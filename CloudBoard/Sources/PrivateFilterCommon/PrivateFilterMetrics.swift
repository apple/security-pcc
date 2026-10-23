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

// Vendored from CloudBoardMetrics/CloudBoardMetrics.swift
// Types are renamed from CloudBoard* / generic names to PrivateFilter* to avoid
// collisions when both modules are linked in the same binary (e.g. PrivateFilterDownloader).
// The PrivateFilter targets will eventually move out of CloudBoard, so this avoids
// a dependency on CloudBoardMetrics from the start.

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
    category: "privatefiltermetrics"
)

// MARK: - Vendored from CloudBoardLogging (minimal subset)

/// Vendored from CloudBoardLogging.ReportableError
public protocol PrivateFilterReportableError: Error {
    var publicDescription: String { get }
}

extension String {
    /// Vendored from CloudBoardLogging — converts an error to a privacy-safe string.
    public init(privateFilterReportable error: Error) {
        if let reportableError = error as? PrivateFilterReportableError {
            self = reportableError.publicDescription
        } else {
            self = String(describing: type(of: error))
        }
    }
}

// MARK: - Constants

/// Vendored from CloudBoardMetrics.gaugeMetricPublishInterval
public let privateFilterGaugeMetricPublishInterval: Duration = .seconds(30)

// MARK: - MetricLabel (vendored from CloudBoardMetrics.MetricLabel)

public struct PrivateFilterMetricLabel: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension PrivateFilterMetricLabel: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

// MARK: - MetricDimensions (vendored from CloudBoardMetrics.MetricDimensions)

public struct PrivateFilterMetricDimensions<Key: RawRepresentable<String> & Hashable & Sendable>: Sendable {
    public var dimensions: [(Key, String)]
    public init(dimensions: [(Key, String)]) {
        self.dimensions = dimensions
    }

    public init() {
        self.dimensions = []
    }
}

extension PrivateFilterMetricDimensions: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (Key, String)...) {
        self.dimensions = elements
    }
}

extension PrivateFilterMetricDimensions {
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

// MARK: - NoDimensionKeys (vendored from CloudBoardMetrics.NoDimensionKeys)

public enum PrivateFilterNoDimensionKeys: RawRepresentable, Hashable, Sendable {
    public var rawValue: String { fatalError() }
    public init?(rawValue _: String) { return nil }
}

// MARK: - Counter (vendored from CloudBoardMetrics.Counter)

@frozen
public enum PrivateFilterCounterAction: Hashable, Sendable {
    public static var increment: Self { .increment(by: 1) }
    public static var reset: Self { .reset(to: 0) }
    case increment(by: Int)
    case reset(to: Int64)
}

public protocol PrivateFilterCounter: Sendable {
    associatedtype DimensionKey: RawRepresentable<String> & Hashable & Sendable = PrivateFilterNoDimensionKeys
    static var label: PrivateFilterMetricLabel { get }
    var dimensions: PrivateFilterMetricDimensions<DimensionKey> { get }
    var action: PrivateFilterCounterAction { get }
}

extension PrivateFilterCounter where DimensionKey == PrivateFilterNoDimensionKeys {
    public var dimensions: PrivateFilterMetricDimensions<DimensionKey> { [:] }
}

// MARK: - Gauge (vendored from CloudBoardMetrics.Gauge)

@frozen
public enum PrivateFilterGaugeValue: Hashable, Sendable {
    case integer(Int)
    case floatingPoint(Double)
}

public protocol PrivateFilterGaugeValueConvertible: Sendable {
    init?(_ gaugeValue: PrivateFilterGaugeValue)
    var privateFilterGaugeValue: PrivateFilterGaugeValue { get }
}

extension PrivateFilterGaugeValue: PrivateFilterGaugeValueConvertible {
    public init?(_ gaugeValue: PrivateFilterGaugeValue) {
        self = gaugeValue
    }

    public var privateFilterGaugeValue: PrivateFilterGaugeValue {
        self
    }
}

extension Int: PrivateFilterGaugeValueConvertible {
    public init?(_ gaugeValue: PrivateFilterGaugeValue) {
        switch gaugeValue {
        case .integer(let int):
            self = int
        case .floatingPoint:
            return nil
        }
    }

    public var privateFilterGaugeValue: PrivateFilterGaugeValue { .integer(self) }
}

extension Double: PrivateFilterGaugeValueConvertible {
    public init?(_ gaugeValue: PrivateFilterGaugeValue) {
        switch gaugeValue {
        case .integer:
            return nil
        case .floatingPoint(let double):
            self = double
        }
    }

    public var privateFilterGaugeValue: PrivateFilterGaugeValue { .floatingPoint(self) }
}

public protocol PrivateFilterGauge: Sendable {
    associatedtype DimensionKey: RawRepresentable<String> & Hashable & Sendable = PrivateFilterNoDimensionKeys
    associatedtype Value: PrivateFilterGaugeValueConvertible & Hashable & Sendable = Double
    static var label: PrivateFilterMetricLabel { get }
    var dimensions: PrivateFilterMetricDimensions<DimensionKey> { get }
    var value: Value { get }
}

extension PrivateFilterGauge where DimensionKey == PrivateFilterNoDimensionKeys {
    public var dimensions: PrivateFilterMetricDimensions<DimensionKey> { [:] }
}

// MARK: - Histogram (vendored from CloudBoardMetrics.Histogram)

public struct PrivateFilterHistogramBuckets: Hashable, Sendable {
    public var buckets: [Double]
    public init(buckets: [Double]) {
        self.buckets = buckets
    }
}

extension PrivateFilterHistogramBuckets: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Double...) {
        self.buckets = elements
    }
}

public protocol PrivateFilterHistogramValueConvertible {
    init?(_ histogramValue: PrivateFilterHistogramValue)
    var privateFilterHistogramValue: PrivateFilterHistogramValue { get }
}

@frozen
public enum PrivateFilterHistogramValue: Hashable, Sendable {
    case integer(Int)
    case floatingPoint(Double)
    case values([Double])
}

extension PrivateFilterHistogramValue: PrivateFilterHistogramValueConvertible {
    public init?(_ histogramValue: PrivateFilterHistogramValue) {
        self = histogramValue
    }

    public var privateFilterHistogramValue: PrivateFilterHistogramValue {
        self
    }
}

extension Int: PrivateFilterHistogramValueConvertible {
    public init?(_ histogramValue: PrivateFilterHistogramValue) {
        switch histogramValue {
        case .integer(let int):
            self = int
        case .floatingPoint, .values:
            return nil
        }
    }

    public var privateFilterHistogramValue: PrivateFilterHistogramValue { .integer(self) }
}

extension Double: PrivateFilterHistogramValueConvertible {
    public init?(_ histogramValue: PrivateFilterHistogramValue) {
        switch histogramValue {
        case .integer, .values:
            return nil
        case .floatingPoint(let double):
            self = double
        }
    }

    public var privateFilterHistogramValue: PrivateFilterHistogramValue { .floatingPoint(self) }
}

public protocol PrivateFilterHistogram: Sendable {
    associatedtype DimensionKey: RawRepresentable<String> & Hashable & Sendable = PrivateFilterNoDimensionKeys
    associatedtype Value: PrivateFilterHistogramValueConvertible & Hashable & Sendable = Double
    static var label: PrivateFilterMetricLabel { get }
    static var buckets: PrivateFilterHistogramBuckets { get }
    var dimensions: PrivateFilterMetricDimensions<DimensionKey> { get }
    var value: Value { get }
}

extension PrivateFilterHistogram where DimensionKey == PrivateFilterNoDimensionKeys {
    public var dimensions: PrivateFilterMetricDimensions<DimensionKey> { [:] }
}

// MARK: - Factories (vendored from CloudBoardMetrics)

public protocol PrivateFilterCounterFactory<Input>: Sendable {
    associatedtype Input
    associatedtype Counter: PrivateFilterCounter

    func make(_ input: Input) -> Counter
}

public protocol PrivateFilterGaugeFactory<Input>: Sendable {
    associatedtype Input
    associatedtype Gauge: PrivateFilterGauge

    func make(_ input: Input) -> Gauge
}

public protocol PrivateFilterHistogramFactory<Input>: Sendable {
    associatedtype Input
    associatedtype Histogram: PrivateFilterHistogram

    consuming func make(_ input: Input) -> Histogram
}

// MARK: - Error specializations (vendored from CloudBoardMetrics)

public protocol PrivateFilterDimensionKeysWithError {
    static var errorDescription: Self { get }
}

public enum PrivateFilterDefaultErrorDimensionKeys: String, PrivateFilterDimensionKeysWithError, RawRepresentable,
Hashable, Sendable {
    case errorDescription
}

public protocol PrivateFilterErrorCounter: PrivateFilterCounter {
    associatedtype DimensionKey: PrivateFilterDimensionKeysWithError = PrivateFilterDefaultErrorDimensionKeys
    associatedtype Factory: PrivateFilterCounterFactory = PrivateFilterErrorCounterFactory<Self>
    init(dimensions: PrivateFilterMetricDimensions<DimensionKey>, action: PrivateFilterCounterAction)
}

public struct PrivateFilterErrorCounterFactory<Counter: PrivateFilterErrorCounter>: PrivateFilterCounterFactory {
    public var action: PrivateFilterCounterAction
    public var dimensions: PrivateFilterMetricDimensions<Counter.DimensionKey>

    public init(
        action: PrivateFilterCounterAction = .increment,
        dimensions: PrivateFilterMetricDimensions<Counter.DimensionKey> = .init()
    ) {
        self.action = action
        self.dimensions = dimensions
    }

    public consuming func make(_ error: any Error) -> Counter {
        .init(
            dimensions: self.dimensions.appending(
                String(privateFilterReportable: error), forKey: .errorDescription
            ),
            action: self.action
        )
    }
}

// Does this make sense for a Gauge?
public protocol PrivateFilterErrorGauge: PrivateFilterGauge {
    associatedtype DimensionKey: PrivateFilterDimensionKeysWithError = PrivateFilterDefaultErrorDimensionKeys
    associatedtype Factory: PrivateFilterGaugeFactory = PrivateFilterErrorGaugeFactory<Self>
    init(value: Value, dimensions: PrivateFilterMetricDimensions<DimensionKey>)
}

public struct PrivateFilterErrorGaugeFactory<Gauge: PrivateFilterErrorGauge>: PrivateFilterGaugeFactory {
    public var value: Gauge.Value
    public var dimensions: PrivateFilterMetricDimensions<Gauge.DimensionKey>

    public init(value: Gauge.Value, dimensions: PrivateFilterMetricDimensions<Gauge.DimensionKey> = .init()) {
        self.value = value
        self.dimensions = dimensions
    }

    public consuming func make(_ error: any Error) -> Gauge {
        .init(
            value: self.value,
            dimensions: self.dimensions.appending(
                String(privateFilterReportable: error), forKey: .errorDescription
            )
        )
    }
}

public protocol PrivateFilterErrorHistogram: PrivateFilterHistogram {
    associatedtype DimensionKey: PrivateFilterDimensionKeysWithError = PrivateFilterDefaultErrorDimensionKeys
    associatedtype Factory: PrivateFilterHistogramFactory = PrivateFilterErrorHistogramFactory<Self>
    init(value: Value, dimensions: PrivateFilterMetricDimensions<DimensionKey>)
}

public struct PrivateFilterErrorHistogramFactory<Histogram: PrivateFilterErrorHistogram>:
PrivateFilterHistogramFactory {
    public var value: Histogram.Value
    public var dimensions: PrivateFilterMetricDimensions<Histogram.DimensionKey>

    public init(
        value: Histogram.Value,
        dimensions: PrivateFilterMetricDimensions<Histogram.DimensionKey> = .init()
    ) {
        self.value = value
        self.dimensions = dimensions
    }

    public consuming func make(_ error: any Error) -> Histogram {
        .init(
            value: self.value,
            dimensions: self.dimensions.appending(
                String(privateFilterReportable: error), forKey: .errorDescription
            )
        )
    }
}

// MARK: - Duration histogram (vendored from CloudBoardMetrics.DurationHistogram)

public protocol PrivateFilterDurationHistogram: PrivateFilterHistogram {
    associatedtype DimensionKey: RawRepresentable<String> & Hashable & Sendable = PrivateFilterNoDimensionKeys
    associatedtype Value = Double
    associatedtype Factory: PrivateFilterHistogramFactory = PrivateFilterDurationHistogramFactory<Self>
    init(value: Value, dimensions: PrivateFilterMetricDimensions<DimensionKey>)
}

public struct PrivateFilterDurationHistogramFactory<Histogram: PrivateFilterDurationHistogram>:
PrivateFilterHistogramFactory {
    public var dimensions: PrivateFilterMetricDimensions<Histogram.DimensionKey>

    public init(dimensions: PrivateFilterMetricDimensions<Histogram.DimensionKey> = .init()) {
        self.dimensions = dimensions
    }

    public consuming func make(_ duration: Histogram.Value) -> Histogram {
        Histogram(value: duration, dimensions: self.dimensions)
    }
}

// MARK: - Exit counter (vendored from CloudBoardMetrics)

public protocol PrivateFilterDimensionKeysWithExitCode {
    static var exitCode: Self { get }
    static var reasonNamespace: Self { get }
}

public enum PrivateFilterDefaultExitDimensionKeys: String, PrivateFilterDimensionKeysWithExitCode,
RawRepresentable, Hashable, Sendable {
    case exitCode
    case reasonNamespace
}

public struct PrivateFilterLaunchDJobExitDetails: Hashable, Sendable {
    public var exitCode: String
    public var reasonNamespace: String

    public init(exitCode: String, reasonNamespace: String) {
        self.exitCode = exitCode
        self.reasonNamespace = reasonNamespace
    }
}

public protocol PrivateFilterExitCounter: PrivateFilterCounter {
    associatedtype DimensionKey: PrivateFilterDimensionKeysWithExitCode = PrivateFilterDefaultExitDimensionKeys
    associatedtype Factory: PrivateFilterCounterFactory = PrivateFilterExitCounterFactory<Self>
    init(dimensions: PrivateFilterMetricDimensions<DimensionKey>, action: PrivateFilterCounterAction)
}

public struct PrivateFilterExitCounterFactory<Counter: PrivateFilterExitCounter>: PrivateFilterCounterFactory {
    public var action: PrivateFilterCounterAction
    public var dimensions: PrivateFilterMetricDimensions<Counter.DimensionKey>

    public init(
        action: PrivateFilterCounterAction = .increment,
        dimensions: PrivateFilterMetricDimensions<Counter.DimensionKey> = .init()
    ) {
        self.action = action
        self.dimensions = dimensions
    }

    public consuming func make(_ input: PrivateFilterLaunchDJobExitDetails) -> Counter {
        .init(
            dimensions: self.dimensions.appending([
                (input.exitCode, .exitCode),
                (input.reasonNamespace, .reasonNamespace),
            ]),
            action: self.action
        )
    }
}

// MARK: - MetricsSystem (vendored from CloudBoardMetrics.MetricsSystem)

public protocol PrivateFilterMetricsSystem: Sendable {
    func emit(_ counter: some PrivateFilterCounter)
    func emit(_ gauge: some PrivateFilterGauge)
    func emit(_ histogram: some PrivateFilterHistogram)
    func invalidate()
}

extension PrivateFilterMetricsSystem {
    // swiftformat:disable opaqueGenericParameters
    public func withStatusMetrics<ReturnType, ErrorCounterType: PrivateFilterErrorCounter>(
        total totalCounter: some PrivateFilterCounter,
        error errorCounterFactory: PrivateFilterErrorCounterFactory<ErrorCounterType>,
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

    public func withStatusMetrics<ReturnType, ErrorCounterType: PrivateFilterErrorCounter>(
        total totalCounter: some PrivateFilterCounter,
        error errorCounterFactory: PrivateFilterErrorCounterFactory<ErrorCounterType>,
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

    public func withStatusMetrics<
        ReturnType, ErrorCounterType: PrivateFilterErrorCounter, TimerHistogram: PrivateFilterDurationHistogram
    >(
        total totalCounter: some PrivateFilterCounter,
        error errorCounterFactory: PrivateFilterErrorCounterFactory<ErrorCounterType>,
        timer timerFactory: PrivateFilterDurationHistogramFactory<TimerHistogram>,
        _ body: () throws -> ReturnType
    ) rethrows -> ReturnType where TimerHistogram.Value == Double {
        let start = ContinuousClock.now
        defer {
            let duration = ContinuousClock.now - start
            self.emit(timerFactory.make(duration.privateFilterSeconds))
        }
        self.emit(totalCounter)
        do {
            return try body()
        } catch {
            self.emit(errorCounterFactory.make(error))
            throw error
        }
    }

    public func withStatusMetrics<
        ReturnType, ErrorCounterType: PrivateFilterErrorCounter, TimerHistogram: PrivateFilterDurationHistogram
    >(
        total totalCounter: some PrivateFilterCounter,
        error errorCounterFactory: PrivateFilterErrorCounterFactory<ErrorCounterType>,
        timer timerFactory: PrivateFilterDurationHistogramFactory<TimerHistogram>,
        _ body: () async throws -> ReturnType
    ) async rethrows -> ReturnType where TimerHistogram.Value == Double {
        let start = ContinuousClock.now
        defer {
            let duration = ContinuousClock.now - start
            self.emit(timerFactory.make(duration.privateFilterSeconds))
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

// MARK: - CloudMetricsSystem (vendored from CloudBoardMetrics.CloudMetricsSystem)

public struct PrivateFilterCloudMetricsSystem: PrivateFilterMetricsSystem {
    /// - Parameters:
    ///   - clientName: The client name for CloudMetrics.
    ///   - bootstrap: Whether to call CloudMetrics.bootstrap. Defaults to true.
    ///     Pass false when another metrics system (e.g. CloudBoardMetrics.CloudMetricsSystem)
    ///     already handles bootstrap in the same process.
    public init(clientName: String, bootstrap: Bool = true) {
        #if canImport(CloudMetricsFramework)
        if bootstrap {
            guard #_hasSymbol(CloudMetrics.self) else { return }
            CloudMetrics.bootstrap(clientName: clientName)
        }
        #endif
    }

    public func emit(_ counter: some PrivateFilterCounter) {
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

    public func emit(_ gauge: some PrivateFilterGauge) {
        #if canImport(CloudMetricsFramework)
        guard #_hasSymbol(CloudMetrics.self) else { return }

        let label = type(of: gauge).label.rawValue
        let dimensions = gauge.dimensions.dimensions.map { ($0.0.rawValue, $0.1) }

        let cloudGauge = CloudMetricsFramework.Gauge(label: label, dimensions: dimensions)
        switch gauge.value.privateFilterGaugeValue {
        case .integer(let value):
            cloudGauge.record(value)
        case .floatingPoint(let value):
            cloudGauge.record(value)
        }
        #endif
    }

    public func emit(_ histogram: some PrivateFilterHistogram) {
        #if canImport(CloudMetricsFramework)
        guard #_hasSymbol(CloudMetrics.self) else { return }

        let label = type(of: histogram).label.rawValue
        let dimensions = histogram.dimensions.dimensions.map { ($0.0.rawValue, $0.1) }
        let buckets = type(of: histogram).buckets.buckets

        let cloudHistogram: CloudMetricsFramework.Histogram
        do {
            cloudHistogram = try CloudMetricsFramework.Histogram(
                label: label, dimensions: dimensions, buckets: buckets
            )
        } catch {
            logger.fault("failed to initialise histogram \(error)")
            return
        }

        switch histogram.value.privateFilterHistogramValue {
        case .integer(let value):
            cloudHistogram.record(value)
        case .floatingPoint(let value):
            cloudHistogram.record(value)
        case .values(let samples):
            // cloudmetricsd does not implement histogramSetBuckets() so we record
            // each sample individually via the conventional path.
            for sample in samples {
                cloudHistogram.record(sample)
            }
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

// MARK: - NoOpMetricsSystem (vendored from CloudBoardMetrics.NoOpMetricsSystem)

public struct PrivateFilterNoOpMetricsSystem: PrivateFilterMetricsSystem {
    public init() {}
    public func emit(_: some PrivateFilterCounter) {}
    public func emit(_: some PrivateFilterGauge) {}
    public func emit(_: some PrivateFilterHistogram) {}
    public func invalidate() {}
}

extension PrivateFilterMetricsSystem where Self == PrivateFilterNoOpMetricsSystem {
    public static var noOp: Self { Self() }
}

// MARK: - Duration extensions (vendored from CloudBoardMetrics)

extension Duration {
    public var privateFilterMilliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) * 1e-15
    }

    public var privateFilterSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}

// MARK: - Histogram buckets

extension PrivateFilterHistogramBuckets {
    // Same boundaries as `persistentServiceQueryTime` in CloudBoardJobFramework
    // and `requestTime` in CloudBoardJobHelperCore/CloudBoardDCore.
    public static let lookupTime: Self = [
        0.001381,
        0.001953,
        0.002762,
        0.003906,
        0.005524,
        0.007812,
        0.011049,
        0.015625,
        0.022097,
        0.03125,
        0.044194,
        0.0625,
        0.088388,
        0.125,
        0.176777,
        0.25,
        0.353553,
        0.5,
        0.707107,
        1.0,
        1.414214,
        1.681793,
        2.0,
        2.181015,
        2.378414,
        2.593679,
        2.828427,
        2.953652,
        3.084422,
        3.220981,
        3.363586,
        3.512504,
        3.668016,
        3.830413,
        4.0,
        4.177095,
        4.362031,
        4.555155,
        4.756828,
        4.967431,
        5.187358,
        5.417022,
        5.656854,
        5.907305,
        6.168843,
        6.441961,
        6.727171,
        7.025009,
        7.336032,
        7.660826,
        8.0,
        8.35419,
        8.724062,
        9.110309,
        9.513657,
        9.934862,
        10.374716,
        11.313708,
        12.337687,
        13.454343,
        14.672065,
        16.0,
        22.627417,
        32.0,
        45.254834,
        64.0,
        90.509668,
        128.0,
        181.019336,
        256.0,
        362.038672,
    ]
}
