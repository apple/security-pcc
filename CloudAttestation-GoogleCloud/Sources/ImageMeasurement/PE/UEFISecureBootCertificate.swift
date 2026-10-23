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
//  UEFISecureBootCertificate.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import BinaryCoding
import Foundation
import SwiftASN1

extension PE {
    // OID for SpcIndirectDataContent: 1.3.6.1.4.1.311.2.1.4
    private static let spcIndirectDataOID: ASN1ObjectIdentifier = [1, 3, 6, 1, 4, 1, 311, 2, 1, 4]

    private static let winCertTypePKCS7: UInt16 = 0x0002
    private static let winCertRevision2: UInt16 = 0x0200

    struct UEFISecureBootCertificate: Sendable, Hashable {
        let bytes: ArraySlice<UInt8>

        /// Parses a WIN_CERTIFICATE structure from a PE certificate table
        init(certificateTable data: Data) throws {
            var slice = ArraySlice(data)
            let length = try slice.readUInt32()
            let revision = try slice.readUInt16()
            let certType = try slice.readUInt16()

            guard revision == winCertRevision2, certType == winCertTypePKCS7 else {
                throw ImageMeasurementError.invalidUEFISecureBootCertificate
            }

            let certDataLen = Int(length) - 8
            guard certDataLen > 0 else {
                throw ImageMeasurementError.invalidUEFISecureBootCertificate
            }

            self.bytes = try slice.readBytes(count: certDataLen)
        }

        var imageDigest: Data {
            get throws {
                // Parse PKCS7 SignedData to extract image digest
                let asn1Node = try DER.parse(bytes)
                return try Data(self.extractDigest(from: asn1Node))
            }
        }

        // ContentInfo ::= SEQUENCE { contentType, content [0] EXPLICIT }
        // SignedData ::= SEQUENCE { version, digestAlgorithms, encapContentInfo, ... }
        // EncapsulatedContentInfo ::= SEQUENCE { eContentType, eContent [0] EXPLICIT }
        // SpcIndirectDataContent ::= SEQUENCE { data, messageDigest DigestInfo }
        // DigestInfo ::= SEQUENCE { digestAlgorithm, digest OCTET STRING }
        private func extractDigest(from contentInfo: ASN1Node) throws -> [UInt8] {
            try DER.sequence(contentInfo, identifier: .sequence) { nodes in
                _ = try ASN1ObjectIdentifier(derEncoded: &nodes)

                guard let contentNode = nodes.next() else {
                    throw ImageMeasurementError.uefiSecureBootHashNotFound
                }

                let signedDataNode = try contentNode.firstChild(withIdentifier: .sequence)

                return try DER.sequence(signedDataNode, identifier: .sequence) { nodes in
                    // version - skip
                    guard nodes.next() != nil else { throw ImageMeasurementError.uefiSecureBootHashNotFound }
                    // digestAlgorithms - skip
                    guard nodes.next() != nil else { throw ImageMeasurementError.uefiSecureBootHashNotFound }
                    // encapContentInfo
                    guard let encapNode = nodes.next() else { throw ImageMeasurementError.uefiSecureBootHashNotFound }

                    let result = try DER.sequence(encapNode, identifier: .sequence) { nodes in
                        let oid = try ASN1ObjectIdentifier(derEncoded: &nodes)
                        guard oid == spcIndirectDataOID else { throw ImageMeasurementError.uefiSecureBootHashNotFound }

                        guard let contentNode = nodes.next() else { throw ImageMeasurementError.uefiSecureBootHashNotFound }
                        let spcNode = try contentNode.firstChild(withIdentifier: .sequence)

                        return try DER.sequence(spcNode, identifier: .sequence) { nodes in
                            // SpcAttributeTypeAndOptionalValue - skip
                            guard nodes.next() != nil else { throw ImageMeasurementError.uefiSecureBootHashNotFound }
                            // DigestInfo
                            guard let digestInfoNode = nodes.next() else { throw ImageMeasurementError.uefiSecureBootHashNotFound }

                            return try DER.sequence(digestInfoNode, identifier: .sequence) { nodes in
                                // AlgorithmIdentifier - skip
                                guard nodes.next() != nil else { throw ImageMeasurementError.uefiSecureBootHashNotFound }
                                // digest OCTET STRING
                                let octetString = try ASN1OctetString(derEncoded: &nodes)
                                return [UInt8](octetString.bytes)
                            }
                        }
                    }

                    // Drain remaining SignedData fields (certificates, crls, signerInfos)
                    while nodes.next() != nil {}
                    return result
                }
            }
        }
    }
}

extension ASN1Node {
    fileprivate func firstChild(withIdentifier identifier: ASN1Identifier) throws -> ASN1Node {
        guard case .constructed(let children) = content else {
            throw ImageMeasurementError.uefiSecureBootHashNotFound
        }
        for child in children {
            if child.identifier == identifier {
                return child
            }
        }
        throw ImageMeasurementError.uefiSecureBootHashNotFound
    }
}
