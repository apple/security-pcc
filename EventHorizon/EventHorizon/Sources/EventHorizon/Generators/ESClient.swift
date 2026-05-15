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


#if canImport(EndpointSecurity)
import EndpointSecurity
#if os(macOS)
import Darwin.bsm.libbsm
#else
import DarwinPrivate.bsm.libbsm
#endif
#endif
import Foundation
#if canImport(os)
import os
#endif

public class ESClient: EHGenerator, AllEventsIterable {
    private let log = EHLog.withCategory(ESClient.self)

    public static let allEvents: [any EHUEFEvent.Type] = [
        ESClientProcExecEvent.self,
        ESClientProcExitEvent.self,
        ESClientIOKitOpenEvent.self,
        ESClientSSHLoginEvent.self,
        ESClientSSHLogoutEvent.self,
        ESClientFileOpenEvent.self
    ]


    public struct ESClientProcExecEvent: EHUEFEvent {
        public var tags = Set<String>()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "proc_exec"

        public var fields: [String: EHValueType] = [:]

        public init() {}

        public init(
            tags: Set<String> = [],
            startTime: Double = 0,
            cwd: String = "",
            args: [String] = [],
            executable: String = "",
            signingID: String = "",
            platformBinary: Bool = false,
            tty: String = "",
            script: String = "",
            pid: UInt32 = 0,
            euid: UInt32 = 0,
            egid: UInt32 = 0,
            codesigningFlags: UInt32 = 0,
            ppid: Int32 = 0,
            parentExecutable: String = "",
            parentSigningID: String = "",
            parentPlatformBinary: Bool = false,
            fdCount: UInt32 = 0,
            pipeIds: [UInt64] = [],
        ) {
            self.tags = tags
            self.startTime = startTime
            self.cwd = cwd
            self.args = args
            self.executable = executable
            self.signingID = signingID
            self.platformBinary = platformBinary
            self.tty = tty
            self.script = script
            self.pid = pid
            self.euid = euid
            self.egid = egid
            self.codesigningFlags = codesigningFlags
            self.ppid = ppid
            self.parentExecutable = parentExecutable
            self.parentSigningID = parentSigningID
            self.parentPlatformBinary = parentPlatformBinary
            self.fdCount = fdCount
            self.pipeIds = pipeIds
        }

        public var startTime: Double = 0

        public var cwd: String = ""

        public var args: [String] = []

        public var executable: String = ""

        public var signingID: String = ""

        public var platformBinary: Bool = false

        public var tty: String = ""

        public var script: String = ""

        public var pid: UInt32 = 0

        public var euid: UInt32 = 0

        public var egid: UInt32 = 0

        public var codesigningFlags: UInt32 = 0

        public var ppid: Int32 = 0

        public var parentExecutable: String = ""

        public var parentSigningID: String = ""

        public var parentPlatformBinary: Bool = false

        public var fdCount: UInt32 = 0

        public var pipeIds: [UInt64] = []
    }

    public struct ESClientProcExitEvent: EHUEFEvent {
        public var tags = Set<String>()

        public var fields: [String: EHValueType] = [:]
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "proc_exit"

        public init() {}

        public init(
            tags: Set<String> = [],
            timestamp: TimeInterval = 0,
            pid: UInt32 = 0,
            executable: String = "",
            exitStatus: Int32 = 0
        ) {
            self.tags = tags
            self.timestamp = timestamp
            self.pid = pid
            self.executable = executable
            self.exitStatus = exitStatus
        }

        public var timestamp: TimeInterval = 0

        public var pid: UInt32 = 0

        public var executable: String = ""

        public var exitStatus: Int32 = 0
    }

    public struct ESClientIOKitOpenEvent: EHUEFEvent {
        internal init(tags: Set<String> = Set<String>(), fields: [String: EHValueType] = [:], event_category: EHUEFCategory = .resource, event_type: String = "iokit_open", timestamp: TimeInterval = 0, pid: UInt32 = 0, executable: String = "", userClientClass: String = "", userClientType: UInt32 = 0, binName: String = "") {
            self.tags = tags
            self.fields = fields
            self.event_category = event_category
            self.event_type = event_type
            self.timestamp = timestamp
            self.pid = pid
            self.executable = executable
            self.userClientClass = userClientClass
            self.userClientType = userClientType
            self.binName = binName
        }

        public var tags = Set<String>()
        public init() {}

        public var fields: [String: EHValueType] = [:]
        public var event_category: EHUEFCategory = .resource
        public var event_type: String = "iokit_open"

        public var timestamp: TimeInterval = 0

        public var pid: UInt32 = 0

        public var executable: String = ""

        public var userClientClass: String = ""

        public var userClientType: UInt32 = 0

        public var binName: String = ""
    }

    struct ESClientSSHLoginEvent: EHUEFEvent {
        var tags = Set<String>()

        var fields: [String: EHValueType] = [:]
        var event_category: EHUEFCategory = .system
        var event_type: String = "ssh_login"

        var timestamp: TimeInterval = 0

        var srcAddr: String = ""

        var username: String = ""

        var success: String = ""

        var uid: String = ""
    }

    struct ESClientSSHLogoutEvent: EHUEFEvent {
        var tags = Set<String>()

        var fields: [String: EHValueType] = [:]
        var event_category: EHUEFCategory = .system
        var event_type: String = "ssh_logout"

        var timestamp: TimeInterval = 0

        var srcAddr: String = ""

        var username: String = ""

        var uid: UInt32 = 0
    }

    public struct ESClientFileOpenEvent: EHUEFEvent {
        public init(tags: Set<String> = Set<String>(), fields: [String: EHValueType] = [:], event_category: EHUEFCategory = .file, event_type: String = "file_open", timestamp: TimeInterval = 0, path: String = "", size: Int64 = 0, fflag: Int32 = 0, exe: String = "", pid: UInt32 = 0, ppid: Int32 = 0, signing_id: String = "", uid: UInt32 = 0) {
            self.tags = tags
            self.fields = fields
            self.event_category = event_category
            self.event_type = event_type
            self.timestamp = timestamp
            self.path = path
            self.size = size
            self.fflag = fflag
            self.exe = exe
            self.pid = pid
            self.ppid = ppid
            self.signing_id = signing_id
            self.uid = uid
        }

        public var tags = Set<String>()
        public init() {}

        public var fields: [String: EHValueType] = [:]
        public var event_category: EHUEFCategory = .file
        public var event_type: String = "file_open"

        public var timestamp: TimeInterval = 0

        public var path: String = ""

        public var size: Int64 = 0

        public var fflag: Int32 = 0

        public var exe: String = ""

        public var pid: UInt32 = 0

        public var ppid: Int32 = 0

        public var signing_id: String = ""

        public var uid: UInt32 = 0

    }


    internal var pipeline: EHPipeline?
    public func configure(_ pipeline: EHPipeline) throws {
        #if !canImport(EndpointSecurity)
        throw ESClientError.platformUnsupported
        #else
        let result = es_new_client(&self.client, esEventHandler)
        guard result == ES_NEW_CLIENT_RESULT_SUCCESS, self.client != nil else {
            os_log(.info, log: log, "Error creating es_client: \(result.rawValue)")
            throw ESClientError.unableToSubsribe(code: Int(result.rawValue))
        }
        let result_file = es_new_client(&self.client_file, esEventHandler)
        guard result_file == ES_NEW_CLIENT_RESULT_SUCCESS, let cf = self.client_file else {
            os_log(.info, log: log, "Error creating es_client_file: \(result_file.rawValue)")
            throw ESClientError.unableToSubsribe(code: Int(result_file.rawValue))
        }

        let muteCode = es_unmute_all_target_paths(cf)
        guard muteCode == ES_RETURN_SUCCESS else {
            os_log(.error, log: log, "Unable to unmute all target paths: \(muteCode.rawValue)")
            throw ESClientError.unableToSubsribe(code: Int(muteCode.rawValue))
        }

        let muteInvertCode = es_invert_muting(cf, ES_MUTE_INVERSION_TYPE_TARGET_PATH)
        guard muteInvertCode == ES_RETURN_SUCCESS else {
            os_log(.error, log: log, "Unable to invert muting target paths: \(muteInvertCode.rawValue)")
            throw ESClientError.unableToSubsribe(code: Int(muteInvertCode.rawValue))
        }

        var pathLiterals: [String] = []
        var pathPrefixes: [String] = []
        for transform in pipeline.transforms {
            os_log(.debug, log: log, "Checking transform \(transform.name) for file subscriptions")
            if let fileSubscriber = transform as? EHFileSubscriber, let filePaths = fileSubscriber.filePaths {
                os_log(.debug, log: log, "Transform \(transform.name) has paths \(filePaths)")
                for path in filePaths {
                    if path.hasSuffix("*") {
                        pathPrefixes.append(String(path.dropLast()))
                    } else {
                        pathLiterals.append(path)
                    }
                }
            }
        }

        try Set(pathLiterals).forEach { try self.subscribeToTargetPath(path: $0, kind: .literal) }
        try Set(pathPrefixes).forEach { try self.subscribeToTargetPath(path: $0, kind: .prefix) }

        os_log(.info, log: log, "Successfully configured ESClient")

        #endif
    }

    public enum FileSubscriptionType {
        case literal
        case prefix
    }

    public func subscribeToTargetPath(path: String, kind: FileSubscriptionType) throws {
        #if !canImport(EndpointSecurity)
        throw ESClientError.platformUnsupported
        #else
        guard let client = self.client_file else {
            throw ESClientError.notSubscribed
        }
        let ret = es_mute_path(client, path, kind == .literal ? ES_MUTE_PATH_TYPE_TARGET_LITERAL : ES_MUTE_PATH_TYPE_TARGET_PREFIX)
        guard ret == ES_RETURN_SUCCESS else {
            os_log(.error, log: log, "Unable to subscribe to file path target \(kind == .literal ? "literal" : "prefix"): \(path)")
            throw ESClientError.unableToSubsribe(code: Int(ret.rawValue))
        }
        os_log(.debug, log: log, "Subscribed to file path target \(kind == .literal ? "literal" : "prefix"): \(path)")
        #endif
    }

    public enum ESClientError: Error {
        case unableToSubsribe(code: Int)
        case platformUnsupported
        case notSubscribed
    }

    var client: OpaquePointer?
    var client_file: OpaquePointer?

    #if canImport(EndpointSecurity)
    let eventTypes = [
        ES_EVENT_TYPE_NOTIFY_EXEC,
        ES_EVENT_TYPE_NOTIFY_EXIT,
        ES_EVENT_TYPE_NOTIFY_IOKIT_OPEN,
        ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGIN,
        ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGOUT
    ]
    let eventTypes_file = [
        ES_EVENT_TYPE_NOTIFY_OPEN
    ]
    #endif
    public func stop() throws {
        #if canImport(EndpointSecurity)
        if self.client != nil {
            es_delete_client(self.client)
        }
        if self.client_file != nil {
            es_delete_client(self.client_file)
        }
        #endif
    }

    public init() {}
    deinit {
        try? self.stop()
    }

    public func start(_ pipeline: EHPipeline) throws {
        #if !canImport(EndpointSecurity)
        throw ESClientError.platformUnsupported
        #else
        self.pipeline = pipeline
        let subResult = self.subscribeToEvents()
        guard subResult == ES_RETURN_SUCCESS else {
            os_log(.info, log: log, "Error subscribing to events: \(String(describing: subResult))")
            throw ESClientError.unableToSubsribe(code: Int(subResult.rawValue))
        }
        #endif
    }
#if canImport(EndpointSecurity)
    func subscribeToEvents() -> es_return_t {
        let c = es_subscribe(self.client!, self.eventTypes, UInt32(self.eventTypes.count))
        guard c == ES_RETURN_SUCCESS else {
            return c
        }
        return es_subscribe(self.client_file!, self.eventTypes_file, UInt32(self.eventTypes_file.count))
    }

    func esEventHandler(client: OpaquePointer, message: UnsafePointer<es_message_t>) {
        let esMessage = message.pointee
        guard let pipeline = self.pipeline else {
            return
        }
        if let event: any EHUEFEvent = esMessageToEHUEFEvent(esMessage) {
            Task {
                await pipeline.process(event)
            }
        }
    }

    func esMessageToEHUEFEvent(_ esMessage: es_message_t) -> EHUEFEvent? {
        switch esMessage.event_type {
        case ES_EVENT_TYPE_NOTIFY_EXEC:
            return handleExecEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_EXIT:
            return handleExitEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_IOKIT_OPEN:
            return handleIOKitEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGIN:
            return handleSSHLoginEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGOUT:
            return handleSSHLogoutEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_OPEN:
            return handleOpenEvent(esMessage: esMessage)
        default:
            os_log(.error, log: log, "Warning: Unexpected event type: \(esMessage.event_type.rawValue)")
            return nil
        }
    }

    func handleExecEvent(esMessage: es_message_t) -> EHUEFEvent? {
        var argArr: [String] = []
        var fdCount: UInt32 = 0
        var pipeIds: [UInt64] = []
        var tags: Set<String> = Set()
        withUnsafePointer(to: esMessage.event.exec) {
            $0.withMemoryRebound(to: es_event_exec_t.self, capacity: 1) {
                let argCount = es_exec_arg_count($0)
                for i in 0 ..< argCount {
                    let arg = es_exec_arg($0, i)
                    argArr.append(String(cString: arg.data))
                }
                fdCount = es_exec_fd_count($0)
                if fdCount > 0 {
                    for i in 0 ..< fdCount {
                        let fdinfo = es_exec_fd($0, i)
                        if fdinfo.pointee.fdtype == PROX_FDTYPE_PIPE {
                            pipeIds.append(fdinfo.pointee.pipe.pipe_id)
                            switch fdinfo.pointee.fd {
                            case 0:
                                tags.insert(EventNormalizer.Tags.stdin_redirected_to_pipe.rawValue)
                            case 1:
                                tags.insert(EventNormalizer.Tags.stdout_redirected_to_pipe.rawValue)
                            case 2:
                                tags.insert(EventNormalizer.Tags.stderr_redirected_to_pipe.rawValue)
                            default:
                                break
                            }
                        }
                    }
                }
            }
        }

        let execProcess = esMessage.event.exec.target.pointee
        var tty = EventHorizonKit.eventInfoNone
        if execProcess.tty != nil {
            tty = String(cString: (execProcess.tty!.pointee.path.data))
        }
        var script = EventHorizonKit.eventInfoNone
        if esMessage.event.exec.script != nil {
            script = String(cString: esMessage.event.exec.script!.pointee.path.data)
        }
        let parentProcess = esMessage.process.pointee

        return ESClientProcExecEvent(
            tags: tags,
            startTime: Double(execProcess.start_time.tv_sec) + (Double(execProcess.start_time.tv_usec) / Double(USEC_PER_SEC)),
            cwd: String(cString: esMessage.event.exec.cwd.pointee.path.data),
            args: argArr,
            executable: String(cString: execProcess.executable.pointee.path.data),
            signingID: String(cString: execProcess.signing_id.data),
            platformBinary: execProcess.is_platform_binary,
            tty: tty,
            script: script,
            pid: UInt32(audit_token_to_pid(execProcess.audit_token)),
            euid: audit_token_to_euid(execProcess.audit_token),
            egid: audit_token_to_egid(execProcess.audit_token),
            codesigningFlags: execProcess.codesigning_flags,
            ppid: execProcess.ppid,
            parentExecutable: String(cString: parentProcess.executable.pointee.path.data),
            parentSigningID: String(cString: parentProcess.signing_id.data),
            parentPlatformBinary: parentProcess.is_platform_binary,
            fdCount: fdCount,
            pipeIds: pipeIds
        )
    }

    func handleExitEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let stat = esMessage.event.exit.stat

        let exitCode = (stat >> 8) & 0xFF

        return ESClientProcExitEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            pid: UInt32(audit_token_to_pid(esMessage.process.pointee.audit_token)),
            executable: String(cString: esMessage.process.pointee.executable.pointee.path.data),
            exitStatus: exitCode)
    }

    func handleIOKitEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let iokitEvent = esMessage.event.iokit_open
        let userClientClass = String(cString: iokitEvent.user_client_class.data)
        let executablePath = String(cString: esMessage.process.pointee.executable.pointee.path.data)
        let binName = (executablePath as NSString).lastPathComponent

        return ESClientIOKitOpenEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            pid: UInt32(audit_token_to_pid(esMessage.process.pointee.audit_token)),
            executable: executablePath,
            userClientClass: userClientClass,
            userClientType: iokitEvent.user_client_type,
            binName: binName)
    }

    func handleSSHLoginEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let sshEvent = esMessage.event.openssh_login.pointee

        return ESClientSSHLoginEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            srcAddr: String(cString: sshEvent.source_address.data),
            username: String(cString: sshEvent.username.data),
            success: String(describing: sshEvent.success),
            uid: sshEvent.has_uid == true ? "\(sshEvent.uid.uid)" : EventHorizonKit.eventInfoNone)
    }

    func handleSSHLogoutEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let sshEvent = esMessage.event.openssh_logout.pointee

        return ESClientSSHLogoutEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            srcAddr: String(cString: sshEvent.source_address.data),
            username: String(cString: sshEvent.username.data),
            uid: sshEvent.uid
            )
    }

    func handleOpenEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let openEvent = esMessage.event.open
        let process = esMessage.process.pointee

        return ESClientFileOpenEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            path: String(cString: openEvent.file.pointee.path.data),
            size: openEvent.file.pointee.stat.st_size,
            fflag: openEvent.fflag,
            exe: String(cString: process.executable.pointee.path.data),
            pid: UInt32(audit_token_to_pid(esMessage.process.pointee.audit_token)),
            ppid: process.ppid,
            signing_id: String(cString: process.signing_id.data),
            uid: UInt32(audit_token_to_euid(esMessage.process.pointee.audit_token))
        )
    }

    private func esMessageTimeToDouble(esMessage: es_message_t) -> Double {
        return Double(esMessage.time.tv_sec) + (Double(esMessage.time.tv_nsec) / Double(NSEC_PER_SEC))
    }
    #endif

}

extension ESClient.ESClientProcExecEvent: EventNormalizer.ProcessNormalizable {
    public var n_fd_count: UInt32 {
        self.fdCount
    }

    public var n_fd_pipe_ids: [UInt64] {
        self.pipeIds
    }

    public var n_start_time: Double {
        self.startTime
    }

    public var n_cwd: String {
        self.cwd
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "signingID": .string(self.signingID),
            "platformBinary": .boolean(self.platformBinary),
            "script": .string(self.script),
            "codesigningFlags": .int(Int(self.codesigningFlags)),
            "parentSigningID": .string(self.parentSigningID),
            "parentPlatformBinary": .boolean(self.parentPlatformBinary)
        ]
    }

    public var n_tty: String {
        self.tty
    }

    public var n_uid: UInt32 {
        self.euid
    }

    public var n_gid: UInt32 {
        self.egid
    }

    public var n_p_exe: String {
        self.parentExecutable
    }

    public var n_pid: Int64 {
        Int64(self.pid)
    }

    public var n_ppid: Int64 {
        Int64(self.ppid)
    }

    public var n_exe: String {
        self.executable
    }

    public var n_args: [String] {
        self.args
    }
}


extension ESClient.ESClientIOKitOpenEvent: EventNormalizer.DeviceOpenNormalizable {
    public var n_timestamp: Double {
        self.timestamp
    }

    public var n_pid: Int64 {
        Int64(self.pid)
    }

    public var n_executable: String {
        self.executable
    }

    public var n_device_identifier: String {
        self.userClientClass
    }

    public var n_device_path: String {
        self.binName.isEmpty ? "" : "/IOKit/\(self.binName)"
    }

    public var n_device_major: UInt32? {
        nil
    }

    public var n_device_minor: UInt32? {
        nil
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "userClientType": .int(Int(self.userClientType)),
            "binName": .string(self.binName)
        ]
    }
}
