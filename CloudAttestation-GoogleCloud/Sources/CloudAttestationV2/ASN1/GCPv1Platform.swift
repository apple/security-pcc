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

import Common
import Foundation
import SwiftASN1

/// GCPv1 platform firmware measurements, DER-encoded per the ASN.1 schema in `CloudAttestation.asn`.
///
/// ```
/// GCPv1Platform ::= SEQUENCE {
///     titan      [0] OCTET STRING OPTIONAL,
///     bmc        [1] OCTET STRING OPTIONAL,
///     bios       [2] OCTET STRING OPTIONAL,
///     intelTDX   [3] IntelTDXPlatform OPTIONAL,
///     nvidiaGPU  [4] NvidiaGPUMeasurement OPTIONAL,
///     ovmfDigest [5] OCTET STRING OPTIONAL
/// }
/// ```
public struct GCPv1Platform: Sendable, Hashable, Encodable {
    /// SHA-256 RW firmware hash of the Titan security chip, from the `rwHash`
    /// field of its EK certificate.
    public let titanMeasurement: Data?

    /// SHA-256 digest of the bare-metal host's BMC firmware — the single
    /// `EV_EFI_HCRTM_EVENT` (Titan H-CRTM) measured into PCR[0]. Matches GCP's
    /// `GMESState.BmcFirmwareDigest`; reconciled by policy against `host.bmcFirmwareDigest`.
    public let bmcMeasurement: Data?

    /// SHA-256 digest of the bare-metal host's BIOS — the single Google DRTM
    /// event measured into PCR[17]. Matches GCP's `GMESState.BiosDigest`;
    /// reconciled by policy against `host.biosDigest`.
    public let biosMeasurement: Data?

    /// Intel TDX platform TCB configuration.
    public let intelTDX: IntelTDXPlatform?

    /// NVIDIA GPU firmware measurements (driver + optional VBIOS).
    public let nvidiaGPU: NvidiaGPUMeasurement?

    /// SHA-384 digest of the OVMF firmware (MRTD). Only present in VMs.
    public let ovmfDigest: Data?

    public init(
        titanMeasurement: Data? = nil,
        bmcMeasurement: Data? = nil,
        biosMeasurement: Data? = nil,
        intelTDX: IntelTDXPlatform? = nil,
        nvidiaGPU: NvidiaGPUMeasurement? = nil,
        ovmfDigest: Data? = nil
    ) {
        self.titanMeasurement = titanMeasurement
        self.bmcMeasurement = bmcMeasurement
        self.biosMeasurement = biosMeasurement
        self.intelTDX = intelTDX
        self.nvidiaGPU = nvidiaGPU
        self.ovmfDigest = ovmfDigest
    }
}

// MARK: - DER Encoding

extension GCPv1Platform: DERSerializable {
    public func serialize(into coder: inout DER.Serializer) throws {
        try coder.appendConstructedNode(identifier: .sequence) { coder in
            // [0] titan OPTIONAL — EK certificate RW firmware hash (Titan chip)
            if let titanMeasurement {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](titanMeasurement)[...]),
                    explicitlyTaggedWithTagNumber: 0,
                    tagClass: .contextSpecific
                )
            }
            // [1] bmc OPTIONAL — EV_EFI_HCRTM_EVENT digest at PCR[0] (BMC firmware)
            if let bmcMeasurement {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](bmcMeasurement)[...]),
                    explicitlyTaggedWithTagNumber: 1,
                    tagClass: .contextSpecific
                )
            }
            // [2] bios OPTIONAL — Google DRTM event digest (host BIOS)
            if let biosMeasurement {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](biosMeasurement)[...]),
                    explicitlyTaggedWithTagNumber: 2,
                    tagClass: .contextSpecific
                )
            }
            // [3] intelTDX OPTIONAL
            if let intelTDX {
                try coder.serialize(
                    intelTDX,
                    explicitlyTaggedWithTagNumber: 3,
                    tagClass: .contextSpecific
                )
            }
            // [4] nvidiaGPU OPTIONAL
            if let nvidiaGPU {
                try coder.serialize(
                    nvidiaGPU,
                    explicitlyTaggedWithTagNumber: 4,
                    tagClass: .contextSpecific
                )
            }
            // [5] ovmfDigest OPTIONAL
            if let ovmfDigest {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](ovmfDigest)[...]),
                    explicitlyTaggedWithTagNumber: 5,
                    tagClass: .contextSpecific
                )
            }
        }
    }
}

// MARK: - DER Decoding

extension GCPv1Platform: DERParseable {
    public init(derEncoded node: ASN1Node) throws {
        self = try DER.sequence(node, identifier: .sequence) { nodes in
            // [0] titan — EK certificate RW firmware hash (Titan chip)
            let titan: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 0,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }
            // [1] bmc — EV_EFI_HCRTM_EVENT digest at PCR[0] (BMC firmware)
            let bmc: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 1,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }
            // [2] bios — Google DRTM event digest (host BIOS)
            let bios: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 2,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }
            // [3] intelTDX
            let intelTDX: IntelTDXPlatform? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 3,
                tagClass: .contextSpecific
            ) { try IntelTDXPlatform(derEncoded: $0) }
            // [4] nvidiaGPU
            let nvidiaGPU: NvidiaGPUMeasurement? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 4,
                tagClass: .contextSpecific
            ) { try NvidiaGPUMeasurement(derEncoded: $0) }
            // [5] ovmfDigest
            let ovmfDigest: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 5,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            return GCPv1Platform(
                titanMeasurement: titan.map { Data($0.bytes) },
                bmcMeasurement: bmc.map { Data($0.bytes) },
                biosMeasurement: bios.map { Data($0.bytes) },
                intelTDX: intelTDX,
                nvidiaGPU: nvidiaGPU,
                ovmfDigest: ovmfDigest.map { Data($0.bytes) }
            )
        }
    }
}
