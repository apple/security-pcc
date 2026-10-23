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
//  CryptexCacheIntegration.swift
//  darwinOSBits
//
//

import Foundation
import System
import CryptexKit
internal import DarwinInitBridging

/// Handles integration with the cryptex cache system, including ticket validation and cached personalization.
class CryptexCacheIntegration {
    private let downloadConfig: DownloadConfiguration
    private let downloadAuth: DownloadAuthentication
    private let appleConnect: Bool
    private let diavloServerURL: String?

    init(
        downloadConfig: DownloadConfiguration,
        downloadAuth: DownloadAuthentication,
        appleConnect: Bool,
        diavloServerURL: String?
    ) {
        self.downloadConfig = downloadConfig
        self.downloadAuth = downloadAuth
        self.appleConnect = appleConnect
        self.diavloServerURL = diavloServerURL
    }

    /// Validates a ticket file using Image4 cryptographic verification.
    ///
    /// - Parameters:
    ///   - ticketPath: Path to the ticket file
    ///   - ginfPath: Path to the GINF file
    /// - Returns: true if validation succeeds, false otherwise
    /// - Throws: Errno.invalidArgument if paths are invalid
    internal func isValidTicket(_ ticketPath: String, _ ginfPath: String) throws -> Bool {
        guard let ticketURL = URL(string: ticketPath),
              let ginfURL = URL(string: ginfPath) else {
            throw Errno.invalidArgument
        }

        let ginf = try FileHandle(forReadingFrom: ginfURL).availableData
        let manifest = try FileHandle(forReadingFrom: ticketURL).availableData
        var image4Validation: Bool = false
        logger.info("Trying to validate \(ticketPath) and \(ginfPath).")

        ginf.withUnsafeBytes { (_ginf: UnsafeRawBufferPointer) in
            manifest.withUnsafeBytes { (_manifest: UnsafeRawBufferPointer) in
                image4Validation = shim_validateImage4Ticket(
                    _manifest.assumingMemoryBound(to: UInt8.self).baseAddress!,
                    manifest.count,
                    _ginf.assumingMemoryBound(to: UInt8.self).baseAddress!,
                    ginf.count)
            }
        }
        return image4Validation
    }

    /// Builds cache access parameters for a cryptex.
    ///
    /// - Parameter cryptex: The cryptex configuration
    /// - Returns: Cache delegate access parameters
    /// - Throws: Error if parameter building fails
    internal func buildCacheAccessParameter(cryptex: CryptexConfig) async throws -> CryptexCacheDelegate.AccessParameter {
        let aeaDecryptionParameters = try await cryptex.resolveAEADecryptionParameters(
            downloadConfig: downloadConfig,
            downloadAuth: downloadAuth)

        let digest = try cryptex.sha256Bytes

        return CryptexCacheDelegate.AccessParameter(
            digest: digest,
            alternateKnoxCDNHost: downloadConfig.alternateCDNHost,
            aeaDecryptionParameters: aeaDecryptionParameters,
            maxActiveNetworkTasks: downloadConfig.maxActiveTasks,
            chunkSize: downloadConfig.chunkSize)
    }

    // MARK: - Private Helpers

    /// Attempts to use a cached ticket to create a PersonalizedCryptex without personalization.
    ///
    /// - Parameters:
    ///   - entry: The cache entry
    ///   - config: The cryptex configuration
    ///   - cryptexPath: Path to the extracted cryptex
    /// - Returns: A PersonalizedCryptex if the cached ticket is valid, nil otherwise
    /// - Throws: CryptexError or other errors if loading fails
    private func tryToUseCachedTicket(
        entry: CryptexCacheDelegate.Entry,
        config: CryptexConfig,
        cryptexPath: FilePath
    ) async throws -> PersonalizedCryptex? {
        let (ticket, ginfpath) = try entry.fetchTicketandGinfPath()

        guard try ticket.fileExists(), try ginfpath.fileExists() else {
            logger.info("Cached ticket and ginf don't exist for \(config.identifier)")
            return nil
        }

        guard try isValidTicket(ticket.string, ginfpath.string) else {
            logger.warning("Failed to validate ticket for \(config.identifier), need to repersonalize.")
            entry.deleteTicketAndginf()
            return nil
        }

        logger.info("Successfully validated ticket for \(config.identifier)")

        let bundle = try CryptexBundle(path: cryptexPath)
        let device = CryptexLocalDevice()
        let identity = try await device.readIdentity()

        guard let cryptexObject = try await bundle.getCryptex(matching: identity, variant: config.config.variant) else {
            throw CryptexError.cryptexNotFound
        }

        try await cryptexObject.attachPersonalizedManifest(path: ticket)

        let server = config.personalizationServer(diavloServerURL: diavloServerURL)
        return PersonalizedCryptex(
            config: config,
            cryptexObject: cryptexObject,
            device: device,
            personalizationServer: server)
    }

    /// Personalizes a cryptex and caches the resulting ticket and GINF.
    ///
    /// - Parameters:
    ///   - entry: The cache entry
    ///   - config: The cryptex configuration
    ///   - cryptexPath: Path to the extracted cryptex
    ///   - ticketPath: Path where the ticket should be written
    ///   - ginfPath: Path where the GINF should be written
    /// - Returns: A PersonalizedCryptex ready for installation
    /// - Throws: CryptexApplyError if personalization fails
    private func personalizeAndCache(
        entry: CryptexCacheDelegate.Entry,
        config: CryptexConfig,
        cryptexPath: FilePath,
        ticketPath: FilePath,
        ginfPath: FilePath
    ) async throws -> PersonalizedCryptex {
        let extractedCryptex = ExtractedCryptex(config: config, path: cryptexPath, ticketPath: ticketPath)

        let personalizedCryptex = try await extractedCryptex.personalize(
            diavloServerURL: diavloServerURL,
            appleConnect: appleConnect,
            ginfPath: ginfPath)

        logger.info("Just finished personalizing \(config.identifier)")

        do {
            try entry.ingestTicketandGINF(ticket: ticketPath, ginfPath: ginfPath)
        } catch {
            logger.info("Failed to ingest ticket & ginf for \(config.identifier)")
        }

        return personalizedCryptex
    }

    /// Gets a personalized cryptex from a cache entry, using cached ticket or fresh personalization.
    ///
    /// This method handles the smart fallback workflow:
    /// 1. Extract the cryptex from cache entry
    /// 2. Try to use cached ticket if available and valid
    /// 3. If no valid cached ticket, personalize fresh and cache the result
    ///
    /// - Parameters:
    ///   - entry: The cache entry containing the cryptex
    ///   - config: The cryptex configuration
    /// - Returns: A PersonalizedCryptex ready for installation
    /// - Throws: CryptexApplyError if extraction or personalization fails
    internal func getPersonalizedCryptex(
        entry: CryptexCacheDelegate.Entry,
        config: CryptexConfig
    ) async throws -> PersonalizedCryptex {
        let cryptexPath: FilePath
        do {
            cryptexPath = try entry.extract()
        } catch {
            logger.error("[\(config.identifier)] Failed to extract cryptex: \(error)")
            throw CryptexApplyError(kind: .extractionFailed(identifier: config.identifier), underlyingError: error)
        }

        do {
            if let cached = try await tryToUseCachedTicket(entry: entry, config: config, cryptexPath: cryptexPath) {
                return cached
            }
        } catch let error as CryptexError {
            logger.error("[\(config.identifier)] Failed to load cryptex from cache: \(String(describing: error))")
            throw CryptexApplyError(kind: .cacheAccessFailed(identifier: config.identifier), underlyingError: error)
        } catch {
            logger.error("[\(config.identifier)] Failed to load cryptex from cache with unexpected error: \(error.localizedDescription)")
            throw CryptexApplyError(kind: .cacheAccessFailed(identifier: config.identifier), underlyingError: error)
        }

        let (ticket, ginfpath) = try entry.fetchTicketandGinfPath()

        do {
            return try await personalizeAndCache(
                entry: entry,
                config: config,
                cryptexPath: cryptexPath,
                ticketPath: ticket,
                ginfPath: ginfpath)
        } catch let error as CryptexApplyError {
            throw error
        } catch {
            logger.error("Failed to personalize cryptex \(config.identifier) with unexpected error: \(error.localizedDescription)")
            throw CryptexApplyError(kind: .personalizationFailed(identifier: config.identifier), underlyingError: error)
        }
    }

    /// Attempts to fetch a cryptex from the cache.
    ///
    /// - Parameters:
    ///   - cryptex: The cryptex configuration
    ///   - cache: The cache instance to use
    /// - Returns: A PersonalizedCryptex ready for installation
    /// - Throws: CryptexApplyError if cache access fails
    func fetchFromCache(
        cryptex: CryptexConfig,
        cache: CryptexCache
    ) async throws -> PersonalizedCryptex {
        let delegateAccessParameter: CryptexCacheDelegate.AccessParameter
        do {
            delegateAccessParameter = try await buildCacheAccessParameter(cryptex: cryptex)
        } catch {
            logger.error("[\(cryptex.identifier)] Failed to build cache access parameters: \(error)")
            throw CryptexApplyError(kind: .cacheAccessFailed(identifier: cryptex.identifier), underlyingError: error)
        }

        let entry: CryptexCacheDelegate.Entry
        do {
            entry = try await cache.access(
                entryBackedByResourceAt: cryptex.config.url,
                authentication: downloadAuth,
                downloadConfiguration: downloadConfig,
                delegateParameter: delegateAccessParameter)
        } catch {
            logger.error("[\(cryptex.identifier)] Failed to handle cache access: \(error)")
            throw CryptexApplyError(kind: .cacheAccessFailed(identifier: cryptex.identifier), underlyingError: error)
        }

        do {
            return try await getPersonalizedCryptex(entry: entry, config: cryptex)
        } catch let error as CryptexApplyError {
            throw error
        } catch {
            logger.error("[\(cryptex.identifier)] Failed to fetch from Entry")
            throw CryptexApplyError(kind: .cacheAccessFailed(identifier: cryptex.identifier), underlyingError: error)
        }
    }
}
