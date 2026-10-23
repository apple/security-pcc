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

extension CLI.ReleaseCmd {
    struct ReleaseDumpCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "dump",
            abstract: "Display information about a release in the Private Cloud Compute Transparency Log.",
            discussion: """
            Displays detailed information for a single release identified by its log \
            index. Output includes the application name, build version, creation and \
            expiry timestamps, and individual digests for the OS manifest ticket along \
            with the associated cryptexes (such as Private Cloud extensions).

            Software component digests are published while model/adapter image digests \
            will not be. Use --detail to include raw metadata and parsed Image4 manifest \
            properties.
            """
        )

        @OptionGroup var globalOptions: CLI.globalOptions
        @OptionGroup var swlogOptions: CLI.ReleaseCmd.options

        @Option(name: [.customLong("release"), .customShort("R")],
                help: "SW Release Log index.")
        var releaseIndex: UInt64

        @Flag(name: [.customLong("detail")],
              help: "Include details in the output.")
        var showDetails: Bool = false

        @Flag(name: [.customLong("json")],
              help: ArgumentHelp("Output json info.", visibility: .customerHidden))
        var jsonOutput: Bool = false

        func run() async throws {
            let logEnvironment = swlogOptions.environment
            CLI.logger.log("release list")
            if logEnvironment != .production {
                CLI.logger.log("using KT environment: \(logEnvironment.rawValue)")
            }

            var swlog = try await SWReleases(
                environment: logEnvironment,
                altKtInitEndpoint: swlogOptions.ktInitEndpoint,
                traceLog: swlogOptions.traceLog
            )

            try await swlog.fetchReleases(
                helper: PCCVREAttestationHelperResolver(environment: logEnvironment),
                reqCount: 1,
                searchRangeStart: Int64(releaseIndex),
                searchRangeEnd: releaseIndex + 1
            )

            guard swlog.count > 0 else {
                if let skippedLeaf = swlog.skippedLeaves.first(where: { $0.index == releaseIndex }) {
                    if jsonOutput {
                        print(asJSONString(PartialReleaseInfo(leaf: skippedLeaf)))
                    } else {
                        printPartialRelease(leaf: skippedLeaf)
                    }
                    fputs("Warning: Some data from this release could not be parsed; consider updating macOS to a newer version to see more details.\n", stderr)
                    return
                }
                throw CLIError("release index \(releaseIndex) wasn't found")
            }
            guard swlog.count == 1 else {
                throw CLIError("more than one release found with index \(releaseIndex): \(swlog.count)")
            }

            let releaseInfo = await ReleaseInfo(swlog[0])

            if jsonOutput {
                print(asJSONString(releaseInfo))
            } else {
                print("\(String(format: "%8d", releaseInfo.index)): \(releaseInfo.label)\(releaseInfo.statusDescription)\n\t\(releaseInfo.dataHash)")

                print()
                print(releaseInfo.printableString())

                if showDetails {
                    if let metadata = releaseInfo.metadataJson {
                        print("Metadata:")
                        print(metadata)
                    }

                    if let parsedDescription = releaseInfo.parsedDescription {
                        print()
                        print(parsedDescription)
                    }
                }
            }
        }

        private func printPartialRelease(leaf: TransparencyLog.ATLeaf) {
            print(Self.formatPartialRelease(leaf: leaf))
        }

        static func formatPartialRelease(leaf: TransparencyLog.ATLeaf) -> String {
            let nodeData = leaf.nodeData
            var builder = ""

            builder += "\(String(format: "%8d", leaf.index)):\n"
            builder += "\t\(nodeData.dataHash.hexString)\n"

            let insertTime: UInt64
            if let insertion = nodeData.insertionTime {
                insertTime = insertion / 1000
            } else {
                insertTime = nodeData.expiryMs / 1000 - 14 * 24 * 60 * 60
            }
            let expireTime = nodeData.expiryMs / 1000

            if let metadata = try? SWReleaseMetadata(leaf: leaf) {
                builder += "\n"
                builder += "Application: \(metadata.application ?? "N/A")\n"

                let buildVersion: String? = if !metadata.metadata.buildVersion.isEmpty {
                    metadata.metadata.buildVersion
                } else if let darwinInitString = metadata.darwinInitString,
                          let darwinInit = try? DarwinInitConfigV1(jsonString: darwinInitString) {
                    darwinInit.buildVersion
                } else {
                    nil
                }
                builder += "Build version: \(buildVersion ?? "N/A")\n"

                builder += "Inserted: \(dateAsString(insertTime))\n"
                builder += "Expires:  \(dateAsString(expireTime))\n"

                if !metadata.assets.isEmpty {
                    builder += "\n"
                    builder += "Assets:\n"
                    for asset in metadata.assets {
                        builder += "  \(asset.type.label): \(asset.url)\n"
                    }
                }
            } else {
                builder += "\n"
                builder += "Inserted: \(dateAsString(insertTime))\n"
                builder += "Expires:  \(dateAsString(expireTime))\n"
            }

            return builder
        }

        struct PartialReleaseInfo: Encodable {
            struct Asset: Encodable {
                let type: String
                let url: String
            }

            let index: UInt64
            let dataHash: String
            let releaseType: String
            let insertTime: UInt64
            let expireTime: UInt64
            let applicationName: String?
            let buildVersion: String?
            let assets: [Asset]?

            init(leaf: TransparencyLog.ATLeaf) {
                let nodeData = leaf.nodeData

                self.index = leaf.index
                self.dataHash = nodeData.dataHash.hexString
                self.releaseType = nodeData.releaseType.description

                if let insertion = nodeData.insertionTime {
                    self.insertTime = insertion / 1000
                } else {
                    self.insertTime = nodeData.expiryMs / 1000 - 14 * 24 * 60 * 60
                }
                self.expireTime = nodeData.expiryMs / 1000

                if let metadata = try? SWReleaseMetadata(leaf: leaf) {
                    self.applicationName = metadata.application

                    if !metadata.metadata.buildVersion.isEmpty {
                        self.buildVersion = metadata.metadata.buildVersion
                    } else if let darwinInitString = metadata.darwinInitString,
                              let darwinInit = try? DarwinInitConfigV1(jsonString: darwinInitString) {
                        self.buildVersion = darwinInit.buildVersion
                    } else {
                        self.buildVersion = nil
                    }

                    if !metadata.assets.isEmpty {
                        self.assets = metadata.assets.map { Asset(type: $0.type.label, url: $0.url) }
                    } else {
                        self.assets = nil
                    }
                } else {
                    self.applicationName = nil
                    self.buildVersion = nil
                    self.assets = nil
                }
            }
        }
    }
}
