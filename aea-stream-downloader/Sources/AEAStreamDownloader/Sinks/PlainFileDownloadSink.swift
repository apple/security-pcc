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

import Logging
import NIOCore
import Synchronization

import struct SystemPackage.FilePermissions
import struct _NIOFileSystem.FileSystem
import enum _NIOFileSystem.OpenOptions
import struct _NIOFileSystem.WriteFileHandle
import func _NIOFileSystem.withFileSystem

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// NIOFileSystem's public API takes `SystemPackage.FilePermissions`. On macOS
// this file also imports Apple's `System`, whose `FilePermissions` is a
// different type, so we spell out the SystemPackage one explicitly.

/// Permissions applied to directories created by ``PlainFileDownloadSink`` (0o755).
private let plainFileDirectoryPermissions: SystemPackage.FilePermissions = [
    .ownerReadWriteExecute,
    .groupReadExecute,
    .otherReadExecute,
]

/// Permissions applied to files created by ``PlainFileDownloadSink`` (0o744).
private let plainFileFilePermissions: SystemPackage.FilePermissions = [
    .ownerReadWriteExecute,
    .groupRead,
    .otherRead,
]

/// A ``DownloadSink`` that writes raw bytes directly to output files.
///
/// For each entry, the file is pre-allocated via `ftruncate`, then chunks are
/// written concurrently at their offsets using `_NIOFileSystem`'s `pwrite`-based I/O.
/// Backpressure is provided by an ``AsyncSemaphore``: at most
/// `threadPoolSize * writeParallelismMultiplier` chunks may be in flight at once.
struct PlainFileDownloadSink: DownloadSink {
    typealias RangeRequests = AsyncStream<RangeRequest>

    let outputDir: FilePath
    let chunkSize: Int
    let threadPoolSize: Int
    let writeParallelismMultiplier: Int
    let logger: Logger

    private let semaphore: AsyncSemaphore
    private let handleMap: HandleMap

    init(
        outputDirectory: FilePath,
        chunkSize: Int,
        threadPoolSize: Int = 2,
        writeParallelismMultiplier: Int = 4,
        logger: Logger
    ) {
        self.outputDir = outputDirectory
        self.chunkSize = chunkSize
        self.threadPoolSize = threadPoolSize
        self.writeParallelismMultiplier = writeParallelismMultiplier
        self.logger = logger
        self.semaphore = AsyncSemaphore(permits: threadPoolSize * writeParallelismMultiplier)
        self.handleMap = HandleMap()
    }

    var sentinelPath: FilePath {
        outputDir.appending(".download-metadata")
    }

    var shouldClearOutputDirectory: Bool { true }

    var outputDirectory: FilePath { outputDir }

    func process(_ data: ByteBuffer, for request: RangeRequest) async throws {
        let handle = handleMap.get(for: request.sourceEntry.path)!
        try await handle.write(contentsOf: data.readableBytesView, toAbsoluteOffset: Int64(request.offset))
    }

    func requestCompleted(for request: RangeRequest) {
        semaphore.release()
    }

    func withRangeRequests<Result: Sendable>(
        entries: [SourceContentsEntry],
        _ body: (AsyncStream<RangeRequest>, Self) async throws -> Result
    ) async throws -> Result {
        let chunkSize = self.chunkSize
        let semaphore = self.semaphore

        logger.info(
            "Starting plain file download",
            metadata: [
                "outputDir": "\(outputDir)",
                "entryCount": "\(entries.count)",
                "chunkSize": "\(chunkSize)",
                "threadPoolSize": "\(threadPoolSize)",
                "writeParallelism": "\(threadPoolSize * writeParallelismMultiplier)",
            ]
        )

        return try await withFileSystem(numberOfThreads: threadPoolSize) { fileSystem in
            try await fileSystem.createDirectories(
                forEntries: entries,
                under: outputDir
            )

            let handles = try await fileSystem.openAndResizeFiles(
                for: entries,
                under: outputDir
            )
            handleMap.setAll(handles)
            do {
                let (rangeStream, continuation) = AsyncStream<RangeRequest>.makeStream()

                let result = try await withThrowingTaskGroup(of: Result?.self) { group in
                    group.addTask {
                        // Producer: generate range requests with backpressure.
                        defer { continuation.finish() }
                        for entry in entries {
                            var offset = 0
                            while offset < entry.size {
                                let length = min(chunkSize, entry.size - offset)
                                try await semaphore.acquire()
                                continuation.yield(
                                    RangeRequest(
                                        sourceEntry: entry,
                                        offset: off_t(offset),
                                        length: length
                                    )
                                )
                                offset += length
                            }
                        }
                        return nil
                    }

                    // Consumer: run the caller's body.
                    let result = try await body(rangeStream, self)

                    // Cancel the producer if it hasn't finished yet.
                    group.cancelAll()

                    return result
                }

                try await handles.closeAll(makeChangesVisible: true, logger: logger)
                handleMap.clear()
                return result
            } catch {
                try? await handles.closeAll(makeChangesVisible: false, logger: logger)
                handleMap.clear()
                throw error
            }
        }
    }
}

// MARK: - Thread-safe handle storage

/// Thread-safe map from file paths to write file handles.
private final class HandleMap: Sendable {
    private let storage = Mutex<[FilePath: WriteFileHandle]>([:])

    func setAll(_ handles: [FilePath: WriteFileHandle]) {
        storage.withLock { $0 = handles }
    }

    func get(for path: FilePath) -> WriteFileHandle? {
        storage.withLock { $0[path] }
    }

    func clear() {
        storage.withLock { $0.removeAll() }
    }
}

// MARK: - Helper extensions

extension [SourceContentsEntry] {
    /// Returns the set of parent directories needed to write all entries
    /// under `outputDir`, excluding `outputDir` itself.
    fileprivate func parentDirectories(under outputDir: FilePath) -> Set<FilePath> {
        var dirs = Set<FilePath>()
        for entry in self {
            let parent = outputDir.appending(entry.path.components).removingLastComponent()
            if parent != outputDir {
                dirs.insert(parent)
            }
        }
        return dirs
    }
}

extension FileSystem {
    /// Creates all parent directories needed to write `entries` under `outputDir`.
    fileprivate func createDirectories(
        forEntries entries: [SourceContentsEntry],
        under outputDir: FilePath
    ) async throws {
        for dir in entries.parentDirectories(under: outputDir) {
            try await createDirectory(
                at: .init(dir.string),
                withIntermediateDirectories: true,
                permissions: plainFileDirectoryPermissions
            )
        }
    }

    /// Opens a new file for `entry` under `outputDir`, pre-sized to `entry.size`.
    fileprivate func openAndResizeFile(
        for entry: SourceContentsEntry,
        under outputDir: FilePath
    ) async throws -> WriteFileHandle {
        let filePath = outputDir.appending(entry.path.components)
        let handle = try await openFile(
            forWritingAt: .init(filePath.string),
            options: .newFile(
                replaceExisting: true,
                permissions: plainFileFilePermissions
            )
        )
        try await handle.resize(to: .bytes(Int64(entry.size)))
        return handle
    }

    /// Opens and pre-sizes files for all entries concurrently.
    fileprivate func openAndResizeFiles(
        for entries: [SourceContentsEntry],
        under outputDir: FilePath
    ) async throws -> [FilePath: WriteFileHandle] {
        try await withThrowingTaskGroup(
            of: (FilePath, WriteFileHandle).self
        ) { group in
            for entry in entries {
                group.addTask {
                    let handle = try await self.openAndResizeFile(
                        for: entry,
                        under: outputDir
                    )
                    return (entry.path, handle)
                }
            }

            var handles: [FilePath: WriteFileHandle] = [:]
            for try await (path, handle) in group {
                handles[path] = handle
            }
            return handles
        }
    }
}

extension [FilePath: WriteFileHandle] {
    /// Closes every handle, shielded from task cancellation.
    ///
    /// Individual `close()` errors are caught so that all handles are closed
    /// even if some fail. The first error is rethrown after every handle has
    /// been closed. The operation runs inside an unstructured `Task` so that
    /// cancellation of the calling task does not prevent the kernel file
    /// descriptors from being released.
    fileprivate func closeAll(makeChangesVisible: Bool, logger: Logger) async throws {
        try await forAllHandlesWithCancellationShield(logger: logger) { handle in
            try await handle.close(makeChangesVisible: makeChangesVisible)
        }
    }

    /// Runs `body` on every handle inside a cancellation-shielded `Task`.
    ///
    /// Individual errors are caught so that `body` is called for every handle
    /// regardless of earlier failures. The first error is rethrown after all
    /// handles have been visited.
    func forAllHandlesWithCancellationShield(
        logger: Logger,
        _ body: @escaping @Sendable (WriteFileHandle) async throws -> Void
    ) async throws {
        try await Task {
            var firstError: (any Error)?
            for (path, handle) in self {
                do {
                    try await body(handle)
                } catch {
                    logger.warning(
                        "Failed to close file handle",
                        metadata: [
                            "path": "\(path)",
                            "error": "\(error)",
                        ]
                    )
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
            if let firstError {
                throw firstError
            }
        }.value
    }
}
