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
internal import CloudBoardDomain

struct MCPError: Codable, Error, Sendable, Equatable {
    let code: Int
    let message: String
    let data: MCPAnyCodable?

    init(code: Int, message: String, data: MCPAnyCodable?) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// MARK: - MCP Message Protocol

struct MCPRequest: Codable, Equatable, Sendable {
    let jsonrpc: String
    let id: String
    let method: String
    let params: [String: MCPAnyCodable]?

    init(id: String, method: String, params: [String: MCPAnyCodable]?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct MCPNotificationInitializedRequest: Codable, Equatable, Sendable {
    let jsonrpc: String
    let method: String
    let params: [String: MCPAnyCodable]?

    init(method: String) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = [:]
    }
}

struct MCPResponse<T: Codable>: Codable, Sendable where T: Sendable {
    let jsonrpc: String
    let id: String
    let result: T?
    let error: MCPError?

    init(
        jsonrpc: String,
        id: String,
        result: T?,
        error: MCPError?
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

enum MCPAnyCodable: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MCPAnyCodable])
    case object([String: MCPAnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([MCPAnyCodable].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: MCPAnyCodable].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}

/// MCP protocol says.
/// if isError == True, toolContent stores the error message
/// isError == False, we can share response via ToolContent/structuredContent.
///     structuredContent → your application logic (parse, validate, display)
///     content                  → what you inject into the LLM's tool result message
struct MCPContents: Hashable, Codable, Sendable {
    let content: [MCPContent]?
    let structuredContent: [String: ToolInvocationResponseValue]?
    let isError: Bool?

    init(
        content: [MCPContent]? = nil,
        structuredContent: [String: ToolInvocationResponseValue]? = nil,
        isError: Bool? = nil
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }
}

enum MCPContent: Hashable, Codable, Sendable {
    /// Text content
    case text(String)
    /// Image content
    case image(data: Data, mimeType: String, metadata: [String: String]?)
    /// Audio content
    case audio(data: Data, mimeType: String)
    /// Embedded resource content
    case resource(uri: String, mimeType: String, text: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case image
        case resource
        case audio
        case uri
        case mimeType
        case data
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let data = try container.decode(Data.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            let metadata = try container.decodeIfPresent(
                [String: String].self, forKey: .metadata
            )
            self = .image(data: data, mimeType: mimeType, metadata: metadata)
        case "audio":
            let data = try container.decode(Data.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .audio(data: data, mimeType: mimeType)
        case "resource":
            let uri = try container.decode(String.self, forKey: .uri)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            let text = try container.decodeIfPresent(String.self, forKey: .text)
            self = .resource(uri: uri, mimeType: mimeType, text: text)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown tool content type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType, let metadata):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(metadata, forKey: .metadata)
        case .audio(let data, let mimeType):
            try container.encode("audio", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .resource(let uri, let mimeType, let text):
            try container.encode("resource", forKey: .type)
            try container.encode(uri, forKey: .uri)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(text, forKey: .text)
        }
    }
}

// MARK: - Initialization Protocol

struct InitializeRequest: Codable, Sendable {
    let protocolVersion: String
    let capabilities: ClientCapabilities
    let clientInfo: ClientInfo

    init(
        protocolVersion: String,
        capabilities: ClientCapabilities,
        clientInfo: ClientInfo
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
    }
}

struct InitializeResponse: Codable, Sendable, Equatable {
    let protocolVersion: String
    let capabilities: ServerCapabilities
    let serverInfo: ServerInfo
    let instructions: String?

    init(
        protocolVersion: String,
        capabilities: ServerCapabilities,
        serverInfo: ServerInfo,
        instructions: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}

struct ClientInfo: Codable, Sendable, Equatable {
    let name: String
    let version: String

    init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

struct ServerInfo: Codable, Sendable, Equatable {
    let name: String
    let version: String

    init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

struct ClientCapabilities: Codable, Sendable, Equatable {
    let sampling: SamplingCapability?
    let experimental: [String: String]?
    let roots: RootsCapability?

    init(
        sampling: SamplingCapability? = nil,
        experimental: [String: String]? = nil,
        roots: RootsCapability? = nil
    ) {
        self.sampling = sampling
        self.experimental = experimental
        self.roots = roots
    }
}

struct SamplingCapability: Codable, Sendable, Equatable {
    init() {}
}

struct RootsCapability: Codable, Sendable, Equatable {
    let listChanged: Bool?

    init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

struct ServerCapabilities: Codable, Sendable, Equatable {
    let logging: LoggingCapability?
    let tools: ToolsCapability?
    let resources: ResourcesCapability?
    let prompts: PromptsCapability?
    let experimental: [String: String]?

    init(
        logging: LoggingCapability? = nil,
        tools: ToolsCapability? = nil,
        resources: ResourcesCapability? = nil,
        prompts: PromptsCapability? = nil,
        experimental: [String: String]? = nil
    ) {
        self.logging = logging
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.experimental = experimental
    }
}

struct LoggingCapability: Codable, Sendable, Equatable {
    init() {}
}

struct ToolsCapability: Codable, Sendable, Equatable {
    init() {}
}

struct ResourcesCapability: Codable, Sendable, Equatable {
    let subscribe: Bool?

    init(subscribe: Bool? = nil) {
        self.subscribe = subscribe
    }
}

struct PromptsCapability: Codable, Sendable, Equatable {
    init() {}
}
