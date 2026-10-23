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
import WhisperClient

#if canImport(System)
import System
#else
import SystemPackage
#endif

// MARK: - Hex decoding

func hexToBytes<C: Collection>(_ hex: C) -> [UInt8] where C.Element == UInt8 {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    var it = hex.makeIterator()
    while let hi = it.next(), let lo = it.next() {
        guard let h = hexVal(hi), let l = hexVal(lo) else { return [] }
        bytes.append(h << 4 | l)
    }
    return bytes
}

/// Decodes an AEA symmetric key from its serialized form.
///
/// The input bytes must be prefixed with the ASCII bytes `hex:`, followed
/// by a valid hex-encoded key.  The prefix is stripped and the remainder
/// is hex-decoded to produce the raw key bytes.
///
/// - Throws: ``ConfigurationError/invalidSymmetricKey(_:)`` when the input
///   is empty, does not start with `hex:`, or the hex payload is invalid.
func decodeAEAKey<C: Collection>(_ raw: C) throws -> [UInt8] where C.Element == UInt8 {
    guard !raw.isEmpty else {
        throw ConfigurationError.invalidSymmetricKey("key is empty")
    }

    guard raw.starts(with: "hex:".utf8) else {
        throw ConfigurationError.invalidSymmetricKey(
            "key must start with hex: prefix"
        )
    }

    let hexPart = raw.dropFirst(4)
    let decoded = hexToBytes(hexPart)
    guard !decoded.isEmpty else {
        throw ConfigurationError.invalidSymmetricKey(
            "key has hex: prefix but contains invalid hex characters"
        )
    }
    return decoded
}

private func hexVal(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte &- UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte &- UInt8(ascii: "a") &+ 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte &- UInt8(ascii: "A") &+ 10
    default: return nil
    }
}

private let hexTable: [UInt8] = Array("0123456789abcdef".utf8)

func bytesToHex<C: Sequence>(_ bytes: C) -> String where C.Element == UInt8 {
    var utf8 = [UInt8]()
    utf8.reserveCapacity(bytes.underestimatedCount * 2)
    for byte in bytes {
        utf8.append(hexTable[Int(byte >> 4)])
        utf8.append(hexTable[Int(byte & 0x0F)])
    }
    return String(decoding: utf8, as: UTF8.self)
}

// MARK: - Errors

public enum AEADownloaderError: Error, Equatable, CustomStringConvertible, ReportableError {
    case metadataFetchFailed(status: Int)
    case httpRangeFailed(offset: Int64, status: Int)
    case asyncStreamGetRangeFailed(Int32)
    case asyncStreamProcessFailed(Int32)
    case asyncStreamCloseFailed(Int32)
    case etagFetchFailed(status: Int)
    case metadataParseFailed(String)
    case archiveIdentifierMismatch
    case archiveIdentifierNotValidated
    case secretFetchFailed(status: Int)
    case secretPayloadInvalid(String)

    public var description: String {
        switch self {
        case .metadataFetchFailed(let status):
            return "Failed to fetch GCE metadata token: HTTP \(status)"
        case .httpRangeFailed(let offset, let status):
            return "HTTP range request at offset \(offset) failed: HTTP \(status)"
        case .asyncStreamGetRangeFailed(let rc):
            return "__AAAsyncByteStreamGetRange failed with code \(rc)"
        case .asyncStreamProcessFailed(let rc):
            return "__AAAsyncByteStreamProcess failed with code \(rc)"
        case .asyncStreamCloseFailed(let rc):
            return "__AAAsyncByteStreamClose failed with code \(rc)"
        case .etagFetchFailed(let status):
            return "Failed to fetch GCS object ETag: HTTP \(status)"
        case .metadataParseFailed(let reason):
            return "Failed to parse source metadata: \(reason)"
        case .archiveIdentifierMismatch:
            return "Archive identifier does not match expected digest"
        case .archiveIdentifierNotValidated:
            return "Archive identifier validation was expected but did not occur"
        case .secretFetchFailed(let status):
            return "Failed to fetch secret from Google Secret Manager: HTTP \(status)"
        case .secretPayloadInvalid(let reason):
            return "Secret Manager payload was malformed: \(reason)"
        }
    }

    public var reportableDescription: String { description }
}

// MARK: - Streaming download and extract

@discardableResult
public func streamingDownloadAndExtract(
    logger: Logger,
    configuration: AEAConfiguration
) async throws -> DownloadResult {

    try configuration.validate()

    let assetName = configuration.sourceURL
    let context = DownloadContext(assetName: assetName)
    let clock = ContinuousClock()
    let startTime = clock.now

    do {
        let result: DownloadResult
        switch configuration.downloadMode {
        case .aea:
            result = try await aeaDownload(logger: logger, configuration: configuration, context: context)
        case .plainFile:
            result = try await plainFileDownload(logger: logger, configuration: configuration, context: context)
        }

        let elapsed = clock.now - startTime
        switch result {
        case .alreadyCurrent:
            context.metrics.recordDownloadSkipped(elapsed)
        case .downloaded:
            context.metrics.recordDownloadCompleted(elapsed)
        }
        return result
    } catch {
        let elapsed = clock.now - startTime
        context.metrics.recordDownloadFailed(elapsed, error: error)
        throw error
    }
}

// MARK: - AEA download

private func aeaDownload(
    logger: Logger,
    configuration: AEAConfiguration,
    context: DownloadContext
) async throws -> DownloadResult {
    let symmetricKeyBytes: [UInt8]
    if configuration.isWhisperConfigured {
        symmetricKeyBytes = try await resolveSymmetricKeyFromWhisper(
            configuration: configuration,
            logger: logger
        )
    } else {
        symmetricKeyBytes = try configuration.symmetricKeyBytes
    }
    let outputDir = FilePath(configuration.outputPath)
    let chunkSize = configuration.chunkSizeMB * 1_048_576

    return try await withSource(configuration: configuration, logger: logger, metrics: context.metrics) { source in
        let sink = AEADownloadSink(
            outputDir: outputDir,
            symmetricKeyBytes: symmetricKeyBytes,
            expectedArchiveIdentifierSHA256: try configuration.expectedArchiveIdentifierSHA256,
            chunkSize: chunkSize,
            allocLimit: configuration.allocLimit,
            threadCount: configuration.fileSystemThreadPoolSize,
            skipPaddingCheck: configuration.skipPaddingCheck,
            logger: logger
        )
        return try await download(
            from: source,
            to: sink,
            logger: logger,
            context: context,
            forceDownload: configuration.force,
            urlOnlyIdentityCheck: configuration.urlOnlyIdentityCheck,
            sourceURL: configuration.sourceURL
        )
    }
}

// MARK: - Plain file download

private func plainFileDownload(
    logger: Logger,
    configuration: AEAConfiguration,
    context: DownloadContext
) async throws -> DownloadResult {
    let outputDir = FilePath(configuration.outputPath)
    let chunkSize = configuration.chunkSizeMB * 1_048_576

    return try await withSource(configuration: configuration, logger: logger, metrics: context.metrics) { source in
        let sink = PlainFileDownloadSink(
            outputDirectory: outputDir,
            chunkSize: chunkSize,
            threadPoolSize: configuration.fileSystemThreadPoolSize,
            writeParallelismMultiplier: configuration.writeParallelismMultiplier,
            logger: logger
        )
        return try await download(
            from: source,
            to: sink,
            logger: logger,
            context: context,
            forceDownload: configuration.force,
            urlOnlyIdentityCheck: configuration.urlOnlyIdentityCheck,
            sourceURL: configuration.sourceURL
        )
    }
}

// MARK: - Whisper key resolution

/// Fetches the AEA symmetric key from Whisper using mTLS.
///
/// Creates a short-lived ``HTTPClient`` configured with the mTLS certificates
/// from `configuration`, fetches the secret, and shuts down the client.
/// If the secret bytes start with the ASCII prefix `hex:`, the remainder is
/// hex-decoded to produce the raw key bytes.
func resolveSymmetricKeyFromWhisper(
    configuration: AEAConfiguration,
    logger: Logger
) async throws -> [UInt8] {
    guard
        let secretName = configuration.whisperSecretName,
        let namespace = configuration.whisperNamespace,
        let serverURLString = configuration.whisperServerURL,
        let serverURL = URL(string: serverURLString),
        let certPath = configuration.whisperTLSCertificatePath,
        let keyPath = configuration.whisperTLSKeyPath
    else {
        preconditionFailure("resolveSymmetricKeyFromWhisper called without Whisper configuration")
    }

    logger.info(
        "Fetching symmetric key from Whisper",
        metadata: [
            "secretName": "\(secretName)",
            "namespace": "\(namespace)",
            "serverURL": "\(serverURLString)",
        ]
    )

    let tlsConfig = try makeBaseTLSConfigurationForMTLS(
        certificatePath: certPath,
        keyPath: keyPath,
        caCertificatePath: configuration.whisperTLSCACertificatePath
    )

    return try await withHTTPClient(
        tlsConfiguration: tlsConfig,
        connectTimeout: .seconds(Int64(configuration.httpConnectTimeoutSeconds)),
        readTimeout: .seconds(Int64(configuration.httpReadTimeoutSeconds))
    ) { httpClient in
        let provider = WhisperSecretProvider(
            httpClient: httpClient,
            serverURL: serverURL,
            logger: logger
        )

        let secretBytes: [UInt8]
        do {
            secretBytes = try await provider.fetchSecretWithRetry(
                name: secretName,
                namespace: namespace,
                retryConfiguration: configuration.retryConfiguration,
                logger: logger
            )
        } catch {
            logger.error(
                "Failed to fetch symmetric key from Whisper",
                metadata: ["error": "\(String(reportable: error))"]
            )
            throw error
        }

        let keyBytes: [UInt8]
        do {
            keyBytes = try decodeAEAKey(secretBytes)
        } catch {
            logger.error(
                "Whisper secret key decoding failed",
                metadata: ["error": "\(String(reportable: error))"]
            )
            throw error
        }

        logger.info("Successfully fetched symmetric key from Whisper")
        return keyBytes
    }
}

// MARK: - Source dispatch helper

/// Creates a ``DownloadSource`` appropriate for `configuration.sourceURLType`
/// and passes it to `body`. Handles lifecycle (e.g. GCS client shutdown).
private func withSource<Result: Sendable>(
    configuration: AEAConfiguration,
    logger: Logger,
    metrics: DownloadMetrics,
    _ body: (any DownloadSource) async throws -> Result
) async throws -> Result {
    switch configuration.sourceURLType {
    case .file(let path):
        logger.info("Loading local file into memory", metadata: ["path": "\(path)"])
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        logger.info("Loaded file")
        let source = InMemoryDownloadSource(data: fileData, logger: logger)
        return try await body(source)

    case .fileDirectory(let path):
        logger.info("Enumerating local directory", metadata: ["path": "\(path)"])
        let source = FileDirectorySource(directoryPath: path, logger: logger)
        return try await body(source)

    case .s3(let bucket, let key):
        return try await S3DownloadSource.withSource(
            bucket: bucket,
            key: key,
            baseURL: configuration.s3BaseURL,
            auth: configuration.s3AuthMode,
            logger: logger,
            httpConnectTimeoutSeconds: configuration.httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: configuration.httpReadTimeoutSeconds,
            retryConfiguration: configuration.retryConfiguration,
            metrics: metrics
        ) { source in
            try await body(source)
        }

    case .s3Directory(let bucket, let prefix):
        return try await S3DownloadSource.withDirectorySource(
            bucket: bucket,
            prefix: prefix,
            baseURL: configuration.s3BaseURL,
            auth: configuration.s3AuthMode,
            logger: logger,
            httpConnectTimeoutSeconds: configuration.httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: configuration.httpReadTimeoutSeconds,
            retryConfiguration: configuration.retryConfiguration,
            metrics: metrics
        ) { source in
            try await body(source)
        }

    case .gcs(let bucket, let object):
        let source = try await GCSDownloadSource.create(
            bucket: bucket,
            object: object,
            logger: logger,
            metadataBaseURL: configuration.metadataBaseURL,
            gcsBaseURL: configuration.gcsBaseURL,
            httpConnectTimeoutSeconds: configuration.httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: configuration.httpReadTimeoutSeconds,
            retryConfiguration: configuration.retryConfiguration,
            metrics: metrics
        )
        do {
            let result = try await body(source)
            try? await source.shutdown()
            return result
        } catch {
            try? await source.shutdown()
            throw error
        }

    case .gcsDirectory(let bucket, let prefix):
        let source = try await GCSDownloadSource.createDirectory(
            bucket: bucket,
            prefix: prefix,
            logger: logger,
            metadataBaseURL: configuration.metadataBaseURL,
            gcsBaseURL: configuration.gcsBaseURL,
            httpConnectTimeoutSeconds: configuration.httpConnectTimeoutSeconds,
            httpReadTimeoutSeconds: configuration.httpReadTimeoutSeconds,
            retryConfiguration: configuration.retryConfiguration,
            metrics: metrics
        )
        do {
            let result = try await body(source)
            try? await source.shutdown()
            return result
        } catch {
            try? await source.shutdown()
            throw error
        }
    }
}
