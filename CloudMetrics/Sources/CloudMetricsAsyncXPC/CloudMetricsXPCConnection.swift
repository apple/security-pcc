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

//  Copyright © 2023 Apple Inc. All rights reserved.

import Foundation
import OSLog
import XPC
import XPCPrivate

// MARK: - Actor

/// Represents an authorized bi-directional xpc connection established by a remote client to the XPC service:
package actor CloudMetricsAsyncXPCConnection: Identifiable {
    private typealias XPCResult = Result<XPCDictionary, CloudMetricsAsyncXPCError>
    package typealias ConnectionEventHandler = @Sendable (CloudMetricsAsyncXPCConnection) async -> Void

    package nonisolated let name: String
    private var logger: Logger
    private var connection: XPCConnection
    private var connectionQueue: DispatchQueue
    private var nonPostedMessageHandlers: [String: XPCNonPostedMessageHandler]

    private var onConnectionInvalidated: ConnectionEventHandler?
    private var onConnectionInterrupted: ConnectionEventHandler?
    private var onConnectionTerminationImminent: ConnectionEventHandler?

    internal init(_ connection: XPCConnection) {
        self.connection = connection
        self.connectionQueue = DispatchQueue(label: "com.apple.CloudMetricsAsyncXPC.CloudMetricsXPCConnection.queue")
        self.nonPostedMessageHandlers = [:]
        self.logger = Logger(subsystem: "com.apple.CloudMetricsAsyncXPC", category: "CloudMetricsXPCConnection")
        self.name = connection.name
        self.connection.setTargetQueue(self.connectionQueue)
    }

    package func getEntitlementStringValue(_ entitlement: String) -> String? {
        connection.getEntitlementStringValue(entitlement)
    }

    private func handleMessage(message: XPCDictionary) {
        guard let type: String = message[kMessageTypeKey] else {
            self.logger.error("Could not get type for message. connection_name=\(self.name, privacy: .public)")
            return
        }

        self.logger.trace("""
                          Handle message. \
                          message_type=\(type, privacy: .public) \
                          connection_name=\(self.name, privacy: .public)
                          """)
        let logger = self.logger
        if let handler = self.nonPostedMessageHandlers[type] {
            Task.detached(priority: Task.currentPriority) { [weak self, message, logger] in
                guard let self else { return }
                defer { withExtendedLifetime(self) {} }

                guard let encodedMessage: xpc_object_t = message[kMessageBodyKey] else {
                    return
                }

                guard var replyDict = message.createReply() else {
                    return
                }

                do {
                    try await CloudMetricsAsyncXPCContext.$context.withValue(.init(peerConnection: self)) {
                        let encodedReply = try await handler(encodedMessage)
                        replyDict[kMessageBodyKey] = encodedReply
                    }
                } catch {
                    logger
                        .error("""
                            Failed to handle message with reply. \
                            message_type=\(type, privacy: .public) \
                            error=\(error, privacy: .public)
                            """)
                    replyDict[kMessageRemoteProcessErrorKey] = String(describing: error)
                    replyDict.removeValue(forKey: kMessageBodyKey)
                }

                replyDict.sendReply()
            }
        } else {
            self.logger.error("""
                Unexpected message from  connection, canceling connection. \
                connection_name=\(self.name, privacy: .public) \
                type=\(type, privacy: .public)
                """)
            self.cancel()
        }
    }

    /// Extract return value for a specific message type from an xpc reply message
    private func getReply<Message: CloudMetricsAsyncXPCMessage>(object: XPCObject, from _: Message.Type) throws -> Message
    .Success {
        let dict = try XPCDictionary(connection: self.connection, object: object)
        guard let encodedReply: xpc_object_t = dict[kMessageBodyKey] else {
            guard let unexpectedError: String = dict[kMessageRemoteProcessErrorKey] else {
                throw CloudMetricsAsyncXPCError.corruptedReply
            }

            throw CloudMetricsAsyncXPCError.remoteProcessError(
                unexpectedError,
                connectionName: self.connection.name
            )
        }

        let decoder = XPCObjectDecoder()
        let reply = try decoder.decode(Message.Reply.self, from: encodedReply)
        return try reply.get()
    }

    /// All libxpc events are tunneled thru this method and dispatched to appropriate handlers
    private func handleXPCEvent(object: XPCObject) async -> Bool {
        do {
            let message = try XPCDictionary(
                connection: self.connection,
                object: object
            )
            self.handleMessage(message: message)
        } catch CloudMetricsAsyncXPCError.terminationImminent {
            self.logger.log("Connection termination is imminent. connection_name=\(self.name, privacy: .public)")
            await self.onConnectionTerminationImminent?(self)
            self.connection.cancel()
        } catch CloudMetricsAsyncXPCError.connectionInterrupted {
            self.logger.log("Connection has been interrupted. connection_name=\(self.name, privacy: .public)")
            await self.onConnectionInterrupted?(self)
            self.connection.cancel()
        } catch CloudMetricsAsyncXPCError.connectionInvalid(let reason) {
            self.logger.log("""
                Connection has been invalidated. \
                connection_name=\(self.name, privacy: .public) \
                reason=\(reason ?? "", privacy: .public)
                """)
            await self.onConnectionInvalidated?(self)
            return true
        } catch {
            self.logger.error("""
                Connection error. \
                connection_name=\(self.name, privacy: .public) \
                error=\(error, privacy: .public)
                """)
            self.connection.cancel()
        }

        return false
    }

    /// XPC connections start in a suspended state and require activation. Activate the connection without any message
    /// handlers.
    @discardableResult
    package func activate() -> Self {
        self.activate(messageHandlers: [:])
        return self
    }

    /// XPC connections start in a suspended state and require activation. Activate the connection and register message
    /// handlers.
    @discardableResult
    package func activate(buildMessageHandlerStore: (inout MessageHandlerStore) -> Void) -> Self {
        var store = CloudMetricsAsyncXPCConnection.MessageHandlerStore()
        buildMessageHandlerStore(&store)
        self.activate(messageHandlers: store.handlers)
        return self
    }

    @discardableResult
    internal func activate(
        messageHandlers: [String: XPCNonPostedMessageHandler]
    ) -> Self {
        self.nonPostedMessageHandlers = messageHandlers

        // NOTE: We should pass a weak reference to self,
        // however, libswift_Concurrency when ran only in combination with XCTest
        // either over-releases async context or it gets corrupted, therefore
        // libswift_Concurrency hits a bad access exception in swift_task_switchImpl.
        //
        // To keep unit tests in place, lets pass a strong reference to self here. In practice,
        // client code will call cancel to terminate the connection and thus break
        // the strong reference.
        Task {
            for await object in self.connection.events where await self.handleXPCEvent(object: object) {
                return
            }
        }

        self.connection.resume()

        return self
    }

    /// Cancel and close xpc connection
    package func cancel() {
        self.connection.cancel()
    }

    // Checks if peer has the provided entitlement
    package func hasEntitlement(_ entitlement: String) -> Bool {
        return self.connection.hasEntitlement(entitlement)
    }

    /// Send a non-posted message with response data.
    @discardableResult
    package func send<Message>(_ message: Message) async throws -> Message.Success
    where Message: CloudMetricsAsyncXPCMessage {
        try await self._send(message)
    }

    /// Send a non-posted message without response data.
    package func send<Message>(_ message: Message) async throws
    where Message: CloudMetricsAsyncXPCMessage, Message.Success == ExplicitSuccess {
        _ = try await self._send(message)
    }

    private func _send<Message: CloudMetricsAsyncXPCMessage>(_ message: Message) async throws -> Message.Success {
        let encoder = XPCObjectEncoder()
        let encodedMessage = try encoder.encode(message)

        var dict = XPCDictionary()
        dict[kMessageTypeKey] = String(describing: Message.self)
        dict[kMessageBodyKey] = encodedMessage

        return try await withCheckedThrowingContinuation { continuation in
            let replyLock = NSLock()
            self.connection.sendMessageWithReply(dict, self.connectionQueue) { object in
                do {
                    // NSLock life-time is limited to individual send method call,
                    // thus the lock in never unlocked once it's locked. It's a replacement for
                    // swift-atomics boolean that used to be here.
                    if replyLock.try() {
                        let result = try self.getReply(object: object, from: Message.self)
                        continuation.resume(returning: result)
                    } else {
                        self.logger.error("Dropping unexpected reply. connection_name=\(self.name, privacy: .public)")
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Send a posted message.
    package func send<Message: CloudMetricsAsyncXPCMessage>(_ message: Message) throws where Message.Success == Never,
    Message.Failure == Never {
        let encoder = XPCObjectEncoder()
        let encodedMessage = try encoder.encode(message)

        var dict = XPCDictionary()
        dict[kMessageTypeKey] = String(describing: Message.self)
        dict[kMessageBodyKey] = encodedMessage
        self.connection.sendMessage(dict)
    }

    @discardableResult
    package func handleConnectionInvalidated(handler: ConnectionEventHandler?) -> Self {
        self.onConnectionInvalidated = handler
        return self
    }

    @discardableResult
    package func handleConnectionInterrupted(handler: ConnectionEventHandler?) -> Self {
        self.onConnectionInterrupted = handler
        return self
    }

    @discardableResult
    package func handleConnectionTerminationImminent(handler: ConnectionEventHandler?) -> Self {
        self.onConnectionTerminationImminent = handler
        return self
    }

    deinit {
        self.connection.cancel()
    }
}

// MARK: - Message handlers

extension CloudMetricsAsyncXPCConnection {
    internal typealias XPCNonPostedMessageHandler = @Sendable (xpc_object_t) async throws -> xpc_object_t

    package struct MessageHandlerStore: Sendable {
        internal private(set) var handlers: [String: XPCNonPostedMessageHandler]

        package init() {
            self.handlers = [:]
        }

        package mutating func register<Message: CloudMetricsAsyncXPCMessage>(
            _: Message.Type,
            handler: @Sendable @escaping (Message) async throws -> Message.Success
        ) {
            self.handlers[String(describing: Message.self)] = { encodedMessage in
                let decoder = XPCObjectDecoder()
                let message = try decoder.decode(Message.self, from: encodedMessage)

                let reply: Message.Reply
                do {
                    let result = try await handler(message)
                    reply = .success(result)
                } catch let error as Message.Failure {
                    reply = .failure(error)
                }

                let encoder = XPCObjectEncoder()
                let encodedReply = try encoder.encode(reply)
                return encodedReply
            }
        }
    }
}

// MARK: - Static methods

extension CloudMetricsAsyncXPCConnection {
    /// Connect to a machService by name
    package static func connect(to machService: String) async -> CloudMetricsAsyncXPCConnection {
        let connection = XPCLocalConnection(xpc_connection_create_mach_service(machService, nil, 0))
        return CloudMetricsAsyncXPCConnection(connection)
    }

    /// Connect to a machService by name of a specific UUID (for multi-instance services)
    package static func connect(to machService: String, withUUID uuid: UUID) async -> CloudMetricsAsyncXPCConnection {
        let xpcConnection = xpc_connection_create_mach_service(machService, nil, 0)
        // xpc_connection_set_oneshot_instance() copies the uuid passed in here
        var instanceUUID = uuid
        withUnsafeMutablePointer(to: &instanceUUID) { id in
            xpc_connection_set_oneshot_instance(xpcConnection, id)
        }

        let connection = XPCLocalConnection(xpcConnection)
        return CloudMetricsAsyncXPCConnection(connection)
    }

    /// Connect to an endpoint
    package static func connect(to endpoint: CloudMetricsAsyncXPCEndpoint) async -> CloudMetricsAsyncXPCConnection {
        let connection = XPCLocalConnection(endpoint: endpoint)
        return CloudMetricsAsyncXPCConnection(connection)
    }
}
