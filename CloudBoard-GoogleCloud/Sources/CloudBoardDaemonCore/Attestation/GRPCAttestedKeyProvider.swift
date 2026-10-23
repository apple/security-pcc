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

import CloudAttestationV2
import CloudBoardJobHelperCore
import CloudBoardProtos
import CloudBoardUtilities
import Crypto
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import Metrics
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// An ``AttestedKeyProvider`` that obtains attestation sets from cb_attestationd
/// via gRPC and looks up WSD keys directly via cloudattestationv2.
final class GRPCAttestedKeyProvider: AttestationProvider, AttestedKeyProvider, RequestEncryptionKeyResolver, Sendable {
    private static let logger = Logger(label: "cloudboardd.GRPCAttestedKeyProvider")

    struct CachedState: Sendable {
        var attestationSet: AttestationSet?
        /// Maps keyID (SHA256 of attestation bundle) to the JSON-encoded KeyIdentifier
        /// received from cb_attestationd.
        var keyHandlesByKeyID: [Data: Data]
        var watcherContinuations: [UUID: AsyncStream<AttestationSet>.Continuation]
    }

    private let cachedState: Mutex<CachedState>
    private let keyStore: any CloudAttestationV2.KeyStore

    init(keyStore: any CloudAttestationV2.KeyStore) {
        self.cachedState = Mutex(CachedState(attestationSet: nil, keyHandlesByKeyID: [:], watcherContinuations: [:]))
        self.keyStore = keyStore
    }

    /// Update the cached attestation set from a proto response.
    func updateFromProto(_ response: Proto_Attestation_WatchAttestationsResponse) {
        let protoSet = response.attestationSet

        let current = protoSet.currentAttestation
        let currentAttestation = AttestationSet.Attestation(
            attestationBundle: current.attestationBundle,
            expiry: current.expiry.date,
            releaseDigest: "",
            appData: [:],
            transparencyTreeID: current.hasTransparencyTreeID ? current.transparencyTreeID : nil,
            transparencyRevision: current.hasTransparencyRevision ? current.transparencyRevision : nil
        )

        let unpublished = protoSet.unpublishedAttestations.map { att in
            AttestationSet.Attestation(
                attestationBundle: att.attestationBundle,
                expiry: att.expiry.date,
                releaseDigest: "",
                appData: [:],
                transparencyTreeID: att.hasTransparencyTreeID ? att.transparencyTreeID : nil,
                transparencyRevision: att.hasTransparencyRevision ? att.transparencyRevision : nil
            )
        }

        let attestationSet = AttestationSet(
            currentAttestation: currentAttestation,
            unpublishedAttestations: unpublished
        )

        var keyHandles: [Data: Data] = [:]
        let currentKeyID = Data(SHA256.hash(data: current.attestationBundle))
        keyHandles[currentKeyID] = current.keyHandle
        for unpublishedAttestation in protoSet.unpublishedAttestations {
            let keyID = Data(SHA256.hash(data: unpublishedAttestation.attestationBundle))
            keyHandles[keyID] = unpublishedAttestation.keyHandle
        }

        self.cachedState.withLock { state in
            state.attestationSet = attestationSet
            state.keyHandlesByKeyID = keyHandles
            for (_, continuation) in state.watcherContinuations {
                continuation.yield(attestationSet)
            }
        }

        Counter(label: "cloudboard_attestation_update_total").increment()

        Self.logger.info(
            "Updated attestation set from cb_attestationd",
            metadata: [
                "keyCount": "\(1 + protoSet.unpublishedAttestations.count)",
                "currentKeyExpiry": "\(current.expiry.date)",
                "currentKeyID": "\(currentKeyID.base64EncodedString())",
            ]
        )
    }

    func currentAttestationSet() async throws -> AttestationSet {
        guard let set = self.cachedState.withLock({ $0.attestationSet }) else {
            Self.logger.warning("No attestation set available from cb_attestationd")
            throw GRPCAttestedKeyProviderError.noAttestationSetAvailable
        }
        return set
    }

    func watchAttestationSets() -> AsyncStream<AttestationSet> {
        let id = UUID()
        return AsyncStream { continuation in
            self.cachedState.withLock { state in
                if let current = state.attestationSet {
                    continuation.yield(current)
                }
                state.watcherContinuations[id] = continuation
            }
            continuation.onTermination = { _ in
                self.cachedState.withLock { _ = $0.watcherContinuations.removeValue(forKey: id) }
            }
        }
    }

    func key(for keyID: Data) async throws -> any HPKEKEMPrivateKey {
        guard let keyHandleData = self.cachedState.withLock({ $0.keyHandlesByKeyID[keyID] }) else {
            Self.logger.warning(
                "Key lookup failed for unknown keyID",
                metadata: ["keyID": "\(keyID.base64EncodedString())"]
            )
            throw GRPCAttestedKeyProviderError.unknownKeyID(keyID)
        }

        let keyIdentifier: any CloudAttestationV2.KeyIdentifier
        do {
            // We have to assume that the concrete key identifier type is UUID as there currently is no other way to
            // decode the handle/ID.
            keyIdentifier = try JSONDecoder().decode(UUID.self, from: keyHandleData)
        } catch {
            Self.logger.error(
                "Failed to decode key handle",
                metadata: [
                    "keyID": "\(keyID.base64EncodedString())",
                    "error": "\(String(reportable: error))",
                ]
            )
            throw GRPCAttestedKeyProviderError.invalidKeyHandle(keyID)
        }

        Self.logger.debug(
            "Looking up WSD key",
            metadata: ["keyHandle": "\(keyIdentifier)", "keyID": "\(keyID.base64EncodedString())"]
        )

        do {
            Counter(label: "cloudboard_key_lookup_total").increment()
            let clock = ContinuousClock()
            let start = clock.now
            let wsdKey = try self.keyStore.key(id: keyIdentifier)
            let kemKey = try Conformance.Curve25519.KeyEncapsulation.PrivateKey(key: wsdKey)
            let duration = clock.now - start

            Timer(
                label: "cloudboard_key_lookup_seconds",
                preferredDisplayUnit: .seconds
            ).record(duration: duration)

            return kemKey
        } catch {
            Counter(
                label: "cloudboard_key_lookup_error_total",
                dimensions: [("errorDescription", String(reportable: error))]
            ).increment()
            Self.logger.error(
                "WSD key lookup failed",
                metadata: [
                    "keyHandle": "\(keyIdentifier)",
                    "keyID": "\(keyID.base64EncodedString())",
                    "error": "\(String(reportable: error))",
                ]
            )
            throw error
        }
    }

    func resolveRequestEncryptionKey(for keyID: Data) async throws -> String {
        guard let keyHandleData = self.cachedState.withLock({ $0.keyHandlesByKeyID[keyID] }) else {
            throw GRPCAttestedKeyProviderError.unknownKeyID(keyID)
        }
        let uuid = try JSONDecoder().decode(UUID.self, from: keyHandleData)
        return uuid.uuidString
    }
}

enum GRPCAttestedKeyProviderError: Error {
    case noAttestationSetAvailable
    case unknownKeyID(Data)
    case invalidKeyHandle(Data)
}

extension GRPCAttestedKeyProviderError: ReportableError {
    var publicDescription: String {
        switch self {
        case .noAttestationSetAvailable:
            "GRPCAttestedKeyProviderError.noAttestationSetAvailable"
        case .unknownKeyID:
            "GRPCAttestedKeyProviderError.unknownKeyID"
        case .invalidKeyHandle:
            "GRPCAttestedKeyProviderError.invalidKeyHandle"
        }
    }
}
