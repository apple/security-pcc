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


extension AuditLogGenerator: AllEventsIterable {
    #if os(Linux)
    public static let allEvents: [any EHUEFEvent.Type] = [
        AuditDenialEvent.self
    ]
    #else
    public static let allEvents: [any EHUEFEvent.Type] = []
    #endif
}


#if os(Linux)

extension AuditLogGenerator {
    public struct AuditDenialEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .system
        public var event_type: String = "audit_denial"

        public init() {}

        public init(
            timestamp: Double = 0,
            serial: Int64 = 0,
            source: String = "",
            action: String = "",
            pid: Int64 = 0,
            comm: String = "",
            path: String = "",
            policyContext: String = "",
            targetClass: String = "",
            permissive: Bool = false,
            requestedMask: String = "",
            deniedMask: String = "",
            profile: String = "",
            exe: String = "",
            rawMessage: String = ""
        ) {
            self.timestamp = timestamp
            self.serial = serial
            self.source = source
            self.action = action
            self.pid = pid
            self.comm = comm
            self.path = path
            self.policyContext = policyContext
            self.targetClass = targetClass
            self.permissive = permissive
            self.requestedMask = requestedMask
            self.deniedMask = deniedMask
            self.profile = profile
            self.exe = exe
            self.rawMessage = rawMessage
        }

        public var timestamp: Double = 0

        public var serial: Int64 = 0

        public var source: String = ""

        public var action: String = ""

        public var pid: Int64 = 0

        public var comm: String = ""

        public var path: String = ""

        public var policyContext: String = ""

        public var targetClass: String = ""

        public var permissive: Bool = false

        public var requestedMask: String = ""

        public var deniedMask: String = ""

        public var profile: String = ""

        public var exe: String = ""

        public var rawMessage: String = ""
    }
}


extension AuditLogGenerator.AuditDenialEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "serial": return serial
        case "source": return source
        case "action": return action
        case "pid": return pid
        case "comm": return comm
        case "path": return path
        case "policyContext": return policyContext
        case "targetClass": return targetClass
        case "permissive": return permissive
        case "requestedMask": return requestedMask
        case "deniedMask": return deniedMask
        case "profile": return profile
        case "exe": return exe
        case "rawMessage": return rawMessage
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
    static let timestamp: AST.RegoValue = .string("timestamp")
    static let serial: AST.RegoValue = .string("serial")
    static let source: AST.RegoValue = .string("source")
    static let action: AST.RegoValue = .string("action")
    static let pid: AST.RegoValue = .string("pid")
    static let comm: AST.RegoValue = .string("comm")
    static let path: AST.RegoValue = .string("path")
    static let policyContext: AST.RegoValue = .string("policyContext")
    static let targetClass: AST.RegoValue = .string("targetClass")
    static let permissive: AST.RegoValue = .string("permissive")
    static let requestedMask: AST.RegoValue = .string("requestedMask")
    static let deniedMask: AST.RegoValue = .string("deniedMask")
    static let profile: AST.RegoValue = .string("profile")
    static let exe: AST.RegoValue = .string("exe")
    static let rawMessage: AST.RegoValue = .string("rawMessage")
}

extension AuditLogGenerator.AuditDenialEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.serial] = .number(RegoNumber(int: serial))
        obj[RK.source] = .string(source)
        obj[RK.action] = .string(action)
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.comm] = .string(comm)
        obj[RK.path] = .string(path)
        obj[RK.policyContext] = .string(policyContext)
        obj[RK.targetClass] = .string(targetClass)
        obj[RK.permissive] = .boolean(permissive)
        obj[RK.requestedMask] = .string(requestedMask)
        obj[RK.deniedMask] = .string(deniedMask)
        obj[RK.profile] = .string(profile)
        obj[RK.exe] = .string(exe)
        obj[RK.rawMessage] = .string(rawMessage)
        return .object(obj)
    }
}

#endif
