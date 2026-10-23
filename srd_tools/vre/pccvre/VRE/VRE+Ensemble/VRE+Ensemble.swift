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

import Foundation
import Network
import System

// VRE.Ensemble state for ensembles

extension VRE {
    struct Ensemble {
        static let validNodeCounts = CLI.internalBuild ? [2, 4, 8] : [2]

        // Node holds in-core representation of an ensemble member node
        struct Node {
            let instance: VRE.Instance
            let rank: UInt8
            let udid: String
            var name: String { instance.name }
            var hostName: String? { try? instance.darwinInitHelper().localHostname()?.appending(".local") }
            var isLeader: Bool { rank == 0 }
        }

        let name: String
        var config: VRE.Ensemble.Config
        var nodes: [Node]

        // directory contains the full path of the named ensemble bundle:
        var directory: URL { VRE.ensembleDir(name) }

        // exists returns true if the ensembleDir exists (any object by name)
        static func exists(_ name: String) -> Bool {
            FileManager.isExist(VRE.ensembleDir(name))
        }

        var exists: Bool { VRE.Ensemble.exists(name) }

        // configFile contains the full path of the named ensemble config plist
        static let configFilename = "ensemble.plist"
        static func configFile(_ name: String) -> URL {
            VRE.ensembleDir(name).appending(path: VRE.Ensemble.configFilename)
        }

        var configFile: URL { Ensemble.configFile(name) }

        // leader node typically first
        var leader: Node? { nodes.first(where: { $0.isLeader }) }

        // leaderRunning == true if leader node is live
        var leaderRunning: Bool { leader?.instance.vm.isRunning ?? false }

        // anyNodeRunning == true if any node instance is live
        var anyNodeRunning: Bool {
            for node in nodes where node.instance.vm.isRunning {
                return true
            }

            return false
        }

        // allNodesRunning == true if all node instances live
        var allNodesRunning: Bool {
            for node in nodes where !node.instance.vm.isRunning {
                return false
            }

            return true
        }

        // anyNodeExist == true if any node instance exists
        var anyNodeExist: Bool {
            for node in nodes where node.instance.exists {
                return true
            }

            return false
        }

        // allNodesExist == true if all node instances exist
        var allNodesExist: Bool {
            for node in nodes where !node.instance.exists {
                return false
            }

            return true
        }

        // initialize new VRE ensemble in memory
        init(
            name: String,
            instances: [VRE.Instance]
        ) {
            self.name = name
            self.nodes = instances.enumerated().map {
                Node(instance: $1,
                     rank: UInt8($0),
                     udid: $1.status().udid ?? "00000000-0000000000000000")
            }
            self.config = VRE.Ensemble.Config(
                name: name,
                nodes: nodes.map {
                    VRE.Ensemble.Config.Node(
                        name: $0.name,
                        rank: $0.rank,
                        udid: $0.udid
                    )
                }
            )
        }

        // load VRE ensemble from existing ensemble.plist file
        init(name: String) throws {
            guard VRE.Ensemble.exists(name) else {
                throw VREError("VRE ensemble '\(name)' does not exist")
            }

            self.name = name
            self.config = try VRE.Ensemble.Config(
                contentsOf: VRE.Ensemble.configFile(name)
            )

            do {
                self.nodes = try config.nodes.map { try Node(instance: VRE.Instance(name: $0.name),
                                                             rank: $0.rank,
                                                             udid: $0.udid) }
            } catch {
                throw VREError("load VRE ensemble: \(error)")
            }
        }

        // create writes a new VRE ensemble on the file system
        //  - name instance folder created (removed upon any errors)
        func create() throws {
            guard !exists else {
                throw VREError("ensemble already exists")
            }

            guard allNodesExist else {
                throw VREError("one or more node instances missing")
            }

            do {
                try Globals.computer.fileSystem.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw VREError("cannot create ensemble folder: \(error)")
            }

            do {
                try config.write(to: configFile)
            } catch {
                try? Globals.computer.fileSystem.removeItem(at: directory)
                throw error
            }
        }

        // remove ensures associated instances no longer exist and removes the ensemble config folder
        func remove() throws {
            guard !anyNodeExist else {
                throw VREError("one or more node instances still exist")
            }

            do {
                try Globals.computer.fileSystem.removeItem(at: directory)
            } catch {
                throw VREError("remove VRE instance folder: \(error)")
            }
        }

        // start launches member nodes within an ensemble -- method blocks while instances running
        mutating func start() async throws {
            guard !anyNodeRunning else {
                throw VREError("one or more node instances indicate running")
            }

            var vmTasks: [Task<Void, Error>] = []

            // start nodes (leader first)
            for node in nodes.sorted(by: { a, _ in a.isLeader }) {
                
                

                let vmTask = Task {
                    try await node.instance.start(quietMode: true)
                }

                vmTasks.append(vmTask)
            }

            await withTaskGroup(of: Void.self) { group in
                for vmTask in vmTasks {
                    group.addTask { _ = await vmTask.result }
                }

                await group.waitForAll()
            }
        }
    }
}
