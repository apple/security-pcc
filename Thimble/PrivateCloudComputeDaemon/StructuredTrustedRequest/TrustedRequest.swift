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
//  TrustedRequest.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import FeatureFlags
import Foundation
import InternalSwiftProtobuf
@_spi(HTTP) @_spi(OHTTP) import Network
import PrivateCloudCompute
import Synchronization
import os.log

private let logger = Logger(for: .trustedRequest)

protocol IncomingUserDataReaderProtocol: Sendable {
    func forwardData(_ data: IncomingUserData) async throws
    func shutdown(error: any Error)
    func finish(error: (any Error)?)
}

protocol OutgoingUserDataWriterProtocol: Sendable {
    func withNextOutgoingElement<Result>(_ closure: (OutgoingUserData) async throws -> Result) async throws -> Result

    func cancelAllWrites(error: any Error)
    /// Takes a closure that will be called when `cancelAllWrites(error:)` is called.
    /// **Note:** the closure will be called only once and then cleared out. Consecutive calls to
    /// `cancelAllWrites(error:)` will not result in calling this closure again. Also, if the reading gets canceled with
    /// Swift Task cancellation, the closure is cleared out too and consecutive call of `cancelAllWrites(error:)` will
    /// not call it.
    /// Calling this function multiple times will override previously stored closure.
    func registerCancelAllWritesClosure(_ closure: @escaping @Sendable (any Error) -> Void)
}

protocol TrustedRequestXPCEventsObserver: Sendable {
    func cancel(reason: TrustedRequestCancellationReason)
    func createSubrequestFailed(subrequest: XPCSubrequest, error: PrivateCloudComputeError)
}

enum TrustedRequestCancellationReason {
    case frameworkCancellation
    case xpcInvalidation
    case inactivityTimeout

    var privateCloudComputeErrorCode: PrivateCloudComputeError.Code {
        switch self {
        case .frameworkCancellation:
            .cancelledDueToFrameworkCancellation
        case .xpcInvalidation:
            .cancelledDueToXPCInvalidation
        case .inactivityTimeout:
            .cancelledDueToInactivityTimeout
        }
    }
}

final class TrustedRequest<
    OutgoingUserDataWriter: OutgoingUserDataWriterProtocol,
    IncomingUserDataReader: IncomingUserDataReaderProtocol,
    ConnectionFactory: NWAsyncConnectionFactoryProtocol,
    LegacyAttestationStore: LegacyAttestationStoreProtocol,
    AttestationStore: AttestationStoreProtocol,
    AttestationVerifier: AttestationVerifierProtocol,
    RateLimiter: RateLimiterProtocol,
    SystemInfo: SystemInfoProtocol,
    TokenProvider: OneTimeTokenProviderProtocol,
    ReputationTokenProvider: ReputationTokenProviderProtocol,
    WaitlistTokenProvider: WaitlistTokenProviderProtocol,
    FeatureFlagChecker: FeatureFlagCheckerProtocol,
    Reporter: AppleIntelligenceEventReporter,
    Clock: _Concurrency.Clock
>: TrustedRequestXPCEventsObserver, Sendable where Clock.Duration == Duration {
    let clientRequestID: UUID
    let serverRequestID: UUID
    let configuration: TrustedRequestConfiguration
    /// Workload as we receive it from the adopter. Note, that what we actually send to the server
    /// may be different. E.g. we don't let through unknown workload parameters, or we may add
    /// something to it.
    let parameters: Workload
    let stepReporter: AppleIntelligenceStepReporter<Reporter>

    let outgoingUserDataWriter: OutgoingUserDataWriter
    let incomingUserDataReader: IncomingUserDataReader
    let progressReader: TrustedRequestProgressReader
    let connectionFactory: ConnectionFactory
    let attestationStoreOrLegacyStore: AttestationStoreOrLegacyStore<LegacyAttestationStore, AttestationStore>
    let attestationVerifier: AttestationVerifier
    let rateLimiter: RateLimiter
    let systemInfo: SystemInfo
    let tokenProvider: TokenProvider
    let reputationTokenProvider: ReputationTokenProvider?
    let waitlistTokenProvider: WaitlistTokenProvider?
    let clock: Clock
    let jsonEncoder = tc2JSONEncoder()
    let featureFlagChecker: FeatureFlagChecker

    let eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation
    let requestMetrics: RequestMetrics<Clock, LegacyAttestationStore, AttestationStore, SystemInfo, BiomeReporter>

    /// Used to watch for inactivity and gracefully end the request if needed.
    private let inactivityWatchdog: TrustedRequestInactivityWatchdog<Clock>?

    // The request body's OHTTP context
    private let requestOHTTPContext = 1
    private let trustedProxyResponseBypassOhttpContext = 2

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
        stepReporter: AppleIntelligenceStepReporter<Reporter>,
        outgoingUserDataWriter: OutgoingUserDataWriter,
        incomingUserDataReader: IncomingUserDataReader,
        progressReader: TrustedRequestProgressReader,
        connectionFactory: ConnectionFactory,
        attestationStoreOrLegacyStore: AttestationStoreOrLegacyStore<LegacyAttestationStore, AttestationStore>,
        attestationVerifier: AttestationVerifier,
        rateLimiter: RateLimiter,
        systemInfo: SystemInfo,
        tokenProvider: TokenProvider,
        reputationTokenProvider: ReputationTokenProvider?,
        waitlistTokenProvider: WaitlistTokenProvider?,
        requestMetrics: RequestMetrics<Clock, LegacyAttestationStore, AttestationStore, SystemInfo, BiomeReporter>,
        clock: Clock,
        eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation,
        featureFlagChecker: FeatureFlagChecker
    ) {
        self.clientRequestID = clientRequestID
        self.serverRequestID = serverRequestID

        self.configuration = configuration
        self.parameters = parameters
        self.stepReporter = stepReporter

        self.outgoingUserDataWriter = outgoingUserDataWriter
        self.incomingUserDataReader = incomingUserDataReader
        self.progressReader = progressReader
        self.connectionFactory = connectionFactory
        self.attestationStoreOrLegacyStore = attestationStoreOrLegacyStore
        self.attestationVerifier = attestationVerifier
        self.rateLimiter = rateLimiter
        self.systemInfo = systemInfo
        self.tokenProvider = tokenProvider
        self.reputationTokenProvider = reputationTokenProvider
        self.waitlistTokenProvider = waitlistTokenProvider
        self.clock = clock
        self.eventStreamContinuation = eventStreamContinuation
        self.featureFlagChecker = featureFlagChecker
        self.requestMetrics = requestMetrics

        self.requestMetrics.waitlistTokenExpected(waitlistTokenProvider != nil)
        self.requestMetrics.reputationTokenExpected(reputationTokenProvider != nil)

        if let timeout = self.configuration.inactivityTimeout {
            self.inactivityWatchdog = TrustedRequestInactivityWatchdog(clock: clock, timeout: timeout)
        } else {
            self.inactivityWatchdog = nil
        }
    }

    func run() async throws {
        logger.debug("\(self.logPrefix) Running TrustedRequest")
        logger.debug("\(self.logPrefix) Configuration: \(self.configuration)")

        try await PowerAssertion.withPowerAssertion(name: "TC2TrustedRequest") {
            try await self.stepReporter.withStep(.privateCloudComputeRequestInDaemon, requestID: clientRequestID) {

                defer {
                    await self.requestMetrics.logOSLogAndBiomeStreamRequestLog()
                }

                do {
                    try await self.runRequest()
                    self.incomingUserDataReader.finish(error: nil)
                    self.progressReader.finish()
                    self.requestMetrics.requestFinished(error: nil)
                    self.eventStreamContinuation.yield(.trustedRequestCompleted(featureId: self.configuration.featureID, error: nil))
                } catch {
                    // wrapping the internal error as PrivateCloudComputeError for throwing to our clients
                    let pccError = PrivateCloudComputeError.wrapAny(error: error)
                    logger.error("\(self.logPrefix) sendRopesRequest pccError=\(pccError) from error=\(error)")
                    self.incomingUserDataReader.finish(error: pccError)
                    self.progressReader.finish()
                    self.outgoingUserDataWriter.cancelAllWrites(error: pccError)
                    self.requestMetrics.requestFinished(error: pccError)
                    self.eventStreamContinuation.yield(.trustedRequestCompleted(featureId: self.configuration.featureID, error: pccError))
                    throw pccError
                }
            }
        }
    }

    // MARK: - TrustedRequestXPCEventsObserver

    func cancel(reason: TrustedRequestCancellationReason) {
        // Note: this may be called multiple times if request is being cancelled.
        self.requestMetrics.willCancel(reason: reason)
        if self.featureFlagChecker.isEnabled(.requestCancellationV2) {
            logger.debug("\(self.logPrefix) cancelling the request, reason=\(String(describing: reason))")

            // Canceling OutgoingUserDataWriter here means it won't accept any new messages to send from the framework.
            // Note: we cancel it with a certain error code, that is being caught and specially treated inside of the
            // `sendLoop()` making it send `.final` to the server and complete the data stream.
            let error = PrivateCloudComputeError(code: reason.privateCloudComputeErrorCode)
            self.outgoingUserDataWriter.cancelAllWrites(error: error)

            // Switching IncomingUserDataReader to shutdown mode means:
            // * if there is suspended `next()` call from the adopter waiting for more data, it will throw
            //   with the `error`
            // * if there is suspended `forwardData()` from the daemon waiting for adopter to read data,
            //   it will just resume effectively dropping the already received data
            // * future calls to `next()` will throw with the `error`
            // * future calls to `forwardData()` will drop the data and just return
            self.incomingUserDataReader.shutdown(error: error)
        }
    }

    func createSubrequestFailed(
        subrequest: PrivateCloudCompute.XPCSubrequest,
        error: PrivateCloudCompute.PrivateCloudComputeError
    ) {
        self.requestMetrics.createSubrequestFailed(subrequest: subrequest, error: error)
    }

    // MARK: - Private Methods -

    private enum RunSubTask {
        case ropesRequestDidFinish(Result<Void, any Error>)
        case dataSubstreamDidFinish(Result<Void, any Error>)
        case responseBypassSubstreamDidFinish(Result<Void, any Error>)
        case nodeSubstreamsDidFinish(Result<Void, any Error>)
        case connectionMetricsReportingDidFinish
        case inactivityWatchdogDidFinish(Result<Void, any Error>)
    }

    private func runRequest() async throws {
        scheduleServerDrivenConfigurationFetchIfNeeded()

        let sessionCount = try await self.checkRateLimiting()

        let (rootConnectionUpdatesStream, rootConnectionUpdatesContinuation) = AsyncStream<ConnectionUpdate>.makeStream()

        async let _ = {
            await withTaskCancellationHandler {
                for await update in rootConnectionUpdatesStream {
                    logger.log("\(self.logPrefix) connection update=\(String(describing: update))")
                    self.progressReader.forward(update)
                }
                logger.log("\(self.logPrefix) connection updates monitoring finished")
            } onCancel: {
                // At the end of the outer function (`runRequest`), the `async let` subtask gets
                // canceled because nothing in awaiting for its result.
                logger.log("\(self.logPrefix) connection updates monitoring canceled")
                rootConnectionUpdatesContinuation.finish()
            }
        }()

        try await self.connectionFactory.connect(
            parameters: .makeTLSAndHTTPParameters(
                ignoreCertificateErrors: self.configuration.ignoreCertificateErrors,
                forceOHTTP: self.configuration.forceOHTTP,
                useCompression: true,
                featureFlagChecker: self.featureFlagChecker,
                bundleIdentifier: self.configuration.bundleID,
                serviceClass: self.configuration.serviceClass
            ),
            endpoint: .url(self.configuration.endpointURL),
            activity: nil,
            on: .main,
            requestID: self.serverRequestID,
            logComment: self.logComment(.root),
            maximumReadLength: self.configuration.networkConnectionReadSize,
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
            async let asyncRequestToken = self.requestMetrics.observeAuthTokenFetch {
                try await self.loadRequestToken()
            }

            // Reputation tokens
            // Not all requests use reputation tokens. When it's used, the following is expected:
            // 1. We fetch reputation token and send it to ROPES.
            // 2. We generate reputation token request and send it on data stream. Later, we expect to receive
            //    a reputation token response (refund) from the server and we would pass it to NSP.
            // 3. If fetching of reputation token failed, we don't send generated token request.
            // 4. Errors around reputation tokens are not fatal and don't fail the request.
            async let asyncReputationToken = self.requestMetrics.observeReputationTokenFetch {
                try await self.loadReputationToken()
            }
            async let asyncReputationTokenRequest = self.requestMetrics.observeReputationRefundTokenGeneration {
                try await self.generateReputationTokenRequest()
            }

            // Waitlist tokens
            // If it's on (controlled by server-driven config), then:
            // 1. We fetch waitlist token and send it to ROPES.
            // 2. Error fetching waitlist token is not fatal and doesn't fail the request.
            async let asyncWaitlistToken = self.requestMetrics.observeWaitlistTokenFetch {
                try await self.loadWaitlistToken()
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
            self.outgoingUserDataWriter.registerCancelAllWritesClosure { error in
                // If adopter cancels request while data send loop awaits for "ready for more chunks",
                // we need to abort the wait.
                logger.log("\(self.logPrefix) cancelAllWrites called, error=\(error)")
                readyForMoreChunksEvent.fire(throwing: error)
            }

            let ropesInvokeRequestSentEvent = AsyncEvent<Void>()
            let responseBypassContextReceivedEvent = AsyncEvent<Proto_PrivateCloudCompute_ResponseContext>()
            let trustedProxyNodeSelectedEvent = AsyncEvent<Int>()  // the value is ohttp context
            let requestToken = try await asyncRequestToken
            // Intentionally not throwing here. We don't want to fail the request because of this.
            // Error will be captured in logs and telemetry.
            let reputationToken = try? await asyncReputationToken
            let reputationTokenRequest: Data? =
                if reputationToken == nil {
                    nil
                } else {
                    // Intentionally not throwing here. We don't want to fail the request because of this.
                    // Error will be captured in logs and telemetry.
                    try? await asyncReputationTokenRequest
                }

            // We should only accept "reputation token response" (refund) if we actually had "reputation token request"
            reputationTokenResponseExpected.withLock {
                $0 = reputationTokenRequest != nil
            }

            // Intentionally not throwing here. We don't want to fail the request because of this.
            // Error will be captured in logs and telemetry.
            let waitlistToken = try? await asyncWaitlistToken

            let (requestActivityStream, requestActivityContinuation) = AsyncStream.makeStream(of: TrustedRequestActivity.self)

            let result = await withTaskGroup(of: RunSubTask.self, returning: Result<Void, any Error>.self) { taskGroup in
                logger.log("\(self.logPrefix) Entered main task group")

                // 1. ropes connection
                taskGroup.addTask {
                    return .ropesRequestDidFinish(
                        await Result {
                            defer {
                                logger.log("\(self.logPrefix) Finish requestActivityContinuation")
                                requestActivityContinuation.finish()
                            }

                            let requestHeaders = try self.makeRopesRequestHeaders(
                                token: requestToken,
                                sessionCount: sessionCount,
                                cachedAttestations: cachedNodes
                            )

                            try await self.runRopesRequest(
                                requestHeaders: requestHeaders,
                                reputationToken: reputationToken,
                                waitlistToken: waitlistToken,
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
                                    reputationTokenRequest: reputationTokenRequest,
                                    dataStreamOutbound: dataStreamOutbound,
                                    readyForMoreChunksEvent: readyForMoreChunksEvent,
                                    requestActivityContinuation: requestActivityContinuation,
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
                                        logger.debug("\(self.logPrefix) No response bypass context received from any node")
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
                            logger.log("\(self.logPrefix) \(String(reflecting: establishReport))")
                        } else {
                            logger.warning("\(self.logPrefix) connection establishment report is unavailable")
                        }
                    } catch {
                        self.requestMetrics.reportConnectionError(error)
                    }
                    return .connectionMetricsReportingDidFinish
                }

                // 5. inactivity watchdog
                if let inactivityWatchdog = self.inactivityWatchdog {
                    taskGroup.addTask {
                        return .inactivityWatchdogDidFinish(
                            await Result {
                                try await inactivityWatchdog.run(activityStream: requestActivityStream)
                            }
                        )
                    }
                }

                var nodeStreamsError: (any Error)?
                var dataStreamError: (any Error)?
                var responseStreamError: (any Error)?
                var ropesError: (any Error)?

                // if one subtask fails, we need to stop all the other ones by throwing
                while let nextResult = await taskGroup.next() {
                    switch nextResult {
                    case .ropesRequestDidFinish(.success):
                        logger.log("\(self.logPrefix) Ropes request finished successfully")
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
                        logger.log("\(self.logPrefix) Ropes request failed. Error: \(failure)")
                        logger.debug("\(self.logPrefix) Cancelling main task group due to root stream failure, error=\(failure)")
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
                        logger.log("\(self.logPrefix) Response bypass substream task finished successfully")
                        self.requestMetrics.responseBypassStreamFinished()

                    case .responseBypassSubstreamDidFinish(.failure(let failure)):
                        logger.log("\(self.logPrefix) Response bypass substream task failed. Error: \(failure)")
                        self.requestMetrics.responseBypassStreamFinished()
                        self.requestMetrics.responseReceivingFailed(error: failure)
                        responseStreamError = failure

                    case .dataSubstreamDidFinish(.success):
                        logger.log("\(self.logPrefix) Data substream task finished successfully")

                    case .dataSubstreamDidFinish(.failure(let failure)):
                        logger.log("\(self.logPrefix) Data substream task failed. Error: \(failure)")
                        dataStreamError = failure

                    case .nodeSubstreamsDidFinish(.success):
                        logger.log("\(self.logPrefix) Node substreams task finished successfully")
                        self.requestMetrics.nodeStreamsFinished()
                        if !self.configuration.trustedProxyResponseBypass {
                            // Means response payload is expected on a node stream and if all them have finished, the
                            // response state could be considered finished as well.
                            self.requestMetrics.responsePayloadReceiveFinished()
                        }

                    case .nodeSubstreamsDidFinish(.failure(let failure)):
                        logger.log("\(self.logPrefix) Node substreams task failed. error: \(failure)")

                        // Any of these out of the node substreams means we can't make progress
                        if let error = failure as? TrustedRequestError, error.isGroupTerminatingError {
                            logger.debug("\(self.logPrefix) Cancelling main task group due node substreams failure, error=\(error)")
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

                        self.requestMetrics.nodeStreamsFinished()

                        if !self.configuration.trustedProxyResponseBypass {
                            // Response payload was expected on node's stream
                            self.requestMetrics.responseReceivingFailed(error: failure)
                        }
                        nodeStreamsError = failure

                    case .connectionMetricsReportingDidFinish:
                        logger.log("\(self.logPrefix) Connection metrics reporting finished")

                    case .inactivityWatchdogDidFinish(.success):
                        logger.log("\(self.logPrefix) Inactivity watchdog finished")

                    case .inactivityWatchdogDidFinish(.failure(let error)):
                        logger.log("\(self.logPrefix) Inactivity watchdog finished, error=\(error)")
                        // Gracefully end the request by sending `.final` to the server if data stream hasn't been
                        // finished yet, and throw an error to the adopter indicating it was cancelled due to
                        // inactivity.
                        self.cancel(reason: .inactivityTimeout)
                    }
                }

                // If we have a `.failedToValidateInlineAttestations` error from the nodeSubstream task,
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
            logger.log("\(self.logPrefix) \(String(reflecting: dataTransferReport))")

            try result.get()
        }
    }

    private let reputationTokenResponseExpected = Mutex<Bool>(false)

    private func checkRateLimiting() async throws -> UInt {
        // This is a surgical bugfix for an upcoming release. We should reconsider
        // when we modify the workload params (routing-key and filtering): rdar://179173593
        // The goal here is to have workload params to match with what we do
        // in `specificRateLimitFilter()`.
        var workload = parameters
        workload.parameters = prepare(workloadParameters: workload.parameters)

        let requestMetadataForRateLimit = RateLimiterRequestMetadata(
            configuration: self.configuration,
            parameters: workload
        )
        if let rateLimitInfo = await self.rateLimiter.rateLimitDenialInfo(now: Date.now, for: requestMetadataForRateLimit, sessionID: configuration.sessionID) {
            // This means the rate limiter does not want us to proceed.
            let code: PrivateCloudComputeError.Code =
                switch rateLimitInfo.rateLimitSource {
                case .ropes: .deniedDueToRateLimit
                case .vault: .deniedDueToUserDeviceRateLimit
                case .device: .deniedDueToEarlierAvailabilityConcern
                }
            throw PrivateCloudComputeError(code: code, retryAfterDate: rateLimitInfo.retryAfterDate)
        }

        let sessionCount: UInt
        if let sessionID = self.configuration.sessionID {
            sessionCount = await self.rateLimiter.sessionProgress(now: Date.now, for: sessionID)
            logger.log("\(self.logPrefix) using session identifier \(sessionID) with progress \(sessionCount)")
        } else {
            sessionCount = 0
            logger.log("\(self.logPrefix) no session identifier on request")
        }
        return sessionCount
    }

    private func updateRateLimiting() async {
        let requestMetadataForRateLimit = RateLimiterRequestMetadata(
            configuration: self.configuration,
            parameters: self.parameters
        )

        logger.log(
            """
            \(self.logPrefix) updating rate limiter with attribution
            bundleID: \(self.configuration.bundleID.rawValue)
            originatingBundleID: \(self.configuration.originatingBundleID?.rawValue ?? "nil")
            clientBundleID: \(self.configuration.clientBundleID)
            featureID: \(self.configuration.featureID ?? "nil")
            sessionID: \(self.configuration.sessionID?.uuidString ?? "nil")
            qos: \(self.configuration.serverQoS.rawValue, privacy: .public)

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

    private func loadRequestToken() async throws -> Data {
        try await withOSActivity {
            try await self.tokenProvider.fetchToken()
        }
    }

    private func loadWaitlistToken() async throws -> Data? {
        guard let waitlistTokenProvider else {
            return nil
        }

        return try await withOSActivity {
            try await logger.logLifetime("loadWaitlistToken", logPrefix: self.logPrefix) {
                try await waitlistTokenProvider.fetchToken()
            }
        }
    }

    private func loadReputationToken() async throws -> Data? {
        guard let reputationTokenProvider else {
            return nil
        }

        return try await withOSActivity {
            try await logger.logLifetime("loadReputationToken", logPrefix: self.logPrefix) {
                try await reputationTokenProvider.fetchToken()
            }
        }
    }

    private func generateReputationTokenRequest() async throws -> Data? {
        guard let reputationTokenProvider else {
            return nil
        }
        return try await withOSActivity {
            try await logger.logLifetime("generateReputationTokenRequest", logPrefix: self.logPrefix) {
                try await reputationTokenProvider.generateTokenRequest()
            }
        }
    }

    func loadCachedAttestations() async -> [ValidatedAttestationOrAttestation] {
        // get all unexpired attestations
        guard let prefetchParameters = self.parameters.forPrefetching() else {
            logger.error("\(self.logPrefix) invalid set of parameters for prefetching")
            return []
        }

        let maxCachedAttestations = self.configuration.maxCachedAttestations

        switch attestationStoreOrLegacyStore {
        case .attestationStore(let attestationStore):
            do {
                let cachedAttestations = try await attestationStore.getAttestationsForRequest(
                    parameters: prefetchParameters,
                    serverRequestID: self.serverRequestID,
                    maxAttestations: maxCachedAttestations
                )
                logger.log("\(self.logPrefix) Total cached attestations from store: \(cachedAttestations.count) maxCachedAttestations: \(maxCachedAttestations)")

                var count = 0
                return cachedAttestations.map { validatedAttestation in
                    defer {
                        count += 1
                    }

                    logger.log("\(self.logPrefix) creating verified node with identifier: \(validatedAttestation.attestation.nodeID), ohttpcontext: \(count + 10), kind: \(validatedAttestation.nodeKind)")
                    return ValidatedAttestationOrAttestation.cachedValidatedAttestation(validatedAttestation, ohttpContext: UInt64(count + 10))
                }
            } catch {
                logger.error("\(self.logPrefix) failed to get attestations from store: \(error)")
                return []
            }
        case .legacyStore(let legacyAttestationStore):
            let cachedAttestations = await legacyAttestationStore.getAttestationsForRequest(
                nodeKind: .proxy,
                parameters: prefetchParameters,
                serverRequestID: self.serverRequestID,
                maxAttestations: maxCachedAttestations
            )
            logger.log("\(self.logPrefix) Total cached attestations from store: \(cachedAttestations.count) maxCachedAttestations: \(maxCachedAttestations)")

            var count = 0
            return cachedAttestations.map { (key, validatedAttestation) in
                defer {
                    count += 1
                }

                logger.log("\(self.logPrefix) creating verified node with identifier: \(key), ohttpcontext: \(count + 10), kind: \(validatedAttestation.nodeKind)")
                return ValidatedAttestationOrAttestation.cachedValidatedAttestation(validatedAttestation, ohttpContext: UInt64(count + 10))
            }
        }
    }

    private func scheduleServerDrivenConfigurationFetchIfNeeded() {
        if self.configuration.isServerDrivenConfigurationOutdated {
            logger.info("\(self.logPrefix) Server driven configuration is outdated, scheduling a fetch")
            self.eventStreamContinuation.yield(.fetchServerDrivenConfigurationIfAllowed)
        }
    }

    // MARK: Ropes request

    private func runRopesRequest(
        requestHeaders: HTTPFields,
        reputationToken: Data?,
        waitlistToken: Data?,
        cachedNodes: [ValidatedAttestationOrAttestation],
        inbound: ConnectionFactory.Inbound,
        outbound: ConnectionFactory.Outbound,
        unverifiedNodeContinuation: AsyncStream<ValidatedAttestationOrAttestation>.Continuation,
        ropesInvokeRequestSentEvent: AsyncEvent<Void>,
        readyForMoreChunksEvent: AsyncEvent<Void>,
        trustedProxyNodeSelectedEvent: AsyncEvent<Int>
    ) async throws {
        try await withOSActivity {
            defer { logger.debug("\(self.logPrefix(.root)) Finished root connection subtask") }

            let httpRequest = HTTPRequest(
                method: .post,
                scheme: "https",
                authority: self.configuration.trustedRequestHostname,
                path: self.configuration.trustedRequestPath,
                headerFields: requestHeaders
            )

            let invokeRequestMessage = self.makeInvokeRequest(
                cachedNodes: cachedNodes,
                reputationToken: reputationToken,
                waitlistToken: waitlistToken
            )
            let framer = Framer()
            let invokeRequestPayload = try framer.frameMessage(invokeRequestMessage)

            await self.updateRateLimiting()

            try await self.requestMetrics.observeSendingRopesRequest(headers: requestHeaders) {
                // the timeout around sending the invoke request, is used as a connection establish
                // timeout, since NW will automatically retry to create a connection, if it could not
                // establish one at first try.
                let timeout: Duration = .seconds(60)
                try await withCancellationAfterTimeout(duration: timeout, clock: self.clock) {
                    let begin = self.clock.now
                    do {
                        logger.log("\(self.logPrefix(.root)) ropes request send, invokeRequestMessage=\(invokeRequestMessage.loggingDescription)")
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
                        logger.error("\(self.logPrefix(.root)) ropes request send has timed out timeout=\(timeout)")
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
    }

    private func prepare(workloadParameters params: [String: String]) -> [String: String] {
        let params = params.preparedToBeSentAsHeaders(featureFlagChecker: self.featureFlagChecker)

        guard self.configuration.enforceWorkloadParametersFiltering else {
            return params
        }

        let allowed = Workload.allowedParameters
        return params.filter { elm in
            if allowed.contains(elm.key) {
                return true
            } else {
                logger.warning("\(self.logPrefix) found workload parameter not in allow list, ignoring: \(elm.key)")
                return false
            }
        }
    }

    internal func makeRopesRequestHeaders(
        token: Data,
        sessionCount: UInt,
        cachedAttestations: [ValidatedAttestationOrAttestation]
    ) throws -> HTTPFields {
        let filteredWorkloadParameters = prepare(workloadParameters: parameters.parameters)
        let workloadParametersAsJSON = try self.jsonEncoder.encode(filteredWorkloadParameters)
        let workloadParametersAsString = String(data: workloadParametersAsJSON, encoding: .utf8) ?? ""

        var headers: HTTPFields = [
            .appleRequestUUID: self.serverRequestID.uuidString,
            .appleClientInfo: self.systemInfo.osInfo,
            .appleWorkload: parameters.type,
            .appleWorkloadParameters: workloadParametersAsString,
            .appleQOS: self.configuration.serverQoS.rawValue,
            .appleBundleID: self.configuration.bundleID.redactedValue,
            .appleSessionProgress: String(sessionCount),
            .contentType: HTTPField.Constants.contentTypeMessageRopesRequest,
            .userAgent: HTTPField.Constants.userAgentTrustedCloudComputeD,
            .authorization: "PrivateToken token=\"\(base64URL(token))\"",
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

        logger.log("\(self.logPrefix(.root)) sending headers\n\(headers.loggingDescription)")

        return headers
    }

    private func makeInvokeRequest(
        cachedNodes: [ValidatedAttestationOrAttestation],
        reputationToken: Data?,
        waitlistToken: Data?
    ) -> Proto_Ropes_HttpService_InvokeRequest {
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
                if self.featureFlagChecker.isEnforceAntiTargetabilityForInlineAttestationsEnabled(environment: self.configuration.environment) {
                    $0.capabilities.antiTargetabilityMinAttestationEnforcement = true
                    $0.requiredInlineAttestationsCountIfAny = UInt32(self.configuration.minExpectedInlineAttestations)
                }
                $0.attestationMappings = cachedNodes.map { node in
                    return .with {
                        logger.log("\(self.logPrefix(.root)) adding prefetched attestation for node: \(node.identifier) ohttpContext: \(UInt32(node.ohttpContext))")
                        $0.nodeIdentifier = node.identifier
                        $0.ohttpContext = UInt32(node.ohttpContext)
                    }
                }

                for privateToken in [reputationToken, waitlistToken] {
                    if let privateToken {
                        $0.privateTokens.append(
                            .with({ token in
                                token.token = privateToken
                            }))
                    }
                }
            }
        }
    }

    /// This is the very first message sent on data stream.
    private func makeOpenRequestPayload(
        reputationTokenRequest: Data?
    ) -> Proto_PrivateCloudCompute_PrivateCloudComputeRequest {
        return .with {
            $0.open = .with {
                $0.version = self.configuration.multiTurn ? 1 : 0
                let isChunkingEnabled =
                    self.configuration.applicationDataChunkingSize > 0
                    && self.featureFlagChecker.isEnabled(self.configuration.environment == .production ? .applicationDataChunking : .applicationDataChunkingPreProduction)

                if isChunkingEnabled {
                    $0.capabilities.applicationDataChunking = .with {
                        $0.size = UInt32(self.configuration.applicationDataChunkingSize)
                    }
                }
                $0.optedInToShareDiagnosticsAndUsageWithApple = self.configuration.optedInToShareDiagnosticsAndUsageWithApple
                $0.workloadType = self.parameters.type
                if let reputationTokenRequest {
                    $0.reputationTokenRequest.tokenRequest = reputationTokenRequest
                }
                if self.featureFlagChecker.isEnabled(.requestExecutionLogCompression) {
                    $0.capabilities.requestExecutionLogEntryCompression = .with {
                        $0.supportedAlgorithms = Proto_PrivateCloudCompute_CompressedPayload.supportedCompressionAlgorithms
                    }
                }
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
                logger.log("\(self.logPrefix(.root)) received message: \(String(describing: message.type))")

                switch message.type {
                case .attestation(let attestation):
                    self.handleAttestation(attestation, continuation: unverifiedNodeContinuation)

                case .readyForMoreChunks:
                    self.requestMetrics.readyForMoreChunks()
                    readyForMoreChunksEvent.fire()

                case .rateLimitConfigurationList(let rateLimitConfigurationList):
                    logger.debug("\(self.logPrefix(.root)) received \(rateLimitConfigurationList.rateLimitConfiguration.count) rate limit configurations")
                    self.handleRateLimitConfigurationList(rateLimitConfigurationList)

                case .expiredAttestationList(let expiredAttestationList):
                    logger.debug("\(self.logPrefix(.root)) received expired attestation message for parameters  \(String(describing: self.parameters)). Will refresh attestations out of band")
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
                    logger.info("\(self.logPrefix(.root)) trusted proxy node selected ohttpContext=\(proxySelected.ohttpContext)")
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
                            logger.error(
                                "\(self.logPrefix(.root)) unrecognized featureId. This is not a failure, but may become a failure in the future. reason=\(denyReasonString, privacy: .public), featureID=\(featureIdString, privacy: .public)"
                            )

                        case .workloadBlocked:
                            let workloadTypeString = "\(self.parameters.type)"
                            let workloadParameterString = "\(self.parameters.parameters)"
                            logger.error("\(self.logPrefix(.root)) request denial: reason=\(denyReasonString, privacy: .public), type=\(workloadTypeString), parameters=\(workloadParameterString)")

                        default:
                            logger.error("\(self.logPrefix(.root)) request denial: reason=\(denyReasonString, privacy: .public)")
                        }
                    }

                case nil:
                    break

                case .attestationList, .compressedAttestationList:
                    logger.fault("\(self.logPrefix(.root)) attestation response unexpected: \(String(describing: message.type))")

                @unknown default:
                    logger.error("\(self.logPrefix(.root)) unknown: \(String(describing: message.type))")
                }
            }

            logger.debug("\(self.logPrefix(.root)) Received all messages on ropes stream")
        } catch {
            readyForMoreChunksEvent.fire(throwing: error)
            throw error
        }
    }

    private func processResponseContext(_ received: NWConnectionReceived) throws -> Data? {
        logger.log("\(self.logPrefix(.root)) received content: \(String(describing: received.data)), contentContextPresent: \(received.contentContext != nil), isComplete: \(received.isComplete)")

        // the response head and response end are hidden in the contentContext. If there is no
        // contextContext we just forward the data for further processing.
        guard let responseContext = received.contentContext, let httpResponse = responseContext.httpResponse else {
            return received.data
        }

        logger.info("\(self.logPrefix(.root)) received headers\n\(httpResponse.headerFields.loggingDescription)")

        if let trailers = responseContext.httpMetadata?.trailerFields {
            logger.info("\(self.logPrefix(.root)) received trailers\n\(trailers.loggingDescription)")
        } else {
            logger.info("\(self.logPrefix(.root)) received no trailers")
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
        let workloadParams = self.prepare(workloadParameters: self.parameters.parameters)
        let qos = self.configuration.serverQoS
        return RateLimitFilter(
            bundleID: bundleID.rawValue,
            featureID: featureID,
            qos: qos,
            workloadType: workloadType,
            workloadParams: workloadParams
        )
    }

    private func processRopesResponseHead(_ response: HTTPResponse, contentContext: NWConnection.ContentContext) throws {
        // If it is a bad request, ROPES will fail it with a non-200 response and send errors in headers

        let responseMetadata = RopesResponseMetadata(response, contentContext: contentContext)
        logger.debug("\(self.logPrefix) \(responseMetadata.loggingDescription)")
        if responseMetadata.isAvailabilityConcern, let retryAfter = responseMetadata.retryAfter {
            let rateLimitConfig = RateLimitConfiguration(
                source: .device,
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
        logger.debug("\(self.logPrefix) \(responseMetadata.loggingDescription)")
        self.requestMetrics.gatewayStreamFinished()

        for measurement in responseMetadata.componentTimeMeasurements {
            logger.debug("\(self.logPrefix) Received component time measurement on gateway stream: \(measurement)")
            self.eventStreamContinuation.yield(.componentTimeMeasurementReceived(clientRequestID: self.clientRequestID, source: .json(measurement)))
        }

        if responseMetadata.isAvailabilityConcern, let retryAfter = responseMetadata.retryAfter {
            let rateLimitConfig = RateLimitConfiguration(
                source: .device,
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
        if let ttrTitle = responseMetadata.ttrTitle, self.configuration.environment != .production {
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

        // Successful request should contain trailers
        if responseMetadata.code == .ok && responseMetadata.missingTrailingMetadata {
            logger.error("\(self.logPrefix) ROPES response ended without trailers")
            throw PrivateCloudComputeError(code: .missingTrailingMetadata)
        }

        // check that ROPES didn't mark the request as failed in the trailers.
        if responseMetadata.status != .ok || responseMetadata.receivedErrorCode != .code(.success) {
            logger.error(
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
        logger.debug("\(self.logPrefix) attestation ohttpContext=\(attestation.ohttpContext)")
        let mappedAttestation = Attestation(
            attestation: attestation,
            requestParameters: self.parameters
        )
        let mapped = ValidatedAttestationOrAttestation.inlineAttestation(
            mappedAttestation,
            ohttpContext: UInt64(attestation.ohttpContext)
        )

        if !attestation.nodeIdentifier.isEmpty && mappedAttestation.nodeID != attestation.nodeIdentifier {
            logger.error("\(self.logPrefix) node id does not match attestation bundle calculated=\(mappedAttestation.nodeID) fromServer=\(attestation.nodeIdentifier) bundleSize=\(attestation.attestationBundle.count) bytes")
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
                source: .ropes,
                proto: proto,
                config: self.configuration
            ) {
                return rateLimitConfig
            } else {
                logger.error("\(self.logPrefix) unable to process rate limit configuration \(String(describing: proto))")
                return nil
            }
        }
        self.eventStreamContinuation.yield(.rateLimitConfigurations(list))
    }

    private func processRequestExecutionLogEntry(
        _ entry: Proto_PrivateCloudCompute_RequestExecutionLogEntry,
        nodeID: String,
        responseBypassContextReceivedEvent: AsyncEvent<Proto_PrivateCloudCompute_ResponseContext>,
        logContext: LogContext
    ) throws {
        if entry.hasAttestation {
            let proxiedAttestation = ProxiedAttestation(attestationBundle: entry.attestation)
            self.requestMetrics.proxiedAttestationReceived(proxiedAttestation: proxiedAttestation, proxiedBy: nodeID)
        }
        for proto in entry.assetMetadata {
            let asset = AssetMetadata(proto: proto)
            self.requestMetrics.executionAssetReceived(asset)
        }
        if entry.hasOutboundCallContext {
            let outboundCallContext = OutboundCallContext(proto: entry.outboundCallContext, nodeID: nodeID)
            self.requestMetrics.executionOutboundCallReceived(outboundCallContext)
        }
        if entry.final {
            self.requestMetrics.nodeRequestExecutionLogFinalized(nodeID: nodeID)
        }
        if entry.hasResponseContext {
            if self.configuration.trustedProxyResponseBypass {
                logger.debug("\(self.logPrefix(logContext)) received AEAD for response bypass contextID=\(entry.responseContext.contextID)")
                responseBypassContextReceivedEvent.fire(entry.responseContext)
            } else {
                throw TrustedRequestError(code: .unexpectedlyReceivedResponseBypassContext)
            }
        }
    }

    // MARK: Send data stream

    private func sendLoop(
        reputationTokenRequest: Data?,
        dataStreamOutbound: ConnectionFactory.OHTTPSubStreamFactory.Outbound,
        readyForMoreChunksEvent: AsyncEvent<Void>,
        requestActivityContinuation: AsyncStream<TrustedRequestActivity>.Continuation
    ) async throws {
        try await withOSActivity {
            let logContext = LogContext.data(self.requestOHTTPContext)
            var readyForMoreChunks: Bool = false
            var budget = TrustedRequestConstants.maxDataToSendBeforeReadyForMoreChunksReceived
            let framer = Framer()

            try await self.requestMetrics.observeOpenRequestPayloadSend(
                reputationTokenRequestIncluded: reputationTokenRequest != nil
            ) {
                let message = self.makeOpenRequestPayload(reputationTokenRequest: reputationTokenRequest)
                let messageFrame = try framer.frameMessage(message)
                budget -= messageFrame.count

                logger.debug("\(self.logPrefix(logContext)) Sending open request payload message on data stream. Remaining budget before ready for more chunks: \(budget), message=\(message.loggingDescription)")

                try await dataStreamOutbound.write(
                    content: messageFrame,
                    contentContext: .defaultMessage,
                    isComplete: false
                )
            }

            var userStreamIsFinished = false
            do {
                while !userStreamIsFinished {
                    try await self.outgoingUserDataWriter.withNextOutgoingElement { outgoingUserData in
                        logger.debug("\(self.logPrefix(logContext)) Received a message to forward to server, message=\(String(describing: outgoingUserData))")
                        self.requestMetrics.receivedOutgoingUserData(outgoingUserData: outgoingUserData)
                        requestActivityContinuation.yield(.userDataReceived)

                        if outgoingUserData.isComplete {
                            userStreamIsFinished = true
                            if case .data(let payload) = outgoingUserData, payload.data.isEmpty {
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
                        case .data(let payload):
                            // non multi-turn request
                            outgoingMessage = self.makePrivateCloudComputeSendApplicationPayloadRequest(
                                data: payload.data
                            )
                        case .openSubrequest(let payload):
                            logger.debug(
                                """
                                \(self.logPrefix(logContext)) openSubrequest \
                                subrequestId=\(payload.subrequestId), \
                                priority=\(String(describing: payload.priority), privacy: .public), \
                                opaqueCryptoMaterial=\(payload.opaqueCryptoMaterial)
                                """)

                            outgoingMessage = .with { message in
                                message.subOpen.subrequestID = payload.subrequestId
                                message.subOpen.priority = .init(payload.priority)
                                message.subOpen.opaqueCryptoMaterial = payload.opaqueCryptoMaterial.map { .init(opaqueCryptoMaterial: $0) }
                            }
                        case .subrequestData(let payload):
                            logger.debug("\(self.logPrefix(logContext)) subrequestData subrequestId=\(payload.subrequestId)")
                            outgoingMessage = .with {
                                $0.payloadChunk.subrequestID = payload.subrequestId
                                $0.payloadChunk.chunkData = payload.data
                            }
                        case .closeSubrequest(let payload):
                            logger.debug("\(self.logPrefix(logContext)) closeSubrequest subrequestId=\(payload.subrequestId)")
                            outgoingMessage = .with {
                                $0.subClose.subrequestID = payload.subrequestId
                            }
                        case .cancelSubrequest(let payload):
                            logger.debug("\(self.logPrefix(logContext)) cancelSubrequest subrequestId=\(payload.subrequestId)")
                            outgoingMessage = .with {
                                $0.subCancel.subrequestID = payload.subrequestId
                            }

                        case .final:
                            logger.debug("\(self.logPrefix(logContext)) final")
                            outgoingMessage = .with {
                                $0.finalMessage = .init()
                            }
                        }

                        guard let outgoingMessage else {
                            return
                        }

                        let message = try framer.frameMessage(outgoingMessage, randomizedPaddingMaxSize: self.configuration.maxProtobufRandomizedPaddingSize)

                        if readyForMoreChunks {
                            logger.debug("\(self.logPrefix(logContext)) Sending message on data stream, ready for more chunks received")
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
                                logger.debug("\(self.logPrefix(logContext)) Sending message on data stream, within initial budget: \(budget)")
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
                                logger.debug("\(self.logPrefix(logContext)) Sending message on data stream (\(message.count) bytes), above initial budget: \(budget) bytes")
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

                                try await logger.logLifetime("wait for readyForMoreChunks", logPrefix: self.logPrefix(logContext)) {
                                    try await readyForMoreChunksEvent()
                                }
                                readyForMoreChunks = true

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
                logger.log("\(self.logPrefix(logContext)) Finished sending all messages")
                self.requestMetrics.dataStreamFinished()
            } catch {
                guard self.featureFlagChecker.isEnabled(.requestCancellationV2) else {
                    throw error
                }

                if let error = error as? PrivateCloudComputeError, error.shouldEndRequestGracefully {
                    // We are here if adopter or inactivity watchdog cancelled the request, or because of xpc
                    // invalidation. And it also means that data stream hasn't finished already.
                    // * In case of single-shot requests maybe we sent no user data or we sent some, and before we
                    //   finished, cancellation happens.
                    // * In case of multi-turn, the data stream is usually running until adopter exits withConnection
                    //   closure. So if we are here, maybe we are in-between subrequests, or in the process of sending
                    //   a subrequest.
                    // Either way, we need to end the data stream so the server can wrap up everything and send us back
                    // cost token and final REL.

                    // `userStreamIsFinished` must be false at this point.
                    logger.log("\(self.logPrefix(logContext)) outgoingUserDataWriter ended due to cancellation, error=\(error), userStreamIsFinished=\(userStreamIsFinished)")

                    try await logger.logLifetime("sending final", logPrefix: self.logPrefix(logContext)) {
                        try await self.sendFinalMessageDueCancellation(dataStreamOutbound: dataStreamOutbound, framer: framer)
                    }
                } else {
                    throw error
                }
            }
        }
    }

    private func sendFinalMessageDueCancellation(
        dataStreamOutbound: ConnectionFactory.OHTTPSubStreamFactory.Outbound,
        framer: Framer
    ) async throws {
        // In case of multi-turn we want to signal to the server there will be no more subrequests so
        // it can wrap up things and return cost token and final REL.
        let finalMessage = Proto_PrivateCloudCompute_PrivateCloudComputeRequest.with {
            $0.finalMessage = .init()
        }

        let outgoingUserData = try framer.frameMessage(
            finalMessage,
            randomizedPaddingMaxSize: self.configuration.maxProtobufRandomizedPaddingSize
        )

        try await dataStreamOutbound.write(
            content: outgoingUserData,
            contentContext: .defaultMessage,
            isComplete: true
        )
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
        try await withOSActivity {
            defer { logger.debug("\(self.logPrefix) Leaving runNodesStreams") }

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
                defer { logger.debug("\(self.logPrefix) Leaving runNodesStreams taskGroup") }

                var runningNodeIDs: Set<String> = []
                var inlineNodeIDs: Set<String> = []
                runningNodeIDs.reserveCapacity(32)  // skip first reallocs
                inlineNodeIDs.reserveCapacity(32)
                // Only used with new attestation store and when we only pick and validate
                // a single inline attestation out of many returned by the server.
                var ohttpContextOfRandomlySelectedInlineNode: UInt64?

                switch attestationStoreOrLegacyStore {
                case .attestationStore:
                    let minimumAttestationEnforcementEnabled = self.featureFlagChecker.isEnforceAntiTargetabilityForInlineAttestationsEnabled(
                        environment: self.configuration.environment
                    )

                    // If anti-targetability is on (`minimumAttestationEnforcementEnabled`)
                    //   - Pick node indices ahead of time
                    //   - As inline node attestations received, extract udid for de-duping, and only
                    //     keep attestations for pre-selected indices.
                    //   - Use inline nodes once all are received and there are no duplicates.
                    // else
                    //   - As inline node attestations received, extract udid for de-duping, and keep
                    //     ALL attestations in-memory.
                    //   - Pick a random one to use, validate it, and start using it.

                    // NOTE: a cached node stream could be started while receiving, de-duping, and validation of pre-selected inline attestations is ongoing.

                    var selectedInlineNodes: [ValidatedAttestationOrAttestation] = []
                    var nextInlineNodeIndex = 0
                    var seenInlineUDIDs: Set<String> = []

                    // Process cached attestations exactly like legacy
                    let streamDrainInterval = self.requestMetrics.beginInlineStreamDrain()
                    defer { self.requestMetrics.endInlineStreamDrain(streamDrainInterval) }
                    for await node in maybeUnverifiedNodeStream {
                        let logContext = LogContext.node(Int(node.ohttpContext))

                        switch node {
                        case .cachedValidatedAttestation:
                            // Cached attestations: same as legacy - just add to running set and spawn task
                            if runningNodeIDs.contains(node.identifier) {
                                logger.debug("\(self.logPrefix(logContext)) already have a node with identifier \(node.identifier), conflict")
                                continue
                            }

                            if runningNodeIDs.count >= self.configuration.maxTotalAttestations {
                                logger.debug("\(self.logPrefix(logContext)) ignoring node \(node.identifier); already have \(runningNodeIDs.count) attestations out of \(self.configuration.maxTotalAttestations) max")
                                continue
                            }

                            runningNodeIDs.insert(node.identifier)

                            taskGroup.addTask {
                                await self.runSingleNodeStream(
                                    logContext: logContext,
                                    node: node,
                                    reportableNodeUdidContinuation: reportableNodeUdidContinuation,
                                    ropesInvokeRequestSentEvent: ropesInvokeRequestSentEvent,
                                    responseBypassContextReceivedEvent: responseBypassContextReceivedEvent,
                                    ohttpStreamFactory: ohttpStreamFactory
                                )
                            }

                        case .inlineAttestation(let attestation, _):
                            let currentInlineNodeIndex = nextInlineNodeIndex
                            nextInlineNodeIndex += 1

                            // Extract udid (lightweight - without full validation)
                            let udid: String
                            do {
                                udid = try await self.attestationVerifier.udid(attestation: attestation)
                            } catch {
                                logger.error("\(self.logPrefix) couldn't extract udid from inline attestation, failing request, cancelling other node streams, error=\(error)")
                                taskGroup.cancelAll()
                                return .failure(TrustedRequestError(code: .failedToExtractAttestationUDID, underlying: [error]))
                            }

                            // Check for duplicate udids among inline attestations
                            if seenInlineUDIDs.contains(udid) {
                                logger.error("\(self.logPrefix(logContext)) Duplicate UDID detected among inline attestations, node \(node.identifier) - failing request")
                                return .failure(TrustedRequestError(code: .duplicateUDIDInBatch))
                            }
                            seenInlineUDIDs.insert(udid)
                            logger.debug("\(self.logPrefix(logContext)) Extracted UDID for inline node \(node.identifier)")

                            inlineNodeIDs.insert(node.identifier)
                            if minimumAttestationEnforcementEnabled {
                                // Only keep the attestation if it was pre-selected.
                                if self.configuration.preSelectedInlineAttestationIndices.contains(currentInlineNodeIndex) {
                                    logger.debug("\(self.logPrefix(logContext)) node was pre-selected, index=\(currentInlineNodeIndex)")
                                    selectedInlineNodes.append(node)
                                } else {
                                    logger.debug("\(self.logPrefix(logContext)) node was not pre-selected, index=\(currentInlineNodeIndex)")
                                }
                            } else {
                                // Use all inline attestations, up to `maxInlineAttestations`
                                if selectedInlineNodes.count >= self.configuration.maxInlineAttestations {
                                    logger.debug(
                                        """
                                        \(self.logPrefix(logContext)) ignoring inline attestation,
                                        maxInlineAttestations=\(self.configuration.maxInlineAttestations),
                                        selectedInlineNodes.count=\(selectedInlineNodes.count),
                                        nodeId=\(node.identifier),
                                        index=\(currentInlineNodeIndex)
                                        """
                                    )
                                } else {
                                    logger.debug(
                                        """
                                        \(self.logPrefix(logContext)) will use inline attestation,
                                        maxInlineAttestations=\(self.configuration.maxInlineAttestations),
                                        selectedInlineNodes.count=\(selectedInlineNodes.count),
                                        nodeId=\(node.identifier),
                                        index=\(currentInlineNodeIndex)
                                        """
                                    )
                                    selectedInlineNodes.append(node)
                                }
                            }
                        }

                        if runningNodeIDs.count >= self.configuration.maxTotalAttestations {
                            logger.debug("\(self.logPrefix) Reached max total attestations limit")
                            break
                        }
                    }  // for await node in maybeUnverifiedNodeStream

                    logger.debug("\(self.logPrefix) stream of cached and inline attestations finished, seenUniqInlineUDIDs.count=\(seenInlineUDIDs.count)")

                    // If the anti-targetability feature is on, and we received some inline attestations,
                    // it must be at least the `minExpectedInlineAttestations`.
                    if minimumAttestationEnforcementEnabled && !inlineNodeIDs.isEmpty && inlineNodeIDs.count < self.configuration.minExpectedInlineAttestations {
                        logger.error("\(self.logPrefix) Insufficient inline attestations for anti-targetability: received \(inlineNodeIDs.count), expected minimum \(self.configuration.minExpectedInlineAttestations)")

                        logger.debug("\(self.logPrefix) Cancelling all node substreams due to insufficientInlineAttestations")
                        taskGroup.cancelAll()

                        return .failure(TrustedRequestError(code: .insufficientInlineAttestations))
                    }

                    if seenInlineUDIDs.isEmpty {
                        logger.log("\(self.logPrefix) didn't receive any inline attestations")
                    } else {
                        logger.log("\(self.logPrefix) inline nodes ready for full validation and use, totalReceived=\(seenInlineUDIDs.count), selected=\(selectedInlineNodes.count)")

                        for selectedNode in selectedInlineNodes {
                            let logContext = LogContext.node(Int(selectedNode.ohttpContext))
                            ohttpContextOfRandomlySelectedInlineNode = selectedNode.ohttpContext

                            // The selected inline goes through the same checks as legacy
                            if runningNodeIDs.contains(selectedNode.identifier) {
                                logger.debug("\(self.logPrefix(logContext)) already have a node with identifier \(selectedNode.identifier), conflict")
                            } else if runningNodeIDs.count >= self.configuration.maxTotalAttestations {
                                logger.debug("\(self.logPrefix(logContext)) ignoring node \(selectedNode.identifier); already have \(runningNodeIDs.count) attestations out of \(self.configuration.maxTotalAttestations) max")
                            } else {
                                runningNodeIDs.insert(selectedNode.identifier)

                                taskGroup.addTask {
                                    await self.runSingleNodeStream(
                                        logContext: logContext,
                                        node: selectedNode,
                                        reportableNodeUdidContinuation: reportableNodeUdidContinuation,
                                        ropesInvokeRequestSentEvent: ropesInvokeRequestSentEvent,
                                        responseBypassContextReceivedEvent: responseBypassContextReceivedEvent,
                                        ohttpStreamFactory: ohttpStreamFactory
                                    )
                                }
                            }
                        }
                    }
                case .legacyStore:
                    // Legacy attestation store case
                    let streamDrainInterval = self.requestMetrics.beginInlineStreamDrain()
                    defer { self.requestMetrics.endInlineStreamDrain(streamDrainInterval) }
                    for await node in maybeUnverifiedNodeStream {
                        let logContext = LogContext.node(Int(node.ohttpContext))

                        if case .inlineAttestation = node {
                            if inlineNodeIDs.count >= self.configuration.maxInlineAttestations {
                                let count = inlineNodeIDs.count
                                // TODO: consider storing this attestation somewhere so we can log it in thtool requests, etc.; probably overkill though.
                                logger.error("\(self.logPrefix(logContext)) ignoring node \(node.identifier); already have \(count) attestations out of \(self.configuration.maxTotalAttestations) max")
                                continue
                            }

                            inlineNodeIDs.insert(node.identifier)
                        }

                        if runningNodeIDs.contains(node.identifier) {
                            logger.debug("\(self.logPrefix(logContext)) already have a node with identifier \(node.identifier), conflict")
                            continue
                        }

                        if runningNodeIDs.count >= self.configuration.maxTotalAttestations {
                            let count = runningNodeIDs.count
                            // TODO: consider storing this attestation somewhere so we can log it in thtool requests, etc.; probably overkill though.
                            logger.error("\(self.logPrefix(logContext)) ignoring node \(node.identifier); already have \(count) attestations out of \(self.configuration.maxTotalAttestations) max")
                            continue
                        }

                        runningNodeIDs.insert(node.identifier)

                        taskGroup.addTask {
                            await self.runSingleNodeStream(
                                logContext: logContext,
                                node: node,
                                reportableNodeUdidContinuation: reportableNodeUdidContinuation,
                                ropesInvokeRequestSentEvent: ropesInvokeRequestSentEvent,
                                responseBypassContextReceivedEvent: responseBypassContextReceivedEvent,
                                ohttpStreamFactory: ohttpStreamFactory
                            )
                        }
                    }  // end node subtask group
                }  // end attestationStoreOrLegacyStore switch

                // NOTE: we may not get to this point of execution, e.g. in case of `insufficientInlineAttestations`

                logger.debug("\(self.logPrefix) Not expecting more attestations. Running with \(runningNodeIDs.count) attestations, inline=\(inlineNodeIDs.count)")

                var errorsPerOhttpContext: [UInt64: (any Error)] = [:]
                var criticalError: TrustedRequestError?

                var completed = 0
                while let (ohttpContext, result) = await taskGroup.next() {
                    completed += 1
                    logger.debug("\(self.logPrefix) Node substream task finished. Remaining: \(runningNodeIDs.count - completed)")
                    switch result {
                    case .success(.verifyAttestationFailed(let error)):
                        errorsPerOhttpContext[ohttpContext] = error
                        if ohttpContext == ohttpContextOfRandomlySelectedInlineNode && !(error is CancellationError) {
                            // We are here if we use new attestation store and we only pick and validate
                            // a single inline attestation out of many returned by the server. And this
                            // node's validation failed, not good.
                            criticalError = TrustedRequestError(code: .failedToValidateInlineAttestations, underlying: [error])

                            // There could be other node streams running (for cached attestations), but
                            // we don't know whether one has been already picked or not, and we don't
                            // want to hang waiting. The server returned an invalid attestation, we don't
                            // proceed regardless.
                            logger.debug("\(self.logPrefix) Cancelling all node substreams as validation of randomly selected inline attestation failed, ohttpContext=\(ohttpContext), error=\(error)")
                            taskGroup.cancelAll()
                        }

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
                            logger.debug("\(self.logPrefix) Cancelling all node substreams as the selected proxy node failed. selectedProxyOhttpContext=\(selected)")
                            taskGroup.cancelAll()
                        }
                    }
                }

                logger.debug("\(self.logPrefix) All \(runningNodeIDs.count) node substreams have finished")

                do {
                    if let criticalError {
                        throw criticalError
                    }

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
    }

    private func runSingleNodeStream(
        logContext: LogContext,
        node: ValidatedAttestationOrAttestation,
        reportableNodeUdidContinuation: AsyncStream<String>.Continuation,
        ropesInvokeRequestSentEvent: AsyncEvent<Void>,
        responseBypassContextReceivedEvent: AsyncEvent<Proto_PrivateCloudCompute_ResponseContext>,
        ohttpStreamFactory: ConnectionFactory.OHTTPSubStreamFactory
    ) async -> (UInt64, Result<ControlledNodeSubtaskResult, any Error>) {
        await withOSActivity {
            // The cancellation handler is merely for logging
            await withTaskCancellationHandler {
                logger.log("\(self.logPrefix(logContext)) Creating node stream subtask for node: \(node.identifier) cloudOSVersion:\(node.cloudOSVersion)")

                defer { logger.debug("\(self.logPrefix(logContext)) Leaving node stream subtask for node: \(node.identifier)") }
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
                            logger.log("\(self.logPrefix(logContext)) verifying attestation")
                            // the state after verify attestation is set in `verifyAttestation(node:)`
                            do {
                                validatedAttestation = try await self.verifyAttestation(attestation: attestation)
                                reportableNodeUdidContinuation.yield(validatedAttestation.udid)
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
                logger.log("\(self.logPrefix(logContext)) Node stream subtask has been cancelled for node: \(node.identifier)")
            }
        }
    }

    private let selectedProxyNode = Mutex<Int?>(nil)

    private func verifyAttestation(attestation: Attestation) async throws -> ValidatedAttestation {
        try await self.requestMetrics.observeAttestationVerify(
            nodeID: attestation.nodeID
        ) {
            do {
                let validatedAttestation = try await self.attestationVerifier.validate(attestation: attestation, expectedNodeKind: .proxy)
                logger.log("\(self.logPrefix) attestation success with package key \(validatedAttestation.publicKey), validationExpiration: \(validatedAttestation.attestationExpiry)")
                return validatedAttestation
            } catch {
                logger.log("\(self.logPrefix) attestation failure with error \(error)")
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

        logger.log("\(self.logPrefix(logContext)) starting node stream to \(nodeID); creating request...")

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
                logger.debug("\(self.logPrefix(logContext)) Received message from node \(nodeID): \(String(describing: message.type))")
                if isFirstMessage {
                    self.requestMetrics.nodeFirstResponseReceived(nodeID: nodeID)
                    isFirstMessage = false
                }

                var incomingUserData: IncomingUserData?

                switch message.type {
                case .responseUuid(let uuidData):
                    logger.debug("\(self.logPrefix(logContext)) Received responseUuid. Ignoring. uuidData=\(uuidData)")

                case .subOpen(let message):
                    logger.debug("\(self.logPrefix(logContext)) Received subOpen subrequestId=\(message.subrequestID)")
                    incomingUserData = .openSubresponse(.init(subrequestId: message.subrequestID))

                case .payloadChunk(let payload):
                    logger.debug("\(self.logPrefix(logContext)) Received payload \(payload.chunkData.count) bytes subrequestId=\(payload.subrequestID)")
                    self.requestMetrics.responsePayloadReceived(bytes: payload.chunkData.count, nodeID: nodeID)
                    incomingUserData = .subresponseData(.init(subrequestId: payload.subrequestID, data: payload.chunkData))

                case .subClose(let message):
                    logger.debug("\(self.logPrefix(logContext)) Received subClose subrequestId=\(message.subrequestID), status=\(String(describing: message.status)), errorDescription=\(message.errorDescription)")
                    incomingUserData = .closeSubresponse(.init(subrequestId: message.subrequestID, status: .init(message.status)))

                case .responseSummary(let responseSummary):
                    logger.debug("\(self.logPrefix(logContext)) Response summary: \(responseSummary.loggingDescription)")
                    do {
                        try checkResponseSummaryError(responseSummary)
                        self.requestMetrics.nodeSummaryReceived(nodeID: nodeID, error: nil)
                    } catch {
                        self.requestMetrics.nodeSummaryReceived(nodeID: nodeID, error: error)
                        throw error
                    }

                case .responsePayload(let payload):
                    logger.debug("\(self.logPrefix(logContext)) Received payload \(payload.count) bytes from node")
                    self.requestMetrics.responsePayloadReceived(bytes: payload.count, nodeID: nodeID)
                    incomingUserData = .data(.init(data: payload))

                case .requestExecutionLogEntry(let entry):
                    logger.debug("\(self.logPrefix(logContext)) Received request execution log entry: \(entry.loggingDescription)")
                    try processRequestExecutionLogEntry(
                        entry,
                        nodeID: nodeID,
                        responseBypassContextReceivedEvent: responseBypassContextReceivedEvent,
                        logContext: logContext
                    )
                    if entry.final {
                        isFinalRELEntryReceived = true
                    }

                case .compressedRequestExecutionLogEntry(let entry):
                    logger.debug("\(self.logPrefix(logContext)) Received compressed request execution log entry, compression=\(String(describing: entry.compressedRequestExecutionLogEntryData.compressionAlgorithm))")
                    let requestExecutionLogEntry: Proto_PrivateCloudCompute_RequestExecutionLogEntry
                    do {
                        requestExecutionLogEntry = try entry.decompressedRequestExecutionLogEntry()
                    } catch {
                        logger.error("\(self.logPrefix(logContext)) decompression failed with error: \(error)")
                        throw TrustedRequestError(code: .failedToDecompressRequestExecutionLogEntry)
                    }
                    try processRequestExecutionLogEntry(
                        requestExecutionLogEntry,
                        nodeID: nodeID,
                        responseBypassContextReceivedEvent: responseBypassContextReceivedEvent,
                        logContext: logContext
                    )
                    if requestExecutionLogEntry.final {
                        isFinalRELEntryReceived = true
                    }

                case .componentTimeMeasurement(let measurement):
                    logger.debug("\(self.logPrefix(logContext)) Received component time measurement on node stream: \(measurement.loggingDescription)")
                    self.eventStreamContinuation.yield(
                        .componentTimeMeasurementReceived(
                            clientRequestID: self.clientRequestID,
                            source: .proto(measurement)
                        )
                    )

                case .costToken(let costToken):
                    logger.debug("\(self.logPrefix(logContext)) Received cost token, jwt=\(costToken.jwt)")
                    self.costTokenReceived(costToken)

                case .reputationToken(let response):
                    logger.debug("\(self.logPrefix(logContext)) Received reputation token response, response=\(response.tokenResponse)")
                    await self.reputationTokenResponseReceived(response)

                case nil:
                    // TBD: Should we fail the request here. Not getting a type looks like a
                    //      protocol error from the server.
                    break

                @unknown default:
                    break
                }

                if let incomingUserData {
                    try throwIfResponseBypassIsOn(logContext: logContext)
                    try await self.receivedIncomingUserData(incomingUserData: incomingUserData)
                }
            }

            if !isFinalRELEntryReceived {
                logger.error("\(self.logPrefix(logContext)) Didn't receive final request execution log entry nodeID=\(nodeID)")
            }

            self.requestMetrics.nodeResponseFinished(nodeID: nodeID)
            logger.debug("\(self.logPrefix(logContext)) Received all messages in node stream: \(nodeID)")
        }
    }

    private func receivedIncomingUserData(incomingUserData: IncomingUserData) async throws {
        self.requestMetrics.receivedIncomingUserData(incomingUserData: incomingUserData)
        try await self.incomingUserDataReader.forwardData(incomingUserData)
    }

    private func costTokenReceived(_ costToken: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.CostToken) {
        self.tokenProvider.save(costToken: costToken.jwt)
    }

    private func reputationTokenResponseReceived(
        _ response: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ReputationTokenResponse
    ) async {
        guard let reputationTokenProvider else {
            return
        }

        guard reputationTokenResponseExpected.withLock({ $0 }) else {
            logger.error("\(self.logPrefix) received reputation token response when not expecting, ignoring")
            return
        }
        do {
            try await self.requestMetrics.observeReputationRefundTokenResponseSave {
                try await reputationTokenProvider.save(tokenResponse: response.tokenResponse)
            }
        } catch {
            logger.error("\(self.logPrefix) error saving reputation token response, ignoring, error=\(error)")
        }
    }

    private func throwIfResponseBypassIsOn(logContext: LogContext) throws {
        if self.configuration.trustedProxyResponseBypass {
            logger.error("\(self.logPrefix(logContext)) Trusted proxy request did not expect response on node stream")
            throw TrustedRequestError(code: .expectedResponseOnBypass)
        }
    }

    private func runResponseBypassStream(
        ohttpContext: Int,
        responseBypassContextReceivedEvent: AsyncEvent<Proto_PrivateCloudCompute_ResponseContext>,
        ohttpStreamFactory: ConnectionFactory.OHTTPSubStreamFactory
    ) async throws {
        try await withOSActivity {
            let logContext = LogContext.responseBypass(ohttpContext)
            logger.log("\(self.logPrefix(logContext)) starting response bypass context=\(ohttpContext)")

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
                        logger.debug("\(self.logPrefix(logContext)) Received message on response bypass: \(String(describing: message.type))")

                        var incomingUserData: IncomingUserData?

                        switch message.type {
                        case .responseUuid(let uuidData):
                            logger.debug("\(self.logPrefix(logContext)) Received responseUuid on response bypass. Ignoring. uuidData=\(uuidData)")

                        case .subOpen(let message):
                            logger.debug("\(self.logPrefix(logContext)) Received subOpen subrequestId=\(message.subrequestID)")
                            incomingUserData = .openSubresponse(.init(subrequestId: message.subrequestID))

                        case .payloadChunk(let payload):
                            logger.debug("\(self.logPrefix(logContext)) Received payload \(payload.chunkData.count) bytes subrequestId=\(payload.subrequestID)")
                            self.requestMetrics.responsePayloadReceived(bytes: payload.chunkData.count)
                            incomingUserData = .subresponseData(.init(subrequestId: payload.subrequestID, data: payload.chunkData))

                        case .subClose(let message):
                            logger.debug("\(self.logPrefix(logContext)) Received subClose subrequestId=\(message.subrequestID), status=\(String(describing: message.status)), errorDescription=\(message.errorDescription)")
                            incomingUserData = .closeSubresponse(.init(subrequestId: message.subrequestID, status: .init(message.status)))

                        case .responseSummary(let responseSummary):
                            logger.debug("\(self.logPrefix(logContext)) Received responseSummary on response bypass responseSummary=\(responseSummary.loggingDescription)")
                            try checkResponseSummaryError(responseSummary)

                        case .responsePayload(let payload):
                            logger.debug("\(self.logPrefix(logContext)) Received payload \(payload.count) bytes on response bypass")
                            self.requestMetrics.responsePayloadReceived(bytes: payload.count)
                            incomingUserData = .data(.init(data: payload))

                        case .requestExecutionLogEntry(let entry):
                            logger.debug("\(self.logPrefix(logContext)) Unexpected requestExecutionLogEntry on response bypass entry=\(entry.loggingDescription)")

                        case .compressedRequestExecutionLogEntry(let entry):
                            logger.debug("\(self.logPrefix(logContext)) Unexpected compressedRequestExecutionLogEntry on response bypass entry=\(entry.loggingDescription)")

                        case .componentTimeMeasurement(let measurement):
                            logger.debug("\(self.logPrefix(logContext)) Received component time measurement: \(measurement.loggingDescription)")
                            self.eventStreamContinuation.yield(
                                .componentTimeMeasurementReceived(
                                    clientRequestID: self.clientRequestID,
                                    source: .proto(measurement)
                                )
                            )

                        case .costToken(let costToken):
                            logger.debug("\(self.logPrefix(logContext)) Received cost token, jwt=\(costToken.jwt)")
                            self.costTokenReceived(costToken)

                        case .reputationToken(let response):
                            logger.debug("\(self.logPrefix(logContext)) Received reputation token response, response=\(response.tokenResponse)")
                            await self.reputationTokenResponseReceived(response)

                        case nil:
                            // TBD: Should we fail the request here. Not getting a type looks like a
                            //      protocol error from the server.
                            break

                        @unknown default:
                            break
                        }

                        if let incomingUserData {
                            try await self.receivedIncomingUserData(incomingUserData: incomingUserData)
                        }
                    }

                    self.requestMetrics.responsePayloadReceiveFinished()
                    logger.debug("\(self.logPrefix(logContext)) Received all messages on response bypass")
                }
            )
        }
    }

    private func checkResponseSummaryError(_ responseSummary: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.CloseResponsePayload) throws {
        let error: TrustedRequestError
        switch responseSummary.responseStatus {
        case .ok:
            return
        case .unauthenticated:
            error = TrustedRequestError(code: .responseSummaryIndicatesUnauthenticated)
        case .internalError:
            error = TrustedRequestError(code: .responseSummaryIndicatesInternalError)
        case .invalidRequest:
            error = TrustedRequestError(code: .responseSummaryIndicatesInvalidRequest)
        case .proxyFindWorkerError:
            error = TrustedRequestError(code: .responseSummaryIndicatesProxyFindWorkerError)
        case .proxyWorkerValidationError:
            error = TrustedRequestError(code: .responseSummaryIndicatesProxyWorkerValidationError)
        case .UNRECOGNIZED(_):
            error = TrustedRequestError(code: .responseSummaryIndicatesFailure)
        }
        let errorStatus = "\(responseSummary.responseStatus)"
        if responseSummary.hasErrorDescription, !responseSummary.errorDescription.isEmpty {
            logger.error("Response Summary Error: status=\(errorStatus), description=\(responseSummary.errorDescription)")
        } else {
            logger.error("Response Summary Error: status=\(errorStatus), no description")
        }
        throw error
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
        } else {
            self.missingTrailingMetadata = true
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
        case .failedToValidateInlineAttestations,
            .expectedResponseOnBypass,
            .duplicateUDIDInBatch,
            .insufficientInlineAttestations,
            .failedToExtractAttestationUDID:
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
