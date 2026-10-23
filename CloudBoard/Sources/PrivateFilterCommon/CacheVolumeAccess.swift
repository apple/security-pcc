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
import os

/// Filesystem-ownership and access helpers shared by the PrivateFilter services
/// and the ownership-fixup helper.
///
/// The download cache lives on a darwin-init provisioned volume whose mount root
/// is created `root:wheel`. The services run as `mobile`, and sandbox
/// entitlements do not override POSIX ownership, so a privileged helper must hand
/// the volume to `mobile` before the downloader can create its cache tree. These
/// utilities implement that chown and the access probes the services use to wait
/// until the fixup has happened.
package enum CacheVolumeAccess {
    package enum Error: Swift.Error, CustomStringConvertible {
        /// No passwd entry for the requested user name.
        case unknownUser(String)
        /// `lchown(2)` failed for a specific path.
        case chownFailed(path: String, code: Int32)
        /// The directory tree under `root` could not be enumerated (root missing,
        /// unreadable, or not a directory) — so ownership could not be fully applied.
        case enumerationFailed(path: String)

        package var description: String {
            switch self {
            case .unknownUser(let name):
                "No passwd entry for user '\(name)'"
            case .chownFailed(let path, let code):
                "chown failed for \(path): \(String(cString: strerror(code))) (errno \(code))"
            case .enumerationFailed(let path):
                "could not enumerate directory tree at \(path)"
            }
        }
    }

    /// Recursively change ownership of `root` (and everything beneath it) to the
    /// named user's uid/gid. Uses `lchown` so symlinks are re-owned in place
    /// rather than followed. Idempotent — re-running on an already-owned tree is a
    /// no-op at the ownership level.
    ///
    /// Must run with sufficient privilege (root); a non-privileged caller will
    /// hit `EPERM`.
    @discardableResult
    package static func chownRecursively(
        _ root: URL,
        toUser userName: String,
        logger: Logger
    ) throws -> Int {
        guard let pw = getpwnam(userName) else {
            throw Error.unknownUser(userName)
        }
        let uid = pw.pointee.pw_uid
        let gid = pw.pointee.pw_gid

        // A nil enumerator means the tree can't be walked (root missing, unreadable,
        // or not a directory). Treat it as an error rather than chowning only `root`
        // and reporting success — that would mask a real problem as "Entries=1".
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw Error.enumerationFailed(path: root.path)
        }
        var paths = [root]
        for case let url as URL in enumerator {
            paths.append(url)
        }

        for url in paths {
            if lchown(url.path, uid, gid) != 0 {
                throw Error.chownFailed(path: url.path, code: errno)
            }
        }
        logger.log("""
        Reassigned cache volume ownership. \
        Root=\(root.path, privacy: .public) \
        User=\(userName, privacy: .public) \
        Entries=\(paths.count, privacy: .public)
        """)
        return paths.count
    }

    /// True if `url`'s owner and group already match the named user's uid/gid.
    /// Returns false on any error (unknown user, unreadable attributes) so callers
    /// treat "can't confirm" as "not yet correct" and fall through to fixing it.
    ///
    /// Lets the ownership fixup be idempotent: if the volume root is already owned by
    /// the target user, the caller can skip the recursive chown entirely — avoiding a
    /// needless tree walk and, more importantly, avoiding racing whoever is now
    /// writing into the (already-correctly-owned) volume.
    package static func isOwned(_ url: URL, by userName: String) -> Bool {
        guard let pw = getpwnam(userName) else { return false }
        let uid = pw.pointee.pw_uid
        let gid = pw.pointee.pw_gid
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let owner = attributes[.ownerAccountID] as? NSNumber,
            let group = attributes[.groupOwnerAccountID] as? NSNumber
        else {
            return false
        }
        return owner.uint32Value == uid && group.uint32Value == gid
    }

    /// True if a throwaway file can be created and removed directly inside `dir`.
    /// Probes the real write (a temp file in `dir`) rather than `access(2)`, so it
    /// reflects both POSIX permissions and sandbox policy.
    ///
    /// Does NOT create `dir`: a missing directory reads as not-writable (`false`),
    /// which is exactly what the startup waits want — callers probe a directory that
    /// already exists (the mounted volume root) and must not fabricate it (which
    /// could shadow a not-yet-present mount).
    package static func isReadWritable(_ dir: URL) -> Bool {
        // Per-call UUID (not just the PID) so concurrent probes from the same process
        // — e.g. separate Tasks racing at startup — get distinct files and never
        // remove or overwrite each other's probe mid-flight.
        let probe = dir.appendingPathComponent(
            ".pfs-access-probe-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
        )
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// True if `dir` exists and its contents can be listed by the current process.
    package static func isReadable(_ dir: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil
    }

    /// The kind of access a startup wait is blocking on.
    package enum AccessMode {
        /// Can list the directory's contents (`isReadable`).
        case readable
        /// Can create/remove a file directly inside the directory (`isReadWritable`).
        case readWritable
    }

    /// Poll `dir` every `pollInterval` until it has `mode` access, then return.
    ///
    /// Unbounded on purpose: only an external actor (the ownership-fixup helper for
    /// write access, the downloader for the populated cache) can make the condition
    /// true, so there is nothing useful to do but wait, and waiting is strictly
    /// better than exiting and crash-looping. Logs on the first miss and then
    /// periodically so the wait is observable. Shared by the downloader (which waits
    /// for `.readWritable` on the volume root) and the controller (which waits for
    /// `.readable` on the populated cache directory).
    package static func waitForAccess(
        to dir: URL,
        mode: AccessMode,
        pollInterval: Duration,
        logger: Logger
    ) async {
        func satisfied() -> Bool {
            switch mode {
            case .readable: isReadable(dir)
            case .readWritable: isReadWritable(dir)
            }
        }
        let modeDescription = switch mode {
        case .readable: "readable"
        case .readWritable: "read/writable"
        }

        var attempt = 0
        while !satisfied() {
            attempt += 1
            // Log the first miss and then periodically to avoid spamming the log.
            if attempt == 1 || attempt.isMultiple(of: 12) {
                logger.log("""
                Cache not yet \(modeDescription, privacy: .public), waiting. \
                Path=\(dir.path, privacy: .public) \
                Attempt=\(attempt, privacy: .public)
                """)
            }
            try? await Task.sleep(for: pollInterval)
        }
        if attempt > 0 {
            logger.log("""
            Cache is now \(modeDescription, privacy: .public). Proceeding. \
            Path=\(dir.path, privacy: .public)
            """)
        }
    }
}
