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
//  ScribeRootCertificate.swift
//  Titan
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//
//  Parser for the Titan scribe root certificate format published in
//  `github.com/google/platform-attestation`, directory
//  `titan/dice/scriberoots/certdata`. These are the self-signed public-key root
//  certificates that anchor DICE certificate chains (see ``TitanScribeRoots``).
//
//  Two variants share a fixed 300-byte layout that — by construction — places
//  the 64-byte subject public key at the same offset (byte 172) in both:
//
//    TitanScribeCertificate (magic 0x8230):
//      magic u16 · size u16 · devID0 u32 · devID1 u32 · roRWR[32] · roX[32]
//      · roY[32] · rwHash[32] · rwFwr[32] · rwX[32] · rwY[32] · sigR[32] · sigS[32]
//      → subject key = (rwX, rwY)
//
//    SelfSignedScribeCertificate (magic 0xf0ef):
//      magic u16 · size u16 · reserved[168] · keyX[32] · keyY[32] · sigR[32] · sigS[32]
//      → subject key = (keyX, keyY)
//
//  We only need the subject key (the key that verifies DeviceID/DeviceID-scribe
//  signatures); the roots are trusted by pinning, not by verifying their own
//  self-signatures, so the authority key and signature are skipped.
//

import BinaryCoding
import Crypto
import Foundation

// MARK: - ScribeRootCertificate

/// A parsed Titan scribe root certificate. Fixed 300 bytes.
package struct ScribeRootCertificate: BinaryDecodable, StaticSized {
    /// Which of the two scribe certificate encodings this is.
    package enum Kind: UInt16, Sendable {
        case titan = 0x8230
        case selfSigned = 0xf0ef
    }

    package var kind: Kind
    /// The public key that verifies signatures made by this scribe (the RW key
    /// for a Titan cert, or the external key for a self-signed cert).
    package var subjectKey: ECP256PublicKey

    /// The 2-byte magic identifying the variant.
    private static let magicByteCount = 2
    /// Bytes preceding the subject key after the 2-byte magic, identical for
    /// both variants (Titan: size+devID0+devID1+roRWR+roX+roY+rwHash+rwFwr;
    /// self-signed: size+reserved).
    private static let bytesBeforeSubjectKey = 170
    /// The trailing 64-byte `(r, s)` scribe self-signature, which we skip.
    private static let signatureByteCount = 64

    /// Fixed 300 bytes: 2 (magic) + 170 (pre-key) + 64 (subject key) + 64 (sig).
    package static let byteCount = magicByteCount + bytesBeforeSubjectKey + ECP256PublicKey.byteCount + signatureByteCount

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        let magic = try buffer.readUInt16()
        guard let kind = Kind(rawValue: magic) else {
            throw ParseError.unsupportedMagic(magic)
        }
        self.kind = kind
        _ = try buffer.readBytes(count: Self.bytesBeforeSubjectKey)
        self.subjectKey = try buffer.read(ECP256PublicKey.self)
        _ = try buffer.readBytes(count: Self.signatureByteCount)
    }

    package enum ParseError: Error {
        case unsupportedMagic(UInt16)
    }
}
