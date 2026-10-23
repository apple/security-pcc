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

// Kept at package level (not public) so it can change without ABI-compatibility concerns.
// This restriction can be relaxed once tooling moves to its own repo and targets.

/// Create XPC component within a specific server
package actor PersistentServiceClientRouterAPIXPCServer: PersistentServiceClientRouterAPIServerToClientProtocol {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentServiceClientRouterAPIXPCServer"
    )

    private let listener: CloudBoardAsyncXPCListener
    private let delegate: PersistentServiceClientRouterAPIServerDelegateProtocol

    /// Per-helper state: the responder for sending messages back and the
    /// XPC connection ID (used for cleanup on disconnect / reconnect
    /// bookkeeping).
    private struct HelperEntry {
        let responder: PersistentServiceClientRouterQueryResponder
        let connectionID: CloudBoardAsyncXPCConnection.ID
    }

    /// Active helpers keyed by their job UUID.
    private var helpersByUUID: [UUID: HelperEntry] = [:]

    /// Reverse mapping from connection identity to helper UUID, for disconnect cleanup.
    private var uuidByConnectionID: [CloudBoardAsyncXPCConnection.ID: UUID] = [:]

    internal var endpoint: CloudBoardAsyncXPCEndpoint? {
        get async { await self.listener.endpoint }
    }

    package init(
        localService: String,
        entitlement: String,
        delegate: PersistentServiceClientRouterAPIServerDelegateProtocol
    ) {
        self.listener = .init(
            localService: localService,
            entitlement: entitlement,
            singleClient: false
        )
        self.delegate = delegate
    }

    package func start() async {
        await self.listener.set(delegate: self)
        await self.listener.listen(buildMessageHandlerStore: self.configureHandlers)
    }

    /// Post an attestation usage report to a specific helper.
    ///
    /// Fire-and-forget at the XPC layer. Throughput-
    /// critical: unblocks the caller's per-instance consumer task from
    /// cb_attestationd round-trips. Dedup + retry + timeout tracking now
    /// lives at `JobHelperQuorumInstance.pendingAttestations`; the
    /// authoritative ack is the separate `.nodeApproval` command the
    /// jobhelper emits after validation completes.
    package func postAttestation(
        _ report: PersistentServiceClientRouter.AttestationUsageReport,
        to helperID: UUID
    ) async {
        guard let entry = helpersByUUID[helperID] else {
            Self.logger.warning(
                "Attestation post skipped: helper \(helperID, privacy: .public) not registered"
            )
            return
        }
        do {
            try await entry.responder.sendAttestation(report)
            Self.logger.info(
                "Attestation posted to helper \(helperID, privacy: .public), keyID \(report.keyID.base64EncodedString(), privacy: .public), purpose \(String(describing: report.purpose), privacy: .public)"
            )
        } catch {
            // Rare: the underlying `connection.post` throws synchronously on a
            // dead connection, or the responder closure throws
            // `.connectionInvalidated` if the weakly-held connection was
            // already released. Either way the reaper in the caller will
            // schedule a retry — no rollback needed here.
            Self.logger.error(
                "Attestation post failed for helper \(helperID, privacy: .public), keyID \(report.keyID.base64EncodedString(), privacy: .public): \(error, privacy: .public). Reaper will retry."
            )
        }
    }

    // MARK: - Helper registry

    /// Remove a helper's server-side state (responder + reverse mapping).
    /// Called from both `helperExiting` (explicit) and `invalidatedConnection` (disconnect).
    private func removeHelper(helperID: UUID) {
        if let entry = self.helpersByUUID.removeValue(forKey: helperID) {
            self.uuidByConnectionID.removeValue(forKey: entry.connectionID)
        }
    }

    /// Outcome of a `.Register` call, determined by the prior state of `helpersByUUID[helperID]`.
    private enum RegistrationOutcome {
        /// First registration for this `helperID`.
        case new
        /// Replaced an existing entry with a new connection — the previous connection is now stale.
        case reconnect
        /// Same `helperID` re-registered on the same connection — no change.
        case existing
    }

    /// Returns an existing or newly-created responder for the given helper, along with the
    /// registration outcome so the caller can fire coherent lifecycle events on the delegate.
    ///
    /// This method is synchronous (no suspension points between read and write) to avoid
    /// actor reentrancy issues with the helper registry.
    @discardableResult
    private func responder(
        forHelperID helperID: UUID,
        connection: CloudBoardAsyncXPCConnection
    ) -> (responder: PersistentServiceClientRouterQueryResponder, outcome: RegistrationOutcome) {
        let connectionID = connection.id

        if let existing = helpersByUUID[helperID] {
            if existing.connectionID == connectionID {
                // Same helper, same connection — reuse existing responder
                return (existing.responder, .existing)
            }
            // Helper reconnected with a new connection — clean up old reverse mapping and reset
            Self.logger.info("Helper \(helperID, privacy: .public) reconnected with new connection")
            self.uuidByConnectionID.removeValue(forKey: existing.connectionID)

            let responder = PersistentServiceClientRouterQueryResponder(connection: connection)
            self.helpersByUUID[helperID] = HelperEntry(
                responder: responder,
                connectionID: connectionID
            )
            self.uuidByConnectionID[connectionID] = helperID
            return (responder, .reconnect)
        }

        let responder = PersistentServiceClientRouterQueryResponder(connection: connection)
        self.helpersByUUID[helperID] = HelperEntry(
            responder: responder,
            connectionID: connectionID
        )
        self.uuidByConnectionID[connectionID] = helperID
        return (responder, .new)
    }

    /// Resolves the helper UUID from the current XPC connection context.
    private func resolveHelperID() throws -> UUID {
        guard let context = CloudBoardAsyncXPCContext.context else {
            Self.logger.error("No current XPC context — dropping message")
            throw PersistentServiceClientRouterAPIError.noXPCContextAvailable
        }
        guard let helperID = uuidByConnectionID[context.peerConnection.id] else {
            Self.logger.error("Received message from unregistered connection — dropping")
            throw PersistentServiceClientRouterAPIError.helperNotRegistered
        }
        return helperID
    }

    /// Resolves the helper UUID from the current XPC connection context, returning
    /// `nil` if there is no context or the connection was never registered. Unlike
    /// `resolveHelperID()`, this neither logs nor throws — for callers where a
    /// missing registration is benign (e.g. a helper that exits without ever
    /// registering) rather than an error to surface.
    private func currentHelperID() -> UUID? {
        guard let context = CloudBoardAsyncXPCContext.context else {
            return nil
        }
        return self.uuidByConnectionID[context.peerConnection.id]
    }

    private nonisolated func configureHandlers(_ handlers: inout CloudBoardAsyncXPCConnection.MessageHandlerStore) {
        handlers
            .register(PersistentServiceClientRouterAPIXPCClientToServerMessages.Register.self) { [weak self] message in
                if let self {
                    guard let context = CloudBoardAsyncXPCContext.context else {
                        Self.logger
                            .error("No current XPC context during register - dropping")
                        throw PersistentServiceClientRouterAPIError.noXPCContextAvailable
                    }
                    let (_, outcome) = await self.responder(
                        forHelperID: message.helperID,
                        connection: context.peerConnection
                    )
                    switch outcome {
                    case .new:
                        await self.delegate.helperConnected(helperID: message.helperID)
                    case .reconnect:
                        // Fire a synthetic disconnect before the new connect so the delegate
                        // sees a paired lifecycle. The stale connection's invalidatedConnection
                        // will suppress its own notification by connectionID mismatch.
                        await self.delegate.helperDisconnected(helperID: message.helperID)
                        await self.delegate.helperConnected(helperID: message.helperID)
                    case .existing:
                        break
                    }
                }
                return ExplicitSuccess()
            }

        handlers
            .register(PersistentServiceClientRouterAPIXPCClientToServerMessages.SendQuery.self) { [weak self] message in
                if let self {
                    let helperID = try await self.resolveHelperID()
                    guard let entry = await self.helpersByUUID[helperID] else {
                        Self.logger
                            .error(
                                "Received SendQuery from unregistered helper \(helperID, privacy: .public) - dropping"
                            )
                        throw PersistentServiceClientRouterAPIError.helperNotRegistered
                    }
                    await self.delegate.sendQuery(
                        jobHelperID: helperID,
                        payload: message.payload,
                        correlationID: message.correlationID,
                        timeout: message.timeout,
                        responder: entry.responder
                    )
                }
                return ExplicitSuccess()
            }

        handlers
            .register(
                PersistentServiceClientRouterAPIXPCClientToServerMessages.NodeApproval
                    .self
            ) { [weak self] message in
                if let self {
                    let helperID = try await self.resolveHelperID()
                    await self.delegate.nodeApprovalReceived(
                        helperID: helperID,
                        keyID: message.keyID,
                        approved: message.approved
                    )
                }
                return ExplicitSuccess()
            }

        handlers
            .register(
                PersistentServiceClientRouterAPIXPCClientToServerMessages.RelUseCommitted
                    .self
            ) { [weak self] message in
                if let self {
                    let helperID = try await self.resolveHelperID()
                    await self.delegate.relUseCommittedReceived(
                        helperID: helperID,
                        keyID: message.keyID,
                        success: message.success
                    )
                }
                return ExplicitSuccess()
            }

        handlers
            .register(
                PersistentServiceClientRouterAPIXPCClientToServerMessages.HelperExiting
                    .self
            ) { [weak self] _ in
                if let self {
                    // A helper that exits without a router-side registration record
                    // has nothing to tear down. Treat the missing registration as a
                    // benign no-op rather than rejecting the message — rejecting would
                    // surface as paired errors on both the router and the exiting helper.
                    if let helperID = await self.currentHelperID() {
                        // Remove state *before* notifying the delegate so that the delegate
                        // cannot send messages back to an exiting helper's responder.
                        await self.removeHelper(helperID: helperID)
                        await self.delegate.helperExiting(helperID: helperID)
                    }
                }
                return ExplicitSuccess()
            }
    }
}

// MARK: - CloudBoardAsyncXPCListenerDelegate

extension PersistentServiceClientRouterAPIXPCServer: CloudBoardAsyncXPCListenerDelegate {
    func invalidatedConnection(_ connection: CloudBoardAsyncXPCConnection) async {
        guard let helperID = uuidByConnectionID.removeValue(forKey: connection.id) else {
            return
        }
        // Only remove and notify if connectionID still matches. If the helper already
        // reconnected on a new connection, this invalidation is stale — the helper is
        // alive and should not receive a spurious disconnect event.
        if self.helpersByUUID[helperID]?.connectionID == connection.id {
            self.helpersByUUID.removeValue(forKey: helperID)
            await self.delegate.helperDisconnected(helperID: helperID)
        }
    }
}
