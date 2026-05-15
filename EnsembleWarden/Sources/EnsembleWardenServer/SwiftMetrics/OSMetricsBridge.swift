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
//  OSMetricsBridge.swift
//  EnsembleWarden
//
// Originally created by Oliver Chick
// Modified by Carolina Cassedy on 7/23/25.
//

@_spi(OSMetric) private import os

/// This code bridges SwiftMetrics to OSMetrics so that OSMetrics can be used
/// as a backend for code
final package class OSMetricsBridge: MetricsFactory, Sendable {
    package let globalLabels: [String: String] = [:]
    /// These histogram buckets are somewhat application specific and reflect expected operation durations
    private let defaultTimeHistogramBuckets: [Double] =  [
        0.1, 0.2, 0.3, 0.4, 0.5,
        0.6, 0.7, 0.8, 0.9,

        1.0, 2.0, 3.0, 4.0, 5.0,
        6.0, 7.0, 8.0, 9.0,

        10.0, 20.0, 30.0, 40.0, 50.0,
        60.0, 70.0, 80.0, 90.0, 100.0,
        200.0, 300.0, 400.0, 500.0, 600.0,
        700.0, 800.0, 900.0,

        1000.0, 2000.0, 3000.0, 4000.0, 5000.0,
        6000.0, 7000.0, 8000.0, 9000.0,

        10000.0, 20000.0, 30000.0
    ]

    package init(){}

    package func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        let finalDimensions = dimensions + globalLabels
        let counter = OSMetricCounter(
            type: UInt64.self,
            label: label,
            extraDimensions: OSMetricDimensions(values: finalDimensions)
        )
        let counterWrapper = OSMetricCounterWrapper(counter: counter)
        return OSMetricsCounterHandler(counterWrapper: counterWrapper)
    }

    final class OSMetricCounterWrapper: Sendable {
        private let counter: OSMetricCounter<UInt64>
        fileprivate init(counter: OSMetricCounter<UInt64>) {
            self.counter = counter
        }

        func increment(by amount: UInt64) {
            counter.add(amount)
        }

        func reset() {
            counter.reset()
        }

        fileprivate func getCounter() -> OSMetricCounter<UInt64> {
            return counter
        }
    }

    final class OSMetricsCounterHandler: CounterHandler {
        private let counterWrapper: OSMetricCounterWrapper

        fileprivate init(counterWrapper: OSMetricCounterWrapper) {
            self.counterWrapper = counterWrapper
        }

        func increment(by amount: Int64) {
            counterWrapper.increment(by: UInt64(amount))
        }

        func reset() {
            counterWrapper.reset()
        }
    }

    protocol HistogramProtocol: Sendable {
        func record(_ value: Int64)
        func record(_ value: Double)
        func reset()
    }

    final class OSMetricHistogramWrapper: HistogramProtocol {
        private let histogram: OSMetricHistogram<Double>

        fileprivate init(histogram: OSMetricHistogram<Double>) {
            self.histogram = histogram
        }

        func record(_ value: Int64) {
            histogram.set(Double(value))
        }

        func record(_ value: Double) {
            histogram.set(value)
        }

        func reset() {
            histogram.reset()
        }
    }

    final class OSMetricGaugeWrapper: Sendable {
        private let gauge: OSMetricGauge<Double>

        fileprivate init(gauge: OSMetricGauge<Double>) {
            self.gauge = gauge
        }

        func set(_ value: Double) {
            gauge.set(value)
        }

        func increment(by amount: Double) {
            // OSMetricGauge doesn't have increment, so unable to implement
        }

        func decrement(by amount: Double) {
            // OSMetricGauge doesn't have decrement, so unable to implement
        }

        func reset() {
            gauge.reset()
        }
    }

    package func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        let finalDimensions = dimensions + globalLabels

        let gauge = OSMetricGauge(
            type: Double.self,
            label: label,
            extraDimensions: OSMetricDimensions(values: finalDimensions)
        )

        let gaugeWrapper = OSMetricGaugeWrapper(gauge: gauge)
        return OSMetricsGaugeHandler(gaugeWrapper: gaugeWrapper)
    }

    final class OSMetricsGaugeHandler: MeterHandler {
        private let gaugeWrapper: OSMetricGaugeWrapper

        fileprivate init(gaugeWrapper: OSMetricGaugeWrapper) {
            self.gaugeWrapper = gaugeWrapper
        }

        func set(_ value: Int64) {
            gaugeWrapper.set(Double(value))
        }

        func set(_ value: Double) {
            gaugeWrapper.set(value)
        }

        func increment(by amount: Double) {
            gaugeWrapper.increment(by: amount)
        }

        func decrement(by amount: Double) {
            gaugeWrapper.decrement(by: amount)
        }
    }

    package func makeTimer(
        label: String,
        dimensions: [(String, String)]
    ) -> TimerHandler {
        let finalDimensions = dimensions + globalLabels

        let histogram = OSMetricHistogram(
                            type: Double.self, label: label,
                            extraDimensions: OSMetricDimensions(values: finalDimensions),
                            bins: .interval(count: 5, interval: 10))

        let histogramWrapper = OSMetricHistogramWrapper(histogram: histogram)

        return OSMetricsTimerHandler(histogram: histogramWrapper)
    }

    final class OSMetricsTimerHandler: TimerHandler {
        private let histogram: HistogramProtocol
        fileprivate init(histogram: HistogramProtocol) {
            self.histogram = histogram
        }

        func recordNanoseconds(_ duration: Int64) {
            histogram.record(duration)
        }
    }

    package func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> any RecorderHandler {
        let finalDimensions = dimensions + globalLabels
        let binType = OSMetricBinType.logarithmic(count: UInt8(defaultTimeHistogramBuckets.count))
        let histogram = OSMetricHistogram(type: Double.self, label: label, extraDimensions: OSMetricDimensions(values: finalDimensions), bins: binType)

        let histogramWrapper = OSMetricHistogramWrapper(histogram: histogram)
        return OSMetricsValueHistogramHandler(histogram: histogramWrapper)
    }

    final class OSMetricsValueHistogramHandler: RecorderHandler {
        private let histogram: HistogramProtocol
        fileprivate init(histogram: HistogramProtocol) {
            self.histogram = histogram
        }

        func record(_ value: Int64) {
            histogram.record(value)
        }

        func record(_ value: Double) {
            histogram.record(value)
        }
    }


    package func destroyCounter(_ handler: any CounterHandler) {}
    package func destroyMeter(_ handler: any MeterHandler) {}
    package func destroyFloatingPointCounter(_: FloatingPointCounterHandler) {}
    package func destroyRecorder(_ handler: any RecorderHandler) {}
    package func destroyTimer(_ handler: any TimerHandler) {}
}
