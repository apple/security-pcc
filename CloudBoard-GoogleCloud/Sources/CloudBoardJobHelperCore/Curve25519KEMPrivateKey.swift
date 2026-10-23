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

import Crypto

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A wrapper around `Curve25519.KeyAgreement.PrivateKey` that conforms to `HPKEKEMPrivateKey`
/// by implementing DHKEM decapsulation (DH + ExtractAndExpand) per RFC 9180.
///
/// This is used by `TestOnlyAttestedKeyProvider` to provide a KEM-compatible key
/// from an in-memory Curve25519 key agreement key.
package struct Curve25519KEMPrivateKey: HPKEKEMPrivateKey, Sendable {
    package let publicKey: Curve25519KEMPublicKey
    private let key: Curve25519.KeyAgreement.PrivateKey

    package init(_ key: Curve25519.KeyAgreement.PrivateKey) {
        self.key = key
        self.publicKey = Curve25519KEMPublicKey(key.publicKey)
    }

    package static func generate() throws -> Curve25519KEMPrivateKey {
        Curve25519KEMPrivateKey(Curve25519.KeyAgreement.PrivateKey())
    }

    package func decapsulate(_ encapsulated: Data) throws -> SymmetricKey {
        // DHKEM decapsulation per RFC 9180 Section 4.1:
        // 1. Parse encapsulated as ephemeral public key
        let pkE = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: encapsulated)
        // 2. DH key agreement
        let dh = try self.key.sharedSecretFromKeyAgreement(with: pkE)
        // 3. ExtractAndExpand
        let pkRm = self.key.publicKey.rawRepresentation
        return DHKEMUtils.extractAndExpand(dh: dh, enc: encapsulated, pkRm: pkRm)
    }
}

package struct Curve25519KEMPublicKey: HPKEKEMPublicKey, Sendable {
    package typealias EphemeralPrivateKey = Curve25519KEMEphemeralPrivateKey

    private let key: Curve25519.KeyAgreement.PublicKey

    package init(_ key: Curve25519.KeyAgreement.PublicKey) {
        self.key = key
    }

    package init<D: ContiguousBytes>(_ serialization: D, kem: HPKE.KEM) throws {
        self.key = try Curve25519.KeyAgreement.PublicKey(serialization, kem: kem)
    }

    package func hpkeRepresentation(kem: HPKE.KEM) throws -> Data {
        try self.key.hpkeRepresentation(kem: kem)
    }

    package func encapsulate() throws -> KEM.EncapsulationResult {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let dh = try ephemeral.sharedSecretFromKeyAgreement(with: self.key)
        let enc = ephemeral.publicKey.rawRepresentation
        let pkRm = self.key.rawRepresentation
        let sharedSecret = DHKEMUtils.extractAndExpand(dh: dh, enc: enc, pkRm: pkRm)
        return KEM.EncapsulationResult(sharedSecret: sharedSecret, encapsulated: enc)
    }
}

package struct Curve25519KEMEphemeralPrivateKey: HPKEKEMPrivateKeyGeneration, Sendable {
    package let publicKey: Curve25519KEMPublicKey
    private let key: Curve25519.KeyAgreement.PrivateKey

    package init() {
        self.key = Curve25519.KeyAgreement.PrivateKey()
        self.publicKey = Curve25519KEMPublicKey(self.key.publicKey)
    }

    package static func generate() throws -> Curve25519KEMEphemeralPrivateKey {
        Curve25519KEMEphemeralPrivateKey()
    }

    package func decapsulate(_ encapsulated: Data) throws -> SymmetricKey {
        let pkE = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: encapsulated)
        let dh = try self.key.sharedSecretFromKeyAgreement(with: pkE)
        let pkRm = self.key.publicKey.rawRepresentation
        return DHKEMUtils.extractAndExpand(dh: dh, enc: encapsulated, pkRm: pkRm)
    }
}

/// DHKEM utilities implementing ExtractAndExpand per RFC 9180 Section 4.1
/// for DHKEM(Curve25519, HKDF-SHA256) (KEM ID 0x0020).
private enum DHKEMUtils {
    // suite_id = "KEM" || I2OSP(kem_id, 2) where kem_id = 0x0020
    private static let suiteID = Data("KEM".utf8) + Data([0x00, 0x20])
    private static let nSecret = 32

    static func extractAndExpand(
        dh: some ContiguousBytes,
        enc: Data,
        pkRm: Data,
        pkSm: Data? = nil
    ) -> SymmetricKey {
        // LabeledExtract("", "eae_prk", dh)
        // labeled_ikm = concat("HPKE-v1", suite_id, "eae_prk", dh)
        var ikmInput = Data("HPKE-v1".utf8)
        ikmInput.append(suiteID)
        ikmInput.append(Data("eae_prk".utf8))
        ikmInput.append(contentsOf: dh.withUnsafeBytes { Data($0) })

        let prk = HKDF<SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: ikmInput),
            salt: Data()
        )

        // LabeledExpand(prk, "shared_secret", kem_context, Nsecret)
        // kem_context = concat(enc, pkRm[, pkSm])
        // labeled_info = concat(I2OSP(L, 2), "HPKE-v1", suite_id, "shared_secret", kem_context)
        var expandInfo = Data([UInt8(nSecret >> 8), UInt8(nSecret & 0xFF)])
        expandInfo.append(Data("HPKE-v1".utf8))
        expandInfo.append(suiteID)
        expandInfo.append(Data("shared_secret".utf8))
        expandInfo.append(enc)
        expandInfo.append(pkRm)
        if let pkSm {
            expandInfo.append(pkSm)
        }

        return HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: expandInfo,
            outputByteCount: nSecret
        )
    }
}
