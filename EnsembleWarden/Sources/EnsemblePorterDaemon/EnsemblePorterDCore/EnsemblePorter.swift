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
//  EnsemblePorter.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 22/07/2025.

#if canImport(AppleComputeEnsembler)
@_weakLinked private import AppleComputeEnsembler
#endif
package import CryptoKit
package import EnsemblePorterCommon
private import EnsemblePorterProtos
private import EnsembleWardenServer
package import Foundation
internal import InternalSwiftProtobuf
internal import OSLog
@_spi(OSMetric) private import os
internal import Synchronization
@preconcurrency private import XPC
@_spi(WorkAroundResolvableCrash) @_weakLinked private import XPCDistributed

package final class EnsemblePorter: Sendable {
#if canImport(AppleComputeEnsembler)
    private let implementation: EnsemblePorterImpl<EnsembledTransponder>
#else
    private let implementation: EnsemblePorterImpl<MockEnsembleTransponder>
#endif

    package init(clientType: ClientType = .defaultClient,
                 maxConsecutiveHeartbeatFailures: Int = EnsemblePorterConstants.maxConsecutiveHeartbeatFailures,
                 heartbeatSendInterval: Duration = EnsemblePorterConstants.heartbeatSendInterval,
                 heartbeatSendTimeout: TimeInterval = EnsemblePorterConstants.heartbeatSendTimeout) throws {
#if canImport(AppleComputeEnsembler)
        self.implementation = try .init(intraEnsembleTransponder: EnsembledTransponder(),
                                        clientType: clientType,
                                        maxConsecutiveHeartbeatFailures: maxConsecutiveHeartbeatFailures,
                                        heartbeatSendInterval: heartbeatSendInterval,
                                        heartbeatSendTimeout: heartbeatSendTimeout)
#else
        self.implementation = .init(intraEnsembleTransponder: MockEnsembleTransponder(),
                                    clientType: clientType,
                                    maxConsecutiveHeartbeatFailures: maxConsecutiveHeartbeatFailures,
                                    heartbeatSendInterval: heartbeatSendInterval,
                                    heartbeatSendTimeout: heartbeatSendTimeout)
#endif
    }

    package func waitForRunning() async {
        await self.implementation.waitForRunning()
    }

    package func run() async throws {
        try await self.implementation.run()
    }

    package func run(machServiceName: String) async throws {
        try await self.implementation.run(machServiceName: machServiceName)
    }

    package func runAnonymous(endpointHandler: @escaping @Sendable (XPCEndpoint) -> Void) async throws {
        try await self.implementation.runAnonymous(endpointHandler: endpointHandler)
    }

    package func prewarmFollowers() async throws {
        try await self.implementation.prewarmFollowers()
    }

    package func provide(cryptoMaterial: Data, ftETKey: SymmetricKey, requestID: UUID, spanID: UInt64) async throws {
        try await self.implementation.provide(cryptoMaterial: cryptoMaterial, ftETKey: ftETKey,
                                              requestID: requestID, spanID: spanID)
    }

    package func provide(encryptedCryptoMaterial: Data, leaderPublicKey: Data, requestID: UUID, spanID: UInt64) async throws {
        try await self.implementation.provide(encryptedCryptoMaterial: encryptedCryptoMaterial,
                                              leaderPublicKey: leaderPublicKey,
                                              requestID: requestID, spanID: spanID)
    }

    package func teardownFollowers() async throws {
        try await self.implementation.teardownFollowers()
    }

    /// Call when this turn only uses the FT/ET key (no multi-turn keys from CloudBoard).
    ///
    /// Signals EnsemblePorter that this is a non-multi-turn request.
    /// The key supply is handled internally by the orchestration.
    /// For multi-turn requests, don't call this - the system will wait for CloudBoard keys.
    package func ftETOnlyTurn() async throws {
        try await self.implementation.ftETOnlyTurn()
    }

    /// Coordinates crypto material distribution with multi-turn mode decision.
    ///
    /// Runs until either:
    /// - The crypto material stream ends (multi-turn case)
    /// - Non-multi-turn mode is signaled (cancels the stream listener)
    ///
    /// - Parameters:
    ///   - derivedKey: The FT/ET key for crypto material distribution
    ///   - requestID: Request ID for tracing
    ///   - spanID: Span ID for tracing
    ///   - cryptoMaterials: Async stream of crypto material data
    package func orchestrateCryptoMaterialCoordination(
        derivedKey: SymmetricKey,
        requestID: UUID,
        spanID: UInt64,
        cryptoMaterials: AsyncStream<Data>
    ) async throws {
        try await self.implementation.orchestrateCryptoMaterialCoordination(
            derivedKey: derivedKey,
            requestID: requestID,
            spanID: spanID,
            cryptoMaterials: cryptoMaterials
        )
    }
}

package struct FollowerInfo {
    package var rank: Int
    package var instanceUUID: UUID
    package var intraEnsembleKey: SymmetricKey
    package var intraEnsemblePublicKey: Curve25519.KeyAgreement.PublicKey

    package init(rank: Int, instanceUUID: UUID, intraEnsembleKey: SymmetricKey,
                 intraEnsemblePublicKey: Curve25519.KeyAgreement.PublicKey) {
        self.rank = rank
        self.instanceUUID = instanceUUID
        self.intraEnsembleKey = intraEnsembleKey
        self.intraEnsemblePublicKey = intraEnsemblePublicKey
    }
}

/// Main EnsemblePorter service implementation.
///
/// This struct provides the core functionality for running the EnsemblePorter service,
/// supporting both XPCSession and distributed actor transport mechanisms.
package final class EnsemblePorterImpl<IntraEnsembleTransponder: EnsembleTransponder>: Sendable {

    internal enum State: Sendable {

        case prewarming([CheckedContinuation<Void, Never>])

        case prewarmed(followerInfo: [FollowerInfo], [CheckedContinuation<Void, Never>])

        /// Continuations will be resumed when the server is running.
        case notStarted(followerInfo: [FollowerInfo], [CheckedContinuation<Void, Never>])

        /// Continuations will be resumed when the server is running.
        case starting(followerInfo: [FollowerInfo], [CheckedContinuation<Void, Never>])
        /// Continuations will be resumed when the server is running.
        case running(
            logic: EnsemblePorterLogic<IntraEnsembleTransponder>,
            shutdownContinuation: CheckedContinuation<Void, Never>)
        case shuttingDown(
            logic: EnsemblePorterLogic<IntraEnsembleTransponder>,
            shutdownContinuation: CheckedContinuation<Void, Never>)
        case stopped
    }

    /// Object used to transfer data between leader and followers acorss the ensemble
    internal let intraEnsembleTransponder: IntraEnsembleTransponder

    /// The type of the XPC client that we use to talk between the framework and daemon.
    private let clientType: ClientType
    package let metrics = EnsemblePorterMetrics()

    /// Our current state
    internal let state = Mutex<State>(.prewarming([]))

    internal let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "EnsemblePorter")

    /// Unstructured heartbeat task started during prewarm and cancelled during shutdown.
    private let heartbeatTask: Mutex<Task<Void, Never>?> = .init(nil)

    /// Maximum consecutive heartbeat failures before giving up on a follower.
    private let maxConsecutiveHeartbeatFailures: Int

    /// How often the leader sends heartbeats to each follower.
    private let heartbeatSendInterval: Duration

    /// Network timeout for a single heartbeat send.
    private let heartbeatSendTimeout: TimeInterval

    /// Creates a new EnsemblePorter instance.
    /// - Parameters:
    ///   - intraEnsembleTransponder: The transport implementation to use to send data between SoCs in an ensemble.
    ///   - clientType: The client mechanism to use
    ///   - maxConsecutiveHeartbeatFailures: Maximum consecutive heartbeat failures before giving up on a follower.
    ///   - heartbeatSendInterval: How often the leader sends heartbeats to each follower.
    ///   - heartbeatSendTimeout: Network timeout for a single heartbeat send.
    package init(intraEnsembleTransponder: IntraEnsembleTransponder,
                 clientType: ClientType = .defaultClient,
                 maxConsecutiveHeartbeatFailures: Int = EnsemblePorterConstants.maxConsecutiveHeartbeatFailures,
                 heartbeatSendInterval: Duration = EnsemblePorterConstants.heartbeatSendInterval,
                 heartbeatSendTimeout: TimeInterval = EnsemblePorterConstants.heartbeatSendTimeout) {
        self.intraEnsembleTransponder = intraEnsembleTransponder
        self.clientType = clientType
        self.maxConsecutiveHeartbeatFailures = maxConsecutiveHeartbeatFailures
        self.heartbeatSendInterval = heartbeatSendInterval
        self.heartbeatSendTimeout = heartbeatSendTimeout
    }

    /// Waits for the server to be running (ready to accept connections).
    ///
    /// Used in tests since we don't have the launchd magic there.
    package func waitForRunning() async {
        await withCheckedContinuation { continuation in
            self.state.withLock { state in
                switch state {
                case .prewarming(var continuations):
                    continuations.append(continuation)
                    state = .prewarming(continuations)
                case .prewarmed(followerInfo: let followerInfo, var continuations):
                    continuations.append(continuation)
                    state = .prewarmed(followerInfo: followerInfo, continuations)
                case .notStarted(followerInfo: let followerInfo, var continuations):
                    continuations.append(continuation)
                    state = .notStarted(followerInfo: followerInfo, continuations)
                case .starting(let followerInfo, var continuations):
                    continuations.append(continuation)
                    state = .starting(followerInfo: followerInfo, continuations)
                case .running, .shuttingDown:
                    // Resume for .shuttingDown too — callers will get .notRunning when
                    // they try to use the porter, but we must not block forever if
                    // teardown races with waitForRunning.
                    continuation.resume()
                case .stopped:
                    self.logger.warning("waitForRunning() called but the server already stopped")
                    continuation.resume()
                }
            }
        }
    }

    /// Starts the EnsemblePorter service using the default mach service name.
    package func run(machServiceName: String? = nil) async throws {
        try await self.startService { logic in
            self.logger.log("Validating if leader or follower")
            let isLeader = try await self.intraEnsembleTransponder.nodeInfo().leader

            let defaultServiceName: String
            if isLeader {
                defaultServiceName = EnsemblePorterConstants.xpcKeyFetcherClientName
            } else {
                defaultServiceName = EnsemblePorterConstants.xpcKeyFetcherFollowerClientName
            }
            let serviceName = machServiceName ?? defaultServiceName
            self.logger.log("""
                Resolved mach service to use. \
                leader=\(isLeader, privacy: .public) \
                service_name=\(serviceName, privacy: .public)
                """)

            try await self.run(machServiceName: serviceName, logic: logic)
        }
    }

    /// Starts the EnsemblePorter service with a specific mach service name and logic.
    ///
    /// - Parameters:
    ///   - machServiceName: The mach service name to use for the service. This is is overridden during testing.
    ///   - logic: The EnsemblePorterLogic instance to use
    private func run(machServiceName: String, logic: EnsemblePorterLogic<IntraEnsembleTransponder>) async throws {
        try await withThrowingTaskGroup { group in
            group.addTask {
                do {
                    switch self.clientType {
                    case .distributedActors:
                        try await self.runWithDistributedActors(machServiceName: machServiceName, logic: logic)
                    case .xpcSession:
                        try await self.runWithXPCSession(
                            machServiceName: machServiceName,
                            logic: logic)
                    }
                } catch {
                    self.logger.error("EnsemblePorter threw top-level error. error=\(String(reportable: error), privacy: .public)")
                    throw error
                }
            }

            defer {
                self.logger.log("Task group cancelling")
                group.cancelAll()
                self.logger.log("Task group shutdown")
            }
            try await group.next()
        }
    }

    private func runWithDistributedActors(machServiceName: String, logic: EnsemblePorterLogic<IntraEnsembleTransponder>) async throws {
        let actorSystem = XPCSystem(EnsemblePorterConstants.xpcKeyFetcherClientName)
        let fetchActor = EnsemblePorterServerFetchActor(logic: logic, actorSystem: actorSystem)
        let provideActor = EnsemblePorterServerProvideActor(logic: logic, actorSystem: actorSystem)

        self.logger.log("""
            Initialising XPCDistributed actors. \
            mach_service_name=\(machServiceName, privacy: .public)
            """
        )
        try await actorSystem.listen(on: .machService(machServiceName)) { (local: consuming XPCSystem.Session.LocalInterface) in
            local.export(provideActor, asDefaultActorFor: $EnsemblePorterProvideActor.self)
            local.export(fetchActor, asDefaultActorFor: $EnsemblePorterFetchActor.self)
            return await local.activateThenWaitForCancellation()
        }
    }

    private func runWithXPCSession(machServiceName: String,
                                   logic: EnsemblePorterLogic<IntraEnsembleTransponder>) async throws {
        self.logger.log("""
            Initialising XPCSession server. \
            mach_service_name=\(machServiceName, privacy: .public)
            """
        )

        let handler = EnsemblePorterXPCServerHandler(logic: logic)
        let server = EnsemblePorterXPCServer(
            handler: handler,
            xpcServiceName: machServiceName,
            entitlement: EnsemblePorterConstants.provideKeysEntitlement,
            metrics: self.metrics
        )

        await self.serveXPCSession(logic: logic) {
            try await server.run()
        }
    }

    /// Starts the EnsemblePorter service using an anonymous XPC listener.
    ///
    /// The endpoint is vended via `endpointHandler` before blocking, allowing the caller to
    /// connect clients without a launchd-registered mach service name. Intended for tests.
    package func runAnonymous(endpointHandler: @escaping @Sendable (XPCEndpoint) -> Void) async throws {
        try await self.startService { logic in
            self.logger.log("Initialising anonymous XPCSession server.")

            let handler = EnsemblePorterXPCServerHandler(logic: logic)
            let server = EnsemblePorterXPCServer(
                handler: handler,
                xpcServiceName: "<anonymous>",
                entitlement: EnsemblePorterConstants.provideKeysEntitlement,
                metrics: self.metrics
            )

            await self.serveXPCSession(logic: logic) {
                try await server.runAnonymous(endpointHandler: endpointHandler)
            }
        }
    }

    /// Shared lifecycle for `run()` and `runAnonymous()`: transitions state, creates the
    /// `EnsemblePorterLogic`, and runs the provided server task.
    private func startService(
        _ serverTask: @Sendable (EnsemblePorterLogic<IntraEnsembleTransponder>) async throws -> Void
    ) async throws {
        let followerInfo: [FollowerInfo] = try self.state.withLock { state in
            switch state {
            case .prewarming(let continuations):
                state = .starting(followerInfo: [], continuations)
                return []
            case .prewarmed(let followerInfo, let continuations):
                state = .starting(followerInfo: followerInfo, continuations)
                return followerInfo
            default:
                throw EnsemblePorterError.invalidStateTransition(existing: String(describing: state), proposed: "starting")
            }
        }
        defer {
            self.cancelHeartbeat()
            self.state.withLock { $0 = .stopped }
        }

        self.logger.log("EnsemblePorter started. client_type=\(String(describing: self.clientType), privacy: .public)")
        defer {
            self.logger.log("EnsemblePorter ended")
        }

        self.metrics.processStarts.increment()

        let logic = EnsemblePorterLogic(keySafe: .init(metrics: self.metrics),
                                        intraEnsembleTransponder: self.intraEnsembleTransponder,
                                        followerInfo: followerInfo,
                                        metrics: self.metrics)

        try await serverTask(logic)
    }

    /// Shared XPC session serving logic: runs the server task alongside a state-management
    /// task that transitions to `.running` and waits for cancellation/shutdown.
    private func serveXPCSession(logic: EnsemblePorterLogic<IntraEnsembleTransponder>,
                                 serverTask: @escaping @Sendable () async throws -> Void) async {
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await serverTask()
            }
            group.addTask {
                // Wait for cancellation
                await withTaskCancellationHandler(operation: {
                    await withCheckedContinuation { shutdownContinuation in
                        // Atomically set state to .running AND get waiting continuations.
                        // This ensures state is .running before any resumed task can check it.
                        let waitingContinuations = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
                            let waiting: [CheckedContinuation<Void, Never>]
                            switch state {
                            case .prewarming(let continuations),
                            .prewarmed(_, let continuations),
                            .notStarted(_, let continuations):
                                // This can happen if waitForRunning is called before start() sets state to starting
                                waiting = continuations
                            case .starting(_, let continuations):
                                waiting = continuations
                            case .running, .shuttingDown:
                                waiting = []
                            case .stopped:
                                waiting = []
                            }
                            state = .running(
                                logic: logic,
                                shutdownContinuation: shutdownContinuation)
                            return waiting
                        }
                        // Resume all waiting continuations now that state is .running
                        waitingContinuations.forEach { $0.resume() }
                    }
                }, onCancel: {
                    // Resume the continuation on cancellation to allow clean shutdown
                    self.state.withLock { state in
                        switch state {
                        case .running(_, let shutdownContinuation),
                            .shuttingDown(_, let shutdownContinuation):
                            shutdownContinuation.resume()
                            state = .stopped
                        default:
                            break
                        }
                    }
                })
            }
        }
    }

    package func provide(cryptoMaterial: Data, ftETKey: SymmetricKey, requestID: UUID, spanID: UInt64) async throws {
        self.logger.log("""
            Waiting to be running before providing keys. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID, privacy: .public)
            """)
        await self.waitForRunning()
        let logic = try self.state.withLock { state in
            switch state {
            case .running(let logic, _):
                return logic
            case .prewarming, .prewarmed, .notStarted, .starting, .stopped, .shuttingDown:
                throw EnsemblePorterError.notRunning
            }
        }

        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            try await PrismTracing.withSpan(name: "EnsemblePorterProvide") {
                self.logger.log("""
                    Processing crypto material. \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID, privacy: .public)
                    """)

                // Decode TurnKeys from CloudBoard/TIE
                PrismTracing.logCheckpoint(name: "Decoding turn keys from CloudBoard/TIE")
                let turnKeys: Apple_Cloudos_Cloudllm_TurnKeys
                do {
                    turnKeys = try .init(serializedBytes: cryptoMaterial)
                } catch {
                    self.logger.error("""
                        Error decoding turn keys protobuf from CloudBoard/TIE. \
                        error=\(String(reportable: error), privacy: .public) \
                        request_id=\(PrismTracing.requestID, privacy: .public) \
                        span_id=\(PrismTracing.spanID, privacy: .public)
                        """)
                    throw EnsemblePorterError.invalidKeysSupplied
                }

                // Combine TurnKeys + ftETKey into EnsemblePorterCryptoMaterial for distribution
                let combinedMaterial = Apple_Cloudos_Cloudllm_EnsemblePorterCryptoMaterial.with {
                    $0.turnKeys = turnKeys
                    $0.ftEtKey = ftETKey.withUnsafeBytes { Data($0) }
                }

                try await logic.provide(additionalCryptoPayload: try combinedMaterial.serializedData())
            }
        }
    }

    package func provide(encryptedCryptoMaterial: Data, leaderPublicKey: Data, requestID: UUID, spanID: UInt64) async throws {
        let logic: EnsemblePorterLogic<IntraEnsembleTransponder> = try self.state.withLock { state in
            switch state {
            case .running(let logic, _):
                return logic
            case .prewarming, .prewarmed, .notStarted, .starting, .stopped, .shuttingDown:
                throw EnsemblePorterError.notRunning
            }
        }
        self.logger.log("""
            Processing encrypted crypto material. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID, privacy: .public)
            """)
        _ = try await logic.provide(encryptedCryptoMaterial: encryptedCryptoMaterial, leaderPublicKey: leaderPublicKey)
    }

    package func teardownFollowers() async throws {
        self.logger.log("EnsemblePorter teardown starting")

        var waitersToResume: [CheckedContinuation<Void, Never>] = []
        var phase: EnsemblePorterMetrics.ShutdownFollowersPhase = .requestComplete
        let logic: EnsemblePorterLogic<IntraEnsembleTransponder>? = self.state.withLock { state in
            switch state {
            case .running(let logic, let continuation):
                state = .shuttingDown(logic: logic, shutdownContinuation: continuation)
                phase = .requestComplete
                return logic
            case .prewarmed(let followerInfo, let waiters),
                 .notStarted(let followerInfo, let waiters),
                 .starting(let followerInfo, let waiters):
                waitersToResume = waiters
                state = .stopped
                phase = .preRequest
                return EnsemblePorterLogic(
                    keySafe: .init(metrics: self.metrics),
                    intraEnsembleTransponder: self.intraEnsembleTransponder,
                    followerInfo: followerInfo,
                    metrics: self.metrics)
            case .prewarming(let waiters):
                // Prewarm still in flight: we don't yet know which followers exist.
                waitersToResume = waiters
                state = .stopped
                return nil
            case .shuttingDown, .stopped:
                return nil
            }
        }
        for waiter in waitersToResume {
            waiter.resume()
        }

        guard let logic, !logic.followerInfo.isEmpty else {
            self.logger.log("No followers to shutdown")
            return
        }

        self.cancelHeartbeat()
        self.logger.log("Shutting down followers.")

        let start = ContinuousClock.now
        do {
            // Teardown runs outside any request context (e.g. from CloudBoardSupportApp.teardown()
            // or after a .prewarmed → .stopped transition). Establish a sentinel Prism context with
            // an all-zero requestID so the inner shutdown path can read PrismTracing.requestID/spanID
            // without tripping its "no requestID for activityID" assertion.
            try await PrismTracing.withResumed(requestID: Self.noRequestSentinelID) {
                try await logic.shutdownAllFollowers()
            }
            self.metrics.recordShutdownFollowers(
                phase: phase,
                success: true,
                durationSeconds: Self.elapsedSeconds(since: start))
            self.logger.log("EnsemblePorter teardown completed successfully")
        } catch {
            self.metrics.recordShutdownFollowers(
                phase: phase,
                success: false,
                error: error,
                durationSeconds: Self.elapsedSeconds(since: start))
            self.logger.error("""
                EnsemblePorter teardown failed. \
                error=\(String(reportable: error), privacy: .public)
                """)
            throw error
        }
    }

    private static func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Sentinel requestID used when EnsemblePorter performs work outside any per-request context
    /// (prewarm, teardown). Surfacing all-zero in traces makes these calls easy to identify versus
    /// real per-request work.
    package static var noRequestSentinelID: UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    /// Call when this turn only uses the FT/ET key (no multi-turn keys from CloudBoard).
    ///
    /// Signals EnsemblePorter that this is a non-multi-turn request.
    /// The key supply is handled internally by the orchestration.
    /// For multi-turn requests, don't call this - the system will wait for CloudBoard keys.
    package func ftETOnlyTurn() async throws {
        await self.waitForRunning()
        let logic: EnsemblePorterLogic<IntraEnsembleTransponder> = try self.state.withLock { state in
            switch state {
            case .running(let logic, _):
                return logic
            case .prewarming, .prewarmed, .notStarted, .starting, .stopped, .shuttingDown:
                throw EnsemblePorterError.notRunning
            }
        }
        await logic.ftETOnlyTurn()
    }

    /// Coordinates crypto material distribution with multi-turn mode decision.
    ///
    /// Runs until either:
    /// - The crypto material stream ends (multi-turn case)
    /// - Non-multi-turn mode is signaled (cancels the stream listener)
    ///
    /// - Parameters:
    ///   - derivedKey: The FT/ET key for crypto material distribution
    ///   - requestID: Request ID for tracing
    ///   - spanID: Span ID for tracing
    ///   - cryptoMaterials: Async stream of crypto material data
    package func orchestrateCryptoMaterialCoordination(
        derivedKey: SymmetricKey,
        requestID: UUID,
        spanID: UInt64,
        cryptoMaterials: AsyncStream<Data>
    ) async throws {
        await self.waitForRunning()
        let logic: EnsemblePorterLogic<IntraEnsembleTransponder> = try self.state.withLock { state in
            switch state {
            case .running(let logic, _):
                return logic
            case .prewarming, .prewarmed, .notStarted, .starting, .stopped, .shuttingDown:
                throw EnsemblePorterError.notRunning
            }
        }
        try await logic.orchestrateCryptoMaterialCoordination(
            derivedKey: derivedKey,
            requestID: requestID,
            spanID: spanID,
            cryptoMaterials: cryptoMaterials
        )
    }

    // MARK: - Heartbeat

    /// Starts the heartbeat task that runs until the porter shuts down.
    ///
    /// Called at the end of `prewarmFollowers()` so heartbeats begin immediately
    /// after follower instances are created, avoiding timeout during the gap
    /// between prewarm and `run()`.
    internal func startHeartbeat(followerInfo: [FollowerInfo]) {
        guard !followerInfo.isEmpty else { return }
        let task = Task {
            self.logger.log("Heartbeat task started. follower_count=\(followerInfo.count, privacy: .public)")
            defer { self.logger.log("Heartbeat task ended") }
            await withTaskGroup(of: Void.self) { group in
                for follower in followerInfo {
                    group.addTask {
                        var consecutiveFailures = 0
                        while !Task.isCancelled {
                            let roundStart = ContinuousClock.now
                            do {
                                try await self.sendHeartbeat(
                                    to: follower,
                                    priorConsecutiveFailures: consecutiveFailures)
                                consecutiveFailures = 0
                            } catch let error as EnsemblePorterError where error == .instanceNotFound {
                                if self.isShuttingDown || Task.isCancelled {
                                    self.logger.warning("""
                                        Heartbeat rejected during shutdown - ignoring. \
                                        rank=\(follower.rank, privacy: .public)
                                        """)
                                    break
                                }
                                // The controller explicitly rejected the heartbeat — the follower
                                // porter instance is gone.  Exit immediately so CB brings up a new
                                // support app.
                                self.logger.error("""
                                    Heartbeat rejected by controller - instance not found. \
                                    Shutting down sibling followers, then exiting. \
                                    rank=\(follower.rank, privacy: .public)
                                    """)
                                // Best-effort: free sibling followers' slots immediately
                                // instead of waiting for each follower's controller heartbeat-
                                // timeout watchdog. Stops the failure cascading into
                                // eviction-and-crash for unrelated leaders. (rdar://179488696)
                                await self.shutdownOtherFollowers(
                                    except: follower.rank, in: followerInfo)
                                self.metrics.incrementHeartbeatExit(reason: .instanceNotFound)
                                self.logger.error("""
                                    Exiting ensembleporterd. \
                                    reason=instance_not_found \
                                    rank=\(follower.rank, privacy: .public)
                                    """)
                                exit(EX_UNAVAILABLE)
                            } catch {
                                consecutiveFailures += 1
                                self.logger.warning("""
                                    Heartbeat failed. \
                                    rank=\(follower.rank, privacy: .public) \
                                    consecutive_failures=\(consecutiveFailures, privacy: .public) \
                                    error=\(String(reportable: error), privacy: .public)
                                    """)
                                if consecutiveFailures >= self.maxConsecutiveHeartbeatFailures {
                                    if self.isShuttingDown || Task.isCancelled {
                                        self.logger.warning("""
                                            Heartbeat failed during shutdown - ignoring. \
                                            rank=\(follower.rank, privacy: .public) \
                                            consecutive_failures=\(consecutiveFailures, privacy: .public)
                                            """)
                                        break
                                    }
                                    self.logger.error("""
                                        Heartbeat failed too many consecutive times. \
                                        Shutting down sibling followers, then exiting. \
                                        rank=\(follower.rank, privacy: .public) \
                                        max_consecutive_failures=\(self.maxConsecutiveHeartbeatFailures, privacy: .public)
                                        """)
                                    // Best-effort: free sibling followers' slots immediately
                                    // instead of waiting for each follower's controller
                                    // heartbeat-timeout watchdog. (rdar://179488696)
                                    await self.shutdownOtherFollowers(
                                        except: follower.rank, in: followerInfo)
                                    // Spoken to the CloudBoard team. Exiting is the recommended approach.
                                    // By exiting CB will inform tie-cloud-app that the support app is unhealthy
                                    // and ask it what to do.
                                    // rdar://179642532
                                    self.metrics.incrementHeartbeatExit(reason: .maxConsecutiveFailures)
                                    self.logger.error("""
                                        Exiting ensembleporterd. \
                                        reason=max_consecutive_failures \
                                        rank=\(follower.rank, privacy: .public) \
                                        consecutive_failures=\(consecutiveFailures, privacy: .public)
                                        """)
                                    exit(EX_UNAVAILABLE)
                                }
                            }
                            let elapsed = ContinuousClock.now - roundStart
                            let remaining = self.heartbeatSendInterval - elapsed
                            if remaining > .zero {
                                try? await Task.sleep(for: remaining)
                            }
                        }
                    }
                }
            }
        }
        self.heartbeatTask.withLock { $0 = task }
    }

    /// Cancels the heartbeat task if it is running.
    private func cancelHeartbeat() {
        self.heartbeatTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    /// Returns `true` when the porter has entered the `.shuttingDown` or `.stopped` state.
    ///
    /// Used by the heartbeat loop to distinguish "follower removed because we are
    /// tearing down" from "follower unexpectedly vanished."  We also check `.stopped`
    /// because `startService()`'s defer block calls `cancelHeartbeat()` and then
    /// transitions directly to `.stopped`, racing with in-flight heartbeat iterations.
    private var isShuttingDown: Bool {
        self.state.withLock {
            switch $0 {
            case .shuttingDown, .stopped:
                return true
            default:
                return false
            }
        }
    }

    /// Sends a heartbeat message to a single follower using the transponder directly.
    ///
    /// Used to keep follower instances alive for the entire request lifetime.
    /// Records round-trip duration metrics for each heartbeat attempt.
    /// - Parameter priorConsecutiveFailures: Streak length *before* this attempt. Used to
    ///   tag the per-attempt metric with the bucketed `consecutive_failures` dimension —
    ///   on failure the recorded streak is `priorConsecutiveFailures + 1`; on success the
    ///   streak resets to `0` for the recorded sample.
    /// - Throws: If the heartbeat send fails or the follower reports the instance is unknown.
    internal func sendHeartbeat(to follower: FollowerInfo, priorConsecutiveFailures: Int = 0) async throws {
        let heartbeatMessage = Protos.PorterMessage.with {
            $0.messageType = .heartbeat(.with {
                $0.instanceUuid = Data(uuid: follower.instanceUUID)
            })
        }
        let start = ContinuousClock.now
        do {
            let responseData = try await self.intraEnsembleTransponder.sendData(
                appID: EnsemblePorterConstants.ensembledAppID,
                data: heartbeatMessage.serializedData(),
                destination: follower.rank,
                timeout: self.heartbeatSendTimeout,
                // Heartbeats run in a detached background task with no active request span, so we
                // don't attach a tracing context — otherwise every ping would manufacture a
                // spurious requestID/span for ensembled to record.
                includeTracingContext: false)
            let elapsed = ContinuousClock.now - start

            // Check if the controller reported the instance as unknown/removed
            let response = try Protos.HeartbeatResponse(serializedBytes: responseData)
            guard response.success else {
                self.metrics.recordHeartbeatRoundTrip(
                    rank: follower.rank,
                    success: false,
                    consecutiveFailures: priorConsecutiveFailures + 1,
                    durationSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                self.logger.warning("""
                    Heartbeat rejected by controller - instance not found. \
                    rank=\(follower.rank, privacy: .public) \
                    instance_uuid=\(follower.instanceUUID, privacy: .public)
                    """)
                throw EnsemblePorterError.instanceNotFound
            }

            self.metrics.recordHeartbeatRoundTrip(
                rank: follower.rank,
                success: true,
                consecutiveFailures: 0,
                durationSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        } catch {
            self.logger.error("""
                Error sending heartbeat. \
                error=\(String(reportable: error), privacy: .public) \
                rank=\(follower.rank, privacy: .public) \
                instance_uuid=\(follower.instanceUUID, privacy: .public)
                """)
            let elapsed = ContinuousClock.now - start
            self.metrics.recordHeartbeatRoundTrip(
                rank: follower.rank,
                success: false,
                consecutiveFailures: priorConsecutiveFailures + 1,
                durationSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            throw error
        }
    }

    /// Sends a best-effort shutdown to every follower except the one whose heartbeat just failed.
    ///
    /// Without this, the failed-heartbeat path leaves the leader's other follower porter slots
    /// occupied until each follower's controller heartbeat-timeout watchdog fires. By sending an
    /// explicit shutdown we free those slots immediately, which stops one heartbeat failure from
    /// cascading into eviction-and-crash for unrelated concurrent leaders sharing the same
    /// follower pool. (rdar://179488696)
    ///
    /// Failures here are expected and ignored — at the point this is invoked we're already
    /// in a failure path. Successes/failures are reported via `heartbeatFailureShutdown*` metrics.
    internal func shutdownOtherFollowers(
        except failedRank: Int,
        in followers: [FollowerInfo]
    ) async {
        let start = ContinuousClock.now
        // Each task returns nil on success or the failing error; we keep the first error
        // for the aggregate metric. The function itself never throws — sibling shutdown is
        // best-effort (we are already on the failure path).
        let firstError: Error? = await withTaskGroup(of: Error?.self) { group in
            for follower in followers where follower.rank != failedRank {
                group.addTask {
                    let shutdownMessage = Protos.PorterMessage.with {
                        $0.messageType = .shutdown(.with {
                            $0.instanceUuid = Data(uuid: follower.instanceUUID)
                        })
                    }
                    let taskStart = ContinuousClock.now
                    do {
                        let serialized = try shutdownMessage.serializedData()
                        _ = try await self.intraEnsembleTransponder.sendData(
                            appID: EnsemblePorterConstants.ensembledAppID,
                            data: serialized,
                            destination: follower.rank,
                            timeout: self.heartbeatSendTimeout)
                        let elapsed = ContinuousClock.now - taskStart
                        self.metrics.heartbeatFailureShutdownDurationSuccess.set(
                            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        )
                        self.logger.log("""
                            Sibling-follower shutdown sent after heartbeat failure. \
                            rank=\(follower.rank, privacy: .public) \
                            instance_uuid=\(follower.instanceUUID, privacy: .public)
                            """)
                        return nil
                    } catch {
                        let elapsed = ContinuousClock.now - taskStart
                        self.metrics.heartbeatFailureShutdownDurationFailure.set(
                            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        )
                        self.logger.warning("""
                            Sibling-follower shutdown failed after heartbeat failure. \
                            rank=\(follower.rank, privacy: .public) \
                            error=\(String(reportable: error), privacy: .public)
                            """)
                        return error
                    }
                }
            }
            var captured: Error? = nil
            for await taskError in group {
                if captured == nil, let taskError {
                    captured = taskError
                }
            }
            return captured
        }
        self.metrics.recordShutdownFollowers(
            phase: .heartbeatFailure,
            success: firstError == nil,
            error: firstError,
            durationSeconds: Self.elapsedSeconds(since: start))
    }

}
