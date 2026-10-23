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

// VRE.VM provides interface to "vrevm" command for managing VMs

import Foundation

private let vrevmCommandName = "vrevm"
private let envExitOnPID = "\(vrevmCommandName)_EXIT_ON_PID".uppercased()

extension VRE {
    /// <#Description#>
    struct VM {
        static var vrevmCmd: String = CLI.commandDir.appending(vrevmCommandName).string

        /// Config encapsulates (in-core) settings for creating an instance VM
        struct Config {
            struct Network {
                enum Mode: String {
                    case none
                    case nat
                    case hostOnly
                }

                let mode: Mode
                var macAddr: String? = nil
            }

            var osImage: String?
            var osVariant: String?
            var osVariantName: String?
            var fusing: String?
            var darwinInitPath: String?
            var networks: [Network] = [Network(mode: .nat)]
            /// Designate number of CPUs for guest
            var ncpu: UInt?
            /// Designate memory (GiB) for guest
            var nramGB: UInt?
            /// Primary VM disk size in GiB; nil uses the vrevm default (64).
            var diskSizeGB: UInt?
            var bootArgs: VRE.NVRAMArgs?
            var nvramArgs: VRE.NVRAMArgs?
            var romImagePath: String?
            var vsepImagePath: String?
            var kernelCachePath: String?
            var sptmPath: String?
            var txmPath: String?
            var prkitPath: String?
        }

        struct Status: Codable {
            var name: String
            var bundlepath: String?
            var state: String?
            var ecid: String?
            var udid: String?
            var cpumem: String?
            var netmode: String?
            var macaddr: String?
            var ipaddr: String?
            var rsdname: String?

            var isRunning: Bool { state ?? "" == "running" }

            var memoryGB: Int? {
                cpumem?.replacingOccurrences(of: "GiB", with: "").split(separator: "/").dropFirst().first.flatMap { Int($0) }
            }
        }

        let name: String

        // isRunning returns true if "vrevm list" shows VM running
        var isRunning: Bool {
            if let vmStatus = try? status() {
                return vmStatus.isRunning
            }

            return false
        }

        init(
            name: String,
            vrevmPath: String? = nil
        ) {
            self.name = name
            if let vrevmPath, Globals.computer.fileSystem.isExecutableFile(atPath: vrevmPath) {
                VRE.VM.vrevmCmd = vrevmPath
            }
        }

        // create executes a "vrevm create" operation using settings in config
        func create(config: Config) throws {
            // must have osImage and darwinInit
            guard config.osImage != nil, config.darwinInitPath != nil else {
                throw VREError("missing os restore/darwin-init spec")
            }

            var cmdline = ["create"]
            cmdline.append(contentsOf: vmConfigArgs(config))

            do {
                try Self.vmCmd(cmdline)
            } catch {
                throw VREError("error creating VRE instance: \(error)")
            }
        }

        // remove executes a "vrevm remove" operation (no prompt)
        func remove() throws {
            let cmdline: [String] = ["remove", "-f", "--name=\(name)"]

            do {
                try Self.vmCmd(cmdline, outMode: .none)
            } catch {
                throw VREError("error removing VRE instance: \(error)")
            }
        }

        // start executes a "vrevm run" operation (optionally passing in darwin-init.json);
        //   remains blocked while running
        func start(
            darwinInit: String? = nil,
            quietMode: Bool = false
        ) throws {
            var cmdline: [String] = ["run", "--name=\(name)"]
            if let darwinInit {
                cmdline.append("--darwin-init=\(darwinInit)")
            }
            if quietMode {
                cmdline.append("--quiet")
            }

            do {
                if quietMode {
                    try Self.vmCmd(cmdline, outMode: .nostdin)
                } else {
                    try Self.vmCmd(cmdline, outMode: .terminal)
                }
            } catch {
                throw VREError("error starting VRE instance: \(error)")
            }
        }

        // status executes a "vrevm list" for the named VM and returns decoded Status
        func status() throws -> Status {
            let cmdline = ["list", "--json", "--name=\(name)"]

            let listOutput: String
            do {
                listOutput = try Self.vmCmd(cmdline, outMode: .capture)
            } catch {
                throw VREError("error listing VRE instances: \(error)")
            }

            guard let vmstatus = try? JSONDecoder().decode(
                [Status].self,
                from: listOutput.data(using: .utf8)!
            ), vmstatus.count == 1 else {
                throw VREError("\(name): failed to obtain status")
            }

            return vmstatus[0]
        }
        
        // assign virtmesh rank id and plugin path
        func assignVirtMesh(rank: Int, pluginPath: URL) throws {
            let cmdline = [
                "modify",
                "--name=\(name)",
                "--virt-mesh-rank=\(rank)",
                "--virt-mesh-plugin",
                pluginPath.path(percentEncoded: false),
            ]
            do {
                try Self.vmCmd(cmdline, outMode: .terminal)
            } catch {
                throw VREError("error assigning virtmesh to VRE instance: \(error)")
            }
        }

        static func status() throws -> [Status] {
            let cmdline = ["list", "--json"]

            let listOutput: String
            do {
                listOutput = try vmCmd(cmdline, outMode: .capture)
            } catch {
                throw VREError("error listing VRE instances: \(error)")
            }

            guard let vmstatus = try? JSONDecoder().decode(
                [Status].self,
                from: listOutput.data(using: .utf8)!
            ) else {
                throw VREError("failed to obtain status")
            }
            return vmstatus
        }

        /// Adds up the amount of memory requested by all the running VMs
        /// - Returns: total memory in GB
        static func totalRunningVMMemory() throws -> Int {
            let vmStatus = try VRE.VM.status()
            let runningVMMemory = vmStatus
                .filter { $0.isRunning }
                .reduce(0) { (sum, vm) in sum + (vm.memoryGB ?? 0) }
            return runningVMMemory
        }

        // vmConfigArgs populates a command-line for "vrevm" from Config
        private func vmConfigArgs(_ config: Config) -> [String] {
            var cmdline = ["--name=\(name)"]

            if let osImage = config.osImage {
                cmdline.append("--restore=\(osImage)")
            }

            if let osVariant = config.osVariant {
                cmdline.append("--variant=\(osVariant)")
            } else if let osVariantName = config.osVariantName {
                cmdline.append("--variant-name=\(osVariantName)")
            }

            if let fusing = config.fusing {
                cmdline.append("--fusing=\(fusing)")
            }

            if let darwinInit = config.darwinInitPath {
                cmdline.append("--darwin-init=\(darwinInit)")
            }

            if let ncpu = config.ncpu {
                cmdline.append("--ncpu=\(ncpu)")
            }

            for network in config.networks {
                var netargs: [String] = [network.mode.rawValue]
                if let mac = network.macAddr {
                    netargs.append("macaddr=\(mac)")
                }
                cmdline.append("--network=\(netargs.joined(separator: ","))")
            }

            if let nramGB = config.nramGB {
                cmdline.append("--nram=\(nramGB)")
            }

            if let bootArgs = config.bootArgs {
                cmdline.append("--boot-args=\(nvramArg(bootArgs))")
            }

            if let nvramArgs = config.nvramArgs {
                cmdline.append("--nvram=\(nvramArg(nvramArgs))")
            }

            if let romImage = config.romImagePath {
                cmdline.append("--rom=\(romImage)")
            }

            if let vsepImage = config.vsepImagePath {
                cmdline.append("--vseprom=\(vsepImage)")
            }

            if let kernelCachePath = config.kernelCachePath {
                cmdline.append("--kernelcache=\(kernelCachePath)")
            }

            if let sptmPath = config.sptmPath {
                cmdline.append("--sptm=\(sptmPath)")
            }

            if let txmPath = config.txmPath {
                cmdline.append("--txm=\(txmPath)")
            }

            if let prkitPath = config.prkitPath {
                cmdline.append("--prkit=\(prkitPath)")
            }

            if let diskSizeGB = config.diskSizeGB {
                cmdline.append("--storage=\(diskSizeGB)")
            }

            return cmdline
        }

        // nvramArg reassembles nvargs into string of whitespace separated entries ("<key>=<val> <key> ..");
        //  primarily for passing to vrevm command-line
        private func nvramArg(_ nvargs: VRE.NVRAMArgs) -> String {
            var arg: [String] = []
            for (k, v) in nvargs {
                if v != "" {
                    arg.append("\(k)=\(v)")
                } else {
                    arg.append(k)
                }
            }

            return arg.joined(separator: " ")
        }

        // vmCmd executes the "vrevm" command with the commandArgs command-line.
        //  printCmd can be provided to display a different command-line from what's actually provided.
        //  outMode determines where command output should be collected (passed to ExecCommand)
        @discardableResult
        private static func vmCmd(
            _ commandArgs: [String],
            printCmd: String? = nil,
            outMode: ExecCommand.OutputMode = .terminal
        ) throws -> String {
            var commandLine = commandArgs
            commandLine.insert(VRE.VM.vrevmCmd, at: 0)

            VRE.logger.debug("\(printCmd ?? commandLine.joined(separator: " "), privacy: .public)")

            let execQueue = DispatchQueue(label: applicationName + ".exec", qos: .userInitiated)
            // let vrevm know it was launched by us for monitoring in case we exit abnormally (and exit itself)
            let envvars = [envExitOnPID: String(getpid())]
            let (exitCode, stdOutput, stdError) = try Globals.computer.processRunner.run(
                command: commandLine,
                environment: envvars,
                outputMode: outMode,
                queue: execQueue
            )

            guard exitCode == 0 || exitCode == 15 else { // ec=15 == (sig) terminated
                var errMsg = "vrevm exited \(exitCode)"
                if !stdError.isEmpty {
                    errMsg += "; error=\"\(stdError)\""
                }

                throw VREError(errMsg)
            }

            return stdOutput
        }
    }
}

extension VRE.VM.Config.Network.Mode: Codable {}
extension VRE.VM.Config.Network: Codable {}
