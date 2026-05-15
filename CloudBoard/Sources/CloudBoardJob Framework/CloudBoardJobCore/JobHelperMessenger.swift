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

internal import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
internal import CloudBoardLogging
import Foundation
import os
internal import Synchronization
import CryptoKit
import XPCPrivate

private enum WarmupState {
    case idle
    case waiting(Promise<Void, Error>)
    case warmupInProgress(Promise<Void, Error>?)
    case complete(Error?)
}

enum WarmupStateError: Error {
    case waitInvokedWhileAlreadyWaiting
    case waitInvokedWhileInProgressWithContinuationSet
    case warmupInvokedMoreThanOnce
    case warmupInvokedAfterComplete
    case warmupNeverCalled
    case foundWaitingAfterWarmupFinished
    case foundCompleteAfterWarmupFinished
    case foundIdleAfterWarmupFinished
}

extension WarmupStateError: RequestExecutionErrorProtocol {
    var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.cloudAppFramework
    }

    var staticStringRepresentation: StaticString {
        switch self {
        case .waitInvokedWhileAlreadyWaiting: "waitInvokedWhileAlreadyWaiting"
        case .waitInvokedWhileInProgressWithContinuationSet: "waitInvokedWhileInProgressWithContinuationSet"
        case .warmupInvokedMoreThanOnce: "warmupInvokedMoreThanOnce"
        case .warmupInvokedAfterComplete: "warmupInvokedAfterComplete"
        case .warmupNeverCalled: "warmupNeverCalled"
        case .foundWaitingAfterWarmupFinished: "foundWaitingAfterWarmupFinished"
        case .foundCompleteAfterWarmupFinished: "foundCompleteAfterWarmupFinished"
        case .foundIdleAfterWarmupFinished: "foundIdleAfterWarmupFinished"
        }
    }

    var errorCode: UInt32 {
        switch self {
        case .waitInvokedWhileAlreadyWaiting: CloudAppFrameworkErrorCodes.waitInvokedWhileAlreadyWaiting.rawValue
        case .waitInvokedWhileInProgressWithContinuationSet: CloudAppFrameworkErrorCodes
            .waitInvokedWhileInProgressWithContinuationSet.rawValue
        case .warmupInvokedMoreThanOnce: CloudAppFrameworkErrorCodes.warmupInvokedMoreThanOnce.rawValue
        case .warmupInvokedAfterComplete: CloudAppFrameworkErrorCodes.warmupInvokedAfterComplete.rawValue
        case .warmupNeverCalled: CloudAppFrameworkErrorCodes.warmupNeverCalled.rawValue
        case .foundWaitingAfterWarmupFinished: CloudAppFrameworkErrorCodes.foundWaitingAfterWarmupFinished.rawValue
        case .foundCompleteAfterWarmupFinished: CloudAppFrameworkErrorCodes.foundCompleteAfterWarmupFinished.rawValue
        case .foundIdleAfterWarmupFinished: CloudAppFrameworkErrorCodes.foundIdleAfterWarmupFinished.rawValue
        }
    }
}

enum JobHelperMessengerError: Error, Equatable {
    case waitForWarmupCalledAfterEndJob
    case parametersReceivedTwice
    case waitForParametersCalledAfterEndJob
    case provideOutputCalledAfterEndJob
    case endOfResponseCalledAfterEndJob
    case endJobCalledMoreThanOnce
    case tornDownBeforeParametersReceived
    case pccRequestCalledAfterEndJob
    case unknownPCCWorkerID
    case workerFoundResultReceivedTwice
    case workerFoundResultNotReceived
    case unknownSubrequestID(UInt32)
    case openSubreqeustCalledBeforeParametersReceived
    case subrequestAlreadyClosed(UInt32)
    case subrequestAlreadyOpened(UInt32)
    case workerRequestDiscardedForSingleModeRequest
    case missingApplicationDataChunkingConfig
    case receivedDuplicateApplicationDataChunkingConfig
    case unknownError
}

extension JobHelperMessengerError: RequestExecutionErrorProtocol {
    var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.cloudAppFramework
    }

    var staticStringRepresentation: StaticString {
        switch self {
        case .waitForWarmupCalledAfterEndJob: "waitForWarmupCalledAfterEndJob"
        case .parametersReceivedTwice: "parametersReceivedTwice"
        case .waitForParametersCalledAfterEndJob: "waitForParametersCalledAfterEndJob"
        case .provideOutputCalledAfterEndJob: "provideOutputCalledAfterEndJob"
        case .endOfResponseCalledAfterEndJob: "endOfResponseCalledAfterEndJob"
        case .endJobCalledMoreThanOnce: "endJobCalledMoreThanOnce"
        case .tornDownBeforeParametersReceived: "tornDownBeforeParametersReceived"
        case .pccRequestCalledAfterEndJob: "pccRequestCalledAfterEndJob"
        case .unknownPCCWorkerID: "unknownPCCWorkerID"
        case .workerFoundResultReceivedTwice: "workerFoundResultReceivedTwice"
        case .workerFoundResultNotReceived: "workerFoundResultNotReceived"
        case .unknownSubrequestID: "unknownSubrequestID"
        case .openSubreqeustCalledBeforeParametersReceived: "openSubreqeustCalledBeforeParametersReceived"
        case .subrequestAlreadyClosed: "subrequestAlreadyClosed"
        case .subrequestAlreadyOpened: "subrequestAlreadyOpened"
        case .workerRequestDiscardedForSingleModeRequest: "workerRequestDiscardedForSingleModeRequest"
        case .missingApplicationDataChunkingConfig: "missingApplicationDataChunkingConfig"
        case .receivedDuplicateApplicationDataChunkingConfig: "receivedDuplicateApplicationDataChunkingConfig"
        case .unknownError: "unknownError"
        }
    }

    var errorCode: UInt32 {
        switch self {
        case .waitForWarmupCalledAfterEndJob: CloudAppFrameworkErrorCodes.waitForWarmupCalledAfterEndJob.rawValue
        case .parametersReceivedTwice: CloudAppFrameworkErrorCodes.parametersReceivedTwice.rawValue
        case .waitForParametersCalledAfterEndJob: CloudAppFrameworkErrorCodes.waitForParametersCalledAfterEndJob
            .rawValue
        case .provideOutputCalledAfterEndJob: CloudAppFrameworkErrorCodes.provideOutputCalledAfterEndJob.rawValue
        case .endOfResponseCalledAfterEndJob: CloudAppFrameworkErrorCodes.endOfResponseCalledAfterEndJob.rawValue
        case .endJobCalledMoreThanOnce: CloudAppFrameworkErrorCodes.endJobCalledMoreThanOnce.rawValue
        case .tornDownBeforeParametersReceived: CloudAppFrameworkErrorCodes.tornDownBeforeParametersReceived.rawValue
        case .pccRequestCalledAfterEndJob: CloudAppFrameworkErrorCodes.pccRequestCalledAfterEndJob.rawValue
        case .unknownPCCWorkerID: CloudAppFrameworkErrorCodes.unknownPCCWorkerID.rawValue
        case .workerFoundResultReceivedTwice: CloudAppFrameworkErrorCodes.workerFoundResultReceivedTwice.rawValue
        case .workerFoundResultNotReceived: CloudAppFrameworkErrorCodes.workerFoundResultNotReceived.rawValue
        case .unknownSubrequestID: CloudAppFrameworkErrorCodes.unknownSubrequestID.rawValue
        case .openSubreqeustCalledBeforeParametersReceived: CloudAppFrameworkErrorCodes
            .openSubreqeustCalledBeforeParametersReceived.rawValue
        case .subrequestAlreadyClosed: CloudAppFrameworkErrorCodes.subrequestAlreadyClosed.rawValue
        case .subrequestAlreadyOpened: CloudAppFrameworkErrorCodes.subrequestAlreadyOpened.rawValue
        case .workerRequestDiscardedForSingleModeRequest: CloudAppFrameworkErrorCodes
            .workerRequestDiscardedForSingleModeRequest.rawValue
        case .missingApplicationDataChunkingConfig: CloudAppFrameworkErrorCodes.missingApplicationDataChunkingConfig
            .rawValue
        case .receivedDuplicateApplicationDataChunkingConfig: CloudAppFrameworkErrorCodes
            .receivedDuplicateApplicationDataChunkingConfig.rawValue
        case .unknownError: CloudAppFrameworkErrorCodes.unknownError.rawValue
        }
    }
}

protocol JobHelperMessengerProtocol: Sendable {
    // General
    func waitForWarmupComplete() async throws
    func waitForParameters() async throws -> ParametersData
    func warmup(info: ManagedWarmupInfo) async throws
    func receiveParameters(parametersData: ParametersData) async throws
    func provideInput(_ data: Data) async throws
    func teardown() async
    func cancel() async
    func sendSubrequestResponse(subrequestID: UInt32, data: Data) async throws
    func subresponseEOF(subrequestID: UInt32, status: SubresponseStatus) async throws

    // Proxy
    func findWorker(
        query: FindWorkerQuery,
        subrequestID: UInt32?,
        cryptoMaterialHandles: [CryptoMaterialHandle],
        requestSummary: FindWorkerRequestSummaryProvisioner
    ) async throws
        -> (PCCWorkerInfo, AsyncStream<WorkerResponseMessage>)
    func sendWorkerRequestMessage(workerID: UUID, _ data: Data) async throws
    func sendWorkerEOF(workerID: UUID, isError: Bool) async throws
    func receiveWorkerFoundEvent(workerID: UUID, info: WorkerFoundInfo) async throws
    func receiveWorkerMessage(workerID: UUID, _ response: WorkerResponseMessage) async throws
    func receiveWorkerEOF(workerID: UUID) async throws
    func finalizeRequestExecutionLog() async throws

    // Key derivation
    func distributeEnsembleKey(info: String, distributionType: EnsembleKeyDistributionType) async throws -> UUID
    func distributeSealedEnsembleKey(
        info: String,
        distributionType: EnsembleKeyDistributionType
    ) async throws -> EnsembleKeyInfo

    // Private Information Retrieval (PIR)
    func makePIRRequest(
        _ request: PrivateInformationRetrievalRequest,
        purpose: String,
        traceContext: PIRRequestTraceContext
    ) async throws -> PrivateInformationRetrievalResponse

    func configureApplicationDataChunking(config: ApplicationDataChunkingConfiguration) async throws
    func getApplicationDataChunkingConfiguration() async throws -> ApplicationDataChunkingConfiguration
    func getMaxApplicationLayerMessageSize() async throws -> Int
}

actor JobHelperMessenger: JobHelperMessengerProtocol {
    typealias JobHelperSubrequestContinuation = AsyncStream<SubrequestExecution>.Continuation
    typealias JobHelperTeardownContinuation = AsyncStream<Void>.Continuation

    fileprivate static let log = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "JobHelperMessenger"
    )

    private let subrequestContinuation: JobHelperSubrequestContinuation
    private let teardownContinuation: JobHelperTeardownContinuation
    private let appInstance: CloudBoardApp
    private let log: Logger

    private var warmupState: WarmupState = .idle
    private var endCalled: Bool = false
    private var metricsBuilder: CloudAppMetrics.Builder
    private var parametersReceived: Bool
    private var parametersPromise:
        Promise<ParametersData, JobHelperMessengerError> = Promise(
            autoFailureIfUnfulfilled: JobHelperMessengerError
                .tornDownBeforeParametersReceived
        )
    private var parametersData: ParametersData?

    private let server: CloudBoardJobAPIServerProtocol

    private var pccWorkerRequests: [UUID: PCCWorkerResponseSession] = [:]

    // Subrequest management
    private enum SubrequestSessionState {
        case open(SubrequestSession)
        case closed
    }

    private enum ApplicationDataChunkingConfigState {
        case waitingForConfig
        case configReceived(ApplicationDataChunkingConfiguration)
    }

    private var applicationDataChunkingConfigState: ApplicationDataChunkingConfigState

    private var activeSubrequests: [UInt32: SubrequestSessionState] = [:]

    package static let defaultSubrequestID: UInt32 = 0
    private var singleRequestMode: Bool = false
    private var maxApplicationLayerMessageSize: Int = 0
    private var lengthPrefixMessageChunker: LengthPrefixMessageChunker?

    init(
        server: CloudBoardJobAPIServerProtocol,
        subrequestContinuation: JobHelperSubrequestContinuation,
        teardownContinuation: JobHelperTeardownContinuation,
        log: os.Logger,
        appInstance: CloudBoardApp,
        metricsBuilder: CloudAppMetrics.Builder
    ) async {
        self.subrequestContinuation = subrequestContinuation
        self.teardownContinuation = teardownContinuation
        self.log = log
        self.server = server
        self.appInstance = appInstance
        self.metricsBuilder = metricsBuilder
        self.parametersReceived = false
        self.applicationDataChunkingConfigState = .waitingForConfig
        await self.server.set(delegate: self)
        await self.server.connect()
    }

    deinit {
        // warmup is not guaranteed to be called if we get cancelled early on so ensure that any promise that is being
        // waited on is fulfilled when this goes out of scope.
        switch self.warmupState {
        case .waiting(let promise):
            promise.fail(with: WarmupStateError.warmupNeverCalled)
        case .warmupInProgress(let promise):
            promise?.fail(with: WarmupStateError.warmupNeverCalled)
        case .idle, .complete:
            // do nothing
            ()
        }
    }

    func provideOutput(_ data: Data) async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.provideOutputCalledAfterEndJob
        }

        for chunk in try self.getLengthPrefixMessageChunker().chunkData(data: data) {
            await self.server.provideResponseChunk(chunk)
        }
    }

    func waitForWarmupComplete() async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.waitForWarmupCalledAfterEndJob
        }

        switch self.warmupState {
        case .idle:
            let promise = Promise<Void, Error>()
            self.warmupState = .waiting(promise)
            try await Future(promise).valueWithCancellation
        case .waiting:
            throw WarmupStateError.waitInvokedWhileAlreadyWaiting
        case .warmupInProgress(let promise):
            if promise != nil {
                throw WarmupStateError.waitInvokedWhileInProgressWithContinuationSet
            }

            let promise = Promise<Void, Error>()
            self.warmupState = .warmupInProgress(promise)
            try await Future(promise).valueWithCancellation
        case .complete(let error):
            if let error {
                throw error
            }
        }
    }

    func waitForParameters() async throws -> ParametersData {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.waitForParametersCalledAfterEndJob
        }
        Self.log.log("Waiting for parameters")
        defer { Self.log.log("Parameters received") }
        return try await Future(self.parametersPromise).valueWithCancellation
    }

    func buildMetrics() -> CloudAppMetrics {
        return CloudAppMetrics(self.metricsBuilder, buildTime: .now)
    }

    func endOfResponse() async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.endOfResponseCalledAfterEndJob
        }
        await self.server.endOfResponse()
    }

    func reportCloudAppRequestExecutionError(error: CloudAppRequestExecutionError) async {
        await self.server.reportRequestExecutionError(RequestExecutionError(from: error))
    }

    func reportRequestExecutionError(error: RequestExecutionErrorProtocol) async {
        await self.server.reportRequestExecutionError(RequestExecutionError(from: error))
    }

    func internalError() async {
        await self.server.internalError()
    }

    func endJob() async throws {
        Self.log.log("endJob called")
        guard self.endCalled == false else {
            throw JobHelperMessengerError.endJobCalledMoreThanOnce
        }
        self.endCalled = true

        await self.server.endJob()
    }

    // MARK: - Subrequest Management

    /// Send a subrequest response chunk to the server
    func sendSubrequestResponse(subrequestID: UInt32, data: Data) async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.provideOutputCalledAfterEndJob
        }
        if self.singleRequestMode {
            try await self.provideOutput(data)
        } else {
            for chunk in try self.getLengthPrefixMessageChunker().chunkData(data: data) {
                await self.server.sendSubresponsePayload(subrequestID: subrequestID, payload: chunk)
            }
        }
    }

    /// Send subresponse EOF to the client
    func subresponseEOF(subrequestID: UInt32, status: SubresponseStatus) async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.endOfResponseCalledAfterEndJob
        }

        switch status {
        case .error(let error):
            self.log.error(
                "Sub request \(subrequestID, privacy: .public) failed with error: \(String(reportable: error), privacy: .public)"
            )
        case .discarded:
            self.log.error("Sub request \(subrequestID, privacy: .public) discarded")
        case .ok:
            self.log.log("Sub request \(subrequestID, privacy: .public) finished")
        }

        if self.singleRequestMode {
            switch status {
            case .ok:
                try await self.endOfResponse()
            case .discarded:
                self.log
                    .error("Unexpectedly received discarded sub response status for cloud app in single request mode")
                throw JobHelperMessengerError.workerRequestDiscardedForSingleModeRequest
            case .error(let error):
                await self.reportErrorForSingleRequestMode(error: error)
            }
        } else {
            let internalSubresponseStatus = InternalSubresponseStatus(status)
            await self.server.sendSubresponseEOF(subrequestID: subrequestID, status: internalSubresponseStatus)
        }
    }

    private func reportErrorForSingleRequestMode(error: Error) async {
        switch error {
        case let requestExecutionError as RequestExecutionErrorProtocol:
            await self.reportRequestExecutionError(error: requestExecutionError)
            await self.internalError()
        case let cloudAppRequestExecutionError as CloudAppRequestExecutionError:
            await self.reportCloudAppRequestExecutionError(error: cloudAppRequestExecutionError)
        default: await self.internalError()
        }
    }
}

extension JobHelperMessenger: CloudBoardJobAPIServerDelegateProtocol {}

extension JobHelperMessenger: CloudBoardJobAPIClientToServerProtocol {
    func warmup(info: ManagedWarmupInfo) async throws {
        switch self.warmupState {
        case .idle:
            self.warmupState = .warmupInProgress(nil)
        case .waiting(let promise):
            self.warmupState = .warmupInProgress(promise)
        case .warmupInProgress:
            throw WarmupStateError.warmupInvokedMoreThanOnce
        case .complete:
            throw WarmupStateError.warmupInvokedAfterComplete
        }

        do {
            try await self.appInstance.warmup(
                environment: WarmupEnvironment(
                    cloudAppName: info.cloudAppName,
                    launchdJobInstanceUUID: info.launchdJobInstanceUUID,
                    assetsMetadata: info.cloudAppAssetsMetadata
                )
            )
            self.maxApplicationLayerMessageSize = info.maxApplicationLayerMessageSize
        } catch {
            switch self.warmupState {
            case .idle, .waiting:
                throw WarmupStateError.foundIdleAfterWarmupFinished
            case .warmupInProgress(let promise):
                self.warmupState = .complete(error)
                promise?.fail(with: error)
                throw error
            case .complete:
                throw WarmupStateError.foundCompleteAfterWarmupFinished
            }
        }

        switch self.warmupState {
        case .idle:
            throw WarmupStateError.foundIdleAfterWarmupFinished
        case .waiting:
            throw WarmupStateError.foundWaitingAfterWarmupFinished
        case .warmupInProgress(let promise):
            self.warmupState = .complete(nil)
            promise?.succeed()
        case .complete:
            throw WarmupStateError.foundCompleteAfterWarmupFinished
        }
    }

    func receiveParameters(parametersData: ParametersData) async throws {
        if self.parametersReceived {
            throw JobHelperMessengerError.parametersReceivedTwice
        }
        self.metricsBuilder.receivedParameters(parametersData)
        self.parametersReceived = true
        self.parametersPromise.succeed(with: parametersData)
        self.parametersData = parametersData
    }

    func provideInput(_ data: Data) async throws {
        // If this method is called this means we are running
        // in a mode where there are no sub requests,
        // hence we just use a run request with id kDefaultSubrequestID.
        // Or we have received notification of end of input on the connection
        if !self.activeSubrequests.keys.contains(Self.defaultSubrequestID) {
            try await self.fabricateClientSubrequest()
        }
        try await self.receiveSubrequestPayload(subrequestID: Self.defaultSubrequestID, payload: data)
    }

    func openClientSubrequest(
        subrequestID: UInt32,
        cryptoMaterialHandles: [CryptoMaterialHandle],
        isDiscardable: Bool
    ) async throws {
        self.log.debug("Opening client subrequest \(subrequestID, privacy: .public)")

        guard let parametersData else {
            throw JobHelperMessengerError.openSubreqeustCalledBeforeParametersReceived
        }

        guard !self.activeSubrequests.keys.contains(subrequestID) else {
            throw JobHelperMessengerError.subrequestAlreadyOpened(subrequestID)
        }

        // Create and store the subrequest session
        let session = SubrequestSession(
            subrequestID: subrequestID,
            messenger: self,
            maxApplicationLayerMessageSize: self.maxApplicationLayerMessageSize
        )

        self.activeSubrequests[subrequestID] = .open(session)
        self.subrequestContinuation.yield(.init(
            subrequestID: subrequestID,
            cryptoMaterialHandles: cryptoMaterialHandles.map { $0.uuid },
            events: session.events,
            responseWriter: session.responseWriter,
            pccClient: .init(
                jobHelperMessenger: self,
                clientRequestID: parametersData.plaintextMetadata.requestID,
                requestBypassed: parametersData.requestBypassed,
                clientSubrequestCapabilites: .init(
                    clientSubrequestID: subrequestID,
                    cryptoMaterialHandles: .init(cryptoMaterialHandles.map { $0.uuid })
                )
            ),
            isDiscardable: isDiscardable
        ))
    }

    func receiveSubrequestPayload(subrequestID: UInt32, payload: Data) async throws {
        self.log.debug("Received subrequest payload for \(subrequestID, privacy: .public)")

        guard let sessionState = self.activeSubrequests[subrequestID] else {
            self.log.error("Received payload for unknown subrequest ID: \(subrequestID, privacy: .public)")
            throw JobHelperMessengerError.unknownSubrequestID(subrequestID)
        }
        switch sessionState {
        case .closed:
            self.log.error("Received payload for closed subrequest ID: \(subrequestID, privacy: .public)")
            throw JobHelperMessengerError.subrequestAlreadyClosed(subrequestID)
        case .open(let session):
            let chunkingConfig = try await self.getApplicationDataChunkingConfiguration()
            try session.receivePayload(payload, chunkingConfig: chunkingConfig)
        }
    }

    func closeClientSubrequest(subrequestID: UInt32) async throws {
        self.log.debug("Closing client subrequest \(subrequestID)")

        guard let sessionState = self.activeSubrequests[subrequestID] else {
            self.log.error("Closing unknown subrequest ID: \(subrequestID, privacy: .public)")
            throw JobHelperMessengerError.unknownSubrequestID(subrequestID)
        }
        switch sessionState {
        case .closed:
            self.log.error("Already closed subrequest ID: \(subrequestID, privacy: .public)")
            throw JobHelperMessengerError.subrequestAlreadyClosed(subrequestID)
        case .open(let session):
            // We retain the subrequest ID in the map in order to be able to distinguish between unknown and previously
            // closed subrequests
            self.activeSubrequests[subrequestID] = .closed
            // endOfInput can throw error, cleaning states before calling it.
            try session.endOfInput()
        }
    }

    func cancelClientSubrequest(subrequestID: UInt32) async throws {
        self.log.debug("Cancelling client subrequest \(subrequestID)")

        guard let sessionState = self.activeSubrequests[subrequestID] else {
            self.log.error("Cancelling unknown subrequest ID: \(subrequestID, privacy: .public)")
            throw JobHelperMessengerError.unknownSubrequestID(subrequestID)
        }
        switch sessionState {
        case .closed:
            self.log.log("Cancelling already closed subrequest ID: \(subrequestID, privacy: .public). Ignoring.")
        case .open(let session):
            // It is up to the cloud app to react to cancellation events
            session.cancel()
        }
    }

    func teardown() async {
        self.log.debug("Received teardown request")
        self.teardownContinuation.finish()
    }

    private func closeActiveSubrequestsExceptDefault() {
        for (subrequestID, sessionState) in self.activeSubrequests {
            if subrequestID == Self.defaultSubrequestID {
                continue
            }
            self.log.debug("Closing subrequest \(subrequestID, privacy: .public) due to final message")
            if case .open(let session) = sessionState {
                do {
                    try session.endOfInput()
                } catch {
                    if let requestExecutionError = error as? RequestExecutionErrorProtocol {
                        self.log.error(
                            """
                            Closing subrequest \(subrequestID, privacy: .public)
                            error: \(String(reportable: requestExecutionError), privacy: .public)
                            """
                        )
                    } else {
                        self.log.error("Error Closing subrequest \(subrequestID, privacy: .public)")
                    }
                }
            }
        }
    }

    func endOfInput() async throws {
        do {
            // Skipping closing the default subrequest here as it is getting closed in the next step
            self.closeActiveSubrequestsExceptDefault()

            if self.activeSubrequests.keys.contains(Self.defaultSubrequestID) {
                try await self.closeClientSubrequest(subrequestID: Self.defaultSubrequestID)
            }

            self.subrequestContinuation.finish()
        } catch {
            self.subrequestContinuation.finish()
            throw error
        }
    }

    func cancel() async {
        if self.parametersReceived == false {
            self.parametersPromise.fail(
                with:
                JobHelperMessengerError.tornDownBeforeParametersReceived
            )
        }
    }

    func findWorker(
        query: FindWorkerQuery,
        subrequestID: UInt32?,
        cryptoMaterialHandles: [CryptoMaterialHandle],
        requestSummary: FindWorkerRequestSummaryProvisioner
    ) async throws
    -> (PCCWorkerInfo, AsyncStream<WorkerResponseMessage>) {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.pccRequestCalledAfterEndJob
        }

        let (responseStream, responseContinuation) = AsyncStream<WorkerResponseMessage>.makeStream()
        let workerSession = PCCWorkerResponseSession(responseStreamContinuation: responseContinuation)
        self.pccWorkerRequests[query.workerID] = workerSession
        do {
            try await self.server.findWorker(
                query: query,
                subrequestID: subrequestID,
                cryptoMaterialHandles: cryptoMaterialHandles
            )
        } catch {
            try workerSession.onWorkerNotFound(error)
            await requestSummary.populate(error: error)
            await requestSummary.log(to: self.log)
            throw error
        }
        // Wait until we have found a worker
        let workerInfo = try await workerSession.waitForWorkerFound()
        return (workerInfo, responseStream)
    }

    func sendWorkerRequestMessage(workerID: UUID, _ data: Data) async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.pccRequestCalledAfterEndJob
        }

        guard self.pccWorkerRequests[workerID] != nil else {
            self.log.error("Received worker request for an unknown worker ID: \(workerID, privacy: .public)")
            throw JobHelperMessengerError.unknownPCCWorkerID
        }

        for chunk in try self.getLengthPrefixMessageChunker().chunkData(data: data) {
            await self.server.sendWorkerRequestMessage(workerID: workerID, chunk)
        }
    }

    func sendWorkerEOF(workerID: UUID, isError: Bool) async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.pccRequestCalledAfterEndJob
        }

        guard self.pccWorkerRequests[workerID] != nil else {
            self.log.error("Received worker request for an unknown worker ID: \(workerID, privacy: .public)")
            throw JobHelperMessengerError.unknownPCCWorkerID
        }

        await self.server.sendWorkerEOF(workerID: workerID, isError: isError)
    }

    func receiveWorkerFoundEvent(
        workerID: UUID,
        info: WorkerFoundInfo
    ) async throws {
        guard self.endCalled == false else {
            throw JobHelperMessengerError.pccRequestCalledAfterEndJob
        }

        guard let session = self.pccWorkerRequests[workerID] else {
            self.log.error("Received worker found message for an unknown worker ID: \(workerID, privacy: .public)")
            throw JobHelperMessengerError.unknownPCCWorkerID
        }

        try session.onWorkerFound(
            PCCWorkerInfo(
                releaseDigest: info.releaseDigest,
                ensemble: info.ensemble,
                rack: info.rack,
                workload: info.workload
            )
        )
    }

    func receiveWorkerMessage(workerID: UUID, _ response: WorkerResponseMessage) async throws {
        self.log.info("Received worker message for worker ID: \(workerID, privacy: .public)")
        guard let workerSession = self.pccWorkerRequests[workerID] else {
            self.log.error("Received worker response for an unknown worker ID: \(workerID, privacy: .public)")
            throw JobHelperMessengerError.unknownPCCWorkerID
        }

        workerSession.responseStreamContinuation.yield(response)
    }

    func receiveWorkerResponseSummary(workerID: UUID, status: WorkerResponseStatus) async throws {
        self.log.info("Received worker response summary for worker ID: \(workerID, privacy: .public)")
        guard let workerSession = self.pccWorkerRequests[workerID] else {
            self.log.error(
                "Received worker response summary for an unknown invocation ID: \(workerID, privacy: .public)"
            )
            throw JobHelperMessengerError.unknownPCCWorkerID
        }

        if status == .discarded {
            try workerSession.onWorkerNotFound(PCCRequestError.requestDiscarded)
        } else {
            workerSession.responseStreamContinuation.yield(.result(.init(from: status)))
        }
    }

    func receiveWorkerEOF(workerID: UUID) async throws {
        self.log.info("Received worker EOF for worker ID: \(workerID, privacy: .public)")
        guard let workerSession = self.pccWorkerRequests[workerID] else {
            self.log.error("Received worker response for an unknown worker ID: \(workerID, privacy: .public)")
            throw JobHelperMessengerError.unknownPCCWorkerID
        }
        workerSession.finish()
    }

    func finalizeRequestExecutionLog() async throws {
        self.log.info("Received request to finalize Request Execution Log")
        await self.server.finalizeRequestExecutionLog()
    }

    func distributeEnsembleKey(
        info: String,
        distributionType: EnsembleKeyDistributionType
    ) async throws -> UUID {
        self.log.info("Received request to distribute ensemble key")
        return try await self.server.distributeEnsembleKey(info: info, distributionType: .init(distributionType))
    }

    func distributeSealedEnsembleKey(
        info: String,
        distributionType: EnsembleKeyDistributionType
    ) async throws -> EnsembleKeyInfo {
        self.log.info("Received request to distribute encrypted ensemble key")
        let keyInfo = try await self.server.distributeSealedEnsembleKey(
            info: info,
            distributionType: .init(distributionType)
        )
        return .init(keyID: keyInfo.keyID, keyEncryptionKey: SymmetricKey(data: keyInfo.keyEncryptionKey))
    }

    func makePIRRequest(
        _ request: PrivateInformationRetrievalRequest,
        purpose: String,
        traceContext: PIRRequestTraceContext
    ) async throws -> PrivateInformationRetrievalResponse {
        self.log.info("Received Private Information Retrieval request")
        let response = try await self.server.makePrivateInformationRetrievalRequest(
            .init(payload: request.payload, purpose: purpose, traceContext: traceContext)
        )
        return .init(from: response)
    }

    func configureApplicationDataChunking(config: ApplicationDataChunkingConfiguration) async throws {
        switch self.applicationDataChunkingConfigState {
        case .waitingForConfig:
            self.applicationDataChunkingConfigState = .configReceived(config)
            self.lengthPrefixMessageChunker = LengthPrefixMessageChunker(
                config: config,
                maxApplicationLayerMessageSize: self.maxApplicationLayerMessageSize
            )
        case .configReceived(let existingConfig):
            // Ideally we should only receive this message once
            self.log.error("Received unexpected duplicate configureApplicationDataChunking message")
            if config != existingConfig {
                // throwing error only when the new config is different
                throw JobHelperMessengerError.receivedDuplicateApplicationDataChunkingConfig
            }
        }
    }

    func getApplicationDataChunkingConfiguration() async throws -> ApplicationDataChunkingConfiguration {
        switch self.applicationDataChunkingConfigState {
        case .waitingForConfig:
            // Ideally when this method is called we should have received ApplicationDataChunkingConfig
            throw JobHelperMessengerError.missingApplicationDataChunkingConfig
        case .configReceived(let config):
            return config
        }
    }

    private func getLengthPrefixMessageChunker() throws -> LengthPrefixMessageChunker {
        guard let messageChunker = self.lengthPrefixMessageChunker else {
            // LengthPrefixMessageChunker is initialised after we receive ApplicationDataChunkingConfig
            // Ideally when this method is called we should have received the chunking config
            throw JobHelperMessengerError.missingApplicationDataChunkingConfig
        }
        return messageChunker
    }

    func getMaxApplicationLayerMessageSize() async throws -> Int {
        return self.maxApplicationLayerMessageSize
    }
}

extension JobHelperMessenger {
    package func fabricateClientSubrequest() async throws {
        self.log.debug("Fabricating client subrequest")

        guard let parametersData else {
            throw JobHelperMessengerError.openSubreqeustCalledBeforeParametersReceived
        }

        self.singleRequestMode = true
        guard !self.activeSubrequests.keys.contains(Self.defaultSubrequestID) else {
            self.log.debug("Default session already exists. Skipping.")
            return
        }

        // Create and store the subrequest session
        let session = SubrequestSession(
            subrequestID: Self.defaultSubrequestID,
            messenger: self,
            maxApplicationLayerMessageSize: self.maxApplicationLayerMessageSize
        )
        self.activeSubrequests[Self.defaultSubrequestID] = .open(session)
        self.subrequestContinuation.yield(.init(
            subrequestID: Self.defaultSubrequestID,
            cryptoMaterialHandles: [],
            events: session.events,
            responseWriter: session.responseWriter,
            pccClient: .init(
                jobHelperMessenger: self,
                clientRequestID: parametersData.plaintextMetadata.requestID,
                requestBypassed: parametersData.requestBypassed
            ),
            isDiscardable: false
        ))
    }
}

final class PCCWorkerResponseSession: Sendable {
    enum PCCWorkerFindingState {
        case finding(Promise<PCCWorkerInfo, Error>)
        case found(PCCWorkerInfo)
        case notFound(Error)
    }

    let responseStreamContinuation: AsyncStream<WorkerResponseMessage>.Continuation
    let workerFindingState: Mutex<PCCWorkerFindingState>

    init(responseStreamContinuation: AsyncStream<WorkerResponseMessage>.Continuation) {
        self.responseStreamContinuation = responseStreamContinuation
        self.workerFindingState = .init(.finding(Promise()))
    }

    func waitForWorkerFound() async throws -> PCCWorkerInfo {
        let state = self.workerFindingState.withLock { $0 }
        switch state {
        case .finding(let promise):
            return try await Future(promise).valueWithCancellation
        case .found(let workerInfo):
            return workerInfo
        case .notFound(let error):
            throw error
        }
    }

    func onWorkerFound(_ workerInfo: PCCWorkerInfo) throws {
        try self.workerFindingState.withLock {
            switch $0 {
            case .finding(let promise):
                promise.succeed(with: workerInfo)
                $0 = .found(workerInfo)
            case .found, .notFound:
                throw JobHelperMessengerError.workerFoundResultReceivedTwice
            }
        }
    }

    func onWorkerNotFound(_ error: Error) throws {
        try self.workerFindingState.withLock {
            switch $0 {
            case .finding(let promise):
                promise.fail(with: error)
                $0 = .notFound(error)
            case .found, .notFound:
                throw JobHelperMessengerError.workerFoundResultReceivedTwice
            }
        }
    }

    func finish() {
        self.responseStreamContinuation.finish()
        self.workerFindingState.withLock {
            switch $0 {
            case .finding(let promise):
                promise.fail(with: JobHelperMessengerError.workerFoundResultNotReceived)
                $0 = .notFound(JobHelperMessengerError.workerFoundResultNotReceived)
            case .found, .notFound:
                ()
            }
        }
    }

    deinit {
        self.finish()
    }
}

/// Manages the lifecycle and I/O for a single client subrequest
public final class SubrequestSession: Sendable {
    let subrequestID: UInt32
    let eventContinuation: AsyncStream<SubrequestEvent>.Continuation
    let events: SubrequestEventSequence
    let responseWriter: SubresponseWriter
    let buffer: Mutex<LengthPrefixBuffer>

    init(
        subrequestID: UInt32,
        messenger: JobHelperMessenger,
        maxApplicationLayerMessageSize: Int
    ) {
        self.subrequestID = subrequestID
        let (eventStream, eventContinuation) = AsyncStream<SubrequestEvent>.makeStream()
        self.eventContinuation = eventContinuation
        self.events = SubrequestEventSequence(eventStream: eventStream)
        self.responseWriter = SubresponseWriter(messenger: messenger, subrequestID: subrequestID)

        self.eventContinuation.yield(.subrequestStart(.init()))
        self.buffer = .init(LengthPrefixBuffer(maxMessageSize: maxApplicationLayerMessageSize))
    }

    func receivePayload(
        _ payload: Data,
        chunkingConfig: ApplicationDataChunkingConfiguration
    ) throws {
        switch chunkingConfig {
        case .disabled:
            self.eventContinuation.yield(.subrequestPayload(.init(data: payload)))
        case .enabled:
            for chunk in try self.buffer.withLock({ try $0.append(.init(chunk: payload)) }) {
                self.eventContinuation.yield(.subrequestPayload(.init(data: chunk.chunk)))
            }
        }
    }

    func cancel() {
        self.eventContinuation.yield(.subrequestCancellation(.init()))
    }

    func endOfInput() throws {
        self.eventContinuation.yield(.subrequestEnd(.init()))
        self.eventContinuation.finish()

        try self.buffer.withLock { assembler in
            try assembler.validateCompleteDataChunksReceived()
        }
    }
}

extension CloudBoardJobAPIEnsembleKeyDistributionType {
    init(_ distributionType: EnsembleKeyDistributionType) {
        self = switch distributionType {
        case .local: .local
        case .distributed: .distributed
        }
    }
}

extension PrivateInformationRetrievalResponse {
    init(from response: CloudBoardJobAPIPIRResponse) {
        self = PrivateInformationRetrievalResponse(
            payload: response.payload
        )
    }
}

extension RequestExecutionError {
    init(from error: RequestExecutionErrorProtocol) {
        self = RequestExecutionError(
            errorSource: error.errorSource,
            errorMessage: error.staticStringRepresentation,
            errorCode: error.errorCode,
        )
    }
}

extension RequestExecutionErrorSource {
    init(from source: CloudAppRequestExecutionErrorSource) {
        switch source {
        case .cloudApp:
            self = .cloudApp
        case .cloudAppFramework:
            self = .cloudAppFramework
        }
    }
}

extension RequestExecutionError {
    init(from error: CloudAppRequestExecutionError) {
        self = RequestExecutionError(
            errorSource: .init(from: error.errorSource),
            errorMessage: error.errorMessage,
            errorCode: error.errorCode
        )
    }
}

extension WorkerResponseMessage.Result {
    init(from responseStatus: WorkerResponseStatus) {
        switch responseStatus {
        case .succeeded:
            self = .ok
        case .failed:
            self = .failure
        case .discarded:
            self = .discarded
        }
    }
}

extension InternalSubresponseStatus {
    fileprivate init(_ status: SubresponseStatus) {
        switch status {
        case .ok:
            self = .ok
        case .discarded:
            self = .discarded
        case .error(let error):
            self = .error(.init(error))
        }
    }
}

extension RequestExecutionError {
    fileprivate init(_ error: Error) {
        switch error {
        case let requestExecutionError as RequestExecutionErrorProtocol:
            self = .init(from: requestExecutionError)
        case let cloudAppRequestExecutionError as CloudAppRequestExecutionError:
            self = .init(from: cloudAppRequestExecutionError)
        default:
            JobHelperMessenger.log.error(
                "Failed to convert error \(String(reportable: error), privacy: .public) to RequestExecutionError"
            )
            self = .init(from: JobHelperMessengerError.unknownError)
        }
    }
}

extension LengthPrefixBufferError: RequestExecutionErrorProtocol {
    package var staticStringRepresentation: StaticString {
        switch self {
        case .exceedingMaxMessageSize: "exceedingMaxMessageSize"
        case .receivedAdditionalChunkAfterFinalChunk: "receivedAdditionalChunkAfterFinalChunk"
        case .finalChunkContainsIncompleteMessage: "finalChunkContainsIncompleteMessage"
        }
    }

    package var errorCode: UInt32 {
        switch self {
        case .exceedingMaxMessageSize: CloudAppFrameworkErrorCodes.exceedingMaxMessageSize.rawValue
        case .receivedAdditionalChunkAfterFinalChunk: CloudAppFrameworkErrorCodes.receivedAdditionalChunkAfterFinalChunk
            .rawValue
        case .finalChunkContainsIncompleteMessage: CloudAppFrameworkErrorCodes.finalChunkContainsIncompleteMessage
            .rawValue
        }
    }

    package var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.cloudAppFramework
    }
}
