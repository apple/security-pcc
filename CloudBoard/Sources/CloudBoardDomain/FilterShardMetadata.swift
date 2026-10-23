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

/// Parsed representation of filter shard metadata published by PrivateFilterController
/// via ServiceDiscovery. The JSON format is versioned; unknown fields are silently
/// ignored by `JSONDecoder` for forward compatibility.
///
/// - Note: This type logically belongs in `PrivateFilterClientRouter`, but that target
///   is a tool (`com.apple.product-type.tool`) and Xcode cannot link test bundles against
///   tool modules. It lives here in `CloudBoardDomain` until that limitation is resolved.
package struct FilterShardMetadata: Codable, Sendable, Equatable {
    /// Schema version of the metadata envelope (currently `1`).
    package var version: Int
    /// Per-filter shard descriptors published by this node.
    package var shards: [ShardInfo]
    /// Filters that failed to build or load, if any. Present only when the
    /// producer is running with `ContinueOnFilterFailure` enabled.
    package var failedShards: [FailedShardInfo]?

    package struct FailedShardInfo: Codable, Sendable, Equatable {
        /// ID of the filter that failed
        package var filterID: String
        /// which phase of the fake filter creation failed
        package var phase: String
        /// Safe to log text describing the error
        package var error: String
    }

    package struct ShardInfo: Codable, Sendable, Equatable {
        /// Human-readable filter identifier (e.g. `"com.apple.fm.language.instruct_server_v2.base_pro.bf2"`).
        package var filterID: String
        /// Zero-padded 16-character lowercase hex string of the SHA-256–derived filter ID hash.
        package var filterIDHash: String
        /// Human-readable hashing-scheme identifier shared across shards using the same hash.
        /// Empty string when `isFaked` is true.
        package var hashingID: String
        /// Zero-padded 16-character lowercase hex string of the SHA-256–derived hashing ID hash.
        package var hashingIDHash: String
        /// 0-based index of this shard within the filter's shard set.
        package var shardIndex: Int
        /// Total number of shards the filter is split into.
        package var numShards: Int
        /// Total number of fragments the filter is divided into (the modulus for routing).
        package var modulus: Int
        /// 2-element array `[min, max]` (inclusive) of modulo index values hosted by this shard.
        package var moduloRange: [UInt]
        /// Monotonically increasing revision counter; bumped when shard content changes.
        package var revision: Int
        /// When true, the filter data is synthetic (fakeLocal, fakeRemote).
        /// hashingID/hashingIDHash are placeholders and must
        /// not be validated against this shard.
        package var isFaked: Bool

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.filterID = try container.decode(String.self, forKey: .filterID)
            self.filterIDHash = try container.decode(String.self, forKey: .filterIDHash)
            self.hashingID = try container.decode(String.self, forKey: .hashingID)
            self.hashingIDHash = try container.decode(String.self, forKey: .hashingIDHash)
            self.shardIndex = try container.decode(Int.self, forKey: .shardIndex)
            self.numShards = try container.decode(Int.self, forKey: .numShards)
            self.modulus = try container.decode(Int.self, forKey: .modulus)
            self.moduloRange = try container.decode([UInt].self, forKey: .moduloRange)
            self.revision = try container.decode(Int.self, forKey: .revision)
            self.isFaked = try container.decodeIfPresent(Bool.self, forKey: .isFaked) ?? false

            guard self.modulus > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modulus,
                    in: container,
                    debugDescription: "modulus must be positive, got \(self.modulus)"
                )
            }
            guard self.numShards > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .numShards,
                    in: container,
                    debugDescription: "numShards must be positive, got \(self.numShards)"
                )
            }
            guard self.modulus % self.numShards == 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modulus,
                    in: container,
                    debugDescription: "modulus (\(self.modulus)) must be a multiple of numShards (\(self.numShards))"
                )
            }
            guard self.shardIndex >= 0, self.shardIndex < self.numShards else {
                throw DecodingError.dataCorruptedError(
                    forKey: .shardIndex,
                    in: container,
                    debugDescription: "shardIndex (\(self.shardIndex)) must be in 0..<numShards (\(self.numShards))"
                )
            }
            guard self.moduloRange.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .moduloRange,
                    in: container,
                    debugDescription: "moduloRange must have exactly 2 elements, got \(self.moduloRange.count)"
                )
            }
            guard self.moduloRange[0] <= self.moduloRange[1] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .moduloRange,
                    in: container,
                    debugDescription: "moduloRange[0] (\(self.moduloRange[0])) must be <= moduloRange[1] (\(self.moduloRange[1]))"
                )
            }
            guard self.moduloRange[1] < UInt(self.modulus) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .moduloRange,
                    in: container,
                    debugDescription: "moduloRange[1] (\(self.moduloRange[1])) must be < modulus (\(self.modulus))"
                )
            }
        }
    }

    package static func parse(json: String) throws -> FilterShardMetadata {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(FilterShardMetadata.self, from: data)
    }
}

extension FilterShardMetadata.ShardInfo {
    /// Re-validates the structural invariants that `init(from:)` enforces, returning a
    /// human-readable description for the first violated invariant or `nil` if the
    /// shard is well-formed. Callers that consume `ShardInfo` outside the JSON decode
    /// path (e.g. a bridge command that already received a parsed value) can use this
    /// as a defence-in-depth check before the value reaches code that `precondition`s
    /// on the same invariants.
    package var validationFailureDescription: String? {
        if self.modulus <= 0 {
            return "modulus must be positive, got \(self.modulus)"
        }
        if self.numShards <= 0 {
            return "numShards must be positive, got \(self.numShards)"
        }
        if self.modulus % self.numShards != 0 {
            return "modulus (\(self.modulus)) must be a multiple of numShards (\(self.numShards))"
        }
        if self.shardIndex < 0 || self.shardIndex >= self.numShards {
            return "shardIndex (\(self.shardIndex)) must be in 0..<numShards (\(self.numShards))"
        }
        if self.moduloRange.count != 2 {
            return "moduloRange must have exactly 2 elements, got \(self.moduloRange.count)"
        }
        if self.moduloRange[0] > self.moduloRange[1] {
            return "moduloRange[0] (\(self.moduloRange[0])) must be <= moduloRange[1] (\(self.moduloRange[1]))"
        }
        if self.moduloRange[1] >= UInt(self.modulus) {
            return "moduloRange[1] (\(self.moduloRange[1])) must be < modulus (\(self.modulus))"
        }
        return nil
    }
}
