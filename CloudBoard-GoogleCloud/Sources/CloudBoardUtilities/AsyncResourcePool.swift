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

import Atomics
import Logging
import NIOConcurrencyHelpers
import ServiceLifecycle
import Synchronization

private let logger = Logger(label: "AsyncResourcePool")

package struct AsyncResourcePoolConfiguration: Sendable {
    public static let `default` = AsyncResourcePoolConfiguration()

    public var initialTargetCapacity: Int = 10

    /// Maximum time a resource may exist before it is recycled: torn down cleanly (via
    /// ``AsyncResourceShutdownReason/capacityReduced``) and replaced by a freshly created instance. The lifetime is
    /// measured from when the resource's creation begins. A resource that is currently checked out is never
    /// interrupted mid-use — it is recycled as soon as it is idle at (or returned to the pool after) its lifetime.
    ///
    /// `nil` (the default) disables recycling: resources live until they are consumed or the pool shrinks.
    public var maxIdleResourceLifetime: Duration? = nil

    /// Symmetric jitter, as a percentage (clamped to `0...50`), applied independently to each resource's
    /// ``maxIdleResourceLifetime``. Each resource's effective lifetime is
    /// `maxIdleResourceLifetime * (1 + random(-jitter, +jitter) / 100)`,
    /// spreading the recycling of a cohort created together across a window instead of tearing them all down at the
    /// same instant (which would cause a capacity dip and a burst of simultaneous re-warms).
    ///
    /// `0` disables jitter.
    public var maxIdleResourceLifetimeJitterPercent: Double = 0

    /// The effective idle lifetime for a single resource.
    ///
    /// Applies symmetric ``maxIdleResourceLifetimeJitterPercent`` jitter (capped at 50%) to
    /// ``maxIdleResourceLifetime``: `maxIdleResourceLifetime * (1 + unitJitter * jitterPercent / 100)`.

    /// - Parameter unitJitter: Position within the jitter band, in `-1...1` (`0` is no shift, `±1` is the full
    ///   ∓`jitterPercent`). Defaults to a random draw
    /// - Returns: The jittered lifetime, or `nil` if recycling is disabled (``maxIdleResourceLifetime`` is `nil`).
    func jitteredLifetime(unitJitter: Double = Double.random(in: -1...1)) -> Duration? {
        guard let lifetime = self.maxIdleResourceLifetime else { return nil }
        let multiplier =
            1.0 + unitJitter.clamped(-1, 1) * self.maxIdleResourceLifetimeJitterPercent.clamped(0, 50)
            / 100
        return lifetime * multiplier
    }
}

package enum AsyncResourceShutdownReason {
    /// The pool is shedding this resource because it now holds more than its target capacity (or is shutting down). The
    /// resource is not replaced.
    case capacityReduced
    /// The resource reached its ``AsyncResourcePoolConfiguration/maxIdleResourceLifetime`` and is being recycled:
    /// torn down and replaced by a freshly created instance so the pool's capacity is preserved.
    case lifetimeExceeded
    /// The consumer that checked this resource out has finished with it and already wound it down.
    case executionCompleted
}

package protocol AsyncResourceProtocol: Sendable {
    func shutdown(reason: AsyncResourceShutdownReason)
}

package struct AsyncResourcePoolCompletionNotification<AsyncResource: AsyncResourceProtocol>: Sendable {
    private let handler: @Sendable (AsyncResource) -> Void
    private let notified = ManagedAtomic<Bool>(false)

    init(handler: @escaping @Sendable (AsyncResource) -> Void) {
        self.handler = handler
    }

    var wasNotified: Bool {
        self.notified.load(ordering: .relaxed)
    }

    package func notify(resourceReady: AsyncResource) {
        guard self.notified.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            return
        }
        self.handler(resourceReady)
    }
}

package protocol AsyncResourceFactory: Sendable {
    associatedtype AsyncResource: AsyncResourceProtocol

    func createAndRun(notifier: AsyncResourcePoolCompletionNotification<AsyncResource>) async
}

package struct AsyncResourcePool<AsyncResource: Sendable, Factory: AsyncResourceFactory>: Service & Sendable
where Factory.AsyncResource == AsyncResource {

    struct ManagedResource: Sendable {
        let resource: AsyncResource
        let id: Int
        /// Instant at which this resource reaches its maximum lifetime and should be recycled, or `nil` if
        /// recycling is disabled. Stable across reuse (checkout/return): a resource returned to the pool after this
        /// instant is retired rather than re-pooled, so a reused resource cannot outlive its lifetime.
        let expiresAt: ContinuousClock.Instant?
    }

    struct State: Sendable {
        var target: Int
        var idle: [ManagedResource]
        var inUse: Int
        var creating: Int
        var waiters: [ResourceWaiter<ManagedResource>]
        var shutDown: Bool
        var resourceHandles: [Int: AsyncValueBox<AsyncResourceShutdownReason>]
        var nextResourceId: Int

        var totalManaged: Int {
            self.idle.count + self.inUse + self.creating
        }
    }

    private let factory: Factory
    private let configuration: AsyncResourcePoolConfiguration
    private let clock: any ContinuousClockProtocol
    private let _state: NIOLockedValueBox<State>
    private let signalStream: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation
    private let capacityStream: AsyncStream<Capacity>
    private let capacityContinuation: AsyncStream<Capacity>.Continuation

    public init(
        factory: Factory,
        configuration: AsyncResourcePoolConfiguration = .default,
        clock: any ContinuousClockProtocol = ContinuousClock()
    ) {
        self.factory = factory
        self.configuration = configuration
        self.clock = clock
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.signalStream = stream
        self.signalContinuation = continuation
        // Keep only the latest snapshot: a single consumer only cares about the current
        // capacity, and coalescing avoids an unbounded backlog if it falls behind.
        let (capacityStream, capacityContinuation) = AsyncStream<Capacity>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.capacityStream = capacityStream
        self.capacityContinuation = capacityContinuation
        self._state = NIOLockedValueBox(
            State(
                target: configuration.initialTargetCapacity,
                idle: [],
                inUse: 0,
                creating: 0,
                waiters: [],
                shutDown: false,
                resourceHandles: [:],
                nextResourceId: 0
            )
        )
    }

    public var targetCapacity: Int {
        get {
            self._state.withLockedValue {
                $0.target
            }
        }
        nonmutating set {
            self._state.withLockedValue {
                guard !$0.shutDown else {
                    return
                }
                $0.target = newValue
            }
            self.signalContinuation.yield()
        }
    }

    public struct Capacity: Sendable, Equatable {
        public var target: Int
        public var available: Int
        public var inUse: Int
        public var creating: Int
    }

    public var currentCapacity: Capacity {
        get {
            self._state.withLockedValue { state in
                Capacity(
                    target: state.target,
                    available: state.idle.count,
                    inUse: state.inUse,
                    creating: state.creating
                )
            }
        }
    }

    /// A stream of capacity snapshots, emitted after every run-loop state transition
    /// (resource created, acquired, returned, or retired).
    ///
    /// The stream keeps only the most recent snapshot (`bufferingNewest(1)`), so a late or
    /// slow consumer always observes the current capacity, and rapid intermediate values may
    /// be coalesced. Must only be consumed by one consumer at a time — the backing stream is
    /// single-subscriber, so concurrent consumers would split snapshots between them.
    package var capacityChanges: AsyncStream<Capacity> {
        self.capacityStream
    }

    public enum ResourceInput: Sendable {
        case resource(AsyncResource)
        case timedOut
        case capacityExhausted
    }

    public enum ResourceOutput: Sendable {
        case returnToThePool
        case removeFromPoolAndShutdown
        case removeFromPoolButAllowRunning
    }

    private enum Acquisition {
        case immediate(ManagedResource)
        case capacityExhausted
        case needsWait(ResourceWaiter<ManagedResource>)
    }

    public func withResource<R: Sendable>(
        timeout: Duration = .forever,
        _ body: @Sendable (ResourceInput) async throws -> (R, ResourceOutput)
    ) async throws -> R {
        let acquisition: Acquisition = self._state.withLockedValue { state in
            if let resource = state.idle.popLast() {
                state.inUse += 1
                return .immediate(resource)
            }
            if state.creating == 0 && (state.totalManaged >= state.target || state.shutDown) {
                return .capacityExhausted
            }
            // Slightly iffy to be doing the initialiser under the lock, but we know this is very simple
            let waiter = ResourceWaiter<ManagedResource>()
            state.waiters.append(waiter)
            return .needsWait(waiter)
        }

        switch acquisition {
        case .immediate(let managed):
            // Acquiring an idle resource leaves totalManaged unchanged, so it triggers no
            // create/destroy — the signal only drives a capacity emission for the idle drop.
            self.signalContinuation.yield()
            return try await self.executeWithResource(managed, body: body)

        case .capacityExhausted:
            let (result, _) = try await body(.capacityExhausted)
            return result

        case .needsWait(let waiter):
            if let managed = await self.waitForResource(timeout: timeout, waiter: waiter) {
                return try await self.executeWithResource(managed, body: body)
            } else {
                let (result, _) = try await body(.timedOut)
                return result
            }
        }
    }

    public func run() async throws {
        logger.info(
            "AsyncResourcePool: run() starting",
            metadata: [
                "initialTarget": "\(self.configuration.initialTargetCapacity)"
            ]
        )
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        let state = self._state.withLockedValue { $0 }
                        logger.info(
                            "AsyncResourcePool: status",
                            metadata: [
                                "target": "\(state.target)",
                                "idle": "\(state.idle.count)",
                                "inUse": "\(state.inUse)",
                                "creating": "\(state.creating)",
                            ]
                        )
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
                self.dispatchActions(into: &group)

                for await _ in self.signalStream {
                    self.dispatchActions(into: &group)
                }
                logger.info(
                    "AsyncResourcePool: signal stream ended, cancelling all resource tasks"
                )
                group.cancelAll()
            }
        } onCancel: {
            logger.info("AsyncResourcePool: task cancelled, initiating shutdown")
            self.initiateShutdown()
        }
        self.cancelWaiters()
        logger.info("AsyncResourcePool: run() completed")
    }

    package func initiateShutdown() {
        let stats = self._state.withLockedValue { state -> (Int, Int, Int) in
            let stats = (state.idle.count, state.inUse, state.creating)
            state.target = 0
            state.shutDown = true
            return stats
        }
        logger.info(
            "AsyncResourcePool: initiateShutdown",
            metadata: [
                "idle": "\(stats.0)",
                "inUse": "\(stats.1)",
                "creating": "\(stats.2)",
            ]
        )
        // As a safety net we do both (a) round of shutdown actions, (b) cancellation of the whole pool when the signal
        // stream finishes
        self.signalContinuation.yield()
        self.signalContinuation.finish()
    }

    private enum DispatchAction {
        case create
        case destroy(AsyncValueBox<AsyncResourceShutdownReason>)
    }

    private func dispatchActions(into group: inout TaskGroup<Void>) {
        let (actions, capacity, state): ([DispatchAction], Capacity, State) = self._state.withLockedValue { state in
            var actions: [DispatchAction] = []

            let excess = state.totalManaged - state.target
            if excess > 0 && !state.idle.isEmpty {
                let destroyCount = min(excess, state.idle.count)
                let removed = state.idle.suffix(destroyCount)
                state.idle.removeLast(destroyCount)
                for resource in removed {
                    if let handle = state.resourceHandles.removeValue(forKey: resource.id) {
                        actions.append(.destroy(handle))
                    }
                }
            }

            let deficit = state.target - state.totalManaged
            let createCount = max(0, deficit)
            state.creating += createCount
            for _ in 0..<createCount {
                actions.append(.create)
            }

            // Capture the post-decision capacity while still holding the lock so the emitted
            // snapshot matches exactly the state this dispatch acted on, free of races with a
            // concurrent checkout, return, or target change.
            let capacity = Capacity(
                target: state.target,
                available: state.idle.count,
                inUse: state.inUse,
                creating: state.creating
            )
            return (actions, capacity, state)
        }

        let toCreateCount = actions.filter {
            if case .create = $0 {
                return true
            }
            return false
        }.count

        let toDestroyCount = actions.filter {
            if case .destroy = $0 {
                return true
            }
            return false
        }.count

        logger.info(
            "AsyncResourcePool: dispatchActions",
            metadata: [
                "target": "\(state.target)",
                "idle": "\(state.idle.count)",
                "inUse": "\(state.inUse)",
                "creating": "\(state.creating)",
                "toCreate": "\(toCreateCount)",
                "toDestroy": "\(toDestroyCount)",
            ]
        )

        for action in actions {
            switch action {
            case .create:
                self.spawnResourceTask(into: &group)
            case .destroy(let handle):
                handle.put(.capacityReduced)
            }
        }

        // The locked block above is the single funnel through which all state transitions pass,
        // so emitting its captured snapshot reports every create/acquire/return/retire exactly once.
        self.capacityContinuation.yield(capacity)
    }

    private func spawnResourceTask(into group: inout TaskGroup<Void>) {
        let id = self._state.withLockedValue { state -> Int in
            let id = state.nextResourceId
            state.nextResourceId += 1
            return id
        }

        let terminationSignal = AsyncValueBox<AsyncResourceShutdownReason>()
        self._state.withLockedValue { state in
            state.resourceHandles[id] = terminationSignal
        }

        group.addTask {
            let recycleDeadline = self.configuration.jitteredLifetime().map { self.clock.now.advanced(by: $0) }
            let resourceBox = NIOLockedValueBox<AsyncResource?>(nil)
            let notifier = AsyncResourcePoolCompletionNotification<AsyncResource> { resource in
                let managed = ManagedResource(resource: resource, id: id, expiresAt: recycleDeadline)
                logger.info(
                    "AsyncResourcePool: resource created",
                    metadata: [
                        "resourceID": "\(id)"
                    ]
                )
                resourceBox.withLockedValue {
                    $0 = resource
                }
                self.offerToWaiters(resource: managed, isNewlyCreated: true)
            }

            await withTaskGroup(of: Void.self) { inner in
                inner.addTask {
                    logger.info(
                        "AsyncResourcePool: creating a new resource",
                        metadata: [
                            "resourceID": "\(id)"
                        ]
                    )
                    await self.factory.createAndRun(notifier: notifier)
                    logger.info(
                        "AsyncResourcePool: resource finished running",
                        metadata: [
                            "resourceID": "\(id)"
                        ]
                    )
                }
                inner.addTask {
                    guard let terminationReason = try? await terminationSignal.get() else {
                        return
                    }
                    logger.info(
                        "AsyncResourcePool: termination signal for resource",
                        metadata: [
                            "resourceID": "\(id)",
                            "reason": "\(terminationReason))",
                        ]
                    )

                    let resource = resourceBox.withLockedValue { $0 }
                    resource?.shutdown(reason: terminationReason)
                }
                // Idle recycle timer: when this resource reaches its lifetime, recycle it if it is idle at that
                // moment. If it is checked out then, `recycleIfIdle` is a no-op. The return path (`handleReturn`)
                // retires it once it comes back, and normal `.removeFromPoolAndShutdown` teardown covers the rest.
                if let recycleDeadline {
                    inner.addTask {
                        do {
                            try await self.clock.sleep(until: recycleDeadline)
                        } catch {
                            // Cancelled before the lifetime elapsed (e.g. the resource was torn
                            // down normally, or the pool is shutting down) — nothing to recycle.
                            return
                        }
                        self.recycleIfIdle(id: id)
                        // Park until cancelled so this task never wins the race below: recycling (or normal teardown)
                        // proceeds via the termination-signal path, and an in-use resource must not be torn down just
                        // because its timer fired.
                        try? await Task.sleep(for: .forever)
                    }
                }
                await inner.next()
                inner.cancelAll()
            }

            logger.info(
                "AsyncResourcePool: handling exit",
                metadata: [
                    "resourceID": "\(id)",
                    "wasFullyCreated": "\(notifier.wasNotified))",
                ]
            )
            if notifier.wasNotified {
                self.handleResourceDeath(id: id)
            } else {
                self._state.withLockedValue { state in
                    state.creating -= 1
                    state.resourceHandles.removeValue(forKey: id)
                }
                self.signalContinuation.yield()
            }
        }
    }

    private func executeWithResource<R: Sendable>(
        _ managed: ManagedResource,
        body: @Sendable (ResourceInput) async throws -> (R, ResourceOutput)
    ) async throws -> R {
        let result: Result<(R, ResourceOutput), any Error>
        do {
            result = .success(try await body(.resource(managed.resource)))
        } catch {
            result = .failure(error)
        }

        switch result {
        case .success(let (value, output)):
            self.handleReturn(managed: managed, output: output)
            return value
        case .failure(let error):
            self.handleReturn(managed: managed, output: .removeFromPoolAndShutdown)
            throw error
        }
    }

    private func handleReturn(managed: ManagedResource, output: ResourceOutput) {
        logger.info(
            "Handling async resource return",
            metadata: [
                "resourceID": .stringConvertible(managed.id),
                "action": .string("\(output)"),
            ]
        )
        switch output {
        case .returnToThePool:
            if let expiresAt = managed.expiresAt, self.clock.now >= expiresAt {
                // The resource reached its maximum lifetime while checked out. Retire it. `.lifetimeExceeded`
                // actively shuts it down (unlike `.executionCompleted`, which assumes the body already did), and the
                // trailing signal has dispatch create a replacement.
                let handle: AsyncValueBox<AsyncResourceShutdownReason>? = self._state.withLockedValue { state in
                    state.inUse -= 1
                    return state.resourceHandles.removeValue(forKey: managed.id)
                }
                logger.info(
                    "AsyncResourcePool: retiring returned resource past its lifetime",
                    metadata: [
                        "resourceID": "\(managed.id)"
                    ]
                )
                handle?.put(.lifetimeExceeded)
            } else {
                self.offerToWaiters(
                    resource: managed,
                    isNewlyCreated: false
                )
            }

        case .removeFromPoolAndShutdown:
            let handle: AsyncValueBox<AsyncResourceShutdownReason>? = self._state.withLockedValue { state in
                state.inUse -= 1
                return state.resourceHandles.removeValue(forKey: managed.id)
            }
            handle?.put(.executionCompleted)

        case .removeFromPoolButAllowRunning:  // TODO: is this case really useful
            self._state.withLockedValue { state in
                state.inUse -= 1
                state.resourceHandles.removeValue(forKey: managed.id)
            }
        }
        self.signalContinuation.yield()
    }

    private enum OfferDispatch {
        case addedToIdle
        case rejectNewlyCreated(AsyncValueBox<AsyncResourceShutdownReason>?)
        case takeWaiter(ResourceWaiter<ManagedResource>)
    }

    private func offerToWaiters(
        resource: ManagedResource,
        isNewlyCreated: Bool
    ) {
        while true {
            let dispatch: OfferDispatch = self._state.withLockedValue { state in
                if state.waiters.isEmpty {
                    // A newly-created resource arriving while we are already at or above
                    // target (or the pool is shutting down) would only be torn down again
                    // by the next `dispatchActions`. Mirror its accounting here and reject
                    // the resource directly so it is never pooled.
                    if isNewlyCreated && (state.shutDown || state.totalManaged > state.target) {
                        state.creating -= 1
                        return .rejectNewlyCreated(state.resourceHandles.removeValue(forKey: resource.id))
                    }
                    if isNewlyCreated {
                        state.creating -= 1
                    } else {
                        state.inUse -= 1
                    }
                    state.idle.append(resource)
                    return .addedToIdle
                }
                return .takeWaiter(state.waiters.removeFirst())
            }

            switch dispatch {
            case .addedToIdle:
                // totalManaged is unchanged, so this drives a capacity emission for the
                // idle growth without provoking any create/destroy.
                self.signalContinuation.yield()
                return
            case .rejectNewlyCreated(let handle):
                handle?.put(.capacityReduced)
                return
            case .takeWaiter(let waiter):
                // The waiter may no longer be interested (because of timeouts)
                // if so, we will go back and retry the whole process
                if waiter.fulfill(resource) {
                    // If the resource was previously inUse (aka not newlyCreated)
                    // we don't need to change the accounting
                    if isNewlyCreated {
                        self._state.withLockedValue { state in
                            state.creating -= 1
                            state.inUse += 1
                        }
                    }
                    return
                }
            }
        }
    }

    private func waitForResource(
        timeout: Duration,
        waiter: ResourceWaiter<ManagedResource>
    ) async -> ManagedResource? {
        // Error exit is only on cancellations
        let result = try? await withTimeout(timeout) {
            try await waiter.wait()
        }

        // If we timed out waiting for resource, we should remove
        // ourselves from the list.
        // We resolve possible races, by keeping more extensive states
        // in the waiter+retrying in `offerToWaiters`
        if result == nil {
            self._state.withLockedValue { state in
                state.waiters.removeAll {
                    waiter === $0
                }
            }
        }

        return result
    }

    private func handleResourceDeath(id: Int) {
        self._state.withLockedValue { state in
            state.resourceHandles.removeValue(forKey: id)
            if let idx = state.idle.firstIndex(where: { $0.id == id }) {
                state.idle.remove(at: idx)
            }
        }
        self.signalContinuation.yield()
    }

    /// Recycles the idle resource with the given `id`: atomically claims it from the idle set and
    /// signals its teardown so it is torn down and replaced. A no-op if the resource is not
    /// currently idle (checked out, already retired, or gone) — recycling never interrupts an
    /// in-flight use, and a checked-out resource is torn down through normal teardown instead.
    ///
    /// Called from a resource's own recycle timer once its idle lifetime elapses.
    private func recycleIfIdle(id: Int) {
        let handle: AsyncValueBox<AsyncResourceShutdownReason>? = self._state.withLockedValue { state in
            guard let idx = state.idle.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            state.idle.remove(at: idx)
            return state.resourceHandles.removeValue(forKey: id)
        }
        guard let handle else {
            return
        }
        logger.info(
            "AsyncResourcePool: recycling idle resource past its lifetime",
            metadata: [
                "resourceID": "\(id)"
            ]
        )
        // Reuse the standard teardown path: `.lifetimeExceeded` drives the resource's shutdown and
        // completes its termination task, which cancels the create task. Removing it from `idle`
        // above dropped `totalManaged` below `target`, so the signalled dispatch schedules a fresh
        // replacement.
        handle.put(.lifetimeExceeded)
        self.signalContinuation.yield()
    }

    private func cancelWaiters() {
        let waiters = self._state.withLockedValue { state -> [ResourceWaiter<ManagedResource>] in
            state.shutDown = true
            let w = state.waiters
            state.waiters = []
            state.idle = []
            state.resourceHandles = [:]
            return w
        }

        for waiter in waiters {
            waiter.cancel()
        }

        // The pool is shutting down; let any capacity consumer's `for await` finish.
        self.capacityContinuation.finish()
    }
}

final class ResourceWaiter<Resource: Sendable>: Sendable {
    private enum State {
        case idle
        case suspended(CheckedContinuation<Resource, any Error>)
        case fulfilled(Resource)
        case done
    }

    private let _state: NIOLockedValueBox<State>

    init() {
        self._state = NIOLockedValueBox(.idle)
    }

    func wait() async throws -> Resource {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Resource, any Error>) in
                let immediate: Result<Resource, any Error>? = self._state.withLockedValue { state in
                    switch state {
                    case .idle:
                        state = .suspended(continuation)
                        return nil
                    case .fulfilled(let resource):
                        state = .done
                        return .success(resource)
                    case .done:
                        return .failure(CancellationError())
                    case .suspended:
                        fatalError("Double wait on ResourceWaiter")
                    }
                }
                if let result = immediate {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func fulfill(_ resource: Resource) -> Bool {
        self._state.withLockedValue { state in
            switch state {
            case .idle:
                state = .fulfilled(resource)
                return true
            case .suspended(let continuation):
                state = .done
                continuation.resume(returning: resource)
                return true
            case .fulfilled, .done:
                return false
            }
        }
    }

    func cancel() {
        self._state.withLockedValue { state in
            switch state {
            case .idle:
                state = .done
            case .suspended(let continuation):
                state = .done
                continuation.resume(throwing: CancellationError())
            case .fulfilled, .done:
                break
            }
        }
    }
}

extension Duration {
    package static let forever: Duration = .nanoseconds(Int64.max)
}
