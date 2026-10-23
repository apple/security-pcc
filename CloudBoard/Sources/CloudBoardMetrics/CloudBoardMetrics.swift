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

import CloudBoardLogging
import os

#if RC_IS_CLOUDOS_ENABLED
import CloudMetricsFramework
#elseif canImport(CloudMetricsFramework)
@_weakLinked import CloudMetricsFramework
#else
#warning("CloudMetricsFramework not available at compile time")
#endif

private let logger: os.Logger = .init(
    subsystem: "com.apple.cloudos.cloudboard",
    category: "cloudboardmetrics"
)

public let gaugeMetricPublishInterval: Duration = .seconds(30)
public let workloadParameterInferenceIDKey: String = "inference-id"

public struct MetricLabel: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension MetricLabel: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

public struct MetricDimensions<Key: RawRepresentable<String> & Hashable & Sendable>: Sendable {
    public var dimensions: [(Key, String)]
    public init(dimensions: [(Key, String)]) {
        self.dimensions = dimensions
    }

    public init() {
        self.dimensions = []
    }
}

extension MetricDimensions: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (Key, String)...) {
        self.dimensions = elements
    }
}

extension MetricDimensions {
    public mutating func append(_ value: String, forKey key: Key) {
        if self.dimensions.contains(where: { $0.0 == key }) {
            let dimensions = self.dimensions
            logger
                .fault(
                    "duplicate dimension key \(key.rawValue, privacy: .public). Given dimensions: \(dimensions, privacy: .public). New value: \(value, privacy: .public)"
                )
        }
        self.dimensions.append((key, value))
    }

    public consuming func appending(_ value: String, forKey key: Key) -> Self {
        self.append(value, forKey: key)
        return self
    }

    public mutating func append(_ pairs: some Sequence<(String, Key)>) {
        self.dimensions.reserveCapacity(self.dimensions.count + pairs.underestimatedCount)

        for (value, key) in pairs {
            self.append(value, forKey: key)
        }
    }

    public consuming func appending(_ pairs: some Sequence<(String, Key)>) -> Self {
        self.append(pairs)
        return self
    }
}

public enum NoDimensionKeys: RawRepresentable, Hashable, Sendable {
    public var rawValue: String { fatalError() }
    public init?(rawValue _: String) { return nil }
}

@frozen
public enum CounterAction: Hashable, Sendable {
    public static var increment: Self { .increment(by: 1) }
    public static var reset: Self { .reset(to: 0) }
    case increment(by: Int)
    case reset(to: Int64)
}

public protocol Counter: Sendable {
    associatedtype DimensionKey: RawRepresentable<String> & Hashable & Sendable = NoDimensionKeys
    static var label: MetricLabel { get }
    var dimensions: MetricDimensions<DimensionKey> { get }
    var action: CounterAction { get }
}

extension Counter where DimensionKey == NoDimensionKeys {
    public var dimensions: MetricDimensions<DimensionKey> { [:] }
}

@frozen
public enum GaugeValue: Hashable, Sendable {
    case integer(Int)
    case floatingPoint(Double)
}

public protocol GaugeValueConvertible: Sendable {
    init?(_ gaugeValue: GaugeValue)
    var gaugeValue: GaugeValue { get }
}

extension GaugeValue: GaugeValueConvertible {
    public init?(_ gaugeValue: GaugeValue) {
        self = gaugeValue
    }

    public var gaugeValue: GaugeValue {
        self
    }
}

extension Int: GaugeValueConvertible {
    public init?(_ gaugeValue: GaugeValue) {
        switch gaugeValue {
        case .integer(let int):
            self = int
        case .floatingPoint:
            return nil
        }
    }

    public var gaugeValue: GaugeValue { .integer(self) }
}

extension Double: GaugeValueConvertible {
    public init?(_ gaugeValue: GaugeValue) {
        switch gaugeValue {
        case .integer:
            return nil
        case .floatingPoint(let double):
            self = double
        }
    }

    public var gaugeValue: GaugeValue { .floatingPoint(self) }
}

public protocol Gauge: Sendable {
    associatedtype DimensionKey: RawRepresentable<String> & Hashable & Sendable = NoDimensionKeys
    associatedtype Value: GaugeValueConvertible & Hashable & Sendable = Double
    static var label: MetricLabel { get }
    var dimensions: MetricDimensions<DimensionKey> { get }
    var value: Value { get }
}

extension Gauge where DimensionKey == NoDimensionKeys {
    public var dimensions: MetricDimensions<DimensionKey> { [:] }
}

public struct HistogramBuckets: Hashable, Sendable {
    public var buckets: [Double]
    public init(buckets: [Double]) {
        self.buckets = buckets
    }
}

extension HistogramBuckets: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Double...) {
        self.buckets = elements
    }
}

public protocol HistogramValueConvertible {
    init?(_ histogramValue: HistogramValue)
    var histogramValue: HistogramValue { get }
}

@frozen
public enum HistogramValue: Hashable, Sendable {
    case integer(Int)
    case floatingPoint(Double)
}

extension HistogramValue: HistogramValueConvertible {
    public init?(_ histogramValue: HistogramValue) {
        self = histogramValue
    }

    public var histogramValue: HistogramValue {
        self
    }
}

extension Int: HistogramValueConvertible {
    public init?(_ histogramValue: HistogramValue) {
        switch histogramValue {
        case .integer(let int):
            self = int
        case .floatingPoint:
            return nil
        }
    }

    public var histogramValue: HistogramValue { .integer(self) }
}

extension Double: HistogramValueConvertible {
    public init?(_ histogramValue: HistogramValue) {
        switch histogramValue {
        case .integer:
            return nil
        case .floatingPoint(let double):
            self = double
        }
    }

    public var histogramValue: HistogramValue { .floatingPoint(self) }
}

public protocol Histogram: Sendable {
    associatedtype DimensionKey: RawRepresentable<String> & Hashable & Sendable = NoDimensionKeys
    associatedtype Value: HistogramValueConvertible & Hashable & Sendable = Double
    static var label: MetricLabel { get }
    static var buckets: HistogramBuckets { get }
    var dimensions: MetricDimensions<DimensionKey> { get }
    var value: Value { get }
}

extension Histogram where DimensionKey == NoDimensionKeys {
    public var dimensions: MetricDimensions<DimensionKey> { [:] }
}

public protocol CounterFactory<Input>: Sendable {
    associatedtype Input
    associatedtype Counter: CloudBoardMetrics.Counter

    func make(_ input: Input) -> Counter
}

public protocol GaugeFactory<Input> {
    associatedtype Input
    associatedtype Gauge: CloudBoardMetrics.Gauge

    func make(_ input: Input) -> Gauge
}

public protocol HistogramFactory<Input>: Sendable {
    associatedtype Input
    associatedtype Histogram: CloudBoardMetrics.Histogram

    consuming func make(_ input: Input) -> Histogram
}

public protocol DimensionKeysWithError {
    static var errorDescription: Self { get }
}

public enum DefaultErrorDimensionKeys: String, DimensionKeysWithError, RawRepresentable, Hashable, Sendable {
    case errorDescription
}

public protocol ErrorCounter: Counter {
    associatedtype DimensionKey: DimensionKeysWithError = DefaultErrorDimensionKeys
    associatedtype Factory: CounterFactory = ErrorCounterFactory<Self>
    init(dimensions: MetricDimensions<DimensionKey>, action: CounterAction)
}

public struct ErrorCounterFactory<Counter: ErrorCounter>: CounterFactory {
    public var action: CounterAction
    public var dimensions: MetricDimensions<Counter.DimensionKey>

    public init(action: CounterAction = .increment, dimensions: MetricDimensions<Counter.DimensionKey> = .init()) {
        self.action = action
        self.dimensions = dimensions
    }

    public consuming func make(_ error: any Error) -> Counter {
        .init(
            dimensions: self.dimensions.appending(String(reportable: error), forKey: .errorDescription),
            action: self.action
        )
    }
}

// Does this make sense for a Gauge?
public protocol ErrorGauge: Gauge {
    associatedtype DimensionKey: DimensionKeysWithError = DefaultErrorDimensionKeys
    associatedtype Factory: GaugeFactory = ErrorGaugeFactory<Self>
    init(value: Value, dimensions: MetricDimensions<DimensionKey>)
}

public struct ErrorGaugeFactory<Gauge: ErrorGauge>: GaugeFactory {
    public var value: Gauge.Value
    public var dimensions: MetricDimensions<Gauge.DimensionKey>

    public init(value: Gauge.Value, dimensions: MetricDimensions<Gauge.DimensionKey> = .init()) {
        self.value = value
        self.dimensions = dimensions
    }

    public consuming func make(_ error: any Error) -> Gauge {
        .init(
            value: self.value,
            dimensions: self.dimensions.appending(String(reportable: error), forKey: .errorDescription)
        )
    }
}

public protocol ErrorHistogram: Histogram {
    associatedtype DimensionKey: DimensionKeysWithError = DefaultErrorDimensionKeys
    associatedtype Factory: HistogramFactory = ErrorHistogramFactory<Self>
    init(value: Value, dimensions: MetricDimensions<DimensionKey>)
}

public struct ErrorHistogramFactory<Histogram: ErrorHistogram>: HistogramFactory {
    public var value: Histogram.Value
    public var dimensions: MetricDimensions<Histogram.DimensionKey>

    public init(value: Histogram.Value, dimensions: MetricDimensions<Histogram.DimensionKey> = .init()) {
        self.value = value
        self.dimensions = dimensions
    }

    public consuming func make(_ error: any Error) -> Histogram {
        .init(
            value: self.value,
            dimensions: self.dimensions.appending(String(reportable: error), forKey: .errorDescription)
        )
    }
}

public protocol DurationHistogram: Histogram {
    associatedtype DimensionKey: RawRepresentable<String> & Hashable & Sendable = NoDimensionKeys
    associatedtype Value = Double
    associatedtype Factory: HistogramFactory = DurationHistogramFactory<Self>
    init(value: Value, dimensions: MetricDimensions<DimensionKey>)
}

public struct DurationHistogramFactory<Histogram: DurationHistogram>: HistogramFactory {
    public var dimensions: MetricDimensions<Histogram.DimensionKey>

    public init(dimensions: MetricDimensions<Histogram.DimensionKey> = .init()) {
        self.dimensions = dimensions
    }

    public consuming func make(_ duration: Histogram.Value) -> Histogram {
        Histogram(value: duration, dimensions: self.dimensions)
    }
}

public protocol DimensionKeysWithExitCode {
    static var exitCode: Self { get }
    static var reasonNamespace: Self { get }
}

public enum DefaultExitDimensionKeys: String, DimensionKeysWithExitCode, RawRepresentable, Hashable, Sendable {
    case exitCode
    case reasonNamespace
}

public struct LaunchDJobExitDetails: Hashable, Sendable {
    public var exitCode: String
    public var reasonNamespace: String

    public init(exitCode: String, reasonNamespace: String) {
        self.exitCode = exitCode
        self.reasonNamespace = reasonNamespace
    }
}

public protocol ExitCounter: Counter {
    associatedtype DimensionKey: DimensionKeysWithExitCode = DefaultExitDimensionKeys
    associatedtype Factory: CounterFactory = ExitCounterFactory<Self>
    init(dimensions: MetricDimensions<DimensionKey>, action: CounterAction)
}

public struct ExitCounterFactory<Counter: ExitCounter>: CounterFactory {
    public var action: CounterAction
    public var dimensions: MetricDimensions<Counter.DimensionKey>

    public init(action: CounterAction = .increment, dimensions: MetricDimensions<Counter.DimensionKey> = .init()) {
        self.action = action
        self.dimensions = dimensions
    }

    public consuming func make(_ input: LaunchDJobExitDetails) -> Counter {
        .init(
            dimensions: self.dimensions.appending([
                (input.exitCode, .exitCode),
                (input.reasonNamespace, .reasonNamespace),
            ]),
            action: self.action
        )
    }
}

public protocol MetricsSystem: Sendable {
    func emit(_ counter: some Counter)
    func emit(_ gauge: some Gauge)
    func emit(_ histogram: some Histogram)
    func invalidate()
}

extension MetricsSystem {
    // swiftformat:disable opaqueGenericParameters
    public func withStatusMetrics<ReturnType, ErrorCounterType: ErrorCounter>(
        total totalCounter: some Counter,
        error errorCounterFactory: ErrorCounterFactory<ErrorCounterType>,
        _ body: () throws -> ReturnType
    ) rethrows -> ReturnType {
        self.emit(totalCounter)
        do {
            return try body()
        } catch {
            self.emit(errorCounterFactory.make(error))
            throw error
        }
    }

    public func withStatusMetrics<ReturnType, ErrorCounterType: ErrorCounter>(
        total totalCounter: some Counter,
        error errorCounterFactory: ErrorCounterFactory<ErrorCounterType>,
        _ body: () async throws -> ReturnType
    ) async rethrows -> ReturnType {
        self.emit(totalCounter)
        do {
            return try await body()
        } catch {
            self.emit(errorCounterFactory.make(error))
            throw error
        }
    }

    public func withStatusMetrics<ReturnType, ErrorCounterType: ErrorCounter, TimerHistogram>(
        total totalCounter: some Counter,
        error errorCounterFactory: ErrorCounterFactory<ErrorCounterType>,
        timer timerFactory: DurationHistogramFactory<TimerHistogram>,
        _ body: () throws -> ReturnType
    ) rethrows -> ReturnType where TimerHistogram.Value == Double {
        let timeMeasurement = ContinuousTimeMeasurement.start()
        defer {
            self.emit(timerFactory.make(timeMeasurement.duration.seconds))
        }
        self.emit(totalCounter)
        do {
            return try body()
        } catch {
            self.emit(errorCounterFactory.make(error))
            throw error
        }
    }

    public func withStatusMetrics<ReturnType, ErrorCounterType: ErrorCounter, TimerHistogram>(
        total totalCounter: some Counter,
        error errorCounterFactory: ErrorCounterFactory<ErrorCounterType>,
        timer timerFactory: DurationHistogramFactory<TimerHistogram>,
        _ body: () async throws -> ReturnType
    ) async rethrows -> ReturnType where TimerHistogram.Value == Double {
        let timeMeasurement = ContinuousTimeMeasurement.start()
        defer {
            self.emit(timerFactory.make(timeMeasurement.duration.seconds))
        }
        self.emit(totalCounter)
        do {
            return try await body()
        } catch {
            self.emit(errorCounterFactory.make(error))
            throw error
        }
    }
    // swiftformat:enable someall
}

public struct CloudMetricsSystem: MetricsSystem {
    public init(clientName: String) {
        #if canImport(CloudMetricsFramework)
        guard #_hasSymbol(CloudMetrics.self) else { return }
        CloudMetrics.bootstrap(clientName: clientName)
        #endif
    }

    public func emit(_ counter: some Counter) {
        #if canImport(CloudMetricsFramework)
        guard #_hasSymbol(CloudMetrics.self) else { return }

        let label = type(of: counter).label.rawValue
        let dimensions = counter.dimensions.dimensions.map { ($0.0.rawValue, $0.1) }

        let cloudCounter = CloudMetricsFramework.Counter(label: label, dimensions: dimensions)
        switch counter.action {
        case .increment(let amount):
            cloudCounter.increment(by: amount)
        case .reset(let value):
            cloudCounter.reset(value: value)
        }
        #endif
    }

    public func emit(_ gauge: some Gauge) {
        #if canImport(CloudMetricsFramework)
        guard #_hasSymbol(CloudMetrics.self) else { return }

        let label = type(of: gauge).label.rawValue
        let dimensions = gauge.dimensions.dimensions.map { ($0.0.rawValue, $0.1) }

        let cloudGauge = CloudMetricsFramework.Gauge(label: label, dimensions: dimensions)
        switch gauge.value.gaugeValue {
        case .integer(let value):
            cloudGauge.record(value)
        case .floatingPoint(let value):
            cloudGauge.record(value)
        }
        #endif
    }

    public func emit(_ histogram: some Histogram) {
        #if canImport(CloudMetricsFramework)
        guard #_hasSymbol(CloudMetrics.self) else { return }

        let label = type(of: histogram).label.rawValue
        let dimensions = histogram.dimensions.dimensions.map { ($0.0.rawValue, $0.1) }
        let buckets = type(of: histogram).buckets.buckets

        let cloudHistogram: CloudMetricsFramework.Histogram
        do {
            cloudHistogram = try CloudMetricsFramework.Histogram(label: label, dimensions: dimensions, buckets: buckets)
        } catch {
            logger.fault("failed to initialise histogram \(error)")
            return
        }

        switch histogram.value.histogramValue {
        case .integer(let value):
            cloudHistogram.record(value)
        case .floatingPoint(let value):
            cloudHistogram.record(value)
        }
        #endif
    }

    public func invalidate() {
        #if canImport(CloudMetricsFramework)
        guard #_hasSymbol(CloudMetrics.self) else { return }
        CloudMetrics.invalidate()
        #endif
    }
}

public struct NoOpMetricsSystem: MetricsSystem {
    public func emit(_: some Counter) {}
    public func emit(_: some Gauge) {}
    public func emit(_: some Histogram) {}
    public func invalidate() {}
}

extension MetricsSystem where Self == NoOpMetricsSystem {
    public static var noOp: Self { Self() }
}

// This is a sufficiently common operation and it's easy to think seconds() is precise
extension Duration {
    package var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) * 1e-15
    }

    package var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }

    package static func minutes(_ minutes: Int) -> Duration {
        return .seconds(minutes * 60)
    }

    package static func hours(_ hours: Int) -> Duration {
        return .minutes(hours * 60)
    }
}
