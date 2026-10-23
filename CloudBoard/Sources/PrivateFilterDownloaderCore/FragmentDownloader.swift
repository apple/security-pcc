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

import FilterCore
import Foundation
import os
import PrivateFilterCommon

/// Downloads a single fragment using async URLSession, replacing the callback-based
/// FragmentStateMachine + Promise/Future bridge with a sequential loop.
///
/// Each fragment downloads one chunk at a time — structured concurrency makes
/// the sequential flow explicit. No Mutex, no state machine, no deferred I/O.
/// Crash recovery uses the same SwiftData-backed ChunkDownloadStore.
struct FragmentDownloader: Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "FragmentDownloader"
    )

    let metadata: FragmentMetadata
    let rangeConfig: RangeDownloadConfig?
    let metricsSystem: any PrivateFilterMetricsSystem
    let filterID: FilterIDString

    private var useChunkedDownload: Bool {
        guard let rangeConfig, rangeConfig.enabled, let fileSize = self.metadata.fileSize else {
            return false
        }
        return fileSize > UInt64(rangeConfig.chunkSize)
    }

    // MARK: - Public entry point

    /// Download the fragment, handling chunked range requests and crash recovery.
    /// Called from within `retryWithBackoff` — throwing causes a retry.
    func download(using urlSession: URLSession) async throws {
        if self.useChunkedDownload {
            try await self.downloadChunked(using: urlSession)
        } else {
            try await self.downloadFull(using: urlSession)
        }
    }

    func verify() throws {
        let stagingURL = self.metadata.destination.appendingPathExtension("staging")
        let verifyStart = ContinuousClock.now
        let computedSHA256 = try computeSHA256(of: stagingURL)
        let hashDuration = ContinuousClock.now - verifyStart
        if computedSHA256 != self.metadata.sha256 {
            Self.logger.error("""
            Downloaded fragment doesn't have the expected SHA256 \
            FragmentID=\(self.metadata.id, privacy: .public) \
            Expected=\(self.metadata.sha256, privacy: .public) \
            Computed=\(computedSHA256, privacy: .public)
            """)
            try? FileManager.default.removeItem(at: stagingURL)
            throw FragmentDownloadError.sha256Mismatch(expected: self.metadata.sha256, actual: computedSHA256)
        }
        try FileManager.default.moveItem(at: stagingURL, to: self.metadata.destination)
        let totalDuration = ContinuousClock.now - verifyStart
        Self.logger.log("""
        Fragment verified. \
        FragmentID=\(self.metadata.id, privacy: .public) \
        SHA256Duration=\(hashDuration, privacy: .public) \
        TotalVerifyDuration=\(totalDuration, privacy: .public)
        """)
    }

    // MARK: - Full (non-chunked) download

    private func downloadFull(using urlSession: URLSession) async throws {
        let start = ContinuousClock.now
        Self.logger.log("""
        Starting full download. \
        FragmentID=\(self.metadata.id, privacy: .public) \
        URL=\(self.metadata.source, privacy: .public)
        """)
        var request = URLRequest(url: self.metadata.source)
        request.addValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Use data(for:) and write straight to .staging on the (cache) volume,
        // rather than a download task whose temp file lands in this process's own
        // ephemeral tmpdir and then has to be cross-volume copied to the volume.
        // The full path only runs for fragments at or below rangeChunkSize (larger
        // ones go chunked), so the in-memory buffer is bounded in the shipping
        // config. NB: if range downloads are disabled, every fragment uses this path
        // regardless of size and is buffered whole — acceptable for that non-default
        // config; switch to delegate streaming if airtight memory safety is needed.
        let (data, response) = try await urlSession.data(for: request)
        try self.checkHTTPSuccess(response)
        let stagingURL = self.metadata.destination.appendingPathExtension("staging")
        try data.write(to: stagingURL, options: .atomic)
        let duration = ContinuousClock.now - start
        Self.logger.log("""
        Fragment full download complete. \
        FragmentID=\(self.metadata.id, privacy: .public) \
        URL=\(self.metadata.source, privacy: .public) \
        Duration=\(duration, privacy: .public)
        """)
    }

    // MARK: - Chunked download

    private static let chunkRetryBaseDelay: Duration = .seconds(10)
    private static let chunkRetryDelayIncrement: Duration = .seconds(5)
    private static let chunkRetryMaxDelay: Duration = .seconds(30)

    private func downloadChunked(using urlSession: URLSession) async throws {
        guard let rangeConfig = self.rangeConfig,
              let fileSize = self.metadata.fileSize else {
            throw FragmentDownloadError.partialFileError(reason: "Range config or file size unavailable")
        }

        let chunkSize = rangeConfig.chunkSize
        let totalChunks = try ChunkDownloadStore.totalChunks(fileSize: fileSize, chunkSize: chunkSize)
        let resumeIndex = self.loadResumeInfo(totalChunks: totalChunks) ?? 0
        // We release the store before deleting the file or the backing database treats it as an error
        var store = try self.openOrCreateStore(resumeChunkIndex: resumeIndex, totalChunks: totalChunks)
        let chunkedStart = ContinuousClock.now

        // Per-chunk counter emissions are batched into one emission per fragment to keep
        // metric volume bounded; counts are flushed via defer so partial progress is reported
        // even on a thrown fragment.
        var chunksAttempted = 0
        var chunksSucceeded = 0
        defer {
            if chunksAttempted > 0 {
                self.metricsSystem.emit(
                    Metrics.RangeChunkAttemptCounter(
                        action: .increment(by: chunksAttempted),
                        dimensions: [.filterID: self.filterID]
                    )
                )
            }
            if chunksSucceeded > 0 {
                self.metricsSystem.emit(
                    Metrics.RangeChunkSuccessCounter(
                        action: .increment(by: chunksSucceeded),
                        dimensions: [.filterID: self.filterID]
                    )
                )
            }
        }

        for chunkIndex in resumeIndex ..< totalChunks {
            let start = Int64(chunkIndex) * chunkSize
            let end = min(start + chunkSize - 1, Int64(fileSize) - 1)
            let expectedSize = end - start + 1

            var request = URLRequest(url: self.metadata.source)
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            request.addValue("identity", forHTTPHeaderField: "Accept-Encoding")

            let chunkStart = ContinuousClock.now
            Self.logger.debug("""
            Starting range download. \
            FragmentID=\(self.metadata.id, privacy: .public) \
            URL=\(self.metadata.source, privacy: .public) \
            Range=bytes=\(start, privacy: .public)-\(end, privacy: .public) \
            Chunk=\(chunkIndex, privacy: .public)/\(totalChunks, privacy: .public)
            """)

            let (chunkData, _) = try await self.downloadChunkWithRetry(
                request: request,
                using: urlSession
            )
            chunksAttempted += 1

            guard chunkData.count == Int(expectedSize) else {
                Self.logger.error("""
                Chunk size mismatch. \
                FragmentID=\(self.metadata.id, privacy: .public) \
                Expected=\(expectedSize, privacy: .public) \
                Actual=\(chunkData.count, privacy: .public)
                """)
                throw FragmentDownloadError.partialFileError(
                    reason: "Chunk size mismatch: expected \(expectedSize) bytes, got \(chunkData.count)"
                )
            }
            chunksSucceeded += 1

            try self.appendChunkToPartialFile(data: chunkData)
            try store?.recordChunkComplete()
            let chunkDuration = ContinuousClock.now - chunkStart
            Self.logger.debug("""
            Chunk download complete. \
            FragmentID=\(self.metadata.id, privacy: .public) \
            Chunk=\(chunkIndex, privacy: .public)/\(totalChunks, privacy: .public) \
            Size=\(expectedSize, privacy: .public) \
            Duration=\(chunkDuration, privacy: .public)
            """)
        }

        let chunkedDuration = ContinuousClock.now - chunkedStart
        Self.logger.log("""
        All chunks downloaded, verifying. \
        FragmentID=\(self.metadata.id, privacy: .public) \
        Chunks=\(totalChunks, privacy: .public) \
        Duration=\(chunkedDuration, privacy: .public)
        """)

        let partialURL = self.metadata.destination.appendingPathExtension("partial")
        let stagingURL = self.metadata.destination.appendingPathExtension("staging")
        do {
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: stagingURL)
        } catch {
            store = nil
            self.cleanupChunkedState()
            throw error
        }
        store = nil
        self.cleanupChunkedState()
    }

    /// Retry a single chunk download for transient errors (5xx, timeouts,
    /// connection resets). Non-retryable errors (4xx) throw immediately.
    private func downloadChunkWithRetry(
        request: URLRequest,
        using urlSession: URLSession
    ) async throws -> (Data, URLResponse) {
        let maxAttempts = self.rangeConfig?.chunkRetryAttempts ?? 5
        var delay = Self.chunkRetryBaseDelay

        func backoff() async {
            try? await Task.sleep(for: delay)
            delay = min(delay + Self.chunkRetryDelayIncrement, Self.chunkRetryMaxDelay)
        }

        for attempt in 1 ... maxAttempts {
            do {
                let result = try await self.downloadChunkData(request: request, using: urlSession)
                return result
            } catch let error as URLError where self.isTransient(error) && attempt < maxAttempts {
                Self.logger.warning("""
                Transient chunk download error, retrying. \
                FragmentID=\(self.metadata.id, privacy: .public) \
                Attempt=\(attempt, privacy: .public)/\(maxAttempts, privacy: .public) \
                Error=\(error.localizedDescription, privacy: .public)
                """)
                await backoff()
            } catch let error as FragmentDownloadError where error.isTransientHTTP && attempt < maxAttempts {
                Self.logger.warning("""
                Transient HTTP error on chunk download, retrying. \
                FragmentID=\(self.metadata.id, privacy: .public) \
                Attempt=\(attempt, privacy: .public)/\(maxAttempts, privacy: .public) \
                Error=\(error, privacy: .public)
                """)
                await backoff()
            } catch where !(error is FragmentDownloadError) && attempt < maxAttempts {
                Self.logger.warning("""
                Chunk download error, retrying. \
                FragmentID=\(self.metadata.id, privacy: .public) \
                Attempt=\(attempt, privacy: .public)/\(maxAttempts, privacy: .public) \
                Error=\(error, privacy: .public)
                """)
                await backoff()
            }
        }
        return try await self.downloadChunkData(request: request, using: urlSession)
    }

    // data(for:) buffers the full response before we can check the status code.
    // If the server ignores Range and returns the entire file (HTTP 200), this
    // will spike memory and likely jetsam the process. Acceptable risk for now
    // since the normal 206 path is a bounded chunk.
    private func downloadChunkData(
        request: URLRequest,
        using urlSession: URLSession
    ) async throws -> (Data, URLResponse) {
        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw FragmentDownloadError.missingHTTPResponse
        }

        if (500 ... 599).contains(http.statusCode) {
            throw FragmentDownloadError.httpError(statusCode: http.statusCode)
        }

        if http.statusCode == 200 {
            throw FragmentDownloadError.rangeFallback
        }

        guard http.statusCode == 206 else {
            throw FragmentDownloadError.httpError(statusCode: http.statusCode)
        }

        return (data, response)
    }

    private func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // MARK: - HTTP validation

    private func checkHTTPSuccess(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FragmentDownloadError.missingHTTPResponse
        }
        let statusCode = httpResponse.statusCode
        guard (200 ..< 300).contains(statusCode) else {
            throw FragmentDownloadError.httpError(statusCode: statusCode)
        }
    }

    // MARK: - File operations

    private func appendChunkToPartialFile(data: Data) throws {
        let partialURL = self.metadata.destination.appendingPathExtension("partial")

        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }

        let writeHandle = try FileHandle(forWritingTo: partialURL)
        defer { try? writeHandle.close() }
        try writeHandle.seekToEnd()
        try writeHandle.write(contentsOf: data)
        fsync(writeHandle.fileDescriptor)
    }

    /// Remove all chunked-download state so the next attempt starts fresh.
    private func cleanupChunkedState() {
        let partialURL = self.metadata.destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)
        ChunkDownloadStore.cleanupSidecarFiles(destination: self.metadata.destination)
    }

    // MARK: - SwiftData store management

    private func openOrCreateStore(resumeChunkIndex: Int, totalChunks: Int) throws -> ChunkDownloadStore? {
        guard let rangeConfig = self.rangeConfig,
              let fileSize = self.metadata.fileSize else {
            return nil
        }

        let storeURL = ChunkDownloadStore.storeURL(for: self.metadata.destination)

        if resumeChunkIndex > 0 {
            do {
                return try ChunkDownloadStore.open(at: storeURL)
            } catch {
                Self.logger.warning("""
                Failed to open existing download store, creating fresh. \
                FragmentID=\(self.metadata.id, privacy: .public) \
                Error=\(error, privacy: .public)
                """)
                self.cleanupChunkedState()
            }
        } else {
            self.cleanupChunkedState()
        }

        return try ChunkDownloadStore.create(
            at: storeURL,
            fragmentID: self.metadata.id,
            expectedFileSize: fileSize,
            expectedSHA256: self.metadata.sha256,
            chunkSize: rangeConfig.chunkSize,
            totalChunks: totalChunks
        )
    }

    // MARK: - Crash recovery

    private func loadResumeInfo(totalChunks: Int) -> Int? {
        guard let rangeConfig = self.rangeConfig,
              let fileSize = self.metadata.fileSize else {
            return nil
        }

        let storeURL = ChunkDownloadStore.storeURL(for: self.metadata.destination)
        let partialURL = self.metadata.destination.appendingPathExtension("partial")

        guard let recovered = ChunkDownloadStore.recoverState(from: storeURL) else {
            self.cleanupChunkedState()
            return nil
        }

        guard recovered.fragmentID == self.metadata.id,
              recovered.expectedSHA256 == self.metadata.sha256,
              recovered.expectedFileSize == fileSize,
              recovered.chunkSize == rangeConfig.chunkSize,
              recovered.completedChunks >= 0,
              recovered.completedChunks <= recovered.totalChunks else {
            Self.logger.warning("""
            Stale or mismatched download state, starting fresh. \
            FragmentID=\(self.metadata.id, privacy: .public)
            """)
            self.cleanupChunkedState()
            return nil
        }

        guard recovered.completedChunks > 0 else {
            self.cleanupChunkedState()
            return nil
        }

        let expectedPartialSize = Int64(recovered.completedChunks) * rangeConfig.chunkSize
        // `Checksum.fileSize` goes through `NSNumber.uint64Value`, avoiding the
        // `as? Int64` pitfall that returns nil for a valid file whose size is
        // stored under a different NSNumber tag. A missing file throws → nil here.
        guard let actualSize = (try? Checksum.fileSize(path: partialURL.path)).map(Int64.init) else {
            Self.logger.warning("""
            Download state exists but partial file missing, starting fresh. \
            FragmentID=\(self.metadata.id, privacy: .public)
            """)
            self.cleanupChunkedState()
            return nil
        }

        if actualSize < expectedPartialSize {
            Self.logger.warning("""
            Partial file smaller than expected, starting fresh. \
            FragmentID=\(self.metadata.id, privacy: .public) \
            Expected=\(expectedPartialSize, privacy: .public) \
            Actual=\(actualSize, privacy: .public)
            """)
            self.cleanupChunkedState()
            return nil
        }

        if actualSize > expectedPartialSize {
            Self.logger.info("""
            Truncating partial file to committed boundary. \
            FragmentID=\(self.metadata.id, privacy: .public) \
            TruncateTo=\(expectedPartialSize, privacy: .public) \
            ActualSize=\(actualSize, privacy: .public)
            """)
            do {
                let handle = try FileHandle(forWritingTo: partialURL)
                defer { try? handle.close() }
                handle.truncateFile(atOffset: UInt64(expectedPartialSize))
                fsync(handle.fileDescriptor)
            } catch {
                Self.logger.error("""
                Failed to truncate partial file, starting fresh. \
                FragmentID=\(self.metadata.id, privacy: .public) \
                Error=\(error, privacy: .public)
                """)
                self.cleanupChunkedState()
                return nil
            }
        }

        Self.logger.info("""
        Resuming chunked download from persisted state. \
        FragmentID=\(self.metadata.id, privacy: .public) \
        CompletedChunks=\(recovered.completedChunks, privacy: .public)/\(totalChunks, privacy: .public)
        """)
        return recovered.completedChunks
    }
}
