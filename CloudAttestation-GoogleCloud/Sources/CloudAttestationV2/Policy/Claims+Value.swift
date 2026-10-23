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
//  Claims+Value.swift
//  CloudAttestationV2
//
//  Created by David Zech on 2/18/26.
//

import AST
import Foundation

extension Claims {
    public protocol ValueProtocol: Codable, Hashable, Sendable {
        //        init?(_ intValue: Int)
        //        init?(_ boolValue: Bool)
        //        init?(_ stringValue: String)
        //        init?(_ bytesValue: [UInt8])
        //        init?(_ arrayValue: [some ValueProtocol])
        //        init?(_ dictionaryValue: [String: some ValueProtocol])
        init?(_ value: Value)

        var value: Value { get }
    }

    public protocol DefaultInitializableValue: ValueProtocol {
        init()
    }

    public enum Value: ValueProtocol {
        case null
        case int(Int64)
        case bool(Bool)
        case string(String)
        case bytes(Data)
        case array([Value])
        case dictionary([String: Value])

        public init(_ value: Value) {
            self = value
        }

        public var value: Value {
            self
        }

        var typeErased: Any {
            switch self {
            case .null:
                NSNull()
            case .int(let int):
                int
            case .bool(let bool):
                bool
            case .string(let string):
                string
            case .bytes(let bytes):
                bytes
            case .array(let array):
                array
            case .dictionary(let dictionary):
                dictionary
            }
        }

        var prettyJSONObject: Any {
            switch self {
            case .null:
                return NSNull()
            case .int(let int):
                return int
            case .bool(let bool):
                return bool
            case .string(let string):
                return string
            case .bytes(let array):
                return Data(array).base64EncodedString()
            case .array(let array):
                return array.map { $0.prettyJSONObject }
            case .dictionary(let dictionary):
                return dictionary.mapValues { value in
                    value.prettyJSONObject
                }
            }
        }
    }
}

extension Claims.Value: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .int(value)
    }
}

extension Claims.Value: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self = .string(value)
    }
}

extension String: Claims.ValueProtocol {
    public init?(_ value: Claims.Value) {
        guard case .string(let s) = value else {
            return nil
        }
        self = s
    }

    public var value: Claims.Value {
        .string(self)
    }
}

extension Bool: Claims.ValueProtocol {
    public init?(_ value: Claims.Value) {
        guard case .bool(let bool) = value else {
            return nil
        }
        self = bool
    }

    public var value: Claims.Value {
        .bool(self)
    }
}

extension Int64: Claims.ValueProtocol {
    public init?(_ value: Claims.Value) {
        guard case .int(let int) = value else {
            return nil
        }
        self = int
    }

    public var value: Claims.Value {
        .int(self)
    }
}

extension Data: Claims.ValueProtocol {
    public init?(_ value: Claims.Value) {
        guard case .bytes(let data) = value else {
            return nil
        }
        self = data
    }

    public var value: Claims.Value {
        .bytes(self)
    }
}

extension Dictionary: Claims.ValueProtocol where Key == String, Value == Claims.Value {
    public init?(_ value: Claims.Value) {
        guard case .dictionary(let dictionary) = value else {
            return nil
        }
        self = dictionary
    }

    public var value: Claims.Value {
        .dictionary(self)
    }
}

extension Array: Claims.ValueProtocol where Element: Claims.ValueProtocol {}

extension Claims.Value {
    var regoValue: RegoValue {
        switch self {
        case .null:
            return .null
        case .int(let int):
            return .number(RegoNumber(int: int))
        case .bool(let bool):
            return .boolean(bool)
        case .string(let string):
            return .string(string)
        case .bytes(let data):
            return .string(data.base64EncodedString())
        case .array(let array):
            return .array(array.map { $0.regoValue })
        case .dictionary(let dictionary):
            var output = [RegoValue: RegoValue]()
            for (key, value) in dictionary {
                output[.string(key)] = value.regoValue
            }
            return .object(output)
        }
    }
}
