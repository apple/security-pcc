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
//  Blackwell+OpaqueDataType.swift
//  CloudAttestationV2
//
//  Created by David Zech on 2/17/26.
//

extension Blackwell {
    // MARK: - Opaque Data Type Helpers
    public enum OpaqueDataType: UInt16 {
        case certIssuerName = 1
        case certAuthorityKeyIdentifier = 2
        case driverVersion = 3
        case gpuInfo = 4
        case sku = 5
        case vbiosVersion = 6
        case manufacturerId = 7
        case tamperDetection = 8
        case smc = 9
        case vpr = 10
        case nvdec0Status = 11
        case msrscnt = 12
        case cprinfo = 13
        case boardId = 14
        case chipSku = 15
        case chipSkuMod = 16
        case project = 17
        case projectSku = 18
        case projectSkuMod = 19
        case fwid = 20
        case protectedPcieStatus = 21
        case switchPdi = 22
        case floorsweptPorts = 23
        case positionId = 24
        case lockSwitchStatus = 25
        case gpuLinkConn = 32
        case sysEnableStatus = 33
        case opaqueDataVersion = 34
        case chipInfo = 35
        case featureFlag = 36

        public var name: String {
            switch self {
            case .certIssuerName: return "CERT_ISSUER_NAME"
            case .certAuthorityKeyIdentifier: return "CERT_AUTHORITY_KEY_IDENTIFIER"
            case .driverVersion: return "DRIVER_VERSION"
            case .gpuInfo: return "GPU_INFO"
            case .sku: return "SKU"
            case .vbiosVersion: return "VBIOS_VERSION"
            case .manufacturerId: return "MANUFACTURER_ID"
            case .tamperDetection: return "TAMPER_DETECTION"
            case .smc: return "SMC"
            case .vpr: return "VPR"
            case .nvdec0Status: return "NVDEC0_STATUS"
            case .msrscnt: return "MSRSCNT"
            case .cprinfo: return "CPRINFO"
            case .boardId: return "BOARD_ID"
            case .chipSku: return "CHIP_SKU"
            case .chipSkuMod: return "CHIP_SKU_MOD"
            case .project: return "PROJECT"
            case .projectSku: return "PROJECT_SKU"
            case .projectSkuMod: return "PROJECT_SKU_MOD"
            case .fwid: return "FWID"
            case .protectedPcieStatus: return "PROTECTED_PCIE_STATUS"
            case .switchPdi: return "SWITCH_PDI"
            case .floorsweptPorts: return "FLOORSWEPT_PORTS"
            case .positionId: return "POSITION_ID"
            case .lockSwitchStatus: return "LOCK_SWITCH_STATUS"
            case .gpuLinkConn: return "GPU_LINK_CONN"
            case .sysEnableStatus: return "SYS_ENABLE_STATUS"
            case .opaqueDataVersion: return "OPAQUE_DATA_VERSION"
            case .chipInfo: return "CHIP_INFO"
            case .featureFlag: return "FEATURE_FLAG"
            }
        }
    }
}
