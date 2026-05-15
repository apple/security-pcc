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
//  CryptexCache.swift
//  darwinOSBits
//
//

import Foundation
import System
import CryptoKit
import DarwinPrivate.os.variant
import os

typealias CryptexCache = Cache<CryptexCacheDelegate>
    
class CryptexCacheDelegate: CacheDelegate {
    static let logger = Logger.cryptexcache
	static private let permittedFiles: [String] = ["aea", "ticket", "ginf"]

    class Entry {
        let path: FilePath
        let lock: ExclusiveLockedFile
        let archivePath: FilePath
        let removeArchiveOnDeInit: Bool // For when "archivePath" is pointing to the unencrypted copy of the archive.
        let aeaDecryptionParameters: AEADecryptionParameters?
        var extractionPath: FilePath?
        
        init(at path: FilePath, lock: ExclusiveLockedFile, archivePath: FilePath, removeArchiveOnDeinit: Bool, aeaDecryptionParameters: AEADecryptionParameters?) {
            self.path = path
            self.lock = lock
            self.archivePath = archivePath
            self.removeArchiveOnDeInit = removeArchiveOnDeinit
            self.aeaDecryptionParameters = aeaDecryptionParameters
            self.extractionPath = nil
        }

		internal func copyObject(fromPath: FilePath, toPath: FilePath) {
			do {
				try FileManager.default.copyItem(atPath: fromPath.string, toPath: toPath.string)
			} catch {
				logger.info("Caught copyItem error \(error).")
			}
		}

		func fetchTicketandGinfPath() throws -> (FilePath, FilePath) {
			let dirPath = try CryptexManager.setUpExtractedPath()
			let toTmpTicketPath = dirPath.appending("ticket")
			let toTmpGINFPath = dirPath.appending("ginf")
			let fromTicketPath = self.path.appending("/ticket")
			let fromGINFPath = self.path.appending("/ginf")

			copyObject(fromPath: fromTicketPath, toPath: toTmpTicketPath)
			copyObject(fromPath: fromGINFPath, toPath: toTmpGINFPath)

			return (toTmpTicketPath, toTmpGINFPath)
		}

		func deleteTicketAndginf() {
			let ticketPath = self.path.appending("/ticket")
			let ginfPath = self.path.appending("/ginf")

			do { try FileManager.default.removeItem(atPath: ticketPath.string) } catch {
				logger.error("No ticket to delete")
			}

			do { try FileManager.default.removeItem(atPath: ginfPath.string) } catch {
				logger.error("No ginf to delete")
			}
		}

		func ingestTicketandGINF(ticket ticketFromPath: FilePath, ginfPath ginfFromPath: FilePath) throws {
			let ticketToPath = self.path.appending("/ticket")
			let ginfToPath = self.path.appending("/ginf")

			logger.info("Copying ginf ticket from \(ginfFromPath) to \(ginfToPath)")
			try FileManager.default.copyItem(at: URL(filePath: ginfFromPath)!, to:  URL(filePath: ginfToPath)!)

			logger.info("Copying personalized ticket from \(ticketFromPath) to \(ticketToPath)")
			try FileManager.default.copyItem(at: URL(filePath: ticketFromPath)!, to:  URL(filePath: ticketToPath)!)
		}

        func extract() throws -> FilePath {
            if let extractionPath = self.extractionPath {
                return extractionPath
            } else {
                let extractionPath = try CryptexManager.setUpExtractedPath()
                self.extractionPath = extractionPath
                do {
                    try self.archivePath.extract(to: extractionPath, using: self.aeaDecryptionParameters)
                } catch {
                    // We should cleanup the entry if it's failed to extract
                    self.extractionPath = nil
                    self.cleanup()
                    throw error
                }

                return extractionPath
            }
        }

        private func cleanup() {
            do {
                try self.archivePath.remove()
            } catch {
                Logger.caching.fault("Failed to remove \"\(self.archivePath)\" from cache: \(error)")
            }
        }

        deinit {
            if self.removeArchiveOnDeInit {
                self.cleanup()
            }
        }
    }
    
    struct AccessParameter {
        let digest: [UInt8]?
        let alternateKnoxCDNHost: String?
        let aeaDecryptionParameters: AEADecryptionParameters?
        let maxActiveNetworkTasks: Int?
        let chunkSize: UInt64?
    }
    
    enum Error: Swift.Error {
        case extractionFailure
        case missingRequiredDigest
        case downloadFailure
    }
    
    func handleCacheMiss(forCacheEntryDirectory entryDir: FilePath,
                         lock: ExclusiveLockedFile,
                         downloadInformation: CacheDownloadInformation,
                         downloadedFile: FilePath,
                         tempDir: FilePath,
                         delegateParameter: AccessParameter) async throws -> Entry {
        let aeaPath = entryDir.appending("aea")
        let downloadedCryptexArchiveMagic: FilePath.ArchiveType?

        do {
            downloadedCryptexArchiveMagic = try downloadedFile.readArchiveMagic()
        } catch {
            CryptexCacheDelegate.logger.error("[\(downloadInformation.url)] Failed to read archive magic for \(downloadedFile): \(error)")
            throw Error.extractionFailure
        }
        
        if downloadedCryptexArchiveMagic == .AppleEncryptedArchive {
            // If the file is already an AEA, just move it into the cache
            try FileManager.default.moveItem(atPath: downloadedFile.string, toPath: aeaPath.string)
            
            return Entry(at: entryDir, lock: lock, archivePath: aeaPath, removeArchiveOnDeinit: false, aeaDecryptionParameters: delegateParameter.aeaDecryptionParameters)
        } else {
            // Non-AEA cases must be wrapped in an AEA before inserted into the cache
            guard let digest = delegateParameter.digest else {
                CryptexCacheDelegate.logger.error("[\(downloadInformation.url)] No digest found when digest is required.")
                throw Error.missingRequiredDigest
            }
            
            do {
                try downloadedFile.wrapFileContentsInAppleEncryptedArchive(
                    at: aeaPath,
                    using: SymmetricKey(data: digest),
                    permissions: [.ownerReadWrite],
                    compression: downloadedCryptexArchiveMagic == .UncompressedAppleArchive)
            } catch {
                // Failed to create cache archive, so the next time will have a cache miss,
                // but we still try to extract the inner archive.
                CryptexCacheDelegate.logger.warning("[\(downloadInformation.url)] Failed to create archive in cache: \(error)")
            }
            
            // "downloadedFile" will be deleted soon after returning. Moving to extend life.
            let innerArchivePath: FilePath = entryDir.appending("inner")
            try FileManager.default.moveItem(atPath: downloadedFile.string, toPath: innerArchivePath.string)
            
            return Entry(at: entryDir,
                         lock: lock,
                         archivePath: innerArchivePath,
                         removeArchiveOnDeinit: true,
                         aeaDecryptionParameters: delegateParameter.aeaDecryptionParameters)
        }
    }

    func handleCacheHit(forCacheEntryDirectory entryDir: FilePath,
                        lock: ExclusiveLockedFile,
                        downloadInformation: CacheDownloadInformation,
                        tempDir: FilePath,
                        delegateParameter: AccessParameter) async throws -> Entry {
        let cachedFile = entryDir.appending("aea")
        
        if (try? cachedFile.exists()) != true {
            CryptexCacheDelegate.logger.error("[\(downloadInformation.url)] Cached archive missing")
            throw CacheError.validationFailure
        }
        
        let removeArchiveOnDeinit: Bool
        let finalArchivePath: FilePath
        
        if downloadInformation.url.scheme == kKnoxURLScheme || delegateParameter.aeaDecryptionParameters != nil {
            finalArchivePath = cachedFile
            removeArchiveOnDeinit = false
        } else {
            let innerArchivePath = entryDir.appending("inner")

            guard let digest = delegateParameter.digest else {
                CryptexCacheDelegate.logger.error("[\(downloadInformation.url)] No digest found when digest is required.")
                throw Error.missingRequiredDigest
            }

            do {
                try cachedFile.extractAppleEncryptedArchive(
                    to: innerArchivePath,
                    using: SymmetricKey(data: digest),
                    mode: .extractRawBytes(outputFilePermissions: [.ownerReadWrite]))
            } catch {
                // Give an opportunity for a second chance.
                throw CacheError.validationFailure
            }

            if (try? innerArchivePath.fileExists()) != true {
                // If the path doesn't point to a regular file, bail.
                throw Error.extractionFailure
            }

            if (try? SHA256.Digest(innerArchivePath) == digest) != true {
                CryptexCacheDelegate.logger.error("[\(downloadInformation.url)] Cached file failed sha validation!")
                throw CacheError.validationFailure
            }
            
            finalArchivePath = innerArchivePath
            removeArchiveOnDeinit = true
        }
        
        return Entry(at: entryDir,
                     lock: lock,
                     archivePath: finalArchivePath,
                     removeArchiveOnDeinit: removeArchiveOnDeinit,
                     aeaDecryptionParameters: delegateParameter.aeaDecryptionParameters)
    }

    func handleDownload(from url: URL,
                        to downloadDirectory: FilePath,
                        authentication: DownloadAuthentication,
                        downloadConfiguration: DownloadConfiguration,
                        delegateParameter: AccessParameter) async throws -> FilePath {
        let downloaded: FilePath
        
        if url.scheme == kKnoxURLScheme {
            guard let encrypted = await KnoxClientWrapper.downloadRaw(from: url,
                                                                      to: downloadDirectory,
                                                                      configuration: downloadConfiguration,
                                                                      authentication: authentication,
                                                                      alternateCDNHost: delegateParameter.alternateKnoxCDNHost) else {
                throw Error.downloadFailure
            }
            
            // At the time of writing, Knox digests are commonly the digest of the decrypted asset.
            // In addition, Knox may use algorithms other than SHA-256.
            // I have observed Knox returning a SHA-512/256 digest and that algorithm is not supported by CryptoKit.
            // Because there are configs out there that erroneously contain the SHA-512/256 digest of the decrypted asset
            // for Knox URLs, the digest check is not done here. It is also redundant.
            // At extraction time, the AEA decryption process combined with an archive ID check ensures the integrity of the download.
            
            downloaded = encrypted
        } else {
            guard let compressed = await Network.downloadItem(at: url,
                                                              to: downloadDirectory,
                                                              attempts: Int(truncatingIfNeeded: downloadConfiguration.downloadRetries),
                                                              background: downloadConfiguration.networkServiceType == .background,
                                                              maxActiveTasks: delegateParameter.maxActiveNetworkTasks,
                                                              chunkSize: delegateParameter.chunkSize) else {
                throw Error.downloadFailure
            }

            if let digest = delegateParameter.digest {
                if (try? SHA256.Digest(compressed) == digest) != true {
                    Logger.caching.error("[\(url)] Downloaded file failed sha validation!")
                    throw Error.downloadFailure
                }
            }

            downloaded = compressed
        }

        return downloaded
    }

	func entryPurge(from: FilePath) throws {
		//Parse filename, remove anything not in the "allow" list
		for fileEntry in try FileManager.default.contentsOfDirectory(atPath: from.string) {
			if (!Self.permittedFiles.contains(fileEntry)) {
				Logger.caching.error("\(fileEntry) is not a permitted file, removing it from the cache")
				try Self.removeItem(at: FilePath(from.string + "/" + fileEntry))
			}
		}
	}

	static private func removeItem(at path: FilePath) throws {
		do {
			try path.remove()
		} catch {
			Logger.caching.fault("Failed to remove \"\(path)\" from cache: \(error)")
			throw error
		}
	}
}

extension CryptexCache {
    static let logger = Logger.cryptexcache
    
#if os(macOS)
    internal static let defaultCacheDirectoryPath: FilePath = "/System/Volumes/Preboot/DarwinInitCache/cryptex"
#else
    internal static let defaultCacheDirectoryPath: FilePath = "/private/preboot/DarwinInitCache/cryptex"
#endif
}
