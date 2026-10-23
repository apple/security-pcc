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
import CloudBoardLogging
import CloudBoardMetrics

enum Metrics {
    struct ProcessInfo: CloudBoardMetrics.Uptime.ProcessInfo {
        static let prefix: String = "cb_bridged"
        static let type = CloudBoardMetrics.Uptime.ProcessType.daemon
    }

    enum CloudBoardBridgeDaemon {
        struct PhysicalMemoryFootprintGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_physical_memory_footprint_bytes"
            var value: Int
        }

        struct LifetimeMaxPhysicalMemoryFootprintGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_lifetime_max_physical_memory_footprint_bytes"
            var value: Int
        }
    }

    enum ServiceDiscoverySubscriber {
        enum DimensionKey: String, RawRepresentable {
            case serviceName
        }

        struct UpdateSuccessCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_service_discovery_subscriber_update_success_total"
            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(serviceName: String) {
                self.action = .increment(by: 1)
                self.dimensions = [.serviceName: serviceName]
            }
        }

        struct UpdateErrorCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_service_discovery_subscriber_update_error_total"
            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(serviceName: String) {
                self.action = .increment(by: 1)
                self.dimensions = [.serviceName: serviceName]
            }
        }
    }

    enum ToolCall {
        enum ResultValue: String {
            case success
            case protocolError // error at protocol layer
            case failure // error at application layer
            case unexpectedError // any other uncaught error
        }

        struct TotalCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_tool_call_total"
            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case result
                case serverID
                case tool
            }

            init(action: CounterAction, result: ResultValue, serverID: String, tool: String) {
                self.action = action
                self.dimensions = [
                    .result: result.rawValue,
                    .serverID: serverID,
                    .tool: tool,
                ]
            }
        }

        struct DurationHistogram: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_tool_call_duration_seconds"
            static let buckets: HistogramBuckets = .requestTime
            var value: Double
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case result
                case serverID
                case tool
            }

            init(duration: Duration, result: ResultValue, serverID: String, tool: String) {
                self.value = Double(duration.microsecondsClamped) / 1_000_000
                self.dimensions = [
                    .result: result.rawValue,
                    .serverID: serverID,
                    .tool: tool,
                ]
            }
        }
    }

    enum PIRService {
        enum ResultValue: String {
            case success
            case failure
        }

        struct RequestTotalCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_pir_encrypted_request_total"
            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case result
            }

            init(action: CounterAction, result: ResultValue) {
                self.action = action
                self.dimensions = [.result: result.rawValue]
            }
        }

        struct RequestDurationHistogram: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_pir_encrypted_request_duration_seconds"
            static let buckets: HistogramBuckets = .requestTime
            var value: Double
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case result
            }

            init(duration: Duration, result: ResultValue) {
                self.value = Double(duration.microsecondsClamped) / 1_000_000
                self.dimensions = [.result: result.rawValue]
            }
        }
    }

    enum CIPCompanionService {
        enum ResultValue: String {
            case success
            case failure
            case unexpectedError
        }

        struct TotalCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_cip_companion_service_total"
            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case result
            }

            init(action: CounterAction, result: ResultValue) {
                self.action = action
                self.dimensions = [.result: result.rawValue]
            }
        }

        struct DurationHistogram: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_cip_companion_service_duration_seconds"
            static let buckets: HistogramBuckets = .requestTime
            var value: Double
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case result
            }

            init(duration: Duration, result: ResultValue) {
                self.value = Double(duration.microsecondsClamped) / 1_000_000
                self.dimensions = [.result: result.rawValue]
            }
        }
    }

    enum AppleSigningService {
        enum ResultValue: String {
            case success
            case failure
            case unexpectedError
        }

        enum OperationName: String {
            case sign
            case getKeyVersions
        }

        struct TotalCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_apple_signing_service_total"
            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case result
                case operation
            }

            init(action: CounterAction, result: ResultValue, operation: OperationName) {
                self.action = action
                self.dimensions = [
                    .result: result.rawValue,
                    .operation: operation.rawValue,
                ]
            }
        }

        struct DurationHistogram: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_apple_signing_service_duration_seconds"
            static let buckets: HistogramBuckets = .requestTime
            var value: Double
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case result
                case operation
            }

            init(duration: Duration, result: ResultValue, operation: OperationName) {
                self.value = Double(duration.microsecondsClamped) / 1_000_000
                self.dimensions = [
                    .result: result.rawValue,
                    .operation: operation.rawValue,
                ]
            }
        }
    }

    enum PersistentClientHelper {
        // Naming: metrics in this family use a `cb_bridged_persistent_` prefix. Three
        // counters predate that convention and remain UNPREFIXED —
        // `cb_bridged_drain_complete_wait_timeout_total`,
        // `cb_bridged_helper_key_expired_force_teardown_total`, and
        // `cb_bridged_connection_establishment_timeout_total` — because they are already
        // referenced by logauditlists/dashboards; renaming would break those audits. New
        // metrics in this family MUST use the `persistent_` prefix (as the gauges and the
        // newer timeout counters below do).
        /// Dimensions tagged onto every per-unit pool-membership
        /// metric so operators can slice "which capability / shard
        /// has N nodes?" without grepping logs. Both fields are
        /// always present; `shardID` is the empty string when the
        /// capability is unsharded (the same convention used on the
        /// SD wire format).
        enum UnitDimensionKeys: String {
            case capability
            case shardID
        }

        /// Dimension for connection-lifecycle counters. A persistent
        /// connection belongs to exactly one service but typically
        /// covers many units (capabilities × shards), so per-unit
        /// dimensions would N-fold-count a single event. `serviceName`
        /// is at the right granularity: bounded cardinality (one per
        /// configured persistent-service client) and meaningful to
        /// operators who want to slice events by the trusted-filter /
        /// future / etc. service.
        enum ServiceDimensionKeys: String {
            case serviceName
        }

        /// Incremented when the bridge's bounded drain-wait expires without
        /// the router signalling drain-complete. Non-zero is an alert: the
        /// router-side drain-complete logic regressed and the bridge had to
        /// force a Terminate to reclaim the stream slot.
        struct DrainCompleteWaitTimeoutCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_drain_complete_wait_timeout_total"
            var dimensions: MetricDimensions<ServiceDimensionKeys>
            var action: CounterAction = .increment(by: 1)
        }

        /// Incremented when a rotating connection's replacement stream did not reach
        /// `sendHelperReady` within the bounded readiness wait, so the old stream began
        /// draining without confirmation that the replacement was routable. Non-zero means
        /// the make-before-break overlap degraded to a plain drain for that rotation —
        /// investigate replacement establishment latency / failures.
        struct ReplacementReadyWaitTimeoutCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_persistent_replacement_ready_wait_timeout_total"
            var dimensions: MetricDimensions<ServiceDimensionKeys>
            var action: CounterAction = .increment(by: 1)
        }

        /// Incremented when the bridge force-tears-down a helper because its
        /// attestation key has hard-expired (server-supplied
        /// `SuggestedAttestation.expires_after`). Non-zero means earlier
        /// defenses (router-side drain-complete + bridge drain-wait timeout)
        /// failed to reap a helper before its key became useless — investigate.
        struct HelperKeyExpiredForceTeardownCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_helper_key_expired_force_teardown_total"
            var dimensions: MetricDimensions<ServiceDimensionKeys>
            var action: CounterAction = .increment(by: 1)
        }

        /// Incremented when the outer establishment-timeout wrapper trips
        /// before gRPC's own `connectionPool.maxWaitTime` cleared the
        /// attempt — i.e. the underlying knob did not bound the failure on
        /// its own. The bridge throws a retryable error and the retry
        /// filter promotes a spare if one is available.
        struct ConnectionEstablishmentTimeoutCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_connection_establishment_timeout_total"
            var dimensions: MetricDimensions<ServiceDimensionKeys>
            var action: CounterAction = .increment(by: 1)
        }

        /// Number of currently-active connections per unit. Emitted after
        /// every reconciliation pass so operators can see "is unit U below
        /// cap?" without grepping logs.
        struct ActiveNodesPerUnitGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_persistent_unit_active_nodes"
            var dimensions: MetricDimensions<UnitDimensionKeys>
            var value: Int
        }

        /// Number of currently-spare connections per unit (visible candidates
        /// not promoted to active because the per-unit cap is full).
        struct SpareNodesPerUnitGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_persistent_unit_spare_nodes"
            var dimensions: MetricDimensions<UnitDimensionKeys>
            var value: Int
        }

        /// Dimensions for capability-scoped gauges. Only `capability` is meaningful
        /// — coverage is a property of the capability as a whole, not of an
        /// individual shard.
        enum CapabilityDimensionKeys: String {
            case capability
        }

        /// Number of complete, independent replicas of this capability
        /// currently being served, summed across all advertised shard
        /// configurations. Each configuration contributes the minimum
        /// active-node count over its units (its weakest shard bounds how many
        /// full copies it provides; a configuration with any uncovered unit
        /// contributes 0), so an unsharded capability on N nodes reports N and
        /// two independent one-deep configurations report 2. `0` means the
        /// capability is not being served — the tightest alert; higher values
        /// signal served redundancy. "Active" means promoted with a connection
        /// task running, not a proven-healthy stream. Operators alert on
        /// `< desiredCoverage` and graph trends.
        struct CapabilityCoverageGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_persistent_capability_coverage"
            var dimensions: MetricDimensions<CapabilityDimensionKeys>
            var value: Int
        }

        /// Count of distinct shard configurations advertised across
        /// instances for the capability. Steady-state value is 1; > 1 means
        /// instances disagree on the capability's shard set, e.g. a rolling
        /// reconfiguration is in flight. Not an alert on its own —
        /// coverage decides whether the capability is healthy.
        struct CapabilityShardConfigurationsGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_persistent_capability_shard_configurations"
            var dimensions: MetricDimensions<CapabilityDimensionKeys>
            var value: Int
        }

        /// Labels for the discovered-instances gauge. `serviceID` carries the
        /// ServiceDiscovery serviceName the instances were discovered under.
        /// `isolationDomain` is always this node's wanted domain (the gauge
        /// only counts instances in it) but is labelled so the series is
        /// self-describing. `shardID` is the empty string for unsharded
        /// capabilities (same convention as the SD wire / per-unit gauges).
        enum DiscoveredInstanceDimensionKeys: String {
            case serviceID
            case isolationDomain
            case capability
            case shardID
        }

        /// Number of ServiceDiscovery instances visible to this node — those
        /// passing cell-ID and self-node filtering, in this node's isolation
        /// domain — that advertise the unit. Re-emitted on a timer so it stays
        /// fresh between sparse SD updates. Distinct from
        /// `..._persistent_unit_active_nodes`, which counts post-reconciliation
        /// pool connections subject to per-unit caps; this counts the raw
        /// visible discovery before caps are applied.
        struct DiscoveredInstancesPerUnitGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_persistent_service_discovered_instances"
            var dimensions: MetricDimensions<DiscoveredInstanceDimensionKeys>
            var value: Int
        }
    }
}
