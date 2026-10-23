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

import Dispatch
import Foundation

#if os(Linux)
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import Synchronization

public class AuditLogGenerator: EHGenerator {
    public enum AuditLogGeneratorError: Error {
        case platformUnsupported
    }

    public struct Config: Sendable {
        public var auditLogPath: String
        public var pollTimeoutMs: Int32

        public init(auditLogPath: String = "/var/log/audit/audit.log", pollTimeoutMs: Int32 = 100) {
            self.auditLogPath = auditLogPath
            self.pollTimeoutMs = pollTimeoutMs
        }
    }

    static let log = EHLog.withCategory(AuditLogGenerator.self)

    private let config: Config
    private let pollQueue = DispatchQueue(label: "com.apple.eventhorizon.auditlog.poll")
    private let stopFlag = StopFlag()

    final class StopFlag: Sendable {
        private let value = Atomic<Bool>(false)
        var isStopped: Bool { value.load(ordering: .relaxed) }
        func stop() { value.store(true, ordering: .relaxed) }
        func reset() { value.store(false, ordering: .relaxed) }
    }

    public init(config: Config = Config()) {
        self.config = config
    }

    public func configure(_ pipeline: EHPipeline) throws {
        Self.log.log(.debug, "Configuring AuditLogGenerator for \(config.auditLogPath)")
    }

    public func start(_ pipeline: EHPipeline) throws {
        guard FileManager.default.fileExists(atPath: config.auditLogPath) else {
            Self.log.log(.info, "Audit log not found at \(config.auditLogPath), skipping")
            return
        }

        Self.log.log(.info, "Starting AuditLogGenerator for \(config.auditLogPath)")
        let auditLogPath = config.auditLogPath
        let pollTimeoutMs = config.pollTimeoutMs

        stopFlag.reset()
        let flag = stopFlag
        pollQueue.async {
            Self.pollLoop(
                pipeline: pipeline,
                auditLogPath: auditLogPath,
                pollTimeoutMs: pollTimeoutMs,
                stopFlag: flag
            )
        }
    }

    public func stop() throws {
        stopFlag.stop()
    }


    private static func pollLoop(
        pipeline: EHPipeline,
        auditLogPath: String,
        pollTimeoutMs: Int32,
        stopFlag: StopFlag
    ) {
        let inotifyFd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard inotifyFd >= 0 else {
            log.log(.error, "Failed to initialize inotify: \(String(cString: strerror(errno)))")
            return
        }
        defer { close(inotifyFd) }

        guard var state = openAndWatch(inotifyFd: inotifyFd, path: auditLogPath) else {
            return
        }

        var eventBuffer = [UInt8](repeating: 0, count: 4096)

        while !stopFlag.isStopped {
            var pfd = pollfd(fd: inotifyFd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pfd, 1, pollTimeoutMs)

            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                log.log(.error, "poll() failed: \(String(cString: strerror(errno)))")
                break
            }

            if pollResult == 0 {
                continue
            }

            var needsReopen = false
            let inotifyBytesRead = eventBuffer.withUnsafeMutableBufferPointer { buf in
                read(inotifyFd, buf.baseAddress!, buf.count)
            }

            if inotifyBytesRead > 0 {
                var offset = 0
                while offset < inotifyBytesRead {
                    let event = eventBuffer.withUnsafeBufferPointer { buf in
                        buf.baseAddress!.advanced(by: offset)
                            .withMemoryRebound(to: inotify_event.self, capacity: 1) { $0.pointee }
                    }
                    let eventSize = MemoryLayout<inotify_event>.size + Int(event.len)
                    offset += eventSize

                    if event.mask & UInt32(IN_MOVE_SELF) != 0 || event.mask & UInt32(IN_DELETE_SELF) != 0 {
                        needsReopen = true
                    }
                }
            }

            let events = readNewLines(fd: state.fd, buffer: &state.lineBuffer)
            for event in events {
                Self.log.log(.info, """
                    AUDIT_DENIAL event: \
                    source = \(event.source), \
                    action = \(event.action), \
                    pid = \(event.pid), \
                    comm = \(event.comm), \
                    path = \(event.path), \
                    policyContext = \(event.policyContext), \
                    targetClass = \(event.targetClass), \
                    permissive = \(event.permissive), \
                    profile = \(event.profile), \
                    exe = \(event.exe)
                    """)
                Task { await pipeline.process(event) }
            }

            if needsReopen {
                log.log(.info, "Audit log rotated, reopening")
                close(state.fd)
                inotify_rm_watch(inotifyFd, state.watchDescriptor)

                Thread.sleep(forTimeInterval: 0.5)

                guard let newState = openAndWatch(inotifyFd: inotifyFd, path: auditLogPath) else {
                    log.log(.error, "Failed to reopen audit log after rotation")
                    state.fd = -1
                    state.watchDescriptor = -1
                    break
                }
                state = newState
            }
        }

        if state.fd >= 0 {
            close(state.fd)
        }
        if state.watchDescriptor >= 0 {
            inotify_rm_watch(inotifyFd, state.watchDescriptor)
        }
    }

    private struct WatchState {
        var fd: Int32
        var watchDescriptor: Int32
        var lineBuffer: String
    }

    private static func openAndWatch(inotifyFd: Int32, path: String) -> WatchState? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            log.log(.error, "Failed to open \(path): \(String(cString: strerror(errno)))")
            return nil
        }

        lseek(fd, 0, SEEK_END)

        let wd = inotify_add_watch(
            inotifyFd,
            path,
            UInt32(IN_MODIFY | IN_MOVE_SELF | IN_DELETE_SELF)
        )
        guard wd >= 0 else {
            log.log(.error, "Failed to add inotify watch for \(path): \(String(cString: strerror(errno)))")
            close(fd)
            return nil
        }

        return WatchState(fd: fd, watchDescriptor: wd, lineBuffer: "")
    }

    private static func readNewLines(fd: Int32, buffer: inout String) -> [AuditDenialEvent] {
        var events: [AuditDenialEvent] = []
        var readBuffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let bytesRead = readBuffer.withUnsafeMutableBufferPointer { buf in
                read(fd, buf.baseAddress!, buf.count)
            }

            if bytesRead <= 0 {
                break
            }

            if let chunk = String(bytes: readBuffer[..<bytesRead], encoding: .utf8) {
                buffer += chunk
            }
        }

        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])

            if let event = parseLine(line) {
                events.append(event)
            }
        }

        return events
    }


    static func parseLine(_ line: String) -> AuditDenialEvent? {
        if line.contains("type=AVC") && line.contains("avc:  denied") {
            return parseSELinuxDenial(line)
        }
        if line.contains("type=AVC") && line.contains("apparmor=") {
            return parseAppArmorDenial(line)
        }
        return nil
    }

    static func parseSELinuxDenial(_ line: String) -> AuditDenialEvent? {
        let (timestamp, serial) = extractAuditTimestamp(line)

        let action: String
        if let braceStart = line.range(of: "{ "),
           let braceEnd = line.range(of: " }", range: braceStart.upperBound..<line.endIndex) {
            action = String(line[braceStart.upperBound..<braceEnd.lowerBound])
        } else {
            action = "denied"
        }

        let pid = extractField(line, key: "pid").flatMap { Int64($0) } ?? 0
        let comm = extractQuotedField(line, key: "comm") ?? extractField(line, key: "comm") ?? ""
        let path = extractQuotedField(line, key: "path") ?? extractField(line, key: "path") ?? ""
        let scontext = extractField(line, key: "scontext") ?? ""
        let tclass = extractField(line, key: "tclass") ?? ""
        let permissiveStr = extractField(line, key: "permissive") ?? "0"
        let exe = extractQuotedField(line, key: "exe") ?? extractField(line, key: "exe") ?? ""

        return AuditDenialEvent(
            timestamp: timestamp,
            serial: serial,
            source: "selinux",
            action: action,
            pid: pid,
            comm: comm,
            path: path,
            policyContext: scontext,
            targetClass: tclass,
            permissive: permissiveStr == "1",
            exe: exe,
            rawMessage: line
        )
    }

    static func parseAppArmorDenial(_ line: String) -> AuditDenialEvent? {
        let apparmorStatus = extractQuotedField(line, key: "apparmor") ?? ""
        guard apparmorStatus == "DENIED" || apparmorStatus == "AUDIT" else {
            return nil
        }

        let (timestamp, serial) = extractAuditTimestamp(line)
        let operation = extractQuotedField(line, key: "operation") ?? ""
        let profile = extractQuotedField(line, key: "profile") ?? ""
        let name = extractQuotedField(line, key: "name") ?? ""
        let pid = extractField(line, key: "pid").flatMap { Int64($0) } ?? 0
        let comm = extractQuotedField(line, key: "comm") ?? extractField(line, key: "comm") ?? ""
        let requestedMask = extractQuotedField(line, key: "requested_mask") ?? ""
        let deniedMask = extractQuotedField(line, key: "denied_mask") ?? ""

        return AuditDenialEvent(
            timestamp: timestamp,
            serial: serial,
            source: "apparmor",
            action: operation,
            pid: pid,
            comm: comm,
            path: name,
            permissive: apparmorStatus == "AUDIT",
            requestedMask: requestedMask,
            deniedMask: deniedMask,
            profile: profile,
            rawMessage: line
        )
    }


    static func extractAuditTimestamp(_ line: String) -> (Double, Int64) {
        guard let auditStart = line.range(of: "msg=audit("),
              let auditEnd = line.range(of: ")", range: auditStart.upperBound..<line.endIndex)
        else {
            return (0, 0)
        }

        let content = line[auditStart.upperBound..<auditEnd.lowerBound]
        let parts = content.split(separator: ":")
        let timestamp = parts.first.flatMap { Double($0) } ?? 0
        let serial = parts.count > 1 ? (Int64(parts[1]) ?? 0) : 0
        return (timestamp, serial)
    }

    static func extractField(_ line: String, key: String) -> String? {
        let searchKey = key + "="
        guard let range = line.range(of: searchKey) else {
            return nil
        }

        let valueStart = range.upperBound
        let valueEnd: String.Index
        if let spaceIndex = line[valueStart...].firstIndex(of: " ") {
            valueEnd = spaceIndex
        } else {
            valueEnd = line.endIndex
        }

        let value = String(line[valueStart..<valueEnd])
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    static func extractQuotedField(_ line: String, key: String) -> String? {
        let searchKey = key + "=\""
        guard let range = line.range(of: searchKey) else {
            return nil
        }

        let valueStart = range.upperBound
        guard let quoteEnd = line[valueStart...].firstIndex(of: "\"") else {
            return nil
        }

        return String(line[valueStart..<quoteEnd])
    }
}

#else

public class AuditLogGenerator: EHGenerator {
    public enum AuditLogGeneratorError: Error {
        case platformUnsupported
    }

    public init() {}

    public func configure(_ pipeline: EHPipeline) throws {
        throw AuditLogGeneratorError.platformUnsupported
    }

    public func start(_ pipeline: EHPipeline) throws {
        throw AuditLogGeneratorError.platformUnsupported
    }

    public func stop() throws {
        throw AuditLogGeneratorError.platformUnsupported
    }
}

#endif
