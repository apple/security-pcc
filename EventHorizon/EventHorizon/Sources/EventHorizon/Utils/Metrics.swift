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

import Foundation
#if canImport(LoggingSupport, _version: 1788)
@_spi(OSMetric)
import os
#elseif canImport(os)
import os
#endif
import Synchronization
#if os(Linux)
import Metrics
#endif

#if canImport(LoggingSupport, _version: 1788)
@available(macOS 16, iOS 19.0, watchOS 12.0, tvOS 19.0, *)
extension OSMetricGroup: EHMetrics.EHMetricGroupProtocol {
    public init(subsystem: String, category: String) {
        self.init(subsystem: subsystem, category: category, dimensions: .empty)
    }
}

@available(macOS 16, iOS 19.0, watchOS 12.0, tvOS 19.0, *)
extension OSMetricCounter: EHMetrics.EHCounter where T == UInt64 {}

@available(macOS 16, iOS 19.0, watchOS 12.0, tvOS 19.0, *)
extension OSMetricGauge: EHMetrics.EHGauge where T == Double {}
#endif

public actor EHMetrics {
    public static let label_prefix = "eh"
    public protocol EHCounter: Sendable {
        func add(_ value: UInt64)
        func subtract(_ value: UInt64)
        func reset()
        func increment()
        func decrement()
    }
    public protocol EHGauge: Sendable {
        func reset()
        func set(_ value: Double)
    }

    public protocol EHMetricGroupProtocol: Sendable {
        init(subsystem: String, category: String)
        init()
    }

    public struct MetricKey: Hashable, Sendable {
        public let base: String
        public let dimensions: [(String, String)]?

        public init(base: String, dimensions: [(String, String)]? = nil) {
            self.base = base
            self.dimensions = dimensions?.sorted(by: { $0.0 < $1.0 })
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(base)
            guard let dimensions else {
                return
            }
            for (key, value) in dimensions {
                hasher.combine(key)
                hasher.combine(value)
            }
        }

        public static func == (lhs: MetricKey, rhs: MetricKey) -> Bool {
            guard lhs.base == rhs.base else {
                return false
            }
            switch (lhs.dimensions, rhs.dimensions) {
            case (nil, nil):
                return true
            case (nil, _), (_, nil):
                return false
            case let (lhsDims?, rhsDims?):
                guard lhsDims.count == rhsDims.count else {
                    return false
                }
                for (lhsPair, rhsPair) in zip(lhsDims, rhsDims) {
                    if lhsPair.0 != rhsPair.0 || lhsPair.1 != rhsPair.1 {
                        return false
                    }
                }
                return true
            }
        }
    }

    private let log = EHLog.withCategory(EHMetrics.self)
    private var groups: [String: any EHMetricGroupProtocol] = [:]
    private var counters: [MetricKey: any EHCounter] = [:]
    private var gauges: [MetricKey: any EHGauge] = [:]

    private func metricKey(base: String, extraDimensions: [(String, String)]? = nil) -> MetricKey {
        MetricKey(base: base, dimensions: extraDimensions)
    }

    public func counter_increment(counter: String, by: UInt64 = 1, group: String, extraDimensions: [(String, String)]? = nil) {
        counterOrCreate(label: counter, group: group, extraDimensions: extraDimensions).add(by)
    }
    public func counter_decrement(counter: String, by: UInt64 = 1, group: String, extraDimensions: [(String, String)]? = nil) {
        counterOrCreate(label: counter, group: group, extraDimensions: extraDimensions).subtract(by)
    }
    public func counter_reset(counter: String, group: String, extraDimensions: [(String, String)]? = nil) {
        counterOrCreate(label: counter, group: group, extraDimensions: extraDimensions).reset()
    }
    public func gauge_set(gauge: String, value: Double, group: String, extraDimensions: [(String, String)]? = nil) {
        gaugeOrCreate(label: gauge, group: group, extraDimensions: extraDimensions).set(value)
    }
    public func gauge_reset(gauge: String, group: String, extraDimensions: [(String, String)]? = nil) {
        gaugeOrCreate(label: gauge, group: group, extraDimensions: extraDimensions).reset()
    }

    private func counterOrCreate(label: String, group: String, extraDimensions: [(String, String)]? = nil) -> any EHCounter {
        let idxKey = metricKey(base: label, extraDimensions: extraDimensions)
        if let c = counters[idxKey] {
            return c
        }
        if groups[group] == nil {
            groups[group] = EHMetrics.groupWithCategory(group)
        }
        counters[idxKey] = EHMetrics.createCounter(label: label, group: groups[group]!, extraDimensions: extraDimensions)
        return counters[idxKey]!
    }

    private func gaugeOrCreate(label: String, group: String, extraDimensions: [(String, String)]? = nil) -> any EHGauge {
        let idxKey = metricKey(base: label, extraDimensions: extraDimensions)
        if let g = gauges[idxKey] {
            return g
        }
        if groups[group] == nil {
            groups[group] = EHMetrics.groupWithCategory(group)
        }
        gauges[idxKey] = EHMetrics.createGauge(label: label, group: groups[group]!, extraDimensions: extraDimensions)
        return gauges[idxKey]!
    }

    private init() {
        #if !os(Linux)
        if !EHMetrics.supportsOSMetrics() {
            Task {
                repeat {
                    try? await Task.sleep(for: .seconds(10))
                    await EHMetrics.shared.dumpValues()
                } while true
            }
        }
        #endif
    }

    public func addGroup(_ group: String) {
        self.groups[group] = EHMetrics.groupWithCategory(group)
    }

    public func addCounter(label: String, group: String, extraDimensions: [(String, String)]? = nil) {
        let key = metricKey(base: label, extraDimensions: extraDimensions)
        if groups[group] == nil {
            groups[group] = EHMetrics.groupWithCategory(group)
        }
        self.counters[key] = EHMetrics.createCounter(label: label, group: groups[group]!, extraDimensions: extraDimensions)
    }

    public func addGauge(label: String, group: String, extraDimensions: [(String, String)]? = nil) {
        let key = metricKey(base: label, extraDimensions: extraDimensions)
        if groups[group] == nil {
            groups[group] = EHMetrics.groupWithCategory(group)
        }
        self.gauges[key] = EHMetrics.createGauge(label: label, group: groups[group]!, extraDimensions: extraDimensions)
    }

    public func preRegisterMetrics<C: EHMetricDefinitionCounterProtocol, G: EHMetricDefinitionGaugeProtocol>(
        counters: C.Type,
        gauges: G.Type,
        dimensionCombinations: [[(String, String)]]? = nil
    ) {
        MetricNameCache.shared.preload(C.self)
        MetricNameCache.shared.preload(G.self)

        for counter in C.allCases {
            let group = counter.group
            if groups[group] == nil {
                groups[group] = EHMetrics.groupWithCategory(group)
            }
            _ = counterOrCreate(label: counter.prefixedMetricName, group: group, extraDimensions: nil)

            if let dimensionCombinations {
                for dims in dimensionCombinations {
                    _ = counterOrCreate(label: counter.prefixedMetricName, group: group, extraDimensions: dims)
                }
            }
        }

        for gauge in G.allCases {
            let group = gauge.group
            if groups[group] == nil {
                groups[group] = EHMetrics.groupWithCategory(group)
            }
            _ = gaugeOrCreate(label: gauge.prefixedMetricName, group: group, extraDimensions: nil)

            if let dimensionCombinations {
                for dims in dimensionCombinations {
                    _ = gaugeOrCreate(label: gauge.prefixedMetricName, group: group, extraDimensions: dims)
                }
            }
        }
    }

    public func bulkReport(counters: [(any EHMetrics.EHMetricDefinitionProtocol, UInt64, [(String, String)]?)]?,
                           gauges: [(any EHMetrics.EHMetricDefinitionProtocol, Double, [(String, String)]?)]?) {
        if let counters {
            for counter in counters {
                self.counter_increment(counter: counter.0.prefixedMetricName, by: counter.1, group: counter.0.group, extraDimensions: counter.2)
            }
        }
        if let gauges {
            for gauge in gauges {
                self.gauge_set(gauge: gauge.0.prefixedMetricName, value: gauge.1, group: gauge.0.group, extraDimensions: gauge.2)
            }
        }
    }
    #if !os(Linux)
    public func dumpValues() {
        var counterValues: [String: UInt64] = [:]
        var gaugeValues: [String: Double] = [:]

        for (_, counter) in self.counters {
            if let m = counter as? EHMetricCounter {
                let fname = !m.dimensions.isEmpty ? "\(m.label){\(m.dimensions.map { dim in "\(dim.name)=\(dim.value)" }.sorted().joined(separator: ","))}" : m.label
                counterValues[fname] = m.value
            }
        }

        for (_, gauge) in self.gauges {
            if let m = gauge as? EHMetricGauge {
                let fname = !m.dimensions.isEmpty ? "\(m.label){\(m.dimensions.map { dim in "\(dim.name)=\(dim.value)" }.sorted().joined(separator: ","))}" : m.label
                gaugeValues[fname] = m.value
            }
        }

        if !counterValues.isEmpty {
            let c = String(data: (try? JSONEncoder().encode(counterValues)) ?? Data(), encoding: .utf8) ?? "encoding failed"
            os_log(.debug, log: log, "Metrics: Counters: \(c)")
        }
        if !gaugeValues.isEmpty {
            let g = String(data: (try? JSONEncoder().encode(gaugeValues)) ?? Data(), encoding: .utf8) ?? "encoding failed"
            os_log(.debug, log: log, "Metrics: Gauges: \(g)")
        }
    }
    #endif

    public func exportPrometheus() -> String {
        #if os(Linux)
        return PrometheusBackend.exportText()
        #else
        var lines: [String] = []

        var countersByLabel: [String: [(dimensions: [SendableDimension], value: UInt64)]] = [:]
        for (_, counter) in self.counters {
            if let m = counter as? EHMetricCounter {
                countersByLabel[m.label, default: []].append((m.dimensions, m.value))
            }
        }

        let cacheCounters = PipelineMetricsCache.shared.exportCounterValues()
        for entry in cacheCounters {
            if var existing = countersByLabel[entry.label] {
                existing.removeAll { e in
                    let eDims = Dictionary(uniqueKeysWithValues: e.dimensions.map { ($0.name, $0.value) })
                    let entryDims = Dictionary(uniqueKeysWithValues: entry.dimensions.map { ($0.name, $0.value) })
                    return eDims == entryDims
                }
                existing.append((entry.dimensions, entry.value))
                countersByLabel[entry.label] = existing
            } else {
                countersByLabel[entry.label, default: []].append((entry.dimensions, entry.value))
            }
        }

        for label in countersByLabel.keys.sorted() {
            guard var entries = countersByLabel[label] else {
                continue
            }
            let hasNonZero = entries.contains { $0.value > 0 }
            if hasNonZero {
                entries.removeAll { $0.value == 0 }
            }
            let sanitized = Self.sanitizeMetricName(label)
            lines.append("# TYPE \(sanitized) counter")
            for entry in entries {
                let labelStr = Self.formatPrometheusLabels(entry.dimensions)
                lines.append("\(sanitized)\(labelStr) \(entry.value)")
            }
        }

        var gaugesByLabel: [String: [(dimensions: [SendableDimension], value: Double)]] = [:]
        for (_, gauge) in self.gauges {
            if let m = gauge as? EHMetricGauge {
                gaugesByLabel[m.label, default: []].append((m.dimensions, m.value))
            }
        }

        let cacheGauges = PipelineMetricsCache.shared.exportGaugeValues()
        for entry in cacheGauges {
            if var existing = gaugesByLabel[entry.label] {
                existing.removeAll { e in
                    let eDims = Dictionary(uniqueKeysWithValues: e.dimensions.map { ($0.name, $0.value) })
                    let entryDims = Dictionary(uniqueKeysWithValues: entry.dimensions.map { ($0.name, $0.value) })
                    return eDims == entryDims
                }
                existing.append((entry.dimensions, entry.value))
                gaugesByLabel[entry.label] = existing
            } else {
                gaugesByLabel[entry.label, default: []].append((entry.dimensions, entry.value))
            }
        }

        for label in gaugesByLabel.keys.sorted() {
            guard var entries = gaugesByLabel[label] else {
                continue
            }
            let hasNonZero = entries.contains { $0.value != 0.0 }
            if hasNonZero {
                entries.removeAll { $0.value == 0.0 }
            }
            let sanitized = Self.sanitizeMetricName(label)
            lines.append("# TYPE \(sanitized) gauge")
            for entry in entries {
                let labelStr = Self.formatPrometheusLabels(entry.dimensions)
                lines.append("\(sanitized)\(labelStr) \(Self.formatDouble(entry.value))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
        #endif
    }
    private static func supportsOSMetrics() -> Bool {
        #if os(Linux)
        return false
        #else
        guard #available(macOS 16, iOS 19.0, watchOS 12.0, tvOS 19.0, *) else {
            return false
        }
        return true
        #endif
    }

    public static let shared = EHMetrics()
    public static func groupWithCategory(_ category: String) -> EHMetricGroupProtocol {
        #if !os(Linux)
            #if canImport(LoggingSupport, _version: 1788)
                if #available(macOS 16, iOS 19.0, watchOS 12.0, tvOS 19.0, *) {
                    return OSMetricGroup(subsystem: EventHorizonKit.framework_name, category: category)
                }
            #endif
        #endif
        return EHMetricGroup(subsystem: EventHorizonKit.framework_name, category: category)
    }

    public static func createCounter(label: String, group: any EHMetricGroupProtocol, extraDimensions: [(String, String)]? = nil) -> any EHCounter {
        let dimensions = extraDimensions != nil ? extraDimensions! + EHMetrics.defaultDimensions() : EHMetrics.defaultDimensions()
        #if !os(Linux)
            #if canImport(LoggingSupport, _version: 1788)
                if #available(macOS 16, iOS 19.0, watchOS 12.0, tvOS 19.0, *) {
                    return OSMetricCounter(type: UInt64.self,
                                                 group: group as? OSMetricGroup ?? OSMetricGroup(subsystem: EventHorizonKit.framework_name, category: "default"),
                                                 label: label,
                                                 extraDimensions: OSMetricDimensions(values: dimensions)
                                           )
                }
            #endif
        #endif
        return EHMetricCounter(label: label, group: group, dimensions: dimensions)
    }

    public static func createGauge(label: String, group: any EHMetricGroupProtocol, extraDimensions: [(String, String)]? = nil) -> any EHGauge {
        let dimensions = extraDimensions != nil ? extraDimensions! + EHMetrics.defaultDimensions() : EHMetrics.defaultDimensions()
        #if !os(Linux)
            #if canImport(LoggingSupport, _version: 1788)
                if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *) {
                    return OSMetricGauge(type: Double.self,
                                         group: group as? OSMetricGroup ?? OSMetricGroup(subsystem: EventHorizonKit.framework_name, category: "default"),
                                         label: label,
                                         extraDimensions: OSMetricDimensions(values: dimensions)
                                         )
                }
            #endif
        #endif
        return EHMetricGauge(label: label, group: group, dimensions: dimensions)
    }

    public static func defaultDimensions() -> [(String, String)] {
        return [
            (DefaultDimensions.eh_frontend.rawValue, EHInfo.shared.currentFrontend),
            (DefaultDimensions.eh_variant.rawValue, EHInfo.shared.currentVariant)
        ]
    }

    public enum DefaultDimensions: String {
        case eh_frontend
        case eh_variant
    }

    struct EHMetricGroup: EHMetricGroupProtocol {
        init(subsystem: String, category: String) {
            self.subsystem = subsystem
            self.category = category
        }

        init() {
            self.subsystem = EventHorizonKit.framework_name
            self.category = "default"
        }

        let subsystem: String
        let category: String
    }

    final class EHMetricCounter: EHCounter {
        let label: String
        let group: any EHMetricGroupProtocol
        let dimensions: [SendableDimension]
        #if os(Linux)
        let counter: Metrics.Counter
        #else
        let ivalue: Mutex<UInt64> = .init(0)
        #endif

        init(label: String = "", group: any EHMetricGroupProtocol, dimensions: [(String, String)] = []) {
            self.label = label
            self.group = group
            self.dimensions = dimensions.map { SendableDimension(name: $0.0, value: $0.1) }
            #if os(Linux)
            self.counter = Metrics.Counter(label: label, dimensions: dimensions)
            #endif
        }

        #if !os(Linux)
        var value: UInt64 {
            return self.ivalue.withLock { $0 }
        }
        #endif

        func add(_ value: UInt64) {
            #if os(Linux)
            self.counter.increment(by: Int64(min(value, UInt64(Int64.max))))
            #else
            self.ivalue.withLock { $0 += value }
            #endif
        }

        func subtract(_ value: UInt64) {
            #if os(Linux)
            _ = value
            #else
            self.ivalue.withLock { $0 -= value }
            #endif
        }

        func reset() {
            #if os(Linux)
            self.counter.reset()
            #else
            self.ivalue.withLock { $0 = 0 }
            #endif
        }

        func increment() {
            #if os(Linux)
            self.counter.increment()
            #else
            self.ivalue.withLock { $0 += 1 }
            #endif
        }

        func decrement() {
            #if os(Linux)
            #else
            self.ivalue.withLock { $0 -= 1 }
            #endif
        }
    }
    struct SendableDimension: Codable, Sendable {
        let name: String
        let value: String
    }

    final class EHMetricGauge: EHGauge, Sendable {
        let label: String
        let group: any EHMetricGroupProtocol
        let dimensions: [SendableDimension]
        #if os(Linux)
        let gauge: Metrics.Gauge
        #else
        let ivalue: Mutex<Double> = .init(0)
        #endif

        init(label: String = "", group: any EHMetricGroupProtocol, dimensions: [(String, String)] = []) {
            self.label = label
            self.group = group
            self.dimensions = dimensions.map { SendableDimension(name: $0.0, value: $0.1) }
            #if os(Linux)
            self.gauge = Metrics.Gauge(label: label, dimensions: dimensions)
            #endif
        }

        #if !os(Linux)
        var value: Double {
            return self.ivalue.withLock { $0 }
        }
        #endif

        func reset() {
            #if os(Linux)
            self.gauge.record(0.0)
            #else
            self.ivalue.withLock { $0 = 0 }
            #endif
        }

        func set(_ value: Double) {
            #if os(Linux)
            self.gauge.record(value)
            #else
            self.ivalue.withLock { $0 = value }
            #endif
        }
    }


    public protocol EHMetricDefinitionProtocol: CaseIterable, Sendable {
        var prefixedMetricName: String { get }
        var rawValue: String { get }
        var group: String { get }
    }

    public protocol EHMetricDefinitionCounterProtocol: EHMetricDefinitionProtocol {
        func increment(_ by: UInt64, extraDimensions: [(String, String)]?) async
        func decrement(_ by: UInt64, extraDimensions: [(String, String)]?) async
        func reset(_ extraDimensions: [(String, String)]?) async

        var batchSize: UInt64? { get }
    }

    public protocol EHMetricDefinitionGaugeProtocol: EHMetricDefinitionProtocol {
        func set(_ value: Double, extraDimensions: [(String, String)]?) async
        func reset(_ extraDimensions: [(String, String)]?) async

        var sampleRate: UInt64? { get }
    }

    public protocol EHMetricConfigProtocol {
        associatedtype _counters: EHMetricDefinitionProtocol
        associatedtype _gauges: EHMetricDefinitionProtocol
    }


    public final class MetricNameCache: @unchecked Sendable {
        public static let shared = MetricNameCache()

        private struct State {
            var groupCache: [String: String] = [:]
            var prefixedNameCache: [String: String] = [:]
        }

        private let state = Mutex<State>(State())

        private init() {}

        public func group(for rawValue: String) -> String {
            state.withLock { state in
                if let cached = state.groupCache[rawValue] {
                    return cached
                }

                let computed: String
                if let underscoreIndex = rawValue.firstIndex(of: "_") {
                    computed = String(rawValue[..<underscoreIndex])
                } else {
                    computed = "default"
                }

                state.groupCache[rawValue] = computed
                return computed
            }
        }

        public func prefixedName(for rawValue: String) -> String {
            state.withLock { state in
                if let cached = state.prefixedNameCache[rawValue] {
                    return cached
                }

                let computed = "\(EHMetrics.label_prefix)_\(rawValue)"
                state.prefixedNameCache[rawValue] = computed
                return computed
            }
        }

        public func preload<T: EHMetricDefinitionProtocol>(_ type: T.Type) {
            for metric in T.allCases {
                _ = group(for: metric.rawValue)
                _ = prefixedName(for: metric.rawValue)
            }
        }
    }
}

extension EHMetrics.EHMetricDefinitionProtocol {
    public var prefixedMetricName: String {
        EHMetrics.MetricNameCache.shared.prefixedName(for: self.rawValue)
    }

    public var group: String {
        EHMetrics.MetricNameCache.shared.group(for: self.rawValue)
    }
}

extension EHMetrics.EHMetricDefinitionCounterProtocol {
    public func increment(_ by: UInt64 = 1, extraDimensions: [(String, String)]? = nil) async {
        await EHMetrics.shared.counter_increment(counter: self.prefixedMetricName, by: by, group: self.group, extraDimensions: extraDimensions)
    }
    public func decrement(_ by: UInt64 = 1, extraDimensions: [(String, String)]? = nil) async {
        await EHMetrics.shared.counter_decrement(counter: self.prefixedMetricName, by: by, group: self.group, extraDimensions: extraDimensions)
    }
    public func reset(_ extraDimensions: [(String, String)]? = nil) async {
        await EHMetrics.shared.counter_reset(counter: self.prefixedMetricName, group: self.group, extraDimensions: extraDimensions)
    }

    public var batchSize: UInt64? { nil }
}

extension EHMetrics.EHMetricDefinitionGaugeProtocol {
    public func set(_ value: Double, extraDimensions: [(String, String)]? = nil) async {
        await EHMetrics.shared.gauge_set(gauge: self.prefixedMetricName, value: value, group: self.group, extraDimensions: extraDimensions)
    }
    public func reset(_ extraDimensions: [(String, String)]? = nil) async {
        await EHMetrics.shared.gauge_reset(gauge: self.prefixedMetricName, group: self.group, extraDimensions: extraDimensions)
    }

    public var sampleRate: UInt64? { nil }
}


public final class PipelineMetricsCache: @unchecked Sendable {
    public static let shared = PipelineMetricsCache()

    private final class AtomicAccumulator: @unchecked Sendable {
        let value = Atomic<UInt64>(0)
    }

    private final class CachedCounter {
        let counter: any EHMetrics.EHCounter
        let accumulator: AtomicAccumulator
        init(counter: any EHMetrics.EHCounter, accumulator: AtomicAccumulator) {
            self.counter = counter
            self.accumulator = accumulator
        }
    }

    private final class CachedGauge {
        let gauge: any EHMetrics.EHGauge
        let sampleCounter: AtomicAccumulator
        init(gauge: any EHMetrics.EHGauge, sampleCounter: AtomicAccumulator) {
            self.gauge = gauge
            self.sampleCounter = sampleCounter
        }
    }

    private let counterLock = NSLock()
    private var counters: [String: CachedCounter] = [:]
    private let gaugeLock = NSLock()
    private var gauges: [String: CachedGauge] = [:]

    private let flushTask: Mutex<Task<Void, Never>?> = Mutex(nil)

    private let _gaugeSampleRate = Atomic<UInt64>(100)
    private let _counterBatchSize = Atomic<UInt64>(100)

    public var gaugeSampleRate: UInt64 {
        get { _gaugeSampleRate.load(ordering: .relaxed) }
        set { _gaugeSampleRate.store(max(1, newValue), ordering: .relaxed) }
    }

    public var counterBatchSize: UInt64 {
        get { _counterBatchSize.load(ordering: .relaxed) }
        set { _counterBatchSize.store(max(1, newValue), ordering: .relaxed) }
    }

    private init() {}


    @inline(__always)
    private static func buildKey(_ metricRawValue: String, _ dimensions: [(String, String)]?) -> String {
        guard let dimensions, !dimensions.isEmpty else {
            return metricRawValue
        }
        var key = metricRawValue
        for (_, value) in dimensions {
            key.append("\0")
            key.append(value)
        }
        return key
    }


    @inline(__always)
    private func cachedCounter(
        _ metric: any EHMetrics.EHMetricDefinitionProtocol,
        key: String,
        dimensions: [(String, String)]?
    ) -> CachedCounter {
        counterLock.lock()
        if let cached = counters[key] {
            counterLock.unlock()
            return cached
        }
        counterLock.unlock()

        let counter = EHMetrics.createCounter(
            label: metric.prefixedMetricName,
            group: EHMetrics.groupWithCategory(metric.group),
            extraDimensions: dimensions
        )
        let entry = CachedCounter(counter: counter, accumulator: AtomicAccumulator())

        counterLock.lock()
        if let cached = counters[key] {
            counterLock.unlock()
            return cached
        }
        counters[key] = entry
        counterLock.unlock()

        return entry
    }

    @inline(__always)
    public func counter(
        _ metric: any EHMetrics.EHMetricDefinitionProtocol,
        dimensions: [(String, String)]?
    ) -> any EHMetrics.EHCounter {
        let key = Self.buildKey(metric.rawValue, dimensions)
        return cachedCounter(metric, key: key, dimensions: dimensions).counter
    }

    @inline(__always)
    public func incrementCounter(
        _ metric: any EHMetrics.EHMetricDefinitionProtocol,
        by value: UInt64 = 1,
        dimensions: [(String, String)]?
    ) {
        counter(metric, dimensions: dimensions).add(value)
    }


    @inline(__always)
    public func incrementCounterBatched(
        _ metric: any EHMetrics.EHMetricDefinitionCounterProtocol,
        by value: UInt64 = 1,
        dimensions: [(String, String)]?
    ) {
        let key = Self.buildKey(metric.rawValue, dimensions)
        let entry = cachedCounter(metric, key: key, dimensions: dimensions)

        let threshold = metric.batchSize ?? counterBatchSize

        let newValue = entry.accumulator.value.wrappingAdd(value, ordering: .relaxed).newValue
        if newValue >= threshold {
            let toFlush = entry.accumulator.value.exchange(0, ordering: .acquiringAndReleasing)
            if toFlush > 0 {
                entry.counter.add(toFlush)
            }
        }
    }


    public func flushPendingCounters() {
        counterLock.lock()
        let entries = Array(counters.values)
        counterLock.unlock()

        for entry in entries {
            let toFlush = entry.accumulator.value.exchange(0, ordering: .acquiringAndReleasing)
            if toFlush > 0 {
                entry.counter.add(toFlush)
            }
        }
    }

    public func startPeriodicFlush(intervalSeconds: Int) {
        guard intervalSeconds > 0 else {
            return
        }
        flushTask.withLock { slot in
            slot?.cancel()
            slot = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(intervalSeconds))
                    } catch {
                        return
                    }
                    self?.flushPendingCounters()
                }
            }
        }
    }

    public func stopPeriodicFlush() {
        flushTask.withLock { slot in
            slot?.cancel()
            slot = nil
        }
    }


    @inline(__always)
    private func cachedGauge(
        _ metric: any EHMetrics.EHMetricDefinitionProtocol,
        key: String,
        dimensions: [(String, String)]?
    ) -> CachedGauge {
        gaugeLock.lock()
        if let cached = gauges[key] {
            gaugeLock.unlock()
            return cached
        }
        gaugeLock.unlock()

        let gauge = EHMetrics.createGauge(
            label: metric.prefixedMetricName,
            group: EHMetrics.groupWithCategory(metric.group),
            extraDimensions: dimensions
        )
        let entry = CachedGauge(gauge: gauge, sampleCounter: AtomicAccumulator())

        gaugeLock.lock()
        if let cached = gauges[key] {
            gaugeLock.unlock()
            return cached
        }
        gauges[key] = entry
        gaugeLock.unlock()

        return entry
    }

    @inline(__always)
    public func gauge(
        _ metric: any EHMetrics.EHMetricDefinitionProtocol,
        dimensions: [(String, String)]?
    ) -> any EHMetrics.EHGauge {
        let key = Self.buildKey(metric.rawValue, dimensions)
        return cachedGauge(metric, key: key, dimensions: dimensions).gauge
    }

    @inline(__always)
    public func setGauge(
        _ metric: any EHMetrics.EHMetricDefinitionProtocol,
        value: Double,
        dimensions: [(String, String)]?
    ) {
        gauge(metric, dimensions: dimensions).set(value)
    }

    @inline(__always)
    public func setGaugeSampled(
        _ metric: any EHMetrics.EHMetricDefinitionGaugeProtocol,
        value: Double,
        dimensions: [(String, String)]?
    ) {
        let rate = max(1, metric.sampleRate ?? gaugeSampleRate)

        let key = Self.buildKey(metric.rawValue, dimensions)
        let entry = cachedGauge(metric, key: key, dimensions: dimensions)

        let count = entry.sampleCounter.value.wrappingAdd(1, ordering: .relaxed).newValue
        if count % rate == 0 {
            entry.gauge.set(value)
        }
    }


    @inline(__always)
    public func increment(
        _ metric: any EHMetrics.EHMetricDefinitionCounterProtocol,
        by value: UInt64 = 1,
        dimensions: [(String, String)]?
    ) {
        if metric.batchSize != nil {
            incrementCounterBatched(metric, by: value, dimensions: dimensions)
        } else {
            incrementCounter(metric, by: value, dimensions: dimensions)
        }
    }

    @inline(__always)
    public func set(
        _ metric: any EHMetrics.EHMetricDefinitionGaugeProtocol,
        value: Double,
        dimensions: [(String, String)]?
    ) {
        if metric.sampleRate != nil {
            setGaugeSampled(metric, value: value, dimensions: dimensions)
        } else {
            setGauge(metric, value: value, dimensions: dimensions)
        }
    }


    #if !os(Linux)
    func exportCounterValues() -> [(label: String, dimensions: [EHMetrics.SendableDimension], value: UInt64)] {
        var result: [(label: String, dimensions: [EHMetrics.SendableDimension], value: UInt64)] = []
        counterLock.lock()
        for (_, entry) in counters {
            let pending = entry.accumulator.value.exchange(0, ordering: .acquiringAndReleasing)
            if pending > 0 {
                entry.counter.add(pending)
            }
            if let m = entry.counter as? EHMetrics.EHMetricCounter {
                result.append((m.label, m.dimensions, m.value))
            }
        }
        counterLock.unlock()
        return result
    }

    func exportGaugeValues() -> [(label: String, dimensions: [EHMetrics.SendableDimension], value: Double)] {
        var result: [(label: String, dimensions: [EHMetrics.SendableDimension], value: Double)] = []
        gaugeLock.lock()
        for (_, entry) in gauges {
            if let m = entry.gauge as? EHMetrics.EHMetricGauge {
                result.append((m.label, m.dimensions, m.value))
            }
        }
        gaugeLock.unlock()
        return result
    }
    #endif
}
