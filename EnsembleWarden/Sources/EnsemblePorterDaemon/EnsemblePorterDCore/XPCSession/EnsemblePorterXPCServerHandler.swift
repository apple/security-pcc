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
//  EnsemblePorterXPCServerHandler.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 10/08/2025.
//

private import CryptoKit
package import EnsemblePorterCommon
internal import EnsembleWardenServer
package import Foundation
private import os
@_spiOnly private import Security_Private.SecTaskPriv
@preconcurrency private import XPC

package final class EnsemblePorterXPCServerHandler<IntraEnsembleTransponder: EnsembleTransponder>: Sendable {

    private let logic: EnsemblePorterLogic<IntraEnsembleTransponder>
    private let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "XPCServerHandler")

    internal init(logic: EnsemblePorterLogic<IntraEnsembleTransponder>) {
        self.logic = logic
    }

    /// Dispatches all requests
    package func handleRequest(_ request: EnsemblePorterXPCAPI.Request, auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        switch request {
        case .provide(let provideRequest):
            return await handleProvide(provideRequest, auditToken: auditToken)
        case .fetch(let fetchRequest):
            return await handleFetch(fetchRequest, auditToken: auditToken)
        case .getNumberOfTurnKeys(let numberOfTurnKeysRequest):
            return await handleGetNumberOfTurnKeys(numberOfTurnKeysRequest, auditToken: auditToken)
        case .fetchFollowerTokens(let fetchTokensRequest):
            return await handleFetchFollowerTokens(fetchTokensRequest, auditToken: auditToken)
        case .fetchFTETKey(let fetchFTETKeyRequest):
            return await handleFetchFTETKey(fetchFTETKeyRequest, auditToken: auditToken)
        case .getIntraEnsemblePublicKey(let getKeyRequest):
            return await handleGetIntraEnsemblePublicKey(getKeyRequest, auditToken: auditToken)
        case .provideEncryptedCryptoMaterial(let provideEncryptedRequest):
            return await handleProvideEncryptedCryptoMaterial(provideEncryptedRequest, auditToken: auditToken)
        case .ftETOnlyTurn(let ftETOnlyTurnRequest):
            return await handleFTETOnlyTurn(ftETOnlyTurnRequest, auditToken: auditToken)
        }
    }

    private func validate(entitlement: String, auditToken: audit_token_t) throws {
        guard let secTask = SecTaskCreateWithAuditToken(nil, auditToken) else {
            logger.error("Unable to create secTask from auditToken")
            throw EnsemblePorterError.entitlementCheckFailed
        }

        var error: Unmanaged<CFError>?
        let entitlementValue = SecTaskCopyValueForEntitlement(secTask, entitlement as CFString, &error)

        if let error {
            logger.error("Error checking entitlement. error=\(error.takeRetainedValue(), privacy: .public)")
            throw EnsemblePorterError.entitlementCheckFailed
        } else if entitlementValue == nil {
            logger.error("Missing entitlement. missing_entitlement=\(entitlement, privacy: .public)")
            throw EnsemblePorterError.missingEntitlement(entitlement)
        }
    }

    private func handleProvide(_ request: EnsemblePorterXPCAPI.Provide, auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        do {
            try self.validate(entitlement: EnsemblePorterConstants.provideKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            return .provide(.failure(error))
        } catch {
            return .provide(.failure(.unexpectedError))
        }

        return await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            do {
                _ = try await logic.provide(additionalCryptoPayload: request.additionalCryptoPayload)
                return .provide(.success(.init()))
            } catch let error as EnsemblePorterError {
                logger.error("""
                    Error during provide keys request handling. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                return .provide(.failure(error))
            } catch {
                logger.error("""
                    Error during provide keys request handling. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                return .provide(.failure(.unexpectedError))
            }
        }
    }

    private func handleFetch(_ request: EnsemblePorterXPCAPI.Fetch, auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            return .fetch(.failure(error))
        } catch {
            return .fetch(.failure(.unexpectedError))
        }

        return await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            do {
                PrismTracing.logCheckpoint(name: "FetchTurnKey")
                let data = try logic.fetch(turnNumber: request.turnNumber)
                return .fetch(.success(.init(data: data)))
            } catch let error as EnsemblePorterError {
                return .fetch(.failure(error))
            } catch {
                return .fetch(.failure(.unexpectedError))
            }
        }
    }

    private func handleGetNumberOfTurnKeys(_ request: EnsemblePorterXPCAPI.GetNumberOfTurnKeys, auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            return .getNumberOfTurnKeys(.failure(error))
        } catch {
            return .getNumberOfTurnKeys(.failure(.unexpectedError))
        }

        return await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            do {
                PrismTracing.logCheckpoint(name: "getNumberOfTurnKeys")
                let count = try logic.getNumberOfTurnKeys()
                return .getNumberOfTurnKeys(.success(.init(count: count)))
            } catch let error as EnsemblePorterError {
                return .getNumberOfTurnKeys(.failure(error))
            } catch {
                return .getNumberOfTurnKeys(.failure(.unexpectedError))
            }
        }
    }

    private func handleFetchFollowerTokens(_ request: EnsemblePorterXPCAPI.FetchFollowerTokens,
                                           auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            return .fetchFollowerTokens(.failure(error))
        } catch {
            return .fetchFollowerTokens(.failure(.unexpectedError))
        }

        return await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            do {
                PrismTracing.logCheckpoint(name: "Fetching ensemblefollowerporter instance UUID")
                let tokens = try await logic.fetchEnsembleFollowerPorterInstanceUUIDs()
                return .fetchFollowerTokens(.success(.init(tokens: tokens.values)))
            } catch let error as EnsemblePorterError {
                return .fetchFollowerTokens(.failure(error))
            } catch {
                return .fetchFollowerTokens(.failure(.unexpectedError))
            }
        }
    }

    private func handleFetchFTETKey(_ request: EnsemblePorterXPCAPI.FetchFTETKey,
                                    auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            return .fetchFTETKey(.failure(error))
        } catch {
            return .fetchFTETKey(.failure(.unexpectedError))
        }

        return await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            do {
                PrismTracing.logCheckpoint(name: "FetchFTETKey")
                let key = try self.logic.keySafe.retrieveKey(turnNumber: Int.max)
                let data = key.withUnsafeBytes { Data($0) }
                return .fetchFTETKey(.success(.init(data: data)))
            } catch let error as EnsemblePorterError {
                self.logger.error("""
                    Error fetching FT/ET key. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                return .fetchFTETKey(.failure(error))
            } catch {
                self.logger.error("""
                    Error fetching FT/ET key. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                return .fetchFTETKey(.failure(.unexpectedError))
            }
        }
    }

    private func handleGetIntraEnsemblePublicKey(_ request: EnsemblePorterXPCAPI.GetIntraEnsemblePublicKey,
                                                  auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        do {
            try self.validate(entitlement: EnsemblePorterConstants.getPublicKeyEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            return .getIntraEnsemblePublicKey(.failure(error))
        } catch {
            return .getIntraEnsemblePublicKey(.failure(.unexpectedError))
        }

        let publicKey = logic.getFollowerIntraEnsemblePublicKey()
        return .getIntraEnsemblePublicKey(.success(.init(data: publicKey.rawRepresentation)))
    }

    private func handleProvideEncryptedCryptoMaterial(_ request: EnsemblePorterXPCAPI.ProvideEncryptedCryptoMaterial,
                                                       auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        do {
            try self.validate(entitlement: EnsemblePorterConstants.provideEncryptedCryptoMaterialEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            return .provideEncryptedCryptoMaterial(.failure(error))
        } catch {
            return .provideEncryptedCryptoMaterial(.failure(.unexpectedError))
        }

        return await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            do {
                _ = try await logic.provide(encryptedCryptoMaterial: request.encryptedPayload,
                                            leaderPublicKey: request.leaderPublicKey)
                return .provideEncryptedCryptoMaterial(.success(.init()))
            } catch let error as EnsemblePorterError {
                logger.error("Error during provide encrypted crypto material request handling. error=\(String(reportable: error), privacy: .public)")
                return .provideEncryptedCryptoMaterial(.failure(error))
            } catch {
                logger.error("Error during provide encrypted crypto material request handling. error=\(String(reportable: error), privacy: .public)")
                return .provideEncryptedCryptoMaterial(.failure(.unexpectedError))
            }
        }
    }

    private func handleFTETOnlyTurn(_ request: EnsemblePorterXPCAPI.FTETOnlyTurn,
                                    auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            return .ftETOnlyTurn(.failure(error))
        } catch {
            return .ftETOnlyTurn(.failure(.unexpectedError))
        }

        return await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            PrismTracing.logCheckpoint(name: "FTETOnlyTurn")
            await self.logic.ftETOnlyTurn()
            return .ftETOnlyTurn(.success(.init()))
        }
    }
}
