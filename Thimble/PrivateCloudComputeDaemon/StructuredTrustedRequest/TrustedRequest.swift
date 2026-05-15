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
//  TrustedRequest.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import AppleIntelligenceReporting
import FeatureFlags
import Foundation
import InternalSwiftProtobuf
@_spi(HTTP) @_spi(OHTTP) import Network
import PrivateCloudCompute
import Synchronization
import os.log

protocol IncomingUserDataReaderProtocol: Sendable {
    func forwardData(_ data: IncomingUserData) async throws
    func finish(error: (any Error)?)
}

protocol OutgoingUserDataWriterProtocol: Sendable {
    func withNextOutgoingElement<Result>(_ closure: (OutgoingUserData) async throws -> Result) async throws -> Result

    func cancelAllWrites(error: any Error)
}

protocol TrustedRequestXPCEventsObserver: Sendable {
    func willCancel(reason: TrustedRequestCancellationReason)
    func createSubrequestFailed(subrequest: XPCSubrequest, error: PrivateCloudComputeError)
}

enum TrustedRequestCancellationReason {
    case frameworkCancellation
    case xpcInvalidation
}

final class TrustedRequest<
    OutgoingUserDataWriter: OutgoingUserDataWriterProtocol,
    IncomingUserDataReader: IncomingUserDataReaderProtocol,
    ConnectionFactory: NWAsyncConnectionFactoryProtocol,
    AttestationStore: AttestationStoreProtocol,
    AttestationVerifier: AttestationVerifierProtocol,
    RateLimiter: RateLimiterProtocol,
    SystemInfo: SystemInfoProtocol,
    TokenProvider: TokenProviderProtocol,
    FeatureFlagChecker: FeatureFlagCheckerProtocol,
    Clock: _Concurrency.Clock
>: Sendable where Clock.Duration == Duration {
    let clientRequestID: UUID
    let serverRequestID: UUID
    let configuration: TrustedRequestConfiguration
    let parameters: Workload

    let outgoingUserDataWriter: OutgoingUserDataWriter
    let incomingUserDataReader: IncomingUserDataReader
    let progressReader: TrustedRequestProgressReader
    let connectionFactory: ConnectionFactory
    let attestationStore: AttestationStore?
    let attestationVerifier: AttestationVerifier
    let rateLimiter: RateLimiter
    let systemInfo: SystemInfo
    let tokenProvider: TokenProvider
    let clock: Clock
    let jsonEncoder = tc2JSONEncoder()
    let featureFlagChecker: FeatureFlagChecker

    let eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation
    let requestMetrics: RequestMetrics<Clock, AttestationStore, SystemInfo, BiomeReporter>

    // The request body's OHTTP context
    private let requestOHTTPContext = 1
    private let trustedProxyResponseBypassOhttpContext = 2

    private let logger = tc2Logger(forCategory: .trustedRequest)
    private var logPrefix: String {
        logPrefix()
    }

    private func logPrefix(_ context: LogContext? = nil) -> String {
        if let context {
            "\(serverRequestID): (\(context))"
        } else {
            "\(serverRequestID):"
        }
    }

    private func logComment(_ context: LogContext) -> String {
        "\(context)"
    }

    private enum LogContext: CustomStringConvertible {
        case root
        case node(Int)  // ohttpContext
        case responseBypass(Int)  // ohttpContext
        case data(Int)  // ohttpContext

        var description: String {
            switch self {
            case .root:
                return "root"
            case .node(let ohttpContext):
                return "node, \(ohttpContext)"
            case .responseBypass(let ohttpContext):
                return "responseBypass, \(ohttpContext)"
            case .data(let ohttpContext):
                return "data, \(ohttpContext)"
            }
        }
    }

    init(
        clientRequestID: UUID,
        serverRequestID: UUID,
        configuration: TrustedRequestConfiguration,
        parameters: Workload,
        outgoingUserDataWriter: OutgoingUserDataWriter,
        incomingUserDataReader: IncomingUserDataReader,
        progressReader: TrustedRequestProgressReader,
        connectionFactory: ConnectionFactory,
        attestationStore: AttestationStore?,
        attestationVerifier: AttestationVerifier,
        rateLimiter: RateLimiter,
        systemInfo: SystemInfo,
        tokenProvider: TokenProvider,
        clock: Clock,
        startDate: Date = .now,
        eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation,
        featureFlagChecker: FeatureFlagChecker
    ) {
        self.clientRequestID = clientRequestID
        self.serverRequestID = serverRequestID

        self.configuration = configuration
        self.parameters = parameters

        self.outgoingUserDataWriter = outgoingUserDataWriter
        self.incomingUserDataReader = incomingUserDataReader
        self.progressReader = progressReader
        self.connectionFactory = connectionFactory
        self.attestationStore = attestationStore
        self.attestationVerifier = attestationVerifier
        self.rateLimiter = rateLimiter
        self.systemInfo = systemInfo
        self.tokenProvider = tokenProvider
        self.clock = clock
        self.eventStreamContinuation = eventStreamContinuation
        self.featureFlagChecker = featureFlagChecker
        self.requestMetrics = RequestMetrics(
            clientRequestID: self.clientRequestID,
            serverRequestID: self.serverRequestID,
            bundleID: configuration.bundleID,
            originatingBundleID: configuration.originatingBundleID,
            featureID: configuration.featureID,
            sessionID: configuration.sessionID,
            environment: configuration.environment,
            qos: configuration.serverQoS,
            parameters: parameters,
            eventStreamContinuation: eventStreamContinuation,
            clock: clock,
            startDate: startDate,
            store: self.attestationStore,
            systemInfo: self.systemInfo,
            biomeReporter: BiomeReporter(logger: self.logger)
        )
    }

    func run() async throws {
        self.logger.debug("Running TrustedRequest")
        self.logger.debug("\(self.logPrefix) Configuration: \(self.configuration)")

        try await PowerAssertion.withPowerAssertion(name: "TC2TrustedRequest") {
            try await withAppleIntelligenceEvent(id: clientRequestID, step: .privateCloudComputeRequestInDaemon) {
                do {
                    try await self.runRequest()
                    self.incomingUserDataReader.finish(error: nil)
                    self.progressReader.finish()
                    await self.requestMetrics.requestFinished(error: nil)
                    self.eventStreamContinuation.yield(.trustedRequestCompleted(featureId: self.configuration.featureID, error: nil))
                } catch {
                    // wrapping the internal error as PrivateCloudComputeError for reporting and for throwing to our clients
                    let pccError = PrivateCloudComputeError.wrapAny(error: error)
                    self.logger.error("\(self.logPrefix) sendRopesRequest pccError=\(pccError) from error=\(error)")
                    self.incomingUserDataReader.finish(error: pccError)
                    self.progressReader.finish()
                    self.outgoingUserDataWriter.cancelAllWrites(error: pccError)
                    await self.requestMetrics.requestFinished(error: pccError)
                    self.eventStreamContinuation.yield(.trustedRequestCompleted(featureId: self.configuration.featureID, error: pccError))
                    throw pccError
                }
            }
        }
    }

    // MARK: - Private Methods -

    private enum RunSubTask {
        case ropesRequestDidFinish(Result<Void, any Error>)
        case dataSubstreamDidFinish(Result<Void, any Error>)
        case responseBypassSubstreamDidFinish(Result<Void, any Error>)
        case nodeSubstreamsDidFinish(Result<Void, any Error>)
        case connectionMetricsReportingDidFinish
    }

    private func runRequest() async throws {
        scheduleServerDrivenConfigurationFetchIfNeeded()

        let sessionCount = try await self.checkRateLimiting()

        let (rootConnectionUpdatesStream, rootConnectionUpdatesContinuation) = AsyncStream<ConnectionUpdate>.makeStream()

        async let _ = {
            await withTaskCancellationHandler {
                for await update in rootConnectionUpdatesStream {
                    self.logger.log("\(self.logPrefix) connection update=\(String(describing: update))")
                    self.progressReader.forward(update)
                }
                self.logger.log("\(self.logPrefix) connection updates monitoring finished")
            } onCancel: {
                // At the end of the outer function (`runRequest`), the `async let` subtask gets
                // canceled because nothing in awaiting for its result.
                self.logger.log("\(self.logPrefix) connection updates monitoring canceled")
                rootConnectionUpdatesContinuation.finish()
            }
        }()

        try await self.connectionFactory.connect(
            parameters: .makeTLSAndHTTPParameters(
                ignoreCertificateErrors: self.configuration.ignoreCertificateErrors,
                forceOHTTP: self.configuration.forceOHTTP,
                useCompression: true,
                bundleIdentifier: self.configuration.bundleID
            ),
            endpoint: .url(self.configuration.endpointURL),
            activity: nil,
            on: .main,
            requestID: self.serverRequestID,
            logComment: self.logComment(.root),
            progressContinuation: rootConnectionUpdatesContinuation,
        ) { inbound, outbound, ohttpStreams, metricsReporter in

            let pendingDataTransferReport = metricsReporter.startDataTransferReport()

            // start network activities first
            self.requestMetrics.attachNetworkActivities(ohttpStreams)

            // We load the one time token (ott) and the cached attestations inside the connection
            // block, since we want to parallelize connection startup, loading the ott and loading
            // the cached attestations to minimize wait time for the user.
            // Remember that the inner block is called before the connection has been established.
            // We'll wait for the connection to fully establish in the first write to it.
            async let asyncLinkedTokenPair = self.requestMetrics.observeAuthTokenFetch {
                try await self.loadLinkedTokenPair()
            }

            // load cached attestations and add them to the sequence of attestations that we should try.
            let cachedNodes = await self.requestMetrics.observeLoadAttestationsFromCache {
                await self.loadCachedAttestations()
            }
            let (unverifiedNodeStream, unverifiedNodeContinuation) = AsyncStream.makeStream(of: ValidatedAttestationOrAttestation.self)
            for cachedAttestation in cachedNodes {
                unverifiedNodeContinuation.yield(cachedAttestation)
            }

            let readyForMoreChunksEvent = AsyncEvent<Void>()
            let ropesInvokeRequestSentEvent = AsyncEvent<Void>()
            let responseBypassContextReceivedEvent = AsyncEvent<Proto_PrivateCloudCompute_ResponseContext>()
            let trustedProxyNodeSelectedEvent = AsyncEvent<Int>()  // the value is ohttp context
            let linkedTokenPair = try await asyncLinkedTokenPair

            let result = await withTaskGroup(of: RunSubTask.self, returning: Result<Void, any Error>.self) { taskGroup in
                self.logger.log("Entered main task group")

                // 1. ropes connection
                taskGroup.addTask {
                    return .ropesRequestDidFinish(
                        await Result {
                            let requestHeaders = try self.makeRopesRequestHeaders(
                                token: linkedTokenPair,
                                sessionCount: sessionCount,
                                cachedAttestations: cachedNodes
                            )

                            try await self.runRopesRequest(
                                requestHeaders: requestHeaders,
                                cachedNodes: cachedNodes,
                                inbound: inbound,
                                outbound: outbound,
                                unverifiedNodeContinuation: unverifiedNodeContinuation,
                                ropesInvokeRequestSentEvent: ropesInvokeRequestSentEvent,
                                readyForMoreChunksEvent: readyForMoreChunksEvent,
                                trustedProxyNodeSelectedEvent: trustedProxyNodeSelectedEvent
                            )
                        }
                    )
                }

                // 2. data stream
                taskGroup.addTask {
                    return .dataSubstreamDidFinish(
                        await Result {
                            try await ropesInvokeRequestSentEvent()
                            try await ohttpStreams.withOHTTPSubStream(
                                ohttpContext: UInt64(self.requestOHTTPContext),
                                standaloneAEADKey: self.configuration.aeadKey,
                                logComment: self.logComment(.data(self.requestOHTTPContext))
                            ) { dataStreamInbound, dataStreamOutbound in
                                try await self.sendLoop(
                                    dataStreamOutbound: dataStreamOutbound,
                                    readyForMoreChunksEvent: readyForMoreChunksEvent,
                                    linkedTokenPair: linkedTokenPair
                                )
                            }
                        }
                    )
                }

                // 2.5 response stream
                if self.configuration.trustedProxyResponseBypass {
                    taskGroup.addTask {
                        return .responseBypassSubstreamDidFinish(
                            await Result {
                                try await self.runResponseBypassStream(
                                    ohttpContext: self.trustedProxyResponseBypassOhttpContext,
                                    responseBypassContextReceivedEvent: responseBypassContextReceivedEvent,
                                    ohttpStreamFactory: ohttpStreams
                                )
                            }
                        )
                    }
                }

                // 3. node streams
                taskGroup.addTask {
                    return .nodeSubstreamsDidFinish(
                        await Result {
                            do {
                                try await self.runNodeStreams(
                                    unverifiedNodeStream,
                                    ropesInvokeRequestSentEvent: ropesInvokeRequestSentEvent,
                                    responseBypassContextReceivedEvent: responseBypassContextReceivedEvent,
                                    trustedProxyNodeSelectedEvent: trustedProxyNodeSelectedEvent,
                                    ohttpStreamFactory: ohttpStreams
                                )

                                if self.configuration.trustedProxyResponseBypass {
                                    // By this point, the node streams having concluded, one of them should have
                                    // given a response bypass. If not, the response bypass task will want to fail.
                                    // Note the event will fire only once; we take advantage
                                    // of that here and throw if there is no response bypass
                                    // received yet.
                                    let fired = responseBypassContextReceivedEvent.fire(throwing: TrustedRequestError(code: .missingResponseBypassContext))
                                    if fired {
                                        self.logger.debug("\(self.logPrefix) No response bypass context received from any node")
                                    }
                                }
                            } catch {
                                if self.configuration.trustedProxyResponseBypass {
                                    // This will cause response bypass task to finish
                                    // Note the event will fire only once; we take advantage
                                    // of that here and throw if there is no response bypass
                                    // received yet.
                                    responseBypassContextReceivedEvent.fire(throwing: error)
                                }
                                throw error
                            }
                        }
                    )
                }

                // 4. connection metrics
                taskGroup.addTask {
                    do {
                        try await metricsReporter.connectionReady
                        self.requestMetrics.reportConnectionReady()
                        if let establishReport = try await metricsReporter.connectionEstablishReport {
                            self.requestMetrics.reportConnectionEstablishReport(
                                NWConnectionEstablishmentReport(establishReport)
                            )
                            self.logger.log("\(self.logPrefix) \(String(reflecting: establishReport))")
                        } else {
                            self.logger.warning("\(self.logPrefix) connection establishment report is unavailable")
                        }
                    } catch {
                        self.requestMetrics.reportConnectionError(error)
                    }
                    return .connectionMetricsReportingDidFinish
                }

                var nodeStreamsError: (any Error)?
                var dataStreamError: (any Error)?
                var responseStreamError: (any Error)?
                var ropesError: (any Error)?

                // if one subtask fails, we need to stop all the other ones by throwing
                while let nextResult = await taskGroup.next() {
                    switch nextResult {
                    case .ropesRequestDidFinish(.success):
                        self.logger.log("\(self.logPrefix) Ropes request finished successfully")
                    // We MUST NOT cancel the taskGroup here! Background:
                    //
                    // `ropesRequestDidFinish` means that we received the trailers from ROPES,
                    // as all node messages are proxied through ROPES, this also means that we
                    // won't receive any further messages in the data or nodes streams.
                    // HOWEVER as we use different tasks for processing the different ohttp-
                    // substreams those messages may not be consumed yet because of different
                    // task schedulings! Cancellation of the still running tasks may lead to
                    // truncation of the response. Cancellation is not necessary anyway, since
                    // the streams have already finished by definition (the ROPES request has
                    // finished).

                    case .ropesRequestDidFinish(.failure(let failure)):
                        self.logger.log("\(self.logPrefix) Ropes request failed. Error: \(failure)")
                        self.logger.debug("\(self.logPrefix) Cancelling main task group")
                        // OutgoingUserDataWriter could be in a state where `withNextOutgoingElement`
                        // is called and suspended from the `sendLoop()`. OutgoingUserDataWriter is looking for
                        // Task cancellations and will resume `withNextOutgoingElement`'s continuation with
                        // CancellationError when it detects one. Then future attempts to `write(message:)`
                        // will result in that CancellationError. But this leads to adopter attempting to write
                        // something to see a not so useful error. So since we now have the actual error here,
                        // we can fail the OutgoingUserDataWriter with that error before it sees the cancellation
                        // so a better error gets propagated to the adopter during next write.
                        // Wrapping the internal error as PrivateCloudComputeError for reporting and for throwing to our clients
                        self.outgoingUserDataWriter.cancelAllWrites(error: PrivateCloudComputeError.wrapAny(error: failure))
                        taskGroup.cancelAll()
                        ropesError = failure

                    case .responseBypassSubstreamDidFinish(.success):
                        self.logger.log("\(self.logPrefix) Response bypass substream task finished successfully")
                        self.requestMetrics.responseBypassStreamFinished()

                    case .responseBypassSubstreamDidFinish(.failure(let failure)):
                        self.logger.log("\(self.logPrefix) Response bypass substream task failed. Error: \(failure)")
                        self.requestMetrics.responseBypassStreamFinished()
                        self.requestMetrics.responseReceivingFailed(error: failure)
                        responseStreamError = failure

                    case .dataSubstreamDidFinish(.success):
                        self.logger.log("\(self.logPrefix) Data substream task finished successfully")

                    case .dataSubstreamDidFinish(.failure(let failure)):
                        self.logger.log("\(self.logPrefix) Data substream task failed. Error: \(failure)")
                        dataStreamError = failure

                    case .nodeSubstreamsDidFinish(.success):
                        self.logger.log("\(self.logPrefix) Node substreams task finished successfully")
                        self.requestMetrics.nodeStreamsFinished()
                        if !self.configuration.trustedProxyResponseBypass {
                            // Means response payload is expected on a node stream and if all them have finished, the
                            // response state could be considered finished as well.
                            self.requestMetrics.responsePayloadReceiveFinished()
                        }

                    case .nodeSubstreamsDidFinish(.failure(let failure)):
                        // Any of these out of the node substreams means we can't make progress
                        if let error = failure as? TrustedRequestError, error.isGroupTerminatingError {
                            // OutgoingUserDataWriter could be in a state where `withNextOutgoingElement`
                            // is called and suspended from the `sendLoop()`. OutgoingUserDataWriter is looking for
                            // Task cancellations and will resume `withNextOutgoingElement`'s continuation with
                            // CancellationError when it detects one. Then future attempts to `write(message:)`
                            // will result in that CancellationError. But this leads to adopter attempting to write
                            // something to see a not so useful error. So since we now have the actual error here,
                            // we can fail the OutgoingUserDataWriter with that error before it sees the cancellation
                            // so a better error gets propagated to the adopter during next write.
                            // Wrapping the internal error as PrivateCloudComputeError for reporting and for throwing to our clients
                            self.outgoingUserDataWriter.cancelAllWrites(error: PrivateCloudComputeError.wrapAny(error: failure))
                            taskGroup.cancelAll()
                        }

                        self.logger.log("\(self.logPrefix) Node substreams task failed. error: \(failure)")
                        self.requestMetrics.nodeStreamsFinished()

                        if !self.configuration.trustedProxyResponseBypass {
                            // Response payload was expected on node's stream
                            self.requestMetrics.responseReceivingFailed(error: failure)
                        }
                        nodeStreamsError = failure

                    case .connectionMetricsReportingDidFinish:
                        self.logger.log("\(self.logPrefix) Connection metrics reporting finished")
                    }
                }

                // TODO: rdar://159331733 (Remove (or restore?) `failedToValidateAllAttestations` error)
                // If we have a `failedToValidateAllAttestations` error from the nodeSubstream task,
                // we should use this error. In all other cases we are interested in what ROPES
                // tells us, as this gives the best signal of what went wrong. But of course only if
                // ropesError is not a cancellation error.
                //
                // We return a Result<Void, any Error> from here, as nonThrowingTaskGroups can
                // currently not throw.
                if let structuredError = nodeStreamsError as? TrustedRequestError,
                    structuredError.isGroupTerminatingError
                {
                    return .failure(structuredError)
                }
                if let ropesError, ropesError as? CancellationError == nil {
                    return .failure(ropesError)
                }
                if let nodeStreamsError, nodeStreamsError as? CancellationError == nil {
                    return .failure(nodeStreamsError)
                }
                if let responseStreamError, responseStreamError as? CancellationError == nil {
                    return .failure(responseStreamError)
                }
                if let dataStreamError, dataStreamError as? CancellationError == nil {
                    return .failure(dataStreamError)
                }
                if ropesError != nil || nodeStreamsError != nil || responseStreamError != nil || dataStreamError != nil {
                    return .failure(CancellationError())
                }
                return .success(())
            }

            let dataTransferReport = await pendingDataTransferReport.collect()
            self.requestMetrics.reportDataTransferReport(dataTransferReport)
            self.logger.log("\(self.logPrefix) \(String(reflecting: dataTransferReport))")

            try result.get()
        }
    }

    private func checkRateLimiting() async throws -> UInt {
        let requestMetadataForRateLimit = RateLimiterRequestMetadata(
            configuration: self.configuration,
            parameters: self.parameters
        )
        if let rateLimitInfo = await self.rateLimiter.rateLimitDenialInfo(now: Date.now, for: requestMetadataForRateLimit, sessionID: configuration.sessionID) {
            // This means the rate limiter does not want us to proceed.
            throw PrivateCloudComputeError(
                code: .deniedDueToRateLimit,
                retryAfterDate: rateLimitInfo.retryAfterDate
            )
        }

        let sessionCount: UInt
        if let sessionID = self.configuration.sessionID {
            sessionCount = await self.rateLimiter.sessionProgress(now: Date.now, for: sessionID)
            self.logger.log("\(self.logPrefix) using session identifier \(sessionID) with progress \(sessionCount)")
        } else {
            sessionCount = 0
            self.logger.log("\(self.logPrefix) no session identifier on request")
        }
        return sessionCount
    }

    private func updateRateLimiting() async {
        let requestMetadataForRateLimit = RateLimiterRequestMetadata(
            configuration: self.configuration,
            parameters: self.parameters
        )

        self.logger.log(
            """
            \(self.logPrefix) updating rate limiter with attribution
            bundleID: \(self.configuration.bundleID)
            originatingBundleID: \(self.configuration.originatingBundleID ?? "nil")
            clientBundleID: \(self.configuration.clientBundleID)
            featureID: \(self.configuration.featureID ?? "nil")
            sessionID: \(self.configuration.sessionID?.uuidString ?? "nil")

            workloadType: \(self.parameters.type)
            workloadTags: \n\(self.parameters.parameters.map { "\t\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
            """
        )
        // This is sent as we run the ropes request outbound send. It
        // is positioned this way so that if any of the non-ropes request
        // work fails, the rate limiter is not charged. But we want to
        // be certain that if there is a possibility ropes sees the
        // outbound request, that we have tracked it.
        await self.rateLimiter.appendSuccessfulRequest(requestMetadata: requestMetadataForRateLimit, sessionID: configuration.sessionID, timestamp: Date.now)
    }

    struct LinkedTokenPair {
        var tokenGrantingToken: Data
        var ott: Data
        var salt: Data
    }

    private func loadLinkedTokenPair() async throws -> LinkedTokenPair {
        let (ltt, ott, salt) = try await self.tokenProvider.requestToken()
        return LinkedTokenPair(
            tokenGrantingToken: ltt,
            ott: ott,
            salt: salt
        )
    }

    func loadCachedAttestations() async -> [ValidatedAttestationOrAttestation] {
        // without store we can't load any attestations
        guard let store = self.attestationStore else {
            self.logger.error("\(self.logPrefix) unable to access attestation store")
            return []
        }
        // get all unexpired attestations
        guard let prefetchParameters = self.parameters.forPrefetching() else {
            self.logger.error("\(self.logPrefix) invalid set of parameters for prefetching")
            return []
        }

        let maxCachedAttestations = self.configuration.maxCachedAttestations
        let cachedAttestations = await store.getAttestationsForRequest(
            nodeKind: .proxy,
            parameters: prefetchParameters,
            serverRequestID: self.serverRequestID,
            maxAttestations: maxCachedAttestations
        )
        self.logger.log("\(self.logPrefix) Total cached attestations from store: \(cachedAttestations.count) maxCachedAttestations: \(maxCachedAttestations)")

        var count = 0
        let result = cachedAttestations.map { (key, validatedAttestation) in
            defer {
                count += 1
            }

            self.logger.log("\(self.logPrefix) creating verified node with identifier: \(key), ohttpcontext: \(count + 10), kind: \(validatedAttestation.nodeKind)")
            return ValidatedAttestationOrAttestation.cachedValidatedAttestation(validatedAttestation, ohttpContext: UInt64(count + 10))
        }
        return result
    }

    private func scheduleServerDrivenConfigurationFetchIfNeeded() {
        if self.configuration.isServerDrivenConfigurationOutdated {
            self.logger.info("Server driven configuration is outdated, scheduling a fetch")
            self.eventStreamContinuation.yield(.fetchServerDrivenConfigurationIfAllowed)
        }
    }

    // MARK: Ropes request

    private func runRopesRequest(
        requestHeaders: HTTPFields,
        cachedNodes: [ValidatedAttestationOrAttestation],
        inbound: ConnectionFactory.Inbound,
        outbound: ConnectionFactory.Outbound,
        unverifiedNodeContinuation: AsyncStream<ValidatedAttestationOrAttestation>.Continuation,
        ropesInvokeRequestSentEvent: AsyncEvent<Void>,
        readyForMoreChunksEvent: AsyncEvent<Void>,
        trustedProxyNodeSelectedEvent: AsyncEvent<Int>
    ) async throws {
        defer { self.logger.debug("\(self.logPrefix(.root)) Finished root connection subtask") }

        let httpRequest = HTTPRequest(
            method: .post,
            scheme: "https",
            authority: self.configuration.trustedRequestHostname,
            path: self.configuration.trustedRequestPath,
            headerFields: requestHeaders
        )

        let invokeRequestMessage = self.makeInvokeRequest(cachedNodes: cachedNodes)
        let framer = Framer()
        let invokeRequestPayload = try framer.frameMessage(invokeRequestMessage)

        await self.updateRateLimiting()

        try await self.requestMetrics.observeSendingRopesRequest(headers: requestHeaders) {
            // the timeout around sending the invoke request, is used as a connection establish
            // timeout, since NW will automatically retry to create a connection, if it could not
            // establish one at first try.
            let timeout: Duration = .seconds(10)
            try await withCancellationAfterTimeout(duration: timeout, clock: self.clock) {
                let begin = self.clock.now
                do {
                    self.logger.log("\(self.logPrefix(.root)) ropes request send")
                    try await outbound.write(
                        content: invokeRequestPayload,
                        contentContext: .init(request: httpRequest),
                        isComplete: true
                    )
                } catch let error where Task.isCancelled && self.clock.now >= begin.advanced(by: timeout) {
                    // The situation here is such that,
                    //   1. The write failed
                    //   2. The current task is cancelled, and
                    //   3. The timeout duration has passed.
                    // Which is enough information for us to reasonably assume that the
                    // timeout occurred. The reason for step 3 is that it's possible for
                    // the whole outer-task to have been cancelled (for instance if the
                    // adopter sent a cancel). In which case we have 1 & 2 but perhaps
                    // not 3.
                    self.logger.error("\(self.logPrefix(.root)) ropes request send has timed out timeout=\(timeout)")
                    throw TrustedRequestError(code: .invokeRequestPayloadSendFailedAndCancelled, underlying: [error])
                }
            }
        }

        ropesInvokeRequestSentEvent.fire()

        try await self.handleRopesConnectionResponses(
            inbound: inbound,
            unverifiedNodeContinuation: unverifiedNodeContinuation,
            readyForMoreChunksEvent: readyForMoreChunksEvent,
            trustedProxyNodeSelectedEvent: trustedProxyNodeSelectedEvent
        )
    }

    private func filter(workloadParameters params: [String: String]) -> [String: String] {
        guard self.configuration.enforceWorkloadParametersFiltering else {
            return params
        }

        let allowed = Workload.allowedParameters
        return params.filter { elm in
            if allowed.contains(elm.key) {
                return true
            } else {
                self.logger.error("\(self.logPrefix) found workload parameter not in allow list: \(elm.key)")
                return false
            }
        }
    }

    internal func makeRopesRequestHeaders(
        token: LinkedTokenPair,
        sessionCount: UInt,
        cachedAttestations: [ValidatedAttestationOrAttestation]
    ) throws -> HTTPFields {
        let filteredWorkloadParameters = filter(workloadParameters: parameters.parameters)
        let workloadParametersAsJSON = try self.jsonEncoder.encode(filteredWorkloadParameters)
        let workloadParametersAsString = String(data: workloadParametersAsJSON, encoding: .utf8) ?? ""

        var headers: HTTPFields = [
            .appleRequestUUID: self.serverRequestID.uuidString,
            .appleClientInfo: self.systemInfo.osInfo,
            .appleWorkload: parameters.type,
            .appleWorkloadParameters: workloadParametersAsString,
            .appleQOS: self.configuration.serverQoS.rawValue,
            .appleBundleID: self.configuration.bundleID,
            .appleSessionProgress: String(sessionCount),
            .contentType: HTTPField.Constants.contentTypeMessageRopesRequest,
            .userAgent: HTTPField.Constants.userAgentTrustedCloudComputeD,
            .authorization: "PrivateToken token=\"\(base64URL(token.ott))\"",
        ]
        if let featureIdentifier = self.configuration.featureID {
            headers[.appleFeatureID] = featureIdentifier
        }
        if let automatedDeviceGroup = self.systemInfo.automatedDeviceGroup {
            headers[.appleAutomatedDeviceGroup] = automatedDeviceGroup
        }
        if let testSignalHeader = self.configuration.testSignalHeader {
            headers[.appleTestSignal] = testSignalHeader
        }
        if let testOptionsHeader = self.configuration.testOptionsHeader {
            headers[.appleTestOptions] = testOptionsHeader
        }
        if let routingGroupAlias = self.configuration.routingGroupAlias {
            headers[.appleRoutingGroupAlias] = routingGroupAlias
        }
        if let value = self.configuration.trustedProxyRoutingGroupAlias {
            headers[HTTPField.Name.appleTrustedProxyRoutingGroupAlias] = value
        }
        if let value = self.configuration.trustedProxyRequestBypass {
            headers[HTTPField.Name.appleTrustedProxyRequestBypass] = value ? "true" : "false"
        }
        if self.configuration.multiTurn {
            headers[.appleMultiTurn] = "true"
        }

        headers[.appleTrustedProxy] = "true"

        if let overrideCellID = self.configuration.overrideCellID {
            // If there is an override cell id, we ALWAYS want to set it, regardless of presence of cached attestations
            headers[.appleServerHint] = overrideCellID

            // We also set a flag to mark that there is an overridden cell id
            headers[.appleServerHintForReal] = "true"
        } else if let node = cachedAttestations.first, let cellID = node.validatedCellID {
            headers[.appleServerHint] = cellID
        }

        self.logger.log("\(self.logPrefix(.root)) sending headers\n\(headers.loggingDescription)")

        return headers
    }

    private func makeInvokeRequest(cachedNodes: [ValidatedAttestationOrAttestation]) -> Proto_Ropes_HttpService_InvokeRequest {
        return .with {
            $0.setupRequest = .with {
                $0.encryptedRequestOhttpContext = UInt32(self.requestOHTTPContext)
                if self.configuration.trustedProxyResponseBypass {
                    $0.trustedProxyResponseBypassOhttpContexts = [UInt32(self.trustedProxyResponseBypassOhttpContext)]
                }
                // This field _must_ be set to ensure the server does not
                // send attestations in lists (which the client does not handle)
                $0.capabilities.attestationStreaming = true
                $0.capabilities.trustedProxyDuplicateFirstRequestChunk = true
                $0.capabilities.trustedProxyRequestNack = true
                $0.attestationMappings = cachedNodes.map { node in
                    return .with {
                        self.logger.log("\(self.logPrefix(.root)) adding prefetched attestation for node: \(node.identifier) ohttpContext: \(UInt32(node.ohttpContext))")
                        $0.nodeIdentifier = node.identifier
                        $0.ohttpContext = UInt32(node.ohttpContext)
                    }
                }
            }
        }
    }

    private func makePrivateCloudComputeSendAuthTokenRequest(
        _ token: LinkedTokenPair
    ) -> Proto_PrivateCloudCompute_PrivateCloudComputeRequest {
        return .with {
            $0.open = .with {
                $0.tokenGrantingToken = token.tokenGrantingToken
                $0.ottSalt = token.salt
                $0.version = self.configuration.multiTurn ? 1 : 0
                if self.featureFlagChecker.isEnabled(PrivateCloudComputeFeatureFlags.applicationDataChunking) {
                    $0.capabilities.applicationDataChunking = .with {
                        $0.size = UInt32(TrustedRequestConstants.maxApplicationDataSizeBeforeChunking)
                    }
                }
                $0.workloadType = self.parameters.type
            }
        }
    }

    private func makePrivateCloudComputeSendApplicationPayloadRequest(
        data: Data
    ) -> Proto_PrivateCloudCompute_PrivateCloudComputeRequest {
        return .with {
            $0.applicationPayload = data
        }
    }

    private func handleRopesConnectionResponses(
        inbound: ConnectionFactory.Inbound,
        unverifiedNodeContinuation: AsyncStream<ValidatedAttestationOrAttestation>.Continuation,
        readyForMoreChunksEvent: AsyncEvent<Void>,
        trustedProxyNodeSelectedEvent: AsyncEvent<Int>
    ) async throws {
        let responseMessageStream =
            inbound
            .compactMap { try self.processResponseContext($0) }
            .deframed(lengthType: UInt32.self, messageType: Proto_Ropes_HttpService_InvokeResponse.self)

        do {
            for try await message in responseMessageStream {
                self.logger.log("\(self.logPrefix(.root)) received message: \(String(describing: message.type))")

                switch message.type {
                case .attestation(let attestation):
                    self.handleAttestation(attestation, continuation: unverifiedNodeContinuation)

                case .readyForMoreChunks:
                    self.requestMetrics.readyForMoreChunks()
                    readyForMoreChunksEvent.fire()

                case .rateLimitConfigurationList(let rateLimitConfigurationList):
                    self.logger.debug("\(self.logPrefix(.root)) received \(rateLimitConfigurationList.rateLimitConfiguration.count) rate limit configurations")
                    self.handleRateLimitConfigurationList(rateLimitConfigurationList)

                case .expiredAttestationList(let expiredAttestationList):
                    self.logger.debug("\(self.logPrefix(.root)) received expired attestation message for parameters  \(String(describing: self.parameters)). Will refresh attestations out of band")
                    self.eventStreamContinuation.yield(.expiredAttestationList(expiredAttestationList, self.parameters))

                case .noFurtherAttestations:
                    // ROPES sends a new message no_further_attestations in the cases:
                    //  (1) cache miss, send the message after sending attestation_list
                    //  (2) cache hit, send the message before sending "trustedProxyNodeSelected" and "readyForMoreChunks".
                    // This means we can use this as the signal that we won't receive any
                    // further attestations from ROPES inside this trusted request.
                    unverifiedNodeContinuation.finish()
                    self.requestMetrics.noFurtherAttestations()

                case .trustedProxyNodeSelected(let proxySelected):
                    self.logger.info("\(self.logPrefix(.root)) trusted proxy node selected ohttpContext=\(proxySelected.ohttpContext)")
                    self.selectedProxyNode.withLock {
                        $0 = Int(proxySelected.ohttpContext)
                    }
                    trustedProxyNodeSelectedEvent.fire(Int(proxySelected.ohttpContext))

                    self.requestMetrics.nodeSelected(ohttpContext: Int(proxySelected.ohttpContext))

                case .revokedAttestationList:
                    break

                case .diagnosticInformation(let info):
                    if info.hasDenyReason {
                        let denyReasonString = "\(info.denyReason)"
                        switch info.denyReason {
                        case .featureidBlocked:
                            let featureIdString = self.configuration.featureID ?? "nil"
                            self.logger.error(
                                "\(self.logPrefix(.root)) unrecognized featureId. This is not a failure, but may become a failure in the future. reason=\(denyReasonString, privacy: .public), featureID=\(featureIdString, privacy: .public)"
                            )

                        case .workloadBlocked:
                            let workloadTypeString = "\(self.parameters.type)"
                            let workloadParameterString = "\(self.parameters.parameters)"
                            self.logger.error("\(self.logPrefix(.root)) request denial: reason=\(denyReasonString, privacy: .public), type=\(workloadTypeString), parameters=\(workloadParameterString)")

                        default:
                            self.logger.error("\(self.logPrefix(.root)) request denial: reason=\(denyReasonString, privacy: .public)")
                        }
                    }

                case nil:
                    break

                case .attestationList, .compressedAttestationList:
                    self.logger.fault("\(self.logPrefix(.root)) attestation response unexpected: \(String(describing: message.type))")

                @unknown default:
                    self.logger.error("\(self.logPrefix(.root)) unknown: \(String(describing: message.type))")
                }
            }

            self.logger.debug("\(self.logPrefix(.root)) Received all messages on ropes stream")
        } catch {
            readyForMoreChunksEvent.fire(throwing: error)
            throw error
        }
    }

    private func processResponseContext(_ received: NWConnectionReceived) throws -> Data? {
        self.logger.log("\(self.logPrefix(.root)) received content: \(String(describing: received.data)), contentContextPresent: \(received.contentContext != nil), isComplete: \(received.isComplete)")

        // the response head and response end are hidden in the contentContext. If there is no
        // contextContext we just forward the data for further processing.
        guard let responseContext = received.contentContext, let httpResponse = responseContext.httpResponse else {
            return received.data
        }

        self.logger.info("\(self.logPrefix(.root)) received headers\n\(httpResponse.headerFields.loggingDescription)")

        if let trailers = responseContext.httpMetadata?.trailerFields {
            self.logger.info("\(self.logPrefix(.root)) received trailers\n\(trailers.loggingDescription)")
        } else {
            self.logger.info("\(self.logPrefix(.root)) received no trailers")
        }

        if received.isComplete {
            try self.processRopesResponseEnd(httpResponse, contentContext: responseContext)
        } else {
            do {
                try self.processRopesResponseHead(httpResponse, contentContext: responseContext)
                self.requestMetrics.ropesConnectionResponseReceived(response: httpResponse, error: nil)
            } catch {
                self.requestMetrics.ropesConnectionResponseReceived(response: httpResponse, error: error)
                throw error
            }
        }

        return received.data
    }

    // This will produce a rate limit filter that is narrowly targeted at
    // requests "of this type," more or less meaning that other requests
    // should not be impacted by a retry-after response; only substantially
    // similar requests. This is a spec change, in response to:
    // rdar://128609738 (CARRY 22 (in 24h) unexpected errors "DeniedDueToRateLimit: a rate limit of zero is in place for requests of this type")
    private func specificRateLimitFilter() -> RateLimitFilter {
        let bundleID = self.configuration.bundleID
        let featureID = self.configuration.featureID
        let workloadType = self.parameters.type
        let workloadParams = self.filter(workloadParameters: self.parameters.parameters)
        return RateLimitFilter(bundleID: bundleID, featureID: featureID, workloadType: workloadType, workloadParams: workloadParams)
    }

    private func processRopesResponseHead(_ response: HTTPResponse, contentContext: NWConnection.ContentContext) throws {
        // If it is a bad request, ROPES will fail it with a non-200 response and send errors in headers

        let responseMetadata = RopesResponseMetadata(response, contentContext: contentContext)
        self.logger.debug("\(self.logPrefix) \(responseMetadata.loggingDescription)")
        if responseMetadata.isAvailabilityConcern, let retryAfter = responseMetadata.retryAfter {
            let rateLimitConfig = RateLimitConfiguration(
                filter: self.specificRateLimitFilter(),
                timing: .init(
                    now: Date.now,
                    retryAfter: retryAfter,
                    config: self.configuration
                )
            )
            self.eventStreamContinuation.yield(.rateLimitConfigurations([rateLimitConfig]))
        }

        if responseMetadata.code != .ok {
            throw PrivateCloudComputeError(responseMetadata: responseMetadata)
        }
    }

    private func processRopesResponseEnd(_ response: HTTPResponse, contentContext: NWConnection.ContentContext) throws {
        // If it is a bad request, ROPES will fail it with a non-200 response and send errors in headers
        // If for whatever reason, after sending the initial 200 OK, there is an error, ROPES indicates that in trailers
        // Responses/Trailers from ROPES can contain these headers:
        //  “status” response header contains the gRPC status code of the error
        //  “error-code” response header contains ropes-defined error codes
        //  “description” response header contains the description of the error. This header might not be set in production environments
        //  “cause” response header contains a short description of the cause of the error. This header might not be set in production environments
        //  “retry-after” response headers contains the number of seconds that the client should wait before retrying
        //  "ttr-*" response headers contains the context of a Tap-to-radar indication from ROPES
        //  "apple-component-time-measurement" response header contains component timing measurements from ROPES

        let responseMetadata = RopesResponseMetadata(response, contentContext: contentContext)
        self.logger.debug("\(self.logPrefix) \(responseMetadata.loggingDescription)")
        self.requestMetrics.gatewayStreamFinished()

        for measurement in responseMetadata.componentTimeMeasurements {
            self.logger.debug("\(self.logPrefix) Received component time measurement on gateway stream: \(measurement)")
            self.eventStreamContinuation.yield(.componentTimeMeasurementReceived(clientRequestID: self.clientRequestID, source: .json(measurement)))
        }

        if responseMetadata.isAvailabilityConcern, let retryAfter = responseMetadata.retryAfter {
            let rateLimitConfig = RateLimitConfiguration(
                filter: self.specificRateLimitFilter(),
                timing: .init(
                    now: Date.now,
                    retryAfter: retryAfter,
                    config: self.configuration
                )
            )
            self.eventStreamContinuation.yield(.rateLimitConfigurations([rateLimitConfig]))
        }

        #if os(iOS)
        if let ttrTitle = responseMetadata.ttrTitle, self.configuration.environment != TC2Environment.production.name {
            // contains ttr title, meaning that server wants us to prompt ttr
            let ttrContext = TapToRadarContext(
                ttrTitle: ttrTitle,
                ttrDescription: responseMetadata.ttrDescription,
                ttrComponentID: responseMetadata.ttrComponentID,
                ttrComponentName: responseMetadata.ttrComponentName,
                ttrComponentVersion: responseMetadata.ttrComponentVersion
            )
            self.eventStreamContinuation.yield(.tapToRadarIndicationReceived(context: ttrContext))
        }
        #endif

        // check that ROPES didn't mark the request as failed in the trailers.
        if responseMetadata.status != .ok || responseMetadata.receivedErrorCode != .code(.success) {
            self.logger.error(
                """
                \(self.logPrefix) ROPES response indicates a failure
                status: \("\(nilStringIfNil(responseMetadata.status))", privacy: .public)
                receivedErrorCode: \("\(nilStringIfNil(responseMetadata.receivedErrorCode))", privacy: .public)
                trailers:\n\(contentContext.httpMetadata?.trailerFields?.loggingDescription ?? "nil")
                """
            )
            throw PrivateCloudComputeError(responseMetadata: responseMetadata)
        }
    }

    private func handleAttestation(
        _ attestation: Proto_Ropes_Common_Attestation,
        continuation: AsyncStream<ValidatedAttestationOrAttestation>.Continuation
    ) {
        self.logger.debug("\(self.logPrefix) attestation ohttpContext=\(attestation.ohttpContext)")
        let mappedAttestation = Attestation(
            attestation: attestation,
            requestParameters: self.parameters
        )
        let mapped = ValidatedAttestationOrAttestation.inlineAttestation(
            mappedAttestation,
            ohttpContext: UInt64(attestation.ohttpContext)
        )

        if !attestation.nodeIdentifier.isEmpty && mappedAttestation.nodeID != attestation.nodeIdentifier {
            self.logger.error("\(self.logPrefix) node id does not match attestation bundle calculated=\(mappedAttestation.nodeID) fromServer=\(attestation.nodeIdentifier) bundleSize=\(attestation.attestationBundle.count) bytes")
        }

        self.requestMetrics.attestationsReceived(CollectionOfOne(mapped))
        continuation.yield(mapped)

        // NOTE: do not cache attestation. See: rdar://124965521 (Attestations received in response to an invoke should not be cached)
        // Attestations should only be added as a result of prefetching.
    }

    private func handleRateLimitConfigurationList(
        _ rateLimitConfigs: Proto_Ropes_RateLimit_RateLimitConfigurationList
    ) {
        let list = rateLimitConfigs.rateLimitConfiguration.compactMap { proto in
            if let rateLimitConfig = RateLimitConfiguration(
                now: Date.now,
                proto: proto,
                config: self.configuration
            ) {
                return rateLimitConfig
            } else {
                self.logger.error("\(self.logPrefix) unable to process rate limit configuration \(String(describing: proto))")
                return nil
            }
        }
        self.eventStreamContinuation.yield(.rateLimitConfigurations(list))
    }

    // MARK: Send data stream

    private func sendLoop(
        dataStreamOutbound: ConnectionFactory.OHTTPSubStreamFactory.Outbound,
        readyForMoreChunksEvent: AsyncEvent<Void>,
        linkedTokenPair: LinkedTokenPair
    ) async throws {
        let logContext = LogContext.data(self.requestOHTTPContext)
        var readyForMoreChunks: Bool = false
        var budget = TrustedRequestConstants.maxDataToSendBeforeReadyForMoreChunksReceived
        let framer = Framer()

        try await self.requestMetrics.observeAuthTokenSend {
            let authMessage = self.makePrivateCloudComputeSendAuthTokenRequest(linkedTokenPair)
            let authFrame = try framer.frameMessage(authMessage)
            budget -= authFrame.count

            self.logger.debug("\(self.logPrefix(logContext)) Sending auth message on data stream. Remaining budget before ready for more chunks: \(budget)")

            try await dataStreamOutbound.write(
                content: authFrame,
                contentContext: .defaultMessage,
                isComplete: false
            )
        }

        var firstSubrequest = true
        var userStreamIsFinished = false
        while !userStreamIsFinished {
            try await self.outgoingUserDataWriter.withNextOutgoingElement { outgoingUserData in
                self.logger.debug("\(self.logPrefix(logContext)) Received user data to forward to server")
                self.requestMetrics.receivedOutgoingUserData(outgoingUserData: outgoingUserData)

                if outgoingUserData.isComplete {
                    userStreamIsFinished = true
                    if case .data(let data, _) = outgoingUserData, data.isEmpty {
                        // If we are in the last message of a not multi-turn request and don't need
                        // to transfer any more data, we must not wrap the nothing data in a payload
                        // request proto. Instead we only need to signal to the network stack, that
                        // write has completed.
                        // In multi-step requests we've been asked to send `finalMessage`.
                        return try await dataStreamOutbound.write(
                            content: nil,
                            contentContext: .defaultMessage,
                            isComplete: true
                        )
                    }
                }

                var outgoingMessage: Proto_PrivateCloudCompute_PrivateCloudComputeRequest?
                switch outgoingUserData {
                case .data(let data, _):
                    // non multi-turn request
                    outgoingMessage = self.makePrivateCloudComputeSendApplicationPayloadRequest(
                        data: data
                    )
                case .openSubrequest(let subrequestId, let priority, let opaqueCryptoMaterial):
                    self.logger.debug("\(self.logPrefix(logContext)) openSubrequest subrequestId=\(subrequestId), priority=\(String(describing: priority), privacy: .public), opaqueCryptoMaterial=\(opaqueCryptoMaterial, privacy: .sensitive)")

                    let oneTimeToken: Data
                    if firstSubrequest {
                        self.logger.debug("\(self.logPrefix(logContext)) First subrequest, using initial OTT")
                        // For the first subrequest use the same OTT we sent to ROPES.
                        oneTimeToken = linkedTokenPair.ott
                        firstSubrequest = false
                    } else {
                        // Consecutive subrequest needs its own OTT.
                        self.logger.debug("\(self.logPrefix(logContext)) Consecutive subrequest, fetching OTT")
                        let asyncLinkedTokenPair = try await self.requestMetrics.observeSubrequestAuthTokenFetch(subrequestId: subrequestId) {
                            try await self.loadLinkedTokenPair()
                        }
                        oneTimeToken = asyncLinkedTokenPair.ott
                    }
                    outgoingMessage = .with { message in
                        message.subOpen.subrequestID = subrequestId
                        message.subOpen.priority = .init(priority)
                        message.subOpen.opaqueCryptoMaterial = opaqueCryptoMaterial.map { .init(opaqueCryptoMaterial: $0) }
                        message.subOpen.oneTimeToken = oneTimeToken
                    }
                case .subrequestData(let subrequestId, let data):
                    self.logger.debug("\(self.logPrefix(logContext)) subrequestData subrequestId=\(subrequestId)")
                    outgoingMessage = .with {
                        $0.payloadChunk.subrequestID = subrequestId
                        $0.payloadChunk.chunkData = data
                    }
                case .closeSubrequest(let subrequestId):
                    self.logger.debug("\(self.logPrefix(logContext)) closeSubrequest subrequestId=\(subrequestId)")
                    outgoingMessage = .with {
                        $0.subClose.subrequestID = subrequestId
                    }
                case .cancelSubrequest(let subrequestId):
                    self.logger.debug("\(self.logPrefix(logContext)) cancelSubrequest subrequestId=\(subrequestId)")
                    outgoingMessage = .with {
                        $0.subCancel.subrequestID = subrequestId
                    }

                case .final:
                    self.logger.debug("\(self.logPrefix(logContext)) final")
                    outgoingMessage = .with {
                        $0.finalMessage = .init()
                    }
                }

                guard let outgoingMessage else {
                    return
                }

                let message = try framer.frameMessage(outgoingMessage, randomizedPaddingMaxSize: self.configuration.maxProtobufRandomizedPaddingSize)

                if readyForMoreChunks {
                    self.logger.debug("\(self.logPrefix(logContext)) Sending message on data stream, ready for more chunks received")
                    try await self.requestMetrics.observeDataWrite(bytesToSend: message.count) {
                        try await dataStreamOutbound.write(
                            content: message,
                            contentContext: .defaultMessage,
                            isComplete: outgoingUserData.isComplete
                        )
                    }
                    self.requestMetrics.wroteOutgoingUserData(outgoingUserData: outgoingUserData, inBudget: true)
                } else {
                    if message.count <= budget {  // do we fit into our budget
                        self.logger.debug("\(self.logPrefix(logContext)) Sending message on data stream, within initial budget: \(budget)")
                        try await self.requestMetrics.observeDataWrite(bytesToSend: message.count, inBudget: true) {
                            try await dataStreamOutbound.write(
                                content: message,
                                contentContext: .defaultMessage,
                                isComplete: outgoingUserData.isComplete
                            )
                        }
                        self.requestMetrics.wroteOutgoingUserData(outgoingUserData: outgoingUserData, inBudget: true)
                        budget -= message.count
                    } else {
                        self.logger.debug("\(self.logPrefix(logContext)) Sending message on data stream (\(message.count) bytes), above initial budget: \(budget) bytes")
                        let dataToSendOnceReadyForMoreChunks: Data
                        // we are over budget
                        if budget > 0 {
                            // send what we can
                            let prefix = message.prefix(budget)
                            try await self.requestMetrics.observeDataWrite(bytesToSend: prefix.count, inBudget: false) {
                                try await dataStreamOutbound.write(
                                    content: prefix,
                                    contentContext: .defaultMessage,
                                    isComplete: false
                                )
                            }
                            dataToSendOnceReadyForMoreChunks = message.dropFirst(prefix.count)
                        } else {
                            dataToSendOnceReadyForMoreChunks = message
                        }

                        self.logger.debug("\(self.logPrefix(logContext)) Waiting on ready for more chunks signal")
                        try await readyForMoreChunksEvent()
                        readyForMoreChunks = true
                        self.logger.debug("\(self.logPrefix(logContext)) Ready for more chunks received")

                        try await self.requestMetrics.observeDataWrite(
                            bytesToSend: dataToSendOnceReadyForMoreChunks.count,
                            inBudget: false
                        ) {
                            try await dataStreamOutbound.write(
                                content: dataToSendOnceReadyForMoreChunks,
                                contentContext: .defaultMessage,
                                isComplete: outgoingUserData.isComplete
                            )
                        }
                        self.requestMetrics.wroteOutgoingUserData(outgoingUserData: outgoingUserData, inBudget: false)
                    }
                }
            }
        }
        self.logger.log("\(self.logPrefix(logContext)) Finished sending all user data")
        self.requestMetrics.dataStreamFinished()
    }

    // MARK: Node streams

    private enum ControlledNodeSubtaskResult {
        case finished
        case verifyAttestationFailed(any Error)
    }

    private enum NodeControllerOrStreamSubtaskResult {
        /// Means communication with the actual node has finished.
        case nodeStreamFinished
        case verifyAttestationFailed(any Error)
    }

    private func runNodeStreams(
        _ maybeUnverifiedNodeStream: AsyncStream<ValidatedAttestationOrAttestation>,
        ropesInvokeRequestSentEvent: AsyncEvent<Void>,
        responseBypassContextReceivedEvent: AsyncEvent<Proto_PrivateCloudCompute_ResponseContext>,
        trustedProxyNodeSelectedEvent: AsyncEvent<Int>,
        ohttpStreamFactory: ConnectionFactory.OHTTPSubStreamFactory
    ) async throws {
        defer { self.logger.debug("\(self.logPrefix) Leaving runNodesStreams") }

        let (reportableNodeUdidStream, reportableNodeUdidContinuation) = AsyncStream.makeStream(of: String.self)
        async let reportableNodeUdidTask: Void = {
            // Here we consume the hardware identifiers of attestations as they are
            // validated by the node streams in their separate tasks. When the tasks
            // are concluded and we know that no further validation will happen, the
            // stream finishes and we publish to the event stream that tracks the
            // distribution of nodes. See rdar://135384108 for details.
            var reportableNodeUniqueDeviceIds: [String] = []
            reportableNodeUniqueDeviceIds.reserveCapacity(32)
            for await udid in reportableNodeUdidStream {
                reportableNodeUniqueDeviceIds.append(udid)
            }
            self.requestMetrics.inlineAttestationsValidated(reportableNodeUniqueDeviceIds)
        }()

        let result = await withTaskGroup(
            of: (ohttpContext: UInt64, result: Result<ControlledNodeSubtaskResult, any Error>).self,
            returning: Result<Void, any Error>.self
        ) { taskGroup in
            var runningNodeIDs: Set<String> = []
            var inlineNodeIDs: Set<String> = []
            runningNodeIDs.reserveCapacity(32)  // skip first reallocs
            inlineNodeIDs.reserveCapacity(32)

            for await node in maybeUnverifiedNodeStream {
                let logContext = LogContext.node(Int(node.ohttpContext))
                if case .inlineAttestation = node {
                    if inlineNodeIDs.count >= self.configuration.maxInlineAttestations {
                        let count = inlineNodeIDs.count
                        // TODO: consider storing this attestation somewhere so we can log it in thtool requests, etc.; probably overkill though.
                        self.logger.error("\(self.logPrefix(logContext)) ignoring node \(node.identifier); already have \(count) attestations out of \(self.configuration.maxTotalAttestations) max")
                        continue
                    }

                    inlineNodeIDs.insert(node.identifier)
                }

                if runningNodeIDs.contains(node.identifier) {
                    self.logger.debug("\(self.logPrefix(logContext)) already have a node with identifier \(node.identifier), conflict")
                    continue
                }

                if runningNodeIDs.count >= self.configuration.maxTotalAttestations {
                    let count = runningNodeIDs.count
                    // TODO: consider storing this attestation somewhere so we can log it in thtool requests, etc.; probably overkill though.
                    self.logger.error("\(self.logPrefix(logContext)) ignoring node \(node.identifier); already have \(count) attestations out of \(self.configuration.maxTotalAttestations) max")
                    continue
                }

                runningNodeIDs.insert(node.identifier)

                taskGroup.addTask {
                    // The cancellation handler is merely for logging
                    await withTaskCancellationHandler {
                        self.logger.log("\(self.logPrefix(logContext)) Creating node stream subtask for node: \(node.identifier) cloudOSVersion:\(node.cloudOSVersion)")

                        defer { self.logger.debug("\(self.logPrefix(logContext)) Leaving node stream subtask for node: \(node.identifier)") }
                        return await withTaskGroup(
                            of: Result<NodeControllerOrStreamSubtaskResult, any Error>.self,
                            returning: (ohttpContext: UInt64, result: Result<ControlledNodeSubtaskResult, any Error>).self
                        ) { taskGroup in
                            let ohttpContext: UInt64 = node.ohttpContext

                            taskGroup.addTask {
                                let validatedAttestation: ValidatedAttestation
                                switch node {
                                case .cachedValidatedAttestation(let attestation, _):
                                    validatedAttestation = attestation

                                case .inlineAttestation(let attestation, _):
                                    self.logger.log("\(self.logPrefix(logContext)) verifying attestation")
                                    // the state after verify attestation is set in `verifyAttestation(node:)`
                                    do {
                                        validatedAttestation = try await self.verifyAttestation(attestation: attestation)
                                        if let udid = validatedAttestation.udid {
                                            reportableNodeUdidContinuation.yield(udid)
                                        }
                                    } catch {
                                        return .success(.verifyAttestationFailed(error))
                                    }
                                }

                                return await Result {
                                    // the sentKey state is set in `runNodeRequest(...)`
                                    try await self.runNodeRequest(
                                        validatedAttestation: validatedAttestation,
                                        ohttpContext: ohttpContext,
                                        ropesInvokeRequestSentEvent: ropesInvokeRequestSentEvent,
                                        responseBypassContextReceivedEvent: responseBypassContextReceivedEvent,
                                        ohttpStreamFactory: ohttpStreamFactory
                                    )
                                    return .nodeStreamFinished
                                }
                            }

                            let subtaskResult = await taskGroup.next()!
                            taskGroup.cancelAll()  // cancel the sibling
                            let result: Result<ControlledNodeSubtaskResult, any Error> = subtaskResult.map {
                                switch $0 {
                                case .nodeStreamFinished:
                                    return .finished
                                case .verifyAttestationFailed(let error):
                                    return .verifyAttestationFailed(error)
                                }
                            }
                            return (ohttpContext, result)
                        }
                    } onCancel: {
                        // I want to know when a cancellation comes in from above; in contrast to the
                        // situation where the subtasks cancel each other.
                        self.logger.log("\(self.logPrefix(logContext)) Node stream subtask has been cancelled for node: \(node.identifier)")
                    }
                }  // end node subtask group
            }  // end node for loop

            self.logger.debug("\(self.logPrefix) Not expecting more attestations. Running with \(runningNodeIDs.count) attestations")

            var errorsPerOhttpContext: [UInt64: (any Error)] = [:]

            var completed = 0
            while let (ohttpContext, result) = await taskGroup.next() {
                completed += 1
                self.logger.debug("\(self.logPrefix) Node substream task finished. Remaining: \(runningNodeIDs.count - completed)")
                switch result {
                case .success(.verifyAttestationFailed(let error)):
                    errorsPerOhttpContext[ohttpContext] = error

                case .success(.finished):
                    break

                case .failure(let taskError):
                    errorsPerOhttpContext[ohttpContext] = taskError
                }

                // Do we already know which proxy node is selected?
                if let selected = selectedProxyNode.withLock({ $0 }) {
                    // Did it happen to fail?
                    if errorsPerOhttpContext[UInt64(selected)] != nil {
                        // Don't wait for remaining node streams (if any).
                        self.logger.debug("\(self.logPrefix) Cancelling all node substreams as the selected proxy node failed. selectedProxyOhttpContext=\(selected)")
                        taskGroup.cancelAll()
                    }
                }
            }

            self.logger.debug("\(self.logPrefix) All \(runningNodeIDs.count) node substreams have finished")
            defer { self.logger.debug("\(self.logPrefix) Leaving runNodesStreams taskGroup") }

            do {
                let selectedProxyOhttpContext = Int(try await trustedProxyNodeSelectedEvent())
                if let error = errorsPerOhttpContext[UInt64(selectedProxyOhttpContext)] {
                    return .failure(error)
                } else {
                    return .success(())
                }
            } catch {
                return .failure(error)
            }
        }

        reportableNodeUdidContinuation.finish()
        await reportableNodeUdidTask

        try result.get()
    }

    private let selectedProxyNode = Mutex<Int?>(nil)

    private func verifyAttestation(attestation: Attestation) async throws -> ValidatedAttestation {
        try await self.requestMetrics.observeAttestationVerify(
            nodeID: attestation.nodeID
        ) {
            do {
                let validatedAttestation = try await self.attestationVerifier.validate(attestation: attestation, expectedNodeKind: .proxy)
                self.logger.log("\(self.logPrefix) attestation success with package key \(validatedAttestation.publicKey), validationExpiration: \(validatedAttestation.attestationExpiry)")
                return validatedAttestation
            } catch {
                self.logger.log("\(self.logPrefix) attestation failure with error \(error)")
                throw error
            }
        }
    }

    private func runNodeRequest(
        validatedAttestation: ValidatedAttestation,
        ohttpContext: UInt64,
        ropesInvokeRequestSentEvent: AsyncEvent<Void>,
        responseBypassContextReceivedEvent: AsyncEvent<Proto_PrivateCloudCompute_ResponseContext>,
        ohttpStreamFactory: ConnectionFactory.OHTTPSubStreamFactory
    ) async throws {
        let logContext = LogContext.node(Int(ohttpContext))
        let nodeID = validatedAttestation.attestation.nodeID

        self.logger.log("\(self.logPrefix(logContext)) starting node stream to \(nodeID); creating request...")

        return try await ohttpStreamFactory.withOHTTPSubStream(
            ohttpContext: ohttpContext,
            gatewayKeyConfig: validatedAttestation.publicKey,
            mediaType: "application/protobuf",
            logComment: self.logComment(logContext)
        ) { nodeInbound, nodeOutbound in
            // we must ensure that the ropes invoke request got send in the http request first.
            try await ropesInvokeRequestSentEvent()

            // we send our aead key first
            try await self.requestMetrics.observeSendingKeyToNode(nodeID: nodeID) {
                try await nodeOutbound.write(
                    content: self.configuration.aeadKey,
                    contentContext: .defaultMessage,
                    isComplete: true
                )
            }

            // now lets consume all responses
            let deframed =
                nodeInbound
                .compactMap { $0.data }
                .deframed(
                    lengthType: UInt32.self,
                    messageType: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.self
                )

            var isFirstMessage = true
            var isFinalRELEntryReceived = false

            // For multi-turn requests we expect to receive `subOpen`, one or more `payloadChunk`, and `subClose` per each subrequest.
            // For non multi-turn requests we expect response data coming in a for of one or more `responsePayload`.
            receiveLoop: for try await message in deframed {
                self.logger.debug("\(self.logPrefix(logContext)) Received message from node \(nodeID): \(String(describing: message.type))")
                if isFirstMessage {
                    self.requestMetrics.nodeFirstResponseReceived(nodeID: nodeID)
                    isFirstMessage = false
                }

                var incomingUserData: IncomingUserData?

                switch message.type {
                case .responseUuid(let uuidData):
                    self.logger.debug("\(self.logPrefix(logContext)) Received responseUuid. Ignoring. uuidData=\(uuidData)")

                case .subOpen(let message):
                    self.logger.debug("\(self.logPrefix(logContext)) Received subOpen subrequestId=\(message.subrequestID)")
                    incomingUserData = .openSubresponse(message.subrequestID)

                case .payloadChunk(let payload):
                    self.logger.debug("\(self.logPrefix(logContext)) Received payload \(payload.chunkData.count) bytes subrequestId=\(payload.subrequestID)")
                    self.requestMetrics.responsePayloadReceived(bytes: payload.chunkData.count, nodeID: nodeID)
                    incomingUserData = .subresponseData(payload.subrequestID, payload.chunkData)

                case .subClose(let message):
                    self.logger.debug("\(self.logPrefix(logContext)) Received subClose subrequestId=\(message.subrequestID), status=\(String(describing: message.status))")
                    incomingUserData = .closeSubresponse(message.subrequestID, .init(message.status))

                case .responseSummary(let responseSummary):
                    self.logger.debug("\(self.logPrefix(logContext)) Response summary: \(responseSummary.loggingDescription)")
                    do {
                        try checkResponseSummaryError(responseSummary)
                        self.requestMetrics.nodeSummaryReceived(nodeID: nodeID, error: nil)
                    } catch {
                        self.requestMetrics.nodeSummaryReceived(nodeID: nodeID, error: error)
                        throw error
                    }

                case .responsePayload(let payload):
                    self.logger.debug("\(self.logPrefix(logContext)) Received payload \(payload.count) bytes from node")
                    self.requestMetrics.responsePayloadReceived(bytes: payload.count, nodeID: nodeID)
                    incomingUserData = .data(payload)

                case .requestExecutionLogEntry(let entry):
                    self.logger.debug("\(self.logPrefix(logContext)) Received request execution log entry: \(entry.loggingDescription)")
                    if entry.hasAttestation {
                        let proxiedAttestation = ProxiedAttestation(attestationBundle: entry.attestation)
                        self.requestMetrics.proxiedAttestationReceived(proxiedAttestation: proxiedAttestation, proxiedBy: nodeID)
                    }
                    for proto in entry.assetMetadata {
                        let asset = AssetMetadata(proto: proto)
                        self.requestMetrics.executionAssetReceived(asset)
                    }
                    if entry.final {
                        isFinalRELEntryReceived = true
                        self.requestMetrics.nodeRequestExecutionLogFinalized(nodeID: nodeID)
                    }
                    if entry.hasResponseContext {
                        if self.configuration.trustedProxyResponseBypass {
                            self.logger.debug("\(self.logPrefix(logContext)) received AEAD for response bypass contextID=\(entry.responseContext.contextID)")
                            responseBypassContextReceivedEvent.fire(entry.responseContext)
                        } else {
                            throw TrustedRequestError(code: .unexpectedlyReceivedResponseBypassContext)
                        }
                    }

                case .componentTimeMeasurement(let measurement):
                    self.logger.debug("\(self.logPrefix(logContext)) Received component time measurement on node stream: \(measurement.loggingDescription)")
                    self.eventStreamContinuation.yield(
                        .componentTimeMeasurementReceived(
                            clientRequestID: self.clientRequestID,
                            source: .proto(measurement)
                        )
                    )

                case nil:
                    // TBD: Should we fail the request here. Not getting a type looks like a
                    //      protocol error from the server.
                    break

                @unknown default:
                    break
                }

                if let incomingUserData {
                    try throwIfResponseBypassIsOn(logContext: logContext)
                    self.requestMetrics.receivedIncomingUserData(incomingUserData: incomingUserData)
                    try await self.incomingUserDataReader.forwardData(incomingUserData)
                }
            }

            if !isFinalRELEntryReceived {
                self.logger.error("\(self.logPrefix(logContext)) Didn't receive final request execution log entry nodeID=\(nodeID)")
            }

            self.requestMetrics.nodeResponseFinished(nodeID: nodeID)
            self.logger.debug("\(self.logPrefix(logContext)) Received all messages in node stream: \(nodeID)")
        }
    }

    private func throwIfResponseBypassIsOn(logContext: LogContext) throws {
        if self.configuration.trustedProxyResponseBypass {
            self.logger.error("\(self.logPrefix(logContext)) Trusted proxy request did not expect response on node stream")
            throw TrustedRequestError(code: .expectedResponseOnBypass)
        }
    }

    private func runResponseBypassStream(
        ohttpContext: Int,
        responseBypassContextReceivedEvent: AsyncEvent<Proto_PrivateCloudCompute_ResponseContext>,
        ohttpStreamFactory: ConnectionFactory.OHTTPSubStreamFactory
    ) async throws {
        let logContext = LogContext.responseBypass(ohttpContext)
        self.logger.log("\(self.logPrefix(logContext)) starting response bypass context=\(ohttpContext)")

        return try await ohttpStreamFactory.withOHTTPSubStream(
            ohttpContext: UInt64(ohttpContext),
            logComment: self.logComment(logContext),
            aeadDelivery: {
                let response = try await responseBypassContextReceivedEvent()
                return (aeadKey: response.aeadKey, aeadNonce: response.aeadNonce)
            },
            body: { inbound in
                // Read the response
                let deframed =
                    inbound
                    .compactMap { $0.data }
                    .deframed(
                        lengthType: UInt32.self,
                        messageType: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.self
                    )

                // For multi-turn requests we expect to receive `subOpen`, one or more `payloadChunk`, and `subClose` per each subrequest.
                // For non multi-turn requests we expect response data coming in a for of one or more `responsePayload`.
                receiveLoop: for try await message in deframed {
                    self.logger.debug("\(self.logPrefix(logContext)) Received message on response bypass: \(String(describing: message.type))")

                    var incomingUserData: IncomingUserData?

                    switch message.type {
                    case .responseUuid(let uuidData):
                        self.logger.debug("\(self.logPrefix(logContext)) Received responseUuid on response bypass. Ignoring. uuidData=\(uuidData)")

                    case .subOpen(let message):
                        self.logger.debug("\(self.logPrefix(logContext)) Received subOpen subrequestId=\(message.subrequestID)")
                        incomingUserData = .openSubresponse(message.subrequestID)

                    case .payloadChunk(let payload):
                        self.logger.debug("\(self.logPrefix(logContext)) Received payload \(payload.chunkData.count) bytes subrequestId=\(payload.subrequestID)")
                        self.requestMetrics.responsePayloadReceived(bytes: payload.chunkData.count)
                        incomingUserData = .subresponseData(payload.subrequestID, payload.chunkData)

                    case .subClose(let message):
                        self.logger.debug("\(self.logPrefix(logContext)) Received subClose subrequestId=\(message.subrequestID), status=\(String(describing: message.status))")
                        incomingUserData = .closeSubresponse(message.subrequestID, .init(message.status))

                    case .responseSummary(let responseSummary):
                        self.logger.debug("\(self.logPrefix(logContext)) Received responseSummary on response bypass responseSummary=\(responseSummary.loggingDescription)")
                        try checkResponseSummaryError(responseSummary)

                    case .responsePayload(let payload):
                        self.logger.debug("\(self.logPrefix(logContext)) Received payload \(payload.count) bytes on response bypass")
                        self.requestMetrics.responsePayloadReceived(bytes: payload.count)
                        incomingUserData = .data(payload)

                    case .requestExecutionLogEntry(let entry):
                        self.logger.debug("\(self.logPrefix(logContext)) Unexpected requestExecutionLogEntry on response bypass entry=\(entry.loggingDescription)")

                    case .componentTimeMeasurement(let protoValue):
                        self.logger.warning("\(self.logPrefix(logContext)) Unexpected componentTimeMeasurement on response bypass protoValue=\(protoValue.loggingDescription)")

                    case nil:
                        // TBD: Should we fail the request here. Not getting a type looks like a
                        //      protocol error from the server.
                        break

                    @unknown default:
                        break
                    }

                    if let incomingUserData {
                        self.requestMetrics.receivedIncomingUserData(incomingUserData: incomingUserData)
                        try await self.incomingUserDataReader.forwardData(incomingUserData)
                    }
                }

                self.requestMetrics.responsePayloadReceiveFinished()
                self.logger.debug("\(self.logPrefix(logContext)) Received all messages on response bypass")
            }
        )
    }

    private func checkResponseSummaryError(_ responseSummary: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.CloseResponsePayload) throws {
        switch responseSummary.responseStatus {
        case .ok:
            break  // no error
        case .unauthenticated:
            throw TrustedRequestError(code: .responseSummaryIndicatesUnauthenticated)
        case .internalError:
            throw TrustedRequestError(code: .responseSummaryIndicatesInternalError)
        case .invalidRequest:
            throw TrustedRequestError(code: .responseSummaryIndicatesInvalidRequest)
        case .proxyFindWorkerError:
            throw TrustedRequestError(code: .responseSummaryIndicatesProxyFindWorkerError)
        case .proxyWorkerValidationError:
            throw TrustedRequestError(code: .responseSummaryIndicatesProxyWorkerValidationError)
        case .UNRECOGNIZED(_):
            throw TrustedRequestError(code: .responseSummaryIndicatesFailure)
        }
    }
}

enum ValidatedAttestationOrAttestation {
    case cachedValidatedAttestation(ValidatedAttestation, ohttpContext: UInt64)
    case inlineAttestation(Attestation, ohttpContext: UInt64)

    var identifier: String {
        switch self {
        case .cachedValidatedAttestation(let validatedAttestation, _):
            return validatedAttestation.attestation.nodeID
        case .inlineAttestation(let attestation, _):
            return attestation.nodeID
        }
    }

    var ohttpContext: UInt64 {
        switch self {
        case .cachedValidatedAttestation(_, let ohttpContext):
            return ohttpContext
        case .inlineAttestation(_, let ohttpContext):
            return ohttpContext
        }
    }

    var maybeValidatedCellID: String {
        switch self {
        case .cachedValidatedAttestation(let validatedAttestation, _):
            return validatedAttestation.validatedCellID ?? ""
        case .inlineAttestation(let attestation, _):
            return "unvalidated(\(attestation.unvalidatedCellID ?? ""))"
        }
    }

    var validatedCellID: String? {
        switch self {
        case .cachedValidatedAttestation(let validatedAttestation, _):
            return validatedAttestation.validatedCellID
        default:
            return nil
        }
    }

    var cloudOSVersion: String {
        switch self {
        case .cachedValidatedAttestation(let validatedAttestation, _):
            return validatedAttestation.attestation.cloudOSVersion
        case .inlineAttestation(let attestation, _):
            return attestation.cloudOSVersion
        }
    }

    var cloudOSReleaseType: String {
        switch self {
        case .cachedValidatedAttestation(let validatedAttestation, _):
            return validatedAttestation.attestation.cloudOSReleaseType
        case .inlineAttestation(let attestation, _):
            return attestation.cloudOSReleaseType
        }
    }
}

extension Result {
    init(asyncCatching: () async throws(Failure) -> Success) async {
        do {
            self = try await .success(asyncCatching())
        } catch {
            self = .failure(error)
        }
    }
}

extension RopesResponseMetadata {
    init(_ response: HTTPResponse, contentContext: NWConnection.ContentContext) {
        self = RopesResponseMetadata(code: response.status.code)
        for field in response.headerFields {
            self.set(value: field.value, for: field.name.rawName)
        }

        // If we have trailers we need to consume those as well.
        if let trailerFields = contentContext.httpMetadata?.trailerFields {
            for field in trailerFields {
                self.set(value: field.value, for: field.name.rawName)
            }
        }
    }
}

extension NWConnection.ContentContext {
    var httpMetadata: NWProtocolHTTP.Metadata? {
        protocolMetadata(definition: NWProtocolHTTP.definition) as? NWProtocolHTTP.Metadata
    }
}

extension TrustedRequestError {
    fileprivate var isGroupTerminatingError: Bool {
        switch code {
        case .failedToValidateAllAttestations,
            .expectedResponseOnBypass:
            return true
        default:
            return false
        }
    }
}

private func base64URL(_ data: Data) -> String {
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

extension Proto_PrivateCloudCompute_SubrequestExecutionPriority {
    init(_ priority: PrivateCloudComputeConnection.Request.Priority) {
        switch priority {
        case .unspecified:
            self = .requestExecutionPriorityUnspecified
        case .discardable:
            self = .requestExecutionPriorityDiscardable
        }
    }
}

extension Proto_PrivateCloudCompute_OpaqueCryptoMaterial {
    init(opaqueCryptoMaterial: PrivateCloudComputeConnection.Request.OpaqueCryptoMaterial) {
        self.id = opaqueCryptoMaterial.id.uuidString
        self.material = opaqueCryptoMaterial.material
    }
}

extension XPCResponseMessage.SubresponseStatus {
    init(_ status: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.CloseSubresponsePayload.SubresponseStatus) {
        switch status {
        case .ok:
            self = .ok
        case .internalError:
            self = .internalError
        case .invalidRequest:
            self = .invalidRequest
        case .discarded:
            self = .discarded
        case .UNRECOGNIZED(let value):
            self = .unrecognized(value)
        }
    }
}
