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
import CloudBoardDomain
import Foundation
import os
internal import CloudBoardLogging

/// Means to communicate to a specific PrivateServiceClientRouter implementation
package actor PersistentServiceClientRouterAPIXPCClient {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentServiceClientRouterAPIXPCClient"
    )

    private let machServiceName: String
    private let helperID: UUID
    private var connection: CloudBoardAsyncXPCConnection?
    /// Monotonic counter incremented on each reconnect. The invalidation/interruption
    /// handlers capture the generation at registration time and compare it when firing.
    /// If it doesn't match (because a reconnect already happened), the handler is stale
    /// and the call is skipped. This prevents a second enqueued event from the old
    /// connection from tearing down the new one.
    private var connectionGeneration: UInt64 = 0
    /// Callback for persistent service responses broadcast from the router.
    private let responseHandler: @Sendable (PersistentService.Response) async -> Void
    /// Synchronous callback for attestation usage reports broadcast from the router.
    /// `nonisolated` so the XPC posted-message handler (which cannot `await` into actor
    /// isolation) can invoke it directly; the callback is expected to enqueue onto an
    /// AsyncStream owned by the caller so no unstructured Task is needed here.
    private nonisolated let attestationUsageReportHandler:
        @Sendable (PersistentServiceClientRouter.AttestationUsageReport) -> Void

    public init(
        machServiceName: String,
        helperID: UUID,
        responseHandler: @escaping @Sendable (PersistentService.Response) async -> Void,
        attestationUsageReportHandler: @escaping @Sendable (PersistentServiceClientRouter.AttestationUsageReport)
            -> Void
    ) async {
        self.machServiceName = machServiceName
        self.helperID = helperID
        self.responseHandler = responseHandler
        self.attestationUsageReportHandler = attestationUsageReportHandler
        let conn = await CloudBoardAsyncXPCConnection.connect(to: machServiceName)
        self.connection = conn
        await self.installConnectionHandlers(on: conn)
    }

    public func activate() async {
        guard let connection else { return }
        await connection.activate(buildMessageHandlerStore: self.configureHandlers)
    }

    // MARK: - Connection lifecycle

    private func installConnectionHandlers(on connection: CloudBoardAsyncXPCConnection) async {
        let generation = self.connectionGeneration
        _ = await connection
            .handleConnectionInvalidated { [weak self] _ in
                await self?.surpriseDisconnect(generation: generation)
            }
            .handleConnectionInterrupted { [weak self] _ in
                await self?.surpriseDisconnect(generation: generation)
            }
    }

    /// Handles a surprise disconnect from the router by reconnecting, re-activating,
    /// and re-registering so the new router instance replays attestations.
    ///
    /// The `generation` parameter prevents stale events from a previous connection
    /// from tearing down a valid new connection. Both `handleConnectionInvalidated`
    /// and `handleConnectionInterrupted` can fire for the same connection; without
    /// the generation check the second (already-enqueued) call would reconnect again.
    ///
    /// Follows the same pattern as `PersistentServiceBridgeRouterXPCClient.surpriseDisconnect()`.
    private func surpriseDisconnect(generation: UInt64) async {
        guard generation == self.connectionGeneration else {
            Self.logger.info(
                "Ignoring stale disconnect for \(self.machServiceName, privacy: .public) (generation \(generation, privacy: .public) != \(self.connectionGeneration, privacy: .public))"
            )
            return
        }
        self.connectionGeneration &+= 1

        Self.logger.error(
            "Router connection lost for \(self.machServiceName, privacy: .public), reconnecting"
        )

        // Clean up old connection handlers and cancel the old connection.
        // Set connection to nil so interleaved send methods (which can run at
        // await suspension points) see no connection and return early, rather
        // than sending on an un-activated connection.
        if let connection {
            await connection.handleConnectionInvalidated(handler: nil)
            await connection.handleConnectionInterrupted(handler: nil)
            await connection.cancel()
        }
        self.connection = nil

        // Reconnect. Only assign to self.connection after the new connection
        // is fully activated.
        let newConnection = await CloudBoardAsyncXPCConnection.connect(to: self.machServiceName)
        await self.installConnectionHandlers(on: newConnection)
        await newConnection.activate(buildMessageHandlerStore: self.configureHandlers)
        self.connection = newConnection

        // Re-register with the new router instance. This causes the router to
        // replay all known attestations via sendAttestationIfNew, allowing the
        // job helper to re-approve them without restarting.
        await self.sendRegister()
    }

    private nonisolated func configureHandlers(_ handlers: inout CloudBoardAsyncXPCConnection.MessageHandlerStore) {
        handlers.register(PersistentServiceClientRouterResponseMessage.self) { [weak self] message in
            if let self {
                await self.responseHandler(message.response)
            }
            return ExplicitSuccess()
        }
        handlers.register(PersistentServiceClientRouterAttestationUsageReportMessage.self) { [weak self] message in
            // Synchronous hand-off to the caller's sync callback (which should
            // enqueue onto an AsyncStream drained by a structured consumer).
            // No unstructured Task here — the expensive validation happens in
            // the consumer, out of the XPC event loop. The authoritative ack
            // back to the router is the separate `.nodeApproval` command the
            // jobhelper emits once the validation resolves.
            guard let self else {
                Self.logger.warning(
                    "Dropping attestation usage report — XPC client deallocated before handler dispatch"
                )
                return
            }
            self.attestationUsageReportHandler(message.report)
        }
    }
}

extension PersistentServiceClientRouterAPIXPCClient: PersistentServiceClientRouterAPIClientToServerProtocol {
    public func sendRegister() async {
        guard let connection else { return }
        do {
            try await connection.send(
                PersistentServiceClientRouterAPIXPCClientToServerMessages.Register(
                    helperID: self.helperID
                )
            )
        } catch {
            Self.logger
                .error(
                    "\(String(unredacted: error), privacy: .public) while sending register to \(self.machServiceName, privacy: .public)"
                )
        }
    }

    public func sendQuery(
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration?
    ) async {
        guard let connection else {
            Self.logger.error(
                "No connection to router \(self.machServiceName, privacy: .public) while sending query with correlationID=\(correlationID, privacy: .public)"
            )
            return
        }
        do {
            try await connection.send(
                PersistentServiceClientRouterAPIXPCClientToServerMessages.SendQuery(
                    payload: payload,
                    correlationID: correlationID,
                    timeout: timeout
                )
            )
        } catch {
            // no need to throw any errors, or send a response, the system will trigger timeouts in the client
            Self.logger
                .error(
                    "Error=\(String(unredacted: error), privacy: .public) while sending a query with correlationID=\(correlationID, privacy: .public) to machServiceanme=\(self.machServiceName, privacy: .public)"
                )
        }
    }

    public func sendNodeApproval(keyID: Data, approved: Bool) async {
        guard let connection else { return }
        do {
            try await connection.send(
                PersistentServiceClientRouterAPIXPCClientToServerMessages.NodeApproval(
                    keyID: keyID,
                    approved: approved
                )
            )
        } catch {
            Self.logger
                .error(
                    "\(String(unredacted: error), privacy: .public) while sending node approval to \(self.machServiceName, privacy: .public)"
                )
        }
    }

    public func sendRelUseCommitted(keyID: Data, success: Bool) async {
        guard let connection else { return }
        do {
            try await connection.send(
                PersistentServiceClientRouterAPIXPCClientToServerMessages.RelUseCommitted(
                    keyID: keyID,
                    success: success
                )
            )
        } catch {
            Self.logger
                .error(
                    "\(String(unredacted: error), privacy: .public) while sending REL-use commit to \(self.machServiceName, privacy: .public)"
                )
        }
    }

    public func sendHelperExiting() async {
        guard let connection else { return }
        do {
            try await connection.send(
                PersistentServiceClientRouterAPIXPCClientToServerMessages.HelperExiting()
            )
        } catch {
            Self.logger
                .error(
                    "\(String(unredacted: error), privacy: .public) while sending helper exiting to \(self.machServiceName, privacy: .public)"
                )
        }
    }
}
