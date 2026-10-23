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
import Foundation

extension CLI {
    struct ListCmd: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List VMs"
        )

        @OptionGroup var globalOptions: globalOptions

        @Flag(name: [.customLong("json")],
              help: ArgumentHelp("Output as json info.", visibility: .hidden))
        var jsonOutput: Bool = false

        @Option(name: [.customLong("name"), .customShort("N")],
                help: "Name of guest VM to list (multiple).",
                transform: { try validateVMName($0) })
        var vmNames: [String] = []

        func run() throws {
            CLI.logger.log("list VREs \(vmNames.isEmpty ? ["<all>"] : vmNames, privacy: .public)")

            // vmlist starts with list of entries in VM-Library/
            var vmlist: [String] = (try? FileManager().contentsOfDirectory(atPath: globalOptions.datadir).filter {
                $0.hasSuffix(VMBundle.nameExt)
            }.map { $0.trimSuffix(VMBundle.nameExt) }) ?? []

            if vmNames.count > 0 {
                vmlist = vmlist.filter { vmNames.contains($0) }
            }

            CLI.logger.log("list of (matching) VMs requested: \(vmlist, privacy: .public)")

            // vmfields holds VM attributes to display/output
            struct vmfields: Codable {
                let name: String
                var bundlepath: String
                var state: String = "invalid"
                var ecid: String?
                var udid: String?
                var cpumem: String?
                var netmode: String?
                var macaddr: String?
                var networks: [vmnetconfig]?
                var nvramargs: VM.NVRAMmap?
                var ipaddr: String?
                var rsdname: String?
            }

            struct vmnetconfig: Codable {
                var mode: VM.NetworkMode
                var macaddr: String?
                var ipaddr: String?
                var bridgeif: String?
            }

            var vms: [vmfields] = []
            var fieldWidths = [20, 10, 17, 8] // min field widths for name, state, ecid, cpumem, (+ipaddr)

            for vmname in vmlist.sorted() {
                let vm = VM(name: vmname, dataDir: globalOptions.datadir)
                var vminfo: vmfields
                do {
                    try vm.open()
                    let vmConfig = vm.vmConfig!

                    var netconfig: [vmnetconfig] = []
                    if let networkConfigs = vm.vmConfig?.networkConfigs {
                        for net in networkConfigs {
                            netconfig.append(
                                vmnetconfig(mode: net.mode,
                                            macaddr: net.macAddr.string,
                                            ipaddr: vm.isRunning() ? try? net.ipAddress()?.asString() : nil,
                                            bridgeif: net.options.bridgeIf?.identifier))
                        }
                    }

                    vminfo = vmfields(
                        name: vmname,
                        bundlepath: vm.bundle.bundlePath.path,
                        state: vm.isRunning() ? "running" : "shutdown",
                        ecid: String(vm.ecid, radix: 16),
                        udid: vm.udidStr,
                        cpumem: String(format: "%d/%dGiB",
                                       vmConfig.cpuCount,
                                       vmConfig.memorySize / (1024 * 1024 * 1024)),
                        netmode: vmConfig.networkConfigs?.first?.mode.rawValue ?? .none,
                        networks: netconfig,
                        nvramargs: vmConfig.nvramArgs
                    )

                    if let macaddr = vm.primaryInterface()?.macAddr {
                        vminfo.macaddr = macaddr.string
                    }

                    if vm.isRunning() {
                        vminfo.ipaddr = try? vm.primaryIPAddress()?.asString()
                        vminfo.rsdname = try? vm.rsdName()
                    }
                } catch {
                    vminfo = vmfields(name: vmname,
                                      bundlepath: vm.bundle.bundlePath.path)
                }

                vms.append(vminfo)
                fieldWidths[0] = max(fieldWidths[0], vminfo.name.count)
                fieldWidths[1] = max(fieldWidths[1], vminfo.state.count)
                fieldWidths[2] = max(fieldWidths[2], vminfo.ecid?.count ?? 1)
                fieldWidths[3] = max(fieldWidths[3], vminfo.cpumem?.count ?? 1)
            }

            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .withoutEscapingSlashes
            let jsonList = String(decoding: try! jsonEncoder.encode(vms), as: UTF8.self)
            CLI.logger.log("VM info: \(jsonList, privacy: .public)")

            // --json option
            if jsonOutput {
                print(jsonList)
                return
            }

            guard vms.count > 0 else {
                throw CLIError("no VMs found")
            }

            print(String.tabular(widths: fieldWidths, "name", "status", "ecid", "cpu/mem", "ipaddr"))
            for vm in vms {
                print(String.tabular(widths: fieldWidths,
                                     vm.name,
                                     vm.state,
                                     vm.ecid ?? "-",
                                     vm.cpumem ?? "-",
                                     vm.ipaddr ?? "-"))
            }

            print()
        }
    }
}
