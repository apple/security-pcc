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
import System

extension CLI {
    struct CryptexCmd: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "cryptex",
            abstract: "Build cryptexes for usage with the VRE.",
            subcommands: [
                CryptexCreateCmd.self,
            ]
        )
    }
}

extension CLI.CryptexCmd {
    struct CryptexCreateCmd: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a cryptex from an existing directory structure."
        )

        @OptionGroup var globalOptions: CLI.globalOptions

        // Use a mount point allowed by Sandbox and not conflicting with customer cryptexes.
        static let defaultMountPoint = "/private/var/PrivateCloudSupportInternalAdditions"

        @Option(name: [.customLong("source"), .customShort("S")],
                help: "Source directory to use for cryptex contents.",
                completion: .directory,
                transform: { try CLI.validateDirectoryPath($0) })
        var source: FilePath

        @Option(name: [.customLong("variant"), .customShort("V")],
                help: "Variant name to use for new cryptex.",
                transform: { try CLI.validateCryptexVariantName($0) })
        var variantName: String

        @Option(name: [.customLong("cryptexctl")],
                help: ArgumentHelp("Path to cryptexctl command.", visibility: .hidden))
        var cryptexCtlPath: String = "/System/Library/SecurityResearch/usr/bin/cryptexctl.research"

        @Option(name: [.customLong("mount-point")],
                help: ArgumentHelp("Cryptex mount point.", visibility: .hidden))
        var mountPoint: String = Self.defaultMountPoint

        func createDiskImage(sourceDirectory: String, queue: DispatchQueue, tempDirPath: String) throws -> String {
            let diskImageURL = FileManager.fileURL(tempDirPath).appending(component: "cryptexDiskImage.dmg")

            let commandLine = ["/usr/bin/hdiutil", "create", "-srcfolder", sourceDirectory, diskImageURL.path]
            let exitCode: Int32
            do {
                (exitCode, _, _) = try ExecCommand(commandLine).run(
                    outputMode: .none,
                    queue: queue
                )
            } catch {
                throw CLIError("Unable to create disk image for new cryptex.")
            }

            guard exitCode == 0 else {
                throw CLIError("Failed to create disk image for new cryptex, hdiutil error: \(exitCode).")
            }

            return diskImageURL.path(percentEncoded: false)
        }

        func createCryptex(diskImagePath: String, queue: DispatchQueue, tempDirPath: String, cryptexCtlPath: String) throws -> String {
            let commandLine = [
                cryptexCtlPath, "create",
                "--output-directory=\(tempDirPath)",
                "--restricted-exec-mode-default=both",
                "--identifier=\(variantName)",
                "--mount-point=\(mountPoint)",
                "-v", "1",
                "-V", variantName,
                "--FCHP=0xff10",
                "--TYPE=0x3",
                "--STYP=0x1",
                "--CLAS=0xf2",
                "--NDOM=0x3",
                "--BORD=0x90",
                "--CHIP=0xfe01",
                "--SDOM=0x1",
                diskImagePath,
            ]
            let exitCode: Int32
            do {
                (exitCode, _, _) = try ExecCommand(commandLine).run(
                    outputMode: .terminal,
                    queue: queue
                )
            } catch {
                throw CLIError("Unable to create new cryptex.")
            }
            guard exitCode == 0 else {
                throw CLIError("Cryptex creation command failed with error: \(exitCode).")
            }

            let newCryptexURL = FileManager.fileURL(tempDirPath).appendingPathComponent("\(variantName).cxbd")
            return newCryptexURL.path(percentEncoded: false)
        }

        func createCryptexArchive(cryptexPath: String, queue: DispatchQueue) throws -> String {
            let cryptexArchivePath = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("\(variantName).aar")

            let commandLine = ["/usr/bin/aa", "archive", "-d", cryptexPath, "-o", cryptexArchivePath, "-a", "raw"]
            let exitCode: Int32

            do {
                (exitCode, _, _) = try ExecCommand(commandLine).run(
                    outputMode: .none,
                    queue: queue
                )
            } catch {
                throw CLIError("Unable to create cryptex archive.")
            }
            guard exitCode == 0 else {
                throw CLIError("Cryptex archive creation failed with error: \(exitCode).")
            }

            return cryptexArchivePath
        }

        func run() async throws {
            guard Globals.computer.fileSystem.fileExists(atPath: cryptexCtlPath) else {
                throw CLIError("Unable to find \(cryptexCtlPath)).")
            }

            let queue = DispatchQueue(label: "CryptexCreateQueue")

            let tempDir = try FileManager.tempDirectory(
                subPath: applicationName, UUID().uuidString
            ).path(percentEncoded: false)
            defer {
                try? Globals.computer.fileSystem.removeItem(atPath: tempDir)
            }

            let diskImagePath = try createDiskImage(sourceDirectory: source.string, queue: queue, tempDirPath: tempDir)
            let cryptexPath = try createCryptex(diskImagePath: diskImagePath, queue: queue, tempDirPath: tempDir, cryptexCtlPath: cryptexCtlPath)
            let cryptexArchivePath = try createCryptexArchive(cryptexPath: cryptexPath, queue: queue)

            print("Created new cryptex at path: \(cryptexArchivePath) with variant name: \(variantName)")
        }
    }
}
