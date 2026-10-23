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
//  ECP256.swift
//  Titan
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding
import Crypto
import Foundation

// MARK: - ECP256PublicKey

/// A NIST P-256 public key as stored in a Titan DICE certificate: the affine
/// coordinates `(x, y)`, each a 32-byte **little-endian** integer (Titan stores
/// key material little-endian, matching the rest of the DICE structures).
package struct ECP256PublicKey: BinaryCodable, StaticSized {
    /// The affine x coordinate (`QAX`), little-endian.
    package var x: InlineArray<32, UInt8>
    /// The affine y coordinate (`QAY`), little-endian.
    package var y: InlineArray<32, UInt8>

    @StructureSize
    package static var byteCount: Int {
        \Self.x
        \Self.y
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.x = try buffer.readInlineArray()
        self.y = try buffer.readInlineArray()
    }

    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.x)
        buffer.append(self.y)
    }
}

extension ECP256PublicKey {
    /// The key as a swift-crypto `P256.Signing.PublicKey`.
    ///
    /// The stored coordinates are little-endian; the X9.63 representation
    /// swift-crypto expects is big-endian, so each coordinate is byte-reversed.
    /// Throws if `(x, y)` is not a valid point on the P-256 curve.
    package var p256PublicKey: P256.Signing.PublicKey {
        get throws {
            var x963: [UInt8] = [0x04]
            x963.append(contentsOf: self.x.bytes.reversed())
            x963.append(contentsOf: self.y.bytes.reversed())
            return try P256.Signing.PublicKey(x963Representation: x963)
        }
    }

    /// The Titan key identifier for this key: the first 16 bytes of
    /// `SHA256(x ‖ y)` over the little-endian coordinates as stored (Titan's
    /// `ComputeKeyIDECDSA`). This is the value carried in a DeviceID
    /// certificate's `scribeKeyID` field and the last path component of a
    /// published scribe-root filename, so it is the natural key for looking a
    /// scribe root up in ``TitanScribeRoots``.
    package var keyID: TitanKeyID {
        var hasher = SHA256()
        hasher.update(data: Data(self.x.bytes))
        hasher.update(data: Data(self.y.bytes))
        // A SHA-256 digest is always 32 bytes, so its first `TitanKeyID.byteCount`
        // (16) bytes safely fill the fixed-size array — no failable init needed.
        let digest = Array(hasher.finalize())
        return TitanKeyID(.init { digest[$0] })
    }

    /// The Titan `KeyInfo` for this key: the first 4 bytes of `SHA256(x ‖ y)`
    /// over the little-endian coordinates as stored (Titan's
    /// `ComputeKeyInfoTitan`) — the same digest as ``keyID``, truncated to 4
    /// bytes. A certificate header carries the `KeyInfo` of a related key (e.g.
    /// an alias-key certificate carries its signing DeviceID key's `KeyInfo`).
    package var keyInfo: TitanKeyInfo {
        var hasher = SHA256()
        hasher.update(data: Data(self.x.bytes))
        hasher.update(data: Data(self.y.bytes))
        let digest = Array(hasher.finalize())
        // A SHA-256 digest is always 32 bytes, so the 4-byte prefix is present.
        return TitanKeyInfo(Array(digest.prefix(TitanKeyInfo.byteCount)))!
    }
}

// MARK: - TitanKeyID

/// A Titan key identifier: the first 16 bytes of `SHA256(x ‖ y)` of a P-256
/// public key's little-endian coordinates. Used to name scribe keys in DeviceID
/// certificates and to index the pinned scribe roots.
package struct TitanKeyID: StaticSized, Hashable, Sendable, CustomStringConvertible {
    @StructureSize
    package static var byteCount: Int {
        \Self.bytes
    }

    package let bytes: [16 of UInt8]

    package init(_ bytes: [16 of UInt8]) {
        self.bytes = bytes
    }

    package init?(_ bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else {
            return nil
        }
        self.bytes = .init { idx in
            bytes[idx]
        }
    }

    /// Parses a 32-character hex string (as used in scribe-root filenames).
    package init?(hexEncoded hex: String) {
        guard hex.count == Self.byteCount * 2 else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    package var description: String {
        self.bytes.bytes.map { String(format: "%02x", $0) }.joined()
    }

    package static func == (lhs: borrowing TitanKeyID, rhs: borrowing TitanKeyID) -> Bool {
        lhs.bytes == rhs.bytes
    }

    package func hash(into hasher: inout Hasher) {
        for i in self.bytes.indices {
            hasher.combine(self.bytes[i])
        }
    }
}

// MARK: - TitanKeyInfo

/// A Titan `KeyInfo`: a 4-byte key identifier (`ComputeKeyInfoTitan`, the leading
/// 4 bytes of `SHA256(x ‖ y)` over a key's little-endian coordinates). Certificate
/// headers carry the `KeyInfo` of a related key — notably an alias-key
/// certificate's `certValidity` prefix names the RW firmware code-signing key
/// that must be trusted (see ``TitanRWSigningKeys``).
package struct TitanKeyInfo: Hashable, Sendable, CustomStringConvertible {
    package static let byteCount = 4

    package let bytes: [UInt8]

    /// Fails unless `bytes` is exactly ``byteCount`` (4) bytes.
    package init?(_ bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else {
            return nil
        }
        self.bytes = bytes
    }

    /// The four bytes as a tuple, for pinning literal constants.
    package init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) {
        self.bytes = [b0, b1, b2, b3]
    }

    package var description: String {
        self.bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ECP256Signature

/// A NIST P-256 ECDSA signature as stored in a Titan DICE certificate: the `(r, s)`
/// scalars, each a 32-byte **little-endian** integer.
package struct ECP256Signature: BinaryCodable, StaticSized {
    /// The `r` scalar, little-endian.
    package var r: InlineArray<32, UInt8>
    /// The `s` scalar, little-endian.
    package var s: InlineArray<32, UInt8>

    @StructureSize
    package static var byteCount: Int {
        \Self.r
        \Self.s
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.r = try buffer.readInlineArray()
        self.s = try buffer.readInlineArray()
    }

    package func encode(to buffer: inout [UInt8]) {
        buffer.append(self.r)
        buffer.append(self.s)
    }
}

extension ECP256Signature {
    /// The signature as a swift-crypto `P256.Signing.ECDSASignature`.
    ///
    /// `rawRepresentation` is big-endian `r ‖ s`; the stored scalars are
    /// little-endian, so each is byte-reversed.
    package var p256Signature: P256.Signing.ECDSASignature {
        get throws {
            var raw: [UInt8] = []
            raw.append(contentsOf: self.r.bytes.reversed())
            raw.append(contentsOf: self.s.bytes.reversed())
            return try P256.Signing.ECDSASignature(rawRepresentation: raw)
        }
    }
}
