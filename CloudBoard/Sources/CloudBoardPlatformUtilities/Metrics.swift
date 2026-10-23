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

private let prefix = "cloudboard"

enum Metrics {
    enum HotPropertiesController {
        struct HotPropertiesCanaryValue: Gauge {
            static let label: MetricLabel = "\(prefix)_hotproperties_canary"
            var value: Double
        }
    }

    enum HeartbeatPublisher {
        struct PublishedCounter: Counter {
            static let label: MetricLabel = "\(prefix)_heartbeat_publish_total"
            var action: CounterAction

            enum DimensionKey: String, RawRepresentable {
                case isHealthy
            }

            var dimensions: MetricDimensions<DimensionKey>

            init(action: CounterAction, isHealthy: Bool) {
                self.action = action
                self.dimensions = [
                    .isHealthy: "\(isHealthy)",
                ]
            }
        }

        struct FailedToPublishCounter: ErrorCounter {
            static let label: MetricLabel = "\(prefix)_heartbeat_publish_error_total"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction
        }
    }

    enum StatusMonitor {
        struct Status: Gauge {
            static let label: MetricLabel = "\(prefix)_status"
            var value: Int

            enum DimensionKey: String, RawRepresentable {
                case daemonStatus
                case knownServiceCount
                case failedComponents
            }

            var dimensions: MetricDimensions<DimensionKey>

            init(
                value: Int,
                daemonStatus: DaemonStatus
            ) {
                self.value = value
                self.dimensions = [
                    .daemonStatus: "\(daemonStatus.metricDescription)",
                ]
                switch daemonStatus {
                case .initializing, .waitingForFirstAttestationFetch, .waitingForFirstHotPropertyUpdate,
                     .waitingForWorkloadRegistration, .daemonDrained,
                     .daemonExitingOnError, .uninitialized, .serviceDiscoveryPublisherDraining:
                    () // No associated state with these, so no extra dimension
                case .serviceDiscoveryUpdateSuccess(let knownServiceCount),
                     .serviceDiscoveryUpdateFailure(let knownServiceCount):
                    self.dimensions.append(String(knownServiceCount), forKey: .knownServiceCount)
                case .componentsFailedToRun(let components):
                    self.dimensions.append(String(describing: components), forKey: .failedComponents)
                }
            }
        }

        // Deprecated
        struct LegacyStatusInitializing: Gauge {
            static let label: MetricLabel = "\(prefix)_status_initializing"
            var value: Int
        }

        // Deprecated
        struct LegacyStatusWaitingForFirstAttestationFetch: Gauge {
            static let label: MetricLabel = "\(prefix)_status_waiting_for_first_attestation_fetch"
            var value: Int
        }

        // Deprecated
        struct LegacyStatusWaitingForFirstHotPropertyUpdate: Gauge {
            static let label: MetricLabel = "\(prefix)_status_waiting_for_first_hot_property_update"
            var value: Int
        }

        // Deprecated
        struct LegacyStatusWaitingForWorkloadRegistration: Gauge {
            static let label: MetricLabel = "\(prefix)_status_waiting_for_workload_registration"
            var value: Int
        }

        // Deprecated
        struct LegacyStatusComponentsFailedToRun: Gauge {
            static let label: MetricLabel = "\(prefix)_status_components_failed_to_run"
            var value: Int

            enum DimensionKey: String, RawRepresentable {
                case failedComponents
            }

            var dimensions: MetricDimensions<DimensionKey>

            init(value: Int, failedComponents: Components) {
                self.value = value
                self.dimensions = [
                    .failedComponents: "\(failedComponents)",
                ]
            }
        }

        // Deprecated
        struct LegacyStatusServiceDiscoveryUpdateSuccess: Gauge {
            static let label: MetricLabel = "\(prefix)_status_service_discovery_update_success"
            var value: Int

            enum DimensionKey: String, RawRepresentable {
                case knownServiceCount
            }

            var dimensions: MetricDimensions<DimensionKey>

            init(value: Int, knownServiceCount: Int) {
                self.value = value
                self.dimensions = [
                    .knownServiceCount: "\(knownServiceCount)",
                ]
            }
        }

        // Deprecated
        struct LegacyStatusServiceDiscoveryUpdateFailure: Gauge {
            static let label: MetricLabel = "\(prefix)_status_service_discovery_update_failure"
            var value: Int

            enum DimensionKey: String, RawRepresentable {
                case knownServiceCount
            }

            var dimensions: MetricDimensions<DimensionKey>

            init(value: Int, knownServiceCount: Int) {
                self.value = value
                self.dimensions = [
                    .knownServiceCount: "\(knownServiceCount)",
                ]
            }
        }

        // Deprecated
        struct LegacyStatusServiceDiscoveryPublisherDraining: Gauge {
            static let label: MetricLabel = "\(prefix)_status_service_discovery_publisher_draining"
            var value: Int
        }

        // Deprecated
        struct LegacyStatusDaemonDrained: Gauge {
            static let label: MetricLabel = "\(prefix)_status_daemon_drained"
            var value: Int
        }

        // Deprecated
        struct LegacyStatusDaemonExitingOnError: Gauge {
            static let label: MetricLabel = "\(prefix)_status_daemon_exiting_on_error"
            var value: Int
        }
    }

    enum WorkloadStatus {
        struct HealthStatus: Gauge {
            static let label: MetricLabel = "\(prefix)_workload_health_status"
            var value: Int

            enum DimensionKey: String, RawRepresentable {
                case healthStatus
            }

            var dimensions: MetricDimensions<DimensionKey>

            init(value: Int, healthStatus: WorkloadController.ControllerState) {
                self.value = value
                self.dimensions = [
                    .healthStatus: "\(healthStatus)",
                ]
            }
        }
    }

    enum ControlPlaneHealthDHealthChecker {
        struct ControlPlaneHealthdStatus: Gauge {
            static let label: MetricLabel = "\(prefix)_control_plane_healthd_status"
            var value: Int

            init(value: Int) {
                self.value = value
            }
        }

        struct CloudBoardWaitingForControlPlaneHealthDReadyStatus: Gauge {
            static let label: MetricLabel = "\(prefix)_waiting_for_control_plane_healthd_ready_state"

            var value: Int

            init(value: Int) {
                self.value = value
            }
        }
    }

    enum TLSConfiguration {
        struct TLSVerificationErrorCounter: ErrorCounter {
            static let label: MetricLabel = "\(prefix)_tls_verification_failure_total"
            var dimensions: MetricDimensions<DefaultErrorDimensionKeys>
            var action: CounterAction

            init(action: CounterAction, failureReason: String) {
                self.init(dimensions: [.errorDescription: failureReason], action: action)
            }

            init(dimensions: MetricDimensions<DimensionKey>, action: CounterAction) {
                self.action = action
                self.dimensions = dimensions
            }
        }
    }
}
