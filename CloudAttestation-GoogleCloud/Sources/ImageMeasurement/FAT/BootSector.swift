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
//  BootSector.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding

extension FAT {
    enum FATType {
        case fat16
        case fat32
    }

    struct BootSector: BinaryDecodable {
        var jumpBoot: (UInt8, UInt8, UInt8)
        var oemName: [UInt8]  // 8 bytes
        var bytesPerSector: UInt16
        var sectorsPerCluster: UInt8
        var reservedSectorCount: UInt16
        var numFATs: UInt8
        var rootEntryCount: UInt16  // 0 for FAT32
        var totalSectors16: UInt16
        var media: UInt8
        var fatSize16: UInt16  // 0 for FAT32
        var sectorsPerTrack: UInt16
        var numHeads: UInt16
        var hiddenSectors: UInt32
        var totalSectors32: UInt32
        // FAT32-specific fields
        var fatSize32: UInt32
        var extFlags: UInt16
        var fsVer: UInt16
        var rootCluster: UInt32

        var byteCount: Int { 52 }

        var fatType: FATType {
            fatSize16 == 0 ? .fat32 : .fat16
        }

        /// Sectors occupied by one FAT, works for both FAT16 and FAT32.
        var fatSizeSectors: UInt32 {
            fatType == .fat16 ? UInt32(fatSize16) : fatSize32
        }

        var bytesPerCluster: Int {
            Int(bytesPerSector) * Int(sectorsPerCluster)
        }

        var fatStartOffset: Int {
            Int(reservedSectorCount) * Int(bytesPerSector)
        }

        var fatSizeBytes: Int {
            Int(fatSizeSectors) * Int(bytesPerSector)
        }

        /// Number of sectors occupied by the root directory (non-zero only for FAT16).
        var rootDirSectors: Int {
            ((Int(rootEntryCount) * 32) + (Int(bytesPerSector) - 1)) / Int(bytesPerSector)
        }

        /// Byte offset where the root directory starts (FAT16 only).
        var rootDirOffset: Int {
            fatStartOffset + Int(numFATs) * fatSizeBytes
        }

        /// Byte size of the fixed root directory area (FAT16 only).
        var rootDirSize: Int {
            rootDirSectors * Int(bytesPerSector)
        }

        var dataRegionStart: Int {
            fatStartOffset + Int(numFATs) * fatSizeBytes + rootDirSectors * Int(bytesPerSector)
        }

        init(from buffer: inout ArraySlice<UInt8>) throws {
            let j0 = try buffer.readUInt8()
            let j1 = try buffer.readUInt8()
            let j2 = try buffer.readUInt8()
            self.jumpBoot = (j0, j1, j2)
            self.oemName = [UInt8](try buffer.readBytes(count: 8))
            self.bytesPerSector = try buffer.readUInt16()
            self.sectorsPerCluster = try buffer.readUInt8()
            self.reservedSectorCount = try buffer.readUInt16()
            self.numFATs = try buffer.readUInt8()
            self.rootEntryCount = try buffer.readUInt16()
            self.totalSectors16 = try buffer.readUInt16()
            self.media = try buffer.readUInt8()
            self.fatSize16 = try buffer.readUInt16()
            self.sectorsPerTrack = try buffer.readUInt16()
            self.numHeads = try buffer.readUInt16()
            self.hiddenSectors = try buffer.readUInt32()
            self.totalSectors32 = try buffer.readUInt32()

            if self.fatSize16 == 0 {
                // FAT32: read extended BPB fields
                self.fatSize32 = try buffer.readUInt32()
                self.extFlags = try buffer.readUInt16()
                self.fsVer = try buffer.readUInt16()
                self.rootCluster = try buffer.readUInt32()
            } else {
                // FAT16: these fields don't exist; use defaults
                self.fatSize32 = 0
                self.extFlags = 0
                self.fsVer = 0
                self.rootCluster = 0
            }
        }
    }
}
