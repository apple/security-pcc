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

import Dispatch
import XPC
import XPCPrivate

// MARK: - Abstract Initializer

internal func XPCConnectionCreate(
    connection: XPCConnection,
    object: XPCObject
) throws -> XPCConnection {
    if object.type == XPC_TYPE_CONNECTION {
        return XPCLocalConnection(object.rawValue)
    }
    throw CloudMetricsAsyncXPCError(connection: connection, object: object)
}

// MARK: - Protocol

internal protocol XPCConnection: CustomStringConvertible, Sendable {
    // MARK: Properties

    var events: AsyncStream<XPCObject> { get }
    var name: String { get }
    var endpoint: CloudMetricsAsyncXPCEndpoint? { get }
    var invalidationReason: String? { get }

    // MARK: Lifecycle

    func activate()
    func resume()
    func cancel()

    // MARK: Event Handling

    func setTargetQueue(_ queue: DispatchQueue?)
    func setEventHandler(_ handler: @escaping xpc_handler_t)

    // MARK: Message Sending

    func sendMessage(_ message: XPCDictionary)
    func sendMessageWithReply(
        _ message: XPCDictionary,
        _ queue: DispatchQueue?,
        _ handler: @escaping (XPCObject) -> Void
    )

    // MARK: Entitlement

    func hasEntitlement(_ entitlement: String) -> Bool
    func getEntitlementStringValue(_ entitlement: String) -> String?

}

// MARK: - Local Connection

internal struct XPCLocalConnection {
    internal var events: AsyncStream<XPCObject>
    internal let rawValue: xpc_connection_t

    internal init(_ connection: xpc_connection_t) {
        self.rawValue = connection
        self.events = AsyncStream { continuation in
            xpc_connection_set_event_handler(connection) { event in
                continuation.yield(XPCObject(rawValue: event))
            }
        }
    }
}

extension XPCLocalConnection {
    /// Connect to an endpoint.
    internal init(endpoint: CloudMetricsAsyncXPCEndpoint) {
        let connection = xpc_connection_create_from_endpoint(endpoint.rawValue)
        self.init(connection)
    }

    /// Connect to a mach service by name.
    internal init(machService: String) {
        let connection = xpc_connection_create_mach_service(machService, nil, 0)
        self.init(connection)
    }

    /// Start a mach service.
    internal static func listener(machService: String) -> XPCLocalConnection {
        let connection = xpc_connection_create_mach_service(
            machService, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        return self.init(connection)
    }

    /// Start an anonymous service.
    internal static func listener() -> XPCLocalConnection {
        let connection = xpc_connection_create(nil, nil)
        return self.init(connection)
    }
}

extension XPCLocalConnection: CustomStringConvertible {
    internal var description: String {
        "XPCLocalConnection(name: \"\(self.name)\")"
    }
}

extension XPCLocalConnection: @unchecked Sendable {}

extension XPCLocalConnection: XPCConnection {
    // MARK: Properties

    internal var name: String {
        let connectionName = if let nameCString = xpc_connection_get_name(self.rawValue) {
            String(cString: nameCString)
        } else {
            "anonymous"
        }
        let pid = xpc_connection_get_pid(self.rawValue)
        return "\(connectionName)(pid \(pid))"
    }

    internal var invalidationReason: String? {
        var ret: String?
        if let reason = xpc_connection_copy_invalidation_reason(self.rawValue) {
            ret = String(cString: reason)
            free(reason)
        }
        return ret
    }

    internal var endpoint: CloudMetricsAsyncXPCEndpoint? {
        CloudMetricsAsyncXPCEndpoint(connection: self)
    }

    // MARK: Lifecycle

    internal func activate() {
        xpc_connection_activate(self.rawValue)
    }

    internal func resume() {
        xpc_connection_resume(self.rawValue)
    }

    internal func cancel() {
        xpc_connection_cancel(self.rawValue)
    }

    // MARK: Event Handling

    internal func setTargetQueue(_ queue: DispatchQueue?) {
        xpc_connection_set_target_queue(self.rawValue, queue)
    }

    internal func setEventHandler(_ handler: @escaping xpc_handler_t) {
        xpc_connection_set_event_handler(self.rawValue, handler)
    }

    // MARK: Message Sending

    internal func sendMessage(_ message: XPCDictionary) {
        xpc_connection_send_message(self.rawValue, message._value)
    }

    internal func sendMessageWithReply(
        _ message: XPCDictionary,
        _ queue: DispatchQueue?,
        _ handler: @escaping (XPCObject) -> Void
    ) {
        xpc_connection_send_message_with_reply(
            self.rawValue,
            message._value,
            queue
        ) { object in
            handler(XPCObject(rawValue: object))
        }
    }

    // MARK: Entitlement

    internal func hasEntitlement(_ entitlement: String) -> Bool {
        guard let entitlement = xpc_connection_copy_entitlement_value(self.rawValue, entitlement) else {
            return false
        }
        return xpc_bool_get_value(entitlement)
    }

    internal func getEntitlementStringValue(_ entitlement: String) -> String? {
        guard let entitlement = xpc_connection_copy_entitlement_value(self.rawValue, entitlement) else {
            return nil
        }
        guard let unsafeStr = xpc_string_get_string_ptr(entitlement) else {
            return nil
        }
        return String(cString: unsafeStr)
    }
}
