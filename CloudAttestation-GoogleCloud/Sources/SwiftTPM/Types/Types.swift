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
//  TPMS.swift
//  SwiftTPM
//
//  Created on 12/11/25.
//

import BinaryCoding

// MARK: - TPMS

package enum TPMS {}

// MARK: - TPM
package enum TPM {
    /// Structure tag
    /// Structure tags are used to disambiguate structures. They are 16-bit values with the most significant bit SET so that they do not overlap TPM_ALG_ID values.
    /// A single exception is made for the value associated with TPM_ST_RSP_COMMAND (0x00C4), which has the same value as the TPM_TAG_RSP_COMMAND tag from earlier versions of this specification.
    /// This value is used when the TPM is compatible with a previous TPM specification and the TPM cannot determine which family of response code to return because the command tag is not valid.
    /// Many of the structures defined in this document have parameters that are unions of other structures. That is, a parameter may be one of several structures.
    /// The parameter will have a selector value that indicates which of the options is actually present.
    /// In order to allow the marshaling and unmarshaling code to determine which of the possible structures is allowed, each selector will have a unique interface type and will constrain the number of possible tag values.
    /// Table 19 defines the structure tags values. The definition of many structures is context-sensitive using an algorithm ID.
    /// In cases where an algorithm ID is not a meaningful way to designate the structure, the values in this table are used.
    package enum ST: UInt16, StaticSized, TPMDecodable {
        case rspCommand = 0x00C4
        case null = 0x8000
        case sessions
        case attestNV = 0x8014
        case attestCommandAudit
        case attestSessionAudit
        case attestCertify
        case attestQuote
        case attestTime
        case attestCreation
        case attestNVDigest = 0x801C
        case creation = 0x8021
        case verified
        case authSecret
        case hashCheck
        case authSigned
        case fuManifest

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            let val = try buffer.read(Self.RawValue.self, byteOrder: .bigEndian)
            guard let st = ST(rawValue: val) else {
                throw TPMError.invalidValue(val, for: Self.self)
            }
            self = st
        }
    }

    package typealias Constants32 = UInt32

    package static let GeneratedValue: Constants32 = 0xFF54_4347

    typealias Handle = UInt32
}

typealias TPM_HANDLE = TPM.Handle

let TPM_ST_RSP_COMMAND = TPM.ST.rspCommand
let TPM_ST_NULL = TPM.ST.null
let TPM_ST_SESSIONS = TPM.ST.sessions
let TPM_ST_ATTEST_NV = TPM.ST.attestNV
let TPM_ST_ATTEST_COMMAND_AUDIT = TPM.ST.attestCommandAudit
let TPM_ST_ATTEST_SESSION_AUDIT = TPM.ST.attestSessionAudit
let TPM_ST_ATTEST_CERTIFY = TPM.ST.attestCertify
let TPM_ST_ATTEST_QUOTE = TPM.ST.attestQuote
let TPM_ST_ATTEST_TIME = TPM.ST.attestTime
let TPM_ST_ATTEST_CREATION = TPM.ST.attestCreation
let TPM_ST_ATTEST_NV_DIGEST = TPM.ST.attestNVDigest
let TPM_ST_CREATION = TPM.ST.creation
let TPM_ST_VERIFIED = TPM.ST.verified
let TPM_ST_AUTH_SECRET = TPM.ST.authSecret
let TPM_ST_HASH_CHECK = TPM.ST.hashCheck
let TPM_ST_AUTH_SIGNED = TPM.ST.authSigned
let TPM_ST_FU_MANIFEST = TPM.ST.fuManifest
let TPM_GENERATED_VALUE = TPM.GeneratedValue

// MARK: - TPMI

package enum TPMI {
    package enum ST {}

    package typealias YesNo = Bool
}

package typealias TPMI_ST = TPMI.ST
package typealias TPMI_YES_NO = TPMI.YesNo

// MARK: - TPMU
package enum TPMU {}

// MARK: - TPMT
package enum TPMT {}

// MARK: - TPM2B
package struct TPM2B {
    struct Container<T>: TPMDecodable {
        var size: UInt16 {
            UInt16(buffer.count)
        }
        var buffer: [UInt8]

        var byteCount: Int {
            self.size.byteCount + buffer.byteCount
        }

        init(buffer: some Sequence<UInt8>) {
            self.buffer = .init(buffer)
        }

        init(from buffer: inout ArraySlice<UInt8>) throws {
            let size = try buffer.read(UInt16.self, byteOrder: .bigEndian)
            self.buffer = .init(try buffer.readBytes(count: Int(size)))
            guard self.buffer.count == self.size else {
                throw TPMError.invalidSize
            }
        }
    }

    protocol DecodableContainerProtocol {
        associatedtype T
        func decode(using decoder: TPMDecoder) throws -> T
    }
}

extension TPM2B.Container: TPM2B.DecodableContainerProtocol where T: TPMDecodable {
    func decode(using decoder: TPMDecoder = TPMDecoder()) throws -> T {
        try decoder.decode(T.self, from: self.buffer)
    }
}

extension TPM2B.Container: Equatable where T: Equatable {}

extension TPM2B.Container: Hashable where T: Hashable {}

// MARK: - TPML

enum TPML {
    struct List<T: TPMDecodable>: TPMDecodable {
        var count: UInt32 { UInt32(objects.count) }
        var objects: [T]

        var byteCount: Int {
            count.byteCount
                + objects.reduce(
                    0,
                    { acc, obj in
                        acc + obj.byteCount
                    }
                )
        }

        init(objects: some Sequence<T>) {
            self.objects = .init(objects)
        }

        init(from buffer: inout ArraySlice<UInt8>) throws {
            let count = try buffer.read(UInt32.self, byteOrder: .bigEndian)
            var objects: [T] = .init()
            for _ in 0..<count {
                objects.append(try buffer.read(T.self))
            }
            self.objects = objects
        }
    }
}

extension TPML.List: Equatable where T: Equatable {}
extension TPML.List: Hashable where T: Hashable {}
