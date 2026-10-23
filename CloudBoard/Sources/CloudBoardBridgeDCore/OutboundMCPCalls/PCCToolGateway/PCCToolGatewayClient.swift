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

import struct AppleCertificates.PolicyAPRN
import CloudBoardCommon
internal import CloudBoardDomain
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import InternalSwiftProtobuf
import Logging
import NIOCore
import NIOTLS
import NIOTransportServices
import os
import Synchronization
import Tracing

final class PCCToolGatewayClient: PCCToolGatewayClientProtocol {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PCCToolGatewayClient"
    )

    private static let tracingLogger = Logger(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "PCCToolGatewayClient"
    )

    private static let grpcBackgroundActivityLogger = Logging.Logger(
        osLogSubsystem: "com.apple.cloudos.cloudboard",
        osLogCategory: "PCCToolGatewayClient",
        domain: "BackgroundActivity"
    )

    private static let grpcClientLogger = Logging.Logger(
        osLogSubsystem: "com.apple.cloudos.cloudboard",
        osLogCategory: "PCCToolGatewayClient",
        domain: "GRPC"
    )

    private let grpcClient: Proto_PCCToolGateway_PccToolGatewayAsyncClientProtocol
    private let nodeInfo: NodeInfo
    private let metricsSystem: MetricsSystem
    private let requestTimeout: Duration

    init(
        eventLoopGroup: NIOTSEventLoopGroup,
        nodeInfo: NodeInfo,
        targetHost: String,
        targetPort: Int,
        tlsConfig: GRPCClientConfiguration.TLSConfiguration,
        backOffConfig: GRPCClientConfiguration.ConnectionBackoff,
        idleTimeout: TimeAmount,
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        targetPolicyAPRNs: [PolicyAPRN]?,
        metricsSystem: MetricsSystem,
    ) throws {
        Self.logger.log("""
        message=Preparing PCC tool gateway client"
        target=\(targetHost + ":" + String(targetPort), privacy: .public)
        tls=\(String(describing: tlsConfig), privacy: .public)
        """)

        self.nodeInfo = nodeInfo
        self.metricsSystem = metricsSystem

        let resolvedIdentityCallBack = tlsConfig.enablemTLS ? identityCallback : nil

        let tlsConfiguration: ClientTLSConfiguration
        if tlsConfig.enable {
            let serverVerification: GRPCTLSConfiguration.ServerVerification?
            if let policyAPRNs = targetPolicyAPRNs, policyAPRNs.count > 0 {
                serverVerification = GRPCTLSConfiguration.policyAPRNServerVerification(
                    expectedPolicyAPRNs: policyAPRNs,
                    metricsSystem: self.metricsSystem
                )
            } else {
                Self.logger.warning("Missing policyAPRNs, disabling server certificate validation")
                serverVerification = nil
            }
            tlsConfiguration = ClientTLSConfiguration(
                tlsConfig,
                identityCallback: resolvedIdentityCallBack,
                serverVerification: serverVerification
            )
        } else {
            tlsConfiguration = ClientTLSConfiguration(
                nil,
                identityCallback: resolvedIdentityCallBack
            )
        }

        do {
            let channel = try GRPCChannelPool.with(
                target: .hostAndPort(targetHost, targetPort),
                transportSecurity: .init(tlsConfiguration),
                eventLoopGroup: eventLoopGroup
            ) { gRPCConfig in
                gRPCConfig.idleTimeout = idleTimeout
                gRPCConfig.backgroundActivityLogger = Self.grpcBackgroundActivityLogger
                gRPCConfig.connectionBackoff = .init(from: backOffConfig)
            }
            self.grpcClient = Proto_PCCToolGateway_PccToolGatewayAsyncClient(
                channel: channel,
                defaultCallOptions: CallOptions(logger: Self.grpcClientLogger)
            )
            self.requestTimeout = MCPClient.defaultTimeout
        } catch {
            Self.logger.log("""
            message=Failed to initialize PCC tool gateway client
            target=\(targetHost + ":" + String(targetPort), privacy: .public)
            tls=\(String(describing: tlsConfig), privacy: .public)
            error=\(String(reportable: error), privacy: .public)
            """)
            throw error
        }
    }

    // Test-only initializer that accepts a mock gRPC client
    init(
        grpcClient: Proto_PCCToolGateway_PccToolGatewayAsyncClientProtocol,
        nodeInfo: NodeInfo,
        metricsSystem: MetricsSystem,
        requestTimeout: Duration = MCPClient.defaultTimeout
    ) {
        self.grpcClient = grpcClient
        self.nodeInfo = nodeInfo
        self.metricsSystem = metricsSystem
        self.requestTimeout = requestTimeout
    }

    public func invokeTool(
        request: PCCToolInvocationRequest,
        span: BridgeRequestSummaryTracer.Span
    ) async throws -> PCCToolInvocationResponse {
        // This does not yet support cancellation
        // If this is cancelled, the ongoing request should be cancelled too. Cancellation should be propagated all the
        // way from cloud app to PCCToolGatewayClient.
        span.outboundCallRequestID = request.traceContext.toolInvocationID
        let spanID = span.spanID
        PCCToolGatewayCheckpoint(
            spanID: spanID,
            operationName: "invoke_tool_started",
            message: "Received invokeTool request",
            request: request
        ).log(to: Self.tracingLogger, level: .default)

        let callStart = ContinuousClock.now
        do {
            let result = try await self.toolCallHandler(
                spanID: spanID,
                toolInvocationRequest: request
            )
            let duration = ContinuousClock.now - callStart

            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "invoke_tool_succeeded",
                message: "Completed invokeTool request",
                request: request
            ).log(to: Self.tracingLogger, level: .default)

            self.emitMetrics(
                request: request,
                metricResult: .init(from: result),
                duration: duration
            )
            return result
        } catch {
            let duration = ContinuousClock.now - callStart
            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "invoke_tool_failed",
                message: "Error making invokeTool request",
                error: error,
                request: request
            ).log(to: Self.tracingLogger, level: .error)

            if let err = error as? (any RequestExecutionErrorProtocol) {
                span.recordError(error, attributes: .init(), at: DefaultTracerClock.now)
                self.emitMetrics(
                    request: request,
                    metricResult: .failure,
                    duration: duration
                )
                return PCCToolInvocationResponse.failure(err.staticStringRepresentation.description)
            }

            self.emitMetrics(
                request: request,
                metricResult: .unexpectedError,
                duration: duration
            )
            throw error
        }
    }

    private func emitMetrics(
        request: PCCToolInvocationRequest,
        metricResult: Metrics.ToolCall.ResultValue,
        duration: Duration
    ) {
        self.metricsSystem.emit(Metrics.ToolCall.TotalCounter(
            action: .increment,
            result: metricResult,
            serverID: request.serverID,
            tool: request.tool
        ))
        self.metricsSystem.emit(Metrics.ToolCall.DurationHistogram(
            duration: duration,
            result: metricResult,
            serverID: request.serverID,
            tool: request.tool
        ))
    }

    public func shutdown() async throws {
        // Close the gRPC channel
        try await self.grpcClient.channel.close().get()
    }

    enum TaskCompletionStatus {
        case response(PCCToolInvocationResponse)
        case taskEnded
    }

    /// For each new Invoke tool request
    /// create new MCPTransportCall per request and start 3 processes
    /// - process that makes calls with MCP Client
    /// - process that reads ToolGateway request coming from Transport and forwards it to GRPC server
    /// - process that receives GRPC responses and send it to MCP client, MCP client parses the data and returns to the
    /// caller.
    private func toolCallHandler(
        spanID: UInt64,
        toolInvocationRequest: PCCToolInvocationRequest,
    ) async throws -> PCCToolInvocationResponse {
        PCCToolGatewayCheckpoint(
            spanID: spanID,
            operationName: "creating_mcp_transport_call",
            message: "Creating MCP transport call",
            request: toolInvocationRequest
        ).log(to: Self.tracingLogger, level: .default)

        let callOptions = self.generateCallOptions(
            requestId: toolInvocationRequest.traceContext.toolInvocationID
        )
        let mcpTransportCall = self.grpcClient.makeCreateMcpTransportCall(callOptions: callOptions)

        do {
            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "successfully_created_mcp_transport",
                message: "Successfully created MCP transport",
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .default)

            let gRPCRequestStream = mcpTransportCall.requestStream
            let gRPCResponseStream = mcpTransportCall.responseStream

            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "creating_mcp_session",
                message: "Creating MCP session",
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .default)

            let toolCallResponse = try await withThrowingTaskGroup(of: TaskCompletionStatus?.self) { mcpSessionGroup in
                let (mcpRequestStream, mcpRequestStreamContinuation) = AsyncStream<MCPTransportRequest>
                    .makeStream()
                let (mcpResponseStream, mcpResponseStreamContinuation) = AsyncThrowingStream<
                    Data,
                    Swift.Error
                >.makeStream()

                let transport = PCCToolGatewayTransport(
                    spanID: spanID,
                    traceContext: toolInvocationRequest.traceContext,
                    mcpRequestStreamContinuation: mcpRequestStreamContinuation,
                    mcpResponseStream: mcpResponseStream
                )

                // Send tool call request via MCP Client
                mcpSessionGroup.addTask { @Sendable in
                    let mcpCallResponse = try await self.makeMCPCall(
                        spanID: spanID,
                        toolInvocationRequest: toolInvocationRequest,
                        transport: transport
                    )
                    return .response(mcpCallResponse)
                }

                // Read message from transport and forward them to GRPC server
                mcpSessionGroup.addTask {
                    try await self.mcpRequestStreamHandler(
                        spanID: spanID,
                        toolInvocationRequest: toolInvocationRequest,
                        mcpRequestStream: mcpRequestStream,
                        gRPCRequestStream: gRPCRequestStream
                    )
                    return .taskEnded
                }

                // Read message from GRPC server and forward them to MCP client
                mcpSessionGroup.addTask {
                    try await self.gRPCResponseStreamHandler(
                        spanID: spanID,
                        toolInvocationRequest: toolInvocationRequest,
                        gRPCResponseStream: gRPCResponseStream,
                        mcpResponseStreamContinuation: mcpResponseStreamContinuation,
                        transport: transport
                    )
                    return .taskEnded
                }

                var toolInvocationResponse: PCCToolInvocationResponse?
                do {
                    for try await result in mcpSessionGroup {
                        switch result {
                        case .response(let response):
                            toolInvocationResponse = response
                        case .taskEnded, .none:
                            ()
                        }
                    }
                } catch {
                    mcpSessionGroup.cancelAll()
                    throw error
                }

                if let toolInvocationResponse {
                    return toolInvocationResponse
                }
                throw PCCToolGatewayClientError.receivedNoResponse
            }

            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "waiting_for_mcp_transport_call_status",
                message: "CreateMCPTransportCall - waiting for status",
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .default)

            let status = await mcpTransportCall.status

            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "mcp_transport_call_status_received",
                message: "CreateMCPTransportCall - status received",
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .default)

            guard status.isOk else {
                throw PCCToolGatewayClientError.grpc(status)
            }

            return toolCallResponse
        } catch {
            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "error_processing_tool_gateway_request",
                message: "Failed to process toolGateway request",
                error: error,
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .error)
            throw error
        }
    }

    private func mcpRequestStreamHandler(
        spanID: UInt64,
        toolInvocationRequest: PCCToolInvocationRequest,
        mcpRequestStream: AsyncStream<MCPTransportRequest>,
        gRPCRequestStream: GRPCAsyncRequestStreamWriter<Proto_PCCToolGateway_CreateMcpTransportRequest>
    ) async throws {
        defer {
            gRPCRequestStream.finish()

            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "mcp_request_stream_handler_finished",
                message: "Finished MCP request stream handler task",
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .default)
        }

        PCCToolGatewayCheckpoint(
            spanID: spanID,
            operationName: "adding_mcp_request_stream_handler",
            message: "Adding MCP request stream handler task",
            request: toolInvocationRequest
        ).log(to: Self.tracingLogger, level: .default)

        do {
            for await request in mcpRequestStream {
                switch request {
                case .connect:
                    PCCToolGatewayCheckpoint(
                        spanID: spanID,
                        operationName: "connecting_to_mcp_server",
                        message: "Connecting to MCP server",
                        request: toolInvocationRequest
                    ).log(to: Self.tracingLogger, level: .default)
                    try await gRPCRequestStream.send(.with {
                        $0.request = .connect(.with {
                            $0.serverID = toolInvocationRequest.serverID
                            $0.requestID = toolInvocationRequest.traceContext.serverRequestID
                            $0.traceContext = .with {
                                $0.spanID = toolInvocationRequest.traceContext.spanID
                                $0.traceID = .init(from: toolInvocationRequest.traceContext.traceID)
                            }
                            $0.tenantInfo = .with {
                                $0.bundleID = toolInvocationRequest.clientRequestMetadata.bundleID
                                $0.featureID = toolInvocationRequest.clientRequestMetadata.featureID
                                $0.clientInfo = toolInvocationRequest.clientRequestMetadata.clientInfo
                                $0.automatedDeviceGroup = toolInvocationRequest.clientRequestMetadata
                                    .automatedDeviceGroup
                            }
                            $0.serverCloudosVersion = self.nodeInfo.cloudOSBuildVersion ?? ""
                        })
                    })
                case .data(jsonRPC: let jsonRPCMessage):
                    PCCToolGatewayCheckpoint(
                        spanID: spanID,
                        operationName: "sending_json_rpc_message_to_mcp_server",
                        message: "Sending JSON rpc message to MCP server",
                        request: toolInvocationRequest
                    ).log(to: Self.tracingLogger, level: .default)
                    try await gRPCRequestStream.send(.with {
                        $0.request = .requestBody(jsonRPCMessage)
                    })
                }
            }
        } catch {
            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "mcp_request_stream_handler_error",
                message: "Error in MCP request stream handler",
                error: error,
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .error)
            throw error
        }
    }

    private func generateCallOptions(requestId: String) -> CallOptions {
        var callOptions = CallOptions()
        callOptions.requestIDHeader = "Apple-Request-UUID"
        callOptions.requestIDProvider = .userDefined(requestId)
        return callOptions
    }

    private func gRPCResponseStreamHandler(
        spanID: UInt64,
        toolInvocationRequest: PCCToolInvocationRequest,
        gRPCResponseStream: GRPCAsyncResponseStream<Proto_PCCToolGateway_CreateMcpTransportResponse>,
        mcpResponseStreamContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation,
        transport: PCCToolGatewayTransport
    ) async throws {
        defer {
            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "grpc_response_stream_handler_finished",
                message: "Finished GRPC response stream handler",
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .default)
        }

        PCCToolGatewayCheckpoint(
            spanID: spanID,
            operationName: "grpc_response_stream_handler_added",
            message: "Adding GRPC response stream handler",
            request: toolInvocationRequest
        ).log(to: Self.tracingLogger, level: .default)

        do {
            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "waiting_for_grpc_response",
                message: "Waiting for gRCP responses",
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .default)

            for try await gRPCResponse in gRPCResponseStream {
                switch gRPCResponse.response {
                case .connected:
                    PCCToolGatewayCheckpoint(
                        spanID: spanID,
                        operationName: "connected_to_mcp_server",
                        message: "Connected to MCP server",
                        request: toolInvocationRequest
                    ).log(to: Self.tracingLogger, level: .default)
                    try await transport.setClientConnectedState()

                case .json(let jsonRPCMessage):
                    PCCToolGatewayCheckpoint(
                        spanID: spanID,
                        operationName: "received_mcp_response",
                        message: "Received MCP response",
                        request: toolInvocationRequest,
                    ).log(to: Self.tracingLogger, level: .default)
                    mcpResponseStreamContinuation.yield(Data(jsonRPCMessage.utf8))

                case .none:
                    throw PCCToolGatewayClientError.unexpectedResponse
                }
            }
            mcpResponseStreamContinuation.finish()
        } catch {
            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "grpc_response_stream_handler_error",
                message: "Error in GRPC response stream handler",
                error: error,
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .error)
            await transport.disconnect()
            mcpResponseStreamContinuation.finish(throwing: error)
            throw error
        }
    }

    private func makeMCPCall(
        spanID: UInt64,
        toolInvocationRequest: PCCToolInvocationRequest,
        transport: PCCToolGatewayTransport
    ) async throws -> PCCToolInvocationResponse {
        defer {
            PCCToolGatewayCheckpoint(
                spanID: spanID,
                operationName: "mcp_call_finished",
                message: "Finished MCP.client task",
                request: toolInvocationRequest
            ).log(to: Self.tracingLogger, level: .default)
        }

        PCCToolGatewayCheckpoint(
            spanID: spanID,
            operationName: "mcp_call_started",
            message: "Making tool call request",
            request: toolInvocationRequest
        ).log(to: Self.tracingLogger, level: .default)

        let (contents, err) = try await MCPClient(
            transport: transport,
            spanID: spanID,
            timeout: self.requestTimeout
        ).makeToolCallRequest(
            request: toolInvocationRequest
        )

        if let err {
            var errorData: PCCToolInvocationArgumentValue?
            if let data = err.data {
                errorData = PCCToolInvocationArgumentValue(from: data)
            }
            return PCCToolInvocationResponse.protocolError(
                .init(
                    code: err.code,
                    message: err.message,
                    data: errorData
                )
            )
        }
        if let contents {
            if let isError = contents.isError, isError {
                if let content = contents.content, content.count > 0,
                   case .text(let message) = content[0] {
                    return PCCToolInvocationResponse.failure(message)
                } else {
                    return PCCToolInvocationResponse.failure("Tool call failed. Error details not available.")
                }
            }
            guard let structuredContent = contents.structuredContent, !structuredContent.isEmpty else {
                return PCCToolInvocationResponse.failure("Empty tool call response received")
            }
            return PCCToolInvocationResponse.success(.init(
                contents: contents.content?.map { .init(from: $0) } ?? [],
                structuredContent: structuredContent
            ))
        }
        throw PCCToolGatewayClientError.receivedNoResponse
    }
}

extension GRPCChannelPool.Configuration.TransportSecurity {
    init(_ tlsMode: ClientTLSConfiguration) {
        switch tlsMode {
        case .plaintext:
            self = .plaintext
        case .simpleTLS(let config):
            self = .tls(
                .grpcTLSConfiguration(
                    hostnameOverride: config.sniOverride,
                    identityCallback: config.localIdentityCallback,
                    customRoot: config.customRoot,
                    serverVerification: config.serverVerification
                )
            )
        }
    }
}

extension MCPAnyCodable {
    init(from: CloudBoardDomain.PCCToolInvocationArgumentValue) {
        self = switch from {
        case .null:
            .null
        case .bool(let value):
            .bool(value)
        case .int(let value):
            .int(value)
        case .double(let value):
            .double(value)
        case .string(let value):
            .string(value)
        case .array(let value):
            .array(value.map { MCPAnyCodable(from: $0) })
        case .map(let value):
            .object(value.mapValues { MCPAnyCodable(from: $0) })
        }
    }
}

extension CloudBoardDomain.PCCToolInvocationArgumentValue {
    init(from: MCPAnyCodable) {
        self = switch from {
        case .null:
            .null
        case .bool(let value):
            .bool(value)
        case .int(let value):
            .int(value)
        case .double(let value):
            .double(value)
        case .string(let value):
            .string(value)
        case .array(let value):
            .array(value.map { CloudBoardDomain.PCCToolInvocationArgumentValue(from: $0) })
        case .object(let value):
            .map(value.mapValues { CloudBoardDomain.PCCToolInvocationArgumentValue(from: $0) })
        }
    }
}

extension CloudBoardDomain.PCCToolInvocationResponseContent {
    init(from: MCPContent) {
        self = switch from {
        case .text(let text):
            .text(text)
        case .image(data: let data, mimeType: let mimeType, metadata: let metadata):
            .image(data: data, mimeType: mimeType, metadata: metadata)
        case .audio(data: let data, mimeType: let mimeType):
            .audio(data: data, mimeType: mimeType)
        case .resource(uri: let uri, mimeType: let mimeType, text: let text):
            .resource(uri: uri, mimeType: mimeType, text: text)
        }
    }
}

extension Com_Apple_Cloudboard_Api_V1_UUID {
    init(from uuid: UUID) {
        // big-endian conversion
        self = Com_Apple_Cloudboard_Api_V1_UUID()
        let b = uuid.uuid
        self.mostSigBits = (UInt64(b.0) << 56) | (UInt64(b.1) << 48) | (UInt64(b.2) << 40) | (UInt64(b.3) << 32)
            | (UInt64(b.4) << 24) | (UInt64(b.5) << 16) | (UInt64(b.6) << 8) | UInt64(b.7)
        self.leastSigBits = (UInt64(b.8) << 56) | (UInt64(b.9) << 48) | (UInt64(b.10) << 40) | (UInt64(b.11) << 32)
            | (UInt64(b.12) << 24) | (UInt64(b.13) << 16) | (UInt64(b.14) << 8) | UInt64(b.15)
    }
}

extension Proto_PCCToolGateway_UUID {
    init(from uuid: UUID) {
        // big-endian conversion
        self = Proto_PCCToolGateway_UUID()
        let b = uuid.uuid
        self.mostSigBits = (UInt64(b.0) << 56) | (UInt64(b.1) << 48) | (UInt64(b.2) << 40) | (UInt64(b.3) << 32)
            | (UInt64(b.4) << 24) | (UInt64(b.5) << 16) | (UInt64(b.6) << 8) | UInt64(b.7)
        self.leastSigBits = (UInt64(b.8) << 56) | (UInt64(b.9) << 48) | (UInt64(b.10) << 40) | (UInt64(b.11) << 32)
            | (UInt64(b.12) << 24) | (UInt64(b.13) << 16) | (UInt64(b.14) << 8) | UInt64(b.15)
    }
}

extension Metrics.ToolCall.ResultValue {
    init(from response: PCCToolInvocationResponse) {
        self = switch response {
        case .success: .success
        case .failure: .failure
        case .protocolError: .protocolError
        }
    }
}
