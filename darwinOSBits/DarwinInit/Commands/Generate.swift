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
//  Generate.swift
//  darwin-init
//

import ArgumentParserInternal
import DarwinInitConfig
import Foundation
import libnarrativecert
import System

struct Generate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generates a new configuration",
        discussion: """
The generate subcommand takes various arguments and creates a json file that can \
be passed to the darwinOS through boot-args. This allows the command \
"darwin-init apply" to configure the system to these specifications.
""")

    @Argument(help: "The file name to store the generated configuration")
    var fileName: String

    @Option(name: .shortAndLong, help: "A message to be placed in the log")
    var log: String?

    @Option(name: [.customShort("C"), .customLong("pre-init-cmd")], help: "Specify one or more scripts to execute in bash before all other darwin-init operations.")
    var preInitCommands: [String] = []

	@Flag(name: .long, inversion: .prefixedNo, help: "Pre-init commands will be treated as system critical. If any one fails, darwin-init will stop and fail immediately without performing the remaining config.")
	var preInitCritical: Bool?

    @Flag(name: .shortAndLong, inversion: .prefixedNo, help: "Enable SSH daemon")
    var ssh: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable SSH password authentication")
    var sshPasswordAuth: Bool?

    @Flag(name: [.customShort("P"), .long], inversion: .prefixedNo, help: "Collect performance data at boot")
    var perfdata: Bool?

    @Flag(name: [.customShort("d"), .long], inversion: .prefixedNo, help: "Issue DCRT hardware attestation certificate at boot")
    var issueDCRT: Bool?

	@Option(name: [.customShort("n"), .long, .customLong("compname")], help: "Custom device computer name used in user displays and used by bonjour.")
	var computerName: String?

    // Underscored to work around a bug fixed in newer versions of Swift-Argument-Parser.
	@Option(name: [.customLong("host-name"), .customLong("hostname"), .customLong("fqdn")], help: "Custom device hostname.")
    var _hostName: String?

	@Option(name: .long, help: "Custom device local hostname used by bonjour.")
	var localHostName: String?

    @Option(name: [.customLong("usage-label")], help: "Usage label for tagging log messages forwarded by splunkloggingd and emitted by OSAnalytics")
    var usageLabel: String?
    
    @Option(name: [.customLong("config-security-policy")], help: "Policy for security and privacy validation of the darwin-init config. May be set to 'customer', 'customerProxy' or 'carry'. If not set, no security/privacy validation is performed. Included in the attestation bundle.")
    var configSecurityPolicy: String?
    
    @Option(name: [.customLong("config-security-policy-version")], help: "Version number to use when validating darwin-init config against the config-security-policy. Each time new policy enforcement logic is deployed for a darwin-init key, we will increment the version number. Clients may override this and use an older version so that they only receive a warning but can still apply their config.")
    var configSecurityPolicyVersion: Int?

	@Flag(name: [.customLong("retain-previously-cached-cryptexes-unsafely")], help: "Retain cryptexes exclusive to previous configs (internal use only)")
	var retainPreviouslyCachedCryptexesUnsafelyFlagCount: Int
	
	@Option(name: .long, help: "Sets the maximum storage space that the cryptex cache should occupy (in bytes)")
	var cryptexCacheMaxTotalSize: Int?

    @Flag(name: .long, inversion: .prefixedEnableDisable, help: "Enable/disable diagnostics submission")
    var diagnosticsSubmission: Bool?

    @Option(name: .customLong("apply-timeout"), help: "Set the timeout to enforce when applying this config. Value should be a string of the same format as the `darwin-init apply --timeout` argument.")
    var applyTimeoutArgument: String?

    @Option(name: .customLong("cryptex-download-bandwidth-limit"), help: "Configure the input bandwidth limit on the Mellanox interface in bits per second. The limit will be set immediately before cryptexes are downloaded and unset immediately after. Intended only for J236.")
    var bandwidthLimit: UInt64?

    @Flag(name: .long, inversion: .prefixedNo, help: "Lock down cryptex sealed software hash registers, preventing further loading of cryptexes. This behavior is implied when \"userspace-reboot\" is set to \"rem\".")
    var lockCryptexes: Bool?

    @Option(
        help: "Set the maximum transfer unit (MTU) of the uplink (min: \(kUplinkMTUMin), max: \(kUplinkMTUMax))."
    )
    var networkUplinkMTU: Int?

    @OptionGroup
    var cryptexOptions: CryptexOptions

    @OptionGroup
    var diavloOptions: DiavloOptions

    @OptionGroup
    var installOptions: InstallOptions

    @OptionGroup
    var packageOptions: PackageOptions

    @OptionGroup
    var resultConfig: ResultOptions

    @OptionGroup
    var preferenceOptions: PreferenceOptions
    
    @OptionGroup
    var narrativeIdentitiesOptions: NarrativeIdentityOptions

    @OptionGroup
    var userOptions: UserOptions
    
    @OptionGroup
    var logOptions: LogOptions

	@OptionGroup
    var networkOptions: NetworkOptions

    func run() throws {
		var config = DInitConfig(
			caRoots: nil,
			cryptexConfig: cryptexOptions.config,
			diavloConfig: diavloOptions.config,
			firewallConfig: nil,
			installConfig: installOptions.config,
			packageConfig: packageOptions.config,
			preferencesConfig: preferenceOptions.config,
            narrativeIdentitiesConfig: narrativeIdentitiesOptions.config,
			resultConfig: resultConfig.config,
			userConfig: userOptions.config,
            logConfig: logOptions.config,
            networkConfig: networkOptions.config,
            networkUplinkMTU: networkUplinkMTU,
			logText: log,
			legacyComputerName: nil,
			legacyHostName: nil,
			legacyFQDN: nil,
			computerName: computerName,
			hostName: _hostName,
			localHostName: localHostName,
			collectPerfData: perfdata,
			enableSSH: ssh,
			enableSSHPasswordAuthentication: sshPasswordAuth,
            lockCryptexes: lockCryptexes,
			rebootAfterSetup: installOptions.reboot,
			USRAfterSetup: installOptions.userspaceReboot,
            preInitCommands: preInitCommands.isEmpty ? nil : preInitCommands,
			preInitCritical: preInitCritical,
			issueDCRT: issueDCRT,
			usageLabel: usageLabel,
			retainPreviouslyCachedCryptexesUnsafely: (retainPreviouslyCachedCryptexesUnsafelyFlagCount > 0) ? true : nil,
			cryptexCacheMaxTotalSize: cryptexCacheMaxTotalSize,
            configSecurityPolicy: configSecurityPolicy,
            configSecurityPolicyVersion: configSecurityPolicyVersion,
            diagnosticsSubmissionEnabled: diagnosticsSubmission,
            applyTimeoutArgument: applyTimeoutArgument,
            bandwidthLimit: bandwidthLimit)

        if let key = userOptions.key {
            do {
                config.userConfig?.sshAuthorizedKeys = try key.loadString()
            } catch {
                logger.error("Unable to read public key at \(key)")
                throw error
            }
        }

        let json = try config.jsonString(prettyPrinted: false, redactCredentialStrings: false)
        if fileName == "-" {
            print(json)
        } else {
            try FilePath(fileName).save(json)
        }

        let deprecationNotice = """
            error: `darwin-init generate` is deprecated and will be removed.
            The JSON has still been produced for now, but this command will be removed entirely in the future.

            """
        FileHandle.standardError.write(Data(deprecationNotice.utf8))
        throw ExitCode.failure
    }

    func validate() throws {
        if let mtu = networkUplinkMTU, !(mtu >= kUplinkMTUMin  && mtu <= kUplinkMTUMax) {
            throw ValidationError("MTU needs to be between \(kUplinkMTUMin) and \(kUplinkMTUMax)")
        }
    }
}

extension Generate {
    struct CryptexOptions: ParsableArguments {
        @Option(
            name: [.customShort("c"), .customLong("cryptex")],
            help: "URL of the cryptexes to install",
            transform: { try URL($0, strategy: .url) })
        var cryptexUrl: [URL] = []

        @Option(name: [.customShort("V"), .customLong("cryptex-variant")], help: "Variant names for the cryptexes")
        var variant: [String] = []

        @Option(name: [.customLong("cryptex-size")], help: "Sizes of the compressed cryptexes")
        var size: [Int] = []

        @Option(name: [.customLong("cryptex-sha256")], help: "Hexadecimal sha256 digests of the compressed cryptexes")
        var sha256: [Sha256] = []

        @Option(name: [.customLong("cryptex-authorization-service")], help: "Authorization services used to verify cryptex validities")
        var auth: [Config.Cryptex.Cryptex.SigningEnvironment] = []
        
        @Option(name: [.customLong("daw-token")], help: "Daw token for authenticating with Knox when downloading and fetching decryption key for a Knox cryptex.")
        var dawToken: [String] = []
        
        @Option(name: [.customLong("wg-username")], help: "Westgate username for authenticating with Knox when downloading and fetching decryption key for a Knox cryptex. If testing at desk, you should use your AppleConnect username.")
        var wgUsername: [String] = []
        
        @Option(name: [.customLong("wg-token")], help: "Westgate token for authenticating with Knox when downloading and fetching decryption key for a Knox cryptex.")
        var wgToken: [String] = []
        
        @Option(name: [.customLong("alternate-CDN-host")], help: "Alternate CDN host address to use when downloading cryptexes from Knox.")
        var alternateCDNHost: [String] = []
        
		@Option(name: [.customLong("background-traffic-class")], help: "Enable setting the network service type to background rather than default for Knox cryptex downloads. Set to 'true' to enable. Default is 'false'.")
        var backgroundTrafficClass: Bool = false
        
        @Option(name: [.customLong("network-retry-count")], help: "Configure the number of retries with exponential backoff for network failures such as HTTP 429 when downloading and decrypting a cryptex from Knox. The max number of retries is 15. This does not apply to authorization failures.")
        var networkRetryCount: UInt?

        @Option(name: [.customLong("cryptex-sign-using-apple-connect")], help: "Use AppleConnect(SSO) for personalization")
        var appleConnect: Bool = false

		@Option(name: [.customLong("cryptex-cacheable")], help: "Enable caching of this cryptex")
		var cacheable: [Bool] = []
		
        @Option(name: [.customLong("cryptex-identifier")], help: "The identifier for the cryptex")
        var identifier: [String] = []
        
        @Option(name: [.customLong("aea-archive-id")], help: "The expected AEA archive ID for an AEA cryptex")
        var aeaArchiveId: [String] = []
        
        @Option(name: [.customLong("aea-decryption-key")], help: "Pre-determined decryption key for an AEA cryptex")
        var aeaDecryptionKey: [String] = []
        
        @Option(name: [.customLong("max-active-tasks")], help: "Maximum parallel active tasks for performing range request downloads. Defaults is 4.")
        var maxActiveTasks: Int?
        
        @Option(name: [.customLong("chunk-size")], help: "Chunk size (in bytes) to use when performing parallel range request downloads. If set, darwin-init will assume range requests are supported without verifying via a HEAD request. Note: If unspecified, but darwin-init detects range requests are supported a default of 16 MiB is used.")
        var chunkSize: UInt64?

		var config: [DInitCryptexConfig]? {
			guard !cryptexUrl.isEmpty else { return nil }
			return cryptexUrl.indices.map { index in
                let aeaDecryptionParams = (aeaDecryptionKey[safe: index] != nil && aeaArchiveId[safe: index] != nil) ? DInitAEADecryptionParams(aeaArchiveId: aeaArchiveId[safe: index]!, aeaDecryptionKey: aeaDecryptionKey[safe: index]!) : nil
                return DInitCryptexConfig(
					url: cryptexUrl[index],
					variant: variant[safe: index],
					size: size[safe: index],
					sha256: sha256[safe: index],
					auth: auth[safe: index],
                    dawToken: CredentialString(dawToken[safe: index]),
                    wgUsername: wgUsername[safe: index],
					wgToken: CredentialString(wgToken[safe: index]),
                    alternateCDNHost: alternateCDNHost[safe: index],
                    backgroundTrafficClass: backgroundTrafficClass,
                    networkRetryCount: networkRetryCount,
					appleConnect: appleConnect,
					cacheable: cacheable[safe: index],
                    identifier: identifier[safe: index],
                    aeaDecryptionParams: aeaDecryptionParams,
                    maxActiveTasks: maxActiveTasks,
                    chunkSize: chunkSize)
			}
		}

        func validate() throws {
            // There might be case where one wants to install a cryptex with variant, and another
            // without variant. It will still work for the JSON config, but we just don't support
            // that in `generate` command.
            if !variant.isEmpty, cryptexUrl.count != variant.count {
                throw ValidationError("Must specify --cryptex-variant for all cryptexes or none")
            }

            if !size.isEmpty, size.count != cryptexUrl.count {
                throw ValidationError("Must specify --cryptex-size for all cryptexes or none")
            }

            if !sha256.isEmpty, sha256.count != cryptexUrl.count {
                throw ValidationError("Must specify --cryptex-sha256 for all cryptexes or none")
            }

            if !auth.isEmpty, auth.count != cryptexUrl.count {
                throw ValidationError("Must specify --cryptex-authorization-service for all cryptexes or none")
            }

            if !identifier.isEmpty, identifier.count != cryptexUrl.count {
                throw ValidationError("Must specify --cryptex-identifier for all cryptexes or none")
            }

            if !identifier.isEmpty, Set(identifier).count < identifier.count {
                throw ValidationError("cryptex identifier must be unique")
            }
        }
    }

    struct PackageOptions: ParsableArguments {
        @Option(
            name: [.customShort("p"), .customLong("package")],
            help: "URL of the packages to install",
            transform: { try URL($0, strategy: .url) }
        )
        var packageUrl: [URL] = []

        var config: [DInitPackageConfig]? {
            guard !packageUrl.isEmpty else { return nil }
            return packageUrl.indices.map { index in
                DInitPackageConfig(url: packageUrl[index])
            }
        }
    }

    struct DiavloOptions: ParsableArguments {
        @Option(name: .customLong("diavlo-url"), help: "URL to the diavlo authorization server e.g. https://diavlo.apple.com")
        var serverURL: String?

        @Option(name: .customLong("diavlo-root-certificate"), help: "PEM encoded root certificate of the the diavlo authorization server")
        var rootCertificate: DInitData?

        @Flag(name: .customLong("diavlo-sign-using-apple-connect"), help: "Use AppleConnect credentials to trust the diavlo authorization server")
        var appleConnect: Bool = false

        var config: DInitDiavloConfig? {
            guard let serverURL = serverURL else { return nil }
            return DInitDiavloConfig(
                serverURL: serverURL,
                rootCertificate: rootCertificate,
                appleConnect: appleConnect)
        }

        func validate() throws {
            if serverURL == nil && rootCertificate != nil {
                throw ValidationError("Must not specify --diavlo-root-certificate without --diavlo-url")
            }
            if serverURL == nil && appleConnect {
                throw ValidationError("Must not specify --diavlo-sign-using-apple-connect without --diavlo-url")
            }
        }
    }

    struct ResultOptions: ParsableArguments {
        @Option(name: .customLong("failure-action"), help: "Set the trigger action for failures. Options reboot/shutdown")
        var failureAction: Config.Finish.FailureAction?

        var config: DInitResultConfig? {
            guard let failure = failureAction else { return nil }
            return DInitResultConfig(failureAction: failure)
        }
    }

    struct InstallOptions: ParsableArguments {
        @Option(name: .shortAndLong, help: "Causes darwin-init to delay before executing any install steps until the specified mount point has become available")
        var wait: String?

        @Option(name: [.customShort("B"), .long], help: .init("""
Shell script that will be executed before the root is installed. The script \
will be executed using customizable shell and may include files found \
on mount points that may not be in the base install (such as sumac -v).
"""))
        var preflight: String?

        @Option(name: [.customShort("T"), .long], help: .init("""
A complete path the shell that'll be used to executed preflight script. If not \
specified it defaults to /bin/bash. All preflights run under a shell.
"""))
        var preflightShell: String?

        @Option(name: .shortAndLong, help: .init("""
A root that will be passed to the darwinup command. This can be a URL. If it is \
a URL, it causes darwin-init to wait until the destination is reachable.
"""))
        var root: String?

        @Option(name: [.customShort("A"), .long], help: .init("""
Shell script that will be executed after the root is installed. The script \
will be executed using customizable shell. Script may include files that have \
been installed by the root.
"""))
        var postflight: String?


        @Option(name: [.customShort("S"), .long], help: .init("""
A complete path the shell that'll be used to executed postflight script. If not \
specified it defaults to /bin/bash. All postflights run under a shell.
"""))
        var postflightShell: String?

        @Flag(name: [.customShort("R"), .long], inversion: .prefixedNo, help: "Reboot the machine after the preflight, root install, and postflight")
        var reboot: Bool?

        @Option(name: [.customShort("U"), .long], help: "Reboot userspace after preflight, root install, and postflight. Use \"rem\" for Restricted Execution Mode. Use \"rem-dev\" for Restricted Execution Mode without blowing the fuse that enforces trust cache REM policy. This fuse state is attested to, so \"rem-dev\" is not useful in production deployments. Use an empty string (\"\") to disable userspace reboots on systems where it is the default.")
        var userspaceReboot: DInitUSR?

        var config: DInitInstallConfig? {
            guard wait != nil || preflight != nil || root != nil || postflight != nil else {
                return nil
            }
            return DInitInstallConfig(
                waitForVolume: wait,
                preflight: preflight,
                preflightShell: preflightShell,
                root: root,
                postflight: postflight,
                postflightShell: postflightShell)
        }

        func validate() throws {
            if reboot != nil && (preflight == nil && root == nil && postflight == nil) {
                throw ValidationError("Must not specify --reboot without at least one of --preflight, --root, or --postflight")
            }

            if preflightShell != nil && preflight == nil {
                throw ValidationError("Preflight shell specified, but not the preflight script")
            }

            if postflightShell != nil && postflight == nil {
                throw ValidationError("Postflight shell specified, but not the postflight script")
            }

        }
    }
    
    struct NetworkOptions: ParsableArguments {
        @Option(name: .customLong("network-interface"), help: "Name of interface to configure")
        var interface: [String] = []
        
        @Option(name: .customLong("network-configuration"), help: "Network configuration for the specified network interface given as a json.")
        var configuration: [JSON] = []
        
        var config: [DInitNetworkConfig]? {
            guard !interface.isEmpty else { return nil }
            return interface.indices.map { index in
                DInitNetworkConfig(
                    interface: interface[index],
                    value: configuration[index])
            }
        }
        
        func validate() throws {
            if interface.count != configuration.count {
                throw ValidationError("Must specify a --network-configuration for each --network-interface")
            }
        }
    }

    struct NarrativeIdentityOptions: ParsableArguments {
        @Option(name: .customLong("narrative-identity"), help: "Narrative Identity of format <domain>-<identitytype> to configure. Supported Identities are \(formatSupportedNarrativeIdentities())")
        var identity: [String] = []
        
        @Option(name: .customLong("narrative-options"), help: "Options specific to the narrative identity.")
        var option: [JSON] = []
        
        var config: [DInitNarrativeIdentitiesConfig]? {
            guard !identity.isEmpty else { return nil }
            return identity.indices.map { index in
                DInitNarrativeIdentitiesConfig(
                    identity : identity[index],
                    options: option[safe: index])
            }
        }
        
        func validate() throws {

            if identity.count < option.count  {
                throw ValidationError("Must specify --narrative-identity for all --narrative-options")
            }
            
            try identity.indices.forEach { index in
                
                let components = identity[index].components(separatedBy: "-")
                guard components.count == 2,
                      isNarrativeCertSupported(domain: components[0], identityType: components[1]) else {
                    throw ValidationError("Narrative Identity \(identity[index]) is not supported. Supported Identities are \(formatSupportedNarrativeIdentities())")
                }
            }
        }
    }
    
    struct PreferenceOptions: ParsableArguments {
        @Option(name: .customLong("preference"), help: "Preference key to update")
        var preference: [String] = []

        @Option(name: .customLong("preference-value"), help: "Preference value as json, use \"null\" to delete a preference.")
        var value: [JSON] = []

        @Option(name: .customLong("preference-application-id"), help: "Restrict preference domain by applicationId (default: kCFPreferencesAnyApplication)")
        var applicationId: [String] = []

        @Option(name: .customLong("preference-username"), help: "Restrict preference domain by user (default: kCFPreferencesAnyUser)")
        var userName: [String] = []

        @Option(name: .customLong("preference-hostname"), help: "Restrict preference domain by host (default: kCFPreferencesCurrentHost)")
        var hostName: [String] = []

        var config: [DInitPreferencesConfig]? {
            guard !preference.isEmpty else { return nil }
            return preference.indices.map { index in
                DInitPreferencesConfig(
                    key: preference[index],
                    value: value[index],
                    applicationId: applicationId[safe: index],
                    userName: userName[safe: index],
                    hostName: hostName[safe: index])
            }
        }

        func validate() throws {
            if preference.count != value.count {
                throw ValidationError("Must specify an equal number of --preference and --preference-value")
            }

            if !applicationId.isEmpty, applicationId.count != preference.count {
                throw ValidationError("Must specify --preference-application-id for all preferences or none")
            }

            if !userName.isEmpty, userName.count != preference.count {
                throw ValidationError("Must specify --preference-username for all preferences or none")
            }

            if !hostName.isEmpty, hostName.count != preference.count {
                throw ValidationError("Must specify --preference-hostname for all preferences or none")
            }
        }
    }

    struct UserOptions: ParsableArguments {
        @Option(name: .shortAndLong, help: "Specifies the \"username,uid,gid\" of a user")
        var user: DInitUserOptions?

        @Option(name: .shortAndLong, help: "Specifies the password of the user")
        var password: String?

        @Flag(name: .shortAndLong, inversion: .prefixedNo, help: "Specifies that the user should have admin privileges")
        var admin: Bool?

        @Flag(name: .shortAndLong, inversion: .prefixedNo, help: "Enable users of the admin group to be perform sudo operations without prompting for a password")
        var passwordlessSudo: Bool?

        @Option(
            name: .shortAndLong,
            help: "A file pointer to the ssh authorized_keys file containing at least one public key",
            transform: FilePath.init(_:)
        )
        var key: FilePath?

        @Option(name: .customLong("apple-connect-principal"), help: "AppleConnect principal that can be used to log into the account using SSH")
        var principals: [String] = []

        @Option(name: .customLong("apple-connect-group"), help: "AppleConnect group that can be used to log into the account using SSH")
        var groups: [String] = []

        var config: DInitUserConfig? {
            guard let user = user else { return nil }
            return DInitUserConfig(
                userName: user.username,
                uid: user.uid,
                gid: user.gid,
                password: password,
                isAdmin: admin,
                sshAuthorizedKeys: nil,
                passwordlessSudo: passwordlessSudo,
                appleConnectSSHConfig: (
                    (principals.count > 0 || groups.count > 0) ?
                    DInitAppleConnectSSHConfig(
                        principals: principals.count > 0 ? principals : nil,
                        groups: groups.count > 0 ? groups : nil) : nil
                )
            )
        }

        mutating func validate() throws {
            if user == nil {
                guard
                    password == nil,
                    admin == nil,
                    key == nil,
                    passwordlessSudo == nil,
                    principals.count == 0,
                    groups.count == 0
                else {
                    throw ValidationError("Must not specify --password, --admin, --passwordlessSudo, --key, --apple-connect-principal, or --apple-connect-group without --user")
                }
            }
        }
    }
    
    struct LogOptions: ParsableArguments {
        @Option(name: .customLong("system-log-privacy-level"), help: "Set the system log privacy level to one of 'Public', 'Private', or 'Sensitive'. Note: this will persist across reboots.")
        var systemLogPrivacyLevel: DInitSystemLogPrivacyLevel?
        
        @Option(name: .customLong("system-logging-enabled"), help: "Enable or disable system logging by setting to 'true' or 'false'.")
        var systemLoggingEnabled: Bool?
        
        var config: DInitLogConfig? {
            if systemLogPrivacyLevel == nil && systemLoggingEnabled == nil {
                return nil
            }
            return DInitLogConfig(
                systemLogPrivacyLevel: systemLogPrivacyLevel,
                systemLoggingEnabled: systemLoggingEnabled
            )
        }
    }
}
