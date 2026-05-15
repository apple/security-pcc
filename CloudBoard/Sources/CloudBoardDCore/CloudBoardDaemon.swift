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

import CFPreferenceCoder
#if canImport(CloudAssetDownloaderFramework)
import CloudAssetDownloaderFramework
#endif
import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardIdentity
import CloudBoardJobAuthDAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import Foundation
import InternalGRPC
import Logging
import NIOCore
import NIOTLS
import NIOTransportServices
import os
import Security
import Synchronization
#if canImport(SystemServiceMonitor)
@_weakLinked import SystemServiceMonitor
#endif
import GRPCClientConfiguration
import Tracing

/// Central coordinator daemon interacting with PCC Gateway to provide node attestations and load status as well as
/// receive and respond with encrypted requests and responses. It also provides an endpoint for the workload controller
/// to signal readiness of the workload and to provide service discovery registration metadata that cloudboardd
/// announces to Service Discovery.
public actor CloudBoardDaemon {
    public static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "cloudboardd"
    )

    static let metricsClientName = "cloudboardd"
    static let maxInstanceCount = 1000

    /// cb_jobhelpers create non disposable LAContexts, which have a limit around 170
    /// per SoC. We set the limit of the total number of cb_jobhelpers which can hold
    /// an LAContext just under this. The jobhelpers release the LAContext once they
    /// have completed the SEP operation and notify cloudboardd
    static let maxAuthContextCount = 150

    private static let watchdogProcessName = "cloudboardd"
    private let metricsSystem: MetricsSystem
    private let tracer: RequestSummaryTracer

    private let workloadManagers: [WorkloadManager]
    private let heartbeatPublisher: HeartbeatPublisher?
    private let launchdJobFinder: LaunchdJobFinderProtocol
    private let serviceDiscoverySetup: ServiceDiscoverySetup
    private let attestationProvider: AttestationProvider?
    private let config: CloudBoardDConfiguration
    private let hotProperties: HotPropertiesController?
    private let healthServer: HealthServer?
    private let nodeInfo: NodeInfo?
    private let group: NIOTSEventLoopGroup
    private let workloadControllerServer: WorkloadControllerServer?
    private let insecureListener: Bool
    private let lifecycleManager: LifecycleManager
    private let watchdogService: CloudBoardWatchdogService?
    private let statusMonitor: StatusMonitor
    private let jobAuthClient: CloudBoardJobAuthAPIClientProtocol?
    private var exitContinuation: CheckedContinuation<Void, Never>?
    private let convergenceTracing: ConvergenceTracing?
    private var serviceDiscoveryComms: ServiceDiscoveryCommsProtocol?
    private let healthReporter: (any RunnableHealthReporter)?
    private let statusProvider: StatusProvider?
    private let dependencyHealthChecker: ServiceDependencyHealthChecker?

    public init(configPath: String?, metricsSystem: MetricsSystem? = nil) throws {
        let config: CloudBoardDConfiguration
        if let configPath {
            Self.logger.info("Loading configuration from \(configPath, privacy: .public)")
            config = try CloudBoardDConfiguration.fromFile(
                path: configPath, secureConfigLoader: .real
            )
        } else {
            Self.logger.info("Loading configuration from preferences")
            config = try CloudBoardDConfiguration.fromPreferences()
        }
        let configJSON = try String(decoding: JSONEncoder().encode(config), as: UTF8.self)
        Self.logger.log("Loaded configuration: \(configJSON, privacy: .public)")
        let nodeInfo = NodeInfo.load(secureConfig: config.secureConfig)
        if let isLeader = nodeInfo.isLeader {
            if !isLeader {
                CloudBoardDaemon.logger.log("Not a leader node, exiting..")
                Foundation.exit(0)
            }
        } else {
            CloudBoardDaemon.logger.error("Unable to check if node is a leader")
        }
        try self.init(config: config, nodeInfo: nodeInfo, metricsSystem: metricsSystem)
    }

    internal init(config: CloudBoardDConfiguration, nodeInfo: NodeInfo?, metricsSystem: MetricsSystem? = nil) throws {
        self.group = NIOTSEventLoopGroup.singleton
        let metricsSystem = metricsSystem ?? CloudMetricsSystem(clientName: CloudBoardDaemon.metricsClientName)
        self.statusMonitor = .init(metrics: metricsSystem)
        let tracer = RequestSummaryTracer(metrics: metricsSystem)
        let launchdJobFinder = LaunchdJobFinder(metrics: metricsSystem)
        guard !config.secureConfig.cloudAppNames.isEmpty else {
            throw CloudBoardDaemonError.noCloudAppSet
        }

        let assetsMetadataClient: any AssetsMetadataClientProtocol
        #if canImport(CloudAssetDownloaderFramework)
        assetsMetadataClient = CloudAssetsMetadataClient()
        #else
        throw CloudBoardDaemonError.noCloudAssetDownloaderFramework
        #endif

        var totalMaxAuthContexts = 0
        var totalMaxCloudAppInstanceCount = 0
        self.workloadManagers = try config.secureConfig.cloudAppNames.compactMap { cloudAppName in
            let cloudAppConfig = try config.secureConfig.cloudAppConfig(cloudApp: cloudAppName)
            if !config.secureConfig.shouldEnforceAppleInfrastructureSecurityConfig,
               cloudAppConfig.disabled {
                return nil
            }
            totalMaxAuthContexts += cloudAppConfig.maxAuthContextCount
            totalMaxCloudAppInstanceCount += cloudAppConfig.maxInstanceCount

            return try WorkloadManager(
                isProxy: config.secureConfig.isProxy,
                cloudAppName: cloudAppName,
                config: cloudAppConfig,
                assetsMetadataClient: assetsMetadataClient,
                launchdJobFinder: launchdJobFinder,
                tracer: tracer,
                metrics: metricsSystem,
                inMemoryControllerConfig: cloudAppConfig.inMemoryController
            )
        }
        guard totalMaxAuthContexts <= Self.maxAuthContextCount else {
            throw CloudBoardDaemonError.maxAuthContextCountExceedsLimit(totalMaxAuthContexts)
        }
        guard totalMaxCloudAppInstanceCount <= Self.maxInstanceCount else {
            throw CloudBoardDaemonError.maxInstanceCountExceedsLimit(totalMaxCloudAppInstanceCount)
        }
        self.metricsSystem = metricsSystem
        self.tracer = tracer
        self.launchdJobFinder = launchdJobFinder
        self.convergenceTracing = ConvergenceTracing(
            linkSpanID: config.secureConfig.convergenceSpanID,
            linkTraceID: config.secureConfig.convergenceTraceID,
            tracer: self.tracer
        )
        self.convergenceTracing?.startSummary()
        self.config = config
        let hotProperties = HotPropertiesController()
        self.hotProperties = hotProperties
        self.nodeInfo = nodeInfo
        self.insecureListener = false
        self.serviceDiscoverySetup = ServiceDiscoverySetup.standard
        self.jobAuthClient = nil
        self.statusProvider = StatusProvider(statusMonitor: self.statusMonitor)
        self.attestationProvider = nil
        self.workloadControllerServer = WorkloadControllerServer(
            metrics: self.metricsSystem
        )
        self.healthReporter = Self.initializeHealthReporter(config: config)
        self.healthServer = HealthServer(healthReporter: self.healthReporter)
        if let heartbeat = config.heartbeat {
            CloudBoardDaemon.logger.info("Heartbeat configured")
            self.heartbeatPublisher = try .init(
                configuration: heartbeat,
                identifier: ProcessInfo.processInfo.hostName,
                nodeInfo: nodeInfo,
                statusMonitor: self.statusMonitor,
                hotProperties: hotProperties,
                metrics: metricsSystem
            )
        } else {
            CloudBoardDaemon.logger.info("Heartbeat not configured")
            self.heartbeatPublisher = nil
        }

        let lifecycleManagerConfig = config.lifecycleManager ?? CloudBoardDConfiguration.LifecycleManager()
        self.lifecycleManager = LifecycleManager(
            config: .init(
                timeout: lifecycleManagerConfig.drainTimeout,
                enforceAllStateChecks: lifecycleManagerConfig.enforceAllStateChecks
            )
        )
        self.watchdogService = CloudBoardWatchdogService(processName: Self.watchdogProcessName, logger: Self.logger)
        self.dependencyHealthChecker = Self.initializeServiceDependencyHealthChecker(config: config)
    }

    // Test entry point to allow dependency injection.
    //
    // This variant explicitly _disables_ having a service discovery integration by default, as
    // typically that won't be working properly in unit test scenarios unless it has
    // been deliberately set up.
    internal init(
        group: NIOTSEventLoopGroup = NIOTSEventLoopGroup.singleton,
        heartbeatPublisher: HeartbeatPublisher? = nil,
        serviceDiscoverySetup: ServiceDiscoverySetup = .notPresent,
        workloadManagers: [WorkloadManager] = [],
        healthServer: HealthServer? = nil,
        healthReporter: (any RunnableHealthReporter)? = nil,
        lifecycleManager: LifecycleManager? = nil,
        attestationProvider: AttestationProvider? = nil,
        config: CloudBoardDConfiguration,
        hotProperties: HotPropertiesController? = nil,
        nodeInfo: NodeInfo? = nil,
        workloadControllerServer: WorkloadControllerServer?,
        insecureListener: Bool,
        metricsSystem: MetricsSystem? = nil,
        statusMonitor: StatusMonitor? = nil,
        tracer: RequestSummaryTracer? = nil,
        jobAuthClient: CloudBoardJobAuthAPIClientProtocol?,
        launchdJobFinder: LaunchdJobFinderProtocol? = nil,
        statusProvider: StatusProvider? = nil,
        dependencyHealthChecker: ServiceDependencyHealthChecker? = nil
    ) throws {
        let metricsSystem = metricsSystem ?? CloudMetricsSystem(clientName: CloudBoardDaemon.metricsClientName)
        let statusMonitor = statusMonitor ?? StatusMonitor(metrics: metricsSystem)
        self.statusMonitor = statusMonitor
        let tracer = tracer ?? RequestSummaryTracer(metrics: metricsSystem)
        self.convergenceTracing = nil
        self.group = group
        self.heartbeatPublisher = heartbeatPublisher
        self.serviceDiscoverySetup = serviceDiscoverySetup
        let launchdJobFinder = launchdJobFinder ?? LaunchdJobFinder(metrics: metricsSystem)
        self.workloadManagers = workloadManagers
        self.metricsSystem = metricsSystem
        self.tracer = tracer
        self.launchdJobFinder = launchdJobFinder
        if let lifecycleManager {
            self.lifecycleManager = lifecycleManager
        } else {
            let lifecycleManagerConfig = config.lifecycleManager ?? CloudBoardDConfiguration.LifecycleManager()
            self.lifecycleManager = LifecycleManager(
                config: .init(
                    timeout: lifecycleManagerConfig.drainTimeout,
                    enforceAllStateChecks: lifecycleManagerConfig.enforceAllStateChecks
                )
            )
        }
        self.attestationProvider = attestationProvider
        self.config = config
        self.hotProperties = hotProperties
        self.nodeInfo = nodeInfo
        self.insecureListener = insecureListener
        self.workloadControllerServer = workloadControllerServer
        self.watchdogService = nil
        self.jobAuthClient = jobAuthClient
        self.healthServer = healthServer
        self.healthReporter = healthReporter
        self.statusProvider = statusProvider
        self.dependencyHealthChecker = dependencyHealthChecker
    }

    nonisolated static func initializeHealthReporter(config: CloudBoardDConfiguration) -> RunnableHealthReporter? {
        #if canImport(SystemServiceMonitor)
        if #available(iOS 26.0, macOS 15.6, *), #_hasSymbol(ReportClient.self) {
            let enableSSMStatusReportingFlag = config.systemServiceMonitor?
                .enableSSMStatusReporting ?? CloudBoardDConfiguration.SystemServiceMonitorConfiguration()
                .enableSSMStatusReporting
            guard enableSSMStatusReportingFlag else {
                CloudBoardDaemon.logger.info("SystemServiceMonitor disabled")
                return nil
            }

            return SystemServiceMonitorHealthReporter()
        }
        #endif

        CloudBoardDaemon.logger.debug("SystemServiceMonitor is not available")
        return nil
    }

    nonisolated static func initializeServiceDependencyHealthChecker(config: CloudBoardDConfiguration)
    -> ServiceDependencyHealthChecker? {
        #if canImport(SystemServiceMonitor)
        if #available(iOS 26.0, macOS 15.6, *), #_hasSymbol(ReportClient.self) {
            let enableSSMStatusReportingFlag = config.systemServiceMonitor?
                .enableSSMStatusReporting ?? CloudBoardDConfiguration.SystemServiceMonitorConfiguration()
                .enableSSMStatusReporting
            guard enableSSMStatusReportingFlag else {
                CloudBoardDaemon.logger.info("SystemServiceMonitor disabled")
                return nil
            }

            return ControlPlaneHealthDHealthChecker()
        }
        #endif

        CloudBoardDaemon.logger.debug("SystemServiceMonitor is not available")
        return nil
    }

    public func start() async throws {
        do {
            try await self.start(
                portPromisePerCloudApp: nil,
                allowExit: false,
                customSearchPath: .fromPreferences
            )
        } catch {
            self.convergenceTracing?.stopSummary(error: error)
            throw error
        }
    }

    /// expose more control for testing purposes
    /// - a way of surfacing the GRPC server port
    /// - a way to allow CloudBoardDaemon to exit
    /// - a way of configuring the search paths
    func start(
        portPromisePerCloudApp: [String: Promise<Int, Error>]?,
        allowExit: Bool,
        // any test using this should be isolated by default
        customSearchPath: CustomSearchPathDirectory = .explictCompleteIsolation()
    ) async throws {
        try await CloudBoardMetrics.Uptime.withStandardMetrics(
            processInfo: Metrics.ProcessInfo.self,
            metrics: self.metricsSystem
        ) {
            try await self._start(
                portPromisePerCloudApp: portPromisePerCloudApp,
                allowExit: allowExit,
                customSearchPath: customSearchPath
            )
        }
    }

    private func _start(
        portPromisePerCloudApp: [String: Promise<Int, Error>]?,
        allowExit: Bool,
        // any test using this should be isolated by default
        customSearchPath: CustomSearchPathDirectory = .explictCompleteIsolation()
    ) async throws {
        Self.logger.log("hello from cloudboardd")
        switch customSearchPath {
        case .systemNormal:
            () // do nothing
        case .fromPreferences:
            configureTemporaryDirectory(suffix: CFPreferences.cloudboardPreferencesDomain, logger: Self.logger)
        case .explicit:
            Self.logger.log("using an explicit custom search path")
            if self.config.secureConfig.shouldEnforceAppleInfrastructureSecurityConfig {
                fatalError("Attempt to set explicit search paths which should only be used for testing")
            }
        }
        self._allowExit = allowExit

        let hotProperties = self.hotProperties
        let drainTimeMeasurement: OSAllocatedUnfairLock<ContinuousTimeMeasurement?> =
            OSAllocatedUnfairLock(initialState: nil)

        self.statusMonitor.initializing()
        let jobQuiescenceMonitor: JobQuiescenceMonitor
        await self.launchdJobFinder.cleanupManagedLaunchdJobs(logger: CloudBoardDaemon.logger)
        do {
            jobQuiescenceMonitor = JobQuiescenceMonitor(lifecycleManager: self.lifecycleManager)
            try jobQuiescenceMonitor.startQuiescenceMonitor()

            try await self.lifecycleManager.managed {
                let identityManager = IdentityManager(
                    useSelfSignedCert: self.config.grpc?.useSelfSignedCertificate == true,
                    metricsSystem: self.metricsSystem,
                    metricProcess: "cloudboardd"
                )
                if !self.insecureListener, identityManager.identity == nil {
                    CloudBoardDaemon.logger.error("Unable to load TLS identity, exiting.")
                    throw IdentityManagerError.unableToRunSecureService
                }

                if hotProperties != nil {
                    CloudBoardDaemon.logger.info("Hot properties are enabled.")
                } else {
                    CloudBoardDaemon.logger.info("Hot properties are disabled.")
                }

                let heartbeatPublisher = self.heartbeatPublisher
                if heartbeatPublisher != nil {
                    CloudBoardDaemon.logger.info("Heartbeats are enabled.")
                } else {
                    CloudBoardDaemon.logger.info("Heartbeats are disabled.")
                }
                await heartbeatPublisher?.updateCredentialProvider {
                    identityManager.identity?.credential
                }

                let attestationProvider: AttestationProvider
                if let injectedAttestationProvider = self.attestationProvider {
                    CloudBoardDaemon.logger.info("using attestation provider injected for testing")
                    attestationProvider = injectedAttestationProvider
                } else {
                    attestationProvider = await AttestationProvider(
                        attestationClient: CloudBoardAttestationAPIXPCClient.localConnection(),
                        metricsSystem: self.metricsSystem,
                        healthMonitors: self.workloadManagers.map {
                            $0.healthMonitor
                        },
                        isProxy: self.config.secureConfig.isProxy
                    )
                }

                let sessionsFileDirectory: URL = try customSearchPath
                    .lookup(for: .cachesDirectory, in: .userDomainMask)
                    .appending(components: CFPreferences.cloudboardPreferencesDomain, "sessions")
                let sessionStore = try SessionStore(
                    attestationProvider: attestationProvider,
                    metrics: self.metricsSystem,
                    sessionStorage: OnDiskSessionStorage(fileDirectory: sessionsFileDirectory)
                )

                let keepalive = self.config.grpc?.keepalive
                let identityCallback = if !self.insecureListener {
                    identityManager.identityCallback
                } else {
                    nil as GRPCTLSConfiguration.IdentityCallback?
                }

                try await withErrorLogging(operation: "cloudboardDaemon task group", sensitiveError: false) {
                    try await withThrowingTaskGroup(of: String.self) { group in

                        // Starting the IdentityManager early is important in permitting services using TLS
                        // to become available early in the daemon's lifecycle - e.g. statusServer
                        group.addTaskWithLogging(operation: "certificate refresh", sensitiveError: false) {
                            await identityManager.identityUpdateLoop()
                            return "certificate refresh"
                        }

                        group.addTask {
                            try await attestationProvider.run()
                            return "attestationProvider"
                        }

                        group.addTask {
                            try await sessionStore.run()
                            return "sessionStore"
                        }

                        if let hotProperties = self.hotProperties {
                            group.addTaskWithLogging(operation: "Hot properties task", sensitiveError: false) {
                                try await hotProperties.run(metrics: self.metricsSystem)
                                return "Hot properties task"
                            }
                        }

                        try await withErrorLogging(operation: "Verify hot property update received", level: .default) {
                            self.convergenceTracing?.checkpoint(
                                operationName: DaemonStatus.waitingForFirstHotPropertyUpdate.metricDescription
                            )
                            self.statusMonitor.waitingForFirstHotPropertyUpdate()
                            try await self.hotProperties?.waitForFirstUpdate()
                        }

                        if let healthServer = self.healthServer {
                            if let healthReporter = self.healthReporter {
                                await healthReporter.run()
                            }
                            group.addTaskWithLogging(operation: "healthServer", sensitiveError: false) {
                                await healthServer.run(healthPublishers: self.workloadManagers.map { $0.healthMonitor })
                                return "healthServer"
                            }
                        }

                        if let statusProvider = self.statusProvider {
                            group.addTaskWithLogging(operation: "statusServer", sensitiveError: false) {
                                let statusPort = self.config.statusServer.port
                                let statusServiceAddress = try await self
                                    .resolveServiceAddress(cloudAppPort: statusPort)
                                try await self.runStatusServer(
                                    statusProvider: statusProvider,
                                    identityCallback: identityCallback,
                                    keepalive: keepalive,
                                    serviceAddress: statusServiceAddress
                                )
                                return "statusServer"
                            }
                        }

                        if let heartbeatPublisher {
                            group.addTaskWithLogging(operation: "heartbeat", sensitiveError: false) {
                                try await heartbeatPublisher.run()
                                return "heartbeat"
                            }
                        }

                        // Block service announce until we are sure we are able to fetch attestations
                        try await withErrorLogging(operation: "Verify attestation fetch", level: .default) {
                            self.convergenceTracing?.checkpoint(
                                operationName: DaemonStatus.waitingForFirstAttestationFetch.metricDescription
                            )
                            self.statusMonitor.waitingForFirstAttestationFetch()
                            _ = try await attestationProvider.currentAttestationSet()
                        }

                        // Block service announce until we have obtained signing keys from cb_jobauthd
                        try await withErrorLogging(
                            operation: "Verify presence of auth token signing keys",
                            level: .default
                        ) {
                            self.statusMonitor.waitingForFirstKeyFetch()

                            self.convergenceTracing?.checkpoint(
                                operationName: DaemonStatus.waitingForFirstKeyFetch.metricDescription
                            )

                            try await self.checkAuthTokenSigningKeysPresence()
                            CloudBoardDaemon.logger.log("Signing key verification passed")
                        }

                        group.addTaskWithLogging(operation: "workload managers", sensitiveError: false) {
                            do {
                                let expectedPeerAPRNs: [APRN]? = if let aprns = self.config.grpc?.expectedPeerAPRNs {
                                    try aprns.map { try APRN(string: $0) }
                                } else if let aprn = self.config.grpc?.expectedPeerAPRN {
                                    try [APRN(string: aprn)]
                                } else {
                                    nil
                                }
                                CloudBoardDaemon.logger.log(
                                    "Configured expected peer APRNs: \(expectedPeerAPRNs.map { "\($0)" } ?? "nil", privacy: .public)"
                                )

                                // register watchdog work processor to monitor global concurrency thread pool.
                                // Disabled in unit tests
                                if let watchdogService = self.watchdogService {
                                    await watchdogService.activate()
                                }
                                try await withLifecycleManagementHandlers(label: "workloadControllerServer") {
                                    self.statusMonitor.waitingForWorkloadRegistration()
                                    do {
                                        try await withThrowingTaskGroup { grpcGroup in
                                            if let portPromisePerCloudApp {
                                                guard portPromisePerCloudApp.count == self.workloadManagers.count else {
                                                    fatalError("port promise not set for all cloud apps")
                                                }
                                            }
                                            for workloadManager in self.workloadManagers {
                                                if let portPromisePerCloudApp {
                                                    guard portPromisePerCloudApp[workloadManager.cloudAppName] != nil
                                                    else {
                                                        fatalError(
                                                            "port promise not set for \(workloadManager.cloudAppName)"
                                                        )
                                                    }
                                                }

                                                let serviceAddress = try await self
                                                    .resolveServiceAddress(
                                                        cloudAppPort: self.config.secureConfig
                                                            .cloudAppPort(cloudApp: workloadManager.cloudAppName)
                                                    )
                                                let serviceDiscovery = try await self.setupServiceDiscovery(
                                                    attestationProvider: attestationProvider,
                                                    identityManager: identityManager,
                                                    serviceAddress: serviceAddress
                                                )
                                                grpcGroup.addTask {
                                                    try await workloadManager.run(
                                                        enforceRequestBypass: self.config.secureConfig
                                                            .enforceRequestBypass(
                                                                cloudApp: workloadManager
                                                                    .cloudAppName
                                                            ),
                                                        identityCallback: identityCallback,
                                                        serviceAddress: serviceAddress,
                                                        expectedPeerAPRNs: expectedPeerAPRNs,
                                                        keepalive: keepalive,
                                                        portPromise: portPromisePerCloudApp?[
                                                            workloadManager
                                                                .cloudAppName
                                                        ],
                                                        attestationProvider: attestationProvider,
                                                        serviceDiscovery: serviceDiscovery,
                                                        loadConfiguration: self.config.load,
                                                        hotProperties: hotProperties,
                                                        sessionStore: sessionStore,
                                                        workloadControllerServer: self.workloadControllerServer
                                                    )
                                                }
                                            }
                                            await self.workloadControllerServer?.start()
                                            self.convergenceTracing?.stopSummary()
                                            do {
                                                try await grpcGroup.waitForAll()
                                            } catch {
                                                Self.logger
                                                    .error(
                                                        "workload controller failed with error: \(String(unredacted: error), privacy: .public)"
                                                    )
                                                throw error
                                            }
                                        }
                                    } catch {
                                        self.statusMonitor.workloadControllerRunningFailed()
                                        throw error
                                    }
                                } onDrain: {
                                    do {
                                        try await self.workloadControllerServer?.shutdown()
                                    } catch {
                                        Self.logger
                                            .error(
                                                "workload controller server failed to notify listeners of shutdown: \(String(reportable: error), privacy: .public)"
                                            )
                                    }
                                }
                                return "workload managers"
                            } catch {
                                self.statusMonitor.grpcServerRunningFailed()
                                throw error
                            }
                        }

                        group.addTaskWithLogging(
                            operation: "Publish nodeReleaseDigest metrics task",
                            sensitiveError: false,
                            logger: Self.logger,
                            level: .debug
                        ) {
                            let nodeReleaseDigest = try await attestationProvider.currentAttestationSet()
                                .currentAttestation.releaseDigest
                            while true {
                                self.metricsSystem.emit(Metrics.CloudBoardDaemon.ActiveNodeReleaseDigestGauge(
                                    value: 1,
                                    nodeReleaseDigestValue: nodeReleaseDigest
                                ))
                                Self.logger.log("publishing nodeReleaseDigest metrics \(nodeReleaseDigest)")
                                try await Task.sleep(for: gaugeMetricPublishInterval)
                            }
                            return "Publish nodeReleaseDigest metrics task"
                        }

                        group.addTaskWithLogging(
                            operation: "Emit daemon memory usage metrics",
                            sensitiveError: false,
                            logger: Self.logger,
                            level: .debug
                        ) {
                            try await runEmitMemoryUsageMetricsLoop(
                                logger: Self.logger,
                                metricsSystem: self.metricsSystem,
                                physicalMemoryFootprintGauge: {
                                    Metrics.CloudBoardDaemon.PhysicalMemoryFootprintGauge(value: $0)
                                },
                                lifetimeMaxPhysicalMemoryFootprintGauge: {
                                    Metrics.CloudBoardDaemon.LifetimeMaxPhysicalMemoryFootprintGauge(value: $0)
                                }
                            )
                            return "Emit daemon memory usage metrics"
                        }

                        // When any of these tasks exit, they all do.
                        let name = try await group.next()
                        Self.logger.log("\(name ?? "nil", privacy: .public) exited - cancelling everything else")
                        group.cancelAll()
                    }
                }
            } onDrain: {
                drainTimeMeasurement.withLock { $0 = ContinuousTimeMeasurement.start() }
                for workloadManager in self.workloadManagers {
                    self.metricsSystem.emit(
                        Metrics.CloudBoardDaemon.DrainStartCounter(
                            action: .increment,
                            dimensions: [
                                .activeRequests: "\(workloadManager.activeRequestsBeforeDrain)",
                                .cloudApp: workloadManager.cloudAppName,
                            ]
                        )
                    )
                }
            } onDrainCompleted: {
                let drainDuration = drainTimeMeasurement.withLock { $0?.duration }
                if let drainDuration {
                    for workloadManager in self.workloadManagers {
                        self.metricsSystem.emit(
                            Metrics.CloudBoardDaemon.DrainCompletionTimeHistogram(
                                duration: drainDuration,
                                activeRequests: workloadManager.activeRequestsBeforeDrain,
                                cloudApp: workloadManager.cloudAppName
                            )
                        )
                    }
                    Self.logger.log("Drain Completed in: \(drainDuration.seconds)s")
                }
            }
        } catch {
            self.statusMonitor.daemonExitingOnError()
            CloudBoardDaemon.logger.error("fatal error, exiting: \(String(unredacted: error), privacy: .public)")
            throw error
        }

        self.statusMonitor.daemonDrained()
        jobQuiescenceMonitor.quiesceCompleted()
        self.convergenceTracing?.stopSummary()

        // once drained do not exit, JobQuiescence Framework will take care of exiting
        // stash continuation for use in tests where we may want to exit
        await withCheckedContinuation { exitContinuation in
            self.exitContinuation = exitContinuation
            if self._allowExit {
                exitContinuation.resume()
            }
        }
    }

    private func runStatusServer(
        statusProvider: StatusProvider,
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        keepalive: CloudBoardDConfiguration.Keepalive?,
        serviceAddress: SocketAddress
    ) async throws {
        guard let host = serviceAddress.ipAddress, let port = serviceAddress.port else {
            CloudBoardDaemon.logger.error(
                "Unable to bind status server: invalid service address \(serviceAddress, privacy: .public)"
            )
            throw CloudBoardDaemonError.invalidServiceAddress(serviceAddress)
        }

        let loggingLogger = Logging.Logger(
            osLogSubsystem: "com.apple.cloudos.cloudboard",
            osLogCategory: "cloudboardd",
            domain: "StatusServer"
        )

        let server: Server

        if let identityCallback {
            let config = try GRPCTLSConfiguration.cloudboardProviderConfiguration(
                identityCallback: identityCallback,
                expectedPeerAPRNs: nil,
                metricsSystem: self.metricsSystem
            )
            var builder = Server.usingTLS(with: config, on: self.group)
                .withServiceProviders([statusProvider])
                .withLogger(loggingLogger)

            if let keepalive {
                builder = builder.withKeepalive(.init(keepalive))
            }

            server = try await builder.bind(host: host, port: port).get()
        } else {
            server = try await Server.insecure(group: self.group)
                .withServiceProviders([statusProvider])
                .withLogger(loggingLogger)
                .bind(host: host, port: port).get()
        }

        CloudBoardDaemon.logger.info("Status server listening on \(host):\(port)")

        try await withTaskCancellationHandler {
            try await server.onClose.get()
        } onCancel: {
            server.close(promise: nil)
        }
    }

    private var _allowExit = false

    private func setupServiceDiscovery(
        attestationProvider: AttestationProvider,
        identityManager: IdentityManager,
        serviceAddress: SocketAddress
    ) async throws -> (any ServiceDiscoveryPublisherProtocol)? {
        var serviceDiscovery: (any ServiceDiscoveryPublisherProtocol)?
        switch self.serviceDiscoverySetup {
        case .notPresent:
            CloudBoardDaemon.logger.warning("Service discovery not enabled due to setup")
            serviceDiscovery = nil
        case .predefined(let publisher):
            CloudBoardDaemon.logger.info("Using service discovery injected for testing")
            serviceDiscovery = publisher
        case .fromConfiguration(let comms):
            if let sdConfig = self.config.serviceDiscovery {
                CloudBoardDaemon.logger.info("Enabling service discovery")
                let serviceDiscoveryComms: any ServiceDiscoveryCommsProtocol
                if self.serviceDiscoveryComms != nil {
                    serviceDiscoveryComms = self.serviceDiscoveryComms!
                } else if let comms {
                    CloudBoardDaemon.logger.info("Using service discovery comms injected for testing")
                    serviceDiscoveryComms = comms
                } else {
                    serviceDiscoveryComms = try ServiceDiscoveryComms(
                        group: self.group,
                        configuration: sdConfig,
                        localIdentityCallback: identityManager.identityCallback,
                        metrics: self.metricsSystem
                    )
                }
                self.serviceDiscoveryComms = serviceDiscoveryComms
                let attestationSet = try await attestationProvider.currentAttestationSet()
                serviceDiscovery = try ServiceDiscoveryPublisher(
                    serviceDiscoveryComms: serviceDiscoveryComms,
                    configuration: sdConfig,
                    serviceAddress: serviceAddress,
                    hotProperties: self.hotProperties,
                    nodeInfo: self.nodeInfo,
                    cellID: self.config.serviceDiscovery?.cellID,
                    statusMonitor: self.statusMonitor,
                    metrics: self.metricsSystem,
                    nodeReleaseDigest: attestationSet.currentAttestation.releaseDigest,
                    routingGroupAliases: self.config.secureConfig.routingGroupAliases,
                    bootID: self.getAdvertisedBootID(appData: attestationSet.currentAttestation.appData),
                    dependencyHealthChecker: self.dependencyHealthChecker
                )
            } else {
                CloudBoardDaemon.logger.warning("Service discovery not enabled due to config")
                serviceDiscovery = nil
            }
        }
        return serviceDiscovery
    }

    /// On proxies we cannot advertise the bootID in the attestation for annoying, and hopefully
    /// temporary reasons. This isn't a problem for the current use cases, but if we aren't a proxy failing
    /// to advertise it will fail in much more complex ways down stream so it is terminal
    private func getAdvertisedBootID(appData: [String: Data]) -> String? {
        guard let bootID = appData[ComputeNodeAppDataKeys.bootID] else {
            if self.config.secureConfig.isProxy {
                return nil
            }
            fatalError(
                "We have no bootID in the attestation app data - this compute node will fail to function correctly in pick scenarios"
            )
        }
        guard let bootIDString = bootID.utf8String else {
            fatalError("The bootID '\(bootID.base64EncodedString())' was not a legal utf8 string!")
        }
        return bootIDString
    }

    private func checkAuthTokenSigningKeysPresence() async throws {
        let jobAuthClient: CloudBoardJobAuthAPIClientProtocol = if let _ = self.jobAuthClient {
            self.jobAuthClient!
        } else {
            await CloudBoardJobAuthAPIXPCClient.localConnection()
        }
        await jobAuthClient.connect()
        // This will wait until we successfully obtain the keys from cb_jobauthd. We deliberately block on this since
        // cb_jobhelper instances will do the same and we shouldn't register with Service Discovery if we know
        // cb_jobhelper instances won't come up.
        _ = try await jobAuthClient.requestTGTSigningKeys()
        _ = try await jobAuthClient.requestOTTSigningKeys()

        // We do not check that the signing key sets are non-empty as that is a valid configuration in non-prod
        // environments. cb_jobauthd itself enforces that the key rotation service configuration is provided for
        // customer configurations.
        await jobAuthClient.disconnect()
    }

    private func resolveServiceAddress(cloudAppPort: Int?) async throws -> SocketAddress {
        return try await self.config.resolveLocalServiceAddress(cloudAppPort: cloudAppPort)
    }
}

extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

// NOTE: The description of this type is publicly logged and/or included in metric dimensions and therefore MUST not
// contain sensitive data.
struct CloudBoardDaemonLogMetadata: CustomStringConvertible {
    var jobID: UUID?
    var rpcID: UUID?
    var requestTrackingID: String?
    var remotePID: Int?
    var workerID: UUID?
    var spanID: UInt64?
    var cloudApp: String?

    init(
        jobID: UUID? = nil,
        rpcID: UUID? = nil,
        requestTrackingID: String? = nil,
        remotePID: Int? = nil,
        workerID: UUID? = nil,
        spanID: UInt64? = nil,
        cloudApp: String? = nil
    ) {
        self.jobID = jobID
        self.rpcID = rpcID
        self.requestTrackingID = requestTrackingID
        self.remotePID = remotePID
        self.workerID = workerID
        self.spanID = spanID
        self.cloudApp = cloudApp
    }

    var description: String {
        var fields: [String] = []

        if let jobID = self.jobID {
            fields.append("jobID=\(jobID)")
        }
        if let rpcID = self.rpcID, rpcID != .zero {
            fields.append("rpcID=\(rpcID)")
        }
        if let requestTrackingID = self.requestTrackingID, requestTrackingID != "" {
            fields.append("requestTrackingID=\(requestTrackingID)")
        }
        if let remotePID = self.remotePID {
            fields.append("remotePid=\(remotePID)")
        }
        if let workerID = self.workerID {
            fields.append("workerID=\(workerID)")
        }
        if let spanID = self.spanID {
            fields.append("spanID=\(spanID)")
        }
        if let cloudApp = self.cloudApp {
            fields.append("cloudApp=\(cloudApp)")
        }

        if !fields.isEmpty {
            return "[\(fields.joined(separator: " "))]"
        }
        return ""
    }
}

enum CloudBoardDaemonError: ReportableError {
    case noCloudAppSet
    case noCloudAssetDownloaderFramework
    case maxInstanceCountExceedsLimit(Int)
    case maxAuthContextCountExceedsLimit(Int)
    case invalidServiceAddress(SocketAddress)

    var publicDescription: String {
        switch self {
        case .noCloudAppSet: "No Cloud App setup in secure config"
        case .noCloudAssetDownloaderFramework: "No CloudAssetDownloaderFramework"
        case .maxInstanceCountExceedsLimit(let setLimit): "Max instance count \(setLimit) exceeds limit of \(CloudBoardDaemon.maxInstanceCount)"
        case .maxAuthContextCountExceedsLimit(let setLimit): "Max auth context count \(setLimit) exceeds limit of \(CloudBoardDaemon.maxAuthContextCount)"
        case .invalidServiceAddress(let address): "Invalid service address: \(address)"
        }
    }
}
