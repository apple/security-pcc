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
//  QuoteV4+Encoding.swift
//  CloudAttestationV2
//

import BinaryCoding
import Foundation

extension V4.Quote: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.header)
        buffer.append(self.body)
        buffer.append(self.signatureDataLen)
        buffer.append(self.signatureData)
    }

    /// Build a V4.Quote from its component parts. Used by tooling and simulators that
    /// need to construct a quote without round-tripping through bytes.
    package init(header: V4.Header, body: V4.Body, signatureData: V4.ECDSA256QuoteSignatureData) {
        self.header = header
        self.body = body
        self.signatureData = signatureData
    }
}

// MARK: - Header

extension V4.Header: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.version)
        buffer.append(self.attestationKeyType)
        buffer.append(self.teeType)
        buffer.append(self._reserved0)
        buffer.append(self._reserved1)
        buffer.append(self.qeVendorID)
        buffer.append(self.userData)
    }

    package init(
        attestationKeyType: V4.AttestationKeyType,
        teeType: V4.TEEType,
        qeVendorID: UUID,
        userData: InlineArray<20, UInt8>
    ) {
        self.attestationKeyType = attestationKeyType
        self.teeType = teeType
        self.qeVendorID = qeVendorID
        self.userData = userData
        self.raw = ArraySlice<UInt8>()
    }
}

// MARK: - Body

extension V4.Body: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.teeTcbSvn)
        buffer.append(self.mrSeam)
        buffer.append(self.mrSignerSeam)
        buffer.append(self.seamAttributes)
        buffer.append(self.tdAttributes)
        buffer.append(self.xfam)
        buffer.append(self.mrtd)
        buffer.append(self.mrConfigId)
        buffer.append(self.mrOwner)
        buffer.append(self.mrOwnerConfig)
        buffer.append(self.rtmr0)
        buffer.append(self.rtmr1)
        buffer.append(self.rtmr2)
        buffer.append(self.rtmr3)
        buffer.append(self.reportData)
    }

    package init(
        teeTcbSvn: InlineArray<16, UInt8>,
        mrSeam: InlineArray<48, UInt8>,
        mrSignerSeam: InlineArray<48, UInt8> = .init(repeating: 0),
        tdAttributes: V4.TDAttributes,
        xfam: V4.XFAM,
        mrtd: InlineArray<48, UInt8>,
        mrConfigId: InlineArray<48, UInt8> = .init(repeating: 0),
        mrOwner: InlineArray<48, UInt8> = .init(repeating: 0),
        mrOwnerConfig: InlineArray<48, UInt8> = .init(repeating: 0),
        rtmr0: InlineArray<48, UInt8>,
        rtmr1: InlineArray<48, UInt8>,
        rtmr2: InlineArray<48, UInt8>,
        rtmr3: InlineArray<48, UInt8>,
        reportData: InlineArray<64, UInt8>
    ) {
        self.teeTcbSvn = teeTcbSvn
        self.mrSeam = mrSeam
        self.mrSignerSeam = mrSignerSeam
        self.tdAttributes = tdAttributes
        self.xfam = xfam
        self.mrtd = mrtd
        self.mrConfigId = mrConfigId
        self.mrOwner = mrOwner
        self.mrOwnerConfig = mrOwnerConfig
        self.rtmr0 = rtmr0
        self.rtmr1 = rtmr1
        self.rtmr2 = rtmr2
        self.rtmr3 = rtmr3
        self.reportData = reportData
        self.raw = ArraySlice<UInt8>()
    }
}

// MARK: - Enum scalars

extension V4.AttestationKeyType: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.rawValue)
    }
}

extension V4.TEEType: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.rawValue)
    }
}

extension V4.TDAttributes: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.rawValue)
    }
}

extension V4.XFAM: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.rawValue)
    }
}

// MARK: - Signature data

extension V4.ECDSA256QuoteSignatureData: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.signature)
        buffer.append(self.ecdsaAttestationKey)
        buffer.append(self.qeCertificationData)
    }

    package init(
        signature: InlineArray<64, UInt8>,
        ecdsaAttestationKey: InlineArray<64, UInt8>,
        qeCertificationData: V4.QECertificationData
    ) {
        self.signature = signature
        self.ecdsaAttestationKey = ecdsaAttestationKey
        self.qeCertificationData = qeCertificationData
    }
}

extension V4.QECertificationData: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.certificationDataType)
        buffer.append(self.size)
        buffer.append(self.data)
    }

    package init(_ data: V4.CertificationData) {
        self.certificationDataType = data.type
        self.data = data
    }
}

extension V4.QECertificationDataType: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.rawValue)
    }
}

extension V4.CertificationData: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        switch self {
        case .plaintexPpid(let bytes),
            .encryptedPpidWithRSA2048(let bytes),
            .encryptedPpidWithRSA3072(let bytes),
            .plaintextPckLeafCertificate(let bytes),
            .concatenatedPCKCertChain(let bytes),
            .platformManifest(let bytes):
            buffer.append(contentsOf: bytes)
        case .qeReportCertificationData(let qeReport):
            buffer.append(qeReport)
        }
    }
}

extension V4.QEReportCertificationData: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.qeReport)
        buffer.append(self.qeReportSignature)
        buffer.append(self.qeAuthenticationData)
        buffer.append(self.qeCertificationData)
    }
}

extension V4.EnclaveReport: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.cpuSvn)
        buffer.append(self.miscSelect)
        buffer.append(self._reserved0)
        buffer.append(self.attributes)
        buffer.append(self.mrEnclave)
        buffer.append(self._reserved1)
        buffer.append(self.mrSigner)
        buffer.append(self._reserved2)
        buffer.append(self.isvProdId)
        buffer.append(self.isvSvn)
        buffer.append(self._reserved3)
        buffer.append(self.reportData)
    }
}

extension V4.MISCSelect: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.rawValue)
    }
}

extension V4.EnclaveAttributes: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.flags.rawValue)
        buffer.append(self.xfrm.rawValue)
    }
}

extension V4.QEAuthenticationData: BinaryEncodable {
    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.size)
        buffer.append(contentsOf: self.bytes)
    }

    package init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}
