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

@_spi(HPKEAlgID) import CryptoKit
import Foundation
import Network
import Security
internal import Synchronization
internal import HTTPClientStateMachine
internal import InternalGRPC
internal import InternalSwiftProtobuf
internal import NIOCore
import os

extension PCCHarness {
    /// Compute the last 64 bits of SHA-256 of a name string, as a big-endian UInt64.
    ///
    /// Deliberately copied from PersistentService.sha256Last8 in CloudBoardDomain.
    /// Tooling constraints restrict cloudboard-vre-cli to depend only on LocalCloudBoardClient.
    public static func sha256Last8(_ name: String) -> UInt64 {
        let digest = SHA256.hash(data: Data(name.utf8))
        var value: UInt64 = 0
        for byte in digest.suffix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    /// Attestation info returned from a persistent service attestation query.
    public struct SuggestedAttestationInfo: Sendable {
        public let keyID: Data
        public let attestationBundle: Data
    }

    /// Connection lifecycle events from the server.
    public enum ConnectionEvent: Sendable {
        case shouldRecreate
        case mustRecreate
        case recreationForced
        case drainingStarted
        case drainingCritical
    }

    /// The type of a decrypted persistent service response, determined by the tag byte.
    public enum PersistentServiceResponseType: Sendable {
        /// Application-layer payload (tag byte `0x01`).
        case serviceSpecific(Data)
        /// Server-defined metadata update (tag byte `0x02`).
        case metadataUpdate(Data)
    }

    /// Test client for the InvokePersistentService bidirectional gRPC stream.
    ///
    /// Uses a response pump (``run()``) that must be active in a sibling task.
    /// The pump dispatches responses to typed channels: ``responseChunks`` for
    /// decrypted data, ``latestAttestation`` for the most recent attestation,
    /// and the ``onConnectionEvent`` callback for lifecycle notifications.
    ///
    /// Usage:
    /// ```swift
    /// try await withThrowingTaskGroup(of: Void.self) { group in
    ///     group.addTask { try await client.run() }
    ///     try await client.connectAndSetup(connectionID: "...", serviceID: "...")
    ///     try await client.sendChunk(requestData, isFinal: true)
    ///     for try await (message, isFinal) in client.responseChunks {
    ///         // process decrypted response message
    ///     }
    ///     try await client.terminate()
    ///     group.cancelAll()
    /// }
    /// ```
    public final class PersistentServiceTestClient: Sendable {
        private static let logger: Logger = .init(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "PersistentServiceTestClient"
        )

        private let call: GRPCAsyncBidirectionalStreamingCall<
            Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest,
            Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse
        >

        /// Shared attestation bundle validator for extracting public keys.
        private let attestationValidator: AttestationBundleValidator

        /// OHTTP crypto context, initialized during setup.
        private let cryptoContext = PrivateCloudComputeCryptoContext()

        /// Optional handler for connection lifecycle events (reconnection, draining).
        private let connectionEventHandler: (@Sendable (ConnectionEvent) -> Void)?

        // Pump dispatch channels
        private let _latestAttestation = Mutex<SuggestedAttestationInfo?>(nil)
        private let attestationResponseContinuation: AsyncStream<SuggestedAttestationInfo>.Continuation
        private let attestationResponses: AsyncStream<SuggestedAttestationInfo>
        private let setupAckContinuation: AsyncStream<Void>.Continuation
        private let setupAcks: AsyncStream<Void>
        private let responseChunkContinuation: AsyncThrowingStream<
            (message: PersistentServiceResponseType, isFinal: Bool),
            Error
        >.Continuation

        /// Decrypted response chunks. Iterate after setup is complete.
        public let responseChunks: AsyncThrowingStream<(message: PersistentServiceResponseType, isFinal: Bool), Error>

        /// The most recently received suggested attestation from the server.
        /// This is a snapshot so might not be the absolutely correct value
        public var latestAttestation: SuggestedAttestationInfo? {
            self._latestAttestation.withLock { $0 }
        }

        init(
            channel: GRPCChannel,
            attestationValidator: AttestationBundleValidator,
            onConnectionEvent: (@Sendable (ConnectionEvent) -> Void)? = nil
        ) {
            let client = Com_Apple_Cloudboard_Api_V1_PersistentServiceAsyncClient(channel: channel)
            self.call = client.makeInvokePersistentServiceCall()
            self.attestationValidator = attestationValidator
            self.connectionEventHandler = onConnectionEvent

            let (attestStream, attestCont) = AsyncStream<SuggestedAttestationInfo>.makeStream()
            self.attestationResponses = attestStream
            self.attestationResponseContinuation = attestCont

            let (ackStream, ackCont) = AsyncStream<Void>.makeStream()
            self.setupAcks = ackStream
            self.setupAckContinuation = ackCont

            let (chunkStream, chunkCont) = AsyncThrowingStream<
                (message: PersistentServiceResponseType, isFinal: Bool),
                Error
            >.makeStream()
            self.responseChunks = chunkStream
            self.responseChunkContinuation = chunkCont
        }

        /// Convenience initializer that creates a gRPC channel internally.
        ///
        /// This avoids the need for test code to import NIO modules directly, which can
        /// cause type identity conflicts when multiple copies of NIO are linked.
        public convenience init(
            host: String,
            port: Int,
            attestationValidator: AttestationBundleValidator,
            onConnectionEvent: (@Sendable (ConnectionEvent) -> Void)? = nil
        ) {
            self.init(
                host: host,
                port: port,
                attestationValidator: attestationValidator,
                clientIdentity: nil,
                serverVerifyBlock: nil,
                onConnectionEvent: onConnectionEvent
            )
        }

        /// Convenience initializer that creates a plaintext (insecure) gRPC channel.
        /// Use when connecting to a PersistentService running without TLS.
        public convenience init(
            host: String,
            port: Int,
            attestationValidator: AttestationBundleValidator,
            insecure _: Bool,
            onConnectionEvent: (@Sendable (ConnectionEvent) -> Void)? = nil
        ) {
            let group = PlatformSupport.makeEventLoopGroup(
                loopCount: 1,
                networkPreference: .userDefined(.networkFramework)
            )
            let channel = ClientConnection.insecure(group: group)
                .withConnectionTimeout(minimum: .seconds(5))
                .withConnectionBackoff(retries: .none)
                .connect(host: host, port: port)
            self.init(
                channel: channel,
                attestationValidator: attestationValidator,
                onConnectionEvent: onConnectionEvent
            )
        }

        /// Convenience initializer that creates a gRPC channel with an optional client identity for mTLS.
        ///
        /// When `clientIdentity` is provided, the full certificate chain is sent during the
        /// TLS handshake via `sec_identity_create_with_certificates`. This is required for
        /// servers that validate the chain against specific root CAs.
        ///
        /// - Parameters:
        ///   - serverVerifyBlock: Custom server certificate verification. When nil, all server
        ///     certificates are accepted without validation.
        public convenience init(
            host: String,
            port: Int,
            attestationValidator: AttestationBundleValidator,
            clientIdentity: SecIdentity?,
            clientCertificateChain: [SecCertificate] = [],
            serverVerifyBlock: sec_protocol_verify_t? = nil,
            onConnectionEvent: (@Sendable (ConnectionEvent) -> Void)? = nil
        ) {
            let group = PlatformSupport.makeEventLoopGroup(
                loopCount: 1,
                networkPreference: .userDefined(.networkFramework)
            )
            let verifyQueue = DispatchQueue(label: "com.apple.cloudos.cloudboard.test-client-tls-verify")

            let options = NWProtocolTLS.Options()

            // gRPC runs over HTTP/2, which is negotiated via ALPN. Without advertising these
            // protocols the server completes the TLS handshake with no ALPN selected and then
            // closes the connection ("No ALPN protocol negotiated, closing").
            for `protocol` in ["grpc-exp", "h2", "http/1.1"] {
                sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, `protocol`)
            }

            if let serverVerifyBlock {
                sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, true)
                sec_protocol_options_set_verify_block(
                    options.securityProtocolOptions,
                    serverVerifyBlock,
                    verifyQueue
                )
            } else {
                // Skip server certificate verification (test client trusts any server).
                sec_protocol_options_set_verify_block(
                    options.securityProtocolOptions,
                    { _, _, verifyComplete in verifyComplete(true) },
                    verifyQueue
                )
            }

            // Present our client identity with full chain if provided.
            if let clientIdentity {
                let secIdentity = sec_identity_create_with_certificates(
                    clientIdentity,
                    clientCertificateChain as CFArray
                )
                if let secIdentity {
                    sec_protocol_options_set_local_identity(
                        options.securityProtocolOptions,
                        secIdentity
                    )
                } else {
                    preconditionFailure("Failed to create sec_identity from provided client certificate chain")
                }
            }

            let tlsConfig = GRPCTLSConfiguration.makeClientConfigurationBackedByNetworkFramework(
                options: options
            )
            let channel = ClientConnection.usingTLS(with: tlsConfig, on: group)
                .withConnectionTimeout(minimum: .seconds(5))
                .withConnectionBackoff(retries: .none)
                .connect(host: host, port: port)
            self.init(
                channel: channel,
                attestationValidator: attestationValidator,
                onConnectionEvent: onConnectionEvent
            )
        }

        // MARK: - Response Pump

        /// Runs the response pump that dispatches gRPC responses to the appropriate channels.
        ///
        /// Must be called in a task group alongside your test logic. Returns when the
        /// gRPC response stream ends.
        public func run() async throws {
            defer {
                self.responseChunkContinuation.finish()
                self.attestationResponseContinuation.finish()
                self.setupAckContinuation.finish()
            }
            for try await response in self.call.responseStream {
                guard let type = response.type else { continue }
                switch type {
                case .keepAlive:
                    continue

                case .setupAck:
                    Self.logger.log("Received SetupAck")
                    self.setupAckContinuation.yield(())

                case .connectionLifecycle(let lifecycle):
                    self.handleConnectionLifecycle(lifecycle)

                case .serverLifeCycle(let serverLifecycle):
                    self.handleServerLifecycle(serverLifecycle)

                case .responseChunk(let chunk):
                    do {
                        let decrypted = try self.cryptoContext.decapsulateMessage(
                            chunk.encryptedPayload, isFinal: chunk.isFinal
                        )
                        // Tag byte constants from PersistentServiceMessage / PersistentServiceResponseMessage
                        // in CloudBoardControllerFramework. These are duplicated here because
                        // LocalCloudBoardClient cannot depend on CloudBoardControllerFramework.
                        let message: PersistentServiceResponseType
                        let tag = decrypted.first
                        let payload = decrypted.isEmpty ? decrypted : Data(decrypted.dropFirst())
                        switch tag {
                        case 0x02:
                            message = .metadataUpdate(payload)
                        default:
                            // 0x01 or unrecognized — treat as serviceSpecific
                            message = .serviceSpecific(payload)
                        }
                        self.responseChunkContinuation.yield((message, chunk.isFinal))
                    } catch {
                        self.responseChunkContinuation.finish(throwing: error)
                        throw error
                    }
                }
            }
        }

        private func handleConnectionLifecycle(
            _ lifecycle: Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse.ConnectionLifecycleMessage
        ) {
            if lifecycle.hasSuggestedAttestation, !lifecycle.suggestedAttestation.keyID.isEmpty {
                let info = SuggestedAttestationInfo(
                    keyID: lifecycle.suggestedAttestation.keyID,
                    attestationBundle: lifecycle.suggestedAttestation.attestationBundle
                )
                self._latestAttestation.withLock { $0 = info }

                if lifecycle.eventType == .responseToQuery {
                    self.attestationResponseContinuation.yield(info)
                }
            }

            switch lifecycle.eventType {
            case .responseToQuery:
                () // attestation already dispatched above
            case .connectionShouldBeRecreated:
                self.connectionEventHandler?(.shouldRecreate)
            case .connectionMustBeRecreated:
                self.connectionEventHandler?(.mustRecreate)
            case .connectionRecreationForced:
                self.connectionEventHandler?(.recreationForced)
            default:
                break
            }
        }

        private func handleServerLifecycle(
            _ serverLifecycle: Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse.ServerLifecycleMessage
        ) {
            switch serverLifecycle.eventType {
            case .drainingStarted:
                self.connectionEventHandler?(.drainingStarted)
            case .drainingCritical:
                self.connectionEventHandler?(.drainingCritical)
            default:
                break
            }
        }

        // MARK: - Send (non-blocking)

        /// Sends AnnounceConnection as the first message to establish the connection identifier.
        public func announceConnection(connectionID: String) async throws {
            var announce = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest.AnnounceConnection()
            announce.connectionID = connectionID
            var request = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest()
            request.type = .announceConnection(announce)
            try await self.call.requestStream.send(request)
        }

        /// Sends an attestation query. Use ``waitForAttestationResponse()`` to get the result.
        public func sendAttestationQuery() async throws {
            var request = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest()
            request.type = .attestationQuery(.init())
            try await self.call.requestStream.send(request)
        }

        /// Performs OHTTP key encapsulation and sends Setup. Use ``waitForSetupAck()`` to await confirmation.
        public func sendSetup(keyID: Data, attestationBundle: Data, serviceID: String) async throws {
            let (publicKey, _) = try await self.attestationValidator.parseAndValidate(attestationBundle)
            let encryptedKey = try self.cryptoContext.encapsulateDataEncryptionKey(for: publicKey)

            var setupMsg = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest.Setup()
            setupMsg.decryptionKey.keyID = keyID
            setupMsg.decryptionKey.encryptedPayload = encryptedKey
            setupMsg.serviceID = serviceID

            var request = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest()
            request.type = .setup(setupMsg)
            try await self.call.requestStream.send(request)
        }

        /// Encrypts and sends a query chunk.
        public func sendChunk(_ data: Data, isFinal: Bool) async throws {
            // Tag byte constants from PersistentServiceMessage / PersistentServiceResponseMessage
            // in CloudBoardControllerFramework. These are duplicated here because
            // LocalCloudBoardClient cannot depend on CloudBoardControllerFramework.
            // Tag 0x01 = serviceSpecific.
            var taggedData = Data([0x01])
            taggedData.append(data)
            let encrypted = try self.cryptoContext.encapsulateMessage(taggedData, isFinal: isFinal)
            var chunk = Proto_Ropes_Common_Chunk()
            chunk.encryptedPayload = encrypted
            chunk.isFinal = isFinal

            var request = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest()
            request.type = .requestChunk(chunk)
            try await self.call.requestStream.send(request)
        }

        /// Encrypts and sends a metadata query chunk (tag 0x02).
        public func sendMetadataQuery(_ data: Data, isFinal: Bool) async throws {
            // Tag 0x02 = metadataQuery. See comment in sendChunk for why this is hardcoded.
            var taggedData = Data([0x02])
            taggedData.append(data)
            let encrypted = try self.cryptoContext.encapsulateMessage(taggedData, isFinal: isFinal)
            var chunk = Proto_Ropes_Common_Chunk()
            chunk.encryptedPayload = encrypted
            chunk.isFinal = isFinal
            var request = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest()
            request.type = .requestChunk(chunk)
            try await self.call.requestStream.send(request)
        }

        /// Sends a terminate message and closes the request stream.
        public func terminate() async throws {
            var request = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest()
            request.type = .terminate(.init())
            try await self.call.requestStream.send(request)
            self.call.requestStream.finish()
        }

        /// Closes the request stream without sending terminate.
        public func close() {
            self.call.requestStream.finish()
        }

        /// Forcefully cancels the underlying gRPC call and finishes all internal
        /// async streams so that callers blocked in ``waitForAttestationResponse()``
        /// or ``waitForSetupAck()`` are unblocked immediately.
        /// Use when the task is being cancelled and graceful terminate may not succeed.
        public func cancel() {
            self.responseChunkContinuation.finish()
            self.attestationResponseContinuation.finish()
            self.setupAckContinuation.finish()
            self.call.cancel()
        }

        // MARK: - Blocking Helpers

        /// Waits for the server to respond with a suggested attestation.
        /// The response pump (``run()``) must be active.
        public func waitForAttestationResponse() async throws -> SuggestedAttestationInfo {
            for await info in self.attestationResponses {
                return info
            }
            throw PersistentServiceTestClientError.unexpectedEndOfStream
        }

        /// Waits for the server to acknowledge setup.
        /// The response pump (``run()``) must be active.
        public func waitForSetupAck() async throws {
            for await _ in self.setupAcks {
                return
            }
            throw PersistentServiceTestClientError.unexpectedEndOfStream
        }

        // MARK: - Convenience

        /// Performs the full connection flow: announce → query attestation → validate → setup → wait for ack.
        ///
        /// Returns ``responseChunks`` for iterating decrypted data.
        /// The response pump (``run()``) must be active.
        @discardableResult
        public func connectAndSetup(
            connectionID: String,
            serviceID: String
        ) async throws -> AsyncThrowingStream<(message: PersistentServiceResponseType, isFinal: Bool), Error> {
            try await self.announceConnection(connectionID: connectionID)
            try await self.sendAttestationQuery()
            let attestation = try await self.waitForAttestationResponse()
            try await self.sendSetup(
                keyID: attestation.keyID,
                attestationBundle: attestation.attestationBundle,
                serviceID: serviceID
            )
            try await self.waitForSetupAck()
            return self.responseChunks
        }
    }

    enum PersistentServiceTestClientError: Error {
        case unexpectedEndOfStream
        case setupFailed
    }
}
