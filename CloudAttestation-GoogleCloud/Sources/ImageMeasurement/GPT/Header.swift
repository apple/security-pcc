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
//  Header.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding
import Foundation

extension GPT {
    private static let gptSignature: UInt64 = 0x5452_4150_2049_4645  // "EFI PART" in little-endian

    struct Header: BinaryDecodable {
        var signature: UInt64
        var revision: UInt32
        var headerSize: UInt32
        var headerCRC32: UInt32
        var reserved: UInt32
        var myLBA: UInt64
        var alternateLBA: UInt64
        var firstUsableLBA: UInt64
        var lastUsableLBA: UInt64
        var diskGUID: UUID
        var partitionEntryLBA: UInt64
        var numberOfPartitionEntries: UInt32
        var sizeOfPartitionEntry: UInt32
        var partitionEntryArrayCRC32: UInt32

        var byteCount: Int { 92 }

        init(from buffer: inout ArraySlice<UInt8>) throws {
            self.signature = try buffer.readUInt64()
            guard self.signature == gptSignature else {
                throw ImageMeasurementError.invalidGPTSignature
            }
            self.revision = try buffer.readUInt32()
            self.headerSize = try buffer.readUInt32()
            self.headerCRC32 = try buffer.readUInt32()
            self.reserved = try buffer.readUInt32()
            self.myLBA = try buffer.readUInt64()
            self.alternateLBA = try buffer.readUInt64()
            self.firstUsableLBA = try buffer.readUInt64()
            self.lastUsableLBA = try buffer.readUInt64()
            self.diskGUID = try UUID(from: &buffer)
            self.partitionEntryLBA = try buffer.readUInt64()
            self.numberOfPartitionEntries = try buffer.readUInt32()
            self.sizeOfPartitionEntry = try buffer.readUInt32()
            self.partitionEntryArrayCRC32 = try buffer.readUInt32()
        }
    }

    struct PartitionEntry: BinaryDecodable {
        var partitionTypeGUID: UUID
        var uniquePartitionGUID: UUID
        var startingLBA: UInt64
        var endingLBA: UInt64
        var attributes: UInt64
        var name: [UInt8]

        var byteCount: Int { 128 }

        init(from buffer: inout ArraySlice<UInt8>) throws {
            self.partitionTypeGUID = try UUID(from: &buffer)
            self.uniquePartitionGUID = try UUID(from: &buffer)
            self.startingLBA = try buffer.readUInt64()
            self.endingLBA = try buffer.readUInt64()
            self.attributes = try buffer.readUInt64()
            // Name is 72 bytes (36 UTF-16LE code units) in a standard 128-byte entry
            self.name = [UInt8](try buffer.readBytes(count: 72))
        }

        var isEmpty: Bool {
            partitionTypeGUID == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        }

        var label: String {
            let utf16Units = stride(from: 0, to: name.count &- 1, by: 2).map { i in
                UInt16(name[i]) | (UInt16(name[i + 1]) << 8)
            }
            let trimmed = utf16Units.prefix(while: { $0 != 0 })
            return String(utf16CodeUnits: Array(trimmed), count: trimmed.count)
        }
    }
}
