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
//  CSELClaims.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Crypto
import Foundation
import GCPv1
import Logging
import SwiftASN1
import SwiftEventLog
import SwiftTDX

// MARK: - CELClaims

/// Claims derived from a CEL (Canonical Event Log) launch log. Used for both
/// the confidential-VM workload CSEL (RTMR[3] / CCMR4, SHA-384) and the
/// bare-metal host launch log (PCR[19], SHA-256) — the register and bank differ,
/// the projection is the same.
///
/// Trust model — IMPORTANT for policy authors:
///
/// `replayedMeasurements` maps each hash bank present on the replayed register
/// to the value produced by replaying every CEL record that targets it. It is
/// NOT compared against the quote inside this generator — the generator has no
/// access to the quote. **Policy MUST verify that the relevant
/// `replayedMeasurements[bank]` equals the corresponding register from the quote
/// (e.g. `replayedMeasurements.sha384 == tdx.rtmr3`, or
/// `replayedMeasurements.sha256 == hostTPM.pcr19`) before trusting `gpus` or
/// `containerImageDigest`.**
///
/// Without that check, the log's contents an attacker could have chosen
/// freely; their digests would be authentic relative to the log, but the log
/// itself wouldn't be bound to the hardware quote. With the check, the log is
/// hardware-attested and the derived claims inherit that guarantee.
public struct CSELClaims: Codable, Claims.DefaultInitializableValue {
    private static let logger = Logger(label: "com.apple.CloudAttestation.CSELClaims")

    /// The replayed value of the target register, keyed by hash-bank name
    /// (`"sha256"`, `"sha384"`, `"sha512"`) — one entry per bank the CEL records
    /// carried. **Policy MUST verify the relevant bank equals the companion
    /// quote's register (`rtmr3` for the workload, `pcr19` for the host) before
    /// trusting any other field on this struct.**
    public var replayedMeasurements: [String: Data]? = nil

    /// Information and attestations over each installed GPU.
    public var gpus: [GPU]? = nil

    /// OCI container image digest (e.g. "sha256:a2e12...").
    public var containerImageDigest: String? = nil

    /// Attested environment variables set on the workload container.
    public var environmentVariables: [EnvironmentVariable]? = nil

    /// Attested environment variable overrides applied to the workload container.
    public var overrideEnvironmentVariables: [EnvironmentVariable]? = nil

    /// The `PCC_VARIANT` environment variable value, if present.
    public var pccVariant: String? = nil

    /// The `HOSTNAME` environment variable value, if present — the workload
    /// container's view of the machine it launched on.
    ///
    /// A triage label only, never an input to a decision: like every other field
    /// on this struct it is trustworthy only once policy has bound this log to
    /// hardware (see the trust model above), and the code that logs it does so on
    /// paths where that binding may be exactly what failed.
    ///
    /// Resolved like ``pccVariant``: an override entry wins over a base one, and a
    /// duplicated `HOSTNAME` at either level yields `nil` rather than an arbitrary
    /// pick.
    public var hostname: String? = nil

    /// The CPU Platform Instance ID — a 16-byte identifier extracted from the
    /// Host COS record preceding the launch separator on the bare-metal host's
    /// CEL launch log (PCR[19]). Matches GCP's `HostACOSState.CpuPiid` /
    /// `parseCPUPIID`. `nil` for the confidential-VM workload CSEL, which
    /// carries no Host COS records. Trustworthy only once policy has bound
    /// this log to hardware (`replayedMeasurements.sha256 == hostTPM.pcr19`).
    public var cpuPIID: Data? = nil

    public init() {}

    /// A convenience getter DER-encoded leaf certificates from each GPU's attestation certificate chain.
    /// Not part of a claim
    package var nvidiaLeafCertificates: [Data]? {
        guard let gpus else {
            return nil
        }
        return gpus.compactMap { gpu in
            let certChainData = gpu.attestationCertificateChain
            guard !certChainData.isEmpty else {
                return nil
            }

            let pemString = String(decoding: certChainData, as: UTF8.self)
            let pems: [PEMDocument]
            do {
                pems = try PEMDocument.parseMultiple(pemString: pemString)
            } catch {
                Self.logger.warning(
                    "Failed to parse GPU attestation certificate chain as PEM",
                    metadata: [
                        "gpuUUID": .string(gpu.uuid),
                        "error": .string(String(describing: error)),
                    ]
                )
                return nil
            }

            guard let leafPem = pems.first else {
                Self.logger.warning(
                    "GPU attestation certificate chain parsed but contained no PEM blocks",
                    metadata: ["gpuUUID": .string(gpu.uuid)]
                )
                return nil
            }

            return Data(leafPem.derBytes)
        }
    }
}

// MARK: - Environment Variable

extension CSELClaims {
    public struct EnvironmentVariable: Codable, Claims.ValueProtocol {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        /// Parses a `NAME=VALUE` string, splitting on the first `=`.
        /// Returns nil if there is no `=` (malformed).
        init?(rawEntry: String) {
            guard let separatorIndex = rawEntry.firstIndex(of: "=") else {
                return nil
            }
            self.name = String(rawEntry[..<separatorIndex])
            self.value = String(rawEntry[rawEntry.index(after: separatorIndex)...])
        }
    }
}

extension Collection<CSELClaims.EnvironmentVariable> {
    /// The value of the single entry named `name`, or `nil` when the name is absent
    /// or appears more than once — a duplicate is ambiguous, and picking one
    /// arbitrarily would let a second entry shadow the first.
    func uniqueValue(of name: String) -> String? {
        var found: String? = nil
        for entry in self where entry.name == name {
            guard found == nil else { return nil }
            found = entry.value
        }
        return found
    }
}

// MARK: - GPU Claim
extension CSELClaims {
    public struct GPU: Codable, Claims.ValueProtocol {
        public var uuid: String
        public var driverVersion: String
        public var vbiosVersion: String
        public var attestationCertificateChain: Data
        public var architecture: Architecture
        public var attestation: Data
        /// The nonce the platform declares it used for this GPU attestation,
        /// taken from the report-level `NvidiaAttestationReport.nonce` (shared
        /// across every GPU in the report). Fed into `Evidence` so verification
        /// enforces that it matches the GPU-signed SPDM response nonce; the
        /// authenticated value is surfaced separately on `NvidiaGPUClaims.nonce`.
        public var nonce: Data

        package init?(_ protoGpuInfo: ConfidentialSpace_GpuInfo, nonce: Data) {
            self.uuid = protoGpuInfo.uuid
            self.driverVersion = protoGpuInfo.driverVersion
            self.vbiosVersion = protoGpuInfo.vbiosVersion
            self.attestationCertificateChain = protoGpuInfo.attestationCertificateChain
            guard let arch = Architecture(protoGpuInfo.gpuArchitectureType) else {
                return nil
            }
            self.architecture = arch
            self.attestation = protoGpuInfo.attestationReport
            self.nonce = nonce
        }

        public enum Architecture: String, Codable, Claims.ValueProtocol {
            case hopper
            case blackwell

            init?(_ protoGpuArchitecture: ConfidentialSpace_GpuArchitectureType) {
                switch protoGpuArchitecture {
                case .hopper:
                    self = .hopper
                case .blackwell:
                    self = .blackwell
                default:
                    return nil
                }
            }

            public var product: String {
                switch self {
                case .hopper: "GH100"
                case .blackwell: "GB100"
                }
            }
        }
    }
}

// MARK: - Generator

extension CSELClaims {
    public struct Generator: ClaimsGenerator, Sendable {
        /// The register the replay targets. `.ccmr(4)` (= RTMR[3]) for the
        /// confidential-VM workload CSEL; `.pcr(19)` for the bare-metal host
        /// launch log.
        let index: CEL.Index

        public init(index: CEL.Index = .ccmr(4)) {
            self.index = index
        }

        /// Generates claims from a CEL launch log.
        ///
        /// If the log can't be parsed or replayed at all, returns empty claims;
        /// policy MUST verify `replayedMeasurements` is present and matches the
        /// quote before trusting any other field. Otherwise returns a
        /// `CSELClaims` with whichever fields could be extracted.
        public func generateClaims(for csel: CEL) throws -> CSELClaims {
            var claims = CSELClaims()

            let measurements: [String: Data]
            do {
                measurements = try Self.replayMeasurements(csel, index: index)
            } catch {
                CSELClaims.logger.error(
                    "CSEL replay failed; returning empty claims (policy binding will fail since replayedMeasurements is absent)",
                    metadata: ["error": .string(String(describing: error))]
                )
                return claims
            }
            claims.replayedMeasurements = measurements.isEmpty ? nil : measurements

            var gpus: [GPU]? = nil
            var envVars: [EnvironmentVariable] = []
            var overrideEnvVars: [EnvironmentVariable] = []

            // Trust only on-index records up to the launch separator: off-index
            // records aren't in the quote, and a guest can extend the register
            // after the separator. Mirrors `extractCPUPIID`.
            extraction: for record in csel where record.index == index {
                guard case .cos(let cos) = record.content,
                    let cosType = CosEventType(rawValue: cos.cosType)
                else {
                    continue
                }

                switch cosType {
                case .launchSeparator:
                    break extraction

                case .gpuDeviceAttestationBinding:
                    let report: ConfidentialSpace_NvidiaAttestationReport
                    do {
                        report = try ConfidentialSpace_NvidiaAttestationReport(serializedBytes: cos.eventContent)
                    } catch {
                        CSELClaims.logger.debug(
                            "Failed to decode NvidiaAttestationReport from CSEL GPU binding record",
                            metadata: [
                                "eventContentBytes": .stringConvertible(cos.eventContent.count),
                                "error": .string(String(describing: error)),
                            ]
                        )
                        continue
                    }
                    guard gpus == nil else {
                        throw CSELClaimsError.multipleGPUDeviceAttestationBindings
                    }
                    gpus = report.gpuInfos.compactMap { GPU($0, nonce: report.nonce) }

                case .imageDigest:
                    guard claims.containerImageDigest == nil else {
                        throw CSELClaimsError.multipleImageDigests
                    }
                    if let digest = String(bytes: cos.eventContent, encoding: .utf8) {
                        claims.containerImageDigest = digest
                    }

                case .envVar:
                    if let raw = String(bytes: cos.eventContent, encoding: .utf8),
                        let parsed = EnvironmentVariable(rawEntry: raw)
                    {
                        envVars.append(parsed)
                    }

                case .overrideEnv:
                    if let raw = String(bytes: cos.eventContent, encoding: .utf8),
                        let parsed = EnvironmentVariable(rawEntry: raw)
                    {
                        overrideEnvVars.append(parsed)
                    }

                default:
                    continue
                }
            }

            if let gpus {
                claims.gpus = gpus
            }
            if !envVars.isEmpty {
                claims.environmentVariables = envVars
            }
            if !overrideEnvVars.isEmpty {
                claims.overrideEnvironmentVariables = overrideEnvVars
            }

            claims.pccVariant = overrideEnvVars.uniqueValue(of: "PCC_VARIANT") ?? envVars.uniqueValue(of: "PCC_VARIANT")
            claims.hostname = overrideEnvVars.uniqueValue(of: "HOSTNAME") ?? envVars.uniqueValue(of: "HOSTNAME")

            claims.cpuPIID = Self.extractCPUPIID(from: csel, index: index)

            return claims
        }

        /// Hash banks this generator can replay. CEL records may also carry
        /// SHA-1/SM3 digests; those are out of scope and ignored.
        private static let replayableBanks: [(algorithm: SwiftEventLog.Algorithm, name: String)] = [
            (.sha256, "sha256"),
            (.sha384, "sha384"),
            (.sha512, "sha512"),
        ]

        /// Replays every CEL record targeting `index` into one register per hash
        /// bank present, returning `[bankName: replayedValue]`. A record on the
        /// target index that is missing a bank's digest is rejected (the replay
        /// for that bank cannot be trusted) rather than silently skipped.
        /// Records on other indices are out-of-scope.
        private static func replayMeasurements(_ eventLog: CEL, index: CEL.Index) throws -> [String: Data] {
            let targeted = eventLog.records.filter { $0.index == index }
            guard !targeted.isEmpty else { return [:] }

            var measurements: [String: Data] = [:]
            for (algorithm, name) in replayableBanks {
                guard targeted.contains(where: { record in record.digests.contains { $0.algorithm == algorithm } }) else {
                    continue
                }
                let digests = try targeted.map { record -> [UInt8] in
                    guard let digest = record.digests.first(where: { $0.algorithm == algorithm })?.data else {
                        throw CSELClaimsError.inconsistentDigests(bank: name)
                    }
                    // Bind content to the register: the digest is what gets
                    // replayed into the quote, so require H(content) == digest
                    // before trusting this record's content.
                    guard try record.contentTLVBytes.digest(using: algorithm).elementsEqual(digest) else {
                        throw CSELClaimsError.contentDigestMismatch(bank: name)
                    }
                    return digest
                }
                measurements[name] = try Self.replay(algorithm, digests: digests)
            }
            return measurements
        }

        /// Replays `digests` (in order) into a fresh register sized for `algorithm`.
        private static func replay(_ algorithm: SwiftEventLog.Algorithm, digests: [[UInt8]]) throws -> Data {
            switch algorithm {
            case .sha256: return try extend(ExtendableRegister<SHA256>(hashFunction: SHA256.self), digests)
            case .sha384: return try extend(ExtendableRegister<SHA384>(hashFunction: SHA384.self), digests)
            case .sha512: return try extend(ExtendableRegister<SHA512>(hashFunction: SHA512.self), digests)
            case .sha1, .sm3: throw CSELClaimsError.unsupportedBank
            }
        }

        private static func extend<Hash>(_ register: ExtendableRegister<Hash>, _ digests: [[UInt8]]) throws -> Data {
            var register = register
            for digest in digests {
                try register.extend(data: digest)
            }
            return Data(register)
        }

        /// Extracts the CPU Platform Instance ID from the Host COS records on
        /// `index`, mirroring GCP's `parseCPUPIID`: a `cpuPIID` record must
        /// appear exactly once, before the `launchSeparator`, and be exactly 16
        /// bytes. Unlike GCP's implementation, a record on `index` that isn't a
        /// recognized Host COS event is skipped rather than rejected outright —
        /// matching this generator's existing permissive record selection — and
        /// per-record digest verification is left to the replay binding rather
        /// than re-checked here. `nil` for logs without Host COS records (e.g.
        /// the confidential-VM workload CSEL).
        private static func extractCPUPIID(from cel: CEL, index: CEL.Index) -> Data? {
            var cpuPIID: [UInt8]? = nil
            var seenSeparator = false
            for record in cel where record.index == index {
                guard case .hostCOS(let hostCOS) = record.content,
                    let contentType = HostCOSContentType(rawValue: hostCOS.contentType)
                else {
                    continue
                }

                guard !seenSeparator else {
                    CSELClaims.logger.warning("Host COS event found after launch separator; discarding cpuPIID")
                    return nil
                }

                switch contentType {
                case .launchSeparator:
                    seenSeparator = true
                case .cpuPIID:
                    guard cpuPIID == nil else {
                        CSELClaims.logger.warning("Duplicate cpuPIID event on CEL launch log; discarding cpuPIID")
                        return nil
                    }
                    guard hostCOS.eventContent.count == Self.cpuPIIDSize else {
                        CSELClaims.logger.warning(
                            "cpuPIID event had unexpected length; discarding cpuPIID",
                            metadata: ["length": .stringConvertible(hostCOS.eventContent.count)]
                        )
                        return nil
                    }
                    cpuPIID = hostCOS.eventContent
                }
            }

            guard seenSeparator, let cpuPIID else { return nil }
            return Data(cpuPIID)
        }

        private static let cpuPIIDSize = 16
    }
}

// MARK: - Errors
enum CSELClaimsError: Error {
    case multipleGPUDeviceAttestationBindings
    /// More than one `imageDigest` on the replayed index before the separator; a
    /// genuine log carries exactly one.
    case multipleImageDigests
    /// A record on the replayed index was missing the named bank's digest, or
    /// `extend` rejected a wrong-length digest.
    case inconsistentDigests(bank: String)
    /// A record's content did not hash to its own digest (`H(content) != digest`)
    /// for the named bank, so the content isn't bound to the quoted register.
    case contentDigestMismatch(bank: String)
    /// A replayable bank dispatched to an algorithm with no register backing.
    case unsupportedBank
}

// MARK: - NVIDIA Leaf Certificates

extension ConfidentialSpace_NvidiaAttestationReport {
    /// Extracts the DER-encoded leaf certificate from each GPU's attestation certificate chain.
    package func leafCertificates() throws -> [Data] {
        try gpuInfos.compactMap { gpuInfo in
            let certChainData = gpuInfo.attestationCertificateChain
            guard !certChainData.isEmpty else {
                return nil
            }

            let pemString = String(decoding: certChainData, as: UTF8.self)
            let pems = try PEMDocument.parseMultiple(pemString: pemString)

            guard let leafPem = pems.first else {
                return nil
            }

            return Data(leafPem.derBytes)
        }
    }
}
