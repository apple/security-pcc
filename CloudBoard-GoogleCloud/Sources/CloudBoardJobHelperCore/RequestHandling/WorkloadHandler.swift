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
import CloudBoardProtos
import CloudBoardUtilities
import Configuration
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import NIOCore
import NIOPosix
import Synchronization
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum WarmupOutcome {
    case completed
    case failed(String)
}

/// Handler responsible for invoking the cloud app
final class WorkloadHandler: Sendable {
    private let logger: Logger
    private let cloudAppSocketPath: String
    private let keyDerivation: KeyDerivationResponder
    private let stateMachine: WorkloadHandlerStateMachine
    private let _requestID: Mutex<String?>
    private let _span: Mutex<(any Span)?>
    private let _terminationReason: Mutex<String?>
    private let _warmupFailureReason: Mutex<String?>
    private let stats = CloudAppRequestStatistics()

    /// Outgoing request messages — the request sequence and key-derivation results —
    /// funnelled through `requestProducer`'s single drain so writes never overlap.
    private let outgoingRequests: AsyncStream<Proto_CloudApp_InvokeWorkloadRequest>
    private let outgoingRequestsContinuation: AsyncStream<Proto_CloudApp_InvokeWorkloadRequest>.Continuation

    init(
        configReader: ConfigReader,
        cloudAppSocketPath: String,
        requestSecrets: RequestSecrets
    ) {
        self.logger = Logger(label: "cb_jobhelper.WorkloadHandler")
        self.cloudAppSocketPath = cloudAppSocketPath
        self.keyDerivation = KeyDerivationResponder(requestSecrets: requestSecrets)
        self.stateMachine = WorkloadHandlerStateMachine()
        self._requestID = Mutex(nil)
        self._span = Mutex(nil)
        self._terminationReason = Mutex(nil)
        self._warmupFailureReason = Mutex(nil)
        (self.outgoingRequests, self.outgoingRequestsContinuation) = AsyncStream.makeStream()
    }

    private var requestID: String? {
        self._requestID.withLock { $0 }
    }

    private var span: (any Span)? {
        self._span.withLock { $0 }
    }

    private var terminationReason: String? {
        self._terminationReason.withLock { $0 }
    }

    var isAbandoned: Bool { stateMachine.isAbandoned }

    func terminate(reason: String) {
        self._terminationReason.withLock { $0 = reason }
    }

    /// Gracefully winds down a prewarmed handler that will not receive a request. Sends the cloud app a graceful
    /// terminate so it runs its early-shutdown path, then abandons the request to unblock the request/response waiters,
    /// so `run()` returns on its own.
    func shutdownWithoutRequest() {
        self.outgoingRequestsContinuation.yield(
            .with { $0.terminate = .with { $0.reason = self.terminationReason ?? "instance retired" } }
        )
        self.stateMachine.abandon()
    }

    func run() async throws {
        self.logger.info("Workload handler starting")
        defer {
            self.logger.info("Workload handler ending", metadata: ["requestID": "\(self.requestID ?? "")"])
        }

        let transport = try await HTTP2ClientTransport.WrappedChannel.wrapping { configure in
            try await ClientBootstrap(
                group: .singletonMultiThreadedEventLoopGroup
            ).connect(unixDomainSocketPath: self.cloudAppSocketPath) { channel in
                configure(channel)
            }
        }
        try await withGRPCClient(transport: transport) { client in
            try await self.invokeWorkload(client: client)
        }
    }

    private func invokeWorkload<Transport: ClientTransport>(client: GRPCClient<Transport>) async throws {
        let cloudApp = Proto_CloudApp_CloudApp.Client(wrapping: client)
        var options = CallOptions.defaults
        options.maxResponseMessageBytes = .max
        options.maxRequestMessageBytes = .max
        try await cloudApp.invokeWorkload(options: options) { writer in
            await self.requestProducer(cloudAppRequestWriter: writer)
        } onResponse: { responses in
            await self.onResponse(cloudAppResponses: responses)
        }
    }

    func startClientConnection(
        span: any Span,
        parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters,
        opaqueCryptoMaterialProvider: @escaping @Sendable () async throws -> [OpaqueCryptoMaterial],
        requestInput: AsyncStream<Data>,
        responseOutput: AsyncThrowingStream<Data, any Error>.Continuation
    ) throws {
        self._requestID.withLock { $0 = parameters.requestID }
        self._span.withLock { $0 = span }
        try self.stateMachine.start(
            clientConnection:
                .init(
                    parameters: parameters,
                    input: requestInput,
                    output: responseOutput,
                    opaqueCryptoMaterialProvider: opaqueCryptoMaterialProvider
                )
        )
    }

    /// Sole owner of the `RPCWriter`: drains `outgoingRequests` and writes each message. Runs
    /// concurrently with `produceRequestSequence` and the key-derivation loop, which both feed
    /// `outgoingRequests`; ends when `onResponse` finishes the stream.
    func requestProducer(
        cloudAppRequestWriter: RPCWriter<Proto_CloudApp_InvokeWorkloadRequest>,
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await self.produceRequestSequence()
                } catch {
                    self.handleRequestProducerFailure(error)
                    // Stop the drain and the key-derivation loop; on the success path onResponse
                    // finishes them at terminal.
                    self.finishOutgoing()
                }
            }
            // Derives keys the cloud app asks for (handed off by onResponse via `accept`) and writes
            // each result into `outgoingRequests`, so every request write stays funnelled through the
            // single drain below rather than onResponse touching the writer directly.
            group.addTask {
                await self.keyDerivation.run(writingResultsInto: self.outgoingRequestsContinuation)
            }
            group.addTask {
                do {
                    for await request in self.outgoingRequests {
                        try await cloudAppRequestWriter.write(request)
                    }
                } catch {
                    self.handleRequestProducerFailure(error)
                }
            }
        }
    }

    /// Ends the outgoing pipeline: stops the key-derivation loop and finishes the request funnel so
    /// `requestProducer`'s drain completes and the RPC writer is closed. Safe to call more than once.
    private func finishOutgoing() {
        self.keyDerivation.finishAcceptingRequests()
        self.outgoingRequestsContinuation.finish()
    }

    /// Records a request-producer failure: logs and abandons the request unless it already
    /// finished successfully or was abandoned.
    private func handleRequestProducerFailure(_ error: any Error) {
        guard !self.stateMachine.isRequestFinishedSuccessfully, !self.stateMachine.isAbandoned else {
            self.logger.info("requestProducer exiting: request already finished or abandoned")
            return
        }
        self.logger.error(
            "Failed to send request to cloud app",
            metadata: ["requestID": "\(self.requestID ?? "")", "error": "\(String(reportable: error))"]
        )
        // onResponse may accept a server response to the partial request as success — preempt it.
        // The state machine will call responseOutput.finish(throwing:) if a continuation is held.
        self.stateMachine.abandon(throwing: CloudAppResponseError(message: String(reportable: error)))
    }

    /// Produces the request message sequence by yielding into `outgoingRequestsContinuation`:
    /// warmup, connection context, sub-request context, the input loop, and EOF/Terminate.
    /// Throws on production failure; the caller handles teardown. `onResponse` finishes the
    /// continuation at the terminal state on the success path.
    private func produceRequestSequence() async throws {
        self.outgoingRequestsContinuation.yield(.init(RPCWarmupContext(nodeResourceID: NodeResourceID(-1))))
        try self.stateMachine.startWarmup()
        self.stats.warmupStarted()

        let clientConnection = try await self.waitForClientConnection()
        self.outgoingRequestsContinuation.yield(
            .init(
                RPCConnectionContext(
                    requestID: clientConnection.parameters.requestID,
                    bundleID: clientConnection.parameters.tenantInfo.bundleID,
                    bundleVersion: clientConnection.parameters.tenantInfo.bundleVersion,
                    featureID: clientConnection.parameters.tenantInfo.featureID,
                    clientInfo: clientConnection.parameters.tenantInfo.clientInfo,
                    workloadType: clientConnection.parameters.workload.type,
                    workloadParameters: Dictionary(parameters: clientConnection.parameters.workload.param),
                    automatedDeviceGroup: clientConnection.parameters.tenantInfo.automatedDeviceGroup,
                    traceContext: {
                        let parameters = clientConnection.parameters
                        guard parameters.hasTraceContext else { return nil }
                        // Inject cloudboardd's active span into a W3C traceparent header.
                        var invokeWorkloadSpanID: UInt64? = nil
                        InstrumentationSystem.instrument.inject(
                            ServiceContext.current ?? ServiceContext.topLevel,
                            into: &invokeWorkloadSpanID,
                            using: InvokeWorkloadSpanIDInjector()
                        )
                        guard let invokeWorkloadSpanID else {
                            self.logger.debug(
                                "No active OTel span — forwarding original trace context to cloud app",
                                metadata: ["requestID": "\(parameters.requestID)"]
                            )
                            return TraceContext(parameters.traceContext)
                        }
                        self.logger.debug(
                            "Forwarding invoke_workload span ID to cloud app",
                            metadata: [
                                "requestID": "\(parameters.requestID)",
                                "invokeWorkloadSpanID": "\(String(invokeWorkloadSpanID, radix: 16))",
                                "parentSpanID": "\(String(parameters.traceContext.spanID, radix: 16))",
                            ]
                        )
                        return TraceContext(
                            traceIDMostSigBits: parameters.traceContext.traceID.mostSigBits,
                            traceIDLeastSigBits: parameters.traceContext.traceID.leastSigBits,
                            spanID: invokeWorkloadSpanID,
                            parentSpanID: parameters.traceContext.spanID
                        )
                    }()
                )
            )
        )

        // This is stand-in for a client provided sub-request identifier.
        let subRequestID = UInt32.random(in: 0...UInt32.max)
        let opaqueCryptoMaterial = try await clientConnection.opaqueCryptoMaterialProvider()
        self.outgoingRequestsContinuation.yield(
            .init(
                RPCSubRequestContext(
                    subRequestID: subRequestID,
                    opaqueCryptoMaterial: opaqueCryptoMaterial
                )
            )
        )
        try self.stateMachine.startRequest()

        let requestInput = _SendableStreamIterator(stream: clientConnection.input)
        var isFirstInput = true
        while let inputData = try await self.waitForInputOrTermination(
            input: requestInput
        ) {
            let rpcMessage = RPCSubRequestInputData(
                subRequestID: subRequestID,
                message: inputData
            )
            self.outgoingRequestsContinuation.yield(.init(rpcMessage))
            self.stats.requestChunkSent()
            if isFirstInput {
                self.logger.info(
                    "Workload handler received first request chunk",
                    metadata: ["requestID": "\(clientConnection.parameters.requestID)"]
                )
                self.span?.addEvent(SpanEvent(name: "cloud_app_first_request_data_sent"))
                isFirstInput = false
            }
        }

        if let reason = self.terminationReason {
            self.logger.info(
                "Sending Terminate to cloud app",
                metadata: ["requestID": "\(clientConnection.parameters.requestID)", "reason": "\(reason)"]
            )
            self.outgoingRequestsContinuation.yield(
                .with { $0.terminate = .with { $0.reason = reason } }
            )
        } else {
            self.outgoingRequestsContinuation.yield(
                .init(
                    RPCSubRequestEndOfInput(
                        subRequestID: subRequestID
                    )
                )
            )
        }
    }

    func onResponse(
        cloudAppResponses: StreamingClientResponse<Proto_CloudApp_InvokeWorkloadResponse>
    ) async {
        // Ends requestProducer's drain and the key-derivation loop on every exit path so it can
        // complete the RPC writer.
        defer { self.finishOutgoing() }

        var responsesIterator = cloudAppResponses.messages.makeAsyncIterator()

        let expectedWarmupCompleted: Proto_CloudApp_InvokeWorkloadResponse?
        do {
            expectedWarmupCompleted = try await responsesIterator.next()
        } catch {
            self._warmupFailureReason.withLock { $0 = "Failed to read warmup response: \(String(reportable: error))" }
            stateMachine.abandon()
            return
        }

        guard let expectedWarmupCompletedType = expectedWarmupCompleted?.type else {
            self._warmupFailureReason.withLock { $0 = "Got corrupt RPC message (warmup), without type" }
            stateMachine.abandon()
            return
        }
        guard case .warmupComplete(_) = expectedWarmupCompletedType else {
            self._warmupFailureReason.withLock { $0 = "Got message other than .warmupComplete" }
            stateMachine.abandon()
            return
        }
        do {
            try stateMachine.completeWarmup()
        } catch {
            self._warmupFailureReason.withLock {
                $0 = "completeWarmup failed unexpectedly: \(String(reportable: error))"
            }
            stateMachine.abandon()
            return
        }
        self.stats.warmupCompleted()
        self.span?.addEvent(
            SpanEvent(
                name: "cloud_app_warmup_complete",
                attributes: [
                    "warmupDurationMs":
                        "\(self.stats.durations().warmup.map { "\($0.inMilliseconds)" } ?? "")"
                ]
            )
        )

        guard let clientConnection = await self.waitForRequestStart() else {
            self.logger.info("onResponse exiting: request start abandoned")
            return
        }
        let responseOutput = clientConnection.output
        var isFirstResponse = true
        while true {
            let responseMessage: Proto_CloudApp_InvokeWorkloadResponse?
            do {
                responseMessage = try await responsesIterator.next()
            } catch {
                stateMachine.abandon(throwing: error)
                return
            }
            guard let responseMessage else { break }
            guard let type = responseMessage.type else {
                stateMachine.abandon(
                    throwing: CloudAppResponseError(message: "corrupt RPC message, without type")
                )
                return
            }

            switch type {
            case .warmupComplete:
                stateMachine.abandon(
                    throwing: CloudAppResponseError(message: "received duplicate warmupComplete")
                )
                return
            case .responseOutputData(let outputData):
                self.stats.responseChunkReceived()
                if isFirstResponse {
                    self.span?.addEvent(SpanEvent(name: "cloud_app_first_response_data_received"))
                    isFirstResponse = false
                }
                responseOutput.yield(outputData.message)
            case .keyDerivationRequest(let req):
                self.keyDerivation.accept(req)
            case .responseEndOfOutput(let eofResult):
                guard let eofResultType = eofResult.type else {
                    stateMachine.abandon(
                        throwing: CloudAppResponseError(message: "corrupt RPC message, eof without type")
                    )
                    return
                }
                switch eofResultType {
                case .success:
                    self.recordCloudAppDurations()
                    self.span?.addEvent(SpanEvent(name: "cloud_app_response_complete"))
                    do {
                        try stateMachine.finishRequestSuccessfully()
                    } catch {
                        self.logger.error(
                            "finishRequestSuccessfully failed unexpectedly",
                            metadata: [
                                "requestID": "\(self.requestID ?? "")",
                                "error": "\(String(reportable: error))",
                            ]
                        )
                        stateMachine.abandon(throwing: error)
                        return
                    }
                    return
                case .error(let errorMessage):
                    self.logger.error(
                        "CloudApp reported error",
                        metadata: [
                            "requestID": "\(self.requestID ?? "")",
                            "errorMessage": "\(errorMessage.message)",
                        ]
                    )
                    stateMachine.abandon(
                        throwing: CloudAppResponseError(message: errorMessage.message)
                    )
                    return
                }
            case .cloudAppComplete:
                if self.terminationReason != nil {
                    // The request was aborted via a client terminate, so the cloud app completing without a final
                    // response is expected. Abandon cleanly (no error) so the request winds down as a clean abort
                    // rather than surfacing a failure upstream.
                    stateMachine.abandon()
                } else {
                    stateMachine.abandon(
                        throwing: CloudAppResponseError(
                            message: "received cloudAppComplete before responseEndOfOutput"
                        )
                    )
                }
                return
            }
        }
        stateMachine.abandon(
            throwing: CloudAppResponseError(
                message: "Got to the end of response stream without .responseEndOfOutput"
            )
        )
    }

    func waitForWarmupToComplete() async -> WarmupOutcome {
        let waitResult = await MultiWaiter.waitFirst {
            try await self.stateMachine.waitUntil(state: .warmupCompleted)
        } _: {
            try await self.stateMachine.waitUntil(state: .abandoned)
        }
        switch waitResult {
        case .first(let result):
            guard (try? result.get()) != nil else {
                let reason = self._warmupFailureReason.withLock { $0 } ?? "unknown"
                return .failed(reason)
            }
            return .completed
        case .second:
            let reason = self._warmupFailureReason.withLock { $0 } ?? "unknown"
            return .failed(reason)
        }
    }

    private func waitForClientConnection() async throws -> ClientConnectionState {
        let waitResult = await MultiWaiter.waitFirst {
            try await self.stateMachine.waitUntil(state: .clientConnectionStarted)
        } _: {
            try await self.stateMachine.waitUntil(state: .abandoned)
        }
        switch waitResult {
        case .first(let result):
            let state = try result.get()
            guard case .clientConnectionStarted(let clientConnection) = state else {
                fatalError("Got unexpected state \(state)")
            }
            return clientConnection
        case .second:
            throw CancellationError()
        }
    }

    private func waitForRequestStart() async -> ClientConnectionState? {
        let waitResult = await MultiWaiter.waitFirst {
            try await self.stateMachine.waitUntil(state: .requestStarted)
        } _: {
            try await self.stateMachine.waitUntil(state: .abandoned)
        }
        switch waitResult {
        case .first(let result):
            guard let state = try? result.get() else {
                self.logger.info("waitForRequestStart: cancelled while waiting for request to start")
                return nil
            }
            guard case .requestStarted(let clientConnection) = state else {
                fatalError("Got unexpected state \(state)")
            }
            return clientConnection
        case .second:
            return nil
        }
    }

    private func waitForAnyTerminalState() async -> WorkloadHandlerStateMachineState? {
        let waitResult = await MultiWaiter.waitFirst {
            try await self.stateMachine.waitUntil(state: .requestFinishedSuccessfully)
        } _: {
            try await self.stateMachine.waitUntil(state: .abandoned)
        }
        switch waitResult {
        case .first(let result):
            if let state = try? result.get() { return state }
            self.logger.info("waitForAnyTerminalState: cancelled while waiting for terminal state")
            return nil
        case .second(let result):
            if let state = try? result.get() { return state }
            self.logger.info("waitForAnyTerminalState: cancelled while waiting for terminal state")
            return nil
        }
    }

    private func waitForInputOrTermination(
        input: _SendableStreamIterator<Data>
    ) async throws -> Data? {
        let waitResult = await MultiWaiter.waitFirst {
            await input.next()
        } _: {
            await self.waitForAnyTerminalState()
        }

        switch waitResult {
        case .first(let result):
            return try? result.get()
        case .second:
            return nil
        }
    }

    private func recordCloudAppDurations() {
        let durations = self.stats.durations()

        self.logger.info(
            "Cloud app request complete",
            metadata: [
                "requestID": "\(self.requestID ?? "")",
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
            ]
        )

        self.span?.addEvent(
            SpanEvent(
                name: "cloud_app_response_finished",
                attributes: [
                    "warmupDurationMs":
                        "\(durations.warmup.map { "\($0.inMilliseconds)" } ?? "")",
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
                ]
            )
        )
    }
}

extension Proto_CloudApp_InvokeWorkloadRequest.ConnectionContext.WorkloadParameter {
    init(_ ropesParameter: Proto_Ropes_Common_Workload.Parameter) {
        self = .with {
            $0.key = ropesParameter.key
            $0.value = ropesParameter.value
        }
    }
}

extension [String: [String]] {
    init(parameters: [Proto_Ropes_Common_Workload.Parameter]) {
        self = [:]

        for parameter in parameters {
            self[parameter.key, default: []].append(contentsOf: parameter.value)
        }
    }
}
