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

import CloudBoardAsyncXPC
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import InternalSwiftProtobuf
import os

/// Models CloudBoardJobHelper side of the API with the CloudApp workload.
///
/// Manages the state of the CloudApp process, including launching, warming it up and tearing it down,
/// monitors the state of the process, buffers any messages to the process as required,
/// and provides an interface to make calls to the workload as well as a `responseStream`.
package protocol ManagedCloudAppProtocol: ManagedAppProtocol, Actor {
    nonisolated var responseStream: AsyncThrowingStream<CloudBoardJobHelperCore.CloudAppResponse, any Error> { get }
    // Defined on construction so safe to use from any context
    nonisolated var cloudAppName: String { get }

    func run() async throws
    func provideInput(_ data: Data) async throws
    func openClientSubrequest(
        subrequestId: UInt64,
        cryptoMaterialHandles: [CryptoMaterialHandle],
        isDiscardable: Bool
    ) async throws
    func subrequestPayloadChunk(subrequestId: UInt64, chunk: Data) async throws
    func closeClientSubrequest(subrequestId: UInt64) async throws
    func cancelClientSubrequest(subrequestId: UInt64) async throws
    func endOfInput(error: Error?) async throws
    func workerFound(workerID: UUID, info: WorkerFoundInfo, spanID: UInt64?) async throws
    func workerResponseMessage(workerID: UUID, data: Data?, isFinal: Bool) async throws
    func workerResponseSummary(workerID: UUID, status: WorkerResponseStatus) async throws
    func workerFailure(workerID: UUID, rawROPESCode: UInt32, ropesMessage: String?) async throws
    func configureApplicationDataChunking(config: ApplicationDataChunkingConfiguration) async throws
    func clientDiagnosticsSharingOptIn(_ optedIn: Bool) async throws
    func sendPersistentServiceResponse(_ response: PersistentService.Response) async throws
}

private typealias JobHelperToCloudAppMessage = CloudBoardJobAPIXPCClientToServerMessage

actor ManagedCloudApp: ManagedCloudAppProtocol, ManagedAppResponseHandlerProtocol {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ManagedCloudApp"
    )

    private static let tracingLogger = Logger(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "ManagedCloudApp"
    )

    private let jobUUID: UUID
    private var requestID: String?
    private var spanID: UInt64?
    private let metrics: MetricsSystem

    private let managedApp: ManagedApp
    let cloudAppName: String

    /// Provides access to request secrets such as the DEK need to derive new secrets from client-provided key material
    private let requestSecrets: RequestSecrets
    /// Provides support for Private Information Retrieval (PIR)
    private let pirHelper: PIRHelperProtocol
    private let toolInvocationHelper: ToolInvocationHelperProtocol
    /// If set, find worker XPC calls require the calling process to have a corresponding entitlement
    private let enforceCloudAppEntitlements: Bool

    public var remotePID: Int? {
        get async {
            return await self.managedApp.remotePID
        }
    }

    public var abandoned: Bool {
        get async {
            return await self.managedApp.abandoned
        }
    }

    private nonisolated let (cloudAppResponseStream, cloudAppResponseContinuation) = AsyncThrowingStream<
        CloudAppResponse,
        any Error
    >.makeStream()

    public nonisolated var responseStream: AsyncThrowingStream<CloudAppResponse, any Error> {
        self.cloudAppResponseStream
    }

    init(
        cloudAppName: String,
        definition: any LaunchdJobDefinitionProtocol,
        xpcClientFactory: any ManagedAppXPCClientFactoryProtocol,
        requestSecrets: RequestSecrets,
        pirHelper: PIRHelperProtocol,
        toolInvocationHelper: ToolInvocationHelperProtocol,
        // this would only be false in unit tests
        enforceCloudAppEntitlements: Bool = true,
        metrics: any MetricsSystem,
        jobUUID: UUID,
        spanID: UInt64?
    ) throws {
        self.cloudAppName = cloudAppName
        self.jobUUID = jobUUID
        self.requestSecrets = requestSecrets
        self.pirHelper = pirHelper
        self.toolInvocationHelper = toolInvocationHelper
        self.enforceCloudAppEntitlements = enforceCloudAppEntitlements
        self.metrics = metrics
        self.spanID = spanID
        self.managedApp = ManagedApp(
            definition: definition,
            xpcClientFactory: xpcClientFactory,
            tracingLogger: Self.tracingLogger,
            logger: Self.logger,
            metrics: metrics,
            jobUUID: jobUUID,
            spanID: spanID
        )
    }

    func run() async throws {
        do {
            try await self.managedApp.run(responseHandler: self)
            self.cloudAppResponseContinuation.finish()
        } catch {
            self.cloudAppResponseContinuation.finish(throwing: error)
            throw error
        }
    }

    func onTermination(statusCode: Int?) {
        self.cloudAppResponseContinuation.yield(.appTermination(.init(statusCode: statusCode)))
    }

    func onDisconnect(error _: (any Error)?) async {
        // Nothing we can do here but log because we already handle cloud app termination and finish the
        // cloudAppResponseContinuation in the onTermination callback.
        await ManagedCloudAppCheckpoint(
            jobID: self.jobUUID,
            requestID: self.requestID,
            remotePID: self.managedApp.remotePID,
            spanID: self.spanID,
            message: "Cloud app disconnected",
        ).log(to: Self.tracingLogger, level: .default)
    }

    func onInternalError() async throws {
        self.cloudAppResponseContinuation.yield(.internalError)
    }

    func onJobFinished() async throws {
        self.cloudAppResponseContinuation.yield(.endJob)
    }

    // MARK: Jobhelper to Cloud App messages/events

    public func warmup(info: ManagedWarmupInfo) async throws {
        try await self.managedApp.warmup(info: info)
    }

    public func parameters(_ parametersData: ParametersData) async throws {
        self.requestID = parametersData.plaintextMetadata.requestID
        try await self.managedApp.parameters(parametersData)
    }

    public func abandon() async throws {
        try await self.managedApp.abandon()
    }

    public func teardown() async throws {
        try await self.managedApp.teardown()
    }

    func provideInput(_ data: Data) async throws {
        let requestChunk = JobHelperToCloudAppMessage.RequestChunk(data: data)
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.requestChunk(requestChunk)
        try await self.managedApp.sendOrBuffer(message)
    }

    func configureApplicationDataChunking(config: ApplicationDataChunkingConfiguration) async throws {
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest
            .configureApplicationDataChunking(config)
        try await self.managedApp.sendOrBuffer(message)
    }

    func clientDiagnosticsSharingOptIn(_ optedIn: Bool) async throws {
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest
            .clientDiagnosticsSharingOptIn(optedIn)
        try await self.managedApp.sendOrBuffer(message)
    }

    func openClientSubrequest(
        subrequestId: UInt64,
        cryptoMaterialHandles: [CryptoMaterialHandle],
        isDiscardable: Bool
    ) async throws {
        let openRequest = JobHelperToCloudAppMessage.OpenClientSubrequest(
            clientSubrequestID: subrequestId,
            cryptoMaterialHandles: cryptoMaterialHandles,
            isDiscardable: isDiscardable
        )
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.openClientSubrequest(openRequest)
        try await self.managedApp.sendOrBuffer(message)
    }

    func subrequestPayloadChunk(subrequestId: UInt64, chunk: Data) async throws {
        let payloadMessage = JobHelperToCloudAppMessage.SubrequestPayloadChunk(
            clientSubrequestID: subrequestId,
            chunk: chunk
        )
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.subrequestPayloadChunk(payloadMessage)
        try await self.managedApp.sendOrBuffer(message)
    }

    func closeClientSubrequest(subrequestId: UInt64) async throws {
        let closeRequest = JobHelperToCloudAppMessage.CloseClientSubrequest(clientSubrequestID: subrequestId)
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.closeClientSubrequest(closeRequest)
        try await self.managedApp.sendOrBuffer(message)
    }

    func cancelClientSubrequest(subrequestId: UInt64) async throws {
        let cancellationRequest = JobHelperToCloudAppMessage.CancelClientSubrequest(clientSubrequestID: subrequestId)
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.cancelClientSubrequest(cancellationRequest)
        try await self.managedApp.sendOrBuffer(message)
    }

    /// Signals the end of input
    /// - Parameter error: error in case the input stream failed instead of finishing cleanly
    func endOfInput(error: Error? = nil) async throws {
        if let error {
            // Should only teardown the cloudApp after the error is propagated back
            // Else there would be a race between the app terminating and finishing
            // the continuation, before retuning the error
            self.cloudAppResponseContinuation.finish(throwing: error)
            try await self.abandon()
        } else {
            let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.endOfInput
            try await self.managedApp.sendOrBuffer(message, ignoreOnTermination: true)
        }
    }

    public func workerFound(workerID: UUID, info: WorkerFoundInfo, spanID: UInt64?) async throws {
        let workerFound = JobHelperToCloudAppMessage.WorkerFound(workerID: workerID, info: info)
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.receiveWorkerFoundEvent(workerFound)
        do {
            _ = try await self.managedApp.send(message)
        } catch ManagedAppError.alreadyTerminated {
            // Nothing we can do if the app has already terminated, so let's log this and otherwise ignore the error
            await ManagedCloudAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: spanID,
                message: "Failed to send WorkerFound message because app has already terminated",
                error: ManagedAppError.alreadyTerminated
            ).log(to: Self.tracingLogger, level: .info)
        }
    }

    func workerResponseMessage(workerID: UUID, data: Data?, isFinal: Bool) async throws {
        do {
            if let data {
                let workerResponse = JobHelperToCloudAppMessage.WorkerResponse(
                    workerID: workerID,
                    message: .payload(data)
                )
                let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.receiveWorkerMessage(workerResponse)
                _ = try await self.managedApp.send(message)
            }

            if isFinal {
                let workerEOF = JobHelperToCloudAppMessage.WorkerEOF(workerID: workerID)
                let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.receiveWorkerEOF(workerEOF)
                _ = try await self.managedApp.send(message)
            }
        } catch ManagedAppError.alreadyTerminated {
            // Nothing we can do if the app has already terminated, so let's log this and otherwise ignore the error
            await ManagedCloudAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: self.spanID,
                message: "Failed to send worker response message because app has already terminated",
                error: ManagedAppError.alreadyTerminated
            ).log(to: Self.tracingLogger, level: .info)
        }
    }

    func workerResponseSummary(workerID: UUID, status: WorkerResponseStatus) async throws {
        let responseSummary = JobHelperToCloudAppMessage.WorkerResponseSummary(workerID: workerID, status: status)
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.receiveWorkerResponseSummary(responseSummary)
        do {
            _ = try await self.managedApp.send(message)
        } catch ManagedAppError.alreadyTerminated {
            // Nothing we can do if the app has already terminated, so let's log this and otherwise ignore the error
            await ManagedCloudAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: self.spanID,
                message: "Failed to send worker response summary message because app has already terminated",
                error: ManagedAppError.alreadyTerminated
            ).log(to: Self.tracingLogger, level: .info)
        }
    }

    func workerFailure(workerID: UUID, rawROPESCode: UInt32, ropesMessage: String?) async throws {
        let workerFailure = JobHelperToCloudAppMessage.WorkerFailure(
            workerID: workerID,
            rawROPESCode: rawROPESCode,
            ropesMessage: ropesMessage
        )
        let message = JobHelperToCloudAppMessage.InvokeWorkloadRequest.receiveWorkerFailure(workerFailure)
        do {
            _ = try await self.managedApp.send(message)
        } catch ManagedAppError.alreadyTerminated {
            await ManagedCloudAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: self.spanID,
                message: "Failed to send worker failure message because app has already terminated",
                error: ManagedAppError.alreadyTerminated
            ).log(to: Self.tracingLogger, level: .info)
        }
    }

    // MARK: Cloud app to jobhelper messages/events

    nonisolated func configureMessageHandlers(store: inout CloudBoardAsyncXPCConnection.MessageHandlerStore) {
        let cloudAppResponseContinuation = self.cloudAppResponseContinuation
        // Posted messages
        store.register(DataMessage.self) { message in
            cloudAppResponseContinuation.yield(.chunk(message.data))
        }
        store.register(WorkerRequestMessage.self) { workerRequestMessage in
            cloudAppResponseContinuation.yield(.workerRequestMessage(
                workerRequestMessage.workerID,
                workerRequestMessage.message
            ))
        }
        store.register(WorkerEOF.self) { workerEOF in
            cloudAppResponseContinuation.yield(.workerRequestEOF(workerEOF.workerID, workerEOF.isError))
        }
        store.register(FinalizeRequestExecutionLog.self) { _ in
            cloudAppResponseContinuation.yield(.finalizeRequestExecutionLog)
        }
        store.register(SubresponsePayload.self) { subresponsePayloadMessage in
            cloudAppResponseContinuation.yield(.subresponsePayload(
                subresponsePayloadMessage.subresponseID,
                subresponsePayloadMessage.payload
            ))
        }

        // Messages with explicit response
        store.register(FindWorkerMessage.self, handler: self.handleFindWorker)
        store.register(EndOfResponse.self, handler: self.handleEndOfResponse)
        store.register(CloudAppToJobHelperPIRMessage.self, handler: self.handlePIRRequest)
        store.register(EndOfSubresponse.self) { subresponseEOF in
            cloudAppResponseContinuation.yield(.endOfSubresponse(subresponseEOF.subresponseID, subresponseEOF.status))
            return ExplicitSuccess()
        }
        store.register(CloudAppToJobHelperRequestExecutionError.self, handler: self.handleRequestExecutionError)
        store.register(PCCToolInvocationMessage.self, handler: self.handleToolInvocationRequest)
        store.register(ComponentTimeMeasurement.self, handler: self.handleComponentTimeMeasurement)
        store.register(
            CloudAppToJobHelperPersistentServiceQuery.self
        ) { query in
            cloudAppResponseContinuation.yield(.persistentServiceQuery(
                query.identity,
                query.payload,
                query.correlationID,
                query.timeout
            ))
        }
        store.register(
            CloudAppToJobHelperPersistentServiceInformBlocked.self,
            handler: self.handlePersistentServiceInformBlocked
        )
    }

    nonisolated func handleResponseChunk(_ chunk: DataMessage) {
        self.cloudAppResponseContinuation.yield(.chunk(chunk.data))
    }

    nonisolated func handleWorkerRequestMessage(_ workerRequestMessage: WorkerRequestMessage) {
        self.cloudAppResponseContinuation.yield(.workerRequestMessage(
            workerRequestMessage.workerID,
            workerRequestMessage.message
        ))
    }

    nonisolated func handleWorkerEOF(_ workerEOF: WorkerEOF) {
        self.cloudAppResponseContinuation.yield(.workerRequestEOF(workerEOF.workerID, workerEOF.isError))
    }

    nonisolated func handleFinalizeRequestExecutionLog(_: FinalizeRequestExecutionLog) {
        self.cloudAppResponseContinuation.yield(.finalizeRequestExecutionLog)
    }

    nonisolated func handleSubresponsePayload(_ subresponsePayloadMessage: SubresponsePayload) {
        self.cloudAppResponseContinuation.yield(.subresponsePayload(
            subresponsePayloadMessage.subresponseID,
            subresponsePayloadMessage.payload
        ))
    }

    nonisolated func handleEndOfSubresponse(_ subresponseEOF: EndOfSubresponse) -> ExplicitSuccess {
        self.cloudAppResponseContinuation.yield(.endOfSubresponse(subresponseEOF.subresponseID, subresponseEOF.status))
        return ExplicitSuccess()
    }

    func handleFindWorker(_ findWorkerMessage: FindWorkerMessage) async throws -> ExplicitSuccess {
        guard let xpcConnection = CloudBoardAsyncXPCContext.context?.peerConnection else {
            // This is a programming error, there is no condition where we would get a message but not have
            // a `peerConnection` available.
            assertionFailure("xpcConnection not available")
            Self.logger.error("xpcConnection not available")
            return ExplicitSuccess()
        }
        let hasEntitlement = await xpcConnection.hasEntitlement(kCloudBoardJobAPIOutboundPCCRequestEntitlement)
        if self.enforceCloudAppEntitlements {
            guard hasEntitlement else {
                Self.logger.error("Cloud app not entitled to make outbound pcc requests")
                fatalError("Cloud app not entitled to make outbound pcc requests")
            }
        } else {
            if !hasEntitlement {
                Self.logger.error("Cloud app not entitled to make outbound pcc requests but this check is disabled")
            }
        }
        self.cloudAppResponseContinuation.yield(.findWorker(
            findWorkerMessage.query,
            findWorkerMessage.subrequestID,
            findWorkerMessage.cryptoMaterialHandles
        ))
        return ExplicitSuccess()
    }

    func handleEndOfResponse(_: EndOfResponse) async throws -> ExplicitSuccess {
        self.cloudAppResponseContinuation.yield(.endOfResponse)
        return ExplicitSuccess()
    }

    func handlePIRRequest(_ pirMessage: CloudAppToJobHelperPIRMessage) async throws -> CloudBoardJobAPIPIRResponse {
        guard let xpcConnection = CloudBoardAsyncXPCContext.context?.peerConnection else {
            // This is a programming error, there is no condition where we would get a message but not have
            // a `peerConnection` available.
            assertionFailure("xpcConnection not available")
            Self.logger.error("xpcConnection not available")
            throw CloudAppToJobHelperPIRError.internalError
        }
        let hasEntitlement = await xpcConnection.hasEntitlement(kCloudBoardJobAPIOutboundPIRRequestEntitlement)
        if self.enforceCloudAppEntitlements {
            guard hasEntitlement else {
                Self.logger.error("CloudApp not entitled to make outbound PIR requests")
                fatalError("CloudApp not entitled to make outbound PIR requests")
            }
        } else {
            if !hasEntitlement {
                Self.logger
                    .error("CloudApp not entitled to make outbound PIR requests but this check is disabled")
            }
        }

        let pirRequestID = pirMessage.request.traceContext.pirRequestID
        let pirSpanID = pirMessage.request.traceContext.spanID
        let requestPayload = pirMessage.request.payload
        await ManagedCloudAppCheckpoint(
            jobID: self.jobUUID,
            requestID: self.requestID,
            remotePID: self.managedApp.remotePID,
            spanID: pirSpanID,
            message: "Received PIR request from cloud app"
        ).log(to: Self.tracingLogger, level: .info, pirRequestID: pirRequestID)
        do {
            let responsePayload = try await self.pirHelper.makeRequest(
                requestPayload: requestPayload,
                traceContext: pirMessage.request.traceContext
            )
            return CloudBoardJobAPIPIRResponse(payload: responsePayload)
        } catch {
            await ManagedCloudAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: pirMessage.request.traceContext.spanID,
                message: "Failed to make PIR request",
                error: error
            ).log(to: Self.tracingLogger, level: .error, pirRequestID: pirRequestID)
            throw error
        }
    }

    func handleRequestExecutionError(_ error: CloudAppToJobHelperRequestExecutionError) async throws
    -> ExplicitSuccess {
        self.cloudAppResponseContinuation.yield(.reportRequestExecutionError(error.error))
        return ExplicitSuccess()
    }

    func handleToolInvocationRequest(_ toolInvocationMessage: PCCToolInvocationMessage) async throws
    -> PCCToolInvocationResponse {
        guard let xpcConnection = CloudBoardAsyncXPCContext.context?.peerConnection else {
            // This is a programming error, there is no condition where we would get a message but not have
            // a `peerConnection` available.
            assertionFailure("xpcConnection not available")
            Self.logger.error("xpcConnection not available")
            throw PCCToolInvocationError.internalError
        }

        let hasEntitlement = await xpcConnection
            .hasEntitlement(kCloudBoardJobAPIOutboundToolInvocationRequestEntitlement)
        if self.enforceCloudAppEntitlements {
            guard hasEntitlement else {
                Self.logger.error("CloudApp not entitled to make outbound Tool Invocation requests")
                fatalError("CloudApp not entitled to make outbound Tool Invocation requests")
            }
        } else {
            if !hasEntitlement {
                Self.logger
                    .error("CloudApp not entitled to make outbound Tool Invocation requests but this check is disabled")
            }
        }

        await ManagedCloudAppCheckpoint(
            jobID: self.jobUUID,
            requestID: self.requestID,
            remotePID: self.managedApp.remotePID,
            spanID: toolInvocationMessage.request.traceContext.spanID,
            operationName: "handle_tool_invocation_request",
            message: "Received Tool Invocation request from cloud app"
        ).log(
            to: Self.tracingLogger,
            level: .info,
            toolInvocationRequestID: toolInvocationMessage.request.traceContext.toolInvocationID
        )

        do {
            // Sending JSON serialized Tool Invocation request data to client via Request Execution Log
            self.cloudAppResponseContinuation.yield(.outboundCallNotification(.toolCall))
            try self.cloudAppResponseContinuation.yield(.sendOutboundCallRequestExecutionLog(
                PCCToolInvocationRequest.outboundCallServiceName,
                toolInvocationMessage.request.serialize()
            ))
            return try await self.toolInvocationHelper.makeRequest(
                request: toolInvocationMessage.request,
            )
        } catch {
            await ManagedCloudAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: toolInvocationMessage.request.traceContext.spanID,
                operationName: "handle_tool_invocation_request",
                message: "Failed to make ToolInvocation request",
                error: error
            ).log(
                to: Self.tracingLogger,
                level: .error,
                toolInvocationRequestID: toolInvocationMessage.request.traceContext.toolInvocationID
            )
            throw error
        }
    }

    func handleComponentTimeMeasurement(
        _ measurement: ComponentTimeMeasurement
    ) async throws -> ExplicitSuccess {
        self.cloudAppResponseContinuation.yield(.componentTimeMeasurement(measurement))
        return ExplicitSuccess()
    }

    nonisolated func handlePersistentServiceQuery(
        _ query: CloudAppToJobHelperPersistentServiceQuery
    ) {
        self.cloudAppResponseContinuation.yield(.persistentServiceQuery(
            query.identity,
            query.payload,
            query.correlationID,
            query.timeout
        ))
    }

    func handlePersistentServiceInformBlocked(
        _ message: CloudAppToJobHelperPersistentServiceInformBlocked
    ) async throws -> ExplicitSuccess {
        self.cloudAppResponseContinuation.yield(.persistentServiceInformBlocked(
            message.correlationIDs
        ))
        return ExplicitSuccess()
    }

    /// Send a persistent service response back to the cloud app
    func sendPersistentServiceResponse(_ response: PersistentService.Response) async throws {
        let message = JobHelperToCloudAppPersistentServiceResponse(response: response)
        do {
            _ = try await self.managedApp.send(message)
        } catch ManagedAppError.alreadyTerminated {
            await ManagedCloudAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: self.spanID,
                message: "Failed to send persistent service response because app has already terminated",
                error: ManagedAppError.alreadyTerminated
            ).log(to: Self.tracingLogger, level: .info)
        }
    }
}

extension ManagedCloudApp {
    /// Testing only: handle of the underlying Launchd job
    var _testJobInitiator: any LaunchdJobInstanceInitiatorProtocol {
        get async {
            await self.managedApp._testJobInitiator
        }
    }
}

extension ParametersData {
    package init(
        _ data: CloudBoardJobHelperAPI.Parameters,
        nodeAppData: [String: Data],
        launchdJobInstanceUUID: UUID,
        supportApps: [String]
    ) {
        self.init(
            parametersReceived: data.parametersReceived,
            plaintextMetadata: .init(
                data.plaintextMetadata,
                requestID: data.requestID
            ),
            requestBypassed: data.requestBypassed,
            traceContext: .init(traceID: data.traceContext.traceID, spanID: data.traceContext.spanID),
            nodeAppData: .init(
                rackID: nodeAppData[ComputeNodeAppDataKeys.rackID],
                bootID: nodeAppData[ComputeNodeAppDataKeys.bootID],
                ensembleID: nodeAppData[ComputeNodeAppDataKeys.ensembleID]
            ),
            launchdJobInstanceUUID: launchdJobInstanceUUID,
            supportApps: supportApps
        )
    }
}

extension ParametersData.PlaintextMetadata {
    init(_ data: CloudBoardJobHelperAPI.Parameters.PlaintextMetadata, requestID: String) {
        self.init(
            bundleID: data.bundleID,
            bundleVersion: data.bundleVersion,
            featureID: data.featureID,
            clientInfo: data.clientInfo,
            workloadType: data.workloadType,
            workloadParameters: data.workloadParameters,
            requestID: requestID,
            automatedDeviceGroup: data.automatedDeviceGroup
        )
    }
}

struct ManagedCloudAppCheckpoint: RequestCheckpoint {
    private(set) var jobID: UUID
    private(set) var requestID: String?
    private(set) var remotePID: Int?
    var operationName: StaticString
    var serviceName: StaticString = "cb_jobhelper"
    var namespace: StaticString = "cloudboard"
    var error: Error?
    var message: StaticString
    var spanID: UInt64?

    public init(
        jobID: UUID,
        requestID: String?,
        remotePID: Int?,
        spanID: UInt64?,
        operationName: StaticString = #function,
        message: StaticString,
        error: Error? = nil
    ) {
        self.jobID = jobID
        self.requestID = requestID
        self.remotePID = remotePID
        self.spanID = spanID
        self.operationName = operationName
        self.message = message
        if let error {
            self.error = error
        }
    }

    public func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.jobID.uuidString, privacy: .public)
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
        """)
    }

    func log(to logger: Logger, level: OSLogType = .default, pirRequestID: String) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.jobID.uuidString, privacy: .public)
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
        pir.request.uuid=\(pirRequestID, privacy: .public)
        """)
    }

    func log(to logger: Logger, level: OSLogType = .default, toolInvocationRequestID: String) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.jobID.uuidString, privacy: .public)
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
        toolInvocation.request.uuid=\(toolInvocationRequestID, privacy: .public)
        """)
    }
}
