// Copyright © 2025 Apple Inc. All Rights Reserved.

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
//  JSON+Decoder.swift
//  darwinOSBits
//
//

import Foundation

open class JSEnumDecoder: Decoder {

    public var codingPath: [CodingKey]
    public var userInfo: [CodingUserInfoKey: Any]

    private var node: JSON

    public init(from node: JSON, codingPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.node = node
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    public func container<Key: CodingKey>(
        keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        let value = SingleValueContainer(value: self.node, at: self.codingPath)
        return .init(KeyedValueContainer(value: try value.decodeDict(), at: value.codingPath))
    }

    public func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let array = SingleValueContainer(value: self.node, at: self.codingPath)
        return UnkeyedContainer(codingPath: array.codingPath, arr: try array.decodeArray())
    }

    public func singleValueContainer() throws -> any SingleValueDecodingContainer {
        return SingleValueContainer(value: self.node, at: self.codingPath)
    }

    // --

    public static func decode<T: Decodable>(_ type: T.Type, from json: JSON) throws -> T {
        let decoder = JSEnumDecoder(from: json)
        return try T.init(from: decoder)
    }

    // --

    struct IndexKey: CodingKey {
        let intValue: Int?
        var stringValue: String {
            guard let intValue = self.intValue else {
                fatalError()
            }
            return "\(intValue)"
        }

        init(intValue: Int) {
            self.intValue = intValue
        }

        init?(stringValue: String) {
            return nil
        }
    }

    internal struct UnkeyedContainer: UnkeyedDecodingContainer {
        var codingPath: [any CodingKey]
        var currentIndex: Int
        let arr: [JSON]

        init(codingPath: [any CodingKey], arr: [JSON]) {
            self.codingPath = codingPath
            self.currentIndex = 0
            self.arr = arr
        }

        mutating func _nextValue() throws -> SingleValueContainer {
            guard !self.isAtEnd else {
                throw DecodingError.valueNotFound(
                    Any.self,
                    .init(codingPath: self.codingPath,
                          debugDescription: "No value at index \(currentIndex)"))
            }

            let index = currentIndex
            currentIndex += 1

            let newPath = self.codingPath + [IndexKey(intValue: currentIndex)]
            return SingleValueContainer(value: arr[index], at: newPath)
        }

        var count: Int? {
            arr.count
        }

        var isAtEnd: Bool {
            return currentIndex == count
        }

        mutating func decodeNil() throws -> Bool {
            try _nextValue().decodeNil()
        }

        mutating func decode(_ type: Bool.Type) throws -> Bool {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: String.Type) throws -> String {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: Double.Type) throws -> Double {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: Float.Type) throws -> Float {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: Int.Type) throws -> Int {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: Int8.Type) throws -> Int8 {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: Int16.Type) throws -> Int16 {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: Int32.Type) throws -> Int32 {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: Int64.Type) throws -> Int64 {
            try _nextValue().decode(type)
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        mutating func decode(_ type: Int128.Type) throws -> Int128 {
            try _nextValue().decode(type)
        }
        mutating func decode(_ type: UInt.Type) throws -> UInt {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
            try _nextValue().decode(type)
        }

        mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
            try _nextValue().decode(type)
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        mutating func decode(_ type: UInt128.Type) throws -> UInt128 {
            try _nextValue().decode(type)
        }

        mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
            try _nextValue().decode(type)
        }

        mutating func nestedContainer<NestedKey>(
            keyedBy type: NestedKey.Type
        ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
            let value = try _nextValue()
            return .init(KeyedValueContainer(value: try value.decodeDict(), at: value.codingPath))
        }

        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
            let value = try _nextValue()
            return UnkeyedContainer(codingPath: value.codingPath, arr: try value.decodeArray())
        }

        mutating func superDecoder() throws -> any Decoder {
            fatalError("Not supported")
        }
    }

    // --

    internal struct SingleValueContainer: SingleValueDecodingContainer {
        var value: JSON
        var codingPath: [CodingKey]

        init(value: JSON, at codingPath: [CodingKey]) {
            self.value = value
            self.codingPath = codingPath
        }

        private func _typeMismatch(_ type: Any.Type) -> DecodingError {
            DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "type mismatch"))
        }

        var isNull: Bool {
            return decodeNil()
        }

        internal func decodeDict() throws -> [String: JSON] {
            guard case .dictionary(let dict) = value else {
                throw _typeMismatch([String: JSON].self)
            }
            return dict
        }

        internal func decodeArray() throws -> [JSON] {
            guard case .array(let array) = value else {
                throw _typeMismatch([JSON].self)
            }
            return array
        }

        func decodeNil() -> Bool {
            return if case .null = value { true } else { false }
        }

        func decode(_ type: Bool.Type) throws -> Bool {
            guard case let .bool(boolValue) = value else {
                throw self._typeMismatch(Bool.self)
            }
            return boolValue
        }

        func decode(_ type: String.Type) throws -> String {
            guard case .string(let string) = value else {
                throw self._typeMismatch(String.self)
            }
            return string
        }

        func _decodeFloat<T: BinaryFloatingPoint>(_: T.Type) throws -> T {
			if case .number(let number) = value {
				return T(number)
            }

			guard case .int(let number) = value else {
				throw self._typeMismatch(T.self)
			}

			return T(number)
        }

        func decode(_ type: Double.Type) throws -> Double {
            try _decodeFloat(Double.self)
        }

        func decode(_ type: Float.Type) throws -> Float {
            try _decodeFloat(Float.self)
        }

        func _decodeInt<T: BinaryInteger>(_: T.Type) throws -> T {
			guard case .int(let number) = value else {
                throw self._typeMismatch(T.self)
            }
            return T(number)
        }

        func decode(_ type: Int.Type) throws -> Int {
            try _decodeInt(Int.self)
        }

        func decode(_ type: Int8.Type) throws -> Int8 {
            try _decodeInt(Int8.self)
        }

        func decode(_ type: Int16.Type) throws -> Int16 {
            try _decodeInt(Int16.self)
        }

        func decode(_ type: Int32.Type) throws -> Int32 {
            try _decodeInt(Int32.self)
        }

        func decode(_ type: Int64.Type) throws -> Int64 {
            try _decodeInt(Int64.self)
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        func decode(_ type: Int128.Type) throws -> Int128 {
            try _decodeInt(Int128.self)
        }

        func decode(_ type: UInt.Type) throws -> UInt {
            try _decodeInt(UInt.self)
        }

        func decode(_ type: UInt8.Type) throws -> UInt8 {
            try _decodeInt(UInt8.self)
        }

        func decode(_ type: UInt16.Type) throws -> UInt16 {
            try _decodeInt(UInt16.self)
        }

        func decode(_ type: UInt32.Type) throws -> UInt32 {
            try _decodeInt(UInt32.self)
        }

        func decode(_ type: UInt64.Type) throws -> UInt64 {
            try _decodeInt(UInt64.self)
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        func decode(_ type: UInt128.Type) throws -> UInt128 {
            try _decodeInt(UInt128.self)
        }

        func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
			if T.self is URL.Type {
				let string = try self.decode(String.self)
				guard let url = URL(string: string) else {
					throw DecodingError.typeMismatch(type, .init(
						codingPath: codingPath,
						debugDescription: "Could not decode '\(string)' as URL."
					))
				}
				return url as! T
			} else if T.self is Duration.Type {
				let string = try self.decode(String.self)
				guard let duration = Duration(argument: string) else {
					throw DecodingError.typeMismatch(type, .init(
						codingPath: codingPath,
						debugDescription: "Could not decode '\(string)' as Duration."
					))
				}
				return duration as! T
			}

			let decoder = JSEnumDecoder(from: value, codingPath: codingPath)
            return try T.init(from: decoder)
        }
    }

    internal struct KeyedValueContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let codingPath: [CodingKey]
        let dict: [String: JSON]

        var allKeys: [Key] {
            return dict.keys.compactMap { Key(stringValue: $0) }
        }

        init(value: [String: JSON], at codingPath: [CodingKey]) {
            self.codingPath = codingPath
            self.dict = value
        }

        func _getValue(forKey key: Key) throws -> SingleValueContainer {
            guard let value = dict[key.stringValue] else {
                throw DecodingError.keyNotFound(key, .init(codingPath: self.codingPath,
                                                           debugDescription: "\(key.stringValue) not found"))
            }
            let path = self.codingPath + [key]
            return SingleValueContainer(value: value, at: path)
        }

        func contains(_ key: Key) -> Bool {
            let res = dict[key.stringValue] != nil
            return res
        }

        func decodeNil(forKey key: Key) throws -> Bool {
            try _getValue(forKey: key).decodeNil()
        }

        func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
            try self._getValue(forKey: key).decode(Bool.self)
        }

        func decode(_ type: String.Type, forKey key: Key) throws -> String {
            try self._getValue(forKey: key).decode(String.self)
        }

        func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
            try self._getValue(forKey: key).decode(Double.self)
        }

        func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
            try self._getValue(forKey: key).decode(Float.self)
        }

        func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
            try self._getValue(forKey: key).decode(Int.self)
        }

        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
            try self._getValue(forKey: key).decode(Int8.self)
        }

        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
            try self._getValue(forKey: key).decode(Int16.self)
        }

        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
            try self._getValue(forKey: key).decode(Int32.self)
        }

        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
            try self._getValue(forKey: key).decode(Int64.self)
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        func decode(_ type: Int128.Type, forKey key: Key) throws -> Int128 {
            try self._getValue(forKey: key).decode(Int128.self)
        }

        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
            try self._getValue(forKey: key).decode(UInt.self)
        }

        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
            try self._getValue(forKey: key).decode(UInt8.self)
        }

        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
            try self._getValue(forKey: key).decode(UInt16.self)
        }

        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
            try self._getValue(forKey: key).decode(UInt32.self)
        }

        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
            try self._getValue(forKey: key).decode(UInt64.self)
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        func decode(_ type: UInt128.Type, forKey key: Key) throws -> UInt128 {
            try self._getValue(forKey: key).decode(UInt128.self)
        }

        func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
            let value = try _getValue(forKey: key)

            if T.self is URL.Type {
                let string = try value.decode(String.self)
                guard let url = URL(string: string) else {
                    throw DecodingError.typeMismatch(type, .init(
                        codingPath: codingPath,
                        debugDescription: "Could not decode '\(string)' as URL."
                    ))
                }
                return url as! T
            } else if T.self is Duration.Type {
                let string = try value.decode(String.self)
                guard let duration = Duration(argument: string) else {
                    throw DecodingError.typeMismatch(type, .init(
                        codingPath: codingPath,
                        debugDescription: "Could not decode '\(string)' as Duration."
                    ))
                }
                return duration as! T
            }

            let decoder = JSEnumDecoder(from: value.value, codingPath: value.codingPath)
            return try T.init(from: decoder)
        }

        func nestedContainer<NestedKey>(
            keyedBy type: NestedKey.Type, forKey key: Key
        ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
            let value = try self._getValue(forKey: key)
            return .init(KeyedValueContainer<NestedKey>(value: try value.decodeDict(), at: value.codingPath))
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            let value = try self._getValue(forKey: key)
            return UnkeyedContainer(codingPath: value.codingPath, arr: try value.decodeArray())
        }

        func superDecoder() throws -> any Decoder {
            fatalError("Not supported")
        }

        func superDecoder(forKey key: Key) throws -> any Decoder {
            fatalError("Not supported")
        }
    }
}
