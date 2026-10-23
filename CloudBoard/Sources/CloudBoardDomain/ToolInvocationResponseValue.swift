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
package import CloudBoardAsyncXPC

public enum ToolInvocationResponseValue: Codable, Sendable, Hashable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ToolInvocationResponseValue])
    case map([String: ToolInvocationResponseValue])

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
            buffer.writeHostInteger(values.count)
            for item in values {
                try item.encode(to: &buffer)
            }
        case .map(let values):
            buffer.writeHostInteger(6)
            buffer.writeHostInteger(values.count)
            for (key, value) in values {
                try key.encode(to: &buffer)
                try value.encode(to: &buffer)
            }
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
            let count = try buffer.readHostIntegerOrThrow(as: Int.self)
            var array: [ToolInvocationResponseValue] = []
            array.reserveCapacity(count)
            for _ in 0 ..< count {
                try array.append(ToolInvocationResponseValue(from: &buffer))
            }
            self = .array(array)
        case 6:
            let count = try buffer.readHostIntegerOrThrow(as: Int.self)
            var dict: [String: ToolInvocationResponseValue] = [:]
            dict.reserveCapacity(count)
            for _ in 0 ..< count {
                let key = try String(from: &buffer)
                dict[key] = try ToolInvocationResponseValue(from: &buffer)
            }
            self = .map(dict)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
    }

    public init(from decoder: Decoder) throws {
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
        } else if let array = try? container.decode([ToolInvocationResponseValue].self) {
            self = .array(array)
        } else if let map = try? container.decode([String: ToolInvocationResponseValue].self) {
            self = .map(map)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .map(let m): try container.encode(m)
        }
    }

    // MARK: - Dictionary-like Access

    /// Subscript access for dictionary keys
    public subscript(key: String) -> ToolInvocationResponseValue? {
        guard case .map(let dict) = self else { return nil }
        return dict[key]
    }

    /// Subscript access for array indices
    public subscript(index: Int) -> ToolInvocationResponseValue? {
        guard case .array(let array) = self else { return nil }
        guard index >= 0, index < array.count else { return nil }
        return array[index]
    }

    /// Check if key exists in map
    public func hasKey(_ key: String) -> Bool {
        guard case .map(let dict) = self else { return false }
        return dict[key] != nil
    }

    /// Get all keys (if this is an map)
    public var keys: [String]? {
        guard case .map(let dict) = self else { return nil }
        return Array(dict.keys)
    }

    /// Get all values (if this is an map)
    public var values: [ToolInvocationResponseValue]? {
        guard case .map(let dict) = self else { return nil }
        return Array(dict.values)
    }

    /// Count of items (array length or map key count)
    public var count: Int? {
        switch self {
        case .array(let array):
            return array.count
        case .map(let dict):
            return dict.count
        default:
            return nil
        }
    }

    /// Check if empty
    public var isEmpty: Bool {
        switch self {
        case .array(let array):
            return array.isEmpty
        case .map(let dict):
            return dict.isEmpty
        default:
            return false
        }
    }

    // MARK: - Type Conversions

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [ToolInvocationResponseValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var mapValue: [String: ToolInvocationResponseValue]? {
        if case .map(let value) = self { return value }
        return nil
    }

    /// Check if value is null
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: - Type Checking

    public var isString: Bool {
        if case .string = self { return true }
        return false
    }

    public var isNumber: Bool {
        switch self {
        case .int, .double:
            return true
        default:
            return false
        }
    }

    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    public var isMap: Bool {
        if case .map = self { return true }
        return false
    }

    public var isBool: Bool {
        if case .bool = self { return true }
        return false
    }
}
