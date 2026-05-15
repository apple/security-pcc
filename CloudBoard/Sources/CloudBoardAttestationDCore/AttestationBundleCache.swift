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

import CloudBoardLogging
import Foundation
import os

protocol AttestationBundleCache: Sendable {
    /// Write an entry to the cache.
    func write(_ entry: AttestationCacheEntry) async throws

    /// Remove an entry from the cache.
    func remove(keyId: Data) async

    /// Read all the entries from the cache.
    func read() async -> AttestationCacheRecord
}

struct AttestationCacheEntry: Codable, Sendable, Hashable {
    let keyId: Data
    let attestationBundle: Data
}

struct AttestationCacheRecord: Codable {
    var entries: [Data: Data]
}

final class NoopAttestationBundleCache: AttestationBundleCache {
    static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "NoopAttestationBundleCache"
    )

    init() {
        Self.logger.warning("Using Noop Cache. Attestation data will not be persisted!")
    }

    func write(_: AttestationCacheEntry) async throws {
        Self.logger.warning("Using Noop Cache. Attestation data will not be persisted!")
    }

    func remove(keyId _: Data) async {
        Self.logger.warning("Using Noop Cache. Attestation data will not be persisted!")
    }

    func read() async -> AttestationCacheRecord {
        Self.logger.warning("Using Noop Cache. Attestation data not be persisted! Returning empty cache")
        return .init(entries: [:])
    }
}

actor OnDiskAttestationBundleCache: AttestationBundleCache {
    static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "OnDiskAttestationBundleCache"
    )

    private let cacheFileURL: URL
    private let cacheFileDirectoryURL: URL
    private let jsonEncoder: JSONEncoder = .init()
    private let jsonDecoder: JSONDecoder = .init()
    private let fileManager: FileManager = .init()
    private var inMemoryCache: AttestationCacheRecord = .init(entries: [:])

    init(directoryURL: URL) throws {
        self.cacheFileDirectoryURL = directoryURL
        do {
            // Ensure cache directory exists and create missing parent directories if needed.
            // If the directory already exists, the function succeeds without error.
            try self.fileManager.createDirectory(
                at: self.cacheFileDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            Self.logger.error("Failed to create cache directory, error: \(String(unredacted: error), privacy: .public)")
            throw error
        }
        self.cacheFileURL = self.cacheFileDirectoryURL.appending(component: "attestation-bundle-cache.json")
        Self.logger.log("Creating cache at \(self.cacheFileURL.description, privacy: .public)")
        self.jsonEncoder.outputFormatting = [.prettyPrinted]
    }

    /// Resets the cache by removing the underlying cached file.
    private func reset() {
        do {
            self.inMemoryCache.entries.removeAll()
            try self.fileManager.removeItem(at: self.cacheFileURL)
        } catch {
            Self.logger.error(
                "The cache failed to delete a malformed file, error: \(String(unredacted: error), privacy: .public). The cache will probably not recover now and will keep failing."
            )
        }
    }

    func write(_ entry: AttestationCacheEntry) async throws {
        if self.inMemoryCache.entries[entry.keyId] != nil {
            Self.logger.error("KeyID \(entry.keyId, privacy: .public) already present in memory cache.")
        } else {
            self.inMemoryCache.entries[entry.keyId] = entry.attestationBundle
            let onDiskCache = try self.jsonEncoder.encode(self.inMemoryCache)
            try onDiskCache.write(to: self.cacheFileURL, options: .atomic)
            Self.logger.info("Written keyId: \(entry.keyId, privacy: .public) to the on disk cache.")
        }
    }

    /// Removes entry only from the in memory cache.
    /// On disk is only updated the next time `write` is called.
    func remove(keyId: Data) async {
        if self.inMemoryCache.entries.removeValue(forKey: keyId) != nil {
            Self.logger.info("KeyID \(keyId, privacy: .public) marked for removal from on disk cache on next write.")
        }
    }

    func read() async -> AttestationCacheRecord {
        let data: Data
        do {
            data = try Data(contentsOf: self.cacheFileURL, options: .uncached)
            Self.logger.debug("Cache file data loaded.")
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            Self.logger.debug("Cache miss.")
            return self.inMemoryCache
        } catch {
            Self.logger.error(
                "Could not read on disk cache, resetting. Error: \(String(unredacted: error), privacy: .public)"
            )
            self.reset()
            return self.inMemoryCache
        }
        do {
            self.inMemoryCache = try self.jsonDecoder.decode(AttestationCacheRecord.self, from: data)
            return self.inMemoryCache
        } catch {
            Self.logger.error(
                "The cache is malformed, resetting. Error: \(String(unredacted: error), privacy: .public)"
            )
            self.reset()
            return self.inMemoryCache
        }
    }
}
