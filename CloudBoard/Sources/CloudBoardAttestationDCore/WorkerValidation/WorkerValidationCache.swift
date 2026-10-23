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

import CloudAttestation
import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardLogging
import CloudBoardMetrics
import CryptoKit
import DequeModule
import Foundation
import os
import Synchronization

/// Maintains the cache of validated tuple pairs of (proxyRequestAttestation, workerAttestation)
/// This needs to cleanly expire old entries to avoid using too much memory and not block
/// checks on tuple (a,b) when validation is occuring for anything not an exact match
/// This should be cheap to create if not running as a proxy
internal actor WorkerValidationCache<ClockType: DateAwareClock> {
    private let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "WorkerValidationCache"
    )

    private let metrics: MetricsSystem
    private let factory: any AttestationValidatorFactoryProtocol
    private let enableReleaseSetValidation: Bool
    private let clock: ClockType
    // map from the request attestation's keyID to the cache for it
    private var proxyKeyCache: [Data: PerProxyAttestationCache<ClockType>] = [:]
    // we have a hard limit on the size here, but it will avoid some confusing errors
    // where an expired key is considered "unknown" - this is kept very small
    private var expiredKeyHistoryWindow: Deque<Data> = []
    private var proxyKeyMetrics: [Int: (metrics: CacheMetrics, snapshotSequenceID: Int)] = [:]
    private var nextPerProxyAttestationCacheID: Int = 1

    // It is possible in certain edge cases (adding or removing proxy attestation whilst
    // some validations are inflight) for validatedEntriesTotal to exceed maximumValidatedEntrySize
    // This would be by an extremely small amount so is not viewed as a problem
    private let maximumValidatedEntrySize: Int
    private var validatedEntriesTotal: Int = 0
    private var allowedToAddToCacheTotal: Int = 0
    private var workerRackIDCache: [HardwareID: WorkerRackValidationEntry<ClockType>] = [:]
    private var workerRackIDCacheTTLMinutes: Int
    private var lastRackCacheCleanupTime: ClockType.Instant?
    private let minimumCleanupIntervalSeconds: Int = 30

    internal init(
        factory: any AttestationValidatorFactoryProtocol,
        enableReleaseSetValidation: Bool,
        maximumValidatedEntrySize: Int,
        metrics: MetricsSystem,
        // abstracted to allow unit testing
        clock: ClockType,
        workerRackIDCacheTTLMinutes: Int
    ) {
        self.factory = factory
        self.enableReleaseSetValidation = enableReleaseSetValidation
        self.metrics = metrics
        self.maximumValidatedEntrySize = maximumValidatedEntrySize
        self.clock = clock
        self.workerRackIDCacheTTLMinutes = workerRackIDCacheTTLMinutes
    }

    private func removeExpiredKeys() {
        let now = self.clock.dateNow
        let expired = self.proxyKeyCache.values.filter { $0.expiry <= now }
        for entry in expired {
            self.removeKey(keyId: entry.proxyKeyId, reason: "auto expiry")
        }
    }

    private func addKey(
        proxyKey: InternalAttestedKey,
        validator: AttestationValidatorProtocol
    ) {
        let keyID = proxyKey.keyID
        // Before doing anything else check for expired entries and purge them
        // This means that even if we somehow don't get ``notifyOfKeyRemoval()``
        // calls, or they are wrong, the cache will clean itself up
        self.removeExpiredKeys()
        guard self.proxyKeyCache[keyID] == nil else {
            fatalError("Attempt to add an existing key ID: \(keyID.base64EncodedString())")
        }
        defer {
            self.nextPerProxyAttestationCacheID += 1
        }
        let cache = PerProxyAttestationCache(
            logger: self.logger,
            id: self.nextPerProxyAttestationCacheID,
            expiry: proxyKey.expiry,
            proxyKeyId: proxyKey.keyID,
            validator: validator,
            clock: self.clock
        )
        self.proxyKeyCache[keyID] = cache
        self.recalculateSize()
    }

    private func recalculateSize() {
        // proxyKeyCache is the sorce of truth
        self.proxyKeyMetrics.removeAll()
        var total = CacheMetrics()
        for (_, cache) in self.proxyKeyCache {
            // this gets the sequence ids locked in step with the vsnapshot so subsequent deltas can be
            // ignored/incorporated properly
            let counts = cache.metricSnapshot()
            self.proxyKeyMetrics[cache.id] = counts
            total.add(counts.metrics)
        }
        // not bothering to emit a metric related to deduplicating, it's low value as it's
        // likely to remain zero for the most part outside of tests
        self.metrics.emit(CloudBoardAttestationMetrics.CloudAttestationValidator.WorkerValidationCacheCountGauge(
            value: Double(total.validated)
        ))
        self.metrics
            .emit(CloudBoardAttestationMetrics.CloudAttestationValidator.WorkerValidationCacheValidatingCountGauge(
                value: Double(total.validating)
            ))
        self.validatedEntriesTotal = total.validated
        self.allowedToAddToCacheTotal = total.validatingCacheable
    }

    private func removeKey(
        keyId: Data,
        reason: StaticString
    ) {
        let entry = self.proxyKeyCache[keyId]
        if let entry {
            self.logger.log(
                "removing cache entry for keyID: \(entry.proxyKeyId.base64EncodedString(), privacy: .public) with \(entry.metricSnapshot().metrics, privacy: .public) entries due to \(reason, privacy: .public)."
            )
            self.proxyKeyCache.removeValue(forKey: entry.proxyKeyId)
            // Size limit is chosen to cover a month of conventional use (expiry after 24 hours)
            // Since the keys are SHA256 this is 1KB fixed cost
            if self.expiredKeyHistoryWindow.count > 32 {
                _ = self.expiredKeyHistoryWindow.popLast()
            }
            self.expiredKeyHistoryWindow.prepend(keyId)
            self.recalculateSize()
        }
    }

    /// On a restart this might be called repeatedly
    /// it's "new" to this instance of the cache regardless of the age
    func notifyOfNewKey(
        proxyKey: InternalAttestedKey
    ) async throws {
        let validator = try await self.factory.makeForProxyAttestation(
            rawProxyAttestationBundle: proxyKey.attestationBundle,
            enableReleaseSetValidation: self.enableReleaseSetValidation
        )
        self.addKey(proxyKey: proxyKey, validator: validator)
    }

    /// In theory automatic expiry will cover it, but good to be able to explicitly
    /// Remove keys from the set when no longer valid
    func notifyOfKeyRemoval(proxyKey: InternalAttestedKey) {
        self.removeKey(keyId: proxyKey.keyID, reason: "notification")
        // general tidy up too
        self.removeExpiredKeys()
    }

    // Deal with deltas in a way where we can maintain things in a self consistent way.
    private func notifyCacheSizeChange(
        attestationCache: PerProxyAttestationCache<ClockType>,
        delta: CacheMetricsDelta
    ) async {
        // There won't be many caches concurrently in use, so just iterate over them every time
        var total = CacheMetrics()
        for (cacheID, lastCount) in self.proxyKeyMetrics {
            if attestationCache.id == cacheID, lastCount.snapshotSequenceID < delta.sequenceID {
                var updated = lastCount.metrics
                updated.add(delta.changes)
                // we do not update the snapshotSequenceID, it's used as a filter based on the last snapshot,
                // it's reasonable to receive/process the deltas out of order
                self.proxyKeyMetrics[cacheID] = (metrics: updated, lastCount.snapshotSequenceID)
                total.add(updated)
            } else {
                total.add(lastCount.metrics)
            }
        }
        self.logger.debug(
            "notifyCacheSizeChange \(attestationCache.proxyKeyId.hexString, privacy: .public) : \(delta, privacy: .public) resulted in \(total, privacy: .public)"
        )
        self.metrics.emit(CloudBoardAttestationMetrics.CloudAttestationValidator.WorkerValidationCacheCountGauge(
            value: Double(total.validated)
        ))
        self.metrics
            .emit(CloudBoardAttestationMetrics.CloudAttestationValidator.WorkerValidationCacheValidatingCountGauge(
                value: Double(total.validating)
            ))
        self.validatedEntriesTotal = total.validated
        self.allowedToAddToCacheTotal = total.validatingCacheable
    }

    private func recordWorkerRackId(hardwareID: HardwareID, rackId: RackId) async {
        let now = self.clock.now
        self.workerRackIDCache[hardwareID] = WorkerRackValidationEntry(
            hardwareID: hardwareID,
            rackId: rackId,
            creationInstant: now,
            entryLifetimeMinutes: self.workerRackIDCacheTTLMinutes
        )
        self.logger.debug("Recorded new worker \(hardwareID, privacy: .public) -> rack \(rackId, privacy: .public)")
    }

    /// Updates the last update timestamp to now, extending the cache entry's lifetime before expiration
    private func resetLastUpdateTime(hardwareID: HardwareID) async {
        guard var entry = workerRackIDCache[hardwareID] else { return }
        entry.lastUpdateInstant = self.clock.now
        self.workerRackIDCache[hardwareID] = entry
        self.logger.debug("Reset last update time for worker \(hardwareID, privacy: .public)")
    }

    /// Removes cache entries that haven't been updated within the configured TTL (default 1 hour)
    /// Each successful validation from the same rack resets the timer, so only truly stale entries expire
    /// To avoid excessive overhead with larger caches, cleanup only runs if at least
    /// minimumCleanupIntervalSeconds has elapsed since the last cleanup
    private func cleanupWorkerRackValidationEntries() async {
        let now = self.clock.now

        // Check if we need to cleanup - only if minimum interval has passed
        if let lastCleanup = self.lastRackCacheCleanupTime {
            let elapsed = lastCleanup.duration(to: now)
            if elapsed < Duration.seconds(self.minimumCleanupIntervalSeconds) {
                // Too soon since last cleanup, skip this one
                return
            }
        }

        // Update last cleanup time before doing the work
        self.lastRackCacheCleanupTime = now

        let expiredKeys = self.workerRackIDCache.compactMap { key, entry in
            entry.isExpired(at: now) ? key : nil
        }

        for key in expiredKeys {
            let removedEntry = self.workerRackIDCache.removeValue(forKey: key)
            if let entry = removedEntry {
                self.logger
                    .info(
                        "Removed expired rack validation entry for worker \(key, privacy: .public) (rack: \(entry.rackId, privacy: .public))"
                    )
            }
        }

        if !expiredKeys.isEmpty {
            self.logger.info("Cleaned up \(expiredKeys.count, privacy: .public) expired rack validation entries")
        }
    }

    /// Validates that a worker's rack ID matches its previously recorded rack
    /// - First connection: Records the worker's rack and allows the connection
    /// - Same rack: Resets the expiration timer and allows the connection
    /// - Different rack: Blocks the connection and resets the timer to extend the blocking period
    internal func validateWorkerRackId(
        hardwareID: HardwareID,
        currentRackId: RackId
    ) async throws -> RackValidationResult {
        // Clean up expired entries first
        await self.cleanupWorkerRackValidationEntries()

        guard let existingEntry = self.workerRackIDCache[hardwareID] else {
            // First time seeing this worker - record and allow
            await self.recordWorkerRackId(hardwareID: hardwareID, rackId: currentRackId)
            self.logger
                .info(
                    "First validation for worker \(hardwareID, privacy: .public) on rack \(currentRackId, privacy: .public)"
                )
            return .allowed(currentRackId)
        }

        if existingEntry.rackId == currentRackId {
            // Same rack - reset the last update time and allow
            await self.resetLastUpdateTime(hardwareID: hardwareID)
            self.logger
                .debug(
                    "Worker \(hardwareID, privacy: .public) validated on same rack \(currentRackId, privacy: .public), last update time reset"
                )
            return .allowed(currentRackId)
        }

        // Rack has changed - fail worker validation and reset last update time
        self.logger.error("""
        Worker \(hardwareID, privacy: .public) rack change detected!
        Previous rack ID: \(existingEntry.rackId, privacy: .public) -> Attempted rack ID: \(
            currentRackId,
            privacy: .public
        )
        Refusing worker validation and resetting last update time to extend blockage of worker use
        """)

        let rackChangeError = WorkerRackValidationError.rackIdChanged(
            reason: "Rack change detected",
            originalRackId: existingEntry.rackId.rackId,
            blockedUntil: Date.now.addingTimeInterval(TimeInterval(self.workerRackIDCacheTTLMinutes * 60)),
            hardwareID: hardwareID
        )
        self.metrics
            .emit(
                CloudBoardAttestationMetrics.RackIdValidation.WorkerRackIdChangeCounter.Factory()
                    .make(rackChangeError)
            )

        // Reset last update time to reset the blocking period
        await self.resetLastUpdateTime(hardwareID: hardwareID)

        return .blocked(rackValidationError: rackChangeError)
    }

    func validateWorkerAttestation(
        proxyAttestationKeyID: Data,
        rawWorkerAttestationBundle: Data
    ) async throws -> CloudBoardAttestationDAPI.WorkerValidationResult {
        // We want to include the wasCached status in the success metrics, so we do them all at the end.
        // Error is inherently uncached
        let timeMeasurement = ContinuousTimeMeasurement.start()
        // SHA256 is already considered sufficiently secure to identify the attestation
        // as the keyID, this is just reusing that slightly more efficiently.
        // Do it early so we can have a consistent logging entry
        let workerKeyID = SHA256.hash(data: rawWorkerAttestationBundle)
        self.logger.log(
            "Validating worker attestation with digest \(workerKeyID.description, privacy: .public) against proxy \(proxyAttestationKeyID.base64EncodedString(), privacy: .public)"
        )
        // if we didn't work this out then it is simply considered not cached
        var inCache = CloudBoardAttestationMetrics.CloudAttestationValidator.InCache.miss
        defer {
            self.metrics.emit(CloudBoardAttestationMetrics.CloudAttestationValidator.ValidationDurationHistogram(
                duration: timeMeasurement.duration, inCache: inCache
            ))
            self.metrics.emit(CloudBoardAttestationMetrics.CloudAttestationValidator.ValidationCounter(
                action: .increment(by: 1),
                inCache: inCache
            ))
        }
        do {
            let attestationCache = self.proxyKeyCache[proxyAttestationKeyID]
            guard let attestationCache else {
                // this is fixed small size so the linear lookup (in the error case) is fine
                let expired = self.expiredKeyHistoryWindow.contains(proxyAttestationKeyID)
                self.logger.error(
                    "Request for \(expired ? "expired" : "unknown", privacy: .public) proxy attestation key \(proxyAttestationKeyID.base64EncodedString(), privacy: .public)"
                )
                throw CloudBoardAttestationAPIError.unavailableKeyID(
                    requestKeyID: proxyAttestationKeyID, expired: expired
                )
            }
            let allowedToAddToCache = self.validatedEntriesTotal + self.allowedToAddToCacheTotal < self
                .maximumValidatedEntrySize
            // add early, the delta only does the decrement
            if allowedToAddToCache {
                self.allowedToAddToCacheTotal += 1
            }

            let (validated, _inCache) = try await attestationCache.validateWorkerAttestation(
                workerKeyID: workerKeyID,
                rawWorkerAttestationBundle: rawWorkerAttestationBundle,
                allowedToAddToCache: allowedToAddToCache,
                notifySizeChange: { delta in
                    await self.notifyCacheSizeChange(attestationCache: attestationCache, delta: delta)
                }
            )
            inCache = _inCache
            guard validated.expiration > self.clock.dateNow else {
                self.logger.error(
                    "Cached validation of proxy: \(proxyAttestationKeyID.base64EncodedString(), privacy: .public) with worker digest \(workerKeyID.description, privacy: .public) no longer valid, the worker expired at \(validated.expiration, privacy: .public)"
                )
                throw CloudBoardAttestationError.attestationExpired
            }
            self.logger.log(
                """
                Validated worker attestation with digest \(workerKeyID.description, privacy: .public) running \(
                    validated.releaseDigest,
                    privacy: .public
                )
                as \(String(describing: inCache), privacy: .public)
                in \(timeMeasurement.duration, privacy: .public)
                against key cache \(attestationCache.id, privacy: .public) { \(
                    attestationCache.metricSnapshot().metrics,
                    privacy: .public
                ) }
                """
            )

            let rackValidation: CloudBoardAttestationDAPI.RackValidationResult
            let hardwareID = validated.hardwareID
            let rack = validated.appData["rackID"]?.utf8String

            if let rack {
                let rackId = RackId(rack)
                /// We know by now if this hardwareId is reasonable to use based on the security policy.
                /// We special case unknown because lookup table no longer makes sense.
                /// CloudAttestationV2 does not yet provide hardware identifiers, so rack
                /// awareness is not supported for that format.
                switch hardwareID {
                case .unknown, .cloudAttestationV2:
                    rackValidation = .allowed(rackId)
                default:
                    rackValidation = try await self.validateWorkerRackId(
                        hardwareID: hardwareID,
                        currentRackId: rackId
                    )
                }
            } else {
                // Without a RackId (or if it is explicitly not relevant) we proceed, but down stream code
                // may then choose to consider this unreasonable, or behave differently
                rackValidation = .allowed(RackId.irrelevant)
            }
            return CloudBoardAttestationDAPI.WorkerValidationResult(
                validatedWorker: validated,
                rackValidation: rackValidation
            )
        } catch {
            self.metrics
                .emit(
                    CloudBoardAttestationMetrics.CloudAttestationValidator.FailedValidationCounter.Factory()
                        .make(error)
                )
            throw error
        }
    }
}

/// A cache of validated worker attestations which are validated against a specific Proxy attestation
/// (and hence specific key).
/// The name should be parsed as: "Per ProxyAttestation Cache"
/// This is only ever added to, then thrown away once the proxy key expires/is removed.
/// If a worker's attestation expires before the proxies attestation we just ignore the
/// memory overhead to make locking simple.
/// The validation includes the expiry time for worker so it won't give a false positive
private final class PerProxyAttestationCache<ClockType: DateAwareClock>: Sendable {
    private let logger: Logger
    /// When this entire object becomes invalid
    public let expiry: Date
    public let id: Int
    public let proxyKeyId: Data
    public let validator: any AttestationValidatorProtocol
    private let clock: ClockType

    private let workerKeyToValidation = Mutex<LockedState>(.init())

    internal init(
        logger: Logger,
        id: Int,
        expiry: Date,
        proxyKeyId: Data,
        validator: any AttestationValidatorProtocol,
        clock: ClockType
    ) {
        self.logger = logger
        self.id = id
        self.expiry = expiry
        self.proxyKeyId = proxyKeyId
        self.validator = validator
        self.clock = clock
    }

    // We do not bother to cache failures (but we retain expired entries to keep those invalid).
    // 1. We _never_ expect failures - they are symptomatic of a severe failing in the system
    // 2. the performance impact to retrying a failure is low because each is associated to an
    // expensive to deal with wider request anyway.
    // 3. If there was transitory failure inside the CloudAttestation validation layer we would self heal

    // The validated worker includes the expiration of the key

    private enum ValidationState {
        case pending(_ validation: Promise<ValidatedWorker, Error>, _ id: Int)
        case success(ValidatedWorker)
    }

    // not Sendable, mutated only inside the lock
    private class CacheCounts {
        /// At any point outside one of the mutating functions this can be used as a
        /// valid snapshot of the state of the system
        private(set) var details = CacheMetricSnapshot(sequenceID: 0)
        /// num entries waiting on a specific validation
        private var deduped: [Int: Int] = [:]
        private var nextValidationID = 0
        /// monotonic sequence per proxy cache.
        private var nextSequenceID: Int = 1

        private func nextSeqID() -> Int {
            defer {
                self.nextSequenceID += 1
            }
            return self.nextSequenceID
        }

        func noChange() -> CacheMetricsDelta {
            let delta = CacheMetricsDelta(
                sequenceID: nextSeqID()
            )
            self.details.applyDelta(delta: delta)
            return delta
        }

        func newValidation(
            allowedToAddToCache: Bool
        ) -> (delta: CacheMetricsDelta, id: Int) {
            defer {
                self.nextValidationID += 1
            }
            // Subtle difference here for correctness
            // allowedToAddToCache needs to be added to the *snapshot*
            // but should not be included in the delta we provide, because the delta
            // change for that was pre-applied in advance
            var delta = CacheMetricsDelta(
                sequenceID: nextSeqID(),
                validating: 1,
                allowedToAddToCache: allowedToAddToCache ? 1 : 0
            )
            self.details.applyDelta(delta: delta)
            delta.changes.validatingCacheable = 0
            return (delta, self.nextValidationID)
        }

        func dedupedValidation(_ id: Int) -> CacheMetricsDelta {
            // AllowedToAddToCache ignored, that's a function of
            // the original, even if a duplicate would have allowed it
            // this simplifies things considerably for a minor theoretical
            // additional cache miss
            let delta = CacheMetricsDelta(
                sequenceID: nextSeqID(),
                deduped: 1
            )
            self.details.applyDelta(delta: delta)
            self.deduped[id, default: 0] += 1
            return delta
        }

        func completeValidation(
            _ id: Int,
            allowedToAddToCache: Bool,
            success: Bool
        ) -> CacheMetricsDelta {
            let wereDeduped = self.deduped.removeValue(forKey: id) ?? 0
            let delta = CacheMetricsDelta(
                sequenceID: nextSeqID(),
                validated: success ? 1 : 0,
                validating: -1,
                deduped: -wereDeduped,
                allowedToAddToCache: allowedToAddToCache ? -1 : 0
            )
            self.details.applyDelta(delta: delta)
            return delta
        }
    }

    /// The size of this in memory is the principle driver of the default limit for cache size
    /// If that changes check, and possibly change, the default in
    /// ``CloudBoardAttestationDConfiguration.maximumValidatedEntryCacheSize`` and if need be the jetsam limit
    /// counts is fixed size, the validationTasks is bounded by the concurrent request handling  so it's just:
    /// workerState
    /// Key : 32 bytes
    /// Value: 32 bytes (8 : PublicKey, 8 : Date, 16: String[1])
    /// 1. The  string's actual value is a releaseDigest which should be interned away
    ///
    /// Therefore the cost is the Dictionary overhead for this which, given the load factor of 3/4 and
    /// power of two scaling for the internal buffers gives:
    /// ```
    /// 32 bytes * X (keys)
    /// 32 bytes * X (values)
    /// 32 bits * X (bitset for inuse)
    /// ```
    /// Where X is a power of two larger than 3/4 of the maximum size for each cache
    ///
    private final class LockedState {
        var workerState: [SHA256.Digest: ValidationState] = [:]
        // releaseDigest strings for workers will be from a very limited set so we intern them here to avoid
        // the 64 bytes for each worker.
        // This _could_ be done at the top level, but then we need a way to clear old entries and locking.
        // Doing it on each proxy key is not too much cost/effort and simplifies things
        var internedStrings = Set<String>()
        let counts = CacheCounts()
        // in flight tasks so we can cancel them if they exceed the life of the cache
        var validationTasks = Set<Task<Void, Never>>()
    }

    private struct CacheMetricSnapshot: CustomStringConvertible {
        /// sequenceID of the last delta, these *must* be applied in order
        var sequenceID: Int
        var metrics: CacheMetrics = .init()

        mutating func applyDelta(delta: CacheMetricsDelta) {
            self.metrics.add(delta.changes)
            self.sequenceID = delta.sequenceID
        }

        var description: String {
            "\(self.metrics) sequenceID: \(self.sequenceID)"
        }
    }

    /// Get a snapshot of the size of this cache.
    fileprivate func metricSnapshot() -> (metrics: CacheMetrics, snapshotSequenceID: Int) {
        return self.workerKeyToValidation.withLock {
            let snapshot = $0.counts.details
            return (metrics: snapshot.metrics, snapshotSequenceID: snapshot.sequenceID)
        }
    }

    /// Returns a `ValidatedWorker` if the attestation is valid otherwise it throws
    /// - Parameters:
    ///   - rawWorkerAttestationBundle: The raw attestation bundle of the worker
    ///   - allowedToAddToCache: Can the (successful) result of this call be stored in the validated cache
    ///                          we allow storing in flight validation requests regardless
    ///   - notifySizeChange: This will be called back every time the sizes of the cache changes.
    ///
    /// ``notifySizeChange`` semantics:
    /// All actual deltas will be delivered once and only once except on de-init.
    /// Deltas may not be delivered to the request they were about in some cases (due to deduplication)
    /// but will sum up properly.
    /// Deltas may not arrive in order, they are designed behave correctly under addition
    /// No lock will be held while calling them
    func validateWorkerAttestation(
        workerKeyID: SHA256.Digest,
        rawWorkerAttestationBundle: Data,
        allowedToAddToCache: Bool,
        notifySizeChange: @escaping @Sendable (CacheMetricsDelta) async -> Void
    ) async throws
        -> (
            CloudBoardAttestationDAPI.ValidatedWorker,
            inCache: CloudBoardAttestationMetrics.CloudAttestationValidator.InCache
        ) {
        let (state, newTask, metricDelta) = self.workerKeyToValidation.withLock {
            cache -> (ValidationState, Task<Void, Never>?, CacheMetricsDelta) in
            if let state = cache.workerState[workerKeyID] {
                // we duplicate some work done later to get the metrics counts updated inside the lock
                let metricDelta =
                    switch state {
                    case .pending(_, let id):
                        cache.counts.dedupedValidation(id)
                    case .success:
                        // no sizing change, the hit/miss is dealt with separately
                        cache.counts.noChange()
                    }
                return (state, nil, metricDelta)
            }
            // simple, start the validation as an unstructured task which will then retake the lock
            // to complete things
            let promise = Promise<ValidatedWorker, Error>()
            let (metricDelta, id) = cache.counts.newValidation(allowedToAddToCache: allowedToAddToCache)
            let state = ValidationState.pending(promise, id)
            cache.workerState[workerKeyID] = state
            // Done in the lock so one and only one instance of this specific task will be started
            let task = self.startUnattachedValidationTask(
                workerKeyID: workerKeyID,
                rawWorkerAttestationBundle: rawWorkerAttestationBundle,
                promise: promise,
                id: id,
                allowedToAddToCache: allowedToAddToCache,
                notifySizeChange: notifySizeChange
            )
            cache.validationTasks.insert(task)
            return (state, task, metricDelta)
        }
        await notifySizeChange(metricDelta)
        switch state {
        case .pending(let promise, _):
            let result = try await Future(promise).valueWithCancellation
            if let newTask {
                self.workerKeyToValidation.withLock { cache in
                    _ = cache.validationTasks.remove(newTask)
                }
                return (result, .miss)
            } else {
                return (result, .deduped)
            }
        // no need to notify, all accounting is handled in the completion associated with the original
        case .success(let validated):
            return (validated, .hit)
        }
    }

    private enum SharableValidationState {
        // From the timeout sub task: timeout occurred
        case timeOutTriggered
        // From the timeout sub task: cancelled
        case timeOutCancelled
        // From the validation sub task: sucess or failure it doesn't matter
        case completed
        // From the validation sub task: The parent was deinited
        case parentDeinited
    }

    /// Runs an unstructured task doing the validation in the background, holding no locks.
    /// Once this completes it reaquires the lock to update the state
    /// This is unstructured because of deduplication, we cannot share a single task between two requests
    /// This could be done by each PerProxyAttestationCache maintaining a task group driven by an
    /// async stream of requests, but this is overkill when we simply want to cancel any running ones
    /// if the cache is deinited, and detect long running ones
    private func startUnattachedValidationTask(
        workerKeyID: SHA256.Digest,
        rawWorkerAttestationBundle: Data,
        promise: Promise<ValidatedWorker, Error>,
        id: Int,
        // can this request be stored in the cache once validated
        allowedToAddToCache: Bool,
        // do not hold a lock when calling this
        notifySizeChange: @escaping @Sendable (CacheMetricsDelta) async -> Void
    ) -> Task<Void, Never> {
        // take a strong reference to what we need but weak to self so hanging validations don't leak
        let validator = self.validator
        let clock = self.clock
        let logger = self.logger
        // This task must truly never throw, otherwise we would lose the error
        let logPrefix = "Validation task on \(self.proxyKeyId.hexString) for workerKeyId \(workerKeyID)"
        return Task { [weak self] in
            await withTaskGroup { group in
                // timeout, 10 seconds is extremely conservative, but should prevent hanging validations
                // from taking out the daemon. Each timed out task would be associated with a failed request
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(10), tolerance: .zero, clock: clock)
                        logger.error("\(logPrefix, privacy: .public) timeout")
                        return SharableValidationState.timeOutTriggered
                    } catch is CancellationError {
                        logger.debug("\(logPrefix, privacy: .public) timeout cancelled")
                        return SharableValidationState.timeOutCancelled
                    } catch {
                        logger
                            .error(
                                "\(logPrefix, privacy: .public) unexpected error \(error, privacy: .public) - treating as cancellation"
                            )
                        return SharableValidationState.timeOutCancelled
                    }
                }
                // actual validation and state update
                group.addTask { [weak self] in
                    do {
                        var validated = try await validator.validate(
                            rawAttestationBundle: rawWorkerAttestationBundle
                        )
                        guard let self else {
                            // if we got de-inited then there's nothing to do, any promises were cleaned up already
                            return SharableValidationState.parentDeinited
                        }

                        let metricDelta = self.workerKeyToValidation.withLock { cache in
                            // intern before storing
                            validated.releaseDigest = cache.internedStrings.insert(
                                validated.releaseDigest
                            ).memberAfterInsert

                            // complete the original request, and any others blocking on it as well
                            promise.succeed(with: validated)

                            if allowedToAddToCache {
                                cache.workerState[workerKeyID] = ValidationState.success(validated)
                            } else {
                                cache.workerState.removeValue(forKey: workerKeyID)
                            }
                            return cache.counts.completeValidation(
                                id,
                                allowedToAddToCache: allowedToAddToCache,
                                success: true
                            )
                        }
                        // at this point an error is no longer possible so we can do the notify
                        await notifySizeChange(metricDelta)
                        return SharableValidationState.completed
                    } catch {
                        await Self.logValidationFailure(
                            logger: logger,
                            originalError: error,
                            workerKeyID: workerKeyID,
                            validator: validator,
                            rawWorkerAttestationBundle: rawWorkerAttestationBundle
                        )
                        guard let self else {
                            // if we got de-inited then there's nothing more to do:
                            // * any promises were cleaned up already
                            // * notifyForMetrics is actively harmful, the outer cache dealt with recalculation
                            // if a request was waiting on this it will fail, but liekly it was already failed
                            return SharableValidationState.parentDeinited
                        }
                        // if we got here no cache update or notify can have happened
                        let metricDelta = self.workerKeyToValidation.withLock { cache in
                            let state = cache.workerState.removeValue(forKey: workerKeyID)
                            if case .pending(let promise, _) = state {
                                promise.fail(with: error)
                            }
                            return cache.counts.completeValidation(
                                id,
                                allowedToAddToCache: allowedToAddToCache,
                                success: false
                            )
                        }
                        await notifySizeChange(metricDelta)
                        return SharableValidationState.completed
                    }
                }
                for await event in group {
                    // no matter what the event, we cancel the other one
                    // the validation task will handle the cancellation gracefully
                    group.cancelAll()
                    if case .parentDeinited = event {
                        // implies the unattached Task was cancelled - which is done only in deinit
                        // so we don't need to do anything except log it
                        logger.warning("\(logPrefix, privacy: .public) being discarded as parent was deinited")
                    }
                }
            }
        }
    }

    /// This class is responsible for logging in a consistent fashion so that we can alert
    /// on these events - it indicates a significant failure.
    /// the prefix "WORKER VALIDATION FAILURE:" is trapped for the alerts,
    /// the part after the : can be altered to add more information as desired
    private static func logValidationFailure(
        logger: Logger,
        originalError: any Error,
        workerKeyID: SHA256.Digest,
        validator: any AttestationValidatorProtocol,
        rawWorkerAttestationBundle: Data
    ) async {
        let proxyAttestationDigest = SHA256.hash(data: validator.rawProxyAttestationBundle).description
        let workerAttestationDigest = SHA256.hash(data: rawWorkerAttestationBundle).description

        // lets see if we can parse the release digest
        do {
            let releaseDigest = try await validator.parseReleaseDigest(
                rawAttestationBundle: rawWorkerAttestationBundle
            )
            logger.error(
                """
                WORKER VALIDATION FAILURE: \
                error: \(originalError, privacy: .public) \
                workerKeyID:\(workerKeyID.description, privacy: .public) \
                proxyAttestationDigest: \(proxyAttestationDigest, privacy: .public) \
                workerAttestationDigest: \(workerAttestationDigest, privacy: .public) \
                enableReleaseSetValidation: \(validator.enableReleaseSetValidation, privacy: .public) \
                proxy.proxiedReleaseDigests: \(validator.proxiedReleaseDigests, privacy: .public) \
                worker.releaseDigest: \(releaseDigest, privacy: .public)
                """
            )
        } catch let subsequentError {
            // if not then there's not point trying to get fancy, this is all we can do
            logger.error(
                """
                WORKER VALIDATION FAILURE:
                error: \(originalError, privacy: .public)
                workerKeyID:\(workerKeyID.description, privacy: .public)
                enableReleaseSetValidation: \(validator.enableReleaseSetValidation, privacy: .public)
                proxyAttestationDigest: \(proxyAttestationDigest, privacy: .public)
                workerAttestationDigest: \(workerAttestationDigest, privacy: .public)
                proxy.proxiedReleaseDigests: \(validator.proxiedReleaseDigests, privacy: .public)
                unable to get more details due to: \(subsequentError, privacy: .public)
                """
            )
        }
    }

    deinit {
        // first cancel any pending tasks - we don't want to leak those
        workerKeyToValidation.withLock { cache in
            if !cache.validationTasks.isEmpty {
                let count = cache.validationTasks.count
                self.logger.error(
                    "cleaning up \(count, privacy: .public) pending validation tasks for \(self.proxyKeyId.base64EncodedString(), privacy: .public)"
                )
                for task in cache.validationTasks {
                    task.cancel()
                }
            }
            // Also ensure all promises are completed, there's no need for any notifyMetrics work
            // so we can do all this inside the lock
            for (workerKeyId, promise) in cache.workerState {
                switch promise {
                case .pending(let validationPromise, _):
                    let workerKeyId = Data(workerKeyId)
                    self.logger.error(
                        "cache for \(self.proxyKeyId.base64EncodedString(), privacy: .public) being cleaned up with a pending promise for \(workerKeyId.base64EncodedString(), privacy: .public)"
                    )
                    validationPromise.fail(with: CloudBoardAttestationAPIError.validationTimedOut(
                        requestKeyID: self.proxyKeyId, workerKeyId: workerKeyId
                    ))
                case .success:
                    () // nothing to do
                }
            }
        }
    }
}

private struct CacheMetrics: CustomStringConvertible {
    /// The number of validated entries
    var validated: Int = 0
    /// The number of ongoing validation entries - this includes ``validatingCacheable``
    var validating: Int = 0
    /// The number of entries waiting on another validation (which would be counted in validating)
    var deduped: Int = 0
    // the number of validating entries which will be allowed to store their
    // result into the cache if they suceed
    var validatingCacheable: Int = 0

    /// works for deltas or totals, just addeds all the numbers
    mutating func add(_ other: CacheMetrics) {
        self.validated += other.validated
        self.validating += other.validating
        self.deduped += other.deduped
        self.validatingCacheable += other.validatingCacheable
    }

    var description: String {
        "validated: \(self.validated), validating: \(self.validating), deduped: \(self.deduped), allowedToAddToCache: \(self.validatingCacheable)"
    }
}

/// Changes to the values in ``CacheMetric``
/// if applied out of order the results are the same
private struct CacheMetricsDelta: CustomStringConvertible {
    /// monotonic sequence per proxy cache, but may arrive out of order
    var sequenceID: Int
    var changes: CacheMetrics = .init()

    init(
        sequenceID: Int,
        validated: Int = 0,
        validating: Int = 0,
        deduped: Int = 0,
        allowedToAddToCache: Int = 0
    ) {
        self.sequenceID = sequenceID
        self.changes = .init(
            validated: validated,
            validating: validating,
            deduped: deduped,
            validatingCacheable: allowedToAddToCache
        )
    }

    var description: String {
        "\(self.changes) sequenceId: \(self.sequenceID)"
    }
}

/// Cache entry tracking a worker's UDID to rack ID mapping
/// Entries expire if not updated within the configured TTL (default 1 hour)
/// Timer resets on each successful validation from the same rack, or when a rack change is detected (to extend the
/// blocking period)
internal struct WorkerRackValidationEntry<ClockType: Clock>: Sendable where ClockType.Duration == Duration {
    let hardwareID: HardwareID
    let rackId: RackId
    var lastUpdateInstant: ClockType.Instant
    let lifetimeSinceLastUpdateMinutes: Int

    /// Checks if this entry has expired (last update was longer ago than the configured TTL)
    func isExpired(at currentInstant: ClockType.Instant) -> Bool {
        let elapsed = self.lastUpdateInstant.duration(to: currentInstant)
        return elapsed >= Duration.minutes(self.lifetimeSinceLastUpdateMinutes)
    }

    init(
        hardwareID: HardwareID,
        rackId: RackId,
        creationInstant: ClockType.Instant,
        entryLifetimeMinutes: Int
    ) {
        self.hardwareID = hardwareID
        self.rackId = rackId
        self.lastUpdateInstant = creationInstant
        self.lifetimeSinceLastUpdateMinutes = entryLifetimeMinutes
    }
}
