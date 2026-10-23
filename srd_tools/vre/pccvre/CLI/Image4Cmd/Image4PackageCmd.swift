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
import MachO_Swift
import Foundation

extension CLI.Image4Cmd {
    struct Image4PackageCmd: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "package",
            abstract: "Package a MachO into an image4 payload containing payload properties",
            discussion: """
            On newer SPTM/TXM devices, iBoot does not perform any parsing of the MachO firmware image
            in order to exclude the MachO parser from the trusted computing base. Instead, it requires
            that the firmware images be parsed ahead of time, with each segment of the MachO designated
            into a particular region.

            The offset and size of each region is then stored within a DER dictionary which is embedded
            into the image4 payload with the "PAYP" (payload properties) tag. The PAYP dictionary also
            contains the base address of where the image must be loaded as well as the address of the
            entry point into the image.

            Constructing and embedding this PAYP dictionary into an image4 payload can be non-trivial.
            This command aims to automate generating an image4 payload given the firmware's type and
            MachO image.
            """
        )

        @OptionGroup var globalOptions: CLI.globalOptions

        @Option(name: [.customLong("type"), .customShort("T")],
                help: """
                The type of the MachO you're attempting to package into an image4 payload.
                The options are "kernel-cache", "sptm", and "txm".
                """)
        var type = "kernel-cache"
        func getType4CC() throws -> String {
            switch type {
            case "kernel-cache":
                return "krnl"
            case "sptm":
                return "sptm"
            case "txm":
                return "trxm"
            default:
                throw CLIError("\(type) | Unknown payload type requested")
            }
        }

        @OptionGroup var fileOptions: CLI.Image4Cmd.options

        func run() async throws {
            let fileData = try fileOptions.readInputData()
            var payloadProperties: Unmanaged<CFData>?

            var amRet = try fileData.withUnsafeBytes {
                let machO = try MachO(withUnsafeData: $0)

                guard machO.slices.count == 1 else {
                    throw MachO.Error.numSlices
                }
                let slice = machO.slices[0]

                return AMAuthInstallApImg4GetPayloadPropertiesData(
                    nil,
                    &payloadProperties,
                    "PAYP" as CFString,
                    try slice.payloadProperties as CFDictionary
                )
            }
            guard amRet == kAMAuthInstallErrorNone else {
                throw CLIError("\(fileOptions.inputFile) | Unable to create payload properties: \(amRet)")
            }

            var img4Payload: Unmanaged<CFData>?
            amRet = try AMAuthInstallApImg4CreatePayloadWithProperties(
                getType4CC().cString(using: String.Encoding.utf8),
                "0".cString(using: String.Encoding.utf8),
                fileData as CFData,
                nil, nil,
                payloadProperties!.takeRetainedValue(),
                &img4Payload
            )
            guard amRet == kAMAuthInstallErrorNone else {
                throw CLIError("\(fileOptions.inputFile) | Unable to stitch payload properties: \(amRet)")
            }

            /* Output the requested file */
            try fileOptions.writeOutputData(img4Payload!.takeRetainedValue() as Data)
        }
    }
}
