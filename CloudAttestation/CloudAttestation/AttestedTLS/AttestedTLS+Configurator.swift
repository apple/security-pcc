// Copyright © 2025 Apple Inc. All Rights Reserved.

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
//  AttestedTLS+Configurator.swift
//  CloudAttestation
//
//  Copyright © 2025 Apple Inc. All rights reserved.
//

import Network
@preconcurrency import Security
import Security_Private.SecIdentityPriv
import os.log
import Synchronization

extension AttestedTLS {
    public struct Configurator<Attestor: CloudAttestation.Attestor>: Sendable {
        let logger = Logger(subsystem: "com.apple.CloudAttestation", category: "AttestedTLS.Configurator")

        let attestor: Attestor
        let keyType: KeyType
        let lifetime: Duration
        let storage: IdentityStorage

        /// An optional callback that is called when a TLS session could not be established due to a certificate or attestation verification failure.
        /// This can be useful for debugging since you would normally get an opaque "invalid certificate" error from Security/Networking layer.
        public var errorHandler: (@Sendable (any Swift.Error) -> Void)?

        /// Initializes the Configurator, creating an initial Attestation and SecIdentity using the given parameters
        /// - Parameters:
        ///   - keyType: the type of Asymmetric keypair to use. Defaults to P-384
        ///   - attestor: the CloudAttestation Attestor object used to generate Attestations
        ///   - lifetime: the lifetime of the Identity Certificate and Attestation. Defaults to 1 hour.
        public init(using keyType: KeyType = .p384, with attestor: Attestor, lifetime: Duration = .seconds(60) * 60) async throws {
            if case .curve25519 = keyType {
                logger.error("Curve25519 keys not yet supported")
                throw Error.privateKeyGenerationFailure
            }
            self.attestor = attestor
            self.keyType = keyType
            self.lifetime = lifetime
            self.storage = try await .init(Self.createIdentity(using: keyType, with: attestor, lifetime: lifetime))
        }

        /// Creates a new NWProtocolTLS.Options object configured for Attested mTLS.
        /// Will refresh the Attestation and SecIdentity if it has expired. It will not refresh any earlier, it is highly recommended to call ``refresh()`` before expiration.
        public func createTLSOptions<Validator: CloudAttestation.Validator>(with validator: Validator, queue: DispatchQueue = .global()) async throws -> NWProtocolTLS.Options {
            if await self.expired {
                try await refresh()
            }

            let tlsProtocol = NWProtocolTLS.Options()
            let options = tlsProtocol.securityProtocolOptions

            func verifySecTrust(_ secTrust: SecTrust) async -> Bool {
                do {
                    guard let leaf = secTrust.chain?.first, secTrust.chain?.count == 1 else {
                        return false
                    }
                    let certificate = try Certificate(from: leaf)
                    try await certificate.validate(using: validator)
                    logger.debug("SecTrust verification completedly successfully")
                    return true
                } catch {
                    self.errorHandler?(error)
                    logger.error("SecTrust verification failed: \(error)")
                    return false
                }
            }

            sec_protocol_options_set_challenge_block(
                options,
                { metadata, complete in
                    let body = UncheckedCompletion {
                        let identity = await storage.identity
                        complete(sec_identity_create(identity))
                    }
                    Task {
                        try await body()
                    }
                },
                queue
            )
            sec_protocol_options_set_verify_block(
                options,
                { metadata, trust, complete in
                    let body = UncheckedCompletion {
                        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                        complete(await verifySecTrust(secTrust))
                    }
                    Task {
                        try await body()
                    }
                },
                queue
            )
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
            sec_protocol_options_set_peer_authentication_required(options, true)

            return tlsProtocol
        }

        /// Refreshes the Attestation and SecIdentity assosciated with this Configurator.
        public func refresh() async throws {
            let newIdentity = try await Self.createIdentity(using: keyType, with: attestor, lifetime: lifetime)
            await storage.setIdentity(newIdentity)
        }

        /// Returns the expiration
        public var expiration: Date {
            get async {
                let identity = await storage.identity
                var cert: SecCertificate?
                guard SecIdentityCopyCertificate(identity, &cert) == 0, let cert else {
                    return Date.distantPast
                }
                guard let exp = SecCertificateCopyNotValidAfterDate(cert) as? Date else {
                    return Date.distantPast
                }

                return exp
            }
        }

        /// Indicates if the SecIdentity and Attestation are expired
        public var expired: Bool {
            get async {
                await expiration < Date.now
            }
        }

        static private func createIdentity(using keyType: KeyType, with attestor: Attestor, lifetime: Duration) async throws -> SecIdentity {
            let key = try keyType.createKey()
            let cert = try await Certificate(for: key, using: attestor, lifetime: lifetime)

            guard let identity = SecIdentityCreate(nil, cert.certificate, key)?.takeRetainedValue() else {
                throw Error.identityGenerationFailure
            }

            return identity
        }
    }
}
