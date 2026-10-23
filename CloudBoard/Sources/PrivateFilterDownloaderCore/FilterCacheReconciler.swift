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
import os
import PrivateFilterCommon

/// Reconciles the on-disk download cache under `remoteRootPath` against the
/// node's configuration.
///
/// On an Ephemeral Data Mode root the tree is wiped on every boot, so this is a
/// cheap no-op. On a persistent cache volume the downloaded fragments survive
/// reboot, so we must:
///   - **re-verify** every planned fragment's SHA256, removing any that fail so
///     they are re-downloaded (always on — this is corruption repair, not pruning), and
///   - **prune** (when `pruningEnabled`) anything present that isn't wanted:
///       - whole directories for filters not configured as `.standard` on this node
///         (config is the canonical source — a filter dropped from `filterIDs`, or
///         switched to a non-downloading source, has its cached data reclaimed), and
///       - files inside a configured filter that don't belong to this node's shard
///         (or are orphaned download sidecars).
///
/// Because the keep-set is config-driven, pruning is unambiguous and does not
/// depend on the cryptex being mounted: a filter the node is no longer configured
/// to host is pruned even on a boot where discovery couldn't run.
enum FilterCacheReconciler {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: FilterCacheReconciler.self)
    )

    struct Result {
        /// Unconfigured filter directories removed.
        var prunedFilterCount = 0
        /// Files removed because they fall outside this node's shard.
        var prunedOutOfShardFileCount = 0
        /// Unexpected files removed from the cache root (e.g. a pre-upgrade status.json).
        var prunedStrayFileCount = 0
        /// Total files removed (out-of-shard + stray).
        var prunedFileCount: Int { self.prunedOutOfShardFileCount + self.prunedStrayFileCount }
        /// Count of persisted fragments that failed SHA256 re-verification (on-disk
        /// corruption), keyed by filterID. Each was removed for re-download.
        var revalidationFailuresByFilter: [FilterIDString: Int] = [:]
        /// True when every planned fragment is present with a matching SHA256 — i.e.
        /// no fragment downloads are needed. (The descriptor lives elsewhere and is
        /// (re)finalized by the downloader regardless, so it isn't part of this.)
        var cacheComplete = true
        /// Per-filter fragments that still need downloading (missing on disk, or
        /// removed here because they failed verification). Fragments that verified
        /// clean are deliberately omitted so the download path doesn't re-hash them.
        var pendingByFilter: [FilterIDString: [FragmentMetadata]] = [:]
    }

    /// Entries at the cache root that are never pruned. In production the fragment
    /// root and the status/descriptor directory are different volumes, but in dev
    /// `remoteRootPath` defaults to the status directory, so guard the status signal
    /// and the relocated descriptors against the top-level prune.
    private static let preservedRootEntries: Set<String> = [
        "status.json", "status.json.corrupt", "descriptors",
    ]

    /// Sidecar suffixes appended to a fragment's destination during download.
    /// Kept for fragments still in this node's shard (so an interrupted chunked
    /// download can resume), pruned for everything else. `.staging` (full-download
    /// path) plus the chunked sidecars owned by `ChunkDownloadStore`.
    private static let sidecarSuffixes = [".staging"] + ChunkDownloadStore.sidecarSuffixes

    /// Escape hatch: remove every entry under `remoteRootPath`, wiping all cached
    /// filter state so the next reconcile/download rebuilds from scratch. Returns
    /// the number of top-level entries removed. A missing root is a no-op.
    @discardableResult
    static func wipeAll(remoteRootPath: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: remoteRootPath, includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        var removed = 0
        for entry in entries {
            do {
                try fm.removeItem(at: entry)
                removed += 1
            } catch {
                Self.logger
                    .error("Failed to wipe \(entry.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
        return removed
    }

    static func reconcile(
        plan: FilterDownloadPlanner.Result,
        configuredStandardFilterIDs: Set<FilterIDString>,
        remoteRootPath: URL,
        pruningEnabled: Bool,
        maxConcurrentVerifications: Int
    ) async -> Result {
        let fm = FileManager.default
        var result = Result()

        // 1. Prune whole directories for filters this node isn't configured to host.
        //    Anything under the data root that isn't a configured filter directory is
        //    a stray and removed — including a `filter.json`/`status.json` left here by
        //    an older build — except the status signal and relocated descriptors.
        if pruningEnabled {
            if let entries = try? fm.contentsOfDirectory(
                at: remoteRootPath,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                for entry in entries {
                    let name = entry.lastPathComponent
                    if Self.preservedRootEntries.contains(name) { continue }
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDir, configuredStandardFilterIDs.contains(name) { continue }
                    do {
                        try fm.removeItem(at: entry)
                        if isDir {
                            result.prunedFilterCount += 1
                            Self.logger.log("Pruned unconfigured filter directory. FilterID=\(name, privacy: .public)")
                        } else {
                            result.prunedStrayFileCount += 1
                            Self.logger.log("Pruned stray file from cache root. File=\(name, privacy: .public)")
                        }
                    } catch {
                        Self.logger.error("Failed to prune \(name, privacy: .public): \(error, privacy: .public)")
                    }
                }
            }
        }

        // 2. For each filter we plan to download, prune out-of-shard files and collect
        //    the fragments to re-verify. Missing fragments are recorded as pending
        //    immediately (no hashing needed); present fragments are queued for the
        //    concurrent hash pass below. This step is cheap (directory listing + stat),
        //    so it stays serial.
        var workItems: [VerificationWorkItem] = []
        for (filterID, fragments) in plan.fragmentsByFilter {
            let filterDir = remoteRootPath.appendingPathComponent(filterID)
            let expectedFragmentNames = Set(fragments.map { $0.destination.lastPathComponent })

            if pruningEnabled, let entries = try? fm.contentsOfDirectory(
                at: filterDir, includingPropertiesForKeys: nil
            ) {
                for entry in entries
                    where !Self.isExpected(entry.lastPathComponent, expectedFragments: expectedFragmentNames) {
                    do {
                        try fm.removeItem(at: entry)
                        result.prunedOutOfShardFileCount += 1
                        Self.logger.log("""
                        Pruned out-of-shard file from filter cache. \
                        FilterID=\(filterID, privacy: .public) \
                        File=\(entry.lastPathComponent, privacy: .public)
                        """)
                    } catch {
                        Self.logger.error("""
                        Failed to prune \(entry.lastPathComponent, privacy: .public) \
                        from filter \(filterID, privacy: .public): \(error, privacy: .public)
                        """)
                    }
                }
            }

            for fragment in fragments {
                if fm.fileExists(atPath: fragment.destination.path) {
                    workItems.append(VerificationWorkItem(filterID: filterID, fragment: fragment))
                } else {
                    result.cacheComplete = false
                    result.pendingByFilter[filterID, default: []].append(fragment)
                }
            }
        }

        // 3. Re-hash present fragments concurrently. Reconcile runs cold (post-reboot
        //    page cache is empty), so it is bound by storage read latency: a single
        //    synchronous read stream sits at queue depth 1 and leaves most of the
        //    device's bandwidth unused. Issuing several hashes at once raises the
        //    in-flight read count and lifts effective throughput toward the device
        //    ceiling. Each task only reads files and logs — it never touches `result`,
        //    so the concurrent pass is data-race free.
        let verdicts = await Self.verifyFragments(workItems, maxConcurrency: maxConcurrentVerifications)

        // 4. Apply corrupt-fragment side effects serially: this is the only place
        //    `result` and the filesystem are mutated for verification, keeping the
        //    outcome deterministic regardless of hashing order. A corrupt fragment
        //    (SHA256 mismatch or unreadable) is removed with its sidecars and queued
        //    for re-download.
        for verdict in verdicts where verdict.outcome == .corrupt {
            let path = verdict.fragment.destination
            result.cacheComplete = false
            result.revalidationFailuresByFilter[verdict.filterID, default: 0] += 1
            try? fm.removeItem(at: path)
            ChunkDownloadStore.cleanupSidecarFiles(destination: path)
            result.pendingByFilter[verdict.filterID, default: []].append(verdict.fragment)
            Self.logger.log("""
            Removed corrupt cached fragment (SHA256 mismatch). \
            FilterID=\(verdict.filterID, privacy: .public) \
            Fragment=\(path.lastPathComponent, privacy: .public)
            """)
        }

        return result
    }

    private struct VerificationWorkItem: Sendable {
        let filterID: FilterIDString
        let fragment: FragmentMetadata
    }

    private enum VerificationOutcome: Sendable {
        case valid
        case corrupt
    }

    private struct VerificationVerdict: Sendable {
        let filterID: FilterIDString
        let fragment: FragmentMetadata
        let outcome: VerificationOutcome
    }

    /// Hashes each work item's fragment, bounded to `maxConcurrency` in-flight at a
    /// time (via the shared `mapConcurrently` throttle). A hashing error is treated as
    /// corruption so a bad read can't leave an unverified fragment in place; the
    /// distinction from a true digest mismatch is preserved in the log.
    private static func verifyFragments(
        _ items: [VerificationWorkItem],
        maxConcurrency: Int
    ) async -> [VerificationVerdict] {
        let total = items.count
        var collected: [VerificationVerdict] = []
        collected.reserveCapacity(total)

        await items.mapConcurrently(maxConcurrency: maxConcurrency) { item in
            let path = item.fragment.destination
            let outcome: VerificationOutcome
            do {
                let digest = try computeSHA256(of: path)
                outcome = digest == item.fragment.sha256 ? .valid : .corrupt
            } catch {
                Self.logger.error("""
                Failed to hash cached fragment, treating as corrupt. \
                FilterID=\(item.filterID, privacy: .public) \
                Fragment=\(path.lastPathComponent, privacy: .public) \
                Error=\(error, privacy: .public)
                """)
                outcome = .corrupt
            }
            return VerificationVerdict(
                filterID: item.filterID,
                fragment: item.fragment,
                outcome: outcome
            )
        } onResult: { verdict in
            // Runs serially in the caller's context, so mutating `collected` and
            // logging ordered progress here needs no lock.
            collected.append(verdict)
            if verdict.outcome == .valid {
                Self.logger.info("""
                Verified cached fragment. \
                FilterID=\(verdict.filterID, privacy: .public) \
                Fragment=\(verdict.fragment.destination.lastPathComponent, privacy: .public) \
                Progress=\(collected.count, privacy: .public)-of-\(total, privacy: .public)
                """)
            }
        }

        return collected
    }

    private static func isExpected(_ name: String, expectedFragments: Set<String>) -> Bool {
        if expectedFragments.contains(name) { return true }
        for suffix in Self.sidecarSuffixes where name.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            if expectedFragments.contains(base) { return true }
        }
        return false
    }
}
