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
//  AlgID.swift
//  SwiftTPM
//
//  Created on 12/11/25.
//

import BinaryCoding

extension TPM {
    package enum Alg {}
}

extension TPMI {
    package enum Alg {}
}

extension TPM.Alg {
    package enum ID: UInt16, TPMDecodable, StaticSized {
        case error = 0
        case rsa = 0x1
        case tdes = 0x3
        case sha1 = 0x4
        case hmac = 0x5
        case aes = 0x6
        case mgf1 = 0x7
        case keyedhash = 0x8
        case xor = 0xa
        case sha256 = 0xb
        case sha384 = 0xc
        case sha512 = 0xd
        case null = 0x10
        case sm3_256 = 0x12
        case sm4 = 0x13
        case rsassa = 0x14
        case rsaes = 0x15
        case rsapss = 0x16
        case oaep = 0x17
        case ecdsa = 0x18
        case ecdh = 0x19
        case ecdaa = 0x1a
        case sm2 = 0x1b
        case ecschnorr = 0x1c
        case ecmqv = 0x1d
        case kdf1_sp800_56a = 0x20
        case kdf2 = 0x21
        case kdf1_sp800_108 = 0x22
        case ecc = 0x23
        case symcipher = 0x25
        case camellia = 0x26
        case sha3_256 = 0x27
        case sha3_384 = 0x28
        case cmac = 0x3f
        case ctr = 0x40
        case ofb = 0x41
        case cbc = 0x42
        case cfb = 0x43
        case ecb = 0x44

        static var sha: Self { .sha1 }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let id = try buffer.read(Self.RawValue.self, byteOrder: .bigEndian)
            guard let this = Self(rawValue: id) else {
                throw TPMError.invalidValue(id, for: Self.self)
            }
            self = this
        }
    }
}

typealias TPM_ALG_ID = TPM.Alg.ID

extension TPMI.Alg {
    package enum Hash: TPMDecodable {
        case sha1
        case sha256
        case sha384
        case sha512
        case sha3_256
        case sha3_384
        case sm3_256

        package var digestSize: Int {
            switch self {
            case .sha1:
                20
            case .sha256:
                32
            case .sha384:
                48
            case .sha512:
                64
            case .sha3_256:
                32
            case .sha3_384:
                48
            case .sm3_256:
                32
            }
        }
    }
}

extension TPMI.Alg.Hash: StaticSized, RawRepresentable {
    package init?(rawValue: TPM.Alg.ID) {
        switch rawValue {
        case .sha1:
            self = .sha1
        case .sha256:
            self = .sha256
        case .sha384:
            self = .sha384
        case .sha512:
            self = .sha512
        case .sm3_256:
            self = .sm3_256
        case .sha3_256:
            self = .sha3_256
        case .sha3_384:
            self = .sha3_384
        default:
            return nil
        }
    }

    package var rawValue: TPM.Alg.ID {
        switch self {
        case .sha1:
            .sha1
        case .sha256:
            .sha256
        case .sha384:
            .sha384
        case .sha512:
            .sha512
        case .sha3_256:
            .sha3_256
        case .sha3_384:
            .sha3_384
        case .sm3_256:
            .sm3_256
        }
    }
}

package typealias TPMI_ALG_HASH = TPMI.Alg.Hash
