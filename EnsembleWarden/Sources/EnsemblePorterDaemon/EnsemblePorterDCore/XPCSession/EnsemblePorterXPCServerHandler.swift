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
            self.logic.metrics.incrementEntitlementValidation(entitlement: entitlement, success: false, failureType: .secTask)
            logger.error("Unable to create secTask from auditToken")
            throw EnsemblePorterError.entitlementCheckFailed
        }

        var error: Unmanaged<CFError>?
        let entitlementValue = SecTaskCopyValueForEntitlement(secTask, entitlement as CFString, &error)

        if let error {
            self.logic.metrics.incrementEntitlementValidation(entitlement: entitlement, success: false, failureType: .secTaskCopyError)
            logger.error("Error checking entitlement. error=\(error.takeRetainedValue(), privacy: .public)")
            throw EnsemblePorterError.entitlementCheckFailed
        }

        // All entitlements gated by this validator are boolean: a value of `<false/>` or any
        // non-boolean type must be rejected, not silently accepted as "present".
        guard let entitlementValue, CFEqual(entitlementValue, kCFBooleanTrue) else {
            self.logic.metrics.incrementEntitlementValidation(entitlement: entitlement, success: false, failureType: .missingOrWrongValue)
            logger.error("Missing entitlement. missing_entitlement=\(entitlement, privacy: .public)")
            throw EnsemblePorterError.missingEntitlement(entitlement)
        }

        self.logic.metrics.incrementEntitlementValidation(entitlement: entitlement, success: true, failureType: .none)
    }

    /// Records the duration + outcome of an XPC handler. Call from a `defer` so it fires on every
    /// path (including ones that map errors to Response cases).
    private func recordXPC(operation: EnsemblePorterMetrics.XPCOperation, start: ContinuousClock.Instant, response: EnsemblePorterXPCAPI.Response) {
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let success: Bool
        let errorCategory: String?
        switch response.metricsOutcome {
        case .success:
            success = true
            errorCategory = nil
        case .failure(let error):
            success = false
            errorCategory = error?.metricsLabel ?? "other"
        }
        self.logic.metrics.recordXPCRequest(operation: operation, success: success, errorCategory: errorCategory, durationSeconds: seconds)
    }

    private func handleProvide(_ request: EnsemblePorterXPCAPI.Provide, auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        let start = ContinuousClock.now
        var response: EnsemblePorterXPCAPI.Response = .provide(.failure(.unexpectedError))
        defer { self.recordXPC(operation: EnsemblePorterMetrics.XPCOperation.provide, start: start, response: response) }
        do {
            try self.validate(entitlement: EnsemblePorterConstants.provideKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            response = .provide(.failure(error))
            return response
        } catch {
            response = .provide(.failure(.unexpectedError))
            return response
        }

        response = await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
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
        return response
    }

    private func handleFetch(_ request: EnsemblePorterXPCAPI.Fetch, auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        let start = ContinuousClock.now
        var response: EnsemblePorterXPCAPI.Response = .fetch(.failure(.unexpectedError))
        defer { self.recordXPC(operation: EnsemblePorterMetrics.XPCOperation.fetch, start: start, response: response) }
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            response = .fetch(.failure(error))
            return response
        } catch {
            response = .fetch(.failure(.unexpectedError))
            return response
        }

        response = await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            do {
                PrismTracing.logCheckpoint(name: "FetchTurnKey", level: .debug)
                let data = try logic.fetch(turnNumber: request.turnNumber)
                return .fetch(.success(.init(data: data)))
            } catch let error as EnsemblePorterError {
                return .fetch(.failure(error))
            } catch {
                return .fetch(.failure(.unexpectedError))
            }
        }
        return response
    }

    private func handleGetNumberOfTurnKeys(_ request: EnsemblePorterXPCAPI.GetNumberOfTurnKeys, auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        let start = ContinuousClock.now
        var response: EnsemblePorterXPCAPI.Response = .getNumberOfTurnKeys(.failure(.unexpectedError))
        defer { self.recordXPC(operation: EnsemblePorterMetrics.XPCOperation.getNumberOfTurnKeys, start: start, response: response) }
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            response = .getNumberOfTurnKeys(.failure(error))
            return response
        } catch {
            response = .getNumberOfTurnKeys(.failure(.unexpectedError))
            return response
        }

        response = await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            do {
                PrismTracing.logCheckpoint(name: "getNumberOfTurnKeys", level: .debug)
                let count = try logic.getNumberOfTurnKeys()
                return .getNumberOfTurnKeys(.success(.init(count: count)))
            } catch let error as EnsemblePorterError {
                return .getNumberOfTurnKeys(.failure(error))
            } catch {
                return .getNumberOfTurnKeys(.failure(.unexpectedError))
            }
        }
        return response
    }

    private func handleFetchFollowerTokens(_ request: EnsemblePorterXPCAPI.FetchFollowerTokens,
                                           auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        let start = ContinuousClock.now
        var response: EnsemblePorterXPCAPI.Response = .fetchFollowerTokens(.failure(.unexpectedError))
        defer { self.recordXPC(operation: EnsemblePorterMetrics.XPCOperation.fetchFollowerTokens, start: start, response: response) }
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            response = .fetchFollowerTokens(.failure(error))
            return response
        } catch {
            response = .fetchFollowerTokens(.failure(.unexpectedError))
            return response
        }

        response = await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
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
        return response
    }

    private func handleFetchFTETKey(_ request: EnsemblePorterXPCAPI.FetchFTETKey,
                                    auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        let start = ContinuousClock.now
        var response: EnsemblePorterXPCAPI.Response = .fetchFTETKey(.failure(.unexpectedError))
        defer { self.recordXPC(operation: EnsemblePorterMetrics.XPCOperation.fetchFTETKey, start: start, response: response) }
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            response = .fetchFTETKey(.failure(error))
            return response
        } catch {
            response = .fetchFTETKey(.failure(.unexpectedError))
            return response
        }

        response = await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
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
        return response
    }

    private func handleGetIntraEnsemblePublicKey(_ request: EnsemblePorterXPCAPI.GetIntraEnsemblePublicKey,
                                                  auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        let start = ContinuousClock.now
        var response: EnsemblePorterXPCAPI.Response = .getIntraEnsemblePublicKey(.failure(.unexpectedError))
        defer { self.recordXPC(operation: EnsemblePorterMetrics.XPCOperation.getIntraEnsemblePublicKey, start: start, response: response) }
        do {
            try self.validate(entitlement: EnsemblePorterConstants.getPublicKeyEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            response = .getIntraEnsemblePublicKey(.failure(error))
            return response
        } catch {
            response = .getIntraEnsemblePublicKey(.failure(.unexpectedError))
            return response
        }

        let publicKey = logic.getFollowerIntraEnsemblePublicKey()
        response = .getIntraEnsemblePublicKey(.success(.init(data: publicKey.rawRepresentation)))
        return response
    }

    private func handleProvideEncryptedCryptoMaterial(_ request: EnsemblePorterXPCAPI.ProvideEncryptedCryptoMaterial,
                                                       auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        let start = ContinuousClock.now
        var response: EnsemblePorterXPCAPI.Response = .provideEncryptedCryptoMaterial(.failure(.unexpectedError))
        defer { self.recordXPC(operation: EnsemblePorterMetrics.XPCOperation.provideEncryptedCryptoMaterial, start: start, response: response) }
        do {
            try self.validate(entitlement: EnsemblePorterConstants.provideEncryptedCryptoMaterialEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            response = .provideEncryptedCryptoMaterial(.failure(error))
            return response
        } catch {
            response = .provideEncryptedCryptoMaterial(.failure(.unexpectedError))
            return response
        }

        response = await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
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
        return response
    }

    private func handleFTETOnlyTurn(_ request: EnsemblePorterXPCAPI.FTETOnlyTurn,
                                    auditToken: audit_token_t) async -> EnsemblePorterXPCAPI.Response {
        let start = ContinuousClock.now
        var response: EnsemblePorterXPCAPI.Response = .ftETOnlyTurn(.failure(.unexpectedError))
        defer { self.recordXPC(operation: EnsemblePorterMetrics.XPCOperation.ftETOnlyTurn, start: start, response: response) }
        do {
            try self.validate(entitlement: EnsemblePorterConstants.fetchKeysEntitlement, auditToken: auditToken)
        } catch let error as EnsemblePorterError {
            response = .ftETOnlyTurn(.failure(error))
            return response
        } catch {
            response = .ftETOnlyTurn(.failure(.unexpectedError))
            return response
        }

        response = await PrismTracing.withResumed(requestID: request.requestID, spanID: request.spanID) {
            PrismTracing.logCheckpoint(name: "FTETOnlyTurn")
            await self.logic.ftETOnlyTurn()
            return .ftETOnlyTurn(.success(.init()))
        }
        return response
    }
}

extension EnsemblePorterXPCAPI.Response {
    fileprivate enum MetricsOutcome {
        case success
        case failure(EnsemblePorterError?)
    }

    /// Maps each Response variant to a coarse success/failure outcome with optional typed error
    /// so the metrics layer can emit a stable `error_category`.
    fileprivate var metricsOutcome: MetricsOutcome {
        switch self {
        case .provide(let r): return Self.outcome(r)
        case .fetch(let r): return Self.outcome(r)
        case .getNumberOfTurnKeys(let r): return Self.outcome(r)
        case .fetchFollowerTokens(let r): return Self.outcome(r)
        case .fetchFTETKey(let r): return Self.outcome(r)
        case .getIntraEnsemblePublicKey(let r): return Self.outcome(r)
        case .provideEncryptedCryptoMaterial(let r): return Self.outcome(r)
        case .ftETOnlyTurn(let r): return Self.outcome(r)
        case .decodingError: return .failure(nil)
        }
    }

    private static func outcome<S>(_ r: CodableResult<S, EnsemblePorterError>) -> MetricsOutcome {
        switch r {
        case .success: return .success
        case .failure(let error): return .failure(error)
        }
    }
}
