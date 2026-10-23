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

import CAppleArchive
import Crypto
import Dispatch
import Foundation
import Logging
import NIOCore
import Synchronization

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

/// A ``DownloadSink`` that decrypts and extracts an AEA (Apple Encrypted Archive)
/// stream on the fly.
///
/// The sink encapsulates the `AEAAsyncDecryptionStream` lifecycle, a dedicated
/// `DispatchQueue` thread running the GetRange/Process state machine, and a
/// ``ResultQueue`` that bridges fetched data from Swift concurrency back to that
/// thread.
public struct AEADownloadSink: DownloadSink {
    public typealias RangeRequests = AsyncStream<RangeRequest>

    let outputDir: FilePath
    let symmetricKeyBytes: [UInt8]
    let expectedArchiveIdentifierSHA256: Data?
    let chunkSize: Int
    let allocLimit: Int
    let threadCount: Int
    let skipPaddingCheck: Bool
    let logger: Logger

    /// Thread-safe queue for passing downloaded range data from the caller
    /// back to the dedicated GetRange/Process thread.
    private let resultQueue: ResultQueue

    /// Thread-safe box for propagating the first error between the dedicated
    /// thread and the async caller.
    private let errorBox: ErrorBox

    public init(
        outputDir: FilePath,
        symmetricKeyBytes: [UInt8],
        expectedArchiveIdentifierSHA256: Data? = nil,
        chunkSize: Int,
        allocLimit: Int = 0,
        threadCount: Int = 0,
        skipPaddingCheck: Bool = false,
        logger: Logger
    ) {
        self.outputDir = outputDir
        self.symmetricKeyBytes = symmetricKeyBytes
        self.expectedArchiveIdentifierSHA256 = expectedArchiveIdentifierSHA256
        self.chunkSize = chunkSize
        self.allocLimit = allocLimit
        self.threadCount = threadCount
        self.skipPaddingCheck = skipPaddingCheck
        self.logger = logger
        self.resultQueue = ResultQueue()
        self.errorBox = ErrorBox()
    }

    public var sentinelPath: FilePath {
        outputDir.appending(".aea-download-metadata")
    }

    public var shouldClearOutputDirectory: Bool { true }

    public var outputDirectory: FilePath { outputDir }

    public func process(_ data: ByteBuffer, for request: RangeRequest) async throws {
        resultQueue.enqueue(offset: request.offset, data: data)
    }

    public func requestCompleted(for request: RangeRequest) {}

    public func withRangeRequests<Result: Sendable>(
        entries: [SourceContentsEntry],
        _ body: (AsyncStream<RangeRequest>, Self) async throws -> Result
    ) async throws -> Result {
        guard entries.count == 1 else {
            throw ConfigurationError.multipleFilesNotSupported(count: entries.count)
        }
        let entry = entries[0]

        // Local bindings for Sendable captures.
        let keyData = symmetricKeyBytes
        let expectedIdentifier = expectedArchiveIdentifierSHA256
        let logger = self.logger
        let errorBox = self.errorBox

        let topology = discoverNUMATopology(logger: logger)
        logNUMATopology(topology, logger: logger)

        logger.info(
            "Starting streaming download and extract",
            metadata: [
                "outputDir": "\(outputDir)",
                "chunkSize": "\(chunkSize)",
                "allocLimit": "\(allocLimit)",
                "threadCount": "\(threadCount)",
            ]
        )

        // Remove any stale .tmp_decrypt directory from a previous interrupted run.
        let tmpDecryptPath = outputDir.appending(".tmp_decrypt")
        tmpDecryptPath.withCString { cPath in
            var st = stat()
            if stat(cPath, &st) == 0 {
                logger.info(
                    "Removing stale .tmp_decrypt directory",
                    metadata: ["path": "\(tmpDecryptPath)"]
                )
                try? FileManager.default.removeItem(atPath: String(cString: cPath))
            }
        }

        // Build AEA callbacks.

        let identifierValidated = Mutex(false)

        let contextCallback: AEAContextCallback = { rawContext in
            let setKeyRC = setSymmetricKey(keyData, on: rawContext)
            guard setKeyRC == 0 else { return setKeyRC }

            // Only validate after the prologue has been authenticated.
            guard let expectedIdentifier, isContextAuthenticated(rawContext) else { return 0 }

            guard let actualIdentifier = readArchiveIdentifier(from: rawContext) else {
                logger.warning("Unable to read archive identifier from context")
                errorBox.set(AEADownloaderError.archiveIdentifierMismatch)
                return -1
            }

            guard SHA256.hash(data: actualIdentifier) == expectedIdentifier else {
                logger.warning("Archive identifier mismatch — aborting extraction")
                errorBox.set(AEADownloaderError.archiveIdentifierMismatch)
                return -1
            }

            identifierValidated.withLock { $0 = true }
            logger.debug("Archive identifier validated successfully")
            return 0
        }

        // Slot carrying the entry type discovered in EXTRACT_BEGIN, consumed in EXTRACT_ATTRIBUTES.
        // AppleArchive fires BEGIN and ATTRIBUTES back-to-back on the same thread inside the
        // header-parsing state machine, so a single slot is sufficient — no need for a path-keyed map.
        let pendingEntryType = Mutex<UInt8?>(nil)

        let entryMessageCallback: AEAEntryMessageCallback = { message, path, data in
            switch message {
            case __AA_ENTRY_MESSAGE_EXTRACT_BEGIN.rawValue:
                handleExtractBegin(
                    data: data,
                    path: path,
                    pendingType: pendingEntryType,
                    logger: logger
                )
            case __AA_ENTRY_MESSAGE_EXTRACT_ATTRIBUTES.rawValue:
                handleExtractAttributes(
                    data: data,
                    path: path,
                    pendingType: pendingEntryType,
                    logger: logger
                )
            default:
                break
            }
            return 0
        }

        let progressCallback: AEAProgressCallback = { percent in
            logger.info("Progress", metadata: ["percent": "\(percent)"])
            return 0
        }

        let asyncStream = try AEAAsyncDecryptionStream(
            extractTo: outputDir,
            chunkSize: chunkSize,
            allocLimit: allocLimit,
            threadCount: threadCount,
            skipPaddingCheck: skipPaddingCheck,
            contextCallback: contextCallback,
            entryMessageCallback: entryMessageCallback,
            progressCallback: progressCallback
        )
        logger.debug("Opened async decrypt+extract stream")

        let resultQueue = self.resultQueue
        let (rangeStream, rangeContinuation) = AsyncStream<RangeRequest>.makeStream()

        let threadDone = DispatchSemaphore(value: 0)
        let dedicatedQueue = DispatchQueue(label: "aea-async-stream")

        dedicatedQueue.async {
            defer { threadDone.signal() }

            var loopError: (any Error)?

            outerLoop: while true {
                let (rc, nbyte, offset) = asyncStream.getRange()
                logger.trace(
                    "GetRange returned",
                    metadata: ["rc": "\(rc)", "offset": "\(offset)", "nbyte": "\(nbyte)"]
                )

                if rc < 0 {
                    loopError = AEADownloaderError.asyncStreamGetRangeFailed(rc)
                    break
                }

                if rc == 1 && nbyte == 0 {
                    // Done — all ranges have been requested.
                    break
                }

                if rc == 0 {
                    logger.trace("GetRange returned busy, draining results")
                    let (batch, _) = resultQueue.dequeueAll()
                    if !batch.isEmpty {
                        for item in batch {
                            var buf = item.data
                            let processRC = buf.withUnsafeMutableReadableBytes { ptr in
                                asyncStream.process(
                                    data: ptr.baseAddress!,
                                    count: ptr.count,
                                    offset: item.offset
                                )
                            }
                            logger.trace(
                                "Process returned",
                                metadata: [
                                    "rc": "\(processRC)", "offset": "\(item.offset)",
                                    "size": "\(item.data.readableBytes)",
                                ]
                            )
                            if processRC < 0 {
                                loopError = AEADownloaderError.asyncStreamProcessFailed(processRC)
                                break outerLoop
                            }
                        }
                    }

                    // Check if there's been an error from downloads.
                    if let e = errorBox.get() {
                        loopError = e
                        break outerLoop
                    }

                    // Brief sleep to avoid busy-waiting.
                    Thread.sleep(forTimeInterval: 0.001)
                    continue
                }

                // rc == 1, nbyte > 0: request this range.
                rangeContinuation.yield(RangeRequest(sourceEntry: entry, offset: offset, length: nbyte))

                // Drain any available results.
                let (batch, _) = resultQueue.dequeueAll()
                for item in batch {
                    var buf = item.data
                    let processRC = buf.withUnsafeMutableReadableBytes { ptr in
                        asyncStream.process(
                            data: ptr.baseAddress!,
                            count: ptr.count,
                            offset: item.offset
                        )
                    }
                    logger.trace(
                        "Process returned",
                        metadata: [
                            "rc": "\(processRC)", "offset": "\(item.offset)",
                            "size": "\(item.data.readableBytes)",
                        ]
                    )
                    if processRC < 0 {
                        loopError = AEADownloaderError.asyncStreamProcessFailed(processRC)
                        break outerLoop
                    }
                }
            }

            logger.debug("GetRange/Process loop completed")

            // Signal no more ranges.
            rangeContinuation.finish()

            // Drain any remaining results.
            if loopError == nil {
                logger.debug("Draining remaining in-flight downloads")
                var finished = false
                while !finished {
                    let (batch, f) = resultQueue.dequeueAll()
                    finished = f
                    for item in batch {
                        var buf = item.data
                        let processRC = buf.withUnsafeMutableReadableBytes { ptr in
                            asyncStream.process(
                                data: ptr.baseAddress!,
                                count: ptr.count,
                                offset: item.offset
                            )
                        }
                        logger.trace(
                            "Process returned",
                            metadata: [
                                "rc": "\(processRC)", "offset": "\(item.offset)",
                                "size": "\(item.data.readableBytes)",
                            ]
                        )
                        if processRC < 0 {
                            loopError = AEADownloaderError.asyncStreamProcessFailed(processRC)
                            break
                        }
                    }
                    if loopError != nil { break }
                }
            }

            if let e = loopError {
                errorBox.set(e)
            }
            logger.debug("Main loop complete")
        }

        // Call body, capturing the result.
        let bodyResult: Swift.Result<Result, any Error>
        do {
            let result = try await body(rangeStream, self)
            bodyResult = .success(result)
        } catch {
            bodyResult = .failure(error)
        }

        // Cleanup: signal no more data, then wait for the dedicated thread.
        resultQueue.markFinished()

        if case .failure = bodyResult {
            asyncStream.cancel()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                wait(threadDone)
                continuation.resume()
            }
        }

        logger.debug("Task group complete")

        // Close the stream — finalizes extraction.
        if errorBox.get() != nil {
            logger.warning(
                "Cancelling async stream",
                metadata: ["error": "\(String(reportable: errorBox.get()))"]
            )
            asyncStream.cancel()
        }

        let closeRC = asyncStream.close()
        logger.debug("AsyncByteStream closed", metadata: ["rc": "\(closeRC)"])
        if closeRC < 0 && errorBox.get() == nil {
            if case .success = bodyResult {
                throw AEADownloaderError.asyncStreamCloseFailed(closeRC)
            }
        }

        // Check for errors from the dedicated thread.
        if let error = errorBox.get() {
            throw error
        }

        // Ensure digest validation actually ran if it was expected.
        if expectedIdentifier != nil && !identifierValidated.withLock({ $0 }) {
            throw AEADownloaderError.archiveIdentifierNotValidated
        }

        return try bodyResult.get()
    }
}

// MARK: - AEA context helpers

/// Sets the symmetric key on an AEA context.
///
/// - Returns: 0 on success, a negative error code on failure.
package func setSymmetricKey(_ key: [UInt8], on context: __AEAContext) -> Int32 {
    key.withUnsafeBufferPointer { keyBuf in
        __AEAContextSetFieldBlob(
            context,
            __AEA_CONTEXT_FIELD_SYMMETRIC_KEY.rawValue,
            __AEA_CONTEXT_FIELD_REPRESENTATION_RAW.rawValue,
            keyBuf.baseAddress!,
            keyBuf.count
        )
    }
}

/// Reads the archive identifier blob from an AEA context.
///
/// - Returns: The raw identifier bytes, or `nil` if not available.
package func readArchiveIdentifier(from context: __AEAContext) -> [UInt8]? {
    var idSize: size_t = 0
    let queryRC = __AEAContextGetFieldBlob(
        context,
        __AEA_CONTEXT_FIELD_ARCHIVE_IDENTIFIER.rawValue,
        __AEA_CONTEXT_FIELD_REPRESENTATION_RAW.rawValue,
        0,
        nil,
        &idSize
    )
    guard queryRC == 0, idSize > 0 else { return nil }

    var identifier = [UInt8](repeating: 0, count: idSize)
    _ = __AEAContextGetFieldBlob(
        context,
        __AEA_CONTEXT_FIELD_ARCHIVE_IDENTIFIER.rawValue,
        __AEA_CONTEXT_FIELD_REPRESENTATION_RAW.rawValue,
        idSize,
        &identifier,
        nil
    )
    return identifier
}

/// Returns whether the AEA context has been fully authenticated
/// (i.e. the prologue has been decrypted and sizes are available).
package func isContextAuthenticated(_ context: __AEAContext) -> Bool {
    __AEAContextGetFieldUInt(context, __AEA_CONTEXT_FIELD_RAW_SIZE.rawValue) > 0
}

// MARK: - Thread-safe result queue

/// A simple thread-safe queue for passing downloaded range data from Swift concurrency tasks
/// back to the dedicated GetRange/Process thread.
private final class ResultQueue: Sendable {
    private struct State {
        var results: [(offset: off_t, data: ByteBuffer)] = []
        var finished = false
    }

    private let storage = Mutex(State())

    func enqueue(offset: off_t, data: ByteBuffer) {
        storage.withLock { $0.results.append((offset: offset, data: data)) }
    }

    func markFinished() {
        storage.withLock { $0.finished = true }
    }

    func dequeueAll() -> (queue: [(offset: off_t, data: ByteBuffer)], finished: Bool) {
        storage.withLock { state in
            let r = state.results
            let finished = state.finished
            state.results.removeAll()
            return (r, finished)
        }
    }
}

// MARK: - Thread-safe error box

private final class ErrorBox: Sendable {
    private let storage = Mutex<(any Error)?>(nil)

    init() {}

    func set(_ error: any Error) {
        storage.withLock { stored in
            if stored == nil {
                stored = error
            }
        }
    }

    func get() -> (any Error)? {
        storage.withLock { $0 }
    }
}

// MARK: - Semaphore helper

private func wait(_ sem: DispatchSemaphore) {
    sem.wait()
}

// MARK: - Entry type extraction

extension Optional {
    /// Consumes the current value, leaving `nil` in its place, and returns
    /// what was there.
    fileprivate mutating func take() -> Wrapped? {
        let value = self
        self = nil
        return value
    }
}

/// Handles the `AA_ENTRY_MESSAGE_EXTRACT_BEGIN` message: extracts the entry
/// type from the header, then stores it into the pending-type slot for the
/// subsequent `AA_ENTRY_MESSAGE_EXTRACT_ATTRIBUTES` message to consume.
///
/// A non-nil value already in the slot signals that a previous entry received
/// BEGIN but never reached ATTRIBUTES (excluded entry, header parse failure).
/// This is logged at `.debug` and the slot is overwritten.
internal func handleExtractBegin(
    data: UnsafeMutableRawPointer?,
    path: UnsafePointer<CChar>,
    pendingType: borrowing Mutex<UInt8?>,
    logger: Logger
) {
    let newType = extractEntryType(from: data, path: path, logger: logger)
    pendingType.withLock { slot in
        if let stale = slot {
            logger.debug(
                "Stale entry type slot on BEGIN (prior entry skipped ATTRIBUTES)",
                metadata: [
                    "path": "\(String(cString: path))",
                    "staleType": "\(entryTypeDescription(stale))",
                ]
            )
        }
        slot = newType
    }
}

/// Handles the `AA_ENTRY_MESSAGE_EXTRACT_ATTRIBUTES` message: reads the type
/// stashed by the preceding BEGIN, then forces the on-disk mode to `0o755`
/// for directories and `0o744` for everything else.
///
/// Also clears the archive-recorded `UID`/`GID` intent bits so the extractor
/// skips `fchown` entirely; extracted files inherit the process's fsuid from
/// the `open(O_CREAT)` that produced them, which lets us run unprivileged
/// without `CAP_CHOWN`. Errors from `fchmod` and other attribute syscalls
/// remain fatal.
///
/// The archive-root entry (path `""` or `"."`) is a special case: it maps
/// to the caller's extraction directory, which we don't necessarily own.
/// `fchmod` on a file whose owner doesn't match the process's euid returns
/// `EPERM` on Linux, so for that entry we clear the `MOD` intent bit and
/// leave the on-disk mode of the extraction directory untouched. UID/GID
/// are still cleared, for the same reason as above.
///
/// If no type is pending — i.e. ATTRIBUTES fired without a matching BEGIN —
/// this is logged at `.debug` and the mode defaults to `0o744`.
internal func handleExtractAttributes(
    data: UnsafeMutableRawPointer?,
    path: UnsafePointer<CChar>,
    pendingType: borrowing Mutex<UInt8?>,
    logger: Logger
) {
    guard let data else { return }
    let attrPtr = data.assumingMemoryBound(to: __AAEntryAttributes.self)
    let typ = pendingType.withLock { $0.take() }

    // Never touch owner/group — see doc comment above.
    attrPtr.pointee.UID = 0
    attrPtr.pointee.GID = 0

    let pathString = String(cString: path)
    if isArchiveRootPath(pathString) {
        // Suppress fchmod on the extraction directory itself.
        attrPtr.pointee.MOD = 0
        logger.debug(
            "Skipping mode override on archive-root entry",
            metadata: ["path": "\(pathString)"]
        )
        return
    }

    let mode: UInt32 = (typ == UInt8(ascii: "D")) ? 0o755 : 0o744
    if let typ {
        logger.debug(
            "Applying permission override",
            metadata: [
                "path": "\(pathString)",
                "type": "\(entryTypeDescription(typ))",
                "mode": "\(String(mode, radix: 8))",
            ]
        )
    } else {
        logger.debug(
            "ATTRIBUTES fired with no pending type; defaulting to file mode",
            metadata: [
                "path": "\(pathString)",
                "mode": "\(String(mode, radix: 8))",
            ]
        )
    }
    attrPtr.pointee.MOD = 1
    attrPtr.pointee.mod = mode
}

/// Returns `true` if `path` is the archive-root sentinel — the entry whose
/// on-disk destination is the extraction directory itself. AppleArchive
/// stores this as either the empty string or `"."`, depending on how the
/// archive was authored.
internal func isArchiveRootPath(_ path: String) -> Bool {
    path.isEmpty || path == "."
}

/// Reads the `TYP` field from an entry header pointer supplied by
/// `AA_ENTRY_MESSAGE_EXTRACT_BEGIN`, returning the raw type byte
/// (e.g. `'D'` for directory, `'F'` for regular file).
internal func extractEntryType(
    from data: UnsafeMutableRawPointer?,
    path: UnsafePointer<CChar>,
    logger: Logger
) -> UInt8? {
    guard let data else {
        logger.debug(
            "BEGIN callback received nil header data",
            metadata: ["path": "\(String(cString: path))"]
        )
        return nil
    }
    let header = __AAHeader(data)
    let typKey = __AAFieldKey(
        skey: (
            Int8(UInt8(ascii: "T")),
            Int8(UInt8(ascii: "Y")),
            Int8(UInt8(ascii: "P")),
            0
        )
    )
    let idx = __AAHeaderGetKeyIndex(header, typKey)
    if idx < 0 {
        logger.debug(
            "TYP field missing from entry header",
            metadata: ["path": "\(String(cString: path))"]
        )
        return nil
    }
    var typValue: UInt64 = 0
    let rc = __AAHeaderGetFieldUInt(header, UInt32(idx), &typValue)
    guard rc == 0 else {
        logger.debug(
            "Failed to read TYP field",
            metadata: [
                "path": "\(String(cString: path))",
                "rc": "\(rc)",
            ]
        )
        return nil
    }
    return UInt8(truncatingIfNeeded: typValue)
}

/// Precomputed lookup table for `entryTypeDescription`: each printable ASCII
/// byte maps to a single-character `String`; everything else falls through to
/// `"<unknown>"`.
private let entryTypeTable: [String] = {
    var table = Array(repeating: "<unknown>", count: 256)
    for i in 0x20..<0x7F {
        table[i] = String(UnicodeScalar(i)!)
    }
    return table
}()

/// Renders an AA entry type byte as its printable ASCII character
/// (e.g. `"D"`, `"F"`, `"L"`) for logging.
internal func entryTypeDescription(_ typ: UInt8) -> String {
    entryTypeTable[Int(typ)]
}
