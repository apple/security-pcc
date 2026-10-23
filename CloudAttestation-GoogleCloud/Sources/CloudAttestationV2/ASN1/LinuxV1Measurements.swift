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
//  LinuxV1Measurements.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import SwiftASN1

/// Linux boot measurements, DER-encoded per the ASN.1 schema in `CloudAttestation.asn`.
///
/// ```
/// LinuxV1Measurements ::= SEQUENCE {
///     ukiDigest         [0] OCTET STRING OPTIONAL,
///     ovmfDigest        [1] OCTET STRING OPTIONAL,
///     nvidiaDriver      [2] NvidiaGPUMeasurement OPTIONAL,
///     shimDigest        [3] OCTET STRING OPTIONAL,
///     grubDigest        [4] OCTET STRING OPTIONAL,
///     vmlinuzDigest     [5] OCTET STRING OPTIONAL,
///     kernelCommandLine [6] UTF8String OPTIONAL
/// }
/// ```
public struct LinuxV1Measurements: Sendable, Hashable, Encodable {
    /// Digest of the UKI PE image sans signature (Bowcaster and beyond). SHA-384 for guest VM
    /// UKIs (measured into TDX SHA-384 RTMRs); SHA-256 for the bare-metal host UKI (measured into
    /// the host TPM's SHA-256 PCR[21]).
    public let ukiDigest: Data?

    /// SHA-384 digest of OVMF firmware (only present in VMs). Set per-VM in the GCPv1
    /// host-image flow (each guest VM measures its own OVMF). Standalone GCPv1 VM images
    /// instead record platform OVMF in ``GCPv1Platform/ovmfDigest``. Also populated on
    /// Bowcaster, where OVMF is recorded in the host TPM event log.
    public let ovmfDigest: Data?

    /// NVIDIA driver firmware (product, version, SPDM measurements). Only set on
    /// `workloadVMMeasurements` because the driver is loaded by the workload OS image.
    public let nvidiaDriver: NvidiaGPUMeasurement?

    /// SHA-384 digest of the shim bootloader (Vanguard).
    public let shimDigest: Data?

    /// SHA-384 digest of the GRUB bootloader (Vanguard).
    public let grubDigest: Data?

    /// SHA-384 digest of the vmlinuz kernel image (Vanguard).
    public let vmlinuzDigest: Data?

    /// Kernel command line string (Vanguard).
    public let kernelCommandLine: String?

    public init(
        ukiDigest: Data? = nil,
        ovmfDigest: Data? = nil,
        nvidiaDriver: NvidiaGPUMeasurement? = nil,
        shimDigest: Data? = nil,
        grubDigest: Data? = nil,
        vmlinuzDigest: Data? = nil,
        kernelCommandLine: String? = nil
    ) {
        self.ukiDigest = ukiDigest
        self.ovmfDigest = ovmfDigest
        self.nvidiaDriver = nvidiaDriver
        self.shimDigest = shimDigest
        self.grubDigest = grubDigest
        self.vmlinuzDigest = vmlinuzDigest
        self.kernelCommandLine = kernelCommandLine
    }
}

// MARK: - DER Encoding

extension LinuxV1Measurements: DERSerializable {
    public func serialize(into coder: inout DER.Serializer) throws {
        try coder.appendConstructedNode(identifier: .sequence) { coder in
            if let ukiDigest {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](ukiDigest)[...]),
                    explicitlyTaggedWithTagNumber: 0,
                    tagClass: .contextSpecific
                )
            }
            if let ovmfDigest {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](ovmfDigest)[...]),
                    explicitlyTaggedWithTagNumber: 1,
                    tagClass: .contextSpecific
                )
            }
            if let nvidiaDriver {
                try coder.serialize(
                    nvidiaDriver,
                    explicitlyTaggedWithTagNumber: 2,
                    tagClass: .contextSpecific
                )
            }
            if let shimDigest {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](shimDigest)[...]),
                    explicitlyTaggedWithTagNumber: 3,
                    tagClass: .contextSpecific
                )
            }
            if let grubDigest {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](grubDigest)[...]),
                    explicitlyTaggedWithTagNumber: 4,
                    tagClass: .contextSpecific
                )
            }
            if let vmlinuzDigest {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](vmlinuzDigest)[...]),
                    explicitlyTaggedWithTagNumber: 5,
                    tagClass: .contextSpecific
                )
            }
            if let kernelCommandLine {
                try coder.serialize(
                    ASN1UTF8String(kernelCommandLine),
                    explicitlyTaggedWithTagNumber: 6,
                    tagClass: .contextSpecific
                )
            }
        }
    }
}

// MARK: - DER Decoding

extension LinuxV1Measurements: DERParseable {
    public init(derEncoded node: ASN1Node) throws {
        self = try DER.sequence(node, identifier: .sequence) { nodes in
            let ukiDigest: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 0,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let ovmfDigest: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 1,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let nvidiaDriver: NvidiaGPUMeasurement? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 2,
                tagClass: .contextSpecific
            ) { try NvidiaGPUMeasurement(derEncoded: $0) }

            let shimDigest: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 3,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let grubDigest: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 4,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let vmlinuzDigest: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 5,
                tagClass: .contextSpecific
            ) { try ASN1OctetString(derEncoded: $0) }

            let kernelCommandLine: ASN1UTF8String? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 6,
                tagClass: .contextSpecific
            ) { try ASN1UTF8String(derEncoded: $0) }

            return LinuxV1Measurements(
                ukiDigest: ukiDigest.map { Data($0.bytes) },
                ovmfDigest: ovmfDigest.map { Data($0.bytes) },
                nvidiaDriver: nvidiaDriver,
                shimDigest: shimDigest.map { Data($0.bytes) },
                grubDigest: grubDigest.map { Data($0.bytes) },
                vmlinuzDigest: vmlinuzDigest.map { Data($0.bytes) },
                kernelCommandLine: kernelCommandLine.map { String($0) }
            )
        }
    }
}
