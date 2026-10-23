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

/* swift tabwidth="4" prefertabs="false" */
//
//  MetricsFilter.swift
//  CloudMetricsDaemon
//
//  Created by Andrea Guzzo on 10/24/23.
//

package import CloudMetricsXPC
import Foundation
internal import os
#if canImport(SecureConfigDB)
@_weakLinked private import SecureConfigDB
#endif

package final class MetricsFilter: Sendable {
    internal enum LogEventType {
        case onRecord
        case onPublish
    }

    internal final class FrequencyTracker: Sendable {
        private struct State {
            fileprivate var lastUpdated: [String: Date] = [:]
            fileprivate var lastPublished: [String: Date] = [:]
            fileprivate var recordedSincePublish: [String: Int] = [:]
            fileprivate var loggedMetrics: [String: [LogEventType: ContinuousClock.Instant]] = [:]
            fileprivate var logThrottleInterval: Duration
            fileprivate var bucketCountsSincePublish: [String: [Int]] = [:]
            // Persistent threshold noise for the AboveThreshold mechanism (CHANGEDv3).
            // Double.nan marks a bucket slot that has not been sampled yet.
            fileprivate var threshNoise: [String: [Double]] = [:]
        }

        private let state: OSAllocatedUnfairLock<State>
        private let logger = Logger(subsystem: "MetricsFilter", category: "FrequencyTracker")

        internal init(logThrottleInterval: Duration) {
            self.state = .init(initialState: .init(logThrottleInterval: logThrottleInterval))
        }

        internal func lastUpdated(_ metricName: String) -> Date {
            let lastUpdated = self.state.withLock { $0.lastUpdated[metricName] }
            return lastUpdated ?? Date.distantPast
        }

        internal func lastPublished(_ metricName: String) -> Date {
            let lastPublished = self.state.withLock { $0.lastPublished[metricName] }
            return lastPublished ?? Date.distantPast
        }

        internal func recordUpdate(_ metricName: String) {
            self.state.withLock { state in state.lastUpdated[metricName] = Date.now }
        }

        internal func recordPublish(_ metricName: String) {
            self.state.withLock { state in state.lastPublished[metricName] = Date.now }
        }

        internal func incrementRecordedCount(_ key: String) {
            self.state.withLock { state in
                state.recordedSincePublish[key] = (state.recordedSincePublish[key] ?? 0) + 1
            }
        }

        internal func recordedCount(_ key: String) -> Int {
            self.state.withLock { $0.recordedSincePublish[key] ?? 0 }
        }

        internal func resetRecordedCount(_ key: String) {
            self.state.withLock { state in state.recordedSincePublish[key] = 0 }
        }

        /// Increments the per-bucket record count for the given key since last publish.
        internal func incrementBucketCount(_ key: String, bucket: Int) {
            self.state.withLock { state in
                var counts = state.bucketCountsSincePublish[key] ?? []
                while counts.count <= bucket { counts.append(0) }
                counts[bucket] += 1
                state.bucketCountsSincePublish[key] = counts
            }
        }

        /// Returns the number of records in the given bucket since last publish.
        internal func bucketCount(_ key: String, bucket: Int) -> Int {
            self.state.withLock { state in
                guard let counts = state.bucketCountsSincePublish[key], bucket < counts.count else { return 0 }
                return counts[bucket]
            }
        }

        /// Returns the persistent thresh_noise for the given bucket, sampling it lazily on first access.
        ///
        /// Uses Double.nan as a sentinel for "not yet initialised". All writes happen inside the lock
        /// so concurrent readers always see a fully-formed array.
        internal func getOrInitThreshNoise(_ key: String, bucket: Int, sigma: Double, bucketCount: Int) -> Double {
            state.withLock { state in
                guard bucket < bucketCount else { return Double.nan }
                var values = state.threshNoise[key] ?? [Double](repeating: Double.nan, count: bucketCount)
                while values.count <= bucket { values.append(Double.nan) }
                if values[bucket].isNaN {
                    values[bucket] = laplaceRandom(scale: sigma)
                    state.threshNoise[key] = values  // only write when a slot is newly sampled
                }
                return values[bucket]
            }
        }

        /// Atomically resets per-bucket counts and resamples thresh_noise for the next epoch.
        ///
        /// Both mutations share a single lock acquisition so no concurrent reader can observe
        /// zeroed bucket counts paired with stale thresh_noise from the previous epoch.
        internal func resetBucketCountsAndResampleThreshNoise(_ key: String, threshNoiseSigmas: [Double]) {
            state.withLock { state in
                state.bucketCountsSincePublish.removeValue(forKey: key)
                // Only touch threshNoise for Laplace metrics (non-empty sigmas).
                // Writing [] for deterministic metrics would corrupt the nil-means-uninitialised sentinel.
                guard !threshNoiseSigmas.isEmpty else { return }
                state.threshNoise[key] = threshNoiseSigmas.map { laplaceRandom(scale: $0) }
            }
        }

        /// Returns the current thresh_noise array, or nil if no bucket has been sampled yet.
        internal func threshNoiseValues(_ key: String) -> [Double]? {
            state.withLock { state in
                guard let values = state.threshNoise[key],
                      !values.contains(where: { $0.isNaN }) else { return nil }
                return values
            }
        }

        /// Overwrites thresh_noise with caller-supplied values. Use in tests only.
        internal func setThreshNoise(_ key: String, values: [Double]) {
            state.withLock { state in state.threshNoise[key] = values }
        }

        // Laplace random — same algorithm as AggregateReader.laplaceRandom.
        private func laplaceRandom(scale: Double) -> Double {
            guard scale > 0 else { return 0 }
            let u = Double.random(in: (-0.5 + Double.ulpOfOne)..<0.5)
            return -scale * (u < 0 ? -1.0 : 1.0) * log(1.0 - 2.0 * abs(u))
        }

        internal func shouldLog(_ metricName: String, _ logEvent: LogEventType) -> Bool {
            self.state.withLock { state in
                var shouldLog = true
                if let record = state.loggedMetrics[metricName] {
                    if let when = record[logEvent] {
                        if when.duration(to: .now) < state.logThrottleInterval {
                            shouldLog = false
                        }
                    }
                    if shouldLog {
                        var updatedRecord = record
                        updatedRecord[logEvent] = .now
                        state.loggedMetrics[metricName] = updatedRecord
                    }
                } else {
                    state.loggedMetrics[metricName] = [logEvent: .now]
                }
                return shouldLog
            }
        }
    }

    private typealias ClientName = String
    private typealias MetricName = String

    private let allowList: [ClientName: [MetricName: Configuration.FilterRule]]
    private let allMetricsByName: [String: [Configuration.FilterRule]]
    private let ignoreList: [ClientName: [MetricName]]
    private let allIgnoredMetrics: [MetricName]
    private let logger = Logger(subsystem: "MetricsFilter", category: "RuleChecker")
    private let globalDimensions: [String]
    private let disabled: Bool
    private let frequencyTracker: FrequencyTracker

    package init(configuration: Configuration) {
        self.allowList = configuration.auditLists?.allowedMetrics.reduce(
            into: [ClientName: [MetricName: Configuration.FilterRule]]()
        ) { result, rule in
            if result[rule.client] != nil {
                result[rule.client]?[rule.label] = rule
            } else {
                result[rule.client] = [rule.label: rule]
            }
        } ?? [:]
        self.allMetricsByName = self.allowList.values.reduce(
            into: [String: [Configuration.FilterRule]]()
        ) { result, rules in
            for (_, rule) in rules {
                if result[rule.label] != nil {
                    result[rule.label]?.append(rule)
                } else {
                    result[rule.label] = [rule]
                }
            }
        }

        self.ignoreList = configuration.auditLists?.ignoredMetrics ?? [:]
        self.allIgnoredMetrics = self.ignoreList.values.flatMap { $0 }

        self.globalDimensions = configuration.globalLabels.keys.sorted()
        // Check if allow lists are disabled from the configuration
        var enableFiltering = true
        do {
            if #_hasSymbol(SecureConfigParameters.self) {
                if let filteringEnforced = try SecureConfigParameters.loadContents().metricsFilteringEnforced {
                    enableFiltering = filteringEnforced
                } else {
                    enableFiltering = configuration.requireAllowList
                }
            } else {
                // if metricsFilteringEnforced is not available in secure config, disable the metrics filtering
                enableFiltering = configuration.requireAllowList
            }
        } catch {
            self.logger
                .error("Can't access `metricsFilteringEnforced` in SecureConfigParameters: \(error, privacy: .public)")
            #if DEBUG
            // In DEBUG, in case there is no SecureConfig setting available,
            // we still want to enable filtering if there is an allow list defined
            // in order to support development/testing
            enableFiltering = !self.allowList.isEmpty
            #else
            enableFiltering = configuration.requireAllowList
            #endif
        }

        // Check if we got an "Allow-All" list (any client can send any metric)
        if self.allowList["*"] != nil {
            enableFiltering = false
        }
        self.disabled = !enableFiltering
        self.frequencyTracker = FrequencyTracker(logThrottleInterval: configuration.auditLogThrottleInterval)
    }

    package func shouldRecord(metric: CloudMetric, client: MetricsClient) -> Bool {
        let metricName = metric.label

        if self.disabled {
            return true
        }

        // Check if the allow list is allowing any metric
        // (either for any client or for this specific one)
        if self.allowList["*"] != nil || self.allowList[client.name]?["*"] != nil {
            return true
        }

        guard let rule = allowList[client.name]?[metricName] else {
            var ignore = false
            if let ignoreList = self.ignoreList[client.name] {
                ignore = ignoreList.contains(metric.label)
            }
            if !ignore {
                self.logUnauditedRecord(
                    metricName: metricName,
                    type: metric.type,
                    dimensionCount: metric.dimensions.count,
                    client: client
                )
            }
            return false
        }

        guard rule.type == metric.type || rule.type == .all else {
            self.logTypeMismatch(metricName: metricName, type: metric.type, rule: rule, client: client)
            return false
        }

        let dimensions = self.classifyDimensions(of: metric, against: rule)
        if dimensions.hasUnauditedDimensions {
            self.logUnauditedDimensions(
                metricName: metricName,
                type: metric.type,
                dimensions: dimensions,
                rule: rule,
                client: client
            )
            return false
        }

        let lastUpdate = self.frequencyTracker.lastUpdated(metricName)
        if rule.minUpdateInterval > .seconds(0),
           lastUpdate.timeIntervalSinceNow < Double(rule.minUpdateInterval.components.seconds) {
            // TODO: rdar://119687218 (Find a way to implement this by aggregating
            // values before recording them in the MetricStore)
            self.logUpdatedTooFrequently(
                metricName: metricName,
                lastUpdate: lastUpdate,
                rule: rule,
                client: client
            )
        }
        self.frequencyTracker.recordUpdate(metricName)
        return true
    }

    /// Splits a metric's non-global dimensions by how they compare with the audit list.
    ///
    /// Every dimension is classified before the caller decides, so a rejection can report the
    /// dimensions that did match alongside the ones that failed. Returning on the first failure
    /// would make the log depend on dictionary iteration order.
    private func classifyDimensions(of metric: CloudMetric, against rule: Configuration.FilterRule)
        -> ClassifiedDimensions {
        var classified = ClassifiedDimensions()
        let dimensions = metric.dimensions.filter { !self.globalDimensions.contains($0.key) }
        for (key, value) in dimensions {
            // if dimensions are being mentioned in the rule,
            // all non-global dimensions for this metric need to be present
            guard let valuesList = rule.dimensions[key] else {
                classified.unaudited.append(key)
                continue
            }
            // if possible values are defined, the dimension value must also be included
            if valuesList.isEmpty {
                classified.unrestricted.append(key)
            } else if valuesList.contains(value) {
                classified.matched.append("\(key)=\(value)")
            } else {
                classified.withUnauditedValue.append(key)
            }
        }
        return classified
    }

    package func shouldPublish(metricName: String, destination: Configuration.Destination) -> Bool {
        if self.disabled {
            return true
        }

        // TODO: rdar://125978998 (We should preserve a link to the client in metrics recorded in the MetricsStore)
        if self.allMetricsByName["*"] != nil {
            return true
        }

        guard let rules = allMetricsByName[metricName] else {
            if !self.allIgnoredMetrics.contains(metricName) {
                self.logUnauditedPublish(metricName: metricName, destination: destination)
            }
            return false
        }

        let destinations = rules.flatMap { $0.destinations }
        if !destinations.isEmpty && !destinations.contains(destination) {
            self.logUnauditedDestination(
                metricName: metricName,
                destination: destination,
                auditedDestinations: destinations
            )
            return false
        }

        for rule in rules {
            // Note: if there are more rules matching this same metric name
            // (let's say coming from different clients) this will actually
            // apply the strictest interval among the all the matching rules
            let lastPublished = self.frequencyTracker.lastPublished(metricName)
            if rule.minPublishInterval > .seconds(0),
               Date.now.timeIntervalSince(lastPublished) < TimeInterval(rule.minPublishInterval.components.seconds) {
                self.logPublishedTooFrequently(
                    metricName: metricName,
                    destination: destination,
                    lastPublished: lastPublished,
                    rule: rule
                )
                return false
            }
        }
        self.frequencyTracker.recordPublish(metricName)
        return true
    }

    package func isAggregateOnNode(for metricLabel: String, client clientName: String) -> Bool {
        allowList[clientName]?[metricLabel]?.aggregateOnNode ?? false
    }

    package func laplaceNoiseInjection(for metricLabel: String, client clientName: String) -> Configuration.LaplaceNoiseInjection? {
        allowList[clientName]?[metricLabel]?.laplaceNoiseInjection
    }

    /// Records that one observation fell into the given histogram bucket (Laplace noise path only).
    package func incrementBucketCount(metricLabel: String, clientName: String, bucket: Int) {
        frequencyTracker.incrementBucketCount("\(clientName)::\(metricLabel)", bucket: bucket)
    }

    /// Returns accumulated observations in the given histogram bucket since the last publish.
    package func bucketCount(metricLabel: String, clientName: String, bucket: Int) -> Int {
        frequencyTracker.bucketCount("\(clientName)::\(metricLabel)", bucket: bucket)
    }

    /// Returns true if the minimum publish interval has elapsed since the last collect for this metric.
    package func meetsPublishInterval(clientName: String, metricLabel: String) -> Bool {
        guard let rule = allowList[clientName]?[metricLabel], rule.aggregateOnNode else { return false }
        let key = "\(clientName)::\(metricLabel)"
        let lastPublished = frequencyTracker.lastPublished(key)
        guard rule.minPublishInterval > .seconds(0) else { return true }
        return Date.now.timeIntervalSince(lastPublished) >= TimeInterval(rule.minPublishInterval.components.seconds)
    }

    package func incrementRecordedCount(metricLabel: String, clientName: String) {
        frequencyTracker.incrementRecordedCount("\(clientName)::\(metricLabel)")
    }

    /// Returns true if the (client, label) pair is eligible for a deterministic collect-and-publish.
    ///
    /// **No `disabled` guard**: unlike `shouldRecord`/`shouldPublish`, this method intentionally
    /// does not short-circuit when `self.disabled` is true. Aggregate collection is driven by
    /// explicit `aggregateOnNode` configuration. When filtering is disabled and the allowList is
    /// empty, `AggregateStoreProvider` never creates entries (because `isAggregateOnNode` requires
    /// the rule to exist), so this method is never called for a metric without a rule.
    ///
    /// **TOCTOU**: `shouldCollect` and `recordCollect` are separate calls, but concurrent
    /// invocations are not possible in practice — `AggregateReader` runs a single linear async
    /// loop and is the only caller. Even in the hypothetical case of two concurrent callers, the
    /// OTEL delta store acts as a backstop: after the first `collect()` drains the delta, the
    /// second call returns empty and the `guard !metrics.isEmpty` check prevents a duplicate
    /// publish.
    package func shouldCollect(clientName: String, metricLabel: String) -> Bool {
        guard let rule = allowList[clientName]?[metricLabel], rule.aggregateOnNode else {
            return false
        }
        let key = "\(clientName)::\(metricLabel)"
        let lastPublished = frequencyTracker.lastPublished(key)
        if rule.minPublishInterval > .seconds(0) {
            guard Date.now.timeIntervalSince(lastPublished) >= TimeInterval(rule.minPublishInterval.components.seconds) else {
                return false
            }
        }
        if rule.minPublishCount > 0 {
            guard frequencyTracker.recordedCount(key) >= rule.minPublishCount else {
                return false
            }
        }
        return true
    }

    package func recordCollect(clientName: String, metricLabel: String) {
        let key = "\(clientName)::\(metricLabel)"
        frequencyTracker.recordPublish(key)
        frequencyTracker.resetRecordedCount(key)
        // Reset bucket counts and resample thresh_noise atomically (AboveThreshold — CHANGEDv3).
        let threshNoiseSigmas = allowList[clientName]?[metricLabel]?.laplaceNoiseInjection?
            .buckets.map { $0.noiseSigmaThreshold } ?? []
        frequencyTracker.resetBucketCountsAndResampleThreshNoise(key, threshNoiseSigmas: threshNoiseSigmas)
    }

    /// Returns the persistent thresh_noise for the given bucket, initialising it lazily on first call.
    package func threshNoise(metricLabel: String, clientName: String, bucket: Int) -> Double {
        guard let noiseConfig = allowList[clientName]?[metricLabel]?.laplaceNoiseInjection,
              bucket < noiseConfig.buckets.count else { return 0 }
        let key = "\(clientName)::\(metricLabel)"
        return frequencyTracker.getOrInitThreshNoise(
            key,
            bucket: bucket,
            sigma: noiseConfig.buckets[bucket].noiseSigmaThreshold,
            bucketCount: noiseConfig.buckets.count
        )
    }

    /// Returns current thresh_noise values for all buckets, or nil if not yet initialised.
    /// Intended for tests only.
    internal func threshNoiseValues(metricLabel: String, clientName: String) -> [Double]? {
        frequencyTracker.threshNoiseValues("\(clientName)::\(metricLabel)")
    }

    /// Directly sets thresh_noise to supplied values. Use in tests only.
    internal func setThreshNoiseForTesting(_ values: [Double], metricLabel: String, clientName: String) {
        frequencyTracker.setThreshNoise("\(clientName)::\(metricLabel)", values: values)
    }
}

// MARK: - Audit list diagnostics

/// Formatting of the audit list rejection logs.
///
/// A rejection is a configuration outcome rather than a daemon failure, so these are logged below
/// the error level. Each message is a static sentence followed by `key=value` pairs, starting with
/// a `reason` that identifies the check that failed.
///
/// Privacy follows the audit list: a metric label, dimension key or dimension value that appears in
/// the list has been audited and is logged publicly, and anything absent from it stays private. Each
/// message therefore reports what the audit list *does* permit, which is what makes a redacted line
/// actionable. All of these are throttled per label by `FrequencyTracker`.
extension MetricsFilter {
    /// A metric's non-global dimensions, split by how they compare with the audit list.
    internal struct ClassifiedDimensions {
        /// `key=value` for dimensions whose value is in the rule's audited values.
        internal var matched: [String] = []
        /// Keys the rule audits without restricting the value, so the value is unaudited.
        internal var unrestricted: [String] = []
        /// Audited keys carrying a value that is not in the rule's audited values.
        internal var withUnauditedValue: [String] = []
        /// Keys that are absent from the rule entirely.
        internal var unaudited: [String] = []

        internal var hasUnauditedDimensions: Bool {
            !self.unaudited.isEmpty || !self.withUnauditedValue.isEmpty
        }
    }

    /// Logs that a client is not audited to record a metric at all.
    ///
    /// A label that appears anywhere in the audit list has itself been audited, so it is logged
    /// publicly along with the clients it *is* audited for — which turns the common "allow-listed
    /// under the wrong client" mistake into an actionable line. A label that appears nowhere in the
    /// list stays private, leaving only the shape of the metric.
    private func logUnauditedRecord(
        metricName: String,
        type: CloudMetricType,
        dimensionCount: Int,
        client: MetricsClient
    ) {
        guard self.frequencyTracker.shouldLog(metricName, .onRecord) else {
            return
        }
        let auditedClients = Set(self.allMetricsByName[metricName]?.map { $0.client } ?? []).sorted()
        if auditedClients.isEmpty {
            self.logger.log("""
            Not recording a metric that is missing from the audit list \
            reason=labelNotAudited \
            client=\(client.name, privacy: .public) \
            process=\(client.remoteProcess, privacy: .public) \
            type=\(type, privacy: .public) \
            dimensionCount=\(dimensionCount, privacy: .public) \
            label=\(metricName, privacy: .private)
            """)
        } else {
            self.logger.log("""
            Not recording a metric that is only audited for other clients \
            reason=labelAuditedForOtherClients \
            client=\(client.name, privacy: .public) \
            process=\(client.remoteProcess, privacy: .public) \
            type=\(type, privacy: .public) \
            auditedClients=\(auditedClients.joined(separator: ","), privacy: .public) \
            label=\(metricName, privacy: .public)
            """)
        }
    }

    /// Logs that an audited label was recorded with a type the audit list doesn't allow.
    private func logTypeMismatch(
        metricName: String,
        type: CloudMetricType,
        rule: Configuration.FilterRule,
        client: MetricsClient
    ) {
        guard self.frequencyTracker.shouldLog(metricName, .onRecord) else {
            return
        }
        self.logger.log("""
        Not recording a metric whose type does not match the audit list \
        reason=typeMismatch \
        client=\(client.name, privacy: .public) \
        process=\(client.remoteProcess, privacy: .public) \
        type=\(type, privacy: .public) \
        auditedType=\(rule.type, privacy: .public) \
        label=\(metricName, privacy: .public)
        """)
    }

    /// Logs that an audited label was recorded with dimensions the audit list doesn't allow.
    ///
    /// The label is audited, so it is public, as are the dimensions that did match — together they
    /// show how far the metric got before being rejected. `reason` names the stricter of the two
    /// failures; both failure fields are always present, since a metric can hit both at once.
    private func logUnauditedDimensions(
        metricName: String,
        type: CloudMetricType,
        dimensions: ClassifiedDimensions,
        rule: Configuration.FilterRule,
        client: MetricsClient
    ) {
        guard self.frequencyTracker.shouldLog(metricName, .onRecord) else {
            return
        }
        let reason = dimensions.unaudited.isEmpty ? "dimensionValueNotAudited" : "dimensionNotAudited"
        self.logger.log("""
        Not recording a metric whose dimensions are not in the audit list \
        reason=\(reason, privacy: .public) \
        client=\(client.name, privacy: .public) \
        process=\(client.remoteProcess, privacy: .public) \
        label=\(metricName, privacy: .public) \
        type=\(type, privacy: .public) \
        matchedDimensions=\(dimensions.matched.sorted().joined(separator: ","), privacy: .public) \
        unrestrictedDimensions=\(dimensions.unrestricted.sorted().joined(separator: ","), privacy: .public) \
        dimensionsWithUnauditedValue=\(dimensions.withUnauditedValue.sorted().joined(separator: ","), privacy: .public) \
        auditedDimensions=\(rule.dimensions.keys.sorted().joined(separator: ","), privacy: .public) \
        unauditedDimensions=\(dimensions.unaudited.sorted().joined(separator: ","), privacy: .private)
        """)
    }

    /// Logs that an audited label is being recorded faster than its rule allows.
    ///
    /// `enforced=false`: the record is kept regardless, pending rdar://119687218.
    private func logUpdatedTooFrequently(
        metricName: String,
        lastUpdate: Date,
        rule: Configuration.FilterRule,
        client: MetricsClient
    ) {
        guard self.frequencyTracker.shouldLog(metricName, .onRecord) else {
            return
        }
        self.logger.log("""
        Recording a metric that is updating more frequently than the audit list allows \
        reason=updatedTooFrequently \
        client=\(client.name, privacy: .public) \
        process=\(client.remoteProcess, privacy: .public) \
        label=\(metricName, privacy: .public) \
        minUpdateInterval=\(rule.minUpdateInterval, privacy: .public) \
        secondsSinceLastUpdate=\(-lastUpdate.timeIntervalSinceNow, privacy: .public) \
        enforced=false
        """)
    }

    /// Logs that a metric in the store is not audited for publication by any client.
    ///
    /// There is no client attribution here: the store does not preserve the recording client
    /// (rdar://125978998). The label is absent from the audit list, so it stays private.
    private func logUnauditedPublish(metricName: String, destination: Configuration.Destination) {
        guard self.frequencyTracker.shouldLog(metricName, .onPublish) else {
            return
        }
        self.logger.log("""
        Not publishing a metric that is missing from the audit list \
        reason=labelNotAudited \
        destination=\(destination, privacy: .public) \
        label=\(metricName, privacy: .private)
        """)
    }

    /// Logs that an audited label is not audited for this particular destination.
    private func logUnauditedDestination(
        metricName: String,
        destination: Configuration.Destination,
        auditedDestinations: [Configuration.Destination]
    ) {
        guard self.frequencyTracker.shouldLog(metricName, .onPublish) else {
            return
        }
        self.logger.log("""
        Not publishing a metric to a destination that is not in the audit list \
        reason=destinationNotAudited \
        destination=\(destination, privacy: .public) \
        auditedDestinations=\(auditedDestinations.map { "\($0)" }.joined(separator: ","), privacy: .public) \
        label=\(metricName, privacy: .public)
        """)
    }

    /// Logs that an audited label is being published faster than its rule allows.
    private func logPublishedTooFrequently(
        metricName: String,
        destination: Configuration.Destination,
        lastPublished: Date,
        rule: Configuration.FilterRule
    ) {
        self.logger.log("""
        Not publishing a metric that is publishing more frequently than the audit list allows \
        reason=publishedTooFrequently \
        destination=\(destination, privacy: .public) \
        label=\(metricName, privacy: .public) \
        minPublishInterval=\(rule.minPublishInterval, privacy: .public) \
        secondsSinceLastPublish=\(Date.now.timeIntervalSince(lastPublished), privacy: .public)
        """)
    }
}
