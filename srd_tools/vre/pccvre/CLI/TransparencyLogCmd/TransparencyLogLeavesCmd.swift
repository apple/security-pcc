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
import CryptoKit
import Foundation

extension CLI.TransparencyLogCmd {
    struct LeavesCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "leaves",
            abstract: "List AT leaf entries from local audit storage.",
            aliases: ["leafs"]
        )

        @OptionGroup var transparencyLogOptions: CLI.TransparencyLogCmd.options

        @Option(name: [.customLong("type"), .customShort("t")],
                help: "Leaf type to filter by (release, keybundle-tgt, keybundle-ott, keybundle-ohttp, server-node, test-marker).")
        var leafType: LeafTypeArg?

        @Option(name: [.customLong("count"), .customShort("c")],
                help: "Maximum number of leaves to display.")
        var count: UInt?

        @Flag(name: [.customLong("json")],
              help: "Output as JSON.")
        var jsonOutput: Bool = false

        func run() async throws {
            let storageURL = FileManager.fileURL(transparencyLogOptions.storage)
                .appending(path: transparencyLogOptions.environment.rawValue)
            let treeURL = storageURL.appending(path: "applicationTree.json")

            guard let treeData = try? Data(contentsOf: treeURL) else {
                throw CLIError("No audit data found at \(treeURL.path). Run 'pccvre transparency-log audit' first.")
            }

            let tree = try JSONDecoder().decode(MerkleTree<SHA256>.self, from: treeData)

            var entries: [LeafEntry] = []
            for (index, nodeBytes) in tree.leaves.enumerated() {
                guard let nodeData = try? TransparencyLog.ATLeaf.decodeNodeData(nodeBytes) else {
                    continue
                }

                if let leafType, nodeData.type != ATLeafType(rawValue: UInt8(leafType.protoValue.rawValue)) {
                    continue
                }

                entries.append(LeafEntry(
                    index: UInt64(index),
                    type: nodeData.type.description,
                    dataHash: nodeData.dataHash.hexString,
                    expiryMs: nodeData.expiryMs,
                    expiry: Self.formatExpiry(nodeData.expiryMs),
                    expired: nodeData.expiryMs / 1000 <= UInt64(Date().timeIntervalSince1970)
                ))
            }

            if let count {
                entries = Array(entries.suffix(Int(count)))
            }

            if jsonOutput {
                print(asJSONString(entries, pretty: true))
            } else {
                for entry in entries {
                    let expiredMarker = entry.expired ? " (expired)" : ""
                    print("\(entry.index): \(entry.dataHash)  \(entry.expiry)\(expiredMarker)")
                }
            }
        }

        private static func formatExpiry(_ expiryMs: UInt64) -> String {
            let date = Date(timeIntervalSince1970: TimeInterval(expiryMs) / 1000.0)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }
    }
}

// MARK: - Leaf type argument

extension CLI.TransparencyLogCmd.LeavesCmd {
    enum LeafTypeArg: String, ExpressibleByArgument, CaseIterable {
        case release
        case keybundleTgt = "keybundle-tgt"
        case keybundleOtt = "keybundle-ott"
        case keybundleOhttp = "keybundle-ohttp"
        case serverNode = "server-node"
        case testMarker = "test-marker"

        var protoValue: TxPB_ATLogDataType {
            switch self {
            case .release: return .release
            case .keybundleTgt: return .keybundleTgt
            case .keybundleOtt: return .keybundleOtt
            case .keybundleOhttp: return .keybundleOhttp
            case .serverNode: return .serverNode
            case .testMarker: return .testMarker
            }
        }
    }
}

// MARK: - JSON output model

extension CLI.TransparencyLogCmd.LeavesCmd {
    struct LeafEntry: Codable {
        let index: UInt64
        let type: String
        let dataHash: String
        let expiryMs: UInt64
        let expiry: String
        let expired: Bool
    }
}
