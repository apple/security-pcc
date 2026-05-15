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
import CloudBoardCommon
import CloudBoardLogging
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import NIOCore
import os

extension CFPreferences {
    public static var cloudboardPreferencesDomain: String {
        "com.apple.cloudos.cloudboardd"
    }
}

private let logger: Logger = .init(
    subsystem: "com.apple.cloudos.cloudboard",
    category: "CloudBoardDConfiguration"
)

public struct CloudBoardDConfiguration: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case serviceDiscovery = "ServiceDiscovery"
        case grpc = "GRPC"
        case heartbeat = "Heartbeat"
        case lifecycleManager = "LifecycleManager"
        case _prewarming = "Prewarming"
        case systemServiceMonitor = "SystemServiceMonitor"
        case _load = "Load"
        case _statusServer = "StatusServer"
        // deliberately *not* serialising _secureConfig
    }

    public var serviceDiscovery: ServiceDiscovery?
    public var heartbeat: Heartbeat?
    public var grpc: GRPCConfiguration?
    public var lifecycleManager: LifecycleManager?
    public var systemServiceMonitor: SystemServiceMonitorConfiguration?
    private var _statusServer: StatusServerConfiguration?
    private var _load: LoadConfiguration?
    private var _prewarming: PrewarmingConfiguration?
    private var _secureConfig: SecureConfig? = nil

    public var secureConfig: SecureConfig {
        /// Attempting to do this in a real run means we didn't apply security checks,
        /// this should be instantly terminal
        precondition(self._secureConfig != nil, "Attempt to access secureconfig when it has not been hooked up")
        return self._secureConfig!
    }

    /// This is not for direct use  _always_ go through construction/decoding then call ``applySecureConfig``
    /// before letting anything else interact with this instance
    private init(
        serviceDiscovery: ServiceDiscovery? = nil,
        heartbeat: Heartbeat? = nil,
        grpc: GRPCConfiguration? = nil,
        lifecycleManager: LifecycleManager? = nil,
        systemServiceMonitor: SystemServiceMonitorConfiguration? = nil,
        load: LoadConfiguration? = nil,
        prewarming: PrewarmingConfiguration? = nil,
        statusServer: StatusServerConfiguration? = nil
    ) {
        self.serviceDiscovery = serviceDiscovery
        self.heartbeat = heartbeat
        self.grpc = grpc
        self.lifecycleManager = lifecycleManager
        self.systemServiceMonitor = systemServiceMonitor
        self._load = load
        self._prewarming = prewarming
        self._statusServer = statusServer
    }

    /// This is not for direct use except in tests
    /// It *does not validate* `secureconfig`
    internal init(
        secureConfig: SecureConfig,
        serviceDiscovery: ServiceDiscovery? = nil,
        heartbeat: Heartbeat? = nil,
        grpc: GRPCConfiguration? = nil,
        lifecycleManager: LifecycleManager? = nil,
        systemServiceMonitor: SystemServiceMonitorConfiguration? = nil,
        load: LoadConfiguration? = nil,
        prewarming: PrewarmingConfiguration? = nil,
        statusServer: StatusServerConfiguration? = nil
    ) {
        self._secureConfig = secureConfig
        self.serviceDiscovery = serviceDiscovery
        self.heartbeat = heartbeat
        self.grpc = grpc
        self.lifecycleManager = lifecycleManager
        self.systemServiceMonitor = systemServiceMonitor
        self._load = load
        self._prewarming = prewarming
        self._statusServer = statusServer
    }

    private mutating func applySecureConfig(_ secureConfig: SecureConfig) throws {
        self._secureConfig = secureConfig
        // after setting up everything else validate
        if secureConfig.shouldEnforceAppleInfrastructureSecurityConfig {
            try self.enforceAppleInfrastructureSecurityConfig()
        }
    }

    /// Create an instance of the config which has been validated against the `secureConfig`
    /// throws if validation fails
    public static func createAndValidate(
        secureConfig: SecureConfig,
        serviceDiscovery: ServiceDiscovery? = nil,
        heartbeat: Heartbeat? = nil,
        grpc: GRPCConfiguration? = nil,
        lifecycleManager: LifecycleManager? = nil,
        load: LoadConfiguration? = nil,
        prewarming: PrewarmingConfiguration? = nil,
        statusServer: StatusServerConfiguration? = nil
    ) throws -> CloudBoardDConfiguration {
        var config = CloudBoardDConfiguration(
            serviceDiscovery: serviceDiscovery,
            heartbeat: heartbeat,
            grpc: grpc,
            lifecycleManager: lifecycleManager,
            load: load,
            prewarming: prewarming,
            statusServer: statusServer
        )
        try config.applySecureConfig(secureConfig)
        return config
    }

    public var load: LoadConfiguration {
        self._load ?? .init()
    }

    public var prewarming: PrewarmingConfiguration {
        return self._prewarming ?? .init()
    }

    public var statusServer: StatusServerConfiguration {
        self._statusServer ?? .init()
    }

    public enum CloudBoardDConfigurationError: Error {
        case missingServiceDiscoveryTLSConfig
        case disallowedURLScheme
        case missingGRPCPeerAPRN
    }

    /// Load the cloudboard daemon specific config,
    /// Also load the ``SecureConfig`` and apply any validation rules specified in it  to the parameters
    /// Any errors in validation will reult in throwing an error
    public static func fromFile(
        path: String,
        secureConfigLoader: SecureConfigLoader
    ) throws -> CloudBoardDConfiguration {
        var config: CloudBoardDConfiguration
        do {
            logger.info("Loading configuration from file \(path, privacy: .public)")
            let fileContents = try Data(contentsOf: URL(filePath: path))
            let decoder = PropertyListDecoder()
            config = try decoder.decode(CloudBoardDConfiguration.self, from: fileContents)
            config.logWarningForMissingConfigurations()
        } catch {
            logger.error("Unable to load config from file: \(String(unredacted: error), privacy: .public)")
            throw error
        }

        let secureConfig: SecureConfig
        do {
            secureConfig = try secureConfigLoader.load()
        } catch {
            logger.error("Error loading secure config: \(String(unredacted: error), privacy: .public)")
            throw error
        }
        try config.applySecureConfig(secureConfig)
        return config
    }

    public static func fromPreferences(secureConfigLoader: SecureConfigLoader = .real) throws
    -> CloudBoardDConfiguration {
        logger.info(
            "Loading configuration from preferences \(CFPreferences.cloudboardPreferencesDomain, privacy: .public)"
        )
        let preferences = CFPreferences(domain: CFPreferences.cloudboardPreferencesDomain)
        do {
            return try self.fromPreferences(preferences, secureConfigLoader: secureConfigLoader)
        } catch {
            logger.error("Error loading configuration from preferences: \(String(unredacted: error), privacy: .public)")
            throw error
        }
    }

    /// Enforces security configuration if running on Apple infrastructure (as opposed to e.g. the VRE) with a
    /// 'customer' security policy
    private mutating func enforceAppleInfrastructureSecurityConfig() throws {
        logger.info("Enforcing Apple infrastructure security config")

        // service discovery
        if self.serviceDiscovery != nil {
            guard let serviceDiscoveryTLSConfig = serviceDiscovery!.tlsConfig else {
                logger.error("Missing ServiceDiscovery TLS configuration")
                throw CloudBoardDConfigurationError.missingServiceDiscoveryTLSConfig
            }

            if !serviceDiscoveryTLSConfig.enable {
                logger.error("Overriding ServiceDiscovery TLS configuration with new value Enable=true")
                self.serviceDiscovery!.tlsConfig!._enable = true
            }

            if !serviceDiscoveryTLSConfig.enablemTLS {
                logger.error("Overriding ServiceDiscovery TLS configuration with new value EnablemTLS=true")
                self.serviceDiscovery!.tlsConfig!._enablemTLS = true
            }
        } else {
            logger.warning("No service discovery configuration present")
        }

        // heartbeat
        if self.heartbeat != nil {
            if self.heartbeat!.serviceURL.scheme?.lowercased() != "https" {
                logger.error("Error: Heartbeat scheme is not 'https'")
                throw CloudBoardDConfigurationError.disallowedURLScheme
            }

            if self.heartbeat!.allowInsecure {
                logger.error("Overriding Heartbeat configuration with new value AllowInsecure=false")
                self.heartbeat!.allowInsecure = false
            }

            if self.heartbeat!.disableMTLS {
                logger.error("Overriding Heartbeat configuration with new value DisableMTLS=false")
                self.heartbeat!.disableMTLS = false
            }
        } else {
            logger.warning("No Heartbeat configuration present")
        }

        // gRPC
        guard var grpcConfig = self.grpc else {
            logger.error("No GRPC configuration present. GRPC peer APRN must be configured.")
            throw CloudBoardDConfigurationError.missingGRPCPeerAPRN
        }
        let expectedPeerAPRNs = grpcConfig.expectedPeerAPRNs ?? grpcConfig.expectedPeerAPRN.map { [$0] } ?? []
        guard !expectedPeerAPRNs.isEmpty else {
            logger.error("Missing GRPC peer APRN")
            throw CloudBoardDConfigurationError.missingGRPCPeerAPRN
        }

        if grpcConfig.useSelfSignedCertificate {
            logger.error("Overriding GRPC configuration with new value UseSelfSignedCertificate=false")
            grpcConfig.useSelfSignedCertificate = false
            self.grpc = grpcConfig
        }
    }

    public static func fromPreferences(
        _ preferences: CFPreferences,
        secureConfigLoader: SecureConfigLoader
    ) throws -> CloudBoardDConfiguration {
        let decoder = CFPreferenceDecoder()
        var configuration = try decoder.decode(CloudBoardDConfiguration.self, from: preferences)
        configuration.logWarningForMissingConfigurations()

        let secureConfig: SecureConfig
        do {
            secureConfig = try secureConfigLoader.load()
        } catch {
            logger.error("Error loading secure config: \(String(unredacted: error), privacy: .public)")
            throw error
        }
        try configuration.applySecureConfig(secureConfig)

        return configuration
    }

    private func logWarningForMissingConfigurations() {
        if self.serviceDiscovery == nil {
            logger.warning("No service discovery config to load")
        }

        if self.grpc == nil {
            logger.warning("No grpc config to load, falling back to defaults")
        }

        if self.lifecycleManager == nil {
            logger.warning("No lifecycle manager config to load, falling back to defaults")
        }
    }
}

extension CloudBoardDConfiguration {
    public struct ServiceDiscovery: Codable, Hashable, Sendable {
        enum CodingKeys: String, CodingKey {
            case targetHost = "TargetHost"
            case targetPort = "TargetPort"
            case serviceRegion = "ServiceRegion"
            case serviceZone = "ServiceZone"
            case lbConfig = "LBConfig"
            case tlsConfig = "TLS"
            case backoffConfig = "BackoffConfig"
            case keepalive = "Keepalive"
            case cellID = "CellID"
        }

        /// Service discovery host address
        public var targetHost: String
        /// Service discovery port
        public var targetPort: Int
        /// Service discovery region
        public var serviceRegion: String
        /// Service discovery zone
        public var serviceZone: String?
        /// Metadata for PCC Gateway that is announced to service discovery alongside the workload metadata. Expected to
        /// contain "cluster" and "environment" keys and values.
        public var lbConfig: [String: String]
        /// TLS configuration for all service discovery connections
        public var tlsConfig: TLSConfiguration?
        /// Backoff configuration for service discovery connections on failures
        public var backoffConfig: GRPCClientConfiguration.ConnectionBackoff?
        /// Keepalive configuration for service discovery connections
        public var keepalive: Keepalive?
        /// Cell ID to include in service discovery as "cellId" subfield value under "description" field. Used by PCC
        /// Gateway.
        public var cellID: String?

        internal init(
            targetHost: String,
            targetPort: Int,
            serviceRegion: String,
            serviceZone: String?,
            lbConfig: [String: String],
            tlsConfig: GRPCClientConfiguration.TLSConfiguration? = nil,
            backoffConfig: GRPCClientConfiguration.ConnectionBackoff? = nil,
            keepalive: CloudBoardDConfiguration.Keepalive? = nil,
            cellID: String?
        ) {
            self.targetHost = targetHost
            self.targetPort = targetPort
            self.serviceRegion = serviceRegion
            self.serviceZone = serviceZone
            self.lbConfig = lbConfig
            self.tlsConfig = tlsConfig
            self.backoffConfig = backoffConfig
            self.keepalive = keepalive
            self.cellID = cellID
        }
    }
}

extension CloudBoardDConfiguration {
    public struct LifecycleManager: Codable, Hashable, Sendable {
        // enforceAllStateChecks deliberately not coded,
        // it is for unit testing only
        enum CodingKeys: String, CodingKey {
            case _drainTimeoutSecs = "DrainTimeoutSeconds"
        }

        public init() {}

        init(
            _drainTimeoutSecs: Int64? = nil,
            enforceAllStateChecks: Bool = true
        ) {
            self._drainTimeoutSecs = _drainTimeoutSecs
            self.enforceAllStateChecks = enforceAllStateChecks
        }

        var _drainTimeoutSecs: Int64?

        /// Time after which cloudboardd signals that the drain completed irregardless of any requests still in-flight
        public var drainTimeout: ContinuousClock.Duration {
            self._drainTimeoutSecs.map { Duration.seconds($0) } ?? .seconds(60 * 15) // 15 minute default
        }

        public var enforceAllStateChecks: Bool = true
    }
}

extension CloudBoardDConfiguration {
    public struct SystemServiceMonitorConfiguration: Codable, Hashable, Sendable {
        enum CodingKeys: String, CodingKey {
            case _enableSSMStatusReporting = "EnableSSMStatusReporting"
        }

        // flag to enable SSM status reporting
        private var _enableSSMStatusReporting: Bool?

        public init(_enableSSMStatusReporting: Bool? = nil) {
            self._enableSSMStatusReporting = _enableSSMStatusReporting
        }

        // Disabling SSM reporting by default. Once available broadly, we can change the default.
        public var enableSSMStatusReporting: Bool {
            get { self._enableSSMStatusReporting ?? false }
            set { self._enableSSMStatusReporting = newValue }
        }

        public var description: String {
            """
            SystemServiceMonitorConfiguration(\
            enableSSMStatusReporting: \(self.enableSSMStatusReporting) \
            )
            """
        }
    }
}

extension CloudBoardDConfiguration {
    public struct Keepalive: Codable, Hashable, Sendable {
        enum CodingKeys: String, CodingKey {
            case _timeToFirstPingMS = "TimeToFirstPingMilliseconds"
            case _timeoutMS = "TimeoutMilliseconds"
            case _permitWithoutCalls = "PermitWithoutCalls"
            case _maxPingsWithoutData = "MaxPingsWithoutData"
            case _intervalMS = "IntervalMilliseconds"
        }

        var _timeToFirstPingMS: Int?
        var _timeoutMS: Int?
        var _permitWithoutCalls: Bool?
        var _maxPingsWithoutData: Int?
        var _intervalMS: Int?

        public init() {}

        internal init(
            _timeToFirstPingMS: Int? = nil,
            _timeoutMS: Int? = nil,
            _permitWithoutCalls: Bool? = nil,
            _maxPingsWithoutData: Int? = nil,
            _intervalMS: Int? = nil
        ) {
            self._timeToFirstPingMS = _timeToFirstPingMS
            self._timeoutMS = _timeoutMS
            self._permitWithoutCalls = _permitWithoutCalls
            self._maxPingsWithoutData = _maxPingsWithoutData
            self._intervalMS = _intervalMS
        }

        /// The amount of time to wait before sending a keepalive ping
        public var timeToFirstPing: Duration {
            self._timeToFirstPingMS.map { .milliseconds(Int64($0)) } ?? .seconds(15)
        }

        /// The amount of time to wait for an acknowledgment. This value must be less than interval.
        public var timeout: Duration {
            self._timeoutMS.map { .milliseconds(Int64($0)) } ?? .seconds(2)
        }

        /// Send keepalive pings even if there are no calls in flight.
        public var permitWithoutCalls: Bool {
            self._permitWithoutCalls ?? true
        }

        /// Maximum number of pings that can be sent when there is no data/header frame to be sent
        public var maxPingsWithoutData: Int {
            self._maxPingsWithoutData ?? 0
        }

        /// If there are no data/header frames being received: the minimum amount of time to wait between successive
        /// pings.
        public var interval: Duration {
            self._intervalMS.map { .milliseconds(Int64($0)) } ?? .seconds(15)
        }
    }
}

extension CloudBoardDConfiguration {
    public struct GRPCConfiguration: Codable, Hashable, Sendable, CustomStringConvertible {
        enum CodingKeys: String, CodingKey {
            case listeningIP = "ListeningIP"
            case listeningPort = "ListeningPort"
            case forceIPv6Resolution = "ForceIPv6Resolution"
            case expectedPeerAPRN = "ExpectedPeerAPRN"
            case expectedPeerAPRNs = "ExpectedPeerAPRNs"
            case keepalive = "Keepalive"
            case _useSelfSignedCertificate = "UseSelfSignedCertificate"
        }

        /// IP address GRPC server listens on. If not provided, the interface and corresponding IP to bind to is
        /// determined by making a UDP connection to the configured service discovery endpoint. If no service discovery
        /// configuration is provided, the server will listen on localhost only.
        public var listeningIP: String?
        /// GRPC server port. Defaults to 4442.
        public var listeningPort: Int?

        /// Forces the use of IPv6 only when determining which IP address to bind to. This has no effect if
        /// ``listeningIP`` is provided.
        public var forceIPv6Resolution: Bool?

        /// The APRN of the peer that the server should expect. If not provided, the server will not validate the
        /// client's identity
        ///
        /// DEPRECATED: Use ``expectedPeerAPRNs`` instead
        public var expectedPeerAPRN: String?

        /// List of candidate APRNs of the peer that the server should expect. If not provided, the server will not
        /// validate the client's identity. Otherwise the server validates that the peer certificate contains at least
        /// one of the provided APRNs.
        public var expectedPeerAPRNs: [String]?

        /// Keepalive configuration for the GRPC server
        public var keepalive: Keepalive?

        private var _useSelfSignedCertificate: Bool?

        public init(
            listeningIP: String? = nil,
            listeningPort: Int? = nil,
            forceIPv6Resolution: Bool? = nil,
            useSelfSignedCertificate: Bool? = nil,
            expectedPeerAPRNs: [String]? = nil,
            keepAlive: Keepalive? = nil
        ) {
            self.listeningIP = listeningIP
            self.listeningPort = listeningPort
            self.forceIPv6Resolution = forceIPv6Resolution
            self._useSelfSignedCertificate = useSelfSignedCertificate
            self.expectedPeerAPRNs = expectedPeerAPRNs
            self.keepalive = keepAlive
        }

        /// If true, cloudboardd will generate and use a self-signed server certificate instead of using a Narrative
        /// identity
        public var useSelfSignedCertificate: Bool {
            get { self._useSelfSignedCertificate ?? false }
            set { self._useSelfSignedCertificate = newValue }
        }

        public var description: String {
            """
            GRPCConfiguration(\
            listeningIP: \(String(describing: self.listeningIP)), \
            listeningPort: \(String(describing: self.listeningPort)), \
            forceIPv6Resolution: \(self.forceIPv6Resolution.map { "\($0)" } ?? "nil"), \
            useSelfSignedCertificate: \(self.useSelfSignedCertificate), \
            expectedPeerAPRNs: \(self.expectedPeerAPRNs.map { $0.joined(separator: ", ") } ?? "nil")
            keepalive: \(String(describing: self.keepalive))
            )
            """
        }
    }

    public struct Heartbeat: Codable, Hashable, Sendable {
        private var _serviceURL: URL
        private var _allowInsecure: Bool?
        private var _disableMTLS: Bool?
        private var _attemptCount: Int?
        private var _retryDelay: TimeInterval?
        private var _httpRequestTimeout: TimeInterval?
        private var _tickInterval: TimeInterval?
        private var _maximumToleranceRatio: Double?
        private var _additionalProperties: [String: String]?

        init(
            serviceURL: URL,
            allowInsecure: Bool? = nil,
            disableMTLS: Bool? = nil,
            attemptCount: Int? = nil,
            retryDelay: TimeInterval? = nil,
            httpRequestTimeout: TimeInterval? = nil,
            tickInterval: TimeInterval? = nil,
            maximumToleranceRatio: Double? = nil,
            additionalProperties: [String: String]? = nil
        ) {
            self._serviceURL = serviceURL
            self._allowInsecure = allowInsecure
            self._disableMTLS = disableMTLS
            self._attemptCount = attemptCount
            self._retryDelay = retryDelay
            self._httpRequestTimeout = httpRequestTimeout
            self._tickInterval = tickInterval
            self._maximumToleranceRatio = maximumToleranceRatio
            self._additionalProperties = additionalProperties
        }

        enum CodingKeys: String, CodingKey {
            case _serviceURL = "ServiceURL"
            case _allowInsecure = "AllowInsecure"
            case _disableMTLS = "DisableMTLS"
            case _attemptCount = "AttemptCount"
            case _retryDelay = "RetryDelay"
            case _httpRequestTimeout = "HTTPRequestTimeout"
            case _tickInterval = "TickInterval"
            case _maximumToleranceRatio = "MaximumToleranceRatio"
            case _additionalProperties = "AdditionalProperties"
        }

        /// Heartbeat service endpoint URL
        public var serviceURL: URL {
            self._serviceURL
        }

        /// If true, allows insecure HTTP endpoints to be used, otherwise HTTPS is enforced
        public var allowInsecure: Bool {
            get { self._allowInsecure ?? false }
            set { self._allowInsecure = newValue }
        }

        /// If true, no client certificate is sent
        public var disableMTLS: Bool {
            get { self._disableMTLS ?? false }
            set { self._disableMTLS = newValue }
        }

        /// Number of attempts to send heartbeat signal before failing the request
        public var attemptCount: Int {
            self._attemptCount ?? 3
        }

        /// Time between retries of failed heartbeat signal requests
        public var retryDelay: TimeInterval {
            self._retryDelay ?? 5.0
        }

        /// Timeout for HTTP requests to the heartbeat service
        public var httpRequestTimeout: TimeInterval {
            self._httpRequestTimeout ?? 30.0
        }

        /// Interval between sending heartbeat signals to the server
        public var tickInterval: TimeInterval {
            self._tickInterval ?? 30.0
        }

        /// Used to determine the jitter to add to tick interval
        public var maximumToleranceRatio: Double {
            self._maximumToleranceRatio ?? 0.25
        }

        public var additionalProperties: [String: String]? {
            self._additionalProperties
        }
    }

    public struct StatusServerConfiguration: Codable, Hashable, Sendable, CustomStringConvertible {
        /// Default status server port
        public static let defaultPort = 50052

        enum CodingKeys: String, CodingKey {
            case _port = "Port"
        }

        private var _port: Int?

        /// Status server port. Defaults to 50052.
        public var port: Int {
            self._port ?? Self.defaultPort
        }

        public init(port: Int? = nil) {
            self._port = port
        }

        public var description: String {
            "StatusServer(port: \(self.port))"
        }
    }
}

extension CloudBoardDConfiguration {
    public struct LoadConfiguration: Codable, Hashable, Sendable, CustomStringConvertible {
        enum CodingKeys: String, CodingKey {
            case _enforceConcurrentRequestLimit = "EnforceConcurrentRequestLimit"
            case _overrideCloudAppConcurrentRequests = "OverrideCloudAppConcurrentRequests"
            case _maxCumulativeRequestBytes = "MaxCumulativeRequestBytes"
        }

        private var _enforceConcurrentRequestLimit: Bool?
        private var _overrideCloudAppConcurrentRequests: Bool?
        var _maxCumulativeRequestBytes: Int?

        /// If true, CloudBoard rejects incoming requests if we currently handle the maximum number of requests as
        /// configured by the workload controller
        public var enforceConcurrentRequestLimit: Bool {
            self._enforceConcurrentRequestLimit ?? true
        }

        /// If true, cloudboardd takes over the responsibility from the workload controller of updating the current
        /// request number for load status updates
        public var overrideCloudAppConcurrentRequests: Bool {
            self._overrideCloudAppConcurrentRequests ?? true
        }

        /// Maximum number of request bytes across chunks. When reached, cloudboardd aborts the request.
        public var maxCumulativeRequestBytes: Int {
            self._maxCumulativeRequestBytes ?? 10_485_760 // 10 MiB
        }

        init(
            enforceConcurrentRequestLimit: Bool? = nil,
            overrideCloudAppConcurrentRequests: Bool? = nil,
            maxCumulativeRequestBytes: Int? = nil
        ) {
            self._enforceConcurrentRequestLimit = enforceConcurrentRequestLimit
            self._overrideCloudAppConcurrentRequests = overrideCloudAppConcurrentRequests
            self._maxCumulativeRequestBytes = maxCumulativeRequestBytes
        }

        public var description: String {
            """
            LoadConfiguration(\
            enforceConcurrentRequestLimit: \(self.enforceConcurrentRequestLimit) \
            overrideCloudAppConcurrentRequests: \(self.overrideCloudAppConcurrentRequests) \
            maxCumulativeRequestBytes: \(self.maxCumulativeRequestBytes) \
            )
            """
        }
    }
}

extension CloudBoardDConfiguration {
    public struct PrewarmingConfiguration: Codable, Hashable, Sendable, CustomStringConvertible {
        enum CodingKeys: String, CodingKey {
            case prewarmedPoolSize = "PrewarmedPoolSize"
            case maxProcessCount = "MaxProcessCount"
        }

        /// Number of cb_jobhelper and cloud app process pairs to keep pre-warmed. The number of processes in the pool
        /// can be lower if maxProcessCount minus the number of request-handling processes is smaller then the value
        /// configured here.
        public var prewarmedPoolSize: Int?
        /// Total limit of cb_jobhelper and cloud app process pairs including both inactive pre-warmed pairs as well as
        /// active request-handling pairs.
        public var maxProcessCount: Int?

        package init(prewarmedPoolSize: Int? = nil, maxProcessCount: Int? = nil) {
            self.prewarmedPoolSize = prewarmedPoolSize
            self.maxProcessCount = maxProcessCount
        }

        public var description: String {
            """
            PrewarmingConfiguration(\
            prewarmedPoolSize: \(self.prewarmedPoolSize.map { "\($0)" } ?? "nil") \
            maxProcessCount: \(self.maxProcessCount.map { "\($0)" } ?? "nil") \
            )
            """
        }
    }
}

extension ClientConnectionKeepalive {
    public init(_ config: CloudBoardDConfiguration.Keepalive?) {
        let resolved = config ?? .init()
        self = .init(
            interval: .init(resolved.timeToFirstPing),
            timeout: .init(resolved.timeout),
            permitWithoutCalls: resolved.permitWithoutCalls,
            maximumPingsWithoutData: UInt(resolved.maxPingsWithoutData),
            minimumSentPingIntervalWithoutData: .init(resolved.interval)
        )
    }
}

extension ServerConnectionKeepalive {
    public init(_ config: CloudBoardDConfiguration.Keepalive?) {
        let resolved = config ?? .init()
        self = .init(
            interval: .init(resolved.timeToFirstPing),
            timeout: .init(resolved.timeout),
            permitWithoutCalls: resolved.permitWithoutCalls,
            maximumPingsWithoutData: UInt(resolved.maxPingsWithoutData),
            minimumSentPingIntervalWithoutData: .init(resolved.interval)
        )
    }
}
