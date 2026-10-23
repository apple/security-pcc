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
@_spi(Private) import CloudAttestation

extension CLI.AttestationCmd {
    struct ParseCmd: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "parse",
            abstract: "Parse and convert a PCC Attestation Bundle."
        )

        @OptionGroup var globalOptions: CLI.globalOptions

        @OptionGroup var attestOptions: CLI.AttestationFormatOptions

        @Option(name: [.customLong("output-format"), .customShort("O")],
                help: "Output format of PCC Attestation Bundle.")
        var outputFormat: OutputFormat = .json

        @Option(name: [.customLong("output"), .customShort("o")],
                help: "Output file of parsed PCC Attestation Bundle.",
                completion: .file())
        var outputFile: String = "-"

        @Argument(help: "Path to the Apple Intelligence Report, or depending on `--input-format` the PCC Attestation Bundle to parse.",
                  completion: .file())
        var file: String

        func run() async throws {
            switch try attestOptions.loadAndDispatch(file: file) {
            case .v2(let nodeBytes):
                // Route to pccvre-attestation-helper for the JSON form. We
                // already hold the raw protobuf node bytes, so -O protobuf is
                // served locally without a helper round-trip.
                if outputFormat == .protobuf {
                    try writeOutput(nodeBytes)
                    return
                }
                let resolver = PCCVREAttestationHelperResolver(environment: CLIDefaults.ktEnvironment)
                let envelope = try await attestOptions.runV2Helper(
                    nodeBytes: nodeBytes,
                    via: resolver,
                    subcommand: ["attestation", "parse"]
                )
                if outputFile == "-" {
                    print(envelope.summary)
                    print()
                    print(envelope.detail)
                } else {
                    // envelope.detail is the helper's protobuf-JSON of the
                    // AttestationBundle — write that, matching -O json on v1.
                    try writeOutput(Data((envelope.detail + "\n").utf8))
                }
                if !envelope.ok {
                    throw ExitCode(1)
                }

            case .v1(let nodeBytes, let fileData):
                let bundle = try attestOptions.decodeV1Bundle(nodeBytes: nodeBytes, fileData: fileData)
                try writeV1(bundle: bundle)
            }
        }

        /// Writes raw bytes to `outputFile` (or stdout for `-`, refusing
        /// protobuf-to-TTY). Shared by the v1 path's serialized output and the
        /// v2 path's already-extracted node bytes / envelope detail.
        private func writeOutput(_ data: Data) throws {
            let output: FileHandle
            if outputFile == "-" {
                output = FileHandle.standardOutput
                if outputFormat == .protobuf, output.isTTY {
                    throw CLIError("refusing to write binary protobuf to terminal")
                }
            } else {
                if !FileManager.isRegularFile(outputFile) {
                    Globals.computer.fileSystem.createFile(atPath: outputFile, contents: nil)
                }
                do {
                    output = try FileHandle(forWritingTo: FileManager.fileURL(outputFile))
                    try output.truncate(atOffset: 0)
                } catch {
                    throw CLIError("failed to create file handle")
                }
            }
            do {
                try output.write(contentsOf: data)
            } catch {
                throw CLIError("write to \(outputFile): \(error)")
            }
        }

        private func writeV1(bundle attestationBundle: AttestationBundle) throws {
            let parsedBundle: Data
            switch outputFormat {
                case .protobuf:
                    do {
                        parsedBundle = try attestationBundle.serializedData()
                    } catch {
                        throw CLIError("serialize to protobuf: \(error)")
                    }

                case .json:
                    do {
                        let jsonStr = try attestationBundle.jsonString() + "\n"
                        guard let jsonData = jsonStr.data(using: .utf8) else {
                            throw CLIError("failed to encode utf8")
                        }

                        parsedBundle = jsonData
                    } catch {
                        throw CLIError("convert to json: \(error)")
                    }
            }

            try writeOutput(parsedBundle)
        }
    }

    enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
        case protobuf
        case json
    }
}
