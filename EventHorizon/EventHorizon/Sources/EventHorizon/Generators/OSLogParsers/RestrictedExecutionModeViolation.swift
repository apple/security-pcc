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

public final class RestrictedExecutionModeViolation: OSLogStreamer.PredicatePlugin {
    public static let allEvents: [any EHUEFEvent.Type] = [ Event.self ]
    let parser = Parser()
    public func parse(_ fromOSLogEvent: OSLogStreamer.OSLogEvent) -> (any EHUEFEvent)? {
        parser.parse(fromOSLogEvent)
    }

    static let predicate: String = "((processID == 0) AND eventMessage CONTAINS[cd] \"Restricted Execution Mode\")"
    public func getPredicate() -> String {
        return Self.predicate
    }

    public func logMessageMatch(_ event: OSLogStreamer.OSLogEvent) -> Bool {
        return (event.processID == 0) && event.composedMessage.contains("Restricted Execution Mode")
    }

    public init() {}

    struct Parser: OSLogStreamer.EventParser, @unchecked Sendable {
        let rrule = /(AMFI: )?When validating (?<binary>.+?):\n +(?<identity>.+?) not allowed for Restricted Execution Mode state \((?<remstate>.+?)\)(: (?<reason>.+?))?$/
        func parse(_ fromOSLogEvent: OSLogStreamer.OSLogEvent) -> (any EHUEFEvent)? {
            if let result = try? rrule.firstMatch(in: fromOSLogEvent.composedMessage) {
                var e = Event()
                e.timestamp = fromOSLogEvent.timestamp.timeIntervalSince1970
                e.binary = String(result.binary)
                e.identity = String(result.identity)
                e.remstate = String(result.remstate)
                e.reason = String(result.reason ?? "")
                return e
            }
            return nil
        }
    }

    public struct Event: EHUEFEvent {
        internal init(fields: [String: EHValueType] = [:], tags: Set<String> = Set<String>(), event_category: EHUEFCategory = .system, event_type: String = "RestrictedExecutionModeViolation", binary: String = "", identity: String = "", remstate: String = "", reason: String = "", timestamp: TimeInterval = 0) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.binary = binary
            self.identity = identity
            self.remstate = remstate
            self.reason = reason
            self.timestamp = timestamp
        }

        public var metadata = EHEventMetadata()

        public var event_category: EHUEFCategory = .system
        public var event_type: String = "RestrictedExecutionModeViolation"

        public var binary = ""
        public var identity = ""
        public var remstate = ""
        public var reason = ""
        public var timestamp: TimeInterval = 0
        public init() {}
    }
}


extension RestrictedExecutionModeViolation.Event: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "binary": return binary
        case "identity": return identity
        case "remstate": return remstate
        case "reason": return reason
        case "timestamp": return timestamp
        default: return nil
        }
    }
}


import AST

private enum RK {
    static let event_type: AST.RegoValue = .string("event_type")
    static let event_category: AST.RegoValue = .string("event_category")
    static let tags: AST.RegoValue = .string("tags")
    static let fields: AST.RegoValue = .string("fields")
    static let binary: AST.RegoValue = .string("binary")
    static let identity: AST.RegoValue = .string("identity")
    static let remstate: AST.RegoValue = .string("remstate")
    static let reason: AST.RegoValue = .string("reason")
    static let timestamp: AST.RegoValue = .string("timestamp")
}

extension RestrictedExecutionModeViolation.Event: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.binary] = .string(binary)
        obj[RK.identity] = .string(identity)
        obj[RK.remstate] = .string(remstate)
        obj[RK.reason] = .string(reason)
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        return .object(obj)
    }
}
