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
//  Cache.swift
//  DarwinInit
//

import Foundation
import System
import CryptoKit
import os

protocol CacheDelegate {
    associatedtype Entry
    associatedtype AccessParameter
    
    // "completionBlock" should be called with a path to the data.
    // A 'nil' block is sent on a prefetch command.
    func handleCacheMiss(forCacheEntryDirectory entryDir: FilePath,
                         lock: ExclusiveLockedFile,
                         downloadInformation: CacheDownloadInformation,
                         downloadedFile: FilePath,
                         tempDir: FilePath,
                         delegateParameter: AccessParameter) async throws -> Entry
    
    // "completionBlock" should be called with a path to the data.
    // A 'nil' block is sent on a prefetch command.
    func handleCacheHit(forCacheEntryDirectory entryDir: FilePath,
                        lock: ExclusiveLockedFile,
                        downloadInformation: CacheDownloadInformation,
                        tempDir: FilePath,
                        delegateParameter: AccessParameter) async throws -> Entry
    
    func handleDownload(from url: URL,
                        to downloadDirectory: FilePath,
                        authentication: DownloadAuthentication,
                        downloadConfiguration: DownloadConfiguration,
                        delegateParameter: AccessParameter) async throws -> FilePath

	func entryPurge(from: FilePath) throws
}

enum CacheError: Error {
    case failedToSetUpOutputDirectory
    case failedToEnumerateCacheContents
    case validationFailure
    case evictionFailure
}

struct CacheDownloadInformation {
    let url: URL
    let authentication: DownloadAuthentication
}

struct CacheEntryFilesystemInfo {
    let url: URL
    let totalFileAllocatedSize: Int
    let contentModificationDate: Date
}

class Cache<D: CacheDelegate> {
    internal let cacheRootDirectory: FilePath
    internal let maxTotalSize: Int
    private let delegate: D

    internal let cacheDataDirectory: FilePath
    private let cacheTemporaryDirectory: FilePath
    private let cacheDownloadDirectory: FilePath

    init?(at cacheDirectoryPath: FilePath, delegate: D, maxTotalSize: Int? = nil) {
        self.cacheRootDirectory = cacheDirectoryPath

        self.maxTotalSize = if let maxTotalSize {
            max(0, maxTotalSize)
        } else {
            // Not configured, auto-calculate based on volume capacity
            Self.calculateDefaultCacheSize(for: cacheDirectoryPath)
        }
        self.delegate = delegate

        self.cacheDataDirectory = self.cacheRootDirectory.appending("data")
        self.cacheTemporaryDirectory = self.cacheRootDirectory.appending("tmp")
        self.cacheDownloadDirectory = self.cacheRootDirectory.appending("download")

        do {
            try Self.createDirectory(at: self.cacheRootDirectory)
        } catch {
            Logger.caching.fault("Failed to create cache directory at \(self.cacheRootDirectory): \(error)")
            return nil
        }
    }

    /// Calculate default cache size as a percentage of volume capacity
    ///
    /// - Parameters:
    ///   - cacheDirectoryPath: The path where the cache will be stored
    ///   - ratio: The ratio of volume capacity to use (default: 0.5 = 50%)
    /// - Returns: The calculated cache size in bytes, bounded by min/max limits
    static func calculateDefaultCacheSize(for cacheDirectoryPath: FilePath, ratio: Double = 0.5) -> Int {
        do {
            let totalCapacity = try cacheDirectoryPath.volumeTotalCapacity()
            let calculatedSizeDouble = Double(totalCapacity) * ratio

            // Check if the calculated size exceeds Int.max to prevent overflow on 32-bit platforms
            let calculatedSize: Int
            if calculatedSizeDouble > Double(Int.max) {
                Logger.caching.warning("Calculated cache size (\(calculatedSizeDouble)) exceeds Int.max (\(Int.max)). Clamping to Int.max.")
                calculatedSize = Int.max
            } else {
                calculatedSize = Int(calculatedSizeDouble)
            }

            Logger.caching.info("Calculated default cache size: \(calculatedSize.formatted(.byteCount(style: .memory))) (\(Int(ratio * 100))% of \(totalCapacity.formatted(.byteCount(style: .memory))) volume)")

            // Minimum 1 GB
            let minSize = 1 * 1024 * 1024 * 1024

            return max(minSize, calculatedSize)
        } catch {
            Logger.caching.error("Failed to query volume attributes for \(cacheDirectoryPath): \(error). Using default cache size.")
            return kDefaultCryptexCacheMaxTotalSize
        }
    }
    
    static internal func generateCacheEntryName(forEntryBackedByResourceAt url: URL) -> String {
        return SHA256.hash(data: url.dataRepresentation).map { String(format: "%02hhx", $0) }.joined()
    }
    
    // The root of the cache should contain 3 directories (tmp, download, and data) with sub-directories
    // for each cache entry.
    private func getTemporaryDirectoryPathForEntry(withName name: String) -> FilePath {
        return self.cacheTemporaryDirectory.appending(name)
    }
    
    private func getDownloadDirectoryPathForEntry(withName name: String) -> FilePath {
        return self.cacheDownloadDirectory.appending(name)
    }
    
    // This should only be retrieved under lock within this class.
    // It's only marked "internal" instead of "private", so that it can be used in tests.
    internal func getDataDirectoryPathForEntry(withName name: String) -> FilePath {
        return self.cacheDataDirectory.appending(name)
    }
    
    private func getFileLockPathForEntry(withName name: String) -> FilePath {
        return self.cacheRootDirectory.appending(".\(name).lock")
    }
    
    @discardableResult
    internal func access(entryBackedByResourceAt url: URL,
                         authentication: DownloadAuthentication,
                         downloadConfiguration: DownloadConfiguration = DownloadConfiguration(),
                         delegateParameter: D.AccessParameter) async throws -> D.Entry {
        let cacheEntryName = Self.generateCacheEntryName(forEntryBackedByResourceAt: url)
        let cacheEntryDirectory = self.getDataDirectoryPathForEntry(withName: cacheEntryName)
        
        let entry = try await self.inContextForEntry(withName: cacheEntryName) { (downloadDir: FilePath, tempDir: FilePath, lock: ExclusiveLockedFile) in
            let isCacheHit: Bool
            
            do {
                try Self.createDirectory(at: cacheEntryDirectory)
            } catch {
                Logger.caching.error("[\(url)] Failed to create cache entry directory at \(cacheEntryDirectory)")
                throw error
            }
            
            try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: cacheEntryDirectory.string)
            
            do {
                isCacheHit = try !cacheEntryDirectory.isEmptyDirectory()
            } catch {
                // Failed to enumerate files...
                Logger.caching.error("[\(url)] Failed to enumerate files in cache directory... cleaning directory: \(error)")
                isCacheHit = false
                try cacheEntryDirectory.removeAllFilesInDirectory()
            }
            
            let cacheDownloadInformation = CacheDownloadInformation(url: url, authentication: authentication)
            
            if (isCacheHit) {
                Logger.caching.log("[\(url)] Found in cache")
                
                do {
                    return try await self.delegate.handleCacheHit(forCacheEntryDirectory: cacheEntryDirectory,
                                                           lock: lock,
                                                           downloadInformation: cacheDownloadInformation,
                                                           tempDir: tempDir,
                                                           delegateParameter: delegateParameter)
                } catch CacheError.validationFailure {
                    Logger.caching.log("[\(url)] Cache entry validation failed; triggering cache miss")
                    
                    // Clean slate for the cache miss
                    try cacheEntryDirectory.removeAllFilesInDirectory()
                    try tempDir.removeAllFilesInDirectory()
                    try downloadDir.removeAllFilesInDirectory()
                }
            }
            
            Logger.caching.log("[\(url)] Cache miss")
            
            let downloadedFile: FilePath
            
            do {
                downloadedFile = try await self.delegate.handleDownload(from: url,
                                                                        to: downloadDir,
                                                                        authentication: authentication,
                                                                        downloadConfiguration: downloadConfiguration,
                                                                        delegateParameter: delegateParameter)
            } catch {
                Logger.caching.error("[\(url)] Failed to download: \(error)")
                throw error
            }
            
            do {
                return try await self.delegate.handleCacheMiss(forCacheEntryDirectory: cacheEntryDirectory,
                                                                lock: lock,
                                                                downloadInformation: cacheDownloadInformation,
                                                                downloadedFile: downloadedFile,
                                                                tempDir: tempDir,
                                                                delegateParameter: delegateParameter)
            } catch {
                Logger.caching.error("[\(url)] Failed to handle cache miss: \(error)")
                throw error
            }
        }
        
        try await self.evict()
        return entry
    }
    
    func purge(retainingEntriesForURLs urls: [URL]) async throws {
        let retainedEntries = urls.reduce(into: Set<String>()) {
            $0.insert(Self.generateCacheEntryName(forEntryBackedByResourceAt: $1))
        }
        
        for item in try FileManager.default.contentsOfDirectory(atPath: self.cacheRootDirectory.string) {
            let fullPath = self.cacheRootDirectory.appending(item)
            
            if fullPath != self.cacheDataDirectory {
                try Self.removeItem(at: fullPath)
            } else {
				for entryName in try FileManager.default.contentsOfDirectory(atPath: self.cacheDataDirectory.string) {
					try await self.inContextForEntry(withName: entryName) {
						if !retainedEntries.contains(entryName) {
							try Self.removeItem(at: self.cacheDataDirectory.appending(entryName))
						} else {
							try self.delegate.entryPurge(from: self.cacheDataDirectory.appending(entryName))
						}
					}
				}
			}
		}
    }
    
    private func inContextForEntry<T>(withName name: String, _ block: (_ downloadDir: FilePath, _ tempDir: FilePath, _ lock: ExclusiveLockedFile) async throws -> T) async throws -> T {
        let tempDir = self.getTemporaryDirectoryPathForEntry(withName: name)
        let downloadDir = self.getDownloadDirectoryPathForEntry(withName: name)
        let operationLockPath = self.getFileLockPathForEntry(withName: name)
        let lock = try ExclusiveLockedFile.open(operationLockPath, permissions: .ownerReadWriteExecute)

        return try await Self.withTemporaryDirectory(at: tempDir) {
            return try await Self.withTemporaryDirectory(at: downloadDir) {
                return try await block(downloadDir, tempDir, lock)
            }
        }
    }
    
    private func inContextForEntry(withName name: String, nonBlocking: Bool = false, _ block: () async throws -> Void) async throws {
        let operationLockName = self.getFileLockPathForEntry(withName: name)
        
        try await ExclusiveLockedFile.withLock(on: operationLockName, permissions: .ownerReadWriteExecute, nonBlocking: nonBlocking) {
            try await block()
        }
    }
    
    static private func removeItem(at url: URL) throws {
        Logger.caching.debug("Removing item at \(url)")
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Logger.caching.fault("Failed to remove \"\(url)\" from cache: \(error)")
            throw error
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

    static private func createDirectory(at path: FilePath) throws {
        try path.createDirectory(permissions: .ownerReadWriteExecute, intermediateDirectories: true)
    }

    // This function is used instead of defer blocks to propagate file removal errors.
    // It is not possible to throw from a defer block.
    static private func withTemporaryDirectory<T>(at path: FilePath, _ body: () async throws -> T) async throws -> T {
        let returnValue: T

        try Self.createDirectory(at: path)

        do {
            returnValue = try await body()
        } catch {
            let preexistingError = error

            do {
                try Self.removeItem(at: path)
            } catch {
                Logger.filesystem.fault("Removal of file system item '\(path)' failed after pre-existing error thrown: \(preexistingError)")
                throw error
            }

            throw preexistingError
        }

        try Self.removeItem(at: path)

        return returnValue
    }
    
    // This function doesn't lock the entries, so the information could be inaccurate.
    // Only filesystem metadata should be checked here.
    // If the modification time in the returned info matches the modification time under lock,
    // then the size should be correct (ignoring any strange modification time manipulation).
    private func getCacheEntryFilesystemInfo() throws -> [CacheEntryFilesystemInfo] {
        var output: [CacheEntryFilesystemInfo] = []
        
        if (try? self.cacheDataDirectory.directoryExists()) != true {
            Logger.caching.debug("Cache data directory doesn't exist. Returning empty cache entry filesystem info.")
            return output
        }
        
        guard let cacheEntryEnumerator = FileManager.default.enumerator(at: URL(filePath: self.cacheDataDirectory.string),
                                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                                        options: .skipsSubdirectoryDescendants) else {
            Logger.caching.error("Failed to create cache entry enumerator")
            throw CacheError.failedToEnumerateCacheContents
        }
        
        for case let cacheDataDirectoryItem as URL in cacheEntryEnumerator {
            guard let resourceValues = try? cacheDataDirectoryItem.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDirectory = resourceValues.isDirectory
            else {
                Logger.caching.fault("Failed to get \"isDirectory\" for \(cacheDataDirectoryItem.lastPathComponent). Removing...")
                try Self.removeItem(at: cacheDataDirectoryItem)
                continue
            }
            
            if !isDirectory {
                Logger.caching.debug("\(cacheDataDirectoryItem.lastPathComponent) in cache data is not a directory! Removing...")
                try Self.removeItem(at: cacheDataDirectoryItem)
                continue
            }
            
            let resourceKeys = Set<URLResourceKey>([
                .isRegularFileKey,
                .totalFileAllocatedSizeKey])
            
            guard let cacheEntryContentEnumerator = FileManager.default.enumerator(at: cacheDataDirectoryItem,
                                                                                   includingPropertiesForKeys: Array(resourceKeys),
                                                                                   options: []) else {
                Logger.caching.error("Failed to create cache entry content enumerator")
                throw CacheError.failedToEnumerateCacheContents
            }
            
            var entryTotalAllocatedSize: Int = 0
            
            for case let cacheEntryItem as URL in cacheEntryContentEnumerator {
                guard let resourceValues = try? cacheEntryItem.resourceValues(forKeys: resourceKeys),
                      let isRegularFile = resourceValues.isRegularFile
                else {
                    Logger.caching.fault("Failed to get \"isRegularFile\" for \(cacheEntryItem.lastPathComponent)")
                    continue
                }
                
                if !isRegularFile {
                    continue
                }
                
                guard let totalFileAllocatedSize = resourceValues.totalFileAllocatedSize
                else {
                    Logger.caching.fault("Failed to get \"totalFileAllocatedSize\" for \(cacheEntryItem.lastPathComponent)")
                    continue
                }
                
                entryTotalAllocatedSize += totalFileAllocatedSize
            }
            
            guard let entryContentModificationDate = try? cacheDataDirectoryItem.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                Logger.caching.fault("Failed to get \"contentModificationDate\" for \(cacheDataDirectoryItem.lastPathComponent)")
                continue
            }
            
            output.append(CacheEntryFilesystemInfo(url: cacheDataDirectoryItem,
                                                   totalFileAllocatedSize: entryTotalAllocatedSize,
                                                   contentModificationDate: entryContentModificationDate))
        }
        
        return output
    }
    
    private func evict() async throws {
        var evictionCandidates = try self.getCacheEntryFilesystemInfo().sorted(by: { $0.contentModificationDate > $1.contentModificationDate })
        var cacheContentTotalSize = evictionCandidates.reduce(0) { $0 + $1.totalFileAllocatedSize }

        while cacheContentTotalSize > self.maxTotalSize {
            Logger.caching.debug("""
                    Cache eviction: current size \(cacheContentTotalSize.formatted(.byteCount(style: .memory))), \
                    max size \(self.maxTotalSize.formatted(.byteCount(style: .memory))), \
                    entries: \(evictionCandidates.count)
                """)

            guard let candidate = evictionCandidates.popLast() else {
                Logger.caching.error("""
                    No more cache entries to evict! Cache size: \(cacheContentTotalSize.formatted(.byteCount(style: .memory))), \
                    max size: \(self.maxTotalSize.formatted(.byteCount(style: .memory)))
                """)
                throw CacheError.evictionFailure
            }

            let cacheEntryName = candidate.url.lastPathComponent
            Logger.caching.debug("Attempting to evict \(cacheEntryName) (\(candidate.totalFileAllocatedSize.formatted(.byteCount(style: .memory))))")
            do {
                try await self.inContextForEntry(withName: cacheEntryName, nonBlocking: true) {
                    guard let entryContentModificationDate = try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                        Logger.caching.fault("Failed to get \"contentModificationDate\" for \(cacheEntryName)")
                        return
                    }

                    if candidate.contentModificationDate != entryContentModificationDate {
                        Logger.caching.debug("\"contentModificationDate\" for \(candidate.url.lastPathComponent) changed. Skipping...")
                        return
                    }

                    // The entry should have been unmodified since it was checked since the modification time matches.
                    // The size should also be accurate.
                    Logger.caching.info("Evicting \"\(cacheEntryName)\" from cache (\(candidate.totalFileAllocatedSize.formatted(.byteCount(style: .memory))))")
                    let entryDirectories = [
                        self.getDataDirectoryPathForEntry(withName: cacheEntryName),
                        self.getTemporaryDirectoryPathForEntry(withName: cacheEntryName),
                        self.getDownloadDirectoryPathForEntry(withName: cacheEntryName)
                    ]

                    for directory in entryDirectories {
                        do {
                            try FileManager.default.removeItem(atPath: directory.string)
                        } catch CocoaError.fileNoSuchFile {
                            // Ignore
                        }
                    }

                    cacheContentTotalSize -= candidate.totalFileAllocatedSize
                    Logger.caching.info("Successfully evicted \(cacheEntryName), new cache size: \(cacheContentTotalSize.formatted(.byteCount(style: .memory)))")
                }
            } catch Errno.resourceTemporarilyUnavailable {
                Logger.caching.debug("Skipping eviction of \(cacheEntryName) from cache due to existing lock on entry")
                continue
            }
        }
    }
}
