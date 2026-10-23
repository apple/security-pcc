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

import CloudBoardJobAuthDAPI
import CloudBoardLogging
import CryptoKit
import Foundation
import os
import Security
import Synchronization

enum CostTokenError: ReportableError {
    case signingFailed(Error)
    case encodingFailed(Error)
    case missingPatIssuer
    case utf8EncodingFailed
    case invalidPrivateKey(Error)

    var publicDescription: String {
        return switch self {
        case .signingFailed(let error): "costToken.signingFailed(\(String(reportable: error)))"
        case .encodingFailed(let error): "costToken.encodingFailed(\(String(reportable: error)))"
        case .missingPatIssuer: "costToken.missingPatIssuer"
        case .utf8EncodingFailed: "costToken.utf8EncodingFailed"
        case .invalidPrivateKey(let error): "costToken.invalidPrivateKey(\(String(reportable: error)))"
        }
    }
}

struct CostTokenJWTPayload: Codable {
    let versionNumber: Int32
    let iat: Int64
    let iss: String
    let patIssuer: String
    let bucketizedCostUnit: Int32

    enum CodingKeys: String, CodingKey {
        case versionNumber = "version_number"
        case iat
        case iss
        case patIssuer = "pat_issuer"
        case bucketizedCostUnit = "bucketized_cost_unit"
    }
}

final class CostTokenSigner: Sendable {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CostTokenSigner"
    )

    private struct SigningKeyMaterial {
        let privateKey: P256.Signing.PrivateKey
        let keyID: Data
    }

    private static let costTokenVersion: Int32 = 1
    private static let timeBucketSize: TimeInterval = 3600
    private static let hardcodedCost: Int32 =
        0 // Bucketized cost units required. This constiutes a single bucket
    private static let issuer: String = "CloudBoard"
    private let keyMaterial: Mutex<SigningKeyMaterial>

    init(costTokenSigningKey: CostTokenSigningKeyPair) throws {
        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(derRepresentation: costTokenSigningKey.privateKey)
        } catch {
            throw CostTokenError.invalidPrivateKey(error)
        }

        // Key ID is already computed from public key by cb_jobauthd
        self.keyMaterial = Mutex(SigningKeyMaterial(
            privateKey: privateKey,
            keyID: costTokenSigningKey.keyId
        ))
    }

    func setSigningKey(_ costTokenSigningKey: CostTokenSigningKeyPair) throws {
        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(derRepresentation: costTokenSigningKey.privateKey)
        } catch {
            Self.logger.error("""
            message=\("Failed to update cost token signing key: invalid private key", privacy: .public)
            error=\(String(reportable: error), privacy: .public)
            """)
            throw CostTokenError.invalidPrivateKey(error)
        }

        self.keyMaterial.withLock {
            $0 = SigningKeyMaterial(
                privateKey: privateKey,
                keyID: costTokenSigningKey.keyId
            )
        }

        Self.logger.info("""
        message=\("Cost token signing key updated successfully", privacy: .public)
        newKeyId=\(costTokenSigningKey.keyId.base64EncodedString(), privacy: .public)
        validStart=\(costTokenSigningKey.validStart, privacy: .public)
        validEnd=\(costTokenSigningKey.validEnd, privacy: .public)
        """)
    }

    func generateCostToken(patIssuer: String) throws -> Data {
        guard !patIssuer.isEmpty else {
            Self.logger.error("Cost token generation failed: patIssuer is empty")
            throw CostTokenError.missingPatIssuer
        }

        // Get current key material
        let (signingPrivateKey, signingKeyID) = self.keyMaterial.withLock { ($0.privateKey, $0.keyID) }

        Self.logger.info("""
        message=\("Generating cost token", privacy: .public)
        patIssuer=\(patIssuer, privacy: .public)
        keyId=\(signingKeyID.base64EncodedString(), privacy: .public)
        truncatedKeyId=\(signingKeyID.last.map { Int8(bitPattern: $0) } ?? -1, privacy: .public)
        """)

        let bucketizedTime = Self.bucketTimestamp(Date.now)

        let payload = CostTokenJWTPayload(
            versionNumber: Self.costTokenVersion,
            iat: bucketizedTime,
            iss: Self.issuer,
            patIssuer: patIssuer,
            bucketizedCostUnit: Self.hardcodedCost
        )

        let header: Data
        do {
            header = try Self.createJWTHeader(keyID: signingKeyID)
        } catch {
            throw CostTokenError.encodingFailed(error)
        }

        let payloadJSON: Data
        do {
            payloadJSON = try JSONEncoder().encode(payload)
        } catch {
            throw CostTokenError.encodingFailed(error)
        }

        let signingInput = [
            header.base64URLEncodedString(),
            payloadJSON.base64URLEncodedString(),
        ].joined(separator: ".")

        guard let signingInputData = signingInput.data(using: .utf8) else {
            throw CostTokenError.utf8EncodingFailed
        }

        let signature = try Self.signData(signingInputData, with: signingPrivateKey)

        let jwt = [
            header.base64URLEncodedString(),
            payloadJSON.base64URLEncodedString(),
            signature.base64URLEncodedString(),
        ].joined(separator: ".")

        guard let jwtData = jwt.data(using: .utf8) else {
            throw CostTokenError.utf8EncodingFailed
        }

        Self.logger.info("""
        message=\("Cost token generated successfully", privacy: .public)
        tokenSizeBytes=\(jwtData.count, privacy: .public)
        keyId=\(signingKeyID.base64EncodedString(), privacy: .public)
        """)

        return jwtData
    }

    // Rounds timestamp down to the nearest hour boundary
    private static func bucketTimestamp(_ date: Date) -> Int64 {
        let epochSeconds = Int64(date.timeIntervalSince1970)
        let bucketedSeconds = (epochSeconds / Int64(self.timeBucketSize)) * Int64(self.timeBucketSize)
        return bucketedSeconds
    }

    private static func createJWTHeader(keyID: Data) throws -> Data {
        let headerDict: [String: Any] = [
            "alg": "ES256", // ECDSA P-256 with SHA-256
            "typ": "JWT",
            "kid": keyID.base64URLEncodedString(),
        ]

        do {
            return try JSONSerialization.data(withJSONObject: headerDict)
        } catch {
            throw CostTokenError.encodingFailed(error)
        }
    }

    private static func signData(_ data: Data, with privateKey: P256.Signing.PrivateKey) throws -> Data {
        do {
            let signature = try privateKey.signature(for: data)
            // JWT ES256 requires raw R||S format (64 bytes: 32-byte R + 32-byte S)
            // CryptoKit's rawRepresentation provides exactly this format per RFC 7518
            return signature.rawRepresentation
        } catch {
            throw CostTokenError.signingFailed(error)
        }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        return self
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
