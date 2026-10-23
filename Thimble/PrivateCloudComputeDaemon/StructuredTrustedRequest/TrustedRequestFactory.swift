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
//  TrustedRequestFactory.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CloudAttestation
private import DarwinPrivate.os.variant
import Foundation
import Network
import PrivateCloudCompute
import os.log

private let logger = Logger(for: .daemon)

typealias ThimbledTrustedRequestFactory = TrustedRequestFactory<
    DefaultConfiguration,
    NWAsyncConnection,
    LegacyAttestationStore,
    DeferredAttestationStore,
    AttestationVerifier<FeatureFlagChecker, CloudAttestation.MuxValidator>,
    DeferredRateLimiter,
    ServerDrivenConfiguration,
    SystemInfo,
    OSEligibility,
    DeviceState,
    TokenProviderFactory<DefaultConfiguration, FeatureFlagChecker, ServerDrivenConfiguration, SystemInfo>,
    FeatureFlagChecker,
    ContinuousClock
>

final class TrustedRequestFactory<
    Configuration: PrivateCloudCompute.Configuration,
    ConnectionFactory: NWAsyncConnectionFactoryProtocol,
    LegacyAttestationStore: LegacyAttestationStoreProtocol,
    AttestationStore: AttestationStoreProtocol,
    AttestationVerifier: AttestationVerifierProtocol,
    RateLimiter: RateLimiterProtocol,
    ServerDrivenConfiguration: ServerDrivenConfigurationProtocol,
    SystemInfo: SystemInfoProtocol,
    OSEligibility: OSEligibilityProtocol,
    DeviceState: DeviceStateProtocol,
    TokenProviderFactory: TokenProviderFactoryProtocol,
    FeatureFlagChecker: FeatureFlagCheckerProtocol,
    Clock: _Concurrency.Clock
>: Sendable where Clock.Duration == Duration {

    let config: Configuration
    let serverDrivenConfig: ServerDrivenConfiguration
    let systemInfo: SystemInfo
    let osEligibility: OSEligibility
    let deviceState: DeviceState

    let connectionFactory: ConnectionFactory
    let attestationStoreOrLegacyStore: AttestationStoreOrLegacyStore<LegacyAttestationStore, AttestationStore>
    let attestationVerifier: AttestationVerifier
    let rateLimiter: RateLimiter
    let tokenProviderFactory: TokenProviderFactory
    let clock: Clock
    let clientBundleIdentifier: String
    let parametersCache: WorkloadLRUCache
    let eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation
    let featureFlagChecker: FeatureFlagChecker

    init(
        config: Configuration,
        serverDrivenConfig: ServerDrivenConfiguration,
        systemInfo: SystemInfo,
        osEligibility: OSEligibility,
        deviceState: DeviceState,
        connectionFactory: ConnectionFactory,
        attestationStoreOrLegacyStore: AttestationStoreOrLegacyStore<LegacyAttestationStore, AttestationStore>,
        attestationVerifier: AttestationVerifier,
        rateLimiter: RateLimiter,
        tokenProviderFactory: TokenProviderFactory,
        clock: Clock,
        clientBundleIdentifier: String,
        parametersCache: WorkloadLRUCache,
        eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation,
        featureFlagChecker: FeatureFlagChecker
    ) {
        self.config = config
        self.serverDrivenConfig = serverDrivenConfig
        self.systemInfo = systemInfo
        self.osEligibility = osEligibility
        self.deviceState = deviceState
        self.connectionFactory = connectionFactory
        self.attestationStoreOrLegacyStore = attestationStoreOrLegacyStore
        self.attestationVerifier = attestationVerifier
        self.rateLimiter = rateLimiter
        self.tokenProviderFactory = tokenProviderFactory
        self.clock = clock
        self.clientBundleIdentifier = clientBundleIdentifier
        self.parametersCache = parametersCache
        self.eventStreamContinuation = eventStreamContinuation
        self.featureFlagChecker = featureFlagChecker
    }

    func startTrustedRequest(
        requestParameters: RequestParameters,
        bundleIdentifier: BundleIdentifier,
        originatingBundleIdentifier: BundleIdentifier?,
        effectiveUserIdentifier: uid_t?
    ) throws -> TrustedRequestXPCProxy {
        // Here, we'll block a call on the basis of the config bag's list of blocked
        // bundle ids. We will block a request on the basis of both its bundleIdentifier
        // (which is actual or overridden) AND its originatingBundleIdentifier, which might
        // be a third party. Assuming the call proceeds, the only remaining use for
        // originatingBundleId will be to pass it in telemetry.
        let blockedBundleIds = self.serverDrivenConfig.blockedBundleIds
        guard
            !blockedBundleIds.contains(where: {
                $0 == bundleIdentifier.rawValue || $0 == originatingBundleIdentifier?.rawValue || $0 == self.clientBundleIdentifier
            })
        else {
            logger.error(
                "bundleID blocked by server, exiting trusted request with blockedBundleIDs=\(blockedBundleIds), bundleID=\(bundleIdentifier.rawValue), originatingBundleID=\(originatingBundleIdentifier?.rawValue ?? "nil"), clientBundleIdentifier=\(self.clientBundleIdentifier)"
            )
            throw PrivateCloudComputeError(code: .bundleIdBlocked)
        }

        let configuration = try TrustedRequestConfiguration(
            clientBundleID: self.clientBundleIdentifier,
            bundleID: bundleIdentifier,
            originatingBundleID: originatingBundleIdentifier,
            featureID: requestParameters.featureIdentifier,
            sessionID: requestParameters.sessionIdentifier,
            configuration: config,
            parameters: requestParameters.workload,
            multiTurn: requestParameters.isMultiTurn,
            qos: requestParameters.qos,
            serviceClass: requestParameters.serviceClass?.unwrap(),
            serverConfiguration: self.serverDrivenConfig,
            userID: effectiveUserIdentifier,
            systemInfo: self.systemInfo,
            deviceState: self.deviceState,
            featureFlagChecker: self.featureFlagChecker
        )

        let serverRequestID = UUID()
        logger.log("server id=\(serverRequestID) set for request against client id=\(requestParameters.clientRequestId)")

        let requestMetrics = RequestMetrics(
            clientRequestID: requestParameters.clientRequestId,
            serverRequestID: serverRequestID,
            bundleID: configuration.bundleID,
            originatingBundleID: configuration.originatingBundleID,
            featureID: configuration.featureID,
            sessionID: configuration.sessionID,
            environment: configuration.environment.name,
            qos: configuration.serverQoS,
            serviceClass: configuration.serviceClass,
            parameters: requestParameters.workload,
            eventStreamContinuation: self.eventStreamContinuation,
            clock: self.clock,
            attestationStoreOrLegacyStore: self.attestationStoreOrLegacyStore,
            systemInfo: self.systemInfo,
            biomeReporter: BiomeReporter()
        )

        guard self.deviceState.isUnlockedSinceBoot else {
            logger.info("request blocked because the device has not been unlocked since boot")
            let error = PrivateCloudComputeError(code: .unavailableBeforeFirstUnlock)
            requestMetrics.requestFinished(error: error)
            throw error
        }

        guard self.osEligibility.deviceEligibleForPCC else {
            logger.info("request blocked due to eligibility failure")
            let error = PrivateCloudComputeError(code: .eligibilityCheckFailed)
            requestMetrics.requestFinished(error: error)
            throw error
        }

        let outgoingUserDataWriter = OutgoingUserDataWriter()
        let incomingUserDataReader = IncomingUserDataReader()
        let progressReader = TrustedRequestProgressReader()
        let oneTimeTokenProvider = try self.tokenProviderFactory.oneTimeTokenProvider(
            workloadType: requestParameters.workload.type,
            featureIdentifier: requestParameters.featureIdentifier ?? "",
            logPrefix: "\(serverRequestID): [ott]"
        )

        var reputationTokenProvider: TokenProviderFactory.ReputationTokenProvider? = nil
        if self.featureFlagChecker.isEnabled(.reputationTokens) {
            do {
                reputationTokenProvider = try self.tokenProviderFactory.reputationTokenProvider(
                    workload: requestParameters.workload,
                    featureIdentifier: requestParameters.featureIdentifier ?? "",
                    logPrefix: "\(serverRequestID): [reputation]"
                )
            } catch {
                logger.error("\(serverRequestID): failed to create reputation token provider, continuing without it, error=\(error)")
            }
        }

        var waitlistTokenProvider: TokenProviderFactory.WaitlistTokenProvider? = nil
        if self.featureFlagChecker.isEnabled(.waitlistTokens) {
            waitlistTokenProvider = self.tokenProviderFactory.waitlistTokenProvider(logPrefix: "\(serverRequestID): [waitlist]")
            logger.info("\(serverRequestID): waitlist token provider, created=\(waitlistTokenProvider != nil)")
        }

        let request = TrustedRequest(
            clientRequestID: requestParameters.clientRequestId,
            serverRequestID: serverRequestID,
            configuration: configuration,
            parameters: requestParameters.workload,
            stepReporter: AppleIntelligenceStepReporter(forWorkload: requestParameters.workload),
            outgoingUserDataWriter: outgoingUserDataWriter,
            incomingUserDataReader: incomingUserDataReader,
            progressReader: progressReader,
            connectionFactory: self.connectionFactory,
            attestationStoreOrLegacyStore: self.attestationStoreOrLegacyStore,
            attestationVerifier: self.attestationVerifier,
            rateLimiter: self.rateLimiter,
            systemInfo: self.systemInfo,
            tokenProvider: oneTimeTokenProvider,
            reputationTokenProvider: reputationTokenProvider,
            waitlistTokenProvider: waitlistTokenProvider,
            requestMetrics: requestMetrics,
            clock: self.clock,
            eventStreamContinuation: self.eventStreamContinuation,
            featureFlagChecker: self.featureFlagChecker
        )

        let task = Task {
            // In rdar://140284184 we see an InactiveHard jetsam on macOS following a `nextWithCompletion:` call during
            // an exceptionally long iteration of response data. We should hold a transaction during the entire process
            // of running the request task, instead of leaving it up to the xpc layer.
            try await withOSTransaction(name: "startTrustedRequest.Task") {
                // Kick off any cleanup that is necessary on the attestation store. We do not take any assertions at the moment
                // while performing disk writes. However the trusted request path will acquire power assertions. We should be able to
                // perform all the clean up in parallel while the trusted request runs
                self.eventStreamContinuation.yield(.attestationStoreCleanup)
                self.eventStreamContinuation.yield(
                    .reportDailyActiveUserIfNecessary(
                        requestID: request.requestMetrics.requestIDForEventReporting,
                        environment: configuration.environment.name
                    )
                )

                // add the parameters to the cache for prefetching attestations for such requests in the future
                var prefetchNeeded: Bool = false
                if let prefetchParameters = requestParameters.workload.forPrefetching() {
                    if !self.parametersCache.addToCache(value: prefetchParameters) {
                        prefetchNeeded = true
                    }
                }

                defer {
                    if os_variant_allows_internal_security_policies(privateCloudComputeOsVariantSubsystem) {
                        self.logRequest(request.requestMetrics.makeLogEntry())
                    }
                }

                // Actually run the request
                try await request.run()

                // If we are seeing this workload for the first time, kick off a prefetch so that we have cached attestations for this
                // workload if another request happens before the scheduled prefetches runs
                if prefetchNeeded {
                    logger.log("need to prefetch attestations for this workload")
                    self.eventStreamContinuation.yield(.prefetchAttestationsForNewWorkload(workload: requestParameters.workload))
                }

                if self.attestationStoreOrLegacyStore.isLegacy {
                    // Discard prefetched attestations used for this request and prefetch just a single batch
                    // This is to ensure that attestations never repeat between requests for targetability concerns and
                    // to make sure that the attestation cache is always topped up for future trusted requests which may happen before
                    // the scheduled prefetching runs
                    self.eventStreamContinuation.yield(.discardUsedAttestationsAndPrefetchBatch(serverRequestID: serverRequestID, workload: requestParameters.workload))
                }
            }
        }

        return TrustedRequestXPCProxy(
            requestID: serverRequestID,
            // Chunk size is computed once at task-creation time (snapshot semantics) from
            // daemon-side config and feature flags, so the framework receives a stable value
            // for the lifetime of this request rather than re-evaluating lazily.
            chunkSize: Self.computeChunkSize(env: configuration.environment, config: self.config, featureFlagChecker: self.featureFlagChecker),
            outgoingUserDataWriter: outgoingUserDataWriter,
            incomingUserDataReader: incomingUserDataReader,
            progressReader: progressReader,
            task: task,
            xpcEventsObserver: request,
            featureFlagChecker: self.featureFlagChecker
        )
    }

    /// Computes the effective chunk size from daemon-side configuration and feature flags
    ///
    /// - Returns: The maximum bytes per chunk, or `nil` if chunking is disabled.
    private static func computeChunkSize(
        env: TC2Environment,
        config: Configuration,
        featureFlagChecker: some FeatureFlagCheckerProtocol
    ) -> Int? {
        let flag: PrivateCloudComputeFeatureFlags = env == .production ? .applicationDataChunking : .applicationDataChunkingPreProduction
        guard featureFlagChecker.isEnabled(flag) else {
            return nil
        }
        let rawSize = config[.applicationDataChunkingSize]
        return rawSize > 0 ? rawSize : nil
    }

    private func logRequest(_ logEntry: TrustedRequestLogEntry) {
        let jsonEncoder = JSONEncoder()

        jsonEncoder.dateEncodingStrategy = .custom { date, encoder in
            let formatStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(formatStyle))
        }

        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? jsonEncoder.encode(logEntry), let string = String(data: data, encoding: .utf8) {
            let logger = Logger(subsystem: logSubsystem, category: LogCategory.requestLogCategoryName)
            logger.log("\(string)")
        } else {
            logger.error("unable to encode and log request")
        }
    }
}
