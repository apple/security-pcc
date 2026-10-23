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

import CryptoKit
import FilterCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A debug-only filter implementation that serves lookups as a deterministic
/// pure function of `(filterID, BinaryKey)` with a configured hit probability,
/// after a synthetic per-call delay drawn from a log-normal distribution.
///
/// No on-disk artifacts, no I/O, no fragment data — synthetic filters skip both
/// the downloader and `FakeFilterBuilder` entirely. Sharding behaviour matches
/// `FragmentedFilter.contains` bit-for-bit: a key whose fragment falls outside
/// this shard's range throws the same `FilterError.fragmentNotCovered`
/// (so the wire-level outcome is `failedToQuery`, identical to a real filter
/// receiving an off-shard query).
package struct SyntheticFilter: Sendable, SyncQueryableFilter {
    /// Resolved, post-defaulting parameters used to construct a `SyntheticFilter`.
    /// Callers feed user-overridable optionals through `resolve(...)`; the
    /// returned struct holds the final values used at lookup time.
    package struct ResolvedParams: Sendable, Hashable {
        package let hitProbability: Double
        package let logNormalMu: Double
        package let logNormalSigma: Double
        package let delayCapSeconds: Double

        package init(
            hitProbability: Double,
            logNormalMu: Double,
            logNormalSigma: Double,
            delayCapSeconds: Double
        ) {
            self.hitProbability = hitProbability
            self.logNormalMu = logNormalMu
            self.logNormalSigma = logNormalSigma
            self.delayCapSeconds = delayCapSeconds
        }

        /// Resolve user-supplied per-filter optionals against the FilterSource-derived
        /// defaults. `hitProbability` is clamped here (not in the inner loop) so a
        /// malformed config value can't smuggle a >1 or <0 through.
        package static func resolve(
            hitProbability: Double?,
            logNormalMu: Double?,
            logNormalSigma: Double?,
            delayCapMs: Double?,
            source: FilterSource
        ) -> ResolvedParams {
            let defaults = Self.defaults(for: source)
            let hit = (hitProbability ?? defaults.hitProbability)
                .clamped(to: 0.0 ... 1.0)
            return ResolvedParams(
                hitProbability: hit,
                logNormalMu: logNormalMu ?? defaults.logNormalMu,
                logNormalSigma: logNormalSigma ?? defaults.logNormalSigma,
                delayCapSeconds: (delayCapMs ?? defaults.delayCapMs) / 1000.0
            )
        }

        /// Defaults per FilterSource kind. Synthetic-only sources have meaningful
        /// defaults; non-synthetic sources fall back to syntheticRemote-shaped
        /// values (unreachable in practice — only synthetic sources construct this).
        private static func defaults(for source: FilterSource) -> (
            hitProbability: Double,
            logNormalMu: Double,
            logNormalSigma: Double,
            delayCapMs: Double
        ) {
            // log-normal anchored on p50=0.6 ms, p90=1.0 ms:
            //   μ = ln(0.0006) ≈ -7.4186 (seconds)
            //   σ = ln(p90/p50) / Φ⁻¹(0.9) = ln(5/3) / 1.2816 ≈ 0.3987
            // This yields p99 ≈ 1.5 ms — the user-stated p99=1.2 ms target
            // does not fit log-normal exactly; documented as approximation.
            let mu = Foundation.log(0.0006)
            let sigma = 0.3987
            let cap = 100.0 // ms — defensive clamp on a pathological tail draw
            switch source {
            case .syntheticRemote:
                return (hitProbability: 0.4, logNormalMu: mu, logNormalSigma: sigma, delayCapMs: cap)
            case .syntheticLocal:
                return (hitProbability: 1e-6, logNormalMu: mu, logNormalSigma: sigma, delayCapMs: cap)
            case .standard, .fakeRemote, .fakeLocal:
                return (hitProbability: 0.4, logNormalMu: mu, logNormalSigma: sigma, delayCapMs: cap)
            }
        }
    }

    package let filterID: FilterIDString
    package let totalFragments: Int
    /// Closed range of fragment indices owned by this shard. Computed once at
    /// init from the configured shardCount/shardIndex/totalFragments and used
    /// per-call to throw `fragmentNotCovered` for off-shard keys with the same
    /// payload `FragmentedFilter.contains` would produce.
    package let coveredFragments: ClosedRange<UInt>
    package let params: ResolvedParams
    /// SHA-256 of `filterID.utf8` precomputed once. Mixed into every per-key
    /// hit decision so the same `BinaryKey` resolves differently across filters
    /// that share a hit probability.
    private let filterIDDigest: SHA256Digest

    package init(
        filterID: FilterIDString,
        totalFragments: Int,
        shardConfig: FilterShardConfig,
        params: ResolvedParams
    ) throws {
        self.filterID = filterID
        self.totalFragments = totalFragments
        let range = try shardConfig.fragmentRange(totalFragments: totalFragments)
        // Range is half-open; convert to inclusive closed range to match
        // FragmentedFilter's coveredRange contract.
        self.coveredFragments = UInt(range.lowerBound) ... UInt(range.upperBound - 1)
        self.params = params
        self.filterIDDigest = SHA256.hash(data: Data(filterID.utf8))
    }

    /// Check whether a key may be present in the filter, after a synthetic per-call delay.
    ///
    /// **Synchronous and blocking**: the delay is a real thread sleep, not an `await`.
    /// This mirrors `FragmentedFilter.contains` (a blocking `pread`) so a synthetic filter
    /// can be dispatched to the shared `WorkPool` exactly like a pread-backed filter.
    /// Callers must run it on a dedicated work-pool thread, never on the cooperative pool.
    package func contains(_ key: BinaryKey) throws -> Bool {
        let fragment = key.fragmentIndex(totalFragments: self.totalFragments)
        guard self.coveredFragments.contains(fragment) else {
            throw FilterError.fragmentNotCovered(
                fragment: fragment,
                coveredRange: self.coveredFragments
            )
        }

        let delaySeconds = self.sampleDelaySeconds()
        if delaySeconds > 0 {
            Self.blockingSleep(seconds: delaySeconds)
        }

        return self.uniformFraction(forKey: key) < self.params.hitProbability
    }

    /// Blocking, nanosecond-resolution sleep for the synthetic per-call delay.
    ///
    /// Uses `nanosleep` rather than `Thread.sleep(forTimeInterval:)`: the latter
    /// rounds sub-millisecond intervals up to a coarse scheduler granularity, which
    /// would distort the sampled log-normal distribution (p50 ≈ 0.6 ms). `nanosleep`
    /// honours the requested duration without timer coalescing. Retries on `EINTR`
    /// with the reported remaining time so the total delay is preserved.
    private static func blockingSleep(seconds: Double) {
        let whole = seconds.rounded(.towardZero)
        var request = timespec(
            tv_sec: Int(whole),
            tv_nsec: Int((seconds - whole) * 1_000_000_000)
        )
        var remaining = timespec()
        while nanosleep(&request, &remaining) != 0 {
            if errno != EINTR { break }
            request = remaining
        }
    }

    /// Draw a single sample from the log-normal `(μ, σ)` distribution and
    /// clamp to `[0, delayCapSeconds]`. Box–Muller using Foundation's thread-safe
    /// `Double.random(in:)` (backed by `SystemRandomNumberGenerator`).
    private func sampleDelaySeconds() -> Double {
        // u1 must be strictly > 0 to keep `log(u1)` finite. Using
        // `leastNormalMagnitude` as the lower bound avoids the rare-but-real
        // possibility of drawing exactly 0.
        let u1 = Double.random(in: .leastNormalMagnitude ... 1.0)
        let u2 = Double.random(in: 0.0 ..< 1.0)
        let z = (-2.0 * Foundation.log(u1)).squareRoot() * Foundation.cos(2.0 * .pi * u2)
        let raw = Foundation.exp(self.params.logNormalMu + self.params.logNormalSigma * z)
        return min(max(raw, 0.0), self.params.delayCapSeconds)
    }

    /// SHA-256 over `(filterIDDigest || keyBytes)`, then take the first 8 bytes
    /// (big-endian) as a UInt64 and map to a uniform `[0, 1)` via
    /// `uniformDouble(fromHash:)`. Deterministic across processes — same
    /// `(filterID, key)` always yields the same value.
    package func uniformFraction(forKey key: BinaryKey) -> Double {
        var hasher = SHA256()
        self.filterIDDigest.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        key.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize()
        let value: UInt64 = digest.withUnsafeBytes { buf in
            UInt64(bigEndian: buf.loadUnaligned(as: UInt64.self))
        }
        return Self.uniformDouble(fromHash: value)
    }

    /// Convert a `UInt64` to a uniform `Double` in the half-open range `[0, 1)`.
    ///
    /// Uses the top 53 bits — Double has 53 bits of mantissa precision, so any
    /// integer that fits converts exactly. Dividing by `2^53` (representable
    /// exactly as `0x1.0p53`) yields a result strictly less than 1.0 for every
    /// `UInt64` value, including `UInt64.max`. The naive `Double(value) / Double(UInt64.max)`
    /// breaks the half-open contract because `Double(UInt64.max)` rounds up to
    /// `2^64`, producing exactly `1.0`.
    package static func uniformDouble(fromHash value: UInt64) -> Double {
        let bits53 = value >> 11
        return Double(bits53) / 0x1.0p53
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
