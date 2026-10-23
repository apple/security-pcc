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

import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import DequeModule
import os
import Synchronization
import Tracing

private let log: Logger = .init(
    subsystem: "com.apple.cloudos.cloudboard",
    category: "JobHelperInstanceProvider"
)

// This placeholder delegate is needed for prewarmed JobHelperInstance instances until
// they are used and we get a real delegate for handling responses from associated
// JobHelperInstance instances. Instances of this are never expected to be invoked.
actor PrewarmedJobHelperResponseDelegate: CloudBoardJobHelperAPIClientDelegateProtocol {
    let metrics: MetricsSystem

    init(metrics: MetricsSystem) {
        self.metrics = metrics
    }

    nonisolated func cloudBoardJobHelperAPIClientSurpriseDisconnect() {
        log.error("surprise disconnect of prewarmed JobHelperInstance")
    }

    nonisolated func handleWorkloadResponse(_: JobHelperToCloudBoardDaemonMessage) {
        self.metrics
            .emit(Metrics.JobHelperInstanceProvider.PlaceholderDelegateWorkloadResponseInvoked(action: .increment))
        log.error("sendWorkloadResponse unexpectedly called on PrewarmedJobHelperResponseDelegate")
    }
}

enum JobHelperInstanceInstanceQueueError: Error {
    case usedAfterTerminateCalled
    case terminateCalledMultipleTimes
    case clearingQueueForRestartingInstances
}

actor JobHelperInstanceQueue {
    private var readyJobHelperInstances: Deque<JobHelperInstance> = Deque()
    private var waiters: [Promise<JobHelperInstance, Error>] = []
    private var terminated: Bool = false
    private var cloudAppName: String
    private let metrics: MetricsSystem
    /// When non-nil, the current queued instance count is yielded here whenever it changes. Only wired for the
    /// ready queue; the other queues pass `nil` and incur no notification cost.
    private let instanceCountChangedContinuation: AsyncStream<Int>.Continuation?

    init(
        cloudAppName: String,
        metrics: MetricsSystem,
        instanceCountChangedContinuation: AsyncStream<Int>.Continuation? = nil
    ) {
        self.cloudAppName = cloudAppName
        self.metrics = metrics
        self.instanceCountChangedContinuation = instanceCountChangedContinuation
    }

    private func notifyCountChanged() {
        self.instanceCountChangedContinuation?.yield(self.readyJobHelperInstances.count)
    }

    private func enqueue(_ instance: JobHelperInstance, _ operation: (JobHelperInstance) -> Void) throws {
        guard !self.terminated else {
            throw JobHelperInstanceInstanceQueueError.usedAfterTerminateCalled
        }
        if self.waiters.count > 0 {
            let waiter = self.waiters.removeFirst()
            self.metrics.emit(Metrics.JobHelperInstanceProvider.WaitedForCreationTotal(
                action: .increment,
                cloudApp: self.cloudAppName
            ))
            waiter.succeed(with: instance)
        } else {
            operation(instance)
            self.notifyCountChanged()
        }
    }

    func push(_ instance: JobHelperInstance) throws {
        try self.enqueue(instance) { self.readyJobHelperInstances.append($0) }
    }

    func pushFirst(_ instance: JobHelperInstance) throws {
        try self.enqueue(instance) { self.readyJobHelperInstances.insert($0, at: 0) }
    }

    func popFirst() async throws -> JobHelperInstance {
        guard !self.terminated else {
            throw JobHelperInstanceInstanceQueueError.usedAfterTerminateCalled
        }

        if let readyInstance = self.readyJobHelperInstances.popFirst() {
            self.notifyCountChanged()
            return readyInstance
        }

        /// This promise can only fail with CancellationError
        /// To avoid any races with enqueue fulfiling the promise, we mark the
        /// promise to fail with CancellationError if never fulfilled.
        let waiterPromise = Promise<JobHelperInstance, Error>(autoFailureIfUnfulfilled: CancellationError())
        let result: Result<JobHelperInstance, Error>
        do {
            self.waiters.append(waiterPromise)
            result = try await Future(waiterPromise).resultWithCancellation
        } catch {
            self.waiters.removeAll(where: { $0 === waiterPromise })
            throw CancellationError()
        }
        return try result.get()
    }

    func remove(_ instance: JobHelperInstance) -> Bool {
        guard let index = self.readyJobHelperInstances.firstIndex(where: { $0 == instance }) else {
            return false
        }

        self.readyJobHelperInstances.remove(at: index)
        self.notifyCountChanged()
        return true
    }

    func terminate(error: Error) throws -> Deque<JobHelperInstance> {
        guard !self.terminated else {
            throw JobHelperInstanceInstanceQueueError.terminateCalledMultipleTimes
        }
        self.terminated = true
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.fail(with: error)
        }

        defer { self.readyJobHelperInstances = [] }
        // Shutdown: finish the stream so the count consumer exits. No need to yield a final 0 — nothing reads the
        // ready count once we are terminating.
        self.instanceCountChangedContinuation?.finish()
        return self.readyJobHelperInstances
    }

    func clearQueue() throws -> Deque<JobHelperInstance> {
        guard !self.terminated else {
            throw JobHelperInstanceInstanceQueueError.terminateCalledMultipleTimes
        }
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.fail(with: JobHelperInstanceInstanceQueueError.clearingQueueForRestartingInstances)
        }

        defer { self.readyJobHelperInstances = [] }
        // Restart, not terminal: yield the reset-to-zero but keep the stream open for the refilled instances.
        self.instanceCountChangedContinuation?.yield(0)
        return self.readyJobHelperInstances
    }
}

enum JobHelperInstanceProviderError: Error {
    case teardownInitiatedBecauseRefillStreamFinished
    case invalidPrewarmedPoolSizeSpecified
    case invalidMaxInstanceCountSpecified
    case failedToAllocateJobHelperInstance
    case warmupTimedOut
}

// JobHelperInstanceProvider is left as a class so that we don't serialize all
// calls to withClient() (support multiple jobs in parallel)
final class JobHelperInstanceProvider: Sendable {
    private let cloudAppName: String
    private let supportAppNames: [String]
    private let isTrampolineProxy: Bool
    private let metrics: MetricsSystem
    private let tracer: any Tracer
    private let launchdJobFinder: any LaunchdJobFinderProtocol
    private let jobHelperXPCClientFactory: any CloudBoardJobHelperAPIClientFactoryProtocol

    private let jobHelperInstanceGetRetryCount: Int = 3
    private let prewarmedPoolSize: Int
    private let maxInstanceCount: Int
    private let maxLAContextCount: Int
    private let maxApplicationLayerMessageSize: Int
    private let maxToolInvocationsPerRequest: Int
    private let teardownTimeout: Duration
    private let warmupTimeout: Duration?
    private let consecutiveWarmupFailuresThreshold: Int
    private let healthMonitor: ServiceHealthMonitor?
    /// When true, the prewarm pool ready count is reported to the health monitor for load-level calculation. The
    /// configured prewarm pool is expected to be sized to at least the controller's max concurrency (validated and
    /// warned about by `WorkloadController`); this provider does not resize the pool dynamically.
    private let maxBatchDependsOnPrewarmedSize: Bool
    /// Cadence at which the pool-size gauges are sampled and emitted. Gauges are point-in-time samples, so they are
    /// published periodically rather than on every queue edge — edge-triggered emission would hammer the metrics
    /// backend during pool fill/drain without adding meaningful resolution.
    private let gaugeEmitInterval: Duration

    private var prewarmingDisabled: Bool {
        return self.prewarmedPoolSize == 0
    }

    /// Queue with instances which are ready to serve requests
    private let readyPrewarmedQueue: JobHelperInstanceQueue

    /// Stream of the ready-queue count, driven by `readyPrewarmedQueue` and consumed in `run()` to emit metrics and
    /// (when enabled) the load level reported to ROPES. Decouples the fan-out from the queue actor's isolation.
    private let readyCountStream: AsyncStream<Int>

    /// Queue with instances which have prewarmed the job helper instance
    /// but cannot serve requests, for example because it doesn't have a LAContext yet
    private let notReadyPrewarmedQueue: JobHelperInstanceQueue
    /// Queue with instances which are being prewarmed and are waiting
    /// for the warmup to be completed.
    private let prewarmingQueue: JobHelperInstanceQueue
    private let refillStream: AsyncStream<ContinuousTimeMeasurement>
    private let refillContinuation: AsyncStream<ContinuousTimeMeasurement>.Continuation

    private let laContextAvailableStream: AsyncStream<ContinuousTimeMeasurement>
    private let laContextAvailableContinutation: AsyncStream<ContinuousTimeMeasurement>.Continuation

    // fulfilled when initial assets metadata is provided.
    private let initialAssetsReadyPromise: Promise<Void, Error>?
    private let assetsMetadata: Mutex<[AssetConsumer: [AssetMetadata]]>

    /// This is internal for Testing purposes
    internal struct State {
        var managedInstanceCount: Int = 0
        /// Number of instances in the ready queue (fully warmed + LAContext assigned) able to serve immediately.
        var availablePrewarmedCount: Int = 0
        var awaitingLAContext: Int = 0
        var consecutiveWarmupFailures: Int = 0
        var laContextResourcePool: ResourcePool
        var instanceResourcePool: ResourcePool
    }

    internal let state: Mutex<State>

    private func incrementManagedInstanceCount() {
        self.state.withLock { state in
            state.managedInstanceCount += 1
        }
    }

    private func decrementManagedInstanceCount() {
        self.state.withLock { state in
            state.managedInstanceCount -= 1
        }
    }

    /// Periodically samples and emits the pool-size gauges (`PrewarmedPoolSizeGauge` ready count, and the derived
    /// `PrewarmingPoolSizeGauge` in-progress count). Gauges are inherently point-in-time samples, so they are
    /// published on a fixed cadence rather than on every queue edge: edge-triggered emission would hammer the
    /// metrics backend while the pool fills/drains without adding resolution the gauge semantics need. Runs until
    /// the enclosing task group is cancelled.
    private func processPoolSizeGaugeSampling() async {
        while true {
            self.emitPoolSizeGauges()
            do {
                try await Task.sleep(for: self.gaugeEmitInterval)
            } catch {
                return
            }
        }
    }

    /// Emits both pool-size gauges from a single consistent snapshot of the counts. The ready count mirrors the
    /// value last published to ROPES via `updateAvailablePrewarmedInstances`; the prewarming count is derived as
    /// `managedInstanceCount - availablePrewarmedCount`.
    private func emitPoolSizeGauges() {
        let (ready, prewarming) = self.state.withLock { state in
            (state.availablePrewarmedCount, max(0, state.managedInstanceCount - state.availablePrewarmedCount))
        }
        self.metrics.emit(Metrics.JobHelperInstanceProvider.PrewarmedPoolSizeGauge(
            value: ready, cloudApp: self.cloudAppName, configuredPoolSize: self.prewarmedPoolSize
        ))
        self.metrics.emit(Metrics.JobHelperInstanceProvider.PrewarmingPoolSizeGauge(
            value: prewarming, cloudApp: self.cloudAppName, configuredPoolSize: self.prewarmedPoolSize
        ))
    }

    /// Invoked by `readyPrewarmedQueue` whenever the number of immediately-servable instances changes. Updates the
    /// stored ready count and, when `maxBatchDependsOnPrewarmedSize` is enabled, drives the load level reported to
    /// ROPES. This stays edge-triggered (unlike the gauges) because ROPES must see availability changes promptly —
    /// it is a real-time signal, not a sampled metric.
    private func onReadyPrewarmedCountChanged(_ readyCount: Int) {
        self.state.withLock { state in
            state.availablePrewarmedCount = readyCount
        }
        self.healthMonitor?.updateAvailablePrewarmedInstances(count: readyCount)
    }

    private func recordWarmupFailure() {
        guard self.consecutiveWarmupFailuresThreshold > 0 else { return }
        let shouldEnterMaintenance = self.state.withLock { state in
            state.consecutiveWarmupFailures += 1
            return state.consecutiveWarmupFailures >= self.consecutiveWarmupFailuresThreshold
        }
        if shouldEnterMaintenance {
            log.error(
                "JobHelperInstanceProvider::\(self.cloudAppName, privacy: .public) consecutive warmup failures reached threshold (\(self.consecutiveWarmupFailuresThreshold, privacy: .public)), entering maintenance"
            )
            self.healthMonitor?.enterMaintenance(.prewarmingFailed)
        }
    }

    private func recordWarmupSuccess() {
        let shouldExitMaintenance = self.state.withLock { state in
            let wasInFailureState = state.consecutiveWarmupFailures >= self.consecutiveWarmupFailuresThreshold
            state.consecutiveWarmupFailures = 0
            return wasInFailureState
        }
        if shouldExitMaintenance {
            log.info(
                "JobHelperInstanceProvider::\(self.cloudAppName, privacy: .public) warmup succeeded after failures, exiting maintenance"
            )
            self.healthMonitor?.exitMaintenance(.prewarmingFailed)
        }
    }

    init(
        cloudAppName: String,
        supportAppNames: [String],
        isTrampolineProxy: Bool,
        prewarmedPoolSize: Int,
        maxInstanceCount: Int,
        maxLAContextCount: Int = 1,
        maxApplicationLayerMessageSize: Int,
        maxToolInvocationsPerRequest: Int,
        teardownTimeout: Duration,
        warmupTimeout: Duration? = nil,
        consecutiveWarmupFailuresThreshold: Int,
        healthMonitor: ServiceHealthMonitor? = nil,
        maxBatchDependsOnPrewarmedSize: Bool = false,
        gaugeEmitInterval: Duration = gaugeMetricPublishInterval,
        metrics: MetricsSystem,
        tracer: any Tracer,
        launchdJobFinder: any LaunchdJobFinderProtocol,
        jobHelperXPCClientFactory: any CloudBoardJobHelperAPIClientFactoryProtocol,
        waitForInitialAssets: Bool
    ) throws {
        self.cloudAppName = cloudAppName
        self.supportAppNames = supportAppNames
        self.isTrampolineProxy = isTrampolineProxy
        log.log(
            "Initializing JobHelperInstanceProvider::\(self.cloudAppName, privacy: .public) with prewarmedPoolSize: \(prewarmedPoolSize, privacy: .public), maxInstanceCount: \(maxInstanceCount, privacy: .public)"
        )
        if prewarmedPoolSize < 0 || prewarmedPoolSize > 1000 {
            log.error(
                "Invalid prewarmedPoolSize specified (\(prewarmedPoolSize, privacy: .public)) for \(self.cloudAppName, privacy: .public), value must be in [0, 1000]"
            )
            throw JobHelperInstanceProviderError.invalidPrewarmedPoolSizeSpecified
        }
        if maxInstanceCount != 0, prewarmedPoolSize > maxInstanceCount {
            log.error(
                "Specified prewarmedPoolSize (\(prewarmedPoolSize, privacy: .public)) for \(self.cloudAppName, privacy: .public), exceeds provided maxInstanceCount (\(maxInstanceCount, privacy: .public))"
            )
            throw JobHelperInstanceProviderError.invalidPrewarmedPoolSizeSpecified
        }
        self.prewarmedPoolSize = prewarmedPoolSize
        if maxInstanceCount < 0 || maxInstanceCount > 1000 {
            log.error(
                "Invalid maxInstanceCount specified (\(maxInstanceCount, privacy: .public)) for \(self.cloudAppName, privacy: .public), value must be in [0, 1000]"
            )
            throw JobHelperInstanceProviderError.invalidMaxInstanceCountSpecified
        }
        self.maxInstanceCount = maxInstanceCount
        self.maxLAContextCount = maxLAContextCount
        self.teardownTimeout = teardownTimeout
        self.warmupTimeout = warmupTimeout
        self.consecutiveWarmupFailuresThreshold = consecutiveWarmupFailuresThreshold
        self.healthMonitor = healthMonitor
        self.maxBatchDependsOnPrewarmedSize = maxBatchDependsOnPrewarmedSize
        self.gaugeEmitInterval = gaugeEmitInterval

        let (readyCountStream, readyCountContinuation) = AsyncStream<Int>.makeStream()
        self.readyCountStream = readyCountStream
        self.readyPrewarmedQueue = JobHelperInstanceQueue(
            cloudAppName: self.cloudAppName,
            metrics: metrics,
            instanceCountChangedContinuation: readyCountContinuation
        )
        self.notReadyPrewarmedQueue = JobHelperInstanceQueue(
            cloudAppName: self.cloudAppName,
            metrics: metrics
        )
        self.prewarmingQueue = JobHelperInstanceQueue(
            cloudAppName: self.cloudAppName,
            metrics: metrics
        )
        (self.refillStream, self.refillContinuation) = AsyncStream<ContinuousTimeMeasurement>.makeStream()
        (self.laContextAvailableStream, self.laContextAvailableContinutation) = AsyncStream<ContinuousTimeMeasurement>
            .makeStream()
        self.metrics = metrics
        self.tracer = tracer
        self.launchdJobFinder = launchdJobFinder
        self.jobHelperXPCClientFactory = jobHelperXPCClientFactory
        self.state = .init(State(
            laContextResourcePool: .init(poolSize: self.maxLAContextCount),
            instanceResourcePool: .init(poolSize: self.maxInstanceCount)
        ))
        self.assetsMetadata = .init([:])
        self.initialAssetsReadyPromise = if waitForInitialAssets {
            .init(autoFailureIfUnfulfilled: CancellationError())
        } else {
            nil
        }
        self.maxApplicationLayerMessageSize = maxApplicationLayerMessageSize
        self.maxToolInvocationsPerRequest = maxToolInvocationsPerRequest
    }

    /// Run  the provided `JobHelperInstance` until it terminates and handler teardown triggers.
    /// Completes on `JobHelperInstance` finishing (the underlying process terminating).
    ///
    /// This is non-throwing because we don't want errors managing/running a specific job helper instance to
    /// be propagated outside of the management context of that specific instance.
    ///
    /// - Parameter jobHelperInstance: the jobhelper instance to run
    private func runJobHelperInstance(_ jobHelperInstance: JobHelperInstance) async {
        await withTaskGroup(of: Void.self) { instanceTaskGroup in
            instanceTaskGroup.addTask {
                do {
                    try await jobHelperInstance.run()
                } catch {
                    log.error("""
                    \(jobHelperInstance.logMetadata(), privacy: .public) \
                    manageJobHelperInstance instance.run() received an error: \
                    \(String(unredacted: error), privacy: .public)
                    """)
                }
                if await self.removeFromPrewarmedQueues(jobHelperInstance) {
                    await jobHelperInstance.triggerTeardown()
                }
            }

            instanceTaskGroup.addTask {
                // this expects the trigger for teardown to be invoked elsewhere - if it isn't,
                // promise gets leaked and cloudboardd will crash.
                await jobHelperInstance.awaitTeardownTriggerAndComplete()
                if await jobHelperInstance.laContextAssigned {
                    await self.laContextUsedByClient()
                }
            }

            await instanceTaskGroup.waitForAll()
        }
    }

    private func removeFromPrewarmedQueues(_ jobHelperInstance: JobHelperInstance) async -> Bool {
        // The order of the check is important, since an instance
        // can move from notReady to Ready, but not the other way around.
        var removed = await self.notReadyPrewarmedQueue.remove(jobHelperInstance)
        if !removed {
            removed = await self.readyPrewarmedQueue.remove(jobHelperInstance)
        }
        if removed {
            self.metrics.emit(Metrics.JobHelperInstanceProvider.PrewarmedInstancesDiedTotal(
                action: .increment,
                cloudApp: self.cloudAppName
            ))
            self.decrementManagedInstanceCount()
        }
        return removed
    }

    /// Awaits the point at which every asset consumer has its initial assets. Returns immediately when gating is
    /// disabled (no initial-assets promise). The promise is fulfilled via `updateAssetsMetadata(isInitial: true)`.
    ///
    /// Cancellation-aware: throws `CancellationError` if the awaiting task is cancelled, so callers unwind
    /// instead of blocking teardown.
    func waitForInitialAssets() async throws {
        guard let initialAssetsReadyPromise = self.initialAssetsReadyPromise else {
            return
        }
        try await Future(initialAssetsReadyPromise).valueWithCancellation
    }

    func run() async throws {
        let definitions = try self.launchdJobFinder.getJobDefinitions(
            type: CloudBoardJobType.cbJobHelper,
            name: nil
        )
        guard definitions.count == 1 else {
            log.error("unexpected cb_jobhelper managed jobs count \(definitions.count, privacy: .public)")
            throw JobHelperInstanceError.tooManyManagedJobs
        }
        let definition = definitions[0]
        log.log("discovered cb_jobhelper launchd job")

        self.state.withLock { state in
            for _ in 0 ..< self.prewarmedPoolSize {
                if state.instanceResourcePool.acquireResource() {
                    self.refillContinuation.yield(.start())
                }
            }
        }

        if let initialAssetsReadyPromise = self.initialAssetsReadyPromise {
            log.log("Waiting for all initial assets to be available")
            try await Future(initialAssetsReadyPromise).valueWithCancellation
            log.log("All initial assets are available")
        }

        await withTaskGroup { group in
            group.addTask {
                await self.processRefillStream(definition: definition)
            }
            group.addTask {
                await self.processLAContextAvailableStream()
            }
            group.addTask {
                await self.processReadyCountStream()
            }
            group.addTask {
                await self.processPoolSizeGaugeSampling()
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Consumes the ready-queue count stream, driving metrics and (when enabled) the load level reported to ROPES.
    /// Running on the provider's task — rather than synchronously inside the queue actor — keeps the metric emission
    /// and health-monitor fan-out off the queue's isolation.
    private func processReadyCountStream() async {
        for await count in self.readyCountStream {
            self.onReadyPrewarmedCountChanged(count)
        }
    }

    private func processRefillStream(definition: LaunchdJobDefinitionProtocol) async {
        // We don't want the child tasks to throw here since each is responsible for handling
        // the errors in creating and managing its associated jobhelper instance.
        await withDiscardingTaskGroup { group in
            // Each time we receive a signal on this stream, create one new JobHelperInstance
            for await processRequestedAt in self.refillStream {
                let initiatedAt = ContinuousTimeMeasurement.start()
                let withLAContext = self.state.withLock {
                    if $0.laContextResourcePool.acquireResource() {
                        return true
                    }
                    $0.awaitingLAContext += 1
                    return false
                }

                let jobHelperInstance = JobHelperInstance(
                    definition,
                    cloudAppName: self.cloudAppName,
                    supportAppNames: self.supportAppNames,
                    isTrampolineProxy: self.isTrampolineProxy,
                    withLAContext: withLAContext,
                    assetsMetadata: self.assetsMetadata.withLock { $0 },
                    maxApplicationLayerMessageSize: self.maxApplicationLayerMessageSize,
                    maxToolInvocationsPerRequest: self.maxToolInvocationsPerRequest,
                    jobHelperXPCClientFactory: self.jobHelperXPCClientFactory,
                    delegate: PrewarmedJobHelperResponseDelegate(metrics: self.metrics),
                    metrics: self.metrics,
                    tracer: self.tracer,
                    teardownTimeout: self.teardownTimeout
                )

                log.info("\(jobHelperInstance.logMetadata(), privacy: .public) created JobHelperInstance")
                group.addTask {
                    do {
                        try self.state.withLock { state in
                            try state.instanceResourcePool.resourceAcquired()
                            if withLAContext {
                                try state.laContextResourcePool.resourceAcquired()
                            }
                        }
                        await self.runJobHelperInstance(jobHelperInstance)
                        try self.state.withLock { state in
                            try state.instanceResourcePool.resourceReleased()
                        }
                        self.jobHelperInstanceConsumed()
                    } catch {
                        /// Any failures here is fatal as we have broken the constraints of the system
                        log.error("JobhelperInstanceProvider coming down due to error: \(error, privacy: .public)")
                        self.refillContinuation.finish()
                    }
                }

                group.addTask {
                    // prewarm the jobhelper instance - races with `runJobHelperInstance`, but that is handled by the
                    // jobhelper instance's state machine
                    do {
                        self.incrementManagedInstanceCount()

                        /// We keep track of the instances which are still being warmed up
                        /// So that if we get a request to restart all instances
                        /// we also abandon the instances which are being warmed up.
                        try await self.prewarmingQueue.push(jobHelperInstance)
                        if let warmupTimeout = self.warmupTimeout {
                            try await withThrowingTaskGroup(of: Void.self) { timeoutGroup in
                                timeoutGroup.addTask {
                                    try await jobHelperInstance.waitForWarmupComplete()
                                }
                                timeoutGroup.addTask {
                                    try await Task.sleep(for: warmupTimeout)
                                    throw JobHelperInstanceProviderError.warmupTimedOut
                                }
                                try await timeoutGroup.next()
                                timeoutGroup.cancelAll()
                            }
                        } else {
                            try await jobHelperInstance.waitForWarmupComplete()
                        }
                        let notRestarted = await self.prewarmingQueue.remove(jobHelperInstance)
                        if !notRestarted {
                            log.log("""
                            \(jobHelperInstance.logMetadata(), privacy: .public) warmed up after 
                            being abandoned. Ignoring the warmup notification.
                            """)
                            return
                        }

                        if withLAContext {
                            try await self.readyPrewarmedQueue.push(jobHelperInstance)
                        } else {
                            try await self.notReadyPrewarmedQueue.push(jobHelperInstance)
                        }
                        let launchDuration = initiatedAt.duration
                        // time from
                        let launchLatency = processRequestedAt.duration
                        log.debug("""
                        \(jobHelperInstance.logMetadata(), privacy: .public) warmed up
                        latency=\(launchLatency.milliseconds, privacy: .public)ms
                        launch=\(launchDuration.milliseconds, privacy: .public)ms
                        queue=\((launchLatency - launchDuration).milliseconds, privacy: .public)ms
                        """)
                        self.metrics.emit(
                            Metrics.JobHelperInstanceProvider.TimeToLaunchJobHelperInstanceHistogram(
                                duration: launchLatency,
                                cloudApp: self.cloudAppName,
                                prewarmingEnabled: !self.prewarmingDisabled,
                                prewarmedPoolSize: self.prewarmedPoolSize
                            )
                        )
                        self.recordWarmupSuccess()
                    } catch {
                        // Dont rethrow this error because we want to let run complete so the JobHelperInstance
                        // can be torn down and removed from the prewarmed queue.
                        log.error("""
                        \(jobHelperInstance.logMetadata(), privacy: .public) \
                        warmup failed with error: \
                        \(String(unredacted: error), privacy: .public) \
                        tearing down
                        """)
                        self.metrics.emit(Metrics.JobHelperInstanceProvider.InvokeWarmupErrorTotal(
                            action: .increment,
                            cloudApp: self.cloudAppName
                        ))
                        self.recordWarmupFailure()
                        let removed = await self.removeFromPrewarmedQueues(jobHelperInstance)

                        /// If we throw even before adding to any of the queues, we are respoinsible
                        /// for decrementing the prewarm counts
                        if !removed {
                            self.decrementManagedInstanceCount()
                        }
                        await jobHelperInstance.triggerTeardown(error: error)
                    }
                }
            }

            log.error(
                "JobHelperInstanceProvider::\(self.cloudAppName, privacy: .public) run() refillStream finished, tearing down any remaining prewarmed instances"
            )
            do {
                let error = JobHelperInstanceProviderError.teardownInitiatedBecauseRefillStreamFinished
                for jobHelperInstance in try await self.prewarmingQueue.terminate(error: error) {
                    await jobHelperInstance.triggerTeardown(error: error)
                    self.decrementManagedInstanceCount()
                }
                for jobHelperInstance in try await self.readyPrewarmedQueue.terminate(error: error) {
                    await jobHelperInstance.triggerTeardown(error: error)
                    self.decrementManagedInstanceCount()
                }
                for jobHelperInstance in try await self.notReadyPrewarmedQueue.terminate(error: error) {
                    await jobHelperInstance.triggerTeardown(error: error)
                    self.decrementManagedInstanceCount()
                }
            } catch {
                log.error("""
                JobHelperInstanceProvider::\(self.cloudAppName, privacy: .public) run() teardown failed to invoke \
                terminate() on prewarmed queue: \
                \(String(unredacted: error), privacy: .public)
                """)
            }
        }
    }

    private func processLAContextAvailableStream() async {
        for await processRequestAt in self.laContextAvailableStream {
            let instanceWaitingForLAContext = self.state.withLock {
                if $0.awaitingLAContext > 0,
                   $0.laContextResourcePool.acquireResource() {
                    $0.awaitingLAContext -= 1
                    return true
                } else {
                    return false
                }
            }

            if instanceWaitingForLAContext {
                var instance: JobHelperInstance?
                do {
                    log.log(
                        "JobHelperInstanceProvider::\(self.cloudAppName, privacy: .public): Assigning LAContext to prewarmed instance"
                    )
                    do {
                        instance = try await self.notReadyPrewarmedQueue.popFirst()
                        try await instance!.assignLAContext()
                    } catch {
                        try self.state.withLock {
                            try $0.laContextResourcePool.acquireFailed()
                        }
                        throw error
                    }
                    try self.state.withLock {
                        try $0.laContextResourcePool.resourceAcquired()
                    }
                    /// Safe to force unwrap here.
                    try await self.readyPrewarmedQueue.push(instance!)

                    let assignLatency = processRequestAt.duration
                    self.metrics
                        .emit(Metrics.JobHelperInstanceProvider.TimeToAssignLAContextJobHelperInstanceHistogram(
                            duration: assignLatency,
                            cloudApp: self.cloudAppName
                        ))
                } catch {
                    log.error(
                        "JobHelperInstanceProvider::\(self.cloudAppName, privacy: .public): Error assigning LAContext: \(String(unredacted: error), privacy: .public)"
                    )
                    await instance?.triggerTeardown(error: error)
                    self.decrementManagedInstanceCount()
                    // Re-signal to try next waiting instance
                    self.laContextAvailableContinutation.yield(.start())
                }
            }
        }
    }

    // Called whenever a JobHelperInstance goes away for any reason.
    // Does the logical check and determines
    // "do we need a new one - yes/no?", if yes enqueue a void message into the
    // stream that the run refill tasks awaits on.
    // Avoid throwing and async routines to maintain simplicity here
    // called when one is consumed from the free queue AND when one actually
    // dies.
    private func jobHelperInstanceConsumed() {
        // While the # of (currently running + creation in-flight processes) is less than the ceiling
        // AND the # of (currently prewarmed + creation in-flight processes) is less than the prewarmed pool size,
        // submit new creation requests.
        self.state.withLock { state in
            var pendingPlusPrewarmedCount: Int {
                state.managedInstanceCount + state.instanceResourcePool.acquiring
            }

            while pendingPlusPrewarmedCount < self.prewarmedPoolSize,
                  state.instanceResourcePool.acquireResource() {
                self.refillContinuation.yield(.start())
            }
        }
    }

    private func dequeueJobHelperInstance(
        delegate: CloudBoardJobHelperAPIClientDelegateProtocol?
    ) async throws -> JobHelperInstance {
        let waitForAllocationMeasurement = ContinuousTimeMeasurement.start()

        let retryMaxCount = self.jobHelperInstanceGetRetryCount
        for attempt in 1 ... retryMaxCount {
            // If prewarming is disabled, signal to request a new JobHelperInstance
            if self.prewarmingDisabled {
                self.state.withLock { state in
                    if state.instanceResourcePool.acquireResource() {
                        self.refillContinuation.yield(.start())
                    }
                }
            }

            let jobHelperInstance: JobHelperInstance
            do {
                jobHelperInstance = try await self.readyPrewarmedQueue.popFirst()
            } catch {
                log.error("""
                dequeueJobHelperInstance popFirst returned error: \
                \(String(unredacted: error), privacy: .public)
                """)
                throw error
            }
            self.decrementManagedInstanceCount()
            self.jobHelperInstanceConsumed()

            do {
                // This could fail if the JobHelperInstance died and we de-queued it
                // before manageJobHelperInstance() handled the death notification and
                // removed it from the prewarmed queue.
                if let delegate {
                    try await jobHelperInstance.set(delegate: delegate)
                }
                self.metrics.emit(
                    Metrics.JobHelperInstanceProvider.AttemptsToAllocateJobHelperInstanceHistogram(
                        value: attempt,
                        cloudApp: self.cloudAppName
                    )
                )
                self.metrics.emit(
                    Metrics.JobHelperInstanceProvider.TimeToAllocateJobHelperInstanceHistogram(
                        duration: waitForAllocationMeasurement.duration,
                        cloudApp: self.cloudAppName,
                        prewarmingEnabled: !self.prewarmingDisabled,
                        prewarmedPoolSize: self.prewarmedPoolSize
                    )
                )
                return jobHelperInstance
            } catch {
                log.error("""
                \(jobHelperInstance.logMetadata(), privacy: .public) dequeueJobHelperInstance failed \
                to use dequeued instance: \
                \(String(unredacted: error), privacy: .public)
                """)
                // Ensure the jobhelper instance is torn down
                await jobHelperInstance.triggerTeardown(error: error)
            }
        }

        self.metrics.emit(Metrics.JobHelperInstanceProvider.FailedToAllocateTotal(
            action: .increment,
            cloudApp: self.cloudAppName,
            retryCount: retryMaxCount
        ))
        throw JobHelperInstanceProviderError.failedToAllocateJobHelperInstance
    }

    // Assumption here is that we have ownership of the JobHelperInstance at this point,
    // if someone else does use it, they have violated the ownership contract defined
    // by use of the withJobHelperInstance() call (which expects all usage of the client to be contained
    // within the body). There's no great way to defend against violation of this contract.
    private func returnJobHelperInstance(_ jobHelperInstance: JobHelperInstance) async {
        let instanceUsed = await !jobHelperInstance.canBeReturnedToPool
        // If the instance was used or prewarming is disabled, return the jobhelper instance
        if instanceUsed || self.prewarmingDisabled {
            await jobHelperInstance.triggerTeardown()
            return
        }

        do {
            try await jobHelperInstance.set(delegate: PrewarmedJobHelperResponseDelegate(metrics: self.metrics))
        } catch {
            log.error("""
            \(jobHelperInstance.logMetadata(), privacy: .public) failed to reclaim \
            unused JobHelperInstance instance: \
            \(String(unredacted: error), privacy: .public)
            """)
            self.metrics.emit(Metrics.JobHelperInstanceProvider.FailedToReclaimTotal(
                action: .increment,
                cloudApp: self.cloudAppName
            ))
            // We complete the teardown promise, which signals to the associated task in manageJobHelperInstance()
            // that we should initiate teardown of this instance.
            await jobHelperInstance.triggerTeardown(error: error)
            return
        }

        log.info("\(jobHelperInstance.logMetadata(), privacy: .public) reclaimed unused JobHelperInstance instance")
        do {
            try await self.readyPrewarmedQueue.pushFirst(jobHelperInstance)
        } catch {
            log.error("""
            \(jobHelperInstance.logMetadata(), privacy: .public) failed to return unused \
            JobHelperInstance instance to prewarmed queue: \
            \(String(unredacted: error), privacy: .public), \
            initiating teardown
            """)
            self.metrics.emit(Metrics.JobHelperInstanceProvider.FailedToReclaimTotal(
                action: .increment,
                cloudApp: self.cloudAppName
            ))
            // We complete the teardown promise, which signals to the associated task in manageJobHelperInstance()
            // that we should initiate teardown of this instance.
            await jobHelperInstance.triggerTeardown(error: error)
            return
        }
        self.incrementManagedInstanceCount()
        self.metrics.emit(Metrics.JobHelperInstanceProvider.ReclaimedPrewarmedTotal(
            action: .increment,
            cloudApp: self.cloudAppName
        ))
    }

    // All usage of the JobHelperInstance provided to the body must be completed
    // by the time the body returns.
    func withJobHelperInstance<ReturnValue>(
        delegate: CloudBoardJobHelperAPIClientDelegateProtocol,
        _ body: (JobHelperInstance) async throws -> ReturnValue
    ) async throws
    -> ReturnValue {
        let jobHelperInstance: JobHelperInstance
        do {
            try await jobHelperInstance = self.dequeueJobHelperInstance(delegate: delegate)
        } catch {
            log.error("""
            withJobHelperInstance(): failed to obtain JobHelperInstance: \
            \(String(unredacted: error), privacy: .public)
            """)
            throw error
        }

        log.info("\(jobHelperInstance.logMetadata(), privacy: .public) allocated for usage")

        do {
            let returnValue = try await body(jobHelperInstance)
            await self.returnJobHelperInstance(jobHelperInstance)
            log.info("withJobHelperInstance returning")
            return returnValue
        } catch {
            log.error("""
            \(jobHelperInstance.logMetadata(), privacy: .public) \
            withJobHelperInstance() body returned error \
            \(String(unredacted: error), privacy: .public)
            """)
            await jobHelperInstance.triggerTeardown(error: error)
            throw error
        }
    }

    func laContextUsedByClient() async {
        do {
            try self.state.withLock {
                try $0.laContextResourcePool.resourceReleased()
                self.laContextAvailableContinutation.yield(.start())
            }
        } catch {
            /// This can only occur if a job helper instance tries to double release it's LAContext
            /// which should already be caught by it's own state machine.
            /// We can safely swallow the error here
            log.error("Failed to release LAContext with error: \(String(unredacted: error), privacy: .public)")
        }
    }

    func updateAssetsMetadata(_ assetsMetadata: [AssetConsumer: [AssetMetadata]], isInitial: Bool = false) {
        self.assetsMetadata.withLock {
            $0 = assetsMetadata
        }
        if isInitial {
            log.info("Received initial assets metadata: \(assetsMetadata, privacy: .public)")
            self.initialAssetsReadyPromise?.succeed()
        } else {
            log.info("Received newer assets metadata: \(assetsMetadata, privacy: .public)")
        }
    }

    public func restartPrewarmedInstances() async throws {
        // Should only be called when no more requests can come in at this point:
        // - ServiceHealthMonitor max batch size is 0, or
        // - ServiceHealthMonitor service status is unhealthy
        log.info("Restarting prewarmed instances")

        try await withThrowingTaskGroup(of: Void.self) { group in
            let instancesWithLAContext = try await self.readyPrewarmedQueue.clearQueue()
            let instancesWithoutLAContext = try await self.notReadyPrewarmedQueue.clearQueue()
            self.state.withLock {
                $0.awaitingLAContext = 0
            }
            let instancesPrewarming = try await self.prewarmingQueue.clearQueue()

            func restartInstances(instances: Deque<JobHelperInstance>) {
                for jobHelperInstance in instances {
                    group.addTask {
                        do {
                            let id = jobHelperInstance.id
                            log.info("Disposing stale JobHelperInstance jobID=\(id, privacy: .public)")
                            try await jobHelperInstance.abandon()
                            await jobHelperInstance.triggerTeardown()
                        } catch {
                            log.error("""
                            Failed to dispose of stale JobHelperInstance: \
                            \(String(reportable: error), privacy: .public)
                            """)
                        }
                        self.decrementManagedInstanceCount()
                        self.jobHelperInstanceConsumed()
                    }
                }
            }

            restartInstances(instances: instancesWithLAContext)
            restartInstances(instances: instancesWithoutLAContext)
            restartInstances(instances: instancesPrewarming)

            try await group.waitForAll()
        }
    }
}

/// This is not thread safe and should be used from inside a Lock
struct ResourcePool {
    let poolSize: Int
    private var noLimit: Bool {
        self.poolSize == 0
    }

    var acquiring: Int = 0
    var acquired: Int = 0

    enum ResourcePoolError: Error {
        case nothingBeingAcquired
        case nothingAcquired
    }

    init(poolSize: Int) {
        self.poolSize = poolSize
    }

    mutating func acquireResource() -> Bool {
        if self.noLimit ||
            (self.acquired + self.acquiring < self.poolSize) {
            self.acquiring += 1
            return true
        }
        return false
    }

    mutating func acquireFailed() throws {
        guard self.acquiring > 0 else {
            throw ResourcePoolError.nothingBeingAcquired
        }
        self.acquiring -= 1
    }

    mutating func resourceAcquired() throws {
        guard self.acquiring > 0 else {
            throw ResourcePoolError.nothingBeingAcquired
        }
        self.acquiring -= 1
        self.acquired += 1
    }

    mutating func resourceReleased() throws {
        guard self.acquired > 0 else {
            throw ResourcePoolError.nothingAcquired
        }
        self.acquired -= 1
    }
}
