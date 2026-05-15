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

import Foundation
#if canImport(os)
@_spi(OSMetric)
import os
#endif
import Synchronization

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

    private let log = EHLog.withCategory(EHMetrics.self)
    private var groups: [String: any EHMetricGroupProtocol] = [:]
    private var counters: [String: any EHCounter] = [:]
    private var gauges: [String: any EHGauge] = [:]

    private func metricKey(base: String, extraDimensions: [(String, String)]? = nil) -> String {
        guard let extraDimensions else {
            return base
        }
        let dimensionsString = extraDimensions.map { "\($0.0)=\($0.1)" }.sorted().joined(separator: ",")
        return "\(base)_\(dimensionsString)"
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
        if !EHMetrics.supportsOSMetrics() {
            Task {
                repeat {
                    try? await Task.sleep(for: .seconds(10))
                    await EHMetrics.shared.dumpValues()
                } while true
            }
        }
    }

    public func addGroup(_ group: String) {
        self.groups[group] = EHMetrics.groupWithCategory(group)
    }

    public func addCounter(label: String, group: String, extraDimensions: [(String, String)]? = nil) {
        self.counters[label] = EHMetrics.createCounter(label: label, group: groups[group]!, extraDimensions: extraDimensions)
    }

    public func addGauge(label: String, group: String, extraDimensions: [(String, String)]? = nil) {
        self.gauges[label] = EHMetrics.createGauge(label: label, group: groups[group]!, extraDimensions: extraDimensions)
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
    private static func supportsOSMetrics() -> Bool {
        guard #available(macOS 16, iOS 19.0, watchOS 12.0, tvOS 19.0, *) else {
            return false
        }
        return true
    }

    public static let shared = EHMetrics()
    public static func groupWithCategory(_ category: String) -> EHMetricGroupProtocol {
        #if canImport(LoggingSupport, _version: 1788)
            if #available(macOS 16, iOS 19.0, watchOS 12.0, tvOS 19.0, *) {
                return OSMetricGroup(subsystem: EventHorizonKit.framework_name, category: category)
            }
        #endif
        return EHMetricGroup(subsystem: EventHorizonKit.framework_name, category: category)
    }

    public static func createCounter(label: String, group: any EHMetricGroupProtocol, extraDimensions: [(String, String)]? = nil) -> any EHCounter {
        let dimensions = extraDimensions != nil ? extraDimensions! + EHMetrics.defaultDimensions() : EHMetrics.defaultDimensions()
        #if canImport(LoggingSupport, _version: 1788)
            if #available(macOS 16, iOS 19.0, watchOS 12.0, tvOS 19.0, *) {
                return OSMetricCounter(type: UInt64.self,
                                                group: group as? OSMetricGroup ?? OSMetricGroup(subsystem: EventHorizonKit.framework_name, category: "default"),
                                                label: label,
                                                extraDimensions: OSMetricDimensions(values: dimensions)
                                        )
            }
        #endif
        return EHMetricCounter(label: label, group: group, dimensions: dimensions)
    }

    public static func createGauge(label: String, group: any EHMetricGroupProtocol, extraDimensions: [(String, String)]? = nil) -> any EHGauge {
        let dimensions = extraDimensions != nil ? extraDimensions! + EHMetrics.defaultDimensions() : EHMetrics.defaultDimensions()
        #if canImport(LoggingSupport, _version: 1788)
            if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *) {
                return OSMetricGauge(type: Double.self,
                                        group: group as? OSMetricGroup ?? OSMetricGroup(subsystem: EventHorizonKit.framework_name, category: "default"),
                                        label: label,
                                        extraDimensions: OSMetricDimensions(values: dimensions)
                                        )
            }
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
        let ivalue: Mutex<UInt64> = .init(0)
        let label: String
        let group: any EHMetricGroupProtocol
        let dimensions: [SendableDimension]
        init (label: String = "", group: any EHMetricGroupProtocol, dimensions: [(String, String)] = []) {
            self.label = label
            self.group = group
            self.dimensions = dimensions.map { SendableDimension(name: $0.0, value: $0.1) }
        }

        var value: UInt64 {
            self.ivalue.withLock { $0 }
        }

        func add(_ value: UInt64) {
            self.ivalue.withLock { $0 += value }
        }

        func subtract(_ value: UInt64) {
            self.ivalue.withLock { $0 -= value }
        }

        func reset() {
            self.ivalue.withLock { $0 = 0 }
        }

        func increment() {
            self.ivalue.withLock { $0 += 1 }
        }

        func decrement() {
            self.ivalue.withLock { $0 -= 1 }
        }
    }
    struct SendableDimension: Codable, Sendable {
        let name: String
        let value: String
    }

    final class EHMetricGauge: EHGauge, Sendable {
        let ivalue: Mutex<Double> = .init(0)
        let label: String
        let group: any EHMetricGroupProtocol
        let dimensions: [SendableDimension]
        init (label: String = "", group: any EHMetricGroupProtocol, dimensions: [(String, String)] = []) {
            self.label = label
            self.group = group
            self.dimensions = dimensions.map { SendableDimension(name: $0.0, value: $0.1) }
        }
        var value: Double {
            self.ivalue.withLock { $0 }
        }

        func reset() {
            self.ivalue.withLock { $0 = 0 }
        }

        func set(_ value: Double) {
            self.ivalue.withLock { $0 = value }
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
    }

    public protocol EHMetricDefinitionGaugeProtocol: EHMetricDefinitionProtocol {
        func set(_ value: Double, extraDimensions: [(String, String)]?) async
        func reset(_ extraDimensions: [(String, String)]?) async
    }

    public protocol EHMetricConfigProtocol {
        associatedtype _counters: EHMetricDefinitionProtocol
        associatedtype _gauges: EHMetricDefinitionProtocol
    }
}
extension EHMetrics.EHMetricDefinitionProtocol {
    public var prefixedMetricName: String {
        "\(EHMetrics.label_prefix)_\(self.rawValue)"
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
    public var group: String {
        return self.rawValue.contains("_") ? self.rawValue.components(separatedBy: "_").first! : "default"
    }
}

extension EHMetrics.EHMetricDefinitionGaugeProtocol {
    public func set(_ value: Double, extraDimensions: [(String, String)]? = nil) async {
        await EHMetrics.shared.gauge_set(gauge: self.prefixedMetricName, value: value, group: self.group, extraDimensions: extraDimensions)
    }
    public func reset(_ extraDimensions: [(String, String)]? = nil) async {
        await EHMetrics.shared.gauge_reset(gauge: self.prefixedMetricName, group: self.group, extraDimensions: extraDimensions)
    }
    public var group: String {
        return self.rawValue.contains("_") ? self.rawValue.components(separatedBy: "_").first! : "default"
    }

}
