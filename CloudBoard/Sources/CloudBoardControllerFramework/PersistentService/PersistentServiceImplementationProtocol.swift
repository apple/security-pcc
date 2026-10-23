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
internal import CloudBoardJobHelperAPI
internal import CloudBoardDomain
import Foundation
import os

// Kept at package level (not public) so it can change without ABI-compatibility concerns.
// This restriction can be relaxed once tooling moves to its own repo and targets.

/// Represents a tagged message from a client to a persistent service.
///
/// The framework parses the tag byte from the wire format and delivers a typed enum case.
/// Cloud apps send bare protobuf — the framework adds/strips the tag byte.
package enum PersistentServiceMessage: Sendable {
    case serviceSpecific(Data)
    case metadataQuery(Data)
}

/// Represents a tagged response from a persistent service back to the client.
package enum PersistentServiceResponseMessage: Sendable {
    case serviceSpecific(Data)
    case metadataUpdate(Data)
}

extension PersistentServiceMessage {
    /// Parse a raw wire-format message (tag byte + protobuf payload) into a typed enum case.
    package static func parse(_ data: Data) -> PersistentServiceMessage {
        guard let tag = data.first else {
            return .serviceSpecific(data)
        }
        let payload = Data(data.dropFirst())
        switch tag {
        case PersistentServiceStreamTag.serviceSpecific:
            return .serviceSpecific(payload)
        case PersistentServiceStreamTag.metadata:
            return .metadataQuery(payload)
        default:
            return .serviceSpecific(payload)
        }
    }
}

extension PersistentServiceResponseMessage {
    /// Serialize the response by prepending the tag byte to the payload.
    package func serialized() -> Data {
        switch self {
        case .serviceSpecific(let data):
            var out = Data([PersistentServiceStreamTag.serviceSpecific])
            out.append(data)
            return out
        case .metadataUpdate(let data):
            var out = Data([PersistentServiceStreamTag.metadata])
            out.append(data)
            return out
        }
    }
}

/// A protocol that any controller can adopt to handle messages from persistent service connections.
///
/// When `cb_pserverhelper` receives encrypted queries over a persistent connection, it performs OHTTP/HPKE
/// decryption and forwards the plaintext to the target controller via XPC. The framework parses the tag byte
/// and delivers a typed ``PersistentServiceMessage`` through ``handleMessage(_:isFinal:responder:)``.
/// Controllers send responses back through the provided ``PersistentServiceResponder``.
package protocol PersistentServiceImplementationProtocol: Sendable {
    /// Called when a message arrives from cb_pserverhelper (already OHTTP-decrypted, tag parsed).
    func handleMessage(
        _ message: PersistentServiceMessage,
        isFinal: Bool,
        responder: PersistentServiceResponder
    ) async throws
    /// Called when the persistent connection is torn down.
    func handleTeardown() async
}

/// Wraps an XPC connection to send plaintext response chunks back to cb_pserverhelper.
///
/// The helper will then OHTTP-encapsulate the response and forward it to cloudboardd.
package struct PersistentServiceResponder: Sendable {
    private let _sendResponse: @Sendable (Data, Bool) async throws -> Void

    init(connection: CloudBoardAsyncXPCConnection) {
        self._sendResponse = { data, isFinal in
            try await connection.post(PersistentPlaintextResponseChunk(data: data, isFinal: isFinal))
        }
    }

    /// Creates a responder backed by a custom send closure.
    /// This always remains package level even once the wider API is exposed
    package init(sendResponse: @escaping @Sendable (Data, Bool) async throws -> Void) {
        self._sendResponse = sendResponse
    }

    /// Send a typed response message back to cb_pserverhelper (serializes with tag byte).
    package func sendResponse(_ message: PersistentServiceResponseMessage, isFinal: Bool) async throws {
        try await self._sendResponse(message.serialized(), isFinal)
    }

    /// Convenience: send raw data as a `serviceSpecific` response.
    package func sendResponse(_ data: Data, isFinal: Bool) async throws {
        try await self.sendResponse(.serviceSpecific(data), isFinal: isFinal)
    }
}
