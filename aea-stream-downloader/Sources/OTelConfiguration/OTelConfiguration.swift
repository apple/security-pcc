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

import Configuration
import Logging
import OTel

/// Configuration for OpenTelemetry, read from a ``ConfigReader``.
///
/// Expected keys (relative — no namespace prefix):
/// - `enabled` (optional, default `true`)
/// - `loglevel` (optional, default `info`)
/// - `diagnostics.enabled` (optional, default `false`)
/// - `diagnostics.loglevel` (optional, default `info`)
/// - `otlp.endpoint` (optional, default `http+unix://%2Fvar%2Frun%2Fobservability%2Fotel.sock`)
/// - `otlp.protocol` (optional, default `httpProtobuf`)
/// - `otlp.compression` (optional, default `none`)
/// - `otlp.timeoutSeconds` (optional, default `10`)
/// - `environment` (optional, default `unknown`)
package struct OTelConfigurationBuilder: Sendable {
    /// Whether OTel is enabled at all. When `false`, `build()` returns `nil`.
    package var enabled: Bool
    /// The log level applied to the OTel logs signal.
    package var logLevel: Logger.Level
    /// Whether OTel diagnostic logging is enabled.
    package var diagnosticsEnabled: Bool
    /// The log level for OTel diagnostic messages.
    package var diagnosticsLogLevel: Logger.Level
    /// The OTLP exporter endpoint (shared across all signals).
    package var otlpEndpoint: String
    /// The OTLP exporter protocol (shared across all signals).
    package var otlpProtocol: OTLPProtocolOption
    /// The OTLP exporter compression (shared across all signals).
    package var otlpCompression: OTLPCompressionOption
    /// The OTLP exporter timeout in seconds (shared across all signals).
    package var otlpTimeoutSeconds: Int
    /// The deployment environment (e.g. `production`, `staging`).
    package var environment: String

    package init(
        enabled: Bool = true,
        logLevel: Logger.Level = .info,
        diagnosticsEnabled: Bool = false,
        diagnosticsLogLevel: Logger.Level = .info,
        otlpEndpoint: String = "http+unix://%2Fvar%2Frun%2Fobservability%2Fotel.sock",
        otlpProtocol: OTLPProtocolOption = .httpProtobuf,
        otlpCompression: OTLPCompressionOption = .none,
        otlpTimeoutSeconds: Int = 10,
        environment: String = "unknown"
    ) {
        self.enabled = enabled
        self.logLevel = logLevel
        self.diagnosticsEnabled = diagnosticsEnabled
        self.diagnosticsLogLevel = diagnosticsLogLevel
        self.otlpEndpoint = otlpEndpoint
        self.otlpProtocol = otlpProtocol
        self.otlpCompression = otlpCompression
        self.otlpTimeoutSeconds = otlpTimeoutSeconds
        self.environment = environment
    }

    /// Creates an ``OTelConfigurationBuilder`` by reading values from a ``ConfigReader``.
    ///
    /// The reader should already be scoped to the appropriate prefix
    /// (e.g. `config.scoped(to: "otel")`).
    package init(config: ConfigReader) {
        self.enabled = config.bool(forKey: "enabled") ?? true

        self.logLevel =
            config.string(forKey: "loglevel").flatMap { Logger.Level(rawValue: $0) } ?? .info

        self.diagnosticsEnabled = config.bool(forKey: "diagnostics.enabled") ?? false

        self.diagnosticsLogLevel =
            config.string(forKey: "diagnostics.loglevel").flatMap { Logger.Level(rawValue: $0) }
            ?? .info

        self.otlpEndpoint =
            config.string(forKey: "otlp.endpoint") ?? "http+unix://%2Fvar%2Frun%2Fobservability%2Fotel.sock"

        self.otlpProtocol =
            config.string(forKey: "otlp.protocol").flatMap { OTLPProtocolOption(rawValue: $0) }
            ?? .httpProtobuf

        self.otlpCompression =
            config.string(forKey: "otlp.compression").flatMap {
                OTLPCompressionOption(rawValue: $0)
            } ?? .none

        self.otlpTimeoutSeconds = config.int(forKey: "otlp.timeoutSeconds") ?? 10

        self.environment = config.string(forKey: "environment") ?? "unknown"
    }

    /// Builds an ``OTel.Configuration`` from these settings, or returns `nil` if OTel is disabled.
    package func build() -> OTel.Configuration? {
        guard enabled else { return nil }

        var otelConfig = OTel.Configuration.default
        otelConfig.serviceName = "aea-stream-downloader"
        otelConfig.resourceAttributes["service.namespace"] = "aea-stream-downloader"
        otelConfig.resourceAttributes["deployment.environment"] = environment

        if diagnosticsEnabled {
            otelConfig.diagnosticLogger = .console
            otelConfig.diagnosticLogLevel = .init(diagnosticsLogLevel)
        }

        otelConfig.logs.level = .init(logLevel)
        otelConfig.logs.otlpExporter.endpoint = "\(otlpEndpoint)/v1/logs"
        otelConfig.logs.otlpExporter.protocol = otlpProtocol.otelProtocol
        otelConfig.logs.otlpExporter.compression = otlpCompression.otelCompression
        otelConfig.logs.otlpExporter.timeout = .seconds(otlpTimeoutSeconds)

        otelConfig.metrics.otlpExporter.endpoint = "\(otlpEndpoint)/v1/metrics"
        otelConfig.metrics.otlpExporter.protocol = otlpProtocol.otelProtocol
        otelConfig.metrics.otlpExporter.compression = otlpCompression.otelCompression
        otelConfig.metrics.otlpExporter.timeout = .seconds(otlpTimeoutSeconds)

        otelConfig.traces.otlpExporter.endpoint = "\(otlpEndpoint)/v1/traces"
        otelConfig.traces.otlpExporter.protocol = otlpProtocol.otelProtocol
        otelConfig.traces.otlpExporter.compression = otlpCompression.otelCompression
        otelConfig.traces.otlpExporter.timeout = .seconds(otlpTimeoutSeconds)

        return otelConfig
    }
}

// MARK: - OTel.Configuration.LogLevel bridging

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

// MARK: - Protocol option

/// The OTLP exporter protocol to use.
package enum OTLPProtocolOption: String, Sendable {
    case grpc
    case httpJSON
    case httpProtobuf

    var otelProtocol: OTel.Configuration.OTLPExporterConfiguration.`Protocol` {
        switch self {
        case .grpc: .grpc
        case .httpJSON: .httpJSON
        case .httpProtobuf: .httpProtobuf
        }
    }
}

// MARK: - Compression option

/// The OTLP exporter compression to use.
package enum OTLPCompressionOption: String, Sendable {
    case gzip
    case none

    var otelCompression: OTel.Configuration.OTLPExporterConfiguration.Compression {
        switch self {
        case .gzip: .gzip
        case .none: .none
        }
    }
}
