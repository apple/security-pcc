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
#if canImport(LoggingSupport)
import LoggingSupport
#endif
import Synchronization
private let log = EHLog.withCategory("MDNSResponderQueries")

public final class MDNSResponderQueries: OSLogStreamer.PredicatePlugin {
    public static let allEvents: [any EHUEFEvent.Type] = [ Event.self ]
    let parser = Parser()
    public func parse(_ fromOSLogEvent: OSLogStreamer.OSLogEvent) -> (any EHUEFEvent)? {
        parser.parse(fromOSLogEvent)
    }

    static let predicate: String = "(process == \"mDNSResponder\" AND subsystem == \"com.apple.mDNSResponder\" AND category == \"Default\")"
    public func getPredicate() -> String {
        return Self.predicate
    }

    public func logMessageMatch(_ event: OSLogStreamer.OSLogEvent) -> Bool {
        return event.process == "mDNSResponder" && event.subsystem == "com.apple.mDNSResponder" && (event.composedMessage.contains("DNSServiceQueryRecord START") || event.composedMessage.contains("DNSServiceQueryRecord result"))
    }

    private let profile = Mutex(["Subsystems":
        [
            "com.apple.mDNSResponder": [
                "Default": [
                    "Privacy-Enable-Level": "Sensitive",
                    "Level": [
                        "Enable": "info",
                        "Persist": "inherit"
                    ]
                ]
            ]
        ]
    ])
    private let loadedProfile = Mutex(false)

    public init() {
        #if canImport(LoggingSupport)
        var error: NSError?
        let ret = profile.withLock {
            OSLogInstallProfilePayload( $0, &error)
        }
        os_log(.debug, log: log, "loaded profile: \(ret)")
        if let error {
            os_log(.error, log: log, "error loading profile: \(error)")
        } else {
            loadedProfile.withLock { $0 = true }
        }
        #endif
    }

    deinit {
        #if canImport(LoggingSupport)
        if (loadedProfile.withLock { $0 }) {
            var error: NSError?
            let ret = profile.withLock {
                OSLogRemoveProfilePayload( $0, &error)
            }
            os_log(.debug, log: log, "unloaded profile: \(ret)")
            if let error {
                os_log(.error, log: log, "error unloading profile: \(error)")
            }
        }
        #endif
    }

    static let lookupMap = ThreadSafeExpiringLookupMap<String, Event>(.seconds(120))
    static let tldExtractCache = Mutex<LRUCache<String, String>>(LRUCache(totalCount: 256))

    static func subdomainFromQuery(_ query: String) -> String {
        let (wasCached, cached) = tldExtractCache.withLock { cache in
            if let cached = cache[query] {
                 return (true, cached)
            }
            return (false, "")
        }
        if wasCached {
            return cached
        }
        let resolved = {
            let lookup = (query.hasSuffix(".") ? String(query.dropLast(1)) : query)
            if let droppedTld = lookup.removingTLD() {
                var parts = droppedTld.split(separator: ".")
                _ = parts.removeLast()
                guard !parts.isEmpty else {
                    return ""
                }
                let subdomain = parts.joined(separator: ".")
                return subdomain
            }
            return ""
        }()
        tldExtractCache.withLock { cache in
            cache[query] = resolved
        }
        return resolved
    }

    struct Parser: OSLogStreamer.EventParser, @unchecked Sendable {
        let rrule = /\[(?<queryid>R\d+)(-.+?)?\] DNSServiceQueryRecord (?<rowtype>START|result) -- (qname: (?<qname>.+?)(, +))?(event: (?<event>.+?)(, +))?(expired: (?<expired>.+?)(, +))?(qtype: (?<qtype>.+?)(, +))?(flags: (?<flags>.+?)(, +))?((ifindex|interface index): (?<interface>.+?)(, +))?(client pid: (?<pid>\d+) \((?<processname>.+?)\)(, +|$))?(name hash: (?<namehash>.+?)(, +|$))?(type: (?<rtype>.+?)(, +))?(rdata: (?<rdata>.+?)($))?/

        func parse(_ fromOSLogEvent: OSLogStreamer.OSLogEvent) -> (any EHUEFEvent)? {
            if let result = try? rrule.firstMatch(in: fromOSLogEvent.composedMessage) {
                var e = Event()
                e.rowtype = String(result.rowtype) == "START" ? Event.QueryType.start.rawValue : Event.QueryType.result.rawValue
                e.timestamp = fromOSLogEvent.timestamp.timeIntervalSince1970
                e.queryID = String(result.queryid)
                e.interfaceIndex = Int(String(result.interface ?? "0")) ?? 0
                e.namehash = String(result.namehash ?? "na")

                if e.rowtype == Event.QueryType.start.rawValue {
                    e.process = String(result.processname ?? "na")
                    e.processID = pid_t(Int(String(result.pid ?? "0")) ?? 0)
                    e.qname = String(result.qname ?? "na")
                    e.qtype = String(result.qtype ?? "na")
                    e.qnameSE = e.qname.shannonEntropy()
                    e.subqname = MDNSResponderQueries.subdomainFromQuery(e.qname)
                    e.subqnameSE = e.subqname.shannonEntropy()
                    e.flags = String(result.flags ?? "na")
                    MDNSResponderQueries.lookupMap[e.queryID] = e
                } else if e.rowtype == Event.QueryType.result.rawValue {
                    e.rdata = String(result.rdata ?? "na")
                    e.qtype = String(result.rtype ?? "na")
                    if let queryStart = MDNSResponderQueries.lookupMap[e.queryID] {
                        e.process = queryStart.process
                        e.processID = queryStart.processID
                        e.qname = queryStart.qname
                        e.flags = queryStart.flags
                        e.qnameSE = queryStart.qnameSE
                        e.subqname = queryStart.subqname
                        e.subqnameSE = queryStart.subqnameSE
                    }
                }
                return e
            } else {
                return nil
            }
        }

    }

    public struct Event: EHUEFEvent {
        public init() {}
        public enum QueryType: String, Codable, CaseIterable {
            case start
            case result
        }
        public var metadata = EHEventMetadata()

        public var event_category: EHUEFCategory = .system
        public var event_type: String = "DNSServiceQueryRecord"

        public var rowtype = QueryType.start.rawValue

        public var timestamp: TimeInterval = 0

        public var queryID = ""

        public var process = ""

        public var processID: pid_t = 0

        public var qname = ""

        public var qtype = ""

        public var flags = ""

        public var interfaceIndex: Int = 0

        public var namehash = ""

        public var rdata = ""

        public var qnameSE: Double = 0

        public var subqname = ""

        public var subqnameSE: Double = 0
    }
}

extension MDNSResponderQueries.Event: EventNormalizer.DnsNormalizable {
    public var n_pid: Int64 {
        Int64(self.processID)
    }

    public var n_proc_name: String {
        self.process
    }

    public var n_rowtype: String {
        self.rowtype
    }

    public var n_qname: String {
        self.qname
    }

    public var n_qtype: String {
        self.qtype
    }

    public var n_rcode: String {
        ""
    }

    public var n_rdata: String {
        self.rdata
    }

    public var n_qname_entropy: Double {
        self.qnameSE
    }

    public var n_subqname: String {
        self.subqname
    }

    public var n_subqname_entropy: Double {
        self.subqnameSE
    }

    public var n_start_time: Double {
        self.timestamp
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "namehash": .string(self.namehash),
            "queryID": .string(self.queryID),
            "interfaceIndex": .int(Int(self.interfaceIndex)),
            "flags": .string(self.flags)
        ]
    }
}


extension MDNSResponderQueries.Event: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "rowtype": return rowtype
        case "timestamp": return timestamp
        case "queryID": return queryID
        case "process": return process
        case "processID": return processID
        case "qname": return qname
        case "qtype": return qtype
        case "flags": return flags
        case "interfaceIndex": return interfaceIndex
        case "namehash": return namehash
        case "rdata": return rdata
        case "qnameSE": return qnameSE
        case "subqname": return subqname
        case "subqnameSE": return subqnameSE
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
    static let rowtype: AST.RegoValue = .string("rowtype")
    static let timestamp: AST.RegoValue = .string("timestamp")
    static let queryID: AST.RegoValue = .string("queryID")
    static let process: AST.RegoValue = .string("process")
    static let processID: AST.RegoValue = .string("processID")
    static let qname: AST.RegoValue = .string("qname")
    static let qtype: AST.RegoValue = .string("qtype")
    static let flags: AST.RegoValue = .string("flags")
    static let interfaceIndex: AST.RegoValue = .string("interfaceIndex")
    static let namehash: AST.RegoValue = .string("namehash")
    static let rdata: AST.RegoValue = .string("rdata")
    static let qnameSE: AST.RegoValue = .string("qnameSE")
    static let subqname: AST.RegoValue = .string("subqname")
    static let subqnameSE: AST.RegoValue = .string("subqnameSE")
}

extension MDNSResponderQueries.Event: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.rowtype] = .string(rowtype)
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.queryID] = .string(queryID)
        obj[RK.process] = .string(process)
        obj[RK.processID] = .number(RegoNumber(int: Int64(processID)))
        obj[RK.qname] = .string(qname)
        obj[RK.qtype] = .string(qtype)
        obj[RK.flags] = .string(flags)
        obj[RK.interfaceIndex] = .number(RegoNumber(int: Int64(interfaceIndex)))
        obj[RK.namehash] = .string(namehash)
        obj[RK.rdata] = .string(rdata)
        obj[RK.qnameSE] = .number(RegoNumber(decimal: Decimal(qnameSE)))
        obj[RK.subqname] = .string(subqname)
        obj[RK.subqnameSE] = .number(RegoNumber(decimal: Decimal(subqnameSE)))
        return .object(obj)
    }
}
