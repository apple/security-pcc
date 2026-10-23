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
import CloudBoardJobHelperAPI
import CloudBoardLogging
import Foundation
import os

package enum PersistentHelperInstanceError: ReportableError {
    case tornDownBeforeRunning
    case unexpectedTerminationError(Error)
    case illegalStateAfterClientIsRunning(String)
    case illegalStateAfterClientIsConnected(String)
    case helperUnavailable(String)
    case monitoringCompletedEarly(Error?)
    case monitoringCompletedFromConnected(Error?)
    case monitoringCompletedMoreThanOnce
    case jobNeverRan
    case setDelegateCalledOnTerminatingInstance
    case sendMessageBeforeClientConnected
    case helperExitedUnexpectedly

    package var publicDescription: String {
        return switch self {
        case .tornDownBeforeRunning: "tornDownBeforeRunning"
        case .unexpectedTerminationError(let error): "unexpectedTerminationError(\(String(reportable: error)))"
        case .illegalStateAfterClientIsRunning(let state): "illegalStateAfterClientIsRunning(\(state))"
        case .illegalStateAfterClientIsConnected(let state): "illegalStateAfterClientIsConnected(\(state))"
        case .helperUnavailable(let state): "helperUnavailable(\(state))"
        case .monitoringCompletedEarly(let error):
            "monitoringCompletedEarly\(error.map { "(\(String(reportable: $0)))" } ?? "")"
        case .monitoringCompletedFromConnected(let error):
            "monitoringCompletedFromConnected\(error.map { "(\(String(reportable: $0)))" } ?? "")"
        case .monitoringCompletedMoreThanOnce: "monitoringCompletedMoreThanOnce"
        case .jobNeverRan: "jobNeverRan"
        case .setDelegateCalledOnTerminatingInstance: "setDelegateCalledOnTerminatingInstance"
        case .sendMessageBeforeClientConnected: "sendMessageBeforeClientConnected"
        case .helperExitedUnexpectedly: "helperExitedUnexpectedly"
        }
    }
}

/// Manages a persistent helper process instance and provides an API to it.
///
/// This is a simplified version of `JobHelperInstance` for long-lived persistent connections.
/// Unlike `JobHelperInstance`, there is no prewarming, no LAContext management, and no pool return.
/// Each instance is bound to a specific key and terminates when that key becomes invalid.
package actor PersistentHelperInstance: Equatable {
    package static func == (lhs: PersistentHelperInstance, rhs: PersistentHelperInstance) -> Bool {
        return lhs.job.uuid == rhs.job.uuid
    }

    fileprivate static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard", category: "PersistentHelperInstance"
    )

    private var stateMachine: PersistentHelperInstanceStateMachine

    private nonisolated let job: any LaunchdJobInstanceInitiatorProtocol
    package nonisolated let keyID: Data
    private nonisolated let helperXPCClientFactory: any PersistentHelperAPIClientFactoryProtocol

    package nonisolated var id: UUID {
        return self.job.uuid
    }

    private let connectCompletePromise: Promise<Void, Error> = Promise(autoFailureIfUnfulfilled: CancellationError())
    private let teardownTrigger: Promise<Void, Error> = Promise(autoFailureIfUnfulfilled: CancellationError())
    private var teardownTriggered: Bool = false

    init(
        _ helperLaunchdJob: any LaunchdJobDefinitionProtocol,
        keyID: Data,
        helperXPCClientFactory: any PersistentHelperAPIClientFactoryProtocol,
        delegate: PersistentHelperAPIClientDelegateProtocol,
        teardownTimeout: Duration
    ) {
        self.job = helperLaunchdJob.createInstance(uuid: UUID())
        self.keyID = keyID
        self.helperXPCClientFactory = helperXPCClientFactory
        self.stateMachine = PersistentHelperInstanceStateMachine(
            keyID: keyID,
            jobHelperJobInstance: self.job,
            helperXPCClientFactory: self.helperXPCClientFactory,
            delegate: delegate,
            teardownTimeout: teardownTimeout
        )
    }

    package func run() async throws {
        do {
            Self.log.info("Running persistent helper job \(self.job.uuid, privacy: .public)")
            for try await state in self.job.startAndWatch() {
                Self.log.info("""
                Persistent helper job \(self.job.uuid, privacy: .public) state changed to \
                '\(state, privacy: .public)'
                """)
                switch state {
                case .initialized, .created, .starting:
                    break
                case .running(let pid):
                    do {
                        try await self.stateMachine.clientIsRunning(pid: pid)
                        self.markConnectComplete()
                    } catch {
                        self.markConnectComplete(error: error)
                    }
                case .terminated(let terminationCondition):
                    _ = terminationCondition
                    await self.stateMachine.clientTerminated()
                case .neverRan:
                    await self.stateMachine.clientTerminated()
                @unknown default:
                    break
                }
            }
        }
        try await self.stateMachine.monitoringCompleted()
        // If teardown was not triggered before the process exited, the helper
        // died unexpectedly (crash, external signal, etc.). Throw so the caller
        // can distinguish this from an intentional exit (draining, node removal).
        if !self.teardownTriggered {
            throw PersistentHelperInstanceError.helperExitedUnexpectedly
        }
    }

    private func markConnectComplete(error: Error? = nil) {
        if let error {
            self.connectCompletePromise.fail(with: error)
        } else {
            self.connectCompletePromise.succeed()
        }
    }

    package func set(
        delegate: PersistentHelperAPIClientDelegateProtocol
    ) async throws {
        try await self.stateMachine.set(delegate: delegate)
    }

    package func waitForConnectComplete() async throws {
        do {
            try await Future(self.connectCompletePromise).valueWithCancellation
        } catch let error as CancellationError {
            Self.log.error("waitForConnectComplete() task cancelled")
            throw error
        } catch {
            Self.log.error("""
            waitForConnectComplete() returned error: \
            \(String(unredacted: error), privacy: .public)
            """)
            throw error
        }
    }

    package func initialize(_ params: PersistentHelperInitParams) async throws {
        try await self.stateMachine.initialize(params)
    }

    package func initializeClient(_ params: PersistentClientHelperInitParams) async throws {
        try await self.stateMachine.initializeClient(params)
    }

    package func sendEncryptedMessage(_ message: PersistentHelperInboundMessage) async throws {
        try await self.stateMachine.sendEncryptedMessage(message)
    }

    package func triggerTeardown(error: Error? = nil) {
        guard !self.teardownTriggered else {
            Self.log.log("Teardown already triggered. Ignoring new trigger.")
            return
        }
        self.teardownTriggered = true
        if let error {
            self.teardownTrigger.fail(with: error)
        } else {
            self.teardownTrigger.succeed()
        }
    }

    /// Waits for the teardown trigger to fire, then performs teardown and waits for it to complete.
    ///
    /// This is the preferred way to manage instance lifecycle because it ensures the caller
    /// does not return until the helper process has been fully torn down (XPC teardown command
    /// sent and launchd job removed). Returning early — e.g. on cancellation — would leak the
    /// helper instance and its associated system resources.
    package func awaitTeardownTriggerAndComplete() async {
        do {
            try await Future(self.teardownTrigger).value
        } catch {
            Self.log.error("""
            Persistent helper instance received error from associated \
            future: \(String(unredacted: error), privacy: .public)
            """)
        }

        do {
            try await self.stateMachine.teardown()
        } catch {
            Self.log.error("""
            Persistent helper instance encountered error invoking \
            teardown: \(String(unredacted: error), privacy: .public)
            """)
        }
    }

    package func waitForExit() async throws {
        try await self.stateMachine.waitForTermination()
    }
}

// MARK: - State Machine

/// Handler called when the state machine is dropped in an invalid state.
///
/// In production this calls `fatalError`; in tests it can be replaced with
/// a handler that records a test failure without crashing the process.
internal protocol PersistentHelperInstanceInvariantFailureHandler: Sendable {
    func handleInvariantViolation(_ message: @autoclosure () -> String)
}

/// The default handler that calls `fatalError`, used in production.
internal struct DefaultInvariantFailureHandler: PersistentHelperInstanceInvariantFailureHandler {
    func handleInvariantViolation(_ message: @autoclosure () -> String) {
        fatalError(message())
    }
}

internal actor PersistentHelperInstanceStateMachine {
    enum State: CustomStringConvertible {
        case awaitingConnection
        case connecting(PersistentHelperAPIClientDelegateProtocol)
        case connected(any PersistentHelperAPIClientProtocol)
        case terminating
        case terminated
        case monitoringCompleted

        var description: String {
            switch self {
            case .awaitingConnection: "awaitingConnection"
            case .connecting: "connecting"
            case .connected: "connected"
            case .terminating: "terminating"
            case .terminated: "terminated"
            case .monitoringCompleted: "monitoringCompleted"
            }
        }
    }

    private let keyID: Data
    private let jobHelperJobInstance: any LaunchdJobInstanceInitiatorProtocol
    private let helperXPCClientFactory: any PersistentHelperAPIClientFactoryProtocol
    internal var remotePID: Int?
    private var delegate: PersistentHelperAPIClientDelegateProtocol
    private var state: State {
        didSet(oldState) {
            PersistentHelperInstance.log.trace("""
            PersistentHelperInstanceStateMachine state changed: \
            \(oldState, privacy: .public) -> \(self.state, privacy: .public)
            """)
        }
    }

    private let terminationPromise = Promise<Void, Error>(autoFailureIfUnfulfilled: CancellationError())
    private var terminationRequested: Bool = false
    private let teardownTimeout: Duration
    private nonisolated let failureHandler: any PersistentHelperInstanceInvariantFailureHandler

    init(
        keyID: Data,
        jobHelperJobInstance: any LaunchdJobInstanceInitiatorProtocol,
        helperXPCClientFactory: any PersistentHelperAPIClientFactoryProtocol,
        delegate: PersistentHelperAPIClientDelegateProtocol,
        teardownTimeout: Duration,
        failureHandler: any PersistentHelperInstanceInvariantFailureHandler = DefaultInvariantFailureHandler()
    ) {
        self.keyID = keyID
        self.state = .awaitingConnection
        self.jobHelperJobInstance = jobHelperJobInstance
        self.helperXPCClientFactory = helperXPCClientFactory
        self.delegate = delegate
        self.teardownTimeout = teardownTimeout
        self.failureHandler = failureHandler
    }

    func set(
        delegate: PersistentHelperAPIClientDelegateProtocol
    ) async throws {
        self.delegate = delegate
        switch self.state {
        case .awaitingConnection, .connecting:
            ()
        case .connected(let client):
            await client.set(delegate: self.delegate)
        case .terminating, .terminated, .monitoringCompleted:
            PersistentHelperInstance.log.error(
                "Received request to update delegate on terminating PersistentHelperInstance"
            )
            throw PersistentHelperInstanceError.setDelegateCalledOnTerminatingInstance
        }
    }

    deinit {
        switch state {
        case .awaitingConnection, .connecting:
            terminationPromise.fail(
                with: PersistentHelperInstanceError.tornDownBeforeRunning
            )
        case .connected:
            // Log at fault level — this is a bug (state machine dropped without cleanup)
            // but must not crash the process: a single helper failure should only
            // affect the gRPC stream that owns it, not the entire daemon.
            PersistentHelperInstance.log.fault(
                "PersistentHelperInstanceStateMachine dropped in .connected state without cleaning up"
            )
            terminationPromise.fail(
                with: PersistentHelperInstanceError.tornDownBeforeRunning
            )
        case .terminated, .monitoringCompleted:
            ()
        case .terminating:
            // Same rationale: log the invariant violation without crashing.
            PersistentHelperInstance.log.fault(
                "PersistentHelperInstanceStateMachine dropped in .terminating state before completion"
            )
        }
    }

    func initialize(_ params: PersistentHelperInitParams) async throws {
        switch self.state {
        case .connected(let client):
            PersistentHelperInstance.log.debug("Sending initialize to persistent helper")
            try await client.initialize(params)
        case .awaitingConnection, .connecting:
            PersistentHelperInstance.log.error(
                "Cannot initialize persistent helper: not yet connected"
            )
            throw PersistentHelperInstanceError.sendMessageBeforeClientConnected
        case .terminating, .terminated, .monitoringCompleted:
            PersistentHelperInstance.log.error(
                "Cannot initialize persistent helper: terminating"
            )
            throw PersistentHelperInstanceError.helperUnavailable("\(self.state)")
        }
    }

    func initializeClient(_ params: PersistentClientHelperInitParams) async throws {
        switch self.state {
        case .connected(let client):
            PersistentHelperInstance.log.debug("Sending initializeClient to persistent helper")
            try await client.initializeClient(params)
        case .awaitingConnection, .connecting:
            PersistentHelperInstance.log.error(
                "Cannot initialize client helper: not yet connected"
            )
            throw PersistentHelperInstanceError.sendMessageBeforeClientConnected
        case .terminating, .terminated, .monitoringCompleted:
            PersistentHelperInstance.log.error(
                "Cannot initialize client helper: terminating"
            )
            throw PersistentHelperInstanceError.helperUnavailable("\(self.state)")
        }
    }

    func sendEncryptedMessage(_ message: PersistentHelperInboundMessage) async throws {
        switch self.state {
        case .connected(let client):
            PersistentHelperInstance.log.debug("Sending encrypted message to persistent helper")
            try await client.sendEncryptedMessage(message)
        case .awaitingConnection, .connecting:
            PersistentHelperInstance.log.error(
                "Cannot send message to persistent helper: not yet connected"
            )
            throw PersistentHelperInstanceError.sendMessageBeforeClientConnected
        case .terminating, .terminated, .monitoringCompleted:
            PersistentHelperInstance.log.error(
                "Cannot send message to persistent helper: terminating"
            )
            throw PersistentHelperInstanceError.helperUnavailable("\(self.state)")
        }
    }

    func clientIsRunning(pid: Int?) async throws {
        self.remotePID = pid
        PersistentHelperInstance.log.notice(
            "Persistent helper is running (pid: \(pid.map { String($0) } ?? "unknown", privacy: .public))"
        )
        switch self.state {
        case .awaitingConnection:
            let setDelegate = self.delegate
            self.state = .connecting(setDelegate)
            let client: any PersistentHelperAPIClientProtocol
            do {
                client = try await self.connect(delegate: setDelegate)
            } catch {
                PersistentHelperInstance.log.error("""
                Unable to connect to persistent helper \
                \(String(unredacted: error), privacy: .public) moving to terminated state
                """)
                self.state = .terminated
                self.terminationPromise.fail(with: error)
                throw error
            }
            // This only throows if  state tranasition was bad, so it's fine to just leave the state
            // machine in whatever state that results in.
            try await self.clientIsConnected(client: client)
        case .connecting, .connected, .terminating, .terminated, .monitoringCompleted:
            PersistentHelperInstance.log.fault("""
            State machine in unexpected state \
            \(self.state, privacy: .public) after persistent helper reported running
            """)
            throw PersistentHelperInstanceError.illegalStateAfterClientIsRunning("\(self.state)")
        }
    }

    func connect(
        delegate: any PersistentHelperAPIClientDelegateProtocol
    ) async throws -> any PersistentHelperAPIClientProtocol {
        PersistentHelperInstance.log.debug("Connecting to persistent helper")
        let client = try await self.helperXPCClientFactory.localConnection(self.jobHelperJobInstance.uuid)
        await client.set(delegate: delegate)
        await client.connect()
        PersistentHelperInstance.log.debug("Connected to persistent helper")
        return client
    }

    private func clientIsConnected(
        client: any PersistentHelperAPIClientProtocol
    ) async throws {
        while case .connecting(let setDelegate) = self.state, !(setDelegate === delegate) {
            self.state = .connecting(self.delegate)
            await client.set(delegate: self.delegate)
        }

        switch self.state {
        case .connecting:
            self.state = .connected(client)
            if self.terminationRequested {
                await self.teardownConnectedClient(client: client)
            }
        case .terminated:
            ()
        case .awaitingConnection, .connected, .terminating, .monitoringCompleted:
            PersistentHelperInstance.log.fault("""
            State machine in unexpected state \
            \(self.state, privacy: .public) after connecting to persistent helper
            """)
            throw PersistentHelperInstanceError.illegalStateAfterClientIsConnected("\(self.state)")
        }
    }

    func teardown() async throws {
        PersistentHelperInstance.log.log("Received request to teardown persistent helper")

        if self.terminationRequested {
            PersistentHelperInstance.log.info("Termination already requested, waiting")
            try await self.waitForTermination()
            return
        }

        self.terminationRequested = true

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.teardownTask() }
                group.addTask { try await self.teardownTimeoutTask() }
                PersistentHelperInstance.log.info("Waiting for persistent helper termination")
                try await group.next()
                group.cancelAll()
                PersistentHelperInstance.log.info("Teardown complete")
            }
            try? await self.removeJob()
        } catch {
            try? await self.removeJob()
        }
    }

    private func teardownTask() async throws {
        switch self.state {
        case .awaitingConnection, .connecting:
            PersistentHelperInstance.log.info(
                "Received teardown while not yet connected, waiting for connection"
            )
            try await self.waitForTermination()
        case .connected(let client):
            await self.teardownConnectedClient(client: client)
            try await self.waitForTermination()
        case .terminating:
            try await self.waitForTermination()
        case .terminated, .monitoringCompleted:
            PersistentHelperInstance.log.debug(
                "Ignoring teardown request in state \(self.state, privacy: .public)"
            )
        }
    }

    private func teardownTimeoutTask() async throws {
        PersistentHelperInstance.log.info("Teardown timeout task started")
        do {
            try await Task.sleep(for: self.teardownTimeout)
        } catch is CancellationError {
            PersistentHelperInstance.log.info("Teardown timeout cancelled")
            throw CancellationError()
        }
        PersistentHelperInstance.log.error("Termination of persistent helper timed out")
        try await self.removeJob()
    }

    private func removeJob() async throws {
        if let handle = await self.jobHelperJobInstance.instanceHandleIfCreated {
            PersistentHelperInstance.log.error("Persistent helper still running, removing")
            try handle.remove(logger: PersistentHelperInstance.log)
        }
    }

    internal func waitForTermination() async throws {
        do {
            try await Future(self.terminationPromise).valueWithCancellation
        } catch let error as CancellationError {
            throw error
        } catch let error as PersistentHelperInstanceError {
            switch error {
            case .monitoringCompletedEarly, .monitoringCompletedFromConnected:
                // Known race: the launchd monitor stream completed while the
                // state machine still considered the helper alive. The state
                // machine has already classified and handled the outcome; we
                // are only propagating it to callers awaiting termination.
                PersistentHelperInstance.log.notice("""
                terminationPromise resolved via known monitor-completed race: \
                \(String(reportable: error), privacy: .public)
                """)
            case .tornDownBeforeRunning, .unexpectedTerminationError,
                 .illegalStateAfterClientIsRunning, .illegalStateAfterClientIsConnected,
                 .helperUnavailable, .monitoringCompletedMoreThanOnce,
                 .jobNeverRan, .setDelegateCalledOnTerminatingInstance,
                 .sendMessageBeforeClientConnected, .helperExitedUnexpectedly:
                PersistentHelperInstance.log.error("""
                Unexpected error while waiting for \
                terminationPromise to be fulfilled: \
                \(String(reportable: error), privacy: .public)
                """)
            }
            throw PersistentHelperInstanceError.unexpectedTerminationError(error)
        } catch {
            PersistentHelperInstance.log.fault("""
            Unexpected error while waiting for \
            terminationPromise to be fulfilled: \
            \(String(reportable: error), privacy: .public)
            """)
            throw PersistentHelperInstanceError.unexpectedTerminationError(error)
        }
    }

    private func teardownConnectedClient(
        client: PersistentHelperAPIClientToServerProtocol
    ) async {
        self.state = .terminating
        PersistentHelperInstance.log.info("Sending teardown request to persistent helper")
        do {
            try await client.teardown()
        } catch {
            PersistentHelperInstance.log.error("""
            client.teardown() returned error: \
            \(String(unredacted: error), privacy: .public)
            """)
        }
    }

    func clientTerminated() async {
        switch self.state {
        case .awaitingConnection, .connecting, .connected, .terminating:
            self.terminationPromise.succeed()
        case .terminated:
            PersistentHelperInstance.log.warning(
                "Persistent helper reported to have terminated twice"
            )
        case .monitoringCompleted:
            PersistentHelperInstance.log.warning(
                "Persistent helper reported to have terminated after monitoring stopped"
            )
        }
        self.state = .terminated
    }

    func monitoringCompleted(error: Error? = nil) async throws {
        defer {
            self.state = .monitoringCompleted
        }

        switch self.state {
        case .awaitingConnection, .connecting, .terminating:
            if let error {
                PersistentHelperInstance.log.error("""
                Persistent helper monitoring stopped before receiving \
                termination notification with error: \
                \(String(unredacted: error), privacy: .public)
                """)
            } else {
                PersistentHelperInstance.log.error(
                    "Persistent helper monitoring stopped before receiving termination notification"
                )
            }
            self.terminationPromise.fail(
                with: PersistentHelperInstanceError.monitoringCompletedEarly(error)
            )
            throw PersistentHelperInstanceError.monitoringCompletedEarly(error)
        case .connected where self.terminationRequested:
            // Teardown was already in flight; the helper exiting now is the
            // expected end of that sequence — not an "unexpected" race.
            // Don't try to send a teardown XPC to a process that is already
            // gone, and don't fail the promise: callers awaiting termination
            // should see clean completion. The defer above still transitions
            // state to .monitoringCompleted.
            if let error {
                PersistentHelperInstance.log.notice("""
                Persistent helper monitoring stopped during teardown with \
                error: \(String(reportable: error), privacy: .public)
                """)
            } else {
                PersistentHelperInstance.log.notice(
                    "Persistent helper monitoring stopped during teardown"
                )
            }
            self.terminationPromise.succeed()
        case .connected(let client):
            PersistentHelperInstance.log.error("""
            Persistent helper monitoring stopped before receiving termination \
            notification (while connected). Sending teardown.
            """)
            await self.teardownConnectedClient(client: client)
            self.terminationPromise.fail(
                with: PersistentHelperInstanceError.monitoringCompletedFromConnected(error)
            )
            throw PersistentHelperInstanceError.monitoringCompletedFromConnected(error)
        case .terminated:
            ()
        case .monitoringCompleted:
            PersistentHelperInstance.log.error(
                "Persistent helper monitoring reported to have completed twice"
            )
            throw PersistentHelperInstanceError.monitoringCompletedMoreThanOnce
        }
    }
}
