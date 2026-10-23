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

import CloudBoardDomain
package import CloudBoardCommon
public import CloudBoardLogging
package import CloudBoardMetrics
import Foundation
import os
internal import Synchronization

/// A client for communicating with persistent services running alongside the cloud app.
///
/// Persistent services are long-running helper processes identified by a ``PersistentService.Identity``.
/// Queries are sent as opaque `Data` payloads and correlated to responses via ``PersistentService.QueryCorrelationID``.
///
/// This client handles both timeout management and metric emission:
/// - Queries with a non-nil timeout are tracked; if no response arrives in time, a
///   timeout error is synthesized.
///
/// **Example usage:**
/// ```swift
/// let client: any PersistentServiceClientProtocol = environment.persistentServiceClient
/// let serviceID = PersistentService.Identity(serviceID: 0xABCD_1234_5678_EF00)
/// let correlationID = PersistentService.QueryCorrelationID()
///
/// // Subscribe to results before sending queries
/// let results = client.subscribeToResults(for: serviceID)
///
/// // Send a query with an optional timeout
/// try await client.sendQuery(
///     to: serviceID,
///     payload: queryData,
///     correlationID: correlationID,
///     timeout: .milliseconds(500)
/// )
///
/// // Consume results
/// for try await response in results {
///     if response.correlationID == correlationID {
///         switch response.payload {
///         case .success(let data):
///             // handle response data
///             break
///         case .error(let errorInfo):
///             // handle error
///             break
///         }
///     }
/// }
/// ```
public protocol PersistentServiceClientProtocol: Sendable {
    /// Send a query to a persistent service.
    /// - Parameters:
    ///   - identity: The identity of the persistent service to query.
    ///   - payload: Opaque query data.
    ///   - correlationID: A unique identifier to correlate this query with its response.
    ///   - timeout: Optional per-query timeout. Should be at least 10ms if specified.
    ///     If nil, an appropriate timeout is selected based on the use case.
    func sendQuery(
        to identity: PersistentService.Identity,
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration?
    ) async

    /// Send a query and attach a human-readable `capability` label that downstream metric
    /// emit sites use as a dimension on `QuerySampledDurationHistogram`. Implementations that
    /// don't care about metrics can let the default implementation forward to
    /// ``sendQuery(to:payload:correlationID:timeout:)`` and ignore the label.
    func sendQuery(
        to identity: PersistentService.Identity,
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration?,
        capability: String
    ) async

    /// Subscribe to results from a persistent service.
    /// - Parameter identity: The identity of the persistent service to subscribe to.
    /// - Returns: An async sequence of responses from the persistent service.
    func subscribeToResults(
        for identity: PersistentService.Identity
    ) async -> any AsyncSequence<PersistentService.Response, Never>

    /// Inform the system that forward progress is blocked on the results of specific queries.
    /// - Parameter correlationIDs: The correlation IDs of the queries blocking progress.
    func informBlocked(on correlationIDs: [PersistentService.QueryCorrelationID]) async

    /// Activate the framework's persistent-service metrics under the given swift-metrics
    /// client identity. Concrete implementations construct a `CloudMetricsSystem` lazily
    /// and start emitting `cb_cloudapp_persistent_service_*` metrics for subsequent
    /// responses; mock/no-op adopters should leave this as the default no-op.
    ///
    /// The cloud-app calls this once during startup (e.g. early in `run(input:responder:environment:)`
    /// or during `warmup`) before issuing queries it wants metric-instrumented. Late
    /// activation is supported but lossy — see the concrete `PersistentServiceClient`
    /// implementation for the exact semantics.
    func activateMetrics(clientName: String)
}

extension PersistentServiceClientProtocol {
    /// Default implementation drops the `capability` label and forwards to the existing
    /// no-capability ``sendQuery(to:payload:correlationID:timeout:)``. Adopters that don't
    /// care about metrics get this for free; the concrete `PersistentServiceClient`
    /// overrides it with the capability-aware implementation.
    public func sendQuery(
        to identity: PersistentService.Identity,
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration?,
        capability _: String
    ) async {
        await self.sendQuery(
            to: identity,
            payload: payload,
            correlationID: correlationID,
            timeout: timeout
        )
    }

    /// No-op default for adopters that don't implement framework metrics.
    public func activateMetrics(clientName _: String) {
        // No-op
    }
}

public enum PersistentServiceClientError: ReportableError, Hashable {
    case notYetImplemented

    public var publicDescription: String {
        switch self {
        case .notYetImplemented: return "Not yet implemented"
        }
    }
}

/// Implementation of ``PersistentServiceClientProtocol`` that routes queries through
/// the job helper messenger XPC path to cb_jobhelper.
///
/// Metric emission is **opt-in**. The cloud-app must call ``activateMetrics(clientName:)``
/// once during startup; until activation no metric state is tracked at all (no per-query
/// timing entries, no swift-metrics emits). Once activated, this client emits three
/// metrics, every one of which fires at most once per process per label set:
///
/// - `QueryAtLeastOneResultCounter`: emitted at most once per `(serviceName, result, errorCode)`
///   per process. Acts as a "did we ever see this outcome?" indicator.
/// - `QueryNoCorrelationIDCounter`: emitted at most once per `serviceName` per process.
/// - `QuerySampledDurationHistogram`: a single duration observation per
///   `(serviceName, success, capability)` per process. The current sampling policy is
///   "first observation wins"; the `sampled` in the metric label leaves room for richer
///   policies later without renaming. The `capability` dimension is supplied by filter-aware
///   callers via
///   ``PersistentServiceClientProtocol/sendQuery(to:payload:correlationID:timeout:capability:)``;
///   callers using the no-capability overload get `""`.
public final class PersistentServiceClient: PersistentServiceClientProtocol, Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentServiceClient"
    )

    private let jobHelperMessenger: any JobHelperMessengerProtocol

    fileprivate let state: SubscriptionState

    internal init(
        jobHelperMessenger: any JobHelperMessengerProtocol,
        defaultLateResponsePolicy: LateResponsePolicy = .drop,
        metricsSystem: (any MetricsSystem)? = nil
    ) {
        self.jobHelperMessenger = jobHelperMessenger
        self.state = SubscriptionState(
            defaultLateResponsePolicy: defaultLateResponsePolicy,
            metricsSystem: metricsSystem
        )
    }

    // MARK: - Per-service policy

    package func setLateResponsePolicy(
        _ policy: LateResponsePolicy,
        for identity: PersistentService.Identity
    ) {
        self.state.setLateResponsePolicy(policy, for: identity)
    }

    // MARK: - Metrics activation

    /// Activate the framework's persistent-service metrics by binding this client to the
    /// given swift-metrics client identity. Internally constructs a
    /// `CloudMetricsSystem(clientName:)` (which calls `CloudMetrics.bootstrap` once per
    /// process) and starts emitting `cb_cloudapp_persistent_service_*` metrics for
    /// subsequent responses.
    ///
    /// Activation is one-way per `PersistentServiceClient`. Repeat calls are ignored and a
    /// warning is logged — the existing metrics system stays active. Two reasons:
    /// `CloudMetrics.bootstrap` may assert on a second invocation in the same process, and
    /// the dedup state for the once-per-process counters carries forward, so a swap would
    /// leave the new system unable to emit anything that the previous system already saw.
    /// If the cloud-app needs different metric identities per query, that's not supported here.
    ///
    /// Cloud-apps should call this once during startup (e.g. early in
    /// `run(input:responder:environment:)` or during `warmup`) **before issuing any queries
    /// that should be metric-instrumented**.
    ///
    /// Late activation is supported but lossy. To save memory, the framework skips
    /// per-query timing tracking entirely while metrics are inactive. When a cloud-app
    /// activates after queries are already in flight, responses to those pre-activation
    /// queries arrive without a timing entry and fall into the no-correlation branch of
    /// metric emission, firing `cb_cloudapp_persistent_service_query_no_correlation_id_total`
    /// (already once-per-service, so bounded — but it's a misattribution distinct from the
    /// "real" no-correlation case where the helper sends an unmatched response). Queries
    /// registered *after* activation are tracked normally.
    public func activateMetrics(clientName: String) {
        // Defer constructing `CloudMetricsSystem` until we know we need it — if metrics are
        // already active, constructing a second one would call `CloudMetrics.bootstrap` for
        // nothing and may assert.
        let activated = self.state.activateMetrics { CloudMetricsSystem(clientName: clientName) }
        if !activated {
            Self.logger.warning("""
            activateMetrics(clientName:) called more than once; ignoring repeat activation. \
            clientName=\(clientName, privacy: .public)
            """)
        }
    }

    /// Package overload that accepts a pre-built `MetricsSystem`. Tests use this to inject
    /// `TestMetricsSystem` (or any other instance) without going through `CloudMetricsSystem`.
    /// Same one-way activation contract as ``activateMetrics(clientName:)``.
    package func activateMetrics(_ metricsSystem: any MetricsSystem) {
        let activated = self.state.activateMetrics { metricsSystem }
        if !activated {
            Self.logger.warning("activateMetrics(_:) called more than once; ignoring repeat activation")
        }
    }

    // MARK: - PersistentServiceClientProtocol

    public func sendQuery(
        to identity: PersistentService.Identity,
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration?
    ) async {
        await self.sendQuery(
            to: identity,
            payload: payload,
            correlationID: correlationID,
            timeout: timeout,
            capability: ""
        )
    }

    /// Capability-aware implementation of
    /// ``PersistentServiceClientProtocol/sendQuery(to:payload:correlationID:timeout:capability:)``.
    /// When metrics are active, the `capability` value is recorded in the per-correlationID
    /// timing entry and used as a dimension on `QuerySampledDurationHistogram` when the
    /// response is observed; before activation it is dropped along with the rest of the
    /// timing state.
    public func sendQuery(
        to identity: PersistentService.Identity,
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration?,
        capability: String
    ) async {
        // Register timing + timeout BEFORE sending, to avoid a race where an early
        // response arrives before the timeout/timing entries exist.
        self.state.registerQuery(
            correlationID: correlationID,
            identity: identity,
            timeout: timeout,
            capability: capability
        )

        await self.jobHelperMessenger.sendPersistentServiceQuery(
            to: identity,
            payload: payload,
            correlationID: correlationID,
            timeout: timeout
        )
    }

    public func subscribeToResults(
        for identity: PersistentService.Identity
    ) async -> any AsyncSequence<PersistentService.Response, Never> {
        await self.subscribeMergedStream(for: identity)
    }

    /// Internal: returns a shared async sequence for the given identity.
    ///
    /// The first call for an identity creates the merge task (which pumps responses from
    /// the real stream + timeout stream → metrics → `AsyncStream` buffer). An
    /// `AsyncShareSequence` wraps this buffer, allowing multiple concurrent consumers.
    /// Subsequent calls return the same shared sequence — each caller gets an independent
    /// iterator that receives all responses from the point it starts iterating.
    ///
    /// The merge task starts pumping immediately into the base `AsyncStream` (which buffers
    /// unconditionally). `AsyncShareSequence` is demand-driven — it pulls from the buffer
    /// only when a consumer calls `next()`. This means:
    /// - Responses are never lost (buffered in the base stream)
    /// - Consumers see responses from when they start iterating forward
    /// - If no consumer is iterating, responses accumulate in the buffer
    private func subscribeMergedStream(
        for identity: PersistentService.Identity
    ) async -> AsyncShareSequence<AsyncStream<PersistentService.Response>> {
        let (promise, isCreator) = self.state.getOrCreateStreamPromise(for: identity)

        if isCreator {
            let manager = self.state.manager(for: identity)
            let timeoutStream = manager.timeoutResponses

            let (mergedStream, mergedContinuation) = AsyncStream<PersistentService.Response>.makeStream()

            let realStream = await self.jobHelperMessenger.persistentServiceResponses(for: identity)

            // The merge task starts immediately and pumps responses into the AsyncStream
            // regardless of whether anyone is consuming it yet. AsyncStream buffers the
            // yields, so no responses are lost.
            // The merge task captures state weakly to break the retain cycle:
            // SubscriptionState → mergeTasks → Task closure → state. If state is freed
            // (client deallocated), the connection is gone anyway — dropping metrics for
            // in-flight responses is harmless since no one will observe the results anyway.
            let mergeTask = Task { [weak state = self.state] in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await response in timeoutStream {
                            guard !Task.isCancelled else { break }
                            state?.emitMetrics(for: response, identity: identity)
                            mergedContinuation.yield(response)
                        }
                    }

                    for await response in realStream {
                        guard !Task.isCancelled else { break }
                        if let filtered = manager.processRealResponse(response) {
                            state?.emitMetrics(for: filtered, identity: identity)
                            mergedContinuation.yield(filtered)
                        }
                    }

                    group.cancelAll()
                    await group.waitForAll()
                    mergedContinuation.finish()
                }
            }
            self.state.storeMergeTask(mergeTask, for: identity)

            nonisolated(unsafe) let iterator = mergedStream.makeAsyncIterator()
            let shared = AsyncShareSequence<AsyncStream<PersistentService.Response>>(
                { iterator },
                bufferingPolicy: .unbounded
            )
            promise.succeed(with: shared)
        }

        return await Future(promise).value
    }

    public func informBlocked(on correlationIDs: [PersistentService.QueryCorrelationID]) async {
        await self.jobHelperMessenger.informPersistentServiceBlocked(on: correlationIDs)
    }

    // MARK: - Query session (request/response convenience)

    /// Create a query session for simple request/response patterns.
    ///
    /// - Note: Prefer ``withQuerySession(for:body:)`` which manages the pump lifecycle
    ///   automatically. This method requires the caller to start ``run()`` in a task and
    ///   ensure it is cancelled when done — failure to do so will hang.
    ///
    /// Multiple sessions and/or direct ``subscribeToResults(for:)`` calls can coexist
    /// for the same identity — each gets an independent view of all responses.
    public func makeQuerySession(
        for identity: PersistentService.Identity
    ) async -> PersistentServiceQuerySession {
        let stream = await self.subscribeMergedStream(for: identity)
        return PersistentServiceQuerySession(client: self, identity: identity, stream: stream)
    }

    /// Execute a block with a managed query session.
    ///
    /// This is the recommended way to use the request/response API. The pump is started
    /// automatically and cancelled when `body` returns — no manual lifecycle management
    /// is needed.
    ///
    /// Multiple calls for the same identity are supported — each gets an independent
    /// view of all responses via the shared stream.
    ///
    /// **Example (single query):**
    /// ```swift
    /// let result = try await client.withQuerySession(for: identity) { session in
    ///     try await session.query(payload: data, correlationID: id, timeout: .seconds(5))
    /// }
    /// ```
    ///
    /// **Example (parallel queries):**
    /// ```swift
    /// let results = try await client.withQuerySession(for: identity) { session in
    ///     async let r1 = session.query(payload: p1, correlationID: id1)
    ///     async let r2 = session.query(payload: p2, correlationID: id2)
    ///     return try await [r1, r2]
    /// }
    /// ```
    public func withQuerySession<Result: Sendable>(
        for identity: PersistentService.Identity,
        body: @escaping @Sendable (PersistentServiceQuerySession) async throws -> Result
    ) async throws -> Result {
        let stream = await self.subscribeMergedStream(for: identity)
        let session = PersistentServiceQuerySession(client: self, identity: identity, stream: stream)

        return try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                await session.run()
                throw CancellationError()
            }
            group.addTask {
                try await body(session)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Internal state

private final class SubscriptionState: Sendable {
    private let defaultLateResponsePolicy: LateResponsePolicy

    fileprivate struct MutableState {
        var managers: [PersistentService.Identity: QueryTimeoutManager<ContinuousClock>] = [:]
        var sharedStreams: [
            PersistentService.Identity:
                Promise<AsyncShareSequence<AsyncStream<PersistentService.Response>>, Never>
        ] = [:]
        var mergeTasks: [PersistentService.Identity: Task<Void, Never>] = [:]
    }

    fileprivate let lock: Mutex<MutableState>

    /// Soft cap on the number of in-flight timing entries retained per `SubscriptionState`.
    /// Far above any realistic concurrent-query count — the cap exists only as a backstop
    /// against pathological leaks (helper disconnect mid-flight, queries with `nil` timeout
    /// that never receive a response). At the cap the oldest entry is dropped; an eventual
    /// late response for an evicted entry falls through to the no-correlation branch in
    /// ``emitMetrics(for:identity:)``, which is already a once-per-service emit.
    private static let maxInFlightTimingEntries: Int = 1024

    private struct TimingEntry: Sendable {
        let sentAt: Date
        let identity: PersistentService.Identity
        let capability: String
    }

    /// Bounded-FIFO storage for in-flight timing entries.
    ///
    /// `entries` is the lookup map; `insertionOrder` is a fixed-capacity ring buffer of
    /// the most recently inserted correlation IDs. When the ring buffer overwrites a slot,
    /// the displaced ID is removed from `entries` if it is still present (eviction).
    /// `emitMetrics` only mutates `entries`; the ring buffer self-cleans when its slots
    /// are eventually overwritten — `entries.removeValue` simply no-ops on stale IDs.
    private struct BoundedTimings: Sendable {
        var entries: [PersistentService.QueryCorrelationID: TimingEntry] = [:]
        var insertionOrder: [PersistentService.QueryCorrelationID?]
        var writeHead: Int = 0

        init(capacity: Int) {
            self.insertionOrder = Array(repeating: nil, count: capacity)
        }

        /// Inserts `entry` and evicts the oldest entry if the ring buffer overwrites a
        /// still-live slot. Amortized O(1).
        mutating func insert(_ id: PersistentService.QueryCorrelationID, entry: TimingEntry) {
            self.entries[id] = entry
            let displaced = self.insertionOrder[self.writeHead]
            self.insertionOrder[self.writeHead] = id
            self.writeHead = (self.writeHead + 1) % self.insertionOrder.count
            if let displaced, displaced != id {
                self.entries.removeValue(forKey: displaced)
            }
        }

        mutating func remove(
            _ id: PersistentService.QueryCorrelationID
        ) -> TimingEntry? {
            self.entries.removeValue(forKey: id)
        }
    }

    /// Timing entries for in-flight queries, keyed by correlation ID.
    /// Separate from the main lock so the merge task (which calls ``emitMetrics``)
    /// never contends with ``registerQuery`` or ``manager(for:)`` on the main lock.
    ///
    /// Populated only while a metrics system is active — ``registerQuery`` checks
    /// ``isMetricsActive()`` first and skips the insert when no system is bound. Cloud-apps
    /// that never call ``activateMetrics(_:)`` pay nothing for this storage; activation
    /// after queries are already in flight is supported but lossy (those queries' responses
    /// fall through to the no-correlation branch — see the public docstring on
    /// ``PersistentServiceClient/activateMetrics(clientName:)``).
    private let queryTimings: Mutex<BoundedTimings>

    private struct ResultKey: Hashable, Sendable {
        let serviceName: String
        let success: Bool
        let errorCode: String
    }

    private struct DurationKey: Hashable, Sendable {
        let serviceName: String
        let success: Bool
        let capability: String
    }

    private struct OneShotMetricState: Sendable {
        /// Active metrics system. `nil` until ``activateMetrics(_:)`` is called by the cloud-app.
        var metricsSystem: (any MetricsSystem)?
        var noCorrelationServices: Set<String> = []
        var resultsSeen: Set<ResultKey> = []
        var sampledDurationKeysSeen: Set<DurationKey> = []
    }

    /// Tracks the active metrics system plus the label sets already reported via the
    /// at-most-once metric emit sites, so each emit fires exactly once per process lifetime.
    private let oneShot: Mutex<OneShotMetricState>

    init(
        defaultLateResponsePolicy: LateResponsePolicy,
        metricsSystem: (any MetricsSystem)? = nil
    ) {
        self.defaultLateResponsePolicy = defaultLateResponsePolicy
        self.lock = Mutex(MutableState())
        self.queryTimings = Mutex(BoundedTimings(capacity: Self.maxInFlightTimingEntries))
        self.oneShot = Mutex(OneShotMetricState(metricsSystem: metricsSystem))
    }

    /// Install `buildSystem()` as the active metrics system if no system has been activated
    /// yet (whether by an earlier `activateMetrics` call or by the constructor seed). Returns
    /// `true` if the new system was installed, `false` if a previous activation is still in
    /// effect. The closure is invoked only when activation will succeed, so callers that
    /// would otherwise pay a cost to construct a `MetricsSystem` (e.g. `CloudMetricsSystem`,
    /// which calls `CloudMetrics.bootstrap`) avoid that work on repeat calls.
    func activateMetrics(_ buildSystem: () -> any MetricsSystem) -> Bool {
        self.oneShot.withLock { state in
            guard state.metricsSystem == nil else { return false }
            state.metricsSystem = buildSystem()
            return true
        }
    }

    /// Snapshot whether a metrics system is currently active. Used by ``registerQuery`` to
    /// short-circuit timing-entry inserts when no system is bound; a TOCTOU race with
    /// ``activateMetrics(_:)`` is acceptable because the contract is "activate before sending
    /// queries", and a missed insert simply causes the response to take the no-correlation
    /// branch in ``emitMetrics(for:identity:)``.
    func isMetricsActive() -> Bool {
        self.oneShot.withLock { $0.metricsSystem != nil }
    }

    /// Merge tasks are not cleaned up before deinit — once a service identity is used,
    /// it should be assumed useful for the rest of the cloud app's lifetime, and the
    /// task is cheap to retain. Cancellation happens in deinit when the client is freed.
    deinit {
        let tasks = self.lock.withLock { Array($0.mergeTasks.values) }
        for task in tasks {
            task.cancel()
        }
    }

    func storeMergeTask(_ task: Task<Void, Never>, for identity: PersistentService.Identity) {
        self.lock.withLock { $0.mergeTasks[identity] = task }
    }

    func setLateResponsePolicy(_ policy: LateResponsePolicy, for identity: PersistentService.Identity) {
        let manager = self.lock.withLock { state in
            self.getOrCreateManager(in: &state, for: identity)
        }
        manager.setLateResponsePolicy(policy)
    }

    func manager(for identity: PersistentService.Identity) -> QueryTimeoutManager<ContinuousClock> {
        self.lock.withLock { state in
            self.getOrCreateManager(in: &state, for: identity)
        }
    }

    private func getOrCreateManager(
        in state: inout MutableState,
        for identity: PersistentService.Identity
    ) -> QueryTimeoutManager<ContinuousClock> {
        if let existing = state.managers[identity] {
            return existing
        }
        let mgr = QueryTimeoutManager(clock: ContinuousClock(), lateResponsePolicy: self.defaultLateResponsePolicy)
        state.managers[identity] = mgr
        return mgr
    }

    // MARK: - Query registration (timing + timeout)

    func registerQuery(
        correlationID: PersistentService.QueryCorrelationID,
        identity: PersistentService.Identity,
        timeout: Duration?,
        capability: String
    ) {
        let sentAt = Date()

        // Skip the timing insert when no metrics system is bound — saves the per-query
        // ring-buffer write and the dictionary entry on cloud-apps that never call
        // ``activateMetrics``. If a cloud-app activates *after* this query was registered,
        // the response will fall into the no-correlation branch of ``emitMetrics`` (driving
        // the once-per-service `cb_cloudapp_persistent_service_query_no_correlation_id_total`
        // counter) instead of producing a duration sample. Activate during startup before
        // sending queries to avoid that misattribution.
        if self.isMetricsActive() {
            self.queryTimings.withLock {
                $0.insert(
                    correlationID,
                    entry: TimingEntry(sentAt: sentAt, identity: identity, capability: capability)
                )
            }
        }

        let manager = self.lock.withLock { state in
            self.getOrCreateManager(in: &state, for: identity)
        }

        manager.registerQuery(
            correlationID: correlationID,
            timeout: timeout,
            querySentAt: sentAt
        )
    }

    /// Emit metrics for a response. The `identity` is provided by the caller (captured
    /// at subscription time) so this method never needs to touch the main lock.
    ///
    /// Every emit path fires at most once per process per label set, and only after the
    /// cloud-app has called ``activateMetrics(_:)`` (or the constructor seed):
    /// - `QueryAtLeastOneResultCounter` is emitted on the first response per
    ///   `(serviceName, success, errorCode)` triple.
    /// - `QuerySampledDurationHistogram` records the first observed duration per
    ///   `(serviceName, success, capability)` triple. Subsequent responses for the same
    ///   triple are silently dropped — the metric label keeps `sampled` so a future policy
    ///   change (reservoir sampling, periodic resets, etc.) can land without renaming.
    /// - `QueryNoCorrelationIDCounter` is emitted on the first no-correlation response per
    ///   `serviceName`.
    func emitMetrics(for response: PersistentService.Response, identity: PersistentService.Identity) {
        let timing = self.queryTimings.withLock { $0.remove(response.correlationID) }
        let serviceName = PersistentService.serviceName(for: identity.serviceID)

        if let timing {
            let durationSeconds = Date().timeIntervalSince(timing.sentAt)
            let success: Bool
            let errorCode: String
            switch response.payload {
            case .success:
                success = true
                errorCode = ""
            case .error(let errorInfo):
                success = false
                errorCode = "\(errorInfo.code)"
            }

            // Snapshot the metrics system + dedup state under a single lock acquisition.
            // Emit outside the lock to avoid holding it across the metrics-system's emit().
            let snapshot = self.oneShot.withLock { state -> (
                metrics: (any MetricsSystem)?,
                resultIsFirst: Bool,
                durationIsFirst: Bool
            ) in
                guard let metrics = state.metricsSystem else {
                    return (nil, false, false)
                }
                let r = state.resultsSeen.insert(
                    ResultKey(serviceName: serviceName, success: success, errorCode: errorCode)
                ).inserted
                let d = state.sampledDurationKeysSeen.insert(
                    DurationKey(serviceName: serviceName, success: success, capability: timing.capability)
                ).inserted
                return (metrics, r, d)
            }

            guard let metricsSystem = snapshot.metrics else { return }

            if snapshot.resultIsFirst {
                metricsSystem.emit(PersistentServiceMetrics.QueryAtLeastOneResultCounter(
                    serviceName: serviceName,
                    success: success,
                    errorCode: errorCode
                ))
            }
            if snapshot.durationIsFirst {
                metricsSystem.emit(PersistentServiceMetrics.QuerySampledDurationHistogram(
                    durationSeconds: durationSeconds,
                    serviceName: serviceName,
                    success: success,
                    capability: timing.capability
                ))
            }
        } else {
            let snapshot = self.oneShot.withLock { state -> (
                metrics: (any MetricsSystem)?,
                isFirst: Bool
            ) in
                guard let metrics = state.metricsSystem else { return (nil, false) }
                let inserted = state.noCorrelationServices.insert(serviceName).inserted
                return (metrics, inserted)
            }
            guard let metricsSystem = snapshot.metrics else { return }
            if snapshot.isFirst {
                metricsSystem.emit(PersistentServiceMetrics.QueryNoCorrelationIDCounter(
                    action: .increment,
                    serviceName: serviceName
                ))
            }
        }
    }

    // MARK: - Shared stream management

    /// Atomically returns the promise for the shared stream, creating it if this is the first call.
    /// The caller uses `isCreator` to know whether they need to set up the merge task.
    func getOrCreateStreamPromise(
        for identity: PersistentService.Identity
    ) -> (Promise<AsyncShareSequence<AsyncStream<PersistentService.Response>>, Never>, isCreator: Bool) {
        self.lock.withLock { state in
            if let existing = state.sharedStreams[identity] {
                return (existing, false)
            }
            let promise = Promise<AsyncShareSequence<AsyncStream<PersistentService.Response>>, Never>()
            state.sharedStreams[identity] = promise
            return (promise, true)
        }
    }
}

// MARK: - Query session

/// A session that provides a simple request/response interface to a persistent service.
///
/// Created via ``PersistentServiceClient/makeQuerySession(for:)``. Start the
/// session's pump with ``run()`` in a task group, then call ``query()`` to send
/// queries and await their responses. Multiple ``query()`` calls can safely run
/// concurrently from a task group.
///
/// - Important: The `correlationID` must also be encoded into `payload` by the
///   caller. This is a legacy coupling — a future update will decouple these.
///
/// **Example (single query):**
/// ```swift
/// let session = try await client.makeQuerySession(for: identity)
/// try await withThrowingTaskGroup(of: Void.self) { group in
///     group.addTask { await session.run() }
///     let result = try await session.query(
///         payload: data, correlationID: id, timeout: .seconds(5)
///     )
///     session.cancel()
/// }
/// ```
///
/// **Example (parallel queries):**
/// ```swift
/// let session = try await client.makeQuerySession(for: identity)
/// try await withThrowingTaskGroup(of: PersistentService.ResponsePayload.self) { group in
///     group.addTask { await session.run(); throw CancellationError() }
///     for (payload, id) in queries {
///         group.addTask {
///             try await session.query(payload: payload, correlationID: id, timeout: .seconds(5))
///         }
///     }
///     var results: [PersistentService.ResponsePayload] = []
///     for try await result in group { results.append(result) }
/// }
/// ```
public final class PersistentServiceQuerySession: Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentServiceQuerySession"
    )

    private let client: PersistentServiceClient
    private let identity: PersistentService.Identity
    private let stream: AsyncShareSequence<AsyncStream<PersistentService.Response>>
    private let pendingQueries: Mutex<[
        PersistentService.QueryCorrelationID: Promise<PersistentService.ResponsePayload, any Error>
    ]>

    fileprivate init(
        client: PersistentServiceClient,
        identity: PersistentService.Identity,
        stream: AsyncShareSequence<AsyncStream<PersistentService.Response>>
    ) {
        self.client = client
        self.identity = identity
        self.stream = stream
        self.pendingQueries = Mutex([:])
    }

    /// Run the subscription pump. Blocks until cancelled or the underlying stream ends.
    ///
    /// The stream is already set up (timeout merging + metrics are handled by
    /// ``PersistentServiceClient/subscribeToResults(for:)``). This method just
    /// matches responses to pending promises.
    public func run() async {
        for await response in self.stream {
            guard !Task.isCancelled else {
                break
            }
            let promise = self.pendingQueries.withLock { $0.removeValue(forKey: response.correlationID) }
            promise?.succeed(with: response.payload)
        }
        self.failAllPending()
    }

    /// Send a query and await the matching response.
    ///
    /// - Important: The `correlationID` must also be encoded into `payload`.
    ///   This is a legacy coupling that will be decoupled in a future update.
    ///
    /// - Parameters:
    ///   - payload: Opaque query data (must contain the encoded `correlationID`).
    ///   - correlationID: A unique identifier matching the ID encoded in `payload`.
    ///   - timeout: Optional per-query timeout.
    /// - Returns: The response payload (success data or error info).
    /// - Throws: `CancellationError` if the task is cancelled or the session ends.
    public func query(
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration? = nil
    ) async throws -> PersistentService.ResponsePayload {
        try await self.query(
            payload: payload,
            correlationID: correlationID,
            timeout: timeout,
            capability: ""
        )
    }

    /// Package-only overload that lets a filter-aware caller attach a `capability` label.
    /// Forwards into ``PersistentServiceClient/sendQuery(to:payload:correlationID:timeout:capability:)``.
    package func query(
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration? = nil,
        capability: String
    ) async throws -> PersistentService.ResponsePayload {
        let promise = Promise<PersistentService.ResponsePayload, any Error>(
            autoFailureIfUnfulfilled: CancellationError()
        )
        self.pendingQueries.withLock { $0[correlationID] = promise }

        await self.client.sendQuery(
            to: self.identity,
            payload: payload,
            correlationID: correlationID,
            timeout: timeout,
            capability: capability
        )

        return try await Future(promise).valueWithCancellation
    }

    /// Cancel the session, failing all pending promises with `CancellationError`.
    public func cancel() {
        self.failAllPending()
    }

    private func failAllPending() {
        let pending = self.pendingQueries.withLock { queries in
            let all = queries
            queries.removeAll()
            return all
        }
        for (_, promise) in pending {
            promise.fail(with: CancellationError())
        }
    }
}
