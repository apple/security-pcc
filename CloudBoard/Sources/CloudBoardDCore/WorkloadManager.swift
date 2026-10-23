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

import CloudBoardCommon
import CloudBoardController
import CloudBoardDomain
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import GRPCClientConfiguration
import InternalGRPC
import Logging
import NIOCore
import NIOTransportServices
import os
import Synchronization

/// Manages workload execution and lifecycle for CloudBoard applications.
///
/// `WorkloadManager` is responsible for orchestrating the various components needed to run a CloudBoard application,
/// including job helper instances, health monitoring, gRPC servers, and workload control. It coordinates the startup,
/// execution, and shutdown of all these services in a structured manner.
///
/// ## Key Responsibilities
/// - Managing job helper instances and their lifecycle
/// - Providing health monitoring and status reporting
/// - Running the gRPC server with TLS configuration
/// - Coordinating workload control and service discovery
/// - Handling graceful shutdown and draining of active requests
package final class WorkloadManager: Sendable {
    /// Is the workload running in proxy mode.
    let isProxy: Bool

    /// Whether the proxy sends the attestation transparency log tree ID and revision to ROPES as find-worker
    /// routing-parameter constraints. Sourced from the global secure config.
    let includeTransparencyConstraintsInWorkerRequests: Bool

    /// The name of the CloudBoard application being managed.
    let cloudAppName: String

    /// How this cloud app advertises capacity and admits requests with respect to prewarmed-instance availability.
    let prewarmedAdmissionPolicy: SecureConfig.PrewarmedAdmissionPolicy

    /// Whether the reported max batch size should account for available prewarmed instances. Derived from
    /// `prewarmedAdmissionPolicy`.
    var maxBatchDependsOnPrewarmedSize: Bool {
        self.prewarmedAdmissionPolicy != .disabled
    }

    /// The statically-configured prewarm pool size for this cloud app, forwarded to the `WorkloadController` so it
    /// can warn when a registration's `maxBatchSize` exceeds it while `maxBatchDependsOnPrewarmedSize` is enabled.
    let configuredPrewarmedPoolSize: Int

    /// Monitors the health status of the service and its components.
    package let healthMonitor: ServiceHealthMonitor

    /// Provides health check functionality for gRPC health checks.
    let healthProvider: HealthProvider

    /// Manages job helper instances, including prewarming and lifecycle management.
    /// This is optional to support different testing scenarios.
    let jobHelperInstanceProvider: JobHelperInstanceProvider?

    /// Provides client connections to job helper instances.
    let jobHelperClientProvider: CloudBoardJobHelperClientProvider

    /// Thread-safe container for the CloudBoard provider instance.
    /// Protected by a mutex as it may be accessed concurrently during startup.
    let cloudBoardProvider: Mutex<CloudBoardProvider?> = .init(nil)

    /// Provides delegate handling for job helper responses.
    let jobhelperResponseDelegateProvider: CloudBoardJobHelperResponseDelegateProvider

    /// Optional workload controller for managing workload-specific operations.
    let workloadController: WorkloadController?

    /// Manages assets metadata for job helper and the workload.
    let assetsMetadataManager: AssetsMetadataManager

    /// Metrics system for collecting and reporting performance metrics.
    let metrics: MetricsSystem

    /// Tracer for request summary and performance monitoring.
    let tracer: RequestSummaryTracer

    /// Returns the number of active requests that are currently being processed before draining begins.
    ///
    /// This property is used during graceful shutdown to determine how many requests need to complete
    /// before the service can be safely stopped.
    ///
    /// - Returns: The count of active requests
    var activeRequestsBeforeDrain: Int {
        self.cloudBoardProvider.withLock { $0?.activeRequestsBeforeDrain ?? 0 }
    }

    /// Awaits initial assets readiness for this cloud app. Returns immediately when no provider exists or gating is
    /// disabled. Lets callers gate on per-app asset availability.
    /// - SeeAlso: `JobHelperInstanceProvider.waitForInitialAssets()`.
    func waitForInitialAssets() async throws {
        try await self.jobHelperInstanceProvider?.waitForInitialAssets()
    }

    /// Initializes a WorkloadManager
    ///
    /// This initializer sets up all the necessary components for running a CloudBoard application
    /// with full job helper instance management.
    ///
    /// - Parameters:
    ///   - isProxy: Whether this instance is running in proxy mode
    ///   - cloudAppName: The name identifier for the CloudBoard application
    ///   - config: Configuration settings for the cloud application
    ///   - launchdJobFinder: Service for finding and managing launchd jobs
    ///   - tracer: Request tracer for performance monitoring
    ///   - metrics: Metrics collection system
    ///   - workloadController: Optional workload controller in case the app is configured with in memory controller
    /// - Throws: Configuration or initialization errors from setting up job helper providers
    init(
        isProxy: Bool,
        cloudAppName: String,
        config: SecureConfig.CloudAppConfig,
        assetsMetadataClient: AssetsMetadataClientProtocol,
        launchdJobFinder: LaunchdJobFinderProtocol,
        tracer: RequestSummaryTracer,
        metrics: MetricsSystem,
        inMemoryControllerConfig: SecureConfig.AppControllerConfig = .inMemoryControllerNotEnabled,
        teardownTimeout: Duration,
        includeTransparencyConstraintsInWorkerRequests: Bool = true
    ) throws {
        self.isProxy = isProxy
        self.includeTransparencyConstraintsInWorkerRequests = includeTransparencyConstraintsInWorkerRequests
        self.cloudAppName = cloudAppName
        self.prewarmedAdmissionPolicy = config.prewarmedAdmissionPolicy
        self.configuredPrewarmedPoolSize = config.prewarmPoolSize
        self.healthMonitor = .init(
            cloudApp: cloudAppName,
            maxBatchDependsOnPrewarmedSize: config.maxBatchDependsOnPrewarmedSize
        )
        self.jobHelperInstanceProvider = try JobHelperInstanceProvider(
            cloudAppName: cloudAppName,
            supportAppNames: config.supportApps.map { $0 },
            isTrampolineProxy: config.isTrampolineProxy,
            prewarmedPoolSize: config.prewarmPoolSize,
            maxInstanceCount: config.maxInstanceCount,
            maxLAContextCount: config.maxAuthContextCount,
            maxApplicationLayerMessageSize: config.maxApplicationLayerMessageSize,
            maxToolInvocationsPerRequest: config.maxToolInvocationsPerRequest,
            teardownTimeout: teardownTimeout,
            warmupTimeout: config.warmupTimeout,
            consecutiveWarmupFailuresThreshold: config.consecutiveWarmupFailuresThreshold,
            healthMonitor: self.healthMonitor,
            maxBatchDependsOnPrewarmedSize: config.maxBatchDependsOnPrewarmedSize,
            metrics: metrics,
            tracer: tracer,
            launchdJobFinder: launchdJobFinder,
            jobHelperXPCClientFactory: CloudBoardJobHelperAPIXPCClientFactory(),
            waitForInitialAssets: true
        )
        self.jobHelperClientProvider = try CloudBoardJobHelperXPCClientProvider(
            instanceProvider: self.jobHelperInstanceProvider!
        )
        self.jobhelperResponseDelegateProvider = JobHelperResponseDelegateProvider()
        self.healthProvider = .init(monitor: self.healthMonitor)

        let workloadTags: [String: RoutingTagValue] = inMemoryControllerConfig.workloadTags.mapValues {
            switch $0 {
            case .string(let s):
                return .string(s)
            case .stringList(let l):
                return .stringList(l)
            }
        }
        let workloadConfig: InternalWorkloadConfig = if isProxy {
            .proxy(.init(
                maxBatchSize: inMemoryControllerConfig.maxConcurrency,
                optimalBatchSize: inMemoryControllerConfig.optimalBatchSize,
                currentBatchSize: 0,
                metadata: .init(services: inMemoryControllerConfig.proxyServices),
                workloadTags: workloadTags
            ))
        } else {
            .compute(.init(
                maxBatchSize: inMemoryControllerConfig.maxConcurrency,
                optimalBatchSize: inMemoryControllerConfig.optimalBatchSize,
                currentBatchSize: 0,
                workloadTags: workloadTags,
                appRoutingKeys: inMemoryControllerConfig.appRoutingKeys
            ))
        }

        self.workloadController = if inMemoryControllerConfig.inMemoryEnabled {
            .init(
                cloudAppName: cloudAppName,
                healthPublisher: self.healthMonitor,
                inMemoryControllerConfig: (
                    .init(workloadName: inMemoryControllerConfig.workloadName, cloudAppName: cloudAppName),
                    workloadConfig
                ),
                maxBatchDependsOnPrewarmedSize: config.maxBatchDependsOnPrewarmedSize,
                configuredPrewarmedPoolSize: config.prewarmPoolSize,
                metrics: metrics
            )
        } else { nil }

        var assetsConsumerIDs: [AssetConsumer: String] = [:]
        if let pirAssetsConsumerID = config.assets.pirAssetsConsumerID {
            assetsConsumerIDs[.pir] = pirAssetsConsumerID
        }
        if let cloudAppAssetsConsumerID = config.assets.cloudAppAssetsConsumerID {
            assetsConsumerIDs[.cloudApp] = cloudAppAssetsConsumerID
        }
        self.assetsMetadataManager = .init(
            assetsConsumerIDs: assetsConsumerIDs,
            assetsMetadataClient: assetsMetadataClient,
            serviceHealthMonitor: self.healthMonitor,
            jobHelperInstanceProvider: self.jobHelperInstanceProvider
        )
        self.metrics = metrics
        self.tracer = tracer
    }

    /// For testing only
    /// Initializes a WorkloadManager for testing purposes with configurable mock components.
    ///
    /// This initializer provides extensive customization options for testing scenarios,
    /// allowing different components to be mocked or replaced as needed.
    ///
    /// - Parameters:
    ///   - cloudAppName: The name identifier for the CloudBoard application
    ///   - config: CloudBoard daemon configuration
    ///   - metrics: Optional metrics system (defaults to CloudMetricsSystem if nil)
    ///   - tracer: Optional request tracer (defaults to RequestSummaryTracer if nil)
    ///   - launchdJobFinder: Optional job finder (defaults to LaunchdJobFinder if nil)
    ///   - jobHelperClientProvider: Optional mock job helper client provider
    ///   - jobHelperXPCClientFactory: Optional mock XPC client factory
    ///   - healthMonitor: Optional mock health monitor
    ///   - jobHelperResponseDelegateProvider: Optional mock response delegate provider
    ///   - workloadController: Optional mock workload controller
    ///
    /// - Note: Providing both `jobHelperClientProvider` and `jobHelperXPCClientFactory` will cause a precondition
    /// failure,
    ///         as these represent different levels of mocking that should not be used together.
    ///
    /// - Throws: Configuration or initialization errors from setting up components
    init(
        isProxy: Bool,
        cloudAppName: String,
        supportAppNames: [String],
        isTrampolineProxy: Bool,
        maxApplicationLayerMessageSize: Int = 1024 * 1024 * 4,
        maxToolInvocationsPerRequest: Int = SecureConfig.CloudAppConfig.defaultMaxToolInvocationsPerRequest,
        config: CloudBoardDConfiguration,
        metrics: MetricsSystem? = nil,
        tracer: RequestSummaryTracer? = nil,
        launchdJobFinder: LaunchdJobFinderProtocol? = nil,
        jobHelperClientProvider: CloudBoardJobHelperClientProvider? = nil,
        jobHelperXPCClientFactory: (any CloudBoardJobHelperAPIClientFactoryProtocol)? = nil,
        healthMonitor: ServiceHealthMonitor? = nil,
        jobHelperResponseDelegateProvider: CloudBoardJobHelperResponseDelegateProvider? = nil,
        assetMetadataClient: (any AssetsMetadataClientProtocol)? = nil,
        waitForInitialAssets: Bool = false,
        workloadController: WorkloadController? = nil,
        teardownTimeout: Duration = .seconds(10)
    ) throws {
        self.isProxy = isProxy
        self.cloudAppName = cloudAppName
        self.includeTransparencyConstraintsInWorkerRequests = config.secureConfig
            .includeTransparencyConstraintsInWorkerRequests
        self.prewarmedAdmissionPolicy =
            try (config.secureConfig.cloudAppConfig(cloudApp: cloudAppName)).prewarmedAdmissionPolicy
        self.configuredPrewarmedPoolSize = config.prewarming.prewarmedPoolSize ?? 0
        self.metrics = metrics ?? CloudMetricsSystem(clientName: "cloudboardd")
        self.tracer = tracer ?? RequestSummaryTracer(metrics: self.metrics)
        let launchdJobFinder = launchdJobFinder ?? LaunchdJobFinder(metrics: self.metrics)
        self.healthMonitor = healthMonitor ?? ServiceHealthMonitor(cloudApp: self.cloudAppName)
        // This is a legacy of there being two different approaches to mocking the jobhelpers out.
        // One is high level, directly replacing the jobHelperClientProvider,
        // the other allows for mocking out the launchd and local XPC parts but still
        // using the normal code paths around them.
        // The former is simpler, but doesn't exercise as much code
        if let jobHelperClientProvider {
            // providing both would indicate a flawed understanding of the mocking
            precondition(
                jobHelperXPCClientFactory == nil,
                "provided jobHelperClientProvider but jobHelperXPCClientFactory was also provided"
            )
            self.jobHelperClientProvider = jobHelperClientProvider
            self.jobHelperInstanceProvider = nil
        } else {
            let jobHelperXPCClientFactory = jobHelperXPCClientFactory ?? CloudBoardJobHelperAPIXPCClientFactory()
            self.jobHelperInstanceProvider = try JobHelperInstanceProvider(
                cloudAppName: cloudAppName,
                supportAppNames: supportAppNames,
                isTrampolineProxy: isTrampolineProxy,
                prewarmedPoolSize: config.prewarming.prewarmedPoolSize ?? 0,
                maxInstanceCount: config.prewarming.maxProcessCount ?? 0,
                maxApplicationLayerMessageSize: maxApplicationLayerMessageSize,
                maxToolInvocationsPerRequest: maxToolInvocationsPerRequest,
                teardownTimeout: teardownTimeout,
                consecutiveWarmupFailuresThreshold: config.prewarming.prewarmedPoolSize ?? 1,
                healthMonitor: self.healthMonitor,
                metrics: self.metrics,
                tracer: self.tracer,
                launchdJobFinder: launchdJobFinder,
                jobHelperXPCClientFactory: jobHelperXPCClientFactory,
                waitForInitialAssets: waitForInitialAssets
            )
            self.jobHelperClientProvider = try CloudBoardJobHelperXPCClientProvider(
                instanceProvider: self.jobHelperInstanceProvider!
            )
        }
        self.healthProvider = .init(monitor: self.healthMonitor)
        if let jobHelperResponseDelegateProvider {
            self.jobhelperResponseDelegateProvider = jobHelperResponseDelegateProvider
        } else {
            self.jobhelperResponseDelegateProvider = JobHelperResponseDelegateProvider()
        }

        let assetsConfig = try config.secureConfig.cloudAppConfig(cloudApp: cloudAppName).assets
        var assetsConsumerIDs: [AssetConsumer: String] = [:]
        if let cloudAppAssetsConsumerID = assetsConfig.cloudAppAssetsConsumerID {
            assetsConsumerIDs[.cloudApp] = cloudAppAssetsConsumerID
        }
        if let pirAssetsConsumerID = assetsConfig.pirAssetsConsumerID {
            assetsConsumerIDs[.pir] = pirAssetsConsumerID
        }
        self.assetsMetadataManager = .init(
            assetsConsumerIDs: assetsConsumerIDs,
            assetsMetadataClient: assetMetadataClient ?? NoOpAssetsMetadataClient(),
            serviceHealthMonitor: self.healthMonitor,
            jobHelperInstanceProvider: self.jobHelperInstanceProvider
        )

        self.workloadController = workloadController
    }

    /// Runs the WorkloadManager and orchestrates all its components.
    ///
    /// This is the main entry point for starting the WorkloadManager. It sets up and coordinates
    /// the execution of multiple concurrent tasks including job helper instances, health monitoring,
    /// gRPC server, service discovery, and workload control.
    ///
    /// - Parameters:
    ///   - enforceRequestBypass: Whether to enforce request bypass rules
    ///   - identityCallback: Optional TLS identity callback for secure connections
    ///   - serviceAddress: The socket address where the service should bind
    ///   - expectedPeerAPRNs: Expected Apple Push Receipt Numbers for peer validation
    ///   - keepalive: Optional keepalive configuration for connections
    ///   - portPromise: Optional promise to fulfill with the bound port number
    ///   - attestationProvider: Provider for attestation functionality
    ///   - serviceDiscovery: Optional service discovery publisher
    ///   - loadConfiguration: Configuration for load management
    ///   - hotProperties: Optional hot properties controller for dynamic configuration
    ///   - sessionStore: Store for managing user sessions
    ///   - workloadControllerServer: Optional workload controller server
    ///
    /// - Throws: Various errors related to network binding, service startup, or task execution
    ///
    /// ## Task Coordination
    /// The method uses a `TaskGroup` to run multiple concurrent operations:
    /// - Job helper instance management (if configured)
    /// - Health monitoring with lifecycle management
    /// - CloudBoard provider execution
    /// - Service discovery (if provided)
    /// - gRPC server hosting
    /// - Workload controller (if provided)
    ///
    /// When any task exits, all other tasks are cancelled, ensuring coordinated shutdown.
    func run(
        enforceRequestBypass: Bool,
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        serviceAddress: SocketAddress,
        expectedPeerAPRNs: [APRN]?,
        keepalive: CloudBoardDConfiguration.Keepalive?,
        portPromise: Promise<Int, Error>? = nil,
        attestationProvider: AttestationProvider,
        serviceDiscovery: ServiceDiscoveryPublisherProtocol?,
        loadConfiguration: CloudBoardDConfiguration.LoadConfiguration,
        hotProperties: HotPropertiesController?,
        perAppMaxCumulativeRequestBytes: Int? = nil,
        sessionStore: SessionStore,
        workloadControllerServer: WorkloadControllerServer?
    ) async throws {
        let cloudboardProvider = CloudBoardProvider(
            isProxy: self.isProxy,
            cloudAppName: self.cloudAppName,
            enforceRequestBypass: enforceRequestBypass,
            jobHelperClientProvider: self.jobHelperClientProvider,
            jobHelperResponseDelegateProvider: self.jobhelperResponseDelegateProvider,
            healthMonitor: self.healthMonitor,
            metrics: self.metrics,
            tracer: self.tracer,
            attestationProvider: attestationProvider,
            loadConfiguration: loadConfiguration,
            hotProperties: hotProperties,
            perAppMaxCumulativeRequestBytes: perAppMaxCumulativeRequestBytes,
            sessionStore: sessionStore,
            prewarmedAdmissionPolicy: self.prewarmedAdmissionPolicy,
            includeTransparencyConstraintsInWorkerRequests: self.includeTransparencyConstraintsInWorkerRequests
        )
        self.cloudBoardProvider.withLock { $0 = cloudboardProvider }
        try await withErrorLogging(operation: "cloudApp:\(self.cloudAppName) task group", sensitiveError: false) {
            try await withThrowingTaskGroup(of: String.self) { group in
                if let jobHelperInstanceProvider {
                    group.addTask {
                        try await jobHelperInstanceProvider.run()
                        return "\(self.cloudAppName)::jobHelperInstanceProvider"
                    }
                }

                group.addTaskWithLogging(operation: "\(self.cloudAppName)::healthMonitor", sensitiveError: false) {
                    await withLifecycleManagementHandlers(label: "\(self.cloudAppName)::healthMonitor") {
                        await self.healthProvider.run()
                    } onDrain: {
                        self.healthMonitor.drain()
                    }
                    return "\(self.cloudAppName)::healthMonitor"
                }

                group.addTask {
                    await cloudboardProvider.run()
                    return "\(self.cloudAppName)::cloudBoardProvider"
                }

                group.addTask {
                    try await self.assetsMetadataManager.run()
                    return "\(self.cloudAppName)::assetsMetadataManager"
                }

                if let serviceDiscovery {
                    group.addTaskWithLogging(
                        operation: "\(self.cloudAppName)::serviceDiscovery",
                        sensitiveError: false
                    ) {
                        do {
                            try await serviceDiscovery.run()
                        } catch let error as CancellationError {
                            throw error
                        } catch {
                            throw error
                        }
                        return "\(self.cloudAppName)::serviceDiscovery"
                    }
                }

                group.addTask {
                    try await Self.runServer(
                        cloudBoardProvider: cloudboardProvider,
                        providers: [self.healthProvider],
                        identityCallback: identityCallback,
                        serviceAddress: serviceAddress,
                        expectedPeerAPRNs: expectedPeerAPRNs,
                        keepalive: keepalive.map { .init($0) },
                        portPromise: portPromise,
                        metricsSystem: self.metrics
                    )
                    return "\(self.cloudAppName)::grpcServer"
                }

                if let workloadControllerServer {
                    group.addTask {
                        try await workloadControllerServer.runController(
                            workloadController: self.workloadController ?? WorkloadController(
                                cloudAppName: self.cloudAppName,
                                healthPublisher: self.healthMonitor,
                                maxBatchDependsOnPrewarmedSize: self.maxBatchDependsOnPrewarmedSize,
                                configuredPrewarmedPoolSize: self.configuredPrewarmedPoolSize,
                                metrics: self.metrics
                            ),
                            serviceDiscoveryPublisher: serviceDiscovery,
                            concurrentRequestCountStream: cloudboardProvider.concurrentRequestCountStream,
                            providerPause: cloudboardProvider.pause,
                            restartPrewarmedInstances: self.jobHelperInstanceProvider?.restartPrewarmedInstances
                        )
                        return "\(self.cloudAppName)::workloadController"
                    }
                }

                // When any of these tasks exit, they all do.
                let name = try await group.next()
                CloudBoardDaemon.logger
                    .log("\(name ?? "nil", privacy: .public) exited - cancelling everything else")
                group.cancelAll()
            }
        }
    }

    private static func runServer(
        cloudBoardProvider: CloudBoardProvider,
        providers: [CallHandlerProvider],
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        serviceAddress: SocketAddress,
        expectedPeerAPRNs: [APRN]?,
        keepalive: ServerConnectionKeepalive?,
        portPromise: Promise<Int, Error>? = nil,
        metricsSystem: MetricsSystem
    ) async throws {
        try await self.withEventLoopGroup { group in
            let server = try await self.runGRPCServer(
                group: group,
                providers: [cloudBoardProvider] + providers,
                identityCallback: identityCallback,
                serviceAddress: serviceAddress,
                expectedPeerAPRNs: expectedPeerAPRNs,
                keepalive: keepalive,
                portPromise: portPromise,
                metricsSystem: metricsSystem
            )

            try await withLifecycleManagementHandlers(label: "gRPC server") {
                try await withTaskCancellationHandler {
                    try await server.onClose.get()
                } onCancel: {
                    server.close(promise: nil)
                }
            } onDrain: {
                await cloudBoardProvider.drain()
            }
        }
    }

    private static func runGRPCServer(
        group: NIOTSEventLoopGroup,
        providers: [CallHandlerProvider],
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        serviceAddress: SocketAddress,
        expectedPeerAPRNs: [APRN]?,
        keepalive: ServerConnectionKeepalive?,
        portPromise: Promise<Int, Error>? = nil,
        metricsSystem: MetricsSystem
    ) async throws -> Server {
        let loggingLogger = Logging.Logger(
            osLogSubsystem: "com.apple.cloudos.cloudboard",
            osLogCategory: "cloudboardd",
            domain: "GRPCServer"
        )

        let server: Server

        CloudBoardDaemon.logger.log("Running GRPC service at \(serviceAddress, privacy: .public)")

        do {
            if let identityCallback {
                CloudBoardDaemon.logger.info("Running service with TLS.")
                let config = try GRPCTLSConfiguration.cloudboardProviderConfiguration(
                    identityCallback: identityCallback,
                    expectedPeerAPRNs: expectedPeerAPRNs,
                    metricsSystem: metricsSystem
                )
                var serverBuilder = Server.usingTLS(with: config, on: group)
                    .withServiceProviders(providers)
                    .withLogger(loggingLogger)
                if let keepalive {
                    CloudBoardDaemon.logger.info("Configuring GRPCServer keepalive")
                    serverBuilder = serverBuilder
                        .withKeepalive(keepalive)
                }
                server = try await serverBuilder.bind(host: serviceAddress.ipAddress!, port: serviceAddress.port!).get()
            } else {
                CloudBoardDaemon.logger.warning("Running service without TLS.")
                server = try await Server.insecure(group: group)
                    .withServiceProviders(providers)
                    .withLogger(loggingLogger)
                    .bind(host: serviceAddress.ipAddress!, port: serviceAddress.port!).get()
            }
        } catch {
            portPromise?.fail(with: error)
            throw error
        }

        portPromise?.succeed(with: server.channel.localAddress!.port!)

        CloudBoardDaemon.logger
            .info("Bound service at \(String(describing: server.channel.localAddress), privacy: .public)")

        return server
    }

    private static func withEventLoopGroup(_ operation: (NIOTSEventLoopGroup) async throws -> Void) async rethrows {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        do {
            try await operation(group)
            try? await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
