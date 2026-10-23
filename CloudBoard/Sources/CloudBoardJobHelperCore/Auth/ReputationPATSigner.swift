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

import _CryptoExtras
import CloudBoardLogging
import CryptoKit
import Foundation
import os
import SwiftASN1

enum ReputationPATSignerError: ReportableError {
    case invalidPrivateKey(Error)
    case invalidKeyFormat
    case invalidTokenRequest
    case signingFailed(Error)

    var publicDescription: String {
        switch self {
        case .invalidPrivateKey(let error): "reputationPAT.invalidPrivateKey(\(String(reportable: error)))"
        case .invalidKeyFormat: "reputationPAT.invalidKeyFormat"
        case .invalidTokenRequest: "reputationPAT.invalidTokenRequest"
        case .signingFailed(let error): "reputationPAT.signingFailed(\(String(reportable: error)))"
        }
    }
}

struct ReputationPATSigner: Sendable {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ReputationPATSigner"
    )

    // SHA384 matches token_type 0x0002 (RSABSSA_SHA384_PSS_Randomized)
    private let privateKey: _RSA.BlindSigning.PrivateKey<SHA384>

    /// Accepts a PKCS#8 or PKCS#1 DER-encoded RSA private key.
    /// KRS provisions keys with the rsassaPss OID in the PKCS#8 AlgorithmIdentifier,
    /// which BoringSSL rejects — we detect and unwrap to PKCS#1 before parsing.
    init(derRepresentation: Data) throws {
        do {
            // If PKCS#8 wraps with rsassaPss OID, BoringSSL rejects it — unwrap to PKCS#1 first.
            let keyData = Self.unwrapIfRSASSAPSS(derRepresentation) ?? derRepresentation
            self.privateKey = try _RSA.BlindSigning.PrivateKey<SHA384>(derRepresentation: keyData)
        } catch {
            throw ReputationPATSignerError.invalidPrivateKey(error)
        }
    }

    /// Signs a Privacy Pass TokenRequest (RFC 9578) and returns the blind signature.
    /// TokenRequest layout: uint16 token_type | uint8 truncated_token_key_id | uint8[Nk] blinded_msg
    /// Returns: uint8[Nk] blind_sig
    func sign(_ tokenRequest: Data) throws -> Data {
        // Nk = RSA modulus size in bytes (256 for RSA-2048)
        let nk = self.privateKey.keySizeInBits / 8
        // RFC 9578: TokenRequest = uint16 token_type | uint8 truncated_token_key_id | uint8[Nk] blinded_msg
        guard tokenRequest.count == 3 + nk,
              // token_type 0x0002 = Blind RSA (2048-bit, SHA-384, PSS)
              tokenRequest[tokenRequest.startIndex] == 0x00,
              tokenRequest[tokenRequest.startIndex + 1] == 0x02 else {
            throw ReputationPATSignerError.invalidTokenRequest
        }
        // Strip the 3-byte header; remaining bytes are the client-blinded message
        let blindedMsg = Data(tokenRequest.dropFirst(3))
        do {
            // Raw RSA blind sign operation per RFC 9474 BlindSign
            let blindSignature = try self.privateKey.blindSignature(for: blindedMsg)
            Self.logger.info("message=\("Reputation PAT signed successfully", privacy: .public)")
            // Returns blind_sig; client unblinds to get the final PAT
            return blindSignature.rawRepresentation
        } catch {
            throw ReputationPATSignerError.signingFailed(error)
        }
    }

    // Returns inner PKCS#1 bytes if data is PKCS#8 with rsassaPss OID; nil for any other format.
    private static func unwrapIfRSASSAPSS(_ data: Data) -> Data? {
        // try? intentional: on parse failure or OID mismatch, return nil so the original bytes
        // reach BoringSSL, which surfaces the real error via .invalidPrivateKey.
        guard let pki = try? PrivateKeyInfo(derEncoded: data),
              pki.algorithmOID == .AlgorithmIdentifier.rsaPSS else { return nil }
        return pki.privateKeyBytes
    }

    // PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm AlgorithmIdentifier, privateKey OCTET STRING }
    private struct PrivateKeyInfo {
        let algorithmOID: ASN1ObjectIdentifier
        let privateKeyBytes: Data

        init(derEncoded data: Data) throws {
            let parsed = try DER.parse(Array(data))
            (self.algorithmOID, self.privateKeyBytes) = try DER.sequence(parsed, identifier: .sequence) { nodes in
                _ = try Int(derEncoded: &nodes) // advance past the version field
                guard let algIdNode = nodes.next() else {
                    throw ASN1Error.invalidASN1Object(reason: "missing AlgorithmIdentifier")
                }
                // AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters ANY OPTIONAL }
                // We only need the OID; remaining parameters (if any) are left unread.
                let oid = try DER.sequence(algIdNode, identifier: .sequence) { inner in
                    try ASN1ObjectIdentifier(derEncoded: &inner)
                }
                // privateKey OCTET STRING wraps the inner PKCS#1 key bytes from the PKCS#8 container
                let privateKeyBytes = try Data(ASN1OctetString(derEncoded: &nodes).bytes)
                return (oid, privateKeyBytes)
            }
        }
    }
}
