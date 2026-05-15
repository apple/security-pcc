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

//
//  EnsemblePorterXPCAPI.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 10/08/2025.
//

package import Foundation

package protocol EnsemblePorterXPCRequest: Codable {
    associatedtype Response: EnsemblePorterXPCResponse & Sendable
}

package protocol EnsemblePorterXPCResponse: Codable {}

extension CodableResult: EnsemblePorterXPCResponse where Success: EnsemblePorterXPCResponse, Failure == EnsemblePorterError {}

package enum EnsemblePorterXPCAPI {

    package struct Success: EnsemblePorterXPCResponse {
        package init() {}
    }

    package struct NumberOfTurnKeysResponse: EnsemblePorterXPCResponse {
        package let count: Int

        package init(count: Int) {
            self.count = count
        }
    }

    package struct DataResponse: EnsemblePorterXPCResponse {
        package let data: Data

        package init(data: Data) {
            self.data = data
        }
    }

    package struct FollowerTokensResponse: EnsemblePorterXPCResponse {
        package let tokens: [Int: UUID]

        package init(tokens: [Int: UUID]) {
            self.tokens = tokens
        }
    }

    package struct Provide: EnsemblePorterXPCRequest {
        package typealias Response = CodableResult<Success, EnsemblePorterError>

        package let additionalCryptoPayload: Data
        package let requestID: UUID
        package let spanID: UInt64

        package init(additionalCryptoPayload: Data, requestID: UUID, spanID: UInt64) {
            self.additionalCryptoPayload = additionalCryptoPayload
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    package struct Fetch: EnsemblePorterXPCRequest {
        package typealias Response = CodableResult<DataResponse, EnsemblePorterError>

        package let turnNumber: Int
        package let requestID: UUID
        package let spanID: UInt64

        package init(turnNumber: Int, requestID: UUID, spanID: UInt64) {
            self.turnNumber = turnNumber
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    package struct GetNumberOfTurnKeys: EnsemblePorterXPCRequest {
        package typealias Response = CodableResult<NumberOfTurnKeysResponse, EnsemblePorterError>

        package let requestID: UUID
        package let spanID: UInt64

        package init(requestID: UUID, spanID: UInt64) {
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    package struct FetchFollowerTokens: EnsemblePorterXPCRequest {
        package typealias Response = CodableResult<FollowerTokensResponse, EnsemblePorterError>

        package let requestID: UUID
        package let spanID: UInt64

        package init(requestID: UUID, spanID: UInt64) {
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    package struct FetchFTETKey: EnsemblePorterXPCRequest {
        package typealias Response = CodableResult<DataResponse, EnsemblePorterError>

        package let requestID: UUID
        package let spanID: UInt64

        package init(requestID: UUID, spanID: UInt64) {
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    package struct GetIntraEnsemblePublicKey: EnsemblePorterXPCRequest {
        package typealias Response = CodableResult<DataResponse, EnsemblePorterError>

        package init() {
        }
    }

    package struct ProvideEncryptedCryptoMaterial: EnsemblePorterXPCRequest {
        package typealias Response = CodableResult<Success, EnsemblePorterError>

        package let encryptedPayload: Data
        package let leaderPublicKey: Data
        package let requestID: UUID
        package let spanID: UInt64

        package init(encryptedPayload: Data, leaderPublicKey: Data, requestID: UUID, spanID: UInt64) {
            self.encryptedPayload = encryptedPayload
            self.leaderPublicKey = leaderPublicKey
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    /// Signals that this turn only uses the FT/ET key (no multi-turn keys from CloudBoard).
    /// The key supply is handled internally by EnsemblePorter's orchestration.
    package struct FTETOnlyTurn: EnsemblePorterXPCRequest {
        package typealias Response = CodableResult<Success, EnsemblePorterError>

        package let requestID: UUID
        package let spanID: UInt64

        package init(requestID: UUID, spanID: UInt64) {
            self.requestID = requestID
            self.spanID = spanID
        }
    }

    package enum Request: Codable {
        case provide(Provide)
        case fetch(Fetch)
        case getNumberOfTurnKeys(GetNumberOfTurnKeys)
        case fetchFollowerTokens(FetchFollowerTokens)
        case fetchFTETKey(FetchFTETKey)
        case getIntraEnsemblePublicKey(GetIntraEnsemblePublicKey)
        case provideEncryptedCryptoMaterial(ProvideEncryptedCryptoMaterial)
        case ftETOnlyTurn(FTETOnlyTurn)
    }

    package enum Response: Codable {
        case provide(Provide.Response)
        case fetch(Fetch.Response)
        case getNumberOfTurnKeys(GetNumberOfTurnKeys.Response)
        case fetchFollowerTokens(FetchFollowerTokens.Response)
        case fetchFTETKey(FetchFTETKey.Response)
        case getIntraEnsemblePublicKey(GetIntraEnsemblePublicKey.Response)
        case provideEncryptedCryptoMaterial(ProvideEncryptedCryptoMaterial.Response)
        case ftETOnlyTurn(FTETOnlyTurn.Response)
        case decodingError
    }
}
