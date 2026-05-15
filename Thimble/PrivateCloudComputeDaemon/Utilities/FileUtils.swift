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

//
//  FileUtils.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
import os.log

private let daemonName = "PrivateCloudCompute"
package let blockingIOQueue = DispatchQueue(label: "com.apple.privatecloudcompute.blockingio", attributes: .concurrent)

// This is a _very_ low-rent way to take blocking IO off a concurrency thread
// when we can, without importing or building some non-blocking API alternative.
// Which we may care to do at some point but not for Crystal.
func doBlockingIOWork<T>(onQueue queue: DispatchQueue = blockingIOQueue, _ block: @Sendable @escaping () -> T) async -> T {
    return await withCheckedContinuation { continuation in
        queue.async {
            let x = block()
            continuation.resume(returning: x)
        }
    }
}

// This is a _very_ low-rent way to take blocking IO off a concurrency thread
// when we can, without importing or building some non-blocking API alternative.
// Which we may care to do at some point but not for Crystal.
func doThrowingBlockingIOWork<T>(onQueue queue: DispatchQueue = blockingIOQueue, _ block: @Sendable @escaping () throws -> T) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do {
                let x = try block()
                continuation.resume(returning: x)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// This function computes which directory our local state should be in.
/// - Parameter dataContainerUrl: An optional location, from the sandbox, that gives the location of our data container
/// - Parameter environment: For non-production environments, returned daemon url will be specific to the environment.
/// - Returns: A tuple; the first element is where we should store our local data, and the second location is optionally a location where the local store used to be, so we can migrate.
func getDaemonDirectoryPath(dataContainerUrl: URL? = nil, environment: TC2Environment) -> (URL, migrateFrom: URL?) {
    let logger = tc2Logger(forCategory: .daemon)
    let fileManager = FileManager.default

    // PLEASE NOTE
    // The daemon is not containerized. That means that the FileManager APIs do not do
    // the transparent work of putting our $HOME, etc (`.libraryDirectory` below) into
    // the data container. Instead, we deal directly with the data container and the
    // actual user $HOME; they appear differently and we can address both.
    //
    // As a result, what we're doing is as follows: if we are given a dataContainerUrl,
    // then we use it as the "daemon directory." And in that case, we also return the
    // actual $HOME-based directory, because someone might like to migrate some data
    // from one to the other in a transition.
    //
    // If, however, we are not given a dataContainerUrl, then we just happily operate
    // in $HOME like we did before.
    //
    // IMPORTANT: If the daemon becomes containerized in the future, this logic also
    // must change.

    let actualLibDir: URL
    let migrateFromLibDir: URL?
    if let dataContainerUrl {
        actualLibDir = dataContainerUrl.appending(path: "Library", directoryHint: .isDirectory)
        do {
            migrateFromLibDir = try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            fatalError("Could not get Library path for user error=\(error)")
        }
    } else {
        do {
            actualLibDir = try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            fatalError("Could not get Library path for user error=\(error)")
        }
        migrateFromLibDir = nil
    }

    func appendingPCCAndEnvironmentIfNeeded(libDir: URL, environment: TC2Environment?) -> URL {
        var result = URL(fileURLWithPath: libDir.path, isDirectory: true).appendingPathComponent(daemonName, isDirectory: true)
        if let environment, environment != .production {
            result = result.appending(path: environment.name, directoryHint: .isDirectory)
        }
        do {
            try fileManager.createDirectory(at: result, withIntermediateDirectories: true)
        } catch {
            fatalError("Failure to create directory at \(result) error=\(error) ")
        }
        return result
    }

    let daemonDir = appendingPCCAndEnvironmentIfNeeded(libDir: actualLibDir, environment: environment)
    let migrateFrom = migrateFromLibDir.map { url in
        appendingPCCAndEnvironmentIfNeeded(libDir: url, environment: nil)  // we didn't have environment subdirectories
    }
    logger.debug("daemonDir=\(daemonDir)")
    logger.debug("migrateFrom=\(migrateFrom?.absoluteString ?? "")")

    return (daemonDir, migrateFrom: migrateFrom)
}

/// Move an individual file for the purpose of migration
func moveDaemonStateFile(from source: URL, to destination: URL) {
    let logger = tc2Logger(forCategory: .daemon)
    let fileManager = FileManager.default

    logger.debug("migrating file source=\(source) destination=\(destination)")
    do {
        try fileManager.moveItem(at: source, to: destination)
    } catch {
        logger.error("migration failed error=\(error)")
    }
}

/// Remove an individual file if it exists ignoring any errors.
func removeDaemonStateFile(url: URL) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.relativePath) else {
        return
    }

    let logger = tc2Logger(forCategory: .daemon)

    logger.debug("deleting file url=\(url.absoluteString)")
    do {
        try fileManager.removeItem(at: url)
    } catch {
        logger.error("deletion failed error=\(error)")
    }
}
/// Move all the known files in a migration, and try to delete the source directory.
func migrateDaemon(from source: URL, to destination: URL) {
    let logger = tc2Logger(forCategory: .daemon)
    let fileManager = FileManager.default

    let destinationContents: [URL]
    do {
        destinationContents = try fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
    } catch {
        logger.error("failed destination migration check error=\(error)")
        return
    }

    guard destinationContents.isEmpty else {
        // If there are already files in the destination directory, do not attempt a migration
        logger.debug("skipping migration due to destinationContents=\(destinationContents)")
        return
    }

    let sourceContents: [URL]
    do {
        sourceContents = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    } catch {
        logger.error("failed source migration check error=\(error)")
        sourceContents = []
    }

    guard !sourceContents.isEmpty else {
        // If there are no files in the source directory, do not attempt a migration
        logger.debug("skipping migration due to sourceContents=\(sourceContents)")
        return
    }

    // Immediately write something to prevent the migration from happening multiple times
    let migrationSemaphoreFile = destination.appendingPathComponent(".migration")
    do {
        // This is so that we can easily write/read migration metadata later if we want (it's an empty json).
        let data = "{}\n".data(using: .utf8)!
        try data.write(to: migrationSemaphoreFile)
        logger.debug("wrote migrationSemaphoreFile=\(migrationSemaphoreFile)")
    } catch {
        logger.error("failed to write migrationSemaphoreFile=\(migrationSemaphoreFile), error=\(error)")
    }

    // Allow each owner to migrate their own stuff; failure here is ignored.
    NodeDistributionAnalyzerStoreHelper.migrate(from: source, to: destination)
    RateLimiter.migrate(from: source, to: destination)
    ServerDrivenConfiguration.migrate(from: source, to: destination)
    WorkloadLRUCache.migrate(from: source, to: destination)
    AttestationStore.migrate(from: source, to: destination)

    // Remove the source dir (if possible)
    do {
        try fileManager.removeItem(at: source)
        logger.debug("deleted migration source=\(source)")
    } catch {
        logger.error("unable to delete migration source error=\(error)")
    }
}
