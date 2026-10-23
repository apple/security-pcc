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
import CDispatch
import CoreFoundation
import Crypto
import Foundation

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

public let CLONE_FS: Int32 = 0x00000200
public let CLONE_NEWNS: Int32	= 0x00020000

public protocol ExecAllowlistOperations: Sendable {
    func addFileToExecAllowlist(containerId: UInt64, inode: UInt64, device: UInt32, binaryHash: [UInt8]) -> Int32
    func addFileToScriptAllowlist(containerId: UInt64, inode: UInt64, device: UInt32, scriptHash: [UInt8]) -> Int32
    func removeContainerFromExecAllowlist(containerId: UInt64)
    func removeContainerFromScriptAllowlist(containerId: UInt64)
    func unshareWrapper(flags: Int32) -> Int32
    func setnsWrapper(fd: Int32, nstype: Int32) -> Int32
}

public struct ExecAllowlistController: Sendable {
    static let log = EHLog.withCategory(ExecAllowlistController.self)

    private let operations: ExecAllowlistOperations

    public init(operations: ExecAllowlistOperations) {
        self.operations = operations
    }

    public struct FileId {
        public let inode: UInt64
        public let device: UInt32
    }

    public struct HashedFile {
        public let path: String
        public let sha256Hash: Data
        public let id: FileId
    }

    public enum HostNamespaceAccess: CustomStringConvertible {
        case native
        case pidHost
        case mountedProc(String)
        case mountedNamespace(String)
        case unavailable

        public var description: String {
            switch self {
            case .native: return "native"
            case .pidHost: return "pidHost"
            case .mountedProc(let p): return "mountedProc(\(p))"
            case .mountedNamespace(let p): return "mountedNamespace(\(p))"
            case .unavailable: return "unavailable"
            }
        }
    }

    public static func getFileId(for path: String) -> FileId? {
        var statInfo = stat()
        let result = stat(path, &statInfo)

        guard result == 0 else {
            return nil
        }

        return FileId(inode: UInt64(statInfo.st_ino), device: UInt32(statInfo.st_dev))
    }

    private static func getNamespaceInode(_ path: String) -> UInt64? {
        var statInfo = stat()
        guard stat(path, &statInfo) == 0 else {
            return nil
        }
        return UInt64(statInfo.st_ino)
    }

    public static func detectHostNamespaceAccess(hostProcPath: String?) -> HostNamespaceAccess {
        let fileManager = FileManager.default

        if let hostProc = hostProcPath {
            let nsPath = "\(hostProc)/1/ns/mnt"
            if fileManager.isReadableFile(atPath: nsPath) {
                return .mountedProc(hostProc)
            }
            os_log(.error, log: log, "Specified host_proc path \(hostProc) does not contain readable namespace file")
        }

        if fileManager.isReadableFile(atPath: "/host_mnt_ns") {
            return .mountedNamespace("/host_mnt_ns")
        }
        if fileManager.isReadableFile(atPath: "/host_proc/1/ns/mnt") {
            return .mountedProc("/host_proc")
        }

        guard let selfPidNs = getNamespaceInode("/proc/self/ns/pid"),
              let initPidNs = getNamespaceInode("/proc/1/ns/pid") else {
            return .unavailable
        }

        if selfPidNs == initPidNs {
            guard let selfMntNs = getNamespaceInode("/proc/self/ns/mnt"),
                  let initMntNs = getNamespaceInode("/proc/1/ns/mnt") else {
                return .unavailable
            }

            if selfMntNs == initMntNs {
                return .native
            } else {
                return .pidHost
            }
        }

        return .unavailable
    }

    public static func getHash(for path: String) -> HashedFile? {
        let fileURL = URL(fileURLWithPath: path)

        guard let fileData = try? Data(contentsOf: fileURL) else {
            return nil
        }

        let digest = SHA256.hash(data: fileData)
        let hashData = Data(digest)

        guard let fileId = getFileId(for: path) else {
            return nil
        }

        return HashedFile(path: path, sha256Hash: hashData, id: fileId)
    }

    public static func isExecutable(at path: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: path)
    }

    public static func isSymbolicLink(at path: String) -> Bool {
        let fileManager = FileManager.default
        do {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            let fileType = attributes[.type] as? FileAttributeType
            return fileType == .typeSymbolicLink
        } catch {
            return false
        }
    }

    public static func enumerateExecutables(in path: String) -> [String] {
        let fileManager = FileManager.default
        var executables: [String] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            os_log(.error, log: log, "Could not create enumerator for directory: \(path)")
            return []
        }

        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isFolder), !isFolder.boolValue else {
                continue
            }

            if isSymbolicLink(at: fullPath) {
                continue
            }

            if isExecutable(at: fullPath) {
                executables.append(fullPath)
            }
        }

        return executables
    }

    public static func validateContainerProcess(pid: Int64) -> Bool {
        let procPath = "/proc/\(pid)"
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: procPath) else {
            return false
        }

        let mntNsPath = "\(procPath)/ns/mnt"
        guard fileManager.isReadableFile(atPath: mntNsPath) else {
            return false
        }

        return true
    }

    public func enterContainerNamespace(containerPid: Int64) -> Int32 {
        let currentNsPath = "/proc/self/ns/mnt"
        let currentNsFd = open(currentNsPath, O_RDONLY)
        guard currentNsFd >= 0 else {
            return -1
        }

        let containerNsPath = "/proc/\(containerPid)/ns/mnt"
        let containerNsFd = open(containerNsPath, O_RDONLY)
        guard containerNsFd >= 0 else {
            close(currentNsFd)
            return -1
        }

        let unshareResult = operations.unshareWrapper(flags: CLONE_FS)
        guard unshareResult == 0 else {
            close(currentNsFd)
            return -1
        }

        let setnsResult = operations.setnsWrapper(fd: containerNsFd, nstype: CLONE_NEWNS)
        close(containerNsFd)
        guard setnsResult == 0 else {
            close(currentNsFd)
            return -1
        }

        return currentNsFd
    }

    private func enterNamespace(path: String) -> Int32 {
        let currentNsFd = open("/proc/self/ns/mnt", O_RDONLY)
        guard currentNsFd >= 0 else {
            return -1
        }

        let targetNsFd = open(path, O_RDONLY)
        guard targetNsFd >= 0 else {
            close(currentNsFd)
            return -1
        }

        let unshareResult = operations.unshareWrapper(flags: CLONE_FS)
        guard unshareResult == 0 else {
            close(targetNsFd)
            close(currentNsFd)
            return -1
        }

        let setnsResult = operations.setnsWrapper(fd: targetNsFd, nstype: CLONE_NEWNS)
        close(targetNsFd)

        guard setnsResult == 0 else {
            close(currentNsFd)
            return -1
        }

        return currentNsFd
    }

    public func enterHostNamespace(access: HostNamespaceAccess) -> Int32 {
        let nsPath: String

        switch access {
        case .native:
            return -2

        case .pidHost:
            nsPath = "/proc/1/ns/mnt"

        case .mountedProc(let hostProc):
            nsPath = "\(hostProc)/1/ns/mnt"

        case .mountedNamespace(let path):
            nsPath = path

        case .unavailable:
            return -1
        }

        return enterNamespace(path: nsPath)
    }

    public func restoreOriginalNamespace(originalNsFd: Int32) {
        let restoreResult = operations.setnsWrapper(fd: originalNsFd, nstype: CLONE_NEWNS)
        close(originalNsFd)

        if restoreResult != 0 {
            os_log(.error, log: Self.log, "Failed to restore original namespace. errno: \(errno)")
        }
    }

    public func populateAllowlist(
        containerId: UInt64,
        containerPid: Int64,
        allowlistFolders: [String],
        hostAccess: HostNamespaceAccess = .native
    ) -> Bool {
        os_log(.info, log: Self.log, "Populating execution allowlist for container ID: \(containerId)")

        var originalNsFd: Int32 = -1
        defer {
            if originalNsFd >= 0 {
                restoreOriginalNamespace(originalNsFd: originalNsFd)
                os_log(.debug, log: Self.log, "Restored original namespace for container ID: \(containerId)")
            }
        }

        if containerId == 0 {
            switch hostAccess {
            case .native:
                os_log(.debug, log: Self.log, "Running natively on host, no namespace switch needed")
            case .unavailable:
                os_log(.info, log: Self.log, "Host namespace access unavailable, enumerating local filesystem")

            default:
                originalNsFd = enterHostNamespace(access: hostAccess)
                guard originalNsFd >= 0 else {
                    os_log(.error, log: Self.log, "Failed to enter host namespace via \(hostAccess)")
                    return false
                }
                os_log(.debug, log: Self.log, "Successfully entered host namespace via \(hostAccess)")
            }
        } else {
            guard Self.validateContainerProcess(pid: containerPid) else {
                os_log(.error, log: Self.log, "Unable to validate container process, ID: \(containerId), PID: \(containerPid)")
                return false
            }

            originalNsFd = enterContainerNamespace(containerPid: containerPid)
            guard originalNsFd >= 0 else {
                os_log(.error, log: Self.log, "Unable to enter container namepsace, ID: \(containerId), PID: \(containerPid)")
                return false
            }

            os_log(.debug, log: Self.log, "Successfully entered container namespace, container ID: \(containerId)")
        }

        var totalProcessed = 0
        var totalSuccessful = 0
        var totalErrors = 0
        var totalSymlinks = 0

        for folder in allowlistFolders {
            os_log(.debug, log: Self.log, "Processing folder: \(folder), container ID: \(containerId)")

            let fileManager = FileManager.default
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
                os_log(.debug, log: Self.log, "Folder does not exist: \(folder)")
                continue
            }

            var allFiles: [String] = []
            var symlinksCount = 0

            if let enumerator = fileManager.enumerator(atPath: folder) {
                while let relativePath = enumerator.nextObject() as? String {
                    let fullPath = folder.appendingPathComponent(relativePath)

                    isFolder = false
                    guard fileManager.fileExists(atPath: fullPath, isDirectory: &isFolder), !isFolder.boolValue else {
                        continue
                    }

                    allFiles.append(fullPath)
                    if Self.isSymbolicLink(at: fullPath) {
                        symlinksCount += 1
                    }
                }
            }

            totalSymlinks += symlinksCount
            os_log(.debug, log: Self.log, "Found \(allFiles.count) total files, \(symlinksCount) symbolic links (will be skipped)")

            let executables = Self.enumerateExecutables(in: folder)
            os_log(.debug, log: Self.log, "Found \(executables.count) executable files (excluding symbolic links)")

            for executable in executables {
                totalProcessed += 1

                guard let file = Self.getHash(for: executable) else {
                    os_log(.error, log: Self.log, "Unable to calculate file hash for \(executable)")
                    totalErrors += 1
                    continue
                }

                let hashBytes = [UInt8](file.sha256Hash)
                let result = operations.addFileToExecAllowlist(
                    containerId: containerId,
                    inode: UInt64(file.id.inode),
                    device: file.id.device,
                    binaryHash: hashBytes
                )

                if result != 0 {
                    os_log(.error, log: Self.log,
                        "Failed to add \(executable) (ino:\(file.id.inode), dev:\(file.id.device)) to allowlist: \(result)")
                    totalErrors += 1
                } else {
                    totalSuccessful += 1
                }
            }
        }

        os_log(.info, log: Self.log, """
            Allowlist population summary - \
            Container ID: \(containerId), \
            Total processed: \(totalProcessed), \
            Successfully added: \(totalSuccessful), \
            Errors: \(totalErrors), Symlinks skipped: \(totalSymlinks)
            """)

        return totalSuccessful > 0
    }

    public func removeContainerAllowlist(containerId: UInt64) {
        operations.removeContainerFromExecAllowlist(containerId: containerId)
    }

    public func removeContainerScriptAllowlist(containerId: UInt64) {
        operations.removeContainerFromScriptAllowlist(containerId: containerId)
    }

    public static func enumerateScripts(in path: String) -> [String] {
        let fileManager = FileManager.default
        var scripts: [String] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            os_log(.error, log: log, "Could not create enumerator for directory: \(path)")
            return []
        }

        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isFolder), !isFolder.boolValue else {
                continue
            }

            if isSymbolicLink(at: fullPath) {
                continue
            }

            if fullPath.hasSuffix(".py") || fullPath.hasSuffix(".pyc") {
                scripts.append(fullPath)
            }
        }

        return scripts
    }

    public func populateScriptAllowlist(
        containerId: UInt64,
        containerPid: Int64,
        scriptFolders: [String],
        hostAccess: HostNamespaceAccess = .native
    ) -> Bool {
        os_log(.info, log: Self.log, "Populating script allowlist for container ID: \(containerId)")

        var originalNsFd: Int32 = -1
        defer {
            if originalNsFd >= 0 {
                restoreOriginalNamespace(originalNsFd: originalNsFd)
            }
        }

        if containerId == 0 {
            switch hostAccess {
            case .native:
                break
            case .unavailable:
                os_log(.info, log: Self.log, "Host namespace access unavailable for script allowlist, enumerating local filesystem")
            default:
                originalNsFd = enterHostNamespace(access: hostAccess)
                guard originalNsFd >= 0 else {
                    os_log(.error, log: Self.log, "Failed to enter host namespace for script allowlist via \(hostAccess)")
                    return false
                }
            }
        } else {
            guard Self.validateContainerProcess(pid: containerPid) else {
                os_log(.error, log: Self.log, "Unable to validate container process for script allowlist, ID: \(containerId), PID: \(containerPid)")
                return false
            }

            originalNsFd = enterContainerNamespace(containerPid: containerPid)
            guard originalNsFd >= 0 else {
                os_log(.error, log: Self.log, "Unable to enter container namespace for script allowlist, ID: \(containerId), PID: \(containerPid)")
                return false
            }
        }

        var totalProcessed = 0
        var totalSuccessful = 0
        var totalErrors = 0

        for folder in scriptFolders {
            os_log(.debug, log: Self.log, "Processing script folder: \(folder), container ID: \(containerId)")

            let fileManager = FileManager.default
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
                os_log(.debug, log: Self.log, "Script folder does not exist: \(folder)")
                continue
            }

            let scripts = Self.enumerateScripts(in: folder)
            os_log(.debug, log: Self.log, "Found \(scripts.count) script files in \(folder)")

            for script in scripts {
                totalProcessed += 1

                guard let file = Self.getHash(for: script) else {
                    os_log(.error, log: Self.log, "Unable to calculate file hash for script \(script)")
                    totalErrors += 1
                    continue
                }

                let hashBytes = [UInt8](file.sha256Hash)
                let result = operations.addFileToScriptAllowlist(
                    containerId: containerId,
                    inode: UInt64(file.id.inode),
                    device: file.id.device,
                    scriptHash: hashBytes
                )

                if result != 0 {
                    os_log(.error, log: Self.log,
                        "Failed to add script \(script) (ino:\(file.id.inode), dev:\(file.id.device)) to allowlist: \(result)")
                    totalErrors += 1
                } else {
                    totalSuccessful += 1
                }
            }
        }

        os_log(.info, log: Self.log, """
            Script allowlist population summary - \
            Container ID: \(containerId), \
            Total processed: \(totalProcessed), \
            Successfully added: \(totalSuccessful), \
            Errors: \(totalErrors)
            """)

        return totalSuccessful > 0
    }
}
#endif
