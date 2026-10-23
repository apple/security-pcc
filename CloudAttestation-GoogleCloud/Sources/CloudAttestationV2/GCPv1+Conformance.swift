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
//  GCPv1+Conformance.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Crypto
import Foundation
import GCPv1
import PrivateCloudCompute
import SwiftASN1
import Logging
import SwiftProtobuf
import SwiftTDX
import X509

// MARK: - KeyStore Conformance

extension GCPv1.KeyStore: KeyStore {
    public func generateKey(algorithm: Algorithm, lifespan: Duration) throws -> GCPv1.Key {
        let gcpAlgorithm: GCPv1.Algorithm = .with {
            $0.type = "kem"
            $0.params.kemID = algorithm.kemAlgorithm
        }
        return try generateKey(algorithm: gcpAlgorithm, lifespan: lifespan)
    }

    public var keys: [GCPv1.Key] {
        get throws {
            return try self.keyInfos.map { try self.key(for: $0) }
        }
    }
}

// MARK: - Key Conformance

extension GCPv1.Key: Key {
    private static let logger = Logger(label: "com.apple.CloudAttestation.GCPv1.KeyStore")

    public func decapsulate(ciphertext: Ciphertext) throws -> SharedSecret {
        let gcpCiphertext: GCPv1.Ciphertext = .with {
            $0.algorithm = ciphertext.algorithm.kemAlgorithm
            $0.ciphertext = ciphertext.ciphertext
        }
        let result = try decapsulate(ciphertext: gcpCiphertext)
        guard let algorithm = Algorithm(kemAlgorithm: result.algorithm) else {
            throw GCPv1Error.invalidLabel(String(describing: result.algorithm))
        }
        return SharedSecret(algorithm: algorithm, sharedSecret: result.secret)
    }

    public func attest(with transparencyProver: some TransparencyProver, nonce: Data?, appData: Data?) async throws -> AttestationBundle {
        // Fetch the platform certificate chain and a *fresh* certificate-transparency log head up front.
        // The log head's digest is bound into AttestedMetadata below so the head the node witnessed at
        // attest time is committed into the TDX quote — that is what lets a verifier establish freshness
        // from the log-assigned timestamp instead of a node-controlled one. Best-effort:
        // environments without certificate transparency yield empty proofs and simply omit the binding.
        // The same proofs are reused in the final bundle below.
        let platformCertChain = await loadPlatformCertificateChain()
        let ctProofs = try await fetchCTProofs(for: platformCertChain?.first, with: transparencyProver)

        // Build AttestedMetadata proto from nonce + appData, plus the CT log-head digest.
        var metadata = PrivateCloudCompute_AttestedMetadata()
        if let nonce {
            metadata.nonce = nonce
        }
        if let appData {
            metadata.appData = .with { $0.value = appData }
        }
        if ctProofs != ATLogProofs(), !ctProofs.inclusionProof.slh.object.isEmpty {
            // Digest of the *serialized LogHead* (not the merkle root): binding it commits the entire
            // log head — including its server timestamp — into the quote, so the verifier can trust
            // `timestampMs` without verifying the transparency log's signature.
            metadata.certificateTransparencyLogheadDigest = Data(SHA256.hash(data: ctProofs.inclusionProof.slh.object))
        }

        // Serialize and generate digest
        let serializedMetadata = try metadata.serializedData()
        let digest = Data(SHA256.hash(data: serializedMetadata))

        // Call WSD attestation service with the digest as challenge
        //
        // A zero-valued/mock host attestation must be left *off* the bundle
        // entirely: assigning it (even a default-initialized message) flips
        // the proto's `hasHostAttestation` presence bit to true, which drives
        // the claims generator down the bare-metal host path and emits empty
        // `hostTPM`/`host`/`hostCSEL` claims. The binding policy then treats
        // those empty-but-present sections as a real host attestation and
        // rejects the bundle for failing reconciliation. Keep it optional so
        // the mock/error cases leave `hasHostAttestation` false.
        let hostAttestation: HostAttestation?
        let endorsement = try attest(challenge: digest)
        do {
            let maybeHostAttestation = try keyStore.attestHost(challenge: digest)
            if maybeHostAttestation.challenge == digest || self.keyStore.forceEmitHostAttestations {
                hostAttestation = maybeHostAttestation
            } else {
                Self.logger.warning("mock host attestation detected, omitting host attestation from bundle")
                hostAttestation = nil
            }
        } catch {
            Self.logger.error("failed to create host attestation, omitting host attestation from bundle", metadata: ["error": "\(error)"])
            hostAttestation = nil
        }

        // Convert KeyEndorsement to AttestationBundle
        let gcpv1Attestation: PrivateCloudCompute_GCPv1Attestation = .with {
            $0.tdxWorkload = endorsement.vmProtectedKeyEndorsement.bindingKeyAttestation.attestation.proto
            $0.tdxKeyProtection = endorsement.vmProtectedKeyEndorsement.protectedKeyAttestation.attestation.proto
            $0.attestedMetadata = serializedMetadata
            if let hostAttestation {
                $0.hostAttestation = hostAttestation
            }
        }

        // Compute the Release digests (the bundle has no transparency proofs yet) so we can
        // request inclusion proofs for them. Self-validate through the canonical GCPv1 development pipeline
        let interimBundle = AttestationBundle(
            proto: .with {
                $0.attestationBundle = .gcpv1AttestationBundle(.with { $0.gcpv1Attestation = gcpv1Attestation })
            }
        )
        let validatedBundle = try await GCPv1Validator().validate(bundle: interimBundle, against: GCPv1Validator.structuralPolicy)

        let workloadRelease = try validatedBundle.workloadRelease()
        let workloadReleaseDigest = Data(SHA256.hash(data: try workloadRelease.derRepresentation))

        let firmwareRelease = try validatedBundle.firmwareRelease()
        let firmwareReleaseDigest = Data(SHA256.hash(data: try firmwareRelease.derRepresentation))

        Self.logger.info(
            "Fetching release transparency proofs",
            metadata: [
                "workloadReleaseDigest": .string(workloadReleaseDigest.hexString),
                "firmwareReleaseDigest": .string(firmwareReleaseDigest.hexString),
            ]
        )

        let releaseProofs = try await transparencyProver.proveInclusion(
            of: [workloadReleaseDigest, firmwareReleaseDigest],
            at: nil,
            coveringAll: .release,
            preferOldest: true
        )

        do {
            guard releaseProofs.count == 2 else {
                throw GCPv1AttestationError.insufficientTransparencyProofs(expected: 2, got: releaseProofs.count)
            }
        } catch {
            Self.logger.error(
                "Fewer transparency proofs than expected, attestation validation might fail",
                metadata: [
                    "expected": .stringConvertible(2),
                    "got": .stringConvertible(releaseProofs.count),
                ]
            )
        }

        let gcpv1AttestationBundle: PrivateCloudCompute_GCPv1AttestationBundle = .with {
            $0.gcpv1Attestation = gcpv1Attestation
            $0.platformCertificates = .with { $0.appleChain = platformCertChain ?? [] }
            $0.transparencyProofs = .with {
                $0.certificateTransparencyProofs = ctProofs
                if let workloadProof = releaseProofs[workloadReleaseDigest] {
                    $0.softwareTransparencyProofs = workloadProof
                }
                if let firmwareProof = releaseProofs[firmwareReleaseDigest] {
                    $0.firmwareTransparencyProofs = firmwareProof
                }
            }
        }

        let bundle: PrivateCloudCompute_AttestationBundle = .with {
            $0.attestationBundle = .gcpv1AttestationBundle(gcpv1AttestationBundle)
            $0.version = 2
        }
        return AttestationBundle(proto: bundle)
    }

    private func fetchCTProofs(for certDer: Data?, with transparencyProver: some TransparencyProver) async throws -> ATLogProofs {
        // return an empty proof structure if we couldn't load the cert leaf, deferring enforcement to the relying party's validation logic.
        guard let certDer else {
            Self.logger.warning("No platform leaf certificate available; returning empty certificate transparency proofs")
            return .init()
        }
        let fingerprint = Data(certDer.digest(using: SHA256.self))
        Self.logger.info(
            "Fetching certificate transparency proofs",
            metadata: ["fingerprint": .string(fingerprint.hexString)]
        )
        return try await transparencyProver.proveInclusion(of: fingerprint, at: nil, coveringAll: .serverNode, preferOldest: true)
    }

    func loadPlatformCertificateChain() async -> [Data]? {
        #if DEBUG
        if let strategy = self.keyStore.testAssetStrategy {
            Self.logger.debug("Loaded platform certificate chain from test asset strategy")
            return strategy.loadPlatformCertificateChain()
        }
        #endif
        if let data = FileManager.default.contents(atPath: "/var/run/cloudattestation/platformcertificate.pem") {
            let pemString = String(decoding: data, as: UTF8.self)
            guard let pems = try? PEMDocument.parseMultiple(pemString: pemString) else {
                Self.logger.warning(
                    "Failed to parse platform certificate chain from /var/run/cloudattestation/platformcertificate.pem; returning nil"
                )
                return nil
            }
            Self.logger.debug(
                "Loaded platform certificate chain from /var/run/cloudattestation/platformcertificate.pem",
                metadata: ["chainLength": .stringConvertible(pems.count)]
            )
            return pems.map { Data($0.derBytes) }
        }
        Self.logger.warning("No platform certificate available on disk at /var/run/cloudattestation/platformcertificate.pem")
        return nil
    }
}

enum GCPv1AttestationError: Error {
    case insufficientTransparencyProofs(expected: Int, got: Int)
    case missingPCKCertificate
}

// MARK: - Algorithm Bridging

extension Algorithm {
    fileprivate var kemAlgorithm: Keymanager_KemAlgorithm {
        switch self {
        case .dhkem_x25519_hkdf_sha256:
            return .dhkemX25519HkdfSha256
        }
    }

    fileprivate init?(kemAlgorithm: Keymanager_KemAlgorithm) {
        switch kemAlgorithm {
        case .dhkemX25519HkdfSha256:
            self = .dhkem_x25519_hkdf_sha256
        default:
            return nil
        }
    }
}

// MARK: - Attestation Conversion

extension GCPv1.Attestation {
    fileprivate var proto: ConfidentialSpace_VmAttestation {
        var vmAttestation = ConfidentialSpace_VmAttestation()
        vmAttestation.label = Data(label.rawValue.utf8)
        vmAttestation.challenge = challenge
        vmAttestation.extraData = extraData

        var tdxCcel = ConfidentialSpace_TdxCcelQuote()
        tdxCcel.ccelBootEventLog = quote.tdxCcelQuote.ccelBootEventLog
        tdxCcel.celLaunchEventLog = quote.tdxCcelQuote.celLaunchEventLog
        tdxCcel.tdQuote = quote.tdxCcelQuote.tdQuote

        var quoteWrapper = ConfidentialSpace_VmAttestationQuote()
        quoteWrapper.quote = .tdxCcelQuote(tdxCcel)
        vmAttestation.quote = quoteWrapper

        return vmAttestation
    }
}
