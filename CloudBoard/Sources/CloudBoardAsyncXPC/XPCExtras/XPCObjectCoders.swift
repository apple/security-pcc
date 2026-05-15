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

import Foundation
import XPC

// Note: There are quite a few places in this file where the force-unwrap operator `!` is used. Nearly all of these
//       cases are due to the various Codable protocols enforcing optionality in scenarios where we can reliably prove
//       there is no possibility of a `nil` value arising, or else that such a value arising in practice would indicate
//       an error of such severity that immediately crashing is the appropriate response.

internal final class XPCObjectEncoder {
    internal init() {}

    /// The usual - turns an encodable something into an `xpc_object_t`
    internal func encode<T: Encodable>(_ value: T) throws -> xpc_object_t {
        let encoder = _XPCObjectEncoder()

        try value.encode(to: encoder)
        guard let result = encoder.topLevelStorage else {
            throw EncodingError.invalidValue(value, .init(
                codingPath: [],
                debugDescription: "Failed to encode top-level value of type \(T.self)"
            ))
        }
        return result
    }

    /// Flatten an encodable something into an existing `xpc_object_t`. The
    /// object **MUST** be a dictionary, and any existing keys in the dictionary
    /// will be overwritten if they conflict with those being encoded. This is
    /// intended for use with, e.g. the reply dictionary provided by
    /// `xpc_dictionary_create_reply()`.
    private func encode(_ value: some Encodable, into dictionary: xpc_object_t) throws {
        guard xpc_get_type(dictionary) == XPC_TYPE_DICTIONARY else {
            throw EncodingError.invalidValue(dictionary, .init(
                codingPath: [],
                debugDescription: "The destination for an in-place encode must be a dictionary."
            ))
        }

        let result = try encode(value)
        guard xpc_get_type(result) == XPC_TYPE_DICTIONARY else {
            throw EncodingError.invalidValue(dictionary, .init(
                codingPath: [],
                debugDescription: "The source for an in-place encode must encode to a dictionary at the top level."
            ))
        }
        xpc_dictionary_apply(result) { key, value -> Bool in
            xpc_dictionary_set_value(dictionary, key, value)
            return true
        }
    }

    /// Flatten an encodable something into an existing `XPCDictionary`.
    private func encode(_ value: some Encodable, into dictionary: inout XPCDictionary) throws {
        try dictionary.withUnsafeUnderlyingDictionary { dictionary in
            try self.encode(value, into: dictionary)
        }
    }
}

final class _XPCObjectEncoder: Encoder {
    fileprivate var topLevelStorage: xpc_object_t?

    init(atPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.codingPath = atPath
        self.userInfo = userInfo
    }

    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]

    func container<Key>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        assert(self.topLevelStorage == nil)
        self.topLevelStorage = xpc_dictionary_create(nil, nil, 0)
        return .init(XPCObjectKeyedEncodingContainer(
            encodingTo: self.topLevelStorage!,
            for: self,
            atPath: self.codingPath
        ))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        assert(self.topLevelStorage == nil)
        self.topLevelStorage = xpc_array_create(nil, 0)
        return XPCObjectUnkeyedEncodingContainer(encodingTo: self.topLevelStorage!, for: self, atPath: self.codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        assert(self.topLevelStorage == nil)
        return XPCObjectSingleValueEncodingContainer(for: self, atPath: self.codingPath)
    }
}

private struct XPCObjectKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    private let encoder: _XPCObjectEncoder
    private let topLevelStorage: xpc_object_t

    init(encodingTo topLevelStorage: xpc_object_t, for encoder: _XPCObjectEncoder, atPath: [CodingKey]) {
        self.encoder = encoder
        self.topLevelStorage = topLevelStorage
        self.codingPath = atPath
    }

    let codingPath: [CodingKey]

    mutating func encodeNil(forKey key: Key) throws { xpc_dictionary_set_value(
        self.topLevelStorage,
        key.stringValue,
        nil
    ) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { xpc_dictionary_set_bool(
        self.topLevelStorage,
        key.stringValue,
        value
    ) }
    mutating func encode(_ value: String, forKey key: Key) throws { xpc_dictionary_set_string(
        self.topLevelStorage,
        key.stringValue,
        value
    ) }
    mutating func encode(_ value: Double, forKey key: Key) throws { xpc_dictionary_set_double(
        self.topLevelStorage,
        key.stringValue,
        value
    ) }
    mutating func encode(_ value: Float, forKey key: Key) throws {
        xpc_dictionary_set_double(self.topLevelStorage, key.stringValue, Double(value))
    }

    mutating func encode(_ value: Int, forKey key: Key) throws { xpc_dictionary_set_int64(
        self.topLevelStorage,
        key.stringValue,
        Int64(value)
    ) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { xpc_dictionary_set_int64(
        self.topLevelStorage,
        key.stringValue,
        Int64(value)
    ) }
    mutating func encode(_ value: Int16, forKey key: Key) throws {
        xpc_dictionary_set_int64(self.topLevelStorage, key.stringValue, Int64(value))
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        xpc_dictionary_set_int64(self.topLevelStorage, key.stringValue, Int64(value))
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        xpc_dictionary_set_int64(self.topLevelStorage, key.stringValue, value)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        xpc_dictionary_set_uint64(self.topLevelStorage, key.stringValue, UInt64(value))
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        xpc_dictionary_set_uint64(self.topLevelStorage, key.stringValue, UInt64(value))
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        xpc_dictionary_set_uint64(self.topLevelStorage, key.stringValue, UInt64(value))
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        xpc_dictionary_set_uint64(self.topLevelStorage, key.stringValue, UInt64(value))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws { xpc_dictionary_set_uint64(
        self.topLevelStorage,
        key.stringValue,
        value
    ) }
    mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
        if let date = value as? Date {
            xpc_dictionary_set_date(self.topLevelStorage, key.stringValue, Int64(date.timeIntervalSince1970))
        } else if let uuid = value as? UUID {
            withUnsafeBytes(of: uuid.uuid) {
                xpc_dictionary_set_uuid(
                    self.topLevelStorage,
                    key.stringValue,
                    $0.bindMemory(to: UInt8.self).baseAddress!
                )
            }
        } else if let data = value as? Data {
            data.withUnsafeBytes { xpc_dictionary_set_data(
                self.topLevelStorage,
                key.stringValue,
                $0.baseAddress!,
                $0.count
            ) }
        } else if let placeholder = value as? XPCObjectContainer {
            xpc_dictionary_set_value(self.topLevelStorage, key.stringValue, placeholder.object)
        } else {
            let encoder = _XPCObjectEncoder(atPath: codingPath + [key])
            try value.encode(to: encoder)
            guard let result = encoder.topLevelStorage else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: self.codingPath + [key],
                    debugDescription: "failed to encode value of type \(T.self)"
                ))
            }
            xpc_dictionary_set_value(self.topLevelStorage, key.stringValue, result)
        }
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let newStorage = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(self.topLevelStorage, key.stringValue, newStorage)
        return .init(XPCObjectKeyedEncodingContainer<NestedKey>(
            encodingTo: newStorage,
            for: self.encoder,
            atPath: self.codingPath + [key]
        ))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let newStorage = xpc_array_create(nil, 0)
        xpc_dictionary_set_value(self.topLevelStorage, key.stringValue, newStorage)
        return XPCObjectUnkeyedEncodingContainer(
            encodingTo: newStorage,
            for: self.encoder,
            atPath: self.codingPath + [key]
        )
    }

    mutating func superEncoder() -> Encoder {
        fatalError("superEncoder() is not supported for XPC encoding and Codable still doesn't throw from this method")
    }

    mutating func superEncoder(forKey _: Key) -> Encoder {
        fatalError(
            "superEncoder(forKey:) is not supported for XPC encoding and Codable still doesn't throw from this method"
        )
    }
}

private struct XPCObjectUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    private let encoder: _XPCObjectEncoder
    private let topLevelStorage: xpc_object_t

    init(encodingTo topLevelStorage: xpc_object_t, for encoder: _XPCObjectEncoder, atPath: [CodingKey]) {
        self.encoder = encoder
        self.topLevelStorage = topLevelStorage
        self.codingPath = atPath
    }

    let codingPath: [CodingKey]

    var count: Int { xpc_array_get_count(self.topLevelStorage) }

    private var currentIndexKey: CodingKey { CodableIndexKey(intValue: self.count)! }

    mutating func encodeNil() throws {
        throw EncodingError.invalidValue(Void?(()) as Any, .init(
            codingPath: self.codingPath + [self.currentIndexKey],
            debugDescription: "nil is not allowed in XPC arrays"
        ))
    }

    mutating func encode(_ value: Bool) throws { xpc_array_append_value(self.topLevelStorage, xpc_bool_create(value)) }
    mutating func encode(_ value: String) throws {
        xpc_array_append_value(self.topLevelStorage, xpc_string_create(value))
    }

    mutating func encode(_ value: Double) throws {
        xpc_array_append_value(self.topLevelStorage, xpc_double_create(value))
    }

    mutating func encode(_ value: Float) throws { xpc_array_append_value(
        self.topLevelStorage,
        xpc_double_create(Double(value))
    ) }
    mutating func encode(_ value: Int) throws { xpc_array_append_value(
        self.topLevelStorage,
        xpc_int64_create(Int64(value))
    ) }
    mutating func encode(_ value: Int8) throws { xpc_array_append_value(
        self.topLevelStorage,
        xpc_int64_create(Int64(value))
    ) }
    mutating func encode(_ value: Int16) throws { xpc_array_append_value(
        self.topLevelStorage,
        xpc_int64_create(Int64(value))
    ) }
    mutating func encode(_ value: Int32) throws { xpc_array_append_value(
        self.topLevelStorage,
        xpc_int64_create(Int64(value))
    ) }
    mutating func encode(_ value: Int64) throws { xpc_array_append_value(self.topLevelStorage, xpc_int64_create(value))
    }

    mutating func encode(_ value: UInt) throws { xpc_array_append_value(
        self.topLevelStorage,
        xpc_uint64_create(UInt64(value))
    ) }
    mutating func encode(_ value: UInt8) throws { xpc_array_append_value(
        self.topLevelStorage,
        xpc_uint64_create(UInt64(value))
    ) }
    mutating func encode(_ value: UInt16) throws { xpc_array_append_value(
        self.topLevelStorage,
        xpc_uint64_create(UInt64(value))
    ) }
    mutating func encode(_ value: UInt32) throws { xpc_array_append_value(
        self.topLevelStorage,
        xpc_uint64_create(UInt64(value))
    ) }
    mutating func encode(_ value: UInt64) throws {
        xpc_array_append_value(self.topLevelStorage, xpc_uint64_create(value))
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        if let date = value as? Date {
            xpc_array_append_value(self.topLevelStorage, xpc_date_create(Int64(date.timeIntervalSince1970)))
        } else if let uuid = value as? UUID {
            withUnsafeBytes(of: uuid.uuid) {
                xpc_array_append_value(
                    self.topLevelStorage,
                    xpc_uuid_create($0.bindMemory(to: UInt8.self).baseAddress!)
                )
            }
        } else if let data = value as? Data {
            data.withUnsafeBytes { xpc_array_append_value(
                self.topLevelStorage,
                xpc_data_create($0.baseAddress!, $0.count)
            ) }
        } else if let placeholder = value as? XPCObjectContainer {
            xpc_array_append_value(self.topLevelStorage, placeholder.object)
        } else {
            let encoder = _XPCObjectEncoder(atPath: codingPath + [currentIndexKey])
            try value.encode(to: encoder)
            guard let result = encoder.topLevelStorage else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: self.codingPath + [self.currentIndexKey],
                    debugDescription: "failed to encode value of type \(T.self)"
                ))
            }
            xpc_array_append_value(self.topLevelStorage, result)
        }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey
            .Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let newStorage = xpc_dictionary_create(nil, nil, 0)
        xpc_array_append_value(self.topLevelStorage, newStorage)
        return .init(XPCObjectKeyedEncodingContainer(
            encodingTo: newStorage,
            for: self.encoder,
            atPath: self.codingPath + [self.currentIndexKey]
        ))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let newStorage = xpc_array_create(nil, 0)
        xpc_array_append_value(self.topLevelStorage, newStorage)
        return XPCObjectUnkeyedEncodingContainer(
            encodingTo: newStorage,
            for: self.encoder,
            atPath: self.codingPath + [self.currentIndexKey]
        )
    }

    mutating func superEncoder() -> Encoder {
        fatalError("superEncoder() is not supported for XPC encoding and Codable still doesn't throw from this method")
    }
}

private struct XPCObjectSingleValueEncodingContainer: SingleValueEncodingContainer {
    private let encoder: _XPCObjectEncoder

    fileprivate init(for encoder: _XPCObjectEncoder, atPath: [CodingKey]) {
        self.encoder = encoder
        self.codingPath = atPath
    }

    var codingPath: [CodingKey]

    // The single-value container is kinda weird in that rather than carrying
    // its own storage, it sets the top-level storage on the encoder directly.
    // This slightly backwards behavior allows for this simpler implementation
    // which has no need to precisely track the lifetimes of vended containers.

    mutating func encodeNil() throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_null_create()
    }

    mutating func encode(_ value: Bool) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_bool_create(value)
    }

    mutating func encode(_ value: String) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_string_create(value)
    }

    mutating func encode(_ value: Double) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_double_create(value)
    }

    mutating func encode(_ value: Float) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_double_create(Double(value))
    }

    mutating func encode(_ value: Int) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_int64_create(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_int64_create(Int64(value))
    }

    mutating func encode(_ value: Int16) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_int64_create(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_int64_create(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_int64_create(value)
    }

    mutating func encode(_ value: UInt) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_uint64_create(UInt64(value))
    }

    mutating func encode(_ value: UInt8) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_uint64_create(UInt64(value))
    }

    mutating func encode(_ value: UInt16) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_uint64_create(UInt64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_uint64_create(UInt64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        precondition(self.encoder.topLevelStorage == nil)
        self.encoder.topLevelStorage = xpc_uint64_create(value)
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        precondition(self.encoder.topLevelStorage == nil)

        if let date = value as? Date {
            self.encoder.topLevelStorage = xpc_date_create(Int64(date.timeIntervalSince1970))
        } else if let uuid = value as? UUID {
            self.encoder.topLevelStorage = withUnsafeBytes(of: uuid.uuid) {
                xpc_uuid_create($0.bindMemory(to: UInt8.self).baseAddress!)
            }
        } else if let data = value as? Data {
            self.encoder.topLevelStorage = data.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
        } else if let placeholder = value as? XPCObjectContainer {
            self.encoder.topLevelStorage = placeholder.object
        } else {
            let encoder = _XPCObjectEncoder(atPath: self.codingPath, userInfo: self.encoder.userInfo)
            try value.encode(to: encoder)
            guard let result = encoder.topLevelStorage else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: self.codingPath,
                    debugDescription: "failed to encode value of type \(T.self)"
                ))
            }
            self.encoder.topLevelStorage = result
        }
    }
}

internal final class XPCObjectDecoder {
    internal typealias Input = xpc_object_t

    internal init() {}

    internal func decode<T: Decodable>(_: T.Type = T.self, from object: xpc_object_t) throws -> T {
        let decoder = _XPCObjectDecoder(decoding: object)

        return try T(from: decoder)
    }

    internal func decode<T: Decodable>(_ type: T.Type = T.self, from dict: XPCDictionary) throws -> T {
        try dict.withUnsafeUnderlyingDictionary { dict in
            try self.decode(type, from: dict)
        }
    }
}

final class _XPCObjectDecoder: Decoder {
    private let topLevelObject: xpc_object_t

    init(decoding topLevelObject: xpc_object_t, atPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.topLevelObject = topLevelObject
        self.codingPath = atPath
        self.userInfo = userInfo
    }

    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]

    func container<Key>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        if xpc_get_type(self.topLevelObject) != XPC_TYPE_DICTIONARY {
            throw DecodingError.typeMismatch(
                Key.self,
                .init(codingPath: self.codingPath, debugDescription: "dictionary required here")
            )
        }
        return .init(XPCObjectKeyedDecodingContainer(decoding: self.topLevelObject, for: self, atPath: self.codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        if xpc_get_type(self.topLevelObject) != XPC_TYPE_ARRAY {
            throw DecodingError.typeMismatch(
                [Decodable].self,
                .init(codingPath: self.codingPath, debugDescription: "array required here")
            )
        }
        return XPCObjectUnkeyedDecodingContainer(decoding: self.topLevelObject, for: self, atPath: self.codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        XPCObjectSingleValueDecodingContainer(decoding: self.topLevelObject, for: self, atPath: self.codingPath)
    }
}

/// Cribbed right out of `stdlib/internal/core/Codable.swift.gyb`
struct CodableIndexKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    internal init?(stringValue _: String) {
        nil
    }

    internal init?(intValue: Int) {
        self.stringValue = "Index \(intValue)"
        self.intValue = intValue
    }
}

private struct XPCObjectKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    private let decoder: _XPCObjectDecoder
    private let topLevelObject: xpc_object_t

    init(decoding topLevelObject: xpc_object_t, for decoder: _XPCObjectDecoder, atPath: [CodingKey]) {
        assert(xpc_get_type(topLevelObject) == XPC_TYPE_DICTIONARY)
        self.decoder = decoder
        self.topLevelObject = topLevelObject
        self.codingPath = atPath
    }

    let codingPath: [CodingKey]

    var allKeys: [Key] {
        var keys: [String] = []

        let applyResult = xpc_dictionary_apply(topLevelObject) { key, _ in
            // A non-UTF8 string here would be a fatal error in any case, representing serious memory corruption or a
            // major XPC bug
            keys.append(String(utf8String: key)!)
            return true
        }
        assert(applyResult == true)
        return keys.compactMap { Key(stringValue: $0) }
    }

    private func xpcDecodingObjectOfType(
        _ type: (some Any).Type,
        xpcType: xpc_type_t,
        forKey key: XPCObjectKeyedDecodingContainer.Key
    ) throws -> xpc_object_t {
        guard let object = xpc_dictionary_get_value(topLevelObject, key.stringValue) else {
            throw DecodingError.keyNotFoundError(expecting: key, in: self)
        }
        guard xpc_get_type(object) == xpcType else {
            throw DecodingError.typeMismatchError(expecting: type, butFound: object, forKey: key, in: self)
        }
        return object
    }

    private func xpcDecodingObjectOfIntegerType<T: SignedInteger>(
        _ type: T.Type,
        forKey key: XPCObjectKeyedDecodingContainer.Key
    ) throws -> T {
        guard let result = try type.init(
            exactly: xpc_int64_get_value(xpcDecodingObjectOfType(type, xpcType: XPC_TYPE_INT64, forKey: key))
        )
        else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "value doesn't fit in \(type)"
            )
        }
        return result
    }

    private func xpcDecodingObjectOfIntegerType<T: UnsignedInteger>(
        _ type: T.Type,
        forKey key: XPCObjectKeyedDecodingContainer.Key
    ) throws -> T {
        guard let result = try type.init(
            exactly: xpc_uint64_get_value(xpcDecodingObjectOfType(type, xpcType: XPC_TYPE_UINT64, forKey: key))
        )
        else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "value doesn't fit in \(type)"
            )
        }
        return result
    }

    func contains(_ key: Key) -> Bool {
        xpc_dictionary_get_value(self.topLevelObject, key.stringValue) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        do {
            _ = try self.xpcDecodingObjectOfType(Void?.self, xpcType: XPC_TYPE_NULL, forKey: key)
            return true
        } catch DecodingError.typeMismatch(_, _) {
            return false
        }
    }

    func decode(_: Bool.Type, forKey key: Key) throws -> Bool {
        try xpc_bool_get_value(self.xpcDecodingObjectOfType(Bool.self, xpcType: XPC_TYPE_BOOL, forKey: key))
    }

    func decode(_: String.Type, forKey key: Key) throws -> String {
        let stringObject = try xpcDecodingObjectOfType(String.self, xpcType: XPC_TYPE_STRING, forKey: key)

        return UnsafeBufferPointer(
            start: xpc_string_get_string_ptr(stringObject),
            count: xpc_string_get_length(stringObject)
        )
        .withMemoryRebound(to: UInt8.self) {
            String(decoding: $0, as: UTF8.self)
        }
    }

    func decode(_: Double.Type, forKey key: Key) throws -> Double {
        try xpc_double_get_value(self.xpcDecodingObjectOfType(Double.self, xpcType: XPC_TYPE_DOUBLE, forKey: key))
    }

    func decode(_: Float.Type, forKey key: Key) throws -> Float {
        guard let result = try Float(
            exactly: xpc_double_get_value(xpcDecodingObjectOfType(
                Double.self,
                xpcType: XPC_TYPE_DOUBLE,
                forKey: key
            ))
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "value doesn't fit in Float"
            )
        }
        return result
    }

    func decode(_: Int.Type, forKey key: Key) throws -> Int { try self.xpcDecodingObjectOfIntegerType(
        Int.self,
        forKey: key
    ) }
    func decode(_: Int8.Type, forKey key: Key) throws -> Int8 { try self.xpcDecodingObjectOfIntegerType(
        Int8.self,
        forKey: key
    ) }
    func decode(_: Int16.Type, forKey key: Key) throws -> Int16 { try self.xpcDecodingObjectOfIntegerType(
        Int16.self,
        forKey: key
    ) }
    func decode(_: Int32.Type, forKey key: Key) throws -> Int32 { try self.xpcDecodingObjectOfIntegerType(
        Int32.self,
        forKey: key
    ) }
    func decode(_: Int64.Type, forKey key: Key) throws -> Int64 { try self.xpcDecodingObjectOfIntegerType(
        Int64.self,
        forKey: key
    ) }
    func decode(_: UInt.Type, forKey key: Key) throws -> UInt { try self.xpcDecodingObjectOfIntegerType(
        UInt.self,
        forKey: key
    ) }
    func decode(_: UInt8.Type, forKey key: Key) throws -> UInt8 { try self.xpcDecodingObjectOfIntegerType(
        UInt8.self,
        forKey: key
    ) }
    func decode(_: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try self.xpcDecodingObjectOfIntegerType(UInt16.self, forKey: key)
    }

    func decode(_: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try self.xpcDecodingObjectOfIntegerType(UInt32.self, forKey: key)
    }

    func decode(_: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try self.xpcDecodingObjectOfIntegerType(UInt64.self, forKey: key)
    }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        if T.self is Date.Type {
            return try Date(
                timeIntervalSince1970: TimeInterval(
                    xpc_date_get_value(self.xpcDecodingObjectOfType(
                        Date.self,
                        xpcType: XPC_TYPE_DATE,
                        forKey: key
                    ))
                )
            ) as! T
        } else if T.self is UUID.Type {
            return try xpc_uuid_get_bytes(
                self.xpcDecodingObjectOfType(
                    UUID.self,
                    xpcType: XPC_TYPE_UUID,
                    forKey: key
                )
            )!.withMemoryRebound(to: uuid_t.self, capacity: 1) { UUID(uuid: $0.pointee) } as! T
        } else if T.self is Data.Type {
            let object = try xpcDecodingObjectOfType(Data.self, xpcType: XPC_TYPE_DATA, forKey: key)

            if xpc_data_get_length(object) > 0 {
                return Data(bytes: xpc_data_get_bytes_ptr(object)!, count: xpc_data_get_length(object)) as! T
            } else {
                return Data() as! T
            }
        } else if T.self is XPCObjectContainer.Type {
            guard let object = xpc_dictionary_get_value(topLevelObject, key.stringValue) else {
                throw DecodingError.keyNotFoundError(expecting: key, in: self)
            }
            return XPCObjectContainer(object) as! T
        } else {
            guard let raw = xpc_dictionary_get_value(topLevelObject, key.stringValue) else {
                throw DecodingError.keyNotFoundError(expecting: key, in: self)
            }
            let decoder = _XPCObjectDecoder(decoding: raw, atPath: codingPath + [key], userInfo: self.decoder.userInfo)
            return try type.init(from: decoder)
        }
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let dict = try xpcDecodingObjectOfType(NestedKey.self, xpcType: XPC_TYPE_DICTIONARY, forKey: key)

        return .init(XPCObjectKeyedDecodingContainer<NestedKey>(
            decoding: dict,
            for: self.decoder,
            atPath: self.codingPath + [key]
        ))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let array = try xpcDecodingObjectOfType([Decodable].self, xpcType: XPC_TYPE_ARRAY, forKey: key)

        return XPCObjectUnkeyedDecodingContainer(decoding: array, for: self.decoder, atPath: self.codingPath + [key])
    }

    func superDecoder() throws -> Decoder {
        throw DecodingError.valueNotFoundError(
            expectingValueOfType: _XPCObjectDecoder.self,
            atCodingPath: self.codingPath,
            debugDescription: "super is not supported"
        )
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        throw DecodingError.keyNotFoundError(expecting: key, in: self, debugDescription: "super is not supported")
    }
}

private struct XPCObjectUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    private let decoder: _XPCObjectDecoder
    private let topLevelObject: xpc_object_t

    init(decoding topLevelObject: xpc_object_t, for decoder: _XPCObjectDecoder, atPath: [CodingKey]) {
        assert(xpc_get_type(topLevelObject) == XPC_TYPE_ARRAY)
        self.decoder = decoder
        self.topLevelObject = topLevelObject
        self.codingPath = atPath
        self.currentIndex = 0
    }

    let codingPath: [CodingKey]
    var count: Int? { xpc_array_get_count(self.topLevelObject) }
    var isAtEnd: Bool { self.currentIndex >= self.count!
    } // Force-unwrap hides protocol-enforced optionality that is never actually nil
    private(set) var currentIndex: Int
    private var currentIndexKey: CodingKey { CodableIndexKey(intValue: self.currentIndex)! }

    private mutating func xpcDecodingObjectOfType<R>(
        _ type: (some Any).Type,
        xpcType: xpc_type_t,
        alsoChecking: (XPCObjectUnkeyedDecodingContainer, xpc_object_t) throws -> R = { _, o in o as! R }
    ) throws -> R {
        guard !self.isAtEnd else {
            throw DecodingError.valueNotFoundError(
                expectingValueOfType: type,
                in: self,
                debugDescription: "no items left in array"
            )
        }
        let object = xpc_array_get_value(topLevelObject, self.currentIndex)
        guard xpc_get_type(object) == xpcType else {
            throw DecodingError.typeMismatchError(expecting: type, butFound: object, in: self)
        }
        let result = try alsoChecking(self, object)
        self.currentIndex += 1
        return result
    }

    private mutating func xpcDecodingObjectOfIntegerType<T: SignedInteger>(_ type: T.Type) throws -> T {
        try self.xpcDecodingObjectOfType(type, xpcType: XPC_TYPE_INT64) {
            guard let result = type.init(exactly: xpc_int64_get_value($1)) else {
                throw DecodingError.dataCorruptedError(in: $0, debugDescription: "value doesn't fit in \(type)")
            }
            return result
        }
    }

    private mutating func xpcDecodingObjectOfIntegerType<T: UnsignedInteger>(_ type: T.Type) throws -> T {
        try self.xpcDecodingObjectOfType(type, xpcType: XPC_TYPE_UINT64) {
            guard let result = type.init(exactly: xpc_uint64_get_value($1)) else {
                throw DecodingError.dataCorruptedError(in: $0, debugDescription: "value doesn't fit in \(type)")
            }
            return result
        }
    }

    mutating func decodeNil() throws -> Bool {
        do {
            let _: xpc_object_t = try xpcDecodingObjectOfType(Void?.self, xpcType: XPC_TYPE_NULL)
            return true
        } catch DecodingError.typeMismatch(_, _) {
            self.currentIndex += 1
            return false
        }
    }

    mutating func decode(_: Bool.Type) throws -> Bool {
        try xpc_bool_get_value(self.xpcDecodingObjectOfType(Bool.self, xpcType: XPC_TYPE_BOOL))
    }

    mutating func decode(_: String.Type) throws -> String {
        let stringObject: xpc_object_t = try xpcDecodingObjectOfType(String.self, xpcType: XPC_TYPE_STRING)

        return UnsafeBufferPointer(
            start: xpc_string_get_string_ptr(stringObject),
            count: xpc_string_get_length(stringObject)
        )
        .withMemoryRebound(to: UInt8.self) {
            String(decoding: $0, as: UTF8.self)
        }
    }

    mutating func decode(_: Double.Type) throws -> Double {
        try xpc_double_get_value(self.xpcDecodingObjectOfType(Double.self, xpcType: XPC_TYPE_DOUBLE))
    }

    mutating func decode(_: Float.Type) throws -> Float {
        try self.xpcDecodingObjectOfType(Float.self, xpcType: XPC_TYPE_DOUBLE) {
            guard let result = Float(exactly: xpc_double_get_value($1)) else {
                throw DecodingError.dataCorruptedError(in: $0, debugDescription: "value doesn't fit in Float")
            }
            return result
        }
    }

    mutating func decode(_: Int.Type) throws -> Int { try self.xpcDecodingObjectOfIntegerType(Int.self) }
    mutating func decode(_: Int8.Type) throws -> Int8 { try self.xpcDecodingObjectOfIntegerType(Int8.self) }
    mutating func decode(_: Int16.Type) throws -> Int16 { try self.xpcDecodingObjectOfIntegerType(Int16.self) }
    mutating func decode(_: Int32.Type) throws -> Int32 { try self.xpcDecodingObjectOfIntegerType(Int32.self) }
    mutating func decode(_: Int64.Type) throws -> Int64 { try self.xpcDecodingObjectOfIntegerType(Int64.self) }
    mutating func decode(_: UInt.Type) throws -> UInt { try self.xpcDecodingObjectOfIntegerType(UInt.self) }
    mutating func decode(_: UInt8.Type) throws -> UInt8 { try self.xpcDecodingObjectOfIntegerType(UInt8.self) }
    mutating func decode(_: UInt16.Type) throws -> UInt16 { try self.xpcDecodingObjectOfIntegerType(UInt16.self) }
    mutating func decode(_: UInt32.Type) throws -> UInt32 { try self.xpcDecodingObjectOfIntegerType(UInt32.self) }
    mutating func decode(_: UInt64.Type) throws -> UInt64 { try self.xpcDecodingObjectOfIntegerType(UInt64.self) }

    mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        if T.self is Date.Type {
            return try Date(
                timeIntervalSince1970: TimeInterval(xpc_date_get_value(self.xpcDecodingObjectOfType(
                    Date.self,
                    xpcType: XPC_TYPE_DATE
                )))
            ) as! T
        } else if T.self is UUID.Type {
            return try xpc_uuid_get_bytes(self.xpcDecodingObjectOfType(UUID.self, xpcType: XPC_TYPE_UUID))!
                .withMemoryRebound(to: uuid_t.self, capacity: 1) { UUID(uuid: $0.pointee) } as! T
        } else if T.self is Data.Type {
            let object: xpc_object_t = try xpcDecodingObjectOfType(Data.self, xpcType: XPC_TYPE_DATA)

            return Data(bytes: xpc_data_get_bytes_ptr(object)!, count: xpc_data_get_length(object)) as! T
        } else if T.self is XPCObjectContainer.Type {
            guard !self.isAtEnd else {
                throw DecodingError.valueNotFoundError(
                    expectingValueOfType: type,
                    in: self,
                    debugDescription: "no items left in array"
                )
            }
            let object = xpc_array_get_value(topLevelObject, self.currentIndex)
            self.currentIndex += 1
            return XPCObjectContainer(object) as! T
        } else {
            let raw = xpc_array_get_value(topLevelObject, self.currentIndex)
            let decoder = _XPCObjectDecoder(
                decoding: raw,
                atPath: codingPath + [currentIndexKey],
                userInfo: self.decoder.userInfo
            )
            let result = try type.init(from: decoder)
            self.currentIndex += 1
            return result
        }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy _: NestedKey
            .Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try .init(XPCObjectKeyedDecodingContainer(
            decoding: self.xpcDecodingObjectOfType(NestedKey.self, xpcType: XPC_TYPE_DICTIONARY),
            for: self.decoder,
            atPath: self.codingPath + [self.currentIndexKey]
        ))
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try XPCObjectUnkeyedDecodingContainer(
            decoding: self.xpcDecodingObjectOfType([Decodable].self, xpcType: XPC_TYPE_ARRAY),
            for: self.decoder,
            atPath: self.codingPath + [self.currentIndexKey]
        )
    }

    mutating func superDecoder() throws -> Decoder {
        throw DecodingError.valueNotFoundError(
            expectingValueOfType: _XPCObjectDecoder.self,
            atCodingPath: self.codingPath,
            debugDescription: "super is not supported"
        )
    }
}

private struct XPCObjectSingleValueDecodingContainer: SingleValueDecodingContainer {
    private let decoder: _XPCObjectDecoder
    private let topLevelObject: xpc_object_t

    init(decoding topLevelObject: xpc_object_t, for decoder: _XPCObjectDecoder, atPath: [CodingKey]) {
        self.decoder = decoder
        self.topLevelObject = topLevelObject
        self.codingPath = atPath
    }

    let codingPath: [CodingKey]

    private func xpcDecodingObjectOfType(_ type: (some Any).Type, xpcType: xpc_type_t) throws -> xpc_object_t {
        guard xpc_get_type(self.topLevelObject) == xpcType else {
            throw DecodingError.typeMismatchError(expecting: type, butFound: self.topLevelObject, in: self)
        }
        return self.topLevelObject
    }

    private func xpcDecodingObjectOfIntegerType<T: SignedInteger>(_ type: T.Type) throws -> T {
        guard let result = try type.init(exactly: xpc_int64_get_value(xpcDecodingObjectOfType(
            type,
            xpcType: XPC_TYPE_INT64
        ))) else {
            throw DecodingError.dataCorruptedError(in: self, debugDescription: "value doesn't fit in \(type)")
        }
        return result
    }

    private func xpcDecodingObjectOfIntegerType<T: UnsignedInteger>(_ type: T.Type) throws -> T {
        guard let result = try type.init(exactly: xpc_uint64_get_value(xpcDecodingObjectOfType(
            type,
            xpcType: XPC_TYPE_UINT64
        ))) else {
            throw DecodingError.dataCorruptedError(in: self, debugDescription: "value doesn't fit in \(type)")
        }
        return result
    }

    func decodeNil() -> Bool { xpc_get_type(self.topLevelObject) == XPC_TYPE_NULL }

    func decode(_: Bool.Type) throws -> Bool {
        try xpc_bool_get_value(self.xpcDecodingObjectOfType(Bool.self, xpcType: XPC_TYPE_BOOL))
    }

    func decode(_: String.Type) throws -> String {
        let stringObject = try xpcDecodingObjectOfType(String.self, xpcType: XPC_TYPE_STRING)

        return UnsafeBufferPointer(
            start: xpc_string_get_string_ptr(stringObject),
            count: xpc_string_get_length(stringObject)
        )
        .withMemoryRebound(to: UInt8.self) {
            String(decoding: $0, as: UTF8.self)
        }
    }

    func decode(_: Double.Type) throws -> Double {
        try xpc_double_get_value(self.xpcDecodingObjectOfType(Double.self, xpcType: XPC_TYPE_DOUBLE))
    }

    func decode(_: Float.Type) throws -> Float {
        guard let result = try Float(exactly: xpc_double_get_value(xpcDecodingObjectOfType(
            Float.self,
            xpcType: XPC_TYPE_DOUBLE
        ))) else {
            throw DecodingError.dataCorruptedError(in: self, debugDescription: "value doesn't fit in Float")
        }
        return result
    }

    func decode(_: Int.Type) throws -> Int { try self.xpcDecodingObjectOfIntegerType(Int.self) }
    func decode(_: Int8.Type) throws -> Int8 { try self.xpcDecodingObjectOfIntegerType(Int8.self) }
    func decode(_: Int16.Type) throws -> Int16 { try self.xpcDecodingObjectOfIntegerType(Int16.self) }
    func decode(_: Int32.Type) throws -> Int32 { try self.xpcDecodingObjectOfIntegerType(Int32.self) }
    func decode(_: Int64.Type) throws -> Int64 { try self.xpcDecodingObjectOfIntegerType(Int64.self) }
    func decode(_: UInt.Type) throws -> UInt { try self.xpcDecodingObjectOfIntegerType(UInt.self) }
    func decode(_: UInt8.Type) throws -> UInt8 { try self.xpcDecodingObjectOfIntegerType(UInt8.self) }
    func decode(_: UInt16.Type) throws -> UInt16 { try self.xpcDecodingObjectOfIntegerType(UInt16.self) }
    func decode(_: UInt32.Type) throws -> UInt32 { try self.xpcDecodingObjectOfIntegerType(UInt32.self) }
    func decode(_: UInt64.Type) throws -> UInt64 { try self.xpcDecodingObjectOfIntegerType(UInt64.self) }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        if T.self is Date.Type {
            return try Date(
                timeIntervalSince1970: TimeInterval(xpc_date_get_value(self.xpcDecodingObjectOfType(
                    Date.self,
                    xpcType: XPC_TYPE_DATE
                )))
            ) as! T
        } else if T.self is UUID.Type {
            return try xpc_uuid_get_bytes(self.xpcDecodingObjectOfType(UUID.self, xpcType: XPC_TYPE_UUID))!
                .withMemoryRebound(to: uuid_t.self, capacity: 1) { UUID(uuid: $0.pointee) } as! T
        } else if T.self is Data.Type {
            let object: xpc_object_t = try xpcDecodingObjectOfType(Data.self, xpcType: XPC_TYPE_DATA)

            return Data(bytes: xpc_data_get_bytes_ptr(object)!, count: xpc_data_get_length(object)) as! T
        } else if T.self is XPCObjectContainer.Type {
            return XPCObjectContainer(self.topLevelObject) as! T
        } else {
            let decoder = _XPCObjectDecoder(
                decoding: topLevelObject,
                atPath: self.codingPath,
                userInfo: self.decoder.userInfo
            )

            return try type.init(from: decoder)
        }
    }
}

@propertyWrapper
internal struct XPCObjectContainer: Codable {
    internal var object: xpc_object_t

    internal init(_ object: xpc_object_t) { self.object = object }
    internal init(wrappedValue: xpc_object_t) { self.init(wrappedValue) }

    @available(
        *,
        deprecated,
        message: "Decoding an XPCObjectContainer as the top level object is not supported and will result in a fatal error."
    )
    internal init(from _: Decoder) throws { fatalError("XPCObjectContainer cannot be directly encoded.") }
    @available(
        *,
        deprecated,
        message: "Encoding an XPCObjectContainer as the top level object is not supported and will result in a fatal error."
    )
    internal func encode(to _: Encoder) throws { fatalError("XPCObjectContainer cannot be encoded directly.") }

    internal var wrappedValue: xpc_object_t {
        get { self.object }
        set { self.object = newValue }
    }
}
