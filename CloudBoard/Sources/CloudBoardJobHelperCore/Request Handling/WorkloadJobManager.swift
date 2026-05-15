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

import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CloudBoardJobSupportAPI
import CloudBoardLogging
import CloudBoardMetrics
import HTTPClientStateMachine
@_spi(HPKEAlgID) import CryptoKit
import Foundation
import InternalSwiftProtobuf
import os
import Synchronization
import Tracing

/// Job manager responsible for the communication with:
/// * privatecloudcomputed on the client
/// * (proxy only) ROPES to negotiate workers
/// * (proxy only) talking to/from workers
/// All those messages go through ROPES (via cloudboardd) though.
///
/// In addition it deals with unwrapping/wrapping theapplication request and response payloads to and from
/// the workload respectively.
final class WorkloadJobManager: Sendable {
    private typealias PrivateCloudComputeRequest = Proto_PrivateCloudCompute_PrivateCloudComputeRequest
    private typealias PrivateCloudComputeResponse = Proto_PrivateCloudCompute_PrivateCloudComputeResponse

    enum OutboundMessage: Equatable, Sendable {
        case chunk(FinalizableChunk<Data>)
        case findWorker(query: FindWorkerQuery, negotiate: Negotiate)
        /// The response on receiving a NegotiatePick from ROPES indicating the ensembles that may be used
        case workerNegotiatePickResponse(UUID, selectableEnsembles: EnsembleNegotiation)
        case workerDecryptionKey(UUID, keyID: Data, Data)
        case workerRequestMessage(UUID, FinalizableChunk<Data>)
        case workerRequestEOF(UUID)
        case workerError(UUID)
        case jobHelperEOF
        case requestExecutionError(RequestExecutionError)

        static func chunk(_ chunk: Data, isFinal: Bool = false) -> Self {
            .chunk(.init(chunk: chunk, isFinal: isFinal))
        }
    }

    fileprivate static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "WorkloadJobManager"
    )

    private static let unknownAttestationAppDataValue = "UNKNOWN"

    fileprivate static let tracingLogger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "WorkloadJobManager"
    )

    private let isProxy: Bool
    private let requestStream: AsyncStream<PipelinePayload>
    private let responseContinuation: AsyncStream<WorkloadJobManager.OutboundMessage>.Continuation
    private let cloudAppRequestContinuation: AsyncStream<PipelinePayload>.Continuation
    private let attestationValidator: any CloudBoardAttestationWorkerValidationProtocol

    private let jobUUID: UUID
    private let uuid: UUID
    private let stateMachine: Mutex<WorkloadJobStateMachine>
    private let buffer: Mutex<LengthPrefixBuffer>
    private let managedCloudApp: ManagedCloudAppProtocol
    private let managedSupportApps: [ManagedSupportAppProtocol]
    private let assetsMetadata: [AssetMetadata]
    private let effortDegrader: PolicyControlledEffortDegrader
    private let sessionPrivacyController: SelectionNegotiation.WorkerSessionsPrivacyController

    /// There is state not known/ready until the actual request parameters come through
    /// They are all defined here so it's clear
    struct RequestInProgress {
        let requestParameters: ParametersData

        internal init(
            requestParameters: ParametersData
        ) {
            self.requestParameters = requestParameters
        }
    }

    private let _requestInProgress: Mutex<RequestInProgress?> = .init(nil)

    enum ClientSubrequestState {
        case open(
            cryptoMaterials: [InternalCryptoMaterial],
            oneTimeToken: Data,
            timeMeasurement: ContinuousTimeMeasurement
        )
        case closed
    }

    /// State not reasonable to use unless this is a proxy,
    final class ProxyCapability: Sendable {
        let workerSessions: Mutex<[UUID: PCCWorkerSession]> = .init([:])
        // History of key IDs of reported compute node attestations as part of the Request Execution Log. Used to
        // deduplicate attestations in the REL sent back to the client in case a compute node is used more than once in
        // the context of a client request.
        let requestExecutionLogAttestations: Mutex<[Data]> = .init([])
        let relFinalized: Mutex<Bool> = .init(false)

        // The id of the request is operating under, this matters for transitive trust
        // not available till the parameters are decoded
        let requestAttestationKeyID = Mutex<Data?>(nil)
        // not known till the parameters are decoded, but easy to default to false as the safe option
        let treatAsRestrictedChoice = Mutex<Bool>(false)
        let clientSubrequestStateMap: Mutex<[UInt32: ClientSubrequestState]> = .init([:])
        internal init() {}
    }

    // non nil only if we are running in a proxy
    private let _proxyCapability: ProxyCapability?
    private var proxyCapability: ProxyCapability {
        guard let capability = self._proxyCapability else {
            fatalError("Attempt to use a codepath that requires the proxy!")
        }
        return capability
    }

    /// Unknown till we have parameters, until we know either way treat it as false regardless
    private var hasAutomatedDeviceGroup: Bool {
        !(self._requestInProgress.withLock {
            $0?.requestParameters.plaintextMetadata.automatedDeviceGroup.isEmpty ?? true
        })
    }

    /// The metrics system to use.
    private let metrics: MetricsSystem

    private let tracer: any Tracer
    private let spanID: UInt64

    private let requestHandlingSpan: Mutex<Span?> = .init(nil)
    private let responseHandlingSpan: Mutex<Span?> = .init(nil)
    private let invokeWorkloadSpan: Mutex<Span?> = .init(nil)

    private let requestMessageCount: Mutex<Int> = .init(0)
    private let responseMessageCount: Mutex<Int> = .init(0)

    init(
        tgtValidator: TokenGrantingTokenValidatorProtocol,
        enforceTGTValidation: Bool,
        effortDegrader: PolicyControlledEffortDegrader,
        isProxy: Bool,
        requestStream: AsyncStream<PipelinePayload>,
        maxRequestMessageSize: Int,
        responseContinuation: AsyncStream<WorkloadJobManager.OutboundMessage>.Continuation,
        cloudAppRequestContinuation: AsyncStream<PipelinePayload>.Continuation,
        managedCloudApp: ManagedCloudAppProtocol,
        managedSupportApps: [ManagedSupportAppProtocol],
        assetsMetadata: [AssetMetadata],
        attestationValidator: any CloudBoardAttestationWorkerValidationProtocol,
        negotiationRules: SelectionNegotiationSetup.Rules,
        metrics: MetricsSystem,
        jobUUID: UUID,
        tracer: any Tracer,
        jobHelperSpanID: UInt64
    ) {
        self.effortDegrader = effortDegrader
        self.isProxy = isProxy
        self.requestStream = requestStream
        self.responseContinuation = responseContinuation
        self.cloudAppRequestContinuation = cloudAppRequestContinuation
        self.managedCloudApp = managedCloudApp
        self.managedSupportApps = managedSupportApps
        self.assetsMetadata = assetsMetadata
        self.metrics = metrics
        self.attestationValidator = attestationValidator
        self.sessionPrivacyController = SelectionNegotiation.WorkerSessionsPrivacyController(
            rules: negotiationRules
        )

        self.jobUUID = jobUUID
        self.uuid = UUID()
        self.stateMachine = .init(WorkloadJobStateMachine(
            tgtValidator: tgtValidator,
            isProxy: isProxy,
            enforceTGTValidation: enforceTGTValidation,
            metrics: metrics,
            jobUUID: self.jobUUID,
            spanID: jobHelperSpanID
        ))
        self.buffer = .init(.init(maxMessageSize: maxRequestMessageSize))
        self.tracer = tracer
        self._proxyCapability = isProxy ? .init() : nil
        self.spanID = jobHelperSpanID
    }

    internal func run() async {
        defer {
            self.invokeWorkloadSpan.withLock { $0?.end() }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                defer {
                    self.cloudAppRequestContinuation.finish()
                    self.requestHandlingSpan.withLock { $0?.end() }
                }
                do {
                    for await message in self.requestStream {
                        self.requestMessageCount.withLock {
                            $0 += 1
                        }
                        try await self.receivePipelineMessage(message)
                    }
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Request stream finished"
                    ).log(to: Self.tracingLogger, level: .default)
                    try self.stateMachine.withLock { try $0.terminate() }
                } catch {
                    self.requestHandlingSpan.withLock { $0?.recordError(error) }
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Error handling request stream",
                        error: error
                    ).log(to: Self.tracingLogger, level: .error)
                    do {
                        // If input stream failed, signal end of input stream to the workload.
                        // The error is expected to be sent back in the response stream
                        try await self.managedCloudApp.endOfInput(error: error)
                        for supportApp in self.managedSupportApps {
                            try await supportApp.endOfInput()
                        }
                    } catch {}
                }
            }

            group.addTask {
                var jobHelperEOFSent = false
                defer {
                    if !jobHelperEOFSent {
                        self.responseContinuation.yield(.jobHelperEOF)
                    }
                    self.responseContinuation.finish()
                    self.responseHandlingSpan.withLock { $0?.end() }
                }
                var responseSummarySent = false
                do {
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Sending back response UUID"
                    ).log(to: Self.tracingLogger, level: .default)
                    try self.responseContinuation.yield(.chunk(.init(chunk: self.uuidChunk())))

                    // Wait for workload responses, encode them, and forward them
                    var uncleanAppTermination = false
                    for try await response in self.managedCloudApp.responseStream {
                        let responseMessagesReceived = self.responseMessageCount.withLock {
                            $0 += 1
                            return $0
                        }

                        await self.getWorkloadInvokeAndHandlingSpans(
                            isRequestHandlingSpan: false,
                            isResponseHandlingSpan: true
                        )

                        switch response {
                        case .chunk(let data):
                            // downsample the checkpoints we log for response chunks
                            if responseMessagesReceived <= 2 || responseMessagesReceived % 100 == 0 {
                                await WorkloadJobManagerCheckpoint(
                                    logMetadata: self.logMetadata(spanID: self.spanID),
                                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                                    message: "Received cloud app response",
                                    operationName: "received_response_chunk"
                                ).log(to: Self.tracingLogger, level: .default)
                            }
                            var serializedResponse = try PrivateCloudComputeResponse.with {
                                $0.type = .responsePayload(data)
                            }.serializedData()
                            serializedResponse.prependLength()
                            self.responseContinuation.yield(.chunk(.init(chunk: serializedResponse)))
                        case .internalError:
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received cloud app internalError notification",
                                operationName: "received_internal_error"
                            ).log(to: Self.tracingLogger, level: .default)

                            try await self.handleCloudAppError(
                                &responseSummarySent,
                                &jobHelperEOFSent
                            )
                        case .reportRequestExecutionError(let error):
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received cloud app RequestExecutionError notification",
                                operationName: "received_request_execution_error"
                            ).log(requestExecutionError: error, to: Self.tracingLogger, level: .default)

                            self.responseContinuation.yield(.requestExecutionError(error))
                            self.updateRequestExecutionErrorSpan(errorMessage: error.errorMessage)
                        case .endOfResponse:
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received cloud app endOfResponse notification",
                                operationName: "received_end_of_response"
                            ).log(to: Self.tracingLogger, level: .default)

                            // We can only send the response summary at this point if we are either a compute node, or
                            // a proxy and have already finalized the REL
                            if (self.isProxy && self.proxyCapability.relFinalized.withLock { $0 }) || !self.isProxy {
                                if !responseSummarySent {
                                    // At this point our only indication of success/failure is the possible unclean
                                    // exit,
                                    // which may not have happened or the message for it may not have reached us yet.
                                    // For now we accept this: if the cloud app cleanly terminates the response
                                    // writer, the REL is finalized (or not relevant) and *then* crashes it's
                                    // considered a success.
                                    // If the cloud app passed .internalError to us before then we would have reported
                                    // it as a failure. A more positive indication of success can be added as
                                    // a breaking change in the future
                                    let responseSummaryChunk = try self.responseSummaryChunk(
                                        treatAsFailure: uncleanAppTermination
                                    )
                                    self.responseContinuation.yield(.chunk(.init(
                                        chunk: responseSummaryChunk,
                                        isFinal: true
                                    )))
                                    self.responseContinuation.yield(.jobHelperEOF)
                                    jobHelperEOFSent = true
                                    responseSummarySent = true
                                    self.responseHandlingSpan.withLock {
                                        $0?.recordError(WorkloadJobManagerError.uncleanAppTermination)
                                    }
                                }
                                self.responseHandlingSpan.withLock {
                                    $0?.attributes.requestSummary.responseChunkAttributes.isFinal = true
                                }
                            }
                        case .endJob:
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received cloud app endJob notification",
                                operationName: "received_end_job"
                            ).log(to: Self.tracingLogger, level: .default)
                            // the job has ended - we don't finish the loop until we have also received app termination
                            // signal, but we can send the final response chunk back to the client if we hadn't
                            // previously sent it.

                            // First, send final REL entry if it has not previously been finalized
                            // Send final REL entry IFF we got to the point of sending the REL
                            if self.isProxy {
                                try await self.sendRequestExecutionLogTermination()
                            }
                            // See comments in .endOfResponse case
                            if !responseSummarySent {
                                let responseSummaryChunk = try self.responseSummaryChunk(
                                    treatAsFailure: uncleanAppTermination
                                )
                                self.responseContinuation.yield(.chunk(.init(
                                    chunk: responseSummaryChunk,
                                    isFinal: true
                                )))
                                responseSummarySent = true
                                self.responseHandlingSpan.withLock {
                                    $0?.attributes.requestSummary.responseChunkAttributes.isFinal = true
                                }
                                self.responseHandlingSpan.withLock {
                                    $0?.recordError(WorkloadJobManagerError.uncleanAppTermination)
                                }
                            }
                        case .appTermination(let terminationMetadata):
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received cloud app termination metadata",
                                operationName: "received_app_termination"
                            ).logAppTermination(
                                terminationMetadata: terminationMetadata,
                                to: Self.tracingLogger,
                                level: .default
                            )

                            if let statusCode = terminationMetadata.statusCode, statusCode != 0 {
                                uncleanAppTermination = true
                                self.responseHandlingSpan.withLock {
                                    $0?.attributes.requestSummary.responseChunkAttributes
                                        .appTerminationStatusCode = statusCode
                                }
                            }

                            if self._proxyCapability != nil {
                                // If any worker session has still not received EOF by this time
                                // we should explicitly close it, so the worker session
                                // input stream is closed.
                                self.proxyCapability.workerSessions.withLock {
                                    [responseContinuation = self.responseContinuation] in
                                    for (workerID, workerSession) in $0 {
                                        if workerSession.finishRequestStreamAndCloseSession() {
                                            responseContinuation.yield(.workerRequestEOF(workerID))
                                        }
                                    }
                                }
                            }
                        case .findWorker(let query, let subrequestID, let cryptoMaterialHandles):
                            try await self.receiveFindWorkerQuery(
                                query: query,
                                subrequestID: subrequestID,
                                cryptoMaterialHandles: cryptoMaterialHandles
                            )
                        case .workerRequestMessage(let workerID, let payload):
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received worker request message",
                                operationName: "received_worker_request"
                            ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)

                            guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[workerID] })
                            else {
                                await WorkloadJobManagerCheckpoint(
                                    logMetadata: self.logMetadata(spanID: self.spanID),
                                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                                    message: "Received worker message for unknown worker ID. Ignoring.",
                                    operationName: "worker_message_ignored"
                                ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
                                throw WorkloadJobManagerError.unknownWorkerID
                            }

                            let encapsulatedMessage = try workerSession.encapsulateMessage(payload, isFinal: false)
                            self.responseContinuation.yield(.workerRequestMessage(
                                workerID,
                                .init(chunk: encapsulatedMessage, isFinal: false)
                            ))
                        case .workerRequestEOF(let workerID, let isError):
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received worker request EOF",
                                operationName: "worker_request_eof"
                            ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)

                            guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[workerID] })
                            else {
                                await WorkloadJobManagerCheckpoint(
                                    logMetadata: self.logMetadata(spanID: self.spanID),
                                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                                    message: "Received worker request message for unknown worker ID. Ignoring.",
                                    operationName: "worker_message_ignored"
                                ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
                                throw WorkloadJobManagerError.unknownWorkerID
                            }

                            // Request chunks for the worker go through the proxy if they are not forwarded by ROPES.
                            // This can happen in 2 situations:
                            // - the request chunks are from the original client, and requestBypass is not enabled
                            // - the request chunks are not from the original client
                            let requestChunksThroughProxy = !workerSession.query.forwardRequestChunks
                            // We send EOF without the final message in case of errors
                            // since ROPES will see this as a close message, which has
                            // come before a final message, and would let the worker node
                            // know that something has gone wrong, and cancelling it's request
                            if !isError, requestChunksThroughProxy {
                                let encapsulatedMessage = try workerSession.encapsulateFinalMessage()
                                self.responseContinuation.yield(.workerRequestMessage(
                                    workerID,
                                    .init(chunk: encapsulatedMessage, isFinal: true)
                                ))
                            }
                            self.responseContinuation.yield(.workerRequestEOF(workerID))
                        case .finalizeRequestExecutionLog:
                            try await self.sendRequestExecutionLogTermination()
                        case .subresponsePayload(let subrequestID, let payload):
                            await WorkloadJobManagerCheckpoint(
                                logMetadata: self.logMetadata(spanID: self.spanID),
                                requestMessageCount: self.requestMessageCount.withLock { $0 },
                                responseMessageCount: self.responseMessageCount.withLock { $0 },
                                message: "Received sub-response payload",
                                operationName: "received_sub_response_payload"
                            ).log(to: Self.tracingLogger, level: .default)

                            // Only handle sub-responses if we're a proxy
                            guard self.isProxy else {
                                Self.logger.error("Received sub response on a non-proxy node")
                                throw WorkloadJobManagerError.receivedSubrequestOnNonProxyNode
                            }

                            guard try self.stateMachine.withLock({ try $0.protocolVersion }) != 0 else {
                                /// The client is on the old version
                                /// We don't expect to receive any sub request responses
                                /// The CloudBoardJob Framework ensures this if client is on old version
                                throw WorkloadJobManagerError.receivedSubrequestPayloadWithOlderProtocolVersion
                            }

                            // Verify that we have crypto material for this sub-request
                            let subrequestKnown = self.proxyCapability.clientSubrequestStateMap
                                .withLock { subrequestStateMap in
                                    subrequestStateMap[subrequestID] != nil
                                }
                            guard subrequestKnown else {
                                Self.logger.error(
                                    "Received sub response for unknown requestID: \(subrequestID, privacy: .public)"
                                )
                                throw WorkloadJobManagerError.unknownSubrequestID
                            }

                            // Forward sub-response payload to client
                            var serializedResponse = try PrivateCloudComputeResponse.with {
                                $0.type = .payloadChunk(.with {
                                    $0.subrequestID = subrequestID
                                    $0.chunkData = payload
                                })
                            }.serializedData()
                            serializedResponse.prependLength()
                            self.responseContinuation.yield(.chunk(.init(chunk: serializedResponse)))
                        case .endOfSubresponse(let subrequestID, let status):
                            // Only handle sub-responses if we're a proxy
                            guard self.isProxy else {
                                Self.logger.error("Received sub response on a non-proxy node")
                                throw WorkloadJobManagerError.receivedSubrequestOnNonProxyNode
                            }

                            let logLevel: OSLogType
                            switch status {
                            case .ok, .discarded:
                                logLevel = .default
                            case .error(let error):
                                logLevel = .error
                                self.updateRequestExecutionErrorSpan(
                                    subrequestID: subrequestID,
                                    errorMessage: error.errorMessage
                                )
                            }

                            let plaintextMetadata = self._requestInProgress.withLock {
                                $0?.requestParameters.plaintextMetadata
                            }

                            try await self.reportSubrequestStatus(
                                subrequestID: subrequestID,
                                status: status,
                                metadata: plaintextMetadata,
                                logLevel: logLevel
                            )

                            try self.cleanupSubrequestMetadata(subrequestID: subrequestID)

                            // Forward sub-response EOF to client
                            var serializedResponse = try PrivateCloudComputeResponse.with {
                                $0.type = .subClose(.with {
                                    $0.subrequestID = subrequestID
                                    $0.status = .init(status)
                                })
                            }.serializedData()
                            serializedResponse.prependLength()
                            self.responseContinuation.yield(.chunk(.init(chunk: serializedResponse)))
                        }
                    }

                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Cloud app response stream finished",
                        operationName: "worker_response_stream_finished"
                    ).log(to: Self.tracingLogger, level: .default)

                    // We should have already sent the summary on receiving `endOfResponse` or `endJob` from the
                    // CloudApp when finishing cleanly, but we may not have
                    if !responseSummarySent {
                        if self.isProxy {
                            try await self.sendRequestExecutionLogTermination()
                        }
                        // See comments in .endOfResponse case
                        let responseSummaryChunk = try self.responseSummaryChunk(
                            treatAsFailure: uncleanAppTermination
                        )
                        self.responseContinuation.yield(.chunk(.init(
                            chunk: responseSummaryChunk,
                            isFinal: true
                        )))
                        self.responseHandlingSpan.withLock {
                            $0?.attributes.requestSummary.responseChunkAttributes.isFinal = true
                        }
                        self.responseHandlingSpan.withLock {
                            $0?.recordError(WorkloadJobManagerError.uncleanAppTermination)
                        }
                    }

                    let plaintextMetadata = self._requestInProgress.withLock { $0?.requestParameters.plaintextMetadata }

                    self.metrics.emit(Metrics.WorkloadManager.SuccessResponsesSentCounter(
                        action: .increment,
                        automatedDeviceGroup: !(
                            plaintextMetadata?.automatedDeviceGroup
                                .isEmpty ?? true
                        ),
                        featureId: plaintextMetadata?.featureID,
                        bundleId: plaintextMetadata?.bundleID,
                        inferenceId: plaintextMetadata?.workloadParameters[workloadParameterInferenceIDKey]?.first
                    ))
                } catch {
                    self.invokeWorkloadSpan.withLock { $0?.recordError(error) }
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        requestMessageCount: self.requestMessageCount.withLock { $0 },
                        responseMessageCount: self.responseMessageCount.withLock { $0 },
                        message: "Error while processing request",
                        operationName: "error_request_processing",
                        error: error
                    ).log(to: Self.tracingLogger, level: .error)
                    do {
                        // Right now our code shouldn't allow this to happen but if we ever throw after already having
                        // sent the response summary, we shouldn't sent another one.
                        if !responseSummarySent {
                            if self.isProxy {
                                try await self.sendRequestExecutionLogTermination()
                            }

                            try self.responseContinuation.yield(
                                .chunk(.init(chunk: self.errorResponseSummaryChunk(for: error), isFinal: true))
                            )
                            if let workerError = error as? WorkloadJobManagerError {
                                switch workerError {
                                case .findWorkerFailed(let workerID, _, _), .workerSessionFailure(let workerID, _, _):
                                    self.responseContinuation.yield(.workerError(workerID))
                                default: self.sendRequestExecutionError(error: error)
                                }
                            } else {
                                self.sendRequestExecutionError(error: error)
                            }
                        }
                    } catch {
                        await WorkloadJobManagerCheckpoint(
                            logMetadata: self.logMetadata(spanID: self.spanID),
                            requestMessageCount: self.requestMessageCount.withLock { $0 },
                            responseMessageCount: self.responseMessageCount.withLock { $0 },
                            message: "Unexpectedly failed to serialize error response. Not sending error response summary",
                            operationName: "error_error_serialization",
                            error: error
                        ).log(to: Self.tracingLogger, level: .error)
                    }
                    self.invokeWorkloadSpan.withLock { $0?.recordError(error) }
                }
            }
            await group.waitForAll()
        }
    }

    private func updateRequestExecutionErrorSpan(
        subrequestID: UInt32? = nil,
        errorMessage: String
    ) {
        self.responseHandlingSpan.withLock {
            var errors = $0?.attributes.requestSummary.requestExecutionErrorAttributes.errors ?? []
            errors.append(
                RequestExecutionSpanError(
                    subrequestID: subrequestID,
                    errorMessage: errorMessage
                )
            )
            $0?.attributes.requestSummary.requestExecutionErrorAttributes.errors = errors
        }
    }

    private func sendRequestExecutionError(error: Error) {
        if let customError = error as? RequestExecutionErrorProtocol {
            self.responseContinuation.yield(.requestExecutionError(.init(
                errorSource: customError.errorSource,
                errorMessage: customError.staticStringRepresentation,
                errorCode: customError.errorCode
            )))

            self.updateRequestExecutionErrorSpan(errorMessage: customError.staticStringRepresentation.description)
        }
    }

    // Something went very wrong inside the cloud app, but it still managed to tell
    // us about it. It's likely going to crash too, but the action done here
    // avoids the cleanup code within CloudApp (which terminates everything 'nicely')
    // causing us to treat this request as a success at the PCC layer.
    // The simplest way to do that is to complete the pcc layer now (if we can)
    // The cloud app is highly unlikely to be sending anything else useful to the
    // client now so this doesn't matter.
    private func handleCloudAppError(
        _ responseSummarySent: inout Bool,
        _ jobHelperEOFSent: inout Bool
    ) async throws {
        // We have to close the REL if needed first
        if self.isProxy {
            try await self.sendRequestExecutionLogTermination()
        }
        if responseSummarySent {
            Self.logger.error(
                "Unable to report error within the cloud app to the client as the response summary has already been sent"
            )
            // Throwing at this point would be counter productive, we do not expect this to
            // happen and if the client got a clean response first it may well be fine
        } else {
            let responseSummaryChunk = try self.responseSummaryChunk(treatAsFailure: true)
            self.responseContinuation.yield(.chunk(.init(
                chunk: responseSummaryChunk,
                isFinal: true
            )))
            self.responseContinuation.yield(.jobHelperEOF)
            jobHelperEOFSent = true
            responseSummarySent = true
            self.responseHandlingSpan.withLock {
                $0?.attributes.requestSummary.responseChunkAttributes.isFinal = true
            }
            self.responseHandlingSpan.withLock { $0?.recordError(WorkloadJobManagerError.cloudAppInternalError) }
        }
    }

    private func getWorkloadInvokeAndHandlingSpans(
        isRequestHandlingSpan: Bool,
        isResponseHandlingSpan: Bool,
        requestID: String? = nil
    ) async {
        let remotePID = await self.managedCloudApp.remotePID
        let parentSpanID = TraceContextCache.singletonCache.getSpanID(
            forKeyWithID: requestID ?? "",
            forKeyWithSpanIdentifier: SpanIdentifier.invokeWorkload
        )

        let existingContext = self.invokeWorkloadSpan.withLock {
            $0 = $0 ?? self.tracer.startSpan(
                OperationNames.invokeWorkload,
                context: ServiceContext.topLevel
            )
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.spanID = self.spanID
            if parentSpanID != nil {
                $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.parentSpanID = parentSpanID
            }

            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.jobUUID = self.jobUUID.uuidString
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.remotePID = remotePID
            return $0?.context
        }

        if isRequestHandlingSpan {
            let requestMessageCount = self.requestMessageCount.withLock { $0 }
            self.requestHandlingSpan.withLock {
                $0 = $0 ?? self.tracer.startSpan(
                    OperationNames.invokeWorkloadRequest,
                    context: existingContext ?? ServiceContext.topLevel
                )
                $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.requestMessageCount = requestMessageCount
            }
        }
        if isResponseHandlingSpan {
            let responseMessageCount = self.responseMessageCount.withLock { $0 }
            self.responseHandlingSpan.withLock {
                $0 = $0 ?? self.tracer.startSpan(
                    OperationNames.invokeWorkloadResponse,
                    context: existingContext ?? ServiceContext.topLevel
                )
                $0?.attributes.requestSummary.responseChunkAttributes.responseMessagesCount = responseMessageCount
            }
        }
    }

    private func reportSubrequestStatus(
        subrequestID: UInt32,
        status: InternalSubresponseStatus,
        metadata: ParametersData.PlaintextMetadata?,
        logLevel: OSLogType
    ) async throws {
        let duration = try self.proxyCapability.clientSubrequestStateMap.withLock { subrequestStateMap in
            switch subrequestStateMap[subrequestID] {
            case .closed:
                throw WorkloadJobManagerError.closedSubrequestID
            case .open(_, _, let measurement):
                return measurement.duration
            case .none:
                Self.logger.error(
                    "Received sub response EOF for unknown requestID: \(subrequestID, privacy: .public)"
                )
                throw WorkloadJobManagerError.unknownSubrequestID
            }
        }

        self.metrics.emit(Metrics.WorkloadManager.SubrequestDuration(
            duration: duration,
            automatedDeviceGroup: !(metadata?.automatedDeviceGroup.isEmpty ?? true),
            featureId: metadata?.featureID,
            bundleId: metadata?.bundleID,
            inferenceId: metadata?.workloadParameters[workloadParameterInferenceIDKey]?.first,
            status: status
        ))

        switch status {
        case .ok:
            // Nothing to do
            ()
        case .discarded, .error:
            self.metrics.emit(Metrics.WorkloadManager.SubrequestFailureCounter(
                action: .increment,
                automatedDeviceGroup: !(metadata?.automatedDeviceGroup.isEmpty ?? true),
                featureId: metadata?.featureID,
                bundleId: metadata?.bundleID,
                inferenceId: metadata?.workloadParameters[workloadParameterInferenceIDKey]?.first,
                status: status
            ))
        }

        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            requestMessageCount: self.requestMessageCount.withLock { $0 },
            responseMessageCount: self.responseMessageCount.withLock { $0 },
            message: "Received end of sub-response",
            operationName: "received_end_of_sub_response"
        ).log(
            subrequestID: subrequestID,
            subresponseStatus: status,
            duration: duration,
            to: Self.tracingLogger,
            level: logLevel
        )
    }

    private func cleanupSubrequestMetadata(subrequestID: UInt32) throws {
        guard try self.stateMachine.withLock({ try $0.protocolVersion }) != 0 else {
            /// The client is on the old version
            /// We don't expect to receive any sub request responses
            /// The CloudBoardJob Framework ensures this if client is on old version
            throw WorkloadJobManagerError.receivedSubrequestPayloadWithOlderProtocolVersion
        }
        // Clean up the sub-request
        try self.proxyCapability.clientSubrequestStateMap.withLock { subrequestStateMap in
            switch subrequestStateMap[subrequestID] {
            case .closed:
                throw WorkloadJobManagerError.closedSubrequestID
            case .open:
                subrequestStateMap[subrequestID] = .closed
            case .none:
                Self.logger.error(
                    "Received sub response EOF for unknown requestID: \(subrequestID, privacy: .public)"
                )
                throw WorkloadJobManagerError.unknownSubrequestID
            }
        }
    }

    // Used for .nackAndExit and normal .parameters
    // nothing expensive should happen here, just assign all the state we don't know till we get them
    private func registerParametersData(parametersData: ParametersData) async {
        await self.getWorkloadInvokeAndHandlingSpans(
            isRequestHandlingSpan: true,
            isResponseHandlingSpan: false,
            requestID: parametersData.plaintextMetadata.requestID
        )
        self.requestHandlingSpan.withLock {
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.receivedParameters = true
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.requestID = parametersData.plaintextMetadata
                .requestID
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.bundleID = parametersData.plaintextMetadata
                .bundleID
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.featureID = parametersData.plaintextMetadata
                .featureID
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.automatedDeviceGroup = parametersData
                .plaintextMetadata.automatedDeviceGroup
            $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.workload = parametersData.plaintextMetadata
                .workloadType
        }

        self._requestInProgress.withLock { $0 = RequestInProgress(requestParameters: parametersData) }
        self.stateMachine.withLock {
            $0.receiveRequestID(requestID: parametersData.plaintextMetadata.requestID)
            $0.receiveAutomatedDeviceGroup(automatedDeviceGroup: parametersData.plaintextMetadata.automatedDeviceGroup)
            $0.receiveFeatureID(featureID: parametersData.plaintextMetadata.featureID)
            $0.receiveBundleID(bundleID: parametersData.plaintextMetadata.bundleID)
            $0.receiveInferenceID(
                inferenceID: parametersData.plaintextMetadata.workloadParameters[workloadParameterInferenceIDKey]?.first
            )
        }
    }

    /// The rules used in negotiation will ignore this if it's not legal to relax them
    /// so we can just set this based on whether it would be relevant.
    private func determineIfShouldTreatAsRestrictedChoice(
        workload: [String: [String]]
    ) async throws -> Bool {
        // The use of hard coded strings for the keys here is deliberate.
        // These are defined in ROPES, it is _significant_ effort to change then so
        // they are defined here *and* in tests to ensure they are not changed accidentally
        let explicitModeKey = "cb_treat_as_restricted_choice_mode"
        if let explicitRestrictedMode = workload[explicitModeKey] {
            // currently we allow anything that parses as true or false
            // if this ever becomes more flexible the old mechanisms need to be retained.
            // Since this is used in testing scenarios only we are strict in what we accept
            // so failures are found fast
            // We allow for limited backward compatible expansion by allowing multiple values,
            // but only using the first one
            guard let mode = explicitRestrictedMode.first else {
                throw CloudBoardJobHelperError.restrictedChoiceModeInvalid(
                    details: "\(explicitModeKey) is an empty list, it should be a single value"
                )
            }
            // if it fails to parse we treat it as an error so the source can fix themselves
            guard let asBool = Bool(mode) else {
                throw CloudBoardJobHelperError.restrictedChoiceModeInvalid(
                    details: "\(explicitModeKey) first value was \(mode), it should be a bool"
                )
            }
            // This will be ignored in customer, RGA, if any, is treated as entirely irrelevant
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: asBool ?
                    "May treat this request as restricted choice based on explicit mode" :
                    "May not treat this request as restricted based on explicit mode"
            ).log(
                to: Self.tracingLogger,
                // This is unusual so we log it a higher to ensure it is visible
                level: .default
            )
            return asBool
        } else if workload["routing_group_alias"] != nil {
            // The existence of this parameter is only used when an RGA is being applied to the
            // compute selections, This implies the set of choices is restricted in ways the proxy
            // cannot control or know about. This may result in less restrictive rules being used
            // outsaide of customer to help the system function effectively
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "May treat this request as restricted based on routing_group_alias"
            ).log(to: Self.tracingLogger, level: .info)
            return true
        } else {
            return false
        }
    }

    private func receivePipelineMessage(_ pipelineMessage: PipelinePayload) async throws {
        self.metrics.emit(Metrics.WorkloadManager.TotalRequestsReceivedCounter(
            action: .increment,
            automatedDeviceGroup: self.hasAutomatedDeviceGroup
        ))
        do {
            switch pipelineMessage {
            case .warmup(let warmupData):
                self.requestHandlingSpan.withLock {
                    $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.receivedSetup = true
                }
                self.cloudAppRequestContinuation.yield(.warmup(warmupData))
            case .nackAndExit(let parametersData):
                await self.registerParametersData(parametersData: parametersData)
                self.requestHandlingSpan.withLock {
                    $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.isNack = true
                }
                // treat this like an abandon in most respects
                self.stateMachine.withLock { $0.abandon() }
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Sending NACK and exiting"
                ).log(to: Self.tracingLogger, level: .default)
                // an empty REL is what constitutes a NACK
                try await self.sendRequestExecutionLogTermination()
                self.cloudAppRequestContinuation.yield(.abandon)
            case .oneTimeToken(let token):
                await self.getWorkloadInvokeAndHandlingSpans(isRequestHandlingSpan: true, isResponseHandlingSpan: false)
                self.requestHandlingSpan.withLock {
                    $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.receivedToken = true
                }
                try self.stateMachine.withLock { try $0.receiveOneTimeToken(token) }
            case .parameters(let parametersData):
                await self.registerParametersData(parametersData: parametersData)

                self.stateMachine.withLock { $0.receivedRequestBypassMode(bypassed: parametersData.requestBypassed) }

                self.cloudAppRequestContinuation.yield(.parameters(parametersData))
            case .chunk(let finalizableChunk):
                await self.getWorkloadInvokeAndHandlingSpans(isRequestHandlingSpan: true, isResponseHandlingSpan: false)
                self.requestHandlingSpan.withLock {
                    $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.isFinal = finalizableChunk.isFinal
                }

                // The ROPES test client sends 0-byte payloads as final chunks. These aren't expected to be serialized
                // PrivateCloudCompute messages but exist to finalize the request stream.
                if finalizableChunk.chunk.isEmpty, finalizableChunk.isFinal {
                    Self.logger.debug("Received final 0-byte payload, forwarding as end of input")
                    try self.buffer.withLock { try $0.validateCompleteDataChunksReceived() }
                    self.cloudAppRequestContinuation.yield(.endOfInput)
                } else {
                    try await self.receiveEncodedRequest(finalizableChunk)
                }
            case .endOfInput, .openClientSubrequest, .subrequestPayload, .closeSubrequest, .cancelSubrequest,
                 .applicationDataChunkingConfig:
                // These cases should not be received from the pipeline. ``endOfInput`` is generated internally by
                // WorkloadJobManager when processing FinalMessage or empty final chunks, not received as input.
                Self.logger.error(
                    "Unexpectedly received message of type \(pipelineMessage.publicDescription, privacy: .public) from cloudboardd"
                )
                fatalError(
                    "Unexpectedly received message of type \(pipelineMessage.publicDescription) from cloudboardd"
                )
            case .abandon:
                await self.getWorkloadInvokeAndHandlingSpans(isRequestHandlingSpan: true, isResponseHandlingSpan: false)
                self.requestHandlingSpan.withLock {
                    $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.abandon = true
                }
                self.stateMachine.withLock { $0.abandon() }
                self.cloudAppRequestContinuation.yield(.abandon)
            case .teardown:
                await self.getWorkloadInvokeAndHandlingSpans(isRequestHandlingSpan: true, isResponseHandlingSpan: false)
                self.requestHandlingSpan.withLock {
                    $0?.attributes.requestSummary.pipelinePayloadRequestAttributes.teardown = true
                }
                self.cloudAppRequestContinuation.yield(.teardown)
            case .parametersMetaData(let keyID, let workload):
                if self.isProxy {
                    self.proxyCapability.requestAttestationKeyID.withLock { $0 = keyID }
                    let treatAsRestrictedIfPossible = try await self.determineIfShouldTreatAsRestrictedChoice(
                        workload: workload
                    )
                    self.proxyCapability.treatAsRestrictedChoice.withLock {
                        $0 = treatAsRestrictedIfPossible
                    }
                }
                // yielded primarily to allow tests to spot that this occurred
                // it's dropped later and doesn't make it to the cloud app itself
                self.cloudAppRequestContinuation.yield(pipelineMessage)
            case .workerFound(let workerID, _, let spanID):
                // We should replace PipelinePayload with multiple types so we aren't forced to handle cases that are
                // never expected to happen. .workerFound is only used between WorkloadJobManager and the cloud app,
                // same as .endOfInput above.
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: spanID),
                    message: "Received unexpected workerFound message from cloudboardd"
                ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
            case .workerNegotiatePick(let providedByRopes):
                try await self.workerNegotiatePick(
                    info: providedByRopes
                )
            case .selectedWorker(let workerAttestationInfo, let dek, let workloadParameters):
                try await self.notificationOfSelectedWorker(
                    info: workerAttestationInfo,
                    dataEncryptionKey: dek,
                    workloadParameters: workloadParameters
                )
            case .workerResponseChunk(let workerID, let chunk):
                try await self.receiveWorkerResponseChunk(workerID: workerID, chunk: chunk)
            case .workerResponseSummary(let workerID, _):
                // We never expect to receive a workerResponseSummary from CloudBoardMessenger
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Received unexpected workerResponseSummary message from cloudboardd"
                ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
            case .workerResponseClose(
                let workerID,
                let grpcStatus,
                let grpcMessage,
                let ropesErrorCode,
                let ropesMessage
            ):
                try await self.receiveWorkerResponseClose(
                    workerID: workerID,
                    grpcStatus: grpcStatus,
                    grpcMessage: grpcMessage,
                    ropesErrorCode: ropesErrorCode,
                    ropesMessage: ropesMessage
                )
            case .workerResponseEOF(let workerID):
                try await self.receiveWorkerResponseEOF(workerID: workerID)
            case .readyToSendAssetsMetadataRELEntry:
                /// We need to always send the assetMetadata REL entry from a worker node
                /// even if there are no assets. This serves as a signal for the proxy node
                /// to help finalise it's own REL to the client.
                /// A proxy node only needs to send this entry if it loads any assets itself.
                if !self.isProxy || !self.assetsMetadata.isEmpty {
                    try await self.makeProtoAndSendRequestExecutionLogEntry(
                        attestationInfo: nil,
                        responseBypass: nil,
                        assetsMetadata: self.assetsMetadata.map { assetMetadata in
                            .with {
                                $0.assetID = assetMetadata.id
                                $0.applicationID = assetMetadata.consumerID
                                $0.hash = assetMetadata.identityHash
                                $0.version = assetMetadata.version
                            }
                        },
                        isFinal: !self.isProxy
                    )
                }
            }
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                requestMessageCount: self.requestMessageCount.withLock { $0 },
                responseMessageCount: self.responseMessageCount.withLock { $0 },
                message: "received pipeline message"
            ).logReceiveRequestPipelineMessage(
                pipelineMessage: pipelineMessage,
                to: Self.tracingLogger,
                level: .default
            )
        } catch {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                requestMessageCount: self.requestMessageCount.withLock { $0 },
                responseMessageCount: self.responseMessageCount.withLock { $0 },
                message: "received pipeline message"
            ).logReceiveRequestPipelineMessage(
                pipelineMessage: pipelineMessage,
                to: Self.tracingLogger,
                level: .default
            )
            self.requestHandlingSpan.withLock { $0?.recordError(error) }
            throw error
        }
    }

    private func receiveEncodedRequest(_ encodedRequestChunk: FinalizableChunk<Data>) async throws {
        let chunks = try self.buffer.withLock {
            try $0.append(encodedRequestChunk)
        }
        for chunk in chunks {
            switch try PrivateCloudComputeRequest(serializedBytes: chunk.chunk).type {
            case .applicationPayload(let payload):
                // Check if protocol version > 0, which should not use applicationPayload
                guard try self.stateMachine.withLock({ try $0.protocolVersion }) == 0 else {
                    // Abandon the workload and throw
                    self.stateMachine.withLock { $0.abandon() }
                    throw WorkloadJobManagerError.receivedApplicationPayloadWithNewerProtocolVersion
                }

                if try self.stateMachine.withLock({ try $0.requestBypassed }) {
                    // Abandon the workload and throw
                    self.stateMachine.withLock { $0.abandon() }
                    throw WorkloadJobManagerError.receivedApplicationPayloadWithRequestBypassEnabled
                }

                if let cloudAppRequest = stateMachine.withLock({ $0.receiveChunk(FinalizableChunk(
                    chunk: payload,
                    isFinal: chunk.isFinal
                )) }) {
                    self.cloudAppRequestContinuation.yield(.chunk(cloudAppRequest))
                }
            case .open(let open):
                // Store the protocol version for later validation
                try self.stateMachine.withLock { try $0.setProtocolVersion(open.version) }
                try self.handleCapabilities(capabilities: open.capabilities)
                try await self.handleAuthToken(tgt: open.tokenGrantingToken, ottSalt: open.ottSalt)
            case .finalMessage:
                // This is a message without payload allowing privatecloudcomputed to explicitly indicate the end of the
                // request stream
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                    message: "Received final message"
                ).log(to: Self.tracingLogger, level: .default)
                try self.buffer.withLock { try $0.validateCompleteDataChunksReceived() }
                self.cloudAppRequestContinuation.yield(.endOfInput)
            case .payloadChunk(let payload):
                try self.newVersionCheck()
                guard self.isProxy else {
                    throw WorkloadJobManagerError.receivedSubrequestOnNonProxyNode
                }

                if try self.stateMachine.withLock({ try $0.requestBypassed }) {
                    // Abandon the workload and throw
                    self.stateMachine.withLock { $0.abandon() }
                    throw WorkloadJobManagerError.receivedApplicationPayloadWithRequestBypassEnabled
                }

                try self.proxyCapability.clientSubrequestStateMap.withLock { subrequestStateMap in
                    guard subrequestStateMap.keys.contains(payload.subrequestID) else {
                        throw WorkloadJobManagerError.unknownSubrequestID
                    }
                }

                if let cloudAppRequest = stateMachine.withLock({ $0.receiveChunk(FinalizableChunk(
                    chunk: payload.chunkData,
                    isFinal: chunk.isFinal
                )) }) {
                    self.cloudAppRequestContinuation.yield(.subrequestPayload(
                        clientSubrequestId: payload.subrequestID,
                        chunk: cloudAppRequest.chunk
                    ))
                }
            case .subOpen(let subOpen):
                try self.newVersionCheck()
                guard self.isProxy else {
                    throw WorkloadJobManagerError.receivedSubrequestOnNonProxyNode
                }

                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Subrequest opened",
                    operationName: "received_subrequest_open"
                ).log(
                    to: Self.tracingLogger,
                    subrequestID: subOpen.subrequestID,
                    cryptoMaterialCount: subOpen.opaqueCryptoMaterial.count,
                    level: .default
                )

                try self.proxyCapability.clientSubrequestStateMap.withLock { subrequestStateMap in
                    guard !subrequestStateMap.keys.contains(subOpen.subrequestID) else {
                        throw WorkloadJobManagerError.receivedDuplicateOpenClientSubrequest
                    }
                    let cryptoMaterials: [InternalCryptoMaterial] = subOpen.opaqueCryptoMaterial.map {
                        .init(handle: .init(uuid: UUID()), id: $0.id, material: $0.material)
                    }
                    // We do not enforce OTTs to be provided for subrequests to allow for flexible enforcement by ROPES.
                    subrequestStateMap[subOpen.subrequestID] = .open(
                        cryptoMaterials: cryptoMaterials,
                        oneTimeToken: subOpen.oneTimeToken,
                        timeMeasurement: ContinuousTimeMeasurement.start()
                    )
                    let isDiscardable = subOpen.priority == .requestExecutionPriorityDiscardable

                    self.cloudAppRequestContinuation.yield(.openClientSubrequest(
                        clientSubrequestId: subOpen.subrequestID,
                        cryptoMaterialHandles: cryptoMaterials.map { $0.handle },
                        isDiscardable: isDiscardable
                    ))

                    /// At this point we can let the client know that it can expect to
                    /// receive responses for this sub request
                    var serializedResponse = try PrivateCloudComputeResponse.with {
                        $0.type = .subOpen(.with {
                            $0.subrequestID = subOpen.subrequestID
                        })
                    }.serializedData()
                    serializedResponse.prependLength()
                    self.responseContinuation.yield(.chunk(.init(chunk: serializedResponse)))
                }
            case .subClose(let subClose):
                try self.newVersionCheck()
                guard self.isProxy else {
                    throw WorkloadJobManagerError.receivedSubrequestOnNonProxyNode
                }

                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Subrequest closed",
                    operationName: "received_subrequest_close"
                ).log(
                    to: Self.tracingLogger,
                    subrequestID: subClose.subrequestID,
                    level: .default
                )

                try self.proxyCapability.clientSubrequestStateMap.withLock { subrequestStateMap in
                    guard subrequestStateMap.keys.contains(subClose.subrequestID) else {
                        throw WorkloadJobManagerError.unknownSubrequestID
                    }
                }

                self.cloudAppRequestContinuation.yield(.closeSubrequest(clientSubrequestId: subClose.subrequestID))
            case .subCancel(let subCancel):
                try self.newVersionCheck()
                guard self.isProxy else {
                    throw WorkloadJobManagerError.receivedSubrequestOnNonProxyNode
                }

                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Subrequest cancelled",
                    operationName: "received_subrequest_cancel"
                ).log(
                    to: Self.tracingLogger,
                    subrequestID: subCancel.subrequestID,
                    level: .default
                )

                try self.proxyCapability.clientSubrequestStateMap.withLock { subrequestStateMap in
                    guard subrequestStateMap.keys.contains(subCancel.subrequestID) else {
                        throw WorkloadJobManagerError.unknownSubrequestID
                    }
                }

                self.cloudAppRequestContinuation.yield(.cancelSubrequest(clientSubrequestId: subCancel.subrequestID))
            case .proxyInvokeOpen(let proxyInvokeOpen):
                guard !self.isProxy else {
                    throw WorkloadJobManagerError.receivedProxyInvokeOnProxyNode
                }
                try self.handleCapabilities(capabilities: proxyInvokeOpen.capabilities)
                try await self.handleAuthToken(
                    tgt: proxyInvokeOpen.tokenGrantingToken,
                    ottSalt: proxyInvokeOpen.ottSalt
                )

                // For now we don't pass crypto material handles to compute node cloud apps, so just create the UUID
                // on the spot here
                let cryptoMaterial = proxyInvokeOpen.opaqueCryptoMaterial.map { protoCryptoMaterial in
                    InternalCryptoMaterial(
                        handle: .init(uuid: UUID()),
                        id: protoCryptoMaterial.id,
                        material: protoCryptoMaterial.material
                    )
                }
                for supportApp in self.managedSupportApps {
                    for material in cryptoMaterial {
                        await WorkloadJobManagerCheckpoint(
                            logMetadata: self.logMetadata(spanID: self.spanID),
                            message: "Forwarding crypto material",
                            operationName: "forward_crypto_material"
                        ).log(
                            to: Self.tracingLogger,
                            supportAppPID: supportApp.remotePID,
                            cryptoMaterialHandle: material.handle.uuid,
                            level: .default
                        )
                    }

                    try await supportApp.receiveCryptoMaterial(cryptoMaterial)
                }
            case .none:
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    requestMessageCount: self.requestMessageCount.withLock { $0 },
                    responseMessageCount: self.responseMessageCount.withLock { $0 },
                    message: "Received encoded request of unknown type, ignoring"
                ).log(to: Self.tracingLogger, level: .debug)
            }
        }
    }

    private func handleAuthToken(tgt: Data, ottSalt: Data) async throws {
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            requestMessageCount: self.requestMessageCount.withLock { $0 },
            responseMessageCount: self.responseMessageCount.withLock { $0 },
            message: "Received auth token"
        ).log(to: Self.tracingLogger, level: .default)
        for cloudAppRequest in try self.stateMachine.withLock({ try $0.receiveAuthToken(
            tokenGrantingToken: tgt,
            onetimeTokenSalt: ottSalt
        ) }) {
            switch cloudAppRequest {
            case .chunk(let chunk):
                self.cloudAppRequestContinuation.yield(.chunk(chunk))
            case .finalMessage:
                self.cloudAppRequestContinuation.yield(.endOfInput)
                for supportApp in self.managedSupportApps {
                    try await supportApp.endOfInput()
                }
            }
        }
    }

    private func handleCapabilities(capabilities: Proto_PrivateCloudCompute_Capabilities) throws {
        var chunkingConfig: ApplicationDataChunkingConfiguration = .disabled
        if capabilities.isInitialized, capabilities.hasApplicationDataChunking {
            if capabilities.applicationDataChunking.size > 0 {
                chunkingConfig = .enabled(chunkSize: Int(capabilities.applicationDataChunking.size))
            }
        }
        try self.stateMachine.withLock { try $0.receiveApplicationDataChunkingConfig(config: chunkingConfig) }
        self.cloudAppRequestContinuation.yield(.applicationDataChunkingConfig(chunkingConfig))
    }

    private func newVersionCheck() throws {
        guard try self.stateMachine.withLock({ try $0.protocolVersion }) > 0 else {
            // Abandon the workload and throw
            self.stateMachine.withLock { $0.abandon() }
            throw WorkloadJobManagerError.receivedSubrequestPayloadWithOlderProtocolVersion
        }
    }

    private func receiveFindWorkerQuery(
        query: FindWorkerQuery,
        subrequestID: UInt32?,
        cryptoMaterialHandles: [CryptoMaterialHandle]
    ) async throws {
        let workerID = query.workerID
        let findWorkerDurationMeasurement =
            OSAllocatedUnfairLock<ContinuousTimeMeasurement>(initialState: ContinuousTimeMeasurement.start())
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: query.spanID),
            requestMessageCount: self.requestMessageCount.withLock { $0 },
            responseMessageCount: self.responseMessageCount.withLock { $0 },
            message: "Received request to find worker"
        ).log(
            workerID: workerID,
            serviceName: query.serviceName,
            routingParameters: query.routingParameters,
            groupID: query.groupID,
            to: Self.tracingLogger,
            level: .default
        )

        // Best effort attempt to fail early in case a previous session was marked as final. We additionally enforce
        // not sending the re-wrapped DEK if the REL has previously been finalized at the time we receive the worker
        // attestation from ROPES (see `sendRequestExecutionLogEntry`).
        let previousSessionWasFinal = self.proxyCapability.workerSessions.withLock {
            $0.values.contains(where: { $0.isFinal })
        }
        guard !previousSessionWasFinal else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: query.spanID),
                message: "Received request to find a worker while a previous worker request was marked as final"
            ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
            throw WorkloadJobManagerError.workerRequestAfterFinal
        }

        // We must wait for the auth token to have been received before we can make an outbound request as we otherwise
        // risk for the worker attestation to come back before we receive the auth token. As both messages are handled
        // by the same AsyncStream-consuming task in WorkloadJobManager, we cannot await the auth token message while
        // handling the worker attestation as that would result in a deadlock. Therefore, we wait here instead. Note
        // that this can result in a latency hit when the client delays sending the auth token which otherwise could be
        // received and processed in parallel to finding a worker and validating its attestation.
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Waiting for auth token before progressing with worker request"
        ).log(workerID: workerID, to: Self.tracingLogger, level: .default)
        let authTokenData = try await self.stateMachine.withLock {
            try $0.awaitAuthTokens()
        }.valueWithCancellation

        let (cryptoMaterialsForWorkerSession, oneTimeToken) = try self.proxyCapability.clientSubrequestStateMap
            .withLock {
                if let subrequestID {
                    guard let subrequestState = $0[subrequestID] else {
                        throw WorkloadJobManagerError.unknownSubrequestID
                    }
                    switch subrequestState {
                    case .closed:
                        throw WorkloadJobManagerError.closedSubrequestID
                    case .open(let allCryptoMaterials, let subrequestOneTimeToken, _):
                        // Using oneTimeToken received in subOpen
                        if !cryptoMaterialHandles.isEmpty {
                            let matchingCryptoMaterials = allCryptoMaterials.filter { cryptoMaterial in
                                cryptoMaterialHandles.contains(cryptoMaterial.handle)
                            }
                            guard matchingCryptoMaterials.count == cryptoMaterialHandles.count else {
                                throw WorkloadJobManagerError.unknownCryptoMaterialHandle
                            }
                            return (matchingCryptoMaterials, subrequestOneTimeToken)
                        } else {
                            return ([], subrequestOneTimeToken)
                        }
                    }
                } else {
                    // Using oneTimeToken received in parameters from ROPES
                    return ([], authTokenData.oneTimeToken)
                }
            }

        let sessionExisted = try self.proxyCapability.workerSessions.withLock { workerSessions in
            guard workerSessions[query.workerID] == nil else {
                return true
            }

            let negotiation = try self.sessionPrivacyController.beginNewNegotiation(
                groupID: query.groupID,
                reuse: query.reuseTarget,
                // This was determined on being informed of the parameters, so can be relied upon at
                // the point we try to find a worker
                treatAsRestrictedChoice: self.proxyCapability.treatAsRestrictedChoice.withLock { $0 }
            )

            let workerSession = PCCWorkerSession(
                workerID: workerID,
                query: query,
                responseBypassMode: ResponseBypassMode(requested: query.responseBypass),
                isFinal: query.isFinal,
                findWorkerDurationMeasurement: findWorkerDurationMeasurement,
                cryptoMaterials: cryptoMaterialsForWorkerSession,
                negotiation: negotiation
            )
            workerSessions[workerID] = workerSession
            var updatedQuery = query
            updatedQuery.oneTimeToken = oneTimeToken
            try self.responseContinuation.yield(
                .findWorker(
                    query: self.applyPrivacyTransform(updatedQuery),
                    negotiate: workerSession.negotiation.forROPES
                )
            )
            return false
        }

        if sessionExisted {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: query.spanID),
                requestMessageCount: self.requestMessageCount.withLock { $0 },
                responseMessageCount: self.responseMessageCount.withLock { $0 },
                message: "Worker session already exists. Ignoring."
            ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
            throw WorkloadJobManagerError.unknownWorkerID
        }
    }

    private func applyPrivacyTransform(_ query: FindWorkerQuery) throws -> FindWorkerQuery {
        var degraded = query
        degraded.effort = try self.effortDegrader.degrade(query.effort)
        return degraded
    }

    private func workerNegotiatePick(
        info: WorkerNegotiatePickInfo
    ) async throws {
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: info.spanID),
            message: "Received worker ensemble negotiation"
        ).log(workerID: info.workerID, to: Self.tracingLogger, level: .default)

        guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[info.workerID] }) else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: info.spanID),
                message: "Received worker ensemble negotiation for unknown worker ID"
            ).log(workerID: info.workerID, to: Self.tracingLogger, level: .error)
            throw WorkloadJobManagerError.unknownWorkerID
        }
        do {
            let selectableEnsembles = try workerSession.negotiation.pickUpdate(
                providedFromROPES: info.proposed.ensembles
            )
            self.responseContinuation.yield(
                .workerNegotiatePickResponse(
                    info.workerID, selectableEnsembles: EnsembleNegotiation(selectableEnsembles)
                )
            )
        } catch {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Worker ensemble negotiation failed",
                error: error
            ).log(workerID: info.workerID, to: Self.tracingLogger, level: .error)
            // this is very deliberately entirely terminal
            self.stateMachine.withLock { $0.abandon() }
            throw WorkloadJobManagerError.workerAttestationValidationFailed(error)
        }
    }

    private func notificationOfSelectedWorker(
        info: WorkerAttestationInfo,
        dataEncryptionKey: SymmetricKey,
        workloadParameters: [String: [String]]
    ) async throws {
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: info.spanID),
            message: "Received worker attestation"
        ).log(workerID: info.workerID, to: Self.tracingLogger, level: .default)

        guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[info.workerID] }) else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: info.spanID),
                message: "Received worker attestation for unknown worker ID"
            ).log(workerID: info.workerID, to: Self.tracingLogger, level: .error)
            throw WorkloadJobManagerError.unknownWorkerID
        }
        // Receive client-provided DEK that needs to be re-wrapped for the worker
        try workerSession.receiveDataEncryptionKey(dataEncryptionKey)

        // Validate attestation and obtain re-wrapped encapsulated DEK to be sent to worker
        let encapsulatedWorkerDEK: Data
        let bypassCapability: ResponseBypassCapability?
        let foundInfo: WorkerFoundInfo
        do {
            // Validate worker attestation and rack ID atomically
            let validationResult = try await self.attestationValidator.validateWorkerAttestation(
                // by this stage we can assert the request key must be known
                proxyAttestationKeyID: self.proxyCapability.requestAttestationKeyID.withLock { $0! },
                rawWorkerAttestationBundle: info.attestationBundle
            )

            let validatedWorker = validationResult.validatedWorker
            let rackValidation = validationResult.rackValidation

            let canTolerateMissingAppData = !self.sessionPrivacyController.requiresAttestationAppData
            func getAttestationAppData(_ key: String) throws -> String {
                guard let value = validatedWorker.appData[key] else {
                    guard canTolerateMissingAppData else {
                        throw SelectionNegotiationError.missingInformationFromWorkerAttestation(key: key)
                    }
                    return Self.unknownAttestationAppDataValue
                }
                guard let asString = value.utf8String else {
                    Self.logger.error("Attempt to parse key for \(key, privacy: .public) as UTF8 failed!")
                    throw CloudBoardAttestationAPIError.internalError
                }
                return asString
            }
            let ensembleId = try getAttestationAppData(ComputeNodeAppDataKeys.ensembleID)
            let bootId = try getAttestationAppData(ComputeNodeAppDataKeys.bootID)
            let rackId = try getAttestationAppData(ComputeNodeAppDataKeys.rackID)

            // Handle rack validation result
            switch rackValidation {
            case .allowed:
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: info.spanID),
                    message: "Worker rack validation passed",
                    operationName: "rack_validation_success"
                ).log(workerID: info.workerID, to: Self.tracingLogger, level: .debug)
            case .blocked(let rackValidationError):
                await WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: info.spanID),
                    message: "Worker blocked due to unexpected rack change.",
                    operationName: "rack_validation_blocked"
                ).log(workerID: info.workerID, to: Self.tracingLogger, level: .error)

                throw rackValidationError
            }

            // This verifies any negotiate rules against the selection
            // if it fails then the request as a whole must completely fail, since this
            // is caught, and treated as a specific case of workerAttestationValidationFailed
            // it is terminal
            try workerSession.negotiation.selectionMade(
                ensemble: EnsembleInstanceId(ensembleId: ensembleId, bootId: bootId),
                rack: RackId(rackId)
            )

            (encapsulatedWorkerDEK, bypassCapability) = try workerSession.receiveValidatedAttestation(validatedWorker)

            foundInfo = WorkerFoundInfo(
                releaseDigest: validatedWorker.releaseDigest,
                ensemble: EnsembleInstanceId(ensembleId: ensembleId, bootId: bootId),
                rack: RackId(rackId),
                workload: workloadParameters
            )
        } catch {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: info.spanID),
                message: "Worker attestation validation failed",
                error: error
            ).log(workerID: info.workerID, to: Self.tracingLogger, level: .error)
            self.stateMachine.withLock { $0.abandon() }
            throw WorkloadJobManagerError.workerAttestationValidationFailed(error)
        }

        var responseBypass: (capability: ResponseBypassCapability, contextID: UInt32)?
        if bypassCapability != nil || info.bypassContextID != nil {
            guard bypassCapability != nil else {
                throw WorkloadJobManagerError.missingResponseBypassCapability
            }
            guard info.bypassContextID != nil else {
                throw WorkloadJobManagerError.missingResponseBypassContextID
            }
            responseBypass = (capability: bypassCapability!, contextID: info.bypassContextID!)
        }

        // We should not go further than this until we have obtained and validated the TGT. As we wait for the auth
        // token to have been received and processed when we initiate the worker request it MUST be available at this
        // point.
        let authTokenData = try await self.stateMachine.withLock {
            try $0.awaitAuthTokens()
        }.valueWithCancellation

        // Send REL entry back to the client. This will throw if the REL has previously been finalized in which case
        // the encapsulated DEK will not be sent to ROPES.
        // The final REL entry will be sent when the final worker session returns a final REL message
        // instead of when we have selected the final worker.
        try await self.sendRequestExecutionLogEntry(
            attestationInfo: info,
            responseBypass: responseBypass,
            isFinal: false
        )

        // Send encapsulated DEK to worker
        self.responseContinuation.yield(.workerDecryptionKey(info.workerID, keyID: info.keyID, encapsulatedWorkerDEK))

        // The cloud app can only make outbound requests after we have received the Parameters message from ROPES
        // meaning that we also know at this point whether the node is bypassed or not. If bypassed, we don't have
        // a TGT to forward and don't need to do so because it is directly sent to the worker as part of the request
        // payload from the client.
        if !workerSession.query.forwardRequestChunks {
            // Send auth token to worker
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: info.spanID),
                message: "Sending proxy invoke open to worker"
            ).log(workerID: info.workerID, to: Self.tracingLogger, level: .debug)

            let encapsulatedProxyInvokeOpen = try workerSession.encapsulateProxyInvokeOpen(
                tgt: authTokenData.tokenGrantingToken,
                ottSalt: authTokenData.oneTimeTokenSalt,
                chunkingConfig: self.stateMachine.withLock {
                    try $0.getApplicationDataChunkingConfig()
                }
            )
            self.responseContinuation.yield(.workerRequestMessage(
                info.workerID,
                .init(chunk: encapsulatedProxyInvokeOpen, isFinal: false)
            ))
        }

        let findWorkerDuration = workerSession.findWorkerDurationMeasurement.withLock { $0.duration }
        self.metrics
            .emit(
                Metrics.WorkloadManager
                    .FindWorkerDuration(
                        duration: findWorkerDuration
                    )
            )

        // Inform cloud app that a worker has been found
        self.cloudAppRequestContinuation.yield(.workerFound(
            info.workerID,
            info: foundInfo,
            spanID: info.spanID
        ))
    }

    private func receiveWorkerResponseChunk(workerID: UUID, chunk: FinalizableChunk<Data>) async throws {
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Received worker response chunk"
        ).log(workerID: workerID, to: Self.logger, level: .debug)
        guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[workerID] }) else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received worker response chunk for unknown worker ID"
            ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
            throw WorkloadJobManagerError.unknownWorkerID
        }

        let decapsulatedMessage = try workerSession.decapsulateMessage(chunk: chunk)
        switch decapsulatedMessage.type {
        case .responseUuid:
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received response UUID for worker"
            ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)
        // Do nothing. The response UUID has been replaced with a client-provided request ID but needs to be
        // sent for backward compatibility with privatecloudcomputed.
        case .responsePayload(let payload):
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received response payload for worker"
            ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)
            self.cloudAppRequestContinuation.yield(
                .workerResponseChunk(workerID, .init(chunk: payload, isFinal: chunk.isFinal))
            )
        case .responseSummary(let summary):
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received response summary for worker"
            ).log(
                workerID: workerID,
                pccResponseStatus: summary.responseStatus.rawValue,
                to: Self.tracingLogger, level: .debug
            )
            let status: WorkerResponseStatus = summary.responseStatus == .ok ? .succeeded : .failed
            self.cloudAppRequestContinuation.yield(.workerResponseSummary(
                workerID,
                status: status
            ))
        case .requestExecutionLogEntry(let workerRelEntry):
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received REL entry from worker. Forwarding to client."
            ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)
            guard !workerRelEntry.hasAttestation else {
                throw WorkloadJobManagerError.receivedUnsupportedRELFromWorker
            }
            guard !workerRelEntry.hasResponseContext else {
                throw WorkloadJobManagerError.receivedUnsupportedRELFromWorker
            }
            guard !self.proxyCapability.relFinalized.withLock({ $0 }) else {
                throw WorkloadJobManagerError.workerAssetMetadataRELAfterFinal
            }

            /// Always send if this is the final worker session, to finalise the REL
            /// or if the worker node's REL entry has assets which should be reported to the client.
            if workerSession.isFinal || !workerRelEntry.assetMetadata.isEmpty {
                try await self.makeProtoAndSendRequestExecutionLogEntry(
                    attestationInfo: nil,
                    responseBypass: nil,
                    assetsMetadata: workerRelEntry.assetMetadata,
                    isFinal: workerSession.isFinal && workerRelEntry.final
                )
            }
        default:
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received pipeline message of unknown type"
            ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
        }
    }

    private func receiveWorkerResponseClose(
        workerID: UUID,
        grpcStatus: Int,
        grpcMessage: String?,
        ropesErrorCode: UInt32?,
        ropesMessage: String?
    ) async throws {
        guard let workerSession = self.proxyCapability.workerSessions.withLock({ $0[workerID] }) else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Received response close for unknown worker ID"
            ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
            throw WorkloadJobManagerError.unknownWorkerID
        }

        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Received gRPC status for worker"
        ).log(
            workerID: workerID,
            grpcStatus: grpcStatus,
            grpcMessage: grpcMessage,
            ropesErrorCode: ropesErrorCode,
            ropesMessage: ropesMessage,
            to: Self.tracingLogger,
            level: .debug
        )

        if let ropesErrorCode {
            try await self.handleFindWorkerRopesError(
                workerID: workerID,
                ropesErrorCode: ropesErrorCode,
                ropesMessage: ropesMessage,
                workerSession: workerSession
            )
        } else {
            let status: WorkerResponseStatus = grpcStatus == 0 ? .succeeded : .failed
            self.cloudAppRequestContinuation.yield(.workerResponseSummary(workerID, status: status))
        }
    }

    private func handleFindWorkerRopesError(
        workerID: UUID,
        ropesErrorCode: UInt32,
        ropesMessage: String?,
        workerSession: PCCWorkerSession
    ) async throws {
        if ropesErrorCode == RopesError.RESOURCE_EXHAUSTED_DISCARDABLE.rawValue {
            self.cloudAppRequestContinuation.yield(.workerResponseSummary(workerID, status: .discarded))
        } else {
            self.stateMachine.withLock { $0.abandon() }
            if !workerSession.workerFound() {
                throw WorkloadJobManagerError.findWorkerFailed(workerID, ropesErrorCode, ropesMessage)
            } else {
                throw WorkloadJobManagerError.workerSessionFailure(workerID, ropesErrorCode, ropesMessage)
            }
        }
    }

    private func receiveWorkerResponseEOF(workerID: UUID) async throws {
        await WorkloadJobManagerCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            message: "Received EOF for worker"
        ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)
        self.cloudAppRequestContinuation.yield(.workerResponseEOF(workerID))
    }

    private func sendRequestExecutionLogTermination() async throws {
        try await self.makeProtoAndSendRequestExecutionLogEntry(
            attestationInfo: nil,
            responseBypass: nil,
            assetsMetadata: [],
            isFinal: true
        )
    }

    private func sendRequestExecutionLogEntry(
        attestationInfo: WorkerAttestationInfo,
        responseBypass: (capability: ResponseBypassCapability, contextID: UInt32)?,
        isFinal: Bool
    ) async throws {
        try await self.makeProtoAndSendRequestExecutionLogEntry(
            attestationInfo: attestationInfo,
            responseBypass: responseBypass,
            assetsMetadata: [],
            isFinal: isFinal
        )
    }

    private func makeProtoAndSendRequestExecutionLogEntry(
        attestationInfo: WorkerAttestationInfo?,
        responseBypass: (capability: ResponseBypassCapability, contextID: UInt32)?,
        assetsMetadata: [Proto_PrivateCloudCompute_AssetMetadata],
        isFinal: Bool
    ) async throws {
        var attestationPreviouslyReported = false
        if self.isProxy {
            let alreadyFinalized = self.proxyCapability.relFinalized.withLock { finalized in
                let alreadyFinalized = finalized
                finalized = isFinal
                return alreadyFinalized
            }

            if alreadyFinalized {
                if attestationInfo == nil {
                    // Nothing to do
                    return
                } else {
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Asked to send request execution log entry after it was already finalized"
                    ).log(to: Self.tracingLogger, level: .error)
                    throw WorkloadJobManagerError.workerRequestAfterFinal
                }
            }

            // Deduplicate attestations in the request execution log in case a compute node is used more than once in
            // the
            // context of a single client request.
            attestationPreviouslyReported =
                self.proxyCapability.requestExecutionLogAttestations.withLock { requestExecutionLogAttestations in
                    if let attestationInfo {
                        if requestExecutionLogAttestations.contains(attestationInfo.keyID) {
                            return true
                        } else {
                            requestExecutionLogAttestations.append(attestationInfo.keyID)
                            return false
                        }
                    } else {
                        return false
                    }
                }

            guard (attestationInfo != nil && !attestationPreviouslyReported) || isFinal || responseBypass != nil ||
                !assetsMetadata.isEmpty else {
                // No need to send a REL entry if the attestation was previously reported and the REL entry otherwise
                // carries no meaningful information
                if let attestationInfo {
                    await WorkloadJobManagerCheckpoint(
                        logMetadata: self.logMetadata(spanID: self.spanID),
                        message: "Not reporting deduplicated attestation in Request Execution Log"
                    ).log(to: Self.tracingLogger, keyID: attestationInfo.keyID, level: .default)
                }
                return
            }
        }
        if isFinal {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Sending final request execution log entry"
            ).log(to: Self.tracingLogger, keyID: attestationInfo?.keyID, level: .default)
        } else {
            await WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(spanID: self.spanID),
                message: "Sending request execution log entry"
            ).log(to: Self.tracingLogger, keyID: attestationInfo?.keyID, level: .default)
        }

        let requestExecutionLogEntry: PrivateCloudComputeResponse = .with {
            $0.requestExecutionLogEntry = .with {
                if let attestationInfo, !attestationPreviouslyReported {
                    $0.attestation = attestationInfo.attestationBundle
                }
                if let responseBypass {
                    $0.responseContext = .with {
                        $0.aeadID = UInt32(responseBypass.capability.aead.value)
                        $0.aeadKey = responseBypass.capability.aeadKey.withUnsafeBytes { Data($0) }
                        $0.aeadNonce = responseBypass.capability.aeadNonce
                        $0.contextID = responseBypass.contextID
                    }
                }
                $0.assetMetadata = assetsMetadata
                $0.final = isFinal
            }
        }
        var relEntry = try requestExecutionLogEntry.serializedData()
        relEntry.prependLength()
        self.responseContinuation.yield(.chunk(.init(chunk: relEntry)))
    }

    private func uuidChunk() throws -> Data {
        let uuidMessage = PrivateCloudComputeResponse.with {
            $0.type = .responseUuid(withUnsafeBytes(of: self.uuid.uuid) { Data($0) })
        }
        var serialized = try uuidMessage.serializedData()
        serialized.prependLength()
        return serialized
    }

    private func responseSummaryChunk(treatAsFailure: Bool) throws -> Data {
        let summary: PrivateCloudComputeResponse = .with {
            $0.responseSummary = .with {
                if treatAsFailure {
                    $0.responseStatus = .internalError
                    $0.postResponseActions = .with {
                        $0.requestDiagnostics = true
                    }
                } else {
                    $0.responseStatus = .ok
                }
            }
        }
        var serializedResult = try summary.serializedData()
        serializedResult.prependLength()
        return serializedResult
    }

    private func errorResponseSummaryChunk(for error: Error) throws -> Data {
        let summary = PrivateCloudComputeResponse.with {
            $0.responseSummary = .with {
                $0.responseStatus = error.responseStatus
            }
        }
        var serializedResult = try summary.serializedData()
        serializedResult.prependLength()
        return serializedResult
    }
}

struct WorkloadJobStateMachine {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "WorkloadJobStateMachine"
    )

    private static let tracingLogger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "WorkloadJobStateMachine"
    )

    enum BufferedMessage<T> where T: Sendable {
        case chunk(FinalizableChunk<T>)
        case finalMessage
    }

    internal enum RequestBypassMode {
        case unknown
        case bypassed
        case notBypassed
    }

    internal enum State {
        case awaitingOneTimeToken(
            requestBypass: RequestBypassMode,
            bufferedMessages: [BufferedMessage<Data>],
            authTokenPromise: Promise<AuthTokenData, Error>
        )
        case awaitingTokenGrantingToken(
            requestBypass: RequestBypassMode,
            bufferedMessages: [BufferedMessage<Data>],
            oneTimeToken: Data,
            authTokenPromise: Promise<AuthTokenData, Error>
        )
        case validatedTokenGrantingToken(
            requestBypass: RequestBypassMode,
            tgt: Data,
            ottSalt: Data,
            oneTimeToken: Data
        )
        case abandoning
        case terminated(Bool)
    }

    internal struct AuthTokenData {
        var tokenGrantingToken: Data
        var oneTimeTokenSalt: Data
        var oneTimeToken: Data
    }

    private let tgtValidator: TokenGrantingTokenValidatorProtocol
    private let isProxy: Bool
    private let enforceTGTValidation: Bool
    private let metrics: MetricsSystem
    private var state: State
    private var _protocolVersion: UInt32 = 0

    private var requestID: String = ""
    private var automatedDeviceGroup: String = ""
    private var featureID: String = ""
    private var bundleID: String = ""
    private var inferenceID: String? = ""
    private let jobUUID: UUID
    private let spanID: UInt64
    private var applicationDataChunkingConfig: ApplicationDataChunkingConfiguration = .disabled

    public var abandoned: Bool {
        switch self.state {
        case .abandoning:
            return true
        case .terminated(let abandoned):
            return abandoned
        default:
            return false
        }
    }

    init(
        tgtValidator: TokenGrantingTokenValidatorProtocol,
        isProxy: Bool,
        enforceTGTValidation: Bool,
        metrics: MetricsSystem,
        jobUUID: UUID,
        spanID: UInt64
    ) {
        self.tgtValidator = tgtValidator
        self.isProxy = isProxy
        self.enforceTGTValidation = enforceTGTValidation
        self.metrics = metrics
        self.state = .awaitingOneTimeToken(
            requestBypass: .unknown,
            bufferedMessages: [],
            authTokenPromise: Promise<AuthTokenData, Error>()
        )
        self.jobUUID = jobUUID
        self.spanID = spanID
    }

    mutating func receiveChunk(_ chunk: FinalizableChunk<Data>) -> FinalizableChunk<Data>? {
        WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "receiveChunk"
        ).loggingStateChange(to: Self.tracingLogger, level: .debug) {
            switch self.state {
            case .awaitingOneTimeToken(let requestBypass, var bufferedMessages, let authTokenPromise):
                if case .bypassed = requestBypass {
                    authTokenPromise.fail(with: WorkloadJobStateMachineError.requestBypassed)
                    preconditionFailure("Received chunk with enabled request bypass")
                }
                bufferedMessages.append(.chunk(chunk))
                self.state = .awaitingOneTimeToken(
                    requestBypass: requestBypass,
                    bufferedMessages: bufferedMessages,
                    authTokenPromise: authTokenPromise
                )
                return (nil, self.state)
            case .awaitingTokenGrantingToken(let requestBypass, var bufferedMessages, let ott, let authTokenPromise):
                if case .bypassed = requestBypass {
                    authTokenPromise.fail(with: WorkloadJobStateMachineError.requestBypassed)
                    preconditionFailure("Received chunk with enabled request bypass")
                }
                bufferedMessages.append(.chunk(chunk))
                self.state = .awaitingTokenGrantingToken(
                    requestBypass: requestBypass,
                    bufferedMessages: bufferedMessages,
                    oneTimeToken: ott,
                    authTokenPromise: authTokenPromise
                )
                return (nil, self.state)
            case .validatedTokenGrantingToken(let requestBypass, _, _, _):
                precondition(requestBypass == .notBypassed, "Received chunk with enabled request bypass")
                return (chunk, self.state)
            case .abandoning:
                preconditionFailure("Received chunk after instance abandoned")
            case .terminated:
                preconditionFailure("Received chunk while already terminated")
            }
        }
    }

    mutating func receiveOneTimeToken(
        _ oneTimeToken: Data
    ) throws {
        try WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "receiveOneTimeToken"
        ).loggingStateChange(to: Self.tracingLogger, level: .debug) {
            switch self.state {
            case .awaitingOneTimeToken(let requestBypass, let chunks, let authTokenPromise):
                self.state = .awaitingTokenGrantingToken(
                    requestBypass: requestBypass,
                    bufferedMessages: chunks,
                    oneTimeToken: oneTimeToken,
                    authTokenPromise: authTokenPromise
                )
                return ((), self.state)
            case .awaitingTokenGrantingToken, .validatedTokenGrantingToken:
                throw TokenGrantingTokenError.receivedOneTimeTokenTwice
            case .abandoning:
                preconditionFailure("Received OTT after instance abandoned")
            case .terminated:
                preconditionFailure("Received one-time token while already terminated")
            }
        }
    }

    mutating func receiveAuthToken(
        tokenGrantingToken: Data,
        onetimeTokenSalt: Data,
    ) throws -> [BufferedMessage<Data>] {
        try WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "receiveAuthToken"
        ).loggingStateChange(to: Self.tracingLogger, level: .debug) {
            switch self.state {
            case .awaitingOneTimeToken:
                // Unexpected, we should always receive the one-time token before the token granting token
                throw TokenGrantingTokenError.missingOneTimeToken
            case .awaitingTokenGrantingToken(let requestBypass, let bufferedMessages, let ott, let authTokenPromise):
                do {
                    let tgt = tokenGrantingToken
                    let ottSalt = onetimeTokenSalt
                    // ROPES sends an empty OTT to compute nodes for proxied requests. Since the proxy will not provide
                    // the DEK until it has validated the TGT we do not have to re-validate it on compute nodes.
                    if self.isProxy || !ott.isEmpty {
                        try self.validateToken(tgt: tgt, ott: ott, ottSalt: ottSalt)
                    } else {
                        self.tgtValidator.notifyOfUnvalidatedTokenGrantingToken(tgt, ottSalt: ottSalt)
                        WorkloadJobManagerCheckpoint(
                            logMetadata: self.logMetadata(),
                            message: "Received auth token without one-time token, assuming TGT has been validated on proxy",
                            operationName: "validateToken"
                        ).log(to: WorkloadJobManager.tracingLogger, level: .default)
                    }
                    self.state = .validatedTokenGrantingToken(
                        requestBypass: requestBypass,
                        tgt: tgt,
                        ottSalt: ottSalt,
                        oneTimeToken: ott
                    )
                    switch requestBypass {
                    case .unknown:
                        throw WorkloadJobStateMachineError.requestBypassStateUnknown
                    case .bypassed:
                        if !bufferedMessages.isEmpty {
                            throw WorkloadJobStateMachineError.requestBypassed
                        }
                    case .notBypassed:
                        // nothing to do
                        ()
                    }
                    authTokenPromise.succeed(with: .init(
                        tokenGrantingToken: tgt,
                        oneTimeTokenSalt: ottSalt,
                        oneTimeToken: ott
                    ))
                    return (bufferedMessages, self.state)
                } catch {
                    authTokenPromise.fail(with: error)
                    throw error
                }
            case .validatedTokenGrantingToken:
                throw TokenGrantingTokenError.receivedTokenGrantingTokenTwice
            case .abandoning:
                preconditionFailure("Received auth token after instance abandoned")
            case .terminated:
                preconditionFailure("Received auth token while already terminated")
            }
        }
    }

    mutating func receivedRequestBypassMode(bypassed: Bool) {
        WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "requestBypassed"
        ).loggingStateChange(to: Self.tracingLogger, level: .debug) {
            let newBypassMode: RequestBypassMode = bypassed ? .bypassed : .notBypassed
            switch self.state {
            case .awaitingOneTimeToken(let requestBypass, let bufferedMessages, let authTokenPromise):
                precondition(requestBypass == .unknown, "Received request bypass notification twice")
                precondition(
                    !bypassed || bufferedMessages.isEmpty,
                    "Received request bypass notification with buffered messages"
                )
                self.state = .awaitingOneTimeToken(
                    requestBypass: newBypassMode,
                    bufferedMessages: bufferedMessages,
                    authTokenPromise: authTokenPromise
                )
            case .awaitingTokenGrantingToken(
                let requestBypass,
                let bufferedMessages,
                let oneTimeToken,
                let authTokenPromise
            ):
                precondition(requestBypass == .unknown, "Received request bypass notification twice")
                precondition(
                    !bypassed || bufferedMessages.isEmpty,
                    "Received request bypass notification with buffered messages"
                )
                self.state = .awaitingTokenGrantingToken(
                    requestBypass: newBypassMode,
                    bufferedMessages: bufferedMessages,
                    oneTimeToken: oneTimeToken,
                    authTokenPromise: authTokenPromise
                )
            case .validatedTokenGrantingToken(let requestBypass, let tgt, let ottSalt, let ott):
                precondition(requestBypass == .unknown, "Received request bypass notification twice")
                self.state = .validatedTokenGrantingToken(
                    requestBypass: newBypassMode,
                    tgt: tgt,
                    ottSalt: ottSalt,
                    oneTimeToken: ott
                )
            case .abandoning:
                preconditionFailure("Received request bypass notification after instance abandoned")
            case .terminated:
                preconditionFailure("Received request bypass notification while already terminated")
            }
            return ((), self.state)
        }
    }

    /// Whether request bypass is used for the request or not. This will throw if called before the Parameters message
    /// has been received by ROPES and therefore should only be used in flows that can happen only after that message
    /// is received (e.g. worker requests)
    var requestBypassed: Bool {
        get throws {
            switch self.state {
            case .awaitingOneTimeToken(let requestBypass, _, _),
                 .awaitingTokenGrantingToken(let requestBypass, _, _, _),
                 .validatedTokenGrantingToken(let requestBypass, _, _, _):
                switch requestBypass {
                case .unknown: throw WorkloadJobStateMachineError.requestBypassStateUnknown
                case .bypassed: true
                case .notBypassed: false
                }
            case .abandoning:
                throw WorkloadJobStateMachineError.jobAbandoned
            case .terminated:
                throw WorkloadJobStateMachineError.terminated
            }
        }
    }

    mutating func abandon() {
        WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "abandon"
        ).loggingStateChange(to: Self.tracingLogger, level: .debug) {
            switch self.state {
            case .awaitingOneTimeToken(_, _, let authTokenPromise),
                 .awaitingTokenGrantingToken(_, _, _, let authTokenPromise):
                authTokenPromise.fail(with: WorkloadJobStateMachineError.jobAbandoned)
                self.state = .abandoning
            case .terminated:
                preconditionFailure("Attempted to abandon after termination")
            default:
                self.state = .abandoning
            }
            return ((), self.state)
        }
    }

    mutating func terminate() throws {
        _ = try WorkloadJobStateMachineCheckpoint(
            logMetadata: self.logMetadata(spanID: self.spanID),
            state: self.state,
            operation: "terminate"
        ).loggingStateChange(to: Self.tracingLogger, level: .debug) {
            var isAbandoned = false
            switch self.state {
            case .awaitingOneTimeToken(_, _, let authTokenPromise):
                // Reached the end of the request stream without receiving the one-time token from ROPES
                authTokenPromise.fail(with: WorkloadJobStateMachineError.terminating)
                throw TokenGrantingTokenError.missingOneTimeToken
            case .awaitingTokenGrantingToken(_, _, _, let authTokenPromise):
                // Reached the end of the request stream without receiving a TGT
                authTokenPromise.fail(with: WorkloadJobStateMachineError.terminating)
                throw TokenGrantingTokenError.missingTokenGrantingToken
            case .validatedTokenGrantingToken:
                () // Nothing to do
            case .abandoning:
                isAbandoned = true
            case .terminated:
                preconditionFailure("Attempted to terminate more than once")
            }
            self.state = .terminated(isAbandoned)
            return ((), self.state)
        }
    }

    private func validateToken(tgt: Data, ott: Data, ottSalt: Data) throws {
        do {
            self.metrics.emit(Metrics.WorkloadManager.TGTValidationCounter(
                action: .increment,
                automatedDeviceGroup: !(
                    self
                        .automatedDeviceGroup.isEmpty
                ),
                featureId: self.featureID,
                bundleId: self.bundleID,
                inferenceId: self.inferenceID
            ))
            try self.tgtValidator.validateTokenGrantingToken(tgt, ott: ott, ottSalt: ottSalt)
            WorkloadJobManagerCheckpoint(
                logMetadata: self.logMetadata(),
                message: "Successfully validated TGT",
                operationName: "validateToken"
            ).log(to: Self.tracingLogger, level: .default)
        } catch {
            self.metrics.emit(Metrics.WorkloadManager.TGTValidationErrorCounter(
                action: .increment,
                automatedDeviceGroup: !(self.automatedDeviceGroup.isEmpty),
                error: error,
                featureId: self.featureID,
                bundleId: self.bundleID,
                inferenceId: self.inferenceID
            ))
            if self.enforceTGTValidation {
                WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(),
                    message: "Failed to validate TGT",
                    operationName: "validateToken",
                    error: error
                ).log(to: Self.tracingLogger, level: .error)
                throw error
            } else {
                WorkloadJobManagerCheckpoint(
                    logMetadata: self.logMetadata(spanID: self.spanID),
                    message: "Failed to validate TGT. Continuing as enforcement is disabled.",
                    operationName: "validateToken",
                    error: error
                ).log(to: Self.tracingLogger, level: .default)
            }
        }
    }

    mutating func awaitAuthTokens() throws -> Future<AuthTokenData, Error> {
        switch self.state {
        case .awaitingOneTimeToken(_, _, let authTokenPromise),
             .awaitingTokenGrantingToken(_, _, _, let authTokenPromise):
            return Future(authTokenPromise)
        case .validatedTokenGrantingToken(_, let tgt, let ottSalt, let ott):
            let promise = Promise<AuthTokenData, Error>()
            promise.succeed(with: .init(
                tokenGrantingToken: tgt,
                oneTimeTokenSalt: ottSalt,
                oneTimeToken: ott
            ))
            return Future(promise)
        case .abandoning:
            throw WorkloadJobStateMachineError.jobAbandoned
        case .terminated:
            throw WorkloadJobStateMachineError.terminated
        }
    }

    mutating func receiveRequestID(requestID: String) {
        self.requestID = requestID
    }

    mutating func receiveAutomatedDeviceGroup(automatedDeviceGroup: String) {
        self.automatedDeviceGroup = automatedDeviceGroup
    }

    mutating func receiveBundleID(bundleID: String) {
        self.bundleID = bundleID
    }

    mutating func receiveFeatureID(featureID: String) {
        self.featureID = featureID
    }

    mutating func receiveInferenceID(inferenceID: String?) {
        self.inferenceID = inferenceID
    }

    mutating func receiveApplicationDataChunkingConfig(config: ApplicationDataChunkingConfiguration) throws {
        self.applicationDataChunkingConfig = config
    }

    func getApplicationDataChunkingConfig() throws -> ApplicationDataChunkingConfiguration {
        return self.applicationDataChunkingConfig
    }

    mutating func setProtocolVersion(_ version: UInt32) throws {
        switch self.state {
        case .abandoning:
            throw WorkloadJobStateMachineError.jobAbandoned
        case .terminated:
            throw WorkloadJobStateMachineError.terminated
        default:
            self._protocolVersion = version
        }
    }

    var protocolVersion: UInt32 {
        get throws {
            switch self.state {
            case .abandoning:
                throw WorkloadJobStateMachineError.jobAbandoned
            case .terminated:
                throw WorkloadJobStateMachineError.terminated
            default:
                return self._protocolVersion
            }
        }
    }

    private func logMetadata(spanID: UInt64? = nil) -> CloudBoardJobHelperLogMetadata {
        return CloudBoardJobHelperLogMetadata(
            jobID: self.jobUUID,
            requestTrackingID: self.requestID,
            spanID: spanID
        )
    }
}

extension WorkloadJobManager {
    private func logMetadata(spanID: UInt64? = nil) async -> CloudBoardJobHelperLogMetadata {
        return await CloudBoardJobHelperLogMetadata(
            jobID: self.jobUUID,
            requestTrackingID: self._requestInProgress.withLock { $0?.requestParameters.plaintextMetadata.requestID },
            remotePID: self.managedCloudApp.remotePID,
            spanID: spanID
        )
    }
}

enum RopesError: UInt32 {
    case RESOURCE_EXHAUSTED_DISCARDABLE = 4008
}

extension Proto_PrivateCloudCompute_PrivateCloudComputeResponse.CloseSubresponsePayload.SubresponseStatus {
    fileprivate init(_ status: InternalSubresponseStatus) {
        switch status {
        case .ok:
            self = .ok
        case .discarded:
            self = .discarded
        case .error:
            self = .internalError
        }
    }
}
