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
//  GCPv1+ClaimsGenerator.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import Crypto
import Common
import Logging
import Metrics
import SwiftNVAttestation
import GCPv1
import PrivateCloudCompute

extension Counter {
    enum TransparencyClaimKind: String, CaseIterable {
        case certificate, software, firmware
    }

    enum TransparencyClaimFailReason: String, CaseIterable {
        case missing = "nil"
        case unverified
    }

    private static let gcpv1TransparencyClaimFailureCounters: [TransparencyClaimKind: [TransparencyClaimFailReason: Counter]] = {
        let label = "cloudattestation_transparency_claim_failure"
        var table: [TransparencyClaimKind: [TransparencyClaimFailReason: Counter]] = [:]
        for kind in TransparencyClaimKind.allCases {
            var inner: [TransparencyClaimFailReason: Counter] = [:]
            for reason in TransparencyClaimFailReason.allCases {
                inner[reason] = Counter(
                    label: label,
                    dimensions: [("type", kind.rawValue), ("reason", reason.rawValue)]
                )
            }
            table[kind] = inner
        }
        return table
    }()

    static func gcpv1TransparencyClaimFailure(_ kind: TransparencyClaimKind, reason: TransparencyClaimFailReason) -> Counter {
        gcpv1TransparencyClaimFailureCounters[kind]![reason]!
    }
}

public struct GCPv1Claims {}

// MARK: - Diagnostics

extension Claims {
    /// A short, human-meaningful label for the machine these claims describe, for use in log
    /// metadata so a failure can be attributed to a node. `nil` when no claim carries one.
    ///
    /// UNTRUSTED — a triage label, never an input to a decision. On GCPv1 this resolves to the
    /// workload container's attested `HOSTNAME`, which is only bound to hardware once policy has
    /// reconciled `workloadCSEL.replayedMeasurements.sha384` against `workloadTDX.rtmr3`; the
    /// callers that log it do so on paths where the bundle was *rejected*, so that binding may be
    /// exactly what failed.
    ///
    /// Lives here rather than in the policy engines so they stay free of bundle-specific claim
    /// knowledge; other bundle shapes can extend the resolution chain as they gain an equivalent.
    package var attestedNodeLabel: String? {
        // Explicit `self` is required: implicit member lookup doesn't route through
        // `Claims`'s `@dynamicMemberLookup` subscript.
        self.workloadCSEL?.hostname
    }
}

// MARK: - Registered Keys

extension Claims.RegisteredKeys {
    public static let workloadTDX = Claims.RegisteredKey<TDXClaims>(name: "workloadTDX")
    public static let workloadCCEL = Claims.RegisteredKey<CCELClaims>(name: "workloadCCEL")
    public static let workloadPCK = Claims.RegisteredKey<PCKCertificateClaims>(name: "workloadPCK")
    public static let workloadCSEL = Claims.RegisteredKey<CSELClaims>(name: "workloadCSEL")
    public static let workloadGPUs = Claims.RegisteredKey<[NvidiaGPUClaims]>(name: "workloadGPUs")

    public static let keyProtectionTDX = Claims.RegisteredKey<TDXClaims>(name: "keyProtectionTDX")
    public static let keyProtectionCCEL = Claims.RegisteredKey<CCELClaims>(name: "keyProtectionCCEL")
    public static let keyProtectionPCK = Claims.RegisteredKey<PCKCertificateClaims>(name: "keyProtectionPCK")

    public static let hostTPM = Claims.RegisteredKey<TPMClaims>(name: "hostTPM")
    public static let host = Claims.RegisteredKey<HostClaims>(name: "host")
    public static let hostCSEL = Claims.RegisteredKey<CSELClaims>(name: "hostCSEL")
    public static let hostAuxiliary = Claims.RegisteredKey<AuxiliaryClaims>(name: "hostAuxiliary")

    public static let protobuf = Claims.RegisteredKey<GCPv1Claims.ProtobufClaims>(name: "protobuf")

    public static let certificateTransparency = Claims.RegisteredKey<TransparencyClaims>(name: "certificateTransparency")
    public static let softwareTransparency = Claims.RegisteredKey<TransparencyClaims>(name: "softwareTransparency")
    public static let firmwareTransparency = Claims.RegisteredKey<TransparencyClaims>(name: "firmwareTransparency")

    public static let platformCertificate = Claims.RegisteredKey<GCPv1PlatformCertificateClaims>(name: "platformCertificate")
    public static let computedDeviceIdentityManifest = Claims.RegisteredKey<GCPv1DeviceIdentityManifest>(name: "computedDeviceIdentityManifest")
}

extension GCPv1Claims {
    /// Claims originating directly from selecting/parsing protobuf fields.
    public struct ProtobufClaims: Claims.ValueProtocol {
        /// `SHA512(label || SHA512(challenge || SHA5125(extra_data)))`
        public var workloadReportDataDigest: Data? = nil
        public var workloadBindingPublicKey: Data? = nil

        /// `SHA512(label || SHA512(challenge || SHA5125(extra_data)))`
        public var keyProtectionReportDataDigest: Data? = nil
        public var keyProtectionBindingPublicKey: Data? = nil

        /// The raw `HostAttestation.challenge` the TPM was asked to quote over.
        /// Unlike the TDX report-data digests above, the host quote binds the
        /// challenge *directly* — real Titan captures set `TPMS_ATTEST.extraData`
        /// equal to these bytes verbatim, not to the `SHA256(label || ...)`
        /// derivation the Confidential Space proto documents. Policy reconciles
        /// this against `hostTPM.extraData` to bind the signed quote to the
        /// bundle's declared host challenge. `nil` when no host TPM quote is
        /// present.
        public var hostChallenge: Data? = nil

        /// The raw `VmAttestation.challenge` bytes each TDX quote was taken over.
        /// The `*ReportDataDigest` fields above already prove these challenges are
        /// in the signed quotes; surfacing them raw lets policy additionally bind
        /// them to ``attestedMetadataDigest``.
        public var workloadChallenge: Data? = nil
        public var keyProtectionChallenge: Data? = nil

        /// `SHA256` of the serialized `AttestedMetadata` blob the caller attached
        /// (`GCPv1Attestation.attested_metadata`). At attestation time this digest
        /// is the challenge signed into every TDX/host quote, so policy reconciles
        /// it against ``workloadChallenge`` / ``keyProtectionChallenge`` /
        /// ``hostChallenge`` to authenticate the caller's `nonce`+`appData`
        /// envelope. Always populated — an empty (unattached) envelope still hashes
        /// to a fixed digest (`SHA256("")`), which the quote challenges also carry —
        /// so the binding is always enforced and the envelope cannot be dropped or
        /// tampered with undetected.
        public var attestedMetadataDigest: Data? = nil

        /// The caller-supplied `AttestedMetadata.nonce`, surfaced so policy can
        /// reconcile it against a caller-provided expected nonce
        /// (``ValidatorOptions/nonce``, injected as `input.nonce`). `nil` when no
        /// metadata was attached or its nonce field is empty.
        public var attestedNonce: Data? = nil
    }
}

extension GCPv1Claims {
    public struct Generator: ClaimsGenerator {
        private static let logger = Logger(label: "com.apple.CloudAttestation.GCPv1Claims.Generator")

        var transparencyVerifier: TransparencyVerifier & Sendable
        var certificateVerifier: any GCPv1PlatformCertificate.Verifier

        package init() {
            self.transparencyVerifier = NopTransparencyLog()
            self.certificateVerifier = Self.makePlatformCertificateVerifier()
        }

        public init(transparencyVerifier: TransparencyVerifier & Sendable) {
            self.transparencyVerifier = transparencyVerifier
            self.certificateVerifier = Self.makePlatformCertificateVerifier()
        }

        init(transparencyVerifier: TransparencyVerifier & Sendable, certificateVerifier: any GCPv1PlatformCertificate.Verifier) {
            self.transparencyVerifier = transparencyVerifier
            self.certificateVerifier = certificateVerifier
        }

        public func generateClaims(for bundle: AttestationBundle) async throws -> Claims {
            var claims = Claims()
            claims.generator = self.name
            claims.workloadTDX = TDXClaims()
            claims.keyProtectionTDX = TDXClaims()
            claims.workloadCCEL = CCELClaims()
            claims.keyProtectionCCEL = CCELClaims()

            switch bundle.proto.attestationBundle {
            case .gcpv1AttestationBundle(let gcpBundle):
                var protobufClaims = ProtobufClaims()
                let tdxWorkload = bundle.proto.gcpv1AttestationBundle.gcpv1Attestation.tdxWorkload
                protobufClaims.workloadChallenge = tdxWorkload.challenge
                protobufClaims.workloadReportDataDigest = reportDataDigest(
                    label: tdxWorkload.label,
                    challenge: tdxWorkload.challenge,
                    extraData: tdxWorkload.extraData
                )

                if let workloadKeyClaims = try? Keymanager_KeyClaims(serializedBytes: tdxWorkload.extraData) {
                    if case let .vmBindingClaims(vmBindingClaims) = workloadKeyClaims.claims {
                        protobufClaims.workloadBindingPublicKey = vmBindingClaims.bindingPubKey.publicKey
                    }
                } else if !tdxWorkload.extraData.isEmpty {
                    Self.logger.debug(
                        "Failed to decode Keymanager_KeyClaims from workload extraData; workloadBindingPublicKey will be nil",
                        metadata: ["extraDataBytes": .stringConvertible(tdxWorkload.extraData.count)]
                    )
                }

                let tdxKeyProtection = bundle.proto.gcpv1AttestationBundle.gcpv1Attestation.tdxKeyProtection
                protobufClaims.keyProtectionChallenge = tdxKeyProtection.challenge
                protobufClaims.keyProtectionReportDataDigest = reportDataDigest(
                    label: tdxKeyProtection.label,
                    challenge: tdxKeyProtection.challenge,
                    extraData: tdxKeyProtection.extraData
                )
                if let keyProtectionKeyClaims = try? Keymanager_KeyClaims(serializedBytes: tdxKeyProtection.extraData) {
                    if case let .vmKeyClaims(vmKeyClaims) = keyProtectionKeyClaims.claims {
                        protobufClaims.keyProtectionBindingPublicKey = vmKeyClaims.bindingPubKey.publicKey
                    }
                } else if !tdxKeyProtection.extraData.isEmpty {
                    Self.logger.debug(
                        "Failed to decode Keymanager_KeyClaims from key-protection extraData; keyProtectionBindingPublicKey will be nil",
                        metadata: ["extraDataBytes": .stringConvertible(tdxKeyProtection.extraData.count)]
                    )
                }

                // Caller-attached metadata envelope. At attestation time the
                // challenge signed into every quote is `SHA256(serialized
                // AttestedMetadata{nonce, appData})` — computed even when the caller
                // attached nothing, since an empty envelope still hashes to a fixed
                // digest. Always surface that digest so policy can bind it to every
                // quote challenge: tampering with (or dropping) `attested_metadata`
                // changes the digest and breaks the binding, so the envelope cannot
                // be stripped undetected. The nonce is surfaced only when present.
                let attestedMetadata = bundle.proto.gcpv1AttestationBundle.gcpv1Attestation.attestedMetadata
                protobufClaims.attestedMetadataDigest = Data(SHA256.hash(data: attestedMetadata))
                if let metadata = try? PrivateCloudCompute_AttestedMetadata(serializedBytes: attestedMetadata), !metadata.nonce.isEmpty {
                    protobufClaims.attestedNonce = metadata.nonce
                }

                claims.protobuf = protobufClaims

                let tdxGenerator = TDXClaims.Generator()

                // TDX Workload

                let workloadTDXClaims = try await tdxGenerator.generateClaims(for: gcpBundle.gcpv1Attestation.tdxWorkload.quote.tdxCcelQuote.tdQuote)
                claims.workloadTDX = workloadTDXClaims

                // TDX Key Protection

                let keyProtectionTDXClaims = try await tdxGenerator.generateClaims(for: gcpBundle.gcpv1Attestation.tdxKeyProtection.quote.tdxCcelQuote.tdQuote)
                claims.keyProtectionTDX = keyProtectionTDXClaims

                // Workload CCEL, verified by TDX Workload's RTMRs

                let workloadCCELGenerator = CCELClaims.Generator()
                let workloadCCELClaims = try await workloadCCELGenerator.generateClaims(for: gcpBundle.gcpv1Attestation.tdxWorkload.quote.tdxCcelQuote.ccelBootEventLog)
                claims.workloadCCEL = workloadCCELClaims

                // Key Protection CCEL, verified by TDX Key Protection's RTMRs

                let keyProtectionCCELGenerator = CCELClaims.Generator()
                let keyProtectionCCELClaims = try await keyProtectionCCELGenerator.generateClaims(
                    for: gcpBundle.gcpv1Attestation.tdxKeyProtection.quote.tdxCcelQuote.ccelBootEventLog
                )
                claims.keyProtectionCCEL = keyProtectionCCELClaims

                // Workload PCK Certificate Claims, verified by TDX attestation
                if let workloadPCKCertificate = workloadTDXClaims.pckCertificate {
                    do {
                        claims.workloadPCK = try await PCKCertificateClaims.Generator().generateClaims(for: workloadPCKCertificate)
                    } catch {
                        Self.logger.debug(
                            "Workload PCK certificate claims generation failed; claim left nil",
                            metadata: ["error": .string(String(describing: error))]
                        )
                    }
                }

                // KeyProtection PCK Certificate Claims, verified by TDX attestation
                if let keyProtectionPCKCertificate = keyProtectionTDXClaims.pckCertificate {
                    do {
                        claims.keyProtectionPCK = try await PCKCertificateClaims.Generator().generateClaims(for: keyProtectionPCKCertificate)
                    } catch {
                        Self.logger.debug(
                            "Key-protection PCK certificate claims generation failed; claim left nil",
                            metadata: ["error": .string(String(describing: error))]
                        )
                    }
                }

                // Device Identity (GPU leaf certificate digests from CSEL launch event log)
                let cselClaims = try await CSELClaims.Generator().generateClaims(
                    for: gcpBundle.gcpv1Attestation.tdxWorkload.quote.tdxCcelQuote.cselLaunchEventLog
                )
                claims.workloadCSEL = cselClaims

                // GPU Claims, sourced from ratcheted attestations in the CSEL.
                if let cselGPUs = cselClaims.gpus {
                    claims.workloadGPUs = try await NvidiaGPUClaims.Generator().generateClaims(forCSELGPUs: cselGPUs)
                }

                // Host Attestation — bare-metal host. The TPM quote structure,
                // the PC Client boot event log, and the CEL launch log are
                // projected into separate claims (TPMClaims / HostClaims /
                // CSELClaims); policy reconciles `host.replayedPCRn == hostTPM.pcrN`
                // and `hostCSEL.replayedMeasurements.sha256 == hostTPM.pcr19`,
                // mirroring CCEL/CSEL↔TDX.
                //
                // Require an actual TPM quote, not merely `hasHostAttestation`:
                // a zero-valued/mock HostAttestation still reports present but
                // has no quote, and would otherwise yield empty `{}` host
                // claims that the binding policy misreads as a real host
                // attestation failing reconciliation.
                if gcpBundle.gcpv1Attestation.hasHostAttestation, gcpBundle.gcpv1Attestation.hostAttestation.hasTpmQuote {
                    let hostAttestation = gcpBundle.gcpv1Attestation.hostAttestation
                    let tpmQuote = hostAttestation.tpmQuote
                    claims.protobuf?.hostChallenge = hostAttestation.challenge
                    claims.hostTPM = try await TPMClaims.Generator().generateClaims(for: tpmQuote)
                    claims.host = try await HostClaims.Generator().generateClaims(for: tpmQuote.pcclientBootEventLog)
                    claims.hostCSEL = try await CSELClaims.Generator(index: .pcr(HostPCR.launch)).generateClaims(for: tpmQuote.celLaunchEventLog)
                    // Auxiliary NV attestations (e.g. the Titan warm-reset
                    // counter) — a sibling of the quote, signed separately by
                    // the same endorsed EK. Only emitted when the attestation
                    // actually carries some, so an absent claim stays absent
                    // rather than becoming a truthy empty `{}` in Rego.
                    if !hostAttestation.auxAttestation.signedNvs.isEmpty {
                        claims.hostAuxiliary = try await AuxiliaryClaims.Generator().generateClaims(for: hostAttestation)
                    }
                }

                // Device Identity Manifest computed from the attestation evidence, mirroring
                // ``Validated/AttestationBundle/deviceIdentityManifest()``: the Intel identity is
                // the TDX quote's PCK certificate, the NVIDIA identities are the GPU attestation
                // leaf certificates from the CSEL, and the Google identity is the Titan DICE
                // DeviceID certificate from the bare-metal host's TPM quote (absent on
                // non-Bowcaster bundles, which carry no host attestation).
                claims.computedDeviceIdentityManifest = GCPv1DeviceIdentityManifest(
                    googleIdentityDigest: claims.hostTPM?.titanDeviceIdentity.map { Data(SHA384.hash(data: $0)) },
                    intelIdentityDigest: workloadTDXClaims.pckCertificate.map { Data(SHA384.hash(data: $0)) },
                    nvidiaIdentityDigest: cselClaims.nvidiaLeafCertificates?.map { Data(SHA384.hash(data: $0)) }
                )

                // Platform Certificate Claims
                if bundle.proto.gcpv1AttestationBundle.hasPlatformCertificates {
                    let platCertClaims = try await GCPv1PlatformCertificateClaims.Generator(certificateVerifier: self.certificateVerifier).generateClaims(
                        for: bundle.proto.gcpv1AttestationBundle.platformCertificates
                    )
                    claims.platformCertificate = platCertClaims
                }

                // Transparency Claims
                let transparencyGenerator = TransparencyClaims.Generator(transparencyVerifier: self.transparencyVerifier)
                if let certHash = bundle.proto.gcpv1AttestationBundle.platformCertificates.appleChain.first.flatMap({ leafCert in
                    SHA256.hash(data: leafCert)
                }) {
                    let ctProofs = bundle.proto.gcpv1AttestationBundle.transparencyProofs.certificateTransparencyProofs
                    var ctClaims = try await transparencyGenerator.generateClaims(
                        for: (digest: Data(certHash), proofs: ctProofs, type: .certificate)
                    )
                    populateLogHeadFreshness(&ctClaims, gcpAttestation: gcpBundle.gcpv1Attestation, ctProofs: ctProofs)
                    claims.certificateTransparency = ctClaims
                    if ctClaims.verified != true {
                        Self.logger.warning("Certificate transparency proof did not verify; certificateTransparency claim marked unverified")
                        Counter.gcpv1TransparencyClaimFailure(.certificate, reason: .unverified).increment()
                    }
                } else {
                    Self.logger.warning("No platform leaf certificate available; certificateTransparency claim left nil")
                    Counter.gcpv1TransparencyClaimFailure(.certificate, reason: .missing).increment()
                }

                let swRelease: Data?
                do {
                    swRelease = Data(try ReleaseV2.workload(bundle: bundle, claims: claims).digest())
                } catch {
                    if case DeviceIdentityManifestError.heterogeneousGPUMeasurements = error {
                        Self.logger.error(
                            "Workload release derivation failed: GPUs report inconsistent SPDM measurement content; softwareTransparency claim will be left nil",
                            metadata: ["error": .string(String(describing: error))]
                        )
                    } else {
                        Self.logger.warning(
                            "Workload release derivation failed; softwareTransparency claim will be left nil",
                            metadata: ["error": .string(String(describing: error))]
                        )
                    }
                    swRelease = nil
                }
                if let swRelease {
                    let swTransparencyClaims = try await transparencyGenerator.generateClaims(
                        for: (digest: swRelease, proofs: bundle.proto.gcpv1AttestationBundle.transparencyProofs.softwareTransparencyProofs, type: .software)
                    )
                    claims.softwareTransparency = swTransparencyClaims
                    if swTransparencyClaims.verified != true {
                        Self.logger.warning("Software transparency proof did not verify; softwareTransparency claim marked unverified")
                        Counter.gcpv1TransparencyClaimFailure(.software, reason: .unverified).increment()
                    }
                } else {
                    Self.logger.warning("Workload release digest unavailable; softwareTransparency claim left nil")
                    Counter.gcpv1TransparencyClaimFailure(.software, reason: .missing).increment()
                }

                let fwRelease: Data?
                do {
                    fwRelease = Data(try ReleaseV2.firmware(bundle: bundle, claims: claims).digest())
                } catch {
                    if case DeviceIdentityManifestError.heterogeneousGPUMeasurements = error {
                        Self.logger.error(
                            "Firmware release derivation failed: GPUs report inconsistent SPDM measurement content; firmwareTransparency claim will be left nil",
                            metadata: ["error": .string(String(describing: error))]
                        )
                    } else {
                        Self.logger.warning(
                            "Firmware release derivation failed; firmwareTransparency claim will be left nil",
                            metadata: ["error": .string(String(describing: error))]
                        )
                    }
                    fwRelease = nil
                }
                if let fwRelease {
                    let fwTransparencyClaims = try await transparencyGenerator.generateClaims(
                        for: (digest: fwRelease, proofs: bundle.proto.gcpv1AttestationBundle.transparencyProofs.firmwareTransparencyProofs, type: .firmware)
                    )
                    claims.firmwareTransparency = fwTransparencyClaims
                    if fwTransparencyClaims.verified != true {
                        Self.logger.warning("Firmware transparency proof did not verify; firmwareTransparency claim marked unverified")
                        Counter.gcpv1TransparencyClaimFailure(.firmware, reason: .unverified).increment()
                    }
                } else {
                    Self.logger.warning("Firmware release digest unavailable; firmwareTransparency claim left nil")
                    Counter.gcpv1TransparencyClaimFailure(.firmware, reason: .missing).increment()
                }

                extractValidatorOutput(from: gcpBundle, into: &claims)
            default:
                break
            }

            return claims
        }

        private func extractValidatorOutput(
            from gcpBundle: PrivateCloudCompute_GCPv1AttestationBundle,
            into claims: inout Claims
        ) {
            let extraData = gcpBundle.gcpv1Attestation.tdxKeyProtection.extraData
            let keyClaims = try? Keymanager_KeyClaims(serializedBytes: extraData)
            switch keyClaims?.claims {
            case .vmKeyClaims(let vmProtectionKeyClaims):
                let publicKey = vmProtectionKeyClaims.kemPubKey
                switch publicKey.algorithm {
                case .dhkemX25519HkdfSha256:
                    // Clamp the reported expiration to the earliest of: the key's own lifetime, each
                    // present transparency leaf expiry, and — when a CT log head is bound — the freshness
                    // horizon (logHeadTimestamp + 72h). This keeps the cached trust window from outliving
                    // the proofs or the freshness gate (`gcpv1.transparency.certificate_loghead_fresh`), so
                    // a compute node's self-validation catches an attestation that won't survive its
                    // expected lifetime.
                    var expiration = Date(timeIntervalSince1970: vmProtectionKeyClaims.expirationTime)
                    let logHeadHorizon = claims.certificateTransparency?.logHeadTimestamp?.addingTimeInterval(Self.logHeadMaxAge)
                    for candidate in [
                        claims.certificateTransparency?.expiresAt,
                        claims.softwareTransparency?.expiresAt,
                        claims.firmwareTransparency?.expiresAt,
                        logHeadHorizon,
                    ] {
                        if let candidate, candidate < expiration {
                            expiration = candidate
                        }
                    }
                    claims.output = OutputClaims(
                        publicKey: .curve25519(publicKey.publicKey),
                        expiration: expiration
                    )
                default:
                    return
                }
            default:
                return
            }
        }

        /// Freshness horizon applied to a bound certificate-transparency log head when clamping the
        /// reported expiration. MUST stay in sync with `loghead_max_age_ns` (72h) in
        /// `gcpv1/transparency/certificate.rego`.
        private static let logHeadMaxAge: TimeInterval = 72 * 60 * 60

        /// Computes `SHA512(label || SHA512(challenge || SHA512(extraData)))`, the report-data digest binding
        /// the VM attestation's label, challenge, and extra data into the TDX quote's REPORTDATA field.
        private func reportDataDigest(label: Data, challenge: Data, extraData: Data) -> Data {
            let extraDataDigest = Data(SHA512.hash(data: extraData))
            let innerDigest = Data(SHA512.hash(data: challenge + extraDataDigest))
            return Data(SHA512.hash(data: label + innerDigest))
        }

        /// Establishes certificate-transparency log-head freshness for the bundle.
        ///
        /// At attest time the node binds the digest of the certificate-transparency log head it witnessed
        /// into `AttestedMetadata.certificate_transparency_loghead_digest`. That digest rides into the TDX
        /// quote's REPORTDATA (the whole `AttestedMetadata` is bound — enforced generally by the
        /// `metadata_bound` binding gate), so the log head — and its log-assigned `timestampMs` — is
        /// authenticated by the quote without verifying the transparency log's own signature. This surfaces
        /// that server timestamp so policy can gate freshness against a server-controlled clock rather than
        /// a node-controlled one (e.g. the key's expiry).
        ///
        /// The binding is optional: when the metadata carries no log-head digest the claim fields stay
        /// `nil` and policy treats the bundle leniently. When a digest *is* present it must match the
        /// carried signed log head, otherwise `logHeadTimestamp` is left `nil` while `logHeadDigestBound`
        /// is `true`, which policy rejects. (The metadata↔quote binding itself is gated separately.)
        private func populateLogHeadFreshness(
            _ claim: inout TransparencyClaims,
            gcpAttestation: PrivateCloudCompute_GCPv1Attestation,
            ctProofs: ATLogProofs
        ) {
            guard let metadata = try? PrivateCloudCompute_AttestedMetadata(serializedBytes: gcpAttestation.attestedMetadata),
                !metadata.certificateTransparencyLogheadDigest.isEmpty
            else {
                // No log-head binding present — nothing to surface; policy handles the absent case.
                return
            }

            // A binding is claimed; record it so policy enforces freshness even if the match below fails.
            claim.logHeadDigestBound = true

            // The bound digest must match the certificate-transparency log head we carry. The digest covers
            // the entire serialized LogHead, so a match authenticates its timestampMs through the metadata↔
            // quote binding enforced by the `metadata_bound` policy gate.
            let slhObject = ctProofs.inclusionProof.slh.object
            guard !slhObject.isEmpty,
                Data(SHA256.hash(data: slhObject)) == metadata.certificateTransparencyLogheadDigest,
                let logHead = try? LogHead(serializedBytes: slhObject),
                logHead.timestampMs > 0
            else {
                Self.logger.warning("Certificate transparency log-head digest does not match the carried signed log head; freshness unavailable")
                return
            }

            claim.logHeadTimestamp = Date(timeIntervalSince1970: Double(logHead.timestampMs) / 1000)
        }
    }
}

// MARK: - Helper extenstions

extension Evidence {
    init(_ cselGPU: CSELClaims.GPU) {
        let arch = cselGPU.architecture.rawValue.uppercased()
        let certificate = cselGPU.attestationCertificateChain
        let evidence = cselGPU.attestation

        // Feed the declared report nonce (hex-encoded, as `Evidence` expects) so
        // verification enforces it matches the GPU-signed SPDM response nonce. An
        // empty nonce hex-encodes to "" and preserves the skip-when-absent behavior.
        self.init(arch: arch, certificate: certificate, evidence: evidence, nonce: cselGPU.nonce.hexString)
    }
}

// MARK: - Platform Specific Certificate Verifiers

extension GCPv1Claims.Generator {
    /// Builds the platform-certificate chain verifier over ``AppleTrustAnchors/recognized``.
    /// The anchor set is intentionally not a parameter — see ``AppleTrustAnchors``.
    static func makePlatformCertificateVerifier() -> some GCPv1PlatformCertificate.Verifier {
        #if canImport(Security) && (os(macOS) || os(iOS))
        return GCPv1PlatformCertificate.SecTrustVerifier(roots: AppleTrustAnchors.recognized)
        #else
        return GCPv1PlatformCertificate.X509Verifier(roots: AppleTrustAnchors.recognized)
        #endif
    }
}
