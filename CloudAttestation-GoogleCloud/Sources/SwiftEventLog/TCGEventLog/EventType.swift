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
//  EventType.swift
//  CloudAttestationV2
//
//  Created by David Zech on 1/30/26.
//

import BinaryCoding

package enum EventType: RawRepresentable, ExpressibleByIntegerLiteral, Hashable {
    package var rawValue: UInt32 {
        switch self {
        case .prebootCert:
            0
        case .postCode:
            1
        case .unused:
            2
        case .evNoAction:
            3
        case .separator:
            4
        case .action:
            5
        case .eventTag:
            6
        case .sCRTMContents:
            7
        case .sCRTMVersion:
            8
        case .cpuMicrocode:
            9
        case .platformConfigFlags:
            10
        case .tableOfDevices:
            11
        case .compactHash:
            12
        case .ipl:
            13
        case .iplPartitionData:
            14
        case .efiVariableDriverConfig:
            0x8000_0001
        case .efiVariableBoot:
            0x8000_0002
        case .efiBootServicesApplication:
            0x8000_0003
        case .efiBootServicesDriver:
            0x8000_0004
        case .efiRuntimeServicesDriver:
            0x8000_0005
        case .efiGPTEvent:
            0x8000_0006
        case .efiAction:
            0x8000_0007
        case .efiPlatformFirmwareBlob:
            0x8000_0008
        case .efiHandoffTables:
            0x8000_0009
        case .efiPlatformFirmwareBlob2:
            0x8000_000a
        case .efiHandoffTables2:
            0x8000_000b
        case .efiVariableAuthority:
            0x8000_00e0
        case .efiSPDMFirmwareBlob:
            0x8000_00e1
        case .efiSPDMFirmwareConfig:
            0x8000_00e2
        case .efiHCRTMEvent:
            0x8000_0010
        case .googleDRTMEvent:
            0x1000_0000
        case .unknown(let uInt32):
            uInt32
        }
    }

    case prebootCert
    case postCode
    case unused
    case evNoAction
    case separator
    case action
    case eventTag
    case sCRTMContents
    case sCRTMVersion
    case cpuMicrocode
    case platformConfigFlags
    case tableOfDevices
    case compactHash
    case ipl
    case iplPartitionData
    case efiVariableDriverConfig
    case efiVariableBoot
    case efiBootServicesApplication
    case efiBootServicesDriver
    case efiRuntimeServicesDriver
    case efiGPTEvent
    case efiAction
    case efiPlatformFirmwareBlob
    case efiHandoffTables
    case efiPlatformFirmwareBlob2
    case efiHandoffTables2
    case efiVariableAuthority
    case efiSPDMFirmwareBlob
    case efiSPDMFirmwareConfig
    /// `EV_EFI_HCRTM_EVENT` — the H-CRTM measurement (BMC firmware on GCP hosts).
    case efiHCRTMEvent
    /// Google-custom DRTM event type (host BIOS measurement on GCP hosts).
    case googleDRTMEvent
    case unknown(UInt32)

    static func == (lhs: Self, rhs: UInt32) -> Bool {
        return lhs.rawValue == rhs
    }

    package init(integerLiteral: UInt32) {
        self.init(rawValue: integerLiteral)
    }

    package init(rawValue: UInt32) {
        self =
            switch rawValue {
            case 0:
                .prebootCert
            case 1:
                .postCode
            case 2:
                .unused
            case 3:
                .evNoAction
            case 4:
                .separator
            case 5:
                .action
            case 6:
                .eventTag
            case 7:
                .sCRTMContents
            case 8:
                .sCRTMVersion
            case 9:
                .cpuMicrocode
            case 10:
                .platformConfigFlags
            case 11:
                .tableOfDevices
            case 12:
                .compactHash
            case 13:
                .ipl
            case 14:
                .iplPartitionData
            case 0x8000_0001:
                .efiVariableDriverConfig
            case 0x8000_0002:
                .efiVariableBoot
            case 0x8000_0003:
                .efiBootServicesApplication
            case 0x8000_0004:
                .efiBootServicesDriver
            case 0x8000_0005:
                .efiRuntimeServicesDriver
            case 0x8000_0006:
                .efiGPTEvent
            case 0x8000_0007:
                .efiAction
            case 0x8000_0008:
                .efiPlatformFirmwareBlob
            case 0x8000_0009:
                .efiHandoffTables
            case 0x8000_000a:
                .efiPlatformFirmwareBlob2
            case 0x8000_000b:
                .efiHandoffTables2
            case 0x8000_00e0:
                .efiVariableAuthority
            case 0x8000_00e1:
                .efiSPDMFirmwareBlob
            case 0x8000_00e2:
                .efiSPDMFirmwareConfig
            case 0x8000_0010:
                .efiHCRTMEvent
            case 0x1000_0000:
                .googleDRTMEvent
            default:
                .unknown(rawValue)
            }
    }
}

extension EventType: StaticSized, BinaryDecodable {
    package init(from buffer: inout ArraySlice<UInt8>) throws {
        self.init(rawValue: try buffer.read(UInt32.self))
    }
}

extension EventType: CustomDebugStringConvertible {
    package var debugDescription: String {
        switch self {
        case .prebootCert: "prebootCert"
        case .postCode: "postCode"
        case .unused: "unused"
        case .evNoAction: "evNoAction"
        case .separator: "separator"
        case .action: "action"
        case .eventTag: "eventTag"
        case .sCRTMContents: "sCRTMContents"
        case .sCRTMVersion: "sCRTMVersion"
        case .cpuMicrocode: "cpuMicrocode"
        case .platformConfigFlags: "platformConfigFlags"
        case .tableOfDevices: "tableOfDevices"
        case .compactHash: "compactHash"
        case .ipl: "ipl"
        case .iplPartitionData: "iplPartitionData"
        case .efiVariableDriverConfig: "efiVariableDriverConfig"
        case .efiVariableBoot: "efiVariableBoot"
        case .efiBootServicesApplication: "efiBootServicesApplication"
        case .efiBootServicesDriver: "efiBootServicesDriver"
        case .efiRuntimeServicesDriver: "efiRuntimeServicesDriver"
        case .efiGPTEvent: "efiGPTEvent"
        case .efiAction: "efiAction"
        case .efiPlatformFirmwareBlob: "efiPlatformFirmwareBlob"
        case .efiHandoffTables: "efiHandoffTables"
        case .efiPlatformFirmwareBlob2: "efiPlatformFirmwareBlob2"
        case .efiHandoffTables2: "efiHandoffTables2"
        case .efiVariableAuthority: "efiVariableAuthority"
        case .efiSPDMFirmwareBlob: "efiSPDMFirmwareBlob"
        case .efiSPDMFirmwareConfig: "efiSPDMFirmwareConfig"
        case .efiHCRTMEvent: "efiHCRTMEvent"
        case .googleDRTMEvent: "googleDRTMEvent"
        case .unknown(let value): "unknown(0x\(String(value, radix: 16)))"
        }
    }
}
