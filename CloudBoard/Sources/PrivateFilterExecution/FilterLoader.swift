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

import BloomFilter
import FilterCore
import Foundation
import PrivateFilterCommon
import RibbonFilter

/// The shared "which filter family?" switch for the Controller and the
/// ClientRouter. Both services read a `filter.json` that may describe either a
/// **bloom** or a **ribbon** filter; `FilterLoader` peeks the `filter_type`
/// (via `FilterCore.FilterKind`) and constructs the matching reader, returning a
/// single uniform lookup closure that callers already consume.
///
/// This lives in `PrivateFilterExecution` — the one place that links both
/// `BloomFilter` and `RibbonFilter` — so the downloader never pulls in either
/// filter family (it depends only on `PrivateFilterCommon` → `FilterCore`).
public enum FilterLoader: Sendable {
    /// A queryable filter, loaded and ready to answer lookups, plus the metadata
    /// the caller records for status/metrics.
    public struct LoadedFilter: Sendable {
        public let kind: FilterKind
        public let totalFragments: Int
        /// Inclusive range of fragment (prefix) indices this instance covers.
        public let coveredRange: ClosedRange<UInt>
        /// Total on-disk bytes of the covered fragments (bloom: from the
        /// descriptor's `bloom_length`; ribbon: summed from `stat`).
        public let totalFragmentBytes: UInt64
        public let lookup: @Sendable (BinaryKey) async throws -> Bool
    }

    /// Lightweight `filter.json` metadata read without constructing the filter —
    /// enough for a caller to compute a shard's covered range and record shard
    /// info before the (heavier) load.
    public struct FilterMetadata: Sendable {
        public let kind: FilterKind
        public let totalFragments: Int
        public let fragments: [FragmentEntry]

        public struct FragmentEntry: Sendable {
            public let prefixValue: UInt
            public let file: String
        }
    }

    public enum LoadError: Error, CustomStringConvertible, Sendable {
        /// `filter.json` declares a `filter_type` this build does not support
        /// (`.unknown`), or a legacy file with no discriminating fields.
        case unsupportedFilterKind(FilterKind)
        /// The covered fragments exceed the in-memory threshold. Both families
        /// fall back to pread when a `WorkPool` is provided; a nil pool means the
        /// caller only supports in-memory loading (e.g. the router).
        case exceedsInMemoryThreshold(kind: FilterKind, bytes: UInt64, threshold: UInt64)
        /// The selected scope covers no fragments.
        case emptyFragmentList

        public var description: String {
            switch self {
            case .unsupportedFilterKind(let kind):
                return "unsupported filter_type '\(kind.rawValue)'"
            case .exceedsInMemoryThreshold(let kind, let bytes, let threshold):
                return "\(kind.rawValue) filter is \(bytes) bytes, over the in-memory threshold "
                    + "of \(threshold) bytes, and cannot be loaded"
            case .emptyFragmentList:
                return "selected scope covers no fragments"
            }
        }
    }

    /// Peek the filter family and fragment layout from `filter.json` without
    /// constructing the filter. Throws `LoadError.unsupportedFilterKind` for an
    /// unknown `filter_type`.
    public static func peekMetadata(descriptorPath: String) throws -> FilterMetadata {
        let kind = try FilterKind.peek(jsonPath: descriptorPath)
        switch kind {
        case .bloom:
            let descriptor = try FilterDescriptor.read(from: descriptorPath)
            return FilterMetadata(
                kind: .bloom,
                totalFragments: descriptor.totalFragments,
                fragments: descriptor.fragments.map {
                    .init(prefixValue: $0.prefixValue, file: $0.file)
                }
            )
        case .ribbon:
            let descriptor = try RibbonDescriptor.read(from: descriptorPath)
            return FilterMetadata(
                kind: .ribbon,
                totalFragments: descriptor.totalFragments,
                fragments: descriptor.fragments.map {
                    .init(prefixValue: $0.prefixValue, file: $0.file)
                }
            )
        case .unknown:
            throw LoadError.unsupportedFilterKind(kind)
        }
    }

    /// The inclusive fragment range covered by a shard selection. `shardCount <= 1`
    /// means the whole filter. Mirrors the load path so a caller can record a
    /// shard's covered range before loading.
    public static func fragmentRange(
        totalFragments: Int,
        shardIndex: Int,
        shardCount: Int
    ) throws -> ClosedRange<UInt> {
        let scope = Self.scope(shardIndex: shardIndex, shardCount: shardCount)
        try scope.validate(totalFragments: totalFragments)
        return scope.fragmentRange(totalFragments: totalFragments)
    }

    /// Construct a queryable filter, dispatching on the `filter_type` in
    /// `filter.json`.
    ///
    /// Both families load the same way: `InMemory*` under `inMemoryThresholdBytes`,
    /// otherwise the `Pread*` reader wrapped in an `AsyncWorkPoolFilter` dispatched
    /// to `pool` (or `LoadError.exceedsInMemoryThreshold` if `pool` is nil). Both
    /// honour the shard selection.
    ///
    /// - unknown: `LoadError.unsupportedFilterKind`.
    ///
    /// - Parameter pool: POSIX work pool for blocking pread lookups. Callers that
    ///   only support in-memory loading (e.g. the router) pass nil, which turns an
    ///   over-threshold filter into `LoadError.exceedsInMemoryThreshold`.
    public static func loadLookup(
        descriptorPath: String,
        fragmentsDirectory: String,
        shardIndex: Int,
        shardCount: Int,
        inMemoryThresholdBytes: UInt64,
        pool: WorkPool? = nil
    ) throws -> LoadedFilter {
        let kind = try FilterKind.peek(jsonPath: descriptorPath)
        switch kind {
        case .bloom:
            return try Self.loadBloom(
                descriptorPath: descriptorPath,
                fragmentsDirectory: fragmentsDirectory,
                shardIndex: shardIndex,
                shardCount: shardCount,
                inMemoryThresholdBytes: inMemoryThresholdBytes,
                pool: pool
            )
        case .ribbon:
            return try Self.loadRibbon(
                descriptorPath: descriptorPath,
                fragmentsDirectory: fragmentsDirectory,
                shardIndex: shardIndex,
                shardCount: shardCount,
                inMemoryThresholdBytes: inMemoryThresholdBytes,
                pool: pool
            )
        case .unknown:
            throw LoadError.unsupportedFilterKind(kind)
        }
    }

    // MARK: - Private

    private static func scope(shardIndex: Int, shardCount: Int) -> FilterScope {
        shardCount > 1 ? .shard(index: shardIndex, count: shardCount) : .wholeFilter
    }

    /// Shared load skeleton for both families: resolve the shard scope, size the
    /// covered fragments, then choose in-memory vs pread-on-`pool` against the
    /// threshold. The family-specific pieces — counting/sizing the covered
    /// fragments and building each reader — arrive as closures.
    private static func makeLoadedFilter(
        kind: FilterKind,
        totalFragments: Int,
        shardIndex: Int,
        shardCount: Int,
        inMemoryThresholdBytes: UInt64,
        pool: WorkPool?,
        coverage: (ClosedRange<UInt>) -> (count: Int, bytes: UInt64),
        inMemoryLookup: (FilterScope) throws -> @Sendable (BinaryKey) async throws -> Bool,
        preadLookup: (FilterScope, WorkPool) throws -> @Sendable (BinaryKey) async throws -> Bool
    ) throws -> LoadedFilter {
        let scope = Self.scope(shardIndex: shardIndex, shardCount: shardCount)
        try scope.validate(totalFragments: totalFragments)
        let range = scope.fragmentRange(totalFragments: totalFragments)

        let (coveredCount, totalBytes) = coverage(range)
        guard coveredCount > 0 else {
            throw LoadError.emptyFragmentList
        }

        let lookup: @Sendable (BinaryKey) async throws -> Bool
        if totalBytes < inMemoryThresholdBytes {
            // In-memory lookups are pure array indexing — no syscalls, so they run
            // directly on the Swift cooperative thread pool.
            lookup = try inMemoryLookup(scope)
        } else {
            // Pread-backed lookups issue blocking pread() syscalls, so they must
            // run on a dedicated POSIX WorkPool. Callers without a pool only
            // support in-memory loading.
            guard let pool else {
                throw LoadError.exceedsInMemoryThreshold(
                    kind: kind, bytes: totalBytes, threshold: inMemoryThresholdBytes
                )
            }
            lookup = try preadLookup(scope, pool)
        }

        return LoadedFilter(
            kind: kind,
            totalFragments: totalFragments,
            coveredRange: range,
            totalFragmentBytes: totalBytes,
            lookup: lookup
        )
    }

    private static func loadBloom(
        descriptorPath: String,
        fragmentsDirectory: String,
        shardIndex: Int,
        shardCount: Int,
        inMemoryThresholdBytes: UInt64,
        pool: WorkPool?
    ) throws -> LoadedFilter {
        let descriptor = try FilterDescriptor.read(from: descriptorPath)
        return try Self.makeLoadedFilter(
            kind: .bloom,
            totalFragments: descriptor.totalFragments,
            shardIndex: shardIndex,
            shardCount: shardCount,
            inMemoryThresholdBytes: inMemoryThresholdBytes,
            pool: pool,
            coverage: { range in
                let covered = descriptor.fragments.filter { range.contains($0.prefixValue) }
                return (covered.count, covered.reduce(UInt64(0)) { $0 + $1.bloomLength })
            },
            inMemoryLookup: { scope in
                let filter = try FragmentedFilter<InMemoryBloomFilter>(
                    descriptorPath: descriptorPath, fragmentsDirectory: fragmentsDirectory, scope: scope
                )
                return { key in try filter.contains(key) }
            },
            preadLookup: { scope, pool in
                let filter = try FragmentedFilter<PreadBloomFilter>(
                    descriptorPath: descriptorPath, fragmentsDirectory: fragmentsDirectory, scope: scope
                )
                let asyncFilter = AsyncWorkPoolFilter(filter: filter, pool: pool)
                return { key in try await asyncFilter.contains(key) }
            }
        )
    }

    private static func loadRibbon(
        descriptorPath: String,
        fragmentsDirectory: String,
        shardIndex: Int,
        shardCount: Int,
        inMemoryThresholdBytes: UInt64,
        pool: WorkPool?
    ) throws -> LoadedFilter {
        let descriptor = try RibbonDescriptor.read(from: descriptorPath)
        return try Self.makeLoadedFilter(
            kind: .ribbon,
            totalFragments: descriptor.totalFragments,
            shardIndex: shardIndex,
            shardCount: shardCount,
            inMemoryThresholdBytes: inMemoryThresholdBytes,
            pool: pool,
            coverage: { range in
                // Ribbon carries an explicit per-fragment `file_size` (mandatory),
                // so the threshold decision needs no per-fragment `stat`.
                let covered = descriptor.fragments.filter { range.contains($0.prefixValue) }
                return (covered.count, covered.reduce(UInt64(0)) { $0 + $1.fileSize })
            },
            inMemoryLookup: { scope in
                let filter = try RibbonFragmentedFilter<InMemoryRibbonFilter>(
                    descriptorPath: descriptorPath, fragmentsDirectory: fragmentsDirectory, scope: scope
                )
                return { key in try filter.contains(key) }
            },
            preadLookup: { scope, pool in
                let filter = try RibbonFragmentedFilter<PreadRibbonFilter>(
                    descriptorPath: descriptorPath, fragmentsDirectory: fragmentsDirectory, scope: scope
                )
                let asyncFilter = AsyncWorkPoolFilter(filter: filter, pool: pool)
                return { key in try await asyncFilter.contains(key) }
            }
        )
    }
}
