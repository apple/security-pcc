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

// MARK: - GCS client

/// Bundles the HTTP machinery needed for GCS range requests.
struct GCSClient {
    let httpClient: HTTPClient
    let tokenProvider: TokenProvider
    let downloadURL: String
    let metadataURL: String
    let objectName: String
    let retryConfiguration: RetryConfiguration

    static func create(
        bucket: String,
        object: String,
        logger: Logger,
        metadataBaseURL: String = "http://metadata.google.internal",
        gcsBaseURL: String = "https://storage.googleapis.com",
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryConfiguration: RetryConfiguration = .default
    ) async throws -> GCSClient {
        let httpClient = HTTPClient(
            eventLoopGroup: .singletonMultiThreadedEventLoopGroup,
            configuration: makeBaseHTTPClientConfig(
                connectTimeout: .seconds(Int64(httpConnectTimeoutSeconds)),
                readTimeout: .seconds(Int64(httpReadTimeoutSeconds))
            )
        )

        let tokenProvider = try await TokenProvider.create(
            logger: logger,
            httpClient: httpClient,
            metadataBaseURL: metadataBaseURL,
            retryConfiguration: retryConfiguration
        )

        // Force-unwrap is safe: addingPercentEncoding can only fail with invalid UTF-16
        // surrogate pairs, which we don't expect to see in object names.
        let encodedObject = object.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let normalizedBaseURL = gcsBaseURL.hasSuffix("/") ? String(gcsBaseURL.dropLast()) : gcsBaseURL
        let metadataURL = "\(normalizedBaseURL)/storage/v1/b/\(bucket)/o/\(encodedObject)"
        let downloadURL = "\(metadataURL)?alt=media"

        return GCSClient(
            httpClient: httpClient,
            tokenProvider: tokenProvider,
            downloadURL: downloadURL,
            metadataURL: metadataURL,
            objectName: object,
            retryConfiguration: retryConfiguration
        )
    }

    func shutdown() async throws {
        tokenProvider.cancel()
        try await httpClient.shutdown()
    }
}

// MARK: - GCS metadata fetch

private struct GCSObjectMetadata: Decodable {
    var etag: String
    var size: String
}

private func fetchObjectMetadata(
    logger: Logger,
    httpClient: HTTPClient,
    metadataURL: String,
    tokenProvider: TokenProvider,
    retryConfiguration: RetryConfiguration = .default,
    metrics: DownloadMetrics? = nil
) async throws -> GCSObjectMetadata {
    try await withRetry(
        configuration: retryConfiguration,
        logger: logger,
        operation: .metadataFetch,
        metrics: metrics
    ) {
        let url = "\(metadataURL)?fields=etag,size"
        var request = HTTPClientRequest(url: url)
        request.headers.add(name: "Authorization", value: "Bearer \(tokenProvider.token)")

        logger.debug("Fetching object metadata", metadata: ["url": "\(url)"])
        let response = try await httpClient.execute(request, timeout: .seconds(30))
        metrics?.recordHTTPStatus(statusCode: Int(response.status.code))
        guard response.status == .ok else {
            throw AEADownloaderError.etagFetchFailed(status: Int(response.status.code))
        }

        let body = try await response.body.collect(upTo: 1024 * 1024)
        let metadata = try JSONDecoder().decode(GCSObjectMetadata.self, from: body)
        logger.debug("Got object metadata", metadata: ["etag": "\(metadata.etag)", "size": "\(metadata.size)"])
        return metadata
    }
}

// MARK: - HTTP range fetch

func fetchRange(
    logger: Logger,
    httpClient: HTTPClient,
    url: String,
    tokenProvider: TokenProvider,
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
            "Fetching range",
            metadata: ["offset": "\(offset)", "nbyte": "\(nbyte)", "rangeHeader": "\(rangeHeader)"]
        )

        var request = HTTPClientRequest(url: url)
        request.headers.add(name: "Authorization", value: "Bearer \(tokenProvider.token)")
        request.headers.add(name: "Range", value: rangeHeader)

        let response = try await httpClient.execute(request, timeout: .seconds(60))
        metrics?.recordHTTPStatus(statusCode: Int(response.status.code))
        guard response.status == .partialContent || response.status == .ok else {
            logger.warning(
                "Range fetch failed",
                metadata: ["offset": "\(offset)", "nbyte": "\(nbyte)", "httpStatus": "\(response.status.code)"]
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
            "Range fetch complete",
            metadata: ["offset": "\(offset)", "requestedBytes": "\(nbyte)", "receivedBytes": "\(body.readableBytes)"]
        )
        return body
    }
}

// MARK: - GCS list API types

private struct GCSListResponse: Decodable {
    var items: [GCSListItem]?
    var nextPageToken: String?
}

struct GCSListItem: Sendable {
    var name: String
    var etag: String
    var size: Int
}

extension GCSListItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name, etag, size
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.etag = try container.decode(String.self, forKey: .etag)
        // GCS returns size as a string in the JSON API
        let sizeString = try container.decode(String.self, forKey: .size)
        guard let size = Int(sizeString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .size,
                in: container,
                debugDescription: "Size '\(sizeString)' is not a valid integer"
            )
        }
        self.size = size
    }
}

// MARK: - GCS download source

/// A ``DownloadSource`` backed by a Google Cloud Storage object or directory prefix.
///
/// For single-file mode, `sourceIdentifier()` returns the object's ETag.
/// For directory mode, it returns a SHA-256 hash of all listed objects' name:etag pairs.
/// `fetch(_:)` performs an HTTP Range request against the GCS JSON API download endpoint.
struct GCSDownloadSource: DownloadSource {
    private let client: GCSClient
    private let logger: Logger
    private let retryConfiguration: RetryConfiguration
    private let metadataCache = MetadataCache<GCSObjectMetadata>()
    private let listingCache = MetadataCache<[GCSListItem]>()

    /// The prefix for directory listing mode; nil for single-file mode.
    private let prefix: String?
    /// The bucket name (needed for listing API).
    private let bucket: String
    /// The GCS base URL (needed for listing API).
    private let gcsBaseURL: String
    /// Pre-created metrics for this asset, or nil if metrics are disabled.
    private let metrics: DownloadMetrics?

    init(
        client: GCSClient,
        logger: Logger,
        prefix: String? = nil,
        bucket: String = "",
        gcsBaseURL: String = "",
        metrics: DownloadMetrics? = nil
    ) {
        self.client = client
        self.logger = logger
        self.retryConfiguration = client.retryConfiguration
        self.prefix = prefix
        self.bucket = bucket
        self.gcsBaseURL = gcsBaseURL.hasSuffix("/") ? String(gcsBaseURL.dropLast()) : gcsBaseURL
        self.metrics = metrics
    }

    /// Creates a `GCSDownloadSource` for a single object.
    static func create(
        bucket: String,
        object: String,
        logger: Logger,
        metadataBaseURL: String = "http://metadata.google.internal",
        gcsBaseURL: String = "https://storage.googleapis.com",
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryConfiguration: RetryConfiguration = .default,
        metrics: DownloadMetrics? = nil
    ) async throws -> GCSDownloadSource {
        try await createImpl(
            bucket: bucket,
            object: object,
            prefix: nil,
            logger: logger,
            metadataBaseURL: metadataBaseURL,
            gcsBaseURL: gcsBaseURL,
            httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: httpReadTimeoutSeconds,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
    }

    /// Creates a `GCSDownloadSource` for listing objects under a prefix.
    static func createDirectory(
        bucket: String,
        prefix: String,
        logger: Logger,
        metadataBaseURL: String = "http://metadata.google.internal",
        gcsBaseURL: String = "https://storage.googleapis.com",
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryConfiguration: RetryConfiguration = .default,
        metrics: DownloadMetrics? = nil
    ) async throws -> GCSDownloadSource {
        try await createImpl(
            bucket: bucket,
            object: prefix,
            prefix: prefix,
            logger: logger,
            metadataBaseURL: metadataBaseURL,
            gcsBaseURL: gcsBaseURL,
            httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: httpReadTimeoutSeconds,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
    }

    private static func createImpl(
        bucket: String,
        object: String,
        prefix: String?,
        logger: Logger,
        metadataBaseURL: String,
        gcsBaseURL: String,
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryConfiguration: RetryConfiguration = .default,
        metrics: DownloadMetrics? = nil
    ) async throws -> GCSDownloadSource {
        let client = try await GCSClient.create(
            bucket: bucket,
            object: object,
            logger: logger,
            metadataBaseURL: metadataBaseURL,
            gcsBaseURL: gcsBaseURL,
            httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: httpReadTimeoutSeconds,
            retryConfiguration: retryConfiguration
        )
        return GCSDownloadSource(
            client: client,
            logger: logger,
            prefix: prefix,
            bucket: bucket,
            gcsBaseURL: gcsBaseURL,
            metrics: metrics
        )
    }

    private func getMetadata() async throws -> GCSObjectMetadata {
        if let cached = metadataCache.value {
            return cached
        }
        let metadata = try await fetchObjectMetadata(
            logger: logger,
            httpClient: client.httpClient,
            metadataURL: client.metadataURL,
            tokenProvider: client.tokenProvider,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
        metadataCache.value = metadata
        return metadata
    }

    private func listObjects(prefix: String) async throws -> [GCSListItem] {
        if let cached = listingCache.value {
            return cached
        }

        var allItems: [GCSListItem] = []
        var pageToken: String? = nil

        repeat {
            let currentPageToken = pageToken
            let listResponse: GCSListResponse = try await withRetry(
                configuration: retryConfiguration,
                logger: logger,
                operation: .listObjects,
                metrics: metrics
            ) {
                var url =
                    "\(gcsBaseURL)/storage/v1/b/\(bucket)/o?prefix=\(prefix)&fields=items(name,etag,size),nextPageToken"
                if let token = currentPageToken {
                    url += "&pageToken=\(token)"
                }

                var request = HTTPClientRequest(url: url)
                request.headers.add(name: "Authorization", value: "Bearer \(client.tokenProvider.token)")

                logger.debug("Listing objects", metadata: ["url": "\(url)"])
                let response = try await client.httpClient.execute(request, timeout: .seconds(30))
                self.metrics?.recordHTTPStatus(statusCode: Int(response.status.code))
                guard response.status == .ok else {
                    throw AEADownloaderError.etagFetchFailed(status: Int(response.status.code))
                }

                let body = try await response.body.collect(upTo: 10 * 1024 * 1024)
                return try JSONDecoder().decode(GCSListResponse.self, from: body)
            }

            if let items = listResponse.items {
                allItems.append(contentsOf: items)
            }
            pageToken = listResponse.nextPageToken
        } while pageToken != nil

        listingCache.value = allItems
        return allItems
    }

    func sourceIdentifier() async throws -> String {
        if let prefix = prefix {
            let items = try await listObjects(prefix: prefix)
            let sorted = items.sorted { $0.name < $1.name }
            let composite = sorted.map { "\($0.name):\($0.etag)\n" }.joined()
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
                let relativePath = String(item.name.dropFirst(prefix.count))
                return SourceContentsEntry(path: FilePath(relativePath), size: item.size)
            }
        }

        let metadata = try await getMetadata()
        guard let size = Int(metadata.size) else {
            throw AEADownloaderError.metadataParseFailed("size is not a valid integer: \(metadata.size)")
        }
        // The URL parser rejects empty objects, so split always produces at least one element.
        let lastComponent = String(client.objectName.split(separator: "/").last!)
        return [SourceContentsEntry(path: FilePath(lastComponent), size: size)]
    }

    func fetch(_ request: RangeRequest) async throws -> ByteBuffer {
        let url: String
        if let prefix = prefix {
            let objectKey = prefix + request.sourceEntry.path.string
            let encodedKey = objectKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            url = "\(gcsBaseURL)/storage/v1/b/\(bucket)/o/\(encodedKey)?alt=media"
        } else {
            url = client.downloadURL
        }

        return try await fetchRange(
            logger: logger,
            httpClient: client.httpClient,
            url: url,
            tokenProvider: client.tokenProvider,
            offset: request.offset,
            nbyte: request.length,
            retryConfiguration: retryConfiguration,
            metrics: metrics
        )
    }

    /// Shuts down the underlying HTTP client and token provider.
    func shutdown() async throws {
        try await client.shutdown()
    }
}
