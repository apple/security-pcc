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

//
//  DInitConfig.swift
//  darwin-init
//

import ArgumentParserInternal
import DarwinInitConfig
import Foundation

@_spi(Private)
public struct DInitConfig {
    var caRoots: DInitCARoots?
    var cryptexConfig: [DInitCryptexConfig]?
    var diavloConfig: DInitDiavloConfig?
    var firewallConfig: DInitFirewallConfig?
    var installConfig: DInitInstallConfig?
    var packageConfig: [DInitPackageConfig]?
    var preferencesConfig: [DInitPreferencesConfig]?
    var narrativeIdentitiesConfig: [DInitNarrativeIdentitiesConfig]?
    var resultConfig: DInitResultConfig?
    var userConfig: DInitUserConfig?
    var logConfig: DInitLogConfig?
    var networkConfig: [DInitNetworkConfig]?
    var networkUplinkMTU: Int?
    var tailspinConfig: DInitTailSpinConfig?
    var featureFlagsConfig: [DInitFeatureFlags]?

    var logText: String?
    
    var legacyComputerName: String?
    var legacyHostName: String?
    var legacyFQDN: String?
    var computerName: String?
    var hostName: String?
    var localHostName: String?
    
    var collectPerfData: Bool?
    
    var enableSSH: Bool?
    var enableSSHPasswordAuthentication: Bool?

    var lockCryptexes: Bool?

    var rebootAfterSetup: Bool?
    var USRAfterSetup: DInitUSR?

    var preInitCommands: [String]?
    var preInitCritical: Bool?
    
    var issueDCRT: Bool?
    
    var secureConfigParameters: JSON?
    
    var usageLabel: String?
    
    var retainPreviouslyCachedCryptexesUnsafely: Bool?
    var cryptexCacheMaxTotalSize: Int?
    var retainedCryptexes: [DInitCryptexConfig]?
    
    var configSecurityPolicy: String?
    var configSecurityPolicyVersion: Int?

	var diagnosticsSubmissionEnabled: Bool?

    var volumes: [String: URL]?

	// Same format as the --timeout input to darwin-init apply
	var applyTimeoutArgument: String?
	var applyTimeout: Duration? {
		get throws {
			guard let applyTimeoutArgument = applyTimeoutArgument else {
				return nil
			}
			guard let duration = Duration(argument: applyTimeoutArgument) else {
				throw ValidationError("Failed to parse 'apply-timeout'")
			}
			return duration
		}
	}
    
    var bandwidthLimit: UInt64?

    @LoaderInjected
    var origin: ConfigOrigin?
    var cryptexCacheInvalidationId: String?
}

extension DInitConfig {
    func jsonString(prettyPrinted: Bool = true, redactCredentialStrings: Bool) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if prettyPrinted {
                encoder.outputFormatting.insert(.prettyPrinted)
            }
            if !redactCredentialStrings {
                encoder.userInfo[CredentialString.redactionOverrideKey] = true
            }
            let data = try encoder.encode(self)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw DInitError.unableToSerializeConfig([], error)
        }
    }
}

extension DInitConfig: CustomStringConvertible {
    public var description: String {
        return (try? self.jsonString(redactCredentialStrings: true)) ?? "<failed to encode DInitConfig>"
    }
}

extension DInitConfig {
    enum CodingKeys: String, CodingKey, CaseIterable {
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
        
        case retainedCryptexes = "cryptex-retain"

        case configSecurityPolicy = "config-security-policy"
        case configSecurityPolicyVersion = "config-security-policy-version"

		case diagnosticsSubmissionEnabled = "diagnostics-submission-enabled"

		case applyTimeoutArgument = "apply-timeout"
        
        case bandwidthLimit = "cryptex-download-bandwidth-limit"
        
        case volumes = "volumes"
        
        case cryptexCacheInvalidationId = "cryptex-cache-invalidation-id"
    }
}

extension DInitConfig: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        caRoots = try container.decodeIfPresent(DInitCARoots.self, forKey: .caRoots)
        if let _cryptexConfig = try? container.decodeIfPresent(DInitCryptexConfig.self, forKey: .cryptexConfig) {
            cryptexConfig = [_cryptexConfig]
        } else {
            cryptexConfig = try container.decodeIfPresent([DInitCryptexConfig].self, forKey: .cryptexConfig)
        }
        diavloConfig = try container.decodeIfPresent(DInitDiavloConfig.self, forKey: .diavloConfig)
        firewallConfig = try container.decodeIfPresent(DInitFirewallConfig.self, forKey: .firewallConfig)
        installConfig = try container.decodeIfPresent(DInitInstallConfig.self, forKey: .installConfig)
        packageConfig = try container.decodeIfPresent([DInitPackageConfig].self, forKey: .packageConfig)
        preferencesConfig = try container.decodeIfPresent([DInitPreferencesConfig].self, forKey: .preferencesConfig)
        narrativeIdentitiesConfig = try
        container.decodeIfPresent([DInitNarrativeIdentitiesConfig].self, forKey: .narrativeIdentitiesConfig)
        resultConfig = try container.decodeIfPresent(DInitResultConfig.self, forKey: .resultConfig)
        userConfig = try container.decodeIfPresent(DInitUserConfig.self, forKey: .userConfig)
        logConfig = try container.decodeIfPresent(DInitLogConfig.self, forKey: .logConfig)
        networkConfig = try container.decodeIfPresent([DInitNetworkConfig].self, forKey: .networkConfig)
        networkUplinkMTU = try container.decodeIfPresent(Int.self, forKey: .networkUplinkMTU)
        tailspinConfig = try container.decodeIfPresent(DInitTailSpinConfig.self, forKey: .tailspinConfig)

        logText = try container.decodeIfPresent(String.self, forKey: .logText)
        
        legacyComputerName = try container.decodeIfPresent(String.self, forKey: .legacyComputerName)
        legacyHostName = try container.decodeIfPresent(String.self, forKey: .legacyHostName)
        legacyFQDN = try container.decodeIfPresent(String.self, forKey: .legacyFQDN)
        computerName = try container.decodeIfPresent(String.self, forKey: .computerName)
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
        localHostName = try container.decodeIfPresent(String.self, forKey: .localHostName)
        
        collectPerfData = try container.decodeIfPresent(DInitBool.self, forKey: .collectPerfData)?.rawValue
        
        enableSSH = try container.decodeIfPresent(DInitBool.self, forKey: .enableSSH)?.rawValue
        enableSSHPasswordAuthentication = try container.decodeIfPresent(DInitBool.self, forKey: .enableSSHPasswordAuthentication)?.rawValue
        
        rebootAfterSetup = try container.decodeIfPresent(DInitBool.self, forKey: .rebootAfterSetup)?.rawValue
        USRAfterSetup = try container.decodeIfPresent(DInitUSR.self, forKey: .USRAfterSetup)
        
        preInitCommands = try container.decodeIfPresent([String].self, forKey: .preInitCommands)
        preInitCritical = try container.decodeIfPresent(DInitBool.self, forKey: .preInitCritical)?.rawValue
        
        issueDCRT = try container.decodeIfPresent(DInitBool.self, forKey: .issueDCRT)?.rawValue
        
        secureConfigParameters = try container.decodeIfPresent(JSON.self, forKey: .secureConfigParameters)
        
        usageLabel = try container.decodeIfPresent(String.self, forKey: .usageLabel)
        
        retainPreviouslyCachedCryptexesUnsafely = try container.decodeIfPresent(DInitBool.self, forKey: .retainPreviouslyCachedCryptexesUnsafely)?.rawValue
        
        cryptexCacheMaxTotalSize = try container.decodeIfPresent(Int.self, forKey: .cryptexCacheMaxTotalSize)
        
        retainedCryptexes = try container.decodeIfPresent([DInitCryptexConfig].self, forKey: .retainedCryptexes)

        configSecurityPolicy = try container.decodeIfPresent(String.self, forKey: .configSecurityPolicy)
        
        configSecurityPolicyVersion = try container.decodeIfPresent(Int.self, forKey: .configSecurityPolicyVersion)

		diagnosticsSubmissionEnabled = try container.decodeIfPresent(DInitBool.self, forKey: .diagnosticsSubmissionEnabled)?.rawValue

		applyTimeoutArgument = try container.decodeIfPresent(String.self, forKey: .applyTimeoutArgument)
        
        bandwidthLimit = try container.decodeIfPresent(UInt64.self, forKey: .bandwidthLimit)

        featureFlagsConfig = try container.decodeIfPresent([DInitFeatureFlags].self, forKey: .featureFlagsConfig)

		lockCryptexes = try container.decodeIfPresent(Bool.self, forKey: .lockCryptexes)

		volumes = try container.decodeIfPresent([String: URL].self, forKey: .volumes)
        
        cryptexCacheInvalidationId = try container.decodeIfPresent(String.self, forKey: .cryptexCacheInvalidationId)
    }
}

extension DInitConfig: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(caRoots, forKey: .caRoots)
        try container.encodeIfPresent(cryptexConfig, forKey: .cryptexConfig)
        try container.encodeIfPresent(diavloConfig, forKey: .diavloConfig)
        try container.encodeIfPresent(firewallConfig, forKey: .firewallConfig)
        try container.encodeIfPresent(installConfig, forKey: .installConfig)
        try container.encodeIfPresent(packageConfig, forKey: .packageConfig)
        try container.encodeIfPresent(preferencesConfig, forKey: .preferencesConfig)
        try container.encodeIfPresent(narrativeIdentitiesConfig, forKey: .narrativeIdentitiesConfig)
        try container.encodeIfPresent(resultConfig, forKey: .resultConfig)
        try container.encodeIfPresent(userConfig, forKey: .userConfig)
        try container.encodeIfPresent(logConfig, forKey: .logConfig)
        try container.encodeIfPresent(networkConfig, forKey: .networkConfig)
        try container.encodeIfPresent(networkUplinkMTU, forKey: .networkUplinkMTU)
        try container.encodeIfPresent(tailspinConfig, forKey: .tailspinConfig)
        try container.encodeIfPresent(logText, forKey: .logText)
        try container.encodeIfPresent(featureFlagsConfig, forKey: .featureFlagsConfig)

        try container.encodeIfPresent(legacyComputerName, forKey: .legacyComputerName)
        try container.encodeIfPresent(legacyHostName, forKey: .legacyHostName)
        try container.encodeIfPresent(legacyFQDN, forKey: .legacyFQDN)
        try container.encodeIfPresent(computerName, forKey: .computerName)
        try container.encodeIfPresent(hostName, forKey: .hostName)
        try container.encodeIfPresent(localHostName, forKey: .localHostName)
        
        try container.encodeIfPresent(collectPerfData, forKey: .collectPerfData)
        
        try container.encodeIfPresent(enableSSH, forKey: .enableSSH)
        try container.encodeIfPresent(enableSSHPasswordAuthentication, forKey: .enableSSHPasswordAuthentication)
        
        try container.encodeIfPresent(rebootAfterSetup, forKey: .rebootAfterSetup)
        try container.encodeIfPresent(USRAfterSetup, forKey: .USRAfterSetup)
        
        try container.encodeIfPresent(preInitCommands, forKey: .preInitCommands)
        try container.encodeIfPresent(preInitCritical, forKey: .preInitCritical)
        
        try container.encodeIfPresent(issueDCRT, forKey: .issueDCRT)
        
        try container.encodeIfPresent(secureConfigParameters, forKey: .secureConfigParameters)
        
        try container.encodeIfPresent(usageLabel, forKey: .usageLabel)
        
        try container.encodeIfPresent(retainPreviouslyCachedCryptexesUnsafely, forKey: .retainPreviouslyCachedCryptexesUnsafely)
        
        try container.encodeIfPresent(cryptexCacheMaxTotalSize, forKey: .cryptexCacheMaxTotalSize)
        
        try container.encodeIfPresent(retainedCryptexes, forKey: .retainedCryptexes)

        try container.encodeIfPresent(configSecurityPolicy, forKey: .configSecurityPolicy)
        
        try container.encodeIfPresent(configSecurityPolicyVersion, forKey: .configSecurityPolicyVersion)

		try container.encodeIfPresent(diagnosticsSubmissionEnabled, forKey: .diagnosticsSubmissionEnabled)

		try container.encodeIfPresent(applyTimeoutArgument, forKey: .applyTimeoutArgument)
        
        try container.encodeIfPresent(bandwidthLimit, forKey: .bandwidthLimit)

		try container.encodeIfPresent(lockCryptexes, forKey: .lockCryptexes)

        try container.encodeIfPresent(volumes, forKey: .volumes)

        try container.encodeIfPresent(cryptexCacheInvalidationId, forKey: .cryptexCacheInvalidationId)
    }
}

extension DInitConfig: Equatable { }

extension DInitConfig: Hashable { }

extension DInitConfig {
    func merging(_ other: DInitConfig, uniquingKeysWith conflictResolver: (Any, Any) throws -> Any) throws -> DInitConfig {
        let encoder = JSONEncoder()
        
        // Please do not copy this override to other parts of the code without seriously considering what you are doing.
        encoder.userInfo[CredentialString.redactionOverrideKey] = true
        
        let selfData = try encoder.encode(self)
        let otherData = try encoder.encode(other)
        
        var selfDict = try JSONSerialization.jsonObject(with: selfData) as! [String: Any]
        let otherDict = try JSONSerialization.jsonObject(with: otherData) as! [String: Any]
        
        try selfDict.merge(otherDict, uniquingKeysWith: conflictResolver)
        
        let result = try JSONSerialization.data(withJSONObject: selfDict)
        return try JSONDecoder().decode(DInitConfig.self, from: result)
    }
}
