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

/// Pure JSON-RPC dispatch for the mock tool gateway, decoupled from the gRPC
/// transport so the handshake logic can be exercised without gRPC types.
///
/// Decodes an MCP request body and produces the JSON response string, or `nil`
/// for notifications that warrant no wire reply. ``MockPCCToolGatewayProvider``
/// owns the gRPC stream and delegates each request body here.
struct MCPRequestHandler: Sendable {
    /// Decodes one MCP JSON-RPC request body and produces the JSON response, or
    /// `nil` for notifications that warrant no reply.
    /// - Throws: The request-decode error when a body is neither a valid request
    ///   nor the `notifications/initialized` notification.
    func handleRequestBody(_ message: String) async throws -> String? {
        let data = Data(message.utf8)
        let decodedRequest: MCPRequest
        do {
            decodedRequest = try JSONDecoder().decode(MCPRequest.self, from: data)
        } catch {
            // A notification carries no `id`, so MCPRequest decoding fails; retry
            // as a notification before surfacing the original error.
            let notification = try JSONDecoder().decode(MCPNotificationInitializedRequest.self, from: data)
            switch notification.method {
            case "notifications/initialized":
                return nil
            default:
                throw error
            }
        }

        switch decodedRequest.method {
        case "initialize":
            return try self.initializeResponse(requestId: decodedRequest.id)
        case "notifications/initialized":
            return nil
        case "tools/call":
            return try self.toolCallResponse(requestId: decodedRequest.id, request: decodedRequest)
        default:
            return try self.genericResponse(requestId: decodedRequest.id)
        }
    }

    private func genericResponse(requestId: String) throws -> String {
        // Encode via JSONEncoder so ids containing quotes or special characters
        // cannot produce malformed JSON.
        struct EmptyResult: Codable, Sendable {}
        let response = MCPResponse(jsonrpc: "2.0", id: requestId, result: EmptyResult())
        return try Self.encodeToString(response)
    }

    private func initializeResponse(requestId: String) throws -> String {
        let result = InitializeResponse(
            protocolVersion: "2026-01-19",
            capabilities: ServerCapabilities(tools: ToolsCapability()),
            serverInfo: ServerInfo(name: "MockToolGateway", version: "0.0.1")
        )
        let response = MCPResponse(jsonrpc: "2.0", id: requestId, result: result)
        return try Self.encodeToString(response)
    }

    private func toolCallResponse(requestId: String, request: MCPRequest) throws -> String {
        let toolName = request.params?.name ?? "unknown-tool"
        let contents = MCPContents(
            content: [.text("Mock response for tool: \(toolName)")],
            structuredContent: ["result": .string("Mock response for tool: \(toolName)")]
        )
        let response = MCPResponse(jsonrpc: "2.0", id: requestId, result: contents)
        return try Self.encodeToString(response)
    }

    private static func encodeToString(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
