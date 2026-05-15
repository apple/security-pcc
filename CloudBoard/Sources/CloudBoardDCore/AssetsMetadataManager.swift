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

import CloudBoardCommon
import CloudBoardDomain
import CloudBoardPlatformUtilities
import os
import Synchronization
import System

// Manages metadata of assets that are used by job helper and the cloud app.
// On assets update, it's also responsible for making sure all prewarmed instances
// are restarted to use the new assets.
actor AssetsMetadataManager {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "AssetsMetadataManager"
    )

    enum AssetsState: Equatable {
        case unavailable
        case available([AssetMetadata])
    }

    private let assetsConsumerIDs: [AssetConsumer: String]
    private let assetsMetadataClient: any AssetsMetadataClientProtocol
    private let jobHelperInstanceProvider: JobHelperInstanceProvider?
    // exposed for testing only
    let serviceHealthMonitor: ServiceHealthMonitor

    // Tracks the state of each consumer's assets
    private var assetsStates: [AssetConsumer: AssetsState]

    init(
        assetsConsumerIDs: [AssetConsumer: String],
        assetsMetadataClient: any AssetsMetadataClientProtocol,
        serviceHealthMonitor: ServiceHealthMonitor,
        jobHelperInstanceProvider: JobHelperInstanceProvider?
    ) {
        self.assetsConsumerIDs = assetsConsumerIDs
        self.assetsMetadataClient = assetsMetadataClient
        self.serviceHealthMonitor = serviceHealthMonitor
        self.jobHelperInstanceProvider = jobHelperInstanceProvider
        self.assetsStates = [:]
        for assetConsumer in assetsConsumerIDs.keys {
            self.assetsStates[assetConsumer] = .unavailable
        }
    }

    func run() async throws {
        if self.assetsStates.isEmpty {
            self.jobHelperInstanceProvider?.updateAssetsMetadata([:], isInitial: true)
            Self.logger.log("No asset dependency. Sleep indefinitely...")
            return try await self.sleepIndefinitely()
        }

        try await self.assetsMetadataClient.connect()

        try await withThrowingTaskGroup(of: String.self) { group in
            for (assetConsumer, assetConsumerID) in self.assetsConsumerIDs {
                Self.logger.log("Subscribing to assets update for \(assetConsumerID)")
                group.addTask {
                    try await self.assetsMetadataClient.subscribeToAssetsMetadata(
                        for: assetConsumerID
                    ) { assetsMetadata in
                        try await self.onAssetsUpdate(assetConsumer: assetConsumer, assetsMetadata: assetsMetadata)
                    }
                    return "AssetsMetadataSubscription for \(assetConsumerID)"
                }
            }
            let taskName = try await group.next() ?? "nil"
            Self.logger.log("\(taskName) exited. Cancelling other tasks...")
            group.cancelAll()
        }
    }

    // exposed for testing only
    func getAssetsState(for assetConsumer: AssetConsumer) -> AssetsState? {
        return self.assetsStates[assetConsumer]
    }

    private func sleepIndefinitely() async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(60))
        }
    }

    private func onAssetsUpdate(assetConsumer: AssetConsumer, assetsMetadata: [AssetMetadata]) async throws {
        switch self.assetsStates[assetConsumer] {
        case .unavailable:
            Self.logger.log("""
            Received initial assets metadata. \
            AssetConsumer=\(assetConsumer, privacy: .public) \
            AssetsMetadata=\(assetsMetadata, privacy: .public)
            """)
            self.assetsStates[assetConsumer] = .available(assetsMetadata)
            self.onInitialAssetsReceived()
        case .available(let oldAssetsMetadata):
            if Set(oldAssetsMetadata) == Set(assetsMetadata) {
                Self.logger.log("""
                Ignore received assets metadata because it's identical to the current one. \
                AssetConsumer=\(assetConsumer, privacy: .public) \
                AssetsMetadata=\(assetsMetadata, privacy: .public)
                """)
                return
            }
            Self.logger.log("""
            Received newer assets metadata. \
            AssetConsumer=\(assetConsumer, privacy: .public) \
            NewAssetsMetadata=\(assetsMetadata, privacy: .public) \
            OldAssetsMetadata=\(oldAssetsMetadata, privacy: .public)
            """)
            self.assetsStates[assetConsumer] = .available(assetsMetadata)
            try await self.onNewerAssetsReceived()
        case .none:
            Self.logger.error("Assets state doesn't exist for \(assetConsumer, privacy: .public)")
        }
    }

    private func onInitialAssetsReceived() {
        let allAssetsMetadata = self.getAllAssetsMetadata()
        if allAssetsMetadata.count < self.assetsStates.count {
            // missing initial assets for at least one consumer
            return
        }
        Self.logger.log("""
        Initial assets for all consumers received. \
        AssetsMetadata=\(allAssetsMetadata, privacy: .public)
        """)
        self.jobHelperInstanceProvider?.updateAssetsMetadata(allAssetsMetadata, isInitial: true)
    }

    private func onNewerAssetsReceived() async throws {
        let allAssetsMetadata = self.getAllAssetsMetadata()
        if allAssetsMetadata.count < self.assetsStates.count {
            // missing initial assets for at least one consumer
            return
        }

        guard let jobHelperInstanceProvider = self.jobHelperInstanceProvider else {
            return
        }

        // Newer assets received after all initial assets were received. Need to restart all
        // prewarmed instances that are using old assets.
        Self.logger.log("Entering maintenance before restarting job helper instances...")
        self.serviceHealthMonitor.enterMaintenance(.restartingJobHelpers)
        jobHelperInstanceProvider.updateAssetsMetadata(allAssetsMetadata, isInitial: false)
        // CloudBoard will not be in a functional state in situations where this throws. So staying
        // in maintenance mode is desired.
        try await jobHelperInstanceProvider.restartPrewarmedInstances()
        Self.logger.log("Exiting maintenance after restarting job helper instances...")
        self.serviceHealthMonitor.exitMaintenance(.restartingJobHelpers)
    }

    private func getAllAssetsMetadata() -> [AssetConsumer: [AssetMetadata]] {
        var allAssetsMetadata: [AssetConsumer: [AssetMetadata]] = [:]
        for (assetConsumer, assetsState) in self.assetsStates {
            switch assetsState {
            case .available(let assetsMetadata):
                allAssetsMetadata[assetConsumer] = assetsMetadata
            case .unavailable:
                ()
            }
        }
        return allAssetsMetadata
    }
}
