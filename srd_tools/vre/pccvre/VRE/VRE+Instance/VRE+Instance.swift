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

// VRE.Instance provides implementation of instances specific to Transparency Log releases.
//  This sits atop VMs provided through the "vrevm" utility.

import Foundation
import System

extension VRE {
    struct Instance {
        let name: String
        var config: VREInstanceConfiguration
        let vm: VRE.VM

        // directory contains the full path of the named instance bundle:
        //  - instance.plist config
        //  - darwin-init.json
        //  - disk images/cryptexes used to (re)create the instance VM
        var directory: URL { VRE.instanceDir(name) }

        // configFile contains the full path of the named instance config plist
        static let configFilename = "instance.plist"
        static func configFile(_ name: String) -> URL {
            VRE.instanceDir(name).appending(path: VRE.Instance.configFilename)
        }

        var configFile: URL { Instance.configFile(name) }

        // darwinInitFile contains the full path of the working darwin-init.json file;
        //  it is passed into the VM upon starting
        static let darwinInitFilename = "darwin-init.json"
        static func darwinInitFile(_ name: String) -> URL {
            VRE.instanceDir(name).appending(path: darwinInitFilename)
        }

        var darwinInitFile: URL { VRE.Instance.darwinInitFile(name) }

        // cryptexFile returns a pathname of a cryptex image file relative to the VRE instance
        //  (only the last component of path is used)
        static func cryptexFile(_ name: String, path: String) -> URL {
            return VRE.instanceDir(name).appending(path: FileManager.fileURL(path).lastPathComponent)
        }

        func cryptexFile(_ path: String) -> URL { VRE.Instance.cryptexFile(name, path: path) }

        // pcToolsDir is the designated directory containing an unpacked Private Cloud (Host) Tools,
        //  used for making inference requests (tie-vre-cli)
        static let pcToolsDirname = "PCTools"
        static func pcToolsDir(_ name: String) -> URL {
            VRE.instanceDir(name).appending(path: pcToolsDirname)
        }

        var pcToolsDir: URL { VRE.Instance.pcToolsDir(name) }

        // pcToolsUnpacked is true if PCTools/ exists (implying TIE inference tools unpacked)
        var pcToolsUnpacked: Bool { FileManager.isDirectory(pcToolsDir) }

        // exists returns true if the instanceDir exists
        static func exists(_ name: String) -> Bool {
            FileManager.isExist(VRE.instanceDir(name))
        }

        var exists: Bool { VRE.Instance.exists(name) }

        // isRunning returns true if underlying VM appears to be running (locked)
        var isRunning: Bool { vm.isRunning }

        // protectedInstanceFiles is list of entries to guard against overwriting (with cryptex images)
        static let protectedInstanceFiles = [VRE.Instance.configFilename,
                                             VRE.Instance.darwinInitFilename,
                                             VRE.Instance.pcToolsDirname]

        // initialize new VRE instance in memory
        init(
            name: String,
            releaseID: String,
            httpService: HTTPServer.Configuration?
        ) {
            self.name = name
            config = VREInstanceConfiguration(
                name: name,
                releaseID: releaseID,
                httpService: httpService
            )

            vm = VRE.VM(name: name)
        }

        // load VRE instance from existing instance.plist file
        init(name: String) throws {
            guard VRE.Instance.exists(name) else {
                throw VREError("VRE instance '\(name)' does not exist")
            }

            self.name = name

            vm = VRE.VM(name: name)
            config = try VREInstanceConfiguration(
                contentsOf: Instance.configFile(name)
            )
        }

        // darwinInitHelper returns a DarwinInitHelper object for the instance's darwin-init.json config
        func darwinInitHelper() throws -> DarwinInitHelper {
            guard let darwinInit = try? DarwinInitHelper(configFile: darwinInitFile.path,
                                                         pccvreHelper: try pccvreHelper()) else {
                throw VREError("invalid darwin-init.json file")
            }

            return darwinInit
        }

        func pccvreHelper() throws -> PCCVREHelper {
            let toolsDir = try CLI.unpackPCTools(vre: self)
            return PCCVREHelper.configuredOrInToolsDir(toolsDir)
        }

        // create writes a new VRE instance on the file system and creates the underlying VM.
        //  - name instance folder created (removed upon any errors)
        //  - cryptexes enumerated in instanceAssets are hard-linked (or copied) in
        //  - create (VRE+Config) instance.plist file
        //  - create darwin-init.json file (from darwinInit parameter)
        //  - create & restore VM (vrevm create) from vmConfig
        mutating func create(
            vmConfig: VMConfig, // base configuration with which to create a VM
            darwinInit: String,
            instanceAssets: [CryptexSpec] // items to copy in
        ) throws {

            if let _ = try? vm.status() {
                throw VREError("VRE VM \(name) already exists")
            }

            do {
                try Globals.computer.fileSystem.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw VREError("cannot create instance folder: \(error)")
            }

            let copiedAssets = try copyInstanceAssets(instanceAssets: instanceAssets)

            var vmConfig = vmConfig
            // set osImage/variant from release info (unless passed in by caller)
            if vmConfig.osImage == nil {
                guard let osAsset = config.lookupAssetType(.os) else {
                    throw VREError("no OS restore image defined")
                }

                vmConfig.osImage = cryptexFile(osAsset.file).path
                if vmConfig.osVariantName == nil {
                    vmConfig.osVariantName = osAsset.variant
                }
            }

            vmConfig.darwinInitPath = darwinInitFile.path

            // Only use DarwinInitHelper (which requires HOST_TOOLS via pccvreHelper)
            // if there are cryptex assets to populate in the darwin-init config.
            let hasCryptexAssets = copiedAssets.contains {
                $0.assetType != SWReleaseMetadata.AssetType.os.label &&
                $0.assetType != SWReleaseMetadata.AssetType.hostTools.label
            }
            if hasCryptexAssets {
                var darwinInitHelper = try DarwinInitHelper(config: darwinInit, pccvreHelper: pccvreHelper())
                try darwinInitHelper.populateReleaseCryptexes(assets: copiedAssets)
                try darwinInitHelper.save(toFile: darwinInitFile.path)
            } else {
                config.httpService = nil
                try darwinInit.write(toFile: darwinInitFile.path, atomically: true, encoding: .utf8)
            }

            do {
                try config.write(to: configFile)
            } catch {
                throw VREError("save config into VRE area: \(error)")
            }

            do {
                try vm.create(config: vmConfig)
            } catch {
                throw VREError("VM creation failed: \(error)")
            }
        }

        mutating func copyInstancePCTools(
            instanceAssets: [CryptexSpec] // items to copy in
        ) throws -> [CryptexSpec] {
            try copyInstanceAssets(instanceAssets: instanceAssets.filter { $0.assetType == "ASSET_TYPE_HOST_TOOLS" })
        }

        mutating func copyInstanceAssets(
            instanceAssets: [CryptexSpec] // items to copy in
        ) throws -> [CryptexSpec] {
            do {
                try Globals.computer.fileSystem.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw VREError("cannot create instance folder: \(error)")
            }
            // for all cryptex assets (from release metadata):
            // - save reference to those with an ASSET_TYPE_XX in the config
            // - link/copy into instance directory
            // - copiedAssets contains instanceAssets with updated pathnames copied into instance area
            var copiedAssets: [CryptexSpec] = []
            for asset in instanceAssets {
                do {
                    let dstCryptexPath = try copyInImage(asset.path.string, fileType: asset.fileType)
                    if let assetType = asset.assetType {
                        config.addReleaseAsset(
                            type: assetType,
                            file: dstCryptexPath.path,
                            variant: asset.variant
                        )
                    }

                    try copiedAssets.append(
                        CryptexSpec(path: dstCryptexPath.path,
                                    variant: asset.variant,
                                    assetType: asset.assetType))
                } catch {
                    throw VREError("copy asset into VRE area: \(error)")
                }
            }
            return copiedAssets
        }

        // remove deletes associated instance VM and instance config
        func remove() throws {
            VRE.logger.log("remove VRE instance: \(name, privacy: .public)")
            do {
                do {
                    try vm.remove()
                } catch {
                    VRE.logger.error("remove VM: \(error, privacy: .public)")
                    // fall through
                }

                try Globals.computer.fileSystem.removeItem(at: directory)
            } catch {
                throw VREError("remove VRE instance folder: \(error)")
            }
        }

        // status returns information from the underlying VM (from vrevm --list --json)
        func status() -> VMStatus {
            if let status = try? vm.status() {
                return status
            }

            return VMStatus(name: name, state: "invalid")
        }

        // start launches instance VM (in the foreground);
        // under the instances/<vrename>/
        // - ensure darwin-init.json present
        // - configure & start http service
        // - update an ephemeral copy of darwin-init
        // - start VM (via vrevm), passing in updated (ephemeral) darwin-init
        // - block while VM running
        func start(
            quietMode: Bool = false // pass --quiet to vrevm
        ) async throws {
            VRE.logger.log("start VRE instance: \(name, privacy: .public)")
            guard let vmStatus = try? vm.status(), let vmState = vmStatus.state else {
                throw VREError("VRE VM not found")
            }

            guard vmState != "running" else {
                throw VREError("VRE VM currently running")
            }

            var updatedDarwinInit: DarwinInitHelper? = nil
            var httpServer: HTTPServer?
            if let httpConfig = config.httpService {
                var darwinInit = try darwinInitHelper()
                httpServer = try await HTTPServer.start(httpConfig, accessPath: FilePath(directory.path))

                let bindAddr = String(describing: httpServer!.host)
                print("HTTP service started: \(bindAddr):\(httpServer!.port ?? .zero)")

                try darwinInit.updateLocalCryptexURLs(httpServer: httpServer!)
                updatedDarwinInit = darwinInit
            }

            defer {
                if let httpServer {
                    do {
                        try httpServer.shutdown()
                    } catch {
                        VRE.logger.error("shutdown http service: \(error, privacy: .public)")
                        // fall through
                    }
                }
            }

            // write out darwin-init with local updates for this session only
            let runningDarwinInitPath: String
            do {
                runningDarwinInitPath = try FileManager.tempDirectory(
                    subPath: applicationName, UUID().uuidString
                ).appendingPathComponent("darwin-init.json").path
                VRE.logger.debug("temp darwin-init: \(runningDarwinInitPath, privacy: .public)")
            } catch {
                throw VREError("create temp dir: \(error)")
            }

            defer {
                do {
                    try Globals.computer.fileSystem.removeItem(atPath: runningDarwinInitPath)
                } catch {
                    VRE.logger.error("remove temp file \(runningDarwinInitPath, privacy: .public): \(error, privacy: .public)")
                }
            }

            do {
                if let updatedDarwinInit {
                    try updatedDarwinInit.save(toFile: runningDarwinInitPath)
                } else {
                    try Globals.computer.fileSystem.copyItem(
                        at: darwinInitFile,
                        to: URL(fileURLWithPath: runningDarwinInitPath)
                    )
                }
            } catch {
                throw VREError("temp copy of darwin-init: \(error)")
            }

            // blocks while running
            do {
                try vm.start(darwinInit: runningDarwinInitPath, quietMode: quietMode)
            } catch {
                throw VREError("start VM: \(error)")
            }
        }

        // runCloudRemoteDiag executes a cloudremotediagctl command (typically distributed within the
        //   Private Cloud host-side tools) and returns the output (typically expected to be json)
        func runCloudRemoteDiag(
            toolsDir: URL? = nil, // pcToolsDir by default
            commandArgs: [String] // sub commands (--device arg already provided)
        ) throws -> String {
            let toolsDir = toolsDir ?? pcToolsDir
            let diagCmd = "cloudremotediagctl"
            let diagCmdPath = "\(toolsDir.path)/usr/local/bin/\(diagCmd)"

            guard FileManager.isExecutable(diagCmdPath) else {
                throw VREError("\(diagCmd) command not available")
            }

            var rsdName: String // cloudremotediag must have --device arg

            // .. even for "help" command
            if commandArgs.first == "help" {
                rsdName = "none"
            } else {
                guard let _rsdName = status().rsdname else {
                    throw VREError("cannot determine rsd name (or not yet available)")
                }

                rsdName = _rsdName
            }

            let commandLine = [diagCmdPath, "--device=\(rsdName)"] + commandArgs
            let logMsg = "cloudremotediagctl call: \(commandLine.joined(separator: " "))"
            CLI.logger.log("\(logMsg, privacy: .public)")

            let (exitCode, stdOutput, stdError) = try ExecCommand(commandLine).run(
                outputMode: .capture,
                queue: DispatchQueue(label: "\(applicationName).ExecCommand")
            )

            guard exitCode == 0 else {
                if !stdError.isEmpty {
                    VRE.logger.error("cloudremotediagctl error: \(stdError, privacy: .public)")
                }

                throw VREError("cloudremotediagctl returned exitCode=\(exitCode)")
            }

            VRE.logger.log("cloudremotediagctl result: \(stdOutput, privacy: .public)")
            return stdOutput
        }

        // configureSSH adds configuration to darwin-init to enable SSH access:
        //  if enabled == true
        //    - add cryptex containing SSH service (either specified shellCryptex or the "DEBUG_SHELL"
        //        asset from release metadata info if available)
        //      - skip adding the "os" asset if variant name contains " internal "
        //    - add user{root:0:0} stanza containing publicKey (only one supported)
        //    - set "ssh: true"
        //    - can be "enabled" again to update public key
        //  if enabled == false
        //    - remove shellCryptex (if known)
        //    - set "ssh: false"
        //    - remove user{} stanza
        func configureSSH(
            enabled: Bool = true,
            publicKey: String? = nil,
            shellCryptex: CryptexSpec? = nil
        ) throws {
            VRE.logger.log("configure SSH for VRE \(name) (enabled: \(enabled, format: .answer, privacy: .public))")

            // prefix to use for disabling/reenabling darwin-init security policy keys
            var darwinInit = try darwinInitHelper()

            if !enabled {
                if let shellAsset = config.lookupAssetType(.debugShell) {
                    try darwinInit.removeCryptex(variant: shellAsset.variant)
                }

                try darwinInit.disableSSH()

                try darwinInit.save()
                return
            }

            guard let publicKey else {
                throw VREError("public key not provided")
            }

            // try to determine whether we started with an " internal " variant
            var internalVariant = false
            if let osAsset = config.lookupAssetType(.os) {
                internalVariant = osAsset.variant.lowercased().contains(" internal ")
            }

            if !internalVariant { // skip adding "shell" cryptex for "internal" variants
                if let shellCryptex {
                    // if cryptex specified by caller, use it
                    do {
                        let dstShellCryptex = try copyInImage(shellCryptex.path.string)
                        try darwinInit.addCryptex(
                            .init(
                                variant: shellCryptex.variant,
                                url: dstShellCryptex.lastPathComponent
                            )
                        )
                    } catch {
                        throw VREError("copy cryptex to VRE instance directory: \(error)")
                    }
                } else if let shellAsset = config.lookupAssetType(.debugShell) {
                    // otherwise check if AssetType.debugShell available to the instance (for non-Internal builds)
                    try darwinInit.addCryptex(.init(
                        variant: shellAsset.variant,
                        url: shellAsset.file
                    ))
                } else {
                    VRE.logger.log("no shell cryptex provided - ssh may not be available")
                }
            }

            try darwinInit.enableSSH(sshPubKey: publicKey)

            try darwinInit.save()
        }

        // copyInImage checks src exists (as a regular file), does not overwrite any "protected" files,
        //  and (if overwrite enable) ensures existing destination (if present) is removed prior to
        //  either hard-linking or copying in. A filename extension is appended as needed based on the
        //  file type (dmg, ipsw, aar). The final destination URL is returned upon success.
        func copyInImage(
            _ src: String,
            fileType: AssetHelper.FileType? = nil,
            dstName: String? = nil,
            overwrite: Bool = false
        ) throws -> URL {
            let srcURL = FileManager.fileURL(src)
            var dstName = dstName ?? srcURL.lastPathComponent

            guard FileManager.isExist(src, resolve: true) else {
                throw VREError("\(src): does not exist")
            }
            guard FileManager.isRegularFile(src, resolve: true) else {
                throw VREError("\(src): not a file")
            }

            // don't allow clobbering of instance.plist, darwin-init.json, etc
            guard !VRE.Instance.protectedInstanceFiles.contains(dstName) else {
                throw VREError("cannot overwrite \(dstName)")
            }

            let imageFileType: AssetHelper.FileType
            if let fileType {
                imageFileType = fileType
            } else {
                // determine image type (based on header)
                do {
                    imageFileType = try AssetHelper.fileType(srcURL)
                } catch {
                    throw VREError("\(src): image type: \(error)")
                }
            }

            // .. and append an appropriate .extension as needed
            let srcExt = srcURL.pathExtension.lowercased()
            let addExt = switch imageFileType {
            case .targz:
                ![imageFileType.ext, "tgz"].contains(srcExt)
            default:
                !imageFileType.ext.isEmpty && srcExt != imageFileType.ext
            }

            if addExt {
                dstName += "." + imageFileType.ext
            }

            // derive destination path
            let dst = cryptexFile(dstName)
            if FileManager.isExist(dst, resolve: true) {
                if overwrite {
                    try Globals.computer.fileSystem.removeItem(at: dst)
                } else {
                    return dst
                }
            }

            do {
                try FileManager.linkFile(srcURL, dst)
                var ftype = imageFileType.ext.isEmpty ? "unknown" : imageFileType.ext
                ftype += fileType == nil ? " (detected)" : " (preset)"

                let info = "\(src) [type: \(ftype)] -> \(dst.path)"
                VRE.logger.debug("copy/link \(info, privacy: .public)")
            } catch {
                throw VREError("copy/link file: \(error)")
            }

            return dst
        }

        // copyPCHostTools copies list of subPaths (relative to mountPoint, which is expected to be the
        //  mount point of the PCC Host Tools) into the PCTools/ folder of the VRE instance -- the
        //  copying is recursive, so files may contain directory names. A staging directory is used
        //  during the process and moved into place when completed (previous PCTools/ is removed)
        func copyPCHostTools(
            mountPoint: URL,
            subPaths: [String] = ["usr", "System"]
        ) throws {
            VRE.logger.log("copy private cloud host-side tools")
            VRE.logger.debug("pc tools mounted at: \(mountPoint.path, privacy: .public)")

            // unpack into staging area (limit leaving partial results)
            let tmpPCToolsDir = FileManager.fileURL(pcToolsDir.path + "-unpack")
            try? Globals.computer.fileSystem.removeItem(at: tmpPCToolsDir)

            do {
                try Globals.computer.fileSystem.createDirectory(
                    at: tmpPCToolsDir,
                    withIntermediateDirectories: false
                )
            } catch {
                throw VREError("mkdir: \(tmpPCToolsDir.path): \(error)")
            }

            for sub in subPaths {
                let src = mountPoint.appending(path: sub)
                do {
                    VRE.logger.log("copy \(src.path, privacy: .public) -> \(tmpPCToolsDir.path, privacy: .public)")
                    try Globals.computer.fileSystem.copyItem(at: src, to: tmpPCToolsDir.appending(path: sub))
                } catch {
                    throw VREError("copy \(src.path) -> \(tmpPCToolsDir.path): \(error)")
                }
            }

            // unpack completed - now move staging folder into place
            VRE.logger.debug("remove original VRE pctools folder \(pcToolsDir, privacy: .public)")
            try? Globals.computer.fileSystem.removeItem(at: pcToolsDir)
            do {
                try Globals.computer.fileSystem.moveItem(at: tmpPCToolsDir, to: pcToolsDir)
            } catch {
                throw VREError("move \(tmpPCToolsDir.path) -> \(pcToolsDir): \(error)")
            }
        }
    }
}
