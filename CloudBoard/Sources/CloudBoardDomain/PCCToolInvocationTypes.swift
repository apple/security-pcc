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
internal import CloudBoardLogging
package import CloudBoardAsyncXPC

package enum PCCToolInvocationArgumentValue: Sendable, Codable, Equatable, Hashable, ByteBufferCodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([PCCToolInvocationArgumentValue])
    case map([String: PCCToolInvocationArgumentValue])

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .null:
            buffer.writeHostInteger(0)
        case .bool(let flag):
            buffer.writeHostInteger(1)
            try flag.encode(to: &buffer)
        case .int(let value):
            buffer.writeHostInteger(2)
            buffer.writeHostInteger(value)
        case .double(let value):
            buffer.writeHostInteger(3)
            try value.encode(to: &buffer)
        case .string(let value):
            buffer.writeHostInteger(4)
            try value.encode(to: &buffer)
        case .array(let values):
            buffer.writeHostInteger(5)
            try values.encode(to: &buffer)
        case .map(let values):
            buffer.writeHostInteger(6)
            try values.encode(to: &buffer)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch rawValue {
        case 0:
            self = .null
        case 1:
            self = try .bool(.init(from: &buffer))
        case 2:
            let value = try buffer.readHostIntegerOrThrow(as: Int.self)
            self = .int(value)
        case 3:
            self = try .double(.init(from: &buffer))
        case 4:
            self = try .string(.init(from: &buffer))
        case 5:
            self = try .array(.init(from: &buffer))
        case 6:
            self = try .map(.init(from: &buffer))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
    }
}

extension PCCToolInvocationArgumentValue {
    enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "null": self = .null
        case "bool": self = try .bool(container.decode(Bool.self, forKey: .value))
        case "int": self = try .int(container.decode(Int.self, forKey: .value))
        case "double": self = try .double(container.decode(Double.self, forKey: .value))
        case "string": self = try .string(container.decode(String.self, forKey: .value))
        case "array": self = try .array(container.decode([PCCToolInvocationArgumentValue].self, forKey: .value))
        case "map": self = try .map(container.decode([String: PCCToolInvocationArgumentValue].self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown type: \(type)"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .null:
            try container.encode("null", forKey: .type)
        case .bool(let value):
            try container.encode("bool", forKey: .type)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode("int", forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode("double", forKey: .type)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode("string", forKey: .type)
            try container.encode(value, forKey: .value)
        case .array(let value):
            try container.encode("array", forKey: .type)
            try container.encode(value, forKey: .value)
        case .map(let value):
            try container.encode("map", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

package enum PCCToolInvocationError: Error, ByteBufferCodable {
    case clientUnavailable
    case noRequestHandlerSet
    case internalError

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .clientUnavailable:
            buffer.writeHostInteger(0)
        case .noRequestHandlerSet:
            buffer.writeHostInteger(1)
        case .internalError:
            buffer.writeHostInteger(2)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch rawValue {
        case 0:
            self = .clientUnavailable
        case 1:
            self = .noRequestHandlerSet
        case 2:
            self = .internalError
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
    }
}

package struct PCCToolInvocationResponseError: Sendable, Equatable, Hashable, ByteBufferCodable {
    package let code: Int
    package let message: String
    package let data: PCCToolInvocationArgumentValue?

    package init(code: Int, message: String, data: PCCToolInvocationArgumentValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        buffer.writeHostInteger(self.code)
        try self.message.encode(to: &buffer)
        try self.data.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.code = try buffer.readHostIntegerOrThrow(as: Int.self)
        self.message = try .init(from: &buffer)
        self.data = try .init(from: &buffer)
    }
}

/// Content within a MCP tool response
package enum PCCToolInvocationResponseContent: Sendable, Codable, Equatable, Hashable, ByteBufferCodable {
    /// Text content
    case text(String)
    /// Image content
    case image(data: Data, mimeType: String, metadata: [String: String]?)
    /// Audio content
    case audio(data: Data, mimeType: String)
    /// Embedded resource content
    case resource(uri: String, mimeType: String, text: String?)

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .text(let text):
            buffer.writeHostInteger(0)
            try text.encode(to: &buffer)
        case .image(let data, let mimeType, let metadata):
            buffer.writeHostInteger(1)
            try data.encode(to: &buffer)
            try mimeType.encode(to: &buffer)
            try metadata.encode(to: &buffer)
        case .audio(let data, let mimeType):
            buffer.writeHostInteger(2)
            try data.encode(to: &buffer)
            try mimeType.encode(to: &buffer)
        case .resource(let uri, let mimeType, let text):
            buffer.writeHostInteger(3)
            try uri.encode(to: &buffer)
            try mimeType.encode(to: &buffer)
            try text.encode(to: &buffer)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch rawValue {
        case 0:
            self = try .text(.init(from: &buffer))
        case 1:
            self = try .image(
                data: .init(from: &buffer),
                mimeType: .init(from: &buffer),
                metadata: .init(from: &buffer)
            )
        case 2:
            self = try .audio(
                data: .init(from: &buffer),
                mimeType: .init(from: &buffer),
            )
        case 3:
            self = try .resource(
                uri: .init(from: &buffer),
                mimeType: .init(from: &buffer),
                text: .init(from: &buffer)
            )
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
    }
}

package struct PCCToolInvocationResponseData: Sendable, Equatable, ByteBufferCodable {
    package let contents: [PCCToolInvocationResponseContent]
    package let structuredContent: [String: ToolInvocationResponseValue]

    package init(
        contents: [PCCToolInvocationResponseContent],
        structuredContent: [String: ToolInvocationResponseValue]
    ) {
        self.contents = contents
        self.structuredContent = structuredContent
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.contents.encode(to: &buffer)
        buffer.writeHostInteger(self.structuredContent.count)
        for (key, value) in self.structuredContent {
            try key.encode(to: &buffer)
            try value.encode(to: &buffer)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.contents = try .init(from: &buffer)
        let count = try buffer.readHostIntegerOrThrow(as: Int.self)
        var dict: [String: ToolInvocationResponseValue] = [:]
        dict.reserveCapacity(count)
        for _ in 0 ..< count {
            let key = try String(from: &buffer)
            dict[key] = try ToolInvocationResponseValue(from: &buffer)
        }
        self.structuredContent = dict
    }
}

package enum PCCToolInvocationResponse: Sendable, Equatable, ByteBufferCodable {
    case success(PCCToolInvocationResponseData)
    case protocolError(PCCToolInvocationResponseError)
    case failure(String)

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .success(let responseData):
            buffer.writeHostInteger(0)
            try responseData.encode(to: &buffer)
        case .protocolError(let err):
            buffer.writeHostInteger(1)
            try err.encode(to: &buffer)
        case .failure(let err):
            buffer.writeHostInteger(2)
            try err.encode(to: &buffer)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch rawValue {
        case 0:
            self = try .success(.init(from: &buffer))
        case 1:
            self = try .protocolError(.init(from: &buffer))
        case 2:
            self = try .failure(.init(from: &buffer))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
    }
}

package struct ClientRequestMetadata: Sendable, Equatable, Hashable, ByteBufferCodable {
    public var bundleID: String
    public var featureID: String
    public var clientInfo: String
    public var automatedDeviceGroup: String

    package init(
        bundleID: String,
        featureID: String,
        clientInfo: String,
        automatedDeviceGroup: String
    ) {
        self.bundleID = bundleID
        self.featureID = featureID
        self.clientInfo = clientInfo
        self.automatedDeviceGroup = automatedDeviceGroup
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.bundleID.encode(to: &buffer)
        try self.featureID.encode(to: &buffer)
        try self.clientInfo.encode(to: &buffer)
        try self.automatedDeviceGroup.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.bundleID = try .init(from: &buffer)
        self.featureID = try .init(from: &buffer)
        self.clientInfo = try .init(from: &buffer)
        self.automatedDeviceGroup = try .init(from: &buffer)
    }
}

package struct PCCToolInvocationRequest: Sendable, Equatable, Hashable, ByteBufferCodable, OutboundCallContextProtocol {
    // the outbound call service name used in REL
    package static let outboundCallServiceName = OutboundCallType.toolCall.rawValue
    // MCP server id
    package var serverID: String
    // Name of the invoked tool
    package var tool: String
    // Tool Invocation request arguments
    package var arguments: [String: PCCToolInvocationArgumentValue]
    // Data required for tracing per Tool Invocation request
    package var traceContext: PCCToolInvocationTraceContext
    package var clientRequestMetadata: ClientRequestMetadata

    // SerializableModel is used to generate outbound call Request Execution Log metadata
    // Provide Coding keys for members that needs to be added to REL
    package struct SerializableModel: Codable, Equatable {
        let serverID: String
        let tool: String
        let arguments: [String: PCCToolInvocationArgumentValue]

        enum CodingKeys: String, CodingKey {
            case serverID = "server_id"
            case tool = "tool_name"
            case arguments
        }
    }

    package func toSerializableModel() -> SerializableModel {
        SerializableModel(
            serverID: self.serverID,
            tool: self.tool,
            arguments: self.arguments
        )
    }

    package init(
        serverID: String,
        tool: String,
        arguments: [String: PCCToolInvocationArgumentValue],
        traceContext: PCCToolInvocationTraceContext,
        clientRequestMetadata: ClientRequestMetadata
    ) {
        self.serverID = serverID
        self.tool = tool
        self.arguments = arguments
        self.traceContext = traceContext
        self.clientRequestMetadata = clientRequestMetadata
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.serverID.encode(to: &buffer)
        try self.tool.encode(to: &buffer)
        try self.arguments.encode(to: &buffer)
        try self.traceContext.encode(to: &buffer)
        try self.clientRequestMetadata.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.serverID = try .init(from: &buffer)
        self.tool = try .init(from: &buffer)
        self.arguments = try .init(from: &buffer)
        self.traceContext = try .init(from: &buffer)
        self.clientRequestMetadata = try .init(from: &buffer)
    }
}

package struct PCCToolInvocationTraceContext: ByteBufferCodable, Sendable, Hashable, Equatable {
    package let toolInvocationID: String
    package let serverRequestID: String
    package let traceID: UUID
    package let spanID: UInt64

    package init(
        toolInvocationID: String,
        serverRequestID: String,
        traceID: UUID,
        spanID: UInt64
    ) {
        self.toolInvocationID = toolInvocationID
        self.serverRequestID = serverRequestID
        self.traceID = traceID
        self.spanID = spanID
    }

    package func encode(to buffer: inout ByteBuffer) throws {
        try self.toolInvocationID.encode(to: &buffer)
        try self.serverRequestID.encode(to: &buffer)
        try self.traceID.encode(to: &buffer)
        try self.spanID.encode(to: &buffer)
    }

    package init(from buffer: inout ByteBuffer) throws {
        self.toolInvocationID = try .init(from: &buffer)
        self.serverRequestID = try .init(from: &buffer)
        self.traceID = try .init(from: &buffer)
        self.spanID = try .init(from: &buffer)
    }
}

package struct PCCToolInvocationMessage: CloudBoardAsyncXPCByteBufferMessage {
    public typealias Success = PCCToolInvocationResponse
    public typealias Failure = PCCToolInvocationError

    package let request: PCCToolInvocationRequest

    package init(request: PCCToolInvocationRequest) {
        self.request = request
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.request.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.request = try .init(from: &buffer)
    }
}
