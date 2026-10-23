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
import CloudBoardDomain
import CloudBoardLogging
import CloudBoardMetrics

extension HistogramBuckets {
    fileprivate static let chunkSize: HistogramBuckets = [
        1,
        2,
        4,
        8,
        16,
        32,
        64,
        128,
        256,
        512,
        1024, // KiB
        1536,
        2048,
        2560,
        3072,
        3584,
        4096,
        8192,
        16384,
        32768,
        65536,
        131_072,
        262_144,
        524_288,
        1_048_576, // MiB
        536_870_912,
        1_073_741_824, // GiB
    ]

    fileprivate static let keyUnwrapTime: Self = [
        0.005524,
        0.007812,
        0.011049,
        0.015625,
        0.022097,
        0.03125,
        0.044194,
        0.0625,
        0.088388,
        0.125,
        0.176777,
        0.25,
        0.353553,
        0.5, // by the time we are at 500ms mark it really doesn't matter how much slower we go
    ]

    fileprivate static let findWorkerDuration: Self = [
        0,
        0.0001,
        0.0002,
        0.0003,
        0.0004,
        0.0005,
        0.0006,
        0.0007,
        0.0008,
        0.0009,
        0.0010,
        0.0011,
        0.0012,
        0.0013,
        0.0014,
        0.0015,
        0.0016,
        0.0017,
        0.0018,
        0.0019,
        0.002,
        0.0025,
        0.003,
        0.0035,
        0.004,
        0.0045,
        0.005,
        0.006,
        0.007,
        0.008,
        0.009,
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
        1.5,
        2.0,
        2.5,
        3.0,
        4.0,
        5.0,
        6.0,
        7.0,
        8.0,
        9.0,
        10,
        11,
        12,
        13,
        14,
        15,
        17.5,
        20,
        25,
        30,
    ]
}

enum Metrics {
    struct ProcessInfo: CloudBoardMetrics.Uptime.ProcessInfo {
        static let prefix: String = "cb_jobhelper"
        static let type = CloudBoardMetrics.Uptime.ProcessType.process
    }

    /// This is poorly named - it is now covered by ``CloudBoardMetrics/Uptime`` but this remains
    /// for a short time to ensure both old and new metrics are present for the transition
    @available(*, deprecated, message: "This is being entirely replaced by CloudBoardMetrics.Uptime")
    enum Daemon {
        struct LaunchCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_daemon_launch_total"
            var action: CounterAction
        }

        struct UptimeGauge: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_daemon_uptime"
            var value: Int
        }

        struct ErrorExitCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_daemon_exit_error"
            var action: CounterAction
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
        }

        struct TotalExitCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_daemon_exit_total"
            var action: CounterAction
        }
    }

    enum Messenger {
        struct TotalRequestsReceivedCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_messenger_requests_received_total"
            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(
                action: CounterAction,
                automatedDeviceGroup: Bool,
                featureId: String?,
                bundleId: String?,
                inferenceId: String?
            ) {
                self.action = action
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        struct RequestChunkReceivedSizeHistogram: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_messenger_request_chunk_received_size_bytes"
            static let buckets: HistogramBuckets = .chunkSize
            var value: Int
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            init(size: Int, automatedDeviceGroup: Bool, featureId: String?, bundleId: String?, inferenceId: String?) {
                self.value = size
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        struct TotalResponseChunksReceivedCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_messenger_response_chunks_received_total"
            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(
                action: CounterAction,
                automatedDeviceGroup: Bool,
                featureId: String?,
                bundleId: String?,
                inferenceId: String?
            ) {
                self.action = action
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        struct TotalResponseChunksSentCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_messenger_response_chunks_sent_total"
            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(
                action: CounterAction,
                automatedDeviceGroup: Bool,
                featureId: String?,
                bundleId: String?,
                inferenceId: String?
            ) {
                self.action = action
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        struct TotalResponseChunksInBuffer: Gauge {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_messenger_response_chunks_in_buffer_total"
            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            var value: Int
            var dimensions: MetricDimensions<DimensionKey>

            init(value: Int, automatedDeviceGroup: Bool, featureId: String?, bundleId: String?, inferenceId: String?) {
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
                self.value = value
            }
        }

        struct TotalResponseChunkReceivedSizeHistogram: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_messenger_response_chunk_received_size_bytes"
            static let buckets: HistogramBuckets = .chunkSize
            var value: Int
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            init(size: Int, automatedDeviceGroup: Bool, featureId: String?, bundleId: String?, inferenceId: String?) {
                self.value = size
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        struct TotalResponseChunksBufferedSizeHistogram: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_messenger_response_chunk_buffered_size_bytes"
            static let buckets: HistogramBuckets = .chunkSize
            var value: Int
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            init(size: Int, automatedDeviceGroup: Bool, featureId: String?, bundleId: String?, inferenceId: String?) {
                self.value = size
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        struct OverallErrorCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_messenger_error"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }

        struct KeyUnwrapDuration: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_key_unwrap_duration_seconds"
            static let buckets: HistogramBuckets = .keyUnwrapTime
            var dimensions: MetricDimensions<DimensionKey>
            var value: Double

            enum DimensionKey: String, RawRepresentable {
                case result
                case errorDescription
                case automatedDeviceGroup
            }

            init(duration: Duration, error: Error?, automatedDeviceGroup: Bool) {
                self.value = Double(duration.microsecondsClamped) / 1_000_000
                if let error {
                    self.dimensions = [
                        .result: "error",
                        .errorDescription: String(reportable: error),
                        .automatedDeviceGroup: automatedDeviceGroup.description,
                    ]
                } else {
                    self.dimensions = [
                        .result: "success",
                        .automatedDeviceGroup: automatedDeviceGroup.description,
                    ]
                }
            }
        }
    }

    enum WorkloadManager {
        // Duration from receiving the request to find a worker from cloudApp till we inform the cloudApp that a worker
        // has been found
        struct FindWorkerDuration: Histogram {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_find_worker_duration_seconds"
            static let buckets: HistogramBuckets = .findWorkerDuration
            var value: Double

            init(duration: Duration) {
                self.value = duration.seconds
            }
        }

        struct TotalRequestsReceivedCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_workload_manager_requests_received_total"
            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
            }

            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(action: CounterAction, automatedDeviceGroup: Bool) {
                self.action = action
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                ]
            }
        }

        struct TotalResponsesSentCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_workload_manager_responses_sent_total"
            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            init(
                action: CounterAction,
                automatedDeviceGroup: Bool, featureId: String?, bundleId: String?, inferenceId: String?
            ) {
                self.action = action
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        struct SuccessResponsesSentCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_workload_manager_responses_sent_success"
            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            init(
                action: CounterAction,
                automatedDeviceGroup: Bool, featureId: String?, bundleId: String?, inferenceId: String?
            ) {
                self.action = action
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        struct FailureResponsesSentCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_workload_manager_responses_sent_failure"
            var dimensions: MetricDimensions<DimensionKey>
            var action: CounterAction

            init(dimensions: MetricDimensions<DimensionKey>, action: CounterAction) {
                self.action = action
                self.dimensions = dimensions
            }

            enum DimensionKey: String, RawRepresentable, DimensionKeysWithError {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
                case errorDescription
            }

            init(
                action: CounterAction,
                automatedDeviceGroup: Bool,
                error: some Swift.Error, featureId: String?, bundleId: String?, inferenceId: String?
            ) {
                self.action = action
                self.dimensions = [
                    .errorDescription: String(reportable: error),
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        struct TotalSubrequestReceivedCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_workload_manager_subrequest_total"
            var dimensions: MetricDimensions<DimensionKey>
            var action: CounterAction

            init(dimensions: MetricDimensions<DimensionKey>, action: CounterAction) {
                self.action = action
                self.dimensions = dimensions
            }

            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
            }

            init(
                action: CounterAction,
                automatedDeviceGroup: Bool,
                featureId: String?, bundleId: String?, inferenceId: String?
            ) {
                self.action = action
                self.dimensions = [
                    .automatedDeviceGroup: automatedDeviceGroup.description,
                    .featureId: featureId ?? "",
                    .bundleId: bundleId ?? "",
                    .inferenceId: inferenceId ?? "",
                ]
            }
        }

        enum SubrequestStatus: String, Sendable {
            case ok
            case discarded
            case failed
        }

        struct SubrequestFailureCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_workload_manager_subrequest_failure"
            var dimensions: MetricDimensions<DimensionKey>
            var action: CounterAction

            init(dimensions: MetricDimensions<DimensionKey>, action: CounterAction) {
                self.action = action
                self.dimensions = dimensions
            }

            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
                case status
                case errorDescription
            }

            init(
                action: CounterAction,
                automatedDeviceGroup: Bool,
                featureId: String?,
                bundleId: String?,
                inferenceId: String?,
                status: InternalSubresponseStatus
            ) {
                self.action = action
                if case .error(let error) = status {
                    self.dimensions = [
                        .automatedDeviceGroup: automatedDeviceGroup.description,
                        .featureId: featureId ?? "",
                        .bundleId: bundleId ?? "",
                        .inferenceId: inferenceId ?? "",
                        .status: status.description,
                        .errorDescription: error.errorMessage, // Provided as a static string so safe to emit here
                    ]
                } else {
                    self.dimensions = [
                        .automatedDeviceGroup: automatedDeviceGroup.description,
                        .featureId: featureId ?? "",
                        .bundleId: bundleId ?? "",
                        .inferenceId: inferenceId ?? "",
                        .status: status.description,
                    ]
                }
            }
        }

        struct SubrequestDuration: Histogram {
            static let label: MetricLabel =
                "\(ProcessInfo.prefix)_workload_manager_subrequest_duration_seconds"
            static let buckets: HistogramBuckets = .requestTime
            var dimensions: MetricDimensions<DimensionKey>
            var value: Double

            enum DimensionKey: String, RawRepresentable {
                case automatedDeviceGroup
                case featureId
                case bundleId
                case inferenceId
                case status
                case errorDescription
            }

            init(
                duration: Duration,
                automatedDeviceGroup: Bool,
                featureId: String?,
                bundleId: String?,
                inferenceId: String?,
                status: InternalSubresponseStatus
            ) {
                self.value = Double(duration.microsecondsClamped) / 1_000_000
                switch status {
                case .ok, .discarded:
                    self.dimensions = [
                        .automatedDeviceGroup: automatedDeviceGroup.description,
                        .featureId: featureId ?? "",
                        .bundleId: bundleId ?? "",
                        .inferenceId: inferenceId ?? "",
                        .status: status.description,
                    ]
                case .error(let error):
                    self.dimensions = [
                        .automatedDeviceGroup: automatedDeviceGroup.description,
                        .featureId: featureId ?? "",
                        .bundleId: bundleId ?? "",
                        .inferenceId: inferenceId ?? "",
                        .status: status.description,
                        .errorDescription: error.errorMessage,
                    ]
                }
            }
        }

        struct OverallErrorCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_workload_manager_error"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }

        /// How many times workloadmanager finished without processing any request messages
        struct UnusedTerminationCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_workload_manager_unused_termination_total"
            var action: CounterAction
        }

        struct WorkloadDurationFromFirstRequestMessage: Histogram {
            static let label: MetricLabel =
                "\(ProcessInfo.prefix)_workload_manager_duration_from_first_request_seconds"
            static let buckets: HistogramBuckets = .requestTime
            var dimensions: MetricDimensions<DimensionKey>
            var value: Double

            enum DimensionKey: String, RawRepresentable {
                case result
                case errorDescription
                case automatedDeviceGroup
            }

            init(duration: Duration, error: Error?, automatedDeviceGroup: Bool) {
                self.value = Double(duration.microsecondsClamped) / 1_000_000
                if let error {
                    self.dimensions = [
                        .result: "error",
                        .errorDescription: String(reportable: error),
                        .automatedDeviceGroup: automatedDeviceGroup.description,
                    ]
                } else {
                    self.dimensions = [
                        .result: "success",
                        .automatedDeviceGroup: automatedDeviceGroup.description,
                    ]
                }
            }
        }
    }

    enum Workload {
        struct OverallErrorCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_workload_error"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }

        struct CloudAppExitCounter: ExitCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_cloudapp_process_exit"
            var dimensions: MetricDimensions<DefaultExitDimensionKeys>
            var action: CounterAction
        }

        struct SupportAppExitCounter: ExitCounter {
            public enum DimensionKeys: String, DimensionKeysWithExitCode, RawRepresentable, Hashable, Sendable {
                case appName
                case exitCode
                case reasonNamespace
            }

            static let label: MetricLabel = "\(ProcessInfo.prefix)_supportapp_process_exit"
            var dimensions: MetricDimensions<DimensionKeys>
            var action: CounterAction
        }
    }

    enum CloudAppRequestStream {
        struct OverallErrorCounter: ErrorCounter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_cloud_app_request_stream_error"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }
    }

    enum PersistentService {
        struct QuerySentCounter: Counter {
            static let label: MetricLabel = "\(ProcessInfo.prefix)_persistent_service_query_sent_total"
            enum DimensionKey: String, RawRepresentable {
                case serviceID
            }

            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(action: CounterAction, serviceID: String) {
                self.action = action
                self.dimensions = [.serviceID: serviceID]
            }
        }

        struct QueryRejectedRELFinalizedCounter: Counter {
            static let label: MetricLabel =
                "\(ProcessInfo.prefix)_persistent_service_query_rejected_rel_finalized_total"
            var action: CounterAction
        }

        struct TransitiveTrustCounter: Counter {
            static let label: MetricLabel =
                "\(ProcessInfo.prefix)_persistent_service_transitive_trust_total"
            enum DimensionKey: String, RawRepresentable {
                case serviceName
            }

            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(action: CounterAction, serviceName: String) {
                self.action = action
                self.dimensions = [.serviceName: serviceName]
            }
        }

        struct TransitiveTrustPrevalidatedCounter: Counter {
            static let label: MetricLabel =
                "\(ProcessInfo.prefix)_persistent_service_transitive_trust_prevalidated_total"
            enum DimensionKey: String, RawRepresentable {
                case serviceName
            }

            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(action: CounterAction, serviceName: String) {
                self.action = action
                self.dimensions = [.serviceName: serviceName]
            }
        }

        struct TransitiveTrustPrevalidationFailureCounter: Counter {
            static let label: MetricLabel =
                "\(ProcessInfo.prefix)_persistent_service_transitive_trust_prevalidation_error_total"
            enum DimensionKey: String, RawRepresentable {
                case serviceName
                case reason
            }

            var action: CounterAction
            var dimensions: MetricDimensions<DimensionKey>

            init(action: CounterAction, serviceName: String, reason: String) {
                self.action = action
                self.dimensions = [
                    .serviceName: serviceName,
                    .reason: reason,
                ]
            }
        }
    }
}

extension InternalSubresponseStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .ok: "ok"
        case .discarded: "discarded"
        case .error: "error"
        }
    }
}
