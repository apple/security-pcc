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
import CloudAttestationV2
import CloudBoardCommon
import CloudBoardLogging
import CloudBoardMetrics
import DequeModule
import Foundation
import InternalSwiftProtobuf
import os
import PrivateCloudCompute
import SwiftProtobuf
import Synchronization

/// Cache for CloudAttestation-provided transparency log entries and consistency proofs used during compute node
/// attestation validation on proxy nodes
///
/// This type conforms to both CloudAttestation v1 and v2 transparency cache protocols that are technically identical
/// but use different types for the same underlying data. We therefore store the actual cached data in serialized form,
/// and deserialize to the requested format on access.
final class CloudBoardTransparencyCache: CloudAttestation.TransparencyCache, CloudAttestationV2.TransparencyCache,
Sendable {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardTransparencyCache"
    )

    struct Configuration: Sendable {
        /// Maximum number of cached transparency log entries. When maximum is reached, least-recently used entries are
        /// removed first.
        var maxLogEntries: Int
        /// Maximum number of cached consistency proofs. When maximum is reached, least-recently used entries are
        /// removed first.
        var maxConsistencyEntries: Int
        /// Interval between periodic expired-entry sweeps for log entries. Set to `.zero` to disable periodic sweeps.
        var expirySweepInterval: TimeInterval
    }

    private struct LogRevisionKey: Hashable, CustomStringConvertible {
        let revision: UInt64
        let treeID: UInt64
        let createdAt: UInt64

        init(_ revision: CloudAttestation.TransparencyLogRevision) {
            self.revision = revision.revision
            self.treeID = revision.treeID
            self.createdAt = revision.createdAt
        }

        init(_ revision: PrivateCloudCompute.TransparencyLogRevision) {
            self.revision = revision.revision
            self.treeID = revision.treeID
            self.createdAt = revision.createdAt
        }

        var description: String {
            "TransparencyLogRevision(\(self.treeID)@\(self.revision))"
        }
    }

    private struct LogEntryKey: Hashable {
        let digest: Data
        let revision: LogRevisionKey
    }

    private struct LogEntryValue {
        let serializedEntry: Data
        let expiry: Date
    }

    private struct LogConsistencyKey: Hashable {
        let from: LogRevisionKey
        let to: LogRevisionKey
    }

    private struct Storage {
        var logEntryStore: [LogEntryKey: LogEntryValue] = [:]
        var logEntryOrder: Deque<LogEntryKey> = []
        var lastExpirySweep: Date = .distantPast

        var consistencyStore: [LogConsistencyKey: Data] = [:]
        var consistencyOrder: Deque<LogConsistencyKey> = []
    }

    private let storage: Mutex<Storage>
    private let configuration: Configuration
    private let metrics: MetricsSystem
    private let clock: any DateAwareClock

    init(
        configuration: Configuration,
        metrics: MetricsSystem,
        clock: any DateAwareClock
    ) {
        self.storage = Mutex(Storage())
        self.configuration = configuration
        self.metrics = metrics
        self.clock = clock
        Self.logger.log("""
        Initialized
        maxLogEntries=\(configuration.maxLogEntries, privacy: .public)
        maxConsistencyEntries=\(configuration.maxConsistencyEntries, privacy: .public)
        expirySweepInterval=\(configuration.expirySweepInterval, privacy: .public)
        """)
    }

    // CloudAttestation.TransparencyCache

    func value(for digest: Data, at revision: CloudAttestation.TransparencyLogRevision) async -> CloudAttestation
    .LogEntry? {
        guard let data = self.lookupLogEntry(digest: digest, revision: LogRevisionKey(revision)) else {
            return nil
        }
        do {
            return try CloudAttestation.LogEntry(serializedBytes: data)
        } catch {
            Self.logger.error("Failed to deserialize cached LogEntry as CloudAttestation.LogEntry: \(error)")
            return nil
        }
    }

    func insert(
        value: CloudAttestation.LogEntry,
        for digest: Data,
        at revision: CloudAttestation.TransparencyLogRevision,
        expiry: Date
    ) async {
        do {
            let data = try value.serializedData()
            self.insertLogEntry(data, digest: digest, revision: LogRevisionKey(revision), expiry: expiry)
        } catch {
            Self.logger.error("Failed to serialize CloudAttestation.LogEntry for caching: \(error)")
        }
    }

    func value(
        from: CloudAttestation.TransparencyLogRevision,
        to: CloudAttestation.TransparencyLogRevision
    ) async -> CloudAttestation.LogConsistency? {
        guard let data = self.lookupLogConsistency(from: LogRevisionKey(from), to: LogRevisionKey(to)) else {
            return nil
        }
        do {
            return try CloudAttestation.LogConsistency(serializedBytes: data)
        } catch {
            Self.logger
                .error("Failed to deserialize cached LogConsistency as CloudAttestation.LogConsistency: \(error)")
            return nil
        }
    }

    func insert(
        value: CloudAttestation.LogConsistency,
        from: CloudAttestation.TransparencyLogRevision,
        to: CloudAttestation.TransparencyLogRevision
    ) async {
        do {
            let data = try value.serializedData()
            self.insertLogConsistency(data, from: LogRevisionKey(from), to: LogRevisionKey(to))
        } catch {
            Self.logger.error("Failed to serialize CloudAttestation.LogConsistency for caching: \(error)")
        }
    }

    // CloudAttestationV2.TransparencyCache

    func value(for digest: Data, at revision: PrivateCloudCompute.TransparencyLogRevision) async -> PrivateCloudCompute
    .LogEntry? {
        guard let data = self.lookupLogEntry(digest: digest, revision: LogRevisionKey(revision)) else {
            return nil
        }
        do {
            return try PrivateCloudCompute.LogEntry(serializedBytes: data)
        } catch {
            Self.logger.error("Failed to deserialize cached LogEntry as PrivateCloudCompute.LogEntry: \(error)")
            return nil
        }
    }

    func insert(
        value: PrivateCloudCompute.LogEntry,
        for digest: Data,
        at revision: PrivateCloudCompute.TransparencyLogRevision,
        expiry: Date
    ) async {
        do {
            let data = try value.serializedData()
            self.insertLogEntry(data, digest: digest, revision: LogRevisionKey(revision), expiry: expiry)
        } catch {
            Self.logger.error("Failed to serialize PrivateCloudCompute.LogEntry for caching: \(error)")
        }
    }

    func value(
        from: PrivateCloudCompute.TransparencyLogRevision,
        to: PrivateCloudCompute.TransparencyLogRevision
    ) async -> PrivateCloudCompute.LogConsistency? {
        guard let data = self.lookupLogConsistency(from: LogRevisionKey(from), to: LogRevisionKey(to)) else {
            return nil
        }
        do {
            return try PrivateCloudCompute.LogConsistency(serializedBytes: data)
        } catch {
            Self.logger
                .error("Failed to deserialize cached LogConsistency as PrivateCloudCompute.LogConsistency: \(error)")
            return nil
        }
    }

    func insert(
        value: PrivateCloudCompute.LogConsistency,
        from: PrivateCloudCompute.TransparencyLogRevision,
        to: PrivateCloudCompute.TransparencyLogRevision
    ) async {
        do {
            let data = try value.serializedData()
            self.insertLogConsistency(data, from: LogRevisionKey(from), to: LogRevisionKey(to))
        } catch {
            Self.logger.error("Failed to serialize PrivateCloudCompute.LogConsistency for caching: \(error)")
        }
    }

    private func lookupLogEntry(digest: Data, revision: LogRevisionKey) -> Data? {
        let now = self.clock.dateNow
        return self.storage.withLock { storage in
            let key = LogEntryKey(digest: digest, revision: revision)
            guard let cached = storage.logEntryStore[key] else {
                Self.logger.log("""
                LogEntry cache miss
                digest=\(digest.base64EncodedString(), privacy: .public)
                revision=\(revision, privacy: .public)
                """)
                self.metrics
                    .emit(CloudBoardAttestationMetrics.TransparencyCache.LogEntryMissCounter(action: .increment))
                return nil
            }
            if cached.expiry <= now {
                // Lazy expiry: remove expired entry on access
                storage.logEntryStore.removeValue(forKey: key)
                storage.logEntryOrder.removeAll(where: { $0 == key })
                Self.logger.log("""
                LogEntry expired on access
                digest=\(digest.base64EncodedString(), privacy: .public)
                revision=\(revision, privacy: .public)
                expiry=\(cached.expiry, privacy: .public)
                """)
                self.metrics
                    .emit(CloudBoardAttestationMetrics.TransparencyCache.LogEntryEvictionCounter(action: .increment))
                self.metrics
                    .emit(
                        CloudBoardAttestationMetrics.TransparencyCache
                            .LogEntryCacheCountGauge(value: storage.logEntryStore.count)
                    )
                self.metrics
                    .emit(CloudBoardAttestationMetrics.TransparencyCache.LogEntryMissCounter(action: .increment))
                return nil
            }
            // LRU: move to back of deque
            if let index = storage.logEntryOrder.firstIndex(of: key) {
                storage.logEntryOrder.remove(at: index)
                storage.logEntryOrder.append(key)
            }
            Self.logger.log("""
            LogEntry cache hit
            digest=\(digest.base64EncodedString(), privacy: .public)
            revision=\(revision, privacy: .public)
            """)
            self.metrics.emit(CloudBoardAttestationMetrics.TransparencyCache.LogEntryHitCounter(action: .increment))
            return cached.serializedEntry
        }
    }

    private func insertLogEntry(_ serializedEntry: Data, digest: Data, revision: LogRevisionKey, expiry: Date) {
        let now = self.clock.dateNow
        self.storage.withLock { storage in
            let key = LogEntryKey(digest: digest, revision: revision)

            // If key already exists, update value in place and refresh LRU position
            if storage.logEntryStore[key] != nil {
                storage.logEntryStore[key] = LogEntryValue(serializedEntry: serializedEntry, expiry: expiry)
                if let index = storage.logEntryOrder.firstIndex(of: key) {
                    storage.logEntryOrder.remove(at: index)
                    storage.logEntryOrder.append(key)
                }
                Self.logger.log("""
                LogEntry updated
                digest=\(digest.base64EncodedString(), privacy: .public)
                revision=\(revision, privacy: .public)
                expiry=\(expiry, privacy: .public)
                """)
                return
            }

            // Periodic sweep of expired entries
            self.sweepExpiredLogEntriesIfNeeded(storage: &storage, now: now)

            // Evict if at capacity
            if self.configuration.maxLogEntries > 0, storage.logEntryStore.count >= self.configuration.maxLogEntries {
                self.removeExpiredLogEntries(storage: &storage, now: now)
            }
            while self.configuration.maxLogEntries > 0,
                  storage.logEntryStore.count >= self.configuration.maxLogEntries {
                self.evictLRULogEntry(storage: &storage)
            }

            // Insert
            storage.logEntryStore[key] = LogEntryValue(serializedEntry: serializedEntry, expiry: expiry)
            storage.logEntryOrder.append(key)
            let logEntryStoreCount = storage.logEntryStore.count
            Self.logger.log("""
            LogEntry inserted
            digest=\(digest.base64EncodedString(), privacy: .public)
            revision=\(revision, privacy: .public)
            expiry=\(expiry, privacy: .public)
            count=\(logEntryStoreCount, privacy: .public)
            """)
            self.metrics
                .emit(
                    CloudBoardAttestationMetrics.TransparencyCache
                        .LogEntryCacheCountGauge(value: storage.logEntryStore.count)
                )
        }
    }

    private func lookupLogConsistency(from: LogRevisionKey, to: LogRevisionKey) -> Data? {
        self.storage.withLock { storage in
            let key = LogConsistencyKey(from: from, to: to)
            guard storage.consistencyStore[key] != nil else {
                Self.logger.log("""
                LogConsistency cache miss
                from=\(from, privacy: .public)
                to=\(to, privacy: .public)
                """)
                self.metrics
                    .emit(CloudBoardAttestationMetrics.TransparencyCache.LogConsistencyMissCounter(action: .increment))
                return nil
            }
            // LRU: move to back of deque
            if let index = storage.consistencyOrder.firstIndex(of: key) {
                storage.consistencyOrder.remove(at: index)
                storage.consistencyOrder.append(key)
            }
            Self.logger.log("""
            LogConsistency cache hit
            from=\(from, privacy: .public)
            to=\(to, privacy: .public)
            """)
            self.metrics
                .emit(CloudBoardAttestationMetrics.TransparencyCache.LogConsistencyHitCounter(action: .increment))
            return storage.consistencyStore[key]
        }
    }

    private func insertLogConsistency(_ serializedConsistency: Data, from: LogRevisionKey, to: LogRevisionKey) {
        self.storage.withLock { storage in
            let key = LogConsistencyKey(from: from, to: to)

            // If key already exists, update value in place and refresh LRU position
            if storage.consistencyStore[key] != nil {
                storage.consistencyStore[key] = serializedConsistency
                if let index = storage.consistencyOrder.firstIndex(of: key) {
                    storage.consistencyOrder.remove(at: index)
                    storage.consistencyOrder.append(key)
                }
                Self.logger.log("""
                LogConsistency entry updated
                from=\(from, privacy: .public)
                to=\(to, privacy: .public)
                """)
                return
            }

            // LRU eviction if at capacity
            while self.configuration.maxConsistencyEntries > 0,
                  storage.consistencyStore.count >= self.configuration.maxConsistencyEntries {
                self.evictLRUConsistencyEntry(storage: &storage)
            }

            storage.consistencyStore[key] = serializedConsistency
            storage.consistencyOrder.append(key)
            let consistencyStoreCount = storage.consistencyStore.count
            Self.logger.log("""
            LogConsistency entry inserted
            from=\(from, privacy: .public)
            to=\(to, privacy: .public)
            count=\(consistencyStoreCount, privacy: .public)
            """)
            self.metrics.emit(
                CloudBoardAttestationMetrics.TransparencyCache
                    .LogConsistencyCacheCountGauge(value: storage.consistencyStore.count)
            )
        }
    }

    /// Sweep expired LogEntry entries if the configured sweep interval has elapsed
    private func sweepExpiredLogEntriesIfNeeded(storage: inout Storage, now: Date) {
        let sweepInterval = self.configuration.expirySweepInterval
        guard sweepInterval > 0 else { return }
        guard now.timeIntervalSince(storage.lastExpirySweep) >= sweepInterval else { return }
        storage.lastExpirySweep = now
        self.removeExpiredLogEntries(storage: &storage, now: now)
    }

    /// Remove all expired LogEntry entries from the store
    private func removeExpiredLogEntries(storage: inout Storage, now: Date) {
        var evictedCount = 0
        storage.logEntryOrder.removeAll { key in
            guard let cached = storage.logEntryStore[key], cached.expiry <= now else {
                return false
            }
            storage.logEntryStore.removeValue(forKey: key)
            evictedCount += 1
            return true
        }
        if evictedCount > 0 {
            let logEntryStoreCount = storage.logEntryStore.count
            Self.logger.log("""
            Swept expired LogEntry entries
            evictedCount=\(evictedCount, privacy: .public)
            remaining=\(logEntryStoreCount, privacy: .public)
            """)
            self.metrics
                .emit(
                    CloudBoardAttestationMetrics.TransparencyCache
                        .LogEntryEvictionCounter(action: .increment(by: evictedCount))
                )
        }
    }

    /// Evict the least-recently-used LogEntry
    private func evictLRULogEntry(storage: inout Storage) {
        guard let key = storage.logEntryOrder.popFirst() else { return }
        storage.logEntryStore.removeValue(forKey: key)
        Self.logger.log("""
        Evicted least-recently-used LogEntry entry
        digest=\(key.digest.base64EncodedString(), privacy: .public)
        revision=\(key.revision, privacy: .public)
        """)
        self.metrics.emit(CloudBoardAttestationMetrics.TransparencyCache.LogEntryEvictionCounter(action: .increment))
    }

    /// Evict the least-recently-used LogConsistency entry
    private func evictLRUConsistencyEntry(storage: inout Storage) {
        guard let key = storage.consistencyOrder.popFirst() else { return }
        storage.consistencyStore.removeValue(forKey: key)
        Self.logger.log("""
        Evicted least-recently-used LogConsistency entry
        from=\(key.from, privacy: .public)
        to=\(key.to, privacy: .public)
        """)
        self.metrics
            .emit(CloudBoardAttestationMetrics.TransparencyCache.LogConsistencyEvictionCounter(action: .increment))
    }
}
