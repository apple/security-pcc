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


#if !os(Linux)
import Clibproc
import Foundation

final class LibprocProcessEnumerator: ProcessEnumeratorProvider {
    func enumerateProcesses() -> [EventNormalizer.NormalizedProcess]? {
        let pidListSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard pidListSize > 0 else {
            return nil
        }

        let pidCount = pidListSize / Int32(MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: Int(pidCount))

        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, pidListSize)
        guard actualSize > 0 else {
            return nil
        }

        let actualCount = actualSize / Int32(MemoryLayout<pid_t>.size)
        var processNodes: [EventNormalizer.NormalizedProcess] = []

        for i in 0..<Int(actualCount) {
            let pid = pids[i]
            if pid <= 0 {
                continue
            }

            if let node = Self.getProcessInfo(for: pid) {
                processNodes.append(node)
            }
        }
        return processNodes
    }

    func enumerateLiveProcesses() -> [(pid: Int64, startTime: Double)]? {
        let pidListSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard pidListSize > 0 else {
            return nil
        }

        let pidCount = pidListSize / Int32(MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: Int(pidCount))

        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, pidListSize)
        guard actualSize > 0 else {
            return nil
        }

        let actualCount = Int(actualSize / Int32(MemoryLayout<pid_t>.size))
        var result: [(pid: Int64, startTime: Double)] = []
        result.reserveCapacity(actualCount)

        var bsdInfo = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)

        for i in 0..<actualCount {
            let pid = pids[i]
            if pid <= 0 {
                continue
            }

            let infoSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, expectedSize)
            guard infoSize == expectedSize else {
                continue
            }

            let startTime = Double(bsdInfo.pbi_start_tvsec) + Double(bsdInfo.pbi_start_tvusec) / 1_000_000.0
            result.append((pid: Int64(pid), startTime: startTime))
        }

        return result
    }

    private static func getProcessInfo(for pid: pid_t) -> EventNormalizer.NormalizedProcess? {
        var bsdInfo = proc_bsdinfo()
        let bsdInfoSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard bsdInfoSize == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            return nil
        }

        var taskInfo = proc_taskinfo()
        let taskInfoSize = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
        guard taskInfoSize == Int32(MemoryLayout<proc_taskinfo>.size) else {
            return nil
        }

        let startTime = Double(bsdInfo.pbi_start_tvsec) + Double(bsdInfo.pbi_start_tvusec) / 1_000_000.0

        let gid = bsdInfo.pbi_gid
        let uid = bsdInfo.pbi_uid

        let exe = getExecutablePath(for: pid)

        let cwd = getCurrentWorkingDirectory(for: pid)

        let args = getCommandLineArguments(for: pid)

        let tty = getTTYPath(for: pid)

        let p_exe = getExecutablePath(for: pid_t(bsdInfo.pbi_ppid))

        return EventNormalizer.NormalizedProcess(
            start_time: startTime,
            cwd: cwd,
            args: args,
            exe: exe,
            tty: tty,
            pid: Int64(pid),
            uid: uid,
            gid: gid,
            ppid: Int64(bsdInfo.pbi_ppid),
            p_exe: p_exe
        )
    }

    private static func getExecutablePath(for pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
        guard result > 0 else {
            return ""
        }

        return String(cString: pathBuffer)
    }

    private static func getCurrentWorkingDirectory(for pid: pid_t) -> String {
        var vnodeInfo = proc_vnodepathinfo()
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard result == Int32(MemoryLayout<proc_vnodepathinfo>.size) else {
            return ""
        }

        return String(cBuffer: vnodeInfo.pvi_cdir.vip_path)
    }

    private static func getCommandLineArguments(for pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0

        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 && size > 0 else {
            return []
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return []
        }

        var args: [String] = []
        var offset = MemoryLayout<Int32>.size

        while offset < size && buffer[offset] != 0 {
            offset += 1
        }
        offset += 1

        while offset < size && buffer[offset] == 0 {
            offset += 1
        }

        while offset < size {
            let start = offset
            while offset < size && buffer[offset] != 0 {
                offset += 1
            }
            if offset > start {
                let arg = buffer[start..<offset].withUnsafeBufferPointer { buf in
                    String(bytes: buf, encoding: .utf8) ?? ""
                }
                if !arg.isEmpty {
                    args.append(arg)
                }
            }
            offset += 1

            if offset >= size || buffer[offset] == 0 {
                break
            }
        }

        return args
    }

    private static func getTTYPath(for pid: pid_t) -> String {
        var bsdInfo = proc_bsdinfo()
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size))

        guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            return ""
        }

        let ttyDev = bsdInfo.e_tdev

        guard ttyDev != UInt32.max else {
            return ""
        }

        return "/dev/tty\(ttyDev)"
    }
}

#endif
