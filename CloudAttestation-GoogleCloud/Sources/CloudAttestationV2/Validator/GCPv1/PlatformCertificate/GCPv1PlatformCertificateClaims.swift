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
//  GCPv1Claims+PlatformCertificate.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import Logging
import X509
import Crypto

public struct GCPv1PlatformCertificateClaims: Claims.ValueProtocol {
    /// Whether or not the paltform certificate passed validation (signature and chain)
    public var verified: Bool
    /// the raw leaf Subject Public Key bytes.
    public var publicKey: Data?
    /// The SHA384 fingerprints of all certs in the chain except the leaf.
    public var trustChainFingerprints: [Data]?
    /// The full SubjectDN strings of all certs in the chain except the leaf.
    public var trustChainSubjects: [String]?
    /// The device identity manifest extracted from the X509v3 extension
    public var deviceIdentityManifest: GCPv1DeviceIdentityManifest?
}

extension GCPv1PlatformCertificateClaims {
    public struct Generator: ClaimsGenerator {
        private static let logger = Logger(label: "com.apple.CloudAttestation.GCPv1PlatformCertificateClaims.Generator")

        let certificateVerifier: GCPv1PlatformCertificate.Verifier

        public func generateClaims(for platformCertificates: PrivateCloudCompute_PlatformCertificates) async throws -> GCPv1PlatformCertificateClaims {
            var claim = GCPv1PlatformCertificateClaims(verified: false)

            let certs = platformCertificates.appleChain
            guard !certs.isEmpty else {
                Self.logger.debug("PlatformCertificates.appleChain is empty; leaving claim unverified")
                return claim
            }

            let x509Certs: [X509.Certificate]
            do {
                x509Certs = try certs.map { try X509.Certificate(derEncoded: [UInt8]($0)) }
            } catch {
                Self.logger.error(
                    "Failed to DER-decode platform certificate chain",
                    metadata: ["error": "\(error)", "certCount": .stringConvertible(certs.count)]
                )
                return claim
            }

            guard let leaf = x509Certs.first.map({ GCPv1PlatformCertificate($0) }) else {
                Self.logger.error("Decoded platform certificate chain unexpectedly had no leaf")
                return claim
            }

            let chain: ValidatedCertificateChain
            do {
                chain = try await certificateVerifier.verify(certificate: leaf, intermediates: x509Certs[1...])
            } catch {
                Self.logger.error(
                    "Platform certificate chain failed verification",
                    metadata: ["error": "\(error)"]
                )
                return claim
            }

            claim.verified = true
            claim.publicKey = Data(leaf.publicKey.subjectPublicKeyInfoBytes)
            claim.deviceIdentityManifest = leaf.deviceIdentityManifest

            // IMPORTANT: the trust-chain claims below are derived from `chain` — the
            // *verified* chain the verifier returned — never from `x509Certs`, which is
            // the caller-supplied `appleChain` input. Policy pins the root's SubjectDN and
            // fingerprint (`gcpv1.platformcertificate.trusted_roots`) to decide which CA
            // is acceptable per environment; sourcing these from the input would make that
            // pin attacker-controlled and reduce the whole check to theatre, while still
            // passing every existing test.
            do {
                claim.trustChainFingerprints = try chain.dropFirst().map { cert in
                    try Data(cert.derRepresentation.digest(using: SHA384.self))
                }
            } catch {
                // TODO: Log here, describing why fingerprint computation failed.
            }

            claim.trustChainSubjects = chain.dropFirst().map { $0.subject.canonicalString }

            return claim
        }
    }
}

// MARK: - Claims Value Protocol Conformance
extension GCPv1DeviceIdentityManifest: Claims.ValueProtocol {

}
