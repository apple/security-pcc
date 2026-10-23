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
//  Qcow2.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding
import Foundation

public enum Qcow2 {
    private static let magic: UInt32 = 0x5146_49FB  // "QFI\xFB"

    public struct Disk<Storage: ReadableImage>: ReadableImage {
        private let storage: Storage
        private let clusterBits: Int
        private let clusterSize: Int
        private let l1Table: [UInt64]
        private let virtualSize: UInt64

        public init(storage: Storage) throws {
            self.storage = storage
            let storageSize = storage.imageSize
            guard storageSize >= 72 else {
                throw ImageMeasurementError.invalidQcow2("File too small for qcow2 header")
            }

            let header = try storage.read(offset: 0, length: 72)

            let magic = header.uint32(at: 0, byteOrder: .bigEndian)
            guard magic == Qcow2.magic else {
                throw ImageMeasurementError.invalidQcow2("Invalid qcow2 magic: 0x\(String(magic, radix: 16))")
            }

            let version = header.uint32(at: 4, byteOrder: .bigEndian)
            guard version == 2 || version == 3 else {
                throw ImageMeasurementError.invalidQcow2("Unsupported qcow2 version: \(version)")
            }

            self.clusterBits = Int(header.uint32(at: 20, byteOrder: .bigEndian))
            self.clusterSize = 1 << clusterBits
            self.virtualSize = header.uint64(at: 24, byteOrder: .bigEndian)

            let l1Size = Int(header.uint32(at: 36, byteOrder: .bigEndian))
            let l1TableOffset = header.uint64(at: 40, byteOrder: .bigEndian)

            guard l1TableOffset + UInt64(l1Size * 8) <= storageSize else {
                throw ImageMeasurementError.invalidQcow2("L1 table extends beyond file")
            }

            let l1Data = try storage.read(offset: l1TableOffset, length: l1Size * 8)
            var l1: [UInt64] = []
            l1.reserveCapacity(l1Size)
            for i in 0..<l1Size {
                l1.append(l1Data.uint64(at: i * 8, byteOrder: .bigEndian))
            }
            self.l1Table = l1
        }

        public var size: UInt64 { virtualSize }
        public var imageSize: UInt64 { virtualSize }

        public func readCluster(at guestOffset: UInt64) throws -> Data {
            let l2Bits = clusterBits - 3
            let l1Index = Int(guestOffset >> (clusterBits + l2Bits))
            let l2Index = Int((guestOffset >> clusterBits) & UInt64((1 << l2Bits) - 1))

            guard l1Index < l1Table.count else {
                return Data(count: clusterSize)
            }

            let l1Entry = l1Table[l1Index]
            guard l1Entry & (1 << 63) != 0 else {
                return Data(count: clusterSize)
            }
            let l2Offset = l1Entry & 0x00FF_FFFF_FFFF_FE00

            let l2EntryOffset = l2Offset + UInt64(l2Index * 8)
            guard l2EntryOffset + 8 <= storage.imageSize else {
                throw ImageMeasurementError.invalidQcow2(
                    "L2 table extends beyond file (l1Index=\(l1Index), l2Offset=\(l2Offset), l2Index=\(l2Index), fileSize=\(storage.imageSize))"
                )
            }

            let l2EntryData = try storage.read(offset: l2EntryOffset, length: 8)
            let l2Entry = l2EntryData.uint64(at: 0, byteOrder: .bigEndian)

            if l2Entry & (1 << 62) != 0 {
                throw ImageMeasurementError.invalidQcow2("Compressed clusters are not supported")
            }

            guard l2Entry & (1 << 63) != 0 else {
                return Data(count: clusterSize)
            }

            let clusterOffset = l2Entry & 0x00FF_FFFF_FFFF_FE00
            guard clusterOffset != 0 else {
                return Data(count: clusterSize)
            }

            guard clusterOffset + UInt64(clusterSize) <= storage.imageSize else {
                throw ImageMeasurementError.invalidQcow2("Cluster extends beyond file")
            }

            return try storage.read(offset: clusterOffset, length: clusterSize)
        }

        public func read(offset: UInt64, length: Int) throws -> Data {
            var result = Data(capacity: length)
            var remaining = length
            var currentOffset = offset

            while remaining > 0 {
                let clusterBase = currentOffset & ~UInt64(clusterSize - 1)
                let offsetInCluster = Int(currentOffset - clusterBase)
                let bytesFromCluster = min(remaining, clusterSize - offsetInCluster)

                let cluster = try readCluster(at: clusterBase)
                let base = cluster.startIndex
                result.append(cluster[(base + offsetInCluster)..<(base + offsetInCluster + bytesFromCluster)])

                currentOffset += UInt64(bytesFromCluster)
                remaining -= bytesFromCluster
            }

            return result
        }

        public func rawImageData() throws -> Data {
            guard virtualSize <= UInt64(Int.max) else {
                throw ImageMeasurementError.invalidQcow2("Virtual size \(virtualSize) exceeds maximum addressable size")
            }
            return try read(offset: 0, length: Int(virtualSize))
        }
    }
}

extension Qcow2.Disk where Storage == Data {
    public init(data: Data) throws {
        try self.init(storage: data)
    }
}
