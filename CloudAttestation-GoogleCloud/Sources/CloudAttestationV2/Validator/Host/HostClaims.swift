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

//
//  HostClaims.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Crypto
import Foundation
import Logging
import SwiftEventLog
import SwiftTPM

// MARK: - HostClaims

/// Claims derived from the bare-metal host's **PC Client boot event log**,
/// independent of the TPM quote.
///
/// This is the host analogue of ``CCELClaims``: the `replayedPCRN` values are
/// produced by replaying the boot log, and ``bootApplicationDigests`` describes
/// what the log says was loaded. The CEL launch log (PCR[19]) is a separate
/// concern entirely, projected by ``CSELClaims``.
///
/// Trust model — IMPORTANT for policy authors: nothing here is bound to
/// hardware on its own. Policy MUST verify `replayedPCRN == TPMClaims.pcrN`
/// (and that ``TPMClaims/verified`` is true and the TPM signature + Titan
/// endorsement are valid) before trusting any field below — exactly as
/// `validate_ccel` requires `ccel_claims.replayedRTMRN == tdx_claims.rtmrN`.
/// Only then is the log proven to be the one the TPM quoted.
///
/// PCR[0] (platform firmware) is seeded by a hardware H-CRTM, but it is still
/// replayable once the register is initialized from the log's `StartupLocality`
/// event, so ``replayedPCR0`` IS produced and policy reconciles it against
/// ``TPMClaims/pcr0`` exactly like the other registers. Without that binding a
/// host on unpublished firmware could substitute a known-good BMC measurement
/// into the unsigned log while its signed PCR[0] reflected the real firmware.
public struct HostClaims: Claims.DefaultInitializableValue {
    /// PCR[0] (platform firmware / H-CRTM) reconstructed by replaying the PC
    /// Client boot event log, with the register seeded from the log's
    /// `StartupLocality` event (see ``bmcFirmwareDigest``). Trustworthy only once
    /// `replayedPCR0 == TPMClaims.pcr0`.
    public var replayedPCR0: Data? = nil

    /// PCR[17] (DRTM) reconstructed by replaying the PC Client boot event log.
    public var replayedPCR17: Data? = nil

    /// PCR[21] (boot-services application register) reconstructed by replaying
    /// the PC Client boot event log.
    public var replayedPCR21: Data? = nil

    /// Digests of the `EV_EFI_BOOT_SERVICES_APPLICATION` images measured into
    /// PCR[21] — the launched bare-metal host image(s). Classified digest-first
    /// (an event whose digest differs from `hash(event.data)` is a loaded
    /// binary, not self-attesting metadata); `event.type` is never trusted to
    /// drive collection. Trustworthy only once `replayedPCR21 == TPMClaims.pcr21`.
    public var bootApplicationDigests: [Data]? = nil

    /// SHA-256 digest of the single `EV_EFI_HCRTM_EVENT` measured into PCR[0] —
    /// the BMC firmware measurement (the Titan H-CRTM). This is the digest of
    /// that one event (`sha256(descriptorHash)`), not the aggregate PCR[0]
    /// register. Matches GCP's `GMESState.BmcFirmwareDigest`. Trustworthy only
    /// once `replayedPCR0 == TPMClaims.pcr0` binds the (unsigned) log to the
    /// quote — the H-CRTM seeds PCR[0] in hardware, but the register is still
    /// replayed from the log with a `StartupLocality`-derived seed.
    public var bmcFirmwareDigest: Data? = nil

    /// SHA-256 digest of the single Google DRTM event measured into PCR[17] —
    /// the host BIOS/platform-firmware measurement. Digest of that one event
    /// (`sha256(descriptorHash)`), not the aggregate register. Matches GCP's
    /// `GMESState.BiosDigest`. Trustworthy only once `replayedPCR17 ==
    /// TPMClaims.pcr17`.
    public var biosDigest: Data? = nil

    public init() {}
}

// MARK: - Errors

enum HostClaimsError: Error {
    /// The serialized boot log shows evidence of separator mutation.
    case tamperedLog(reason: String)
    /// The firmware emitted an error separator (`SHA256(0xFFFFFFFF)`) — a
    /// TCG-spec'd signal that boot encountered a fatal error at this stage.
    /// Measurements on the affected register cannot be trusted past this point.
    case bootFailed(reason: String)
    /// An event measured into a replayed PCR lacked a SHA-256 digest, so the
    /// replay cannot be trusted.
    case missingSHA256Digest(pcr: UInt32)
}

// MARK: - Generator

extension HostClaims {
    /// Projects a host's PC Client boot event log into ``HostClaims``.
    ///
    /// Resilient by design: if replay fails, the corresponding fields are left
    /// `nil` and the failure is logged, so policy sees missing claims (and the
    /// reconciliation it requires fails) rather than a hard error. Replays use
    /// the SHA-256 bank (the only bank these hosts use), mirroring the
    /// SHA-384-only CCEL generator.
    public struct Generator: ClaimsGenerator, Sendable {
        private static let logger = Logger(label: "com.apple.CloudAttestation.HostClaims")

        public init() {}

        public func generateClaims(for pcclientBootEventLog: TCGEventLog) throws -> HostClaims {
            var claims = HostClaims()
            do {
                claims.replayedPCR0 = try Self.replayPCR0(pcclientBootEventLog)
                claims.replayedPCR17 = try Self.replay(pcclientBootEventLog, pcr: HostPCR.drtm)
                claims.replayedPCR21 = try Self.replay(pcclientBootEventLog, pcr: HostPCR.boot)
                claims.bootApplicationDigests = try Self.bootApplications(in: pcclientBootEventLog, pcr: HostPCR.boot)
                // BMC (PCR[0], EV_EFI_HCRTM_EVENT) and BIOS (PCR[17], Google DRTM)
                // are single-event Google measurements — matched by event type,
                // mirroring GCP's `extract.GMESState`.
                claims.bmcFirmwareDigest = Self.googleMeasurementDigest(in: pcclientBootEventLog, pcr: HostPCR.platformFirmware, type: .efiHCRTMEvent)
                claims.biosDigest = Self.googleMeasurementDigest(in: pcclientBootEventLog, pcr: HostPCR.drtm, type: .googleDRTMEvent)
            } catch {
                Self.logger.warning(
                    "Failed to replay host boot event log; returning partial claims",
                    metadata: ["error": .string(String(describing: error))]
                )
            }
            return claims
        }
    }
}

// MARK: - Replay & extraction

extension HostClaims.Generator {
    /// Replays every PC Client boot event measured into `pcr` into a simulated
    /// SHA-256 register. Returns `nil` when no event targets `pcr`. Throws on a
    /// tampered separator, an error (boot-failed) separator, or a SHA-256-less
    /// event, so the caller can leave the replayed value absent rather than
    /// trust a partial or post-failure replay.
    private static func replay(_ eventLog: TCGEventLog, pcr: UInt32) throws -> Data? {
        var register = PCR<SHA256>(hashFunction: SHA256.self)
        var extended = false
        for event in eventLog.events where event.pcrIndex == pcr {
            switch event.authenticatedSeparatorKind {
            case .tampered:
                throw HostClaimsError.tamperedLog(reason: "tampered separator on PCR \(pcr)")
            case .error:
                throw HostClaimsError.bootFailed(reason: "error separator on PCR \(pcr)")
            case .success, nil:
                break
            }
            guard let digest = event.digest(algorithm: SHA256.self) else {
                throw HostClaimsError.missingSHA256Digest(pcr: pcr)
            }
            try register.extend(data: digest)
            extended = true
        }
        return extended ? Data(register) : nil
    }

    /// Replays PCR[0] (the H-CRTM platform-firmware register) from the PC Client
    /// boot event log so policy can reconcile it against the quoted
    /// `TPMClaims.pcr0`. Differs from ``replay(_:pcr:)`` in two PCR[0]-specific
    /// ways:
    ///
    /// - The register is **seeded** from the log's `StartupLocality` event
    ///   (``pcr0Seed(_:)``) rather than started at all-zeros: the H-CRTM resets
    ///   PCR[0] to a locality-dependent value before the firmware extends it.
    /// - `EV_NO_ACTION` events (including `StartupLocality` itself) are
    ///   **skipped** — they are informational and are never extended into the
    ///   PCR. The DRTM registers PCR[17]/[21] carry no such events, so
    ///   ``replay(_:pcr:)`` need not filter them.
    ///
    /// Separator handling and the `missingSHA256Digest` guard match
    /// ``replay(_:pcr:)``; returns `nil` when nothing was extended, so a failed
    /// replay surfaces as an absent claim (and reconciliation fails) rather than
    /// a trusted partial value.
    private static func replayPCR0(_ eventLog: TCGEventLog) throws -> Data? {
        var register = try PCR<SHA256>(Self.pcr0Seed(eventLog), hashFunction: SHA256.self)
        var extended = false
        for event in eventLog.events where event.pcrIndex == HostPCR.platformFirmware {
            if event.type == .evNoAction {
                continue
            }
            switch event.authenticatedSeparatorKind {
            case .tampered:
                throw HostClaimsError.tamperedLog(reason: "tampered separator on PCR \(HostPCR.platformFirmware)")
            case .error:
                throw HostClaimsError.bootFailed(reason: "error separator on PCR \(HostPCR.platformFirmware)")
            case .success, nil:
                break
            }
            guard let digest = event.digest(algorithm: SHA256.self) else {
                throw HostClaimsError.missingSHA256Digest(pcr: HostPCR.platformFirmware)
            }
            try register.extend(data: digest)
            extended = true
        }
        return extended ? Data(register) : nil
    }

    /// The H-CRTM startup-locality seed for the PCR[0] replay. PCR[0] is not
    /// reset to all-zeros on these hosts: the H-CRTM sequence resets it from a
    /// non-zero locality, so the replay must start from the same value.
    ///
    /// The locality is taken, in order of preference, from:
    /// 1. An explicit `StartupLocality` `EV_NO_ACTION` event on PCR[0] — per the
    ///    TCG PC Client Platform Firmware Profile its data is the ASCII signature
    ///    `"StartupLocality"` + a NUL terminator (16 bytes) followed by a single
    ///    locality byte.
    /// 2. Otherwise, the presence of an `EV_EFI_HCRTM_EVENT` implies an H-CRTM
    ///    sequence, which the profile mandates runs at **locality 4**.
    /// 3. Otherwise locality 0 (all-zeros).
    ///
    /// The register's initial value is 32 zero bytes with the locality in the
    /// least-significant byte. This seed comes from the unsigned log, but a wrong
    /// locality simply makes ``replayPCR0(_:)`` diverge from the quoted
    /// `TPMClaims.pcr0` and fail reconciliation.
    private static func pcr0Seed(_ eventLog: TCGEventLog) -> [UInt8] {
        var seed = [UInt8](repeating: 0, count: SHA256.Digest.byteCount)
        let signature = Array("StartupLocality\u{0}".utf8)
        var startupLocality: UInt8? = nil
        var hasHCRTM = false
        for event in eventLog.events where event.pcrIndex == HostPCR.platformFirmware {
            switch event.type {
            case .evNoAction:
                if event.data.count == signature.count + 1, Array(event.data.prefix(signature.count)) == signature {
                    startupLocality = event.data[signature.count]
                }
            case .efiHCRTMEvent:
                hasHCRTM = true
            default:
                break
            }
        }
        if let startupLocality {
            seed[seed.count - 1] = startupLocality
        } else if hasHCRTM {
            seed[seed.count - 1] = 4
        }
        return seed
    }
    /// measured into `pcr`, digest-first.
    ///
    /// `pcr` is treated as a dedicated boot-services-application register on
    /// these hosts (unlike CCEL's PCR4, which shares a TDX RTMR with other roles
    /// and therefore needs an explicit "Calling…/ExitBootServices" bracket).
    /// Every measured image on the register is collected; the replay binding
    /// (``HostClaims/replayedPCR21`` == `TPMClaims.pcr21`) plus policy's
    /// per-digest allowlist are what constrain the set.
    ///
    /// Separators are handled like the replay (tampered → `tamperedLog`, error →
    /// `bootFailed`, so post-failure images are not surfaced). Among the
    /// remaining events, one whose digest equals `SHA256(event.data)` is
    /// self-attesting metadata (GPT, variable authority, etc.) and is skipped;
    /// the rest are loaded PE/COFF binaries whose digest is the Authenticode hash
    /// (independent of `event.data`) and are collected. `event.type` is never
    /// consulted — it is not covered by the PCR. Returns `nil` when no image is
    /// found.
    private static func bootApplications(in eventLog: TCGEventLog, pcr: UInt32) throws -> [Data]? {
        var digests: [Data] = []
        for event in eventLog.events where event.pcrIndex == pcr {
            switch event.authenticatedSeparatorKind {
            case .tampered:
                throw HostClaimsError.tamperedLog(reason: "tampered separator on PCR \(pcr)")
            case .error:
                throw HostClaimsError.bootFailed(reason: "error separator on PCR \(pcr)")
            case .success:
                continue
            case nil:
                break
            }
            guard let digest = event.digest(algorithm: SHA256.self) else {
                throw HostClaimsError.missingSHA256Digest(pcr: pcr)
            }
            // Self-attesting metadata: the measured digest covers event.data itself.
            if Array(SHA256.hash(data: event.data)) == digest {
                continue
            }
            digests.append(Data(digest))
        }
        return digests.isEmpty ? nil : digests
    }

    /// Returns the SHA-256 digest of the single Google measurement event of
    /// `type` measured into `pcr` (BMC's `EV_EFI_HCRTM_EVENT` at PCR[0], BIOS's
    /// Google DRTM at PCR[17]).
    ///
    /// Unlike ``bootApplications(in:pcr:)``, these registers carry exactly one
    /// meaningful event whose identity IS its type, so `type` is matched here
    /// (mirroring GCP's `extract.GMESState`). The recorded digest is
    /// `sha256(descriptorHash)`; policy reconciles it against a reference RIM.
    /// Returns `nil` when no matching event or SHA-256 digest is present, keeping
    /// the generator resilient.
    private static func googleMeasurementDigest(in eventLog: TCGEventLog, pcr: UInt32, type: EventType) -> Data? {
        for event in eventLog.events where event.pcrIndex == pcr && event.type == type {
            guard let digest = event.digest(algorithm: SHA256.self) else { return nil }
            return Data(digest)
        }
        return nil
    }
}
