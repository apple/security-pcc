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
//  Validator.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Foundation
import GCPv1
import Logging
import Metrics

extension Counter {
    enum ValidationResult: String, CaseIterable {
        case pass, fail
    }

    enum ValidationReason: String, CaseIterable {
        case ok
        case rejectedByPolicy = "rejected_by_policy"
        case missingOutput = "missing_output"
        case claimsError = "claims_error"
    }

    private static let validationCounters: [ValidationResult: [ValidationReason: Counter]] = {
        let label = "cloudattestation_validation"
        var table: [ValidationResult: [ValidationReason: Counter]] = [:]
        for result in ValidationResult.allCases {
            var inner: [ValidationReason: Counter] = [:]
            for reason in ValidationReason.allCases {
                inner[reason] = Counter(
                    label: label,
                    dimensions: [("result", result.rawValue), ("reason", reason.rawValue)]
                )
            }
            table[result] = inner
        }
        return table
    }()

    static func validation(_ result: ValidationResult, reason: ValidationReason) -> Counter {
        validationCounters[result]![reason]!
    }
}

public struct Validator<Generator: RootClaimsGenerator, Engine: PolicyEngine>: Sendable {
    private static var logger: Logger { Logger(label: "com.apple.CloudAttestation.Validator") }

    var claimsGenerator: Generator
    var policyEngine: Engine

    public init(claimsGenerator: Generator, policyEngine: Engine) {
        self.claimsGenerator = claimsGenerator
        self.policyEngine = policyEngine
    }

    public func validate(bundle: AttestationBundle, against policy: Engine.PolicyType, options: ValidatorOptions = .init()) async throws -> Validated.AttestationBundle {
        let claims: Claims
        let result: PolicyResult
        do {
            claims = try await claimsGenerator.generateClaims(for: bundle)
            result = try await self.policyEngine.evaluate(claims: claims, with: policy, options: Engine.Options(from: options))
        } catch {
            Counter.validation(.fail, reason: .claimsError).increment()
            throw error
        }
        switch result {
        case .ok:
            guard let validated = Validated.AttestationBundle(bundle, claims: claims) else {
                Counter.validation(.fail, reason: .missingOutput).increment()
                Self.logger.error(
                    "Policy accepted claims but no output was populated; validator cannot return a key",
                    metadata: ["generator": .string(claims.generator ?? "<unknown>")]
                )
                throw ValidatorError.missingOutput
            }
            Counter.validation(.pass, reason: .ok).increment()
            return validated
        case .rejected(violations: let violations):
            Counter.validation(.fail, reason: .rejectedByPolicy).increment()
            throw ValidatorError.rejectedByPolicy(violations: violations)
        }
    }
}

public struct ValidatorOptions {
    /// The freshness nonce the relying party expects. When set, it is injected
    /// into the Rego input as `input.nonce` and reconciled against the attested
    /// `AttestedMetadata.nonce`. Leave `nil` to express no freshness expectation.
    ///
    /// This is purely a freshness lever; it is not required to protect `appData`.
    /// The metadata policy always binds the attested-metadata digest to every
    /// quote challenge, so the caller's `appData` (attested together with the
    /// nonce in one envelope) is authenticated whether or not an expected nonce is
    /// supplied.
    public var nonce: Data?

    /// The clock policy should evaluate against — read once per validation and
    /// injected as `input.now_ns` (nanoseconds since epoch), where the Rego `clock`
    /// module picks it up. Leave `nil` — the default — to let policy use wall time
    /// via `time.now_ns()`.
    ///
    /// Set this to make time-dependent decisions (transparency-claim expiry,
    /// certificate-transparency log-head freshness) reproducible: tests can pin a
    /// clock, and an archived bundle can be replayed against the time it was
    /// captured rather than the time it is re-examined. A closure rather than a
    /// fixed `Date` so a long-lived options value can carry a live clock — pass
    /// `{ fixed }` to pin one.
    public var clock: (@Sendable () -> Date)?
    public var custom: [String: Any]

    public init(nonce: Data? = nil, clock: (@Sendable () -> Date)? = nil, custom: [String: Any] = [:]) {
        self.nonce = nonce
        self.clock = clock
        self.custom = custom
    }
}

/// Namespace for types surfaced by ``Validator/validate(bundle:against:options:)``.
///
/// The validator returns a ``Validated/AttestationBundle`` — a wrapper around the source
/// ``AttestationBundle`` that has cleared policy evaluation, plus the full set of ``Claims``
/// it was evaluated against. Helper functions for extracting or persisting pre-parsed bundle
/// data should hang off ``Validated/AttestationBundle`` so the type signature itself signals
/// that policy evaluation succeeded.
public enum Validated {}

extension Validated {
    /// Proxy pairing an ``AttestationBundle`` with the ``Claims`` generated for it. Forwards
    /// member access to the wrapped bundle via `@dynamicMemberLookup`.
    ///
    /// Typically produced by ``Validator/validate(bundle:against:options:)`` on a successful
    /// policy decision — the wrapper's existence in that flow signals that policy evaluation
    /// passed. Callers may also construct one directly when they need to use the helpers
    /// (for example ``workloadRelease()``, ``firmwareRelease()``, ``deviceIdentityManifest()``)
    /// with claims they've generated outside the validator pipeline.
    @dynamicMemberLookup
    public struct AttestationBundle: Sendable {
        public let bundle: CloudAttestationV2.AttestationBundle

        /// Full set of claims generated for the bundle.
        public let claims: Claims

        package init?(_ bundle: CloudAttestationV2.AttestationBundle, claims: Claims) {
            guard claims.output != nil else { return nil }
            self.bundle = bundle
            self.claims = claims
        }

        public subscript<T>(dynamicMember keyPath: KeyPath<CloudAttestationV2.AttestationBundle, T>) -> T {
            self.bundle[keyPath: keyPath]
        }

        public var output: OutputClaims {
            precondition(claims.output != nil, "claims.output should not be nil")
            return claims.output!
        }

        /// The validated workload public key. Convenience accessor mirroring the field previously
        /// surfaced by `ValidatorOutput`.
        public var publicKey: PublicKeyContainer {
            precondition(claims.output != nil, "claims.output should not be nil")
            return claims.output!.publicKey
        }

        /// The validated workload key expiration. Convenience accessor mirroring the field
        /// previously surfaced by `ValidatorOutput`.
        public var expiration: Date {
            precondition(claims.output != nil, "claims.output should not be nil")
            return claims.output!.expiration
        }
    }
}

public enum ValidatorError: Error {
    case incomplete
    case unsupported
    case missingOutput
    case rejectedByPolicy(violations: [String])
}

extension ValidatorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .incomplete:
            return "incomplete attestation bundle"
        case .unsupported:
            return "unsupported attestation bundle"
        case .missingOutput:
            return "missing 'output' claim"
        case .rejectedByPolicy(violations: let violations):
            let joined = violations.isEmpty ? "no violations reported" : violations.joined(separator: "; ")
            return "rejected by policy: \(joined)"
        }
    }
}

extension PublicKeyContainer: Claims.ValueProtocol {

}
