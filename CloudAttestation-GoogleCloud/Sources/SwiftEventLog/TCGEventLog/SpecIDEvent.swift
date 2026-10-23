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
//  SpecIDEvent.swift
//  CloudAttestationV2
//
//  Created by David Zech on 1/28/26.
//

import BinaryCoding
import SwiftTPM

package struct SpecIDEvent: BinaryDecodable {
    package var header: Header
    var numAlgs: UInt32 {
        UInt32(digestSizes.count)
    }
    package var digestSizes: [SpecIDEvent.AlgorithmSize]
    var vendorInfoSize: UInt8 {
        UInt8(vendorInfo.count)
    }
    package var vendorInfo: [UInt8]

    @StructureSize
    package var byteCount: Int {
        self.header
        self.numAlgs
        self.digestSizes
        self.vendorInfoSize
        self.vendorInfo
    }

    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.header = try buffer.read()
        let numAlgs: UInt32 = try buffer.read()
        self.digestSizes = try buffer.read(count: Int(numAlgs))
        let vendorInfoSize: UInt8 = try buffer.read()
        self.vendorInfo = try buffer.read(count: Int(vendorInfoSize))
    }

    package init(header: Header, digestSizes: [AlgorithmSize], vendorInfo: [UInt8] = []) {
        self.header = header
        self.digestSizes = digestSizes
        self.vendorInfo = vendorInfo
    }
}

extension SpecIDEvent {
    package struct Header: StaticSized, BinaryDecodable {
        static let signature: [16 of UInt8] = [
            0x53, 0x70,
            0x65, 0x63, 0x20, 0x49,
            0x44, 0x20, 0x45, 0x76,
            0x65, 0x6e, 0x74, 0x30,
            0x33, 0x00,
        ]  // "Spec ID Event03\0"

        package var signature: [16 of UInt8]
        package var platformClass: UInt32
        package var versionMinor: UInt8
        package var versionMajor: UInt8
        package var errata: UInt8
        package var uintnSize: UInt8

        @StructureSize
        package static var byteCount: Int {
            \Self.signature
            \Self.platformClass
            \Self.versionMinor
            \Self.versionMajor
            \Self.errata
            \Self.uintnSize
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.signature = try buffer.read()
            self.platformClass = try buffer.read()
            self.versionMinor = try buffer.read()
            self.versionMajor = try buffer.read()
            self.errata = try buffer.read()
            self.uintnSize = try buffer.read()

            guard self.signature.bytes == Self.signature.bytes else {
                throw TCGEventLogError.invalidSpecIDSignature(signature: self.signature.bytes)
            }
        }

        package init(platformClass: UInt32 = 0, versionMinor: UInt8 = 0, versionMajor: UInt8 = 2, errata: UInt8 = 0, uintnSize: UInt8 = 2) {
            self.signature = Self.signature
            self.platformClass = platformClass
            self.versionMinor = versionMinor
            self.versionMajor = versionMajor
            self.errata = errata
            self.uintnSize = uintnSize
        }
    }

    package struct AlgorithmSize: StaticSized, BinaryDecodable {
        package var id: UInt16
        package var size: UInt16

        @StructureSize
        package static var byteCount: Int {
            \Self.id
            \Self.size
        }

        package init(from buffer: inout ArraySlice<UInt8>) throws {
            self.id = try buffer.read()
            self.size = try buffer.read()
        }

        package init(id: UInt16, size: UInt16) {
            self.id = id
            self.size = size
        }
    }
}
