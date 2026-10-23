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
import System
import os

fileprivate struct LockedFile {
    enum LockType {
        case shared
        case exclusive
    }
    
    // When "nonBlocking" is true, this throws Errno.resourceTemporarilyUnavailable (aka EAGAIN)
    // when there is an existing lock on the file.
    static func setLock(fileDescriptor: FileDescriptor, lockType: LockType, nonBlocking: Bool = false) throws {
        var f: flock = flock()
        f.l_start = 0
        f.l_len = 0 // until end of file
        f.l_whence = Int16(truncatingIfNeeded: SEEK_SET)

        switch lockType {
        case .shared:
            f.l_type = Int16(truncatingIfNeeded: F_RDLCK)
        case .exclusive:
            f.l_type = Int16(truncatingIfNeeded: F_WRLCK)
        }
        
        while fcntl(fileDescriptor.rawValue, nonBlocking ? F_OFD_SETLK : F_OFD_SETLKW, &f) == -1 {
            let err = Errno.current
            if err != Errno.interrupted {
                throw err
            }
        }
    }
    
    static func open(_ path: FilePath, lockType: LockType, permissions: FilePermissions, nonBlocking: Bool = false) throws -> FileDescriptor {
        let mode: FileDescriptor.AccessMode
        switch lockType {
        case .shared:
            mode = .readOnly
        case .exclusive:
            mode = .readWrite
        }
        
        var fileDescriptor: FileDescriptor
        while true {
            fileDescriptor = try FileDescriptor.open(path, mode, options: [.create, .closeOnExec], permissions: permissions)
            
            let stat: FileStat
            do {
                try LockedFile.setLock(fileDescriptor: fileDescriptor, lockType: lockType, nonBlocking: nonBlocking)
                stat = try FileStat(path)
            } catch {
                fileDescriptor.closeNoThrow()
                throw error
            }
            
            // Between opening the path and acquiring the lock, the path could have been unlinked by another thread or process.
            // Retrying the entire process if the path is already unlinked.
            // NOTE: Other contexts should only be unlinking paths while holding an exclusive lock.
            if stat.numberOfHardLinks == 0 {
                fileDescriptor.closeNoThrow()
                continue
            } else {
                break
            }
        }
        
        return fileDescriptor
    }
}

class ExclusiveLockedFile {
    private let fileDescriptor: FileDescriptor
    private let path: FilePath
    
    // This class will own the FileDescriptor and close it on deinit.
    private init(fileDescriptor: FileDescriptor, path: FilePath) {
        self.fileDescriptor = fileDescriptor
        self.path = path
    }
    
    deinit {
        ExclusiveLockedFile.releaseLock(fileDescriptor: self.fileDescriptor, path: self.path)
    }
    
    private static func acquireLock(_ path: FilePath, permissions: FilePermissions, nonBlocking: Bool = false) throws -> FileDescriptor {
        let fileDescriptor: FileDescriptor
        
        Logger.filesystem.debug("Acquiring exclusive lock on \"\(path)\"")
        
        do {
            fileDescriptor = try LockedFile.open(path, lockType: .exclusive, permissions: permissions, nonBlocking: nonBlocking)
        } catch {
            Logger.filesystem.error("Failed to acquire exclusive locked file '\(path)': \(error)")
            throw error
        }
        
        Logger.filesystem.debug("Acquired exclusive lock on \"\(path)\" with fd \(fileDescriptor.rawValue)")
        
        return fileDescriptor
    }
    
    private static func releaseLock(fileDescriptor: FileDescriptor, path: FilePath) {
        Logger.filesystem.debug("Releasing exclusive lock on \"\(path)\"")
        path.withPlatformString { unlink($0); return }
        fileDescriptor.closeNoThrow()
        Logger.filesystem.debug("Released exclusive lock on \"\(path)\"")
    }
    
    static func open(_ path: FilePath, permissions: FilePermissions, nonBlocking: Bool = false) throws -> ExclusiveLockedFile {
        let fileDescriptor = try ExclusiveLockedFile.acquireLock(path, permissions: permissions, nonBlocking: nonBlocking)
        return ExclusiveLockedFile(fileDescriptor: fileDescriptor, path: path)
    }
    
    static func withLock<T>(on path: FilePath, permissions: FilePermissions, nonBlocking: Bool = false, _ block: () async throws -> T) async throws -> T {
        let fileDescriptor = try ExclusiveLockedFile.acquireLock(path, permissions: permissions, nonBlocking: nonBlocking)
        
        defer {
            ExclusiveLockedFile.releaseLock(fileDescriptor: fileDescriptor, path: path)
        }
        
        return try await block()
    }
}
