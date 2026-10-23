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
import SwiftData

/// SwiftData model for tracking chunked download progress.
///
/// One row per database. Each fragment gets its own database file at `{destination}.download-db`.
@Model
final class ChunkDownloadRecord {
    var fragmentID: String
    var expectedFileSize: UInt64
    var expectedSHA256: String
    var chunkSize: Int64
    var totalChunks: Int
    var completedChunks: Int

    init(
        fragmentID: String,
        expectedFileSize: UInt64,
        expectedSHA256: String,
        chunkSize: Int64,
        totalChunks: Int,
        completedChunks: Int = 0
    ) {
        self.fragmentID = fragmentID
        self.expectedFileSize = expectedFileSize
        self.expectedSHA256 = expectedSHA256
        self.chunkSize = chunkSize
        self.totalChunks = totalChunks
        self.completedChunks = completedChunks
    }
}

/// Configuration for range-based chunked downloads.
struct RangeDownloadConfig: Sendable {
    let enabled: Bool
    /// Chunk size in bytes. Should be a power of two (e.g. 16_777_216 = 16 MiB).
    let chunkSize: Int64
    /// Maximum retry attempts per chunk before failing the fragment.
    let chunkRetryAttempts: Int
}

/// Recovered state from a previous chunked download.
///
/// Separate from `ChunkDownloadRecord` because `@Model` types are bound to their
/// `ModelContext` and cannot be passed across isolation boundaries.
struct RecoveredDownloadState: Sendable {
    let fragmentID: String
    let expectedFileSize: UInt64
    let expectedSHA256: String
    let chunkSize: Int64
    let totalChunks: Int
    let completedChunks: Int
}

/// Per-fragment SwiftData store for crash-safe chunk progress tracking.
///
/// Wraps a `ModelContainer` + `ModelContext` pointing at a per-fragment SQLite file.
/// SQLite WAL journaling provides crash safety — incomplete transactions are
/// rolled back automatically on recovery.
///
/// Not `Sendable` — must be used from a single task (the fragment's download task).
final class ChunkDownloadStore {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ChunkDownloadStore"
    )

    private let container: ModelContainer
    private let context: ModelContext

    private init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
    }

    /// Create a new store at the given URL and insert the initial record.
    static func create(
        at storeURL: URL,
        fragmentID: String,
        expectedFileSize: UInt64,
        expectedSHA256: String,
        chunkSize: Int64,
        totalChunks: Int
    ) throws -> ChunkDownloadStore {
        let config = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(for: ChunkDownloadRecord.self, configurations: config)
        let store = ChunkDownloadStore(container: container)

        let record = ChunkDownloadRecord(
            fragmentID: fragmentID,
            expectedFileSize: expectedFileSize,
            expectedSHA256: expectedSHA256,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            completedChunks: 0
        )
        store.context.insert(record)
        try store.context.save()

        Self.logger.info("""
        Created download store. \
        FragmentID=\(fragmentID, privacy: .public) \
        TotalChunks=\(totalChunks, privacy: .public) \
        StoreURL=\(storeURL.path, privacy: .public)
        """)

        return store
    }

    /// Create an in-memory store for testing.
    static func createInMemory(
        fragmentID: String,
        expectedFileSize: UInt64,
        expectedSHA256: String,
        chunkSize: Int64,
        totalChunks: Int
    ) throws -> ChunkDownloadStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ChunkDownloadRecord.self, configurations: config)
        let store = ChunkDownloadStore(container: container)

        let record = ChunkDownloadRecord(
            fragmentID: fragmentID,
            expectedFileSize: expectedFileSize,
            expectedSHA256: expectedSHA256,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            completedChunks: 0
        )
        store.context.insert(record)
        try store.context.save()

        return store
    }

    /// Open an existing store for resuming a download.
    static func open(at storeURL: URL) throws -> ChunkDownloadStore {
        let config = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(for: ChunkDownloadRecord.self, configurations: config)
        return ChunkDownloadStore(container: container)
    }

    /// Record that a chunk has been completed. Increments `completedChunks` and saves.
    func recordChunkComplete() throws {
        let descriptor = FetchDescriptor<ChunkDownloadRecord>()
        let records = try self.context.fetch(descriptor)
        guard let record = records.first else {
            throw ChunkDownloadStoreError.noRecord
        }
        record.completedChunks += 1
        try self.context.save()
    }

    /// Recover state from a database on disk. Returns nil if the database is
    /// missing, corrupt, or contains no records.
    static func recoverState(from storeURL: URL) -> RecoveredDownloadState? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }
        do {
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(for: ChunkDownloadRecord.self, configurations: config)
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<ChunkDownloadRecord>()
            let records = try context.fetch(descriptor)
            guard let record = records.first else {
                return nil
            }
            return RecoveredDownloadState(
                fragmentID: record.fragmentID,
                expectedFileSize: record.expectedFileSize,
                expectedSHA256: record.expectedSHA256,
                chunkSize: record.chunkSize,
                totalChunks: record.totalChunks,
                completedChunks: record.completedChunks
            )
        } catch {
            self.logger.warning("""
            Failed to recover download state from database. \
            StoreURL=\(storeURL.path, privacy: .public) \
            Error=\(error, privacy: .public)
            """)
            return nil
        }
    }

    /// Filename suffixes (relative to a fragment's final name) for chunked-download
    /// sidecar files. `.staging` (used by the full-download path) is intentionally
    /// not included. Single source of truth shared with `FilterCacheReconciler`.
    static let sidecarSuffixes = [".partial", ".download-db", ".download-db-wal", ".download-db-shm"]

    /// Delete all sidecar files for a fragment: `.partial`, `.download-db`, `-wal`, `-shm`.
    static func cleanupSidecarFiles(destination: URL) {
        let fm = FileManager.default
        for suffix in Self.sidecarSuffixes {
            try? fm.removeItem(at: URL(fileURLWithPath: destination.path + suffix))
        }
    }

    /// Compute the total number of chunks for a given file size and chunk size.
    static func totalChunks(fileSize: UInt64, chunkSize: Int64) throws -> Int {
        guard chunkSize > 0 else {
            throw ChunkDownloadStoreError.invalidChunkSize(chunkSize)
        }
        let fs = Int64(fileSize)
        return Int((fs + chunkSize - 1) / chunkSize)
    }

    /// URL for the download database given a fragment destination.
    static func storeURL(for destination: URL) -> URL {
        destination.appendingPathExtension("download-db")
    }
}

@available(*, unavailable)
extension ChunkDownloadStore: Sendable {}

enum ChunkDownloadStoreError: Error, CustomStringConvertible {
    case noRecord
    case invalidChunkSize(Int64)

    var description: String {
        switch self {
        case .noRecord:
            "No ChunkDownloadRecord found in database"
        case .invalidChunkSize(let size):
            "chunkSize must be positive, got \(size)"
        }
    }
}

extension ChunkDownloadStoreError: ReportableError {
    var publicDescription: String {
        switch self {
        case .noRecord:
            "noRecord"
        case .invalidChunkSize:
            "invalidChunkSize"
        }
    }
}
