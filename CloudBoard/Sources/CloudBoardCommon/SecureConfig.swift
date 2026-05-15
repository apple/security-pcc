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

import os
@_weakLinked import SecureConfigDB

private enum SecureConfigError: Error {
    case secureConfigDBNotAvailable
    case mockConfigNotPermitted
    case unknownCloudApp(String)
    case duplicatePort(cloudApp: String, port: Int)
    case unsupportedAuthContextDistributionPolicy
    case workloadTagValueNotSetForKey(key: String)
    case unableToParseWorkloadTags(key: String)
    case workloadNameNotSetForController(String)
    case invalidURL(String)
}

public enum SecureConfigLoader: Sendable {
    case real
    case mock(SecureConfig)

    public func load() throws -> SecureConfig {
        let realSecureConfig: SecureConfig?
        if #_hasSymbol(SecureConfigParameters.self) {
            let secureConfigParameters = try SecureConfigParameters.loadContents()
            realSecureConfig = try SecureConfig(parameters: .init(secureConfigParameters))
        } else {
            realSecureConfig = nil
        }
        switch self {
        case .real:
            guard let realSecureConfig else {
                throw SecureConfigError.secureConfigDBNotAvailable
            }
            return realSecureConfig
        case .mock(let secureConfig):
            if let realSecureConfig {
                switch realSecureConfig.parameters.securityPolicy {
                case .carry, .customer:
                    throw SecureConfigError.mockConfigNotPermitted
                case .none:
                    return secureConfig
                }
            }
            return secureConfig
        }
    }
}

public struct SecureConfig: Hashable, Sendable {
    static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "SecureConfig"
    )

    let parameters: Parameters

    public init(parameters: Parameters) {
        self.parameters = parameters
    }

    public var securityPolicy: Parameters.SecurityPolicy {
        self.parameters.securityPolicy
    }

    public var shouldEnforceAppleInfrastructureSecurityConfig: Bool {
        return self.parameters.disableAppleInfrastructureEnforcementForResearch != true
            && self.forceSecurityConfigurationOn
    }

    public var forceSecurityConfigurationOn: Bool {
        switch self.parameters.securityPolicy {
        case .none, .carry:
            return false
        case .customer:
            return true
        }
    }

    /// Is this instance a proxy or not
    public var isProxy: Bool {
        return self.parameters.isProxy
    }

    /// No actual request chunks should reach this instance,
    /// Request bypass should ensure no request is received and a failure is terminal
    public func enforceRequestBypass(cloudApp: String) throws -> Bool {
        if let enforceBypass = try cloudAppConfig(cloudApp: cloudApp).enforceRequestBypass {
            return enforceBypass
        } else {
            if self.isProxy, self.forceSecurityConfigurationOn {
                return true
            }
            return self.parameters.enforceRequestBypass
        }
    }

    public var routingGroupAliases: [String]? {
        self.parameters.routingGroupAliases
    }

    public var grpcForceIPv6Resolution: Bool? {
        self.parameters.grpcForceIPv6Resolution
    }

    public var convergenceSpanID: String {
        self.parameters.convergenceSpanID
    }

    public var convergenceTraceID: String {
        self.parameters.convergenceTraceID
    }

    public var cloudAppNames: [String] {
        self.parameters.cloudAppNames
    }

    public func cloudAppPort(cloudApp: String) throws -> Int? {
        return try self.cloudAppConfig(cloudApp: cloudApp).port
    }

    public func cloudAppConfig(cloudApp: String) throws -> CloudAppConfig {
        guard let config = self.parameters.cloudAppConfigMap[cloudApp] else {
            throw SecureConfigError.unknownCloudApp(cloudApp)
        }
        return config
    }

    public var bridgeDaemonConfig: BridgeDaemonConfig {
        if self.shouldEnforceAppleInfrastructureSecurityConfig {
            self.parameters.bridgeDaemonConfig.copyWithSecurityEnforcement()
        } else {
            self.parameters.bridgeDaemonConfig
        }
    }
}

extension SecureConfig {
    public struct TransitiveTrustCloudAppConfig: Sendable, Hashable {
        /// The policy/app specific defaults will apply in full
        /// this is the default mode, altering the values from config outside of testing
        /// is considered an unusual case outside of the VRE
        public static let noChanges = TransitiveTrustCloudAppConfig()

        /// Must match the rawValue of `SelectionNegotiation/OperatingMode`
        public let operatingMode: String?
        public let multiGroup: Bool?
        public let pickRequiredEnsemblesFromROPES: Int?
        public let pickAllowedEnsemblesFromProxy: Int?
        public let maxTrustedEnsembleInstances: Int?
        public let trustingEnsembleImpliesTrustingRack: Bool?

        internal init(
            operatingMode: String? = nil,
            multiGroup: Bool? = nil,
            pickRequiredEnsemblesFromROPES: Int? = nil,
            pickAllowedEnsemblesFromProxy: Int? = nil,
            maxTrustedEnsembleInstances: Int? = nil,
            trustingEnsembleImpliesTrustingRack: Bool? = nil
        ) {
            self.operatingMode = operatingMode
            self.multiGroup = multiGroup
            self.pickRequiredEnsemblesFromROPES = pickRequiredEnsemblesFromROPES
            self.pickAllowedEnsemblesFromProxy = pickAllowedEnsemblesFromProxy
            self.maxTrustedEnsembleInstances = maxTrustedEnsembleInstances
            self.trustingEnsembleImpliesTrustingRack = trustingEnsembleImpliesTrustingRack
        }
    }
}

extension SecureConfig {
    public struct ShadowCloudAppConfig: Sendable, Hashable {
        /// This is the default state - no shadowing
        public static let notShadowed = ShadowCloudAppConfig()

        /// What to do as the shadow controller
        public enum CloudControllerMode: String, CaseIterable, Sendable {
            /// Leave whatever cloud controller should be running, running
            case original
            /// Use config driven fixed values and register a healthy service
            /// No communication with the remote happens
            case fixed
            /// Talk to the remote and let it control (almost) everything
            case remote
        }

        /// Unless this is true nothing else matters
        /// but we still make sure all other values are "safe" if this is false
        public let enabled: Bool
        /// shadow the cloud apps (defaults to true if enabled)
        public let remoteCloudApps: Bool
        /// How to handle the controller (defaults to fixed if enabled)
        public let cloudController: CloudControllerMode
        /// The remote host to connect to (defaults to "localhost" if enabled)
        public let remoteHost: String
        /// The remote port to connect to, (defaults to 4430 if enabled so registrations can't collide)
        public let remotePort: Int

        /// Used in .fixed mode - defaults to 1
        public let fixedOptimalBatchSize: Int
        /// Used in .fixed mode - defaults to 1
        public let fixedMaxBatchSize: Int
        /// Used in .fixed mode, and if not specified by the remote directly.
        /// Defaults to "unknown-workload" when used.
        /// In the VRE this doesn't normally matter.
        /// If someone is trying to make a shadowed instance work with ROPES setting this properly
        /// will be required
        public let workloadName: String

        /// Safe defaults for not being enabled
        public init() {
            self.enabled = false
            self.remoteCloudApps = false
            self.cloudController = .original
            self.remoteHost = ""
            self.remotePort = 0
            self.fixedOptimalBatchSize = 0
            self.fixedMaxBatchSize = 0
            self.workloadName = ""
        }

        /// Construct from config, if configured in a way that breaks the configured policy this will
        /// result in a detailed fatalError
        internal init(
            // This is deliberately the low level form so we always consider
            // the implications of the full precision possibilities
            securityPolicy: SecureConfigSecurityPolicy,
            disableAppleInfrastructureEnforcementForResearch: Bool,
            enabled: Bool,
            remoteCloudApps: Bool?,
            cloudController: String?,
            remoteHost: String?,
            remotePort: Int?,
            fixedOptimalBatchSize: Int?,
            fixedMaxBatchSize: Int?,
            workloadName: String?
        ) {
            guard enabled else {
                self.init()
                return
            }
            switch securityPolicy {
            case .none:
                () // okay
            case .carry:
                fatalError("ShadowTunnel functionality not allowed in carry")
            case .customerProxy, .customer:
                // this allows VRE researchers to run this code
                guard disableAppleInfrastructureEnforcementForResearch else {
                    fatalError("ShadowTunnel functionality not allowed in customer")
                }
            @unknown default:
                // fail safe - review at the time
                fatalError("ShadowTunnel functionality not allowed in \(securityPolicy)")
            }
            // defaults now can assume shadowing is enabled and legal
            let controllerMode: CloudControllerMode
            if let cloudController {
                guard let mode = CloudControllerMode(rawValue: cloudController) else {
                    fatalError("cloudController '\(cloudController)' not a valid value")
                }
                controllerMode = mode
            } else {
                controllerMode = .fixed
            }
            self.init(
                definitelyLegalToEnable: true,
                remoteCloudApps: remoteCloudApps ?? true,
                cloudController: controllerMode,
                remoteHost: remoteHost ?? "localhost",
                remotePort: remotePort ?? 4430,
                fixedOptimalBatchSize: fixedOptimalBatchSize ?? 1,
                fixedMaxBatchSize: fixedMaxBatchSize ?? 1,
                workloadName: workloadName ?? "unknown-workload"
            )
        }

        private init(
            definitelyLegalToEnable: Bool,
            remoteCloudApps: Bool,
            cloudController: CloudControllerMode,
            remoteHost: String,
            remotePort: Int,
            fixedOptimalBatchSize: Int,
            fixedMaxBatchSize: Int,
            workloadName: String
        ) {
            precondition(definitelyLegalToEnable, "Only for use when legal to shadow tunnel")
            self.enabled = true
            self.remoteCloudApps = remoteCloudApps
            self.cloudController = cloudController
            self.remoteHost = remoteHost
            self.remotePort = remotePort
            self.fixedOptimalBatchSize = fixedOptimalBatchSize
            self.fixedMaxBatchSize = fixedMaxBatchSize
            self.workloadName = workloadName
        }
    }
}

extension SecureConfig {
    /// The asset consumer IDs in this config should match those in CloudAssetDownloader's assets metadata config.
    public struct AssetsConfig: Sendable, Hashable {
        /// Consumer ID for PIR assets. If nil, no dependency on PIR assets.
        public let pirAssetsConsumerID: String?
        /// Consumer ID for assets of the cloud app. If nil, no dependency on cloud app assets.
        public let cloudAppAssetsConsumerID: String?

        internal init(
            pirAssetsConsumerID: String? = nil,
            cloudAppAssetsConsumerID: String? = nil
        ) {
            self.pirAssetsConsumerID = pirAssetsConsumerID
            self.cloudAppAssetsConsumerID = cloudAppAssetsConsumerID
        }
    }
}

extension SecureConfig {
    /// Configuration for CloudBoardBridgeDaemon
    public struct BridgeDaemonConfig: Sendable, Hashable {
        public struct IdentityManagerConfig: Sendable, Hashable {
            public let useSelfSignedCertificate: Bool
        }

        public struct PIRServiceConfig: Sendable, Hashable {
            public let serviceURL: URL
            /// Enable mTLS, using the node's Narrative identity client certificate
            public let enableMTLS: Bool
            /// Indicates the KFed endpoint that the PIR request first lands on
            public let kfedServiceName: String?
            /// After how many seconds of inactivity to send a keep-alive request, if nil no keepalive will be sent.
            public let keepaliveInterval: Int?
        }

        public let identityManager: IdentityManagerConfig
        public let pirService: PIRServiceConfig?

        init(
            identityManager: IdentityManagerConfig,
            pirService: PIRServiceConfig? = nil,
        ) {
            self.identityManager = identityManager
            self.pirService = pirService
        }

        func copyWithSecurityEnforcement() -> BridgeDaemonConfig {
            let pirServiceWithSecurityEnforcement: PIRServiceConfig? = if let pirService = self.pirService {
                .init(
                    serviceURL: pirService.serviceURL,
                    // enforce mTLS
                    enableMTLS: true,
                    kfedServiceName: pirService.kfedServiceName,
                    keepaliveInterval: pirService.keepaliveInterval
                )
            } else {
                nil
            }
            return .init(
                // enforce using Narrative certificate
                identityManager: .init(useSelfSignedCertificate: false),
                pirService: pirServiceWithSecurityEnforcement
            )
        }
    }
}

extension SecureConfig {
    public struct CloudAppConfig: Sendable, Hashable {
        /// The default limit was set for the first adopters
        /// it represents a very safe level to support given the default memory limits on request specific processes.
        /// Altering this is reasonable, but adopters should consider the memory/network pressures in the system and
        /// justify their needs
        public static let defaultMaxApplicationLayerMessageSize = 1024 * 1024 * 4 // 4MB
        public let port: Int?
        public let prewarmPoolSize: Int
        public let maxInstanceCount: Int
        public let maxAuthContextCount: Int
        public let enforceRequestBypass: Bool?
        public let disabled: Bool
        /// Set of support apps that CloudBoard should manage on behalf of the cloud app. An instance of each
        /// configured support app is launched for every cloud app instance. The name specified here must match the
        /// `_AdditionalProperties.CloudBoardJobName` of a process with a launchd plist that contains a
        /// `_AdditionalProperties.CloudBoardJobType` entry with `CloudBoardSupportApp` as value.
        public let supportApps: Set<String>
        /// Only relevant on proxy cloud apps, controls how they allow transitive trust
        /// Note that this *can* be configured in config but it is validated (with cloud app specific rules)
        /// in both production and carry so it is normally not configured directly
        public let transitiveTrust: TransitiveTrustCloudAppConfig
        /// Only relevant if using the shadow tunnel - which is a test only capability
        public let shadow: ShadowCloudAppConfig
        /// max data size supported by the cloud app in bytes
        public let maxApplicationLayerMessageSize: Int

        public let assets: AssetsConfig

        public let inMemoryController: AppControllerConfig

        init(
            port: Int?,
            prewarmPoolSize: Int = 1,
            maxInstanceCount: Int = 1,
            maxAuthContextCount: Int = 1,
            enforceRequestBypass: Bool? = false,
            disabled: Bool = false,
            supportApps: [String] = [],
            transitiveTrust: TransitiveTrustCloudAppConfig = .noChanges,
            shadow: ShadowCloudAppConfig = .notShadowed,
            assets: AssetsConfig = .init(),
            maxApplicationLayerMessageSize: Int = defaultMaxApplicationLayerMessageSize,
            inMemoryController: AppControllerConfig = .inMemoryControllerNotEnabled
        ) {
            self.port = port
            self.prewarmPoolSize = prewarmPoolSize
            self.maxInstanceCount = maxInstanceCount
            self.maxAuthContextCount = min(maxAuthContextCount, maxInstanceCount)
            self.enforceRequestBypass = enforceRequestBypass
            self.disabled = disabled
            self.supportApps = .init(supportApps)
            self.transitiveTrust = transitiveTrust
            self.shadow = shadow
            self.assets = assets
            self.maxApplicationLayerMessageSize = maxApplicationLayerMessageSize
            self.inMemoryController = inMemoryController
        }

        /// Used for creating a copy with maxAuthContextCount changed
        /// The maxInstanceCount still applies as a limit though
        init(
            copy: CloudAppConfig,
            maxAuthContextCount: Int
        ) {
            self.port = copy.port
            self.prewarmPoolSize = copy.prewarmPoolSize
            self.maxInstanceCount = copy.maxInstanceCount
            // this is still limited
            self.maxAuthContextCount = min(maxAuthContextCount, self.maxInstanceCount)
            self.enforceRequestBypass = copy.enforceRequestBypass
            self.disabled = copy.disabled
            self.supportApps = copy.supportApps
            self.transitiveTrust = copy.transitiveTrust
            self.shadow = copy.shadow
            self.assets = copy.assets
            self.maxApplicationLayerMessageSize = copy.maxApplicationLayerMessageSize
            self.inMemoryController = copy.inMemoryController
        }
    }
}

extension SecureConfig {
    public enum WorkloadTagValue: Sendable, Equatable, Hashable {
        case string(String)
        case stringList([String])
    }

    public struct AppControllerConfig: Sendable, Hashable {
        /// Nothing else matters if this is false, as we would not instantiate an in memory controller for this app.
        public let inMemoryEnabled: Bool

        /// workloadName is used as the service name when registering with service discovery.
        public let workloadName: String
        /// The maximum number of concurrent requests to process.
        /// If not set, it is same as `CloudAppConfig:maxInstanceCount`
        public let maxConcurrency: Int
        /// The optimal number of concurrent requests to be processed
        /// If not set this is equal to `maxConurrency`
        public let optimalBatchSize: Int
        /// If configured for a proxy app: This lists the services/workloads this app will proxy requests for.
        /// If configured for a non proxy app: This list is ignored.
        public let proxyServices: [String]

        /// Example of how to set the workloadTags in SecureConfig
        /// com.apple.cloudboard.cloudApp.<cloudAppName>.controller.workloadTagKeys = ["key1", "key2"]
        /// com.apple.cloudboard.cloudApp.<cloudAppName>.controller.workloadTags.key1 = "value"
        /// com.apple.cloudboard.cloudApp.<cloudAppName>.controller.workloadTags.key2 = ["value1", "value2"]
        public let workloadTags: [String: WorkloadTagValue]

        public static let inMemoryControllerNotEnabled = AppControllerConfig(
            inMemoryEnabled: false,
            workloadName: "notEnabled",
            maxConcurrency: 0
        )

        init(
            inMemoryEnabled: Bool = true,
            workloadName: String,
            maxConcurrency: Int,
            optimalBatchSize: Int? = nil,
            proxyServices: [String] = [],
            workloadTags: [String: WorkloadTagValue] = [:]
        ) {
            self.inMemoryEnabled = inMemoryEnabled
            self.workloadName = workloadName
            self.maxConcurrency = maxConcurrency
            self.optimalBatchSize = optimalBatchSize ?? maxConcurrency
            self.proxyServices = proxyServices
            self.workloadTags = workloadTags
        }
    }
}

extension SecureConfig {
    /// Deliberately *not* Codable, This data should not accidentally be read from anywhere except the API
    /// provided by SecureConfigDB
    public struct Parameters: Hashable, Sendable {
        /// cb_jobhelpers create non disposable LAContexts, which have a limit around 170
        /// per SoC. We set the limit of the total number of cb_jobhelpers which can hold
        /// an LAContext just under this. The jobhelpers release the LAContext once they
        /// have completed the SEP operation and notify cloudboardd
        static let maxAuthContextCount = 150

        public enum SecurityPolicy: Sendable, CaseIterable, CustomStringConvertible {
            case none
            case carry
            case customer

            public var description: String {
                switch self {
                case .none: return "none"
                case .carry: return "carry"
                case .customer: return "customer"
                }
            }
        }

        public enum AuthContextDistributionPolicy: String, Sendable {
            case proportionalToPrewarm
            case equalDistribution
            case manual
        }

        let securityPolicy: SecurityPolicy
        let disableAppleInfrastructureEnforcementForResearch: Bool?
        let rackID: String?
        let isProxy: Bool
        let enforceRequestBypass: Bool
        let routingGroupAliases: [String]?
        let grpcForceIPv6Resolution: Bool?
        let convergenceSpanID: String
        let convergenceTraceID: String
        let cloudAppNames: [String]
        let cloudAppConfigMap: [String: CloudAppConfig]
        let bridgeDaemonConfig: BridgeDaemonConfig

        init(_ secureConfigParameters: SecureConfigParameters) throws {
            switch secureConfigParameters.securityPolicy {
            case .none:
                self.securityPolicy = .none
            case .carry:
                self.securityPolicy = .carry
            case .customer, .customerProxy:
                self.securityPolicy = .customer
            @unknown default:
                SecureConfig.logger.warning("Unexpected security policy, defaulting to customer")
                self.securityPolicy = .customer
            }
            // for customer policy this parameter can only be set to true if the code is running in VRE
            self.disableAppleInfrastructureEnforcementForResearch =
                secureConfigParameters.research_disableAppleInfrastrucutureEnforcement

            func terminalParseError<T>(type: T.Type = T.self, key: String, error: any Error) -> Never {
                SecureConfig.logger.fault(
                    "Failed to parse \"\(key, privacy: .public)\" secure-config parameter as \(type, privacy: .public) due to \(String(describing: error), privacy: .public)"
                )
                fatalError(
                    "Failed to parse \"\(key)\" secure-config parameter as \(type) due to \(String(describing: error))"
                )
            }

            func readParameter<T>(
                key: String, defaultValue: T
            ) -> T {
                do {
                    return try secureConfigParameters.unvalidatedParameter(key) ?? defaultValue
                } catch {
                    terminalParseError(type: T.self, key: key, error: error)
                }
            }

            func readOptional<T>(
                _ key: String
            ) -> T? {
                do {
                    return try secureConfigParameters.unvalidatedParameter(key)
                } catch {
                    terminalParseError(type: T?.self, key: key, error: error)
                }
            }

            // Need a different method for integers, since the generic
            // method above defaults to float when reading numbers from the
            // configuration file.
            func readNumberParameter(
                key: String, defaultValue: Int
            ) -> Int {
                do {
                    let number = try secureConfigParameters.unvalidatedNumberParameter(key) as NSNumber
                    return number.intValue
                } catch let error as DecodingError {
                    // there is no way to check for the key existing without any type checking
                    // so we have to catch an error here, we limit the error checking to just
                    // the missing value case though
                    guard case .valueNotFound = error else {
                        terminalParseError(type: NSNumber.self, key: key, error: error)
                    }
                    return defaultValue
                } catch {
                    terminalParseError(type: NSNumber.self, key: key, error: error)
                }
            }

            func readOptionalNumber(
                _ key: String
            ) -> Int? {
                do {
                    let number = try secureConfigParameters.unvalidatedNumberParameter(key) as NSNumber
                    return number.intValue
                } catch let error as DecodingError {
                    guard case .valueNotFound = error else {
                        terminalParseError(type: NSNumber.self, key: key, error: error)
                    }
                    return nil
                } catch {
                    terminalParseError(type: NSNumber.self, key: key, error: error)
                }
            }

            func readWorkloadName(
                _ key: String
            ) throws -> String {
                if let workloadName: String = readOptional(key) {
                    return workloadName
                } else {
                    throw SecureConfigError.workloadNameNotSetForController(key)
                }
            }

            func readWorkloadTag(
                _ key: String
            ) throws -> WorkloadTagValue {
                // Try to read as a string
                do {
                    SecureConfig.logger.debug("Try reading \(key, privacy: .public) as string")
                    return try .string(secureConfigParameters.unvalidatedStringParameter(key))
                } catch {
                    SecureConfig.logger
                        .debug(
                            "\(error, privacy: .public) thrown when trying to read \(key, privacy: .public) as a string."
                        )
                }

                // Try to read as stringList
                do {
                    SecureConfig.logger.debug("Try reading \(key, privacy: .public) as stringList")
                    if let stringListValue: [String] = try secureConfigParameters.unvalidatedParameter(key) {
                        return .stringList(stringListValue)
                    } else {
                        throw SecureConfigError.workloadTagValueNotSetForKey(key: key)
                    }
                } catch {
                    SecureConfig.logger
                        .debug(
                            "\(error, privacy: .public) thrown when trying to read \(key, privacy: .public) as a stringList."
                        )
                }
                throw SecureConfigError.unableToParseWorkloadTags(key: key)
            }

            let isProxy = secureConfigParameters.cloudboard_isProxy ?? false
            self.isProxy = isProxy
            self.enforceRequestBypass = readParameter(
                key: "com.apple.cloudboard.enforceRequestBypass", defaultValue: false
            )
            self.rackID = secureConfigParameters.cloudAttestationRackId
            self.routingGroupAliases = readParameter(key: "com.apple.cloudboard.routingGroupAliases", defaultValue: nil)
            self.grpcForceIPv6Resolution = readParameter(
                key: "com.apple.cloudboard.grpc.forceIPv6Resolution",
                defaultValue: nil
            )

            // Cross-component parameters used for convergence tracing
            self.convergenceSpanID = readParameter(key: "com.apple.cloudos.tracing.spanID", defaultValue: "")
            self.convergenceTraceID = readParameter(key: "com.apple.cloudos.tracing.traceID", defaultValue: "")
            self.cloudAppNames = readParameter(
                key: "com.apple.cloudboard.cloudApps",
                defaultValue: self.isProxy ? ["TIEProxyApp"] : ["TIECloudApp"]
            )
            var portSet: Set<Int> = []
            var defaultPort = 4442
            var cloudAppConfigMap: [String: CloudAppConfig] = try self.cloudAppNames.reduce(into: [:]) {
                let port = readNumberParameter(
                    key: "com.apple.cloudboard.cloudApp.\($1).port",
                    defaultValue: defaultPort
                )
                let (inserted, _) = portSet.insert(port)
                guard inserted else {
                    throw SecureConfigError.duplicatePort(cloudApp: $1, port: port)
                }

                let maxInstanceCount: Int = readNumberParameter(
                    key: "com.apple.cloudboard.cloudApp.\($1).maxProcessCount",
                    defaultValue: isProxy ? 25 : 3
                )
                let transitiveTrust = "com.apple.cloudboard.cloudApp.\($1).transitiveTrust"
                let shadow = "com.apple.cloudboard.cloudApp.\($1).shadow"
                let assets = "com.apple.cloudboard.cloudApp.\($1).assets"
                let controller = "com.apple.cloudboard.cloudApp.\($1).controller"

                let controllerWorkloadTagKeys: [String]? = readOptional("\(controller).workloadTagKeys")
                let controllerWorkloadTags: [String: WorkloadTagValue] = try controllerWorkloadTagKeys?
                    .reduce(into: [:]) {
                        $0[$1] = try readWorkloadTag("\(controller).workloadTags.\($1)")
                    } ?? [:]
                let inMemoryControllerEnabled = readParameter(key: "\(controller).enabled", defaultValue: false)
                let inMemoryControllerWorkloadName: String = if inMemoryControllerEnabled {
                    try readWorkloadName("\(controller).workloadName")
                } else {
                    AppControllerConfig.inMemoryControllerNotEnabled.workloadName
                }
                $0[$1] = .init(
                    port: port,
                    prewarmPoolSize: readNumberParameter(
                        key: "com.apple.cloudboard.cloudApp.\($1).prewarmPoolSize",
                        defaultValue: isProxy ? 25 : 3
                    ),
                    maxInstanceCount: maxInstanceCount,
                    maxAuthContextCount: readNumberParameter(
                        key: "com.apple.cloudboard.cloudApp.\($1).maxAuthContextCount",
                        defaultValue: isProxy ? Self.maxAuthContextCount : 3
                    ),
                    enforceRequestBypass: readParameter(
                        key: "com.apple.cloudboard.cloudApp.\($1).enforceRequestBypass",
                        defaultValue: nil
                    ),
                    disabled: readParameter(
                        key: "com.apple.cloudboard.cloudApp.\($1).disabled",
                        defaultValue: false
                    ),
                    supportApps: readParameter(
                        key: "com.apple.cloudboard.cloudApp.\($1).supportApps",
                        defaultValue: []
                    ),
                    transitiveTrust: SecureConfig.TransitiveTrustCloudAppConfig(
                        operatingMode: readOptional("\(transitiveTrust).operatingMode"),
                        multiGroup: readOptional("\(transitiveTrust).multiGroup"),
                        pickRequiredEnsemblesFromROPES: readOptionalNumber(
                            "\(transitiveTrust).pickRequiredEnsemblesFromROPES"
                        ),
                        pickAllowedEnsemblesFromProxy: readOptionalNumber(
                            "\(transitiveTrust).pickAllowedEnsemblesFromProxy"
                        ),
                        maxTrustedEnsembleInstances: readOptionalNumber(
                            "\(transitiveTrust).maxTrustedEnsembleInstances"
                        ),
                        trustingEnsembleImpliesTrustingRack: readOptional(
                            "\(transitiveTrust).trustingEnsembleImpliesTrustingRack"
                        )
                    ),
                    shadow: SecureConfig.ShadowCloudAppConfig(
                        securityPolicy: secureConfigParameters.securityPolicy,
                        disableAppleInfrastructureEnforcementForResearch:
                        secureConfigParameters.research_disableAppleInfrastrucutureEnforcement ?? false,
                        enabled: readParameter(key: "\(shadow).enabled", defaultValue: false),
                        remoteCloudApps: readOptional("\(shadow).remoteCloudApps"),
                        cloudController: readOptional("\(shadow).cloudController"),
                        remoteHost: readOptional("\(shadow).remoteHost"),
                        remotePort: readOptionalNumber("\(shadow).remotePort"),
                        fixedOptimalBatchSize: readOptionalNumber("\(shadow).fixedOptimalBatchSize"),
                        fixedMaxBatchSize: readOptionalNumber("\(shadow).fixedMaxBatchSize"),
                        workloadName: readOptional("\(shadow).workloadName")
                    ),
                    assets: SecureConfig.AssetsConfig(
                        pirAssetsConsumerID: readOptional("\(assets).consumerID.pir"),
                        cloudAppAssetsConsumerID: readOptional("\(assets).consumerID.cloudApp")
                    ),
                    maxApplicationLayerMessageSize: readNumberParameter(
                        key: "com.apple.cloudboard.cloudApp.\($1).maxApplicationLayerMessageSize",
                        defaultValue: CloudAppConfig.defaultMaxApplicationLayerMessageSize
                    ),
                    inMemoryController: inMemoryControllerEnabled ? .init(
                        inMemoryEnabled: readParameter(key: "\(controller).enabled", defaultValue: false),
                        workloadName: inMemoryControllerWorkloadName,
                        maxConcurrency: readNumberParameter(
                            key: "\(controller).maxConcurrency",
                            defaultValue: maxInstanceCount
                        ),
                        proxyServices: readParameter(key: "\(controller).proxyServices", defaultValue: []),
                        workloadTags: controllerWorkloadTags
                    ) : .inMemoryControllerNotEnabled
                )
                defaultPort = max(defaultPort, port) + 1
            }
            let authContextDistributionPolicy = AuthContextDistributionPolicy(rawValue: readParameter(
                key: "com.apple.cloudboard.authContextDistributionPolicy",
                defaultValue: "proportionalToPrewarm"
            ))
            if let authContextDistributionPolicy {
                Self.allocateMaxAuthContexts(
                    cloudAppConfigMap: &cloudAppConfigMap,
                    policy: authContextDistributionPolicy
                )
            } else {
                throw SecureConfigError.unsupportedAuthContextDistributionPolicy
            }
            self.cloudAppConfigMap = cloudAppConfigMap

            let pirService: BridgeDaemonConfig.PIRServiceConfig?
            if let pirServiceURLString: String = readOptional("com.apple.cloudboard.cb_bridged.pirService.serviceURL") {
                guard let pirServiceURL = URL(string: pirServiceURLString) else {
                    throw SecureConfigError.invalidURL(pirServiceURLString)
                }
                pirService = .init(
                    serviceURL: pirServiceURL,
                    enableMTLS: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.pirService.enableMTLS",
                        defaultValue: true
                    ),
                    kfedServiceName: readOptional("com.apple.cloudboard.cb_bridged.pirService.kfedServiceName"),
                    keepaliveInterval: readOptionalNumber(
                        "com.apple.cloudboard.cb_bridged.pirService.keepaliveInterval"
                    )
                )
            } else {
                pirService = nil
            }
            self.bridgeDaemonConfig = .init(
                identityManager: .init(
                    useSelfSignedCertificate: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.identityManager.useSelfSignedCertificate",
                        defaultValue: false
                    )
                ),
                pirService: pirService
            )
        }

        // exposed for testing only
        internal init(
            cloudAppConfigMap: [String: CloudAppConfig] = [:],
            securityPolicy: SecurityPolicy,
            disableAppleInfrastructureEnforcementForResearch: Bool? = nil,
            isProxy: Bool = false,
            enforceRequestBypass: Bool = false,
            routingGroupAliases: [String]? = nil,
            rackID: String = "",
            grpcForceIPv6Resolution: Bool? = nil,
            convergenceSpanID: String = "",
            convergenceTraceID: String = "",
            bridgeDaemonConfig: BridgeDaemonConfig = .init(identityManager: .init(useSelfSignedCertificate: false))
        ) {
            self.securityPolicy = securityPolicy
            self.disableAppleInfrastructureEnforcementForResearch = disableAppleInfrastructureEnforcementForResearch
            self.isProxy = isProxy
            self.enforceRequestBypass = enforceRequestBypass
            self.routingGroupAliases = routingGroupAliases
            self.grpcForceIPv6Resolution = grpcForceIPv6Resolution
            self.convergenceSpanID = convergenceSpanID
            self.convergenceTraceID = convergenceTraceID
            self.cloudAppNames = cloudAppConfigMap.map { $0.key }
            self.cloudAppConfigMap = cloudAppConfigMap
            self.rackID = rackID
            self.bridgeDaemonConfig = bridgeDaemonConfig
        }

        // exposed for testing only
        // for backward compatibility for single app tests
        internal init(
            cloudAppNames: [String],
            securityPolicy: SecurityPolicy,
            disableAppleInfrastructureEnforcementForResearch: Bool? = nil,
            isProxy: Bool = false,
            enforceRequestBypass: Bool = false,
            routingGroupAliases: [String]? = nil,
            rackID: String = "",
            grpcForceIPv6Resolution: Bool? = nil,
            convergenceSpanID: String = "",
            convergenceTraceID: String = "",
            assets: AssetsConfig = .init()
        ) {
            guard cloudAppNames.count == 1 else {
                fatalError("This initializer only supports a single cloud app name")
            }
            let cloudAppConfig = CloudAppConfig(port: nil, assets: assets)
            self.init(
                cloudAppConfigMap: [cloudAppNames[0]: cloudAppConfig],
                securityPolicy: securityPolicy,
                disableAppleInfrastructureEnforcementForResearch: disableAppleInfrastructureEnforcementForResearch,
                isProxy: isProxy,
                enforceRequestBypass: enforceRequestBypass,
                routingGroupAliases: routingGroupAliases,
                rackID: rackID,
                grpcForceIPv6Resolution: grpcForceIPv6Resolution,
                convergenceSpanID: convergenceSpanID,
                convergenceTraceID: convergenceTraceID
            )
        }

        internal static func allocateMaxAuthContexts(
            cloudAppConfigMap: inout [String: CloudAppConfig],
            policy: AuthContextDistributionPolicy
        ) {
            let numOfCloudApps = cloudAppConfigMap.keys.count
            let totalPrewarmInstanceCount = cloudAppConfigMap.reduce(into: 0) {
                $0 += $1.value.prewarmPoolSize
            }
            let enforcedPolicy: AuthContextDistributionPolicy = if totalPrewarmInstanceCount == 0,
                                                                   case .proportionalToPrewarm = policy {
                .equalDistribution
            } else {
                policy
            }

            guard numOfCloudApps > 0 else {
                SecureConfig.logger.log("No CloudApps configured to run.")
                return
            }

            var remainingAuthContexts: Int = Self.maxAuthContextCount
            for item in cloudAppConfigMap {
                let maxAuthContextCount: Int = switch enforcedPolicy {
                case .proportionalToPrewarm:
                    min(
                        (item.value.prewarmPoolSize * Self.maxAuthContextCount) / totalPrewarmInstanceCount,
                        remainingAuthContexts
                    )
                case .equalDistribution:
                    min(Self.maxAuthContextCount / numOfCloudApps, remainingAuthContexts)
                case .manual:
                    item.value.maxAuthContextCount
                }
                let updatedConfig = CloudAppConfig(
                    copy: item.value,
                    maxAuthContextCount: maxAuthContextCount
                )
                cloudAppConfigMap.updateValue(updatedConfig, forKey: item.key)
                remainingAuthContexts -= updatedConfig.maxAuthContextCount
            }
        }
    }
}

/// Need custom decoder for fixing the ambiguity of the associated array in stringList
extension SecureConfig.WorkloadTagValue: Decodable {
    private enum CodingKeys: String, CodingKey {
        case string
        case stringList
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let stringValue = try? container.decode(String.self, forKey: .string) {
            self = .string(stringValue)
        } else if let listValue = try? container.decode([String].self, forKey: .stringList) {
            self = .stringList(listValue)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unable to decode WorkloadTagValue"
                )
            )
        }
    }
}
