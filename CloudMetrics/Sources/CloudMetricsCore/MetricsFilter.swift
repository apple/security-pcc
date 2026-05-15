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
            fileprivate var loggedMetrics: [String: [LogEventType: ContinuousClock.Instant]] = [:]
            fileprivate var logThrottleInterval: Duration
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
                if self.frequencyTracker.shouldLog(metricName, .onRecord) {
                    self.logger
                        .error(
                            "\(client.name, privacy: .public) is trying to record an unaudited metric: '\(metricName, privacy: .private)'"
                        )
                }
            }
            return false
        }

        guard rule.type == metric.type || rule.type == .all else {
            if self.frequencyTracker.shouldLog(metricName, .onRecord) {
                self.logger.error("""
                Metric '\(metricName, privacy: .public)' of type '\(metric.type, privacy: .public)' \
                doesn't match the allowed type: '\(String(describing: rule.type), privacy: .public)'
                """)
            }
            return false
        }

        let dimensions = metric.dimensions.filter { !self.globalDimensions.contains($0.key) }
        for dimension in dimensions {
            // if dimensions are being mentioned in the rule,
            // all non-global dimensions for this metric need to be present
            if let valuesList = rule.dimensions[dimension.key] {
                // if possible values are defined, the dimension value must also be included
                if !valuesList.isEmpty, !valuesList.contains(dimension.1) {
                    if self.frequencyTracker.shouldLog(metricName, .onRecord) {
                        self.logger.error("""
                        Dimension '\(dimension.0, privacy: .public)' in Metric '\(metricName, privacy: .public)' \
                        contains a not allowed value \(dimension.1, privacy: .private)
                        """)
                    }
                    return false
                }
            } else {
                if self.frequencyTracker.shouldLog(metricName, .onRecord) {
                    self.logger.error("Metric '\(metricName, privacy: .public)' contains unaudited dimensions")
                }
                return false
            }
        }

        let lastUpdate = self.frequencyTracker.lastUpdated(metricName)
        if rule.minUpdateInterval > .seconds(0),
           lastUpdate.timeIntervalSinceNow < Double(rule.minUpdateInterval.components.seconds) {
            self.logger.error("""
            Metric '\(metricName, privacy: .public) is updating too frequently. \
            (lastUpdate=\(lastUpdate), now=\(Date.now)
            """)
            self.logger.info("Rate limiting on record() is current disabled")
            // TODO: rdar://119687218 (Find a way to implement this by aggregating
            // values before recording them in the MetricStore)
            // return false
        }
        self.frequencyTracker.recordUpdate(metricName)
        return true
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
                if self.frequencyTracker.shouldLog(metricName, .onPublish) {
                    self.logger.error("Trying to publish an unaudited metric: '\(metricName, privacy: .private)'")
                }
            }
            return false
        }

        let destinations = rules.flatMap { $0.destinations }
        if !destinations.isEmpty && !destinations.contains(destination) {
            if self.frequencyTracker.shouldLog(metricName, .onPublish) {
                self.logger
                    .error(
                        "Trying to publish metric '\(metricName, privacy: .public)' to unallowed destination '\(destination, privacy: .private)'"
                    )
            }
            return false
        }

        for rule in rules {
            // Note: if there are more rules matching this same metric name
            // (let's say coming from different clients) this will actually
            // apply the strictest interval among the all the matching rules
            let lastPublished = self.frequencyTracker.lastPublished(metricName)
            if rule.minPublishInterval > .seconds(0),
               lastPublished.timeIntervalSinceNow < TimeInterval(rule.minPublishInterval.components.seconds) {
                self.logger.error("""
                Metric '\(metricName, privacy: .public) is publishing too frequently. \
                (lastPublish=\(lastPublished), now=\(Date.now)
                """)
                return false
            }
        }
        self.frequencyTracker.recordPublish(metricName)
        return true
    }
}
