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

import Common
import Foundation
import SwiftASN1

/// Intel TDX platform identity, DER-encoded per the ASN.1 schema in `CloudAttestation.asn`.
///
/// ```
/// IntelTDXPlatform ::= SEQUENCE {
///     seamDigest    [0] OCTET STRING,   -- SHA384, MRSEAM
///     seamSigner    [1] OCTET STRING,   -- SHA384, MRSIGNER
///     seamVersion   [2] INTEGER,        -- SEAMSVN
///     qeDigest      [3] OCTET STRING,   -- SHA256, MRENCLAVE
///     qeSigner      [4] OCTET STRING,   -- SHA256, MRSIGNER
///     qeProductId   [5] INTEGER,        -- ISVPRODID
///     qeVersion     [6] INTEGER,        -- ISVSVN
///     teeTcbSvn     [7] OCTET STRING,   -- 16 bytes, TEE TCB SVN
///     fmspc         [8] OCTET STRING,   -- 6 bytes, FMSPC
///     sgxTcbCompSvn [9] OCTET STRING,   -- 16 bytes, SGX TCB Component SVNs
///     pcesvn        [10] INTEGER        -- PCE SVN
/// }
/// ```
public struct IntelTDXPlatform: Sendable, Hashable, Encodable {
    /// SHA-384 digest of the TDX module (MRSEAM).
    public let seamDigest: Data

    /// SHA-384 digest of the TDX module signer (MRSIGNER).
    public let seamSigner: Data

    /// TDX module security version (SEAMSVN).
    public let seamVersion: Int

    /// SHA-256 digest of the Quoting Enclave (MRENCLAVE).
    public let qeDigest: Data

    /// SHA-256 digest of the Quoting Enclave signer (MRSIGNER).
    public let qeSigner: Data

    /// Quoting Enclave product ID (ISVPRODID).
    public let qeProductId: Int

    /// Quoting Enclave security version (ISVSVN).
    public let qeVersion: Int

    /// TEE TCB SVN from the TDX quote body (16 bytes).
    public let teeTcbSvn: Data

    /// Family-Model-Stepping-Platform-CustomSKU from the PCK certificate (6 bytes).
    public let fmspc: Data

    /// SGX TCB Component SVNs from the PCK certificate (16 bytes).
    public let sgxTcbCompSvn: Data

    /// Provisioning Certification Enclave SVN.
    public let pcesvn: Int

    public init(
        seamDigest: Data,
        seamSigner: Data,
        seamVersion: Int,
        qeDigest: Data,
        qeSigner: Data,
        qeProductId: Int,
        qeVersion: Int,
        teeTcbSvn: Data,
        fmspc: Data,
        sgxTcbCompSvn: Data,
        pcesvn: Int
    ) {
        self.seamDigest = seamDigest
        self.seamSigner = seamSigner
        self.seamVersion = seamVersion
        self.qeDigest = qeDigest
        self.qeSigner = qeSigner
        self.qeProductId = qeProductId
        self.qeVersion = qeVersion
        self.teeTcbSvn = teeTcbSvn
        self.fmspc = fmspc
        self.sgxTcbCompSvn = sgxTcbCompSvn
        self.pcesvn = pcesvn
    }
}

// MARK: - DER Encoding

extension IntelTDXPlatform: DERSerializable {
    public func serialize(into coder: inout DER.Serializer) throws {
        try coder.appendConstructedNode(identifier: .sequence) { coder in
            try coder.serialize(
                ASN1OctetString(contentBytes: [UInt8](seamDigest)[...]),
                explicitlyTaggedWithTagNumber: 0,
                tagClass: .contextSpecific
            )
            try coder.serialize(
                ASN1OctetString(contentBytes: [UInt8](seamSigner)[...]),
                explicitlyTaggedWithTagNumber: 1,
                tagClass: .contextSpecific
            )
            try coder.serialize(seamVersion, explicitlyTaggedWithTagNumber: 2, tagClass: .contextSpecific)
            try coder.serialize(
                ASN1OctetString(contentBytes: [UInt8](qeDigest)[...]),
                explicitlyTaggedWithTagNumber: 3,
                tagClass: .contextSpecific
            )
            try coder.serialize(
                ASN1OctetString(contentBytes: [UInt8](qeSigner)[...]),
                explicitlyTaggedWithTagNumber: 4,
                tagClass: .contextSpecific
            )
            try coder.serialize(qeProductId, explicitlyTaggedWithTagNumber: 5, tagClass: .contextSpecific)
            try coder.serialize(qeVersion, explicitlyTaggedWithTagNumber: 6, tagClass: .contextSpecific)
            try coder.serialize(
                ASN1OctetString(contentBytes: [UInt8](teeTcbSvn)[...]),
                explicitlyTaggedWithTagNumber: 7,
                tagClass: .contextSpecific
            )
            try coder.serialize(
                ASN1OctetString(contentBytes: [UInt8](fmspc)[...]),
                explicitlyTaggedWithTagNumber: 8,
                tagClass: .contextSpecific
            )
            try coder.serialize(
                ASN1OctetString(contentBytes: [UInt8](sgxTcbCompSvn)[...]),
                explicitlyTaggedWithTagNumber: 9,
                tagClass: .contextSpecific
            )
            try coder.serialize(pcesvn, explicitlyTaggedWithTagNumber: 10, tagClass: .contextSpecific)
        }
    }
}

// MARK: - DER Decoding

extension IntelTDXPlatform: DERParseable {
    public init(derEncoded node: ASN1Node) throws {
        self = try DER.sequence(node, identifier: .sequence) { nodes in
            let seamDigest: ASN1OctetString = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 0,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let seamSigner: ASN1OctetString = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 1,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let seamVersion: Int = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 2,
                tagClass: .contextSpecific
            ) { try Int(derEncoded: $0) }

            let qeDigest: ASN1OctetString = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 3,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let qeSigner: ASN1OctetString = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 4,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let qeProductId: Int = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 5,
                tagClass: .contextSpecific
            ) { try Int(derEncoded: $0) }

            let qeVersion: Int = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 6,
                tagClass: .contextSpecific
            ) { try Int(derEncoded: $0) }

            let teeTcbSvn: ASN1OctetString = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 7,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let fmspc: ASN1OctetString = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 8,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let sgxTcbCompSvn: ASN1OctetString = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 9,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let pcesvn: Int = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 10,
                tagClass: .contextSpecific
            ) { try Int(derEncoded: $0) }

            return IntelTDXPlatform(
                seamDigest: Data(seamDigest.bytes),
                seamSigner: Data(seamSigner.bytes),
                seamVersion: seamVersion,
                qeDigest: Data(qeDigest.bytes),
                qeSigner: Data(qeSigner.bytes),
                qeProductId: qeProductId,
                qeVersion: qeVersion,
                teeTcbSvn: Data(teeTcbSvn.bytes),
                fmspc: Data(fmspc.bytes),
                sgxTcbCompSvn: Data(sgxTcbCompSvn.bytes),
                pcesvn: pcesvn
            )
        }
    }
}
