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
//  ArraySlice+Extension.swift
//  CloudAttestationV2
//
//  Created by David Zech on 1/6/26.
//

import Foundation

extension ArraySlice where Element == UInt8 {

    private mutating func readFixedWithInteger<I: FixedWidthInteger>(byteOrder: ByteOrder = .littleEndian) throws -> I {
        let size = I.byteCount
        guard self.count >= size else {
            throw BinaryDecodingError.outOfBounds(have: self.count, need: size)
        }

        var val: I = 0

        for i in 0..<size {
            let e = self.removeFirst()
            val |= I(e) << (i * 8)
        }

        return switch byteOrder {
        case .littleEndian:
            val
        case .bigEndian:
            val.byteSwapped
        }
    }

    package mutating func readUInt8() throws -> UInt8 {
        return try readFixedWithInteger()
    }

    package mutating func readUInt16(byteOrder: ByteOrder = .littleEndian) throws -> UInt16 {
        return try readFixedWithInteger(byteOrder: byteOrder)
    }

    package mutating func readUInt32(byteOrder: ByteOrder = .littleEndian) throws -> UInt32 {
        return try readFixedWithInteger(byteOrder: byteOrder)
    }

    package mutating func readUInt64(byteOrder: ByteOrder = .littleEndian) throws -> UInt64 {
        return try readFixedWithInteger(byteOrder: byteOrder)
    }

    package mutating func readBytes(count: Int) throws -> ArraySlice<UInt8> {
        guard self.count >= count else {
            throw BinaryDecodingError.outOfBounds(have: self.count, need: count)
        }

        let slice = self[self.startIndex..<self.startIndex + count]
        self.removeFirst(count)

        return slice
    }

    package mutating func readBytes<T>(sizeOf: T.Type) throws -> ArraySlice<UInt8> {
        try self.readBytes(count: MemoryLayout<T>.size)
    }

    package mutating func readInlineArray<let count: Int>() throws -> InlineArray<count, UInt8> {
        guard self.count >= count else {
            throw BinaryDecodingError.outOfBounds(have: self.count, need: count)
        }

        let array = InlineArray<count, UInt8> { index in
            self.removeFirst()
        }

        return array
    }
}

package enum ByteOrder {
    case littleEndian
    case bigEndian

    static var host: Self {
        guard 0xFEED_FACE.littleEndian == 0xFEED_FACE else {
            return .bigEndian
        }
        return .littleEndian
    }
}

extension Array: ByteOrdered, BinaryCodable where Element: BinaryCodable {
    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self = []
        while !buffer.isEmpty {
            self.append(try Element(from: &buffer))
        }
    }

    package func encode(to buffer: inout [UInt8]) {
        for element in self {
            element.encode(to: &buffer)
        }
    }

    package static var encodedByteOrder: ByteOrder {
        Element.encodedByteOrder
    }
}

extension InlineArray where Element == UInt8 {
    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self = try buffer.readInlineArray()
    }

    package var bytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: self.count)
        for i in self.indices {
            out[i] = self[i]
        }

        return out
    }
}

extension InlineArray where Element: Equatable {
    package static func == (left: Self, right: Self) -> Bool {
        for i in left.indices {
            if left[i] != right[i] {
                return false
            }
        }
        return true
    }
}

extension UUID: StaticSized, BinaryDecodable {
    package init(from buffer: inout ArraySlice<UInt8>) throws {
        let bytes = try buffer.readBytes(count: 16)
        let startIndex = bytes.startIndex
        self.init(
            uuid: (
                bytes[startIndex + 0], bytes[startIndex + 1], bytes[startIndex + 2], bytes[startIndex + 3], bytes[startIndex + 4], bytes[startIndex + 5], bytes[startIndex + 6],
                bytes[startIndex + 7],
                bytes[startIndex + 8], bytes[startIndex + 9], bytes[startIndex + 10], bytes[startIndex + 11], bytes[startIndex + 12], bytes[startIndex + 13],
                bytes[startIndex + 14], bytes[startIndex + 15]
            )
        )
    }

    init(from bytes: ArraySlice<UInt8>) throws {
        var buffer = bytes
        try self.init(from: &buffer)
    }

    package static let byteCount = 16
}

extension Sequence where Element: Sized {
    package var byteCount: Int {
        self.reduce(0) { acc, elem in
            acc + elem.byteCount
        }
    }
}

extension Array: Sized where Element: Sized {
}

extension ArraySlice: Sized where Element: Sized {
}

extension InlineArray: ByteOrdered, BinaryEncodable where Element == UInt8 {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self)
    }
}

extension UUID: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        let u = self.uuid
        buffer.append(contentsOf: [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ])
    }
}
