// Copyright © 2025 Apple Inc. All Rights Reserved.

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
import Foundation
import System
internal import DarwinInitBridging

class CryptexManager {

    typealias AeaDecryptionParams = Config.Cryptex.Cryptex.AeaDecryptionParams
    
    struct CryptexConfig {
        let url: URL
        let identifier: String

        var variant: String?
        var jetsamPropertiesVariant: String?

        var cacheable: Bool?
        var size: UInt?
        var sha256: DInitSHA256Digest?
        var readWrite: Bool?

        var aeaDecryptionParams: AeaDecryptionParams?
        var signingEnvironment: DInitAuthorizationService?
        var signingEnvironmentURL: String?

        var sha256Bytes: [UInt8]? {
            get throws {
                guard let sha256 else { return nil }
                guard let parsed = sha256.string.hexadecimalASCIIBytes else {
                    logger.error("[\(self.identifier)] Failed to parse SHA256 digest: \(sha256.description)")
                    throw Errno.invalidArgument
                }

                return parsed
            }
        }

        var isCacheable: Bool {
            // explicit opt out
            guard cacheable != false else { return false }

            // If it is a knox URL we can cache
            if url.scheme == kKnoxURLScheme { return true }

            // If we have a sha256, we can cache
            if sha256 != nil { return true }

            // If we have decryption parameters, we can cache
            if aeaDecryptionParams != nil { return true }

            return false
        }
    }

    // MARK: - Properties
    let downloadConfig: DownloadConfiguration
    let downloadAuth: DownloadAuthentication
    let appleConnect: Bool
    let diavloServerURL: String?

    // MARK: - Resolvers
    func resolveAEADecryptionParameters(for cryptex: CryptexConfig) async throws ->  AEADecryptionParameters? {
        if cryptex.aeaDecryptionParams != nil && cryptex.url.scheme == kKnoxURLScheme {
            logger.warning("Pre-determined decryption components already provided for a knox:// url. Will use pre-determined components rather than fetching from Knox.")
        }

        if let params = cryptex.aeaDecryptionParams {
            logger.info("Pre-determined decryption components provided")
            guard let key = params.getDecryptionKey() else {
                return nil
            }
            guard let archiveIdentifierData = params.getArchiveID() else {
                return nil
            }
            return AEADecryptionParameters(
                archiveID: archiveIdentifierData,
                decryptionKey: key)
        }

        if cryptex.url.scheme == kKnoxURLScheme {
            logger.log("Attempting to fetch decryption key for cryptex from Knox.")

            return await KnoxClientWrapper.downloadAEADecryptionParameters(for: cryptex.url,
                                                                           configuration: downloadConfig,
                                                                           authentication: downloadAuth,
                                                                           alternateCDNHost: downloadConfig.alternateCDNHost)
        } else {
            return nil
        }
    }

    func resolveCryptexCacheAccessParameter(cryptex: CryptexConfig) async throws -> CryptexCacheDelegate.AccessParameter {
        let aeaDecryptionParameters: AEADecryptionParameters?

        do {
            aeaDecryptionParameters = try await self.resolveAEADecryptionParameters(for: cryptex)
        } catch {
            logger.error("[\(cryptex.url)] Failed to resolve AEA decryption parameters: \(error)")
            throw error
        }

        let digest: [UInt8]?

        if let sha256 = cryptex.sha256 {
            guard let parsed = sha256.string.hexadecimalASCIIBytes else {
                logger.error("[\(cryptex.url)] Failed to parse SHA256 digest: \(sha256.description)")
                throw Errno.invalidArgument
            }

            digest = parsed
        } else {
            digest = nil
        }

        let delegateAccessParameter = CryptexCacheDelegate.AccessParameter(
            digest: digest,
            alternateKnoxCDNHost: self.downloadConfig.alternateCDNHost,
            aeaDecryptionParameters: aeaDecryptionParameters,
            maxActiveNetworkTasks: self.downloadConfig.maxActiveTasks,
            chunkSize: self.downloadConfig.chunkSize)

        return delegateAccessParameter
    }


    init(downloadConfig: DownloadConfiguration,
         downloadAuth: DownloadAuthentication,
         appleConnect: Bool?,
         diavloServerURL: URL?
    ) {
        self.downloadConfig = downloadConfig
        self.downloadAuth = downloadAuth
        self.appleConnect = appleConnect ?? false
        self.diavloServerURL = diavloServerURL?.absoluteString
    }

	internal func isValidTicket(_ ticketPath: String, _ ginfPath: String) throws -> Bool {
		let ginf = try! FileHandle(forReadingFrom: URL(string: ginfPath)!).availableData
		let manifest = try! FileHandle(forReadingFrom: URL(string: ticketPath)!).availableData
		var image4Validation: Bool = false
		logger.info("Trying to validate \(ticketPath) and \(ginfPath).")

		ginf.withUnsafeBytes { (_ginf: UnsafeRawBufferPointer) in
			manifest.withUnsafeBytes { (_manifest: UnsafeRawBufferPointer) in
				image4Validation = shim_validateImage4Ticket(_manifest.assumingMemoryBound(to: UInt8.self).baseAddress!, manifest.count, _ginf.assumingMemoryBound(to: UInt8.self).baseAddress!, ginf.count)
			}
		}
		return image4Validation
	}


	internal func fetchAndPersonalizeFrom(entry: CryptexCacheDelegate.Entry, config: CryptexConfig) throws -> PersonalizedCryptex? {
		let cryptexPath: FilePath
		do {
			cryptexPath = try entry.extract()
		} catch {
			logger.error("[\(config.identifier)] Failed to extract cryptex: \(error)")
			return nil
		}
        
        let serverURL = self.serverPersonalizationURL(cryptex: config)

		let (ticket, ginfpath) = try entry.fetchTicketandGinfPath()

		if try ticket.fileExists(), try ginfpath.fileExists() {
			if(try isValidTicket(ticket.string, ginfpath.string)) {
				logger.info("Successfully validated ticket")
				return PersonalizedCryptex(config: config, path: cryptexPath, ticketPath: ticket, serverURL: serverURL)
			} else {
				logger.warning("Failed to validate ticket, need to repersonalize.")
				entry.deleteTicketAndginf()
			}
		} else {
			logger.info("ticket path \(ticket) and ginf path \(ginfpath) don't exist")
		}

		let cryptex = ExtractedCryptex.init(config: config, path: cryptexPath, ticketPath: ticket)
        
        guard let personalizedCryptex = cryptex.personalize(serverURL: serverURL, appleConnect: appleConnect, ginfPath: ginfpath) else {
			logger.error("Failed to personalize cryptex \(config.identifier)")
			return nil
		}

		logger.info("Just finished personalizing \(config.identifier)")
		do {
			try entry.ingestTicketandGINF(ticket: ticket, ginfPath: ginfpath)
		} catch {
			logger.info("Failed to ingest ticket & ginf for \(config.identifier)")
		}
		return personalizedCryptex
	}

    /// Download + Extract, optionally using the cache
    func get(cryptex: CryptexConfig, using cache: CryptexCache? = nil) async -> PersonalizedCryptex? {
        if let cache {
            if let cachedResult = await fetchFromCache(cryptex: cryptex, cache: cache) {
                return cachedResult
            }
            logger.info("[\(cryptex.identifier)] Cache fetch failed, falling back to network download")
        }

        return await fetchFromNetwork(cryptex: cryptex)
    }

    /// Attempt to get cryptex from cache, returning nil if any step fails
    private func fetchFromCache(cryptex: CryptexConfig, cache: CryptexCache) async -> PersonalizedCryptex? {
        let resolvedDecryptionParams: AEADecryptionParameters?
        do {
            resolvedDecryptionParams = try await self.resolveAEADecryptionParameters(for: cryptex)
        } catch {
            logger.error("[\(cryptex.identifier)] Failed to resolve AEA decryption parameters: \(error)")
            return nil
        }

        let digest: [UInt8]?
        do {
            digest = try cryptex.sha256Bytes
        } catch {
            return nil
        }

        let delegateAccessParameter = CryptexCacheDelegate.AccessParameter(
            digest: digest,
            alternateKnoxCDNHost: downloadConfig.alternateCDNHost,
            aeaDecryptionParameters: resolvedDecryptionParams,
            maxActiveNetworkTasks: downloadConfig.maxActiveTasks,
            chunkSize: downloadConfig.chunkSize)

        let entry: CryptexCacheDelegate.Entry
        do {
            entry = try await cache.access(entryBackedByResourceAt: cryptex.url,
                                           authentication: downloadAuth,
                                           downloadConfiguration: downloadConfig,
                                           delegateParameter: delegateAccessParameter)
        } catch {
            logger.error("[\(cryptex.identifier)] Failed to handle cache access: \(error)")
            return nil
        }

        do {
            return try fetchAndPersonalizeFrom(entry: entry, config: cryptex)
        } catch {
            logger.error("[\(cryptex.identifier)] Failed to fetch from Entry")
            return nil
        }
    }
    
    func serverPersonalizationURL(cryptex: CryptexConfig) -> String? {
        if let url = cryptex.signingEnvironmentURL {
            return url
        } else if cryptex.signingEnvironment == .diavlo {
            return self.diavloServerURL
        } else {
            return nil
        }
    }
    
    /// Download from network and extract
    private func fetchFromNetwork(cryptex: CryptexConfig) async -> PersonalizedCryptex? {
        guard let downloaded = await self.download(cryptex: cryptex) else {
            return nil
        }
        
        return await self.extract(cryptex: downloaded)?.personalize(serverURL: self.serverPersonalizationURL(cryptex: cryptex),
                                                                    appleConnect: appleConnect)
    }

    struct DownloadedCryptex {
        let config: CryptexConfig
        let path: FilePath
    }

    func download(cryptex: CryptexConfig, to dest: FilePath? = nil) async -> DownloadedCryptex? {
        logger.info("Downloading cryptex \(cryptex.identifier)...")

        let downloaded: FilePath

        if cryptex.url.scheme == kKnoxURLScheme {
            // Download the raw, encrypted cryptex from Knox
            guard let encrypted = await KnoxClientWrapper.downloadRaw(from: cryptex.url,
                                                                      to: dest,
                                                                      configuration: downloadConfig,
                                                                      authentication: downloadAuth,
                                                                      alternateCDNHost: downloadConfig.alternateCDNHost) else {
                return nil
            }

            downloaded = encrypted
        } else {
            let retries = Int(truncatingIfNeeded: downloadConfig.downloadRetries)
            guard let compressed = await Network.downloadItem(at: cryptex.url,
                                                              to: dest,
                                                              attempts: retries,
                                                              background: downloadConfig.backgroundTrafficClass,
                                                              maxActiveTasks: downloadConfig.maxActiveTasks) else {
                return nil
            }

            if let size = cryptex.size {
                do {
                    try compressed.sizeEquals(expectedSize: Int(size))
                } catch {
                    logger.error("Downloaded cryptex failed size validation: \(error.localizedDescription)")
                    return nil
                }
            }

            if let sha256 = cryptex.sha256 {
                do {
                    try compressed.sha256Equals(expectedSHA256: sha256)
                } catch {
                    logger.error("Downloaded cryptex failed sha256 validation: \(error.localizedDescription)")
                    return nil
                }
            }

            downloaded = compressed
        }

        return DownloadedCryptex(config: cryptex, path: downloaded)
    }

    func extract(cryptex: DownloadedCryptex) async -> ExtractedCryptex? {
        let aeaDecryptionParameters: AEADecryptionParameters?
        do {
            aeaDecryptionParameters = try await self.resolveAEADecryptionParameters(for: cryptex.config)
        } catch {
            logger.error("Failed to resolve AEA asset decryption components. Unable to extract cryptex.")
            return nil
        }

        guard let extracted = try? CryptexManager.extractCryptex(
            at: cryptex.path,
            using: aeaDecryptionParameters) else {
            return nil
        }

        return ExtractedCryptex(config: cryptex.config, path: extracted)
    }

    struct ExtractedCryptex {
        let config: CryptexConfig
        let path: FilePath
		let ticketPath: FilePath?

		init(config: CryptexConfig, path: FilePath, ticketPath: FilePath? = nil) {
			self.config = config
			self.path = path
			self.ticketPath = ticketPath
		}

        func personalize(serverURL: String?, appleConnect: Bool, ginfPath: FilePath? = nil) -> PersonalizedCryptex? {
            guard let personalized = LibCryptex.personalizeCryptex(
                at: path,
				ticketPath: self.ticketPath,
                withVariant: config.variant,
                usingAuthorizationService: config.signingEnvironment,
                locatedAt: serverURL,
				usingAppleConnect: appleConnect,
				ginfPath: ginfPath?.string) else {
                return nil
            }

            return PersonalizedCryptex(config: config, path: path, ticketPath: personalized, serverURL: serverURL)
        }
    }

    struct PersonalizedCryptex {
        let config: CryptexConfig
        let path: FilePath
		let ticketPath: FilePath
        let serverURL: String?

        func install(limitLoadToREM: Bool) -> Bool {
            return LibCryptex.installCryptex(
				at: path,
				ticketAt: ticketPath,
                withVariant: config.variant,
                usingAuthorizationService: config.signingEnvironment,
                locatedAt: serverURL,
                limitLoadToREM: limitLoadToREM, readWrite: config.readWrite, jetsamPropertiesVariant: config.jetsamPropertiesVariant)
        }
    }

    static func setUpExtractedPath() throws -> FilePath {
        let extractedPath = FilePath("/var/tmp/darwin-init/cryptex/").appending(UUID().uuidString)
        try? extractedPath.remove()
        do {
            try extractedPath.createDirectory(intermediateDirectories: true)
        } catch {
            logger.error("Unable to create temp directory for cryptex extraction: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return extractedPath
    }

    static func extractCryptex(at archivePath: FilePath, using aeaDecryptionParameters: AEADecryptionParameters?) throws -> FilePath? {
        guard let extractedPath = try? setUpExtractedPath() else {
            return nil
        }

        try archivePath.extract(to: extractedPath, using: aeaDecryptionParameters)

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

        self.init(downloadConfig: dlConfig,
                  downloadAuth: dlAuth,
                  appleConnect: auth?.appleConnect,
                  diavloServerURL: diavlo
        )
    }
}

extension CryptexManager.CryptexConfig {

    init(from config: Config.Cryptex.Cryptex, identifier: String) {
        self.identifier = identifier
        self.url = config.url
        self.signingEnvironment = config.signingEnvironment
        self.signingEnvironmentURL = config.signingEnvironmentUrl?.absoluteString
        self.size = config.size
        self.sha256 = config.sha256
        self.variant = config.variant
        self.jetsamPropertiesVariant = config.jetsamPropertiesVariant
        self.cacheable = config.cacheable
        self.aeaDecryptionParams = config.aeaDecryptionParams
        self.readWrite = config.readwrite
    }

}

// MARK: Config Extensions

extension Config.Authentication {
    var downloadAuthentication: DownloadAuthentication {
        if let token = self.dawToken {
            return .daw(token: token.string)
        } else if let oidc = self.oidcToken {
            return .oidc(token: oidc.string)
        } else if let wg = self.westgate {
            return .westgate(username: wg.username, token: wg.token.string)
        } else {
            return .none
        }
    }
}

extension Config.Cryptex.Cryptex.AeaDecryptionParams {

    func getDecryptionKey() -> SymmetricKey? {
        // convert input String key into an array of UInt8 bytes
        guard let hexDecoded = decryptionKey.string.hexadecimalASCIIBytes, !hexDecoded.isEmpty else {
            logger.error("Invalid hex decryption key, could not convert to array of UInt8")
            return nil
        }

        // convert array of bytes to SymmetricKey for use in a decryption context
        return SymmetricKey(data: hexDecoded)
    }

    func getArchiveID() -> Data? {
        guard let archiveIdentifierBytes = archiveId.string.hexadecimalASCIIBytes, !archiveIdentifierBytes.isEmpty else {
            logger.error("Failed to convert archive identifier from String to Data")
            return nil
        }
        return Data(archiveIdentifierBytes)
    }

}
