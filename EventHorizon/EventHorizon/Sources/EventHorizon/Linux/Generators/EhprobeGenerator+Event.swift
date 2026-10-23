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

#if os(Linux)
import Cehprobe

extension UnsafeRawPointer {
    func loadUnaligned<T>(as type: T.Type) -> T {
        return self.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<T>.size) { ptr in
            return ptr.withMemoryRebound(to: T.self, capacity: 1) { $0.pointee }
        }
    }
}

enum EhprobeNewExecOperation: Int {
    case CREATE = 1
    case CHMOD = 2

    private static let names: [UInt8: String] = {
        return [
            UInt8(CREATE.rawValue): "CREATE",
            UInt8(CHMOD.rawValue): "CHMOD"
        ]
    }()

    static func toString(_ operation: UInt8) -> String {
        return Self.names[operation] ?? "UNKNOWN_OPERATION(\(operation))"
    }
}

extension ehprobe_event_type_t {
    var name: String {
        switch self {
        case EHPROBE_EVENT_EXEC:
            return "EXEC"
        case EHPROBE_EVENT_EXIT:
            return "EXIT"
        case EHPROBE_EVENT_BPRM_CHECK:
            return "BPRM_CHECK"
        case EHPROBE_EVENT_TASK_KILL:
            return "TASK_KILL"
        case EHPROBE_EVENT_FILE_OPEN:
            return "FILE_OPEN"
        case EHPROBE_EVENT_PATH_CHMOD:
            return "PATH_CHMOD"
        case EHPROBE_EVENT_EXEC_SECURITY:
            return "EXEC_SECURITY"
        case EHPROBE_EVENT_BLOCK_KILL:
            return "BLOCK_KILL"
        case EHPROBE_EVENT_NEW_FS_EXEC:
            return "NEW_FS_EXEC"
        case EHPROBE_EVENT_CONTAINER_START:
            return "CONTAINER_START"
        case EHPROBE_EVENT_CONTAINER_STOP:
            return "CONTAINER_STOP"
        case EHPROBE_EVENT_FORK:
            return "FORK"
        case EHPROBE_EVENT_FILE_WRITE:
            return "FILE_WRITE"
        case EHPROBE_EVENT_FILE_UNLINK:
            return "FILE_UNLINK"
        case EHPROBE_EVENT_SETUID:
            return "SETUID"
        case EHPROBE_EVENT_SETGID:
            return "SETGID"
        case EHPROBE_EVENT_NET_ICMP:
            return "NET_ICMP"
        case EHPROBE_EVENT_PACKET_DATA:
            return "PACKET_DATA"
        case EHPROBE_EVENT_SCRIPT_SECURITY:
            return "SCRIPT_SECURITY"
        case EHPROBE_EVENT_AF_ALG_BIND:
            return "AF_ALG_BIND"
        case EHPROBE_EVENT_MODULE_LOAD_REQUEST:
            return "MODULE_LOAD_REQUEST"
        case EHPROBE_EVENT_XFRM_SA_NEW:
            return "XFRM_SA_NEW"
        default:
            return "UNKNOWN(\(self.rawValue))"
        }
    }
}

#endif

extension EhprobeGenerator.EhprobeNetworkEvent: EventNormalizer.NetworkNormalizable {
    public var n_pid: Int64 {
        self.pid
    }

    public var n_proc_name: String {
        self.procName
    }

    public var n_remote_addr: String {
        self.remoteAddr
    }

    public var n_remote_port: UInt16 {
        self.remotePort
    }

    public var n_local_port: UInt16 {
        self.localPort
    }

    public var n_direction: String {
        self.direction
    }

    public var n_protocol: String {
        self.protocol
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_start_time: Double {
        self.startTime
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel))
        ]
    }
}

extension EhprobeGenerator.EhprobeNetworkEvent: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(procName)
        hasher.combine(remoteAddr)
        hasher.combine(remotePort)
        hasher.combine(self.protocol)
        return hasher.finalize()
    }
}


extension EhprobeGenerator.EhprobeIcmpEvent: EventNormalizer.NetworkNormalizable {
    public var n_pid: Int64 {
        self.pid
    }

    public var n_proc_name: String {
        self.procName
    }

    public var n_remote_addr: String {
        self.remoteAddr
    }

    public var n_remote_port: UInt16 {
        0
    }

    public var n_local_port: UInt16 {
        0
    }

    public var n_direction: String {
        "outbound"
    }

    public var n_protocol: String {
        "icmp"
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_start_time: Double {
        self.startTime
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "icmpType": .int(Int(self.icmpType)),
            "icmpCode": .int(Int(self.icmpCode)),
            "identifier": .int(Int(self.identifier)),
            "sequence": .int(Int(self.sequence)),
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel))
        ]
    }
}


extension EhprobeGenerator.EhprobeDnsEvent: EventNormalizer.DnsNormalizable {
    public var n_pid: Int64 {
        self.pid
    }

    public var n_proc_name: String {
        self.procName
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
        self.rcode
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
        self.startTime
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "uid": .int(Int(self.uid)),
            "serverAddr": .string(self.serverAddr),
            "serverPort": .int(Int(self.serverPort)),
            "family": .string(self.family),
            "transactionId": .int(Int(self.transactionId)),
            "answerCount": .int(Int(self.answerCount)),
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel))
        ]
    }
}

extension EhprobeGenerator.EhprobeDnsEvent: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(procName)
        hasher.combine(qname)
        hasher.combine(qtype)
        hasher.combine(rowtype)
        return hasher.finalize()
    }
}


extension EhprobeGenerator.EhprobeDeviceOpenEvent: EventNormalizer.DeviceOpenNormalizable {
    public var n_timestamp: Double {
        self.timestamp
    }

    public var n_pid: Int64 {
        self.pid
    }

    public var n_executable: String {
        self.executable
    }

    public var n_device_identifier: String {
        self.deviceClass
    }

    public var n_device_path: String {
        self.devicePath
    }

    public var n_device_major: UInt32? {
        self.deviceMajor
    }

    public var n_device_minor: UInt32? {
        self.deviceMinor
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel))
        ]
    }
}

extension EhprobeGenerator.EhprobeDeviceOpenEvent: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(executable)
        hasher.combine(deviceClass)
        hasher.combine(devicePath)
        return hasher.finalize()
    }
}


extension EhprobeGenerator.EhprobeSSHLoginEvent: EventNormalizer.SSHNormalizable {
    public var n_start_time: Double {
        self.timestamp
    }

    public var n_src_addr: String {
        self.srcAddr
    }

    public var n_username: String {
        self.username
    }

    public var n_success: Bool {
        self.success
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_pid: Int64 {
        self.pid
    }

    public var n_tty: String {
        self.tty
    }

    public var n_session_id: String {
        self.sessionId
    }

    public var n_action: String {
        "login"
    }

    public var n_session_duration: Double {
        0
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel))
        ]
    }
}

extension EhprobeGenerator.EhprobeSSHLogoutEvent: EventNormalizer.SSHNormalizable {
    public var n_start_time: Double {
        self.timestamp
    }

    public var n_src_addr: String {
        self.srcAddr
    }

    public var n_username: String {
        self.username
    }

    public var n_success: Bool {
        true
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_pid: Int64 {
        self.pid
    }

    public var n_tty: String {
        ""
    }

    public var n_session_id: String {
        self.sessionId
    }

    public var n_action: String {
        "logout"
    }

    public var n_session_duration: Double {
        self.sessionDuration
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel))
        ]
    }
}

extension EhprobeGenerator.EhprobeSSHLoginEvent: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(timestamp)
        hasher.combine(srcAddr)
        hasher.combine(username)
        hasher.combine(sessionId)
        return hasher.finalize()
    }
}

extension EhprobeGenerator: AllEventsIterable {
    public static let allEvents: [any EHUEFEvent.Type] = [
        EhprobeBlockKillEvent.self,
        EhprobeNewFsExecEvent.self,
        EhprobeBlockedExecEvent.self,
        EhprobeScriptSecurityEvent.self,
        EhprobeNetworkEvent.self,
        EhprobeIcmpEvent.self,
        EhprobeDnsEvent.self,
        EhprobeDeviceOpenEvent.self,
        EhprobeSSHLoginEvent.self,
        EhprobeSSHLogoutEvent.self,
        EhprobeProcForkEvent.self,
        EhprobeFileOpenEvent.self,
        EhprobeFileWriteEvent.self,
        EhprobeFileUnlinkEvent.self,
        EhprobeSetuidEvent.self,
        EhprobeSetgidEvent.self,
        EhprobePacketDataEvent.self,
        EhprobeAFAlgBindEvent.self,
        EhprobeModuleLoadRequestEvent.self,
        EhprobeXfrmSaNewEvent.self
    ]

    public struct EhprobeNetworkEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .network
        public var event_type: String = "ehprobe_network"

        public init() {}

        public init(
            startTime: Double = 0,
            pid: Int64 = 0,
            procName: String = "",
            remoteAddr: String = "",
            remotePort: UInt16 = 0,
            localPort: UInt16 = 0,
            direction: String = "",
            `protocol`: String = "",
            uid: UInt32 = 0,
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.startTime = startTime
            self.pid = pid
            self.procName = procName
            self.remoteAddr = remoteAddr
            self.remotePort = remotePort
            self.localPort = localPort
            self.direction = direction
            self.protocol = `protocol`
            self.uid = uid
            self.containerId = containerId
            self.containerLevel = containerLevel
        }

        public var startTime: Double = 0

        public var pid: Int64 = 0

        public var procName: String = ""

        public var remoteAddr: String = ""

        public var remotePort: UInt16 = 0

        public var localPort: UInt16 = 0

        public var direction: String = ""

        public var `protocol`: String = ""

        public var uid: UInt32 = 0

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeIcmpEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .network
        public var event_type: String = "ehprobe_icmp"

        public init() {}

        public init(
            startTime: Double = 0,
            pid: Int64 = 0,
            procName: String = "",
            remoteAddr: String = "",
            family: String = "",
            icmpType: UInt8 = 0,
            icmpCode: UInt8 = 0,
            identifier: UInt16 = 0,
            sequence: UInt16 = 0,
            uid: UInt32 = 0,
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.startTime = startTime
            self.pid = pid
            self.procName = procName
            self.remoteAddr = remoteAddr
            self.family = family
            self.icmpType = icmpType
            self.icmpCode = icmpCode
            self.identifier = identifier
            self.sequence = sequence
            self.uid = uid
            self.containerId = containerId
            self.containerLevel = containerLevel
        }

        public var startTime: Double = 0
        public var pid: Int64 = 0
        public var procName: String = ""
        public var remoteAddr: String = ""
        public var family: String = ""
        public var icmpType: UInt8 = 0
        public var icmpCode: UInt8 = 0
        public var identifier: UInt16 = 0
        public var sequence: UInt16 = 0
        public var uid: UInt32 = 0
        public var containerId: UInt64 = 0
        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeDnsEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .network
        public var event_type: String = "ehprobe_dns"

        public init() {}

        public enum QueryType: String, Codable, CaseIterable {
            case start
            case result
        }

        public init(
            startTime: Double = 0,
            pid: Int64 = 0,
            procName: String = "",
            uid: UInt32 = 0,
            rowtype: String = QueryType.start.rawValue,
            serverAddr: String = "",
            serverPort: UInt16 = 0,
            family: String = "",
            transactionId: UInt16 = 0,
            qtype: String = "",
            qname: String = "",
            rcode: String = "",
            answerCount: UInt16 = 0,
            rdata: String = "",
            qnameSE: Double = 0,
            subqname: String = "",
            subqnameSE: Double = 0,
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.startTime = startTime
            self.pid = pid
            self.procName = procName
            self.uid = uid
            self.rowtype = rowtype
            self.serverAddr = serverAddr
            self.serverPort = serverPort
            self.family = family
            self.transactionId = transactionId
            self.qtype = qtype
            self.qname = qname
            self.rcode = rcode
            self.answerCount = answerCount
            self.rdata = rdata
            self.qnameSE = qnameSE
            self.subqname = subqname
            self.subqnameSE = subqnameSE
            self.containerId = containerId
            self.containerLevel = containerLevel
        }

        public var startTime: Double = 0

        public var pid: Int64 = 0

        public var procName: String = ""

        public var uid: UInt32 = 0

        public var rowtype: String = QueryType.start.rawValue

        public var serverAddr: String = ""

        public var serverPort: UInt16 = 0

        public var family: String = ""

        public var transactionId: UInt16 = 0

        public var qtype: String = ""

        public var qname: String = ""

        public var rcode: String = ""

        public var answerCount: UInt16 = 0

        public var rdata: String = ""

        public var qnameSE: Double = 0

        public var subqname: String = ""

        public var subqnameSE: Double = 0

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeDeviceOpenEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .resource
        public var event_type: String = "ehprobe_device_open"

        public init() {}

        public init(
            timestamp: Double = 0,
            pid: Int64 = 0,
            devicePath: String = "",
            deviceMajor: UInt32 = 0,
            deviceMinor: UInt32 = 0,
            deviceClass: String = "",
            executable: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.timestamp = timestamp
            self.pid = pid
            self.devicePath = devicePath
            self.deviceMajor = deviceMajor
            self.deviceMinor = deviceMinor
            self.deviceClass = deviceClass
            self.executable = executable
            self.containerId = containerId
            self.containerLevel = containerLevel
        }

        public var timestamp: Double = 0

        public var pid: Int64 = 0

        public var devicePath: String = ""

        public var deviceMajor: UInt32 = 0

        public var deviceMinor: UInt32 = 0

        public var deviceClass: String = ""

        public var executable: String = ""

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeBlockKillEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "block_kill"

        public init() {}

        public init(
            sourcePid: UInt32 = 0,
            signal: UInt8 = 0
        ) {
            self.sourcePid = sourcePid
            self.signal = signal
        }

        public var sourcePid: UInt32 = 0

        public var signal: UInt8 = 0
    }

    public struct EhprobeNewFsExecEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "new_fs_exec"

        public init() {}

        public init(
            executable: String = "",
            hash: String = "",
            pid: UInt32 = 0,
            processPath: String = ""
        ) {
            self.executable = executable
            self.hash = hash
            self.pid = pid
            self.processPath = processPath
        }

        public var executable: String = ""

        public var hash: String = ""

        public var pid: UInt32 = 0

        public var processPath: String = ""
    }

    public struct EhprobeBlockedExecEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "exec_blocked"

        public init() {}

        public init(
            executable: String = "",
            hash: String = "",
            pid: UInt32 = 0,
            blockingMode: EhprobeGenerator.ExecBlockingMode = .enforce
        ) {
            self.executable = executable
            self.hash = hash
            self.pid = pid
            self.blocking_mode = blockingMode.rawValue
        }

        public var executable: String = ""

        public var hash: String = ""

        public var pid: UInt32 = 0

        public var blocking_mode: String = ExecBlockingMode.enforce.rawValue
    }

    public struct EhprobeScriptSecurityEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "script_security"

        public init() {}

        public init(
            script_path: String = "",
            hash: String = "",
            pid: UInt32 = 0,
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0,
            blockingMode: EhprobeGenerator.ExecBlockingMode = .enforce,
            isInlineCode: Bool = false,
            isPipedStdin: Bool = false,
            isNoArgs: Bool = false,
            allowed: Bool = false
        ) {
            self.script_path = script_path
            self.hash = hash
            self.pid = pid
            self.containerId = containerId
            self.containerLevel = containerLevel
            self.blocking_mode = blockingMode.rawValue
            self.is_inline_code = isInlineCode
            self.is_piped_stdin = isPipedStdin
            self.is_no_args = isNoArgs
            self.allowed = allowed
        }

        public var script_path: String = ""

        public var hash: String = ""

        public var pid: UInt32 = 0

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0

        public var blocking_mode: String = ExecBlockingMode.enforce.rawValue

        public var is_inline_code: Bool = false

        public var is_piped_stdin: Bool = false

        public var is_no_args: Bool = false

        public var allowed: Bool = false
    }

    public struct EhprobeSSHLoginEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .system
        public var event_type: String = "ssh_login"

        public init() {}

        public init(
            timestamp: TimeInterval = 0,
            srcAddr: String = "",
            username: String = "",
            success: Bool = true,
            uid: UInt32 = 0,
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0,
            pid: Int64 = 0,
            tty: String = "",
            sessionId: String = ""
        ) {
            self.timestamp = timestamp
            self.srcAddr = srcAddr
            self.username = username
            self.success = success
            self.uid = uid
            self.containerId = containerId
            self.containerLevel = containerLevel
            self.pid = pid
            self.tty = tty
            self.sessionId = sessionId
        }

        public var timestamp: TimeInterval = 0

        public var srcAddr: String = ""

        public var username: String = ""

        public var success: Bool = true

        public var uid: UInt32 = 0

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0

        public var pid: Int64 = 0

        public var tty: String = ""

        public var sessionId: String = ""
    }

    public struct EhprobeSSHLogoutEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .system
        public var event_type: String = "ssh_logout"

        public init() {}

        public init(
            timestamp: TimeInterval = 0,
            srcAddr: String = "",
            username: String = "",
            uid: UInt32 = 0,
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0,
            pid: Int64 = 0,
            sessionDuration: Double = 0,
            sessionId: String = ""
        ) {
            self.timestamp = timestamp
            self.srcAddr = srcAddr
            self.username = username
            self.uid = uid
            self.containerId = containerId
            self.containerLevel = containerLevel
            self.pid = pid
            self.sessionDuration = sessionDuration
            self.sessionId = sessionId
        }

        public var timestamp: TimeInterval = 0

        public var srcAddr: String = ""

        public var username: String = ""

        public var uid: UInt32 = 0

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0

        public var pid: Int64 = 0

        public var sessionDuration: Double = 0

        public var sessionId: String = ""
    }

    public struct EhprobeProcForkEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "ehprobe_proc_fork"

        public init() {}

        public init(
            startTime: Double = 0,
            pid: Int64 = 0,
            ppid: Int64 = 0,
            comm: String = "",
            parentExe: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.startTime = startTime
            self.pid = pid
            self.ppid = ppid
            self.comm = comm
            self.parentExe = parentExe
            self.containerId = containerId
            self.containerLevel = containerLevel
            self.tags.insert(EventNormalizer.NormalizedProcess.Tags.fork_only.rawValue)
        }

        public var startTime: Double = 0

        public var pid: Int64 = 0

        public var ppid: Int64 = 0

        public var comm: String = ""

        public var parentExe: String = ""

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeFileOpenEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .resource
        public var event_type: String = "ehprobe_file_open"

        public init() {}

        public init(
            timestamp: Double = 0,
            path: String = "",
            flags: Int32 = 0,
            pid: Int64 = 0,
            ppid: Int64 = 0,
            uid: UInt32 = 0,
            executable: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.timestamp = timestamp
            self.path = path
            self.flags = flags
            self.pid = pid
            self.ppid = ppid
            self.uid = uid
            self.executable = executable
            self.containerId = containerId
            self.containerLevel = containerLevel
        }

        public var timestamp: Double = 0

        public var path: String = ""

        public var flags: Int32 = 0

        public var pid: Int64 = 0

        public var ppid: Int64 = 0

        public var uid: UInt32 = 0

        public var executable: String = ""

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeFileWriteEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .resource
        public var event_type: String = "ehprobe_file_write"

        public init() {}

        public init(
            timestamp: Double = 0,
            path: String = "",
            pid: Int64 = 0,
            ppid: Int64 = 0,
            uid: UInt32 = 0,
            executable: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.timestamp = timestamp
            self.path = path
            self.pid = pid
            self.ppid = ppid
            self.uid = uid
            self.executable = executable
            self.containerId = containerId
            self.containerLevel = containerLevel
        }

        public var timestamp: Double = 0

        public var path: String = ""

        public var pid: Int64 = 0

        public var ppid: Int64 = 0

        public var uid: UInt32 = 0

        public var executable: String = ""

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeFileUnlinkEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .resource
        public var event_type: String = "ehprobe_file_unlink"

        public init() {}

        public init(
            timestamp: Double = 0,
            path: String = "",
            pid: Int64 = 0,
            ppid: Int64 = 0,
            uid: UInt32 = 0,
            executable: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.timestamp = timestamp
            self.path = path
            self.pid = pid
            self.ppid = ppid
            self.uid = uid
            self.executable = executable
            self.containerId = containerId
            self.containerLevel = containerLevel
        }

        public var timestamp: Double = 0

        public var path: String = ""

        public var pid: Int64 = 0

        public var ppid: Int64 = 0

        public var uid: UInt32 = 0

        public var executable: String = ""

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeSetuidEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "ehprobe_setuid"

        public init() {}

        public init(
            timestamp: Double = 0,
            oldUid: UInt32 = 0,
            newUid: UInt32 = 0,
            oldEuid: UInt32 = 0,
            newEuid: UInt32 = 0,
            pid: Int64 = 0,
            ppid: Int64 = 0,
            executable: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.timestamp = timestamp
            self.oldUid = oldUid
            self.newUid = newUid
            self.oldEuid = oldEuid
            self.newEuid = newEuid
            self.pid = pid
            self.ppid = ppid
            self.executable = executable
            self.containerId = containerId
            self.containerLevel = containerLevel
        }

        public var timestamp: Double = 0

        public var oldUid: UInt32 = 0

        public var newUid: UInt32 = 0

        public var oldEuid: UInt32 = 0

        public var newEuid: UInt32 = 0

        public var pid: Int64 = 0

        public var ppid: Int64 = 0

        public var executable: String = ""

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeSetgidEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "ehprobe_setgid"

        public init() {}

        public init(
            timestamp: Double = 0,
            oldGid: UInt32 = 0,
            newGid: UInt32 = 0,
            oldEgid: UInt32 = 0,
            newEgid: UInt32 = 0,
            pid: Int64 = 0,
            ppid: Int64 = 0,
            executable: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0
        ) {
            self.timestamp = timestamp
            self.oldGid = oldGid
            self.newGid = newGid
            self.oldEgid = oldEgid
            self.newEgid = newEgid
            self.pid = pid
            self.ppid = ppid
            self.executable = executable
            self.containerId = containerId
            self.containerLevel = containerLevel
        }

        public var timestamp: Double = 0

        public var oldGid: UInt32 = 0

        public var newGid: UInt32 = 0

        public var oldEgid: UInt32 = 0

        public var newEgid: UInt32 = 0

        public var pid: Int64 = 0

        public var ppid: Int64 = 0

        public var executable: String = ""

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0
    }

    public struct EhprobeAFAlgBindEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "ehprobe_af_alg_bind"

        public init() {}

        public init(
            timestamp: Double = 0,
            salgType: String = "",
            salgName: String = "",
            pid: Int64 = 0,
            ppid: Int64 = 0,
            executable: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0,
            blockingMode: EhprobeGenerator.ExecBlockingMode = .off
        ) {
            self.timestamp = timestamp
            self.salgType = salgType
            self.salgName = salgName
            self.pid = pid
            self.ppid = ppid
            self.executable = executable
            self.containerId = containerId
            self.containerLevel = containerLevel
            self.blocking_mode = blockingMode.rawValue
        }

        public var timestamp: Double = 0

        public var salgType: String = ""

        public var salgName: String = ""

        public var pid: Int64 = 0

        public var ppid: Int64 = 0

        public var executable: String = ""

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0

        public var blocking_mode: String = ExecBlockingMode.off.rawValue
    }

    public struct EhprobeModuleLoadRequestEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .system
        public var event_type: String = "ehprobe_module_load_request"

        public enum Hook: String, Sendable {
            case request
            case read
            case unknown
        }

        public init() {}

        public init(
            timestamp: Double = 0,
            moduleName: String = "",
            filePath: String = "",
            hook: Hook = .unknown,
            pid: Int64 = 0,
            ppid: Int64 = 0,
            executable: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0,
            blockingMode: EhprobeGenerator.ExecBlockingMode = .off
        ) {
            self.timestamp = timestamp
            self.moduleName = moduleName
            self.filePath = filePath
            self.hook = hook.rawValue
            self.pid = pid
            self.ppid = ppid
            self.executable = executable
            self.containerId = containerId
            self.containerLevel = containerLevel
            self.blocking_mode = blockingMode.rawValue
        }

        public var timestamp: Double = 0

        public var moduleName: String = ""

        public var filePath: String = ""

        public var hook: String = Hook.unknown.rawValue

        public var pid: Int64 = 0

        public var ppid: Int64 = 0

        public var executable: String = ""

        public var containerId: UInt64 = 0

        public var containerLevel: UInt32 = 0

        public var blocking_mode: String = ExecBlockingMode.off.rawValue
    }

    public struct EhprobeXfrmSaNewEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .system
        public var event_type: String = "ehprobe_xfrm_sa_new"

        public init() {}

        public init(
            timestamp: Double = 0,
            userNsInum: UInt64 = 0,
            saFlags: UInt32 = 0,
            aeadName: String = "",
            authName: String = "",
            cryptName: String = "",
            pid: Int64 = 0,
            ppid: Int64 = 0,
            executable: String = "",
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0,
            blockingMode: EhprobeGenerator.ExecBlockingMode = .off
        ) {
            self.timestamp = timestamp
            self.userNsInum = userNsInum
            self.saFlags = saFlags
            self.aeadName = aeadName
            self.authName = authName
            self.cryptName = cryptName
            self.pid = pid
            self.ppid = ppid
            self.executable = executable
            self.containerId = containerId
            self.containerLevel = containerLevel
            self.blocking_mode = blockingMode.rawValue
        }

        public var timestamp: Double = 0

        public var userNsInum: UInt64 = 0

        public var saFlags: UInt32 = 0

        public var aeadName: String = ""

        public var authName: String = ""

        public var cryptName: String = ""

        public var pid: Int64 = 0
        public var ppid: Int64 = 0
        public var executable: String = ""
        public var containerId: UInt64 = 0
        public var containerLevel: UInt32 = 0
        public var blocking_mode: String = ExecBlockingMode.off.rawValue
    }

}


extension EhprobeGenerator.EhprobeProcForkEvent: EventNormalizer.ProcessNormalizable {
    public var n_args: [String] {
        []
    }

    public var n_pid: Int64 {
        self.pid
    }

    public var n_ppid: Int64 {
        self.ppid
    }

    public var n_exe: String {
        self.comm
    }

    public var n_start_time: Double {
        self.startTime
    }

    public var n_cwd: String {
        ""
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel)),
            "parentExe": .string(self.parentExe)
        ]
    }

    public var n_tty: String {
        ""
    }

    public var n_uid: UInt32 {
        0
    }

    public var n_euid: UInt32 {
        0
    }

    public var n_gid: UInt32 {
        0
    }

    public var n_p_exe: String {
        self.parentExe
    }

    public var n_fd_count: UInt32 {
        0
    }

    public var n_fd_pipe_ids: [UInt64] {
        []
    }
}


extension EhprobeGenerator.EhprobeFileOpenEvent: EventNormalizer.FileNormalizable {
    public var n_action: String {
        "open"
    }

    public var n_timestamp: Double {
        self.timestamp
    }

    public var n_path: String {
        self.path
    }

    public var n_size: Int64 {
        0
    }

    public var n_flags: Int32 {
        self.flags
    }

    public var n_exe: String {
        self.executable
    }

    public var n_pid: Int64 {
        self.pid
    }

    public var n_ppid: Int64 {
        self.ppid
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel))
        ]
    }
}

extension EhprobeGenerator.EhprobeFileWriteEvent: EventNormalizer.FileNormalizable {
    public var n_action: String {
        "write"
    }

    public var n_timestamp: Double {
        self.timestamp
    }

    public var n_path: String {
        self.path
    }

    public var n_size: Int64 {
        0
    }

    public var n_flags: Int32 {
        0
    }

    public var n_exe: String {
        self.executable
    }

    public var n_pid: Int64 {
        self.pid
    }

    public var n_ppid: Int64 {
        self.ppid
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel))
        ]
    }
}

extension EhprobeGenerator.EhprobeFileUnlinkEvent: EventNormalizer.FileNormalizable {
    public var n_action: String {
        "unlink"
    }

    public var n_timestamp: Double {
        self.timestamp
    }

    public var n_path: String {
        self.path
    }

    public var n_size: Int64 {
        0
    }

    public var n_flags: Int32 {
        0
    }

    public var n_exe: String {
        self.executable
    }

    public var n_pid: Int64 {
        self.pid
    }

    public var n_ppid: Int64 {
        self.ppid
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "containerId": .int(Int(self.containerId)),
            "containerLevel": .int(Int(self.containerLevel))
        ]
    }
}


extension EhprobeGenerator.EhprobeNetworkEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "startTime": return startTime
        case "pid": return pid
        case "procName": return procName
        case "remoteAddr": return remoteAddr
        case "remotePort": return remotePort
        case "localPort": return localPort
        case "direction": return direction
        case "protocol": return `protocol`
        case "uid": return uid
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeDnsEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "startTime": return startTime
        case "pid": return pid
        case "procName": return procName
        case "uid": return uid
        case "rowtype": return rowtype
        case "serverAddr": return serverAddr
        case "serverPort": return serverPort
        case "family": return family
        case "transactionId": return transactionId
        case "qtype": return qtype
        case "qname": return qname
        case "rcode": return rcode
        case "answerCount": return answerCount
        case "rdata": return rdata
        case "qnameSE": return qnameSE
        case "subqname": return subqname
        case "subqnameSE": return subqnameSE
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeDeviceOpenEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "pid": return pid
        case "devicePath": return devicePath
        case "deviceMajor": return deviceMajor
        case "deviceMinor": return deviceMinor
        case "deviceClass": return deviceClass
        case "executable": return executable
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeBlockKillEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "sourcePid": return sourcePid
        case "signal": return signal
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeNewFsExecEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "executable": return executable
        case "hash": return hash
        case "pid": return pid
        case "processPath": return processPath
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeBlockedExecEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "executable": return executable
        case "hash": return hash
        case "pid": return pid
        case "blocking_mode": return blocking_mode
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeScriptSecurityEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "script_path": return script_path
        case "hash": return hash
        case "pid": return pid
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        case "blocking_mode": return blocking_mode
        case "is_inline_code": return is_inline_code
        case "is_piped_stdin": return is_piped_stdin
        case "is_no_args": return is_no_args
        case "allowed": return allowed
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeSSHLoginEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "srcAddr": return srcAddr
        case "username": return username
        case "success": return success
        case "uid": return uid
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        case "pid": return pid
        case "tty": return tty
        case "sessionId": return sessionId
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeSSHLogoutEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "srcAddr": return srcAddr
        case "username": return username
        case "uid": return uid
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        case "pid": return pid
        case "sessionDuration": return sessionDuration
        case "sessionId": return sessionId
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeProcForkEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "startTime": return startTime
        case "pid": return pid
        case "ppid": return ppid
        case "comm": return comm
        case "parentExe": return parentExe
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeFileOpenEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "path": return path
        case "flags": return flags
        case "pid": return pid
        case "ppid": return ppid
        case "uid": return uid
        case "executable": return executable
        case "exe": return executable
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeFileWriteEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "path": return path
        case "pid": return pid
        case "ppid": return ppid
        case "uid": return uid
        case "executable": return executable
        case "exe": return executable
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeSetuidEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "oldUid": return oldUid
        case "newUid": return newUid
        case "oldEuid": return oldEuid
        case "newEuid": return newEuid
        case "uid": return oldUid
        case "pid": return pid
        case "ppid": return ppid
        case "executable": return executable
        case "exe": return executable
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeSetgidEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "oldGid": return oldGid
        case "newGid": return newGid
        case "oldEgid": return oldEgid
        case "newEgid": return newEgid
        case "pid": return pid
        case "ppid": return ppid
        case "executable": return executable
        case "exe": return executable
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeAFAlgBindEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "salgType": return salgType
        case "salgName": return salgName
        case "pid": return pid
        case "ppid": return ppid
        case "executable": return executable
        case "exe": return executable
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        case "blocking_mode": return blocking_mode
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeModuleLoadRequestEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "moduleName": return moduleName
        case "filePath": return filePath
        case "hook": return hook
        case "pid": return pid
        case "ppid": return ppid
        case "executable": return executable
        case "exe": return executable
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        case "blocking_mode": return blocking_mode
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobeXfrmSaNewEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "userNsInum": return userNsInum
        case "saFlags": return saFlags
        case "aeadName": return aeadName
        case "authName": return authName
        case "cryptName": return cryptName
        case "pid": return pid
        case "ppid": return ppid
        case "executable": return executable
        case "exe": return executable
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        case "blocking_mode": return blocking_mode
        default: return nil
        }
    }
}
extension EhprobeGenerator.EhprobeFileUnlinkEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "path": return path
        case "pid": return pid
        case "ppid": return ppid
        case "uid": return uid
        case "executable": return executable
        case "exe": return executable
        case "containerId": return containerId
        case "containerLevel": return containerLevel
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
    static let startTime: AST.RegoValue = .string("startTime")
    static let timestamp: AST.RegoValue = .string("timestamp")
    static let pid: AST.RegoValue = .string("pid")
    static let ppid: AST.RegoValue = .string("ppid")
    static let uid: AST.RegoValue = .string("uid")
    static let procName: AST.RegoValue = .string("procName")
    static let remoteAddr: AST.RegoValue = .string("remoteAddr")
    static let remotePort: AST.RegoValue = .string("remotePort")
    static let localPort: AST.RegoValue = .string("localPort")
    static let direction: AST.RegoValue = .string("direction")
    static let `protocol`: AST.RegoValue = .string("protocol")
    static let containerId: AST.RegoValue = .string("containerId")
    static let containerLevel: AST.RegoValue = .string("containerLevel")
    static let rowtype: AST.RegoValue = .string("rowtype")
    static let serverAddr: AST.RegoValue = .string("serverAddr")
    static let serverPort: AST.RegoValue = .string("serverPort")
    static let family: AST.RegoValue = .string("family")
    static let transactionId: AST.RegoValue = .string("transactionId")
    static let qtype: AST.RegoValue = .string("qtype")
    static let qname: AST.RegoValue = .string("qname")
    static let rcode: AST.RegoValue = .string("rcode")
    static let answerCount: AST.RegoValue = .string("answerCount")
    static let rdata: AST.RegoValue = .string("rdata")
    static let qnameSE: AST.RegoValue = .string("qnameSE")
    static let subqname: AST.RegoValue = .string("subqname")
    static let subqnameSE: AST.RegoValue = .string("subqnameSE")
    static let devicePath: AST.RegoValue = .string("devicePath")
    static let deviceMajor: AST.RegoValue = .string("deviceMajor")
    static let deviceMinor: AST.RegoValue = .string("deviceMinor")
    static let deviceClass: AST.RegoValue = .string("deviceClass")
    static let executable: AST.RegoValue = .string("executable")
    static let sourcePid: AST.RegoValue = .string("sourcePid")
    static let signal: AST.RegoValue = .string("signal")
    static let hash: AST.RegoValue = .string("hash")
    static let processPath: AST.RegoValue = .string("processPath")
    static let srcAddr: AST.RegoValue = .string("srcAddr")
    static let username: AST.RegoValue = .string("username")
    static let success: AST.RegoValue = .string("success")
    static let tty: AST.RegoValue = .string("tty")
    static let sessionId: AST.RegoValue = .string("sessionId")
    static let sessionDuration: AST.RegoValue = .string("sessionDuration")
    static let comm: AST.RegoValue = .string("comm")
    static let parentExe: AST.RegoValue = .string("parentExe")
    static let path: AST.RegoValue = .string("path")
    static let flags: AST.RegoValue = .string("flags")
    static let blocking_mode: AST.RegoValue = .string("blocking_mode")
    static let is_inline_code: AST.RegoValue = .string("is_inline_code")
    static let is_piped_stdin: AST.RegoValue = .string("is_piped_stdin")
    static let is_no_args: AST.RegoValue = .string("is_no_args")
    static let allowed: AST.RegoValue = .string("allowed")
    static let oldUid: AST.RegoValue = .string("oldUid")
    static let newUid: AST.RegoValue = .string("newUid")
    static let oldEuid: AST.RegoValue = .string("oldEuid")
    static let newEuid: AST.RegoValue = .string("newEuid")
    static let oldGid: AST.RegoValue = .string("oldGid")
    static let newGid: AST.RegoValue = .string("newGid")
    static let oldEgid: AST.RegoValue = .string("oldEgid")
    static let newEgid: AST.RegoValue = .string("newEgid")
    static let icmpType: AST.RegoValue = .string("icmpType")
    static let icmpCode: AST.RegoValue = .string("icmpCode")
    static let identifier: AST.RegoValue = .string("identifier")
    static let sequence: AST.RegoValue = .string("sequence")
    static let networkProtocol: AST.RegoValue = .string("networkProtocol")
    static let payload: AST.RegoValue = .string("payload")
    static let payloadLen: AST.RegoValue = .string("payloadLen")
    static let ifindex: AST.RegoValue = .string("ifindex")

    static let proc_name: AST.RegoValue = .string("proc_name")
    static let remote_addr: AST.RegoValue = .string("remote_addr")
    static let remote_port: AST.RegoValue = .string("remote_port")
    static let local_port: AST.RegoValue = .string("local_port")
    static let exe: AST.RegoValue = .string("exe")
    static let exe_basename: AST.RegoValue = .string("exe_basename")
    static let pid_start_time: AST.RegoValue = .string("pid_start_time")
    static let p_pid: AST.RegoValue = .string("p_pid")
    static let p_pid_start_time: AST.RegoValue = .string("p_pid_start_time")
    static let p_exe: AST.RegoValue = .string("p_exe")
    static let p_exe_basename: AST.RegoValue = .string("p_exe_basename")
    static let script_path: AST.RegoValue = .string("script_path")
    static let salgType: AST.RegoValue = .string("salgType")
    static let salgName: AST.RegoValue = .string("salgName")
    static let moduleName: AST.RegoValue = .string("moduleName")
    static let filePath: AST.RegoValue = .string("filePath")
    static let hook: AST.RegoValue = .string("hook")
    static let userNsInum: AST.RegoValue = .string("userNsInum")
    static let saFlags: AST.RegoValue = .string("saFlags")
    static let aeadName: AST.RegoValue = .string("aeadName")
    static let authName: AST.RegoValue = .string("authName")
    static let cryptName: AST.RegoValue = .string("cryptName")
}

extension EhprobeGenerator.EhprobeNetworkEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.startTime] = .number(RegoNumber(decimal: Decimal(startTime)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.procName] = .string(procName)
        obj[RK.remoteAddr] = .string(remoteAddr)
        obj[RK.remotePort] = .number(RegoNumber(int: Int64(remotePort)))
        obj[RK.localPort] = .number(RegoNumber(int: Int64(localPort)))
        obj[RK.direction] = .string(direction)
        obj[RK.protocol] = .string(`protocol`)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeIcmpEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.startTime] = .number(RegoNumber(decimal: Decimal(startTime)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.procName] = .string(procName)
        obj[RK.remoteAddr] = .string(remoteAddr)
        obj[RK.family] = .string(family)
        obj[RK.icmpType] = .number(RegoNumber(int: Int64(icmpType)))
        obj[RK.icmpCode] = .number(RegoNumber(int: Int64(icmpCode)))
        obj[RK.identifier] = .number(RegoNumber(int: Int64(identifier)))
        obj[RK.sequence] = .number(RegoNumber(int: Int64(sequence)))
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeDnsEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.startTime] = .number(RegoNumber(decimal: Decimal(startTime)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.procName] = .string(procName)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.rowtype] = .string(rowtype)
        obj[RK.serverAddr] = .string(serverAddr)
        obj[RK.serverPort] = .number(RegoNumber(int: Int64(serverPort)))
        obj[RK.family] = .string(family)
        obj[RK.transactionId] = .number(RegoNumber(int: Int64(transactionId)))
        obj[RK.qtype] = .string(qtype)
        obj[RK.qname] = .string(qname)
        obj[RK.rcode] = .string(rcode)
        obj[RK.answerCount] = .number(RegoNumber(int: Int64(answerCount)))
        obj[RK.rdata] = .string(rdata)
        obj[RK.qnameSE] = .number(RegoNumber(decimal: Decimal(qnameSE)))
        obj[RK.subqname] = .string(subqname)
        obj[RK.subqnameSE] = .number(RegoNumber(decimal: Decimal(subqnameSE)))
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeDeviceOpenEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.devicePath] = .string(devicePath)
        obj[RK.deviceMajor] = .number(RegoNumber(int: Int64(deviceMajor)))
        obj[RK.deviceMinor] = .number(RegoNumber(int: Int64(deviceMinor)))
        obj[RK.deviceClass] = .string(deviceClass)
        obj[RK.executable] = .string(executable)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeBlockKillEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.sourcePid] = .number(RegoNumber(int: Int64(sourcePid)))
        obj[RK.signal] = .number(RegoNumber(int: Int64(signal)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeNewFsExecEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.executable] = .string(executable)
        obj[RK.hash] = .string(hash)
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.processPath] = .string(processPath)
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeBlockedExecEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.executable] = .string(executable)
        obj[RK.hash] = .string(hash)
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.blocking_mode] = .string(blocking_mode)
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeScriptSecurityEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.script_path] = .string(script_path)
        obj[RK.hash] = .string(hash)
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        obj[RK.blocking_mode] = .string(blocking_mode)
        obj[RK.is_inline_code] = .boolean(is_inline_code)
        obj[RK.is_piped_stdin] = .boolean(is_piped_stdin)
        obj[RK.is_no_args] = .boolean(is_no_args)
        obj[RK.allowed] = .boolean(allowed)
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeSSHLoginEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.srcAddr] = .string(srcAddr)
        obj[RK.username] = .string(username)
        obj[RK.success] = .boolean(success)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.tty] = .string(tty)
        obj[RK.sessionId] = .string(sessionId)
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeSSHLogoutEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.srcAddr] = .string(srcAddr)
        obj[RK.username] = .string(username)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.sessionDuration] = .number(RegoNumber(decimal: Decimal(sessionDuration)))
        obj[RK.sessionId] = .string(sessionId)
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeProcForkEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.startTime] = .number(RegoNumber(decimal: Decimal(startTime)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.comm] = .string(comm)
        obj[RK.parentExe] = .string(parentExe)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeFileOpenEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.path] = .string(path)
        obj[RK.flags] = .number(RegoNumber(int: Int64(flags)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.executable] = .string(executable)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeFileWriteEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.path] = .string(path)
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.executable] = .string(executable)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeFileUnlinkEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.path] = .string(path)
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.executable] = .string(executable)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeSetuidEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.oldUid] = .number(RegoNumber(int: Int64(oldUid)))
        obj[RK.newUid] = .number(RegoNumber(int: Int64(newUid)))
        obj[RK.oldEuid] = .number(RegoNumber(int: Int64(oldEuid)))
        obj[RK.newEuid] = .number(RegoNumber(int: Int64(newEuid)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.executable] = .string(executable)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeSetgidEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.oldGid] = .number(RegoNumber(int: Int64(oldGid)))
        obj[RK.newGid] = .number(RegoNumber(int: Int64(newGid)))
        obj[RK.oldEgid] = .number(RegoNumber(int: Int64(oldEgid)))
        obj[RK.newEgid] = .number(RegoNumber(int: Int64(newEgid)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.executable] = .string(executable)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeAFAlgBindEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.salgType] = .string(salgType)
        obj[RK.salgName] = .string(salgName)
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.executable] = .string(executable)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        obj[RK.blocking_mode] = .string(blocking_mode)
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeModuleLoadRequestEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.moduleName] = .string(moduleName)
        obj[RK.filePath] = .string(filePath)
        obj[RK.hook] = .string(hook)
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.executable] = .string(executable)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        obj[RK.blocking_mode] = .string(blocking_mode)
        return .object(obj)
    }
}

extension EhprobeGenerator.EhprobeXfrmSaNewEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.userNsInum] = .number(RegoNumber(value: userNsInum))
        obj[RK.saFlags] = .number(RegoNumber(int: Int64(saFlags)))
        obj[RK.aeadName] = .string(aeadName)
        obj[RK.authName] = .string(authName)
        obj[RK.cryptName] = .string(cryptName)
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.executable] = .string(executable)
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        obj[RK.blocking_mode] = .string(blocking_mode)
        return .object(obj)
    }
}


extension EhprobeGenerator {
    public struct EhprobePacketDataEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .network
        public var event_type: String = "ehprobe_packet_data"

        public init() {}

        public init(
            pid: Int64 = 0,
            procName: String = "",
            family: UInt32 = 0,
            networkProtocol: UInt32 = 0,
            remoteAddr: String = "",
            remotePort: UInt16 = 0,
            localPort: UInt16 = 0,
            direction: String = "",
            payload: Data = Data(),
            payloadLen: UInt32 = 0,
            containerId: UInt64 = 0,
            containerLevel: UInt32 = 0,
            ifindex: UInt32 = 0
        ) {
            self.pid = pid
            self.procName = procName
            self.family = family
            self.networkProtocol = networkProtocol
            self.remoteAddr = remoteAddr
            self.remotePort = remotePort
            self.localPort = localPort
            self.direction = direction
            self.payload = payload
            self.payloadLen = payloadLen
            self.containerId = containerId
            self.containerLevel = containerLevel
            self.ifindex = ifindex
        }

        public var pid: Int64 = 0
        public var procName: String = ""
        public var family: UInt32 = 0
        public var networkProtocol: UInt32 = 0
        public var remoteAddr: String = ""
        public var remotePort: UInt16 = 0
        public var localPort: UInt16 = 0
        public var direction: String = ""
        public var payload = Data()
        public var payloadLen: UInt32 = 0
        public var containerId: UInt64 = 0
        public var containerLevel: UInt32 = 0
        public var ifindex: UInt32 = 0
    }
}

extension EhprobeGenerator.EhprobePacketDataEvent: EHFieldExtractable {
    public func fieldValue(for key: String) -> Any? {
        switch key {
        case "event_type": return event_type
        case "event_category": return event_category
        case "pid": return pid
        case "procName": return procName
        case "family": return family
        case "networkProtocol": return networkProtocol
        case "remoteAddr": return remoteAddr
        case "remotePort": return remotePort
        case "localPort": return localPort
        case "direction": return direction
        case "payload": return payload
        case "payloadLen": return payloadLen
        case "containerId": return containerId
        case "containerLevel": return containerLevel
        case "ifindex": return ifindex
        default: return nil
        }
    }
}

extension EhprobeGenerator.EhprobePacketDataEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.procName] = .string(procName)
        obj[RK.family] = .number(RegoNumber(int: Int64(family)))
        obj[RK.networkProtocol] = .number(RegoNumber(int: Int64(networkProtocol)))
        obj[RK.remoteAddr] = .string(remoteAddr)
        obj[RK.remotePort] = .number(RegoNumber(int: Int64(remotePort)))
        obj[RK.localPort] = .number(RegoNumber(int: Int64(localPort)))
        obj[RK.direction] = .string(direction)
        obj[RK.payload] = .string(payload.base64EncodedString())
        obj[RK.payloadLen] = .number(RegoNumber(int: Int64(payloadLen)))
        obj[RK.containerId] = .number(RegoNumber(value: containerId))
        obj[RK.containerLevel] = .number(RegoNumber(int: Int64(containerLevel)))
        obj[RK.ifindex] = .number(RegoNumber(int: Int64(ifindex)))
        return .object(obj)
    }
}
