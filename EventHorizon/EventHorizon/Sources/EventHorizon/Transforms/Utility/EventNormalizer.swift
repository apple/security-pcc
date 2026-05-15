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


public final class EventNormalizer: EHTransform, AllEventsIterable {
    public static let allEvents: [any EHUEFEvent.Type] = [
        NormalizedProcess.self,
        NormalizedNetwork.self,
        NormalizedDns.self,
        NormalizedDevice.self
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

    protocol NormalizableEvent: EHUEFEvent, RuleTagger.CustomFieldMatcher {
        var non_normalizable: [String: EHValueType] { get }
    }


    public struct NormalizedProcess: NormalizableEvent, UsernameEnricher.UsernameEnrichable, GroupnameEnricher.GroupnameEnrichable {
        public func gid_properties() -> ([String]?, [String]?) {
            return (nil, ["gid", "p_gid"])
        }

        public func uid_properties() -> ([String]?, [String]?) {
            return (nil, ["uid"])
        }

        public init(tags: Set<String> = Set<String>(), event_category: EHUEFCategory = .process, event_type: String = "normalized_process", fields: [String: EHValueType] = [:], non_normalizable: [String: EHValueType] = [:], start_time: Double = 0, cwd: String = "", args: [String] = [], exe: String = "", tty: String = "", pid: Int64 = 0, uid: UInt32 = 0, gid: UInt32 = 0, ppid: Int64 = 0, p_exe: String = "", fd_count: UInt32 = 0, fd_pipe_ids: [UInt64] = [], p_start_time: Double = 0, p_gid: UInt32 = 0) {
            self.tags = tags
            self.event_category = event_category
            self.event_type = event_type
            self.fields = fields
            self.non_normalizable = non_normalizable
            self.start_time = start_time
            self.cwd = cwd
            self.args = args
            self.exe = exe
            self.tty = tty
            self.pid = pid
            self.uid = uid
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
            self.tags = from.tags
            self.fields = from.fields
            self.start_time = from.n_start_time
            self.cwd = from.n_cwd
            self.args = from.n_args
            self.exe = from.n_exe
            self.tty = from.n_tty
            self.pid = from.n_pid
            self.uid = from.n_uid
            self.gid = from.n_gid
            self.ppid = from.n_ppid
            self.p_exe = from.n_p_exe
            self.non_normalizable = from.n_non_normalizable
            self.fd_count = from.n_fd_count
            self.fd_pipe_ids = from.n_fd_pipe_ids
        }
        public var tags = Set<String>()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "normalized_process"

        public var fields: [String: EHValueType] = [:]
        public var non_normalizable: [String: EHValueType] = [:]

        public var start_time: Double = 0

        public var cwd: String = ""

        public var args: [String] = []

        public var exe: String = ""

        public var tty: String = ""

        public var pid: Int64 = 0

        public var uid: UInt32 = 0

        public var gid: UInt32 = 0

        public var ppid: Int64 = 0

        public var p_exe: String = ""

        public var fd_count: UInt32 = 0

        public var fd_pipe_ids: [UInt64] = []

        public var p_start_time: Double = 0

        public var p_gid: UInt32 = 0


        public var cmdline: String {
            self.args.joined(separator: " ")
        }
    }


    public struct NormalizedNetwork: NormalizableEvent, UsernameEnricher.UsernameEnrichable {
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
            p_exe: String = ""
        ) {
            self.tags = tags
            self.event_category = event_category
            self.event_type = event_type
            self.fields = fields
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
        }

        public init(_ from: any NetworkNormalizable) {
            self.tags = from.tags
            self.fields = from.fields
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

        public var tags = Set<String>()
        public var event_category: EHUEFCategory = .network
        public var event_type: String = "normalized_network"

        public var fields: [String: EHValueType] = [:]
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
            self.tags = tags
            self.event_category = event_category
            self.event_type = event_type
            self.fields = fields
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
            self.tags = from.tags
            self.fields = from.fields
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

        public var tags = Set<String>()
        public var event_category: EHUEFCategory = .network
        public var event_type: String = "normalized_dns"

        public var fields: [String: EHValueType] = [:]
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
            self.tags = tags
            self.event_category = event_category
            self.event_type = event_type
            self.fields = fields
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
            self.tags = from.tags
            self.fields = from.fields
            self.non_normalizable = from.n_non_normalizable
            self.timestamp = from.n_timestamp
            self.pid = from.n_pid
            self.executable = from.n_executable
            self.device_identifier = from.n_device_identifier
            self.device_path = from.n_device_path
            self.device_major = from.n_device_major
            self.device_minor = from.n_device_minor
        }

        public var tags = Set<String>()
        public var event_category: EHUEFCategory = .resource
        public var event_type: String = "normalized_device"

        public var fields: [String: EHValueType] = [:]
        public var non_normalizable: [String: EHValueType] = [:]

        public var timestamp: Double = 0

        public var pid: Int64 = 0

        public var executable: String = ""

        public var device_identifier: String = ""

        public var device_path: String = ""

        public var device_major: UInt32?

        public var device_minor: UInt32?
    }


    public enum Normalizations: CaseIterable, Sendable {
        case process
        case network
        case dns
        case device
    }

    let normalizations: Set<Normalizations>
    public init(_ normalizations: Set<Normalizations> = Set(Normalizations.allCases)) {
        self.normalizations = normalizations
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
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
            }
        }
        return (.proceed, nil, nil, nil)
    }

    public func configure() throws {
    }
}


extension EventNormalizer.NormalizedProcess: EHEventSimilarityValue {
    public var similarityHash: String {
        return "\(self.exe)_\(self.cwd)_\(self.uid)_\(self.args)"
    }
}

extension EventNormalizer.NormalizedNetwork: EHEventSimilarityValue {
    public var similarityHash: String {
        return "\(self.pid)_\(self.proc_name)_\(self.remote_addr)_\(self.remote_port)_\(self.protocol)"
    }
}

extension EventNormalizer.NormalizedDns: EHEventSimilarityValue {
    public var similarityHash: String {
        return "\(self.pid)_\(self.proc_name)_\(self.qname)_\(self.qtype)_\(self.rowtype)"
    }
}

extension EventNormalizer.NormalizedDevice: EHEventSimilarityValue {
    public var similarityHash: String {
        return "\(self.pid)_\(self.executable)_\(self.device_identifier)_\(self.device_path)"
    }
}

extension EventNormalizer.NormalizableEvent {
    func getValueFromField(field: String) -> Any? {
        if let e = self as? EventNormalizer.NormalizedProcess, field == "cmdline" {
            return e.cmdline
        }

        if let val = self.non_normalizable[field] {
            if let sval = val.stringValue {
                return sval
            } else if let ival = val.intValue {
                return ival
            } else if let ival = val.doubleValue {
                return ival
            } else if let bval = val.boolValue {
                return bval
            }
        }

        return nil
    }
}
