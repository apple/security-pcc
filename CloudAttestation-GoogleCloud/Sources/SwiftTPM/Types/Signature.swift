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
//  TPMT+Signature.swift
//  SwiftTPM
//
//  Created on 7/20/26.
//

import BinaryCoding

package typealias TPMT_SIGNATURE = TPMT.Signature

extension TPMT {
    package struct Signature: TPMDecodable, Hashable {
        var sigAlg: TPMI.Alg.SigScheme { signature.sigAlg }
        var signature: TPMU.Signature

        @StructureSize
        package var byteCount: Int {
            self.sigAlg
            self.signature
        }

        init(signature: TPMU.Signature) {
            self.signature = signature
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let sigAlg = try buffer.read(TPMI.Alg.SigScheme.self)

            switch sigAlg {
            case .rsassa:
                self.signature = .rsassa(try TPMS.SignatureRSA(from: &buffer))
            case .rsapss:
                self.signature = .rsapss(try TPMS.SignatureRSA(from: &buffer))
            case .ecdsa:
                self.signature = .ecdsa(try TPMS.SignatureECC(from: &buffer))
            case .ecdaa:
                self.signature = .ecdaa(try TPMS.SignatureECC(from: &buffer))
            case .sm2:
                self.signature = .sm2(try TPMS.SignatureECC(from: &buffer))
            case .ecschnorr:
                self.signature = .ecschnorr(try TPMS.SignatureECC(from: &buffer))
            default:
                throw TPMError.unsupported
            }
        }
    }
}

extension TPMU {
    enum Signature: Sized, Hashable {
        case rsassa(TPMS.SignatureRSA)
        case rsapss(TPMS.SignatureRSA)
        case ecdsa(TPMS.SignatureECC)
        case ecdaa(TPMS.SignatureECC)
        case sm2(TPMS.SignatureECC)
        case ecschnorr(TPMS.SignatureECC)
        case hmac(TPMT.HA)

        var sigAlg: TPMI.Alg.SigScheme {
            switch self {
            case .rsassa(_):
                .rsassa
            case .rsapss(_):
                .rsapss
            case .ecdsa(_):
                .ecdsa
            case .ecdaa(_):
                .ecdaa
            case .sm2(_):
                .sm2
            case .ecschnorr(_):
                .ecschnorr
            case .hmac(_):
                .hmac
            }
        }

        var byteCount: Int {
            switch self {
            case .rsassa(let rsa):
                rsa.byteCount
            case .rsapss(let rsa):
                rsa.byteCount
            case .ecdsa(let ecc):
                ecc.byteCount
            case .ecdaa(let ecc):
                ecc.byteCount
            case .sm2(let ecc):
                ecc.byteCount
            case .ecschnorr(let ecc):
                ecc.byteCount
            case .hmac(let hmac):
                hmac.byteCount
            }
        }
    }
}

typealias TPMI_ALG_SIG_SCHEME = TPMI.Alg.SigScheme

extension TPMI.Alg {
    enum SigScheme: TPMDecodable, Hashable {
        case rsassa
        case rsapss
        case ecdsa
        case ecdaa
        case sm2
        case ecschnorr
        case hmac
    }
}

// MARK: - Package projection

extension TPMT.Signature {
    /// The digest algorithm the signature was computed over, expressed as a
    /// `TPM_ALG_ID`. `nil` for schemes that do not carry one (e.g. `hmac`).
    package var hashAlgorithm: TPM.Alg.ID? {
        switch signature {
        case .rsassa(let rsa), .rsapss(let rsa):
            rsa.hash.rawValue
        case .ecdsa(let ecc), .ecdaa(let ecc), .sm2(let ecc), .ecschnorr(let ecc):
            ecc.hash.rawValue
        case .hmac:
            nil
        }
    }

    /// The ECDSA signature scalars `(r, s)` as the big-endian
    /// `TPM2B_ECC_PARAMETER` bytes stored by the TPM, for the ECC schemes
    /// (`ecdsa`/`ecdaa`/`sm2`/`ecschnorr`). `nil` for RSA or `hmac`. The TPM may
    /// omit leading zero bytes, so callers needing fixed-width scalars must
    /// left-pad each to the curve's order size.
    package var ecdsaSignature: (r: [UInt8], s: [UInt8])? {
        switch signature {
        case .ecdsa(let ecc), .ecdaa(let ecc), .sm2(let ecc), .ecschnorr(let ecc):
            (ecc.signatureR.buffer, ecc.signatureS.buffer)
        case .rsassa, .rsapss, .hmac:
            nil
        }
    }

    /// The RSA modular signature `sig` for the RSA schemes (`rsassa`/`rsapss`).
    /// `nil` for ECC or `hmac`.
    package var rsaSignature: [UInt8]? {
        switch signature {
        case .rsassa(let rsa), .rsapss(let rsa):
            rsa.sig.buffer
        case .ecdsa, .ecdaa, .sm2, .ecschnorr, .hmac:
            nil
        }
    }
}

extension TPMI.Alg.SigScheme: StaticSized, RawRepresentable {
    init?(rawValue: TPM.Alg.ID) {
        switch rawValue {
        case .rsassa:
            self = .rsassa
        case .rsapss:
            self = .rsapss
        case .ecdsa:
            self = .ecdsa
        case .ecdaa:
            self = .ecdaa
        case .sm2:
            self = .sm2
        case .ecschnorr:
            self = .ecschnorr
        case .hmac:
            self = .hmac
        default:
            return nil
        }
    }

    var rawValue: TPM.Alg.ID {
        switch self {
        case .rsassa:
            .rsassa
        case .rsapss:
            .rsapss
        case .ecdsa:
            .ecdsa
        case .ecdaa:
            .ecdaa
        case .sm2:
            .sm2
        case .ecschnorr:
            .ecschnorr
        case .hmac:
            .hmac
        }
    }
}
