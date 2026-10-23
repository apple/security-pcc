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

import CloudBoardController
import os
import Synchronization

/// Tracks the health status of a cloud app workload and broadcasts changes to watchers.
///
/// ## State Diagram
///
/// The monitor has two orthogonal state dimensions: the **reported status** (`lastUpdate`)
/// and the **maintenance condition set**. Together they determine what watchers observe.
///
/// ```
///                         ┌─────────────────────────────────────────────────────────────┐
///                         │              Reported Status (lastUpdate)                    │
///                         │                                                             │
///                         │   .initializing ──updateStatus──▶ .healthy / .unhealthy     │
///                         │         ▲                               │                    │
///                         │         │                          updateStatus              │
///                         │       (init)                           │                     │
///                         │                                        ▼                    │
///                         │                              .healthy ◀──▶ .unhealthy       │
///                         │                                                             │
///                         │   updateStatus() ALWAYS writes lastUpdate, regardless of    │
///                         │   maintenance. Watchers are only notified when NOT under     │
///                         │   maintenance.                                               │
///                         └─────────────────────────────────────────────────────────────┘
///
///                         ┌─────────────────────────────────────────────────────────────┐
///                         │            Maintenance Conditions (Set<Maintenance>)         │
///                         │                                                             │
///                         │   Conditions: .waitingForInitialAssets                       │
///                         │               .attestationInvalid                            │
///                         │               .restartingJobHelpers                          │
///                         │               .prewarmingFailed                               │
///                         │               .draining                                      │
///                         │                                                             │
///                         │   Multiple conditions can be active simultaneously.          │
///                         │   The set is empty (not under maintenance) or non-empty      │
///                         │   (under maintenance).                                       │
///                         └─────────────────────────────────────────────────────────────┘
///
/// ## Watcher Notification Rules
///
/// ```
///   ┌──────────────────┐    enterMaintenance(X)     ┌──────────────────┐
///   │  NOT under        │──────────────────────────▶│  Under            │
///   │  maintenance      │   conditions: {} → {X}    │  maintenance      │
///   │                   │   watchers get .unhealthy  │                   │
///   │  watch() primes   │                            │  watch() primes   │
///   │  with lastUpdate  │                            │  with .unhealthy  │
///   │                   │                            │                   │
///   │  updateStatus()   │    exitMaintenance(X)      │  updateStatus()   │
///   │  notifies watchers│◀──────────────────────────│  suppressed, but  │
///   │                   │   conditions: {X} → {}     │  lastUpdate still │
///   │                   │   watchers get lastUpdate   │  updated          │
///   └──────────────────┘                             └──────────────────┘
///                                                      │            ▲
///                                                      │            │
///                                          enterMaintenance(Y)  exitMaintenance(Y)
///                                          conditions: {X}→{X,Y}  {X,Y}→{X}
///                                          no notification       no notification
///                                          (already under        (still under
///                                           maintenance)          maintenance)
/// ```
///
/// ## Lifecycle (typical startup sequence)
///
/// ```
///   1. init()
///      └─ lastUpdate = .initializing, maintenanceConditions = {}
///
///   2. enterMaintenance(.waitingForInitialAssets)         [WorkloadManager.run()]
///      └─ watchers notified with .unhealthy (if any exist)
///      └─ new watchers primed with .unhealthy
///
///   3. WorkloadController sends updateStatus(.healthy)    [gRPC from cloud app controller]
///      └─ lastUpdate = .healthy(...), but watchers NOT notified (under maintenance)
///
///   4. Initial assets received
///      └─ exitMaintenance(.waitingForInitialAssets)        [AssetsMetadataManager]
///      └─ watchers notified with lastUpdate (.healthy)
///
///   5. Normal operation
///      └─ updateStatus() notifies watchers normally
///
///   6. Newer assets arrive
///      └─ enterMaintenance(.restartingJobHelpers)          [AssetsMetadataManager]
///      └─ restart prewarmed instances
///      └─ exitMaintenance(.restartingJobHelpers)
///      └─ watchers notified with lastUpdate
///
///   7. Shutdown
///      └─ drain() → enterMaintenance(.draining)            [never exits]
///      └─ terminate() → finishes all watcher streams
/// ```
public final class ServiceHealthMonitor: Sendable {
    private static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ServiceHealthMonitor"
    )

    package let cloudApp: String
    /// When true, the reported `maxBatchSize`/`optimalBatchSize` account for the number of available prewarmed
    /// instances (see `applyPrewarm`). Changes to that count are re-broadcast to watchers.
    private let maxBatchDependsOnPrewarmedSize: Bool
    private let currentState: Mutex<State>

    public init(cloudApp: String, maxBatchDependsOnPrewarmedSize: Bool = false) {
        self.cloudApp = cloudApp
        self.maxBatchDependsOnPrewarmedSize = maxBatchDependsOnPrewarmedSize
        self.currentState = Mutex(State(
            nextID: 0,
            watchers: [],
            lastUpdate: .initializing,
            configuredMaxBatchSize: 0,
            currentBatchSizeOverride: nil,
            availablePrewarmedInstances: 0,
            maintenanceConditions: []
        ))
    }

    /// This permanently overrides the current request (batch) count. Used if CloudBoard is configured to keep track
    /// of the current count instead of reporting what the cloud app controller provides us with
    public func overrideCurrentRequestCount(count: Int) {
        self.currentState.withLock { state in
            state.currentBatchSizeOverride = count
        }
    }

    /// The number of prewarmed instances currently ready to serve a request immediately.
    public var availablePrewarmedInstances: Int {
        self.currentState.withLock { $0.availablePrewarmedInstances }
    }

    /// The controller-configured leader `maxBatchSize` — the concurrency ceiling the node could serve if every
    /// instance were warm. This reflects what the controller configured and does not change with transient health
    /// state (e.g. busy / transitioning). Zero until a leader has reported a configuration.
    public var configuredMaxBatchSize: Int {
        self.currentState.withLock { $0.configuredMaxBatchSize }
    }

    /// Updates the number of prewarmed instances ready to serve a request immediately. When
    /// `maxBatchDependsOnPrewarmedSize` is enabled this re-broadcasts the recomputed load level to all watchers so
    /// ROPES sees the change (the value feeds `maxBatchSize = min(configuredMax, currentBatchSize + available)`).
    public func updateAvailablePrewarmedInstances(count: Int) {
        let toNotify: ([Watcher], Status)? = self.currentState.withLock { state in
            state.availablePrewarmedInstances = count
            // Only the prewarm-aware path cares about this value, and only watchers not under maintenance
            // should be notified.
            guard self.maxBatchDependsOnPrewarmedSize, !state.isUnderMaintenance else {
                return nil
            }
            return (state.watchers, self.effectiveStatus(state))
        }

        guard let (watchers, status) = toNotify else {
            return
        }
        for watcher in watchers {
            watcher.continuation.yield(status)
        }
    }

    /// Applies the configured current-batch override and the prewarm-aware capacity reduction to produce the
    /// status that should be reported to watchers. The prewarm reduction is deliberately *not* baked into
    /// `lastUpdate` so it can be recomputed when the available prewarmed count changes.
    private func effectiveStatus(_ state: State) -> Status {
        let withOverride = state.lastUpdate.withCurrentBatchCountOverride(state.currentBatchSizeOverride)
        return self.applyPrewarm(withOverride, availablePrewarmed: state.availablePrewarmedInstances)
    }

    /// Reduces the reported capacity to what is immediately servable given the number of available prewarmed
    /// instances. No-op unless `maxBatchDependsOnPrewarmedSize` is enabled and the status is healthy.
    private func applyPrewarm(_ status: Status, availablePrewarmed: Int) -> Status {
        guard self.maxBatchDependsOnPrewarmedSize else {
            return status
        }
        switch status {
        case .healthy(.leader(let loadLevel)):
            let effectiveMax = min(loadLevel.maxBatchSize, loadLevel.currentBatchSize + availablePrewarmed)
            let effectiveOptimal = min(loadLevel.optimalBatchSize, effectiveMax)
            return .healthy(.leader(.init(
                workloadType: loadLevel.workloadType,
                tags: loadLevel.tags,
                maxBatchSize: effectiveMax,
                currentBatchSize: loadLevel.currentBatchSize,
                optimalBatchSize: effectiveOptimal
            )))
        case .healthy(.follower), .healthy(.persistentService), .initializing, .unhealthy, .terminal:
            return status
        }
    }

    /// The status to surface to watchers while under maintenance. Maintenance normally reports `.unhealthy`, but a
    /// `.terminal` last update is preserved: terminal is an unrecoverable override that maintenance must not mask
    /// (masking it would drop the terminal aggregation override in `HealthServer`).
    private func maintenanceStatus(_ state: State) -> Status {
        state.lastUpdate == .terminal ? .terminal : .unhealthy
    }

    /// Snapshot of effective health status, accounting for maintenance state, batch-size override and prewarmed
    /// availability.
    public var currentStatus: Status {
        self.currentState.withLock { state in
            if state.isUnderMaintenance {
                return self.maintenanceStatus(state)
            }
            return self.effectiveStatus(state)
        }
    }

    public func updateStatus(_ status: Status) {
        let (watchers, statusWithOverride): ([Watcher], Status) = self.currentState.withLock { state in
            // Persist only the current-batch override; the prewarm reduction is applied at emission time.
            state.lastUpdate = status.withCurrentBatchCountOverride(state.currentBatchSizeOverride)

            // Remember the configured concurrency ceiling. A leader reports maxBatchSize == 0 while busy /
            // transitioning, which is a transient advertised value, not a reconfiguration — so only update on a
            // non-zero report to keep configuredMaxBatchSize stable across busy periods.
            if case .healthy(.leader(let loadLevel)) = status, loadLevel.maxBatchSize > 0 {
                state.configuredMaxBatchSize = loadLevel.maxBatchSize
            }

            // do not notify watchers when under maintenance
            if state.isUnderMaintenance {
                return ([], state.lastUpdate)
            }
            return (state.watchers, self.effectiveStatus(state))
        }

        for watcher in watchers {
            watcher.continuation.yield(statusWithOverride)
        }
    }

    public func drain() {
        self.enterMaintenance(.draining)
    }

    public func setAttestationInvalid() {
        self.enterMaintenance(.attestationInvalid)
    }

    public func setAttestationValid() {
        self.exitMaintenance(.attestationInvalid)
    }

    public func terminate() {
        Self.logger.debug("ServiceHealthMonitor::\(self.cloudApp, privacy: .public) terminate called")
        // We _must_ call `finish` from outside the lock, otherwise we'll
        // deadlock.
        let watchers = self.currentState.withLock { state in
            defer { state.watchers = [] }
            return state.watchers
        }

        for watcher in watchers {
            watcher.continuation.finish()
        }
    }

    public func watch() -> AsyncStream<Status> {
        let (stream, continuation) = AsyncStream<Status>.makeStream()

        self.currentState.withLock { state in
            let id = state.generateID()
            let watcher = Watcher(continuation: continuation, id: id)

            state.watchers.append(watcher)
            let count = state.watchers.count
            Self.logger
                .debug(
                    "ServiceHealthMonitor::\(self.cloudApp, privacy: .public) watch called \(count, privacy: .public)"
                )

            continuation.onTermination = { _ in
                self.watcherTerminated(id: id)
            }

            // Prime the pump with the last value to ensure that order of operations
            // isn't an issue. If under maintenance, prime with the maintenance status (unhealthy, or terminal if
            // the last update was terminal) so new watchers see the correct suppressed state.
            if state.isUnderMaintenance {
                continuation.yield(self.maintenanceStatus(state))
            } else {
                continuation.yield(self.effectiveStatus(state))
            }
        }

        return stream
    }

    public func enterMaintenance(_ maintenance: Maintenance) {
        let watchers: [Watcher] = self.currentState.withLock { state in
            // already in this maintenance condition
            if state.maintenanceConditions.contains(maintenance) {
                return []
            }
            state.maintenanceConditions.insert(maintenance)

            // Already reporting a non-serving state to watchers (via last update or OTHER maintenance conditions), so
            // there is nothing new to notify. `.terminal` is included so entering maintenance does not downgrade a
            // terminal service to a plain `.unhealthy` (which would drop the terminal aggregation override).
            let alreadyNotServing = state.lastUpdate == .unhealthy || state.lastUpdate == .terminal
            if alreadyNotServing || state.maintenanceConditions.count > 1 {
                return []
            }
            return state.watchers
        }

        for watcher in watchers {
            watcher.continuation.yield(.unhealthy)
        }
    }

    public func exitMaintenance(_ maintenance: Maintenance) {
        let (watchers, status): ([Watcher], Status) = self.currentState.withLock { state in
            // not under this maintenance condition - don't notify watchers
            if !state.maintenanceConditions.contains(maintenance) {
                return ([], state.lastUpdate)
            }

            state.maintenanceConditions.remove(maintenance)

            // still under other maintenance conditions - don't notify watchers
            if !state.maintenanceConditions.isEmpty {
                return ([], state.lastUpdate)
            }

            // not under any maintenance - notify watchers about the last update. Emit the *effective* status (not
            // the raw lastUpdate) so the prewarm reduction is reapplied: e.g. after restartPrewarmedInstances the
            // ready queue was cleared and availablePrewarmedInstances dropped to 0 while suppressed under
            // maintenance, so the capacity advertised on exit must reflect that, not the pre-restart maxBatchSize.
            return (state.watchers, self.effectiveStatus(state))
        }

        for watcher in watchers {
            watcher.continuation.yield(status)
        }
    }

    private func watcherTerminated(id: Int) {
        self.currentState.withLock { state in
            if let index = state.watchers.firstIndex(where: { $0.id == id }) {
                state.watchers.remove(at: index)
            }
        }
    }
}

extension ServiceHealthMonitor {
    // Conditions where service is unhealthy due to CloudBoard internal reasons.
    public enum Maintenance: Sendable {
        case draining
        case attestationInvalid
        case restartingJobHelpers
        case prewarmingFailed
        case waitingForInitialAssets
    }

    private struct State {
        var nextID: Int

        var watchers: [Watcher]

        var lastUpdate: Status

        /// The controller-configured leader `maxBatchSize` — the concurrency ceiling the node could serve if every
        /// instance were warm. Captured from `updateStatus` whenever a leader reports a non-zero `maxBatchSize`, and
        /// deliberately *not* cleared when the leader transiently reports zero (e.g. while busy / transitioning), so
        /// it always reflects what the controller configured rather than the momentary advertised capacity.
        var configuredMaxBatchSize: Int

        var currentBatchSizeOverride: Int?

        var availablePrewarmedInstances: Int

        var maintenanceConditions: Set<Maintenance>

        var isUnderMaintenance: Bool {
            !self.maintenanceConditions.isEmpty
        }

        mutating func generateID() -> Int {
            defer { self.nextID &+= 1 }
            return self.nextID
        }
    }

    struct Watcher {
        var continuation: AsyncStream<Status>.Continuation
        var id: Int
    }

    public enum Status: Sendable, Hashable, CustomStringConvertible {
        case initializing
        case healthy(Healthy)
        case unhealthy
        /// Terminally unhealthy: the service has failed in a way it cannot recover from on its own (e.g. a persistent
        /// service that exhausted its asset download retries during initialization). Unlike `.unhealthy` — which a
        /// service may report transiently while still converging — `.terminal` is a signal that the node should be
        /// re-converged externally. `HealthServer` treats a single `.terminal` publisher as making the whole node
        /// unhealthy, even while other publishers are still `.initializing`.
        case terminal

        public var description: String {
            switch self {
            case .initializing:
                return "initializing"
            case .unhealthy:
                return "unhealthy"
            case .terminal:
                return "terminal"
            case .healthy(let healthy):
                return "healthy (\(healthy))"
            }
        }

        public func withCurrentBatchCountOverride(_ count: Int?) -> Status {
            guard let count else {
                return self
            }
            switch self {
            case .initializing:
                return .initializing
            case .unhealthy:
                return .unhealthy
            case .terminal:
                return .terminal
            case .healthy(.follower):
                // A follower reports no load level, so there is nothing to override.
                return .healthy(.follower)
            case .healthy(.persistentService):
                // A persistent service reports no load level, so there is nothing to override.
                return .healthy(.persistentService)
            case .healthy(.leader(let loadLevel)):
                return .healthy(.leader(.init(
                    workloadType: loadLevel.workloadType,
                    tags: loadLevel.tags,
                    maxBatchSize: loadLevel.maxBatchSize,
                    currentBatchSize: count,
                    optimalBatchSize: loadLevel.optimalBatchSize
                )))
            }
        }
    }
}

extension ServiceHealthMonitor.Status {
    /// A healthy node's reporting mode. A leader serves requests and advertises a concrete load level; a follower
    /// is healthy and reachable but does not serve requests; a persistent service is healthy and registered but
    /// reports no load level. Neither follower nor persistent service has a load level to advertise.
    public enum Healthy: Sendable, Hashable, CustomStringConvertible {
        case leader(LoadLevel)
        case follower
        case persistentService

        public var description: String {
            switch self {
            case .leader(let loadLevel):
                return "leader (\(loadLevel))"
            case .follower:
                return "follower"
            case .persistentService:
                return "persistentService"
            }
        }
    }

    /// The capacity a leader node advertises to ROPES.
    public struct LoadLevel: Sendable, Hashable, CustomStringConvertible {
        public var workloadType: String

        public var tags: [String: RoutingTagValue]

        public var maxBatchSize: Int

        public var currentBatchSize: Int

        public var optimalBatchSize: Int

        public init(
            workloadType: String,
            tags: [String: RoutingTagValue],
            maxBatchSize: Int,
            currentBatchSize: Int,
            optimalBatchSize: Int
        ) {
            self.workloadType = workloadType
            self.tags = tags
            self.maxBatchSize = maxBatchSize
            self.currentBatchSize = currentBatchSize
            self.optimalBatchSize = optimalBatchSize
        }

        public var description: String {
            """
            workloadType: \(self.workloadType), maxBatchSize: \(self.maxBatchSize), \
            currentBatchSize: \(self.currentBatchSize), optimalBatchSize: \(self.optimalBatchSize)
            """
        }
    }
}
