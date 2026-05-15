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

import CloudBoardJobAuthDAPI
import CloudBoardLogging
import CryptoKit
import Foundation
import os
import Security

enum TokenGrantingTokenValidationError: ReportableError {
    case tgtSigningKeysUnavailable
    case tgtSigningKeysExpiredOrFutureValidityDate
    case tgtSigningKeysTokenKeyIDMismatch
    case invalidTGT(Error)
    case invalidTGTSignature(Error)
    case ottSigningKeysUnavailable
    case ottSigningKeysExpiredOrFutureValidityDate
    case ottSigningKeysTokenKeyIDMismatch
    case invalidOTT(Error)
    case invalidOTTSignature(Error)
    case mismatchingOTTNonce

    var publicDescription: String {
        let errorType = switch self {
        case .tgtSigningKeysUnavailable: "tgtSigningKeysUnavailable"
        case .tgtSigningKeysExpiredOrFutureValidityDate: "tgtSigningKeysExpiredOrFutureValidityDate"
        case .tgtSigningKeysTokenKeyIDMismatch: "tgtSigningKeysTokenKeyIDMismatch"
        case .invalidTGT(let error): "invalidTGT(\(String(reportable: error)))"
        case .invalidTGTSignature: "invalidTGTSignature"
        case .ottSigningKeysUnavailable: "ottSigningKeysUnavailable"
        case .ottSigningKeysExpiredOrFutureValidityDate: "ottSigningKeysExpiredOrFutureValidityDate"
        case .ottSigningKeysTokenKeyIDMismatch: "ottSigningKeysTokenKeyIDMismatch"
        case .invalidOTT(let error): "invalidOTT(\(String(reportable: error)))"
        case .invalidOTTSignature: "invalidOTTSignature"
        case .mismatchingOTTNonce: "mismatchingOTTNonce"
        }
        return "tokenGrantingTokenValidation.\(errorType)"
    }
}

protocol TokenGrantingTokenValidatorProtocol: Sendable {
    func setSigningKeys(_ signingKeys: AuthTokenKeySet)
    func validateTokenGrantingToken(_ tgtData: Data, ott ottData: Data, ottSalt: Data) throws
    /// This function exists for testing purposes only and allows us to validate the propagation of auth tokens across
    /// PCC nodes in integration tests
    func notifyOfUnvalidatedTokenGrantingToken(_ tgtData: Data, ottSalt: Data)
}

extension TokenGrantingTokenValidatorProtocol {
    func notifyOfUnvalidatedTokenGrantingToken(_: Data, ottSalt _: Data) {
        // Empty default implementation as only needed for testing purposes
    }
}

/// Validator for token granting tokens which verifies that TGTs are valid Private Access Tokens, are signed correctly,
/// and are related to the one-time token redeemed by ROPES for the current request.
final class TokenGrantingTokenValidator: TokenGrantingTokenValidatorProtocol {
    private enum TokenType {
        case ott
        case tgt
    }

    private let signingKeys: OSAllocatedUnfairLock<AuthTokenKeySet>

    init(signingKeys: AuthTokenKeySet) {
        self.signingKeys = .init(initialState: signingKeys)
    }

    func setSigningKeys(_ signingKeys: AuthTokenKeySet) {
        self.signingKeys.withLock {
            $0 = signingKeys
        }
    }

    func validateTokenGrantingToken(_ tgtData: Data, ott ottData: Data, ottSalt: Data) throws {
        let (tgtSigningPublicKeys, ottSigningPublicKeys) = self.signingKeys.withLock {
            return ($0.tgtPublicSigningKeys, $0.ottPublicSigningKeys)
        }

        let tgt: PrivateAccessToken
        do {
            tgt = try PrivateAccessToken(tgtData)
        } catch {
            throw TokenGrantingTokenValidationError.invalidTGT(error)
        }
        try self.validate(tgt, signedBy: tgtSigningPublicKeys, type: .tgt)

        let ott: PrivateAccessToken
        do {
            ott = try PrivateAccessToken(ottData)
        } catch {
            throw TokenGrantingTokenValidationError.invalidOTT(error)
        }
        try self.validate(ott, signedBy: ottSigningPublicKeys, type: .ott)

        try self.validateOttIsDerivedFromTGT(tgt: tgt, ott: ott, ottSalt: ottSalt)
    }

    // Validate Signing keys and signatures
    private func validate(
        _ token: PrivateAccessToken,
        signedBy signingPublicKeys: [SigningKey],
        type: TokenType
    ) throws {
        guard !signingPublicKeys.isEmpty else {
            switch type {
            case .ott:
                throw TokenGrantingTokenValidationError.ottSigningKeysUnavailable
            case .tgt:
                throw TokenGrantingTokenValidationError.tgtSigningKeysUnavailable
            }
        }
        let validSigningKeys = signingPublicKeys.filter { key in
            (key.validStart <= Date.now) && (Date.now < key.validEnd)
        }
        guard !validSigningKeys.isEmpty else {
            switch type {
            case .ott:
                throw TokenGrantingTokenValidationError.ottSigningKeysExpiredOrFutureValidityDate
            case .tgt:
                throw TokenGrantingTokenValidationError.tgtSigningKeysExpiredOrFutureValidityDate
            }
        }

        // Get the signing key of which its key Id matches the token key Id
        let finalSigningKey = validSigningKeys.first(where: { key in
            key.keyId == token.tokenKeyID
        })

        guard let finalSigningKey else {
            switch type {
            case .ott:
                throw TokenGrantingTokenValidationError.ottSigningKeysTokenKeyIDMismatch
            case .tgt:
                throw TokenGrantingTokenValidationError.tgtSigningKeysTokenKeyIDMismatch
            }
        }

        do {
            let signingSecKey = try SecKey.fromDEREncodedRSAPublicKey(finalSigningKey.rsaPublicKey)
            try token.validateSignature(signingKey: signingSecKey)
        } catch {
            switch type {
            case .ott:
                throw TokenGrantingTokenValidationError.invalidOTTSignature(error)
            case .tgt:
                throw TokenGrantingTokenValidationError.invalidTGTSignature(error)
            }
        }
    }

    /// Validates that the provided one-time token (OTT) is derived from the token-granting token allowing us to detect
    /// spoofed TGTs. By verifying that the one-time token has been derived from the provided TGT we can ensure that
    /// the TGT was valid at the time of OTT issuance.
    private func validateOttIsDerivedFromTGT(tgt: PrivateAccessToken, ott: PrivateAccessToken, ottSalt: Data) throws {
        var input = tgt.data
        input.append(ottSalt)
        let expectedOTTNonce = Data(SHA256.hash(data: input))
        guard ott.nonce == expectedOTTNonce else {
            throw TokenGrantingTokenValidationError.mismatchingOTTNonce
        }
    }
}
