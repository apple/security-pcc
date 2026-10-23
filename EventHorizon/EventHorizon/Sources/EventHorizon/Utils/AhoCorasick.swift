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

public final class AhoCorasickMatcher: @unchecked Sendable {

    private final class Node {
        nonisolated(unsafe) private var _sparseKeys: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0)
        nonisolated(unsafe) private var _sparseValues: (Node?, Node?, Node?, Node?, Node?, Node?, Node?, Node?) = (nil, nil, nil, nil, nil, nil, nil, nil)
        nonisolated(unsafe) private var _sparseCount: UInt8 = 0
        nonisolated(unsafe) private var _denseChildren: [Node?]?

        var failure: Node?
        var outputLink: Node?
        var patternIndex: Int = -1

        @inline(__always)
        func child(for byte: UInt8) -> Node? {
            if let dense = _denseChildren {
                return dense[Int(byte)]
            }
            let count = _sparseCount
            if count >= 1 && _sparseKeys.0 == byte {
                return _sparseValues.0
            }
            if count >= 2 && _sparseKeys.1 == byte {
                return _sparseValues.1
            }
            if count >= 3 && _sparseKeys.2 == byte {
                return _sparseValues.2
            }
            if count >= 4 && _sparseKeys.3 == byte {
                return _sparseValues.3
            }
            if count >= 5 && _sparseKeys.4 == byte {
                return _sparseValues.4
            }
            if count >= 6 && _sparseKeys.5 == byte {
                return _sparseValues.5
            }
            if count >= 7 && _sparseKeys.6 == byte {
                return _sparseValues.6
            }
            if count >= 8 && _sparseKeys.7 == byte {
                return _sparseValues.7
            }
            return nil
        }

        @inline(__always)
        private func sparseKey(at index: Int) -> UInt8 {
            switch index {
            case 0: return _sparseKeys.0
            case 1: return _sparseKeys.1
            case 2: return _sparseKeys.2
            case 3: return _sparseKeys.3
            case 4: return _sparseKeys.4
            case 5: return _sparseKeys.5
            case 6: return _sparseKeys.6
            case 7: return _sparseKeys.7
            default: fatalError("sparseKey index out of range")
            }
        }

        @inline(__always)
        private func sparseValue(at index: Int) -> Node? {
            switch index {
            case 0: return _sparseValues.0
            case 1: return _sparseValues.1
            case 2: return _sparseValues.2
            case 3: return _sparseValues.3
            case 4: return _sparseValues.4
            case 5: return _sparseValues.5
            case 6: return _sparseValues.6
            case 7: return _sparseValues.7
            default: fatalError("sparseValue index out of range")
            }
        }

        @inline(__always)
        private func setSparseKey(_ key: UInt8, at index: Int) {
            switch index {
            case 0: _sparseKeys.0 = key
            case 1: _sparseKeys.1 = key
            case 2: _sparseKeys.2 = key
            case 3: _sparseKeys.3 = key
            case 4: _sparseKeys.4 = key
            case 5: _sparseKeys.5 = key
            case 6: _sparseKeys.6 = key
            case 7: _sparseKeys.7 = key
            default: fatalError("setSparseKey index out of range")
            }
        }

        @inline(__always)
        private func setSparseValue(_ node: Node?, at index: Int) {
            switch index {
            case 0: _sparseValues.0 = node
            case 1: _sparseValues.1 = node
            case 2: _sparseValues.2 = node
            case 3: _sparseValues.3 = node
            case 4: _sparseValues.4 = node
            case 5: _sparseValues.5 = node
            case 6: _sparseValues.6 = node
            case 7: _sparseValues.7 = node
            default: fatalError("setSparseValue index out of range")
            }
        }

        func setChild(_ node: Node, for byte: UInt8) {
            if _denseChildren != nil {
                _denseChildren![Int(byte)] = node
                return
            }

            let count = Int(_sparseCount)

            for i in 0..<count where sparseKey(at: i) == byte {
                setSparseValue(node, at: i)
                return
            }

            if count < 8 {
                setSparseKey(byte, at: count)
                setSparseValue(node, at: count)
                _sparseCount = UInt8(count + 1)
            } else {
                var arr: [Node?] = Array(repeating: nil, count: 256)
                for i in 0..<count {
                    arr[Int(sparseKey(at: i))] = sparseValue(at: i)
                }
                arr[Int(byte)] = node
                _denseChildren = arr
            }
        }

        func forEachChild(_ body: (UInt8, Node) -> Void) {
            if let dense = _denseChildren {
                for i in 0..<256 {
                    if let child = dense[i] {
                        body(UInt8(i), child)
                    }
                }
                return
            }
            let count = Int(_sparseCount)
            for i in 0..<count {
                body(sparseKey(at: i), sparseValue(at: i)!)
            }
        }
    }

    private let root: Node

    public let patterns: [String]

    public var patternCount: Int { patterns.count }

    public init(patterns: [String]) {
        var seen = Set<String>()
        let unique = patterns.filter { seen.insert($0).inserted }
        self.patterns = unique

        self.root = Node()

        let patternBytes = unique.map { Array($0.utf8) }

        for (index, bytes) in patternBytes.enumerated() {
            var current = root
            for byte in bytes {
                if let child = current.child(for: byte) {
                    current = child
                } else {
                    let newNode = Node()
                    current.setChild(newNode, for: byte)
                    current = newNode
                }
            }
            current.patternIndex = index
        }

        buildFailureLinks()
    }

    private func buildFailureLinks() {
        var queue: [Node] = []

        root.forEachChild { _, child in
            child.failure = root
            queue.append(child)
        }

        while !queue.isEmpty {
            let current = queue.removeFirst()

            current.forEachChild { byteVal, child in
                queue.append(child)

                var failure = current.failure
                while failure != nil && failure!.child(for: byteVal) == nil {
                    failure = failure!.failure
                }

                child.failure = failure?.child(for: byteVal) ?? root

                if child.failure === child {
                    child.failure = root
                }

                if let fail = child.failure, fail.patternIndex >= 0 {
                    child.outputLink = fail
                } else {
                    child.outputLink = child.failure?.outputLink
                }
            }
        }
    }

    public func containsAny(_ text: String) -> Bool {
        guard !patterns.isEmpty else {
            return false
        }

        var s = text
        return s.withUTF8 { buffer in
            var current = root
            var i = 0
            let len = buffer.count
            while i < len {
                let byte = buffer[i]
                i &+= 1
                while current !== root && current.child(for: byte) == nil {
                    current = current.failure ?? root
                }

                if let child = current.child(for: byte) {
                    current = child
                }

                if current.patternIndex >= 0 {
                    return true
                }

                var output = current.outputLink
                while output != nil {
                    if output!.patternIndex >= 0 {
                        return true
                    }
                    output = output!.outputLink
                }
            }

            return false
        }
    }

    public func containsAll(_ text: String) -> Bool {
        guard !patterns.isEmpty else {
            return true
        }

        let targetCount = patterns.count

        if targetCount <= 64 {
            let targetMask: UInt64 = targetCount == 64 ? ~UInt64(0) : (UInt64(1) << targetCount) - 1
            var found: UInt64 = 0
            var current = root

            var s = text
            s.withUTF8 { buffer in
                var i = 0
                let len = buffer.count
                while i < len {
                    guard found != targetMask else {
                        break
                    }
                    let byte = buffer[i]
                    i &+= 1

                    while current !== root && current.child(for: byte) == nil {
                        current = current.failure ?? root
                    }

                    if let child = current.child(for: byte) {
                        current = child
                    }

                    if current.patternIndex >= 0 {
                        found |= UInt64(1) << current.patternIndex
                    }

                    var output = current.outputLink
                    while output != nil {
                        if output!.patternIndex >= 0 {
                            found |= UInt64(1) << output!.patternIndex
                        }
                        output = output!.outputLink
                    }
                }
            }

            return found == targetMask
        }

        var foundPatterns = Set<Int>()
        var current = root

        var s = text
        s.withUTF8 { buffer in
            var i = 0
            let len = buffer.count
            while i < len {
                guard foundPatterns.count < targetCount else {
                    break
                }
                let byte = buffer[i]
                i &+= 1

                while current !== root && current.child(for: byte) == nil {
                    current = current.failure ?? root
                }

                if let child = current.child(for: byte) {
                    current = child
                }

                if current.patternIndex >= 0 {
                    foundPatterns.insert(current.patternIndex)
                }

                var output = current.outputLink
                while output != nil {
                    if output!.patternIndex >= 0 {
                        foundPatterns.insert(output!.patternIndex)
                    }
                    output = output!.outputLink
                }
            }
        }

        return foundPatterns.count == targetCount
    }

    public func containsNone(_ text: String) -> Bool {
        return !containsAny(text)
    }

    public func countMatches(_ text: String) -> Int {
        guard !patterns.isEmpty else {
            return 0
        }

        if patterns.count <= 64 {
            var found: UInt64 = 0
            var current = root

            var s = text
            s.withUTF8 { buffer in
                var i = 0
                let len = buffer.count
                while i < len {
                    let byte = buffer[i]
                    i &+= 1

                    while current !== root && current.child(for: byte) == nil {
                        current = current.failure ?? root
                    }

                    if let child = current.child(for: byte) {
                        current = child
                    }

                    if current.patternIndex >= 0 {
                        found |= UInt64(1) << current.patternIndex
                    }

                    var output = current.outputLink
                    while output != nil {
                        if output!.patternIndex >= 0 {
                            found |= UInt64(1) << output!.patternIndex
                        }
                        output = output!.outputLink
                    }
                }
            }

            return found.nonzeroBitCount
        }

        var foundPatterns = Set<Int>()
        var current = root

        var s = text
        s.withUTF8 { buffer in
            var i = 0
            let len = buffer.count
            while i < len {
                let byte = buffer[i]
                i &+= 1

                while current !== root && current.child(for: byte) == nil {
                    current = current.failure ?? root
                }

                if let child = current.child(for: byte) {
                    current = child
                }

                if current.patternIndex >= 0 {
                    foundPatterns.insert(current.patternIndex)
                }

                var output = current.outputLink
                while output != nil {
                    if output!.patternIndex >= 0 {
                        foundPatterns.insert(output!.patternIndex)
                    }
                    output = output!.outputLink
                }
            }
        }

        return foundPatterns.count
    }

    public func findAllPatternIndices(_ text: String) -> Set<Int> {
        guard !patterns.isEmpty else {
            return []
        }

        if patterns.count <= 64 {
            var found: UInt64 = 0
            var current = root

            var s = text
            s.withUTF8 { buffer in
                var i = 0
                let len = buffer.count
                while i < len {
                    let byte = buffer[i]
                    i &+= 1

                    while current !== root && current.child(for: byte) == nil {
                        current = current.failure ?? root
                    }

                    if let child = current.child(for: byte) {
                        current = child
                    }

                    if current.patternIndex >= 0 {
                        found |= UInt64(1) << current.patternIndex
                    }

                    var output = current.outputLink
                    while output != nil {
                        if output!.patternIndex >= 0 {
                            found |= UInt64(1) << output!.patternIndex
                        }
                        output = output!.outputLink
                    }
                }
            }

            var result = Set<Int>()
            var bits = found
            while bits != 0 {
                let index = bits.trailingZeroBitCount
                result.insert(index)
                bits &= bits - 1
            }
            return result
        }

        var foundPatterns = Set<Int>()
        var current = root

        var s = text
        s.withUTF8 { buffer in
            var i = 0
            let len = buffer.count
            while i < len {
                let byte = buffer[i]
                i &+= 1

                while current !== root && current.child(for: byte) == nil {
                    current = current.failure ?? root
                }

                if let child = current.child(for: byte) {
                    current = child
                }

                if current.patternIndex >= 0 {
                    foundPatterns.insert(current.patternIndex)
                }

                var output = current.outputLink
                while output != nil {
                    if output!.patternIndex >= 0 {
                        foundPatterns.insert(output!.patternIndex)
                    }
                    output = output!.outputLink
                }
            }
        }

        return foundPatterns
    }
}
