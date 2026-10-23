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
//  Disk.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding
import Foundation

extension GPT {
    private static let sectorSize = 512

    public struct Disk<Image: ReadableImage> {
        private let partitionEntries: [GPT.PartitionEntry]
        private let image: Image

        public init(image: Image) throws {
            self.image = image

            guard image.imageSize > UInt64(sectorSize * 2) else {
                throw ImageMeasurementError.invalidImageFile("Image too small to contain GPT header")
            }

            let headerData = try image.read(offset: UInt64(sectorSize), length: 512)
            var headerSlice = ArraySlice<UInt8>(headerData)
            let header = try GPT.Header(from: &headerSlice)

            let entryStart = try header.partitionEntryLBA.safeMultiply(UInt64(sectorSize))
            let entrySize = UInt64(header.sizeOfPartitionEntry)
            let entryCount = UInt64(header.numberOfPartitionEntries)
            let entryEnd = try entryStart.safeAdd(entryCount.safeMultiply(entrySize))

            guard entryEnd <= image.imageSize else {
                throw ImageMeasurementError.invalidImageFile("Partition entry array extends beyond image")
            }

            let entryTableData = try image.read(offset: entryStart, length: Int(entryCount * entrySize))
            let entryTableBase = entryTableData.startIndex
            var entries: [GPT.PartitionEntry] = []
            for i in 0..<Int(entryCount) {
                let offset = entryTableBase + i * Int(entrySize)
                var slice = ArraySlice<UInt8>(entryTableData[offset..<offset + Int(entrySize)])
                entries.append(try GPT.PartitionEntry(from: &slice))
            }
            self.partitionEntries = entries
        }

        public var partitionLabels: [String] {
            partitionEntries.filter { !$0.isEmpty }.map(\.label)
        }

        public func partitionData(index: Int) throws -> Data {
            let zeroIndex = index - 1
            guard zeroIndex >= 0, zeroIndex < partitionEntries.count else {
                throw ImageMeasurementError.partitionNotFound(index: index)
            }
            let entry = partitionEntries[zeroIndex]
            guard !entry.isEmpty else {
                throw ImageMeasurementError.partitionNotFound(index: index)
            }
            return try data(for: entry, label: "index \(index)")
        }

        public func partitionData(label: String) throws -> Data {
            guard let entry = partitionEntries.first(where: { !$0.isEmpty && $0.label == label }) else {
                throw ImageMeasurementError.partitionNotFoundByLabel(label: label)
            }
            return try data(for: entry, label: label)
        }

        public func partitionEndOffset(index: Int) throws -> UInt64 {
            let zeroIndex = index - 1
            guard zeroIndex >= 0, zeroIndex < partitionEntries.count else {
                throw ImageMeasurementError.partitionNotFound(index: index)
            }
            let entry = partitionEntries[zeroIndex]
            guard !entry.isEmpty else {
                throw ImageMeasurementError.partitionNotFound(index: index)
            }
            return try entry.endingLBA.safeAdd(1).safeMultiply(UInt64(sectorSize))
        }

        public func partitionEndOffset(label: String) throws -> UInt64 {
            guard let entry = partitionEntries.first(where: { !$0.isEmpty && $0.label == label }) else {
                throw ImageMeasurementError.partitionNotFoundByLabel(label: label)
            }
            return try entry.endingLBA.safeAdd(1).safeMultiply(UInt64(sectorSize))
        }

        private func data(for entry: GPT.PartitionEntry, label: String) throws -> Data {
            let start = try entry.startingLBA.safeMultiply(UInt64(sectorSize))
            let end = try entry.endingLBA.safeAdd(1).safeMultiply(UInt64(sectorSize))

            guard start <= end else {
                throw ImageMeasurementError.invalidImageFile("Partition '\(label)' has invalid bounds (start > end)")
            }

            guard end <= image.imageSize else {
                throw ImageMeasurementError.invalidImageFile("Partition '\(label)' extends beyond image")
            }

            return try image.read(offset: start, length: Int(end - start))
        }
    }
}

extension GPT.Disk where Image == Data {
    package init(imageData: Data) throws {
        try self.init(image: imageData)
    }
}

extension UInt64 {
    fileprivate func safeAdd(_ other: UInt64) throws -> UInt64 {
        let (result, overflow) = self.addingReportingOverflow(other)
        guard !overflow else {
            throw ImageMeasurementError.invalidImageFile("Arithmetic overflow in partition table")
        }
        return result
    }

    fileprivate func safeMultiply(_ other: UInt64) throws -> UInt64 {
        let (result, overflow) = self.multipliedReportingOverflow(by: other)
        guard !overflow else {
            throw ImageMeasurementError.invalidImageFile("Arithmetic overflow in partition table")
        }
        return result
    }
}
