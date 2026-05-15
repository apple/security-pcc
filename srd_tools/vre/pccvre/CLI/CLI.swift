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

//  Copyright © 2024-2025 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import CloudAttestation
import Foundation
import Network
import OSPrivate_os_log
import System

struct CLI: AsyncParsableCommand {
    static var baseCommands: [any ParsableCommand.Type] = [
        LicenseCmd.self,
        ReleaseCmd.self,
        TransparencyLogCmd.self,
    ]
    static var otherCommands: [any ParsableCommand.Type] = [
        InstanceCmd.self,
        WorkloadCmd.self,
        EnsembleCmd.self,
        Image4Cmd.self,
        CryptexCmd.self,
        AttestationCmd.self,
    ]

    #if UTILITY
        static let subcommands = baseCommands
    #else
        static let subcommands = baseCommands + otherCommands
    #endif
    static var configuration = CommandConfiguration(
        commandName: commandName,
        abstract: "Private Cloud Compute Virtual Research Environment tool.",
        subcommands: subcommands
    )

    struct globalOptions: ParsableArguments {
        @Flag(name: [.customLong("debug"), .customShort("d")], help: "Enable debugging.")
        var debugEnable: Bool = false

        @Option(name: [.customLong("vrevm-path")],
                help: ArgumentHelp("Alternate path to 'vrevm' command.",
                                   visibility: .hidden))
        var vrevmPath: String?

        @Option(name: [.customLong("pccvre-helper")],
                help: ArgumentHelp("Alternate path to 'pccvre-helper' command.",
                                   visibility: .hidden))
        var helperPath: String?

        func validate() throws {
            CLI.setupDebugStderr(debugEnable: debugEnable)

            if let vrevmPath {
                guard FileManager.default.isExecutableFile(atPath: vrevmPath) else {
                    throw CLIError("executable not found")
                }
                // set default "vrevm" command path for all VRE VM activities
                _ = VRE(vrevmPath: vrevmPath)
            }

            if let helperPath {
                guard FileManager.default.isExecutableFile(atPath: helperPath) else {
                    throw CLIError("executable not found")
                }
                PCCVREHelper.configuredPath = helperPath
            }
        }
    }

    struct AttestationFormatOptions: ParsableArguments {
        @Option(name: [.customLong("input-format"), .customShort("I")],
                help: "Input format. Can be any of [attestation-bundle:json, attestation-bundle:protobuf, apple-intelligence-report]")
        var format: AttestationBundle.AttestationFormat = .appleIntelligenceReport

        @Option(name: [.customLong("request-index"), .customShort("r")],
                help: "Index of the request to use when parsing an Apple Intelligence Report. Must be used in combination with --attestation-index.")
        var requestIndex: Int?

        @Option(name: [.customLong("attestation-index"), .customShort("a")],
                help: "Index of the attestation to use when parsing an Apple Intelligence Report. Must be used in combination with --request-index.")
        var attestationIndex: Int?

        func validate() throws {
            guard case .appleIntelligenceReport = format else {
                return
            }

            if requestIndex == nil || attestationIndex == nil {
                throw ValidationError("Both --request-index and --attestation-index need to be supplied for --input-format apple-intelligence-report.")
            }
        }
    }
}

// Utility methods used by multiple commands
extension CLI {
    // commandDir returns directory containing this executable (or ".")
    static var commandDir: FilePath {
        let argv0 = FilePath(Bundle.main.executablePath!).removingLastComponent()
        if argv0.isEmpty {
            return FilePath(".")
        }

        return argv0
    }

    static let logger = os.Logger(subsystem: applicationName, category: "CLI")
    static var internalBuild: Bool { os_variant_allows_internal_security_policies(applicationName) }

    // setupDebugLogger configures log.debug messages to write to stderr when --debug enabled
    static func setupDebugStderr(debugEnable: Bool = false) {
        guard debugEnable else {
            return
        }

        var previous_hook: os_log_hook_t?
        previous_hook = os_log_set_hook(OSLogType.debug) { level, msg in
            // let msgCStr = os_log_copy_formatted_message(msg)
            if let subsystemCStr = msg?.pointee.subsystem,
               String(cString: subsystemCStr) == applicationName,
               let msgCStr = os_log_copy_decorated_message(level, msg)
            {
                fputs(String(cString: msgCStr), stderr)
                free(msgCStr)
                fflush(stderr)
            }

            previous_hook?(level, msg)
        }
    }

    // note writes msg with note prefix to stderr
    static func note(_ msg: String) {
        fputs("Note: \(msg)\n", stderr)
    }

    // warning writes msg with warning prefix to stderr
    static func warning(_ msg: String) {
        fputs("Warning: \(msg)\n", stderr)
    }

    // set stdout/err to linebuf for print()
    static func setOutputLineBuf() {
        setlinebuf(stdout)
        setlinebuf(stderr)
    }

    // confirmYN outputs "<prompt> (y/n) " and returns true if input starts with 'Y' or 'y'; else false
    static func confirmYN(prompt: String) -> Bool {
        print(prompt, terminator: " (y/n) ")
        if let yn = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).uppercased() {
            return yn.hasPrefix("Y")
        }

        return false
    }

    // fetchReleaseInfo takes a target release and extracts release info (containing list of image assets
    //   and darwin-init) and returns parsed info a set of assets (assumed to be previously downloaded).
    //   The release parameters takes the form of:
    //    - numeric: an index in Transparency Log (specified by logEnvironment) containing release metadata
    //    - pathname to a .json or .protobuf (or .pb) pathname containing the info to parse
    static func fetchReleaseInfo(release: String,
                                 logEnvironment: TransparencyLog.Environment = .production) throws ->
        (releaseInfo: SWReleaseMetadata, assets: [CryptexSpec])
    {
        var releaseMetadata: SWReleaseMetadata
        var altAssetsDir: FilePath?

        if let relIndex = UInt64(release) { // index number: look for release.json file (from "releases download")
            CLI.logger.log("lookup release index \(relIndex, privacy: .public)")
            if logEnvironment != .production {
                CLI.logger.log("using KT environment: \(logEnvironment.rawValue)")
            }

            var assetHelper: AssetHelper
            do {
                assetHelper = try AssetHelper(directory: CLIDefaults.assetsDirectory.path)
            } catch {
                throw CLIError("\(CLIDefaults.assetsDirectory.path): \(error)")
            }

            let relMD: SWReleaseMetadata
            do {
                (_, relMD) = try assetHelper.loadRelease(
                    index: relIndex,
                    logEnvironment: logEnvironment
                )
            } catch {
                let logmsg = "release lookup [\(logEnvironment):\(relIndex)]: \(error)"
                CLI.logger.error("\(logmsg, privacy: .public)")

                throw CLIError("SW Release info not found for index \(relIndex): have assets been downloaded?")
            }

            releaseMetadata = relMD
        } else if release.hasSuffix(".json") { // external release.json file
            do {
                releaseMetadata = try SWReleaseMetadata(from: FileManager.fileURL(release))
            } catch {
                throw CLIError("cannot load \(release): \(error)")
            }

            altAssetsDir = FilePath(release).removingLastComponent()
        } else if release.hasSuffix(".pb") || release.hasSuffix(".protobuf") { // external protobuf file
            do {
                let pbufdata = try Data(contentsOf: FileManager.fileURL(release))
                releaseMetadata = try SWReleaseMetadata(data: pbufdata)
            } catch {
                throw CLIError("cannot load \(release): \(error)")
            }
        } else {
            throw ValidationError("must provide release index or release.json file pathname")
        }

        let releaseAssets = try CLI.extractAssetsFromReleaseMetadata(releaseMetadata,
                                                                     altAssetSourceDir: altAssetsDir)

        return (releaseInfo: releaseMetadata, assets: releaseAssets)
    }

    // extractAssetsFromReleaseMetadata parses release metadata (json file) to obtain list of
    //  assets (os image, cryptexes, and types) along with their qualified pathname (relative to
    //  the json file), verified to exist
    static func extractAssetsFromReleaseMetadata(
        _ releaseMetadata: SWReleaseMetadata,
        altAssetSourceDir: FilePath? = nil
    ) throws -> [CryptexSpec] {
        // Extract the assets specified by the release metadata. For each asset, validate
        // that we can find it and determine the local path where it can be found.
        var releaseAssets: [CryptexSpec] = []
        if let osAsset = releaseMetadata.osAsset() {
            do {
                let assetPath = try CLI.expandAssetPath(osAsset,
                                                        altAssetSourceDir: altAssetSourceDir)
                try releaseAssets.append(CryptexSpec(
                    path: assetPath.string,
                    variant: osAsset.variant,
                    assetType: osAsset.type.label,
                    fileType: osAsset.fileType.assetFileType
                ))

                CLI.logger.log("OS release asset: \(assetPath.string, privacy: .public)")
            } catch {
                throw CLIError("asset '\(osAsset.url)' in release: \(error)")
            }
        }

        if let cryptexAssets = releaseMetadata.cryptexAssets() {
            for asset in cryptexAssets.values {
                do {
                    let assetPath = try CLI.expandAssetPath(asset,
                                                            altAssetSourceDir: altAssetSourceDir)
                    try releaseAssets.append(CryptexSpec(
                        path: assetPath.string,
                        variant: asset.variant,
                        assetType: asset.type.label
                    ))

                    CLI.logger.log("cryptex release asset: \(assetPath.string, privacy: .public)")
                } catch {
                    throw CLIError("asset '\(asset.url)' in release: \(error)")
                }
            }
        }

        if let toolsAsset = releaseMetadata.hostToolsAsset() {
            do {
                let assetPath = try CLI.expandAssetPath(toolsAsset,
                                                        altAssetSourceDir: altAssetSourceDir)
                try releaseAssets.append(CryptexSpec(
                    path: assetPath.string,
                    variant: toolsAsset.variant,
                    assetType: toolsAsset.type.label
                ))

                CLI.logger.log("host tools release image: \(assetPath.string, privacy: .public)")
            } catch {
                throw CLIError("asset '\(toolsAsset.url)' in release: \(error)")
            }
        }

        return releaseAssets
    }

    static func extractHostToolsAsset(release: String) throws -> FilePath {
        let info = try Self.fetchReleaseInfo(release: release, logEnvironment: CLIDefaults.ktEnvironment)
        guard let hostTools = info.assets.first(where: { $0.assetType == SWReleaseMetadata.AssetType.hostTools.label }) else {
            throw CLIError("Unable to find host tools in release assets")
        }
        return hostTools.path
    }

    // expandAssetPath searches for a SWReleaseMetadata.Asset (representing a release asset) in various
    //  locations - ensuring exists as a regular file - and returns the qualified pathname; if assetURL:
    //  - resemble full/partial pathname ("file" scheme containing a "/") relative to CWD
    //  - whose last component name exists under either altAssetSourceDir or CLIDefaults.assetsDirectory
    static func expandAssetPath(
        _ asset: SWReleaseMetadata.Asset,
        altAssetSourceDir: FilePath? = nil
    ) throws -> FilePath {
        let assetURL = URL(string: asset.url) ?? FileManager.fileURL(asset.url)

        // if resembles a file pathname (full or partial), use in situ (relative to CWD)
        if assetURL.scheme == "file", asset.url.contains("/") {
            do {
                let assetPath = try FileManager.fullyQualified(assetURL,
                                                               relative: FileManager.default.currentDirectoryPath,
                                                               resolve: true)
                guard FileManager.isRegularFile(assetPath) else {
                    throw CLIError("not a file")
                }

                return FilePath(assetPath.path)
            } catch {
                throw CLIError("\(error)")
            }
        }

        let assetName = assetURL.lastPathComponent

        // otherwise, check under altAssetSourceDir
        if let altAssetSourceDir,
           let assetPath = try? FileManager.fullyQualified(
               assetName,
               relative: altAssetSourceDir.string,
               resolve: true
           ),
           FileManager.isRegularFile(assetPath)
        {
            return FilePath(assetPath.path)
        }

        // .. or in pccvre assets folder
        do {
            let assetPath = try FileManager.fullyQualified(
                assetName,
                relative: CLIDefaults.assetsDirectory.path,
                resolve: true
            )

            guard FileManager.isRegularFile(assetPath) else {
                throw CLIError("not a file")
            }

            return FilePath(assetPath.path)
        } catch {
            throw CLIError("\(error)")
        }
    }

    // setupPCHostTools will either mount the specified toolsDMGPath (if provided) or
    //  the HOST_TOOLS asset associated with the VRE instance (which are mounted and
    //  copied into the instance area) -- the top-level directory containing the tools
    //  (which typically reside under <toolsDir>/usr/local/bin/) is returned, along with
    //  a callback to unmount toolsDMGPath (if provided)
    static func setupPCHostTools(
        _ vre: VRE.Instance,
        toolsDMGPath: String? = nil
    ) throws -> (mountDir: URL, unmountCallback: (() -> Void)?) {
        var toolsDir: URL
        var unmountCallback: (() -> Void)?

        if let toolsDMGPath {
            // caller-provided image: mount and use in place (don't unpack)
            CLI.logger.log("caller-provided tools DMG: \(toolsDMGPath, privacy: .public)")
            (toolsDir, unmountCallback) = try CLI.mountPCHostTools(vre: vre, dmgFile: toolsDMGPath)
        } else {
            toolsDir = try CLI.unpackPCTools(vre: vre)
        }

        return (mountDir: toolsDir, unmountCallback: unmountCallback)
    }

    // mountPCHostTools attempts to mount dmgFile (if provided) or the ".hostTools" asset (associated
    //  with a SW Release), expected to contain "tie-vre-cli" and "cloudremotediagctl". A URL of the
    //  mounted set of tools along with a callback pointer used to clean up mounted image(s).
    static func mountPCHostTools(
        vre: VRE.Instance,
        dmgFile: String? = nil
    ) throws -> (URL, () -> Void) {
        var toolsDMGPath: URL
        if let dmgFile {
            toolsDMGPath = FileManager.fileURL(dmgFile)
        } else {
            // if no tools DMG patch explicitly provided, look for HOST_TOOLS release asset
            guard let toolsAsset = vre.config.lookupAssetType(.hostTools) else {
                throw CLIError("no Host Tools DMG available (and no release asset found)")
            }

            toolsDMGPath = vre.cryptexFile(toolsAsset.file)
        }

        if !FileManager.isRegularFile(toolsDMGPath) {
            throw CLIError("\(toolsDMGPath): file not found")
        }

        var toolsDMGs: [CryptexHelper] = []
        // callback to tidy up mounts/temp dirs
        let unmountCallback = {
            for var dmg in toolsDMGs {
                try? dmg.eject()
            }
        }

        toolsDMGs = try VRE.mountPCHostTools(dmgPath: toolsDMGPath.path)
        guard let toolsMountDir = toolsDMGs.first?.mountPoint else {
            throw CLIError("unable to obtain Host Tools mountpoint")
        }

        CLI.logger.log("mountPCHostTools: mounted on \(toolsMountDir, privacy: .public)")
        return (toolsMountDir, unmountCallback)
    }

    // unpackPCTools mounts either the dmgFile or the ".hostTools" asset (from a SW Release)
    //  and copies the contents (use/ and System/ subdirs) into the "PCTools/" folder of the instance dir.
    //  A path URL to the fully-qualified PCTools/ folder is returned. If "PCTools/" already exists, it is
    //  assumed to already be unpacked and no further action taken.
    @discardableResult
    static func unpackPCTools(
        vre: VRE.Instance,
        dmgFile: String? = nil
    ) throws -> URL {
        if !vre.pcToolsUnpacked {
            CLI.logger.debug("unpackPCTools: not already unpacked; attempting to mount")
            let (toolsMountDir, unmountCallback) = try CLI.mountPCHostTools(vre: vre, dmgFile: dmgFile)

            CLI.logger.log("unpackPCTools: mounted on \(toolsMountDir, privacy: .public); copy into place")
            do {
                try vre.copyPCHostTools(mountPoint: toolsMountDir)
            } catch {
                throw CLIError("unable to copy in Host Tools for instance")
            }

            // done copying: clean up mounts
            CLI.logger.debug("unpackPCTools: running unmountCallback")
            unmountCallback()
        }

        CLI.logger.debug("unpackPCTools: using \(vre.pcToolsDir, privacy: .public)")
        return vre.pcToolsDir
    }

    // checkCloudboardAvailable returns true if cloud-board-health (from cloudremotediagctl indicates "healthy"),
    //  false otherwise -- error thrown if unable to complete call or parse result
    static func checkCloudboardAvailable(
        _ vre: VRE.Instance,
        toolsDir: URL
    ) throws -> Bool {
        let diagStatus = try vre.runCloudRemoteDiag(toolsDir: toolsDir, commandArgs: ["get-cloud-board-health"])

        // expecting result: {"CloudBoardHealthState":"healthy"} or {..: "unhealthy"}
        guard let diagStatusData = diagStatus.data(using: .utf8),
              let diagStatusJSON = try? JSONSerialization.jsonObject(with: diagStatusData,
                                                                     options: []) as? [String: String],
              let cbState = diagStatusJSON["CloudBoardHealthState"]
        else {
            throw CLIError("cloudremotediagctl: couldn't parse json result")
        }

        return cbState == "healthy"
    }

    // performInferenceRequest calls tie-vre-cli against specified hostname (IP) with prompt provided --
    //  the live results are output to stdout
    static func performInferenceRequest(
        toolsDir: URL, // (PCTools) folder containing tie-vre-cli and libraries
        hostname: String, // target hostname (typ IP address)
        prompt: String, // query
        maxTokens: Int = 100 // maximum tokens to generate
    ) throws {
        // tiePayload encodes the prompt within JSON payload expected by tie-vre-cli
        func tiePayload() throws -> String {
            guard let escapedPrompt = try String(data: JSONEncoder().encode(prompt), encoding: .utf8) else {
                throw CLIError("Unable to escape the prompt for JSON")
            }

            return #"""
            {
                "prompt_template": {
                    "prompt_template_v1": {
                        "prompt_template_id": "com.apple.gm.instruct.genericChat",
                        "prompt_template_variable_bindings": [
                            {
                                "name": "userPrompt",
                                "value": \#(escapedPrompt)
                            }
                        ]
                    }
                },
                "model_config": {
                    "model_name": "com.apple.fm.language.research.base",
                    "model_adaptor_name": "com.apple.fm.language.research.adapter",
                    "tokenizer_name": "com.apple.fm.language.research.tokenizer",
                    "options": {
                        "max_tokens": \#(maxTokens)
                    }
                }
            }
            """#
        }

        let envvars = [
            "DYLD_FRAMEWORK_PATH": "\(toolsDir.path)/System/Library/PrivateFrameworks/",
        ]

        let tieCMD = "tie-vre-cli"
        let tieCLI = "\(toolsDir.path)/usr/local/bin/\(tieCMD)"
        guard FileManager.isRegularFile(tieCLI) else {
            throw CLIError("Unable to find inference tool (\(tieCMD))")
        }

        let commandLine = try [
            tieCLI,
            "--hostname=\(hostname)",
            "--payload",
            tiePayload(),
        ]
        let logMsg = "TIE CLI call: [env: \(envvars)] \(commandLine.joined(separator: " "))"
        CLI.logger.log("\(logMsg, privacy: .public)")

        let (exitCode, _, _) = try ExecCommand(commandLine, envvars: envvars).run(
            outputMode: .terminal,
            queue: DispatchQueue(label: "\(applicationName).ExecCommand")
        )

        guard exitCode == 0 else {
            throw CLIError("exitCode=\(exitCode)")
        }
    }

    // copyVMLogs attempts to copy any collected logs for a vrevm VM instance (logs/) to a tempDirectory
    //  (or destDir/) -- typically called prior to wiping VM after a failed "instance create" command;
    //  the destination path is returned if successful
    static func copyVMLogs(
        vre: VRE.Instance,
        destDir altDest: String? = nil
    ) throws -> URL {
        let vminfo = vre.status()
        guard let vmBundleDir = vminfo.bundlepath else {
            throw CLIError("copyVMLogs: no bundle dir available for VM")
        }

        // obtain list of <vre.name>/logs/subdirs (if any)
        let vmLogsDir = FileManager.fileURL(vmBundleDir).appendingPathComponent("logs")
        let vmLogsSubs: [String]
        do {
            vmLogsSubs = try FileManager.default.contentsOfDirectory(atPath: vmLogsDir.path)
        } catch {
            throw CLIError("\(vmLogsDir.path): not found")
        }

        // setup destination folder (either provided or temp folder)
        var logDest: URL
        if let altDest {
            try FileManager.default.createDirectory(atPath: altDest, withIntermediateDirectories: true)
            logDest = FileManager.fileURL(altDest)
        } else {
            // .../com.apple.security-research.pccvre/logs/<vre.name>/...
            logDest = try FileManager.tempDirectory(subPath: applicationName, "logs", vre.name)
        }

        // copy each log subdir separately (as previous copies likely to be around)
        for logSubDir in vmLogsSubs {
            let logSubDir = vmLogsDir.appendingPathComponent(logSubDir)
            let logMsg = "\(logSubDir.path) -> \(logDest.path)"
            do {
                try FileManager.copyFile(logSubDir, logDest)
                CLI.logger.log("copyVMLogs: \(logMsg, privacy: .public)")
            } catch {
                CLI.logger.error("\(logMsg, privacy: .public): \(error)")
                throw CLIError("failed to copy VM logs")
            }
        }

        return logDest
    }
}

// CLI input validators
extension CLI {
    static let defaultOSVariant: String = "customer"

    static var osVariants: [String] {
        let publicVariants: [String] = [
            defaultOSVariant,
            "research",
        ]
        let internalVariants: [String] = [
            "internal-development",
            "internal-debug",
        ]

        return CLI.internalBuild ? publicVariants + internalVariants : publicVariants
    }

    static func parseURL(_ arg: String) throws -> URL {
        guard let url = URL.normalized(string: arg) else {
            throw ValidationError("invalid url")
        }

        return url
    }

    static func validateFilePath(_ arg: String) throws -> String {
        guard FileManager.isExist(arg, resolve: true) else {
            throw ValidationError("\(arg): not found")
        }

        guard FileManager.isRegularFile(arg, resolve: true) else {
            throw ValidationError("\(arg): not a file")
        }

        return arg
    }

    static func validateCryptexSpec(_ arg: String, relativeDir: String? = nil) throws -> CryptexSpec {
        let parg = arg.split(separator: ":", maxSplits: 2)
        guard parg.count == 2 else {
            throw ValidationError("invalid image spec; must be <variant>:<path>")
        }

        let pathURL: URL
        do {
            pathURL = try FileManager.fullyQualified(String(parg[1]), relative: relativeDir)
        } catch {
            throw ValidationError("\(parg[1]): \(error)")
        }

        return try CryptexSpec(path: pathURL.path, variant: String(parg[0]))
    }

    // validateVREName checks whether arg is a valid VRE instance name (no whitespace)
    static func validateVREName(_ arg: String) throws -> String {
        guard !arg.isEmpty,
              arg.unicodeScalars.allSatisfy({ CharacterSet.urlHostAllowed.contains($0) })
        else {
            throw ValidationError("invalid VRE name")
        }

        return arg
    }

    static func validateDirectoryPath(_ arg: String) throws -> FilePath {
        guard FileManager.isDirectory(arg) else {
            throw ValidationError("\(arg): not found or not a directory")
        }

        return FilePath(arg)
    }

    static func validateCryptexVariantName(_ arg: String) throws -> String {
        if arg.isEmpty {
            throw ValidationError("invalid variant name provided")
        }

        if arg.count > FILENAME_MAX {
            throw ValidationError("provided variant name exceeds max \(FILENAME_MAX)")
        }
        return arg
    }

    // validateMACAddresses validates a comma-separated list of mac addresses (in the form of hh:hh:hh:hh:hh:hh,
    //  empty, or "random") and returns array of validated entries -- empty elements represent unset
    static func validateMACAddresses(_ arg: String) throws -> [String] {
        var macAddrs: [String] = []
        for m in arg.components(separatedBy: ",") {
            if m.isEmpty || m == "random" {
                macAddrs.append("")
                continue
            }

            try macAddrs.append(CLI.validateMACAddress(m))
        }

        // check for dups
        let nonEmpty = macAddrs.compactMap { $0.isEmpty ? nil : $0 }
        guard Set(nonEmpty).count == nonEmpty.count else {
            throw ValidationError("duplicate specified")
        }

        return macAddrs
    }

    // validateMACAddress checks whether arg in the form of [hh:hh:hh:hh:hh:hh] and not all 00's or ff's;
    //  also gratuitously clear multicast bit and set locally-assigned bits (per 802.3)
    static func validateMACAddress(_ arg: String) throws -> String {
        var octs = arg.split(separator: ":", maxSplits: 5)
        guard octs.count == 6 else {
            throw ValidationError("invalid MAC address")
        }

        // ensure mac address has unicast and locally-assigned bits set appropriately
        var oct0 = UInt8(octs[0], radix: 16)!
        oct0 &= 0xfe // clear multicast
        oct0 |= 0x2 // set locally-assigned
        if oct0 != UInt8(octs[0], radix: 16)! {
            note("adjusting MAC address (multicast/locally-assigned)")
            octs[0] = Substring(String(format: "%02x", oct0))
        }

        var msum: UInt64 = 0
        for oct in octs {
            guard let oval = UInt8(oct, radix: 16) else {
                throw ValidationError("invalid MAC address")
            }

            msum += UInt64(oval)
        }

        // ensure not all 00's or ff's
        guard msum > 0 && msum < 1530 else {
            throw ValidationError("invalid MAC address")
        }

        return octs.joined(separator: ":").lowercased()
    }

    static func validateFusing(_ arg: String) throws -> String {
        switch arg {
        case "prod": break
        case "dev":
            guard CLI.internalBuild else {
                throw ValidationError("dev fusing not supported")
            }
        default:
            throw ValidationError("specified fusing: \(arg) not supported")
        }

        return arg
    }

    // validateNVramArgs parses arg as a set of whitespace separate NVram args (each of which
    // may be in the form of "key=value" or as simply "key"); returns VRE.nvramArgs map
    static func validateNVRAMArgs(_ arg: String) throws -> VRE.NVRAMArgs {
        var bootArgs: [String: String] = [:]
        for p in arg.components(separatedBy: .whitespacesAndNewlines) {
            let kv = p.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)

            if kv.count > 1 { // typical key=value
                bootArgs[String(kv[0])] = String(kv[1])
            } else { // otherwise, add bare token to args
                bootArgs[String(kv[0])] = ""
            }
        }

        return bootArgs
    }

    // validateHTTPService parses arg as VRE.httpService spec; forms:
    //   'none', '<ipaddr>', '<ipaddr>:<port>' or ':<port>'
    static func validateHTTPService(_ arg: String) throws -> HTTPServer.Configuration? {
        if arg == "none" {
            return nil
        }

        let httpBind = arg.split(separator: ":", maxSplits: 1)
        switch httpBind.count {
        case 1:
            // parse as IP addr (no port)
            guard let address = try? validateIPAddress(String(httpBind[0])) else {
                throw ValidationError("invalid http service addr")
            }

            return .network(HTTPServer.Configuration.Network(host: address))
        case 2:
            // <ip>:<port>
            let rawAddress = String(httpBind[0])
            if !rawAddress.isEmpty {
              guard let address = try? validateIPAddress(rawAddress) else {
                  throw ValidationError("invalid http service addr")
              }

              guard let port = UInt16(String(httpBind[1])), port > 0 else {
                  throw ValidationError("invalid http service port")
              }

              return .network(HTTPServer.Configuration.Network(host: address, port: port))
            } else {
              // or :<port>
              guard let port = UInt16(String(httpBind[1])), port > 0 else {
                  throw ValidationError("invalid http service port")
              }
              return .virtual(HTTPServer.Configuration.Virtual(mode: .nat, port: port))
            }
        default:
            throw ValidationError("invalid http service spec")
        }
    }

    // validateIPAddress parses arg as either an IPv4 or IPv6 address
    static func validateIPAddress(_ arg: String) throws -> NWEndpoint.Host {
        guard let host = NWEndpoint.Host(ipAddress: arg) else {
            throw ValidationError("invalid IP address")
        }
        return host
    }

    static func validateOSVariant(_ arg: String) throws -> String {
        if !CLI.osVariants.contains(arg) {
            throw ValidationError("invalid variant specified")
        }

        return arg
    }

    static func checkReleaseRequirements(metadata: SWReleaseMetadata) throws {
        let supportedFeatures: [String] = [
            "tie_proxy"
        ]

        let missingFeatures = metadata.metadata.requirements.filter {
            !supportedFeatures.contains($0.feature)
        }
        guard !missingFeatures.isEmpty else {
            return
        }

        var errorString = "This version of \(commandName) doesn't have the following features to support this release:"
        for feature in missingFeatures {
            errorString += "\n\(feature.feature) - \(feature.availability)"
        }
        throw CLIError(errorString)
    }
}

extension CloudAttestation.AttestationBundle.AttestationFormat: ExpressibleByArgument {
    init?(argument: String) {
        switch argument {
        case "attestation-bundle:json":
            self = .attestationBundle(.json)

        case "attestation-bundle:protobuf":
            self = .attestationBundle(.protobuf)

        case "apple-intelligence-report":
            self = .appleIntelligenceReport

        default:
            return nil
        }
    }
}

// Defaults provides global defaults from envvars or presets
//   CMDNAME_DEBUG:      Enable debugging
//   CMDNAME_ENV:        SW Transparency Log "environment" (internal only)
//   CMDNAME_ASSETS_DIR: Alt location to store downloaded release assets
//                          (def ~/Library/Caches/com.apple.security-research.pccvre/assets/)
//   CMDNAME_APPLICATION_DIR: Alt dir for pccvre application info (e.g. instances)
//                          (def ~/Library/Application Support/com.apple.security-research.pccvre/)
//
private let envPrefix = commandName.uppercased()

enum CLIDefaults {
    static var debugEnable: Bool {
        if let debugEnv = ProcessInfo().environment["\(envPrefix)_DEBUG"] {
            // false if starts with "n(o)", "f(alse)", "0", else true (if set)
            return !debugEnv.lowercased().starts(with: ["n", "f", "0"])
        }

        return false
    }

    static var ktEnvironment: TransparencyLog.Environment {
        if CLI.internalBuild {
            if let envEnv = ProcessInfo().environment["\(envPrefix)_ENV"] {
                if let env = TransparencyLog.Environment(rawValue: envEnv) {
                    return env
                }
            }
        }

        return .production
    }

    static var applicationDir: URL {
        if let dir = ProcessInfo().environment["\(envPrefix)_APPLICATION_DIR"] {
            return FileManager.fileURL(dir)
        } else {
            return URL.applicationSupportDirectory.appendingPathComponent(applicationName)
        }
    }

    static var customAssetFolder: Bool = false // true if using "alternate" (user) ASSETS_DIR envvar
    static var assetsDirectory: URL {
        if let assetsDirEnv = ProcessInfo().environment["\(envPrefix)_ASSETS_DIR"] {
            customAssetFolder = true
            return FileManager.fileURL(assetsDirEnv)
        }

        return URL.cachesDirectory.appendingPathComponent(applicationName).appendingPathComponent("assets")
    }

    static var cdnHostnameOverride: String? {
        guard let hostname = ProcessInfo().environment["\(envPrefix)_CDN_HOSTNAME_OVERRIDE"] else {
            return nil
        }

        guard hostname.wholeMatch(of: /^[A-Za-z0-9.-]+$/) != nil else {
            return nil
        }

        return hostname
    }
}

// CLIError provides general error encapsulation for errors encountered within CLI layer
struct CLIError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }

    init(_ message: String) {
        CLI.logger.error("\(message, privacy: .public)")
        self.message = message
    }
}
