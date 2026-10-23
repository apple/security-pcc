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

import CloudBoardLogging
import XPC
import XPCPrivate

public enum CloudBoardAsyncXPCError: ReportableError {
    /// Will be delivered to the connection’s event handler if the remote
    /// service exited. The connection is still live even in this case, and
    /// resending a message will cause the service to be launched on-demand.
    /// This error serves as a client’s indication that it should resynchronize
    /// any state that it had given the service. Any messages in the queue to be
    /// sent will be unwound and canceled when this error occurs. In the case
    /// where a message waiting to be sent has a reply handler, that handler
    /// will be invoked with this error. In the context of the reply handler,
    /// this error indicates that a reply to the message will never arrive.
    /// Messages that do not have reply handlers associated with them will be
    /// silently disposed of.
    ///
    /// This error will only be given to peer connections.
    ///
    /// Originally named: `XPC_ERROR_CONNECTION_INTERRUPTED`.
    case connectionInterrupted

    /// Will be delivered to the connection’s event handler if the named
    /// service provided to xpc_connection_create(_:_:) could not be
    /// found in the XPC service namespace. The connection is useless
    /// and should be disposed of. Any messages in the queue to be sent
    /// will be unwound and canceled when this error occurs, similarly
    /// to the behavior when XPC_ERROR_CONNECTION_INTERRUPTED occurs.
    /// The only difference is that the XPC_ERROR_CONNECTION_INVALID
    /// will be given to outstanding reply handlers and the
    /// connection’s event handler.
    ///
    /// This error may be given to any type of connection.
    ///
    /// Originally named: `XPC_ERROR_CONNECTION_INVALID`.
    case connectionInvalid(String?)

    /// This error will be delivered to a peer connection’s event
    /// handler when the XPC runtime has determined that the program
    /// should exit and that all outstanding transactions must be wound
    /// down, and no new transactions can be opened. After this error
    /// has been delivered to the event handler, no more messages will
    /// be received by the connection. The runtime will still attempt
    /// to deliver outgoing messages, but this error should be treated
    /// as an indication that the program will exit very soon, and any
    /// outstanding business over the connection should be wrapped up
    /// as quickly as possible and the connection canceled shortly
    /// thereafter.
    ///
    /// This error will only be delivered to peer connections received
    /// through a listener or the `xpc_main(_:)` event handler.
    ///
    /// Originally named: `XPC_ERROR_TERMINATION_IMMINENT`.
    case terminationImminent

    case unexpectedObjectType(String)
    case corruptedReply
    case remoteProcessError(String?, connectionName: String)

    case noConnection
    case missingEntitlement

    internal init(connection: XPCConnection, object: XPCObject) {
        guard object.type == XPC_TYPE_ERROR else {
            self = .unexpectedObjectType("\(object.type)")
            return
        }

        if xpc_equal(object.rawValue, XPC_ERROR_CONNECTION_INVALID) {
            self = .connectionInvalid(connection.invalidationReason)
        } else if xpc_equal(object.rawValue, XPC_ERROR_CONNECTION_INTERRUPTED) {
            self = .connectionInterrupted
        } else if xpc_equal(object.rawValue, XPC_ERROR_TERMINATION_IMMINENT) {
            self = .terminationImminent
        } else {
            self = .remoteProcessError(nil, connectionName: connection.name)
        }
    }

    public var publicDescription: String {
        switch self {
        case .connectionInterrupted:
            return "ConnectionInterrupted"
        case .connectionInvalid:
            return "ConnectionInvalid"
        case .terminationImminent:
            return "TerminationImminent"
        case .unexpectedObjectType:
            return "UnexpectedObjectType"
        case .corruptedReply:
            return "CorruptedReply"
        case .remoteProcessError:
            return "RemoteProcessError"
        case .noConnection:
            return "NoConnection"
        case .missingEntitlement:
            return "MissingEntitlement"
        @unknown default:
            return "UndefinedError"
        }
    }
}

extension CloudBoardAsyncXPCError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connectionInterrupted:
            return "Connection interrupted."
        case .connectionInvalid(let reason):
            if let reason {
                return "Connection invalid: \(reason)."
            } else {
                return "Connection invalid."
            }
        case .terminationImminent:
            return "Termination imminent."
        case .unexpectedObjectType(let type):
            return "Unexpected object type: \(type)."
        case .corruptedReply:
            return "Corrupted reply."
        case .remoteProcessError(let reason, let connectionName):
            if let reason {
                return "Remote process error on \(connectionName): \(reason)"
            } else {
                return "Remote process error on \(connectionName)."
            }
        case .noConnection:
            return "No connection."
        case .missingEntitlement:
            return "Peer is missing required entitlement."
        }
    }
}
