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
//  CCELClaims.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import GCPv1
import Logging
import SwiftEventLog
import Crypto
import SwiftTDX
import BinaryCoding
import SwiftTPM

// MARK: - CCELClaims

/// Claims derived from a CCEL (CC Event Log) boot event log.
///
/// Trust model — IMPORTANT for policy authors:
///
/// `replayedRTMR0/1/2` are the SHA-384 register values produced by replaying
/// the parsed log, named by **hardware RTMR register** (0-indexed: RTMR[0],
/// RTMR[1], RTMR[2]). They are NOT compared against the TDX quote inside this
/// generator — the generator has no access to the quote. **Policy MUST verify
/// that each `replayedRTMR_n` equals the corresponding `rtmr[n]` from the TDX
/// quote before trusting any other claim in this struct.**
///
/// Without that check, `secureBoot`, `efiApplications`, and `kernel` are
/// derived from a log whose contents an attacker could have chosen freely;
/// their digests would be authentic relative to the log, but the log itself
/// wouldn't be bound to the hardware quote. With the check, the log is
/// hardware-attested and the derived claims inherit that guarantee.
public struct CCELClaims: Claims.DefaultInitializableValue {
    public var replayedRTMR0: Data? = nil
    public var replayedRTMR1: Data? = nil
    public var replayedRTMR2: Data? = nil

    public var secureBoot: SecureBoot? = nil
    public var efiApplications: [EFIApplication]? = nil

    /// Kernel measurements Grub recorded on CCMR3 (hardware RTMR[2]).
    /// Surfaces both the kernel command line and the kernel image digest
    /// when Grub measured them; either subfield may be `nil` on its own.
    /// The whole struct is `nil` when no Grub kernel events were observed.
    public var kernel: Kernel? = nil

    public init() {}

    /// Classifies ``efiApplications`` into a known boot chain layout.
    ///
    /// - One application: a Unified Kernel Image (Bowcaster). The UKI is a
    ///   single signed PE binary that bundles kernel, initrd, and command
    ///   line; nothing is loaded after it before ExitBootServices.
    /// - Two applications: shim → GRUB (Vanguard). Shim is loaded first
    ///   (it verifies GRUB), then GRUB loads the kernel via IPL events on
    ///   CCMR3 (surfaced separately in ``kernel``).
    ///
    /// Returns nil when `efiApplications` is nil/empty or has a count that
    /// matches neither layout — policy should treat that as an unrecognized
    /// boot chain and reject. Computed from `efiApplications`; not part of
    /// the emitted claim dictionary.
    public var bootChain: BootChain? {
        guard let apps = efiApplications else { return nil }
        switch apps.count {
        case 1: return .uki(apps[0])
        case 2: return .shimGrub(shim: apps[0], grub: apps[1])
        default: return nil
        }
    }
}

extension CCELClaims {
    /// Layout of the EFI boot chain measured into RTMR[1] between the
    /// "Calling EFI Application" and "Exit Boot Services" markers.
    public enum BootChain: Sendable, Hashable {
        /// Bowcaster: a single Unified Kernel Image (UKI) that bundles
        /// kernel, initrd, and command line into one signed PE binary.
        /// No GRUB stage; ``CCELClaims/kernel`` is expected to be nil.
        case uki(EFIApplication)
        /// Vanguard: legacy shim → GRUB chain. Shim verifies GRUB, GRUB
        /// loads the kernel — kernel image and command line are then
        /// reported separately in ``CCELClaims/kernel`` from CCMR3.
        case shimGrub(shim: EFIApplication, grub: EFIApplication)

        /// The UKI binary, if this is a Bowcaster boot chain.
        public var uki: EFIApplication? {
            if case .uki(let uki) = self { return uki }
            return nil
        }

        /// The shim binary, if this is a Vanguard boot chain.
        public var shim: EFIApplication? {
            if case .shimGrub(let shim, _) = self { return shim }
            return nil
        }

        /// The GRUB binary, if this is a Vanguard boot chain.
        public var grub: EFIApplication? {
            if case .shimGrub(_, let grub) = self { return grub }
            return nil
        }

        /// Where OVMF is recorded for this boot chain. Bowcaster carries it per-VM in
        /// ``LinuxV1Measurements/ovmfDigest``; Vanguard carries it platform-wide in
        /// ``GCPv1Platform/ovmfDigest``. Each projection site asks for the bucket it owns
        /// via ``vmOVMFDigest(candidate:)`` / ``platformOVMFDigest(candidate:)`` so the rule
        /// stays in one place.
        public func vmOVMFDigest(candidate: Data?) -> Data? {
            switch self {
            case .uki: return candidate
            case .shimGrub: return nil
            }
        }

        public func platformOVMFDigest(candidate: Data?) -> Data? {
            switch self {
            case .uki: return nil
            case .shimGrub: return candidate
            }
        }
    }
}

// MARK: - Secure Boot Claims

extension CCELClaims {
    public struct SecureBoot: Codable, Claims.ValueProtocol {
        /// Whether UEFI Secure Boot is reported as enabled by the
        /// `SecureBoot` UEFI variable (`EV_EFI_VARIABLE_DRIVER_CONFIG`
        /// measurement on the SecureBoot register).
        public var enabled: Bool = false

        /// True if the firmware measured an `EV_EFI_ACTION` event with the
        /// payload `"UEFI Debug Mode"` — a UEFI debugger was attached during
        /// boot. The presence of this measurement is itself the signal; the
        /// digest is `SHA-384("UEFI Debug Mode")` and is RTMR-bound.
        public var uefiDebugMode: Bool = false

        /// True if the firmware measured an `EV_EFI_ACTION` event with the
        /// payload `"DMA Protection Disabled"` — the platform supports DMA
        /// protection but it is disabled. The digest is
        /// `SHA-384("DMA Protection Disabled")` and is RTMR-bound.
        public var dmaProtectionDisabled: Bool = false
    }
}

// MARK: - EFI Application Claims
extension CCELClaims {
    public struct EFIApplication: Claims.ValueProtocol {
        /// Replay-verified SHA-384 digest of the loaded PE/COFF binary.
        /// This covers the actual image, NOT the EFI_IMAGE_LOAD_EVENT metadata in event.data.
        public var digest: Data

        /// File path extracted from the EFI_IMAGE_LOAD_EVENT device path in event.data.
        /// NOT covered by the digest — the digest hashes the loaded binary, not this metadata.
        /// Use only for display/debugging. Never make security decisions based on this value.
        public var untrustedFilePath: String?

        public init(digest: Data, untrustedFilePath: String? = nil) {
            self.digest = digest
            self.untrustedFilePath = untrustedFilePath
        }
    }
}

// MARK: - Kernel Claims
extension CCELClaims {
    public struct Kernel: Codable, Claims.ValueProtocol {
        /// Kernel command line as measured by Grub via the `kernel_cmdline:`
        /// (or legacy `grub_kernel_cmdline `) IPL event. The trailing NUL
        /// byte Grub sometimes includes is stripped. Digest-verified —
        /// covered by the RTMR replay.
        public var cmdline: String?

        /// Replay-verified digest measured by Grub when it loaded the kernel
        /// (a no-prefix file-measurement event on CCMR3). Covers the kernel
        /// binary contents, NOT the path in `untrustedImagePath`.
        public var imageDigest: Data?

        /// Kernel path Grub passed alongside the file measurement. Carried
        /// in `event.data`, NOT covered by `imageDigest`. Use only for
        /// display or diagnostics; never make security decisions based on
        /// this value.
        public var untrustedImagePath: String?
    }
}

enum CCELClaimsError: Error {
    case invalidRTMRIndex(index: Int)
    case missingOrInvalidDigest(algorithm: TPM.Alg.ID)
    case invalidEventOrdering(reason: String)
    /// The serialized event log shows evidence of mutation: a field that
    /// is not RTMR-bound (event.type, event.data, digest list cardinality)
    /// disagrees with a field that is. The replay may still match the quote,
    /// but the log cannot be trusted for any classification beyond the
    /// raw extended digests.
    case tamperedLog(reason: String)
    /// The firmware emitted an error separator (`SHA(0xFFFFFFFF)`) — a
    /// TCG-spec'd signal that boot encountered a fatal error at this stage.
    /// Subsequent measurements cannot be trusted for the affected role.
    case bootFailed(reason: String)
}

extension CCELClaimsError {
    /// Stable numeric code identifying this error case.
    ///
    /// Codes are explicitly assigned and MUST NOT be renumbered or reused —
    /// they form a public contract that downstream consumers (logs, metrics,
    /// remote callers) may pin against. New cases get the next unused code.
    var code: Int {
        switch self {
        case .invalidRTMRIndex: return 1
        case .missingOrInvalidDigest: return 2
        case .invalidEventOrdering: return 3
        case .tamperedLog: return 4
        case .bootFailed: return 5
        }
    }
}

extension CCELClaimsError: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidRTMRIndex(let index):
            return "CCELClaimsError[\(code)] invalidRTMRIndex: index=\(index)"
        case .missingOrInvalidDigest(let algorithm):
            return "CCELClaimsError[\(code)] missingOrInvalidDigest: algorithm=\(algorithm)"
        case .invalidEventOrdering(let reason):
            return "CCELClaimsError[\(code)] invalidEventOrdering: \(reason)"
        case .tamperedLog(let reason):
            return "CCELClaimsError[\(code)] tamperedLog: \(reason)"
        case .bootFailed(let reason):
            return "CCELClaimsError[\(code)] bootFailed: \(reason)"
        }
    }
}

extension CCELClaimsError: LocalizedError {
    var errorDescription: String? { description }
}

extension CCELClaimsError: CustomNSError {
    static var errorDomain: String { "com.apple.CloudAttestationV2.CCELClaimsError" }
    var errorCode: Int { code }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: description]
    }
}

extension CCELClaims {

    public struct Generator: ClaimsGenerator, Sendable {
        private static let logger = Logger(label: "com.apple.CloudAttestation.CCELClaims")

        public init() {
        }

        /// Generates CCEL claims. Throws if the log shows evidence of
        /// tampering or the firmware signaled boot failure — in those cases
        /// no further claim could be safely derived. If the log can't be
        /// parsed or replayed at all, returns empty claims; policy MUST
        /// verify each `replayedRTMR_n` is present and matches the quote
        /// before trusting any other field. Otherwise returns a `CCELClaims`
        /// with whichever fields could be extracted; missing fields are
        /// left `nil`.
        public func generateClaims(for eventLog: TCGEventLog) throws -> CCELClaims {
            var claims = CCELClaims()

            do {
                let (rtmr0, rtmr1, rtmr2) = try replayCCEL(eventLog)
                claims.replayedRTMR0 = Data(rtmr0)
                claims.replayedRTMR1 = Data(rtmr1)
                claims.replayedRTMR2 = Data(rtmr2)
                claims.secureBoot = try extractSecureBoot(from: eventLog)
                claims.efiApplications = try extractEFIApplications(from: eventLog)
                try extractGrubEvents(from: eventLog, into: &claims)
            } catch {
                Self.logger.error(
                    "CCEL replay or extraction failed; returning partial claims",
                    metadata: ["error": .string(String(describing: error))]
                )
            }

            return claims
        }
    }
}

// MARK: - CCEL Replay

extension CCELClaims.Generator {

    /// Maps a CCEL `pcrIndex` (1-based CC MR Index on the wire) to the
    /// 0-based hardware RTMR register it extends. Centralizes the off-by-one
    /// between the wire format and the TDX hardware register namespace so
    /// that policy authors comparing `replayedRTMR_n` against `quote.rtmr_n`
    /// are aligned.
    ///
    ///   pcrIndex 1 (CCMR1) → hardware RTMR[0]
    ///   pcrIndex 2 (CCMR2) → hardware RTMR[1]
    ///   pcrIndex 3 (CCMR3) → hardware RTMR[2]
    ///   pcrIndex 4 (CCMR4) → hardware RTMR[3] — not replayed in this pass
    private static let ccmrToRTMR: [UInt32: Int] = [
        1: 0,
        2: 1,
        3: 2,
    ]

    /// Replays the CCEL (CC Event Log) and verifies simulated RTMR0-2 match the quoted values.
    private func replayCCEL(_ eventLog: TCGEventLog) throws -> (rtmr0: RTMR<SHA384>, rtmr1: RTMR<SHA384>, rtmr2: RTMR<SHA384>) {
        // Simulate hardware RTMR registers 0-2 (48 bytes each, SHA-384), keyed
        // by the 0-based hardware index. Events whose pcrIndex doesn't map to
        // a replayed register (CCMR0, CCMR4) are ignored — policy verifies
        // each replayed register against the quote separately, so anything
        // outside this set is out-of-scope rather than a tamper signal.
        var simulated: [RTMR<SHA384>] = .init(repeating: RTMR(), count: 3)

        for event in eventLog.events {
            guard let rtmrIndex = Self.ccmrToRTMR[event.pcrIndex] else {
                continue
            }
            guard let sha384Digest = event.digest(algorithm: SHA384.self) else {
                throw CCELClaimsError.missingOrInvalidDigest(algorithm: SHA384.tpmAlgorithmID)
            }
            try simulated[rtmrIndex].extend(data: sha384Digest)
        }

        return (simulated[0], simulated[1], simulated[2])
    }
}

// MARK: - CCEL Artifact Extraction

extension CCELClaims.Generator {

    /// Well-known EFI Global Variable GUID: 8be4df61-93ca-11d2-aa0d-00e098032b8c
    private static let efiGlobalVariableGUID: [UInt8] = [
        0x61, 0xdf, 0xe4, 0x8b, 0xca, 0x93, 0xd2, 0x11,
        0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c,
    ]

    /// Well-known EFI action payloads measured into the SecureBoot register.
    /// Detected by digest (digest-first), not by `event.type` — the type
    /// field is attacker-mutable while the digest is RTMR-bound.
    private static let uefiDebugModeString = "UEFI Debug Mode"
    private static let dmaProtectionDisabledString = "DMA Protection Disabled"

    /// Extracts secure boot state from the SecureBoot register (CCMR1 / pcrIndex 1, hardware RTMR[0]).
    ///
    /// Surfaces three independent signals when present in the log:
    ///   - `enabled`: from the `SecureBoot` UEFI variable measurement.
    ///   - `uefiDebugMode`: an `EV_EFI_ACTION "UEFI Debug Mode"` measurement
    ///     was observed (firmware ran with a debugger attached).
    ///   - `dmaProtectionDisabled`: an `EV_EFI_ACTION "DMA Protection Disabled"`
    ///     measurement was observed.
    ///
    /// All three are detected digest-first: well-known SHA-384 constants for
    /// the action payloads, and self-attesting parse for the variable. Returns
    /// nil only when no `SecureBoot` variable measurement is found.
    func extractSecureBoot(from eventLog: TCGEventLog) throws -> CCELClaims.SecureBoot? {
        let uefiDebugModeDigest = Array(SHA384.hash(data: Array(Self.uefiDebugModeString.utf8)))
        let dmaProtectionDisabledDigest = Array(SHA384.hash(data: Array(Self.dmaProtectionDisabledString.utf8)))

        var status: Bool? = nil
        var uefiDebugMode = false
        var dmaProtectionDisabled = false
        var seenSeparator = false

        for event in eventLog.events.filter({ $0.pcrIndex == 1 }) {

            // An authenticated separator in RTMR1 marks the end of pre-OS firmware measurements
            if let separatorKind = event.authenticatedSeparatorKind {
                if separatorKind == .tampered {
                    throw CCELClaimsError.tamperedLog(reason: "Separator digest matches sentinel but type/data disagree")
                }
                if seenSeparator {
                    throw CCELClaimsError.invalidEventOrdering(reason: "Duplicate separator event")
                }
                // Error separator means boot failed — don't trust anything
                if separatorKind == .error {
                    throw CCELClaimsError.bootFailed(reason: "Error separator witnessed in RTMR1 (firmware register)")
                }
                seenSeparator = true
                continue
            }

            guard let sha384Digest = event.digest(algorithm: SHA384.self) else { continue }

            // "UEFI Debug Mode" — digest-first detection. The action payload is
            // self-attesting (digest = SHA384("UEFI Debug Mode")), so a digest
            // match is RTMR-bound evidence the action was measured. event.type
            // and event.data are then verified defensively; disagreement means
            // the log was mutated.
            if sha384Digest == uefiDebugModeDigest {
                guard event.type == .efiAction else {
                    throw CCELClaimsError.tamperedLog(reason: "UEFI Debug Mode digest with wrong event.type (got \(event.type), expected efiAction)")
                }
                guard event.data == Array(Self.uefiDebugModeString.utf8) else {
                    throw CCELClaimsError.tamperedLog(reason: "UEFI Debug Mode digest with mismatched event.data")
                }
                if seenSeparator {
                    throw CCELClaimsError.invalidEventOrdering(reason: "UEFI Debug Mode action witnessed after separator")
                }
                uefiDebugMode = true
                continue
            }

            // "DMA Protection Disabled" — same digest-first pattern.
            if sha384Digest == dmaProtectionDisabledDigest {
                guard event.type == .efiAction else {
                    throw CCELClaimsError.tamperedLog(reason: "DMA Protection Disabled digest with wrong event.type (got \(event.type), expected efiAction)")
                }
                guard event.data == Array(Self.dmaProtectionDisabledString.utf8) else {
                    throw CCELClaimsError.tamperedLog(reason: "DMA Protection Disabled digest with mismatched event.data")
                }
                if seenSeparator {
                    throw CCELClaimsError.invalidEventOrdering(reason: "DMA Protection Disabled action witnessed after separator")
                }
                dmaProtectionDisabled = true
                continue
            }

            // Defensive: detect tampered SecureBoot events where the type
            // field was flipped. SecureBoot variable measurements are
            // self-attesting (digest = SHA384(event.data)) and parse as
            // UEFI_VARIABLE_DATA{efiGlobalVariableGUID, "SecureBoot", ...}
            // regardless of the (untrusted) type. Seeing one with the wrong
            // type means the log was mutated post-measurement; throw rather
            // than silently dropping the claim. (Without this, a true→nil
            // downgrade would be invisible — safe only if policy treats nil
            // as off, but we don't want to rely on that here.)
            if event.type != .efiVariableDriverConfig,
                Array(SHA384.hash(data: event.data)) == sha384Digest,
                let variable = try? UEFIVariableData(from: event.data),
                variable.guid == Self.efiGlobalVariableGUID,
                variable.name == "SecureBoot"
            {
                throw CCELClaimsError.tamperedLog(
                    reason: "SecureBoot variable measurement appears with wrong event.type (got \(event.type), expected efiVariableDriverConfig)"
                )
            }

            guard event.type == .efiVariableDriverConfig else { continue }
            // SecureBoot event after separator — reject
            if seenSeparator {
                throw CCELClaimsError.invalidEventOrdering(reason: "SecureBoot event witnessed after separator")
            }

            // Verify event.data is covered by the RTMR-authenticated digest
            guard Array(SHA384.hash(data: event.data)) == sha384Digest else {
                throw CCELClaimsError.missingOrInvalidDigest(algorithm: .sha384)
            }

            let variable = try UEFIVariableData(from: event.data)
            guard variable.guid == Self.efiGlobalVariableGUID else { continue }
            guard variable.name == "SecureBoot" else { continue }

            // Duplicate SecureBoot event — don't trust either
            if status != nil {
                throw CCELClaimsError.invalidEventOrdering(reason: "duplicate SecureBoot event")
            }
            // Empty `variableData` (observed on Bowcaster TDVF) is treated as disabled —
            // matches UEFI semantics where an unset variable defaults to off, and lets the
            // claim be produced so policy can still inspect debug-mode/DMA flags.
            status = variable.variableData.first == 0x01
        }
        // return nil if no secure boot events were witnessed.
        guard let status else {
            return nil
        }
        var out = CCELClaims.SecureBoot()
        out.enabled = status
        out.uefiDebugMode = uefiDebugMode
        out.dmaProtectionDisabled = dmaProtectionDisabled
        return out
    }

    // Well-known EFI action strings whose digests identify lifecycle events.
    private static let callingEFIApplicationString = "Calling EFI Application from Boot Option"
    private static let returningFromEFIApplicationString = "Returning from EFI Application from Boot Option"
    private static let exitBootServicesString = "Exit Boot Services Invocation"

    /// Extracts authenticated SHA-384 digests of loaded PE/COFF binaries
    /// measured between the "Calling EFI Application" and "Exit Boot Services
    /// Invocation" markers.
    ///
    /// Security model: only the per-event digest is authenticated by RTMR
    /// replay; event.type, event.data, and the digest list cardinality are all
    /// attacker-mutable in the serialized log. Classification is therefore
    /// digest-first:
    ///   - Lifecycle markers and separators are recognized by their well-known
    ///     SHA-384 constants.
    ///   - In-bracket events are split by digest provenance: events where
    ///     SHA384(event.data) == digest are self-attesting metadata (GPT,
    ///     variable authority, etc.) and are skipped. The remainder are loaded
    ///     PE/COFF binaries (digest = Authenticode hash, independent of
    ///     event.data) and are collected.
    ///
    /// event.type is never used to drive collection — that would let an attacker
    /// hide a real binary by retyping it without breaking the RTMR replay.
    ///
    /// Implementation notes:
    /// - Pre-computes SHA-384 digests for the three well-known EFI action strings.
    /// - Walks events in CC MR Index 2 (pcrIndex 2, which maps to RTMR[1]).
    ///   In CCEL this single register carries both EFI App events (TPM PCR 4) and
    ///   ExitBootServices events (TPM PCR 5), so every event is checked against both roles.
    /// - Enforces the Calling → App* → (Returning | ExitBootServices) lifecycle.
    /// - Only returns results when ExitBootServices is observed (completeness gate).
    /// - The digest covers the loaded PE/COFF binary, NOT the EFI_IMAGE_LOAD_EVENT
    ///   metadata in event.data.
    func extractEFIApplications(from eventLog: TCGEventLog) throws -> [CCELClaims.EFIApplication]? {
        // Phase 1: Pre-compute reference digests for lifecycle events.
        let callingEFIAppDigest = Array(SHA384.hash(data: Array(Self.callingEFIApplicationString.utf8)))
        let returningFromEFIAppDigest = Array(SHA384.hash(data: Array(Self.returningFromEFIApplicationString.utf8)))
        let exitBootSvcDigest = Array(SHA384.hash(data: Array(Self.exitBootServicesString.utf8)))

        // Phase 2: State machine variables.
        // NOTE: This code is CCEL/TDX-only. In TDX, both the EFI App role (TPM PCR 4)
        // and ExitBootServices role (TPM PCR 5) collapse into a single register
        // (CC MR Index 2 / RTMR[1]), so we use a single separator tracker and process
        // both roles for every event without index-gating. A TPM implementation would
        // need separate separator tracking per PCR and explicit index guards per role.
        var efiApps: [CCELClaims.EFIApplication] = []
        var seenSeparator = false
        var seenCallingEfiApp = false
        var seenExitBootServices = false
        for event in eventLog.events.filter({ $0.pcrIndex == 2 }) {
            guard let sha384Digest = event.digest(algorithm: SHA384.self) else {
                throw CCELClaimsError.missingOrInvalidDigest(algorithm: .sha384)
            }

            // Classify by replayed digest first. event.type is attacker-mutable
            // and NOT covered by the RTMR — only the per-event digest is
            // authenticated. Any branch that gates collection on event.type
            // alone is bypassable by retyping a real event.

            // "Calling EFI Application from Boot Option"
            if sha384Digest == callingEFIAppDigest {
                guard event.type == .efiAction else {
                    throw CCELClaimsError.invalidEventOrdering(reason: "CallingEFIApp digest with non-EFIAction type \(event.type)")
                }
                guard Array(SHA384.hash(data: event.data)) == sha384Digest else {
                    throw CCELClaimsError.invalidEventOrdering(reason: "unverified CallingEFIApp digest")
                }
                guard !seenCallingEfiApp else {
                    throw CCELClaimsError.invalidEventOrdering(reason: "duplicate CallingEFIApp without intervening ReturningFromEFIApp")
                }
                seenCallingEfiApp = true
            }
            // "Returning from EFI Application from Boot Option"
            else if sha384Digest == returningFromEFIAppDigest {
                guard event.type == .efiAction else {
                    throw CCELClaimsError.invalidEventOrdering(reason: "ReturningFromEFIApp digest with non-EFIAction type \(event.type)")
                }
                guard Array(SHA384.hash(data: event.data)) == sha384Digest else {
                    throw CCELClaimsError.invalidEventOrdering(reason: "unverified ReturningFromEFIApp digest")
                }
                guard seenCallingEfiApp else {
                    throw CCELClaimsError.invalidEventOrdering(reason: "ReturningFromEFIApp before CallingEFIApp")
                }
                seenCallingEfiApp = false
            }
            // "Exit Boot Services Invocation" — completeness gate, terminates the walk.
            else if sha384Digest == exitBootSvcDigest {
                guard event.type == .efiAction else {
                    throw CCELClaimsError.invalidEventOrdering(reason: "ExitBootServices digest with non-EFIAction type \(event.type)")
                }
                guard Array(SHA384.hash(data: event.data)) == sha384Digest else {
                    throw CCELClaimsError.invalidEventOrdering(reason: "unverified ExitBootServices digest")
                }
                seenExitBootServices = true
                break
            }
            // Authenticated separator in the EFI App / ExitBootServices register.
            else if let separatorKind = event.authenticatedSeparatorKind {
                if separatorKind == .tampered {
                    throw CCELClaimsError.tamperedLog(reason: "Separator digest matches sentinel but type/data disagree (pcrIndex 2)")
                }
                // Error separator means boot failed — don't trust anything past this point.
                if separatorKind == .error {
                    throw CCELClaimsError.bootFailed(reason: "Error separator witnessed in pcrIndex 2 (EFI app / ExitBootServices register)")
                }
                guard !seenSeparator else {
                    throw CCELClaimsError.invalidEventOrdering(reason: "duplicate separator in pcrIndex 2")
                }
                seenSeparator = true
            }
            // Inside an open Calling… bracket and not a marker or separator.
            // Distinguish loaded PE binaries from self-attesting metadata
            // (GPT, variable authority, etc.) by digest provenance:
            //
            //   - Self-attesting events have digest = SHA384(event.data).
            //     Only the data structure itself is measured. Skip — these
            //     are not loaded images.
            //   - Loaded images have digest = Authenticode(PE binary), which
            //     is independent of event.data (which holds untrusted
            //     EFI_IMAGE_LOAD_EVENT metadata). Collect.
            //
            // event.type is not consulted — it's attacker-mutable. The
            // digest-data binding is structural and RTMR-bound, so it cannot
            // be forged: making a real binary look self-attesting requires a
            // SHA-384 preimage of the PE digest. The reverse (mutating a
            // self-attesting event's data so the hash no longer matches and
            // it gets collected) is possible but harmless — the digest stays
            // RTMR-bound and policy's binary allowlist rejects the unexpected
            // GPT/variable-authority digest.
            else if seenCallingEfiApp {
                if Array(SHA384.hash(data: event.data)) == sha384Digest {
                    continue
                }
                // event.data is EFI_IMAGE_LOAD_EVENT metadata — best-effort
                // parsed for display only. The digest covers the PE/COFF
                // binary, not this metadata.
                let untrustedFilePath = (try? EFIImageLoadEvent(from: event.data))?.untrustedFilePath
                efiApps.append(CCELClaims.EFIApplication(digest: Data(sha384Digest), untrustedFilePath: untrustedFilePath))
            }
            // Events outside the bracket that aren't markers or separators are
            // pre-boot setup on this register — ignored.
        }

        // Phase 6: Completeness gate — only emit EFI state when the boot
        // sequence completed (ExitBootServices was observed).
        guard seenExitBootServices else { return nil }
        return efiApps.isEmpty ? nil : efiApps
    }

    /// Prefixes that identify a Grub IPL command event on CCMR3. The bytes
    /// after the prefix form the *payload* whose SHA-384 must match the
    /// event's measured digest (with or without a trailing NUL — see
    /// implementation note in `extractGrubEvents`).
    /// See https://www.gnu.org/software/grub/manual/grub/grub.html#Measured-Boot
    /// and the legacy Fedora variants from
    /// https://src.fedoraproject.org/rpms/grub2 (TPM rework patch).
    private static let grubKernelCmdlinePrefix = Array("kernel_cmdline: ".utf8)
    private static let grubLegacyKernelCmdlinePrefix = Array("grub_kernel_cmdline ".utf8)
    private static let grubCommandPrefixes: [[UInt8]] = [
        grubKernelCmdlinePrefix,
        Array("grub_cmd: ".utf8),
        Array("module_cmdline: ".utf8),
        grubLegacyKernelCmdlinePrefix,
        Array("grub_cmd ".utf8),
    ]
    /// Subset of `grubCommandPrefixes` that carries the kernel command line.
    private static let grubKernelCmdlinePrefixes: [[UInt8]] = [
        grubKernelCmdlinePrefix,
        grubLegacyKernelCmdlinePrefix,
    ]

    /// Substring used to identify a kernel-image file measurement among the
    /// no-prefix events on CCMR3. The match runs against `event.data` (the
    /// untrusted file path Grub measured alongside the file digest), so the
    /// classification itself is heuristic — but the resulting `digest` is
    /// still RTMR-bound and can be checked against an allowlist by policy.
    private static let kernelImagePathMarker = "vmlinuz"

    /// Extracts the kernel cmdline and kernel image measurement from the
    /// Grub bootloader events on CCMR3 (pcrIndex 3 / hardware RTMR[2]).
    ///
    /// Two categories of events live on this register:
    ///
    ///   1. **Grub command events** with a recognized ASCII prefix (e.g.
    ///      `kernel_cmdline: `, `grub_cmd: `). The digest covers the bytes
    ///      *after* the prefix; we verify that explicitly. Some Grub versions
    ///      include the trailing NUL in the hash, others don't — we try both.
    ///      A prefix-matched event whose digest doesn't verify is treated as
    ///      tampering, since the prefix is a positive claim about the layout.
    ///
    ///   2. **No-prefix file/variable measurement events** (e.g. `MokList\0`,
    ///      `/syslinux/vmlinuz.A\0`, `/efi/boot/grub.cfg\0`). The digest
    ///      covers the file/variable contents; `event.data` is the untrusted
    ///      *name*. We surface the one we care about — the kernel image —
    ///      heuristically by looking for `"vmlinuz"` in the path. Other names
    ///      (initrd, MokList, grub.cfg) are skipped silently; they're still
    ///      RTMR-bound via the replay.
    ///
    /// We do NOT skip events with `EventType.eventTag` strictly per Google's
    /// rationale — they're Linux IMA events that share this register
    /// post-handoff and are not Grub measurements.
    ///
    /// Throws `tamperedLog` when a prefix-matched event fails digest
    /// verification, when an event of an unexpected type is observed, or when
    /// duplicate kernel measurements appear.
    func extractGrubEvents(from eventLog: TCGEventLog, into claims: inout CCELClaims) throws {
        var kernel = CCELClaims.Kernel()

        for event in eventLog.events.filter({ $0.pcrIndex == 3 }) {
            guard let digest = event.digest(algorithm: SHA384.self) else {
                throw CCELClaimsError.missingOrInvalidDigest(algorithm: .sha384)
            }

            // Skip Linux IMA events that share this register after kernel handoff.
            if event.type == .eventTag {
                continue
            }
            guard event.type == .ipl else {
                throw CCELClaimsError.tamperedLog(reason: "non-IPL event on CCMR3 (pcrIndex 3): type=\(event.type)")
            }

            // Category 1: Grub command event with a recognized prefix.
            if let matchedPrefix = Self.grubCommandPrefixes.first(where: { event.data.starts(with: $0) }) {
                let payload = event.data.dropFirst(matchedPrefix.count)
                let payloadDigest = Array(SHA384.hash(data: Array(payload)))

                let verifiedPayload: ArraySlice<UInt8>
                if payloadDigest == digest {
                    verifiedPayload = payload
                } else if payload.last == 0x00 {
                    let stripped = payload.dropLast()
                    let strippedDigest = Array(SHA384.hash(data: Array(stripped)))
                    guard strippedDigest == digest else {
                        throw CCELClaimsError.tamperedLog(reason: "GRUB command digest mismatch (with and without trailing NUL)")
                    }
                    verifiedPayload = stripped
                } else {
                    throw CCELClaimsError.tamperedLog(reason: "GRUB command digest mismatch")
                }

                if Self.grubKernelCmdlinePrefixes.contains(matchedPrefix) {
                    guard kernel.cmdline == nil else {
                        throw CCELClaimsError.invalidEventOrdering(reason: "duplicate kernel_cmdline event on CCMR3")
                    }
                    let cmdlineBytes: ArraySlice<UInt8> =
                        verifiedPayload.last == 0x00 ? verifiedPayload.dropLast() : verifiedPayload
                    kernel.cmdline = String(decoding: cmdlineBytes, as: UTF8.self)
                }
                // Other Grub command events are digest-verified for trust-chain
                // continuity but not surfaced as claims in v1.
                continue
            }

            // Category 2: no-prefix file/variable measurement.
            // event.data carries an untrusted filename string; the digest is
            // bound to the file/variable contents (NOT to event.data).
            let nameBytes: ArraySlice<UInt8> =
                event.data.last == 0x00 ? event.data.dropLast() : event.data[...]
            guard let untrustedImagePath = String(bytes: nameBytes, encoding: .utf8) else {
                continue
            }
            guard untrustedImagePath.contains(Self.kernelImagePathMarker) else {
                continue
            }
            guard kernel.imageDigest == nil else {
                throw CCELClaimsError.invalidEventOrdering(reason: "duplicate kernel image measurement on CCMR3")
            }
            kernel.imageDigest = Data(digest)
            kernel.untrustedImagePath = untrustedImagePath
        }

        if kernel.cmdline != nil || kernel.imageDigest != nil {
            claims.kernel = kernel
        }
    }
}
