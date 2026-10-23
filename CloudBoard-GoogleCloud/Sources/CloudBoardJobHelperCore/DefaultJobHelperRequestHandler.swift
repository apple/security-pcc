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

import CloudBoardProtos
import CloudBoardUtilities
import Configuration
import Logging
import Metrics
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Real implementation of ``JobHelperRequestHandler`` that runs the full per-request pipeline:
/// OHTTP decryption → PCC protocol → chunking → cloud app.
package struct DefaultJobHelperRequestHandler: JobHelperRequestHandler {
    private static let logger = Logger(label: "cb_jobhelper.DefaultRequestHandler")

    private let attestedConfigReader: ConfigReader
    private let unattestedConfigReader: ConfigReader

    package init(
        attestedConfigReader: ConfigReader,
        unattestedConfigReader: ConfigReader
    ) {
        self.attestedConfigReader = attestedConfigReader
        self.unattestedConfigReader = unattestedConfigReader
    }

    package func run(
        input: AsyncStream<JobHelperPipelineInput>,
        output: AsyncStream<JobHelperPipelineOutput>.Continuation,
        stats: JobHelperRequestStatistics
    ) async throws {
        defer { output.finish() }

        var inputIterator = input.makeAsyncIterator()

        guard let firstInput = await inputIterator.next(),
            case .warmup(let cloudAppSocketPath) = firstInput
        else {
            output.yield(.pipelineFailed(reason: "Expected warmup as first input"))
            return
        }

        Self.logger.info("Received warmup. Starting cloud app warmup")
        let warmupStart = ContinuousClock.now

        try await withThrowingTaskGroup { group in
            let requestSecrets = RequestSecrets()
            let workloadHandler = WorkloadHandler(
                configReader: self.unattestedConfigReader,
                cloudAppSocketPath: cloudAppSocketPath,
                requestSecrets: requestSecrets
            )

            group.addTask { try await workloadHandler.run() }

            let warmupOutcome = await workloadHandler.waitForWarmupToComplete()
            if case .failed(let reason) = warmupOutcome {
                Self.logger.error("Cloud app warmup failed", metadata: ["reason": "\(reason)"])
                output.yield(.pipelineFailed(reason: "Cloud app warmup failed"))
                try await group.waitForAll()
                return
            }
            output.yield(.warmupComplete)

            let warmupDuration = ContinuousClock.now - warmupStart
            Self.logger.info(
                "Cloud app warmup complete",
                metadata: ["warmupDurationMs": "\(warmupDuration.inMilliseconds)"]
            )
            Timer(
                label: "cb_jobhelper_cloud_app_warmup_duration",
                preferredDisplayUnit: .milliseconds
            ).record(duration: warmupDuration)

            let connInput = await inputIterator.next()
            if case .terminate? = connInput {
                // The instance was retired before it handled a request. This is a clean shutdown, not a failure.
                // Gracefully wind down the idle cloud app handler.
                Self.logger.info("cb_jobhelper terminated before receiving a request")
                workloadHandler.shutdownWithoutRequest()
                try await group.waitForAll()
                return
            }
            guard case .connectionContext(let parameters, let keyProvider)? = connInput else {
                output.yield(.pipelineFailed(reason: "Expected connectionContext after warmup"))
                return
            }

            Self.logger.info("Processing request", metadata: ["requestID": "\(parameters.requestID)"])

            var context = ServiceContext.current ?? ServiceContext.topLevel
            InstrumentationSystem.instrument.extract(
                parameters,
                into: &context,
                using: InvokeWorkloadParametersExtractor()
            )

            try await withSpan("process_request", context: context) { span in
                span.attributes["request_id"] = "\(parameters.requestID)"
                span.attributes["tenant_info.automated_device_group"] =
                    "\(parameters.tenantInfo.automatedDeviceGroup)"
                span.attributes["tenant_info.bundle_id"] = "\(parameters.tenantInfo.bundleID)"
                span.attributes["tenant_info.bundle_version"] = "\(parameters.tenantInfo.bundleVersion)"
                span.attributes["tenant_info.client_info"] = "\(parameters.tenantInfo.clientInfo)"
                span.attributes["tenant_info.feature_id"] = "\(parameters.tenantInfo.featureID)"
                span.attributes["workload.type"] = "\(parameters.workload.type)"
                span.attributes["cloud_app.socket_path"] = cloudAppSocketPath
                span.attributes["cloud_app.warmup_duration_ms"] = warmupDuration.inMilliseconds

                do {
                    try await self.runDataPipeline(
                        span: span,
                        parameters: parameters,
                        attestedKeyProvider: keyProvider,
                        input: input,
                        output: output,
                        workloadHandler: workloadHandler,
                        stats: stats,
                        requestSecrets: requestSecrets
                    )
                    let durations = stats.durations()
                    span.addEvent(
                        SpanEvent(
                            name: "response_finished",
                            attributes: [
                                "requestID": "\(parameters.requestID)",
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
                    )
                } catch {
                    span.setStatus(.init(code: .error, message: "\(String(reportable: error))"))
                    let durations = stats.durations()
                    span.addEvent(
                        SpanEvent(
                            name: "response_finished",
                            attributes: [
                                "requestID": "\(parameters.requestID)",
                                "error": "\(String(reportable: error))",
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
                    )
                    // Rethrow wrapped so `withSpan`'s implicit `span.recordError(_:)` exports the redacted
                    // `String(reportable:)` form instead of reflecting the raw error's associated payload.
                    throw RedactedSpanError(underlying: error)
                }
            }

            try await group.waitForAll()
        }
    }

    private func runDataPipeline(
        span: any Span,
        parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters,
        attestedKeyProvider: any AttestedKeyProvider,
        input: AsyncStream<JobHelperPipelineInput>,
        output: AsyncStream<JobHelperPipelineOutput>.Continuation,
        workloadHandler: WorkloadHandler,
        stats: JobHelperRequestStatistics,
        requestSecrets: RequestSecrets
    ) async throws {
        let streams = DataPipelineStreams()

        let ohttpHandler = OHTTPEncryptionHandler(
            attestedKeyProvider: attestedKeyProvider,
            parameters: parameters,
            requestSecrets: requestSecrets
        )
        let pccProtocolHandler = PrivateCloudComputeProtocolHandler(
            configReader: self.attestedConfigReader,
            parameters: parameters,
            stats: stats
        )
        let chunkingHandler = ApplicationLayerChunkingHandler(
            configReader: self.attestedConfigReader,
            parameters: parameters
        )

        try await withThrowingTaskGroup(of: Void.self) { pipelineGroup in
            pipelineGroup.addTask {
                var iter = input.makeAsyncIterator()
                defer { streams.encryptedRequestInputContinuation.finish() }
                while let input = await iter.next() {
                    switch input {
                    case .requestChunk(let chunk):
                        streams.encryptedRequestInputContinuation.yield(chunk)
                        if chunk.isFinal { return }
                    case .terminate:
                        // Mark the request as aborted so the PCC handler treats the imminent end of the (truncated)
                        // request stream as a clean abort rather than `streamEndedWithoutFinalChunk`. This must happen
                        // before the `defer` finishes the encrypted request stream below.
                        pccProtocolHandler.terminate()
                        workloadHandler.terminate(reason: "request terminated by cloudboardd")
                        return
                    case .warmup, .connectionContext:
                        Self.logger.warning("Unexpected pipeline input")
                    }
                }
            }

            pipelineGroup.addTask {
                try await ohttpHandler.run(
                    span: span,
                    requestInput: streams.encryptedRequestInput,
                    requestOutput: streams.decryptedRequestContinuation,
                    responseInput: streams.encodedResponses,
                    responseOutput: streams.encryptedResponseContinuation
                )
            }

            pipelineGroup.addTask {
                try await pccProtocolHandler.run(
                    span: span,
                    requestInput: streams.decryptedRequest,
                    requestOutput: streams.chunkedPayloadsContinuation,
                    responseInput: streams.chunkedResponses,
                    responseOutput: streams.encodedResponsesContinuation
                )
            }

            pipelineGroup.addTask {
                let caps = try await pccProtocolHandler.getCapabilities()
                await chunkingHandler.run(
                    span: span,
                    chunking: caps.applicationDataChunking,
                    requestInput: streams.chunkedPayloads,
                    requestOutput: streams.appPayloadsContinuation,
                    responseInput: streams.appResponses,
                    responseOutput: streams.chunkedResponsesContinuation
                )
            }

            pipelineGroup.addTask {
                let warmupOutcome = await workloadHandler.waitForWarmupToComplete()
                if case .failed(let reason) = warmupOutcome {
                    Self.logger.error(
                        "Cloud app warmup failed, aborting request",
                        metadata: ["requestID": "\(parameters.requestID)", "reason": "\(reason)"]
                    )
                    streams.appResponsesContinuation.finish(
                        throwing: CloudAppResponseError(message: "cloud app failed during warmup")
                    )
                    return
                }
                try workloadHandler.startClientConnection(
                    span: span,
                    parameters: parameters,
                    opaqueCryptoMaterialProvider: { try await pccProtocolHandler.getOpaqueCryptoMaterial() },
                    requestInput: streams.appPayloads,
                    responseOutput: streams.appResponsesContinuation
                )
            }

            pipelineGroup.addTask {
                for await chunk in streams.encryptedResponse {
                    output.yield(.responseChunk(FinalizableChunk(chunk: chunk.chunk, isFinal: chunk.isFinal)))
                }
                output.yield(.responseCompleted)
            }

            // next() rather than waitForAll() so we throw out of the task group and cancel all siblings
            while let _ = try await pipelineGroup.next() {}
        }
    }
}

/// Wraps an error thrown out of a ``withSpan`` operation so that the tracing pipeline's implicit
/// `span.recordError(_:)` (exported by swift-otel via `String(describing:)`) records the redacted
/// `String(reportable:)` form rather than the raw error, whose reflection can dump associated
/// request payload for proto enums. The wrapper is transparent to the rest of the error-handling
/// path: it forwards `ReportableError`, which is the only thing consulted on the errors that escape
/// the span, so logging and metrics are unaffected.
private struct RedactedSpanError: Error, CustomStringConvertible, ReportableError {
    let underlying: any Error
    var publicDescription: String { String(reportable: self.underlying) }
    var description: String { self.publicDescription }
}

private struct DataPipelineStreams: Sendable {
    let encryptedRequestInput: AsyncStream<FinalizableChunk<Data>>
    let encryptedRequestInputContinuation: AsyncStream<FinalizableChunk<Data>>.Continuation
    let decryptedRequest: AsyncStream<FinalizableChunk<Data>>
    let decryptedRequestContinuation: AsyncStream<FinalizableChunk<Data>>.Continuation
    let chunkedPayloads: AsyncStream<Data>
    let chunkedPayloadsContinuation: AsyncStream<Data>.Continuation
    let appPayloads: AsyncStream<Data>
    let appPayloadsContinuation: AsyncStream<Data>.Continuation

    let appResponses: AsyncThrowingStream<Data, any Error>
    let appResponsesContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    let chunkedResponses: AsyncThrowingStream<Data, any Error>
    let chunkedResponsesContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    let encodedResponses: AsyncStream<FinalizableChunk<Data>>
    let encodedResponsesContinuation: AsyncStream<FinalizableChunk<Data>>.Continuation
    let encryptedResponse: AsyncStream<FinalizableChunk<Data>>
    let encryptedResponseContinuation: AsyncStream<FinalizableChunk<Data>>.Continuation

    init() {
        (encryptedRequestInput, encryptedRequestInputContinuation) = AsyncStream.makeStream()
        (decryptedRequest, decryptedRequestContinuation) = AsyncStream.makeStream()
        (chunkedPayloads, chunkedPayloadsContinuation) = AsyncStream.makeStream()
        (appPayloads, appPayloadsContinuation) = AsyncStream.makeStream()
        (appResponses, appResponsesContinuation) = AsyncThrowingStream.makeStream()
        (chunkedResponses, chunkedResponsesContinuation) = AsyncThrowingStream.makeStream()
        (encodedResponses, encodedResponsesContinuation) = AsyncStream.makeStream()
        (encryptedResponse, encryptedResponseContinuation) = AsyncStream.makeStream()
    }
}
