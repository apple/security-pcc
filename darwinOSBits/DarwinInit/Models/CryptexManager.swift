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

//
//  CryptexManager.swift
//  darwinOSBits
//
//

import CryptoKit
import CryptexKit
import DarwinInitConfig
import Foundation
import System

/// Orchestrates the cryptex lifecycle: download, extract, personalize, and install.
///
/// This class coordinates between specialized components:
/// - CryptexDownloader for fetching cryptexes
/// - CryptexCacheIntegration for cache management
/// - Pipeline stages (Extracted/Personalized cryptexes) for state management
class CryptexManager {

    // MARK: - Properties
    private let downloadConfig: DownloadConfiguration
    private let downloadAuth: DownloadAuthentication
    private let appleConnect: Bool
    private let diavloServerURL: String?

    private let downloader: CryptexDownloader
    private let cacheIntegration: CryptexCacheIntegration

    // MARK: - Initialization

    init(
        downloadConfig: DownloadConfiguration,
        downloadAuth: DownloadAuthentication,
        appleConnect: Bool?,
        diavloServerURL: URL?
    ) {
        self.downloadConfig = downloadConfig
        self.downloadAuth = downloadAuth
        self.appleConnect = appleConnect ?? false
        self.diavloServerURL = diavloServerURL?.absoluteString

        self.downloader = CryptexDownloader(
            downloadConfig: downloadConfig,
            downloadAuth: downloadAuth)

        self.cacheIntegration = CryptexCacheIntegration(
            downloadConfig: downloadConfig,
            downloadAuth: downloadAuth,
            appleConnect: self.appleConnect,
            diavloServerURL: self.diavloServerURL)
    }

    // MARK: - High-level Operations

    /// Gets a personalized cryptex, optionally using the cache.
    ///
    /// This is the main entry point for cryptex operations. It attempts to use the cache
    /// if provided, falling back to network download if cache access fails.
    ///
    /// - Parameters:
    ///   - cryptex: The cryptex configuration
    ///   - cache: Optional cache instance for performance
    /// - Returns: A PersonalizedCryptex ready for installation
    /// - Throws: CryptexApplyError if acquisition fails
    func get(cryptex: CryptexConfig, using cache: CryptexCache? = nil) async throws -> PersonalizedCryptex {
        if let cache {
            do {
                return try await cacheIntegration.fetchFromCache(cryptex: cryptex, cache: cache)
            } catch {
                logger.info("[\(cryptex.identifier)] Cache fetch failed, falling back to network download. Fetch failed with error: (\(error.localizedDescription))")
            }
        }

        return try await fetchFromNetwork(cryptex: cryptex)
    }

    /// Prefetches a cryptex into the cache without personalizing or installing it.
    ///
    /// This method is useful for preparing the cache ahead of time. It downloads and stores
    /// the cryptex in the cache, making future `get()` calls faster.
    ///
    /// - Parameters:
    ///   - cryptex: The cryptex configuration
    ///   - cache: The cache instance to prefetch into
    /// - Throws: Error if prefetch fails
    func prefetch(cryptex: CryptexConfig, into cache: CryptexCache) async throws {
        let accessParams = try await cacheIntegration.buildCacheAccessParameter(cryptex: cryptex)

        try await cache.access(
            entryBackedByResourceAt: cryptex.config.url,
            authentication: downloadAuth,
            downloadConfiguration: downloadConfig,
            delegateParameter: accessParams)
    }

    // MARK: - Pipeline Operations

    /// Downloads, extracts, and personalizes a cryptex from the network.
    ///
    /// This is the non-cached path through the pipeline.
    ///
    /// - Parameter cryptex: The cryptex configuration
    /// - Returns: A PersonalizedCryptex ready for installation
    /// - Throws: CryptexApplyError if any stage fails
    private func fetchFromNetwork(cryptex: CryptexConfig) async throws -> PersonalizedCryptex {
        let downloaded = try await downloader.download(cryptex: cryptex)
        let extracted = try await downloaded.extract()
        return try await extracted.personalize(
            diavloServerURL: diavloServerURL,
            appleConnect: appleConnect
        )
    }

    // MARK: - Static Utilities

    /// Sets up a temporary extraction path for a cryptex.
    ///
    /// - Returns: A unique temporary directory path
    /// - Throws: Error if directory creation fails
    static func setUpExtractedPath() throws -> FilePath {
        let extractedPath = FilePath("/private/var/tmp/darwin-init/cryptex/").appending(UUID().uuidString)
        try? extractedPath.remove()
        do {
            try extractedPath.createDirectory(intermediateDirectories: true)
        } catch {
            logger.error("Unable to create temp directory for cryptex extraction: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return extractedPath
    }
}

// MARK: - CryptexManager+Config

extension CryptexManager {

    convenience init(from config: Config.Cryptex, auth: Config.Authentication?, diavlo: URL?) {
        var downloadRetries: UInt?
        var networkServiceType: DownloadConfiguration.NetworkServiceType?
        var alternateCDNHost: String?
        var maxActiveTasks: Int?
        var chunkSize: UInt64?

        if let network = config.network {
            downloadRetries = network.retryCount

            if let serviceType = network.networkServiceType {
                networkServiceType = switch serviceType {
                case .background: DownloadConfiguration.NetworkServiceType.background
                case .default: DownloadConfiguration.NetworkServiceType.default
                }
            }

            alternateCDNHost = network.alternateCdnHost

            if let maxTasks = network.downloadTasks {
                maxActiveTasks = Int(maxTasks)
            }

            if let chunk = network.chunkSize {
                chunkSize = UInt64(chunk)
            }
        }

        let dlConfig = DownloadConfiguration(
            downloadRetries: downloadRetries ?? kDefaultCryptexDownloadRetries,
            networkServiceType: networkServiceType ?? .default,
            alternateCDNHost: alternateCDNHost,
            maxActiveTasks: maxActiveTasks ?? kDefaultCryptexMaxActiveTasks,
            chunkSize: chunkSize
        )

        let dlAuth = if let auth {
            auth.downloadAuthentication
        } else {
            DownloadAuthentication.none
        }

        self.init(
            downloadConfig: dlConfig,
            downloadAuth: dlAuth,
            appleConnect: auth?.appleConnect,
            diavloServerURL: diavlo
        )
    }
}
