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
//  BatchedPrefetch.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import InternalSwiftProtobuf
@_spi(HTTP) @_spi(OHTTP) @_spi(NWActivity) import Network
import PrivateCloudCompute
import Security
import Synchronization
import os.lock

private let logger = Logger(for: .batchedPrefetchRequest)
private let signposter = OSSignposter(logger: logger)

enum TC2FetchType: Equatable {
    case fetchAllBatches
    case fetchSingleBatch(batchID: UInt)
}

private enum Constants {
    static let maximumConcurrentAttestationVerifications = 4
    static let maximumExpiryDuration: TimeInterval = .hours(48)
}

/// Prefetches attestations from ROPES server using the legacy AttestationStore using batches.
/// This request does not talk to Thimble nodes directly.
final class BatchedPrefetch<
    ConnectionFactory: NWAsyncConnectionFactoryProtocol,
    LegacyAttestationStore: LegacyAttestationStoreProtocol,
    RateLimiter: RateLimiterProtocol,
    AttestationVerifier: AttestationVerifierProtocol,
    ServerDrivenConfiguration: ServerDrivenConfigurationProtocol,
    SystemInfo: SystemInfoProtocol,
    FeatureFlagChecker: FeatureFlagCheckerProtocol
>: PrefetchProtocol, Sendable {
    private let encoder = tc2JSONEncoder()
    private let connectionFactory: ConnectionFactory
    private let attestationStore: LegacyAttestationStore
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
    private let fetchType: TC2FetchType
    private let batchUUID: UUID = UUID()
    private let networkConnectionReadSize: Int

    init(
        connectionFactory: ConnectionFactory,
        attestationStore: LegacyAttestationStore,
        rateLimiter: RateLimiter,
        attestationVerifier: AttestationVerifier,
        config: any Configuration,
        serverDrivenConfig: ServerDrivenConfiguration,
        systemInfo: SystemInfo,
        featureFlagChecker: FeatureFlagChecker,
        parameters: Workload,
        eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation,
        prewarm: Bool,
        fetchType: TC2FetchType,
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
        self.fetchType = fetchType
        self.networkConnectionReadSize = featureFlagChecker.isEnabled(.boundedNetworkReads2) ? config[.networkConnectionReadSize] : .max
    }

    private func fetchBatch(
        batchUUID: UUID,
        requestID: UUID,
        requestIDForReporting: UUID,
        batchID: UInt,
        fetchTime: Date,
        headers: HTTPFields,
        prefetchParameters: Workload,
        workloadParametersAsString: String,
        maxAttestations: Int,
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

                // Client should hint maxAttestations to save attestations processed per request
                let prefetchRequest = Proto_Ropes_HttpService_PrefetchRequest.with {
                    // This field _must_ be set to ensure the server does not
                    // send attestations in lists (which the client does not handle)
                    $0.capabilities.attestationStreaming = true
                    $0.clientRequestedAttestationCount = UInt32(maxAttestations)
                }
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
                        await self.attestationStore.deleteEntries(withParameters: prefetchParameters, batchId: batchID)
                    } onTrailers: { trailers in
                        if let trailers {
                            logger.info("\(logPrefix) received trailers\n\(trailers.loggingDescription)")
                        }
                    }
                    .deframed(lengthType: UInt32.self, messageType: Proto_Ropes_HttpService_PrefetchResponse.self)

                var attestationsReceived = 0
                var nodeUDIDsReceived: [String] = []

                await withTaskGroup(of: Prefetch.Response.Node.self) { taskGroup in
                    do {
                        var concurrentAttestationVerifications: Int = 0

                        for try await message in deframed {
                            messageProcessing: switch message.type {
                            case .attestation(let attestation):
                                logger.debug("\(logPrefix) attestation received")
                                attestationsReceived += 1
                                if concurrentAttestationVerifications == Constants.maximumConcurrentAttestationVerifications {
                                    // save to bang! We have more than Constants.maximumConcurrentAttestationVerifications
                                    // currently running, because of this there is definitely a task that we can await here.
                                    let node = await taskGroup.next()!
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

                                if nodes.withLock({ $0.count >= maxAttestations }) {
                                    // We should only process maxAttestations count of attestations, even if ROPES sends us more
                                    break messageProcessing
                                }

                                concurrentAttestationVerifications += 1
                                taskGroup.addTask {
                                    await signposter.withIntervalSignpost(.prefetchVerifyAndStore, id: signpostID) {
                                        await self.verifyAndStore(
                                            attestation: attestation,
                                            prefetchParameters: prefetchParameters,
                                            prewarm: self.prewarm,
                                            requestID: requestID,
                                            requestIDForReporting: requestIDForReporting,
                                            batchID: batchID,
                                            fetchTime: fetchTime,
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
                        assert(concurrentAttestationVerifications == 0)
                    } catch {
                        logger.error("\(logPrefix) response failed: \(String(describing: error))")
                    }
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

    func sendRequest() async throws -> [Prefetch.Response] {
        return try await withOSActivity {
            let logPrefix = "\(self.batchUUID):"
            logger.log("\(logPrefix) executing batch of prefetch requests, prewarm=\(self.prewarm)")
            defer {
                logger.log("\(logPrefix) finished batch of prefetch requests")
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

            let maxAttestationsPerRequest: Int
            let maxPrefetchBatches: Int
            // maxPrefetchedAttestations is capped to 60
            let maxPrefetchedAttestationsFromConfig = self.config[.trustedProxyMaxPrefetchedAttestations]
            let maxPrefetchedAttestationsFromServerConfig = self.serverDrivenConfig.trustedProxyMaxPrefetchedAttestations ?? maxPrefetchedAttestationsFromConfig
            maxAttestationsPerRequest = max(1, min(maxPrefetchedAttestationsFromServerConfig, maxPrefetchedAttestationsFromConfig))
            maxPrefetchBatches = max(1, self.serverDrivenConfig.trustedProxyMaxPrefetchBatches ?? self.config[.trustedProxyMaxPrefetchBatches])

            let batchIDsToFetch: ClosedRange<UInt>
            switch self.fetchType {
            case .fetchAllBatches:
                batchIDsToFetch = 0...UInt(maxPrefetchBatches - 1)
            case .fetchSingleBatch(let batchID):
                batchIDsToFetch = batchID...batchID
            }

            logger.log(
                "\(logPrefix) configuration: maxPrefetchedAttestations: \(maxAttestationsPerRequest), clientCacheSize: \(maxAttestationsPerRequest * batchIDsToFetch.count), maxPrefetchRequests: \(batchIDsToFetch.count), maxPrefetchBatches: \(maxPrefetchBatches)"
            )

            // Check if we have valid prefetched or prewarmed attestations before issuing a prewarm for the set of parameters
            // Skip the check if we are fetching just a single batch to top up the cache after an invoke request consumed a batch
            if fetchType == .fetchAllBatches {
                let attestationsValidityInSeconds = serverDrivenConfig.prewarmAttestationsValidityInSeconds ?? self.config[.prewarmAttestationsValidityInSeconds]
                let fetchTime = Date() - attestationsValidityInSeconds
                if await self.attestationStore.attestationsExist(
                    forParameters: prefetchParameters,
                    clientCacheSize: maxAttestationsPerRequest,
                    fetchTime: fetchTime
                ) {
                    logger.error("\(logPrefix) not prefetching, attestations exist for workload")
                    throw PrivateCloudComputeError(message: "attestations exist for workload")
                }
            }

            let environment = self.config.environment(systemInfo: self.systemInfo)
            self.eventStreamContinuation.yield(
                .reportDailyPrefetchMetricIfNecessary(requestID: self.batchUUID, environment: environment.name)
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

            // Is fetchTime actually supposed to be the same for every batch? It winds up in the
            // attestation store so it is hard to know what the impact will be.
            let fetchTime = Date()
            logger.log("\(logPrefix) fetchTime: \(fetchTime)")

            let signpostID = signposter.makeSignpostID()
            return try await signposter.withIntervalSignpost(.prefetch, id: signpostID) {
                for batchID in batchIDsToFetch {
                    let logPrefix = "\(self.batchUUID)#\(batchID):"

                    // We will only ever try requestCount number of requests. It is a best case effort to try and fill up
                    // the cache up to clientCacheSize, but if ROPES doesn't have any more attestations, we will need to bail
                    let requestID = UUID()

                    let requestIDForReporting: UUID
                    switch environment {
                    case .production:
                        // we need to have a different UUID for reporting for PROD due to privacy concerns
                        requestIDForReporting = UUID()
                        logger.log("\(logPrefix) Request: \(requestID) RequestIDForReporting: \(requestIDForReporting)")
                    default:
                        requestIDForReporting = requestID
                    }

                    headers[HTTPField.Name.appleRequestUUID] = requestID.uuidString

                    do {

                        let batchResponse: Prefetch.Response
                        let saveCount: Int
                        (batchResponse, saveCount) = try await fetchBatch(
                            batchUUID: self.batchUUID,
                            requestID: requestID,
                            requestIDForReporting: requestIDForReporting,
                            batchID: batchID,
                            fetchTime: fetchTime,
                            headers: headers,
                            prefetchParameters: prefetchParameters,
                            workloadParametersAsString: workloadParametersAsString,
                            maxAttestations: maxAttestationsPerRequest,
                            signpostID: signpostID
                        )

                        // batchResponse is just for thtool to print out the nodes, it will have duplicate nodes as well
                        response.append(batchResponse)
                        let duplicates = batchResponse.nodes.count - saveCount
                        logger.log("\(logPrefix) attestations saved: \(saveCount) duplicates: \(duplicates)")
                    } catch {
                        logger.error("\(logPrefix) failed to fetch batch error: \(error)")
                        throw error
                    }
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
        batchID: UInt,
        fetchTime: Date,
        signpostID: OSSignpostID
    ) async -> Prefetch.Response.Node {
        let logPrefix = "\(requestID):"

        let nodeIdentifier = attestation.attestationBundle.base64EncodedSHA256

        // Check if we have this attestation in our store already
        do {
            // Get the unique identifier for the node received from ROPES
            let udid = try await self.attestationVerifier.udid(attestation: .init(attestation: attestation, requestParameters: prefetchParameters))
            if await self.attestationStore.nodeExists(udid: udid) {
                signposter.emitEvent("PrefetchRequest.saveAttestation.existing", id: signpostID)
                logger.log("\(logPrefix) node exists in store for attestation \(udid) \(nodeIdentifier)")

                // Track this node for the parameter set
                let nodeAlreadyTrackedInBatch = await self.attestationStore.trackNodeForParameters(
                    forParameters: prefetchParameters,
                    withUdid: udid,
                    prefetched: !prewarm,
                    batchID: batchID,
                    fetchTime: fetchTime)
                if nodeAlreadyTrackedInBatch {
                    // Batch contains the node already, mark this as a duplicate node for the current batch
                    return .init(
                        identifier: nodeIdentifier,
                        cloudOSVersion: attestation.nodeBuildVersion,
                        cloudOSReleaseType: attestation.nodeReleaseType,
                        validationResult: .nodeAlreadyExistsInBatch,
                        savedToCache: false,
                        udid: udid
                    )
                } else {
                    // We did add tracking, but didn't need to validate the node because a validated one exists already
                    return .init(
                        identifier: nodeIdentifier,
                        cloudOSVersion: attestation.nodeBuildVersion,
                        cloudOSReleaseType: attestation.nodeReleaseType,
                        validationResult: .validationNotNeeded,
                        savedToCache: true,
                        udid: udid
                    )
                }
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

            // Attempt to save the validated attestation to the cache
            if await self.attestationStore.saveValidatedAttestation(validatedAttestation, for: prefetchParameters, prefetched: !prewarm, batch: batchID, fetchTime: fetchTime) {
                signposter.emitEvent("PrefetchRequest.saveAttestation.new", id: signpostID)
                logger.log("\(logPrefix) successfully saved attestation for node: \(nodeIdentifier)")
                savedToCache = true
            } else {
                logger.log("\(logPrefix) failed to save attestation for node: \(nodeIdentifier)")
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
                savedToCache: true,
                udid: nil
            )
        }
    }
}
