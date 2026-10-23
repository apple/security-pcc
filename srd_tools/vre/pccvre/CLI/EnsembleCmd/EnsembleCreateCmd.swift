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
//  EnsembleCreateCmd.swift
//  vre
//
//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import Foundation
import System

extension CLI.EnsembleCmd {
    struct EnsembleCreateCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new Virtual Research Environment ensemble.",
            discussion: """
            Creates two VRE instances, connects them using virtual CIO mesh, and configures them to form an ensemble using darwin-init.
            """
        )

        @OptionGroup var globalOptions: CLI.globalOptions
        @OptionGroup var createOptions: CLI.InstanceCmd.CreateOptions

        @Option(name: [.customLong("name"), .customShort("N")],
                help: "VRE ensemble name.",
                transform: { try CLI.validateVREName($0) })
        var ensembleName: String

        @Option(name: [.customLong("count"), .customShort("c")],
                help: ArgumentHelp("Number of VRE compute nodes \(VRE.Ensemble.validNodeCounts).",
                                   visibility: .customerHidden),
                transform: {
                    guard let c = Int($0), VRE.Ensemble.validNodeCounts.contains(c) else {
                        throw ValidationError("count must be \(VRE.Ensemble.validNodeCounts)")
                    }
                    return c
                })
        var nodeCount: Int = 2

        @Option(name: [.customLong("macaddr"), .customLong("mac")],
                help: "Specify primary network MAC address for each VRE instance (xx:xx:xx:xx:xx:xx)[,..] (first one is leader, remaining ones are optional).",
                transform: { try CLI.validateMACAddresses($0) })
        var macAddrs: [String]?

        @Option(name: [.customLong("virt-mesh-plugin")],
            help: ArgumentHelp(
                "Specify the VirtMesh plugin path, to override the one fetched from the PCTools dmg.",
                visibility: .customerHidden,
            ),
            transform: { try CLI.validateFilePath($0) }
        )
        var virtMeshPlugin: String?

        func run() async throws {
            CLI.logger.log("create Ensemble \(ensembleName, privacy: .public) (nodeCount=\(nodeCount, privacy: .public)")

            guard VRE.Ensemble.exists(ensembleName) == false else {
                throw CLIError("Ensemble '\(ensembleName)' already exists")
            }

            if let release = createOptions.release {
                try validateReaseSupportsEnsembles(release: release)
            }

            let options = Array(0 ..< nodeCount).map {
                InstanceOptions(
                    release: createOptions.release,
                    skipReleaseRequirementsCheck: createOptions.skipReleaseRequirementsCheck,
                    osImage: createOptions.osImage,
                    osVariant: createOptions.osVariant,
                    osVariantName: createOptions.osVariantName,
                    fusing: createOptions.fusing,
                    name: ensembleName + "-node\($0)",
                    diskSizeGB: createOptions.diskSizeGB,
                    networks: [
                        VRE.VMConfig.Network(mode: .nat, macAddr: macAddrs?[$0]),
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
            }

            try CLI.validateRequiredMemoryToCreate(instanceOptions: options)

            // create compute nodes for the ensemble
            let instances = try options.map {
                try CLI.createVREInstance(
                   instanceOptions: $0,
                   httpService: createOptions.httpService
               )
            }

            let ensemble = VRE.Ensemble(name: ensembleName, instances: instances)
            try ensemble.create()

            // add ensemble darwin-init config for each node
            for vre in instances {
                do {
                    var darwinInit = try vre.darwinInitHelper()

                    try darwinInit.addEnsembleConfig(name: ensembleName, ensemble: ensemble)
                    try darwinInit.save()
                } catch {
                    throw CLIError("unable to update node configurations: \(error)")
                }
            }

            guard let leaderNode = ensemble.leader else {
                throw CLIError("unable to determine ensemble leader")
            }

            // unpack PrivateCloud tools image for leader:
            // 1. Need cloudremotediag for ensemble status
            // 2. Need VirtMesh host plugin & broker for distributed VRE
            do {
                try CLI.unpackPCTools(vre: leaderNode.instance)
            } catch {
                CLI.logger.error("unpack PC tools for \(leaderNode.name, privacy: .public): \(error, privacy: .public)")
                CLI.warning("unable to unpack PC tools - some functions won't be available (\(error))")
            }

            // The virtmesh plugin path from the dmg, this path is configured in CIOMesh project's Xcode setting to install VirtMesh host
            var virtMeshPluginPath = leaderNode.instance.pcToolsDir.appending(path: "System/Library/Plugins/com.apple.AppleVirtMeshPlugin.Virtio.vzplugin")

            if virtMeshPlugin != nil {
                virtMeshPluginPath = URL(fileURLWithPath: virtMeshPlugin!)
            }

            if Globals.computer.fileSystem.fileExists(atPath: virtMeshPluginPath.path) {
                CLI.logger.info("Assigning virtmesh plugin and rank")
                do {
                    for node in ensemble.nodes {
                        CLI.logger.debug(
                            "Assigning virtmesh plugin [\(virtMeshPluginPath, privacy: .public)] and rank [\(node.rank, privacy: .public)] for node \(node.name, privacy: .public)"
                        )
                        try node.instance.vm.assignVirtMesh(
                            rank: Int(node.rank), pluginPath: virtMeshPluginPath)
                    }
                } catch {
                    throw CLIError("unable to assign virtmesh plugin: \(error)")
                }
            } else {
                CLI.logger.info(
                    "Skip assigning virtmesh plugin because it's not found from PCTools, possibly because of using an old version of PCTools."
                )
            }
        }

        func validateReaseSupportsEnsembles(release: String) throws {
            guard !createOptions.skipReleaseRequirementsCheck else {
                // Escape hatch for internal qualification.
                // Repurpose `skipReleaseRequirementsCheck` to avoid introducing a new flag and needing to check for its availability in tests.
                return
            }
            let helper: PCCVREHelper
            do {
                helper = try PCCVREHelper.configuredOrFromRelease(release)
            } catch {
                throw CLIError("Unable to check that the PCC release supports ensembles - \(error)")
            }
            if !helper.supports(feature: .ensemble) {
                throw CLIError("The PCC release doesn't support ensembles")
            }
        }
    }
}
