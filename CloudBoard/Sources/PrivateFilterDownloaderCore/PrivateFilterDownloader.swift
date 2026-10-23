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

import CloudBoardCommon
import CloudBoardIdentity
import CloudBoardMetrics
import Foundation
import Network
import os
import PrivateFilterCommon

package struct PrivateFilterDownloader {
    package init() {}

    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: PrivateFilterDownloader.self)
    )

    package func run() async throws {
        Self.logger.log("PrivateFilterDownloader starting")
        configureTemporaryDirectory(suffix: "com.apple.cloudos.PrivateFilterDownloader", logger: Self.logger)

        let config: PrivateFilterDownloaderConfiguration
        do {
            config = try PrivateFilterDownloaderConfiguration.fromSecureConfig()
            Self.logger.log("Loaded configuration from secure config: \(config, privacy: .public)")
        } catch {
            Self.logger.error("Failed to load configuration from secure config: \(error, privacy: .public)")
            throw error
        }

        guard config.enabled else {
            Self.logger.log("Downloader disabled. Exiting...")
            return
        }

        // If every configured filter is fake or synthetic, the downloader has nothing
        // to download — the synthetic fast-path below exits without touching the cache
        // volume at all (the intended maximum-speed path for synthetic-mode dev configs).
        let hasRealFilter = config.filterConfigs.values.contains { perConfig in
            switch perConfig.source {
            case .standard: true
            case .fakeRemote, .fakeLocal, .syntheticRemote, .syntheticLocal: false
            }
        }

        // Everything that touches the cache volume — the pruneAll wipe and the
        // downloads themselves — needs it writable first. The volume's mount root is
        // created root:wheel and handed to `mobile` at boot by
        // PrivateFilterDownloaderHelper; probe `remoteRootParent` (the volume root)
        // directly — not the `complete/` subdir, which we have yet to create — and
        // wait rather than crash-looping on EACCES. Skipped on the synthetic fast-path,
        // where there is nothing to wipe or download.
        if config.pruneAll || hasRealFilter {
            await CacheVolumeAccess.waitForAccess(
                to: config.remoteRootParent,
                mode: .readWritable,
                pollInterval: .seconds(config.cacheAccessRetryIntervalSeconds),
                logger: Self.logger
            )
        }

        // Escape hatch: wipe all cached state so a misbehaving cache can be forced to
        // rebuild from scratch. Runs even in fake/synthetic mode so it can clear stale
        // data left from a prior standard-filter config — which is why the wait above
        // is gated on `pruneAll || hasRealFilter`, not `hasRealFilter` alone. Must come
        // after that wait: on the managed volume the wipe cannot enumerate/delete
        // anything until the ownership fixup has made it writable.
        if config.pruneAll {
            let removed = FilterCacheReconciler.wipeAll(remoteRootPath: config.remoteRootPath)
            Self.logger.warning("""
            pruneAll is set — wiped all cached filter state. \
            RemovedEntries=\(removed, privacy: .public) \
            Path=\(config.remoteRootPath.path, privacy: .public)
            """)
        }

        guard hasRealFilter else {
            Self.logger.log(
                "No filters require downloading (all are fake/synthetic). Exiting..."
            )
            return
        }

        guard let urlPrefix = config.urlPrefix, !urlPrefix.isEmpty else {
            Self.logger.error("Downloader enabled but urlPrefix is not configured — cannot proceed")
            let errorStatus = DownloaderStatus(
                status: .error,
                filters: config.filterConfigs.reduce(into: [:]) { result, entry in
                    result[entry.key] = DownloaderStatus.FilterStatus(
                        filterID: entry.key,
                        status: .error,
                        revision: nil,
                        error: "urlPrefix not configured"
                    )
                }
            )
            try self.writeDownloaderStatus(errorStatus)
            return
        }

        // Metrics. CloudBoardMetrics.CloudMetricsSystem is only needed by
        // IdentityManager (created later, for downloads), but it also bootstraps
        // CloudMetrics for the process — so create it before the PrivateFilter metrics
        // system (which uses bootstrap: false) and before we emit anything, since the
        // reconcile metrics below are emitted even on the no-download fast path.
        let cbMetricsSystem: any MetricsSystem = CloudMetricsSystem(clientName: "PrivateFilterDownloader")
        let privateFilterMetrics: any PrivateFilterMetricsSystem = PrivateFilterCloudMetricsSystem(
            clientName: "PrivateFilterDownloader", bootstrap: false
        )

        // Plan: load metadata, construct URLs, shard-slice.
        let plan = FilterDownloadPlanner.plan(config: config)
        var filterStatuses = plan.failedFilters

        // Reconcile the on-disk cache against config before anything else. On a
        // persistent cache volume the fragments survive reboot, so we re-verify
        // (full re-hash) every planned fragment, and — config being canonical —
        // prune any cached filter this node is no longer configured to host plus
        // any fragments outside this node's shard. On an ephemeral (EphDM) root
        // this is a cheap no-op since the tree was wiped on boot.
        let configuredStandardFilterIDs = Set(
            config.filterConfigs.filter { $0.value.source == .standard }.map(\.key)
        )
        let reconcileStart = ContinuousClock.now
        let reconcile = await FilterCacheReconciler.reconcile(
            plan: plan,
            configuredStandardFilterIDs: configuredStandardFilterIDs,
            remoteRootPath: config.remoteRootPath,
            pruningEnabled: config.enableCachePruning,
            maxConcurrentVerifications: config.maxConcurrentVerifications
        )
        let reconcileDuration = ContinuousClock.now - reconcileStart
        self.emitReconcileMetrics(reconcile, duration: reconcileDuration, metricsSystem: privateFilterMetrics)
        Self.logger.log("""
        Cache reconcile complete. \
        PrunedFilters=\(reconcile.prunedFilterCount, privacy: .public) \
        PrunedFiles=\(reconcile.prunedFileCount, privacy: .public) \
        RevalidationFailures=\(reconcile.revalidationFailuresByFilter.values.reduce(0, +), privacy: .public) \
        ReconcileDuration=\(reconcileDuration, privacy: .public) \
        CacheComplete=\(reconcile.cacheComplete, privacy: .public)
        """)

        // Finalize the descriptor (filter.json / HMAC key) for every planned filter
        // on every boot. The descriptor lives next to status.json on the ephemeral
        // data volume, so it must be re-copied from the (signed) cryptex each boot —
        // a cheap local copy, no network. Record where the fragments live. A cryptex
        // read failure fails just that filter.
        for filterID in plan.fragmentsByFilter.keys {
            guard let source = plan.sourceByFilter[filterID] else {
                Self.logger.error("Missing download source for filter \(filterID, privacy: .public)")
                filterStatuses[filterID] = DownloaderStatus.FilterStatus(
                    filterID: filterID, status: .error, revision: nil,
                    error: "internal: missing download source"
                )
                continue
            }
            do {
                try source.finalizeDescriptor(to: PrivateFilterStatusFile.descriptorURL(for: filterID))
                filterStatuses[filterID] = DownloaderStatus.FilterStatus(
                    filterID: filterID, status: .ok, revision: nil, error: nil,
                    fragmentsDirectory: config.remoteRootPath.appendingPathComponent(filterID).path
                )
            } catch {
                Self.logger.error("""
                Failed to finalize descriptor for filter. \
                FilterID=\(filterID, privacy: .public) Error=\(error, privacy: .public)
                """)
                filterStatuses[filterID] = DownloaderStatus.FilterStatus(
                    filterID: filterID, status: .error, revision: nil,
                    error: "descriptor finalize failed: \(error)"
                )
            }
        }

        // Filters that are ready (descriptor finalized) and still need fragment
        // downloads. If none, no network/identity/downloads are required.
        let filtersNeedingDownload = plan.fragmentsByFilter.keys.filter { filterID in
            filterStatuses[filterID]?.status == .ok && !(reconcile.pendingByFilter[filterID] ?? []).isEmpty
        }

        if filtersNeedingDownload.isEmpty {
            for filterID in plan.fragmentsByFilter.keys where filterStatuses[filterID]?.status == .ok {
                privateFilterMetrics.emit(
                    Metrics.FilterReadyCounter(action: .increment, dimensions: [.filterID: filterID])
                )
            }
            let downloaderStatus = DownloaderStatus(
                status: Self.overallStatus(filterStatuses), filters: filterStatuses
            )
            try self.writeDownloaderStatus(downloaderStatus)
            Self.logger.log("All cached fragments present and verified; published status.json without downloading.")
            return
        }

        let identityManager = IdentityManager(
            metricsSystem: cbMetricsSystem,
            metricProcess: "PrivateFilterDownloader",
            identityBackendType: .narrative()
        )

        await self.waitForNetworkConnectivity()

        let overallDownloadStart = ContinuousClock.now

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                await identityManager.identityUpdateLoop()
            }
            group.addTask {
                // If this fails it implies something has gone very wrong in the metrics subsystem
                // we do not want to continue in those circumstances
                do {
                    try await runEmitPrivateFilterMemoryUsageMetricsLoop(
                        logger: Self.logger,
                        metricsSystem: privateFilterMetrics,
                        physicalMemoryFootprintGauge: {
                            Metrics.PhysicalMemoryFootprintGauge(value: $0)
                        },
                        lifetimeMaxPhysicalMemoryFootprintGauge: {
                            Metrics.LifetimeMaxPhysicalMemoryFootprintGauge(value: $0)
                        }
                    )
                } catch is CancellationError {
                    // deliberately not logging or throwing, this is just the teradown and we stop
                } catch {
                    Self.logger.error("\(error) in memory metrics polling - terminating")
                    throw error
                }
            }
            // Download the pending fragments for each ready filter. Fragments that
            // already verified clean are left as-is and not re-hashed; the descriptor
            // was already finalized above. Filters that are ready with no pending
            // fragments need no work here.
            for filterID in plan.fragmentsByFilter.keys {
                guard filterStatuses[filterID]?.status == .ok else { continue }
                let pending = reconcile.pendingByFilter[filterID] ?? []

                if pending.isEmpty {
                    privateFilterMetrics.emit(
                        Metrics.FilterReadyCounter(action: .increment, dimensions: [.filterID: filterID])
                    )
                    continue
                }

                Self.logger.log("""
                Processing filter. \
                FilterID=\(filterID, privacy: .public) \
                PendingFragments=\(pending.count, privacy: .public)
                """)

                let filterDownloadStart = ContinuousClock.now
                do {
                    try await self.downloadFilter(
                        filterID: filterID,
                        fragments: pending,
                        config: config,
                        identityManager: identityManager,
                        metricsSystem: privateFilterMetrics
                    )
                    privateFilterMetrics.emit(
                        Metrics.FilterReadyCounter(action: .increment, dimensions: [.filterID: filterID])
                    )
                    let bytesDownloaded = pending.reduce(0) { $0 + Int($1.fileSize ?? 0) }
                    if bytesDownloaded > 0 {
                        privateFilterMetrics.emit(
                            Metrics.BytesDownloadedCounter(
                                action: .increment(by: bytesDownloaded),
                                dimensions: [.filterID: filterID]
                            )
                        )
                    }

                    let filterDownloadDuration = ContinuousClock.now - filterDownloadStart
                    privateFilterMetrics.emit(
                        Metrics.FilterDownloadDurationGauge(
                            value: filterDownloadDuration.privateFilterSeconds,
                            dimensions: [.filterID: filterID]
                        )
                    )
                    privateFilterMetrics.emit(
                        Metrics.FilterDownloadCompletionCounter(
                            action: .increment,
                            filterID: filterID,
                            status: .ok
                        )
                    )
                    Self.logger.log("Filter download complete. FilterID=\(filterID, privacy: .public)")
                } catch {
                    Self.logger.error("""
                    Filter download failed. \
                    FilterID=\(filterID, privacy: .public) \
                    Error=\(error, privacy: .public)
                    """)
                    filterStatuses[filterID] = DownloaderStatus.FilterStatus(
                        filterID: filterID, status: .error, revision: nil, error: "\(error)"
                    )
                    privateFilterMetrics.emit(
                        Metrics.FilterDownloadCompletionCounter(
                            action: .increment,
                            filterID: filterID,
                            status: .error
                        )
                    )
                }
            }

            let overallDownloadDuration = ContinuousClock.now - overallDownloadStart
            privateFilterMetrics.emit(
                Metrics.OverallDownloadDurationGauge(value: overallDownloadDuration.privateFilterSeconds)
            )

            // Compute overall status and write status.json.
            let overallStatus = Self.overallStatus(filterStatuses)

            let downloaderStatus = DownloaderStatus(status: overallStatus, filters: filterStatuses)
            do {
                try self.writeDownloaderStatus(downloaderStatus)
            } catch {
                Self.logger.error("Failed to write status.json: \(error, privacy: .public)")
                throw error
            }

            Self.logger.log("""
            Download completed. \
            OverallStatus=\(overallStatus.rawValue, privacy: .public) \
            Duration=\(overallDownloadDuration, privacy: .public)
            """)

            group.cancelAll()
        }
    }

    private func waitForNetworkConnectivity() async {
        Self.logger.log("Waiting for network connectivity...")

        let monitor = NWPathMonitor()
        monitor.start(
            queue: DispatchQueue(label: "com.apple.cloudos.PrivateFilterDownloader.network-monitor")
        )
        defer { monitor.cancel() }

        let maxAttempts = 5
        let interval: Duration = .seconds(30)
        for attempt in 1 ... maxAttempts {
            if monitor.currentPath.status == .satisfied {
                Self.logger.log("Network connectivity established")
                return
            }
            Self.logger.log("""
            Network not yet available, waiting. \
            Attempt=\(attempt, privacy: .public)/\(maxAttempts, privacy: .public)
            """)
            try? await Task.sleep(for: interval)
        }

        Self.logger.warning("Network connectivity not detected in time. Proceeding anyway")
    }

    /// Downloads the given (pending) fragments for a filter into its fragments
    /// directory. The descriptor is finalized separately by the caller.
    private func downloadFilter(
        filterID: FilterIDString,
        fragments: [FragmentMetadata],
        config: PrivateFilterDownloaderConfiguration,
        identityManager: IdentityManager,
        metricsSystem: any PrivateFilterMetricsSystem
    ) async throws {
        // Create the filter output directory once, before any downloads begin.
        let filterDirectory = config.remoteRootPath
            .appendingPathComponent(filterID)
        try FileManager.default.createDirectory(at: filterDirectory, withIntermediateDirectories: true)

        let manager = PrivateFilterDownloadManager(
            fragmentsMetadata: Set(fragments),
            identityManager: identityManager,
            metricsSystem: metricsSystem,
            filterID: filterID,
            maxConcurrentDownloads: config.maxConcurrentDownloads,
            maxConcurrentVerifications: config.maxConcurrentVerifications,
            maxRetryAttempts: config.maxRetryAttempts,
            maxFragmentDownloadFailures: config.maxFragmentDownloadFailures,
            rangeConfig: RangeDownloadConfig(
                enabled: config.rangeDownloadEnabled,
                chunkSize: config.rangeChunkSize,
                chunkRetryAttempts: config.rangeChunkRetryAttempts
            )
        )
        let urlSession = URLSession(
            configuration: config.urlSessionConfig,
            delegate: manager,
            delegateQueue: nil
        )
        defer {
            urlSession.finishTasksAndInvalidate()
        }

        do {
            try await manager.downloadFragments(using: urlSession)
            Self.logger.log("""
            All pending fragments for filter downloaded. \
            FilterID=\(filterID, privacy: .public)
            """)
        } catch {
            Self.logger.error("""
            Error downloading fragments for filter. \
            FilterID=\(filterID, privacy: .public) \
            Error=\(error, privacy: .public)
            """)
            throw error
        }
    }

    /// Overall status from per-filter results: `.ok` if all succeeded, `.partial`
    /// if some did, `.error` if none did (and `.ok` for an empty set — nothing to do).
    private static func overallStatus(
        _ filterStatuses: [FilterIDString: DownloaderStatus.FilterStatus]
    ) -> DownloaderStatus.Status {
        let okCount = filterStatuses.values.filter { $0.status == .ok }.count
        if okCount == filterStatuses.count {
            return .ok
        } else if okCount > 0 {
            return .partial
        } else {
            return .error
        }
    }

    /// Emit the metrics describing the startup reconcile pass: how long it took,
    /// whether the cache was already complete, what was pruned, and any on-disk
    /// corruption found. Emitted on every boot, including the no-download fast path.
    private func emitReconcileMetrics(
        _ reconcile: FilterCacheReconciler.Result,
        duration: Duration,
        metricsSystem: any PrivateFilterMetricsSystem
    ) {
        metricsSystem.emit(Metrics.CacheReconcileDurationGauge(value: duration.privateFilterSeconds))
        metricsSystem.emit(Metrics.CacheReconcileCounter(
            action: .increment,
            outcome: reconcile.cacheComplete ? .complete : .repair
        ))
        if reconcile.prunedFilterCount > 0 {
            metricsSystem.emit(Metrics.PrunedFilterCounter(
                action: .increment(by: reconcile.prunedFilterCount),
                dimensions: [.reason: "unconfigured"]
            ))
        }
        if reconcile.prunedOutOfShardFileCount > 0 {
            metricsSystem.emit(Metrics.PrunedFileCounter(
                action: .increment(by: reconcile.prunedOutOfShardFileCount),
                dimensions: [.reason: "out_of_shard"]
            ))
        }
        if reconcile.prunedStrayFileCount > 0 {
            metricsSystem.emit(Metrics.PrunedFileCounter(
                action: .increment(by: reconcile.prunedStrayFileCount),
                dimensions: [.reason: "stray"]
            ))
        }
        for (filterID, count) in reconcile.revalidationFailuresByFilter where count > 0 {
            metricsSystem.emit(Metrics.FragmentRevalidationFailureCounter(
                action: .increment(by: count),
                dimensions: [.filterID: filterID]
            ))
        }
    }

    /// Writes `status.json` atomically to the fixed **ephemeral** status path
    /// (`PrivateFilterStatusFile.url`), creating its directory if needed. Living on
    /// the wiped data volume rather than the persistent cache volume, the file
    /// vanishes on reboot — so its presence means "validated this boot", which is
    /// exactly the signal the controller waits on.
    private func writeDownloaderStatus(_ status: DownloaderStatus) throws {
        let fileManager = FileManager.default
        let directory = PrivateFilterStatusFile.directory
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(status)

        try data.write(to: PrivateFilterStatusFile.url, options: .atomic)

        Self.logger.log("Wrote status.json to \(PrivateFilterStatusFile.url.path, privacy: .public)")
    }
}
