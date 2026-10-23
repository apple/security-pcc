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
//  GCPv1DeviceIdentityManifest.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Crypto
import Foundation
import SwiftASN1

/// A device identity manifest that can be embedded in a platform certificate or hashed for binding.
public protocol DeviceIdentityManifest: Sendable {
    /// The DER-encoded representation of this manifest, suitable for embedding in an X.509 extension.
    var derRepresentation: Data { get throws }
    func digest<Hash: HashFunction>(using: Hash.Type) throws -> Hash.Digest
}

// MARK: - Digests
extension DeviceIdentityManifest {
    @inlinable
    public func digest<Hash: HashFunction>(using: Hash.Type = SHA384.self) throws -> Hash.Digest {
        return try Hash.hash(data: self.derRepresentation)
    }
}

/// A device identity manifest for GCPv1 attestation, DER-encoded per the ASN.1 schema in `CloudAttestation.asn`.
///
/// `derRepresentation` returns the bare SEQUENCE. When embedded in an X.509 extension, the SEQUENCE is
/// additionally wrapped in an OCTET STRING inside `extnValue` (so `extnValue` parses as
/// `OCTET STRING { OCTET STRING { GCPv1DeviceIdentityManifest } }`).
///
/// ```
/// GCPv1DeviceIdentityManifest ::= SEQUENCE {
///     type                 INTEGER(1),
///     googleIdentityDigest [0] OCTET STRING OPTIONAL,
///     intelIdentityDigest  [1] OCTET STRING OPTIONAL,
///     nvidiaIdentityDigest [2] SET OF OCTET STRING OPTIONAL
/// }
/// ```
public struct GCPv1DeviceIdentityManifest: Codable, Sendable, Hashable {
    private static let typeValue = 1

    /// SHA-384 digest of the Google identity certificate (Bowcaster; not yet available).
    public let googleIdentityDigest: Data?

    /// SHA-384 digest of the Intel PCK Certificate.
    public let intelIdentityDigest: Data?

    /// SHA-384 digests of the leaf certificates in each GPU's attestation certificate chain.
    /// Stored in DER SET OF canonical (lexicographic) order.
    public let nvidiaIdentityDigest: [Data]?

    public init(
        googleIdentityDigest: Data? = nil,
        intelIdentityDigest: Data? = nil,
        nvidiaIdentityDigest: [Data]? = nil
    ) {
        self.googleIdentityDigest = googleIdentityDigest
        self.intelIdentityDigest = intelIdentityDigest
        // Sort to match DER SET OF canonical lexicographic order.
        self.nvidiaIdentityDigest = nvidiaIdentityDigest?.sorted { $0.lexicographicallyPrecedes($1) }
    }
}

// MARK: - DeviceIdentityManifest Conformance

extension GCPv1DeviceIdentityManifest: DeviceIdentityManifest {}

// MARK: - DER Encoding

extension GCPv1DeviceIdentityManifest: DERSerializable {
    public func serialize(into coder: inout DER.Serializer) throws {
        try coder.appendConstructedNode(identifier: .sequence) { coder in
            try coder.serialize(Self.typeValue)

            if let googleDigest = googleIdentityDigest {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](googleDigest)[...]),
                    explicitlyTaggedWithTagNumber: 0,
                    tagClass: .contextSpecific
                )
            }

            if let intelDigest = intelIdentityDigest {
                try coder.serialize(
                    ASN1OctetString(contentBytes: [UInt8](intelDigest)[...]),
                    explicitlyTaggedWithTagNumber: 1,
                    tagClass: .contextSpecific
                )
            }

            if let nvidiaDigests = nvidiaIdentityDigest {
                try coder.serialize(
                    explicitlyTaggedWithTagNumber: 2,
                    tagClass: .contextSpecific
                ) { coder in
                    try coder.serializeSetOf(
                        nvidiaDigests.map { ASN1OctetString(contentBytes: [UInt8]($0)[...]) }
                    )
                }
            }
        }
    }
}

// MARK: - DER Decoding

extension GCPv1DeviceIdentityManifest: DERParseable {
    public init(derEncoded node: ASN1Node) throws {
        self = try DER.sequence(node, identifier: .sequence) { nodes in
            let typeValue = try Int(derEncoded: &nodes)
            guard typeValue == Self.typeValue else {
                throw ASN1Error.invalidASN1Object(reason: "unexpected GCPv1DeviceIdentityManifest type: \(typeValue)")
            }

            let googleDigest: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 0,
                tagClass: .contextSpecific
            ) { node in
                try ASN1OctetString(derEncoded: node)
            }

            let intelDigest: ASN1OctetString? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 1,
                tagClass: .contextSpecific
            ) { node in
                try ASN1OctetString(derEncoded: node)
            }

            let nvidiaDigests: [ASN1OctetString]? = try DER.optionalExplicitlyTagged(
                &nodes,
                tagNumber: 2,
                tagClass: .contextSpecific
            ) { node in
                try DER.set(of: ASN1OctetString.self, identifier: .set, rootNode: node)
            }

            return GCPv1DeviceIdentityManifest(
                googleIdentityDigest: googleDigest.map { Data($0.bytes) },
                intelIdentityDigest: intelDigest.map { Data($0.bytes) },
                nvidiaIdentityDigest: nvidiaDigests.map { $0.map { Data($0.bytes) } }
            )
        }
    }
}
