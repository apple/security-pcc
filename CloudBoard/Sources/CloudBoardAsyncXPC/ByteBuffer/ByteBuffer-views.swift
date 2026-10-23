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

/// A view into a portion of a `ByteBuffer`.
///
/// A `ByteBufferView` is useful whenever a `Collection where Element == UInt8` representing a portion of a
/// `ByteBuffer` is needed.
public struct ByteBufferView: RandomAccessCollection, Sendable {
    public typealias Element = UInt8
    public typealias Index = Int
    public typealias SubSequence = ByteBufferView

    /* private but usableFromInline */ @usableFromInline var _buffer: ByteBuffer
    /* private but usableFromInline */ @usableFromInline var _range: Range<Index>

    @inlinable
    internal init(buffer: ByteBuffer, range: Range<Index>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.capacity)
        self._buffer = buffer
        self._range = range
    }

    /// Creates a `ByteBufferView` from the readable bytes of the given `buffer`.
    @inlinable
    public init(_ buffer: ByteBuffer) {
        self = ByteBufferView(buffer: buffer, range: buffer.readerIndex ..< buffer.writerIndex)
    }

    @inlinable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try self._buffer.withVeryUnsafeBytes { ptr in
            try body(UnsafeRawBufferPointer(
                start: ptr.baseAddress!.advanced(by: self._range.lowerBound),
                count: self._range.count
            ))
        }
    }

    @inlinable
    public var startIndex: Index {
        return self._range.lowerBound
    }

    @inlinable
    public var endIndex: Index {
        return self._range.upperBound
    }

    @inlinable
    public func index(after i: Index) -> Index {
        return i + 1
    }

    @inlinable
    public var count: Int {
        // Unchecked is safe here: Range enforces that upperBound is strictly greater than
        // lower bound, and we guarantee that _range.lowerBound >= 0.
        return self._range.upperBound &- self._range.lowerBound
    }

    @inlinable
    public subscript(position: Index) -> UInt8 {
        get {
            guard position >= self._range.lowerBound, position < self._range.upperBound else {
                preconditionFailure("index \(position) out of range")
            }
            return self._buffer.getInteger(at: position)! // range check above
        }
        set {
            guard position >= self._range.lowerBound, position < self._range.upperBound else {
                preconditionFailure("index \(position) out of range")
            }
            self._buffer.setInteger(newValue, at: position)
        }
    }

    @inlinable
    public subscript(range: Range<Index>) -> ByteBufferView {
        get {
            return ByteBufferView(buffer: self._buffer, range: range)
        }
        set {
            self.replaceSubrange(range, with: newValue)
        }
    }

    @inlinable
    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R? {
        return try self.withUnsafeBytes { bytes in
            return try body(bytes.bindMemory(to: UInt8.self))
        }
    }

    @inlinable
    public func _customIndexOfEquatableElement(_ element: Element) -> Index?? {
        return .some(self.withUnsafeBytes { ptr -> Index? in
            return ptr.firstIndex(of: element).map { $0 + self._range.lowerBound }
        })
    }

    @inlinable
    public func _customLastIndexOfEquatableElement(_ element: Element) -> Index?? {
        return .some(self.withUnsafeBytes { ptr -> Index? in
            return ptr.lastIndex(of: element).map { $0 + self._range.lowerBound }
        })
    }

    @inlinable
    public func _customContainsEquatableElement(_ element: Element) -> Bool? {
        return .some(self.withUnsafeBytes { ptr -> Bool in
            return ptr.contains(element)
        })
    }

    @inlinable
    public func _copyContents(
        initializing ptr: UnsafeMutableBufferPointer<UInt8>
    ) -> (Iterator, UnsafeMutableBufferPointer<UInt8>.Index) {
        precondition(ptr.count >= self.count)

        let bytesToWrite = self.count

        let endIndex = self.withContiguousStorageIfAvailable { ourBytes in
            ptr.initialize(from: ourBytes).1
        }
        precondition(endIndex == bytesToWrite)

        let iterator = self[self.endIndex ..< self.endIndex].makeIterator()
        return (iterator, bytesToWrite)
    }

    // These are implemented as no-ops for performance reasons.
    @inlinable
    public func _failEarlyRangeCheck(_: Index, bounds _: Range<Index>) {}

    @inlinable
    public func _failEarlyRangeCheck(_: Index, bounds _: ClosedRange<Index>) {}

    @inlinable
    public func _failEarlyRangeCheck(_: Range<Index>, bounds _: Range<Index>) {}
}

extension ByteBufferView: MutableCollection {}

extension ByteBufferView: RangeReplaceableCollection {
    // required by `RangeReplaceableCollection`
    @inlinable
    public init() {
        self = ByteBufferView(ByteBuffer())
    }

    /// Reserves enough space in the underlying `ByteBuffer` such that this view can
    /// store the specified number of bytes without reallocation.
    ///
    /// See the documentation for ``ByteBuffer/reserveCapacity(_:)`` for more details.
    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        let additionalCapacity = minimumCapacity - self.count
        if additionalCapacity > 0 {
            self._buffer.reserveCapacity(self._buffer.capacity + additionalCapacity)
        }
    }

    /// Writes a single byte to the underlying `ByteBuffer`.
    @inlinable
    public mutating func append(_ byte: UInt8) {
        // ``CollectionOfOne`` has no witness for
        // ``Sequence.withContiguousStorageIfAvailable(_:)``. so we do this instead:
        self._buffer.setInteger(byte, at: self._range.upperBound)
        self._range = self._range.lowerBound ..< self._range.upperBound.advanced(by: 1)
        self._buffer.moveWriterIndex(to: self._range.upperBound)
    }

    /// Writes a sequence of bytes to the underlying `ByteBuffer`.
    @inlinable
    public mutating func append(contentsOf bytes: some Sequence<UInt8>) {
        let written = self._buffer.setBytes(bytes, at: self._range.upperBound)
        self._range = self._range.lowerBound ..< self._range.upperBound.advanced(by: written)
        self._buffer.moveWriterIndex(to: self._range.upperBound)
    }

    @inlinable
    public mutating func replaceSubrange<C: Collection>(_ subrange: Range<Index>, with newElements: C)
    where ByteBufferView.Element == C.Element {
        precondition(
            subrange.startIndex >= self.startIndex && subrange.endIndex <= self.endIndex,
            "subrange out of bounds"
        )

        if newElements.count == subrange.count {
            self._buffer.setBytes(newElements, at: subrange.startIndex)
        } else if newElements.count < subrange.count {
            // Replace the subrange.
            self._buffer.setBytes(newElements, at: subrange.startIndex)

            // Remove the unwanted bytes between the newly copied bytes and the end of the subrange.
            // try! is fine here: the copied range is within the view and the length can't be negative.
            try! self._buffer.copyBytes(
                at: subrange.endIndex,
                to: subrange.startIndex.advanced(by: newElements.count),
                length: subrange.endIndex.distance(to: self._buffer.writerIndex)
            )

            // Shorten the range.
            let removedBytes = subrange.count - newElements.count
            self._buffer.moveWriterIndex(to: self._buffer.writerIndex - removedBytes)
            self._range = self._range.dropLast(removedBytes)
        } else {
            // Make space for the new elements.
            // try! is fine here: the copied range is within the view and the length can't be negative.
            try! self._buffer.copyBytes(
                at: subrange.endIndex,
                to: subrange.startIndex.advanced(by: newElements.count),
                length: subrange.endIndex.distance(to: self._buffer.writerIndex)
            )

            // Replace the bytes.
            self._buffer.setBytes(newElements, at: subrange.startIndex)

            // Widen the range.
            let additionalByteCount = newElements.count - subrange.count
            self._buffer.moveWriterIndex(forwardBy: additionalByteCount)
            self._range = self._range.startIndex ..< self._range.endIndex.advanced(by: additionalByteCount)
        }
    }
}

extension ByteBuffer {
    /// A view into the readable bytes of the `ByteBuffer`.
    @inlinable
    public var readableBytesView: ByteBufferView {
        return ByteBufferView(self)
    }

    /// Returns a view into some portion of the readable bytes of a `ByteBuffer`.
    ///
    /// - parameters:
    ///   - index: The index the view should start at
    ///   - length: The length of the view (in bytes)
    /// - returns: A view into a portion of a `ByteBuffer` or `nil` if the requested bytes were not readable.
    @inlinable
    public func viewBytes(at index: Int, length: Int) -> ByteBufferView? {
        guard length >= 0, index >= self.readerIndex, index <= self.writerIndex - length else {
            return nil
        }

        return ByteBufferView(buffer: self, range: index ..< (index + length))
    }

    /// Create a `ByteBuffer` from the given `ByteBufferView`s range.
    ///
    /// - parameter view: The `ByteBufferView` which you want to get a `ByteBuffer` from.
    @inlinable
    public init(_ view: ByteBufferView) {
        self = view._buffer.getSlice(at: view.startIndex, length: view.count)!
    }
}

extension ByteBufferView: Equatable {
    /// required by `Equatable`
    @inlinable
    public static func == (lhs: ByteBufferView, rhs: ByteBufferView) -> Bool {
        guard lhs._range.count == rhs._range.count else {
            return false
        }

        // A well-formed ByteBufferView can never have a range that is out-of-bounds of the backing ByteBuffer.
        // As a result, these getSlice calls can never fail, and we'd like to know it if they do.
        let leftBufferSlice = lhs._buffer.getSlice(at: lhs._range.startIndex, length: lhs._range.count)!
        let rightBufferSlice = rhs._buffer.getSlice(at: rhs._range.startIndex, length: rhs._range.count)!

        return leftBufferSlice == rightBufferSlice
    }
}

extension ByteBufferView: Hashable {
    /// required by `Hashable`
    @inlinable
    public func hash(into hasher: inout Hasher) {
        // A well-formed ByteBufferView can never have a range that is out-of-bounds of the backing ByteBuffer.
        // As a result, this getSlice call can never fail, and we'd like to know it if it does.
        hasher.combine(self._buffer.getSlice(at: self._range.startIndex, length: self._range.count)!)
    }
}

extension ByteBufferView: ExpressibleByArrayLiteral {
    /// required by `ExpressibleByArrayLiteral`
    @inlinable
    public init(arrayLiteral elements: Element...) {
        self.init(elements)
    }
}
