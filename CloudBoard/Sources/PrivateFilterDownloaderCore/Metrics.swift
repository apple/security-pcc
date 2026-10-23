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

import PrivateFilterCommon

enum Metrics {
    static let prefix: String = "privatefilterdownloader"

    struct PhysicalMemoryFootprintGauge: PrivateFilterGauge {
        static let label: PrivateFilterMetricLabel = "\(prefix)_physical_memory_footprint_bytes"
        var value: Int
    }

    struct LifetimeMaxPhysicalMemoryFootprintGauge: PrivateFilterGauge {
        static let label: PrivateFilterMetricLabel = "\(prefix)_lifetime_max_physical_memory_footprint_bytes"
        var value: Int
    }

    enum DimensionKey: String, RawRepresentable {
        case filterID
    }

    struct FragmentDownloadAttemptCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_fragment_download_attempt_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    struct FragmentDownloadSuccessCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_fragment_download_success_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    struct FragmentDownloadFailureCounter: PrivateFilterErrorCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_fragment_download_failure_total"
        var dimensions: PrivateFilterMetricDimensions<ErrorDimensionKey>
        var action: PrivateFilterCounterAction

        enum ErrorDimensionKey: String, PrivateFilterDimensionKeysWithError, RawRepresentable, Hashable {
            case filterID
            case errorDescription
        }
    }

    struct FilterDownloadCompletionCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_filter_download_completion_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<FilterCompletionDimensionKey>

        enum FilterCompletionDimensionKey: String, RawRepresentable {
            case filterID
            case status
        }

        init(action: PrivateFilterCounterAction, filterID: String, status: DownloaderStatus.FilterStatus.Status) {
            self.action = action
            self.dimensions = [
                .filterID: filterID,
                .status: status.rawValue,
            ]
        }
    }

    /// (downloaded fragments / total fragments to download) %
    struct FilterDownloadProgressGauge: PrivateFilterGauge {
        static let label: PrivateFilterMetricLabel = "\(prefix)_download_progress_percent"
        var value: Int
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    struct FragmentDownloadDurationGauge: PrivateFilterGauge {
        static let label: PrivateFilterMetricLabel = "\(prefix)_fragment_download_duration_seconds"
        var value: Double
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    struct FilterDownloadDurationGauge: PrivateFilterGauge {
        static let label: PrivateFilterMetricLabel = "\(prefix)_filter_download_duration_seconds"
        var value: Double
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    struct OverallDownloadDurationGauge: PrivateFilterGauge {
        static let label: PrivateFilterMetricLabel = "\(prefix)_overall_download_duration_seconds"
        var value: Double
    }

    // MARK: - Range download metrics

    struct RangeChunkAttemptCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_range_chunk_attempt_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    struct RangeChunkSuccessCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_range_chunk_success_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    struct RangeFallbackToFullCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_range_fallback_to_full_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    // MARK: - Cache reconcile metrics

    enum CacheReconcileOutcome: String {
        /// Every wanted fragment was already present and verified — no download.
        case complete
        /// At least one fragment had to be (re)downloaded this boot.
        case repair
    }

    /// One increment per boot, dimensioned by whether the persistent cache was
    /// already complete or needed repair. The key signal that the cache volume is
    /// doing its job (and the replacement for "downloader ran" on fast-path boots,
    /// which otherwise emit no download metrics).
    struct CacheReconcileCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_cache_reconcile_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<ReconcileDimensionKey>

        enum ReconcileDimensionKey: String, RawRepresentable {
            case outcome
        }

        init(action: PrivateFilterCounterAction, outcome: CacheReconcileOutcome) {
            self.action = action
            self.dimensions = [.outcome: outcome.rawValue]
        }
    }

    /// Wall-clock time of the startup reconcile/verification pass (the full re-hash
    /// of persisted fragments) — new boot latency that gates controller startup.
    struct CacheReconcileDurationGauge: PrivateFilterGauge {
        static let label: PrivateFilterMetricLabel = "\(prefix)_cache_reconcile_duration_seconds"
        var value: Double
    }

    /// A persisted fragment failed SHA256 re-verification on boot and was removed
    /// for re-download — i.e. detected on-disk corruption.
    struct FragmentRevalidationFailureCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_fragment_revalidation_failure_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    enum PruneDimensionKey: String, RawRepresentable {
        case reason
    }

    /// A cached filter directory removed because this node is no longer configured
    /// to host it (decommission / source change). Reason is always `unconfigured`.
    struct PrunedFilterCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_pruned_filter_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<PruneDimensionKey>
    }

    /// A cached file removed: `out_of_shard` (fragment outside this node's shard) or
    /// `stray` (an unexpected file at the cache root, e.g. a pre-upgrade status.json).
    struct PrunedFileCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_pruned_file_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<PruneDimensionKey>
    }

    /// A filter confirmed ready this boot, regardless of path (served from cache or
    /// freshly downloaded). Keeps a per-boot readiness signal even when nothing is
    /// downloaded — `filter_download_completion_total` only covers actual downloads.
    struct FilterReadyCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_filter_ready_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }

    /// Bytes actually downloaded for a filter this boot (sum of (re)downloaded
    /// fragment sizes). Quantifies bandwidth used — and, inversely, saved by the cache.
    struct BytesDownloadedCounter: PrivateFilterCounter {
        static let label: PrivateFilterMetricLabel = "\(prefix)_bytes_downloaded_total"
        var action: PrivateFilterCounterAction
        var dimensions: PrivateFilterMetricDimensions<DimensionKey>
    }
}
