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

internal import CloudAttestation
@_spi(HPKEAlgID) import CryptoKit
import Foundation
internal import HTTPClientStateMachine
import os
internal import Synchronization
internal import InternalSwiftProtobuf

extension PCCHarness {
    public enum PCCEnvironmentError: Error {
        /// Crypto context, required to encrypt request and decrypt response messages, associated with the request could
        /// not be found
        case cryptoContextNotFound
        /// Failed to decode a Private Cloud Compute protocol response message
        case failedToDecodePrivateCloudComputeMessage
        /// The parameters override file provided for request replay is invalid
        case invalidParametersOverrideFile
        /// A subrequest has failed with the provided status
        case subrequestFailed(status: SubresponseClose.Status)
    }

    struct EnvironmentConfiguration {
        let attestationEnvironment: CloudAttestation.Environment
    }

    /// Active environment for making requests to CloudBoard nodes
    public final class Environment: Sendable {
        static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.Environment"
        )

        let gateway: PCCGateway
        let config: EnvironmentConfiguration
        let attestationValidator: AttestationBundleValidator

        init(
            gateway: PCCGateway,
            config: EnvironmentConfiguration,
            attestationValidator: AttestationBundleValidator
        ) {
            self.gateway = gateway
            self.config = config
            self.attestationValidator = attestationValidator
        }

        // MARK: - Client Factory Methods

        /// Create an application-layer client for making requests with decrypted Data streams
        /// - Returns: A client that can be used to make requests to proxy or compute endpoints
        public func makeApplicationClient() -> ApplicationClient {
            return ApplicationClient(environment: self)
        }

        /// Create a VRE-layer client for making requests with application Data input and PCC protocol responses
        /// - Returns: A client that can be used to make requests to proxy or compute endpoints
        public func makeVREClient() -> VREClient {
            return VREClient(environment: self)
        }

        /// Returns the most recent attestation bundle for the provided endpoint
        public func currentAttestationBundle(for endpoint: any CloudAppEndpoint) async throws
        -> LocalCloudBoardAttestationBundle {
            let rawBundle = try await self.gateway.attestationSet(for: endpoint).activeAttestation.attestationBundle
            let (_, attestation) = try await self.attestationValidator.parseAndValidate(rawBundle)
            return attestation
        }

        // MARK: - Proxy Requests

        /// Make an application-layer request to the provided proxy app endpoint.
        /// - Parameters:
        ///   - endpoint: Endpoint of the proxy app to send the request to
        ///   - context: Request context, including the request ID and associated metadata
        ///   - configuration: Request configuration to control client and PCC Gateway behaviour, e.g. for whether to
        ///   use request bypass
        ///   - handler: Request body provided with a session object exposing request and response streams for the
        ///   request, once connected to the endpoint.
        /// - Returns: Return value of the handler. Throws if the handler throws or if the request failed for other
        /// reasons.
        internal func makeProxyRequest<ReturnType: Sendable>(
            to endpoint: ProxyCloudAppEndpoint,
            context: RequestContext = .init(),
            configuration: ProxyRequestConfiguration = .init(),
            _ handler: @Sendable @escaping (ApplicationLayerProxyRequestSession) async throws -> ReturnType
        ) async throws -> ReturnType {
            return try await self.makeProxyRequestWithPCCProtocolResponse(
                to: endpoint,
                context: context,
                configuration: configuration
            ) { pccRequestSession in
                // Create application layer session with transformed streams
                let appRequestSession = ApplicationLayerProxyRequestSession(
                    attestationBundle: pccRequestSession.attestationBundle,
                    requestContinuation: pccRequestSession.requestContinuation,
                    responseStream: ApplicationLayerResponseSequence(base: pccRequestSession.responseStream),
                    bypassResponseStream: ApplicationLayerResponseSequence(base: pccRequestSession.bypassResponseStream)
                )
                return try await handler(appRequestSession)
            }
        }

        /// Make an application-layer request to the provided proxy app endpoint, with a Private Cloud Compute protocol
        /// layer response stream. This is useful if specific PCC protocol response messages, e.g. Request Execution Log
        /// entries, need to be observed.
        /// - Parameters:
        ///   - endpoint: Endpoint of the proxy app to send the request to
        ///   - context: Request context, including the request ID and associated metadata
        ///   - configuration: Request configuration to control client and PCC Gateway behaviour, e.g. for whether to
        ///   use request bypass
        ///   - handler: Request body provided with a session object exposing request and response streams for the
        ///   request, once connected to the endpoint.
        /// - Returns: Return value of the handler. Throws if the handler throws or if the request failed for other
        /// reasons.
        internal func makeProxyRequestWithPCCProtocolResponse<ReturnType: Sendable>(
            to endpoint: ProxyCloudAppEndpoint,
            context: RequestContext = .init(),
            configuration: ProxyRequestConfiguration = .init(),
            _ handler: @Sendable @escaping (PCCProtocolProxyResponseSession) async throws -> ReturnType
        ) async throws -> ReturnType {
            // Obtain and validate attestations for request-handling endpoint and nack endpoints if specified
            let (cryptoContexts, validatedAttestationBundles, perEndpointDataEncryptionKeys) = try await self
                .prepareCryptoContexts(for: [endpoint] + configuration.nackEndpoints)

            let invokeWorkloadRequestContext = PCCGatewayInvokeWorkloadRequestContext(
                baseContext: context,
                perEndpointDataEncryptionKeys: perEndpointDataEncryptionKeys
            )

            // Create bypass response streams
            let (bypassResponseStream, bypassResponseContinuation) = AsyncThrowingStream<
                Proto_Ropes_Common_Chunk,
                Error
            >
                .makeStream()
            let (bypassDecapStream, bypassDecapContinuation) = AsyncStream<Proto_PrivateCloudCompute_ResponseContext>
                .makeStream()

            // Invoke workload via PCC Gateway
            return try await self.gateway.invokeWorkload(
                for: endpoint,
                context: invokeWorkloadRequestContext,
                configuration: .proxy(configuration),
                bypassResponseContinuation: bypassResponseContinuation
            ) { requestSession in
                let nackResponseStreams = self.mapToDecryptedPCCResponseStreams(
                    requestSession.nackStreams,
                    cryptoContexts: cryptoContexts,
                    validatedAttestationBundles: validatedAttestationBundles
                )

                // Create request session
                let (requestStream, requestContinuation) = AsyncStream<Data>.makeStream()
                let (responseStream, responseContinuation) = AsyncThrowingStream<
                    PrivateCloudComputeProtocolResponse,
                    Error
                >
                    .makeStream()
                let (bypassPCCResponseStream, bypassPCCResponseContinuation) = AsyncThrowingStream<
                    PrivateCloudComputeProtocolResponse,
                    Error
                >
                    .makeStream()
                guard let cryptoContext = cryptoContexts[endpoint.hostAndPort],
                      let validatedAttestationBundle = validatedAttestationBundles[endpoint.hostAndPort] else {
                    throw LocalCloudBoardClientError.internalError(
                        "Crypto context and attestation bundle must exist for endpoint \(endpoint.hostAndPort)"
                    )
                }

                let pccRequestSession = PCCProtocolProxyResponseSession(
                    attestationBundle: validatedAttestationBundle,
                    requestContinuation: requestContinuation,
                    responseStream: responseStream,
                    bypassResponseStream: bypassPCCResponseStream,
                    nackStreams: nackResponseStreams
                )

                return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                    // Wrap application layer protocol request messages in PCC protocol and encrypt
                    group.addTask {
                        try self.sendAuthToken(
                            to: requestSession,
                            cryptoContext: cryptoContext,
                            applicationDataChunkingConfiguration: configuration.applicationDataChunkingConfiguration
                        )
                        for await applicationRequestChunk in requestStream {
                            try self.sendApplicationPayload(
                                applicationRequestChunk,
                                to: requestSession,
                                cryptoContext: cryptoContext
                            )
                        }
                        try self.sendFinalMessage(to: requestSession, cryptoContext: cryptoContext)
                        requestSession.finishSending()

                        return .requestStreamFinished
                    }

                    // Decrypt and forward PCC protocol response messages
                    group.addTask {
                        return try await withThrowingTaskGroup(of: Void.self) { responseGroup in
                            // Handle primary response stream
                            responseGroup.addTask {
                                try await self.decryptResponseStream(
                                    from: requestSession,
                                    to: responseContinuation,
                                    cryptoContext: cryptoContext,
                                    validatedAttestationBundle: validatedAttestationBundle,
                                    endpoint: endpoint,
                                    bypassDecapContinuation: bypassDecapContinuation
                                )
                            }

                            // Handle bypass response decapsulation if needed
                            responseGroup.addTask {
                                try await self.decryptBypassResponseStream(
                                    bypassResponseStream: bypassResponseStream,
                                    bypassDecapStream: bypassDecapStream,
                                    bypassPCCResponseContinuation: bypassPCCResponseContinuation
                                )
                            }

                            try await responseGroup.waitForAll()
                            return .responseStreamFinished
                        }
                    }

                    group.addTask {
                        return try await .handlerFinished(handler(pccRequestSession))
                    }

                    while let taskResult = try await group.next() {
                        switch taskResult {
                        case .handlerFinished(let result):
                            Self.logger.debug("makeProxyRequest handler finished")
                            group.cancelAll()
                            return result
                        case .handlerError(let error):
                            Self.logger.error("makeProxyRequest handler failed: \(error)")
                            group.cancelAll()
                            throw error
                        case .requestStreamFinished:
                            Self.logger.debug("makeProxyRequest request stream finished")
                        case .responseStreamFinished:
                            Self.logger.debug("makeProxyRequest response stream finished")
                        }
                    }

                    throw LocalCloudBoardClientError
                        .internalError("Unexpectedly reached end of makeProxyRequest without result")
                }
            }
        }

        // MARK: - Compute Requests

        /// Make an application-layer request to the provided compute app endpoint.
        /// - Parameters:
        ///   - endpoint: Endpoint of the compute app to send the request to
        ///   - context: Request context, including the request ID and associated metadata
        ///   - configuration: Request configuration to control client and PCC Gateway behaviour
        ///   - handler: Request body provided with a session object exposing request and response streams for the
        ///   request, once connected to the endpoint.
        /// - Returns: Return value of the handler. Throws if the handler throws or if the request failed for other
        /// reasons.
        internal func makeComputeRequest<ReturnType: Sendable>(
            to endpoint: ComputeCloudAppEndpoint,
            context: RequestContext = .init(),
            configuration: ComputeRequestConfiguration = .init(),
            handler: @Sendable @escaping (ApplicationLayerRequestSession) async throws -> ReturnType
        ) async throws -> ReturnType {
            return try await self.makeComputeRequestWithPCCProtocolResponse(
                to: endpoint,
                context: context,
                configuration: configuration
            ) { pccRequestSession in
                // Create request session
                let appRequestSession = ApplicationLayerRequestSession(
                    attestationBundle: pccRequestSession.attestationBundle,
                    requestContinuation: pccRequestSession.requestContinuation,
                    responseStream: ApplicationLayerResponseSequence(base: pccRequestSession.responseStream)
                )
                return try await handler(appRequestSession)
            }
        }

        /// Make an application-layer request to the provided compute app endpoint, with a Private Cloud Compute
        /// protocol layer response stream. This is useful if specific PCC protocol response messages, e.g. the response
        /// summary, need to be observed.
        /// - Parameters:
        ///   - endpoint: Endpoint of the compute app to send the request to
        ///   - context: Request context, including the request ID and associated metadata
        ///   - configuration: Request configuration to control client and PCC Gateway behaviour, e.g. for whether to
        ///   use request bypass
        ///   - handler: Request body provided with a session object exposing request and response streams for the
        ///   request, once connected to the endpoint.
        /// - Returns: Return value of the handler. Throws if the handler throws or if the request failed for other
        /// reasons.
        internal func makeComputeRequestWithPCCProtocolResponse<ReturnType: Sendable>(
            to endpoint: ComputeCloudAppEndpoint,
            context: RequestContext = .init(),
            configuration: ComputeRequestConfiguration = .init(),
            handler: @Sendable @escaping (PCCProtocolResponseSession) async throws -> ReturnType
        ) async throws -> ReturnType {
            let (cryptoContext, validatedAttestationBundle, encapsulatedDEK) = try await self.prepareCryptoContext(
                for: endpoint,
                forcedDataEncryptionKey: configuration.forcedDataEncryptionKey
            )

            let invokeWorkloadRequestContext = PCCGatewayInvokeWorkloadRequestContext(
                baseContext: context,
                perEndpointDataEncryptionKeys: [endpoint.hostAndPort: encapsulatedDEK]
            )

            // Create request session
            let (requestStream, requestContinuation) = AsyncStream<Data>.makeStream()
            let (responseStream, responseContinuation) = AsyncThrowingStream<PrivateCloudComputeProtocolResponse, Error>
                .makeStream()
            let pccRequestSession = PCCProtocolResponseSession(
                attestationBundle: validatedAttestationBundle,
                requestContinuation: requestContinuation,
                responseStream: responseStream
            )

            // Invoke workload via PCC Gateway
            return try await self.gateway.invokeWorkload(
                for: endpoint,
                context: invokeWorkloadRequestContext,
                configuration: .compute(configuration)
            ) { requestSession in
                return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                    // Wrap application layer protocol request messages in PCC protocol and encrypt
                    group.addTask {
                        try self.sendAuthToken(
                            to: requestSession,
                            cryptoContext: cryptoContext,
                            applicationDataChunkingConfiguration: configuration.applicationDataChunkingConfiguration
                        )
                        for await applicationRequestChunk in requestStream {
                            try self.sendApplicationPayload(
                                applicationRequestChunk,
                                to: requestSession,
                                cryptoContext: cryptoContext
                            )
                        }
                        try self.sendFinalMessage(to: requestSession, cryptoContext: cryptoContext)
                        requestSession.finishSending()
                        return .requestStreamFinished
                    }

                    // Decrypt and forward PCC protocol response messages
                    group.addTask {
                        try await self.decryptResponseStream(
                            from: requestSession,
                            to: responseContinuation,
                            cryptoContext: cryptoContext,
                            validatedAttestationBundle: validatedAttestationBundle,
                            endpoint: endpoint
                        )
                        return .responseStreamFinished
                    }

                    group.addTask {
                        return try await .handlerFinished(handler(pccRequestSession))
                    }

                    while let taskResult = try await group.next() {
                        switch taskResult {
                        case .handlerFinished(let result):
                            Self.logger.debug("makeComputeRequest handler finished")
                            group.cancelAll()
                            return result
                        case .handlerError(let error):
                            Self.logger.error("makeComputeRequest handler failed: \(error)")
                            group.cancelAll()
                            throw error
                        case .requestStreamFinished:
                            Self.logger.debug("makeComputeRequest request stream finished")
                        case .responseStreamFinished:
                            Self.logger.debug("makeComputeRequest response stream finished")
                        }
                    }

                    throw LocalCloudBoardClientError
                        .internalError("Unexpectedly reached end of makeComputeRequest without result")
                }
            }
        }

        internal func decryptResponseStream(
            from requestSession: PCCGatewayInvokeWorkloadSession,
            to responseContinuation: AsyncThrowingStream<PrivateCloudComputeProtocolResponse, Error>.Continuation,
            cryptoContext: PrivateCloudComputeCryptoContext,
            validatedAttestationBundle: LocalCloudBoardAttestationBundle,
            endpoint: any CloudAppEndpoint,
            checkForREL: Bool = true, // Only proxy requests check for REL
            bypassDecapContinuation: AsyncStream<Proto_PrivateCloudCompute_ResponseContext>.Continuation? = nil
        ) async throws {
            var receivedFinalRequestExecutionLogEntry = false
            for try await response in requestSession.responseStream {
                var decapsulatedPCCMessage = try cryptoContext.decapsulateMessage(
                    response.data,
                    isFinal: response.isFinal
                )

                if let chunkData = decapsulatedPCCMessage.readLengthPrefixedChunk() {
                    let pccResponse = try LocalCloudBoardGRPCAsyncClient
                        .ProtoPrivateCloudComputeResponse(serializedBytes: chunkData)
                    if case .requestExecutionLogEntry(let requestExecutionLogEntry) = pccResponse.type {
                        if receivedFinalRequestExecutionLogEntry {
                            Self.logger.error(
                                "Request execution log entry received after getting the final request execution log entry"
                            )
                        }

                        // Extract response context for bypass decapsulation if available
                        if requestExecutionLogEntry.hasResponseContext,
                           let bypassDecapContinuation {
                            bypassDecapContinuation.yield(requestExecutionLogEntry.responseContext)
                            bypassDecapContinuation.finish()
                        }

                        Self.logger.log(
                            "Received request execution log entry \(String(describing: requestExecutionLogEntry), privacy: .public)"
                        )
                        try responseContinuation.yield(self.convertToClientResponse(
                            pccResponse,
                            trustedProxyAttestationBundle: validatedAttestationBundle,
                            endpoint: endpoint
                        ))
                        if requestExecutionLogEntry.final {
                            receivedFinalRequestExecutionLogEntry = true
                            Self.logger.log("Received final request execution log entry")
                        }
                    } else {
                        try responseContinuation.yield(self.convertToClientResponse(
                            pccResponse
                        ))
                    }
                } else {
                    responseContinuation.yield(PrivateCloudComputeProtocolResponse.payload(.init()))
                }
            }

            if checkForREL, !receivedFinalRequestExecutionLogEntry {
                Self.logger.error("Final request execution log entry not received for the request")
            }
            responseContinuation.finish()
        }

        private func convertToClientResponse(
            _ pccResponse: ProtoPrivateCloudComputeResponse,
            isNack: Bool = false,
            trustedProxyAttestationBundle: LocalCloudBoardAttestationBundle? = nil,
            endpoint: (any CloudAppEndpoint)? = nil
        ) throws -> PrivateCloudComputeProtocolResponse {
            let message: PrivateCloudComputeProtocolResponse
            switch pccResponse.type {
            case .responseUuid(let uuidData):
                if let uuid = UUID(from: uuidData) {
                    message = PrivateCloudComputeProtocolResponse.responseID(uuid)
                } else {
                    throw LocalCloudBoardGRPCClientError.invalidUUIDInCloudComputeResponse
                }
            case .responsePayload(let payloadData):
                message = PrivateCloudComputeProtocolResponse.payload(payloadData)
            case .responseSummary(let responseSummary):
                message = PrivateCloudComputeProtocolResponse.responseSummary(.init(from: responseSummary))
            case .requestExecutionLogEntry(let requestExecutionLogEntry):
                var computeNodeAttestationBundle: LocalCloudBoardAttestationBundle?
                if requestExecutionLogEntry.hasAttestation {
                    computeNodeAttestationBundle = try self.attestationValidator
                        .parseComputeNodeAttestationBundle(requestExecutionLogEntry.attestation)
                    if case .cloudAttestationBundle = computeNodeAttestationBundle!.attestationBundle {
                        let bundle = try AttestationBundle(data: requestExecutionLogEntry.attestation)
                        self.attestationValidator.queueRELAttestationForValidation(bundle: bundle)
                    }
                }
                var outboundCallContext: OutboundCallContext?
                if requestExecutionLogEntry.hasOutboundCallContext {
                    outboundCallContext = .init(from: requestExecutionLogEntry.outboundCallContext)
                }
                if let trustedProxyAttestationBundle, let endpoint {
                    let requestExecutionLogEntryData = RequestExecutionLogEntry(
                        isNack: isNack,
                        isFinal: requestExecutionLogEntry.final,
                        endpoint: endpoint,
                        trustedProxyAttestationBundle: trustedProxyAttestationBundle,
                        computeNodeAttestationBundle: computeNodeAttestationBundle,
                        outboundCallContext: outboundCallContext
                    )
                    message = PrivateCloudComputeProtocolResponse.requestExecutionLogEntry(requestExecutionLogEntryData)
                } else {
                    throw LocalCloudBoardGRPCClientError.incompleteInfoForCreatingRequestExecutionLogEntry
                }
            case .payloadChunk(let subresponsePayload):
                message = PrivateCloudComputeProtocolResponse.payloadChunk(
                    .init(subrequestID: subresponsePayload.subrequestID, data: subresponsePayload.chunkData)
                )
            case .subOpen(let subresponseOpen):
                message = PrivateCloudComputeProtocolResponse
                    .subresponseOpen(.init(subrequestID: subresponseOpen.subrequestID))
            case .subClose(let subresponseClose):
                let responseStatus = switch subresponseClose.status {
                case .ok: SubresponseClose.Status.ok
                case .internalError: SubresponseClose.Status.internalError
                case .invalidRequest: SubresponseClose.Status.invalidRequest
                case .discarded: SubresponseClose.Status.discarded
                case .UNRECOGNIZED: SubresponseClose.Status.unknown
                }
                let subresponseClose = SubresponseClose(
                    subrequestID: subresponseClose.subrequestID,
                    responseStatus: responseStatus
                )
                message = PrivateCloudComputeProtocolResponse.subresponseClose(subresponseClose)
            case .componentTimeMeasurement(let componentTimeMeasurement):
                let measurement = ComponentTimeMeasurement(from: componentTimeMeasurement)
                message = PrivateCloudComputeProtocolResponse.componentTimeMeasurement(measurement)
            case .costToken(let costToken):
                message = PrivateCloudComputeProtocolResponse.costToken(.init(from: costToken))
            case .none:
                message = PrivateCloudComputeProtocolResponse.unknown
            @unknown default:
                message = PrivateCloudComputeProtocolResponse.unknown
            }
            return message
        }

        internal func mapToDecryptedPCCResponseStreams(
            _ nackStreams: [ProxyCloudAppEndpoint: AsyncThrowingStream<FinalizableChunk, Error>],
            cryptoContexts: [HostAndPort: PrivateCloudComputeCryptoContext],
            validatedAttestationBundles: [HostAndPort: LocalCloudBoardAttestationBundle]
        ) -> [ProxyCloudAppEndpoint: any Sendable & AsyncSequence<PrivateCloudComputeProtocolResponse, any Error>] {
            return (nackStreams.reduce(into: [:]) { result, endpointAndResponse in
                let endpoint = endpointAndResponse.key
                let nackResponseStream = endpointAndResponse.value

                let decryptedResponseStream = nackResponseStream.map { encryptedResponseChunk in
                    guard let cryptoContext = cryptoContexts[endpoint.hostAndPort] else {
                        Self.logger.error("Failed to find crypto context for endpoint \(endpoint.hostAndPort)")
                        throw PCCEnvironmentError.cryptoContextNotFound
                    }

                    var decapsulatedPCCMessage = try cryptoContext.decapsulateMessage(
                        encryptedResponseChunk.data,
                        isFinal: encryptedResponseChunk.isFinal
                    )

                    if let chunkData = decapsulatedPCCMessage.readLengthPrefixedChunk() {
                        let pccResponse = try LocalCloudBoardGRPCAsyncClient
                            .ProtoPrivateCloudComputeResponse(serializedBytes: chunkData)
                        return try self.convertToClientResponse(
                            pccResponse,
                            trustedProxyAttestationBundle: validatedAttestationBundles[endpoint.hostAndPort],
                            endpoint: endpoint
                        )
                    } else {
                        throw PCCEnvironmentError.failedToDecodePrivateCloudComputeMessage
                    }
                }
                result[endpoint] = decryptedResponseStream
            })
        }

        internal func decryptBypassResponseStream(
            bypassResponseStream: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>,
            bypassDecapStream: AsyncStream<Proto_PrivateCloudCompute_ResponseContext>,
            bypassPCCResponseContinuation: AsyncThrowingStream<PrivateCloudComputeProtocolResponse, Error>.Continuation
        ) async throws {
            var bypassDecapsulator: StreamingResponseBypassDecapsulator?

            do {
                for try await chunk in bypassResponseStream {
                    // Wait for decapsulator to be available
                    if bypassDecapsulator == nil {
                        var decapIter = bypassDecapStream.makeAsyncIterator()
                        guard let bypassContext = await decapIter.next() else {
                            Self.logger.error("Failed to get bypass decapsulation context from REL entry")
                            throw LocalCloudBoardGRPCClientError.failedToGetBypassDecapsulator
                        }

                        let aeadType = if HPKE.AEAD.AES_GCM_128.value == bypassContext.aeadID {
                            HPKE.AEAD.AES_GCM_128
                        } else if HPKE.AEAD.AES_GCM_256.value == bypassContext.aeadID {
                            HPKE.AEAD.AES_GCM_256
                        } else {
                            Self.logger.error("Invalid AEAD type in bypass response context: \(bypassContext.aeadID)")
                            throw LocalCloudBoardGRPCClientError.invalidAeadType
                        }

                        bypassDecapsulator = try StreamingResponseBypassDecapsulator(
                            aead: aeadType,
                            aeadKey: SymmetricKey(data: bypassContext.aeadKey),
                            aeadNonce: bypassContext.aeadNonce
                        )
                        Self.logger.log("Created bypass decapsulator with AEAD type \(String(describing: aeadType))")
                    }

                    guard chunk.encryptedPayload.count > 0 else {
                        bypassPCCResponseContinuation.yield(PrivateCloudComputeProtocolResponse.payload(.init()))
                        continue
                    }

                    if bypassDecapsulator ==
                        nil { throw LocalCloudBoardClientError.internalError("bypassDecapsulator must not be nil") }
                    var data = try bypassDecapsulator!.decapsulateResponseMessage(
                        chunk.encryptedPayload,
                        isFinal: chunk.isFinal
                    )

                    if let chunkData = data.readLengthPrefixedChunk() {
                        let pccResponse = try LocalCloudBoardGRPCAsyncClient
                            .ProtoPrivateCloudComputeResponse(serializedBytes: chunkData)
                        try bypassPCCResponseContinuation.yield(self.convertToClientResponse(
                            pccResponse
                        ))
                        Self.logger.log("Sent bypassed response chunk to client")
                    } else {
                        bypassPCCResponseContinuation.yield(PrivateCloudComputeProtocolResponse.payload(.init()))
                    }
                }
                bypassPCCResponseContinuation.finish()
            } catch {
                Self.logger.error("Bypass response decapsulation failed: \(error)")
                bypassPCCResponseContinuation.finish(throwing: error)
                throw error
            }
        }

        // MARK: - Persistent Connections

        /// Create a persistent connection to the provided proxy app endpoint. Within this connection, subrequests can
        /// be made.
        /// - Parameters:
        ///   - endpoint: Endpoint of the proxy app to connect to
        ///   - context: Request context, including the request ID and associated metadata
        ///   - configuration: Request configuration to control client and PCC Gateway behaviour
        ///   - handler: Request body provided with a connection session object which can be used to make subrequests
        ///   within the connection.
        /// - Returns: Return value of the handler. Throws if the handler throws or if the request failed for other
        /// reasons.
        internal func withPersistentConnection<ReturnType>(
            to endpoint: ProxyCloudAppEndpoint,
            context: RequestContext = .init(),
            configuration: PersistentConnectionConfiguration = .init(),
            handler: @Sendable @escaping (PersistentConnectionSession) async throws -> ReturnType
        ) async throws -> ReturnType where ReturnType: Sendable {
            // Obtain and validate attestations for request-handling endpoint and NACK endpoints if specified
            let (cryptoContexts, validatedAttestationBundles, perEndpointDataEncryptionKeys) = try await self
                .prepareCryptoContexts(for: [endpoint] + configuration.nackEndpoints)

            let invokeWorkloadRequestContext = PCCGatewayInvokeWorkloadRequestContext(
                baseContext: context,
                perEndpointDataEncryptionKeys: perEndpointDataEncryptionKeys
            )

            let proxyConfiguration = ProxyRequestConfiguration(
                useRequestBypass: false, // Persistent connections are not supported with request bypass
                nackEndpoints: configuration.nackEndpoints,
                applicationDataChunkingConfiguration: configuration.applicationDataChunkingConfiguration
            )

            // Invoke workload via PCC Gateway
            return try await self.gateway.invokeWorkload(
                for: endpoint,
                context: invokeWorkloadRequestContext,
                configuration: .proxy(proxyConfiguration)
            ) { requestSession in
                let nackResponseStreams = self.mapToDecryptedPCCResponseStreams(
                    requestSession.nackStreams,
                    cryptoContexts: cryptoContexts,
                    validatedAttestationBundles: validatedAttestationBundles
                )

                // Create request session
                let (requestStream, requestContinuation) = AsyncStream<SubrequestMessage>.makeStream()
                let (pccResponseStream, pccResponseContinuation) = AsyncThrowingStream<
                    PrivateCloudComputeProtocolResponse,
                    Error
                >
                    .makeStream()

                guard let cryptoContext = cryptoContexts[endpoint.hostAndPort],
                      let validatedAttestationBundle = validatedAttestationBundles[endpoint.hostAndPort] else {
                    throw LocalCloudBoardClientError.internalError(
                        "Crypto context and attestation bundle must exist for endpoint \(endpoint.hostAndPort)"
                    )
                }

                let pccRequestSession = PersistentConnectionSession(
                    attestationBundle: validatedAttestationBundle,
                    requestContinuation: requestContinuation,
                    nackStreams: nackResponseStreams
                )

                return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                    // Wrap application layer protocol request messages in PCC protocol and encrypt
                    group.addTask {
                        try self.sendAuthToken(
                            to: requestSession,
                            protocolVersion: 1,
                            cryptoContext: cryptoContext,
                            applicationDataChunkingConfiguration: configuration.applicationDataChunkingConfiguration
                        )
                        for await subrequestMessage in requestStream {
                            try self.sendSubrequestMessage(
                                subrequestMessage,
                                to: requestSession,
                                cryptoContext: cryptoContext
                            )
                        }
                        try self.sendFinalMessage(to: requestSession, cryptoContext: cryptoContext)
                        requestSession.finishSending()
                        return .requestStreamFinished
                    }

                    // Decrypt and forward PCC protocol response messages
                    group.addTask {
                        try await withThrowingTaskGroup { responseStreamGroup in
                            responseStreamGroup.addTask {
                                try await self.decryptResponseStream(
                                    from: requestSession,
                                    to: pccResponseContinuation,
                                    cryptoContext: cryptoContext,
                                    validatedAttestationBundle: validatedAttestationBundle,
                                    endpoint: endpoint
                                )
                                pccResponseContinuation.finish()
                            }

                            responseStreamGroup.addTask {
                                for try await pccResponse in pccResponseStream {
                                    switch pccResponse {
                                    case .responseID(let id):
                                        Self.logger.info("Received persistent connection response ID: \(id)")
                                    case .payload:
                                        Self.logger.info(
                                            "Unexpectedly received non-subresponse payload chunk in persistent connection response stream"
                                        )
                                    case .responseSummary(let summary):
                                        Self.logger.info(
                                            "Received persistent connection response summary: \(summary)"
                                        )
                                    case .requestExecutionLogEntry:
                                        Self.logger.info("Received persistent connection REL entry")
                                    case .payloadChunk(let payloadChunk):
                                        let subresponsePayload = SubresponsePayload(
                                            subrequestID: payloadChunk.subrequestID,
                                            data: payloadChunk.data
                                        )
                                        pccRequestSession
                                            .receiveSubresponseMessage(.subresponsePayload(subresponsePayload))
                                    case .subresponseOpen(let subOpen):
                                        pccRequestSession
                                            .receiveSubresponseMessage(.subresponseOpen(.init(
                                                subrequestID: subOpen.subrequestID
                                            )))
                                    case .subresponseClose(let subClose):
                                        pccRequestSession.receiveSubresponseMessage(.subresponseClose(.init(
                                            subrequestID: subClose.subrequestID,
                                            responseStatus: subClose.responseStatus
                                        )))
                                    case .componentTimeMeasurement(let componentTimeMeasurement):
                                        Self.logger.info(
                                            "Received component time measurement: \(componentTimeMeasurement)"
                                        )
                                    case .costToken(let costToken):
                                        Self.logger
                                            .info(
                                                "Received cost token in persistent connection: \(costToken.jwt.count) bytes"
                                            )
                                    case .unknown:
                                        Self.logger.info(
                                            "Unexpectedly received message of unknown type in persistent connection response stream"
                                        )
                                    }
                                }
                            }
                            try await responseStreamGroup.waitForAll()
                        }
                        return .responseStreamFinished
                    }

                    group.addTask {
                        return try await .handlerFinished(handler(pccRequestSession))
                    }

                    while let taskResult = try await group.next() {
                        switch taskResult {
                        case .handlerFinished(let result):
                            Self.logger.debug("withPersistentConnection handler finished")
                            group.cancelAll()
                            return result
                        case .handlerError(let error):
                            Self.logger.error("withPersistentConnection handler failed: \(error)")
                            group.cancelAll()
                            throw error
                        case .requestStreamFinished:
                            Self.logger.debug("withPersistentConnection request stream finished")
                        case .responseStreamFinished:
                            Self.logger.debug("withPersistentConnection response stream finished")
                        }
                    }

                    throw LocalCloudBoardClientError
                        .internalError("Unexpectedly reached end of makeProxyRequest without result")
                }
            }
        }

        // MARK: - Helpers

        internal func prepareCryptoContexts(for endpoints: [any CloudAppEndpoint]) async throws -> (
            cryptoContexts: [HostAndPort: PrivateCloudComputeCryptoContext],
            validatedBundles: [HostAndPort: LocalCloudBoardAttestationBundle],
            encapsulatedDEKs: [HostAndPort: EncapsulatedDataEncryptionKey]
        ) {
            var cryptoContexts: [HostAndPort: PrivateCloudComputeCryptoContext] = [:]
            var validatedAttestationBundles: [HostAndPort: LocalCloudBoardAttestationBundle] = [:]
            var perEndpointDataEncryptionKeys: [HostAndPort: EncapsulatedDataEncryptionKey] = [:]

            for endpoint in endpoints {
                let (cryptoContext, validatedAttestationBundle, dekInfo) = try await prepareCryptoContext(for: endpoint)
                let hostAndPort = endpoint.hostAndPort
                validatedAttestationBundles[hostAndPort] = validatedAttestationBundle
                cryptoContexts[hostAndPort] = cryptoContext
                perEndpointDataEncryptionKeys[hostAndPort] = dekInfo
            }

            return (cryptoContexts, validatedAttestationBundles, perEndpointDataEncryptionKeys)
        }

        internal func prepareCryptoContext(
            for endpoint: any CloudAppEndpoint,
            forcedDataEncryptionKey: SymmetricKey? = nil
        ) async throws -> (
            cryptoContext: PrivateCloudComputeCryptoContext,
            validatedBundle: LocalCloudBoardAttestationBundle,
            encapsulatedDEK: EncapsulatedDataEncryptionKey
        ) {
            let attestation = try await gateway.attestationSet(for: endpoint).activeAttestation
            let (publicKey, validatedAttestationBundle) = try await self.attestationValidator.parseAndValidate(
                attestation.attestationBundle
            )

            let cryptoContext = if let dek = forcedDataEncryptionKey {
                PrivateCloudComputeCryptoContext(dataEncryptionKey: dek)
            } else {
                PrivateCloudComputeCryptoContext()
            }

            let encapsulatedDEK = try cryptoContext.encapsulateDataEncryptionKey(for: publicKey)
            let dekInfo = EncapsulatedDataEncryptionKey(
                keyID: attestation.attestationMetadata.keyID,
                dataEncryptionKey: encapsulatedDEK
            )

            return (cryptoContext, validatedAttestationBundle, dekInfo)
        }

        private func sendAuthToken(
            to session: PCCGatewayInvokeWorkloadSession,
            protocolVersion: UInt32 = 0,
            cryptoContext: PrivateCloudComputeCryptoContext,
            applicationDataChunkingConfiguration: ApplicationDataChunkingConfiguration
        ) throws {
            var authToken = Proto_PrivateCloudCompute_OpenRequestPayload()
            authToken.version = protocolVersion
            if case .enabled(let chunkSize) = applicationDataChunkingConfiguration {
                authToken.capabilities = .with {
                    $0.applicationDataChunking = .with {
                        $0.size = UInt32(chunkSize)
                    }
                }
            }
            let pccAuthMessage = try ProtoPrivateCloudComputeRequest.serialized(with: .open(authToken))
            let encapsulated = try cryptoContext.encapsulateMessage(pccAuthMessage, isFinal: false)
            session.send(.init(data: encapsulated, isFinal: false))
        }

        private func sendApplicationPayload(
            _ data: Data,
            to session: PCCGatewayInvokeWorkloadSession,
            cryptoContext: PrivateCloudComputeCryptoContext
        ) throws {
            let message = try ProtoPrivateCloudComputeRequest.serialized(with: .applicationPayload(data))
            let encapsulated = try cryptoContext.encapsulateMessage(message, isFinal: false)
            session.send(.init(data: encapsulated, isFinal: false))
        }

        private func sendFinalMessage(
            to session: PCCGatewayInvokeWorkloadSession,
            cryptoContext: PrivateCloudComputeCryptoContext
        ) throws {
            let message = try ProtoPrivateCloudComputeRequest.serialized(with: .finalMessage(.init()))
            let encapsulated = try cryptoContext.encapsulateMessage(message, isFinal: true)
            session.send(.init(data: encapsulated, isFinal: true))
        }

        private func sendSubrequestMessage(
            _ subrequestMessage: SubrequestMessage,
            to session: PCCGatewayInvokeWorkloadSession,
            cryptoContext: PrivateCloudComputeCryptoContext
        ) throws {
            let message = try ProtoPrivateCloudComputeRequest.serialized(with: subrequestMessage.toProtoType())
            let encapsulated = try cryptoContext.encapsulateMessage(message, isFinal: false)
            session.send(.init(data: encapsulated, isFinal: false))
        }

        // MARK: - Replay

        /// Replay previously recorded request messages
        /// - Parameters:
        ///   - endpoint: Endpoint to replay the messages to
        ///   - configuration: Replay configuration, specifying the file containing the messages to replay as well as
        ///   various override options
        /// - Returns: The encrypted Private CLoud Compute protocol layer response stream. Note that if CloudBoard's
        /// anti-replay functionality is working as expected, the sequence never contains any data but will throw with a
        /// corresponding error.
        public func replayRequest(
            to endpoint: any CloudAppEndpoint,
            configuration: ReplayConfiguration
        ) async throws -> any AsyncSequence<Data, Error> & Sendable {
            // Load recorded messages from file
            var messagesData = try Data(contentsOf: configuration.messagesFileURL)
            var messages: [ProtoInvokeWorkloadRequest] = []

            // Parse messages and apply overrides
            let parametersOverride: ProtoInvokeWorkloadRequest.Parameters?
            if let parametersOverrideURL = configuration.parametersOverrideURL {
                var lengthPrefixedData = try Data(contentsOf: parametersOverrideURL)
                let messageData = lengthPrefixedData.readLengthPrefixedChunk()
                let message = try messageData.map { try ProtoInvokeWorkloadRequest(serializedBytes: $0) }
                if let message, case .parameters(let parameters) = message.type {
                    parametersOverride = parameters
                } else {
                    throw PCCEnvironmentError.invalidParametersOverrideFile
                }
            } else {
                parametersOverride = nil
            }

            while let messageData = messagesData.readLengthPrefixedChunk() {
                var message = try ProtoInvokeWorkloadRequest(serializedBytes: messageData)

                // Apply overrides to parameters message
                if case .parameters(var parameters) = message.type {
                    if let parametersOverride {
                        parameters = parametersOverride
                    }
                    if let requestIDOverride = configuration.requestIDOverride {
                        parameters.requestID = requestIDOverride
                    }
                    if let requestBypassOverride = configuration.requestBypassOverride {
                        parameters.requestBypassed = requestBypassOverride
                    }
                    if let metadataOverride = configuration.metadataOverride {
                        parameters.workload = .with {
                            $0.type = metadataOverride.workloadType
                            $0.param = .init(metadataOverride.workloadParameters)
                        }
                    }
                    // Disable NACK for replays
                    parameters.requestNack = false

                    message = ProtoInvokeWorkloadRequest.with { $0.parameters = parameters }
                }

                messages.append(message)
            }

            Self.logger.log("Replaying \(messages.count) messages to \(endpoint.hostAndPort)")

            // Send to gateway for replay - gateway returns encrypted chunks
            let encryptedResponseStream = try await self.gateway.replayMessages(
                endpoint: endpoint,
                messages: messages
            )

            // Extract raw encrypted data from chunks
            return encryptedResponseStream.map { encryptedChunk in
                return encryptedChunk.data
            }
        }
    }
}
