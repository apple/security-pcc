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
//  Constants.swift
//  darwin-init
//

import Foundation
import System
import os

let kDInitNewUserShell = FilePath("/bin/zsh")
let kDInitDoneFilepath = FilePath("/var/db/.DarwinSetupDone")
let kDInitLogFilepath = FilePath("/var/db/.DarwinInitLog")
let kDInitPersistStorage = FilePath("/var/db/com.apple.darwininit")
let kDInitStatusFilepath = FilePath("/var/db/.DarwinSetupStatus")
let kDInitFirewallRulesPath = FilePath("/var/db/darwin-init/firewall/rules.pf")
let kDInitErrorReportFilepath = FilePath("/var/db/.DarwinErrorReport")
let kDInitSSHCAPublicKeyFilepath = FilePath("/etc/ssh/ca_key.pub")
let kDInitSSHCAAuthorizedPrincipalsDirectory = FilePath("/etc/ssh/authorized_principals/")
let kDInitValidatorBundle = "/usr/share/misc/darwin-init_validator_bundle"
// File loaded by /etc/ssh/sshd_config.d/200-darwininit.conf on tto allow DarwinInit to configure sshd at boot time
let kDInitSSHConfig = kDInitPersistStorage.appending("darwin-init-ssh.conf")
/// Memento SSH keys cache expiration time.
/// 2 hours to make cache useful while still be sensitive to server changes
let kDInitSSHPublicKeysCacheExpirationTime = TimeInterval(2 * 60 * 60)
// sshd config which enables PasswordAuthentication when written to kDInitSSHConfig
let kDInitSSHConfigPWAuthEnabled = """
    PasswordAuthentication yes
    ChallengeResponseAuthentication yes

    """
// sshd config which disables PasswordAuthentication when written to kDInitSSHConfig
let kDInitSSHConfigPWAuthDisabled = """
    PasswordAuthentication no
    ChallengeResponseAuthentication no

    """
let kDInitSSHConfigCAAuth = """
    TrustedUserCAKeys file:\(kDInitSSHCAPublicKeyFilepath.string)
    AuthorizedPrincipalsFile \(kDInitSSHCAAuthorizedPrincipalsDirectory.string)/%u

    """
let kDInitSSHConfigEmpty = "\n".data(using: .utf8)!

let kDInitNVRAMConfigLegacyKey = "darwininit"
/// static URL at which `User Data` from EC2 Instance Metadata Service is reachable
let kDInitEC2UserDataURL = URL(
    string: "http://169.254.169.254/latest/user-data/"
)!
/// static URL at which IMDSv2 token is reachable
let kDInitImdsTokenURL = URL(string: "http://169.254.169.254/latest/api/token")!
/// Header name for IMDSv2 token session ttl when GETing EC2 User Data
let kDInitImdsTokenTtlSecondsHeaderName = "X-aws-ec2-metadata-token-ttl-seconds"
/// Header name for IMDSv2 token when GETing EC2 User Data
let kDInitImdsTokenHeaderName = "X-aws-ec2-metadata-token"
/// Default IMDSv2 token ttl
let kDInitDefaultImdsTokenTtlSeconds = 5
/// Maximum IMDSv2 token ttl
let kDInitMaxImdsTokenTtlSeconds = 6 * 3600
let kDInitEC2Prefix = "ec2imds="
let kDInitDefaultSleepBeforeFailureAction: Duration = .seconds(60)
let kDInitSleepBeforeFailureActionOnLoadFailure: Duration = .seconds(3600)

/// the URL to get the parameters to apply for prod fused BMCs
let kDInitDataCenterBootstrapServer = URL(
    string: "https://dc-bss.apple.com/v2"
)!

let kDInitDataCenterBootstrapServerFallback = URL(
    string: "https://dc-bss.apple.com/v1"
)!

let kDInitTestBootstrapServerFallback = URL(
    string: "http://192.168.64.1/"
)!

let kDInitTestBootstrapServerNVRAMKey = "DCBSS"


enum DataCenterRegionCode: Int32, Sendable {
    case reserved = 0
    case internalTest = 100
}

/// The file to create on disk to enable users in the `admin` group to perform `sudo` operations
/// without being prompted for a password.
let kDInitPasswordlessSuodersFile = (
    path: FilePath("/etc/sudoers.d/01-admin-group"),
    contents: "%admin ALL=(ALL) NOPASSWD:ALL"
)

let kDInitAppleConnectRealm = "APPLECONNECT.APPLE.COM"

let kDInitRemoteServicePrefix = "remotedevice="
let kDInitRemoteServiceName = "com.apple.darwininit.config-server"
let kDInitFactoryRemoteServiceName = "com.apple.factory.darwininit.config-server.remote"

/// The "knox" scheme
let kKnoxURLScheme = "knox"

/// Convenience constant: ``knoxURLScheme`` + "://"
let kKnoxURLPrefix = "\(kKnoxURLScheme)://"

let kDefaultKnoxURL = URL(string: "https://knox.sd.apple.com")!

let kAppleArchiveExtension = "aar"

let kUsageLabelKey = "serverOS-usage-label"

let kCustomerLogPolicyPath =
    "/private/var/PrivateCloudSupport/opt/audit-lists/customer/"
let kCarryLogPolicyPath =
    "/private/var/PrivateCloudSupport/opt/audit-lists/carry/"

// FIXME: remove and use SIOCGIFLINKPARAMS and SIOCSIFLINKPARAMS in Network.swift once rdar://127317411 (Expose vars for getting the values of SIOCGIFLINKPARAMS and SIOCSIFLINKPARAMS) lands
let kSIOCGIFLINKPARAMS: UInt = 0xc0f0_6992
let kSIOCSIFLINKPARAMS: UInt = 0xc0f0_6991

let kUplinkInterfaceAppID = "com.apple.acdc.networking"
let kUplinkInterfaceKey = "interfaces.uplink.bsdName"

let kMantaRemoteAgentdBundleId = "com.apple.Manta.mantaremoteagentd"
let kUplinkMTUHintKey = "uplinkmtu"

// Taken from Manta. Keep in sync with schema.json.
let kUplinkMTUMin = 1280
let kUplinkMTUMax = 16384

// Chunk size for making range requests to the CDN in bytes
let kCDNChunkSize: UInt64 = 16 << 20  // 16 MiB = 16 * 2^(20) bytes
// Max number of active tasks to perform range requests in parallel
let kMaxActiveTasks: Int = 4

#if os(macOS)
    let kDarwinInitCacheRootDirectory: FilePath =
        "/System/Volumes/Preboot/DarwinInitCache"
#else
    let kDarwinInitCacheRootDirectory: FilePath =
        "/private/preboot/DarwinInitCache"
#endif

#if os(macOS)
    let kCacheVolumeKeyCacheRootDirectory: FilePath =
        "/System/Volumes/Preboot/DarwinInitCache/CacheVolumeKeys"
#else
    let kCacheVolumeKeyCacheRootDirectory: FilePath =
        "/private/preboot/DarwinInitCache/CacheVolumeKeys"
#endif

#if os(watchOS)
let kDefaultCryptexCacheMaxTotalSize: Int = Int.max / 2
#else
let kDefaultCryptexCacheMaxTotalSize: Int = (256 * 1024 * 1024 * 1024)
#endif

let kDefaultCryptexDownloadRetries: UInt = 5
let kDefaultCryptexMaxActiveTasks: Int = 4

let kDiavloServerLocation = "https://diavlo.apple.com"

let kDefaultApplyTimeout: Duration = .seconds(60) * 30

let kTailspinDefaultBufferSize: size_t = 50

// We can get rid of this hardcoded builtin cryptex list once rdar://165792764 lands
let kBuiltinCryptexIdentifiers = ["com.apple.ServerRestoreSupport"]

public let logger = Logger.default

extension Logger {
    static let subsystem = "com.apple.darwin-init"

    static let `default` = Logger(category: "")
    static let filesystem = Logger(category: "filesystem")
    static let libcryptex = Logger(category: "libcryptex")
    static let network = Logger(category: "network")
    static let subprocess = Logger(category: "subprocess")
    static let package = Logger(category: "package")
    static let esc = Logger(category: "esc")
    static let ldap = Logger(category: "ldap")
    static let cryptexcache = Logger(category: "cryptexcache")
    static let caching = Logger(category: "caching")
    static let knoxClient = Logger(category: "KnoxClient")
    static let privateCloudOSValidator = Logger(
        category: "PrivateCloudOSValidator"
    )
    static let pccRegoValidator = Logger(
        category: "PCCRegoValidator"
    )

    init(category: String) {
        self.init(subsystem: Self.subsystem, category: category)
    }
}
