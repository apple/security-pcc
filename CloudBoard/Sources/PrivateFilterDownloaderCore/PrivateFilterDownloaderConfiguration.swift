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
import PrivateFilterCommon
@_weakLinked import SecureConfigDB

struct PrivateFilterDownloaderConfiguration: CustomStringConvertible {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: PrivateFilterDownloaderConfiguration.self)
    )

    static let defaultRangeChunkSize: Int64 = 67_108_864 // 64 MiB

    let enabled: Bool
    let maxConcurrentDownloads: Int
    /// Max fragments hashed concurrently. Bounds both download-phase SHA256
    /// verification and the startup cache reconcile re-hash. Reconcile is
    /// cold-read I/O-bound (queue depth 1 when serial), so concurrency raises
    /// the device's effective read bandwidth far above a single stream.
    let maxConcurrentVerifications: Int
    /// Max retry attempts per fragment download.
    let maxRetryAttempts: Int
    /// Maximum number of fragment download/verification failures tolerated within a
    /// single filter before its download is aborted. A filter needs every fragment,
    /// so any failure still leaves it incomplete (the missing fragments are retried
    /// on the next reconcile); this bounds how many stragglers to absorb before
    /// giving up early on a likely systemic problem. Counts only failures that
    /// survive `maxRetryAttempts` retries.
    let maxFragmentDownloadFailures: Int
    let urlSessionUsesClassicLoadingMode: Bool
    let remoteRootPath: URL

    /// Parent directory of `remoteRootPath` — the cache volume mount root the
    /// downloader must be able to write into to create the `complete/` tree. See
    /// `PrivateFilterServiceConfiguration.remoteRootParent(of:)` for the shared
    /// definition of the convention.
    var remoteRootParent: URL {
        PrivateFilterServiceConfiguration.remoteRootParent(of: self.remoteRootPath)
    }

    let urlPrefix: String?
    let recitationDataRoot: URL
    /// Whether to use HTTP Range headers for chunked fragment downloads.
    let rangeDownloadEnabled: Bool
    /// Chunk size in bytes for range downloads. Should be a power of two.
    let rangeChunkSize: Int64
    /// Maximum retry attempts per chunk before failing the fragment.
    let rangeChunkRetryAttempts: Int
    /// Whether to prune cached downloads that aren't configured for this node
    /// (and fragments outside this node's shard). Defaults to true.
    let enableCachePruning: Bool
    /// Escape hatch: when true, wipe ALL cached state under `remoteRootPath` at
    /// startup before doing anything else, forcing a full re-download. Defaults to
    /// false. Intended as a recovery lever if the cache is misbehaving; leaving it
    /// set defeats the cache (every boot wipes and re-downloads).
    let pruneAll: Bool

    /// Interval, in seconds, between checks while waiting for the download cache to
    /// become read/writable at startup. The cache volume is handed to `mobile` by
    /// PrivateFilterDownloaderHelper at boot; until that happens the downloader waits
    /// rather than failing to write. Defaults to 10s, floored at 1s.
    let cacheAccessRetryIntervalSeconds: Int

    /// Per-filter configuration, keyed by filterID.
    let filterConfigs: [FilterIDString: PerFilterConfig]

    init(
        enabled: Bool?,
        maxConcurrentDownloads: Int?,
        maxConcurrentVerifications: Int?,
        maxRetryAttempts: Int?,
        maxFragmentDownloadFailures: Int?,
        urlSessionUsesClassicLoadingMode: Bool?,
        remoteRootPath: URL,
        urlPrefix: String?,
        recitationDataRoot: URL,
        rangeDownloadEnabled: Bool?,
        rangeChunkSize: Int64?,
        rangeChunkRetryAttempts: Int?,
        enableCachePruning: Bool?,
        pruneAll: Bool?,
        cacheAccessRetryIntervalSeconds: Int?,
        filterConfigs: [FilterIDString: PerFilterConfig]
    ) {
        self.enabled = enabled ?? false
        self.maxConcurrentDownloads = Self.clamped(
            maxConcurrentDownloads, default: 4, minimum: 1, name: "maxConcurrentDownloads"
        )
        self.maxConcurrentVerifications = Self.clamped(
            maxConcurrentVerifications, default: 12, minimum: 1, name: "maxConcurrentVerifications"
        )
        self.maxRetryAttempts = maxRetryAttempts ?? 3
        self.maxFragmentDownloadFailures = Self.clamped(
            maxFragmentDownloadFailures, default: 5, minimum: 0, name: "maxFragmentDownloadFailures"
        )
        self.urlSessionUsesClassicLoadingMode = urlSessionUsesClassicLoadingMode ?? true
        self.remoteRootPath = remoteRootPath
        self.urlPrefix = urlPrefix
        self.recitationDataRoot = recitationDataRoot
        let chunkSize = rangeChunkSize ?? Self.defaultRangeChunkSize
        if chunkSize <= 0 {
            Self.logger.error("""
            rangeChunkSize \(chunkSize, privacy: .public) is invalid (must be > 0). \
            Disabling range downloads.
            """)
            self.rangeDownloadEnabled = false
            self.rangeChunkSize = Self.defaultRangeChunkSize
        } else {
            self.rangeDownloadEnabled = rangeDownloadEnabled ?? true
            if chunkSize & (chunkSize - 1) != 0 {
                Self.logger.warning("""
                rangeChunkSize \(chunkSize, privacy: .public) is not a power of two. \
                Using configured value regardless.
                """)
            }
            self.rangeChunkSize = chunkSize
        }
        self.rangeChunkRetryAttempts = rangeChunkRetryAttempts ?? 3
        self.enableCachePruning = enableCachePruning ?? true
        self.pruneAll = pruneAll ?? false
        self.cacheAccessRetryIntervalSeconds = Self.clamped(
            cacheAccessRetryIntervalSeconds, default: 10, minimum: 1, name: "cacheAccessRetryIntervalSeconds"
        )
        self.filterConfigs = filterConfigs
    }

    /// Resolves an optional integer config value to its default when unset, then floors
    /// it at `minimum`, falling back to `default` (with a warning) if the configured
    /// value is below the floor. A non-positive concurrency limit would silently
    /// disable bounded concurrency — the exact slowdown this guards against — so an
    /// out-of-range value is treated as misconfiguration rather than honored.
    private static func clamped(_ value: Int?, default defaultValue: Int, minimum: Int, name: String) -> Int {
        let resolved = value ?? defaultValue
        guard resolved >= minimum else {
            Self.logger.warning("""
            \(name, privacy: .public) \(resolved, privacy: .public) is invalid (must be >= \(
                minimum,
                privacy: .public
            )). \
            Using default \(defaultValue, privacy: .public).
            """)
            return defaultValue
        }
        return resolved
    }

    var description: String {
        "PrivateFilterDownloaderConfiguration(" +
            "enabled: \(self.enabled), " +
            "maxConcurrentDownloads: \(self.maxConcurrentDownloads), " +
            "maxConcurrentVerifications: \(self.maxConcurrentVerifications), " +
            "maxRetryAttempts: \(self.maxRetryAttempts), " +
            "maxFragmentDownloadFailures: \(self.maxFragmentDownloadFailures), " +
            "urlSessionUsesClassicLoadingMode: \(self.urlSessionUsesClassicLoadingMode), " +
            "remoteRootPath: \(self.remoteRootPath), " +
            "urlPrefix: \(self.urlPrefix ?? "nil"), " +
            "recitationDataRoot: \(self.recitationDataRoot), " +
            "rangeDownloadEnabled: \(self.rangeDownloadEnabled), " +
            "rangeChunkSize: \(self.rangeChunkSize), " +
            "rangeChunkRetryAttempts: \(self.rangeChunkRetryAttempts), " +
            "enableCachePruning: \(self.enableCachePruning), " +
            "pruneAll: \(self.pruneAll), " +
            "cacheAccessRetryIntervalSeconds: \(self.cacheAccessRetryIntervalSeconds), " +
            "filterConfigs: \(self.filterConfigs))"
    }
}

extension PrivateFilterDownloaderConfiguration {
    static func fromSecureConfig() throws -> PrivateFilterDownloaderConfiguration {
        guard #_hasSymbol(SecureConfigParameters.self) else {
            throw PrivateFilterSecureConfigError.secureConfigDBNotAvailable
        }
        let parameters = try SecureConfigParameters.loadContents()
        let sharedConfig = try PrivateFilterServiceConfiguration.fromSecureConfig(parameters: parameters)

        let keyPrefix = "com.apple.privatefilter.downloader"
        let enabled: Bool? = try getUnvalidatedParameter(
            key: "\(keyPrefix).enabled",
            from: parameters
        )
        let maxConcurrentDownloads: Int? = try getUnvalidatedParameter(
            key: "\(keyPrefix).maxConcurrentDownloads",
            from: parameters
        )
        let maxConcurrentVerifications: Int? = try getUnvalidatedParameter(
            key: "\(keyPrefix).maxConcurrentVerifications",
            from: parameters
        )
        let maxRetryAttempts: Int? = try getUnvalidatedParameter(
            key: "\(keyPrefix).maxRetryAttempts",
            from: parameters
        )
        let maxFragmentDownloadFailures: Int? = try getUnvalidatedParameter(
            key: "\(keyPrefix).maxFragmentDownloadFailures",
            from: parameters
        )
        let urlSessionUsesClassicLoadingMode: Bool? = try getUnvalidatedParameter(
            key: "\(keyPrefix).urlSessionUsesClassicLoadingMode",
            from: parameters
        )
        let urlPrefix: String? = try getUnvalidatedParameter(
            key: "\(keyPrefix).urlPrefix",
            from: parameters
        )
        let rangeDownloadEnabled: Bool? = try getUnvalidatedParameter(
            key: "\(keyPrefix).rangeDownloadEnabled",
            from: parameters
        )
        let rangeChunkSize: Int64? = try getUnvalidatedParameter(
            key: "\(keyPrefix).rangeChunkSize",
            from: parameters
        )
        let rangeChunkRetryAttempts: Int? = try getUnvalidatedParameter(
            key: "\(keyPrefix).rangeChunkRetryAttempts",
            from: parameters
        )
        let enableCachePruning: Bool? = try getUnvalidatedParameter(
            key: "\(keyPrefix).enableCachePruning",
            from: parameters
        )
        let pruneAll: Bool? = try getUnvalidatedParameter(
            key: "\(keyPrefix).pruneAll",
            from: parameters
        )
        let cacheAccessRetryIntervalSeconds: Int? = try getUnvalidatedParameter(
            key: "\(keyPrefix).cacheAccessRetryIntervalSeconds",
            from: parameters
        )

        return .init(
            enabled: enabled,
            maxConcurrentDownloads: maxConcurrentDownloads,
            maxConcurrentVerifications: maxConcurrentVerifications,
            maxRetryAttempts: maxRetryAttempts,
            maxFragmentDownloadFailures: maxFragmentDownloadFailures,
            urlSessionUsesClassicLoadingMode: urlSessionUsesClassicLoadingMode,
            remoteRootPath: sharedConfig.remoteRootPath,
            urlPrefix: urlPrefix,
            recitationDataRoot: sharedConfig.recitationDataRoot,
            rangeDownloadEnabled: rangeDownloadEnabled,
            rangeChunkSize: rangeChunkSize,
            rangeChunkRetryAttempts: rangeChunkRetryAttempts,
            enableCachePruning: enableCachePruning,
            pruneAll: pruneAll,
            cacheAccessRetryIntervalSeconds: cacheAccessRetryIntervalSeconds,
            filterConfigs: sharedConfig.filterConfigs
        )
    }
}

extension PrivateFilterDownloaderConfiguration {
    var urlSessionConfig: URLSessionConfiguration {
        let urlSessionConfig = URLSessionConfiguration.ephemeral
        urlSessionConfig.timeoutIntervalForRequest = 60
        urlSessionConfig.timeoutIntervalForResource = 60 * 60

        urlSessionConfig.httpMaximumConnectionsPerHost = self.maxConcurrentDownloads
        urlSessionConfig.usesClassicLoadingMode = self.urlSessionUsesClassicLoadingMode

        // disabled to prevent sandbox violations
        urlSessionConfig.httpCookieStorage = nil
        urlSessionConfig.httpShouldSetCookies = false
        urlSessionConfig.urlCredentialStorage = nil
        urlSessionConfig.urlCache = nil
        urlSessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        return urlSessionConfig
    }
}
