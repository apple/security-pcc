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
    case configurationNotAllowedBasedOnPolicy(SecureConfig.Parameters.SecurityPolicy, description: String)
    /// Operator misconfigured the HTTP/2 keepalive PING/PONG knobs.
    /// `ClientConnectionKeepalive` preconditions on `interval > 0`,
    /// `timeout > 0`, and `timeout < interval`; we catch a violation at
    /// parse time so the daemon fails to start with a meaningful error
    /// rather than crashing later when the first channel is constructed.
    case invalidPersistentServiceHttp2Keepalive(
        intervalSeconds: Int,
        timeoutSeconds: Int,
        reason: Http2KeepaliveValidationFailure
    )
    /// Operator enabled `maxBatchDependsOnPrewarmedSize` for an in-memory controller whose configured
    /// `maxConcurrency` exceeds the cloud app's `prewarmPoolSize`. In that mode the node can never warm more
    /// instances than the pool holds, so it could never reach the advertised ceiling. We reject this at parse time
    /// so the daemon fails to start with a meaningful error rather than silently under-serving.
    case inMemoryControllerMaxConcurrencyExceedsPrewarmPoolSize(
        cloudApp: String,
        maxConcurrency: Int,
        prewarmPoolSize: Int
    )
}

/// Specific reason an HTTP/2 keepalive configuration was rejected by
/// `SecureConfig` parsing. Mirrors the preconditions in
/// `ClientConnectionKeepalive` so the operator sees which knob is at
/// fault, not just that "something" was wrong.
public enum Http2KeepaliveValidationFailure: Sendable, Equatable, CustomStringConvertible {
    /// `interval` was zero or negative — there'd be no PING cadence at all.
    case intervalNonPositive
    /// `timeout` was zero or negative — there'd be no PONG-wait window.
    case timeoutNonPositive
    /// `timeout >= interval` — the PONG-wait would never resolve before
    /// the next PING is due.
    case timeoutNotLessThanInterval

    public var description: String {
        switch self {
        case .intervalNonPositive:
            "intervalSeconds must be > 0"
        case .timeoutNonPositive:
            "timeoutSeconds must be > 0"
        case .timeoutNotLessThanInterval:
            "timeoutSeconds must be < intervalSeconds"
        }
    }
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

    /// This loads the real SecureConfig or triggers a `fatalError`
    /// It is ideal for use in the main functions of daemons/processes which
    /// // simply use SecureConfig  as their only source of configuration and just expect it to work
    public static func requireRealConfig() -> SecureConfig {
        do {
            let loader = SecureConfigLoader.real
            return try loader.load()
        } catch {
            // no error here can have any private information
            fatalError("Error loading secure config: \(error)")
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

    public var disableAppleInfrastructureEnforcementForResearch: Bool {
        return self.parameters.disableAppleInfrastructureEnforcementForResearch ?? false
    }

    /// Is this instance a proxy or not
    public var isProxy: Bool {
        return self.parameters.isProxy
    }

    /// Whether to use transitive proof verification instead of proxied release set validation.
    /// Always enforced to `true` when Apple infrastructure security config is active.
    public var enableTransitiveProofVerification: Bool {
        if self.shouldEnforceAppleInfrastructureSecurityConfig {
            return true
        }
        return self.parameters.enableTransitiveProofVerification
    }

    /// Whether the transparency cache is enabled for transitive proof verification
    public var transparencyCacheEnabled: Bool {
        return self.parameters.transparencyCacheEnabled
    }

    /// Maximum number of transparency log entry cache entries
    public var maximumTransparencyCacheLogEntrySize: Int {
        return self.parameters.maximumTransparencyCacheLogEntrySize
    }

    /// Maximum number of transparency log consistency proof cache entries
    public var maximumTransparencyCacheConsistencySize: Int {
        return self.parameters.maximumTransparencyCacheConsistencySize
    }

    /// Interval in seconds between transparency cache expired-entry sweeps
    public var transparencyCacheExpirySweepIntervalSeconds: Int {
        return self.parameters.transparencyCacheExpirySweepIntervalSeconds
    }

    /// Interval in seconds between proxy attestation recycle checks
    public var recycleCheckIntervalSeconds: Int {
        return self.parameters.recycleCheckIntervalSeconds
    }

    /// Whether to mark existing attestations as node-only (unpublish from ROPES) when a recycle check triggers rotation
    public var unpublishExistingAttestationsOnRecycle: Bool {
        return self.parameters.unpublishExistingAttestationsOnRecycle
    }

    /// Whether a proxy sends the transparency log tree ID and revision from the attestation associated with a
    /// request's key ID to ROPES as `treeId`/`revision` workload routing parameters when finding a worker. Defaults
    /// to `true`; set to `false` to omit them from the find-worker constraints.
    public var includeTransparencyConstraintsInWorkerRequests: Bool {
        return self.parameters.includeTransparencyConstraintsInWorkerRequests
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

    public func persistentServicePort(serviceID _: String) throws -> Int? {
        return self.parameters.persistentServicePort
    }

    /// This allows configuring the posture away from the default.
    /// It has no effect in `carry` or `customer`, where test formats are always disallowed
    /// regardless of any operator override.
    public var allowAttestationTestFormats: Bool {
        switch self.parameters.securityPolicy {
        case .none:
            return self.parameters.allowAttestationTestFormats ?? true
        case .carry, .customer:
            return false
        }
    }

    public var bridgeDaemonConfig: BridgeDaemonConfig {
        if self.shouldEnforceAppleInfrastructureSecurityConfig {
            self.parameters.bridgeDaemonConfig.copyWithSecurityEnforcement()
        } else if self.disableAppleInfrastructureEnforcementForResearch {
            self.parameters.bridgeDaemonConfig.copyWithResearchSecurityDisabled()
        } else {
            self.parameters.bridgeDaemonConfig
        }
    }

    /// The _server_ coponents to host
    public var persistentServices: [String] {
        self.parameters.persistentServices
    }

    /// Default cap on concurrent persistent-service helper instances
    /// (cb_pserverhelper on the server side, cb_pclienthelper on the
    /// bridge side) when no operator override is set. Sized for a fleet
    /// of 112 agents with two connections each plus headroom for spares.
    public static let defaultPersistentServiceMaxConcurrentHelperInstances: Int = 500

    /// Default jitter window (seconds) over which the server spreads
    /// `connectionShouldBeRecreated` notifications after an attestation-key
    /// roll. A fleet-wide roll is synchronized, so notifying every client the
    /// instant the key rotates triggers a simultaneous reconnection storm that
    /// contends on replacement establishment and strands in-flight queries;
    /// smearing the notifications over this window avoids that. `0` disables
    /// the jitter (notify immediately).
    public static let defaultPersistentServiceDrainNotificationMaxJitterSeconds: Int = 120

    /// Default runway (seconds) on the bound key reserved for the client to
    /// establish a replacement connection before the key — and thus the
    /// connection — is severed. The jitter never eats into this: if the bound
    /// key's remaining life is at or below the margin, the notification is sent
    /// immediately regardless of the jitter window.
    public static let defaultPersistentServiceDrainNotificationSafetyMarginSeconds: Int = 30

    /// Default HTTP/2 keepalive PING interval (seconds) used by the
    /// bridge's persistent-service channel pool when no operator
    /// override is set. Paired with
    /// `defaultPersistentServiceHttp2KeepalivePongTimeoutSeconds`;
    /// timeout must be strictly less than interval.
    public static let defaultPersistentServiceHttp2KeepalivePingIntervalSeconds: Int = 15

    /// Default HTTP/2 keepalive PONG-wait deadline (seconds). See
    /// `defaultPersistentServiceHttp2KeepalivePingIntervalSeconds`.
    public static let defaultPersistentServiceHttp2KeepalivePongTimeoutSeconds: Int = 5

    /// Default bounded depth of the per-cb_jobhelper attestation-usage-report
    /// queue between the XPC receive callback and the serial validation drain.
    /// Must exceed the number of prevalidation reports a cold quorum
    /// establishment emits in a burst; on overflow `bufferingOldest` drops the
    /// excess and those nodes recover only via the slower attestation-resend
    /// path. Single source of truth for the default (config read, memberwise
    /// init, and `PersistentServiceRouter.init` all reference this).
    public static let defaultAttestationUsageReportsBufferLimit: Int = 256

    /// Validates resolved HTTP/2 keepalive PING/PONG knobs against the
    /// preconditions `ClientConnectionKeepalive` enforces (positive
    /// values, timeout strictly less than interval). Returns `nil` for
    /// a valid pair, or the specific reason it was rejected so the
    /// caller can surface it in a `SecureConfigError`.
    public static func validateHttp2Keepalive(
        intervalSeconds: Int,
        timeoutSeconds: Int
    ) -> Http2KeepaliveValidationFailure? {
        if intervalSeconds <= 0 { return .intervalNonPositive }
        if timeoutSeconds <= 0 { return .timeoutNonPositive }
        if timeoutSeconds >= intervalSeconds { return .timeoutNotLessThanInterval }
        return nil
    }

    /// Resolved cap on concurrent cb_pserverhelper instances the server
    /// will spawn for `serviceID`. Operators override per service via
    /// `com.apple.cloudboard.persistentService.<service>.maxConcurrentHelperInstances`;
    /// services without an override get
    /// `defaultPersistentServiceMaxConcurrentHelperInstances`.
    public func persistentServiceMaxConcurrentHelperInstances(serviceID: String) -> Int {
        self.parameters.persistentServiceMaxConcurrentHelperInstances[serviceID]
            ?? Self.defaultPersistentServiceMaxConcurrentHelperInstances
    }

    /// Resolved jitter window (seconds) over which the server spreads
    /// `connectionShouldBeRecreated` notifications for `serviceID`. Operators
    /// override per service via
    /// `com.apple.cloudboard.persistentService.<service>.drainNotificationMaxJitterSeconds`;
    /// services without an override get
    /// `defaultPersistentServiceDrainNotificationMaxJitterSeconds`.
    public func persistentServiceDrainNotificationMaxJitterSeconds(serviceID: String) -> Int {
        self.parameters.persistentServiceDrainNotificationMaxJitterSeconds[serviceID]
            ?? Self.defaultPersistentServiceDrainNotificationMaxJitterSeconds
    }

    /// Resolved runway (seconds) reserved for replacement establishment for
    /// `serviceID`. Operators override per service via
    /// `com.apple.cloudboard.persistentService.<service>.drainNotificationSafetyMarginSeconds`;
    /// services without an override get
    /// `defaultPersistentServiceDrainNotificationSafetyMarginSeconds`.
    public func persistentServiceDrainNotificationSafetyMarginSeconds(serviceID: String) -> Int {
        self.parameters.persistentServiceDrainNotificationSafetyMarginSeconds[serviceID]
            ?? Self.defaultPersistentServiceDrainNotificationSafetyMarginSeconds
    }

    /// which clients to enable support for
    public var persistentServiceClients: [String] {
        self.parameters.persistentServiceClients
    }

    /// Isolation domain for persistent service SD registration
    public var isolationDomain: String? {
        self.parameters.isolationDomain
    }

    /// Default teardown timeout for cb_jobhelper and cloud app instances. Can be overwritten by cloud app specific
    /// teardown timeout configuration.
    public var teardownTimeout: Duration {
        .seconds(self.parameters.teardownTimeoutSeconds)
    }

    /// Number of the proxy's most-recent active attestation keys that cb_attestationd pre-validates a worker
    /// against when cb_pclienthelper requests a transitive-trust warmup. Keeps the worker-validation cache warm
    /// across the proxy's own attestation rolls so the per-request hot-path validation is a cache hit.
    /// Clamped to `>= 0` so a misconfigured negative value can't crash the daemon (`Array.prefix`); `0` disables
    /// warmup.
    public var transitiveTrustWarmupMaxKeysToValidate: Int {
        max(0, self.parameters.transitiveTrustWarmupMaxKeysToValidate)
    }

    /// Per-warmup timeout used by cb_pclienthelper when asking cb_attestationd to pre-validate its worker
    /// attestation. On timeout the helper proceeds on the unvalidated path (the hot path still validates on
    /// use), so this bounds, but never gates, connection setup. Clamped to `>= 1s` so a misconfigured
    /// zero/negative value can't turn warmup into an instant no-op.
    public var clientHelperAttestationWarmupTimeout: Duration {
        .seconds(max(1, self.parameters.clientHelperAttestationWarmupTimeoutSeconds))
    }

    /// Resolved attestation-usage-report queue depth, clamped `>= 1` so a
    /// misconfigured value can't produce a zero-depth queue. See
    /// `defaultAttestationUsageReportsBufferLimit` for the rationale.
    public var attestationUsageReportsBufferLimit: Int {
        max(1, self.parameters.attestationUsageReportsBufferLimit)
    }

    /// Phase 0 only: static RSA private key for signing reputation PAT (blind signature refunds), provisioned via
    /// darwin-init.
    /// Phase 1 will deliver this dynamically via KRS.
    public var reputationPATSigningKey: String? {
        self.parameters.reputationPATSigningKey
    }

    /// This is set separately from the rest of ServiceDiscovery configuration in CFPrefs
    /// since SRE need the ability to update this. The rest of configuration is injected directed via CP.
    public var useV2ServiceDiscovery: Bool {
        self.parameters.useV2ServiceDiscovery
    }

    /// When true, serviceName-to-appIdentifier check is skipped.
    /// This is forced off when Apple infrastructure security config is enforced.
    public var skipMultiAppValidations: Bool {
        if self.shouldEnforceAppleInfrastructureSecurityConfig {
            return false
        }
        return self.parameters.skipMultiAppValidations
    }

    public struct BridgeServiceMonitoringConfig: Sendable, Hashable {
        public static let disabled = BridgeServiceMonitoringConfig(
            enabled: false,
            connectionTimeout: .seconds(60 * 60 * 12),
            connectionBackoff: .init(
                initialDelay: .seconds(1),
                multiplier: 2.0,
                maxDelay: .seconds(30),
                jitterPercent: 0.25
            )
        )

        public var enabled: Bool
        public var connectionTimeout: Duration

        public struct ConnectionBackoff: Sendable, Hashable {
            public var initialDelay: Duration
            public var multiplier: Double
            public var maxDelay: Duration
            public var jitterPercent: Double
        }

        public var connectionBackoff: ConnectionBackoff
    }

    public var monitoringBridgeService: BridgeServiceMonitoringConfig {
        self.parameters.monitoringBridgeService
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
        public let pickRatioCanScaleTo: Int?
        public let maxTrustedEnsembleInstances: Int?
        public let trustingEnsembleImpliesTrustingRack: Bool?

        internal init(
            operatingMode: String? = nil,
            multiGroup: Bool? = nil,
            pickRequiredEnsemblesFromROPES: Int? = nil,
            pickAllowedEnsemblesFromProxy: Int? = nil,
            pickRatioCanScaleTo: Int? = nil,
            maxTrustedEnsembleInstances: Int? = nil,
            trustingEnsembleImpliesTrustingRack: Bool? = nil
        ) {
            self.operatingMode = operatingMode
            self.multiGroup = multiGroup
            self.pickRequiredEnsemblesFromROPES = pickRequiredEnsemblesFromROPES
            self.pickAllowedEnsemblesFromProxy = pickAllowedEnsemblesFromProxy
            self.pickRatioCanScaleTo = pickRatioCanScaleTo
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
            public let aquariaAPRN: String?
            public let aquariaSanDNS: String?
            public let aquariaTag: String?
            public let aquariaIdentityBackoff: ConnectionBackoff?

            public init(
                useSelfSignedCertificate: Bool,
                aquariaAPRN: String? = nil,
                aquariaSanDNS: String? = nil,
                aquariaTag: String? = nil,
                aquariaIdentityBackoff: ConnectionBackoff? = nil
            ) {
                self.useSelfSignedCertificate = useSelfSignedCertificate
                self.aquariaAPRN = aquariaAPRN
                self.aquariaSanDNS = aquariaSanDNS
                self.aquariaTag = aquariaTag
                self.aquariaIdentityBackoff = aquariaIdentityBackoff
            }
        }

        public struct PIRServiceConfig: Sendable, Hashable {
            public let serviceURL: URL
            /// Enable mTLS, using the node's Narrative identity client certificate
            public let enableMTLS: Bool
            /// Indicates the KFed endpoint that the PIR request first lands on
            public let kfedServiceName: String?
            /// After how many seconds of inactivity to send a keep-alive request, if nil no keepalive will be sent.
            public let keepaliveInterval: Int?
            /// Maximum number of gRPC request attempts (including the initial attempt)
            public let attemptCount: Int
            /// Delay between retry attempts
            public let retryDelay: Duration
            /// Per-attempt timeout for the PIR encrypted request
            public let requestTimeout: Duration

            public init(
                serviceURL: URL,
                enableMTLS: Bool,
                kfedServiceName: String?,
                keepaliveInterval: Int?,
                attemptCount: Int = 1,
                retryDelay: Duration = .milliseconds(100),
                requestTimeout: Duration = .milliseconds(10000)
            ) {
                self.serviceURL = serviceURL
                self.enableMTLS = enableMTLS
                self.kfedServiceName = kfedServiceName
                self.keepaliveInterval = keepaliveInterval
                self.attemptCount = attemptCount
                self.retryDelay = retryDelay
                self.requestTimeout = requestTimeout
            }
        }

        public struct TLSConfiguration: Codable, Hashable, Sendable {
            /// If true, TLS is enabled. Otherwise an insecure connection is used.
            public let enable: Bool?
            /// Override for Server Name Indication to validate in server certificate
            public let sniOverride: String?
            /// Enable mTLS, using the node's Narrative identity client certificate
            public let enablemTLS: Bool

            public init(
                enable: Bool?,
                sniOverride: String?,
                enablemTLS: Bool
            ) {
                self.enable = enable
                self.sniOverride = sniOverride
                self.enablemTLS = enablemTLS
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.enable = try container.decodeIfPresent(Bool.self, forKey: .enable)
                self.sniOverride = try container.decodeIfPresent(String.self, forKey: .sniOverride)
                self.enablemTLS = try container.decode(Bool.self, forKey: .enablemTLS)
            }
        }

        public struct ConnectionBackoff: Codable, Hashable, Sendable {
            public let initial: Double?
            public let maximum: Double?
            public let factor: Double?
            public let jitterPercent: Double?
            public let coolDown: Int?
        }

        public struct ToolGatewayServiceConfig: Sendable, Hashable {
            public let targetHost: String
            public let targetPort: Int
            public let tlsConfig: TLSConfiguration?
            public let idleTimeoutSeconds: Int?
            public let backoffConfig: ConnectionBackoff?
            /// PolicyAPRN strings used to validate the tool gateway server certificate.
            public let targetPolicyAPRNs: [String]?
        }

        public struct PersistentServiceConfig: Sendable, Hashable {
            public let tlsConfig: TLSConfiguration?
            public let backoffConfig: ConnectionBackoff?
            /// Keepalive ping interval in seconds
            public let keepaliveIntervalSeconds: Int?
            /// Connection idle timeout in seconds
            public let idleTimeoutSeconds: Int?
            /// Hard upper bound on how long the bridge waits for a
            /// drain-complete signal from the router after a helper enters
            /// `.draining`. On expiry the bridge force-Terminates the
            /// stream so the slot can be reclaimed and the retry loop
            /// reconnects with fresh keys. Default 60s when nil.
            public let drainCompleteWaitTimeoutSeconds: Int?
            /// Hard upper bound on how long a rotating connection keeps its old
            /// stream serving while waiting for the replacement to become
            /// routable (reach `sendHelperReady`). On expiry the old stream is
            /// drained anyway to honour the server's recreate request. Distinct
            /// from `drainCompleteWaitTimeoutSeconds` (which bounds the
            /// subsequent in-flight drain) so the make-before-break overlap and
            /// the drain grace can be tuned independently. Default 60s when nil.
            public let replacementReadyWaitTimeoutSeconds: Int?
            /// Cap on the number of persistent-service servers the bridge
            /// holds active connections to, applied **per unit**. A unit is
            /// the granularity at which the bridge maintains coverage —
            /// `(capability, shardID)` derived from the SD instance metadata
            /// (`meta["persistent-service"].fields["capabilities"]`). The map is
            /// keyed by the service name as published by Service Discovery,
            /// and the value is the per-unit cap to apply to every unit
            /// derived from that service. Services or units absent from the
            /// map are uncapped, preserving the historical behaviour.
            ///
            /// The cap is **soft**, in two ways:
            ///
            /// 1. It is not a hard per-unit ceiling. One connection counts
            ///    toward *every* unit its node covers, and units overlap, so a
            ///    unit's cap is intentionally **exceeded** when that is the only
            ///    way to bring a colocated unit up to *its* cap. Example: a
            ///    sharded capability whose nodes each also serve an unsharded
            ///    "umbrella" capability — filling every shard to its cap
            ///    necessarily over-covers the umbrella, since the umbrella's
            ///    active set is the union of the shards'. The only firm rule is
            ///    that the bridge never opens a connection that *no* unit still
            ///    needs; total connections are bounded by the sum of per-unit
            ///    caps, not by any single unit's cap.
            /// 2. It is maintained by ongoing reconciliation, not enforced
            ///    synchronously. As active connections drain (server-initiated
            ///    drain notifications) or fail, the node is demoted and a spare
            ///    is promoted to backfill, so a unit converges toward its cap
            ///    through connection churn rather than being held at a fixed
            ///    membership. Transient over-cap (e.g. a briefly co-active old
            ///    and new generation during a make-before-break handover) is
            ///    left to decay via that reconciliation rather than force-torn.
            public let maxServersPerUnit: [String: Int]?
            /// Hard upper bound (in seconds) on how long the bridge will
            /// wait for a single gRPC connection-establishment attempt to
            /// either succeed (reach AnnounceConnection) or fail. Wraps the
            /// gRPC-Swift `connectionPool.maxWaitTime` knob with explicit
            /// structured-concurrency cancellation because that knob has
            /// been observed not to bound real-world failures (closed-on-
            /// accept listeners, HTTP/2 mid-handshake RST). On timeout the
            /// connection task throws a retryable
            /// `establishmentTimeout` error, which goes through the same
            /// retry-and-swap path as any other early failure. nil ⇒ default
            /// 15 s (slightly above gRPC's own 10 s `maxWaitTime`).
            public let connectionEstablishmentTimeoutSeconds: Int?
            /// Number of consecutive failed connection attempts on a single
            /// node before the bridge swaps to a spare (provided one is
            /// available in some unit the failed node covers). Keyed by
            /// service name; missing entries fall back to the global
            /// default of 2. Only effective for services that also have
            /// `maxServersPerUnit` configured.
            public let swapOnFailureThreshold: [String: Int]?
            /// HTTP/2 keepalive PING interval in seconds. NIO sends a
            /// PING every `interval`; if no PONG arrives within
            /// `http2KeepalivePongTimeoutSeconds` the channel closes.
            /// nil ⇒ default 15 s. Must be strictly greater than
            /// `http2KeepalivePongTimeoutSeconds`.
            public let http2KeepalivePingIntervalSeconds: Int?
            /// HTTP/2 keepalive PONG-wait deadline in seconds. nil ⇒
            /// default 5 s. Must be strictly less than
            /// `http2KeepalivePingIntervalSeconds`.
            public let http2KeepalivePongTimeoutSeconds: Int?
            /// Cap on concurrent cb_pclienthelper instances spawned by
            /// this bridge process across all persistent services.
            /// nil ⇒ `SecureConfig.defaultPersistentServiceMaxConcurrentHelperInstances`.
            /// Bridge-side cap is global (not per-service) because a
            /// single bridge process serves all configured persistent
            /// services from one helper-instance provider.
            public let maxConcurrentHelperInstances: Int?
            /// Capability IDs (as advertised in the persistent-service
            /// `capabilities` map) that the bridge discards during SD capability
            /// parsing, so the client router never establishes quorum for or
            /// routes to them. Empty ⇒ nothing blocked (today's behaviour).
            public let blockedCapabilities: [String]
        }

        public struct AppleSigningServiceConfig: Sendable, Hashable {
            public var accountID: String
            public var keyID: String
            public var serviceURL: URL
            public var disableMTLS: Bool
            public var allowInsecure: Bool
            public var attemptCount: Int
            public var retryDelay: TimeInterval
            public var httpRequestTimeout: TimeInterval
        }

        public struct CIPCompanionServiceConfig: Sendable, Hashable {
            public var serviceURL: URL
            public var disableMTLS: Bool
            public var allowInsecure: Bool
            public var attemptCount: Int
            public var retryDelay: TimeInterval
            public var httpRequestTimeout: TimeInterval
        }

        public let identityManager: IdentityManagerConfig
        public let pirService: PIRServiceConfig?
        public let toolGateway: ToolGatewayServiceConfig?
        public let appleSigningService: AppleSigningServiceConfig?
        public let cipCompanionService: CIPCompanionServiceConfig?
        public let persistentService: PersistentServiceConfig?

        init(
            identityManager: IdentityManagerConfig,
            pirService: PIRServiceConfig? = nil,
            toolGateway: ToolGatewayServiceConfig? = nil,
            appleSigningService: AppleSigningServiceConfig? = nil,
            cipCompanionService: CIPCompanionServiceConfig? = nil,
            persistentService: PersistentServiceConfig? = nil
        ) {
            self.identityManager = identityManager
            self.pirService = pirService
            self.toolGateway = toolGateway
            self.appleSigningService = appleSigningService
            self.cipCompanionService = cipCompanionService
            self.persistentService = persistentService
        }

        func copyWithSecurityEnforcement() -> BridgeDaemonConfig {
            let identityManagerWithSecurityEnforcement: IdentityManagerConfig = .init(
                useSelfSignedCertificate: false,
                aquariaAPRN: self.identityManager.aquariaAPRN,
                aquariaSanDNS: self.identityManager.aquariaSanDNS,
                aquariaTag: self.identityManager.aquariaTag,
                aquariaIdentityBackoff: self.identityManager.aquariaIdentityBackoff
            )

            let pirServiceWithSecurityEnforcement: PIRServiceConfig? = if let pirService = self.pirService {
                .init(
                    serviceURL: pirService.serviceURL,
                    // enforce mTLS
                    enableMTLS: true,
                    kfedServiceName: pirService.kfedServiceName,
                    keepaliveInterval: pirService.keepaliveInterval,
                    attemptCount: pirService.attemptCount,
                    retryDelay: pirService.retryDelay,
                    requestTimeout: pirService.requestTimeout
                )
            } else {
                nil
            }
            let toolGatewayWithSecurityEnforcement: ToolGatewayServiceConfig? = if let toolGateway = self.toolGateway {
                .init(
                    targetHost: toolGateway.targetHost,
                    targetPort: toolGateway.targetPort,
                    tlsConfig: TLSConfiguration(
                        // enforce TLS + mTLS
                        enable: true,
                        sniOverride: toolGateway.tlsConfig?.sniOverride,
                        enablemTLS: true
                    ),
                    idleTimeoutSeconds: toolGateway.idleTimeoutSeconds, // in seconds
                    backoffConfig: .init(
                        initial: toolGateway.backoffConfig?.initial,
                        maximum: toolGateway.backoffConfig?.maximum,
                        factor: toolGateway.backoffConfig?.factor,
                        jitterPercent: toolGateway.backoffConfig?.jitterPercent,
                        coolDown: toolGateway.backoffConfig?.coolDown
                    ),
                    targetPolicyAPRNs: toolGateway.targetPolicyAPRNs
                )
            } else {
                nil
            }

            var appleSigningServiceWithSecurityEnforcement: AppleSigningServiceConfig?
            if let appleSigningService = self.appleSigningService {
                appleSigningServiceWithSecurityEnforcement = AppleSigningServiceConfig(
                    accountID: appleSigningService.accountID,
                    keyID: appleSigningService.keyID,
                    serviceURL: appleSigningService.serviceURL,
                    disableMTLS: false,
                    allowInsecure: false,
                    attemptCount: appleSigningService.attemptCount,
                    retryDelay: appleSigningService.retryDelay,
                    httpRequestTimeout: appleSigningService.httpRequestTimeout
                )
            }

            var cipCompanionServiceWithSecurityEnforcement: CIPCompanionServiceConfig?
            if let cipCompanionService = self.cipCompanionService {
                cipCompanionServiceWithSecurityEnforcement = CIPCompanionServiceConfig(
                    serviceURL: cipCompanionService.serviceURL,
                    disableMTLS: false,
                    allowInsecure: false,
                    attemptCount: cipCompanionService.attemptCount,
                    retryDelay: cipCompanionService.retryDelay,
                    httpRequestTimeout: cipCompanionService.httpRequestTimeout
                )
            }

            let persistentServiceWithSecurityEnforcement: PersistentServiceConfig? = if let ps = self
                .persistentService {
                .init(
                    tlsConfig: TLSConfiguration(
                        // enforce TLS + mTLS
                        enable: true,
                        sniOverride: ps.tlsConfig?.sniOverride,
                        enablemTLS: true
                    ),
                    backoffConfig: ps.backoffConfig,
                    keepaliveIntervalSeconds: ps.keepaliveIntervalSeconds,
                    idleTimeoutSeconds: ps.idleTimeoutSeconds,
                    drainCompleteWaitTimeoutSeconds: ps.drainCompleteWaitTimeoutSeconds,
                    replacementReadyWaitTimeoutSeconds: ps.replacementReadyWaitTimeoutSeconds,
                    maxServersPerUnit: ps.maxServersPerUnit,
                    connectionEstablishmentTimeoutSeconds: ps.connectionEstablishmentTimeoutSeconds,
                    swapOnFailureThreshold: ps.swapOnFailureThreshold,
                    http2KeepalivePingIntervalSeconds: ps.http2KeepalivePingIntervalSeconds,
                    http2KeepalivePongTimeoutSeconds: ps.http2KeepalivePongTimeoutSeconds,
                    maxConcurrentHelperInstances: ps.maxConcurrentHelperInstances,
                    blockedCapabilities: ps.blockedCapabilities
                )
            } else {
                nil
            }

            return .init(
                // enforce using Narrative certificate
                identityManager: identityManagerWithSecurityEnforcement,
                pirService: pirServiceWithSecurityEnforcement,
                toolGateway: toolGatewayWithSecurityEnforcement,
                appleSigningService: appleSigningServiceWithSecurityEnforcement,
                cipCompanionService: cipCompanionServiceWithSecurityEnforcement,
                persistentService: persistentServiceWithSecurityEnforcement
            )
        }

        func copyWithResearchSecurityDisabled() -> BridgeDaemonConfig {
            let toolGatewayResearchConfig: ToolGatewayServiceConfig? = if let toolGateway = self.toolGateway {
                .init(
                    targetHost: toolGateway.targetHost,
                    targetPort: toolGateway.targetPort,
                    tlsConfig: TLSConfiguration(
                        // disable TLS + mTLS for research
                        enable: false,
                        sniOverride: toolGateway.tlsConfig?.sniOverride,
                        enablemTLS: false
                    ),
                    idleTimeoutSeconds: toolGateway.idleTimeoutSeconds,
                    backoffConfig: .init(
                        initial: toolGateway.backoffConfig?.initial,
                        maximum: toolGateway.backoffConfig?.maximum,
                        factor: toolGateway.backoffConfig?.factor,
                        jitterPercent: toolGateway.backoffConfig?.jitterPercent,
                        coolDown: toolGateway.backoffConfig?.coolDown
                    ),
                    targetPolicyAPRNs: toolGateway.targetPolicyAPRNs
                )
            } else {
                nil
            }

            var appleSigningServiceResearchConfig: AppleSigningServiceConfig?
            if let appleSigningService = self.appleSigningService {
                appleSigningServiceResearchConfig = AppleSigningServiceConfig(
                    accountID: appleSigningService.accountID,
                    keyID: appleSigningService.keyID,
                    serviceURL: appleSigningService.serviceURL,
                    // disable mTLS for research
                    disableMTLS: true,
                    allowInsecure: true,
                    attemptCount: appleSigningService.attemptCount,
                    retryDelay: appleSigningService.retryDelay,
                    httpRequestTimeout: appleSigningService.httpRequestTimeout
                )
            }

            var cipCompanionServiceResearchConfig: CIPCompanionServiceConfig?
            if let cipCompanionService = self.cipCompanionService {
                cipCompanionServiceResearchConfig = CIPCompanionServiceConfig(
                    serviceURL: cipCompanionService.serviceURL,
                    // disable mTLS for research
                    disableMTLS: true,
                    allowInsecure: true,
                    attemptCount: cipCompanionService.attemptCount,
                    retryDelay: cipCompanionService.retryDelay,
                    httpRequestTimeout: cipCompanionService.httpRequestTimeout
                )
            }

            return .init(
                identityManager: self.identityManager,
                pirService: self.pirService,
                toolGateway: toolGatewayResearchConfig,
                appleSigningService: appleSigningServiceResearchConfig,
                cipCompanionService: cipCompanionServiceResearchConfig,
                persistentService: self.persistentService
            )
        }
    }
}

extension SecureConfig {
    /// How a cloud app advertises capacity to ROPES and admits requests with respect to prewarmed-instance
    /// availability. A single policy rather than a pair of booleans so invalid combinations (e.g. "wait for a
    /// prewarmed instance" while prewarm-aware advertising is off) are unrepresentable.
    public enum PrewarmedAdmissionPolicy: Sendable, Hashable {
        /// Advertised `max_batch_size` ignores prewarmed availability and requests are never rejected for lack of a
        /// ready prewarmed instance. This is the default.
        case disabled
        /// Advertised `max_batch_size` is reduced to what is immediately servable
        /// (`min(configuredMaxConcurrency, currentBatchSize + availablePrewarmedInstances)`). A request that arrives
        /// when no prewarmed instance is ready is rejected with a dedicated error so ROPES retries elsewhere.
        case rejectIfNoPrewarmed
        /// Advertised `max_batch_size` is reduced as in `rejectIfNoPrewarmed`, but a request that arrives when no
        /// prewarmed instance is ready is admitted up to the configured concurrency ceiling and waits for an instance
        /// to warm up rather than being rejected.
        case waitForPrewarmed
    }

    public struct CloudAppConfig: Sendable, Hashable {
        /// The default limit was set for the first adopters
        /// it represents a very safe level to support given the default memory limits on request specific processes.
        /// Altering this is reasonable, but adopters should consider the memory/network pressures in the system and
        /// justify their needs
        public static let defaultMaxApplicationLayerMessageSize = 1024 * 1024 * 4 // 4MB
        public static let defaultMaxToolInvocationsPerRequest = 50
        public let port: Int?
        public let prewarmPoolSize: Int
        public let maxInstanceCount: Int
        public let maxAuthContextCount: Int
        public let enforceRequestBypass: Bool?
        public let disabled: Bool
        /// How this cloud app advertises capacity and admits requests with respect to prewarmed-instance
        /// availability. See `PrewarmedAdmissionPolicy`.
        ///
        /// When not `.disabled`, `max_batch_size` reported to ROPES takes the number of available prewarmed instances
        /// into account: `min(configuredMaxConcurrency, currentBatchSize + availablePrewarmedInstances)`. CloudBoard
        /// also ensures `prewarmPoolSize >= configuredMaxConcurrency`. Defaults to `.disabled`.
        ///
        /// Note: only instances that are fully warmed *and* have an auth context assigned count as "available
        /// prewarmed". For the advertised capacity to be able to reach `configuredMaxConcurrency`, the deployment
        /// must therefore also keep `maxInstanceCount` and `maxAuthContextCount` at least `configuredMaxConcurrency`;
        /// otherwise the node still serves correctly but will permanently under-report its servable capacity.
        public let prewarmedAdmissionPolicy: PrewarmedAdmissionPolicy

        /// Whether the reported `max_batch_size` and request admission account for available prewarmed instances.
        /// Derived from `prewarmedAdmissionPolicy`; true for every policy other than `.disabled`.
        public var maxBatchDependsOnPrewarmedSize: Bool {
            self.prewarmedAdmissionPolicy != .disabled
        }

        /// Whether a request that arrives when no prewarmed instance is ready waits for one to warm up instead of
        /// being rejected. Derived from `prewarmedAdmissionPolicy`; only true for `.waitForPrewarmed`.
        public var waitForPrewarmedInsteadOfRejecting: Bool {
            self.prewarmedAdmissionPolicy == .waitForPrewarmed
        }

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

        /// Maximum number of tool invocations allowed per request
        public let maxToolInvocationsPerRequest: Int

        /// Per-app cumulative request byte limit. When set, overrides the global LoadConfiguration value.
        public let maxCumulativeRequestBytes: Int?

        public let assets: AssetsConfig

        public let inMemoryController: AppControllerConfig

        /// If true, `cb_jobhelper` does not bring up any cloudApp, instead
        /// it directly initiates the findWorker workflow.
        /// If true `enforceRequestBypass` is forced to true.
        public let isTrampolineProxy: Bool

        /// Timeout for cloud app instance and the associated cb_jobhelper instance to tear down after a teardown signal
        /// has been provided. Falls back to global configuration (com.apple.cloudboard.teardownTimeoutSeconds) if not
        /// set. NOTE: Increasing this timeout can have an impact on capacity. This should only be used in production
        /// environments after careful consideration.
        public let teardownTimeout: Duration

        /// Timeout for a single cb_jobhelper warmup attempt before it is considered stuck.
        /// When nil, no timeout is applied during warmup.
        public let warmupTimeout: Duration?

        /// Number of consecutive warmup failures before the node enters maintenance.
        /// Defaults to `prewarmPoolSize` when not explicitly configured.
        public let consecutiveWarmupFailuresThreshold: Int

        init(
            port: Int?,
            prewarmPoolSize: Int = 1,
            maxInstanceCount: Int = 1,
            maxAuthContextCount: Int = 1,
            enforceRequestBypass: Bool? = false,
            disabled: Bool = false,
            prewarmedAdmissionPolicy: PrewarmedAdmissionPolicy = .disabled,
            supportApps: [String] = [],
            transitiveTrust: TransitiveTrustCloudAppConfig = .noChanges,
            shadow: ShadowCloudAppConfig = .notShadowed,
            assets: AssetsConfig = .init(),
            maxApplicationLayerMessageSize: Int = defaultMaxApplicationLayerMessageSize,
            maxToolInvocationsPerRequest: Int = defaultMaxToolInvocationsPerRequest,
            maxCumulativeRequestBytes: Int? = nil,
            inMemoryController: AppControllerConfig = .inMemoryControllerNotEnabled,
            isTrampolineProxy: Bool = false,
            teardownTimeout: Duration = .seconds(10),
            warmupTimeout: Duration? = nil,
            consecutiveWarmupFailuresThreshold: Int? = nil
        ) {
            self.port = port
            self.prewarmPoolSize = prewarmPoolSize
            self.maxInstanceCount = maxInstanceCount
            self.maxAuthContextCount = min(maxAuthContextCount, maxInstanceCount)
            self.isTrampolineProxy = isTrampolineProxy
            self.enforceRequestBypass = isTrampolineProxy ? true : enforceRequestBypass
            self.disabled = disabled
            self.prewarmedAdmissionPolicy = prewarmedAdmissionPolicy
            self.supportApps = .init(supportApps)
            self.transitiveTrust = transitiveTrust
            self.shadow = shadow
            self.assets = assets
            self.maxApplicationLayerMessageSize = maxApplicationLayerMessageSize

            if maxToolInvocationsPerRequest <= 0 {
                SecureConfig.logger.warning(
                    "Received non-positive maxToolInvocationsPerRequest (\(maxToolInvocationsPerRequest, privacy: .public)) for cloud app. Setting maxToolInvocationsPerRequest=0 (CloudApp will not be able to make tool calls)"
                )
                self.maxToolInvocationsPerRequest = 0
            } else {
                self.maxToolInvocationsPerRequest = maxToolInvocationsPerRequest
            }

            if let maxCumulativeRequestBytes, maxCumulativeRequestBytes <= 0 {
                SecureConfig.logger
                    .warning(
                        "Ignoring non-positive maxCumulativeRequestBytes (\(maxCumulativeRequestBytes)) for cloud app"
                    )
            }
            self.maxCumulativeRequestBytes = maxCumulativeRequestBytes.flatMap { $0 > 0 ? $0 : nil }
            self.inMemoryController = inMemoryController
            self.teardownTimeout = teardownTimeout
            self.warmupTimeout = warmupTimeout
            self.consecutiveWarmupFailuresThreshold = consecutiveWarmupFailuresThreshold ?? prewarmPoolSize
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
            self.isTrampolineProxy = copy.isTrampolineProxy
            self.enforceRequestBypass = copy.isTrampolineProxy ? true : copy.enforceRequestBypass
            self.disabled = copy.disabled
            self.prewarmedAdmissionPolicy = copy.prewarmedAdmissionPolicy
            self.supportApps = copy.supportApps
            self.transitiveTrust = copy.transitiveTrust
            self.shadow = copy.shadow
            self.assets = copy.assets
            self.maxApplicationLayerMessageSize = copy.maxApplicationLayerMessageSize
            self.maxToolInvocationsPerRequest = copy.maxToolInvocationsPerRequest
            self.maxCumulativeRequestBytes = copy.maxCumulativeRequestBytes
            self.inMemoryController = copy.inMemoryController
            self.teardownTimeout = copy.teardownTimeout
            self.warmupTimeout = copy.warmupTimeout
            self.consecutiveWarmupFailuresThreshold = copy.consecutiveWarmupFailuresThreshold
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

        public let appRoutingKeys: [String]

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
            workloadTags: [String: WorkloadTagValue] = [:],
            appRoutingKeys: [String] = []
        ) {
            self.inMemoryEnabled = inMemoryEnabled
            self.workloadName = workloadName
            self.maxConcurrency = maxConcurrency
            self.optimalBatchSize = optimalBatchSize ?? maxConcurrency
            self.proxyServices = proxyServices
            self.workloadTags = workloadTags
            self.appRoutingKeys = appRoutingKeys
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
        let allowAttestationTestFormats: Bool?
        let routingGroupAliases: [String]?
        let grpcForceIPv6Resolution: Bool?
        let convergenceSpanID: String
        let convergenceTraceID: String
        let cloudAppNames: [String]
        let cloudAppConfigMap: [String: CloudAppConfig]
        let bridgeDaemonConfig: BridgeDaemonConfig
        let persistentServices: [String]
        let persistentServiceClients: [String]
        let persistentServicePort: Int
        /// Per-service cap on concurrent cb_pserverhelper instances the
        /// server will spawn for the named service. Missing entries fall
        /// back to the provider's default (500). Keyed by the service ID
        /// listed in `persistentServices`.
        let persistentServiceMaxConcurrentHelperInstances: [String: Int]
        /// Per-service jitter window (seconds) over which the server spreads
        /// `connectionShouldBeRecreated` notifications after an attestation-key
        /// roll, so a fleet-synchronized roll doesn't fire every client's
        /// reconnection at once. Missing entries fall back to the default.
        /// Keyed by the service ID listed in `persistentServices`.
        let persistentServiceDrainNotificationMaxJitterSeconds: [String: Int]
        /// Per-service runway (seconds) on the bound key reserved for the client
        /// to establish a replacement connection; the jitter never eats into it.
        /// Missing entries fall back to the default. Keyed by service ID.
        let persistentServiceDrainNotificationSafetyMarginSeconds: [String: Int]
        let isolationDomain: String?
        let teardownTimeoutSeconds: Int
        let useV2ServiceDiscovery: Bool
        let skipMultiAppValidations: Bool
        let enableTransitiveProofVerification: Bool
        let transparencyCacheEnabled: Bool
        let maximumTransparencyCacheLogEntrySize: Int
        let maximumTransparencyCacheConsistencySize: Int
        let transparencyCacheExpirySweepIntervalSeconds: Int
        let recycleCheckIntervalSeconds: Int
        let unpublishExistingAttestationsOnRecycle: Bool
        let includeTransparencyConstraintsInWorkerRequests: Bool
        let transitiveTrustWarmupMaxKeysToValidate: Int
        let clientHelperAttestationWarmupTimeoutSeconds: Int
        let attestationUsageReportsBufferLimit: Int
        let reputationPATSigningKey: String?
        let monitoringBridgeService: SecureConfig.BridgeServiceMonitoringConfig

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

            func readMaxToolInvocationsPerRequest(appName: String) -> Int {
                let configured = readNumberParameter(
                    key: "com.apple.cloudboard.cloudApp.\(appName).maxToolInvocationsPerRequest",
                    defaultValue: CloudAppConfig.defaultMaxToolInvocationsPerRequest
                )
                if configured > CloudAppConfig.defaultMaxToolInvocationsPerRequest {
                    SecureConfig.logger.warning(
                        "com.apple.cloudboard.cloudApp.\(appName, privacy: .public).maxToolInvocationsPerRequest > defaultMaxToolInvocationsPerRequest(\(CloudAppConfig.defaultMaxToolInvocationsPerRequest, privacy: .public))"
                    )
                }
                switch securityPolicy {
                case .customer:
                    if configured > CloudAppConfig.defaultMaxToolInvocationsPerRequest,
                       disableAppleInfrastructureEnforcementForResearch != true {
                        SecureConfig.logger.warning(
                            "Setting maxToolInvocationsPerRequest=defaultMaxToolInvocationsPerRequest(\(CloudAppConfig.defaultMaxToolInvocationsPerRequest, privacy: .public))"
                        )
                        return CloudAppConfig.defaultMaxToolInvocationsPerRequest
                    }
                    return configured
                case .none, .carry:
                    return configured
                }
            }

            let isProxy = secureConfigParameters.cloudboard_isProxy ?? false
            self.isProxy = isProxy
            self.enforceRequestBypass = readParameter(
                key: "com.apple.cloudboard.enforceRequestBypass", defaultValue: false
            )
            self.allowAttestationTestFormats = readOptional(
                "com.apple.cloudboard.allowAttestationTestFormats"
            )
            self.rackID = secureConfigParameters.cloudAttestationRackId
            self.routingGroupAliases = readParameter(key: "com.apple.cloudboard.routingGroupAliases", defaultValue: nil)
            self.grpcForceIPv6Resolution = readParameter(
                key: "com.apple.cloudboard.grpc.forceIPv6Resolution",
                defaultValue: nil
            )
            // Nodes that host persistent-service servers default to the V2 service
            // discovery wire because the ROPES `serviceMetadata` block is only
            // representable there (the V1 meta value type cannot carry a nested map).
            // This flips the node's single SD connection — and therefore every
            // registration on the node, including any co-located cloudApp/proxy
            // workloads — to V2; that whole-node move is intentional, as the V2 SD
            // backend is expected wherever persistent-service hosts run. Operators
            // can still force V1/V2 explicitly via the parameter below.
            let persistentServices: [String] = readParameter(
                key: "com.apple.cloudboard.persistentServices",
                defaultValue: []
            )
            self.useV2ServiceDiscovery = readParameter(
                key: "com.apple.cloudboard.serviceDiscovery.v2",
                defaultValue: !persistentServices.isEmpty
            )

            self.skipMultiAppValidations = readParameter(
                key: "com.apple.cloudboard.skipMultiAppValidations",
                defaultValue: false
            )

            // Cross-component parameters used for convergence tracing
            self.convergenceSpanID = readParameter(key: "com.apple.cloudos.tracing.spanID", defaultValue: "")
            self.convergenceTraceID = readParameter(key: "com.apple.cloudos.tracing.traceID", defaultValue: "")
            let teardownTimeoutSeconds = readNumberParameter(
                key: "com.apple.cloudboard.teardownTimeoutSeconds",
                defaultValue: 10
            )
            self.teardownTimeoutSeconds = teardownTimeoutSeconds
            self.transitiveTrustWarmupMaxKeysToValidate = readNumberParameter(
                key: "com.apple.cloudboard.attestation.transitiveTrustWarmupMaxKeysToValidate",
                defaultValue: 3
            )
            self.clientHelperAttestationWarmupTimeoutSeconds = readNumberParameter(
                key: "com.apple.cloudboard.persistentService.clientHelperAttestationWarmupTimeoutSeconds",
                defaultValue: 30
            )
            self.attestationUsageReportsBufferLimit = readNumberParameter(
                key: "com.apple.cloudboard.persistentService.attestationUsageReportsBufferLimit",
                defaultValue: SecureConfig.defaultAttestationUsageReportsBufferLimit
            )
            self.reputationPATSigningKey = readOptional("com.apple.cloudboard.reputationPATSigningKey")
            self.monitoringBridgeService = SecureConfig.BridgeServiceMonitoringConfig(
                enabled: readParameter(
                    key: "com.apple.cloudboard.bridgeMonitoring.enableMonitoringBridgeService", defaultValue: false
                ),
                // Setting default timeout as 1 day since when the ping request to bridge server fails,
                // cloudboard will just throw an error and restart and fail again until bridge server gets healthy.
                // so no real benefit of having a shorter timeout here.
                connectionTimeout: .seconds(readNumberParameter(
                    key: "com.apple.cloudboard.bridgeMonitoring.connectionTimeoutSeconds", defaultValue: 60 * 60 * 12
                )),
                connectionBackoff: .init(
                    initialDelay: .seconds(readNumberParameter(
                        key: "com.apple.cloudboard.bridgeMonitoring.connectionBackoff.initialDelaySeconds",
                        defaultValue: 1
                    )),
                    multiplier: readParameter(
                        key: "com.apple.cloudboard.bridgeMonitoring.connectionBackoff.multiplier", defaultValue: 2.0
                    ),
                    maxDelay: .seconds(readNumberParameter(
                        key: "com.apple.cloudboard.bridgeMonitoring.connectionBackoff.maxDelaySeconds", defaultValue: 30
                    )),
                    jitterPercent: readParameter(
                        key: "com.apple.cloudboard.bridgeMonitoring.connectionBackoff.jitterPercent", defaultValue: 0.25
                    )
                )
            )
            self.cloudAppNames = readParameter(
                key: "com.apple.cloudboard.cloudApps",
                defaultValue: self.isProxy ? ["TIEProxyApp"] : ["TIECloudApp"]
            )
            let securityPolicy = self.securityPolicy
            let disableAppleInfrastructureEnforcementForResearch = self.disableAppleInfrastructureEnforcementForResearch
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

                let isTrampolineProxy: Bool = isProxy ? readParameter(
                    key: "com.apple.cloudboard.cloudApp.\($1).isTrampolineProxy",
                    defaultValue: false
                ) : false
                let maxInstanceCount: Int = readNumberParameter(
                    key: "com.apple.cloudboard.cloudApp.\($1).maxProcessCount",
                    defaultValue: isTrampolineProxy ? 200 : (isProxy ? 25 : 3)
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
                let prewarmPoolSize = readNumberParameter(
                    key: "com.apple.cloudboard.cloudApp.\($1).prewarmPoolSize",
                    defaultValue: isTrampolineProxy ? 200 : (isProxy ? 25 : 3)
                )
                let maxBatchDependsOnPrewarmedSize = readParameter(
                    key: "com.apple.cloudboard.cloudApp.\($1).maxBatchDependsOnPrewarmedSize",
                    defaultValue: false
                )
                let waitForPrewarmedInsteadOfRejecting = readParameter(
                    key: "com.apple.cloudboard.cloudApp.\($1).waitForPrewarmedInsteadOfRejecting",
                    defaultValue: false
                )
                let prewarmedAdmissionPolicy: PrewarmedAdmissionPolicy = if !maxBatchDependsOnPrewarmedSize {
                    .disabled
                } else if waitForPrewarmedInsteadOfRejecting {
                    .waitForPrewarmed
                } else {
                    .rejectIfNoPrewarmed
                }
                // The in-memory controller's concurrency is known statically here. When
                // maxBatchDependsOnPrewarmedSize is enabled the node can never warm more instances than the prewarm
                // pool holds, so a controller configured to advertise more than that could never reach its ceiling.
                // Reject it at parse time rather than silently under-serving; the runtime clamp in WorkloadController
                // then only ever has to handle externally-registered controllers, whose maxBatchSize is not known
                // until registration. Read the key only when the in-memory controller is enabled so a malformed value
                // on an app whose controller is disabled does not abort parsing.
                let inMemoryMaxConcurrency: Int? = if inMemoryControllerEnabled {
                    readNumberParameter(
                        key: "\(controller).maxConcurrency",
                        defaultValue: maxInstanceCount
                    )
                } else {
                    nil
                }
                if let inMemoryMaxConcurrency, maxBatchDependsOnPrewarmedSize,
                   inMemoryMaxConcurrency > prewarmPoolSize {
                    throw SecureConfigError.inMemoryControllerMaxConcurrencyExceedsPrewarmPoolSize(
                        cloudApp: $1,
                        maxConcurrency: inMemoryMaxConcurrency,
                        prewarmPoolSize: prewarmPoolSize
                    )
                }
                $0[$1] = .init(
                    port: port,
                    prewarmPoolSize: prewarmPoolSize,
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
                    prewarmedAdmissionPolicy: prewarmedAdmissionPolicy,
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
                        pickRatioCanScaleTo: readOptionalNumber(
                            "\(transitiveTrust).pickRatioCanScaleTo"
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
                    maxToolInvocationsPerRequest: readMaxToolInvocationsPerRequest(appName: $1),
                    maxCumulativeRequestBytes: readOptionalNumber(
                        "com.apple.cloudboard.cloudApp.\($1).maxCumulativeRequestBytes"
                    ),
                    inMemoryController: inMemoryControllerEnabled ? .init(
                        inMemoryEnabled: readParameter(key: "\(controller).enabled", defaultValue: false),
                        workloadName: inMemoryControllerWorkloadName,
                        maxConcurrency: inMemoryMaxConcurrency ?? maxInstanceCount,
                        proxyServices: readParameter(key: "\(controller).proxyServices", defaultValue: []),
                        workloadTags: controllerWorkloadTags,
                        appRoutingKeys: readParameter(key: "\(controller).appRoutingKeys", defaultValue: [])
                    ) : .inMemoryControllerNotEnabled,
                    isTrampolineProxy: isTrampolineProxy,
                    // Use cloud app specific teardown timeout configuration if provided, otherwise use global
                    // configuration
                    teardownTimeout: .seconds(readNumberParameter(
                        key: "com.apple.cloudboard.cloudApp.\($1).teardownTimeoutSeconds",
                        defaultValue: teardownTimeoutSeconds
                    )),
                    warmupTimeout: readOptionalNumber(
                        "com.apple.cloudboard.cloudApp.\($1).warmupTimeoutMilliseconds"
                    ).map { .milliseconds($0) },
                    consecutiveWarmupFailuresThreshold: readOptionalNumber(
                        "com.apple.cloudboard.cloudApp.\($1).consecutiveWarmupFailuresThreshold"
                    )
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

            let identityManager: BridgeDaemonConfig.IdentityManagerConfig = .init(
                useSelfSignedCertificate: readParameter(
                    key: "com.apple.cloudboard.cb_bridged.identityManager.useSelfSignedCertificate",
                    defaultValue: false
                ),
                aquariaAPRN: readParameter(
                    key: "com.apple.cloudboard.cb_bridged.identityManager.aquariaAPRN",
                    defaultValue: nil
                ),
                aquariaSanDNS: readParameter(
                    key: "com.apple.cloudboard.cb_bridged.identityManager.aquariaSanDNS",
                    defaultValue: nil
                ),
                aquariaTag: readParameter(
                    key: "com.apple.cloudboard.cb_bridged.identityManager.aquariaTag",
                    defaultValue: nil
                ),
                aquariaIdentityBackoff: BridgeDaemonConfig.ConnectionBackoff(
                    initial: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.identityManager.aquariaIdentityBackoff.initial",
                        defaultValue: 2.0
                    ),
                    maximum: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.identityManager.aquariaIdentityBackoff.maximum",
                        defaultValue: 30.0
                    ),
                    factor: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.identityManager.aquariaIdentityBackoff.factor",
                        defaultValue: 2.0
                    ),
                    jitterPercent: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.identityManager.aquariaIdentityBackoff.jitterPercent",
                        defaultValue: 0.2
                    ),
                    coolDown: readOptionalNumber(
                        "com.apple.cloudboard.cb_bridged.identityManager.aquariaIdentityBackoff.coolDown"
                    )
                ),
            )

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
                    ),
                    attemptCount: readNumberParameter(
                        key: "com.apple.cloudboard.cb_bridged.pirService.attemptCount",
                        defaultValue: 1
                    ),
                    retryDelay: .milliseconds(
                        readNumberParameter(
                            key: "com.apple.cloudboard.cb_bridged.pirService.retryDelayMilliseconds",
                            defaultValue: 100
                        )
                    ),
                    requestTimeout: .milliseconds(
                        readNumberParameter(
                            key: "com.apple.cloudboard.cb_bridged.pirService.requestTimeoutMilliseconds",
                            defaultValue: 10000
                        )
                    )
                )
            } else {
                pirService = nil
            }

            let toolGateway: BridgeDaemonConfig
                .ToolGatewayServiceConfig? = if let toolGatewayTargetHost: String =
                readOptional("com.apple.cloudboard.cb_bridged.toolGateway.targetHost"),
                let toolGatewayTargetPort: Int =
                readOptionalNumber("com.apple.cloudboard.cb_bridged.toolGateway.targetPort") {
                BridgeDaemonConfig.ToolGatewayServiceConfig(
                    targetHost: toolGatewayTargetHost,
                    targetPort: toolGatewayTargetPort,
                    tlsConfig: BridgeDaemonConfig.TLSConfiguration(
                        enable: readParameter(
                            key: "com.apple.cloudboard.cb_bridged.toolGateway.tlsConfig.enable",
                            defaultValue: true
                        ),
                        sniOverride: readOptional("com.apple.cloudboard.cb_bridged.toolGateway.tlsConfig.sniOverride"),
                        enablemTLS: readParameter(
                            key: "com.apple.cloudboard.cb_bridged.toolGateway.tlsConfig.enablemTLS",
                            defaultValue: true
                        )
                    ),
                    idleTimeoutSeconds: readNumberParameter(
                        key: "com.apple.cloudboard.cb_bridged.toolGateway.idleTimeoutSeconds",
                        defaultValue: 30 * 60
                    ),
                    backoffConfig: BridgeDaemonConfig.ConnectionBackoff(
                        initial: readParameter(
                            key: "com.apple.cloudboard.cb_bridged.toolGateway.backoffConfig.initial",
                            defaultValue: 1.0
                        ),
                        maximum: readParameter(
                            key: "com.apple.cloudboard.cb_bridged.toolGateway.backoffConfig.maximum",
                            defaultValue: 120.0
                        ),
                        factor: readParameter(
                            key: "com.apple.cloudboard.cb_bridged.toolGateway.backoffConfig.factor",
                            defaultValue: 1.6
                        ),
                        jitterPercent: readParameter(
                            key: "com.apple.cloudboard.cb_bridged.toolGateway.backoffConfig.jitterPercent",
                            defaultValue: 0.2
                        ),
                        coolDown: readOptionalNumber(
                            "com.apple.cloudboard.cb_bridged.toolGateway.backoffConfig.coolDown"
                        )
                    ),
                    targetPolicyAPRNs: readOptional(
                        "com.apple.cloudboard.cb_bridged.toolGateway.targetPolicyAPRNs"
                    )
                )
            } else {
                nil
            }

            var appleSigningService: BridgeDaemonConfig.AppleSigningServiceConfig?
            if let appleSigningServiceServiceURL: String =
                readOptional("com.apple.cloudboard.cb_bridged.appleSigningService.serviceUrl"),
                let appleSigningServiceAccountID: String =
                readOptional("com.apple.cloudboard.cb_bridged.appleSigningService.accountID"),
                let appleSigningServicekeyID: String =
                readOptional("com.apple.cloudboard.cb_bridged.appleSigningService.keyID") {
                guard let appleSigningServiceServiceURL = URL(string: appleSigningServiceServiceURL) else {
                    throw SecureConfigError.invalidURL(appleSigningServiceServiceURL)
                }
                appleSigningService = .init(
                    accountID: appleSigningServiceAccountID,
                    keyID: appleSigningServicekeyID,
                    serviceURL: appleSigningServiceServiceURL,
                    disableMTLS: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.appleSigningService.disableMTLS",
                        defaultValue: false
                    ),
                    allowInsecure: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.appleSigningService.allowInsecure",
                        defaultValue: false
                    ),
                    attemptCount: readNumberParameter(
                        key: "com.apple.cloudboard.cb_bridged.appleSigningService.attemptCount",
                        defaultValue: 3
                    ),
                    retryDelay: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.appleSigningService.retryDelay",
                        defaultValue: 5
                    ),
                    httpRequestTimeout: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.appleSigningService.httpRequestTimeout",
                        defaultValue: 30
                    )
                )
            }

            var cipCompanionService: BridgeDaemonConfig.CIPCompanionServiceConfig?
            if let cipCompanionServiceServiceURL: String =
                readOptional("com.apple.cloudboard.cb_bridged.cipCompanionService.serviceUrl") {
                guard let serviceURL = URL(string: cipCompanionServiceServiceURL) else {
                    throw SecureConfigError.invalidURL(cipCompanionServiceServiceURL)
                }
                cipCompanionService = .init(
                    serviceURL: serviceURL,
                    disableMTLS: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.cipCompanionService.disableMTLS",
                        defaultValue: false
                    ),
                    allowInsecure: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.cipCompanionService.allowInsecure",
                        defaultValue: false
                    ),
                    attemptCount: readNumberParameter(
                        key: "com.apple.cloudboard.cb_bridged.cipCompanionService.attemptCount",
                        defaultValue: 3
                    ),
                    retryDelay: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.cipCompanionService.retryDelay",
                        defaultValue: 5
                    ),
                    httpRequestTimeout: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.cipCompanionService.httpRequestTimeout",
                        defaultValue: 30
                    )
                )
            }

            // Resolve the list of persistent-service clients early so the
            // bridge daemon config can build per-service maps (e.g. the
            // per-unit cap) from it.
            let persistentServiceClients: [String] = readParameter(
                key: "com.apple.cloudboard.persistentServiceClients",
                defaultValue: []
            )

            // Build the per-service cap map. Each service may opt in via
            // `com.apple.cloudboard.cb_bridged.persistentService.<service>.maxServersPerUnit`.
            // Services that don't set the key are uncapped (today's behaviour).
            var maxServersPerUnit: [String: Int] = [:]
            for service in persistentServiceClients {
                if let cap: Int = readOptionalNumber(
                    "com.apple.cloudboard.cb_bridged.persistentService.\(service).maxServersPerUnit"
                ) {
                    maxServersPerUnit[service] = cap
                }
            }

            // Build the per-service swap-on-failure threshold map.
            // `com.apple.cloudboard.cb_bridged.persistentService.<service>.swapOnFailureThreshold`.
            // Missing services fall back to the manager's default of 2.
            var swapOnFailureThreshold: [String: Int] = [:]
            for service in persistentServiceClients {
                if let threshold: Int = readOptionalNumber(
                    "com.apple.cloudboard.cb_bridged.persistentService.\(service).swapOnFailureThreshold"
                ) {
                    swapOnFailureThreshold[service] = threshold
                }
            }

            // Capability IDs the bridge discards during SD capability parsing.
            // Applied across all persistent services on this node.
            let blockedCapabilities: [String] = readParameter(
                key: "com.apple.cloudboard.cb_bridged.persistentService.blockedCapabilities",
                defaultValue: []
            )

            // HTTP/2 keepalive PING/PONG knobs. `ClientConnectionKeepalive`
            // preconditions on `interval > 0`, `timeout > 0`, and
            // `timeout < interval` (it would crash the daemon on first
            // channel construction otherwise); validate up front against
            // the resolved values so a misconfiguration surfaces at
            // startup with a meaningful error rather than as a
            // precondition trap later.
            let http2KeepalivePingIntervalSeconds: Int? = readOptionalNumber(
                "com.apple.cloudboard.cb_bridged.persistentService.http2KeepalivePingIntervalSeconds"
            )
            let http2KeepalivePongTimeoutSeconds: Int? = readOptionalNumber(
                "com.apple.cloudboard.cb_bridged.persistentService.http2KeepalivePongTimeoutSeconds"
            )
            let effectiveKeepaliveInterval = http2KeepalivePingIntervalSeconds
                ?? SecureConfig.defaultPersistentServiceHttp2KeepalivePingIntervalSeconds
            let effectiveKeepaliveTimeout = http2KeepalivePongTimeoutSeconds
                ?? SecureConfig.defaultPersistentServiceHttp2KeepalivePongTimeoutSeconds
            if let reason = SecureConfig.validateHttp2Keepalive(
                intervalSeconds: effectiveKeepaliveInterval,
                timeoutSeconds: effectiveKeepaliveTimeout
            ) {
                throw SecureConfigError.invalidPersistentServiceHttp2Keepalive(
                    intervalSeconds: effectiveKeepaliveInterval,
                    timeoutSeconds: effectiveKeepaliveTimeout,
                    reason: reason
                )
            }

            let persistentService = BridgeDaemonConfig.PersistentServiceConfig(
                tlsConfig: BridgeDaemonConfig.TLSConfiguration(
                    enable: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.persistentService.tlsConfig.enable",
                        defaultValue: true
                    ),
                    sniOverride: readOptional(
                        "com.apple.cloudboard.cb_bridged.persistentService.tlsConfig.sniOverride"
                    ),
                    enablemTLS: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.persistentService.tlsConfig.enablemTLS",
                        defaultValue: true
                    )
                ),
                backoffConfig: BridgeDaemonConfig.ConnectionBackoff(
                    initial: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.persistentService.backoffConfig.initial",
                        defaultValue: 1.0
                    ),
                    maximum: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.persistentService.backoffConfig.maximum",
                        defaultValue: 120.0
                    ),
                    factor: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.persistentService.backoffConfig.factor",
                        defaultValue: 1.6
                    ),
                    jitterPercent: readParameter(
                        key: "com.apple.cloudboard.cb_bridged.persistentService.backoffConfig.jitterPercent",
                        defaultValue: 0.2
                    ),
                    coolDown: readOptionalNumber(
                        "com.apple.cloudboard.cb_bridged.persistentService.backoffConfig.coolDown"
                    )
                ),
                keepaliveIntervalSeconds: readOptionalNumber(
                    "com.apple.cloudboard.cb_bridged.persistentService.keepaliveIntervalSeconds"
                ),
                idleTimeoutSeconds: readOptionalNumber(
                    "com.apple.cloudboard.cb_bridged.persistentService.idleTimeoutSeconds"
                ),
                drainCompleteWaitTimeoutSeconds: readOptionalNumber(
                    "com.apple.cloudboard.cb_bridged.persistentService.drainCompleteWaitTimeoutSeconds"
                ),
                replacementReadyWaitTimeoutSeconds: readOptionalNumber(
                    "com.apple.cloudboard.cb_bridged.persistentService.replacementReadyWaitTimeoutSeconds"
                ),
                maxServersPerUnit: maxServersPerUnit.isEmpty ? nil : maxServersPerUnit,
                connectionEstablishmentTimeoutSeconds: readOptionalNumber(
                    "com.apple.cloudboard.cb_bridged.persistentService.connectionEstablishmentTimeoutSeconds"
                ),
                swapOnFailureThreshold: swapOnFailureThreshold.isEmpty ? nil : swapOnFailureThreshold,
                http2KeepalivePingIntervalSeconds: http2KeepalivePingIntervalSeconds,
                http2KeepalivePongTimeoutSeconds: http2KeepalivePongTimeoutSeconds,
                maxConcurrentHelperInstances: readOptionalNumber(
                    "com.apple.cloudboard.cb_bridged.persistentService.maxConcurrentHelperInstances"
                ),
                blockedCapabilities: blockedCapabilities
            )

            self.bridgeDaemonConfig = .init(
                identityManager: identityManager,
                pirService: pirService,
                toolGateway: toolGateway,
                appleSigningService: appleSigningService,
                cipCompanionService: cipCompanionService,
                persistentService: persistentService
            )

            self.persistentServices = persistentServices

            self.persistentServiceClients = persistentServiceClients

            self.persistentServicePort = readNumberParameter(
                key: "com.apple.cloudboard.persistentService.port",
                defaultValue: 50053
            )

            // Per-service cap on concurrent cb_pserverhelper instances.
            // Only services listed in `persistentServices` are checked;
            // missing entries fall back to the provider default.
            var perServiceHelperCap: [String: Int] = [:]
            var perServiceDrainMaxJitter: [String: Int] = [:]
            var perServiceDrainSafetyMargin: [String: Int] = [:]
            for service in self.persistentServices {
                if let cap: Int = readOptionalNumber(
                    "com.apple.cloudboard.persistentService.\(service).maxConcurrentHelperInstances"
                ) {
                    perServiceHelperCap[service] = cap
                }
                if let jitter: Int = readOptionalNumber(
                    "com.apple.cloudboard.persistentService.\(service).drainNotificationMaxJitterSeconds"
                ) {
                    perServiceDrainMaxJitter[service] = jitter
                }
                if let margin: Int = readOptionalNumber(
                    "com.apple.cloudboard.persistentService.\(service).drainNotificationSafetyMarginSeconds"
                ) {
                    perServiceDrainSafetyMargin[service] = margin
                }
            }
            self.persistentServiceMaxConcurrentHelperInstances = perServiceHelperCap
            self.persistentServiceDrainNotificationMaxJitterSeconds = perServiceDrainMaxJitter
            self.persistentServiceDrainNotificationSafetyMarginSeconds = perServiceDrainSafetyMargin

            self.isolationDomain = readParameter(
                key: "com.apple.cloudboard.persistentService.isolationDomain",
                defaultValue: nil
            )

            self.enableTransitiveProofVerification = readParameter(
                key: "com.apple.cloudboard.attestation.enableTransitiveProofVerification", defaultValue: true
            )
            self.transparencyCacheEnabled = readParameter(
                key: "com.apple.cloudboard.attestation.transparencyCache.enabled", defaultValue: true
            )
            self.maximumTransparencyCacheLogEntrySize = readNumberParameter(
                key: "com.apple.cloudboard.attestation.transparencyCache.maxLogEntrySize", defaultValue: 1000
            )
            self.maximumTransparencyCacheConsistencySize = readNumberParameter(
                key: "com.apple.cloudboard.attestation.transparencyCache.maxConsistencySize", defaultValue: 100
            )
            self.transparencyCacheExpirySweepIntervalSeconds = readNumberParameter(
                key: "com.apple.cloudboard.attestation.transparencyCache.expirySweepIntervalSeconds", defaultValue: 600
            )
            self.recycleCheckIntervalSeconds = readNumberParameter(
                key: "com.apple.cloudboard.attestation.recycleCheckIntervalSeconds", defaultValue: 300
            )
            self.unpublishExistingAttestationsOnRecycle = readParameter(
                key: "com.apple.cloudboard.attestation.unpublishExistingAttestationsOnRecycle", defaultValue: true
            )
            self.includeTransparencyConstraintsInWorkerRequests = readParameter(
                key: "com.apple.cloudboard.attestation.includeTransparencyConstraintsInWorkerRequests",
                defaultValue: true
            )
        }

        // exposed for testing only
        internal init(
            cloudAppConfigMap: [String: CloudAppConfig] = [:],
            securityPolicy: SecurityPolicy,
            disableAppleInfrastructureEnforcementForResearch: Bool? = nil,
            isProxy: Bool = false,
            enforceRequestBypass: Bool = false,
            allowAttestationTestFormats: Bool? = nil,
            routingGroupAliases: [String]? = nil,
            rackID: String = "",
            grpcForceIPv6Resolution: Bool? = nil,
            useV2ServiceDiscovery: Bool = true,
            convergenceSpanID: String = "",
            convergenceTraceID: String = "",
            teardownTimeoutSeconds: Int = 10,
            bridgeDaemonConfig: BridgeDaemonConfig = .init(identityManager: .init(useSelfSignedCertificate: false)),
            persistentServices: [String] = [],
            persistentServiceClients: [String] = [],
            persistentServicePort: Int = 50053,
            persistentServiceMaxConcurrentHelperInstances: [String: Int] = [:],
            persistentServiceDrainNotificationMaxJitterSeconds: [String: Int] = [:],
            persistentServiceDrainNotificationSafetyMarginSeconds: [String: Int] = [:],
            isolationDomain: String? = nil,
            skipMultiAppValidations: Bool = true,
            enableTransitiveProofVerification: Bool = false,
            transparencyCacheEnabled: Bool = true,
            maximumTransparencyCacheLogEntrySize: Int = 1000,
            maximumTransparencyCacheConsistencySize: Int = 100,
            transparencyCacheExpirySweepIntervalSeconds: Int = 600,
            recycleCheckIntervalSeconds: Int = 300,
            unpublishExistingAttestationsOnRecycle: Bool = true,
            includeTransparencyConstraintsInWorkerRequests: Bool = true,
            transitiveTrustWarmupMaxKeysToValidate: Int = 3,
            clientHelperAttestationWarmupTimeoutSeconds: Int = 30,
            attestationUsageReportsBufferLimit: Int = SecureConfig.defaultAttestationUsageReportsBufferLimit,
            reputationPATSigningKey: String? = nil,
            monitoringBridgeService: SecureConfig.BridgeServiceMonitoringConfig = SecureConfig
                .BridgeServiceMonitoringConfig.disabled
        ) {
            self.securityPolicy = securityPolicy
            self.disableAppleInfrastructureEnforcementForResearch = disableAppleInfrastructureEnforcementForResearch
            self.isProxy = isProxy
            self.enforceRequestBypass = enforceRequestBypass
            self.allowAttestationTestFormats = allowAttestationTestFormats
            self.routingGroupAliases = routingGroupAliases
            self.grpcForceIPv6Resolution = grpcForceIPv6Resolution
            self.convergenceSpanID = convergenceSpanID
            self.convergenceTraceID = convergenceTraceID
            self.teardownTimeoutSeconds = teardownTimeoutSeconds
            self.cloudAppNames = cloudAppConfigMap.map { $0.key }
            self.cloudAppConfigMap = cloudAppConfigMap
            self.rackID = rackID
            self.bridgeDaemonConfig = bridgeDaemonConfig
            self.persistentServices = persistentServices
            self.persistentServiceClients = persistentServiceClients
            self.persistentServicePort = persistentServicePort
            self.persistentServiceMaxConcurrentHelperInstances = persistentServiceMaxConcurrentHelperInstances
            self.persistentServiceDrainNotificationMaxJitterSeconds = persistentServiceDrainNotificationMaxJitterSeconds
            self
                .persistentServiceDrainNotificationSafetyMarginSeconds =
                persistentServiceDrainNotificationSafetyMarginSeconds
            self.isolationDomain = isolationDomain
            self.useV2ServiceDiscovery = useV2ServiceDiscovery
            self.skipMultiAppValidations = skipMultiAppValidations
            self.maximumTransparencyCacheLogEntrySize = maximumTransparencyCacheLogEntrySize
            self.maximumTransparencyCacheConsistencySize = maximumTransparencyCacheConsistencySize
            self.enableTransitiveProofVerification = enableTransitiveProofVerification
            self.transparencyCacheEnabled = transparencyCacheEnabled
            self.transparencyCacheExpirySweepIntervalSeconds = transparencyCacheExpirySweepIntervalSeconds
            self.recycleCheckIntervalSeconds = recycleCheckIntervalSeconds
            self.unpublishExistingAttestationsOnRecycle = unpublishExistingAttestationsOnRecycle
            self.includeTransparencyConstraintsInWorkerRequests = includeTransparencyConstraintsInWorkerRequests
            self.transitiveTrustWarmupMaxKeysToValidate = transitiveTrustWarmupMaxKeysToValidate
            self.clientHelperAttestationWarmupTimeoutSeconds = clientHelperAttestationWarmupTimeoutSeconds
            self.attestationUsageReportsBufferLimit = attestationUsageReportsBufferLimit
            self.reputationPATSigningKey = reputationPATSigningKey
            self.monitoringBridgeService = monitoringBridgeService
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
            useV2ServiceDiscovery: Bool = true,
            convergenceSpanID: String = "",
            convergenceTraceID: String = "",
            teardownTimeoutSeconds: Int = 10,
            assets: AssetsConfig = .init()
        ) {
            guard cloudAppNames.count == 1 else {
                fatalError("This initializer only supports a single cloud app name")
            }
            let cloudAppConfig = CloudAppConfig(
                port: nil,
                assets: assets,
                teardownTimeout: .seconds(teardownTimeoutSeconds)
            )
            self.init(
                cloudAppConfigMap: [cloudAppNames[0]: cloudAppConfig],
                securityPolicy: securityPolicy,
                disableAppleInfrastructureEnforcementForResearch: disableAppleInfrastructureEnforcementForResearch,
                isProxy: isProxy,
                enforceRequestBypass: enforceRequestBypass,
                routingGroupAliases: routingGroupAliases,
                rackID: rackID,
                grpcForceIPv6Resolution: grpcForceIPv6Resolution,
                useV2ServiceDiscovery: useV2ServiceDiscovery,
                convergenceSpanID: convergenceSpanID,
                convergenceTraceID: convergenceTraceID,
                teardownTimeoutSeconds: teardownTimeoutSeconds
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
