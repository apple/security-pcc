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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

// from internal SwiftTLS/ByteBuffer

import Foundation

enum TransparencyTLSError: Error, Equatable, LocalizedError, CustomNSError {
    case excessBytes
    case truncatedMessage

    var errorCode: Int {
        switch self {
        case .excessBytes: return 1
        case .truncatedMessage: return 2
        }
    }
}

// A type that brings over many of the conveniences of NIO's ByteBuffer, reimplemented on Data.
//  This is not a truly hardened version of NIO's ByteBuffer - good enough for what we need.
struct TransparencyByteBuffer {
    private var backingData: Data
    private(set) var readerIndex: Data.Index

    // This is a divergence from NIO's bytebuffer, but if we never move the writer index then we can avoid
    // needing anything else.
    var writerIndex: Data.Index {
        return self.backingData.endIndex
    }

    init(data: Data) {
        self.backingData = data
        self.readerIndex = data.startIndex
    }

    init<Bytes: Sequence>(bytes: Bytes) where Bytes.Element == UInt8 {
        self = TransparencyByteBuffer(data: Data(bytes))
    }

    var readableBytes: Int {
        return self.writerIndex - self.readerIndex
    }

    @discardableResult
    mutating func writeInteger<IntegerType: FixedWidthInteger>(_ integer: IntegerType, as: IntegerType.Type = IntegerType.self) -> Int {
        let byteWidth = IntegerType.byteWidth
        var networkByteOrder = integer.bigEndian
        withUnsafeBytes(of: &networkByteOrder) {
            precondition($0.count == byteWidth)
            self.backingData.append(contentsOf: $0)
        }

        return byteWidth
    }

    @discardableResult
    mutating func setInteger<IntegerType: FixedWidthInteger>(_ integer: IntegerType, at index: Data.Index, as: IntegerType.Type = IntegerType.self) -> Int {
        // Valiate we have space.
        let byteWidth = IntegerType.byteWidth
        let endIndex = index + byteWidth

        precondition(index >= self.readerIndex)
        precondition(endIndex <= self.writerIndex)

        var networkByteOrder = integer.bigEndian
        withUnsafeBytes(of: &networkByteOrder) {
            precondition($0.count == byteWidth)
            self.backingData.replaceSubrange(index..<endIndex, with: $0)
        }

        return byteWidth
    }

    mutating func readInteger<IntegerType: FixedWidthInteger>(as: IntegerType.Type = IntegerType.self) -> IntegerType? {
        var value = IntegerType.zero
        let byteCount = IntegerType.byteWidth
        let endIndex = self.readerIndex + byteCount

        guard self.writerIndex >= endIndex else {
            return nil
        }
        defer {
            self.readerIndex = endIndex
        }

        _ = withUnsafeMutableBytes(of: &value) {
            self.backingData.copyBytes(to: $0, from: self.readerIndex..<endIndex)
        }
        return IntegerType(bigEndian: value)
    }

    @discardableResult
    mutating func writeImmutableBuffer(_ buffer: TransparencyByteBuffer) -> Int {
        let sliceToAppend = buffer.backingData[buffer.readerIndex...]
        self.backingData.append(sliceToAppend)
        return sliceToAppend.count
    }

    @discardableResult
    mutating func setImmutableBuffer(_ buffer: TransparencyByteBuffer, at index: Int) -> Int {
        precondition(index <= self.writerIndex && index >= self.backingData.startIndex)
        let sliceToInsert = buffer.backingData[buffer.readerIndex...]

        // Unchecked math here is safe because we validate the index is in the range already.
        let bytesToOverwrite = min(sliceToInsert.count, self.writerIndex &- index)
        let replacementRange = index..<(index &+ bytesToOverwrite)
        self.backingData[replacementRange] = sliceToInsert
        return sliceToInsert.count
    }

    @discardableResult
    mutating func writeBuffer(_ buffer: inout TransparencyByteBuffer) -> Int {
        defer {
            buffer.readerIndex = buffer.writerIndex
        }
        return self.writeImmutableBuffer(buffer)
    }

    mutating func readSlice(length: Int) -> TransparencyByteBuffer? {
        let endIndex = self.readerIndex + length
        guard endIndex <= self.writerIndex else {
            return nil
        }

        let slice = self.backingData[self.readerIndex..<endIndex]
        self.readerIndex = endIndex
        return TransparencyByteBuffer(data: slice)
    }

    var readableBytesView: Data {
        return self.backingData[self.readerIndex..<self.writerIndex]
    }

    mutating func readBytes(length: Int) -> [UInt8]? {
        let endIndex = self.readerIndex + length
        guard endIndex <= self.writerIndex else {
            return nil
        }
        defer {
            self.readerIndex = endIndex
        }
        return Array(self.backingData[self.readerIndex..<endIndex])
    }

    @discardableResult
    mutating func writeBytes(_ bytes: [UInt8]) -> Int {
        self.backingData.append(contentsOf: bytes)
        return bytes.count
    }

    @discardableResult
    mutating func writeBytes<Bytes: Collection>(_ bytes: Bytes) -> Int where Bytes.Element == UInt8 {
        self.backingData.append(contentsOf: bytes)
        return bytes.count
    }

    mutating func moveReaderIndex(to newIndex: Data.Index) {
        precondition(newIndex >= self.backingData.startIndex)
        precondition(newIndex <= self.backingData.endIndex)

        self.readerIndex = newIndex
    }

    mutating func moveWriterIndex(forwardBy distance: Int) {
        self.backingData.append(contentsOf: repeatElement(0, count: distance))
    }
}

extension TransparencyByteBuffer {
    @discardableResult
    mutating func writeVariableLengthVector<LengthField: FixedWidthInteger>(
        lengthFieldType: LengthField.Type,
        _ writer: (inout TransparencyByteBuffer) -> Int
    ) -> Int {
        // Reserve the place
        let lengthIndex = self.writerIndex
        let lengthLength = self.writeInteger(.zero, as: LengthField.self)
        let bodyLength = writer(&self)
        self.setInteger(LengthField(bodyLength), at: lengthIndex)
        return lengthLength + bodyLength
    }

    @discardableResult
    mutating func writeVariableLengthVectorUInt24(
        _ writer: (inout TransparencyByteBuffer) -> Int
    ) -> Int {
        // Reserve the place
        let lengthIndex = self.writerIndex
        let lengthLength = self.writeUInt24(0)
        let bodyLength = writer(&self)
        self.setUInt24(bodyLength, at: lengthIndex)
        return lengthLength + bodyLength
    }

    mutating func readVariableLengthVector<LengthField: FixedWidthInteger, ResultType>(
        lengthFieldType: LengthField.Type,
        _ reader: (inout TransparencyByteBuffer) throws -> ResultType
    ) throws -> ResultType? {
        return try self.rewindOnNilOrError { buffer in
            guard let length = buffer.readInteger(as: LengthField.self), var slice = buffer.readSlice(length: Int(length)) else {
                return nil
            }

            let result = try reader(&slice)
            guard slice.readableBytes == 0 else {
                throw TransparencyTLSError.excessBytes
            }

            return result
        }
    }

    mutating func readVariableLengthVectorUInt24<ResultType>(
        _ reader: (inout TransparencyByteBuffer) throws -> ResultType
    ) throws -> ResultType? {
        return try self.rewindOnNilOrError { buffer in
            guard let length = buffer.readUInt24(), var slice = buffer.readSlice(length: length) else {
                return nil
            }

            let result = try reader(&slice)
            guard slice.readableBytes == 0 else {
                throw TransparencyTLSError.excessBytes
            }

            return result
        }
    }

    mutating func rewindOnNilOrError<ResultType>(_ block: (inout TransparencyByteBuffer) throws -> ResultType?) rethrows -> ResultType? {
        let original = self

        do {
            guard let result = try block(&self) else {
                self = original
                return nil
            }
            return result
        } catch {
            self = original
            throw error
        }
    }

    @discardableResult
    mutating func writeUInt24(_ length: Int) -> Int {
        precondition(length < (1 << 24))
        let high = UInt8(truncatingIfNeeded: length >> 16)
        let low = UInt16(truncatingIfNeeded: length)

        return self.writeInteger(high) + self.writeInteger(low)
    }

    @discardableResult
    mutating func setUInt24(_ length: Int, at index: Int) -> Int {
        precondition(length < (1 << 24))
        let high = UInt8(truncatingIfNeeded: length >> 16)
        let low = UInt16(truncatingIfNeeded: length)

        var written = self.setInteger(high, at: index)
        written += self.setInteger(low, at: index + written)
        return written
    }

    mutating func readUInt24() -> Int? {
        guard let high = self.readInteger(as: UInt8.self), let low = self.readInteger(as: UInt16.self) else {
            return nil
        }

        return Int(high) << 16 | Int(low)
    }
}

extension TransparencyByteBuffer: Hashable {
    static func == (lhs: TransparencyByteBuffer, rhs: TransparencyByteBuffer) -> Bool {
        return lhs.readableBytesView == rhs.readableBytesView
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.readableBytesView)
    }
}

extension FixedWidthInteger {
    static var byteWidth: Int {
        return (bitWidth + 7) / 8
    }
}
