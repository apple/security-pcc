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

import AppleCertificates
internal import CloudBoardBridgeDAPI
import CloudBoardCommon
internal import CloudBoardDomain
import CloudBoardIdentity
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import NIOCore
import NIOTLS
import NIOTransportServices
import os
import PersistentHelperInstance
import PersistentServiceBridgeRouterAPI
internal import libnarrativecert

/// Long-lived daemon responsible for bridging calls from CloudBoard-managed processes to remote servers.
public struct CloudBoardBridgeDaemon: Sendable {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardBridgeDaemon"
    )

    private static let metricsClientName = "cb_bridged"

    private let eventLoopGroup: NIOTSEventLoopGroup
    private let apiServer: CloudBoardBridgeAPIServerProtocol
    private let nodeInfo: NodeInfo
    private let identityManager: IdentityManager?
    private let aquariaIdentityManager: IdentityManager?
    private let identityManagerConfig: SecureConfig.BridgeDaemonConfig.IdentityManagerConfig
    private let pirServiceClient: RunnablePIRServiceClientProtocol?
    private let pccToolGatewayClient: PCCToolGatewayClientProtocol?
    private let appleSigningServiceClient: BridgeAppleSigningServiceClientProtocol?
    private let cipCompanionServiceClient: BridgeCIPCompanionServiceClientProtocol?
    private let serviceDiscoverySubscriber: ServiceDiscoverySubscriberProtocol?
    private let persistentClientHelperManager: PersistentClientHelperManager?
    private let bridgeRouterClient: (any PersistentServiceBridgeRouterClientProtocol)?
    private let metricsSystem: MetricsSystem

    public init() throws {
        self.eventLoopGroup = NIOTSEventLoopGroup.singleton
        let secureConfig: SecureConfig
        do {
            secureConfig = try SecureConfigLoader.real.load()
        } catch {
            Self.logger.error("Error loading secure config: \(String(unredacted: error), privacy: .public)")
            throw error
        }
        self.nodeInfo = NodeInfo.load(secureConfig: secureConfig)
        let config = secureConfig.bridgeDaemonConfig
        self.apiServer = CloudBoardBridgeAPIXPCServer.localListener()
        self.metricsSystem = CloudMetricsSystem(clientName: Self.metricsClientName)

        let identityBackendType: IdentityBackendType
        if config.identityManager.useSelfSignedCertificate {
            Self.logger.info("Using self signed certs")
            identityBackendType = .selfsigned
        } else {
            identityBackendType = .narrative()
        }
        let identityManager = IdentityManager(
            metricsSystem: self.metricsSystem,
            metricProcess: "cb_bridged",
            identityBackendType: identityBackendType
        )
        self.identityManager = identityManager

        let aquariaIdentityBackendType: IdentityBackendType?
        if config.identityManager.useSelfSignedCertificate || secureConfig
            .disableAppleInfrastructureEnforcementForResearch {
            Self.logger.info("Using self signed certs")
            aquariaIdentityBackendType = .selfsigned
        } else {
            if let aquariaAPRN = config.identityManager.aquariaAPRN,
               let aquariaSanDNS = config.identityManager.aquariaSanDNS,
               let aquariaTag = config.identityManager.aquariaTag {
                aquariaIdentityBackendType = .narrative(
                    config: .init(
                        domain: .aquaria,
                        identityType: .host,
                        aprn: aquariaAPRN,
                        sanDNS: aquariaSanDNS,
                        tag: aquariaTag
                    )
                )
            } else {
                Self.logger.warning("""
                Config missing for configuring aquaria identity: 
                aquariaAPRN:\(config.identityManager.aquariaAPRN ?? "")
                aquariaSanDNS:\(config.identityManager.aquariaSanDNS ?? "")
                aquariaTag:\(config.identityManager.aquariaTag ?? "")
                """)
                aquariaIdentityBackendType = nil
            }
        }
        if let aquariaIdentityBackendType {
            let aquariaIdentityManager = IdentityManager(
                metricsSystem: self.metricsSystem,
                metricProcess: "cb_bridged",
                identityBackendType: aquariaIdentityBackendType
            )
            self.aquariaIdentityManager = aquariaIdentityManager
        } else {
            Self.logger.warning("aquariaIdentityManager not initialized")
            self.aquariaIdentityManager = nil
        }
        self.identityManagerConfig = config.identityManager

        self.pirServiceClient = Self.createPIRServiceClient(
            config: config.pirService,
            identityManager: identityManager,
            metricsSystem: self.metricsSystem
        )
        self.pccToolGatewayClient = try Self.createToolGatewayClient(
            eventLoopGroup: self.eventLoopGroup,
            config: config.toolGateway,
            identityManager: identityManager,
            nodeInfo: self.nodeInfo,
            metricsSystem: self.metricsSystem,
            isProxy: secureConfig.isProxy
        )
        self.appleSigningServiceClient = try Self.setupAppleSigningServiceClient(
            config: config,
            metricsSystem: self.metricsSystem
        )
        self.cipCompanionServiceClient = try Self.setupCIPCompanionServiceClient(
            config: config,
            metricsSystem: self.metricsSystem
        )

        // SD settings come from CloudBoardDConfiguration (shared with cloudboardd)
        // to ensure both processes use the same SD infrastructure.
        let platformSDConfig = Self.loadPlatformServiceDiscoveryConfig()
        let localNodeIP = Self.loadLocalNodeIP()

        let persistentClientHelperManager: PersistentClientHelperManager?
        let bridgeRouterClient: PersistentServiceBridgeRouterXPCClient?
        if secureConfig.persistentServiceClients.isEmpty {
            Self.logger.log("No persistentServiceClients configured; skipping PersistentClientHelperManager")
            persistentClientHelperManager = nil
            bridgeRouterClient = nil
        } else if let platformSDConfig {
            // TLS and backoff come from BridgeDaemon's dedicated persistent service config.
            // Cell ID comes from the shared platform config (same source as cloudboardd).
            let psConfig = config.persistentService

            // Create the helper instance provider for spawning cb_pclienthelper processes
            let helperInstanceProvider: PersistentHelperInstanceProvider?
            do {
                let launchdJobFinder = LaunchdJobFinder(metrics: self.metricsSystem)
                let pclientHelperJob = try launchdJobFinder.getJobDefinition(
                    type: .cbPClientHelper,
                    name: "cb_pclienthelper"
                )
                helperInstanceProvider = PersistentHelperInstanceProvider(
                    helperLaunchdJob: pclientHelperJob.definition,
                    helperXPCClientFactory: PersistentClientHelperXPCClientFactory(),
                    maxConcurrentInstances: config.persistentService?.maxConcurrentHelperInstances
                        ?? SecureConfig.defaultPersistentServiceMaxConcurrentHelperInstances
                )
            } catch {
                Self.logger.warning(
                    "Failed to find cb_pclienthelper job definition; helper spawning disabled: \(String(unredacted: error), privacy: .public)"
                )
                helperInstanceProvider = nil
            }

            if let helperInstanceProvider {
                // Create the control channel for pushing helper lifecycle events to the router
                let client = PersistentServiceBridgeRouterXPCClient(
                    machServiceName: "com.apple.cloudos.PrivateFilterClientRouter.bridge-control"
                )
                bridgeRouterClient = client

                // Build ServerVerification to validate cloudboardd's cert during TLS handshake.
                // Both cb_bridged and cloudboardd run on PCC (ACDC) compute nodes.
                let serverVerification: GRPCTLSConfiguration.ServerVerification?
                if psConfig?.tlsConfig?.enable != false {
                    let policyAPRNs: [PolicyAPRN] = [
                        GRPCTLSConfiguration.persistentServicePeerPolicyAPRN,
                    ]
                    serverVerification = GRPCTLSConfiguration.policyAPRNServerVerification(
                        expectedPolicyAPRNs: policyAPRNs,
                        metricsSystem: self.metricsSystem
                    )
                } else {
                    serverVerification = nil
                }

                persistentClientHelperManager = PersistentClientHelperManager(
                    eventLoopGroup: self.eventLoopGroup,
                    identityCallback: identityManager.identityCallback,
                    tlsConfig: .init(from: psConfig?.tlsConfig),
                    serverVerification: serverVerification,
                    isolationDomain: secureConfig.isolationDomain ?? "default",
                    cellID: platformSDConfig.cellID,
                    localNodeIP: localNodeIP,
                    connectionBackoffStrategy: Self.makeBackoffStrategy(from: psConfig?.backoffConfig),
                    // 10s keepalive matches the server-side PersistentServiceProvider default
                    keepaliveInterval: psConfig?.keepaliveIntervalSeconds.map { .seconds($0) } ?? .seconds(10),
                    // 30s idle timeout: 3 missed keepalives before declaring the connection dead
                    idleTimeout: psConfig?.idleTimeoutSeconds.map { .seconds($0) } ?? .seconds(30),
                    // 1 min hard cap on drain wait — the per-query drain-complete signal
                    // should fire in seconds; 1 min covers legitimate slow drains and
                    // tightens recovery to within a key-rotation window.
                    drainCompleteWaitTimeout: psConfig?.drainCompleteWaitTimeoutSeconds
                        .map { .seconds($0) } ?? .seconds(60),
                    // 1 min hard cap on how long the old stream keeps serving while the
                    // replacement establishes; on expiry we drain the old stream anyway.
                    replacementReadyWaitTimeout: psConfig?.replacementReadyWaitTimeoutSeconds
                        .map { .seconds($0) } ?? .seconds(60),
                    // Outer timeout on a single connection-establishment attempt;
                    // gRPC's own maxWaitTime has been observed not to bound real-
                    // world failures so we wrap with structured cancellation.
                    connectionEstablishmentTimeout: psConfig?.connectionEstablishmentTimeoutSeconds
                        .map { .seconds($0) } ?? .seconds(15),
                    // HTTP/2 keepalive PING/timeout. Defaults centralized
                    // in SecureConfig and validated at parse so the
                    // `timeout < interval` invariant is enforced before
                    // we get here.
                    http2KeepalivePingInterval: psConfig?.http2KeepalivePingIntervalSeconds
                        .map { .seconds($0) }
                        ?? .seconds(
                            SecureConfig.defaultPersistentServiceHttp2KeepalivePingIntervalSeconds
                        ),
                    http2KeepalivePongTimeout: psConfig?.http2KeepalivePongTimeoutSeconds
                        .map { .seconds($0) }
                        ?? .seconds(
                            SecureConfig.defaultPersistentServiceHttp2KeepalivePongTimeoutSeconds
                        ),
                    metricsSystem: self.metricsSystem,
                    helperInstanceProvider: helperInstanceProvider,
                    bridgeRouterClient: client,
                    requireMTLS: secureConfig.shouldEnforceAppleInfrastructureSecurityConfig,
                    maxServersPerUnit: psConfig?.maxServersPerUnit,
                    swapOnFailureThreshold: psConfig?.swapOnFailureThreshold ?? [:],
                    blockedCapabilities: Set(psConfig?.blockedCapabilities ?? [])
                )
                Self.logger.log(
                    "PersistentClientHelperManager constructed for serviceClients=\(secureConfig.persistentServiceClients, privacy: .public)"
                )
            } else {
                Self.logger.error(
                    "helperInstanceProvider unavailable; PersistentClientHelperManager not started — no cb_pclienthelper instances will be launched"
                )
                persistentClientHelperManager = nil
                bridgeRouterClient = nil
            }
        } else {
            Self.logger.warning(
                "persistentServiceClients configured but platform ServiceDiscovery config is missing; skipping PersistentClientHelperManager"
            )
            persistentClientHelperManager = nil
            bridgeRouterClient = nil
        }
        self.persistentClientHelperManager = persistentClientHelperManager
        self.bridgeRouterClient = bridgeRouterClient

        self.serviceDiscoverySubscriber = try Self.createServiceDiscoverySubscriber(
            eventLoopGroup: self.eventLoopGroup,
            platformSDConfig: platformSDConfig,
            serviceNames: secureConfig.persistentServiceClients,
            identityManager: identityManager,
            metricsSystem: self.metricsSystem,
            persistentClientHelperManager: persistentClientHelperManager
        )
    }

    // For testing only
    init(
        eventLoopGroup: NIOTSEventLoopGroup = NIOTSEventLoopGroup.singleton,
        apiServer: CloudBoardBridgeAPIServerProtocol,
        nodeInfo: NodeInfo,
        identityManager: IdentityManager?,
        aquariaIdentityManager: IdentityManager?,
        identityManagerConfig: SecureConfig.BridgeDaemonConfig
            .IdentityManagerConfig = .init(useSelfSignedCertificate: true),
        pirServiceClient: RunnablePIRServiceClientProtocol?,
        pccToolGatewayClient: PCCToolGatewayClientProtocol?,
        appleSigningServiceClient: BridgeAppleSigningServiceClientProtocol?,
        cipCompanionServiceClient: BridgeCIPCompanionServiceClientProtocol?,
        serviceDiscoverySubscriber: ServiceDiscoverySubscriberProtocol? = nil,
        persistentClientHelperManager: PersistentClientHelperManager? = nil,
        bridgeRouterClient: (any PersistentServiceBridgeRouterClientProtocol)? = nil,
        metricsSystem: MetricsSystem
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.apiServer = apiServer
        self.nodeInfo = nodeInfo
        self.identityManager = identityManager
        self.aquariaIdentityManager = aquariaIdentityManager
        self.identityManagerConfig = identityManagerConfig
        self.pirServiceClient = pirServiceClient
        self.pccToolGatewayClient = pccToolGatewayClient
        self.appleSigningServiceClient = appleSigningServiceClient
        self.cipCompanionServiceClient = cipCompanionServiceClient
        self.serviceDiscoverySubscriber = serviceDiscoverySubscriber
        self.persistentClientHelperManager = persistentClientHelperManager
        self.bridgeRouterClient = bridgeRouterClient
        self.metricsSystem = metricsSystem
    }

    public func run() async throws {
        do {
            Self.logger.log("Starting.")
            if let isLeader = NodeInfo.isLeader() {
                if !isLeader {
                    Self.logger.log("Not a leader node. Exiting.")
                    Foundation.exit(0)
                }
            } else {
                Self.logger.error("Unable to check if node is a leader. Continuing.")
            }

            if let aquariaIdentityManager = self.aquariaIdentityManager {
                try await aquariaIdentityManager.waitForInitialIdentity(
                    backoffStrategy: Self.makeBackoffStrategy(from: self.identityManagerConfig.aquariaIdentityBackoff)
                )
            }

            if let appleSigningServiceClient = self.appleSigningServiceClient {
                if let aquariaIdentityManager = self.aquariaIdentityManager {
                    await appleSigningServiceClient.updateCredentialProvider(
                        identityManager: aquariaIdentityManager
                    )
                } else {
                    Self.logger.warning(
                        "Aquaria Identity missing, not updating apple signing service client credential provider"
                    )
                }
            }

            if let cipCompanionServiceClient = self.cipCompanionServiceClient {
                if let aquariaIdentityManager = self.aquariaIdentityManager {
                    await cipCompanionServiceClient.updateCredentialProvider(
                        identityManager: aquariaIdentityManager
                    )
                } else {
                    Self.logger.warning(
                        "Aquaria Identity missing, not updating cip companion service client credential provider"
                    )
                }
            }

            try await CloudBoardMetrics.Uptime.withStandardMetrics(
                processInfo: Metrics.ProcessInfo.self,
                metrics: self.metricsSystem
            ) {
                try await self._run()
            }
        } catch {
            do {
                try await self.cleanUp()
            } catch {
                Self.logger.error("Error during cleanup: \(String(unredacted: error), privacy: .public)")
            }
            throw error
        }
    }

    private func _run() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            if let identityManager = self.identityManager {
                group.addTask {
                    await identityManager.identityUpdateLoop()
                    return "IdentityManagerUpdateLoop"
                }
            }

            if let aquariaIdentityManager = self.aquariaIdentityManager {
                group.addTask {
                    await aquariaIdentityManager.identityUpdateLoop()
                    return "aquariaIdentityManagerUpdateLoop"
                }
            }

            if let pirServiceClient = self.pirServiceClient {
                group.addTask {
                    try await pirServiceClient.run()
                    return "PIRServiceClient"
                }
            }

            // Start the control channel client for pushing helper lifecycle events
            // to PrivateFilterClientRouter. Started before service discovery so the
            // connection is ready when helpers start appearing.
            // At the moment there is a single persistent service, in the future
            // we might have many, which will require a router per service.
            if let bridgeRouterClient = self.bridgeRouterClient {
                await bridgeRouterClient.activate()
            }

            if let serviceDiscoverySubscriber = self.serviceDiscoverySubscriber {
                group.addTask {
                    try await serviceDiscoverySubscriber.run()
                    return "ServiceDiscoverySubscriber"
                }
            }

            if let persistentClientHelperManager = self.persistentClientHelperManager {
                group.addTask {
                    try await persistentClientHelperManager.runEmitDiscoveredInstancesMetricsLoop()
                    return "EmitDiscoveredInstancesMetricsLoop"
                }
            }

            group.addTask {
                try await CloudBoardBridgeServer(
                    apiServer: self.apiServer,
                    pirServiceClient: self.pirServiceClient,
                    pccToolGatewayClient: self.pccToolGatewayClient,
                    appleSigningServiceClient: self.appleSigningServiceClient,
                    cipCompanionServiceClient: self.cipCompanionServiceClient
                ).run()
                return "CloudBoardBridgeServer"
            }

            group.addTask {
                try await runEmitMemoryUsageMetricsLoop(
                    logger: Self.logger,
                    metricsSystem: self.metricsSystem,
                    physicalMemoryFootprintGauge: {
                        Metrics.CloudBoardBridgeDaemon.PhysicalMemoryFootprintGauge(value: $0)
                    },
                    lifetimeMaxPhysicalMemoryFootprintGauge: {
                        Metrics.CloudBoardBridgeDaemon.LifetimeMaxPhysicalMemoryFootprintGauge(value: $0)
                    }
                )
                return "EmitMemoryUsageMetricsLoop"
            }

            let taskName = try await group.next()
            Self.logger.log("\(taskName ?? "nil", privacy: .public) exited. Cancelling other tasks.")

            group.cancelAll()
        }
    }

    private static func createPIRServiceClient(
        config: SecureConfig.BridgeDaemonConfig.PIRServiceConfig?,
        identityManager: IdentityManager,
        metricsSystem: MetricsSystem
    ) -> RunnablePIRServiceClientProtocol? {
        if let config {
            let identityManagerForPIR: IdentityManager? = if config.enableMTLS {
                identityManager
            } else {
                nil
            }

            #if canImport(CipherMLSE)
            return PIRServiceGRPCClient(
                serverURL: config.serviceURL,
                kfedService: config.kfedServiceName,
                identityManager: identityManagerForPIR,
                keepaliveInterval: config.keepaliveInterval.map { .seconds($0) },
                attemptCount: config.attemptCount,
                retryDelay: config.retryDelay,
                requestTimeout: config.requestTimeout,
                metricsSystem: metricsSystem
            )
            #else
            Self.logger.warning("PIR service client not set due to missing CipherMLSE")
            return nil
            #endif
        } else {
            Self.logger.log("PIR service client not configured")
            return nil
        }
    }

    private static func createToolGatewayClient(
        eventLoopGroup: NIOTSEventLoopGroup,
        config: SecureConfig.BridgeDaemonConfig.ToolGatewayServiceConfig?,
        identityManager: IdentityManager,
        nodeInfo: NodeInfo,
        metricsSystem: MetricsSystem,
        isProxy: Bool
    ) throws -> PCCToolGatewayClientProtocol? {
        guard isProxy else {
            self.logger.log("Tool gateway client not initialized (node is not a proxy)")
            return nil
        }
        if let config {
            let policyAPRNs = try config.targetPolicyAPRNs?.map { try PolicyAPRN(string: $0) }
            return try PCCToolGatewayClient(
                eventLoopGroup: eventLoopGroup,
                nodeInfo: nodeInfo,
                targetHost: config.targetHost,
                targetPort: config.targetPort,
                tlsConfig: .init(from: config.tlsConfig),
                backOffConfig: .init(from: config.backoffConfig),
                idleTimeout: TimeAmount.seconds(Int64(config.idleTimeoutSeconds ?? 30 * 60)),
                identityCallback: identityManager.identityCallback,
                targetPolicyAPRNs: policyAPRNs,
                metricsSystem: metricsSystem
            )
        } else {
            Self.logger.log("Tool gateway client not initialized (missing config)")
            return nil
        }
    }

    private static func setupAppleSigningServiceClient(
        config: SecureConfig.BridgeDaemonConfig,
        metricsSystem: MetricsSystem
    ) throws -> BridgeAppleSigningServiceClientProtocol? {
        if let config = config.appleSigningService {
            return try BridgeAppleSigningServiceClient(config: config, metricsSystem: metricsSystem)
        } else {
            Self.logger.log("Apple signing service client not initialized (missing config)")
            return nil
        }
    }

    private static func setupCIPCompanionServiceClient(
        config: SecureConfig.BridgeDaemonConfig,
        metricsSystem: MetricsSystem
    ) throws -> BridgeCIPCompanionServiceClientProtocol? {
        if let config = config.cipCompanionService {
            return try BridgeCIPCompanionServiceClient(config: config, metricsSystem: metricsSystem)
        } else {
            Self.logger.log("CIP companion service client not initialized (missing config)")
            return nil
        }
    }

    private static func createServiceDiscoverySubscriber(
        eventLoopGroup: NIOTSEventLoopGroup,
        platformSDConfig: CloudBoardDConfiguration.ServiceDiscovery?,
        serviceNames: [String],
        identityManager: IdentityManager,
        metricsSystem: MetricsSystem,
        persistentClientHelperManager: PersistentClientHelperManager? = nil
    ) throws -> ServiceDiscoverySubscriberProtocol? {
        guard let platformSDConfig else {
            if !serviceNames.isEmpty {
                self.logger.warning(
                    "persistentServiceClients configured but ServiceDiscovery config is missing; skipping subscriptions"
                )
            }
            return nil
        }
        guard !serviceNames.isEmpty else {
            Self.logger.log("No persistentServiceClients configured; skipping ServiceDiscovery subscriptions")
            return nil
        }

        let onInstancesChanged: (
            @Sendable (String, [Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_InstanceInfo]) async
                -> Void
        )? = if let manager = persistentClientHelperManager {
            { serviceName, instances in
                await manager.handleInstancesChanged(serviceName: serviceName, instances: instances)
            }
        } else {
            nil
        }

        return try ServiceDiscoverySubscriber(
            eventLoopGroup: eventLoopGroup,
            config: .init(from: platformSDConfig),
            serviceNames: serviceNames,
            identityCallback: identityManager.identityCallback,
            metricsSystem: metricsSystem,
            onInstancesChanged: onInstancesChanged
        )
    }

    private func cleanUp() async throws {
        if let pccToolGatewayClient = self.pccToolGatewayClient {
            try await pccToolGatewayClient.shutdown()
        }
        if let persistentClientHelperManager = self.persistentClientHelperManager {
            await persistentClientHelperManager.teardownAllNodes()
        }
    }

    /// Loads the SD config from the shared CloudBoardD configuration (same source as cloudboardd).
    private static func loadPlatformServiceDiscoveryConfig() -> CloudBoardDConfiguration.ServiceDiscovery? {
        do {
            let platformConfig = try CloudBoardDConfiguration.fromPreferences()
            return platformConfig.serviceDiscovery
        } catch {
            self.logger.warning(
                "Failed to load CloudBoardDConfiguration for service discovery: \(String(unredacted: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Loads the local node's IP from the shared CloudBoardD GRPC configuration.
    private static func loadLocalNodeIP() -> String? {
        do {
            let platformConfig = try CloudBoardDConfiguration.fromPreferences()
            return platformConfig.grpc?.listeningIP
        } catch {
            self.logger.warning(
                "Failed to load CloudBoardDConfiguration for local node IP: \(String(unredacted: error), privacy: .public)"
            )
            return nil
        }
    }

    private static func makeBackoffStrategy(
        from backoffConfig: SecureConfig.BridgeDaemonConfig.ConnectionBackoff?
    ) -> ExponentialBackoffStrategy {
        // Defaults match the gRPC standard backoff parameters used by ServiceDiscoverySubscriber
        // and other CloudBoard gRPC clients: start at 1s, scale by 1.6x up to 2min, with 20% jitter.
        let initialSeconds = backoffConfig?.initial ?? 1.0
        let maxSeconds = backoffConfig?.maximum ?? 120.0
        return ExponentialBackoffStrategy(
            initialDelay: .milliseconds(Int((initialSeconds * 1000).rounded())),
            multiplier: backoffConfig?.factor ?? 1.6,
            maxDelay: .milliseconds(Int((maxSeconds * 1000).rounded())),
            jitterPercent: backoffConfig?.jitterPercent ?? 0.2
        )
    }
}

extension GRPCClientConfiguration.TLSConfiguration {
    init(from tlsConfig: SecureConfig.BridgeDaemonConfig.TLSConfiguration?) {
        if let tlsConfig {
            self = GRPCClientConfiguration.TLSConfiguration(
                enable: tlsConfig.enable ?? true,
                sniOverride: tlsConfig.sniOverride,
                enablemTLS: tlsConfig.enablemTLS
            )
        } else {
            self = GRPCClientConfiguration.TLSConfiguration(
                enable: true,
                enablemTLS: true
            )
        }
    }
}

extension GRPCClientConfiguration.ConnectionBackoff {
    init(from backOffConfig: SecureConfig.BridgeDaemonConfig.ConnectionBackoff?) {
        if let backOffConfig {
            self = GRPCClientConfiguration.ConnectionBackoff(
                initial: backOffConfig.initial,
                maximum: backOffConfig.maximum,
                factor: backOffConfig.factor,
                jitterPercent: backOffConfig.jitterPercent,
                coolDown: backOffConfig.coolDown
            )
        } else {
            self = GRPCClientConfiguration.ConnectionBackoff(
                initial: 1.0,
                maximum: 120.0,
                factor: 1.6,
                jitterPercent: 0.2,
                coolDown: nil
            )
        }
    }
}

public enum CloudBoardBridgeDaemonError: ReportableError {
    case identityManagerConfigureIdentityConfigMissing

    public var publicDescription: String {
        switch self {
        case .identityManagerConfigureIdentityConfigMissing: "identityManagerConfigureIdentityConfigMissing"
        }
    }
}
