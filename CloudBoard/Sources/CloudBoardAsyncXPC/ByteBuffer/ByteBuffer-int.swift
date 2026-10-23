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

//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension ByteBuffer {
    @inlinable
    func _toEndianness<T: FixedWidthInteger>(value: T, endianness: Endianness) -> T {
        switch endianness {
        case .little:
            return value.littleEndian
        case .big:
            return value.bigEndian
        }
    }

    /// Read an integer off this `ByteBuffer`, move the reader index forward by the integer's byte size and return the
    /// result.
    ///
    /// - parameters:
    ///     - endianness: The endianness of the integer in this `ByteBuffer` (defaults to big endian).
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - returns: An integer value deserialized from this `ByteBuffer` or `nil` if there aren't enough bytes readable.
    @inlinable
    public mutating func readInteger<T: FixedWidthInteger>(endianness: Endianness = .big, as _: T.Type = T.self) -> T? {
        guard let result = self.getInteger(at: self.readerIndex, endianness: endianness, as: T.self) else {
            return nil
        }
        self._moveReaderIndex(forwardBy: MemoryLayout<T>.size)
        return result
    }

    /// Get the integer at `index` from this `ByteBuffer`. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes for the integer into the `ByteBuffer`.
    ///     - endianness: The endianness of the integer in this `ByteBuffer` (defaults to big endian).
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - returns: An integer value deserialized from this `ByteBuffer` or `nil` if the bytes of interest are not
    ///            readable.
    @inlinable
    public func getInteger<T: FixedWidthInteger>(
        at index: Int,
        endianness: Endianness = Endianness.big,
        as _: T.Type = T.self
    ) -> T? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: MemoryLayout<T>.size) else {
            return nil
        }

        if T.self == UInt8.self {
            assert(range.count == 1)
            return self.withUnsafeReadableBytes { ptr in
                ptr[range.startIndex] as! T
            }
        }

        return self.withUnsafeReadableBytes { ptr in
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { valuePtr in
                valuePtr.copyMemory(from: UnsafeRawBufferPointer(fastRebase: ptr[range]))
            }
            return self._toEndianness(value: value, endianness: endianness)
        }
    }

    /// Write `integer` into this `ByteBuffer`, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - integer: The integer to serialize.
    ///     - endianness: The endianness to use, defaults to big endian.
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeInteger<T: FixedWidthInteger>(
        _ integer: T,
        endianness: Endianness = .big,
        as _: T.Type = T.self
    ) -> Int {
        let bytesWritten = self.setInteger(integer, at: self.writerIndex, endianness: endianness)
        self._moveWriterIndex(forwardBy: bytesWritten)
        return Int(bytesWritten)
    }

    /// Write `integer` into this `ByteBuffer` starting at `index`. This does not alter the writer index.
    ///
    /// - parameters:
    ///     - integer: The integer to serialize.
    ///     - index: The index of the first byte to write.
    ///     - endianness: The endianness to use, defaults to big endian.
    ///     - as: the desired `FixedWidthInteger` type (optional parameter)
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func setInteger<T: FixedWidthInteger>(
        _ integer: T,
        at index: Int,
        endianness: Endianness = .big,
        as _: T.Type = T.self
    ) -> Int {
        var value = self._toEndianness(value: integer, endianness: endianness)
        return Swift.withUnsafeBytes(of: &value) { ptr in
            self.setBytes(ptr, at: index)
        }
    }
}

extension FixedWidthInteger {
    /// Returns the next power of two.
    @inlinable
    func nextPowerOf2() -> Self {
        guard self != 0 else {
            return 1
        }
        return 1 << (Self.bitWidth - (self - 1).leadingZeroBitCount)
    }

    /// Returns the previous power of 2, or self if it already is.
    @inlinable
    func previousPowerOf2() -> Self {
        guard self != 0 else {
            return 0
        }

        return 1 << ((Self.bitWidth - 1) - self.leadingZeroBitCount)
    }
}

extension UInt32 {
    /// Returns the next power of two unless that would overflow, in which case UInt32.max (on 64-bit systems) or
    /// Int32.max (on 32-bit systems) is returned. The returned value is always safe to be cast to Int and passed
    /// to malloc on all platforms.
    @inlinable
    func nextPowerOf2ClampedToMax() -> UInt32 {
        guard self > 0 else {
            return 1
        }

        var n = self

        #if arch(arm) || arch(i386) || arch(arm64_32)
        // on 32-bit platforms we can't make use of a whole UInt32.max (as it doesn't fit in an Int)
        let max = UInt32(Int.max)
        #else
        // on 64-bit platforms we're good
        let max = UInt32.max
        #endif

        n -= 1
        n |= n >> 1
        n |= n >> 2
        n |= n >> 4
        n |= n >> 8
        n |= n >> 16
        if n != max {
            n += 1
        }

        return n
    }
}

/// Endianness refers to the sequential order in which bytes are arranged into larger numerical values when stored in
/// memory or when transmitted over digital links.
public enum Endianness: Sendable {
    /// The endianness of the machine running this program.
    public static let host: Endianness = hostEndianness0()

    private static func hostEndianness0() -> Endianness {
        let number: UInt32 = 0x1234_5678
        return number == number.bigEndian ? .big : .little
    }

    /// big endian, the most significant byte (MSB) is at the lowest address
    case big

    /// little endian, the least significant byte (LSB) is at the lowest address
    case little
}
