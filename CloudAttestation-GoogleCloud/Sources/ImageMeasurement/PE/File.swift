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
//  PEFile.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding
import Crypto
import Foundation

extension PE {
    private static let mzSignature: UInt16 = 0x5A4D  // "MZ"
    private static let peSignature: UInt32 = 0x0000_4550  // "PE\0\0"
    private static let certificateTableIndex = 4
    /// CheckSum is at offset 64 from the OptionalHeader start in both PE32 and PE32+.
    private static let checkSumOptionalHeaderOffset = 64
    private static let checkSumFieldSize = 4
    private static let certificateTableDirEntrySize = 8

    struct File {
        private let checkSumOffset: Int
        private let certificateTableDirEntryOffset: Int?
        private let certificateTableOffset: UInt32?
        private let certificateTableSize: UInt32?
        private let fileData: Data

        init(fileData: Data) throws {
            self.fileData = fileData

            guard fileData.count >= 64 else {
                throw ImageMeasurementError.invalidPESignature
            }

            // Read DOS header - MZ signature at offset 0
            guard fileData.uint16(at: 0) == mzSignature else {
                throw ImageMeasurementError.invalidPESignature
            }

            // PE header offset at DOS header offset 0x3C
            let peOffset = Int(fileData.uint32(at: 0x3C))

            guard peOffset + 4 <= fileData.count else {
                throw ImageMeasurementError.invalidPESignature
            }

            // Verify PE signature
            guard fileData.uint32(at: peOffset) == peSignature else {
                throw ImageMeasurementError.invalidPESignature
            }

            // COFF header starts right after PE signature
            let coffOffset = peOffset + 4
            guard coffOffset + 20 <= fileData.count else {
                throw ImageMeasurementError.invalidPESignature
            }

            let sizeOfOptionalHeader = Int(fileData.uint16(at: coffOffset + 16))

            // Optional header starts after COFF header
            let optionalHeaderOffset = coffOffset + 20
            guard optionalHeaderOffset + sizeOfOptionalHeader <= fileData.count else {
                throw ImageMeasurementError.invalidPESignature
            }

            // Read magic to determine PE32 vs PE32+
            let magic = fileData.uint16(at: optionalHeaderOffset)
            let dataDirectoryOffset: Int
            switch magic {
            case 0x10B:  // PE32
                dataDirectoryOffset = optionalHeaderOffset + 96
            case 0x20B:  // PE32+
                dataDirectoryOffset = optionalHeaderOffset + 112
            default:
                throw ImageMeasurementError.invalidPESignature
            }

            self.checkSumOffset = optionalHeaderOffset + checkSumOptionalHeaderOffset

            // Data directory entry 4 (Certificate Table) - each entry is 8 bytes (4 RVA + 4 size)
            let certTableDirOffset = dataDirectoryOffset + certificateTableIndex * certificateTableDirEntrySize

            if certTableDirOffset + certificateTableDirEntrySize <= fileData.count {
                let offset = fileData.uint32(at: certTableDirOffset)
                let size = fileData.uint32(at: certTableDirOffset + 4)
                if offset > 0, size > 0, Int(offset) + Int(size) <= fileData.count {
                    self.certificateTableDirEntryOffset = certTableDirOffset
                    self.certificateTableOffset = offset
                    self.certificateTableSize = size
                } else {
                    self.certificateTableDirEntryOffset = certTableDirOffset
                    self.certificateTableOffset = nil
                    self.certificateTableSize = nil
                }
            } else {
                self.certificateTableDirEntryOffset = nil
                self.certificateTableOffset = nil
                self.certificateTableSize = nil
            }
        }

        private var certificateTableData: Data? {
            guard let offset = certificateTableOffset, let size = certificateTableSize else { return nil }
            return fileData[Int(offset)..<Int(offset) + Int(size)]
        }

        var certificate: UEFISecureBootCertificate {
            get throws {
                guard let tableData = certificateTableData else {
                    throw ImageMeasurementError.certificateTableNotFound
                }
                return try UEFISecureBootCertificate(certificateTable: tableData)
            }
        }
    }
}

extension PE.File {
    func digest<Hash: Crypto.HashFunction>(using hasher: Hash.Type = SHA384.self) -> Hash.Digest {
        var hash = Hash()

        hash.update(data: fileData[0..<checkSumOffset])
        var cursor = checkSumOffset + PE.checkSumFieldSize

        if let certDirOffset = certificateTableDirEntryOffset {
            hash.update(data: fileData[cursor..<certDirOffset])
            cursor = certDirOffset + PE.certificateTableDirEntrySize
        }

        let end = certificateTableOffset.map { Int($0) } ?? fileData.count
        hash.update(data: fileData[cursor..<end])

        return hash.finalize()
    }
}
