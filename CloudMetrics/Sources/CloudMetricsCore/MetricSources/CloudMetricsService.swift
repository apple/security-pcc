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
//  CloudMetricsService.swift
//  CloudMetricsCore
//
//  Created by Andrea Guzzo on 8/29/22.
//

internal import CloudMetricsConstants
internal import CloudMetricsXPC
import Foundation
internal import os

// swiftlint:disable function_parameter_count
internal final class CloudMetricsService: CloudMetricsServerProtocol, Sendable {
    private let metricsStoreProvider: MetricsStoreProvider
    private let metricsFilter: MetricsFilter
    private static let debugMetricPrefixes: OSAllocatedUnfairLock<[String]?> = .init(initialState: nil)
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "CloudMetricsService")

    internal init(
        metricsStoreProvider: MetricsStoreProvider,
        metricsFilter: MetricsFilter
    ) {
        self.metricsFilter = metricsFilter
        self.metricsStoreProvider = metricsStoreProvider
    }

    internal func setConfiguration(_ configuration: CloudMetricsConfigurationDictionary, client: MetricsClient) throws {
        self.logger.log("""
        setConfiguration. \
        client=\(client.name, privacy: .public) \
        overrides=\(configuration.overrides, privacy: .private)
        """)
        let store = self.metricsStoreProvider[client]
        for (id, override) in configuration.overrides {
            try store.configureMetric(
                label: id.label,
                dimensions: id.dimensions,
                step: 10,
                override: override
            )
        }
    }

    internal func incrementCounter(
        _ counter: CloudMetricsCounter,
        by amount: Int64,
        epoch: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: counter, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(
            metric: counter,
            message: "incrementCounter",
            value: "\(amount)",
            client: client,
            logger: self.logger
        )
        try self.metricsStoreProvider[client].counterIncrement(
            label: counter.label,
            dimensions: counter.dimensions,
            step: 10,
            by: amount,
            timestamp: Date(timeIntervalSince1970: epoch)
        )
    }

    internal func incrementCounter(
        _ counter: CloudMetricsCounter,
        by amount: Double,
        epoch: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: counter, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(
            metric: counter,
            message: "incrementCounter",
            value: "\(amount)",
            client: client,
            logger: self.logger
        )
        try self.metricsStoreProvider[client].counterIncrement(
            label: counter.label,
            dimensions: counter.dimensions,
            step: 10,
            by: amount,
            timestamp: Date(timeIntervalSince1970: epoch)
        )
    }

    internal func resetCounter(_ counter: CloudMetricsCounter, epoch _: Double, client: MetricsClient) throws {
        if !self.metricsFilter.shouldRecord(metric: counter, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(metric: counter, message: "resetCounter", value: "", client: client, logger: self.logger)
        try self.metricsStoreProvider[client].counterReset(
            label: counter.label,
            dimensions: counter.dimensions,
            initialValue: 0.0
        )
    }

    internal func recordInteger(
        recorder: CloudMetricsRecorder,
        value: Int64,
        epoch: Double,
        client: MetricsClient
    ) throws {
        try self.recordDouble(recorder: recorder, value: Double(value), epoch: epoch, client: client)
    }

    internal func recordDouble(
        recorder: CloudMetricsRecorder,
        value: Double,
        epoch: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: recorder, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(
            metric: recorder,
            message: "recordDouble",
            value: "\(value)",
            client: client,
            logger: self.logger
        )
        if recorder.aggregate {
            try self.metricsStoreProvider[client].recorderSet(
                label: recorder.label,
                dimensions: recorder.dimensions,
                step: 10,
                value: Double(value),
                timestamp: Date(timeIntervalSince1970: epoch)
            )
        } else {
            try self.metricsStoreProvider[client].gaugeSet(
                label: recorder.label,
                dimensions: recorder.dimensions,
                step: 10,
                value: Double(value),
                timestamp: Date(timeIntervalSince1970: epoch)
            )
        }
    }

    internal func recordNanoseconds(
        timer: CloudMetricsTimer,
        duration: Int64,
        epoch: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: timer, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(
            metric: timer,
            message: "recordNanoseconds",
            value: "\(duration)",
            client: client,
            logger: self.logger
        )
        try self.metricsStoreProvider[client].recorderSet(
            label: timer.label,
            dimensions: timer.dimensions,
            step: 10,
            value: Double(duration),
            timestamp: Date(timeIntervalSince1970: epoch)
        )
    }

    internal func resetCounter(
        _ counter: CloudMetricsCounter,
        initialValue: Double,
        epoch _: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: counter, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(metric: counter, message: "resetCounter", value: "", client: client, logger: self.logger)
        try self.metricsStoreProvider[client].counterReset(
            label: counter.label,
            dimensions: counter.dimensions,
            initialValue: initialValue
        )
    }

    internal func resetCounter(
        _ counter: CloudMetricsCounter,
        initialValue: Int64,
        epoch _: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: counter, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(metric: counter, message: "resetCounter", value: "", client: client, logger: self.logger)

        try self.metricsStoreProvider[client].counterReset(
            label: counter.label,
            dimensions: counter.dimensions,
            initialValue: Double(initialValue)
        )
    }

    internal func recordInteger(
        histogram: CloudMetricsHistogram,
        buckets: [Double],
        value: Int64,
        epoch: Double,
        client: MetricsClient
    ) throws {
        try self.recordDouble(
            histogram: histogram,
            buckets: buckets,
            value: Double(value),
            epoch: epoch,
            client: client
        )
    }

    internal func recordDouble(
        histogram: CloudMetricsHistogram,
        buckets: [Double],
        value: Double,
        epoch: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: histogram, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(
            metric: histogram,
            message: "recordDouble (histogram)",
            value: "\(value)",
            client: client,
            logger: self.logger
        )

        try self.metricsStoreProvider[client].histogramSet(
            label: histogram.label,
            dimensions: histogram.dimensions,
            step: 10,
            buckets: buckets,
            value: Double(value),
            timestamp: Date(timeIntervalSince1970: epoch)
        )
    }

    internal func recordBuckets(
        histogram: CloudMetricsHistogram,
        buckets: [Double],
        bucketValues: [Int],
        sum: Double,
        count: Int,
        epoch: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: histogram, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(
            metric: histogram,
            message: "recordBuckets",
            value: "buckets:\(buckets), values:\(bucketValues)",
            client: client,
            logger: self.logger
        )

        try self.metricsStoreProvider[client].histogramSetBuckets(
            label: histogram.label,
            dimensions: histogram.dimensions,
            step: 10,
            buckets: buckets,
            values: bucketValues,
            sum: sum,
            count: count,
            timestamp: Date(timeIntervalSince1970: epoch)
        )
    }

    internal func recordInteger(
        summary: CloudMetricsSummary,
        quantiles: [Double],
        value: Int64,
        epoch: Double,
        client: MetricsClient
    ) throws {
        self.debugMetric(
            metric: summary,
            message: "recordInteger",
            value: "\(value)",
            client: client,
            logger: self.logger
        )
        try self.recordDouble(
            summary: summary,
            quantiles: quantiles,
            value: Double(value),
            epoch: epoch,
            client: client
        )
    }

    internal func recordDouble(
        summary: CloudMetricsSummary,
        quantiles _: [Double],
        value: Double,
        epoch: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: summary, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(
            metric: summary,
            message: "recordDouble",
            value: "\(value)",
            client: client,
            logger: self.logger
        )
        try self.metricsStoreProvider[client].summarySet(
            label: summary.label,
            dimensions: summary.dimensions,
            step: 10,
            quantiles: summary.quantiles,
            value: Double(value),
            timestamp: Date(timeIntervalSince1970: epoch)
        )
    }

    internal func recordQuantiles(
        summary: CloudMetricsSummary,
        quantiles: [Double],
        quantileValues: [Double],
        sum: Double,
        count: Int,
        epoch: Double,
        client: MetricsClient
    ) throws {
        if !self.metricsFilter.shouldRecord(metric: summary, client: client) {
            throw CloudMetricsServiceError.metricNotAllowed
        }
        self.debugMetric(
            metric: summary,
            message: "recordQuantiles",
            value: "quantiles:\(quantiles), quantileValues:\(quantileValues)",
            client: client,
            logger: self.logger
        )
        try self.metricsStoreProvider[client].summarySetQuantiles(
            label: summary.label,
            dimensions: summary.dimensions,
            step: 10,
            quantiles: quantiles,
            values: quantileValues,
            sum: sum,
            count: count,
            timestamp: Date(timeIntervalSince1970: epoch)
        )
    }

    internal func clientConnected(client: MetricsClient) {
        self.metricsStoreProvider[client].clientConnected(client: client)
    }

    internal func clientDisconnected(client: MetricsClient) {
        self.metricsStoreProvider[client].clientDisconnected(client: client)
    }

    internal func getStoredCounter(
        label: String,
        client: MetricsClient,
        dimensions: [String: String]
    ) async throws -> CloudMetricsDoubleCounter? {
        self.metricsStoreProvider[client].getStoredCounter(label: label, dimensions: dimensions)
    }

    private static func debugMetricPrefixArray() -> [String] {
        self.debugMetricPrefixes.withLock { debugMetricPrefixes in
            if debugMetricPrefixes == nil {
                if let defaults = UserDefaults(suiteName: kCloudMetricsPreferenceDomain) {
                    let prefixes = defaults.stringArray(forKey: "DebugMetricPrefixes") ?? []
                    debugMetricPrefixes = prefixes
                    return prefixes
                }
            }
            return debugMetricPrefixes ?? []
        }
    }

    private func debugMetric(
        metric: CloudMetric,
        message: String,
        value: String,
        client: MetricsClient,
        logger: Logger
    ) {
        for debuggingPrefix in Self.debugMetricPrefixArray() where metric.label.hasPrefix(debuggingPrefix) {
            logger.info("""
            \(message) \
            client: \(client.name), \
            label: \(metric.label), \
            dimensions: \(metric.dimensions), \
            value: \(value).
            """)
        }
    }
}
