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

import ArgumentParserInternal
import Foundation
import os
import PrivateFilterCommon

/// Root-privileged, run-once-at-boot daemon that hands the download-cache volume
/// to the `mobile` user so the (non-root) PrivateFilter services can write to it.
///
/// The volume is provisioned by darwin-init as `root:wheel`, and darwin-init-v2
/// cannot set volume ownership, so the fix must happen on-device. Sandbox
/// entitlements grant sandbox access but not POSIX write, so without this the
/// downloader cannot create its cache tree.
@main
struct PrivateFilterDownloaderHelperApp: AsyncParsableCommand {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PrivateFilterDownloaderHelper"
    )

    /// Mount root of the download-cache volume whose ownership this helper fixes.
    ///
    /// Hard-coded and never derived from mutable config so this root-privileged
    /// `chown` can only ever touch this one directory. It is a deliberate security
    /// boundary: the daemon must never become a tool for changing ownership on an
    /// attacker-chosen path. The constant is paired with the helper's
    /// `com.apple.security.exception.files.absolute-path.read-write` entitlement,
    /// which grants write to exactly this path — the two MUST stay in sync (and with
    /// the darwin-init volume mount point and the parent of the services'
    /// `remoteRootPath`). Divergence from the configured `remoteRootPath` is detected
    /// and logged (see `warnIfConfiguredRootDiverges`) but never acted on.
    private static let cacheVolumeRoot = URL(
        fileURLWithPath: "/private/var/mnt/com.apple.cloudos.pfs.download-cache"
    )

    /// Owner the cache volume must end up with — the user the PrivateFilter
    /// services run as.
    private static let cacheOwner = "mobile"

    func run() async throws {
        // Testing kill-switch: when disabled, exit cleanly without touching the
        // volume so a test rig can manage ownership by hand or exercise the daemons'
        // cache-access waiting. Fails open (enabled) if config can't be read.
        guard PrivateFilterHelperConfig.loadFromDevice().enabled else {
            Self.logger.log("PrivateFilterDownloaderHelper disabled via config. Exiting without fixup.")
            return
        }

        Self.warnIfConfiguredRootDiverges()

        // The cache volume is mounted by darwin-init before any CloudBoard daemon is
        // started, so if it is absent here this node simply has no such volume (the
        // feature isn't provisioned) — there is nothing to change. Log a notice and
        // exit cleanly rather than failing, which would make launchd retry forever on
        // a node that will never have the volume.
        guard Self.cacheVolumeIsPresent() else {
            Self.logger.notice("""
            No cache volume at \(Self.cacheVolumeRoot.path, privacy: .public); \
            nothing to change. Exiting.
            """)
            return
        }

        // Already fixed up (e.g. a persistent volume chowned on a prior boot): skip
        // the recursive chown entirely. Only the top-level owner matters — once the
        // root is `mobile`-owned the downloader owns everything it creates beneath it
        // — so this both avoids a needless tree walk and, more importantly, stays out
        // of the downloader's way when it may already be writing into the volume.
        guard !CacheVolumeAccess.isOwned(Self.cacheVolumeRoot, by: Self.cacheOwner) else {
            Self.logger.notice("""
            Cache volume at \(Self.cacheVolumeRoot.path, privacy: .public) already owned by \
            \(Self.cacheOwner, privacy: .public); nothing to change. Exiting.
            """)
            return
        }

        // The volume is present. Chown directly; any failure now is a real error and
        // throws, exiting non-zero so launchd (KeepAlive on unsuccessful exit) retries
        // after ThrottleInterval rather than silently leaving the volume unfixed.
        try CacheVolumeAccess.chownRecursively(
            Self.cacheVolumeRoot,
            toUser: Self.cacheOwner,
            logger: Self.logger
        )
    }

    /// Whether the baked-in cache volume mount root exists as a directory.
    private static func cacheVolumeIsPresent() -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: self.cacheVolumeRoot.path, isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    /// Best-effort check that the services' configured `remoteRootPath` actually
    /// lives on the volume this helper fixes. Read purely to detect and log drift —
    /// the chown target is the hard-coded `cacheVolumeRoot`, never this value, so a
    /// mismatch cannot redirect the chown; it only means the configured cache would
    /// not be made writable until the baked path and entitlement are updated to match.
    private static func warnIfConfiguredRootDiverges() {
        guard let config = PrivateFilterServiceConfiguration.loadFromDevice() else { return }
        let configuredVolumeRoot = config.remoteRootParent.standardizedFileURL
        guard configuredVolumeRoot != self.cacheVolumeRoot.standardizedFileURL else { return }
        Self.logger.error("""
        Configured cache volume (\(configuredVolumeRoot.path, privacy: .public)) does not match the \
        baked chown target (\(self.cacheVolumeRoot.path, privacy: .public)); chowning only the baked path. \
        The configured cache will NOT be made writable — update the baked path and the helper's \
        read-write entitlement to match remoteRootPath.
        """)
    }
}
