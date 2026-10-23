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
    struct ReleaseDownloadCmd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "download",
            abstract: "Download assets for a release in the Private Cloud Compute Transparency Log."
        )

        @OptionGroup var globalOptions: CLI.globalOptions
        @OptionGroup var swlogOptions: CLI.ReleaseCmd.options

        @Option(name: [.customLong("overwrite"), .customShort("o")],
                help: "Overwrite existing assets already downloaded.")
        var overwrite: Bool = false

        @Option(name: [.customLong("release"), .customShort("R")],
                help: "SW Release Log index, or path to release metadata .json or .protobuf file.")
        var release: String

        @Flag(name: [.customLong("skip-verify")],
              help: ArgumentHelp("Skip digest verification of downloaded assets.",
                                 visibility: .customerHidden))
        var skipVerifier: Bool = false

        func run() async throws {
            // assetHelper tracks downloaded assets and metadata (json) info
            var assetHelper: AssetHelper
            do {
                assetHelper = try AssetHelper(
                    directory: CLIDefaults.assetsDirectory.path,
                    purgeable: !CLIDefaults.customAssetFolder
                )
            } catch {
                throw CLIError("\(CLIDefaults.assetsDirectory.path): \(error)")
            }

            let releaseMetadata: SWReleaseMetadata

            if let releaseIndex = UInt64(release) {
                CLI.logger.log("release download (index=\(releaseIndex, privacy: .public))")
                let logEnvironment = swlogOptions.environment
                if logEnvironment != .production {
                    CLI.logger.log("using KT environment: \(logEnvironment.rawValue)")
                }

                var swlog = try await SWReleases(
                    environment: logEnvironment,
                    altKtInitEndpoint: swlogOptions.ktInitEndpoint
                )

                try await swlog.fetchReleases(
                    helper: PCCVREAttestationHelperResolver(environment: logEnvironment),
                    reqCount: 1,
                    includeAll: true,
                    searchRangeStart: Int64(releaseIndex),
                    searchRangeEnd: UInt64(releaseIndex + 1)
                )

                guard let swrelease = swlog.last else {
                    throw CLIError("SW Release not found")
                }

                guard let relMetadata = swrelease.metadata else {
                    throw CLIError("SW Release metadata not found")
                }
                releaseMetadata = relMetadata

                do {
                    // ticket & release files always overwritten
                    try assetHelper.addRelease(release: swrelease,
                                               logEnvironment: swlogOptions.environment)
                } catch {
                    throw CLIError("Unable to save release information: \(error)")
                }
            } else if release.hasSuffix(".json") { // external release.json file
                do {
                    releaseMetadata = try SWReleaseMetadata(from: FileManager.fileURL(release))
                } catch {
                    throw CLIError("cannot load \(release): \(error)")
                }
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

            // download assets not already onhand, doesn't match asset digest (in release.json),
            //  or when --overwrite specified
            let cryptexes = await CLI.ReleaseCmd.ReleaseDownloadCmd.fetchAssets(
                assetHelper: assetHelper,
                assets: releaseMetadata.assets,
                skipVerifier: skipVerifier,
                overwrite: overwrite
            )

            if cryptexes.count != releaseMetadata.assets.count {
                throw CLIError("did not retrieve all SW Release assets")
            }

            CLI.logger.log("completed download of assets")
            print("Completed download of assets.")
        }

        // fetchAssets returns set of "cryptexes" (os/tools image or those to pass into VM) from
        //  local cache area, after downloading from CDN as needed
        private static func fetchAssets(
            assetHelper: AssetHelper,
            assets: [SWReleaseMetadata.Asset],
            skipVerifier: Bool = false,
            overwrite: Bool = false
        ) async -> [CryptexSpec] {
            var cryptexes: [CryptexSpec] = []

            for asset in assets {
                guard let assetURL = URL(string: asset.url) else {
                    CLI.logger.error("invalid SW release asset: \(asset.url, privacy: .public)")
                    print("Skipping invalid SW release asset: \(asset.url)")
                    continue
                }

                let assetVerifier: SWReleaseMetadata.AssetVerifier
                if skipVerifier {
                    CLI.logger.log("skipping asset verifier")
                    assetVerifier = { url in FileManager.isRegularFile(url) } // check file exists
                } else {
                    do {
                        // may fail if unknown/invalid digest algo specified in release info for this entry
                        assetVerifier = try SWReleaseMetadata.assetVerifier(asset)
                    } catch {
                        CLI.logger.error("could not derive asset verifier for \(asset.url, privacy: .public): \(error, privacy: .public)")
                        print("Skipping SW release asset \(asset.url): \(error)")
                        continue
                    }
                }

                let assetName = assetURL.lastPathComponent
                if !overwrite {
                    // if have asset already, verify digest against one included in release info
                    if let assetPath = assetHelper.assetPath(assetName),
                       assetVerifier(assetPath)
                    {
                        do {
                            let cryptex = try CryptexSpec(
                                path: assetPath.path,
                                variant: asset.variant,
                                assetType: asset.type.label
                            )

                            cryptexes.append(cryptex)
                            CLI.logger.log("asset already downloaded: \(assetName)")
                            print("SW release asset already downloaded: \(assetName)")
                            continue
                        } catch {} // fall-through -- re-download this item
                    }
                }

                do {
                    print("Downloading asset: \(assetURL.absoluteString)")

                    let assetPath = try await assetHelper.downloadAsset(from: assetURL,
                                                                        verifier: assetVerifier)
                    try cryptexes.append(CryptexSpec(path: assetPath.path,
                                                     variant: asset.variant,
                                                     assetType: asset.type.label))
                    print("SW release asset downloaded: \(assetPath.lastPathComponent)")
                } catch {
                    CLI.logger.error("failed to download: \(error, privacy: .public)")
                    print("Failed to download SW release asset '\(assetURL)': \(error)")
                    continue
                }
            }

            return cryptexes
        }
    }
}
