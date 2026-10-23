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

import AsyncHTTPClient
import Configuration
import FleetManagerClient
import Foundation
import GPUHealthDaemonClient
import Logging
import MirkwoodConfiguration
import NIOCertificateReloading
import NIOSSL
import OpenAPIRuntime
import ServiceLifecycle

@main
struct Application {

    static func main() async throws {

        let environmentConfigReader = ConfigReader(provider: EnvironmentVariablesProvider())
        /// Initialize configuration of CPAgent
        let measuredConfiguration: CPAgentMeasuredConfiguration = CPAgentMeasuredConfiguration(
            config: environmentConfigReader)
        // Setting service for metric and log emission
        let otelServices = try setupObservability(configReader: environmentConfigReader)

        let logger = Logger(label: "CPAgent")

        let identityManager = IdentityManager(cpagentConfiguration: measuredConfiguration)
        let initialIdentityRenewalDate = try await identityManager.provisionIdentity()

        // refreshInterval is required by the initializer but unused: we never call `.run()`.
        // IdentityManager is the sole writer of these files, so instead of polling on a guessed
        // interval, we call `reload()` explicitly right after each write (below, and in
        // IdentityRenewalService) — the reloader picks up the fresh cert immediately.
        let identityCertificateReloader = try TimedCertificateReloader.makeReloaderValidatingSources(
            refreshInterval: .seconds(300),
            certificateSource: .init(
                location: .file(path: measuredConfiguration.identityCertPath), format: .pem),
            privateKeySource: .init(
                location: .file(path: measuredConfiguration.identityKeyPath), format: .pem),
            logger: logger
        )

        /// Create TLS HTTP client to talk to Mirkwood Control Plane Fleet Manager
        let tlsClient = try makeMTLSHttpClient(certificateReloader: identityCertificateReloader)
        defer { _ = tlsClient.shutdown() }

        let metadataClient: any MetadataClient = GCEMetadataClient(
            httpClient: HTTPClient.shared)
        let metadataConfiguration = try await MetadataConfiguration(
            using: metadataClient,
            cpagentConfiguration: measuredConfiguration,
            logger: logger)

        logger.info(
            "Starting CPAgent with measured configuration",
            metadata: ["configuration": "\(measuredConfiguration)"])

        let fleetNodeId = metadataConfiguration.fleetNodeId
        logger.info(
            "Retrieved Fleet Node ID",
            metadata: ["fleetNodeId": "\(fleetNodeId)"])

        let clientFactory = ControlPlaneClientFactory(
            computeInstanceId: metadataConfiguration.computeInstanceId,
            tlsClient: tlsClient)

        let healthServiceClient = clientFactory.makeHealthServiceClient(
            url: metadataConfiguration.healthServiceUrl)
        let fleetManagerClient = clientFactory.makeFleetManagerClient(
            url: metadataConfiguration.fleetManagerUrl)

        /// Fetch boot config once at startup and share it across services that need it.
        /// Services degrade gracefully if this returns nil. If fetchBootConfig throws an error,
        /// the other services won't start and CPAgent will crash.
        let bootConfig: Components.Schemas.NodeConfiguration?
        do {
            bootConfig = try await fetchBootConfig(
                configuration: measuredConfiguration,
                client: fleetManagerClient,
                logger: logger)
        } catch {
            logger.error(
                "Failed to fetch boot config. Will not write config-render-complete file.",
                metadata: ["error": "\(String(reportable: error))"])
            throw error
        }

        // Saves and mounts the unmeasured and measured configurations for the cpagent.
        try await saveRenderedConfiguration(
            fleetNodeId: fleetNodeId,
            bootConfig: bootConfig, config: measuredConfiguration, logger: logger)

        logger.info(
            "Finished rendering config, reading unmeasured config for CPAgent."
        )

        let unmeasuredConfigurationReader: ConfigReader
        do {
            unmeasuredConfigurationReader = await ConfigReader(providers: [
                try UnmeasuredConfigurationProvider(scope: .local),
                try UnmeasuredConfigurationProvider(scope: .global),
            ])
        } catch {
            logger.warning(
                "Failed to load unmeasured configuration for cpagent, falling back to environment variables or defaults",
                metadata: ["error": "\(String(reportable: error))"])
            unmeasuredConfigurationReader = ConfigReader(provider: EnvironmentVariablesProvider())
        }

        // CPAgent's configs loaded from unmeasured config reader
        let unmeasuredConfiguration = CPAgentUnmeasuredConfiguration(
            unmeasuredConfigReader: unmeasuredConfigurationReader)

        logger.info(
            "Starting CPAgent with unmeasured-configuration",
            metadata: ["unmeasured-configuration": "\(unmeasuredConfiguration)"])

        let nodeStatusStore = NodeStatusStore()

        let gpuHealthDaemonClient = GPUHealthDaemonClient(
            target: .unixDomainSocket(
                path: measuredConfiguration.gpuHealthDaemonSocketPath))

        let fluentBitCheckService = FluentBitCheckService(
            healthCheckSocketPath: measuredConfiguration.fluentBitHealthCheckSocketPath,
            healthCheckEndpoint: measuredConfiguration.fluentBitHealthCheckEndpoint)

        let healthMonitor = HealthMonitor(
            healthServiceClient: healthServiceClient,
            fleetManagerClient: fleetManagerClient,
            nodeStatusStore: nodeStatusStore,
            convergenceCheckGpu: unmeasuredConfiguration.convergenceCheckGpu,
            convergenceCheckCloudboard: unmeasuredConfiguration.convergenceCheckCloudboard,
            convergenceCheckFluentBit: unmeasuredConfiguration.convergenceCheckFluentBit,
            enableHealthServiceReporting: unmeasuredConfiguration.reportToHealthService,
            gpuHealthProvider: gpuHealthDaemonClient,
            fluentBitCheckService: fluentBitCheckService)

        let bootSecureConfig = bootConfig?.manifestDetails?.secureConfig
        let bootServiceConfig = bootSecureConfig?.value["serviceConfig"] ?? nil
        let dynamicConfigService = await DynamicConfigService(
            healthServiceClient: healthServiceClient,
            checksum: bootConfig?.checksum,
            renderedConfigDirectory: measuredConfiguration.renderedConfigDirectory,
            bootServiceConfig: bootServiceConfig)

        let drainService = DrainService()
        let drainGRPCServer = DrainGRPCServer(
            socketPath: measuredConfiguration.drainSocketPath,
            drainGRPCService: DrainGRPCService(drainService: drainService))

        let statusGRPCServer = StatusGRPCServer(
            socketPath: measuredConfiguration.statusSocketPath,
            statusReporterGRPCService: StatusReporterGRPCService(nodeStatusStore: nodeStatusStore))

        let attestationClient = AttestationClient(metadataClient: metadataClient)

        var tlsConfiguration = try TLSConfiguration.makeServerConfiguration(
            certificateReloader: identityCertificateReloader)
        // Client certificates are optional: most callers hit /health over plain HTTP or
        // unauthenticated HTTPS, but privileged endpoints require one (see
        // HTTPServer.validateClientCertificateChain).
        tlsConfiguration.certificateVerification = .optionalVerification
        let httpTLSContext = try NIOSSLContext(configuration: tlsConfiguration)

        let httpService = HTTPService(
            port: measuredConfiguration.healthCheckPort,
            tlsContext: httpTLSContext,
            healthMonitor: healthMonitor,
            drainService: drainService,
            attestationClient: attestationClient)

        let attestationCertificateService = AttestationCertificateService(
            fleetManagerClient: fleetManagerClient,
            certFile: URL(fileURLWithPath: measuredConfiguration.attestationCertPath))

        let identityRenewalService = IdentityRenewalService(
            identityManager: identityManager,
            identityCertificateReloader: identityCertificateReloader,
            initialRenewalDate: initialIdentityRenewalDate)

        let services: [(any Service)?] =
            otelServices + [
                identityRenewalService,
                httpService,
                drainGRPCServer,
                statusGRPCServer,
                fluentBitCheckService,
                healthMonitor,
                dynamicConfigService,
                attestationCertificateService,
                gpuHealthDaemonClient,
            ]

        let serviceGroup = ServiceGroup(
            services: Array(services.compacted()),
            gracefulShutdownSignals: [.sigterm],
            logger: logger
        )

        try await serviceGroup.run()
    }
}
