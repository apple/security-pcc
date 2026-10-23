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
//  RegoPolicyEngine.swift
//  CloudAttestationV2
//
//  Created by David Zech on 2/18/26.
//

import Rego
import IR
import AST
import Logging
import Synchronization
import Foundation

public enum RegoPolicy: Policy, Hashable {
    case irPolicy(IR.Policy, parameters: Parameters)
    case bundle(URL, parameters: Parameters)

    static func irPolicy(_ policy: IR.Policy) -> Self {
        .irPolicy(policy, parameters: .init())
    }

    static func bundle(_ policy: URL) -> Self {
        .bundle(policy, parameters: .init())
    }

    var query: String {
        switch self {
        case .irPolicy(_, parameters: let params): return params.query
        case .bundle(_, parameters: let params): return params.query
        }
    }

    var input: [RegoValue: RegoValue] {
        switch self {
        case .irPolicy(_, parameters: let params): return params.input
        case .bundle(_, parameters: let params): return params.input
        }
    }
}

extension RegoPolicy {
    public struct Parameters: Sendable, Hashable {
        public let query: String
        public let input: [RegoValue: RegoValue]

        public init(query: String = "data.main.decision", input: [RegoValue: RegoValue] = [:]) {
            self.query = query
            self.input = input
        }
    }
}

public enum RegoPolicyEngineError: Error {
    case malformedDecision(ResultSet)
    case emptyResultSet
}

public struct RegoPolicyEngine: PolicyEngine {
    private static let logger = Logger(label: "com.apple.CloudAttestation.RegoPolicyEngine")

    public typealias PolicyType = RegoPolicy

    public struct Options: PolicyEngineOptions {
        var nonce: Data? = nil
        var clock: (@Sendable () -> Date)? = nil
        public var query: String? = nil

        public init() {}

        public init(from parameters: ValidatorOptions) throws {
            self.nonce = parameters.nonce
            self.clock = parameters.clock
            if let query = parameters.custom["regoQuery"] as? String {
                self.query = query
            }
        }
    }

    internal let cache: any PolicyCache

    public init(cache: PolicyCache = DefaultPolicyCache()) {
        self.cache = cache
    }

    public func evaluate(claims: Claims, with policy: RegoPolicy, options: Options = Options()) async throws -> PolicyResult {
        let results: ResultSet
        do {
            let prepared: PreparedPolicy
            if let cached = await cache.get(policy) {
                prepared = cached
            } else {
                var engine: OPA.Engine
                let policyQuery: String
                switch policy {
                case .irPolicy(let irPolicy, parameters: let parameters):
                    engine = OPA.Engine(
                        policies: [irPolicy],
                        store: OPA.InMemoryStore(initialData: [
                            "data": [:]
                        ])
                    )
                    policyQuery = parameters.query
                case .bundle(let url, parameters: let parameters):
                    let bundlePath = OPA.Engine.BundlePath(name: "policy", url: url)
                    engine = OPA.Engine(bundlePaths: [bundlePath])
                    policyQuery = parameters.query
                }

                prepared = try await engine.prepareForEvaluation(query: options.query ?? policyQuery)
                await cache.put(policy, prepared)
            }

            // Build the Rego `input` once, regardless of cache hit/miss, so the two
            // paths cannot diverge: policy-supplied input, overlaid with the claims,
            // then the caller options.
            var input = policy.input.merging(claimsToRego(claims)) { $1 }
            input.merge(optionsToRego(options)) { $1 }
            results = try await prepared.evaluate(input: .object(input))
        } catch {
            logFailure(claims: claims, violations: [], error: error)
            throw error
        }

        guard let first = results.first else {
            logFailure(claims: claims, violations: [], error: RegoPolicyEngineError.emptyResultSet)
            throw RegoPolicyEngineError.emptyResultSet
        }

        switch first {
        case .object(let obj):
            let result = obj["result"]
            if case .object(let decision) = result {
                return try handleDecision(decision, claims: claims, raw: results)
            }
            if case .boolean(let allow) = result {
                return try handleBareBoolean(allow, claims: claims)
            }
            logFailure(claims: claims, violations: [], error: RegoPolicyEngineError.malformedDecision(results))
            throw RegoPolicyEngineError.malformedDecision(results)
        default:
            logFailure(claims: claims, violations: [], error: RegoPolicyEngineError.malformedDecision(results))
            throw RegoPolicyEngineError.malformedDecision(results)
        }
    }

    private func handleDecision(_ decision: [RegoValue: RegoValue], claims: Claims, raw: ResultSet) throws -> PolicyResult {
        guard case .boolean(let allow) = decision[.string("allow")] ?? .null else {
            logFailure(claims: claims, violations: [], error: RegoPolicyEngineError.malformedDecision(raw))
            throw RegoPolicyEngineError.malformedDecision(raw)
        }
        let violations: [String] = {
            guard case .array(let arr) = decision[.string("violations")] ?? .null else { return [] }
            return arr.compactMap {
                guard case .string(let s) = $0 else { return nil }
                return s
            }
        }()
        if allow {
            return .ok
        }
        logFailure(claims: claims, violations: violations)
        return .rejected(violations: violations)
    }

    private func handleBareBoolean(_ allow: Bool, claims: Claims) throws -> PolicyResult {
        if allow {
            return .ok
        }
        logFailure(claims: claims, violations: [])
        return .rejected(violations: ["Rego policy rejected (bare boolean query, no violations available)"])
    }

    private func logFailure(claims: Claims, violations: [String], error: Error? = nil) {
        let attestedNode = claims.attestedNodeLabel ?? "<unknown>"

        Self.logger.error(
            "Attestation bundle failed validation",
            metadata: [
                "attestedNode": .string(attestedNode),
                "violations": .array(violations.map { .string($0) }),
            ]
        )

        let jsonString: String = {
            guard
                let data = try? JSONSerialization.data(
                    withJSONObject: claims.prettyJSONDictionary,
                    options: [.prettyPrinted, .sortedKeys]
                ),
                let s = String(data: data, encoding: .utf8)
            else { return "<claims not JSON-serializable>" }
            return s
        }()
        var metadata: Logger.Metadata = [
            "attestedNode": .string(attestedNode),
            "claims": .string(jsonString),
        ]
        if let error {
            metadata["error"] = .string(String(describing: error))
        }
        Self.logger.error(
            "Rego policy rejected attestation bundle",
            metadata: metadata
        )
    }

    func claimsToRego(_ claims: Claims) -> [RegoValue: RegoValue] {
        var object = [RegoValue: RegoValue]()
        for (key, value) in claims.claims {
            object[.string(key.name)] = value.regoValue
        }
        return [
            "claims": .object(object)
        ]
    }

    /// Projects caller-supplied validation options into the Rego `input`. The
    /// expected `nonce` is surfaced as `input.nonce` (base64, matching the claim
    /// `Data` encoding) so policy can reconcile it against the attested nonce.
    /// Omitted when no nonce was supplied, leaving `input.nonce` undefined and the
    /// reconciliation relaxed.
    ///
    /// An explicit clock is read once here and surfaced as `input.now_ns` for the Rego
    /// `clock` module. Omitted when unset, leaving policy on wall time via `time.now_ns()`.
    func optionsToRego(_ options: Options) -> [RegoValue: RegoValue] {
        var input = [RegoValue: RegoValue]()
        if let nonce = options.nonce, !nonce.isEmpty {
            input["nonce"] = .string(nonce.base64EncodedString())
        }
        let now = options.clock?() ?? Date.now
        input["now_ns"] = .number(RegoNumber(int: now.nanosecondsSince1970))
        return input
    }
}

extension RegoPolicyEngine {
    public protocol PolicyCache: Actor {
        func get(_ policy: RegoPolicy) -> PreparedPolicy?
        func put(_ policy: RegoPolicy, _ prepared: PreparedPolicy)
    }
}

extension RegoPolicyEngine {
    public actor DefaultPolicyCache: PolicyCache {
        var cache: [RegoPolicy: PreparedPolicy] = [:]

        public init() {}

        public func get(_ policy: RegoPolicy) -> PreparedPolicy? {
            self.cache[policy]
        }

        public func put(_ policy: RegoPolicy, _ prepared: PreparedPolicy) {
            self.cache[policy] = prepared
        }
    }
}
extension RegoPolicyEngine {
    public typealias PreparedPolicy = OPA.Engine.PreparedQuery
}

extension Date {
    /// Nanoseconds since the Unix epoch, saturating at the `Int64` bounds. Rego numbers are
    /// `Int64`-backed, and sentinels like `.distantFuture` overflow that range — clamping keeps
    /// an out-of-range clock from trapping.
    fileprivate var nanosecondsSince1970: Int64 {
        let nanos = timeIntervalSince1970 * 1_000_000_000
        guard nanos > Double(Int64.min) else { return .min }
        guard nanos < Double(Int64.max) else { return .max }
        return Int64(nanos)
    }
}
