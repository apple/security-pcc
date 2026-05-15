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

import _NIOBase64
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import InternalGRPC
import InternalSwiftProtobuf
import os
import ServiceContextModule
import Tracing

enum InvokeProxyDialBackError: Swift.Error, GRPCStatusTransformable {
    /// Receiving such a message if not a proxy is illegal
    case notProxy
    case invalidWorkerID
    case unknownWorkerID
    case receivedWorkerIDMoreThanOnce
    case receivedWorkerIDAfterClose
    case receivedWorkerIDAfterEOF
    case receivedMessageBeforeID
    case receivedMessageAfterClose
    case receivedMessageAfterEOF
    case receivedCloseBeforeID
    case receivedCloseMoreThanOnce
    case receivedCloseAfterEOF
    case receivedEOFBeforeID
    case receivedEOFMoreThanOnce
    case failedToDecodeAttestationKeyID
    /// A negotiation to select a worker was missing information such that it would just fail later
    case negotiationMissingInformation(missingFields: [String])
    /// A message from ROPES was not one we support anymore
    case unsupportedProtocol

    func makeGRPCStatus() -> InternalGRPC.GRPCStatus {
        switch self {
        case .notProxy: .init(
                code: .unimplemented,
                message: "Attempt to send a proxy dialback to a compute only instance"
            )
        case .invalidWorkerID: .init(code: .invalidArgument, message: "Worker ID is not a valid UUID")
        case .unknownWorkerID: .init(code: .invalidArgument, message: "Unknown worker ID")
        case .receivedWorkerIDMoreThanOnce: .init(
                code: .failedPrecondition,
                message: "Received worker ID more than once"
            )
        case .receivedWorkerIDAfterClose: .init(code: .failedPrecondition, message: "Received worker ID after close")
        case .receivedWorkerIDAfterEOF: .init(code: .failedPrecondition, message: "Received worker ID after EOF")
        case .receivedMessageBeforeID: .init(code: .failedPrecondition, message: "Received message before worker ID")
        case .receivedMessageAfterClose: .init(code: .failedPrecondition, message: "Received message after close")
        case .receivedMessageAfterEOF: .init(code: .failedPrecondition, message: "Received message after EOF")
        case .receivedCloseBeforeID: .init(code: .failedPrecondition, message: "Received close before worker ID")
        case .receivedCloseMoreThanOnce: .init(code: .failedPrecondition, message: "Received close more than once")
        case .receivedCloseAfterEOF: .init(code: .failedPrecondition, message: "Received close after EOF")
        case .receivedEOFBeforeID: .init(code: .failedPrecondition, message: "Received EOF before worker ID")
        case .receivedEOFMoreThanOnce: .init(code: .failedPrecondition, message: "Received EOF more than once")
        case .failedToDecodeAttestationKeyID: .init(
                code: .invalidArgument,
                message: "Unable to base64-decode attestation key ID"
            )
        case .negotiationMissingInformation(let missingFields): .init(
                code: .invalidArgument,
                message: "negotiate proposed ensembles is missing needed data: \(missingFields)"
            )
        case .unsupportedProtocol:
            .init(code: .invalidArgument, message: "Unsupported protocol")
        }
    }
}

// This extension implements the InvokeProxyDialBack gRPC call made by the PCC Gateway (ROPES) in response to a
// InvokeWorkload initiate_proxy_initiate response message. This is used to provide a bi-directional stream to another
// PCC node for outbound calls.
extension CloudBoardProvider {
    func invokeProxyDialBack(
        requestStream: GRPCAsyncRequestStream<Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackRequest>,
        responseStream: GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackResponse>,
        context: GRPCAsyncServerCallContext
    ) async throws {
        var serviceContext = ServiceContext.topLevel
        tracer.extract(context.request.headers, into: &serviceContext, using: HPACKHeadersExtractor())
        try await tracer.withSpan("invokeProxyDialback", context: serviceContext) { span in
            let requestSummary = InvokeProxyDialBackRequestSummaryProvisioner(rpcID: span.context.rpcID)
            return try await self.metrics.withStatusMetrics(
                total: Metrics.CloudBoardProvider.TrustedProxyRequestsCounter(
                    action: .increment(by: 1),
                    cloudApp: self.cloudAppName
                ),
                error: Metrics.CloudBoardProvider.TrustedProxyRequestsErrorCounter.Factory()
            ) {
                return try await self._invokeProxyDialBack(requestStream, responseStream, requestSummary)
            }
        }
    }

    private func _invokeProxyDialBack(
        _ requestStream: GRPCAsyncRequestStream<Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackRequest>,
        _ responseStream: GRPCAsyncResponseStreamWriter<Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackResponse>,
        _ requestSummary: InvokeProxyDialBackRequestSummaryProvisioner
    ) async throws {
        let serviceContext = OSAllocatedUnfairLock(initialState: ServiceContext.current ?? .topLevel)
        guard self.isProxy else {
            throw InvokeProxyDialBackError.notProxy
        }
        let (jobHelperResponseStream, jobHelperResponseContinuation) = AsyncStream<JobHelperInvokeProxyDialBackResponse>
            .makeStream()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Incoming messages
                group.addTask {
                    var invokeProxyStateMachine = InvokeProxyDialBackStateMachine()
                    for try await request in requestStream {
                        switch request.type {
                        case .taskID:
                            // Deprecated in favor of .initiate message, we do not expect this message. Do nothing
                            ()
                        case .initiate(let initiate):
                            if case .traceContextV1(let traceContext) = initiate.traceContextVersion {
                                serviceContext.withLock {
                                    $0.requestID = traceContext.traceID
                                    $0.spanID = TraceContextCache.singletonCache.generateNewSpanID()
                                    $0.parentSpanID = UInt64(traceContext.spanID, radix: 16)
                                    $0.workerID = UUID(uuidString: initiate.taskID)
                                }
                            }

                            await requestSummary.populate(
                                workerID: initiate.taskID,
                                serviceContext: serviceContext.withLock { $0 }
                            )

                            guard let workerID = UUID(uuidString: initiate.taskID) else {
                                throw InvokeProxyDialBackError.invalidWorkerID
                            }

                            CloudBoardProviderCheckpoint(
                                logMetadata: CloudBoardDaemonLogMetadata(
                                    serviceContext: serviceContext.withLock { $0 }
                                ),
                                operationName: "invoke_proxy_dial_back_initiate_message_received",
                                message: "Received InvokeProxyDialBack Initiate message"
                            ).log(workerID: workerID, to: Self.tracingLogger, level: .default)

                            guard let delegates = self.pccWorkerToInitiatorMapping.getInitiator(workerID: workerID)
                            else {
                                Self.logger.error("Unknown workerID \(workerID)")
                                throw InvokeProxyDialBackError.unknownWorkerID
                            }
                            try invokeProxyStateMachine.receivedWorkerID(
                                workerID: workerID,
                                delegates: delegates
                            )
                            let (_, jobHelperResponseDelegate, _) = delegates
                            jobHelperResponseDelegate.registerWorker(
                                uuid: workerID,
                                responseContinuation: jobHelperResponseContinuation
                            )
                        case .computeToProxyMessage(let response):
                            let (workerID, (jobHelper, _, _)) = try invokeProxyStateMachine
                                .receivedMessage()

                            CloudBoardProviderCheckpoint(
                                logMetadata: CloudBoardDaemonLogMetadata(
                                    serviceContext: serviceContext.withLock { $0 }
                                ),
                                operationName: "invoke_proxy_dial_back_compute_to_proxy_message_received",
                                message: "Received InvokeProxyDialBack ComputeToProxyMessage"
                            ).log(workerID: workerID, to: Self.tracingLogger, level: .debug)

                            switch response.type {
                            case .selectedEnsemble(let ensemble):
                                try await self.workerSelected(
                                    workerID: workerID,
                                    jobHelper: jobHelper,
                                    attestation: ensemble.attestation,
                                    workload: ensemble.computeEnsembleWorkload,
                                    serviceContext: serviceContext
                                )
                            case .attestation(let attestation):
                                // Older versions of ROPES using protocol which don't understand negotiate
                                // nor informing the proxy the workload in effect on the compute node
                                // Attempting to keep going could lead to complicated errors so we fail fast
                                CloudBoardProviderCheckpoint(
                                    logMetadata: CloudBoardDaemonLogMetadata(
                                        serviceContext: serviceContext.withLock { $0 }
                                    ),
                                    operationName: "invoke_proxy_dial_back_old_protocol_attestation_received",
                                    message: "Received Attestation instead of SelectedWorker ComputeToProxyMessage"
                                ).log(workerID: workerID, to: Self.tracingLogger, level: .error)
                                throw InvokeProxyDialBackError.unsupportedProtocol
                            case .responseChunk(let responseChunk):
                                Self.logger
                                    .log(
                                        "Received response chunk for worker \(request.initiate.taskID, privacy: .public)"
                                    )
                                try await jobHelper.invokeWorkloadRequest(
                                    .workerResponseChunk(
                                        workerID,
                                        responseChunk.encryptedPayload,
                                        isFinal: responseChunk.isFinal
                                    )
                                )
                            case .negotiatePick(let ensembles):
                                // we do *not* block for the response, the job helper has all the needed
                                // locking to ensure a clean state transition. It will either terminate
                                // everything if this was illegal, or send the needed response later
                                try await self.workerNegotiatePick(
                                    workerID: workerID,
                                    jobHelper: jobHelper,
                                    serviceContext: serviceContext,
                                    ensembles: ensembles
                                )
                            case .none:
                                Self.logger.error("Received invokeProxyDialBack.response of unknown type")
                            }
                        case .close(let close):
                            let (workerID, (jobHelper, _, _)) = try invokeProxyStateMachine.receivedClose()

                            CloudBoardProviderCheckpoint(
                                logMetadata: CloudBoardDaemonLogMetadata(
                                    serviceContext: serviceContext.withLock { $0 }
                                ),
                                operationName: "invoke_proxy_dial_back_close_message_received",
                                message: "Received InvokeProxyDialBack Close message"
                            ).log(workerID: workerID, to: Self.tracingLogger, level: .default)

                            let grpcStatusCode = Int(close.grpcStatus)
                            if grpcStatusCode != 0 {
                                self.metrics.emit(
                                    Metrics.CloudBoardProvider.TrustedProxyRequestsCloseErrorCounter(
                                        action: .increment,
                                        cloudApp: self.cloudAppName,
                                        grpcStatus: grpcStatusCode,
                                        ropesErrorCode: Int(close.ropesErrorCode)
                                    )
                                )
                            }

                            try await jobHelper.invokeWorkloadRequest(.workerResponseClose(
                                workerID,
                                grpcStatus: grpcStatusCode,
                                grpcMessage: close.hasGrpcMessage ? close.grpcMessage : nil,
                                ropesErrorCode: close.hasRopesErrorCode ? close.ropesErrorCode : nil,
                                ropesErrorMessage: close.hasRopesErrorDescription ? close.ropesErrorDescription : nil
                            ))
                        case .none:
                            CloudBoardProviderCheckpoint(
                                logMetadata: CloudBoardDaemonLogMetadata(
                                    serviceContext: serviceContext.withLock { $0 }
                                ),
                                operationName: "invoke_proxy_dial_back_unknown_message_received",
                                message: "Received InvokeProxyDialBack message of unknown type"
                            ).log(to: Self.tracingLogger, level: .error)
                        }
                    }

                    CloudBoardProviderCheckpoint(
                        logMetadata: CloudBoardDaemonLogMetadata(serviceContext: serviceContext.withLock { $0 }),
                        operationName: "invoke_proxy_dial_back_request_finished",
                        message: "InvokeProxyDialBack request stream finished"
                    ).log(to: Self.tracingLogger, level: .default)

                    let (workerID, (jobHelperClient, _, _)) = try invokeProxyStateMachine.receivedEOF()
                    try await jobHelperClient.invokeWorkloadRequest(.workerResponseEOF(workerID))
                    self.pccWorkerToInitiatorMapping.unlink(workerID: workerID)
                }

                // Outgoing messages
                group.addTask {
                    for try await response in jobHelperResponseStream {
                        let workerID = serviceContext.withLock { $0.workerID }
                        switch response {
                        case .decryptionKey(let keyID, let encapsulatedKey):
                            CloudBoardProviderCheckpoint(
                                logMetadata: CloudBoardDaemonLogMetadata(
                                    serviceContext: serviceContext.withLock { $0 }
                                ),
                                operationName: "sending_invoke_proxy_dial_back_decryption_key_message",
                                message: "Sending InvokeProxyDialBack decryption key message"
                            ).log(workerID: workerID, to: Self.tracingLogger, level: .default)

                            try await responseStream.send(.with {
                                $0.proxyToComputeMessage = .with {
                                    $0.decryptionKey = .with {
                                        $0.keyID = keyID
                                        $0.encryptedPayload = encapsulatedKey
                                    }
                                }
                            })

                            let trustedProxyParametersToFirstRewrapDuration = self
                                .trustedProxyParametersToFirstRewrapDurationMeasurement.withLock { $0?.duration }
                            if let trustedProxyParametersToFirstRewrapDuration {
                                self.metrics
                                    .emit(
                                        Metrics.CloudBoardProvider
                                            .TrustedProxyParametersToFirstRewrapDurationHistogram(
                                                cloudApp: self.cloudAppName,
                                                duration: trustedProxyParametersToFirstRewrapDuration
                                            )
                                    )
                            }
                        case .negotiatePickResponse(let selectableEnsembles):
                            CloudBoardProviderCheckpoint(
                                logMetadata: CloudBoardDaemonLogMetadata(
                                    serviceContext: serviceContext.withLock { $0 }
                                ),
                                operationName: "sending_invoke_proxy_dial_back_negotiate_pick_response_message",
                                message: "Sending InvokeProxyDialBack NegotiatePick response message"
                            ).log(workerID: workerID, to: Self.tracingLogger, level: .default)

                            try await responseStream.send(.with {
                                $0.proxyToComputeMessage = .with {
                                    $0.selectableEnsembles = .init(selectableEnsembles)
                                }
                            })
                        case .workerRequestMessage(let payload, let isFinal):
                            CloudBoardProviderCheckpoint(
                                logMetadata: CloudBoardDaemonLogMetadata(
                                    serviceContext: serviceContext.withLock { $0 },
                                    spanID: serviceContext.withLock { $0.parentSpanID }
                                ),
                                operationName: "sending_invoke_proxy_dial_back_worker_request_message",
                                message: "Sending InvokeProxyDialBack worker request message"
                            ).log(workerID: workerID, to: Self.tracingLogger, level: .default)

                            try await responseStream.send(.with {
                                $0.proxyToComputeMessage = .with {
                                    $0.requestChunk = .with {
                                        $0.encryptedPayload = payload
                                        $0.isFinal = isFinal
                                    }
                                }
                            })
                        case .workerRequestEOF:
                            CloudBoardProviderCheckpoint(
                                logMetadata: CloudBoardDaemonLogMetadata(
                                    serviceContext: serviceContext.withLock { $0 }
                                ),
                                operationName: "sending_invoke_proxy_dial_back_close_message",
                                message: "Sending InvokeProxyDialBack close message"
                            ).log(workerID: workerID, to: Self.tracingLogger, level: .default)

                            try await responseStream.send(.with { $0.close = .init() })
                        }
                    }
                }

                // Wait for all tasks to finish unless one of them throws
                while !group.isEmpty {
                    do {
                        try await group.next()
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
            }
            await requestSummary.log(to: Self.tracingLogger)
        } catch {
            await requestSummary.populate(error: error)
            await requestSummary.log(to: Self.tracingLogger)
            throw error
        }
    }

    private func workerNegotiatePick(
        workerID: UUID,
        jobHelper: any CloudBoardJobHelperInstanceProtocol,
        serviceContext: OSAllocatedUnfairLock<ServiceContext>,
        ensembles: Com_Apple_Cloudboard_Api_V1_EnsembleNegotiation
    ) async throws {
        let serviceContext = serviceContext.withLock { $0 }
        let spanID = serviceContext.parentSpanID
        CloudBoardProviderCheckpoint(
            logMetadata: CloudBoardDaemonLogMetadata(
                serviceContext: serviceContext,
                spanID: spanID
            ),
            operationName: "invoke_proxy_dial_back_negotiate_pick_for_worker",
            message: "Received InvokeProxyDialBack NegotiatePick for worker"
        ).log(workerID: workerID, to: Self.tracingLogger, level: .default)
        try await jobHelper.invokeWorkloadRequest(.workerNegotiatePick(
            providedByRopes: WorkerNegotiatePickInfo(
                workerID: workerID,
                spanID: spanID,
                proposed: EnsembleNegotiation(ensembles)
            )
        ))
        self.metrics.emit(
            Metrics.CloudBoardProvider.NegotiatePickCounter(
                action: .increment,
                cloudApp: self.cloudAppName
            )
        )
    }

    private func workerSelected(
        workerID: UUID,
        jobHelper: any CloudBoardJobHelperInstanceProtocol,
        attestation: Proto_Ropes_Common_Attestation,
        workload: Proto_Ropes_Common_Workload,
        serviceContext: OSAllocatedUnfairLock<ServiceContext>
    ) async throws {
        let serviceContext = serviceContext.withLock { $0 }
        let spanID = serviceContext.parentSpanID
        CloudBoardProviderCheckpoint(
            logMetadata: CloudBoardDaemonLogMetadata(
                serviceContext: serviceContext,
                spanID: spanID
            ),
            // we keep this name for consistency whether this came from just an attestation or a SelectedWorker
            // The important thing is getting the attestation so down stream can validate that
            operationName: "invoke_proxy_dial_back_attestation_for_worker_received",
            message: "Received InvokeProxyDialBack attestation for worker"
        ).log(workerID: workerID, to: Self.tracingLogger, level: .default)
        guard let keyIDDecoded = try? attestation.nodeIdentifier._base64Decoded() else {
            throw InvokeProxyDialBackError.failedToDecodeAttestationKeyID
        }
        let keyID = Data(keyIDDecoded)
        let rawAttestationBundle = attestation.attestationBundle
        try await jobHelper.invokeWorkloadRequest(.workerAttestation(
            attestation: WorkerAttestationInfo(
                workerID: workerID,
                keyID: keyID,
                attestationBundle: rawAttestationBundle,
                bypassContextID: attestation.hasOhttpContext ? attestation.ohttpContext : nil,
                spanID: spanID
            ),
            workloadParameters: Dictionary(parameters: workload.param)
        ))

        if let (_, _, findWorkerDurationMeasurement) = self.pccWorkerToInitiatorMapping
            .getInitiator(workerID: workerID) {
            let findWorkerDuration = findWorkerDurationMeasurement.withLock { $0.duration }

            self.metrics
                .emit(
                    Metrics.CloudBoardProvider
                        .FindWorkerDuration(
                            cloudApp: self.cloudAppName,
                            duration: findWorkerDuration
                        )
                )
        }
    }
}

struct InvokeProxyDialBackStateMachine {
    enum State {
        case waitingForWorkerID
        case workerIDReceived(workerID: UUID, delegates: PccWorkerToInitiatorMapping.PCCWorkerInitiator)
        case connectionClosed(workerID: UUID, delegates: PccWorkerToInitiatorMapping.PCCWorkerInitiator)
        case endOfResponseStream
    }

    private var state = State.waitingForWorkerID

    mutating func receivedWorkerID(
        workerID: UUID,
        delegates: PccWorkerToInitiatorMapping.PCCWorkerInitiator
    ) throws {
        switch self.state {
        case .waitingForWorkerID:
            self.state = .workerIDReceived(workerID: workerID, delegates: delegates)
        case .workerIDReceived:
            throw InvokeProxyDialBackError.receivedWorkerIDMoreThanOnce
        case .connectionClosed:
            throw InvokeProxyDialBackError.receivedWorkerIDAfterClose
        case .endOfResponseStream:
            throw InvokeProxyDialBackError.receivedWorkerIDAfterEOF
        }
    }

    mutating func receivedMessage() throws -> (UUID, PccWorkerToInitiatorMapping.PCCWorkerInitiator) {
        switch self.state {
        case .waitingForWorkerID:
            throw InvokeProxyDialBackError.receivedMessageBeforeID
        case .workerIDReceived(let workerID, let delegates):
            return (workerID, delegates)
        case .connectionClosed:
            throw InvokeProxyDialBackError.receivedMessageAfterClose
        case .endOfResponseStream:
            throw InvokeProxyDialBackError.receivedMessageAfterEOF
        }
    }

    mutating func receivedClose() throws -> (UUID, PccWorkerToInitiatorMapping.PCCWorkerInitiator) {
        switch self.state {
        case .waitingForWorkerID:
            throw InvokeProxyDialBackError.receivedCloseBeforeID
        case .workerIDReceived(let workerID, let delegates):
            self.state = .connectionClosed(workerID: workerID, delegates: delegates)
            return (workerID, delegates)
        case .connectionClosed:
            throw InvokeProxyDialBackError.receivedCloseMoreThanOnce
        case .endOfResponseStream:
            throw InvokeProxyDialBackError.receivedCloseAfterEOF
        }
    }

    mutating func receivedEOF() throws -> (UUID, PccWorkerToInitiatorMapping.PCCWorkerInitiator) {
        switch self.state {
        case .waitingForWorkerID:
            throw InvokeProxyDialBackError.receivedEOFBeforeID
        case .workerIDReceived(let workerID, let delegates):
            self.state = .endOfResponseStream
            return (workerID, delegates)
        case .connectionClosed(let workerID, let delegates):
            self.state = .endOfResponseStream
            return (workerID, delegates)
        case .endOfResponseStream:
            throw InvokeProxyDialBackError.receivedEOFMoreThanOnce
        }
    }
}

private actor InvokeProxyDialBackRequestSummaryProvisioner {
    private var requestSummary: InvokeProxyDialBackRequestSummary

    init(rpcID: UUID) {
        self.requestSummary = InvokeProxyDialBackRequestSummary(rpcID: rpcID)
        self.requestSummary.startTimeNanos = RequestSummaryClock.now
    }

    func populate(workerID: String, serviceContext: ServiceContext) {
        self.requestSummary.populate(
            workerID: workerID,
            requestTrackingID: serviceContext.requestID,
            spanID: serviceContext.spanID,
            parentSpanID: serviceContext.parentSpanID
        )
    }

    func populate(workerID: String) {
        self.requestSummary.populate(workerID: workerID)
    }

    func populate(error: Error) {
        self.requestSummary.populate(error: error)
    }

    func log(to logger: Logger) {
        self.requestSummary.endTimeNanos = RequestSummaryClock.now
        self.requestSummary.log(to: logger)
    }
}

private struct InvokeProxyDialBackRequestSummary: RequestSummary {
    var requestID: String?
    var spanID: UInt64?
    var parentSpanID: UInt64?
    let automatedDeviceGroup: String? = nil // No automated device group for InvokeProxyDialBack calls

    var workerID: String?

    var startTimeNanos: Int64?
    var endTimeNanos: Int64?

    let operationName = "InvokeProxyDialBack"
    let type = "RequestSummary"
    var serviceName = "cloudboardd"
    var namespace = "cloudboard"

    let rpcID: UUID
    var error: Error?

    init(rpcID: UUID) {
        self.rpcID = rpcID
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

    func log(to logger: Logger) {
        logger.log("""
        ttl=RequestSummary
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.parent_span_id=\(self.parentSpanID?.hexEncoded ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        rpcId=\(self.rpcID, privacy: .public)
        request.duration_ms=\(self.durationMicros.map { String($0 / 1000) } ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { "\(String(reportable: $0))" } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        worker.uuid=\(self.workerID.map { "\($0)" } ?? "")
        """)
    }
}

extension CloudBoardDaemonLogMetadata {
    init(serviceContext: ServiceContext) {
        self.init(
            rpcID: ServiceContext.current?.rpcID,
            requestTrackingID: serviceContext.requestID,
            workerID: serviceContext.workerID,
            spanID: serviceContext.spanID
        )
    }

    init(serviceContext: ServiceContext, spanID: UInt64?) {
        self.init(
            rpcID: ServiceContext.current?.rpcID,
            requestTrackingID: serviceContext.requestID,
            workerID: serviceContext.workerID,
            spanID: spanID
        )
    }
}
