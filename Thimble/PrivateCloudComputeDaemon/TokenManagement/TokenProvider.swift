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
//  TokenProvider.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import NetworkServiceProxy
import PrivateCloudCompute
import os.log

private let unreasonableDelay: Duration = .seconds(20)
private let logger = Logger(for: .tokenProvider)

enum PrivacyProxyError {
    static let domain = "privacyProxyErrorDomain"

    static let permissionDenied = 1001
    static let ipcFailed = 1002
    static let invalidUserTier = 1003
    static let invalidParam = 1004
    static let invalidConfigData = 1005
    static let invalidConfigDataSign = 1006
    static let serverFailure = 1007
    static let featureDisabled = 1008
    static let rateLimited = 1009
    static let invalidAuthentication = 1010
    static let invalidRequest = 1011
    static let networkFailure = 1012
    static let transparencyFailure = 1013
    static let invalidConfigDates = 1014
    static let tdmFailure = 1015
    static let invalidResponse = 1016
}

enum PrivacyProxyErrorReason: String {
    case malformedAuthToken = "MALFORMED_AUTH_TOKEN"
    case invalidTestOptions = "INVALID_TEST_OPTIONS"
    case missingBaaAuthentication = "MISSING_BAA_AUTHENTICATION"
    case invalidBaa = "INVALID_BAA"
    case deniedBaa = "DENIED_BAA"
    case missingTokenAuthentication = "MISSING_TOKEN_AUTHENTICATION"
    case invalidAuthToken = "INVALID_AUTH_TOKEN"
    case invalidAuthTokenKey = "INVALID_AUTH_TOKEN_KEY"
    case requiresFraudScoreUpdate = "REQUIRES_FRAUD_SCORE_UPDATE"
    case unableToDetermineHardware = "UNABLE_TO_DETERMINE_HARDWARE"
    case unsupportedHardware = "UNSUPPORTED_HARDWARE"
    case missingSubscriptionToken = "MISSING_SUBSCRIPTION_TOKEN"
    case incorrectSubscriptionToken = "INCORRECT_SUBSCRIPTION_TOKEN"
    case subscriptionTokenDeviceIdMismatch = "SUBSCRIPTION_TOKEN_DEVICE_ID_MISMATCH"
    case revokedAuthToken = "REVOKED_AUTH_TOKEN"
    case invalidSubscriptionToken = "INVALID_SUBSCRIPTION_TOKEN"
    case expiredSubscriptionToken = "EXPIRED_SUBSCRIPTION_TOKEN"
    case subscriptionTokenFeatureEnablementStatusInactive = "SUBSCRIPTION_TOKEN_FEATURE_ENABLEMENT_STATUS_INACTIVE"
    case concurrentResourceModification = "CONCURRENT_RESOURCE_MODIFICATION"
    case invalidReputation = "INVALID_REPUTATION"
    case internalServerErrorCassandra = "INTERNAL_SERVER_ERROR_CASSANDRA"
    case internalServerErrorFeatureEnablementStatusCheck = "INTERNAL_SERVER_ERROR_FEATURE_ENABLEMENT_STATUS_CHECK"
    case internalServerErrorSubscriptionToken = "INTERNAL_SERVER_ERROR_SUBSCRIPTION_TOKEN"
}

@available(iOS 18, *)
final class TokenProvider<
    PrivateAccessTokenFetcher: PrivateAccessTokenFetcherWrapperProtocol & Sendable
>: TokenProviderProtocol, OneTimeTokenProviderProtocol, ReputationTokenProviderProtocol, WaitlistTokenProviderProtocol, Sendable {
    private let logPrefix: String
    private let fetcher: PrivateAccessTokenFetcher

    init(
        logPrefix: String,
        fetcher: PrivateAccessTokenFetcher,
    ) {
        self.logPrefix = logPrefix
        self.fetcher = fetcher
    }

    func fetchToken() async throws(TrustedRequestError) -> Data {
        do {
            return try await self.fetch()
        } catch {
            throw self.translateError(error: error)
        }
    }

    func prewarm() async throws(TrustedRequestError) {
        do {
            return try await self.fetchAndSave()
        } catch {
            throw self.translateError(error: error)
        }
    }

    func save(costToken: Data) {
        logger.log("\(self.logPrefix) saving cost token, size=\(costToken.count)")
        self.fetcher.saveToCache(
            auxiliaryAuthenticationData: costToken,
            type: .costJWT,
            label: "pcc-cost-token"
        )
    }

    func generateTokenRequest() async throws(TrustedRequestError) -> Data {
        do {
            return try await logger.logLifetime("generate reputation token request", logPrefix: self.logPrefix) {
                try await fetcher.generateTokenRequest()
            }
        } catch {
            throw self.translateError(error: error)
        }
    }

    func save(tokenResponse: Data) async throws(TrustedRequestError) {
        do {
            try await logger.logLifetime("save reputation token response", logPrefix: self.logPrefix) {
                let token = try await fetcher.handleTokenResponse(tokenResponse)
                await fetcher.saveToCache(token: token)
            }
        } catch {
            throw self.translateError(error: error)
        }
    }

    private func translateError(error: any Error) -> TrustedRequestError {
        let nsError = error as NSError
        guard nsError.domain == PrivacyProxyError.domain else {
            return TrustedRequestError(code: .privacyProxyFailed, underlying: [error])
        }
        let code: TrustedRequestError.Code =
            switch nsError.code {
            case PrivacyProxyError.permissionDenied: .privacyProxyPermissionDenied
            case PrivacyProxyError.ipcFailed: .privacyProxyIpcFailed
            case PrivacyProxyError.invalidUserTier: .privacyProxyInvalidUserTier
            case PrivacyProxyError.invalidParam: .privacyProxyInvalidParam
            case PrivacyProxyError.invalidConfigData: .privacyProxyInvalidConfigData
            case PrivacyProxyError.invalidConfigDataSign: .privacyProxyInvalidConfigDataSign
            case PrivacyProxyError.serverFailure: .privacyProxyServerFailure
            case PrivacyProxyError.featureDisabled: .privacyProxyFeatureDisabled
            case PrivacyProxyError.rateLimited: .privacyProxyRateLimited
            case PrivacyProxyError.invalidAuthentication: .privacyProxyInvalidAuthentication
            case PrivacyProxyError.invalidRequest: .privacyProxyInvalidRequest
            case PrivacyProxyError.networkFailure: .privacyProxyNetworkFailure
            case PrivacyProxyError.transparencyFailure: .privacyProxyTransparencyFailure
            case PrivacyProxyError.invalidConfigDates: .privacyProxyInvalidConfigDates
            case PrivacyProxyError.tdmFailure: .privacyProxyTDMFailure
            case PrivacyProxyError.invalidResponse: .privacyProxyInvalidResponse
            default: .privacyProxyFailed
            }
        let rawErrorReason = nsError.userInfo["NSPServerErrorReason"] as? String
        let errorReason = rawErrorReason.flatMap(PrivacyProxyErrorReason.init(rawValue:))
        return TrustedRequestError(code: code, errorReason: errorReason, underlying: [error])
    }

    private func fetch() async throws -> Data {
        logger.log("\(self.logPrefix) fetching token")
        do {
            let token =
                try await withDelayAction(duration: unreasonableDelay) {
                    try await withUnstructuredTaskAndLeakyTaskCancellation {
                        let token = try await self.fetcher.fetchToken()
                        logger.log("\(self.logPrefix) fetched token=\(token)")
                        return token
                    }
                } onDelay: {
                    logger.error("\(self.logPrefix) latency issue: token fetch is taking longer than expected, delay=\(unreasonableDelay)")
                }
            return token
        } catch {
            logger.error("\(self.logPrefix) fetch failed with error=\(error)")
            throw error
        }
    }

    private func fetchAndSave() async throws {
        let token = try await fetch()

        logger.log("\(self.logPrefix) saving token")
        await fetcher.saveToCache(token: token)
        logger.log("\(self.logPrefix) saved token=\(token)")
    }
}
