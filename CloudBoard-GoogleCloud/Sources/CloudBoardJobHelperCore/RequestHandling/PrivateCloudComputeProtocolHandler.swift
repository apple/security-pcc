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
import LengthPrefixChunking
import Logging
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

package enum PrivateCloudComputeProtocolError: Error, ReportableError, PCCResponseStatusTransformable {
    case receivedProxyOnlyMessageType(String)
    case receivedMessageWithNoType
    case receivedChunkAfterFinal
    case receivedApplicationPayloadBeforeOpen
    case receivedDuplicateOpen
    case receivedApplicationPayloadAfterFinalMessage
    case streamEndedWithoutFinalChunk
    case receivedFinalMessageBeforeOpen
    case receivedFinalMessageOutOfOrder

    package var publicDescription: String {
        switch self {
        case .receivedProxyOnlyMessageType(let type): return "receivedProxyOnlyMessageType(\(type))"
        case .receivedMessageWithNoType: return "receivedMessageWithNoType"
        case .receivedChunkAfterFinal: return "receivedChunkAfterFinal"
        case .receivedApplicationPayloadBeforeOpen: return "receivedApplicationPayloadBeforeOpen"
        case .receivedDuplicateOpen: return "receivedDuplicateOpen"
        case .receivedApplicationPayloadAfterFinalMessage: return "receivedApplicationPayloadAfterFinalMessage"
        case .streamEndedWithoutFinalChunk: return "streamEndedWithoutFinalChunk"
        case .receivedFinalMessageBeforeOpen: return "receivedFinalMessageBeforeOpen"
        case .receivedFinalMessageOutOfOrder: return "receivedFinalMessageOutOfOrder"
        }
    }

    package var pccResponseStatus: PCCResponseStatus { .invalidRequest(self.publicDescription) }
}

/// Client-side capabilities extracted from the PCC .open message
package struct PCCCapabilities: Sendable {
    package let applicationDataChunking: ApplicationDataChunking

    package init(applicationDataChunking: ApplicationDataChunking) {
        self.applicationDataChunking = applicationDataChunking
    }

    package init(from proto: Proto_PrivateCloudCompute_Capabilities) {
        let size = proto.applicationDataChunking.size
        if size > 0 {
            self.applicationDataChunking = .enabled(ApplicationDataChunkingConfiguration(chunkSize: Int(size)))
        } else {
            self.applicationDataChunking = .disabled
        }
    }
}

package enum ApplicationDataChunking: Sendable, CustomStringConvertible {
    case disabled
    case enabled(ApplicationDataChunkingConfiguration)

    package var description: String {
        switch self {
        case .disabled:
            return "disabled"
        case .enabled(let config):
            return "enabled(chunkSize: \(config.chunkSize))"
        }
    }
}

package struct ApplicationDataChunkingConfiguration: Sendable {
    package var chunkSize: Int

    package init(chunkSize: Int) {
        self.chunkSize = chunkSize
    }
}

/// Handler responsible for PCC protocol message encoding/decoding
final class PrivateCloudComputeProtocolHandler: Sendable {
    private let logger: Logger
    private let requestID: String
    private let keyID: String
    private let maxPCCProtocolMessageSize: Int
    private let stateMachine: PCCProtocolHandlerStateMachine
    private let opaqueCryptoMaterialBox: AsyncValueBox<[OpaqueCryptoMaterial]>
    private let stats: JobHelperRequestStatistics

    init(
        configReader: ConfigReader,
        parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters,
        stats: JobHelperRequestStatistics
    ) {
        self.maxPCCProtocolMessageSize = configReader.int(
            forKey: "pccprotocol.maxsize",
            default: 10 * 1024 * 1024
        )
        self.stateMachine = PCCProtocolHandlerStateMachine()
        self.opaqueCryptoMaterialBox = AsyncValueBox()
        self.requestID = parameters.requestID
        self.keyID = parameters.decryptionKey.keyID.base64EncodedString()
        self.logger = Logger(label: "cb_jobhelper.PrivateCloudComputeProtocolHandler")
        self.stats = stats
    }

    /// Waits until the PCC .open message has been received and parsed. Throws on task cancellation.
    func getCapabilities() async throws -> PCCCapabilities {
        try await self.stateMachine.getCapabilities()
    }

    /// Marks the request as aborted by a client terminate so that a subsequent end of the request stream completes
    /// cleanly instead of failing with `streamEndedWithoutFinalChunk`. Must be called before the request input stream
    /// is finished.
    func terminate() {
        self.stateMachine.receiveTerminate()
    }

    /// Returns the opaque crypto material extracted from the PCC open message. Only the
    /// `proxyInvokeOpen` (process-per-request) message carries material; the legacy `.open`
    /// message resolves to an empty array. This will wait until the open message has been
    /// received and parsed.
    func getOpaqueCryptoMaterial() async throws -> [OpaqueCryptoMaterial] {
        try await self.opaqueCryptoMaterialBox.get()
    }

    func run(
        span: any Span,
        requestInput: AsyncStream<FinalizableChunk<Data>>,
        requestOutput: AsyncStream<Data>.Continuation,
        responseInput: AsyncThrowingStream<Data, any Error>,
        responseOutput: AsyncStream<FinalizableChunk<Data>>.Continuation
    ) async throws {
        logger.info(
            "PCC Protocol handler starting",
            metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
        )
        defer {
            self.logger.info(
                "PCC Protocol handler completed",
                metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
            )
        }

        // withResponseSummary wraps the entire task group so that errors thrown by either
        // parseRequest or encodeResponse are caught and turned into a PCC responseSummary.
        try await withResponseSummary(responseOutput: responseOutput, span: span) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.parseRequest(
                        span: span,
                        requestInput: requestInput,
                        requestOutput: requestOutput
                    )
                }
                group.addTask {
                    try await self.encodeResponse(
                        span: span,
                        responseInput: responseInput,
                        responseOutput: responseOutput
                    )
                }
                // Error propagation: if parseRequest throws (protocol/parse error), waitForAll
                // re-throws it, body() throws, and withResponseSummary maps it to a
                // PCCResponseStatus for the responseSummary. encodeResponse is cancelled but
                // its CancellationError is discarded by waitForAll in favour of the real error.
                try await group.waitForAll()
            }
        }
    }

    private func parseRequest(
        span: any Span,
        requestInput: AsyncStream<FinalizableChunk<Data>>,
        requestOutput: AsyncStream<Data>.Continuation
    ) async throws {
        // Buffer and re-assemble length-prefixed messages
        var pccProtocolMessageBuffer = LengthPrefixAssembler(maxMessageSize: self.maxPCCProtocolMessageSize)
        do {
            for await decryptedChunk in requestInput {
                try self.stateMachine.receiveRequestChunk()

                self.logger.debug(
                    "Parsing PCC request chunk",
                    metadata: [
                        "requestID": "\(self.requestID)",
                        "keyID": "\(self.keyID)",
                        "chunkSize": "\(decryptedChunk.chunk.count)",
                        "isFinal": "\(decryptedChunk.isFinal)",
                    ]
                )

                let messages = try pccProtocolMessageBuffer.append(decryptedChunk.chunk)
                for message in messages {
                    let pccRequest = try Proto_PrivateCloudCompute_PrivateCloudComputeRequest(
                        serializedBytes: message
                    )
                    try self.handlePCCMessage(
                        pccRequest,
                        requestOutput: requestOutput,
                        span: span
                    )
                }

                if decryptedChunk.isFinal {
                    try pccProtocolMessageBuffer.finish()
                    self.stateMachine.receiveFinalRequestChunk()
                }
            }

            self.logger.info(
                "Request parsing complete",
                metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
            )
            span.addEvent(SpanEvent(name: "pcc_request_parsing_complete"))
            try self.stateMachine.completeSuccessfully()
            requestOutput.finish()
        } catch {
            self.logger.error(
                "Request parsing failed",
                metadata: [
                    "requestID": "\(self.requestID)",
                    "keyID": "\(self.keyID)",
                    "error": "\(String(reportable: error))",
                ]
            )
            requestOutput.finish()
            self.stateMachine.fail(with: error)
            throw error
        }
    }

    private func handlePCCMessage(
        _ pccRequest: Proto_PrivateCloudCompute_PrivateCloudComputeRequest,
        requestOutput: AsyncStream<Data>.Continuation,
        span: any Span
    ) throws {
        switch pccRequest.type {
        case .open(let openPayload):
            try self.handleOpenMessage(openPayload.capabilities, opaqueCryptoMaterial: [], name: "open")

        case .proxyInvokeOpen(let openPayload):
            let material = openPayload.opaqueCryptoMaterial.map {
                OpaqueCryptoMaterial(id: $0.id, material: $0.material)
            }
            self.logger.info(
                "Received opaque crypto material",
                metadata: ["keyID": "\(self.keyID)", "count": "\(material.count)"]
            )
            try self.handleOpenMessage(
                openPayload.capabilities,
                opaqueCryptoMaterial: material,
                name: "proxyInvokeOpen"
            )

        case .applicationPayload(let payload):
            let payloadIndex = try self.stateMachine.receiveApplicationPayload()
            // With application layer chunking and large payloads, we cannot log an event for each possible
            if payloadIndex == 1 {
                self.logger.info(
                    "Received first PrivateCloudCompute.applicationPayload",
                    metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
                )
                span.addEvent(SpanEvent(name: "pcc_first_application_payload"))
            }
            requestOutput.yield(payload)

        case .finalMessage:
            try self.stateMachine.receiveFinalMessage()
            self.logger.info(
                "Received PrivateCloudCompute.finalMessage",
                metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
            )

        case .subOpen, .payloadChunk, .subClose, .subCancel:
            throw PrivateCloudComputeProtocolError.receivedProxyOnlyMessageType(pccRequest.type.caseName)

        case .none:
            throw PrivateCloudComputeProtocolError.receivedMessageWithNoType
        }
    }

    private func encodeResponse(
        span: any Span,
        responseInput: AsyncThrowingStream<Data, any Error>,
        responseOutput: AsyncStream<FinalizableChunk<Data>>.Continuation
    ) async throws {
        var isFirstResponse = true
        for try await applicationResponse in responseInput {
            self.logger.debug(
                "Encoding PCC response",
                metadata: [
                    "requestID": "\(self.requestID)",
                    "keyID": "\(self.keyID)",
                    "chunkSize": "\(applicationResponse.count)",
                ]
            )
            if isFirstResponse {
                span.addEvent(SpanEvent(name: "pcc_first_response_payload"))
                isFirstResponse = false
            }
            let pccResponse = Proto_PrivateCloudCompute_PrivateCloudComputeResponse.with {
                $0.responsePayload = applicationResponse
            }
            var serializedPCCResponse = try pccResponse.serializedData()
            serializedPCCResponse.prependLength()
            responseOutput.yield(FinalizableChunk(chunk: serializedPCCResponse, isFinal: false))
        }
    }

    private func withResponseSummary(
        responseOutput: AsyncStream<FinalizableChunk<Data>>.Continuation,
        span: any Span,
        _ body: () async throws -> Void
    ) async throws {
        defer { responseOutput.finish() }
        let finalStatus: PCCResponseStatus
        do {
            try await body()
            finalStatus = .ok
        } catch let error as CancellationError {
            throw error
        } catch {
            let reportable = String(reportable: error)
            self.logger.error(
                "Reporting error at PCC protocol layer",
                metadata: [
                    "requestID": "\(self.requestID)",
                    "keyID": "\(self.keyID)",
                    "error": "\(reportable)",
                ]
            )
            self.stats.recordPCCProtocolError(error)
            span.setStatus(.init(code: .error, message: reportable))
            finalStatus = PCCResponseStatus(error)
        }
        self.stats.recordPCCProtocolResponseStatus(finalStatus)

        self.logger.info(
            "Sending PrivateCloudCompute.responseSummary",
            metadata: [
                "requestID": "\(self.requestID)",
                "keyID": "\(self.keyID)",
                "status": "\(finalStatus)",
            ]
        )
        span.addEvent(SpanEvent(name: "pcc_response_summary", attributes: ["status": "\(finalStatus)"]))
        do {
            var data = try Proto_PrivateCloudCompute_PrivateCloudComputeResponse(status: finalStatus)
                .serializedData()
            data.prependLength()
            responseOutput.yield(FinalizableChunk(chunk: data, isFinal: true))
        } catch {
            self.logger.error(
                "Failed to serialize responseSummary",
                metadata: [
                    "requestID": "\(self.requestID)",
                    "keyID": "\(self.keyID)",
                    "error": "\(String(reportable: error))",
                ]
            )
            throw error
        }

        self.logger.info(
            "Response encoding complete",
            metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
        )
        span.addEvent(SpanEvent(name: "pcc_response_encoding_complete"))
    }

    private func handleOpenMessage(
        _ protoCapabilities: Proto_PrivateCloudCompute_Capabilities,
        opaqueCryptoMaterial: [OpaqueCryptoMaterial],
        name: String
    ) throws {
        self.logger.info(
            "Received PrivateCloudCompute open message",
            metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)", "messageType": "\(name)"]
        )
        let capabilities = PCCCapabilities(from: protoCapabilities)
        self.logger.info(
            "Client capabilities",
            metadata: [
                "requestID": "\(self.requestID)",
                "keyID": "\(self.keyID)",
                "applicationDataChunking": "\(capabilities.applicationDataChunking)",
            ]
        )
        try self.stateMachine.receiveOpen(capabilities: capabilities)
        self.opaqueCryptoMaterialBox.put(opaqueCryptoMaterial)
    }
}

extension Proto_PrivateCloudCompute_PrivateCloudComputeResponse {
    fileprivate init(status: PCCResponseStatus) {
        self = .with {
            $0.responseSummary = .with {
                $0.responseStatus = status.protoResponseStatus
                if let desc = status.errorDescription {
                    $0.errorDescription = desc
                }
            }
        }
    }
}

extension PCCResponseStatus {
    fileprivate var protoResponseStatus: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.ResponseStatus {
        switch self {
        case .ok: return .ok
        case .unauthenticated: return .unauthenticated
        case .invalidRequest: return .invalidRequest
        case .internalError(_): return .internalError
        case .proxyFindWorkerError: return .proxyFindWorkerError
        case .proxyWorkerValidationError: return .proxyWorkerValidationError
        }
    }
}

extension Proto_PrivateCloudCompute_PrivateCloudComputeRequest.OneOf_Type? {
    /// The case label without the associated proto message
    var caseName: String {
        // Interpolating the value directly (`"\(oneOf)"`) reflects the full text-format dump of the associated message
        // which is unsafe to log
        guard let self else { return "nil" }
        switch self {
        case .applicationPayload: return "applicationPayload"
        case .open: return "open"
        case .finalMessage: return "finalMessage"
        case .payloadChunk: return "payloadChunk"
        case .subOpen: return "subOpen"
        case .subClose: return "subClose"
        case .proxyInvokeOpen: return "proxyInvokeOpen"
        case .subCancel: return "subCancel"
        }
    }
}
