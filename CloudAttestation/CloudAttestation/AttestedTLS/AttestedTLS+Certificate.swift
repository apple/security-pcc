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
//  AttestedTLS+Certificate.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

@preconcurrency import Security
import SwiftASN1Internal
import CryptoKit
import Security.SecCertificate
import Security_Private.SecCertificateRequest
import Security_Private.SecCertificatePriv
import os.log
import InternalSwiftProtobuf

extension AttestedTLS {
    struct Certificate: Sendable {
        static let logger = Logger(subsystem: "com.apple.CloudAttestation", category: "MutualTLS.Certificate")

        let certificate: SecCertificate
        let publicKey: SecKey
        let attestationExtension: AttestationExtension

        init(from certificate: SecCertificate) throws {
            guard let publicKey = SecCertificateCopyKey(certificate) else {
                throw Error.missingPublicKey
            }

            self.certificate = certificate
            self.publicKey = publicKey

            guard let attestationExtData = SecCertificateCopyExtensionValue(certificate, AttestationExtension.objectIdentifier.description as CFString, nil) as? Data else {
                throw Error.missingAttestationExtension
            }

            self.attestationExtension = try .init(extensionValue: attestationExtData)
        }

        init(for privateKey: SecKey, using attestor: some Attestor, lifetime: Duration) async throws {
            // compute SHA384 of privateKey.Public.publicRepresentation as the CN
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw Error.missingPublicKey
            }
            var cfError: Unmanaged<CFError>? = nil
            guard let data = SecKeyCopyExternalRepresentation(publicKey, &cfError) else {
                if let cfError {
                    throw cfError.takeRetainedValue()
                }
                throw Error.certificateGenerationFailure
            }

            let subject: [[[String]]] = [
                [[kSecOidCommonName as String, SHA384.hash(data: data as Data).hexString]]
            ]
            var parameters: [String: Any] = [:]
            var extensions: [String: Data] = [:]

            let bundle = try await attestor.attest(key: privateKey, expiration: Date.now.addingTimeInterval(lifetime.timeInterval))
            let attestationExtension = AttestationExtension(bundle: bundle)
            extensions[AttestationExtension.objectIdentifier.description] = try attestationExtension.serializedExtensionData()
            parameters[kSecCertificateExtensions as String] = extensions
            // we can't set notAfter directly, so we have to guestimate with some variance by calculating lifetime.
            parameters[kSecCertificateLifetime as String] = Int64(bundle.proto.keyExpiration.date.timeIntervalSinceNow)
            parameters[kSecCertificateSerialNumber as String] = 0
            parameters[kSecCertificateKeyUsage as String] = 1

            guard let cert = SecGenerateSelfSignedCertificate(subject as CFArray, parameters as CFDictionary, publicKey, privateKey) else {
                throw Error.certificateGenerationFailure
            }

            self.certificate = cert
            self.publicKey = publicKey
            self.attestationExtension = attestationExtension
        }

        // 60 second variance allowed
        static let acceptableExpirationDelta = TimeInterval(60)

        func validate(using validator: some Validator) async throws {
            let (key, expiration, _) = try await validator.validate(bundle: self.attestationExtension.bundle)
            guard let notAfterDate = SecCertificateCopyNotValidAfterDate(self.certificate) as? Date else {
                throw Error.missingCertificateNotAfterDate
            }
            guard expiration.distance(to: notAfterDate) <= Self.acceptableExpirationDelta else {
                throw Error.mismatchingExpirationDate
            }
            guard Date.now < expiration else {
                throw Error.attestationExpired
            }

            let pubData = key.raw
            var error: Unmanaged<CFError>?
            guard let externalRep = SecKeyCopyExternalRepresentation(self.publicKey, &error) as? Data else {
                if let error = error?.takeRetainedValue() {
                    throw error
                }
                Self.logger.error("SecKeyCopyExternalRepresentation failed but did not return an error object")
                throw Error.missingPublicKey
            }
            guard pubData == externalRep else {
                throw Error.mismatchingPublicKey
            }
        }
    }
}

// MARK: - Certificate Extension

extension AttestedTLS.Certificate {
    struct AttestationExtension: Sendable {

        static let objectIdentifier: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 6, 93]

        let bundle: AttestationBundle

        init(bundle: AttestationBundle) {
            self.bundle = bundle
        }

        init(extensionValue: some DataProtocol) throws {
            let octetString = try ASN1OctetString(derEncoded: ArraySlice(extensionValue))
            self.bundle = try AttestationBundle(data: Data(octetString.bytes))
        }

        func serializedExtensionData() throws -> Data {
            return try bundle.serializedData()
        }
    }
}
