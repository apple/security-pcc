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

import CloudBoardLogging
import InternalGRPC
import InternalSwiftProtobuf
import os
import Synchronization

final class InvokeWorkloadStreamState: Sendable, CustomStringConvertible {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "InvokeWorkloadStreamState"
    )

    private let state: Mutex<State>
    private let isProxy: Bool

    var description: String {
        return "\(self.state.withLock { $0 })"
    }

    init(isProxy: Bool) {
        self.isProxy = isProxy
        self.state = .init(.awaitingSetup)
    }

    func receiveMessage(_ message: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest) throws {
        switch message.type {
        case .setup:
            try self.receiveSetup()
        case .parameters(let parameters):
            try self.receiveParameters(requestBypass: parameters.requestBypassed, nackRequest: parameters.requestNack)
        case .requestChunk(let chunk):
            try self.receiveChunk(isFinal: chunk.isFinal)
        case .terminate:
            try self.receiveTerminationNotification()
        case .none:
            ()
        }
    }

    func receiveEOF() throws {
        try self.state.withLock { try $0.receivedEOF() }
    }

    private func receiveSetup() throws {
        try self.state.withLock { try $0.receiveSetup() }
    }

    private func receiveParameters(requestBypass: Bool, nackRequest: Bool) throws {
        try self.state.withLock { try $0.receiveParameters(requestBypass: requestBypass, nackRequest: nackRequest) }
    }

    private func receiveChunk(isFinal: Bool) throws {
        try self.state.withLock {
            try $0.receiveChunk()
            if isFinal {
                try $0.receiveFinalChunk()
            }
        }
    }

    private func receiveTerminationNotification() throws {
        try self.state.withLock { try $0.receiveTerminationNotification() }
    }
}

extension InvokeWorkloadStreamState {
    private enum State: CustomStringConvertible {
        case awaitingSetup
        case awaitingParameters
        /// this may or may not have actually received them yet
        case receivingChunks
        case receivedFinalChunk
        case receivedTerminationNotification
        /// Even with request bypass, ROPES duplicates the auth token request chunk and sends it to the proxy
        case requestBypassAwaitingAuthToken
        /// Due to request bypass we aren't expecting anything else after receiving the auth token except termination
        case requestBypass

        var description: String {
            switch self {
            case .awaitingSetup: "awaiting setup"
            case .awaitingParameters: "awaiting parameters"
            case .receivingChunks: "receiving chunks"
            case .receivedFinalChunk: "received final chunk"
            case .receivedTerminationNotification: "received termination notification"
            case .requestBypassAwaitingAuthToken: "request bypass awaiting auth token"
            case .requestBypass: "request bypass"
            }
        }

        mutating func receiveSetup() throws {
            switch self {
            case .awaitingSetup:
                self = .awaitingParameters
            case .awaitingParameters, .receivingChunks, .receivedFinalChunk, .requestBypassAwaitingAuthToken,
                 .requestBypass:
                throw Error.receivedDuplicateSetup
            case .receivedTerminationNotification:
                throw Error.receivedSetupAfterTermination
            }
        }

        mutating func receiveParameters(requestBypass: Bool, nackRequest: Bool) throws {
            switch self {
            case .awaitingParameters:
                if requestBypass {
                    if nackRequest {
                        // If a NACK is requested, ROPES does not send an auth token and CloudBoard is expected to
                        // directly send the NACK and complete the request
                        self = .requestBypass
                    } else {
                        self = .requestBypassAwaitingAuthToken
                    }
                } else {
                    self = .receivingChunks
                }
            case .awaitingSetup:
                throw Error.receivedParametersBeforeSetup
            case .receivingChunks, .receivedFinalChunk, .requestBypassAwaitingAuthToken, .requestBypass:
                throw Error.receivedDuplicateParameters
            case .receivedTerminationNotification:
                throw Error.receivedParametersAfterTermination
            }
        }

        mutating func receiveChunk() throws {
            switch self {
            case .awaitingSetup:
                throw Error.receivedChunkBeforeSetup
            case .awaitingParameters:
                throw Error.receivedChunkBeforeParameters
            case .requestBypassAwaitingAuthToken:
                self = .requestBypass
            case .requestBypass:
                throw Error.receivedChunkUnderRequestBypass
            case .receivedFinalChunk:
                throw Error.receivedChunkAfterFinal
            case .receivingChunks:
                self = .receivingChunks
            case .receivedTerminationNotification:
                throw Error.receivedParametersAfterTermination
            }
        }

        mutating func receiveFinalChunk() throws {
            switch self {
            case .awaitingSetup:
                throw Error.receivedChunkBeforeSetup
            case .awaitingParameters:
                throw Error.receivedChunkBeforeParameters
            case .requestBypassAwaitingAuthToken, .requestBypass:
                // The auth token can never be the final chunk so this is always unexpected
                throw Error.receivedChunkUnderRequestBypass
            case .receivedFinalChunk:
                throw Error.receivedDuplicateFinalChunk
            case .receivingChunks:
                self = .receivedFinalChunk
            case .receivedTerminationNotification:
                throw Error.receivedFinalChunkAfterTermination
            }
        }

        mutating func receiveTerminationNotification() throws {
            switch self {
            case .awaitingSetup:
                throw Error.receivedTerminationBeforeSetup
            case .awaitingParameters, .receivingChunks, .receivedFinalChunk, .requestBypassAwaitingAuthToken,
                 .requestBypass:
                // Expected e.g. for candidate nodes that have not been chosen to handle the request and might be used
                // to signal other reasons for termination in the future
                // Note that currently ROPES does *not* send a terminate message for requestBypass, but
                // there's nothing stopping ROPES sending it and it would be a reasonable state transition
                self = .receivedTerminationNotification
            case .receivedTerminationNotification:
                throw Error.receivedDuplicateTermination
            }
        }

        func receivedEOF() throws {
            switch self {
            case .receivedFinalChunk:
                InvokeWorkloadStreamState.logger.debug("EOF after receivedFinalChunk - clean termination")
                // Expected
                ()
            case .requestBypass:
                InvokeWorkloadStreamState.logger.debug("EOF under requestBypass - clean termination")
                // Expected
                ()
            case .receivedTerminationNotification:
                // Expected for candidate node requests if node has not been chosen
                InvokeWorkloadStreamState.logger
                    .debug("EOF after receivedTerminationNotification - clean(ish) aborted RPC")
                throw Error.rpcAborted
            case .awaitingSetup, .awaitingParameters, .receivingChunks, .requestBypassAwaitingAuthToken:
                InvokeWorkloadStreamState.logger
                    .warning("EOF in state \(String(describing: self), privacy: .public) - treating as a failure")
                throw Error.unexpectedEndOfStream
            }
        }
    }
}

extension InvokeWorkloadStreamState {
    enum Error: Swift.Error {
        case receivedDuplicateSetup
        case receivedParametersBeforeSetup
        case receivedDuplicateParameters
        case receivedChunkBeforeSetup
        case receivedChunkBeforeParameters
        case receivedChunkAfterFinal
        case receivedChunkAfterTermination
        case receivedChunkUnderRequestBypass
        case receivedDuplicateFinalChunk
        case receivedParametersAfterTermination
        case receivedFinalChunkAfterTermination
        case receivedSetupAfterTermination
        case receivedTerminationBeforeSetup
        case receivedDuplicateTermination
        case rpcAborted
        case unexpectedEndOfStream
        case receivedRequestBypassNotification
    }
}

extension InvokeWorkloadStreamState.Error: ReportableError {
    var publicDescription: String {
        switch self {
        case .receivedDuplicateSetup:
            return "InvokeWorkloadStreamStateError.receivedDuplicateSetup"
        case .receivedParametersBeforeSetup:
            return "InvokeWorkloadStreamStateError.receivedParametersBeforeSetup"
        case .receivedDuplicateParameters:
            return "InvokeWorkloadStreamStateError.receivedDuplicateParameters"
        case .receivedChunkBeforeSetup:
            return "InvokeWorkloadStreamStateError.receivedChunkBeforeSetup"
        case .receivedChunkBeforeParameters:
            return "InvokeWorkloadStreamStateError.receivedChunkBeforeParameters"
        case .receivedChunkAfterFinal:
            return "InvokeWorkloadStreamStateError.receivedChunkAfterFinal"
        case .receivedChunkAfterTermination:
            return "InvokeWorkloadStreamStateError.receivedChunkAfterTermination"
        case .receivedChunkUnderRequestBypass:
            return "InvokeWorkloadStreamStateError.receivedChunkUnderRequestBypass"
        case .receivedDuplicateFinalChunk:
            return "InvokeWorkloadStreamStateError.receivedDuplicateFinalChunk"
        case .receivedParametersAfterTermination:
            return "InvokeWorkloadStreamStateError.receivedParametersAfterTermination"
        case .receivedFinalChunkAfterTermination:
            return "InvokeWorkloadStreamStateError.receivedFinalChunkAfterTermination"
        case .receivedSetupAfterTermination:
            return "InvokeWorkloadStreamStateError.receivedSetupAfterTermination"
        case .receivedTerminationBeforeSetup:
            return "InvokeWorkloadStreamStateError.receivedTerminationBeforeSetup"
        case .receivedDuplicateTermination:
            return "InvokeWorkloadStreamStateError.receivedDuplicateTermination"
        case .rpcAborted:
            return "InvokeWorkloadStreamStateError.rpcAborted"
        case .unexpectedEndOfStream:
            return "InvokeWorkloadStreamStateError.unexpectedEndOfStream"
        case .receivedRequestBypassNotification:
            return "InvokeWorkloadStreamStateError.receivedRequestBypassNotification"
        }
    }
}
