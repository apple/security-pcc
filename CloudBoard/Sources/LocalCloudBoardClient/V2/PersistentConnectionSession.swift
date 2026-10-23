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

import Foundation
internal import Synchronization
internal import InternalSwiftProtobuf
import os

extension PCCHarness {
    enum SubrequestDataMessage: Sendable {
        case data(Data)
        case cancel
    }

    /// Session for PCC protocol layer subrequests
    public struct PCCSubrequestSession: Sendable {
        public typealias Response = Data
        public let id: UInt64
        public let responseStream: AsyncThrowingStream<Data, Error>

        private let requestContinuation: AsyncStream<SubrequestDataMessage>.Continuation

        internal init(
            id: UInt64,
            responseStream: AsyncThrowingStream<Data, Error>,
            requestContinuation: AsyncStream<SubrequestDataMessage>.Continuation
        ) {
            self.id = id
            self.responseStream = responseStream
            self.requestContinuation = requestContinuation
        }

        public func send(_ data: Data) async throws {
            self.requestContinuation.yield(.data(data))
        }

        public func cancel() async throws {
            self.requestContinuation.yield(.cancel)
            self.requestContinuation.finish()
        }

        public func finish() async throws {
            self.requestContinuation.finish()
        }
    }

    /// Represents a subset of PrivateCloudComputeRequest protocol messages related to subrequests.
    enum SubrequestMessage: Sendable, CustomStringConvertible {
        case subrequestOpen(SubrequestOpen)
        case subrequestPayload(SubrequestPayload)
        case subrequestClose(SubrequestClose)
        case subrequestCancellation(SubrequestCancellation)

        var description: String {
            switch self {
            case .subrequestOpen: "subrequestOpen"
            case .subrequestPayload: "subrequestPayload"
            case .subrequestClose: "subrequestClose"
            case .subrequestCancellation: "subrequestCancellation"
            }
        }

        /// Convert to protobuf OneOf_Type for serialization
        func toProtoType() -> ProtoPrivateCloudComputeRequest.OneOf_Type {
            switch self {
            case .subrequestOpen(let open):
                return .subOpen(.with {
                    $0.subrequestID = open.subrequestID
                    $0.oneTimeToken = Data(randomByteCount: 16)
                    switch open.metadata.priority {
                    case .unspecified:
                        $0.priority = .requestExecutionPriorityUnspecified
                    case .discardable:
                        $0.priority = .requestExecutionPriorityDiscardable
                    }
                })
            case .subrequestPayload(let payload):
                return .payloadChunk(.with {
                    $0.subrequestID = payload.subrequestID
                    $0.chunkData = payload.data
                })
            case .subrequestClose(let close):
                return .subClose(.with {
                    $0.subrequestID = close.subrequestID
                })
            case .subrequestCancellation(let cancellation):
                return .subCancel(.with {
                    $0.subrequestID = cancellation.subrequestID
                })
            }
        }
    }

    enum SubresponseMessage: Sendable, CustomStringConvertible {
        case subresponseOpen(SubresponseOpen)
        case subresponsePayload(SubresponsePayload)
        case subresponseClose(SubresponseClose)

        var description: String {
            switch self {
            case .subresponseOpen: "subresponseOpen"
            case .subresponsePayload: "subresponsePayload"
            case .subresponseClose: "subresponseClose"
            }
        }

        var subrequestID: UInt64 {
            return switch self {
            case .subresponseOpen(let open):
                open.subrequestID
            case .subresponsePayload(let payload):
                payload.subrequestID
            case .subresponseClose(let close):
                close.subrequestID
            }
        }
    }

    /// Protocol for persistent connection sessions
    public final class PersistentConnectionSession: Sendable {
        fileprivate static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.PersistentConnectionSession"
        )

        /// Attestation bundle from the proxy node
        public let attestationBundle: LocalCloudBoardAttestationBundle

        public let nackStreams: [
            ProxyCloudAppEndpoint: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
        ]

        private let requestContinuation: AsyncStream<SubrequestMessage>.Continuation
        private let subrequestIDCounter = Mutex<UInt64>(0)
        private let subresponseContinuations =
            Mutex<[UInt64: AsyncThrowingStream<SubresponseMessage, Error>.Continuation]>([:])

        init(
            attestationBundle: LocalCloudBoardAttestationBundle,
            requestContinuation: AsyncStream<SubrequestMessage>.Continuation,
            nackStreams: [
                // swiftformat:disable trailingCommas
                ProxyCloudAppEndpoint: any AsyncSequence<PrivateCloudComputeProtocolResponse, Error> & Sendable
            ]
        ) {
            self.attestationBundle = attestationBundle
            self.requestContinuation = requestContinuation
            self.nackStreams = nackStreams
        }

        func receiveSubresponseMessage(_ subresponseMessage: SubresponseMessage) {
            let subrequestID = subresponseMessage.subrequestID
            self.subresponseContinuations.withLock {
                if let continuation = $0[subrequestID] {
                    continuation.yield(subresponseMessage)
                    if case .subresponseClose = subresponseMessage {
                        $0.removeValue(forKey: subrequestID)
                        continuation.finish()
                    }
                } else {
                    Self.logger
                        .warning("Received subresponse message with subrequest ID \(subrequestID) for unknown session")
                    return
                }
            }
        }

        public func makeSubrequest<ReturnType>(
            configuration: SubrequestConfiguration,
            _ body: @Sendable @escaping (PCCSubrequestSession) async throws -> ReturnType
        ) async throws -> ReturnType where ReturnType: Sendable {
            let subrequestID = self.subrequestIDCounter.withLock {
                $0 += 1
                return $0
            }

            // Send open message
            let subrequestOpen = SubrequestOpen(subrequestID: subrequestID, metadata: configuration.metadata)
            self.requestContinuation.yield(.subrequestOpen(subrequestOpen))

            // Request and response data streams for the callee
            let (subrequestStream, subrequestContinuation) = AsyncStream<SubrequestDataMessage>.makeStream()
            let (subresponseDataStream, subresponseDataContinuation) = AsyncThrowingStream<Data, Error>.makeStream()

            // Response stream for subresponse messages that need to be de-multiplexed
            let (subresponseStream, subresponseContinuation) = AsyncThrowingStream<SubresponseMessage, Error>
                .makeStream()

            self.subresponseContinuations.withLock {
                $0[subrequestID] = subresponseContinuation
            }
            let subrequestSession = PCCSubrequestSession(
                id: subrequestID,
                responseStream: subresponseDataStream,
                requestContinuation: subrequestContinuation
            )

            return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                group.addTask {
                    try await self.processRequestStream(
                        subrequestID: subrequestID,
                        subrequestStream: subrequestStream,
                        subresponseContinuation: subresponseContinuation
                    )
                }

                group.addTask {
                    try await self.processResponseStream(
                        subrequestID: subrequestID,
                        subresponseStream: subresponseStream,
                        subresponseDataContinuation: subresponseDataContinuation
                    )
                }

                group.addTask {
                    await self.processHandler(body: body, session: subrequestSession)
                }

                while let taskResult = try await group.next() {
                    switch taskResult {
                    case .handlerFinished(let result):
                        Self.logger.debug("makeSubrequest handler finished")
                        group.cancelAll()
                        return result
                    case .handlerError(let error):
                        Self.logger.error("makeSubrequest handler failed: \(error)")
                        group.cancelAll()
                        throw error
                    case .requestStreamFinished:
                        Self.logger.debug("makeSubrequest request stream finished")
                    case .responseStreamFinished:
                        Self.logger.debug("makeSubrequest response stream finished")
                    }
                }

                throw LocalCloudBoardClientError
                    .internalError("Unexpectedly reached end of makeSubrequest without result")
            }
        }

        /// Processes request stream messages and forwards them to the main request continuation
        private func processRequestStream<ReturnType>(
            subrequestID: UInt64,
            subrequestStream: AsyncStream<SubrequestDataMessage>,
            subresponseContinuation: AsyncThrowingStream<SubresponseMessage, Error>.Continuation
        ) async throws -> RequestTaskGroupResult<ReturnType> where ReturnType: Sendable {
            for await message in subrequestStream {
                switch message {
                case .data(let subrequestPayload):
                    let payload = SubrequestPayload(subrequestID: subrequestID, data: subrequestPayload)
                    self.requestContinuation.yield(.subrequestPayload(payload))
                case .cancel:
                    // Send cancellation message and stop processing
                    self.requestContinuation.yield(.subrequestCancellation(.init(subrequestID: subrequestID)))
                    // Finish subresponse stream
                    Self.logger.info(
                        "Received subresponse cancellation for subrequest ID \(subrequestID). Finishing response stream"
                    )
                    subresponseContinuation.finish()
                }
            }
            self.requestContinuation.yield(.subrequestClose(.init(subrequestID: subrequestID)))

            return .requestStreamFinished
        }

        /// Processes response stream messages and yields data to the subresponse data continuation
        private func processResponseStream<ReturnType>(
            subrequestID: UInt64,
            subresponseStream: AsyncThrowingStream<SubresponseMessage, Error>,
            subresponseDataContinuation: AsyncThrowingStream<Data, Error>.Continuation
        ) async throws -> RequestTaskGroupResult<ReturnType> where ReturnType: Sendable {
            do {
                for try await subresponseMessage in subresponseStream {
                    switch subresponseMessage {
                    case .subresponseOpen:
                        Self.logger.info("Received subresponse open for subrequest ID \(subrequestID)")
                    case .subresponsePayload(let payload):
                        subresponseDataContinuation.yield(payload.data)
                        Self.logger.info("Received subresponse payload for subrequest ID \(subrequestID)")
                    case .subresponseClose(let close):
                        Self.logger.info(
                            "Received subresponse close for subrequest ID \(subrequestID) with status \(close.responseStatus)"
                        )
                        // Throw error if subresponse close indicates an error status
                        if close.responseStatus != .ok {
                            throw PCCEnvironmentError.subrequestFailed(status: close.responseStatus)
                        }
                        // We rely on subresponseStream getting closed so don't finish the data stream
                        // continuation here
                    }
                }
                subresponseDataContinuation.finish()
            } catch {
                subresponseDataContinuation.finish(throwing: error)
                throw error
            }

            return .responseStreamFinished
        }

        /// Executes the handler body and wraps the result or error in a task group result
        private func processHandler<ReturnType>(
            body: @Sendable @escaping (PCCSubrequestSession) async throws -> ReturnType,
            session: PCCSubrequestSession
        ) async -> RequestTaskGroupResult<ReturnType> where ReturnType: Sendable {
            do {
                return try await .handlerFinished(body(session))
            } catch {
                return .handlerError(error)
            }
        }
    }
}
