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

import CloudBoardOSActivity
import Foundation
import OSLog
import XPC
import XPCPrivate

// MARK: - Actor

/// Represents an authorized bi-directional xpc connection established by a remote client to the XPC service:
package actor CloudBoardAsyncXPCConnection: Identifiable {
    private typealias XPCResult = Result<XPCDictionary, CloudBoardAsyncXPCError>
    public typealias ConnectionEventHandler = @Sendable (CloudBoardAsyncXPCConnection) async -> Void

    public nonisolated let name: String
    public var logger: Logger
    private var connection: XPCLocalConnection
    private var connectionQueue: DispatchQueue
    private var postedMessageHandlers: [String: XPCPostedMessageHandler]
    private var nonPostedMessageHandlers: [String: XPCNonPostedMessageHandler]

    private var onConnectionInvalidated: ConnectionEventHandler?
    private var onConnectionInterrupted: ConnectionEventHandler?
    private var onConnectionTerminationImminent: ConnectionEventHandler?

    internal init(_ connection: XPCLocalConnection) {
        self.connection = connection
        self.connectionQueue = DispatchQueue(
            label: "com.apple.CloudBoardAsyncXPC.CloudBoardXPCConnection.queue",
            qos: .userInteractive,
        )
        self.postedMessageHandlers = [:]
        self.nonPostedMessageHandlers = [:]
        self.logger = Logger(subsystem: "com.apple.CloudBoardAsyncXPC", category: "CloudBoardXPCConnection")
        self.name = connection.name
        self.connection.setTargetQueue(self.connectionQueue)
    }

    private func handleMessage(message: sending XPCDictionary) {
        guard let type: String = message[kMessageTypeKey] else {
            self.logger.error("Could not get type for message from \(self.name, privacy: .public) connection")
            return
        }

        self.logger.debug("Handle \(type, privacy: .public) message from \(self.name, privacy: .public) connection")
        let logger = self.logger
        if let handler = self.postedMessageHandlers[type] {
            // posted message handler should not be async as that can trivially lead to
            // messages getting reordered.
            { [weak self, message] in
                guard let self else { return }
                defer { withExtendedLifetime(self) {} }
                guard let encodedMessage: xpc_object_t = message[kMessageBodyKey] else {
                    return
                }
                CloudBoardAsyncXPCContext.$context.withValue(.init(peerConnection: self)) {
                    handler(encodedMessage)
                }
            }()
        } else if let handler = self.nonPostedMessageHandlers[type] {
            Task(priority: Task.currentPriority) { [weak self, message, logger] in
                guard let self else { return }
                defer { withExtendedLifetime(self) {} }

                guard let encodedMessage: xpc_object_t = message[kMessageBodyKey] else {
                    return
                }

                guard var replyDict = message.createReply() else {
                    return
                }

                do {
                    try await CloudBoardAsyncXPCContext.$context.withValue(.init(peerConnection: self)) {
                        let encodedReply = try await handler(encodedMessage)
                        replyDict[kMessageBodyKey] = encodedReply
                    }
                } catch {
                    logger.error(
                        "Failed to handle \(type, privacy: .public) message with reply: \(error, privacy: .public)"
                    )
                    replyDict[kMessageRemoteProcessErrorKey] = String(describing: error)
                    replyDict.removeValue(forKey: kMessageBodyKey)
                }
                replyDict.sendReply()
            }
        } else {
            self.logger
                .error(
                    "Unexpected \(type, privacy: .public) message from \(self.name, privacy: .public) connection, canceling connection"
                )
            self.cancel()
        }
    }

    /// Extract return value for a specific message type from an xpc reply message
    private func getReply<Message: CloudBoardAsyncXPCMessage>(object: XPCObject, from: Message.Type) throws -> Message
    .Success where Message.Reply: Codable {
        let encodedReply = try getEncodedReply(object: object, from: from)
        let reply = try XPCObjectDecoder().decode(Message.Reply.self, from: encodedReply)
        return try reply.get()
    }

    internal func getEncodedReply(
        object: XPCObject,
        from _: (some CloudBoardAsyncXPCMessage).Type
    ) throws -> xpc_object_t {
        let dict = try XPCDictionary(connection: self.connection, object: object)
        guard let encodedReply: xpc_object_t = dict[kMessageBodyKey] else {
            guard let unexpectedError: String = dict[kMessageRemoteProcessErrorKey] else {
                throw CloudBoardAsyncXPCError.corruptedReply
            }

            throw CloudBoardAsyncXPCError.remoteProcessError(
                unexpectedError,
                connectionName: self.connection.name
            )
        }
        return encodedReply
    }

    /// All libxpc events are tunneled thru this method and dispatched to appropriate handlers
    private func handleXPCEvent(object: XPCObject) async -> Bool {
        do {
            let message = try XPCDictionary(
                connection: self.connection,
                object: object
            )
            self.handleMessage(message: message)
        } catch CloudBoardAsyncXPCError.terminationImminent {
            self.logger.info("\(self.name, privacy: .public) connection termination is imminent")
            await self.onConnectionTerminationImminent?(self)
            self.connection.cancel()
        } catch CloudBoardAsyncXPCError.connectionInterrupted {
            self.logger.info("\(self.name, privacy: .public) connection has been interrupted")
            await self.onConnectionInterrupted?(self)
            self.connection.cancel()
        } catch CloudBoardAsyncXPCError.connectionInvalid(let reason) {
            self.logger
                .info(
                    "\(self.name, privacy: .public) connection has been invalidated: \(reason ?? "", privacy: .public)"
                )
            await self.onConnectionInvalidated?(self)
            self.connection.eventsContinuation.finish()
            return true
        } catch {
            self.logger.error(
                "\(self.name, privacy: .public) connection error: (\(error, privacy: .public))"
            )
            self.connection.cancel()
        }

        return false
    }

    /// XPC connections start in a suspended state and require activation. Activate the connection without any message
    /// handlers.
    @discardableResult
    public func activate() -> Self {
        self.activate(postedMessageHandlers: [:], messageHandlers: [:])
        return self
    }

    /// XPC connections start in a suspended state and require activation. Activate the connection and register message
    /// handlers.
    @discardableResult
    public func activate(buildMessageHandlerStore: (inout MessageHandlerStore) -> Void) -> Self {
        var store = CloudBoardAsyncXPCConnection.MessageHandlerStore()
        buildMessageHandlerStore(&store)
        self.activate(postedMessageHandlers: store.postedHandlers, messageHandlers: store.handlers)
        return self
    }

    @discardableResult
    internal func activate(
        postedMessageHandlers: [String: XPCPostedMessageHandler],
        messageHandlers: [String: XPCNonPostedMessageHandler]
    ) -> Self {
        self.nonPostedMessageHandlers.merge(messageHandlers, uniquingKeysWith: { _, newHandler in newHandler })
        self.postedMessageHandlers.merge(postedMessageHandlers, uniquingKeysWith: { _, newHandler in newHandler })

        Task { [weak self] in
            guard let self else { return }
            for await object in await self.connection.events {
                _ = await self.handleXPCEvent(object: object)
            }
        }

        self.connection.resume()

        return self
    }

    public func registerHandler<Message: CloudBoardAsyncXPCCodableMessage>(
        _: Message.Type,
        handler: @Sendable @escaping (Message) async throws -> Message.Success
    ) {
        var store = CloudBoardAsyncXPCConnection.MessageHandlerStore()
        store.register(Message.self, handler: handler)
        self.nonPostedMessageHandlers.merge(store.handlers, uniquingKeysWith: { _, newHandler in newHandler })
    }

    public func registerHandler<Message: CloudBoardAsyncXPCByteBufferMessage>(
        _: Message.Type,
        handler: @Sendable @escaping (Message) async throws -> Message.Success
    ) {
        var store = CloudBoardAsyncXPCConnection.MessageHandlerStore()
        store.register(Message.self, handler: handler)
        self.nonPostedMessageHandlers.merge(store.handlers, uniquingKeysWith: { _, newHandler in newHandler })
    }

    /// Cancel and close xpc connection
    public func cancel() {
        self.connection.cancel()
    }

    // Checks if peer has the provided entitlement
    public func hasEntitlement(_ entitlement: String) -> Bool {
        return self.connection.hasEntitlement(entitlement)
    }

    /// Send a non-posted message with response data.
    public func send<Message>(_ message: Message) async throws -> Message.Success
    where Message: CloudBoardAsyncXPCCodableMessage {
        let interval = Signposter.signposter.beginInterval("Send", "\(self.connection.name) \(type(of: message))")
        defer {
            Signposter.signposter.endInterval("Send", interval)
        }
        // Only create a new activity if none is already present
        return try await self._send(message)
    }

    /// Send a non-posted message without response data.
    public func send<Message>(_ message: Message) async throws
    where Message: CloudBoardAsyncXPCCodableMessage, Message.Success == ExplicitSuccess {
        let interval = Signposter.signposter.beginInterval("Send", "\(self.connection.name) \(type(of: message))")
        defer {
            Signposter.signposter.endInterval("Send", interval)
        }
        // Only create a new activity if none is already present
        _ = try await self._send(message)
    }

    private func _send<Message: CloudBoardAsyncXPCCodableMessage>(
        _ message: Message
    ) async throws -> Message.Success {
        let interval = Signposter.signposter.beginInterval("XPC Encode", "\(Message.Type.self)")
        let encodedMessage = try XPCObjectEncoder().encode(message)
        Signposter.signposter.endInterval("XPC Encode", interval)

        var dict = XPCDictionary()
        dict[kMessageTypeKey] = String(describing: Message.self)
        dict[kMessageBodyKey] = encodedMessage

        return try await withCheckedThrowingContinuation { continuation in
            let replyLock = NSLock()
            let interval = Signposter.signposter.beginInterval(
                "Send encoded",
                "\(self.connection.name) \(type(of: message))"
            )
            self.connection.sendMessageWithReply(dict, self.connectionQueue) { object in
                Signposter.signposter.endInterval("Send encoded", interval)
                do {
                    // NSLock life-time is limited to individual send method call,
                    // thus the lock in never unlocked once it's locked. It's a replacement for
                    // swift-atomics boolean that used to be here.
                    if replyLock.try() {
                        let result = try self.getReply(object: object, from: Message.self)
                        continuation.resume(returning: result)
                    } else {
                        self.logger.error("Dropping unexpected reply on \(self.name, privacy: .public) connection")
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Send a posted message.
    ///
    /// Posted message can have no return or error from the remote end.
    ///
    /// Returns as soon as message has been sent out.
    public func post<Message: CloudBoardAsyncXPCCodableMessage>(_ message: Message) throws
        where Message.Success == Never,
        Message.Failure == Never {
        let interval = Signposter.signposter.beginInterval("Post", "\(self.connection.name) \(type(of: message))")
        defer {
            Signposter.signposter.endInterval("Post", interval)
        }
        let encoder = XPCObjectEncoder()
        let encodedMessage = try encoder.encode(message)

        var dict = XPCDictionary()
        dict[kMessageTypeKey] = String(describing: Message.self)
        dict[kMessageBodyKey] = encodedMessage
        self.connection.sendMessage(dict)
    }

    @discardableResult
    public func handleConnectionInvalidated(handler: ConnectionEventHandler?) -> Self {
        self.onConnectionInvalidated = handler
        return self
    }

    @discardableResult
    public func handleConnectionInterrupted(handler: ConnectionEventHandler?) -> Self {
        self.onConnectionInterrupted = handler
        return self
    }

    @discardableResult
    public func handleConnectionTerminationImminent(handler: ConnectionEventHandler?) -> Self {
        self.onConnectionTerminationImminent = handler
        return self
    }

    deinit {
        self.connection.cancel()
    }
}

// MARK: - Message handlers

extension CloudBoardAsyncXPCConnection {
    internal typealias XPCNonPostedMessageHandler = @Sendable (xpc_object_t) async throws -> xpc_object_t
    /// Posted message handlers should not be made async as that can trivially lead to messages being reordered
    /// when they are getting delivered in quick succession.
    internal typealias XPCPostedMessageHandler = @Sendable (xpc_object_t) -> Void

    public struct MessageHandlerStore: Sendable {
        static let logger: Logger = .init(subsystem: "com.apple.CloudBoardAsyncXPC", category: "MessageHandlerStore")
        /// Handlers requiring a response from the other side
        internal private(set) var handlers: [String: XPCNonPostedMessageHandler]
        /// "Fire and forget" handlers
        internal private(set) var postedHandlers: [String: XPCPostedMessageHandler]

        public init() {
            self.handlers = [:]
            self.postedHandlers = [:]
        }

        public mutating func register<Message: CloudBoardAsyncXPCCodableMessage>(
            _: Message.Type,
            handler: @Sendable @escaping (Message) async throws -> Message.Success
        ) {
            self.handlers[String(describing: Message.self)] = { encodedMessage in
                let message = try Signposter.signposter.withIntervalSignpost(
                    "XPC handler decode",
                    "\(Message.Type.self)"
                ) {
                    let decoder = XPCObjectDecoder()
                    return try decoder.decode(Message.self, from: encodedMessage)
                }

                let reply: Message.Reply
                do {
                    let result = try await handler(message)
                    reply = .success(result)
                } catch let error as Message.Failure {
                    reply = .failure(error)
                }

                let interval = Signposter.signposter.beginInterval("XPC handler response encode", "\(type(of: reply))")
                let encoder = XPCObjectEncoder()
                let encodedReply = try encoder.encode(reply)
                Signposter.signposter.endInterval("XPC handler response encode", interval)
                return encodedReply
            }
        }

        public mutating func register<Message: CloudBoardAsyncXPCCodableMessage>(
            _: Message.Type,
            handler: @Sendable @escaping (Message) -> Void
        ) where Message.Success == Never, Message.Failure == Never {
            self.postedHandlers[String(describing: Message.self)] = { encodedMessage in
                let message = Signposter.signposter.withIntervalSignpost("XPC handler decode", "\(Message.Type.self)") {
                    let decoder = XPCObjectDecoder()
                    return try! decoder.decode(Message.self, from: encodedMessage)
                }

                handler(message)
            }
        }
    }
}

// MARK: - Static methods

extension CloudBoardAsyncXPCConnection {
    /// Connect to a machService by name
    public static func connect(to machService: String) async -> CloudBoardAsyncXPCConnection {
        let connection = XPCLocalConnection(xpc_connection_create_mach_service(machService, nil, 0))
        return CloudBoardAsyncXPCConnection(connection)
    }

    /// Connect to a machService by name of a specific UUID (for multi-instance services)
    public static func connect(to machService: String, withUUID uuid: UUID) async -> CloudBoardAsyncXPCConnection {
        let xpcConnection = xpc_connection_create_mach_service(machService, nil, 0)
        // xpc_connection_set_oneshot_instance() copies the uuid passed in here
        var instanceUUID = uuid
        withUnsafeMutablePointer(to: &instanceUUID) { id in
            xpc_connection_set_oneshot_instance(xpcConnection, id)
        }

        let connection = XPCLocalConnection(xpcConnection)
        return CloudBoardAsyncXPCConnection(connection)
    }

    /// Connect to an endpoint
    public static func connect(to endpoint: CloudBoardAsyncXPCEndpoint) async -> CloudBoardAsyncXPCConnection {
        let connection = XPCLocalConnection(endpoint: endpoint)
        return CloudBoardAsyncXPCConnection(connection)
    }
}

extension CloudBoardAsyncXPCConnection {
    public func entitlementValue(for entitlement: String) -> [String] {
        return self.connection.entitlementValue(for: entitlement)
    }
}

// MARK: - ByteBufferCodable support

extension CloudBoardAsyncXPCConnection {
    /// Send a posted message.
    public func post<Message>(_ message: Message) throws
    where Message: CloudBoardAsyncXPCByteBufferMessage, Message.Success == Never, Message.Failure == Never {
        let interval = Signposter.signposter.beginInterval("Post", "bb \(self.connection.name) \(type(of: message))")
        defer {
            Signposter.signposter.endInterval("Post", interval)
        }
        var byteBuffer = ByteBuffer()
        try message.encode(to: &byteBuffer)

        var dict = XPCDictionary()
        dict[kMessageTypeKey] = String(describing: Message.self)
        dict[kMessageBodyKey] = byteBuffer.withUnsafeReadableBytes {
            xpc_data_create($0.baseAddress, $0.count)
        }
        self.connection.sendMessage(dict)
    }

    /// Send a non-posted message with response data.
    public func send<Message>(_ message: Message) async throws -> Message.Success
    where Message: CloudBoardAsyncXPCByteBufferMessage {
        let interval = Signposter.signposter.beginInterval("Send", "bb \(self.connection.name) \(type(of: message))")
        defer {
            Signposter.signposter.endInterval("Send", interval)
        }
        return try await self._sendByteBufferCodable(message)
    }

    /// Send a non-posted message without response data.
    public func send<Message>(_ message: Message) async throws
    where Message: CloudBoardAsyncXPCByteBufferMessage, Message.Success == ExplicitSuccess {
        let interval = Signposter.signposter.beginInterval("Send", "bb \(self.connection.name) \(type(of: message))")
        defer {
            Signposter.signposter.endInterval("Send", interval)
        }
        _ = try await self._sendByteBufferCodable(message)
    }

    private func _sendByteBufferCodable<Message: CloudBoardAsyncXPCByteBufferMessage>(
        _ message: Message
    ) async throws -> Message.Success
    where Message: ByteBufferCodable, Message.Reply: ByteBufferCodable {
        let interval = Signposter.signposter.beginInterval("XPC Encode", "bb \(Message.Type.self)")
        var byteBuffer = ByteBuffer()
        try message.encode(to: &byteBuffer)
        let xpc_data = byteBuffer.withUnsafeReadableBytes {
            xpc_data_create($0.baseAddress, $0.count)
        }
        Signposter.signposter.endInterval("XPC Encode", interval)

        var dict = XPCDictionary()
        dict[kMessageTypeKey] = String(describing: Message.self)
        dict[kMessageBodyKey] = xpc_data

        return try await withCheckedThrowingContinuation { continuation in
            let replyLock = NSLock()
            let interval = Signposter.signposter.beginInterval(
                "Send encoded",
                "bb \(self.connection.name) \(type(of: message))"
            )
            self.connection.sendMessageWithReply(dict, self.connectionQueue) { object in
                Signposter.signposter.endInterval("Send encoded", interval)
                do {
                    // NSLock life-time is limited to individual send method call,
                    // thus the lock in never unlocked once it's locked. It's a replacement for
                    // swift-atomics boolean that used to be here.
                    if replyLock.try() {
                        let result = try self.getReply(object: object, from: Message.self)
                        continuation.resume(returning: result)
                    } else {
                        self.logger.error("Dropping unexpected reply on \(self.name, privacy: .public) connection")
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Extract return value for a specific message type from an xpc reply message
    private func getReply<Message: CloudBoardAsyncXPCByteBufferMessage>(
        object: XPCObject,
        from: Message.Type
    ) throws -> Message.Success {
        let encodedReply = try getEncodedReply(object: object, from: from)
        var buffer = ByteBuffer(from: encodedReply)
        let reply = try Message.Reply(from: &buffer)
        return try reply.get()
    }
}

extension CloudBoardAsyncXPCConnection.MessageHandlerStore {
    /// Register non-posted message handler.
    ///
    /// Specialized for ByteBufferCodable message and response
    package mutating func register<Message: CloudBoardAsyncXPCMessage>(
        _: Message.Type,
        handler: @Sendable @escaping (Message) async throws -> Message.Success
    ) where Message: ByteBufferCodable, Message.Reply: ByteBufferCodable {
        self.handlers[String(describing: Message.self)] = { encodedMessage in
            let message = try Signposter.signposter.withIntervalSignpost(
                "XPC handler decode",
                "bb \(Message.Type.self)"
            ) {
                var buffer = ByteBuffer(from: encodedMessage)
                return try Message(from: &buffer)
            }

            let reply: Message.Reply
            do {
                let result = try await handler(message)
                reply = .success(result)
            } catch let error as Message.Failure {
                reply = .failure(error)
            }

            let interval = Signposter.signposter.beginInterval(
                "XPC handler response encode",
                "bb \(Message.Reply.Type.self)"
            )
            var byteBuffer = ByteBuffer()
            try reply.encode(to: &byteBuffer)
            let encodedReply = byteBuffer.withUnsafeReadableBytes {
                xpc_data_create($0.baseAddress, $0.count)
            }
            Signposter.signposter.endInterval("XPC handler response encode", interval)
            return encodedReply
        }
    }

    /// Register posted message handler.
    package mutating func register<Message: CloudBoardAsyncXPCByteBufferMessage>(
        _: Message.Type,
        handler: @Sendable @escaping (Message) -> Void
    ) where Message.Success == Never, Message.Failure == Never {
        self.postedHandlers[String(describing: Message.self)] = { encodedMessage in
            let message = Signposter.signposter.withIntervalSignpost(
                "XPC handler decode",
                "bb \(Message.Type.self)"
            ) {
                var buffer = ByteBuffer(from: encodedMessage)
                return try? Message(from: &buffer)
            }

            guard let message else {
                Self.logger
                    .error("Dropping response that failed to deserialize as ByteBufferCodable \(Message.Type.self)")
                return
            }
            handler(message)
        }
    }
}
