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
import OSLog
import XPC

package protocol CloudBoardAsyncXPCListenerDelegate: Actor {
    func invalidatedConnection(_ connection: CloudBoardAsyncXPCConnection) async
}

package actor CloudBoardAsyncXPCListener {
    private typealias XPCResult = Result<XPCConnection, CloudBoardAsyncXPCError>

    private let name: String
    private var listener: XPCConnection
    private let auth: XPCConnectionAuthorization
    private var connections: [CloudBoardAsyncXPCConnection.ID: CloudBoardAsyncXPCConnection]
    private var logger: Logger
    private var listenerQueue: DispatchQueue
    private var postedMessageHandlers: [String: CloudBoardAsyncXPCConnection.XPCPostedMessageHandler]
    private var nonPostedMessageHandlers: [String: CloudBoardAsyncXPCConnection.XPCNonPostedMessageHandler]
    private weak var delegate: CloudBoardAsyncXPCListenerDelegate?
    private let onListening: ((CloudBoardAsyncXPCEndpoint) -> Void)?
    /// Exposed for factory wiring tests in `SingleClientListenerWiringTests`.
    /// `nonisolated` is safe because this is an immutable `let` set during init.
    package nonisolated let singleClient: Bool
    private var hasEverAcceptedConnection: Bool = false

    public var endpoint: CloudBoardAsyncXPCEndpoint? {
        self.listener.endpoint
    }

    public var connectionCount: Int {
        self.connections.count
    }

    /// Initialize an anonymous local listener
    /// - Parameters:
    ///   - singleClient: See ``init(localService:entitlement:singleClient:onListening:)`` for the full
    ///     semantics; this convenience initializer always creates an anonymous listener.
    ///   - onListening: A callback for testing use cases where access to the underlying endpoint is required
    public init(
        singleClient: Bool,
        onListening: ((CloudBoardAsyncXPCEndpoint) -> Void)? = nil
    ) {
        self.init(localService: nil, entitlement: nil, singleClient: singleClient, onListening: onListening)
    }

    /// Initialize xpc listener with an optional mach service name and an
    /// entitlement to check.
    ///
    /// - Parameters:
    ///   - localService: mach xpc service name, when nil, an anonymous listener is created.
    ///     Anonymous listener can be created within a regular process (does not require launchd), thus is suitable for
    ///     unit-testing.
    ///     CloudBoardAsyncXPCEndpoint can be used to establish a connection to an anonymous listener.
    ///   - entitlement: entitlement to check an incoming connection for, when nil, all connections are allowed.
    ///   - singleClient: When `true`, the listener accepts at most one client *for its entire lifetime*: a
    ///     second concurrent connection is rejected, and a reconnection after the first disconnects is also
    ///     rejected. Use this for per-instance launchd `MultipleInstances` services where the only legitimate
    ///     client is the process that spawned the instance via `xpc_connection_set_oneshot_instance(uuid)` —
    ///     for example `CloudBoardJobAPIXPCServer`, `CloudBoardSupportAppAPIXPCServer`,
    ///     `PersistentHelperXPCServer` (cb_pserverhelper / cb_pclienthelper),
    ///     `PersistentClientHelperRouterXPCServer`. Use `false` for shared-daemon listeners that legitimately
    ///     serve concurrent peers (e.g. cb_jobauthd, cb_attestationd, cb_bridged, CloudBoardController,
    ///     CloudBoardHealth, CloudBoardJobHelperAPI). There is no safe default — author must choose.
    ///   - onListening: A callback for testing use cases where access to the underlying endpoint is required
    public init(
        localService name: String?,
        entitlement: String?,
        singleClient: Bool,
        onListening: ((CloudBoardAsyncXPCEndpoint) -> Void)? = nil
    ) {
        let connection: XPCConnection = if let name {
            // Named local mach xpc listener
            XPCLocalConnection(
                xpc_connection_create_mach_service(
                    name,
                    nil,
                    UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
                )
            )
        } else {
            // Anonymous local mach listener
            XPCLocalConnection(xpc_connection_create(nil, nil))
        }

        self.init(
            connection: connection,
            entitlement: entitlement,
            singleClient: singleClient,
            onListening: onListening
        )
    }

    public func set(delegate: CloudBoardAsyncXPCListenerDelegate?) async {
        self.delegate = delegate
    }

    internal init(
        connection: XPCConnection,
        entitlement: String?,
        singleClient: Bool,
        onListening: ((CloudBoardAsyncXPCEndpoint) -> Void)? = nil
    ) {
        self.logger = Logger(subsystem: "com.apple.CloudBoardAsyncXPC", category: "CloudBoardXPCListener")
        self.connections = [:]
        self.postedMessageHandlers = [:]
        self.nonPostedMessageHandlers = [:]
        self.listener = connection
        self.name = connection.name
        self.listenerQueue = DispatchQueue(label: "com.apple.CloudBoardAsyncXPC.CloudBoardXPCListener.queue")
        self.listener.setTargetQueue(self.listenerQueue)
        self.onListening = onListening
        self.singleClient = singleClient

        if let entitlement {
            self.auth = XPCConnectionEntitlementAuthorization(
                entitlement: entitlement
            )
        } else {
            self.auth = XPCConnectionPassthroughAuthorization()
        }
    }

    private func invalidateConnection(_ connection: CloudBoardAsyncXPCConnection) async {
        self.connections.removeValue(forKey: connection.id)
        await self.delegate?.invalidatedConnection(connection)
    }

    private func handleNewConnection(connection: XPCLocalConnection) async {
        guard self.auth.isAuthorized(connection: connection) else {
            connection.cancel()
            return
        }

        if self.singleClient, self.hasEverAcceptedConnection {
            // The fault-level log line is part of the security signal contract: SIEM rules
            // and oncall dashboards key on this category + message text to flag rejected
            // single-client reconnect attempts. Don't downgrade the level or rephrase the
            // message without coordinating with the security team.
            self.logger.fault(
                "\(self.name, privacy: .public) refusing additional connection on single-client listener (already had a connection)"
            )
            connection.cancel()
            return
        }

        let authorizedConnection = CloudBoardAsyncXPCConnection(connection)

        await authorizedConnection.handleConnectionInvalidated { [weak self] conn in
            guard let self else { return }
            await self.invalidateConnection(conn)
        }

        await authorizedConnection.handleConnectionTerminationImminent { [weak self] conn in
            guard let self else { return }
            await self.invalidateConnection(conn)
        }

        await authorizedConnection.handleConnectionInterrupted { [weak self] conn in
            guard let self else { return }
            await self.invalidateConnection(conn)
        }

        self.connections[authorizedConnection.id] = authorizedConnection
        self.hasEverAcceptedConnection = true
        await authorizedConnection.activate(
            postedMessageHandlers: self.postedMessageHandlers,
            messageHandlers: self.nonPostedMessageHandlers
        )
    }

    private func handleXPCEvent(object: XPCObject) async -> Bool {
        do {
            let connection = try XPCConnectionCreate(
                connection: self.listener,
                object: object
            )
            await self.handleNewConnection(connection: connection)
        } catch CloudBoardAsyncXPCError.terminationImminent {
            self.logger.info("\(self.name, privacy: .public) listener termination is imminent")
            self.listener.cancel()
        } catch CloudBoardAsyncXPCError.connectionInterrupted {
            self.logger.info("\(self.name, privacy: .public) listener has been interrupted")
            self.listener.cancel()
        } catch CloudBoardAsyncXPCError.connectionInvalid(let reason) {
            self.logger
                .info("\(self.name, privacy: .public) listener has been invalidated: \(reason ?? "", privacy: .public)")
            return true
        } catch {
            self.logger.error(
                "\(self.name, privacy: .public) listener error: \(error, privacy: .public))"
            )
            self.listener.cancel()
        }

        return false
    }

    /// Register message handlers and start listening for incoming connections and xpc events
    @discardableResult
    public func listen(buildMessageHandlerStore: (inout CloudBoardAsyncXPCConnection.MessageHandlerStore) -> Void)
    -> Self {
        var store = CloudBoardAsyncXPCConnection.MessageHandlerStore()
        buildMessageHandlerStore(&store)

        self.listen(postedMessageHandlers: store.postedHandlers, messageHandlers: store.handlers)
        return self
    }

    @discardableResult
    public func listen(messageHandlerStore: CloudBoardAsyncXPCConnection.MessageHandlerStore) -> Self {
        self.listen(
            postedMessageHandlers: messageHandlerStore.postedHandlers,
            messageHandlers: messageHandlerStore.handlers
        )
        return self
    }

    @discardableResult
    internal func listen(
        postedMessageHandlers: [String: CloudBoardAsyncXPCConnection.XPCPostedMessageHandler],
        messageHandlers: [String: CloudBoardAsyncXPCConnection.XPCNonPostedMessageHandler]
    ) -> Self {
        self.postedMessageHandlers = postedMessageHandlers
        self.nonPostedMessageHandlers = messageHandlers

        // NOTE: We should pass a weak reference to self,
        // however, libswift_Concurrency when ran only in combination with XCTest
        // either over-releases async context or it gets corrupted, therefore
        // libswift_Concurrency hits a bad access exception in swift_task_switchImpl.
        //
        // To keep unit tests in place, lets pass strong reference to self here. In practice,
        // client code will call cancel to terminate the connection and thus break
        // the strong reference.
        Task {
            for await object in self.listener.events where await self.handleXPCEvent(object: object) {
                // Listener connection has been invalidated
                return
            }
        }

        self.listener.activate()
        if let onListening {
            // The only usage of onListening is to get to the endpoint to use it locally
            // extracting it here simplifies calling code outside the isolation domain considerably
            onListening(self.listener.endpoint!)
        }

        return self
    }

    /// Stop listening for xpc events and close all open connections.
    ///
    /// The listener is terminal after `cancel()`: re-invoking `listen(...)` is unsupported. In particular,
    /// the `hasEverAcceptedConnection` sticky flag used by single-client listeners is intentionally not
    /// reset, so a re-listen would silently inherit the prior reject-everything state.
    public func cancel() async {
        self.listener.cancel()
        for (_, connection) in self.connections {
            await connection.cancel()
        }
        self.connections = [:]
    }

    /// Send a message with no reply to all open connections
    public func broadcast<Message: CloudBoardAsyncXPCCodableMessage>(
        _ message: Message,
        requiringEntitlement: String? = nil
    ) async
    where Message.Success == ExplicitSuccess {
        await withThrowingTaskGroup(of: Void.self) { group in
            for (_, connection) in self.connections {
                if let requiringEntitlement,
                   await !connection.hasEntitlement(requiringEntitlement) {
                    continue
                }
                group.addTask {
                    _ = try await connection.send(message)
                }
            }
        }
    }

    /// Send a message with no reply to all open connections
    public func broadcast(
        _ message: some CloudBoardAsyncXPCByteBufferMessage,
        requiringEntitlement: String? = nil
    ) async {
        await withThrowingTaskGroup(of: Void.self) { group in
            for (_, connection) in self.connections {
                if let requiringEntitlement,
                   await !connection.hasEntitlement(requiringEntitlement) {
                    continue
                }
                group.addTask {
                    _ = try await connection.send(message)
                }
            }
        }
    }

    /// Selects the first open connection, enforcing the caller's entitlement
    /// requirement. Throws ``CloudBoardAsyncXPCError/noConnection`` if no peers
    /// are connected, or ``CloudBoardAsyncXPCError/missingEntitlement`` if the
    /// selected peer lacks the requested entitlement. Centralising this logic
    /// keeps the four `sendToAny` overloads below consistent.
    private func firstAuthorizedConnection(
        requiringEntitlement: String?
    ) async throws -> CloudBoardAsyncXPCConnection {
        guard let connection = self.connections.values.first else {
            throw CloudBoardAsyncXPCError.noConnection
        }
        if let requiringEntitlement, await !connection.hasEntitlement(requiringEntitlement) {
            throw CloudBoardAsyncXPCError.missingEntitlement
        }
        return connection
    }

    /// This sends the message to the first connection. This is primarily intended to be used in a client-server setting
    /// where it is known to be a 1:1 relationship.
    public func sendToAny<Message: CloudBoardAsyncXPCCodableMessage>(
        _ message: Message,
        requiringEntitlement: String? = nil
    ) async throws -> Message.Success {
        let connection = try await self.firstAuthorizedConnection(requiringEntitlement: requiringEntitlement)
        return try await connection.send(message)
    }

    /// This sends the message to the first connection. This is primarily intended to be used in a client-server setting
    /// where it is known to be a 1:1 relationship.
    public func sendToAny<Message: CloudBoardAsyncXPCByteBufferMessage>(
        _ message: Message,
        requiringEntitlement: String? = nil
    ) async throws -> Message.Success {
        let connection = try await self.firstAuthorizedConnection(requiringEntitlement: requiringEntitlement)
        return try await connection.send(message)
    }

    /// Fire-and-forget post to the first connection. 1:1 relationship assumed.
    ///
    /// Exists so that callers with a `Never`-reply message can get a throwing,
    /// single-peer alternative to `broadcast` (which silently swallows send
    /// errors). `sendToAny` with a non-Never
    /// `Message.Success` uses `connection.send` which waits for a reply; for
    /// Never-reply messages that hangs.
    public func sendToAny<Message: CloudBoardAsyncXPCByteBufferMessage>(
        _ message: Message,
        requiringEntitlement: String? = nil
    ) async throws
    where Message.Success == Never, Message.Failure == Never {
        let connection = try await self.firstAuthorizedConnection(requiringEntitlement: requiringEntitlement)
        try await connection.post(message)
    }

    /// Fire-and-forget post to the first connection for codable messages with
    /// Never reply. Same rationale as the byte-buffer overload above.
    public func sendToAny<Message: CloudBoardAsyncXPCCodableMessage>(
        _ message: Message,
        requiringEntitlement: String? = nil
    ) async throws
    where Message.Success == Never, Message.Failure == Never {
        let connection = try await self.firstAuthorizedConnection(requiringEntitlement: requiringEntitlement)
        try await connection.post(message)
    }

    /// Send a message with no reply to all open connections
    public func broadcast<Message: CloudBoardAsyncXPCCodableMessage>(
        _ message: Message,
        requiringEntitlement: String? = nil
    ) async
    where Message.Success == Never, Message.Failure == Never {
        await withThrowingTaskGroup(of: Void.self) { group in
            for (_, connection) in self.connections {
                if let requiringEntitlement,
                   await !connection.hasEntitlement(requiringEntitlement) {
                    continue
                }
                group.addTask {
                    try await connection.post(message)
                }
            }
        }
    }

    /// Send a message with no reply to all open connections
    public func broadcast<Message: CloudBoardAsyncXPCByteBufferMessage>(
        _ message: Message,
        requiringEntitlement: String? = nil
    ) async
        where Message.Success == Never,
        Message.Failure == Never {
        await withThrowingTaskGroup(of: Void.self) { group in
            for (_, connection) in self.connections {
                if let requiringEntitlement,
                   await !connection.hasEntitlement(requiringEntitlement) {
                    continue
                }
                group.addTask {
                    try await connection.post(message)
                }
            }
        }
    }

    deinit {
        self.listener.cancel()
        self.connections = [:]
    }
}
