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
//  TitanScribeRoots.swift
//  Titan
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//
//  The pinned Google Titan scribe root certificates — the trust anchors for
//  DICE certificate-chain validation. These are the self-signed public-key root
//  certificates for the keys that sign Titan DeviceID certificates, vendored
//  verbatim from `github.com/google/platform-attestation`, directory
//  `titan/dice/scriberoots/certdata` (see that repo's README).
//
//  Each entry is one 300-byte scribe root certificate in Titan's custom binary
//  format (``ScribeRootCertificate``), keyed by the hex of its subject key's
//  16-byte KeyID (`SHA256(x ‖ y)[0:16]`, little-endian coordinates). That KeyID
//  is exactly the last path component of the upstream filename, so each entry
//  can be cross-checked against the published `certdata` directory. The map is
//  parsed at load and every entry's recomputed KeyID is asserted to match its
//  key, so a corrupted blob fails fast rather than silently trusting the wrong
//  key.
//

import Crypto
import Foundation

// MARK: - TrustedScribeRoot

/// A pinned Titan scribe root: its subject public key plus which certificate
/// encoding it was published as. The ``kind`` lets verification enforce that a
/// DeviceID certificate is anchored by a self-signed scribe cert and a
/// DeviceID-scribe certificate by a Titan scribe cert (matching Google's
/// `validateDeviceIDCertificate` / `validateDeviceIDScribeCertificate`).
package struct TrustedScribeRoot: Sendable {
    /// The key that verifies signatures made by this scribe.
    package let subjectKey: ECP256PublicKey
    /// Which of the two scribe certificate encodings published this root.
    package let kind: ScribeRootCertificate.Kind

    package init(subjectKey: ECP256PublicKey, kind: ScribeRootCertificate.Kind) {
        self.subjectKey = subjectKey
        self.kind = kind
    }
}

// MARK: - TitanScribeRoots

/// The set of trusted Titan scribe root public keys used to anchor DICE
/// certificate chains. Mirrors the shape of `AppleTrustAnchors`.
package enum TitanScribeRoots: Sendable {
    /// All Google-published production scribe roots.
    case production
    /// An explicit set of scribe roots, keyed by KeyID — for tests and custom
    /// trust configurations.
    case custom([TitanKeyID: TrustedScribeRoot])

    /// The trusted scribe roots keyed by their 16-byte ``TitanKeyID``.
    package var trustedKeys: [TitanKeyID: TrustedScribeRoot] {
        switch self {
        case .production:
            Self.productionRoots
        case .custom(let keys):
            keys
        }
    }
}

extension TitanScribeRoots {
    /// The pinned production scribe roots, parsed once from the embedded
    /// certificate blobs. Fails fast (traps) if any embedded blob is malformed
    /// or its recomputed KeyID disagrees with its declared key — that can only
    /// happen if this file is corrupted, which must never ship.
    package static let productionRoots: [TitanKeyID: TrustedScribeRoot] = {
        var result: [TitanKeyID: TrustedScribeRoot] = [:]
        for (keyIDHex, certBase64) in embeddedRoots {
            let declaredKeyID = TitanKeyID(hexEncoded: keyIDHex)
            let certBytes = [UInt8](Data(base64Encoded: certBase64)!)
            let cert = try! ScribeRootCertificate(consumingAll: certBytes)
            precondition(
                cert.subjectKey.keyID == declaredKeyID,
                "Embedded Titan scribe root \(keyIDHex) does not match its subject key's KeyID"
            )
            result[declaredKeyID!] = TrustedScribeRoot(subjectKey: cert.subjectKey, kind: cert.kind)
        }
        return result
    }()

    /// The embedded scribe root certificates, keyed by subject-key KeyID hex.
    /// See the file header for provenance.
    private static let embeddedRoots: [String: String] = [
        "72b2d7d67a2a0e482ed33fea7b0390e8":
            "MIIBKAZQAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqo0ADrbMtueNYseKDLFYOg0jgWQaqY7QyHvvC+jcwFps3mcFBZ7L0aUacejgJZTUfOBP55cKlC6N6zXcYX9Ez+EMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAEdkshjZI1T5OGWR1SgyoacVQ8aHx4k2Bg9cGl5naMFMGVE1g+B762JCgKzZqdf5/ylxOACvX78BG52CnxNE1gyWKVPXDD3pNl1TcbG6OC8r1q53wSwnVja3NkMG4dSQXVGCnY2UWHke4/y6Ek2kwjRCuEWT/kPwGZWA73gh21rm",
        "766a9bdc9d8a829e477a6f6beb7fa6b4":
            "MIIBKBFgAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqp6Ze5kPW7iZuOKkRvWQa/cZSSJBpU94Iay8xJ7ZjcAztkljjnOzJ+BfntOP29RkeBUOKbbj/D5PEQdqx7+uL32MR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAAS+S1tjRhm2hWXBmo6y7Nom3GBOHTlDBXEgFLvgVB757SZbPJyFuq2rKyv3CCuE/HhuErnwKfE8vAOwyLjH4K8MT2kWWN3IpVLxAyalOSahZ/SOSwzW1IFdmSIrxYx/IDDiDyjbgLhRViFiYY4Yl+NZ9+E+RwBCMKeBlCuprIDE",
        "16cd71c6cdecb4914d88c2ca553e2ba7":
            "MIIBKB1gAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqoFFxRQmN8E67esS1fNy6vhlv0E20ZDafTqQW4IHriYgSgcXIFOnIQe1VXlV9NiAd8ExwZDjrfvDxgee4vvjKRGMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAANEHM7KaglcOJXoni53hyjEb9haLSUhkn5EXsRfd3F+ZwRavGpVDdkx4ijCz6VfDMQ4Pm1TEytHp/ySFpoTLptlCKTypVFABWoyLlKhgD5a4GqntQicYi0+KQ0kJRs6FoZLdR66nF1zxEqBSRgk59lzd1OF78EdsaN7u3Tys5hxz",
        "ff790c1c84c1aff69845d5e38a579b7c":
            "MIIBKCpgAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqpeKIKMqIhXs7JyMqUJ6TiENVxXnEEM7IqdDLati1UlGw7znfbSluLkIh2Dl7E1sZXWd64yF3stQCw0ehIlCwdZMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAAjdEluwSTuipEXIqE1z8dauxkWRHEumcF+fzV8eX9NZl8/eB1rGLiw3Hd+8/tz3XljiKbV+4DhUHxdG6eHhpbvouM1A7ySRVwETmjSQbVbexx4kPWBCvDCqX5KRUfW+KiSiPs8gdtPnZkeWRRRBvc1PTRhkmJtyCQcAqHZcR7tI",
        "ddc13af857daf2da442a849d3fb0d8df":
            "MIIBKDZgAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqq6TPUOwPHBVNZ2llLLJhYae9tqZkqP4rjRM5jnLzCVzQeCCL8fSTKKAkYEzmKc0MPh1oopHZfKmb3Gf+my+2J6MR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAANHvTkoRd0RGHk51B970qi2aZ3kY8rMFVuU88zf9IJok74n5Qbf5jPdinqs36BXK9EM69C6C3patSnhszGlVZl/rjkdNcJzqk3QaVesbJTXKXVl1Vf/fEyirQRoj3USmZYrYvyRcBjXQLJy3cgIQEXqhVvBbdhBEbUKjo7RRpgqx",
        "38abc8aaca2dac9d4b9395fff20c7c95":
            "MIIBKEVgAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqoPzZYfPFMyhGGrRnGV3oz6YEH7Wubbr12scP8h/ddSl6BiKJKk9ZAQ8xk+XnlYLNHlGqb5ukP5vHi73Yc4bVSrMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAMtR2JuKzBzZ2K/7N4pzJLEzZgxKhNNF+3Zx8yqCqhEOStGSjHlvVfxhDZ0hhNBOgR8Unc2ocI5U/l0RP2WLqPlwHEmSOJTHAFJlWdWOrcTJkVGf1WqimSeD5FHm5Bk3mBi/CZYFnx/1Jyi3mObwNCTv/LcPSt8sk1kXdZ0VqxBP",
        "d2a3ebb01b99b8ca1ab30e57766c7782":
            "MIIBKFFgAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqrpufewa5mBuL6qgxHP11J1rwgwZ9bvxO5If7XmB7kjGc2rSf3+KnEhnhGGFtzXEmuD2fFkM+mBhsSioDG5w4OnMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAACXswCTBPERCCxHz9x7ZXBENtoJ7zLmGImQFGWY0phARd3Ds7x/MgvLMOHJIZ8x+kksVdzl4YsYdwTfTEgfoMsxbzloaIZwkgBrE0/uYEMwZiKmYWddRHYDlZznNFBgboJl5ow2lNS+70qHxzRI/w2SLdgCZ5wIwiX5moMOIhtle",
        "a6d5d16e75db9d6bcb9027348b7bf7c8":
            "MIIBKBFwAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqVXUzDtN9hbhUi18jPYpeKwa1Gv2S3eDhjErtNV0TWcPQZzdNAts9entr+ooETAXZg4LIDMu5lXGP4U+DuIF/8MR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAABSBCBjjOOk13+yBEUPnnt4Zbv4TwTNG9nyyYSKWz3CG27PLnRiKqWzmiopuw0/g2r8ZDDmU03fy0oMopvoX1tMcged8GZpteCUq63rmhdDRVtsdvpaYojK2wnz5vEQCvgQtSKUqU33/R0Rz7vYxnU/ZDA58+hYskBE7O6kFPZIt",
        "d5193090a0b62df7291a133c8cd2c7ad":
            "MIIBKCBwAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqoRUh3AVTyBG6S/Eu+8Zy5PiWyby/1tKUymDORHuQ8ZFgKC+411P742MymZwO2HWkQLJnxuWASG2jVhnQsm8ZCtMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAAS/t+zx5MM1kx5M2RtGie+VIfEpf+P0KG6b79CRzGYGicEaZSDZ7KrG/mVzbmpIg6KhA8AMXGTmi3Xi6YS9rQeIB92weqzA01znGY8NyKcSIlWqvVTeYYdd+7AUnfVofCZ1xX0Sx+K1YGT/W2gpss8BWN73kRGTo+0Vre3dWNnL",
        "7c006152e2c0cd0382baa52ffa52cf0e":
            "MIIBKCxwAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqpRCtWLlcQxFDmhIIuiNNkO0omvk+lSSKa1hkCXI8yRl4FMdQjk5z4i6tDNtgcUq0iYZppMXuzA7KmqXxUTIAGXMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAIwA9qwVTzGAxK4NLknR1Kby1fnyPFBeItaOcbKH/nJXEQzrljB1amK85c18Fgd/ETH93yluvOYsa8CVz/8YCAcFX/AepNN4ZIKHoGwOmYBh2z1RGmhm6ePgf1DYVGEJyDJeyvP4zSBdlqfWdDm1yUeX4myFxVDpr1ea+4K18P43",
        "54c9fd4e01488bd2578e8ff20d84e6c4":
            "MIIBKDpwAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqKRuHGsQHCOuR+IMNbuq6DSbLhGll2MxJWTVMaGJ/mmq07cxqvCHU0QtgoKcay8M0rQrwODwFrxUxZdvIccLyiMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAMSYOIaRkxLGk0u6vvTXRN8YiayLHKst77gzXNlXiRlCTvZ0j2E92UrjiOol92pij8MndxtRRszI/BEPq7cKueYmsVNFrQXGaA+5mXsOXTHiBKr8I0+zcSHMZtA1orW6fZZ9jr3q382qaMEYRVQA7xYe62bkYyM0+EzRGQeBfwhQ",
        "4f52da19c52f0ce7e39d97d8a1a569df":
            "MIIBKERwAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqe1E1CEULQ999rQVPYAzrHVBtVINa+Pl7bH+8b6fAHM1t+ZWTmpHQM/p7HKTuPdpMXeWvzb1zZZmG6NZpWzu91MR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAO0tvxpuGZi9JRW+LA71qY/QzQrGiZtqVwf+WtCLB138/Uj47rjSajuqlotTS+/ZDAQZO1vl8o8kL/GFBk+At2xl8o6waLJwjZxe1OiFKq+RKiBCWPj3GtTPIarndGLGESAvkypz1HqrkrjdQYBzXqn4com/1hd/zBkoB+zkQ2do",
        "87cb16b4cc009834945c7423cef47bf8":
            "MIIBKFFwAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqoBnlFA5o2H9JbXSDfeGsOVN5t9oMe+pdgx55Q4EHb/GnQS3qkU/e7zG/6Lu9u3aZA1IQj5+mx9LXuWN3Hdp+cCMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAFoyUewZUYd0A/Xo1wnsmYeFiRixByVHIOjZBtpD7FspHUJNNyoZQRHYe07yZv0EarW0DdNUNxPnzCLsFANeiKE4Mv+2DL4ooKulxrgtL1D9tnN0tUut/k01HKsU5b+yIahD35UJUkYgqorzmlVEe3QozMywHxfjivJ0oAcdgwHW",
        "bf8a9aab288286a917e85c6c8768c799":
            "MIIBKAeAAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqS+z3a2O/+5rMXPeBnwhg4/iK5bckdJy1ocYx1AhxsmznZlDfG1epTG8j2l5LKlDc6ZAtGzek5aCw5mMBC6OhPMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAJqFvVTb/hCou2LU8inzwDuKqMFULDBxOIQexNw+pKAQyxIXSc/zbSOkr2/fv4Z7ftL2pliaF+R2D0siY2zX0bbOLKWbTob81wbSt292GbR4YKjMJ4WvMHNzfKed2H8PWso2Zt1CkdUnCEFGFGI3MebJFfjokGcXZh7Ffyt9uZxJ",
        "92abd33bfce281bec33a377b1d50b6e3":
            "MIIBKBOAAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqUIHxmgbFlwlz6f3LNRVlaoO7UJsDL922asmzuz2Zuk6ThQ1hUXECWNRkDO6W869XQzJzxJZb3HbwA1nCo5p0WMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAL0I3MdRw1X1g1L8zq3lZDJ5W1dSjJ8hpBSqSKky4bvSfYwlrjwWT7I5XDDE754tKANa+43+s5E3Fh0phdg0J70KbOESH++ozLflQKdzc+CyJz1DfJ+ZT7jCc4+vlgWNjEd7giWgY2IjZZ+Cg42hQFJDcd1HNZ26spUPs0YSXdUk",
        "350cddbead16fd6efa8953ae8b9eddbf":
            "MIIBKBWAAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqrzoaOxd/QU8v+UD+HSqU2vCFdwpMe2f0d7LuWyKq/52eXnwkXq3EGQALOytvvNfm2Ui5wL1km5gN1/Qy6f+QTAMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAGaVjxHnEpK9/JC60W23ssIwwFc0bR8tJG6/BiUYDgcgZgXW0sOb7G4DNbxekI+8kW3RR6VuMg/AVMe3XmBFKBA/JNc8MIBwN1KKo1Fzh6bmRKOaJDMraM9a4hWyI3c1R8kBPIkDswSyJX1pqjr76uY0XIZ+SnXk8iL/7JGLEC3F",
        "6e26006e509d6ee42db941500a728444":
            "MIIBKCGAAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqomaGCg8UXqTMv7bM0duUoSp5Uzx9MsTPB4SVo77L3wTWAcDgYjAaUJeg8U7HZqCLFpG2P8z6UrEZBBpjHaQVP+MR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAANHtfMr5Jozrck4vlLOz+BEsdka48tb7tVLHwBJTkefb2vLV39TVAlfq4LoOaGgixHqNkx7XTt9U4QoOwf8hZhHwIZG6lJIR3onpXMnnjasquBl87bo4zLm3F3nLj9ft9PuzHGxDKNl0VOqk/43S4HJHZtYeMM14d+gD1sxPlvrV",
        "babb0ee61be502452ae198c14037a7dd":
            "MIIBKC6AAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqia67RiFSAcIaXxJIWLcXqHFEQDkgg3qulSGX1SRexr9qhkxAbxsn9mGKp1/wOPwGI/KWrjPzx7cv9wI1QKduTMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAIV4bkDBVn6N/XuZs28IOmlBeGfbx0n7ZJ5GxrOTbGA60l4WWvzuvdNgC7H/0nTIjmUEIyKsXn8jFtzrI4uDja7qtXuL7uhT+5GziZmIO/3kxqd+5FaqLD+0UhgBV4B/WERL1Gdkez20BDj2egGZz0rhlyV40NlZFRZt03yuKAh7",
        "ac849d3e27aadec02826a6e218ecbab3":
            "MIIBKEeAAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqlGhBmDMCpCvaPCg95fXcyilLZARxRSyMW7N5rCsy7z60cHb+hgBud67YCJjB80H0JkEMpDHZ5Q3RYcoYmxyKnMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAABNDltmu8drK+tFBHKUxqwFxAPHJPh2DXgO2ntS2o32TAGsfZIZo1aZrc6G+9rJbzowIcv+Mdaunv0/nGXPXsgnK6Y6xi+41ab6AzS4ayJLWHd6kn5m9vD5pVNxxzcSrNp03Mzhw+Af26CY+KZFSaASksMTd0WnYeicoQb2nKDFQ",
        "42d0b9ae0da5008ac26817b20b38c83c":
            "MIIBKFKAAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqo6TWhhZAU45eNSZ/4OuTo94+a3TahU3HVXTQAV5nP3eSIJ58cl3cPmz7TEuWxifyQFCh18fAyWmCs/fUjpHKCLMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAFk47Qn0O7cBUS/63OOwHkKwROmpnAzhQM7rIxNXFDO0VSmASugTHSTkCgt3qURK3m8WeJn3UmLchbRBFt9HHxbSO8MYZn/1BlBpN+k+RAvp76mJz6i2lC8Exj6fI7arcEOwP29hMlciJqyMWRPxUsI0fgyQkhCPFXhF4yby7OCd",
        "8e20ba053c17bcb2d1bff5b463c4799d":
            "MIIBKAyQAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqr1aVw2Ze1yQWrPMPoo8r1taQucrxX1yzxH8QBj6a09XxSw4c+Wu4Tet1xJn0RDt+OZ5KfokajKhsy3hhIR3tUMMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAAo2sJK/V1NNzJw+eXcJbUs1xaWGT/kW2fV1u6QbY8zqYSuhU4hk0pADhQhfXJ10WFySPCq57NiF4QHdoRet/mXTElJ5E/11OVOpZ8bq1i1KkrpjSxdOwBSmE9fpzXz3r9wT7b4k43RHgccqXP5NDiFqwzWSVTtqLOTVoZH+aTya",
        "d30b297c0dc65a81a9f4eccf5c2e7516":
            "MIIBKBqQAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqChu+L2hYU5hCBcVQBjjzQM/bqzgzvMJjptD7Mfj1RfWjpT671R4S17RZ4VubPyAXjOaPO3pXzjP6S9WNJQ6AHMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAALepQb+kqgUwpv27BXn/Noa8D+zj1ZiBWa3fj50hJ/SkuFyMTMXzAM8HqtVGz0VuUrHTP4qXSb3IG+UHCO7QMoydsFo30LTn5Qy8nIlOkZuy0CD6IOe19zK2Qvu/Tc0VlNyEIHPSdQt0DdwUnAEyxlZIQ3veqmLEh+T/vLDYiTFp",
        "1a13e3010b3575986fc96b744ca6187d":
            "MIIBKCaQAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqo+sBKJpyFlzqv3TaVJkOamx9/fkSCoB3EV9d0ZsSNibnk+YL0kkazz/2wQrH5AP+6PZxoRDQEPRci/z1FQqxM7MR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAFTCVRvU/9mq8dSANi86PQ0da3reNTRP7DS9ZTYP6G5rFVbXJLvDHST5d8X7oKzFRMggGNcdJFoco/DCdVjCzkOi4MvhTb21k7WEj3kNe9SNH3OCTgJknioLS0lWkUKbi6oKYOIb5NzDp4IloGpMz5FU/8BHFPMZF45KWrMs2ZnN",
        "9a0e3f6b3dd27cc38a8cdc85002797e7":
            "MIIBKDOQAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqoJT0gtKPY8cKTJAi9mjhjwLRbyOCu15wjxMkAwOT2P07ulcfiNlkG4q2KdcsRX6vRWlUtq846cH8LcE0vBP5foMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAHlvMK6nS8RZZt3MTghL4cRPQI5v8JRRWPAet4H4owbKVJHJnEOO4KKvLXAb7w2UphnBuyaxFjKPhvgAQh0V2mcJ6PiamWZmNDBKe5TbivE4xs35QpxxnsFEGuM4wwCUH+PppENr9jsxx506cIRKFE9nJ70jBow1yhJi+V3S5ss8",
        "ed69606aa78ce22b2a76a70bd8582395":
            "MIIBKD+QAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqoJOEoGGzcnBS3qZF02WHYutH2sZIdPDpBhJxi6Dl/QKAl1r6HqAqSHR/l3IbgMEWwhmLm4B7+K+wPlD5Njoqo4MR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAI/FBd06VLoNmPtB8Ed8ZpP9Qp8IXc5SaeD5eKCa1mZYWyXEepXqKf0YDjdkaA8vhUeblBBsXEZ2VsELp4lfId1ZjXWFr/La0NCw6bJDUxjKCRfS//39UQhU4v5Lelts/4QKAja1bW86UHYtO/LVDTPklYFWm23wNj+y57rRkltP",
        "97e3b65f0164d31a7806acfacd340956":
            "MIIBKFiQAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqpz1SZ5Vr9hJY87ZAFlGDdTdI5sOvWNAFB/jgG/CATUWxpyCwQ1c5uIcfQeyLaE+DgApe6IXn3RCTTUjb5Dk6HUMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAAiv6USEblSraurG5RuHXn+/+OipR5f3a9UEJ0cwKimmFrAbs5EVwPPtuKy4q7HeYytwRrexNhBLN2FYnDzf7TvbIxCzLU3G6Z+/l2h4JEU/eGyW8MmjN/j8aiiyJKkYji3QjqCZ8uJ1XkDyFriql+keGo1+7rwRUwUlZGYFMOFP",
        "6941ddf62dc6ca489c7d91cab8022688":
            "MIIBKA+gAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqRnDDLAbc+HLS/DmG8kBjwN4DU5z7MNt2CLeXedbg11KA3XD6j0U2ypsUjQ5C9L1IR6Y10kKQJi8YtEe5bI1PkMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAJkgWtq4X5nphMpJ8i9jdGumSuER/hA6bvFP3rwGf71j45MuouXbnUhVZYQRyzRpODWKlGsczbHagc3eKoT2LHqXXxh1SCF49H/PX94xWb/Pucx2zTv6MQ2DKizVFcYvk+uoyk7Q/h02ZXEsYn78iz3i/6yXnOYxYsdxNw/xruHG",
        "beb3f357113ca9e22b6afc543421dbc4":
            "MIIBKBGgAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqrkqlDgNf0IzOnNCiMENQa50n7RcNbUtyH5h4igPqQNjmfpAkWb021mUMkAwn2SmMLQi+tLn85PkjnlmLwA4+k4MR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAGp2hP/Shk37QBpSwnHqnlbxfWve/ZQZi+4k+1P69MEMpao+mBWWGDsEMYlPmPVQ0axMPb+5AfPeSzOFAwV0dnKKXtv12Fvf4ra5YTYiCbcgLseX4rq8t8BhcQRtCbTWpdmGjqY99WpEcjo4ryhomLkfI5mk7WDOerCmGnrpkKfD",
        "2b7b7c6b1dc7f7c9903a544eeaa7e204":
            "MIIBKC2gAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqZGi9k7Gn7UBg1iuGtJ2f2IFXvbh9Z/kbJJXasSWWJtRcZQIjIEPsFFuXPHePM3aElI1bqxDydBCqgUYRk0NdnMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAO9FERXko5dEjeHXKDx+li+iJknHJjcftcN6HChyQxTzibpWIxJWubFVTKIFmbZCuiXvJKer3AAEb5GEo6ZQA9XEovtIHVkLPacOAit6A/xeWsS+Lqc50tw7T4KFIPsWjnevxEaJ4OYP59QkGHMRVVVHehxg9GZmWRuXpQf7MQOu",
        "badd531b16fc77d84d9d193a14baa2ab":
            "MIIBKEOgAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqovJE/myYTSgFriDLxh9FsomcrbXmIU5pb6hAZiBc2M4IeuM8lMhFq75YyKPgvW2cGKf4AqagqTyTbjfVwXvYHXMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAFh50ugITsGF8Si398X7DbsGAYLo8VhKwz7uwa6raZbkSJRgAtHDXKMcgUbkKGaEsehhnLRXZtMOmbV12sIjH3ZX1sUwDNUzdW1pyZPiUQCHWFmWJKvccLX3QrNv+KGQhMhzXSLPamXA/RyKQpcW8mbEpiwdQpxMV2t+xAQ2HUY1",
        "05f7204c62a28c39f4c332f2b739a4e4":
            "MIIBKFqgAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqN1ZXbhQUBVnE/3ke424D8m6Pp5/4CN398hm4LSjf5iVYOUyuvPs+8/uSn6eIq8WFFBs18FETa+AOyaMdIc1QLMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAOfWvfOEcEY4oouSCfnJM49fT3KWWWUhvBZZvgoppbyVV1ZCQlxgBCKAGeoqI4POJSv1lE8MeMWkg48bq9tLrver5nGyaArPE/b9kZCI8UfYOYAPD+u9ltdc2AXJWU+wR4CZSPYsNkLE0+J+4NvDsWPby8zfzAM/1u9De6Oyr2sx",
        "87d6d649ae41f5930b94dd5135a97726":
            "MIIBKBSwAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqqCt21nHv7YddSAKC9ab9Jq23ILGLrsXU7vz7+yhIU6Ulqj+idaXtuv6dZpsEw8u2Oy2EYFghe1da5MoZkr14rpMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAPQsd1XiRjNhx3b1mzuuSPyMjguFSt/FKxJ7WEQQIhPixfxxwkNxepTxoz6fgBuMeJKdAeMNZoWStI4nOuk93S9yRfAvtAaHRGZhlYJWQ7UQmXLJhtj7VYkkqwcaVrdlRkdzoRQdjv6XEHXONMKIS55VWRDCEWFTwPafL/ILkLFl",
        "174fbff8cd15fe80c080285dcfa0ef5b":
            "MIIBKDawAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqoiKJ93XiUdIWZS0YtEfkjPkFxVGV+TJIztkV//T5B++/jhPcUz+4w55HI/SmJ+BaQOfFKrgq4n35gaFCRKpDhhMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAJNJa1QOyOcH6L8fwSZZd8YXLiYHWYQXgeensbNZdHJEDuPf7mUh0JqxKX/ygtJ2fx687LTMGaHJk/DdMP2D0Vd4a03IUDygc/LbYmcXWWw3vetbjMuWqdn0HLBhqLl8Vcexz7pNrtT6aDRvyqTEwhDqGc4FTlK9zd9SNEdvFjXL",
        "be8e5361195fb74a5a240bf313757bd4":
            "MIIBKFCwAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqohddnJkcaQ0RHd6ZgNc6ls9TO/rG+m/WgbbfuYAmU4xIRhcQC4u4gXMJORzY8TMDlA7xOOcpcjCPdsbb++ImAnMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAN8/kVrEvuRJe42Ew0ALEtHImNuNDYbDOCmBC5S0xmIRi9OCjfDOCZnA6YP77xTxkBgJ89VL8Wb6HV+tUzQfm7RJS4h58OEWImCoG74iPyk8LkG1zWmvRVc1jRP294SBx75DF7Fw3vgBoMW/GMLcMkh/eo9tCBGdaI+uO3lM5ykb",
        "5a94787e0213334f4c4907754842323d":
            "MIIBKBfAAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqpKH9vdS+abLZILx9uLKhhRtsIBqtLxc5pXCWYE0YkLMf84//+veeYLsey/k46mlAGGhlbXimQ/lTIsH1gX00beMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAAP9LwA5nsLR/R2hCeeKgBK15s4TyVrNWxaFps+e5wqTzQYjtchazvBE+xGOIAm2XOteL7Ymjgj0VwFoy6lZLlfc4z36Lngnnyk17BKXk0sDSREVNB+GbtVr1kawuPqA+8pkw1C/OIx5gqx7B0bNTO5AbGGMDgSYlz26hcSbSjU6k",
        "0e46df71d780db4fda4043fe4a6c3409":
            "MIIBKCPAAgZ2S5qTSDFCMiBTY3JpYmUtdjJiAFRUVFRUVFRUVFRUVA8VZqojozLTrtW2eplts1JAGmRFLAbGs1attjvFaOVK0txaSgq6CIY9mjgeFaYQ6vm0vR/a/jUoDT+2HJBUPaiaFlQeMR6Py2iHzIjPyy/x4Wy8kDIulvFm58TEcECfBGYMuLpoc2x0IEQyUDEAVFRUVFRUVFRUVFRUVFRUVFRUAAAAACYeUQVVquukSwAq91eYned3o+P9HRk99ogT8gy8x6noHJKAriIxNy9ALOIlFUK/eAFSXYxP73Xl9GV9YjgZnOSRCi0TT5OztQR/sobY9RHsqyIwouAJ9jRF0j2RAlNR0mDY0s2SMD6f25rt57y+B4f2fJKDDOQIJw5C79RmR5tU",
        "0c60d83110dde5d42d365ae639c7e1fa":
            "7/AoAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAANrCnkNKhKhlY9voyZvhq3TEbrLln2c539TklwbnhT2eHHH0OfeEWZsmdUmC36pkRdNftA4S52AfdqMEbk1WfbtPzkmqk6C68Way8uUfsw80mdaUeb1k7aSYJ0sQtZ46rnhUgh+XRvCoVoyMMXJQWf34LLl3N+M+F17o6/iEznoi",
    ]
}
