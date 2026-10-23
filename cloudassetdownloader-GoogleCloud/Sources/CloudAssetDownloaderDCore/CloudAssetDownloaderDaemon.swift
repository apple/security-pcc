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
import CloudAssetDownloaderAPI
import Configuration
import Foundation
import GRPCNIOTransportHTTP2Posix
import Logging
import Metrics
import MirkwoodConfiguration
import OTel
import ServiceLifecycle

public final class CloudAssetDownloaderDaemon: Sendable {
    private static let logger = Logger.forType(CloudAssetDownloaderDaemon.self)

    private let assetManager: AssetManager
    private let assetConfigRegistry: AssetConfigRegistry
    private let apiServer: CloudAssetDownloaderAPIServer
    private let httpClient: HTTPClient
    private let otelServices: [Service]
    private let dynamicConfigProvider: DynamicConfigurationProvider?

    public init() async throws {
        let configReader = ConfigReader(providers: [EnvironmentVariablesProvider()])
        let daemonConfig = try await CloudAssetDownloaderDConfiguration.fromConfigReader(configReader)

        self.httpClient = try Self.createHTTPClient(tlsConfig: daemonConfig.tls)

        let useAEADownloader = configReader.bool(forKey: "useAeaDownloader") == true
        if daemonConfig.controlPlaneAgentURL != nil {
            let dynamicConfigProvider = try await DynamicConfigurationProvider(
                applicationID: "com.apple.cloudassetdownloaderd"
            )
            self.dynamicConfigProvider = dynamicConfigProvider
            self.assetConfigRegistry = ConfigReaderAssetConfigRegistry(
                configReader: ConfigReader(provider: dynamicConfigProvider),
                assetsRootPath: daemonConfig.assetsRootPath
            )
        } else {
            self.dynamicConfigProvider = nil
            // TODO: disallow this in non-test environments
            self.assetConfigRegistry = TestAssetConfigRegistry(
                configReader: configReader,
                useStaticAssetConfigs: useAEADownloader
            )
        }

        let apiServer = CloudAssetDownloaderAPIGRPCServer(socketPath: daemonConfig.apiSocketPath)

        let assetDownloader: AssetDownloader =
            if useAEADownloader {
                AEAAssetDownloader(httpClient: self.httpClient)
            } else {
                // TODO: remove after cpagent integration
                NoOpAssetDownloader(delay: .seconds(3))
            }
        self.assetManager = AssetManager(
            assetConfigRegistry: self.assetConfigRegistry,
            assetDownloader: assetDownloader,
            apiServer: apiServer,
            purgeInterval: daemonConfig.purgeInterval
        )
        apiServer.setDelegate(self.assetManager)
        self.apiServer = apiServer

        let otelConfig = Self.createOTELConfig(configReader: configReader)
        let otelLoggingBackend = try OTel.makeLoggingBackend(configuration: otelConfig)
        LoggingSystem.bootstrap { label in
            let otelLogHandler = otelLoggingBackend.factory(label)
            var stdoutLogHandler = StreamLogHandler.standardOutput(label: label)
            stdoutLogHandler.logLevel = .info
            return MultiplexLogHandler([otelLogHandler, stdoutLogHandler])
        }
        let otelMetricsBackend = try OTel.makeMetricsBackend(configuration: otelConfig)
        MetricsSystem.bootstrap(otelMetricsBackend.factory)
        self.otelServices = [otelLoggingBackend.service, otelMetricsBackend.service]
    }

    public func run() async throws {
        Self.logger.info("Starting CloudAssetDownloaderDaemon...")
        CADMetrics.recordLaunch()
        defer { CADMetrics.recordExit() }

        // Ensure OTEL services are first, so they're shut down last.
        var services: [ServiceGroupConfiguration.ServiceConfiguration] = self.otelServices.map {
            .init(
                service: $0,
                successTerminationBehavior: .cancelGroup,
                failureTerminationBehavior: .cancelGroup
            )
        }
        services.append(contentsOf: [
            .init(
                service: self.assetManager,
                successTerminationBehavior: .cancelGroup,
                failureTerminationBehavior: .cancelGroup
            ),
            .init(
                service: self.apiServer,
                successTerminationBehavior: .cancelGroup,
                failureTerminationBehavior: .cancelGroup
            ),
        ])
        if let dynamicConfigProvider = self.dynamicConfigProvider {
            services.append(
                .init(
                    service: dynamicConfigProvider,
                    successTerminationBehavior: .cancelGroup,
                    failureTerminationBehavior: .cancelGroup
                )
            )
        }
        let serviceGroupConfig = ServiceGroupConfiguration(
            services: services,
            gracefulShutdownSignals: [.sigterm],
            logger: Logger.forType(CloudAssetDownloaderDaemon.self)
        )
        let serviceGroup = ServiceGroup(configuration: serviceGroupConfig)
        do {
            try await serviceGroup.run()
        } catch {
            try? await self.httpClient.shutdown()
            throw error
        }
        try? await self.httpClient.shutdown()
        Self.logger.info("Exiting CloudAssetDownloaderDaemon...")
    }

    private static func createHTTPClient(
        tlsConfig: CloudAssetDownloaderDConfiguration.TLSConfiguration?
    ) throws -> HTTPClient {
        var httpClientConfig = HTTPClient.Configuration()
        if let tlsConfig {
            httpClientConfig.tlsConfiguration = try tlsConfig.makeNIOSSLClientConfiguration()
        }
        return HTTPClient(
            eventLoopGroup: .singletonMultiThreadedEventLoopGroup,
            configuration: httpClientConfig
        )
    }

    private static func createOTELConfig(configReader: ConfigReader) -> OTel.Configuration {
        var otelConfig: OTel.Configuration = .default
        otelConfig.serviceName = "cloudassetdownloaderd"
        otelConfig.resourceAttributes["service.namespace"] = "cloudassetdownloader"
        otelConfig.resourceAttributes["deployment.environment"] = configReader.string(
            forKey: "environment",
            default: "unknown"
        )
        if configReader.bool(forKey: "otel.diagnostics.enabled") == true {
            otelConfig.diagnosticLogger = .console
            otelConfig.diagnosticLogLevel = .info
        }
        otelConfig.logs.level = .info
        // intentionally hardcoded
        otelConfig.logs.otlpExporter.endpoint = "http+unix://%2Fvar%2Frun%2Fobservability%2Fotel.sock/v1/logs"
        otelConfig.logs.otlpExporter.protocol = .httpProtobuf
        // intentionally hardcoded
        otelConfig.metrics.otlpExporter.endpoint = "http+unix://%2Fvar%2Frun%2Fobservability%2Fotel.sock/v1/metrics"
        otelConfig.metrics.otlpExporter.protocol = .httpProtobuf
        // intentionally hardcoded
        otelConfig.traces.otlpExporter.endpoint = "http+unix://%2Fvar%2Frun%2Fobservability%2Fotel.sock/v1/traces"
        otelConfig.traces.otlpExporter.protocol = .httpProtobuf
        return otelConfig
    }
}
