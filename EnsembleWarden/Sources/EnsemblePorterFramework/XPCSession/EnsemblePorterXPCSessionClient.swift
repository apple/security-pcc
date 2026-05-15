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
//  EnsemblePorterXPCSessionClient.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 10/08/2025.
//

package import CryptoKit
private import EnsemblePorterCommon
package import EnsembleWardenServer
package import Foundation
private import os
private import Synchronization
@_spi(SessionConnectionCompatibility) @preconcurrency private import XPC
private import XPCOverlay

/// XPC session-based client for EnsemblePorter communication.
///
/// This client uses direct XPC session communication to connect to the
/// EnsemblePorter daemon service, using the older school XPCSession technology..
package final class EnsemblePorterXPCSessionClient: EnsemblePorterClient, Sendable {

    private enum State: Sendable, CustomStringConvertible {
        case notConnected(String)
        case connected(XPCSession)
        case failed
        case closed

        var description: String {
            switch self {
            case .notConnected(_):
                "Not connected"
            case .connected(_):
                "Connected"
            case .failed:
                "Failed"
            case .closed:
                "Closed"
            }
        }

    }

    private static let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "EnsemblePorterXPCSessionClient")
    private let state: Mutex<State>

    package init(xpcServiceName: String = EnsemblePorterConstants.xpcKeyFetcherClientName) {
        self.state = .init(.notConnected(xpcServiceName))
    }

    package init(existingConnection: xpc_connection_t) throws {
        let session = try XPCSession(fromConnection: existingConnection) { error in
            // XPC error - safe to log.
            Self.logger.error("XPC session cancelled. error=\(error, privacy: .public)")
        }
        self.state = .init(.connected(session))
    }

    deinit {
        self.state.withLock { state in
            switch state {
            case .closed, .failed: break
            case .connected(let session):
                Self.logger.warning("EnsemblePorterXPCSessionClient was deinit'd without being shutdown.")
                session.cancel(reason: "stop")
            default:
                let stateDescription = state.description
                Self.logger.warning("Invalid state on deinit. state=\(stateDescription, privacy: .public)")
            }
        }
    }


    package func stop() async throws {
        self.state.withLock { state in
            switch state {
            case .connected(let session):
                session.cancel(reason: "stop")
                state = .closed
            case .notConnected(_), .closed:
                break
            case .failed:
                state = .closed
            }
        }
    }

    private func createXPCSession(serviceName: String) throws -> XPCSession {
        Self.logger.log("Creating XPC session. xpc_service_name=\(serviceName, privacy: .public)")

        return try XPCSession(machService: serviceName) { error in
            // Error straight from XPC so we can log
            Self.logger.log("XPC session cancelled. error=\(error, privacy: .public)")
            self.state.withLock { $0 = .failed }
        }
    }

    private func getSession() throws -> XPCSession {
        try self.state.withLock { state in
            switch state {
            case .notConnected(let serviceName):
                let session = try createXPCSession(serviceName: serviceName)
                state = .connected(session)
                return session
            case .connected(let session):
                return session
            case .failed:
                throw EnsemblePorterError.transportFailed
            case .closed: throw EnsemblePorterError.alreadyClosed
            }
        }
    }

    private func sendRequest<Req: EnsemblePorterXPCRequest & Sendable>(_ request: Req) async throws -> Req.Response {
        let session = try getSession()
        let xpcRequest: EnsemblePorterXPCAPI.Request

        switch request {
        case let provide as EnsemblePorterXPCAPI.Provide:
            xpcRequest = .provide(provide)
        case let fetch as EnsemblePorterXPCAPI.Fetch:
            xpcRequest = .fetch(fetch)
        case let getNumberOfTurnKeys as EnsemblePorterXPCAPI.GetNumberOfTurnKeys:
            xpcRequest = .getNumberOfTurnKeys(getNumberOfTurnKeys)
        case let fetchFollowerTokens as EnsemblePorterXPCAPI.FetchFollowerTokens:
            xpcRequest = .fetchFollowerTokens(fetchFollowerTokens)
        case let fetchFTETKey as EnsemblePorterXPCAPI.FetchFTETKey:
            xpcRequest = .fetchFTETKey(fetchFTETKey)
        case let getIntraEnsemblePublicKey as EnsemblePorterXPCAPI.GetIntraEnsemblePublicKey:
            xpcRequest = .getIntraEnsemblePublicKey(getIntraEnsemblePublicKey)
        case let provideEncryptedCryptoMaterial as EnsemblePorterXPCAPI.ProvideEncryptedCryptoMaterial:
            xpcRequest = .provideEncryptedCryptoMaterial(provideEncryptedCryptoMaterial)
        case let ftETOnlyTurn as EnsemblePorterXPCAPI.FTETOnlyTurn:
            xpcRequest = .ftETOnlyTurn(ftETOnlyTurn)
        default:
            throw EnsemblePorterError.unsupportedXPCRequestType
        }

        let requestID = PrismTracing.requestID
        let result = try await withCheckedThrowingContinuation { continuation in
            return PrismTracing.withSyncResumed(requestID: requestID) {
                do {
                    PrismTracing.logCheckpoint(name: "Sending XPC request")
                    try session.send(xpcRequest) { (xpcResponse: Result<EnsemblePorterXPCAPI.Response, Error>) in
                        PrismTracing.withSyncResumed(requestID: requestID) {
                            switch xpcResponse {
                            case .success(let response):
                                PrismTracing.logCheckpoint(name: "Decoding XPC success response")
                                switch response {
                                case .fetch(let fetchResponse): continuation.resume(returning: fetchResponse as! Req.Response)
                                case .provide(let provideResponse): continuation.resume(returning: provideResponse as! Req.Response)
                                case .getNumberOfTurnKeys(let getNumberOfTurnKeysResponse): continuation.resume(returning: getNumberOfTurnKeysResponse as! Req.Response)
                                case .fetchFollowerTokens(let tokensResponse): continuation.resume(returning: tokensResponse as! Req.Response)
                                case .fetchFTETKey(let ftETKeyResponse): continuation.resume(returning: ftETKeyResponse as! Req.Response)
                                case .getIntraEnsemblePublicKey(let publicKeyResponse): continuation.resume(returning: publicKeyResponse as! Req.Response)
                                case .provideEncryptedCryptoMaterial(let provideEncryptedResponse): continuation.resume(returning: provideEncryptedResponse as! Req.Response)
                                case .ftETOnlyTurn(let ftETOnlyTurnResponse): continuation.resume(returning: ftETOnlyTurnResponse as! Req.Response)
                                case .decodingError: continuation.resume(throwing: EnsemblePorterError.transportFailed)
                                }
                            case .failure(let error):
                                Self.logger.error("""
                                Received XPC error from XPC request. \
                                error=\(String(reportable: error), privacy: .public)
                                """)
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                } catch {
                    Self.logger.error("""
                    Error sending XPC message. \
                    error=\(String(describing: error), privacy: .public)
                    """)
                    continuation.resume(throwing: error)
                }
            }
        }
        PrismTracing.logCheckpoint(name: "Returning result of XPC call")
        return result
    }


    package func provide(additionalCryptoPayload: Data, requestID: UUID, spanID: UInt64) async throws {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            let request = EnsemblePorterXPCAPI.Provide(
                additionalCryptoPayload: additionalCryptoPayload,
                requestID: requestID,
                spanID: spanID
            )
            let response = try await sendRequest(request)

            switch response {
            case .success: return
            case .failure(let error): throw error
            }
        }
    }


    package func fetchFollowerTokens(requestID: UUID, spanID: UInt64) async throws -> FollowerTokens {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            let request = EnsemblePorterXPCAPI.FetchFollowerTokens(requestID: requestID, spanID: spanID)
            let response: EnsemblePorterXPCAPI.FetchFollowerTokens.Response
            do {
                response = try await sendRequest(request)
            } catch {
                Self.logger.error("""
                    Error fetching follower tokens. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID, privacy: .public)
                    """)
                throw error
            }

            switch response {
            case .success(let tokensResponse):
                return .init(dictionary: tokensResponse.tokens)
            case .failure(let error):
                Self.logger.error("""
                    Error fetching follower tokens. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID, privacy: .public)
                    """)
                throw error
            }
        }
    }

    package func fetchFTETKey(requestID: UUID, spanID: UInt64) async throws -> SymmetricKey {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            let request = EnsemblePorterXPCAPI.FetchFTETKey(requestID: requestID, spanID: spanID)
            let response: EnsemblePorterXPCAPI.FetchFTETKey.Response
            do {
                response = try await sendRequest(request)
            } catch {
                Self.logger.error("""
                    Error fetching FT/ET key. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID, privacy: .public)
                    """)
                throw error
            }

            switch response {
            case .success(let dataResponse):
                guard dataResponse.data.count == 32 else {
                    Self.logger.error("""
                        FT/ET key has invalid size. \
                        expected=32 \
                        actual=\(dataResponse.data.count, privacy: .public) \
                        request_id=\(requestID, privacy: .public) \
                        span_id=\(spanID, privacy: .public)
                        """)
                    throw EnsemblePorterError.invalidKeysSupplied
                }
                return SymmetricKey(data: dataResponse.data)
            case .failure(let error):
                Self.logger.error("""
                    Error fetching FT/ET key. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID, privacy: .public)
                    """)
                throw error
            }
        }
    }

    package func getIntraEnsemblePublicKey() async throws -> Data {
        let request = EnsemblePorterXPCAPI.GetIntraEnsemblePublicKey()
        let response: EnsemblePorterXPCAPI.GetIntraEnsemblePublicKey.Response
        do {
            response = try await sendRequest(request)
        } catch {
            Self.logger.error("""
                Error getting intra-ensemble public key. \
                error=\(String(reportable: error), privacy: .public) 
                """)
            throw error
        }

        switch response {
        case .success(let dataResponse):
            return dataResponse.data
        case .failure(let error):
            Self.logger.error("""
                Error getting intra-ensemble public key. \
                error=\(String(reportable: error), privacy: .public) 
                """)
            throw error
        }
    }

    package func provide(encryptedCryptoMaterial: Data, leaderPublicKey: Data, requestID: UUID, spanID: UInt64) async throws {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            PrismTracing.logCheckpoint(name: "Daemon provide encryptedCryptoMaterial")
            let request = EnsemblePorterXPCAPI.ProvideEncryptedCryptoMaterial(encryptedPayload: encryptedCryptoMaterial,
                                                                              leaderPublicKey: leaderPublicKey,
                                                                              requestID: requestID,
                                                                              spanID: spanID)
            let response: EnsemblePorterXPCAPI.ProvideEncryptedCryptoMaterial.Response
            do {
                response = try await sendRequest(request)
            } catch {
                Self.logger.error("""
                    Error providing encrypted crypto material. \
                    error=\(String(reportable: error), privacy: .public)
                    """)
                throw error
            }

            switch response {
            case .success:
                return
            case .failure(let error):
                Self.logger.error("""
                    Error providing encrypted crypto material. \
                    error=\(String(reportable: error), privacy: .public)
                    """)
                throw error
            }
        }
    }

    package func ftETOnlyTurn(requestID: UUID, spanID: UInt64) async throws {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            PrismTracing.logCheckpoint(name: "FTETOnlyTurn")
            let request = EnsemblePorterXPCAPI.FTETOnlyTurn(requestID: requestID,
                                                            spanID: spanID)
            let response: EnsemblePorterXPCAPI.FTETOnlyTurn.Response
            do {
                response = try await sendRequest(request)
            } catch {
                Self.logger.error("""
                    Error calling ftETOnlyTurn. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID, privacy: .public)
                    """)
                throw error
            }

            switch response {
            case .success:
                return
            case .failure(let error):
                Self.logger.error("""
                    Error calling ftETOnlyTurn. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(requestID, privacy: .public) \
                    span_id=\(spanID, privacy: .public)
                    """)
                throw error
            }
        }
    }
}
