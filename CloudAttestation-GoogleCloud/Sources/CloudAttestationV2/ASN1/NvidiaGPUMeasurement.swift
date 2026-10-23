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

/// One NVIDIA GPU component (driver or VBIOS) as recorded in a release manifest. The same
/// shape is reused for both: the driver lives on ``LinuxV1Measurements/nvidiaDriver`` (loaded
/// by the workload OS image), and the VBIOS lives on ``GCPv1Platform/nvidiaGPU`` (platform
/// firmware).
///
/// ```
/// NvidiaGPUMeasurement ::= SEQUENCE {
///     product [0] UTF8String,
///     version [1] UTF8String,
///     blocks  [2] SEQUENCE OF NvidiaSPDMBlock
/// }
/// ```
public struct NvidiaGPUMeasurement: Sendable, Hashable, Codable {
    /// GPU product identifier (e.g. "GB100"). Driver SPDM digests are product-specific because
    /// NVIDIA publishes a separate driver RIM per `(product, version)`.
    public let product: String

    /// Component version string. Format depends on the component:
    /// - Driver: e.g. "590.48.01"
    /// - VBIOS:  e.g. "97.00.D9.00.35"
    public let version: String

    /// SPDM measurement blocks contributed by this component, sorted by index. Whether the
    /// entries belong to driver or VBIOS is determined by where the parent structure is stored
    /// and by ``driverSPDMIndices``.
    public let blocks: [NvidiaSPDMBlock]

    public init(
        product: String,
        version: String,
        blocks: [NvidiaSPDMBlock]
    ) {
        self.product = product
        self.version = version
        self.blocks = blocks.sorted { $0.index < $1.index }
    }

    /// SPDM measurement block indices that belong to the NVIDIA driver (Blackwell GB100).
    ///
    /// Verifiers don't have access to NVIDIA's RIMs at attestation time, so the driver/VBIOS
    /// split is encoded here. Indices not in this set (and not in ``excludedSPDMIndices``) are
    /// VBIOS-attributed.
    ///
    /// Source: union of `active` measurement indices in `NV_GPU_CC_DRIVER_GB100_*` RIMs
    /// (RIM 0-based indices 14, 40–63 → SPDM 1-based indices 15, 41–64).
    public static let driverSPDMIndices: Set<Int> = [
        15,
        41, 42, 43, 44, 45, 46, 47, 48, 49, 50,
        51, 52, 53, 54, 55, 56, 57, 58, 59, 60,
        61, 62, 63, 64,
    ]

    /// SPDM measurement block indices that should be omitted from releases regardless of
    /// driver/VBIOS classification. Currently:
    ///
    /// - **62**: Due to hardware binning, some GPUs don't emit this block, so attestations
    ///   are inconsistent across the population. Easier to drop it everywhere than to
    ///   maintain per-population release variants.
    public static let excludedSPDMIndices: Set<Int> = [62]
}

// MARK: - DER Encoding

extension NvidiaGPUMeasurement: DERSerializable {
    public func serialize(into coder: inout DER.Serializer) throws {
        try coder.appendConstructedNode(identifier: .sequence) { coder in
            try coder.serialize(
                ASN1UTF8String(self.product),
                explicitlyTaggedWithTagNumber: 0,
                tagClass: .contextSpecific
            )
            try coder.serialize(
                ASN1UTF8String(self.version),
                explicitlyTaggedWithTagNumber: 1,
                tagClass: .contextSpecific
            )
            try coder.serialize(
                explicitlyTaggedWithTagNumber: 2,
                tagClass: .contextSpecific
            ) { coder in
                try coder.serializeSequenceOf(self.blocks)
            }
        }
    }
}

// MARK: - DER Decoding

extension NvidiaGPUMeasurement: DERParseable {
    public init(derEncoded node: ASN1Node) throws {
        self = try DER.sequence(node, identifier: .sequence) { nodes in
            let product: ASN1UTF8String = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 0,
                tagClass: .contextSpecific
            ) { try ASN1UTF8String(derEncoded: $0) }

            let version: ASN1UTF8String = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 1,
                tagClass: .contextSpecific
            ) { try ASN1UTF8String(derEncoded: $0) }

            let blocks: [NvidiaSPDMBlock] = try DER.explicitlyTagged(
                &nodes,
                tagNumber: 2,
                tagClass: .contextSpecific
            ) { node in
                try DER.sequence(of: NvidiaSPDMBlock.self, identifier: .sequence, rootNode: node)
            }

            return NvidiaGPUMeasurement(
                product: String(product),
                version: String(version),
                blocks: blocks
            )
        }
    }
}
