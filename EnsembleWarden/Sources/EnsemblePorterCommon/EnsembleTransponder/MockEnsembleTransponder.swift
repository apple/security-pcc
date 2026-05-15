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

//
//  MockEnsembleTransponder.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 21/09/2025.
//

private import CryptoKit
package import EnsemblePorterProtos
package import Foundation
package import InternalSwiftProtobuf
private import OSLog
private import Synchronization

/// Mocks out ensembled so that we can run tests and run on macOS
package final class MockEnsembleTransponder: EnsembleTransponder, Sendable {
    private let messages: [Data]
    private let continuations: Mutex<[AsyncThrowingStream<Data, Error>.Continuation]> = .init([])
    private let responses: [Int: Data]
    private let messageHandlers: Mutex<[String: @Sendable (Int, Data) -> Data]> = .init([:])

    /// Info about the current node we're executing on.
    package let nodeInfo: EnsembleNodeInfo
    /// Info about the peer nodes in the same ensemble
    package let peerInfo: [EnsemblePeerInfo]?
    /// Error that we should inject throw when an adopter tries to ``nodeInfo()``.
    package let nodeInfoError: (any Error)?
    /// Error that we should inject throw when an adopter tries to ``sendData(appID:data:destination:)``
    package let sendDataError: (any Error)?
    /// Which message type should trigger sendDataError
    package let sendDataErrorOnMessageType: Protos.PorterMessage.OneOf_MessageType?
    /// Optional delay to simulate slow network responses
    package let responseDelay: Duration?
    /// Captures a list of ``sendData(appID:data:destination:)`` calls that were made so we can assert about these in tests.
    private let _sendDataCalls = Mutex<[SendDataCall]>([])

    private let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "MockEnsembleTransponder")

    /// Data to store for each call to ``sendData(appID:data:destination:)``
    package struct SendDataCall: Sendable {
        package let appID: String
        package let data: Data
        package let destination: Int

        package init(appID: String, data: Data, destination: Int) {
            self.appID = appID
            self.data = data
            self.destination = destination
        }
    }

    /// Creates a new MockEnsembleTransponder
    /// - Parameters:
    ///   - messages: The messages to send to every new subscriber
    ///   - nodeInfo: Information about this node (default: leader, rank 0)
    ///   - peerInfo: Information about peer nodes (default: single peer at rank 1)
    ///   - responses: Responses to return for specific destinations (default: empty response)
    ///   - nodeInfoError: The error to throw when ``nodeInfo()`` is called.
    ///   - sendDataError: The error to throw when ``sendData(appID:data:destination:)`` is called.
    ///   - sendDataErrorOnMessageType: Which message type should trigger sendDataError. If sendDataError is set, this must also be set.
    ///   - responseDelay: Optional delay before returning responses to simulate slow network
    package init(
        messages: [Data] = [],
        nodeInfo: EnsembleNodeInfo = EnsembleNodeInfo(leader: true, rank: 0),
        peerInfo: [EnsemblePeerInfo]? = [],
        responses: [Int: Data] = [:],
        nodeInfoError: (any Error)? = nil,
        sendDataError: (any Error)? = nil,
        sendDataErrorOnMessageType: Protos.PorterMessage.OneOf_MessageType? = nil,
        responseDelay: Duration? = nil
    ) {
        self.messages = messages
        self.nodeInfo = nodeInfo
        self.peerInfo = peerInfo
        self.responses = responses
        self.nodeInfoError = nodeInfoError
        self.sendDataError = sendDataError
        self.sendDataErrorOnMessageType = sendDataErrorOnMessageType
        self.responseDelay = responseDelay
    }

    package var sendDataCalls: [SendDataCall] {
        _sendDataCalls.withLock { $0 }
    }

    package func registerMessageHandler(appID: String, handler: @escaping @Sendable (Int, Data) -> Data) throws {
        messageHandlers.withLock { handlers in
            handlers[appID] = handler
        }

        for message in self.messages {
            handler(0, message)
        }
    }

    package func nodeInfo() async throws -> EnsembleNodeInfo {
        if let error = nodeInfoError {
            throw error
        }
        return nodeInfo
    }

    package func peerInfo() async throws -> [EnsemblePeerInfo]? {
        peerInfo
    }

    package func sendData(appID: String, data: Data, destination: Int, timeout: TimeInterval) async throws -> Data {
        if let error = sendDataError, let errorMessageType = sendDataErrorOnMessageType {
            // Parse the incoming data as a PorterMessage to check its type
            if let porterMessage = try? Protos.PorterMessage(serializedData: data) {
                // Check if the message type matches the one we should fail on
                switch (errorMessageType, porterMessage.messageType) {
                case (.unspecified, .unspecified),
                     (.startNewProcess, .startNewProcess),
                     (.startNewProcessReply, .startNewProcessReply),
                     (.perProcessMessage, .perProcessMessage),
                     (.shutdown, .shutdown):
                    throw error
                default:
                    break
                }
            }
        }

        _sendDataCalls.withLock { calls in
            calls.append(SendDataCall(appID: appID, data: data, destination: destination))
        }

        logger.log("Sending data. destination=\(destination, privacy: .public)")

        // Apply delay if configured to simulate slow network
        if let delay = responseDelay {
            try await Task.sleep(for: delay)
        }

        // Invoke the registered message handler for this appID
        let handler = messageHandlers.withLock { $0[appID] }
        if let handler {
            return handler(nodeInfo.rank, data)
        }

        // Forward the data to all subscribers.
        // This ignores the destination that we're called from.
        // For testing + macOS dev work that's fine.
        continuations.withLock { continuations in
            for continuation in continuations {
                continuation.yield(data)
            }
        }

        return responses[destination] ?? Data()
    }

    package func run() async throws {
        try await withTaskCancellationHandler(operation: {
            while true {
                try await Task.sleep(for: .seconds(60*60))
            }
        }, onCancel: {
            self.logger.log("MockEnsembleTransponder shutdown")
            self.continuations.withLock { continuations in
                for continuation in continuations {
                    continuation.finish()
                }
            }
        })
    }
}
