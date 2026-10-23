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

import Metrics

// MARK: - Download context

/// Metadata about the current download, used for metrics dimensions.
public struct DownloadContext: Sendable {
    /// The full source URL for the asset being downloaded (e.g. `gs://bucket/object`).
    public var assetName: String

    /// Pre-created metric instruments for this download.
    package var metrics: DownloadMetrics

    public init(assetName: String) {
        self.assetName = assetName
        self.metrics = DownloadMetrics(asset: assetName)
    }
}

// MARK: - Metrics operation

/// Normalized operation names used for both log messages and the retry
/// metrics dimension.
package enum MetricsOperation: String, CaseIterable, Hashable, Sendable {
    case rangeFetch = "range_fetch"
    case metadataFetch = "metadata_fetch"
    case listObjects = "list_objects"
    case tokenFetch = "token_fetch"
    case secretFetch = "secret_fetch"

    /// Human-readable label used in log messages.
    var logDescription: String {
        switch self {
        case .rangeFetch: "range fetch"
        case .metadataFetch: "metadata fetch"
        case .listObjects: "list objects"
        case .tokenFetch: "token fetch"
        case .secretFetch: "secret fetch"
        }
    }
}

// MARK: - Pre-created metric instruments

/// Download metric instruments, pre-created once per asset to keep
/// cardinality bounded.
///
/// HTTP status codes and error types are mapped to a finite known set;
/// anything outside that set falls into an `"unknown"` bucket.
package final class DownloadMetrics: Sendable {

    // MARK: Known dimension values

    static let knownHTTPStatusCodes = [200, 206, 400, 401, 403, 404, 408, 429, 500, 502, 503, 504]

    static let knownErrorTypes = [
        "AEADownloaderError",
        "ConfigurationError",
        "HTTPClientError",
        "DecodingError",
    ]

    // MARK: Download duration

    private let durationDownloaded: Timer
    private let durationAlreadyCurrent: Timer
    private let durationErrors: [String: Timer]
    private let durationErrorUnknown: Timer

    // MARK: Chunk timing

    private let chunkDuration: Timer

    // MARK: Bytes downloaded

    private let bytesDownloaded: Counter

    // MARK: Retries by operation

    private let retryCounters: [MetricsOperation: Counter]

    // MARK: HTTP status by status code

    private let httpStatusCounters: [Int: Counter]
    private let httpStatusUnknown: Counter

    // MARK: Errors by type

    private let errorCounters: [String: Counter]
    private let errorUnknown: Counter

    // MARK: Asset loaded (size/checksum not known until completion)

    private let asset: String

    init(asset: String) {
        self.asset = asset

        self.durationDownloaded = Timer(
            label: "aea_download_duration",
            dimensions: [("asset", asset), ("status", "downloaded"), ("error_type", "")]
        )
        self.durationAlreadyCurrent = Timer(
            label: "aea_download_duration",
            dimensions: [("asset", asset), ("status", "already_current"), ("error_type", "")]
        )

        var durationErrors: [String: Timer] = [:]
        for errorType in Self.knownErrorTypes {
            durationErrors[errorType] = Timer(
                label: "aea_download_duration",
                dimensions: [("asset", asset), ("status", "error"), ("error_type", errorType)]
            )
        }
        self.durationErrors = durationErrors
        self.durationErrorUnknown = Timer(
            label: "aea_download_duration",
            dimensions: [("asset", asset), ("status", "error"), ("error_type", "unknown")]
        )

        self.chunkDuration = Timer(
            label: "aea_chunk_duration",
            dimensions: [("asset", asset)]
        )

        self.bytesDownloaded = Counter(
            label: "aea_download_bytes",
            dimensions: [("asset", asset)]
        )

        var retryCounters: [MetricsOperation: Counter] = [:]
        for op in MetricsOperation.allCases {
            retryCounters[op] = Counter(
                label: "aea_download_retries",
                dimensions: [("asset", asset), ("operation", op.rawValue)]
            )
        }
        self.retryCounters = retryCounters

        var httpStatusCounters: [Int: Counter] = [:]
        for code in Self.knownHTTPStatusCodes {
            httpStatusCounters[code] = Counter(
                label: "aea_download_http_status",
                dimensions: [("asset", asset), ("status_code", String(code))]
            )
        }
        self.httpStatusCounters = httpStatusCounters
        self.httpStatusUnknown = Counter(
            label: "aea_download_http_status",
            dimensions: [("asset", asset), ("status_code", "unknown")]
        )

        var errorCounters: [String: Counter] = [:]
        for errorType in Self.knownErrorTypes {
            errorCounters[errorType] = Counter(
                label: "aea_download_errors",
                dimensions: [("asset", asset), ("error_type", errorType)]
            )
        }
        self.errorCounters = errorCounters
        self.errorUnknown = Counter(
            label: "aea_download_errors",
            dimensions: [("asset", asset), ("error_type", "unknown")]
        )
    }

    // MARK: - Recording methods

    /// Records the end-to-end wall time of a completed download.
    func recordDownloadCompleted(_ duration: Duration) {
        durationDownloaded.record(duration: duration)
    }

    /// Records the end-to-end wall time of a skipped (already-current) download.
    func recordDownloadSkipped(_ duration: Duration) {
        durationAlreadyCurrent.record(duration: duration)
    }

    /// Records the end-to-end wall time of a failed download.
    func recordDownloadFailed(_ duration: Duration, error: any Error) {
        let typeName = String(describing: type(of: error))
        let timer = durationErrors[typeName] ?? durationErrorUnknown
        timer.record(duration: duration)
    }

    /// Records the wall time for a single HTTP range-request fetch.
    func recordChunkDuration(_ duration: Duration) {
        chunkDuration.record(duration: duration)
    }

    /// Increments the bytes-downloaded counter.
    func recordBytesDownloaded(_ bytes: Int) {
        bytesDownloaded.increment(by: bytes)
    }

    /// Increments the retry counter for a specific operation.
    func recordRetry(operation: MetricsOperation) {
        retryCounters[operation]!.increment()
    }

    /// Records an HTTP status code from a range or metadata fetch.
    func recordHTTPStatus(statusCode: Int) {
        let counter = httpStatusCounters[statusCode] ?? httpStatusUnknown
        counter.increment()
    }

    /// Records a fetch error during a retried operation.
    func recordError(_ error: any Error) {
        let typeName = String(describing: type(of: error))
        let counter = errorCounters[typeName] ?? errorUnknown
        counter.increment()
    }

    /// Sets the loaded gauge to 1 for a successfully downloaded asset.
    ///
    /// This gauge is created dynamically because `sizeBytes` and `checksum`
    /// are not known until the download completes.
    func markAssetLoaded(sizeBytes: Int, checksum: String) {
        Gauge(
            label: "aea_asset_loaded",
            dimensions: [
                ("asset", asset),
                ("size_bytes", String(sizeBytes)),
                ("checksum", checksum),
            ]
        ).record(1)
    }
}
