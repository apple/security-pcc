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
import Logging
import NIOCore
import NIOFoundationCompat
import NIOPosix
import SystemPackage

import struct _NIOFileSystem.DirectoryFileHandle
import struct _NIOFileSystem.FileSystem
import struct _NIOFileSystem.FileSystemError
import enum _NIOFileSystem.OpenOptions
import struct _NIOFileSystem.ReadFileHandle
import struct _NIOFileSystem.WriteFileHandle

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Merge sentinel

/// Tracks which source URLs were merged into the output directory.
/// Used to detect configuration changes (sources added/removed/reordered).
private struct MergeSentinel: Codable, Equatable {
    var source_urls: [String]
}

private let mergeStagingDirectoryName = ".merge-staging"
private let mergeSentinelFileName = ".merge-metadata"

/// Names of files that should be skipped when merging from a staging directory.
private let stagingMetadataFileNames: Set<String> = [
    ".download-metadata",
    ".download-metadata.tmp",
    ".aea-download-metadata",
    ".aea-download-metadata.tmp",
    ".tmp_decrypt",
]

// MARK: - Public entry point

/// Downloads multiple sources that share the same `outputPath` and merges
/// their outputs into a single directory.
///
/// Each download is executed to a hidden staging subdirectory under
/// `outputPath/.merge-staging/<index>/`, reusing all existing sentinel-based
/// caching. After all downloads succeed, the staging directories are merged
/// into the real output directory using hard links.
///
/// - Parameters:
///   - configurations: The configurations that share the same output path,
///     paired with their original indices for logging.
///   - outputPath: The shared output directory.
///   - logger: Logger for the merge operation.
public func mergedDownloadAndExtract(
    configurations: [(index: Int, configuration: AEAConfiguration)],
    outputPath: String,
    logger: Logger
) async throws {
    precondition(configurations.count >= 2, "mergedDownloadAndExtract requires at least 2 configurations")

    let outputDir = FilePath(outputPath)
    let stagingBase = outputDir.appending(mergeStagingDirectoryName)
    let sentinelPath = outputDir.appending(mergeSentinelFileName)

    try await withMergeFileSystem(numberOfThreads: 2) { fileSystem in
        // Ensure the staging directory exists.
        try await fileSystem.createDirectory(at: stagingBase, withIntermediateDirectories: true)

        // Step 1: Check the merge sentinel for configuration changes.
        let currentSourceURLs = configurations.map(\.configuration.sourceURL)
        let existingSentinel = try await readMergeSentinel(
            at: sentinelPath,
            fileSystem: fileSystem,
            logger: logger
        )
        let configChanged = existingSentinel?.source_urls != currentSourceURLs

        if configChanged {
            logger.info(
                "Merge group configuration changed, invalidating staging directories",
                metadata: ["outputPath": "\(outputPath)"]
            )
            try await cleanStaleStagingDirectories(
                at: stagingBase,
                validCount: configurations.count,
                fileSystem: fileSystem,
                logger: logger
            )
        }

        // Step 2: Execute each download to its staging directory.
        var results: [DownloadResult] = []
        let total = configurations.count

        for (groupIndex, (globalIndex, var configuration)) in configurations.enumerated() {
            let stagingDir = stagingBase.appending("\(groupIndex)")

            // Ensure this staging directory exists.
            try await fileSystem.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            // Redirect output to staging.
            configuration.outputPath = stagingDir.string

            // Force re-download if config changed.
            if configChanged {
                configuration.force = true
            }

            logger.info(
                "Downloading for merge",
                metadata: [
                    "sourceURL": "\(configuration.sourceURL)",
                    "stagingDir": "\(stagingDir)",
                    "download": "\(groupIndex + 1)/\(total)",
                    "globalIndex": "\(globalIndex)",
                ]
            )

            let result = try await streamingDownloadAndExtract(
                logger: logger,
                configuration: configuration
            )
            results.append(result)
        }

        // Step 3: Decide whether to merge.
        let anyDownloaded = results.contains(.downloaded)
        let sentinelMissing = existingSentinel == nil

        guard anyDownloaded || sentinelMissing || configChanged else {
            logger.info(
                "All sources unchanged, skipping merge",
                metadata: ["outputPath": "\(outputPath)"]
            )
            return
        }

        // Step 4: Clear the output directory (preserving staging and sentinel).
        logger.info(
            "Merging staging directories into output",
            metadata: [
                "outputPath": "\(outputPath)",
                "stagingCount": "\(configurations.count)",
            ]
        )
        try await clearOutputDirectoryPreservingStaging(
            at: outputDir,
            fileSystem: fileSystem,
            logger: logger
        )

        // Step 5: Merge files from each staging directory.
        for groupIndex in 0..<configurations.count {
            let stagingDir = stagingBase.appending("\(groupIndex)")
            try await mergeFiles(
                from: stagingDir,
                to: outputDir,
                sourceURL: configurations[groupIndex].configuration.sourceURL,
                fileSystem: fileSystem,
                logger: logger
            )
        }

        // Step 6: Write the merge sentinel.
        try await writeMergeSentinel(
            MergeSentinel(source_urls: currentSourceURLs),
            at: sentinelPath,
            fileSystem: fileSystem,
            logger: logger
        )

        logger.info("Merge complete", metadata: ["outputPath": "\(outputPath)"])
    }
}

// MARK: - Merge sentinel I/O

private func readMergeSentinel(
    at path: FilePath,
    fileSystem: MergeFileSystem,
    logger: Logger
) async throws -> MergeSentinel? {
    guard let buffer = try await fileSystem.readFile(at: path) else {
        logger.debug("No merge sentinel found", metadata: ["path": "\(path)"])
        return nil
    }
    do {
        let sentinel = try JSONDecoder().decode(MergeSentinel.self, from: buffer)
        logger.debug(
            "Read merge sentinel",
            metadata: ["source_urls": "\(sentinel.source_urls)"]
        )
        return sentinel
    } catch {
        logger.warning(
            "Corrupt merge sentinel, will re-merge",
            metadata: ["error": "\(String(reportable: error))"]
        )
        return nil
    }
}

private func writeMergeSentinel(
    _ sentinel: MergeSentinel,
    at path: FilePath,
    fileSystem: MergeFileSystem,
    logger: Logger
) async throws {
    do {
        let buffer = try JSONEncoder().encodeAsByteBuffer(sentinel, allocator: .init())
        try await fileSystem.writeFileAtomically(buffer, at: path)
        logger.debug(
            "Wrote merge sentinel",
            metadata: ["source_urls": "\(sentinel.source_urls)"]
        )
    } catch {
        logger.warning(
            "Failed to write merge sentinel",
            metadata: ["error": "\(String(reportable: error))"]
        )
    }
}

// MARK: - Directory management

/// Clears the output directory while preserving the `.merge-staging` directory
/// and `.merge-metadata` sentinel file.
private func clearOutputDirectoryPreservingStaging(
    at directory: FilePath,
    fileSystem: MergeFileSystem,
    logger: Logger
) async throws {
    var removedCount = 0

    try await fileSystem.withContentsOfDirectory(at: directory) { entry in
        if entry == mergeStagingDirectoryName || entry == mergeSentinelFileName {
            return
        }
        try await fileSystem.removeItem(at: directory.appending(entry))
        removedCount += 1
    }

    logger.debug(
        "Cleared output directory (preserving staging)",
        metadata: ["path": "\(directory)", "removed": "\(removedCount)"]
    )
}

/// Removes staging directories whose index is >= `validCount` (stale from
/// a previous configuration with more downloads).
private func cleanStaleStagingDirectories(
    at stagingBase: FilePath,
    validCount: Int,
    fileSystem: MergeFileSystem,
    logger: Logger
) async throws {
    try await fileSystem.withContentsOfDirectory(at: stagingBase) { entry in
        guard let index = Int(entry), index >= validCount else {
            return
        }
        let path = stagingBase.appending(entry)
        do {
            try await fileSystem.removeItem(at: path)
            logger.info(
                "Removed stale staging directory",
                metadata: ["index": "\(index)", "path": "\(path)"]
            )
        } catch {
            logger.warning(
                "Failed to remove stale staging directory",
                metadata: ["path": "\(path)", "error": "\(String(reportable: error))"]
            )
        }
    }
}

// MARK: - File merging

/// Merges files from a staging directory into the output directory using
/// hard links (falling back to copies).
///
/// Directories are created first, then files are hard-linked concurrently.
/// If a file already exists at the target path (conflict from an earlier
/// source), the existing file is replaced and a warning is logged.
private func mergeFiles(
    from stagingDir: FilePath,
    to outputDir: FilePath,
    sourceURL: String,
    fileSystem: MergeFileSystem,
    logger: Logger
) async throws {
    // Phase 1: Enumerate all entries.
    var directories: [FilePath] = []
    var regularFiles: [FilePath] = []
    var symlinks: [FilePath] = []

    try await fileSystem.withDirectory(atPath: stagingDir) { handle in
        for try await entry in handle.listContents(recursive: true) {
            let entryName = entry.path.lastComponent?.string ?? ""

            // Skip staging metadata files.
            if stagingMetadataFileNames.contains(entryName) {
                continue
            }

            switch entry.type {
            case .directory:
                directories.append(entry.path)
            case .symlink:
                symlinks.append(entry.path)
            case .regular:
                regularFiles.append(entry.path)
            default:
                logger.debug(
                    "Skipping non-regular entry during merge",
                    metadata: ["path": "\(entry.path)", "type": "\(entry.type)"]
                )
            }
        }
    }

    // Phase 2: Create directories (sequentially, to ensure parents exist
    // before children).
    let stagingPrefix = stagingDir.string
    for dir in directories.sorted(by: { $0.string.count < $1.string.count }) {
        let relativePath = relativize(dir, base: stagingPrefix)
        let targetPath = outputDir.appending(relativePath)
        try await fileSystem.createDirectory(
            at: targetPath,
            withIntermediateDirectories: true
        )
    }

    // Phase 3: Hard-link regular files concurrently.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for file in regularFiles {
            let relativePath = relativize(file, base: stagingPrefix)
            let targetPath = outputDir.appending(relativePath)
            group.addTask {
                // Ensure parent directory exists (in case a file's parent
                // wasn't listed as a separate directory entry).
                let parent = targetPath.removingLastComponent()
                if parent != outputDir {
                    try await fileSystem.createDirectory(
                        at: parent,
                        withIntermediateDirectories: true
                    )
                }

                // Check for conflict.
                if await fileSystem.fileExists(at: targetPath) {
                    logger.warning(
                        "File conflict during merge, overwriting with later source",
                        metadata: [
                            "path": "\(relativePath)",
                            "sourceURL": "\(sourceURL)",
                        ]
                    )
                    try await fileSystem.removeItem(at: targetPath)
                }

                // Hard-link, falling back to copy.
                try await fileSystem.createLink(
                    at: targetPath,
                    existingFile: file
                )
            }
        }
        try await group.waitForAll()
    }

    // Phase 4: Recreate symlinks concurrently.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for symlink in symlinks {
            let relativePath = relativize(symlink, base: stagingPrefix)
            let targetPath = outputDir.appending(relativePath)
            group.addTask {
                let destination = try await fileSystem.destinationOfSymbolicLink(at: symlink)

                if await fileSystem.fileExists(at: targetPath) {
                    logger.warning(
                        "Symlink conflict during merge, overwriting with later source",
                        metadata: [
                            "path": "\(relativePath)",
                            "sourceURL": "\(sourceURL)",
                        ]
                    )
                    try await fileSystem.removeItem(at: targetPath)
                }

                try await fileSystem.createSymbolicLink(
                    at: targetPath,
                    withDestination: destination
                )
            }
        }
        try await group.waitForAll()
    }

    logger.debug(
        "Merged staging directory",
        metadata: [
            "stagingDir": "\(stagingDir)",
            "directories": "\(directories.count)",
            "files": "\(regularFiles.count)",
            "symlinks": "\(symlinks.count)",
        ]
    )
}

/// Strips the `base` prefix from `path` to produce a relative path.
private func relativize(_ path: FilePath, base: String) -> String {
    var pathString = path.string
    if pathString.hasPrefix(base) {
        pathString = String(pathString.dropFirst(base.count))
        // Remove leading separator.
        if pathString.hasPrefix("/") {
            pathString = String(pathString.dropFirst())
        }
    }
    return pathString
}

// MARK: - MergeFileSystem

/// Creates a ``MergeFileSystem`` backed by a thread pool with the given number
/// of threads, passes it to `body`, and shuts down the pool when `body` returns
/// or throws.
package func withMergeFileSystem<Result: Sendable>(
    numberOfThreads: Int,
    _ body: (MergeFileSystem) async throws -> Result
) async throws -> Result {
    let threadPool = NIOThreadPool(numberOfThreads: numberOfThreads)
    threadPool.start()
    let fileSystem = MergeFileSystem(threadPool: threadPool)
    do {
        let result = try await body(fileSystem)
        try await threadPool.shutdownGracefully()
        return result
    } catch {
        try? await threadPool.shutdownGracefully()
        throw error
    }
}

/// Wraps a ``FileSystem`` and its ``NIOThreadPool``, providing additional
/// operations (like hard-linking) that dispatch to the pool the same way
/// NIOFileSystem's built-in methods do.
///
/// The wrapper also bridges between `System.FilePath` (used by this module)
/// and NIOFileSystem's path type, so callers pass `FilePath` directly.
package struct MergeFileSystem: Sendable {
    let underlying: FileSystem
    let threadPool: NIOThreadPool

    init(threadPool: NIOThreadPool) {
        self.underlying = FileSystem(threadPool: threadPool)
        self.threadPool = threadPool
    }

    // MARK: Directory operations

    /// Opens the directory at `path`, passes the handle to `body`, and closes
    /// it when `body` returns or throws. The close is shielded from task
    /// cancellation to prevent file descriptor leaks.
    package func withDirectory(
        atPath path: FilePath,
        _ body: (_NIOFileSystem.DirectoryFileHandle) async throws -> Void
    ) async throws {
        let handle = try await underlying.openDirectory(atPath: path, options: .init())
        do {
            try await body(handle)
            try await Task { try await handle.close() }.value
        } catch {
            try? await Task { try await handle.close() }.value
            throw error
        }
    }

    func createDirectory(at path: FilePath, withIntermediateDirectories: Bool) async throws {
        try await underlying.createDirectory(
            at: path,
            withIntermediateDirectories: withIntermediateDirectories,
            permissions: nil
        )
    }

    /// Iterates the immediate children of the directory at `path`, calling
    /// `body` with each entry name. The directory handle is held open for the
    /// duration, avoiding TOCTOU races with concurrent modifications.
    func withContentsOfDirectory(
        at path: FilePath,
        _ body: (String) async throws -> Void
    ) async throws {
        try await withDirectory(atPath: path) { handle in
            for try await entry in handle.listContents(recursive: false) {
                if let name = entry.path.lastComponent?.string {
                    try await body(name)
                }
            }
        }
    }

    // MARK: File operations

    func removeItem(at path: FilePath) async throws {
        _ = try await underlying.removeItem(at: path)
    }

    func copyItem(at sourcePath: FilePath, to destinationPath: FilePath) async throws {
        try await underlying.copyItem(at: sourcePath, to: destinationPath)
    }

    /// Returns `true` if a file or directory exists at `path`.
    func fileExists(at path: FilePath) async -> Bool {
        do {
            let info = try await underlying.info(forFileAt: path, infoAboutSymbolicLink: true)
            return info != nil
        } catch {
            return false
        }
    }

    /// Opens `path` for reading, passes the handle to `body`, and closes it
    /// with a cancellation shield when `body` returns or throws.
    package func withFileForReading<Result: Sendable>(
        at path: FilePath,
        _ body: (ReadFileHandle) async throws -> Result
    ) async throws -> Result {
        let handle = try await underlying.openFile(forReadingAt: path, options: .init())
        do {
            let result = try await body(handle)
            try await Task { try await handle.close() }.value
            return result
        } catch {
            try? await Task { try await handle.close() }.value
            throw error
        }
    }

    /// Opens `path` for writing, passes the handle to `body`, and closes it
    /// with a cancellation shield when `body` returns or throws. Changes are
    /// made visible only on success.
    package func withFileForWriting(
        at path: FilePath,
        options: OpenOptions.Write,
        _ body: (WriteFileHandle) async throws -> Void
    ) async throws {
        let handle = try await underlying.openFile(forWritingAt: path, options: options)
        do {
            try await body(handle)
            try await Task { try await handle.close(makeChangesVisible: true) }.value
        } catch {
            try? await Task { try await handle.close(makeChangesVisible: false) }.value
            throw error
        }
    }

    /// Reads the entire contents of the file at `path`, or returns `nil` if
    /// the file does not exist.
    func readFile(at path: FilePath) async throws -> ByteBuffer? {
        do {
            return try await withFileForReading(at: path) { handle in
                try await handle.readToEnd(maximumSizeAllowed: .mebibytes(1))
            }
        } catch let error as FileSystemError where error.code == .notFound {
            return nil
        }
    }

    /// Writes `buffer` to `path` atomically. The file is written with changes
    /// only made visible on successful completion of the write.
    func writeFileAtomically(_ buffer: ByteBuffer, at path: FilePath) async throws {
        try await withFileForWriting(at: path, options: .newFile(replaceExisting: true)) { handle in
            try await handle.write(contentsOf: buffer, toAbsoluteOffset: 0)
        }
    }

    // MARK: Symlinks

    func createSymbolicLink(at linkPath: FilePath, withDestination destinationPath: FilePath) async throws {
        try await underlying.createSymbolicLink(at: linkPath, withDestination: destinationPath)
    }

    func destinationOfSymbolicLink(at path: FilePath) async throws -> FilePath {
        try await underlying.destinationOfSymbolicLink(at: path)
    }

    // MARK: Hard links

    /// Creates a hard link at `linkPath` pointing to the same inode as
    /// `existingFile`, dispatching the `link(2)` syscall to the thread pool.
    ///
    /// Both paths must be on the same filesystem. If hard-linking fails (e.g.
    /// cross-device or unsupported filesystem), falls back to a copy.
    func createLink(at linkPath: FilePath, existingFile: FilePath) async throws {
        let linked = try await threadPool.runIfActive {
            link(existingFile.string, linkPath.string) == 0
        }

        if !linked {
            try await underlying.copyItem(at: existingFile, to: linkPath)
        }
    }
}
