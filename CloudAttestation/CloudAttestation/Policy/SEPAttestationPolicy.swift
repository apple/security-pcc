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
//  SEPAttestationPolicy.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
@preconcurrency import Security
import os.log

/// Defines an ``AttestationPolicy`` that evaluates a signed Secure Enclave Attestation Blob.
public struct SEPAttestationPolicy: AttestationPolicy {
    let signerLoader: SignerLoader

    @usableFromInline
    var body: (@Sendable (SEP.Attestation) throws -> AttestationPolicy)?

    @usableFromInline
    static let logger: Logger = Logger(subsystem: "com.apple.CloudAttestation", category: "SEPAttestationPolicy")

    public init() {
        self = .init(insecure: false)
    }

    public init(insecure: Bool) {
        if insecure {
            Self.logger.warning("Using Insecure SEPAttestationPolicy")
            self.signerLoader = .insecure
        } else {
            self.signerLoader = .lazy
        }
    }

    /// Constructs a new ``SEPAttestationPolicy`` with a specified signing public key.
    ///
    /// - Parameters:
    ///     - signer: a public key that signed the SEP Attestation Blob. Is generally the Data Center Identity Key (DCIK)
    public init(signer: SecKey) {
        self.signerLoader = .immediate(signer)
    }

    /// Constructs an insecure ``SEPAttestationPolicy`` that will parse the attestation blob, but not verify its signature.
    public static var insecure: Self {
        .init(insecure: true)
    }

    /// Provides a chainining ``PolicyBuilder`` which will have access to a signature verified ``SEP/Attestation``.
    ///
    /// This allows an inner ``AttestationPolicy`` to be written that can consume trusted fields from the verified ``SEP/Attestation``.
    ///
    /// - Parameters:
    ///     - body: a ``PolicyBuilder`` closure that is passed a verified ``SEP/Attestation`` for context.
    ///
    /// - Returns: a copy of self with the provided closure captured for evaluation time.
    @inlinable
    public func verifies(@PolicyBuilder body: @escaping @Sendable (SEP.Attestation) throws -> AttestationPolicy) -> Self {
        var clone = self
        clone.body = body
        return clone
    }

    /// Evaluates the SEP Attestation blob within ``AttestationBundle``
    ///
    /// Verifies the SEP attestation blob by verifying a ``SEP/Attestation``with the public key provided from ``init(signer:)``.
    /// A nested ``PolicyBuilder`` body provided from ``verifies(body:)`` will be evaluated if present.
    ///
    /// - Parameters:
    ///     - bundle: the ``AttestationBundle`` to evaluate.
    ///
    /// - Throws: ``SEPAttestationPolicy/Error`` if the SEP Attestation is invalid. Errors from the nested body will be propagated up as well.
    public func evaluate(bundle: AttestationBundle, context: inout AttestationPolicyContext) async throws {
        let signer: SecKey
        switch self.signerLoader {
        case .lazy:
            guard let secKey = context.validatedCert?.publicKey else {
                throw Error.missingSigningKey
            }
            signer = secKey

        case .immediate(let secKey):
            signer = secKey

        case .insecure:
            let attestation = try SEP.Attestation(from: bundle.proto.sepAttestation)
            context[Self.validatedAttestationKey] = attestation
            Self.logger.log("AttestationBundle passed SEPAttestationPolicy: SEP Attestation has valid structure, but signature was not checked")
            if let body = self.body {
                try await body(attestation).evaluate(bundle: bundle, context: &context)
            }
            return
        }

        do {
            let attestation = try SEP.Attestation(from: bundle.proto.sepAttestation, signer: signer)
            Self.logger.log("AttestationBundle passed SEPAttestationPolicy: SEP attestation signed by trusted authority")

            // check that the deviceIdentity in the cert (if present) matches the attestation's deviceIdentity
            if let certDeviceIdentity = context.validatedCert?.deviceIdentity {
                guard certDeviceIdentity.identity == attestation.identity?.string else {
                    Self.logger.error("Certificate DeviceIdentity \(certDeviceIdentity.identity) != \(attestation.identity?.string ?? "<nil>")")
                    throw Error.invalidIdentity
                }
            }

            context[Self.validatedAttestationKey] = attestation

            if let body = self.body {
                try await body(attestation).evaluate(bundle: bundle, context: &context)
            }
        } catch SEP.Attestation.Error.invalidSignature {
            Self.logger.error("SEP Attestation signature failed verification")
            throw Error.untrusted
        } catch {
            Self.logger.error("SEP Attestation verification failed with unknown reason: \(error, privacy: .public)")
            throw Error.unknown(underlying: error)
        }
    }
}

// MARK: - Signer Loader
extension SEPAttestationPolicy {
    enum SignerLoader: Sendable {
        case immediate(SecKey)
        case lazy
        case insecure
    }
}

// MARK: - Policy Context Keys
extension SEPAttestationPolicy {
    static var validatedAttestationKey: AttestationPolicyContext.Key {
        .init(domain: Self.self, key: "validatedAttestation")
    }
}

extension AttestationPolicyContext {
    @usableFromInline
    var validatedAttestation: SEP.Attestation? {
        self[SEPAttestationPolicy.validatedAttestationKey] as? SEP.Attestation
    }
}

// MARK: - SEPAttestationPolicy Errors

extension SEPAttestationPolicy {
    public enum Error: Swift.Error {
        case untrusted
        case missingSigningKey
        case unknown(underlying: Swift.Error)
        case invalidIdentity
    }
}
