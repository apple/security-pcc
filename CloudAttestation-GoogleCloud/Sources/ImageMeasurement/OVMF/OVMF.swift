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
//  OVMF.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding
import Crypto
import Foundation

public struct OVMFFirmware: Sendable {
    private let firmwareData: Data

    public init(data: Data) {
        self.firmwareData = data
    }

    public var mrtd: Data {
        get throws {
            let regions = try extractMaterialRegions()
            var digest = SHA384()
            for region in regions {
                try Self.updateDigest(&digest, with: region)
            }
            return Data(digest.finalize())
        }
    }
}

// MARK: - GUID Table Parsing

extension OVMFFirmware {
    private static let fwGUIDTableFooterGUID = [UInt8](efiGUID: "96b582de-1fb2-45f7-baea-a366c55a082d")
    private static let tdxMetadataOffsetGUID = [UInt8](efiGUID: "e47a6535-984a-4798-865e-4685a7bf8ec2")
    private static let tdxMetadataGUID = [UInt8](efiGUID: "e9eaf9f3-168e-44d5-a8eb-7f4d8738f6ae")

    private static let fwGUIDTableEndOffset = 0x20
    private static let fwGUIDEntrySize = 18

    private func parseGUIDTable() throws -> [(data: Data, guid: Data)] {
        let len = firmwareData.count

        let footerOffset = len - Self.fwGUIDTableEndOffset - Self.fwGUIDEntrySize
        guard footerOffset >= 0, footerOffset + Self.fwGUIDEntrySize <= len else {
            throw ImageMeasurementError.invalidImageFile("Firmware too small for GUID table")
        }

        let footerSize = Int(firmwareData.uint16(at: footerOffset))
        let footerGUID = firmwareData.subdata(in: (footerOffset + 2)..<(footerOffset + 18))

        guard footerGUID.elementsEqual(Self.fwGUIDTableFooterGUID) else {
            throw ImageMeasurementError.invalidImageFile("GUID table footer not found")
        }

        guard footerSize >= Self.fwGUIDEntrySize else {
            throw ImageMeasurementError.invalidImageFile("Invalid GUID table size")
        }

        let tableContentSize = Int(footerSize) - Self.fwGUIDEntrySize
        let tableStart = len - Self.fwGUIDTableEndOffset - Int(footerSize)
        guard tableStart >= 0 else {
            throw ImageMeasurementError.invalidImageFile("GUID table extends beyond firmware start")
        }

        var entries: [(data: Data, guid: Data)] = []
        var remaining = tableContentSize

        while remaining > 0 {
            guard remaining >= Self.fwGUIDEntrySize else {
                throw ImageMeasurementError.invalidImageFile("Truncated GUID table entry")
            }

            let entryEnd = tableStart + remaining
            let entryHeaderOffset = entryEnd - Self.fwGUIDEntrySize
            let entrySize = Int(firmwareData.uint16(at: entryHeaderOffset))
            let entryGUID = firmwareData.subdata(in: (entryHeaderOffset + 2)..<(entryHeaderOffset + 18))

            guard entrySize >= Self.fwGUIDEntrySize, entrySize <= remaining else {
                throw ImageMeasurementError.invalidImageFile("Corrupted GUID table entry")
            }

            let blockStart = entryEnd - entrySize
            let blockData = firmwareData.subdata(in: blockStart..<(blockStart + entrySize - Self.fwGUIDEntrySize))
            entries.append((data: blockData, guid: entryGUID))

            remaining -= entrySize
        }

        return entries
    }

    private func findGUIDBlock(guid: [UInt8]) throws -> Data {
        let entries = try parseGUIDTable()
        for entry in entries where entry.guid.elementsEqual(guid) {
            return entry.data
        }
        throw ImageMeasurementError.invalidImageFile("GUID block not found")
    }
}

// MARK: - TDX Metadata

extension OVMFFirmware {
    private static let tdxMetadataDescriptorMagic: UInt32 = 0x4656_4454
    private static let tdxMetadataVersion: UInt32 = 1

    private static let sectionTypeBFV: UInt32 = 0
    private static let sectionTypeCFV: UInt32 = 1
    private static let sectionTypeTDHOB: UInt32 = 2
    private static let sectionTypeTempMem: UInt32 = 3
    private static let attributeExtendMR: UInt32 = 0x0000_0001

    private struct TDXMetadataSection {
        var dataOffset: UInt32
        var dataSize: UInt32
        var memoryBase: UInt64
        var memorySize: UInt64
        var sectionType: UInt32
        var attributes: UInt32
    }

    private func extractTDXMetadata() throws -> [TDXMetadataSection] {
        let len = firmwareData.count

        let block = try findGUIDBlock(guid: Self.tdxMetadataOffsetGUID)
        guard block.count >= 4 else {
            throw ImageMeasurementError.invalidImageFile("TDX metadata offset block too small")
        }

        let metadataOffset = Int(block.uint32(at: 0))

        let metadataGUIDOffset = len - metadataOffset - 16
        guard metadataGUIDOffset >= 0, metadataGUIDOffset + 16 <= len else {
            throw ImageMeasurementError.invalidImageFile("TDX metadata GUID offset out of bounds")
        }

        guard firmwareData[metadataGUIDOffset..<(metadataGUIDOffset + 16)].elementsEqual(Self.tdxMetadataGUID) else {
            throw ImageMeasurementError.invalidImageFile("TDX metadata GUID mismatch")
        }

        let descriptorOffset = metadataGUIDOffset + 16
        guard descriptorOffset + 16 <= len else {
            throw ImageMeasurementError.invalidImageFile("TDX metadata descriptor truncated")
        }

        let signature = firmwareData.uint32(at: descriptorOffset)
        guard signature == Self.tdxMetadataDescriptorMagic else {
            throw ImageMeasurementError.invalidImageFile("TDX metadata signature mismatch")
        }

        let version = firmwareData.uint32(at: descriptorOffset + 8)
        guard version == Self.tdxMetadataVersion else {
            throw ImageMeasurementError.invalidImageFile("TDX metadata version mismatch")
        }

        let sectionCount = Int(firmwareData.uint32(at: descriptorOffset + 12))
        let sectionsStart = descriptorOffset + 16

        guard sectionsStart + sectionCount * 32 <= len else {
            throw ImageMeasurementError.invalidImageFile("TDX metadata sections truncated")
        }

        var sections: [TDXMetadataSection] = []
        for i in 0..<sectionCount {
            let offset = sectionsStart + i * 32
            sections.append(
                TDXMetadataSection(
                    dataOffset: firmwareData.uint32(at: offset),
                    dataSize: firmwareData.uint32(at: offset + 4),
                    memoryBase: firmwareData.uint64(at: offset + 8),
                    memorySize: firmwareData.uint64(at: offset + 16),
                    sectionType: firmwareData.uint32(at: offset + 24),
                    attributes: firmwareData.uint32(at: offset + 28)
                )
            )
        }

        return sections
    }
}

// MARK: - Material Regions

extension OVMFFirmware {
    private struct MaterialRegion {
        var gpa: UInt64
        var length: UInt64
        var hostBuffer: Data?
        var extendMR: Bool
    }

    private func extractMaterialRegions() throws -> [MaterialRegion] {
        let sections = try extractTDXMetadata()

        var regions: [MaterialRegion] = []
        var tdhobIndex: Int?

        for section in sections {
            let extendMR = section.attributes & Self.attributeExtendMR != 0

            switch section.sectionType {
            case Self.sectionTypeBFV, Self.sectionTypeCFV:
                let start = Int(section.dataOffset)
                let end = start + Int(section.memorySize)
                guard start >= 0, end <= firmwareData.count else {
                    throw ImageMeasurementError.invalidImageFile("Firmware volume data out of bounds")
                }
                regions.append(
                    MaterialRegion(
                        gpa: section.memoryBase,
                        length: section.memorySize,
                        hostBuffer: firmwareData.subdata(in: start..<end),
                        extendMR: extendMR
                    )
                )

            case Self.sectionTypeTDHOB:
                tdhobIndex = regions.count
                regions.append(
                    MaterialRegion(
                        gpa: section.memoryBase,
                        length: section.memorySize,
                        hostBuffer: nil,
                        extendMR: extendMR
                    )
                )

            case Self.sectionTypeTempMem:
                regions.append(
                    MaterialRegion(
                        gpa: section.memoryBase,
                        length: section.memorySize,
                        hostBuffer: nil,
                        extendMR: extendMR
                    )
                )

            default:
                throw ImageMeasurementError.invalidImageFile("Unsupported TDX metadata section type: \(section.sectionType)")
            }
        }

        guard let hobIndex = tdhobIndex else {
            throw ImageMeasurementError.invalidImageFile("TDX metadata missing TD HOB section")
        }

        let tdhobData = try Self.buildTDHOB(sections: sections, tdhobGPA: regions[hobIndex].gpa, tdhobSize: regions[hobIndex].length)
        regions[hobIndex].hostBuffer = tdhobData

        return regions
    }
}

// MARK: - TDHOB Construction

extension OVMFFirmware {
    private static func buildTDHOB(sections: [TDXMetadataSection], tdhobGPA: UInt64, tdhobSize: UInt64) throws -> Data {
        let numResourceDescriptors = sections.count
        let requiredSize = 56 + 48 * numResourceDescriptors + 8

        guard Int(tdhobSize) >= requiredSize else {
            throw ImageMeasurementError.invalidImageFile("TD HOB buffer overflows region size")
        }

        var buffer = Data(count: Int(tdhobSize))
        var offset = 0

        // Handoff info table (56 bytes)
        buffer.writeLE16(at: offset, value: 1)  // EFI_HOB_TYPE_HANDOFF
        buffer.writeLE16(at: offset + 2, value: 56)
        buffer.writeLE32(at: offset + 8, value: 9)  // Version
        buffer.writeLE64(at: offset + 48, value: tdhobGPA + UInt64(requiredSize - 8))  // EfiEndOfHobList
        offset += 56

        for section in sections {
            buffer.writeLE16(at: offset, value: 3)  // EFI_HOB_TYPE_RESOURCE_DESCRIPTOR
            buffer.writeLE16(at: offset + 2, value: 48)
            buffer.writeLE32(at: offset + 24, value: 0)  // EFI_RESOURCE_SYSTEM_MEMORY
            buffer.writeLE32(at: offset + 28, value: 7)  // PRESENT | INITIALIZED | TESTED
            buffer.writeLE64(at: offset + 32, value: section.memoryBase)
            buffer.writeLE64(at: offset + 40, value: section.memorySize)
            offset += 48
        }

        // End of HOB list
        buffer.writeLE16(at: offset, value: 0xFFFF)  // EFI_HOB_TYPE_END_OF_HOB_LIST
        buffer.writeLE16(at: offset + 2, value: 8)

        return buffer
    }
}

// MARK: - MRTD Digest

extension OVMFFirmware {
    private static let pageSize: UInt64 = 4096
    private static let extensionBufferSize = 128
    private static let mrExtendChunkSize: UInt64 = 256
    private static let pageAddLabel = [UInt8]("MEM.PAGE.ADD".utf8)
    private static let mrExtendLabel = [UInt8]("MR.EXTEND".utf8)

    private static func updateDigest(_ digest: inout SHA384, with region: MaterialRegion) throws {
        let measureBytes = region.extendMR

        if measureBytes {
            guard let data = region.hostBuffer, region.length == UInt64(data.count) else {
                throw ImageMeasurementError.invalidImageFile("Region marked ExtendMR but data size does not match length \(region.length)")
            }
        }

        guard region.gpa % pageSize == 0 else {
            throw ImageMeasurementError.invalidImageFile("Region GPA 0x\(String(region.gpa, radix: 16)) is not page-aligned")
        }
        guard region.length % pageSize == 0 else {
            throw ImageMeasurementError.invalidImageFile("Region length 0x\(String(region.length, radix: 16)) is not page-aligned")
        }

        var buf = [UInt8](repeating: 0, count: extensionBufferSize)

        var i: UInt64 = 0
        while i < region.length {
            if i % pageSize == 0 {
                buf.resetBytes()
                buf.copyLabel(pageAddLabel)
                buf.writeLE64(at: 16, value: region.gpa + i)
                digest.update(data: buf)
            }

            if measureBytes, let hostBuffer = region.hostBuffer {
                buf.resetBytes()
                buf.copyLabel(mrExtendLabel)
                buf.writeLE64(at: 16, value: region.gpa + i)
                digest.update(data: buf)

                let chunkStart = Int(i)
                let chunkMid = chunkStart + extensionBufferSize
                let chunkEnd = chunkStart + Int(mrExtendChunkSize)
                digest.update(data: hostBuffer[chunkStart..<chunkMid])
                digest.update(data: hostBuffer[chunkMid..<chunkEnd])
            }

            i += mrExtendChunkSize
        }
    }
}

// MARK: - Extensions

extension [UInt8] {
    fileprivate init(efiGUID string: String) {
        let hex = string.filter { $0 != "-" }
        let allBytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }

        // EFI GUID mixed-endian encoding: first 3 fields are little-endian, last 8 bytes are raw
        self = [UInt8](repeating: 0, count: 16)
        self[0] = allBytes[3]
        self[1] = allBytes[2]
        self[2] = allBytes[1]
        self[3] = allBytes[0]
        self[4] = allBytes[5]
        self[5] = allBytes[4]
        self[6] = allBytes[7]
        self[7] = allBytes[6]
        for i in 8..<16 { self[i] = allBytes[i] }
    }

    fileprivate mutating func writeLE64(at offset: Int, value: UInt64) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        self[offset + 4] = UInt8(truncatingIfNeeded: value >> 32)
        self[offset + 5] = UInt8(truncatingIfNeeded: value >> 40)
        self[offset + 6] = UInt8(truncatingIfNeeded: value >> 48)
        self[offset + 7] = UInt8(truncatingIfNeeded: value >> 56)
    }

    fileprivate mutating func copyLabel(_ label: [UInt8]) {
        for j in 0..<label.count { self[j] = label[j] }
    }

    fileprivate mutating func resetBytes() {
        for i in 0..<count { self[i] = 0 }
    }
}

extension Data {
    fileprivate mutating func writeLE16(at offset: Int, value: UInt16) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    fileprivate mutating func writeLE32(at offset: Int, value: UInt32) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    fileprivate mutating func writeLE64(at offset: Int, value: UInt64) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        self[offset + 4] = UInt8(truncatingIfNeeded: value >> 32)
        self[offset + 5] = UInt8(truncatingIfNeeded: value >> 40)
        self[offset + 6] = UInt8(truncatingIfNeeded: value >> 48)
        self[offset + 7] = UInt8(truncatingIfNeeded: value >> 56)
    }
}
