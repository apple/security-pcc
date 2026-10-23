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
import CloudAttestationV2
import CloudBoardConfiguration
import CloudBoardControllerCore
import CloudBoardJobCore
import CloudBoardJobHelperCore
import CloudBoardUtilities
import Configuration
import GRPCAppleMTLS
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCServiceLifecycle
import Logging
import Metrics
import NIOCertificateReloading
import OTel
import ServiceDiscoveryPublisher
import ServiceLifecycle

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct CloudBoardServerConfiguration: Sendable {
    let listeningIP: String?
    let listeningPort: Int
}

enum CloudBoardServerError: Error {
    case couldNotResolveIP
    case invalidConfig(String)
}

extension CloudBoardServerError: ReportableError {
    var publicDescription: String {
        switch self {
        case .couldNotResolveIP: "CloudBoardServerError.couldNotResolveIP"
        case .invalidConfig(let message): "CloudBoardServerError.invalidConfig(\(message))"
        }
    }
}

private let cloudBoardServerLogger = Logger(label: "cloudboardd.CloudBoardServer")

public struct CloudBoardServer<IdleClock: Clock>: Sendable where IdleClock.Duration == Duration {
    private static var logger: Logger { cloudBoardServerLogger }

    private let attestedConfigReader: ConfigReader
    private let unattestedConfigReader: ConfigReader
    private let metricsFactory: any MetricsFactory
    /// Clock the per-request idle watchdog observes. Production callers leave
    /// this at `ContinuousClock`; tests inject a deterministic clock to drive
    /// the watchdog without depending on real time.
    private let idleClock: IdleClock
    /// Test-only attestation and key provider. Only injected in tests.
    private let testOnlyAttestationProvider:
        (any AttestationProvider & AttestedKeyProvider & RequestEncryptionKeyResolver)?

    public init(
        attestedConfigReader: ConfigReader,
        unattestedConfigReader: ConfigReader,
        metricsFactory: any MetricsFactory = MetricsSystem.factory,
        idleClock: IdleClock = ContinuousClock()
    ) {
        self.attestedConfigReader = attestedConfigReader
        self.unattestedConfigReader = unattestedConfigReader
        self.metricsFactory = metricsFactory
        self.idleClock = idleClock
        self.testOnlyAttestationProvider = nil
    }

    /// Test-only initialiser that lets a caller supply a provider that fulfils all three attestation
    /// interfaces at once
    package init(
        attestedConfigReader: ConfigReader,
        unattestedConfigReader: ConfigReader,
        metricsFactory: any MetricsFactory = MetricsSystem.factory,
        idleClock: IdleClock = ContinuousClock(),
        testOnlyAttestationProvider: any AttestationProvider & AttestedKeyProvider & RequestEncryptionKeyResolver
    ) {
        self.attestedConfigReader = attestedConfigReader
        self.unattestedConfigReader = unattestedConfigReader
        self.metricsFactory = metricsFactory
        self.idleClock = idleClock
        self.testOnlyAttestationProvider = testOnlyAttestationProvider
    }

    public func run(otelServices: [Service]) async throws {
        let cloudAppWarmupPool = bootstrapCloudAppWarmupPool()

        let staticControllerConfiguration = try ControllerProvidedConfiguration(
            configReader: self.unattestedConfigReader
        )

        let serviceStatusMonitor =
            staticControllerConfiguration.map {
                ServiceStatusMonitor(
                    controllerProvidedConfiguration: $0,
                    configReader: self.unattestedConfigReader,
                    cloudAppWarmupPool: cloudAppWarmupPool,
                    metricsFactory: self.metricsFactory
                )
            }
            ?? ServiceStatusMonitor(
                configReader: self.unattestedConfigReader,
                cloudAppWarmupPool: cloudAppWarmupPool,
                metricsFactory: self.metricsFactory
            )

        try await ControllerListener.withControllerListener(
            configReader: self.unattestedConfigReader,
            statusMonitor: serviceStatusMonitor,
            skipExternal: staticControllerConfiguration != nil
        ) { controllerListener in
            let listeningAddress = try await self.determinePreferredListeningAddress()
            let identityManager = CloudBoardIdentityManager(
                attestedConfigReader: self.attestedConfigReader,
                unattestedConfigReader: self.unattestedConfigReader
            )

            // Forwards the ServiceGroup's graceful-shutdown signal to the SD task below, which
            // otherwise can't observe the signal because it lives outside the group).
            let shutdownSignal = AsyncValueBox<Void>()

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Task 1: Start gRPC server immediately.
                // HealthService reports .initializing until the workload registers and
                // the controller sends setState(.ready).
                group.addTask {
                    try await self.runCloudBoardService(
                        listeningIP: listeningAddress.ip,
                        listeningPort: Int(listeningAddress.port),
                        cloudAppWarmupPool: cloudAppWarmupPool,
                        identityManager: identityManager,
                        serviceStatusMonitor: serviceStatusMonitor,
                        otelServices: otelServices,
                        shutdownSignal: shutdownSignal,
                        metricsFactory: self.metricsFactory
                    )
                }

                // Task 2: Obtain controller-provided configuration — either from the static
                // config override (dev/test) or by waiting for the external controller to
                // register the workload (production) — then update load config and announce
                // to service discovery. Runs concurrently with the gRPC server (Task 1).
                group.addTask {
                    var controllerProvidedConfiguration: ControllerProvidedConfiguration
                    if let staticControllerConfiguration {
                        // Dev/test only: static config override, no external controller.
                        // Transition to ready immediately since no external controller
                        // will send setState(.ready).
                        Self.logger.info(
                            "Using controller configuration overrides and not the external controller."
                        )
                        await serviceStatusMonitor.updateWorkloadState(.ready)
                        controllerProvidedConfiguration = staticControllerConfiguration
                    } else {
                        // Production: block until the external controller registers the workload.
                        Self.logger.info("Waiting for the controller to provide workload configuration.")
                        let (workloadProperties, computeWorkloadConfig) =
                            try await controllerListener.waitForWorkloadRegistration()
                        controllerProvidedConfiguration = ControllerProvidedConfiguration(
                            computeWorkloadConfig: computeWorkloadConfig,
                            workloadProperties: workloadProperties
                        )
                        Self.logger.info("Received workload configuration from the controller.")
                        if let overriddenConfiguration = try ControllerProvidedConfiguration(
                            baseConfiguration: controllerProvidedConfiguration,
                            configReader: self.unattestedConfigReader
                        ) {
                            Self.logger.info("Controller configuration partially overridden.")
                            controllerProvidedConfiguration = overriddenConfiguration
                        }

                        // Update load config from the registration response. For the dev/test path
                        // this is unnecessary — the monitor was already initialized with the
                        // override config at construction time.
                        serviceStatusMonitor.updateLoadConfiguration(
                            controllerProvidedConfiguration.computeWorkloadConfig
                        )
                    }

                    let serviceDiscoveryConfig = try ServiceDiscoveryConfiguration(
                        attestedConfigReader: self.attestedConfigReader,
                        unattestedConfigReader: self.unattestedConfigReader,
                        controllerProvidedConfiguration: controllerProvidedConfiguration
                    )
                    guard let serviceDiscoveryConfig else {
                        Self.logger.warning("No service discovery configured. Skipping registration.")
                        serviceStatusMonitor.updateComponentState(
                            name: ServiceStatusMonitor.ComponentName.serviceDiscovery,
                            status: .ready
                        )
                        return
                    }
                    let sdPublisher: CloudBoardServiceDiscoveryPublisher
                    do {
                        sdPublisher = try await CloudBoardServiceDiscoveryPublisher(
                            config: serviceDiscoveryConfig,
                            identityManager: identityManager
                        )
                    } catch {
                        serviceStatusMonitor.updateComponentState(
                            name: ServiceStatusMonitor.ComponentName.serviceDiscovery,
                            status: .terminalError(message: "Service discovery configuration failed")
                        )
                        throw error
                    }
                    try await sdPublisher.withGRPCClient { grpcClient in
                        try await CloudBoardServiceDiscoveryPublisher.withServiceDiscoveryRetry(
                            statusMonitor: serviceStatusMonitor,
                            degradedGracePeriod: .seconds(serviceDiscoveryConfig.degradedGracePeriodSeconds)
                        ) {
                            try await CloudBoardServiceDiscoveryPublisher.withConnectMetrics { onConnected in
                                try await sdPublisher.withServiceDiscoveryPublisher(
                                    grpcClient: grpcClient,
                                    serviceAddress: listeningAddress
                                ) { publisher in
                                    try publisher.announceCloudBoardService(
                                        config: serviceDiscoveryConfig,
                                        bootID: sdPublisher.bootID
                                    )
                                    onConnected()
                                    serviceStatusMonitor.updateComponentState(
                                        name: ServiceStatusMonitor.ComponentName.serviceDiscovery,
                                        status: .ready
                                    )
                                    // Hold until cp-agent drains (.drained) or a shutdown signal arrives.
                                    // Unblocking on .drained ensures SD deregisters as soon as all in-flight requests
                                    // finish, before the process exits.
                                    try await withThrowingTaskGroup(of: Void.self) { group in
                                        group.addTask {
                                            for await status in serviceStatusMonitor.watch() {
                                                if case .drained = status.aggregateState { return }
                                            }
                                        }
                                        // Triggered by SIGTERM/SIGINT via GracefulShutdownForwarder. Needed because
                                        // this lives outside of the service group.
                                        group.addTask { _ = try? await shutdownSignal.get() }
                                        _ = try await group.next()
                                        group.cancelAll()
                                    }
                                }
                            }
                        }
                    }
                }

                try await group.waitForAll()
            }
        }
    }

    private func bootstrapCloudAppWarmupPool() -> CloudAppWarmupPool {
        // The following config keys used to select alternate request-handling paths that have
        // since been removed. Warn (but don't fail) if any are set so operators / test setups
        // can be updated to the jobhelper-only path.
        let inCloudBoardProcessCloudApp = self.attestedConfigReader.bool(
            forKey: "development.cloudapp.incloudboardprocess"
        )
        let useJobHelper = self.attestedConfigReader.bool(
            forKey: "request.handler.use_jobhelper"
        )
        let devModeCloudAppPort = self.unattestedConfigReader.int(
            forKey: "development.cloudboard.destination.cloudapp.port"
        )
        if inCloudBoardProcessCloudApp != nil || useJobHelper != nil || devModeCloudAppPort != nil {
            Self.logger.warning(
                "CloudApp was requested to run in an unsupported mode; these keys are ignored.",
                metadata: [
                    "development.cloudapp.incloudboardprocess":
                        "\(inCloudBoardProcessCloudApp.map { "\($0)" } ?? "unset")",
                    "request.handler.use_jobhelper":
                        "\(useJobHelper.map { "\($0)" } ?? "unset")",
                    "development.cloudboard.destination.cloudapp.port":
                        "\(devModeCloudAppPort.map { "\($0)" } ?? "unset")",
                ]
            )
        }

        let jobHelperSocketPath = self.unattestedConfigReader.string(
            forKey: "jobhelper.socket_path",
            default: "/run/cb-jobhelper/cb-jobhelper.sock"
        )
        let cloudAppSocket = SocketAddress.UnixDomainSocket(
            path: self.unattestedConfigReader.string(
                forKey: "cloudapp.activation.uds",
                default: "/run/tie-cloud-app/tie-cloud-app.sock"
            )
        )
        return CloudAppWarmupPool(
            cloudAppSocket: cloudAppSocket,
            jobHelperSocketPath: jobHelperSocketPath,
            configReader: self.unattestedConfigReader,
            metricsFactory: self.metricsFactory
        )
    }

    private func runCloudBoardService(
        listeningIP: String,
        listeningPort: Int,
        cloudAppWarmupPool: CloudAppWarmupPool,
        identityManager: CloudBoardIdentityManager,
        serviceStatusMonitor: ServiceStatusMonitor,
        otelServices: [Service],
        shutdownSignal: AsyncValueBox<Void>,
        metricsFactory: any MetricsFactory
    ) async throws {
        let attestationProvider: any AttestationProvider
        let attestedKeyProvider: any AttestedKeyProvider
        let requestEncryptionKeyResolver: any RequestEncryptionKeyResolver
        var grpcAttestedKeyProviderService: GRPCAttestedKeyProviderService?

        if let provider = self.testOnlyAttestationProvider {
            Self.logger.info("Using test-only attestation override. Skipping connecting to cb_attestationd.")
            attestationProvider = provider
            attestedKeyProvider = provider
            requestEncryptionKeyResolver = provider
            // Nothing drives the attestation subcomponent under the override, so mark it ready immediately
            serviceStatusMonitor.updateComponentState(
                name: ServiceStatusMonitor.ComponentName.attestation,
                status: .ready
            )
        } else {
            let attestationUdsPath = self.unattestedConfigReader.string(
                forKey: "attestation.grpc.uds",
                default: "/var/run/cb-attestationd/cb-attestationd.sock"
            )
            Self.logger.info("Using gRPC attestation provider", metadata: ["uds": "\(attestationUdsPath)"])
            let kpsSocketPath = self.unattestedConfigReader.string(
                forKey: "attestation.kps_socket_path",
                default: "/run/container_launcher/kmaserver.sock"
            )
            let attestationSocketPath = self.unattestedConfigReader.string(
                forKey: "attestation.attestation_socket_path",
                default: "/run/container_launcher/teeserver.sock"
            )
            // Auto-detect: if real WSD sockets exist, use them directly;
            // otherwise use the simulator socket paths.
            let effectiveKpsSocketPath: String
            let effectiveAttestationSocketPath: String
            if Self.socketExists(atPath: kpsSocketPath) && Self.socketExists(atPath: attestationSocketPath) {
                Self.logger.info(
                    "Auto-detected WSD sockets for key lookup",
                    metadata: [
                        "kpsSocketPath": "\(kpsSocketPath)",
                        "attestationSocketPath": "\(attestationSocketPath)",
                    ]
                )
                effectiveKpsSocketPath = kpsSocketPath
                effectiveAttestationSocketPath = attestationSocketPath
            } else {
                let simKps = self.unattestedConfigReader.string(
                    forKey: "attestation.simulated_kps_socket_path",
                    default: "/run/sim_container_launcher/kmaserver.sock"
                )
                let simAttestation = self.unattestedConfigReader.string(
                    forKey: "attestation.simulated_attestation_socket_path",
                    default: "/run/sim_container_launcher/teeserver.sock"
                )
                Self.logger.info(
                    "WSD sockets not found, using simulator socket paths for key lookup",
                    metadata: [
                        "kpsSocketPath": "\(simKps)",
                        "attestationSocketPath": "\(simAttestation)",
                    ]
                )
                effectiveKpsSocketPath = simKps
                effectiveAttestationSocketPath = simAttestation
            }
            // Create a KeyStore pointing at the effective socket paths
            let keyStore = CloudAttestationV2.KeyStoreConfiguration
                .gcpV1(
                    kpsSocketPath: effectiveKpsSocketPath,
                    attestationSocketPath: effectiveAttestationSocketPath
                )
                .makeKeyStore()
            let provider = GRPCAttestedKeyProvider(keyStore: keyStore)
            let service = GRPCAttestedKeyProviderService(
                udsPath: attestationUdsPath,
                provider: provider,
                statusMonitor: serviceStatusMonitor
            )
            grpcAttestedKeyProviderService = service
            attestationProvider = provider
            attestedKeyProvider = provider
            requestEncryptionKeyResolver = provider
        }

        let sessionStore = SessionStore(attestationProvider: attestationProvider, metricsFactory: metricsFactory)

        let cloudBoardService = CloudBoardService(
            configReader: self.unattestedConfigReader,
            statusMonitor: serviceStatusMonitor,
            attestationProvider: attestationProvider,
            attestedKeyProvider: attestedKeyProvider,
            sessionStore: sessionStore,
            requestEncryptionKeyResolver: requestEncryptionKeyResolver,
            cloudAppWarmupPool: cloudAppWarmupPool,
            metricsFactory: metricsFactory,
            idleClock: self.idleClock
        )
        let healthService = HealthService(statusMonitor: serviceStatusMonitor)
        let statusMetricsService = StatusMetricsService(
            statusMonitor: serviceStatusMonitor,
            metricsFactory: metricsFactory
        )
        let warmupPoolMetricsService = WarmupPoolMetricsService(
            warmupPool: cloudAppWarmupPool,
            metricsFactory: metricsFactory
        )
        let credentialExpiryMetricsService = CredentialExpiryMetricsService(
            attestationProvider: attestationProvider,
            identityCertificateExpiryProvider: identityManager,
            metricsFactory: metricsFactory
        )
        let cpAgentStatusReporterConfig = CPAgentStatusReporterConfiguration(configReader: self.unattestedConfigReader)
        let cpAgentStatusReporter: CPAgentStatusReporter<HTTP2ClientTransport.Posix>?
        if cpAgentStatusReporterConfig.enabled {
            cpAgentStatusReporter = try CPAgentStatusReporter(
                statusMonitor: serviceStatusMonitor,
                configuration: cpAgentStatusReporterConfig
            )
        } else {
            Self.logger.info("CPAgentStatusReporter disabled, skipping")
            cpAgentStatusReporter = nil
        }

        let drainConfig = CPAgentDrainSubscriberConfiguration(configReader: self.unattestedConfigReader)
        let cpAgentDrainSubscriber: CPAgentDrainSubscriber<HTTP2ClientTransport.Posix>?
        if drainConfig.enabled {
            cpAgentDrainSubscriber = try CPAgentDrainSubscriber(
                statusMonitor: serviceStatusMonitor,
                configuration: drainConfig
            )
        } else {
            Self.logger.info("CPAgentDrainSubscriber disabled, skipping")
            cpAgentDrainSubscriber = nil
        }

        Self.logger.info(
            "Starting CloudBoard gRPC server",
            metadata: [
                "listeningIP": "\(listeningIP)",
                "listeningPort": "\(listeningPort)",
                "hostname": "\(ProcessInfo.processInfo.hostName)",
            ]
        )
        let identitySource = try await identityManager.identitySource
        var serverConfig = HTTP2ServerTransport.Posix.Config.defaults
        serverConfig.http2.targetWindowSize = self.unattestedConfigReader.int(
            forKey: "grpc.http2.targetwindowsize",
            // Should be configured to match max request payload size * max concurrent request limit/batch size.
            // 8 * 75 MB = 600 MB
            default: 629_145_600  // 600 MB
        )
        serverConfig.http2.maxFrameSize = self.unattestedConfigReader.int(
            forKey: "grpc.http2.maxframesize",
            // Should be configured to match max message size + some overhead. With application layer chunking, we
            // currently default to ~60 KB chunked messages.
            default: 65_536  // 64 KB
        )
        // Configure keepalive to prevent load balancer connection timeouts
        serverConfig.connection.keepalive = .init(
            time: .seconds(10),
            timeout: .seconds(5),
            clientBehavior: .init(
                minPingIntervalWithoutCalls: .seconds(5),
                allowWithoutCalls: true
            )
        )

        serverConfig.channelDebuggingCallbacks = .init(
            onBindTCPListener: { channel in
                Self.logger.debug(
                    "Binding TCP listener",
                    metadata: [
                        "channel": "\(channel)"
                    ]
                )
                return channel.eventLoop.makeSucceededVoidFuture()
            },
            onAcceptTCPConnection: { channel in
                Self.logger.debug(
                    "Accepting TCP connection",
                    metadata: [
                        "channel": "\(channel)"
                    ]
                )
                return channel.eventLoop.makeSucceededVoidFuture()
            },
            onAcceptHTTP2Stream: { channel in
                Self.logger.debug(
                    "Accepting HTTP2 stream",
                    metadata: ["channel": "\(channel)"]
                )
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )

        let server = GRPCServer(
            transport: .http2NIOPosix(
                address: .ipv4(host: listeningIP, port: listeningPort),
                transportSecurity: try self.configureTransportSecurity(identitySource: identitySource),
                config: serverConfig
            ),
            services: [cloudBoardService, healthService],
        )

        // Configure the service group with the services. They're started in the order they're listed
        // and shutdown in reverse order.
        let services: [(any Service)?] =
            otelServices + [
                identityManager,
                grpcAttestedKeyProviderService,
                serviceStatusMonitor,
                statusMetricsService,
                warmupPoolMetricsService,
                credentialExpiryMetricsService,
                cpAgentStatusReporter,
                cpAgentDrainSubscriber,
                cloudBoardService,
                cloudAppWarmupPool,
                healthService,
                server,
                // Used to signal graceful shutdown to service discovery publisher living outside of the service group
                GracefulShutdownForwarder(signal: shutdownSignal),
            ]

        let serviceGroup = ServiceGroup(
            services: Array(services.compacted()),
            gracefulShutdownSignals: [.sigint, .sigterm],
            logger: Logger(label: "cloudboardd.service-lifecycle"),
        )

        try await serviceGroup.run()
    }

    private func determinePreferredListeningAddress() async throws -> ServiceDiscovery.NetworkEndpoint {
        // If a listening IP is explicitly configured, use that.
        // Treat empty string the same as unset, an empty string is not a valid IP address to bind to.
        let configuredListeningIP = unattestedConfigReader.string(forKey: "grpc.listeningip").flatMap {
            $0.isEmpty ? nil : $0
        }
        let listeningPort = unattestedConfigReader.int(forKey: "grpc.listeningport", default: 4442)
        if let configuredListeningIP {
            return ServiceDiscovery.NetworkEndpoint(ip: configuredListeningIP, port: listeningPort)
        }

        // If no listening IP is configured, try to determine the ideal service discovery route
        guard let serviceDiscoveryHostname = unattestedConfigReader.string(forKey: "servicediscovery.host") else {
            Self.logger.warning("Unable to guess ideal service discovery route, listening on all interfaces.")
            return ServiceDiscovery.NetworkEndpoint(ip: "0.0.0.0", port: listeningPort)
        }
        let resolvedAddress = try await LocalIPResolution.preferredLocalGRPCServiceAddress(
            serviceDiscoveryHostname: serviceDiscoveryHostname,
            port: listeningPort
        )
        guard let resolvedListeningIP = resolvedAddress.ipAddress else {
            throw CloudBoardServerError.couldNotResolveIP
        }
        return ServiceDiscovery.NetworkEndpoint(ip: resolvedListeningIP, port: listeningPort)
    }

    /// Parse the configured `grpc.tls.client.allowedaprns` entries into policy APRNs, failing startup on any
    /// malformed entry or disallowed wildcard placement.
    func parseAllowedPolicyAPRNs(_ allowedAPRNs: [String]) throws -> Set<PolicyAPRN> {
        do {
            return try Set(allowedAPRNs.map { try PolicyAPRN(string: $0) })
        } catch {
            throw CloudBoardServerError.invalidConfig(
                "grpc.tls.client.allowedaprns contains an invalid policy APRN: \(error)"
            )
        }
    }

    private func configureTransportSecurity(
        identitySource: IdentitySource
    ) throws -> HTTP2ServerTransport.Posix.TransportSecurity {
        let requireMTLS = self.attestedConfigReader.bool(
            forKey: "grpc.tls.client.requiremtls",
            default: false
        )
        let allowedAPRNs = self.unattestedConfigReader.stringArray(forKey: "grpc.tls.client.allowedaprns") ?? []

        if requireMTLS, allowedAPRNs.isEmpty {
            throw CloudBoardServerError.invalidConfig(
                "grpc.tls.client.requiremtls=true but grpc.tls.client.allowedaprns is empty or not configured"
            )
        }

        if !allowedAPRNs.isEmpty {
            Self.logger.info(
                "Configuring mTLS with APRN validation",
                metadata: [
                    "allowedAPRNs": "\(allowedAPRNs.joined(separator: ", "))"
                ]
            )

            // Parse each configured entry as a policy APRN. Policy APRNs are a superset of plain APRNs: a
            // wildcard-free entry matches exactly as before, while `*`/`**` wildcards (in the region,
            // project-id, and resource-id fields) allow a single entry to authorize a family of client APRNs.
            let policyAPRNs = try self.parseAllowedPolicyAPRNs(allowedAPRNs)

            let verifierConfig = AppleVerifierConfiguration(
                narrative: .perform(),
                certificateManager: .skip,
                sdr: .perform(),
                bedrock: .skip
            )

            switch identitySource {
            case .resolved(let identity):
                return try .appleMTLS(
                    certificateChain: .init(identity.chain),
                    privateKey: .bytes(identity.privateKey),
                    aprnAuthorization: .duringHandshake(policyAPRNs: policyAPRNs),
                    verifierConfig: verifierConfig,
                    logger: Self.logger
                ) { _ in }

            case .reloader(let reloader):
                return try .appleMTLS(
                    certificateReloader: reloader,
                    aprnAuthorization: .duringHandshake(policyAPRNs: policyAPRNs),
                    verifierConfig: verifierConfig,
                    logger: Self.logger
                ) { _ in }
            }
        } else {
            Self.logger.info("Configuring server-only TLS without client certificate validation")

            switch identitySource {
            case .resolved(let identity):
                return try .tls(
                    certificateChain: .init(identity.chain),
                    privateKey: .bytes(identity.privateKey)
                )

            case .reloader(let reloader):
                return try .tls(certificateReloader: reloader)
            }
        }
    }

    /// Check if a Unix domain socket exists at the given path using stat(2).
    ///
    /// Unlike `FileManager.fileExists(atPath:)`, this works for socket files.
    /// Returns `true` only if the path exists and is a socket (`S_IFSOCK`).
    private static func socketExists(atPath path: String) -> Bool {
        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else { return false }
        return (statBuf.st_mode & S_IFMT) == S_IFSOCK
    }
}
