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

import os
import Synchronization

// MARK: - Supporting types

/// Cache-line-padded atomic counter. Each instance is heap-allocated
/// to ensure the Atomic sits on its own 128-byte cache line (Apple Silicon).
public final class PaddedAtomicCounter: Sendable {
    public let value: Atomic<Int> = .init(0)
    // Pad to 128 bytes. Class header ~16 bytes + Atomic<Int> 8 bytes + 13×8 = 104 bytes = 128.
    private let _p0: UInt64 = 0
    private let _p1: UInt64 = 0
    private let _p2: UInt64 = 0
    private let _p3: UInt64 = 0
    private let _p4: UInt64 = 0
    private let _p5: UInt64 = 0
    private let _p6: UInt64 = 0
    private let _p7: UInt64 = 0
    private let _p8: UInt64 = 0
    private let _p9: UInt64 = 0
    private let _pA: UInt64 = 0
    private let _pB: UInt64 = 0
    private let _pC: UInt64 = 0
}

/// Per-filter counter set. Each counter on its own cache line.
public struct FilterCounters: Sendable {
    public let hit = PaddedAtomicCounter()
    public let miss = PaddedAtomicCounter()
    public let error = PaddedAtomicCounter()

    public init() {}
}

/// Fixed-capacity reservoir buffer using Algorithm R for uniform random sampling.
public struct ReservoirBuffer: Sendable {
    public static let capacity = 512

    public var samples: [Double]
    public var count: Int = 0

    public static func empty() -> Self {
        var buf = Self(samples: [], count: 0)
        buf.samples.reserveCapacity(Self.capacity)
        return buf
    }
}

// MARK: - Flush data

/// Data produced by a single flush cycle, per filter.
public struct FilterFlushData: Sendable {
    public let filterName: String
    public let hitCount: Int
    public let missCount: Int
    public let errorCount: Int
    public let histogramValues: [Double]
}

// MARK: - Aggregator

/// The outcome of a single filter lookup, used for metric recording.
public enum FilterLookupOutcome: Sendable {
    case hit
    case miss
    case error

    /// String representation used as a metric dimension value at emission time.
    public var metricValue: String {
        switch self {
        case .hit: "hit"
        case .miss: "miss"
        case .error: "error"
        }
    }
}

/// Aggregates per-filter lookup metrics on the hot path and flushes them
/// periodically. Uses lock-free atomics for counters and a single Mutex
/// for reservoir-sampled duration values (swap-and-drain pattern) to
/// minimise hot-path overhead.
///
/// The record path accepts UInt64 filter hashes directly (as they arrive in
/// queries) — no String operations on the hot path. String filter names are
/// resolved only at flush time.
///
/// The aggregator is decoupled from specific metric types — it calls an
/// `onFlush` handler with the accumulated data, letting the caller decide
/// how to emit metrics.
public final class LookupMetricsAggregator: Sendable {
    private static let log = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LookupMetricsAggregator"
    )
    /// Maps the truncated SHA256 filter hash (from queries) to a dense array index.
    private let filterHashToIndex: [UInt64: Int]
    /// Human-readable filter names, indexed to match filterHashToIndex values.
    public let filterNames: [String]
    /// Per-filter atomic counters, indexed. Each counter on its own cache line.
    private let counters: [FilterCounters]
    /// Per-filter reservoir buffers protected by a single Mutex. The flush loop
    /// swaps in empty spare buffers under the lock (brief critical section), then
    /// drains the accumulated data outside the lock with no contention.
    private let histograms: Mutex<[ReservoirBuffer]>
    /// Called on each flush with the accumulated data for all filters that had activity.
    private let onFlush: @Sendable ([FilterFlushData]) -> Void

    public init(
        filterIDs: [(hash: UInt64, name: String)],
        onFlush: @escaping @Sendable ([FilterFlushData]) -> Void
    ) {
        var hashToIndex: [UInt64: Int] = [:]
        var names: [String] = []
        var counterArray: [FilterCounters] = []
        var emptyHistograms: [ReservoirBuffer] = []

        for (i, entry) in filterIDs.enumerated() {
            hashToIndex[entry.hash] = i
            names.append(entry.name)
            counterArray.append(FilterCounters())
            emptyHistograms.append(.empty())
        }

        self.filterHashToIndex = hashToIndex
        self.filterNames = names
        self.counters = counterArray
        self.histograms = Mutex(emptyHistograms)
        self.onFlush = onFlush
    }

    /// Resolves a UInt64 filter hash to its human-readable name, if known.
    public func filterName(forHash hash: UInt64) -> String? {
        guard let idx = self.filterHashToIndex[hash] else { return nil }
        return self.filterNames[idx]
    }

    /// Called on the hot path. Accepts the UInt64 filter hash directly from
    /// the query — no String operations. Lock-free atomic add for counters;
    /// brief Mutex acquisition for reservoir sampling.
    public func record(filterHash: UInt64, result: FilterLookupOutcome, durationSeconds: Double) {
        guard let filterIdx = self.filterHashToIndex[filterHash] else { return }

        // Counter: lock-free atomic increment
        let fc = self.counters[filterIdx]
        switch result {
        case .hit: fc.hit.value.wrappingAdd(1, ordering: .relaxed)
        case .miss: fc.miss.value.wrappingAdd(1, ordering: .relaxed)
        case .error: fc.error.value.wrappingAdd(1, ordering: .relaxed)
        }

        // Reservoir sampling (Algorithm R): uniform random sample bounded to capacity.
        self.histograms.withLock { buffers in
            buffers[filterIdx].count += 1
            let n = buffers[filterIdx].count
            if n <= ReservoirBuffer.capacity {
                buffers[filterIdx].samples.append(durationSeconds)
            } else {
                let j = Int.random(in: 0 ..< n)
                if j < ReservoirBuffer.capacity {
                    buffers[filterIdx].samples[j] = durationSeconds
                }
            }
        }
    }

    /// Performs a single flush cycle: drains counters and histograms, calls onFlush.
    /// Exposed for testing; normally called by `runFlushLoop`.
    public func flush(spare: inout [ReservoirBuffer]) {
        var results: [FilterFlushData] = []

        // Swap histogram buffers under the lock.
        var snapshot = self.histograms.withLock { buffers -> [ReservoirBuffer] in
            let accumulated = buffers
            buffers = spare
            return accumulated
        }

        for i in 0 ..< self.filterNames.count {
            let fc = self.counters[i]
            let h = fc.hit.value.exchange(0, ordering: .relaxed)
            let m = fc.miss.value.exchange(0, ordering: .relaxed)
            let e = fc.error.value.exchange(0, ordering: .relaxed)

            if h > 0 || m > 0 || e > 0 || !snapshot[i].samples.isEmpty {
                results.append(FilterFlushData(
                    filterName: self.filterNames[i],
                    hitCount: h,
                    missCount: m,
                    errorCount: e,
                    histogramValues: snapshot[i].samples
                ))
                // The COW buffer is now shared with FilterFlushData — can't reuse it.
                // Allocate a fresh reservoir for the spare.
                snapshot[i] = .empty()
            } else {
                snapshot[i].count = 0
            }
        }

        spare = snapshot

        if !results.isEmpty {
            self.onFlush(results)
        }
    }

    /// Runs in a background task. Flushes aggregated metrics on a precise interval.
    public func runFlushLoop<C: Clock>(clock: C) async where C.Duration == Duration {
        var nextFlush = clock.now.advanced(by: .seconds(1))
        var spare: [ReservoirBuffer] = self.filterNames.map { _ in .empty() }

        while !Task.isCancelled {
            try? await clock.sleep(until: nextFlush, tolerance: .zero)
            self.flush(spare: &spare)
            let now = clock.now
            nextFlush = nextFlush.advanced(by: .seconds(1))
            if nextFlush <= now {
                let overtime = nextFlush.duration(to: now)
                let skipped = Int(overtime.components.seconds) + 1
                nextFlush = nextFlush.advanced(by: .seconds(skipped))
                Self.log.warning("Metrics flush overrun — skipping \(skipped) tick(s)")
            }
        }
    }
}
