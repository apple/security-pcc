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

//  Copyright © 2025 Apple Inc. All rights reserved.

internal import CloudMetricsConstants
import Foundation
internal import os
@preconcurrency internal import OpenTelemetrySdk

/// Daemon-wide task that periodically collects and publishes aggregate metrics.
///
/// A single instance covers all (clientName, metricLabel) pairs that have `aggregateOnNode = true`.
/// On each tick it checks publish conditions per pair, pulls metrics from the isolated store via
/// `AggregateMetricReaderAdapter.collect()`, and yields them to the shared OTLP stream.
///
/// When `laplaceNoiseInjection` is configured for a metric, the Laplace noise path is used:
/// per-bucket threshold checks with thresh_noise, then per-bucket publish noise is applied at
/// publish time. The deterministic path (shouldCollect / minPublishCount) is used otherwise.
package final class AggregateReader: Sendable {
    private let storeProvider: AggregateStoreProvider
    private let metricsFilter: MetricsFilter
    private let metricDataContinuation: AsyncStream<CollectedMetricsData>.Continuation
    private let destination: Configuration.Destination
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "AggregateReader")

    package init(
        storeProvider: AggregateStoreProvider,
        metricsFilter: MetricsFilter,
        metricDataContinuation: AsyncStream<CollectedMetricsData>.Continuation,
        destination: Configuration.Destination
    ) {
        self.storeProvider = storeProvider
        self.metricsFilter = metricsFilter
        self.metricDataContinuation = metricDataContinuation
        self.destination = destination
    }

    /// Loops on the destination publish interval, triggering collect-and-publish on each tick.
    ///
    /// Exits when the enclosing Task is cancelled: `Task.sleep` throws `CancellationError`, which
    /// propagates out of `run()`. `defer` ensures the stop log is always emitted regardless of
    /// how the function exits.
    package func run() async throws {
        logger.log("Aggregate reader starting. interval=\(self.destination.publishInterval, privacy: .public)")
        defer { logger.log("Aggregate reader stopped") }
        while true {
            try await Task.sleep(for: destination.publishInterval)
            await collectAndPublish()
        }
    }

    /// Routes each registered (client, label) pair to the Laplace noise or deterministic publish path.
    ///
    /// Marked `async` so the caller can `await` it. `Task.yield()` suspends before doing any CPU
    /// work, giving the cooperative thread pool a chance to run other tasks first.
    private func collectAndPublish() async {
        await Task.yield()
        let allEntries = storeProvider.allEntries()
        for (key, entry) in allEntries {
            if let noiseConfig = metricsFilter.laplaceNoiseInjection(for: key.metricLabel, client: key.clientName) {
                collectAndPublishWithLaplaceNoise(key: key, entry: entry, noiseConfig: noiseConfig)
            } else {
                collectAndPublishDeterministic(key: key, entry: entry)
            }
        }
    }

    // MARK: - Laplace noise path

    /// Laplace noise publish path: per-bucket AboveThreshold check, then publish noise injected
    /// into each bucket count. Skips collect() entirely if any bucket threshold is not met,
    /// letting the OTEL delta store accumulate until the next tick.
    private func collectAndPublishWithLaplaceNoise(
        key: AggregateStoreProvider.Key,
        entry: AggregateStoreProvider.Entry,
        noiseConfig: Configuration.LaplaceNoiseInjection
    ) {
        // Gate 1: minimum publish interval must have elapsed
        guard metricsFilter.meetsPublishInterval(clientName: key.clientName, metricLabel: key.metricLabel) else {
            return
        }

        // Gate 2: per-bucket AboveThreshold check (CHANGEDv3).
        // thresh_noise is persistent across windows and is looked up (or lazily initialised) from
        // MetricsFilter state. count_noise is drawn fresh on every tick.
        for (i, bucketRule) in noiseConfig.buckets.enumerated() {
            let count = metricsFilter.bucketCount(metricLabel: key.metricLabel, clientName: key.clientName, bucket: i)
            let threshNoise = metricsFilter.threshNoise(metricLabel: key.metricLabel, clientName: key.clientName, bucket: i)
            let countNoise = laplaceRandom(scale: bucketRule.noiseSigmaCount)
            if Double(count) + countNoise < Double(bucketRule.minPublishCount) + threshNoise {
                // Hold — do NOT call collect(), the OTEL delta store accumulates naturally
                logger.debug("""
                Laplace threshold not met, holding. \
                client=\(key.clientName, privacy: .public) \
                label=\(key.metricLabel, privacy: .public) \
                bucket=\(i, privacy: .public) \
                count=\(count, privacy: .public)
                """)
                return
            }
        }

        // Collect from OTEL — this resets the delta store
        let metrics = entry.reader.collect()
        guard !metrics.isEmpty else { return }

        // Apply noise2 to histogram point data in place
        for metric in metrics {
            guard metric.type == .Histogram else { continue }
            guard let histData = metric.data as? HistogramData else { continue }
            for point in histData.points {
                guard let point = point as? HistogramPointData else { continue }

                // Validate bucket count alignment: N bounds → N+1 OTEL bucket_counts
                // noiseConfig.buckets[i] maps to point.counts[i]
                guard point.counts.count == noiseConfig.buckets.count else {
                    logger.error("""
                    Laplace noise bucket count mismatch, skipping point. \
                    client=\(key.clientName, privacy: .public) \
                    label=\(key.metricLabel, privacy: .public) \
                    pointCounts=\(point.counts.count, privacy: .public) \
                    configBuckets=\(noiseConfig.buckets.count, privacy: .public)
                    """)
                    // collect() has already drained the delta store above; call recordCollect so
                    // thresh_noise is resampled for the next epoch and bucket counts are reset.
                    metricsFilter.recordCollect(clientName: key.clientName, metricLabel: key.metricLabel)
                    return
                }

                // Apply noise2 to each bucket count; negative values are allowed
                for i in 0..<point.counts.count {
                    let noise2 = laplaceRandom(scale: noiseConfig.buckets[i].noiseSigmaPublish)
                    point.counts[i] = Int(Double(point.counts[i]) + noise2)
                }

                // Recompute total count from noisy per-bucket values (clamped to 0)
                point.count = UInt64(max(0, point.counts.reduce(0, +)))

                // Zero out min, max, and sum.
                // min/max reflect the range of pre-noise observed values and can reveal which
                // buckets were non-zero before noise was applied (rdar://179252661).
                // sum is separately correlated with the blocked count and consuming extra
                // privacy budget to noise it independently provides no additional aggregate value.
                point.sum = 0
                point.min = 0
                point.max = 0

                // Exemplars carry raw, unaggregated recorded values (one per bucket, via the
                // OTEL exemplar reservoir) and would leak exact pre-noise samples alongside the
                // noised bucket counts above. Clear them for the same reason sum/min/max are
                // zeroed (rdar://181711559).
                point.exemplars = []
            }
        }

        logger.debug("""
        Collected aggregate metrics (Laplace). \
        client=\(key.clientName, privacy: .public) \
        label=\(key.metricLabel, privacy: .public) \
        count=\(metrics.count, privacy: .public)
        """)

        let update = CollectedMetricsData(
            destination: destination,
            metrics: metrics,
            client: key.clientName
        )
        metricDataContinuation.yieldAndLogOnFailure(update)
        metricsFilter.recordCollect(clientName: key.clientName, metricLabel: key.metricLabel)
    }

    // MARK: - Deterministic path (original logic)

    /// Deterministic publish path: interval + total-count threshold with no noise.
    private func collectAndPublishDeterministic(
        key: AggregateStoreProvider.Key,
        entry: AggregateStoreProvider.Entry
    ) {
        guard metricsFilter.shouldCollect(clientName: key.clientName, metricLabel: key.metricLabel) else {
            return
        }
        let metrics = entry.reader.collect()
        guard !metrics.isEmpty else { return }

        logger.debug("""
        Collected aggregate metrics. \
        client=\(key.clientName, privacy: .public) \
        label=\(key.metricLabel, privacy: .public) \
        count=\(metrics.count, privacy: .public)
        """)

        let update = CollectedMetricsData(
            destination: destination,
            metrics: metrics,
            client: key.clientName
        )
        metricDataContinuation.yieldAndLogOnFailure(update)
        metricsFilter.recordCollect(clientName: key.clientName, metricLabel: key.metricLabel)
    }

    // MARK: - Laplace random

    /// Returns a zero-mean Laplace sample with the given scale using the inverse-CDF method.
    private func laplaceRandom(scale: Double) -> Double {
        guard scale > 0 else { return 0 }
        // U ~ Uniform(-0.5, 0.5); X = -b * sign(U) * ln(1 - 2|U|)
        let u = Double.random(in: (-0.5 + Double.ulpOfOne)..<0.5)
        return -scale * (u < 0 ? -1.0 : 1.0) * log(1.0 - 2.0 * abs(u))
    }
}
