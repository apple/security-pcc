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

//
//  SandboxDataContainer.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
import SandboxPrivate
internal import StorageContainersPrivate
import containermanager
import os.log

private let logger = Logger(for: .sandbox)

/// Acquires a sandbox data container and executes the provided body with access to the container URL.
/// The data container provides isolated storage that persists across app launches.
nonisolated(nonsending) package func withSandboxDataContainer<T: Sendable>(
    _ body: (URL) async -> T
) async -> T {
    if shouldUseProtectedSystemContainer(featureFlags: FeatureFlagChecker()) {
        return await withProtectedSystemDataContainer(body)
    } else {
        return await withDaemonDataContainer(body)
    }
}

/// Decides whether to store the daemon's state in a Protected System container rather than the
/// legacy Internal Daemon Data container.
private func shouldUseProtectedSystemContainer(featureFlags: some FeatureFlagCheckerProtocol) -> Bool {
    #if os(macOS)
    return featureFlags.isEnabled(.protectedSystemContainerMacOS)
    #else
    return featureFlags.isEnabled(.protectedSystemContainerEmbedded)
    #endif
}

// MARK: - Legacy Internal Daemon Data container

/// Acquires the legacy Internal Daemon Data container and executes the provided body with access to
/// the container URL.
nonisolated(nonsending) package func withDaemonDataContainer<T: Sendable>(
    _ body: (URL) async -> T
) async -> T {
    let (url, handle) = acquireContainerHandle()
    defer { releaseContainerHandle(handle: handle) }
    return await body(url)
}

/// Acquires a container handle, optionally crashing on failure.
/// - Returns: The container URL and sandbox extension handle.
private func acquireContainerHandle() -> (url: URL, handle: Int64) {
    let query = container_query_create()
    defer { container_query_free(query) }
    guard let query else {
        fatalError("container_query_create returned nil")
    }
    logger.debug("container_query_create succeeded")

    container_query_set_class(query, CONTAINER_CLASS_INTERNAL_DAEMON_DATA)
    container_query_operation_set_flags(
        query,
        [
            .CONTAINER_QUERY_FLAGS_CREATE_IF_MISSING,
            .CONTAINER_QUERY_FLAGS_RESULT_INCLUDE_PATH,
            .CONTAINER_QUERY_FLAGS_RESULT_INCLUDE_SANDBOX_EXTENSIONS,
        ]
    )
    container_query_set_persona_unique_string(query, CONTAINER_PERSONA_PRIMARY)

    let container = container_query_get_single_result(query)
    guard let container else {
        let error = container_query_get_last_error(query)
        let description = container_error_copy_unlocalized_description(error)
        defer { free(description) }
        let descriptionString = description.flatMap { String(cString: $0, encoding: .utf8) } ?? "nil"
        fatalError("container_query_get_single_result returned nil, error=\(descriptionString)")
    }
    logger.debug("container_query_get_single_result succeeded")

    let path = container_get_path(container)
    guard let path else {
        fatalError("container_get_path returned nil")
    }
    let url = URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
    logger.debug("container_get_path succeeded, url=\(url)")

    let extensionToken = container_copy_sandbox_token(container)
    defer { free(extensionToken) }
    logger.debug("container_copy_sandbox_token succeeded")

    let extensionHandle = sandbox_extension_consume(extensionToken)
    guard extensionHandle != -1 else {
        let error = String(cString: strerror(errno))
        fatalError("sandbox_extension_consume returned handle=-1, error=\(error)")
    }
    logger.debug("sandbox_extension_consume returned handle=\(extensionHandle)")

    let accessResult = access(path, R_OK | W_OK)
    guard accessResult == 0 else {
        let error = String(cString: strerror(errno))
        fatalError("no read/write access to container path: \(error)")
    }

    return (url: url, handle: extensionHandle)
}

private func releaseContainerHandle(handle extensionHandle: Int64) {
    let result = sandbox_extension_release(extensionHandle)
    guard result != -1 else {
        let error = String(cString: strerror(errno))
        fatalError("sandbox_extension_release failed, handle=\(extensionHandle) error=\(error)")
    }
    logger.debug("sandbox_extension_release succeeded handle=\(extensionHandle)")
}

// MARK: - Protected System container

/// Acquires the daemon's Protected System container and executes the provided body with access to
/// the container URL.
///
/// A Protected System container is data-vaulted on all platforms including macOS: even processes
/// granted Full Disk Access cannot reach it. Only this daemon, which carries the
/// `com.apple.private.security.protected-system-container` entitlement, can. Before handing the
/// container to `body`, we delete the daemon's older Internal Daemon Data container.
nonisolated(nonsending) package func withProtectedSystemDataContainer<T: Sendable>(
    _ body: (URL) async -> T
) async -> T {
    let container: Container.Owned
    do {
        container = try Container.Owned(of: .protectedSystem(), persona: .primary)
    } catch {
        fatalError("failed to create protected system container: \(error)")
    }
    logger.debug("created protected system container handle")

    // Access to the container path is only valid while access is granted; hold it for the lifetime of this function.
    do {
        try container.grantAccess(required: true)
    } catch {
        fatalError("failed to grant access to protected system container: \(error)")
    }
    defer {
        container.revokeAccess()
        logger.debug("revoked access to protected system container")
    }
    logger.debug("granted access to protected system container")

    guard let path = container.path, let url = URL(filePath: path, directoryHint: .isDirectory) else {
        fatalError("protected system container path unavailable")
    }
    logger.debug("resolved protected system container path, url=\(url)")
    logger.log("acquired protected system container, url=\(url)")

    excludeFromBackup(url)
    deleteLegacyDaemonContainer()

    return await body(url)
}

private func excludeFromBackup(_ containerURL: URL) {
    do {
        var url = containerURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        logger.debug("excluded container from backup, url=\(url)")
    } catch {
        logger.error("failed to exclude container from backup, url=\(containerURL), error=\(error)")
    }
}

/// Deletes the daemon's legacy Internal Daemon Data container (the one used before the switch to a
/// Protected System container).
private func deleteLegacyDaemonContainer() {
    do {
        let legacyContainers = try Containers(of: .daemon, persona: .primary)
        guard let legacy = legacyContainers.first else {
            logger.log("no legacy daemon container found; nothing to delete")
            return
        }
        try legacy.delete()
        logger.log("deleted legacy daemon container")
    } catch Query.QueryError.noMatchingContainers {
        logger.log("no legacy daemon container found; nothing to delete")
    } catch {
        logger.error("failed to delete legacy daemon container, error=\(error)")
    }
}
