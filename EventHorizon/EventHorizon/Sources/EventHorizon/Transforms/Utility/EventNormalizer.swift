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

public final class EventNormalizer: EHTransform, AllEventsIterable {
    public static let allEvents: [any EHUEFEvent.Type] = [
        NormalizedProcess.self,
        NormalizedNetwork.self,
        NormalizedDns.self,
        NormalizedDevice.self,
        NormalizedSSH.self,
        NormalizedFile.self
    ]

    public let name = "EventNormalizer"
    public enum Tags: String {
        case stdin_redirected_to_pipe
        case stdout_redirected_to_pipe
        case stderr_redirected_to_pipe
    }


    public protocol ProcessNormalizable: EHUEFEvent {
        var n_args: [String] { get }
        var n_pid: Int64 { get }
        var n_ppid: Int64 { get }
        var n_exe: String { get }
        var n_start_time: Double { get }
        var n_cwd: String { get }
        var n_non_normalizable: [String: EHValueType] { get }
        var n_tty: String { get }
        var n_uid: UInt32 { get }
        var n_euid: UInt32 { get }
        var n_gid: UInt32 { get }
        var n_p_exe: String { get }
        var n_fd_count: UInt32 { get }
        var n_fd_pipe_ids: [UInt64] { get }
    }


    public protocol NetworkNormalizable: EHUEFEvent {
        var n_pid: Int64 { get }

        var n_proc_name: String { get }

        var n_remote_addr: String { get }

        var n_remote_port: UInt16 { get }

        var n_local_port: UInt16 { get }

        var n_direction: String { get }

        var n_protocol: String { get }

        var n_uid: UInt32 { get }

        var n_start_time: Double { get }

        var n_non_normalizable: [String: EHValueType] { get }
    }


    public protocol DnsNormalizable: EHUEFEvent {
        var n_pid: Int64 { get }

        var n_proc_name: String { get }

        var n_rowtype: String { get }

        var n_qname: String { get }

        var n_qtype: String { get }

        var n_rcode: String { get }

        var n_rdata: String { get }

        var n_qname_entropy: Double { get }

        var n_subqname: String { get }

        var n_subqname_entropy: Double { get }

        var n_start_time: Double { get }

        var n_non_normalizable: [String: EHValueType] { get }
    }


    public protocol DeviceOpenNormalizable: EHUEFEvent {
        var n_timestamp: Double { get }

        var n_pid: Int64 { get }

        var n_executable: String { get }

        var n_device_identifier: String { get }

        var n_device_path: String { get }

        var n_device_major: UInt32? { get }

        var n_device_minor: UInt32? { get }

        var n_non_normalizable: [String: EHValueType] { get }
    }


    public protocol SSHNormalizable: EHUEFEvent {
        var n_start_time: Double { get }

        var n_src_addr: String { get }

        var n_username: String { get }

        var n_success: Bool { get }

        var n_uid: UInt32 { get }

        var n_pid: Int64 { get }

        var n_tty: String { get }

        var n_session_id: String { get }

        var n_action: String { get }

        var n_session_duration: Double { get }

        var n_non_normalizable: [String: EHValueType] { get }
    }


    public protocol FileNormalizable: EHUEFEvent {
        var n_action: String { get }

        var n_timestamp: Double { get }

        var n_path: String { get }

        var n_size: Int64 { get }

        var n_flags: Int32 { get }

        var n_exe: String { get }

        var n_pid: Int64 { get }

        var n_ppid: Int64 { get }

        var n_uid: UInt32 { get }

        var n_non_normalizable: [String: EHValueType] { get }
    }

    protocol NormalizableEvent: EHUEFEvent {
        var non_normalizable: [String: EHValueType] { get }
    }


    public struct NormalizedProcess: NormalizableEvent, UsernameEnricher.UsernameEnrichable, GroupnameEnricher.GroupnameEnrichable {
        public enum Tags: String {
            case fork_only
        }

        public func gid_properties() -> ([String]?, [String]?) {
            return (nil, ["gid", "p_gid"])
        }

        public func uid_properties() -> ([String]?, [String]?) {
            return (nil, ["uid"])
        }

        public init(tags: Set<String> = Set<String>(), event_category: EHUEFCategory = .process, event_type: String = "normalized_process", fields: [String: EHValueType] = [:], non_normalizable: [String: EHValueType] = [:], start_time: Double = 0, cwd: String = "", args: [String] = [], exe: String = "", tty: String = "", pid: Int64 = 0, uid: UInt32 = 0, euid: UInt32 = 0, gid: UInt32 = 0, ppid: Int64 = 0, p_exe: String = "", fd_count: UInt32 = 0, fd_pipe_ids: [UInt64] = [], p_start_time: Double = 0, p_gid: UInt32 = 0) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.non_normalizable = non_normalizable
            self.start_time = start_time
            self.cwd = cwd
            self.args = args
            self._cmdline = args.joined(separator: " ")
            self.exe = exe
            self.tty = tty
            self.pid = pid
            self.uid = uid
            self.euid = euid
            self.gid = gid
            self.ppid = ppid
            self.p_exe = p_exe
            self.fd_count = fd_count
            self.fd_pipe_ids = fd_pipe_ids
            self.p_start_time = p_start_time
            self.p_gid = p_gid
        }

        public init() {}
        public init(_ from: any ProcessNormalizable) {
            self.metadata = from.metadata
            self.start_time = from.n_start_time
            self.cwd = from.n_cwd
            self.args = from.n_args
            self._cmdline = from.n_args.joined(separator: " ")
            self.exe = from.n_exe
            self.tty = from.n_tty
            self.pid = from.n_pid
            self.uid = from.n_uid
            self.euid = from.n_euid
            self.gid = from.n_gid
            self.ppid = from.n_ppid
            self.p_exe = from.n_p_exe
            self.non_normalizable = from.n_non_normalizable
            self.fd_count = from.n_fd_count
            self.fd_pipe_ids = from.n_fd_pipe_ids
        }
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "normalized_process"

        public var non_normalizable: [String: EHValueType] = [:]

        public var start_time: Double = 0

        public var cwd: String = ""

        public var args: [String] = [] {
            didSet {
                _cmdline = args.joined(separator: " ")
            }
        }

        @CodableIgnored private var _cmdline: String?

        private enum CodingKeys: String, CodingKey {
            case metadata, event_category, event_type, non_normalizable
            case start_time, cwd, args, exe, tty, pid, uid, euid, gid
            case ppid, p_exe, fd_count, fd_pipe_ids, p_start_time, p_gid
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.metadata = try c.decodeIfPresent(EHEventMetadata.self, forKey: .metadata) ?? EHEventMetadata()
            self.event_category = try c.decodeIfPresent(EHUEFCategory.self, forKey: .event_category) ?? .process
            self.event_type = try c.decodeIfPresent(String.self, forKey: .event_type) ?? "normalized_process"
            self.non_normalizable = try c.decodeIfPresent([String: EHValueType].self, forKey: .non_normalizable) ?? [:]
            self.start_time = try c.decodeIfPresent(Double.self, forKey: .start_time) ?? 0
            self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
            let decodedArgs = try c.decodeIfPresent([String].self, forKey: .args) ?? []
            self.args = decodedArgs
            self._cmdline = decodedArgs.joined(separator: " ")
            self.exe = try c.decodeIfPresent(String.self, forKey: .exe) ?? ""
            self.tty = try c.decodeIfPresent(String.self, forKey: .tty) ?? ""
            self.pid = try c.decodeIfPresent(Int64.self, forKey: .pid) ?? 0
            self.uid = try c.decodeIfPresent(UInt32.self, forKey: .uid) ?? 0
            self.euid = try c.decodeIfPresent(UInt32.self, forKey: .euid) ?? 0
            self.gid = try c.decodeIfPresent(UInt32.self, forKey: .gid) ?? 0
            self.ppid = try c.decodeIfPresent(Int64.self, forKey: .ppid) ?? 0
            self.p_exe = try c.decodeIfPresent(String.self, forKey: .p_exe) ?? ""
            self.fd_count = try c.decodeIfPresent(UInt32.self, forKey: .fd_count) ?? 0
            self.fd_pipe_ids = try c.decodeIfPresent([UInt64].self, forKey: .fd_pipe_ids) ?? []
            self.p_start_time = try c.decodeIfPresent(Double.self, forKey: .p_start_time) ?? 0
            self.p_gid = try c.decodeIfPresent(UInt32.self, forKey: .p_gid) ?? 0
        }

        public var exe: String = ""

        public var tty: String = ""

        public var pid: Int64 = 0

        public var uid: UInt32 = 0

        public var euid: UInt32 = 0

        public var gid: UInt32 = 0

        public var ppid: Int64 = 0

        public var p_exe: String = ""

        public var fd_count: UInt32 = 0

        public var fd_pipe_ids: [UInt64] = []

        public var p_start_time: Double = 0

        public var p_gid: UInt32 = 0


        public var cmdline: String {
            if let cached = _cmdline {
                return cached
            }
            return args.joined(separator: " ")
        }
    }


    public struct NormalizedNetwork: NormalizableEvent, UsernameEnricher.UsernameEnrichable, EHProcessTreeEnrichable {
        public func uid_properties() -> ([String]?, [String]?) {
            return (nil, ["uid"])
        }

        public init() {}

        public init(
            tags: Set<String> = Set<String>(),
            event_category: EHUEFCategory = .network,
            event_type: String = "normalized_network",
            fields: [String: EHValueType] = [:],
            non_normalizable: [String: EHValueType] = [:],
            start_time: Double = 0,
            pid: Int64 = 0,
            proc_name: String = "",
            remote_addr: String = "",
            remote_port: UInt16 = 0,
            local_port: UInt16 = 0,
            direction: String = "",
            `protocol`: String = "",
            uid: UInt32 = 0,
            pid_start_time: Double = 0,
            p_pid: Int64 = 0,
            p_pid_start_time: Double = 0,
            p_exe: String = "",
            exe: String = ""
        ) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.non_normalizable = non_normalizable
            self.start_time = start_time
            self.pid = pid
            self.proc_name = proc_name
            self.remote_addr = remote_addr
            self.remote_port = remote_port
            self.local_port = local_port
            self.direction = direction
            self.protocol = `protocol`
            self.uid = uid
            self.pid_start_time = pid_start_time
            self.p_pid = p_pid
            self.p_pid_start_time = p_pid_start_time
            self.p_exe = p_exe
            self.exe = exe
        }

        public init(_ from: any NetworkNormalizable) {
            self.metadata = from.metadata
            self.non_normalizable = from.n_non_normalizable
            self.start_time = from.n_start_time
            self.pid = from.n_pid
            self.proc_name = from.n_proc_name
            self.remote_addr = from.n_remote_addr
            self.remote_port = from.n_remote_port
            self.local_port = from.n_local_port
            self.direction = from.n_direction
            self.protocol = from.n_protocol
            self.uid = from.n_uid
        }

        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .network
        public var event_type: String = "normalized_network"

        public var non_normalizable: [String: EHValueType] = [:]

        public var start_time: Double = 0

        public var pid: Int64 = 0

        public var proc_name: String = ""

        public var remote_addr: String = ""

        public var remote_port: UInt16 = 0

        public var local_port: UInt16 = 0

        public var direction: String = ""

        public var `protocol`: String = ""

        public var uid: UInt32 = 0

        public var pid_start_time: Double = 0

        public var p_pid: Int64 = 0

        public var p_pid_start_time: Double = 0

        public var p_exe: String = ""

        public var exe: String = ""


        public var remote_endpoint: String {
            "\(remote_addr):\(remote_port)"
        }

        public var is_ipv6: Bool {
            remote_addr.contains(":")
        }
    }


    public struct NormalizedDns: NormalizableEvent {
        public init() {}

        public init(
            tags: Set<String> = Set<String>(),
            event_category: EHUEFCategory = .network,
            event_type: String = "normalized_dns",
            fields: [String: EHValueType] = [:],
            non_normalizable: [String: EHValueType] = [:],
            start_time: Double = 0,
            pid: Int64 = 0,
            proc_name: String = "",
            rowtype: String = "",
            qname: String = "",
            qtype: String = "",
            rcode: String = "",
            rdata: String = "",
            qname_entropy: Double = 0,
            subqname: String = "",
            subqname_entropy: Double = 0
        ) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.non_normalizable = non_normalizable
            self.start_time = start_time
            self.pid = pid
            self.proc_name = proc_name
            self.rowtype = rowtype
            self.qname = qname
            self.qtype = qtype
            self.rcode = rcode
            self.rdata = rdata
            self.qname_entropy = qname_entropy
            self.subqname = subqname
            self.subqname_entropy = subqname_entropy
        }

        public init(_ from: any DnsNormalizable) {
            self.metadata = from.metadata
            self.non_normalizable = from.n_non_normalizable
            self.start_time = from.n_start_time
            self.pid = from.n_pid
            self.proc_name = from.n_proc_name
            self.rowtype = from.n_rowtype
            self.qname = from.n_qname
            self.qtype = from.n_qtype
            self.rcode = from.n_rcode
            self.rdata = from.n_rdata
            self.qname_entropy = from.n_qname_entropy
            self.subqname = from.n_subqname
            self.subqname_entropy = from.n_subqname_entropy
        }

        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .network
        public var event_type: String = "normalized_dns"

        public var non_normalizable: [String: EHValueType] = [:]

        public var start_time: Double = 0

        public var pid: Int64 = 0

        public var proc_name: String = ""

        public var rowtype: String = ""

        public var qname: String = ""

        public var qtype: String = ""

        public var rcode: String = ""

        public var rdata: String = ""

        public var qname_entropy: Double = 0

        public var subqname: String = ""

        public var subqname_entropy: Double = 0


        public var is_query: Bool {
            rowtype == "start"
        }

        public var is_response: Bool {
            rowtype == "result"
        }

        public var is_successful: Bool {
            rcode == "NOERROR" || rcode.isEmpty
        }

        public var is_nxdomain: Bool {
            rcode == "NXDOMAIN"
        }

        public var qname_normalized: String {
            qname.hasSuffix(".") ? String(qname.dropLast()) : qname
        }
    }


    public struct NormalizedDevice: NormalizableEvent {
        public init() {}

        public init(
            tags: Set<String> = Set<String>(),
            event_category: EHUEFCategory = .resource,
            event_type: String = "normalized_device",
            fields: [String: EHValueType] = [:],
            non_normalizable: [String: EHValueType] = [:],
            timestamp: Double = 0,
            pid: Int64 = 0,
            executable: String = "",
            device_identifier: String = "",
            device_path: String = "",
            device_major: UInt32? = nil,
            device_minor: UInt32? = nil
        ) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.non_normalizable = non_normalizable
            self.timestamp = timestamp
            self.pid = pid
            self.executable = executable
            self.device_identifier = device_identifier
            self.device_path = device_path
            self.device_major = device_major
            self.device_minor = device_minor
        }

        public init(_ from: any DeviceOpenNormalizable) {
            self.metadata = from.metadata
            self.non_normalizable = from.n_non_normalizable
            self.timestamp = from.n_timestamp
            self.pid = from.n_pid
            self.executable = from.n_executable
            self.device_identifier = from.n_device_identifier
            self.device_path = from.n_device_path
            self.device_major = from.n_device_major
            self.device_minor = from.n_device_minor
        }

        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .resource
        public var event_type: String = "normalized_device"

        public var non_normalizable: [String: EHValueType] = [:]

        public var timestamp: Double = 0

        public var pid: Int64 = 0

        public var executable: String = ""

        public var device_identifier: String = ""

        public var device_path: String = ""

        public var device_major: UInt32?

        public var device_minor: UInt32?
    }


    public struct NormalizedSSH: NormalizableEvent, UsernameEnricher.UsernameEnrichable {
        public func uid_properties() -> ([String]?, [String]?) {
            return (nil, ["uid"])
        }

        public init() {}

        public init(
            tags: Set<String> = Set<String>(),
            event_category: EHUEFCategory = .system,
            event_type: String = "normalized_ssh",
            fields: [String: EHValueType] = [:],
            non_normalizable: [String: EHValueType] = [:],
            start_time: Double = 0,
            src_addr: String = "",
            username: String = "",
            success: Bool = false,
            uid: UInt32 = 0,
            pid: Int64 = 0,
            tty: String = "",
            session_id: String = "",
            action: String = "",
            session_duration: Double = 0
        ) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.non_normalizable = non_normalizable
            self.start_time = start_time
            self.src_addr = src_addr
            self.username = username
            self.success = success
            self.uid = uid
            self.pid = pid
            self.tty = tty
            self.session_id = session_id
            self.action = action
            self.session_duration = session_duration
        }

        public init(_ from: any SSHNormalizable) {
            self.metadata = from.metadata
            self.non_normalizable = from.n_non_normalizable
            self.start_time = from.n_start_time
            self.src_addr = from.n_src_addr
            self.username = from.n_username
            self.success = from.n_success
            self.uid = from.n_uid
            self.pid = from.n_pid
            self.tty = from.n_tty
            self.session_id = from.n_session_id
            self.action = from.n_action
            self.session_duration = from.n_session_duration
        }

        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .system
        public var event_type: String = "normalized_ssh"

        public var non_normalizable: [String: EHValueType] = [:]

        public var start_time: Double = 0

        public var src_addr: String = ""

        public var username: String = ""

        public var success: Bool = false

        public var uid: UInt32 = 0

        public var pid: Int64 = 0

        public var tty: String = ""

        public var session_id: String = ""

        public var action: String = ""

        public var session_duration: Double = 0
    }


    public struct NormalizedFile: NormalizableEvent, UsernameEnricher.UsernameEnrichable {
        public enum Action: String {
            case open
            case unlink
            case rename
            case create
            case write
            case chmod
        }

        public func uid_properties() -> ([String]?, [String]?) {
            return (nil, ["uid"])
        }

        public init() {}

        public init(
            tags: Set<String> = Set<String>(),
            event_category: EHUEFCategory = .file,
            event_type: String = "normalized_file",
            fields: [String: EHValueType] = [:],
            non_normalizable: [String: EHValueType] = [:],
            action: String = Action.open.rawValue,
            timestamp: Double = 0,
            path: String = "",
            size: Int64 = 0,
            flags: Int32 = 0,
            exe: String = "",
            pid: Int64 = 0,
            ppid: Int64 = 0,
            uid: UInt32 = 0
        ) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.non_normalizable = non_normalizable
            self.action = action
            self.timestamp = timestamp
            self.path = path
            self.size = size
            self.flags = flags
            self.exe = exe
            self.pid = pid
            self.ppid = ppid
            self.uid = uid
        }

        public init(_ from: any FileNormalizable) {
            self.metadata = from.metadata
            self.non_normalizable = from.n_non_normalizable
            self.action = from.n_action
            self.timestamp = from.n_timestamp
            self.path = from.n_path
            self.size = from.n_size
            self.flags = from.n_flags
            self.exe = from.n_exe
            self.pid = from.n_pid
            self.ppid = from.n_ppid
            self.uid = from.n_uid
        }

        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .file
        public var event_type: String = "normalized_file"

        public var non_normalizable: [String: EHValueType] = [:]

        public var action: String = Action.open.rawValue

        public var timestamp: Double = 0

        public var path: String = ""

        public var size: Int64 = 0

        public var flags: Int32 = 0

        public var exe: String = ""

        public var pid: Int64 = 0

        public var ppid: Int64 = 0

        public var uid: UInt32 = 0
    }


    public enum Normalizations: CaseIterable, Sendable {
        case process
        case network
        case dns
        case device
        case ssh
        case file
    }

    let normalizations: Set<Normalizations>


    public typealias NormalizerFunc = @Sendable (any EHUEFEvent) -> (any EHUEFEvent)?

    private let dispatchTable: [String: (Normalizations, NormalizerFunc)]

    public static func buildDispatchTable() -> [String: (Normalizations, NormalizerFunc)] {
        var table: [String: (Normalizations, NormalizerFunc)] = [:]

        table[ESClient.ESClientProcExecEvent().event_type] = (.process, { event in
            guard let e = event as? ESClient.ESClientProcExecEvent else {
                return nil
            }
            return NormalizedProcess(e)
        })
        table[ESClient.ESClientProcForkEvent().event_type] = (.process, { event in
            guard let e = event as? ESClient.ESClientProcForkEvent else {
                return nil
            }
            return NormalizedProcess(e)
        })

        table[ESClient.ESClientIOKitOpenEvent().event_type] = (.device, { event in
            guard let e = event as? ESClient.ESClientIOKitOpenEvent else {
                return nil
            }
            return NormalizedDevice(e)
        })

        table[ESClient.ESClientSSHLoginEvent().event_type] = (.ssh, { event in
            guard let e = event as? ESClient.ESClientSSHLoginEvent else {
                return nil
            }
            return NormalizedSSH(e)
        })
        table[ESClient.ESClientSSHLogoutEvent().event_type] = (.ssh, { event in
            guard let e = event as? ESClient.ESClientSSHLogoutEvent else {
                return nil
            }
            return NormalizedSSH(e)
        })

        table[ESClient.ESClientFileOpenEvent().event_type] = (.file, { event in
            guard let e = event as? ESClient.ESClientFileOpenEvent else {
                return nil
            }
            return NormalizedFile(e)
        })
        table[ESClient.ESClientFileWriteEvent().event_type] = (.file, { event in
            guard let e = event as? ESClient.ESClientFileWriteEvent else {
                return nil
            }
            return NormalizedFile(e)
        })
        table[ESClient.ESClientFileCreateEvent().event_type] = (.file, { event in
            guard let e = event as? ESClient.ESClientFileCreateEvent else {
                return nil
            }
            return NormalizedFile(e)
        })
        table[ESClient.ESClientFileUnlinkEvent().event_type] = (.file, { event in
            guard let e = event as? ESClient.ESClientFileUnlinkEvent else {
                return nil
            }
            return NormalizedFile(e)
        })

        table[ESClient.ESClientProcExitEvent().event_type] = (.process, { _ in nil })

        table[EhprobeGenerator.EhprobeNetworkEvent().event_type] = (.network, { event in
            guard let e = event as? EhprobeGenerator.EhprobeNetworkEvent else {
                return nil
            }
            return NormalizedNetwork(e)
        })

        table[EhprobeGenerator.EhprobeIcmpEvent().event_type] = (.network, { event in
            guard let e = event as? EhprobeGenerator.EhprobeIcmpEvent else {
                return nil
            }
            return NormalizedNetwork(e)
        })

        table[EhprobeGenerator.EhprobeDnsEvent().event_type] = (.dns, { event in
            guard let e = event as? EhprobeGenerator.EhprobeDnsEvent else {
                return nil
            }
            return NormalizedDns(e)
        })

        table[EhprobeGenerator.EhprobeDeviceOpenEvent().event_type] = (.device, { event in
            guard let e = event as? EhprobeGenerator.EhprobeDeviceOpenEvent else {
                return nil
            }
            return NormalizedDevice(e)
        })

        table[EhprobeGenerator.EhprobeSSHLoginEvent().event_type] = (.ssh, { event in
            guard let e = event as? EhprobeGenerator.EhprobeSSHLoginEvent else {
                return nil
            }
            return NormalizedSSH(e)
        })
        table[EhprobeGenerator.EhprobeSSHLogoutEvent().event_type] = (.ssh, { event in
            guard let e = event as? EhprobeGenerator.EhprobeSSHLogoutEvent else {
                return nil
            }
            return NormalizedSSH(e)
        })

        table[EhprobeGenerator.EhprobeProcForkEvent().event_type] = (.process, { event in
            guard let e = event as? EhprobeGenerator.EhprobeProcForkEvent else {
                return nil
            }
            return NormalizedProcess(e)
        })

        table[EhprobeGenerator.EhprobeFileOpenEvent().event_type] = (.file, { event in
            guard let e = event as? EhprobeGenerator.EhprobeFileOpenEvent else {
                return nil
            }
            return NormalizedFile(e)
        })
        table[EhprobeGenerator.EhprobeFileWriteEvent().event_type] = (.file, { event in
            guard let e = event as? EhprobeGenerator.EhprobeFileWriteEvent else {
                return nil
            }
            return NormalizedFile(e)
        })
        table[EhprobeGenerator.EhprobeFileUnlinkEvent().event_type] = (.file, { event in
            guard let e = event as? EhprobeGenerator.EhprobeFileUnlinkEvent else {
                return nil
            }
            return NormalizedFile(e)
        })

        table[EhprobeGenerator.EhprobeSetuidEvent().event_type] = (.process, { _ in nil })
        table[EhprobeGenerator.EhprobeSetgidEvent().event_type] = (.process, { _ in nil })
        table[EhprobeGenerator.EhprobeBlockKillEvent().event_type] = (.process, { _ in nil })
        table[EhprobeGenerator.EhprobeNewFsExecEvent().event_type] = (.process, { _ in nil })
        table[EhprobeGenerator.EhprobeBlockedExecEvent().event_type] = (.process, { _ in nil })
        table[EhprobeGenerator.EhprobePacketDataEvent().event_type] = (.network, { _ in nil })

        return table
    }

    public init(_ normalizations: Set<Normalizations> = Set(Normalizations.allCases)) {
        self.normalizations = normalizations
        self.dispatchTable = Self.buildDispatchTable()
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        if let (normalizationType, normalizer) = dispatchTable[event.event_type] {
            if normalizations.contains(normalizationType) {
                if let normalizedEvent = normalizer(event) {
                    return (.proceed_mutated, [normalizedEvent], nil, nil)
                }
            }
            return (.proceed, [event], nil, nil)
        }

        return fallbackNormalize(event)
    }

    private func fallbackNormalize(_ event: any EHUEFEvent) -> EHTransformReturn {
        for normalization in normalizations {
            switch normalization {
            case .process:
                if let event = event as? ProcessNormalizable {
                    return (.proceed_mutated, [NormalizedProcess(event)], nil, nil)
                }
            case .network:
                if let event = event as? NetworkNormalizable {
                    return (.proceed_mutated, [NormalizedNetwork(event)], nil, nil)
                }
            case .dns:
                if let event = event as? DnsNormalizable {
                    return (.proceed_mutated, [NormalizedDns(event)], nil, nil)
                }
            case .device:
                if let event = event as? DeviceOpenNormalizable {
                    return (.proceed_mutated, [NormalizedDevice(event)], nil, nil)
                }
            case .ssh:
                if let event = event as? SSHNormalizable {
                    return (.proceed_mutated, [NormalizedSSH(event)], nil, nil)
                }
            case .file:
                if let event = event as? FileNormalizable {
                    return (.proceed_mutated, [NormalizedFile(event)], nil, nil)
                }
            }
        }
        return (.proceed, [event], nil, nil)
    }

    public func configure() async throws {
    }
}


extension EventNormalizer.NormalizedProcess: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(exe)
        hasher.combine(cwd)
        hasher.combine(uid)
        for arg in args { hasher.combine(arg) }
        return hasher.finalize()
    }
}

extension EventNormalizer.NormalizedNetwork: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(proc_name)
        hasher.combine(remote_addr)
        hasher.combine(remote_port)
        hasher.combine(self.protocol)
        return hasher.finalize()
    }
}

extension EventNormalizer.NormalizedDns: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(proc_name)
        hasher.combine(qname)
        hasher.combine(qtype)
        hasher.combine(rowtype)
        return hasher.finalize()
    }
}

extension EventNormalizer.NormalizedDevice: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(executable)
        hasher.combine(device_identifier)
        hasher.combine(device_path)
        return hasher.finalize()
    }
}

extension EventNormalizer.NormalizedSSH: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(start_time)
        hasher.combine(src_addr)
        hasher.combine(username)
        hasher.combine(session_id)
        hasher.combine(action)
        return hasher.finalize()
    }
}

extension EventNormalizer.NormalizedFile: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(pid)
        hasher.combine(exe)
        hasher.combine(path)
        hasher.combine(action)
        hasher.combine(flags)
        return hasher.finalize()
    }
}


extension EventNormalizer.NormalizedProcess: EHFieldExtractable {
    public func fieldValue(for fieldName: String) -> Any? {
        switch fieldName {
        case "pid": return pid
        case "ppid": return ppid
        case "uid": return uid
        case "euid": return euid
        case "gid": return gid
        case "exe": return exe
        case "args": return args
        case "cwd": return cwd
        case "start_time": return start_time
        case "tty": return tty
        case "fd_count": return fd_count
        case "fd_pipe_ids": return fd_pipe_ids
        case "p_exe": return p_exe
        case "p_start_time": return p_start_time
        case "p_gid": return p_gid
        case "cmdline": return cmdline
        case "non_normalizable": return non_normalizable
        case "event_type": return event_type
        case "event_category": return event_category
        case "metadata": return metadata
        case "fields": return fields
        case "tags": return tags
        default:
            if let value = non_normalizable[fieldName] {
                return value.stringValue ?? value.intValue ?? value.doubleValue ?? value.boolValue
            }
            return nil
        }
    }
}

extension EventNormalizer.NormalizedNetwork: EHFieldExtractable {
    public func fieldValue(for fieldName: String) -> Any? {
        switch fieldName {
        case "pid": return pid
        case "uid": return uid
        case "start_time": return start_time
        case "proc_name": return proc_name
        case "remote_addr": return remote_addr
        case "remote_port": return remote_port
        case "local_port": return local_port
        case "direction": return direction
        case "protocol": return `protocol`
        case "pid_start_time": return pid_start_time
        case "p_pid": return p_pid
        case "p_pid_start_time": return p_pid_start_time
        case "p_exe": return p_exe
        case "exe": return exe
        case "remote_endpoint": return remote_endpoint
        case "is_ipv6": return is_ipv6
        case "non_normalizable": return non_normalizable
        case "event_type": return event_type
        case "event_category": return event_category
        case "metadata": return metadata
        case "fields": return fields
        case "tags": return tags
        default:
            if let value = non_normalizable[fieldName] {
                return value.stringValue ?? value.intValue ?? value.doubleValue ?? value.boolValue
            }
            return nil
        }
    }
}

extension EventNormalizer.NormalizedDns: EHFieldExtractable {
    public func fieldValue(for fieldName: String) -> Any? {
        switch fieldName {
        case "pid": return pid
        case "start_time": return start_time
        case "proc_name": return proc_name
        case "rowtype": return rowtype
        case "qname": return qname
        case "qtype": return qtype
        case "rcode": return rcode
        case "rdata": return rdata
        case "qname_entropy": return qname_entropy
        case "subqname": return subqname
        case "subqname_entropy": return subqname_entropy
        case "non_normalizable": return non_normalizable
        case "event_type": return event_type
        case "event_category": return event_category
        case "metadata": return metadata
        case "fields": return fields
        case "tags": return tags
        default:
            if let value = non_normalizable[fieldName] {
                return value.stringValue ?? value.intValue ?? value.doubleValue ?? value.boolValue
            }
            return nil
        }
    }
}

extension EventNormalizer.NormalizedDevice: EHFieldExtractable {
    public func fieldValue(for fieldName: String) -> Any? {
        switch fieldName {
        case "pid": return pid
        case "timestamp": return timestamp
        case "executable": return executable
        case "device_identifier": return device_identifier
        case "device_path": return device_path
        case "device_major": return device_major
        case "device_minor": return device_minor
        case "non_normalizable": return non_normalizable
        case "event_type": return event_type
        case "event_category": return event_category
        case "metadata": return metadata
        case "fields": return fields
        case "tags": return tags
        default:
            if let value = non_normalizable[fieldName] {
                return value.stringValue ?? value.intValue ?? value.doubleValue ?? value.boolValue
            }
            return nil
        }
    }
}

extension EventNormalizer.NormalizedSSH: EHFieldExtractable {
    public func fieldValue(for fieldName: String) -> Any? {
        switch fieldName {
        case "start_time": return start_time
        case "src_addr": return src_addr
        case "username": return username
        case "success": return success
        case "uid": return uid
        case "pid": return pid
        case "tty": return tty
        case "session_id": return session_id
        case "action": return action
        case "session_duration": return session_duration
        case "non_normalizable": return non_normalizable
        case "event_type": return event_type
        case "event_category": return event_category
        case "metadata": return metadata
        case "fields": return fields
        case "tags": return tags
        default:
            if let value = non_normalizable[fieldName] {
                return value.stringValue ?? value.intValue ?? value.doubleValue ?? value.boolValue
            }
            return nil
        }
    }
}

extension EventNormalizer.NormalizedFile: EHFieldExtractable {
    public func fieldValue(for fieldName: String) -> Any? {
        switch fieldName {
        case "action": return action
        case "timestamp": return timestamp
        case "path": return path
        case "size": return size
        case "flags": return flags
        case "exe": return exe
        case "pid": return pid
        case "ppid": return ppid
        case "uid": return uid
        case "non_normalizable": return non_normalizable
        case "event_type": return event_type
        case "event_category": return event_category
        case "metadata": return metadata
        case "fields": return fields
        case "tags": return tags
        default:
            if let value = non_normalizable[fieldName] {
                return value.stringValue ?? value.intValue ?? value.doubleValue ?? value.boolValue
            }
            return nil
        }
    }
}


import AST

private enum RK {
    static let event_type: AST.RegoValue = .string("event_type")
    static let event_category: AST.RegoValue = .string("event_category")
    static let tags: AST.RegoValue = .string("tags")
    static let fields: AST.RegoValue = .string("fields")
    static let non_normalizable: AST.RegoValue = .string("non_normalizable")
    static let start_time: AST.RegoValue = .string("start_time")
    static let timestamp: AST.RegoValue = .string("timestamp")
    static let cwd: AST.RegoValue = .string("cwd")
    static let args: AST.RegoValue = .string("args")
    static let exe: AST.RegoValue = .string("exe")
    static let tty: AST.RegoValue = .string("tty")
    static let pid: AST.RegoValue = .string("pid")
    static let uid: AST.RegoValue = .string("uid")
    static let euid: AST.RegoValue = .string("euid")
    static let gid: AST.RegoValue = .string("gid")
    static let ppid: AST.RegoValue = .string("ppid")
    static let p_exe: AST.RegoValue = .string("p_exe")
    static let fd_count: AST.RegoValue = .string("fd_count")
    static let fd_pipe_ids: AST.RegoValue = .string("fd_pipe_ids")
    static let p_start_time: AST.RegoValue = .string("p_start_time")
    static let p_gid: AST.RegoValue = .string("p_gid")
    static let cmdline: AST.RegoValue = .string("cmdline")
    static let proc_name: AST.RegoValue = .string("proc_name")
    static let remote_addr: AST.RegoValue = .string("remote_addr")
    static let remote_port: AST.RegoValue = .string("remote_port")
    static let local_port: AST.RegoValue = .string("local_port")
    static let direction: AST.RegoValue = .string("direction")
    static let `protocol`: AST.RegoValue = .string("protocol")
    static let pid_start_time: AST.RegoValue = .string("pid_start_time")
    static let p_pid: AST.RegoValue = .string("p_pid")
    static let p_pid_start_time: AST.RegoValue = .string("p_pid_start_time")
    static let rowtype: AST.RegoValue = .string("rowtype")
    static let qname: AST.RegoValue = .string("qname")
    static let qtype: AST.RegoValue = .string("qtype")
    static let rcode: AST.RegoValue = .string("rcode")
    static let rdata: AST.RegoValue = .string("rdata")
    static let qname_entropy: AST.RegoValue = .string("qname_entropy")
    static let subqname: AST.RegoValue = .string("subqname")
    static let subqname_entropy: AST.RegoValue = .string("subqname_entropy")
    static let executable: AST.RegoValue = .string("executable")
    static let device_identifier: AST.RegoValue = .string("device_identifier")
    static let device_path: AST.RegoValue = .string("device_path")
    static let device_major: AST.RegoValue = .string("device_major")
    static let device_minor: AST.RegoValue = .string("device_minor")
    static let src_addr: AST.RegoValue = .string("src_addr")
    static let username: AST.RegoValue = .string("username")
    static let success: AST.RegoValue = .string("success")
    static let session_id: AST.RegoValue = .string("session_id")
    static let action: AST.RegoValue = .string("action")
    static let session_duration: AST.RegoValue = .string("session_duration")
    static let path: AST.RegoValue = .string("path")
    static let size: AST.RegoValue = .string("size")
    static let flags: AST.RegoValue = .string("flags")
    static let exe_basename: AST.RegoValue = .string("exe_basename")
    static let p_exe_basename: AST.RegoValue = .string("p_exe_basename")
}

public func exeBasename(_ exe: String) -> String {
    guard let lastSlash = exe.lastIndex(of: "/") else {
        return exe
    }
    let afterSlash = exe.index(after: lastSlash)
    return String(exe[afterSlash...])
}

extension EventNormalizer.NormalizedProcess: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = Dictionary(minimumCapacity: 22)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.non_normalizable] = non_normalizable.toRegoValue()
        obj[RK.start_time] = .number(RegoNumber(decimal: Decimal(start_time)))
        obj[RK.cwd] = .string(cwd)
        obj[RK.args] = .array(args.map { .string($0) })
        obj[RK.exe] = .string(exe)
        obj[RK.tty] = .string(tty)
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.euid] = .number(RegoNumber(int: Int64(euid)))
        obj[RK.gid] = .number(RegoNumber(int: Int64(gid)))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.p_exe] = .string(p_exe)
        obj[RK.fd_count] = .number(RegoNumber(int: Int64(fd_count)))
        obj[RK.fd_pipe_ids] = .array(fd_pipe_ids.map { .number(RegoNumber(value: $0)) })
        obj[RK.p_start_time] = .number(RegoNumber(decimal: Decimal(p_start_time)))
        obj[RK.p_gid] = .number(RegoNumber(int: Int64(p_gid)))
        obj[RK.cmdline] = .string(cmdline)
        obj[RK.exe_basename] = .string(exeBasename(exe))
        obj[RK.p_exe_basename] = .string(exeBasename(p_exe))
        return .object(obj)
    }
}

extension EventNormalizer.NormalizedNetwork: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = Dictionary(minimumCapacity: 22)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.non_normalizable] = non_normalizable.toRegoValue()
        obj[RK.start_time] = .number(RegoNumber(decimal: Decimal(start_time)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.proc_name] = .string(proc_name)
        obj[RK.remote_addr] = .string(remote_addr)
        obj[RK.remote_port] = .number(RegoNumber(int: Int64(remote_port)))
        obj[RK.local_port] = .number(RegoNumber(int: Int64(local_port)))
        obj[RK.direction] = .string(direction)
        obj[RK.protocol] = .string(`protocol`)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.pid_start_time] = .number(RegoNumber(decimal: Decimal(pid_start_time)))
        obj[RK.p_pid] = .number(RegoNumber(int: p_pid))
        obj[RK.p_pid_start_time] = .number(RegoNumber(decimal: Decimal(p_pid_start_time)))
        obj[RK.p_exe] = .string(p_exe)
        obj[RK.p_exe_basename] = .string(exeBasename(p_exe))
        obj[RK.exe] = .string(exe)
        obj[RK.exe_basename] = .string(exeBasename(exe))
        return .object(obj)
    }
}

extension EventNormalizer.NormalizedDns: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = Dictionary(minimumCapacity: 14)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.non_normalizable] = non_normalizable.toRegoValue()
        obj[RK.start_time] = .number(RegoNumber(decimal: Decimal(start_time)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.proc_name] = .string(proc_name)
        obj[RK.rowtype] = .string(rowtype)
        obj[RK.qname] = .string(qname)
        obj[RK.qtype] = .string(qtype)
        obj[RK.rcode] = .string(rcode)
        obj[RK.rdata] = .string(rdata)
        obj[RK.qname_entropy] = .number(RegoNumber(decimal: Decimal(qname_entropy)))
        obj[RK.subqname] = .string(subqname)
        obj[RK.subqname_entropy] = .number(RegoNumber(decimal: Decimal(subqname_entropy)))
        return .object(obj)
    }
}

extension EventNormalizer.NormalizedDevice: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = Dictionary(minimumCapacity: 12)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.non_normalizable] = non_normalizable.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.executable] = .string(executable)
        obj[RK.device_identifier] = .string(device_identifier)
        obj[RK.device_path] = .string(device_path)
        if let device_major {
            obj[RK.device_major] = .number(RegoNumber(int: Int64(device_major)))
        }
        if let device_minor {
            obj[RK.device_minor] = .number(RegoNumber(int: Int64(device_minor)))
        }
        return .object(obj)
    }
}

extension EventNormalizer.NormalizedSSH: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = Dictionary(minimumCapacity: 14)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.non_normalizable] = non_normalizable.toRegoValue()
        obj[RK.start_time] = .number(RegoNumber(decimal: Decimal(start_time)))
        obj[RK.src_addr] = .string(src_addr)
        obj[RK.username] = .string(username)
        obj[RK.success] = .boolean(success)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.tty] = .string(tty)
        obj[RK.session_id] = .string(session_id)
        obj[RK.action] = .string(action)
        obj[RK.session_duration] = .number(RegoNumber(decimal: Decimal(session_duration)))
        return .object(obj)
    }
}

extension EventNormalizer.NormalizedFile: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = Dictionary(minimumCapacity: 12)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.non_normalizable] = non_normalizable.toRegoValue()
        obj[RK.action] = .string(action)
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.path] = .string(path)
        obj[RK.size] = .number(RegoNumber(int: size))
        obj[RK.flags] = .number(RegoNumber(int: Int64(flags)))
        obj[RK.exe] = .string(exe)
        obj[RK.exe_basename] = .string(exeBasename(exe))
        obj[RK.pid] = .number(RegoNumber(int: pid))
        obj[RK.ppid] = .number(RegoNumber(int: ppid))
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        return .object(obj)
    }
}
