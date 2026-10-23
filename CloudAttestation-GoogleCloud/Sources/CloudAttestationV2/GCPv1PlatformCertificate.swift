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
//  GCPv1PlatformCertificate.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
@_spi(FixedExpiryValidationTime) import X509
import Foundation
import Logging
import SwiftASN1
import BinaryCoding
#if !os(Linux)
import Security
#endif

@dynamicMemberLookup
public struct GCPv1PlatformCertificate: BinaryDecodable, Hashable, Sendable {
    public var certificate: X509.Certificate

    public init(_ certificate: X509.Certificate) {
        self.certificate = certificate
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        let node = try DER.parse(buffer)
        self.certificate = try X509.Certificate(derEncoded: node)
        buffer = buffer[node.encodedBytes.endIndex...]
    }

    public subscript<T>(dynamicMember keyPath: KeyPath<X509.Certificate, T>) -> T {
        self.certificate[keyPath: keyPath]
    }

    package var byteCount: Int {
        var serializer = DER.Serializer()
        try? serializer.serialize(certificate)
        return serializer.serializedBytes.count
    }

    public var derRepresentation: Data {
        get throws {
            try self.certificate.derRepresentation
        }
    }
}

// MARK: - Apple Platform Certificate getters
extension GCPv1PlatformCertificate {
    private static let logger = Logger(label: "com.apple.CloudAttestation.GCPv1PlatformCertificate")

    /// The ``GCPv1DeviceIdentityManifest`` carried in this certificate's X509v3
    /// extension — the identities recorded when the certificate was *issued*, as
    /// distinct from the manifest the live attestation evidence produces
    /// (`claims.computedDeviceIdentityManifest`). `nil` when the extension is absent
    /// or unparseable.
    package var deviceIdentityManifest: GCPv1DeviceIdentityManifest? {
        guard let ext = certificate.extensions[oid: Self.deviceIdentityManifestOID] else {
            return nil
        }
        do {
            let wrapper = try ASN1OctetString(derEncoded: Array(ext.value))
            return try GCPv1DeviceIdentityManifest(derEncoded: wrapper.bytes)
        } catch {
            Self.logger.error(
                "Failed to parse GCPv1DeviceIdentityManifest extension",
                metadata: ["error": "\(error)"]
            )
            return nil
        }
    }
}

// MARK: - Verifier
extension GCPv1PlatformCertificate {
    protocol Verifier: Sendable {
        /// Validates the certificate and returns the parent chain.
        func verify(certificate: GCPv1PlatformCertificate, intermediates: some Sequence<X509.Certificate>) async throws -> ValidatedCertificateChain
    }
}

extension GCPv1PlatformCertificate.Verifier {
    func verify(certificate: GCPv1PlatformCertificate) async throws -> ValidatedCertificateChain {
        try await self.verify(certificate: certificate, intermediates: [])
    }
}

// MARK: - Swift X509 Verifier

extension GCPv1PlatformCertificate {
    struct X509Verifier: Verifier, Sendable {
        private let rootCertificates: CertificateStore
        private let clock: (@Sendable () -> Date)?

        init(roots: [X509.Certificate], clock: (@Sendable () -> Date)? = nil) {
            self.rootCertificates = .init(roots)
            self.clock = clock
        }

        func verify(certificate: GCPv1PlatformCertificate, intermediates: some Sequence<X509.Certificate>) async throws -> ValidatedCertificateChain {
            let now = self.clock?()
            var verifier = X509.Verifier(rootCertificates: self.rootCertificates) {
                if let now {
                    RFC5280Policy(fixedExpiryValidationTime: now)
                } else {
                    RFC5280Policy()
                }
            }
            let intermediatesStore = CertificateStore(intermediates)

            let result = await verifier.validate(leaf: certificate.certificate, intermediates: intermediatesStore)
            switch result {
            case .validCertificate(let validatedCertificateChain):
                return validatedCertificateChain
            case .couldNotValidate(let array):
                throw X509VerifierError.untrusted(array)
            }
        }
    }

    enum X509VerifierError: Error {
        case untrusted([CertificateValidationResult.PolicyFailure])
    }
}

#if !os(Linux)

extension GCPv1PlatformCertificate {
    struct SecTrustVerifier: Verifier {
        let roots: [SecCertificate]?
        let clock: (@Sendable () -> Date)?

        init(roots: [SecCertificate], clock: (@Sendable () -> Date)? = nil) {
            self.roots = roots
            self.clock = clock
        }

        init(roots: [X509.Certificate], clock: (@Sendable () -> Date)? = nil) {
            self.roots = try? roots.map { cert in
                guard let secCert = SecCertificateCreateWithData(nil, try cert.derRepresentation as CFData) else {
                    throw SecTrustVerifierError.secCertificateCreationError
                }
                return secCert
            }
            self.clock = clock
        }

        func verify(certificate: GCPv1PlatformCertificate, intermediates: some Sequence<X509.Certificate>) throws -> ValidatedCertificateChain {
            var policies: [SecPolicy]

            // self.roots being nil means we failed to convert from Swift-Certificates to Security.framework, which shouldn't ever fail.
            guard let roots = self.roots else {
                throw SecTrustVerifierError.invalidRootCertificates
            }

            policies = [SecPolicyCreateBasicX509()]
            let revocation: SecRevocationPolicy = [.preferCRL]

            guard let revocationPolicy = SecPolicyCreateRevocation(revocation.rawValue) else {
                throw SecTrustVerifierError.policyCreationError
            }

            policies.append(revocationPolicy)

            let certs = try ([certificate.certificate] + intermediates).map { try $0.derRepresentation }

            guard let trust = SecTrust.from(der: certs, policies: policies) else {
                throw SecTrustVerifierError.secTrustCreationError
            }

            var result = SecTrustSetAnchorCertificates(trust, roots as CFArray)
            guard result == errSecSuccess else {
                throw SecTrustVerifierError.internalSecError(status: result)
            }

            result = SecTrustSetAnchorCertificatesOnly(trust, true)
            guard result == errSecSuccess else {
                throw SecTrustVerifierError.internalSecError(status: result)
            }

            result = SecTrustSetNetworkFetchAllowed(trust, false)
            guard result == errSecSuccess else {
                throw SecTrustVerifierError.internalSecError(status: result)
            }

            if let verifyDate = self.clock?() {
                result = SecTrustSetVerifyDate(trust, verifyDate as CFDate)
                guard result == errSecSuccess else {
                    throw SecTrustVerifierError.internalSecError(status: result)
                }
            }

            var error: CFError?
            guard SecTrustEvaluateWithError(trust, &error) else {
                throw SecTrustVerifierError.untrusted(cause: error!)
            }

            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
                throw SecTrustVerifierError.nilTrustedCertificateChain
            }

            let x509Chain = try chain.map { secCert in
                try X509.Certificate(secCert)
            }

            return ValidatedCertificateChain(uncheckedCertificateChain: x509Chain)
        }
    }

    struct SecRevocationPolicy: OptionSet, Sendable {
        let rawValue: CFOptionFlags

        init(rawValue: CFOptionFlags) {
            self.rawValue = rawValue
        }

        static let any = Self(rawValue: kSecRevocationUseAnyAvailableMethod)
        static let ocsp = Self(rawValue: kSecRevocationOCSPMethod)
        static let crl = Self(rawValue: kSecRevocationCRLMethod)
        static let preferCRL = Self(rawValue: kSecRevocationPreferCRL)
        static let requirePositiveResponse = Self(rawValue: kSecRevocationRequirePositiveResponse)
        static let networkAccessDisabled = Self(rawValue: kSecRevocationNetworkAccessDisabled)
    }

    enum SecTrustVerifierError: Error {
        case invalidRootCertificates
        case policyCreationError
        case secTrustCreationError
        case secCertificateCreationError
        case nilTrustedCertificateChain
        case internalSecError(status: OSStatus)
        case untrusted(cause: Error)
    }
}

#endif
