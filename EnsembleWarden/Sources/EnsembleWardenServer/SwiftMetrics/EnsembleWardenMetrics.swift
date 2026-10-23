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

//
//  EnsembleWardenMetrics.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 14/12/2024.
//


package import Foundation
private import EnsembleWardenCommon
//package import EnsembleWardenServer
@_spi(OSMetric) private import os

package enum EnsembleWardenMetricLabels {
    package static let daemonLaunchTotal = "ensemblewarden_daemon_launch_total"
    package static let daemonUptime = "ensemblewarden_daemon_uptime"
    package static let launchdActiveManagedJobs = "ensemblewarden_launchd_active_managed_jobs"
    package static let xpccallsDuration = "ensemblewarden_xpccalls_duration_seconds"
    package static let clientCallsDuration = "ensemblewarden_client_calls_duration_seconds"
    package static let cryptoOperationsDuration = "ensemblewarden_crypto_operations_seconds"
    package static let cryptoSurfaceBytes = "ensemblewarden_crypto_surface_bytes"
    package static let iosurfacePrefaultDuration = "ensemblewarden_iosurface_prefault_seconds"
}

/// Stable identifiers for the `op` dimension on crypto metrics. Bound cardinality on purpose.
package enum CryptoOperation: String, Sendable {
    case encrypt
    case decrypt
}

/// Stable identifiers for the `xpc_operation` dimension on EnsembleWarden XPC metrics.
package enum EnsembleWardenXPCOperation: String, Sendable {
    case start
    case prefault
    case finish
    case publish2
    case fetch2
    case fetchMetadata
    case delete
    case dropAll
}

/// Stable identifiers for the `operation` dimension on EnsembleWarden client metrics.
package enum EnsembleWardenClientOperation: String, Sendable {
    case prewarm
    case supply
    case finish
    case publish2
    case fetch2
    case fetchMetadata
    case prefault
    case delete
    case dropAll
}

package enum EnsembleWardenMetricDimensions {
    package static let XPCPublish2Dimension = ("xpc_operation", "publish2")
    package static let XPCStartDimension = ("xpc_operation", "start")
    package static let XPCFetch2Dimension = ("xpc_operation", "fetch2")
    package static let XPCFinishDimension = ("xpc_operation", "finish")
    package static let successDimension = ("result", "success")
    package static let errorDimension = ("result", "error")
    package static let publish2Dimension = ("operation", "publish2")
    package static let fetch2Dimension = ("operation", "fetch2")
}


// Metric names should conform to
// https://prometheus.io/docs/practices/naming/
package struct EnsembleWardenMetrics<Factory: MetricsFactory> {

    private let logger = Logger(subsystem: "com.apple.cloudos.ensemblewarden", category: "Metrics")

    private var metricsFactory: MetricsFactory

    package var daemonLaunchTotalCount: CounterHandler
    package var launchdJobs: MeterHandler
    package var daemonUptime: RecorderHandler

    package init(metricsFactory: Factory) {
        self.metricsFactory = metricsFactory
        self.daemonLaunchTotalCount = metricsFactory.makeCounter(label: EnsembleWardenMetricLabels.daemonLaunchTotal, dimensions: [])
        self.launchdJobs = metricsFactory.makeMeter(label: EnsembleWardenMetricLabels.launchdActiveManagedJobs, dimensions: [])
        self.daemonUptime = metricsFactory.makeRecorder(label: EnsembleWardenMetricLabels.daemonUptime, dimensions: [], aggregate: false)
    }

    /// Runs a closure, expected to handle an XPC message, and reports metrics on if that closure succeeded.
    ///
    /// - Parameters:
    ///   - operationName: name of the XPC operation; emitted as the `xpc_operation` dimension.
    ///   - purpose: optional `KVCacheTransferPurpose`. When supplied, emitted as the `purpose`
    ///     dimension so we can split FT/ET vs multi-turn latency on the same metric.
    package func reportingXPCMetrics<T>(operationName: EnsembleWardenXPCOperation, purpose: KVCacheTransferPurpose? = nil, fn: () async throws -> T) async rethrows -> T {
        let timerLabel = EnsembleWardenMetricLabels.xpccallsDuration
        let start = Date()
        var dimensions: [(String, String)] = [
            ("xpc_operation", operationName.rawValue)
        ]
        if let purpose {
            dimensions.append(("purpose", purpose.metricsLabel))
        }

        defer {
            let processingTime = Date().timeIntervalSince(start)
            self.metricsFactory.makeRecorder(label: timerLabel, dimensions: dimensions, aggregate: true).record(processingTime)
        }

        do {
            let result = try await fn()
            dimensions.append(("result", "success"))
            return result
        } catch {
            self.logger.error("""
                Operation failed with error. \
                operation_name=\(operationName.rawValue, privacy: .public) \
                error=\(String(reportable: error), privacy: .public)
                """)
            dimensions.append(("result", "error"))
            dimensions.append(("error_category", Self.errorCategory(for: error)))
            throw error
        }
    }

    /// Runs a closure, expected to be a client operation, and reports metrics on if that closure succeeded.
    ///
    /// - Parameters:
    ///   - operationName: emitted as the `operation` dimension.
    ///   - purpose: optional `KVCacheTransferPurpose`; emitted as `purpose` when present.
    package func reportingClientMetrics<T>(operationName: EnsembleWardenClientOperation, purpose: KVCacheTransferPurpose? = nil, fn: () async throws -> T) async rethrows -> T {
        let timerLabel = EnsembleWardenMetricLabels.clientCallsDuration
        let start = Date()

        var dimensions: [(String, String)] = [
            ("operation", operationName.rawValue),
        ]
        if let purpose {
            dimensions.append(("purpose", purpose.metricsLabel))
        }

        defer {
            let processingTime = Date().timeIntervalSince(start)
            self.metricsFactory.makeRecorder(label: timerLabel, dimensions: dimensions, aggregate: true).record(processingTime)
        }

        do {
            let result = try await fn()
            dimensions.append(EnsembleWardenMetricDimensions.successDimension)
            return result
        } catch {
            dimensions.append(EnsembleWardenMetricDimensions.errorDimension)
            dimensions.append(("error_category", Self.errorCategory(for: error)))
            throw error
        }
    }

    /// Synchronous XPC-metrics wrapper for non-async XPC handler paths (e.g. `cancellation`/`finish`).
    package func reportingSyncXPCMetrics<T>(operationName: EnsembleWardenXPCOperation, fn: () throws -> T) rethrows -> T {
        let timerLabel = EnsembleWardenMetricLabels.xpccallsDuration
        let start = Date()
        var dimensions: [(String, String)] = [
            ("xpc_operation", operationName.rawValue),
        ]

        defer {
            let processingTime = Date().timeIntervalSince(start)
            self.metricsFactory.makeRecorder(label: timerLabel, dimensions: dimensions, aggregate: true).record(processingTime)
        }

        do {
            let result = try fn()
            dimensions.append(("result", "success"))
            return result
        } catch {
            self.logger.error("""
                Operation failed with error. \
                operation_name=\(operationName.rawValue, privacy: .public) \
                error=\(String(reportable: error), privacy: .public)
                """)
            dimensions.append(("result", "error"))
            dimensions.append(("error_category", Self.errorCategory(for: error)))
            throw error
        }
    }

    /// Synchronous client-metrics wrapper for non-async client calls (e.g. `prewarm`).
    package func reportingSyncClientMetrics<T>(operationName: EnsembleWardenClientOperation, fn: () throws -> T) rethrows -> T {
        let timerLabel = EnsembleWardenMetricLabels.clientCallsDuration
        let start = Date()

        var dimensions: [(String, String)] = [
            ("operation", operationName.rawValue),
        ]

        defer {
            let processingTime = Date().timeIntervalSince(start)
            self.metricsFactory.makeRecorder(label: timerLabel, dimensions: dimensions, aggregate: true).record(processingTime)
        }

        do {
            let result = try fn()
            dimensions.append(EnsembleWardenMetricDimensions.successDimension)
            return result
        } catch {
            dimensions.append(EnsembleWardenMetricDimensions.errorDimension)
            dimensions.append(("error_category", Self.errorCategory(for: error)))
            throw error
        }
    }

    /// Runs a per-IOSurface crypto operation and records its duration into a single dimensional
    /// histogram (`ensemblewarden_crypto_operations_seconds`). The histogram's auto-emitted
    /// `_count` series covers rate + error counts, so no separate counter is needed.
    ///
    /// - Parameters:
    ///   - op: which crypto operation is being timed
    ///   - fn: the operation; rethrown
    package func reportingCryptoMetrics<T>(op: CryptoOperation, fn: () throws -> T) rethrows -> T {
        let start = Date()
        var dimensions: [(String, String)] = [
            ("op", op.rawValue),
        ]

        defer {
            let processingTime = Date().timeIntervalSince(start)
            self.metricsFactory.makeRecorder(
                label: EnsembleWardenMetricLabels.cryptoOperationsDuration,
                dimensions: dimensions,
                aggregate: true
            ).record(processingTime)
        }

        do {
            let result = try fn()
            dimensions.append(EnsembleWardenMetricDimensions.successDimension)
            return result
        } catch {
            dimensions.append(EnsembleWardenMetricDimensions.errorDimension)
            dimensions.append(("error_category", Self.errorCategory(for: error)))
            throw error
        }
    }

    /// Records the size of an encrypted/decrypted IOSurface (bytes) into the per-op histogram.
    /// Throughput is derived as `bytes / duration` server-side.
    package func recordSurfaceBytes(op: CryptoOperation, bytes: Int) {
        self.metricsFactory.makeRecorder(
            label: EnsembleWardenMetricLabels.cryptoSurfaceBytes,
            dimensions: [
                ("op", op.rawValue),
            ],
            aggregate: true
        ).record(Double(bytes))
    }

    /// Increments the IOSurface prefault failure counter. Prefault failures are non-fatal; this
    /// counter exists so we can alert on rising rates without grepping logs.
    package func reportingPrefault<T>(op: CryptoOperation, fn: () throws -> T) rethrows -> T {
        let start = Date()
        var dimensions: [(String, String)] = [
            ("op", op.rawValue),
        ]

        defer {
            let processingTime = Date().timeIntervalSince(start)
            self.metricsFactory.makeRecorder(
                label: EnsembleWardenMetricLabels.iosurfacePrefaultDuration,
                dimensions: dimensions,
                aggregate: true
            ).record(processingTime)
        }

        do {
            let result = try fn()
            dimensions.append(EnsembleWardenMetricDimensions.successDimension)
            return result
        } catch {
            dimensions.append(EnsembleWardenMetricDimensions.errorDimension)
            throw error
        }
    }

    /// Maps an error to a stable, low-cardinality category string. Never use raw error
    /// descriptions here — that would make `error_category` unbounded.
    ///
    /// The `EnsembleWardenError` switch is exhaustive on purpose so adding a new case there
    /// becomes a compile error here, forcing the author to pick a bucket rather than silently
    /// folding into `ensemblewarden_other`.
    private static func errorCategory(for error: any Error) -> String {
        if let ewError = error as? EnsembleWardenError {
            switch ewError {
            // XPC
            case .unexpectedXPCMessageType: return "unexpected_xpc_message_type"
            case .invalidSyncRequest: return "invalid_sync_request"
            case .clientNoLongerActive: return "client_not_connected"
            case .unsupportedXPCRequestType: return "unsupported_xpc_request_type"
            case .invalidXPCResponse: return "invalid_xpc_response"

            // Internal
            case .failedToCreateIOSurface: return "failed_to_create_iosurface"
            case .failedToAccessDataPointer: return "failed_to_access_data_pointer"
            case .failedToTakeOwnership: return "failed_to_take_ownership"
            case .failedToPrefaultIOSurface: return "failed_to_prefault_iosurface"
            case .launchdMisconfiguration: return "launchd_misconfiguration"
            case .invalidStateTransition: return "invalid_state_transition"
            case .clientNotYetConnected: return "client_not_connected"
            case .invalidFollowerToken: return "invalid_follower_token"
            case .unexpectedError: return "unexpected_error"
            case .externalError: return "external_error"
            case .ensemblePorterError: return "ensembleporter_error"
            case .invalidTurnNumber: return "invalid_turn_number"
            case .failedToGenerateRandomBytes: return "failed_to_generate_random_bytes"
            case .unimplemented: return "unimplemented"
            case .ioSurfaceDataMismatch: return "iosurface_data_mismatch"
            case .invalidStartMessage: return "invalid_start_message"
            case .ensembleTransportUnavailable: return "ensemble_transport_unavailable"
            case .ensembleTransportError(let failure):
                return "ensemblewarden_ensembletransport_\(failure.metricsLabel)"

            // Keys
            case .ensemblePorterHandleNotSupplied: return "key_not_supplied"
            case .keyIDNotSupplied: return "key_not_supplied"
            case .keyIDSuppliedTwice: return "key_supplied_twice"
            case .keyAlreadyFetched: return "key_already_fetched"

            // Crypto
            case .invalidSealedBox: return "invalid_sealed_box"
            case .failedToGenerateIOSurface: return "failed_to_generate_iosurface"
            case .invalidIOSurfaceRange: return "invalid_iosurface_range"
            }
        }
        return "other"
    }
}

fileprivate extension EnsembleTransportFailure {
    /// Snake-case suffix for the `error_category` dimension, appended to
    /// `ensemblewarden_ensembletransport_`. Spelled out rather than derived from `rawValue` so
    /// the wire name and the metric name can change independently.
    ///
    /// Every value here must also be listed under the `error_category` dimension of
    /// `ensemblewarden_xpccalls_duration_seconds` and `ensemblewarden_crypto_operations_seconds`
    /// in `logauditlists/metrics/ensemblewardend.json`. `CloudMetrics.MetricsFilter` drops the
    /// *whole sample* on an unaudited dimension value, not just the dimension, so a missing entry
    /// would silently erase these errors from the success-rate metric. The client-side lists in
    /// `logauditlists/metrics/tie-*.json` leave `error_category` empty, which that filter treats
    /// as unrestricted, so they need no change.
    var metricsLabel: String {
        switch self {
        case .disconnected: "disconnected"
        case .publishFailed: "publish_failed"
        case .duplicateObject: "duplicate_object"
        case .invalidSurface: "invalid_surface"
        case .tooLarge: "too_large"
        case .deleteFailed: "delete_failed"
        case .unexpectedResponse: "unexpected_response"
        case .unknown: "unknown"
        }
    }
}
