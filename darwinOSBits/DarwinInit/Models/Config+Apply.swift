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
//  Config+Apply.swift
//  darwinOSBits
//
//
import Foundation
import System // FIXME: remove later

import FeatureFlags
import FeatureFlagsSupport
import libnarrativecert

internal import DarwinInitBridging

extension Config {

    /// An critical error will stop the application of the Config.
    enum CriticalError: Swift.Error {
        /// Executing a script in the start section failed.
        case startupScriptFailed(String)
    }
}

extension Config.CriticalError: CustomStringConvertible {

    var description: String {
        switch self {
        case .startupScriptFailed(let script):
            return "start script failed (\(script))"
        }
    }
}

extension Config {
    protocol Error {
        var code: Int { get }
        var description: String { get }
    }
}

extension Config {

    func apply(on computer: any Computer, env: Globals, reporter: ErrorReporter) async throws(CriticalError) -> Self {
        logger.info("Applying darwin-init configuration...")

        var result = Config()

        // If we made it to apply then we passed validation
        // There is  nothing to apply for these keys, but set to avoid false failure
        result.authentication = authentication
        result.configSecurityPolicy = configSecurityPolicy
        result.meta = meta
        result.origin = origin

        // Execute the startup scripts. This must run before anything else so that
        // we could run critical init commands, whose failure should bail the rest
        // of the config apply
        if let start {
            result.start = try start.apply(on: computer)
        }

        // Configure logging settings early so that client can see all info
        // in future logs for debugging
        if let log {
            result.log = log.apply(on: computer)
        }

        result.analytics = Self.Analytics.apply(config: analytics, on: computer, reporter: reporter)

        // Configure the firewall
        let firewallInstaller = FirewallInstaller(computer: computer)

        // We need to set preference for the MTU of the uplink before
        // sending out the `firewall.installed` notification.
        if let network {
            result.network = network.setupFirewall(installer: firewallInstaller, reporter: reporter)
        }

        // Send a notification if there was no error during the
        // installation, i.e. it either succeeded or there was
        // nothing to do
        if firewallInstaller.lastError == nil {
            firewallInstaller.sendFirewallRulesInstalledEvent()
            logger.info("Sent notification com.apple.darwininit.firewall.installed")
        }

        // Configure tailspins
        if let tailspin {
            result.tailspin = apply(tailspin: tailspin)
        }

        // Set the device name and usage label
        if let identification {
            result.identification = await identification.apply(on: computer)
        }

        // Install the Apple Root CA certificate
        if let caRoots {
            result.caRoots = caRoots.apply(on: computer)
        }

        // NOTE: Apply any user configuration before enabling SSH so that any
        // provided credentials will be usable as soon as sshd is listening for
        // connections.
        if let users {
            let manager = UserManager(computer: computer)

            result.users = users.map { (name, info) in
                UserManager.User(from: info, name: name)
            }.compactMap { (user: UserManager.User) in
                if manager.setup(user: user) {
                    return user
                } else {
                    // TODO: make UserManager expose concret errors so this becomes more useful
                    if let userConfig = users[user.name] {
                        let applyError = ApplyError(location: userConfig.jsonPointer, code: 1, message: "Failed to setup user")
                        reporter.report(applyError)
                    }
                    
                    return nil
                }
            }.reduce(into: [:]) { (res, user: UserManager.User) in
                res[user.name] = users[user.name]
            }
        }

        do {
            try computer.fileSystem.touch(kDInitSSHConfig)
            if let ssh {
                result.ssh = try ssh.apply(on: computer)
            }
        } catch {
            logger.error("Failed to configure SSH password authentication: \(error)")
        }

        // Issue the DCRT, which is part of the start
        if let start {
            await start.issueDCRT(result: &result.start)
        }

        // Install roots
        if let roots {
            result.roots = roots.compactMap { root in
                root.install(on: computer)
            }
        }

        // Set preferenes
        if let preferences {
            result.preferences = computer.set(preferences: preferences)
        }

        // Only apply network config if firewall was installed
        // and this is not a compute node
        if firewallInstaller.lastError == nil && !computer.isComputeNode {
            if let network {
                network.setupInterfaces(result: &result.network)
            }
        }

        if let narrative {
            result.narrative = apply(narrative: narrative)
        }

        /*
         * Do cache volumes before any cryptex work for a few reasons:
         *     1) Cache setup should almost always be much shorter than
         *        cryptex setup, and it's better to fail faster.
         *     2) Cryptex installation without a USR may load and start jobs
         *        that immediately access cache volumes.
         *     3) The cryptex cache should someday live on a volume set up here.
         */
        if let volumes {
            result.volumes = await apply(volumes: volumes)
        }

        if let diavlo {
            result.diavlo = await diavlo.apply(on: computer, auth: self.authentication)
        }

        if let cryptex {
            result.cryptex = await cryptex.apply(on: computer,
                                                 auth: self.authentication,
                                                 diavloURL: self.diavlo?.url,
                                                 env: env,
                                                 reporter: reporter)
        }

        if let featureFlags {
            result.featureFlags = featureFlags.compactMap { flag in
                flag.apply(on: computer, configSecurityPolicy: configSecurityPolicy)
            }
        }

        if let packages {
            result.packages = await packages.asyncSerialCompactMap { pkg in
                await pkg.apply(on: computer)
            }
        }

        if let finish {
            result.finish = finish.apply(on: computer, globals: env)
        }

        return result
    }

    func apply(narrative: [String: JSON]) -> [String: JSON]? {
        logger.info("Applying narrative identities configuration...")
        let client = NarrativeXPCClient()

        var result: [String: JSON] = [:]
        for (identity, options) in narrative {
            let components = identity.components(separatedBy: "-")
            guard components.count == 2,
                  isNarrativeCertSupported(domain: components[0], identityType: components[1]),
                  let narrativeDomain = NarrativeDomain(rawValue: components[0]),
                  let narrativeIdentityType = NarrativeIdentityType(rawValue: components[1]) else {
                logger.error("Narrative Identity \(identity) is not supported. Supported Identities are \(formatSupportedNarrativeIdentities())")
                continue
            }

            do {
                try client.ConfigureIdentity(narrativeDomain: narrativeDomain,
                                             narrativeIdentityType: narrativeIdentityType,
                                             options: options.dictionaryValue as? [String: String]
                )
                result[identity] = options
            } catch let err as NarrativeCertXPCClientError {
                logger.error("Error in XPCClient when configuring identity for \(identity): \(String(describing: err))")
            } catch {
                logger.error("Error when configuring identity for \(identity): \(error.localizedDescription)")
            }
        }

        return result
    }

    /// Apply the volume configuration
    func apply(volumes: [String: URL]) async -> [String: URL]? {
        var result = [String: URL]()
        if #available(macOS 16.0, iOS 19.0, *) {

            var existing = Volume.list()
            for (name, url) in volumes {
                // Fetch secret for volume. If this fails, move on
                var secret: Data
                do {
                    secret = try await WhisperSecretDetail.fetchWhisperSecret(from: url)
                } catch let error {
                    logger.error("Failed to fetch secret for volume \(name): \(error)")
                    continue
                }

                // Get/Create Volume
                var v: Volume
                if let lv = existing[name] {
                    v = lv
                    do {
                        v.keys = try CacheVolumeKeyManager(forExistingVolumeWith: v.uuid, secret: secret)
                    } catch {
                        logger.error("Unable to initialize CacheVolumeKeyManager to mount volume \(name): \(error)")
                        continue
                    }
                    existing[name] = nil
                } else {
                    do {
                        v = try Volume(createVolumeNamed: name, secret: secret)
                    } catch {
                        logger.error("Failed to create new volume \(name): \(error)")
                        continue
                    }
                }

                // Mount it
                do {
                    try await v.mount()
                    result[name] = volumes[name];
                } catch {
                    logger.error("Unable to mount volume \(v): \(error)")
                }
            }

            // Destroy any orphaned volumes
            for (_, vol) in existing {
                do {
                    vol.keys = CacheVolumeKeyManager(forOrphanedVolumeWith: vol.uuid)
                    try await vol.destroy()
                } catch {
                    logger.error("Failed to destroy volume \(vol) due to: \(error)")
                }
            }
        } else {
            logger.error("Creating cache volumes not available on this platform")
        }
        return result.isEmpty ? nil : result
    }

    func apply(tailspin: Either<Bool, Tailspin>) -> Either<Bool, Tailspin>? {
        logger.info("Applying tailspin configuration...")

        guard shim_check_tailspin() else {
            logger.error("Tailspin doesn't exist in on this OS, so we cannot handle tailspin configuration.")
            return nil
        }

        guard var config = shim_tailspin_config_create_with_default_config() else {
            logger.error("Failed to generate tailspin config.")
            return nil
        }

        defer {
            shim_tailspin_config_free(config)
        }

        // Apply the darwin init tailspin config to the tailspin_config_t object
        tailspin.apply(to: &config)

        // Apply the tailspin_config_t to the computer
        let ok = shim_tailspin_config_apply_sync(config)
        guard ok else {
            logger.error("Failed to apply tailspin configuration.")
            return nil
        }

        return tailspin
    }

}

extension UserManager.User {

    init(from user: Config.User, name: String) {
        self.name = name
        self.uid = uid_t(user.uid)
        self.gid = gid_t(user.gid)
        self.password = user.plaintextPassword
        self.isAdmin = user.admin ?? false
        self.sshAuthorizedKeys = user.sshAuthorizedKey
        self.passwordlessSudo = user.passwordlessSudo ?? false
        if let esc = user.authentication?.esc {
            self.esc = EngineeringSSHCA.Config(principals: esc.principals, groups: esc.groups)
        } else {
            self.esc = nil
        }
        if let memento = user.authentication?.memento {
            self.memento = MementoSSH.Config(users: memento.users,
                                             groups: memento.groups,
                                             ldapServer: memento.ldapServer)
        }
    }

}

// MARK: Log+Apply
extension Config.Log {

    func apply(on computer: any Computer) -> Config.Log? {
        logger.info("Applying logging configuration...")
        var result = Config.Log()

        if let privacyLevel = self.privacyLevel {
            let ok = computer.systemLog.set(privacyLevel: privacyLevel)
            guard ok else { return nil }
            result.privacyLevel = privacyLevel
        }

        if let persist = self.persist {
            let ok = computer.systemLog.set(enabled: persist)
            guard ok else { return result }
            result.persist = persist
        }

        return result
    }

}

// MARK: FeatureFlag+Apply
extension Config.FeatureFlag {
    static let configSecurityPolicyAttribute = "AllowOverrideInPRCOSSecurityPolicy"

    func apply(on computer: Computer, configSecurityPolicy: Config.SecurityPolicy?) -> Self? {
        do {
            if domain != nil {
                guard try applyDomain(configSecurityPolicy: configSecurityPolicy) else {
                    return nil
                }
            } else if attributeName != nil {
                guard try applyAttribute(configSecurityPolicy: configSecurityPolicy) else {
                    return nil
                }
            } else {
                return nil
            }
        } catch {
            logger.error("Failed to apply FeatureFlags: \(error)")
            return nil
        }

        return self
    }

    fileprivate func applyAttributePhase(_ ffConfig: FFConfiguration,_ domain: String,_ feature: String,_ currentFeaturePhase: String) throws {
        guard let featurePhase else { throw DInitFeatureFlagsError.invalidAttributeInput }

        let currentFeaturePhaseInt = ffConfig.sortValue(forPhase: currentFeaturePhase)
        let featurePhaseInt = ffConfig.sortValue(forPhase: featurePhase.rawValue)

        setFeature(ffConfig, currentFeaturePhaseInt >= featurePhaseInt, feature, domain)
    }

    fileprivate func applyAttribute(_ ffConfig: FFConfiguration,_ domain: String, _ configSecurityPolicy: Config.SecurityPolicy?) throws -> Bool {
        guard let attributeName, let attributeValue else { throw DInitFeatureFlagsError.invalidAttributeInput }

        for feature in ffConfig.features(forDomain: domain) {
            guard let featureState = ffConfig.state(forFeature: feature, domain: domain, level: .domain) else {
                continue
            }

            guard let stateAttribute = featureState.attributes[attributeName] else {
                continue
            }

            guard stateAttribute.value == attributeValue else {
                continue
            }

            guard isAllowedToSetFeature(ffConfig, feature, domain, configSecurityPolicy) else {
                logger.warning("Skipping disallowed \(feature) in domain \(domain) - check \(Self.configSecurityPolicyAttribute) attribute")
                continue
            }

            if featurePhase != nil {
                guard let currentFeaturePhase = featureState.phase else {
                    // If the feature doesn't have a phase, it only has a value
                    // It doesn't make sense to apply a phase to a value, so we just ignore it
                    continue
                }

                try applyAttributePhase(ffConfig, domain, feature, currentFeaturePhase)
            } else if let enable {
                setFeature(ffConfig, enable, feature, domain)
            } else {
                throw DInitFeatureFlagsError.invalidAttributeInput
            }
        }

        return true
    }

    fileprivate func applyAttribute(configSecurityPolicy: Config.SecurityPolicy?) throws -> Bool {
        let conf = FFConfiguration.shared
        for domain in conf.domains {
            if try !applyAttribute(conf, domain, configSecurityPolicy) {
                logger.error("Failed to apply conf to \(domain)")
                return false
            }
        }

        do {
            try conf.commitUpdates()
        } catch {
            logger.error("Failed to commit changes with error \(error).")
            return false
        }

        return true
    }

    fileprivate func setFeature(_ conf: FFConfiguration, _ enable: Bool, _ feature: String, _ domain: String) {
        if enable {
            conf.enable(feature: feature, domain: domain, level: .settings)
        } else {
            conf.disable(feature: feature, domain: domain, level: .settings)
        }
    }

    fileprivate func applyDomain(configSecurityPolicy: Config.SecurityPolicy?) throws -> Bool {
        guard let domain, let feature, let enable else { throw DInitFeatureFlagsError.invalidDomainInput }
        let conf = FFConfiguration.shared

        logger.info("Applying \(feature) feature for domain \(domain).")
        if !conf.isValidName(feature) {
            logger.error("Invalid feature name \(feature) in domain \(domain).")
            return false
        }

        guard isAllowedToSetFeature(conf, feature, domain, configSecurityPolicy) else {
            logger.error("Disallowing feature \(feature) in domain \(domain) - check \(Self.configSecurityPolicyAttribute) attribute")
            return false
        }

        setFeature(conf, enable, feature, domain)

        do {
            try conf.commitUpdates()
        } catch {
            logger.error("Failed to commit changes global changes with error \(error).")
            return false
        }
        return true
    }

    func isAllowedToSetFeature(_ conf: FFConfiguration, _ feature: String, _ domain: String, _ configSecurityPolicy: Config.SecurityPolicy?) -> Bool {
        guard let policy = configSecurityPolicy?.policy, policy != ConfigSecurityPolicy.none.rawValue else {
            return true
        }

        guard let state = conf.state(forFeature: feature, domain: domain, level: .domain) else {
            return false
        }
        guard let attribute = state.attributes[Self.configSecurityPolicyAttribute] else {
            return false
        }
        return attribute.value.split(separator: ",").contains { $0 == policy }
    }
}

// MARK: Analytics+Apply
extension Config.Analytics {
    struct AnalyticsApplyError: Config.Error {
        enum ErrorKind: Int {
            case failedToReadDefaults = 1
        }
        
        let kind: ErrorKind
        var code: Int { kind.rawValue }
        
        var description: String {
            switch kind {
            case .failedToReadDefaults:
                return "Failed to read CrashReporter/DiagnosticMessagesHistory defaults"
            }
        }
    }

    static func applySubmit(config: Self?, on computer: any Computer, reporter: ErrorReporter) -> Bool? {
        let defaults = UserDefaults(suiteName: "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist")

        guard let defaults else {
            let error = AnalyticsApplyError(kind: .failedToReadDefaults)
            let location: JSONPointer
            if let config {
                location = config.$submit.jsonPointer
            } else {
                location = JSONPointer(components: [.init(unescaped: "default")])
            }

            reporter.report(error, at: location)
            return false
        }

        let submit = config?.submit
        defaults.set(submit ?? true, forKey: "AutoSubmit")

        if config == nil {
            return nil
        }

        return submit
    }

    static func apply(config: Self?, on computer: any Computer, reporter: ErrorReporter) -> Config.Analytics? {
        guard computer.platform == .macOS else {
            return nil
        }
        var coredumpsResult: Either<Bool, [String]>?

        let submitResult = applySubmit(config: config, on: computer, reporter: reporter)

        if let userCoredumps = config?.coredumps {
            coredumpsResult = userCoredumps.apply(computer: computer)
        }

        if config == nil {
            return nil
        }

        return Config.Analytics(submit: submitResult, coredumps: coredumpsResult)
    }
}

private func setUCoreDump(_ value: Bool) throws {
    let size = MemoryLayout<UInt32>.size
    var newValue: UInt32 = value ? 1 : 0
    try withUnsafeMutableBytes(of: &newValue) { (rawBufferPointer: UnsafeMutableRawBufferPointer) in

        let rawPointer = rawBufferPointer.baseAddress!

        guard Darwin.sysctlbyname("kern.ucoredump", nil, nil, rawPointer, size) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? POSIXErrorCode.EIO)
        }
    }
}

// MARK: Analytics+Apply
extension Either where A == Bool, B == [String] {
    func apply(computer: any Computer) -> Either<Bool, [String]>? {
        let enable: Bool
        var config: [String]

        if !computer.allowsInternalSecurityPolicies {
            // Feature is restricted to internalOS only for now
            return nil
        }

        switch self {
        case .left(let enabled):
            enable = enabled
            config = [String].init()
        case .right(let cfg):
            enable = true
            config = cfg
        }

        do {
            try setUCoreDump(enable)
        } catch {
            logger.error("kern.ucoredump failed with error: \(error)");
            return nil
        }

        if !config.isEmpty {
            guard let suite = UserDefaults(suiteName: "com.apple.CrashReporter") else {
                logger.error("Failed to find CrashReporter suite")
                return nil
            }
            suite.set(config, forKey: "coreFileProcessList")
        }
        return self
    }
}

// MARK: Network+Apply
extension Config.Network {
    struct NetworkApplyError: Config.Error {
        enum ErrorKind: Int {
            case failedToInstallFirewallRules = 1
        }
        
        let kind: ErrorKind
        var code: Int { kind.rawValue }
        
        var description: String {
            switch kind {
            case .failedToInstallFirewallRules:
                return "Failed to install firewall rules"
            }
        }
    }

    func setupFirewall(installer: FirewallInstaller, reporter: ErrorReporter) -> Config.Network? {
        var result = Config.Network()

        // We need to set preference for the MTU of the uplink before
        // sending out the `firewall.installed` notification.
        if let uplinkMtu {
            let raw = Int(uplinkMtu)
            logger.info("Setting uplink MTU to \(raw)")
            let res = Network.setUplinkMTU(raw)
            if res == raw {
                result.uplinkMtu = uplinkMtu
            }
        }

        do {
            if let firewall {
                try installer.installRules(firewall.rules)
                result.firewall = Self.Firewall(rules: firewall.rules)
            }
        } catch {
            logger.error("Unable to install firewall rules: \(error)")
            let e = NetworkApplyError(kind: .failedToInstallFirewallRules)
            reporter.report(e, at: $firewall.jsonPointer)
        }

        return result
    }

    func setupInterfaces(result out: inout Self?) {
        logger.info("Applying network configuration...")

        var result: [String: JSON] = [:]

        guard let interfaces else { return }

        for (interface, options) in interfaces {
            let dict = options.dictionaryValue
            let ok = NetworkConfig.setConfig(retryLimit: 5,
                                             config: dict,
                                             interface: interface)

            guard ok else { continue }

            let have = NetworkConfig.getConfig(interface: interface, config: dict)

            if CFEqual(dict ?? kCFNull, have ?? kCFNull) {
                result[interface] = options
            }
        }

        if out == nil {
            out = Self()
        }
        out?.interfaces = result

    }
}

// MARK: Cryptex+Apply
extension Config.Cryptex {
    struct CryptexApplyError: Config.Error {
        enum ErrorKind: Int {
            case failedToSetBandwidthLimit = 1
            case failedToDepsolveCryptexes
            case failedToDownloadCryptex
            case failedToPersonalizeCryptex
            case failedToInstallCryptex
        }
        
        let kind: ErrorKind
        var code: Int { kind.rawValue }
        
        var description: String {
            switch kind {
            case .failedToSetBandwidthLimit:
                return "Failed to set bandwidth limit for Mellanox interface. Will NOT download cryptexes."
            case .failedToDepsolveCryptexes:
                return "Failed to depsolve cryptexes"
            case .failedToDownloadCryptex:
                return "Failed to download cryptex"
            case .failedToPersonalizeCryptex:
                return "Failed to personalize cryptex"
            case .failedToInstallCryptex:
                return "Failed to install cryptex"
            }
        }
    }

    func apply(on computer: Computer,
               auth: Config.Authentication?,
               diavloURL: URL?,
               env: Globals,
               reporter: ErrorReporter) async -> Self? {

        var result = Self()
        
        if self.lock != nil {
            result.lock = env.lockCryptexes
        }

        var maxCacheSize: Int? = nil

        var bandwithLimit = false
        if let network {
            if let limit = network.bandwidthLimit {
                bandwithLimit = true
                let ok = DarwinInit.Network.setUplinkBandwidthLimit(bandwidthLimit: UInt64(limit))
                guard ok else {
                    let e = CryptexApplyError(kind: .failedToSetBandwidthLimit)
                    reporter.report(e, at: network.$bandwidthLimit.jsonPointer)
                
                    return nil
                }
            }

            result.network = network
        }

        if let cache {
            result.cache = cache
            if cache.retainPreviouslyCachedCryptexesUnsafely != nil {
                result.cache?.retainPreviouslyCachedCryptexesUnsafely = env.retainCachedCryptexes
            }
            if let cacheSize = cache.cacheMaxSize {
                maxCacheSize = Int(cacheSize)
            }
            // If we made it this far, then verifying the cryptex cache invalidation ID succeeded
            result.cache?.invalidationId = env.cryptexCacheInvalidationId
        }

        // If there are no cryptexes to install, we are done
        // Note that we do the check here and not earlier so
        // that retainPreviouslyCachedCryptexesUnsafely get set
        // correctly in the cache block above
        guard let cryptexes else { return result }

        let manager = CryptexManager(from: self, auth: auth, diavlo: diavloURL)
        
        // TODO: move this over to CryptexManager
        let ordered: [String]
        do {
            ordered = try depsolvCryptexes()
        } catch {
            logger.error("Failed to depsolve cryptexes: \(error)")
            let e = CryptexApplyError(kind: .failedToDepsolveCryptexes)
            
            reporter.report(e, at: $cryptexes.jsonPointer)
            
            return nil
        }

        logger.info("Installing cryptexes: \(ordered)")

        let items: [CryptexManager.CryptexConfig] = ordered.compactMap { id in
            guard let cryptex = cryptexes[id] else { return nil }
            return CryptexManager.CryptexConfig(from: cryptex, identifier: id)
        }

        let personalized: [CryptexManager.PersonalizedCryptex]

        let cacheDelegate = CryptexCacheDelegate()
        if let cryptexCache = CryptexCache(at: CryptexCache.defaultCacheDirectoryPath,
                                           delegate: cacheDelegate,
                                           maxTotalSize: maxCacheSize) {

            personalized = await items.asyncSerialCompactMap { item in
                let theCache: CryptexCache?
                if item.isCacheable {
                    theCache = cryptexCache
                } else {
                    Logger.cryptexcache.log("[\(item.identifier)] Not cacheable")
                    theCache = nil
                }

				let personalizedCryptex = await manager.get(cryptex: item, using: theCache)
                if personalizedCryptex == nil {
                    // TODO: this is not so useful right now as it could caused by
                    // a variety of unerlying errors.
                    // CryptexManager should expose the error out for better error reporting
                    let e = CryptexApplyError(kind: .failedToPersonalizeCryptex)
                    if let cryptex = cryptexes[item.identifier] {
                        reporter.report(e, at: cryptex.jsonPointer)
                    }
                }
                return personalizedCryptex
            }

        } else {
            logger.error("Failed to initialize CryptexCache; proceeding without caching")
            personalized = await items.asyncSerialCompactMap { item in
                let personalizedCryptex = await manager.get(cryptex: item)
                if personalizedCryptex == nil {
                    // TODO: this is not so useful right now as it could caused by
                    // a variety of unerlying errors.
                    // CryptexManager should expose the error out for better error reporting
                    let e = CryptexApplyError(kind: .failedToPersonalizeCryptex)
                    if let cryptex = cryptexes[item.identifier] {
                        reporter.report(e, at: cryptex.jsonPointer)
                    }
                }
                return personalizedCryptex
            }
        }

        let applied = personalized.compactMap { item in
            if item.install(limitLoadToREM: env.bootingIntoREM) {
                return item.config
            } else {
                let e = CryptexApplyError(kind: .failedToInstallCryptex)
                reporter.report(e, at: cryptexes[item.config.identifier]!.jsonPointer)

                return nil
            }
        }

        // Get the original cryptex configuration for all cryptexes that
        // have been applied
        result.cryptexes = applied.reduce(into: [:], { result, cfg in
            result[cfg.identifier] = cryptexes[cfg.identifier]
        })

        // Reset the bandwidth limit on the Mellanox interface after cryptex downloads
        // If we fail to reset the bandwidth limit, we consider this an apply failure
        if bandwithLimit {
            let ok = DarwinInit.Network.unsetUplinkBandwidthLimit()
            if !ok {
                logger.error("Failed to unset bandwith limit.")
                result.network?.bandwidthLimit = nil
            }
        }

        return result.isEmpty ? nil : result
    }
}

// MARK: Start+Apply
extension Config.Start {
    func apply(on computer: Computer) throws(Config.CriticalError) -> Config.Start? {
        var result = Config.Start()
        if let scripts {
            for (i, cmd) in scripts.enumerated() {
                logger.info("Executing startup command \(i+1): \(cmd)")

                guard computer.run(shell: "/bin/bash", command: cmd) else {
                    logger.error("Startup command \(i+1) failed.")
                    throw Config.CriticalError.startupScriptFailed(cmd)
                }
            }
            result.scripts = scripts
        }

        if let perfdata {
            let ok = PerformanceData.writeStats(to: "/var/tmp/bootperf.pdj")
            if ok {
                result.perfdata = perfdata
            }
        }
        return result
    }

    func issueDCRT(result: inout Config.Start?) async {
        guard let issueDCRT else {
            return
        }

        if issueDCRT {
            do {
                try await DCRT.issue()
            } catch let error as NSError {
                logger.error("Failed to issue DCRT: \(error, privacy: .public)")
                logger.error("DCRT root error: \(error.rootError(), privacy: .public)")
                // Note: early return, not setting the value
                return
            }

            if result == nil {
                result = Config.Start()
            }
            result?.issueDCRT = issueDCRT
        }
    }
}

// MARK: Identification+Apply
extension Config.Identification {

    func apply(on computer: Computer) async -> Config.Identification? {
        var result = Config.Identification()

        if let computerName {
            do {
                try await computer.set(computerName: computerName)
                result.computerName = computerName
            } catch {
                logger.error("Failed to set computerName: \(error)")
            }
        }

        if let hostname {
            do {
                try await computer.set(hostName: hostname)
                result.hostname = hostname
            } catch {
                logger.error("Failed to set hostName: \(error)")
            }
        }

        if let localHostname {
            do {
                try await computer.set(localHostName: localHostname)
                result.localHostname = localHostname
            } catch {
                logger.error("Failed to set localHostName: \(error)")
            }
        }

        if let usageLabel = usageLabel {
            if UsageLabel.setUsageLabel(to: usageLabel) && computer.setAutomatedDeviceGroup(to: usageLabel) {
                result.usageLabel = usageLabel
            } else {
                logger.error("Failed to set \(kUsageLabelKey, privacy: .public).")
            }
        }

        return result
    }
}

// MARK: CARoots+Apply
extension Config.CARoots {
    func apply(on computer: Computer) -> Config.CARoots? {
        if appleCorporateRoot == true {
            guard CorporateRoot.apply() else {
                return nil
            }
        }

        return Config.CARoots(appleCorporateRoot: self.appleCorporateRoot)
    }
}

// MARK: SSH+Apply
extension Config.SSH {

    func apply(on computer: Computer) throws -> Self? {
       var result = Self()

        if let pwauth {
            let config = if pwauth {
                kDInitSSHConfigPWAuthEnabled
            } else {
                kDInitSSHConfigPWAuthDisabled
            }

            try computer.fileSystem.append(text: config,
                                           to: kDInitSSHConfig)
            result.pwauth = pwauth
        }

        result.enabled = enabled
        if enabled == true {
            if computer.platform == .macOS {
                let sshPlist = "/System/Library/LaunchDaemons/ssh.plist"
                let managementSSHPlist = "/System/Library/LaunchDaemons/com.apple.ssh.management.plist"
                let sshCmd = "/bin/launchctl load -F -w \(sshPlist)"
                let managementSSHCmd = "/bin/launchctl load -F -w \(managementSSHPlist)"

                let sshResult = computer.run(shell: nil, command: sshCmd)
                let managementResult = computer.run(shell: nil, command: managementSSHCmd)
                result.enabled = sshResult && managementResult
            } else {
                let plist = "/AppleInternal/Library/LaunchDaemons/com.apple.internal.darwin.ssh.plist"
                // launchctl is mastered out of customer embedded darwinOS
                // So, do nothing but report successful application in the result config
                if !computer.osVariantHasInternalContent {
                    result.enabled = enabled
                } else {
                    let cmd = "/bin/launchctl load -F -w \(plist)"
                    result.enabled = computer.run(shell: nil, command: cmd)
                }
            }
        }

        return result
    }
}

// MARK: Root+Apply
extension Config.Root {

    func install(on computer: Computer) -> Self? {
        logger.info("Installing \(root) ...")

        if let waitForVolume {
            guard FilePath(waitForVolume).exists(withTimeout: 20) else {
                logger.error("Wait for volume \(waitForVolume) failed")
                return nil
            }
        }

        if let preflight {
            let ok = computer.run(shell: "/bin/bash",
                                  command: preflight)
            guard ok else {
                logger.error("Preflight failed")
                return nil
            }
        }

        let command = "/usr/bin/darwinup install \(root)"
        let ok = computer.run(shell: nil, command: command)
        guard ok else {
            logger.error("Root installed failed")
            return nil
        }

        if let postflight {
            let ok = computer.run(shell: "/bin/bash", command: postflight)
            guard ok else {
                return nil
            }
        }

        return self
    }
}

// MARK: Diavlo+Apply

extension Config.Diavlo {

    func fetchCertsFromServer(url: String, auth: Config.Authentication?) async throws -> Bool {
        logger.info("Applying diavlo configuration...")

        let rootCertificates: DiavloCertList
        if let _rootCertificate = self.rootCertificate {
            logger.debug("Using diavlo root certificate provided in darwin-init config")
            let diavloCert = DiavloCert(cert: _rootCertificate.rawValue)
            rootCertificates = DiavloCertList(certificates: [diavloCert])
        } else {
            logger.debug("Fetching diavlo root certificate from server at \(url)")
            rootCertificates = try await DiavloClient.fetchRootCertificate(server: url)
        }

        return rootCertificates
            .certificates
            .map {
                LibCryptex.trust(
                    rootCertificate: $0.cert,
                    usingAppleConnect: auth?.appleConnect ?? false,
                    signingURL: url)
            }
            .reduce(false) { partialResult, incrementalTrustResult in
                partialResult || incrementalTrustResult
            }
    }

    func apply(on computer: Computer, auth: Config.Authentication?) async -> Self? {
        var success = false
        do {
            let server = self.url.map(\.absoluteString) ?? kDiavloServerLocation
            success = try await self.fetchCertsFromServer(url: server, auth: auth)
        } catch {
            logger.error("Application of diavlo config error \(error).")
        }

        return success ? self : nil
    }

}

// MARK: Package+Apply
extension Config.Package {

    func apply(on computer: any Computer) async -> Self? {
        guard computer.platform == .macOS else {
            logger.fault("Package Install has no effect because it is not available on this platform")
            return nil
        }

#if os(macOS)
        logger.info("Applying package configuration...")

        guard let packagePath = await Network.downloadItem(at: url) else {
            return nil
        }

        let installer = PackageInstaller(url: URL(fileURLWithPath: "\(packagePath)"))
        return installer.install() ? self : nil
#else
        return nil
#endif
    }

}


// MARK: Finish+Apply
extension Config.Finish {

    static func print(logText: String) -> Bool {
        logger.log("darwin-init: \(logText, privacy: .public)")
        let banner = """
==== darwin-init ==============================================================
\(logText)
===============================================================================\n
"""
        do {
            try nothingOrErrno(retryOnInterrupt: true) {
                fputs(banner.cString(using: .utf8), stderr)
            }.get()
            return true
        } catch {
            logger.error("Failed to write to stderr: \(error.localizedDescription)")
            return false
        }
    }

    func apply(on computer: Computer, globals: Globals) -> Self? {
        var result = Self()

        if let scripts {
            for (i, cmd) in scripts.enumerated() {
                logger.info("Executing finish command \(i+1): \(cmd)")

                guard computer.run(shell: "/bin/bash", command: cmd) else {
                    logger.error("Finish command \(i+1) failed.")
                    return nil
                }
            }
            result.scripts = scripts
        }

        if reboot != nil {
            result.reboot = globals.rebootAfterSetup
        }

        if userspaceReboot != nil {
            result.userspaceReboot = globals.USRAfterSetup
        }

        if onFailure != nil {
            result.onFailure = onFailure
        }

        if let message {
            if Self.print(logText: message) {
                result.message = message
            }
        }

        return result
    }
}

// MARK: Tailspin+Apply
extension Either where A == Bool, B == Config.Tailspin {
    typealias Tailspin = Config.Tailspin

    func apply(to tailspin: inout tailspin_config_t) {
        let enable: Bool
        var config: Tailspin?

        switch self {
        case .left(let enabled):
            enable = enabled
        case .right(let cfg):
            enable = true
            config = cfg
        }

        shim_tailspin_enabled_set(tailspin, enable)
        if let config {
            config.apply(tailspin_config: &tailspin)
        } else {
            logger.info("Applying default tailspin configuration.")
            shim_tailspin_buffer_size_set(tailspin, kTailspinDefaultBufferSize)
        }
    }
}

extension Config.Tailspin {

    func apply(tailspin_config: inout tailspin_config_t) {
        logger.debug("Applying custom tailspin configuration.")

        if let fullSamplingPeriodSet {
            logger.info("Applying tailspin full_sampling_period_set configuration value \(fullSamplingPeriodSet)")
            shim_tailspin_full_sampling_period_set(tailspin_config, fullSamplingPeriodSet)
        }

        if let oncoreSamplingPeriodSet {
            logger.info("Applying tailspin oncore_sampling_period_set configuration value \(oncoreSamplingPeriodSet)")
            shim_tailspin_oncore_sampling_period_set(tailspin_config, oncoreSamplingPeriodSet)
        }

        if let bufferSizeSet {
            logger.info("Applying tailspin buffer_size_set configuration value \(bufferSizeSet)")
            shim_tailspin_buffer_size_set(tailspin_config, Int(bufferSizeSet))
        }

        guard let classConfigs else {
            return
        }

        for config in classConfigs {
            logger.info("Setting tailspin kdbg_filter_class \(config.classNumber) to \(config.classEnabled)")
            shim_tailspin_kdbg_filter_class_set(tailspin_config, config.classNumber, config.classEnabled)

            if let subclass = config.subclassConfigs {
                for subconfig in subclass {
                    logger.info("Setting tailspin kdbg_filter_subclass for class:\(config.classNumber), subclass:\(subconfig.subclassNumber) to \(subconfig.subclassEnabled)")
                    shim_tailspin_kdbg_filter_subclass_set(tailspin_config,
                                                           config.classNumber,
                                                           subconfig.subclassNumber,
                                                           subconfig.subclassEnabled)
                }
            }
        }
    }

}
