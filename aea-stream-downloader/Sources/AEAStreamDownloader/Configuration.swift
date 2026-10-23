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

import Configuration
import Foundation
import Logging

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - DownloadMode

/// Whether to decrypt an AEA archive or write a plain file directly.
public enum DownloadMode: String, Sendable, Equatable {
    case aea
    case plainFile
}

// MARK: - DownloaderMode

/// Forces how ``MultiDownloadConfiguration`` interprets its input config.
///
/// - `inferred`: try the indexed `downloads.N.*` layout first, fall back to
///   the top-level `sourceURL`/`outputPath` layout. This is the default and
///   matches historical behaviour.
/// - `multi`: only read `downloads.N.*`; any top-level `sourceURL` is ignored.
/// - `single`: only read the top-level `sourceURL`/`outputPath`; any
///   `downloads.N.*` fields are ignored.
///
/// The forced modes are lenient: fields belonging to the other spelling are
/// silently ignored. If a forced mode finds no matching fields, ``MultiDownloadConfiguration/downloads``
/// ends up empty.
public enum DownloaderMode: String, Sendable, Equatable {
    case single
    case multi
    case inferred
}

// MARK: - SourceURLType

/// Identifies which download backend to use, carrying the parsed URL components.
enum SourceURLType: Equatable {
    case gcs(bucket: String, object: String)
    case s3(bucket: String, key: String)
    case file(path: String)
    case gcsDirectory(bucket: String, prefix: String)
    case s3Directory(bucket: String, prefix: String)
    case fileDirectory(path: String)

    static func parse(_ url: String) -> SourceURLType? {
        if url.hasPrefix("file://") {
            let path = String(url.dropFirst(7))
            if path.hasSuffix("/*") {
                return .fileDirectory(path: String(path.dropLast(2)))
            }
            return .file(path: path)
        } else if let (bucket, object) = parseGSURL(url) {
            if object.hasSuffix("/*") {
                // Keep the trailing "/" as a prefix for listing
                return .gcsDirectory(bucket: bucket, prefix: String(object.dropLast()))
            }
            return .gcs(bucket: bucket, object: object)
        } else if let (bucket, key) = parseS3URL(url) {
            if key.hasSuffix("/*") {
                // Keep the trailing "/" as a prefix for listing
                return .s3Directory(bucket: bucket, prefix: String(key.dropLast()))
            }
            return .s3(bucket: bucket, key: key)
        }
        return nil
    }

    var isS3: Bool {
        switch self {
        case .s3, .s3Directory: return true
        default: return false
        }
    }
}

// MARK: - URL parsers

func parseGSURL(_ url: String) -> (bucket: String, object: String)? {
    guard url.hasPrefix("gs://") else { return nil }
    let rest = url.dropFirst(5)  // drop "gs://"
    guard let slashIndex = rest.firstIndex(of: "/") else { return nil }
    let bucket = String(rest[rest.startIndex..<slashIndex])
    let object = String(rest[rest.index(after: slashIndex)...])
    guard !bucket.isEmpty, !object.isEmpty else { return nil }
    return (bucket, object)
}

func parseS3URL(_ url: String) -> (bucket: String, key: String)? {
    guard url.hasPrefix("s3://") else { return nil }
    let rest = url.dropFirst(5)  // drop "s3://"
    guard let slashIndex = rest.firstIndex(of: "/") else { return nil }
    let bucket = String(rest[rest.startIndex..<slashIndex])
    let key = String(rest[rest.index(after: slashIndex)...])
    guard !bucket.isEmpty, !key.isEmpty else { return nil }
    return (bucket, key)
}

// MARK: - Configuration errors

/// Errors arising from invalid ``AEAConfiguration`` values.
public enum ConfigurationError: Error, CustomStringConvertible, ReportableError {
    case invalidSymmetricKey(String)
    case invalidSourceURL(String)
    case invalidChunkSize(Int)
    case missingS3Configuration(String)
    case invalidDownloadMode(String)
    case invalidDownloaderMode(String)
    case invalidFileSystemThreadPoolSize(Int)
    case invalidWriteParallelismMultiplier(Int)
    case invalidAllocLimit(Int)
    case multipleFilesNotSupported(count: Int)
    case missingWhisperConfiguration(String)
    case invalidHTTPTimeout(String, Int)
    case invalidRetryConfiguration(String)
    case invalidArchiveIdentifier(String)

    public var description: String {
        switch self {
        case .invalidSymmetricKey(let reason):
            return "Invalid symmetric key: \(reason)"
        case .invalidSourceURL(let reason):
            return "Invalid source URL: \(reason)"
        case .invalidChunkSize(let size):
            return "Invalid chunk size: \(size) (must be positive)"
        case .missingS3Configuration(let reason):
            return "Missing S3 configuration: \(reason)"
        case .invalidDownloadMode(let reason):
            return "Invalid download mode: \(reason)"
        case .invalidDownloaderMode(let reason):
            return "Invalid downloader mode: \(reason)"
        case .invalidFileSystemThreadPoolSize(let size):
            return "Invalid fileSystemThreadPoolSize: \(size) (must be positive)"
        case .invalidWriteParallelismMultiplier(let value):
            return "Invalid writeParallelismMultiplier: \(value) (must be positive)"
        case .invalidAllocLimit(let value):
            return "Invalid allocLimit: \(value) (must be non-negative or AEAConfiguration.unlimitedAllocLimit)"
        case .multipleFilesNotSupported(let count):
            return "Source contains \(count) files, but multi-file download is not supported"
        case .missingWhisperConfiguration(let reason):
            return "Missing Whisper configuration: \(reason)"
        case .invalidHTTPTimeout(let field, let value):
            return "Invalid HTTP timeout \(field): \(value) (must be positive)"
        case .invalidRetryConfiguration(let reason):
            return "Invalid retry configuration: \(reason)"
        case .invalidArchiveIdentifier(let reason):
            return "Invalid archive identifier: \(reason)"
        }
    }

    public var reportableDescription: String { description }
}

// MARK: - AEAConfiguration

/// Configuration for the AEA stream downloader.
///
/// Supports two initialization paths:
/// - Explicit values (for programmatic use and testing).
/// - ``ConfigReader``-based (for CLI / environment / file-based configuration).
///
/// The ``ConfigReader`` initializer reads keys **without** a namespace prefix;
/// callers are responsible for scoping (e.g. `config.scoped(to: "aea")`).
public struct AEAConfiguration: Sendable {
    /// Sentinel `allocLimit` value meaning "no byte budget — let `fileSystemThreadPoolSize`
    /// drive the chunk async stream's in-flight chunk count."
    ///
    /// The C API (`__AEADecryptAndExtractChunkAsyncStreamOpen`) switches on
    /// `alloc_limit == SIZE_MAX`. We round-trip `SIZE_MAX` through `Int(bitPattern:)`
    /// because Swift imports `SIZE_MAX` as `UInt` but the function parameter as `Int`.
    public static let unlimitedAllocLimit: Int = Int(bitPattern: SIZE_MAX)

    public var sourceURL: String {
        // Force-unwrap is intentional: setting sourceURL to an unparseable value
        // is a programmer error; use the throwing init to validate upfront.
        didSet { sourceURLType = SourceURLType.parse(sourceURL)! }
    }
    public var outputPath: String
    public var symmetricKeyHex: String
    public var chunkSizeMB: Int
    public var verbose: Bool
    public var force: Bool
    public var metadataBaseURL: String
    public var gcsBaseURL: String
    public var s3BaseURL: String
    public var s3TLSCertificatePath: String
    public var s3TLSKeyPath: String
    public var s3TLSCACertificatePath: String?
    var s3SigV4Credentials: SigV4Credentials?
    var s3Region: String
    public var downloadMode: DownloadMode
    public var fileSystemThreadPoolSize: Int
    public var writeParallelismMultiplier: Int
    public var allocLimit: Int
    public var whisperSecretName: String?
    public var whisperNamespace: String?
    public var whisperServerURL: String?
    public var whisperTLSCertificatePath: String?
    public var whisperTLSKeyPath: String?
    public var whisperTLSCACertificatePath: String?

    /// Explicit master switch for the Whisper feature.
    ///
    /// Three-valued to distinguish an unset key from an explicit assertion:
    /// - `nil` (the default) — inferred: Whisper is on iff ``whisperSecretName``
    ///   is set. This preserves the historical behaviour where merely providing
    ///   a Whisper secret enables the feature.
    /// - `true` — Whisper is asserted to be on. If ``whisperSecretName`` is
    ///   missing, ``validate()`` throws rather than silently falling back to
    ///   symmetric-key mode, so an `AEA_WHISPER_ENABLED=true` env var whose
    ///   secret name failed to arrive fails loudly.
    /// - `false` — Whisper is off, regardless of ``whisperSecretName``. This is
    ///   the escape hatch for higher-priority providers that need to disable
    ///   Whisper even when a lower provider has configured it; the layered
    ///   provider stack resolves "first non-nil wins" and there is no way to
    ///   *unset* a lower layer's value.
    public var whisperEnabled: Bool?
    public var httpConnectTimeoutSeconds: Int
    public var httpReadTimeoutSeconds: Int
    public var retryMaxAttempts: Int
    public var retryBaseDelayMilliseconds: Int
    public var retryMaxDelaySeconds: Int
    public var retryJitterFactor: Double
    public var archiveIdSha256: String?

    /// When `true`, the download orchestrator first compares the source URL
    /// against a URL persisted in the sentinel file, and returns `.alreadyCurrent`
    /// on a match *without* calling `source.sourceIdentifier()`. This avoids the
    /// auth-carrying metadata / list request required to compute the ETag/hash
    /// identifier. On a URL miss the orchestrator falls back to the existing
    /// identifier-based check.
    ///
    /// Defaults to `false` for backwards compatibility. The `aea-stream-downloader`
    /// executable forces this to `true` for all downloads.
    public var urlOnlyIdentityCheck: Bool

    /// When `true`, passes `AA_FLAG_ENCRYPTED_STREAM_NO_PADDING_CHECK` to the
    /// AEA async decrypt+extract stream, which suppresses the terminal padding
    /// verification pass performed at end-of-stream. For very large archives
    /// (hundreds of GB) the padding walk is a meaningful fraction of total
    /// wall-clock. Skipping it is safe when the caller already gates on
    /// ``archiveIdSha256`` or another end-to-end integrity check.
    ///
    /// Defaults to `false` — historical behaviour is to verify padding.
    public var skipPaddingCheck: Bool

    /// Builds a ``RetryConfiguration`` from the individual retry fields.
    var retryConfiguration: RetryConfiguration {
        RetryConfiguration(
            maxAttempts: retryMaxAttempts,
            baseDelay: .milliseconds(retryBaseDelayMilliseconds),
            maxDelay: .seconds(retryMaxDelaySeconds),
            jitterFactor: retryJitterFactor
        )
    }

    /// Whether Whisper-based key retrieval is configured.
    ///
    /// - If ``whisperEnabled`` is `nil` (unset), Whisper is on iff
    ///   ``whisperSecretName`` is non-nil — the historical inference.
    /// - If ``whisperEnabled`` is `true` (explicit), Whisper is on. ``validate()``
    ///   guarantees that in this case ``whisperSecretName`` is also set.
    /// - If ``whisperEnabled`` is `false` (explicit), Whisper is off, ignoring
    ///   ``whisperSecretName``. This is how a higher-priority config provider
    ///   disables Whisper when a lower provider had it configured.
    public var isWhisperConfigured: Bool {
        whisperEnabled ?? (whisperSecretName != nil)
    }

    /// The authentication mode the S3 source should use, derived from
    /// configuration. SigV4 takes precedence when credentials have been
    /// resolved (e.g. from `GCP_SECRET_NAME`); otherwise mTLS using the
    /// configured certificate paths.
    var s3AuthMode: S3AuthMode {
        if let credentials = s3SigV4Credentials {
            return .sigV4(credentials: credentials, region: s3Region)
        }
        return .mTLS(
            certificatePath: s3TLSCertificatePath,
            keyPath: s3TLSKeyPath,
            caCertificatePath: s3TLSCACertificatePath
        )
    }

    /// Decodes `archiveIdSha256` from base64 into raw bytes.
    /// Returns `nil` if `archiveIdSha256` is `nil`.
    /// Throws if the string is non-nil but cannot be decoded.
    var expectedArchiveIdentifierSHA256: Data? {
        get throws {
            guard let encoded = archiveIdSha256 else { return nil }
            guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
                throw ConfigurationError.invalidArchiveIdentifier(
                    "archiveIdSha256 is not valid base64 or decodes to empty"
                )
            }
            return data
        }
    }

    /// Parsed from `sourceURL` at init time and kept in sync via `didSet`.
    /// Used by `validate()` and `streamingDownloadAndExtract` to avoid repeated prefix checks.
    private(set) var sourceURLType: SourceURLType

    public init(
        sourceURL: String,
        outputPath: String,
        symmetricKeyHex: String = "",
        chunkSizeMB: Int = 1,
        verbose: Bool = false,
        force: Bool = false,
        metadataBaseURL: String = "http://metadata.google.internal",
        gcsBaseURL: String = "https://storage.googleapis.com",
        s3BaseURL: String = "",
        s3TLSCertificatePath: String = "",
        s3TLSKeyPath: String = "",
        s3TLSCACertificatePath: String? = nil,
        s3Region: String = "conductor",
        downloadMode: DownloadMode = .aea,
        fileSystemThreadPoolSize: Int = 2,
        writeParallelismMultiplier: Int = 4,
        allocLimit: Int = AEAConfiguration.unlimitedAllocLimit,
        whisperSecretName: String? = nil,
        whisperNamespace: String? = nil,
        whisperServerURL: String? = nil,
        whisperTLSCertificatePath: String? = nil,
        whisperTLSKeyPath: String? = nil,
        whisperTLSCACertificatePath: String? = nil,
        whisperEnabled: Bool? = nil,
        httpConnectTimeoutSeconds: Int = 10,
        httpReadTimeoutSeconds: Int = 5,
        retryMaxAttempts: Int = 20,
        retryBaseDelayMilliseconds: Int = 250,
        retryMaxDelaySeconds: Int = 30,
        retryJitterFactor: Double = 0.25,
        archiveIdSha256: String? = nil,
        urlOnlyIdentityCheck: Bool = false,
        skipPaddingCheck: Bool = false
    ) throws {
        guard let urlType = SourceURLType.parse(sourceURL) else {
            throw ConfigurationError.invalidSourceURL(
                "URL must start with gs://, file://, or s3://, got: \(sourceURL)"
            )
        }
        self.sourceURL = sourceURL
        self.sourceURLType = urlType
        self.outputPath = outputPath
        self.symmetricKeyHex = symmetricKeyHex
        self.chunkSizeMB = chunkSizeMB
        self.verbose = verbose
        self.force = force
        self.metadataBaseURL = metadataBaseURL
        self.gcsBaseURL = gcsBaseURL
        self.s3BaseURL = s3BaseURL
        self.s3TLSCertificatePath = s3TLSCertificatePath
        self.s3TLSKeyPath = s3TLSKeyPath
        self.s3TLSCACertificatePath = s3TLSCACertificatePath
        self.s3SigV4Credentials = nil
        self.s3Region = s3Region
        self.downloadMode = downloadMode
        self.fileSystemThreadPoolSize = fileSystemThreadPoolSize
        self.writeParallelismMultiplier = writeParallelismMultiplier
        self.allocLimit = allocLimit
        self.whisperSecretName = whisperSecretName
        self.whisperNamespace = whisperNamespace
        self.whisperServerURL = whisperServerURL
        self.whisperTLSCertificatePath = whisperTLSCertificatePath
        self.whisperTLSKeyPath = whisperTLSKeyPath
        self.whisperTLSCACertificatePath = whisperTLSCACertificatePath
        self.whisperEnabled = whisperEnabled
        self.httpConnectTimeoutSeconds = httpConnectTimeoutSeconds
        self.httpReadTimeoutSeconds = httpReadTimeoutSeconds
        self.retryMaxAttempts = retryMaxAttempts
        self.retryBaseDelayMilliseconds = retryBaseDelayMilliseconds
        self.retryMaxDelaySeconds = retryMaxDelaySeconds
        self.retryJitterFactor = retryJitterFactor
        self.archiveIdSha256 = archiveIdSha256
        self.urlOnlyIdentityCheck = urlOnlyIdentityCheck
        self.skipPaddingCheck = skipPaddingCheck
    }
}

// MARK: - ConfigReader initializer

extension AEAConfiguration {
    /// Creates an ``AEAConfiguration`` by reading values from a ``ConfigReader``.
    ///
    /// Expected keys (relative — no namespace prefix):
    /// - `sourceURL` (required)
    /// - `outputPath` (required)
    /// - `symmetricKey` (required for `.aea` mode unless Whisper is configured, secret)
    /// - `chunkSizeMB` (optional, default `1`)
    /// - `verbose` (optional, default `false`)
    /// - `force` (optional, default `false`)
    /// - `downloadMode` (optional, default `aea`)
    /// - `fileSystemThreadPoolSize` (optional, default `2`)
    /// - `writeParallelismMultiplier` (optional, default `4`)
    /// - `skipPaddingCheck` (optional, default `false`) — skip AEA padding
    ///   verification at end of stream
    ///
    /// S3 keys use dot-separated components so that the ``EnvironmentVariablesProvider``
    /// produces readable environment variable names (e.g. `AEA_S3_BASE_URL` instead of
    /// `AEA_S3BASE_URL`):
    /// - `s3.baseURL`
    /// - `s3.tls.certificatePath`
    /// - `s3.tls.keyPath`
    /// - `s3.tls.caCertificatePath`
    ///
    /// Whisper keys follow the same dot-separated convention:
    /// - `whisper.enabled` (optional; unset means "infer from `whisper.secretName`
    ///   presence"). Set to `false` from a higher-priority provider to disable
    ///   Whisper when a lower provider had configured it. Setting `true`
    ///   without a `whisper.secretName` fails validation rather than silently
    ///   falling back to symmetric-key mode.
    /// - `whisper.secretName`
    /// - `whisper.namespace`
    /// - `whisper.serverURL`
    /// - `whisper.tls.certificatePath`
    /// - `whisper.tls.keyPath`
    /// - `whisper.tls.caCertificatePath`
    public init(config: ConfigReader) throws {
        let sourceURL = try config.requiredString(forKey: "sourceURL")
        guard let urlType = SourceURLType.parse(sourceURL) else {
            throw ConfigurationError.invalidSourceURL(
                "URL must start with gs://, file://, or s3://, got: \(sourceURL)"
            )
        }
        self.sourceURL = sourceURL
        self.sourceURLType = urlType
        self.outputPath = try config.requiredString(forKey: "outputPath")

        let modeString = config.string(forKey: "downloadMode") ?? "aea"
        guard let mode = DownloadMode(rawValue: modeString) else {
            throw ConfigurationError.invalidDownloadMode(
                "expected 'aea' or 'plainFile', got '\(modeString)'"
            )
        }
        self.downloadMode = mode

        // Read Whisper fields first so we can relax the symmetricKey requirement.
        self.whisperEnabled = config.bool(forKey: "whisper.enabled")
        self.whisperSecretName = config.string(forKey: "whisper.secretName")
        self.whisperNamespace = config.string(forKey: "whisper.namespace")
        self.whisperServerURL = config.string(forKey: "whisper.serverURL")
        self.whisperTLSCertificatePath = config.string(forKey: "whisper.tls.certificatePath")
        self.whisperTLSKeyPath = config.string(forKey: "whisper.tls.keyPath")
        self.whisperTLSCACertificatePath = config.string(forKey: "whisper.tls.caCertificatePath")

        // Mirrors `isWhisperConfigured`; inlined because `self` isn't fully
        // initialized yet.
        let whisperActive = self.whisperEnabled ?? (self.whisperSecretName != nil)
        if mode == .aea && !whisperActive {
            self.symmetricKeyHex = try config.requiredString(forKey: "symmetricKey", isSecret: true)
        } else {
            self.symmetricKeyHex = config.string(forKey: "symmetricKey") ?? ""
        }

        self.chunkSizeMB = config.int(forKey: "chunkSizeMB") ?? 1
        self.verbose = config.bool(forKey: "verbose") ?? false
        self.force = config.bool(forKey: "force") ?? false
        self.metadataBaseURL =
            config.string(forKey: "metadataBaseURL") ?? "http://metadata.google.internal"
        self.gcsBaseURL =
            config.string(forKey: "gcsBaseURL") ?? "https://storage.googleapis.com"
        self.s3BaseURL = config.string(forKey: "s3.baseURL") ?? ""
        self.s3TLSCertificatePath = config.string(forKey: "s3.tls.certificatePath") ?? ""
        self.s3TLSKeyPath = config.string(forKey: "s3.tls.keyPath") ?? ""
        self.s3TLSCACertificatePath = config.string(forKey: "s3.tls.caCertificatePath")
        self.s3SigV4Credentials = nil
        self.s3Region = config.string(forKey: "s3.region") ?? "conductor"
        self.fileSystemThreadPoolSize = config.int(forKey: "fileSystemThreadPoolSize") ?? 2
        self.writeParallelismMultiplier = config.int(forKey: "writeParallelismMultiplier") ?? 4
        self.allocLimit = config.int(forKey: "allocLimit") ?? AEAConfiguration.unlimitedAllocLimit
        self.httpConnectTimeoutSeconds = config.int(forKey: "http.connectTimeoutSeconds") ?? 10
        self.httpReadTimeoutSeconds = config.int(forKey: "http.readTimeoutSeconds") ?? 5
        self.retryMaxAttempts = config.int(forKey: "retry.maxAttempts") ?? 20
        self.retryBaseDelayMilliseconds = config.int(forKey: "retry.baseDelayMilliseconds") ?? 250
        self.retryMaxDelaySeconds = config.int(forKey: "retry.maxDelaySeconds") ?? 30
        self.retryJitterFactor = config.double(forKey: "retry.jitterFactor") ?? 0.25
        self.archiveIdSha256 = config.string(forKey: "archiveIdSha256")
        self.urlOnlyIdentityCheck = config.bool(forKey: "urlOnlyIdentityCheck") ?? false
        self.skipPaddingCheck = config.bool(forKey: "skipPaddingCheck") ?? false
    }
}

// MARK: - Validation

extension AEAConfiguration {
    /// The symmetric key decoded from its hex-encoded serialized form.
    ///
    /// The key string is always hex-decoded. It may optionally start with a
    /// `hex:` prefix, which is stripped before decoding.
    ///
    /// - Throws: ``ConfigurationError/invalidSymmetricKey(_:)`` if the key is
    ///   empty or contains invalid hex characters.
    public var symmetricKeyBytes: [UInt8] {
        get throws {
            let key =
                symmetricKeyHex.utf8.starts(with: "hex:".utf8)
                ? symmetricKeyHex : "hex:" + symmetricKeyHex
            return try decodeAEAKey(key.utf8)
        }
    }

    /// Validates that all configuration values are well-formed.
    ///
    /// - Throws: ``ConfigurationError`` on the first invalid value found.
    public func validate() throws {
        if downloadMode == .aea && !isWhisperConfigured {
            _ = try symmetricKeyBytes
        }

        if isWhisperConfigured {
            // If `whisperEnabled == true` was asserted but no secret name was
            // supplied, fail loudly rather than silently falling back to
            // symmetric-key mode. When `whisperEnabled == nil`, this branch is
            // only reached because `whisperSecretName` is set, so the check is
            // a no-op there.
            guard let secretName = whisperSecretName, !secretName.isEmpty else {
                throw ConfigurationError.missingWhisperConfiguration(
                    "whisperSecretName is required when whisperEnabled is true"
                )
            }
            guard let serverURL = whisperServerURL, !serverURL.isEmpty else {
                throw ConfigurationError.missingWhisperConfiguration(
                    "whisperServerURL is required when whisperSecretName is set"
                )
            }
            guard let namespace = whisperNamespace, !namespace.isEmpty else {
                throw ConfigurationError.missingWhisperConfiguration(
                    "whisperNamespace is required when whisperSecretName is set"
                )
            }
            guard let certPath = whisperTLSCertificatePath, !certPath.isEmpty else {
                throw ConfigurationError.missingWhisperConfiguration(
                    "whisperTLSCertificatePath is required when whisperSecretName is set"
                )
            }
            guard let keyPath = whisperTLSKeyPath, !keyPath.isEmpty else {
                throw ConfigurationError.missingWhisperConfiguration(
                    "whisperTLSKeyPath is required when whisperSecretName is set"
                )
            }
        }

        if sourceURLType.isS3 {
            guard !s3BaseURL.isEmpty else {
                throw ConfigurationError.missingS3Configuration("s3BaseURL is required for s3:// URLs")
            }
            if s3SigV4Credentials == nil {
                guard !s3TLSCertificatePath.isEmpty else {
                    throw ConfigurationError.missingS3Configuration(
                        "s3TLSCertificatePath is required for s3:// URLs"
                    )
                }
                guard !s3TLSKeyPath.isEmpty else {
                    throw ConfigurationError.missingS3Configuration(
                        "s3TLSKeyPath is required for s3:// URLs"
                    )
                }
            }
        }

        guard chunkSizeMB > 0 else {
            throw ConfigurationError.invalidChunkSize(chunkSizeMB)
        }

        guard fileSystemThreadPoolSize > 0 else {
            throw ConfigurationError.invalidFileSystemThreadPoolSize(fileSystemThreadPoolSize)
        }

        guard writeParallelismMultiplier > 0 else {
            throw ConfigurationError.invalidWriteParallelismMultiplier(writeParallelismMultiplier)
        }

        guard allocLimit >= 0 || allocLimit == AEAConfiguration.unlimitedAllocLimit else {
            throw ConfigurationError.invalidAllocLimit(allocLimit)
        }

        guard httpConnectTimeoutSeconds > 0 else {
            throw ConfigurationError.invalidHTTPTimeout(
                "connectTimeoutSeconds",
                httpConnectTimeoutSeconds
            )
        }

        guard httpReadTimeoutSeconds > 0 else {
            throw ConfigurationError.invalidHTTPTimeout(
                "readTimeoutSeconds",
                httpReadTimeoutSeconds
            )
        }

        guard retryMaxAttempts >= 1 else {
            throw ConfigurationError.invalidRetryConfiguration(
                "maxAttempts must be >= 1, got \(retryMaxAttempts)"
            )
        }

        guard retryBaseDelayMilliseconds > 0 else {
            throw ConfigurationError.invalidRetryConfiguration(
                "baseDelayMilliseconds must be positive, got \(retryBaseDelayMilliseconds)"
            )
        }

        guard retryMaxDelaySeconds > 0 else {
            throw ConfigurationError.invalidRetryConfiguration(
                "maxDelaySeconds must be positive, got \(retryMaxDelaySeconds)"
            )
        }

        guard retryJitterFactor >= 0.0 && retryJitterFactor <= 1.0 else {
            throw ConfigurationError.invalidRetryConfiguration(
                "jitterFactor must be between 0.0 and 1.0, got \(retryJitterFactor)"
            )
        }

        // Validate archive identifier if provided.
        _ = try expectedArchiveIdentifierSHA256
    }
}

// MARK: - MultiDownloadConfiguration

/// Wraps one or more ``AEAConfiguration`` values parsed from a single config source.
///
/// Supports two layouts:
/// 1. **Indexed downloads** — `downloads.0.*`, `downloads.1.*`, … with contiguous indices.
///    Per-download fields fall back to global defaults when not set at the indexed scope.
/// 2. **Legacy single download** — top-level `sourceURL` / `outputPath` (delegates to
///    ``AEAConfiguration/init(config:)``).
///
/// Which layout is used is controlled by the ``DownloaderMode`` value read from
/// the top-level `downloaderMode` field. The default (``DownloaderMode/inferred``)
/// preserves the historical "try indexed, fall back to legacy" behaviour;
/// callers who source config from multiple layered providers can set
/// `downloaderMode` to force `single` or `multi` explicitly.
///
/// Global-only fields (`verbose`, `gcsBaseURL`, S3/Whisper infrastructure, etc.) are read
/// once from the top-level scope and applied to every download.
public struct MultiDownloadConfiguration: Sendable {
    public var downloads: [AEAConfiguration]
    public var downloaderMode: DownloaderMode
    public var verbose: Bool
    public var tlsCertificateTimeoutSeconds: Int
    public var httpConnectTimeoutSeconds: Int
    public var httpReadTimeoutSeconds: Int
    public var retryMaxAttempts: Int
    public var retryBaseDelayMilliseconds: Int
    public var retryMaxDelaySeconds: Int
    public var retryJitterFactor: Double

    /// Collects all mTLS certificate and key paths across all downloads
    /// (S3 and Whisper) that should be waited on before proceeding.
    public var mtlsCertificatePathsToWaitFor: Set<String> {
        var paths = Set<String>()
        for dl in downloads {
            if !dl.s3TLSCertificatePath.isEmpty { paths.insert(dl.s3TLSCertificatePath) }
            if !dl.s3TLSKeyPath.isEmpty { paths.insert(dl.s3TLSKeyPath) }
            if let p = dl.whisperTLSCertificatePath, !p.isEmpty { paths.insert(p) }
            if let p = dl.whisperTLSKeyPath, !p.isEmpty { paths.insert(p) }
        }
        return paths
    }
}

extension MultiDownloadConfiguration {
    /// Creates a ``MultiDownloadConfiguration`` by reading values from a ``ConfigReader``.
    ///
    /// The reader should already be scoped to the application namespace (e.g. `"aea"`).
    public init(config: ConfigReader) throws {
        // -- Global-only fields -----------------------------------------------
        let verbose = config.bool(forKey: "verbose") ?? false
        let metadataBaseURL =
            config.string(forKey: "metadataBaseURL") ?? "http://metadata.google.internal"
        let gcsBaseURL =
            config.string(forKey: "gcsBaseURL") ?? "https://storage.googleapis.com"
        let s3BaseURL = config.string(forKey: "s3.baseURL") ?? ""
        let s3TLSCertificatePath = config.string(forKey: "s3.tls.certificatePath") ?? ""
        let s3TLSKeyPath = config.string(forKey: "s3.tls.keyPath") ?? ""
        let s3TLSCACertificatePath = config.string(forKey: "s3.tls.caCertificatePath")
        let s3Region = config.string(forKey: "s3.region") ?? "conductor"
        let fileSystemThreadPoolSize = config.int(forKey: "fileSystemThreadPoolSize") ?? 2
        let writeParallelismMultiplier = config.int(forKey: "writeParallelismMultiplier") ?? 4
        let allocLimit = config.int(forKey: "allocLimit") ?? AEAConfiguration.unlimitedAllocLimit
        let whisperServerURL = config.string(forKey: "whisper.serverURL")
        let whisperTLSCertificatePath = config.string(forKey: "whisper.tls.certificatePath")
        let whisperTLSKeyPath = config.string(forKey: "whisper.tls.keyPath")
        let whisperTLSCACertificatePath = config.string(forKey: "whisper.tls.caCertificatePath")
        let httpConnectTimeoutSeconds = config.int(forKey: "http.connectTimeoutSeconds") ?? 10
        let httpReadTimeoutSeconds = config.int(forKey: "http.readTimeoutSeconds") ?? 5
        let retryMaxAttempts = config.int(forKey: "retry.maxAttempts") ?? 20
        let retryBaseDelayMilliseconds = config.int(forKey: "retry.baseDelayMilliseconds") ?? 250
        let retryMaxDelaySeconds = config.int(forKey: "retry.maxDelaySeconds") ?? 30
        let retryJitterFactor = config.double(forKey: "retry.jitterFactor") ?? 0.25

        // -- Per-download global defaults -------------------------------------
        let defaultSymmetricKeyHex = config.string(forKey: "symmetricKey", isSecret: true) ?? ""
        let defaultDownloadModeString = config.string(forKey: "downloadMode") ?? "aea"
        let defaultChunkSizeMB = config.int(forKey: "chunkSizeMB") ?? 1
        let defaultForce = config.bool(forKey: "force") ?? false
        let defaultAllocLimit = allocLimit
        let defaultWhisperSecretName = config.string(forKey: "whisper.secretName")
        let defaultWhisperNamespace = config.string(forKey: "whisper.namespace")
        let defaultWhisperEnabled: Bool? = config.bool(forKey: "whisper.enabled")
        let defaultURLOnlyIdentityCheck = config.bool(forKey: "urlOnlyIdentityCheck") ?? false
        let defaultSkipPaddingCheck = config.bool(forKey: "skipPaddingCheck") ?? false

        // -- Downloader mode --------------------------------------------------
        let downloaderModeString = config.string(forKey: "downloaderMode") ?? "inferred"
        guard let downloaderMode = DownloaderMode(rawValue: downloaderModeString) else {
            throw ConfigurationError.invalidDownloaderMode(
                "expected 'single', 'multi', or 'inferred', got '\(downloaderModeString)'"
            )
        }

        // -- Probe indexed downloads ------------------------------------------
        let downloadsScope = config.scoped(to: "downloads")

        func probeIndexedDownloads() throws -> [AEAConfiguration] {
            var configurations: [AEAConfiguration] = []
            for i in 0... {
                let indexScope = downloadsScope.scoped(to: ConfigKey("\(i)"))

                guard let sourceURL = indexScope.string(forKey: "sourceURL") else {
                    break
                }

                let outputPath = try indexScope.requiredString(forKey: "outputPath")

                let modeString =
                    indexScope.string(forKey: "downloadMode") ?? defaultDownloadModeString
                guard let downloadMode = DownloadMode(rawValue: modeString) else {
                    throw ConfigurationError.invalidDownloadMode(
                        "expected 'aea' or 'plainFile', got '\(modeString)'"
                    )
                }

                let symmetricKeyHex =
                    indexScope.string(forKey: "symmetricKey", isSecret: true)
                    ?? defaultSymmetricKeyHex
                let chunkSizeMB = indexScope.int(forKey: "chunkSizeMB") ?? defaultChunkSizeMB
                let force = indexScope.bool(forKey: "force") ?? defaultForce
                let perDownloadAllocLimit =
                    indexScope.int(forKey: "allocLimit") ?? defaultAllocLimit
                let whisperSecretName =
                    indexScope.string(forKey: "whisper.secretName") ?? defaultWhisperSecretName
                let whisperNamespace =
                    indexScope.string(forKey: "whisper.namespace") ?? defaultWhisperNamespace
                let whisperEnabled: Bool? =
                    indexScope.bool(forKey: "whisper.enabled") ?? defaultWhisperEnabled
                let archiveIdSha256 = indexScope.string(forKey: "archiveIdSha256")
                let urlOnlyIdentityCheck =
                    indexScope.bool(forKey: "urlOnlyIdentityCheck") ?? defaultURLOnlyIdentityCheck
                let skipPaddingCheck =
                    indexScope.bool(forKey: "skipPaddingCheck") ?? defaultSkipPaddingCheck

                // Validate symmetric key requirement for AEA mode.
                let whisperActive = whisperEnabled ?? (whisperSecretName != nil)
                if downloadMode == .aea && !whisperActive && symmetricKeyHex.isEmpty {
                    throw ConfigurationError.invalidSymmetricKey(
                        "symmetricKey is required for downloads.\(i) in AEA mode (no Whisper configured)"
                    )
                }

                let aeaConfig = try AEAConfiguration(
                    sourceURL: sourceURL,
                    outputPath: outputPath,
                    symmetricKeyHex: symmetricKeyHex,
                    chunkSizeMB: chunkSizeMB,
                    verbose: verbose,
                    force: force,
                    metadataBaseURL: metadataBaseURL,
                    gcsBaseURL: gcsBaseURL,
                    s3BaseURL: s3BaseURL,
                    s3TLSCertificatePath: s3TLSCertificatePath,
                    s3TLSKeyPath: s3TLSKeyPath,
                    s3TLSCACertificatePath: s3TLSCACertificatePath,
                    s3Region: s3Region,
                    downloadMode: downloadMode,
                    fileSystemThreadPoolSize: fileSystemThreadPoolSize,
                    writeParallelismMultiplier: writeParallelismMultiplier,
                    allocLimit: perDownloadAllocLimit,
                    whisperSecretName: whisperSecretName,
                    whisperNamespace: whisperNamespace,
                    whisperServerURL: whisperServerURL,
                    whisperTLSCertificatePath: whisperTLSCertificatePath,
                    whisperTLSKeyPath: whisperTLSKeyPath,
                    whisperTLSCACertificatePath: whisperTLSCACertificatePath,
                    whisperEnabled: whisperEnabled,
                    httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
                    httpReadTimeoutSeconds: httpReadTimeoutSeconds,
                    retryMaxAttempts: retryMaxAttempts,
                    retryBaseDelayMilliseconds: retryBaseDelayMilliseconds,
                    retryMaxDelaySeconds: retryMaxDelaySeconds,
                    retryJitterFactor: retryJitterFactor,
                    archiveIdSha256: archiveIdSha256,
                    urlOnlyIdentityCheck: urlOnlyIdentityCheck,
                    skipPaddingCheck: skipPaddingCheck
                )
                configurations.append(aeaConfig)
            }
            return configurations
        }

        // -- Legacy single-download fallback ----------------------------------
        func parseLegacySingleDownload() throws -> AEAConfiguration? {
            guard config.string(forKey: "sourceURL") != nil else { return nil }
            return try AEAConfiguration(config: config)
        }

        // -- Resolve downloads according to the mode --------------------------
        var configurations: [AEAConfiguration] = []
        switch downloaderMode {
        case .multi:
            configurations = try probeIndexedDownloads()
        case .single:
            if let single = try parseLegacySingleDownload() {
                configurations = [single]
            }
        case .inferred:
            configurations = try probeIndexedDownloads()
            if configurations.isEmpty, let single = try parseLegacySingleDownload() {
                configurations = [single]
            }
        }

        self.downloads = configurations
        self.downloaderMode = downloaderMode
        self.verbose = verbose
        self.tlsCertificateTimeoutSeconds = config.int(forKey: "tls.certificateTimeoutSeconds") ?? 30
        self.httpConnectTimeoutSeconds = httpConnectTimeoutSeconds
        self.httpReadTimeoutSeconds = httpReadTimeoutSeconds
        self.retryMaxAttempts = retryMaxAttempts
        self.retryBaseDelayMilliseconds = retryBaseDelayMilliseconds
        self.retryMaxDelaySeconds = retryMaxDelaySeconds
        self.retryJitterFactor = retryJitterFactor
    }
}

// MARK: - SigV4 credential resolution

extension MultiDownloadConfiguration {
    /// Builds a ``RetryConfiguration`` from this configuration's retry fields,
    /// matching what each individual download uses.
    private var retryConfiguration: RetryConfiguration {
        RetryConfiguration(
            maxAttempts: retryMaxAttempts,
            baseDelay: .milliseconds(retryBaseDelayMilliseconds),
            maxDelay: .seconds(retryMaxDelaySeconds),
            jitterFactor: retryJitterFactor
        )
    }

    /// Fetches HMAC credentials from Google Secret Manager and assigns them to
    /// every entry in ``downloads``.
    ///
    /// When `secretName` is `nil` or empty, this is a no-op. Otherwise, a
    /// single Secret Manager fetch is made and the resulting credentials are
    /// shared across all downloads, so the S3 source signs requests with
    /// SigV4 instead of using mTLS.
    ///
    /// - Parameters:
    ///   - secretName: The Google Secret Manager resource name (full
    ///     `projects/.../secrets/.../versions/...` form or short name) holding
    ///     the HMAC credentials, typically the value of the `GCP_SECRET_NAME`
    ///     environment variable.
    ///   - logger: Logger for diagnostic output during the fetch.
    public mutating func applySigV4Credentials(
        secretName: String?,
        logger: Logger,
        metadataBaseURL: String = "http://metadata.google.internal",
        secretManagerBaseURL: String = "https://secretmanager.googleapis.com"
    ) async throws {
        guard let secretName, !secretName.isEmpty else { return }
        let credentials = try await resolveSigV4Credentials(
            secretName: secretName,
            logger: logger,
            metadataBaseURL: metadataBaseURL,
            secretManagerBaseURL: secretManagerBaseURL,
            httpConnectTimeoutSeconds: httpConnectTimeoutSeconds,
            // Secret Manager round-trips can exceed the per-range read
            // timeout used by downloads; bump if necessary.
            httpReadTimeoutSeconds: max(httpReadTimeoutSeconds, 30),
            retryConfiguration: retryConfiguration
        )
        // Mutate via a stepped index rather than `for i in downloads.indices`:
        // `.indices` may retain a reference to the storage, which would force
        // a CoW copy on the first assignment and invalidate the rest of the
        // indices.
        var i = downloads.startIndex
        while i < downloads.endIndex {
            downloads[i].s3SigV4Credentials = credentials
            downloads.formIndex(after: &i)
        }
    }
}
