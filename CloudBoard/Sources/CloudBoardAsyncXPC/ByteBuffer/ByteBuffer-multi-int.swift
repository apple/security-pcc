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
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// NOTE: THIS FILE IS AUTO-GENERATED BY dev/generate-bytebuffer-multi-int.sh

extension ByteBuffer {
    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<T1: FixedWidthInteger, T2: FixedWidthInteger>(
        endianness: Endianness = .big,
        as _: (T1, T2).Type = (T1, T2).self
    ) -> (T1, T2)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (T1(bigEndian: v1), T2(bigEndian: v2))
        case .little:
            return (T1(littleEndian: v1), T2(littleEndian: v2))
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<T1: FixedWidthInteger, T2: FixedWidthInteger>(
        _ value1: T1,
        _ value2: T2,
        endianness: Endianness = .big,
        as _: (T1, T2).Type = (T1, T2).self
    ) -> Int {
        var v1: T1
        var v2: T2
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<T1: FixedWidthInteger, T2: FixedWidthInteger, T3: FixedWidthInteger>(
        endianness: Endianness = .big,
        as _: (T1, T2, T3).Type = (T1, T2, T3).self
    ) -> (T1, T2, T3)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (T1(bigEndian: v1), T2(bigEndian: v2), T3(bigEndian: v3))
        case .little:
            return (T1(littleEndian: v1), T2(littleEndian: v2), T3(littleEndian: v3))
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<T1: FixedWidthInteger, T2: FixedWidthInteger, T3: FixedWidthInteger>(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        endianness: Endianness = .big,
        as _: (T1, T2, T3).Type = (T1, T2, T3).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger
    >(endianness: Endianness = .big, as _: (T1, T2, T3, T4).Type = (T1, T2, T3, T4).self) -> (T1, T2, T3, T4)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (T1(bigEndian: v1), T2(bigEndian: v2), T3(bigEndian: v3), T4(bigEndian: v4))
        case .little:
            return (T1(littleEndian: v1), T2(littleEndian: v2), T3(littleEndian: v3), T4(littleEndian: v4))
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4).Type = (T1, T2, T3, T4).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5).Type = (T1, T2, T3, T4, T5).self
    ) -> (T1, T2, T3, T4, T5)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (T1(bigEndian: v1), T2(bigEndian: v2), T3(bigEndian: v3), T4(bigEndian: v4), T5(bigEndian: v5))
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5).Type = (T1, T2, T3, T4, T5).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6).Type = (T1, T2, T3, T4, T5, T6).self
    ) -> (T1, T2, T3, T4, T5, T6)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6).Type = (T1, T2, T3, T4, T5, T6).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7).Type = (T1, T2, T3, T4, T5, T6, T7).self
    ) -> (T1, T2, T3, T4, T5, T6, T7)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size
        bytesRequired &+= MemoryLayout<T7>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var v7: T7 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            withUnsafeMutableBytes(of: &v7) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T7>.size)
            }
            offset = offset &+ MemoryLayout<T7>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6),
                T7(bigEndian: v7)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6),
                T7(littleEndian: v7)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        _ value7: T7,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7).Type = (T1, T2, T3, T4, T5, T6, T7).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        var v7: T7
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
            v7 = value7.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
            v7 = value7.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size
        spaceNeeded &+= MemoryLayout<T7>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            (basePtr + offset).copyMemory(from: &v7, byteCount: MemoryLayout<T7>.size)
            offset = offset &+ MemoryLayout<T7>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8).Type = (T1, T2, T3, T4, T5, T6, T7, T8)
            .self
    ) -> (T1, T2, T3, T4, T5, T6, T7, T8)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size
        bytesRequired &+= MemoryLayout<T7>.size
        bytesRequired &+= MemoryLayout<T8>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var v7: T7 = 0
        var v8: T8 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            withUnsafeMutableBytes(of: &v7) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T7>.size)
            }
            offset = offset &+ MemoryLayout<T7>.size
            withUnsafeMutableBytes(of: &v8) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T8>.size)
            }
            offset = offset &+ MemoryLayout<T8>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6),
                T7(bigEndian: v7),
                T8(bigEndian: v8)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6),
                T7(littleEndian: v7),
                T8(littleEndian: v8)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        _ value7: T7,
        _ value8: T8,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8).Type = (T1, T2, T3, T4, T5, T6, T7, T8).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        var v7: T7
        var v8: T8
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
            v7 = value7.bigEndian
            v8 = value8.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
            v7 = value7.littleEndian
            v8 = value8.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size
        spaceNeeded &+= MemoryLayout<T7>.size
        spaceNeeded &+= MemoryLayout<T8>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            (basePtr + offset).copyMemory(from: &v7, byteCount: MemoryLayout<T7>.size)
            offset = offset &+ MemoryLayout<T7>.size
            (basePtr + offset).copyMemory(from: &v8, byteCount: MemoryLayout<T8>.size)
            offset = offset &+ MemoryLayout<T8>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9).Type = (T1, T2, T3, T4, T5, T6, T7, T8, T9).self
    ) -> (T1, T2, T3, T4, T5, T6, T7, T8, T9)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size
        bytesRequired &+= MemoryLayout<T7>.size
        bytesRequired &+= MemoryLayout<T8>.size
        bytesRequired &+= MemoryLayout<T9>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var v7: T7 = 0
        var v8: T8 = 0
        var v9: T9 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            withUnsafeMutableBytes(of: &v7) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T7>.size)
            }
            offset = offset &+ MemoryLayout<T7>.size
            withUnsafeMutableBytes(of: &v8) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T8>.size)
            }
            offset = offset &+ MemoryLayout<T8>.size
            withUnsafeMutableBytes(of: &v9) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T9>.size)
            }
            offset = offset &+ MemoryLayout<T9>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6),
                T7(bigEndian: v7),
                T8(bigEndian: v8),
                T9(bigEndian: v9)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6),
                T7(littleEndian: v7),
                T8(littleEndian: v8),
                T9(littleEndian: v9)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        _ value7: T7,
        _ value8: T8,
        _ value9: T9,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9).Type = (T1, T2, T3, T4, T5, T6, T7, T8, T9).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        var v7: T7
        var v8: T8
        var v9: T9
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
            v7 = value7.bigEndian
            v8 = value8.bigEndian
            v9 = value9.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
            v7 = value7.littleEndian
            v8 = value8.littleEndian
            v9 = value9.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size
        spaceNeeded &+= MemoryLayout<T7>.size
        spaceNeeded &+= MemoryLayout<T8>.size
        spaceNeeded &+= MemoryLayout<T9>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            (basePtr + offset).copyMemory(from: &v7, byteCount: MemoryLayout<T7>.size)
            offset = offset &+ MemoryLayout<T7>.size
            (basePtr + offset).copyMemory(from: &v8, byteCount: MemoryLayout<T8>.size)
            offset = offset &+ MemoryLayout<T8>.size
            (basePtr + offset).copyMemory(from: &v9, byteCount: MemoryLayout<T9>.size)
            offset = offset &+ MemoryLayout<T9>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10).Type = (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10).self
    ) -> (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size
        bytesRequired &+= MemoryLayout<T7>.size
        bytesRequired &+= MemoryLayout<T8>.size
        bytesRequired &+= MemoryLayout<T9>.size
        bytesRequired &+= MemoryLayout<T10>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var v7: T7 = 0
        var v8: T8 = 0
        var v9: T9 = 0
        var v10: T10 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            withUnsafeMutableBytes(of: &v7) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T7>.size)
            }
            offset = offset &+ MemoryLayout<T7>.size
            withUnsafeMutableBytes(of: &v8) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T8>.size)
            }
            offset = offset &+ MemoryLayout<T8>.size
            withUnsafeMutableBytes(of: &v9) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T9>.size)
            }
            offset = offset &+ MemoryLayout<T9>.size
            withUnsafeMutableBytes(of: &v10) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T10>.size)
            }
            offset = offset &+ MemoryLayout<T10>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6),
                T7(bigEndian: v7),
                T8(bigEndian: v8),
                T9(bigEndian: v9),
                T10(bigEndian: v10)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6),
                T7(littleEndian: v7),
                T8(littleEndian: v8),
                T9(littleEndian: v9),
                T10(littleEndian: v10)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        _ value7: T7,
        _ value8: T8,
        _ value9: T9,
        _ value10: T10,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10).Type = (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        var v7: T7
        var v8: T8
        var v9: T9
        var v10: T10
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
            v7 = value7.bigEndian
            v8 = value8.bigEndian
            v9 = value9.bigEndian
            v10 = value10.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
            v7 = value7.littleEndian
            v8 = value8.littleEndian
            v9 = value9.littleEndian
            v10 = value10.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size
        spaceNeeded &+= MemoryLayout<T7>.size
        spaceNeeded &+= MemoryLayout<T8>.size
        spaceNeeded &+= MemoryLayout<T9>.size
        spaceNeeded &+= MemoryLayout<T10>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            (basePtr + offset).copyMemory(from: &v7, byteCount: MemoryLayout<T7>.size)
            offset = offset &+ MemoryLayout<T7>.size
            (basePtr + offset).copyMemory(from: &v8, byteCount: MemoryLayout<T8>.size)
            offset = offset &+ MemoryLayout<T8>.size
            (basePtr + offset).copyMemory(from: &v9, byteCount: MemoryLayout<T9>.size)
            offset = offset &+ MemoryLayout<T9>.size
            (basePtr + offset).copyMemory(from: &v10, byteCount: MemoryLayout<T10>.size)
            offset = offset &+ MemoryLayout<T10>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11).Type = (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11).self
    ) -> (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size
        bytesRequired &+= MemoryLayout<T7>.size
        bytesRequired &+= MemoryLayout<T8>.size
        bytesRequired &+= MemoryLayout<T9>.size
        bytesRequired &+= MemoryLayout<T10>.size
        bytesRequired &+= MemoryLayout<T11>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var v7: T7 = 0
        var v8: T8 = 0
        var v9: T9 = 0
        var v10: T10 = 0
        var v11: T11 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            withUnsafeMutableBytes(of: &v7) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T7>.size)
            }
            offset = offset &+ MemoryLayout<T7>.size
            withUnsafeMutableBytes(of: &v8) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T8>.size)
            }
            offset = offset &+ MemoryLayout<T8>.size
            withUnsafeMutableBytes(of: &v9) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T9>.size)
            }
            offset = offset &+ MemoryLayout<T9>.size
            withUnsafeMutableBytes(of: &v10) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T10>.size)
            }
            offset = offset &+ MemoryLayout<T10>.size
            withUnsafeMutableBytes(of: &v11) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T11>.size)
            }
            offset = offset &+ MemoryLayout<T11>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6),
                T7(bigEndian: v7),
                T8(bigEndian: v8),
                T9(bigEndian: v9),
                T10(bigEndian: v10),
                T11(bigEndian: v11)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6),
                T7(littleEndian: v7),
                T8(littleEndian: v8),
                T9(littleEndian: v9),
                T10(littleEndian: v10),
                T11(littleEndian: v11)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        _ value7: T7,
        _ value8: T8,
        _ value9: T9,
        _ value10: T10,
        _ value11: T11,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11).Type = (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        var v7: T7
        var v8: T8
        var v9: T9
        var v10: T10
        var v11: T11
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
            v7 = value7.bigEndian
            v8 = value8.bigEndian
            v9 = value9.bigEndian
            v10 = value10.bigEndian
            v11 = value11.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
            v7 = value7.littleEndian
            v8 = value8.littleEndian
            v9 = value9.littleEndian
            v10 = value10.littleEndian
            v11 = value11.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size
        spaceNeeded &+= MemoryLayout<T7>.size
        spaceNeeded &+= MemoryLayout<T8>.size
        spaceNeeded &+= MemoryLayout<T9>.size
        spaceNeeded &+= MemoryLayout<T10>.size
        spaceNeeded &+= MemoryLayout<T11>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            (basePtr + offset).copyMemory(from: &v7, byteCount: MemoryLayout<T7>.size)
            offset = offset &+ MemoryLayout<T7>.size
            (basePtr + offset).copyMemory(from: &v8, byteCount: MemoryLayout<T8>.size)
            offset = offset &+ MemoryLayout<T8>.size
            (basePtr + offset).copyMemory(from: &v9, byteCount: MemoryLayout<T9>.size)
            offset = offset &+ MemoryLayout<T9>.size
            (basePtr + offset).copyMemory(from: &v10, byteCount: MemoryLayout<T10>.size)
            offset = offset &+ MemoryLayout<T10>.size
            (basePtr + offset).copyMemory(from: &v11, byteCount: MemoryLayout<T11>.size)
            offset = offset &+ MemoryLayout<T11>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger,
        T12: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12).Type = (
            T1,
            T2,
            T3,
            T4,
            T5,
            T6,
            T7,
            T8,
            T9,
            T10,
            T11,
            T12
        ).self
    ) -> (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size
        bytesRequired &+= MemoryLayout<T7>.size
        bytesRequired &+= MemoryLayout<T8>.size
        bytesRequired &+= MemoryLayout<T9>.size
        bytesRequired &+= MemoryLayout<T10>.size
        bytesRequired &+= MemoryLayout<T11>.size
        bytesRequired &+= MemoryLayout<T12>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var v7: T7 = 0
        var v8: T8 = 0
        var v9: T9 = 0
        var v10: T10 = 0
        var v11: T11 = 0
        var v12: T12 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            withUnsafeMutableBytes(of: &v7) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T7>.size)
            }
            offset = offset &+ MemoryLayout<T7>.size
            withUnsafeMutableBytes(of: &v8) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T8>.size)
            }
            offset = offset &+ MemoryLayout<T8>.size
            withUnsafeMutableBytes(of: &v9) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T9>.size)
            }
            offset = offset &+ MemoryLayout<T9>.size
            withUnsafeMutableBytes(of: &v10) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T10>.size)
            }
            offset = offset &+ MemoryLayout<T10>.size
            withUnsafeMutableBytes(of: &v11) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T11>.size)
            }
            offset = offset &+ MemoryLayout<T11>.size
            withUnsafeMutableBytes(of: &v12) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T12>.size)
            }
            offset = offset &+ MemoryLayout<T12>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6),
                T7(bigEndian: v7),
                T8(bigEndian: v8),
                T9(bigEndian: v9),
                T10(bigEndian: v10),
                T11(bigEndian: v11),
                T12(bigEndian: v12)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6),
                T7(littleEndian: v7),
                T8(littleEndian: v8),
                T9(littleEndian: v9),
                T10(littleEndian: v10),
                T11(littleEndian: v11),
                T12(littleEndian: v12)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger,
        T12: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        _ value7: T7,
        _ value8: T8,
        _ value9: T9,
        _ value10: T10,
        _ value11: T11,
        _ value12: T12,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12).Type = (
            T1,
            T2,
            T3,
            T4,
            T5,
            T6,
            T7,
            T8,
            T9,
            T10,
            T11,
            T12
        ).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        var v7: T7
        var v8: T8
        var v9: T9
        var v10: T10
        var v11: T11
        var v12: T12
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
            v7 = value7.bigEndian
            v8 = value8.bigEndian
            v9 = value9.bigEndian
            v10 = value10.bigEndian
            v11 = value11.bigEndian
            v12 = value12.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
            v7 = value7.littleEndian
            v8 = value8.littleEndian
            v9 = value9.littleEndian
            v10 = value10.littleEndian
            v11 = value11.littleEndian
            v12 = value12.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size
        spaceNeeded &+= MemoryLayout<T7>.size
        spaceNeeded &+= MemoryLayout<T8>.size
        spaceNeeded &+= MemoryLayout<T9>.size
        spaceNeeded &+= MemoryLayout<T10>.size
        spaceNeeded &+= MemoryLayout<T11>.size
        spaceNeeded &+= MemoryLayout<T12>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            (basePtr + offset).copyMemory(from: &v7, byteCount: MemoryLayout<T7>.size)
            offset = offset &+ MemoryLayout<T7>.size
            (basePtr + offset).copyMemory(from: &v8, byteCount: MemoryLayout<T8>.size)
            offset = offset &+ MemoryLayout<T8>.size
            (basePtr + offset).copyMemory(from: &v9, byteCount: MemoryLayout<T9>.size)
            offset = offset &+ MemoryLayout<T9>.size
            (basePtr + offset).copyMemory(from: &v10, byteCount: MemoryLayout<T10>.size)
            offset = offset &+ MemoryLayout<T10>.size
            (basePtr + offset).copyMemory(from: &v11, byteCount: MemoryLayout<T11>.size)
            offset = offset &+ MemoryLayout<T11>.size
            (basePtr + offset).copyMemory(from: &v12, byteCount: MemoryLayout<T12>.size)
            offset = offset &+ MemoryLayout<T12>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger,
        T12: FixedWidthInteger,
        T13: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13).Type = (
            T1,
            T2,
            T3,
            T4,
            T5,
            T6,
            T7,
            T8,
            T9,
            T10,
            T11,
            T12,
            T13
        ).self
    ) -> (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size
        bytesRequired &+= MemoryLayout<T7>.size
        bytesRequired &+= MemoryLayout<T8>.size
        bytesRequired &+= MemoryLayout<T9>.size
        bytesRequired &+= MemoryLayout<T10>.size
        bytesRequired &+= MemoryLayout<T11>.size
        bytesRequired &+= MemoryLayout<T12>.size
        bytesRequired &+= MemoryLayout<T13>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var v7: T7 = 0
        var v8: T8 = 0
        var v9: T9 = 0
        var v10: T10 = 0
        var v11: T11 = 0
        var v12: T12 = 0
        var v13: T13 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            withUnsafeMutableBytes(of: &v7) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T7>.size)
            }
            offset = offset &+ MemoryLayout<T7>.size
            withUnsafeMutableBytes(of: &v8) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T8>.size)
            }
            offset = offset &+ MemoryLayout<T8>.size
            withUnsafeMutableBytes(of: &v9) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T9>.size)
            }
            offset = offset &+ MemoryLayout<T9>.size
            withUnsafeMutableBytes(of: &v10) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T10>.size)
            }
            offset = offset &+ MemoryLayout<T10>.size
            withUnsafeMutableBytes(of: &v11) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T11>.size)
            }
            offset = offset &+ MemoryLayout<T11>.size
            withUnsafeMutableBytes(of: &v12) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T12>.size)
            }
            offset = offset &+ MemoryLayout<T12>.size
            withUnsafeMutableBytes(of: &v13) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T13>.size)
            }
            offset = offset &+ MemoryLayout<T13>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6),
                T7(bigEndian: v7),
                T8(bigEndian: v8),
                T9(bigEndian: v9),
                T10(bigEndian: v10),
                T11(bigEndian: v11),
                T12(bigEndian: v12),
                T13(bigEndian: v13)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6),
                T7(littleEndian: v7),
                T8(littleEndian: v8),
                T9(littleEndian: v9),
                T10(littleEndian: v10),
                T11(littleEndian: v11),
                T12(littleEndian: v12),
                T13(littleEndian: v13)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger,
        T12: FixedWidthInteger,
        T13: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        _ value7: T7,
        _ value8: T8,
        _ value9: T9,
        _ value10: T10,
        _ value11: T11,
        _ value12: T12,
        _ value13: T13,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13).Type = (
            T1,
            T2,
            T3,
            T4,
            T5,
            T6,
            T7,
            T8,
            T9,
            T10,
            T11,
            T12,
            T13
        ).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        var v7: T7
        var v8: T8
        var v9: T9
        var v10: T10
        var v11: T11
        var v12: T12
        var v13: T13
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
            v7 = value7.bigEndian
            v8 = value8.bigEndian
            v9 = value9.bigEndian
            v10 = value10.bigEndian
            v11 = value11.bigEndian
            v12 = value12.bigEndian
            v13 = value13.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
            v7 = value7.littleEndian
            v8 = value8.littleEndian
            v9 = value9.littleEndian
            v10 = value10.littleEndian
            v11 = value11.littleEndian
            v12 = value12.littleEndian
            v13 = value13.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size
        spaceNeeded &+= MemoryLayout<T7>.size
        spaceNeeded &+= MemoryLayout<T8>.size
        spaceNeeded &+= MemoryLayout<T9>.size
        spaceNeeded &+= MemoryLayout<T10>.size
        spaceNeeded &+= MemoryLayout<T11>.size
        spaceNeeded &+= MemoryLayout<T12>.size
        spaceNeeded &+= MemoryLayout<T13>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            (basePtr + offset).copyMemory(from: &v7, byteCount: MemoryLayout<T7>.size)
            offset = offset &+ MemoryLayout<T7>.size
            (basePtr + offset).copyMemory(from: &v8, byteCount: MemoryLayout<T8>.size)
            offset = offset &+ MemoryLayout<T8>.size
            (basePtr + offset).copyMemory(from: &v9, byteCount: MemoryLayout<T9>.size)
            offset = offset &+ MemoryLayout<T9>.size
            (basePtr + offset).copyMemory(from: &v10, byteCount: MemoryLayout<T10>.size)
            offset = offset &+ MemoryLayout<T10>.size
            (basePtr + offset).copyMemory(from: &v11, byteCount: MemoryLayout<T11>.size)
            offset = offset &+ MemoryLayout<T11>.size
            (basePtr + offset).copyMemory(from: &v12, byteCount: MemoryLayout<T12>.size)
            offset = offset &+ MemoryLayout<T12>.size
            (basePtr + offset).copyMemory(from: &v13, byteCount: MemoryLayout<T13>.size)
            offset = offset &+ MemoryLayout<T13>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger,
        T12: FixedWidthInteger,
        T13: FixedWidthInteger,
        T14: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14).Type = (
            T1,
            T2,
            T3,
            T4,
            T5,
            T6,
            T7,
            T8,
            T9,
            T10,
            T11,
            T12,
            T13,
            T14
        ).self
    ) -> (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size
        bytesRequired &+= MemoryLayout<T7>.size
        bytesRequired &+= MemoryLayout<T8>.size
        bytesRequired &+= MemoryLayout<T9>.size
        bytesRequired &+= MemoryLayout<T10>.size
        bytesRequired &+= MemoryLayout<T11>.size
        bytesRequired &+= MemoryLayout<T12>.size
        bytesRequired &+= MemoryLayout<T13>.size
        bytesRequired &+= MemoryLayout<T14>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var v7: T7 = 0
        var v8: T8 = 0
        var v9: T9 = 0
        var v10: T10 = 0
        var v11: T11 = 0
        var v12: T12 = 0
        var v13: T13 = 0
        var v14: T14 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            withUnsafeMutableBytes(of: &v7) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T7>.size)
            }
            offset = offset &+ MemoryLayout<T7>.size
            withUnsafeMutableBytes(of: &v8) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T8>.size)
            }
            offset = offset &+ MemoryLayout<T8>.size
            withUnsafeMutableBytes(of: &v9) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T9>.size)
            }
            offset = offset &+ MemoryLayout<T9>.size
            withUnsafeMutableBytes(of: &v10) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T10>.size)
            }
            offset = offset &+ MemoryLayout<T10>.size
            withUnsafeMutableBytes(of: &v11) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T11>.size)
            }
            offset = offset &+ MemoryLayout<T11>.size
            withUnsafeMutableBytes(of: &v12) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T12>.size)
            }
            offset = offset &+ MemoryLayout<T12>.size
            withUnsafeMutableBytes(of: &v13) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T13>.size)
            }
            offset = offset &+ MemoryLayout<T13>.size
            withUnsafeMutableBytes(of: &v14) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T14>.size)
            }
            offset = offset &+ MemoryLayout<T14>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6),
                T7(bigEndian: v7),
                T8(bigEndian: v8),
                T9(bigEndian: v9),
                T10(bigEndian: v10),
                T11(bigEndian: v11),
                T12(bigEndian: v12),
                T13(bigEndian: v13),
                T14(bigEndian: v14)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6),
                T7(littleEndian: v7),
                T8(littleEndian: v8),
                T9(littleEndian: v9),
                T10(littleEndian: v10),
                T11(littleEndian: v11),
                T12(littleEndian: v12),
                T13(littleEndian: v13),
                T14(littleEndian: v14)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger,
        T12: FixedWidthInteger,
        T13: FixedWidthInteger,
        T14: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        _ value7: T7,
        _ value8: T8,
        _ value9: T9,
        _ value10: T10,
        _ value11: T11,
        _ value12: T12,
        _ value13: T13,
        _ value14: T14,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14).Type = (
            T1,
            T2,
            T3,
            T4,
            T5,
            T6,
            T7,
            T8,
            T9,
            T10,
            T11,
            T12,
            T13,
            T14
        ).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        var v7: T7
        var v8: T8
        var v9: T9
        var v10: T10
        var v11: T11
        var v12: T12
        var v13: T13
        var v14: T14
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
            v7 = value7.bigEndian
            v8 = value8.bigEndian
            v9 = value9.bigEndian
            v10 = value10.bigEndian
            v11 = value11.bigEndian
            v12 = value12.bigEndian
            v13 = value13.bigEndian
            v14 = value14.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
            v7 = value7.littleEndian
            v8 = value8.littleEndian
            v9 = value9.littleEndian
            v10 = value10.littleEndian
            v11 = value11.littleEndian
            v12 = value12.littleEndian
            v13 = value13.littleEndian
            v14 = value14.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size
        spaceNeeded &+= MemoryLayout<T7>.size
        spaceNeeded &+= MemoryLayout<T8>.size
        spaceNeeded &+= MemoryLayout<T9>.size
        spaceNeeded &+= MemoryLayout<T10>.size
        spaceNeeded &+= MemoryLayout<T11>.size
        spaceNeeded &+= MemoryLayout<T12>.size
        spaceNeeded &+= MemoryLayout<T13>.size
        spaceNeeded &+= MemoryLayout<T14>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            (basePtr + offset).copyMemory(from: &v7, byteCount: MemoryLayout<T7>.size)
            offset = offset &+ MemoryLayout<T7>.size
            (basePtr + offset).copyMemory(from: &v8, byteCount: MemoryLayout<T8>.size)
            offset = offset &+ MemoryLayout<T8>.size
            (basePtr + offset).copyMemory(from: &v9, byteCount: MemoryLayout<T9>.size)
            offset = offset &+ MemoryLayout<T9>.size
            (basePtr + offset).copyMemory(from: &v10, byteCount: MemoryLayout<T10>.size)
            offset = offset &+ MemoryLayout<T10>.size
            (basePtr + offset).copyMemory(from: &v11, byteCount: MemoryLayout<T11>.size)
            offset = offset &+ MemoryLayout<T11>.size
            (basePtr + offset).copyMemory(from: &v12, byteCount: MemoryLayout<T12>.size)
            offset = offset &+ MemoryLayout<T12>.size
            (basePtr + offset).copyMemory(from: &v13, byteCount: MemoryLayout<T13>.size)
            offset = offset &+ MemoryLayout<T13>.size
            (basePtr + offset).copyMemory(from: &v14, byteCount: MemoryLayout<T14>.size)
            offset = offset &+ MemoryLayout<T14>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    public mutating func readMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger,
        T12: FixedWidthInteger,
        T13: FixedWidthInteger,
        T14: FixedWidthInteger,
        T15: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15).Type = (
            T1,
            T2,
            T3,
            T4,
            T5,
            T6,
            T7,
            T8,
            T9,
            T10,
            T11,
            T12,
            T13,
            T14,
            T15
        ).self
    ) -> (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15)? {
        var bytesRequired: Int = MemoryLayout<T1>.size
        bytesRequired &+= MemoryLayout<T2>.size
        bytesRequired &+= MemoryLayout<T3>.size
        bytesRequired &+= MemoryLayout<T4>.size
        bytesRequired &+= MemoryLayout<T5>.size
        bytesRequired &+= MemoryLayout<T6>.size
        bytesRequired &+= MemoryLayout<T7>.size
        bytesRequired &+= MemoryLayout<T8>.size
        bytesRequired &+= MemoryLayout<T9>.size
        bytesRequired &+= MemoryLayout<T10>.size
        bytesRequired &+= MemoryLayout<T11>.size
        bytesRequired &+= MemoryLayout<T12>.size
        bytesRequired &+= MemoryLayout<T13>.size
        bytesRequired &+= MemoryLayout<T14>.size
        bytesRequired &+= MemoryLayout<T15>.size

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        var v1: T1 = 0
        var v2: T2 = 0
        var v3: T3 = 0
        var v4: T4 = 0
        var v5: T5 = 0
        var v6: T6 = 0
        var v7: T7 = 0
        var v8: T8 = 0
        var v9: T9 = 0
        var v10: T10 = 0
        var v11: T11 = 0
        var v12: T12 = 0
        var v13: T13 = 0
        var v14: T14 = 0
        var v15: T15 = 0
        var offset = 0
        self.readWithUnsafeReadableBytes { ptr -> Int in
            assert(ptr.count >= bytesRequired)
            let basePtr = ptr.baseAddress! // safe, ptr is non-empty
            withUnsafeMutableBytes(of: &v1) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T1>.size)
            }
            offset = offset &+ MemoryLayout<T1>.size
            withUnsafeMutableBytes(of: &v2) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T2>.size)
            }
            offset = offset &+ MemoryLayout<T2>.size
            withUnsafeMutableBytes(of: &v3) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T3>.size)
            }
            offset = offset &+ MemoryLayout<T3>.size
            withUnsafeMutableBytes(of: &v4) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T4>.size)
            }
            offset = offset &+ MemoryLayout<T4>.size
            withUnsafeMutableBytes(of: &v5) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T5>.size)
            }
            offset = offset &+ MemoryLayout<T5>.size
            withUnsafeMutableBytes(of: &v6) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T6>.size)
            }
            offset = offset &+ MemoryLayout<T6>.size
            withUnsafeMutableBytes(of: &v7) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T7>.size)
            }
            offset = offset &+ MemoryLayout<T7>.size
            withUnsafeMutableBytes(of: &v8) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T8>.size)
            }
            offset = offset &+ MemoryLayout<T8>.size
            withUnsafeMutableBytes(of: &v9) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T9>.size)
            }
            offset = offset &+ MemoryLayout<T9>.size
            withUnsafeMutableBytes(of: &v10) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T10>.size)
            }
            offset = offset &+ MemoryLayout<T10>.size
            withUnsafeMutableBytes(of: &v11) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T11>.size)
            }
            offset = offset &+ MemoryLayout<T11>.size
            withUnsafeMutableBytes(of: &v12) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T12>.size)
            }
            offset = offset &+ MemoryLayout<T12>.size
            withUnsafeMutableBytes(of: &v13) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T13>.size)
            }
            offset = offset &+ MemoryLayout<T13>.size
            withUnsafeMutableBytes(of: &v14) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T14>.size)
            }
            offset = offset &+ MemoryLayout<T14>.size
            withUnsafeMutableBytes(of: &v15) { destPtr in
                destPtr.baseAddress!.copyMemory(from: basePtr + offset, byteCount: MemoryLayout<T15>.size)
            }
            offset = offset &+ MemoryLayout<T15>.size
            assert(offset == bytesRequired)
            return offset
        }
        switch endianness {
        case .big:
            return (
                T1(bigEndian: v1),
                T2(bigEndian: v2),
                T3(bigEndian: v3),
                T4(bigEndian: v4),
                T5(bigEndian: v5),
                T6(bigEndian: v6),
                T7(bigEndian: v7),
                T8(bigEndian: v8),
                T9(bigEndian: v9),
                T10(bigEndian: v10),
                T11(bigEndian: v11),
                T12(bigEndian: v12),
                T13(bigEndian: v13),
                T14(bigEndian: v14),
                T15(bigEndian: v15)
            )
        case .little:
            return (
                T1(littleEndian: v1),
                T2(littleEndian: v2),
                T3(littleEndian: v3),
                T4(littleEndian: v4),
                T5(littleEndian: v5),
                T6(littleEndian: v6),
                T7(littleEndian: v7),
                T8(littleEndian: v8),
                T9(littleEndian: v9),
                T10(littleEndian: v10),
                T11(littleEndian: v11),
                T12(littleEndian: v12),
                T13(littleEndian: v13),
                T14(littleEndian: v14),
                T15(littleEndian: v15)
            )
        }
    }

    @inlinable
    @_alwaysEmitIntoClient
    @discardableResult
    public mutating func writeMultipleIntegers<
        T1: FixedWidthInteger,
        T2: FixedWidthInteger,
        T3: FixedWidthInteger,
        T4: FixedWidthInteger,
        T5: FixedWidthInteger,
        T6: FixedWidthInteger,
        T7: FixedWidthInteger,
        T8: FixedWidthInteger,
        T9: FixedWidthInteger,
        T10: FixedWidthInteger,
        T11: FixedWidthInteger,
        T12: FixedWidthInteger,
        T13: FixedWidthInteger,
        T14: FixedWidthInteger,
        T15: FixedWidthInteger
    >(
        _ value1: T1,
        _ value2: T2,
        _ value3: T3,
        _ value4: T4,
        _ value5: T5,
        _ value6: T6,
        _ value7: T7,
        _ value8: T8,
        _ value9: T9,
        _ value10: T10,
        _ value11: T11,
        _ value12: T12,
        _ value13: T13,
        _ value14: T14,
        _ value15: T15,
        endianness: Endianness = .big,
        as _: (T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15).Type = (
            T1,
            T2,
            T3,
            T4,
            T5,
            T6,
            T7,
            T8,
            T9,
            T10,
            T11,
            T12,
            T13,
            T14,
            T15
        ).self
    ) -> Int {
        var v1: T1
        var v2: T2
        var v3: T3
        var v4: T4
        var v5: T5
        var v6: T6
        var v7: T7
        var v8: T8
        var v9: T9
        var v10: T10
        var v11: T11
        var v12: T12
        var v13: T13
        var v14: T14
        var v15: T15
        switch endianness {
        case .big:
            v1 = value1.bigEndian
            v2 = value2.bigEndian
            v3 = value3.bigEndian
            v4 = value4.bigEndian
            v5 = value5.bigEndian
            v6 = value6.bigEndian
            v7 = value7.bigEndian
            v8 = value8.bigEndian
            v9 = value9.bigEndian
            v10 = value10.bigEndian
            v11 = value11.bigEndian
            v12 = value12.bigEndian
            v13 = value13.bigEndian
            v14 = value14.bigEndian
            v15 = value15.bigEndian
        case .little:
            v1 = value1.littleEndian
            v2 = value2.littleEndian
            v3 = value3.littleEndian
            v4 = value4.littleEndian
            v5 = value5.littleEndian
            v6 = value6.littleEndian
            v7 = value7.littleEndian
            v8 = value8.littleEndian
            v9 = value9.littleEndian
            v10 = value10.littleEndian
            v11 = value11.littleEndian
            v12 = value12.littleEndian
            v13 = value13.littleEndian
            v14 = value14.littleEndian
            v15 = value15.littleEndian
        }

        var spaceNeeded: Int = MemoryLayout<T1>.size
        spaceNeeded &+= MemoryLayout<T2>.size
        spaceNeeded &+= MemoryLayout<T3>.size
        spaceNeeded &+= MemoryLayout<T4>.size
        spaceNeeded &+= MemoryLayout<T5>.size
        spaceNeeded &+= MemoryLayout<T6>.size
        spaceNeeded &+= MemoryLayout<T7>.size
        spaceNeeded &+= MemoryLayout<T8>.size
        spaceNeeded &+= MemoryLayout<T9>.size
        spaceNeeded &+= MemoryLayout<T10>.size
        spaceNeeded &+= MemoryLayout<T11>.size
        spaceNeeded &+= MemoryLayout<T12>.size
        spaceNeeded &+= MemoryLayout<T13>.size
        spaceNeeded &+= MemoryLayout<T14>.size
        spaceNeeded &+= MemoryLayout<T15>.size

        return self.writeWithUnsafeMutableBytes(minimumWritableBytes: spaceNeeded) { ptr -> Int in
            assert(ptr.count >= spaceNeeded)
            var offset = 0
            let basePtr = ptr.baseAddress! // safe: pointer is non zero length
            (basePtr + offset).copyMemory(from: &v1, byteCount: MemoryLayout<T1>.size)
            offset = offset &+ MemoryLayout<T1>.size
            (basePtr + offset).copyMemory(from: &v2, byteCount: MemoryLayout<T2>.size)
            offset = offset &+ MemoryLayout<T2>.size
            (basePtr + offset).copyMemory(from: &v3, byteCount: MemoryLayout<T3>.size)
            offset = offset &+ MemoryLayout<T3>.size
            (basePtr + offset).copyMemory(from: &v4, byteCount: MemoryLayout<T4>.size)
            offset = offset &+ MemoryLayout<T4>.size
            (basePtr + offset).copyMemory(from: &v5, byteCount: MemoryLayout<T5>.size)
            offset = offset &+ MemoryLayout<T5>.size
            (basePtr + offset).copyMemory(from: &v6, byteCount: MemoryLayout<T6>.size)
            offset = offset &+ MemoryLayout<T6>.size
            (basePtr + offset).copyMemory(from: &v7, byteCount: MemoryLayout<T7>.size)
            offset = offset &+ MemoryLayout<T7>.size
            (basePtr + offset).copyMemory(from: &v8, byteCount: MemoryLayout<T8>.size)
            offset = offset &+ MemoryLayout<T8>.size
            (basePtr + offset).copyMemory(from: &v9, byteCount: MemoryLayout<T9>.size)
            offset = offset &+ MemoryLayout<T9>.size
            (basePtr + offset).copyMemory(from: &v10, byteCount: MemoryLayout<T10>.size)
            offset = offset &+ MemoryLayout<T10>.size
            (basePtr + offset).copyMemory(from: &v11, byteCount: MemoryLayout<T11>.size)
            offset = offset &+ MemoryLayout<T11>.size
            (basePtr + offset).copyMemory(from: &v12, byteCount: MemoryLayout<T12>.size)
            offset = offset &+ MemoryLayout<T12>.size
            (basePtr + offset).copyMemory(from: &v13, byteCount: MemoryLayout<T13>.size)
            offset = offset &+ MemoryLayout<T13>.size
            (basePtr + offset).copyMemory(from: &v14, byteCount: MemoryLayout<T14>.size)
            offset = offset &+ MemoryLayout<T14>.size
            (basePtr + offset).copyMemory(from: &v15, byteCount: MemoryLayout<T15>.size)
            offset = offset &+ MemoryLayout<T15>.size
            assert(offset == spaceNeeded)
            return offset
        }
    }
}
