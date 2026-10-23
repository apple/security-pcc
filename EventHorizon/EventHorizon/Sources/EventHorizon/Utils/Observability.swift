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

#if os(Linux)
import Foundation
import Logging
import Metrics
import OTel
import ServiceLifecycle
import Tracing

public enum Observability {
    public static let canonicalSocketPath = "/var/run/observability/otel.sock"

    public struct Config: Sendable {
        public var serviceName: String
        public var serviceNamespace: String
        public var environment: String
        public var otelEnabled: Bool
        public var logLevel: Logger.Level
        public var otelDiagnosticsEnabled: Bool
        public var otelDiagnosticsLogLevel: Logger.Level
        public var otlpProtocol: OTLPProtocol
        public var otlpCompression: OTLPCompression
        public var otlpTimeoutSeconds: Int
        public var otlpSocketPath: String
        public var extraLogHandlerFactories: [@Sendable (String) -> any LogHandler]
        public var suppressStdoutLogging: Bool

        public init(
            serviceName: String,
            serviceNamespace: String = "eventhorizon",
            environment: String = "unknown",
            otelEnabled: Bool = true,
            logLevel: Logger.Level = .info,
            otelDiagnosticsEnabled: Bool = false,
            otelDiagnosticsLogLevel: Logger.Level = .info,
            otlpProtocol: OTLPProtocol = .httpProtobuf,
            otlpCompression: OTLPCompression = .none,
            otlpTimeoutSeconds: Int = 3,
            otlpSocketPath: String = Observability.canonicalSocketPath,
            extraLogHandlerFactories: [@Sendable (String) -> any LogHandler] = [],
            suppressStdoutLogging: Bool = false
        ) {
            self.serviceName = serviceName
            self.serviceNamespace = serviceNamespace
            self.environment = environment
            self.otelEnabled = otelEnabled
            self.logLevel = logLevel
            self.otelDiagnosticsEnabled = otelDiagnosticsEnabled
            self.otelDiagnosticsLogLevel = otelDiagnosticsLogLevel
            self.otlpProtocol = otlpProtocol
            self.otlpCompression = otlpCompression
            self.otlpTimeoutSeconds = otlpTimeoutSeconds
            self.otlpSocketPath = otlpSocketPath
            self.extraLogHandlerFactories = extraLogHandlerFactories
            self.suppressStdoutLogging = suppressStdoutLogging
        }
    }

    public enum OTLPProtocol: String, Sendable {
        case grpc
        case httpJSON
        case httpProtobuf
    }

    public enum OTLPCompression: String, Sendable {
        case gzip
        case none
    }

    nonisolated(unsafe) private static var didBootstrap = false
    private static let bootstrapLock = NSLock()

    public struct ValueParams: Sendable {
        public var serviceName: String
        public var defaultLogLevel: Level
        public var otelEnabled: Bool
        public var otelDiagnosticsEnabled: Bool
        public var otlpProtocol: String
        public var otlpCompression: String
        public var otlpTimeoutSeconds: Int
        public var otlpSocketPath: String
        public var extraLogHandlerFactories: [@Sendable (String) -> any LogHandler]
        public var suppressStdoutLogging: Bool

        public init(
            serviceName: String,
            defaultLogLevel: Level,
            otelEnabled: Bool,
            otelDiagnosticsEnabled: Bool,
            otlpProtocol: String,
            otlpCompression: String,
            otlpTimeoutSeconds: Int,
            otlpSocketPath: String,
            extraLogHandlerFactories: [@Sendable (String) -> any LogHandler] = [],
            suppressStdoutLogging: Bool = false
        ) {
            self.serviceName = serviceName
            self.defaultLogLevel = defaultLogLevel
            self.otelEnabled = otelEnabled
            self.otelDiagnosticsEnabled = otelDiagnosticsEnabled
            self.otlpProtocol = otlpProtocol
            self.otlpCompression = otlpCompression
            self.otlpTimeoutSeconds = otlpTimeoutSeconds
            self.otlpSocketPath = otlpSocketPath
            self.extraLogHandlerFactories = extraLogHandlerFactories
            self.suppressStdoutLogging = suppressStdoutLogging
        }
    }

    public static func configFromValues(_ params: ValueParams) -> Config {
        let logLevel = mapLogLevel(params.defaultLogLevel)
        let environment = EnvironmentResolver.environment ?? "unknown"
        return Config(
            serviceName: params.serviceName,
            environment: environment,
            otelEnabled: params.otelEnabled,
            logLevel: logLevel,
            otelDiagnosticsEnabled: params.otelDiagnosticsEnabled,
            otlpProtocol: OTLPProtocol(rawValue: params.otlpProtocol) ?? .httpProtobuf,
            otlpCompression: OTLPCompression(rawValue: params.otlpCompression) ?? .none,
            otlpTimeoutSeconds: params.otlpTimeoutSeconds,
            otlpSocketPath: params.otlpSocketPath,
            extraLogHandlerFactories: params.extraLogHandlerFactories,
            suppressStdoutLogging: params.suppressStdoutLogging
        )
    }

    public static func configFromResolvers(
        serviceName: String,
        defaultLogLevel: Level,
        defaultOtelEnabled: Bool = false
    ) -> Config {
        let domain = "com.apple.eventhorizond"
        let logLevel = mapLogLevel(defaultLogLevel)

        let otelEnabled = resolveBool(key: "\(domain).observability.otelEnabled", domain: domain, default: defaultOtelEnabled)
        let diagEnabled = resolveBool(key: "\(domain).observability.otelDiagnosticsEnabled", domain: domain, default: false)
        let protocolStr = resolveString(key: "\(domain).observability.otlpProtocol", domain: domain, default: OTLPProtocol.httpProtobuf.rawValue)
        let otlpProtocol = OTLPProtocol(rawValue: protocolStr) ?? .httpProtobuf
        let compressionStr = resolveString(key: "\(domain).observability.otlpCompression", domain: domain, default: OTLPCompression.none.rawValue)
        let otlpCompression = OTLPCompression(rawValue: compressionStr) ?? .none
        let timeout = resolveInt(key: "\(domain).observability.otlpTimeoutSeconds", domain: domain, default: 3)
        let environment = resolveString(key: "\(domain).observability.environment", domain: domain, default: "unknown")
        let socketPath = resolveString(key: "\(domain).observability.otlpSocketPath", domain: domain, default: canonicalSocketPath)

        return Config(
            serviceName: serviceName,
            environment: environment,
            otelEnabled: otelEnabled,
            logLevel: logLevel,
            otelDiagnosticsEnabled: diagEnabled,
            otlpProtocol: otlpProtocol,
            otlpCompression: otlpCompression,
            otlpTimeoutSeconds: timeout,
            otlpSocketPath: socketPath
        )
    }

    public static func lockedSecurityMonitorConfig(serviceName: String, defaultLogLevel: Level) -> Config {
        var cfg = configFromResolvers(
            serviceName: serviceName,
            defaultLogLevel: defaultLogLevel,
            defaultOtelEnabled: true
        )
        cfg.otlpSocketPath = canonicalSocketPath
        return cfg
    }

    public static func setup(_ config: Config) {
        bootstrapLock.lock()
        if didBootstrap {
            bootstrapLock.unlock()
            return
        }
        didBootstrap = true
        bootstrapLock.unlock()

        let log = EHLog.withCategory("Observability")

        guard config.otelEnabled else {
            bootstrapStdoutLogging(config: config)
            MetricsSystem.bootstrap(PrometheusBackend.metricsFactory())
            os_log(.info, log: log, "Observability OTel disabled; logging to stdout, metrics via Prometheus only")
            return
        }

        let otelConfig: OTel.Configuration
        do {
            otelConfig = try buildOTelConfiguration(config)
        } catch {
            bootstrapStdoutLogging(config: config)
            MetricsSystem.bootstrap(PrometheusBackend.metricsFactory())
            os_log(.error, log: log, "Failed to build OTel configuration: \(error.localizedDescription); falling back to stdout-only logging, metrics via Prometheus only")
            return
        }

        var services: [any Service] = []

        do {
            let backend = try OTel.makeLoggingBackend(configuration: otelConfig)
            let logLevel = config.logLevel
            let suppressStdout = config.suppressStdoutLogging
            let extraFactories = config.extraLogHandlerFactories
            LoggingSystem.bootstrap { label in
                var handlers: [any LogHandler] = []
                if !suppressStdout {
                    var stdoutHandler = StreamLogHandler.standardOutput(label: label)
                    stdoutHandler.logLevel = logLevel
                    handlers.append(stdoutHandler)
                }
                handlers.append(backend.factory(label))
                for factory in extraFactories {
                    handlers.append(factory(label))
                }
                return handlers.count == 1 ? handlers[0] : MultiplexLogHandler(handlers)
            }
            services.append(backend.service)
        } catch {
            bootstrapStdoutLogging(config: config)
            os_log(.error, log: log, "Failed to construct OTel logging backend: \(error.localizedDescription); using stdout-only logging")
        }

        do {
            let backend = try OTel.makeMetricsBackend(configuration: otelConfig)
            let multiplex = MultiplexMetricsFactory([
                PrometheusBackend.metricsFactory(),
                backend.factory
            ])
            MetricsSystem.bootstrap(multiplex)
            services.append(backend.service)
            os_log(.info, log: log, "Metrics bootstrapped: swift-prometheus + OTel multiplex")
        } catch {
            MetricsSystem.bootstrap(PrometheusBackend.metricsFactory())
            os_log(.error, log: log, "Failed to construct OTel metrics backend: \(error.localizedDescription); using prometheus-only metrics")
        }

        do {
            let backend = try OTel.makeTracingBackend(configuration: otelConfig)
            InstrumentationSystem.bootstrap(backend.factory)
            services.append(backend.service)
            os_log(.info, log: log, "OTel tracing backend bootstrapped")
        } catch {
            os_log(.error, log: log, "Failed to construct OTel tracing backend: \(error.localizedDescription); traces will not be pushed via OTLP")
        }

        guard !services.isEmpty else {
            os_log(.error, log: log, "No OTel services constructed; not starting ServiceGroup")
            return
        }

        let serviceLogger = Logger(label: "eventhorizon.Observability.ServiceGroup")
        let groupServices = services
        Task.detached {
            let group = ServiceGroup(
                configuration: .init(services: groupServices.map { .init(service: $0) }, logger: serviceLogger)
            )
            do {
                try await group.run()
            } catch {
                let errLog = EHLog.withCategory("Observability")
                os_log(.error, log: errLog, "OTel ServiceGroup terminated with error: \(error.localizedDescription)")
            }
        }

        os_log(.info, log: log, "Observability bootstrapped: serviceName=\(config.serviceName), environment=\(config.environment), socket=\(config.otlpSocketPath), services=\(services.count)")
    }


    private static func bootstrapStdoutLogging(config: Config) {
        let level = config.logLevel
        let extras = config.extraLogHandlerFactories
        let suppressStdout = config.suppressStdoutLogging
        LoggingSystem.bootstrap { label in
            var handlers: [any LogHandler] = []
            if !suppressStdout {
                var h = StreamLogHandler.standardOutput(label: label)
                h.logLevel = level
                handlers.append(h)
            }
            for factory in extras {
                handlers.append(factory(label))
            }
            if handlers.isEmpty {
                var h = StreamLogHandler.standardOutput(label: label)
                h.logLevel = level
                handlers.append(h)
            }
            return handlers.count == 1 ? handlers[0] : MultiplexLogHandler(handlers)
        }
    }

    private static func buildOTelConfiguration(_ config: Config) throws -> OTel.Configuration {
        var otelConfig = OTel.Configuration.default
        otelConfig.serviceName = config.serviceName
        otelConfig.resourceAttributes["service.namespace"] = config.serviceNamespace
        otelConfig.resourceAttributes["deployment.environment"] = config.environment

        if config.otelDiagnosticsEnabled {
            otelConfig.diagnosticLogger = .console
            otelConfig.diagnosticLogLevel = .init(config.otelDiagnosticsLogLevel)
        }

        let proto = otlpProtocolValue(config.otlpProtocol)
        let compression = otlpCompressionValue(config.otlpCompression)
        let timeout = Duration.seconds(config.otlpTimeoutSeconds)
        let logsURL = otlpURL(socketPath: config.otlpSocketPath, signal: "logs")
        let metricsURL = otlpURL(socketPath: config.otlpSocketPath, signal: "metrics")
        let tracesURL = otlpURL(socketPath: config.otlpSocketPath, signal: "traces")

        otelConfig.logs.level = .init(config.logLevel)
        otelConfig.logs.otlpExporter.endpoint = logsURL
        otelConfig.logs.otlpExporter.protocol = proto
        otelConfig.logs.otlpExporter.compression = compression
        otelConfig.logs.otlpExporter.timeout = timeout

        otelConfig.metrics.otlpExporter.endpoint = metricsURL
        otelConfig.metrics.otlpExporter.protocol = proto
        otelConfig.metrics.otlpExporter.compression = compression
        otelConfig.metrics.otlpExporter.timeout = timeout

        otelConfig.traces.otlpExporter.endpoint = tracesURL
        otelConfig.traces.otlpExporter.protocol = proto
        otelConfig.traces.otlpExporter.compression = compression
        otelConfig.traces.otlpExporter.timeout = timeout

        return otelConfig
    }

    private static func otlpURL(socketPath: String, signal: String) -> String {
        let encoded = socketPath.replacingOccurrences(of: "/", with: "%2F")
        return "http+unix://\(encoded)/v1/\(signal)"
    }

    private static func otlpProtocolValue(_ p: OTLPProtocol) -> OTel.Configuration.OTLPExporterConfiguration.`Protocol` {
        switch p {
        case .grpc: return .grpc
        case .httpJSON: return .httpJSON
        case .httpProtobuf: return .httpProtobuf
        }
    }

    private static func otlpCompressionValue(_ c: OTLPCompression) -> OTel.Configuration.OTLPExporterConfiguration.Compression {
        switch c {
        case .gzip: return .gzip
        case .none: return .none
        }
    }

    private static func mapLogLevel(_ level: Level) -> Logger.Level {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .error: return .error
        }
    }

    private static func resolveBool(key: String, domain: String, default defaultValue: Bool) -> Bool {
        let resolver = EHConfigResolver(
            SecureConfigProvider(),
            CFPrefsProvider(),
            EnvironmentConfigResolver(),
            DefaultConfigProvider<Bool>(value: defaultValue)
        )
        return resolver.resolve(key: key, domain: domain) ?? defaultValue
    }

    private static func resolveString(key: String, domain: String, default defaultValue: String) -> String {
        let resolver = EHConfigResolver(
            SecureConfigProvider(),
            CFPrefsProvider(),
            EnvironmentConfigResolver(),
            DefaultConfigProvider<String>(value: defaultValue)
        )
        return resolver.resolve(key: key, domain: domain) ?? defaultValue
    }

    private static func resolveInt(key: String, domain: String, default defaultValue: Int) -> Int {
        let resolver = EHConfigResolver(
            SecureConfigProvider(),
            CFPrefsProvider(),
            EnvironmentConfigResolver(),
            DefaultConfigProvider<Int>(value: defaultValue)
        )
        return resolver.resolve(key: key, domain: domain) ?? defaultValue
    }
}

extension OTel.Configuration.LogLevel {
    init(_ swiftLogLevel: Logger.Level) {
        self =
            switch swiftLogLevel {
            case .trace: .trace
            case .debug: .debug
            case .info: .info
            case .notice: .info
            case .warning: .warning
            case .error: .error
            case .critical: .error
            }
    }
}
#endif
