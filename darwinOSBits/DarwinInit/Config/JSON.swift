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

//
//  JSON.swift
//  DarwinInit
//

import Foundation

public indirect enum JSON {
    case null
    case bool(Bool)
	case int(Int128)
	case number(Double)
    case string(String)
    case array([JSON])
    case dictionary([String: JSON])
}

extension JSON: Decodable {
    public init(from decoder: Decoder) throws {
        if let bool = try? Bool(from: decoder) {
            self = .bool(bool)
		} else if let int = try? Int128(from: decoder) {
			self = .int(int)
		} else if let number = try? Double(from: decoder) {
            self = .number(number)
        } else if let string = try? String(from: decoder) {
            self = .string(string)
        } else if let array = try? [JSON](from: decoder) {
            self = .array(array)
        } else if let dictionary = try? [String: JSON](from: decoder) {
            self = .dictionary(dictionary)
        } else {
            self = .null
        }
    }
}

extension JSON: Encodable {
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(bool):
            try bool.encode(to: encoder)
		case let .int(int):
			try int.encode(to: encoder)
		case let .number(number):
            try number.encode(to: encoder)
        case let .string(string):
            try string.encode(to: encoder)
        case let .array(array):
            try array.encode(to: encoder)
        case let .dictionary(dictionary):
            try dictionary.encode(to: encoder)
        }
    }
}

extension JSON: Equatable { }

extension JSON: Hashable { }

extension JSON {
    public var propertyListValue: CFPropertyList? {
        switch self {
        case .null:
            return nil
        case let .bool(bool):
            return bool as CFBoolean
        case let .int(int):
            return if int.signum() < 0 {
                Int64(clamping: int) as CFNumber
            } else {
                UInt64(clamping: int) as CFNumber
            }
        case let .number(double):
            return double as CFNumber
        case let .string(string):
            return string as CFString
        case let .array(array):
            return array.compactMap(\.propertyListValue) as CFArray
        case let .dictionary(dictionary):
            return dictionary.compactMapValues(\.propertyListValue) as CFDictionary
        }
    }
    
    public var dictionaryValue: CFDictionary? {
        switch self {
		case .null, .bool, .int, .number, .string, .array:
            return nil
        case let .dictionary(dictionary):
            return dictionary.compactMapValues(\._childDictionaryValue) as CFDictionary
        }
    }
    
    private var _childDictionaryValue: Any? {
        switch self {
        case .null:
            return nil
        case let .bool(bool):
            return bool as CFBoolean
        case let .int(int):
            return if int.signum() < 0 {
                Int64(clamping: int) as CFNumber
            } else {
                UInt64(clamping: int) as CFNumber
            }
		case let .number(double):
            return double as CFNumber
        case let .string(string):
            return string as CFString
        case let .array(array):
            return array.compactMap(\._childDictionaryValue) as CFArray
        case let .dictionary(dictionary):
            return dictionary.compactMapValues(\._childDictionaryValue) as CFDictionary
        }
    }
}

extension JSON: CustomStringConvertible {

    private func description<S: Sequence>(
        for seq: S,
        prefix: String,
        postfix: String,
        at level: Int,
        block: (S.Element) -> String
    ) -> String {
        var desc = prefix + "\n"

        desc += seq.map(block).joined(separator: ",\n")

        desc += "\n"
        desc +=  String(repeating: "  ", count: level - 1)
        desc += postfix

        return desc
    }

    private func description(for array: [JSON], level: Int) -> String {
        description(for: array, prefix: "[", postfix: "]", at: level) {
            String(repeating: "  ", count: level) +
            $0.description(level: level + 1)
        }
    }

    private func description(for dict: [String: JSON], level: Int) -> String {
        description(for: dict, prefix: "{", postfix: "}", at: level) { (key, value) in
            String(repeating: "  ", count: level) +
            "\"\(key)\": " +
            value.description(level: level + 1)
        }
    }

    private func description(level: Int) -> String {
        return switch self {
        case .null: "null"
        case let .bool(bool): bool ? "true" : "false"
        case let .int(int): String(int, radix: 10)
        case let .number(double): "\(double)"
        case let .string(string): "\"\(string)\""
        case let .array(array): description(for: array, level: level)
        case let .dictionary(dict): description(for: dict, level: level)
        }
    }

    public var description: String {
        return self.description(level: 1)
    }
}
