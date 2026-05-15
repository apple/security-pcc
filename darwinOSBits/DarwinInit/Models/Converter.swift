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

internal protocol Convertable {
    init?(from conv: Converter) throws
}

internal protocol Converter {
    var codingPath: [any CodingKey] { get }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedConverter<Key>
    func indexedContainer() throws -> any IndexedConverterContainer
    func singleValueContainer() throws -> any SingleValueConverterContainer

    func convert<T>(_ type: T.Type) throws -> PathCoded<T?> where T: Convertable
}

internal protocol SingleValueConverterContainer {
    var codingPath: [any CodingKey] { get }
    var value: JSON { get }

    var dict: [String: JSON] { get throws }
    var array: [JSON] { get throws }

    var bool: Bool { get throws }
    var str: String { get throws }
    var uint: UInt { get throws }
}

internal protocol IndexedConverterContainer {
    var codingPath: [any CodingKey] { get }
    var count: Int { get }

    func convert<T>(_ type: T.Type, at index: Int) throws -> T? where T: Convertable
    func container<Key: CodingKey>(keyedBy type: Key.Type, at index: Int) throws -> KeyedConverter<Key>
}

internal struct JSONConverter: Converter {

    typealias SingleValueContainer = JSEnumDecoder.SingleValueContainer

    let json: JSON
    let codingPath: [any CodingKey]

    init(config: JSON, codingPath: [CodingKey] = []) {
        self.json = config
        self.codingPath = codingPath
    }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedConverter<Key> where Key : CodingKey {
        guard case let .dictionary(dictionary) = json else {
            throw DecodingError.typeMismatch([String: JSON].self, (
                .init(codingPath: self.codingPath,
                      debugDescription: "Expected dictionary, got \(self.json)")
            ))
        }

        return KeyedConverter(dict: dictionary, codingPath: codingPath)
    }

    func indexedContainer() throws -> any IndexedConverterContainer {
        guard case let .array(array) = json else {
            throw DecodingError.typeMismatch([JSON].self, (
                .init(codingPath: self.codingPath,
                      debugDescription: "Expected dictionary, got \(self.json)")
            ))
        }

        return ArrayConverter(array: array, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueConverterContainer {
        return SingleValueContainer(value: json, at: codingPath)
    }

    public static func convert(from json: JSON) throws -> Config {
        let converter = JSONConverter(config: json)
        var config = try Config.init(from: converter)
        config.origin = .init(loadingPath: [.version(.v1)], source: json)
        return config
    }

    func convert<T>(_ type: T.Type) throws -> PathCoded<T?> where T: Convertable {
        let res = try T.init(from: self)
        return PathCoded(wrappedValue: res, at: self.codingPath)
    }
}

extension JSEnumDecoder.SingleValueContainer: SingleValueConverterContainer {
    var dict: [String : JSON] { get throws { try decode([String: JSON].self) } }
    var array: [JSON] { get throws { try decode([JSON].self) } }

    var bool: Bool { get throws { try decode(Bool.self) } }
    var str: String { get throws { try decode(String.self) } }
    var uint: UInt { get throws { try decode(UInt.self) } }
}

struct KeyedConverter<Key: CodingKey> {
    let dict: [String: JSON]
    let codingPath: [CodingKey]

    typealias SingleValueContainer = JSEnumDecoder.SingleValueContainer

    private func _missingKey(key: CodingKey) -> any Error {
        DecodingError.keyNotFound(key, .init(
            codingPath: self.codingPath,
            debugDescription: "\(key.stringValue) not found"))
    }

    private func _missingValue<T>(_ type: T.Type, for key: CodingKey, at path: [CodingKey]) -> any Error {
        DecodingError.valueNotFound(type, .init(
            codingPath: path,
            debugDescription: "\(key.stringValue) is 'null'"))
    }

    func codingPath(forKey key: Key) -> [CodingKey] {
        self.codingPath + [key]
    }

    /// Lookup key and return its value or `nil` if the key is not present.
    /// JSON `null` vaues are treated as missing keys unless `preserveNull` is `true`.
    func _getValue(forKey key: Key, preserveNull: Bool = false) throws -> SingleValueContainer? {
        guard let value = dict[key.stringValue] else {
                return nil
        }
        guard value != .null || preserveNull else {
            return nil
        }
        let path = self.codingPath(forKey: key)
        return SingleValueContainer(value: value, at: path)
    }

    func raw(forKey key: Key) throws-> JSON? {
        return dict[key.stringValue]
    }

    func raw(forCheckedKey key: Key) throws -> JSON {
        guard let value = dict[key.stringValue] else {
            throw _missingKey(key: key)
        }
        return value
    }

    func convert<T>(_ type: T.Type, forKey key: Key) throws -> PathCoded<T?> where T: Convertable {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }

        let converter = JSONConverter(config: val.value, codingPath: val.codingPath)
        let res = try T.init(from: converter)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func convert<T>(_ type: T.Type, forKey key: Key) throws -> PathCoded<T>? where T: Convertable {
        guard let val = try _getValue(forKey: key) else {
            return nil
        }

        let converter = JSONConverter(config: val.value, codingPath: val.codingPath)
        guard let res = try T.init(from: converter) else {
            return nil
        }
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func indexedContainer(forKey key: Key) throws -> ArrayConverter? {
        guard let val = try _getValue(forKey: key) else {
            return nil
        }
        let array = try val.decodeArray()
        return ArrayConverter(array: array, codingPath: val.codingPath)
    }

    func container<K: CodingKey>(keyedBy type: K.Type, forKey key: Key) throws -> KeyedConverter<K>? {
        guard let val = try _getValue(forKey: key) else {
            return nil
        }
        return KeyedConverter<K>(dict: try val.decodeDict(), codingPath: val.codingPath)
    }
}

extension KeyedConverter {

    func bool(forKey key: Key) throws -> PathCoded<Bool>? {
        guard let val = try _getValue(forKey: key) else {
            return nil
        }
        let res = try val.decode(Bool.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func bool(forKey key: Key) throws -> PathCoded<Bool?> {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }
        let res = try val.decode(Bool.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func bool(forCheckedKey key: Key) throws -> PathCoded<Bool> {
        guard let val = try _getValue(forKey: key, preserveNull: true) else {
            throw _missingKey(key: key)
        }
        guard !val.isNull else {
            throw _missingValue(Bool.self, for: key, at: val.codingPath)
        }
        let res = try val.decode(Bool.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func objCBool(forKey key: Key) throws -> PathCoded<Bool?> {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }

        let res: Bool
        do {
            res = try val.decode(Bool.self)
        } catch {
            guard let str = try? val.decode(String.self) else {
                throw error
            }
            res = (str as NSString).boolValue
        }
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func dict<Value: Convertable>(forKey key: Key) throws -> PathCoded<[String: Value]?> {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }

        let values = try val.dict
        let res: [String: Value]? = try values.map { k, v in
            let converter = JSONConverter(config: v, codingPath: val.codingPath)
            return (k, try Value.init(from: converter))
        }.reduce(into: [:]) { res, v in
            res[v.0] = v.1
        }

        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func dict(forKey key: Key) throws -> PathCoded<[String: JSON]?> {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }
        return PathCoded(wrappedValue: try val.dict, at: val.codingPath)
    }

    func str(forKey key: Key) throws -> PathCoded<String>? {
        guard let val = try _getValue(forKey: key) else {
            return nil
        }
        let res = try val.decode(String.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func str(forKey key: Key) throws -> PathCoded<String?> {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }
        let res = try val.decode(String.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func str(forCheckedKey key: Key) throws -> PathCoded<String> {
        guard let val = try _getValue(forKey: key, preserveNull: true) else {
            throw _missingKey(key: key)
        }
        guard !val.isNull else {
            throw _missingValue(String.self, for: key, at: val.codingPath)
        }
        let res = try val.decode(String.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func uint(forKey key: Key) throws -> PathCoded<UInt>? {
        guard let val = try _getValue(forKey: key) else {
            return nil
        }
        let res = try val.decode(UInt.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func uint(forKey key: Key) throws -> PathCoded<UInt?> {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }
        let res = try val.decode(UInt.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func uint(forCheckedKey key: Key) throws -> PathCoded<UInt> {
        guard let val = try _getValue(forKey: key, preserveNull: true) else {
            throw _missingKey(key: key)
        }
        guard !val.isNull else {
            throw _missingValue(UInt.self, for: key, at: val.codingPath)
        }
        let res = try val.decode(UInt.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func uint8(forKey key: Key) throws -> PathCoded<UInt8?> {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }
        let res = try val.decode(UInt8.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func uint8(forCheckedKey key: Key) throws -> PathCoded<UInt8> {
        guard let val = try _getValue(forKey: key) else {
            throw _missingKey(key: key)
        }
        guard !val.isNull else {
            throw _missingValue(UInt8.self, for: key, at: val.codingPath)
        }
        let res = try val.decode(UInt8.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func uint64(forKey key: Key) throws -> PathCoded<UInt64?> {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }
        let res = try val.decode(UInt64.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func url(forKey key: Key) throws -> PathCoded<URL>? {
        guard let val = try _getValue(forKey: key) else {
            return nil
        }
        let res = try val.decode(URL.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func url(forKey key: Key) throws -> PathCoded<URL?> {
        guard let val = try _getValue(forKey: key) else {
            return PathCoded(wrappedValue: nil)
        }
        let res = try val.decode(URL.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }

    func url(forCheckedKey key: Key) throws -> PathCoded<URL> {
        guard let val = try _getValue(forKey: key, preserveNull: true) else {
            throw _missingKey(key: key)
        }
        guard !val.isNull else {
            throw _missingValue(URL.self, for: key, at: val.codingPath)
        }
        let res = try val.decode(URL.self)
        return PathCoded(wrappedValue: res, at: val.codingPath)
    }
}

// MARK: PathCoded
extension PathCoded: Convertable where Value: Convertable {
    init?(from conv: any Converter) throws {
        guard let res = try Value.init(from: conv) else { return nil }
        self.wrappedValue = res
        self.codingPath = conv.codingPath
    }
}

// MARK: Array
struct ArrayConverter: IndexedConverterContainer {
    typealias IndexKey = JSEnumDecoder.IndexKey
    typealias SingleValueContainer = JSEnumDecoder.SingleValueContainer

    let array: [JSON]
    let codingPath: [CodingKey]

    var count: Int {
        return array.count
    }

    func _get(at index: Int) throws -> SingleValueContainer {
        guard index < self.count else {
            throw DecodingError.valueNotFound(
                Any.self,
                .init(codingPath: self.codingPath,
                      debugDescription: "No value at index \(index)"))
        }

        let newPath = self.codingPath + [IndexKey(intValue: index)]
        return SingleValueContainer(value: array[index], at: newPath)
    }

    func convert<T>(_ type: T.Type, at index: Int) throws -> T? where T: Convertable {
        let val = try _get(at: index)
        let converter = JSONConverter(config: val.value, codingPath: val.codingPath)
        return try T.init(from: converter)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type, at index: Int) throws -> KeyedConverter<Key> {
        let val = try _get(at: index)
        let dict = try val.decodeDict()
        return KeyedConverter<Key>(dict: dict, codingPath: val.codingPath)
    }
}

extension Array: Convertable where Element: Convertable {
    init?(from conv: Converter) throws {
        let container = try conv.indexedContainer()
        var res: [Element] = []
        for i in 0..<container.count {
            if let val = try container.convert(Element.self, at: i) {
                res.append(val)
            }
        }
        self.init(res)
    }
}

