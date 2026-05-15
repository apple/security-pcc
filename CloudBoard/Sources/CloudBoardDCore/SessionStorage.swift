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

import CloudBoardLogging
import Foundation
import NIOCore
import os
import Synchronization
import struct SystemPackage.FileDescriptor
import struct SystemPackage.FilePermissions

enum RecoveredSessionState: Hashable {
    case success(Set<SessionKey>)
    case failed
}

protocol SessionStorage {
    /// Stores the given session entry.
    func storeSession(_ sessionEntry: SessionEntry)
    /// Removes sessions keys of the given node key.
    func removeSessions(of expiredNodeKeyID: NodeKeyID)
    /// Restores session keys for the given valid node keys. Also cleans up session keys of node keys not on
    /// the valid keys list.
    /// ALL input keyIDs will have an entry in the resulting dictionary
    /// If a session was _present_ but could not be loaded then it will be indicated by
    /// ``RecoveredSessionState.failed`` in that case any that key should be revoked,
    /// This may be all such keys if there is a serious failure.
    /// if a key has no session (and the implementation is confident this is reasonable) then
    /// it will be indicated with a success, but where the session set is empty
    func restoreSessions(validNodeKeyIDs: [NodeKeyID]) -> [NodeKeyID: RecoveredSessionState]
}

/// Note for logging:
/// Because this class controls the files names it uses, and is only passed ``SessionEntry``
/// (based on public info) and ``NodeKeyID`` public info it is free to log all such
/// information as public.
/// It is *not* free to do this for files during _recovery_ as files in that directory could
/// be inserted by some other process/system and then (on failing parsing) be logged out
///
/// Currently files deemed 'corrupt' will be retained indefinitely. This makes (non customer)
/// analysis of failure modes simpler. The use of disk is negligible. We will introduce
/// removal of older files in the near future
final class OnDiskSessionStorage: SessionStorage {
    enum OnDiskSessionStorageError: ReportableError {
        var publicDescription: String {
            switch self {
            case .failedToCreateFile:
                return "Failed to create sessions file directory"
            case .fileReadError:
                return "Failed to read sessions file"
            case .unableToEnumerateDirectory:
                return "Failed to enumerate sessions file directory"
            case .unableToLockSessionFile:
                return "Unable to lock the session directory"
            case .unableToLockProcess:
                return "Unable to lock the session in process"
            }
        }

        case failedToCreateFile
        case fileReadError
        case unableToEnumerateDirectory
        case unableToLockSessionFile
        case unableToLockProcess
    }

    private static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: OnDiskSessionStorage.self)
    )

    enum FileStatus: String, RawRepresentable {
        /// The file is either good, and being written to (post startup),
        /// or _was_ good and we need to reload it (on restart)
        case active
        /// Ignore the file contents, but consider the key it is for to be unusable
        case corrupt
        /// a previously active file is moved to validating once and only once (during restore).
        /// If it validates then it becomes active.
        /// if it fails validation it becomes corrupt
        /// if we crash/exit during a validating phase then on restart we change it to corrupt
        case validating
    }

    private let fileManager = FileManager.default
    private let fileDirectory: URL
    private let fileHandles: Mutex<[NodeKeyID: FileHandle]>

    // just to trap screw ups where two instances are pointing at the same directory
    private let sessionLockPath: String
    private let lockFileDescriptor: FileDescriptor
    private static let processLocks = Mutex<Set<String>>([])

    init(fileDirectory: URL) throws {
        self.fileDirectory = fileDirectory
        Self.logger.info("Ensuring sessions file directory available at \(fileDirectory.path, privacy: .public)")
        do {
            try FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error(
                "Failed to create sessions file directory: \(String(unredacted: error), privacy: .public)"
            )
            throw error
        }
        self.fileHandles = .init([:])
        let sessionLockPath = fileDirectory.appendingPathComponent("session.lock").path()
        self.sessionLockPath = sessionLockPath
        Self.logger.notice("Attempt to lock \(self.sessionLockPath, privacy: .public)")
        // Multiple processes trying to use the same directory causes horrible to understand issues
        // Multiple 'fake' processes in the internal integration tests makes that even worse
        // We protect against both by taking a process wide lock...
        try Self.processLocks.withLock { locks in
            guard !locks.contains(sessionLockPath) else {
                Self.logger.error("\(sessionLockPath, privacy: .public) process lock already exists")
                throw OnDiskSessionStorageError.unableToLockProcess
            }
            locks.insert(sessionLockPath)
        }
        // and a file lock
        do {
            // SwiftNIO FileDescriptor shadows the one we want
            self.lockFileDescriptor = try SystemPackage.FileDescriptor.open(
                self.sessionLockPath,
                FileDescriptor.AccessMode.readWrite,
                options: [FileDescriptor.OpenOptions.create, FileDescriptor.OpenOptions.exclusiveLock],
                permissions: FilePermissions.ownerReadWrite
            )
        } catch {
            Self.logger
                .error(
                    "\(sessionLockPath, privacy: .public) file already exists and is locked \(error, privacy: .public)"
                )
            Self.processLocks.withLock { locks in
                _ = locks.remove(sessionLockPath)
            }
            throw OnDiskSessionStorageError.unableToLockSessionFile
        }
    }

    // We rely on this directory and naming convention for recovery:
    // <self.fileDirectory>/<NodeKeyIDAsName>.<FileStatus>
    // Where NodeKeyIDAsName is the NodeKeyID via encodeKeyID
    // FileStatus is encoded as the extension
    // anything not conforming to this form is simply ignored
    // These semantics are exposed only so tests can interact with the system

    internal func encodeKeyID(keyID: NodeKeyID) -> String {
        return keyID.base64EncodedString().replacingOccurrences(of: "/", with: "_")
    }

    internal func decodeKeyID(encoded: String) -> NodeKeyID? {
        return Data(base64Encoded: encoded.replacingOccurrences(of: "_", with: "/"))
    }

    private func parseFileName(fileURL: URL) -> (keyID: NodeKeyID, status: FileStatus)? {
        let ext = fileURL.pathExtension
        let fileNameWithoutExtension = fileURL.deletingPathExtension().lastPathComponent
        guard let keyID = self.decodeKeyID(encoded: fileNameWithoutExtension) else {
            return nil
        }
        guard let status = FileStatus(rawValue: ext) else {
            // If we don't understand the status treat as corrupt
            // this parsing happens on files outside of our control so this must restrict visibility
            Self.logger
                .error(
                    "session file \(fileURL.path(), privacy: .private) has unknown status \(ext, privacy: .private) - treating as corrupt"
                )
            return (keyID: keyID, status: .corrupt)
        }
        return (keyID: keyID, status: status)
    }

    private enum RestoreAction: String, RawRepresentable {
        case knownToBeCorrupt
        case markAsCorrupt
        case validate
        case cleanRemove
    }

    private func markAsCorrupted(fileURL: URL, logFileName: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path()) else {
            return
        }
        do {
            let renamed = fileURL.deletingPathExtension().appendingPathExtension(FileStatus.corrupt.rawValue)
            if logFileName {
                Self.logger
                    .notice(
                        "Invalidating sessions file \(fileURL.path(), privacy: .public) by renaming to \(renamed.path(), privacy: .public)"
                    )
            } else {
                Self.logger
                    .notice(
                        "Invalidating sessions file \(fileURL.path(), privacy: .private) by renaming to \(renamed.path(), privacy: .private)"
                    )
            }
            try FileManager.default.moveItem(at: fileURL, to: renamed)
        } catch {
            // We swallow this because:
            // - If we crashed we might just crashloop.
            // - We've correctly identified the file is bad, so we will invalidate the associated key.
            // So this is a fails-shut, and we would just do it again and again each time
            if logFileName {
                Self.logger
                    .error(
                        "Failed to mark a sessions file as corrupt. filePath=\(fileURL.path(), privacy: .public) error=\(String(unredacted: error), privacy: .public)"
                    )
            } else {
                Self.logger
                    .error(
                        "Failed to mark a sessions file as corrupt. filePath=\(fileURL.path(), privacy: .private) error=\(String(unredacted: error), privacy: .public)"
                    )
            }
        }
    }

    /// Actually delete the file, should only happen when told a key is no longer valid
    /// (or implicitly told this on restore when given the set of valid keys)
    /// If this can't do it it will log but not throw/panic
    private func removeSessionFile(fileURL: URL, logFileName: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path()) else {
            return
        }
        do {
            if logFileName {
                Self.logger.info("Removing sessions file \(fileURL.path(), privacy: .public)")
            } else {
                Self.logger.info("Removing sessions file \(fileURL.path(), privacy: .private)")
            }
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            // This is not a serious problem.
            // if the key was no longer valid it won't just become valid again
            // the files in the temporary directory will get deleted by the system in days
            // anyway so crashing here would just degrade availability
            if logFileName {
                Self.logger
                    .error(
                        "Failed to remove sessions file \(fileURL.path(), privacy: .public): \(String(unredacted: error), privacy: .public)"
                    )
            } else {
                Self.logger
                    .error(
                        "Failed to remove sessions file \(fileURL.path(), privacy: .private): \(String(unredacted: error), privacy: .public)"
                    )
            }
        }
    }

    /// Remember this function (and called functions) are *not* allowed to log file names
    /// as public until they are verified as being legitimate node key ID
    func restoreSessions(validNodeKeyIDs: [NodeKeyID]) -> [NodeKeyID: RecoveredSessionState] {
        guard let directoryEnumerator = self.fileManager.enumerator(
            at: self.fileDirectory, includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            // we have no good options here - either we crash, or operate as if we have no state
            // Crucially we cannot distinguish between a key that was just created
            // (and so would not have any previous state) and one where it might have had some and
            // so should be invalidated
            // By treating _everything_ as bad regardless we force the revocation of all keys
            // and then we will keep operating after that (in memory only if necessary)
            Self.logger.error(
                "Unable to enumerate the directory \(self.fileDirectory.path(), privacy: .public) - forcing all keys invalid"
            )
            return .init(uniqueKeysWithValues: validNodeKeyIDs.map { ($0, .failed) })
        }

        // we will mutate the directory as we process files so we need to snapshot the relevant parts now
        var filesToHandle: [URL: (NodeKeyID, currentStatus: FileStatus, action: RestoreAction)] = [:]
        var seenNodeKeyIds: [NodeKeyID: URL] = [:]
        let resourceKeys = Set<URLResourceKey>([.nameKey, .isDirectoryKey, .isReadableKey, .fileSizeKey])
        for case let fileURL as URL in directoryEnumerator {
            // While iterating we can safely ignore anything we don't understand/are unable to read.
            // so long as we are confident it is not referring to a node key in the valid list
            // If it was a file for a key considered valid that key will then be treated as a failed
            // restore later
            // It's nice to ignore things we expect though because it makes debugging easier
            if fileURL.lastPathComponent == "session.lock" {
                continue
            }
            guard let (nodeKeyID, status) = self.parseFileName(fileURL: fileURL) else {
                continue
            }
            let isValidNodeKeyID = validNodeKeyIDs.contains(nodeKeyID)
            if let otherFile = seenNodeKeyIds[nodeKeyID] {
                if isValidNodeKeyID {
                    Self.logger
                        .error(
                            "multiple files for the same nodekey \(nodeKeyID.base64EncodedString(), privacy: .public), treating all as if corrupt"
                        )
                } else {
                    Self.logger
                        .error(
                            "multiple files for the same nodekey \(nodeKeyID.base64EncodedString(), privacy: .private). treating all as if corrupt"
                        )
                }
                // change the previous action to just treat as corrupt
                let previous = filesToHandle[otherFile]!
                filesToHandle[otherFile] = (nodeKeyID, previous.currentStatus, .knownToBeCorrupt)
                filesToHandle[fileURL] = (nodeKeyID, status, .knownToBeCorrupt)
                continue
            }
            seenNodeKeyIds[nodeKeyID] = fileURL
            let action: RestoreAction = switch status {
            case .corrupt:
                // don't touch it at all, it's serving its purpose blocking that node key
                .knownToBeCorrupt
            case .validating:
                // A past instance of cloudboardd attempted to validate this file, but failed
                // to complete that in some way. We treat this as corrupt (the most likely reason is the
                // file was either large enough to trigger a jetsam event, or malformed in some way that
                // we crashed trying to parse it.
                // No point trying again
                .markAsCorrupt
            case .active:
                if isValidNodeKeyID {
                    // this needs validating before we consider it okay and loaded
                    .validate
                } else {
                    // The key for this won't become valid again, so just cleanup
                    .cleanRemove
                }
            }
            filesToHandle[fileURL] = (nodeKeyID, status, action)
            // this directory shouldn't have any subdirectories, but avoid them regardless
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                continue
            }
            if resourceValues.isDirectory ?? false {
                directoryEnumerator.skipDescendants()
            }
        }
        // By the end of this any keys from validaNodeKeyIDs not present in here is reasonable to be
        // treated as a new empty set
        var restoredSessions: [NodeKeyID: RecoveredSessionState] = [:]
        for (fileURL, (nodeKeyID, currentStatus, action)) in filesToHandle {
            let isValidNodeKeyID = validNodeKeyIDs.contains(nodeKeyID)
            switch action {
            case .knownToBeCorrupt:
                // we don't remove files - but only reasonable to log if the keyID is known
                if isValidNodeKeyID {
                    Self.logger.error("\(fileURL, privacy: .public) indicates the key cannot be used")
                    restoredSessions[nodeKeyID] = RecoveredSessionState.failed
                } else {
                    Self.logger
                        .notice(
                            "Session file \(fileURL, privacy: .private) in \(currentStatus.rawValue, privacy: .public) not relevant to the valid keys, leaving it untouched"
                        )
                }
            case .markAsCorrupt:
                if isValidNodeKeyID {
                    Self.logger
                        .error(
                            "\(fileURL, privacy: .public) detected. Assuming previous failure at validation and moving to corrupt"
                        )
                    restoredSessions[nodeKeyID] = RecoveredSessionState.failed
                }
                self.markAsCorrupted(fileURL: fileURL, logFileName: isValidNodeKeyID)
            case .validate:
                precondition(isValidNodeKeyID, "attempt to validate a file pointlessly!")
                if let sessions = self.readSessionFile(fileURL: fileURL) {
                    restoredSessions[nodeKeyID] = .success(Set<SessionKey>(sessions))
                } else {
                    // detailed error reason already logged earlier
                    self.markAsCorrupted(fileURL: fileURL, logFileName: true)
                    restoredSessions[nodeKeyID] = .failed
                }
            case .cleanRemove:
                precondition(!isValidNodeKeyID, "attempt to remove a file for a known key!")
                self.removeSessionFile(fileURL: fileURL, logFileName: false)
            }
        }
        // make sure every input key gets a result
        for validNodeKeyID in validNodeKeyIDs {
            if restoredSessions[validNodeKeyID] == nil {
                // if we got here we are happy no files in the directory represent this key
                // therefore it's reasonable to start it fresh.
                // we don't bother to actually write a file for it, we can do that on the first actual entry
                restoredSessions[validNodeKeyID] = .success(Set<SessionKey>())
            }
        }
        return restoredSessions
    }

    // exposed to make tests easier
    internal func getFileUrl(
        keyID: NodeKeyID,
        status: FileStatus = .active
    ) -> URL {
        return self.fileDirectory
            .appendingPathComponent(self.encodeKeyID(keyID: keyID))
            .appendingPathExtension(status.rawValue)
    }

    func removeSessions(of expiredNodeKeyID: NodeKeyID) {
        self.fileHandles.withLock {
            if let fileHandle = $0.removeValue(forKey: expiredNodeKeyID) {
                do {
                    try fileHandle.close()
                } catch {
                    Self.logger
                        .error(
                            "Failed to close file: \(String(unredacted: error), privacy: .public) for \(expiredNodeKeyID.base64EncodedString(), privacy: .public)"
                        )
                }
            }
        }
        // and remove the file (if it exists regardless)
        self.removeSessionFile(fileURL: self.getFileUrl(keyID: expiredNodeKeyID), logFileName: true)
    }

    func storeSession(_ sessionEntry: SessionEntry) {
        // we don't log this because it has a significant slow down cost to tests in XCode
        let fileHandle: Foundation.FileHandle
        do {
            fileHandle = try self.getFileHandle(for: sessionEntry.nodeKeyID)
        } catch {
            Self.logger.error("""
            Failed to open file. Will not store the session to file. \
            nodeKeyID=\(sessionEntry.nodeKeyID.base64EncodedString(), privacy: .public) \
            error=\(String(unredacted: error), privacy: .public)
            """)
            self.treatAsCorrupt(nodeKeyID: sessionEntry.nodeKeyID, fileHandle: nil)
            return
        }
        // We want to protect against an adversary able to crash cloudboardd after the insert.
        // Despite this a simple synchronous write call is sufficient without also doing a synchronize()
        // This seems strange but:
        // Once the write returns the data has been flushed into OS buffers.
        // If the process dies and is restarted those writes will be visible
        // Any failure of flushing the buffers to the persistant layer from then on
        // is not a concern because all of those scenarios would imply that the Ephemeral data mode
        // in PRCOS results in _all_ data being destroyed anyway (and the keys going invalid too)
        // Therefore we can avoid the underlying fsync that would be detrimental done at high rate for such
        // tiny writes, as well as needlessly slow
        do {
            try fileHandle.write(contentsOf: sessionEntry.sessionKey.asData)
        } catch {
            Self.logger.error("""
            Failed to write session to disk. Attempting to mark the key as corrupt \
            nodeKeyID=\(sessionEntry.nodeKeyID.base64EncodedString(), privacy: .public) \
            error=\(String(unredacted: error), privacy: .public)
            """)
            self.treatAsCorrupt(nodeKeyID: sessionEntry.nodeKeyID, fileHandle: fileHandle)
        }
    }

    /// Called in the event storage of a ``SessionKey`` for the `nodeKeyID`` is not possible
    /// We don't want to crash the system/reject the request, but the only way this can be
    /// done is if we ensure the active file backing that node key is marked as ``FileStatus.corrupt``
    /// We can achieve that in a few ways, in order of preference:
    /// 1) Change the file name to be `<nodeKeyID>.corrupt`
    /// 2) Add a new file name of `<nodeKeyID>.corrupt`
    ///  - we will log about it on restart complaining, but the effect is the same
    /// 3) Write an illegal data block to the file
    /// - we just failed to write the file, so this is tricky!
    ///
    /// This does not throw, or panic, if we can't do this and crash we make things worse as at least
    /// the in memory state is protecting us.
    private func treatAsCorrupt(nodeKeyID: NodeKeyID, fileHandle: FileHandle?) {
        // first send all further writes to devnull so the attempts to tidy up have no interference
        self.fileHandles.withLock {
            $0[nodeKeyID] = FileHandle.nullDevice
        }

        if let fileHandle {
            // try again to write an illegal entry to the file so parsing it in future will fail
            // if this works great, but we should assume it won't and should keep trying other
            // things whether it works or not
            do {
                try fileHandle.write(contentsOf: Data(repeating: 0, count: SessionKey.byteLength * 2))
                Self.logger
                    .notice(
                        "Wrote sentinel bad section to session file for \(nodeKeyID.base64EncodedString(), privacy: .public)"
                    )
            } catch {
                Self.logger
                    .error(
                        "Attempt to write sentinel bad section to session file for \(nodeKeyID.base64EncodedString(), privacy: .public) failed, this was expected"
                    )
            }
            // close the handle so we can try to move it
            do {
                try fileHandle.close()
            } catch {
                Self.logger
                    .error("unable to close the file handle for \(nodeKeyID.base64EncodedString(), privacy: .public)")
            }
        }
        let activeFileURL = self.getFileUrl(keyID: nodeKeyID, status: .active)
        let corruptFileURL = self.getFileUrl(keyID: nodeKeyID, status: .corrupt)
        guard !self.fileManager.fileExists(atPath: corruptFileURL.path()) else {
            // great, something already did it
            Self.logger
                .notice("marker file already exists at \(corruptFileURL.path(), privacy: .public) safe to continue")
            return
        }

        if self.fileManager.fileExists(atPath: activeFileURL.path()) {
            // try to move it
            do {
                try self.fileManager.moveItem(at: activeFileURL, to: corruptFileURL)
                Self.logger
                    .notice(
                        "moved \(activeFileURL.path(), privacy: .public) to \(corruptFileURL.path(), privacy: .public)"
                    )
                return
            } catch {
                Self.logger.error("unable to move  for \(nodeKeyID.base64EncodedString(), privacy: .public)")
            }
            // we do not want to delete the file, it's better than nothing in the event of a restart
        }

        // Write a corrupt one, if there was no activeFile this works cleanly
        // If there wasn't it will still work as multiple files for the same key is treated as corrupt
        if self.fileManager.createFile(atPath: corruptFileURL.path(), contents: Data()) {
            Self.logger.notice("created \(corruptFileURL.path(), privacy: .public)")
            return
        }
        // At this stage there's not much we can do. Crashing the process just results in a potential replay
        Self.logger
            .error(
                "unable to create the corrupt marker file for \(nodeKeyID.base64EncodedString(), privacy: .public) continuing"
            )
    }

    private func getFileHandle(for nodeKeyID: NodeKeyID) throws -> Foundation.FileHandle {
        try self.fileHandles.withLock {
            if let fileHandle = $0[nodeKeyID] {
                return fileHandle
            }

            let fileURL = self.getFileUrl(keyID: nodeKeyID)
            if !FileManager.default.fileExists(atPath: fileURL.path()) {
                Self.logger.info("""
                Creating sessions file for node key. \
                nodeKeyID=\(nodeKeyID.base64EncodedString(), privacy: .public) \
                filePath=\(fileURL.path, privacy: .public)
                """)
                guard FileManager.default.createFile(atPath: fileURL.path(), contents: nil) else {
                    throw OnDiskSessionStorageError.failedToCreateFile
                }
            }

            let fileHandle = try FileHandle(forWritingTo: fileURL)
            try fileHandle.seekToEnd()
            $0[nodeKeyID] = fileHandle
            Self.logger.info("""
            Opened sessions file for node key. \
            nodeKeyID=\(nodeKeyID.base64EncodedString(), privacy: .public) \
            filePath=\(fileURL.path, privacy: .public)
            """)
            return fileHandle
        }
    }

    // exposed so tests can cover the edge cases
    internal static let chunkBufferSize = SessionKey.byteLength * 8 * 1024

    private func readSessionFile(fileURL: URL) -> [SessionKey]? {
        Self.logger.notice("Attempting restore from \(fileURL.path(), privacy: .public)")
        precondition(
            fileURL.pathExtension == FileStatus.active.rawValue,
            "attempt to validate a file that is not active"
        )
        // We first move the file to a pending name, if we crash during processing
        // this will then be ignored/deleted on subsequent restarts
        // This means if things crash/are restarted for other reasons the file is also lost,
        // but since this results in the associated key being invalidated this reamins safe
        let pendingFile = fileURL.deletingPathExtension().appendingPathExtension(FileStatus.validating.rawValue)
        do {
            try FileManager.default.moveItem(at: fileURL, to: pendingFile)
        } catch {
            Self.logger
                .error(
                    "Failed to move \(fileURL.path(), privacy: .public) - to \(pendingFile.path(), privacy: .public): \(error)"
                )
            // Not much we can do here, possibly the box is out of disk which
            // implies something is pretty wrong
            return nil
        }
        var sessions: [SessionKey] = []
        do {
            if let stream = InputStream(url: pendingFile) {
                stream.open()
                defer {
                    stream.close()
                }
                // Read the file in chunks
                let chunkSize = Self.chunkBufferSize
                var chunkBuffer = ByteBufferAllocator().buffer(capacity: chunkSize)
                while stream.hasBytesAvailable {
                    let bytesRead = chunkBuffer.writeWithUnsafeMutableBytes(minimumWritableBytes: chunkSize) {
                        stream.read($0.baseAddress!, maxLength: chunkSize)
                    }
                    if bytesRead < 0 {
                        if let error = stream.streamError {
                            Self.logger
                                .error(
                                    "failed to read file \(pendingFile, privacy: .public) : \(error, privacy: .public)"
                                )
                            throw OnDiskSessionStorageError.fileReadError
                        }
                        Self.logger.error("failed to read file \(pendingFile, privacy: .public)")
                        throw OnDiskSessionStorageError.fileReadError
                    }

                    while chunkBuffer.readableBytes >= SessionKey.byteLength {
                        try sessions.append(SessionKey(from: &chunkBuffer))
                    }
                    // reading from a file so we will get what we ask for unless we ran out of file
                    // therefore we have either:
                    // 1. a partial write that didn't make it
                    // 2. a corrupt file
                    // Either way we just drop the whole thing and (therefore) drop the key
                    guard chunkBuffer.readableBytes == 0 else {
                        Self.logger
                            .error(
                                "\(chunkBuffer.readableBytes, privacy: .public) trailing bytes in file \(pendingFile, privacy: .public) - considering invalid"
                            )
                        throw OnDiskSessionStorageError.fileReadError
                    }
                    chunkBuffer.clear()
                }
            }
        } catch {
            Self.logger.error("""
            Failed to restore sessions from file. \
            filePath=\(fileURL.path(), privacy: .public) \
            error=\(String(unredacted: error), privacy: .public)
            """)
            // clean up after ourselves
            self.markAsCorrupted(fileURL: pendingFile, logFileName: true)
            return nil
        }
        // success, we move the pending file back so it gets picked up next time
        do {
            try FileManager.default.moveItem(at: pendingFile, to: fileURL)
        } catch {
            Self.logger
                .error(
                    "Failed to move \(pendingFile.path(), privacy: .public) - to pending \(fileURL.path(), privacy: .public): \(error)"
                )
            // Again, not much we can do here, drop the session and hence the key
            // the pending file should be cleaned up on the next restart
            return nil
        }
        Self.logger.info("""
        Restored sessions from file. \
        filePath=\(fileURL.path(), privacy: .public) \
        numSessions=\(sessions.count, privacy: .public) 
        """)
        return sessions
    }

    deinit {
        fileHandles.withLock {
            for fileHandle in $0.values {
                do {
                    try fileHandle.close()
                } catch {
                    Self.logger.error("Failed to close file: \(String(unredacted: error), privacy: .public)")
                }
            }
        }
        try? self.lockFileDescriptor.close()
        Self.processLocks.withLock { locks in
            _ = locks.remove(self.sessionLockPath)
        }
        Self.logger.notice("Released session lock on \(self.sessionLockPath, privacy: .public)")
    }
}

final class NoOpSessionStorage: SessionStorage {
    func storeSession(_: SessionEntry) {
        // no-op
    }

    func removeSessions(of _: NodeKeyID) {
        // no-op
    }

    func restoreSessions(
        validNodeKeyIDs: [NodeKeyID]
    ) -> [NodeKeyID: RecoveredSessionState] {
        return .init(
            uniqueKeysWithValues: validNodeKeyIDs
                .map { ($0, RecoveredSessionState.success(Set<SessionKey>())) }
        )
    }
}
