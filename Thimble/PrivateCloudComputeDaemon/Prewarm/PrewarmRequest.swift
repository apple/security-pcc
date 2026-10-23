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
//  PrewarmRequest.swift
//  PrivateCloudCompute
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Network
import PrivateCloudCompute
import os.log

private let logger = Logger(for: .daemon)

struct PrewarmRequest<
    FeatureFlagChecker: PrivateCloudCompute.FeatureFlagCheckerProtocol,
    PrefetchRequestHandler: PrefetchRequestHandlerProtocol,
    TokenProviderFactory: TokenProviderFactoryProtocol,
    ServerDrivenConfiguration: ServerDrivenConfigurationProtocol,
    RateLimiter: RateLimiterProtocol
> {
    init(
        featureFlagChecker: FeatureFlagChecker,
        prefetchRequestHandler: PrefetchRequestHandler,
        tokenProviderFactory: TokenProviderFactory,
        serverDrivenConfig: ServerDrivenConfiguration,
        rateLimiter: RateLimiter
    ) {
        self.featureFlagChecker = featureFlagChecker
        self.prefetchRequestHandler = prefetchRequestHandler
        self.tokenProviderFactory = tokenProviderFactory
        self.serverDrivenConfig = serverDrivenConfig
        self.rateLimiter = rateLimiter
    }

    private let featureFlagChecker: FeatureFlagChecker
    private let prefetchRequestHandler: PrefetchRequestHandler
    private let tokenProviderFactory: TokenProviderFactory
    private let serverDrivenConfig: ServerDrivenConfiguration
    private let rateLimiter: RateLimiter

    /// Prepares the device for a request for the given workload. Does a few things:
    /// 1. prewarms token provider to make sure it has a cached token needed to later run the request for the given workload.
    /// 2. triggers attestation prefetch which will fetch attestations for the given workload if we don't have enough cached already.
    /// - Returns: JSON-encoded `Prefetch.Response` or `nil` if attestation prefetch fails.
    func run(
        now: Date = .now,
        workload: Workload,
        bundleIdentifier: BundleIdentifier,
        featureIdentifier: String,
        serviceClass: NWParameters.ServiceClass?
    ) async -> Data? {
        if shouldSkipDueToBlockedBundleId(bundleIdentifier: bundleIdentifier) {
            logger.warning("prewarm: skipping because bundleIdentifier is blocked, bundleIdentifier=\(bundleIdentifier.rawValue)")
            return nil
        }

        if await shouldSkipDueToRateLimit(now: now, workload: workload, bundleIdentifier: bundleIdentifier, featureIdentifier: featureIdentifier) {
            logger.warning("prewarm: skipping because of existing rate limit, bundleIdentifier=\(bundleIdentifier.rawValue), featureIdentifier=\(featureIdentifier)")
            return nil
        }

        // The token fetch prewarm is done simultaneously with the prefetch
        // of attestations. This is usually local and fast.
        async let tokenPrewarm: () = {
            if self.featureFlagChecker.isEnabled(.fetchAuthTokenOnPrewarm) {
                let tokenProvider = try self.tokenProviderFactory.oneTimeTokenProvider(
                    workloadType: workload.type,
                    featureIdentifier: featureIdentifier,
                    logPrefix: "prewarm: [ott]"
                )
                try await tokenProvider.prewarm()
            }
        }()

        async let reputationTokenPrewarm: () = {
            if self.featureFlagChecker.isEnabled(.reputationTokens) {
                let tokenProvider = try self.tokenProviderFactory.reputationTokenProvider(
                    workload: workload,
                    featureIdentifier: featureIdentifier,
                    logPrefix: "prewarm: [reputation]"
                )
                try await tokenProvider?.prewarm()
            }
        }()

        async let waitlistTokenPrewarm: () = {
            if self.featureFlagChecker.isEnabled(.waitlistTokens) {
                let tokenProvider = self.tokenProviderFactory.waitlistTokenProvider(
                    logPrefix: "prewarm: [waitlist]"
                )
                try await tokenProvider?.prewarm()
            }
        }()

        let result = await self.prefetchRequestHandler.run(
            workload: workload,
            prewarm: true,
            fetchType: .fetchAllBatches,
            bundleIdentifier: bundleIdentifier,
            featureIdentifier: featureIdentifier,
            serviceClass: serviceClass
        )

        do {
            _ = try await tokenPrewarm
        } catch {
            logger.error("prewarm: [ott] token fetch failed, error=\(error)")
        }

        do {
            _ = try await reputationTokenPrewarm
        } catch {
            logger.error("prewarm: [reputation] token fetch failed, error=\(error)")
        }

        do {
            _ = try await waitlistTokenPrewarm
        } catch {
            logger.error("prewarm: [waitlist] token fetch failed, error=\(error)")
        }

        return result
    }

    private func shouldSkipDueToBlockedBundleId(bundleIdentifier: BundleIdentifier) -> Bool {
        self.serverDrivenConfig.blockedBundleIds.contains(bundleIdentifier.rawValue)
    }

    private func shouldSkipDueToRateLimit(
        now: Date,
        workload: Workload,
        bundleIdentifier: BundleIdentifier,
        featureIdentifier: String
    ) async -> Bool {
        let requestMetadata = RateLimiterRequestMetadata(
            bundleID: bundleIdentifier.rawValue,
            featureID: featureIdentifier,
            qos: .high,
            workloadType: workload.type,
            workloadTags: workload.parameters
        )
        guard
            let denialInfo = await self.rateLimiter.rateLimitDenialInfo(
                now: now,
                for: requestMetadata,
                sessionID: nil
            )
        else {
            // no rate limit for such workload
            return false
        }

        logger.log("prewarm: found a matching rate limit, denialInfo=\(String(describing: denialInfo))")
        // If we get, the `denialInfo` here, it means a request for the given parameters at
        // the exact same time would have failed. But it doesn't mean we have to disallow
        // prewarm. Maybe the rate limit is as such that a request would succeed a little bit
        // later. So running prewarm should be fine then. However, if the rate limit is such
        // that no requests allowed at all (count == 0), only then we want to skip the prewarm.
        if denialInfo.deniesAllRequests {
            return true
        }
        return false
    }
}
