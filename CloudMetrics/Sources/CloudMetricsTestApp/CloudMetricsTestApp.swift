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

// swiftlint:disable file_header
//
//  CloudMetricsTestApp.swift
//  CloudMetricsTestApp
//
//  Created by Andrea Guzzo on 09/22/22.
//  Copyright © 2022 Apple Inc. All rights reserved.
//

import ArgumentParserInternal
@_exported import CloudMetricsFramework
import Darwin
import PrometheusParser

@main
package struct CloudMetricsdTestCommand: AsyncParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "cloudmetricstest",
        abstract: "Test tool for CloudMetrics",
        discussion: """
        """
    )

    @Option(help: "Path to a file containing prometheus data dump.")
    internal var prometheusData: String?

    @Option(help: "Countinuosly increment a counter named as specified here.")
    internal var continuousCounter: String?

    @Option(help: """
    How frequently to update the metric (in seconds) \
    when '--continuous-counter' or '--continuous-histogram' has bee passed.
    """)
    internal var updateFrequency: Int = 1

    @Option(help: "How much to increment the counter when '--continuous-counter' has bee passed.")
    internal var incrementStep: UInt64 = 1

    @Option(help: "")
    internal var continousHistogram: String?

    @Option(help: "")
    internal var longLived: Bool = false

    @Option(help: """
    Record a histogram with AggregateOnNode using the given label. \
    Uses --aggregate-histogram-bounds to define bucket boundaries (default: single bound 1.0). \
    See --aggregate-histogram-bounds and --bucket-probabilities for configuration.
    """)
    internal var aggregateHistogram: String?

    @Option(help: """
    Probability of recording a blocked event (2.0) vs non-blocked (0.0) for --aggregate-histogram \
    when using the default single-bound binary histogram. Range 0.0–1.0. Default 0.5. \
    Ignored when --bucket-probabilities is set.
    """)
    internal var blockProbability: Double = 0.5

    @Option(help: "Number of values to record for --aggregate-histogram, then exit. 0 = run forever.")
    internal var aggregateHistogramCount: Int = 0

    @Option(help: """
    Comma-separated histogram bounds for --aggregate-histogram (e.g. '1.0,2.0,3.0'). \
    Defaults to '1.0' (binary histogram: bucket[le=1.0]=non-blocked, bucket[gt=1.0]=blocked). \
    Produces N+1 buckets for N bounds. Sentinel values recorded per bucket: \
    0.0 for bucket[0], midpoint of adjacent bounds for intermediate buckets, lastBound*2 for overflow.
    """)
    internal var aggregateHistogramBounds: String?

    @Option(help: """
    Comma-separated per-bucket probabilities for --aggregate-histogram (N+1 values for N bounds, \
    should sum to 1.0). Controls how likely each bucket is to receive an event. \
    Example for 3 bounds: '0.5,0.2,0.2,0.1'. \
    Defaults to uniform distribution for multi-bucket; uses --block-probability for binary histogram.
    """)
    internal var bucketProbabilities: String?

    package init() {}

    internal static func relayPrometheusMetrics(filepath: String) throws {
        let content = try String(contentsOfFile: filepath, encoding: .utf8)
        CloudMetrics.publishPrometheusMetrics(content: content)
        print("Completed")
    }

    package func run() async throws {
        // Setup the CloudMetrics backend.
        CloudMetrics.bootstrap()
        if let prometheusDataFile = self.prometheusData {
            try CloudMetricsdTestCommand.relayPrometheusMetrics(filepath: prometheusDataFile)
            return
        } else if let continuousCounterName = self.continuousCounter {
            // No arguments passed, run the generic test
            let counter = Counter(label: continuousCounterName)
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + .seconds(self.updateFrequency), repeating: .seconds(self.updateFrequency))
            timer.setEventHandler {
                counter.increment(by: self.incrementStep)
            }
            timer.activate()
            return await withUnsafeContinuation { _ in }
        } else if let continuousHistogramName = self.continousHistogram {
            let histogram = try Histogram(
                label: continuousHistogramName,
                dimensions: [("dim1", "val1"), ("dim2", "val2")],
                buckets: [0.5, 9.5, 25.0, 50.0, 75.0, 90.0]
            )
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + .seconds(self.updateFrequency), repeating: .seconds(self.updateFrequency))
            timer.setEventHandler {
                histogram.record(Double.random(in: 0.0 ..< 100.0))
            }
            timer.activate()
            return await withUnsafeContinuation { _ in }
        } else if let aggregateHistogramLabel = self.aggregateHistogram {
            try await self.runAggregateHistogramTest(label: aggregateHistogramLabel)
            return
        } else {
            try self.runTest()
        }

        if self.longLived {
            while true {}
        }
    }

    internal func runAggregateHistogramTest(label: String) async throws {
        // Parse bounds: default [1.0] for binary histogram backward compat.
        let bounds: [Double]
        if let boundsStr = self.aggregateHistogramBounds {
            let parsed = boundsStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard !parsed.isEmpty else {
                print("Error: --aggregate-histogram-bounds must be non-empty")
                return
            }
            bounds = parsed
        } else {
            bounds = [1.0]
        }

        let bucketCount = bounds.count + 1

        // Compute sentinel values: 0.0 for bucket[0], midpoint for intermediate, lastBound*2 for overflow.
        // For the default binary case [1.0] this produces [0.0, 2.0] — identical to the original behaviour.
        var sentinels: [Double] = [0.0]
        for i in 0..<(bounds.count - 1) {
            sentinels.append((bounds[i] + bounds[i + 1]) / 2.0)
        }
        sentinels.append(bounds[bounds.count - 1] * 2.0)

        // Parse per-bucket probabilities. Fall back to blockProbability for binary, uniform for multi-bucket.
        let probs: [Double]
        if let probStr = self.bucketProbabilities {
            let parsed = probStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parsed.count == bucketCount else {
                print("Error: --bucket-probabilities needs \(bucketCount) values for \(bounds.count) bounds, got \(parsed.count)")
                return
            }
            let total = parsed.reduce(0, +)
            if abs(total - 1.0) > 0.01 {
                print("Warning: --bucket-probabilities sum is \(total), expected 1.0")
            }
            probs = parsed
        } else if bounds == [1.0] {
            // Binary histogram backward compat: blockProbability drives the two-bucket split.
            probs = [1.0 - self.blockProbability, self.blockProbability]
        } else {
            // Multi-bucket default: uniform across all buckets.
            let uniform = 1.0 / Double(bucketCount)
            probs = Array(repeating: uniform, count: bucketCount)
        }

        // Bucket label strings for print output, e.g. "le=1.0", "le=2.0", "gt=3.0".
        var bucketLabels: [String] = bounds.map { "le=\($0)" }
        bucketLabels.append("gt=\(bounds[bounds.count - 1])")

        let histogram = try Histogram(label: label, dimensions: [], buckets: bounds)
        var sent = 0
        var bucketCounts = Array(repeating: 0, count: bucketCount)
        let total = self.aggregateHistogramCount

        let timer = DispatchSource.makeTimerSource()
        timer.schedule(
            deadline: .now() + .seconds(self.updateFrequency),
            repeating: .seconds(self.updateFrequency)
        )
        timer.setEventHandler {
            guard total == 0 || sent < total else {
                timer.cancel()
                return
            }
            // Pick a bucket index according to the probability distribution.
            let bucketIndex = Self.pickBucket(probs: probs)
            let value = sentinels[bucketIndex]
            histogram.record(value)
            sent += 1
            bucketCounts[bucketIndex] += 1

            let sum = zip(sentinels, bucketCounts).map { $0 * Double($1) }.reduce(0, +)
            print("#\(sent)  bucket=\(bucketIndex)(\(bucketLabels[bucketIndex]))  value=\(value)  counts=\(bucketCounts)")
            if sent % 5 == 0 {
                let bucketStr = zip(bucketLabels, bucketCounts).map { "\($0.0):\($0.1)" }.joined(separator: "  ")
                print("  → Expected in Mosaic: count=\(sent) sum=\(sum)  \(bucketStr)")
            }
        }
        timer.activate()

        if total > 0 {
            while sent < total {
                try await Task.sleep(for: .milliseconds(200))
            }
            let sum = zip(sentinels, bucketCounts).map { $0 * Double($1) }.reduce(0, +)
            let bucketStr = zip(bucketLabels, bucketCounts).map { "\($0.0):\($0.1)" }.joined(separator: "  ")
            print("\nAll \(total) values recorded. counts=\(bucketCounts)")
            print("Waiting 65s for final publish to Mosaic...")
            try await Task.sleep(for: .seconds(65))
            print("Done. Verify in Mosaic: count=\(sent) sum=\(sum)  \(bucketStr)")
        } else {
            return await withUnsafeContinuation { _ in }
        }
    }

    // Picks a bucket index by sampling the cumulative probability distribution.
    private static func pickBucket(probs: [Double]) -> Int {
        let r = Double.random(in: 0..<1)
        var cumulative = 0.0
        for (i, p) in probs.enumerated() {
            cumulative += p
            if r < cumulative { return i }
        }
        return probs.count - 1
    }

    internal func runTest() throws {
        let gauge = Gauge(label: "exampleGauge")
        gauge.record(Double(5))

        // No arguments passed, run the generic test
        let counter = Counter(
            label: "exampleCounter",
            dimensions: [("dim1", "val1"), ("dim2", "val2")]
        )

        print("Make our counter start from 5\n")
        counter.reset(value: 5)

        print("Incrementing counter\n")
        counter.increment(by: 1)

        let floatingPointCounter = FloatingPointCounter(
            label: "exampleFloatingPointCounter",
            dimensions: [("dim1", "val1"), ("dim2", "val2")]
        )
        print("Make our counter start from 7.5\n")
        floatingPointCounter.reset(value: 7.5)

        print("Incrementing counter\n")
        floatingPointCounter.increment(by: 1.5)

        let histogram = try Histogram(
            label: "exampleHistogram",
            dimensions: [("dim1", "val1"), ("dim2", "val2")],
            buckets: [0.5, 9.5, 25.0, 50.0, 75.0, 90.0]
        )
    }
}
