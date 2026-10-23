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
//  AttestationStorePrefetch.swift
//  PrivateCloudCompute
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import InternalSwiftProtobuf
@_spi(HTTP) @_spi(OHTTP) @_spi(NWActivity) import Network
import PrivateCloudCompute
import Security
import Synchronization
import os.lock

private let logger = Logger(for: .prefetchRequest)
private let signposter = OSSignposter(logger: logger)

private enum Constants {
    static let maximumConcurrentAttestationVerifications = 4
    static let maximumExpiryDuration: TimeInterval = .hours(48)

    /// Minimum number of attestations expected from the server based on environment.
    /// Production requires more attestations for anti-targeting protection.
    static func minimumExpectedAttestations(for environment: TC2Environment) -> Int {
        switch environment {
        case .production:
            return 40
        case .carry:
            return 10
        default:
            return 1
        }
    }
}

/// Prefetches attestations from ROPES server using the V3 AttestationStore.
/// This implementation uses staged attestations with atomic commit/discard semantics.
/// This request does not talk to Thimble nodes directly.
final class AttestationStorePrefetch<
    ConnectionFactory: NWAsyncConnectionFactoryProtocol,
    AttestationStore: AttestationStoreProtocol,
    RateLimiter: RateLimiterProtocol,
    AttestationVerifier: AttestationVerifierProtocol,
    ServerDrivenConfiguration: ServerDrivenConfigurationProtocol,
    SystemInfo: SystemInfoProtocol,
    FeatureFlagChecker: FeatureFlagCheckerProtocol
>: PrefetchProtocol, Sendable {
    private let encoder = tc2JSONEncoder()
    private let connectionFactory: ConnectionFactory
    private let attestationStore: AttestationStore
    private let rateLimiter: RateLimiter
    private let attestationVerifier: AttestationVerifier
    let config: any Configuration
    private let serverDrivenConfig: ServerDrivenConfiguration
    let systemInfo: SystemInfo
    private let featureFlagChecker: FeatureFlagChecker
    private let parameters: Workload
    let eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation
    let prewarm: Bool
    let bundleIdentifier: BundleIdentifier?
    let featureIdentifier: String?
    let serviceClass: NWParameters.ServiceClass?
    private let pendingPrefetchID = UUID()
    private let networkConnectionReadSize: Int

    init(
        connectionFactory: ConnectionFactory,
        attestationStore: AttestationStore,
        rateLimiter: RateLimiter,
        attestationVerifier: AttestationVerifier,
        config: any Configuration,
        serverDrivenConfig: ServerDrivenConfiguration,
        systemInfo: SystemInfo,
        featureFlagChecker: FeatureFlagChecker,
        parameters: Workload,
        eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation,
        prewarm: Bool,
        bundleIdentifier: BundleIdentifier? = nil,
        featureIdentifier: String? = nil,
        serviceClass: NWParameters.ServiceClass? = nil
    ) {
        self.connectionFactory = connectionFactory
        self.attestationStore = attestationStore
        self.rateLimiter = rateLimiter
        self.attestationVerifier = attestationVerifier
        self.config = config
        self.serverDrivenConfig = serverDrivenConfig
        self.systemInfo = systemInfo
        self.featureFlagChecker = featureFlagChecker
        self.parameters = parameters
        self.eventStreamContinuation = eventStreamContinuation
        self.prewarm = prewarm
        self.bundleIdentifier = bundleIdentifier
        self.featureIdentifier = featureIdentifier
        self.serviceClass = serviceClass
        self.networkConnectionReadSize = featureFlagChecker.isEnabled(.boundedNetworkReads2) ? config[.networkConnectionReadSize] : .max
    }

    private func fetch(
        requestID: UUID,
        requestIDForReporting: UUID,
        fetchTime: Date,
        headers: HTTPFields,
        prefetchParameters: Workload,
        workloadParametersAsString: String,
        expectedNumberOfAttestations: Int,
        pendingPrefetchID: UUID,
        signpostID: OSSignpostID
    ) async throws -> (response: Prefetch.Response, successfulSaveCount: Int) {
        try await withOSActivity {
            let successfulSaveCount = Mutex(0)
            let nodes: Mutex<[Prefetch.Response.Node]> = Mutex([])

            let logPrefix = "\(requestID):"
            logger.log("\(logPrefix) executing prefetch request")
            defer {
                logger.log("\(logPrefix) finished prefetch request")
            }

            let environment = self.config.environment(systemInfo: self.systemInfo)

            try await self.connectionFactory.connect(
                parameters: .makeTLSAndHTTPParameters(
                    ignoreCertificateErrors: self.config[.ignoreCertificateErrors],
                    forceOHTTP: environment.forceOHTTP,
                    useCompression: true,
                    featureFlagChecker: self.featureFlagChecker,
                    bundleIdentifier: self.bundleIdentifier,
                    serviceClass: self.serviceClass
                ),
                endpoint: .url(environment.ropesUrl),
                activity: NWActivity(domain: .cloudCompute, label: .attestationPrefetch),
                on: .main,
                requestID: requestID,
                logComment: "prefetch",
                maximumReadLength: self.networkConnectionReadSize
            ) { inbound, outbound, _, _ in
                logger.log("\(logPrefix) sending request with parameters: \(workloadParametersAsString)")

                let prefetchRequest = Proto_Ropes_HttpService_PrefetchRequest.with {
                    // This field _must_ be set to ensure the server does not
                    // send attestations in lists (which the client does not handle)
                    $0.capabilities.attestationStreaming = true
                    $0.clientRequestedAttestationCount = UInt32(expectedNumberOfAttestations)
                    if self.featureFlagChecker.isEnabled(.enforceAntiTargetabilityOnPrefetch) {
                        $0.capabilities.antiTargetabilityMinAttestationEnforcement = true
                    }
                }
                logger.log("\(logPrefix) prefetchRequest=\(prefetchRequest.loggingDescription, privacy: .public)")
                let prefetchRequestData = try prefetchRequest.serializedData()

                let httpRequest = HTTPRequest(
                    method: .post,
                    scheme: "https",
                    authority: environment.ropesHostname,
                    path: self.config[.prefetchRequestPath],
                    headerFields: headers
                )

                logger.log("\(logPrefix) sending request: \(String(reflecting: httpRequest)) with parameters: \(workloadParametersAsString)")
                logger.log("\(logPrefix) sending headers\n\(headers.loggingDescription)")
                try await outbound.write(
                    content: prefetchRequestData,
                    contentContext: .init(request: httpRequest),
                    isComplete: true
                )

                logger.info("\(logPrefix) waiting for response")

                let deframed =
                    inbound
                    .onHTTPResponseHead { response in
                        logger.info("\(logPrefix) response head received: \(String(describing: response))")
                        logger.info("\(logPrefix) received headers\n\(response.headerFields.loggingDescription)")
                        guard response.status == .ok else {
                            throw PrefetchRequestError(
                                code: .unexpectedStatusCode,
                                underlying: PrefetchRequestError.UnexpectedStatusCode(statusCode: response.status.code)
                            )
                        }
                        // Note new AttestationStore nodes are swapped atomically at finalizePendingPrefetch
                    } onTrailers: { trailers in
                        if let trailers {
                            logger.info("\(logPrefix) received trailers\n\(trailers.loggingDescription)")
                        }
                    }
                    .deframed(lengthType: UInt32.self, messageType: Proto_Ropes_HttpService_PrefetchResponse.self)

                var attestationsReceived = 0
                var nodeUDIDsReceived: [String] = []
                var concurrentAttestationVerifications: Int = 0
                var processingError: (any Error)?

                await withTaskGroup(of: Prefetch.Response.Node.self) { taskGroup in
                    // throws error if validation fails to stop the processing early
                    func newNode(node: Prefetch.Response.Node) throws {
                        guard node.savedToCache else {
                            throw PrivateCloudComputeError(message: "unable to save validated attestations")
                        }

                        concurrentAttestationVerifications -= 1

                        if node.savedToCache {
                            successfulSaveCount.withLock { $0 += 1 }
                        }

                        // Having verified the attestation, we now can collect its hardware
                        // identifier for publishing to the event stream that tracks the
                        // distribution of nodes. See rdar://135384108 for details.
                        if let udid = node.udid {
                            nodeUDIDsReceived.append(udid)
                        }
                        nodes.withLock { $0.append(node) }
                    }

                    do {
                        for try await message in deframed {
                            messageProcessing: switch message.type {
                            case .attestation(let attestation):
                                logger.debug("\(logPrefix) attestation received")
                                attestationsReceived += 1
                                if concurrentAttestationVerifications == Constants.maximumConcurrentAttestationVerifications {
                                    // save to bang! We have more than Constants.maximumConcurrentAttestationVerifications
                                    // currently running, because of this there is definitely a task that we can await here.
                                    try newNode(node: await taskGroup.next()!)
                                }

                                concurrentAttestationVerifications += 1
                                let verifyAndStoreSignpostID = signposter.makeSignpostID()
                                taskGroup.addTask {
                                    await signposter.withIntervalSignpost(.prefetchVerifyAndStore, id: verifyAndStoreSignpostID) {
                                        await self.verifyAndStore(
                                            attestation: attestation,
                                            prefetchParameters: prefetchParameters,
                                            prewarm: self.prewarm,
                                            requestID: requestID,
                                            requestIDForReporting: requestIDForReporting,
                                            fetchTime: fetchTime,
                                            pendingPrefetchID: pendingPrefetchID,
                                            signpostID: signpostID
                                        )
                                    }
                                }

                            case .rateLimitConfigurationList(let rateLimitConfigurationList):
                                logger.log("\(logPrefix) received rate limit configuration count \(rateLimitConfigurationList.rateLimitConfiguration.count)")
                                for proto in rateLimitConfigurationList.rateLimitConfiguration {
                                    if let rateLimitConfig = RateLimitConfiguration(
                                        now: Date.now,
                                        source: .ropes,
                                        proto: proto,
                                        config: config
                                    ) {
                                        await self.rateLimiter.limitByConfiguration(rateLimitConfig)
                                    } else {
                                        logger.error("\(logPrefix) unable to process rate limit configuration \(String(describing: proto))")
                                    }
                                }
                                await self.rateLimiter.save()

                            case .diagnosticInformation:
                                break

                            case .none:
                                break
                            }
                        }

                        logger.info("\(logPrefix) response complete")

                        // the http stream has finished, lets await all the running verifications
                        while let node = await taskGroup.next() {
                            try newNode(node: node)
                        }
                        assert(concurrentAttestationVerifications == 0)
                    } catch {
                        logger.error("\(logPrefix) response failed: \(String(describing: error))")
                        // Store the error so we can propagate it after the task group completes
                        processingError = error
                    }
                }

                // Propagate any error that occurred during attestation processing
                if let error = processingError {
                    throw error
                }

                if attestationsReceived == 0 {
                    throw PrivateCloudComputeError(message: "prefetch returned empty response")
                }

                // note that we have received these attestations/nodes
                self.eventStreamContinuation.yield(.nodesReceived(udids: nodeUDIDsReceived, fromSource: self.prewarm ? .prewarm : .prefetch))
            }

            let response = Prefetch.Response(id: requestID, nodes: nodes.withLock { $0 })
            let count = successfulSaveCount.withLock { $0 }
            return (response, count)
        }
    }

    private func discardPrefetch(withID pendingPrefetchID: UUID) async {
        do {
            try await self.attestationStore.discardPendingPrefetch(id: pendingPrefetchID)
        } catch {
            logger.error("failed to discard pending prefetch (\(pendingPrefetchID)) after failure: \(error)")
        }
    }

    func sendRequest() async throws -> [Prefetch.Response] {
        return try await withOSActivity {
            let logPrefix = "AttestationStorePrefetch_\(self.pendingPrefetchID):"
            logger.log("\(logPrefix) executing prefetch request, prewarm=\(self.prewarm)")
            defer {
                logger.log("\(logPrefix) finished prefetch request")
            }

            var response: [Prefetch.Response] = []

            // Get the prefetch parameters needed from invoke parameters
            guard let prefetchParameters = parameters.forPrefetching() else {
                logger.error("\(logPrefix) invalid set of parameters for prefetching")
                return response
            }

            let workloadParametersAsJSON = try self.encoder.encode(
                prefetchParameters.parameters.preparedToBeSentAsHeaders(
                    featureFlagChecker: self.featureFlagChecker
                )
            )
            let workloadParametersAsString = String(data: workloadParametersAsJSON, encoding: .utf8) ?? ""

            let environment = self.config.environment(systemInfo: self.systemInfo)

            // Ensure we request at least the minimum expected attestations by clamping to the
            // minimum for the environment, allowing server-driven config to override but keep
            // it above client min.
            let expectedAttestations = max(self.serverDrivenConfig.antiTargetabilityExpectedPrefetchedAttestations ?? 0, Constants.minimumExpectedAttestations(for: environment))

            logger.log(
                "\(logPrefix) configuration, expectedAttestations:=\(expectedAttestations)"
            )

            // Note on the batches:
            // New AttestationStore doesn't have batches so we are always throwing an error if attestations exists
            // This covers all the cases that consumes prefetches now
            // The single batch case was only used to top up attestations for a used request which doesn't need to happen
            // now because we don't discard individual batches
            let attestationsValidityInSeconds = serverDrivenConfig.prewarmAttestationsValidityInSeconds ?? self.config[.prewarmAttestationsValidityInSeconds]
            let minValidityFetchTime = Date() - attestationsValidityInSeconds
            if await attestationStore.attestationsExist(forParameters: prefetchParameters, clientCacheSize: expectedAttestations, fetchTime: minValidityFetchTime) {
                logger.error("\(logPrefix) not prefetching, attestations exist for workload")
                throw PrivateCloudComputeError(message: "attestations exist for workload")
            }

            self.eventStreamContinuation.yield(
                .reportDailyPrefetchMetricIfNecessary(requestID: self.pendingPrefetchID, environment: environment.name)
            )

            var headers: HTTPFields
            do {
                headers = try makePrefetchRequestHeaders(
                    prefetchParameters: prefetchParameters,
                    workloadParametersAsString: workloadParametersAsString
                )
            } catch {
                logger.error("\(logPrefix) not prefetching: \(error)")
                throw error
            }

            let fetchTime = Date()
            logger.log("\(logPrefix) fetchTime: \(fetchTime)")

            let v3LogPrefix = "AttestationStoreV3 pendingPrefetchID:\(pendingPrefetchID.uuidString):"
            let requestID = UUID()

            let requestIDForReporting: UUID
            switch environment {
            case .production:
                // we need to have a different UUID for reporting for PROD due to privacy concerns
                requestIDForReporting = UUID()
                logger.log("\(v3LogPrefix) Request: \(requestID) RequestIDForReporting: \(requestIDForReporting)")
            default:
                requestIDForReporting = requestID
            }

            headers[HTTPField.Name.appleRequestUUID] = requestID.uuidString

            let signpostID = signposter.makeSignpostID()
            return try await signposter.withIntervalSignpost(.prefetch, id: signpostID) {
                do {
                    let prefetchResponse: Prefetch.Response
                    let saveCount: Int
                    (prefetchResponse, saveCount) = try await fetch(
                        requestID: requestID,
                        requestIDForReporting: requestIDForReporting,
                        fetchTime: fetchTime,
                        headers: headers,
                        prefetchParameters: prefetchParameters,
                        workloadParametersAsString: workloadParametersAsString,
                        expectedNumberOfAttestations: expectedAttestations,
                        pendingPrefetchID: self.pendingPrefetchID,
                        signpostID: signpostID
                    )

                    if prefetchResponse.nodes.count != saveCount {
                        // This should never happen because entire response is thrown away if a udid duplication is found
                        // In case this does happen, we should sim crash
                        logger.fault("\(v3LogPrefix) error: number of nodes in response (\(prefetchResponse.nodes.count)) does not match number saved (\(saveCount))")
                    }

                    // Verify we received the minimum number of attestations for this environment.
                    let minimumAttestationEnforcementEnabled = self.featureFlagChecker.isEnabled(.enforceAntiTargetabilityOnPrefetch)
                    logger.log("\(v3LogPrefix) minimumAttestationEnforcementEnabled=\(minimumAttestationEnforcementEnabled), minimumExpectedAttestations=\(expectedAttestations), saveCount=\(saveCount)")
                    if saveCount < expectedAttestations && minimumAttestationEnforcementEnabled {
                        logger.error("\(v3LogPrefix) insufficient attestations received: expected at least \(expectedAttestations), got \(saveCount)")
                        throw PrivateCloudComputeError(message: "insufficient attestations received: expected at least \(expectedAttestations), got \(saveCount)")
                    }

                    // prefetchResponse is for thtool to print out the nodes
                    response.append(prefetchResponse)
                } catch {
                    logger.error("\(v3LogPrefix) failed prefetch error: \(error)")
                    await self.discardPrefetch(withID: pendingPrefetchID)
                    throw error
                }

                logger.log("\(v3LogPrefix) finalizing pending prefetch")
                do {
                    try await attestationStore.finalizePendingPrefetch(for: prefetchParameters, pendingPrefetchID: pendingPrefetchID, isPrewarm: self.prewarm)
                    logger.log("\(v3LogPrefix) successfully finalized pending prefetch")
                } catch {
                    logger.error("\(v3LogPrefix) failed to finalize pending prefetch: \(error)")
                    await self.discardPrefetch(withID: pendingPrefetchID)
                    throw error
                }

                return response
            }
        }
    }

    private func verifyAndStore(
        attestation: Proto_Ropes_Common_Attestation,
        prefetchParameters: Workload,
        prewarm: Bool,
        requestID: UUID,
        requestIDForReporting: UUID,
        fetchTime: Date,
        pendingPrefetchID: UUID,
        signpostID: OSSignpostID
    ) async -> Prefetch.Response.Node {
        let logPrefix = "\(requestID):"

        // V3: Uses nodeId (base64EncodedSHA256 of attestation bundle) as the primary key
        let nodeIdentifier = attestation.attestationBundle.base64EncodedSHA256

        do {
            // Get the unique identifier for the node received from ROPES
            let udid = try await self.attestationVerifier.udid(attestation: .init(attestation: attestation, requestParameters: prefetchParameters))
            // V3: Check if attestation already exists by nodeId
            if let validatedNode = try await attestationStore.validatedAttestation(for: nodeIdentifier) {
                signposter.emitEvent("PrefetchRequest.saveAttestation.existing", id: signpostID)
                logger.log("\(logPrefix) node already exists in store for attestation \(nodeIdentifier)")

                try await attestationStore.stageValidatedAttestation(validatedNode, pendingPrefetchID: pendingPrefetchID)
                logger.log("\(logPrefix) existing attestation successfully staged attestation for node: \(nodeIdentifier)")

                return .init(
                    identifier: nodeIdentifier,
                    cloudOSVersion: attestation.nodeBuildVersion,
                    cloudOSReleaseType: attestation.nodeReleaseType,
                    validationResult: .validationNotNeeded,
                    savedToCache: true,
                    udid: udid
                )
            }
        } catch {
            logger.error("\(logPrefix) unable to check the unique id of the attestation and hence skipping validation: \(nodeIdentifier)")
            return .init(
                identifier: nodeIdentifier,
                cloudOSVersion: attestation.nodeBuildVersion,
                cloudOSReleaseType: attestation.nodeReleaseType,
                validationResult: .invalid(error: String(describing: error)),
                savedToCache: false,
                udid: nil
            )
        }

        // Validate the received attestation
        let validationStartTime = Date()
        do {
            let validatedAttestation = try await self.attestationVerifier.validate(
                attestation: .init(attestation: attestation, requestParameters: prefetchParameters),
                expectedNodeKind: .proxy
            )
            var savedToCache = false

            if !attestation.nodeIdentifier.isEmpty && attestation.nodeIdentifier != nodeIdentifier {
                logger.error("\(logPrefix) node id does not match attestation bundle calculated=\(nodeIdentifier) fromServer=\(attestation.nodeIdentifier) bundleSize=\(attestation.attestationBundle.count) bytes")
            }

            let udid = validatedAttestation.udid

            // Check attestation expiry times
            if validatedAttestation.attestationExpiry.timeIntervalSinceNow > Constants.maximumExpiryDuration {
                logger.error("\(logPrefix) attestation validation returned too long expiration for attestation: \(nodeIdentifier); expiry: \(validatedAttestation.attestationExpiry)")
                return .init(
                    identifier: nodeIdentifier,
                    cloudOSVersion: attestation.nodeBuildVersion,
                    cloudOSReleaseType: attestation.nodeReleaseType,
                    validationResult: .validatedExpiryTooLarge,
                    savedToCache: savedToCache,
                    udid: nil
                )
            }

            // V3: Stage the validated attestation (will be committed atomically on finalize)
            do {
                try await attestationStore.stageValidatedAttestation(validatedAttestation, pendingPrefetchID: pendingPrefetchID)
                signposter.emitEvent("PrefetchRequest.saveAttestation.new", id: signpostID)
                logger.log("\(logPrefix) successfully staged attestation for node: \(nodeIdentifier)")
                savedToCache = true
            } catch {
                if let attestationError = error as? AttestationStoreError, attestationError.code == .duplicateUdidInPrefetch {
                    logger.error("\(logPrefix) duplicate udid found in prefetch request for node \(nodeIdentifier), udid: \(udid)")
                } else {
                    logger.error("\(logPrefix) failed to stage attestation for node: \(nodeIdentifier), error: \(error)")
                }
                await self.discardPrefetch(withID: pendingPrefetchID)
                throw error
            }

            return .init(
                identifier: nodeIdentifier,
                cloudOSVersion: attestation.nodeBuildVersion,
                cloudOSReleaseType: attestation.nodeReleaseType,
                validationResult: .valid(publicKey: validatedAttestation.publicKey, expiry: validatedAttestation.attestationExpiry),
                savedToCache: savedToCache,
                udid: udid
            )
        } catch {
            logger.error("\(logPrefix) attestation validation failed for node: \(nodeIdentifier) with error: \(error)")

            // we need to report this error
            let errorMetric = makeAttestationVerificationErrorMetric(
                requestIDForReporting: requestIDForReporting,
                nodeIdentifier: nodeIdentifier,
                error: error,
                validationStartTime: validationStartTime
            )

            self.eventStreamContinuation.yield(.exportMetric(errorMetric))

            return .init(
                identifier: nodeIdentifier,
                cloudOSVersion: attestation.nodeBuildVersion,
                cloudOSReleaseType: attestation.nodeReleaseType,
                validationResult: .invalid(error: String(describing: error)),
                savedToCache: false,
                udid: nil
            )
        }
    }
}
