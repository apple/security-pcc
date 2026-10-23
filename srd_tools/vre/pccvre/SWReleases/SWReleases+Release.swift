// Copyright © 2026 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

@_spi(Private) import CloudAttestation
import CryptoKit
import Foundation

typealias SWRelease = SWReleases.Release

public extension SWReleases {
    // Release is a (parsed) Leaf node in the SW Transparency Tree representing a published release.
    //
    // Two release schemas coexist in the PCC transparency log:
    //
    //   .v1 — legacy CloudAttestation.Release (DER-encoded AppleSiliconV1: apTicket +
    //         cryptexTickets), decoded in-process and rendered via Image4 manifest properties.
    //   .v2 — newer schema (DER-encoded ReleaseV2) decoded out-of-process by
    //         pccvre-attestation-helper. The helper's structured JSON output is stored
    //         opaquely on the case so pccvre doesn't carry the schema's field layout.
    //
    // Both are DER `SEQUENCE { INTEGER version, … }`; dispatch reads that version
    // INTEGER (`TransparencyLog.ATLeaf.releaseSchemaVersion`) — v1=1, v2=2 —
    // rather than guessing from a byte prefix.
    struct Release {
        typealias V1Tickets = CloudAttestation.Release
        typealias Tickets = V1Tickets // back-compat alias for AssetHelper / ReleaseVerifyCmd

        let index: UInt64
        let nodeData: ATLeafData
        let rawData: Data
        var metadata: SWReleaseMetadata?
        let contents: Contents

        var dataHash: Data { nodeData.dataHash }

        enum Contents {
            case v1(V1Tickets)
            /// `nil` when the leaf is v2-shaped but `pccvre-attestation-helper`
            /// is unavailable (not configured, hostTools fetch/mount failed).
            /// The leaf still appears in `release list`/`dump` output — with
            /// its metadata, index, dataHash, and rawData — just without a
            /// parsed summary/detail. See the once-per-run stderr warning
            /// emitted by `PCCVREAttestationHelperResolver.releaseParse`.
            case v2(PCCVREAttestationHelper.Envelope?)
        }

        var v1Tickets: V1Tickets? {
            guard case .v1(let tickets) = contents else { return nil }
            return tickets
        }

        var apManifest: Image4Manifest? {
            guard let tickets = v1Tickets else { return nil }
            let apm = Image4Manifest(data: tickets.apTicket.bytes, kind: .ap)
            return ((try? apm.properties) != nil) ? apm : nil
        }

        var cryptexManifests: [Image4Manifest]? {
            guard let tickets = v1Tickets else { return nil }
            var cms: [Image4Manifest] = []
            for ct in tickets.cryptexTickets {
                let cm = Image4Manifest(data: ct.bytes, kind: .cryptex)
                if (try? cm.properties) != nil {
                    cms.append(cm)
                }
            }
            return cms.count > 0 ? cms : nil
        }

        init(leaf: TransparencyLog.ATLeaf, helper: PCCVREAttestationHelperResolver?) async throws {
            self.index = leaf.index
            self.nodeData = leaf.nodeData
            self.rawData = leaf.rawData

            self.contents = try await Self.decodeContents(leaf: leaf, helper: helper)

            // v1 leaves require a parseable AP manifest, matching the prior contract.
            if case .v1 = self.contents, self.apManifest == nil {
                throw SWReleasesError("[\(leaf.index)]: release payload: no OS ticket")
            }

            self.metadata = try? SWReleaseMetadata(leaf: leaf)
        }

        private static func decodeContents(
            leaf: TransparencyLog.ATLeaf,
            helper: PCCVREAttestationHelperResolver?
        ) async throws -> Contents {
            switch leaf.releaseSchemaVersion {
            case 1:
                do {
                    return .v1(try V1Tickets(serializedData: leaf.rawData))
                } catch {
                    throw SWReleasesError("[\(leaf.index)]: v1 release payload failed to decode: \(error)")
                }

            case 2:
                guard let helper else {
                    // helper:nil callers (e.g. the resolver bootstrap) only
                    // need metadata, not parsed contents.
                    return .v2(nil)
                }
                switch await helper.releaseParse(bytes: leaf.rawData) {
                case .parsed(let envelope):
                    return .v2(envelope)
                case .unrecognized:
                    // The bundled helper doesn't know this schema — try once
                    // more with a freshly-fetched latest helper.
                    if case .parsed(let envelope) = await helper.escalateAndRetry(bytes: leaf.rawData) {
                        return .v2(envelope)
                    }
                    // Helper unavailable or still doesn't recognise it.
                    // Surface the leaf as unparsed-v2 so `release list`/`dump`
                    // still show it (index, dataHash, metadata, rawData intact).
                    CLI.logger.log("[\(leaf.index)]: v2 release payload could not be parsed (helper unavailable or schema unrecognised); showing unparsed")
                    return .v2(nil)
                }

            case let version?:
                // Future schema. Try the latest helper once; otherwise surface
                // unparsed so the leaf isn't silently dropped.
                CLI.logger.log("[\(leaf.index)]: release payload has unknown schema version \(version)")
                if let helper, case .parsed(let envelope) = await helper.escalateAndRetry(bytes: leaf.rawData) {
                    return .v2(envelope)
                }
                return .v2(nil)

            case nil:
                // Not `SEQUENCE { INTEGER version, … }` at all. Surface it
                // unparsed rather than silently dropping to skippedLeaves so
                // the raw bytes are visible in `release list --json`.
                CLI.logger.error("[\(leaf.index)]: release payload is not a recognised DER SEQUENCE { INTEGER version, … }; first bytes: \(leaf.rawData.prefix(16).hexString, privacy: .public)")
                return .v2(nil)
            }
        }
    }
}

extension SWReleases.Release: Comparable, Equatable, Hashable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.index < rhs.index
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dataHash == rhs.dataHash
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(dataHash)
    }
}

extension TransparencyLog.ATLeaf {
    /// The ASN.1 `version` INTEGER of this leaf's DER-encoded release payload.
    /// See `releaseSchemaVersion(rawData:)`.
    var releaseSchemaVersion: Int? { Self.releaseSchemaVersion(rawData: rawData) }

    /// Reads the ASN.1 `version` INTEGER from a DER-encoded release leaf.
    /// Both schemas are `SEQUENCE { INTEGER version, … }`:
    ///   - v1 (`AppleSiliconV1`): `version = 1`, then `OCTET STRING apTicket`
    ///   - v2 (`ReleaseV2`):      `version = 2`, then context-tagged workload/platform
    /// Returns nil on malformed/unexpected structure so callers can treat
    /// it as "unknown schema" rather than guessing. This is the sole
    /// v1/v2 discriminator — a bare `first == 0x30` sniff is useless
    /// since both are DER SEQUENCEs.
    static func releaseSchemaVersion(rawData: Data) -> Int? {
        var i = rawData.startIndex
        func take() -> UInt8? {
            guard i < rawData.endIndex else { return nil }
            defer { i = rawData.index(after: i) }
            return rawData[i]
        }
        guard take() == 0x30, let lb = take() else { return nil }  // SEQUENCE, first length byte
        if lb & 0x80 != 0 {  // long-form length: skip the N length bytes
            guard let next = rawData.index(i, offsetBy: Int(lb & 0x7f), limitedBy: rawData.endIndex) else { return nil }
            i = next
        }
        // INTEGER, length 1, value byte
        guard take() == 0x02, take() == 0x01, let v = take() else { return nil }
        return Int(v)
    }
}
