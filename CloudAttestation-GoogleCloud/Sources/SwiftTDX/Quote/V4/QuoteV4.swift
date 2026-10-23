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
//  Quote.swift
//  CloudAttestationV2
//
//  Created by David Zech on 12/19/25.
//
import Foundation
import BinaryCoding
import Common

extension V4 {
    public struct Quote: Sendable, BinaryDecodable {
        package var header: Header
        package var body: Body
        var signatureDataLen: UInt32 { UInt32(signatureData.byteCount) }
        var signatureData: ECDSA256QuoteSignatureData

        package var byteCount: Int {
            header.byteCount + body.byteCount + signatureDataLen.byteCount + signatureData.byteCount
        }

        static let byteOrder = ByteOrder.littleEndian

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.header = try Header(from: &buffer)
            self.body = try Body(from: &buffer)
            let sigDataLen = try UInt32(from: &buffer)
            self.signatureData = try ECDSA256QuoteSignatureData(from: try buffer.readBytes(count: Int(sigDataLen)))

            // Tolerate trailing zero-padding
            guard buffer.allSatisfy({ $0 == 0 }) else {
                throw ParseError.unconsumedTrailingData(bytes: buffer)
            }
            buffer = buffer[buffer.endIndex...]
        }
    }

    package struct Header: StaticSized, BinaryDecodable {
        let version: UInt16 = 4
        package var attestationKeyType: AttestationKeyType
        package var teeType: TEEType
        var _reserved0: [2 of UInt8] = .init(repeating: 0)
        var _reserved1: [2 of UInt8] = .init(repeating: 0)
        package var qeVendorID: UUID
        package var userData: InlineArray<20, UInt8>

        // TODO: this might change if we support encoding
        var raw: ArraySlice<UInt8>

        @StructureSize
        package static var byteCount: Int {
            \Self.version
            \Self.attestationKeyType
            \Self.teeType
            \Self._reserved0
            \Self._reserved1
            \Self.qeVendorID
            \Self.userData
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let initial = buffer
            let start = buffer.startIndex
            let version = try UInt16(from: &buffer)
            guard version == self.version else {
                throw ParseError.invalidHeaderVersion(value: version)
            }
            self.attestationKeyType = try buffer.read()
            self.teeType = try buffer.read()
            self._reserved0 = try buffer.read()
            self._reserved1 = try buffer.read()
            self.qeVendorID = try buffer.read()
            self.userData = try buffer.read()
            let end = buffer.startIndex
            assert(end - start == Self.byteCount)
            self.raw = initial[..<end]
        }
    }

    package struct Body: BinaryDecodable, StaticSized {
        package var teeTcbSvn: [16 of UInt8]
        package var mrSeam: [48 of UInt8]
        package var mrSignerSeam: [48 of UInt8] = .init(repeating: 0)
        package var seamAttributes: [8 of UInt8] = .init(repeating: 0)
        package var tdAttributes: TDAttributes
        package var xfam: XFAM
        package var mrtd: [48 of UInt8]
        package var mrConfigId: [48 of UInt8]
        package var mrOwner: [48 of UInt8]
        package var mrOwnerConfig: [48 of UInt8]
        package var rtmr0: [48 of UInt8]
        package var rtmr1: [48 of UInt8]
        package var rtmr2: [48 of UInt8]
        package var rtmr3: [48 of UInt8]
        package var reportData: [64 of UInt8]

        // TODO: this might change if we support encoding
        var raw: ArraySlice<UInt8>

        @StructureSize
        package static var byteCount: Int {
            \Self.teeTcbSvn
            \Self.mrSeam
            \Self.mrSignerSeam
            \Self.seamAttributes
            \Self.tdAttributes
            \Self.xfam
            \Self.mrtd
            \Self.mrConfigId
            \Self.mrOwner
            \Self.mrOwnerConfig
            \Self.rtmr0
            \Self.rtmr1
            \Self.rtmr2
            \Self.rtmr3
            \Self.reportData
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let initial = buffer
            let start = buffer.startIndex
            self.teeTcbSvn = try buffer.readInlineArray()
            self.mrSeam = try buffer.readInlineArray()
            self.mrSignerSeam = try buffer.readInlineArray()
            self.seamAttributes = try buffer.readInlineArray()
            self.tdAttributes = try TDAttributes(from: &buffer)
            self.xfam = try XFAM(from: &buffer)
            self.mrtd = try buffer.readInlineArray()
            self.mrConfigId = try buffer.readInlineArray()
            self.mrOwner = try buffer.readInlineArray()
            self.mrOwnerConfig = try buffer.readInlineArray()
            self.rtmr0 = try buffer.readInlineArray()
            self.rtmr1 = try buffer.readInlineArray()
            self.rtmr2 = try buffer.readInlineArray()
            self.rtmr3 = try buffer.readInlineArray()
            self.reportData = try buffer.readInlineArray()
            let end = buffer.startIndex
            assert(end - start == Self.byteCount)
            self.raw = initial[..<end]
        }
    }

    package struct ECDSA256QuoteSignatureData: Sendable, BinaryDecodable {
        package var signature: [64 of UInt8]
        package var ecdsaAttestationKey: [64 of UInt8]
        package var qeCertificationData: QECertificationData

        package var byteCount: Int {
            [64 of UInt8].byteCount + [64 of UInt8].byteCount + qeCertificationData.byteCount
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.signature = try buffer.readInlineArray()
            self.ecdsaAttestationKey = try buffer.readInlineArray()
            self.qeCertificationData = try QECertificationData(from: &buffer)
        }
    }

    package struct QECertificationData: Sendable, BinaryDecodable {
        package var certificationDataType: QECertificationDataType
        package var size: UInt32 { UInt32(data.byteCount) }
        package var data: CertificationData

        package var byteCount: Int {
            QECertificationDataType.byteCount + UInt32.byteCount + data.byteCount
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.certificationDataType = try QECertificationDataType(from: &buffer)
            let size = try UInt32(from: &buffer)
            self.data = try CertificationData(from: try buffer.readBytes(count: Int(size)), with: self.certificationDataType)
            guard data.byteCount == size else {
                throw ParseError.invalidCertificationDataSize(count: data.byteCount)
            }
        }
    }

    package enum QECertificationDataType: UInt16, StaticSized, BinaryDecodable {
        case plaintextPpid = 1
        case encryptedPpidWithRSA2048 = 2
        case encryptedPpidWithRSA3072 = 3
        case plaintextPckLeafCertificate = 4
        case concatenatedPCKCertChain = 5
        case qeReportCertificationData = 6
        case platformManifest = 7

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let u16 = try UInt16(from: &buffer)

            guard let s = Self(rawValue: u16) else {
                throw ParseError.invalidQECertificationDataType(value: u16)
            }

            self = s
        }
    }

    package enum CertificationData: Sendable, TaggedBinaryDecodable {
        package typealias Tag = QECertificationDataType

        case plaintexPpid([UInt8])
        case encryptedPpidWithRSA2048([UInt8])
        case encryptedPpidWithRSA3072([UInt8])
        case plaintextPckLeafCertificate([UInt8])
        case concatenatedPCKCertChain([UInt8])
        case qeReportCertificationData(QEReportCertificationData)
        case platformManifest([UInt8])

        package var type: QECertificationDataType {
            switch self {
            case .plaintexPpid(_):
                .plaintextPpid
            case .encryptedPpidWithRSA2048(_):
                .encryptedPpidWithRSA2048
            case .encryptedPpidWithRSA3072(_):
                .encryptedPpidWithRSA3072
            case .plaintextPckLeafCertificate(_):
                .plaintextPckLeafCertificate
            case .concatenatedPCKCertChain(_):
                .concatenatedPCKCertChain
            case .qeReportCertificationData(_):
                .qeReportCertificationData
            case .platformManifest(_):
                .platformManifest
            }
        }

        package var byteCount: Int {
            switch self {
            case .plaintexPpid(let array):
                fallthrough
            case .encryptedPpidWithRSA2048(let array):
                fallthrough
            case .encryptedPpidWithRSA3072(let array):
                fallthrough
            case .plaintextPckLeafCertificate(let array):
                fallthrough
            case .concatenatedPCKCertChain(let array):
                fallthrough
            case .platformManifest(let array):
                array.count
            case .qeReportCertificationData(let qEReportCertificationData):
                qEReportCertificationData.byteCount
            }
        }

        package init(from buffer: inout ArraySlice<UInt8>, with tag: QECertificationDataType) throws {
            switch tag {
            case .plaintextPpid:
                self = .plaintexPpid(try .init(from: &buffer))
            case .encryptedPpidWithRSA2048:
                self = .encryptedPpidWithRSA2048(try .init(from: &buffer))
            case .encryptedPpidWithRSA3072:
                self = .encryptedPpidWithRSA3072(try .init(from: &buffer))
            case .plaintextPckLeafCertificate:
                self = .plaintextPckLeafCertificate(try .init(from: &buffer))
            case .concatenatedPCKCertChain:
                self = .concatenatedPCKCertChain(try .init(from: &buffer))
            case .qeReportCertificationData:
                self = .qeReportCertificationData(try QEReportCertificationData(from: &buffer))
            case .platformManifest:
                self = .platformManifest(try .init(from: &buffer))
            }
        }
    }

    package struct QEReportCertificationData: Sendable, BinaryDecodable, Sized {
        package var qeReport: EnclaveReport
        package var qeReportSignature: [64 of UInt8]
        package var qeAuthenticationData: QEAuthenticationData
        @Recursive
        package var qeCertificationData: QECertificationData

        package var byteCount: Int {
            EnclaveReport.byteCount + [64 of UInt8].byteCount + qeAuthenticationData.byteCount + qeCertificationData.byteCount
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.qeReport = try EnclaveReport(from: &buffer)
            self.qeReportSignature = try buffer.readInlineArray()
            self.qeAuthenticationData = try QEAuthenticationData(from: &buffer)
            self.qeCertificationData = try QECertificationData(from: &buffer)
        }

        package init(
            qeReport: EnclaveReport,
            qeReportSignature: [64 of UInt8],
            qeAuthenticationData: QEAuthenticationData,
            qeCertificationData: QECertificationData
        ) {
            self.qeReport = qeReport
            self.qeReportSignature = qeReportSignature
            self.qeAuthenticationData = qeAuthenticationData
            self.qeCertificationData = qeCertificationData
        }
    }

    package struct EnclaveReport: StaticSized, BinaryDecodable {
        package var cpuSvn: [16 of UInt8]
        package var miscSelect: MISCSelect
        var _reserved0: [28 of UInt8] = .init(repeating: 0)
        package var attributes: EnclaveAttributes
        package var mrEnclave: [32 of UInt8]
        var _reserved1: [32 of UInt8] = .init(repeating: 0)
        package var mrSigner: [32 of UInt8]
        var _reserved2: [96 of UInt8] = .init(repeating: 0)
        package var isvProdId: UInt16
        package var isvSvn: UInt16
        var _reserved3: [60 of UInt8] = .init(repeating: 0)
        package var reportData: [64 of UInt8]

        // TODO: This will probably change if we support Encoding.
        var raw: ArraySlice<UInt8>

        @StructureSize
        package static var byteCount: Int {
            \Self.cpuSvn
            \Self.miscSelect
            \Self._reserved0
            \Self.attributes
            \Self.mrEnclave
            \Self._reserved1
            \Self.mrSigner
            \Self._reserved2
            \Self.isvProdId
            \Self.isvSvn
            \Self._reserved3
            \Self.reportData
        }

        package init(
            cpuSvn: InlineArray<16, UInt8>,
            miscSelect: V4.MISCSelect = V4.MISCSelect(rawValue: 0),
            attributes: EnclaveAttributes = EnclaveAttributes(flags: [], xfrm: []),
            mrEnclave: InlineArray<32, UInt8>,
            mrSigner: InlineArray<32, UInt8>,
            isvProdId: UInt16,
            isvSvn: UInt16,
            reportData: InlineArray<64, UInt8> = .init(repeating: 0)
        ) {
            self.cpuSvn = cpuSvn
            self.miscSelect = miscSelect
            self.attributes = attributes
            self.mrEnclave = mrEnclave
            self.mrSigner = mrSigner
            self.isvProdId = isvProdId
            self.isvSvn = isvSvn
            self.reportData = reportData
            self.raw = ArraySlice<UInt8>()
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let initial = buffer
            let start = buffer.startIndex
            self.cpuSvn = try InlineArray(from: &buffer)
            self.miscSelect = try MISCSelect(from: &buffer)
            self._reserved0 = try InlineArray(from: &buffer)
            self.attributes = try EnclaveAttributes(from: &buffer)
            self.mrEnclave = try InlineArray(from: &buffer)
            self._reserved1 = try InlineArray(from: &buffer)
            self.mrSigner = try InlineArray(from: &buffer)
            self._reserved2 = try InlineArray(from: &buffer)
            self.isvProdId = try UInt16(from: &buffer)
            self.isvSvn = try UInt16(from: &buffer)
            self._reserved3 = try InlineArray(from: &buffer)
            self.reportData = try InlineArray(from: &buffer)
            let end = buffer.startIndex
            assert(end - start == Self.byteCount)
            self.raw = initial[..<end]
            assert(raw.count == Self.byteCount)
        }
    }

    package struct MISCSelect: OptionSet, StaticSized, BinaryDecodable {
        package let rawValue: UInt32

        package init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.init(rawValue: try UInt32(from: &buffer))
        }
    }

    package struct EnclaveAttributes: StaticSized, BinaryDecodable {
        package var flags: Flags
        package var xfrm: XFRM

        // SGX XFRM is the same XSAVE-state-component bitmap as TDX XFAM (both mirror
        // XCR0). Reuse the XFAM type so consumers get the named flag constants.
        package typealias XFRM = V4.XFAM

        @StructureSize
        package static var byteCount: Int {
            \Self.flags
            \Self.xfrm
        }

        package init(flags: Flags, xfrm: XFRM) {
            self.flags = flags
            self.xfrm = xfrm
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.flags = try Flags(from: &buffer)
            self.xfrm = try XFRM(from: &buffer)
        }

        package struct Flags: OptionSet, StaticSized, BinaryDecodable {
            package let rawValue: UInt64

            package init(rawValue: UInt64) {
                self.rawValue = rawValue
            }

            package init(from buffer: inout ArraySlice<UInt8>) throws {
                self = Self(rawValue: try buffer.readUInt64())
            }

            package static let initialized = Flags(rawValue: 1 << 0)  // bit 0: INIT
            package static let debug = Flags(rawValue: 1 << 1)  // bit 1: DEBUG
            package static let mode64Bit = Flags(rawValue: 1 << 2)  // bit 2: MODE64BIT
            // bit 3: reserved
            package static let provisionKey = Flags(rawValue: 1 << 4)  // bit 4: PROVISIONKEY
            package static let einitTokenKey = Flags(rawValue: 1 << 5)  // bit 5: EINITTOKENKEY
            package static let cet = Flags(rawValue: 1 << 6)  // bit 6: CET
            package static let kss = Flags(rawValue: 1 << 7)  // bit 7: KSS
            // bits 8-9: reserved
            package static let aexNotify = Flags(rawValue: 1 << 10)  // bit 10: AEX_NOTIFY
        }
    }

    package struct QEAuthenticationData: Sized, BinaryDecodable {
        package var size: UInt16 { UInt16(bytes.count) }
        package var bytes: [UInt8]

        package var byteCount: Int {
            UInt16.byteCount + bytes.count
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let size = try UInt16(from: &buffer)
            self.bytes = [UInt8](try buffer.readBytes(count: Int(size)))
            guard self.bytes.count == Int(size) else {
                throw ParseError.invalidQEAuthenticationDataSize(count: self.bytes.count)
            }
        }
    }

    package enum AttestationKeyType: UInt16, StaticSized, BinaryDecodable {
        case ecdsa256WithP256 = 2
        case ecdsa384WithP384 = 3

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let u16 = try buffer.readUInt16()
            guard let s = Self(rawValue: u16) else {
                throw ParseError.invalidAttestationKeyType(value: u16)
            }

            self = s
        }
    }

    package enum TEEType: UInt32, StaticSized, BinaryDecodable {
        case sgx = 0
        case tdx = 0x81

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let u32 = try buffer.readUInt32()
            guard let s = Self(rawValue: u32) else {
                throw ParseError.invalidTEEType(value: u32)
            }

            self = s
        }
    }

    package struct TDAttributes: OptionSet, StaticSized, BinaryDecodable {
        package let rawValue: UInt64

        package init(rawValue: UInt64) {
            self.rawValue = rawValue
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let u64 = try buffer.readUInt64()
            self = Self(rawValue: u64)
        }

        package enum TUD {
            package static let debug = TDAttributes(rawValue: 1 << 0)  // bit 0

            static let reserved = (
                TDAttributes(rawValue: 1 << 1),  // bit 1
                TDAttributes(rawValue: 1 << 2),  // bit 2
                TDAttributes(rawValue: 1 << 3),  // bit 3
                TDAttributes(rawValue: 1 << 4),  // bit 4
                TDAttributes(rawValue: 1 << 5),  // bit 5
                TDAttributes(rawValue: 1 << 6),  // bit 6
                TDAttributes(rawValue: 1 << 7),  // bit 7
            )
        }

        package enum SEC {
            static let reserved = (
                TDAttributes(rawValue: 1 << 8),  // bit 8
                TDAttributes(rawValue: 1 << 9),  // bit 9
                TDAttributes(rawValue: 1 << 10),  // bit 10
                TDAttributes(rawValue: 1 << 11),  // bit 11
                TDAttributes(rawValue: 1 << 12),  // bit 12
                TDAttributes(rawValue: 1 << 13),  // bit 13
                TDAttributes(rawValue: 1 << 14),  // bit 14
                TDAttributes(rawValue: 1 << 15),  // bit 15
                TDAttributes(rawValue: 1 << 16),  // bit 16
                TDAttributes(rawValue: 1 << 17),  // bit 17
                TDAttributes(rawValue: 1 << 18),  // bit 18
                TDAttributes(rawValue: 1 << 19),  // bit 19
                TDAttributes(rawValue: 1 << 20),  // bit 20
                TDAttributes(rawValue: 1 << 21),  // bit 21
                TDAttributes(rawValue: 1 << 22),  // bit 22
                TDAttributes(rawValue: 1 << 23),  // bit 23
                TDAttributes(rawValue: 1 << 24),  // bit 24
                TDAttributes(rawValue: 1 << 25),  // bit 25
                TDAttributes(rawValue: 1 << 26),  // bit 26
                TDAttributes(rawValue: 1 << 27),  // bit 27
            )

            package static let septVeDisable = TDAttributes(rawValue: 1 << 28)
            package static let migratable = TDAttributes(rawValue: 1 << 29)
            package static let pks = TDAttributes(rawValue: 1 << 30)
            package static let kl = TDAttributes(rawValue: 1 << 31)
        }

        package enum OTHER {
            static let reserved = (
                TDAttributes(rawValue: 1 << 32),  // bit 32
                TDAttributes(rawValue: 1 << 33),  // bit 33
                TDAttributes(rawValue: 1 << 34),  // bit 34
                TDAttributes(rawValue: 1 << 35),  // bit 35
                TDAttributes(rawValue: 1 << 36),  // bit 36
                TDAttributes(rawValue: 1 << 37),  // bit 37
                TDAttributes(rawValue: 1 << 38),  // bit 38
                TDAttributes(rawValue: 1 << 39),  // bit 39
                TDAttributes(rawValue: 1 << 40),  // bit 40
                TDAttributes(rawValue: 1 << 41),  // bit 41
                TDAttributes(rawValue: 1 << 42),  // bit 42
                TDAttributes(rawValue: 1 << 43),  // bit 43
                TDAttributes(rawValue: 1 << 44),  // bit 44
                TDAttributes(rawValue: 1 << 45),  // bit 45
                TDAttributes(rawValue: 1 << 46),  // bit 46
                TDAttributes(rawValue: 1 << 47),  // bit 47
                TDAttributes(rawValue: 1 << 48),  // bit 48
                TDAttributes(rawValue: 1 << 49),  // bit 49
                TDAttributes(rawValue: 1 << 50),  // bit 50
                TDAttributes(rawValue: 1 << 51),  // bit 51
                TDAttributes(rawValue: 1 << 52),  // bit 52
                TDAttributes(rawValue: 1 << 53),  // bit 53
                TDAttributes(rawValue: 1 << 54),  // bit 54
                TDAttributes(rawValue: 1 << 55),  // bit 55
                TDAttributes(rawValue: 1 << 56),  // bit 56
                TDAttributes(rawValue: 1 << 57),  // bit 57
                TDAttributes(rawValue: 1 << 58),  // bit 58
                TDAttributes(rawValue: 1 << 59),  // bit 59
                TDAttributes(rawValue: 1 << 60),  // bit 60
                TDAttributes(rawValue: 1 << 61),  // bit 61
                TDAttributes(rawValue: 1 << 62),  // bit 62
            )

            package static let perfMon = TDAttributes(rawValue: 1 << 63)
        }
    }

}

extension V4 {
    package struct XFAM: OptionSet, StaticSized, BinaryDecodable {
        package let rawValue: UInt64

        package init(rawValue: UInt64) {
            self.rawValue = rawValue
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self = Self(rawValue: try buffer.readUInt64())
        }

        package static let x87 = XFAM(rawValue: 1 << 0)
        package static let sse = XFAM(rawValue: 1 << 1)
        package static let avx = XFAM(rawValue: 1 << 2)
        package enum MPX {
            package static let bndReg = XFAM(rawValue: 1 << 3)
            package static let bndCsr = XFAM(rawValue: 1 << 4)
        }
        package enum AVX512 {
            package static let opMask = XFAM(rawValue: 1 << 5)
            package static let zmmHi256 = XFAM(rawValue: 1 << 6)
            package static let Hi16ZMM = XFAM(rawValue: 1 << 7)
        }
        package static let pt = XFAM(rawValue: 1 << 8)
        package static let prku = XFAM(rawValue: 1 << 9)
        package static let pasid = XFAM(rawValue: 1 << 10)
        package enum CET {
            package static let cetU = XFAM(rawValue: 1 << 11)
            package static let cetS = XFAM(rawValue: 1 << 12)
        }
        package static let hdc = XFAM(rawValue: 1 << 13)
        package static let uintr = XFAM(rawValue: 1 << 14)
        package static let lbr = XFAM(rawValue: 1 << 15)
        package static let hwp = XFAM(rawValue: 1 << 16)
        package enum AMX {
            package static let xTileCfg = XFAM(rawValue: 1 << 17)
            package static let xTileData = XFAM(rawValue: 1 << 18)
        }
        package static let apx = XFAM(rawValue: 1 << 19)
        package static let reserved = (
            XFAM(rawValue: 1 << 20),  // bit 20
            XFAM(rawValue: 1 << 21),  // bit 21
            XFAM(rawValue: 1 << 22),  // bit 22
            XFAM(rawValue: 1 << 23),  // bit 23
            XFAM(rawValue: 1 << 24),  // bit 24
            XFAM(rawValue: 1 << 25),  // bit 25
            XFAM(rawValue: 1 << 26),  // bit 26
            XFAM(rawValue: 1 << 27),  // bit 27
            XFAM(rawValue: 1 << 28),  // bit 28
            XFAM(rawValue: 1 << 29),  // bit 29
            XFAM(rawValue: 1 << 30),  // bit 30
            XFAM(rawValue: 1 << 31),  // bit 31
            XFAM(rawValue: 1 << 32),  // bit 32
            XFAM(rawValue: 1 << 33),  // bit 33
            XFAM(rawValue: 1 << 34),  // bit 34
            XFAM(rawValue: 1 << 35),  // bit 35
            XFAM(rawValue: 1 << 36),  // bit 36
            XFAM(rawValue: 1 << 37),  // bit 37
            XFAM(rawValue: 1 << 38),  // bit 38
            XFAM(rawValue: 1 << 39),  // bit 39
            XFAM(rawValue: 1 << 40),  // bit 40
            XFAM(rawValue: 1 << 41),  // bit 41
            XFAM(rawValue: 1 << 42),  // bit 42
            XFAM(rawValue: 1 << 43),  // bit 43
            XFAM(rawValue: 1 << 44),  // bit 44
            XFAM(rawValue: 1 << 45),  // bit 45
            XFAM(rawValue: 1 << 46),  // bit 46
            XFAM(rawValue: 1 << 47),  // bit 47
            XFAM(rawValue: 1 << 48),  // bit 48
            XFAM(rawValue: 1 << 49),  // bit 49
            XFAM(rawValue: 1 << 50),  // bit 50
            XFAM(rawValue: 1 << 51),  // bit 51
            XFAM(rawValue: 1 << 52),  // bit 52
            XFAM(rawValue: 1 << 53),  // bit 53
            XFAM(rawValue: 1 << 54),  // bit 54
            XFAM(rawValue: 1 << 55),  // bit 55
            XFAM(rawValue: 1 << 56),  // bit 56
            XFAM(rawValue: 1 << 57),  // bit 57
            XFAM(rawValue: 1 << 58),  // bit 58
            XFAM(rawValue: 1 << 59),  // bit 59
            XFAM(rawValue: 1 << 60),  // bit 60
            XFAM(rawValue: 1 << 61),  // bit 61
            XFAM(rawValue: 1 << 62),  // bit 62
            XFAM(rawValue: 1 << 63)  // bit 63
        )
    }
}
