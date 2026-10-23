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
import Logging

struct AssetManagerStateMachine {
    private static let logger = Logger.forType(AssetManagerStateMachine.self)

    private let actionPublisher: AssetManagerActionPublisher
    // tracks the download and consumption state of ACTIVE asset bundles
    private var assetBundleStateMachines: [ConsumerID: AssetBundleStateMachine]
    // tracks the state of ALL assets
    private var assetStateMachines: [AssetConfig: AssetStateMachine]
    // tracks the state of applying the current active asset configs
    private var assetConfigsStateMachine: AssetConfigsStateMachine

    init(actionPublisher: AssetManagerActionPublisher) {
        // TODO: handle recover on restart: current active asset, downloaded assets
        self.assetStateMachines = [:]
        self.assetBundleStateMachines = [:]
        self.assetConfigsStateMachine = .init(assetConfigs: [:], actionPublisher: actionPublisher)
        self.actionPublisher = actionPublisher
    }

    mutating func onEvent(_ event: AssetEvent) {
        Self.logger.info("New event", metadata: ["event": "\(event)"])
        switch event {
        case let .assetConfigsReceived(assetConfigs):
            self.onAssetConfigsReceived(assetConfigs)
        case let .assetDownloadStarted(assetConfig):
            self.assetDownloadStarted(assetConfig: assetConfig)
        case let .assetDownloadSucceeded(assetConfig):
            self.onAssetDownloadResult(.success(()), assetConfig: assetConfig)
        case let .assetDownloadFailed(assetConfig, error):
            self.onAssetDownloadResult(.failure(error), assetConfig: assetConfig)
        case let .consumerNotified(consumerID, assetUIDs):
            self.onConsumerNotified(consumerID, assetUIDs: assetUIDs)
        case let .assetBundleConsumed(consumerID, assetUIDs):
            self.onAssetBundleConsumptionResult(.success(()), consumerID: consumerID, assetUIDs: assetUIDs)
        case let .assetBundleFailedToConsume(consumerID, assetUIDs, error):
            self.onAssetBundleConsumptionResult(.failure(error), consumerID: consumerID, assetUIDs: assetUIDs)
        }
    }

    private mutating func onAssetConfigsReceived(_ assetConfigs: [ConsumerID: Set<AssetConfig>]) {
        if self.assetConfigsStateMachine.assetConfigs != assetConfigs {
            Self.logger.info("Received new active asset configs", metadata: ["assetConfigs": "\(assetConfigs)"])
            self.assetConfigsStateMachine = .init(assetConfigs: assetConfigs, actionPublisher: self.actionPublisher)
            self.examineAssetBundleStatesForNewAssetConfigs()
        } else {
            Self.logger.info("Received identical active asset configs", metadata: ["assetConfigs": "\(assetConfigs)"])
            // if we are already in a state to report result, do so
            switch self.assetConfigsStateMachine.state {
            case .applied:
                self.actionPublisher.publish(.reportAssetConfigsApplied(assetConfigs))
            case let .failedToApply(error):
                self.actionPublisher.publish(.reportAssetConfigFailedToApply(assetConfigs, error: error))
            case .applying:
                // in progress
                ()
            }
        }
    }

    private mutating func examineAssetBundleStatesForNewAssetConfigs() {
        for (consumerID, assetConfigsForConsumer) in self.assetConfigsStateMachine.assetConfigs {
            if self.assetBundleStateMachines[consumerID]?.assetConfigs == assetConfigsForConsumer {
                Self.logger.info(
                    "Received identical asset configs for consumer",
                    metadata: [
                        "consumerID": "\(consumerID)",
                        "assetConfigs": "\(assetConfigsForConsumer)",
                    ]
                )
            } else {
                Self.logger.info(
                    "Received new asset configs for consumer",
                    metadata: [
                        "consumerID": "\(consumerID)",
                        "assetConfigs": "\(assetConfigsForConsumer)",
                    ]
                )
                let consumedAssets: Set<AssetConfig> =
                    if let oldAssetBundle = self.assetBundleStateMachines[consumerID] {
                        oldAssetBundle.consumedAssetConfigs
                    } else {
                        []
                    }
                let newAssetBundleStateMachine = AssetBundleStateMachine(
                    consumerID: consumerID,
                    assetConfigs: assetConfigsForConsumer,
                    consumedAssetConfigs: consumedAssets,
                    actionPublisher: self.actionPublisher
                )
                self.assetBundleStateMachines[consumerID] = newAssetBundleStateMachine
                self.examineAssetStatesForNewAssetBundle(newAssetBundleStateMachine)
            }
        }

        // remove asset bundles that are no longer active
        for consumerID in self.assetBundleStateMachines.keys
        where !self.assetConfigsStateMachine.assetConfigs.keys.contains(consumerID) {
            Self.logger.info("Removing state for inactive consumer", metadata: ["consumerID": "\(consumerID)"])
            self.assetBundleStateMachines[consumerID] = nil
        }

        // examine if we already know the result of applying the new asset configs
        var consumedAssetBundles = 0
        loop: for assetBundleStateMachine in self.assetBundleStateMachines.values {
            switch assetBundleStateMachine.state {
            case .consumed:
                consumedAssetBundles += 1
                if consumedAssetBundles == self.assetBundleStateMachines.count {
                    self.assetConfigsStateMachine.onAllAssetBundlesConsumptionSuccess()
                    break loop
                }
            case let .consumptionFailed(error):
                self.assetConfigsStateMachine.onAssetBundleConsumptionFailed(error: error)
                break loop
            case .downloading, .downloaded, .notifiedConsumer:
                ()
            }
        }
    }

    private mutating func examineAssetStatesForNewAssetBundle(_ assetBundleStateMachine: AssetBundleStateMachine) {
        var downloadedAssets = 0
        for assetConfig in assetBundleStateMachine.assetConfigs {
            if let assetStateMachine = self.assetStateMachines[assetConfig] {
                switch assetStateMachine.state {
                case .downloadSucceeded:
                    downloadedAssets += 1
                    if downloadedAssets == assetBundleStateMachine.assetConfigs.count {
                        assetBundleStateMachine.onAssetBundleDownloaded()
                    }
                case let .downloadFailed(error):
                    self.assetConfigsStateMachine.onAssetDownloadFailed(error: error)
                case .downloadPending, .downloading:
                    ()
                }
            } else {
                Self.logger.info("Received new asset config", metadata: ["assetConfig": "\(assetConfig)"])
                self.assetStateMachines[assetConfig] = .init(
                    assetConfig: assetConfig,
                    actionPublisher: self.actionPublisher
                )
                self.actionPublisher.publish(.downloadAsset(assetConfig))
            }
        }
    }

    private mutating func assetDownloadStarted(assetConfig: AssetConfig) {
        guard let assetStateMachine = self.assetStateMachines[assetConfig] else {
            fatalError("No state machine for asset config \(assetConfig)")
        }
        assetStateMachine.onAssetDownloadStarted()
    }

    private mutating func onAssetDownloadResult(_ result: Result<Void, Error>, assetConfig: AssetConfig) {
        guard let assetStateMachine = self.assetStateMachines[assetConfig] else {
            fatalError("No state machine for asset config \(assetConfig)")
        }
        assetStateMachine.onAssetDownloadResult(result)

        let consumerID = assetConfig.consumerID
        guard let assetBundleStateMachine = self.assetBundleStateMachines[consumerID],
            assetBundleStateMachine.assetConfigs.contains(assetConfig)
        else {
            Self.logger.warning("Asset is not active", metadata: ["assetConfig": "\(assetConfig)"])
            return
        }

        switch result {
        case .success:
            let assetConfigs = assetBundleStateMachine.assetConfigs
            var downloadedAssets = 0
            for assetConfig in assetConfigs {
                if case .downloadSucceeded = self.assetStateMachines[assetConfig]?.state {
                    downloadedAssets += 1
                }
            }
            Self.logger.info(
                "Asset downloaded",
                metadata: [
                    "downloadedAssets": "\(downloadedAssets)",
                    "totalAssets": "\(assetConfigs.count)",
                    "consumerID": "\(consumerID)",
                ]
            )
            if downloadedAssets == assetConfigs.count {
                assetBundleStateMachine.onAssetBundleDownloaded()
            }
        case let .failure(error):
            self.assetConfigsStateMachine.onAssetDownloadFailed(error: error)
        }
    }

    private mutating func onConsumerNotified(_ consumerID: ConsumerID, assetUIDs: Set<AssetUID>) {
        guard let assetBundleStateMachine = self.assetBundleStateMachines[consumerID] else {
            Self.logger.warning(
                "Consumer does not have any active asset. Ignoring notification",
                metadata: ["consumerID": "\(consumerID)"]
            )
            return
        }
        assetBundleStateMachine.onConsumerNotified(assetUIDs: assetUIDs)
    }

    private mutating func onAssetBundleConsumptionResult(
        _ result: Result<Void, Error>,
        consumerID: ConsumerID,
        assetUIDs: Set<AssetUID>
    ) {
        guard let assetBundleStateMachine = self.assetBundleStateMachines[consumerID] else {
            Self.logger.warning(
                "Consumer does not have any active asset. Ignoring consumption result",
                metadata: ["consumerID": "\(consumerID)"]
            )
            return
        }
        assetBundleStateMachine.onAssetBundleConsumptionResult(result, assetUIDs: assetUIDs)

        switch result {
        case .success:
            var consumedAssetBundles = 0
            for assetBundleStateMachine in self.assetBundleStateMachines.values {
                if case .consumed = assetBundleStateMachine.state {
                    consumedAssetBundles += 1
                }
            }
            Self.logger.info(
                "Asset bundle consumed",
                metadata: [
                    "consumedAssetBundles": "\(consumedAssetBundles)",
                    "totalAssetBundles": "\(self.assetBundleStateMachines.count)",
                ]
            )
            if consumedAssetBundles == self.assetBundleStateMachines.count {
                self.assetConfigsStateMachine.onAllAssetBundlesConsumptionSuccess()
            }
        case let .failure(error):
            self.assetConfigsStateMachine.onAssetBundleConsumptionFailed(error: error)
        }
    }

    /// Returns assets that are safe to purge.
    /// An asset is purgeable when it meets ALL following conditions:
    /// - not in the active configs
    /// - not currently consumed
    /// - not being downloaded
    func getPurgeableAssets() -> Set<AssetConfig> {
        let activeAssets = Set(self.assetConfigsStateMachine.assetConfigs.values.flatMap(\.self))
        var protectedAssets = activeAssets
        for assetBundleStateMachine in self.assetBundleStateMachines.values {
            protectedAssets.formUnion(assetBundleStateMachine.consumedAssetConfigs)
        }

        var purgeable = Set<AssetConfig>()
        for (assetConfig, assetStateMachine) in self.assetStateMachines {
            if protectedAssets.contains(assetConfig) { continue }
            switch assetStateMachine.state {
            case .downloadFailed:
                purgeable.insert(assetConfig)
            case .downloadSucceeded:
                purgeable.insert(assetConfig)
            case .downloadPending, .downloading:
                ()
            }
        }
        return purgeable
    }

    /// Removes asset state machines for assets that have been cleaned up.
    mutating func removeAssets(_ assets: Set<AssetConfig>) {
        for asset in assets {
            self.assetStateMachines[asset] = nil
            Self.logger.info("Removed asset from state machine", metadata: ["assetConfig": "\(asset)"])
        }
    }
}

extension AssetConfig {
    var uid: AssetUID {
        .init(consumerID: consumerID, assetID: assetID, version: version)
    }
}

extension Set<AssetConfig> {
    var uids: Set<AssetUID> {
        Set<AssetUID>(self.map(\.uid))
    }
}
