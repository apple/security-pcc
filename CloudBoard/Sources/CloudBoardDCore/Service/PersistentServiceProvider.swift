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

import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardJobHelperAPI
import CloudBoardLogging
import Foundation
import InternalGRPC
import InternalSwiftProtobuf
import os
import PersistentHelperInstance
import Synchronization

private enum PersistentServiceProviderError: ReportableError, CustomStringConvertible {
    case duplicateSetup
    case chunkBeforeSetup
    case chunkBeforeSetupSucceeded
    case invalidStateTransition(from: PersistentServiceProvider.InputProcessingState, event: StaticString)
    case invalidAction(inState: PersistentServiceProvider.InputProcessingState, event: StaticString)
    case missingAnnounceConnection
    case duplicateAnnounceConnection

    var publicDescription: String {
        switch self {
        case .duplicateSetup: "Received duplicate Setup message on this stream"
        case .chunkBeforeSetup: "Received requestChunk before setup is complete"
        case .invalidStateTransition(let from, let event):
            "Invalid state transition from \(from) on event \(event)"
        case .invalidAction(let inState, let event):
            "Invalid action \(event) when in state \(inState)"
        case .chunkBeforeSetupSucceeded:
            "Received requestChunk before setup acked as succeeded"
        case .missingAnnounceConnection:
            "Received message before AnnounceConnection"
        case .duplicateAnnounceConnection:
            "Received duplicate AnnounceConnection message"
        }
    }

    var description: String {
        return self.publicDescription
    }
}

/// Handles InvokePersistentService RPCs.
///
/// Unlike CloudBoardProvider, this provider does not enforce concurrent request limits.
/// It does respect draining for graceful shutdown.
final class PersistentServiceProvider: Com_Apple_Cloudboard_Api_V1_PersistentServiceAsyncProvider, Sendable {
    static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentServiceProvider"
    )

    private let drainState = Mutex(DrainState())
    private let helperInstanceProvider: PersistentHelperInstanceProvider
    private let attestationProvider: AttestationProvider
    private let serviceId: String
    /// Bounds for jittering `connectionShouldBeRecreated` notifications so a fleet-synchronized
    /// attestation-key roll doesn't trigger every client's reconnection at once. Defaults to
    /// disabled (`maxJitter == .zero`, i.e. notify immediately); enabled via configuration.
    private let drainJitterConfig: DrainJitterConfig
    /// The backing controller's mach service name, populated once the controller registers.
    /// `nil` until then; connections that arrive before registration are rejected fast.
    private let registeredMachServiceName = Mutex<String?>(nil)

    typealias ResponseStream =
        GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse>

    private struct DrainState {
        var activeConnections: Int = 0
        var draining: Bool = false
        var drainCompleteContinuation: CheckedContinuation<Void, Never>?
        var activeStreams: [UUID: ResponseStream] = [:]

        mutating func requestStarted(id: UUID, stream: ResponseStream) throws {
            if self.draining {
                PersistentServiceProvider.logger.warning(
                    "Received invokePersistentService gRPC message; but draining"
                )
                throw GRPCTransformableError.drainingRequests
            }
            self.activeConnections += 1
            self.activeStreams[id] = stream
        }

        mutating func requestFinished(id: UUID) {
            self.activeConnections -= 1
            self.activeStreams.removeValue(forKey: id)
            if self.draining, self.activeConnections == 0,
               let continuation = self.drainCompleteContinuation {
                self.drainCompleteContinuation = nil
                continuation.resume()
            }
        }
    }

    var interceptors: Com_Apple_Cloudboard_Api_V1_PersistentServiceServerInterceptorFactoryProtocol? {
        nil
    }

    init(
        helperInstanceProvider: PersistentHelperInstanceProvider,
        attestationProvider: AttestationProvider,
        serviceId: String,
        drainJitterConfig: DrainJitterConfig
    ) {
        self.helperInstanceProvider = helperInstanceProvider
        self.attestationProvider = attestationProvider
        self.serviceId = serviceId
        self.drainJitterConfig = drainJitterConfig
    }

    /// Called when the backing controller registers, supplying the mach service name to route to.
    /// Until this is set, incoming connections are rejected with `persistentServiceNotReady`.
    func markControllerRegistered(machServiceName: String) {
        self.registeredMachServiceName.withLock { $0 = machServiceName }
    }

    /// Simple state machine to handle transitions
    fileprivate enum InputProcessingState: CustomStringConvertible {
        case preAnnounce
        case preSetup(connectionID: String)
        case connecting(connectionID: String, PersistentHelperInstance)
        case connected(connectionID: String, PersistentHelperInstance)
        case disconnected(connectionID: String)

        var description: String {
            switch self {
            case .preAnnounce: "preAnnounce"
            case .preSetup: "preSetup"
            case .connecting: "connecting"
            case .connected: "connected"
            case .disconnected: "disconnected"
            }
        }

        var connectionID: String {
            switch self {
            case .preAnnounce: "<unknown>"
            case .preSetup(connectionID: let id): id
            case .connecting(connectionID: let id, _): id
            case .connected(connectionID: let id, _): id
            case .disconnected(connectionID: let id): id
            }
        }

        // in the event of uncontrolled failure we may need to clean the helepr up
        var helperForCleanup: PersistentHelperInstance? {
            switch self {
            case .preAnnounce: return nil
            case .preSetup: return nil
            case .connecting(_, let helper): return helper
            case .connected(_, let helper): return helper
            case .disconnected: return nil
            }
        }
    }

    typealias SetupInfo = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest.Setup

    private static func requireConnectionID(
        _ state: OSAllocatedUnfairLock<InputProcessingState>
    ) throws -> String {
        let currentState = state.withLock { $0 }
        switch currentState {
        case .preAnnounce:
            throw GRPCTransformableError.protocolError(
                PersistentServiceProviderError.missingAnnounceConnection
            )
        // It is a requirement that all states past this point maintain the connectionID
        default:
            return currentState.connectionID
        }
    }

    private enum PersistentServiceTaskResult: String, CustomStringConvertible {
        var description: String {
            rawValue
        }

        case requestInputCompleted
        case responsePumpCompleted
        case keepAliveCompleted
        case helperCompleted
        case attestationSubscriptionCompleted
    }

    func invokePersistentService(
        requestStream: GRPCAsyncRequestStream<Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest>,
        responseStream: GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse>,
        context _: GRPCAsyncServerCallContext
    ) async throws {
        // Fail fast if the backing controller has not registered yet. Without this the
        // connection would otherwise spawn a helper and then block indefinitely waiting
        // for the mach service name, surfacing only as a confusing idle timeout (or no
        // error at all if the client gives up first).
        guard self.registeredMachServiceName.withLock({ $0 }) != nil else {
            Self.logger.error(
                "Rejecting persistent-service connection for '\(self.serviceId, privacy: .public)': backing controller has not registered yet"
            )
            throw GRPCTransformableError.persistentServiceNotReady(serviceID: self.serviceId)
        }

        let connectionUUID = UUID()
        try self.drainState.withLock { try $0.requestStarted(id: connectionUUID, stream: responseStream) }

        // can't be a Mutex, captured in the various tasks below
        let state: OSAllocatedUnfairLock<InputProcessingState> = .init(initialState: .preAnnounce)

        defer {
            self.drainState.withLock { $0.requestFinished(id: connectionUUID) }
            if let helper = state.withLock({ $0.helperForCleanup }) {
                // The helper might keep alive a whole process, we must take action to clean it up
                // even at the cost of a detached task if need be.
                // removeInstance() both removes from the registry and triggers teardown.
                let helperID = helper.id
                if Task.isCancelled {
                    Self.logger
                        .log(
                            "InvokePersistentService for \(self.serviceName) leaked the helper under cancellation - spawning detached task to terminate it"
                        )
                    Task.detached { [helperInstanceProvider = self.helperInstanceProvider] in
                        await helperInstanceProvider.removeInstance(uuid: helperID)
                    }
                } else {
                    Self.logger.log("InvokePersistentService for \(self.serviceName) leaked the helper - killing it")
                    Task { [helperInstanceProvider = self.helperInstanceProvider] in
                        await helperInstanceProvider.removeInstance(uuid: helperID)
                    }
                }
            }
        }

        Self.logger.log("InvokePersistentService called for \(self.serviceName)")

        let connectionDelegate = PersistentConnectionDelegate()
        let idleTimeout = IdleTimeout<ContinuousClock>(
            timeout: .seconds(60),
            taskName: "invokePersistentService",
            taskID: UUID().uuidString
        )
        // succcds at the point the connection is being setup, not that it has finished doing so
        let connectingPromise = Promise<(setup: SetupInfo, helper: PersistentHelperInstance), Error>(
            autoFailureIfUnfulfilled: CancellationError()
        )

        try await withThrowingTaskGroup(of: PersistentServiceTaskResult.self) { group in
            // Idle timeout task — runs for the full duration of the RPC
            group.addTask {
                try await idleTimeout.run()
            }

            // Keep-alive sender task — sends periodic keep-alive messages
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(10))
                    var response = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse()
                    response.type = .keepAlive(.init())
                    try await responseStream.send(response)
                }
                return .keepAliveCompleted
            }

            // Request stream processing — handles this during all states
            func processMessage(
                _ message: Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest
            ) async throws {
                // We do not allow unknown traffic to keep us alive,
                // if this is all we see the connection should timeout.
                guard let type = message.type else {
                    let connID = state.withLock { $0.connectionID }
                    Self.logger
                        .error(
                            "connectionID: \(connID, privacy: .public) Received message with no type - ignoring"
                        )
                    return
                }

                idleTimeout.registerActivity()

                switch type {
                case .announceConnection(let announce):
                    try state.withLock { state in
                        guard case .preAnnounce = state else {
                            throw GRPCTransformableError.protocolError(
                                PersistentServiceProviderError.duplicateAnnounceConnection
                            )
                        }
                        state = .preSetup(connectionID: announce.connectionID)
                    }

                case .attestationQuery:
                    // You can ask this in any state
                    let connID = try Self.requireConnectionID(state)
                    do {
                        let attestationSet = try await attestationProvider.currentAttestationSet()
                        let currentAttestation = attestationSet.currentAttestation
                        var suggested = Com_Apple_Cloudboard_Api_V1_SuggestedAttestation()
                        suggested.keyID = currentAttestation.keyID
                        suggested.attestationBundle = currentAttestation.attestationBundle
                        suggested.expiresAfter = .init(
                            roundingTimeIntervalSince1970: currentAttestation.expiry
                                .timeIntervalSince1970
                        )
                        var lifecycle = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse
                            .ConnectionLifecycleMessage()
                        lifecycle.eventType = .responseToQuery
                        lifecycle.suggestedAttestation = suggested
                        var response = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse()
                        response.type = .connectionLifecycle(lifecycle)
                        try await responseStream.send(response)
                    } catch {
                        Self.logger.error(
                            "connectionID: \(connID, privacy: .public) failed to handle attestation query: \(String(unredacted: error), privacy: .public)"
                        )
                    }

                case .keepAlive:
                    // We use the keep alive just as a means to keep the connection alive
                    // The helper doesn't need it (if it needed some keep alive for health reasons that
                    // should be in the encrypted stream).
                    ()

                case .setup(let setup):
                    let connID = try Self.requireConnectionID(state)
                    try state.withLock { state in
                        switch state {
                        case .preAnnounce:
                            // requireConnectionID already guards this
                            preconditionFailure("unreachable: requireConnectionID should have thrown")
                        case .preSetup:
                            () // fine to proceed
                        case .connecting:
                            Self.logger
                                .error(
                                    "connectionID: \(connID, privacy: .public) received duplicate Setup while already connecting"
                                )
                            throw GRPCTransformableError.protocolError(
                                PersistentServiceProviderError.duplicateSetup
                            )
                        case .connected:
                            Self.logger
                                .error(
                                    "connectionID: \(connID, privacy: .public) received duplicate Setup while already connected"
                                )
                            throw GRPCTransformableError.protocolError(
                                PersistentServiceProviderError.duplicateSetup
                            )
                        case .disconnected:
                            Self.logger
                                .error(
                                    "connectionID: \(connID, privacy: .public) received Setup but already disconnected"
                                )
                            throw PersistentServiceProviderError.invalidStateTransition(
                                from: state, event: "setup"
                            )
                        }
                    }

                    Self.logger.info("Establishing connection for \(connID, privacy: .public)")
                    let helper = try await self.helperInstanceProvider.createInstance(
                        keyID: setup.decryptionKey.keyID,
                        delegate: connectionDelegate
                    )
                    state.withLock { $0 = .connecting(connectionID: connID, helper) }
                    // kick things off else where - this can only happen once thanks to the lock
                    connectingPromise.succeed(with: (setup, helper))

                case .requestChunk(let chunk):
                    // concious decision currently to have *any* error at this level be entirely terminal
                    // for the stream. If you lose a message you can't recover the AEAD stream so it's
                    // better to drop it all anyway
                    let connID = try Self.requireConnectionID(state)
                    let helper = try state.withLock { state in
                        switch state {
                        case .preAnnounce, .preSetup:
                            throw PersistentServiceProviderError.chunkBeforeSetup
                        case .connecting:
                            Self.logger
                                .error(
                                    "Attempt to send a chunk on \(connID, privacy: .public) but before setup was acked"
                                )
                            // The defer checking state will catch this and cleanup the helper
                            throw PersistentServiceProviderError.chunkBeforeSetupSucceeded
                        case .connected(_, let helper):
                            return helper
                        case .disconnected:
                            throw PersistentServiceProviderError.invalidAction(
                                inState: state, event: "requestChunk"
                            )
                        }
                    }
                    do {
                        try await helper.sendEncryptedMessage(
                            .encryptedChunk(chunk.encryptedPayload, isFinal: chunk.isFinal)
                        )
                    } catch {
                        Self.logger
                            .info(
                                "connectionID: \(connID, privacy: .public) failed on receiving encrypted chunk: \(String(unredacted: error), privacy: .public)"
                            )
                        throw error
                    }

                case .terminate(let terminate):
                    let connID = state.withLock { $0.connectionID }
                    let helperForCleanp: PersistentHelperInstance? = state.withLock { state in
                        switch state {
                        case .preAnnounce, .preSetup:
                            // not much to do
                            Self.logger
                                .info("received terminate from client without getting setup: \(terminate.reason)")
                            if case .preSetup(connectionID: let id) = state {
                                state = .disconnected(connectionID: id)
                            }
                            return nil
                        case .connecting(connectionID: let connectionID, let helper):
                            Self.logger
                                .info(
                                    "connectionID: \(connectionID, privacy: .public) received terminate from client during setup phase: \(terminate.reason)"
                                )
                            state = .disconnected(connectionID: connectionID)
                            return helper
                        case .connected(connectionID: let connectionID, let helper):
                            Self.logger
                                .info(
                                    "connectionID: \(connectionID, privacy: .public) received terminate from client: \(terminate.reason)"
                                )
                            state = .disconnected(connectionID: connectionID)
                            return helper
                        case .disconnected:
                            Self.logger
                                .info(
                                    "connectionID: \(connID, privacy: .public) received terminate from client already disconnected: \(terminate.reason)"
                                )
                            return nil
                        }
                    }
                    if let helperForCleanp {
                        await helperForCleanp.triggerTeardown()
                    }
                    // we expect the caller to end the gRPC
                }
            }

            group.addTask {
                for try await message in requestStream {
                    try await processMessage(message)
                }
                return .requestInputCompleted
            }

            // run the helper instance once it is ready
            group.addTask { [helperInstanceProvider = self.helperInstanceProvider] in
                let (setup, helper) = try await Future(connectingPromise).valueWithCancellation
                let connID = try Self.requireConnectionID(state)
                // start a nested group to manage the helper
                do {
                    try await withThrowingTaskGroup(of: Void.self) { instanceGroup in
                        instanceGroup.addTask {
                            do {
                                try await helper.run()
                            } catch {
                                // helper.run() threw (e.g. monitoring stopped unexpectedly).
                                // Trigger teardown so awaitTeardownTriggerAndComplete() can
                                // proceed with XPC cleanup instead of blocking forever.
                                await helper.triggerTeardown(error: error)
                                throw error
                            }
                            // helper.run() returned normally (helper process terminated).
                            // Trigger teardown so awaitTeardownTriggerAndComplete() can
                            // proceed — without this, waitForAll() deadlocks because
                            // the teardown future is never fulfilled.
                            await helper.triggerTeardown()
                        }
                        // Await teardown trigger so that when triggerTeardown() is called
                        // (e.g. from the defer or terminate handler), the actual state machine
                        // teardown executes (XPC teardown command + launchd job removal).
                        instanceGroup.addTask {
                            await helper.awaitTeardownTriggerAndComplete()
                        }
                        /// then deal with getting the helper ready
                        do {
                            try await helper.waitForConnectComplete()
                        } catch {
                            Self.logger.error(
                                "connectionID: \(connID, privacy: .public) failed to connect to persistent helper: \(String(unredacted: error), privacy: .public)"
                            )
                            throw error
                        }

                        do {
                            guard let machServiceName = self.registeredMachServiceName.withLock({ $0 }) else {
                                throw GRPCTransformableError.persistentServiceNotReady(serviceID: self.serviceId)
                            }
                            try await helper.initialize(PersistentHelperInitParams(
                                keyID: setup.decryptionKey.keyID,
                                encryptedKey: setup.decryptionKey.encryptedPayload,
                                targetEndpoint: machServiceName
                            ))
                        } catch {
                            Self.logger.error(
                                "connectionID: \(connID, privacy: .public) failed to initialize persistent helper: \(String(unredacted: error), privacy: .public)"
                            )
                            throw error
                        }
                        // Once the initialized message makes it through on the reponse stream we are ready
                        // The state transition deliberately happens there so we are ready _before_ we tell the
                        // caller we are
                        return try await instanceGroup.waitForAll()
                    }
                } catch {
                    await helperInstanceProvider.removeInstance(uuid: helper.id)
                    state.withLock { $0 = .disconnected(connectionID: $0.connectionID) }
                    throw error
                }
                await helperInstanceProvider.removeInstance(uuid: helper.id)
                state.withLock { $0 = .disconnected(connectionID: $0.connectionID) }
                return .helperCompleted
            }

            // Response pump task — forwards helper responses to gRPC
            group.addTask {
                // no point pumping till we know there could be responses, by then we know the connectionID
                let _ = try await Future(connectingPromise).valueWithCancellation
                let connID = try Self.requireConnectionID(state)
                for await response in connectionDelegate.helperResponses {
                    idleTimeout.registerActivity()
                    // At this stage we must have gone through setup

                    switch response {
                    case .responseChunk(let data, isFinal: let isFinal):
                        var grpcResponse = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse()
                        var chunk = Proto_Ropes_Common_Chunk()
                        chunk.encryptedPayload = data
                        chunk.isFinal = isFinal
                        grpcResponse.type = .responseChunk(chunk)
                        try await responseStream.send(grpcResponse)

                    case .helperEOF:
                        Self.logger
                            .info("Persistent helper for connectionID: \(connID, privacy: .public) sent EOF")
                        // we expect the helperResponses stream to then end cleanly
                        // so don't do anything special

                    case .failureReport(let reason):
                        Self.logger
                            .info(
                                "Persistent helper for connectionID: \(connID, privacy: .public) reported a failure \(reason.publicDescription, privacy: .public)"
                            )
                        throw reason

                    case .initialized:
                        try state.withLock { state in
                            switch state {
                            case .preAnnounce, .preSetup:
                                // something went horribly wrong
                                throw PersistentHelperInstanceError.illegalStateAfterClientIsConnected(
                                    "helper delivered initialized message but we thought still in preSetup"
                                )
                            case .connecting(connectionID: let connectionID, let helper):
                                state = .connected(connectionID: connectionID, helper)
                            case .connected:
                                Self.logger
                                    .error(
                                        "connectionID: \(connID) helper indicated it was initialized more than once"
                                    )
                                // The helper should only deliver one of these so this is still a failure
                                throw PersistentHelperInstanceError.illegalStateAfterClientIsConnected(
                                    "helper delivered multiple initialized messages"
                                )
                            case .disconnected:
                                // likely somethign else went wrong and things would be failing elsewhere
                                // but just in case
                                Self.logger
                                    .error(
                                        "connectionID: \(connID) helper indicated it was initialized but we're already disconnected"
                                    )
                                throw PersistentHelperInstanceError.helperUnavailable(
                                    "Disconnected between setup and setupAck"
                                )
                            }
                        }
                        var response = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse()
                        response.type = .setupAck(.init())
                        try await responseStream.send(response)

                    case .drainComplete:
                        // Only meaningful for client-side helpers (cb_pclienthelper).
                        Self.logger.warning(
                            "Unexpected drainComplete from server-side helper for connectionID: \(connID, privacy: .public)"
                        )

                    case .metadataUpdate:
                        Self.logger.warning(
                            "Unexpected metadataUpdate from server-side helper for connectionID: \(connID, privacy: .public)"
                        )
                    }
                }
                if connectionDelegate.isOverloaded {
                    throw GRPCTransformableError.workloadBusy("response buffer backpressure")
                }
                return .responsePumpCompleted
            }

            // Attestation rotation monitor — notifies the client when the helper's key is no
            // longer current so it can recreate the connection (make-before-break). The
            // notification is jittered by `DrainNotificationScheduler` so a fleet-synchronized key
            // roll doesn't fire every client's reconnection at once (jitter is bounded by the bound
            // key's runway, so short-lived keys / near-expiry notify immediately). The scheduler
            // runs until the update stream ends — it never returns early on a rotation, so the
            // connection stays alive for the client to drain in-flight responses and set up a
            // replacement. Cancelled when another task in the group exits.
            group.addTask {
                let (setup, _) = try await Future(connectingPromise).valueWithCancellation
                let boundKeyID = setup.decryptionKey.keyID
                await DrainNotificationScheduler.run(
                    updates: self.attestationProvider.registerForUpdates(),
                    boundKeyID: boundKeyID,
                    config: self.drainJitterConfig,
                    clock: ContinuousClock()
                ) { attestationSet in
                    let current = attestationSet.currentAttestation
                    Self.logger.info(
                        "Attestation rotated: helper bound to \(boundKeyID.base64EncodedString(), privacy: .public), current is \(current.keyID.base64EncodedString(), privacy: .public). Sending connectionShouldBeRecreated."
                    )
                    var lifecycle = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse
                        .ConnectionLifecycleMessage()
                    lifecycle.eventType = .connectionShouldBeRecreated
                    var suggested = Com_Apple_Cloudboard_Api_V1_SuggestedAttestation()
                    suggested.keyID = current.keyID
                    suggested.attestationBundle = current.attestationBundle
                    suggested.expiresAfter = .init(
                        roundingTimeIntervalSince1970: current.expiry.timeIntervalSince1970
                    )
                    lifecycle.suggestedAttestation = suggested
                    var response = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse()
                    response.type = .connectionLifecycle(lifecycle)
                    do {
                        try await responseStream.send(response)
                    } catch {
                        // Best-effort: a failed send means the stream is already broken; the other
                        // connection tasks will observe it and tear down. Don't propagate here.
                        Self.logger.warning(
                            "Failed to send connectionShouldBeRecreated (bound \(boundKeyID.base64EncodedString(), privacy: .public)): \(String(unredacted: error), privacy: .public)"
                        )
                    }
                }
                return .attestationSubscriptionCompleted
            }

            // Wait for the first task to complete, then cancel the rest
            for try await result in group {
                // `.notice` (not `.info`) so the per-connection teardown reason survives in
                // compute-module logarchives.
                let connID = state.withLock { $0.connectionID }
                Self.logger.notice(
                    "connection torn down: connID=\(connID, privacy: .public) reason=\(result, privacy: .public)"
                )
                group.cancelAll()
                break
            }
        }
    }

    /// Blocks until all active connections finish, rejecting new ones.
    /// Sends `DRAINING_STARTED` to all active connections so they can drain gracefully,
    /// then sends `DRAINING_CRITICAL` to any that remain when the wait completes.
    func drain() async {
        let streams: [ResponseStream] = self.drainState.withLock { state in
            precondition(
                !state.draining,
                "PersistentServiceProvider received request to drain during ongoing drain"
            )
            state.draining = true
            return Array(state.activeStreams.values)
        }

        await self.sendLifecycleMessage(.drainingStarted, to: streams)

        if !streams.isEmpty {
            await withCheckedContinuation { continuation in
                self.drainState.withLock { state in
                    if state.activeConnections == 0 {
                        continuation.resume()
                    } else {
                        state.drainCompleteContinuation = continuation
                    }
                }
            }
        }

        let remainingStreams: [ResponseStream] = self.drainState.withLock { state in
            Array(state.activeStreams.values)
        }
        await self.sendLifecycleMessage(.drainingCritical, to: remainingStreams)
    }

    private func sendLifecycleMessage(
        _ eventType: Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse.ServerLifecycleMessage.EventType,
        to streams: [ResponseStream]
    ) async {
        for stream in streams {
            var lifecycle = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse
                .ServerLifecycleMessage()
            lifecycle.eventType = eventType
            var response = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse()
            response.type = .serverLifeCycle(lifecycle)
            do {
                try await stream.send(response)
            } catch {
                Self.logger.warning(
                    "Failed to send server lifecycle message to connection: \(String(unredacted: error), privacy: .public)"
                )
            }
        }
    }
}

// MARK: - PersistentConnectionDelegate

/// Bridges XPC responses from a persistent helper back to the gRPC response stream.
final class PersistentConnectionDelegate: PersistentHelperAPIClientDelegateProtocol, @unchecked Sendable {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentConnectionDelegate"
    )

    private let initializedPromise: Promise<Void, Error> = Promise(autoFailureIfUnfulfilled: CancellationError())
    private let initializedFulfilled = Mutex(false)
    private let overloaded = Mutex(false)
    private let responseContinuation: AsyncStream<PersistentHelperOutboundMessage>.Continuation
    let helperResponses: AsyncStream<PersistentHelperOutboundMessage>

    var isOverloaded: Bool {
        self.overloaded.withLock { $0 }
    }

    init() {
        // This size is calculated based on:
        // ~64 bytes per query message
        // having 112 hot (sending) connections
        // So if they all have buffer to the limit thats 28 MiB
        // CloudBoard in persistent server mode can afford that (possibly more)
        // but a system that's having 4096 items in the buffer is misbehaving, or we
        // simply aren't keeping up and need to back pressure them.
        let (stream, continuation) = AsyncStream<PersistentHelperOutboundMessage>.makeStream(
            bufferingPolicy: .bufferingOldest(4096)
        )
        self.helperResponses = stream
        self.responseContinuation = continuation
    }

    /// Blocks until the helper sends `.initialized` confirming the HPKE handshake succeeded.
    func waitForInitialized() async throws {
        try await Future(self.initializedPromise).valueWithCancellation
    }

    private func completeInitialized(with result: Result<Void, Error>) {
        let alreadyFulfilled = self.initializedFulfilled.withLock { fulfilled in
            if fulfilled { return true }
            fulfilled = true
            return false
        }
        if alreadyFulfilled {
            let redactedResultText = switch result {
            case .success:
                "success"
            case .failure(let error):
                "error \(String(unredacted: error))"
            }
            Self.logger
                .warning("initializedPromise already fulfilled, ignoring: \(redactedResultText, privacy: .public)")
            return
        }
        self.initializedPromise.fulfil(with: result)
    }

    func handleResponse(_ response: PersistentHelperOutboundMessage) {
        switch response {
        case .initialized:
            self.completeInitialized(with: .success(()))
            self.yieldWithBackpressure(response)

        case .responseChunk, .helperEOF:
            self.yieldWithBackpressure(response)
            if case .helperEOF = response {
                self.responseContinuation.finish()
            }

        case .failureReport(let reason):
            Self.logger.error("Persistent helper reported failure: \(reason, privacy: .public)")
            self.completeInitialized(
                with: .failure(PersistentHelperInstanceError.helperUnavailable("\(reason)"))
            )
            self.responseContinuation.finish()

        case .drainComplete:
            // Only meaningful for client-side helpers (cb_pclienthelper).
            // Server-side helpers should never send this.
            Self.logger.warning("Unexpected drainComplete from server-side helper")

        case .metadataUpdate:
            Self.logger.warning("Unexpected metadataUpdate from server-side helper")
        }
    }

    private func yieldWithBackpressure(_ response: PersistentHelperOutboundMessage) {
        let result = self.responseContinuation.yield(response)
        if case .dropped = result {
            // Buffer full — finish the stream cleanly so the response pump exits
            let alreadyOverloaded = self.overloaded.withLock { o in
                if o { return true }
                o = true
                return false
            }
            if !alreadyOverloaded {
                Self.logger.error("Response buffer full — signaling backpressure termination")
                self.responseContinuation.finish()
            }
        }
    }

    func persistentHelperSurpriseDisconnect() {
        Self.logger.error("Persistent helper surprise disconnected")
        self.completeInitialized(
            with: .failure(PersistentHelperInstanceError.helperUnavailable("surprise disconnect"))
        )
        self.responseContinuation.finish()
    }
}

extension PersistentHelperFailureReason: GRPCStatusTransformable {
    package func makeGRPCStatus() -> InternalGRPC.GRPCStatus {
        return switch self {
        case .ohttpEncapsulationFailure:
            .init(code: .internalError, message: "PersistentService error: OHTTP encapsulation failure")
        case .ohttpDecapsulationFailure:
            .init(code: .internalError, message: "PersistentService error: OHTTP decapsulation failure")
        case .invalidAEAD:
            .init(code: .internalError, message: "PersistentService error: Invalid AEAD")
        case .unknownKeyID:
            .init(code: .internalError, message: "PersistentService error: unknown key ID")
        case .expiredKey:
            .init(code: .internalError, message: "PersistentService error: expired key")
        case .targetConnectionFailed:
            .init(code: .internalError, message: "PersistentService error: target connection failed")
        }
    }
}
