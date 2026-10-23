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

import CloudBoardCommon
import Foundation
import os
internal import CloudBoardDomain

enum MCPTransportRequest: Sendable, Hashable {
    case connect
    case data(jsonRPC: String)
}

final actor PCCToolGatewayTransport: MCPTransport {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PCCToolGatewayMCPTransport"
    )

    private static let tracingLogger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "PCCToolGatewayMCPTransport"
    )

    enum State: Sendable {
        case initialized
        case connecting
        case connected
        case disconnected
    }

    private var state: State = .initialized
    private let spanID: UInt64
    private let traceContext: PCCToolInvocationTraceContext
    private let mcpRequestStreamContinuation: AsyncStream<MCPTransportRequest>.Continuation
    private let mcpResponseStream: AsyncThrowingStream<Data, Swift.Error>
    private var mcpResponseStreamShared: Bool = false
    private var connectionContinuation: CheckedContinuation<Void, Error>?

    init(
        spanID: UInt64,
        traceContext: PCCToolInvocationTraceContext,
        mcpRequestStreamContinuation: AsyncStream<MCPTransportRequest>.Continuation,
        mcpResponseStream: AsyncThrowingStream<Data, Swift.Error>,
    ) {
        self.spanID = spanID
        self.traceContext = traceContext
        self.mcpRequestStreamContinuation = mcpRequestStreamContinuation
        self.mcpResponseStream = mcpResponseStream
    }

    deinit {
        self.state = .disconnected
        if let connectionContinuation = self.connectionContinuation {
            connectionContinuation.resume(throwing: PCCToolGatewayTransportError.failedToConnect)
            self.connectionContinuation = nil
        }
        self.mcpRequestStreamContinuation.finish()
    }

    // This method is called once
    public func connect() async throws {
        switch self.state {
        case .connecting, .connected:
            PCCToolGatewayTransportCheckpoint(
                spanID: self.spanID,
                traceContext: self.traceContext,
                operationName: "transport_already_connected_or_connecting",
                message: "Transport already connected/connecting"
            ).log(to: Self.tracingLogger, level: .default)
            return
        case .initialized, .disconnected:
            // Continue
            ()
        }

        self.state = .connecting

        PCCToolGatewayTransportCheckpoint(
            spanID: self.spanID,
            traceContext: self.traceContext,
            operationName: "connecting_to_mcp_server",
            message: "Connecting to MCP server"
        ).log(to: Self.tracingLogger, level: .default)

        try await withCheckedThrowingContinuation { continuation in
            self.connectionContinuation = continuation
            self.mcpRequestStreamContinuation.yield(.connect)
        }
    }

    public func setClientConnectedState() async throws {
        self.state = .connected
        self.connectionContinuation?.resume()
        self.connectionContinuation = nil
        PCCToolGatewayTransportCheckpoint(
            spanID: self.spanID,
            traceContext: self.traceContext,
            operationName: "connected_to_mcp_server",
            message: "Connected to MCP server"
        ).log(to: Self.tracingLogger, level: .default)
    }

    public func disconnect() async {
        switch self.state {
        case .connected, .connecting:
            // Continue with disconnection
            break
        case .initialized, .disconnected:
            return
        }

        if let connectionContinuation = self.connectionContinuation {
            connectionContinuation.resume(throwing: PCCToolGatewayTransportError.failedToConnect)
            self.connectionContinuation = nil
        }
        self.state = .disconnected
        self.mcpRequestStreamContinuation.finish()
        PCCToolGatewayTransportCheckpoint(
            spanID: self.spanID,
            traceContext: self.traceContext,
            operationName: "disconnecting_from_mcp_server",
            message: "Disconnecting from MCP server"
        ).log(to: Self.tracingLogger, level: .default)
    }

    public func send(_ encodedJSONRPCMessage: Data) async throws {
        guard case .connected = self.state else {
            PCCToolGatewayTransportCheckpoint(
                spanID: self.spanID,
                traceContext: self.traceContext,
                operationName: "transport_not_connected",
                message: "Transport not connected",
                error: PCCToolGatewayTransportError.notConnected
            ).log(to: Self.tracingLogger, level: .error)
            throw PCCToolGatewayTransportError.notConnected
        }
        guard let jsonRPCMessage = String(data: encodedJSONRPCMessage, encoding: .utf8) else {
            PCCToolGatewayTransportCheckpoint(
                spanID: self.spanID,
                traceContext: self.traceContext,
                operationName: "failed_to_decode_message",
                message: "failed to decode message",
                error: PCCToolGatewayTransportError.failedToDecodeJSONRPCMessage
            ).log(to: Self.tracingLogger, level: .error)
            throw PCCToolGatewayTransportError.failedToDecodeJSONRPCMessage
        }

        PCCToolGatewayTransportCheckpoint(
            spanID: self.spanID,
            traceContext: self.traceContext,
            operationName: "sending_mcp_message_to_server",
            message: "Sending MCP message to server"
        ).log(to: Self.tracingLogger, level: .default)
        self.mcpRequestStreamContinuation.yield(.data(jsonRPC: jsonRPCMessage))
    }

    public func receive() throws -> AsyncThrowingStream<Data, Swift.Error> {
        guard case .connected = self.state else {
            PCCToolGatewayTransportCheckpoint(
                spanID: self.spanID,
                traceContext: self.traceContext,
                operationName: "transport_not_connected",
                message: "Transport not connected",
                error: PCCToolGatewayTransportError.notConnected
            ).log(to: Self.tracingLogger, level: .error)

            throw PCCToolGatewayTransportError.notConnected
        }

        if !self.mcpResponseStreamShared {
            self.mcpResponseStreamShared = true
            return self.mcpResponseStream
        }

        PCCToolGatewayTransportCheckpoint(
            spanID: self.spanID,
            traceContext: self.traceContext,
            operationName: "mcp_response_stream_already_shared",
            message: "mcp response stream already shared",
            error: PCCToolGatewayTransportError.streamAlreadyShared
        ).log(to: Self.tracingLogger, level: .error)

        throw PCCToolGatewayTransportError.streamAlreadyShared
    }
}
