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

import CloudBoardJobCore
import CloudBoardJobHelperCore
import CloudBoardProtos
import CloudBoardUtilities
import Configuration
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import Metrics
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private enum StreamTaskResult {
    case requestStreamFinished
    case requestStreamTerminated(reason: String)
    case responseStreamFinished
}

private let invokeWorkloadViaJobHelperExecutorLogger = Logger(
    label: "cloudboardd.InvokeWorkloadViaJobHelperExecutor"
)

final class InvokeWorkloadViaJobHelperExecutor<IdleClock: Clock>: Sendable where IdleClock.Duration == Duration {
    private static var logger: Logger { invokeWorkloadViaJobHelperExecutorLogger }

    private let acquireTimeout: Duration
    private let requestEncryptionKeyResolver: any RequestEncryptionKeyResolver
    private let preRequestLoadState: ServiceStatusMonitor.InvokeWorkloadLoadState
    private let cloudAppWarmupPool: CloudAppWarmupPool
    private let sessionStore: SessionStore
    private let metricsFactory: any MetricsFactory
    private let idleTimeout: Duration
    private let idleClock: IdleClock
    private let affinityRegistration: AffinityKeyRegistration

    init(
        configReader: ConfigReader,
        requestEncryptionKeyResolver: any RequestEncryptionKeyResolver,
        preRequestLoadState: ServiceStatusMonitor.InvokeWorkloadLoadState,
        cloudAppWarmupPool: CloudAppWarmupPool,
        sessionStore: SessionStore,
        metricsFactory: any MetricsFactory,
        idleTimeout: Duration,
        idleClock: IdleClock = ContinuousClock(),
        affinityRegistration: AffinityKeyRegistration
    ) {
        let acquireTimeoutSeconds = configReader.int(
            forKey: "jobhelper.acquire_timeout_seconds",
            default: 3
        )
        self.acquireTimeout = .seconds(acquireTimeoutSeconds)
        self.requestEncryptionKeyResolver = requestEncryptionKeyResolver
        self.preRequestLoadState = preRequestLoadState
        self.cloudAppWarmupPool = cloudAppWarmupPool
        self.sessionStore = sessionStore
        self.metricsFactory = metricsFactory
        self.idleTimeout = idleTimeout
        self.idleClock = idleClock
        self.affinityRegistration = affinityRegistration
    }

    func process(
        _ request: GRPCCore.StreamingServerRequest<Proto_CloudBoard_InvokeWorkloadRequest>,
        writer: RPCWriter<Proto_CloudBoard_InvokeWorkloadResponse>,
        requestStats: InvokeWorkloadRequestStatistics
    ) async throws {
        // Both iterator and stream state (covering the request stream only) are expected to only ever be owned by
        // one function and task at a time. Transfer them up here so the @Sendable @escaping body of withIdleTimeout
        // can capture them.
        let initialIterator = request.messages.makeAsyncIterator()
        let initialState = InvokeWorkloadStreamState()
        let iteratorTransfer = UnsafeTransfer(initialIterator)
        let stateTransfer = UnsafeTransfer(initialState)

        try await withIdleTimeout(
            self.idleTimeout,
            clock: self.idleClock,
            onTimeout: { duration in
                Counter(
                    label: "cloudboard_invoke_workload_idle_timeout_total",
                    factory: self.metricsFactory
                ).increment()
                throw InvokeWorkloadError.idleTimeoutExceeded(duration)
            },
            body: { idleTimer in
                let onActivity: @Sendable () -> Void = { idleTimer.registerActivity() }
                var iterator = iteratorTransfer.wrappedValue
                var streamState = stateTransfer.wrappedValue

                // We first wait for the setup request
                let preRequestBatchSize = try await self.handleSetup(
                    iterator: &iterator,
                    streamState: &streamState,
                    requestStats: requestStats,
                    onActivity: onActivity
                )

                // Assign a job helper instance, connect, warmup, and, if chosen to handle the request, process it
                try await self.connectWarmupAndProcess(
                    iterator: &iterator,
                    streamState: &streamState,
                    writer: writer,
                    requestStats: requestStats,
                    preRequestBatchSize: preRequestBatchSize,
                    onActivity: onActivity
                )
            }
        )
    }

    /// Waits for setup request and checks whether the request would exceed a ROPES-provided concurrency limit
    private func handleSetup(
        iterator: inout RPCAsyncSequence<Proto_CloudBoard_InvokeWorkloadRequest, any Error>.AsyncIterator,
        streamState: inout InvokeWorkloadStreamState,
        requestStats: InvokeWorkloadRequestStatistics,
        onActivity: @Sendable () -> Void
    ) async throws -> Int {
        guard let setupMessage = try await iterator.next() else {
            throw InvokeWorkloadError.expectedSetup
        }
        try streamState.receiveMessage(setupMessage)
        guard case .setup(let setup) = setupMessage.type else {
            throw InvokeWorkloadError.expectedSetup
        }

        requestStats.setupReceived()
        onActivity()

        // If ROPES requested us to not accept the request if it brings us over the specified concurrency limit, reject
        // the request at this point.
        let preRequestBatchSize = self.preRequestLoadState.concurrentRequestCount
        if setup.hasMaxAcceptedCurrentBatchSize && setup.maxAcceptedCurrentBatchSize < preRequestBatchSize {
            throw InvokeWorkloadError.exceededMaxAcceptedBatchSize
        }

        return preRequestBatchSize
    }

    /// Acquires a pre-warmed cb_jobhelper from ``cloudAppWarmupPool``, sends the setup ack to ROPES, then drives the
    /// per-request streams. The pool retires the helper after a completed or committed request. If the request fails
    /// before ROPES sends the parameters message the helper is unused, so it is returned to the pool for reuse (see
    /// ``JobHelperRequestOutcome``).
    private func connectWarmupAndProcess(
        iterator: inout RPCAsyncSequence<Proto_CloudBoard_InvokeWorkloadRequest, any Error>.AsyncIterator,
        streamState: inout InvokeWorkloadStreamState,
        writer: RPCWriter<Proto_CloudBoard_InvokeWorkloadResponse>,
        requestStats: InvokeWorkloadRequestStatistics,
        preRequestBatchSize: Int,
        onActivity: @Sendable @escaping () -> Void
    ) async throws {
        // Note: iterator and InvokeWorkloadStreamState are not Sendable but from here onwards, they are  only
        // accessed from this one task so we can transfer them here.
        let iteratorTransfer = UnsafeTransfer(iterator)
        let stateTransfer = UnsafeTransfer(streamState)
        let rpcID = requestStats.rpcID ?? ""
        try await self.cloudAppWarmupPool.withJobHelperClient(
            acquireTimeout: self.acquireTimeout
        ) { jobHelperClient -> JobHelperRequestOutcome<Void> in
            var iterator = iteratorTransfer.wrappedValue
            var streamState = stateTransfer.wrappedValue

            // A worker counts as unused until ROPES sends the parameters message. Up to that point we have only written
            // the setupAck and waited, so a failure, most commonly the setupAck write failing because ROPES already
            // closed the channel, leaves the worker warm and untouched and it should go back to the pool for reuse
            // rather than being discarded. Once parameters arrive and are forwarded to cb_jobhelper, the request is
            // committed to this worker, so it can no longer be reused.
            var workerEngaged = false
            do {
                Self.logger.info(
                    "Acquired cb_jobhelper from warmup pool, sending setupAck to ROPES",
                    metadata: ["rpcID": "\(rpcID)"]
                )
                try await self.sendSetupAck(writer: writer, preRequestBatchSize: preRequestBatchSize)
                requestStats.setupAckSent()
                onActivity()

                let parameters = try await self.waitForParameters(
                    iterator: &iterator,
                    streamState: &streamState,
                    requestStats: requestStats,
                    onActivity: onActivity
                )
                requestStats.parametersReceived(parameters)
                onActivity()

                self.affinityRegistration.activate(parameters.affinityKey)

                // Reject replays before forwarding to cb_jobhelper, mirroring the in-process
                // executor. Without this check, a replayed request would proxy through to the
                // cloud app despite reusing a previously-seen request encryption key.
                try await self.sessionStore.addSession(
                    keyMaterial: parameters.decryptionKey.encryptedPayload,
                    keyID: parameters.decryptionKey.keyID
                )

                // Parameters received and are about to be forwarded: the request is now committed to this worker.
                workerEngaged = true

                // Start a new span. This can only be done at this point because the trace context is provided in the
                // Parameters message rather than at the gRPC layer.
                try await self.withInvokeWorkloadTracing(requestStats: requestStats, parameters: parameters) {
                    try await self.processRequestAndResponseStreams(
                        jobHelperClient: jobHelperClient,
                        parameters: parameters,
                        iterator: &iterator,
                        streamState: &streamState,
                        writer: writer,
                        requestStats: requestStats,
                        onActivity: onActivity
                    )
                }
                return .completed(())
            } catch {
                // Before the request is committed the cb_jobhelper/cloud app pair is reusable, so ask the pool to
                // return it. Either way the original error is surfaced to the caller.
                return workerEngaged ? .failedAfterCommit(error) : .failedBeforeCommit(error)
            }
        }
    }

    private func sendSetupAck(
        writer: RPCWriter<Proto_CloudBoard_InvokeWorkloadResponse>,
        preRequestBatchSize: Int
    ) async throws {
        try await writer.write(
            .with {
                $0.setupAck = .with {
                    $0.supportTerminate = true
                    $0.supportTracingContextV2 = true
                    $0.supportRoutingV2 = true
                    $0.currentBatchSize = UInt32(preRequestBatchSize)
                }
            }
        )
    }

    private func waitForParameters(
        iterator: inout RPCAsyncSequence<Proto_CloudBoard_InvokeWorkloadRequest, any Error>.AsyncIterator,
        streamState: inout InvokeWorkloadStreamState,
        requestStats: InvokeWorkloadRequestStatistics,
        onActivity: @Sendable () -> Void
    ) async throws -> Proto_CloudBoard_InvokeWorkloadRequest.Parameters {
        // Loop until we either receive parameters or the stream ends. A `.terminate` does not exit the loop. We wait
        // for the actual stream end so `streamState.receiveEndOfStream()` can surface the categorized `abortedCleanly` /
        // `unexpectedEndOfStream` error.
        while let invokeWorkloadRequestMessage = try await iterator.next() {
            try streamState.receiveMessage(invokeWorkloadRequestMessage)
            switch invokeWorkloadRequestMessage.type {
            case .parameters(let parameters):
                Self.logger.info(
                    "Received request parameters",
                    metadata: [
                        "requestID": "\(parameters.requestID)"
                    ]
                )
                return parameters
            case .terminate(let terminationNotification):
                requestStats.terminationReceived(terminationNotification)
                onActivity()
                Self.logger.info(
                    "Received termination notification",
                    metadata: [
                        "code": "\(terminationNotification.code)",
                        "reason": "\(terminationNotification.reason)",
                    ]
                )
            default:
                Self.logger.error(
                    "Expected parameters message",
                    metadata: [
                        "receivedType": "\(invokeWorkloadRequestMessage.type.map { "\($0)" } ?? "nil")"
                    ]
                )
                throw InvokeWorkloadError.expectedParameters
            }
        }

        // Stream ended without parameters. `receiveEndOfStream()` always throws here:
        // `abortedCleanly` if a `.terminate` was received, `unexpectedEndOfStream` otherwise.
        try streamState.receiveEndOfStream()
        // This should never be reached.
        throw InvokeWorkloadError.internalError(
            "waitForParameters: streamState.receiveEndOfStream() returned without throwing — invariant violated"
        )
    }

    private func processRequestAndResponseStreams(
        jobHelperClient: JobHelperClient,
        parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters,
        iterator: inout RPCAsyncSequence<Proto_CloudBoard_InvokeWorkloadRequest, any Error>.AsyncIterator,
        streamState: inout InvokeWorkloadStreamState,
        writer: RPCWriter<Proto_CloudBoard_InvokeWorkloadResponse>,
        requestStats: InvokeWorkloadRequestStatistics,
        onActivity: @Sendable @escaping () -> Void
    ) async throws {
        let (responseStream, responseContinuation) = AsyncThrowingStream<FinalizableChunk<Data>, any Error>.makeStream()
        let (requestStream, requestContinuation) = AsyncStream<FinalizableChunk<Data>>.makeStream()

        let keyHandle = try await self.requestEncryptionKeyResolver
            .resolveRequestEncryptionKey(for: parameters.decryptionKey.keyID)
        try jobHelperClient.startRequest(
            JobHelperClientRequestContext(
                parameters: parameters,
                keyHandle: keyHandle,
                requestInput: requestStream,
                responseOutput: responseContinuation
            )
        )

        let iteratorTransfer = UnsafeTransfer(iterator)

        let stateTransfer = UnsafeTransfer(streamState)
        try await withThrowingTaskGroup(of: StreamTaskResult.self) { group in
            // Request stream processing
            group.addTask {
                var requestIterator = iteratorTransfer.wrappedValue
                var streamState = stateTransfer.wrappedValue
                let outcome = try await self.processRequestStream(
                    parameters: parameters,
                    iterator: &requestIterator,
                    streamState: &streamState,
                    requestStats: requestStats,
                    requestContinuation: requestContinuation,
                    onActivity: onActivity
                )
                switch outcome {
                case .finished: return .requestStreamFinished
                case .terminatedEarly(let reason): return .requestStreamTerminated(reason: reason)
                }
            }

            // Response stream processing
            group.addTask {
                try await self.processResponseStream(
                    parameters: parameters,
                    responseStream: responseStream,
                    writer: writer,
                    requestStats: requestStats,
                    onActivity: onActivity
                )
                return .responseStreamFinished
            }

            while let result = try await group.next() {
                switch result {
                case .requestStreamFinished:
                    break
                case .requestStreamTerminated(let reason):
                    // The client aborted the request. Forward the terminatation signal to cb_jobhelper so it can
                    // gracefully shut down the cloud app and itself. The reason comes from ROPES and doesn't say where
                    // it originated, so qualify it for the downstream components that only see the forwarded string.
                    jobHelperClient.terminate(reason: "request stream terminated by client: \(reason)")
                case .responseStreamFinished:
                    break
                }
            }
        }
    }

    enum RequestStreamOutcome {
        case finished
        case terminatedEarly(reason: String)
    }

    private func processRequestStream(
        parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters,
        iterator: inout RPCAsyncSequence<Proto_CloudBoard_InvokeWorkloadRequest, any Error>.AsyncIterator,
        streamState: inout InvokeWorkloadStreamState,
        requestStats: InvokeWorkloadRequestStatistics,
        requestContinuation: AsyncStream<FinalizableChunk<Data>>.Continuation,
        onActivity: @Sendable () -> Void
    ) async throws -> RequestStreamOutcome {
        defer { requestContinuation.finish() }
        let rpcID = requestStats.rpcID ?? ""
        while let invokeWorkloadRequestMessage = try await iterator.next() {
            try streamState.receiveMessage(invokeWorkloadRequestMessage)
            switch invokeWorkloadRequestMessage.type {
            case .requestChunk(let chunk):
                Self.logger.debug(
                    "Received request chunk",
                    metadata: [
                        "requestID": "\(parameters.requestID)",
                        "rpcID": "\(rpcID)",
                        "chunkSize": "\(chunk.encryptedPayload.count)",
                        "isFinal": "\(chunk.isFinal)",
                    ]
                )
                requestStats.requestChunkReceived(
                    isFinal: chunk.isFinal,
                    encryptedByteCount: chunk.encryptedPayload.count
                )
                onActivity()
                if chunk.isFinal {
                    Self.logger.info(
                        "Received final request chunk",
                        metadata: [
                            "requestID": "\(parameters.requestID)",
                            "rpcID": "\(rpcID)",
                        ]
                    )
                }
                requestContinuation.yield(
                    FinalizableChunk(chunk: chunk.encryptedPayload, isFinal: chunk.isFinal)
                )
                if chunk.isFinal { return .finished }
            case .terminate(let terminate):
                requestStats.terminationReceived(terminate)
                onActivity()
                Self.logger.info(
                    "Received termination notification",
                    metadata: [
                        "requestID": "\(parameters.requestID)",
                        "rpcID": "\(rpcID)",
                        "code": "\(terminate.code)",
                        "reason": "\(terminate.reason)",
                    ]
                )
                // The caller forwards this termination signal to cb_jobhelper for a graceful shutdown.
                return .terminatedEarly(reason: terminate.reason)
            default:
                Self.logger.warning(
                    "Unexpected InvokeWorkload message type. Ignoring.",
                    metadata: [
                        "requestID": "\(parameters.requestID)",
                        "rpcID": "\(rpcID)",
                        "messageType": "\(invokeWorkloadRequestMessage.type.map { "\($0)" } ?? "nil")",
                    ]
                )
            }
        }
        Self.logger.info(
            "End of request stream",
            metadata: [
                "requestID": "\(parameters.requestID)",
                "rpcID": "\(rpcID)",
            ]
        )
        try streamState.receiveEndOfStream()
        return .finished
    }

    fileprivate func processResponseStream(
        parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters,
        responseStream: AsyncThrowingStream<FinalizableChunk<Data>, any Error>,
        writer: RPCWriter<Proto_CloudBoard_InvokeWorkloadResponse>,
        requestStats: InvokeWorkloadRequestStatistics,
        onActivity: @Sendable () -> Void
    ) async throws {
        let rpcID = requestStats.rpcID ?? ""
        for try await responseChunk in responseStream {
            Self.logger.debug(
                "Writing response chunk",
                metadata: [
                    "requestID": "\(parameters.requestID)",
                    "rpcID": "\(rpcID)",
                    "chunkSize": "\(responseChunk.chunk.count)",
                    "isFinal": "\(responseChunk.isFinal)",
                ]
            )
            requestStats.responseChunkSent(
                isFinal: responseChunk.isFinal,
                encryptedByteCount: responseChunk.chunk.count
            )
            onActivity()
            try await writer.write(
                .with {
                    $0.responseChunk = .with {
                        $0.encryptedPayload = responseChunk.chunk
                        $0.isFinal = responseChunk.isFinal
                    }
                }
            )
        }
        Self.logger.info(
            "All responses written",
            metadata: [
                "requestID": "\(parameters.requestID)",
                "rpcID": "\(rpcID)",
            ]
        )
    }

    private func withInvokeWorkloadTracing<T>(
        requestStats: InvokeWorkloadRequestStatistics,
        parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters,
        _ body: () async throws -> T
    ) async rethrows -> T {
        // Start new span. This can only be done at this point because the trace context is provided in the
        // Parameters message rather than at the gRPC layer.
        var context = ServiceContext.current ?? ServiceContext.topLevel
        InstrumentationSystem.instrument.extract(
            parameters,
            into: &context,
            using: InvokeWorkloadParametersExtractor()
        )

        let rpcID = requestStats.rpcID ?? ""
        context.rpcID = requestStats.rpcID

        return try await withSpan("invoke_workload", context: context) { span in
            span.attributes["request_id"] = "\(parameters.requestID)"
            span.attributes["rpc_id"] = "\(rpcID)"
            span.attributes["tenant_info.automated_device_group"] =
                "\(parameters.tenantInfo.automatedDeviceGroup)"
            span.attributes["tenant_info.client_info"] = "\(parameters.tenantInfo.clientInfo)"
            span.attributes["tenant_info.bundle_id"] = "\(parameters.tenantInfo.bundleID)"
            span.attributes["tenant_info.bundle_version"] = "\(parameters.tenantInfo.bundleVersion)"
            span.attributes["tenant_info.feature_id"] = "\(parameters.tenantInfo.featureID)"
            span.attributes["workload.type"] = "\(parameters.workload.type)"

            do {
                let result = try await body()
                let durations = requestStats.durations()
                span.addEvent(
                    SpanEvent(
                        name: "response_finished",
                        attributes: [
                            "requestID": "\(parameters.requestID)",
                            "rpcID": "\(rpcID)",
                            "terminationCode": "\(requestStats.terminationCode.map { "\($0)" } ?? "")",
                            "terminationReason": "\(requestStats.terminationReason ?? "")",
                            "requestChunksReceived": "\(requestStats.requestChunksReceived)",
                            "finalRequestChunkReceived":
                                "\(requestStats.finalRequestChunkReceived)",
                            "encryptedRequestBytesReceived":
                                "\(requestStats.encryptedRequestBytesReceived)",
                            "responseChunksSent": "\(requestStats.responseChunksSent)",
                            "finalResponseChunkSent": "\(requestStats.finalResponseChunkSent)",
                            "encryptedResponseBytesSent":
                                "\(requestStats.encryptedResponseBytesSent)",
                            "totalMs": "\(durations.total.map { "\($0.inMilliseconds)" } ?? "")",
                            "grpcCallStartToSetupMs":
                                "\(durations.grpcCallStartToSetup.map { "\($0.inMilliseconds)" } ?? "")",
                            "setupToSetupAckMs":
                                "\(durations.setupToSetupAck.map { "\($0.inMilliseconds)" } ?? "")",
                            "setupAckToParametersMs":
                                "\(durations.setupAckToParameters.map { "\($0.inMilliseconds)" } ?? "")",
                            "setupToParametersMs":
                                "\(durations.setupToParameters.map { "\($0.inMilliseconds)" } ?? "")",
                            "setupToFirstRequestChunkMs":
                                "\(durations.setupToFirstRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "parametersToFirstRequestChunkMs":
                                "\(durations.parametersToFirstRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "firstRequestChunkToFirstResponseChunkMs":
                                "\(durations.firstRequestChunkToFirstResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "firstRequestChunkToFinalRequestChunkMs":
                                "\(durations.firstRequestChunkToFinalRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "firstRequestChunkToFinalResponseChunkMs":
                                "\(durations.firstRequestChunkToFinalResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "finalRequestChunkToFirstResponseChunkMs":
                                "\(durations.finalRequestChunkToFirstResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "finalRequestChunkToFinalResponseChunkMs":
                                "\(durations.finalRequestChunkToFinalResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "firstResponseChunkToFinalResponseChunkMs":
                                "\(durations.firstResponseChunkToFinalResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "finalResponseChunkToCallEndMs":
                                "\(durations.finalResponseChunkToCallEnd.map { "\($0.inMilliseconds)" } ?? "")",
                            "terminationReceivedToCallEndMs":
                                "\(durations.terminationReceivedToCallEnd.map { "\($0.inMilliseconds)" } ?? "")",
                        ]
                    )
                )
                return result
            } catch {
                span.setStatus(.init(code: .error, message: "\(String(reportable: error))"))
                let durations = requestStats.durations()
                span.addEvent(
                    SpanEvent(
                        name: "response_finished",
                        attributes: [
                            "requestID": "\(parameters.requestID)",
                            "rpcID": "\(rpcID)",
                            "error": "\(String(reportable: error))",
                            "terminationCode": "\(requestStats.terminationCode.map { "\($0)" } ?? "")",
                            "terminationReason": "\(requestStats.terminationReason ?? "")",
                            "requestChunksReceived": "\(requestStats.requestChunksReceived)",
                            "finalRequestChunkReceived":
                                "\(requestStats.finalRequestChunkReceived)",
                            "encryptedRequestBytesReceived":
                                "\(requestStats.encryptedRequestBytesReceived)",
                            "responseChunksSent": "\(requestStats.responseChunksSent)",
                            "finalResponseChunkSent": "\(requestStats.finalResponseChunkSent)",
                            "encryptedResponseBytesSent":
                                "\(requestStats.encryptedResponseBytesSent)",
                            "totalMs": "\(durations.total.map { "\($0.inMilliseconds)" } ?? "")",
                            "grpcCallStartToSetupMs":
                                "\(durations.grpcCallStartToSetup.map { "\($0.inMilliseconds)" } ?? "")",
                            "setupToSetupAckMs":
                                "\(durations.setupToSetupAck.map { "\($0.inMilliseconds)" } ?? "")",
                            "setupAckToParametersMs":
                                "\(durations.setupAckToParameters.map { "\($0.inMilliseconds)" } ?? "")",
                            "setupToParametersMs":
                                "\(durations.setupToParameters.map { "\($0.inMilliseconds)" } ?? "")",
                            "setupToFirstRequestChunkMs":
                                "\(durations.setupToFirstRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "parametersToFirstRequestChunkMs":
                                "\(durations.parametersToFirstRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "firstRequestChunkToFirstResponseChunkMs":
                                "\(durations.firstRequestChunkToFirstResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "firstRequestChunkToFinalRequestChunkMs":
                                "\(durations.firstRequestChunkToFinalRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "firstRequestChunkToFinalResponseChunkMs":
                                "\(durations.firstRequestChunkToFinalResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "finalRequestChunkToFirstResponseChunkMs":
                                "\(durations.finalRequestChunkToFirstResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "finalRequestChunkToFinalResponseChunkMs":
                                "\(durations.finalRequestChunkToFinalResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "firstResponseChunkToFinalResponseChunkMs":
                                "\(durations.firstResponseChunkToFinalResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                            "finalResponseChunkToCallEndMs":
                                "\(durations.finalResponseChunkToCallEnd.map { "\($0.inMilliseconds)" } ?? "")",
                            "terminationReceivedToCallEndMs":
                                "\(durations.terminationReceivedToCallEnd.map { "\($0.inMilliseconds)" } ?? "")",
                        ]
                    )
                )
                throw error
            }
        }
    }
}

enum InvokeWorkloadError: Error {
    /// Expected to receive Setup message
    case expectedSetup
    /// Expected to receive Parameters message
    case expectedParameters
    /// Request stream finished early without explicit termination message
    case uncleanTermination
    /// The incoming request would exceed the provided maximum acceptable batch size
    case exceededMaxAcceptedBatchSize
    /// Neither request nor response chunks observed within the configured idle window.
    case idleTimeoutExceeded(Duration)
    /// An internal invariant was violated. Used as a defensive guard on code paths
    /// that should be unreachable so that a future regression surfaces loudly rather
    /// than silently dropping the request.
    case internalError(String)
}

extension InvokeWorkloadError: ReportableError {
    var publicDescription: String {
        switch self {
        case .expectedSetup:
            return "InvokeWorkloadError.expectedSetup"
        case .expectedParameters:
            return "InvokeWorkloadError.expectedParameters"
        case .uncleanTermination:
            return "InvokeWorkloadError.uncleanTermination"
        case .exceededMaxAcceptedBatchSize:
            return "InvokeWorkloadError.exceededMaxAcceptedBatchSize"
        case .idleTimeoutExceeded(let duration):
            return "InvokeWorkloadError.idleTimeoutExceeded(\(duration))"
        case .internalError(let detail):
            return "InvokeWorkloadError.internalError(\(detail))"
        }
    }
}

extension InvokeWorkloadError: RPCErrorConvertible {
    var rpcErrorCode: RPCError.Code {
        switch self {
        case .expectedSetup: .failedPrecondition
        case .expectedParameters: .failedPrecondition
        case .uncleanTermination: .failedPrecondition
        case .exceededMaxAcceptedBatchSize: .resourceExhausted
        case .idleTimeoutExceeded: .deadlineExceeded
        case .internalError: .internalError
        }
    }

    var rpcErrorMessage: String {
        switch self {
        case .expectedSetup:
            return "Expected setup message before stream end"
        case .expectedParameters:
            return "Expected parameters message"
        case .uncleanTermination:
            return "Request stream finished early without explicit termination message"
        case .exceededMaxAcceptedBatchSize:
            return "Exceeded maximum accepted batch size"
        case .idleTimeoutExceeded(let duration):
            return "InvokeWorkload idle timeout of \(duration) exceeded"
        case .internalError(let detail):
            return "Internal error: \(detail)"
        }
    }
}
