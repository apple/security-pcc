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

import Foundation
internal import InternalGRPC
import os
internal import Synchronization
internal import InternalSwiftProtobuf

extension PCCHarness {
    enum InvokeWorkloadExecutorError: Error {
        case receivedInvokeProxyInitiateForComputeRequest
        case receivedInvokeProxyInitiateForNackRequest
        case receivedProxyWorkerErrorForNackRequest
        case requestExecutionError(source: String, code: UInt32, message: String)
    }

    final class ProxyWorkerErrorHolder: Sendable {
        private let perTaskErrors: Mutex<[String: Error]> = .init([:])

        func recordError(for taskID: String, error: Error) {
            self.perTaskErrors.withLock {
                $0[taskID] = error
            }
        }

        func recordedError(for taskID: String) -> Error? {
            return self.perTaskErrors.withLock {
                return $0[taskID]
            }
        }
    }

    final class InvokeWorkloadExecutor: Sendable {
        private struct LogContext: CustomStringConvertible {
            let requestID: UUID
            let endpoint: HostAndPort
            let nodeType: CloudAppType

            var description: String {
                "[\(self.requestID), \(self.endpoint) (\(self.nodeType))]"
            }
        }

        static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.InvokeWorkloadExecutor"
        )

        private let client: GatewayPCCClient
        private let nodeManager: PCCNodeManager
        private let gatewayConfig: PCCGatewayConfig

        // The errors to be returned to the clients if Trusted Proxy sends ProxyWorkerErrors messages
        private let proxyWorkerErrors: ProxyWorkerErrorHolder = .init()

        init(client: GatewayPCCClient, nodeManager: PCCNodeManager, gatewayConfig: PCCGatewayConfig) {
            self.client = client
            self.nodeManager = nodeManager
            self.gatewayConfig = gatewayConfig
        }

        func invokeWorkload<ReturnType: Sendable>(
            context: InvokeWorkloadRequestContext,
            configuration: InvokeWorkloadConfiguration,
            bypassResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation? = nil,
            handler: @Sendable @escaping (
                InvokeWorkloadSession,
                (any BypassContinuationProtocol<ProtoInvokeWorkloadRequest>)?,
                AsyncStream<ProtoInvokeWorkloadRequest>.Continuation
            ) async throws -> ReturnType
        ) async throws -> ReturnType {
            let logContext = LogContext(
                requestID: context.requestID,
                endpoint: self.client.endpoint.hostAndPort,
                nodeType: (self.client.endpoint as! any InternalAppEndpoint).appType
            )

            return try await self.invokeWorkloadFullControl(
                context: context,
                configuration: configuration,
            ) { invokeWorkloadSession in
                // Send setup
                Self.logger.info("\(logContext) Sending setup message")
                invokeWorkloadSession.send(.makeSetup())

                // Send parameters
                let requestBypassed = switch configuration {
                case .compute: false
                case .proxy(let proxyConfig): proxyConfig.useRequestBypass
                }
                if requestBypassed {
                    Self.logger.info("\(logContext) Request bypass enabled")
                }
                let responseBypass: ProtoResponseBypassMode? = switch configuration {
                case .compute(let computeConfig): computeConfig.responseBypassMode.toProto
                case .proxy: nil
                }
                let dekInfo = context.encapsulatedDataEncryptionKey
                invokeWorkloadSession.send(
                    .makeParameters(
                        decryptionKey: .makeDecryptionKey(keyID: dekInfo.keyID, key: dekInfo.dataEncryptionKey),
                        requestID: context.requestID,
                        metadata: context.workloadMetadata,
                        requestBypassed: requestBypassed,
                        responseBypass: responseBypass
                    )
                )

                // Get the gRPC continuation for connecting bypass streams
                let (grpcRequestStream, grpcRequestContinuation) = AsyncStream<ProtoInvokeWorkloadRequest>.makeStream()

                // Create bypass continuation if request bypass is enabled
                let bypassContinuation: any BypassContinuationProtocol<ProtoInvokeWorkloadRequest> =
                    if requestBypassed {
                        BufferingBypassContinuation()
                    } else {
                        NotBypassedContinuation(grpcRequestContinuation)
                    }

                let (requestStream, requestContinuation) = AsyncStream<FinalizableChunk>.makeStream()
                let (responseStream, responseContinuation) = AsyncThrowingStream<FinalizableChunk, Error>.makeStream()
                let session = InvokeWorkloadSession(
                    requestContinuation: requestContinuation,
                    responseStream: responseStream
                )

                return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                    // Forward gRPC request stream (from bypass continuation or client) to invokeWorkloadSession
                    group.addTask {
                        for await grpcRequest in grpcRequestStream {
                            invokeWorkloadSession.send(grpcRequest)
                        }
                        return .requestStreamFinished
                    }

                    // Transform encrypted PCC protocol messages into InvokeWorkloadRequest requestChunk messages
                    group.addTask {
                        var isFirstChunk = true
                        for await pccRequestChunk in requestStream {
                            let chunkMessage = ProtoInvokeWorkloadRequest.makeChunk(
                                data: pccRequestChunk.data,
                                isFinal: pccRequestChunk.isFinal
                            )

                            // First chunk: send to both proxy (via invokeWorkloadSession) and buffer (via
                            // bypassContinuation)
                            // This duplicates the auth token so ROPES sees it while we also buffer it for the compute
                            // node
                            if requestBypassed, isFirstChunk {
                                invokeWorkloadSession.send(chunkMessage)
                            }

                            // All chunks go through the bypass continuation (which buffers if bypassed, or forwards if
                            // not)
                            bypassContinuation.yield(chunkMessage)
                            isFirstChunk = false
                        }
                        bypassContinuation.finish()

                        // If not bypassed, the continuation already finished the gRPC stream
                        // If bypassed, we need to finish it manually (it will be flushed when connect() is called)
                        if !requestBypassed {
                            grpcRequestContinuation.finish()
                        }
                        return .requestStreamFinished
                    }

                    // Process and forward InvokeWorkloadResponse responseChunk messages
                    group.addTask {
                        try await self.processInvokeWorkloadResponseMessages(
                            invokeWorkloadSession: invokeWorkloadSession,
                            responseContinuation: responseContinuation,
                            context: context,
                            configuration: configuration,
                            bypassContinuation: requestBypassed ? bypassContinuation : nil,
                            bypassResponseContinuation: bypassResponseContinuation,
                            logContext: logContext
                        )
                        return .responseStreamFinished
                    }

                    // Run provided handler
                    group.addTask {
                        do {
                            // Pass bypass continuation if request bypass is enabled, otherwise nil
                            // Also pass the gRPC continuation for connecting bypass streams
                            let bypassToPass = requestBypassed ? bypassContinuation : nil
                            return try await .handlerFinished(handler(session, bypassToPass, grpcRequestContinuation))
                        } catch {
                            return .handlerError(error)
                        }
                    }

                    while let taskResult = try await group.next() {
                        switch taskResult {
                        case .handlerFinished(let result):
                            Self.logger.debug("\(logContext) invokeWorkload handler finished")
                            group.cancelAll()
                            return result
                        case .handlerError(let error):
                            Self.logger.error("\(logContext) invokeWorkload handler failed: \(error)")
                            group.cancelAll()
                            throw error
                        case .requestStreamFinished:
                            Self.logger.debug("\(logContext) invokeWorkload request stream finished")
                        case .responseStreamFinished:
                            Self.logger.debug("\(logContext) invokeWorkload response stream finished")
                        }
                    }

                    throw LocalCloudBoardClientError
                        .internalError("Unexpectedly reached end of invokeWorkload without result")
                }
            }
        }

        private func processInvokeWorkloadResponseMessages(
            invokeWorkloadSession: FullInvokeWorkloadSession,
            responseContinuation: AsyncThrowingStream<FinalizableChunk, Error>.Continuation,
            context: InvokeWorkloadRequestContext,
            configuration: InvokeWorkloadConfiguration,
            bypassContinuation: (any BypassContinuationProtocol<ProtoInvokeWorkloadRequest>)?,
            bypassResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation?,
            logContext: LogContext
        ) async throws {
            defer {
                // Proxy nodes are not guaranteed to make outbound calls with response bypass enabled
                // so we need to ensure that we always finish the response bypass stream
                bypassResponseContinuation?.finish()
            }
            do {
                try await withThrowingTaskGroup { group in
                    for try await invokeWorkloadResponse in invokeWorkloadSession.responseStream {
                        guard let invokeWorkloadResponseType = invokeWorkloadResponse.type else {
                            throw PCCGatewayError.unexpectedInvokeWorkloadResponseMessage
                        }
                        switch invokeWorkloadResponseType {
                        case .setupAck(let setupAck):
                            Self.logger.info("\(logContext) Received setupAck \(setupAck.textFormatString())")
                        case .responseChunk(let chunk):
                            Self.logger
                                .info("\(logContext) Received response chunk of \(chunk.encryptedPayload.count) bytes")
                            responseContinuation.yield(.init(
                                data: chunk.encryptedPayload,
                                isFinal: chunk.isFinal
                            ))
                        case .invokeProxyInitiate(let proxyInitiateRequest):
                            Self.logger.info("\(logContext) Received invokeProxyInitiate message")
                            guard case .proxy(let proxyRequestConfiguration) = configuration else {
                                throw InvokeWorkloadExecutorError.receivedInvokeProxyInitiateForComputeRequest
                            }

                            group.addTask {
                                // Create a no-op bypass response continuation if none was provided
                                let (_, noOpBypassResponseContinuation) =
                                    AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.makeStream()
                                let effectiveBypassResponseContinuation = bypassResponseContinuation ??
                                    noOpBypassResponseContinuation
                                try await ProxyDialBackOrchestrator(
                                    proxyClient: self.client,
                                    nodeManager: self.nodeManager,
                                    gatewayConfig: self.gatewayConfig,
                                    proxyRequestConfiguration: proxyRequestConfiguration,
                                    proxyWorkerErrorHolder: self.proxyWorkerErrors
                                ).initiateProxyDialBack(
                                    originalRequestContext: context,
                                    proxyInitiate: proxyInitiateRequest,
                                    bypassContinuation: bypassContinuation,
                                    bypassMode: proxyInitiateRequest.responseBypassMode,
                                    bypassResponseContinuation: effectiveBypassResponseContinuation
                                )
                            }
                        case .proxyWorkerError(let workerError):
                            Self.logger
                                .error("\(logContext) Received proxyWorkerError for task ID \(workerError.taskID)")
                            let error = self.proxyWorkerErrors.recordedError(for: workerError.taskID) ??
                                LocalCloudBoardGRPCClientError.proxyInternalError
                            Self.logger.error("\(logContext) Finishing response stream with error: \(error)")
                            responseContinuation.finish(throwing: error)
                        case .requestExecutionError(let error):
                            Self.logger.error(
                                "\(logContext) Received request execution error from \(String(describing: error.source)) with code \(error.errorCode) \(error.errorMessage)"
                            )
                            let executionError = InvokeWorkloadExecutorError.requestExecutionError(
                                source: String(describing: error.source),
                                code: error.errorCode,
                                message: error.errorMessage
                            )
                            responseContinuation.finish(throwing: executionError)
                            throw executionError
                        }
                    }
                    responseContinuation.finish()

                    // Wait for outstanding compute node responses via response bypass stream
                    try await group.waitForAll()
                }
            } catch {
                responseContinuation.finish(throwing: error)
            }
        }

        func invokeWorkloadFullControl<ReturnType: Sendable>(
            context: InvokeWorkloadRequestContext,
            configuration: InvokeWorkloadConfiguration,
            recordMessagesToOverride: URL? = nil,
            handler: @Sendable @escaping (FullInvokeWorkloadSession) async throws -> ReturnType
        ) async throws -> ReturnType {
            let logContext = LogContext(
                requestID: context.requestID,
                endpoint: self.client.endpoint.hostAndPort,
                nodeType: (self.client.endpoint as! any InternalAppEndpoint).appType
            )

            let (requestStream, requestContinuation) = AsyncStream<ProtoInvokeWorkloadRequest>.makeStream()
            let (responseStream, responseContinuation) = AsyncThrowingStream<ProtoInvokeWorkloadResponse, Error>
                .makeStream()
            let session = FullInvokeWorkloadSession(
                requestContinuation: requestContinuation,
                responseStream: responseStream
            )

            let (cloudboardRequestContinuation, cloudboardResponseStream) = self.client.invokeWorkload()

            // Get the observer for this specific endpoint
            let observer = self.nodeManager.invokeWorkloadMessageObserver(for: self.client.endpoint)

            // Setup message recording if requested
            let recordingFileHandle: FileHandle?
            if let recordMessagesTo = recordMessagesToOverride ?? configuration.recordMessagesTo {
                Self.logger
                    .info("\(logContext) Will record request messages to \(recordMessagesTo.path, privacy: .public)")
                FileManager.default.createFile(atPath: recordMessagesTo.path(), contents: nil)
                recordingFileHandle = try FileHandle(forWritingTo: recordMessagesTo)
            } else {
                recordingFileHandle = nil
            }

            return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                group.addTask {
                    for await request in requestStream {
                        // Notify observer for this specific endpoint
                        observer?.onRequestToNode(.init(request))

                        // Record message to file if requested
                        if let fileHandle = recordingFileHandle {
                            try fileHandle.write(request.serialized())
                        }
                        cloudboardRequestContinuation.yield(request)
                    }
                    cloudboardRequestContinuation.finish()
                    try? recordingFileHandle?.close()
                    return .requestStreamFinished
                }
                group.addTask {
                    do {
                        for try await cloudboardResponse in cloudboardResponseStream {
                            // Notify observer for this specific endpoint
                            observer?.onResponseFromNode(.init(cloudboardResponse))

                            responseContinuation.yield(cloudboardResponse)
                        }
                        responseContinuation.finish()
                    } catch {
                        responseContinuation.finish(throwing: error)
                    }
                    return .responseStreamFinished
                }
                group.addTask {
                    do {
                        let result = try await handler(session)
                        Self.logger.log("\(logContext) invokeWorkloadFullControl handler finished")
                        return .handlerFinished(result)
                    } catch {
                        Self.logger.error("\(logContext) invokeWorkloadFullControl response handler failed: \(error)")
                        return .handlerError(error)
                    }
                }

                while let taskResult = try await group.next() {
                    switch taskResult {
                    case .handlerFinished(let result):
                        Self.logger.log("\(logContext) invokeWorkloadFullControl handler finished")
                        group.cancelAll()
                        return result
                    case .handlerError(let error):
                        Self.logger.error("\(logContext) invokeWorkloadFullControl handler failed: \(error)")
                        group.cancelAll()
                        throw error
                    case .requestStreamFinished:
                        Self.logger.info("\(logContext) invokeWorkloadFullControl request stream finished")
                    case .responseStreamFinished:
                        Self.logger.info("\(logContext) invokeWorkloadFullControl response stream finished")
                    }
                }

                throw LocalCloudBoardClientError
                    .internalError("Unexpectedly reached end of invokeWorkload without result")
            }
        }

        func requestNack<ReturnType: Sendable>(
            context: InvokeWorkloadRequestContext,
            configuration: InvokeWorkloadConfiguration,
            recordMessagesTo: URL? = nil,
            responseStreamProcessor: @Sendable @escaping (AsyncThrowingStream<FinalizableChunk, Error>) async throws
                -> ReturnType
        ) async throws -> ReturnType {
            let logContext = LogContext(
                requestID: context.requestID,
                endpoint: self.client.endpoint.hostAndPort,
                nodeType: (self.client.endpoint as! any InternalAppEndpoint).appType
            )

            return try await self.invokeWorkloadFullControl(
                context: context,
                configuration: configuration,
                recordMessagesToOverride: recordMessagesTo
            ) { invokeWorkloadSession in
                // Send setup
                Self.logger.info("\(logContext) Sending setup for NACK request")
                invokeWorkloadSession.send(.makeSetup())

                // Request nack
                let dekInfo = context.encapsulatedDataEncryptionKey
                invokeWorkloadSession.send(
                    .makeParameters(
                        decryptionKey: .makeDecryptionKey(keyID: dekInfo.keyID, key: dekInfo.dataEncryptionKey),
                        requestID: context.requestID,
                        metadata: context.workloadMetadata,
                        requestBypassed: true,
                        requestNack: true
                    )
                )
                // NACK requests have no further chunks to send, so finish the request stream immediately.
                // This replicates the behaviour of ROPES which closes the request stream after sending
                // setup + parameters for NACK requests.
                invokeWorkloadSession.finishSending()

                let (responseStream, responseContinuation) = AsyncThrowingStream<FinalizableChunk, Error>.makeStream()

                return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                    // Process and forward InvokeWorkloadResponse responseChunk messages
                    group.addTask {
                        do {
                            for try await invokeWorkloadResponse in invokeWorkloadSession.responseStream {
                                guard let invokeWorkloadResponseType = invokeWorkloadResponse.type else {
                                    throw PCCGatewayError.unexpectedInvokeWorkloadResponseMessage
                                }
                                switch invokeWorkloadResponseType {
                                case .setupAck(let setupAck):
                                    Self.logger.info("\(logContext) Received setupAck \(setupAck.textFormatString())")
                                case .responseChunk(let chunk):
                                    Self.logger.info(
                                        "\(logContext) Received response chunk of \(chunk.encryptedPayload.count) bytes"
                                    )
                                    responseContinuation.yield(.init(
                                        data: chunk.encryptedPayload,
                                        isFinal: chunk.isFinal
                                    ))
                                case .invokeProxyInitiate:
                                    Self.logger
                                        .error("\(logContext) Received invokeProxyInitiate message for NACK request")
                                    throw InvokeWorkloadExecutorError.receivedInvokeProxyInitiateForNackRequest
                                case .proxyWorkerError:
                                    Self.logger
                                        .error("\(logContext) Received ProxyWorkerError message for NACK request")
                                    throw InvokeWorkloadExecutorError.receivedProxyWorkerErrorForNackRequest
                                case .requestExecutionError(let error):
                                    Self.logger.error(
                                        "\(logContext) Received request execution error from \(String(describing: error.source)) with code \(error.errorCode) \(error.errorMessage)"
                                    )
                                    throw InvokeWorkloadExecutorError.requestExecutionError(
                                        source: String(describing: error.source),
                                        code: error.errorCode,
                                        message: error.errorMessage
                                    )
                                }
                            }
                            responseContinuation.finish()
                        } catch {
                            responseContinuation.finish(throwing: error)
                        }

                        return .responseStreamFinished
                    }

                    group.addTask {
                        do {
                            return try await .handlerFinished(responseStreamProcessor(responseStream))
                        } catch {
                            return .handlerError(error)
                        }
                    }

                    while let taskResult = try await group.next() {
                        switch taskResult {
                        case .handlerFinished(let result):
                            Self.logger.error("\(logContext) NACK response stream processor finished")
                            group.cancelAll()
                            return result
                        case .handlerError(let error):
                            Self.logger.error("\(logContext) NACK response stream processor failed: \(error)")
                            group.cancelAll()
                            throw error
                        case .responseStreamFinished:
                            Self.logger.info("\(logContext) NACK response stream finished")
                        case .requestStreamFinished:
                            // No request stream, ignore
                            ()
                        }
                    }

                    throw LocalCloudBoardClientError
                        .internalError("Unexpectedly reached end of requestNack task group without result")
                }
            }
        }
    }
}
