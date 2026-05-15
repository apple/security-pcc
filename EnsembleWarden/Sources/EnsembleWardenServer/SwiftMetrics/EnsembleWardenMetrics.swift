// Copyright © 2025 Apple Inc. All Rights Reserved.

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
    package static let xpccallsTotal = "ensemblewarden_xpccalls_total"
    package static let xpccallsDuration = "ensemblewarden_xpccalls_duration_seconds"
    package static let clientCallsTotal = "ensemblewarden_client_calls_total"
    package static let clientCallsDuration = "ensemblewarden_client_calls_duration_seconds"
}

package enum EnsembleWardenMetricDimensions {
    package static let bundleDimensions = ("bundle", Bundle.main.bundleIdentifier ?? "<unknown>")
    package static let XPCPublishDimension = ("xpc_operation", "publish")
    package static let XPCStartDimension = ("xpc_operation", "start")
    package static let XPCFetchDimension = ("xpc_operation", "fetch")
    package static let XPCFinishDimension = ("xpc_operation", "finish")
    package static let successDimension = ("result", "success")
    package static let errorDimension = ("result", "error")
    package static let publishDimension = ("operation", "publish")
    package static let fetchDimension = ("operation", "fetch")
}


// Metric names should conform to
// https://prometheus.io/docs/practices/naming/
package struct EnsembleWardenMetrics<Factory: MetricsFactory> {

    private let logger = Logger(subsystem: "com.apple.cloudos.ensemblewarden", category: "Metrics")

    private var metricsFactory: MetricsFactory
    private var defaultDimensions: [(String,String)] = [("bundle", Bundle.main.bundleIdentifier ?? "<unknown>")]

    package var daemonLaunchTotalCount: CounterHandler
    package var launchdJobs: MeterHandler
    package var daemonUptime: RecorderHandler

    package init(metricsFactory: Factory) {
        self.metricsFactory = metricsFactory
        self.daemonLaunchTotalCount = metricsFactory.makeCounter(label: EnsembleWardenMetricLabels.daemonLaunchTotal, dimensions: defaultDimensions)
        self.launchdJobs = metricsFactory.makeMeter(label: EnsembleWardenMetricLabels.launchdActiveManagedJobs, dimensions: defaultDimensions)
        self.daemonUptime = metricsFactory.makeRecorder(label: EnsembleWardenMetricLabels.daemonUptime, dimensions: defaultDimensions, aggregate: false)
    }

    /// Runs a closure, expected to handle an XPC message, and reports metrics on if that closure succeeded.
    package func reportingXPCMetrics<T>(operationName: String, fn: () async throws -> T) async rethrows -> T {
        let counterLabel = EnsembleWardenMetricLabels.xpccallsTotal
        let timerLabel = EnsembleWardenMetricLabels.xpccallsDuration
        let start = Date()
        var dimensions: [(String, String)] = [
            ("bundle", Bundle.main.bundleIdentifier ?? "<unknown>"),
            ("xpc_operation", operationName)
        ]

        defer {
            let processingTime = Date().timeIntervalSince(start)
            self.metricsFactory.makeCounter(label: counterLabel, dimensions: dimensions).increment(by: 1)
            self.metricsFactory.makeRecorder(label: timerLabel, dimensions: dimensions, aggregate: false).record(processingTime*1000)
        }

        do {
            let result = try await fn()
            dimensions.append(("result", "success"))
            return result
        } catch {
            self.logger.error("""
                Operation failed with error. \
                operation_name=\(operationName, privacy: .public) \
                error=\(String(reportable: error), privacy: .public)
                """)
            dimensions.append(("result", "error"))
            throw error
        }
    }

    /// Runs a closure, expected to be a client operation, and reports metrics on if that closure succeeded.
    package func reportingClientMetrics<T>(operationName: String, fn: () async throws -> T) async rethrows -> T {
        let counterLabel = EnsembleWardenMetricLabels.clientCallsTotal
        let timerLabel = EnsembleWardenMetricLabels.clientCallsDuration
        let start = Date()

        var dimensions: [(String, String)] = [
            ("operation", operationName),
            EnsembleWardenMetricDimensions.bundleDimensions
        ]

        defer {
            let processingTime = Date().timeIntervalSince(start)
            self.metricsFactory.makeCounter(label: counterLabel, dimensions: dimensions).increment(by: 1)
            self.metricsFactory.makeRecorder(label: timerLabel, dimensions: dimensions, aggregate: false).record(processingTime*1000)
        }

        do {
            let result = try await fn()
            dimensions.append(EnsembleWardenMetricDimensions.successDimension)
            return result
        } catch {
            dimensions.append(EnsembleWardenMetricDimensions.errorDimension)
            throw error
        }
    }
}
