// Copyright © 2025 Apple Inc. All Rights Reserved.

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
import CryptoKit
import Foundation
internal import HTTPClientStateMachine
import os
internal import Synchronization
internal import InternalSwiftProtobuf

/// Package-internal extensions with advanced APIs for CloudBoard-internal usage
package extension PCCHarness.Environment {
    // MARK: - Client Factory Methods

    /// Create a PCC protocol-layer client for making raw protocol-layer requests
    /// - Returns: A PCCProtocolLayerClient instance that can be used to make requests to proxy or compute endpoints
    package func makePCCProtocolLayerClient() -> PCCProtocolLayerClient {
        return PCCProtocolLayerClient(environment: self)
    }

    // MARK: - Message Observers

    /// Set observer for InvokeWorkload messages with a specific endpoint (compute or proxy for NACK)
    /// - Parameters:
    ///   - observer: Observer to set for the endpoint, or nil to remove existing observer
    ///   - endpoint: The endpoint to observe messages for
    package func setInvokeWorkloadMessageObserver(
        _ observer: PCCHarness.InvokeWorkloadMessageObserver?,
        for endpoint: any PCCHarness.CloudAppEndpoint
    ) {
        self.gateway.nodeManager.setInvokeWorkloadMessageObserver(observer, for: endpoint)
    }

    /// Set observer for ProxyDialBack messages with a specific proxy endpoint
    /// - Parameters:
    ///   - observer: Observer to set for the proxy endpoint, or nil to remove existing observer
    ///   - endpoint: The proxy endpoint to observe messages for
    package func setProxyDialBackMessageObserver(
        _ observer: PCCHarness.ProxyDialBackMessageObserver?,
        for endpoint: PCCHarness.ProxyCloudAppEndpoint
    ) {
        self.gateway.nodeManager.setProxyDialBackMessageObserver(observer, for: endpoint)
    }

    // MARK: - Raw PCC Protocol Requests

    package func makePCCProtocolProxyRequest<ReturnType: Sendable>(
        to endpoint: PCCHarness.ProxyCloudAppEndpoint,
        context: PCCHarness.RequestContext = .init(),
        configuration: PCCHarness.ProxyRequestConfiguration = .init(),
        handler: @Sendable @escaping (PCCHarness.PCCProtocolProxyRequestSession) async throws -> ReturnType
    ) async throws -> ReturnType {
        // Obtain and validate attestations for request-handling endpoint and nack endpoints if specified
        let (cryptoContexts, validatedAttestationBundles, perEndpointDataEncryptionKeys) = try await self
            .prepareCryptoContexts(for: [endpoint] + configuration.nackEndpoints)

        let invokeWorkloadRequestContext = PCCHarness.PCCGatewayInvokeWorkloadRequestContext(
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
        ) { gatewaySession in
            let nackResponseStreams = self.mapToDecryptedPCCResponseStreams(
                gatewaySession.nackStreams,
                cryptoContexts: cryptoContexts,
                validatedAttestationBundles: validatedAttestationBundles
            )

            // Create request session
            let (requestStream, requestContinuation) = AsyncStream<(
                PCCHarness.PrivateCloudComputeProtocolRequest,
                Bool
            )>
                .makeStream()
            let (responseStream, responseContinuation) =
                AsyncThrowingStream<PCCHarness.PrivateCloudComputeProtocolResponse, Error>.makeStream()
            let (bypassPCCResponseStream, bypassPCCResponseContinuation) =
                AsyncThrowingStream<PCCHarness.PrivateCloudComputeProtocolResponse, Error>.makeStream()

            guard let cryptoContext = cryptoContexts[endpoint.hostAndPort],
                  let validatedAttestationBundle = validatedAttestationBundles[endpoint.hostAndPort] else {
                throw LocalCloudBoardClientError.internalError(
                    "Crypto context and attestation bundle must exist for endpoint \(endpoint.hostAndPort)"
                )
            }

            let pccRequestSession = PCCHarness.PCCProtocolProxyRequestSession(
                attestationBundle: validatedAttestationBundle,
                requestContinuation: requestContinuation,
                responseStream: responseStream,
                bypassResponseStream: bypassPCCResponseStream,
                nackStreams: nackResponseStreams
            )

            return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                // Serialize and encrypt PCC protocol request messages
                group.addTask {
                    for await (pccRequest, isFinal) in requestStream {
                        let serialized = try PCCHarness.ProtoPrivateCloudComputeRequest.serialized(
                            with: pccRequest.toProtoType()
                        )
                        let encapsulated = try cryptoContext.encapsulateMessage(serialized, isFinal: isFinal)
                        gatewaySession.send(.init(data: encapsulated, isFinal: isFinal))
                    }
                    return .requestStreamFinished
                }

                // Decrypt and forward PCC protocol response messages
                group.addTask {
                    return try await withThrowingTaskGroup(of: Void.self) { responseGroup in
                        // Handle primary response stream
                        responseGroup.addTask {
                            try await self.decryptResponseStream(
                                from: gatewaySession,
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
                        Self.logger.log("makePCCProtocolProxyRequest handler finished")
                        group.cancelAll()
                        return result
                    case .handlerError(let error):
                        Self.logger.error("makePCCProtocolProxyRequest handler failed: \(error)")
                        group.cancelAll()
                        throw error
                    case .requestStreamFinished:
                        Self.logger.info("makePCCProtocolProxyRequest request stream finished")
                    case .responseStreamFinished:
                        Self.logger.info("makePCCProtocolProxyRequest response stream finished")
                    }
                }

                throw LocalCloudBoardClientError
                    .internalError("Unexpectedly reached end of makePCCProtocolProxyRequest without result")
            }
        }
    }

    package func makePCCProtocolComputeRequest<ReturnType: Sendable>(
        to endpoint: PCCHarness.ComputeCloudAppEndpoint,
        context: PCCHarness.RequestContext = .init(),
        configuration: PCCHarness.ComputeRequestConfiguration = .init(),
        handler: @Sendable @escaping (PCCHarness.PCCProtocolRequestSession) async throws -> ReturnType
    ) async throws -> ReturnType {
        let (cryptoContext, validatedAttestationBundle, encapsulatedDEK) = try await self
            .prepareCryptoContext(for: endpoint)

        let invokeWorkloadRequestContext = PCCHarness.PCCGatewayInvokeWorkloadRequestContext(
            baseContext: context,
            perEndpointDataEncryptionKeys: [endpoint.hostAndPort: encapsulatedDEK]
        )

        // Create request session
        let (requestStream, requestContinuation) = AsyncStream<(PCCHarness.PrivateCloudComputeProtocolRequest, Bool)>
            .makeStream()
        let (responseStream, responseContinuation) = AsyncThrowingStream<
            PCCHarness.PrivateCloudComputeProtocolResponse,
            Error
        >
            .makeStream()
        let pccRequestSession = PCCHarness.PCCProtocolRequestSession(
            attestationBundle: validatedAttestationBundle,
            requestContinuation: requestContinuation,
            responseStream: responseStream
        )

        // Invoke workload via PCC Gateway
        return try await self.gateway.invokeWorkload(
            for: endpoint,
            context: invokeWorkloadRequestContext,
            configuration: .compute(configuration)
        ) { gatewaySession in
            return try await withThrowingTaskGroup(of: RequestTaskGroupResult<ReturnType>.self) { group in
                // Serialize and encrypt PCC protocol request messages
                group.addTask {
                    for await (pccRequest, isFinal) in requestStream {
                        let serialized = try PCCHarness.ProtoPrivateCloudComputeRequest.serialized(
                            with: pccRequest.toProtoType()
                        )
                        let encapsulated = try cryptoContext.encapsulateMessage(serialized, isFinal: isFinal)
                        gatewaySession.send(.init(data: encapsulated, isFinal: isFinal))
                    }
                    return .requestStreamFinished
                }

                // Decrypt and forward PCC protocol response messages
                group.addTask {
                    try await self.decryptResponseStream(
                        from: gatewaySession,
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
                        Self.logger.log("makePCCProtocolComputeRequest handler finished")
                        group.cancelAll()
                        return result
                    case .handlerError(let error):
                        Self.logger.error("makePCCProtocolComputeRequest handler failed: \(error)")
                        group.cancelAll()
                        throw error
                    case .requestStreamFinished:
                        Self.logger.info("makePCCProtocolComputeRequest request stream finished")
                    case .responseStreamFinished:
                        Self.logger.info("makePCCProtocolComputeRequest response stream finished")
                    }
                }

                throw LocalCloudBoardClientError
                    .internalError("Unexpectedly reached end of makePCCProtocolComputeRequest without result")
            }
        }
    }

    // MARK: - PCC Protocol Layer Client

    /// Client for making raw PCC protocol-layer requests
    package final class PCCProtocolLayerClient: Sendable {
        private let environment: PCCHarness.Environment

        internal init(environment: PCCHarness.Environment) {
            self.environment = environment
        }

        // MARK: - Proxy Requests

        /// Make a raw PCC protocol-layer request to a proxy app endpoint
        /// - Parameters:
        ///   - endpoint: Endpoint of the proxy app to send the request to
        ///   - context: Request context, including the request ID and associated metadata
        ///   - configuration: Request configuration to control client and PCC Gateway behaviour
        ///   - handler: Request body provided with a session object exposing request and response streams
        /// - Returns: Return value of the handler. Throws if the handler throws or if the request failed
        package func makeRequest<ReturnType: Sendable>(
            to endpoint: PCCHarness.ProxyCloudAppEndpoint,
            context: PCCHarness.RequestContext = .init(),
            configuration: PCCHarness.ProxyRequestConfiguration = .init(),
            handler: @Sendable @escaping (PCCHarness.PCCProtocolProxyRequestSession) async throws -> ReturnType
        ) async throws -> ReturnType {
            return try await self.environment.makePCCProtocolProxyRequest(
                to: endpoint,
                context: context,
                configuration: configuration,
                handler: handler
            )
        }

        // MARK: - Compute Requests

        /// Make a raw PCC protocol-layer request to a compute app endpoint
        /// - Parameters:
        ///   - endpoint: Endpoint of the compute app to send the request to
        ///   - context: Request context, including the request ID and associated metadata
        ///   - configuration: Request configuration to control client and PCC Gateway behaviour
        ///   - handler: Request body provided with a session object exposing request and response streams
        /// - Returns: Return value of the handler. Throws if the handler throws or if the request failed
        package func makeRequest<ReturnType: Sendable>(
            to endpoint: PCCHarness.ComputeCloudAppEndpoint,
            context: PCCHarness.RequestContext = .init(),
            configuration: PCCHarness.ComputeRequestConfiguration = .init(),
            handler: @Sendable @escaping (PCCHarness.PCCProtocolRequestSession) async throws -> ReturnType
        ) async throws -> ReturnType {
            return try await self.environment.makePCCProtocolComputeRequest(
                to: endpoint,
                context: context,
                configuration: configuration,
                handler: handler
            )
        }
    }
}
