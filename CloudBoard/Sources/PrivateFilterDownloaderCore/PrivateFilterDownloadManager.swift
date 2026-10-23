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

import AsyncAlgorithms
import CloudBoardIdentity
import Foundation
import os
import PrivateFilterCommon
import Synchronization

final class PrivateFilterDownloadManager: NSObject, Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: PrivateFilterDownloadManager.self)
    )

    private let identityManager: IdentityManager
    private let metricsSystem: any PrivateFilterMetricsSystem
    private let filterID: FilterIDString
    private let fragmentsMetadata: Set<FragmentMetadata>
    private let maxConcurrentDownloads: Int
    private let maxConcurrentVerifications: Int
    private let maxRetryAttempts: Int
    private let maxFragmentDownloadFailures: Int
    private let totalFragmentCount: Int
    private let rangeConfig: RangeDownloadConfig?
    private let completedCount = Mutex(0)
    private let failureCount = Mutex(0)

    init(
        fragmentsMetadata: Set<FragmentMetadata>,
        identityManager: IdentityManager,
        metricsSystem: any PrivateFilterMetricsSystem,
        filterID: FilterIDString,
        maxConcurrentDownloads: Int,
        maxConcurrentVerifications: Int,
        maxRetryAttempts: Int,
        maxFragmentDownloadFailures: Int,
        rangeConfig: RangeDownloadConfig?
    ) {
        self.fragmentsMetadata = fragmentsMetadata
        self.identityManager = identityManager
        self.metricsSystem = metricsSystem
        self.filterID = filterID
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.maxConcurrentVerifications = maxConcurrentVerifications
        self.maxRetryAttempts = maxRetryAttempts
        self.maxFragmentDownloadFailures = maxFragmentDownloadFailures
        self.totalFragmentCount = fragmentsMetadata.count
        self.rangeConfig = rangeConfig
    }

    func downloadFragments(using urlSession: URLSession) async throws {
        let start = ContinuousClock.now

        let (verifyStream, verifyContinuation) = AsyncStream<FragmentMetadata>.makeStream()

        try await withThrowingDiscardingTaskGroup { outerGroup in
            outerGroup.addTask {
                defer { verifyContinuation.finish() }
                try await self.fragmentsMetadata.async.forEachConcurrently(
                    maxConcurrency: self.maxConcurrentDownloads
                ) { metadata in
                    // A tolerated failure returns false (not thrown), so it doesn't
                    // cancel the group — the fragment is just not queued for verify.
                    if try await self.downloadOnly(metadata: metadata, using: urlSession) {
                        verifyContinuation.yield(metadata)
                    }
                }
            }

            outerGroup.addTask {
                try await verifyStream.forEachConcurrently(
                    maxConcurrency: self.maxConcurrentVerifications
                ) { metadata in
                    try self.verifyFragment(metadata: metadata)
                }
            }
        }

        let duration = ContinuousClock.now - start

        // Reaching here means the failure budget was never exceeded (that path throws
        // from within the group). But a filter needs every fragment, so any tolerated
        // failure still leaves it incomplete — report it so the filter isn't marked
        // ready. The fragments that succeeded are already persisted; the next reconcile
        // re-queues the missing ones.
        let failures = self.failureCount.withLock { $0 }
        if failures > 0 {
            Self.logger.error("""
            Filter download incomplete after tolerating failures. \
            FilterID=\(self.filterID, privacy: .public) \
            Failures=\(failures, privacy: .public)-of-\(self.totalFragmentCount, privacy: .public) \
            Duration=\(duration, privacy: .public)
            """)
            throw FragmentDownloadError.incompleteFilter(failures: failures, total: self.totalFragmentCount)
        }

        Self.logger.log("""
        All fragments downloaded and verified. \
        Duration=\(duration, privacy: .public)
        """)
    }

    /// Records a fragment failure (download or verification) and decides whether the
    /// filter download should keep going. Below the configured budget the failure is
    /// logged and absorbed so the remaining fragments still download; once the budget
    /// is exceeded it throws to abort the whole filter.
    private func recordFailure(metadata: FragmentMetadata, error: any Error, phase: String) throws {
        self.metricsSystem.emit(
            Metrics.FragmentDownloadFailureCounter(
                dimensions: [
                    .filterID: self.filterID,
                    .errorDescription: String(reportable: error),
                ],
                action: .increment
            )
        )

        let failures = self.failureCount.withLock { count in
            count += 1
            return count
        }

        if failures > self.maxFragmentDownloadFailures {
            Self.logger.error("""
            Fragment \(phase, privacy: .public) failed; failure budget exhausted, aborting filter download. \
            FilterID=\(self.filterID, privacy: .public) \
            FragmentID=\(metadata.id, privacy: .public) \
            Failures=\(failures, privacy: .public) \
            Threshold=\(self.maxFragmentDownloadFailures, privacy: .public) \
            Error=\(error, privacy: .public)
            """)
            throw FragmentDownloadError.failureThresholdExceeded(
                failures: failures, threshold: self.maxFragmentDownloadFailures
            )
        }

        Self.logger.warning("""
        Fragment \(phase, privacy: .public) failed but within tolerance, continuing. \
        FilterID=\(self.filterID, privacy: .public) \
        FragmentID=\(metadata.id, privacy: .public) \
        Failures=\(failures, privacy: .public) \
        Threshold=\(self.maxFragmentDownloadFailures, privacy: .public) \
        Error=\(error, privacy: .public)
        """)
    }

    /// Downloads one fragment. Returns `true` on success (queue it for verification),
    /// `false` when the failure was tolerated, and throws only when the failure budget
    /// is exceeded (aborting the filter).
    private func downloadOnly(
        metadata: FragmentMetadata,
        using urlSession: URLSession
    ) async throws -> Bool {
        let fragmentDownloadStart = ContinuousClock.now
        do {
            try await self.downloadFragmentWithRetries(metadata: metadata, using: urlSession)
        } catch {
            try self.recordFailure(metadata: metadata, error: error, phase: "download")
            return false
        }

        let fragmentDownloadDuration = ContinuousClock.now - fragmentDownloadStart
        self.metricsSystem.emit(
            Metrics.FragmentDownloadDurationGauge(
                value: fragmentDownloadDuration.privateFilterSeconds,
                dimensions: [.filterID: self.filterID]
            )
        )
        Self.logger.log("""
        Fragment downloaded, queued for verification. \
        FragmentID=\(metadata.id, privacy: .public) \
        Duration=\(fragmentDownloadDuration, privacy: .public)
        """)
        return true
    }

    private func verifyFragment(metadata: FragmentMetadata) throws {
        let downloader = FragmentDownloader(
            metadata: metadata,
            rangeConfig: self.rangeConfig,
            metricsSystem: self.metricsSystem,
            filterID: self.filterID
        )
        do {
            try downloader.verify()
        } catch {
            try self.recordFailure(metadata: metadata, error: error, phase: "verification")
            return
        }

        self.metricsSystem.emit(
            Metrics.FragmentDownloadSuccessCounter(
                action: .increment,
                dimensions: [.filterID: self.filterID]
            )
        )

        let completed = self.completedCount.withLock { count in
            count += 1
            return count
        }

        self.metricsSystem.emit(
            Metrics.FilterDownloadProgressGauge(
                value: completed * 100 / self.totalFragmentCount,
                dimensions: [.filterID: self.filterID]
            )
        )

        Self.logger.log("""
        Fragment verified and complete. \
        FragmentID=\(metadata.id, privacy: .public) \
        Progress=\(completed, privacy: .public)-of-\(self.totalFragmentCount, privacy: .public)
        """)
    }

    private func downloadFragmentWithRetries(
        metadata: FragmentMetadata,
        using urlSession: URLSession
    ) async throws {
        try await retryWithBackoff(
            label: "download \(metadata.id) from \(metadata.source)",
            maxAttempts: self.maxRetryAttempts,
            logger: Self.logger,
            onAttempt: {
                self.metricsSystem.emit(
                    Metrics.FragmentDownloadAttemptCounter(
                        action: .increment, dimensions: [.filterID: self.filterID]
                    )
                )
            }
        ) {
            if FileManager.default.fileExists(atPath: metadata.destination.path) {
                let computedSHA256 = try computeSHA256(of: metadata.destination)
                if computedSHA256 == metadata.sha256 {
                    Self.logger.info("""
                    Fragment already exists with valid SHA256, skipping. \
                    FragmentID=\(metadata.id, privacy: .public)
                    """)
                    return
                }
                Self.logger.info("""
                Fragment exists but SHA256 mismatch, removing. \
                FragmentID=\(metadata.id, privacy: .public) \
                Expected=\(metadata.sha256, privacy: .public) \
                Actual=\(computedSHA256, privacy: .public)
                """)
                try FileManager.default.removeItem(at: metadata.destination)
            }

            let downloader = FragmentDownloader(
                metadata: metadata,
                rangeConfig: self.rangeConfig,
                metricsSystem: self.metricsSystem,
                filterID: self.filterID
            )
            try await downloader.download(using: urlSession)
        }
    }
}

// MARK: - Auth challenge handling

extension PrivateFilterDownloadManager: URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            if let credential = self.identityManager.identity?.credential {
                completionHandler(.useCredential, credential)
            } else {
                Self.logger.error("No client certificate credential available")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum FragmentDownloadError: Error, CustomStringConvertible {
    case httpError(statusCode: Int)
    case sha256Mismatch(expected: String, actual: String)
    case rangeNotSatisfiable
    case rangeFallback
    case partialFileError(reason: String)
    case missingHTTPResponse
    /// Fragment failures within a filter exceeded the configured budget; the filter
    /// download was aborted early.
    case failureThresholdExceeded(failures: Int, threshold: Int)
    /// The filter download finished but some fragments failed (within budget), so the
    /// filter is incomplete. The missing fragments are retried on the next reconcile.
    case incompleteFilter(failures: Int, total: Int)

    var isTransientHTTP: Bool {
        if case .httpError(let statusCode) = self {
            return (500 ... 599).contains(statusCode)
        }
        return false
    }

    var description: String {
        switch self {
        case .httpError(let statusCode):
            "HTTP error: \(statusCode)"
        case .sha256Mismatch(let expected, let actual):
            "SHA256 mismatch: expected \(expected), got \(actual)"
        case .rangeNotSatisfiable:
            "HTTP 416 Range Not Satisfiable"
        case .rangeFallback:
            "Server returned full file (HTTP 200) instead of range (HTTP 206)"
        case .partialFileError(let reason):
            "Partial file error: \(reason)"
        case .missingHTTPResponse:
            "Download completed without HTTP response"
        case .failureThresholdExceeded(let failures, let threshold):
            "Fragment failure budget exceeded: \(failures) failures > threshold \(threshold)"
        case .incompleteFilter(let failures, let total):
            "Filter incomplete: \(failures) of \(total) fragments failed"
        }
    }
}

extension FragmentDownloadError: ReportableError {
    /// Case name only (plus the bounded HTTP status code); associated string
    /// payloads such as URLs, hashes and free-form reasons are omitted so this is
    /// safe as a public log value and bounded as a metric dimension.
    var publicDescription: String {
        switch self {
        case .httpError(let statusCode):
            "httpError(\(statusCode))"
        case .sha256Mismatch:
            "sha256Mismatch"
        case .rangeNotSatisfiable:
            "rangeNotSatisfiable"
        case .rangeFallback:
            "rangeFallback"
        case .partialFileError:
            "partialFileError"
        case .missingHTTPResponse:
            "missingHTTPResponse"
        case .failureThresholdExceeded:
            "failureThresholdExceeded"
        case .incompleteFilter:
            "incompleteFilter"
        }
    }
}
