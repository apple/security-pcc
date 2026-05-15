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
//  TrustedRequestFactory.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CloudAttestation
internal import CollectionsInternal
private import DarwinPrivate.os.variant
import Foundation
import PrivateCloudCompute
import os.log

typealias ThimbledTrustedRequestFactory = TrustedRequestFactory<
    NWAsyncConnection,
    AttestationStore,
    AttestationVerifier<FeatureFlagChecker, CloudAttestation.MuxValidator>,
    RateLimiter,
    ServerDrivenConfiguration,
    SystemInfo,
    NSPTokenProvider,
    FeatureFlagChecker,
    ContinuousClock
>

final class TrustedRequestFactory<
    ConnectionFactory: NWAsyncConnectionFactoryProtocol,
    AttestationStore: AttestationStoreProtocol,
    AttestationVerifier: AttestationVerifierProtocol,
    RateLimiter: RateLimiterProtocol,
    ServerDrivenConfiguration: ServerDrivenConfigurationProtocol,
    SystemInfo: SystemInfoProtocol,
    TokenProvider: TokenProviderProtocol,
    FeatureFlagChecker: FeatureFlagCheckerProtocol,
    Clock: _Concurrency.Clock
>: Sendable where Clock.Duration == Duration {

    let logger = tc2Logger(forCategory: .daemon)
    let config: any Configuration
    let serverDrivenConfig: ServerDrivenConfiguration
    let systemInfo: SystemInfo

    let connectionFactory: ConnectionFactory
    let attestationStore: AttestationStore?
    let attestationVerifier: AttestationVerifier
    let rateLimiter: RateLimiter
    let tokenProvider: TokenProvider
    let clock: Clock
    let clientBundleIdentifier: String
    let allowBundleIdentifierOverride: Bool
    let parametersCache: WorkloadLRUCache
    let eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation
    let featureFlagChecker: FeatureFlagChecker

    init(
        config: any Configuration,
        serverDrivenConfig: ServerDrivenConfiguration,
        systemInfo: SystemInfo,
        connectionFactory: ConnectionFactory,
        attestationStore: AttestationStore?,
        attestationVerifier: AttestationVerifier,
        rateLimiter: RateLimiter,
        tokenProvider: TokenProvider,
        clock: Clock,
        clientBundleIdentifier: String,
        allowBundleIdentifierOverride: Bool,
        parametersCache: WorkloadLRUCache,
        eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation,
        featureFlagChecker: FeatureFlagChecker
    ) {
        self.config = config
        self.serverDrivenConfig = serverDrivenConfig
        self.systemInfo = systemInfo
        self.connectionFactory = connectionFactory
        self.attestationStore = attestationStore
        self.attestationVerifier = attestationVerifier
        self.rateLimiter = rateLimiter
        self.tokenProvider = tokenProvider
        self.clock = clock
        self.clientBundleIdentifier = clientBundleIdentifier
        self.allowBundleIdentifierOverride = allowBundleIdentifierOverride
        self.parametersCache = parametersCache
        self.eventStreamContinuation = eventStreamContinuation
        self.featureFlagChecker = featureFlagChecker
    }

    func startTrustedRequest(
        clientRequestID: UUID,
        parameters: Workload,
        multiTurn: Bool,
        bundleID requestedBundleID: String?,
        originatingBundleIdentifier: String?,
        featureID: String?,
        sessionID: UUID?,
        effectiveUserIdentifier: uid_t?
    ) -> TrustedRequestXPCProxy? {
        // Figure out which bundle identifier to use
        var bundleIdentifier = self.clientBundleIdentifier
        if let requestedBundleID {
            // if we aren't allowed to use the requested one, error out
            if !allowBundleIdentifierOverride {
                self.logger.error("client not allowed to override \(self.clientBundleIdentifier) with \(requestedBundleID). Need entitlement \(PrivateCloudComputeEntitlement.bundleIdentifierOverride.rawValue)")
                return nil
            }
            bundleIdentifier = requestedBundleID
        }

        // Here, we'll block a call on the basis of the config bag's list of blocked
        // bundle ids. We will block a request on the basis of both its bundleIdentifier
        // (which is actual or overridden) AND its originatingBundleIdentifier, which might
        // be a third party. Assuming the call proceeds, the only remaining use for
        // originatingBundleId will be to pass it in telemetry.

        let blockedBundleIds = self.serverDrivenConfig.blockedBundleIds
        guard
            !blockedBundleIds.contains(where: {
                $0 == bundleIdentifier || $0 == originatingBundleIdentifier || $0 == self.clientBundleIdentifier
            })
        else {
            self.logger.error(
                "bundleId blocked by server, exiting trusted request with blockedBundleIds=\(blockedBundleIds), bundleId=\(bundleIdentifier), originatingBundleId=\(originatingBundleIdentifier ?? "nil")), clientBundleIdentifier=\(self.clientBundleIdentifier)"
            )
            return nil
        }

        guard
            let configuration = try? TrustedRequestConfiguration(
                clientBundleID: self.clientBundleIdentifier,
                bundleID: bundleIdentifier,
                originatingBundleID: originatingBundleIdentifier,
                featureID: featureID,
                sessionID: sessionID,
                configuration: config,
                parameters: parameters,
                multiTurn: multiTurn,
                serverConfiguration: self.serverDrivenConfig,
                userID: effectiveUserIdentifier,
                systemInfo: self.systemInfo,
                featureFlagChecker: self.featureFlagChecker
            )
        else {
            return nil
        }

        let serverRequestID = UUID()
        logger.log("server id=\(serverRequestID) set for request against client id=\(clientRequestID)")

        let outgoingUserDataWriter = OutgoingUserDataWriter()
        let incomingUserDataReader = IncomingUserDataReader()
        let progressReader = TrustedRequestProgressReader()

        let request = TrustedRequest(
            clientRequestID: clientRequestID,
            serverRequestID: serverRequestID,
            configuration: configuration,
            parameters: parameters,
            outgoingUserDataWriter: outgoingUserDataWriter,
            incomingUserDataReader: incomingUserDataReader,
            progressReader: progressReader,
            connectionFactory: self.connectionFactory,
            attestationStore: self.attestationStore,
            attestationVerifier: self.attestationVerifier,
            rateLimiter: self.rateLimiter,
            systemInfo: self.systemInfo,
            tokenProvider: self.tokenProvider,
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
                self.eventStreamContinuation.yield(.reportDailyActiveUserIfNecessary(requestID: request.requestMetrics.requestIDForEventReporting, environment: configuration.environment))

                // add the parameters to the cache for prefetching attestations for such requests in the future
                var prefetchNeeded: Bool = false
                if let prefetchParameters = parameters.forPrefetching() {
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
                    self.logger.log("need to prefetch attestations for this workload")
                    self.eventStreamContinuation.yield(.prefetchAttestationsForNewWorkload(parameters: parameters))
                }

                // Discard prefetched attestations used for this request and prefetch just a single batch
                // This is to ensure that attestations never repeat between requests for targetability concerns and
                // to make sure that the attestation cache is always topped up for future trusted requests which may happen before
                // the scheduled prefetching runs
                self.eventStreamContinuation.yield(.discardUsedAttestationsAndPrefetchBatch(serverRequestID: serverRequestID, parameters: parameters))
            }
        }

        return TrustedRequestXPCProxy(
            requestID: serverRequestID,
            outgoingUserDataWriter: outgoingUserDataWriter,
            incomingUserDataReader: incomingUserDataReader,
            progressReader: progressReader,
            task: task,
            xpcEventsObserver: request.requestMetrics
        )
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
            let logger = tc2Logger(forCategory: .requestLog)
            logger.log("\(string)")
        } else {
            self.logger.error("unable to encode and log request")
        }
    }
}
