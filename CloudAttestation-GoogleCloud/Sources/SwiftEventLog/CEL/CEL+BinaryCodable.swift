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
//  CEL+BinaryCodable.swift
//  CloudAttestationV2
//

import BinaryCoding
import Common

extension CEL: BinaryCodable {
    package init(from buffer: inout ArraySlice<UInt8>) throws {
        // Parse all TLVs from the buffer
        var tlvs: [TLV] = []
        while !buffer.isEmpty {
            tlvs.append(try TLV(from: &buffer))
        }

        // Group TLVs into records, splitting on RECNUM (type 0)
        var records: [Record] = []
        var currentTLVs: [TLV] = []
        for tlv in tlvs {
            if tlv.type == 0 && !currentTLVs.isEmpty {
                records.append(try Record(from: currentTLVs))
                currentTLVs = []
            }
            currentTLVs.append(tlv)
        }
        if !currentTLVs.isEmpty {
            records.append(try Record(from: currentTLVs))
        }

        self.records = records
    }

    package var byteCount: Int {
        self.records.reduce(0) { $0 + $1.byteCount }
    }

    package func encode(to buffer: inout [UInt8]) {
        for record in self.records {
            buffer.append(record)
        }
    }
}

extension CEL.Record: BinaryCodable {
    private static let recnumType: UInt8 = 0
    private static let pcrType: UInt8 = 1
    private static let nvIndexType: UInt8 = 2
    private static let ccmrType: UInt8 = 108
    private static let digestsType: UInt8 = 3

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        var tlvs: [TLV] = []
        for _ in 0..<4 {
            tlvs.append(try TLV(from: &buffer))
        }
        try self.init(from: tlvs)
    }

    package func encode(to buffer: inout [UInt8]) {
        // RECNUM TLV (type 0): big-endian uint64 in an 8-byte value
        TLV(type: Self.recnumType, value: bigEndianBytes(self.recnum)).encode(to: &buffer)

        // Index TLV
        let (indexType, indexValue) = encodedIndex()
        TLV(type: indexType, value: indexValue).encode(to: &buffer)

        // Digests TLV (type 3): nested TLVs of [algorithmID]+digest
        var digestPayload: [UInt8] = []
        for digest in self.digests {
            TLV(type: digest.algorithm.rawValue, value: digest.data).encode(to: &digestPayload)
        }
        TLV(type: Self.digestsType, value: digestPayload).encode(to: &buffer)

        // Content TLV
        self.content.encode(to: &buffer)
    }

    package var byteCount: Int {
        let digestsPayload = self.digests.reduce(0) { $0 + TLV.headerSize + $1.data.count }
        return (TLV.headerSize + 8)  // recnum TLV
            + (TLV.headerSize + 4)  // index TLV
            + (TLV.headerSize + digestsPayload)  // digests TLV
            + self.content.byteCount  // content TLV (already includes its own header)
    }

    private func encodedIndex() -> (type: UInt8, value: [UInt8]) {
        switch self.index {
        case .pcr(let v):
            return (Self.pcrType, bigEndianBytes(UInt32(v)))
        case .nvIndex(let v):
            return (Self.nvIndexType, bigEndianBytes(UInt32(v)))
        case .ccmr(let v):
            return (Self.ccmrType, bigEndianBytes(UInt32(v)))
        case .other(let type, let value):
            return (type, bigEndianBytes(value))
        }
    }
}

extension Content: BinaryCodable {
    private static let managementType: UInt8 = 4
    private static let pcClientSTDType: UInt8 = 5
    private static let imaTemplateType: UInt8 = 7
    private static let imaTLVType: UInt8 = 8
    private static let cosEventType: UInt8 = 80
    private static let hostCOSEventType: UInt8 = 82

    // Inner-payload tags for nested TLV-bearing variants.
    private static let mgtCelVersionTag: UInt8 = 1
    private static let mgtFirmwareEndTag: UInt8 = 2
    private static let mgtTimestampTag: UInt8 = 80
    private static let mgtStateTransTag: UInt8 = 81
    private static let pccEventTypeTag: UInt8 = 0
    private static let pccEventDataTag: UInt8 = 1
    private static let imaTemplateNameTag: UInt8 = 0
    private static let imaTemplateDataTag: UInt8 = 1

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        let tlv = try TLV(from: &buffer)
        try self.init(from: tlv)
    }

    package var byteCount: Int {
        TLV.headerSize + innerByteCount
    }

    package func encode(to buffer: inout [UInt8]) {
        var inner: [UInt8] = []
        inner.reserveCapacity(innerByteCount)
        encodeInner(into: &inner)
        TLV(type: outerType, value: inner).encode(to: &buffer)
    }

    private var outerType: UInt8 {
        switch self {
        case .management: return Self.managementType
        case .pcClientSTD: return Self.pcClientSTDType
        case .cos: return Self.cosEventType
        case .hostCOS: return Self.hostCOSEventType
        case .imaTemplate: return Self.imaTemplateType
        case .imaTLV: return Self.imaTLVType
        case .unknown(let type, _): return type
        }
    }

    private var innerByteCount: Int {
        switch self {
        case .management(let mgt):
            switch mgt {
            case .celVersion: return TLV.headerSize + 4
            case .firmwareEnd: return TLV.headerSize
            case .timestamp: return TLV.headerSize + 8
            case .stateTrans: return TLV.headerSize + 1
            }
        case .pcClientSTD(let pcc):
            return (TLV.headerSize + 4) + (TLV.headerSize + pcc.eventData.count)
        case .cos(let cos):
            return TLV.headerSize + cos.eventContent.count
        case .hostCOS(let hostCOS):
            return TLV.headerSize + hostCOS.eventContent.count
        case .imaTemplate(let ima):
            return (TLV.headerSize + ima.templateName.utf8.count) + (TLV.headerSize + ima.templateData.count)
        case .imaTLV(let data):
            return data.count
        case .unknown(_, let data):
            return data.count
        }
    }

    private func encodeInner(into buffer: inout [UInt8]) {
        switch self {
        case .management(let mgt):
            switch mgt {
            case .celVersion(let major, let minor):
                var value: [UInt8] = []
                value.append(major, byteOrder: .bigEndian)
                value.append(minor, byteOrder: .bigEndian)
                TLV(type: Self.mgtCelVersionTag, value: value).encode(to: &buffer)
            case .firmwareEnd:
                TLV(type: Self.mgtFirmwareEndTag, value: []).encode(to: &buffer)
            case .timestamp(let ts):
                TLV(type: Self.mgtTimestampTag, value: bigEndianBytes(ts)).encode(to: &buffer)
            case .stateTrans(let st):
                TLV(type: Self.mgtStateTransTag, value: [st.rawValue]).encode(to: &buffer)
            }
        case .pcClientSTD(let pcc):
            TLV(type: Self.pccEventTypeTag, value: bigEndianBytes(pcc.eventType)).encode(to: &buffer)
            TLV(type: Self.pccEventDataTag, value: pcc.eventData).encode(to: &buffer)
        case .cos(let cos):
            TLV(type: cos.cosType, value: cos.eventContent).encode(to: &buffer)
        case .hostCOS(let hostCOS):
            TLV(type: hostCOS.contentType, value: hostCOS.eventContent).encode(to: &buffer)
        case .imaTemplate(let ima):
            TLV(type: Self.imaTemplateNameTag, value: Array(ima.templateName.utf8)).encode(to: &buffer)
            TLV(type: Self.imaTemplateDataTag, value: ima.templateData).encode(to: &buffer)
        case .imaTLV(let data):
            buffer.append(contentsOf: data)
        case .unknown(_, let data):
            buffer.append(contentsOf: data)
        }
    }
}

private func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    var out: [UInt8] = []
    out.append(value, byteOrder: .bigEndian)
    return out
}
