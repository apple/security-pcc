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

import Foundation
internal import InternalGRPC
internal import InternalSwiftProtobuf
internal import Synchronization
import os

/// Helper to transfer non-Sendable values across isolation boundaries when we know it's safe
struct UnsafeTransfer<Wrapped> {
    @usableFromInline
    var wrappedValue: Wrapped

    @inlinable
    init(_ wrappedValue: Wrapped) {
        self.wrappedValue = wrappedValue
    }
}

extension UnsafeTransfer: @unchecked Sendable {}

extension PCCHarness {
    /// PCCGateway component that orchestrates proxy-to-compute requests. It handles both the InvokeProxyDialBack gRPC
    /// callback to the proxy node and the InvokeWorkload call to the compute node and proxies between the two nodes.
    final class ProxyDialBackOrchestrator: Sendable {
        private struct LogContext: CustomStringConvertible {
            let requestID: UUID
            let taskID: String
            let proxyEndpoint: HostAndPort
            let computeEndpoint: HostAndPort?

            var description: String {
                if let computeEndpoint {
                    return "[\(self.requestID), task: \(self.taskID), proxy: \(self.proxyEndpoint), compute: \(computeEndpoint)]"
                } else {
                    return "[\(self.requestID), task: \(self.taskID), proxy: \(self.proxyEndpoint)]"
                }
            }
        }

        private struct BypassConfiguration {
            let requestContinuation: (any BypassContinuationProtocol<ProtoInvokeWorkloadRequest>)?
            let mode: ProtoResponseBypassMode
            let responseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation
        }

        private struct ProxyWorkflowContext {
            let computeNodeSelection: ComputeNodeSelectionContext
            let metadata: InvokeWorkloadRequestMetadata
            let log: LogContext
        }

        private struct ProxyDialBackStreams {
            let requestContinuation: AsyncStream<ProtoInvokeProxyDialBackRequest>.Continuation
            let responseStream: GRPCAsyncResponseStream<ProtoInvokeProxyDialBackResponse>
        }

        fileprivate static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.ProxyDialBackOrchestrator"
        )

        private let proxyClient: GatewayPCCClient
        private let nodeManager: PCCNodeManager
        private let gatewayConfig: PCCGatewayConfig
        private let proxyRequestConfiguration: ProxyRequestConfiguration
        private let proxyWorkerErrorHolder: ProxyWorkerErrorHolder

        init(
            proxyClient: GatewayPCCClient,
            nodeManager: PCCNodeManager,
            gatewayConfig: PCCGatewayConfig,
            proxyRequestConfiguration: ProxyRequestConfiguration,
            proxyWorkerErrorHolder: ProxyWorkerErrorHolder
        ) {
            self.proxyClient = proxyClient
            self.nodeManager = nodeManager
            self.gatewayConfig = gatewayConfig
            self.proxyRequestConfiguration = proxyRequestConfiguration
            self.proxyWorkerErrorHolder = proxyWorkerErrorHolder
        }

        func initiateProxyDialBack(
            originalRequestContext: InvokeWorkloadRequestContext,
            proxyInitiate: ProtoInvokeProxyInitiate,
            // Request bypass
            bypassContinuation: (any BypassContinuationProtocol<ProtoInvokeWorkloadRequest>)?,
            // Response bypass
            bypassMode: ProtoResponseBypassMode,
            bypassResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation
        ) async throws {
            let logContext = LogContext(
                requestID: originalRequestContext.baseContext.requestID,
                taskID: proxyInitiate.taskID,
                proxyEndpoint: self.proxyClient.endpoint.hostAndPort,
                computeEndpoint: nil
            )

            Self.logger.info("\(logContext) Initiating proxy dial-back")

            // Log Effort, Reuse, and Negotiate information from InvokeProxyInitiate
            if proxyInitiate.hasReuseConstraints {
                let reuse = proxyInitiate.reuseConstraints
                Self.logger
                    .info(
                        "\(logContext) Reuse constraints: ensembleID=\(reuse.ensemble.ensembleID, privacy: .public) bootID=\(reuse.ensemble.bootID, privacy: .public) rackID=\(reuse.rackID, privacy: .public) workloadAdditions=\(reuse.workloadAdditions.param.asMap(), privacy: .public)"
                    )
            } else {
                Self.logger.info("\(logContext) No reuse constraints")
            }

            if proxyInitiate.hasNegotiate {
                let negotiate = proxyInitiate.negotiate
                if negotiate.hasPick {
                    Self.logger
                        .info(
                            "\(logContext) Negotiate pick: numProvidedChoices=\(negotiate.pick.numProvidedChoices, privacy: .public) numSelectedChoices=\(negotiate.pick.numSelectedChoices, privacy: .public)"
                        )
                } else {
                    Self.logger.info("\(logContext) Negotiate present but no pick configuration")
                }

                // Log trusted ensembles and rack IDs if present
                if !negotiate.trustedEnsembles.isEmpty {
                    let ensembleDescriptions = negotiate.trustedEnsembles.map { ensemble in
                        "ensembleID=\(ensemble.ensembleID) bootID=\(ensemble.bootID)"
                    }.joined(separator: ", ")
                    Self.logger
                        .info(
                            "\(logContext) Negotiate trusted ensembles (\(negotiate.trustedEnsembles.count)): \(ensembleDescriptions, privacy: .public)"
                        )
                }
                if !negotiate.trustedRackIds.isEmpty {
                    Self.logger
                        .info("\(logContext) Negotiate trusted rack IDs: \(negotiate.trustedRackIds, privacy: .public)")
                }
                if negotiate.freeChoice {
                    Self.logger.info("\(logContext) Negotiate free choice enabled")
                }
            } else {
                Self.logger.info("\(logContext) No negotiate configuration")
            }

            if !proxyInitiate.efforts.isEmpty {
                let effortDescriptions = proxyInitiate.efforts.map { effort -> String in
                    var effortDesc = "key=\(effort.key)"
                    effortDesc +=
                        " privacyTransformed=\(effort.privacyTransformedNumerator)/\(effort.privacyTransformedDenominator)"
                    if effort.hasIdealPercentage {
                        effortDesc += " idealPercentage=\(effort.idealPercentage)"
                    }
                    return effortDesc
                }.joined(separator: ", ")
                Self.logger
                    .info(
                        "\(logContext) Efforts (\(proxyInitiate.efforts.count)): \(effortDescriptions, privacy: .public)"
                    )
            } else {
                Self.logger.info("\(logContext) No effort information")
            }

            let computeNodeSelectionContext = ComputeNodeSelectionContext(
                originalRequestContext: originalRequestContext.baseContext,
                initiate: .init(proxyInitiate)
            )

            let bypassConfig = BypassConfiguration(
                requestContinuation: bypassContinuation,
                mode: bypassMode,
                responseContinuation: bypassResponseContinuation
            )

            switch try self.selectCandidateComputeNodes(context: computeNodeSelectionContext) {
            case .error(let errorCode):
                // Handle explicit error code from extended full control selection
                Self.logger.error("\(logContext) Compute node selection failed with error code \(errorCode.rawValue)")
                // Finish the bypass response stream with the error since we're not going to a compute node
                bypassConfig.responseContinuation.finish(throwing: errorCode)
                return self.handleFailureToFindWorker(
                    taskID: proxyInitiate.taskID,
                    errorCode: errorCode.rawValue,
                    logContext: logContext
                )
            case .pick:
                // Ensemble selection using negotiate constraints from proxy
                // May use direct reservation of trusted ensembles or escalate to pick protocol
                Self.logger.info("\(logContext) Starting negotiate constraint-based selection")
                return try await self.handleNegotiateConstraintBasedSelection(
                    proxyInitiate: proxyInitiate,
                    logContext: logContext,
                    computeNodeSelectionContext: computeNodeSelectionContext,
                    bypassConfig: bypassConfig
                )
            case .directChoice(let choice, workloadParameters: let computeWorkloadParameters):
                return try await self.continueWithSelectedEndpoint(
                    choice: choice,
                    workloadParameters: computeWorkloadParameters,
                    computeNodeSelectionContext: computeNodeSelectionContext,
                    bypassConfig: bypassConfig,
                    logMessage: "Selected compute node"
                )
            }
        }

        /// Selects candidate compute nodes based on the configured compute node selection strategy.
        private func selectCandidateComputeNodes(
            context: ComputeNodeSelectionContext
        ) throws -> ProxyInvokeComputeNodeSelection {
            return try self.gatewayConfig.extendedComputeNodeSelectionStrategy.apply(
                to: self.nodeManager.trackedComputeEndpointPool,
                context: context,
                serviceDiscovery: self.gatewayConfig.serviceDiscovery
            )
        }

        private func handleProxyWorkflow(
            with computeEndpoint: any CloudAppEndpoint,
            context: ProxyWorkflowContext,
            bypassConfig: BypassConfiguration,
            streams: ProxyDialBackStreams? = nil,
            proxyDialBackMessageIterator: UnsafeTransfer<
                GRPCAsyncResponseStream<ProtoInvokeProxyDialBackResponse>
                    .Iterator
            >? = nil
        ) async throws {
            let logMessage = streams == nil ? "Starting proxy workflow" :
                "Continuing proxy workflow with existing streams"
            Self.logger.info("\(context.log) \(logMessage)")

            // Validate that we have a proxy endpoint
            guard let proxyEndpoint = self.proxyClient.endpoint as? ProxyCloudAppEndpoint else {
                Self.logger.error("\(context.log) Proxy client endpoint is not a ProxyCloudAppEndpoint")
                throw PCCGatewayError.invalidEndpointType
            }

            // Connect to proxy (or use existing streams)
            let actualStreams: ProxyDialBackStreams
            if let streams {
                actualStreams = streams
            } else {
                let (proxyDialBackContinuation, proxyDialBackResponseStream) = self.proxyClient.invokeProxyDialBack(
                    taskID: context.computeNodeSelection.initiate.taskID
                )
                actualStreams = ProxyDialBackStreams(
                    requestContinuation: proxyDialBackContinuation,
                    responseStream: proxyDialBackResponseStream
                )
            }

            // Connect to compute node and fetch attestation
            let computeClient = try self.nodeManager.client(for: computeEndpoint)
            let computeAttestation = try await computeClient.currentAttestationSet.activeAttestation

            // Inform proxy of selected compute node and provide its attestation
            //
            // ROPES passes through all inputs, on an application specific basis it might inject additional ones
            // like RunMode for TIE - if someone wants to test that they can use the FullControl path
            let workloadProto = Proto_Ropes_Common_Workload.with {
                $0.type = context.computeNodeSelection.initiate.serviceName
                $0.param = .init(context.metadata.workloadParameters)
            }
            let workerSelectedMessage = self.initiateProxyWorkerSelected(
                attestation: computeAttestation,
                workloadMetadata: workloadProto,
                isResponseBypass: bypassConfig.mode == .matchRequestCiphersuiteSharedAeadState
            )

            Self.logger.info("\(context.log) Sending worker selected message to proxy")

            // Notify observer for request to proxy
            let observer = self.nodeManager.proxyDialBackMessageObserver(for: proxyEndpoint)
            observer?.onRequestToProxy(.init(workerSelectedMessage))

            actualStreams.requestContinuation.yield(workerSelectedMessage)

            do {
                // Set up and manage bidirectional stream between proxy and compute node
                try await self.handleProxyWorkflowMessages(
                    proxyEndpoint: proxyEndpoint,
                    context: context,
                    bypassConfig: bypassConfig,
                    computeClient: computeClient,
                    streams: actualStreams,
                    proxyDialBackMessageIterator: proxyDialBackMessageIterator
                )
            } catch {
                Self.logger.error("\(context.log) Proxy workflow failed with error: \(error)")
                // Finish the bypass response stream since we're not going to send any more responses
                bypassConfig.responseContinuation.finish(throwing: error)
                do {
                    try self.closeProxyDialBackRequestOnError(
                        taskID: context.computeNodeSelection.initiate.taskID,
                        proxyDialBackContinuation: actualStreams.requestContinuation,
                        error: error,
                        logContext: context.log
                    )
                } catch {
                    Self.logger.error("\(context.log) Failed to close proxy dial back stream on error: \(error)")
                }
            }
        }

        /// Handles the basic routing v1 vs v2 logic here
        /// v1 gets an attestation ``Proto_Ropes_Common_Attestation``
        /// v2 gets an selectedEnsemble ``Com_Apple_Cloudboard_Api_V1_ComputeToProxyMessage.SelectedEnsemble``
        private func initiateProxyWorkerSelected(
            attestation: ActiveAttestation,
            workloadMetadata: Proto_Ropes_Common_Workload,
            isResponseBypass: Bool,
        ) -> ProtoInvokeProxyDialBackRequest {
            let attestationMessage = Proto_Ropes_Common_Attestation.with {
                $0.nodeIdentifier = attestation.attestationMetadata.keyID.base64EncodedString()
                $0.attestationBundle = attestation.attestationBundle
                if isResponseBypass {
                    // Mandatory field required by proxy when in response bypass mode.
                    // For our purposes, the value is not important at the moment.
                    $0.ohttpContext = 1234
                }
            }

            return ProtoInvokeProxyDialBackRequest.with {
                $0.computeToProxyMessage = .with {
                    $0.selectedEnsemble = .with {
                        $0.attestation = attestationMessage
                        $0.computeEnsembleWorkload = workloadMetadata
                    }
                }
            }
        }

        private func handleProxyWorkflowMessages(
            proxyEndpoint: ProxyCloudAppEndpoint,
            context: ProxyWorkflowContext,
            bypassConfig: BypassConfiguration,
            computeClient: GatewayPCCClient,
            streams: ProxyDialBackStreams,
            proxyDialBackMessageIterator: UnsafeTransfer<
                GRPCAsyncResponseStream<ProtoInvokeProxyDialBackResponse>
                    .Iterator
            >? = nil
        ) async throws {
            let logMessage = proxyDialBackMessageIterator == nil ? "Handling proxy workflow messages" :
                "Handling proxy workflow messages with existing iterator"
            Self.logger.info("\(context.log) \(logMessage)")

            // Get observer for this specific proxy endpoint
            let observer = self.nodeManager.proxyDialBackMessageObserver(for: proxyEndpoint)

            // Assumption: proxy node will first return the DEK, before any chunks
            var iterator = proxyDialBackMessageIterator?.wrappedValue ?? streams.responseStream.makeAsyncIterator()

            guard let dekMessageFromProxy = try await iterator.next() else {
                Self.logger.error("\(context.log) Failed to receive DEK from proxy")
                throw LocalCloudBoardGRPCClientError.proxyToComputeDEKInvalid
            }

            // We can transfer the iterator here as we know that it is no longer used in this task from this point
            // onward.
            let wrappedProxyDialBackMessageIterator = UnsafeTransfer(iterator)

            // Notify observer for response from proxy
            observer?.onResponseFromProxy(.init(dekMessageFromProxy))

            guard dekMessageFromProxy.proxyToComputeMessage.isInitialized,
                  dekMessageFromProxy.proxyToComputeMessage.decryptionKey.isInitialized else {
                Self.logger.error("\(context.log) Received invalid DEK from proxy")
                throw LocalCloudBoardGRPCClientError.proxyToComputeDEKInvalid
            }

            Self.logger.info("\(context.log) Received DEK from proxy")

            let dekFromProxyToComputeNode = dekMessageFromProxy.proxyToComputeMessage.decryptionKey
            let encapsulatedDEKInfo = EncapsulatedDataEncryptionKey(
                keyID: dekFromProxyToComputeNode.keyID,
                dataEncryptionKey: dekFromProxyToComputeNode.encryptedPayload
            )

            let computeRequestContext = InvokeWorkloadRequestContext(
                baseContext: .init(
                    // The request ID on worker requests is the same as the original. We consider this the trace ID
                    // (until there is a dedicated trace ID).
                    requestID: context.computeNodeSelection.originalRequestContext.requestID,
                    workloadMetadata: context.metadata
                ),
                encapsulatedDataEncryptionKey: encapsulatedDEKInfo
            )

            let configuration = ComputeRequestConfiguration(responseBypassMode: .init(from: bypassConfig.mode))

            try await InvokeWorkloadExecutor(
                client: computeClient,
                nodeManager: self.nodeManager,
                gatewayConfig: self.gatewayConfig
            ).invokeWorkload(
                context: computeRequestContext,
                configuration: .compute(configuration)
            ) { invokeWorkloadSession, _, grpcRequestContinuation in
                // The grpcRequestContinuation has now had the setup and parameters sent to it.
                // If there is a pending request bypass, connect it to flush buffered chunks to the compute node.
                let allowPayloadMessagesFromProxy: Bool
                if let bypassContinuation = bypassConfig.requestContinuation, bypassContinuation.hasPendingBypass {
                    allowPayloadMessagesFromProxy = false
                    // This will flush the buffer and wire up any subsequent messages to the compute node
                    try bypassContinuation.connect(target: grpcRequestContinuation)
                    Self.logger.info(
                        "\(context.log) Connected bypass continuation - flushed buffered request chunks to compute node"
                    )
                } else {
                    allowPayloadMessagesFromProxy = true
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Handle messages from proxy node
                    group.addTask {
                        try await self.handleProxyWorkflowProxyMessages(
                            observer: observer,
                            proxyDialBackMessageIterator: wrappedProxyDialBackMessageIterator,
                            allowPayloadMessagesFromProxy: allowPayloadMessagesFromProxy,
                            computeInvokeWorkloadSession: invokeWorkloadSession,
                            logContext: context.log
                        )
                    }

                    // Handle messages from compute node
                    group.addTask {
                        do {
                            try await self.handleProxyWorkflowWorkerMessages(
                                observer: observer,
                                computeInvokeWorkloadSession: invokeWorkloadSession,
                                bypassConfig: bypassConfig,
                                streams: streams,
                                logContext: context.log
                            )
                        } catch {
                            Self.logger.error("\(context.log) Error handling compute node messages: \(error)")
                            do {
                                try self.closeProxyDialBackRequestOnError(
                                    taskID: context.computeNodeSelection.initiate.taskID,
                                    proxyDialBackContinuation: streams.requestContinuation,
                                    error: error,
                                    logContext: context.log
                                )
                            } catch {
                                Self.logger
                                    .error("\(context.log) Failed to close proxy dial back stream on error: \(error)")
                            }
                            throw error
                        }
                    }

                    try await group.waitForAll()
                }
            }
        }

        private func handleProxyWorkflowProxyMessages(
            observer: ProxyDialBackMessageObserver?,
            proxyDialBackMessageIterator: UnsafeTransfer<
                GRPCAsyncResponseStream<ProtoInvokeProxyDialBackResponse>
                    .Iterator
            >,
            allowPayloadMessagesFromProxy: Bool,
            computeInvokeWorkloadSession: InvokeWorkloadSession,
            logContext: LogContext
        ) async throws {
            var iterator = proxyDialBackMessageIterator.wrappedValue
            proxyMessages: while let dialBackMessage = try await iterator.next() {
                // Notify observer for response from proxy
                observer?.onResponseFromProxy(.init(dialBackMessage))

                switch dialBackMessage.type {
                case .proxyToComputeMessage(let proxyToComputeMessage):
                    switch proxyToComputeMessage.type {
                    case .decryptionKey:
                        Self.logger.error("\(logContext) Received unexpected DEK from proxy")
                        throw LocalCloudBoardGRPCClientError.proxyToComputeDEKInvalid
                    case .requestChunk(let chunk):
                        // it's not actually clear what ROPES will do if we try to also send messages
                        // to the worker node, but since the result will be a mangled mess thanks to the
                        // sequence numbers we know we don't ever want to so lets make our testing
                        // environments fail immediately on breaking that contract
                        guard allowPayloadMessagesFromProxy else {
                            Self.logger.error(
                                "\(logContext) Received request chunk from proxy when request bypass is configured"
                            )
                            throw LocalCloudBoardGRPCClientError.requestChunkFromProxyWhenRequestBypassConfigured
                        }
                        computeInvokeWorkloadSession.send(.init(data: chunk.encryptedPayload, isFinal: chunk.isFinal))
                        Self.logger.info("\(logContext) Sent workload chunk to compute node")
                    default:
                        Self.logger.info("\(logContext) Received non-interesting message from proxy")
                    }
                case .close:
                    // this is tricksy - if there is bypass we may want to close both
                    // if we suppose the proxy can 'take itself out of the loop' then the close just
                    // gets ignored. For now that's not a mode of operation we support
                    // so just convert the close into a close finish regardless of the bypass
                    Self.logger.info("\(logContext) Received proxy close notification")
                    computeInvokeWorkloadSession.finishSending()
                    break proxyMessages
                default:
                    // ropes does not do blind forwarding of messages it doesn't understand so just
                    // dropping this is fine conceptually, but worth noting we do in case it means we
                    // missed something changing
                    Self.logger.error(
                        "\(logContext) Received unexpected message from proxy: \(dialBackMessage.type.debugDescription)"
                    )
                }
            }
            Self.logger.info("\(logContext) Finished proxyDialBackResponseStream")
        }

        private func handleProxyWorkflowWorkerMessages(
            observer: ProxyDialBackMessageObserver?,
            computeInvokeWorkloadSession: InvokeWorkloadSession,
            bypassConfig: BypassConfiguration,
            streams: ProxyDialBackStreams,
            logContext: LogContext
        ) async throws {
            var computeResponseStreamIterator = computeInvokeWorkloadSession.responseStream.makeAsyncIterator()
            defer {
                bypassConfig.responseContinuation.finish()
            }
            while let chunk = try await computeResponseStreamIterator.next() {
                let protoChunk = Proto_Ropes_Common_Chunk.with {
                    $0.encryptedPayload = chunk.data
                    $0.isFinal = chunk.isFinal
                }
                if bypassConfig.mode == .matchRequestCiphersuiteSharedAeadState {
                    // Response bypass enabled, send the response directly to the client
                    bypassConfig.responseContinuation.yield(protoChunk)
                    Self.logger.info("\(logContext) Sent response chunk directly to client via bypass")
                } else {
                    // Response bypass not enabled, send back to proxy app
                    let responseMessage = ProtoInvokeProxyDialBackRequest.with {
                        $0.computeToProxyMessage = .with {
                            $0.responseChunk = protoChunk
                        }
                    }
                    observer?.onRequestToProxy(.init(responseMessage))
                    streams.requestContinuation.yield(responseMessage)
                    Self.logger.info("\(logContext) Sent response chunk from compute to proxy")
                }
            }
            let closeMessage = ProtoInvokeProxyDialBackRequest.with {
                $0.close = .init()
            }
            observer?.onRequestToProxy(.init(closeMessage))
            streams.requestContinuation.yield(closeMessage)
            streams.requestContinuation.finish()
            Self.logger.info("\(logContext) Finished forwarding compute node responses")
        }

        private func closeProxyDialBackRequestOnError(
            taskID: String,
            proxyDialBackContinuation: AsyncStream<ProtoInvokeProxyDialBackRequest>.Continuation,
            error: Error,
            ropesErrorCode: UInt32? = nil,
            logContext: LogContext
        ) throws {
            Self.logger.error("\(logContext) Closing proxy dial-back request due to error: \(error)")

            var closeMessage: ProtoInvokeProxyDialBackRequest.Close = .init()
            closeMessage.ropesErrorDescription = String(describing: error)

            switch error {
            case let error as GRPCStatusTransformable:
                let grpcStatus = error.makeGRPCStatus()
                closeMessage.grpcStatus = Int32(grpcStatus.code.rawValue)
                if let grpcMessage = grpcStatus.message {
                    closeMessage.grpcMessage = grpcMessage
                }
                closeMessage.ropesErrorCode = try GatewayComputeNodeSelectionError
                    .fromGRPCCode(grpcStatus.code).rawValue
                Self.logger.error("\(logContext) Error mapped to gRPC code: \(grpcStatus.code.rawValue)")
            default:
                // We use internalServerError for any error that's not from the compute node.
                // This doesn't fully align with how ROPES classify the errors, but for now we don't need to or intend
                // to
                // align.
                closeMessage.ropesErrorCode = GatewayComputeNodeSelectionError.internalServerError.rawValue
                Self.logger.error("\(logContext) Error classified as internal server error")
            }

            if let ropesErrorCode {
                closeMessage.ropesErrorCode = ropesErrorCode
                Self.logger.error("\(logContext) Using explicit ROPES error code: \(ropesErrorCode)")
            }

            proxyDialBackContinuation.yield(ProtoInvokeProxyDialBackRequest.with {
                $0.close = closeMessage
            })
            proxyDialBackContinuation.finish()

            self.proxyWorkerErrorHolder.recordError(for: taskID, error: error)
        }

        private func handleFailureToFindWorker(taskID: String, errorCode: UInt32, logContext: LogContext) {
            Self.logger.error("\(logContext) Failed to find worker, error code: \(errorCode)")

            // Record the specific error so it can be retrieved when the proxy returns ProxyWorkerError
            let error = GatewayComputeNodeSelectionError(rawValue: errorCode) ?? .internalServerError
            self.proxyWorkerErrorHolder.recordError(for: taskID, error: error)

            // Connect to proxy
            let (proxyDialBackContinuation, _) = self.proxyClient.invokeProxyDialBack(
                taskID: taskID
            )
            proxyDialBackContinuation.yield(.with {
                $0.close = .with {
                    // Selection errors only set ropesErrorCode. Runtime gRPC errors from compute nodes
                    // are handled by closeProxyDialBackRequestOnError which sets grpcStatus/grpcMessage.
                    $0.ropesErrorCode = errorCode
                }
            })
            proxyDialBackContinuation.finish()
        }

        /// Helper to handle negotiate pick failure
        private func failNegotiatePickWith(
            error: GatewayComputeNodeSelectionError,
            taskID: String,
            bypassConfig: BypassConfiguration,
            logContext: LogContext
        ) {
            bypassConfig.responseContinuation.finish(throwing: error)
            self.handleFailureToFindWorker(
                taskID: taskID,
                errorCode: error.rawValue,
                logContext: logContext
            )
        }

        /// Helper to continue with selected compute endpoint through proxy workflow
        /// Consolidates the common pattern of setting up context and invoking the proxy workflow
        private func continueWithSelectedEndpoint(
            choice: UsageTrackedAppEndpoint,
            workloadParameters: [String: [String]],
            computeNodeSelectionContext: ComputeNodeSelectionContext,
            bypassConfig: BypassConfiguration,
            logMessage: String,
            streams: ProxyDialBackStreams? = nil,
            proxyDialBackMessageIterator: UnsafeTransfer<
                GRPCAsyncResponseStream<ProtoInvokeProxyDialBackResponse>
                    .Iterator
            >? = nil
        ) async throws {
            try await choice.withValueAsync { endpoint in
                let logContextWithCompute = LogContext(
                    requestID: computeNodeSelectionContext.originalRequestContext.requestID,
                    taskID: computeNodeSelectionContext.initiate.taskID,
                    proxyEndpoint: self.proxyClient.endpoint.hostAndPort,
                    computeEndpoint: endpoint.hostAndPort
                )
                Self.logger.info("\(logContextWithCompute) \(logMessage)")

                let metadata = InvokeWorkloadRequestMetadata(
                    workloadType: computeNodeSelectionContext.initiate.serviceName,
                    workloadParameters: workloadParameters
                )

                let context = ProxyWorkflowContext(
                    computeNodeSelection: computeNodeSelectionContext,
                    metadata: metadata,
                    log: logContextWithCompute
                )

                return try await self.handleProxyWorkflow(
                    with: endpoint,
                    context: context,
                    bypassConfig: bypassConfig,
                    streams: streams,
                    proxyDialBackMessageIterator: proxyDialBackMessageIterator
                )
            }
        }

        /// Setup data needed for ensemble selection
        private struct EnsembleSelectionSetup {
            let proxyEndpoint: ProxyCloudAppEndpoint
            let negotiateConstraints: GatewayEnsembleSelectionStateMachine.NegotiateConstraints
            let serviceDiscovery: ServiceDiscoveryAbstraction.ConsumerClientProtocol
            let allCandidates: [GatewayEnsembleSelectionStateMachine.EnsembleCandidate]
            let workloadParameters: [String: [String]]
        }

        /// Result of racing proxy selection vs queue notifications
        private enum PickRaceResult {
            case proxySelection(
                selected: GatewayEnsembleSelectionStateMachine.EnsembleCandidate,
                token: UsageTrackedAppEndpoint?
            )
            case queueNotification(
                candidate: GatewayEnsembleSelectionStateMachine.EnsembleCandidate,
                token: UsageTrackedAppEndpoint
            )
            case proxyFailed
        }

        /// Extract negotiate constraints, validate, and gather candidates
        private func setupEnsembleSelection(
            proxyInitiate: ProtoInvokeProxyInitiate,
            computeNodeSelectionContext: ComputeNodeSelectionContext,
            bypassConfig: BypassConfiguration,
            logContext: LogContext
        ) throws -> EnsembleSelectionSetup {
            // Validate that we have a proxy endpoint
            guard let proxyEndpoint = self.proxyClient.endpoint as? ProxyCloudAppEndpoint else {
                Self.logger.error("\(logContext) Proxy client endpoint is not a ProxyCloudAppEndpoint")
                throw PCCGatewayError.invalidEndpointType
            }

            // Extract negotiate constraints from proxy message
            guard let negotiateConstraints = GatewayEnsembleSelectionStateMachine
                .NegotiateConstraints(proto: proxyInitiate) else {
                Self.logger.error("\(logContext) No negotiate constraints from proxy")
                throw LocalCloudBoardClientError.internalError("Missing negotiate constraints for pick flow")
            }

            Self.logger.info("""
            \(logContext) Using negotiate constraints from proxy message: \
            pick=\(negotiateConstraints.pick?.numProvidedChoices ?? 0)/\(
                negotiateConstraints.pick?
                    .numSelectedChoices ?? 0
            ) \
            trustedEnsembles=\(negotiateConstraints.trustedEnsembles.count) \
            trustedRackIds=\(negotiateConstraints.trustedRackIds)
            """)

            // Validate service discovery is available
            guard let serviceDiscovery = self.gatewayConfig.serviceDiscovery else {
                Self.logger.error("\(logContext) Service discovery not available for negotiate pick")
                self.failNegotiatePickWith(
                    error: .internalServerError,
                    taskID: computeNodeSelectionContext.initiate.taskID,
                    bypassConfig: bypassConfig,
                    logContext: logContext
                )
                throw LocalCloudBoardClientError.internalError("Service discovery not available")
            }

            // Gather all candidates from service discovery
            let allCandidates = try GatewayEnsembleSelectionStateMachine.gatherCandidates(
                serviceDiscovery: serviceDiscovery,
                availableEndpoints: self.nodeManager.trackedComputeEndpointPool.allValues
            )
            guard !allCandidates.isEmpty else {
                Self.logger.error("\(logContext) No ensemble candidates available")
                self.failNegotiatePickWith(
                    error: .nodesBusy,
                    taskID: computeNodeSelectionContext.initiate.taskID,
                    bypassConfig: bypassConfig,
                    logContext: logContext
                )
                throw LocalCloudBoardClientError.internalError("No candidates available")
            }

            // Workload parameters
            let workloadParameters = try self.gatewayConfig.extendedComputeNodeSelectionStrategy
                .applyConventionalROPESWorkloadManipulation(
                    context: computeNodeSelectionContext,
                    serviceDiscovery: serviceDiscovery
                )

            return EnsembleSelectionSetup(
                proxyEndpoint: proxyEndpoint,
                negotiateConstraints: negotiateConstraints,
                serviceDiscovery: serviceDiscovery,
                allCandidates: allCandidates,
                workloadParameters: workloadParameters
            )
        }

        /// Send pick offer to proxy with available ensemble candidates
        private func sendPickOfferToProxy(
            availableCandidates: [GatewayEnsembleSelectionStateMachine.EnsembleCandidate],
            streams: ProxyDialBackStreams,
            observer: ProxyDialBackMessageObserver?,
            logContext: LogContext
        ) {
            let negotiatePickMessage = ProtoInvokeProxyDialBackRequest.with {
                $0.computeToProxyMessage = .with {
                    $0.negotiatePick = .with {
                        $0.ensembles = availableCandidates.map { entry in
                            Proto_Ropes_Common_EnsembleInstanceId.with {
                                $0.ensembleID = entry.ensembleId
                                $0.bootID = entry.bootId
                            }
                        }
                    }
                }
            }

            observer?.onRequestToProxy(.init(negotiatePickMessage))
            streams.requestContinuation.yield(negotiatePickMessage)
            Self.logger.info("\(logContext) Sent pick offer with \(availableCandidates.count) ensembles to proxy")
        }

        /// Start background queue tasks for attempted direct candidates in case they become available
        /// Returns the Task and closures to manage tokens
        private func startQueueTasksForCandidates(
            _ attemptedCandidates: [GatewayEnsembleSelectionStateMachine.EnsembleCandidate]
        ) -> (
            task: Task<
                (
                    candidate: GatewayEnsembleSelectionStateMachine.EnsembleCandidate,
                    token: UsageTrackedAppEndpoint
                )?,
                Never
            >,
            cancelAllTokens: @Sendable () -> Void
        ) {
            let queueTokens = Mutex<[ComputeNodeQueueManager.QueueToken]>([])
            let task = Task<
                (candidate: GatewayEnsembleSelectionStateMachine.EnsembleCandidate, token: UsageTrackedAppEndpoint)?,
                Never
            > {
                let queueManager = self.nodeManager.queueManager
                for candidate in attemptedCandidates {
                    do {
                        let availableEndpoint =
                            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<
                                PCCHarness.ComputeCloudAppEndpoint,
                                Error
                            >) in
                                let token = queueManager.enqueue(
                                    endpoint: candidate.endpoint,
                                    continuation: continuation
                                )
                                queueTokens.withLock { $0.append(token) }
                            }
                        if let token = try? self.nodeManager.trackedComputeEndpointPool
                            .useSpecific(availableEndpoint) {
                            return (candidate: candidate, token: token)
                        }
                    } catch {
                        // Continue to next candidate
                    }
                }
                return nil
            }

            let cancelAllTokens: @Sendable () -> Void = {
                queueTokens.withLock { tokens in
                    for token in tokens {
                        token.cancel()
                    }
                }
            }

            return (task: task, cancelAllTokens: cancelAllTokens)
        }

        /// Race proxy selection against queue notifications for direct candidates that might become available
        private func raceProxySelectionVsQueue(
            streams: ProxyDialBackStreams,
            observer: ProxyDialBackMessageObserver?,
            allCandidates: [GatewayEnsembleSelectionStateMachine.EnsembleCandidate],
            queueTask: Task<
                (
                    candidate: GatewayEnsembleSelectionStateMachine.EnsembleCandidate,
                    token: UsageTrackedAppEndpoint
                )?,
                Never
            >,
            cancelAllTokens: @escaping @Sendable () -> Void,
            attemptedCandidates: [GatewayEnsembleSelectionStateMachine.EnsembleCandidate],
            logContext: LogContext
        ) async throws -> (
            result: PickRaceResult,
            proxyResponseIterator: GRPCAsyncResponseStream<ProtoInvokeProxyDialBackResponse>.Iterator
        ) {
            // Read selectableEnsembles (while queue tasks are starting in background)
            var sharedProxyIterator = streams.responseStream.makeAsyncIterator()

            guard let selectionResponse = try await sharedProxyIterator.next() else {
                Self.logger.error("\(logContext) Proxy closed stream before sending selectableEnsembles")
                throw LocalCloudBoardClientError.internalError("Proxy closed stream")
            }

            observer?.onResponseFromProxy(.init(selectionResponse))

            guard selectionResponse.proxyToComputeMessage.isInitialized,
                  case .selectableEnsembles = selectionResponse.proxyToComputeMessage.type else {
                Self.logger.error("\(logContext) Invalid selection response from proxy")
                throw LocalCloudBoardClientError.internalError("Invalid selection response")
            }

            let selectableEnsembles = selectionResponse.proxyToComputeMessage.selectableEnsembles

            // Determine which ensemble to use based on injection strategy
            let ensembleToUse: Proto_Ropes_Common_EnsembleInstanceId?
            if let injectionConfig = self.gatewayConfig.injectedEnsembleSelectionConfig {
                switch injectionConfig.strategy {
                case .specific(let injection):
                    // Inject a specific ensemble
                    ensembleToUse = Proto_Ropes_Common_EnsembleInstanceId.with {
                        $0.ensembleID = injection.ensembleID
                        $0.bootID = injection.bootID
                    }
                case .differentFromProxySelection:
                    // Inject a different candidate than what proxy selected
                    guard let proxySelection = selectableEnsembles.ensembles.first else {
                        Self.logger
                            .error(
                                "\(logContext) Test injection failed: Proxy returned no selectable ensembles for differentFromProxySelection"
                            )
                        throw LocalCloudBoardClientError.internalError(
                            "Test injection error: Cannot use .differentFromProxySelection when proxy returns no ensembles"
                        )
                    }

                    // Find a different candidate from allCandidates
                    guard let differentCandidate = allCandidates.first(where: { candidate in
                        candidate.ensembleId != proxySelection.ensembleID ||
                            candidate.bootId != proxySelection.bootID
                    }) else {
                        Self.logger.error(
                            "\(logContext) Test injection failed: Only one ensemble available, cannot inject different ensemble. Proxy selected: \(proxySelection.ensembleID):\(proxySelection.bootID)"
                        )
                        throw LocalCloudBoardClientError.internalError(
                            "Test injection error: Cannot use .differentFromProxySelection with only one ensemble available (need at least 2)"
                        )
                    }

                    ensembleToUse = Proto_Ropes_Common_EnsembleInstanceId.with {
                        $0.ensembleID = differentCandidate.ensembleId
                        $0.bootID = differentCandidate.bootId
                    }
                }
            } else {
                // No injection, use proxy's selection
                ensembleToUse = nil
            }

            let raceResult = try await withThrowingTaskGroup(of: PickRaceResult?.self) { group in
                // Task 1: Try to reserve proxy's selection (or injected ensemble)
                group.addTask {
                    // Use injected ensemble if configured, otherwise use proxy's selection
                    let selectedEnsemble = ensembleToUse ?? selectableEnsembles.ensembles.first

                    guard let selectedEnsemble else {
                        Self.logger.error("\(logContext) Proxy returned no selectable ensembles")
                        return .proxyFailed
                    }

                    // Map selected ensemble back to candidate
                    guard let matchedCandidate = allCandidates.first(where: { candidate in
                        candidate.ensembleId == selectedEnsemble.ensembleID &&
                            candidate.bootId == selectedEnsemble.bootID
                    }) else {
                        Self.logger.error("\(logContext) Could not map proxy selection to candidate")
                        return .proxyFailed
                    }

                    // Try to reserve the proxy's selection
                    let token: UsageTrackedAppEndpoint?
                    do {
                        token = try self.nodeManager.trackedComputeEndpointPool
                            .useSpecific(matchedCandidate.endpoint)
                    } catch {
                        token = nil
                    }
                    return .proxySelection(
                        selected: matchedCandidate,
                        token: token
                    )
                }

                // Task 2: Wait for queue notification
                if !attemptedCandidates.isEmpty {
                    group.addTask {
                        if let queueResult = await queueTask.value {
                            return .queueNotification(
                                candidate: queueResult.candidate,
                                token: queueResult.token
                            )
                        } else {
                            return nil
                        }
                    }
                }

                // Wait for first successful result
                while let result = try await group.next() {
                    if let result {
                        // We have a winner - cancel remaining tasks
                        group.cancelAll()
                        queueTask.cancel()
                        cancelAllTokens()
                        return result
                    }
                }

                Self.logger.warning("\(logContext) All race tasks completed without success")

                // All tasks completed without success
                queueTask.cancel()
                cancelAllTokens()
                return .proxyFailed
            }

            return (result: raceResult, proxyResponseIterator: sharedProxyIterator)
        }

        /// This function implements the pick mechanism when direct reservation of trusted ensembles fails.
        /// It coordinates a race between two concurrent selection paths:
        /// Pick Path: Send available ensemble options to proxy, wait for proxy to pick one, attempt to reserve it
        /// Queue Path: Queue on previously-attempted trusted ensembles in case they become available during pick
        /// Whichever path successfully reserves an endpoint first wins.
        private func handlePickProtocol(
            pickCandidates: [GatewayEnsembleSelectionStateMachine.EnsembleCandidate],
            allCandidates: [GatewayEnsembleSelectionStateMachine.EnsembleCandidate],
            directCandidates: [GatewayEnsembleSelectionStateMachine.EnsembleCandidate],
            attemptedDirect: Set<String>,
            streams: ProxyDialBackStreams,
            observer: ProxyDialBackMessageObserver?,
            stateMachine: inout GatewayEnsembleSelectionStateMachine,
            logContext: LogContext
        ) async throws -> (
            action: GatewayEnsembleSelectionStateMachine.Action,
            proxyIterator: GRPCAsyncResponseStream<ProtoInvokeProxyDialBackResponse>.Iterator
        ) {
            // Filter to only available (non-busy) ensembles for the pick offer.
            // This is only to make tests deterministic and not flaky.
            // Legally, ROPES is allowed to send busy ensembles as well.
            let availableEndpoints = Set(self.nodeManager.trackedComputeEndpointPool.availableValues)
            let availableCandidates = pickCandidates.filter { candidate in
                availableEndpoints.contains(candidate.endpoint)
            }

            guard !availableCandidates.isEmpty else {
                Self.logger.error("\(logContext) No available candidates for pick (all are busy)")
                throw LocalCloudBoardClientError.internalError("No available candidates for pick")
            }

            Self.logger.info(
                "\(logContext) Filtered to \(availableCandidates.count) available ensembles for pick offer"
            )

            // Send pick offer to proxy
            self.sendPickOfferToProxy(
                availableCandidates: availableCandidates,
                streams: streams,
                observer: observer,
                logContext: logContext
            )

            // Verify state machine contract
            assert(
                directCandidates.allSatisfy { attemptedDirect.contains($0.ensembleId) },
                "State machine should only send pick when all direct candidates attempted"
            )

            // Transition state machine
            stateMachine.pickSentToProxy(
                candidates: availableCandidates,
                stillTryingDirect: [],
                attemptedEnsembles: attemptedDirect
            )

            // Queue on attempted direct candidates that might become available during pick
            let attemptedCandidates = directCandidates.filter { candidate in
                attemptedDirect.contains(candidate.ensembleId)
            }

            let (queueTask, cancelAllTokens) = self.startQueueTasksForCandidates(attemptedCandidates)

            // Race proxy selection vs queue notifications
            let (raceResult, proxyIterator) = try await self.raceProxySelectionVsQueue(
                streams: streams,
                observer: observer,
                allCandidates: allCandidates,
                queueTask: queueTask,
                cancelAllTokens: cancelAllTokens,
                attemptedCandidates: attemptedCandidates,
                logContext: logContext
            )

            // Process race result through state machine
            let action: GatewayEnsembleSelectionStateMachine.Action
            switch raceResult {
            case .proxySelection(let selected, let token):
                action = stateMachine.recordProxySelection(
                    selected: selected,
                    token: token,
                    workload: [:]
                )

            case .queueNotification(let candidate, let token):
                action = stateMachine.recordDirectReservation(
                    candidate: candidate,
                    token: token,
                    workload: [:]
                )

            case .proxyFailed:
                Self.logger.error("\(logContext) Proxy did not provide valid selection")
                action = stateMachine.recordPickProtocolFailed()
            }

            return (action: action, proxyIterator: proxyIterator)
        }

        /// Handles ensemble selection using negotiate constraints from the proxy.
        ///
        /// This function uses constraints provided in the proxy's InvokeProxyInitiate message (trusted ensembles,
        /// trusted rack IDs, pick configuration) to select a compute node. Selection strategy:
        /// 1. Try direct reservation of trusted ensembles first
        /// 2. If all trusted ensembles are busy, escalate to pick protocol (if configured)
        /// 3. Pick protocol races proxy selection against queue notifications for stickiness
        private func handleNegotiateConstraintBasedSelection(
            proxyInitiate: ProtoInvokeProxyInitiate,
            logContext: LogContext,
            computeNodeSelectionContext: ComputeNodeSelectionContext,
            bypassConfig: BypassConfiguration
        ) async throws {
            // Setup: extract constraints, validate, gather candidates
            let setup = try self.setupEnsembleSelection(
                proxyInitiate: proxyInitiate,
                computeNodeSelectionContext: computeNodeSelectionContext,
                bypassConfig: bypassConfig,
                logContext: logContext
            )

            // Create state machine and start selection
            var stateMachine = GatewayEnsembleSelectionStateMachine()
            var action = stateMachine.start(
                constraints: setup.negotiateConstraints,
                allCandidates: setup.allCandidates,
                workload: setup.workloadParameters
            )

            var streams: ProxyDialBackStreams?
            var proxyResponseIterator: GRPCAsyncResponseStream<ProtoInvokeProxyDialBackResponse>.Iterator?
            let observer = self.nodeManager.proxyDialBackMessageObserver(for: setup.proxyEndpoint)

            // Execute actions until we reach a terminal state
            actionLoop: while true {
                switch action {
                case .tryDirectReservation(let candidate, remaining: _):
                    Self.logger.info("\(logContext) Trying direct reservation for \(candidate.ensembleId)")

                    // Try to reserve the candidate
                    let token: UsageTrackedAppEndpoint?
                    do {
                        token = try self.nodeManager.trackedComputeEndpointPool.useSpecific(candidate.endpoint)
                        Self.logger.info(
                            "\(logContext) Direct reservation succeeded for \(candidate.ensembleId) at \(candidate.endpoint.hostAndPort)"
                        )
                    } catch {
                        Self.logger.info(
                            "\(logContext) Direct reservation failed for \(candidate.ensembleId) at \(candidate.endpoint.hostAndPort): \(error)"
                        )
                        token = nil
                    }

                    // Record the result and get next action
                    action = stateMachine.recordDirectReservation(
                        candidate: candidate,
                        token: token,
                        workload: setup.workloadParameters
                    )

                    // Yield to prevent busy loop when trying multiple direct reservations
                    await Task.yield()

                case .sendPickToProxy(let pickCandidates):
                    Self.logger.info("\(logContext) Sending pick to proxy with \(pickCandidates.count) ensembles")

                    // Connect to proxy if not already connected
                    if streams == nil {
                        let (proxyDialBackContinuation, proxyDialBackResponseStream) = self.proxyClient
                            .invokeProxyDialBack(
                                taskID: computeNodeSelectionContext.initiate.taskID
                            )
                        streams = ProxyDialBackStreams(
                            requestContinuation: proxyDialBackContinuation,
                            responseStream: proxyDialBackResponseStream
                        )
                    }

                    guard let actualStreams = streams else {
                        Self.logger.error("\(logContext) Failed to establish proxy connection")
                        action = stateMachine.recordPickProtocolFailed()
                        continue
                    }

                    // Verify we're in the expected state and extract direct candidates
                    guard case .ready(let directCandidates, _, let attemptedDirect) = stateMachine.currentStateDetails
                    else {
                        Self.logger.error(
                            "\(logContext) Unexpected state when sending pick (current: \(stateMachine.currentState))"
                        )
                        action = stateMachine.recordPickProtocolFailed()
                        continue
                    }

                    do {
                        let (pickAction, proxyIterator) = try await self.handlePickProtocol(
                            pickCandidates: pickCandidates,
                            allCandidates: setup.allCandidates,
                            directCandidates: directCandidates,
                            attemptedDirect: attemptedDirect,
                            streams: actualStreams,
                            observer: observer,
                            stateMachine: &stateMachine,
                            logContext: logContext
                        )
                        proxyResponseIterator = proxyIterator

                        // Update action with correct workload parameters
                        switch pickAction {
                        case .succeeded(var result):
                            result = GatewayEnsembleSelectionStateMachine.ReservationResult(
                                candidate: result.candidate,
                                token: result.token,
                                workload: setup.workloadParameters,
                                source: result.source
                            )
                            action = .succeeded(result)
                        default:
                            action = pickAction
                        }
                    } catch {
                        Self.logger.error("\(logContext) Pick protocol failed: \(error)")
                        action = stateMachine.recordPickProtocolFailed()
                    }

                case .succeeded(let result):
                    Self.logger
                        .info("\(logContext) Selection succeeded via \(result.source): \(result.candidate.ensembleId)")

                    // Continue with the selected endpoint using the normal proxy workflow
                    try await self.continueWithSelectedEndpoint(
                        choice: result.token,
                        workloadParameters: result.workload,
                        computeNodeSelectionContext: computeNodeSelectionContext,
                        bypassConfig: bypassConfig,
                        logMessage: "Selected compute node via \(result.source) (ensemble selection)",
                        streams: streams,
                        proxyDialBackMessageIterator: proxyResponseIterator.map { UnsafeTransfer($0) }
                    )
                    break actionLoop

                case .failed(let error):
                    Self.logger.error("\(logContext) Selection failed: \(error)")
                    self.failNegotiatePickWith(
                        error: .nodesBusy,
                        taskID: computeNodeSelectionContext.initiate.taskID,
                        bypassConfig: bypassConfig,
                        logContext: logContext
                    )
                    break actionLoop

                case .waitForProxySelection:
                    Self.logger
                        .error("\(logContext) Unexpected state: Received waitForProxySelection after race completed")
                    action = stateMachine.recordPickProtocolFailed()
                    // Yield to prevent tight loop if state machine misbehaves
                    await Task.yield()
                }
            }
        }
    }
}

extension PCCHarness.ComputeNodeSelectionContext.InvokeProxyInitiate {
    init(_ proto: PCCHarness.ProtoInvokeProxyInitiate) {
        let reuseConstraints: PCCHarness.ReuseConstraints? = if proto.hasReuseConstraints {
            .init(proto: proto.reuseConstraints, forceReuseFailure: false)
        } else {
            nil
        }

        self = .init(
            taskID: proto.taskID,
            groupID: proto.groupID,
            serviceName: proto.workload.type,
            workloadParameters: proto.workload.param.asMap(),
            isDiscardable: proto.isDiscardable,
            reuseConstraints: reuseConstraints
        )
    }
}
