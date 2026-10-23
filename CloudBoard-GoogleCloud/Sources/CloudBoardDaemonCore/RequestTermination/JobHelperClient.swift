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
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Client that delegates per-request processing to cb_jobhelper over the `JobHelper.InvokeWorkload` gRPC API.
///
/// Follows the following lifecycle:
/// 1. ``run(client:)`` establishes the gRPC connection and starts the bidirectional stream
/// 2. External caller awaits ``waitForWarmupToComplete()``
/// 3. External caller calls ``startRequest(_:)`` to provide the request context
final class JobHelperClient: Sendable {
    private let logger = Logger(label: "cloudboardd.JobHelperClient")
    let stateMachine = JobHelperClientStateMachine()
    private let cloudAppSocket: SocketAddress.UnixDomainSocket
    private let terminateStream: AsyncStream<String>
    fileprivate let _terminateContinuation: AsyncStream<String>.Continuation

    init(cloudAppSocket: SocketAddress.UnixDomainSocket) {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.cloudAppSocket = cloudAppSocket
        self.terminateStream = stream
        self._terminateContinuation = continuation
    }

    func run<Transport: ClientTransport>(client: GRPCClient<Transport>) async throws {
        let jobHelper = Proto_JobHelper_JobHelper.Client(wrapping: client)

        try await jobHelper.invokeWorkload(
            requestProducer: { writer in
                try await self.requestProducer(writer: writer)
            },
            onResponse: { response in
                try await self.onResponse(response: response)
            }
        )
    }

    func waitForWarmupToComplete() async throws {
        let result = await MultiWaiter.waitFirst {
            try await self.stateMachine.waitUntil(state: .warmupComplete)
        } _: {
            try await self.stateMachine.waitUntil(state: .failed)
        }
        switch result {
        case .first(let outcome):
            _ = try outcome.get()
        case .second(let outcome):
            _ = try outcome.get()
            try self.stateMachine.throwAfterFailure()
        }
    }

    /// Waits for cb_jobhelper to reach a terminal state, i.e., to either finish processing the request and
    /// send the `.completed` message, or fail.
    func waitForCompletion() async throws {
        let result = await MultiWaiter.waitFirst {
            try await self.stateMachine.waitUntil(state: .failed)
        } _: {
            try await self.stateMachine.waitUntil(state: .finished)
        }
        switch result {
        case .first(let outcome):
            _ = try outcome.get()
            try self.stateMachine.throwAfterFailure()
        case .second(let outcome):
            _ = try outcome.get()
        }
    }

    func startRequest(_ context: JobHelperClientRequestContext) throws {
        try self.stateMachine.startRequest(context)
    }

    func terminate(reason: String = "early shutdown") {
        do {
            try self.stateMachine.sendTerminate()
        } catch {
            self.logger.debug(
                "sendTerminate failed (already in terminal state)",
                metadata: ["error": "\(String(reportable: error))"]
            )
            return
        }
        self._terminateContinuation.yield(reason)
        self._terminateContinuation.finish()
    }

    private func waitForRequest() async throws -> JobHelperClientRequestContext {
        let result = await MultiWaiter.waitFirst {
            try await self.stateMachine.waitUntil(state: .requestStarted)
        } _: {
            try await self.stateMachine.waitUntil(state: .failed)
        }
        switch result {
        case .first(let outcome):
            let state = try outcome.get()
            guard case .requestStarted(let context) = state else {
                fatalError("Expected requestStarted state")
            }
            return context
        case .second(let outcome):
            _ = try outcome.get()
            try self.stateMachine.throwAfterFailure()
        }
    }

    private enum RequestTaskGroupResult {
        case requestStreamFinished(Error?)
        case terminationSignalStreamFinished(Error?)
    }

    private func requestProducer(
        writer: RPCWriter<Proto_JobHelper_InvokeWorkloadRequest>
    ) async throws {
        try self.stateMachine.sendWarmupContext()
        self.logger.info("Sending WarmupContext")
        try await writer.write(
            .with {
                $0.warmupContext = .with {
                    $0.cloudAppSocketPath = self.cloudAppSocket.path
                }
            }
        )

        try await withThrowingTaskGroup(of: RequestTaskGroupResult.self) { group in
            // Process request stream
            group.addTask {
                do {
                    let context = try await self.waitForRequest()
                    let requestID = context.parameters.requestID

                    try self.stateMachine.sendConnectionContext()
                    self.logger.info("Sending ConnectionContext", metadata: ["requestID": "\(requestID)"])
                    try await writer.write(
                        .with {
                            $0.connectionContext = .with {
                                $0.parameters = context.parameters
                                $0.keyHandle = context.keyHandle
                            }
                        }
                    )

                    for await chunk in context.requestInput {
                        try self.stateMachine.sendRequestChunk()
                        try await writer.write(
                            .with {
                                $0.requestChunk = .with {
                                    $0.encryptedPayload = chunk.chunk
                                    $0.isFinal = chunk.isFinal
                                }
                            }
                        )
                    }
                    return .requestStreamFinished(nil)
                } catch {
                    self.logger.error(
                        "Error while forwarding request chunks",
                        metadata: ["error": "\(String(reportable: error))"]
                    )
                    return .requestStreamFinished(error)
                }
            }

            // Wait for termination signals
            group.addTask {
                do {
                    var terminateIterator = self.terminateStream.makeAsyncIterator()
                    if let reason = await terminateIterator.next(isolation: nil) {
                        self.logger.info(
                            "Sending termination signal",
                            metadata: [
                                "reason": "\(reason)"
                            ]
                        )
                        try await writer.write(.with { $0.terminate = .with { $0.reason = reason } })
                    }
                    return .terminationSignalStreamFinished(nil)
                } catch {
                    self.logger.error(
                        "Error while forwarding termination signal",
                        metadata: ["error": "\(String(reportable: error))"]
                    )
                    return .terminationSignalStreamFinished(error)
                }
            }
            while let result = try await group.next() {
                switch result {
                case .requestStreamFinished(let error):
                    if let error {
                        throw error
                    }
                // Continue to wait for (early) termination signal
                case .terminationSignalStreamFinished(let error):
                    if let error {
                        throw error
                    }
                    // We've forwarded the termination signal and the request-stream task is no longer needed. Cancel it
                    // and break out of the loop to avoid throwing on the next `try await group.next()` call.
                    group.cancelAll()
                    return
                }
            }
        }
    }

    private func onResponse(
        response: StreamingClientResponse<Proto_JobHelper_InvokeWorkloadResponse>
    ) async throws {
        var responseOutput: AsyncThrowingStream<FinalizableChunk<Data>, any Error>.Continuation?
        defer { responseOutput?.finish() }

        for try await message in response.messages {
            // The warmupComplete message arrives before any caller has called startRequest,
            // so we can't look up the response continuation yet. Every other message means
            // we're in the response phase and a request has been started — grab the
            // continuation here so .error and .completed have it even if no .responseChunk
            // ever arrived (e.g. OHTTP-layer failure produces only .completed.unclean).
            if case .warmupComplete = message.type {
                try self.stateMachine.receiveWarmupComplete()
                self.logger.info("cb_jobhelper warmup complete")
                continue
            }
            if responseOutput == nil {
                guard let requestState = try await self.waitForRequestStarted() else {
                    // Terminated before a request started (e.g. a warmed instance retired during
                    // warmup-pool capacity reduction). There is no response to deliver, so wind
                    // down cleanly rather than treating it as a failure.
                    self.logger.debug("Terminated before a request started, no response to deliver")
                    return
                }
                responseOutput = requestState.responseOutput
            }

            switch message.type {
            case .warmupComplete:
                preconditionFailure("warmupComplete handled above")
            case .responseChunk(let chunk):
                try self.stateMachine.receiveResponseChunk()
                responseOutput?.yield(FinalizableChunk(chunk: chunk.encryptedPayload, isFinal: chunk.isFinal))
                if chunk.isFinal {
                    responseOutput?.finish()
                }
            case .error(let error):
                try self.stateMachine.receiveError()
                self.logger.error("cb_jobhelper reported error", metadata: ["error": "\(error.message)"])
                responseOutput?.finish(throwing: JobHelperClientError.remoteError(error.message))
                return
            case .completed(let completed):
                try self.stateMachine.receiveCompleted()
                self.logger.info("cb_jobhelper completed", metadata: ["status": "\(completed.status)"])
                switch completed.status {
                case .unclean:
                    responseOutput?.finish(throwing: JobHelperClientError.uncleanCompletion)
                default:
                    responseOutput?.finish()
                }
                return
            case .none:
                self.logger.warning("Received unknown message type from cb_jobhelper")
            }
        }

        try self.stateMachine.receiveResponseStreamEnd()
    }

    /// Resolves the in-flight request context for the response side, or `nil` if the request was terminated before any
    /// request started (e.g. a prewarmed instance retired during warmup-pool capacity reduction), in which case there
    /// is no response to deliver.
    private func waitForRequestStarted() async throws -> JobHelperClientRequestContext? {
        let result = await MultiWaiter.waitFirst {
            try await self.stateMachine.waitUntil(state: .requestStarted)
        } _: {
            try await self.stateMachine.waitUntil(state: .streaming)
        } _: {
            // The request may have been terminated early (e.g. client abort). The response side still needs the context
            // to deliver cb_jobhelper's completion, so accept it here.
            try await self.stateMachine.waitUntil(state: .terminating)
        } _: {
            try await self.stateMachine.waitUntil(state: .failed)
        }
        switch result {
        case .first(let outcome):
            let state = try outcome.get()
            guard case .requestStarted(let context) = state else {
                fatalError("Expected requestStarted state")
            }
            return context
        case .second(let outcome):
            let state = try outcome.get()
            guard case .streaming(let context) = state else {
                fatalError("Expected streaming state")
            }
            return context
        case .third(let outcome):
            let state = try outcome.get()
            guard case .terminating(let context) = state else {
                fatalError("Expected terminating state")
            }
            // A nil context means we terminated before a request started, so there is nothing to deliver. The caller
            // winds down cleanly rather than treating it as a failure.
            return context
        case .fourth(let outcome):
            _ = try outcome.get()
            try self.stateMachine.throwAfterFailure()
        }
    }
}

enum JobHelperClientError: Error, ReportableError {
    case remoteError(String)
    case uncleanCompletion

    var publicDescription: String {
        switch self {
        case .remoteError:
            return "JobHelperClientError.remoteError"
        case .uncleanCompletion:
            return "JobHelperClientError.uncleanCompletion"
        }
    }
}

extension JobHelperClientError: RPCErrorConvertible {
    var rpcErrorCode: RPCError.Code { .internalError }

    var rpcErrorMessage: String {
        switch self {
        case .remoteError(let message):
            return "cb_jobhelper reported error: \(message)"
        case .uncleanCompletion:
            return "cb_jobhelper completed uncleanly"
        }
    }
}

private enum JobHelperClientLifecycleState<Result>: Sendable where Result: Sendable {
    case clientFinished
    case clientFailed(Error)
    case bodyFinished(Result)
    case bodyFailed(Error)
}

/// Provides a client to an active cb_jobhelper instance. This function takes care of cb_jobhelper lifecycle management.
/// Adopters must not call ``JobHelperClient.run`` themselves.
func withJobHelperClient<Transport: ClientTransport, Result>(
    grpcClient: GRPCClient<Transport>,
    cloudAppSocket: SocketAddress.UnixDomainSocket,
    _ body: @escaping @Sendable (JobHelperClient) async throws -> Result
) async throws -> Result where Result: Sendable {
    let logger = Logger(label: "cloudboardd.JobHelperClient")

    let jobHelperClient = JobHelperClient(cloudAppSocket: cloudAppSocket)
    defer { jobHelperClient._terminateContinuation.finish() }

    return try await withThrowingTaskGroup(of: JobHelperClientLifecycleState<Result>.self) { group in
        group.addTask {
            do {
                try await jobHelperClient.run(client: grpcClient)
                return .clientFinished
            } catch {
                return .clientFailed(error)
            }
        }

        group.addTask {
            do {
                return .bodyFinished(try await body(jobHelperClient))
            } catch {
                return .bodyFailed(error)
            }
        }

        var bodyResult: Result?
        var bodyError: Error?
        while let taskResult = try await group.next() {
            switch taskResult {
            case .clientFinished:
                break
            case .clientFailed(let error):
                if Task.isCancelled {
                    // The surrounding task was cancelled, e.g. the warmup pool retiring this instance (capacity
                    // reduction / max lifetime) or the pool shutting down. That is expected teardown, not a failure.
                    logger.debug(
                        "Job helper wound down due to cancellation",
                        metadata: [
                            "error": "\(String(reportable: error))"
                        ]
                    )
                } else {
                    // Job helper was lost in some way, the process is expected to clean up itself at this point.
                    logger.error("Job helper failed", metadata: ["error": "\(String(reportable: error))"])
                }
            case .bodyFinished(let result):
                logger.info("Releasing job helper. Sending terminate signal.")
                jobHelperClient.terminate(reason: "request handling completed or finished early due to cancellation")
                bodyResult = result
            case .bodyFailed(let error):
                if Task.isCancelled {
                    // Expected teardown via cancellation (pool retirement / shutdown), not a failure.
                    logger.debug(
                        "Job helper wound down due to cancellation. Sending termination signal.",
                        metadata: ["error": "\(String(reportable: error))"]
                    )
                } else {
                    logger.error(
                        "Failure while using job helper. Sending termination signal, and awaiting job helper termination.",
                        metadata: ["error": "\(String(reportable: error))"]
                    )
                }
                jobHelperClient.terminate(reason: "request handling failed")
                bodyError = error
            }
        }

        if let bodyResult {
            return bodyResult
        } else if let bodyError {
            throw bodyError
        }
        fatalError("Unexpectedly reached end of withJobHelperClient without result or error")
    }
}
