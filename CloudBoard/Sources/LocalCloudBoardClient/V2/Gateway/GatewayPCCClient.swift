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

import Foundation
internal import InternalGRPC
internal import NIOCore
internal import Synchronization
import os
internal import InternalSwiftProtobuf
internal import CloudAttestation

extension PCCHarness {
    enum GatewayPCCClientError: Error {
        case alreadyStarted
        case unexpectedWatchAttestationResponse
        case unavailable(error: Error)
        case noLongerConnected
        case deinitialized
    }

    struct AttestationInfo: Sendable {
        let keyID: String
        let unpublishedAttestations: [Data]
        let currentAttestationBundle: Data
    }

    /// Client used by the PCC Gateway to talk to individual cloud app endpoints on PCC nodes
    final class GatewayPCCClient: Sendable {
        fileprivate static let logger: os.Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "LocalCloudBoardClient.GatewayPCCClient"
        )

        enum State {
            case initialized(attestationPromise: Promise<AttestationSet, Error>)
            case awaitingFirstAttestation(attestationPromise: Promise<
                AttestationSet,
                Error
            >)
            case connected(currentAttestationSet: AttestationSet)
            case finished(error: Error? = nil)
        }

        let endpoint: any CloudAppEndpoint
        private let client: GRPCCloudBoardAsyncClient
        private let state: Mutex<State> =
            .init(.initialized(attestationPromise: .init(
                autoFailureIfUnfulfilled: GatewayPCCClientError
                    .deinitialized
            )))
        private let onAttestationReceived: (@Sendable (any CloudAppEndpoint, LocalCloudBoardAttestationBundle) -> Void)?

        init(
            eventLoopGroup: EventLoopGroup,
            endpoint: any CloudAppEndpoint,
            useTLS: Bool,
            onAttestationReceived: (@Sendable (any CloudAppEndpoint, LocalCloudBoardAttestationBundle) -> Void)? = nil
        ) {
            self.endpoint = endpoint
            self.onAttestationReceived = onAttestationReceived

            let queue = DispatchQueue(
                label: "com.apple.LocalCloudBoardClient.Verification.queue",
                qos: DispatchQoS.userInitiated
            )

            let channel = if useTLS {
                ClientConnection
                    .usingTLSBackedByNetworkFramework(on: eventLoopGroup)
                    .withTLSHandshakeVerificationCallback(on: queue, verificationCallback: { _, _, verifyComplete in
                        /// LocalCloudBoardClient.framework is typically used with the VRE or in other testing setups
                        /// where self-signed certificates are used, so we accept any certificate.
                        verifyComplete(true)
                    })
                    .withConnectionTimeout(minimum: .seconds(5))
                    .withConnectionBackoff(retries: .none)
                    .connect(host: endpoint.host, port: endpoint.port)
            } else {
                ClientConnection(configuration: .default(
                    target: .hostAndPort(endpoint.host, endpoint.port),
                    eventLoopGroup: eventLoopGroup
                ))
            }

            self.client = GRPCCloudBoardAsyncClient(channel: channel)
        }

        /// Connects to the endpoint and watches for attestation updates
        func run() async throws {
            try self.state.withLock { state in
                guard case .initialized(let attestationPromise) = state else {
                    throw GatewayPCCClientError.alreadyStarted
                }
                state = .awaitingFirstAttestation(attestationPromise: attestationPromise)
            }

            let request = ProtoWatchAttestationRequest()
            let responseStream = self.client.watchAttestation(request)

            do {
                for try await response in responseStream {
                    switch response.type {
                    case .attestionSet(let attestationSet):
                        try self.receiveAttestationSet(AttestationSet(from: attestationSet))
                    case .attestationRevocation(let revocation):
                        Self.logger.log("Received attestation revocation for key ID \(revocation.keyID)")
                    case .none:
                        throw GatewayPCCClientError.unexpectedWatchAttestationResponse
                    }
                }
                self.state.withLock { $0 = .finished() }
                await self.closeConnection()
            } catch {
                Self.logger.error("watchAttestation stream finished with error: \(error)")
                self.state.withLock { state in
                    // Fail the attestation promise if we're still waiting for the first attestation
                    // This prevents hanging when currentAttestationSet is called before the error occurs
                    switch state {
                    case .awaitingFirstAttestation(let attestationPromise):
                        attestationPromise.fail(with: error)
                    case .initialized, .connected, .finished:
                        // Nothing to do for these states
                        ()
                    }
                    state = .finished(error: error)
                }
                await self.closeConnection()
                throw error
            }
        }

        private func receiveAttestationSet(_ attestationSet: AttestationSet) throws {
            try self.state.withLock { state in
                switch state {
                case .initialized:
                    throw LocalCloudBoardClientError
                        .internalError("AppEndpointClient in state initialized after having previously been started")
                case .awaitingFirstAttestation(let attestationPromise):
                    attestationPromise.succeed(with: attestationSet)
                    Self.logger.info(
                        "Received first attestation set for endpoint \(self.endpoint.hostAndPort, privacy: .public) with active key ID: \(attestationSet.activeAttestation.attestationMetadata.keyID, privacy: .public)"
                    )
                    state = .connected(currentAttestationSet: attestationSet)
                case .connected:
                    Self.logger.info(
                        "Received attestation update for endpoint \(self.endpoint.hostAndPort, privacy: .public) with active key ID: \(attestationSet.activeAttestation.attestationMetadata.keyID, privacy: .public)"
                    )
                    state = .connected(currentAttestationSet: attestationSet)
                case .finished:
                    throw LocalCloudBoardClientError
                        .internalError("AppEndpointClient in state initialized after having previously been started")
                }
            }

            // Parse the attestation bundle and notify callback if present
            if let callback = self.onAttestationReceived {
                Self.logger
                    .info(
                        "Parsing attestation bundle for service discovery update on endpoint \(self.endpoint.hostAndPort, privacy: .public)"
                    )
                do {
                    let attestationBundle = try LocalCloudBoardAttestationBundle(
                        unvalidated: AttestationBundle(data: attestationSet.activeAttestation.attestationBundle),
                        validated: nil
                    )
                    Self.logger
                        .info(
                            "Successfully parsed attestation bundle, invoking service discovery callback for endpoint \(self.endpoint.hostAndPort, privacy: .public)"
                        )
                    callback(self.endpoint, attestationBundle)
                } catch {
                    Self.logger
                        .error(
                            "Failed to parse attestation bundle for service discovery update: \(error, privacy: .public)"
                        )
                }
            }
        }

        func closeConnection() async {
            do {
                try await self.client.channel.close().get()
            } catch {
                // Don't re-throw as close connection is only called when we reach the end of the connection handling
                // anyway.
                Self.logger.error("Failed to close gRPC connection cleanly: \(error)")
            }
        }

        var currentAttestationSet: AttestationSet {
            /// Returns the current attestation set. If not available, this will wait for an attestation set to be
            /// obtained via watchAttestation call.
            ///
            /// NOTE: This will wait indefinitely if ``run`` is not called.
            get async throws {
                let state = self.state.withLock { $0 }
                switch state {
                case .initialized(let attestationPromise), .awaitingFirstAttestation(let attestationPromise):
                    return try await Future(attestationPromise).valueWithCancellation
                case .connected(let attestationSet):
                    return attestationSet
                case .finished(error: let error):
                    if let error {
                        throw GatewayPCCClientError.unavailable(error: error)
                    } else {
                        throw GatewayPCCClientError.unavailable(error: GatewayPCCClientError.noLongerConnected)
                    }
                }
            }
        }

        /// Makes a `InvokeWorkload` call to the connected PCC endpoint and provides a bidirectional stream.
        func invokeWorkload()
            -> (
                AsyncStream<ProtoInvokeWorkloadRequest>.Continuation,
                GRPCAsyncResponseStream<ProtoInvokeWorkloadResponse>
            ) {
            let (requestStream, requestContinuation) = AsyncStream.makeStream(of: ProtoInvokeWorkloadRequest.self)
            let responseStream = self.client.invokeWorkload(requestStream)
            return (requestContinuation, responseStream)
        }

        /// Makes a `InvokeProxyDialBack` call to the connected PCC endpoint and provides a bidirectional stream.
        func invokeProxyDialBack(taskID: String)
            -> (
                AsyncStream<ProtoInvokeProxyDialBackRequest>.Continuation,
                GRPCAsyncResponseStream<ProtoInvokeProxyDialBackResponse>
            ) {
            let (requestStream, requestContinuation) = AsyncStream.makeStream(of: ProtoInvokeProxyDialBackRequest.self)
            let dialBackResponseStream = self.client.invokeProxyDialBack(requestStream)
            // Always send the InvokeProxyDialBackRequest.Initiate message first, identifying the task/worker
            requestContinuation.yield(.with {
                $0.initiate = .with {
                    $0.taskID = taskID
                }
            })

            return (requestContinuation, dialBackResponseStream)
        }
    }
}
