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
//  NodeValidator.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//
import os.log
@preconcurrency import Security
import FeatureFlags
import CryptoKit
import AppleKeyStore
import InternalSwiftProtobuf

/// Implements ``Validator`` for Apple silicon nodes.
public struct NodeValidator: Validator, Sendable {

    /// The environment to use for validation.
    public let environment: Environment

    @_spi(Private)
    public var transparencyVerifier: any TransparencyVerifier

    @_spi(Private)
    public var validity: Duration

    // Defang parameters
    @_spi(Private)
    public var roots: [SecCertificate] = []

    @_spi(Private)
    public var clock: Date? = nil

    @_spi(Private)
    public var transparencyProofValidation: Bool

    @_spi(Private)
    public var strictCertificateValidation: Bool

    @_spi(Private)
    public var requireProdTrustAnchors: Bool

    @_spi(Private)
    public var requireRestrictedExecutionMode: Bool

    @_spi(Private)
    public var requireEphemeralDataMode: Bool

    @_spi(Private)
    public var restrictDeveloperMode: Bool

    @_spi(Private)
    public var requireProdFusing: Bool

    @_spi(Private)
    public var requireLockedCryptexes: Bool

    @_spi(Private)
    public var ensembleTopologyValidation: Bool

    @_spi(Private)
    public var allowExpired: Bool

    @_spi(Private)
    public var customerSecurityPolicy: DarwinInit.SecureConfigSecurityPolicy = .customer

    @_spi(Private)
    public var restrictSecurityPolicies: Bool

    public var certificateTransparency: Bool

    public var certificateTransparencyVerifyFailClosed: Bool

    static let logger: Logger = Logger(subsystem: "com.apple.CloudAttestation", category: "NodeValidator")

    /// Constructs a ``NodeValidator`` with a default validity duration of 1 day
    public init() {
        self = .init(validity: .days(1))
    }

    /// Constructs a ``NodeValidator`` with the specified environment, and a default validity duration of 1 day.
    public init(environment: Environment) {
        self = .init(validity: .days(1), environment: environment)
    }

    /// Constructs a ``NodeValidator``
    /// - Parameters:
    ///     - validity: a ``Swift/Duration`` object indicating a lower bound on how long a validated AttestationBundle should be valid for
    public init(validity: Duration) {
        self = .init(validity: validity, environment: Environment.current)
    }

    /// Creates a ``NodeValidator``...
    /// - Parameters:
    ///   - validity: The ``Swift/Duration`` object indicating a lower bound on how long a validated AttestationBundle should last.
    ///   - environment: The environment to validate the AttestationBundle in.
    public init(validity: Duration, environment: Environment) {
        self.validity = validity
        self.transparencyVerifier = SWTransparencyVerifier()
        self.environment = environment
        let configuration = Configuration(for: environment)
        self.transparencyProofValidation = configuration.transparencyProofValidation
        self.strictCertificateValidation = configuration.strictCertificateValidation
        self.requireProdTrustAnchors = configuration.requireProdTrustAnchors
        self.requireRestrictedExecutionMode = configuration.requireRestrictedExecutionMode
        self.requireEphemeralDataMode = configuration.requireEphemeralDataMode
        self.restrictDeveloperMode = configuration.restrictDeveloperMode
        self.requireProdFusing = configuration.requireProdFusing
        self.requireLockedCryptexes = configuration.requireLockedCryptexes
        self.ensembleTopologyValidation = configuration.ensembleTopologyValidation
        self.allowExpired = configuration.allowExpired
        self.restrictSecurityPolicies = configuration.restrictSecurityPolicies
        self.certificateTransparency = configuration.certificateTransparency
        self.certificateTransparencyVerifyFailClosed = configuration.certificateTransparencyVerifyFailClosed
    }

    var pinnedSigner: SecKey? = nil

    private var trustAnchors: [SecCertificate] {
        if requireProdTrustAnchors {
            X509Policy.prodProvisioningRoots
        } else {
            self.roots + X509Policy.prodProvisioningRoots + X509Policy.testProvisioningRoots
        }
    }

    private var securityPolicies: [DarwinInit.SecureConfigSecurityPolicy] {
        guard restrictSecurityPolicies else {
            return DarwinInit.SecureConfigSecurityPolicy.allCases
        }

        switch self.environment {
        case .production:
            return [customerSecurityPolicy]
        case .carry, .liveon, .uat, .staging, .quarantine, .qa:
            return [customerSecurityPolicy, .carry]
        case .dev, .ephemeral, .perf, .qa2Primary, .qa2Internal:
            return [customerSecurityPolicy, .carry, .none]
        }
    }

    /// The policy to use for validation.
    @PolicyBuilder
    public var policy: some AttestationPolicy {
        X509Policy(required: self.strictCertificateValidation, roots: self.trustAnchors, clock: self.clock)
        if self.certificateTransparency {
            CertificateTransparencyPolicy(verifier: self.transparencyVerifier, strict: self.certificateTransparencyVerifyFailClosed)
        }
        if let pinnedSigner {
            SEPAttestationPolicy(signer: pinnedSigner)
        } else {
            SEPAttestationPolicy(insecure: !self.strictCertificateValidation)
        }
        APTicketPolicy()
        LocalBootPolicy()
        SEPImagePolicy()
        CryptexPolicy(locked: self.requireLockedCryptexes)
        SecureConfigPolicy()
        TransparencyPolicy(verifier: self.transparencyVerifier, validateProofs: self.transparencyProofValidation)
        KeyOptionsPolicy(mustContain: [.osBound, .sealedHashesBound])
        if self.requireProdFusing {
            FusingPolicy(matches: .init(productionStatus: true, securityMode: true, securityDomain: .any))
        }
        DeviceModePolicy(
            restrictedExecution: self.requireRestrictedExecutionMode ? .on : .any,
            ephemeralData: self.requireEphemeralDataMode ? .on : .any,
            developer: self.restrictDeveloperMode ? .off : .any
        )
        DarwinInitPolicy(securityPolicies: self.securityPolicies)
        RoutingHintPolicy(required: false)
        EnsembleMembersPolicy(required: self.ensembleTopologyValidation)
    }

    /// Validates an attestation bundle.
    /// - Parameters:
    ///   - bundle: The bundle to validate.
    ///   - nonce: The nonce that is used for the current attestation.
    ///   - policy: The policy to use if the current environment does not match any of the provided environments.
    public func validate(
        bundle: AttestationBundle,
        nonce: Data?
    ) async throws -> (key: PublicKeyData, expiration: Date, attestation: Validated.AttestationBundle) {
        do {
            Self.logger.log("Validating attestation bundle in environment \(self.environment, privacy: .public)")
            bundle.trace()

            var context = AttestationPolicyContext()
            try await policy.evaluate(bundle: bundle, context: &context)

            let attestation: SEP.Attestation
            if let maybeAttestation = context[SEPAttestationPolicy.validatedAttestationKey] as? SEP.Attestation {
                attestation = maybeAttestation
            } else {
                attestation = try SEP.Attestation(from: bundle.proto.sepAttestation)
            }

            try validateNonce(desiredNonce: nonce, observedNonce: attestation.nonce, bundle: bundle, logger: Self.logger)

            guard let keyData: PublicKeyData = attestation.publicKeyData else {
                throw CloudAttestationError.unexpected(reason: "Unknown public key type")
            }

            Self.logger.log("AttestationBundle passed validation for public key: \(keyData.fingerprint(), privacy: .public)")

            let now = self.clock ?? .now
            let bundleExpiration = now.addingTimeInterval(self.validity.timeInterval)
            let keyExpiration = bundle.proto.keyExpiration.date

            let expiration = [
                bundleExpiration,
                keyExpiration,
                context.proofExpiration,
                context.certificateProofExpiration,
            ].compactMap { $0 }.min()!

            let expired = now >= expiration

            if expired {
                if !allowExpired {
                    throw CloudAttestationError.expired(expiration: expiration)
                } else {
                    Self.logger.warning("Allowing expired bundle to fail open: expiration=\(expiration, privacy: .public)")
                }
            }

            return (
                key: keyData, expiration: expiration,
                attestation: Validated.AttestationBundle(
                    bundle: bundle,
                    udid: attestation.identity?.udid,
                    routingHint: context.validatedRoutingHint,
                    releaseDigest: context.releaseDigest,
                    appIdentifiers: context.appIdentifiers,
                    context: context
                )
            )
        } catch {
            Self.logger.error("AttestationBundle validation failed: \(error, privacy: .public)")
            throw error
        }
    }
}

// MARK: - Legacy API support

extension NodeValidator {
    public var defaultPolicy: some AttestationPolicy {
        policy
    }
}

extension Digest {
    var hexString: String {
        self.compactMap { String(format: "%02x", $0) }.joined()
    }
}
