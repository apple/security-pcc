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
internal import InternalGRPC
internal import NIOCore
internal import CloudAttestation
internal import HTTPClientStateMachine
import os
internal import InternalSwiftProtobuf

// Namespaced to PCCHarness
extension PCCHarness {
    enum PCCGatewayError: Error {
        case alreadyStarted
        case unknownEndpoint
        case unexpectedInvokeWorkloadResponseMessage
        case missingDataEncryptionKey
        case invalidEndpointType
    }

    struct InvokeWorkloadRequestContext: Sendable {
        internal let baseContext: RequestContext
        internal let encapsulatedDataEncryptionKey: EncapsulatedDataEncryptionKey

        package var requestID: UUID { self.baseContext.requestID }
        package var workloadMetadata: InvokeWorkloadRequestMetadata { self.baseContext.workloadMetadata }

        init(baseContext: RequestContext, encapsulatedDataEncryptionKey: EncapsulatedDataEncryptionKey) {
            self.baseContext = baseContext
            self.encapsulatedDataEncryptionKey = encapsulatedDataEncryptionKey
        }
    }

    enum InvokeWorkloadConfiguration: Sendable {
        case compute(ComputeRequestConfiguration)
        case proxy(ProxyRequestConfiguration)

        var recordMessagesTo: URL? {
            switch self {
            case .compute(let config):
                return config.recordMessagesTo
            case .proxy(let config):
                return config.recordMessagesTo
            }
        }
    }

    struct FinalizableChunk: Sendable {
        let data: Data
        let isFinal: Bool
    }

    final class RequestSession<RequestMessage, ResponseMessage>: Sendable where RequestMessage: Sendable,
    ResponseMessage: Sendable {
        private let requestContinuation: AsyncStream<RequestMessage>.Continuation
        let responseStream: any AsyncSequence<ResponseMessage, Error> & Sendable

        init(
            requestContinuation: AsyncStream<RequestMessage>.Continuation,
            responseStream: AsyncThrowingStream<ResponseMessage, Error>
        ) {
            self.requestContinuation = requestContinuation
            self.responseStream = responseStream
        }

        func send(_ request: RequestMessage) {
            self.requestContinuation.yield(request)
        }

        func finishSending() {
            self.requestContinuation.finish()
        }
    }

    typealias InvokeWorkloadSession = RequestSession<FinalizableChunk, FinalizableChunk>
    typealias FullInvokeWorkloadSession = RequestSession<ProtoInvokeWorkloadRequest, ProtoInvokeWorkloadResponse>

    final class GatewayInvokeWorkloadSession<Base, RequestMessage, ResponseMessage>: Sendable
    where Base: RequestSession<RequestMessage, ResponseMessage> {
        private let baseSession: Base
        let nackStreams: [ProxyCloudAppEndpoint: AsyncThrowingStream<ResponseMessage, Error>]

        var responseStream: any AsyncSequence<ResponseMessage, Error> & Sendable {
            return self.baseSession.responseStream
        }

        init(
            baseSession: Base,
            nackStreams: [ProxyCloudAppEndpoint: AsyncThrowingStream<ResponseMessage, Error>] = [:]
        ) {
            self.baseSession = baseSession
            self.nackStreams = nackStreams
        }

        func send(_ request: RequestMessage) {
            self.baseSession.send(request)
        }

        func finishSending() {
            self.baseSession.finishSending()
        }
    }

    typealias PCCGatewayInvokeWorkloadSession = GatewayInvokeWorkloadSession<
        InvokeWorkloadSession,
        FinalizableChunk,
        FinalizableChunk
    >

    /// Internal gateway that simulates PCC Gateway behavior
    ///
    /// Responsibilities:
    /// - Maintain gRPC connections to all registered nodes
    /// - Manage watchAttestation streams for each node
    /// - Handle worker selection based on configured strategy
    /// - Support request recording and replay for anti-replay testing
    final class PCCGateway: Sendable {
        fileprivate static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.PCCGateway"
        )

        private enum State: Sendable {
            case initialized
            case running
            case finished
        }

        internal let nodeManager: PCCNodeManager
        private let _config: Mutex<PCCGatewayConfig>

        /// For modifications, use `editConfig(_:)` to ensure atomicity.
        package var config: PCCGatewayConfig {
            self._config.withLock { $0 }
        }

        /// Atomically modifies the gateway configuration.
        /// - Parameter body: Closure that receives an inout reference to the config.
        package func editConfig(_ body: (inout PCCGatewayConfig) throws -> Void) rethrows {
            try self._config.withLock { try body(&$0) }
        }

        private let state: Mutex<State> = .init(.initialized)

        // MARK: - Initialization

        init(
            registeredComputeAppEndpoints: [ComputeCloudAppEndpoint],
            registeredProxyAppEndpoints: [ProxyCloudAppEndpoint],
            config: PCCGatewayConfig
        ) {
            self.nodeManager = PCCNodeManager(
                registeredComputeAppEndpoints: registeredComputeAppEndpoints,
                registeredProxyAppEndpoints: registeredProxyAppEndpoints,
                useTLS: config.useTLS,
                serviceDiscovery: config.serviceDiscovery as? ServiceDiscoveryAbstraction.RegistrationClientProtocol
            )
            self._config = Mutex(config)
            self.state.withLock { $0 = .initialized }
        }

        // MARK: - Lifecycle

        /// Run the gateway. Manages long-lived operations like watchAttestation streams.
        /// This must be called in order to make requests to nodes via the gateway.
        func run() async throws {
            defer {
                self.state.withLock { $0 = .finished }
            }
            try self.state.withLock {
                guard case .initialized = $0 else {
                    throw PCCGatewayError.alreadyStarted
                }
                $0 = .running
            }

            try await self.nodeManager.run()
        }

        // MARK: - Attestation Management

        func attestationSet(for endpoint: any CloudAppEndpoint) async throws -> AttestationSet {
            return try await self.nodeManager.client(for: endpoint).currentAttestationSet
        }

        // MARK: - Request handling

        enum InvokeWorkloadTaskGroupResult<ReturnType>: Sendable where ReturnType: Sendable {
            case handlerFinished(ReturnType)
            case handlerFailed(Error)
            case nackStreamsFinished
        }

        func invokeWorkload<ReturnType: Sendable>(
            for endpoint: any CloudAppEndpoint,
            context: PCCGatewayInvokeWorkloadRequestContext,
            configuration: InvokeWorkloadConfiguration,
            bypassResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation? = nil,
            handler: @Sendable @escaping (PCCGatewayInvokeWorkloadSession) async throws -> ReturnType
        ) async throws -> ReturnType {
            return try await withThrowingTaskGroup(of: InvokeWorkloadTaskGroupResult<ReturnType>.self) { group in
                // Prepare NACK response streams if NACKs have been requested
                let (nackStreams, nackContinuations) = self.prepareNACKStreams(configuration: configuration)

                // Holder for bypass continuation from main request
                let bypassContinuationHolder =
                    Mutex<(any BypassContinuationProtocol<ProtoInvokeWorkloadRequest>)?>(.none)

                // Main request
                group.addTask {
                    do {
                        guard let encapsulatedDEK = context.perEndpointDataEncryptionKeys[endpoint.hostAndPort] else {
                            Self.logger.error("Missing data encryption key for endpoint \(endpoint.hostAndPort)")
                            throw PCCGatewayError.missingDataEncryptionKey
                        }
                        let context = InvokeWorkloadRequestContext(
                            baseContext: context.baseContext,
                            encapsulatedDataEncryptionKey: encapsulatedDEK
                        )
                        return try await InvokeWorkloadExecutor(
                            client: self.nodeManager.client(for: endpoint),
                            nodeManager: self.nodeManager,
                            gatewayConfig: self.config
                        )
                        .invokeWorkload(
                            context: context,
                            configuration: configuration,
                            bypassResponseContinuation: bypassResponseContinuation
                        ) { invokeWorkloadSession, bypassContinuation, _ in
                            // Store bypass continuation so ProxyDialBackOrchestrator can use it
                            bypassContinuationHolder.withLock { $0 = bypassContinuation }

                            // Wrap InvokeWorkloadSession to extend it with NACK streams
                            let pccGatewayRequestSession = PCCGatewayInvokeWorkloadSession(
                                baseSession: invokeWorkloadSession,
                                nackStreams: nackStreams
                            )

                            return try await .handlerFinished(handler(pccGatewayRequestSession))
                        }
                    } catch {
                        return .handlerFailed(error)
                    }
                }

                // NACK requests
                if !nackStreams.isEmpty {
                    group.addTask {
                        try await self.handleNACKRequests(
                            context: context,
                            configuration: configuration,
                            nackContinuations: nackContinuations
                        )
                        return .nackStreamsFinished
                    }
                }

                var resultToReturn: ReturnType?
                while let taskResult = try await group.next() {
                    switch taskResult {
                    case .handlerFinished(let result):
                        Self.logger.log("invokeWorkload handler finished")
                        // Don't return here as we need to wait for nack streams to finish as well
                        resultToReturn = result
                    case .handlerFailed(let error):
                        Self.logger.log("invokeWorkload handler failed: \(error)")
                        group.cancelAll()
                        throw error
                    case .nackStreamsFinished:
                        // Nothing to do
                        Self.logger.info("invokeWorkload NACK stream finished")
                    }
                }

                guard let resultToReturn else {
                    throw LocalCloudBoardClientError
                        .internalError("invokeWorkload task group unexpectedly finished without result")
                }

                return resultToReturn
            }
        }

        private func prepareNACKStreams(configuration: InvokeWorkloadConfiguration) -> (
            [ProxyCloudAppEndpoint: AsyncThrowingStream<FinalizableChunk, Error>],
            [ProxyCloudAppEndpoint: AsyncThrowingStream<FinalizableChunk, Error>.Continuation]
        ) {
            var nackStreams: [ProxyCloudAppEndpoint: AsyncThrowingStream<FinalizableChunk, Error>] = [:]
            var nackContinuations: [ProxyCloudAppEndpoint: AsyncThrowingStream<FinalizableChunk, Error>.Continuation] =
                [:]

            if case .proxy(let proxyConfiguration) = configuration {
                for nackEndpoint in proxyConfiguration.nackEndpoints {
                    let (nackStream, nackContinuation) = AsyncThrowingStream<FinalizableChunk, Error>.makeStream()
                    nackStreams[nackEndpoint] = nackStream
                    nackContinuations[nackEndpoint] = nackContinuation
                }
            }

            return (nackStreams, nackContinuations)
        }

        private func handleNACKRequests(
            context: PCCGatewayInvokeWorkloadRequestContext,
            configuration: InvokeWorkloadConfiguration,
            nackContinuations: [ProxyCloudAppEndpoint: AsyncThrowingStream<FinalizableChunk, Error>.Continuation]
        ) async throws {
            try await withThrowingTaskGroup(of: Void.self) { nackTaskGroup in
                for (nackEndpoint, nackContinuation) in nackContinuations {
                    nackTaskGroup.addTask {
                        guard let encapsulatedDEK =
                            context.perEndpointDataEncryptionKeys[nackEndpoint.hostAndPort] else {
                            Self.logger.error(
                                "Missing data encryption key for endpoint \(nackEndpoint.hostAndPort)"
                            )
                            throw PCCGatewayError.missingDataEncryptionKey
                        }

                        let context = InvokeWorkloadRequestContext(
                            baseContext: context.baseContext,
                            encapsulatedDataEncryptionKey: encapsulatedDEK
                        )

                        // Get NACK recording URL if configured for this endpoint
                        let nackRecordingURL: URL? = if case .proxy(let proxyConfig) = configuration {
                            proxyConfig.recordNACKMessagesTo[nackEndpoint]
                        } else {
                            nil
                        }

                        try await InvokeWorkloadExecutor(
                            client: self.nodeManager.client(for: nackEndpoint),
                            nodeManager: self.nodeManager,
                            gatewayConfig: self.config
                        ).requestNack(
                            context: context,
                            configuration: configuration,
                            recordMessagesTo: nackRecordingURL
                        ) { responseStream in
                            do {
                                for try await nackResponse in responseStream {
                                    nackContinuation.yield(nackResponse)
                                }
                                nackContinuation.finish()
                            } catch {
                                nackContinuation.finish(throwing: error)
                            }
                        }
                    }
                }

                try await nackTaskGroup.waitForAll()
            }
        }

        // MARK: - Replay Support

        /// Replays recorded messages to a node. This only returns once the full response has been received.
        func replayMessages(
            endpoint: any CloudAppEndpoint,
            messages: [ProtoInvokeWorkloadRequest]
        ) async throws -> AsyncThrowingStream<FinalizableChunk, Error> {
            let client = try self.nodeManager.client(for: endpoint)

            // Create response stream
            let (responseStream, responseContinuation) = AsyncThrowingStream<FinalizableChunk, Error>
                .makeStream()

            // Get gRPC stream
            let (grpcRequestContinuation, grpcResponseStream) = client.invokeWorkload()

            do {
                // Send all recorded messages
                for message in messages {
                    grpcRequestContinuation.yield(message)
                }
                grpcRequestContinuation.finish()

                // Process responses (will likely get gRPC error from node rejection)
                for try await grpcResponse in grpcResponseStream {
                    guard let responseType = grpcResponse.type else {
                        continue
                    }

                    switch responseType {
                    case .responseChunk(let chunk):
                        // Forward the encrypted chunk as-is
                        // Typically nodes will reject replay requests with a gRPC error
                        Self.logger
                            .info("Received response chunk of \(chunk.encryptedPayload.count) bytes during replay")
                        responseContinuation.yield(.init(
                            data: chunk.encryptedPayload,
                            isFinal: chunk.isFinal
                        ))
                    case .setupAck:
                        Self.logger.info("Received setupAck during replay")
                    default:
                        Self.logger.info("Received other message type during replay")
                    }
                }

                responseContinuation.finish()
            } catch {
                Self.logger.error("Replay request failed: \(error)")
                responseContinuation.finish(throwing: error)
            }

            return responseStream
        }

        // MARK: - Internal Helpers

        /// Parse attestation bundle data into LocalCloudBoardAttestationBundle
        private func parseAttestationBundle(_ data: Data) throws -> LocalCloudBoardAttestationBundle {
            // Try test-only bundle first
            if let testBundle = try? TestOnlyAttestationBundle(data: data) {
                return LocalCloudBoardAttestationBundle(testOnlyAttestationBundle: testBundle)
            }

            // Parse as real attestation bundle
            let bundle = try AttestationBundle(data: data)
            return try LocalCloudBoardAttestationBundle(unvalidated: bundle, validated: nil)
        }
    }
}
