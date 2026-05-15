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
import os
#endif

public class AlertLibrary {
    public static let alerts = PCCLibrary.allCases.map(\.alert)
    public static func alertsWithTag(_ tags: [String]) -> [AlertEngine.AlertDefinition] {
        return Self.alerts.filter { alert in
            alert.tags.contains { tag in tags.contains(tag) }
        }
    }
}

extension AlertEngine.AlertDefinition {
    public func rule(_ alertId: String) -> RuleTagger.Rule {
        return .init(constraints: self.constraints,
              criteria: self.criteria,
              name: "\(alertId):\(self.id)",
              tags: Set(
                [
                    "\(alertId):\(self.id)",
                    "\(alertId):\(AlertEngine.alert_hit_id)"
                ] + self.tags
              )
        )
    }
}
extension AlertEngine.AlertDefinition: CustomDebugStringConvertible {
    public var debugDescription: String {
        "Alert: \(self.id)"
    }
}
public final class AlertEngine: EHTransform, EHFileSubscriber, AllEventsIterable {
    public static let allEvents: [any EHUEFEvent.Type] = [
        AlertEvent.self
    ]

    public var filePaths: [String]? {
        return self.ruleEngine.filePaths
    }

    public enum Tags: String, CaseIterable {
        case cloudOS
    }

    private let alert_tag_prefix: String
    public static let alert_hit_id: String = "___alert_hit"
    public protocol AlertEngineLibrary: Sendable, CaseIterable {
        var alert: AlertEngine.AlertDefinition { get }
        var library_id: String { get }
    }
    public struct AlertDefinition: Sendable {
        internal init(confidence: Double, severity: Double, id: String, name: String, description: String, constraints: [RuleTagger.Constraint], criteria: RuleTagger.ConstraintCriteria, matching_events: [String: any EHUEFEvent], nonmatching_events: [String: any EHUEFEvent], tags: [String] = []) {
            self.confidence = confidence
            self.severity = severity
            self.id = id
            self.name = name
            self.description = description
            self.constraints = constraints
            self.criteria = criteria
            self.matching_events = matching_events
            self.nonmatching_events = nonmatching_events
            self.tags = tags
        }

        public let confidence: Double
        public let severity: Double
        public let id: String
        public let name: String
        public let description: String
        public let constraints: [RuleTagger.Constraint]
        public let criteria: RuleTagger.ConstraintCriteria
        public let matching_events: [String: any EHUEFEvent]
        public let nonmatching_events: [String: any EHUEFEvent]
        public let tags: [String]
    }

    public struct AlertEvent: EHUEFEvent {
        public init() {}
        public var tags = Set<String>()

        public var fields: [String: EHValueType] = [:]
        public var event_category: EHUEFCategory = .alert
        public var event_type: String = "alert"

        public var timestamp: TimeInterval = 0
        public var name: String = ""
        public var identifier: String = ""
        public var severity: Double = 0
        public var confidence: Double = 0
        public var payload: String = ""
    }

    private let log = EHLog.withCategory(RuleTagger.self)

    let alerts: [String: AlertDefinition]
    let ruleEngine: RuleTagger
    public init(_ alerts: [AlertDefinition]) {
        self.alerts = alerts.reduce(into: [String: AlertDefinition]()) { $0[$1.id] = $1 }
        let alertid = "alertengine_\(UUID().uuidString)"
        self.alert_tag_prefix = alertid
        self.ruleEngine = RuleTagger(alerts.map { $0.rule(alertid) })
    }

    public func configure() throws {

    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        let result = await self.ruleEngine.process(event)
        let alerthitId = "\(self.alert_tag_prefix):\(AlertEngine.alert_hit_id)"
        if result.0 == .proceed_mutated, let event = result.1?.first, event.tags.contains(alerthitId) {
            var counterMetrics: [(any EHMetrics.EHMetricDefinitionProtocol, UInt64, [(String, String)]?)] = []
            var mevent = event
            mevent.tags = Set(event.tags.filter { !$0.hasPrefix("\(self.alert_tag_prefix):") })
            var returnAlerts: [any EHUEFEvent] = [mevent]

            for tag in event.tags where tag.hasPrefix("\(self.alert_tag_prefix):") && tag != alerthitId {
                guard let alertDef = self.alerts[String(tag.split(separator: ":").last!)] else {
                    os_log(.error, log: log, "Unable to find alert definition for tag: \(tag)")
                    break
                }
                counterMetrics.append((EHMetrics.Labels.Counters.alertengine_hit_count, 1, [(EHMetrics.Labels.Dimensions.alert_id.rawValue, alertDef.id)]))
                var alertEvent = AlertEvent()
                alertEvent.timestamp = Date().timeIntervalSince1970
                alertEvent.identifier = alertDef.id
                alertEvent.name = alertDef.name
                alertEvent.payload = mevent.jsonString
                alertEvent.fields = mevent.fields
                alertEvent.tags = mevent.tags
                alertEvent.confidence = alertDef.confidence
                alertEvent.severity = alertDef.severity
                returnAlerts.append(alertEvent)
            }
            return (.proceed_mutated, returnAlerts, counterMetrics, nil)
        } else {
            return (.proceed, [event], nil, nil)
        }
    }

    public let name = "AlertEngineTransform"

}
