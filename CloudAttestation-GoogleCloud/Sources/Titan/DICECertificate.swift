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
//  DICECertificate.swift
//  Titan
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//
//  Swift port of Google's Titan DICE certificate structures, from
//  `github.com/google/platform-attestation`, package `titan/dice/titandice`
//  (`structures.go` / `constants.go`). The blobs are fixed-layout,
//  little-endian, packed C structs — `BinaryCoding` already defaults integers to
//  little-endian, so no byte-order annotations are needed. These types
//  round-trip: `decode → encode` reproduces the input bytes exactly.
//
//  Note: the alias-key certificate can, in general, carry an optional trailing
//  firmware hash (when its `extensionHeaderType` is the firmware-hash variant).
//  We only handle the fixed layout our fixtures use (no firmware-hash
//  extension), which keeps every structure statically sized.
//

import BinaryCoding

// MARK: - KeycertSignatureHeader

/// The common signature header prefixing Titan key certificates
/// (`KeycertSignatureHeader`). Fixed 64 bytes.
package struct KeycertSignatureHeader: BinaryCodable, StaticSized {
    package var signatureVersion: UInt32
    package var signaturePurpose: UInt32
    package var extensionHeaderType: UInt8
    package var keyType: UInt8
    package var keyOp: UInt8
    package var keyAlg: UInt8
    /// `SHA256(x ‖ y)[0:4]` of the certified key.
    package var keyInfo: InlineArray<4, UInt8>
    package var certValidity: InlineArray<16, UInt8>
    package var hwid: UInt64
    package var hwCat: UInt16
    package var reserved0: InlineArray<2, UInt8>
    package var bootloaderTag: UInt32
    package var fwEpoch: UInt32
    package var fwMajorVersion: UInt16
    package var pubKeySize: UInt16
    package var reserved1: InlineArray<8, UInt8>

    @StructureSize
    package static var byteCount: Int {
        \Self.signatureVersion
        \Self.signaturePurpose
        \Self.extensionHeaderType
        \Self.keyType
        \Self.keyOp
        \Self.keyAlg
        \Self.keyInfo
        \Self.certValidity
        \Self.hwid
        \Self.hwCat
        \Self.reserved0
        \Self.bootloaderTag
        \Self.fwEpoch
        \Self.fwMajorVersion
        \Self.pubKeySize
        \Self.reserved1
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.signatureVersion = try UInt32(from: &buffer)
        self.signaturePurpose = try UInt32(from: &buffer)
        self.extensionHeaderType = try UInt8(from: &buffer)
        self.keyType = try UInt8(from: &buffer)
        self.keyOp = try UInt8(from: &buffer)
        self.keyAlg = try UInt8(from: &buffer)
        self.keyInfo = try buffer.readInlineArray()
        self.certValidity = try buffer.readInlineArray()
        self.hwid = try UInt64(from: &buffer)
        self.hwCat = try UInt16(from: &buffer)
        self.reserved0 = try buffer.readInlineArray()
        self.bootloaderTag = try UInt32(from: &buffer)
        self.fwEpoch = try UInt32(from: &buffer)
        self.fwMajorVersion = try UInt16(from: &buffer)
        self.pubKeySize = try UInt16(from: &buffer)
        self.reserved1 = try buffer.readInlineArray()
    }

    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.signatureVersion)
        buffer.append(self.signaturePurpose)
        buffer.append(self.extensionHeaderType)
        buffer.append(self.keyType)
        buffer.append(self.keyOp)
        buffer.append(self.keyAlg)
        buffer.append(self.keyInfo)
        buffer.append(self.certValidity)
        buffer.append(self.hwid)
        buffer.append(self.hwCat)
        buffer.append(self.reserved0)
        buffer.append(self.bootloaderTag)
        buffer.append(self.fwEpoch)
        buffer.append(self.fwMajorVersion)
        buffer.append(self.pubKeySize)
        buffer.append(self.reserved1)
    }
}

// MARK: - EKCertificate

/// The Titan `ek_cert`: certifies the EK public key that signs TPM quotes.
/// Fixed 256 bytes (128-byte header + 64-byte key + 64-byte signature).
package struct EKCertificate: BinaryCodable, StaticSized {
    /// Header of an `EKCertificate`: the common signature header plus the RW and
    /// qualified-name hashes. Fixed 128 bytes.
    package struct Header: BinaryCodable, StaticSized {
        package var signatureHeader: KeycertSignatureHeader
        package var rwHash: InlineArray<32, UInt8>
        package var qualifiedName: InlineArray<32, UInt8>

        @StructureSize
        package static var byteCount: Int {
            \Self.signatureHeader
            \Self.rwHash
            \Self.qualifiedName
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.signatureHeader = try KeycertSignatureHeader(from: &buffer)
            self.rwHash = try buffer.readInlineArray()
            self.qualifiedName = try buffer.readInlineArray()
        }

        package func encode(to buffer: inout [UInt8]) {
            buffer.append(self.signatureHeader)
            buffer.append(self.rwHash)
            buffer.append(self.qualifiedName)
        }
    }

    package var header: Header
    package var publicKey: ECP256PublicKey
    package var signature: ECP256Signature

    @StructureSize
    package static var byteCount: Int {
        \Self.header
        \Self.publicKey
        \Self.signature
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.header = try Header(from: &buffer)
        self.publicKey = try ECP256PublicKey(from: &buffer)
        self.signature = try ECP256Signature(from: &buffer)
    }

    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.header)
        buffer.append(self.publicKey)
        buffer.append(self.signature)
    }
}

// MARK: - AliasKeyCertificate

/// The Titan alias-key certificate (`AliasKeyCertificate`). Fixed 192 bytes
/// (64-byte header + 64-byte key + 64-byte signature).
///
/// The upstream structure can carry an optional trailing 32-byte firmware hash
/// when `header.extensionHeaderType` is the firmware-hash variant; we only model
/// the fixed layout our fixtures use, so this type is statically sized.
package struct AliasKeyCertificate: BinaryCodable, StaticSized {
    package var header: KeycertSignatureHeader
    package var publicKey: ECP256PublicKey
    package var signature: ECP256Signature

    @StructureSize
    package static var byteCount: Int {
        \Self.header
        \Self.publicKey
        \Self.signature
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.header = try KeycertSignatureHeader(from: &buffer)
        self.publicKey = try ECP256PublicKey(from: &buffer)
        self.signature = try ECP256Signature(from: &buffer)
    }

    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.header)
        buffer.append(self.publicKey)
        buffer.append(self.signature)
    }
}

// MARK: - DeviceIDCertificate

/// The Titan `DeviceIDCertificate`. Fixed 192 bytes (64-byte header + 64-byte
/// key + 64-byte signature).
package struct DeviceIDCertificate: BinaryCodable, StaticSized {
    /// Header of a `DeviceIDCertificate`. Fixed 64 bytes.
    package struct Header: BinaryCodable, StaticSized {
        package var signatureVersion: UInt32
        package var signaturePurpose: UInt32
        package var extensionHeaderType: UInt8
        package var keyType: UInt8
        package var keyOp: UInt8
        package var keyAlg: UInt8
        package var keyInfo: InlineArray<4, UInt8>
        package var certValidity: InlineArray<16, UInt8>
        /// `SHA256(x ‖ y)[0:16]` of the scribe key.
        package var scribeKeyID: InlineArray<16, UInt8>
        package var hwid: UInt64
        package var hwCat: UInt16
        package var signedDataSize: UInt16
        package var bootloaderTag: UInt32

        @StructureSize
        package static var byteCount: Int {
            \Self.signatureVersion
            \Self.signaturePurpose
            \Self.extensionHeaderType
            \Self.keyType
            \Self.keyOp
            \Self.keyAlg
            \Self.keyInfo
            \Self.certValidity
            \Self.scribeKeyID
            \Self.hwid
            \Self.hwCat
            \Self.signedDataSize
            \Self.bootloaderTag
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.signatureVersion = try UInt32(from: &buffer)
            self.signaturePurpose = try UInt32(from: &buffer)
            self.extensionHeaderType = try UInt8(from: &buffer)
            self.keyType = try UInt8(from: &buffer)
            self.keyOp = try UInt8(from: &buffer)
            self.keyAlg = try UInt8(from: &buffer)
            self.keyInfo = try buffer.readInlineArray()
            self.certValidity = try buffer.readInlineArray()
            self.scribeKeyID = try buffer.readInlineArray()
            self.hwid = try UInt64(from: &buffer)
            self.hwCat = try UInt16(from: &buffer)
            self.signedDataSize = try UInt16(from: &buffer)
            self.bootloaderTag = try UInt32(from: &buffer)
        }

        package func encode(to buffer: inout [UInt8]) {
            buffer.append(self.signatureVersion)
            buffer.append(self.signaturePurpose)
            buffer.append(self.extensionHeaderType)
            buffer.append(self.keyType)
            buffer.append(self.keyOp)
            buffer.append(self.keyAlg)
            buffer.append(self.keyInfo)
            buffer.append(self.certValidity)
            buffer.append(self.scribeKeyID)
            buffer.append(self.hwid)
            buffer.append(self.hwCat)
            buffer.append(self.signedDataSize)
            buffer.append(self.bootloaderTag)
        }
    }

    package var header: Header
    package var key: ECP256PublicKey
    package var signature: ECP256Signature

    @StructureSize
    package static var byteCount: Int {
        \Self.header
        \Self.key
        \Self.signature
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.header = try Header(from: &buffer)
        self.key = try ECP256PublicKey(from: &buffer)
        self.signature = try ECP256Signature(from: &buffer)
    }

    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.header)
        buffer.append(self.key)
        buffer.append(self.signature)
    }
}

// MARK: - DeviceIDScribeCertificate

/// The Titan `DeviceIDScribeCertificate`: binds a DeviceID cert hash to the
/// scribe RW key. Fixed 160 bytes (32-byte hash + 64-byte key + 64-byte signature).
package struct DeviceIDScribeCertificate: BinaryCodable, StaticSized {
    package var deviceIDCertHash: InlineArray<32, UInt8>
    package var scribeRWKey: ECP256PublicKey
    package var signature: ECP256Signature

    @StructureSize
    package static var byteCount: Int {
        \Self.deviceIDCertHash
        \Self.scribeRWKey
        \Self.signature
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.deviceIDCertHash = try buffer.readInlineArray()
        self.scribeRWKey = try ECP256PublicKey(from: &buffer)
        self.signature = try ECP256Signature(from: &buffer)
    }

    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.deviceIDCertHash)
        buffer.append(self.scribeRWKey)
        buffer.append(self.signature)
    }
}

// MARK: - TitanDICEScribeCertificateChain

/// The Titan `dice_cert_chain`: the alias-key, DeviceID, and DeviceID-scribe
/// certificates, concatenated in that order. Fixed 544 bytes (192 + 192 + 160).
package struct TitanDICEScribeCertificateChain: BinaryCodable, StaticSized {
    package var aliasKeyCertificate: AliasKeyCertificate
    package var deviceIDCertificate: DeviceIDCertificate
    package var deviceIDScribeCertificate: DeviceIDScribeCertificate

    @StructureSize
    package static var byteCount: Int {
        \Self.aliasKeyCertificate
        \Self.deviceIDCertificate
        \Self.deviceIDScribeCertificate
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.aliasKeyCertificate = try AliasKeyCertificate(from: &buffer)
        self.deviceIDCertificate = try DeviceIDCertificate(from: &buffer)
        self.deviceIDScribeCertificate = try DeviceIDScribeCertificate(from: &buffer)
    }

    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.aliasKeyCertificate)
        buffer.append(self.deviceIDCertificate)
        buffer.append(self.deviceIDScribeCertificate)
    }
}

package protocol DICESignable {
    var signedData: [UInt8] { get }
}

// MARK: - Signed messages

//  The bytes each certificate's ECDSA signature covers — the little-endian
//  serialization of everything up to (but excluding) the signature, matching
//  Titan's `serialize*Certificate` helpers. Verifying a signature means checking
//  it against `SHA256(signedData)` with the appropriate parent key.

extension EKCertificate: DICESignable {
    /// The signed message: `header ‖ publicKey`.
    package var signedData: [UInt8] {
        var buffer: [UInt8] = []
        self.header.encode(to: &buffer)
        self.publicKey.encode(to: &buffer)
        return buffer
    }
}

extension AliasKeyCertificate: DICESignable {
    /// The signed message: `header ‖ publicKey`. (This models only the fixed
    /// layout without the optional trailing firmware hash — see the type doc.)
    package var signedData: [UInt8] {
        var buffer: [UInt8] = []
        self.header.encode(to: &buffer)
        self.publicKey.encode(to: &buffer)
        return buffer
    }
}

extension DeviceIDCertificate: DICESignable {
    /// The signed message: `header ‖ key`. Its `SHA256` is also the value bound
    /// by a ``DeviceIDScribeCertificate``'s `deviceIDCertHash`.
    package var signedData: [UInt8] {
        var buffer: [UInt8] = []
        self.header.encode(to: &buffer)
        self.key.encode(to: &buffer)
        return buffer
    }
}

extension DeviceIDScribeCertificate: DICESignable {
    /// The signed message: `deviceIDCertHash ‖ scribeRWKey`.
    package var signedData: [UInt8] {
        var buffer: [UInt8] = []
        buffer.append(contentsOf: self.deviceIDCertHash.bytes)
        self.scribeRWKey.encode(to: &buffer)
        return buffer
    }
}
