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

import CloudAttestationV2
import CloudBoardProtos
import CloudBoardUtilities
import Configuration
import Crypto
import GRPCCore
import Logging
import ServiceLifecycle

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// gRPC service implementing the cb_jobhelper API for communication with cloudboardd.
///
/// Owns the gRPC protocol (state machine, message routing). Delegates actual
/// per-request processing to a ``JobHelperRequestHandler``.
package final class JobHelperGRPCService: Sendable {
    private static let logger = Logger(label: "cb_jobhelper.JobHelperGRPCService")

    private let requestHandler: any JobHelperRequestHandler
    private let keyStore: (any CloudAttestationV2.KeyStore)?
    private let serviceGroup: ServiceGroup?

    package init(
        requestHandler: any JobHelperRequestHandler,
        keyStore: (any CloudAttestationV2.KeyStore)? = nil,
        serviceGroup: ServiceGroup? = nil
    ) {
        self.requestHandler = requestHandler
        self.keyStore = keyStore
        self.serviceGroup = serviceGroup
    }
}

extension JobHelperGRPCService: Proto_JobHelper_JobHelper.ServiceProtocol {
    package func invokeWorkload(
        request: GRPCCore.StreamingServerRequest<Proto_JobHelper_InvokeWorkloadRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<Proto_JobHelper_InvokeWorkloadResponse> {
        .init { writer in
            try await asyncDefer {
                if let serviceGroup = self.serviceGroup {
                    await serviceGroup.triggerGracefulShutdown()
                }
            } untilAfter: {
                try await context.withTaskCancellationOnRPCCancellation {
                    try await self.runInvokeWorkloadPipeline(request: request, writer: writer)
                }
                return Metadata()
            }
        }
    }

    private func runInvokeWorkloadPipeline(
        request: GRPCCore.StreamingServerRequest<Proto_JobHelper_InvokeWorkloadRequest>,
        writer: RPCWriter<Proto_JobHelper_InvokeWorkloadResponse>
    ) async throws {
        let stats = JobHelperRequestStatistics(grpcCallStart: ContinuousClock.now)
        var pipelineError: (any Error)?
        defer { self.recordRequestSummary(stats: stats, error: pipelineError) }

        let stateMachine = JobHelperServiceStateMachine()
        let (pipelineInput, pipelineInputContinuation) = AsyncStream<JobHelperPipelineInput>.makeStream()
        let (pipelineOutput, pipelineOutputContinuation) = AsyncStream<JobHelperPipelineOutput>.makeStream()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.requestHandler.run(
                        input: pipelineInput,
                        output: pipelineOutputContinuation,
                        stats: stats
                    )
                }

                group.addTask {
                    try await self.readGRPCInput(
                        request: request,
                        stateMachine: stateMachine,
                        pipelineInput: pipelineInputContinuation,
                        stats: stats
                    )
                }

                group.addTask {
                    try await self.writeGRPCOutput(
                        pipelineOutput: pipelineOutput,
                        stateMachine: stateMachine,
                        writer: writer,
                        stats: stats
                    )
                }

                // next() rather than waitForAll() so we throw out of the task group and cancel all siblings
                while let _ = try await group.next() {}
            }
        } catch {
            pipelineError = error
            Self.logger.error(
                "Pipeline error",
                metadata: ["error": "\(String(reportable: error))"]
            )
        }

        let completionStatus: Proto_JobHelper_InvokeWorkloadResponse.Completed.Status =
            pipelineError == nil ? .clean : .unclean
        try? stateMachine.sendCompleted()
        try await writer.write(
            .with {
                $0.completed = .with { $0.status = completionStatus }
            }
        )
        Self.logger.info("Sent Completed", metadata: ["status": "\(completionStatus)"])
    }

    private func readGRPCInput(
        request: GRPCCore.StreamingServerRequest<Proto_JobHelper_InvokeWorkloadRequest>,
        stateMachine: JobHelperServiceStateMachine,
        pipelineInput: AsyncStream<JobHelperPipelineInput>.Continuation,
        stats: JobHelperRequestStatistics
    ) async throws {
        defer { pipelineInput.finish() }

        for try await message in request.messages {
            switch message.type {
            case .warmupContext(let warmupContext):
                try stateMachine.receiveWarmupContext()
                stats.warmupContextReceived()
                Self.logger.info("Received WarmupContext")
                pipelineInput.yield(.warmup(cloudAppSocketPath: warmupContext.cloudAppSocketPath))

            case .connectionContext(let connectionContext):
                try stateMachine.receiveConnectionContext()
                stats.connectionContextReceived(connectionContext.parameters)
                let keyProvider: any AttestedKeyProvider
                if let keyStore = self.keyStore {
                    keyProvider = try WSDKeyProvider(
                        keyStore: keyStore,
                        keyHandle: connectionContext.keyHandle
                    )
                } else {
                    // Test-only path: no keystore configured
                    keyProvider = UnconfiguredKeyProvider()
                }
                Self.logger.info(
                    "Received ConnectionContext",
                    metadata: ["requestID": "\(connectionContext.parameters.requestID)"]
                )
                pipelineInput.yield(
                    .connectionContext(
                        parameters: connectionContext.parameters,
                        attestedKeyProvider: keyProvider
                    )
                )

            case .requestChunk(let chunk):
                try stateMachine.receiveRequestChunk()
                stats.requestChunkReceived(
                    isFinal: chunk.isFinal,
                    encryptedByteCount: chunk.encryptedPayload.count
                )
                pipelineInput.yield(
                    .requestChunk(
                        FinalizableChunk(
                            chunk: chunk.encryptedPayload,
                            isFinal: chunk.isFinal
                        )
                    )
                )

            case .terminate(let terminate):
                try stateMachine.receiveTerminate()
                stats.terminateReceived()
                Self.logger.info(
                    "Received Terminate",
                    metadata: ["reason": "\(terminate.reason)"]
                )
                pipelineInput.yield(.terminate)

            case .none:
                Self.logger.warning("Received message with no type")
            }
        }
    }

    private func writeGRPCOutput(
        pipelineOutput: AsyncStream<JobHelperPipelineOutput>,
        stateMachine: JobHelperServiceStateMachine,
        writer: RPCWriter<Proto_JobHelper_InvokeWorkloadResponse>,
        stats: JobHelperRequestStatistics
    ) async throws {
        for await output in pipelineOutput {
            if stateMachine.isTerminating { continue }

            switch output {
            case .warmupComplete:
                try stateMachine.sendWarmupComplete()
                try await writer.write(.with { $0.warmupComplete = .init() })
                stats.warmupCompleteSent()
                Self.logger.info("Sent WarmupComplete")

            case .responseChunk(let chunk):
                try stateMachine.sendResponseChunk()
                try await writer.write(
                    .with {
                        $0.responseChunk = .with {
                            $0.encryptedPayload = chunk.chunk
                            $0.isFinal = chunk.isFinal
                        }
                    }
                )
                stats.responseChunkSent(isFinal: chunk.isFinal, encryptedByteCount: chunk.chunk.count)

            case .responseCompleted:
                Self.logger.info("Request processing complete")

            case .pipelineFailed(let reason):
                try stateMachine.sendError()
                try await writer.write(
                    .with {
                        $0.error = .with { $0.message = "\(reason)" }
                    }
                )
                Self.logger.error("Pipeline failed", metadata: ["reason": "\(reason)"])
                throw JobHelperPipelineError(reason: reason)
            }
        }
    }

    private func recordRequestSummary(stats: JobHelperRequestStatistics, error: (any Error)?) {
        let durations = stats.durations()
        let parameters = stats.parameters
        let traceID =
            parameters.flatMap { $0.hasTraceContext ? $0.traceContext.traceID.hexEncoded : nil } ?? ""
        Self.logger.log(
            level: error == nil ? .info : .error,
            "JobHelper request summary",
            metadata: [
                "requestID": "\(parameters?.requestID ?? "")",
                "error": "\(error.map { String(reportable: $0) } ?? "")",
                "pccProtocolError": "\(stats.pccProtocolError.map { String(reportable: $0) } ?? "")",
                "pccProtocolResponseStatus": "\(stats.pccProtocolResponseStatus.map { "\($0)" } ?? "")",
                "bundleID": "\(parameters?.tenantInfo.bundleID ?? "")",
                "bundleVersion": "\(parameters?.tenantInfo.bundleVersion ?? "")",
                "featureID": "\(parameters?.tenantInfo.featureID ?? "")",
                "clientInfo": "\(parameters?.tenantInfo.clientInfo ?? "")",
                "automatedDeviceGroup": "\(parameters?.tenantInfo.automatedDeviceGroup ?? "")",
                "workloadType": "\(parameters?.workload.type ?? "")",
                "traceID": "\(traceID)",
                "requestChunksReceived": "\(stats.requestChunksReceived)",
                "finalRequestChunkReceived": "\(stats.finalRequestChunkReceived)",
                "encryptedRequestBytesReceived": "\(stats.encryptedRequestBytesReceived)",
                "responseChunksSent": "\(stats.responseChunksSent)",
                "finalResponseChunkSent": "\(stats.finalResponseChunkSent)",
                "encryptedResponseBytesSent": "\(stats.encryptedResponseBytesSent)",
                "totalMs": "\(durations.total.map { "\($0.inMilliseconds)" } ?? "")",
                "warmupMs": "\(durations.warmup.map { "\($0.inMilliseconds)" } ?? "")",
                "warmupCompleteToConnectionContextMs":
                    "\(durations.warmupCompleteToConnectionContext.map { "\($0.inMilliseconds)" } ?? "")",
                "connectionContextToFirstRequestChunkMs":
                    "\(durations.connectionContextToFirstRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
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
                "terminateReceivedToCallEndMs":
                    "\(durations.terminateReceivedToCallEnd.map { "\($0.inMilliseconds)" } ?? "")",
            ]
        )
    }
}

private struct JobHelperPipelineError: Error {
    let reason: StaticString
}

extension JobHelperPipelineError: ReportableError {
    var publicDescription: String {
        "JobHelperPipelineError: \(self.reason)"
    }
}

/// Placeholder used when ``JobHelperGRPCService`` is constructed without a keystore, e.g.
/// by tests whose request handlers don't actually decrypt anything. Any real key lookup
/// against this provider is a programming error.
private struct UnconfiguredKeyProvider: AttestedKeyProvider, Sendable {
    struct NotConfiguredError: Error, ReportableError {
        var publicDescription: String { "UnconfiguredKeyProvider.NotConfiguredError" }
    }

    func key(for _: Data) async throws -> any HPKEKEMPrivateKey {
        throw NotConfiguredError()
    }
}
