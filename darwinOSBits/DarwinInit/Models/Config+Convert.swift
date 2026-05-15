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
//  Config+Convert.swift
//  darwinOSBits
//
//

import Foundation

extension Config: Convertable {
	enum VersionOneKeys: String, CodingKey, CaseIterable {
		case caRoots = "ca-roots"
		case cryptexConfig = "cryptex"
		case diavloConfig = "diavlo"
		case firewallConfig = "firewall"
		case installConfig = "install"
		case packageConfig = "package"
		case preferencesConfig = "preferences"
		case narrativeIdentitiesConfig = "narrative-identities"
		case resultConfig = "result"
		case userConfig = "user"
		case logConfig = "log"
		case networkConfig = "network"
		case networkUplinkMTU = "network-uplink-mtu"
		case tailspinConfig = "tailspin"
		case featureFlagsConfig = "feature_flags"
		case logText = "logtext"
		case legacyComputerName = "compname"
		case legacyHostName = "hostname"
		case legacyFQDN = "fqdn"
		case computerName = "computer-name"
		case hostName = "host-name"
		case localHostName = "local-host-name"
		case collectPerfData = "perfdata"
		case enableSSH = "ssh"
		case enableSSHPasswordAuthentication = "ssh_pwauth"
		case lockCryptexes = "lock-cryptexes"
		case rebootAfterSetup = "reboot"
		case USRAfterSetup = "userspace-reboot"
		case preInitCommands = "pre-init-cmds"
		case preInitCritical = "pre-init-critical"
		case issueDCRT = "issue-dcrt"
		case secureConfigParameters = "secure-config"
		case usageLabel = "usage-label"
		case retainPreviouslyCachedCryptexesUnsafely = "retain-previously-cached-cryptexes-unsafely"
		case cryptexCacheMaxTotalSize = "cryptex-cache-max-total-size"
		case configSecurityPolicy = "config-security-policy"
		case configSecurityPolicyVersion = "config-security-policy-version"
		case diagnosticsSubmissionEnabled = "diagnostics-submission-enabled"
		case applyTimeoutArgument = "apply-timeout"
		case bandwidthLimit = "cryptex-download-bandwidth-limit"
		case retainedCryptexes = "cryptex-retain"
        case volumes = "volumes"
		case cryptexCacheInvalidationId = "cryptex-cache-invalidation-id"
	}

	enum NetworkVersionOneKeys: String, CodingKey {
		case interface
		case value
	}

	enum TailspinVersionOneKeys: String, CodingKey {
		case configurationOptions = "configuration_options"
		case tailspinEnabled = "tailspin_enabled"
	}

	enum NarrativeVersionOneKeys: String, CodingKey {
		case identity
		case options
	}

    enum FirewallVersionOneKeys: String, CodingKey {
        case rules
    }

	init(from conv: Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
        self.$authentication = try conv.convert(Authentication.self)
		self.$caRoots = try container.convert(CARoots.self, forKey: .caRoots)
		self.$cryptex = try container.convert(Cryptex.self, forKey: .cryptexConfig)

        let retainCryptexes: PathCoded<Bool?> = try container.objCBool(forKey: .retainPreviouslyCachedCryptexesUnsafely)
        let cacheSize: PathCoded<UInt?> = try container.uint(forKey: .cryptexCacheMaxTotalSize)
        let cryptexesToRetain: PathCoded<Cryptex?> = try container.convert(Cryptex.self, forKey: .retainedCryptexes)
        let invalidationId: PathCoded<String?> = try container.str(forKey: .cryptexCacheInvalidationId)

        let lockCryptexes: PathCoded<Bool?> = try container.bool(forKey: .lockCryptexes)
        if lockCryptexes.wrappedValue != nil {
			if cryptex == nil {
				self.cryptex = Cryptex()
			}
			self.cryptex?.$lock = lockCryptexes
		}

        if retainCryptexes.wrappedValue != nil ||
            cacheSize.wrappedValue != nil ||
            cryptexesToRetain.wrappedValue != nil ||
            invalidationId.wrappedValue != nil {
			if cryptex == nil {
				self.cryptex = Cryptex()
			}
			if cryptex?.cache == nil {
				self.cryptex?.cache = Cryptex.Cache()
			}
            
            if let cryptexToRetain = cryptexesToRetain.wrappedValue {
                self.cryptex?.cache?.$retainedCryptexes = cryptexToRetain.$cryptexes
            } else {
                self.cryptex?.cache?.$retainedCryptexes = PathCoded(wrappedValue: nil)
            }
			self.cryptex?.cache?.$cacheMaxSize = cacheSize
			self.cryptex?.cache?.$retainPreviouslyCachedCryptexesUnsafely = retainCryptexes
            self.cryptex?.cache?.$invalidationId = invalidationId
		}

        let bandwidthLimit: PathCoded<UInt?> = try container.uint(forKey: .bandwidthLimit)
        if bandwidthLimit.wrappedValue != nil {
			if cryptex == nil {
				self.cryptex = Cryptex()
			}
			if cryptex?.network == nil {
				self.cryptex?.network = Cryptex.Network()
			}
			self.cryptex?.network?.$bandwidthLimit = bandwidthLimit
		}

        self.$analytics = try conv.convert(Analytics.self)
        self.$configSecurityPolicy = try conv.convert(SecurityPolicy.self)
		self.$diavlo = try container.convert(Diavlo.self, forKey: .diavloConfig)

		self.$featureFlags = try container.convert([FeatureFlag].self, forKey: .featureFlagsConfig)
        self.$finish = try conv.convert(Finish.self)
		self.$packages = try container.convert([Package].self, forKey: .packageConfig)

		if let prefs = try container.indexedContainer(forKey: .preferencesConfig) {

			var res: [String: [String: [String: JSON]]] = [:]

			for i in 0..<prefs.count {
				let pref = try prefs.container(keyedBy: PrefsVersionOneKeys.self, at: i)
                let key = try pref.str(forCheckedKey: .key)
				let val = try pref.raw(forCheckedKey: .value)
                let app = try pref.str(forKey: .applicationId).wrappedValue ?? "AnyApplication"
                let usr = try pref.str(forKey: .userName).wrappedValue ?? "AnyUser"

				if res[usr] == nil {
					res[usr] = [:]
				}
                if res[usr]?[app] == nil {
                    res[usr]?[app] = [:]
                }
                res[usr]?[app]?[key.wrappedValue] = val
			}

			if !res.isEmpty {
				self.preferences = res
			}
		}

        self.$identification = try conv.convert(Identification.self)
		self.$log = try container.convert(Log.self, forKey: .logConfig)

        if let applyTimeout = try container.str(forKey: .applyTimeoutArgument) {
            let meta = Meta(applyTimeout: applyTimeout.wrappedValue)
            self.meta = meta
            self.meta?.$applyTimeout.codingPath = applyTimeout.codingPath
        }

		if let netCfg = try container.indexedContainer(forKey: .networkConfig) {
			var ifaces: [String: JSON] = [:]

			for i in 0..<netCfg.count {
				let iface = try netCfg.container(keyedBy: NetworkVersionOneKeys.self, at: i)
                let name = try iface.str(forCheckedKey: .interface)
				let val = try iface.raw(forCheckedKey: .value)
                ifaces[name.wrappedValue] = val
			}

			if !ifaces.isEmpty {
				if network == nil {
					network = Network()
				}
				self.network?.interfaces = ifaces
			}
		}

		if let narrativeIds = try container.indexedContainer(forKey: .narrativeIdentitiesConfig) {
			var ids: [String: JSON] = [:]

			for i in 0..<narrativeIds.count {
				let dict = try narrativeIds.container(keyedBy: NarrativeVersionOneKeys.self, at: i)
                let id = try dict.str(forCheckedKey: .identity)
				let options = try dict.raw(forKey: .options) ?? JSON.null
                ids[id.wrappedValue] = options
			}

			self.narrative = ids
            self.$narrative.codingPath = narrativeIds.codingPath
		}

        if let mtu = try container.uint(forKey: .networkUplinkMTU) {
			if network == nil {
				network = Network()
			}
            self.network?.$uplinkMtu = mtu.makeOptional()
		}

        if let firewall = try container.container(keyedBy: FirewallVersionOneKeys.self,
                                                  forKey: .firewallConfig) {
            if network == nil {
                network = Network()
            }

            if let rules = try firewall.str(forKey: .rules) {
                network?.firewall = Network.Firewall(rules: [rules.wrappedValue])
                network?.firewall?.$rules.codingPath = rules.codingPath
            }
        }

        // NB: root (alphabetically should be here) is done after start

		if let userCfg = try container.container(keyedBy: User.VersionOneKeys.self, forKey: .userConfig) {
            let name = try userCfg.str(forCheckedKey: .userName)
			guard let user = try container.convert(User.self, forKey: .userConfig) else {
                let context = DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "User data incomplete",
                    underlyingError: nil)
                throw DecodingError.valueNotFound(User.self, context)
			}
			self.users = [
                name.wrappedValue: user.wrappedValue
			]
            self.$users.codingPath = userCfg.codingPath
		}

        self.$secureConfig = try container.dict(forKey: .secureConfigParameters)

        self.$ssh = try conv.convert(SSH.self)
        self.$start = try conv.convert(Start.self)

        // if `install` does not have a `root` entry, convert the scripts
        // to start scripts. Hence this needs to be done after `start` is
        // converted so it can append to `start.scripts`.
        if let root = try container.container(keyedBy: Config.Root.VersionOneKeys.self,
                                              forKey: .installConfig) {

            if let uri = try root.str(forKey: .root) {
                var entry = Config.Root(root: uri.wrappedValue)
                entry.$root.codingPath = uri.codingPath
                self.$roots.codingPath = root.codingPath
                entry.$preflight = try root.str(forKey: .preflight)
                entry.$postflight = try root.str(forKey: .postflight)
                self.roots = [entry]
            } else {
                let scripts: [PathCoded<String?>] = [
                    try root.str(forKey: .preflight), try root.str(forKey: .postflight)
                ]
                for script in scripts {
                    guard let script = script.wrappedValue else { continue }
                    if self.start == nil {
                        self.start = Start()
                    }
                    if self.start?.scripts == nil {
                        self.start?.scripts = [script]
                    } else {
                        self.start?.scripts?.append(script)
                    }
                }
            }
        }

		if let ts = try container.container(keyedBy: TailspinVersionOneKeys.self, forKey: .tailspinConfig) {
			let enabled = try ts.bool(forCheckedKey: .tailspinEnabled)
            if enabled.wrappedValue {
				if let tsCfg = try ts.convert(Tailspin.self, forKey: .configurationOptions) {
                    self.tailspin = .right(tsCfg.wrappedValue)
                    self.$tailspin.codingPath = tsCfg.codingPath
				} else {
					self.tailspin = .left(true)
                    self.$tailspin.codingPath = enabled.codingPath
				}
			} else {
				self.tailspin = .left(false)
                self.$tailspin.codingPath = ts.codingPath
			}
		}

        self.$volumes = try container.dict(forKey: .volumes)
	}
}

extension Config {
	enum PrefsVersionOneKeys: String, CodingKey {
		case key
		case value
		case applicationId = "application_id"
		case userName = "username"
		case hostName = "hostname"
	}
}

extension Config.Authentication: Convertable {
	typealias VersionOneKeys = Config.Cryptex.VersionOneKeys

	init?(from conv: Converter) throws {
		let outer = try conv.container(keyedBy: Config.VersionOneKeys.self)

		guard let array = try outer.indexedContainer(forKey: .cryptexConfig) else {
			return nil
		}

		for i in 0..<array.count {
			let container = try array.container(keyedBy: VersionOneKeys.self, at: i)

            let wg_token: PathCoded<CredentialString>? = try container.convert(CredentialString.self, forKey: .wgToken)
            let wg_user: PathCoded<String>? = try container.str(forKey: .wgUsername)

            if let wg_user, let wg_token {
				// TODO: warn on overwrite
                self.westgate = Westgate(token: wg_token, username: wg_user)
                self.$westgate.codingPath = container.codingPath
			}

			if let daw_token = try container.str(forKey: .dawToken) {
                self.dawToken = CredentialString(daw_token.wrappedValue)
                self.$dawToken.codingPath = daw_token.codingPath
			}
            
            if let oidc_token = try container.str(forKey: .oidcToken) {
                self.oidcToken = CredentialString(oidc_token.wrappedValue)
                self.$oidcToken.codingPath = oidc_token.codingPath
            }

            let appleConnect: PathCoded<Bool?> = try container.bool(forKey: .appleConnect)
            if appleConnect.wrappedValue != nil {
				self.$appleConnect = appleConnect
			}
		}

        if self.isEmpty {
            return nil
        }
	}
}

extension Config.Authentication.Westgate {

    init(token: PathCoded<CredentialString>, username: PathCoded<String>) {
        self.init(token: token.wrappedValue, username: username.wrappedValue)
        self.$token.codingPath = token.codingPath
        self.$username.codingPath = username.codingPath
    }

}

extension Config.CARoots: Convertable {

	enum VersionOneKeys: String, CodingKey {
		case appleCorpRoot = "apple-corporate-root"
	}

	init(from converter: Converter) throws {
		let container = try converter.container(keyedBy: VersionOneKeys.self)
		self.$appleCorporateRoot = try container.bool(forKey: .appleCorpRoot)
	}
}

extension Config.Cryptex.Network: Convertable {
	typealias VersionOneKeys = Config.Cryptex.VersionOneKeys

	init?(from conv: Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)

        let bgClass: PathCoded<Bool?> = try container.bool(forKey: .backgroundTrafficClass)

        if let isBg = bgClass.wrappedValue {
            self.networkServiceType = isBg ? .background : .default
            self.$networkServiceType.codingPath = bgClass.codingPath
        }

		self.$alternateCdnHost = try container.str(forKey: .alternateCDNHost)
		self.$retryCount = try container.uint(forKey: .networkRetryCount)
		self.$downloadTasks = try container.uint(forKey: .maxActiveTasks)
        self.$chunkSize = try container.uint(forKey: .chunkSize)

		if networkServiceType == nil &&
            alternateCdnHost == nil &&
            retryCount == nil &&
            downloadTasks == nil &&
            chunkSize == nil {
			return nil
		}
	}
}

extension Config.Cryptex.Cryptex: Convertable {
	typealias VersionOneKeys = Config.Cryptex.VersionOneKeys

	init(from conv: Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
        let url = try container.url(forCheckedKey: .url)
        self.init(url: url.wrappedValue)
        self.$url.codingPath = url.codingPath

		self.$aeaDecryptionParams = try container.convert(AeaDecryptionParams.self, forKey: .aeaDecryptionParams)
		self.$cacheable = try container.bool(forKey: .cacheable)
        self.$signingEnvironment = try container.convert(DInitAuthorizationService.self, forKey: .auth)
        self.$sha256 = try container.convert(DInitSHA256Digest.self, forKey: .sha256)
        self.$size = try container.uint(forKey: .size)
        self.$variant = try container.str(forKey: .variant)
        self.$jetsamPropertiesVariant = try container.str(forKey: .jetsamPropertiesVariant)
        self.$originalKnoxUrl = try container.url(forKey: .originalKnoxUrl)
	}
}

extension Config.Cryptex.Cryptex.AeaDecryptionParams: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case aeaArchiveId = "aea_archive_id"
		case aeaDecryptionKey = "aea_decryption_key"
	}

	init(from conv: Converter) throws {
        let container = try conv.container(keyedBy: VersionOneKeys.self)

        let archiveId = try container.str(forCheckedKey: .aeaArchiveId)
        let decryptionKey = try container.str(forCheckedKey: .aeaDecryptionKey)

        self.init(archiveId: archiveId, decryptionKey: decryptionKey)
	}

    private init(archiveId: PathCoded<String>, decryptionKey: PathCoded<String>) {
        self.init(archiveId: CredentialString(archiveId.wrappedValue),
                  decryptionKey: CredentialString(decryptionKey.wrappedValue))
        self.$archiveId.codingPath = archiveId.codingPath
        self.$decryptionKey.codingPath = decryptionKey.codingPath
    }
}

extension Config.Cryptex: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case url
		case variant
		case jetsamPropertiesVariant = "jetsam_properties_variant"
		case size
		case sha256
		case auth
		case dawToken = "daw_token"
        case oidcToken = "oidc_token"
		case wgUsername = "wg_username"
		case wgToken = "wg_token"
		case alternateCDNHost = "alternate_cdn_host"
		case backgroundTrafficClass = "background_traffic_class"
		case networkRetryCount = "network_retry_count"
		case appleConnect = "apple_connect"
		case cacheable
		case identifier
		case aeaDecryptionParams = "aea_decryption_params"
		case maxActiveTasks = "max_active_tasks"
        case chunkSize = "chunk_size"
        case originalKnoxUrl = "original_knox_url"
	}

	typealias CryptexCfg = Cryptex

	init(from conv: Converter) throws {
		let container = try conv.indexedContainer()

		var cryptexes: [String: CryptexCfg] = [:]
        var lastCryptex: String?
		for i in 0..<container.count {
			if let nw = try container.convert(Network.self, at: i) {
				self.network = nw
			}

            if var cryptex = try container.convert(CryptexCfg.self, at: i) {
				let inner = try container.container(keyedBy: VersionOneKeys.self, at: i)
                let id = try inner.str(forKey: .identifier).wrappedValue ?? cryptex.url.absoluteString

				if cryptexes[id] != nil {
					throw DecodingError.dataCorrupted(.init(
						codingPath: conv.codingPath,
						debugDescription: "Duplicated cryptex id: \(id)")
					)
				}

                if let lastCryptex {
                    cryptex.dependencies = [lastCryptex]
                }

                lastCryptex = id
				cryptexes[id] = cryptex
			}
		}
		self.cryptexes = cryptexes
        self.$cryptexes.codingPath = conv.codingPath
	}
}

extension Config.Diavlo: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case serverURL = "url"
		case rootCertificate = "root_certificate"
		case appleConnect = "apple_connect"
	}

	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
        let url = try container.url(forCheckedKey: .serverURL)
        self.init(url: url.wrappedValue)
        self.$url.codingPath = url.codingPath
		self.$rootCertificate = try container.convert(DInitData.self, forKey: .rootCertificate)
	}
}

extension Config.FeatureFlag: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case domain = "domain"
		case feature = "feature"
		case enable = "enable"
		case attributeName = "attribute_name"
		case attributeValue = "attribute_value"
		case featurePhase = "feature_phase"
	}

	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
		$attributeName = try container.str(forKey: .attributeName)
		$attributeValue = try container.str(forKey: .attributeValue)
		$domain = try container.str(forKey: .domain)
		$enable = try container.bool(forKey: .enable)
		$feature = try container.str(forKey:.feature)
		$featurePhase = try container.convert(FeaturePhase.self, forKey: .featurePhase)
	}
}

extension Config.FeatureFlag.FeaturePhase: Convertable {
	init?(from conv: any Converter) throws {
		let container = try conv.singleValueContainer()
		self.init(rawValue: try container.str)
	}
}

extension Config.Finish: Convertable {
	typealias VersionOneKeys = Config.VersionOneKeys

    enum ResultConfigVersionOneKeys: String, CodingKey, CaseIterable {
        case failureAction
    }

	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)

		self.$message = try container.str(forKey: .logText)
		self.$reboot = try container.objCBool(forKey: .rebootAfterSetup)

        self.$userspaceReboot = try container.convert(UserspaceReboot.self, forKey: .USRAfterSetup)

        if let resultDict = try container.container(keyedBy: ResultConfigVersionOneKeys.self,
                                                    forKey: .resultConfig) {
            self.$onFailure = try resultDict.convert(FailureAction.self, forKey: .failureAction)
        }

        if message == nil && reboot == nil && userspaceReboot == nil && self.onFailure == nil {
			return nil
		}
	}
}

extension Config.Finish.UserspaceReboot: Convertable {
	typealias VersionOneKeys = Config.VersionOneKeys

	init?(from conv: Converter) throws {
		let container = try conv.singleValueContainer()
		let str = try container.str
		self.init(rawValue: str)
	}
}

extension Config.Identification: Convertable {
	typealias VersionOneKeys = Config.VersionOneKeys
    init?(from conv: any Converter) throws {
        let container = try conv.container(keyedBy: VersionOneKeys.self)

        self.$computerName = try container.str(forKey: .legacyComputerName)
        self.$localHostname = try container.str(forKey: .legacyComputerName)

        if let name = try container.str(forKey: .legacyFQDN) {
            self.$computerName = name.makeOptional()
        }

        if let name = try container.str(forKey: .computerName) {
            self.$computerName = name.makeOptional()
        }

        if let name = try container.str(forKey: .hostName) {
            self.$hostname = name.makeOptional()
        }

        if let name = try container.str(forKey: .localHostName) {
            self.$localHostname = name.makeOptional()
        }

        if let name = try container.str(forKey: .usageLabel) {
            self.$usageLabel = name.makeOptional()
        }

        if self.isEmpty {
           return nil
        }
	}
}

extension Config.Package: Convertable {
	enum VersionOneKeys: String, CodingKey, CaseIterable {
		case url = "url"
	}

	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
        let url = try container.url(forCheckedKey: .url)
        self.init(url: url.wrappedValue)
        self.$url.codingPath = url.codingPath
	}
}

extension Config.Log: Convertable {

	enum VersionOneKeys: String, CodingKey, CaseIterable {
		case systemLogPrivacyLevel = "system-log-privacy-level"
		case systemLoggingEnabled = "system-logging-enabled"
	}

	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
		self.$persist = try container.bool(forKey: .systemLoggingEnabled)
		self.$privacyLevel =  try container.convert(PrivacyLevel.self, forKey: .systemLogPrivacyLevel)

        if self.isEmpty {
			return nil
		}
	}
}

extension Config.Log.PrivacyLevel: Convertable {
	init?(from conv: any Converter) throws {
		let container = try conv.singleValueContainer()
		let str = try container.str
		self.init(rawValue: str)
	}
}

extension Config.Analytics: Convertable {
	typealias VersionOneKeys = Config.VersionOneKeys

	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
		self.$submit = try container.objCBool(forKey: .diagnosticsSubmissionEnabled)

		if self.submit == nil {
			return nil
		}
	}
}

extension Config.Root: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case waitForVolume
		case preflight
		case preflightShell
		case root
		case postflight
		case postflightShell
	}
	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
        let root: PathCoded<String> = try container.str(forCheckedKey: .root)
        self.init(root: root.wrappedValue)
        self.$root.codingPath = root.codingPath
		self.$preflight = try container.str(forKey: .preflight)
		self.$postflight = try container.str(forKey: .postflight)
	}
}

extension Config.SecurityPolicy: Convertable {
	typealias VersionOneKeys = Config.VersionOneKeys

	init?(from conv: Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)

		self.$version = try container.uint(forKey: .configSecurityPolicyVersion)
		self.$policy = try container.str(forKey: .configSecurityPolicy)

		if self.version == nil && self.policy == nil {
			return nil
		}
	}
}

extension Config.SSH: Convertable {
	typealias VersionOneKeys = Config.VersionOneKeys

	init?(from conv: Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)

		self.$enabled = try container.objCBool(forKey: .enableSSH)
		self.$pwauth = try container.objCBool(forKey: .enableSSHPasswordAuthentication)

        if self.isEmpty {
			return nil
		}
	}
}

extension Config.Start: Convertable {
	typealias VersionOneKeys = Config.VersionOneKeys

	init?(from conv: Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)

		self.$issueDCRT = try container.objCBool(forKey: .issueDCRT)
		self.$perfdata = try container.objCBool(forKey: .collectPerfData)

        if let preinit = try container.convert([String].self, forKey: .preInitCommands) {
            self.$scripts = preinit.makeOptional()
        }

        if self.isEmpty { return nil }
	}
}

extension Config.User: Convertable {
	enum VersionOneKeys: String, CodingKey, CaseIterable {
		case userName = "name"
		case uid
		case gid
		case password
		case isAdmin
		case sshAuthorizedKeys = "ssh_authorized_key"
		case passwordlessSudo = "passwordless_sudo"
		case appleConnectSSHConfig = "ssh_appleconnect_auth"
		case appleAuthenticationConfig = "apple_authentication"
	}

	init?(from conv: Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)

        let uid = try container.uint(forCheckedKey: .uid)
        let gid = try container.uint(forCheckedKey: .gid)

        self.init(uid: uid.wrappedValue, gid: gid.wrappedValue)
        self.$uid.codingPath = uid.codingPath
        self.$gid.codingPath = gid.codingPath

        self.$admin = try container.objCBool(forKey: .isAdmin)
		self.$plaintextPassword = try container.str(forKey: .password)
		self.$passwordlessSudo = try container.objCBool(forKey: .passwordlessSudo)
		self.$sshAuthorizedKey = try container.str(forKey: .sshAuthorizedKeys)
		self.authentication = try Authentication(from: conv)
	}
}

extension Config.User.Authentication: Convertable {
	typealias VersionOneKeys = Config.User.VersionOneKeys

	init?(from conv: Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
		self.$esc = try container.convert(ESC.self, forKey: .appleConnectSSHConfig)
		self.$memento = try container.convert(Memento.self, forKey: .appleAuthenticationConfig)
		if esc == nil && memento == nil {
			return nil
		}
	}
}

extension Config.User.Authentication.ESC: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case principals
		case groups
	}

	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
		$principals = try container.convert([String].self, forKey: .principals)
		$groups = try container.convert([String].self, forKey: .groups)
		if principals == nil && groups == nil {
			return nil
		}
	}
}

extension Config.User.Authentication.Memento: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case users
		case groups
		case ldapServer = "ldap-server"
	}
	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)

		$users = try container.convert([String].self, forKey: .users)
		$groups = try container.convert([String].self, forKey: .groups)
		$ldapServer = try container.str(forKey: .ldapServer)
		if users == nil && groups == nil && ldapServer == nil {
			return nil
		}
	}
}

extension String: Convertable {
	init?(from conv: any Converter) throws {
		let container = try conv.singleValueContainer()
		self = try container.str
	}
}


extension Config.Tailspin: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case full_sampling_period_set = "full_sampling_period_set"
		case oncore_sampling_period_set = "oncore_sampling_period_set"
		case buffer_size_set = "buffer_size_set"
		case class_configs = "class_configs"
	}
	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
		$bufferSizeSet = try container.uint64(forKey: .buffer_size_set)
		$fullSamplingPeriodSet = try container.uint64(forKey: .full_sampling_period_set)
		$oncoreSamplingPeriodSet = try container.uint64(forKey: .oncore_sampling_period_set)
		$classConfigs = try container.convert([ClassConfig].self, forKey: .class_configs)
	}
}

extension Config.Tailspin.ClassConfig: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case class_number = "class_number"
		case class_enabled = "class_enabled"
		case subclass_configs = "subclass_configs"
	}

	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
		let classNumber = try container.uint8(forCheckedKey: .class_number)
		let classEnabled = try container.bool(forCheckedKey: .class_enabled)

        self.init(number: classNumber, enabled: classEnabled)
        self.$classNumber.codingPath = classNumber.codingPath

		$subclassConfigs = try container.convert([SubclassConfig].self, forKey: .subclass_configs)
	}

    private init(number: PathCoded<UInt8>, enabled: PathCoded<Bool>) {
        self.init(classNumber: number.wrappedValue,
                  classEnabled: enabled.wrappedValue)
        self.$classNumber.codingPath = number.codingPath
        self.$classEnabled.codingPath = enabled.codingPath
    }
}

extension Config.Tailspin.ClassConfig.SubclassConfig: Convertable {
	enum VersionOneKeys: String, CodingKey {
		case subclassNumber = "subclass_number"
		case subclassEnabled = "subclass_enabled"
	}

	init?(from conv: any Converter) throws {
		let container = try conv.container(keyedBy: VersionOneKeys.self)
		let subclassNumber = try container.uint8(forCheckedKey: .subclassNumber)
		let subclassEnabled = try container.bool(forCheckedKey: .subclassEnabled)
        self.init(number: subclassNumber, enabled: subclassEnabled)
        self.$subclassNumber.codingPath = subclassNumber.codingPath
    }

    init(number: PathCoded<UInt8>, enabled: PathCoded<Bool>) {
        self.init(subclassNumber: number.wrappedValue,
                  subclassEnabled: enabled.wrappedValue)
        self.$subclassNumber.codingPath = number.codingPath
        self.$subclassEnabled.codingPath = enabled.codingPath
    }
}

// MARK: Existing types

extension CredentialString: Convertable {
	init?(from conv: any Converter) throws {
		let container = try conv.singleValueContainer()
		self.init(try container.str)
	}
}


extension DInitAuthorizationService: Convertable {
    init?(from conv: any Converter) throws {
        let container = try conv.singleValueContainer()
        self.init(rawValue: try container.str)
    }
}

extension DInitData: Convertable {
	init?(from conv: any Converter) throws {
		let container = try conv.singleValueContainer()

		guard let data = Data(base64Encoded: try container.str) else {
			let context = DecodingError.Context(
				codingPath: conv.codingPath,
				debugDescription: "Encoded string is not valid base64 encoded data",
				underlyingError: nil)
			throw DecodingError.dataCorrupted(context)
		}

		self.rawValue = data
	}
}

extension DInitFailureAction: Convertable {
    init?(from conv: any Converter) throws {
        let container = try conv.singleValueContainer()
        self.init(argument: try container.str)
    }
}

extension DInitSHA256Digest: Convertable {
    init?(from conv: any Converter) throws {
        let container = try conv.singleValueContainer()
        self.init(argument: try container.str)
    }
}

extension URL: Convertable {
    init?(from conv: any Converter) throws {
        let container = try conv.singleValueContainer()
        self.init(string: try container.str)
    }
}
