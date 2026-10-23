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

internal import CloudBoardAsyncXPC
package import CloudBoardDomain
import Foundation
import os

public actor CloudBoardBridgeAPIXPCClient {
    private let logger: Logger
    /// Creates a fresh, unactivated XPC connection to cb_bridged. Invoked lazily the first
    /// time a request needs a connection, and again after a disconnect.
    private let connectionFactory: @Sendable () async -> CloudBoardAsyncXPCConnection

    /// The connection lifecycle.
    private enum State {
        /// No connection: the next request establishes one.
        case notConnected
        /// A current connection, represented as a *future* that resolves to the fully
        /// **activated** connection. In-flight establishment and an established connection
        /// are the same case: callers `await` the task, which both coalesces concurrent
        /// callers onto a single establishment and ensures no caller ever observes an
        /// un-activated connection (the task activates before it resolves).
        case connection(Task<CloudBoardAsyncXPCConnection, Never>)
    }

    private var state: State = .notConnected
    /// Advanced on every teardown. The drop handlers capture the generation in effect
    /// when the connection was established and are ignored once it advances, so a stale
    /// event — including the invalidated+interrupted pair that can both fire for one
    /// connection — can't tear down a newer connection. Mirrors the pattern used by
    /// `PersistentServiceClientRouterAPIXPCClient`.
    private var generation: UInt64 = 0

    internal init(
        logger: Logger,
        connectionFactory: @escaping @Sendable () async -> CloudBoardAsyncXPCConnection
    ) {
        self.logger = logger
        self.connectionFactory = connectionFactory
    }
}

extension CloudBoardBridgeAPIXPCClient {
    public static func localConnection(logger: Logger) async -> CloudBoardBridgeAPIXPCClient {
        self.init(
            logger: logger,
            connectionFactory: { await .connect(to: kCloudBoardBridgeAPIXPCLocalServiceName) }
        )
    }
}

extension CloudBoardBridgeAPIXPCClient {
    /// Returns a live, activated connection to cb_bridged, establishing one on demand.
    ///
    /// The connection is created lazily on first use, so a process that never makes a
    /// bridge request never connects — and a process that isn't permitted to reach
    /// cb_bridged never triggers a reconnect loop.
    private func liveConnection() async -> CloudBoardAsyncXPCConnection {
        switch self.state {
        case .connection(let task):
            return await task.value
        case .notConnected:
            let generation = self.generation
            let factory = self.connectionFactory
            let task = Task { () async -> CloudBoardAsyncXPCConnection in
                let connection = await factory()
                // Install the drop handlers before activating so no event is missed,
                // and activate before returning so the future only resolves once the
                // connection is usable.
                let activated = await connection
                    .handleConnectionInvalidated { [weak self] conn in
                        await self?.connectionDropped(conn, generation: generation)
                    }
                    .handleConnectionInterrupted { [weak self] conn in
                        await self?.connectionDropped(conn, generation: generation)
                    }
                await activated.activate()
                return activated
            }
            self.state = .connection(task)
            return await task.value
        }
    }

    /// Handles a dropped connection (invalidated or interrupted). Unlike a background
    /// auto-reconnect, this simply returns to `.notConnected`; the next request
    /// re-establishes a connection via `liveConnection()`. Reconnection is therefore bounded
    /// by the rate of actual requests, so an unreachable service can't loop forever.
    private func connectionDropped(_ connection: CloudBoardAsyncXPCConnection, generation: UInt64) async {
        // Ignore stale events from a superseded connection.
        guard generation == self.generation else { return }
        self.generation &+= 1
        self.state = .notConnected
        self.logger.log("XPC connection to cb_bridged dropped; will reconnect on the next request.")
        await connection.handleConnectionInvalidated(handler: nil)
        await connection.handleConnectionInterrupted(handler: nil)
        await connection.cancel()
    }
}

extension CloudBoardBridgeAPIXPCClient: CloudBoardBridgeAPIClientToServerProtocol {
    package func makePIREncryptedRequest(
        _ encryptedRequest: PIREncryptedRequest,
        traceContext: PIREncryptedRequestTraceContext
    ) async throws -> PIREncryptedResponse {
        let connection = await self.liveConnection()
        return try await connection.send(
            CloudBoardBridgeAPIXPCClientToServerMessage.MakeEncryptedPIRRequest(
                encryptedRequest: encryptedRequest,
                traceContext: traceContext
            )
        )
    }

    package func makeToolInvocationRequest(
        _ request: PCCToolInvocationRequest
    ) async throws -> PCCToolInvocationResponse {
        let connection = await self.liveConnection()
        return try await connection.send(
            PCCToolInvocationMessage(request: request)
        )
    }

    package func makeAppleSigningServiceSignRequest(
        _ request: AppleSigningServiceSignRequest,
        traceContext: AppleSigningServiceTraceContext
    ) async throws -> InternalAppleSigningServiceSignResponse {
        let connection = await self.liveConnection()
        return try await connection.send(
            InternalAppleSigningServiceSignMessage(
                request: request,
                traceContext: traceContext
            )
        )
    }

    package func makeAppleSigningServiceGetKeyVersionsRequest(
        traceContext: AppleSigningServiceTraceContext
    ) async throws -> InternalAppleSigningServiceGetKeyVersionsResponse {
        let connection = await self.liveConnection()
        return try await connection.send(
            InternalAppleSigningServiceGetKeyVersionsMessage(traceContext: traceContext)
        )
    }

    package func makeCIPCompanionServiceVerifyImageRequest(
        _ request: CIPCompanionServiceVerifyImageRequest,
        traceContext: CIPCompanionServiceTraceContext,
    ) async throws -> InternalCIPCompanionServiceImageVerificationResponse {
        let connection = await self.liveConnection()
        return try await connection.send(
            InternalCIPCompanionServiceVerifyImageMessage(
                request: request,
                traceContext: traceContext
            )
        )
    }
}

extension CloudBoardBridgeAPIXPCClient: CloudBoardBridgeAPIClientProtocol {
    package func connect() async {
        // The connection is established lazily on the first request; this is an optional
        // eager warm-up for callers that want to pre-connect. Callers that never make a
        // request never connect.
        _ = await self.liveConnection()
    }

    package func ping() async throws {
        let connection = await self.liveConnection()
        _ = try await connection.send(CloudBoardBridgeAPIXPCClientToServerMessage.Ping())
    }
}
