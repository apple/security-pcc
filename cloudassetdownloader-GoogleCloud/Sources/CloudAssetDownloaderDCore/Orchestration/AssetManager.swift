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

import CloudAssetDownloaderAPI
import Foundation
import Logging
import ServiceLifecycle
import Synchronization

final class AssetManager: Sendable, Service {
    private static let logger = Logger.forType(AssetManager.self)

    private let assetConfigRegistry: AssetConfigRegistry
    private let assetDownloader: AssetDownloader
    private let apiServer: CloudAssetDownloaderAPIServer
    private let purgeInterval: Duration

    private let actionStream: AsyncStream<AssetManagerAction>
    private let actionPublisher: AsyncStream<AssetManagerAction>.Continuation
    private let stateMachine: Mutex<AssetManagerStateMachine>

    init(
        assetConfigRegistry: AssetConfigRegistry,
        assetDownloader: AssetDownloader,
        apiServer: CloudAssetDownloaderAPIServer,
        purgeInterval: Duration = .seconds(300)
    ) {
        self.assetConfigRegistry = assetConfigRegistry
        self.assetDownloader = assetDownloader
        self.apiServer = apiServer
        self.purgeInterval = purgeInterval
        (self.actionStream, self.actionPublisher) = AsyncStream<AssetManagerAction>.makeStream()
        self.stateMachine = .init(.init(actionPublisher: self.actionPublisher))
    }

    func run() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                await self.watchActiveAssetConfigs()
                return "watchActiveAssetConfigs"
            }
            group.addTask {
                await self.watchActions()
                return "watchActions"
            }
            group.addTask {
                await self.purgeStaleAssets()
                return "purgeStaleAssets"
            }
            let taskName = try await group.next() ?? "nil"
            Self.logger.info("Task exited. Cancelling other tasks...", metadata: ["taskName": "\(taskName)"])
            group.cancelAll()
        }
    }

    private func watchActiveAssetConfigs() async {
        await self.assetConfigRegistry.watchActiveAssetConfigs { activeAssetConfigs in
            // TODO: de-dup
            Self.logger.info("Received active asset configs", metadata: ["activeAssetConfigs": "\(activeAssetConfigs)"])
            self.onEvent(.assetConfigsReceived(activeAssetConfigs))
        }
    }

    private func watchActions() async {
        await withDiscardingTaskGroup { group in
            for await action in self.actionStream {
                group.addTask {
                    await self.performAction(action)
                }
            }
        }
    }

    private func performAction(_ action: AssetManagerAction) async {
        Self.logger.info("New action", metadata: ["action": "\(action)"])
        switch action {
        case let .downloadAsset(assetConfig):
            await self.downloadAsset(assetConfig)
        case let .notifyConsumer(consumerID, assetConfigs):
            await self.notifyConsumer(consumerID: consumerID, assetConfigs: assetConfigs)
        case let .reportAssetConfigsApplied(assetConfigs):
            self.assetConfigRegistry.reportAssetConfigsApplied(assetConfigs)
        case let .reportAssetConfigFailedToApply(assetConfigs, error):
            self.assetConfigRegistry.reportAssetConfigsFailedToApply(assetConfigs, error: error)
        }
    }

    private func downloadAsset(_ assetConfig: AssetConfig) async {
        CADMetrics.recordDownloadAttempt(assetConfig: assetConfig)
        self.onEvent(.assetDownloadStarted(assetConfig))
        let startTime = ContinuousClock.now
        do {
            try await self.assetDownloader.download(assetConfig)
            let duration = ContinuousClock.now - startTime
            CADMetrics.recordDownloadSuccess(assetConfig: assetConfig, duration: duration)
            self.onEvent(.assetDownloadSucceeded(assetConfig))
        } catch {
            CADMetrics.recordDownloadFailure(assetConfig: assetConfig, error: error)
            self.onEvent(.assetDownloadFailed(assetConfig, error: error))
        }
    }

    private func notifyConsumer(consumerID: ConsumerID, assetConfigs: Set<AssetConfig>) async {
        let assets = assetConfigs.map {
            AssetMetadata(id: $0.assetID, version: $0.version, location: $0.destination)
        }
        await self.apiServer.onAssetBundleUpdate(consumerID: consumerID, assets: Set(assets))
        CADMetrics.recordNotificationSent(consumerID: consumerID, assetCount: assets.count)
        self.onEvent(.consumerNotified(consumerID, assetConfigs.uids))
    }

    private func onEvent(_ event: AssetEvent) {
        self.stateMachine.withLock { $0.onEvent(event) }
    }

    private func purgeStaleAssets() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: self.purgeInterval)
            } catch {
                Self.logger.info("purgeStaleAssets task cancelled")
                break
            }
            let purgeable = self.stateMachine.withLock { $0.getPurgeableAssets() }
            if purgeable.isEmpty { continue }

            var purged = Set<AssetConfig>()
            for assetConfig in purgeable {
                let path = assetConfig.destination.string
                if !FileManager.default.fileExists(atPath: path) {
                    Self.logger.info(
                        "Asset does not exist in file system",
                        metadata: ["assetConfig": "\(assetConfig)"]
                    )
                    purged.insert(assetConfig)
                    continue
                }
                do {
                    try FileManager.default.removeItem(atPath: path)
                    Self.logger.info("Removed asset from file system", metadata: ["assetConfig": "\(assetConfig)"])
                    CADMetrics.recordAssetPurged()
                    purged.insert(assetConfig)
                } catch {
                    Self.logger.error(
                        "Failed to remove asset from file system, will retry",
                        metadata: [
                            "assetConfig": "\(assetConfig)",
                            "error": "\(error)",
                        ]
                    )
                    CADMetrics.recordAssetPurgeFailure(error: error)
                }
            }
            if !purged.isEmpty {
                self.stateMachine.withLock { $0.removeAssets(purged) }
            }
        }
    }

    deinit {
        self.actionPublisher.finish()
    }
}

extension AssetManager: CloudAssetDownloaderAPIServerDelegate {
    func onAssetBundleConsumptionResult(
        _ result: Result<Void, any Error>,
        consumerID: ConsumerID,
        assetUIDs: Set<AssetUID>
    ) {
        switch result {
        case .success:
            CADMetrics.recordConsumptionSuccess(consumerID: consumerID)
            self.onEvent(.assetBundleConsumed(consumerID, assetUIDs))
        case let .failure(error):
            CADMetrics.recordConsumptionFailure(consumerID: consumerID)
            self.onEvent(.assetBundleFailedToConsume(consumerID, assetUIDs, error: error))
        }
    }
}
