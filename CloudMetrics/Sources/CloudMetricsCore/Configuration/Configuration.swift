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

//
//  Configuration.swift
//  CloudMetrics
//
//  Created by Oliver Chick (ORAC) on 12/12/2024.
//

internal import CloudMetricsConstants
package import CloudMetricsXPC
#if canImport(cloudOSInfo)
@_weakLinked import cloudOSInfo
#endif
private import MobileGestaltPrivate
package import NIOSSL
internal import os

/// Contains the configuration for ``CloudMetricsDaemon``
package struct Configuration: Hashable, Equatable {
    internal static let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "Configuration")
    package var auditLists: AuditLists?
    package var openTelemetryEndpoint: OpenTelemetryEndpoint
    /// Config for OTLP protocol
    package var openTelemetry: OpenTelemetry
    /// Number of failed publishes in a row before the server is deemed unhealthy.
    package var publishFailureThreshold: Int

    /// No longer used. openTelemetry is the only supported backend.
    package var useOpenTelemetry: Bool
    package var defaultHistogramBuckets: [Double]
    package var auditLogThrottleInterval: Duration
    package var requireAllowList: Bool

    /// Source to use for fetching TLS keys.
    package var keySource: KeySource

    // Destinations
    package var destinations: [Destination]
    package var defaultDestination: Destination

    // Labels
    package var configuredLabels: [String: String]
    package var systemLabels: [String: String] = makeSystemLabels()
    package var globalLabels: [String: String] {
        systemLabels.merging(configuredLabels, uniquingKeysWith: { l, r in r })
    }
}

// MARK: Nested types
extension Configuration {
    package struct OpenTelemetryEndpoint: Hashable, Equatable {
        package var hostname: String
        package var port: Int
        package var mtls: Bool
    }

    package struct OpenTelemetry: Hashable, Equatable, Decodable {
        /// Amount of time to wait after the first error received when publishing over gRPC
        package var defaultBackoff: Duration

        /// The maximum amount of time to wait between backoffs in a capped exponential backoff algorithm.
        package var maxBackoff: Duration
        /// Maximum amount of time to try to publish to an OTLP server before timing out.
        package var timeout: Duration?

    }

    package enum KeySource: Hashable, Equatable {
        case localCerts(Certificates)
        case keychain
        case none
    }

    package struct Certificates: Hashable, Equatable {
        package var mtlsPrivateKey: NIOSSLPrivateKey
        package var mtlsCertificateChain: [NIOSSLCertificate]
        package var mtlsTrustRoots: NIOSSLTrustRoots
    }

    package struct Destination: Equatable, Hashable {
        package var publishInterval: Duration = .seconds(60)
        package var workspace: String?
        package var namespace: String?
        package var clients: [String] = []
    }

    package struct FilterRule: Hashable, Equatable {
        package var client: String
        package var label: String
        package var minUpdateInterval: Duration = .seconds(0)
        package var minPublishInterval: Duration = .seconds(0)
        package var type: CloudMetricType
        package var destinations: [Destination] = []
        package var dimensions: [String: [String]] = [:]
    }

    package struct AuditLists: Hashable, Equatable {

        package var allowedMetrics: [FilterRule]
        package var ignoredMetrics: [String: [String]]
    }
}

// MARK: Decodable conformations.

extension Configuration: Decodable {

    private enum CodingKeys: String, CodingKey {
        case destinations = "Destinations"
        case metricDestinations = "MetricDestinations"
        case defaultDestination = "DefaultDestination"
        case globalLabels = "GlobalLabels"
        case useOpenTelemetryBackend = "UseOpenTelemetryBackend"
        case requireAllowList = "RequireAllowList"
        case openTelemetryEndpoint = "OpenTelemetryEndpoint"
        case openTelemetry = "OpenTelemetry"
        case auditLists = "AuditLists"
        case localCertificateConfig = "LocalCertificateConfig"
        case defaultHistogramBuckets = "DefaultHistogramBuckets"
        case auditLogThrottleIntervalSeconds = "AuditLogThrottleIntervalSeconds"
        case publishFailureThreshold = "PublishFailureThreshold"
    }

    /// Custom decoder as we need to support plist files out-in-the wild that use differences from our struct.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let destinations = try container.decodeIfPresent([Configuration.Destination].self, forKey: .destinations)

        // Config can specify both Destinations and MetricDestinations.
        // MetricDestinations takes priority
        if let metricDestinations = try container.decodeIfPresent([String : Configuration.Destination].self, forKey: .metricDestinations),
           metricDestinations.count > 0 {
            self.destinations = metricDestinations.map { name, dest in
                var destination = dest
                destination.workspace = name
                return destination
            }
        } else {
            self.destinations = destinations ?? []
        }

        self.defaultDestination = try container.decode(Configuration.Destination.self, forKey: .defaultDestination)
        self.systemLabels = try container.decode([String: String].self, forKey: .globalLabels)
        self.requireAllowList = try container.decodeIfPresent(Bool.self, forKey: .requireAllowList) ?? false
        if let openTelemetryEndpoint = try container.decodeIfPresent(Configuration.OpenTelemetryEndpoint.self,
                                                                     forKey: .openTelemetryEndpoint) {
            self.openTelemetryEndpoint = openTelemetryEndpoint
        } else {
            Self.logger.log("No OpenTelemetry endpoint configured, defaulting to localhost")
            self.openTelemetryEndpoint = .init(hostname: "localhost", port: 4_317, mtls: false)
        }
        self.openTelemetry = try container.decodeIfPresent(OpenTelemetry.self, forKey: .openTelemetry) ?? .init(defaultBackoff: .milliseconds(50), maxBackoff: .seconds(30))
        self.publishFailureThreshold = try container.decodeIfPresent(Int.self, forKey: .publishFailureThreshold) ?? 5
        self.auditLists = try container.decodeIfPresent(Configuration.AuditLists.self, forKey: .auditLists)
        self.keySource = try .init(localCertificateConfig: container.decodeIfPresent(ConfigPlistCertificateConfig.self, forKey: .localCertificateConfig))
        self.defaultHistogramBuckets = try container.decodeIfPresent([Double].self, forKey: .defaultHistogramBuckets) ?? []
        self.useOpenTelemetry = true
        if let auditLogThrottleIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .auditLogThrottleIntervalSeconds) {
            self.auditLogThrottleInterval = .seconds(auditLogThrottleIntervalSeconds)
        } else {
            self.auditLogThrottleInterval = .seconds(kCloudMetricsAuditLogThrottleIntervalDefault)
        }
        self.configuredLabels = try container.decodeIfPresent([String: String].self, forKey: .globalLabels) ?? [:]

        try self.updateDefaultDestination()
    }
}

extension Configuration.Destination: Decodable {
    private enum CodingKeys: String, CodingKey {
        case publishInterval = "PublishInterval"
        case workspace = "Workspace"
        case namespace = "Namespace"
        case clients = "Clients"
    }

    // Custom decoder required for backwards compatibility since plists encode `publishInterval` as an int,
    // whereas `Duration` decodes differently.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let publishInterval = try container.decodeIfPresent(Int.self, forKey: .publishInterval) {
            self.publishInterval = .seconds(publishInterval)
        }
        self.workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        self.namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
        if let clients = try container.decodeIfPresent([String].self, forKey: .clients) {
            self.clients = clients
        }
    }
}

/// Custom conformance due to legacy plists encoidng `DisableMtls` rather than `TLS`
extension Configuration.OpenTelemetryEndpoint: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hostname = "Hostname"
        case port = "Port"
        case disableMTLS = "DisableMtls"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hostname = try container.decode(String.self, forKey: .hostname)
        self.port = try container.decode(Int.self, forKey: .port)
        self.mtls = try !container.decode(Bool.self, forKey: .disableMTLS)

    }
}

extension Configuration.AuditLists: Decodable {
    private enum CodingKeys: String, CodingKey {
        case allowedMetrics = "AllowedMetrics"
        case ignoredMetrics = "IgnoredMetrics"
    }
}

/// Need custom Decodable implementation since we have backwards compatibility with plists that encode intervals as ints.
/// Also we need to encode `
extension Configuration.FilterRule: Decodable {
    private enum CodingKeys: String, CodingKey {
        case client = "Client"
        case label = "Label"
        case minUpdateInterval = "MinUpdateInterval"
        case minPublishInterval = "MinPublishInterval"
        case type = "Type"
        case destinations = "Destinations"
        case dimensions = "Dimensions"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.client = try container.decode(String.self, forKey: .client)
        self.label = try container.decode(String.self, forKey: .label)
        self.minUpdateInterval = try .seconds(container.decode(Int.self, forKey: .minUpdateInterval))
        self.minPublishInterval = try .seconds(container.decode(Int.self, forKey: .minPublishInterval))
        let typeAsString = try container.decodeIfPresent(String.self, forKey: .type)
        if let typeAsString {
            guard let type = CloudMetricType(rawValue: typeAsString) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.type],
                    debugDescription: "type \(typeAsString) is not a valid metric type"))
            }
            self.type = type
        } else {
            // If no type is present we use "all"
            self.type = .all
        }
        self.destinations = try container.decode([String].self, forKey: .destinations).map{
            try .init(id: $0)
        }
        self.dimensions = try container.decode([String: [String]].self, forKey: .dimensions)
    }
}

extension Configuration.Destination: CustomStringConvertible {
    internal var id: String {
        "\(workspace ?? "<none>")/\(namespace ?? "<none>")/\(publishInterval)"
    }

    package var description: String {
        "Destination{\(id)}"
    }

    internal init(id: String) throws {
        let components = id.split(separator: "/")
        if components.count < 2 {
            throw ConfigurationError.invalidDestination(id)
        }
        self.workspace = String(components[0])
        self.namespace = String(components[1])
        if components.count > 2, let interval = Int(components[3]) {
            self.publishInterval = .seconds(interval)
        }
    }
}

extension Configuration.Certificates: CustomStringConvertible {
    /// Don't print the private key!
    package var description: String {
        """
        trustRoots=\(self.mtlsTrustRoots)
        certChain=\(self.mtlsCertificateChain)
        """
    }
}

extension Configuration {
    package init(configurationFile: String, auditLists: Configuration.AuditLists? = nil) throws {
        Self.logger.log("Reading from provided configuration file: \(configurationFile, privacy: .public)")
        let decoder = PropertyListDecoder()
        self = try decoder.decode(
            Configuration.self,
            from: try Data(contentsOf: URL(filePath: configurationFile))
        )
        if let auditLists {
            self.auditLists = auditLists
            self.requireAllowList = true
        }
    }

    internal mutating func updateDefaultDestination() throws {
        var defaultDestinationFound = false
        var dedupDestinations: Set<String> = []
        for destination in destinations {

            if destination.namespace == defaultDestination.namespace,
               destination.workspace == defaultDestination.workspace {
                defaultDestination.publishInterval = destination.publishInterval
                defaultDestinationFound = true
            }

            let uniqueId = "\(destination.workspace ?? "")/\(destination.namespace ?? "")"
            if dedupDestinations.contains(uniqueId) {
                throw ConfigurationError.duplicateDestinationConfiguration(uniqueId)
            }
            dedupDestinations.insert(uniqueId)
        }
        if defaultDestinationFound == false {
            throw ConfigurationError.defaultDestinationNotFound
        }
    }

    static func makeSystemLabels() -> [String: String] {
        var labels = [String: String]()
        #if canImport(cloudOSInfo)
        if #_hasSymbol(CloudOSInfoProvider.self) {
            let cloudOSInfo = CloudOSInfoProvider()
            if #_hasSymbol(cloudOSInfo.observabilityLabels) {
                do {
                    let observabilityLabels = try cloudOSInfo.observabilityLabels()
                    labels.merge(observabilityLabels) { (_, new) in new }
                } catch {
                    Self.logger.log("Can't load observability labels: \(error, privacy: .public)")
                }
            }
        }
        #endif
        let nodeUDID = MobileGestalt.current.uniqueDeviceID
        if nodeUDID == nil {
            Self.logger.error("Can't get a valid UDID")
        }
        labels["_udid"] = nodeUDID ?? ""

        let hwModel = MobileGestalt.current.hwModelStr
        if hwModel == nil {
            Self.logger.error("Can't get a valid HWModel string")
        }
        labels["_hwmodel"] = hwModel ?? ""

        let systemCryptexVersion = self.systemCryptexVersion
        Self.logger.log("Loaded system cryptex version. system_cryptex_version=\(systemCryptexVersion ?? "unknown", privacy: .public)")
        labels["_systemcryptexversion"] = systemCryptexVersion ?? ""

        do {
            // Lookup the default projectID configured by darwin-init in CFPrefs.
            let cloudUsageTrackingDomain = "com.apple.acsi.cloudusagetrackingd"
            if let projectId = try preferencesStringValue("defaultProjectID", domain: cloudUsageTrackingDomain) {
                labels["_projectid"] = projectId
            }
        } catch {
            Self.logger.error("Can't get the project ID from CFPrefs. error=\(error, privacy: .public)")
        }

        let acecDomain = "com.apple.acec"
        if let acecAccountID = try? preferencesStringValue("AccountID", domain: acecDomain) {
            labels["_acecAccountID"] = acecAccountID
        }

    #if os(macOS)
        #if canImport(MobileGestalt, _version: 1444)
            if MobileGestalt.current.isComputePacketBridge {
                labels["_type"] = "apb"
            } else {
                labels["_type"] = "node"
            }
        #else
            labels["_type"] = "node"
        #endif
    #elseif os(iOS)
        if MobileGestalt.current.isComputeController {
            labels["_type"] = "bmc"
        } else {
            labels["_type"] = "node"
        }
    #endif

        self.logger.log("Loaded system labels. labels=\(labels, privacy: .public)")
        return labels
    }

    internal static var systemCryptexVersion: String? {
        #if canImport(cloudOSInfo)
        if #_hasSymbol(CloudOSInfoProvider.self) {
            let cloudOSInfo = CloudOSInfoProvider()
            do {
                let buildVersion = try cloudOSInfo.cloudOSBuildVersion()
                return buildVersion
            } catch {
                Self.logger.error("""
                    Unable to determine build version from deployment manifest. \
                    Will attempt to fallback to cryptex version.plist. \
                    error=\(error, privacy: .public)
                    """)
            }

            do {
                let buildVersion = try cloudOSInfo.extractVersionFromSupportCryptex()
                return buildVersion
            } catch {
                Self.logger.error("""
                    Failed to determine build version from cryptex. \
                    error=\(error, privacy: .public)
                    """)
                return nil
            }
        }
        #endif

        return nil
    }
}
