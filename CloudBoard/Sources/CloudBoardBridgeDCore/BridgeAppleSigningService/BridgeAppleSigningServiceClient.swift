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

import AppleSigningServiceClient
import CloudBoardCommon
import CloudBoardIdentity
import CloudBoardLogging
import CloudBoardMetrics
internal import CloudBoardDomain
import Foundation
import os

final class BridgeAppleSigningServiceClient: BridgeAppleSigningServiceClientProtocol {
    static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "BridgeAppleSigningServiceClient"
    )

    static let tracingLogger = Logger(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "BridgeAppleSigningServiceClient"
    )
    let httpClient: AppleSigningServiceHTTPClientProtocol
    let accountID: String
    let keyID: String
    private let metricsSystem: MetricsSystem

    init(
        config: SecureConfig.BridgeDaemonConfig.AppleSigningServiceConfig,
        metricsSystem: MetricsSystem
    ) throws {
        self.accountID = config.accountID
        self.keyID = config.keyID
        self.metricsSystem = metricsSystem
        do {
            self.httpClient = try AppleSigningServiceHTTPClient(
                configuration: .init(
                    serviceURL: config.serviceURL,
                    allowInsecure: config.allowInsecure,
                    disableMTLS: config.disableMTLS,
                    attemptCount: config.attemptCount,
                    retryDelay: config.retryDelay,
                    httpRequestTimeout: config.httpRequestTimeout
                )
            )
        } catch {
            Self.logger.error("Error initializing BridgeAppleSigningService client\(error, privacy: .public)")
            throw error
        }
        Self.logger.info("BridgeAppleSigningService client initialized")
    }

    // For testing only
    internal init(
        accountID: String,
        keyID: String,
        httpClient: AppleSigningServiceHTTPClientProtocol,
        metricsSystem: MetricsSystem
    ) {
        self.accountID = accountID
        self.keyID = keyID
        self.httpClient = httpClient
        self.metricsSystem = metricsSystem
    }

    func updateCredentialProvider(identityManager: IdentityManager) async {
        Self.logger.info("Update appleSigningService client credential provider")
        await self.httpClient.updateCredentialProvider {
            identityManager.identity?.credential
        }
    }

    /// Signs the provided data with the specified key.
    func sign(
        request: AppleSigningServiceSignRequest,
        traceContext: AppleSigningServiceTraceContext,
        span: BridgeRequestSummaryTracer.Span
    ) async throws -> InternalAppleSigningServiceSignResponse {
        span.outboundCallRequestID = traceContext.requestID
        BridgeAppleSigningServiceClientCheckpoint(
            spanID: span.spanID,
            traceContext: traceContext,
            operationName: "apple_signing_service_sign_request_started",
            message: "Make appleSigningService sign request",
        ).log(to: Self.tracingLogger, level: .default)

        let callStart = ContinuousClock.now
        do {
            var context = request.operationContext ?? [:]
            context["traceID"] = traceContext.traceID.uuidString
            context["spanID"] = String(span.spanID)
            let response = try await self.httpClient.sign(
                accountId: self.accountID,
                keyId: self.keyID,
                request: .init(
                    payload: request.payload,
                    payloadType: .init(from: request.payloadType),
                    algorithm: .init(from: request.algorithm),
                    version: request.version,
                    operationContext: context
                )
            )
            BridgeAppleSigningServiceClientCheckpoint(
                spanID: span.spanID,
                traceContext: traceContext,
                operationName: "apple_signing_service_sign_request_succeeded",
                message: "AppleSigningService sign request succeeded",
            ).log(to: Self.tracingLogger, level: .default)
            self.emitMetrics(operation: .sign, result: .success, duration: ContinuousClock.now - callStart)
            return InternalAppleSigningServiceSignResponse(
                response: .init(
                    signature: response.signature,
                    certChain: response.certChain
                )
            )
        } catch let error as AppleSigningServiceHTTPClient.ClientError {
            BridgeAppleSigningServiceClientCheckpoint(
                spanID: span.spanID,
                traceContext: traceContext,
                operationName: "apple_signing_service_sign_request_failure",
                message: "Error making appleSigningService sign request",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            self.emitMetrics(operation: .sign, result: .failure, duration: ContinuousClock.now - callStart)
            throw InternalAppleSigningServiceErrorResponse(
                error: AppleSigningServiceError.failure(.init(from: error))
            )
        } catch {
            BridgeAppleSigningServiceClientCheckpoint(
                spanID: span.spanID,
                traceContext: traceContext,
                operationName: "apple_signing_service_sign_request_unexpected_error",
                message: "Error making appleSigningService sign request",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            self.emitMetrics(operation: .sign, result: .unexpectedError, duration: ContinuousClock.now - callStart)
            throw InternalAppleSigningServiceErrorResponse(
                error: AppleSigningServiceError.unexpectedError
            )
        }
    }

    /// Gets the underlying key versions for a specified signing key.
    func getKeyVersions(
        traceContext: AppleSigningServiceTraceContext,
        span: BridgeRequestSummaryTracer.Span
    ) async throws -> InternalAppleSigningServiceGetKeyVersionsResponse {
        span.outboundCallRequestID = traceContext.requestID
        BridgeAppleSigningServiceClientCheckpoint(
            spanID: span.spanID,
            traceContext: traceContext,
            operationName: "apple_signing_service_get_key_versions_request_started",
            message: "Make appleSigningService getKeyVersions request",
        ).log(to: Self.tracingLogger, level: .default)

        let callStart = ContinuousClock.now
        do {
            let response = try await self.httpClient.getKeyVersions(
                accountId: self.accountID,
                keyId: self.keyID
            )

            BridgeAppleSigningServiceClientCheckpoint(
                spanID: span.spanID,
                traceContext: traceContext,
                operationName: "apple_signing_service_get_key_versions_request_succeeded",
                message: "AppleSigningService getKeyVersions request succeeded",
            ).log(to: Self.tracingLogger, level: .default)
            self.emitMetrics(
                operation: .getKeyVersions,
                result: .success,
                duration: ContinuousClock.now - callStart
            )
            return InternalAppleSigningServiceGetKeyVersionsResponse(
                response: .init(versions: response.versions.map { .init(from: $0) })
            )
        } catch let error as AppleSigningServiceHTTPClient.ClientError {
            BridgeAppleSigningServiceClientCheckpoint(
                spanID: span.spanID,
                traceContext: traceContext,
                operationName: "apple_signing_service_get_key_versions_request_failure",
                message: "Error making appleSigningService getKeyVersions request",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            self.emitMetrics(
                operation: .getKeyVersions,
                result: .failure,
                duration: ContinuousClock.now - callStart
            )
            throw InternalAppleSigningServiceErrorResponse(
                error: AppleSigningServiceError.failure(.init(from: error))
            )
        } catch {
            BridgeAppleSigningServiceClientCheckpoint(
                spanID: span.spanID,
                traceContext: traceContext,
                operationName: "apple_signing_service_get_key_versions_request_unexpected_error",
                message: "Error making appleSigningService getKeyVersions request",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            self.emitMetrics(
                operation: .getKeyVersions,
                result: .unexpectedError,
                duration: ContinuousClock.now - callStart
            )
            throw InternalAppleSigningServiceErrorResponse(
                error: AppleSigningServiceError.unexpectedError
            )
        }
    }

    private func emitMetrics(
        operation: Metrics.AppleSigningService.OperationName,
        result: Metrics.AppleSigningService.ResultValue,
        duration: Duration
    ) {
        self.metricsSystem.emit(
            Metrics.AppleSigningService.TotalCounter(
                action: .increment(by: 1),
                result: result,
                operation: operation
            )
        )
        self.metricsSystem.emit(
            Metrics.AppleSigningService.DurationHistogram(
                duration: duration,
                result: result,
                operation: operation
            )
        )
    }
}

extension PayloadType {
    init(from: AppleSigningServiceSignPayloadType) {
        switch from {
        case .digest:
            self = .digest
        }
    }
}

extension SignatureAlgorithm {
    init(from: AppleSigningServiceSignAlgorithm) {
        switch from {
        case .mldsa87Rsa3072PssSha512Dr13:
            self = .mldsa87Rsa3072PssSha512Dr13
        }
    }
}

extension AppleSigningServiceKeyVersion {
    init(from version: KeyVersion) {
        self = .init(
            version: version.version,
            certChain: version.certChain
        )
    }
}

extension AppleSigningServiceProblemDetails {
    init(from error: AppleSigningServiceHTTPClient.ClientError) {
        switch error {
        case .undocumentedResponseHTTPCode(let code, let message):
            self = .init(code: code, title: message)
        case .signFailed(let code, let title, let detail, let instance):
            self = .init(code: code, title: title, detail: detail, instance: instance)
        case .getKeyVersionsFailed(let code, let title, let detail, let instance):
            self = .init(code: code, title: title, detail: detail, instance: instance)
        }
    }
}
