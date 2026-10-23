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
import Crypto
import Logging
import Metrics
import ObliviousX
import Synchronization
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Sendable wrapper for OHTTPServerStateMachine to safely share across concurrent tasks
final class OHTTPEncryptionContext: Sendable {
    private let stateMachine: Mutex<OHTTPServerStateMachine>

    init() {
        self.stateMachine = Mutex(OHTTPServerStateMachine())
    }

    func receiveKey(
        _ encryptedPayload: Data,
        privateKey: any HPKEKEMPrivateKey
    ) throws -> ([FinalizableChunk<Data>], OHTTPEncapsulation.StreamingResponse, SymmetricKey) {
        try self.stateMachine.withLock {
            try $0.receiveKey(encryptedPayload, privateKey: privateKey)
        }
    }

    func receiveChunk(_ chunk: Data, isFinal: Bool) throws -> Data? {
        try self.stateMachine.withLock {
            try $0.receiveChunk(chunk, isFinal: isFinal)
        }
    }
}

/// Handler responsible for OHTTP encryption and decryption
final class OHTTPEncryptionHandler: Sendable {
    private let logger: Logger
    private let requestID: String
    private let keyID: String
    private let attestedKeyProvider: any AttestedKeyProvider
    private let parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters
    private let requestSecrets: RequestSecrets

    init(
        attestedKeyProvider: any AttestedKeyProvider,
        parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters,
        requestSecrets: RequestSecrets
    ) {
        self.attestedKeyProvider = attestedKeyProvider
        self.parameters = parameters
        self.requestSecrets = requestSecrets
        self.requestID = parameters.requestID
        self.keyID = parameters.decryptionKey.keyID.base64EncodedString()
        self.logger = Logger(label: "cb_jobhelper.OHTTPEncryptionHandler")
    }

    func run(
        span: any Span,
        requestInput: AsyncStream<FinalizableChunk<Data>>,
        requestOutput: AsyncStream<FinalizableChunk<Data>>.Continuation,
        responseInput: AsyncStream<FinalizableChunk<Data>>,
        responseOutput: AsyncStream<FinalizableChunk<Data>>.Continuation
    ) async throws {
        logger.info("OHTTP handler starting", metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"])
        defer {
            self.logger.info(
                "OHTTP handler completed",
                metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
            )
        }

        logger.info(
            "Requesting decryption key from key provider",
            metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
        )
        let requestEncryptionKey = try await self.attestedKeyProvider.key(for: parameters.decryptionKey.keyID)
        logger.info(
            "Decryption key obtained from key provider",
            metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
        )

        let cryptoContext = OHTTPEncryptionContext()
        let clock = ContinuousClock()
        let decapStart = clock.now
        let (bufferedChunks, responseEncapsulator, dataEncryptionKey) = try cryptoContext.receiveKey(
            parameters.decryptionKey.encryptedPayload,
            privateKey: requestEncryptionKey
        )
        self.requestSecrets.provide(dataEncryptionKey: dataEncryptionKey)
        let decapDuration = clock.now - decapStart
        Timer(
            label: "cb_jobhelper_ohttp_decapsulation_seconds",
            preferredDisplayUnit: .seconds
        ).record(duration: decapDuration)

        span.addEvent(
            SpanEvent(
                name: "ohttp_key_decapsulation_complete",
                attributes: [
                    "keyID": "\(self.keyID)",
                    "durationMs": "\(decapDuration.inMilliseconds)",
                ]
            )
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Decrypt request chunks
            group.addTask {
                var chunksDecrypted = 0
                var encryptedBytesReceived = 0
                var isFirstChunk = true
                // Process buffered chunks first
                for bufferedChunk in bufferedChunks {
                    self.logger.debug(
                        "Processing buffered decrypted chunk",
                        metadata: [
                            "requestID": "\(self.requestID)",
                            "keyID": "\(self.keyID)",
                            "chunkSize": "\(bufferedChunk.chunk.count)",
                        ]
                    )
                    chunksDecrypted += 1
                    if isFirstChunk {
                        self.logger.info(
                            "OHTTP handler received first request chunk",
                            metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
                        )
                        span.addEvent(SpanEvent(name: "ohttp_first_request_chunk_decrypted"))
                        isFirstChunk = false
                    }
                    requestOutput.yield(bufferedChunk)
                }

                // Process incoming encrypted chunks
                for await encryptedChunk in requestInput {
                    self.logger.debug(
                        "Decrypting chunk",
                        metadata: [
                            "requestID": "\(self.requestID)",
                            "keyID": "\(self.keyID)",
                            "chunkSize": "\(encryptedChunk.chunk.count)",
                            "isFinal": "\(encryptedChunk.isFinal)",
                        ]
                    )

                    encryptedBytesReceived += encryptedChunk.chunk.count

                    if let decryptedChunk = try cryptoContext.receiveChunk(
                        encryptedChunk.chunk,
                        isFinal: encryptedChunk.isFinal
                    ) {
                        chunksDecrypted += 1
                        requestOutput.yield(FinalizableChunk(chunk: decryptedChunk, isFinal: encryptedChunk.isFinal))
                        if isFirstChunk {
                            self.logger.info(
                                "OHTTP handler received first request chunk",
                                metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
                            )
                            span.addEvent(SpanEvent(name: "ohttp_first_request_chunk_decrypted"))
                            isFirstChunk = false
                        }
                        if encryptedChunk.isFinal {
                            span.addEvent(
                                SpanEvent(
                                    name: "ohttp_final_request_chunk_decrypted",
                                    attributes: [
                                        "chunksDecrypted": "\(chunksDecrypted)",
                                        "encryptedBytesReceived": "\(encryptedBytesReceived)",
                                    ]
                                )
                            )
                        }
                    }
                }

                self.logger.info(
                    "Request decryption complete",
                    metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
                )
                span.addEvent(
                    SpanEvent(
                        name: "ohttp_request_decryption_complete",
                        attributes: [
                            "chunksDecrypted": "\(chunksDecrypted)",
                            "encryptedBytesReceived": "\(encryptedBytesReceived)",
                        ]
                    )
                )
                requestOutput.finish()
            }

            // Encrypt response chunks
            group.addTask {
                var encapsulator = responseEncapsulator
                var chunksEncrypted = 0
                var encryptedBytesSent = 0
                var isFirstChunk = true
                for await responseChunk in responseInput {
                    let encrypted = try encapsulator.encapsulate(responseChunk.chunk, final: responseChunk.isFinal)
                    chunksEncrypted += 1
                    encryptedBytesSent += encrypted.count
                    responseOutput.yield(FinalizableChunk(chunk: encrypted, isFinal: responseChunk.isFinal))

                    if isFirstChunk {
                        span.addEvent(SpanEvent(name: "ohttp_first_response_chunk_encrypted"))
                        isFirstChunk = false
                    }
                    if responseChunk.isFinal {
                        span.addEvent(
                            SpanEvent(
                                name: "ohttp_final_response_chunk_encrypted",
                                attributes: [
                                    "chunksEncrypted": "\(chunksEncrypted)",
                                    "encryptedBytesSent": "\(encryptedBytesSent)",
                                ]
                            )
                        )
                    }

                    self.logger.debug(
                        "Encrypted response",
                        metadata: [
                            "requestID": "\(self.requestID)",
                            "keyID": "\(self.keyID)",
                            "chunkSize": "\(encrypted.count)",
                            "isFinal": "\(responseChunk.isFinal)",
                        ]
                    )
                }

                self.logger.info(
                    "Response encryption complete",
                    metadata: ["requestID": "\(self.requestID)", "keyID": "\(self.keyID)"]
                )
                span.addEvent(
                    SpanEvent(
                        name: "ohttp_response_encryption_complete",
                        attributes: [
                            "chunksEncrypted": "\(chunksEncrypted)",
                            "encryptedBytesSent": "\(encryptedBytesSent)",
                        ]
                    )
                )
                responseOutput.finish()
            }

            // next() rather than waitForAll() so we throw out of the task group and cancel all siblings
            while let _ = try await group.next() {}
        }
    }
}
