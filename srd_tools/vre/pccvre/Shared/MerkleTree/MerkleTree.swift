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

import CryptoKit
import Foundation
import SwiftData
import System

struct MerkleTree<Hash: HashFunction>: Sendable {
    var leaves: [Data] = []
    var digestCache: [Range<Int>: Data] = [:]

    var count: Int { self.leaves.count }
    var rootDigest: Data {
        mutating get {
            self.calculateDigest()
        }
    }

    subscript(_ index: Int) -> Data { self.leaves[index] }

    init(using: Hash.Type = SHA256.self) {}

    init(_ elements: some Sequence<some DataProtocol>, using: Hash.Type = SHA256.self) {
        self = .init(using: using)
        for element in elements {
            self.append(Data(element))
        }
    }

    init(_ elements: some Sequence<Data>, using: Hash.Type = SHA256.self) {
        self.append(contentsOf: elements)
    }

    mutating func digest(range: Range<Int>) -> Data {
        self.calculateDigest(range: range)
    }

    mutating func digest(range: PartialRangeUpTo<Int>) -> Data {
        self.calculateDigest(range: 0..<range.upperBound)
    }

    private mutating func calculateDigest() -> Data {
        self.calculateDigest(range: self.leaves.startIndex..<self.leaves.endIndex)
    }

    private mutating func calculateDigest(range: Range<Int>) -> Data {
        if let digest = self.cachedDigest(for: range) {
            return digest
        }

        let n = range.count
        if n == 0 {
            return Data(Hash.hash(data: Data()))
        }

        if let first = range.first, range.count == 1 {
            return Data(Hash.leaf(data: self.leaves[first]))
        }

        let k = Self.k(n: n)

        let left = Data(calculateDigest(range: range[..<(range.startIndex+k)]))
        let right = Data(calculateDigest(range: range[(range.startIndex+k)...]))
        let digest = Data(Hash.interior(left: left, right: right))
        if range.count > 1, range.count.isPowerOf2 {
            self.cache(digest: digest, for: range)
        }

        return digest
    }

    mutating func verifyInclusion(of data: Data, with proof: InclusionProof) -> Bool {
        let (r, sn) = Self.rebuildRootDigest(leaf: Hash.leaf(data: data),
                                             lastIndex: self.count - 1,
                                             proof: proof)
        return r == self.rootDigest && sn == 0
    }

    mutating func append(_ data: Data) {
        self.leaves.append(data)
    }

    mutating func append(contentsOf: some Sequence<Data>) {
        self.leaves.append(contentsOf: contentsOf)
    }

    private mutating func cache(digest: Data, for range: Range<Int>) {
        self.digestCache[range] = digest
    }

    private func cachedDigest(for range: Range<Int>) -> Data? {
        self.digestCache[range]
    }

    private static func rebuildRootDigest(leaf: Hash.Digest,
                                          lastIndex: Int,
                                          proof: InclusionProof)
        -> (Hash.Digest, Int)
    {
        var fn = proof.index
        var sn = lastIndex
        var r = leaf

        for p in proof.path {
            if fn.isOdd || fn == sn {
                r = Hash.interior(left: Data(p), right: Data(r))
                if fn.isEven {
                    repeat {
                        fn >>= 1
                        sn >>= 1
                    } while fn.isEven || fn == 0
                }
            } else {
                r = Hash.interior(left: Data(r), right: Data(p))
            }

            fn >>= 1
            sn >>= 1
        }

        return (r, sn)
    }

    // Calculates the largest power of 2 less than `n` for `n > 1`
    private static func k(n: Int) -> Int {
        precondition(n > 1)
        // calculate largest power of 2 less than n
        let k = 1 << (n.bitWidth - n.leadingZeroBitCount - 1)
        return k == n ? k >> 1 : k
    }
}

// MARK: - Codable

extension MerkleTree: Codable {}

// MARK: - InclusionProof

extension MerkleTree {
    struct InclusionProof: Hashable {
        let index: Int
        let path: [Data]
    }

    mutating func proveInclusion(of data: Data) -> InclusionProof? {
        guard !self.leaves.isEmpty else {
            return nil
        }

        if self.leaves.count == 1, let first = leaves.first, first == data {
            return InclusionProof(index: 0, path: [])
        }

        guard let m = leaves.firstIndex(of: data) else {
            return nil
        }

        return self.proveInclusion(index: m, range: self.leaves.startIndex..<self.leaves.endIndex)
    }

    private mutating func proveInclusion(index m: Int, range: Range<Int>) -> InclusionProof {
        let n = range.count
        if n == 1 {
            return InclusionProof(index: m, path: [])
        }

        let k = Self.k(n: n)
        if m < k {
            let recursiveProof = self.proveInclusion(index: m,
                                                     range: range[range.startIndex..<range.startIndex+k])
            return InclusionProof(index: m,
                                  path: recursiveProof.path +
                                      [Data(self.calculateDigest(range: range[(range.startIndex+k)...]))])
        } else {
            precondition(m >= k)
            let recursiveProof = self.proveInclusion(index: m - k, range: range[(range.startIndex+k)...])
            return InclusionProof(index: m,
                                  path: recursiveProof.path +
                                      [Data(self.calculateDigest(range: range[..<(range.startIndex+k)]))])
        }
    }
}

// MARK: - HashFunction Extensions

extension HashFunction {
    static func leaf(data: some DataProtocol) -> Self.Digest {
        var hash = Self()
        hash.update(data: [0x00])
        hash.update(data: data)
        return hash.finalize()
    }

    static func interior(left: some DataProtocol, right: some DataProtocol) -> Self.Digest {
        var hash = Self()
        hash.update(data: [0x01])
        hash.update(data: left)
        hash.update(data: right)
        return hash.finalize()
    }
}

private extension Int {
    var isOdd: Bool {
        self & 1 == 1
    }

    var isEven: Bool {
        self & 1 == 0
    }

    var isPowerOf2: Bool {
        self.nonzeroBitCount == 1
    }
}
