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
//  Ext4.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding
import Foundation

public enum Ext4 {}

extension Ext4 {
    struct Superblock {
        let inodeCount: UInt32
        let blockCount: UInt64
        let blockSize: UInt32
        let inodesPerGroup: UInt32
        let inodeSize: UInt16
        let firstDataBlock: UInt32
        let has64bit: Bool

        init(data: Data, offset: Int = 1024) throws {
            guard data.count >= offset + 256 else {
                throw ImageMeasurementError.invalidImageFile("Too small for ext4 superblock")
            }

            let magic = data.uint16(at: offset + 56)
            guard magic == 0xEF53 else {
                throw ImageMeasurementError.invalidImageFile("Invalid ext4 magic: 0x\(String(magic, radix: 16))")
            }

            self.inodeCount = data.uint32(at: offset + 0)
            let blockCountLo = UInt64(data.uint32(at: offset + 4))
            self.firstDataBlock = data.uint32(at: offset + 20)
            let logBlockSize = data.uint32(at: offset + 24)
            self.blockSize = 1024 << logBlockSize
            self.inodesPerGroup = data.uint32(at: offset + 40)
            self.inodeSize = data.uint16(at: offset + 88)

            let incompatFeatures = data.uint32(at: offset + 96)
            self.has64bit = (incompatFeatures & 0x80) != 0

            let blockCountHi = has64bit ? UInt64(data.uint32(at: offset + 336)) : 0
            self.blockCount = blockCountHi << 32 | blockCountLo
        }
    }
}

// MARK: - FileHandle

extension Ext4 {
    public struct FileHandle: ReadableImage {
        fileprivate enum BlockMap {
            case extents([Extent])
            case materialized(Data)
        }

        fileprivate struct Extent {
            let logicalBlock: UInt64
            let physicalBlock: UInt64
            let count: UInt64
        }

        private let partitionData: Data
        private let blockSize: Int
        private let blockMap: BlockMap
        public let imageSize: UInt64

        fileprivate init(partitionData: Data, blockSize: Int, blockMap: BlockMap, imageSize: UInt64) {
            self.partitionData = partitionData
            self.blockSize = blockSize
            self.blockMap = blockMap
            self.imageSize = imageSize
        }

        public func read(offset: UInt64, length: Int) throws -> Data {
            guard offset + UInt64(length) <= imageSize else {
                throw ImageMeasurementError.invalidImageFile("Read past end of ext4 file (offset \(offset), length \(length), size \(imageSize))")
            }

            switch blockMap {
            case .materialized(let data):
                return data.subdata(in: Int(offset)..<Int(offset) + length)
            case .extents(let extents):
                return try readFromExtents(extents, offset: offset, length: length)
            }
        }

        private func readFromExtents(_ extents: [Extent], offset: UInt64, length: Int) throws -> Data {
            var result = Data(capacity: length)
            var remaining = length
            var pos = offset

            while remaining > 0 {
                let blockIndex = pos / UInt64(blockSize)
                let offsetInBlock = Int(pos % UInt64(blockSize))

                if let extent = Self.findExtent(extents, containing: blockIndex) {
                    let blockInExtent = blockIndex - extent.logicalBlock
                    let physBlock = extent.physicalBlock + blockInExtent
                    let blocksLeftInExtent = extent.count - blockInExtent
                    let bytesLeftInExtent = Int(blocksLeftInExtent) * blockSize - offsetInBlock
                    let bytesToRead = min(remaining, bytesLeftInExtent)

                    let dataOffset = Int(physBlock) * blockSize + offsetInBlock
                    guard dataOffset + bytesToRead <= partitionData.count else {
                        throw ImageMeasurementError.invalidImageFile("Extent data block out of bounds")
                    }

                    result.append(partitionData[(partitionData.startIndex + dataOffset)..<(partitionData.startIndex + dataOffset + bytesToRead)])
                    pos += UInt64(bytesToRead)
                    remaining -= bytesToRead
                } else {
                    let bytesInBlock = min(remaining, blockSize - offsetInBlock)
                    result.append(Data(count: bytesInBlock))
                    pos += UInt64(bytesInBlock)
                    remaining -= bytesInBlock
                }
            }

            return result
        }

        private static func findExtent(_ extents: [Extent], containing blockIndex: UInt64) -> Extent? {
            var lo = 0
            var hi = extents.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if extents[mid].logicalBlock + extents[mid].count <= blockIndex {
                    lo = mid + 1
                } else if extents[mid].logicalBlock > blockIndex {
                    hi = mid
                } else {
                    return extents[mid]
                }
            }
            return nil
        }
    }
}

// MARK: - FileSystem

extension Ext4 {
    public struct FileSystem {
        private let data: Data
        private let sb: Superblock

        public init(partitionData: Data) throws {
            self.data = partitionData
            self.sb = try Superblock(data: partitionData)
        }

        public func readFile(at path: String) throws -> Data {
            let inode = try resolveInode(at: path)
            return try readInodeData(inode)
        }

        public func openFile(at path: String) throws -> FileHandle {
            let inodeNum = try resolveInode(at: path)
            return try openInode(inodeNum)
        }

        public func listDirectory(at path: String) throws -> [String] {
            let inode = try resolveInode(at: path)
            return try readDirectory(inode: inode).map(\.name)
        }

        /// Inode number of the filesystem root directory.
        public static let rootInode: UInt32 = 2

        /// Lists entries in the directory at `inode`. Use together with ``Self/rootInode`` to
        /// walk a filesystem without re-resolving paths from the root on every step.
        public func listDirectoryEntries(inode: UInt32) throws -> [DirectoryEntry] {
            try readDirectory(inode: inode)
        }

        // MARK: Path Resolution

        private func resolveInode(at path: String) throws -> UInt32 {
            let components = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }

            var currentInode: UInt32 = 2
            for (index, component) in components.enumerated() {
                let entries = try readDirectory(inode: currentInode)

                guard let entry = entries.first(where: { $0.name.caseInsensitiveCompare(component) == .orderedSame }) else {
                    throw ImageMeasurementError.fileNotFound(path: path)
                }

                if index < components.count - 1 {
                    guard entry.fileType == .directory else {
                        throw ImageMeasurementError.fileNotFound(path: path)
                    }
                }
                currentInode = entry.inode
            }

            return currentInode
        }

        // MARK: Opening Files (lazy)

        private func openInode(_ inodeNum: UInt32) throws -> FileHandle {
            let inodeData = try readInode(inodeNum)
            let flags = inodeData.uint32(at: 32)
            let isExtents = (flags & 0x80000) != 0

            let sizeLo = UInt64(inodeData.uint32(at: 4))
            let sizeHi = UInt64(inodeData.uint32(at: 108))
            let fileSize = sizeHi << 32 | sizeLo

            let iBlock = inodeData.subdata(in: (inodeData.startIndex + 40)..<(inodeData.startIndex + 100))

            if isExtents {
                let extents = try collectExtents(from: iBlock)
                return FileHandle(partitionData: data, blockSize: Int(sb.blockSize), blockMap: .extents(extents), imageSize: fileSize)
            }

            let fileData = try readIndirectBlocks(iBlock: iBlock, fileSize: fileSize)
            return FileHandle(partitionData: data, blockSize: Int(sb.blockSize), blockMap: .materialized(fileData), imageSize: fileSize)
        }

        private func collectExtents(from iBlock: Data) throws -> [FileHandle.Extent] {
            var extents: [FileHandle.Extent] = []
            try collectExtentNode(data: iBlock, into: &extents)
            return extents
        }

        private func collectExtentNode(data nodeData: Data, into extents: inout [FileHandle.Extent]) throws {
            guard nodeData.count >= 12 else { return }

            let magic = nodeData.uint16(at: 0)
            guard magic == 0xF30A else {
                throw ImageMeasurementError.invalidImageFile("Invalid extent header magic: 0x\(String(magic, radix: 16))")
            }

            let entries = Int(nodeData.uint16(at: 2))
            let depth = Int(nodeData.uint16(at: 6))

            if depth == 0 {
                for i in 0..<entries {
                    let offset = 12 + i * 12
                    let logicalBlock = UInt64(nodeData.uint32(at: offset))
                    let count = UInt64(nodeData.uint16(at: offset + 4))
                    let startHi = UInt64(nodeData.uint16(at: offset + 6))
                    let startLo = UInt64(nodeData.uint32(at: offset + 8))
                    let physBlock = startHi << 32 | startLo
                    extents.append(FileHandle.Extent(logicalBlock: logicalBlock, physicalBlock: physBlock, count: count))
                }
            } else {
                for i in 0..<entries {
                    let offset = 12 + i * 12
                    let leafLo = UInt64(nodeData.uint32(at: offset + 4))
                    let leafHi = UInt64(nodeData.uint16(at: offset + 8))
                    let leafBlock = leafHi << 32 | leafLo

                    let blockOffset = Int(leafBlock) * Int(sb.blockSize)
                    guard blockOffset + Int(sb.blockSize) <= self.data.count else {
                        throw ImageMeasurementError.invalidImageFile("Extent index block out of bounds")
                    }
                    let childData = self.data.subdata(in: (self.data.startIndex + blockOffset)..<(self.data.startIndex + blockOffset + Int(sb.blockSize)))
                    try collectExtentNode(data: childData, into: &extents)
                }
            }
        }

        // MARK: Reading Files (eager)

        private func readInodeData(_ inodeNum: UInt32) throws -> Data {
            let inodeData = try readInode(inodeNum)
            let flags = inodeData.uint32(at: 32)
            let isExtents = (flags & 0x80000) != 0

            let sizeLo = UInt64(inodeData.uint32(at: 4))
            let sizeHi = UInt64(inodeData.uint32(at: 108))
            let fileSize = sizeHi << 32 | sizeLo

            let iBlock = inodeData.subdata(in: (inodeData.startIndex + 40)..<(inodeData.startIndex + 100))

            guard isExtents else {
                return try readIndirectBlocks(iBlock: iBlock, fileSize: fileSize)
            }
            return try readExtentTree(iBlock: iBlock, fileSize: fileSize)
        }

        // MARK: Inode Reading

        private func readInode(_ inodeNum: UInt32) throws -> Data {
            let index = inodeNum - 1
            let group = Int(index / sb.inodesPerGroup)
            let localIndex = Int(index % sb.inodesPerGroup)

            let gdOffset: Int
            if sb.blockSize == 1024 {
                gdOffset = 2048
            } else {
                gdOffset = Int(sb.blockSize)
            }

            let gdEntrySize = sb.has64bit ? 64 : 32
            let gdEntry = gdOffset + group * gdEntrySize

            guard gdEntry + gdEntrySize <= data.count else {
                throw ImageMeasurementError.invalidImageFile("Block group descriptor out of bounds")
            }

            let inodeTableLo = UInt64(data.uint32(at: gdEntry + 8))
            let inodeTableHi = sb.has64bit ? UInt64(data.uint32(at: gdEntry + 36)) : 0
            let inodeTableBlock = inodeTableHi << 32 | inodeTableLo

            let inodeOffset = Int(inodeTableBlock) * Int(sb.blockSize) + localIndex * Int(sb.inodeSize)
            guard inodeOffset + Int(sb.inodeSize) <= data.count else {
                throw ImageMeasurementError.invalidImageFile("Inode \(inodeNum) out of bounds (offset \(inodeOffset), data size \(data.count))")
            }

            return data.subdata(in: (data.startIndex + inodeOffset)..<(data.startIndex + inodeOffset + Int(sb.inodeSize)))
        }

        // MARK: Directory Parsing

        /// An entry in an ext4 directory.
        public struct DirectoryEntry: Sendable {
            public let name: String
            public let fileType: FileType
            public let inode: UInt32
        }

        /// File type stored in an ext4 directory entry. Source: Linux `ext4.h` `EXT4_FT_*`.
        public enum FileType: UInt8, Sendable {
            case unknown = 0
            case regularFile = 1
            case directory = 2
            case characterDevice = 3
            case blockDevice = 4
            case fifo = 5
            case socket = 6
            case symbolicLink = 7
        }

        private func readDirectory(inode inodeNum: UInt32) throws -> [DirectoryEntry] {
            let dirData = try readInodeData(inodeNum)
            var entries: [DirectoryEntry] = []
            var offset = 0

            while offset + 8 <= dirData.count {
                let ino = dirData.uint32(at: offset)
                let recLen = Int(dirData.uint16(at: offset + 4))
                let nameLen = Int(dirData[dirData.startIndex + offset + 6])
                let fileType = FileType(rawValue: dirData[dirData.startIndex + offset + 7]) ?? .unknown

                guard recLen > 0 else { break }

                if ino != 0 && offset + 8 + nameLen <= dirData.count {
                    let nameStart = dirData.startIndex + offset + 8
                    let name = String(decoding: dirData[nameStart..<nameStart + nameLen], as: UTF8.self)
                    if name != "." && name != ".." {
                        entries.append(DirectoryEntry(name: name, fileType: fileType, inode: ino))
                    }
                }

                offset += recLen
            }

            return entries
        }

        // MARK: Extent Tree (eager read)

        private func readExtentTree(iBlock: Data, fileSize: UInt64) throws -> Data {
            var result = Data(capacity: Int(fileSize))
            try readExtentNode(data: iBlock, into: &result, remaining: Int(fileSize))
            return result
        }

        private func readExtentNode(data nodeData: Data, into result: inout Data, remaining: Int) throws {
            guard nodeData.count >= 12 else { return }

            let magic = nodeData.uint16(at: 0)
            guard magic == 0xF30A else {
                throw ImageMeasurementError.invalidImageFile("Invalid extent header magic: 0x\(String(magic, radix: 16))")
            }

            let entries = Int(nodeData.uint16(at: 2))
            let depth = Int(nodeData.uint16(at: 6))

            if depth == 0 {
                for i in 0..<entries {
                    guard result.count < remaining else { return }
                    let offset = 12 + i * 12
                    let eeBlock = Int(nodeData.uint32(at: offset))
                    let len = Int(nodeData.uint16(at: offset + 4))
                    let startHi = UInt64(nodeData.uint16(at: offset + 6))
                    let startLo = UInt64(nodeData.uint32(at: offset + 8))
                    let physBlock = startHi << 32 | startLo

                    let logicalOffset = eeBlock * Int(sb.blockSize)
                    if logicalOffset > result.count {
                        result.append(Data(count: min(logicalOffset - result.count, remaining - result.count)))
                    }

                    let blockCount = min(len, (remaining - result.count + Int(sb.blockSize) - 1) / Int(sb.blockSize))
                    for b in 0..<blockCount {
                        guard result.count < remaining else { return }
                        let blockOffset = Int(physBlock + UInt64(b)) * Int(sb.blockSize)
                        let bytesToRead = min(Int(sb.blockSize), remaining - result.count)
                        guard blockOffset + bytesToRead <= self.data.count else {
                            throw ImageMeasurementError.invalidImageFile("Extent data block out of bounds")
                        }
                        result.append(self.data[(self.data.startIndex + blockOffset)..<(self.data.startIndex + blockOffset + bytesToRead)])
                    }
                }
            } else {
                for i in 0..<entries {
                    guard result.count < remaining else { return }
                    let offset = 12 + i * 12
                    let leafLo = UInt64(nodeData.uint32(at: offset + 4))
                    let leafHi = UInt64(nodeData.uint16(at: offset + 8))
                    let leafBlock = leafHi << 32 | leafLo

                    let blockOffset = Int(leafBlock) * Int(sb.blockSize)
                    guard blockOffset + Int(sb.blockSize) <= self.data.count else {
                        throw ImageMeasurementError.invalidImageFile("Extent index block out of bounds")
                    }
                    let childData = self.data.subdata(in: (self.data.startIndex + blockOffset)..<(self.data.startIndex + blockOffset + Int(sb.blockSize)))
                    try readExtentNode(data: childData, into: &result, remaining: remaining)
                }
            }
        }

        // MARK: Indirect Blocks (eager read)

        private func readIndirectBlocks(iBlock: Data, fileSize: UInt64) throws -> Data {
            var result = Data(capacity: Int(fileSize))
            let remaining = Int(fileSize)
            let ptrsPerBlock = Int(sb.blockSize) / 4

            for i in 0..<12 {
                guard result.count < remaining else { return result }
                try appendBlock(iBlock.uint32(at: i * 4), to: &result, remaining: remaining)
            }

            guard result.count < remaining else { return result }
            try readIndirect(blockNum: iBlock.uint32(at: 48), depth: 1, ptrsPerBlock: ptrsPerBlock, into: &result, remaining: remaining)

            guard result.count < remaining else { return result }
            try readIndirect(blockNum: iBlock.uint32(at: 52), depth: 2, ptrsPerBlock: ptrsPerBlock, into: &result, remaining: remaining)

            guard result.count < remaining else { return result }
            try readIndirect(blockNum: iBlock.uint32(at: 56), depth: 3, ptrsPerBlock: ptrsPerBlock, into: &result, remaining: remaining)

            return result
        }

        private func readIndirect(blockNum: UInt32, depth: Int, ptrsPerBlock: Int, into result: inout Data, remaining: Int) throws {
            guard blockNum != 0 else { return }
            let blockOffset = Int(blockNum) * Int(sb.blockSize)
            guard blockOffset + Int(sb.blockSize) <= data.count else {
                throw ImageMeasurementError.invalidImageFile("Indirect block out of bounds")
            }
            let block = data.subdata(in: (data.startIndex + blockOffset)..<(data.startIndex + blockOffset + Int(sb.blockSize)))

            if depth == 1 {
                for i in 0..<ptrsPerBlock {
                    guard result.count < remaining else { return }
                    try appendBlock(block.uint32(at: i * 4), to: &result, remaining: remaining)
                }
            } else {
                for i in 0..<ptrsPerBlock {
                    guard result.count < remaining else { return }
                    try readIndirect(blockNum: block.uint32(at: i * 4), depth: depth - 1, ptrsPerBlock: ptrsPerBlock, into: &result, remaining: remaining)
                }
            }
        }

        private func appendBlock(_ blockNum: UInt32, to result: inout Data, remaining: Int) throws {
            guard blockNum != 0 else { return }
            let blockOffset = Int(blockNum) * Int(sb.blockSize)
            let bytesToRead = min(Int(sb.blockSize), remaining - result.count)
            guard blockOffset + bytesToRead <= data.count else {
                throw ImageMeasurementError.invalidImageFile("Data block out of bounds")
            }
            result.append(data[(data.startIndex + blockOffset)..<(data.startIndex + blockOffset + bytesToRead)])
        }
    }
}
