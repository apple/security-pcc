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
//  ClaimsValueCoding.swift
//  CloudAttestationV2
//
//  Created by David Zech on 4/16/26.
//

import Foundation
import Logging

// MARK: - Default Codable Bridge for ValueProtocol

extension Claims.ValueProtocol where Self: Codable {
    private static var logger: Logger { Logger(label: "com.apple.CloudAttestation.ClaimsValueCoding") }

    public init?(_ value: Claims.Value) {
        guard let decoded = try? Self(from: ClaimsValueDecoder(value: value, codingPath: [])) else {
            return nil
        }
        self = decoded
    }

    public var value: Claims.Value {
        let encoder = ClaimsValueEncoder()
        do {
            try self.encode(to: encoder)
        } catch {
            Self.logger.warning(
                "Claims.Value encoding failed; returning empty dictionary",
                metadata: [
                    "type": .string(String(describing: Self.self)),
                    "error": .string(String(describing: error)),
                ]
            )
            return .dictionary([:])
        }
        return encoder.result ?? .dictionary([:])
    }
}

// MARK: - Helpers

private func claimsEncode<T: Encodable>(_ value: T, codingPath: [CodingKey]) throws -> Claims.Value {
    if let v = value as? Claims.Value { return v }
    if let d = value as? Data { return .bytes(d) }
    if let d = value as? Date { return .string(d.formatted(.iso8601)) }
    let encoder = ClaimsValueEncoder(codingPath: codingPath)
    try value.encode(to: encoder)
    guard let result = encoder.result else {
        throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "Failed to produce Claims.Value for \(type(of: value))"))
    }
    return result
}

private func claimsDecode<T: Decodable>(_ type: T.Type, from value: Claims.Value, codingPath: [CodingKey]) throws -> T {
    if type == Data.self {
        guard case .bytes(let data) = value else {
            throw DecodingError.typeMismatch(Data.self, .init(codingPath: codingPath, debugDescription: "Expected .bytes for Data, got \(value)"))
        }
        return data as! T
    }
    if type == Date.self {
        guard case .string(let s) = value else {
            throw DecodingError.typeMismatch(Date.self, .init(codingPath: codingPath, debugDescription: "Expected .string for Date, got \(value)"))
        }
        guard let date = try? Date(s, strategy: .iso8601) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Expected ISO8601 string for Date, got \(s)"))
        }
        return date as! T
    }
    if type == Claims.Value.self {
        return value as! T
    }
    return try T(from: ClaimsValueDecoder(value: value, codingPath: codingPath))
}

// MARK: - Encoder

final class ClaimsValueEncoder: Encoder {
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    var result: Claims.Value?

    init(codingPath: [CodingKey] = []) { self.codingPath = codingPath }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(KeyedEnc<Key>(codingPath: codingPath, encoder: self))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        UnkeyedEnc(codingPath: codingPath, encoder: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        SingleValueEnc(codingPath: codingPath, encoder: self)
    }
}

// MARK: Keyed Encoding

private final class KeyedEnc<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let codingPath: [CodingKey]
    private let encoder: ClaimsValueEncoder
    private var dict: [String: Claims.Value] = [:]
    private var pendingNested: [(key: String, encoder: ClaimsValueEncoder)] = []

    init(codingPath: [CodingKey], encoder: ClaimsValueEncoder) {
        self.codingPath = codingPath
        self.encoder = encoder
    }

    deinit {
        for pending in pendingNested {
            if let v = pending.encoder.result {
                dict[pending.key] = v
            }
        }
        encoder.result = .dictionary(dict)
    }

    func encodeNil(forKey key: Key) throws { dict[key.stringValue] = .null }
    func encode(_ value: Bool, forKey key: Key) throws { dict[key.stringValue] = .bool(value) }
    func encode(_ value: String, forKey key: Key) throws { dict[key.stringValue] = .string(value) }
    func encode(_ value: Double, forKey key: Key) throws {
        throw EncodingError.invalidValue(value, .init(codingPath: codingPath + [key], debugDescription: "Claims.Value does not support floating-point types"))
    }
    func encode(_ value: Float, forKey key: Key) throws {
        throw EncodingError.invalidValue(value, .init(codingPath: codingPath + [key], debugDescription: "Claims.Value does not support floating-point types"))
    }
    func encode(_ value: Int, forKey key: Key) throws { dict[key.stringValue] = .int(Int64(value)) }
    func encode(_ value: Int8, forKey key: Key) throws { dict[key.stringValue] = .int(Int64(value)) }
    func encode(_ value: Int16, forKey key: Key) throws { dict[key.stringValue] = .int(Int64(value)) }
    func encode(_ value: Int32, forKey key: Key) throws { dict[key.stringValue] = .int(Int64(value)) }
    func encode(_ value: Int64, forKey key: Key) throws { dict[key.stringValue] = .int(value) }
    func encode(_ value: UInt, forKey key: Key) throws { dict[key.stringValue] = .int(Int64(bitPattern: UInt64(value))) }
    func encode(_ value: UInt8, forKey key: Key) throws { dict[key.stringValue] = .int(Int64(value)) }
    func encode(_ value: UInt16, forKey key: Key) throws { dict[key.stringValue] = .int(Int64(value)) }
    func encode(_ value: UInt32, forKey key: Key) throws { dict[key.stringValue] = .int(Int64(value)) }
    func encode(_ value: UInt64, forKey key: Key) throws { dict[key.stringValue] = .int(Int64(bitPattern: value)) }
    func encode<T: Encodable>(_ value: T, forKey key: Key) throws { dict[key.stringValue] = try claimsEncode(value, codingPath: codingPath + [key]) }

    func nestedContainer<N: CodingKey>(keyedBy keyType: N.Type, forKey key: Key) -> KeyedEncodingContainer<N> {
        let nested = ClaimsValueEncoder(codingPath: codingPath + [key])
        pendingNested.append((key.stringValue, nested))
        return KeyedEncodingContainer(KeyedEnc<N>(codingPath: codingPath + [key], encoder: nested))
    }

    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let nested = ClaimsValueEncoder(codingPath: codingPath + [key])
        pendingNested.append((key.stringValue, nested))
        return UnkeyedEnc(codingPath: codingPath + [key], encoder: nested)
    }

    func superEncoder() -> Encoder {
        let nested = ClaimsValueEncoder(codingPath: codingPath)
        pendingNested.append(("super", nested))
        return nested
    }

    func superEncoder(forKey key: Key) -> Encoder {
        let nested = ClaimsValueEncoder(codingPath: codingPath + [key])
        pendingNested.append((key.stringValue, nested))
        return nested
    }
}

// MARK: Unkeyed Encoding

private final class UnkeyedEnc: UnkeyedEncodingContainer {
    let codingPath: [CodingKey]
    private let encoder: ClaimsValueEncoder
    private var array: [Claims.Value] = []
    private var pendingNested: [(index: Int, encoder: ClaimsValueEncoder)] = []
    var count: Int { array.count }

    init(codingPath: [CodingKey], encoder: ClaimsValueEncoder) {
        self.codingPath = codingPath
        self.encoder = encoder
    }

    deinit {
        for pending in pendingNested {
            if let v = pending.encoder.result, pending.index < array.count {
                array[pending.index] = v
            }
        }
        encoder.result = .array(array)
    }

    func encodeNil() throws { array.append(.null) }
    func encode(_ value: Bool) throws { array.append(.bool(value)) }
    func encode(_ value: String) throws { array.append(.string(value)) }
    func encode(_ value: Double) throws {
        throw EncodingError.invalidValue(value, .init(codingPath: codingPath + [IndexKey(intValue: count)], debugDescription: "Claims.Value does not support floating-point types"))
    }
    func encode(_ value: Float) throws {
        throw EncodingError.invalidValue(value, .init(codingPath: codingPath + [IndexKey(intValue: count)], debugDescription: "Claims.Value does not support floating-point types"))
    }
    func encode(_ value: Int) throws { array.append(.int(Int64(value))) }
    func encode(_ value: Int8) throws { array.append(.int(Int64(value))) }
    func encode(_ value: Int16) throws { array.append(.int(Int64(value))) }
    func encode(_ value: Int32) throws { array.append(.int(Int64(value))) }
    func encode(_ value: Int64) throws { array.append(.int(value)) }
    func encode(_ value: UInt) throws { array.append(.int(Int64(bitPattern: UInt64(value)))) }
    func encode(_ value: UInt8) throws { array.append(.int(Int64(value))) }
    func encode(_ value: UInt16) throws { array.append(.int(Int64(value))) }
    func encode(_ value: UInt32) throws { array.append(.int(Int64(value))) }
    func encode(_ value: UInt64) throws { array.append(.int(Int64(bitPattern: value))) }
    func encode<T: Encodable>(_ value: T) throws { array.append(try claimsEncode(value, codingPath: codingPath + [IndexKey(intValue: count)])) }

    func nestedContainer<N: CodingKey>(keyedBy keyType: N.Type) -> KeyedEncodingContainer<N> {
        let index = array.count
        array.append(.null)
        let nested = ClaimsValueEncoder(codingPath: codingPath + [IndexKey(intValue: index)])
        pendingNested.append((index, nested))
        return KeyedEncodingContainer(KeyedEnc<N>(codingPath: codingPath + [IndexKey(intValue: index)], encoder: nested))
    }

    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let index = array.count
        array.append(.null)
        let nested = ClaimsValueEncoder(codingPath: codingPath + [IndexKey(intValue: index)])
        pendingNested.append((index, nested))
        return UnkeyedEnc(codingPath: codingPath + [IndexKey(intValue: index)], encoder: nested)
    }

    func superEncoder() -> Encoder {
        let index = array.count
        array.append(.null)
        let nested = ClaimsValueEncoder(codingPath: codingPath + [IndexKey(intValue: index)])
        pendingNested.append((index, nested))
        return nested
    }
}

// MARK: Single Value Encoding

private struct SingleValueEnc: SingleValueEncodingContainer {
    let codingPath: [CodingKey]
    let encoder: ClaimsValueEncoder

    mutating func encodeNil() throws { encoder.result = .null }
    mutating func encode(_ value: Bool) throws { encoder.result = .bool(value) }
    mutating func encode(_ value: String) throws { encoder.result = .string(value) }
    mutating func encode(_ value: Double) throws {
        throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "Claims.Value does not support floating-point types"))
    }
    mutating func encode(_ value: Float) throws {
        throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "Claims.Value does not support floating-point types"))
    }
    mutating func encode(_ value: Int) throws { encoder.result = .int(Int64(value)) }
    mutating func encode(_ value: Int8) throws { encoder.result = .int(Int64(value)) }
    mutating func encode(_ value: Int16) throws { encoder.result = .int(Int64(value)) }
    mutating func encode(_ value: Int32) throws { encoder.result = .int(Int64(value)) }
    mutating func encode(_ value: Int64) throws { encoder.result = .int(value) }
    mutating func encode(_ value: UInt) throws { encoder.result = .int(Int64(bitPattern: UInt64(value))) }
    mutating func encode(_ value: UInt8) throws { encoder.result = .int(Int64(value)) }
    mutating func encode(_ value: UInt16) throws { encoder.result = .int(Int64(value)) }
    mutating func encode(_ value: UInt32) throws { encoder.result = .int(Int64(value)) }
    mutating func encode(_ value: UInt64) throws { encoder.result = .int(Int64(bitPattern: value)) }
    mutating func encode<T: Encodable>(_ value: T) throws { encoder.result = try claimsEncode(value, codingPath: codingPath) }
}

// MARK: - Decoder

struct ClaimsValueDecoder: Decoder {
    let value: Claims.Value
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .dictionary(let dict) = value else {
            throw DecodingError.typeMismatch([String: Claims.Value].self, .init(codingPath: codingPath, debugDescription: "Expected .dictionary, got \(value)"))
        }
        return KeyedDecodingContainer(KeyedDec<Key>(dict: dict, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let array) = value else {
            throw DecodingError.typeMismatch([Claims.Value].self, .init(codingPath: codingPath, debugDescription: "Expected .array, got \(value)"))
        }
        return UnkeyedDec(array: array, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        SingleValueDec(value: value, codingPath: codingPath)
    }
}

// MARK: Keyed Decoding

private struct KeyedDec<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let dict: [String: Claims.Value]
    let codingPath: [CodingKey]
    var allKeys: [Key] { dict.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { dict[key.stringValue] != nil }

    private func require(_ key: Key) throws -> Claims.Value {
        guard let v = dict[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Key '\(key.stringValue)' not found"))
        }
        return v
    }

    private func requireInt(_ key: Key) throws -> Int64 {
        guard case .int(let i) = try require(key) else {
            throw DecodingError.typeMismatch(Int64.self, .init(codingPath: codingPath + [key], debugDescription: "Expected .int"))
        }
        return i
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let v = dict[key.stringValue] else { return true }
        if case .null = v { return true }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        guard case .bool(let b) = try require(key) else {
            throw DecodingError.typeMismatch(Bool.self, .init(codingPath: codingPath + [key], debugDescription: "Expected .bool"))
        }
        return b
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        guard case .string(let s) = try require(key) else {
            throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath + [key], debugDescription: "Expected .string"))
        }
        return s
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        throw DecodingError.typeMismatch(Double.self, .init(codingPath: codingPath + [key], debugDescription: "Claims.Value does not support floating-point types"))
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        throw DecodingError.typeMismatch(Float.self, .init(codingPath: codingPath + [key], debugDescription: "Claims.Value does not support floating-point types"))
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { Int(truncatingIfNeeded: try requireInt(key)) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { Int8(truncatingIfNeeded: try requireInt(key)) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { Int16(truncatingIfNeeded: try requireInt(key)) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { Int32(truncatingIfNeeded: try requireInt(key)) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try requireInt(key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { UInt(truncatingIfNeeded: try requireInt(key)) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { UInt8(truncatingIfNeeded: try requireInt(key)) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { UInt16(truncatingIfNeeded: try requireInt(key)) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { UInt32(truncatingIfNeeded: try requireInt(key)) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { UInt64(bitPattern: try requireInt(key)) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try claimsDecode(type, from: require(key), codingPath: codingPath + [key])
    }

    func nestedContainer<N: CodingKey>(keyedBy type: N.Type, forKey key: Key) throws -> KeyedDecodingContainer<N> {
        guard case .dictionary(let nested) = try require(key) else {
            throw DecodingError.typeMismatch([String: Claims.Value].self, .init(codingPath: codingPath + [key], debugDescription: "Expected .dictionary"))
        }
        return KeyedDecodingContainer(KeyedDec<N>(dict: nested, codingPath: codingPath + [key]))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        guard case .array(let nested) = try require(key) else {
            throw DecodingError.typeMismatch([Claims.Value].self, .init(codingPath: codingPath + [key], debugDescription: "Expected .array"))
        }
        return UnkeyedDec(array: nested, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> any Decoder {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Super decoding is not supported by Claims.Value decoding"))
    }
    func superDecoder(forKey key: Key) throws -> any Decoder {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath + [key], debugDescription: "Super decoding is not supported by Claims.Value decoding"))
    }
}

// MARK: Unkeyed Decoding

private final class UnkeyedDec: UnkeyedDecodingContainer {
    let array: [Claims.Value]
    let codingPath: [CodingKey]
    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }
    var currentIndex: Int = 0

    init(array: [Claims.Value], codingPath: [CodingKey]) {
        self.array = array
        self.codingPath = codingPath
    }

    private func next() throws -> Claims.Value {
        guard !isAtEnd else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Unkeyed container exhausted"))
        }
        let v = array[currentIndex]
        currentIndex += 1
        return v
    }

    private func nextInt() throws -> Int64 {
        guard case .int(let i) = try next() else {
            throw DecodingError.typeMismatch(Int64.self, .init(codingPath: codingPath, debugDescription: "Expected .int at index \(currentIndex - 1)"))
        }
        return i
    }

    func decodeNil() throws -> Bool {
        guard !isAtEnd else { return false }
        if case .null = array[currentIndex] {
            currentIndex += 1
            return true
        }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let b) = try next() else {
            throw DecodingError.typeMismatch(Bool.self, .init(codingPath: codingPath, debugDescription: "Expected .bool"))
        }
        return b
    }

    func decode(_ type: String.Type) throws -> String {
        guard case .string(let s) = try next() else {
            throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath, debugDescription: "Expected .string"))
        }
        return s
    }

    func decode(_ type: Double.Type) throws -> Double {
        throw DecodingError.typeMismatch(Double.self, .init(codingPath: codingPath, debugDescription: "Claims.Value does not support floating-point types"))
    }
    func decode(_ type: Float.Type) throws -> Float {
        throw DecodingError.typeMismatch(Float.self, .init(codingPath: codingPath, debugDescription: "Claims.Value does not support floating-point types"))
    }
    func decode(_ type: Int.Type) throws -> Int { Int(truncatingIfNeeded: try nextInt()) }
    func decode(_ type: Int8.Type) throws -> Int8 { Int8(truncatingIfNeeded: try nextInt()) }
    func decode(_ type: Int16.Type) throws -> Int16 { Int16(truncatingIfNeeded: try nextInt()) }
    func decode(_ type: Int32.Type) throws -> Int32 { Int32(truncatingIfNeeded: try nextInt()) }
    func decode(_ type: Int64.Type) throws -> Int64 { try nextInt() }
    func decode(_ type: UInt.Type) throws -> UInt { UInt(truncatingIfNeeded: try nextInt()) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { UInt8(truncatingIfNeeded: try nextInt()) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { UInt16(truncatingIfNeeded: try nextInt()) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { UInt32(truncatingIfNeeded: try nextInt()) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { UInt64(bitPattern: try nextInt()) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let idx = currentIndex
        return try claimsDecode(type, from: next(), codingPath: codingPath + [IndexKey(intValue: idx)])
    }

    func nestedContainer<N: CodingKey>(keyedBy type: N.Type) throws -> KeyedDecodingContainer<N> {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Nested keyed containers are not supported in unkeyed Claims.Value decoding"))
    }

    func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Nested unkeyed containers are not supported in unkeyed Claims.Value decoding"))
    }

    func superDecoder() throws -> Decoder {
        throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Super decoding is not supported by Claims.Value decoding"))
    }
}

// MARK: Single Value Decoding

private struct SingleValueDec: SingleValueDecodingContainer {
    let value: Claims.Value
    let codingPath: [CodingKey]

    private func requireInt() throws -> Int64 {
        guard case .int(let i) = value else {
            throw DecodingError.typeMismatch(Int64.self, .init(codingPath: codingPath, debugDescription: "Expected .int"))
        }
        return i
    }

    func decodeNil() -> Bool {
        if case .null = value { return true }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let b) = value else {
            throw DecodingError.typeMismatch(Bool.self, .init(codingPath: codingPath, debugDescription: "Expected .bool"))
        }
        return b
    }

    func decode(_ type: String.Type) throws -> String {
        guard case .string(let s) = value else {
            throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath, debugDescription: "Expected .string"))
        }
        return s
    }

    func decode(_ type: Double.Type) throws -> Double {
        throw DecodingError.typeMismatch(Double.self, .init(codingPath: codingPath, debugDescription: "Claims.Value does not support floating-point types"))
    }
    func decode(_ type: Float.Type) throws -> Float {
        throw DecodingError.typeMismatch(Float.self, .init(codingPath: codingPath, debugDescription: "Claims.Value does not support floating-point types"))
    }
    func decode(_ type: Int.Type) throws -> Int { try Int(truncatingIfNeeded: requireInt()) }
    func decode(_ type: Int8.Type) throws -> Int8 { try Int8(truncatingIfNeeded: requireInt()) }
    func decode(_ type: Int16.Type) throws -> Int16 { try Int16(truncatingIfNeeded: requireInt()) }
    func decode(_ type: Int32.Type) throws -> Int32 { try Int32(truncatingIfNeeded: requireInt()) }
    func decode(_ type: Int64.Type) throws -> Int64 { try requireInt() }
    func decode(_ type: UInt.Type) throws -> UInt { try UInt(truncatingIfNeeded: requireInt()) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try UInt8(truncatingIfNeeded: requireInt()) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try UInt16(truncatingIfNeeded: requireInt()) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try UInt32(truncatingIfNeeded: requireInt()) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try UInt64(bitPattern: requireInt()) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T { try claimsDecode(type, from: value, codingPath: codingPath) }
}

// MARK: - Index Coding Key

private struct IndexKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }
}
