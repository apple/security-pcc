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

import CFPreferenceCoder
import CloudBoardCommon
import CloudBoardLogging
import Foundation
import NIOCore
import os

extension CFPreferences {
    static var cbAttestationPreferencesDomain: String {
        "com.apple.cloudos.cb_attestationd"
    }
}

struct CloudBoardAttestationDConfiguration: Codable, Hashable {
    enum CodingKeys: String, CodingKey {
        case _useInMemoryKey = "UseInMemoryKey"
        case _keyLifetimeMinutes = "KeyLifetimeMinutes"
        case _keyExpiryGracePeriodSeconds = "KeyExpiryGracePeriodSeconds"
        case _enableReleaseSetValidation = "EnableReleaseSetValidation"
        case _cloudAttestation = "CloudAttestation"
        case _transparencyLog = "TransparencyLog"
        case _existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition =
            "ExistingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition"
        case _maximumValidatedEntryCacheSize =
            "MaximumValidatedEntryCacheSize"
        case _rackIdCacheLifetimeMinutes = "RackIdCacheLifetimeMinutes"
    }

    private var _useInMemoryKey: Bool?
    private var _keyLifetimeMinutes: Int?
    private var _keyExpiryGracePeriodSeconds: Int?
    // exposed so the backward compatibility config parsing can kick in
    fileprivate var _enableReleaseSetValidation: Bool?
    private var _cloudAttestation: CloudAttestationConfiguration?
    private var _transparencyLog: TransparencyLogConfiguration?
    private var _existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition: Bool?
    private var _maximumValidatedEntryCacheSize: Int?
    private var _rackIdCacheLifetimeMinutes: Int?

    // If true, an in-memory key is used as node key instead of a SEP-backed key. This automatically disables the use of
    // CloudAttestation which require SEP-backed keys. Note that regular clients enforce SEP-backed attested keys and
    // with that cannot talk to nodes with this value set to true.
    var useInMemoryKey: Bool {
        get { self._useInMemoryKey ?? false }
        set { self._useInMemoryKey = newValue }
    }

    /// Lifetime of node keys. Note that in production, the configured key lifetime plus the configured grace period
    /// together is enforced to be below 48 hours.
    var keyLifetime: TimeAmount {
        self._keyLifetimeMinutes.map { .minutes(Int64($0)) } ?? .hours(24)
    }

    /// Grace period in which keys are usable beyond their advertised expiry/lifetime
    var keyExpiryGracePeriod: TimeAmount {
        self._keyExpiryGracePeriodSeconds.map { .seconds(Int64($0)) } ?? .minutes(5)
    }

    // Enable release set validation within a proxy. If this is true, compute nodes must run a release associated
    // with the proxy attestation. This must be enforced when running with a prod security config policy.
    var enableReleaseSetValidation: Bool {
        get { self._enableReleaseSetValidation ?? false }
        set { self._enableReleaseSetValidation = newValue }
    }

    /// CloudAttestation-related configuration. See individual fields for documentation.
    var cloudAttestation: CloudAttestationConfiguration {
        get { return self._cloudAttestation ?? CloudAttestationConfiguration() }
        set { self._cloudAttestation = newValue }
    }

    var transparencyLog: TransparencyLogConfiguration {
        get { return self._transparencyLog ?? TransparencyLogConfiguration() }
        set { self._transparencyLog = newValue }
    }

    /// If true, on a proxy node, whenever there's a new Transparency Log entry
    /// the exisitng attesation will still be valid to be used on the node, but will no longer be available anywhwere
    /// outside the node, like ROPES
    /// There's no affect on a non proxy node.
    var existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition: Bool {
        get { self._existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition ?? true }
        set { self._existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition = newValue }
    }

    /// If non zero, on a proxy node, the successful validation of worker attestations will be cached
    /// up to a maximum of this number (the semantics of how that limit is handled is not specified)
    var maximumValidatedEntryCacheSize: Int {
        get {
            // This default is based on the following heuristics - all with conservative margins added:
            // 30MB The Jetsam limit for the daemon
            // -5MB for existing use (measured at about 4 MB)
            // -5MB for spikes of load (doing validations/flushing to disk, this is based on observations)
            // -10MB for unanticipated use and conservative factor
            // Leaving  10MB for the cache
            //
            // The memory cost of the proxy key+validator is negligible at scale and is limited by rotation
            // and releases, under normal use there would be 2-3 such active keys (thanks to keyExpiryGracePeriod)
            // We wish to cover a release update, which would add an additional key release, so 4 such fully
            // populated per key caches. This doesn't affect our limit, but we should use this to determine if
            // the memory we have allocated to this should be increased.
            //
            // The cost for each entry is documented in PerProxyAttestationCache and is currently
            // 68 bytes * CostFactor
            // CostFactor is dependendent on the size of each cache and the underlying Dictionary load factor.
            // We take an extremely conservative multiplier of 2 for this, then account for the cost of the
            // doubling of the backing array on crossing each scale threshold, so again double
            // everything again and work that into CostFactor taking it to 4
            // We then apply another conservative margin on this of 50%
            // ```
            // size = Memory / 68bytes * CostFactor * Margin
            // size = 10MB / 68B * 4 * 2
            // ```
            // Giving a size of 19275
            self._maximumValidatedEntryCacheSize ?? 19275
        }
        set { self._maximumValidatedEntryCacheSize = newValue }
    }

    var rackIdCacheLifetime: Int {
        get { self._rackIdCacheLifetimeMinutes ?? 0 }
        set { self._rackIdCacheLifetimeMinutes = newValue }
    }

    private var _secureConfig: SecureConfig? = nil
    public var secureConfig: SecureConfig {
        /// Attempting to do this in a real run means we didn't apply security checks,
        /// this should be instantly terminal
        precondition(self._secureConfig != nil, "Attempt to access secureconfig when it has not been hooked up")
        return self._secureConfig!
    }

    /// Returns true if this node is configured to run as a proxy. This is used to determine whether to include
    /// inclusion proofs for proxied compute node releases in the generated attestation bundle.
    var isProxy: Bool {
        return self.secureConfig.isProxy
    }

    init(
        useInMemoryKey: Bool,
        cloudAttestation: CloudAttestationConfiguration,
        secureConfig: SecureConfig
    ) {
        self._useInMemoryKey = useInMemoryKey
        self._cloudAttestation = cloudAttestation
        self._secureConfig = secureConfig
    }

    /// parse from a file, this does not provide the fallback to legacy configuration if not specified
    static func fromFile(
        path: String,
        secureConfigLoader: SecureConfigLoader
    ) throws -> CloudBoardAttestationDConfiguration {
        var config: CloudBoardAttestationDConfiguration
        do {
            CloudBoardAttestationDaemon.logger.info("Loading configuration from file \(path, privacy: .public)")
            let fileContents = try Data(contentsOf: URL(filePath: path))
            let decoder = PropertyListDecoder()
            config = try decoder.decode(CloudBoardAttestationDConfiguration.self, from: fileContents)
        } catch {
            CloudBoardAttestationDaemon.logger.error(
                "Unable to load config from file: \(String(unredacted: error), privacy: .public)"
            )
            throw error
        }

        let secureConfig: SecureConfig
        do {
            CloudBoardAttestationDaemon.logger.info("Loading secure config from SecureConfigDB")
            secureConfig = try secureConfigLoader.load()
        } catch {
            CloudBoardAttestationDaemon.logger
                .error("Error loading secure config: \(String(unredacted: error), privacy: .public)")
            throw error
        }

        try config.applySecureConfig(secureConfig)
        return config
    }

    static func fromPreferences(secureConfigLoader: SecureConfigLoader = .real) throws
    -> CloudBoardAttestationDConfiguration {
        CloudBoardAttestationDaemon.logger
            .info(
                "Loading configuration from preferences \(CFPreferences.cbAttestationPreferencesDomain, privacy: .public)"
            )
        let preferences = CFPreferences(domain: CFPreferences.cbAttestationPreferencesDomain)
        do {
            return try .fromPreferences(preferences, secureConfigLoader: secureConfigLoader)
        } catch {
            CloudBoardAttestationDaemon.logger.error(
                "Error loading configuration from preferences: \(String(unredacted: error), privacy: .public)"
            )
            throw error
        }
    }

    static func fromPreferences(
        _ preferences: CFPreferences,
        secureConfigLoader: SecureConfigLoader
    ) throws -> CloudBoardAttestationDConfiguration {
        let decoder = CFPreferenceDecoder()
        var configuration = try decoder.decode(CloudBoardAttestationDConfiguration.self, from: preferences)
        // fallback parsing, done *before* secure config overrides things
        try self.updateFromLegacyPreferences(fromOwnConfig: &configuration)

        let secureConfig: SecureConfig
        do {
            CloudBoardAttestationDaemon.logger.info("Loading secure config from SecureConfigDB")
            secureConfig = try secureConfigLoader.load()
        } catch {
            CloudBoardAttestationDaemon.logger
                .error("Error loading secure config: \(String(unredacted: error), privacy: .public)")
            throw error
        }
        try configuration.applySecureConfig(secureConfig)
        return configuration
    }

    private mutating func applySecureConfig(_ secureConfig: SecureConfig) throws {
        self._secureConfig = secureConfig
        // after setting up everything else validate
        if secureConfig.shouldEnforceAppleInfrastructureSecurityConfig {
            self.enforceSecurityConfig()
        }
    }

    mutating func enforceSecurityConfig() {
        CloudBoardAttestationDaemon.logger.debug("Enforcing security config")
        if self.useInMemoryKey {
            CloudBoardAttestationDaemon.logger.error("Overriding configuration with new value UseInMemoryKey=false")
            self.useInMemoryKey = false
        }

        if !self.cloudAttestation.enabled {
            CloudBoardAttestationDaemon.logger
                .error("Overriding configuration with new value CloudAttestation.Enabled=true")
            self.cloudAttestation.enabled = true
        }

        if !self.cloudAttestation.includeTransparencyLogInclusionProof {
            CloudBoardAttestationDaemon.logger.error(
                "Overriding configuration with new value CloudAttestation.IncludeTransparencyLogInclusionProof=true"
            )
            self.cloudAttestation.includeTransparencyLogInclusionProof = true
        }

        // Release-set infrastructure enforcement is irrelevant when transitive proof verification is enabled
        if !self.secureConfig.enableTransitiveProofVerification {
            if self.transparencyLog.proxiedReleaseDigestsOverride != nil {
                CloudBoardAttestationDaemon.logger
                    .error(
                        "Overriding configuration with new value TransparencyLog.ProxiedReleaseDigestsOverride=nil"
                    )
                self.transparencyLog.proxiedReleaseDigestsOverride = nil
            }

            if !self.enableReleaseSetValidation {
                CloudBoardAttestationDaemon.logger
                    .error("Overriding configuration with new value EnableReleaseSetValidation=true")
                self.enableReleaseSetValidation = true
            }
        }

        // Enforce minimum rack ID cache lifetime of 60 minutes in production/customer mode
        let minimumRackIdCacheLifetimeMinutes = 60
        if self.rackIdCacheLifetime < minimumRackIdCacheLifetimeMinutes {
            let oldValue = self.rackIdCacheLifetime
            CloudBoardAttestationDaemon.logger.error(
                "Overriding configuration with new value RackIdCacheLifetime=\(minimumRackIdCacheLifetimeMinutes) minutes (was \(oldValue) minutes)"
            )
            self.rackIdCacheLifetime = minimumRackIdCacheLifetimeMinutes
        }
    }
}

extension CloudBoardAttestationDConfiguration {
    struct CloudAttestationConfiguration: Codable, Hashable {
        enum CodingKeys: String, CodingKey {
            // Determines whether we provide a real CloudAttestation-provided attestation bundle or a fake attestation
            // bundle that just contains the public key
            case _enabled = "Enabled"
            // Enables inclusion of a transparency inclusion proof in the attestation bundle
            case _includeTransparencyLogInclusionProof = "IncludeTransparencyLogInclusionProof"
            case _attestationRetryConfiguration = "AttestationRetryConfiguration"
        }

        private var _enabled: Bool?
        private var _includeTransparencyLogInclusionProof: Bool?
        private var _attestationRetryConfiguration: RetryConfiguration?

        /// If true, CloudAttestation is used to attest node keys and create attestation bundles. Otherwise, a fake
        /// attestation bundle only containing the public node key in OHTTP key configuration encoding is generated.
        var enabled: Bool {
            get { self._enabled ?? true }
            set { self._enabled = newValue }
        }

        /// If true, an transparency log inclusion proof is fetched from the Transparency Service and included in the
        /// attestation bundle
        var includeTransparencyLogInclusionProof: Bool {
            get { self._includeTransparencyLogInclusionProof ?? false }
            set { self._includeTransparencyLogInclusionProof = newValue }
        }

        /// Configuration of node key attestation generation retries.
        /// See individual fields for documentation.
        var attestationRetryConfiguration: RetryConfiguration {
            self._attestationRetryConfiguration ?? .init()
        }

        init(
            enabled: Bool = true,
            includeTransparencyLogInclusionProof: Bool = false,
            attestationRetryConfiguration: RetryConfiguration? = nil
        ) {
            self._enabled = enabled
            self._includeTransparencyLogInclusionProof = includeTransparencyLogInclusionProof
            self._attestationRetryConfiguration = attestationRetryConfiguration
        }
    }
}

extension CloudBoardAttestationDConfiguration {
    struct TransparencyLogConfiguration: Codable, Hashable {
        enum CodingKeys: String, CodingKey {
            case _transparencyLogRetryConfiguration = "TransparencyLogRetryConfiguration"
            case _releaseDigestPollingIntervalMintues = "ReleaseDigestPollingIntervalMintues"
            /// Jitter in percent of the poll period
            case _pollingIntervalJitter = "PollingIntervalJitter"
            case _transparencyLogMetadataApplications = "TransparencyLogMetadataApplications"
            case proxiedReleaseDigestsOverride = "ProxiedReleaseDigestsOverride"
            case _releaseDigestExpiryGracePeriodMinutes = "ReleaseDigestExpiryGracePeriod"
        }

        private var _transparencyLogRetryConfiguration: RetryConfiguration?
        private var _releaseDigestPollingIntervalMintues: Int?
        private var _pollingIntervalJitter: Double?
        private var _transparencyLogMetadataApplications: [String]?
        private var _releaseDigestExpiryGracePeriodMinutes: Int?

        /// Configuration of release digest fetch from transparency log retries.
        /// See individual fields for documentation.
        var transparencyLogRetryConfiguration: RetryConfiguration {
            self._transparencyLogRetryConfiguration ?? .init()
        }

        public var releaseDigestPollingIntervalMintues: Duration {
            self._releaseDigestPollingIntervalMintues.map { .minutes($0) } ?? .minutes(5)
        }

        var pollingIntervalJitter: Double {
            get { self._pollingIntervalJitter ?? 20 }
            set { self._pollingIntervalJitter = newValue }
        }

        var transparencyLogMetadataApplications: [String] {
            get { self._transparencyLogMetadataApplications ?? [] }
            set { self._transparencyLogMetadataApplications = newValue }
        }

        /// List of compute node release digests that the node will proxy requests for. This will override the set of
        /// release digests pushed to the node via control plane. Only supported with a non-prod security configuration.
        var proxiedReleaseDigestsOverride: [String]?

        /// Additional grace period in minutes we add on top of the key expiry
        /// to filter out release digests which are going to expire before the attestation key
        var releaseDigestExpiryGracePeriodMinutes: TimeAmount {
            self._releaseDigestExpiryGracePeriodMinutes.map { .minutes(Int64($0)) } ?? .minutes(60)
        }

        init(
            transparencyLogRetryConfiguration: RetryConfiguration? = nil,
            releaseDigestPollingIntervalMinutes: Int? = nil,
            pollingIntervalJitter: Double? = nil,
            proxiedReleaseDigestsOverride: [String]? = nil,
            releaseDigestExpiryGracePeriodMinutes: Int? = nil
        ) {
            self._transparencyLogRetryConfiguration = transparencyLogRetryConfiguration
            self._releaseDigestPollingIntervalMintues = releaseDigestPollingIntervalMinutes
            self._pollingIntervalJitter = pollingIntervalJitter
            self.proxiedReleaseDigestsOverride = proxiedReleaseDigestsOverride
            self._releaseDigestExpiryGracePeriodMinutes = releaseDigestExpiryGracePeriodMinutes
        }
    }
}

extension CloudBoardAttestationDConfiguration {
    struct RetryConfiguration: Codable, Hashable {
        enum CodingKeys: String, CodingKey {
            case _initialDelaySeconds = "InitialDelaySeconds"
            case _multiplier = "Multiplier"
            case _maxDelaySeconds = "MaxDelaySeconds"
            case jitter = "Jitter"
            case _perRetryTimeoutSeconds = "PerRetryTimeoutSeconds"
            case _timeoutSeconds = "TimeoutSeconds"
        }

        private var _initialDelaySeconds: Int64?
        private var _multiplier: Double?
        private var _maxDelaySeconds: Int64?
        private var _perRetryTimeoutSeconds: Int64?
        private var _timeoutSeconds: Int64?

        /// Initial delay between retries
        var initialDelay: Duration { self._initialDelaySeconds.map { .seconds($0) } ?? .seconds(1) }
        /// Multiplier for exponential backoff between retries, starting from initial delay
        var multiplier: Double { self._multiplier ?? 1.6 }
        /// Maximum delay between retries
        var maxDelay: Duration { self._maxDelaySeconds.map { .seconds($0) } ?? .minutes(5) }
        /// Jitter in percent
        var jitter: Double?
        // Per-retry timeout
        var perRetryTimeout: Duration? { self._perRetryTimeoutSeconds.map { .seconds($0) } }
        /// Overall timeout after which no new retry is attempted
        var timeout: Duration? {
            get { self._timeoutSeconds.map { .seconds($0) } }
            set { self._timeoutSeconds = newValue?.components.seconds }
        }

        init(
            initialDelay: Duration? = nil,
            multiplier: Double? = nil,
            maxDelay: Duration? = nil,
            jitter: Double? = nil,
            perRetryTimeout: Duration? = nil,
            timeout: Duration? = nil
        ) {
            self._initialDelaySeconds = initialDelay?.components.seconds
            self._multiplier = multiplier
            self._maxDelaySeconds = maxDelay?.components.seconds
            self.jitter = jitter
            self._perRetryTimeoutSeconds = perRetryTimeout?.components.seconds
            self._timeoutSeconds = timeout?.components.seconds
        }
    }
}

extension Duration {
    static func minutes(_ minutes: Int) -> Duration {
        .init(secondsComponent: Int64(minutes * 60), attosecondsComponent: 0)
    }
}

// Just enough of CBJobHelperConfiguration to pull out parts that moved into the AttestationDaemon config
extension CloudBoardAttestationDConfiguration {
    /// Check settings that might be controlled from some other config setting as a fallback.
    /// If no concrete value was provided from the attestation daemon's own config,
    /// and a value is present in the fallback config set that.
    /// If both values are defined validate they match, if not this is a fatal error
    static func updateFromLegacyPreferences(
        fromOwnConfig: inout CloudBoardAttestationDConfiguration
    ) throws {
        let domain = "com.apple.cloudos.cb_jobhelper"
        CloudBoardAttestationDaemon.logger.info(
            "Checking for fallback configuration from preferences \(domain, privacy: .public)"
        )
        let preferences = CFPreferences(domain: domain)
        let decoder = CFPreferenceDecoder()
        do {
            let legacyConfig = try decoder.decode(CBJobHelperConfigurationShim.self, from: preferences)
            let legacyValue = legacyConfig._proxyConfiguration?.enableReleaseSetValidation
            if let legacyValue {
                if let fromOwn = fromOwnConfig._enableReleaseSetValidation {
                    if fromOwn != legacyValue {
                        fatalError(
                            "EnableReleaseSetValidation configuration mismatch. From own config: \(fromOwn), From preferences: \(legacyValue)"
                        )
                    }
                } else {
                    CloudBoardAttestationDaemon.logger
                        .notice(
                            "EnableReleaseSetValidation was set to \(legacyValue) based on \(domain) confgi fallback"
                        )
                    fromOwnConfig._enableReleaseSetValidation = legacyValue
                }
            }
        } catch {
            CloudBoardAttestationDaemon.logger.error(
                "Error loading fallback \(domain) configuration from preferences: \(String(unredacted: error), privacy: .public)"
            )
            throw error
        }
    }

    // This is the minimal snippet of code needed to load what we need from the CBJobHelper config
    // Deliberately keeping the same name as a prefix so it will show up in searches
    private struct CBJobHelperConfigurationShim: Codable, Hashable {
        enum CodingKeys: String, CodingKey {
            case _proxyConfiguration = "ProxyConfiguration"
        }

        var _proxyConfiguration: ProxyConfiguration?

        struct ProxyConfiguration: Codable, Hashable, Sendable {
            enum CodingKeys: String, CodingKey {
                case enableReleaseSetValidation = "EnableReleaseSetValidation"
            }

            // Enable release set validation within a proxy. If this is true, compute nodes must run a release
            // associated
            // with the proxy attestation. This must be enforced when running with a prod security config policy.
            var enableReleaseSetValidation: Bool
        }
    }
}
