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

import CloudBoardAsyncXPC
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging

import Foundation
import os

actor ManagedAppStateMachine {
    enum ManagedAppMessage {
        case byteBufferCodable(any CloudBoardAsyncXPCByteBufferMessage)
        case codable(any CloudBoardAsyncXPCCodableMessage)
    }

    // NOTE: The description of this type is publicly logged and/or included in metric dimensions and therefore MUST not
    // contain sensitive data.
    enum State: CustomStringConvertible {
        case awaitingAppConnection([ManagedAppMessage], ManagedWarmupInfo?, ParametersData?)
        case connecting([ManagedAppMessage], ManagedWarmupInfo?, ParametersData?)
        case connected(ManagedAppXPCClient)
        case terminating
        case terminated
        case monitoringCompleted

        // NOTE: This description is publicly logged and/or included in metric dimensions and therefore MUST not contain
        // sensitive data.
        var description: String {
            switch self {
            case .awaitingAppConnection: "awaitingAppConnection"
            case .connecting: "connecting"
            case .connected: "connected"
            case .terminating: "terminating"
            case .terminated: "terminated"
            case .monitoringCompleted: "monitoringCompleted"
            }
        }
    }

    private let xpcClientFactory: any ManagedAppXPCClientFactoryProtocol
    private let job: any LaunchdJobInstanceInitiatorProtocol
    private let appName: String
    private var remotePID: Int?
    private var requestID: String?
    private var spanID: UInt64?

    private let tracingLogger: Logger
    private let logger: Logger

    private var state: State = .awaitingAppConnection([], nil, nil) {
        didSet(oldState) {
            self.logger.trace("""
            jobID=\(self.job.uuid, privacy: .public)
            appName=\(self.appName, privacy: .public)
            message=\("state changed", privacy: .public)
            oldState=\(oldState, privacy: .public)
            state=\(self.state, privacy: .public)
            """)
        }
    }

    private var started: Bool = false
    private let warmupPromise = Promise<Void, Error>(
        autoFailureIfUnfulfilled: ManagedAppError
            .tornDownBeforeWarmupFinished
    )
    private let terminationPromise = Promise<Void, Error>()
    private var terminationRequest: TerminationRequest = .none
    public var abandoned: Bool {
        self.terminationRequest == .abandon
    }

    private enum TerminationRequest {
        case none
        case terminate
        case abandon
    }

    init(
        appName: String,
        xpcClientFactory: any ManagedAppXPCClientFactoryProtocol,
        job: any LaunchdJobInstanceInitiatorProtocol,
        tracingLogger: Logger,
        logger: Logger,
        spanID: UInt64?
    ) {
        self.appName = appName
        self.xpcClientFactory = xpcClientFactory
        self.job = job
        self.tracingLogger = tracingLogger
        self.logger = logger
        self.spanID = spanID
    }

    deinit {
        if !started {
            terminationPromise.fail(with: ManagedAppError.tornDownBeforeRunning)
        }
    }

    func start() async {
        self.started = true
    }

    /// Sends a message asynchronously without waiting for a response. Specifically, if the XPC client is not yet
    /// connected, the messages will be buffered and this returns immediately. The messages are forwarded once the
    /// client is connected.
    ///
    /// If the client is already connected, this will send the message right away and wait for the ExplicitSuccess XPC
    /// response.
    /// - Parameter message: The message to send.
    /// - Parameter ignoreOnTermination: If set to true, this will just ignore the message and not throw if the message
    /// can't be sent because the app is currently terminating or has already terminated.
    func sendOrBuffer<Message: CloudBoardAsyncXPCByteBufferMessage>(
        _ message: Message,
        ignoreOnTermination: Bool
    ) async throws
    where Message.Success == ExplicitSuccess {
        try await self.sendOrBuffer(
            ManagedAppMessage.byteBufferCodable(message),
            ignoreOnTermination: ignoreOnTermination
        )
    }

    /// Sends a message asynchronously without waiting for a response. Specifically, if the XPC client is not yet
    /// connected, the messages will be buffered and this returns immediately. The messages are forwarded once the
    /// client is connected.
    ///
    /// If the client is already connected, this will send the message right away and wait for the ExplicitSuccess XPC
    /// response.
    /// - Parameter message: The message to send.
    /// - Parameter ignoreOnTermination: If set to true, this will just ignore the message and not throw if the message
    /// can't be sent because the app is currently terminating or has already terminated.
    func sendOrBuffer<Message: CloudBoardAsyncXPCCodableMessage>(
        _ message: Message,
        ignoreOnTermination: Bool
    ) async throws
    where Message.Success == ExplicitSuccess {
        try await self.sendOrBuffer(ManagedAppMessage.codable(message), ignoreOnTermination: ignoreOnTermination)
    }

    /// Sends XPC message to the connected app.
    ///
    /// Will fail if not yet connected to the app. Currently only used for messages expected to be sent to the app
    /// in response to messages sent from the app, ensuring that the connection must have previously established.
    ///
    /// - Parameter message: The message to send.
    func send<Message: CloudBoardAsyncXPCByteBufferMessage>(_ message: Message) async throws -> Message.Success {
        switch self.state {
        case .awaitingAppConnection, .connecting:
            // Can never happen if messages are only sent in response to the cloud app making a request/sending a
            // message first
            let error = ManagedAppError.illegalStateWhenSendingMessage(
                "\(self.state)",
                type: "\(String(describing: type(of: message)))"
            )
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "State machine in unexpected state while trying to send message",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: .fault)
            throw error
        case .connected(let client):
            return try await client.send(message)
        case .terminated, .terminating, .monitoringCompleted:
            // We have terminated in the meantime, nothing we can do
            let error = ManagedAppError.alreadyTerminated
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Cannot send message to app currently terminating",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: .error)
            throw error
        }
    }

    /// Sends XPC message to the connected app.
    ///
    /// Will fail if not yet connected to the app. Currently only used for messages expected to be sent to the app
    /// in response to messages sent from the app, ensuring that the connection must have previously established.
    ///
    /// - Parameter message: The message to send.
    func send<Message: CloudBoardAsyncXPCCodableMessage>(_ message: Message) async throws -> Message.Success {
        switch self.state {
        case .awaitingAppConnection, .connecting:
            // Can never happen as worker can only be found is only sent in response to the cloud app requesting an
            // outbound connection
            let error = ManagedAppError.illegalStateWhenSendingMessage(
                "\(self.state)",
                type: "\(String(describing: type(of: message)))"
            )
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "State machine in unexpected state while trying to send message",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: .fault)
            throw error
        case .connected(let client):
            return try await client.send(message)
        case .terminated, .terminating, .monitoringCompleted:
            // We have terminated in the meantime, nothing we can do
            let error = ManagedAppError.alreadyTerminated
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Cannot send message to app currently terminating",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: .error)
            throw error
        }
    }

    private func sendOrBuffer(_ message: ManagedAppMessage, ignoreOnTermination: Bool) async throws {
        switch self.state {
        case .awaitingAppConnection(let bufferedMessages, let warmupInfo, let parametersData):
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "buffering input data while waiting for connection to managed app",
                state: self.state
            ).log(to: self.tracingLogger, level: .debug)
            self.state = .awaitingAppConnection(bufferedMessages + [message], warmupInfo, parametersData)
        case .connecting(let bufferedMessages, let warmupInfo, let parametersData):
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "buffering input data while waiting for connection to managed app",
                state: self.state
            ).log(to: self.tracingLogger, level: .debug)
            self.state = .connecting(bufferedMessages + [message], warmupInfo, parametersData)
        case .connected(let client):
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "sending input data to managed app",
                state: self.state
            ).log(to: self.tracingLogger, level: .debug)
            switch message {
            case .byteBufferCodable(let message):
                _ = try await client.send(message)
            case .codable(let message):
                _ = try await client.send(message)
            }
        case .terminating, .terminated, .monitoringCompleted:
            let error = ManagedAppError.appUnavailable(state: "\(self.state)")
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Cannot forward input to managed app currently terminating or already terminated",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: ignoreOnTermination ? .default : .error)
            if !ignoreOnTermination {
                throw error
            }
        }
    }

    func clientIsRunning(
        pid: Int?,
        responseHandler: ManagedAppResponseHandlerProtocol
    ) async throws {
        self.remotePID = pid
        // Notice-/default-level log to ensure that we have the cb_jobhelper associated with the current request is
        // visible in Splunk
        ManagedAppStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            appName: self.appName,
            message: "App is running",
            state: self.state
        ).log(to: self.tracingLogger, level: .default)
        switch self.state {
        case .awaitingAppConnection(let bufferedInputData, let warmupInfo, let parametersData):
            self.state = .connecting(bufferedInputData, warmupInfo, parametersData)
            try await self.connect(responseHandler: responseHandler)
        case .connecting, .connected,
             .terminating, .terminated, .monitoringCompleted:
            let error = ManagedAppError.illegalStateAfterClientIsRunning("\(self.state)")
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "State machine in unexpected state after app state reported to be \"running\"",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: .fault)
            throw error
        }
    }

    private func connect(
        responseHandler: ManagedAppResponseHandlerProtocol
    ) async throws {
        ManagedAppStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            appName: self.appName,
            message: "Connecting to app",
            state: self.state
        ).log(to: self.tracingLogger, level: .info)

        let appClient = try await xpcClientFactory.makeXPCClient(for: self.job, responseHandler: responseHandler)

        ManagedAppStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            appName: self.appName,
            message: "Connected to app",
            state: self.state
        ).log(to: self.tracingLogger, level: .info)
        try await self.clientIsConnected(client: appClient)
    }

    func warmup(info: ManagedWarmupInfo) async throws {
        switch self.state {
        case .awaitingAppConnection(let data, _, let parametersData):
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received warmup message. Waiting for cloud app connection.",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
            self.state = .awaitingAppConnection(data, info, parametersData)
        case .connecting(let data, _, let parametersData):
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received warmup message. Waiting for cloud app connection.",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
            self.state = .connecting(data, info, parametersData)
        case .terminated:
            // This is a bit of a race but it's basically fine: we received this message as
            // we were tearing down. Do nothing.
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received warmup message after cloud app terminated, message will be dropped",
                state: self.state
            ).log(to: self.tracingLogger, level: .error)
        case .connected(let client):
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received warmup message. Forwarding to cloud app.",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
            await self.sendWarmup(client: client, info: info)
        case .terminating, .monitoringCompleted:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received warmup data while app is terminating or monitoring completed",
                state: self.state
            ).log(to: self.tracingLogger, level: .fault)
        }

        try await Future(self.warmupPromise).valueWithCancellation
    }

    func parameters(_ parametersData: ParametersData) async throws {
        self.requestID = parametersData.plaintextMetadata.requestID
        switch self.state {
        case .awaitingAppConnection(let data, let warmupInfo, _):
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received parameters message",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
            self.state = .awaitingAppConnection(data, warmupInfo, parametersData)
        case .connecting(let data, let warmupInfo, _):
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received parameters message",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
            self.state = .connecting(data, warmupInfo, parametersData)
        case .terminated:
            // This is a bit of a race but it's basically fine: we received this message as
            // we were tearing down. Do nothing.
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received parameters message after app terminated, message will be dropped",
                state: self.state
            ).log(to: self.tracingLogger, level: .error)
        case .connected(let client):
            try await client.sendParameters(parametersData: parametersData)
        case .terminating, .monitoringCompleted:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received parameters data while app is terminating or monitoring completed",
                state: self.state
            ).log(to: self.tracingLogger, level: .fault)
        }
    }

    private func sendWarmup(
        client: ManagedAppXPCClient,
        info: ManagedWarmupInfo
    ) async {
        do {
            try await client.warmup(info: info)
            self.warmupPromise.succeed()
        } catch {
            self.warmupPromise.fail(with: ManagedAppError.warmupFailed(error))
        }
    }

    // Expected to be invoked from .connecting states
    private func clientIsConnected(client: ManagedAppXPCClient) async throws {
        switch self.state {
        case .connecting:
            if let warmupInfo = self.state.warmupInfo {
                ManagedAppStateMachineCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    appName: self.appName,
                    message: "Client is connected, forwarding previously received warmup info",
                    state: self.state
                ).log(to: self.tracingLogger, level: .default)
                await self.sendWarmup(client: client, info: warmupInfo)
            }
            if let parametersData = state.parametersData {
                try await client.sendParameters(parametersData: parametersData)
                ManagedAppStateMachineCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    appName: self.appName,
                    message: "Client is connected, forwarding previously received parameters data",
                    state: self.state
                ).log(to: self.tracingLogger, level: .default)
            }
            switch self.terminationRequest {
            case .none:
                while let bufferedMessage = state.nextBufferedMessage() {
                    ManagedAppStateMachineCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        appName: self.appName,
                        message: "Forwarding buffered input chunk to app",
                        state: self.state
                    ).log(to: self.tracingLogger, level: .debug)
                    switch bufferedMessage {
                    case .byteBufferCodable(let message):
                        _ = try await client.send(message)
                    case .codable(let message):
                        _ = try await client.send(message)
                    }
                }

                switch self.state {
                case .connecting:
                    self.state = .connected(client)
                case .terminated, .terminating, .monitoringCompleted:
                    // We have terminated in the meantime, nothing we can do
                    ()
                case .awaitingAppConnection, .connected:
                    let error = ManagedAppError.illegalStateAfterClientIsConnected("\(self.state)")
                    ManagedAppStateMachineCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        appName: self.appName,
                        message: "State machine in unexpected state after connecting to app",
                        state: self.state,
                        error: error
                    ).log(to: self.tracingLogger, level: .fault)
                    throw error
                }
            case .terminate, .abandon:
                // The app was requested to terminate. Note the bufferedMessages here might be stale, but we don't
                // actually use the contained data so this is fine.
                try await self.teardownConnectedClient(
                    client: client,
                    bufferedMessages: self.state.bufferedMessages
                )
            }
        case .terminated, .terminating, .monitoringCompleted:
            // We have terminated in the meantime, nothing we can do
            ()
        case .awaitingAppConnection, .connected:
            let error = ManagedAppError.illegalStateAfterClientIsConnected("\(self.state)")
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "State machine in unexpected state after connecting to app",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: .fault)
            throw error
        }
    }

    func abandon() async throws {
        try await self.teardown(abandon: true)
    }

    func teardown(abandon: Bool = false) async throws {
        if self.terminationRequest != .none {
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Job termination already requested, waiting for termination",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
        } else {
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received request to teardown job",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
            if abandon == true {
                self.terminationRequest = .abandon
            } else {
                self.terminationRequest = .terminate
            }
        }

        switch self.state {
        case .awaitingAppConnection, .connecting:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Received request to teardown app while not yet connected, waiting for connection",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
            try await self.waitForTermination()
        case .connected(let client):
            try await self.teardownConnectedClient(client: client)
            try await self.waitForTermination()
        case .terminating:
            try await self.waitForTermination()
        case .terminated, .monitoringCompleted:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Ignoring request to teardown app",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
        }
    }

    private func waitForTermination() async throws {
        do {
            try await Future(self.terminationPromise).valueWithCancellation
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "Unexpected error while waiting for terminationPromise to be fulfilled",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: .fault)
            throw ManagedAppError.unexpectedTerminationError(error)
        }
    }

    private func teardownConnectedClient(
        //        client: CloudBoardJobAPIClientToServerProtocol,
        client: ManagedAppXPCClient,
        bufferedMessages: [ManagedAppMessage] = []
    ) async throws {
        if bufferedMessages.count > 0 {
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "App requested to terminate with buffered messages",
                state: self.state
            ).log(to: self.tracingLogger, level: .error)
        }
        self.state = .terminating
        ManagedAppStateMachineCheckpoint(
            logMetadata: self.logMetadata(),
            appName: self.appName,
            message: "Sending teardown request to app",
            state: self.state
        ).log(to: self.tracingLogger, level: .debug)
        do {
            try await client.teardown()
        } catch {
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "client.teardown() returned error",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: .error)
        }
    }

    func clientTerminated(statusCode _: Int?) async {
        switch self.state {
        case .awaitingAppConnection(_, _, _),
             .connecting:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "App has terminated with buffered input data chunks",
                state: self.state
            ).log(to: self.tracingLogger, level: .error)
            self.terminationPromise.succeed()
        case .connected, .terminating:
            self.terminationPromise.succeed()
        case .terminated:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "App reported to have terminated after monitoring stopped",
                state: self.state
            ).log(to: self.tracingLogger, level: .error)
        case .monitoringCompleted:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "App reported to have terminated after monitoring stopped",
                state: self.state
            ).log(to: self.tracingLogger, level: .default)
        }

        self.state = .terminated
    }

    // This routine is guaranteed to be invoked once we make it to the point of calling ManagedApp.run(). That ensures
    // that the terminationPromise is completed.
    func monitoringCompleted(error: Error? = nil) async throws {
        defer {
            self.state = .monitoringCompleted
        }

        switch self.state {
        case .awaitingAppConnection, .connecting, .terminating:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "App monitoring stopped before receiving termination notification",
                state: self.state,
                error: error
            ).log(to: self.tracingLogger, level: .error)
            self.terminationPromise.fail(with: ManagedAppError.monitoringCompletedEarly(error))
            throw ManagedAppError.monitoringCompletedEarly(error)
        case .connected:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "cb_jobhelper monitoring stopped before receiving termination notification",
                state: self.state
            ).log(to: self.tracingLogger, level: .error)
        case .terminated:
            // terminationPromise fulfilled in clientTerminated()
            ()
        case .monitoringCompleted:
            ManagedAppStateMachineCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                appName: self.appName,
                message: "cb_jobhelper monitoring reported to have completed twice",
                state: self.state,
                error: ManagedAppError.monitoringCompletedMoreThanOnce
            ).log(to: self.tracingLogger, level: .error)
            throw ManagedAppError.monitoringCompletedMoreThanOnce
        }
    }
}

// Needed to safely de-queue messages after async calls.
extension ManagedAppStateMachine.State {
    var bufferedMessages: [ManagedAppStateMachine.ManagedAppMessage] {
        switch self {
        case .awaitingAppConnection(let messages, _, _):
            return messages
        case .connecting(let messages, _, _):
            return messages
        case .connected, .monitoringCompleted, .terminating, .terminated:
            return []
        }
    }

    var warmupInfo: ManagedWarmupInfo? {
        switch self {
        case .awaitingAppConnection(_, let info, _):
            return info
        case .connecting(_, let info, _):
            return info
        case .connected, .monitoringCompleted, .terminating, .terminated:
            return nil
        }
    }

    var parametersData: ParametersData? {
        switch self {
        case .awaitingAppConnection(_, _, let data):
            return data
        case .connecting(_, _, let data):
            return data
        case .connected, .monitoringCompleted, .terminating, .terminated:
            return nil
        }
    }

    mutating func nextBufferedMessage() -> ManagedAppStateMachine.ManagedAppMessage? {
        switch self {
        case .connecting(var bufferedInputData, let warmupInfo, let payloadData):
            guard bufferedInputData.count > 0 else { return nil }
            let data = bufferedInputData.removeFirst()
            self = .connecting(bufferedInputData, warmupInfo, payloadData)
            return data
        case .awaitingAppConnection, .connected, .terminating, .terminated, .monitoringCompleted:
            return nil
        }
    }
}

extension ManagedAppStateMachine {
    private func logMetadata(spanID: UInt64? = nil) -> CloudBoardJobHelperLogMetadata {
        return CloudBoardJobHelperLogMetadata(
            jobID: self.job.uuid,
            requestTrackingID: self.requestID,
            remotePID: self.remotePID,
            spanID: spanID
        )
    }
}

private struct ManagedAppStateMachineCheckpoint: RequestCheckpoint {
    var logMetadata: CloudBoardJobHelperLogMetadata
    var appName: String
    var requestID: String? { self.logMetadata.requestTrackingID }
    var operationName: StaticString
    var serviceName: StaticString = "cb_jobhelper"
    var namespace: StaticString = "cloudboard"
    var error: Error?
    var message: StaticString
    var state: ManagedAppStateMachine.State

    public init(
        logMetadata: CloudBoardJobHelperLogMetadata,
        appName: String,
        operationName: StaticString = #function,
        message: StaticString,
        state: ManagedAppStateMachine.State,
        error: Error? = nil
    ) {
        self.logMetadata = logMetadata
        self.appName = appName
        self.operationName = operationName
        self.message = message
        self.state = state
        if let error {
            self.error = error
        }
    }

    public func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        appName=\(self.appName, privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        state=\(self.state, privacy: .public)
        message=\(self.message, privacy: .public)
        """)
    }
}
