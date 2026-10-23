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
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import Synchronization

import Cehprobe

public struct EhprobeOperations: ExecAllowlistOperations {
    public func addFileToExecAllowlist(containerId: UInt64, inode: UInt64, device: UInt32, binaryHash: [UInt8]) -> Int32 {
        return ehprobe_add_file_to_exec_allowlist(containerId, inode, device, binaryHash)
    }

    public func addFileToScriptAllowlist(containerId: UInt64, inode: UInt64, device: UInt32, scriptHash: [UInt8]) -> Int32 {
        return ehprobe_add_file_to_script_allowlist(containerId, inode, device, scriptHash)
    }

    public func removeContainerFromExecAllowlist(containerId: UInt64) {
        ehprobe_remove_container_from_exec_allowlist(containerId)
    }

    public func removeContainerFromScriptAllowlist(containerId: UInt64) {
        ehprobe_remove_container_from_script_allowlist(containerId)
    }

    public func unshareWrapper(flags: Int32) -> Int32 {
        return ehprobe_unshare_wrapper(flags)
    }

    public func setnsWrapper(fd: Int32, nstype: Int32) -> Int32 {
        return ehprobe_setns_wrapper(fd, nstype)
    }
}

private final class EhprobeContext {
    let pipeline: EHPipeline

    init(pipeline: EHPipeline) {
        self.pipeline = pipeline
    }
}
#endif

public class EhprobeGenerator: EHGenerator {
    public enum EhprobeGeneratorError: Error {
        case platformUnsupported
    }

    public enum ExecBlockingMode: String, Sendable {
        case off
        case audit
        case enforce
    }

    #if os(Linux)
    static let log = EHLog.withCategory(EhprobeGenerator.self)

    private static let systemBootTime: Double = {
        guard let statContent = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else {
            return 0.0
        }

        for line in statContent.components(separatedBy: .newlines) where line.hasPrefix("btime ") {
            let components = line.components(separatedBy: " ")
            if components.count >= 2, let bootTime = Double(components[1]) {
                return bootTime
            }
        }

        return 0.0
    }()

    public struct EHProbeConfig {
        public var blockingMode: ExecBlockingMode
        public var hostProcPath: String?
        public var includeDPI: Bool
        public var scriptBlockingMode: ExecBlockingMode
        public var includeExec: Bool
        public var includeFS: Bool
        public var includeNetwork: Bool
        public var includeBlockKill: Bool
        public var includeAfAlg: Bool
        public var afAlgBlock: Bool

        public var includeModuleLoad: Bool
        public var moduleLoadBlock: Bool

        public var includeXfrmSaNew: Bool
        public var xfrmSaNewBlock: Bool

        public init(
            blockingMode: ExecBlockingMode = .off,
            hostProcPath: String? = nil,
            includeDPI: Bool = false,
            scriptBlockingMode: ExecBlockingMode = .off,
            includeExec: Bool = true,
            includeFS: Bool = true,
            includeNetwork: Bool = true,
            includeBlockKill: Bool = true,
            includeAfAlg: Bool = true,
            afAlgBlock: Bool = true,
            includeModuleLoad: Bool = true,
            moduleLoadBlock: Bool = true,
            includeXfrmSaNew: Bool = true,
            xfrmSaNewBlock: Bool = true
        ) {
            self.blockingMode = blockingMode
            self.hostProcPath = hostProcPath
            self.includeDPI = includeDPI
            self.scriptBlockingMode = scriptBlockingMode
            self.includeExec = includeExec
            self.includeFS = includeFS
            self.includeNetwork = includeNetwork
            self.includeBlockKill = includeBlockKill
            self.includeAfAlg = includeAfAlg
            self.afAlgBlock = afAlgBlock
            self.includeModuleLoad = includeModuleLoad
            self.moduleLoadBlock = moduleLoadBlock
            self.includeXfrmSaNew = includeXfrmSaNew
            self.xfrmSaNewBlock = xfrmSaNewBlock
        }
    }

    public var config: EHProbeConfig

    private var hostNamespaceAccess: ExecAllowlistController.HostNamespaceAccess = .native

    private static let procBasePath = Mutex<String>("/proc")

    var requestedEhprobeFeatures: UInt32 = 0

    private var ehprobeContext: EhprobeContext?

    private var pollingTask: Task<Void, Never>?

    private let setFeaturesMutex = Mutex<Void>(())

    private var configuredPathLiterals: Set<String> = []
    private var configuredPathPrefixes: Set<String> = []

    static let allowlistFolders = [
        "/bin",
        "/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/libexec",
        "/usr/lib/systemd"
    ]

    static let scriptAllowlistFolders: [String] = {
        let pythonPrefixes = [
            ("/usr/lib", "python3"),
            ("/usr/lib64", "python3"),
            ("/usr/local/lib", "python3")
        ]
        let fm = FileManager.default
        var folders: [String] = []
        for (parent, prefix) in pythonPrefixes {
            guard let entries = try? fm.contentsOfDirectory(atPath: parent) else {
                continue
            }
            for entry in entries where entry.hasPrefix(prefix) {
                folders.append("\(parent)/\(entry)")
            }
        }
        folders.append("/usr/local/bin")
        return folders
    }()

    static let interpreterNames: [String] = {
        var names: Set<String> = ["python", "python3"]
        let fm = FileManager.default
        for dir in allowlistFolders {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for entry in entries {
                guard entry.hasPrefix("python") else {
                    continue
                }
                guard !entry.contains("-") else {
                    continue
                }
                names.insert(entry)
            }
        }
        return Array(names).sorted()
    }()

    public static let execAllowlistController = ExecAllowlistController(operations: EhprobeOperations())

    static func resolveInterpreterPath(_ rawPath: String, pid: Int64) -> String {
        if rawPath.isEmpty {
            return ""
        }

        if rawPath.hasPrefix("/") {
            return rawPath
        }

        let basePath = procBasePath.withLock { $0 }
        let cwdLink = "\(basePath)/\(pid)/cwd"
        guard let cwd = try? FileManager.default.destinationOfSymbolicLink(atPath: cwdLink) else {
            return ""
        }

        let fullPath: String
        if rawPath.hasPrefix("./") {
            fullPath = cwd + "/" + String(rawPath.dropFirst(2))
        } else {
            fullPath = cwd + "/" + rawPath
        }

        let url = URL(fileURLWithPath: fullPath).standardized
        return url.path
    }

    static func readEnvVar(_ name: String, pid: Int64) -> String {
        let basePath = procBasePath.withLock { $0 }
        let environPath = "\(basePath)/\(pid)/environ"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: environPath)) else {
            return ""
        }

        let prefix = "\(name)="
        let entries = data.split(separator: 0)
        for entry in entries {
            if let str = String(data: Data(entry), encoding: .utf8),
               str.hasPrefix(prefix) {
                return String(str.dropFirst(prefix.count))
            }
        }
        return ""
    }

    public func stop() throws {
        pollingTask?.cancel()
        pollingTask = nil
        closeEhprobe()
        ehprobeContext = nil
    }

    public func configure(_ pipeline: EHPipeline) throws {
        self.requestedEhprobeFeatures = 0
        if self.config.includeExec {
            self.requestedEhprobeFeatures |= UInt32(EHPROBE_FEATURE_EXEC.rawValue)
        }
        if self.config.includeFS {
            self.requestedEhprobeFeatures |= UInt32(EHPROBE_FEATURE_FS.rawValue)
        }
        if self.config.includeNetwork {
            self.requestedEhprobeFeatures |= UInt32(EHPROBE_FEATURE_NETWORK.rawValue)
        }
        if self.config.includeAfAlg || self.config.afAlgBlock {
            self.requestedEhprobeFeatures |= UInt32(EHPROBE_FEATURE_AF_ALG.rawValue)
        }

        if self.config.includeModuleLoad || self.config.moduleLoadBlock {
            self.requestedEhprobeFeatures |= UInt32(EHPROBE_FEATURE_MODULE_LOAD.rawValue)
        }

        if self.config.includeXfrmSaNew || self.config.xfrmSaNewBlock {
            self.requestedEhprobeFeatures |= UInt32(EHPROBE_FEATURE_XFRM_SA_NEW.rawValue)
        }

        if self.config.blockingMode != .off {
            self.requestedEhprobeFeatures |=
                UInt32(EHPROBE_FEATURE_BLOCK_KILL.rawValue) |
                UInt32(EHPROBE_FEATURE_BLOCK_EXEC.rawValue)
        } else if self.config.includeBlockKill {
            self.requestedEhprobeFeatures |= UInt32(EHPROBE_FEATURE_BLOCK_KILL.rawValue)
        }

        if self.config.includeDPI {
            self.requestedEhprobeFeatures |= UInt32(EHPROBE_FEATURE_DPI.rawValue)
        }

        if self.config.scriptBlockingMode != .off {
            self.requestedEhprobeFeatures |= UInt32(EHPROBE_FEATURE_BLOCK_SCRIPT.rawValue)
        }

        configuredPathLiterals.removeAll()
        configuredPathPrefixes.removeAll()

        for transform in pipeline.transforms {
            if let fileSubscriber = transform as? EHFileSubscriber,
               let filePaths = fileSubscriber.filePaths {
                for path in filePaths {
                    if path.hasSuffix("*") {
                        let prefix = String(path.dropLast())
                        configuredPathPrefixes.insert(prefix)
                        Self.log.log(.debug, "Collected file path prefix: \(prefix)")
                    } else {
                        configuredPathLiterals.insert(path)
                        Self.log.log(.debug, "Collected file path literal: \(path)")
                    }
                }
            }
        }

        let totalPaths = configuredPathLiterals.count + configuredPathPrefixes.count
        Self.log.log(.info, "Collected \(totalPaths) file paths for filtering (\(configuredPathLiterals.count) literal, \(configuredPathPrefixes.count) prefix)")
    }

    @discardableResult
    public func addFilePathFilter(_ path: String) -> Bool {
        guard !path.isEmpty else {
            Self.log.log(.error, "Cannot add empty path filter")
            return false
        }
        if path == "*" {
            Self.log.log(.error, "Cannot add wildcard-only path filter")
            return false
        }

        if path.hasSuffix("*") {
            let prefix = String(path.dropLast())

            if ehprobe_is_running() {
                let result = ehprobe_file_path_add_prefix(prefix)
                if result != 0 {
                    Self.log.log(.error, "Failed to add prefix path filter '\(prefix)': \(result)")
                    return false
                }
            }

            configuredPathPrefixes.insert(prefix)
            Self.log.log(.debug, "Added file path prefix filter: \(prefix)")
        } else {
            if ehprobe_is_running() {
                let result = ehprobe_file_path_add_literal(path)
                if result != 0 {
                    Self.log.log(.error, "Failed to add literal path filter '\(path)': \(result)")
                    return false
                }
            }

            configuredPathLiterals.insert(path)
            Self.log.log(.debug, "Added file path literal filter: \(path)")
        }
        return true
    }

    public func clearFilePathFilters() {
        configuredPathLiterals.removeAll()
        configuredPathPrefixes.removeAll()

        if ehprobe_is_running() {
            let result = ehprobe_file_path_clear_all()
            if result != 0 {
                Self.log.log(.error, "Failed to clear file path filters: \(result)")
            }
        }
        Self.log.log(.debug, "Cleared all file path filters")
    }

    public init(config: EHProbeConfig) {
        Self.log.log(.debug, "Initializing EhprobeGenerator")
        self.config = config
    }

    public func startEhprobe(pipeline: EHPipeline? = nil) -> Bool {
        let featuresString = String(format: "0x%02X", self.requestedEhprobeFeatures)
        Self.log.log(.info, "Initializing ehprobe, features: \(featuresString)")

        self.hostNamespaceAccess = ExecAllowlistController.detectHostNamespaceAccess(
            hostProcPath: config.hostProcPath
        )
        Self.log.log(.info, "Host namespace access mode: \(self.hostNamespaceAccess)")

        switch self.hostNamespaceAccess {
        case .mountedProc(let path):
            Self.procBasePath.withLock { $0 = path }
        default:
            Self.procBasePath.withLock { $0 = "/proc" }
        }

        guard initEhprobe(pipeline: pipeline) else {
            Self.log.log(.error, "Unable to initialize ehprobe")
            return false
        }

        guard ehprobe_start() == 0 else {
            Self.log.log(.error, "Failed to start ehprobe monitoring")
            return false
        }

        guard configCapture() else {
            Self.log.log(.error, "Unable to config capture parameters")
            return false
        }

        Self.log.log(.info, "ehprobe initialized")
        return true
    }

    public func setEhprobeFeatures(requestedFeatures: UInt32) -> Bool {
        return setFeaturesMutex.withLock { _ in
            guard ehprobe_set_features(requestedFeatures) == 0 else {
                Self.log.log(.error, "Unable to set ehprobe features")
                return false
            }

            self.requestedEhprobeFeatures = requestedFeatures

            guard configCapture() else {
                Self.log.log(.error, "Unable to config capture parameters")
                return false
            }

            let featuresString = String(format: "0x%02X", self.requestedEhprobeFeatures)
            Self.log.log(.info, "ehprobe features set to: \(featuresString)")
            return true
        }
    }

    private func initEhprobe(pipeline: EHPipeline?) -> Bool {
        var initialized = false
        defer {
            if !initialized {
                ehprobe_destroy()
                ehprobeContext = nil
            }
        }

        if pipeline != nil {
            ehprobeContext = EhprobeContext(pipeline: pipeline!)
        }

        guard ehprobeContext != nil else {
            Self.log.log(.error, "pipeline not defined")
            return false
        }

        var config = ehprobe_config_t()
        config.features = requestedEhprobeFeatures
        config.ring_buffer_size_kb = 256
        config.poll_timeout_ms = 100
        config.enable_debug_output = false

        config.user_context = Unmanaged.passUnretained(ehprobeContext!).toOpaque()

        config.event_handler = { eventPtr, userContext in
            guard let event = eventPtr,
                let context = userContext else {
                return 0
            }

            let ehprobeContext = Unmanaged<EhprobeContext>.fromOpaque(context).takeUnretainedValue()

            guard let swiftEvent = EHProbeEvent(from: event.pointee) else {
                return 0
            }

            let pipeline = ehprobeContext.pipeline

            Task {
                await EhprobeGenerator.processEhprobeEvent(
                    pipeline: pipeline,
                    event: swiftEvent
                )
            }

            return 0
        }

        config.log_handler = { level, message in
            guard let msgCStr = message else {
                return
            }
            let msgStr = String(cString: msgCStr)

            struct Static {
                static let llog = EHLog.withCategory(Static.self)
            }

            switch level {
            case EHPROBE_LOG_ERROR:
                os_log(.error, log: Static.llog, "ehprobe: %@", msgStr)
            case EHPROBE_LOG_WARNING:
                os_log(.info, log: Static.llog, "ehprobe: %@", msgStr)
            case EHPROBE_LOG_INFO:
                os_log(.info, log: Static.llog, "ehprobe: %@", msgStr)
            case EHPROBE_LOG_DEBUG:
                os_log(.debug, log: Static.llog, "ehprobe: %@", msgStr)
            default:
                os_log(.debug, log: Static.llog, "ehprobe: %@", msgStr)
            }
        }

        guard ehprobe_init(&config) == 0 else {
            Self.log.log(.error, "ehprobe_init() error")
            return false
        }

        initialized = true
        return true
    }

    public func closeEhprobe() {
        ehprobe_stop()
        ehprobe_destroy()
    }

    private func configCapture() -> Bool {
        configureFilePathFilter()

        if (requestedEhprobeFeatures & UInt32(EHPROBE_FEATURE_BLOCK_EXEC.rawValue)) != 0 {
            if Self.execAllowlistController.populateAllowlist(
                containerId: 0,
                containerPid: 0,
                allowlistFolders: Self.allowlistFolders,
                hostAccess: self.hostNamespaceAccess) {

                scanPreExistingContainers()

                let mode: UInt64 = switch self.config.blockingMode {
                case .off: UInt64(EHPROBE_BLOCKING_MODE_OFF)
                case .audit: UInt64(EHPROBE_BLOCKING_MODE_AUDIT)
                case .enforce: UInt64(EHPROBE_BLOCKING_MODE_ENFORCE)
                }
                let ret = ehprobe_set_blocking_mode(mode)
                if ret != 0 {
                    Self.log.log(.error, "Failed to set blocking mode to \(self.config.blockingMode.rawValue): \(ret)")
                } else {
                    Self.log.log(.debug, "Exec blocking mode set to: \(self.config.blockingMode.rawValue)")
                }
            } else {
                Self.log.log(.error, "Failed to populate allowlist, setting blocking mode to off")
                ehprobe_set_blocking_mode(UInt64(EHPROBE_BLOCKING_MODE_OFF))
            }
        } else {
            ehprobe_set_blocking_mode(UInt64(EHPROBE_BLOCKING_MODE_OFF))
            Self.log.log(.debug, "Exec blocking mode set to: off")
        }

        if (requestedEhprobeFeatures & UInt32(EHPROBE_FEATURE_BLOCK_SCRIPT.rawValue)) != 0 {
            for name in Self.interpreterNames {
                let ret = ehprobe_add_interpreter_binary(name)
                if ret != 0 {
                    Self.log.log(.error, "Failed to add interpreter binary '\(name)': \(ret)")
                } else {
                    Self.log.log(.debug, "Added interpreter binary: \(name)")
                }
            }

            let allowlistResult = Self.execAllowlistController.populateScriptAllowlist(
                containerId: 0,
                containerPid: 0,
                scriptFolders: Self.scriptAllowlistFolders,
                hostAccess: self.hostNamespaceAccess)
            if !allowlistResult {
                Self.log.log(.info, "Script allowlist empty or no script folders found — all scripts will require allowlisting")
            }

            let mode: UInt64 = switch self.config.scriptBlockingMode {
            case .off: UInt64(EHPROBE_BLOCKING_MODE_OFF)
            case .audit: UInt64(EHPROBE_BLOCKING_MODE_AUDIT)
            case .enforce: UInt64(EHPROBE_BLOCKING_MODE_ENFORCE)
            }
            let ret = ehprobe_set_script_blocking_mode(mode)
            if ret != 0 {
                Self.log.log(.error, "Failed to set script blocking mode to \(self.config.scriptBlockingMode.rawValue): \(ret)")
            } else {
                Self.log.log(.debug, "Script blocking mode set to: \(self.config.scriptBlockingMode.rawValue)")
            }

        } else {
            ehprobe_set_script_blocking_mode(UInt64(EHPROBE_BLOCKING_MODE_OFF))
        }

        if (requestedEhprobeFeatures & UInt32(EHPROBE_FEATURE_AF_ALG.rawValue)) != 0 {
            let mode: UInt64 = self.config.afAlgBlock
                ? UInt64(EHPROBE_BLOCKING_MODE_ENFORCE)
                : UInt64(EHPROBE_BLOCKING_MODE_OFF)
            let ret = ehprobe_set_af_alg_block_mode(mode)
            if ret != 0 {
                Self.log.log(.error, "Failed to set AF_ALG block mode to \(self.config.afAlgBlock): \(ret)")
            } else {
                Self.log.log(.debug, "AF_ALG block mode set to: \(self.config.afAlgBlock ? "enforce" : "off")")
            }
        } else if self.config.afAlgBlock {
            Self.log.log(.info, "AF_ALG block requested but AF_ALG feature is disabled — forcing off")
            ehprobe_set_af_alg_block_mode(UInt64(EHPROBE_BLOCKING_MODE_OFF))
        }

        if (requestedEhprobeFeatures & UInt32(EHPROBE_FEATURE_MODULE_LOAD.rawValue)) != 0 {
            let mode: UInt64 = self.config.moduleLoadBlock
                ? UInt64(EHPROBE_BLOCKING_MODE_ENFORCE)
                : UInt64(EHPROBE_BLOCKING_MODE_OFF)
            let ret = ehprobe_set_module_load_block_mode(mode)
            if ret != 0 {
                Self.log.log(.error, "Failed to set module-load block mode to \(self.config.moduleLoadBlock): \(ret)")
            } else {
                Self.log.log(.debug, "Module-load block mode set to: \(self.config.moduleLoadBlock ? "enforce" : "off")")
            }
        } else if self.config.moduleLoadBlock {
            Self.log.log(.info, "Module-load block requested but MODULE_LOAD feature is disabled — forcing off")
            let ret = ehprobe_set_module_load_block_mode(UInt64(EHPROBE_BLOCKING_MODE_OFF))
            if ret != 0 {
                Self.log.log(.error, "Failed to force module-load block mode off: \(ret)")
            }
        }

        if (requestedEhprobeFeatures & UInt32(EHPROBE_FEATURE_XFRM_SA_NEW.rawValue)) != 0 {
            let mode: UInt64 = self.config.xfrmSaNewBlock
                ? UInt64(EHPROBE_BLOCKING_MODE_ENFORCE)
                : UInt64(EHPROBE_BLOCKING_MODE_OFF)
            let ret = ehprobe_set_xfrm_sa_new_block_mode(mode)
            if ret != 0 {
                Self.log.log(.error, "Failed to set XFRM SA block mode to \(self.config.xfrmSaNewBlock): \(ret)")
            } else {
                Self.log.log(.debug, "XFRM SA block mode set to: \(self.config.xfrmSaNewBlock ? "enforce" : "off")")
            }
        } else if self.config.xfrmSaNewBlock {
            Self.log.log(.info, "XFRM SA block requested but XFRM_SA_NEW feature is disabled — forcing off")
            let ret = ehprobe_set_xfrm_sa_new_block_mode(UInt64(EHPROBE_BLOCKING_MODE_OFF))
            if ret != 0 {
                Self.log.log(.error, "Failed to force XFRM SA block mode off: \(ret)")
            }
        }

        Self.log.log(.info, "ehprobe configured")
        return true
    }

    static func minimizePrefixes(_ prefixes: Set<String>) -> Set<String> {
        let stripped = prefixes.map { p -> (stripped: String, hadWildcard: Bool) in
            if p.hasSuffix("/*") {
                return (String(p.dropLast(2)), true)
            }
            return (p, false)
        }

        let sorted = stripped.sorted { $0.stripped.count < $1.stripped.count }

        var kept: [(stripped: String, hadWildcard: Bool)] = []
        for candidate in sorted {
            let subsumed = kept.contains { shorter in
                candidate.stripped == shorter.stripped ||
                candidate.stripped.hasPrefix(shorter.stripped + "/")
            }
            if !subsumed {
                kept.append(candidate)
            }
        }

        return Set(kept.map { entry in
            entry.hadWildcard ? entry.stripped + "/*" : entry.stripped
        })
    }

    private func configureFilePathFilter() {
        let minimizedPrefixes = EhprobeGenerator.minimizePrefixes(configuredPathPrefixes)
        let dropped = configuredPathPrefixes.count - minimizedPrefixes.count
        if dropped > 0 {
            Self.log.log(.info, "Prefix subsumption removed \(dropped) redundant prefix(es)")
        }

        let totalPaths = configuredPathLiterals.count + minimizedPrefixes.count
        Self.log.log(.info, "Configuring file path filter with \(configuredPathLiterals.count) literals and \(minimizedPrefixes.count) prefixes")

        let clearResult = ehprobe_file_path_clear_all()
        if clearResult != 0 {
            Self.log.log(.error, "Failed to clear file path filters: \(clearResult)")
        }

        for path in configuredPathLiterals {
            let result = ehprobe_file_path_add_literal(path)
            if result != 0 {
                Self.log.log(.error, "Failed to add literal path filter '\(path)': \(result)")
            }
        }

        for prefix in minimizedPrefixes {
            let barePrefix = prefix.hasSuffix("/*") ? String(prefix.dropLast(2)) : prefix
            let result = ehprobe_file_path_add_prefix(barePrefix)
            if result != 0 {
                if result == -28 {
                    Self.log.log(.error, "LPM trie full: could not add prefix '\(barePrefix)'")
                } else {
                    Self.log.log(.error, "Failed to add prefix path filter '\(barePrefix)': \(result)")
                }
            }
        }

        let enableResult = ehprobe_file_path_filter_enable(true)
        if enableResult != 0 {
            Self.log.log(.error, "Failed to enable file path filtering: \(enableResult)")
        } else {
            if totalPaths > 0 {
                Self.log.log(.info, "File path filtering enabled with \(totalPaths) path(s)")
            } else {
                Self.log.log(.info, "File path filtering enabled (no paths configured - all file events will be filtered)")
            }
        }
    }

    private func scanPreExistingContainers() {
        guard (requestedEhprobeFeatures & UInt32(EHPROBE_FEATURE_BLOCK_EXEC.rawValue)) != 0 else {
            Self.log.log(.debug, "Exec blocking not enabled, skipping pre-existing container scan")
            return
        }

        var containerIds = [UInt64](repeating: 0, count: 256)
        var count: Int32 = 0

        let result = ehprobe_container_get_all_ids(&containerIds, 256, &count)
        guard result == 0 else {
            Self.log.log(.error, "Failed to get container IDs: \(result)")
            return
        }

        guard count > 0 else {
            Self.log.log(.debug, "No pre-existing containers found")
            return
        }

        Self.log.log(.info, "Scanning \(count) pre-existing container(s) for allowlist population")

        for i in 0..<Int(count) {
            let containerId = containerIds[i]

            var container = ehprobe_container()
            let queryResult = ehprobe_container_query(containerId, &container)
            guard queryResult == 0 else {
                Self.log.log(.error, "Failed to query container \(containerId): \(queryResult)")
                continue
            }

            guard container.start_time_ns == 0 else {
                Self.log.log(.debug, "Container \(containerId) is not pre-existing, skipping")
                continue
            }

            let containerPid = Int64(container.pid)

            Self.log.log(.info, "Populating allowlist for pre-existing container: id=\(containerId), pid=\(containerPid)")

            if Self.execAllowlistController.populateAllowlist(
                containerId: containerId,
                containerPid: containerPid,
                allowlistFolders: Self.allowlistFolders) {

                let mode: UInt64 = switch self.config.blockingMode {
                case .off: UInt64(EHPROBE_BLOCKING_MODE_OFF)
                case .audit: UInt64(EHPROBE_BLOCKING_MODE_AUDIT)
                case .enforce: UInt64(EHPROBE_BLOCKING_MODE_ENFORCE)
                }
                ehprobe_set_container_blocking_mode(containerId, mode)
                Self.log.log(.info, "Set blocking mode for pre-existing container \(containerId): \(self.config.blockingMode.rawValue)")
            } else {
                Self.log.log(.error, "Failed to populate allowlist for pre-existing container: \(containerId)")
            }
        }
    }

    private static func parseDnsPayload(_ payload: [UInt8], family: UInt32) -> (queryName: String, queryType: UInt16, transactionId: UInt16, isResponse: Bool, responseCode: UInt16, answerCount: UInt16, rdata: [String]) {
        guard payload.count >= 12 else {
            return ("", 0, 0, false, 0, 0, [])
        }

        let transactionId = UInt16(payload[0]) << 8 | UInt16(payload[1])

        let flags = UInt16(payload[2]) << 8 | UInt16(payload[3])
        let isResponse = (flags & 0x8000) != 0
        let responseCode = UInt16(flags & 0x000F)

        let questionCount = UInt16(payload[4]) << 8 | UInt16(payload[5])

        let answerCount = UInt16(payload[6]) << 8 | UInt16(payload[7])

        var queryName = ""
        var offset = 12

        while offset < payload.count {
            let labelLen = Int(payload[offset])
            if labelLen == 0 {
                offset += 1
                break
            }

            if labelLen >= 0xC0 {
                offset += 2
                break
            }

            if offset + 1 + labelLen > payload.count {
                break
            }

            if !queryName.isEmpty {
                queryName += "."
            }

            let labelBytes = Array(payload[(offset + 1)..<(offset + 1 + labelLen)])
            if let label = String(bytes: labelBytes, encoding: .utf8) {
                queryName += label
            }

            offset += 1 + labelLen
        }

        var queryType: UInt16 = 0
        if offset + 2 <= payload.count {
            queryType = UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1])
        }

        offset += 4

        var rdataAddresses: [String] = []
        if isResponse && answerCount > 0 && questionCount > 0 {
            for _ in 1..<questionCount {
                while offset < payload.count {
                    let labelLen = Int(payload[offset])
                    if labelLen == 0 {
                        offset += 1
                        break
                    }
                    if labelLen >= 0xC0 {
                        offset += 2
                        break
                    }
                    offset += 1 + labelLen
                }
                offset += 4
            }

            for _ in 0..<min(answerCount, 4) {
                guard offset < payload.count else { break }

                let nameStart = payload[offset]
                if nameStart >= 0xC0 {
                    offset += 2
                } else {
                    while offset < payload.count {
                        let labelLen = Int(payload[offset])
                        if labelLen == 0 {
                            offset += 1
                            break
                        }
                        if labelLen >= 0xC0 {
                            offset += 2
                            break
                        }
                        offset += 1 + labelLen
                    }
                }

                guard offset + 10 <= payload.count else { break }

                let rrType = UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1])
                offset += 2

                offset += 2

                offset += 4

                let rdLength = Int(UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1]))
                offset += 2

                guard offset + rdLength <= payload.count else { break }

                if rrType == 1 && rdLength == 4 {
                    let addr = "\(payload[offset]).\(payload[offset + 1]).\(payload[offset + 2]).\(payload[offset + 3])"
                    rdataAddresses.append(addr)
                } else if rrType == 28 && rdLength == 16 {
                    var groups: [String] = []
                    for i in stride(from: offset, to: offset + 16, by: 2) {
                        let value = UInt16(payload[i]) << 8 | UInt16(payload[i + 1])
                        groups.append(String(format: "%x", value))
                    }
                    rdataAddresses.append(groups.joined(separator: ":"))
                }

                offset += rdLength
            }
        }

        return (queryName, queryType, transactionId, isResponse, responseCode, answerCount, rdataAddresses)
    }

    private static func subdomainFromQuery(_ query: String) -> String {
        let lookup = query.hasSuffix(".") ? String(query.dropLast(1)) : query

        var parts = lookup.split(separator: ".")
        guard parts.count > 2 else {
            return ""
        }

        parts.removeLast(2)

        return parts.joined(separator: ".")
    }

    private static func dnsQueryTypeString(_ queryType: UInt16) -> String {
        switch queryType {
        case 1: return "A"
        case 2: return "NS"
        case 5: return "CNAME"
        case 6: return "SOA"
        case 12: return "PTR"
        case 15: return "MX"
        case 16: return "TXT"
        case 28: return "AAAA"
        case 33: return "SRV"
        case 255: return "ANY"
        default: return "\(queryType)"
        }
    }

    private static func dnsResponseCodeString(_ rcode: UInt16) -> String {
        switch rcode {
        case 0: return "NOERROR"
        case 1: return "FORMERR"
        case 2: return "SERVFAIL"
        case 3: return "NXDOMAIN"
        case 4: return "NOTIMP"
        case 5: return "REFUSED"
        default: return "\(rcode)"
        }
    }

    public static func processEhprobeEvent(pipeline: EHPipeline, event: EHProbeEvent) async {
        switch event.eventType {
        case EHPROBE_EVENT_EXEC:
            let exe_path = event[0].asString
            let exe_file = event[1].asString
            let args = event[2].asMultiString
            let pid = event[3].asUInt64
            let ppid = event[4].asUInt64
            let comm = event[5].asString
            let cwd = event[6].asString
            let tty = EHProbeEvent.ttyDevicePath(from: event[7].asUInt32)
            let euid = event[8].asUInt32
            let egid = event[9].asUInt32
            let parent_exe_path = event[10].asString
            let container_id = event[11].asUInt64
            let container_level = event[12].asUInt32

            Self.log.log(.debug, """
                Processing EXEC event: \
                exe_path = \(exe_path), \
                exe_file = \(exe_file), \
                args = \(args), \
                pid = \(pid), \
                ppid = \(ppid), \
                comm = \(comm), \
                cwd = \(cwd), \
                tty = \(tty), \
                euid = \(euid), \
                egid = \(egid), \
                parent_exe_path = \(parent_exe_path), \
                container_id = \(container_id), \
                container_level = \(container_level)
                """)

            await pipeline.process(ESClient.ESClientProcExecEvent(
                startTime: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                cwd: cwd,
                args: args,
                executable: exe_path,
                signingID: "",
                platformBinary: true,
                tty: tty,
                script: "",
                pid: UInt32(pid),
                euid: euid,
                egid: egid,
                codesigningFlags: 0,
                ppid: Int32(ppid),
                parentExecutable: parent_exe_path,
                parentSigningID: "",
                parentPlatformBinary: true
            ))
            Self.log.log(.debug, "Processed EXEC event\n")

        case EHPROBE_EVENT_EXIT:
            let pid = event[0].asInt64
            let exit_code = event[1].asInt64
            let exit_status = event[2].asInt64
            let signal = event[3].asUInt8
            let core_dumped = event[4].asBool
            let container_id = event[5].asUInt64
            let container_level = event[6].asUInt32

            let exe_path = await ProcessCollector.processTree[pid]?.name ?? ""

            Self.log.log(.debug, """
                Processing EXIT event: \
                pid: \(pid), \
                exit_code: \(exit_code), \
                exit_status: \(exit_status), \
                signal: \(signal), \
                core_dumped: \(core_dumped), \
                container_id = \(container_id), \
                container_level = \(container_level), \
                exe_path: \(exe_path)
                """)

            await pipeline.process(ESClient.ESClientProcExitEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                pid: UInt32(pid),
                executable: exe_path,
                exitStatus: Int32(exit_status)
            ))
            Self.log.log(.debug, "Processed EXIT event\n")

        case EHPROBE_EVENT_FORK:
            let child_pid = event[0].asInt64
            let parent_pid = event[1].asInt64
            let comm = event[2].asString
            let parent_exe = event[3].asString
            let container_id = event[4].asUInt64
            let container_level = event[5].asUInt32

            Self.log.log(.debug, """
                FORK event: \
                child_pid = \(child_pid), \
                parent_pid = \(parent_pid), \
                comm = \(comm), \
                parent_exe = \(parent_exe), \
                container_id = \(container_id), \
                container_level = \(container_level)
                """)

            await pipeline.process(EhprobeProcForkEvent(
                startTime: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                pid: child_pid,
                ppid: parent_pid,
                comm: comm,
                parentExe: parent_exe,
                containerId: container_id,
                containerLevel: container_level
            ))
            Self.log.log(.debug, "Processed FORK event\n")

        case EHPROBE_EVENT_BLOCK_KILL:
            let source_pid = event[0].asInt64
            let signal = event[1].asUInt8

            Self.log.log(.debug, """
                BLOCK_KILL event: \
                source_pid = \(source_pid), \
                signal = \(signal)
                """)

            await pipeline.process(EhprobeBlockKillEvent(
                sourcePid: UInt32(source_pid),
                signal: signal
            ))

        case EHPROBE_EVENT_NEW_FS_EXEC:
            let exe_path = event[0].asString
            let hash = event[1].asHexString
            let pid = event[2].asInt64
            let process_path = event[3].asString

            Self.log.log(.debug, """
                NEW_FS_EXEC event: \
                exe_path = \(exe_path), \
                hash = \(hash), \
                pid = \(pid), \
                process_path = \(process_path)
                """)

            await pipeline.process(EhprobeNewFsExecEvent(
                executable: exe_path,
                hash: hash,
                pid: UInt32(pid),
                processPath: process_path
            ))

        case EHPROBE_EVENT_EXEC_SECURITY:
            let exe_path = event[0].asString
            let hash = event[1].asHexString
            let pid = event[2].asInt64
            let allow = event[5].asBool
            let blockingModeRaw = event[6].asUInt32
            let blockingMode: ExecBlockingMode = switch blockingModeRaw {
            case UInt32(EHPROBE_BLOCKING_MODE_AUDIT): .audit
            case UInt32(EHPROBE_BLOCKING_MODE_ENFORCE): .enforce
            default: .off
            }

            Self.log.log(.info, """
                EXEC_SECURITY event: \
                path = \(exe_path), \
                hash = \(hash), \
                pid = \(pid), \
                allow = \(allow), \
                blocking_mode = \(blockingMode.rawValue)
                """)

            if !allow {
                await pipeline.process(EhprobeBlockedExecEvent(
                    executable: exe_path,
                    hash: hash,
                    pid: UInt32(pid),
                    blockingMode: blockingMode
                ))
            }

        case EHPROBE_EVENT_SCRIPT_SECURITY:
            let script_path = event[0].asString
            let hash = event[1].asHexString
            let pid = event[2].asInt64
            let container_id = event[3].asUInt64
            let container_level = event[4].asUInt32
            let allow = event[5].asBool
            let blockingModeRaw = event[6].asUInt32
            let blockingMode: ExecBlockingMode = switch blockingModeRaw {
            case UInt32(EHPROBE_BLOCKING_MODE_AUDIT): .audit
            case UInt32(EHPROBE_BLOCKING_MODE_ENFORCE): .enforce
            default: .off
            }
            let isInlineCode = event[7].asBool
            let isPipedStdin = event[8].asBool
            let isNoArgs = event[9].asBool

            Self.log.log(.info, """
                SCRIPT_SECURITY event: \
                script_path = \(script_path), \
                hash = \(hash), \
                pid = \(pid), \
                container_id = \(container_id), \
                allow = \(allow), \
                blocking_mode = \(blockingMode.rawValue), \
                is_inline_code = \(isInlineCode), \
                is_piped_stdin = \(isPipedStdin), \
                is_no_args = \(isNoArgs)
                """)

            await pipeline.process(EhprobeScriptSecurityEvent(
                script_path: script_path,
                hash: hash,
                pid: UInt32(pid),
                containerId: container_id,
                containerLevel: container_level,
                blockingMode: blockingMode,
                isInlineCode: isInlineCode,
                isPipedStdin: isPipedStdin,
                isNoArgs: isNoArgs,
                allowed: allow
            ))

        case EHPROBE_EVENT_SCRIPT_FILE_CHECK:
            let filePath = event[0].asString
            let pid = event[1].asInt64
            let scriptPath = event[2].asString
            let blockingModeRaw = event[3].asUInt32
            let blockingMode: ExecBlockingMode = switch blockingModeRaw {
            case UInt32(EHPROBE_BLOCKING_MODE_AUDIT): .audit
            case UInt32(EHPROBE_BLOCKING_MODE_ENFORCE): .enforce
            default: .off
            }

            let resolvedScriptPath = Self.resolveInterpreterPath(scriptPath, pid: pid)

            let startupPath = Self.readEnvVar("PYTHONSTARTUP", pid: pid)
            let resolvedStartupPath = Self.resolveInterpreterPath(startupPath, pid: pid)

            let matched = (!resolvedScriptPath.isEmpty && filePath == resolvedScriptPath)
                || (!resolvedStartupPath.isEmpty && filePath == resolvedStartupPath)

            if matched {
                if blockingMode == .enforce {
                    Self.log.log(.error, """
                        SCRIPT_FILE_CHECK: killing pid=\(pid) for unauthorized extensionless script \
                        file=\(filePath) script_path=\(scriptPath) startup=\(startupPath)
                        """)
                    kill(Int32(pid), SIGKILL)
                } else if blockingMode == .audit {
                    Self.log.log(.info, """
                        SCRIPT_FILE_CHECK: audit: unauthorized extensionless script \
                        file=\(filePath) script_path=\(scriptPath) startup=\(startupPath) pid=\(pid)
                        """)
                }
            }

        case EHPROBE_EVENT_CONTAINER_START:
            let id = event[0].asUInt64
            let level = event[1].asUInt32
            let pid = event[2].asInt64
            let ppid = event[3].asInt64
            let pid_ns_inum = event[4].asUInt64
            let mnt_ns_inum = event[5].asUInt64
            let net_ns_inum = event[6].asUInt64
            let cgroup_id = event[7].asUInt64
            let runtime = event[8].asString
            let blocking_mode = event[9].asUInt32

            Self.log.log(.debug, """
                CONTAINER_START event: \
                id = \(id), \
                level = \(level), \
                pid = \(pid), \
                ppid = \(ppid), \
                pid_ns_inum = \(pid_ns_inum), \
                mnt_ns_inum = \(mnt_ns_inum), \
                net_ns_inum = \(net_ns_inum), \
                cgroup_id = \(cgroup_id), \
                runtime = \(runtime), \
                blocking_mode = \(blocking_mode)
                """)

            if blocking_mode != UInt32(EHPROBE_BLOCKING_MODE_OFF) {
                if execAllowlistController.populateAllowlist(
                    containerId: id,
                    containerPid: pid,
                    allowlistFolders: allowlistFolders) {

                    ehprobe_set_container_blocking_mode(id, UInt64(blocking_mode))
                }
            }

        case EHPROBE_EVENT_CONTAINER_STOP:
            let id = event[0].asUInt64
            let level = event[1].asUInt32
            let exit_signal = event[2].asUInt8
            let exit_code = event[3].asInt64
            let runtime = event[4].asString
            let blocking_mode = event[5].asUInt32

            Self.log.log(.debug, """
                CONTAINER_STOP event: \
                id = \(id), \
                level = \(level), \
                exit_signal = \(exit_signal), \
                exit_code = \(exit_code), \
                runtime = \(runtime), \
                blocking_mode = \(blocking_mode)
                """)

            if blocking_mode != UInt32(EHPROBE_BLOCKING_MODE_OFF) {
                execAllowlistController.removeContainerAllowlist(containerId: id)
            }

        case EHPROBE_EVENT_NET_TCP:
            let pid = event[0].asInt64
            let comm = event[1].asString
            let fd = event[2].asInt64
            let family = event[3].asUInt32
            let destAddr = event[4].asIPAddress(family: family) ?? ""
            let destPort = event[5].asUInt32
            let localPort = event[6].asUInt32
            let initiator = event[7].asUInt32
            let uid = event[8].asUInt32
            let container_id = event[9].asUInt64
            let container_level = event[10].asUInt32

            let direction = (initiator == 1) ? "outbound" : "inbound"

            Self.log.log(.debug, """
                NET_TCP event: \
                pid = \(pid), \
                comm = \(comm), \
                fd = \(fd), \
                family = \(family == 2 ? "IPv4" : "IPv6"), \
                dest = \(destAddr):\(destPort), \
                local_port = \(localPort), \
                initiator = \(direction), \
                uid = \(uid), \
                container_id = \(container_id), \
                container_level = \(container_level)
                """)

            await pipeline.process(EhprobeNetworkEvent(
                startTime: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                pid: pid,
                procName: comm,
                remoteAddr: destAddr,
                remotePort: UInt16(destPort),
                localPort: UInt16(localPort),
                direction: direction,
                protocol: "tcp",
                uid: uid,
                containerId: container_id,
                containerLevel: container_level
            ))
            Self.log.log(.debug, "Processed NET_TCP event\n")

        case EHPROBE_EVENT_NET_UDP:
            let pid = event[0].asInt64
            let comm = event[1].asString
            let family = event[2].asUInt32
            let remoteAddr = event[3].asIPAddress(family: family) ?? ""
            let remotePort = event[4].asUInt32
            let localPort = event[5].asUInt32
            let initiator = event[6].asUInt32
            let uid = event[7].asUInt32
            let container_id = event[8].asUInt64
            let container_level = event[9].asUInt32

            let direction = (initiator == 1) ? "outbound" : "inbound"

            Self.log.log(.debug, """
                NET_UDP event: \
                pid = \(pid), \
                comm = \(comm), \
                family = \(family == 2 ? "IPv4" : "IPv6"), \
                remote = \(remoteAddr):\(remotePort), \
                local_port = \(localPort), \
                initiator = \(direction), \
                uid = \(uid), \
                container_id = \(container_id), \
                container_level = \(container_level)
                """)

            await pipeline.process(EhprobeNetworkEvent(
                startTime: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                pid: pid,
                procName: comm,
                remoteAddr: remoteAddr,
                remotePort: UInt16(remotePort),
                localPort: UInt16(localPort),
                direction: direction,
                protocol: "udp",
                uid: uid,
                containerId: container_id,
                containerLevel: container_level
            ))
            Self.log.log(.debug, "Processed NET_UDP event\n")

        case EHPROBE_EVENT_DNS:
            let pid = event[0].asInt64
            let comm = event[1].asString
            let uid = event[2].asUInt32
            let directionVal = event[3].asUInt32
            let family = event[6].asUInt32
            let serverAddr = event[4].asIPAddress(family: family) ?? ""
            let serverPort = event[5].asUInt32
            let payload = Array(event[7].asData)
            let originalLen = event[8].asUInt32
            let container_id = event[9].asUInt64
            let container_level = event[10].asUInt32

            let rowtype = (directionVal == 1) ? EhprobeDnsEvent.QueryType.start.rawValue : EhprobeDnsEvent.QueryType.result.rawValue
            let familyStr = (family == 2) ? "IPv4" : "IPv6"

            let (queryName, queryTypeNum, transactionId, isResponse, responseCode, answerCount, rdataAddrs) = parseDnsPayload(payload, family: family)

            let qtypeStr = dnsQueryTypeString(queryTypeNum)
            let rcodeStr = dnsResponseCodeString(responseCode)

            let qname = queryName.hasSuffix(".") ? queryName : (queryName.isEmpty ? "" : queryName + ".")

            let qnameSE = qname.shannonEntropy()

            let subqname = Self.subdomainFromQuery(qname)
            let subqnameSE = subqname.shannonEntropy()

            let rdata = rdataAddrs.joined(separator: ", ")

            Self.log.log(.debug, """
                DNS event: \
                pid = \(pid), \
                comm = \(comm), \
                uid = \(uid), \
                rowtype = \(rowtype), \
                server = \(serverAddr):\(serverPort), \
                family = \(familyStr), \
                tx_id = 0x\(String(format: "%04x", transactionId)), \
                qname = \(qname), \
                qtype = \(qtypeStr), \
                qr = \(isResponse ? "response" : "query"), \
                rcode = \(rcodeStr), \
                answers = \(answerCount), \
                rdata = \(rdata), \
                qnameSE = \(String(format: "%.4f", qnameSE)), \
                subqname = \(subqname), \
                payload_size = \(payload.count), \
                original_len = \(originalLen), \
                container_id = \(container_id), \
                container_level = \(container_level)
                """)

            await pipeline.process(EhprobeDnsEvent(
                startTime: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                pid: pid,
                procName: comm,
                uid: uid,
                rowtype: rowtype,
                serverAddr: serverAddr,
                serverPort: UInt16(serverPort),
                family: familyStr,
                transactionId: transactionId,
                qtype: qtypeStr,
                qname: qname,
                rcode: rcodeStr,
                answerCount: answerCount,
                rdata: rdata,
                qnameSE: qnameSE,
                subqname: subqname,
                subqnameSE: subqnameSE,
                containerId: container_id,
                containerLevel: container_level
            ))
            Self.log.log(.debug, "Processed DNS event\n")

        case EHPROBE_EVENT_DEVICE_OPEN:
            let devicePath = event[0].asString
            let deviceMajor = event[1].asUInt32
            let deviceMinor = event[2].asUInt32
            let deviceClass = event[3].asString
            let executable = event[4].asString
            let containerId = event[5].asUInt64
            let containerLevel = event[6].asUInt32

            Self.log.log(.debug, """
                DEVICE_OPEN event: \
                pid = \(event.pid), \
                device = \(devicePath), \
                major = \(deviceMajor), \
                minor = \(deviceMinor), \
                class = \(deviceClass), \
                exe = \(executable), \
                container_id = \(containerId), \
                container_level = \(containerLevel)
                """)

            await pipeline.process(EhprobeDeviceOpenEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                pid: Int64(event.pid),
                devicePath: devicePath,
                deviceMajor: deviceMajor,
                deviceMinor: deviceMinor,
                deviceClass: deviceClass,
                executable: executable,
                containerId: containerId,
                containerLevel: containerLevel
            ))
            Self.log.log(.debug, "Processed DEVICE_OPEN event\n")

        case EHPROBE_EVENT_FILE_OPEN:
            let filePath = event[0].asString
            let flags = event[1].asInt32
            let ppid = event[2].asInt64
            let uid = event[3].asUInt32
            let executable = event[4].asString
            let containerId = event[5].asUInt64
            let containerLevel = event[6].asUInt32

            Self.log.log(.debug, """
                FILE_OPEN event: \
                pid = \(event.pid), \
                path = \(filePath), \
                flags = \(flags), \
                ppid = \(ppid), \
                uid = \(uid), \
                exe = \(executable), \
                container_id = \(containerId), \
                container_level = \(containerLevel)
                """)

            await pipeline.process(EhprobeFileOpenEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                path: filePath,
                flags: flags,
                pid: Int64(event.pid),
                ppid: ppid,
                uid: uid,
                executable: executable,
                containerId: containerId,
                containerLevel: containerLevel
            ))
            Self.log.log(.debug, "Processed FILE_OPEN event\n")

        case EHPROBE_EVENT_FILE_WRITE:
            let filePath = event[0].asString
            let ppid = event[1].asInt64
            let uid = event[2].asUInt32
            let executable = event[3].asString
            let containerId = event[4].asUInt64
            let containerLevel = event[5].asUInt32

            Self.log.log(.debug, """
                FILE_WRITE event: \
                pid = \(event.pid), \
                path = \(filePath), \
                ppid = \(ppid), \
                uid = \(uid), \
                exe = \(executable), \
                container_id = \(containerId), \
                container_level = \(containerLevel)
                """)

            await pipeline.process(EhprobeFileWriteEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                path: filePath,
                pid: Int64(event.pid),
                ppid: ppid,
                uid: uid,
                executable: executable,
                containerId: containerId,
                containerLevel: containerLevel
            ))
            Self.log.log(.debug, "Processed FILE_WRITE event\n")

        case EHPROBE_EVENT_FILE_UNLINK:
            let filePath = event[0].asString
            let ppid = event[1].asInt64
            let uid = event[2].asUInt32
            let executable = event[3].asString
            let containerId = event[4].asUInt64
            let containerLevel = event[5].asUInt32

            Self.log.log(.debug, """
                FILE_UNLINK event: \
                pid = \(event.pid), \
                path = \(filePath), \
                ppid = \(ppid), \
                uid = \(uid), \
                exe = \(executable), \
                container_id = \(containerId), \
                container_level = \(containerLevel)
                """)

            await pipeline.process(EhprobeFileUnlinkEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                path: filePath,
                pid: Int64(event.pid),
                ppid: ppid,
                uid: uid,
                executable: executable,
                containerId: containerId,
                containerLevel: containerLevel
            ))
            Self.log.log(.debug, "Processed FILE_UNLINK event\n")

        case EHPROBE_EVENT_SETUID:
            let oldUid = event[0].asUInt32
            let newUid = event[1].asUInt32
            let oldEuid = event[2].asUInt32
            let newEuid = event[3].asUInt32
            let ppid = event[4].asInt64
            let executable = event[5].asString
            let containerId = event[6].asUInt64
            let containerLevel = event[7].asUInt32

            Self.log.log(.debug, """
                SETUID event: \
                pid = \(event.pid), \
                old_uid = \(oldUid), \
                new_uid = \(newUid), \
                old_euid = \(oldEuid), \
                new_euid = \(newEuid), \
                ppid = \(ppid), \
                exe = \(executable), \
                container_id = \(containerId), \
                container_level = \(containerLevel)
                """)

            await pipeline.process(EhprobeSetuidEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                oldUid: oldUid,
                newUid: newUid,
                oldEuid: oldEuid,
                newEuid: newEuid,
                pid: Int64(event.pid),
                ppid: ppid,
                executable: executable,
                containerId: containerId,
                containerLevel: containerLevel
            ))
            Self.log.log(.debug, "Processed SETUID event\n")

        case EHPROBE_EVENT_SETGID:
            let oldGid = event[0].asUInt32
            let newGid = event[1].asUInt32
            let oldEgid = event[2].asUInt32
            let newEgid = event[3].asUInt32
            let ppid = event[4].asInt64
            let executable = event[5].asString
            let containerId = event[6].asUInt64
            let containerLevel = event[7].asUInt32

            Self.log.log(.debug, """
                SETGID event: \
                pid = \(event.pid), \
                old_gid = \(oldGid), \
                new_gid = \(newGid), \
                old_egid = \(oldEgid), \
                new_egid = \(newEgid), \
                ppid = \(ppid), \
                exe = \(executable), \
                container_id = \(containerId), \
                container_level = \(containerLevel)
                """)

            await pipeline.process(EhprobeSetgidEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                oldGid: oldGid,
                newGid: newGid,
                oldEgid: oldEgid,
                newEgid: newEgid,
                pid: Int64(event.pid),
                ppid: ppid,
                executable: executable,
                containerId: containerId,
                containerLevel: containerLevel
            ))
            Self.log.log(.debug, "Processed SETGID event\n")

        case EHPROBE_EVENT_AF_ALG_BIND:
            let salgType = event[0].asString
            let salgName = event[1].asString
            let ppid = event[2].asInt64
            let executable = event[3].asString
            let containerId = event[4].asUInt64
            let containerLevel = event[5].asUInt32
            let blockingModeRaw = event[6].asUInt64
            let blockingMode: ExecBlockingMode = switch blockingModeRaw {
            case UInt64(EHPROBE_BLOCKING_MODE_AUDIT): .audit
            case UInt64(EHPROBE_BLOCKING_MODE_ENFORCE): .enforce
            default: .off
            }

            Self.log.log(.debug, """
                AF_ALG_BIND event: \
                pid = \(event.pid), \
                salg_type = \(salgType), \
                salg_name = \(salgName), \
                ppid = \(ppid), \
                exe = \(executable), \
                container_id = \(containerId), \
                container_level = \(containerLevel), \
                blocking_mode = \(blockingMode.rawValue)
                """)

            await pipeline.process(EhprobeAFAlgBindEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                salgType: salgType,
                salgName: salgName,
                pid: Int64(event.pid),
                ppid: ppid,
                executable: executable,
                containerId: containerId,
                containerLevel: containerLevel,
                blockingMode: blockingMode
            ))
            Self.log.log(.debug, "Processed AF_ALG_BIND event\n")

        case EHPROBE_EVENT_MODULE_LOAD_REQUEST:
            let moduleName = event[0].asString
            let filePath = event[1].asString
            let hookTag = event[2].asUInt32
            let ppid = event[3].asInt64
            let executable = event[4].asString
            let containerId = event[5].asUInt64
            let containerLevel = event[6].asUInt32
            let blockingModeRaw = event[7].asUInt64
            let blockingMode: ExecBlockingMode = switch blockingModeRaw {
            case UInt64(EHPROBE_BLOCKING_MODE_AUDIT): .audit
            case UInt64(EHPROBE_BLOCKING_MODE_ENFORCE): .enforce
            default: .off
            }
            let hook: EhprobeModuleLoadRequestEvent.Hook = switch hookTag {
            case 1: .request
            case 2: .read
            default: .unknown
            }

            Self.log.log(.debug, """
                MODULE_LOAD_REQUEST event: \
                pid = \(event.pid), \
                module = \(moduleName), \
                file = \(filePath), \
                hook = \(hook.rawValue), \
                ppid = \(ppid), \
                exe = \(executable), \
                container_id = \(containerId), \
                container_level = \(containerLevel), \
                blocking_mode = \(blockingMode.rawValue)
                """)

            await pipeline.process(EhprobeModuleLoadRequestEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                moduleName: moduleName,
                filePath: filePath,
                hook: hook,
                pid: Int64(event.pid),
                ppid: ppid,
                executable: executable,
                containerId: containerId,
                containerLevel: containerLevel,
                blockingMode: blockingMode
            ))
            Self.log.log(.debug, "Processed MODULE_LOAD_REQUEST event\n")

        case EHPROBE_EVENT_XFRM_SA_NEW:
            let userNsInum = event[0].asUInt64
            let saFlags = event[1].asUInt32
            let aeadName = event[2].asString
            let authName = event[3].asString
            let cryptName = event[4].asString
            let ppid = event[5].asInt64
            let executable = event[6].asString
            let containerId = event[7].asUInt64
            let containerLevel = event[8].asUInt32
            let blockingModeRaw = event[9].asUInt64
            let blockingMode: ExecBlockingMode = switch blockingModeRaw {
            case UInt64(EHPROBE_BLOCKING_MODE_AUDIT): .audit
            case UInt64(EHPROBE_BLOCKING_MODE_ENFORCE): .enforce
            default: .off
            }

            Self.log.log(.debug, """
                XFRM_SA_NEW event: \
                pid = \(event.pid), \
                userns = \(userNsInum), \
                flags = 0x\(String(saFlags, radix: 16)), \
                aead = \(aeadName), \
                auth = \(authName), \
                crypt = \(cryptName), \
                ppid = \(ppid), \
                exe = \(executable), \
                container_id = \(containerId), \
                container_level = \(containerLevel), \
                blocking_mode = \(blockingMode.rawValue)
                """)

            await pipeline.process(EhprobeXfrmSaNewEvent(
                timestamp: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                userNsInum: userNsInum,
                saFlags: saFlags,
                aeadName: aeadName,
                authName: authName,
                cryptName: cryptName,
                pid: Int64(event.pid),
                ppid: ppid,
                executable: executable,
                containerId: containerId,
                containerLevel: containerLevel,
                blockingMode: blockingMode
            ))
            Self.log.log(.debug, "Processed XFRM_SA_NEW event\n")

        case EHPROBE_EVENT_NET_ICMP:
            let pid    = event[0].asInt64
            let comm   = event[1].asString
            let uid    = event[2].asUInt32
            let icmpType  = UInt8(event[3].asUInt32)
            let icmpCode  = UInt8(event[4].asUInt32)
            let identifier = UInt16(event[5].asUInt32)
            let sequence   = UInt16(event[6].asUInt32)
            let family = event[7].asUInt32
            let remoteAddr = event[8].asIPAddress(family: family) ?? ""
            let containerId    = event[9].asUInt64
            let containerLevel = event[10].asUInt32

            Self.log.log(.debug, """
                NET_ICMP event: \
                pid = \(pid), \
                comm = \(comm), \
                family = \(family == 2 ? "IPv4" : "IPv6"), \
                remote = \(remoteAddr), \
                icmp_type = \(icmpType), \
                icmp_code = \(icmpCode), \
                id = \(identifier), \
                seq = \(sequence), \
                uid = \(uid), \
                container_id = \(containerId), \
                container_level = \(containerLevel)
                """)

            await pipeline.process(EhprobeIcmpEvent(
                startTime: Self.systemBootTime + (Double(event.timestampNs) / 1_000_000_000.0),
                pid: pid,
                procName: comm,
                remoteAddr: remoteAddr,
                family: family == 2 ? "IPv4" : "IPv6",
                icmpType: icmpType,
                icmpCode: icmpCode,
                identifier: identifier,
                sequence: sequence,
                uid: uid,
                containerId: containerId,
                containerLevel: containerLevel
            ))
            Self.log.log(.debug, "Processed NET_ICMP event\n")

        case EHPROBE_EVENT_PACKET_DATA:
            let pid = event[0].asInt64
            let comm = event[1].asString
            let family = event[2].asUInt32
            let proto = event[3].asUInt32
            let remoteAddr = event[4].asIPAddress(family: family) ?? ""
            let remotePort = UInt16(event[5].asUInt32)
            let localPort = UInt16(event[6].asUInt32)
            let dir = event[7].asUInt32
            let ifindex = event[8].asUInt32
            let payloadData = event[9].asData
            let payloadLen = event[10].asUInt32
            let containerId = event[11].asUInt64
            let containerLevel = event[12].asUInt32

            let direction = (dir == 1) ? "outbound" : "inbound"

            Self.log.log(.debug, """
                PACKET_DATA event: \
                pid = \(pid), \
                comm = \(comm), \
                proto = \(proto == 6 ? "TCP" : "UDP"), \
                remote = \(remoteAddr):\(remotePort), \
                local_port = \(localPort), \
                direction = \(direction), \
                ifindex = \(ifindex), \
                payload_len = \(payloadLen)
                """)

            await pipeline.process(EhprobePacketDataEvent(
                pid: pid,
                procName: comm,
                family: family,
                networkProtocol: proto,
                remoteAddr: remoteAddr,
                remotePort: remotePort,
                localPort: localPort,
                direction: direction,
                payload: payloadData,
                payloadLen: payloadLen,
                containerId: containerId,
                containerLevel: containerLevel,
                ifindex: ifindex
            ))

        default:
            Self.log.log(.debug, "Unrecognized event: type \(event.eventType)\n")
        }
    }

    public func start(_ pipeline: EHPipeline) throws {
        guard startEhprobe(pipeline: pipeline) else {
            return
        }

        pollingTask = Task { @Sendable in
            while !Task.isCancelled {
                let result = ehprobe_poll(100)
                if result < 0 {
                    guard result == Int32(EHPROBE_ERROR_NOT_RUNNING.rawValue) || result == Int32(EHPROBE_ERROR_NOT_INITIALIZED.rawValue) else {
                        Self.log.log(.error, "Error polling ehprobe: \(result)")
                        break
                    }

                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }
    #else
    public func configure(_ pipeline: EHPipeline) throws {
        throw EhprobeGeneratorError.platformUnsupported
    }

    public func start(_ pipeline: EHPipeline) throws {
        throw EhprobeGeneratorError.platformUnsupported
    }

    public func stop() throws {
        throw EhprobeGeneratorError.platformUnsupported
    }
    #endif

}
