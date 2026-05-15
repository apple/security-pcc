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
import CloudBoardMetrics
import CryptoKit
import Foundation
import InternalSwiftProtobuf
import os

enum ManagedAppError: ReportableError {
    case tornDownBeforeRunning
    case unexpectedTerminationError(Error)
    case illegalStateAfterClientIsRunning(String)
    case illegalStateAfterClientIsConnected(String)
    case illegalStateAfterClientTerminationFailed(String)
    case illegalStateWhenSendingMessage(String, type: String)
    case appUnavailable(state: String)
    case monitoringCompletedEarly(Error?)
    case monitoringCompletedMoreThanOnce
    case jobNeverRan
    case alreadyTerminated
    case warmupFailed(Error)
    case tornDownBeforeWarmupFinished

    var publicDescription: String {
        let errorType = switch self {
        case .tornDownBeforeRunning: "tornDownBeforeRunning"
        case .unexpectedTerminationError(let error): "unexpectedTerminationError(\(String(reportable: error)))"
        case .illegalStateAfterClientIsRunning(let state): "illegalStateAfterClientIsRunning(\(state))"
        case .illegalStateAfterClientIsConnected(let state): "illegalStateAfterClientIsConnected(\(state))"
        case .illegalStateAfterClientTerminationFailed(let state): "illegalStateAfterClientTerminationFailed(\(state))"
        case .illegalStateWhenSendingMessage(let state, let type): "illegalStateWhenSendingMessage(\(state), \(type)"
        case .appUnavailable(let state): "appUnavailable(\(state))"
        case .monitoringCompletedEarly(let error):
            if let error {
                "monitoringCompletedEarly(\(String(reportable: error)))"
            } else {
                "monitoringCompletedEarly"
            }
        case .monitoringCompletedMoreThanOnce: "monitoringCompletedMoreThanOnce"
        case .jobNeverRan: "jobNeverRan"
        case .alreadyTerminated: "alreadyTerminated"
        case .warmupFailed(let error): "warmupFailed(\(String(reportable: error)))"
        case .tornDownBeforeWarmupFinished: "tornDownBeforeWarmupFinished"
        }
        return "ManagedAppError.\(errorType)"
    }
}

/// CloudBoardJobHelper-end of the XPC protocol.
///
/// The two protocols are subtly different due to the defined message (and more importantly their response) types,
/// as well as semantics of asynchronous message handler ordering.
package protocol ManagedAppResponseHandlerProtocol: Sendable {
    /// Called when the cloud app has experienced a terminal error
    func onInternalError() async throws

    /// Called when the main task (i.e. the run function) within the managed process finished
    func onJobFinished() async throws

    /// XPC connection has been disconnected. Cleanly or otherwise.
    ///
    /// No way of recovering from this.
    func onDisconnect(error: Error?) async

    /// Called when the managed process has terminated
    func onTermination(statusCode: Int?) async

    /// Allows specialized handlers to register handlers for XPC messages. Handlers should *not* register for
    /// ManagedAppToJobHelperXPCMessages messages that are shared across managed apps as these are already handled
    /// by ManagedApp itself and will result in corresponding pre-defined handler functions be called (see
    /// `onInternalError` and `onJobFinished`).
    func configureMessageHandlers(store: inout CloudBoardAsyncXPCConnection.MessageHandlerStore)
}

final class ManagedAppResponseHandler: ManagedAppResponseHandlerProtocol {
    private let specializedResponseHandler: ManagedAppResponseHandlerProtocol

    init(specializedResponseHandler: ManagedAppResponseHandlerProtocol) {
        self.specializedResponseHandler = specializedResponseHandler
    }

    func onInternalError() async throws {
        try await self.specializedResponseHandler.onInternalError()
    }

    func onJobFinished() async throws {
        try await self.specializedResponseHandler.onJobFinished()
    }

    func onDisconnect(error: (any Error)?) async {
        await self.specializedResponseHandler.onDisconnect(error: error)
    }

    func onTermination(statusCode: Int?) async {
        await self.specializedResponseHandler.onTermination(statusCode: statusCode)
    }

    func configureMessageHandlers(store: inout CloudBoardAsyncXPC.CloudBoardAsyncXPCConnection.MessageHandlerStore) {
        // Register common handlers
        store.register(ManagedAppToJobHelperXPCMessages.EndJob.self) { _ in
            try await self.onJobFinished()
            return ExplicitSuccess()
        }
        store.register(ManagedAppToJobHelperXPCMessages.InternalError.self) { _ in
            try await self.onInternalError()
            return ExplicitSuccess()
        }
        self.specializedResponseHandler.configureMessageHandlers(store: &store)
    }
}

internal protocol ManagedAppXPCClientFactoryProtocol: Sendable {
    func makeXPCClient(
        for job: LaunchdJobInstanceInitiatorProtocol,
        responseHandler: any ManagedAppResponseHandlerProtocol
    ) async throws -> ManagedAppXPCClient
}

struct ManagedAppXPCClientFactory: ManagedAppXPCClientFactoryProtocol {
    func makeXPCClient(
        for job: any LaunchdJobInstanceInitiatorProtocol,
        responseHandler: any ManagedAppResponseHandlerProtocol
    ) async throws -> ManagedAppXPCClient {
        let client = await ManagedAppXPCClient.localConnectionWithUUID(
            machServiceName: job.attributes.initMachServiceName,
            uuid: job.uuid,
            responseHandler: responseHandler
        )
        return client
    }
}

package protocol ManagedAppProtocol: Actor {
    var remotePID: Int? { get async }
    var abandoned: Bool { get async }

    func warmup(info: ManagedWarmupInfo) async throws
    func parameters(_ parametersData: ParametersData) async throws
    func teardown() async throws
    func abandon() async throws
}

final actor ManagedApp: ManagedAppProtocol, Sendable {
    private let appName: String
    private var stateMachine: ManagedAppStateMachine
    private let job: any LaunchdJobInstanceInitiatorProtocol

    private let tracingLogger: Logger
    private let logger: Logger
    private var requestID: String?
    private var spanID: UInt64?
    private let metrics: MetricsSystem

    private(set) var remotePID: Int?
    private static let uncleanTerminationExitCode: Int = -255

    public var abandoned: Bool {
        get async {
            return await self.stateMachine.abandoned
        }
    }

    init(
        definition: any LaunchdJobDefinitionProtocol,
        xpcClientFactory: any ManagedAppXPCClientFactoryProtocol,
        tracingLogger: Logger,
        logger: Logger,
        metrics: any MetricsSystem,
        jobUUID: UUID,
        spanID: UInt64?
    ) {
        self.tracingLogger = tracingLogger
        self.logger = logger
        self.appName = definition.attributes.cloudBoardJobName

        // Create a new job instance
        self.job = definition.createInstance(uuid: jobUUID)
        self.stateMachine = ManagedAppStateMachine(
            appName: self.appName,
            xpcClientFactory: xpcClientFactory,
            job: self.job,
            tracingLogger: tracingLogger,
            logger: logger,
            spanID: spanID
        )
        self.metrics = metrics
        self.spanID = spanID
    }

    func run(responseHandler: any ManagedAppResponseHandlerProtocol) async throws {
        let responseHandler = ManagedAppResponseHandler(specializedResponseHandler: responseHandler)

        await self.stateMachine.start()
        ManagedAppCheckpoint(
            jobID: self.job.uuid,
            appName: self.appName,
            requestID: self.requestID,
            remotePID: self.remotePID,
            spanID: self.spanID,
            message: "Running job",
            state: nil
        ).log(to: self.tracingLogger, level: .default)
        var lastKnownJobState: LaunchdJobEvents.State? = nil
        defer {
            ManagedAppCheckpoint(
                jobID: self.job.uuid,
                appName: self.appName,
                requestID: self.requestID,
                remotePID: self.remotePID,
                spanID: self.spanID,
                message: "Job finished",
                state: lastKnownJobState
            ).log(to: self.tracingLogger, level: .default)
        }
        do {
            for try await state in self.job.startAndWatch() {
                lastKnownJobState = state
                ManagedAppCheckpoint(
                    jobID: self.job.uuid,
                    appName: self.appName,
                    requestID: self.requestID,
                    remotePID: self.remotePID,
                    spanID: self.spanID,
                    message: "Job state changed",
                    state: state
                ).log(to: self.tracingLogger, level: .info)
                switch state {
                case .initialized, .created, .starting:
                    // Nothing to do
                    ()
                case .running(let pid):
                    self.remotePID = pid
                    try await self.stateMachine.clientIsRunning(pid: pid, responseHandler: responseHandler)
                case .terminated(let terminationCondition):
                    if case .cloudBoardApp = self.job.attributes.cloudBoardJobType {
                        terminationCondition.emitMetrics(
                            metricsSystem: self.metrics,
                            counterFactory: Metrics.Workload.CloudAppExitCounter.Factory()
                        )
                    } else if case .cloudBoardSupportApp = self.job.attributes.cloudBoardJobType {
                        terminationCondition.emitMetrics(
                            metricsSystem: self.metrics,
                            counterFactory: Metrics.Workload.SupportAppExitCounter.Factory(
                                dimensions: [.appName: self.appName]
                            ),
                        )
                    }

                    let statusCode: Int? = if case .exited(let status) = terminationCondition {
                        switch status {
                        case .osStatus(_, let code):
                            code
                        case .wait4Status(let code):
                            code
                        case .unknown:
                            nil
                        @unknown default:
                            nil
                        }
                    } else if case .uncleanShutdown = terminationCondition {
                        Self.uncleanTerminationExitCode
                    } else {
                        nil
                    }
                    await self.stateMachine.clientTerminated(statusCode: statusCode)
                    await responseHandler.onTermination(statusCode: statusCode)
                case .neverRan:
                    await self.stateMachine.clientTerminated(statusCode: nil)
                    await responseHandler.onTermination(statusCode: nil)
                }
            }
            try await self.stateMachine.monitoringCompleted()
        } catch {
            ManagedAppCheckpoint(
                jobID: self.job.uuid,
                appName: self.appName,
                requestID: self.requestID,
                remotePID: self.remotePID,
                spanID: self.spanID,
                message: "Error while monitoring CloudApp, no longer monitoring",
                state: lastKnownJobState,
                error: error
            ).log(to: self.tracingLogger, level: .error)
            await responseHandler.onTermination(statusCode: nil)
            try await self.stateMachine.monitoringCompleted(error: error)
            throw error
        }
    }

    public func warmup(info: ManagedWarmupInfo) async throws {
        try await self.stateMachine.warmup(info: info)
    }

    public func parameters(_ parametersData: ParametersData) async throws {
        self.requestID = parametersData.plaintextMetadata.requestID
        try await self.stateMachine.parameters(parametersData)
    }

    public func abandon() async throws {
        try await self.stateMachine.abandon()
    }

    public func teardown() async throws {
        try await self.stateMachine.teardown()
    }

    /// Sends XPC message to the connected app.
    ///
    /// Will fail if not yet connected to the app. Currently only used for messages expected to be sent to the app
    /// in response to messages sent from the app, ensuring that the connection must have previously established.
    ///
    /// - Parameter message: The message to send.
    public func send<Message: CloudBoardAsyncXPCByteBufferMessage>(_ message: Message) async throws -> Message.Success {
        return try await self.stateMachine.send(message)
    }

    /// Sends XPC message to the connected app.
    ///
    /// Will fail if not yet connected to the app. Currently only used for messages expected to be sent to the app
    /// in response to messages sent from the app, ensuring that the connection must have previously established.
    ///
    /// - Parameter message: The message to send.
    public func send<Message: CloudBoardAsyncXPCCodableMessage>(_ message: Message) async throws -> Message.Success {
        return try await self.stateMachine.send(message)
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
    public func sendOrBuffer<Message: CloudBoardAsyncXPCByteBufferMessage>(
        _ message: Message,
        ignoreOnTermination: Bool = false
    ) async throws
    where Message.Success == ExplicitSuccess {
        return try await self.stateMachine.sendOrBuffer(message, ignoreOnTermination: ignoreOnTermination)
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
    public func sendOrBuffer<Message: CloudBoardAsyncXPCCodableMessage>(
        _ message: Message,
        ignoreOnTermination: Bool = false
    ) async throws
    where Message.Success == ExplicitSuccess {
        return try await self.stateMachine.sendOrBuffer(message, ignoreOnTermination: ignoreOnTermination)
    }
}

extension ManagedApp {
    /// Testing only: handle of the underlying Launchd job
    var _testJobInitiator: any LaunchdJobInstanceInitiatorProtocol {
        self.job
    }
}

struct ManagedAppCheckpoint: RequestCheckpoint {
    private(set) var jobID: UUID
    private(set) var requestID: String?
    private(set) var remotePID: Int?
    let appName: String
    var operationName: StaticString
    var serviceName: StaticString = "cb_jobhelper"
    var namespace: StaticString = "cloudboard"
    var error: Error?
    var message: StaticString
    var state: LaunchdJobEvents.State?
    var spanID: UInt64?

    public init(
        jobID: UUID,
        appName: String,
        requestID: String?,
        remotePID _: Int?,
        spanID: UInt64?,
        operationName: StaticString = #function,
        message: StaticString,
        state: LaunchdJobEvents.State?,
        error: Error? = nil
    ) {
        self.jobID = jobID
        self.appName = appName
        self.requestID = requestID
        self.spanID = spanID
        self.operationName = operationName
        self.state = state
        self.message = message
        if let error {
            self.error = error
        }
    }

    public func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.jobID.uuidString, privacy: .public)
        appName=\(self.appName, privacy: .public)
        remotePid=\(self.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        state=\(String(describing: self.state), privacy: .public)
        """)
    }
}
