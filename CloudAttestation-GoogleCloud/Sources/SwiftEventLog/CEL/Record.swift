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
//  Record.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding
import Common

extension CEL {
    public struct Record: Sendable {
        package var recnum: UInt64
        package var index: Index
        package var digests: [CELDigest]
        package var content: Content

        /// The serialized Content TLV (`[type][length][value]`) — the bytes the
        /// record's `digests` cover. Callers verify `H(contentTLVBytes) == digest`
        /// to bind `content` to the hardware register. Byte-exact with the on-wire
        /// bytes: every `Content` variant round-trips and the inner parsers reject
        /// trailing bytes.
        package var contentTLVBytes: [UInt8] {
            content.encoded()
        }

        package init(recnum: UInt64, index: Index, digests: [CELDigest], content: Content) {
            self.recnum = recnum
            self.index = index
            self.digests = digests
            self.content = content
        }
    }

    public enum Index: Sendable, Equatable {
        case pcr(UInt32)
        case ccmr(UInt32)
        case nvIndex(UInt32)
        case other(type: UInt8, value: UInt64)
    }
}

extension CEL.Record {
    private static let recnumType: UInt8 = 0
    private static let pcrType: UInt8 = 1
    private static let nvIndexType: UInt8 = 2
    private static let ccmrType: UInt8 = 108
    private static let digestsType: UInt8 = 3

    package init(from tlvs: [TLV]) throws {
        guard let recnumTLV = tlvs.first, recnumTLV.type == Self.recnumType else {
            throw CELError.missingField("RECNUM")
        }
        self.recnum = recnumTLV.value.uintVar(byteOrder: .bigEndian)

        guard tlvs.count >= 4 else {
            throw CELError.missingField("record requires at least 4 TLVs, got \(tlvs.count)")
        }

        let indexTLV = tlvs[1]
        let indexValue = indexTLV.value.uintVar(byteOrder: .bigEndian)
        switch indexTLV.type {
        case Self.pcrType:
            self.index = .pcr(try indexValue.narrowedToUInt32(field: "PCR"))
        case Self.nvIndexType:
            self.index = .nvIndex(try indexValue.narrowedToUInt32(field: "NV_INDEX"))
        case Self.ccmrType:
            self.index = .ccmr(try indexValue.narrowedToUInt32(field: "CCMR"))
        default:
            self.index = .other(type: indexTLV.type, value: indexValue)
        }

        let digestsTLV = tlvs[2]
        guard digestsTLV.type == Self.digestsType else {
            throw CELError.unexpectedTLVType(expected: Self.digestsType, got: digestsTLV.type)
        }
        self.digests = try Self.parseDigests(from: digestsTLV.value)

        let contentTLV = tlvs[3]
        self.content = try Content(from: contentTLV)
    }

    private static func parseDigests(from bytes: [UInt8]) throws -> [CELDigest] {
        var buffer = ArraySlice(bytes)
        var digests: [CELDigest] = []
        while !buffer.isEmpty {
            let tlv = try TLV(from: &buffer)
            guard let algorithm = Algorithm(rawValue: tlv.type) else {
                throw CELError.invalidDigestAlgorithm(tlv.type)
            }
            digests.append(CELDigest(algorithm: algorithm, data: tlv.value))
        }
        return digests
    }
}

extension UInt64 {
    /// Narrows to `UInt32`, throwing a CEL parse error tagged with `field` when
    /// the value does not fit.
    fileprivate func narrowedToUInt32(field: String) throws -> UInt32 {
        guard let narrowed = UInt32(exactly: self) else {
            throw CELError.invalidData("\(field) index \(self) exceeds UInt32")
        }
        return narrowed
    }
}

// MARK: - CustomDebugStringConvertible

extension CEL.Index: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .pcr(let idx):
            return "PCR=\(idx)"
        case .ccmr(let idx):
            return "RTMR=\(idx - 1)"
        case .nvIndex(let idx):
            return "NV=0x\(String(idx, radix: 16))"
        case .other(let type, let value):
            return "type=0x\(String(type, radix: 16)),value=\(value)"
        }
    }
}

extension CEL.Record: CustomDebugStringConvertible {
    public var debugDescription: String {
        let digestStrs = digests.map { "\($0.algorithm):\($0.data.hexString)" }
        return """
            [\(recnum)] \(index.debugDescription) Digests=[\(digestStrs.joined(separator: ", "))]
                 Content=\(content.debugDescription)
            """
    }
}
