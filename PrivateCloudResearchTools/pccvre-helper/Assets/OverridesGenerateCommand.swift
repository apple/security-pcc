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

//  Copyright © 2026 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import Foundation

/// Generates a custom PCC Overrides asset (an unencrypted Apple Archive) from a metadata directory,
/// for exercising PCC Overrides in a CAD VRE. Served over HTTP and wired in via `--print-darwin-init`.
struct OverridesGenerateCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate a custom PCC Overrides asset from a metadata directory."
    )

    /// `AssetMetadata.consumerID` the PCC Overrides handler resolves the asset under
    /// (PCCAgentSafety/Override/OverridesAssetLoader.swift).
    static let consumerID = "PCCSafetyOverrideAssets"
    /// Default `asset_id`; must begin with the overrides Knox image prefix so the handler resolves it.
    static let defaultAssetID = "PCC_PCC_SYSTEM_ASSETS_SAFETY_OVERRIDES_GENERIC_GENERIC_CV_9"

    @Option(name: .customLong("metadata-directory"),
            help: "Directory of override resources (<resource-id>.input/.output containing metadata.json).",
            completion: .directory)
    var metadataDirectory: String

    @Option(name: [.customLong("output"), .customShort("o")],
            help: "Path to write the generated .aar asset.",
            completion: .file())
    var outputPath: String

    @Option(name: .customLong("base-model"),
            help: "Version subfolder to read metadata.json from within each resource directory.")
    var baseModel: String = "v9"

    @Flag(name: .customLong("compute-window-size"),
          help: "Compute windowSize/windowSizeStrict from the patterns instead of using metadata.json values.")
    var computeWindowSize: Bool = false

    @Flag(name: .customLong("print-darwin-init"),
          help: "After generating, print the applicationAssetMap darwin-init snippet for the CAD VRE.")
    var printDarwinInit: Bool = false

    @Option(name: .customLong("asset-url"),
            help: "URL the VRE node will fetch the asset from (used only for --print-darwin-init).")
    var assetURL: String?

    @Option(name: .customLong("asset-version"),
            help: "Asset version string for the darwin-init snippet.")
    var assetVersion: String = "1"

    @Option(name: .customLong("asset-id"),
            help: "Asset ID for the darwin-init snippet.")
    var assetID: String = defaultAssetID

    @Flag(name: .customLong("debug"), help: .hidden)
    var debug: Bool = false

    func run() throws {
        CLI.setupPrinting(debugFlag: debug)

        let calculator: WindowSizeCalculating = computeWindowSize
            ? ComputedWindowSizeCalculator()
            : PassthroughWindowSizeCalculator()
        let builder = OverridesAssetBuilder(baseModel: baseModel, windowSizeCalculator: calculator)

        let metadataURL = URL(fileURLWithPath: metadataDirectory)
        let resources = try builder.loadResources(fromMetadataDirectory: metadataURL)

        let fm = FileManager.default
        let stagingDirectory = fm.temporaryDirectory
            .appendingPathComponent("pccvre-overrides-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingDirectory) }

        try builder.stage(resources, into: stagingDirectory)
        try archive(stagingDirectory: stagingDirectory, outputPath: outputPath)

        FileHandle.standardError.write(Data("Generated \(resources.count) override resource(s) → \(outputPath)\n".utf8))

        if printDarwinInit {
            print(try darwinInitSnippet())
        }
    }

    /// Packages the staged tree into an Apple Archive whose root is the tree's contents.
    private func archive(stagingDirectory: URL, outputPath: String) throws {
        let outputURL = URL(fileURLWithPath: outputPath)
        let fm = FileManager.default
        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // `aa archive` refuses to overwrite; clear a stale output file, but never delete a directory.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: outputURL.path, isDirectory: &isDir) {
            guard !isDir.boolValue else {
                throw CLIError("Output path is a directory: \(outputURL.path). Pass a file path for the .aar.")
            }
            try fm.removeItem(at: outputURL)
        }

        let launcher = ProcessLauncher()
        let result = try launcher.exec(
            executablePath: Self.aaPath,
            arguments: ["archive", "-d", stagingDirectory.path, "-o", outputURL.path]
        )
        guard result.exitCode == 0 else {
            throw CLIError("aa archive failed (exit \(result.exitCode)): \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
    }

    private static var aaPath: String {
        ProcessInfo().environment["PCCVRE_AA"] ?? "/usr/bin/aa"
    }

    /// Ready-to-paste darwin-init for the CAD VRE. The `applicationAssetMap` preference points
    /// `cloudassetdownloaderd` at the served asset; the secure-config flags allow the unencrypted
    /// (non-AEA) archive to be accepted.
    private func darwinInitSnippet() throws -> String {
        let url = assetURL ?? "http://<VRE-HOST-IP>:3001/\(URL(fileURLWithPath: outputPath).lastPathComponent)"
        let preference: [String: Any] = [
            "application_id": "com.apple.cloudos.hotproperties.cloudassetdownloaderd",
            "key": "applicationAssetMap",
            "value": [Self.consumerID: [["url": url, "version": assetVersion, "asset_id": assetID]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: preference, options: [.prettyPrinted, .sortedKeys])
        return """

        # --- darwin-init for the CAD VRE ---
        # Add to "preferences":
        \(String(decoding: data, as: UTF8.self))

        # Add to "secure-config" (accept the unencrypted asset):
        "com.apple.cloudos.cloudassetdownloaderd.allowNonAEAAssets": true,
        "com.apple.cloudos.cloudassetdownloaderd.enforceConsumerIDs": false
        """
    }
}
