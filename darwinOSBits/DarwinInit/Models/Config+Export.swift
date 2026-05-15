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
//  Config+Export.swift
//  darwinOSBits
//
//

import Foundation

/// Exports Config (V2 schema) back to V1 schema JSON format.
///
/// Uses two patterns:
/// 1. Direct export: Converts V2 field values directly to V1 format
/// 2. Filtered export: Preserves V1 source structure by filtering through V2 state
///    (used when V1/V2 have structural differences or V1 has fields not in V2)
struct VersionOneExporter {

    private struct DictWriter<Key: CodingKey> {
        var dict: [String: JSON] = [:]

        subscript(key: Key) -> JSON? {
            get {
                return dict[key.stringValue]
            }
            set {
                dict[key.stringValue] = newValue
            }
        }

        var json: JSON {
            return .dictionary(dict)
        }
    }

    enum Error: Swift.Error {
        case noOrigin
        case originNotV1
    }

    let config: Config
    let converter: Converter
    private var result: DictWriter<Config.VersionOneKeys>

    init(config: Config) throws {
        guard let origin = config.origin else {
            throw Error.noOrigin
        }

        guard origin.isV1 else {
            throw Error.originNotV1
        }

        self.config = config
        self.converter = JSONConverter(config: origin.source)
        self.result = DictWriter<Config.VersionOneKeys>()
    }

    /// Exports the config to V1 schema JSON format by filtering the original V1 source
    /// through the current V2 state. Requires config.origin to be present.
    mutating func export() throws -> JSON {
        if let caRoots = config.caRoots {
            try export(caRoots: caRoots)
        }

        if let cryptex = config.cryptex {
            try export(cryptex: cryptex)
        }

        if let policy = config.configSecurityPolicy {
            try export(policy: policy)
        }

        if let diavlo = config.diavlo {
            try export(diavlo: diavlo)
        }

        if let featureFlags = config.featureFlags {
            try export(featureFlags: featureFlags)
        }

        if let finish = config.finish {
            try export(finish: finish)
        }

        if let identification = config.identification {
            try export(identification: identification)
        }

        if let log = config.log {
            try export(log: log)
        }

        if let meta = config.meta {
            try export(meta: meta)
        }

        if let network = config.network {
            try export(network: network)
        }

        if let analytics = config.analytics {
            try export(analytics: analytics)
        }

        if let packages = config.packages {
            try export(packages: packages)
        }

        if let preferences = config.preferences {
            try export(preferences: preferences)
        }

        if let roots = config.roots {
            try export(roots: roots)
        }

        if let secureConfig = config.secureConfig {
            result[.secureConfigParameters] = .dictionary(secureConfig)
        }

        if let ssh = config.ssh {
            try export(ssh: ssh)
        }

        if let start = config.start {
            try export(start: start)
        }

        let root = try converter.container(keyedBy: Config.VersionOneKeys.self)
        if let critical = try root.objCBool(forKey: .preInitCritical).wrappedValue {
            result[.preInitCritical] = .bool(critical)
        }

        if let tailspin = config.tailspin {
            try export(tailspin: tailspin)
        }

        if let users = config.users {
            try export(users: users)
        }

        if let narrative = config.narrative {
            try export(narrative: narrative)
        }

        if let volumes = config.volumes {
            try export(volumes: volumes)
        }

        return .dictionary(result.dict)
    }

    private mutating func export(caRoots: Config.CARoots) throws {
        if let appleCorporateRoot = caRoots.appleCorporateRoot {
            var value = DictWriter<Config.CARoots.VersionOneKeys>()
            value[.appleCorpRoot] = .bool(appleCorporateRoot)
            result[.caRoots] = value.json
        }
    }

    private mutating func export(policy: Config.SecurityPolicy) throws {
        if let policyString = policy.policy {
            result[.configSecurityPolicy] = .string(policyString)
        }
        if let version = policy.version {
            result[.configSecurityPolicyVersion] = .int(Int128(version))
        }
    }

    private mutating func export(preferences: [String: [String: [String: JSON]]]) throws {
        let conv = self.converter
        let root = try conv.container(keyedBy: Config.VersionOneKeys.self)

        guard let prefs = try root.indexedContainer(forKey: .preferencesConfig) else {
            return
        }

        var res: [JSON] = []
        for i in 0..<prefs.count {
            let pref = try prefs.container(keyedBy: Config.PrefsVersionOneKeys.self, at: i)

            let key = try pref.str(forCheckedKey: .key).wrappedValue
            let val = try pref.raw(forCheckedKey: .value)
            let app = try pref.str(forKey: .applicationId).wrappedValue ?? "AnyApplication"
            let usr = try pref.str(forKey: .userName).wrappedValue ?? "AnyUser"

            if preferences[usr]?[app]?[key] == val {
                res.append(.dictionary(pref.dict))
            }
        }

        result[.preferencesConfig] = .array(res)
    }

    private mutating func export(cryptex: Config.Cryptex) throws {
        // Restore the original cryptex entries from origin
        // This will also include their authentication settings
        if let cryptexes = cryptex.cryptexes {
            let ids = Set(cryptexes.map { $0.key })
            let cryptexConfigs = try listCryptexes(include: ids)
            if !cryptexConfigs.isEmpty {
                result[.cryptexConfig] = .array(cryptexConfigs)
            }
        }

        if let cache = cryptex.cache {
            if let retainUnsafely = cache.retainPreviouslyCachedCryptexesUnsafely {
                result[.retainPreviouslyCachedCryptexesUnsafely] = .bool(retainUnsafely)
            }
            if let cacheMaxSize = cache.cacheMaxSize {
                result[.cryptexCacheMaxTotalSize] = .int(Int128(cacheMaxSize))
            }
            if let invalidationId = cache.invalidationId {
                result[.cryptexCacheInvalidationId] = .string(invalidationId)
            }

            if let retainedCryptexes = cache.retainedCryptexes {
                let retainConfigs = retainedCryptexes.values.map { cryptexEntry -> JSON in
                    .dictionary(["url": .string(cryptexEntry.url.absoluteString)])
                }
                result[.retainedCryptexes] = .array(retainConfigs)
            }
        }

        if let lock = cryptex.lock {
            result[.lockCryptexes] = .bool(lock)
        }

        if let network = cryptex.network, let bandwidthLimit = network.bandwidthLimit {
            result[.bandwidthLimit] = .int(Int128(bandwidthLimit))
        }
    }

    /// Extract cryptex entries from the original V1 JSON
    private func listCryptexes(include have: Set<String>) throws -> [JSON] {
        let root = try converter.container(keyedBy: Config.VersionOneKeys.self)
        guard let cryptexArray = try root.indexedContainer(forKey: .cryptexConfig) else {
            return []
        }

        var result: [JSON] = []
        for i in 0..<cryptexArray.count {
            let entry = try cryptexArray.container(keyedBy: Config.Cryptex.VersionOneKeys.self, at: i)
            let url = try entry.url(forCheckedKey: .url)
            let id = try entry.str(forKey: .identifier).wrappedValue ?? url.wrappedValue.absoluteString

            if have.contains(id) {
                result.append(.dictionary(entry.dict))
            }
        }

        return result
    }

    private mutating func export(diavlo: Config.Diavlo) throws {
        var diavloConfig = DictWriter<Config.Diavlo.VersionOneKeys>()
        if let url = diavlo.url {
            diavloConfig[.serverURL] = .string(url.absoluteString)
        }
        if let rootCert = diavlo.rootCertificate {
            diavloConfig[.rootCertificate] = .string(rootCert.rawValue.base64EncodedString())
        }
        if let auth = config.authentication, let ac = auth.appleConnect {
            diavloConfig[.appleConnect] = .bool(ac)
        }
        if !diavloConfig.dict.isEmpty {
            result[.diavloConfig] = diavloConfig.json
        }
    }

    private mutating func export(featureFlags: [Config.FeatureFlag]) throws {
        let flagConfigs = featureFlags.map { flag -> JSON in
            var config = DictWriter<Config.FeatureFlag.VersionOneKeys>()
            if let domain = flag.domain {
                config[.domain] = .string(domain)
            }
            if let feature = flag.feature {
                config[.feature] = .string(feature)
            }
            if let enable = flag.enable {
                config[.enable] = .bool(enable)
            }
            if let attributeName = flag.attributeName {
                config[.attributeName] = .string(attributeName)
            }
            if let attributeValue = flag.attributeValue {
                config[.attributeValue] = .string(attributeValue)
            }
            if let featurePhase = flag.featurePhase {
                config[.featurePhase] = .string(featurePhase.rawValue)
            }
            return config.json
        }
        result[.featureFlagsConfig] = .array(flagConfigs)
    }

    private mutating func export(finish: Config.Finish) throws {
        if let message = finish.message {
            result[.logText] = .string(message)
        }
        if let reboot = finish.reboot {
            result[.rebootAfterSetup] = .bool(reboot)
        }
        if let userspaceReboot = finish.userspaceReboot {
            result[.USRAfterSetup] = .string(userspaceReboot.rawValue)
        }
        if let failure = finish.onFailure {
            var resultConfig = DictWriter<Config.Finish.ResultConfigVersionOneKeys>()
            resultConfig[.failureAction] = .string(failure.rawValue)
            if !resultConfig.dict.isEmpty {
                result[.resultConfig] = resultConfig.json
            }
        }
    }

    private mutating func export(identification: Config.Identification) throws {
        if let computerName = identification.computerName {
            result[.computerName] = .string(computerName)
        }
        if let hostname = identification.hostname {
            result[.hostName] = .string(hostname)
        }
        if let localHostname = identification.localHostname {
            result[.localHostName] = .string(localHostname)
        }
        if let usageLabel = identification.usageLabel {
            result[.usageLabel] = .string(usageLabel)
        }
    }

    private mutating func export(log: Config.Log) throws {
        var logConfig = DictWriter<Config.Log.VersionOneKeys>()
        if let privacyLevel = log.privacyLevel {
            logConfig[.systemLogPrivacyLevel] = .string(privacyLevel.rawValue)
        }
        if let persist = log.persist {
            logConfig[.systemLoggingEnabled] = .bool(persist)
        }
        if !logConfig.dict.isEmpty {
            result[.logConfig] = logConfig.json
        }
    }

    private mutating func export(meta: Config.Meta) throws {
        if let applyTimeout = meta.applyTimeout {
            result[.applyTimeoutArgument] = .string(applyTimeout)
        }
    }

    private mutating func export(network: Config.Network) throws {
        if let interfaces = network.interfaces {
            let networkConfigs = interfaces.map { (key, value) -> JSON in
                var netConf = DictWriter<Config.NetworkVersionOneKeys>()
                netConf[.interface] = .string(key)
                netConf[.value] = value
                return netConf.json
            }
            result[.networkConfig] = .array(networkConfigs)
        }

        if let uplinkMtu = network.uplinkMtu {
            result[.networkUplinkMTU] = .int(Int128(uplinkMtu))
        }

        if let firewall = network.firewall, let firstRule = firewall.rules.first {
            var fwConfig = DictWriter<Config.FirewallVersionOneKeys>()
            fwConfig[.rules] = .string(firstRule)
            result[.firewallConfig] = fwConfig.json
        }
    }

    private mutating func export(analytics: Config.Analytics) throws {
        if let submit = analytics.submit {
            result[.diagnosticsSubmissionEnabled] = .bool(submit)
        }
    }

    private mutating func export(packages: [Config.Package]) throws {
        let packageConfigs = packages.map { package -> JSON in
            var pkg = DictWriter<Config.Package.VersionOneKeys>()
            pkg[.url] = .string(package.url.absoluteString)
            return pkg.json
        }
        result[.packageConfig] = .array(packageConfigs)
    }

    private mutating func export(roots: [Config.Root]) throws {
        guard let firstRoot = roots.first else { return }

        var installConfig = DictWriter<Config.Root.VersionOneKeys>()
        installConfig[.root] = .string(firstRoot.root)

        if let preflight = firstRoot.preflight {
            installConfig[.preflight] = .string(preflight)
        }
        if let postflight = firstRoot.postflight {
            installConfig[.postflight] = .string(postflight)
        }
        if let waitForVolume = firstRoot.waitForVolume {
            installConfig[.waitForVolume] = .string(waitForVolume)
        }

        result[.installConfig] = installConfig.json
    }

    private mutating func export(ssh: Config.SSH) throws {
        if let enabled = ssh.enabled {
            result[.enableSSH] = .bool(enabled)
        }
        if let pwauth = ssh.pwauth {
            result[.enableSSHPasswordAuthentication] = .bool(pwauth)
        }
    }

    private mutating func export(start: Config.Start) throws {
        if let issueDCRT = start.issueDCRT {
            result[.issueDCRT] = .bool(issueDCRT)
        }
        if let perfdata = start.perfdata {
            result[.collectPerfData] = .bool(perfdata)
        }
        if let scripts = start.scripts {
            let scriptArray = scripts.map { JSON.string($0) }
            result[.preInitCommands] = .array(scriptArray)
        }
    }

    private mutating func export(tailspin: Either<Bool, Config.Tailspin>) throws {
        switch tailspin {
        case .left(let enabled):
            var wrapper = DictWriter<Config.TailspinVersionOneKeys>()
            wrapper[.tailspinEnabled] = .bool(enabled)
            wrapper[.configurationOptions] = .null
            result[.tailspinConfig] = wrapper.json
        case .right(let config):
            var tailspinOpts = DictWriter<Config.Tailspin.VersionOneKeys>()
            if let fullSamplingPeriodSet = config.fullSamplingPeriodSet {
                tailspinOpts[.full_sampling_period_set] = .int(Int128(fullSamplingPeriodSet))
            }
            if let oncoreSamplingPeriodSet = config.oncoreSamplingPeriodSet {
                tailspinOpts[.oncore_sampling_period_set] = .int(Int128(oncoreSamplingPeriodSet))
            }
            if let bufferSizeSet = config.bufferSizeSet {
                tailspinOpts[.buffer_size_set] = .int(Int128(bufferSizeSet))
            }
            if let classConfigs = config.classConfigs {
                let classConfigArray = classConfigs.map { classConfig -> JSON in
                    var classConf = DictWriter<Config.Tailspin.ClassConfig.VersionOneKeys>()
                    classConf[.class_number] = .int(Int128(classConfig.classNumber))
                    classConf[.class_enabled] = .bool(classConfig.classEnabled)
                    if let subclassConfigs = classConfig.subclassConfigs {
                        let subclassArray = subclassConfigs.map { subConfig -> JSON in
                            var subConf = DictWriter<Config.Tailspin.ClassConfig.SubclassConfig.VersionOneKeys>()
                            subConf[.subclassNumber] = .int(Int128(subConfig.subclassNumber))
                            subConf[.subclassEnabled] = .bool(subConfig.subclassEnabled)
                            return subConf.json
                        }
                        classConf[.subclass_configs] = .array(subclassArray)
                    }
                    return classConf.json
                }
                tailspinOpts[.class_configs] = .array(classConfigArray)
            }

            var wrapper = DictWriter<Config.TailspinVersionOneKeys>()
            wrapper[.tailspinEnabled] = .bool(true)
            wrapper[.configurationOptions] = tailspinOpts.json
            result[.tailspinConfig] = wrapper.json
        }
    }

    private mutating func export(users: [String: Config.User]) throws {
        guard let firstUser = users.first else { return }
        let (username, user) = firstUser

        var userConfig = DictWriter<Config.User.VersionOneKeys>()
        userConfig[.userName] = .string(username)
        userConfig[.uid] = .int(Int128(user.uid))
        userConfig[.gid] = .int(Int128(user.gid))

        if let admin = user.admin {
            userConfig[.isAdmin] = .bool(admin)
        }
        if let password = user.plaintextPassword {
            userConfig[.password] = .string(password)
        }
        if let passwordlessSudo = user.passwordlessSudo {
            userConfig[.passwordlessSudo] = .bool(passwordlessSudo)
        }
        if let sshKey = user.sshAuthorizedKey {
            userConfig[.sshAuthorizedKeys] = .string(sshKey)
        }

        if let auth = user.authentication {
            if let esc = auth.esc {
                var escConfig = DictWriter<Config.User.Authentication.ESC.VersionOneKeys>()
                if let principals = esc.principals {
                    escConfig[.principals] = .array(principals.map { .string($0) })
                }
                if let groups = esc.groups {
                    escConfig[.groups] = .array(groups.map { .string($0) })
                }
                if !escConfig.dict.isEmpty {
                    userConfig[.appleConnectSSHConfig] = escConfig.json
                }
            }

            if let memento = auth.memento {
                var mementoConfig = DictWriter<Config.User.Authentication.Memento.VersionOneKeys>()
                if let users = memento.users {
                    mementoConfig[.users] = .array(users.map { .string($0) })
                }
                if let groups = memento.groups {
                    mementoConfig[.groups] = .array(groups.map { .string($0) })
                }
                if let ldapServer = memento.ldapServer {
                    mementoConfig[.ldapServer] = .string(ldapServer)
                }
                if !mementoConfig.dict.isEmpty {
                    userConfig[.appleAuthenticationConfig] = mementoConfig.json
                }
            }
        }

        result[.userConfig] = userConfig.json
    }

    private mutating func export(narrative: [String: JSON]) throws {
        let container = try converter.container(keyedBy: Config.VersionOneKeys.self)
        guard let ids = try container.indexedContainer(forKey: .narrativeIdentitiesConfig) else { return }

        var res: [JSON] = []
        for i in 0..<ids.count {
            let dict = try ids.container(keyedBy: Config.NarrativeVersionOneKeys.self, at: i)
            let id = try dict.str(forCheckedKey: .identity).wrappedValue
            guard let have = narrative[id] else { continue }

            var entry = DictWriter<Config.NarrativeVersionOneKeys>()
            entry[.identity] = .string(id)
            if try dict.raw(forKey: .options) != nil {
                entry[.options] = have
            }
            res.append(entry.json)
        }

        result[.narrativeIdentitiesConfig] = .array(res)
    }

    private mutating func export(volumes: [String: URL]) throws {
        let res: [String: JSON] = volumes.reduce(into: [:]) { (res, entry) in
            res[entry.key] = .string(entry.value.absoluteString)
        }
        result[.volumes] = .dictionary(res)
    }

}

extension Config {

    /// Converts a Config structure to v1 schema JSON format
    /// This is the inverse of the conversion done in Config+Convert.swift
    func toV1JSON() throws -> JSON {
        var exporter = try VersionOneExporter(config: self)
        return try exporter.export()
    }
}
