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

import CloudBoardMetrics
import Foundation

extension HistogramBuckets {
    fileprivate static let keyAttestationTime: Self = [
        0.005,
        0.01,
        0.025,
        0.05,
        0.075,
        0.1,
        0.125,
        0.15,
        0.175,
        0.2,
        0.25,
        0.3,
        0.35,
        0.4,
        0.45,
        0.5,
        0.6,
        0.7,
        0.8,
        0.9,
        1.0,
        1.25,
        1.5,
        1.75,
        2.0,
        2.25,
        2.5,
        3.0,
        3.5,
        4.0,
        4.5,
        5.0,
        5.5,
        6.0,
        6.5,
        7.0,
        7.5,
        8.0,
        8.5,
        9.0,
        9.5,
        10,
        15,
        17.5,
        20,
        25,
        30,
        35,
        40,
        45,
        50,
        60,
        80,
    ]
    fileprivate static let dcProvisioningCertProvisioningTime = keyAttestationTime
}

enum CloudBoardAttestationMetrics {
    struct ProcessInfo: CloudBoardMetrics.Uptime.ProcessInfo {
        static let prefix: String = "cb_attestationd"
        static let type = CloudBoardMetrics.Uptime.ProcessType.daemon
    }

    enum CloudAttestation {
        struct AttestationCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_attestation_total"
            var action: CounterAction
        }

        struct AttestationErrorCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_attestation_failed_total"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }

        struct AttestationRetryCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_attestation_retry_total"
            var action: CounterAction
        }

        struct AttestationDurationHistogram: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_attestation_seconds"
            static let buckets: HistogramBuckets = .keyAttestationTime
            var value: Double
        }
    }

    enum CloudBoardAttestationDaemon {
        struct PhysicalMemoryFootprintGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_physical_memory_footprint_bytes"
            var value: Int
        }

        struct LifetimeMaxPhysicalMemoryFootprintGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_lifetime_max_physical_memory_footprint_bytes"
            var value: Int
        }
    }

    enum CloudBoardAttestationServer {
        struct KeyRotationCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_key_rotated_total"
            var action: CounterAction
        }

        struct RecycleCheckCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_recycle_check_total"
            var action: CounterAction
        }

        struct RecycleCheckRecycledCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_recycle_check_recycled_total"
            var action: CounterAction
        }

        struct RecycleCheckFailedCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_recycle_check_failed_total"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }
    }

    enum TransparencyLog {
        struct TransparencyLogCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_log_total"
            var action: CounterAction
        }

        struct TransparencyLogErrorCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_log_failed_total"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }

        struct TransparencyLogRetryCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_log_retry_total"
            var action: CounterAction
        }
    }

    enum CloudAttestationValidator {
        enum InCache: String, RawRepresentable {
            case miss // total miss, started new validation
            case hit // cache hit - ver cheap
            case deduped // miss, but another validaiton already started, awaiting that
        }

        enum DimensionKey: String, RawRepresentable {
            case inCache
        }

        /// Number of validated entries
        struct WorkerValidationCacheCountGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_compute_node_attestation_cache_validated_count"
            var value: Double
        }

        /// Number of entries being validated at this point
        struct WorkerValidationCacheValidatingCountGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_compute_node_attestation_cache_validating_count"
            var value: Double
        }

        struct ValidationCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_compute_node_attestation_validation_total"
            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>
            init(action: CounterAction, inCache: InCache) {
                self.action = action
                self.dimensions = Self.makeDimensions(inCache: inCache)
            }

            /// useful for unit test assertions
            static func makeDimensions(inCache: InCache) -> MetricDimensions<DimensionKey> {
                [
                    .inCache: inCache.rawValue,
                ]
            }
        }

        struct FailedValidationCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_compute_node_attestation_failed_validation_total"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }

        struct ValidationDurationHistogram: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_compute_node_attestation_validation_seconds"
            static let buckets: HistogramBuckets = .keyAttestationTime
            var dimensions: MetricDimensions<DimensionKey>
            var value: Double

            init(duration: Duration, inCache: InCache) {
                self.value = duration.seconds
                self.dimensions = [
                    .inCache: inCache.rawValue,
                ]
            }
        }
    }

    enum TransparencyCache {
        struct LogEntryCacheCountGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_cache_log_entry_count"
            var value: Int
        }

        struct LogConsistencyCacheCountGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_cache_log_consistency_count"
            var value: Int
        }

        struct LogEntryHitCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_cache_log_entry_hit_total"
            var action: CounterAction
        }

        struct LogEntryMissCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_cache_log_entry_miss_total"
            var action: CounterAction
        }

        struct LogConsistencyHitCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_cache_log_consistency_hit_total"
            var action: CounterAction
        }

        struct LogConsistencyMissCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_cache_log_consistency_miss_total"
            var action: CounterAction
        }

        struct LogEntryEvictionCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_cache_log_entry_eviction_total"
            var action: CounterAction
        }

        struct LogConsistencyEvictionCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_transparency_cache_log_consistency_eviction_total"
            var action: CounterAction
        }
    }

    enum RackIdValidation {
        struct WorkerRackIdChangeCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_compute_node_rack_id_change_total"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }
    }
}
