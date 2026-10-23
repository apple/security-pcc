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

extension ByteBuffer {
    public struct LengthPrefixError: Swift.Error {
        private enum BaseError {
            case messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat
            case messageCouldNotBeReadSuccessfully
        }

        private var baseError: BaseError

        public static let messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat: LengthPrefixError =
            .init(baseError: .messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat)
        public static let messageCouldNotBeReadSuccessfully: LengthPrefixError =
            .init(baseError: .messageCouldNotBeReadSuccessfully)
    }
}

extension ByteBuffer {
    /// Prefixes a message written by `writeMessage` with the number of bytes written as an `Integer`.
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to write the length prefix
    ///     - writeMessage: A closure that takes a buffer, writes a message to it and returns the number of bytes
    /// written
    /// - Throws: If the number of bytes written during `writeMessage` can not be exactly represented as the given
    /// `Integer` i.e. if the number of bytes written is greater than `Integer.max`
    /// - Returns: Number of total bytes written
    @discardableResult
    @inlinable
    public mutating func writeLengthPrefixed<Integer>(
        endianness: Endianness = .big,
        as _: Integer.Type,
        writeMessage: (inout ByteBuffer) throws -> Int
    ) throws -> Int where Integer: FixedWidthInteger {
        var totalBytesWritten = 0

        let lengthPrefixIndex = self.writerIndex
        // Write a zero as a placeholder which will later be overwritten by the actual number of bytes written
        totalBytesWritten += self.writeInteger(.zero, endianness: endianness, as: Integer.self)

        let startWriterIndex = self.writerIndex
        let messageLength = try writeMessage(&self)
        let endWriterIndex = self.writerIndex

        totalBytesWritten += messageLength

        let actualBytesWritten = endWriterIndex - startWriterIndex
        assert(
            actualBytesWritten == messageLength,
            "writeMessage returned \(messageLength) bytes, but actually \(actualBytesWritten) bytes were written, but they should be the same"
        )

        guard let lengthPrefix = Integer(exactly: messageLength) else {
            throw LengthPrefixError.messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat
        }

        self.setInteger(lengthPrefix, at: lengthPrefixIndex, endianness: endianness, as: Integer.self)

        return totalBytesWritten
    }
}

extension ByteBuffer {
    /// Reads an `Integer` from `self`, reads a slice of that length and passes it to `readMessage`.
    /// It is checked that `readMessage` returns a non-nil value.
    ///
    /// The `readerIndex` is **not** moved forward if the length prefix could not be read or `self` does not contain
    /// enough bytes. Otherwise `readerIndex` is moved forward even if `readMessage` throws or returns nil.
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to read the length prefix
    ///     - readMessage: A closure that takes a `ByteBuffer` slice which contains the message after the length prefix
    /// - Throws: if `readMessage` returns nil
    /// - Returns: `nil` if the length prefix could not be read,
    ///            the length prefix is negative or
    ///            the buffer does not contain enough bytes to read a message of this length.
    ///            Otherwise the result of `readMessage`.
    @inlinable
    public mutating func readLengthPrefixed<Integer, Result>(
        endianness: Endianness = .big,
        as _: Integer.Type,
        readMessage: (ByteBuffer) throws -> Result?
    ) throws -> Result? where Integer: FixedWidthInteger {
        guard let buffer = self.readLengthPrefixedSlice(endianness: endianness, as: Integer.self) else {
            return nil
        }
        guard let result = try readMessage(buffer) else {
            throw LengthPrefixError.messageCouldNotBeReadSuccessfully
        }
        return result
    }

    /// Reads an `Integer` from `self` and reads a slice of that length from `self` and returns it.
    ///
    /// If nil is returned, `readerIndex` is **not** moved forward.
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to read the length prefix
    /// - Returns: `nil` if the length prefix could not be read,
    ///            the length prefix is negative or
    ///            the buffer does not contain enough bytes to read a message of this length.
    ///            Otherwise the message after the length prefix.
    @inlinable
    public mutating func readLengthPrefixedSlice<Integer>(
        endianness: Endianness = .big,
        as _: Integer.Type
    ) -> ByteBuffer? where Integer: FixedWidthInteger {
        guard let result = self.getLengthPrefixedSlice(at: self.readerIndex, endianness: endianness, as: Integer.self)
        else {
            return nil
        }
        self._moveReaderIndex(forwardBy: MemoryLayout<Integer>.size + result.readableBytes)
        return result
    }

    /// Gets an `Integer` from `self` and gets a slice of that length from `self` and returns it.
    ///
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to get the length prefix
    /// - Returns: `nil` if the length prefix could not be read,
    ///            the length prefix is negative or
    ///            the buffer does not contain enough bytes to read a message of this length.
    ///            Otherwise the message after the length prefix.
    @inlinable
    public func getLengthPrefixedSlice<Integer>(
        at index: Int,
        endianness: Endianness = .big,
        as _: Integer.Type
    ) -> ByteBuffer? where Integer: FixedWidthInteger {
        guard let lengthPrefix = self.getInteger(at: index, endianness: endianness, as: Integer.self),
              let messageLength = Int(exactly: lengthPrefix),
              let messageBuffer = self.getSlice(at: index + MemoryLayout<Integer>.size, length: messageLength)
        else {
            return nil
        }

        return messageBuffer
    }
}
