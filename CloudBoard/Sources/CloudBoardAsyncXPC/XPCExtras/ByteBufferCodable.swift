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
import XPC

/// Alternative, faster approach to coding XPC messages.
///
/// The goal is to be able to replace Codable where serialization/deserialization performance matters.
///
/// Since the serialization is completely abstracted away from any adopters by always providing a
/// framework for interacting with an XPC service along with the XPC service (no need for versioning, or
/// permissive decoding), and all communication happens on the same box over XPC, a simple, custom
/// serialization into a byte buffer is often faster than going via Codable.
///
/// Note: This is public because package would block inline use, it's not intended to be made available
/// to CloudBoard consumers
public protocol ByteBufferCodable {
    func encode(to buffer: inout ByteBuffer) throws
    init(from buffer: inout ByteBuffer) throws
}

package struct ByteBufferCodingKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?

    public init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = "\(intValue)"
    }

    public init(stringValue: String) {
        self.stringValue = stringValue
    }

    public init<T>(_: T.Type) {
        self.stringValue = "\(T.self)"
    }
}

extension ExplicitSuccess: ByteBufferCodable {
    public func encode(to _: inout ByteBuffer) throws {}
    public init(from _: inout ByteBuffer) throws {}
}

extension Never: ByteBufferCodable {
    public func encode(to _: inout ByteBuffer) throws {}
    public init(from _: inout ByteBuffer) throws {
        fatalError("There's no way to create an instance of `Never`")
    }
}

extension CloudBoardAsyncXPCMessageResult: ByteBufferCodable
where Success: ByteBufferCodable, Failure: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .success(let success):
            buffer.writeInteger(0)
            try success.encode(to: &buffer)
        case .failure(let failure):
            buffer.writeInteger(1)
            try failure.encode(to: &buffer)
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let enumCase: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        switch enumCase {
        case 0:
            let associatedValue = try Success(from: &buffer)
            self = .success(associatedValue)
        case 1:
            let associatedValue = try Failure(from: &buffer)
            self = .failure(associatedValue)
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}

extension ByteBuffer {
    @inlinable
    public init(from xpcObject: xpc_object_t) {
        let messageLength = xpc_data_get_length(xpcObject)
        self = ByteBuffer()
        self.reserveCapacity(messageLength)
        self.writeWithUnsafeMutableBytes(minimumWritableBytes: messageLength) { pointer in
            xpc_data_get_bytes(xpcObject, pointer.baseAddress!, 0, messageLength)
        }
    }
}

/// Extensions with constraints cannot create protocol conformances to other protocols,
/// but they can supply the implementations.
/// This makes it trivial to get a robust implementation for ByteBufferCodable on many enums
/// simply by declaring the conformance
extension RawRepresentable where Self.RawValue: FixedWidthInteger {
    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        buffer.writeInteger(self.rawValue, as: Self.RawValue.self)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        guard let rawValue = buffer.readInteger(as: Self.RawValue.self) else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        guard let enumCase = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
        self = enumCase
    }
}

extension Data: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        try buffer.writeLengthPrefixed(as: Int.self, writeMessage: { $0.writeBytes(self) })
    }

    public init(from buffer: inout ByteBuffer) throws {
        let bytesRead = try buffer.readLengthPrefixed(as: Int.self) {
            var buffer = $0
            return buffer.readBytes(length: $0.readableBytes)
        }
        guard let bytesRead else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "failed to read expected bytes"
            ))
        }
        self = Data(bytesRead)
    }
}

extension Date: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        try self.timeIntervalSince1970.encode(to: &buffer)
    }

    public init(from buffer: inout ByteBuffer) throws {
        let timeInterval: TimeInterval = try .init(from: &buffer)
        self = .init(timeIntervalSince1970: timeInterval)
    }
}

extension Duration: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        try self.components.seconds.encode(to: &buffer)
        try self.components.attoseconds.encode(to: &buffer)
    }

    public init(from buffer: inout ByteBuffer) throws {
        self = try .init(
            secondsComponent: .init(from: &buffer),
            attosecondsComponent: .init(from: &buffer)
        )
    }
}

extension Double: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        buffer.writeInteger(self.sign.rawValue)
        buffer.writeInteger(self.exponentBitPattern)
        buffer.writeInteger(self.significandBitPattern)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let signInt: Int = buffer.readInteger(), let sign: FloatingPointSign = .init(rawValue: signInt) else {
            throw DecodingError.valueNotFound(
                Int.self,
                .init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "no expected sign"
                )
            )
        }
        guard let exponentBitPattern: UInt = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Int.self,
                .init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "no expected exponent"
                )
            )
        }
        guard let significandBitPattern: UInt64 = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Int.self,
                .init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "no expected exponent"
                )
            )
        }
        self = .init(
            sign: sign,
            exponentBitPattern: exponentBitPattern,
            significandBitPattern: significandBitPattern
        )
    }
}

extension Array: ByteBufferCodable where Array.Element: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        buffer.writeInteger(self.count)
        for value in self {
            try value.encode(to: &buffer)
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let count: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "no expected item count"
                )
            )
        }
        self = .init()
        self.reserveCapacity(count)
        for _ in 0 ..< count {
            try self.append(Element(from: &buffer))
        }
    }
}

extension UUID: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        buffer.writeMultipleIntegers(
            self.uuid.0,
            self.uuid.1,
            self.uuid.2,
            self.uuid.3,
            self.uuid.4,
            self.uuid.5,
            self.uuid.6,
            self.uuid.7
        )
        buffer.writeMultipleIntegers(
            self.uuid.8,
            self.uuid.9,
            self.uuid.10,
            self.uuid.11,
            self.uuid.12,
            self.uuid.13,
            self.uuid.14,
            self.uuid.15
        )
    }

    public init(from buffer: inout ByteBuffer) throws {
        self = try buffer.readWithUnsafeReadableBytes {
            guard let baseAddress = $0.bindMemory(to: UInt8.self).baseAddress else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [ByteBufferCodingKey(Self.self)], debugDescription: "could not deserialize UUID"
                ))
            }
            return (MemoryLayout<uuid_t>.size, NSUUID(uuidBytes: baseAddress) as UUID)
        }
    }
}

extension Dictionary: ByteBufferCodable where Dictionary.Key: ByteBufferCodable, Dictionary.Value: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        buffer.writeInteger(self.count)
        for (k, v) in self {
            try k.encode(to: &buffer)
            try v.encode(to: &buffer)
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let count: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Int.self,
                .init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "no expected item count"
                )
            )
        }
        self = .init()
        self.reserveCapacity(count)
        for _ in 0 ..< count {
            let key = try Key(from: &buffer)
            self[key] = try Value(from: &buffer)
        }
    }
}

extension String: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        try buffer.writeLengthPrefixed(as: Int.self, writeMessage: { $0.writeString(self) })
    }

    public init(from buffer: inout ByteBuffer) throws {
        let stringRead = try buffer.readLengthPrefixed(as: Int.self) {
            var buffer = $0
            return buffer.readString(length: $0.readableBytes)
        }
        guard let string = stringRead else {
            throw DecodingError.valueNotFound(String.self, .init(
                codingPath: [], debugDescription: "failed to read expected string"
            ))
        }
        self = string
    }
}

extension Bool: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        if self {
            buffer.writeInteger(UInt8(1))
        } else {
            buffer.writeInteger(UInt8(0))
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let value: UInt8 = buffer.readInteger() else {
            throw DecodingError.valueNotFound(Int.self, .init(
                codingPath: [ByteBufferCodingKey(Self.self)], debugDescription: "no expected value"
            ))
        }
        switch value {
        case 0: self = false
        case 1: self = true
        case let value: throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "wrong value \(value) for boolean"
            ))
        }
    }
}

extension Optional: ByteBufferCodable where Wrapped: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .none: try false.encode(to: &buffer)
        case .some(let wrapped):
            try true.encode(to: &buffer)
            try wrapped.encode(to: &buffer)
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        let hasValue: Bool = try .init(from: &buffer)
        if hasValue {
            self = try .some(.init(from: &buffer))
        } else {
            self = .none
        }
    }
}

extension Int64: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        buffer.writeInteger(self)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let integer: Self = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected value")
            )
        }
        self = integer
    }
}

extension UInt64: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        buffer.writeInteger(self)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let integer: Self = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected value")
            )
        }
        self = integer
    }
}

extension UInt32: ByteBufferCodable {
    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        buffer.writeInteger(self)
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let integer: Self = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected value")
            )
        }
        self = integer
    }
}

// read and write where host endianess is assumed and lack of data is treated as an error
extension ByteBuffer {
    /// Write `integer` into this `ByteBuffer`, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - integer: The integer to serialize.
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeHostInteger<T: FixedWidthInteger>(
        _ integer: T,
        as _: T.Type = T.self
    ) -> Int {
        return self.writeInteger(integer, endianness: .host, as: T.self)
    }

    /// Read an integer off this `ByteBuffer`, move the reader index forward by the integer's byte size and return the
    /// result, throw if the value cannot be read.
    ///
    /// - parameters:
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    ///     - description: a short description of what is being read for error messages
    /// - returns: An integer value deserialized from this `ByteBuffer`
    @inlinable
    public mutating func readHostIntegerOrThrow<T: FixedWidthInteger>(
        as _: T.Type = T.self,
        file: String = #file,
        line: UInt = #line,
    ) throws -> T {
        guard let result = self.readInteger(endianness: .host, as: T.self) else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected value at \(file):\(line)")
            )
        }
        return result
    }
}
