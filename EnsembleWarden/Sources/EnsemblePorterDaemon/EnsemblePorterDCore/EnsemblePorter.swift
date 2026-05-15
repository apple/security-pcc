// Copyright © 2025 Apple Inc. All Rights Reserved.

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
@_spi(WorkAroundResolvableCrash) @_weakLinked private import XPCDistributed

package final class EnsemblePorter: Sendable {
#if canImport(AppleComputeEnsembler)
    private let implementation: EnsemblePorterImpl<EnsembledTransponder>
#else
    private let implementation: EnsemblePorterImpl<MockEnsembleTransponder>
#endif

    package init(autoShutdownTimeout: Duration? = nil,
                 clientType: ClientType = .defaultClient) throws {
#if canImport(AppleComputeEnsembler)
        self.implementation = try .init(intraEnsembleTransponder: EnsembledTransponder(),
                                        autoShutdownTimeout: autoShutdownTimeout,
                                        clientType: clientType)
#else
        self.implementation = .init(intraEnsembleTransponder: MockEnsembleTransponder(),
                                    autoShutdownTimeout: autoShutdownTimeout,
                                    clientType: clientType)
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
            shutdownContinuation: CheckedContinuation<Void, Never>,
            autoShutdownContinuation: AsyncStream<Void>.Continuation)
        case stopped
    }

    /// Object used to transfer data between leader and followers acorss the ensemble
    internal let intraEnsembleTransponder: IntraEnsembleTransponder

    /// The type of the XPC client that we use to talk between the framework and daemon.
    private let clientType: ClientType
    package let metrics = EnsemblePorterMetrics()

    /// Our current state
    internal let state = Mutex<State>(.prewarming([]))

    /// The time after which the porter will shut itself down.
    ///
    /// Porters handles key materials. We don't want to keep them knocking around. Ideally we will shutdown as soon
    /// as we have given out all the keys. But what if warden never asks for the keys? We don't want to stay around
    /// forever. We therefore shutdown after this long.
    private let autoShutdownTimeout: Duration?

    internal let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "EnsemblePorter")


    /// Creates a new EnsemblePorter instance.
    /// - Parameters:
    ///   - intraEnsembleTransponder: The transport implementation to use to send data between SoCs in an ensemble.
    ///   - autoShutdownTimeout: The time after which we should automatically shutdown the daemon. Mainly used on followers where cb_jobhelper won't do the job management.
    ///   - clientType: The client mechanism to use
    package init(intraEnsembleTransponder: IntraEnsembleTransponder,
                 autoShutdownTimeout: Duration? = nil,
                 clientType: ClientType = .defaultClient) {
        self.intraEnsembleTransponder = intraEnsembleTransponder
        self.autoShutdownTimeout = autoShutdownTimeout
        self.clientType = clientType
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
                case .running:
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
        let followerInfo: [FollowerInfo] = try self.state.withLock { state in
            switch state {
            case .prewarming(let continuations):
                // Allow transition from prewarming directly to starting when there are no followers to prewarm
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
            self.state.withLock { $0 = .stopped }
        }

        self.logger.log("EnsemblePorter started. client_type=\(String(describing: self.clientType), privacy: .public)")
        defer {
            self.logger.log("EnsemblePorter ended")
        }
        logger.log("Validating if leader or follower")
        let isLeader: Bool
        do {
            isLeader = try await self.intraEnsembleTransponder.nodeInfo().leader
        } catch {
            self.metrics.incrementFollowerSend(success: false, error: .ensembledError)
            throw error
        }
        self.metrics.processStarts.increment()

        // Generate follower tokens and create logic
        let logic = EnsemblePorterLogic(keySafe: .init(metrics: self.metrics),
                                        intraEnsembleTransponder: self.intraEnsembleTransponder,
                                        followerInfo: followerInfo,
                                        metrics: self.metrics)

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

    /// Starts the EnsemblePorter service with a specific mach service name and logic.
    ///
    /// - Parameters:
    ///   - machServiceName: The mach service name to use for the service. This is is overridden during testing.
    ///   - logic: The EnsemblePorterLogic instance to use
    private func run(machServiceName: String, logic: EnsemblePorterLogic<IntraEnsembleTransponder>) async throws {
        let (startAutoShutdownStream, startAutoShutdownContinuation) = AsyncStream<Void>.makeStream()
        try await withThrowingTaskGroup { group in
            group.addTask {
                do {
                    switch self.clientType {
                    case .distributedActors:
                        try await self.runWithDistributedActors(machServiceName: machServiceName, logic: logic)
                    case .xpcSession:
                        try await self.runWithXPCSession(
                            machServiceName: machServiceName,
                            logic: logic,
                            autoShutdownContinuation: startAutoShutdownContinuation)
                    }
                } catch {
                    self.logger.error("EnsemblePorter threw top-level error. error=\(String(reportable: error), privacy: .public)")
                    throw error
                }
            }
            if let autoShutdownTimeout = self.autoShutdownTimeout {
                group.addTask {
                    // Have a timeout where we shutdown as a last-ditch attempt at ensuring we're not keeping keys around.
                    for await _ in startAutoShutdownStream.prefix(1) {}
                    try Task.checkCancellation()
                    self.logger.log("""
                        Starting auto-shutdown timer. \
                        timer_duration_s=\(autoShutdownTimeout.components.seconds)
                        """)
                    defer {
                        self.logger.log("auto-shutdown task complete.")
                    }
                    try await Task.sleep(for: autoShutdownTimeout)
                    self.logger.log("Auto-shutdown timer fired.")
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
                                   logic: EnsemblePorterLogic<IntraEnsembleTransponder>,
                                   autoShutdownContinuation: AsyncStream<Void>.Continuation) async throws {
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

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run()
            }
            group.addTask {
                // Wait for server to be running, then update our state
                await server.waitForRunning()

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
                            case .running:
                                waiting = []
                            case .stopped:
                                waiting = []
                            }
                            state = .running(
                                logic: logic,
                                shutdownContinuation: shutdownContinuation,
                                autoShutdownContinuation: autoShutdownContinuation)
                            return waiting
                        }
                        // Resume all waiting continuations now that state is .running
                        waitingContinuations.forEach { $0.resume() }
                    }
                }, onCancel: {
                    // Resume the continuation on cancellation to allow clean shutdown
                    self.state.withLock { state in
                        if case .running(_, let shutdownContinuation, _) = state {
                            shutdownContinuation.resume()
                            state = .stopped
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
            case .running(let logic, _, _):
                return logic
            default:
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
            case .running(let logic, _, let autoShutdownContinuation):
                autoShutdownContinuation.yield()
                return logic
            case .prewarming, .prewarmed, .notStarted, .starting, .stopped:
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

        let logic: EnsemblePorterLogic<IntraEnsembleTransponder> = try self.state.withLock { state in
            switch state {
            case .running(let logic, _, _):
                return logic
            case .prewarming, .prewarmed, .notStarted, .starting, .stopped:
                throw EnsemblePorterError.notRunning
            }
        }

        // Check if this is a leader by checking if we have followers
        guard !logic.followerInfo.isEmpty else {
            self.logger.log("No followers to shutdown")
            return
        }

        self.logger.log("Shutting down followers.")

        do {
            try await logic.shutdownAllFollowers()
            self.logger.log("EnsemblePorter teardown completed successfully")
        } catch {
            self.logger.error("""
                EnsemblePorter teardown failed. \
                error=\(String(reportable: error), privacy: .public)
                """)
            throw error
        }
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
            case .running(let logic, _, _):
                return logic
            case .prewarming, .prewarmed, .notStarted, .starting, .stopped:
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
            case .running(let logic, _, _):
                return logic
            case .prewarming, .prewarmed, .notStarted, .starting, .stopped:
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
}
