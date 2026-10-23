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
//  TitanDICEVerifier.swift
//  Titan
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//
//  Full validation of a Titan DICE endorsement: proves the endorsement key (EK)
//  that signs a TPM quote chains, by ECDSA-P256/SHA-256 signatures, back to a
//  pinned Google scribe root (``TitanScribeRoots``).
//
//  The chain, from leaf to root:
//
//    EK cert            —signed by→ alias-key public key
//    alias-key cert     —signed by→ DeviceID key
//    DeviceID cert      —signed by→ a pinned scribe root (named by the DeviceID
//                                   header's `scribeKeyID`)
//    DeviceID-scribe cert:
//        · binds the DeviceID cert by hash (`SHA256(deviceID.signedData)`)
//        · carries a scribe RW key that must itself be a pinned scribe root,
//          and whose signature over this cert we verify.
//
//  Mirrors the checks in Google's `titandice.ValidateScribeCertificateChain` /
//  `ValidateEKCertificate`.
//

import Crypto
import Foundation

// MARK: - TitanDICEVerifier

/// Verifies a Titan DICE endorsement chain against pinned scribe roots.
package struct TitanDICEVerifier: Sendable {
    /// The trusted scribe roots this verifier anchors chains to.
    package let roots: TitanScribeRoots
    /// The trusted RW firmware code-signing key infos an alias-key certificate's
    /// `certValidity` prefix must name.
    package let rwSigningKeys: TitanRWSigningKeys
    /// Whether the EK certifies a firmware-limited endorsement key (FEK). When
    /// true, the EK's firmware major version must equal the alias key's; when
    /// false, it must be zero. Mirrors the `expectFirmwareLimited` argument to
    /// Google's `ValidateEKCertificate`.
    package let expectFirmwareLimited: Bool

    package init(
        roots: TitanScribeRoots = .production,
        rwSigningKeys: TitanRWSigningKeys = .production,
        expectFirmwareLimited: Bool = true
    ) {
        self.roots = roots
        self.rwSigningKeys = rwSigningKeys
        self.expectFirmwareLimited = expectFirmwareLimited
    }

    /// Verifies the endorsement key certificate against the DICE certificate
    /// chain and the pinned scribe roots. Returns the verified EK public key on
    /// success; throws ``VerificationError`` on the first failing check.
    @discardableResult
    package func verify(
        ekCertificate: EKCertificate,
        with chain: TitanDICEScribeCertificateChain
    ) throws -> ECP256PublicKey {
        let trusted = self.roots.trustedKeys

        let aliasKey = chain.aliasKeyCertificate
        let deviceID = chain.deviceIDCertificate
        let deviceIDScribe = chain.deviceIDScribeCertificate

        // 0. Header policy: each certificate must declare the signature version,
        // purpose, key type/op/algorithm, and reserved/size fields expected for
        // its role, so a certificate minted for one layer cannot be substituted
        // for another. Mirrors the header checks in Google's
        // `validateDeviceIDCertificate` / `validateAliasKeyCertificate` /
        // `ValidateEKCertificate`.
        try Self.checkDeviceIDHeader(deviceID.header)
        try Self.checkKeycertHeader(aliasKey.header, purpose: .aliasKeyCert, keyType: .aliasKey, step: .aliasKeyCertificate)
        try Self.checkKeycertHeader(ekCertificate.header.signatureHeader, purpose: .archKeyCert, keyType: .tpmEK, step: .ekCertificate)

        // 0b. The alias-key certificate's `certValidity` prefix names the RW
        // firmware code-signing key that endorsed the firmware it was derived
        // under; that key info must be trusted. Mirrors the `certValidity[0:4]`
        // membership check in Google's `validateAliasKeyCertificate`.
        try self.checkRWSigningKey(aliasKey.header)

        // 1. DeviceID certificate is signed by the scribe root named in its
        // header (`scribeKeyID`); that root must be pinned and, per Google's
        // `validateDeviceIDCertificate`, must be a self-signed scribe cert.
        let deviceIDAuthorityID = TitanKeyID(deviceID.header.scribeKeyID)
        guard let deviceIDAuthority = trusted[deviceIDAuthorityID] else {
            throw VerificationError.untrustedScribeRoot(deviceIDAuthorityID)
        }
        guard deviceIDAuthority.kind == .selfSigned else {
            throw VerificationError.scribeCertificateWrongType(.deviceIDCertificate, deviceIDAuthority.kind)
        }
        try Self.verifySignature(deviceID.signature, over: deviceID.signedData, with: deviceIDAuthority.subjectKey, step: .deviceIDCertificate)

        // 2. The DeviceID-scribe certificate carries the scribe RW key. That key
        // must itself be a pinned root, and it must sign this certificate. Per
        // Google's `validateDeviceIDScribeCertificate`, that root must be a Titan
        // scribe cert.
        let scribeRWKey = deviceIDScribe.scribeRWKey
        let scribeAuthorityID = scribeRWKey.keyID
        guard let scribeAuthority = trusted[scribeAuthorityID] else {
            throw VerificationError.untrustedScribeRoot(scribeAuthorityID)
        }
        // Pin the actual key bytes, not just the 16-byte KeyID, so that a KeyID
        // collision in the (attacker-supplied) carried key cannot substitute a
        // different point for the pinned one.
        guard scribeAuthority.subjectKey.hasSameCoordinates(as: scribeRWKey) else {
            throw VerificationError.scribeKeyMismatch(scribeAuthorityID)
        }
        guard scribeAuthority.kind == .titan else {
            throw VerificationError.scribeCertificateWrongType(.deviceIDScribeCertificate, scribeAuthority.kind)
        }
        try Self.verifySignature(deviceIDScribe.signature, over: deviceIDScribe.signedData, with: scribeAuthority.subjectKey, step: .deviceIDScribeCertificate)

        // 3. The DeviceID-scribe certificate binds the DeviceID certificate by
        // hash, tying the two independently-signed halves together.
        guard Array(SHA256.hash(data: deviceID.signedData)) == Array(deviceIDScribe.deviceIDCertHash.bytes) else {
            throw VerificationError.deviceIDHashMismatch
        }

        // 4. Alias-key certificate is signed by the DeviceID key, and its
        // `keyInfo` names that same DeviceID key (Google's `ErrAKCKeyInfo`).
        try Self.require(aliasKey.header.keyInfo.bytes == deviceID.key.keyInfo.bytes, .aliasKeyCertificate, .keyInfo)
        try Self.verifySignature(aliasKey.signature, over: aliasKey.signedData, with: deviceID.key, step: .aliasKeyCertificate)

        // 5. EK certificate is signed by the alias key.
        try Self.verifySignature(ekCertificate.signature, over: ekCertificate.signedData, with: aliasKey.publicKey, step: .ekCertificate)

        // 6. Cross-layer consistency: every layer must describe the same chip
        // (HWID/HWCat) and firmware state (bootloader tag / firmware epoch).
        try Self.checkConsistency(ekCertificate: ekCertificate, aliasKey: aliasKey, deviceID: deviceID)

        // 7. EK firmware major version: a firmware-limited EK must match the
        // alias key's firmware major version; a non-firmware-limited EK must
        // report zero. Mirrors the `FWMajorVersion` checks in Google's
        // `ValidateEKCertificate`.
        try self.checkEKFirmwareMajorVersion(ekCertificate: ekCertificate, aliasKey: aliasKey)

        // 8. EK qualified name: the cert's qualified name must equal the TPM
        // qualified name of the EK public key under the expected primary-key
        // template and endorsement hierarchy. Mirrors Google's
        // `verifyEKQualifiedName`.
        try self.checkEKQualifiedName(ekCertificate: ekCertificate)

        return ekCertificate.publicKey
    }

    // MARK: Signature verification

    private static func verifySignature(
        _ signature: ECP256Signature,
        over message: [UInt8],
        with key: ECP256PublicKey,
        step: Step
    ) throws {
        let publicKey: P256.Signing.PublicKey
        let ecdsaSignature: P256.Signing.ECDSASignature
        do {
            publicKey = try key.p256PublicKey
            ecdsaSignature = try signature.p256Signature
        } catch {
            throw VerificationError.malformedKeyOrSignature(step)
        }
        // `isValidSignature(_:for:)` hashes `message` with SHA-256, matching
        // Titan's `VerifyECDSATitan`.
        guard publicKey.isValidSignature(ecdsaSignature, for: message) else {
            throw VerificationError.invalidSignature(step)
        }
    }

    // MARK: Cross-layer consistency

    private static func checkConsistency(
        ekCertificate: EKCertificate,
        aliasKey: AliasKeyCertificate,
        deviceID: DeviceIDCertificate
    ) throws {
        let ekHeader = ekCertificate.header.signatureHeader

        // EK ↔ alias key: same chip, firmware epoch, and bootloader.
        guard ekHeader.hwid == aliasKey.header.hwid,
            ekHeader.hwCat == aliasKey.header.hwCat,
            ekHeader.bootloaderTag == aliasKey.header.bootloaderTag,
            ekHeader.fwEpoch == aliasKey.header.fwEpoch
        else {
            throw VerificationError.inconsistentLayers(.ekVsAliasKey)
        }

        // alias key ↔ DeviceID: same chip and bootloader (the DeviceID header
        // carries no firmware epoch).
        guard aliasKey.header.hwid == deviceID.header.hwid,
            aliasKey.header.hwCat == deviceID.header.hwCat,
            aliasKey.header.bootloaderTag == deviceID.header.bootloaderTag
        else {
            throw VerificationError.inconsistentLayers(.aliasKeyVsDeviceID)
        }
    }

    // MARK: Header policy

    /// Titan header field values expected by DICE certificate verification,
    /// from Google's `titandice` constants (`constants.go`).
    private enum Constants {
        /// `SigHeaderversion1`: the only signature header version we accept.
        static let signatureVersion: UInt32 = 1
        /// `SigExtensionHeaderTypeNone`: no trailing extension header. We only
        /// model the fixed (no firmware-hash) layout, so every header must be
        /// this variant.
        static let extensionHeaderTypeNone: UInt8 = 0
        /// `KeyOpSign`: every certified key in the chain is a signing key.
        static let keyOpSign: UInt8 = 0
        /// `KeyAlgECDSAP256`: every key is a NIST P-256 ECDSA key.
        static let keyAlgECDSAP256: UInt8 = 0
        /// `headerPubKeySize`: the certified key is a 64-byte `(x, y)` point.
        static let pubKeySize: UInt16 = 64

        // The following EK-template constants were verified byte-for-byte against
        // Google's `titandice` known-answer certificates.
        /// `TPMA_OBJECT` for the endorsement-key template (`titanEKTemplate`).
        static let ekObjectAttributes: UInt32 = 0x0005_0472
        /// `TPMA_OBJECT` for the firmware-limited endorsement-key template
        /// (`titanFEKTemplate` — adds `stClear` and `firmwareLimited`).
        static let fekObjectAttributes: UInt32 = 0x0005_0576
        /// `TPM_RH_ENDORSEMENT`, the hierarchy for a non-firmware-limited EK.
        static let endorsementHierarchy: UInt32 = 0x4000_000B
        /// `TPM_RH_FW_ENDORSEMENT`, the hierarchy for a firmware-limited EK.
        static let firmwareEndorsementHierarchy: UInt32 = 0x4000_0141
    }

    /// A Titan `SignaturePurpose` value (`constants.go`).
    private enum SignaturePurpose: UInt32 {
        /// `SigArchKeyCert`, carried by the EK certificate.
        case archKeyCert = 1
        /// `SigDeviceIDCert`.
        case deviceIDCert = 9
        /// `SigAliasKeyCert`.
        case aliasKeyCert = 11
    }

    /// A Titan `KeyType` value (`constants.go`).
    private enum KeyType: UInt8 {
        case deviceID = 5
        case aliasKey = 6
        case tpmEK = 8
    }

    /// Validates the shared `KeycertSignatureHeader` (used by the EK and
    /// alias-key certificates) declares the version, purpose, key type, and
    /// fixed key/reserved fields expected for `step`'s role.
    private static func checkKeycertHeader(
        _ header: KeycertSignatureHeader,
        purpose: SignaturePurpose,
        keyType: KeyType,
        step: Step
    ) throws {
        try require(header.signatureVersion == Constants.signatureVersion, step, .signatureVersion)
        try require(header.signaturePurpose == purpose.rawValue, step, .signaturePurpose)
        try require(header.extensionHeaderType == Constants.extensionHeaderTypeNone, step, .extensionHeaderType)
        try require(header.keyType == keyType.rawValue, step, .keyType)
        try require(header.keyOp == Constants.keyOpSign, step, .keyOp)
        try require(header.keyAlg == Constants.keyAlgECDSAP256, step, .keyAlg)
        try require(header.pubKeySize == Constants.pubKeySize, step, .pubKeySize)
        try require(header.reserved0.bytes.allSatisfy { $0 == 0 }, step, .reserved)
        try require(header.reserved1.bytes.allSatisfy { $0 == 0 }, step, .reserved)
    }

    /// Validates the DeviceID certificate header (a distinct layout carrying a
    /// `scribeKeyID` and `signedDataSize` in place of the shared header's
    /// firmware/reserved fields).
    private static func checkDeviceIDHeader(_ header: DeviceIDCertificate.Header) throws {
        let step = Step.deviceIDCertificate
        try require(header.signatureVersion == Constants.signatureVersion, step, .signatureVersion)
        try require(header.signaturePurpose == SignaturePurpose.deviceIDCert.rawValue, step, .signaturePurpose)
        try require(header.extensionHeaderType == Constants.extensionHeaderTypeNone, step, .extensionHeaderType)
        try require(header.keyType == KeyType.deviceID.rawValue, step, .keyType)
        try require(header.keyOp == Constants.keyOpSign, step, .keyOp)
        try require(header.keyAlg == Constants.keyAlgECDSAP256, step, .keyAlg)
        // The signed prefix covers everything but the trailing 64-byte signature.
        try require(Int(header.signedDataSize) == DeviceIDCertificate.byteCount - ECP256Signature.byteCount, step, .signedDataSize)
        // The DeviceID header's `keyInfo` is the leading 4 bytes of its
        // `scribeKeyID` (matching Google's `validateDeviceIDCertificate`).
        try require(header.keyInfo.bytes == Array(header.scribeKeyID.bytes.prefix(4)), step, .keyInfo)
    }

    private static func require(_ condition: Bool, _ step: Step, _ field: HeaderField) throws {
        guard condition else {
            throw VerificationError.unexpectedHeaderField(step, field)
        }
    }

    /// Validates that the alias-key certificate's `certValidity` prefix names a
    /// trusted RW firmware code-signing key.
    private func checkRWSigningKey(_ header: KeycertSignatureHeader) throws {
        // `certValidity` is a fixed 16 bytes, so its 4-byte prefix always forms a
        // valid `TitanKeyInfo`.
        guard let keyInfo = TitanKeyInfo(Array(header.certValidity.bytes.prefix(TitanKeyInfo.byteCount))) else {
            throw VerificationError.unexpectedHeaderField(.aliasKeyCertificate, .certValidity)
        }
        guard self.rwSigningKeys.trustedKeyInfos.contains(keyInfo) else {
            throw VerificationError.untrustedRWSigningKey(keyInfo)
        }
    }

    /// Validates the EK's firmware major version against ``expectFirmwareLimited``.
    private func checkEKFirmwareMajorVersion(ekCertificate: EKCertificate, aliasKey: AliasKeyCertificate) throws {
        let ekFWMajor = ekCertificate.header.signatureHeader.fwMajorVersion
        let expected = self.expectFirmwareLimited ? aliasKey.header.fwMajorVersion : 0
        try Self.require(ekFWMajor == expected, .ekCertificate, .fwMajorVersion)
    }

    // TODO: This hand-marshals the TPM `TPMT_PUBLIC` public area and computes the
    // object/qualified name by hand because SwiftTPM is decode-only. Once SwiftTPM
    // gains TPM structure *encoding* (a `TPMEncodable`), replace this with a real
    // `TPMT_PUBLIC` built from the EK/FEK template and marshaled through SwiftTPM,
    // plus a shared TPM Name/qualified-name helper.
    /// Validates that the EK certificate's stored qualified name equals the TPM
    /// qualified name computed from the EK public key under the expected
    /// primary-key template and endorsement hierarchy.
    ///
    /// The TPM defines the qualified name of a primary key as
    /// `H_nameAlg( hierarchyHandle ‖ Name )`, where the object `Name` is
    /// `nameAlgID ‖ H_nameAlg(publicArea)`. Every field of the EK/FEK
    /// `TPMT_PUBLIC` is fixed by Google's template except the public key point,
    /// so the public area is assembled directly here. The template constants
    /// (object attributes and hierarchy handles) were verified byte-for-byte
    /// against Google's `titandice` known-answer certificates.
    private func checkEKQualifiedName(ekCertificate: EKCertificate) throws {
        let qualifiedName = Self.ekQualifiedName(publicKey: ekCertificate.publicKey, expectFirmwareLimited: self.expectFirmwareLimited)
        guard qualifiedName == ekCertificate.header.qualifiedName.bytes else {
            throw VerificationError.ekQualifiedNameMismatch
        }
    }

    /// The TPM qualified name of an EK public key under the endorsement (or
    /// firmware-endorsement) primary-key template. Exposed for known-answer
    /// testing against Google's `titandice` certificates.
    static func ekQualifiedName(publicKey: ECP256PublicKey, expectFirmwareLimited: Bool) -> [UInt8] {
        // The `TPMT_PUBLIC` public area for the EK/FEK primary-key template.
        var publicArea: [UInt8] = []
        publicArea += [0x00, 0x23]  // type = TPM_ALG_ECC
        publicArea += [0x00, 0x0B]  // nameAlg = TPM_ALG_SHA256
        publicArea += bigEndianBytes(expectFirmwareLimited ? Constants.fekObjectAttributes : Constants.ekObjectAttributes)
        publicArea += [0x00, 0x00]  // authPolicy: empty TPM2B_DIGEST
        // TPMS_ECC_PARMS
        publicArea += [0x00, 0x10]  // symmetric = TPM_ALG_NULL
        publicArea += [0x00, 0x18]  // scheme = TPM_ALG_ECDSA
        publicArea += [0x00, 0x0B]  //   hashAlg = TPM_ALG_SHA256
        publicArea += [0x00, 0x03]  // curveID = TPM_ECC_NIST_P256
        publicArea += [0x00, 0x10]  // kdf = TPM_ALG_NULL
        // unique = TPMS_ECC_POINT: x ‖ y, each a big-endian 32-byte
        // TPM2B_ECC_PARAMETER (the stored coordinates are little-endian).
        publicArea += [0x00, 0x20]
        publicArea += publicKey.x.bytes.reversed()
        publicArea += [0x00, 0x20]
        publicArea += publicKey.y.bytes.reversed()

        // Name = nameAlgID ‖ H_nameAlg(publicArea).
        var name: [UInt8] = [0x00, 0x0B]  // TPM_ALG_SHA256
        name += Array(SHA256.hash(data: Data(publicArea)))

        // qualifiedName = H_nameAlg(hierarchyHandle ‖ Name).
        let hierarchyHandle = expectFirmwareLimited ? Constants.firmwareEndorsementHierarchy : Constants.endorsementHierarchy
        return Array(SHA256.hash(data: Data(bigEndianBytes(hierarchyHandle) + name)))
    }

    /// The big-endian 4-byte encoding of a 32-bit value.
    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    // MARK: - Errors

    /// The chain link a failure occurred at.
    package enum Step: String, Sendable {
        case ekCertificate
        case aliasKeyCertificate
        case deviceIDCertificate
        case deviceIDScribeCertificate
    }

    /// A certificate header field whose declared value did not match the fixed
    /// value Titan requires for that certificate's role.
    package enum HeaderField: String, Sendable {
        case signatureVersion
        case signaturePurpose
        case extensionHeaderType
        case keyType
        case keyOp
        case keyAlg
        case pubKeySize
        case reserved
        case signedDataSize
        case keyInfo
        case certValidity
        case fwMajorVersion
    }

    /// The pair of layers whose fields disagreed.
    package enum LayerPair: String, Sendable {
        case ekVsAliasKey
        case aliasKeyVsDeviceID
    }

    package enum VerificationError: Error, Equatable {
        /// The KeyID was not a valid format.
        case invalidKeyID([UInt8])
        /// A scribe key referenced by the chain is not among the pinned roots.
        case untrustedScribeRoot(TitanKeyID)
        /// The scribe RW key carried in the chain does not equal the pinned key
        /// its KeyID resolved to.
        case scribeKeyMismatch(TitanKeyID)
        /// A certificate's ECDSA signature did not verify under its parent key.
        case invalidSignature(Step)
        /// A key or signature could not be decoded as a valid P-256 value.
        case malformedKeyOrSignature(Step)
        /// The DeviceID-scribe cert's bound hash did not match the DeviceID cert.
        case deviceIDHashMismatch
        /// Two chain layers described different chips/firmware.
        case inconsistentLayers(LayerPair)
        /// A certificate header declared a value other than the one Titan
        /// requires for that certificate's role.
        case unexpectedHeaderField(Step, HeaderField)
        /// The alias-key certificate's `certValidity` prefix named an RW firmware
        /// code-signing key that is not among the trusted key infos.
        case untrustedRWSigningKey(TitanKeyInfo)
        /// A pinned scribe root anchoring the given step was of the wrong
        /// certificate encoding (e.g. a Titan scribe cert where a self-signed
        /// one was required).
        case scribeCertificateWrongType(Step, ScribeRootCertificate.Kind)
        /// The EK certificate's stored qualified name did not match the qualified
        /// name computed from its public key under the expected TPM template and
        /// endorsement hierarchy.
        case ekQualifiedNameMismatch
    }
}

// MARK: - ECP256PublicKey coordinate comparison

extension ECP256PublicKey {
    /// Whether two keys have byte-identical stored coordinates.
    fileprivate func hasSameCoordinates(as other: ECP256PublicKey) -> Bool {
        self.x.bytes == other.x.bytes && self.y.bytes == other.y.bytes
    }
}
