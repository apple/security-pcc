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
//  JSEnumEncoder.swift
//  JsonKit
//

import DarwinInitConfig
import Foundation

protocol JSDictContainer: KeyedEncodingContainerProtocol {
    var json: JSON { get }
}

fileprivate enum ValueBox {
    case basic(JSValueBuilder)
    case array(JSArrayBuilder)
    case dict(any JSDictContainer)
}

extension ValueBox {
    public var json: JSON {
        switch self {
        case .basic(let builder):
            return builder.json
        case .array(let builder):
            return builder.json
        case .dict(let container):
            return container.json
        }
    }
}

extension ValueBox {

    static func `null`(at path: [any CodingKey], context: Context) -> ValueBox {
        .basic(JSValueBuilder.null(at: path, context: context))
    }

    static func basic(value: JSON, at path: [any CodingKey], context: Context) -> ValueBox {
        .basic(JSValueBuilder(basic: value, at: path, context: context))
    }
}

fileprivate struct Context {
    var userInfo: [CodingUserInfoKey: Any] = [:]
    var dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate
    var dataEncodingStrategy: JSONEncoder.DataEncodingStrategy = .base64
}

fileprivate final class JSValueBuilder: SingleValueEncodingContainer {

    public var codingPath: [any CodingKey] = []
    private var _value: JSON?
    private let context: Context

    var value: JSON? {
        get {
            return self._value
        }

        set {
            guard self._value == nil else {
                preconditionFailure("value already set")
            }
            self._value = newValue
        }
    }

    var json: JSON {
        return self.value ?? .null
    }

    fileprivate init(at path: [any CodingKey], context: Context) {
        self.codingPath = path
        self.context = context
        self._value = nil
    }

    fileprivate init(basic: JSON, at path: [any CodingKey], context: Context) {
        self.codingPath = path
        self.context = context
        self._value = basic
    }

    static func `null`(at path: [any CodingKey], context: Context) -> JSValueBuilder {
        .init(basic: .null, at: path, context: context)
    }

    // MARK: encode

    func encode(_ value: Int) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: Int8) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: Int16) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: Int32) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: Int64) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: UInt) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: UInt8) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: UInt16) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: UInt32) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: UInt64) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: Int128) throws {
        self.value = .int(value)
    }

    func encode(_ value: UInt128) throws {
        self.value = .int(Int128(value))
    }

    func encode(_ value: Float) throws {
        self.value = .number(Double(value))
    }

    func encode(_ value: Double) throws {
        self.value = .number(value)
    }

    func encode(_ value: String) throws {
        self.value = .string(value)
    }

    func encode(_ value: Bool) throws {
        self.value = .bool(value)
    }

    func encodeNil() throws {
        self.value = .null
    }

    func encode<T>(_ value: T) throws where T: Encodable {
        if let url = value as? URL {
            self.value = .string(url.absoluteString)
        } else if let duration = value as? Duration {
            // Convert Duration to a string format that Duration(argument:) can parse
            let components = duration.components
            let totalSeconds = components.seconds
            self.value = .string("\(totalSeconds)s")
        } else if let date = value as? Date {
            try encodeDate(date)
        } else if let data = value as? Data {
            try encodeData(data)
        } else {
            let encoder = JSEnumEncoder(at: self.codingPath, context: self.context)
            try value.encode(to: encoder)
            if let v = encoder.value {
                self.value = v.json
            }
        }
    }

    private func encodeDate(_ date: Date) throws {
        switch context.dateEncodingStrategy {
        case .secondsSince1970:
            self.value = .number(date.timeIntervalSince1970)
        case .millisecondsSince1970:
            self.value = .number(date.timeIntervalSince1970 * 1000)
        case .iso8601:
            let formatter = ISO8601DateFormatter()
            self.value = .string(formatter.string(from: date))
        case .formatted(let formatter):
            self.value = .string(formatter.string(from: date))
        case .custom(let closure):
            let encoder = JSEnumEncoder(at: self.codingPath, context: self.context)
            try closure(date, encoder)
            if let v = encoder.value {
                self.value = v.json
            }
        case .deferredToDate:
            fallthrough
        @unknown default:
            let encoder = JSEnumEncoder(at: self.codingPath, context: self.context)
            try date.encode(to: encoder)
            if let v = encoder.value {
                self.value = v.json
            }
        }
    }

    private func encodeData(_ data: Data) throws {
        switch context.dataEncodingStrategy {
        case .base64:
            self.value = .string(data.base64EncodedString())
        case .custom(let closure):
            let encoder = JSEnumEncoder(at: self.codingPath, context: self.context)
            try closure(data, encoder)
            if let v = encoder.value {
                self.value = v.json
            }
        case .deferredToData:
            fallthrough
        @unknown default:
            let encoder = JSEnumEncoder(at: self.codingPath, context: self.context)
            try data.encode(to: encoder)
            if let v = encoder.value {
                self.value = v.json
            }
        }
    }

}

fileprivate final class JSArrayBuilder: UnkeyedEncodingContainer {
    typealias IndexKey = JSEnumDecoder.IndexKey

    var array: [ValueBox] = []
    var codingPath: [any CodingKey]
    private let context: Context

    fileprivate init(at path: [any CodingKey], context: Context) {
        self.array = []
        self.codingPath = path
        self.context = context
    }

    var count: Int {
        return array.count
    }

    var json: JSON {
        .array(
            self.array.map(\.json)
        )
    }

    func makeCodingPath() -> [any CodingKey] {
        self.codingPath + [IndexKey(intValue: self.count)]
    }

    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey : CodingKey {
        let path = self.makeCodingPath()
        let builder = JSDictBuilder<NestedKey>(at: path, context: self.context)
        array.append(.dict(builder))
        return KeyedEncodingContainer(builder)
    }

    func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let path = self.makeCodingPath()
        let builder = JSArrayBuilder(at: path, context: self.context)
        array.append(.array(builder))
        return builder
    }

    func encode<T>(_ value: T) throws where T: Encodable {
        let path = makeCodingPath()
        let builder = JSValueBuilder(at: path, context: self.context)
        try builder.encode(value)
        array.append(.basic(builder))
    }

    func _builder(_ block: (JSValueBuilder) throws -> Void) rethrows {
        let path = makeCodingPath()
        let builder = JSValueBuilder(at: path, context: self.context)
        try block(builder)
        array.append(ValueBox.basic(builder))
    }

    func encode(_ value: Bool) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: String) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: Float) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: Double) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int8) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int16) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int32) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int64) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt8) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt16) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt32) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt64) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int128) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt128) throws {
        try _builder() {
            try $0.encode(value)
        }
    }

    func encodeNil() throws {
        let path = self.makeCodingPath()
        array.append(.basic(JSValueBuilder.null(at: path, context: self.context)))
    }

    func superEncoder() -> any Encoder {
        fatalError("Not Implemented")
    }
}

fileprivate final class JSDictBuilder<Key: CodingKey>: JSDictContainer {

    var codingPath: [any CodingKey]
    var dict: [String: ValueBox] = [:]
    private let context: Context

    fileprivate init(at path: [any CodingKey], context: Context) {
        self.dict = [:]
        self.codingPath = path
        self.context = context
    }

    var json: JSON {
        .dictionary(
            dict.mapValues(\.json)
        )
    }

    func makeCodingPath(forKey key: Key) -> [any CodingKey] {
        return self.codingPath + [key]
    }

    func nestedContainer<NestedKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let path = makeCodingPath(forKey: key)
        let builder = JSDictBuilder<NestedKey>(at: path, context: self.context)
        dict[key.stringValue] = .dict(builder)
        return KeyedEncodingContainer(builder)
    }

    func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let path = makeCodingPath(forKey: key)
        let builder = JSArrayBuilder(at: path, context: self.context)
        dict[key.stringValue] = .array(builder)
        return builder
    }

    func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable{
        let path = makeCodingPath(forKey: key)
        let builder = JSValueBuilder(at: path, context: self.context)
        try builder.encode(value)
        dict[key.stringValue] = .basic(builder)
    }

    func encodeNil(forKey key: Key) throws {
        let path = makeCodingPath(forKey: key)
        dict[key.stringValue] = .null(at: path, context: self.context)
    }

    func _builder(forKey key: Key, _ block: (JSValueBuilder ) throws -> Void) rethrows {
        let path = makeCodingPath(forKey: key)
        let builder = JSValueBuilder(at: path, context: self.context)
        try block(builder)
        dict[key.stringValue] = ValueBox.basic(builder)
    }

    func encode(_ value: Bool, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: String, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: Float, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: Double, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int8, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int16, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int32, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int64, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt8, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt16, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt32, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt64, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: Int128, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func encode(_ value: UInt128, forKey key: Key) throws {
        try _builder(forKey: key) {
            try $0.encode(value)
        }
    }

    func superEncoder() -> any Encoder {
        fatalError("Not implemented")
    }

    func superEncoder(forKey key: Key) -> any Encoder {
        fatalError("Not implemented")
    }
}

open class JSEnumEncoder: Encoder {

    public var codingPath: [any CodingKey]

    fileprivate var value: ValueBox?
    fileprivate var context: Context

    init(at path: [any CodingKey] = [], info: [CodingUserInfoKey: Any] = [:]) {
        self.codingPath = path
        self.context = Context(userInfo: info)
    }

    fileprivate init(at path: [any CodingKey], context: Context) {
        self.codingPath = path
        self.context = context
    }

    public var userInfo: [CodingUserInfoKey: Any] {
        get {
            return context.userInfo
        }
        set {
            context.userInfo = newValue
        }
    }

    public var dateEncodingStrategy: JSONEncoder.DateEncodingStrategy {
        get {
            return context.dateEncodingStrategy
        }
        set {
            context.dateEncodingStrategy = newValue
        }
    }

    public var dataEncodingStrategy: JSONEncoder.DataEncodingStrategy {
        get {
            return context.dataEncodingStrategy
        }
        set {
            context.dataEncodingStrategy = newValue
        }
    }

    public func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {

        switch value {
        case .none:
            let builder = JSDictBuilder<Key>(at: self.codingPath, context: self.context)
            value = .dict(builder)
            return KeyedEncodingContainer(builder)
        case .dict(let builder):
            guard let builder = builder as? JSDictBuilder<Key> else {
                preconditionFailure("Incompatible container types")
            }
            return KeyedEncodingContainer(builder)
        default:
            preconditionFailure("Container previously encoded with type \(value as Any)")
        }
    }

    public func unkeyedContainer() -> any UnkeyedEncodingContainer {
        switch value {
        case .none:
            let builder = JSArrayBuilder(at: self.codingPath, context: self.context)
            value = .array(builder)
            return builder
        case .array(let builder):
            return builder
        default:
            preconditionFailure("Container previously encoded with type \(value as Any)")
        }

    }

    public func singleValueContainer() -> any SingleValueEncodingContainer {
        switch value {
        case .none:
            let builder = JSValueBuilder(at: self.codingPath, context: self.context)
            value = .basic(builder)
            return builder
        case .basic(let builder):
            return builder
        default:
            preconditionFailure("Container previously encoded with type \(value as Any)")
        }
    }

    func encode<T : Encodable>(_ value: T) throws -> JSON {
        let encoder = JSEnumEncoder(at: [], context: context)
        try value.encode(to: encoder)
        return encoder.value?.json ?? .null
    }

}
