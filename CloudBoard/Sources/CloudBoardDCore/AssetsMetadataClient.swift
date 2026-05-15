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

import CloudBoardDomain
import CloudBoardLogging
import os
import Synchronization
import System
#if canImport(CloudAssetDownloaderFramework)
import CloudAssetDownloaderFramework
#endif

typealias CBAssetMetadata = CloudBoardDomain.AssetMetadata

protocol AssetsMetadataClientProtocol: Sendable {
    func connect() async throws

    /// Subscribes to assets metadata updates for a specific consumer.
    /// This method creates a long-lived subscription that continuously receives assets metadata
    /// updates from the source.
    ///
    /// - Parameters:
    ///   - consumerID: The unique identifier for the asset consumer.
    ///   - assetsUpdateHandler: A handler invoked for each assets metadata update received.
    ///                          The handler should process the assets and throw an error if
    ///                          consumption fails.
    func subscribeToAssetsMetadata(
        for consumerID: String,
        assetsUpdateHandler: @Sendable ([CBAssetMetadata]) async throws -> Void
    ) async throws
}

#if canImport(CloudAssetDownloaderFramework)
typealias CADAssetMetadata = CloudAssetDownloaderFramework.AssetMetadata

final class CloudAssetsMetadataClient: AssetsMetadataClientProtocol {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudAssetsMetadataClient"
    )

    private let client: CloudAssetDownloaderClient

    init() {
        self.client = CloudAssetDownloaderClient()
    }

    func connect() async throws {
        try await self.client.connect()
    }

    func subscribeToAssetsMetadata(
        for consumerID: String,
        assetsUpdateHandler: @Sendable ([CBAssetMetadata]) async throws -> Void
    ) async throws {
        let stream = try await self.client.subscribeAssetsMetadata(for: consumerID)
        for await update in stream {
            Self.logger.log("""
            Received assets metadata update from CloudAssetDownloader. \
            ConsumerID=\(consumerID, privacy: .public) \
            AssetsMetadata=\(update, privacy: .public)
            """)

            let assetsMetadata: [CBAssetMetadata] = update.map {
                CBAssetMetadata(
                    consumerID: consumerID,
                    id: $0.id,
                    version: $0.version,
                    path: $0.path.string,
                    identityHash: $0.identityHash
                )
            }
            do {
                try await assetsUpdateHandler(assetsMetadata)
                await self.reportAssetsConsumptionSuccess(consumerID: consumerID, assetsMetadata: update)
            } catch {
                await self.reportAssetsConsumptionFailure(
                    consumerID: consumerID,
                    assetsMetadata: update,
                    consumptionError: error
                )
            }
        }
        Self.logger.log("Subscription stream for \(consumerID, privacy: .public) finished.")
    }

    private func reportAssetsConsumptionSuccess(
        consumerID: String,
        assetsMetadata: [CADAssetMetadata]
    ) async {
        Self.logger.log("""
        Reporting assets consumptionSuccess. \
        ConsumerID=\(consumerID, privacy: .public) \
        AssetsMetadata=\(assetsMetadata, privacy: .public)
        """)
        do {
            try await self.client.reportAssetsConsumptionSuccess(
                applicationID: consumerID,
                assetsMetadata: assetsMetadata
            )
        } catch let reportError {
            Self.logger.error("""
            Failed to report assets consumption success. \
            ConsumerID=\(consumerID, privacy: .public) \
            AssetsMetadata=\(assetsMetadata, privacy: .public) \
            Error=\(String(unredacted: reportError))
            """)
        }
    }

    private func reportAssetsConsumptionFailure(
        consumerID: String,
        assetsMetadata: [CADAssetMetadata],
        consumptionError: Error
    ) async {
        Self.logger.error("""
        Reporting assets consumption failure. \
        ConsumerID=\(consumerID, privacy: .public) \
        AssetsMetadata=\(assetsMetadata, privacy: .public) \
        Reason=\(String(unredacted: consumptionError))
        """)
        do {
            try await self.client.reportAssetsConsumptionFailure(
                applicationID: consumerID,
                assetsMetadata: assetsMetadata,
                reason: String(unredacted: consumptionError)
            )
        } catch let reportError {
            Self.logger.error("""
            Failed to report assets consumption failure. \
            ConsumerID=\(consumerID, privacy: .public) \
            AssetsMetadata=\(assetsMetadata, privacy: .public) \
            Error=\(String(unredacted: reportError))
            """)
        }
    }
}
#endif

/// no-op AssetsMetadataClient for testing only
final class NoOpAssetsMetadataClient: AssetsMetadataClientProtocol {
    private let subscriptions: Mutex<[AsyncStream<[CBAssetMetadata]>.Continuation]> = .init([])

    func connect() async throws {
        // no-op
    }

    func subscribeToAssetsMetadata(
        for _: String,
        assetsUpdateHandler _: @Sendable ([CBAssetMetadata]) async throws -> Void
    ) async throws {
        let (idleStream, continuation) = AsyncStream<[CBAssetMetadata]>.makeStream()
        self.subscriptions.withLock {
            $0.append(continuation)
        }
        // There won't be any update in no-op implementation. The idle stream keeps the subscription
        // long running.
        for await _ in idleStream {}
    }

    deinit {
        self.subscriptions.withLock {
            for continuation in $0 {
                continuation.finish()
            }
        }
    }
}
