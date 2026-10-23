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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import CoreAnalytics
import Foundation
import System

extension CLI.InstanceCmd {
    // InstanceCreateOptions contains command-line arguments shared between commands responsible for
    //  creating instances (certain items [such as name] remain closer to the implementation
    struct CreateOptions: ParsableArguments {
        @Option(name: [.customLong("release"), .customShort("R")],
                help: "SW Release Log index, or path to release metadata .json or .protobuf file. Release assets must be downloaded with `pccvre release download` prior to this.",
                completion: .file())
        var release: String?

        // SW releases are selected by <release> indexnum for given <logEnvironment>
        @Option(name: [.customLong("environment"), .customShort("E")],
                help: ArgumentHelp("SW Transparency Log environment.",
                                   visibility: .customerHidden))
        var logEnvironment: TransparencyLog.Environment = CLIDefaults.ktEnvironment

        @Option(name: [.customLong("osimage"), .customShort("O")],
                help: "Alternate Private Cloud Compute OS image path.",
                completion: .file(),
                transform: { try CLI.validateFilePath($0) })
        var osImage: String? // restore image

        @Option(name: [.customLong("variant")],
                help: """
                Specify variant for OS installation. (values: \(CLI.osVariants.joined(separator: ", "))
                default: \(CLI.defaultOSVariant))
                """,
                transform: { try CLI.validateOSVariant($0) })
        var osVariant: String?

        @Option(name: [.customLong("variant-name")],
                help: ArgumentHelp("Specify variant-name for OS installation.", visibility: .customerHidden))
        var osVariantName: String?

        @Option(name: [.customLong("fusing")],
                help: ArgumentHelp("Specify VRE instance fusing.", visibility: .customerHidden),
                transform: { try CLI.validateFusing($0) })
        var fusing: String = CLI.internalBuild ? "dev" : "prod"

        @Option(name: [.customLong("boot-args"), .customShort("B")],
                help: "Specify VRE boot-args (research variant only).",
                transform: { try CLI.validateNVRAMArgs($0) })
        var bootArgs: VRE.NVRAMArgs?

        @Option(name: [.customLong("nvram")],
                help: ArgumentHelp("Specify VRE nvram args.", visibility: .customerHidden),
                transform: { try CLI.validateNVRAMArgs($0) })
        var nvramArgs: VRE.NVRAMArgs?

        @Option(name: [.customLong("rom")],
                help: ArgumentHelp("Path to iBoot ROM image for VRE.", visibility: .customerHidden),
                completion: .file(),
                transform: { try CLI.validateFilePath($0) })
        var romImage: String?

        @Option(name: [.customLong("vseprom")],
                help: ArgumentHelp("Path to vSEP ROM image for VRE.", visibility: .customerHidden),
                completion: .file(),
                transform: { try CLI.validateFilePath($0) })
        var vsepImage: String?

        @Option(name: [.customLong("http-endpoint")],
                help: "Bind built-in HTTP service to <addr>[:<port>] or 'none'. (default: automatic)",
                transform: { try CLI.validateHTTPService($0) })
        var httpService: HTTPServer.Configuration? = .virtual(HTTPServer.Configuration.Virtual(mode: .nat))

        @Option(name: [.customShort("K"), .customLong("kernelcache")],
                help: "Custom kernel cache for VRE.",
                completion: .file(),
                transform: { try CLI.validateFilePath($0) })
        var kernelCache: String?

        @Option(name: [.customShort("S"), .customLong("sptm")],
                help: "Custom SPTM for VRE.",
                completion: .file(),
                transform: { try CLI.validateFilePath($0) })
        var sptmPath: String?

        @Option(name: [.customShort("M"), .customLong("txm")],
                help: "Custom TXM for VRE.",
                completion: .file(),
                transform: { try CLI.validateFilePath($0) })
        var txmPath: String?

        @Option(name: [.customLong("prkit")],
                help: ArgumentHelp("Path to PRKit plist for restore options.",
                                   visibility: .customerHidden),
                completion: .file(),
                transform: { try CLI.validateFilePath($0) })
        var prkitPath: String?

        @Flag(help: ArgumentHelp("Skip the release requirements check.",
                                 visibility: .customerHidden))
        var skipReleaseRequirementsCheck: Bool = false

        @Option(name: [.customLong("disk-size")],
                help: "Primary VM disk size in GiB (default: 64). Increase for larger releases such as TTS.")
        var diskSizeGB: UInt?

        func validate() throws {
            if osVariant != nil && osVariantName != nil {
                throw ValidationError("Only one of --variant or --variant-name can be specified.")
            }
        }
    }

    struct InstanceCreateCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new Virtual Research Environment instance.",
            discussion: """
            The standard flow for this command uses the configuration and assets
            provided within release metadata (using the --release option). After
            completing successfully, a VM has been created and restored with the
            configured OS image and left stopped.

            It's also possible to create a VRE instance using --osimage if --release
            is not used.

            Use the instance 'configure' command to manage individual cryptexes and
            replace darwin-init configuration.
            """
        )

        @OptionGroup var globalOptions: CLI.globalOptions
        @OptionGroup var createOptions: CLI.InstanceCmd.CreateOptions

        @Option(name: [.customLong("name"), .customShort("N")],
                help: "VRE instance name.",
                transform: { try CLI.validateVREName($0) })
        var vreName: String

        @Option(name: [.customLong("macaddr"), .customLong("mac")],
                help: "Specify network MAC address for VRE instance (xx:xx:xx:xx:xx:xx).",
                transform: { try CLI.validateMACAddress($0) })
        var macAddr: String?

        func run() async throws {
            CLI.logger.log("create VRE \(vreName, privacy: .public)")

            let instanceOptions = InstanceOptions(
                release: createOptions.release,
                skipReleaseRequirementsCheck: createOptions.skipReleaseRequirementsCheck,
                osImage: createOptions.osImage,
                osVariant: createOptions.osVariant,
                osVariantName: createOptions.osVariantName,
                fusing: createOptions.fusing,
                name: vreName,
                diskSizeGB: createOptions.diskSizeGB,
                networks: [
                    VRE.VMConfig.Network(mode: .nat, macAddr: macAddr),
                    VRE.VMConfig.Network(mode: .hostOnly)
                ],
                bootArgs: createOptions.bootArgs,
                nvramArgs: createOptions.nvramArgs,
                romImage: createOptions.romImage,
                vsepImage: createOptions.vsepImage,
                kernelCache: createOptions.kernelCache,
                sptmPath: createOptions.sptmPath,
                txmPath: createOptions.txmPath,
                prkitPath: createOptions.prkitPath
            )

            try CLI.validateRequiredMemoryToCreate(instanceOptions: [instanceOptions])

            // Synthesize all of the inputs to create a recipe for this instance.
            // Any cryptexes specified in the darwin-init must be accessible locally
            // prior to creating the instance (we will link/copy these to the instance
            // directory).
            _ = try CLI.createVREInstance(
                instanceOptions: instanceOptions,
                httpService: createOptions.httpService
            )
        }
    }
}

extension SWReleaseMetadata {
    init (
        release: String,
        logEnvironment: TransparencyLog.Environment,
        skipReleaseRequirementsCheck: Bool = false
    ) throws {
        var releaseMetadata: SWReleaseMetadata
        (releaseMetadata, _) = try CLI.fetchReleaseInfo(release: release, logEnvironment: logEnvironment)

        guard let _ = releaseMetadata.darwinInitString else {
            throw CLIError("unable to load darwin-init config from release info")
        }

        if !skipReleaseRequirementsCheck {
            try CLI.checkReleaseRequirements(metadata: releaseMetadata)
        }

        self = releaseMetadata
    }
}

extension CLI {
    static func createVREInstance(
        instanceOptions: InstanceOptions,
        httpService: HTTPServer.Configuration?,
        force: Bool = false
    ) throws -> VRE.Instance {
        if instanceOptions.diskSizeGB == 0 {
            throw CLIError("disk size must be greater than 0 GiB")
        }

        if VRE.Instance.exists(instanceOptions.name) {
            if force {
                let vre = try VRE.Instance(name: instanceOptions.name)
                if vre.isRunning {
                    throw CLIError("VRE '\(instanceOptions.name)' is running")
                }
                try vre.remove()
            } else {
                throw CLIError("VRE '\(instanceOptions.name)' already exists")
            }
        }

        let releaseMetadata = try instanceOptions.releaseMetadata

        var releaseAssets: [CryptexSpec] = if let releaseMetadata {
            try CLI.extractAssetsFromReleaseMetadata(releaseMetadata, altAssetSourceDir: instanceOptions.altAssetsDir)
        } else {
            []
        }

        let releaseID = releaseMetadata?.releaseHash.hexString ?? "-"

        var osVariant = instanceOptions.osVariant
        if let osImage = instanceOptions.osImage {
            if osVariant == nil || osVariant!.isEmpty,
               instanceOptions.osVariantName == nil || instanceOptions.osVariantName!.isEmpty
            {
                osVariant = CLI.defaultOSVariant
                print("Using default OS variant: \(osVariant!)")
                CLI.logger.log("using default OS variant: \(osVariant!, privacy: .public)")
            }

            if releaseAssets.count > 0 {
                // update ASSET_TYPE_OS with image/variant ultimately used
                try releaseAssets.append(CryptexSpec(
                    path: osImage,
                    variant: instanceOptions.osVariantName ?? osVariant ?? "Unknown",
                    assetType: SWReleaseMetadata.AssetType.os.label
                ))
            }
        }

        var vre = VRE.Instance(
            name: instanceOptions.name,
            releaseID: releaseID,
            httpService: httpService
        )

        var darwinInit = "" // start with "empty" darwin-init
        if let relDarwinInit = releaseMetadata?.darwinInitString {
            darwinInit = relDarwinInit
        }

        if let instanceDarwinInitOverrides = try instanceOptions.darwinInitOverridesString {
            // ensure we have PC host tools to handle the overrides
            _ = try vre.copyInstancePCTools(instanceAssets: releaseAssets)
            var darwinInitHelper = try DarwinInitHelper(config: darwinInit, pccvreHelper: vre.pccvreHelper())

            // get the list of cryptexes from the instance config - we will want to make sure we have copied
            // their assets
            let overrideDarwinInitHelper = try DarwinInitHelper(
                config: instanceDarwinInitOverrides,
                pccvreHelper: darwinInitHelper.pccvreHelper
            )
            // tolerate having some cryptexes with blank URL specified - we are not going to use them
            // any cryptexes that are getting removed using `MERGE_STRAT` _should_ have the URL set to ""
            let cryptexes = try overrideDarwinInitHelper.cryptexes().filter { $0.url != "" }
            let overrideCryptexes: [CryptexSpec] = try cryptexes.map {
                return try CryptexSpec(path: $0.url, variant: $0.variant)
            }
            CLI.logger.debug("Got cryptexes \(overrideCryptexes)")
            let copiedOverrideCryptexes = try vre.copyInstanceAssets(instanceAssets: overrideCryptexes)
            // merge the provided instance config onto the release darwin init
            try darwinInitHelper.mergeConfig(overrideDarwinInit: overrideDarwinInitHelper.configJSON)
            for cryptex in copiedOverrideCryptexes {
                if let assetBasename = cryptex.path.lastComponent?.string {
                    try darwinInitHelper.addCryptex(.init(variant: cryptex.variant, url: assetBasename))
                }
            }
            darwinInit = darwinInitHelper.configJSON
        }

        CLI.logger.debug("Create VRE instance with darwin-init:\(darwinInit, privacy: .public)")


        // create the VRE instance (and underlying VM) -- a restore is also performed on the
        //  new VM using the recipe we've crafted above from the input.
        do {
            try vre.create(
                vmConfig: instanceOptions.vmConfig,
                darwinInit: darwinInit,
                instanceAssets: releaseAssets
            )
        } catch {
            // if VRE/VM creation failed, attempt to save a copy of the vrevm logs
            let createErr = error
            if let savedLogs = try? CLI.copyVMLogs(vre: vre) {
                print("\nCopy of the VRE VM logs stored under: \(savedLogs.path)")
            }

            try? vre.remove()
            throw createErr
        }

        // Hostname is needed for ensembles. Don't try to modify darwin-init if there are no HOST_TOOLS.
        if var darwinInitHelper = try? vre.darwinInitHelper(),
           try darwinInitHelper.localHostname() == nil {
            try darwinInitHelper.setLocalHostname(randomHostname())
            try darwinInitHelper.save()
        }

        AnalyticsSendEventLazy("com.apple.securityresearch.pccvre.restored") {
            var eventReleaseID = releaseID
            if eventReleaseID.isEmpty || eventReleaseID == "-" {
                eventReleaseID = "unknown"
            }

            return [
                "version": eventReleaseID as NSString,
            ]
        }

        return vre
    }

    static func validateRequiredMemoryToCreate(instanceOptions: [InstanceOptions]) throws {
        let requiredMemoryGB = instanceOptions.map { $0.resolveNramGB() }.reduce(0) { (sum, mem) in sum + mem }
        // Assume that restore won't use all memory - don't account for host headroom and running instances.
        try Main.validateRequiredMemory(
            requiredMemoryGB: Int(requiredMemoryGB),
            consumedMemoryGB: 0
        )
    }
}

protocol SharedVREInstanceOptions: Codable {
    /// SW Release Log index
    var release: String? { get set }
    /// SW Transparency Log environment
    var transparencyLogEnvironment: TransparencyLog.Environment? { get set }
    /// Alternate Private Cloud Compute OS image path
    var osImage: String? { get set }
    /// Specify variant for OS installation
    var osVariant: String? { get set }
    /// Specify variant-name for OS installation
    var osVariantName: String? { get set }
    /// Specify VRE instance fusing
    var fusing: String? { get set }

    func validate() throws
}

struct InstanceOptions: SharedVREInstanceOptions {
    /// SW Release Log index
    var release: String?

    /// Skip the check whether release meets the requirements specified in release metadata
    var skipReleaseRequirementsCheck: Bool?

    /// SW Transparency Log environment
    var transparencyLogEnvironment: TransparencyLog.Environment?

    var osImage: String?

    var osVariant: String? = CLI.defaultOSVariant

    var osVariantName: String?

    var fusing: String?

    /// Name of the instance
    var name: String

    var ncpu: UInt?

    var nramGB: UInt?

    /// Primary VM disk size in GiB; nil uses the vrevm default (64).
    var diskSizeGB: UInt?

    var networks: [VRE.VMConfig.Network]? = [
        VRE.VMConfig.Network(mode: .nat, macAddr: nil),
        VRE.VMConfig.Network(mode: .hostOnly)
    ]

    var bootArgs: VRE.NVRAMArgs?

    var nvramArgs: VRE.NVRAMArgs?

    var romImage: String?

    var vsepImage: String?

    var kernelCache: String?

    var sptmPath: String?

    var txmPath: String?

    var prkitPath: String?

    /// Overrides for bits of darwin-init otherwise specified in release metadata
    var darwinInitOverrides: InstanceOptions.UnstructuredJSON?

    var darwinInitOverridesString: String? {
        get throws {
            if let darwinInitOverrides {
                let encoder = JSONEncoder()
                let data = try encoder.encode(darwinInitOverrides)
                return String(decoding: data, as: UTF8.self)
            } else {
                return nil
            }
        }
    }

    func validate() throws {
        _ = try osVariant.map { try CLI.validateOSVariant($0) }
        _ = try fusing.map { try CLI.validateFusing($0) }
        _ = try osImage.map { try CLI.validateFilePath($0) }
        _ = try romImage.map { try CLI.validateFilePath($0) }
        _ = try vsepImage.map { try CLI.validateFilePath($0) }
        _ = try kernelCache.map { try CLI.validateFilePath($0) }
        _ = try sptmPath.map { try CLI.validateFilePath($0) }
        _ = try txmPath.map { try CLI.validateFilePath($0) }
        _ = try prkitPath.map { try CLI.validateFilePath($0) }
        if osVariant != nil && osVariantName != nil {
            throw ValidationError("Only one of --variant or --variant-name can be specified.")
        }
    }

    var releaseMetadata: SWReleaseMetadata? {
        get throws {
            // we validate release to always be set when parsing the wrapping workload structure
            // or expect the release info to be passed in directly, but we don't require it for various CLI
            // instance creation workflows.
            if let release {
                try SWReleaseMetadata(
                    release: release,
                    logEnvironment: transparencyLogEnvironment ?? CLIDefaults.ktEnvironment,
                    skipReleaseRequirementsCheck: skipReleaseRequirementsCheck ?? false
                )
            } else {
                nil
            }
        }
    }

    var altAssetsDir: FilePath? {
        if let release, release.hasSuffix(".json") {
            FilePath(release).removingLastComponent()
        } else {
            nil
        }
    }
}

extension InstanceOptions {
    var vmConfig: VRE.VMConfig {
        .init(
            osImage: osImage,
            osVariant: osVariant,
            osVariantName: osVariantName,
            fusing: fusing,
            networks: networks ?? [],
            ncpu: ncpu,
            nramGB: resolveNramGB(),
            diskSizeGB: diskSizeGB,
            bootArgs: bootArgs,
            nvramArgs: nvramArgs,
            romImagePath: romImage,
            vsepImagePath: vsepImage,
            kernelCachePath: kernelCache,
            sptmPath: sptmPath,
            txmPath: txmPath,
            prkitPath: prkitPath
        )
    }
}

extension InstanceOptions {
    func resolveNramGB() -> UInt {
        // explicit config takes priority
        if let nramGB {
            return nramGB
        }

        let application = try? self.releaseMetadata?.application

        // ask pccvre-helper about memory requirements in the corresponding PCC release
        if let release,
           let helper = try? PCCVREHelper.configuredOrFromRelease(release),
           let requiredMemory = try? helper.requiredMemory(application: application) {
            return requiredMemory
        }

        // fallback to hard-coded defaults for older releases
        return (application == "TIE Proxy") ? 2 : 14
    }
}
