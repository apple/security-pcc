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
        ESClientProcForkEvent.self,
        ESClientIOKitOpenEvent.self,
        ESClientSSHLoginEvent.self,
        ESClientSSHLogoutEvent.self,
        ESClientFileOpenEvent.self,
        ESClientFileWriteEvent.self,
        ESClientFileCreateEvent.self,
        ESClientFileUnlinkEvent.self
    ]


    public struct ESClientProcExecEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "proc_exec"

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
            pipeIds: [UInt64] = []
        ) {
            self.metadata = EHEventMetadata(tags: tags)
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
        public var metadata = EHEventMetadata()

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
            self.metadata = EHEventMetadata(tags: tags)
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

    public struct ESClientProcForkEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "proc_fork"

        public init() {}

        public init(
            startTime: Double = 0,
            pid: UInt32 = 0,
            ppid: Int32 = 0,
            comm: String = "",
            parentExecutable: String = ""
        ) {
            self.startTime = startTime
            self.pid = pid
            self.ppid = ppid
            self.comm = comm
            self.parentExecutable = parentExecutable
            self.tags.insert(EventNormalizer.NormalizedProcess.Tags.fork_only.rawValue)
        }

        public var startTime: Double = 0

        public var pid: UInt32 = 0

        public var ppid: Int32 = 0

        public var comm: String = ""

        public var parentExecutable: String = ""
    }

    public struct ESClientIOKitOpenEvent: EHUEFEvent {
        internal init(tags: Set<String> = Set<String>(), fields: [String: EHValueType] = [:], event_category: EHUEFCategory = .resource, event_type: String = "iokit_open", timestamp: TimeInterval = 0, pid: UInt32 = 0, executable: String = "", userClientClass: String = "", userClientType: UInt32 = 0, binName: String = "") {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.timestamp = timestamp
            self.pid = pid
            self.executable = executable
            self.userClientClass = userClientClass
            self.userClientType = userClientType
            self.binName = binName
        }

        public var metadata = EHEventMetadata()
        public init() {}

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
        var metadata = EHEventMetadata()

        var event_category: EHUEFCategory = .system
        var event_type: String = "ssh_login"

        var timestamp: TimeInterval = 0

        var srcAddr: String = ""

        var username: String = ""

        var success: String = ""

        var uid: String = ""
    }

    struct ESClientSSHLogoutEvent: EHUEFEvent {
        var metadata = EHEventMetadata()

        var event_category: EHUEFCategory = .system
        var event_type: String = "ssh_logout"

        var timestamp: TimeInterval = 0

        var srcAddr: String = ""

        var username: String = ""

        var uid: UInt32 = 0
    }

    public struct ESClientFileOpenEvent: EHUEFEvent {
        public init(tags: Set<String> = Set<String>(), fields: [String: EHValueType] = [:], event_category: EHUEFCategory = .file, event_type: String = "file_open", timestamp: TimeInterval = 0, path: String = "", size: Int64 = 0, fflag: Int32 = 0, exe: String = "", pid: UInt32 = 0, ppid: Int32 = 0, signing_id: String = "", uid: UInt32 = 0) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
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

        public var metadata = EHEventMetadata()
        public init() {}

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

    public struct ESClientFileWriteEvent: EHUEFEvent {
        public init(
            tags: Set<String> = Set<String>(),
            fields: [String: EHValueType] = [:],
            event_category: EHUEFCategory = .file,
            event_type: String = "file_write",
            timestamp: TimeInterval = 0,
            path: String = "",
            exe: String = "",
            pid: UInt32 = 0,
            ppid: Int32 = 0,
            signing_id: String = "",
            uid: UInt32 = 0
        ) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.timestamp = timestamp
            self.path = path
            self.exe = exe
            self.pid = pid
            self.ppid = ppid
            self.signing_id = signing_id
            self.uid = uid
        }

        public var metadata = EHEventMetadata()
        public init() {}

        public var event_category: EHUEFCategory = .file
        public var event_type: String = "file_write"

        public var timestamp: TimeInterval = 0

        public var path: String = ""

        public var exe: String = ""

        public var pid: UInt32 = 0

        public var ppid: Int32 = 0

        public var signing_id: String = ""

        public var uid: UInt32 = 0
    }

    public struct ESClientFileCreateEvent: EHUEFEvent {
        public init(
            tags: Set<String> = Set<String>(),
            fields: [String: EHValueType] = [:],
            event_category: EHUEFCategory = .file,
            event_type: String = "file_create",
            timestamp: TimeInterval = 0,
            path: String = "",
            exe: String = "",
            pid: UInt32 = 0,
            ppid: Int32 = 0,
            signing_id: String = "",
            uid: UInt32 = 0,
            destination_type: String = ""
        ) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.timestamp = timestamp
            self.path = path
            self.exe = exe
            self.pid = pid
            self.ppid = ppid
            self.signing_id = signing_id
            self.uid = uid
            self.destination_type = destination_type
        }

        public var metadata = EHEventMetadata()
        public init() {}

        public var event_category: EHUEFCategory = .file
        public var event_type: String = "file_create"

        public var timestamp: TimeInterval = 0

        public var path: String = ""

        public var exe: String = ""

        public var pid: UInt32 = 0

        public var ppid: Int32 = 0

        public var signing_id: String = ""

        public var uid: UInt32 = 0

        public var destination_type: String = ""
    }

    public struct ESClientFileUnlinkEvent: EHUEFEvent {
        public init(
            tags: Set<String> = Set<String>(),
            fields: [String: EHValueType] = [:],
            event_category: EHUEFCategory = .file,
            event_type: String = "file_unlink",
            timestamp: TimeInterval = 0,
            path: String = "",
            exe: String = "",
            pid: UInt32 = 0,
            ppid: Int32 = 0,
            signing_id: String = "",
            uid: UInt32 = 0,
            parent_dir: String = ""
        ) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.event_category = event_category
            self.event_type = event_type
            self.timestamp = timestamp
            self.path = path
            self.exe = exe
            self.pid = pid
            self.ppid = ppid
            self.signing_id = signing_id
            self.uid = uid
            self.parent_dir = parent_dir
        }

        public var metadata = EHEventMetadata()
        public init() {}

        public var event_category: EHUEFCategory = .file
        public var event_type: String = "file_unlink"

        public var timestamp: TimeInterval = 0

        public var path: String = ""

        public var exe: String = ""

        public var pid: UInt32 = 0

        public var ppid: Int32 = 0

        public var signing_id: String = ""

        public var uid: UInt32 = 0

        public var parent_dir: String = ""
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
        ES_EVENT_TYPE_NOTIFY_FORK,
        ES_EVENT_TYPE_NOTIFY_IOKIT_OPEN,
        ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGIN,
        ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGOUT
    ]
    let eventTypes_file = [
        ES_EVENT_TYPE_NOTIFY_OPEN,
        ES_EVENT_TYPE_NOTIFY_WRITE,
        ES_EVENT_TYPE_NOTIFY_CREATE,
        ES_EVENT_TYPE_NOTIFY_UNLINK
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
        case ES_EVENT_TYPE_NOTIFY_FORK:
            return handleForkEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_IOKIT_OPEN:
            return handleIOKitEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGIN:
            return handleSSHLoginEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_OPENSSH_LOGOUT:
            return handleSSHLogoutEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_OPEN:
            return handleOpenEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_WRITE:
            return handleWriteEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_CREATE:
            return handleCreateEvent(esMessage: esMessage)
        case ES_EVENT_TYPE_NOTIFY_UNLINK:
            return handleUnlinkEvent(esMessage: esMessage)
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
                    argArr.append(Self.safeString(arg.data))
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
            tty = Self.safeString(execProcess.tty!.pointee.path.data)
        }
        var script = EventHorizonKit.eventInfoNone
        if esMessage.event.exec.script != nil {
            script = Self.safeString(esMessage.event.exec.script!.pointee.path.data)
        }
        let parentProcess = esMessage.process.pointee

        return ESClientProcExecEvent(
            tags: tags,
            startTime: Double(execProcess.start_time.tv_sec) + (Double(execProcess.start_time.tv_usec) / Double(USEC_PER_SEC)),
            cwd: Self.safeString(esMessage.event.exec.cwd.pointee.path.data),
            args: argArr,
            executable: Self.safeString(execProcess.executable.pointee.path.data),
            signingID: Self.safeString(execProcess.signing_id.data),
            platformBinary: execProcess.is_platform_binary,
            tty: tty,
            script: script,
            pid: UInt32(audit_token_to_pid(execProcess.audit_token)),
            euid: audit_token_to_euid(execProcess.audit_token),
            egid: audit_token_to_egid(execProcess.audit_token),
            codesigningFlags: execProcess.codesigning_flags,
            ppid: execProcess.ppid,
            parentExecutable: Self.safeString(parentProcess.executable.pointee.path.data),
            parentSigningID: Self.safeString(parentProcess.signing_id.data),
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
            executable: Self.safeString(esMessage.process.pointee.executable.pointee.path.data),
            exitStatus: exitCode)
    }

    func handleForkEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let childProcess = esMessage.event.fork.child.pointee
        let parentProcess = esMessage.process.pointee

        let executablePath = Self.safeString(childProcess.executable.pointee.path.data)
        let comm = (executablePath as NSString).lastPathComponent

        return ESClientProcForkEvent(
            startTime: Double(childProcess.start_time.tv_sec) + (Double(childProcess.start_time.tv_usec) / Double(USEC_PER_SEC)),
            pid: UInt32(audit_token_to_pid(childProcess.audit_token)),
            ppid: childProcess.ppid,
            comm: comm,
            parentExecutable: Self.safeString(parentProcess.executable.pointee.path.data)
        )
    }

    func handleIOKitEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let iokitEvent = esMessage.event.iokit_open
        let userClientClass = Self.safeString(iokitEvent.user_client_class.data)
        let executablePath = Self.safeString(esMessage.process.pointee.executable.pointee.path.data)
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
            srcAddr: Self.safeString(sshEvent.source_address.data),
            username: Self.safeString(sshEvent.username.data),
            success: String(describing: sshEvent.success),
            uid: sshEvent.has_uid == true ? "\(sshEvent.uid.uid)" : EventHorizonKit.eventInfoNone)
    }

    func handleSSHLogoutEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let sshEvent = esMessage.event.openssh_logout.pointee

        return ESClientSSHLogoutEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            srcAddr: Self.safeString(sshEvent.source_address.data),
            username: Self.safeString(sshEvent.username.data),
            uid: sshEvent.uid
            )
    }

    func handleOpenEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let openEvent = esMessage.event.open
        let process = esMessage.process.pointee

        return ESClientFileOpenEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            path: Self.safeString(openEvent.file.pointee.path.data),
            size: openEvent.file.pointee.stat.st_size,
            fflag: openEvent.fflag,
            exe: Self.safeString(process.executable.pointee.path.data),
            pid: UInt32(audit_token_to_pid(esMessage.process.pointee.audit_token)),
            ppid: process.ppid,
            signing_id: Self.safeString(process.signing_id.data),
            uid: UInt32(audit_token_to_euid(esMessage.process.pointee.audit_token))
        )
    }

    func handleWriteEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let writeEvent = esMessage.event.write
        let process = esMessage.process.pointee

        return ESClientFileWriteEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            path: Self.safeString(writeEvent.target.pointee.path.data),
            exe: Self.safeString(process.executable.pointee.path.data),
            pid: UInt32(audit_token_to_pid(esMessage.process.pointee.audit_token)),
            ppid: process.ppid,
            signing_id: Self.safeString(process.signing_id.data),
            uid: UInt32(audit_token_to_euid(esMessage.process.pointee.audit_token))
        )
    }

    func handleCreateEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let createEvent = esMessage.event.create
        let process = esMessage.process.pointee

        let path: String
        let destinationType: String

        if createEvent.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE {
            path = Self.safeString(createEvent.destination.existing_file.pointee.path.data)
            destinationType = "file"
        } else if createEvent.destination_type == ES_DESTINATION_TYPE_NEW_PATH {
            path = Self.safeString(createEvent.destination.new_path.dir.pointee.path.data) + "/" +
                   Self.safeString(createEvent.destination.new_path.filename.data)
            destinationType = (createEvent.destination.new_path.mode & UInt16(S_IFDIR)) != 0 ? "dir" : "file"
        } else {
            os_log(
                .error,
                log: log,
                "ESClient: Unknown create event destination_type: %{public}d",
                createEvent.destination_type.rawValue
            )
            return nil
        }

        return ESClientFileCreateEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            path: path,
            exe: Self.safeString(process.executable.pointee.path.data),
            pid: UInt32(audit_token_to_pid(esMessage.process.pointee.audit_token)),
            ppid: process.ppid,
            signing_id: Self.safeString(process.signing_id.data),
            uid: UInt32(audit_token_to_euid(esMessage.process.pointee.audit_token)),
            destination_type: destinationType
        )
    }

    func handleUnlinkEvent(esMessage: es_message_t) -> EHUEFEvent? {
        let unlinkEvent = esMessage.event.unlink
        let process = esMessage.process.pointee

        return ESClientFileUnlinkEvent(
            timestamp: self.esMessageTimeToDouble(esMessage: esMessage),
            path: Self.safeString(unlinkEvent.target.pointee.path.data),
            exe: Self.safeString(process.executable.pointee.path.data),
            pid: UInt32(audit_token_to_pid(esMessage.process.pointee.audit_token)),
            ppid: process.ppid,
            signing_id: Self.safeString(process.signing_id.data),
            uid: UInt32(audit_token_to_euid(esMessage.process.pointee.audit_token)),
            parent_dir: Self.safeString(unlinkEvent.parent_dir.pointee.path.data)
        )
    }

    private static func safeString(_ ptr: UnsafePointer<CChar>?) -> String {
        guard let ptr = ptr else {
            return ""
        }
        return String(cString: ptr)
    }

    private static func safeString(_ ptr: UnsafePointer<UInt8>?) -> String {
        guard let ptr = ptr else {
            return ""
        }
        return String(cString: ptr)
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

    public var n_euid: UInt32 {
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


extension ESClient.ESClientProcForkEvent: EventNormalizer.ProcessNormalizable {
    public var n_args: [String] {
        []
    }

    public var n_pid: Int64 {
        Int64(self.pid)
    }

    public var n_ppid: Int64 {
        Int64(self.ppid)
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
        [:]
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
        self.parentExecutable
    }

    public var n_fd_count: UInt32 {
        0
    }

    public var n_fd_pipe_ids: [UInt64] {
        []
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

extension ESClient.ESClientSSHLoginEvent: EventNormalizer.SSHNormalizable {
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
        (self.success as NSString).boolValue
    }

    public var n_uid: UInt32 {
        UInt32(self.uid) ?? 0
    }

    public var n_pid: Int64 {
        0
    }

    public var n_tty: String {
        ""
    }

    public var n_session_id: String {
        ""
    }

    public var n_action: String {
        "login"
    }

    public var n_session_duration: Double {
        0
    }

    public var n_non_normalizable: [String: EHValueType] {
        [:]
    }
}

extension ESClient.ESClientSSHLogoutEvent: EventNormalizer.SSHNormalizable {
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
        0
    }

    public var n_tty: String {
        ""
    }

    public var n_session_id: String {
        ""
    }

    public var n_action: String {
        "logout"
    }

    public var n_session_duration: Double {
        0
    }

    public var n_non_normalizable: [String: EHValueType] {
        [:]
    }
}


extension ESClient.ESClientFileOpenEvent: EventNormalizer.FileNormalizable {
    public var n_action: String {
        EventNormalizer.NormalizedFile.Action.open.rawValue
    }

    public var n_timestamp: Double {
        self.timestamp
    }

    public var n_path: String {
        self.path
    }

    public var n_size: Int64 {
        self.size
    }

    public var n_flags: Int32 {
        self.fflag
    }

    public var n_exe: String {
        self.exe
    }

    public var n_pid: Int64 {
        Int64(self.pid)
    }

    public var n_ppid: Int64 {
        Int64(self.ppid)
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "signing_id": .string(self.signing_id)
        ]
    }
}

extension ESClient.ESClientFileWriteEvent: EventNormalizer.FileNormalizable {
    public var n_action: String {
        EventNormalizer.NormalizedFile.Action.write.rawValue
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
        self.exe
    }

    public var n_pid: Int64 {
        Int64(self.pid)
    }

    public var n_ppid: Int64 {
        Int64(self.ppid)
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "signing_id": .string(self.signing_id)
        ]
    }
}

extension ESClient.ESClientFileCreateEvent: EventNormalizer.FileNormalizable {
    public var n_action: String {
        EventNormalizer.NormalizedFile.Action.create.rawValue
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
        self.exe
    }

    public var n_pid: Int64 {
        Int64(self.pid)
    }

    public var n_ppid: Int64 {
        Int64(self.ppid)
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "signing_id": .string(self.signing_id),
            "destination_type": .string(self.destination_type)
        ]
    }
}

extension ESClient.ESClientFileUnlinkEvent: EventNormalizer.FileNormalizable {
    public var n_action: String {
        EventNormalizer.NormalizedFile.Action.unlink.rawValue
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
        self.exe
    }

    public var n_pid: Int64 {
        Int64(self.pid)
    }

    public var n_ppid: Int64 {
        Int64(self.ppid)
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_non_normalizable: [String: EHValueType] {
        [
            "signing_id": .string(self.signing_id),
            "parent_dir": .string(self.parent_dir)
        ]
    }
}


extension ESClient.ESClientProcExecEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "startTime": return startTime
        case "cwd": return cwd
        case "args": return args
        case "executable": return executable
        case "signingID": return signingID
        case "platformBinary": return platformBinary
        case "tty": return tty
        case "script": return script
        case "pid": return pid
        case "euid": return euid
        case "egid": return egid
        case "codesigningFlags": return codesigningFlags
        case "ppid": return ppid
        case "parentExecutable": return parentExecutable
        case "parentSigningID": return parentSigningID
        case "parentPlatformBinary": return parentPlatformBinary
        case "fdCount": return fdCount
        case "pipeIds": return pipeIds
        default: return nil
        }
    }
}

extension ESClient.ESClientProcExitEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "pid": return pid
        case "executable": return executable
        case "exitStatus": return exitStatus
        default: return nil
        }
    }
}

extension ESClient.ESClientProcForkEvent: EHFieldExtractable {
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
        case "parentExecutable": return parentExecutable
        default: return nil
        }
    }
}

extension ESClient.ESClientIOKitOpenEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "pid": return pid
        case "executable": return executable
        case "userClientClass": return userClientClass
        case "userClientType": return userClientType
        case "binName": return binName
        default: return nil
        }
    }
}

extension ESClient.ESClientSSHLoginEvent: EHFieldExtractable {
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
        default: return nil
        }
    }
}

extension ESClient.ESClientSSHLogoutEvent: EHFieldExtractable {
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
        default: return nil
        }
    }
}

extension ESClient.ESClientFileOpenEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "path": return path
        case "size": return size
        case "fflag": return fflag
        case "exe": return exe
        case "pid": return pid
        case "ppid": return ppid
        case "signing_id": return signing_id
        case "uid": return uid
        default: return nil
        }
    }
}

extension ESClient.ESClientFileWriteEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "path": return path
        case "exe": return exe
        case "pid": return pid
        case "ppid": return ppid
        case "signing_id": return signing_id
        case "uid": return uid
        default: return nil
        }
    }
}

extension ESClient.ESClientFileCreateEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "path": return path
        case "exe": return exe
        case "pid": return pid
        case "ppid": return ppid
        case "signing_id": return signing_id
        case "uid": return uid
        case "destination_type": return destination_type
        default: return nil
        }
    }
}

extension ESClient.ESClientFileUnlinkEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "path": return path
        case "exe": return exe
        case "pid": return pid
        case "ppid": return ppid
        case "signing_id": return signing_id
        case "uid": return uid
        case "parent_dir": return parent_dir
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
    static let cwd: AST.RegoValue = .string("cwd")
    static let args: AST.RegoValue = .string("args")
    static let executable: AST.RegoValue = .string("executable")
    static let signingID: AST.RegoValue = .string("signingID")
    static let platformBinary: AST.RegoValue = .string("platformBinary")
    static let tty: AST.RegoValue = .string("tty")
    static let script: AST.RegoValue = .string("script")
    static let pid: AST.RegoValue = .string("pid")
    static let euid: AST.RegoValue = .string("euid")
    static let egid: AST.RegoValue = .string("egid")
    static let codesigningFlags: AST.RegoValue = .string("codesigningFlags")
    static let ppid: AST.RegoValue = .string("ppid")
    static let parentExecutable: AST.RegoValue = .string("parentExecutable")
    static let parentSigningID: AST.RegoValue = .string("parentSigningID")
    static let parentPlatformBinary: AST.RegoValue = .string("parentPlatformBinary")
    static let fdCount: AST.RegoValue = .string("fdCount")
    static let pipeIds: AST.RegoValue = .string("pipeIds")
    static let exitStatus: AST.RegoValue = .string("exitStatus")
    static let comm: AST.RegoValue = .string("comm")
    static let userClientClass: AST.RegoValue = .string("userClientClass")
    static let userClientType: AST.RegoValue = .string("userClientType")
    static let binName: AST.RegoValue = .string("binName")
    static let srcAddr: AST.RegoValue = .string("srcAddr")
    static let username: AST.RegoValue = .string("username")
    static let success: AST.RegoValue = .string("success")
    static let uid: AST.RegoValue = .string("uid")
    static let path: AST.RegoValue = .string("path")
    static let size: AST.RegoValue = .string("size")
    static let fflag: AST.RegoValue = .string("fflag")
    static let exe: AST.RegoValue = .string("exe")
    static let signing_id: AST.RegoValue = .string("signing_id")
    static let destination_type: AST.RegoValue = .string("destination_type")
    static let parent_dir: AST.RegoValue = .string("parent_dir")
}

extension ESClient.ESClientProcExecEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 21)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.startTime] = .number(RegoNumber(decimal: Decimal(startTime)))
        obj[RK.cwd] = .string(cwd)
        obj[RK.args] = .array(args.map { .string($0) })
        obj[RK.executable] = .string(executable)
        obj[RK.signingID] = .string(signingID)
        obj[RK.platformBinary] = .boolean(platformBinary)
        obj[RK.tty] = .string(tty)
        obj[RK.script] = .string(script)
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.euid] = .number(RegoNumber(int: Int64(euid)))
        obj[RK.egid] = .number(RegoNumber(int: Int64(egid)))
        obj[RK.codesigningFlags] = .number(RegoNumber(int: Int64(codesigningFlags)))
        obj[RK.ppid] = .number(RegoNumber(int: Int64(ppid)))
        obj[RK.parentExecutable] = .string(parentExecutable)
        obj[RK.parentSigningID] = .string(parentSigningID)
        obj[RK.parentPlatformBinary] = .boolean(parentPlatformBinary)
        obj[RK.fdCount] = .number(RegoNumber(int: Int64(fdCount)))
        obj[RK.pipeIds] = .array(pipeIds.map { .number(RegoNumber(value: $0)) })
        return .object(obj)
    }
}

extension ESClient.ESClientProcExitEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 8)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.executable] = .string(executable)
        obj[RK.exitStatus] = .number(RegoNumber(int: Int64(exitStatus)))
        return .object(obj)
    }
}

extension ESClient.ESClientProcForkEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 9)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.startTime] = .number(RegoNumber(decimal: Decimal(startTime)))
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.ppid] = .number(RegoNumber(int: Int64(ppid)))
        obj[RK.comm] = .string(comm)
        obj[RK.parentExecutable] = .string(parentExecutable)
        return .object(obj)
    }
}

extension ESClient.ESClientIOKitOpenEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 10)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.executable] = .string(executable)
        obj[RK.userClientClass] = .string(userClientClass)
        obj[RK.userClientType] = .number(RegoNumber(int: Int64(userClientType)))
        obj[RK.binName] = .string(binName)
        return .object(obj)
    }
}

extension ESClient.ESClientSSHLoginEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 9)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.srcAddr] = .string(srcAddr)
        obj[RK.username] = .string(username)
        obj[RK.success] = .string(success)
        obj[RK.uid] = .string(uid)
        return .object(obj)
    }
}

extension ESClient.ESClientSSHLogoutEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 8)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.srcAddr] = .string(srcAddr)
        obj[RK.username] = .string(username)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        return .object(obj)
    }
}

extension ESClient.ESClientFileOpenEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 13)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.path] = .string(path)
        obj[RK.size] = .number(RegoNumber(int: size))
        obj[RK.fflag] = .number(RegoNumber(int: Int64(fflag)))
        obj[RK.exe] = .string(exe)
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.ppid] = .number(RegoNumber(int: Int64(ppid)))
        obj[RK.signing_id] = .string(signing_id)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        return .object(obj)
    }
}

extension ESClient.ESClientFileWriteEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 11)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.path] = .string(path)
        obj[RK.exe] = .string(exe)
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.ppid] = .number(RegoNumber(int: Int64(ppid)))
        obj[RK.signing_id] = .string(signing_id)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        return .object(obj)
    }
}

extension ESClient.ESClientFileCreateEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 12)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.path] = .string(path)
        obj[RK.exe] = .string(exe)
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.ppid] = .number(RegoNumber(int: Int64(ppid)))
        obj[RK.signing_id] = .string(signing_id)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.destination_type] = .string(destination_type)
        return .object(obj)
    }
}

extension ESClient.ESClientFileUnlinkEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = .init(minimumCapacity: 12)
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.path] = .string(path)
        obj[RK.exe] = .string(exe)
        obj[RK.pid] = .number(RegoNumber(int: Int64(pid)))
        obj[RK.ppid] = .number(RegoNumber(int: Int64(ppid)))
        obj[RK.signing_id] = .string(signing_id)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.parent_dir] = .string(parent_dir)
        return .object(obj)
    }
}
