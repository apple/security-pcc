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
final class LinuxProcessEnumerator: ProcessEnumeratorProvider {
    private let procPath: String

    init(procPath: String = "/proc") {
        self.procPath = procPath
    }

    func enumerateProcesses() -> [EventNormalizer.NormalizedProcess]? {
        guard let procEntries = try? FileManager.default.contentsOfDirectory(atPath: procPath) else {
            return nil
        }

        var processNodes: [EventNormalizer.NormalizedProcess] = []

        for entry in procEntries {
            guard let pid = Int64(entry) else {
                continue
            }

            if let process = getProcessInfo(for: pid) {
                processNodes.append(process)
            }
        }

        return processNodes.isEmpty ? nil : processNodes
    }

    func enumerateLiveProcesses() -> [(pid: Int64, startTime: Double)]? {
        guard let procEntries = try? FileManager.default.contentsOfDirectory(atPath: procPath) else {
            return nil
        }

        let bootTime = getSystemBootTime()
        let clockTicks = Double(sysconf(Int32(_SC_CLK_TCK)))

        var result: [(pid: Int64, startTime: Double)] = []

        for entry in procEntries {
            guard let pid = Int64(entry) else {
                continue
            }

            guard let statInfo = readStatInfo(for: pid) else {
                continue
            }

            let startTime = bootTime + (Double(statInfo.startTime) / clockTicks)
            result.append((pid: pid, startTime: startTime))
        }

        return result.isEmpty ? nil : result
    }

    private func getProcessInfo(for pid: Int64) -> EventNormalizer.NormalizedProcess? {
        let pidPath = "\(procPath)/\(pid)"

        guard FileManager.default.fileExists(atPath: pidPath) else {
            return nil
        }

        guard let statInfo = readStatInfo(for: pid) else {
            return nil
        }

        let startTime = getProcessStartTime(for: pid, statInfo: statInfo)

        let exe = getExecutablePath(for: pid)

        let cwd = getCurrentWorkingDirectory(for: pid)

        let args = getCommandLineArguments(for: pid)

        let tty = Self.getTTYPath(ttyNr: statInfo.ttyNr)

        let p_exe = getExecutablePath(for: statInfo.ppid)

        let (uid, gid) = getUidGid(for: pid)

        return EventNormalizer.NormalizedProcess(
            start_time: startTime,
            cwd: cwd,
            args: args,
            exe: exe,
            tty: tty,
            pid: pid,
            uid: uid,
            gid: gid,
            ppid: statInfo.ppid,
            p_exe: p_exe
        )
    }

    private struct StatInfo {
        let ppid: Int64
        let startTime: UInt64
        let ttyNr: Int32
    }

    private func readStatInfo(for pid: Int64) -> StatInfo? {
        let statPath = "\(procPath)/\(pid)/stat"

        guard let statContent = try? String(contentsOfFile: statPath, encoding: .utf8) else {
            return nil
        }

        let fields = statContent.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")

        guard fields.count >= 22 else {
            return nil
        }

        guard let ppid = Int64(fields[3]),
              let ttyNr = Int32(fields[6]),
              let startTime = UInt64(fields[21]) else {
            return nil
        }

        return StatInfo(ppid: ppid, startTime: startTime, ttyNr: ttyNr)
    }

    private func getProcessStartTime(for pid: Int64, statInfo: StatInfo) -> Double {
        let bootTime = getSystemBootTime()

        let clockTicks = Double(sysconf(Int32(_SC_CLK_TCK)))

        return bootTime + (Double(statInfo.startTime) / clockTicks)
    }

    private func getSystemBootTime() -> Double {
        let statFilePath = "\(procPath)/stat"
        guard let statContent = try? String(contentsOfFile: statFilePath, encoding: .utf8) else {
            return 0.0
        }

        for line in statContent.components(separatedBy: .newlines) where line.hasPrefix("btime ") {
            let components = line.components(separatedBy: " ")
            if components.count >= 2, let bootTime = Double(components[1]) {
                return bootTime
            }
        }

        return 0.0
    }

    private func getExecutablePath(for pid: Int64) -> String {
        let exePath = "\(procPath)/\(pid)/exe"

        do {
            return try FileManager.default.destinationOfSymbolicLink(atPath: exePath)
        } catch {
            return ""
        }
    }

    private func getCurrentWorkingDirectory(for pid: Int64) -> String {
        let cwdPath = "\(procPath)/\(pid)/cwd"

        do {
            return try FileManager.default.destinationOfSymbolicLink(atPath: cwdPath)
        } catch {
            return ""
        }
    }

    private func getCommandLineArguments(for pid: Int64) -> [String] {
        let cmdlinePath = "\(procPath)/\(pid)/cmdline"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cmdlinePath)) else {
            return []
        }

        let bytes = Array(data)
        var args: [String] = []
        var currentArg = Data()

        for byte in bytes {
            if byte == 0 {
                if !currentArg.isEmpty {
                    if let arg = String(data: currentArg, encoding: .utf8) {
                        args.append(arg)
                    }
                    currentArg = Data()
                }
            } else {
                currentArg.append(byte)
            }
        }

        if !currentArg.isEmpty {
            if let arg = String(data: currentArg, encoding: .utf8) {
                args.append(arg)
            }
        }

        return args
    }

    private static func getTTYPath(ttyNr: Int32) -> String {
        guard ttyNr != 0 else {
            return ""
        }

        return "/dev/tty\(ttyNr)"
    }

    private func getUidGid(for pid: Int64) -> (UInt32, UInt32) {
        let statusPath = "\(procPath)/\(pid)/status"

        guard let statusContent = try? String(contentsOfFile: statusPath, encoding: .utf8) else {
            return (0, 0)
        }

        var uid: UInt32 = 0
        var gid: UInt32 = 0

        for line in statusContent.components(separatedBy: .newlines) {
            if line.hasPrefix("Uid:") {
                let components = line.components(separatedBy: .whitespacesAndNewlines)
                if components.count >= 2, let realUid = UInt32(components[1]) {
                    uid = realUid
                }
            } else if line.hasPrefix("Gid:") {
                let components = line.components(separatedBy: .whitespacesAndNewlines)
                if components.count >= 2, let realGid = UInt32(components[1]) {
                    gid = realGid
                }
            }
        }

        return (uid, gid)
    }
}
#endif
