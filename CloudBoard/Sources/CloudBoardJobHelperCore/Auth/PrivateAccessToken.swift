// Copyright © 2025 Apple Inc. All Rights Reserved.

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

import CloudBoardLogging
import Foundation
import Security

enum PrivateAccessTokenError: ReportableError {
    case failedToValidateSignature(Error?)
    case insufficientBytesForTokenType
    case insufficientBytesForNonce
    case insufficientBytesForChallengeDigest
    case insufficientBytesForTokenKeyID
    case insufficientBytesForAuthenticator
    case signatureValidationNotImplemented(PrivateAccessToken.TokenType)
    case unknownTokenType(UInt16)

    var publicDescription: String {
        let errorType = switch self {
        case .failedToValidateSignature: "failedToValidateSignature"
        case .insufficientBytesForTokenType: "insufficientBytesForTokenType"
        case .insufficientBytesForNonce: "insufficientBytesForNonce"
        case .insufficientBytesForChallengeDigest: "insufficientBytesForChallengeDigest"
        case .insufficientBytesForTokenKeyID: "insufficientBytesForTokenKeyID"
        case .insufficientBytesForAuthenticator: "insufficientBytesForAuthenticator"
        case .signatureValidationNotImplemented(let tokenType): "signatureValidationNotImplemented(\(tokenType)"
        case .unknownTokenType: "unknownTokenType"
        }
        return "privateAccessToken.\(errorType)"
    }
}

/// Represents a Private Access Token/Privacy Pass Token as defined at
/// https://www.ietf.org/archive/id/draft-ietf-privacypass-auth-scheme-15.html#name-token-structure
struct PrivateAccessToken {
    /// 2-byte type of the token
    private(set) var tokenType: TokenType
    /// 32-byte client-generated random nonce
    private(set) var nonce: Data
    /// 32-byte SHA256 hash of the original token challenge
    private(set) var challengeDigest: Data
    /// Identifier for the authenticator key, length depends on token type
    private(set) var tokenKeyID: Data
    /// Signature computed over token type, nonce, challenge digest, and token key id
    private(set) var authenticator: Data

    init(_ data: Data) throws {
        var data = data
        self.tokenType = try data.popTokenType()
        self.nonce = try data.popNonce()
        self.challengeDigest = try data.popChallengeDigest()
        self.tokenKeyID = try data.popTokenKeyID(tokenType: self.tokenType)
        self.authenticator = try data.popAuthenticator(tokenType: self.tokenType)
    }
}

extension PrivateAccessToken {
    enum TokenType: UInt16 {
        /// VOPRF (P-384, SHA-384)
        /// https://datatracker.ietf.org/doc/html/draft-ietf-privacypass-protocol-16#name-token-type-voprf-p-384-sha-
        case publicMetadata = 0x0001
        /// Blind RSA (2084-bit)
        /// https://datatracker.ietf.org/doc/html/draft-ietf-privacypass-protocol-16#name-token-type-blind-rsa-2048-b
        case publiclyVerifiable = 0x0002
        /// Rate-Limited Blind RSA(SHA-384, 2048-bit) with ECDSA(P-384, SHA-384)
        /// https://www.ietf.org/archive/id/draft-ietf-privacypass-rate-limit-tokens-03.html#name-ecdsa-based-token-type
        case rateLimitedTokenECDSA = 0x0003
        /// Rate-Limited Blind RSA(SHA-384, 2048-bit) with Ed25519(SHA-512)
        /// https://www.ietf.org/archive/id/draft-ietf-privacypass-rate-limit-tokens-03.html#name-ed25519-based-token-type
        case rateLimitedTokenEd25519 = 0x0004

        var tokenKeyIDByteCount: Int {
            switch self {
            case .publicMetadata: 32
            case .publiclyVerifiable: 32
            case .rateLimitedTokenECDSA: 32
            case .rateLimitedTokenEd25519: 32
            }
        }

        var authenticatorByteCount: Int {
            return switch self {
            case .publicMetadata: 48
            case .publiclyVerifiable: 256
            case .rateLimitedTokenECDSA: 512
            case .rateLimitedTokenEd25519: 512
            }
        }

        private static let publicMetadataData = Data([0x00, 0x01])
        private static let publiclyVerifiableData = Data([0x00, 0x02])
        private static let rateLimitedTokenECDSAData = Data([0x00, 0x03])
        private static let rateLimitedTokenEd25519Data = Data([0x00, 0x04])

        var data: Data {
            return switch self {
            case .publicMetadata: Self.publicMetadataData
            case .publiclyVerifiable: Self.publiclyVerifiableData
            case .rateLimitedTokenECDSA: Self.rateLimitedTokenECDSAData
            case .rateLimitedTokenEd25519: Self.rateLimitedTokenEd25519Data
            }
        }
    }
}

extension PrivateAccessToken {
    var signedData: Data {
        var signedData = self.tokenType.data
        signedData.append(self.nonce)
        signedData.append(self.challengeDigest)
        signedData.append(self.tokenKeyID)
        return signedData
    }

    var data: Data {
        var data = self.tokenType.data
        data.append(self.nonce)
        data.append(self.challengeDigest)
        data.append(self.tokenKeyID)
        data.append(self.authenticator)
        return data
    }

    func validateSignature(signingKey: SecKey) throws {
        // For now we only support publiclyVerifiable-type tokens
        guard case .publiclyVerifiable = self.tokenType else {
            throw PrivateAccessTokenError.signatureValidationNotImplemented(self.tokenType)
        }

        var error: Unmanaged<CFError>?
        let signatureIsValid = SecKeyVerifySignature(
            signingKey,
            SecKeyAlgorithm.rsaSignatureMessagePSSSHA384,
            Data(self.signedData) as CFData,
            Data(self.authenticator) as CFData,
            &error
        )

        if !signatureIsValid {
            // error must be set if signature is invalid
            throw PrivateAccessTokenError.failedToValidateSignature(error?.takeRetainedValue() as Error?)
        }
    }
}

extension Data {
    fileprivate mutating func popTokenType() throws -> PrivateAccessToken.TokenType {
        guard self.count >= 2 else {
            throw PrivateAccessTokenError.insufficientBytesForTokenType
        }

        let tokenTypeRaw = UInt16(self[self.startIndex]) << 8 | UInt16(self[self.startIndex + 1])
        guard let tokenType = PrivateAccessToken.TokenType(rawValue: tokenTypeRaw) else {
            throw PrivateAccessTokenError.unknownTokenType(tokenTypeRaw)
        }
        self = self.dropFirst(2)
        return tokenType
    }

    fileprivate mutating func popNonce() throws -> Data {
        guard self.count >= 32 else {
            throw PrivateAccessTokenError.insufficientBytesForNonce
        }

        let nonce = self.prefix(32)
        self = self.dropFirst(32)
        return nonce
    }

    fileprivate mutating func popChallengeDigest() throws -> Data {
        guard self.count >= 32 else {
            throw PrivateAccessTokenError.insufficientBytesForChallengeDigest
        }

        let nonce = self.prefix(32)
        self = self.dropFirst(32)
        return nonce
    }

    fileprivate mutating func popTokenKeyID(tokenType: PrivateAccessToken.TokenType) throws -> Data {
        guard self.count >= tokenType.tokenKeyIDByteCount else {
            throw PrivateAccessTokenError.insufficientBytesForTokenKeyID
        }

        let nonce = self.prefix(tokenType.tokenKeyIDByteCount)
        self = self.dropFirst(tokenType.tokenKeyIDByteCount)
        return nonce
    }

    fileprivate mutating func popAuthenticator(tokenType: PrivateAccessToken.TokenType) throws -> Data {
        guard self.count >= tokenType.authenticatorByteCount else {
            throw PrivateAccessTokenError.insufficientBytesForAuthenticator
        }

        let nonce = self.prefix(tokenType.authenticatorByteCount)
        self = self.dropFirst(tokenType.authenticatorByteCount)
        return nonce
    }
}
