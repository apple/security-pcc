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

import CloudBoardControllerCore
import CloudBoardProtos
import CloudBoardUtilities
import Configuration
import GRPCCore
import Logging
import Metrics
import ServiceLifecycle
import Synchronization

final class ServiceStatusMonitor: Service, Sendable {
    private static let logger = Logger(label: "cloudboardd.ServiceStatusMonitor")

    private struct ServiceState {

        private struct ActiveState {
            var nextID: Int = 0
            var watchers: [Watcher] = []
            var drainIdleContinuation: CheckedContinuation<Void, Never>?
            var busyIdleContinuation: CheckedContinuation<Void, Never>?
        }

        private enum LifecycleState {
            case active(ActiveState)
            case terminated
        }

        private enum DrainPhase { case notDraining, draining, drained }

        private var lifecycleState: LifecycleState
        var components: [String: ComponentState]
        private var drainPhase: DrainPhase = .notDraining
        var concurrentRequestCount: Int
        var configuredMaxConcurrentRequests: Int
        var optimalConcurrentRequests: Int
        var availablePrewarmedInstances: Int = 0
        /// Refcount of affinity keys held by in-flight requests; a key is present iff at least
        /// one in-flight request holds it. Drives ``InvokeWorkloadLoadState/affinityKeysInProgress``.
        var affinityKeyCounts: [AffinityKeyIdentity: Int] = [:]
        /// Whether the projected load level is bounded by prewarmed availability. Derived once
        /// from the monitor's ``PrewarmLoadLevelMode`` at init; the config keys and the mode
        /// itself live solely on the monitor.
        let boundLoadLevelByPrewarmed: Bool

        init(
            components: [String: ComponentStatus],
            configuredMaxConcurrentRequests: Int,
            optimalConcurrentRequests: Int,
            boundLoadLevelByPrewarmed: Bool
        ) {
            self.lifecycleState = .active(ActiveState())
            self.components = components.mapValues {
                ComponentState(status: $0, updatedAt: .now)
            }
            self.concurrentRequestCount = 0
            self.configuredMaxConcurrentRequests = configuredMaxConcurrentRequests
            self.optimalConcurrentRequests = optimalConcurrentRequests
            self.boundLoadLevelByPrewarmed = boundLoadLevelByPrewarmed
        }

        var isDraining: Bool { drainPhase == .draining }

        /// Transitions to draining. Returns true if there are no in-flight requests.
        mutating func beginDraining() -> Bool {
            guard drainPhase == .notDraining else { return false }
            drainPhase = .draining
            return concurrentRequestCount == 0
        }

        mutating func completeDrain() {
            drainPhase = .drained
        }

        var isTerminated: Bool {
            if case .terminated = lifecycleState { return true }
            return false
        }

        var watchers: [Watcher] {
            guard case .active(let active) = lifecycleState else { return [] }
            return active.watchers
        }

        var drainIdleContinuation: CheckedContinuation<Void, Never>? {
            get {
                guard case .active(let active) = lifecycleState else { return nil }
                return active.drainIdleContinuation
            }
            set {
                guard case .active(var active) = lifecycleState else { return }
                active.drainIdleContinuation = newValue
                lifecycleState = .active(active)
            }
        }

        var busyIdleContinuation: CheckedContinuation<Void, Never>? {
            get {
                guard case .active(let active) = lifecycleState else { return nil }
                return active.busyIdleContinuation
            }
            set {
                guard case .active(var active) = lifecycleState else { return }
                active.busyIdleContinuation = newValue
                lifecycleState = .active(active)
            }
        }

        mutating func generateID() -> Int {
            guard case .active(var active) = lifecycleState else {
                preconditionFailure("generateID called on terminated ServiceState")
            }
            let id = active.nextID
            active.nextID = active.nextID &+ 1
            lifecycleState = .active(active)
            return id
        }

        mutating func addWatcher(_ watcher: Watcher) {
            guard case .active(var active) = lifecycleState else { return }
            active.watchers.append(watcher)
            lifecycleState = .active(active)
        }

        mutating func removeWatcher(id: Int) {
            guard case .active(var active) = lifecycleState else { return }
            if let index = active.watchers.firstIndex(where: { $0.id == id }) {
                active.watchers.remove(at: index)
            }
            lifecycleState = .active(active)
        }

        /// Transitions to terminated and returns watchers and any pending continuations to unblock.
        mutating func terminateAndDrainWatchers() -> (
            watchers: [Watcher],
            drainIdleContinuation: CheckedContinuation<Void, Never>?,
            busyIdleContinuation: CheckedContinuation<Void, Never>?
        ) {
            guard case .active(let active) = lifecycleState else { return ([], nil, nil) }
            lifecycleState = .terminated
            return (active.watchers, active.drainIdleContinuation, active.busyIdleContinuation)
        }

        /// The load state advertised to watchers and used to enforce the concurrency limit.
        ///
        /// When ``boundLoadLevelByPrewarmed`` is set, the effective max/optimal are bounded by
        /// the prewarm pool so capacity reflects what can be served right now.
        func currentLoadState() -> InvokeWorkloadLoadState {
            // When capacity is bounded by the prewarm pool, the effective max/optimal
            // shrink to what can actually be served right now: in-flight requests plus
            // the prewarmed instances ready to pick up new work.
            guard boundLoadLevelByPrewarmed else {
                return .init(
                    concurrentRequestCount: concurrentRequestCount,
                    maxConcurrentRequests: configuredMaxConcurrentRequests,
                    optimalConcurrentRequests: optimalConcurrentRequests,
                    affinityKeysInProgress: sortedAffinityKeys()
                )
            }
            let effectiveMax = min(
                configuredMaxConcurrentRequests,
                concurrentRequestCount + availablePrewarmedInstances
            )
            let effectiveOptimal = min(optimalConcurrentRequests, effectiveMax)
            return .init(
                concurrentRequestCount: concurrentRequestCount,
                maxConcurrentRequests: effectiveMax,
                optimalConcurrentRequests: effectiveOptimal,
                affinityKeysInProgress: sortedAffinityKeys()
            )
        }

        // Subcomponent statuses — the aggregate drives the Status exposed to watchers.
        // Severity ordering: terminalError > transientError > busy > initializing > degraded > ready.
        // When multiple components share the same worst severity, we produce a richer
        // description than the single-component case (e.g. "waiting for X, Y" or
        // "2 subcomponents busy: reason1; reason2") so callers have actionable context.
        func aggregateState() -> State {
            guard !isTerminated else { return .drained }
            switch drainPhase {
            case .draining: return .draining
            case .drained: return .drained
            case .notDraining:
                var initializingComponents: [(name: String, phase: String)] = []
                var degradedComponents: [(name: String, detail: String)] = []
                var busyComponents: [(name: String, detail: String)] = []
                var transientComponents: [(name: String, detail: String)] = []
                var terminalComponents: [(name: String, detail: String)] = []

                for (name, componentState) in components.sorted(by: { $0.key < $1.key }) {
                    switch componentState.status {
                    case .ready: break
                    case .initializing(let phase): initializingComponents.append((name, phase))
                    case .degraded(let reason): degradedComponents.append((name, reason))
                    case .busy(let reason): busyComponents.append((name, reason))
                    case .transientError(let message): transientComponents.append((name, message))
                    case .terminalError(let message): terminalComponents.append((name, message))
                    }
                }

                if !terminalComponents.isEmpty {
                    return .terminalError(
                        message: Self.aggregateDetail(terminalComponents, plural: "subcomponents failed")
                    )
                }
                if !transientComponents.isEmpty {
                    return .transientError(
                        message: Self.aggregateDetail(transientComponents, plural: "subcomponents in transient error")
                    )
                }
                if !busyComponents.isEmpty {
                    return .busy(reason: Self.aggregateDetail(busyComponents, plural: "subcomponents busy"))
                }
                if !initializingComponents.isEmpty {
                    let phase =
                        initializingComponents.count == 1
                        ? (initializingComponents[0].phase.isEmpty
                            ? initializingComponents[0].name
                            : initializingComponents[0].phase)
                        : "waiting for \(initializingComponents.map { $0.name }.joined(separator: ", "))"
                    return .initializing(phase: phase)
                }
                if !degradedComponents.isEmpty {
                    return .degraded(
                        reason: Self.aggregateDetail(degradedComponents, plural: "subcomponents degraded"),
                        loadState: currentLoadState()
                    )
                }

                return components.isEmpty
                    ? .initializing(phase: "")
                    : .ready(currentLoadState())
            }
        }

        func currentStatus() -> Status {
            .init(
                components: components.mapValues { $0.status },
                aggregateState: aggregateState(),
                loadState: currentLoadState()
            )
        }

        /// Distinct in-flight affinity keys in ascending order for a deterministic emit order.
        func sortedAffinityKeys() -> [AffinityKeyIdentity] {
            affinityKeyCounts.keys.sorted()
        }

        /// Builds an aggregate detail string from a list of named components.
        /// - Single component: passes its detail through unchanged.
        /// - Multiple components: produces "<n> <plural>: detail1; detail2",
        ///   falling back to the component name when its detail string is empty.
        private static func aggregateDetail(
            _ components: [(name: String, detail: String)],
            plural: String
        ) -> String {
            guard components.count > 1 else {
                let component = components[0]
                return component.detail.isEmpty ? component.name : component.detail
            }
            let details = components.map { $0.detail.isEmpty ? $0.name : $0.detail }.joined(separator: "; ")
            return "\(components.count) \(plural): \(details)"
        }
    }

    private struct Watcher {
        var continuation: AsyncStream<Status>.Continuation
        var id: Int
    }

    private let lockedState: Mutex<ServiceState>
    private let metricsFactory: any MetricsFactory
    private let cloudAppWarmupPool: CloudAppWarmupPool
    private let extraCloudAppsOverMaxBatchSize: Int
    private let prewarmLoadLevelMode: PrewarmLoadLevelMode

    /// How the prewarm pool influences the load level reported to ROPES and request admission.
    /// Derived from the two `warmupPool.*` config flags.
    private enum PrewarmLoadLevelMode {
        /// Load level is derived solely from the configured maximum; the prewarm pool is ignored.
        case ignorePrewarmed
        /// Load level is bounded by prewarmed availability; a request that arrives with no
        /// prewarmed instance ready is rejected so ROPES can re-route.
        case rejectOnShortfall
        /// Load level is bounded by prewarmed availability; a request that arrives with no
        /// prewarmed instance ready is admitted (within the hard ceiling) and waits for one.
        case waitOnShortfall

        init(maxBatchDependsOnPrewarmedSize: Bool, waitForPrewarmedInstance: Bool) {
            switch (maxBatchDependsOnPrewarmedSize, waitForPrewarmedInstance) {
            case (false, _): self = .ignorePrewarmed
            case (true, false): self = .rejectOnShortfall
            case (true, true): self = .waitOnShortfall
            }
        }

        /// Whether the load level reported to ROPES is bounded by prewarmed availability.
        var boundsLoadLevelByPrewarmed: Bool {
            switch self {
            case .ignorePrewarmed: return false
            case .rejectOnShortfall, .waitOnShortfall: return true
            }
        }

        /// Whether a prewarm-shortfall request waits for an instance rather than being rejected.
        var waitsForPrewarmedInstance: Bool {
            switch self {
            case .ignorePrewarmed, .rejectOnShortfall: return false
            case .waitOnShortfall: return true
            }
        }
    }

    private static func readExtraCloudAppsOverMaxBatchSize(configReader: ConfigReader) -> Int {
        max(
            configReader.int(
                forKey: "warmupPool.extraCloudAppsOverMaxBatchSize",
                default: 10
            ),
            0
        )
    }

    private static func readMaxBatchDependsOnPrewarmedSize(configReader: ConfigReader) -> Bool {
        configReader.bool(
            forKey: "warmupPool.maxBatchDependsOnPrewarmedSize",
            default: false
        )
    }

    private static func readWaitForPrewarmedInstance(configReader: ConfigReader) -> Bool {
        configReader.bool(
            forKey: "warmupPool.waitForPrewarmedInstance",
            default: false
        )
    }

    public init(
        cloudAppWarmupPool: CloudAppWarmupPool,
        extraCloudAppsOverMaxBatchSize: Int,
        maxBatchDependsOnPrewarmedSize: Bool = false,
        waitForPrewarmedInstance: Bool = false,
        metricsFactory: any MetricsFactory = MetricsSystem.factory
    ) {
        self.cloudAppWarmupPool = cloudAppWarmupPool
        self.extraCloudAppsOverMaxBatchSize = extraCloudAppsOverMaxBatchSize
        self.prewarmLoadLevelMode = PrewarmLoadLevelMode(
            maxBatchDependsOnPrewarmedSize: maxBatchDependsOnPrewarmedSize,
            waitForPrewarmedInstance: waitForPrewarmedInstance
        )
        self.metricsFactory = metricsFactory
        self.lockedState = .init(
            ServiceState(
                components: [
                    ComponentName.workload: .initializing(phase: "awaiting initial workload status"),
                    ComponentName.serviceDiscovery: .initializing(phase: "awaiting initial Service Discovery status"),
                    ComponentName.attestation: .initializing(phase: "awaiting cb_attestationd connection"),
                ],
                configuredMaxConcurrentRequests: 0,
                optimalConcurrentRequests: 0,
                boundLoadLevelByPrewarmed: self.prewarmLoadLevelMode.boundsLoadLevelByPrewarmed
            )
        )
    }

    public convenience init(
        configReader: ConfigReader,
        cloudAppWarmupPool: CloudAppWarmupPool,
        metricsFactory: any MetricsFactory = MetricsSystem.factory
    ) {
        self.init(
            cloudAppWarmupPool: cloudAppWarmupPool,
            extraCloudAppsOverMaxBatchSize: Self.readExtraCloudAppsOverMaxBatchSize(configReader: configReader),
            maxBatchDependsOnPrewarmedSize: Self.readMaxBatchDependsOnPrewarmedSize(configReader: configReader),
            waitForPrewarmedInstance: Self.readWaitForPrewarmedInstance(configReader: configReader),
            metricsFactory: metricsFactory
        )
    }

    public init(
        controllerProvidedConfiguration: ControllerProvidedConfiguration,
        cloudAppWarmupPool: CloudAppWarmupPool,
        extraCloudAppsOverMaxBatchSize: Int,
        maxBatchDependsOnPrewarmedSize: Bool = false,
        waitForPrewarmedInstance: Bool = false,
        metricsFactory: any MetricsFactory = MetricsSystem.factory
    ) {
        self.cloudAppWarmupPool = cloudAppWarmupPool
        self.extraCloudAppsOverMaxBatchSize = extraCloudAppsOverMaxBatchSize
        self.prewarmLoadLevelMode = PrewarmLoadLevelMode(
            maxBatchDependsOnPrewarmedSize: maxBatchDependsOnPrewarmedSize,
            waitForPrewarmedInstance: waitForPrewarmedInstance
        )
        self.metricsFactory = metricsFactory
        let initialBatchSize = controllerProvidedConfiguration.computeWorkloadConfig.maxBatchSize
        self.cloudAppWarmupPool.targetCapacity = Self.targetCapacity(
            maxConcurrentRequests: initialBatchSize,
            extraCloudAppsOverMaxBatchSize: extraCloudAppsOverMaxBatchSize
        )
        self.lockedState = .init(
            ServiceState(
                components: [
                    ComponentName.workload: .initializing(phase: "awaiting initial workload status"),
                    ComponentName.serviceDiscovery: .initializing(phase: "awaiting initial Service Discovery status"),
                    ComponentName.attestation: .initializing(phase: "awaiting cb_attestationd connection"),
                ],
                configuredMaxConcurrentRequests: initialBatchSize,
                optimalConcurrentRequests: controllerProvidedConfiguration.computeWorkloadConfig.optimalBatchSize,
                boundLoadLevelByPrewarmed: self.prewarmLoadLevelMode.boundsLoadLevelByPrewarmed
            )
        )
    }

    public convenience init(
        controllerProvidedConfiguration: ControllerProvidedConfiguration,
        configReader: ConfigReader,
        cloudAppWarmupPool: CloudAppWarmupPool,
        metricsFactory: any MetricsFactory = MetricsSystem.factory
    ) {
        self.init(
            controllerProvidedConfiguration: controllerProvidedConfiguration,
            cloudAppWarmupPool: cloudAppWarmupPool,
            extraCloudAppsOverMaxBatchSize: Self.readExtraCloudAppsOverMaxBatchSize(configReader: configReader),
            maxBatchDependsOnPrewarmedSize: Self.readMaxBatchDependsOnPrewarmedSize(configReader: configReader),
            waitForPrewarmedInstance: Self.readWaitForPrewarmedInstance(configReader: configReader),
            metricsFactory: metricsFactory
        )
    }

    /// Consumes the warmup pool's capacity stream, feeding the available count into the load
    /// state so watchers and the rejection branch see how many prewarmed instances can serve
    /// new requests. Returns immediately (no consumption) when prewarm-size gating is disabled.
    /// Runs until the stream ends or the task is cancelled.
    private func consumePrewarmPoolCapacity() async {
        guard self.prewarmLoadLevelMode.boundsLoadLevelByPrewarmed else {
            return
        }
        for await capacity in self.cloudAppWarmupPool.capacityChanges {
            self.updateAvailablePrewarmedInstances(count: capacity.available)
        }
    }

    var currentState: State {
        self.lockedState.withLock {
            $0.aggregateState()
        }
    }

    var availablePrewarmedInstances: Int {
        self.lockedState.withLock { $0.availablePrewarmedInstances }
    }

    var affinityKeysInProgress: [AffinityKeyIdentity] {
        self.lockedState.withLock { $0.sortedAffinityKeys() }
    }

    /// Updates the count of prewarmed instances ready to serve new requests, notifying
    /// watchers when the resulting load state could change.
    ///
    /// Notification is skipped when prewarm gating is off, the count is unchanged, or the
    /// monitor isn't actively serving (only `.ready`/`.degraded` embed the reduced load state).
    func updateAvailablePrewarmedInstances(count: Int) {
        guard self.prewarmLoadLevelMode.boundsLoadLevelByPrewarmed else { return }
        self.lockedState.withLock { state in
            guard state.availablePrewarmedInstances != count else { return }
            state.availablePrewarmedInstances = count
            switch state.aggregateState() {
            case .ready, .degraded:
                // Notify under the lock so the snapshot reflects the state this update produced
                // and concurrent updaters can't interleave a stale snapshot.
                notifyWatchers(
                    state.watchers,
                    with: state.currentStatus()
                )
            case .initializing, .transientError, .busy, .terminalError, .draining, .drained:
                return
            }
        }
    }

    /// Increments the refcount for each given affinity key (one in-flight request started holding them).
    /// Notifies watchers only if the distinct key set changed (some key went 0→1) and the node is serving.
    /// - Parameter ids: Pre-deduplicated identities; the registration handle dedups before calling.
    func addAffinityKeys(_ ids: [AffinityKeyIdentity]) {
        guard !ids.isEmpty else { return }
        self.lockedState.withLock { state in
            guard !state.isTerminated else { return }
            var distinctSetChanged = false
            for id in ids {
                let old = state.affinityKeyCounts[id, default: 0]
                if old == 0 { distinctSetChanged = true }
                state.affinityKeyCounts[id] = old + 1
            }
            guard distinctSetChanged else { return }
            switch state.aggregateState() {
            case .ready, .degraded:
                notifyWatchers(state.watchers, with: state.currentStatus())
            case .initializing, .transientError, .busy, .terminalError, .draining, .drained:
                return
            }
        }
    }

    /// Decrements the refcount for each given affinity key; removes a key at 0 (a request stopped holding it).
    /// Notifies watchers only if the distinct key set changed (some key went 1→0) and the node is serving.
    /// - Parameter ids: Pre-deduplicated identities; the registration handle dedups before calling.
    func removeAffinityKeys(_ ids: [AffinityKeyIdentity]) {
        guard !ids.isEmpty else { return }
        self.lockedState.withLock { state in
            guard !state.isTerminated else { return }
            let distinctSetChanged = self._removeAffinityKeysLocked(&state, ids: ids)
            guard distinctSetChanged else { return }
            switch state.aggregateState() {
            case .ready, .degraded:
                notifyWatchers(state.watchers, with: state.currentStatus())
            case .initializing, .transientError, .busy, .terminalError, .draining, .drained:
                return
            }
        }
    }

    /// Decrements the refcount for each given identity, removing any that reach 0.
    /// - Returns: `true` if the distinct key set changed (some key went 1→0), so the caller can
    ///   decide whether to notify watchers. Does not notify or check termination itself.
    @discardableResult
    private func _removeAffinityKeysLocked(_ state: inout ServiceState, ids: [AffinityKeyIdentity]) -> Bool {
        var distinctSetChanged = false
        for id in ids {
            guard let old = state.affinityKeyCounts[id] else { continue }
            if old <= 1 {
                state.affinityKeyCounts[id] = nil
                distinctSetChanged = true
            } else {
                state.affinityKeyCounts[id] = old - 1
            }
        }
        return distinctSetChanged
    }

    func componentState(_ name: String) -> ComponentState? {
        self.lockedState.withLock { $0.components[name] }
    }

    func run() async throws {
        defer {
            Self.logger.info("ServiceStatusMonitor shutting down, terminating all watchers")
            terminate()
        }

        let initialStatus = self.lockedState.withLock {
            $0.currentStatus()
        }
        let initialComponents = initialStatus.components
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        Self.logger.info(
            "ServiceStatusMonitor started",
            metadata: [
                "initialState": "\(initialStatus.aggregateState)",
                "components": "\(initialComponents)",
            ]
        )

        // Feed prewarmed-instance availability into the load state for as long as the monitor
        // runs (a no-op when prewarm gating is off), then tear the feed down on shutdown.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.consumePrewarmPoolCapacity() }
            defer { group.cancelAll() }
            // Wait for shutdown
            try await gracefulShutdown()
        }
    }

    func terminate() {
        Self.logger.info("ServiceStatusMonitor terminate called")
        // We _must_ call `finish` from outside the lock, otherwise we'll
        // deadlock.
        let (watchers, drainIdleContinuation, busyIdleContinuation) = self.lockedState.withLock { state in
            state.terminateAndDrainWatchers()
        }

        for watcher in watchers {
            watcher.continuation.finish()
        }
        drainIdleContinuation?.resume()
        busyIdleContinuation?.resume()
    }

    func watch() -> AsyncStream<Status> {
        let (stream, continuation) = AsyncStream<Status>.makeStream()

        self.lockedState.withLock { state in
            guard !state.isTerminated else {
                // Finish the continuation right away
                continuation.finish()
                return
            }
            let id = state.generateID()
            let watcher = Watcher(continuation: continuation, id: id)

            state.addWatcher(watcher)
            let count = state.watchers.count
            Self.logger.debug("ServiceStatusMonitor watch called", metadata: ["currentWatcherCount": "\(count)"])

            continuation.onTermination = { _ in
                self.watcherTerminated(id: id)
            }

            // Prime the pump with the current status to ensure that order of
            // operations isn't an issue.
            continuation.yield(
                state.currentStatus()
            )
        }

        return stream
    }

    private func watcherTerminated(id: Int) {
        self.lockedState.withLock { state in
            state.removeWatcher(id: id)
        }
    }

    private func notifyWatchers(_ watchers: [Watcher], with status: Status) {
        for watcher in watchers {
            watcher.continuation.yield(status)
        }
    }

    /// Snapshot of one component-state mutation, returned by ``_lockedUpdateComponentState``
    /// so the caller can do logging and watcher notification outside the lock.
    private struct ComponentStateUpdate {
        var oldComponent: ComponentStatus?
        var oldStatus: Status
        var newStatus: Status
        var watchers: [Watcher]
    }

    private func _lockedUpdateComponentState(
        state: inout ServiceState,
        name: String,
        status: ComponentStatus
    ) -> ComponentStateUpdate? {
        guard !state.isTerminated else { return nil }

        let oldStatus = state.currentStatus()
        let oldComponent = state.components[name]?.status
        if oldComponent != status {
            state.components[name] = ComponentState(status: status, updatedAt: .now)
        }
        return ComponentStateUpdate(
            oldComponent: oldComponent,
            oldStatus: oldStatus,
            newStatus: state.currentStatus(),
            watchers: state.watchers
        )
    }

    private static func targetCapacity(
        maxConcurrentRequests: Int,
        extraCloudAppsOverMaxBatchSize: Int
    ) -> Int {
        guard maxConcurrentRequests > 0 else {
            return 0
        }
        return maxConcurrentRequests + extraCloudAppsOverMaxBatchSize
    }

    private func targetCapacity(maxConcurrentRequests: Int) -> Int {
        Self.targetCapacity(
            maxConcurrentRequests: maxConcurrentRequests,
            extraCloudAppsOverMaxBatchSize: self.extraCloudAppsOverMaxBatchSize
        )
    }

    private func _lockedWarmupPoolTargetCapacity(
        state: inout ServiceState,
        status: ComponentStatus
    ) -> Int {
        if status.isBusy {
            return 0
        }
        return self.targetCapacity(
            maxConcurrentRequests: state.configuredMaxConcurrentRequests
        )
    }

    func updateComponentState(name: String, status: ComponentStatus) {
        let statusUpdate = self.lockedState.withLock { state in
            precondition(
                name != ComponentName.workload,
                "Use updateWorkloadState(_:) for workload component updates"
            )
            return self._lockedUpdateComponentState(
                state: &state,
                name: name,
                status: status
            )
        }

        guard let statusUpdate else {
            return
        }
        self.publishStateUpdate(
            name: name,
            status: status,
            update: statusUpdate
        )
    }

    /// Workload state is handled speparately from other components because it
    /// drives the warmup pool, including waiting for the pool to reduce the capacity
    /// to 0. In case we're entering busy state.
    /// This is the reason for it being an `async` function, contrary to the other component.
    func updateWorkloadState(_ status: ComponentStatus) async {
        let name = ComponentName.workload
        let statusUpdate: (ComponentStateUpdate, Int)? = self.lockedState.withLock { state in
            guard
                let update = self._lockedUpdateComponentState(
                    state: &state,
                    name: name,
                    status: status
                )
            else {
                return nil
            }
            let poolTargetCapacity = self._lockedWarmupPoolTargetCapacity(
                state: &state,
                status: status
            )

            return (update, poolTargetCapacity)
        }

        guard let (componentUpdate, targetCapacity) = statusUpdate else {
            return
        }
        self.publishStateUpdate(
            name: name,
            status: status,
            update: componentUpdate
        )
        self.cloudAppWarmupPool.targetCapacity = targetCapacity

        if status.isBusy {
            do {
                try await self.cloudAppWarmupPool.waitForEmpty()
            } catch {
                Self.logger.error(
                    "Warmup pool drain interrupted on busy transition",
                    metadata: [
                        "error": "\(String(reportable: error))"
                    ]
                )
            }
        }
    }

    private func publishStateUpdate(
        name: String,
        status: ComponentStatus,
        update: ComponentStateUpdate
    ) {
        guard update.oldStatus != update.newStatus else { return }
        Self.logger.info(
            "Component state updated",
            metadata: [
                "component": "\(name)",
                "componentFrom": "\(update.oldComponent.map { "\($0)" } ?? "nil")",
                "componentTo": "\(status)",
                "from": "\(update.oldStatus.aggregateState)",
                "to": "\(update.newStatus.aggregateState)",
            ]
        )
        notifyWatchers(update.watchers, with: update.newStatus)
    }

    func updateLoadConfiguration(_ config: ComputeWorkloadConfig) {
        let (watchers, newStatus, isBusy): ([Watcher], Status, Bool) = self.lockedState.withLock { state in
            guard !state.isTerminated else {
                return (
                    [],
                    state.currentStatus(), false
                )
            }
            let oldStatus = state.currentStatus()
            state.configuredMaxConcurrentRequests = config.maxBatchSize
            state.optimalConcurrentRequests = config.optimalBatchSize
            let newStatus = state.currentStatus()
            let isBusy = state.components[ComponentName.workload]?.status.isBusy ?? false
            guard oldStatus != newStatus else { return ([], newStatus, isBusy) }
            return (state.watchers, newStatus, isBusy)
        }
        // Only resize the pool when the workload is not draining for a busy transition;
        // if we're busy, the pool stays at zero until we go back to ready.
        if !isBusy {
            self.cloudAppWarmupPool.targetCapacity = self.targetCapacity(
                maxConcurrentRequests: config.maxBatchSize
            )
        }

        notifyWatchers(watchers, with: newStatus)
    }

    /// Transitions the monitor to `.draining`, rejecting all new requests.
    ///
    /// Suspends until all in-flight requests finish (i.e. `concurrentRequestCount` drops to 0).
    /// Returns immediately if there are no in-flight requests when called.
    func beginDraining() async {
        let (watchers, status, idle): ([Watcher], Status, Bool) = self.lockedState.withLock { state in
            let idle = state.beginDraining()
            return (
                state.watchers,
                state.currentStatus(),
                idle
            )
        }
        notifyWatchers(watchers, with: status)

        guard !idle else { return }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Re-check under lock: requests may have completed between the first lock release
                // and storing the continuation. If already cancelled, reclaim it in the same lock
                // so there's no window for monitoringLoad to race with a second lock acquisition.
                let shouldResume = self.lockedState.withLock { state -> Bool in
                    if state.concurrentRequestCount == 0 {
                        return true
                    }
                    state.drainIdleContinuation = continuation
                    if Task.isCancelled {
                        state.drainIdleContinuation = nil
                        return true
                    }
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            // Unblock the waiter and clear the slot so monitoringLoad doesn't resume it later.
            // Calling .resume() inside the lock is safe: CheckedContinuation.resume() only
            // enqueues the waiter on the executor — it does not run it synchronously.
            self.lockedState.withLock { state in
                state.drainIdleContinuation?.resume()
                state.drainIdleContinuation = nil
            }
        }
    }

    /// Transitions the monitor to `.drained`, unblocking SD deregistration.
    func completeDrain() {
        let (watchers, status): ([Watcher], Status) = self.lockedState.withLock { state in
            state.completeDrain()
            return (
                state.watchers,
                state.currentStatus()
            )
        }
        notifyWatchers(watchers, with: status)
    }

    /// Waits until all in-flight requests complete and (when configured) the warmup pool
    /// has drained to zero managed instances. Doesn't change the monitor's drain state.
    ///
    /// Used by the busy-state transition to block the `setState(.busy)` RPC response until
    /// the node is fully idle: no in-flight requests AND no pre-warmed cb_jobhelpers.
    /// Returns early if the calling task is cancelled while waiting on the pool.
    func waitForIdle() async {
        await self.waitForInFlightRequestsCompletion()
        try? await self.cloudAppWarmupPool.waitForEmpty()
    }

    private func waitForInFlightRequestsCompletion() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Re-check under lock: requests may have completed before the continuation is
                // stored. If already cancelled, reclaim it in the same lock so there's no window
                // for monitoringLoad to race with a second lock acquisition.
                let shouldResume = self.lockedState.withLock { state -> Bool in
                    if state.concurrentRequestCount == 0 {
                        return true
                    }
                    state.busyIdleContinuation = continuation
                    if Task.isCancelled {
                        state.busyIdleContinuation = nil
                        return true
                    }
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            // Unblock the waiter and clear the slot so monitoringLoad doesn't resume it later.
            // Calling .resume() inside the lock is safe: CheckedContinuation.resume() only
            // enqueues the waiter on the executor — it does not run it synchronously.
            self.lockedState.withLock { state in
                state.busyIdleContinuation?.resume()
                state.busyIdleContinuation = nil
            }
        }
    }

    /// Keeps track of the current load with each invocation of this function contributing to it, and enforces the
    /// configured concurrency limit.
    ///
    /// This currently does not take into account any concurrency-impacting cleanup that goes beyond responding to the
    /// request (e.g. waiting for per-request processes to have terminated, or waiting for pre-warming of additional
    /// request handling processes).
    /// - Parameter body: function that contributes to the load of the system. Once the function returns, the load level
    /// is lowered accordingly. The function is passed the pre-request load state and an
    /// ``AffinityKeyRegistration`` bound to this monitor; any keys it activates are removed atomically
    /// with the load-count decrement when the body returns.
    /// - Returns: Result of the provided function
    func monitoringLoad<ReturnType>(
        body: @Sendable (InvokeWorkloadLoadState, AffinityKeyRegistration) async throws -> ReturnType,
    ) async throws -> ReturnType {
        let (oldLoadState, watchersToNotify, newStatus):
            (
                InvokeWorkloadLoadState, [Watcher], Status
            ) = try self.lockedState.withLock { state in
                let aggregate = state.aggregateState()
                let oldLoadState: InvokeWorkloadLoadState
                switch aggregate {
                case .initializing:
                    throw ServiceStatusError.initializing
                case .transientError(let message):
                    throw ServiceStatusError.transientError(message: message)
                case .terminalError(let message):
                    throw ServiceStatusError.terminalError(message: message)
                case .busy(let reason):
                    throw ServiceStatusError.busy(reason: reason)
                case .ready(let loadState), .degraded(_, let loadState):
                    oldLoadState = loadState
                case .drained:
                    throw ServiceStatusError.drained
                case .draining:
                    throw ServiceStatusError.draining
                }
                if oldLoadState.concurrentRequestCount == oldLoadState.maxConcurrentRequests {
                    // Distinguish "genuinely at the hard concurrency ceiling" from "blocked only
                    // because no prewarmed instance is ready" using the raw (unreduced) capacity.
                    // The shortfall case applies only when there is still configured headroom
                    // (current < configured max) that simply has no warm instance to fill it; once
                    // current reaches the configured max, warming more instances cannot admit the
                    // request, so it is a real ceiling rejection. The headroom check also implies a
                    // non-zero configured max.
                    let isPrewarmShortfall =
                        self.prewarmLoadLevelMode.boundsLoadLevelByPrewarmed
                        && state.concurrentRequestCount < state.configuredMaxConcurrentRequests
                        && state.availablePrewarmedInstances == 0
                    // When configured to wait, admit a prewarm-shortfall request rather than
                    // rejecting it: the headroom check guarantees we stay within the hard ceiling,
                    // and the executor blocks on the warmup pool until an instance becomes ready.
                    if !(isPrewarmShortfall && self.prewarmLoadLevelMode.waitsForPrewarmedInstance) {
                        Self.logger.warning(
                            "Rejecting incoming request because it would exceed the number of maximum concurrent requests",
                            metadata: [
                                "concurrentRequests": "\(oldLoadState.concurrentRequestCount)",
                                "optimalConcurrentRequests":
                                    "\(oldLoadState.optimalConcurrentRequests.map { "\($0)" } ?? "nil")",
                                "maxConcurrentRequests": "\(oldLoadState.maxConcurrentRequests)",
                            ]
                        )
                        Counter(
                            label: "cloudboard_max_concurrent_request_count_rejected_total",
                            factory: self.metricsFactory
                        ).increment()
                        if isPrewarmShortfall {
                            throw ServiceStatusError.maxConcurrentRequestsExceededNotEnoughPrewarmed
                        }
                        throw ServiceStatusError.maxConcurrentRequestsExceeded
                    }
                    Self.logger.info(
                        "Admitting incoming request despite no prewarmed instance being ready; waiting for one to free up",
                        metadata: [
                            "concurrentRequests": "\(state.concurrentRequestCount)",
                            "configuredMaxConcurrentRequests": "\(state.configuredMaxConcurrentRequests)",
                        ]
                    )
                }
                Self.logger.info(
                    "Accepting incoming request",
                    metadata: [
                        "concurrentRequests": "\(oldLoadState.concurrentRequestCount)",
                        "optimalConcurrentRequests":
                            "\(oldLoadState.optimalConcurrentRequests.map { "\($0)" } ?? "nil")",
                        "maxConcurrentRequests": "\(oldLoadState.maxConcurrentRequests)",
                    ]
                )
                state.concurrentRequestCount += 1
                return (
                    oldLoadState, state.watchers,
                    state.currentStatus()
                )
            }

        notifyWatchers(watchersToNotify, with: newStatus)

        // Owns this request's affinity-key lifecycle. The body activates it (mid-request, once
        // `Parameters` arrives); teardown's single locked block below removes those ids together
        // with the load-count decrement so one notify reflects both changes.
        let affinityRegistration = AffinityKeyRegistration(monitor: self)

        defer {
            let (watchers, status, drainContinuation, busyContinuation):
                ([Watcher], Status, CheckedContinuation<Void, Never>?, CheckedContinuation<Void, Never>?) =
                    self.lockedState.withLock { state in
                        state.concurrentRequestCount -= 1
                        if !state.isTerminated {
                            self._removeAffinityKeysLocked(&state, ids: affinityRegistration.registeredIdentities())
                        }
                        var drainContinuation: CheckedContinuation<Void, Never>? = nil
                        var busyContinuation: CheckedContinuation<Void, Never>? = nil
                        if state.concurrentRequestCount == 0 {
                            // Only wake drain waiters during graceful shutdown (beginDraining flow).
                            if state.isDraining {
                                drainContinuation = state.drainIdleContinuation
                                state.drainIdleContinuation = nil
                            }
                            // Always wake busy waiters — independent of drain state.
                            busyContinuation = state.busyIdleContinuation
                            state.busyIdleContinuation = nil
                        }
                        return (
                            state.watchers,
                            state.currentStatus(),
                            drainContinuation, busyContinuation
                        )
                    }

            notifyWatchers(watchers, with: status)
            drainContinuation?.resume()
            busyContinuation?.resume()
        }

        return try await body(oldLoadState, affinityRegistration)
    }
}

extension ServiceStatusMonitor {
    /// Hashable/Comparable stand-in for `Proto_CloudBoard_AffinityKey`, which is `Equatable`
    /// but not `Hashable` and so cannot key a dictionary or be deduplicated directly.
    ///
    /// `category` preserves unknown categories (`.UNRECOGNIZED`) so identities round-trip back to
    /// the same proto. CloudBoard never interprets `category`; it only echoes keys.
    struct AffinityKeyIdentity: Hashable, Sendable, Comparable {
        var category: Proto_CloudBoard_AffinityKey.Category
        var data: UInt64

        init(_ proto: Proto_CloudBoard_AffinityKey) {
            self.category = proto.category
            self.data = proto.data
        }

        var proto: Proto_CloudBoard_AffinityKey {
            .with {
                $0.category = self.category
                $0.data = self.data
            }
        }

        /// Lexicographic over `(category, data)` for a deterministic emit order.
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.category.rawValue != rhs.category.rawValue {
                return lhs.category.rawValue < rhs.category.rawValue
            }
            return lhs.data < rhs.data
        }
    }
}

extension ServiceStatusMonitor {
    enum ComponentName {
        static let workload = "workload"
        static let serviceDiscovery = "serviceDiscovery"
        static let attestation = "attestation"
    }
}

extension ServiceStatusMonitor {
    enum ComponentStatus: Equatable {
        case initializing(phase: String)
        case ready
        case degraded(reason: String)
        case busy(reason: String)  // workload temporarily unavailable (e.g. recycling)
        case transientError(message: String)
        case terminalError(message: String)

        var isBusy: Bool {
            if case .busy = self { return true }
            return false
        }
    }

    struct ComponentState: Equatable {
        var status: ComponentStatus
        var updatedAt: ContinuousClock.Instant

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.status == rhs.status
        }
    }
}

extension ServiceStatusMonitor {
    /// Snapshot of the system status, emitted by `watch()` on every state change.
    ///
    /// Pairs the raw per-component states with the aggregate state, so each watcher
    /// can choose the level of detail it needs.
    struct Status: Sendable, Equatable {
        var components: [String: ComponentStatus]
        var aggregateState: State
        var loadState: InvokeWorkloadLoadState
    }
}

extension ServiceStatusMonitor {
    struct InvokeWorkloadLoadState: Sendable, Hashable, CustomStringConvertible {
        var concurrentRequestCount: Int
        var maxConcurrentRequests: Int
        var optimalConcurrentRequests: Int?
        /// Distinct affinity keys held by in-flight requests, in ascending order. Echoed in
        /// load reporting; never affects readiness or admission.
        var affinityKeysInProgress: [AffinityKeyIdentity] = []

        public var description: String {
            "current: \(concurrentRequestCount), optimal: \(optimalConcurrentRequests.map { "\($0)" } ?? "nil"), max: \(maxConcurrentRequests)"
        }
    }

    enum State: Sendable, Hashable, CustomStringConvertible {
        case initializing(phase: String)
        case ready(InvokeWorkloadLoadState)
        case degraded(reason: String, loadState: InvokeWorkloadLoadState)  // impaired but still serving
        case transientError(message: String)  // non-functional but self-recoverable
        case busy(reason: String)  // workload temporarily unavailable (e.g. recycling)
        case terminalError(message: String)  // non-recoverable error
        case draining
        case drained

        var description: String {
            switch self {
            case .initializing(let phase):
                return phase.isEmpty ? "initializing" : "initializing(\(phase))"
            case .ready(let loadState):
                return "ready(\(loadState))"
            case .degraded(let reason, _):
                return reason.isEmpty ? "degraded" : "degraded(\(reason))"
            case .transientError(let message):
                return message.isEmpty ? "transientError" : "transientError(\(message))"
            case .busy(let reason):
                return reason.isEmpty ? "busy" : "busy(\(reason))"
            case .terminalError(let message):
                return message.isEmpty ? "terminalError" : "terminalError(\(message))"
            case .drained:
                return "drained"
            case .draining:
                return "draining"
            }
        }
    }
}

enum ServiceStatusError: Error, Equatable, RPCErrorConvertible {
    case maxConcurrentRequestsExceeded
    case maxConcurrentRequestsExceededNotEnoughPrewarmed
    case initializing
    case busy(reason: String)
    case terminalError(message: String)
    case transientError(message: String)
    case drained
    case draining

    var rpcErrorCode: GRPCCore.RPCError.Code {
        switch self {
        case .maxConcurrentRequestsExceeded: .resourceExhausted
        case .maxConcurrentRequestsExceededNotEnoughPrewarmed: .resourceExhausted
        case .initializing: .unavailable
        case .busy: .unavailable
        case .terminalError: .unavailable
        case .drained: .unavailable
        case .draining: .unavailable
        case .transientError: .unavailable
        }
    }

    var rpcErrorMessage: String {
        switch self {
        case .maxConcurrentRequestsExceeded: "Max concurrent requests exceeded"
        case .maxConcurrentRequestsExceededNotEnoughPrewarmed: "Max concurrent requests exceeded (not enough prewarmed)"
        case .initializing: "Service not ready"
        case .busy(let reason): reason.isEmpty ? "Service busy" : reason
        case .terminalError(let message): message.isEmpty ? "Service in terminal error" : message
        case .drained: "Service drained"
        case .transientError(let message): message.isEmpty ? "Service in transient error" : message
        case .draining: "Service draining"
        }
    }
}

extension ServiceStatusError: ReportableError {
    var publicDescription: String {
        switch self {
        case .maxConcurrentRequestsExceeded: "ServiceStatusError.maxConcurrentRequestsExceeded"
        case .maxConcurrentRequestsExceededNotEnoughPrewarmed:
            "ServiceStatusError.maxConcurrentRequestsExceededNotEnoughPrewarmed"
        case .initializing: "ServiceStatusError.initializing"
        case .busy: "ServiceStatusError.busy"
        case .terminalError: "ServiceStatusError.terminalError"
        case .transientError: "ServiceStatusError.transientError"
        case .drained: "ServiceStatusError.drained"
        case .draining: "ServiceStatusError.draining"
        }
    }
}

extension ServiceStatusMonitor.InvokeWorkloadLoadState {
    static var unavailable: Self {
        .init(concurrentRequestCount: 0, maxConcurrentRequests: 0)
    }
}
