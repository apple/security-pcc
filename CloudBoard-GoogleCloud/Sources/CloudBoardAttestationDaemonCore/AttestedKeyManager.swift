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

import CloudAttestationV2
import CloudBoardUtilities
import Crypto
import Logging
import Metrics
import PrivateCloudCompute
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum AttestedKeyError: Error, ReportableError {
    case keyCreationFailed(any Error)
    case keyAttestationFailed(any Error)
    case keyValidationFailed(any Error)
    case unsupportedBundleType

    var publicDescription: String {
        switch self {
        case .keyCreationFailed(let wrapped):
            return "keyCreationFailed: \(String(reportable: wrapped))"
        case .keyAttestationFailed(let wrapped):
            return "keyAttestationFailed: \(String(reportable: wrapped))"
        case .keyValidationFailed(let wrapped):
            return "keyValidationFailed: \(String(reportable: wrapped))"
        case .unsupportedBundleType:
            return "unsupportedBundleType"
        }
    }
}

struct AttestedKey: Sendable {
    let key: any CloudAttestationV2.Key
    let attestationBundle: Data
    let expiry: Date
    let keyHandle: any CloudAttestationV2.KeyIdentifier
    /// Highest transparency log tree ID across the bundle's transparency proofs, if any carry an inclusion proof. See
    ///  ``AttestationBundle/highestTransparencyLogRevision``.
    var transparencyTreeID: UInt64?
    /// Highest transparency log revision within that tree across the bundle's transparency proofs, if any carry an
    /// inclusion proof. See ``AttestationBundle/highestTransparencyLogRevision``.
    var transparencyRevision: UInt64?

    var keyID: Data {
        Data(SHA256.hash(data: self.attestationBundle))
    }
}

struct AttestedKeySet: Sendable {
    var currentKey: AttestedKey
    var unpublishedKeys: [AttestedKey]
}

struct AttestedKeyConfiguration: Sendable {
    var attestationEnvironment: Environment
    var appData: Data?
    /// If set to true, attestations are validated on this node after generation. If they fail the validation,
    /// key attestation is retried.
    var selfValidateAttestation: Bool
    /// Minimum age the certificate-transparency log head bound to the bundle must have reached for
    /// self-validation to accept it. This is to ensure that the proxy fleet has had time to recycle onto a tree root
    /// containing it the device identity certificate entry. Setting this to zero waives the window.
    var certificateLogHeadMinAge: Duration
    var advertisedKeyLifetime: Duration
    var keyLifetimeGracePeriod: Duration
    var retryBackoffInitialDelay: Duration
    var retryBackoffMaxDelay: Duration

    init(
        attestationEnvironment: Environment = .dev,
        appData: Data? = nil,
        selfValidateAttestation: Bool = true,
        certificateLogHeadMinAge: Duration = .seconds(60 * 60 * 24),
        advertisedKeyLifetime: Duration = .seconds(60 * 60 * 24),
        keyLifetimeGracePeriod: Duration = .seconds(5),
        retryBackoffInitialDelay: Duration = .seconds(5),
        retryBackoffMaxDelay: Duration = .seconds(5 * 60)
    ) {
        self.attestationEnvironment = attestationEnvironment
        self.appData = appData
        self.selfValidateAttestation = selfValidateAttestation
        self.certificateLogHeadMinAge = certificateLogHeadMinAge
        self.advertisedKeyLifetime = advertisedKeyLifetime
        self.keyLifetimeGracePeriod = keyLifetimeGracePeriod
        self.retryBackoffInitialDelay = retryBackoffInitialDelay
        self.retryBackoffMaxDelay = retryBackoffMaxDelay
    }
}

final class AttestedKeyManager: Sendable {
    private static let logger = Logger(label: "cb_attestationd.AttestedKeyManager")

    private struct KeyState: Sendable {
        var currentKey: AttestedKey?
        var unpublishedKeys: [AttestedKey]
        var watcherContinuations: [UUID: AsyncStream<AttestedKeySet>.Continuation]

        init() {
            self.currentKey = nil
            self.unpublishedKeys = []
            self.watcherContinuations = [:]
        }
    }

    private let state: Mutex<KeyState>

    init() {
        self.state = Mutex(KeyState())
    }

    func generateKey(
        using keyStore: any CloudAttestationV2.KeyStore,
        configuration: AttestedKeyConfiguration
    ) async throws {
        let advertisedKeyLifetime = configuration.advertisedKeyLifetime
        let keyLifetimeGracePeriod = configuration.keyLifetimeGracePeriod
        let attestationEnvironment = configuration.attestationEnvironment
        let appData = configuration.appData
        let selfValidateAttestation = configuration.selfValidateAttestation
        let certificateLogHeadMinAge = configuration.certificateLogHeadMinAge

        Self.logger.info(
            "Generating new attested key",
            metadata: [
                "advertisedKeyLifetime": "\(advertisedKeyLifetime)",
                "keyLifetimeGracePeriod": "\(keyLifetimeGracePeriod)",
                "attestationEnvironment": "\(attestationEnvironment)",
                "appData": "\(appData?.base64EncodedString() ?? "")",
                "selfValidateAttestation": "\(selfValidateAttestation)",
                "certificateLogHeadMinAge": "\(certificateLogHeadMinAge)",
            ]
        )

        Counter.attestationAttempt().increment()
        let attemptClock = ContinuousClock()
        let attemptStart = attemptClock.now

        let key: any CloudAttestationV2.Key
        do {
            let clock = ContinuousClock()
            let start = clock.now
            key = try keyStore.generateKey(
                algorithm: .dhkem_x25519_hkdf_sha256,
                lifespan: advertisedKeyLifetime + keyLifetimeGracePeriod
            )
            Timer.attestationPhaseDuration(phase: .keyCreation).record(duration: clock.now - start)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Counter.attestationFailure(phase: .keyCreation, error: error).increment()
            throw AttestedKeyError.keyCreationFailed(error)
        }
        Self.logger.info("Key generated in WSD", metadata: ["keyHandle": "\(key.id)"])

        // Once the key exists in WSD it counts against the per-process key limit (~100). Anything that
        // throws below must destroy it before propagating, or repeated retries will pile up orphaned
        // keys until WSD refuses to create more.
        do {
            let bundleData: Data
            let attestationBundle: AttestationBundle
            do {
                let clock = ContinuousClock()
                let start = clock.now
                attestationBundle = try await key.attest(for: attestationEnvironment, nonce: nil, appData: appData)
                bundleData = try attestationBundle.serializedData()
                Timer.attestationPhaseDuration(phase: .attestation).record(duration: clock.now - start)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Counter.attestationFailure(phase: .attestation, error: error).increment()
                throw AttestedKeyError.keyAttestationFailed(error)
            }

            if selfValidateAttestation {
                // Validate the attestation here to ensure that we catch policy violations here (possibly during
                // convergence) rather than at validation time on proxy nodes where it would cause request failures.
                try await self.selfValidate(
                    attestationBundle,
                    in: attestationEnvironment,
                    certificateLogHeadMinAge: certificateLogHeadMinAge
                )
            }

            // The grace period is additive: the real WSD key lives `advertisedKeyLifetime + keyLifetimeGracePeriod`
            // (see the `lifespan` passed to `generateKey` above), while clients are told the key expires
            // after `advertisedKeyLifetime`. This lets in-flight requests that picked up the key just before its
            // advertised expiry still validate against a live WSD key during the grace window.
            let keyExpiry = Date.now.addingTimeInterval((advertisedKeyLifetime + keyLifetimeGracePeriod).timeInterval)
            // What's propagated to the outside/to clients
            let effectiveExpiry = Date.now.addingTimeInterval(advertisedKeyLifetime.timeInterval)

            // Extract the transparency log tree ID and revision to advertise alongside the attestation. This is
            // advisory metadata, so a failure here must not fail key generation (and take attestation down) — but it
            // is unexpected, so log it loudly. An absent proof legitimately yields nil without throwing.
            let logRevision: (treeID: UInt64, revision: UInt64)?
            do {
                logRevision = try attestationBundle.highestTransparencyLogRevision()
            } catch {
                Self.logger.error(
                    "Failed to extract transparency log revision from attestation bundle",
                    metadata: ["error": "\(String(reportable: error))"]
                )
                logRevision = nil
            }

            let attestedKey = AttestedKey(
                key: key,
                attestationBundle: bundleData,
                expiry: effectiveExpiry,
                keyHandle: key.id,
                transparencyTreeID: logRevision?.treeID,
                transparencyRevision: logRevision?.revision
            )

            let keySet = self.state.withLock { state -> AttestedKeySet in
                if let previous = state.currentKey {
                    state.unpublishedKeys.append(previous)
                }
                state.currentKey = attestedKey
                state.unpublishedKeys.removeAll { $0.expiry < Date.now }

                let keySet = AttestedKeySet(
                    currentKey: attestedKey,
                    unpublishedKeys: state.unpublishedKeys
                )

                for (_, continuation) in state.watcherContinuations {
                    continuation.yield(keySet)
                }

                return keySet
            }

            Timer.attestationDuration().record(duration: attemptClock.now - attemptStart)

            Self.logger.info(
                "Successfully attested key",
                metadata: [
                    "keyHandle": "\(attestedKey.keyHandle)",
                    "keyID": "\(attestedKey.keyID.base64EncodedString())",
                    "bundleSize": "\(bundleData.count)",
                    "keyExpiry": "\(keyExpiry)",
                    "effectiveExpiry": "\(effectiveExpiry)",
                    "unpublishedKeyCount": "\(keySet.unpublishedKeys.count)",
                    "transparencyTreeID": "\(logRevision?.treeID.description ?? "nil")",
                    "transparencyRevision": "\(logRevision?.revision.description ?? "nil")",
                ]
            )
        } catch {
            destroyOrphanedKey(key)
            throw error
        }
    }

    /// Best-effort cleanup for a WSD key that was created but never reached the published state because attestation or
    /// self-validation failed. We don't propagate destroy failures. The caller already has a more meaningful error to
    /// report and we just want to avoid leaking the key handle.
    private func destroyOrphanedKey(_ key: any CloudAttestationV2.Key) {
        do {
            let clock = ContinuousClock()
            let start = clock.now
            try key.destroy()
            Timer.attestationPhaseDuration(phase: .keyDestruction).record(duration: clock.now - start)
            Self.logger.info(
                "Destroyed orphaned WSD key after failed attestation attempt",
                metadata: ["keyHandle": "\(key.id)"]
            )
        } catch {
            Counter.attestationFailure(phase: .keyDestruction, error: error).increment()
            Self.logger.error(
                "Failed to destroy orphaned WSD key after failed attestation attempt; key handle may leak against the WSD key limit",
                metadata: [
                    "keyHandle": "\(key.id)",
                    "error": "\(String(reportable: error))",
                ]
            )
        }
    }

    /// Verify an attestation bundle against itself using the environment's policy. The verifier reuses the
    /// bundle's own witnessed proofs as both compute-node and proxy proofs, so this catches issues such as
    /// empty proofs or claims that the policy rejects.
    ///
    /// `certificateLogHeadMinAge` configures cloudattestationv2's certificate-transparency log-head maturity gate, see
    ///  `` AttestedKeyConfiguration/certificateLogHeadMinAge``.
    private func selfValidate(
        _ bundle: AttestationBundle,
        in environment: Environment,
        certificateLogHeadMinAge: Duration
    ) async throws {
        Self.logger.info(
            "Self-validating attestation bundle",
            metadata: [
                "environment": "\(environment)",
                "certificateLogHeadMinAge": "\(certificateLogHeadMinAge)",
            ]
        )
        do {
            let clock = ContinuousClock()
            let start = clock.now
            let verifier = try PCCTransparencyLog.TransitiveVerifier(selfValidating: bundle)
            let validator = UniversalValidator(transparencyVerifier: verifier)
            _ = try await validator.validate(
                bundle: bundle,
                against: UniversalValidator.policy(for: environment),
                options: ValidatorOptions(certificateLogHeadMinAge: certificateLogHeadMinAge)
            )
            Timer.attestationPhaseDuration(phase: .validation).record(duration: clock.now - start)
            Self.logger.info("Self-validation succeeded")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Counter.attestationFailure(phase: .validation, error: error).increment()
            Self.logger.error(
                "Self-validation failed",
                metadata: ["error": "\(error)"]
            )
            throw AttestedKeyError.keyValidationFailed(error)
        }
    }

    func currentAttestationSet() -> AttestedKeySet? {
        self.state.withLock { state in
            guard let current = state.currentKey else {
                return nil
            }
            return AttestedKeySet(
                currentKey: current,
                unpublishedKeys: state.unpublishedKeys
            )
        }
    }

    func watchAttestationSets() -> AsyncStream<AttestedKeySet> {
        let id = UUID()
        return AsyncStream { continuation in
            self.state.withLock { state in
                if let current = state.currentKey {
                    let keySet = AttestedKeySet(
                        currentKey: current,
                        unpublishedKeys: state.unpublishedKeys
                    )
                    continuation.yield(keySet)
                }
                state.watcherContinuations[id] = continuation
            }
            continuation.onTermination = { _ in
                self.state.withLock { _ = $0.watcherContinuations.removeValue(forKey: id) }
            }
        }
    }

    func runKeyRotation<C: Clock>(
        using keyStore: any CloudAttestationV2.KeyStore,
        configuration: AttestedKeyConfiguration,
        clock: C = ContinuousClock(),
        onAttempt: @escaping @Sendable (Result<Void, any Error>) -> Void = { _ in }
    ) async throws where C.Duration == Duration {
        while !Task.isCancelled {
            let rotationInterval = self.state.withLock { state -> TimeInterval? in
                guard let currentKey = state.currentKey else { return nil }
                let halfLife = currentKey.expiry.timeIntervalSinceNow / 2
                return max(halfLife, 1)
            }

            guard let interval = rotationInterval else {
                Self.logger.error("No current key available for rotation scheduling")
                return
            }

            Self.logger.info(
                "Next key rotation scheduled",
                metadata: ["intervalSeconds": "\(Int(interval))"]
            )

            try await clock.sleep(for: .seconds(interval))

            try await self.generateWithRetry(
                using: keyStore,
                configuration: configuration,
                clock: clock,
                onAttempt: onAttempt
            )
        }
    }

    /// Generate an attested key, retrying with exponential backoff until success or cancellation.
    /// Each attempt (success or failure) is reported via `onAttempt`.
    func generateWithRetry<C: Clock>(
        using keyStore: any CloudAttestationV2.KeyStore,
        configuration: AttestedKeyConfiguration,
        clock: C = ContinuousClock(),
        onAttempt: @escaping @Sendable (Result<Void, any Error>) -> Void = { _ in }
    ) async throws where C.Duration == Duration {
        let strategy = RetryWithBackoff(
            backoffStrategy: ExponentialBackoffStrategy(
                initialDelay: configuration.retryBackoffInitialDelay,
                multiplier: 2,
                maxDelay: configuration.retryBackoffMaxDelay,
                jitterPercent: 0
            ),
            logger: Self.logger,
            retryFilter: { error in
                if error is CancellationError {
                    return .stop
                }
                Self.logger.error(
                    "Attested key generation attempt failed",
                    metadata: ["error": "\(error)"]
                )
                onAttempt(.failure(error))
                Counter.attestationRetry().increment()
                return .continue
            }
        )
        try await executeWithRetries(retryStrategy: strategy, clock: clock) {
            try await self.generateKey(
                using: keyStore,
                configuration: configuration
            )
        }
        onAttempt(.success(()))
    }
}

extension PCCTransparencyLog.TransitiveVerifier {
    /// Build a verifier that verifies a bundle against itself.
    ///
    /// The bundle's proofs are reused as both compute-node and proxy proofs, with`NopTransparencyLog` as the
    /// inner prover so we don't need to access the transparency log over the network. Per-environment policy
    /// on the presence of proofs is enforced by `UniversalValidator.policy(for:)`.
    init(selfValidating bundle: AttestationBundle) throws {
        guard case .gcpv1AttestationBundle(let gcpBundle) = bundle.proto.attestationBundle else {
            throw AttestedKeyError.unsupportedBundleType
        }
        self.init(
            certificateProofs: gcpBundle.transparencyProofs.certificateTransparencyProofs,
            softwareProofs: gcpBundle.transparencyProofs.softwareTransparencyProofs,
            firmwareProofs: gcpBundle.transparencyProofs.firmwareTransparencyProofs,
            transparencyProver: NopTransparencyLog()
        )
    }
}

extension AttestationBundle {
    /// The transparency log tree ID and revision to advertise for this bundle, taken across its certificate, software,
    /// and firmware transparency proofs.
    ///
    /// A revision number only orders entries *within* a single transparency log tree, so revisions from different trees
    /// are not comparable. We therefore group the proofs' log heads by tree ID, pick the newest tree (highest tree ID),
    /// and report the highest revision witnessed within that tree. In the normal case all three proofs sit in the same
    /// tree and this is simply the max revision across them.
    ///
    /// Returns `nil` if the bundle is not GCPv1 or none of the proofs carry an inclusion proof — both are legitimate
    /// "no revision to advertise" cases rather than errors.
    ///
    /// - Throws: ``TransparencyLogRevisionError/unparseableLogHead`` if a proof carries an inclusion proof whose
    ///   log head cannot be parsed. This is not expected to happen. The bundle has already been attested and self-
    ///   validated which would fail for the same reason.
    func highestTransparencyLogRevision() throws -> (treeID: UInt64, revision: UInt64)? {
        guard case .gcpv1AttestationBundle(let gcpBundle) = self.proto.attestationBundle else {
            return nil
        }
        let proofs = gcpBundle.transparencyProofs
        let candidates: [(name: String, proofs: ATLogProofs)] = [
            ("certificate", proofs.certificateTransparencyProofs),
            ("software", proofs.softwareTransparencyProofs),
            ("firmware", proofs.firmwareTransparencyProofs),
        ]

        // treeID -> highest revision witnessed in that tree
        var maxRevisionByTree: [UInt64: UInt64] = [:]
        for candidate in candidates where candidate.proofs.hasInclusionProof {
            let logHead: LogHead
            do {
                logHead = try LogHead(serializedBytes: candidate.proofs.inclusionProof.slh.object)
            } catch {
                throw TransparencyLogRevisionError.unparseableLogHead(proof: candidate.name, underlying: error)
            }
            maxRevisionByTree[logHead.treeID] = max(maxRevisionByTree[logHead.treeID] ?? 0, logHead.revision)
        }

        guard let treeID = maxRevisionByTree.keys.max(), let revision = maxRevisionByTree[treeID] else {
            return nil
        }
        return (treeID: treeID, revision: revision)
    }
}

enum TransparencyLogRevisionError: Error, ReportableError {
    /// A transparency proof carried an inclusion proof, but its log head could not be deserialized.
    case unparseableLogHead(proof: String, underlying: any Error)

    var publicDescription: String {
        switch self {
        case .unparseableLogHead(let proof, let underlying):
            return "unparseableLogHead(proof: \(proof), underlying: \(String(reportable: underlying)))"
        }
    }
}
