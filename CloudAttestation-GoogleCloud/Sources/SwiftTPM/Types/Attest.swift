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
//  TPMS+Attest.swift
//  SwiftTPM
//
//  Created on 12/11/25.
//

import BinaryCoding

package typealias TPMS_ATTEST = TPMS.Attest

extension TPMS {
    package struct Attest: TPMDecodable, Hashable {
        package var magic: TPM.Constants32 = TPM.GeneratedValue
        package var type: TPMI.ST.Attest { attested.type }
        package var qualifiedSigner: TPM2B.Name
        package var extraData: TPM2B.Data
        package var clockInfo: TPMS.ClockInfo
        package var firmwareVersion: UInt64
        package var attested: TPMU.Attest

        @StructureSize
        package var byteCount: Int {
            self.magic
            self.type
            self.extraData
            self.clockInfo
            self.firmwareVersion
            self.attested
        }

        init(
            magic: TPM.Constants32 = TPM.GeneratedValue,
            qualifiedSigner: TPM2B.Name,
            extraData: TPM2B.Data,
            clockInfo: TPMS.ClockInfo,
            firmwareVersion: UInt64,
            attested: TPMU.Attest
        ) {
            self.magic = magic
            self.qualifiedSigner = qualifiedSigner
            self.extraData = extraData
            self.clockInfo = clockInfo
            self.firmwareVersion = firmwareVersion
            self.attested = attested
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.magic = try buffer.read(TPM.Constants32.self, byteOrder: .bigEndian)
            let type = try buffer.read(TPMI.ST.Attest.self)
            self.qualifiedSigner = try buffer.read(TPM2B.Name.self)
            self.extraData = try buffer.read(TPM2B.Data.self)
            self.clockInfo = try buffer.read(TPMS.ClockInfo.self)
            self.firmwareVersion = try buffer.read(UInt64.self, byteOrder: .bigEndian)

            switch type {
            case .quote:
                self.attested = .quote(try TPMS.QuoteInfo(from: &buffer))
            case .nv:
                self.attested = .nv(try TPMS.NVCertifyInfo(from: &buffer))
            case .nvDigest:
                self.attested = .nvDigest(try TPMS.NVDigestCertifyInfo(from: &buffer))
            default:
                throw TPMError.unsupported
            }
        }
    }
}

extension TPMU {
    package enum Attest: Sized, Hashable {
        case certify(TPMS.CertifyInfo)
        case creation(TPMS.CreationInfo)
        case quote(TPMS.QuoteInfo)
        case commandAudit(TPMS.CommandAuditInfo)
        case sessionAudit(TPMS.SessionAuditInfo)
        case time(TPMS.TimeAttestInfo)
        case nv(TPMS.NVCertifyInfo)
        case nvDigest(TPMS.NVDigestCertifyInfo)

        var type: TPMI.ST.Attest {
            switch self {
            case .certify(_):
                .certify
            case .creation(_):
                .creation
            case .quote(_):
                .quote
            case .commandAudit(_):
                .commandAudit
            case .sessionAudit(_):
                .sessionAudit
            case .time(_):
                .time
            case .nv(_):
                .nv
            case .nvDigest(_):
                .nvDigest
            }
        }

        package var byteCount: Int {
            switch self {
            case .certify(let certifyInfo):
                certifyInfo.byteCount
            case .creation(let creation):
                creation.byteCount
            case .quote(let quote):
                quote.byteCount
            case .commandAudit(let commandAudit):
                commandAudit.byteCount
            case .sessionAudit(let sessionAudit):
                sessionAudit.byteCount
            case .time(let time):
                time.byteCount
            case .nv(let nv):
                nv.byteCount
            case .nvDigest(let nvDigest):
                nvDigest.byteCount
            }
        }
    }
}

typealias TPMI_ST_ATTEST = TPMI.ST.Attest

extension TPMI.ST {
    package enum Attest: TPMDecodable, Hashable {
        case nv
        case commandAudit
        case sessionAudit
        case certify
        case quote
        case time
        case creation
        case nvDigest
    }
}

// MARK: - Package projection

extension TPMS.Attest {
    /// `pcrDigest` from the `TPMS_QUOTE_INFO` — the digest the TPM signed over
    /// the selected PCRs. `nil` when this attestation is not a quote.
    package var quotePCRDigest: [UInt8]? {
        guard case .quote(let quoteInfo) = attested else { return nil }
        return quoteInfo.pcrDigest.buffer
    }

    /// The PCR selections the TPM signed in the `TPMS_QUOTE_INFO`: for each bank
    /// (by TPM algorithm id), the selected PCR indices in canonical ascending
    /// order. `nil` when this attestation is not a quote.
    ///
    /// This is the authoritative, signature-bound statement of *which* PCRs the
    /// quote covers — consumers must use it to bind PCR-index labels rather than
    /// trusting an out-of-band PCR map. The indices are computed directly from
    /// the wire bitmask (octet `i`, bit `j` → PCR `i*8 + j`).
    package var quotePCRSelections: [(bankAlgID: UInt16, pcrs: [UInt32])]? {
        guard case .quote(let quoteInfo) = attested else { return nil }
        return quoteInfo.pcrSelect.pcrSelections.map { selection in
            var pcrs: [UInt32] = []
            for (octet, byte) in selection.pcrSelect.enumerated() {
                for bit in 0..<8 where (byte & (UInt8(1) << bit)) != 0 {
                    pcrs.append(UInt32(octet * 8 + bit))
                }
            }
            return (bankAlgID: selection.hash.rawValue.rawValue, pcrs: pcrs)
        }
    }

    /// The Name of the NV index this attestation certifies, from the signed
    /// `TPMS_NV_CERTIFY_INFO` / `TPMS_NV_DIGEST_CERTIFY_INFO`. `nil` when this
    /// attestation is not an NV certification.
    ///
    /// This digest is the only identification of the index inside the signed
    /// body — consumers must recompute it from the accompanying
    /// `TPMS_NV_PUBLIC` (``TPMS/NVPublic/name(marshaled:)``) rather than trusting
    /// that unauthenticated public area's `nvIndex` directly.
    package var nvIndexName: [UInt8]? {
        switch attested {
        case .nv(let info):
            info.indexName.name
        case .nvDigest(let info):
            info.indexName.name
        default:
            nil
        }
    }

    /// The certified contents of the NV index, from the signed
    /// `TPMS_NV_CERTIFY_INFO`. `nil` unless this is a `TPM_ST_ATTEST_NV`
    /// attestation — notably, the `_NV_DIGEST_` variant carries only a digest of
    /// the contents, never the contents themselves.
    package var nvContents: [UInt8]? {
        guard case .nv(let info) = attested else { return nil }
        return info.nvContents.buffer
    }
}

extension TPMI.ST.Attest: StaticSized, RawRepresentable {
    package init?(rawValue: TPM.ST) {
        switch rawValue {
        case .attestNV:
            self = .nv
        case .attestCommandAudit:
            self = .commandAudit
        case .attestSessionAudit:
            self = .sessionAudit
        case .attestCertify:
            self = .certify
        case .attestQuote:
            self = .quote
        case .attestTime:
            self = .time
        case .attestCreation:
            self = .creation
        case .attestNVDigest:
            self = .nvDigest
        default:
            return nil
        }
    }

    package var rawValue: TPM.ST {
        switch self {
        case .nv:
            .attestNV
        case .commandAudit:
            .attestCommandAudit
        case .sessionAudit:
            .attestSessionAudit
        case .certify:
            .attestCertify
        case .quote:
            .attestQuote
        case .time:
            .attestTime
        case .creation:
            .attestCreation
        case .nvDigest:
            .attestNVDigest
        }
    }
}
