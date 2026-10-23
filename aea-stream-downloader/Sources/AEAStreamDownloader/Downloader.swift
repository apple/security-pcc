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

/// The outcome of a download operation.
public enum DownloadResult: Sendable, Equatable {
    /// The output directory was already up-to-date (sentinel matched).
    case alreadyCurrent
    /// A fresh download and extraction was performed.
    case downloaded
}

// MARK: - Orchestrator

/// Downloads from a ``DownloadSource`` into a ``DownloadSink``, with
/// sentinel-based caching and output directory management.
///
/// 1. Reads the sentinel file. If `urlOnlyIdentityCheck` is on and the sentinel's
///    stored URL matches `sourceURL`, returns `.alreadyCurrent` *without* calling
///    `source.sourceIdentifier()`. This lets callers skip work when they trust
///    the URL to represent identity, avoiding an auth-carrying metadata fetch.
/// 2. Otherwise, calls `source.sourceIdentifier()` and compares against the
///    sentinel's stored identifier. If they match and `!forceDownload`, returns
///    `.alreadyCurrent`.
/// 3. Clears the output directory if the sink requests it.
/// 4. Calls `sink.withRangeRequests { ... }` — inside the closure, iterates
///    range requests in a task group, fetching each from `source` and calling
///    `sink.process(...)`.
/// 5. Writes the sentinel file with both the source identifier and (if provided)
///    the source URL.
/// 6. Returns `.downloaded`.
@discardableResult
public func download(
    from source: some DownloadSource,
    to sink: some DownloadSink,
    logger: Logger,
    context: DownloadContext,
    forceDownload: Bool = false,
    urlOnlyIdentityCheck: Bool = false,
    sourceURL: String? = nil
) async throws -> DownloadResult {
    // Step 1: Read the sentinel once. Both the URL fast-path and the identifier
    // check consult it.
    let sentinel = readSentinel(at: sink.sentinelPath, logger: logger)

    // Step 2: URL fast-path — matches means no auth-carrying identifier fetch.
    if let matchedURL = urlFastPathMatch(
        sentinel: sentinel,
        sourceURL: sourceURL,
        urlOnlyIdentityCheck: urlOnlyIdentityCheck,
        forceDownload: forceDownload
    ) {
        logger.info(
            "Source URL unchanged, skipping download",
            metadata: ["sourceURL": "\(matchedURL)"]
        )
        return .alreadyCurrent
    }

    // Step 3: Identifier fallback — fetch and compare against the sentinel.
    let sourceIdentifier = try await source.sourceIdentifier()

    if !forceDownload, sentinel?.sourceIdentifier == sourceIdentifier {
        logger.info(
            "Source unchanged, skipping download",
            metadata: ["identifier": "\(sourceIdentifier)"]
        )
        return .alreadyCurrent
    }

    // Step 4: Clear output directory if the sink requires it.
    if sink.shouldClearOutputDirectory {
        try clearOutputDirectory(at: sink.outputDirectory, logger: logger)
    }

    // Step 5: Run the sink, fetching ranges from the source.
    let entries = try await source.contents()
    try await sink.withRangeRequests(entries: entries) { rangeRequests, sink in
        let clock = ContinuousClock()
        let metrics = context.metrics
        try await withThrowingDiscardingTaskGroup { group in
            for await request in rangeRequests {
                let source = source
                group.addTask {
                    defer { sink.requestCompleted(for: request) }
                    let chunkStart = clock.now
                    let data = try await source.fetch(request)
                    let chunkElapsed = clock.now - chunkStart
                    metrics.recordChunkDuration(chunkElapsed)
                    metrics.recordBytesDownloaded(data.readableBytes)
                    try await sink.process(data, for: request)
                }
            }
        }
    }

    // Step 6: Write sentinel.
    writeSentinel(
        identifier: sourceIdentifier,
        sourceURL: sourceURL,
        at: sink.sentinelPath,
        logger: logger
    )

    // Step 7: Record asset-loaded gauge.
    let totalSize = entries.reduce(0) { $0 + $1.size }
    context.metrics.markAssetLoaded(sizeBytes: totalSize, checksum: sourceIdentifier)

    return .downloaded
}

// MARK: - URL-only identity fast path

/// Returns the source URL that the URL-only fast-path matched on, or `nil` if
/// the fast-path does not apply. Non-nil means the caller can short-circuit
/// with `.alreadyCurrent` *without* consulting the source — the whole point of
/// the URL-only mode is to avoid an auth-carrying metadata / list request just
/// to decide the output is already current.
///
/// All four preconditions must hold:
/// - `forceDownload` is off (a forced download always re-downloads),
/// - URL-only identity checking is enabled by the caller,
/// - a `sourceURL` was supplied,
/// - the sentinel records the same URL.
private func urlFastPathMatch(
    sentinel: SentinelState?,
    sourceURL: String?,
    urlOnlyIdentityCheck: Bool,
    forceDownload: Bool
) -> String? {
    guard !forceDownload, urlOnlyIdentityCheck else { return nil }
    guard let sourceURL, sentinel?.sourceURL == sourceURL else { return nil }
    return sourceURL
}

// MARK: - Sentinel file for caching

private struct SentinelMetadata: Codable {
    var source_identifier: String
    var source_url: String?
}

/// Decoded contents of a sentinel file.
struct SentinelState {
    var sourceIdentifier: String
    var sourceURL: String?
}

func readSentinel(at sentinelPath: FilePath, logger: Logger) -> SentinelState? {
    let pathString = sentinelPath.string
    guard let data = FileManager.default.contents(atPath: pathString) else {
        logger.debug("No sentinel file found", metadata: ["path": "\(sentinelPath)"])
        return nil
    }
    do {
        let metadata = try JSONDecoder().decode(SentinelMetadata.self, from: data)
        logger.debug(
            "Read sentinel",
            metadata: [
                "identifier": "\(metadata.source_identifier)",
                "sourceURL": "\(metadata.source_url ?? "<absent>")",
            ]
        )
        return SentinelState(
            sourceIdentifier: metadata.source_identifier,
            sourceURL: metadata.source_url
        )
    } catch {
        logger.warning("Corrupt sentinel file, will re-download", metadata: ["error": "\(String(reportable: error))"])
        return nil
    }
}

func writeSentinel(
    identifier: String,
    sourceURL: String? = nil,
    at sentinelPath: FilePath,
    logger: Logger
) {
    let metadata = SentinelMetadata(source_identifier: identifier, source_url: sourceURL)
    do {
        let data = try JSONEncoder().encode(metadata)
        let pathString = sentinelPath.string
        // Write atomically by writing to a temp file then renaming.
        let tempPath = pathString + ".tmp"
        try data.write(to: URL(fileURLWithPath: tempPath))
        try FileManager.default.moveItem(atPath: tempPath, toPath: pathString)
        // Match the 0o744 mode applied to files by PlainFileDownloadSink so
        // the whole output tree is consistent. A chmod failure here would be
        // strange (we just wrote the file) and doesn't affect caching, so we
        // don't propagate it.
        _ = chmod(pathString, 0o744)
        logger.debug(
            "Wrote sentinel",
            metadata: [
                "identifier": "\(identifier)",
                "sourceURL": "\(sourceURL ?? "<absent>")",
            ]
        )
    } catch {
        logger.warning("Failed to write sentinel file", metadata: ["error": "\(String(reportable: error))"])
    }
}

func clearOutputDirectory(at directory: FilePath, logger: Logger) throws {
    let fm = FileManager.default
    let dirString = directory.string
    let contents = try fm.contentsOfDirectory(atPath: dirString)
    for entry in contents {
        let entryPath = URL(fileURLWithPath: dirString).appendingPathComponent(entry).path
        try fm.removeItem(atPath: entryPath)
    }
    logger.debug(
        "Cleared output directory",
        metadata: ["path": "\(directory)", "entries": "\(contents.count)"]
    )
}
