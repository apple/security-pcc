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


#if os(Linux)
import Foundation
#if canImport(os)
import os
#endif


public protocol SSHSocketMatcher: Sendable {
    func findSocketEndpoint(forPid pid: Int64, localPort: UInt16) -> String?
}

public final class ProcSSHSocketMatcher: SSHSocketMatcher {
    private let procPath: String
    private let log = EHLog.withCategory(ProcSSHSocketMatcher.self)

    public init(hostProcPath: String? = nil) {
        self.procPath = hostProcPath ?? "/proc"
    }

    public func findSocketEndpoint(forPid pid: Int64, localPort: UInt16) -> String? {
        let fdPath = "\(procPath)/\(pid)/fd"
        os_log(.debug, log: self.log, "[SSH_DEBUG] findSocketEndpoint: procPath=%{public}s pid=%lld localPort=%d", procPath, pid, localPort)

        guard let fdEntries = try? FileManager.default.contentsOfDirectory(atPath: fdPath) else {
            os_log(.debug, log: self.log, "[SSH_DEBUG] findSocketEndpoint: cannot read fd directory %{public}s for pid %lld", fdPath, pid)
            return nil
        }

        var socketInodes: [String] = []

        for fd in fdEntries {
            let fdSymlinkPath = "\(procPath)/\(pid)/fd/\(fd)"
            guard let symlinkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: fdSymlinkPath) else {
                continue
            }

            if symlinkTarget.hasPrefix("socket:[") && symlinkTarget.hasSuffix("]") {
                let start = symlinkTarget.index(symlinkTarget.startIndex, offsetBy: 8)
                let end = symlinkTarget.index(before: symlinkTarget.endIndex)
                let inodeStr = String(symlinkTarget[start..<end])
                socketInodes.append(inodeStr)

                if let endpoint = lookupSocketEndpoint(inode: inodeStr, localPort: localPort, pid: pid) {
                    os_log(.debug, log: self.log,
                           "[SSH_DEBUG] findSocketEndpoint: pid %lld inode %{public}s matched endpoint %{public}s (localPort %d)",
                           pid, inodeStr, endpoint, localPort)
                    return endpoint
                }
            }
        }

        os_log(.debug, log: self.log,
               "[SSH_DEBUG] findSocketEndpoint: pid %lld no matching socket found for localPort %d (checked %d socket inodes: %{public}s)",
               pid, localPort, socketInodes.count, socketInodes.joined(separator: ","))
        return nil
    }

    private func lookupSocketEndpoint(inode: String, localPort: UInt16, pid: Int64) -> String? {
        let netBase = "\(procPath)/\(pid)/net"
        for tcpFile in ["\(netBase)/tcp", "\(netBase)/tcp6"] {
            guard let tcpContent = try? String(contentsOfFile: tcpFile, encoding: .utf8) else {
                continue
            }

            for line in tcpContent.split(separator: "\n").dropFirst() {
                let parts = line.split(separator: " ")

                guard parts.count >= 10 else { continue }

                guard parts[9] == inode else { continue }

                let localAddrPort = parts[1]
                guard let colonIdx = localAddrPort.firstIndex(of: ":") else { continue }
                let localPortHex = localAddrPort[localAddrPort.index(after: colonIdx)...]
                guard let localPortValue = UInt16(localPortHex, radix: 16), localPortValue == localPort else {
                    continue
                }

                let remoteAddrPort = parts[2]
                guard let remoteColonIdx = remoteAddrPort.firstIndex(of: ":") else { continue }
                let remoteAddrHex = remoteAddrPort[remoteAddrPort.startIndex..<remoteColonIdx]
                let remotePortHex = remoteAddrPort[remoteAddrPort.index(after: remoteColonIdx)...]

                let remoteAddr: String
                if tcpFile.hasSuffix("/net/tcp") {
                    guard remoteAddrHex.count == 8 else { continue }

                    let byte1 = UInt8(remoteAddrHex.suffix(2), radix: 16) ?? 0
                    let byte2 = UInt8(remoteAddrHex.dropLast(2).suffix(2), radix: 16) ?? 0
                    let byte3 = UInt8(remoteAddrHex.dropLast(4).suffix(2), radix: 16) ?? 0
                    let byte4 = UInt8(remoteAddrHex.prefix(2), radix: 16) ?? 0

                    remoteAddr = "\(byte1).\(byte2).\(byte3).\(byte4)"
                } else {
                    if remoteAddrHex.count == 32 && remoteAddrHex.hasPrefix("0000000000000000FFFF0000") {
                        let ipv4Hex = remoteAddrHex.suffix(8)
                        let byte1 = UInt8(ipv4Hex.suffix(2), radix: 16) ?? 0
                        let byte2 = UInt8(ipv4Hex.dropLast(2).suffix(2), radix: 16) ?? 0
                        let byte3 = UInt8(ipv4Hex.dropLast(4).suffix(2), radix: 16) ?? 0
                        let byte4 = UInt8(ipv4Hex.prefix(2), radix: 16) ?? 0
                        remoteAddr = "\(byte1).\(byte2).\(byte3).\(byte4)"
                    } else if remoteAddrHex.count == 32 {
                        remoteAddr = formatIPv6Address(String(remoteAddrHex))
                    } else {
                        remoteAddr = String(remoteAddrHex)
                    }
                }

                guard let remotePort = UInt16(remotePortHex, radix: 16) else { continue }

                return "\(remoteAddr):\(remotePort)"
            }
        }

        return nil
    }

    private func formatIPv6Address(_ hexStr: String) -> String {
        guard hexStr.count == 32 else {
            return hexStr
        }

        var bytes: [UInt8] = []
        for i in stride(from: 0, to: 32, by: 8) {
            let group = String(hexStr[hexStr.index(hexStr.startIndex, offsetBy: i)..<hexStr.index(hexStr.startIndex, offsetBy: i + 8)])
            for j in stride(from: 6, through: 0, by: -2) {
                let byteHex = String(group[group.index(group.startIndex, offsetBy: j)..<group.index(group.startIndex, offsetBy: j + 2)])
                if let byte = UInt8(byteHex, radix: 16) {
                    bytes.append(byte)
                }
            }
        }

        guard bytes.count == 16 else {
            return hexStr
        }

        var groups: [UInt16] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let value = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            groups.append(value)
        }

        var longestStart = -1
        var longestLen = 0
        var currentStart = -1
        var currentLen = 0

        for i in 0..<8 {
            if groups[i] == 0 {
                if currentStart == -1 {
                    currentStart = i
                    currentLen = 1
                } else {
                    currentLen += 1
                }
            } else {
                if currentLen > longestLen && currentLen > 1 {
                    longestStart = currentStart
                    longestLen = currentLen
                }
                currentStart = -1
                currentLen = 0
            }
        }
        if currentLen > longestLen && currentLen > 1 {
            longestStart = currentStart
            longestLen = currentLen
        }

        var result = ""
        var i = 0
        while i < 8 {
            if i == longestStart {
                result += i == 0 ? "::" : ":"
                i += longestLen
            } else {
                if i > 0 && i != longestStart + longestLen {
                    result += ":"
                }
                result += String(format: "%x", groups[i])
                i += 1
            }
        }

        return result
    }
}

public final class SSHEventSynthesizer: EHTransform {
    public let name = "SSHEventSynthesizer"

    private let sessionTracker: SSHSessionTracker
    private let log = EHLog.withCategory(SSHEventSynthesizer.self)

    public init(
        sshdSessionTimeoutSeconds: TimeInterval = 5.0,
        shellTimeoutSeconds: TimeInterval = 120.0,
        activeTimeoutHours: TimeInterval = 24.0,
        maxPendingCorrelations: Int = 1024,
        maxActiveSessions: Int = 512,
        socketMatcher: SSHSocketMatcher? = nil,
        hostProcPath: String? = nil
    ) {
        self.sessionTracker = SSHSessionTracker(
            sshdSessionTimeout: sshdSessionTimeoutSeconds,
            shellTimeout: shellTimeoutSeconds,
            activeTimeout: activeTimeoutHours * 3600,
            maxPending: maxPendingCorrelations,
            maxSessions: maxActiveSessions,
            socketMatcher: socketMatcher ?? ProcSSHSocketMatcher(hostProcPath: hostProcPath)
        )
    }

    public func setHostProcPath(_ path: String) async {
        await sessionTracker.setHostProcPath(path)
    }

    public func configure() async throws {
        os_log(.info, log: self.log, "SSHEventSynthesizer configured")

        Task {
            while true {
                await sessionTracker.cleanupExpired()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        if let netEvent = event as? EventNormalizer.NormalizedNetwork {
            await processNetworkEvent(netEvent)
            return (.proceed, nil, nil, nil)
        }

        if let procEvent = event as? EventNormalizer.NormalizedProcess {
            if procEvent.tags.contains(EventNormalizer.NormalizedProcess.Tags.fork_only.rawValue) {
                return (.proceed, nil, nil, nil)
            }

            if isSSHDaemon(procEvent.exe) {
                os_log(.debug, log: self.log,
                       "[SSH_DEBUG] process: sshd EXEC detected pid=%lld exe=%{public}s ppid=%lld",
                       procEvent.pid, procEvent.exe, procEvent.ppid)
                await processSshdExecEvent(procEvent)
                return (.proceed, nil, nil, nil)
            }

            if let loginEvent = await processShellExecEvent(procEvent) {
                return (.proceed, [procEvent, loginEvent], nil, nil)
            }

            return (.proceed, nil, nil, nil)
        }

        if let exitEvent = event as? ESClient.ESClientProcExitEvent {
            if let logoutEvent = await processExitEvent(exitEvent) {
                return (.proceed, [exitEvent, logoutEvent], nil, nil)
            }
            return (.proceed, nil, nil, nil)
        }

        return (.proceed, nil, nil, nil)
    }

    private func isSSHDaemon(_ executable: String) -> Bool {
        let basename = (executable as NSString).lastPathComponent
        return basename.hasPrefix("sshd")
    }

    private func processNetworkEvent(_ event: EventNormalizer.NormalizedNetwork) async {

        guard event.protocol == "tcp" &&
              event.direction == "inbound" else {
            return
        }

        let actualProcess = await ProcessCollector.processTree[event.pid]
        let processStartTime: Double
        if let process = actualProcess {
            processStartTime = process.startTime
        } else {
            processStartTime = event.start_time
        }

        let isPort22 = event.local_port == 22
        let isSshdProcess = actualProcess?.name.contains("sshd") ?? false

        guard isPort22 || isSshdProcess else {
            return
        }

        await sessionTracker.recordConnection(
            pid: event.pid,
            startTime: processStartTime,
            remoteAddr: event.remote_addr,
            remotePort: event.remote_port,
            localPort: event.local_port,
            timestamp: event.start_time,
            uid: event.uid,
            containerId: extractContainerId(from: event),
            containerLevel: extractContainerLevel(from: event)
        )
    }

    private func processSshdExecEvent(_ event: EventNormalizer.NormalizedProcess) async {
        guard let processNode = await ProcessCollector.processTree[event.pid] else {
            os_log(.debug, log: self.log,
                   "[SSH_DEBUG] processSshdExecEvent: pid=%lld exe=%{public}s not found in ProcessTree",
                   event.pid, event.exe)
            return
        }

        let startTimeSeconds = processNode.startTime

        let childPids = Array(processNode.childPids)

        _ = await sessionTracker.recordSshdExec(
            pid: event.pid,
            startTime: startTimeSeconds,
            uid: event.uid,
            username: extractUsername(from: event),
            tty: event.tty,
            containerId: extractContainerId(from: event),
            containerLevel: extractContainerLevel(from: event),
            childPids: childPids
        )
    }

    private func processShellExecEvent(_ event: EventNormalizer.NormalizedProcess) async -> EhprobeGenerator.EhprobeSSHLoginEvent? {
        guard let processNode = await ProcessCollector.processTree[event.pid] else {
            return nil
        }

        let basename = (event.exe as NSString).lastPathComponent
        let isSSHSubsystem = basename == "scp" || basename == "sftp-server"
        let hasTTY = !event.tty.isEmpty
        let hasNoArgs = event.args.isEmpty

        if !isSSHSubsystem && !hasTTY && !hasNoArgs {
            os_log(.debug, log: self.log,
                   "[SSH_DEBUG] processShellExecEvent: SKIPPED pid=%lld exe=%{public}s (no tty, has args, not subsystem)",
                   event.pid, event.exe)
            return nil
        }

        let startTimeSeconds = processNode.startTime
        let pendingCount = await sessionTracker.pendingSessionCount

        if pendingCount > 0 {
            os_log(.debug, log: self.log,
                   "[SSH_DEBUG] processShellExecEvent: pid=%lld exe=%{public}s basename=%{public}s ppid=%lld tty=%{public}s pendingSessions=%d",
                   event.pid, event.exe, basename, event.ppid, event.tty, pendingCount)
        }

        let loginEvent = await sessionTracker.recordShellExec(
            pid: event.pid,
            exe: event.exe,
            startTime: startTimeSeconds,
            uid: event.uid,
            username: extractUsername(from: event),
            tty: event.tty,
            containerId: extractContainerId(from: event),
            containerLevel: extractContainerLevel(from: event)
        )

        if let loginEvent = loginEvent {
            os_log(.info, log: self.log, """
                SSH_LOGIN event: \
                session_id = \(loginEvent.sessionId), \
                timestamp = \(loginEvent.timestamp), \
                srcAddr = \(loginEvent.srcAddr), \
                username = \(loginEvent.username), \
                success = \(loginEvent.success), \
                uid = \(loginEvent.uid), \
                pid = \(loginEvent.pid), \
                tty = \(loginEvent.tty), \
                container_id = \(loginEvent.containerId), \
                container_level = \(loginEvent.containerLevel)
                """)
            return loginEvent
        }

        return nil
    }

    private func processExitEvent(_ event: ESClient.ESClientProcExitEvent) async -> EhprobeGenerator.EhprobeSSHLogoutEvent? {

        let pid = Int64(event.pid)

        guard let process = await ProcessCollector.processTree[pid] else {
            return nil
        }

        let startTimeSeconds = process.startTime
        let timestamp = event.timestamp

        let logoutEvent = await sessionTracker.recordExit(
            pid: pid,
            startTime: startTimeSeconds,
            timestamp: timestamp
        )

        if let logoutEvent = logoutEvent {
            os_log(.info, log: self.log, """
                SSH_LOGOUT event: \
                session_id = \(logoutEvent.sessionId), \
                timestamp = \(logoutEvent.timestamp), \
                srcAddr = \(logoutEvent.srcAddr), \
                username = \(logoutEvent.username), \
                uid = \(logoutEvent.uid), \
                pid = \(logoutEvent.pid), \
                sessionDuration = \(String(format: "%.1f", logoutEvent.sessionDuration))s, \
                container_id = \(logoutEvent.containerId), \
                container_level = \(logoutEvent.containerLevel)
                """)
            return logoutEvent
        }

        return nil
    }


    private func extractUsername(from event: EventNormalizer.NormalizedProcess) -> String {
        if let uidName = event.fields["uid_name"],
           case .string(let username) = uidName {
            return username
        }

        for arg in event.args {
            if arg.contains("@") && arg.contains("pts") {
                if let username = arg.split(separator: "@").first.map(String.init) {
                    return username.replacingOccurrences(of: "sshd: ", with: "")
                }
            }
        }

        return "\(event.uid)"
    }

    private func extractContainerId(from event: EventNormalizer.NormalizedProcess) -> UInt64 {
        if let containerIdValue = event.non_normalizable["containerId"],
           case .int(let containerId) = containerIdValue {
            return UInt64(containerId)
        }
        return 0
    }

    private func extractContainerLevel(from event: EventNormalizer.NormalizedProcess) -> UInt32 {
        if let containerLevelValue = event.non_normalizable["containerLevel"],
           case .int(let containerLevel) = containerLevelValue {
            return UInt32(containerLevel)
        }
        return 0
    }

    private func extractContainerId(from event: EventNormalizer.NormalizedNetwork) -> UInt64 {
        if let containerIdValue = event.non_normalizable["containerId"],
           case .int(let containerId) = containerIdValue {
            return UInt64(containerId)
        }
        return 0
    }

    private func extractContainerLevel(from event: EventNormalizer.NormalizedNetwork) -> UInt32 {
        if let containerLevelValue = event.non_normalizable["containerLevel"],
           case .int(let containerLevel) = containerLevelValue {
            return UInt32(containerLevel)
        }
        return 0
    }
}


private actor SSHSessionTracker {
    private let log = EHLog.withCategory(SSHSessionTracker.self)
    private var socketMatcher: SSHSocketMatcher

    private struct SSHSession {
        enum State {
            case awaitingSshd
            case awaitingShell
            case active
        }

        var state: State

        let netTcpPid: Int64
        let netTcpStartTime: Double
        let remoteAddr: String
        let remotePort: UInt16
        let localPort: UInt16
        let timestamp: Double
        var uid: UInt32
        let containerId: UInt64
        let containerLevel: UInt32
        let createdAt: Date

        var sshdSessionPid: Int64?
        var sshdSessionStartTime: Double?
        var sshdSessionMatchedAt: Double?
        var sshdSessionUid: UInt32?

        var shellPid: Int64?
        var shellStartTime: Double?
        var username: String?
        var tty: String?
        var sessionId: String?
    }

    private let pendingSessions: LRUCache<String, SSHSession>
    private let activeSessions: LRUCache<String, SSHSession>

    private let sshdSessionTimeout: TimeInterval
    private let shellTimeout: TimeInterval
    private let activeTimeout: TimeInterval

    private let sessionCompletionBinaries: Set<String> = [
        "bash", "zsh", "ash", "bsh", "csh", "sh", "pdksh", "tclsh", "fish", "tcsh", "ksh", "dash", "scp", "sftp-server"
    ]

    init(
        sshdSessionTimeout: TimeInterval,
        shellTimeout: TimeInterval,
        activeTimeout: TimeInterval,
        maxPending: Int,
        maxSessions: Int,
        socketMatcher: SSHSocketMatcher
    ) {
        self.sshdSessionTimeout = sshdSessionTimeout
        self.shellTimeout = shellTimeout
        self.activeTimeout = activeTimeout
        self.socketMatcher = socketMatcher
        self.pendingSessions = LRUCache(totalCount: maxPending)
        self.activeSessions = LRUCache(totalCount: maxSessions)
    }

    var pendingSessionCount: Int {
        pendingSessions.count
    }

    func setHostProcPath(_ path: String) {
        os_log(.info, log: self.log, "[SSH_DEBUG] setHostProcPath called with path=%{public}s", path)
        self.socketMatcher = ProcSSHSocketMatcher(hostProcPath: path)
    }

    func recordConnection(
        pid: Int64,
        startTime: Double,
        remoteAddr: String,
        remotePort: UInt16,
        localPort: UInt16,
        timestamp: Double,
        uid: UInt32,
        containerId: UInt64,
        containerLevel: UInt32
    ) {
        let normalizedRemoteAddr = Self.normalizeIPAddress(remoteAddr)
        let key = makeSSHKey(remoteAddr: normalizedRemoteAddr, remotePort: remotePort)

        let session = SSHSession(
            state: .awaitingSshd,
            netTcpPid: pid,
            netTcpStartTime: startTime,
            remoteAddr: normalizedRemoteAddr,
            remotePort: remotePort,
            localPort: localPort,
            timestamp: timestamp,
            uid: uid,
            containerId: containerId,
            containerLevel: containerLevel,
            createdAt: Date(),
            sshdSessionPid: nil,
            sshdSessionStartTime: nil,
            sshdSessionMatchedAt: nil,
            sshdSessionUid: nil,
            shellPid: nil,
            shellStartTime: nil,
            username: nil,
            tty: nil,
            sessionId: nil
        )
        pendingSessions[key] = session
        os_log(.debug, log: self.log,
               "[SSH_DEBUG] recordConnection: key=%{public}s pid=%lld remoteAddr=%{public}s (raw=%{public}s) remotePort=%d localPort=%d timestamp=%.3f",
               key, pid, normalizedRemoteAddr, remoteAddr, remotePort, localPort, timestamp)
    }

    func recordSshdExec(
        pid: Int64,
        startTime: Double,
        uid: UInt32,
        username: String,
        tty: String,
        containerId: UInt64,
        containerLevel: UInt32,
        childPids: [Int64] = []
    ) -> Bool {
        var matchedKey: String?
        var matchedSession: SSHSession?

        let pidsToTry = [pid] + childPids

        os_log(.debug, log: self.log,
               "[SSH_DEBUG] recordSshdExec: pid=%lld startTime=%.3f childPids=%{public}s pendingCount=%d",
               pid, startTime, childPids.map { String($0) }.joined(separator: ","), pendingSessions.count)

        for (key, session) in pendingSessions {
            guard session.state == .awaitingSshd else {
                continue
            }

            let timeDiff = startTime - session.timestamp
            guard timeDiff >= 0 && timeDiff <= sshdSessionTimeout else {
                os_log(.debug, log: self.log,
                       "[SSH_DEBUG] recordSshdExec: pid=%lld session key=%{public}s timeout (timeDiff=%.3f, limit=%.1f)",
                       pid, key, timeDiff, sshdSessionTimeout)
                continue
            }

            var endpoint: String?
            for tryPid in pidsToTry {
                if let found = socketMatcher.findSocketEndpoint(forPid: tryPid, localPort: session.localPort) {
                    endpoint = found
                    break
                }
            }

            if let endpoint {
                os_log(.debug, log: self.log,
                       "[SSH_DEBUG] recordSshdExec: pid=%lld endpoint=%{public}s vs key=%{public}s match=%d",
                       pid, endpoint, key, endpoint == key ? 1 : 0)
            } else {
                os_log(.debug, log: self.log,
                       "[SSH_DEBUG] recordSshdExec: pid=%lld no endpoint found for localPort=%d (session key=%{public}s)",
                       pid, session.localPort, key)
            }

            guard let endpoint else {
                continue
            }

            if key == endpoint {
                matchedKey = key
                matchedSession = session
                break
            }
        }

        guard let key = matchedKey, var session = matchedSession else {
            os_log(.debug, log: self.log, "[SSH_DEBUG] recordSshdExec: pid=%lld NO MATCH found", pid)
            return false
        }

        os_log(.debug, log: self.log,
               "[SSH_DEBUG] recordSshdExec: pid=%lld MATCHED key=%{public}s, transitioning to awaitingShell",
               pid, key)

        session.state = .awaitingShell
        session.sshdSessionPid = pid
        session.sshdSessionStartTime = startTime
        session.sshdSessionMatchedAt = startTime
        session.sshdSessionUid = uid
        pendingSessions[key] = session

        return true
    }

    func recordShellExec(
        pid: Int64,
        exe: String,
        startTime: Double,
        uid: UInt32,
        username: String,
        tty: String,
        containerId: UInt64,
        containerLevel: UInt32
    ) async -> EhprobeGenerator.EhprobeSSHLoginEvent? {
        guard isSessionCompletionBinary(exe) else {
            return nil
        }

        os_log(.debug, log: self.log,
               "[SSH_DEBUG] recordShellExec: pid=%lld exe=%{public}s startTime=%.3f pendingCount=%d",
               pid, exe, startTime, pendingSessions.count)

        var matchedKey: String?
        var matchedSession: SSHSession?

        for (key, session) in pendingSessions {
            guard session.state == .awaitingShell else {
                os_log(.debug, log: self.log,
                       "[SSH_DEBUG] recordShellExec: pid=%lld skipping key=%{public}s (state=%{public}s, not awaitingShell)",
                       pid, key, "\(session.state)")
                continue
            }
            guard let sshdPid = session.sshdSessionPid else {
                continue
            }
            guard let sshdStartTime = session.sshdSessionStartTime else {
                continue
            }
            guard let sshdMatchedAt = session.sshdSessionMatchedAt else {
                continue
            }

            let timeDiff = startTime - sshdMatchedAt
            guard timeDiff >= 0 && timeDiff <= shellTimeout else {
                os_log(.debug, log: self.log,
                       "[SSH_DEBUG] recordShellExec: pid=%lld key=%{public}s timeout (timeDiff=%.3f, limit=%.1f)",
                       pid, key, timeDiff, shellTimeout)
                continue
            }

            let isAncestor = await ProcessCollector.processTree.isAncestor(
                ancestorPid: sshdPid,
                ancestorStartTime: sshdStartTime,
                of: pid,
                descendantStartTime: startTime
            )

            os_log(.debug, log: self.log,
                   "[SSH_DEBUG] recordShellExec: pid=%lld key=%{public}s sshdPid=%lld isAncestor=%d",
                   pid, key, sshdPid, isAncestor ? 1 : 0)

            if isAncestor {
                matchedKey = key
                matchedSession = session
                break
            }
        }

        guard let key = matchedKey, var session = matchedSession else {
            os_log(.debug, log: self.log,
                   "[SSH_DEBUG] recordShellExec: pid=%lld exe=%{public}s NO MATCH found",
                   pid, exe)
            return nil
        }

        os_log(.debug, log: self.log,
               "[SSH_DEBUG] recordShellExec: pid=%lld MATCHED key=%{public}s, generating SSH_LOGIN",
               pid, key)

        pendingSessions[key] = nil

        session.state = .active
        session.shellPid = pid
        session.shellStartTime = startTime
        session.username = username
        session.tty = tty
        session.uid = uid
        session.sessionId = "\(pid)"

        let sessionKey = makeSessionKey(pid: pid, startTime: startTime)
        activeSessions[sessionKey] = session

        var loginEvent = EhprobeGenerator.EhprobeSSHLoginEvent()
        loginEvent.timestamp = startTime
        loginEvent.srcAddr = session.remoteAddr
        loginEvent.username = username
        loginEvent.success = true
        loginEvent.uid = uid
        loginEvent.containerId = containerId
        loginEvent.containerLevel = containerLevel
        loginEvent.pid = pid
        loginEvent.tty = tty
        loginEvent.sessionId = "\(pid)"

        return loginEvent
    }

    func recordExit(
        pid: Int64,
        startTime: Double,
        timestamp: Double
    ) -> EhprobeGenerator.EhprobeSSHLogoutEvent? {
        let sessionKey = makeSessionKey(pid: pid, startTime: startTime)

        guard let session = activeSessions[sessionKey] else {
            return nil
        }

        activeSessions[sessionKey] = nil

        var logoutEvent = EhprobeGenerator.EhprobeSSHLogoutEvent()
        logoutEvent.timestamp = timestamp
        logoutEvent.srcAddr = session.remoteAddr
        logoutEvent.username = session.username ?? "\(session.uid)"
        logoutEvent.uid = session.uid
        logoutEvent.containerId = session.containerId
        logoutEvent.containerLevel = session.containerLevel
        logoutEvent.pid = pid
        logoutEvent.sessionDuration = timestamp - (session.shellStartTime ?? session.timestamp)
        logoutEvent.sessionId = session.sessionId ?? "\(pid)"

        return logoutEvent
    }

    func cleanupExpired() {
        let now = Date()
        let nowTimestamp = now.timeIntervalSince1970

        var expiredPending: [String] = []
        for (key, session) in pendingSessions {
            var shouldExpire = false

            switch session.state {
            case .awaitingSshd:
                if now.timeIntervalSince(session.createdAt) > sshdSessionTimeout {
                    shouldExpire = true
                }
            case .awaitingShell:
                if let sshdMatchedAt = session.sshdSessionMatchedAt {
                    let timeSinceMatch = nowTimestamp - sshdMatchedAt
                    if timeSinceMatch > shellTimeout {
                        shouldExpire = true
                    }
                } else {
                    shouldExpire = true
                }
            case .active:
                shouldExpire = true
            }

            if shouldExpire {
                expiredPending.append(key)
            }
        }
        for key in expiredPending {
            pendingSessions[key] = nil
        }

        var expiredSessions: [String] = []
        for (key, session) in activeSessions {
            guard session.state == .active else {
                expiredSessions.append(key)
                continue
            }

            if now.timeIntervalSince(session.createdAt) > activeTimeout {
                expiredSessions.append(key)
            }
        }
        for key in expiredSessions {
            activeSessions[key] = nil
        }
    }


    private func isSessionCompletionBinary(_ exe: String) -> Bool {
        var basename = (exe as NSString).lastPathComponent

        if basename.hasPrefix("-") {
            basename = String(basename.dropFirst())
        }

        return sessionCompletionBinaries.contains(basename)
    }

    private func makeSSHKey(remoteAddr: String, remotePort: UInt16) -> String {
        let normalizedAddr = Self.normalizeIPAddress(remoteAddr)
        return "\(normalizedAddr):\(remotePort)"
    }

    private func makeSessionKey(pid: Int64, startTime: Double) -> String {
        return "\(pid)_\(startTime)"
    }

    static func normalizeIPAddress(_ addr: String) -> String {
        let lowered = addr.lowercased()

        guard lowered.hasPrefix("::ffff:") else {
            return addr
        }

        let suffix = String(addr.dropFirst(7))

        if suffix.contains(".") {
            return suffix
        }

        let hexParts = suffix.split(separator: ":")
        if hexParts.count == 2,
           let high = UInt16(hexParts[0], radix: 16),
           let low = UInt16(hexParts[1], radix: 16) {
            let b1 = high >> 8
            let b2 = high & 0xFF
            let b3 = low >> 8
            let b4 = low & 0xFF
            return "\(b1).\(b2).\(b3).\(b4)"
        }

        return addr
    }
}
#endif
