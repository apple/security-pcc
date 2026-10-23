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
//  TC2Daemon.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import AppleIntelligenceReporting
import CloudAttestation
import CloudTelemetry
import Foundation
import Foundation_Private.NSBackgroundActivityScheduler
import Foundation_Private.NSXPCConnection
import PrivateCloudCompute
import Synchronization
import os.log

private let logger = Logger(for: .daemon)

@available(iOS 18.0, *)
package final class TC2Daemon: NSObject, NSXPCListenerDelegate, TC2DaemonHostDelegate, Sendable {
    let systemInfo: SystemInfo
    let osEligibility: OSEligibility
    let deviceState = DeviceState()
    let serverDrivenConfig: ServerDrivenConfiguration
    let config = DefaultConfiguration()
    let prefetchActivity:
        PrefetchScheduledActivity<
            DeferredRateLimiter,
            LegacyAttestationStore,
            DeferredAttestationStore,
            AttestationVerifier<FeatureFlagChecker, CloudAttestation.MuxValidator>,
            ServerDrivenConfiguration,
            DefaultConfiguration,
            NWAsyncConnection,
            SystemInfo,
            FeatureFlagChecker,
            PrefetchTracker
        >
    let vaultConfigurationUpdater: VaultConfigurationUpdater<DeferredRateLimiter, DeviceQuotaConfigurationFetcherWrapper, DefaultConfiguration, FeatureFlagChecker, NotificationsProducer>
    let notificationsMonitor: NotificationsMonitor<VaultConfigurationUpdater<DeferredRateLimiter, DeviceQuotaConfigurationFetcherWrapper, DefaultConfiguration, FeatureFlagChecker, NotificationsProducer>>
    let updateServerDrivenConfigurationActivity: UpdateServerDrivenConfigScheduledActivity<ServerDrivenConfiguration, SystemInfo>
    let updateVaultConfigurationActivity: UpdateVaultConfigScheduledActivity<VaultConfigurationUpdater<DeferredRateLimiter, DeviceQuotaConfigurationFetcherWrapper, DefaultConfiguration, FeatureFlagChecker, NotificationsProducer>>
    let rateLimiter: DeferredRateLimiter
    let tokenProviderFactory: TokenProviderFactory<DefaultConfiguration, FeatureFlagChecker, ServerDrivenConfiguration, SystemInfo>
    let attestationStoreOrLegacyStore: AttestationStoreOrLegacyStore<LegacyAttestationStore, DeferredAttestationStore>
    let attestationVerifier: AttestationVerifier<FeatureFlagChecker, CloudAttestation.MuxValidator>
    let dailyActiveUserReporter: DailyActiveUsersReporter<UserDefaultsStore, SystemInfo>
    let featureUsageAnalyzerScheduledActivity: FeatureUsageAnalyzerScheduledActivity<SystemInfo, FeatureFlagChecker>
    let tapToRadarController = TapToRadarController()
    let componentTimeMeasurementReporter: ComponentTimeMeasurementReporter<AppleIntelligenceReporting.EventReporter>
    let nodeDistributionAnalyzer: NodeDistributionAnalyzer<SystemInfo>
    let featureUsageAnalyzer: FeatureUsageAnalyzer<FeatureUsageAnalyzerStoreHelper, SystemInfo>
    let nodeDistributionReportActivity: NodeDistributionReportScheduledActivity<SystemInfo>
    let preferencesStore = PreferencesStore()
    let featureFlagChecker = FeatureFlagChecker()
    let fetchServerDrivenConfigurationValve: OverflowValve<ContinuousClock> = OverflowValve(
        frequency: .hours(12),
        clock: ContinuousClock()
    )
    let expiredBuildNotification: ExpiredBuildNotification<SystemUserNotification, PreferencesStore>

    let (thimbledEventStream, thimbledEventContinuation) = AsyncStream.makeStream(of: ThimbledEvent.self)

    var scheduledPrefetchTask: ScheduledTask<PreferencesStore, OSEligibility> {
        .init(
            preregisteredIdentifier: "com.apple.privatecloudcompute.prefetchAttestations",
            work: prefetchActivity,
            store: preferencesStore,
            osEligibility: osEligibility
        )
    }

    var scheduledFeatureUsageAnalyzerTask: ScheduledTask<PreferencesStore, OSEligibility> {
        .init(
            preregisteredIdentifier: "com.apple.privatecloudcompute.featureUsageAnalyzer",
            work: featureUsageAnalyzerScheduledActivity,
            store: preferencesStore,
            osEligibility: osEligibility
        )
    }

    var scheduledFetchConfigBagTask: ScheduledTask<PreferencesStore, OSEligibility> {
        .init(
            preregisteredIdentifier: "com.apple.privatecloudcompute.fetchServerDrivenConfig",
            work: updateServerDrivenConfigurationActivity,
            store: preferencesStore,
            osEligibility: osEligibility
        )
    }

    var scheduledFetchVaultConfigTask: ScheduledTask<PreferencesStore, OSEligibility> {
        .init(
            preregisteredIdentifier: "com.apple.privatecloudcompute.fetchVaultConfig",
            work: updateVaultConfigurationActivity,
            store: preferencesStore,
            osEligibility: osEligibility
        )
    }

    var scheduledNodeDistributionReportTask: ScheduledTask<PreferencesStore, OSEligibility> {
        .init(
            preregisteredIdentifier: "com.apple.privatecloudcompute.nodeDistributionReport",
            work: nodeDistributionReportActivity,
            store: preferencesStore,
            osEligibility: osEligibility
        )
    }

    var prefetchRequestHandler: PrefetchRequestHandler<PrefetchTracker, DeferredRateLimiter, LegacyAttestationStore, DeferredAttestationStore, DefaultConfiguration, ServerDrivenConfiguration, SystemInfo, FeatureFlagChecker> {
        PrefetchRequestHandler(
            prefetchTracker: self.prefetchTracker,
            rateLimiter: self.rateLimiter,
            attestationStoreOrLegacyStore: self.attestationStoreOrLegacyStore,
            attestationVerifier: self.attestationVerifier,
            config: self.config,
            serverDrivenConfig: self.serverDrivenConfig,
            systemInfo: self.systemInfo,
            featureFlagChecker: self.featureFlagChecker,
            eventStreamContinuation: self.thimbledEventContinuation
        )
    }

    let structuredRequestFactoriesBySetup: Mutex<[TC2ResolvedSetup: ThimbledTrustedRequestFactory]> = Mutex([:])

    let prefetchTracker = PrefetchTracker()

    let bundleIDProvider: any BundleIDProviderProtocol

    package init(dataContainerUrl: URL) {
        self.systemInfo = SystemInfo(featureFlagChecker: self.featureFlagChecker)
        self.osEligibility = OSEligibility()
        let environment = self.config.environment(systemInfo: self.systemInfo)

        let daemonDirectoryPath = getDaemonDirectoryPath(
            dataContainerUrl: dataContainerUrl,
            environment: environment
        )

        clearDefaultsIfBuildChanged(systemInfo: self.systemInfo, store: self.preferencesStore)

        if self.featureFlagChecker.isEnabled(.secTaskBundleIDResolution) {
            self.bundleIDProvider = SecTaskBundleIDProvider()
        } else {
            self.bundleIDProvider = LegacyBundleIDProvider()
        }

        self.rateLimiter = DeferredRateLimiter(config: self.config, from: daemonDirectoryPath)
        if self.featureFlagChecker.isEnabled(.attestationStoreV3) {
            let attestationStore = DeferredAttestationStore(dir: daemonDirectoryPath)
            self.attestationStoreOrLegacyStore = .attestationStore(attestationStore)
        } else {
            let legacyAttestationStore = LegacyAttestationStore(dir: daemonDirectoryPath)
            self.attestationStoreOrLegacyStore = .legacyStore(legacyAttestationStore)
        }
        self.serverDrivenConfig = ServerDrivenConfiguration(from: daemonDirectoryPath)
        self.attestationVerifier = AttestationVerifier(
            environment: environment,
            featureFlagChecker: self.featureFlagChecker,
            validator: cloudAttestationValidator(for: environment)
        )
        self.tokenProviderFactory = TokenProviderFactory(
            configuration: self.config,
            featureFlagChecker: self.featureFlagChecker,
            serverDrivenConfig: self.serverDrivenConfig,
            systemInfo: self.systemInfo
        )
        self.dailyActiveUserReporter = DailyActiveUsersReporter<UserDefaultsStore, SystemInfo>(systemInfo: self.systemInfo)
        self.prefetchActivity = PrefetchScheduledActivity(
            rateLimiter: self.rateLimiter,
            attestationStoreOrLegacyStore: self.attestationStoreOrLegacyStore,
            attestationVerifier: self.attestationVerifier,
            config: self.config,
            daemonDirectoryPath: daemonDirectoryPath,
            serverDrivenConfig: self.serverDrivenConfig,
            systemInfo: self.systemInfo,
            featureFlagChecker: self.featureFlagChecker,
            connectionFactory: NWAsyncConnection(),
            eventStreamContinuation: self.thimbledEventContinuation,
            prefetchTracker: self.prefetchTracker
        )
        self.vaultConfigurationUpdater = VaultConfigurationUpdater(
            rateLimiter: self.rateLimiter,
            fetcher: DeviceQuotaConfigurationFetcherWrapper(),
            configuration: self.config,
            featureFlagChecker: self.featureFlagChecker,
            notificationsProducer: NotificationsProducer()
        )
        self.notificationsMonitor = NotificationsMonitor(
            vaultConfigurationUpdater: self.vaultConfigurationUpdater,
            osEligibility: self.osEligibility
        )

        self.updateServerDrivenConfigurationActivity = UpdateServerDrivenConfigScheduledActivity(
            serverDrivenConfig: self.serverDrivenConfig,
            systemInfo: systemInfo,
            config: self.config
        )
        self.updateVaultConfigurationActivity = UpdateVaultConfigScheduledActivity(updater: self.vaultConfigurationUpdater)
        self.nodeDistributionAnalyzer = NodeDistributionAnalyzer(
            environment: environment.name,
            storeURL: daemonDirectoryPath,
            systemInfo: self.systemInfo
        )
        self.nodeDistributionReportActivity = NodeDistributionReportScheduledActivity(
            eventStreamContinuation: self.thimbledEventContinuation,
            nodeDistributionAnalyzer: self.nodeDistributionAnalyzer
        )
        self.featureUsageAnalyzer = FeatureUsageAnalyzer(
            storeHelper: FeatureUsageAnalyzerStoreHelper(storeURL: daemonDirectoryPath),
            environment: environment.name,
            systemInfo: self.systemInfo
        )
        self.featureUsageAnalyzerScheduledActivity = FeatureUsageAnalyzerScheduledActivity(
            eventStreamContinuation: self.thimbledEventContinuation,
            featureUsageAnalyzer: self.featureUsageAnalyzer,
            featureFlagChecker: self.featureFlagChecker,
        )
        self.expiredBuildNotification = ExpiredBuildNotification(
            displayInterval: config[.expiredBuildNotificationDisplayInterval],
            store: self.preferencesStore,
        )

        let eventReporter: AppleIntelligenceReporting.EventReporter?
        do {
            eventReporter = try AppleIntelligenceReporting.EventReporter()
        } catch {
            logger.error("Failed to initialize ComponentTimeMeasurementReporter: \(error)")
            eventReporter = nil
        }
        self.componentTimeMeasurementReporter = ComponentTimeMeasurementReporter(eventReporter: eventReporter)

        super.init()
        logger.log("Starting daemon. tc2OSInfo: \(self.systemInfo.osInfo)")
    }

    func structuredRequestFactory(
        forSetup setup: TC2ResolvedSetup,
        requestParameters: RequestParameters
    ) -> ThimbledTrustedRequestFactory {
        self.structuredRequestFactoriesBySetup.withLock { factories in
            if let factory = factories[setup] {
                return factory
            } else {
                let factory = ThimbledTrustedRequestFactory(
                    config: self.config,
                    serverDrivenConfig: self.serverDrivenConfig,
                    systemInfo: self.systemInfo,
                    osEligibility: self.osEligibility,
                    deviceState: self.deviceState,
                    connectionFactory: NWAsyncConnection(),
                    attestationStoreOrLegacyStore: self.attestationStoreOrLegacyStore,
                    attestationVerifier: self.attestationVerifier,
                    rateLimiter: self.rateLimiter,
                    tokenProviderFactory: self.tokenProviderFactory,
                    clock: ContinuousClock(),
                    clientBundleIdentifier: setup.clientBundleIdentifier,
                    parametersCache: self.prefetchActivity.parametersCache,
                    eventStreamContinuation: self.thimbledEventContinuation,
                    featureFlagChecker: self.featureFlagChecker,
                )
                factories[setup] = factory
                return factory
            }
        }
    }

    func warmAttestationStore() async {
        if case .attestationStore(let attestationStore) = self.attestationStoreOrLegacyStore {
            await attestationStore.warm()
        }
    }

    package func main() async {
        do {
            logger.log("Setting up CloudTelemetry xpc service activities.")
            try await CloudTelemetry.setupXpcServiceActivities()
        } catch {
            logger.log("Failed to setup CloudTelemetry")
        }

        DispatchQueue.global().async {
            let listener = NSXPCListener(machServiceName: "com.apple.privatecloudcompute")
            listener.delegate = self

            logger.log("Listener start")
            listener.resume()
            logger.log("Listener done")

            logger.log("Register prefetch task")
            self.scheduledPrefetchTask.register()

            logger.log("Register feature usage analyzer task")
            self.scheduledFeatureUsageAnalyzerTask.register()

            logger.log("Register fetch config bag task")
            self.scheduledFetchConfigBagTask.register()

            logger.log("Register update request tokens rate limits task")
            self.scheduledFetchVaultConfigTask.register()

            logger.log("Register node distribution report task")
            self.scheduledNodeDistributionReportTask.register()
        }

        logger.log("Starting daemon run loop...")

        await self.runEventStreamLoop()
    }

    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    package func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        logger.log("Thimble trying to connect: checking entitlements")

        let hasEntitlement = PrivateCloudComputeEntitlement.allCases.contains { entitlement in
            return newConnection.value(forEntitlement: entitlement.rawValue) as? Bool == true
        }
        guard hasEntitlement else {
            logger.log("Rejecting connection because it doesn't have any of the required entitlements: \(String(describing: PrivateCloudComputeEntitlement.allCases))")
            return false
        }

        // set up the new connection with an exported ThimbleDaemonHandler

        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = interfaceForTC2DaemonProtocol()

        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = TC2DaemonHost(config: self.config, systemInfo: self.systemInfo, bundleIDProvider: self.bundleIDProvider, delegate: self, connection: newConnection, deviceState: self.deviceState)
        newConnection.exportedObject = exportedObject

        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()
        logger.log("Resumed")
        newConnection.invalidationHandler = { [weak exportedObject] in
            if let exportedObject = exportedObject {
                exportedObject.invalidationHandler()
            }
        }
        newConnection.interruptionHandler = { [weak exportedObject] in
            if let exportedObject = exportedObject {
                exportedObject.interruptionHandler()
            }
        }

        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }

    func prefetchAttestationsAsResponseToExpiredAttestationList(
        _ expiredAttestationList: Proto_Ropes_HttpService_InvokeResponse.ExpiredAttestationList,
        parameters: Workload
    ) async {
        do {
            if expiredAttestationList.shouldClearCache {
                // The prefetch request will take care of clearing out the store of older attestations for this workload
                logger.log("creating a prefetch request as response to expired attestations")

                try await self.prefetchTracker.ensuringOnlyASinglePrefetchIsRunningForParameters(parameters) {
                    let prefetchRequest: any PrefetchProtocol
                    switch attestationStoreOrLegacyStore {
                    case .legacyStore(let legacyAttestationStore):
                        prefetchRequest = BatchedPrefetch(
                            connectionFactory: NWAsyncConnection(),
                            attestationStore: legacyAttestationStore,
                            rateLimiter: self.rateLimiter,
                            attestationVerifier: self.attestationVerifier,
                            config: self.config,
                            serverDrivenConfig: self.serverDrivenConfig,
                            systemInfo: systemInfo,
                            featureFlagChecker: self.featureFlagChecker,
                            parameters: parameters,
                            eventStreamContinuation: self.thimbledEventContinuation,
                            prewarm: false,
                            fetchType: .fetchAllBatches
                        )
                    case .attestationStore(let attestationStore):
                        prefetchRequest = AttestationStorePrefetch(
                            connectionFactory: NWAsyncConnection(),
                            attestationStore: attestationStore,
                            rateLimiter: self.rateLimiter,
                            attestationVerifier: self.attestationVerifier,
                            config: self.config,
                            serverDrivenConfig: self.serverDrivenConfig,
                            systemInfo: systemInfo,
                            featureFlagChecker: self.featureFlagChecker,
                            parameters: parameters,
                            eventStreamContinuation: self.thimbledEventContinuation,
                            prewarm: false
                        )
                    }

                    logger.log("firing prefetch request as response to expired attestations")
                    _ = try await prefetchRequest.sendRequest()
                }
            } else {
                for nodeIdentifier in expiredAttestationList.nodeIdentifier {
                    switch attestationStoreOrLegacyStore {
                    case .legacyStore(let legacyAttestationStore):
                        _ = await legacyAttestationStore.deleteEntryForNode(nodeIdentifier: nodeIdentifier)
                    case .attestationStore(let attestationStore):
                        _ = await attestationStore.deleteEntryForNode(nodeID: nodeIdentifier)
                    }
                }
            }
        } catch {
            logger.log("failed prefetch request as response to expired attestations. error: \(error)")
        }
    }
}
