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

package protocol CloudMetricsAsyncXPCListenerDelegate: Actor {
    func clientConnected(_ connection: CloudMetricsAsyncXPCConnection) async
    func clientDisconnected(_ connection: CloudMetricsAsyncXPCConnection) async
}

package actor CloudMetricsAsyncXPCListener {
    private typealias XPCResult = Result<XPCConnection, CloudMetricsAsyncXPCError>

    private let name: String
    private var listener: XPCConnection
    private let auth: XPCConnectionAuthorization
    private var connections: [CloudMetricsAsyncXPCConnection.ID: CloudMetricsAsyncXPCConnection]
    private var logger: Logger
    private var listenerQueue: DispatchQueue
    private var nonPostedMessageHandlers: [String: CloudMetricsAsyncXPCConnection.XPCNonPostedMessageHandler]
    private weak var delegate: CloudMetricsAsyncXPCListenerDelegate?

    package var endpoint: CloudMetricsAsyncXPCEndpoint? {
        self.listener.endpoint
    }

    package var connectionCount: Int {
        self.connections.count
    }

    /// Initialize an anonymous local listener
    package init() {
        self.init(localService: nil, entitlement: nil)
    }

    /// Initialize xpc listener with an optional mach service name and an
    /// entitlement to check.
    ///
    /// - Parameters:
    /// - localService: mach xpc service name, when nil, an anonymous listener is created.
    /// Anonymous listener can be created within a regular process (does not require launchd), thus is suitable for
    /// unit-testing.
    /// CloudMetricsAsyncXPCEndpoint can be used to establish a connection to an anonymous listener.
    /// - entitlement: entitlement to check an incoming connection for, when nil, all connections are allowed.
    package init(localService name: String?, entitlement: String?) {
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

        self.init(connection: connection, entitlement: entitlement)
    }

    package func set(delegate: CloudMetricsAsyncXPCListenerDelegate?) async {
        self.delegate = delegate
    }

    internal init(connection: XPCConnection, entitlement: String?) {
        self.logger = Logger(subsystem: "com.apple.CloudMetricsAsyncXPC", category: "CloudMetricsXPCListener")
        self.connections = [:]
        self.nonPostedMessageHandlers = [:]
        self.listener = connection
        self.name = connection.name
        self.listenerQueue = DispatchQueue(label: "com.apple.CloudMetricsAsyncXPC.CloudMetricsXPCListener.queue")
        self.listener.setTargetQueue(self.listenerQueue)

        if let entitlement {
            self.auth = XPCConnectionEntitlementAuthorization(
                entitlement: entitlement
            )
        } else {
            self.auth = XPCConnectionPassthroughAuthorization()
        }
    }

    private func invalidateConnection(_ connection: CloudMetricsAsyncXPCConnection) async {
        self.connections.removeValue(forKey: connection.id)
        await self.delegate?.clientDisconnected(connection)
    }

    private func handleNewConnection(connection: XPCConnection) async {
        guard self.auth.isAuthorized(connection: connection) else {
            connection.cancel()
            return
        }

        let authorizedConnection = CloudMetricsAsyncXPCConnection(connection)
        await self.delegate?.clientConnected(authorizedConnection)

        /// Here we now have created a connection to the client
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
        await authorizedConnection.activate(
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
        } catch CloudMetricsAsyncXPCError.terminationImminent {
            self.logger.log("""
            Listener termination is imminent. \
            connection_name=\(self.name, privacy: .public)
            """)
            self.listener.cancel()
        } catch CloudMetricsAsyncXPCError.connectionInterrupted {
            self.logger.log("""
            Listener has been interrupted. \
            connection_name=\(self.name, privacy: .public)
            """)
            self.listener.cancel()
        } catch CloudMetricsAsyncXPCError.connectionInvalid(let reason) {
            self.logger.log("""
            Listener has been invalidated. \
            connection_name=\(self.name, privacy: .public) \
            reason=\(reason ?? "", privacy: .public)
            """)
            return true
        } catch {
            self.logger.error("""
            Listener error. \
            connection_name=\(self.name, privacy: .public) \
            error=\(error, privacy: .public)
            """)
            self.listener.cancel()
        }

        return false
    }

    /// Register message handlers and start listening for incoming connections and xpc events
    @discardableResult
    package func listen(buildMessageHandlerStore: (inout CloudMetricsAsyncXPCConnection.MessageHandlerStore) -> Void)
    -> Self {
        var store = CloudMetricsAsyncXPCConnection.MessageHandlerStore()
        buildMessageHandlerStore(&store)

        self.listen(messageHandlers: store.handlers)
        return self
    }

    @discardableResult
    package func listen(messageHandlerStore: CloudMetricsAsyncXPCConnection.MessageHandlerStore) -> Self {
        self.listen(
            messageHandlers: messageHandlerStore.handlers
        )
        return self
    }

    @discardableResult
    internal func listen(
        messageHandlers: [String: CloudMetricsAsyncXPCConnection.XPCNonPostedMessageHandler]
    ) -> Self {
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

        return self
    }

    /// Stop listening for xpc events and close all open connections
    package func cancel() async {
        self.listener.cancel()
        for (_, connection) in self.connections {
            await connection.cancel()
        }
        self.connections = [:]
    }

    /// Send a message with no reply to all open connections
    package func broadcast(
        _ message: some CloudMetricsAsyncXPCMessage,
        requiringEntitlement: String? = nil
    ) async throws {
        await withThrowingTaskGroup(of: Void.self) { group in
            for (_, connection) in self.connections {
                if let requiringEntitlement,
                   await !connection.hasEntitlement(requiringEntitlement) {
                    continue
                }
                group.addTask {
                    try await connection.send(message)
                }
            }
        }
    }

    deinit {
        self.listener.cancel()
        self.connections = [:]
    }
}
