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
import Configuration
import LengthPrefixChunking
import Logging
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Handler responsible for application-layer data chunking/reassembly.
///
/// This handler sits between the PCC protocol handler and the workload handler to:
/// - Reassemble length-prefixed chunked request data from clients that support chunking
/// - Chunk response data for clients that support chunking
///
/// If the client does not support chunking (chunk size is nil or 0), this handler
/// passes data through unchanged.
final class ApplicationLayerChunkingHandler: Sendable {
    private let logger: Logger
    private let requestID: String
    private let maxMessageSize: Int

    init(
        configReader: ConfigReader,
        parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters
    ) {
        self.logger = Logger(label: "cb_jobhelper.ApplicationLayerChunkingHandler")
        self.requestID = parameters.requestID
        self.maxMessageSize = configReader.int(
            forKey: "applicationchunking.maxmessagesize",
            default: 100 * 1024 * 1024  // 100 MB
        )
    }

    func run(
        span: any Span,
        chunking: ApplicationDataChunking,
        requestInput: AsyncStream<Data>,
        requestOutput: AsyncStream<Data>.Continuation,
        responseInput: AsyncThrowingStream<Data, any Error>,
        responseOutput: AsyncThrowingStream<Data, any Error>.Continuation
    ) async {
        defer {
            self.logger.info(
                "Application layer chunking handler completed",
                metadata: ["requestID": "\(self.requestID)"]
            )
        }
        switch chunking {
        case .disabled:
            logger.info(
                "Application layer chunking disabled, passing through",
                metadata: ["requestID": "\(self.requestID)"]
            )
        case .enabled(let config):
            logger.info(
                "Application layer chunking enabled",
                metadata: ["requestID": "\(self.requestID)", "chunkSize": "\(config.chunkSize)"]
            )
        }

        await withThrowingTaskGroup(of: Void.self) { group in
            // Request path: reassemble chunked data
            group.addTask {
                try await self.processRequests(
                    span: span,
                    input: requestInput,
                    output: requestOutput,
                    chunking: chunking
                )
            }

            // Response path: chunk data
            group.addTask {
                await self.processResponses(
                    span: span,
                    input: responseInput,
                    output: responseOutput,
                    chunking: chunking
                )
            }

            // Finish responseOutput with the real error before calling cancelAll() so we
            // win the race against processResponses catching CancellationError and calling
            // output.finish(throwing: CancellationError()) in its own catch block.
            var failed = false
            while let result = await group.nextResult() {
                if case .failure(let error) = result, !failed {
                    failed = true
                    responseOutput.finish(throwing: error)
                    group.cancelAll()
                }
            }

            if !failed {
                responseOutput.finish()
            }
        }
    }

    private func processRequests(
        span: any Span,
        input: AsyncStream<Data>,
        output: AsyncStream<Data>.Continuation,
        chunking: ApplicationDataChunking
    ) async throws {
        defer {
            self.logger.info("Request processing complete", metadata: ["requestID": "\(self.requestID)"])
            output.finish()
            span.addEvent(SpanEvent(name: "chunking_handler_request_complete"))
        }
        var assembledFirstRequestMessage = false
        var receivedFirstRequestChunk = false
        do {
            switch chunking {
            case .enabled:
                // Buffer and re-assemble length-prefixed messages
                var assembler = LengthPrefixAssembler(maxMessageSize: self.maxMessageSize)

                for await chunk in input {
                    if !receivedFirstRequestChunk {
                        self.logger.info(
                            "Chunking handler received first request chunk",
                            metadata: ["requestID": "\(self.requestID)"]
                        )
                        receivedFirstRequestChunk = true
                    }
                    self.logger.debug(
                        "Reassembling request chunk",
                        metadata: ["requestID": "\(self.requestID)"]
                    )
                    let messages = try assembler.append(chunk)
                    for message in messages {
                        self.logger.debug(
                            "Reassembled complete message",
                            metadata: ["requestID": "\(self.requestID)"]
                        )
                        if !assembledFirstRequestMessage {
                            span.addEvent(SpanEvent(name: "chunking_handler_first_request_message"))
                            assembledFirstRequestMessage = true
                        }
                        output.yield(message)
                    }
                }

                try assembler.finish()
            case .disabled:
                // Pass through unchanged
                for await data in input {
                    if !receivedFirstRequestChunk {
                        self.logger.info(
                            "Chunking handler received first request chunk",
                            metadata: ["requestID": "\(self.requestID)"]
                        )
                        receivedFirstRequestChunk = true
                    }
                    if !assembledFirstRequestMessage {
                        span.addEvent(SpanEvent(name: "chunking_handler_first_request_message"))
                        assembledFirstRequestMessage = true
                    }
                    output.yield(data)
                }
            }
        } catch {
            self.logger.error(
                "Request reassembly failed",
                metadata: ["requestID": "\(self.requestID)", "error": "\(String(reportable: error))"]
            )
            throw error
        }
    }

    private func processResponses(
        span: any Span,
        input: AsyncThrowingStream<Data, any Error>,
        output: AsyncThrowingStream<Data, any Error>.Continuation,
        chunking: ApplicationDataChunking
    ) async {
        defer {
            self.logger.info("Response processing complete", metadata: ["requestID": "\(self.requestID)"])
            span.addEvent(SpanEvent(name: "chunking_handler_response_complete"))
        }
        var isFirst = true
        do {
            switch chunking {
            case .enabled(let config):
                let chunker = try LengthPrefixChunker(chunkSize: config.chunkSize)

                for try await data in input {
                    self.logger.debug(
                        "Chunking response",
                        metadata: ["requestID": "\(self.requestID)"]
                    )
                    let chunks = try chunker.chunkData(data: data)
                    for chunk in chunks {
                        self.logger.debug(
                            "Yielding response chunk",
                            metadata: ["requestID": "\(self.requestID)"]
                        )
                        if isFirst {
                            span.addEvent(SpanEvent(name: "chunking_handler_first_response_message"))
                            isFirst = false
                        }
                        output.yield(chunk)
                    }
                }
            case .disabled:
                for try await data in input {
                    if isFirst {
                        span.addEvent(SpanEvent(name: "chunking_handler_first_response_passthrough"))
                        isFirst = false
                    }
                    output.yield(data)
                }
            }
        } catch {
            // Finish responseOutput with the error without re-throwing. Re-throwing to the outer
            // task group would cancel the PCC handler before it can synthesize a responseSummary
            // — the PCC handler must stay alive to read the error off chunkedApplicationResponses
            // and write the final responseSummary chunk.
            output.finish(throwing: error)
        }
    }
}
