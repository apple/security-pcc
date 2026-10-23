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

import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import SotoSignerV4

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(System)
import System
#else
import SystemPackage
#endif

// MARK: - S3 client

/// Bundles the HTTP machinery needed to issue authenticated S3 requests.
///
/// Authentication is provided by an ``S3AuthMode`` selected at construction time:
/// either client-cert mTLS (handled by the underlying `HTTPClient`'s TLS config)
/// or per-request AWS Signature V4 signing via `SotoSignerV4`.
struct S3Client {
    let httpClient: HTTPClient
    let downloadURL: String
    let key: String
    private let auth: S3AuthMode

    init(httpClient: HTTPClient, downloadURL: String, key: String, auth: S3AuthMode) {
        self.httpClient = httpClient
        self.downloadURL = downloadURL
        self.key = key
        self.auth = auth
    }

    /// Builds an `HTTPClient` and `S3Client` configured for the chosen
    /// authentication mode.
    static func create(
        bucket: String,
        key: String,
        baseURL: String,
        auth: S3AuthMode,
        logger: Logger,
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5
    ) throws -> S3Client {
        var httpConfig = makeBaseHTTPClientConfig(
            connectTimeout: .seconds(Int64(httpConnectTimeoutSeconds)),
            readTimeout: .seconds(Int64(httpReadTimeoutSeconds))
        )

        switch auth {
        case .mTLS(let certificatePath, let keyPath, let caCertificatePath):
            httpConfig.tlsConfiguration = try makeBaseTLSConfigurationForMTLS(
                certificatePath: certificatePath,
                keyPath: keyPath,
                caCertificatePath: caCertificatePath
            )
        case .sigV4:
            // Default system trust roots; no client cert. Per-request signing
            // is applied in `sign(_:)`.
            break
        }

        let httpClient = HTTPClient(
            eventLoopGroup: .singletonMultiThreadedEventLoopGroup,
            configuration: httpConfig
        )

        let normalizedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let downloadURL = "\(normalizedBaseURL)/\(bucket)/\(key)"
        logger.debug("S3Client created", metadata: ["downloadURL": "\(downloadURL)"])
        return S3Client(
            httpClient: httpClient,
            downloadURL: downloadURL,
            key: key,
            auth: auth
        )
    }

    /// Executes `request` against the underlying HTTP client, signing it with
    /// SigV4 first when the auth mode requires it. The mTLS path passes the
    /// request through unchanged.
    func execute(
        _ request: consuming HTTPClientRequest,
        timeout: TimeAmount
    ) async throws -> HTTPClientResponse {
        sign(&request)
        return try await httpClient.execute(request, timeout: timeout)
    }

    /// Signs `request` in place when SigV4 is configured; a no-op for mTLS.
    ///
    /// Bodies are signed as `.unsignedPayload`; the downloader is read-only,
    /// so every S3 request is HEAD or GET with no body.
    ///
    /// `AWSSigner.signHeaders` consumes the URL's query string verbatim into
    /// its canonical request, assuming the caller has already percent-encoded
    /// query parameters per the SigV4 spec. The list-objects URL embeds the
    /// prefix as a query value with literal slashes, which the server
    /// canonicalizes to `%2F` — so we must normalize the URL via
    /// `signer.processURL` first, and send that same normalized URL on the
    /// wire to keep client and server canonical requests in sync.
    private func sign(_ request: inout HTTPClientRequest) {
        guard case .sigV4(let credentials, let region) = auth else {
            return
        }
        // Every URL we sign is built by us in path-style with a numeric port
        // and ASCII bucket/key components; Foundation's parser never fails on
        // those. A nil here would be a programmer error in URL construction.
        let url = URL(string: request.url)!
        let signer = AWSSigner(
            credentials: StaticCredential(
                accessKeyId: credentials.accessKeyId,
                secretAccessKey: credentials.secretAccessKey
            ),
            name: "s3",
            region: region
        )
        // processURL sorts query items, percent-encodes them per SigV4 rules,
        // and (for S3) re-encodes the path. A nil return would only happen on
        // an unparseable URL, which we've already excluded above.
        let normalizedURL = signer.processURL(url: url)!
        request.url = normalizedURL.absoluteString
        request.headers = signer.signHeaders(
            url: normalizedURL,
            method: request.method,
            headers: request.headers,
            body: .unsignedPayload,
            date: Date()
        )
    }

    func shutdown() async throws {
        try await httpClient.shutdown()
    }
}

// MARK: - S3 error body

/// Reads up to 4KB of an error response body and returns it as a string for
/// diagnostic logging. S3-compatible endpoints return short XML bodies that
/// name the precise failure mode (`SignatureDoesNotMatch`, `AccessDenied`,
/// `InvalidAccessKeyId`, `RequestTimeTooSkewed`, ...), which the bare status
/// code can't disambiguate.
///
/// Always returns a string; on read failure the placeholder `"<unavailable>"`
/// is used so the metadata field is never absent.
private func readS3ErrorBody(_ response: HTTPClientResponse) async -> String {
    do {
        let buffer = try await response.body.collect(upTo: 4 * 1024)
        let snippet = String(buffer: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? "<empty>" : snippet
    } catch {
        return "<unavailable>"
    }
}

// MARK: - S3 metadata fetch

struct S3ObjectMetadata {
    var etag: String
    var contentLength: Int?
}

func fetchS3Metadata(
    logger: Logger,
    client: S3Client,
    url: String,
    retryConfiguration: RetryConfiguration = .default,
    metrics: DownloadMetrics? = nil
) async throws -> S3ObjectMetadata {
    try await withRetry(
        configuration: retryConfiguration,
        logger: logger,
        operation: .metadataFetch,
        metrics: metrics
    ) {
        var request = HTTPClientRequest(url: url)
        request.method = .HEAD

        logger.debug("Fetching S3 metadata", metadata: ["url": "\(url)"])
        let response = try await client.execute(request, timeout: .seconds(30))
        metrics?.recordHTTPStatus(statusCode: Int(response.status.code))
        guard response.status == .ok else {
            let body = await readS3ErrorBody(response)
            logger.warning(
                "S3 metadata fetch failed",
                metadata: [
                    "httpStatus": "\(response.status.code)",
                    "responseBody": "\(body)",
                ]
            )
            throw AEADownloaderError.etagFetchFailed(status: Int(response.status.code))
        }

        guard let etag = response.headers["ETag"].first else {
            throw AEADownloaderError.etagFetchFailed(status: Int(response.status.code))
        }

        let contentLength = response.headers["Content-Length"].first.flatMap(Int.init)
        let contentLengthDescription = contentLength.map(String.init) ?? "nil"

        logger.debug(
            "Got S3 metadata",
            metadata: ["etag": "\(etag)", "contentLength": "\(contentLengthDescription)"]
        )
        return S3ObjectMetadata(etag: etag, contentLength: contentLength)
    }
}

// MARK: - S3 range fetch

func fetchS3Range(
    logger: Logger,
    client: S3Client,
    url: String,
    offset: off_t,
    nbyte: size_t,
    retryConfiguration: RetryConfiguration = .default,
    metrics: DownloadMetrics? = nil
) async throws -> ByteBuffer {
    try await withRetry(
        configuration: retryConfiguration,
        logger: logger,
        operation: .rangeFetch,
        metrics: metrics
    ) {
        let rangeHeader = "bytes=\(offset)-\(offset + off_t(nbyte) - 1)"
        logger.debug(
            "Fetching S3 range",
            metadata: ["offset": "\(offset)", "nbyte": "\(nbyte)", "rangeHeader": "\(rangeHeader)"]
        )

        var request = HTTPClientRequest(url: url)
        request.headers.add(name: "Range", value: rangeHeader)

        let response = try await client.execute(request, timeout: .seconds(60))
        metrics?.recordHTTPStatus(statusCode: Int(response.status.code))
        guard response.status == .partialContent || response.status == .ok else {
            let body = await readS3ErrorBody(response)
            logger.warning(
                "S3 range fetch failed",
                metadata: [
                    "offset": "\(offset)", "nbyte": "\(nbyte)",
                    "httpStatus": "\(response.status.code)",
                    "responseBody": "\(body)",
                ]
            )
            throw AEADownloaderError.httpRangeFailed(offset: Int64(offset), status: Int(response.status.code))
        }

        // Pre-allocate a buffer sized for the requested range so the default
        // collect path doesn't keep growing the first received ByteBuffer as
        // larger chunks stream in.
        var body = ByteBuffer()
        body.reserveCapacity(nbyte)
        try await response.body.collect(upTo: nbyte + 1024, into: &body)
        logger.debug(
            "S3 range fetch complete",
            metadata: [
                "offset": "\(offset)", "requestedBytes": "\(nbyte)",
                "receivedBytes": "\(body.readableBytes)",
            ]
        )
        return body
    }
}

// MARK: - S3 download source

/// A ``DownloadSource`` backed by an S3-compatible object.
///
/// `sourceIdentifier()` issues a `HEAD` request and returns the `ETag` response header.
/// `fetch(_:)` performs an HTTP Range request against the S3 path-style endpoint.
struct S3DownloadSource: DownloadSource {
    private let client: S3Client
    private let logger: Logger
    private let retryConfiguration: RetryConfiguration
    private let metadataCache = MetadataCache<S3ObjectMetadata>()
    private let listingCache = MetadataCache<[S3ListItem]>()

    /// The prefix for directory listing mode; nil for single-file mode.
    private let prefix: String?
    /// The bucket name (needed for listing API).
    private let bucket: String
    /// The base URL (needed for listing API).
    private let baseURL: String
    /// Pre-created metrics for this asset, or nil if metrics are disabled.
    private let metrics: DownloadMetrics?

    init(
        client: S3Client,
        logger: Logger,
        retryConfiguration: RetryConfiguration = .default,
        prefix: String? = nil,
        bucket: String = "",
        baseURL: String = "",
        metrics: DownloadMetrics? = nil
    ) {
        self.client = client
        self.logger = logger
        self.retryConfiguration = retryConfiguration
        self.prefix = prefix
        self.bucket = bucket
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.metrics = metrics
    }

    /// Creates an `S3DownloadSource` for a single object.
    static func create(
        bucket: String,
        key: String,
        baseURL: String,
        auth: S3AuthMode,
        logger: Logger,
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryConfiguration: RetryConfiguration = .default,
        metrics: DownloadMetrics? = nil
    ) throws -> S3DownloadSource {
        try createImpl(
            bucket: bucket,
            key: key,
            prefix: nil,
            baseURL: baseURL,
            auth: auth,
            logger: logger,
            httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: httpReadTimeoutSeconds,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
    }

    /// Creates an `S3DownloadSource` for listing objects under a prefix.
    static func createDirectory(
        bucket: String,
        prefix: String,
        baseURL: String,
        auth: S3AuthMode,
        logger: Logger,
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryConfiguration: RetryConfiguration = .default,
        metrics: DownloadMetrics? = nil
    ) throws -> S3DownloadSource {
        try createImpl(
            bucket: bucket,
            key: prefix,
            prefix: prefix,
            baseURL: baseURL,
            auth: auth,
            logger: logger,
            httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: httpReadTimeoutSeconds,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
    }

    private static func createImpl(
        bucket: String,
        key: String,
        prefix: String?,
        baseURL: String,
        auth: S3AuthMode,
        logger: Logger,
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryConfiguration: RetryConfiguration = .default,
        metrics: DownloadMetrics? = nil
    ) throws -> S3DownloadSource {
        let client = try S3Client.create(
            bucket: bucket,
            key: key,
            baseURL: baseURL,
            auth: auth,
            logger: logger,
            httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: httpReadTimeoutSeconds
        )
        return S3DownloadSource(
            client: client,
            logger: logger,
            retryConfiguration: retryConfiguration,
            prefix: prefix,
            bucket: bucket,
            baseURL: baseURL,
            metrics: metrics
        )
    }

    private func getMetadata() async throws -> S3ObjectMetadata {
        if let cached = metadataCache.value {
            return cached
        }
        let metadata = try await fetchS3Metadata(
            logger: logger,
            client: client,
            url: client.downloadURL,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
        metadataCache.value = metadata
        return metadata
    }

    private func listObjects(prefix: String) async throws -> [S3ListItem] {
        if let cached = listingCache.value {
            return cached
        }

        var allItems: [S3ListItem] = []
        var continuationToken: String? = nil

        repeat {
            let currentToken = continuationToken
            let result: S3ListResult = try await withRetry(
                configuration: retryConfiguration,
                logger: logger,
                operation: .listObjects,
                metrics: metrics
            ) {
                var url = "\(baseURL)/\(bucket)?list-type=2&prefix=\(prefix)"
                if let token = currentToken {
                    url += "&continuation-token=\(token)"
                }

                var request = HTTPClientRequest(url: url)
                request.method = .GET

                logger.debug("Listing S3 objects", metadata: ["url": "\(url)"])
                let response = try await client.execute(request, timeout: .seconds(30))
                self.metrics?.recordHTTPStatus(statusCode: Int(response.status.code))
                guard response.status == .ok else {
                    let body = await readS3ErrorBody(response)
                    logger.warning(
                        "S3 list-objects failed",
                        metadata: [
                            "url": "\(url)",
                            "httpStatus": "\(response.status.code)",
                            "responseBody": "\(body)",
                        ]
                    )
                    throw AEADownloaderError.etagFetchFailed(status: Int(response.status.code))
                }

                let body = try await response.body.collect(upTo: 10 * 1024 * 1024)
                let bodyData = Data(buffer: body)

                let parser = S3ListObjectsV2Parser()
                return parser.parse(data: bodyData)
            }

            allItems.append(contentsOf: result.items)

            if result.isTruncated {
                continuationToken = result.nextContinuationToken
            } else {
                continuationToken = nil
            }
        } while continuationToken != nil

        listingCache.value = allItems
        return allItems
    }

    func sourceIdentifier() async throws -> String {
        if let prefix = prefix {
            let items = try await listObjects(prefix: prefix)
            let sorted = items.sorted { $0.key < $1.key }
            let composite = sorted.map { "\($0.key):\($0.etag)\n" }.joined()
            var hasher = SHA256()
            hasher.update(data: Data(composite.utf8))
            let hash = hasher.finalize()
            return "sha256:" + bytesToHex(hash)
        }
        return try await getMetadata().etag
    }

    func contents() async throws -> [SourceContentsEntry] {
        if let prefix = prefix {
            let items = try await listObjects(prefix: prefix)
            return items.map { item in
                let relativePath = String(item.key.dropFirst(prefix.count))
                return SourceContentsEntry(path: FilePath(relativePath), size: item.size)
            }
        }

        let metadata = try await getMetadata()
        guard let contentLength = metadata.contentLength else {
            throw AEADownloaderError.metadataParseFailed("Content-Length header missing")
        }
        // The URL parser rejects empty keys, so split always produces at least one element.
        let lastComponent = String(client.key.split(separator: "/").last!)
        return [SourceContentsEntry(path: FilePath(lastComponent), size: contentLength)]
    }

    func fetch(_ request: RangeRequest) async throws -> ByteBuffer {
        let url: String
        if let prefix {
            url = "\(baseURL)/\(bucket)/\(prefix + request.sourceEntry.path.string)"
        } else {
            url = client.downloadURL
        }

        return try await fetchS3Range(
            logger: logger,
            client: client,
            url: url,
            offset: request.offset,
            nbyte: request.length,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
    }

    /// Shuts down the underlying HTTP client.
    func shutdown() async throws {
        try await client.shutdown()
    }

    /// Creates an `S3DownloadSource`, passes it to `body`, and ensures `shutdown()`
    /// is called when `body` returns or throws.
    static func withSource<Result>(
        bucket: String,
        key: String,
        baseURL: String,
        auth: S3AuthMode,
        logger: Logger,
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryConfiguration: RetryConfiguration = .default,
        metrics: DownloadMetrics? = nil,
        _ body: (S3DownloadSource) async throws -> Result
    ) async throws -> Result {
        let source = try create(
            bucket: bucket,
            key: key,
            baseURL: baseURL,
            auth: auth,
            logger: logger,
            httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: httpReadTimeoutSeconds,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
        do {
            let result = try await body(source)
            try await source.shutdown()
            return result
        } catch {
            try? await source.shutdown()
            throw error
        }
    }

    /// Creates an `S3DownloadSource` in directory mode, passes it to `body`, and ensures
    /// `shutdown()` is called when `body` returns or throws.
    static func withDirectorySource<Result>(
        bucket: String,
        prefix: String,
        baseURL: String,
        auth: S3AuthMode,
        logger: Logger,
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryConfiguration: RetryConfiguration = .default,
        metrics: DownloadMetrics? = nil,
        _ body: (S3DownloadSource) async throws -> Result
    ) async throws -> Result {
        let source = try createDirectory(
            bucket: bucket,
            prefix: prefix,
            baseURL: baseURL,
            auth: auth,
            logger: logger,
            httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: httpReadTimeoutSeconds,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
        do {
            let result = try await body(source)
            try await source.shutdown()
            return result
        } catch {
            try? await source.shutdown()
            throw error
        }
    }
}
