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
//  X509Policy.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
@preconcurrency import Security
import Security_Private.SecPolicyPriv
import Security_Private.SecCertificatePriv
import os.log

/// Defines an ``AttestationPolicy`` that evaluates an X.509 Certificate for an Identity Key.
public struct X509Policy: AttestationPolicy {
    @usableFromInline
    var required: Bool

    var _roots: [Data] = []
    var roots: [SecCertificate] {
        get {
            _roots.map { SecCertificateCreateWithData(nil, $0 as CFData)! }
        }
        set {
            _roots = newValue.map { SecCertificateCopyData($0) as Data }
        }
    }

    @usableFromInline
    var clock: Date?

    @usableFromInline
    var revocation: RevocationPolicy?

    @usableFromInline
    var body: (@Sendable (ProvisioningCertificate) throws -> AttestationPolicy)?

    static let logger: Logger = Logger(subsystem: "com.apple.CloudAttestation", category: "X509Policy")

    /// Creates a new ``X509Policy`` with the provided root certificates.
    ///
    /// - Parameters:
    ///     - roots: an array of `SecCertificate` that serve as the trust anchors for Certificate chain evaluation.
    ///     - clock: an optional `Date` that will be used as the Certificate chain evaluation time, if present. Defaults to nil.
    public init(roots: [SecCertificate], clock: Date? = nil) {
        self = .init(required: true, roots: roots, clock: clock)
    }

    /// Creates a new ``X509Policy`` with the provided root certificates.
    /// - Parameters:
    ///   - required: The `required` flag.
    ///   - roots: The root certificates to use for validation.
    ///   - clock: The `Date` that will be used as the Certificate chain evaluation time.
    @_disfavoredOverload
    public init(required: Bool, roots: [SecCertificate], clock: Date? = nil) {
        self = .init(required: required, roots: roots, clock: clock, revocation: nil)
    }

    public init(required: Bool, roots: [SecCertificate], clock: Date? = nil, revocation: RevocationPolicy? = nil) {
        self.required = required
        self.roots = roots
        self.clock = clock
        self.body = nil
        self.revocation = revocation
    }

    /// Provides a chainining ``PolicyBuilder`` which will have access to a signature verified ``ProvisioningCertificate`` which represents a domain specific validated X.509 Certificate.
    ///
    /// This allows an inner ``AttestationPolicy`` to be written that can consume a trusted `SecKey` and other extension values from an X.509 Certificate.
    ///
    /// - Parameters:
    ///     - body: a ``PolicyBuilder`` closure that is passed a verified `SecKey` for context.
    ///
    /// - Returns: a copy of self with the provided closure captured for evaluation time.
    @inlinable
    public func verifies(@PolicyBuilder body: @escaping @Sendable (_ cert: ProvisioningCertificate) throws -> AttestationPolicy) -> Self {
        var clone = self
        clone.body = body
        return clone
    }

    /// Evaluates the X.509 provisioning identity certificate within ``AttestationBundle``.
    ///
    /// The provided Certificate chain (in order of leaf to intermediates) is evaluated against the set of provided root Certificates provided from ``init(roots:clock:)``
    /// If clock was provided, that `Date` is used as the evaluation time for expiration checks.
    ///
    /// - Throws: ``X509Policy/Error`` if any Certificates are invalid, or fail to construct a valid, non-expired chain.
    public func evaluate(bundle: AttestationBundle, context: inout AttestationPolicyContext) async throws {
        // evaluate policy
        do {
            guard let leaf = bundle.proto.provisioningCertificateChain.first else {
                throw Error.emptyCertificateChain
            }

            try self.evaluateCertificateChain(bundle.proto.provisioningCertificateChain)

            let provCert = try ProvisioningCertificate(data: leaf)

            context[Self.validatedCertKey] = provCert

            Self.logger.log("AttestationBundle passed X509Policy: provisioning identity certificate trusted")

            if let body = body {
                try await body(provCert).evaluate(bundle: bundle, context: &context)
            }
        } catch {
            guard required else {
                Self.logger.warning("Failing open since \"required\"=\(required, privacy: .public)")
                return
            }
            throw error
        }
    }

    func evaluateCertificateChain(_ chain: [Data]) throws {
        var policies: [SecPolicy]
        var networkFetchAllowed = false

        guard let dcAttestationPolicy = SecPolicyCreateDCAttestation() else {
            throw X509Policy.Error.policyCreationFailure
        }
        policies = [dcAttestationPolicy]

        if let revocation {
            guard let revocationPolicy = SecPolicyCreateRevocation(revocation.rawValue) else {
                throw Error.invalidRevocationPolicy
            }
            networkFetchAllowed = true
            policies.append(revocationPolicy)
        }
        guard let trust = SecTrust.from(der: chain, policies: policies) else {
            throw Error.malformedCertificateChain
        }

        var result = SecTrustSetAnchorCertificates(trust, self.roots as CFArray)
        guard result == errSecSuccess else {
            throw Error.internalSecError(status: result)
        }

        result = SecTrustSetAnchorCertificatesOnly(trust, true)
        guard result == errSecSuccess else {
            throw Error.internalSecError(status: result)
        }

        result = SecTrustSetNetworkFetchAllowed(trust, networkFetchAllowed)
        guard result == errSecSuccess else {
            throw Error.internalSecError(status: result)
        }

        if let verifyDate = self.clock {
            result = SecTrustSetVerifyDate(trust, verifyDate as CFDate)
            guard result == errSecSuccess else {
                throw Error.internalSecError(status: result)
            }
        }

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            throw Error.untrusted(cause: error!)
        }
    }
}

// MARK: - Revocation Policy

extension X509Policy {
    /// Maps SecRevocation Policies to Swift types
    public struct RevocationPolicy: OptionSet, Sendable {
        public let rawValue: CFOptionFlags

        public init(rawValue: CFOptionFlags) {
            self.rawValue = rawValue
        }

        public static let any = Self(rawValue: kSecRevocationUseAnyAvailableMethod)
        public static let ocsp = Self(rawValue: kSecRevocationOCSPMethod)
        public static let crl = Self(rawValue: kSecRevocationCRLMethod)
        public static let preferCRL = Self(rawValue: kSecRevocationPreferCRL)
        public static let requirePositiveResponse = Self(rawValue: kSecRevocationRequirePositiveResponse)
        public static let networkAccessDisabled = Self(rawValue: kSecRevocationNetworkAccessDisabled)
    }
}

// MARK: - Policy Context
extension X509Policy {
    static var validatedCertKey: AttestationPolicyContext.Key {
        .init(domain: Self.self, key: "validatedCert")
    }
}

extension AttestationPolicyContext {
    @usableFromInline
    var validatedCert: ProvisioningCertificate? {
        self[X509Policy.validatedCertKey] as? ProvisioningCertificate
    }
}

// MARK: - CA
extension X509Policy {
    static let testProvisioningRoots: [SecCertificate] = [SecCertificateCreateWithData(kCFAllocatorDefault, testProvisioningRootCAData as CFData)!]
    static let prodProvisioningRoots: [SecCertificate] = [SecCertificateCreateWithData(kCFAllocatorDefault, productionProvisioningRootCAData as CFData)!]
}

// MARK: - X509Policy Errors
extension X509Policy {
    public enum Error: Swift.Error {
        case emptyCertificateChain
        case malformedCertificateChain
        case unsupportedPublicKey
        case untrusted(cause: Swift.Error)
        case internalSecError(status: OSStatus)
        case invalidRevocationPolicy
        case policyCreationFailure
    }
}
