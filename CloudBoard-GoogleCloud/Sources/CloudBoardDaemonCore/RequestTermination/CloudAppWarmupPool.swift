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

import CloudBoardUtilities
import Configuration
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import Metrics
import NIOPosix
import ServiceLifecycle

extension JobHelperClient: AsyncResourceProtocol {
    func shutdown(reason: AsyncResourceShutdownReason) {
        switch reason {
        case .capacityReduced:
            self.terminate(reason: "instance not needed")
        case .lifetimeExceeded:
            self.terminate(reason: "instance reached maximum lifetime")
        case .executionCompleted:
            // The body that consumed this resource is responsible for terminating
            // cb_jobhelper itself, so nothing to do here.
            break
        }
    }
}

/// Builds and owns the lifetime of a single `JobHelperClient` for `AsyncResourcePool`.
///
/// `createAndRun` spins up the gRPC transport, drives `JobHelperClient.run`, waits for
/// warmup to complete, hands the warmed-up client to the pool, then parks until the
/// jobhelper reaches a terminal state — or until the pool cancels this task to retire
/// the resource.
struct JobHelperFactory: AsyncResourceFactory {
    private static let logger = Logger(label: "cloudboardd.JobHelperFactory")

    let jobHelperSocketPath: String
    let cloudAppSocket: SocketAddress.UnixDomainSocket
    let warmupTimeout: Duration
    let metricsFactory: any MetricsFactory

    init(
        jobHelperSocketPath: String,
        cloudAppSocket: SocketAddress.UnixDomainSocket,
        configReader: ConfigReader,
        metricsFactory: any MetricsFactory
    ) {
        self.jobHelperSocketPath = jobHelperSocketPath
        self.cloudAppSocket = cloudAppSocket
        let warmupTimeoutSeconds = configReader.int(forKey: "warmupPool.warmupTimeoutSeconds", default: 30)
        self.warmupTimeout = .seconds(warmupTimeoutSeconds)
        self.metricsFactory = metricsFactory
    }

    func createAndRun(
        notifier: AsyncResourcePoolCompletionNotification<JobHelperClient>
    ) async {
        do {
            try await self.failableCreateAndRun(notifier: notifier)
        } catch is CancellationError {
            // The pool retires an instance (capacity reduction, max lifetime, or pool shutdown) by
            // cancelling this task. That is expected teardown, not a failure.
            Self.logger.debug("JobHelperFactory task cancelled for retirement")
        } catch {
            Self.logger.error(
                "JobHelperFactory exited with an error",
                metadata: ["error": .string(String(reportable: error))]
            )
        }
    }

    private func failableCreateAndRun(
        notifier: AsyncResourcePoolCompletionNotification<JobHelperClient>
    ) async throws {
        let transport = try await HTTP2ClientTransport.WrappedChannel.wrapping { configure in
            try await ClientBootstrap(
                group: .singletonMultiThreadedEventLoopGroup
            ).connect(unixDomainSocketPath: self.jobHelperSocketPath) { channel in
                configure(channel)
            }
        }
        try await withGRPCClient(transport: transport) { grpcClient in
            try await withJobHelperClient(
                grpcClient: grpcClient,
                cloudAppSocket: self.cloudAppSocket
            ) { jobHelperClient in
                let warmupStart = ContinuousClock.now
                do {
                    try await withTimeout(self.warmupTimeout) {
                        try await jobHelperClient.waitForWarmupToComplete()
                    }
                    Timer(
                        label: "cloudboard_prewarm_jobhelper_warmup_duration",
                        preferredDisplayUnit: .milliseconds,
                        factory: self.metricsFactory
                    ).record(duration: ContinuousClock.now - warmupStart)
                } catch {
                    // A cancelled factory task means the pool is retiring this instance (shrinking
                    // or shutting down), not a warmup failure, so don't count it as such. `withTimeout`
                    // propagates cancellation unchanged, so a `TimeoutError` here is a real timeout.
                    if !(error is CancellationError) {
                        Counter(
                            label: "cloudboard_prewarm_jobhelper_warmup_error_total",
                            dimensions: [("reason", error is TimeoutError ? "timeout" : "error")],
                            factory: self.metricsFactory
                        ).increment()
                        if let timeoutError = error as? TimeoutError {
                            Self.logger.error(
                                "JobHelperFactory timed out during warmup",
                                metadata: [
                                    "timeout": "\(self.warmupTimeout)",
                                    "error": .string(String(reportable: timeoutError.underlyingError)),
                                ]
                            )
                        }
                    }
                    throw error
                }
                notifier.notify(resourceReady: jobHelperClient)

                // Park here until the jobhelper finishes naturally (post-request) or
                // fails. When the pool retires this resource the surrounding task gets
                // cancelled, which propagates as a CancellationError out of waitFirst.
                let result = await MultiWaiter.waitFirst {
                    try await jobHelperClient.stateMachine.waitUntil(state: .failed)
                } _: {
                    try await jobHelperClient.stateMachine.waitUntil(state: .finished)
                }
                switch result {
                case .first(let outcome), .second(let outcome):
                    _ = try outcome.get()
                }
            }
        }
    }
}

enum CloudAppWarmupPoolError: ReportableError {
    case capacityExhausted
    case acquireTimedOut
    case targetCapacityRaisedWhileWaitingToEmpty

    var publicDescription: String {
        switch self {
        case .capacityExhausted:
            "CloudApp warmup pool capacity exhausted"
        case .acquireTimedOut:
            "Timed out waiting for a warmed-up CloudApp from the pool"
        case .targetCapacityRaisedWhileWaitingToEmpty:
            "CloudApp warmup pool target capacity raised while waiting to empty"
        }
    }
}

/// The result of a ``CloudAppWarmupPool/withJobHelperClient(acquireTimeout:_:)`` body, telling the pool how to dispose
/// of the acquired cb_jobhelper. Each cb_jobhelper is single-use, so a completed request always retires the instance.
/// However, a failure before the cb_jobhelper has been used/committed should not result in the instance being
/// terminated. Instead it can be returned to the pool for future use.
enum JobHelperRequestOutcome<Value: Sendable>: Sendable {
    /// The request finished. Retire the (single-use) worker and hand `value` back to the caller.
    case completed(Value)
    /// The request failed after it was committed to the worker. Retire the worker and rethrow `error` to the caller.
    case failedAfterCommit(any Error)
    /// The request failed before it was committed to the worker, which is therefore still warm and unused. Return it to
    /// the pool for reuse and rethrow `error` to the caller.
    case failedBeforeCommit(any Error)
}

/// Pool of pre-warmed `JobHelperClient`s. The owner (typically `ServiceStatusMonitor`) is responsible for sizing the
/// pool via ``targetCapacity``.
///
/// Per-request work goes through ``withJobHelperClient(acquireTimeout:_:)`` which acquires a warmed instance and runs
/// the body. A cb_jobhelper process handles a single request, so the instance is retired once the request completes or
/// fails after being committed to it. A failure before the request is committed leaves the instance warm and returns
/// it to the pool.
struct CloudAppWarmupPool: Service {
    private static let logger = Logger(label: "cloudboardd.CloudAppWarmupPool")

    let rawPool: AsyncResourcePool<JobHelperClient, JobHelperFactory>
    let terminationTimeout: Duration
    let metricsFactory: any MetricsFactory

    public var targetCapacity: Int {
        get { self.rawPool.targetCapacity }
        nonmutating set { self.rawPool.targetCapacity = newValue }
    }

    /// A stream of the pool's capacity snapshots.
    ///
    /// - SeeAlso: `AsyncResourcePool.capacityChanges` for emission and buffering semantics.
    var capacityChanges: AsyncStream<AsyncResourcePool<JobHelperClient, JobHelperFactory>.Capacity> {
        self.rawPool.capacityChanges
    }

    /// The pool's current capacity snapshot. Suitable for periodic sampling (e.g. metrics),
    /// unlike ``capacityChanges``, which is a single-consumer stream.
    var currentCapacity: AsyncResourcePool<JobHelperClient, JobHelperFactory>.Capacity {
        self.rawPool.currentCapacity
    }

    /// Can throw CancellationError or CloudAppWarmupPoolError.targetCapacityRaisedWhileWaitingToEmpty
    func waitForEmpty() async throws {
        while true {
            let capacity = self.rawPool.currentCapacity
            if capacity.target != 0 {
                throw CloudAppWarmupPoolError.targetCapacityRaisedWhileWaitingToEmpty
            }
            if capacity.available == 0 && capacity.inUse == 0 && capacity.creating == 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    init(
        cloudAppSocket: SocketAddress.UnixDomainSocket,
        jobHelperSocketPath: String,
        configReader: ConfigReader,
        metricsFactory: any MetricsFactory = MetricsSystem.factory
    ) {
        self.metricsFactory = metricsFactory
        var configuration = AsyncResourcePoolConfiguration.default
        // Start at zero. `ServiceStatusMonitor` raises the target once the controller hands us the workload's
        // batch-size.
        configuration.initialTargetCapacity = 0
        // Recycle idle pre-warmed cb_jobhelper instances after a maximum lifetime so long-lived idle processes are
        // periodically replaced by fresh ones. A non-positive value disables recycling.
        //
        // We do this to allow for maximum per-request process lifetime enforcement via systemd.
        let maxInstanceLifetimeSeconds = configReader.int(
            forKey: "warmupPool.maxInstanceLifetimeSeconds",
            // Recycle processes after 10 minutes by default
            default: 60 * 10
        )
        if maxInstanceLifetimeSeconds > 0 {
            configuration.maxIdleResourceLifetime = .seconds(maxInstanceLifetimeSeconds)
            // Jitter spreads a cohort's teardowns over a window to avoid recycling them all at once
            configuration.maxIdleResourceLifetimeJitterPercent = configReader.double(
                forKey: "warmupPool.maxInstanceLifetimeJitterPercent",
                default: 10
            )
        }
        self.rawPool = AsyncResourcePool<JobHelperClient, JobHelperFactory>(
            factory: JobHelperFactory(
                jobHelperSocketPath: jobHelperSocketPath,
                cloudAppSocket: cloudAppSocket,
                configReader: configReader,
                metricsFactory: metricsFactory
            ),
            configuration: configuration
        )
        let terminationTimeoutSeconds = configReader.int(
            forKey: "warmupPool.terminationTimeoutSeconds",
            default: 5
        )
        self.terminationTimeout = .seconds(terminationTimeoutSeconds)

        Self.logger.info(
            "CloudAppWarmupPool initialised",
            metadata: [
                "jobHelperSocketPath": "\(jobHelperSocketPath)",
                "cloudAppSocketPath": "\(cloudAppSocket.path)",
                "terminationTimeout": "\(self.terminationTimeout)",
                "maxInstanceLifetime": "\(configuration.maxIdleResourceLifetime.map { "\($0)" } ?? "disabled")",
                "maxInstanceLifetimeJitterPercent": "\(configuration.maxIdleResourceLifetimeJitterPercent)",
            ]
        )
    }

    /// Acquires a warmed cb_jobhelper, runs `body`, and disposes of the instance according to the
    /// ``JobHelperRequestOutcome`` the body returns: a completed or committed-then-failed request retires the
    /// worker, while a failure before the request was committed returns the still-warm worker to the pool for reuse.
    /// The body's caller-facing value is returned. A failure outcome's error is rethrown.
    func withJobHelperClient<R: Sendable>(
        acquireTimeout: Duration,
        _ body: @escaping @Sendable (JobHelperClient) async -> JobHelperRequestOutcome<R>
    ) async throws -> R {
        let acquireStart = ContinuousClock.now
        let result: Result<R, any Error> = try await self.rawPool.withResource(timeout: acquireTimeout) { resource in
            switch resource {
            case .resource(let jobHelperClient):
                Timer(
                    label: "cloudboard_prewarm_pool_acquire_duration",
                    preferredDisplayUnit: .milliseconds,
                    factory: self.metricsFactory
                ).record(duration: ContinuousClock.now - acquireStart)

                switch await body(jobHelperClient) {
                case .completed(let value):
                    await self.terminateAndAwait(jobHelperClient, reason: "request handling completed")
                    return (.success(value), .removeFromPoolAndShutdown)

                case .failedAfterCommit(let error):
                    Self.logger.info(
                        "Retiring job helper after request failure",
                        metadata: ["error": "\(String(reportable: error))"]
                    )
                    await self.terminateAndAwait(jobHelperClient, reason: "request handling failed")
                    return (.failure(error), .removeFromPoolAndShutdown)

                case .failedBeforeCommit(let error):
                    // The request failed before it was committed to the worker (e.g. a setupAck write failed because
                    // ROPES closed the channel), so the instance is still warm and unused. Return it to the pool rather
                    // than paying to build and warm a replacement.
                    Self.logger.warning(
                        "Returning unused warmed cb_jobhelper to pool after pre-request failure",
                        metadata: ["error": "\(String(reportable: error))"]
                    )
                    Counter(
                        label: "cloudboard_prewarm_pool_worker_returned_unused_total",
                        factory: self.metricsFactory
                    ).increment()
                    return (.failure(error), .returnToThePool)
                }
            case .timedOut:
                Counter(
                    label: "cloudboard_prewarm_pool_acquire_timeout_total",
                    factory: self.metricsFactory
                ).increment()
                throw CloudAppWarmupPoolError.acquireTimedOut
            case .capacityExhausted:
                Counter(
                    label: "cloudboard_prewarm_pool_capacity_exhausted_total",
                    factory: self.metricsFactory
                ).increment()
                throw CloudAppWarmupPoolError.capacityExhausted
            }
        }
        return try result.get()
    }

    /// Terminates the cb_jobhelper and waits (bounded by ``terminationTimeout``) for it to reach a
    /// terminal state, so the resource is quiesced before the pool retires it. Never throws: a slow
    /// or failed wind-down is logged and pool retire falls back to cancelling the factory task, so a
    /// caller retiring a worker after a request failure never masks the original error.
    private func terminateAndAwait(_ jobHelperClient: JobHelperClient, reason: String) async {
        Self.logger.info(
            "Releasing job helper, sending terminate signal and awaiting termination",
            metadata: ["reason": "\(reason)"]
        )
        jobHelperClient.terminate(reason: reason)
        let waitStart = ContinuousClock.now
        do {
            try await withTimeout(self.terminationTimeout) {
                try await jobHelperClient.waitForCompletion()
            }
            Self.logger.info(
                "cb_jobhelper terminated",
                metadata: ["waitDurationMs": "\((ContinuousClock.now - waitStart).inMilliseconds)"]
            )
        } catch is TimeoutError {
            Self.logger.error(
                "Timed out waiting for cb_jobhelper to terminate. Falling back to pool retire via cancellation.",
                metadata: [
                    "terminationTimeout": "\(self.terminationTimeout)",
                    "waitDurationMs": "\((ContinuousClock.now - waitStart).inMilliseconds)",
                ]
            )
        } catch is CancellationError {
            // The pool is tearing down (retirement or shutdown) rather than the wind-down failing.
            Self.logger.debug(
                "Cancelled while waiting for cb_jobhelper to terminate",
                metadata: ["waitDurationMs": "\((ContinuousClock.now - waitStart).inMilliseconds)"]
            )
        } catch {
            Self.logger.error(
                "Error while waiting for cb_jobhelper to terminate",
                metadata: [
                    "error": "\(String(reportable: error))",
                    "waitDurationMs": "\((ContinuousClock.now - waitStart).inMilliseconds)",
                ]
            )
        }
    }

    func run() async throws {
        try await withGracefulShutdownHandler {
            try await self.rawPool.run()
        } onGracefulShutdown: {
            self.rawPool.initiateShutdown()
        }
    }
}
