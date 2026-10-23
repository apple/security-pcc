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
//  PCCTransparencyLog+TransitiveVerifier.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import Logging
import PrivateCloudCompute

extension PCCTransparencyLog {
    public struct TransitiveVerifier: Sendable, TransparencyVerifier {
        private static let logger = Logger(label: "com.apple.CloudAttestation.PCCTransparencyLog.TransitiveVerifier")

        let certificateProofs: TransparencyLogProofs
        let softwareProofs: TransparencyLogProofs
        let firmwareProofs: TransparencyLogProofs
        let transparencyProver: TransparencyProver & Sendable
        var transparencyCache: TransparencyCache?
        private static let inclusionCoalescer = CoalescingCache<InclusionKey, LogEntry>()
        private static let consistencyCoalescer = CoalescingCache<ConsistencyKey, LogConsistency>()

        private struct InclusionKey: Hashable, Sendable {
            let digest: Data
            let revision: TransparencyLogRevision
        }

        private struct ConsistencyKey: Hashable, Sendable {
            let from: TransparencyLogRevision
            let to: TransparencyLogRevision
        }

        public init(
            certificateProofs: TransparencyLogProofs,
            softwareProofs: TransparencyLogProofs,
            firmwareProofs: TransparencyLogProofs,
            transparencyProver: TransparencyProver & Sendable,
            transparencyCache: TransparencyCache? = nil
        ) {
            self.certificateProofs = certificateProofs
            self.softwareProofs = softwareProofs
            self.firmwareProofs = firmwareProofs
            self.transparencyProver = transparencyProver
            self.transparencyCache = transparencyCache
        }

        @discardableResult
        public func verifyInclusion(of digest: Data, proofs: TransparencyLogProofs, type: TransparencyProofType) async throws -> Date {
            guard proofs != TransparencyLogProofs() else {
                throw TransitiveVerifierError.missingComputeNodeProofs
            }

            let proxyingProofs = selectProxyNodeProofs(for: type)
            guard proxyingProofs != TransparencyLogProofs() else {
                throw TransitiveVerifierError.missingProxyProofsForType(type)
            }

            // Only the proxy SLH is used as the trust anchor below; the proxy leaf itself is never
            // merkle-verified, so treat `proxyNodeLeaf` fields as advisory (config sanity) only.
            let proxyNodeLeaf = try proxyingProofs.inclusionProof.leafData
            let proxyNodeRevision = try proxyingProofs.inclusionProof.logRevision
            let computeNodeRevision = try proofs.inclusionProof.logRevision

            let verifiedLeaf: ATLeafData
            if proxyNodeRevision.isSuperSet(of: computeNodeRevision) {
                verifiedLeaf = try await verifyConsistency(between: computeNodeRevision, and: proxyNodeRevision, proxyingProofs: proxyingProofs, computeNodeProofs: proofs)
            } else {
                verifiedLeaf = try await verifyInclusion(of: digest, at: proxyNodeRevision, proxyingProofs: proxyingProofs, computeNodeProofs: proofs)
            }

            // Validate leaf-level invariants on the leaf that was actually merkle-verified above. On the
            // fresh-fetch path `verifiedLeaf` comes from `transparencyProver`, not the bundle-supplied
            // `proofs`, so this must run *after* the branch — checking the bundle leaf instead would let
            // a substituted proof for the wrong digest (or a spoofed expiry on the never-verified bundle
            // leaf) slip through. Mirrors V1 `TransitiveTransparencyVerifier`.
            try validateLeaf(verifiedLeaf, matches: digest, proxyNodeLeaf: proxyNodeLeaf)

            Self.logger.info("Compute node passed transparency inclusion verification")
            return verifiedLeaf.expiry
        }

        private func selectProxyNodeProofs(for type: TransparencyProofType) -> TransparencyLogProofs {
            switch type {
            case .certificate:
                self.certificateProofs
            case .software:
                self.softwareProofs
            case .firmware:
                self.firmwareProofs
            }
        }

        // Validate that the merkle-verified leaf's digest and type match expectations. Both invariants
        // live here so they move together with any future refactor of the call site.
        private func validateLeaf(_ verifiedLeaf: ATLeafData, matches digest: Data, proxyNodeLeaf: ATLeafData) throws {
            guard verifiedLeaf.dataHash == digest else {
                Self.logger.error(
                    "Digest the inclusion proof is for does not match the expected digest",
                    metadata: [
                        "inclusionProofDigest": .string(verifiedLeaf.dataHash.hexString),
                        "expectedDigest": .string(digest.hexString),
                    ]
                )
                throw TransitiveVerifierError.mismatchingDigests
            }

            guard verifiedLeaf.type == proxyNodeLeaf.type else {
                Self.logger.error(
                    "Leaf type of inclusion proof does not match proxy inclusion proof",
                    metadata: [
                        "verifiedLeafType": .string(String(describing: verifiedLeaf.type)),
                        "proxyNodeLeafType": .string(String(describing: proxyNodeLeaf.type)),
                    ]
                )
                throw TransitiveVerifierError.mismatchingLeafTypes
            }
        }

        // Verify transitive transparency via a consistency proof when the proxy node revision is a superset
        // of the compute node revision, reducing the number of requests to the transparency server.
        private func verifyConsistency(
            between computeNodeRevision: TransparencyLogRevision,
            and proxyNodeRevision: TransparencyLogRevision,
            proxyingProofs: TransparencyLogProofs,
            computeNodeProofs: TransparencyLogProofs
        ) async throws -> ATLeafData {
            Self.logger.info("Proxy node revision is a superset of compute node revision, fetching consistency proofs")

            let consistencyProof = try await cachedConsistencyProofs(from: computeNodeRevision, to: proxyNodeRevision) {
                try await transparencyProver.proveConsistency(from: computeNodeRevision, to: proxyNodeRevision)
            }

            guard computeNodeProofs.inclusionProof.slh == consistencyProof.startSlh,
                consistencyProof.endSlh == proxyingProofs.inclusionProof.slh
            else {
                let consistencyLogRevisions = try consistencyProof.logRevision

                Self.logger.error(
                    "Tree heads in consistency proof do not match inclusion proof tree heads",
                    metadata: [
                        "computeNodeInclusionProof": .stringConvertible(computeNodeRevision),
                        "consistencyProofStart": .stringConvertible(consistencyLogRevisions.start),
                        "consistencyProofEnd": .stringConvertible(consistencyLogRevisions.end),
                        "proxyNodeInclusionProof": .stringConvertible(proxyNodeRevision),
                    ]
                )
                throw TransitiveVerifierError.mismatchingTreeHeads
            }

            guard consistencyProof.isValid else {
                Self.logger.error("Consistency proof is invalid")
                throw TransitiveVerifierError.invalidConsistencyProof
            }

            guard computeNodeProofs.inclusionProof.isValid else {
                Self.logger.error("Compute node inclusion proof is invalid")
                throw TransitiveVerifierError.invalidInclusionProof
            }

            return try computeNodeProofs.inclusionProof.leafData
        }

        // Verify transitive transparency via an inclusion proof when the proxy node revision matches
        // or is behind the compute node revision.
        private func verifyInclusion(
            of digest: Data,
            at proxyNodeRevision: TransparencyLogRevision,
            proxyingProofs: TransparencyLogProofs,
            computeNodeProofs: TransparencyLogProofs
        ) async throws -> ATLeafData {
            let computeNodeRevision = try computeNodeProofs.inclusionProof.logRevision
            let inclusionProof: LogEntry

            if proxyNodeRevision == computeNodeRevision {
                Self.logger.info("Proxy node revision matches compute node revision, using provided compute node inclusion proof")
                inclusionProof = computeNodeProofs.inclusionProof
            } else {
                Self.logger.info("Proxy node revision is behind provided proof, fetching fresh compute node inclusion proof")
                inclusionProof = try await cachedInclusionProofs(for: digest, at: proxyNodeRevision) {
                    try await transparencyProver.proveInclusion(of: digest, at: proxyNodeRevision, coveringAll: nil, preferOldest: false).inclusionProof
                }
            }

            guard inclusionProof.slh == proxyingProofs.inclusionProof.slh else {
                Self.logger.error("Tree head in proxy inclusion proof does not match compute node inclusion proof")
                throw TransitiveVerifierError.mismatchingTreeHeads
            }

            guard inclusionProof.isValid else {
                Self.logger.error("Compute node inclusion proof invalid")
                throw TransitiveVerifierError.invalidInclusionProof
            }

            return try inclusionProof.leafData
        }

        private func cachedInclusionProofs(
            for digest: Data,
            at revision: TransparencyLogRevision,
            _ closure: @Sendable @escaping () async throws -> LogEntry
        ) async throws -> LogEntry {
            guard let transparencyCache else {
                return try await closure()
            }

            if let cached = await transparencyCache.value(for: digest, at: revision) {
                return cached
            }

            let value = try await Self.inclusionCoalescer.value(for: InclusionKey(digest: digest, revision: revision), using: closure)
            do {
                // Key by the proof's own leaf digest so a substituted/poisoned entry can't shadow the
                // requested digest on subsequent lookups; validateLeaf catches it on the way out either
                // way, but this keeps the cache self-consistent.
                let leaf = try value.leafData
                await transparencyCache.insert(value: value, for: leaf.dataHash, at: revision, expiry: leaf.expiry)
            } catch {
                Self.logger.error(
                    "Failed to insert proof into cache",
                    metadata: ["error": .string(String(describing: error))]
                )
            }

            return value
        }

        private func cachedConsistencyProofs(
            from: TransparencyLogRevision,
            to: TransparencyLogRevision,
            _ closure: @Sendable @escaping () async throws -> LogConsistency
        ) async throws -> LogConsistency {
            guard let transparencyCache else {
                return try await closure()
            }

            if let cached = await transparencyCache.value(from: from, to: to) {
                return cached
            }

            let value = try await Self.consistencyCoalescer.value(for: ConsistencyKey(from: from, to: to), using: closure)
            await transparencyCache.insert(value: value, from: from, to: to)
            return value
        }
    }
}

public protocol TransparencyCache: Sendable {
    // For inclusion proofs
    func value(for digest: Data, at revision: TransparencyLogRevision) async -> LogEntry?

    func insert(value: LogEntry, for digest: Data, at revision: TransparencyLogRevision, expiry: Date) async

    // For consistency proofs
    func value(from: TransparencyLogRevision, to: TransparencyLogRevision) async -> LogConsistency?

    func insert(value: LogConsistency, from: TransparencyLogRevision, to: TransparencyLogRevision) async
}

extension PCCTransparencyLog {
    enum TransitiveVerifierError: Error {
        case missingComputeNodeProofs
        case missingProxyProofsForType(TransparencyProofType)
        case mismatchingDigests
        case invalidInclusionProof
        case invalidConsistencyProof
        case mismatchingTreeHeads
        case mismatchingLeafTypes
    }
}

// MARK: - CoalescingCache

actor CoalescingCache<Key: Hashable & Sendable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, any Error>] = [:]

    func value(for key: Key, using fetch: @Sendable @escaping () async throws -> Value) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task { try await fetch() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
