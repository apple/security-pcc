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
//  Transformer.swift
//  PrometheusParser
//
//  Created by Marco Magdy on 8/22/23.
//

internal import CloudMetricsConstants
import Foundation
import os
import PrometheusParser

extension Double {
    internal func toSafeInt() -> Int? {
        if self > Double(Int.max) || self < Double(Int.min) {
            return nil
        }
        return Int(self)
    }
}

private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "PrometheusTransformer")

// swiftlint:disable cyclomatic_complexity
// swiftlint:disable function_body_length
// swiftlint:disable force_unwrapping

extension CloudMetrics {
    // Parses prometheus text-formatted metrics, does the necessary translation to
    // cloudmetrics data-types and finally publishes them.
    public static func publishPrometheusMetrics(content: String) {
        let blocks = parseByBlock(input: content)
        logger.info("Found blocks in file. num_blocks=\(blocks.count)")
        for block in blocks {
            publishPrometheusBlocks(block: block)
        }
    }
}

private func publishPrometheusBlocks(block: PromMetricBlock) {
    switch block {
    case let .counter(promCounters):
        for currentCounter in promCounters {
            let dims = extractDimensions(labels: currentCounter.labels)
            let counter = FloatingPointCounter(label: currentCounter.name, dimensions: dims)
            counter.reset(value: currentCounter.value)
        }
        logger.info("Published counters to cloudmetrics. num_metrics=\(promCounters.count)")
    case let .gauge(promGauges):
        for currentGauge in promGauges {
            let dims = extractDimensions(labels: currentGauge.labels)
            let gauge = Gauge(label: currentGauge.name, dimensions: dims)
            gauge.record(currentGauge.value)
        }
        logger.info("Published gauges to cloudmetrics. num_metrics=\(promGauges.count)")
    case let .histogram(promHistogram):
        guard promHistogram.buckets.first != nil else {
            // Histogram should always have at least 1 bucket
            break
        }

        guard let buckets = extractBucketNamesAndValues(promHistogram.buckets) else {
            break
        }

        logger.debug("""
            Creating a cloudmetrics histogram. \
            metric_name=\(promHistogram.name, privacy: .private) \
            metric_value=\(promHistogram.count.value) \
            metric_sum=\(promHistogram.sum.value)
            """)
        let histogram = try? Histogram(label: promHistogram.name,
                                       dimensions: buckets.dimensions,
                                       buckets: buckets.names)
        guard let count = promHistogram.count.value.toSafeInt() else {
            logger.error("""
                Histogram has a count that is not a valid Swift Int. \
                metric_name=\(promHistogram.name, privacy: .private)
                """)
            break
        }
        histogram?.record(bucketValues: buckets.values, sum: promHistogram.sum.value, count: count)
        logger.debug("Published histogram. buckets_values=\(buckets.values.count)")
    case let .summary(promSummary):
        guard promSummary.buckets.first != nil else {
            // Summary should have at least 1 quantile
            logger.error("Encounterd a Summary block with ZERO quantiles")
            break
        }

        guard let quantiles = extractQuantileNamesAndValues(promSummary.buckets) else {
            break
        }

        logger.debug("""
            Creating a cloudmetrics Summary. \
            metric_name=\(promSummary.name, privacy: .private) \
            metric_value=\(promSummary.count.value) \
            num_metric_quantiles=\(quantiles.values.count)
            """)
        let summary = try? Summary(label: promSummary.name,
                                   dimensions: quantiles.dimensions,
                                   quantiles: quantiles.names)
        guard let count = promSummary.count.value.toSafeInt() else {
            logger.error("Summary \(promSummary.name) has a count that is not a valid Swift Int.")
            break
        }
        summary?.record(quantileValues: quantiles.values, sum: promSummary.sum.value, count: count)
    @unknown default:
        fatalError("Unknown type of prometheus block")
    }
}

private func extractDimensions(labels: [PromLabel]) -> [(String, String)] {
    extractDimensions(labels: labels, excludeLabel: nil)
}

private func extractDimensions(labels: [PromLabel], excludeLabel: String?) -> [(String, String)] {
    labels.filter { label in
        label.name != excludeLabel
    }
    .map { label in
        (label.name, label.value)
    }
}

// Extracts the values of the "quantile" label and convert them to Double
// If the values are not convertible to Double or the label "quantile" does not exist, return nil
private func extractQuantileNamesAndValues(_ metrics: [PromMetric]) -> Quantiles? {
    var names = [Double]()
    var values = [Double]()
    for line in metrics {
        let quantileLabel = line.labels.first { label in
            label.name == "quantile"
        }

        guard let quantile = quantileLabel else {
            logger.error("Failed to find a metric with label 'quantile'. Invalid prometheus summary.")
            return nil
        }

        guard let name = Double(quantile.value) else {
            logger.error("""
                Failed to convert the value of the 'quantile' metric to a Double. \
                metric_value=\(quantile.value)
                """)
            return nil
        }

        names.append(name)
        values.append(line.value)
    }

    let dimensions = metrics.isEmpty ? [(String, String)]() : extractDimensions(labels: metrics.first!.labels,
                                                                                excludeLabel: "quantile")
    return Quantiles(names: names, values: values, dimensions: dimensions)
}

private  func extractBucketNamesAndValues(_ buckets: [PromMetric]) -> Buckets? {
    var names = [Double]()
    var values = [Int]()
    for line in buckets {
        let leLabel = line.labels.first { label in
            label.name == "le"
        }
        guard let leLabel = leLabel else {
            logger.error("Bucket with label 'le' is not found. Invalid prometheus histogram.")
            return nil
        }

        guard let name = Double(leLabel.value) else {
            logger.error("""
                Failed to convert the value of the 'le' bucket to a Double. \
                metric_value=\(leLabel.value)
                """)
            return nil
        }

        names.append(name)
        guard let value = line.value.toSafeInt() else {
            logger.error("""
                Value of histogram cannot be represented as a Swift Int. \
                metric_name=\(line.name) \
                bucket=\(leLabel.value)
                """)
            return nil
        }
        values.append(value)
    }
    let dimensions = buckets.isEmpty ? [(String, String)]() : extractDimensions(labels: buckets.first!.labels,
                                                                                excludeLabel: "le")
    return Buckets(names: names, values: values, dimensions: dimensions)
}

private struct Buckets {
    let names: [Double]
    let values: [Int]
    let dimensions: [(String, String)] // The dimensions should be the same between the different buckets
}

private struct Quantiles {
    let names: [Double]
    let values: [Double]
    let dimensions: [(String, String)] // The dimensions should be the same between the different quantiles
}
