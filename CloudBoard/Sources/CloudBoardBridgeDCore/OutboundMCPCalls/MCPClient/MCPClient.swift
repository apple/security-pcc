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
import os
internal import CloudBoardDomain
import CloudBoardCommon
import CloudBoardLogging
import Synchronization

/// Minimal MCP client to make single tool invocation requests.
final class MCPClient: Sendable {
    // Supported MCP message
    private static let toolCallRequestName = "tools/call"
    private static let initializationRequestName = "initialize"
    private static let initializedNotificationName = "notifications/initialized"

    static let defaultTimeout: Duration = .seconds(30)

    private static let clientName: String = "CloudBoardMCP"
    private static let clientVersion: String = "1.0"
    private static let protocolVersion: String = "2025-11-25"

    /// The connection to the server
    private let connection: any MCPTransport
    private let spanID: UInt64
    private let timeout: Duration

    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "MCPClient"
    )

    private static let tracingLogger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "MCPClient"
    )

    init(transport: any MCPTransport, spanID: UInt64, timeout: Duration = MCPClient.defaultTimeout) {
        self.spanID = spanID
        self.connection = transport
        self.timeout = timeout
    }

    ///  Connects to the MCP server, initializes the connection, makes the tool invocation, and disconnects again.
    public func makeToolCallRequest(
        request: PCCToolInvocationRequest
    ) async throws -> (MCPContents?, MCPError?) {
        do {
            return try await withTimeout(self.timeout) {
                MCPClientCheckpoint(
                    spanID: self.spanID,
                    operationName: "connecting_to_mcp_server",
                    message: "Connecting to MCP server",
                    traceContext: request.traceContext
                ).log(to: Self.tracingLogger, level: .debug)
                try await self.connection.connect()

                /// For simplicity, and to avoid the round-trip time, we do not wait for a response to the initialize
                /// request
                /// but optimistically assume that it will succeed and send the request right away.
                try await self.sendInitRequest(to: self.connection)
                try await self.sendInitializedNotification(to: self.connection)

                var responseIterator = try await self.connection.receive().makeAsyncIterator()
                guard let firstResponse = try await responseIterator.next() else {
                    throw MCPClientError.unexpectedEndOfResponseStream
                }

                /// First response is expected to be the initialization response. Ensure that it is, and that
                /// initialization was successful.
                let initializedResponse: MCPResponse<InitializeResponse>
                do {
                    initializedResponse = try JSONDecoder().decode(
                        MCPResponse<InitializeResponse>.self,
                        from: firstResponse
                    )
                } catch {
                    MCPClientCheckpoint(
                        spanID: self.spanID,
                        operationName: "initialization_response_decoding_error",
                        message: "initialization response decoding error",
                        error: error,
                        traceContext: request.traceContext,
                    ).log(to: Self.tracingLogger, level: .error)
                    throw MCPClientError.dataDecodingError
                }

                if let error = initializedResponse.error {
                    MCPClientCheckpoint(
                        spanID: self.spanID,
                        operationName: "failed_to_initialize_mcp_connection",
                        message: "Failed to initialize MCP connection",
                        error: error,
                        traceContext: request.traceContext,
                    ).log(to: Self.tracingLogger, level: .error)

                    throw MCPClientError.errorInitalizingClient
                }

                try await self.sendToolRequest(request, to: self.connection)

                guard let secondResponse = try await responseIterator.next() else {
                    throw MCPClientError.unexpectedEndOfResponseStream
                }

                let toolResponse: MCPResponse<MCPContents>
                do {
                    toolResponse = try JSONDecoder().decode(MCPResponse<MCPContents>.self, from: secondResponse)
                } catch {
                    MCPClientCheckpoint(
                        spanID: self.spanID,
                        operationName: "tool_call_response_decoding_error",
                        message: "tool call response decoding error",
                        error: error,
                        traceContext: request.traceContext,
                    ).log(to: Self.tracingLogger, level: .error)
                    throw MCPClientError.dataDecodingError
                }

                MCPClientCheckpoint(
                    spanID: self.spanID,
                    operationName: "disconnecting_from_mcp_server",
                    message: "Disconnecting from MCP server",
                    traceContext: request.traceContext
                ).log(to: Self.tracingLogger, level: .debug)
                await self.connection.disconnect()

                MCPClientCheckpoint(
                    spanID: self.spanID,
                    operationName: "disconnected_from_mcp_server",
                    message: "Disconnected from MCP server",
                    traceContext: request.traceContext,
                ).log(to: Self.tracingLogger, level: .debug)

                return (toolResponse.result, toolResponse.error)
            }
        } catch {
            MCPClientCheckpoint(
                spanID: self.spanID,
                operationName: "failed_to_make_tool_call",
                message: "Failed to make tool call",
                error: error,
                traceContext: request.traceContext
            ).log(to: Self.tracingLogger, level: .error)
            await self.connection.disconnect()
            throw error
        }
    }

    private func sendInitRequest(to connection: any MCPTransport) async throws {
        let initRequest = MCPRequest(
            id: UUID().uuidString,
            method: Self.initializationRequestName,
            params: [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string(Self.clientName),
                    "version": .string(Self.clientVersion),
                ]),
            ]
        )
        try await connection.send(self.encodeData(initRequest))
    }

    private func sendInitializedNotification(to connection: any MCPTransport) async throws {
        let initializedNotification = MCPNotificationInitializedRequest(method: Self.initializedNotificationName)
        try await connection.send(self.encodeData(initializedNotification))
    }

    private func sendToolRequest(_ request: PCCToolInvocationRequest, to connection: any MCPTransport) async throws {
        MCPClientCheckpoint(
            spanID: self.spanID,
            operationName: "send_tool_call_request",
            message: "Sending Tool Call request",
            traceContext: request.traceContext
        ).log(to: Self.tracingLogger, level: .default)
        let toolRequest = MCPRequest(
            id: request.traceContext.toolInvocationID,
            method: Self.toolCallRequestName,
            params: [
                "name": .string(request.tool),
                "arguments": .object(request.arguments.mapValues { .init(from: $0) }),
                "_meta": .object([
                    "toolInvocationId": .string(request.traceContext.toolInvocationID),
                ]),
            ]
        )
        try await connection.send(self.encodeData(toolRequest))
    }

    private func encodeData(_ request: MCPRequest) async throws -> Data {
        do {
            return try JSONEncoder().encode(request)
        } catch {
            Self.logger.error("Error encoding data \(error, privacy: .public))")
            throw MCPClientError.dataEncodingError
        }
    }

    private func encodeData(_ request: MCPNotificationInitializedRequest) throws -> Data {
        do {
            return try JSONEncoder().encode(request)
        } catch {
            Self.logger.error("Error encoding data \(error, privacy: .public))")
            throw MCPClientError.dataEncodingError
        }
    }
}

struct MCPClientCheckpoint: RequestCheckpoint {
    var requestID: String?
    var toolGatewayRequestId: String
    var traceID: UUID
    var spanID: UInt64
    var operationName: StaticString
    var serviceName: StaticString = "cb_bridged"
    var namespace: StaticString = "cloudboard"
    var error: Error?
    var message: StaticString

    init(
        requestID: String,
        toolGatewayRequestId: String,
        operationName: StaticString,
        message: StaticString,
        error: Error? = nil,
        traceID: UUID,
        spanID: UInt64,
    ) {
        self.requestID = requestID
        self.operationName = operationName
        self.message = message
        self.traceID = traceID
        self.spanID = spanID
        self.error = error
        self.toolGatewayRequestId = toolGatewayRequestId
    }

    init(
        spanID: UInt64,
        operationName: StaticString,
        message: StaticString,
        error: Error? = nil,
        traceContext: PCCToolInvocationTraceContext
    ) {
        self.init(
            requestID: traceContext.serverRequestID,
            toolGatewayRequestId: traceContext.toolInvocationID,
            operationName: operationName,
            message: message,
            error: error,
            traceID: traceContext.traceID,
            spanID: spanID,
        )
    }

    func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        toolGatewayRequestId.uuid=\(self.toolGatewayRequestId, privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
        tracing.trace_id=\(self.traceID.traceIDString, privacy: .public)
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

    func log(to logger: Logger, level: OSLogType = .default, name: String) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        toolGatewayRequestId.uuid=\(self.toolGatewayRequestId, privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
        tracing.trace_id=\(self.traceID.traceIDString, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        toolName=\(name, privacy: .public)
        """)
    }
}

private struct TimeoutError: Error {}

/// Executes the given `operation` up to `maxDuration` seconds and cancels it if it exceeds the timeout.
/// - Parameters:
///   - maxDuration: max execution duration in seconds of `operation`
///   - operation: the task to start and cancel after `maxDuration` seconds
/// - Returns: the result of `operation`
/// - Throws: if `operation` does not return a result after `maxDuration`
private func withTimeout<Result: Sendable>(
    _ maxDuration: Duration,
    operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    try await withThrowingTaskGroup(of: Result?.self, returning: Swift.Result<Result, any Error>.self) { group in
        // add actual operation
        group.addTask(operation: operation)
        // add watchdog
        group.addTask {
            try? await Task.sleep(for: maxDuration)
            return nil
        }
        // we add two tasks and it is therefore safe to unwrap at least one call to `group.next()`
        let firstResult = try await group.next()!
        // either the operation or the watchdog has finished
        // regardless of which finished first, we need to cancel the second task
        group.cancelAll()

        if let firstResult {
            return .success(firstResult)
        } else {
            return .failure(MCPClientError.requestTimeout)
        }
    }.get()
}
