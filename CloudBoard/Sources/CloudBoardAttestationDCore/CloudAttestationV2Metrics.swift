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

@preconcurrency import CloudMetricsFramework
import Metrics

/// Bootstraps swift-metrics' global `MetricsSystem` to route all `Metrics.Counter`/`Gauge`/etc.
/// instances through ``CloudMetricsBridge``. Must be called exactly once per process, before any
/// `Metrics` type is instantiated.
///
/// CloudAttestationV2 and its transitive dependencies create counters via `Metrics.Counter(label:)`.
/// Without a bootstrap those emissions go to the default no-op factory and are silently dropped;
/// after bootstrap they flow into the CloudMetrics pipeline.
public enum CloudAttestationV2Metrics {
    public static func bootstrap(globalLabels: [String: String]) {
        MetricsSystem.bootstrap(CloudMetricsBridge(globalLabels: globalLabels))
    }
}

/// This code bridges SwiftMetrics to CloudMetrics so that CloudMetrics can be used
/// as a backend for code that has an existing dependency on SwiftMetrics.
final class CloudMetricsBridge: Metrics.MetricsFactory, Sendable {
    let globalLabels: [String: String]
    private let defaultTimeHistogramBuckets: [Double] = [
        1, 5,
        10, 20, 30, 50, 70,
        100, 200, 500, 750,
        1000, 1250, 1500, 1750,
        2000, 2250, 2500,
        3000, 3500,
        4000, 4500,
        5000,
        6000,
    ].map { $0 * 1_000_000 } // durations are recorded in nanoseconds, but we are mainly interested in milliseconds
    private let timeHistogramBuckets: [String: [Double]]
    private let defaultValueHistogramBuckets: [Double] = MetricsHelper
        .makeExponentialBucketsArray(start: 1, factor: 2, count: 16)
    private let valueHistogramBuckets: [String: [Double]]

    init(
        globalLabels: [String: String],
        timeHistogramBuckets: [String: [Double]] = [:],
        valueHistogramBuckets: [String: [Double]] = [:]
    ) {
        self.globalLabels = globalLabels
        self.timeHistogramBuckets = timeHistogramBuckets
        self.valueHistogramBuckets = valueHistogramBuckets
    }

    func makeCounter(label: String, dimensions: [(String, String)]) -> Metrics.CounterHandler {
        let counter = CloudMetricsFramework.Counter(
            label: label,
            dimensions: dimensions + self.globalLabels
        )
        return CloudMetricsCounterHandler(counter: counter)
    }

    func makeFloatingPointCounter(
        label: String,
        dimensions: [(String, String)]
    ) -> Metrics.FloatingPointCounterHandler {
        let counter = CloudMetricsFramework.FloatingPointCounter(
            label: label,
            dimensions: dimensions + self.globalLabels
        )
        return CloudMetricsFloatingPointerCounterHandler(counter: counter)
    }

    func makeRecorder(
        label: String,
        dimensions: [(String, String)],
        aggregate: Bool
    ) -> Metrics.RecorderHandler {
        if aggregate {
            let buckets = self.valueHistogramBuckets[label] ?? self.defaultValueHistogramBuckets
            // We don't want to crash the app if this is mis-wired, hence the `try?` returning an optional histogram.
            // It will quietly swallow measurements if misconfigured
            let histogram = try? CloudMetricsFramework.Histogram(
                label: label,
                dimensions: dimensions + self.globalLabels,
                buckets: buckets
            )
            return CloudMetricsValueHistogramHandler(histogram: histogram)
        } else {
            let recorder = CloudMetricsFramework.Recorder(
                label: label,
                dimensions: dimensions + self.globalLabels,
                aggregate: aggregate
            )
            return CloudMetricsRecorderHandler(recorder: recorder)
        }
    }

    func makeTimer(
        label: String,
        dimensions: [(String, String)]
    ) -> Metrics.TimerHandler {
        // Back timers with a histogram rather than a CloudMetrics timer. Reason being that histogram supports buckets,
        // and doesn't just give a summary.
        let buckets = self.timeHistogramBuckets[label] ?? self.defaultTimeHistogramBuckets
        // We don't want to crash the app if this is mis-wired, hence the `try?` returning an optional histogram. It
        // will queitly swallow measurements if misconfigured
        let histogram = try? CloudMetricsFramework.Histogram(
            label: label,
            dimensions: dimensions + self.globalLabels,
            buckets: buckets
        )
        return CloudMetricsTimerHandler(histogram: histogram)
    }

    func destroyCounter(_: Metrics.CounterHandler) {}
    func destroyFloatingPointCounter(_: Metrics.FloatingPointCounterHandler) {}
    func destroyRecorder(_: Metrics.RecorderHandler) {}
    func destroyTimer(_: Metrics.TimerHandler) {}
}

private final class CloudMetricsCounterHandler: Metrics.CounterHandler {
    private let counter: CloudMetricsFramework.Counter
    fileprivate init(counter: CloudMetricsFramework.Counter) {
        self.counter = counter
    }

    func increment(by amount: Int64) {
        self.counter.increment(by: amount)
    }

    func reset() {
        self.counter.reset()
    }
}

private final class CloudMetricsFloatingPointerCounterHandler: Metrics.FloatingPointCounterHandler {
    private let counter: CloudMetricsFramework.FloatingPointCounter
    fileprivate init(counter: CloudMetricsFramework.FloatingPointCounter) {
        self.counter = counter
    }

    func increment(by amount: Double) {
        self.counter.increment(by: amount)
    }

    func reset() {
        self.counter.reset()
    }
}

private final class CloudMetricsTimerHandler: Metrics.TimerHandler {
    private let histogram: CloudMetricsFramework.Histogram?
    fileprivate init(histogram: CloudMetricsFramework.Histogram?) {
        self.histogram = histogram
    }

    func recordNanoseconds(_ duration: Int64) {
        self.histogram?.record(duration)
    }
}

private final class CloudMetricsValueHistogramHandler: Metrics.RecorderHandler {
    private let histogram: CloudMetricsFramework.Histogram?
    fileprivate init(histogram: CloudMetricsFramework.Histogram?) {
        self.histogram = histogram
    }

    func record(_ value: Int64) {
        self.histogram?.record(value)
    }

    func record(_ value: Double) {
        self.histogram?.record(value)
    }
}

private final class CloudMetricsRecorderHandler: Metrics.RecorderHandler {
    private let recorder: CloudMetricsFramework.Recorder
    fileprivate init(recorder: CloudMetricsFramework.Recorder) {
        self.recorder = recorder
    }

    func record(_ value: Int64) {
        self.recorder.record(value)
    }

    func record(_ value: Double) {
        self.recorder.record(value)
    }
}

enum MetricsHelper {
    /// Create exponential buckets used by Histograms
    ///
    ///  - Parameters:
    ///     - start: Start value for your buckets, should be larger than 0. This will be the upper bound of your
    ///     first bucket.
    ///     - factor: Factor to increase each upper bound by, based on the upper bound of the last bucket.
    ///     Should be larger than 1.
    ///     - count: Amount of buckets to generate, should be larger than zero. The +Inf bucket is not included
    ///     in this count.
    static func makeExponentialBucketsArray(start: Double, factor: Double, count: Int) -> [Double] {
        assert(count > 1, "Bucket.exponential needs a count greater than 1")
        assert(start > 0, "Bucket.exponential needs a start larger than 0")
        assert(factor > 1, "Bucket.exponential needs a factor larger than 1")
        var arr = [Double]()
        var intervalStart = start
        for _ in 0 ..< count {
            arr.append(intervalStart)
            intervalStart *= factor
        }
        return arr
    }
}
