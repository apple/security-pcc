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

// MARK: CFPreferenceValue

private protocol CFPreferenceValue {
    static func cast(from value: CFPropertyList) -> Self?
}

extension Bool: CFPreferenceValue {
    fileprivate static func cast(from value: CFPropertyList) -> Self? {
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        let cfBool = value as! CFBoolean
        return CFBooleanGetValue(cfBool)
    }
}

extension String: CFPreferenceValue {
    fileprivate static func cast(from value: CFPropertyList) -> Self? {
        guard CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return (value as! CFString) as String
    }
}

extension [String: CFPropertyList]: CFPreferenceValue {
    fileprivate static func cast(from value: CFPropertyList) -> Self? {
        guard CFGetTypeID(value) == CFDictionaryGetTypeID() else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: ((value as! CFDictionary) as NSDictionary).lazy.compactMap {
            if let key = $0 as? String {
                return (key, $1 as CFPropertyList)
            } else {
                return nil
            }
        })
    }
}

extension [CFPropertyList]: CFPreferenceValue {
    fileprivate static func cast(from value: CFPropertyList) -> Self? {
        guard CFGetTypeID(value) == CFArrayGetTypeID() else {
            return nil
        }
        return ((value as! CFArray) as NSArray).map { $0 as CFPropertyList }
    }
}

// MARK: CFPreferenceNumber

private protocol CFPreferenceNumber {
    init?(exactly number: NSNumber)
}

enum CFPreferenceNumberCastResult<Number> {
    case typeMismatch
    case numberDoesNotFitExactly
    case success(Number)
}

extension CFPreferenceNumber {
    static func cast(from value: CFPropertyList) -> CFPreferenceNumberCastResult<Self> {
        guard CFGetTypeID(value) == CFNumberGetTypeID() else {
            return .typeMismatch
        }
        guard let value = Self(exactly: value as! CFNumber) else {
            return .numberDoesNotFitExactly
        }

        return .success(value)
    }
}

extension Int: CFPreferenceNumber {}
extension Int8: CFPreferenceNumber {}
extension Int16: CFPreferenceNumber {}
extension Int32: CFPreferenceNumber {}
extension Int64: CFPreferenceNumber {}

extension UInt: CFPreferenceNumber {}
extension UInt8: CFPreferenceNumber {}
extension UInt16: CFPreferenceNumber {}
extension UInt32: CFPreferenceNumber {}
extension UInt64: CFPreferenceNumber {}

extension Float: CFPreferenceNumber {}
extension Double: CFPreferenceNumber {}

// MARK: PreferenceDecoder

public enum CFPreferenceDecoderError: Error {
    case preferenceRootDecoderDoesNotSupportUnkeyedDecoding
}

public struct CFPreferenceDecoder {
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public init() {}

    public func decode<Value: Decodable>(_: Value.Type = Value.self, from preferences: CFPreferences) throws -> Value {
        let decoder = PreferenceRootDecoderImplementation(preferences: preferences, userInfo: userInfo)
        return try Value(from: decoder)
    }
}

struct PreferenceRootDecoderImplementation: Decoder {
    var preferences: CFPreferences

    var userInfo: [CodingUserInfoKey: Any]

    var codingPath: [CodingKey] { [] }

    func container<Key>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        .init(PreferenceRootKeyedContainerDecoder(preferences: self.preferences, userInfo: self.userInfo))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw CFPreferenceDecoderError.preferenceRootDecoderDoesNotSupportUnkeyedDecoding
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        self
    }
}

extension PreferenceRootDecoderImplementation: SingleValueDecodingContainer {
    func decodeNil() -> Bool {
        false
    }

    private func _decode<Value>(as _: Value.Type = Value.self) throws -> Never {
        throw DecodingError.typeMismatch(Value.self, DecodingError.Context(
            codingPath: self.codingPath,
            debugDescription: "Preference root can never decode single value of type \(Value.self). The first level must always be keyed."
        ))
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try self._decode(as: type)
    }

    func decode(_ type: String.Type) throws -> String {
        try self._decode(as: type)
    }

    func decode(_ type: Double.Type) throws -> Double {
        try self._decode(as: type)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try self._decode(as: type)
    }

    func decode(_ type: Int.Type) throws -> Int {
        try self._decode(as: type)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try self._decode(as: type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try self._decode(as: type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try self._decode(as: type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try self._decode(as: type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        try self._decode(as: type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try self._decode(as: type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try self._decode(as: type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try self._decode(as: type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try self._decode(as: type)
    }

    func decode<T>(_: T.Type) throws -> T where T: Decodable {
        try T(from: self)
    }
}

struct PreferenceRootKeyedContainerDecoder<Key: CodingKey>: KeyedDecodingContainerProtocol {
    var preferences: CFPreferences
    var userInfo: [CodingUserInfoKey: Any]
    var allKeys: [Key] { [] }
    var codingPath: [CodingKey] { [] }

    func contains(_ key: Key) -> Bool {
        self.preferences.contains(key.stringValue)
    }

    private func _decoder(forKey key: Key) throws -> SingleValuePreferenceDecoder {
        guard let value = preferences.getValue(forKey: key.stringValue) else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: self.codingPath + CollectionOfOne(key as CodingKey),
                debugDescription: "value not found for key \(key)"
            ))
        }

        return SingleValuePreferenceDecoder(value: value, codingPath: [key], userInfo: self.userInfo)
    }

    func decodeNil(forKey _: Key) throws -> Bool {
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        try self._decoder(forKey: key).decode(type)
    }

    func nestedContainer<NestedKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        try self._decoder(forKey: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try self._decoder(forKey: key).unkeyedContainer()
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        try self._decoder(forKey: key)
    }

    func superDecoder() throws -> any Decoder {
        PreferenceRootDecoderImplementation(preferences: self.preferences, userInfo: self.userInfo)
    }
}

struct SingleValuePreferenceDecoder: Decoder {
    /// This can be any of the following types
    /// - CFString
    /// - CFNumber
    /// - CFBoolean
    /// - CFDate
    /// - CFData
    /// - CFArray
    /// - CFDictionary
    var value: CFPropertyList
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]

    private func _decode<Value: CFPreferenceValue>(
        as _: Value.Type = Value.self
    ) throws -> Value {
        guard let typedValue = Value.cast(from: value) else {
            throw DecodingError.typeMismatch(Value.self, DecodingError.Context(
                codingPath: self.codingPath,
                debugDescription: "could not cast value \(self.value) to type \(Value.self)"
            ))
        }

        return typedValue
    }

    private func _decode<Value: CFPreferenceNumber>(
        as _: Value.Type = Value.self
    ) throws -> Value {
        switch Value.cast(from: self.value) {
        case .typeMismatch:
            throw DecodingError.typeMismatch(Value.self, DecodingError.Context(
                codingPath: self.codingPath,
                debugDescription: "could not cast value \(self.value) to type \(Value.self)"
            ))
        case .numberDoesNotFitExactly:
            throw DecodingError.typeMismatch(Value.self, DecodingError.Context(
                codingPath: self.codingPath,
                debugDescription: "value \(self.value) does not fit exactly into type \(Value.self)"
            ))
        case .success(let value):
            return value
        }
    }

    func container<Key>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        return try KeyedDecodingContainer(KeyedPreferenceDecodingContainer<Key>(
            container: self._decode(as: [String: CFPropertyList].self),
            codingPath: self.codingPath,
            userInfo: self.userInfo
        ))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try UnkeyedPreferenceDecodingContainer(
            array: self._decode(as: [CFPropertyList].self),
            codingPath: self.codingPath,
            userInfo: self.userInfo
        )
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        self
    }
}

extension SingleValuePreferenceDecoder: SingleValueDecodingContainer {
    func decodeNil() -> Bool {
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try self._decode(as: type)
    }

    func decode(_ type: String.Type) throws -> String {
        try self._decode(as: type)
    }

    func decode(_ type: Double.Type) throws -> Double {
        try self._decode(as: type)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try self._decode(as: type)
    }

    func decode(_ type: Int.Type) throws -> Int {
        try self._decode(as: type)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try self._decode(as: type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try self._decode(as: type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try self._decode(as: type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try self._decode(as: type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        try self._decode(as: type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        try self._decode(as: type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        try self._decode(as: type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        try self._decode(as: type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try self._decode(as: type)
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        if type == URL.self {
            guard let url = try URL(string: self.decode(String.self)) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: self.codingPath,
                        debugDescription: "Invalid URL string."
                    )
                )
            }
            return url as! T
        } else {
            return try T(from: self)
        }
    }
}

struct KeyedPreferenceDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol, Decoder {
    /// This is a `CFDictionary` and the value of this dictionary can be any of the following value:
    /// - CFString
    /// - CFNumber
    /// - CFBoolean
    /// - CFDate
    /// - CFData
    /// - CFArray
    /// - another CFDictionary
    /// https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFPropertyLists/Articles/StructureAndContents.html#//apple_ref/doc/uid/20001171-CJBEJBHH
    var container: [String: CFPropertyList]
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]

    var allKeys: [Key] {
        self.container.keys.compactMap {
            Key(stringValue: $0)
        }
    }

    func contains(_ key: Key) -> Bool {
        self.container[key.stringValue] != nil
    }

    private func _decoder(forKey key: Key) throws -> SingleValuePreferenceDecoder {
        guard let value = container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: self.codingPath + CollectionOfOne(key as CodingKey),
                debugDescription: "value not found for key \(key)"
            ))
        }

        return SingleValuePreferenceDecoder(
            value: value,
            codingPath: self.codingPath + CollectionOfOne(key as CodingKey),
            userInfo: self.userInfo
        )
    }

    func decodeNil(forKey _: Key) throws -> Bool {
        // `CFDictionary`s value can't be `Optional<_>`
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try self._decoder(forKey: key).decode(type)
    }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        try self._decoder(forKey: key).decode(type)
    }

    func nestedContainer<NestedKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        try self._decoder(forKey: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try self._decoder(forKey: key).unkeyedContainer()
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        try self._decoder(forKey: key)
    }

    func superDecoder() throws -> any Decoder {
        self
    }

    func container<NestedKey>(keyedBy _: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey>
    where NestedKey: CodingKey {
        .init(KeyedPreferenceDecodingContainer<NestedKey>(
            container: self.container,
            codingPath: self.codingPath,
            userInfo: self.userInfo
        ))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([CFPropertyList].self, DecodingError.Context(
            codingPath: self.codingPath,
            debugDescription: "a keyed decoding container can not be converted to an unkeyed container"
        ))
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        SingleValuePreferenceDecoder(
            value: self.container as CFDictionary,
            codingPath: self.codingPath,
            userInfo: self.userInfo
        )
    }
}

struct UnkeyedPreferenceDecodingContainer: UnkeyedDecodingContainer {
    /// This is a `CFArray` and the value of this array can be any of the following value:
    /// - CFString
    /// - CFNumber
    /// - CFBoolean
    /// - CFDate
    /// - CFData
    /// - CFDictionary
    /// - another CFArray
    var array: [CFPropertyList]
    var currentIndex: Int
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any]

    var count: Int? {
        self.array.count
    }

    var isAtEnd: Bool {
        self.array.endIndex == self.currentIndex
    }

    init(array: [CFPropertyList], codingPath: [CodingKey], userInfo: [CodingUserInfoKey: Any]) {
        self.array = array
        self.currentIndex = array.startIndex
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    private mutating func _nextDecoder<Value>(
        decode: (SingleValuePreferenceDecoder) throws -> Value
    ) throws -> Value {
        guard self.array.indices.contains(self.currentIndex) else {
            throw DecodingError.valueNotFound(Value.self, DecodingError.Context(
                codingPath: self.codingPath,
                debugDescription: "run out of elements"
            ))
        }

        let value = self.array[self.currentIndex]
        let decoder = SingleValuePreferenceDecoder(value: value, codingPath: codingPath, userInfo: userInfo)

        let decodedValue = try decode(decoder)

        self.array.formIndex(after: &self.currentIndex)

        return decodedValue
    }

    mutating func decodeNil() throws -> Bool {
        false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: String.Type) throws -> String {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        try self._nextDecoder { try $0.decode(type) }
    }

    mutating func decode<T>(_: T.Type) throws -> T where T: Decodable {
        guard self.array.indices.contains(self.currentIndex) else {
            throw DecodingError.valueNotFound(T.self, DecodingError.Context(
                codingPath: self.codingPath,
                debugDescription: "run out of elements"
            ))
        }

        let value = self.array[self.currentIndex]

        let decoder = SingleValuePreferenceDecoder(value: value, codingPath: codingPath, userInfo: userInfo)

        let decodedValue = try decoder.decode(T.self)

        self.array.formIndex(after: &self.currentIndex)

        return decodedValue
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey>
    where NestedKey: CodingKey {
        try self._nextDecoder { try $0.container(keyedBy: type) }
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try self._nextDecoder { try $0.unkeyedContainer() }
    }

    mutating func superDecoder() throws -> any Decoder {
        try SingleValuePreferenceDecoder(
            value: self._nextDecoder { $0.value },
            codingPath: self.codingPath,
            userInfo: self.userInfo
        )
    }
}
