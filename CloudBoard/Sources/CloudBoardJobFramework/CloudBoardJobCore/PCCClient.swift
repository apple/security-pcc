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

internal import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
internal import CloudBoardLogging
import Foundation
import os
internal import Synchronization

public enum PCCClientError: RequestExecutionErrorProtocol {
    case noHandlerResult
    case illegalTransition
    case usedAfterFinalizedCalled
    case unknownCryptoMaterial
    /// Crypto material handles were provided for a PCCClient with missing subrequest context
    case missingSubrequestContext
    /// A prior `makePCCRequest` on this `PCCClient` failed in a way that disallows
    /// further calls; this call is fast-failed without reaching CloudBoard.
    case requestDisallowed

    package var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.cloudAppFramework
    }

    package var staticStringRepresentation: StaticString {
        switch self {
        case .noHandlerResult: "noHandlerResult"
        case .illegalTransition: "illegalTransition"
        case .usedAfterFinalizedCalled: "usedAfterFinalizedCalled"
        case .unknownCryptoMaterial: "unknownCryptoMaterial"
        case .missingSubrequestContext: "missingSubrequestContext"
        case .requestDisallowed: "requestDisallowed"
        }
    }

    package var errorCode: UInt32 {
        switch self {
        case .noHandlerResult: CloudAppFrameworkErrorCodes.noHandlerResult.rawValue
        case .illegalTransition: CloudAppFrameworkErrorCodes.illegalTransition.rawValue
        case .usedAfterFinalizedCalled: CloudAppFrameworkErrorCodes.usedAfterFinalizedCalled.rawValue
        case .unknownCryptoMaterial: CloudAppFrameworkErrorCodes.unknownCryptoMaterial.rawValue
        case .missingSubrequestContext: CloudAppFrameworkErrorCodes.missingSubrequestContext.rawValue
        case .requestDisallowed: CloudAppFrameworkErrorCodes.requestDisallowed.rawValue
        }
    }
}

/// Represents request-related errors due to PCC Gateway
public enum PCCRequestError: RequestExecutionErrorProtocol, Hashable {
    /// The request has been discarded by ROPES, e.g. due to insufficient capacity
    case requestDiscarded

    /// Failed to assign a worker for the request. Only thrown when the call opted in via
    /// `PCCRequestConfiguration.delayedTerminationOnFailure`
    case findWorkerFailed(rawROPESCode: UInt32, message: String?)

    /// A worker had been assigned for the request but the session subsequently
    /// failed. Only thrown when the call opted in via
    /// `PCCRequestConfiguration.delayedTerminationOnFailure`
    case workerSessionFailure(rawROPESCode: UInt32, message: String?)

    package var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.cloudAppFramework
    }

    package var staticStringRepresentation: StaticString {
        switch self {
        case .requestDiscarded: "requestDiscarded"
        case .findWorkerFailed: "findWorkerFailed"
        case .workerSessionFailure: "workerSessionFailure"
        }
    }

    package var errorCode: UInt32 {
        switch self {
        case .requestDiscarded: CloudAppFrameworkErrorCodes.requestDiscarded.rawValue
        case .findWorkerFailed: CloudAppFrameworkErrorCodes.findWorkerFailed.rawValue
        case .workerSessionFailure: CloudAppFrameworkErrorCodes.workerSessionFailure.rawValue
        }
    }
}

// makePCCRequest config data
public struct PCCRequestConfiguration: Sendable {
    public var effort: ExpectedEffort?
    // if not set, no reuse is possible or reasonable
    public var reuseTarget: ReuseTarget?
    public var cryptoMaterialHandles: Set<UUID>
    public var responseBypass: Bool
    public var isFinal: Bool
    public var spanID: UInt64?
    public var groupID: String?
    public var isDiscardable: Bool

    /// When `true`, a non-discardable find-worker or worker-session failure is
    /// delivered to the caller as a typed `PCCRequestError` thrown from
    /// `makePCCRequest`, instead of triggering an immediate teardown of the
    /// cloud app.
    ///
    /// The PCC request is still terminal: any subsequent `makePCCRequest` call
    /// on this `PCCClient` will throw `PCCClientError.requestDisallowed`. The
    /// cloud app cannot rescue or retry the failing request.
    ///
    /// Default: `false` (legacy behavior — non-discardable failures throw out
    /// of the cloud app run and trigger teardown).
    public var delayedTerminationOnFailure: Bool

    public init(
        effort: ExpectedEffort? = nil,
        reuseTarget: ReuseTarget? = nil,
        cryptoMaterialHandles: Set<UUID> = [],
        responseBypass: Bool = false,
        isFinal: Bool = false,
        spanID: UInt64? = nil,
        groupID: String? = nil,
        isDiscardable: Bool = false,
    ) {
        self.init(
            effort: effort,
            reuseTarget: reuseTarget,
            cryptoMaterialHandles: cryptoMaterialHandles,
            responseBypass: responseBypass,
            isFinal: isFinal,
            spanID: spanID,
            groupID: groupID,
            isDiscardable: isDiscardable,
            delayedTerminationOnFailure: false
        )
    }

    public init(
        effort: ExpectedEffort? = nil,
        reuseTarget: ReuseTarget? = nil,
        cryptoMaterialHandles: Set<UUID> = [],
        responseBypass: Bool = false,
        isFinal: Bool = false,
        spanID: UInt64? = nil,
        groupID: String? = nil,
        isDiscardable: Bool = false,
        delayedTerminationOnFailure: Bool = false
    ) {
        self.effort = effort
        self.reuseTarget = reuseTarget
        self.cryptoMaterialHandles = cryptoMaterialHandles
        self.responseBypass = responseBypass
        self.isFinal = isFinal
        self.spanID = spanID
        self.groupID = groupID ?? UUID().uuidString
        self.isDiscardable = isDiscardable
        self.delayedTerminationOnFailure = delayedTerminationOnFailure
    }
}

/// A client for sending requests to other Private Cloud Compute nodes.
/// This is used only by "proxy" based cloud apps to request "compute" nodes to do work on their behalf.
/// These a commonly called "sub requests" or "InvokeProxyInitiate" for the ROPES grpc message used to start
/// them from the proxy node.
public final class PCCClient: Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PCCClient"
    )

    private static let tracingLogger = Logger(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "PCCClient"
    )

    private let jobHelperMessenger: JobHelperMessengerProtocol
    private let clientRequestID: String
    private let finalized = OSAllocatedUnfairLock(initialState: false)
    private let forwardBypassedRequestChunksToWorker: OSAllocatedUnfairLock<Bool>
    private let clientSubrequestCapabilites: ClientSubrequestCapabilities?

    /// Set to `true` when a terminal error requires subsequent PCC requests to be disallowed,
    /// for targetability concern.
    private let abandoned: Mutex<Bool> = .init(false)

    init(
        jobHelperMessenger: JobHelperMessengerProtocol,
        clientRequestID: String,
        requestBypassed: Bool,
        clientSubrequestCapabilites: ClientSubrequestCapabilities? = nil
    ) {
        self.jobHelperMessenger = jobHelperMessenger
        self.clientRequestID = clientRequestID
        self.forwardBypassedRequestChunksToWorker = .init(initialState: requestBypassed)
        self.clientSubrequestCapabilites = clientSubrequestCapabilites
    }

    public enum PCCWorkerResponse: Equatable, Sendable {
        public struct Result: Equatable, Sendable {
            public enum Status: Encodable, Equatable, Sendable, CustomStringConvertible {
                case ok
                case failure
                /// No longer used. When requests are discarded, makePCCRequest will throw
                /// PCCCRequestError.requestDiscarded.
                case discarded

                public var description: String {
                    switch self {
                    case .ok: "OK"
                    case .failure: "Failure"
                    case .discarded: "Discarded"
                    }
                }
            }

            public var status: Status

            static func from(_ result: WorkerResponseMessage.Result) -> PCCWorkerResponse.Result {
                return switch result {
                case .ok: .init(status: .ok)
                case .failure: .init(status: .failure)
                case .discarded: .init(status: .discarded)
                }
            }
        }

        case payload(Data)
        case result(Result)
    }

    public struct PCCRequestSession: Sendable {
        public struct ResponseData: AsyncSequence, Sendable {
            public typealias Element = PCCWorkerResponse
            public typealias Failure = Error
            public typealias AsyncIterator = AsyncThrowingStream<Element, Failure>.AsyncIterator

            let responseStream: AsyncThrowingStream<PCCWorkerResponse, Error>

            public func makeAsyncIterator() -> AsyncIterator {
                return self.responseStream.makeAsyncIterator()
            }
        }

        public struct RequestWriter: Sendable {
            fileprivate typealias DataOutputContinuation = AsyncThrowingStream<Data, Error>.Continuation

            fileprivate let outputContinuation: DataOutputContinuation
            fileprivate init(_ outputContinuation: DataOutputContinuation) {
                self.outputContinuation = outputContinuation
            }

            public func write(_ output: Data) async throws {
                self.outputContinuation.yield(output)
            }

            public func finish() async throws {
                self.outputContinuation.finish()
            }
        }

        public let sessionID: UUID
        public let requestWriter: RequestWriter
        public let responseStream: ResponseData
        public let workerInfo: PCCWorkerInfo

        fileprivate init(
            sessionID: UUID,
            workerInfo: PCCWorkerInfo,
            _ requestWriter: RequestWriter,
            _ responseStream: ResponseData
        ) {
            self.sessionID = sessionID
            self.workerInfo = workerInfo
            self.requestWriter = requestWriter
            self.responseStream = responseStream
        }
    }

    enum RequestTaskGroupResult<ReturnType: Sendable> {
        case handlerFinished(ReturnType)
        case handlerError(Error)
        case requestStreamFinished
        case requestStreamError(Error)
        case responseStreamFinished
        case workerResponseStreamError(Error)
    }

    enum PCCRequestCompletionStatus {
        case awaiting(requestStreamCompleted: Bool, responseStreamCompleted: Bool, handlerCompleted: Bool)
        case allComplete
    }

    // Heavily overloaded function for ABI compatibility
    /// Request a PCC node for performing some specific computation(S)
    @preconcurrency
    public func makePCCRequest<ReturnType: Sendable>(
        serviceName: String,
        routingParameters: [String: [String]],
        configuration: PCCRequestConfiguration,
        handler: @Sendable @escaping (PCCRequestSession) async throws -> ReturnType
    ) async throws -> ReturnType {
        let findWorkerSpanID: UInt64 = TraceContextCache.singletonCache.generateNewSpanID()
        let requestSummary = FindWorkerRequestSummaryProvisioner(
            requestID: self.clientRequestID,
            clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
            spanID: findWorkerSpanID,
            parentSpanID: configuration.spanID
        )
        await requestSummary.populate(reuseTarget: configuration.reuseTarget, groupID: configuration.groupID)
        if !configuration.cryptoMaterialHandles.isEmpty {
            guard let clientSubrequestCapabilites else {
                Self.logger.error("Crypto material handles provided for a PCCClient without subrequest context")
                await requestSummary.populate(error: PCCClientError.missingSubrequestContext)
                await requestSummary.log(to: Self.tracingLogger)
                throw PCCClientError.missingSubrequestContext
            }

            for cryptoMaterialHandle in configuration.cryptoMaterialHandles {
                guard clientSubrequestCapabilites.cryptoMaterialHandles.contains(cryptoMaterialHandle)
                else {
                    Self.logger.error("Unknown crypto material handle provided")
                    await requestSummary.populate(error: PCCClientError.unknownCryptoMaterial)
                    await requestSummary.log(to: Self.tracingLogger)
                    throw PCCClientError.unknownCryptoMaterial
                }
            }
        }

        // We disallow subsequent requests to prevent ROPES from getting a retry oracle.
        // Note that this is best-effort under concurrent calls: when two makePCCRequest calls
        // overlap and the first one fails terminally, the second may have already issued
        // its findWorker XPC by the time the framework observes the first's failure. In
        // that case the second proceeds normally. This is not an anti-targetability violation
        // since concurrent overlap is not a retry oracle.
        if self.abandoned.withLock({ $0 }) {
            await requestSummary.populate(error: PCCClientError.requestDisallowed)
            await requestSummary.log(to: Self.tracingLogger)
            throw PCCClientError.requestDisallowed
        }

        let wasAlreadyFinalized = self.finalized.withLock { finalized in
            if finalized {
                return true
            } else if configuration.isFinal {
                finalized = true
                return false
            } else {
                return false
            }
        }
        if wasAlreadyFinalized {
            await requestSummary.populate(error: PCCClientError.usedAfterFinalizedCalled)
            await requestSummary.log(to: Self.tracingLogger)
            throw PCCClientError.usedAfterFinalizedCalled
        }

        let (requestStream, requestContinuation) = AsyncThrowingStream<Data, Error>.makeStream(of: Data.self)
        let (responseStream, responseContinuation) = AsyncThrowingStream<PCCWorkerResponse, Error>.makeStream()
        let requestWriter = PCCRequestSession.RequestWriter(requestContinuation)
        let workerID = UUID()

        PCCClientCheckpoint(
            requestID: self.clientRequestID,
            clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
            workerID: workerID,
            message: "Received request to find PCC worker",
            spanID: findWorkerSpanID
        ).log(
            serviceName: serviceName,
            routingParameters: routingParameters,
            reuseTarget: configuration.reuseTarget,
            groupID: configuration.groupID,
            responseBypass: configuration.responseBypass,
            isFinal: configuration.isFinal,
            to: Self.tracingLogger,
            level: .info
        )

        // If this is the first worker request and the proxy has been bypassed for the request payload, ask ROPES
        // to forward the buffered request chunks to this worker.
        let forwardBypassedRequestChunks = self.forwardBypassedRequestChunksToWorker.withLock {
            let result = $0
            $0 = false
            return result
        }

        let (workerInfo, workerResponseStream): (PCCWorkerInfo, AsyncThrowingStream<WorkerResponseMessage, Error>)
        do {
            (workerInfo, workerResponseStream) = try await self.jobHelperMessenger.findWorker(
                query: FindWorkerQuery(
                    workerID: workerID,
                    serviceName: serviceName,
                    routingParameters: routingParameters,
                    effort: configuration.effort,
                    reuseTarget: configuration.reuseTarget.map { ReuseTargetConstraints($0) },
                    responseBypass: configuration.responseBypass,
                    forwardRequestChunks: forwardBypassedRequestChunks,
                    isFinal: configuration.isFinal,
                    spanID: findWorkerSpanID,
                    groupID: configuration.groupID,
                    isDiscardable: configuration.isDiscardable,
                    deliversNonDiscardableFailures: configuration.delayedTerminationOnFailure
                ),
                subrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                cryptoMaterialHandles: configuration.cryptoMaterialHandles.map { .init(uuid: $0) },
                requestSummary: requestSummary
            )
        } catch {
            await requestSummary.populate(error: error)
            await requestSummary.log(to: Self.tracingLogger)
            self.abandonOnTerminalError(error)
            throw error
        }

        do {
            return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                // Task group to handle requests from the cloud app to other PCC nodes
                group.addTask {
                    do {
                        for try await request in requestStream {
                            try await self.jobHelperMessenger.sendWorkerRequestMessage(workerID: workerID, request)
                        }
                        try await self.jobHelperMessenger.sendWorkerEOF(workerID: workerID, isError: false)
                        return .requestStreamFinished
                    } catch {
                        try await self.jobHelperMessenger.sendWorkerEOF(workerID: workerID, isError: true)
                        return .requestStreamError(error)
                    }
                }

                // Task group to handle responses received from other PCC nodes via cb_jobhelper
                group.addTask {
                    defer {
                        responseContinuation.finish()
                    }
                    do {
                        var buffer = await LengthPrefixBuffer(
                            maxMessageSize: self.jobHelperMessenger
                                .getMaxApplicationLayerMessageSize()
                        )
                        let chunkingConfig = try await self.jobHelperMessenger.getApplicationDataChunkingConfiguration()
                        let subrequestID = self.clientSubrequestCapabilites?.clientSubrequestID ??
                            JobHelperMessenger.defaultSubrequestID
                        for try await response in workerResponseStream {
                            switch response {
                            case .payload(let data):
                                switch chunkingConfig {
                                case .disabled:
                                    responseContinuation.yield(.payload(data))
                                case .enabled:
                                    for chunk in try buffer.append(
                                        .init(chunk: data),
                                        requestID: self.clientRequestID,
                                        subrequestID: subrequestID
                                    ) {
                                        responseContinuation.yield(.payload(chunk.chunk))
                                    }
                                }
                            case .result(let result):
                                responseContinuation.yield(.result(.from(result)))
                            @unknown default:
                                PCCClientCheckpoint(
                                    requestID: self.clientRequestID,
                                    clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                                    workerID: workerID,
                                    message: "Received worker response message of unknown type. Ignoring.",
                                    spanID: findWorkerSpanID
                                ).log(to: Self.tracingLogger, level: .error)
                            }
                        }

                        try buffer.validateCompleteDataChunksReceived(
                            requestID: self.clientRequestID,
                            subrequestID: subrequestID
                        )
                        return .responseStreamFinished
                    } catch {
                        return .workerResponseStreamError(error)
                    }
                }

                // Task group to run the cloud app handler
                group.addTask {
                    do {
                        return try await .handlerFinished(handler(PCCRequestSession(
                            sessionID: workerID,
                            workerInfo: workerInfo,
                            requestWriter,
                            .init(responseStream: responseStream)
                        )))
                    } catch {
                        return .handlerError(error)
                    }
                }

                var completionStatus = PCCRequestCompletionStatus.awaiting(
                    requestStreamCompleted: false,
                    responseStreamCompleted: false,
                    handlerCompleted: false
                )
                var handlerResult: ReturnType? = nil
                for try await result in group {
                    switch result {
                    case .handlerFinished(let result):
                        switch completionStatus {
                        case .awaiting(let requestStreamCompleted, let responseStreamCompleted, let handlerCompleted):
                            if handlerCompleted {
                                PCCClientCheckpoint(
                                    requestID: self.clientRequestID,
                                    clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                                    workerID: workerID,
                                    message: "Handler unexpectedly reported to have finished more than once",
                                    error: PCCClientError.illegalTransition,
                                    spanID: findWorkerSpanID
                                ).log(to: Self.tracingLogger, level: .error)
                                throw PCCClientError.illegalTransition
                            } else {
                                // This can happen due to a race condition which doesn't affect correctness in any way.
                                if !responseStreamCompleted {
                                    PCCClientCheckpoint(
                                        requestID: self.clientRequestID,
                                        clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                                        workerID: workerID,
                                        message: "Handler finished before response stream from worker to cloud app finished",
                                        spanID: findWorkerSpanID
                                    ).log(to: Self.tracingLogger, level: .default)
                                    responseContinuation.finish()
                                }

                                handlerResult = result
                                if requestStreamCompleted {
                                    completionStatus = .allComplete
                                } else {
                                    completionStatus = .awaiting(
                                        requestStreamCompleted: requestStreamCompleted,
                                        responseStreamCompleted: true,
                                        handlerCompleted: true
                                    )
                                    requestContinuation.finish()
                                }
                            }
                        case .allComplete:
                            PCCClientCheckpoint(
                                requestID: self.clientRequestID,
                                clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                                workerID: workerID,
                                message: "Handler unexpectedly reported to have finished more than once",
                                error: PCCClientError.illegalTransition,
                                spanID: findWorkerSpanID
                            ).log(to: Self.tracingLogger, level: .error)
                            throw PCCClientError.illegalTransition
                        }
                    case .handlerError(let error):
                        PCCClientCheckpoint(
                            requestID: self.clientRequestID,
                            clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                            workerID: workerID,
                            message: "Cloud app failed during outbound request processing",
                            error: error,
                            spanID: findWorkerSpanID
                        ).log(to: Self.tracingLogger, level: .error)
                        requestContinuation.finish(throwing: error)
                        group.cancelAll()
                        completionStatus = .allComplete
                        throw error
                    case .requestStreamFinished:
                        switch completionStatus {
                        case .awaiting(let requestStreamCompleted, let responseStreamCompleted, let handlerCompleted):
                            if requestStreamCompleted {
                                PCCClientCheckpoint(
                                    requestID: self.clientRequestID,
                                    clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                                    workerID: workerID,
                                    message: "Request stream unexpectedly reported to have finished more than once",
                                    error: PCCClientError.illegalTransition,
                                    spanID: findWorkerSpanID
                                ).log(to: Self.tracingLogger, level: .error)
                                throw PCCClientError.illegalTransition
                            } else {
                                PCCClientCheckpoint(
                                    requestID: self.clientRequestID,
                                    clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                                    workerID: workerID,
                                    message: "Request stream finished",
                                    spanID: findWorkerSpanID
                                ).log(to: Self.tracingLogger, level: .default)
                                if responseStreamCompleted, handlerCompleted {
                                    completionStatus = .allComplete
                                } else {
                                    completionStatus = .awaiting(
                                        requestStreamCompleted: true,
                                        responseStreamCompleted: responseStreamCompleted,
                                        handlerCompleted: handlerCompleted
                                    )
                                }
                            }
                        case .allComplete:
                            PCCClientCheckpoint(
                                requestID: self.clientRequestID,
                                clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                                workerID: workerID,
                                message: "Request stream unexpectedly reported to have finished more than once",
                                error: PCCClientError.illegalTransition,
                                spanID: findWorkerSpanID
                            ).log(to: Self.tracingLogger, level: .error)
                            throw PCCClientError.illegalTransition
                        }
                    case .requestStreamError(let error):
                        PCCClientCheckpoint(
                            requestID: self.clientRequestID,
                            clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                            workerID: workerID,
                            message: "Error while forwarding worker request message from cloud app",
                            error: error,
                            spanID: findWorkerSpanID
                        ).log(to: Self.tracingLogger, level: .error)
                        group.cancelAll()
                        completionStatus = .allComplete
                        throw error
                    case .workerResponseStreamError(let error):
                        PCCClientCheckpoint(
                            requestID: self.clientRequestID,
                            clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                            workerID: workerID,
                            message: "Error while forwarding worker response message to cloud app",
                            error: error,
                            spanID: findWorkerSpanID
                        ).log(to: Self.tracingLogger, level: .error)
                        group.cancelAll()
                        completionStatus = .allComplete
                        throw error
                    case .responseStreamFinished:
                        switch completionStatus {
                        case .awaiting(let requestStreamCompleted, let responseStreamCompleted, let handlerCompleted):
                            if !responseStreamCompleted {
                                PCCClientCheckpoint(
                                    requestID: self.clientRequestID,
                                    clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                                    workerID: workerID,
                                    message: "Response stream finished",
                                    spanID: findWorkerSpanID
                                ).log(to: Self.tracingLogger, level: .default)
                                completionStatus = .awaiting(
                                    requestStreamCompleted: requestStreamCompleted,
                                    responseStreamCompleted: true,
                                    handlerCompleted: handlerCompleted
                                )
                            }
                        case .allComplete:
                            PCCClientCheckpoint(
                                requestID: self.clientRequestID,
                                clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                                workerID: workerID,
                                message: "Response stream unexpectedly reported to have finished more than once",
                                error: PCCClientError.illegalTransition,
                                spanID: findWorkerSpanID
                            ).log(to: Self.tracingLogger, level: .error)
                            throw PCCClientError.illegalTransition
                        }
                    }

                    if case .allComplete = completionStatus {
                        PCCClientCheckpoint(
                            requestID: self.clientRequestID,
                            clientSubrequestID: self.clientSubrequestCapabilites?.clientSubrequestID,
                            workerID: workerID,
                            message: "Worker request completed",
                            spanID: findWorkerSpanID
                        ).log(to: Self.tracingLogger, level: .info)
                        await requestSummary.log(to: Self.tracingLogger)
                        group.cancelAll()

                        precondition(handlerResult != nil, "Handler result should not be nil at this point")
                        return handlerResult!
                    }
                }

                throw PCCClientError.noHandlerResult
            }
        } catch {
            // All errors from the task group reach here — populate and log requestSummary once.
            await requestSummary.populate(error: error)
            await requestSummary.log(to: Self.tracingLogger)
            self.abandonOnTerminalError(error)
            throw error
        }
    }

    @preconcurrency
    public func makePCCRequest<ReturnType: Sendable>(
        serviceName: String,
        routingParameters: [String: [String]],
        effort: ExpectedEffort? = nil,
        // if not set no reuse is possible or reasonable
        reuseTarget: ReuseTarget? = nil,
        cryptoMaterialHandles: Set<UUID> = [],
        responseBypass: Bool = false,
        isFinal: Bool = false,
        spanID: UInt64? = nil,
        groupID: String? = nil,
        handler: @Sendable @escaping (PCCRequestSession) async throws -> ReturnType
    ) async throws -> ReturnType {
        return try await self.makePCCRequest(
            serviceName: serviceName,
            routingParameters: routingParameters,
            configuration: .init(
                effort: effort,
                reuseTarget: reuseTarget,
                cryptoMaterialHandles: cryptoMaterialHandles,
                responseBypass: responseBypass,
                isFinal: isFinal,
                spanID: spanID,
                groupID: groupID
            ),
            handler: handler
        )
    }

    @preconcurrency
    public func makePCCRequest<ReturnType: Sendable>(
        serviceName: String,
        routingParameters: [String: [String]],
        effort: ExpectedEffort? = nil,
        // if not set no reuse is possible or reasonable
        reuseTarget: ReuseTarget? = nil,
        cryptoMaterialHandles: Set<UUID> = [],
        responseBypass: Bool = false,
        isFinal: Bool = false,
        spanID: UInt64? = nil,
        handler: @Sendable @escaping (PCCRequestSession) async throws -> ReturnType
    ) async throws -> ReturnType {
        return try await self.makePCCRequest(
            serviceName: serviceName,
            routingParameters: routingParameters,
            configuration: .init(
                effort: effort,
                reuseTarget: reuseTarget,
                cryptoMaterialHandles: cryptoMaterialHandles,
                responseBypass: responseBypass,
                isFinal: isFinal,
                spanID: spanID
            ),
            handler: handler
        )
    }

    // Overloaded function for ABI compatibility
    @preconcurrency
    public func makePCCRequest<ReturnType: Sendable>(
        serviceName: String,
        routingParameters: [String: [String]],
        effort _: ExpectedEffort? = nil,
        // if not set no reuse is possible or reasonable
        reuseTarget: ReuseTarget? = nil,
        responseBypass: Bool = false,
        isFinal: Bool = false,
        spanID: UInt64? = nil,
        handler: @Sendable @escaping (PCCRequestSession) async throws -> ReturnType
    ) async throws -> ReturnType {
        return try await self.makePCCRequest(
            serviceName: serviceName,
            routingParameters: routingParameters,
            configuration: .init(
                effort: nil,
                reuseTarget: reuseTarget,
                cryptoMaterialHandles: [],
                responseBypass: responseBypass,
                isFinal: isFinal,
                spanID: spanID
            ),
            handler: handler
        )
    }

    // Overloaded function for ABI compatibility and UInt64 representation of spanID.
    @preconcurrency
    public func makePCCRequest<ReturnType: Sendable>(
        serviceName: String,
        routingParameters: [String: [String]],
        responseBypass: Bool = false,
        isFinal: Bool = false,
        handler: @Sendable @escaping (PCCRequestSession) async throws -> ReturnType,
        spanID: UInt64? = nil
    ) async throws -> ReturnType {
        return try await self.makePCCRequest(
            serviceName: serviceName,
            routingParameters: routingParameters,
            configuration: .init(
                effort: nil,
                reuseTarget: nil,
                responseBypass: responseBypass,
                isFinal: isFinal,
                spanID: spanID
            ),
            handler: handler,
        )
    }

    // Overloadeded function for ABI compatibility and String representation of spanID.
    @preconcurrency
    public func makePCCRequest<ReturnType: Sendable>(
        serviceName: String,
        routingParameters: [String: [String]],
        responseBypass: Bool = false,
        isFinal: Bool = false,
        handler: @Sendable @escaping (PCCRequestSession) async throws -> ReturnType,
        spanID: String? = nil
    ) async throws -> ReturnType {
        return try await self.makePCCRequest(
            serviceName: serviceName,
            routingParameters: routingParameters,
            configuration: .init(
                responseBypass: responseBypass,
                isFinal: isFinal,
                spanID: UInt64(spanID ?? "", radix: 16) ?? UInt64.random(in: 0 ..< UInt64.max)
            ),
            handler: handler,
        )
    }

    /// Establishes a bidirectional request/response stream with another PCC node that matches the provided
    /// `serviceName` and `routingParameters`. Only usable from a cloud proxy app.
    ///
    /// - Parameters:
    ///   - serviceName: The service name to find a worker node for.
    ///   - routingParameters: The routing parameters to use when finding a worker node.
    ///   - responseBypass: If `true` the response stream from the worker will go directly to the initiating client
    ///   rather than coming back to this instance
    ///   - isFinal: If `true` CloudBoard sends a final Request Execution Log entry to the initiating client and
    ///   prevents any further outbound requests
    ///   - handler: Handler that is provided with a session object that provides a request writer to send request
    ///   messages to the worker node and a response stream for response messages from the worker. Node that in the case
    ///   response bypass is enabled, the response stream only ever contains a response summary once the worker request
    ///   completes.
    @preconcurrency
    public func makePCCRequest<ReturnType: Sendable>(
        serviceName: String,
        routingParameters: [String: [String]],
        responseBypass: Bool = false,
        isFinal: Bool = false,
        handler: @Sendable @escaping (PCCRequestSession) async throws -> ReturnType,
    ) async throws -> ReturnType {
        return try await self.makePCCRequest(
            serviceName: serviceName,
            routingParameters: routingParameters,
            configuration: .init(
                responseBypass: responseBypass,
                isFinal: isFinal,
                spanID: UInt64.random(in: 0 ..< UInt64.max)
            ),
            handler: handler,
        )
    }

    /// Calling `finalize` allows CloudBoard to signal back to the client via the Request Execution Log that for the
    /// current request no more outbound requests will be made. Once finalized, further calls to `makePCCRequest` will
    /// fail.
    ///
    /// Calling finalize multiple times or after a `makePCCRequest` has been made that was marked as final has no
    /// effect.
    public func finalize() async throws {
        let alreadyFinalized = self.finalized.withLock {
            let alreadyFinalized = $0
            $0 = true
            return alreadyFinalized
        }
        if !alreadyFinalized {
            try await self.jobHelperMessenger.finalizeRequestExecutionLog()
        }
    }

    func abandonOnTerminalError(_ error: Error) {
        guard let pccError = error as? PCCRequestError else { return }
        switch pccError {
        case .findWorkerFailed, .workerSessionFailure:
            self.abandoned.withLock { $0 = true }
        case .requestDiscarded:
            ()
        }
    }
}

struct PCCClientCheckpoint: RequestCheckpoint {
    var requestID: String?
    var clientSubrequestID: UInt64?
    var workerID: UUID
    var spanID: UInt64?
    var operationName: StaticString
    // RequestCheckpoint requires serviceName to be a static string but we can only
    // determine the cloud app's process name dynamically
    var serviceName: StaticString = "unused"
    var cloudAppServiceName: String {
        DebugContext.appName ??
            ProcessInfo.processInfo.processName
    }

    var namespace: StaticString = "cloudboard"
    var error: Error?
    var message: StaticString

    init(
        requestID: String,
        clientSubrequestID: UInt64?,
        workerID: UUID,
        operationName: StaticString = #function,
        message: StaticString,
        error: Error? = nil,
        spanID: UInt64? = nil
    ) {
        self.requestID = requestID
        self.clientSubrequestID = clientSubrequestID
        self.workerID = workerID
        self.operationName = operationName
        self.message = message
        self.spanID = spanID
        self.error = error
    }

    func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID!, privacy: .public)
        client.subrequest_id=\(self.clientSubrequestID?.description ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.cloudAppServiceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        worker.uuid=\(self.workerID, privacy: .public)
        """)
    }

    func log(
        serviceName: String,
        routingParameters: [String: [String]],
        reuseTarget: ReuseTarget?,
        groupID: String?,
        responseBypass: Bool,
        isFinal: Bool,
        to logger: Logger,
        level: OSLogType = .default
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        service.name=\(self.cloudAppServiceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        worker.serviceName=\(serviceName, privacy: .public),
        worker.routingParameters=\(routingParameters, privacy: .public)
        worker.responseBypass=\(responseBypass, privacy: .public)
        worker.isFinal=\(isFinal, privacy: .public)
        worker.uuid=\(self.workerID, privacy: .public)
        worker.reuseTarget.ensemble=\(reuseTarget?.ensemble.description ?? "", privacy: .public)
        worker.reuseTarget.rack=\(reuseTarget?.rack?.description ?? "", privacy: .public)
        worker.reuseTarget.workloadAdditions=\(reuseTarget?.workloadAdditions ?? [:], privacy: .public)
        worker.groupID=\(groupID ?? "", privacy: .public)
        """)
    }
}

package actor FindWorkerRequestSummaryProvisioner {
    public var requestSummary: FindWorkerRequestSummary

    init(requestID: String, clientSubrequestID: UInt64?, spanID: UInt64? = nil, parentSpanID: UInt64? = nil) {
        self.requestSummary = FindWorkerRequestSummary(
            requestID: requestID,
            clientSubrequestID: clientSubrequestID,
            spanID: spanID,
            parentSpanID: parentSpanID
        )
        self.requestSummary.startTimeNanos = RequestSummaryClock.now
    }

    func populate(workerID: String, requestTrackingID: String?, spanID: UInt64?, parentSpanID: UInt64?) {
        self.requestSummary.populate(
            workerID: workerID,
            requestTrackingID: requestTrackingID,
            spanID: spanID,
            parentSpanID: parentSpanID
        )
    }

    func populate(workerID: String) {
        self.requestSummary.populate(workerID: workerID)
    }

    func populate(reuseTarget: ReuseTarget?, groupID: String?) {
        self.requestSummary.populate(reuseTarget: reuseTarget, groupID: groupID)
    }

    func populate(error: Error) {
        self.requestSummary.populate(error: error)
    }

    func log(to logger: Logger) {
        self.requestSummary.endTimeNanos = RequestSummaryClock.now
        self.requestSummary.log(to: logger)
    }
}

package struct FindWorkerRequestSummary: RequestSummary, Sendable {
    public var serviceName: String {
        DebugContext.appName ?? ProcessInfo.processInfo.processName
    }

    public var requestID: String?
    public var clientSubrequestID: UInt64?
    var spanID: UInt64?
    var parentSpanID: UInt64?
    public let automatedDeviceGroup: String? = nil // No automated device group for FindWorker calls

    var workerID: String?
    var groupID: String?
    var reuseTarget: ReuseTarget?
    public var startTimeNanos: Int64?
    public var endTimeNanos: Int64?

    public let operationName = "FindWorker"
    public let type = "RequestSummary"
    public var namespace = "cloudboard"

    public var error: Error?

    init(requestID: String, clientSubrequestID: UInt64? = nil, spanID: UInt64? = nil, parentSpanID: UInt64? = nil) {
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.requestID = requestID
        self.clientSubrequestID = clientSubrequestID
    }

    mutating func populate(workerID: String, requestTrackingID: String?, spanID: UInt64?, parentSpanID: UInt64?) {
        self.workerID = workerID
        self.requestID = requestTrackingID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }

    mutating func populate(workerID: String) {
        self.workerID = workerID
    }

    mutating func populate(reuseTarget: ReuseTarget?, groupID: String?) {
        self.reuseTarget = reuseTarget
        self.groupID = groupID
    }

    public func log(to logger: Logger) {
        logger.log("""
        ttl=RequestSummary
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        client.subrequest_id=\(self.clientSubrequestID?.description ?? "UNKNOWN", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.parent_span_id=\(self.parentSpanID?.hexEncoded ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        request.duration_ms=\(self.durationMicros.map { String($0 / 1000) } ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { "\(String(reportable: $0))" } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        worker.uuid=\(self.workerID.map { "\($0)" } ?? "")
        worker.reuseTarget.ensemble=\(self.reuseTarget?.ensemble.description ?? "", privacy: .public)
        worker.reuseTarget.rack=\(self.reuseTarget?.rack?.description ?? "", privacy: .public)
        worker.reuseTarget.workloadAdditions=\(self.reuseTarget?.workloadAdditions ?? [:], privacy: .public)
        worker.groupID=\(self.groupID ?? "", privacy: .public)
        """)
    }
}

/// Information about the worker known once it has been assigned to us
public struct PCCWorkerInfo: Sendable, Equatable {
    /// The sha-256 digest of the release section of the attestation bundle
    /// for the worker encoded identically to how it is advertised in the
    /// service discovery registration
    public var releaseDigest: String

    /// pulled from the attestation
    public var ensemble: EnsembleInstanceId

    /// pulled from the attestation
    public var rack: RackId

    /// The workload that was presented to the worker by ropes, including any edits it made such
    /// as specific run modes, reuse additions etc.
    /// Note: this will not light up till ROPES supports it - until then it will be empty rather than nil
    /// since it should always be filled in from the point it is supported (and relied upon)
    public var workload: [String: [String]]

    /// Build version of the release running on the worker
    public var buildVersion: String
    /// Type of release running on the worker
    public var releaseType: String

    internal init(
        releaseDigest: String,
        ensemble: EnsembleInstanceId,
        rack: RackId,
        workload: [String: [String]],
        buildVersion: String,
        releaseType: String
    ) {
        self.releaseDigest = releaseDigest
        self.ensemble = ensemble
        self.rack = rack
        self.workload = workload
        self.buildVersion = buildVersion
        self.releaseType = releaseType
    }
}

package struct ClientSubrequestCapabilities: Sendable {
    public let clientSubrequestID: UInt64
    public let cryptoMaterialHandles: Set<UUID>
}
