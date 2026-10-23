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

extension CLI.Image4Cmd {
    struct Image4ExtractCmd: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "extract",
            abstract: "Extract a binary payload from an image4 object",
            discussion: """
            Firmware images are delivered to a device in the form of image4 objects. A complete image4
            object containing both a payload and a signed manifest is extended as a .img4 file, and a
            stand-alone object containing just the payload is extended as a .im4p file.

            This command can extract the raw binary payload from either kind of file. Optionally, the
            command can also decompress the raw bytes before outputting them, which is useful given
            that firmware images are often compressed with the LZFSE algorithm.
            """
        )

        @OptionGroup var globalOptions: CLI.globalOptions

        @Flag(name: [.customLong("decompress"), .customShort("D")],
              help: """
              Decompress the binary when extracting it. This option can be provided even if
              the input image4 payload is not compressed, in which case this option will do
              nothing.
              """)
        var decompress = false

        @OptionGroup var fileOptions: CLI.Image4Cmd.options

        func run() async throws {
            let fileData = try fileOptions.readInputData()

            let img4Obj = parseImg4Data(fileData)
            guard var img4Obj = img4Obj else {
                throw CLIError("\(fileOptions.inputFile) | Unable to decode as an image4 object")
            }

            var img4Payload = Data(buffer: UnsafeBufferPointer<UInt8>(
                start: img4Obj.payload.data.data,
                count: img4Obj.payload.data.length
            ))

            /* Decompress the payload if required */
            if decompress == true {
                img4Payload = try decompressImg4Payload(fileOptions.inputFile, &img4Obj, &img4Payload)
            }

            /* Output the payload to the output file */
            try fileOptions.writeOutputData(img4Payload)
        }

        func parseImg4Data(_ img4Data: Data) -> Img4? {
            var img4Obj = Img4()
            return img4Data.withUnsafeBytes { rawData in
                let typedData = rawData.assumingMemoryBound(to: UInt8.self)
                let typedPtr = typedData.baseAddress

                /*
                 * First attempt to decode as an image4 payload. On failure, attempt to
                 * decode as an image4 file. The second failure is fatal.
                 */
                var derRet = Img4DecodeInitPayload(typedPtr, typedData.count, &img4Obj)
                if derRet != DR_Success {
                    derRet = Img4DecodeInit(typedPtr, typedData.count, &img4Obj)
                }
                guard derRet == DR_Success else {
                    return nil
                }
                return img4Obj
            }
        }

        func decompressImg4Payload(
            _ fileName: String,
            _ img4Obj: inout Img4,
            _ img4Payload: inout Data
        ) throws -> Data {
            var compressionExists = false
            var compressionAlgo = UInt32(kImg4PayloadCompression_Max_Supported)
            var originalSize = UInt32(0)

            Img4DecodePayloadCompressionInfoExists(&img4Obj, &compressionExists)
            guard compressionExists == true else {
                return img4Payload
            }

            let derRet = Img4DecodeGetPayloadCompressionInfo(&img4Obj, &compressionAlgo, &originalSize)
            guard derRet == DR_Success else {
                throw CLIError("\(fileName)| Unable to acquire compression info: \(derRet)")
            }
            guard compressionAlgo < kImg4PayloadCompression_Max_Supported else {
                throw CLIError("\(fileName)| Invalid compression algorithm: \(compressionAlgo)")
            }
            guard compressionAlgo != kImg4PayloadCompression_LZSS else {
                throw CLIError("\(fileName)| Unsupported compression algorithm: \(compressionAlgo)")
            }

            /* Decompress the input payload */
            let unsafeBuffer = try img4Payload.withUnsafeBytes { rawData in
                let typedData = rawData.assumingMemoryBound(to: UInt8.self)

                /* Allocate space for the decompressed output */
                let unsafeBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(originalSize))

                let compressionSize = compression_decode_buffer(
                    unsafeBuffer.baseAddress, unsafeBuffer.count,
                    typedData.baseAddress, typedData.count,
                    nil,
                    COMPRESSION_LZFSE_SMALL_BLOCKS
                )
                guard compressionSize == originalSize else {
                    throw CLIError("\(fileName)| Unable to compress LZFSE paylad")
                }

                return unsafeBuffer
            }

            /* Store the unsafe buffer into the same payload object */
            img4Payload = Data(buffer: unsafeBuffer)

            /* Safe to deallocate the unsafe buffer now */
            unsafeBuffer.deallocate()

            return img4Payload
        }
    }
}
