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

import CloudBoardProtos
import Logging
import NIOCore
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum CloudAppStateMachineState: Sendable {
    enum Identifier: Equatable {
        case processLaunched
        case cloudBoardRPCStarted
        case warmupStarted
        case warmupCompleted
        case connectionContextReceived
        case requestStarted
        case cloudAppServiceExecutionCompleted
        case cloudAppRunCompleted
        case shuttingDownEarlyDueCloudBoardRPCError
        case shuttingDownEarlyDueTermination

        var label: StaticString {
            switch self {
            case .processLaunched: "processLaunched"
            case .cloudBoardRPCStarted: "cloudBoardRPCStarted"
            case .warmupStarted: "warmupStarted"
            case .warmupCompleted: "warmupCompleted"
            case .connectionContextReceived: "connectionContextReceived"
            case .requestStarted: "requestStarted"
            case .cloudAppServiceExecutionCompleted: "cloudAppServiceExecutionCompleted"
            case .cloudAppRunCompleted: "cloudAppRunCompleted"
            case .shuttingDownEarlyDueCloudBoardRPCError: "shuttingDownEarlyDueCloudBoardRPCError"
            case .shuttingDownEarlyDueTermination: "shuttingDownEarlyDueTermination"
            }
        }
    }

    case processLaunched
    case cloudBoardRPCStarted
    case warmupStarted
    case warmupCompleted(any CloudAppService)
    case connectionContextReceived(any CloudAppService, ConnectionContext)
    case requestStarted(CloudAppSubRequestID)
    case cloudAppServiceExecutionCompleted
    case cloudAppRunCompleted

    // Dedicated error state, if we get unexpected cb RPC (out of order, or otherwise corrupt), got a transport failure,
    // or premature end of stream
    case shuttingDownEarlyDueCloudBoardRPCError(any Error)

    // Early shutdown requested via termination signal. Unlike the error state above, this is an expected, clean
    // wind-down: no error is reported back to CloudBoard.
    case shuttingDownEarlyDueTermination(reason: String)

    var identifier: Identifier {
        switch self {
        case .processLaunched: .processLaunched
        case .cloudBoardRPCStarted: .cloudBoardRPCStarted
        case .warmupStarted: .warmupStarted
        case .warmupCompleted: .warmupCompleted
        case .connectionContextReceived: .connectionContextReceived
        case .requestStarted: .requestStarted
        case .cloudAppServiceExecutionCompleted: .cloudAppServiceExecutionCompleted
        case .cloudAppRunCompleted: .cloudAppRunCompleted
        case .shuttingDownEarlyDueCloudBoardRPCError: .shuttingDownEarlyDueCloudBoardRPCError
        case .shuttingDownEarlyDueTermination: .shuttingDownEarlyDueTermination
        }
    }
}

package enum CloudAppStateMachineAction {
    case handleCloudBoardRPCStarting(CloudBoardRPCChannel)
    case notifyCloudBoardThatWarmupCompleted
    case runCloudApp(WarmupContext)
    case terminateCloudApp(possibleError: (any Error)?)
    case startRequest(
        subRequestID: CloudAppSubRequestID,
        service: any CloudAppService,
        connectionContext: ConnectionContext,
        subRequestContext: RPCSubRequestContext,
    )
    case yieldRequestInput(subRequestID: CloudAppSubRequestID, data: Data)
    case finishRequestInput(subRequestID: CloudAppSubRequestID)
    case yieldRequestOutput(subRequestID: CloudAppSubRequestID, data: Data)
    case finishRequestOutputAndTerminateCloudAppService(
        subRequestID: CloudAppSubRequestID,
        possibleError: (any Error)?
    )
    case resolveKeyDerivation(derivationID: UInt64, result: KeyDerivationCoordinator.Result)
    case exit(status: CloudAppExitStatus)

    case doNothing
    case rejectSecondaryCloudBoardRPC

    package enum CloudAppServiceRejectionReason {
        case cloudBoardRPCError
        case secondaryExecution
    }
    case rejectCloudAppService(reason: CloudAppServiceRejectionReason)

    case disallowedTransition(reason: StaticString)
}

package struct CloudAppStateMachineEngine: Sendable {
    fileprivate var requestID: String?
    fileprivate var state: CloudAppStateMachineState
    fileprivate var lastHandlerFunction: StaticString

    var _stateForTests: CloudAppStateMachineState {
        self.state
    }

    package init() {
        self.requestID = nil
        self.state = .processLaunched
        self.lastHandlerFunction = ""
    }
}

enum CloudAppStateMachineError: ReportableError {
    case spuriousEndOfCloudBoardRPC
    case corruptCloudBoardRPC
    case requestDataGeneratedAfterRequestHandlerExit
    case cloudAppRunCompletedPrematurely

    var publicDescription: String {
        switch self {
        case .spuriousEndOfCloudBoardRPC:
            return "CloudBoard RPC completed abruptly."
        case .corruptCloudBoardRPC:
            return "CloudBoard RPC delivered unexpected/misordered messages."
        case .requestDataGeneratedAfterRequestHandlerExit:
            return "CloudAppService continued generating output messages after exiting request handling."
        case .cloudAppRunCompletedPrematurely:
            return
                "CloudApp.run completed too early. Likely CloudAppService wasn't submitted for execution, or the execution was unstructured wrt CloudApp.run."
        }
    }
}

private protocol CloudBoardRPCSignals {}
extension CloudAppStateMachineEngine: CloudBoardRPCSignals {

    mutating func cloudBoardRPCServerExited(error: any Error) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched:
            self.state = .cloudBoardRPCStarted
            return .exit(status: .exitedBeforeCloudAppGotToRun(rpcError: error))
        case .cloudBoardRPCStarted,
            .warmupStarted,
            .warmupCompleted,
            .connectionContextReceived,
            .requestStarted,
            .cloudAppServiceExecutionCompleted:
            return .disallowedTransition(reason: "RPC server mustn't exit while CloudAppService is serving requests")
        case .cloudAppRunCompleted,
            .shuttingDownEarlyDueCloudBoardRPCError,
            .shuttingDownEarlyDueTermination:
            // No special handling is needed, other signals drive SM transitions
            return .doNothing
        }
    }

    package mutating func cloudBoardRPCStarted(
        channel: CloudBoardRPCChannel
    ) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched:
            self.state = .cloudBoardRPCStarted
            return .handleCloudBoardRPCStarting(channel)
        case .cloudBoardRPCStarted,
            .warmupStarted,
            .warmupCompleted,
            .connectionContextReceived,
            .requestStarted,
            .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted,
            .shuttingDownEarlyDueCloudBoardRPCError,
            .shuttingDownEarlyDueTermination:
            return .rejectSecondaryCloudBoardRPC
        }
    }

    package mutating func receivedTerminate(reason: String) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched, .cloudBoardRPCStarted:
            // Terminated before the cloud app got to run. Exit cleanly.
            self.state = .cloudAppRunCompleted
            return .exit(status: .exit(possibleInvokeResponseError: nil, possibleAppRunError: nil))

        case .warmupStarted, .warmupCompleted, .connectionContextReceived:
            self.state = .shuttingDownEarlyDueTermination(reason: reason)
            return .terminateCloudApp(possibleError: nil)

        case .requestStarted:
            self.state = .shuttingDownEarlyDueTermination(reason: reason)
            return .terminateCloudApp(possibleError: nil)

        case .cloudAppServiceExecutionCompleted, .cloudAppRunCompleted:
            return .doNothing

        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            return .doNothing
        }
    }

    package mutating func cloudBoardRPCInputCompleted(possibleError: (any Error)?) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched:
            return .disallowedTransition(reason: "RPC completed, not having started")

        case .cloudBoardRPCStarted:
            self.state = .cloudAppRunCompleted
            let error = possibleError ?? CloudAppStateMachineError.spuriousEndOfCloudBoardRPC
            // Spurious exit, before CloudApp.run was invoked. We exit early.
            return .exit(status: .exitedBeforeCloudAppGotToRun(rpcError: error))

        case .warmupStarted:
            let error = possibleError ?? CloudAppStateMachineError.spuriousEndOfCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .terminateCloudApp(possibleError: error)

        case .warmupCompleted,
            .connectionContextReceived:
            let error = possibleError ?? CloudAppStateMachineError.spuriousEndOfCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            // Not transitioning the state, until the early shutdown gets processed
            return .terminateCloudApp(possibleError: error)

        case .requestStarted(let subRequestID):
            // If the request started, and the stream terminates cleanly, we want to let it continue executing.
            // Additionally, we'll generate fake end of request input, to make sure request handling
            // doesn't get stuck.
            // Conversely, in case of errors, we always consider this as the early shutdown signal
            // TODO: validate that the RPC errors are transferred across to process exit (also, should there be a way to get those programatically)?
            if let error = possibleError {
                self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
                return .terminateCloudApp(possibleError: error)
            } else {
                return .finishRequestInput(subRequestID: subRequestID)
            }

        case .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted:
            if let error = possibleError {
                self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            }
            return .doNothing
        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            // Ignore, error shutdown being executed already anyway.
            return .doNothing
        }
    }

    package mutating func received(warmupContext: WarmupContext) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched:
            return .disallowedTransition(reason: "Got received(warmupContext:), before CloudBoardRPC started")
        case .cloudBoardRPCStarted:
            self.state = .warmupStarted
            return .runCloudApp(warmupContext)
        case .warmupStarted,
            .warmupCompleted,
            .connectionContextReceived,
            .requestStarted:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .terminateCloudApp(possibleError: error)
        case .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted:
            // Already processing exit, let it continue, but move to the error state
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(CloudAppStateMachineError.corruptCloudBoardRPC)
            return .doNothing
        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            // Already handling error exit
            return .doNothing
        }
    }

    package mutating func received(connectionContext: ConnectionContext) -> CloudAppStateMachineAction {
        self.requestID = connectionContext.requestID
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched:
            return .disallowedTransition(reason: "Got received(connectionContext:), before CloudBoardRPC started")
        case .cloudBoardRPCStarted:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .exit(status: .exitedBeforeCloudAppGotToRun(rpcError: error))
        case .warmupCompleted(let service):
            self.state = .connectionContextReceived(service, connectionContext)
            return .doNothing
        case .warmupStarted,
            .connectionContextReceived,
            .requestStarted:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .terminateCloudApp(possibleError: error)
        case .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted:
            // Already processing exit, let it continue, but move to the error state
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(CloudAppStateMachineError.corruptCloudBoardRPC)
            return .doNothing
        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            // Already handling error exit
            return .doNothing
        }
    }

    package mutating func received(
        subRequestID: CloudAppSubRequestID,
        subRequestContext: RPCSubRequestContext
    ) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched:
            return .disallowedTransition(reason: "Got received(connectionContext:), before CloudBoardRPC started")
        case .cloudBoardRPCStarted:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .exit(status: .exitedBeforeCloudAppGotToRun(rpcError: error))
        case .connectionContextReceived(let service, let connectionContext):
            self.state = .requestStarted(subRequestID)
            return .startRequest(
                subRequestID: subRequestID,
                service: service,
                connectionContext: connectionContext,
                subRequestContext: subRequestContext
            )
        case .warmupStarted,
            .warmupCompleted,
            .requestStarted:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .terminateCloudApp(possibleError: error)
        case .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted:
            // Already processing exit, let it continue, but move to the error state
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(CloudAppStateMachineError.corruptCloudBoardRPC)
            return .doNothing
        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            // Already handling error exit
            return .doNothing
        }
    }

    package mutating func received(
        subRequestID: CloudAppSubRequestID,
        inputData: Data
    ) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched:
            return .disallowedTransition(reason: "Got received(connectionContext:), before CloudBoardRPC started")
        case .cloudBoardRPCStarted:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .exit(status: .exitedBeforeCloudAppGotToRun(rpcError: error))
        case .requestStarted(let executingSubRequestID):
            // TODO: test for error when wrong request ID is received with input data or EoS
            guard subRequestID == executingSubRequestID else {
                let error = CloudAppStateMachineError.corruptCloudBoardRPC
                self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
                return .terminateCloudApp(possibleError: error)
            }
            // no state change
            return .yieldRequestInput(
                subRequestID: subRequestID,
                data: inputData
            )
        case .warmupStarted,
            .warmupCompleted,
            .connectionContextReceived:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .terminateCloudApp(possibleError: error)
        case .cloudAppServiceExecutionCompleted, .cloudAppRunCompleted:
            // Already processing exit, but more input could be generated. Drop it on the floor.
            return .doNothing
        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            // Already handling error exit
            return .doNothing
        }
    }

    // TODO: rework the cancellation to use @TaskLocal
    package mutating func receivedEndOfInput(subRequestID: CloudAppSubRequestID) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched:
            return .disallowedTransition(reason: "Got received(connectionContext:), before CloudBoardRPC started")
        case .cloudBoardRPCStarted:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .exit(status: .exitedBeforeCloudAppGotToRun(rpcError: error))
        case .requestStarted(let executingSubRequestID):
            guard subRequestID == executingSubRequestID else {
                let error = CloudAppStateMachineError.corruptCloudBoardRPC
                self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
                return .terminateCloudApp(possibleError: error)
            }
            // Request execution is continuing still, remain in the same state until CloudAppService.request() exits (notified via `requestHandlingFinished`)
            return .finishRequestInput(subRequestID: subRequestID)
        case .warmupStarted,
            .warmupCompleted,
            .connectionContextReceived:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .terminateCloudApp(possibleError: error)
        case .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted:
            // Already processing exit, let it continue, but move to the error state
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(CloudAppStateMachineError.corruptCloudBoardRPC)
            return .doNothing
        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            // Already handling error exit
            return .doNothing
        }
    }

    package mutating func received(
        keyDerivationResult result: KeyDerivationCoordinator.Result,
        derivationID: UInt64
    ) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .processLaunched:
            return .disallowedTransition(reason: "Got key derivation result before CloudBoardRPC started")
        case .cloudBoardRPCStarted:
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .exit(status: .exitedBeforeCloudAppGotToRun(rpcError: error))
        case .requestStarted:
            // The cloud app can only request derivation while its request handler runs, so a result
            // is expected here. Correlate it back to the waiting deriveKey via the coordinator.
            return .resolveKeyDerivation(derivationID: derivationID, result: result)
        case .warmupStarted,
            .warmupCompleted,
            .connectionContextReceived:
            // A derivation result before a request started is misordered/corrupt CloudBoard traffic.
            let error = CloudAppStateMachineError.corruptCloudBoardRPC
            self.state = .shuttingDownEarlyDueCloudBoardRPCError(error)
            return .terminateCloudApp(possibleError: error)
        case .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted:
            // The request handler already finished; a late reply has no waiter. Drop it on the floor.
            return .doNothing
        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            // Already tearing down; pending derivations are failed via the coordinator's shutdown.
            return .doNothing
        }
    }
}

private protocol CloudAppSignals {}
extension CloudAppStateMachineEngine: CloudAppSignals {
    package mutating func warmupCompleted(service: (any CloudAppService)) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .warmupStarted:
            self.state = .warmupCompleted(service)
            return .notifyCloudBoardThatWarmupCompleted
        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            return .rejectCloudAppService(reason: .cloudBoardRPCError)
        case .processLaunched,
            .cloudBoardRPCStarted:
            return .disallowedTransition(reason: "Warmup completed, before warmup got started")
        case .warmupCompleted,
            .connectionContextReceived,
            .requestStarted,
            .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted:
            return .rejectCloudAppService(reason: .secondaryExecution)
        }
    }

    package mutating func requestOutputGenerated(
        subRequestID: CloudAppSubRequestID,
        outputData: Data
    ) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .requestStarted(let executingSubRequestID):
            guard executingSubRequestID == subRequestID else {
                return .disallowedTransition(
                    reason: "Unexpected request id, state machine can only handle a single request right now"
                )
            }
            return .yieldRequestOutput(subRequestID: subRequestID, data: outputData)
        case .processLaunched,
            .cloudBoardRPCStarted,
            .warmupStarted,
            .warmupCompleted,
            .connectionContextReceived:
            return .disallowedTransition(
                reason: "requestOutputGenerated(requestID:outputData:) before request got started"
            )

        case .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted:
            // This indicates that application isn't following structured concurrency rules.
            // The data is being generated after `CloudAppService.request` exited
            return .exit(
                status: .exitedBeforeCloudAppGotToRun(
                    rpcError: CloudAppStateMachineError.requestDataGeneratedAfterRequestHandlerExit
                )
            )

        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            // Don't attempt to deliver the data to CloudBoard. Especially that in some cases we're here because CB messages were corrupt, so it's a security concern
            return .doNothing
        }
    }

    package mutating func requestHandlingCompleted(
        subRequestID: CloudAppSubRequestID,
        possibleError: (any Error)?
    ) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .requestStarted(let executingSubRequestID):
            guard executingSubRequestID == subRequestID else {
                return .disallowedTransition(
                    reason: "Unexpected request id, state machine can only handle a single request right now"
                )
            }
            self.state = .cloudAppServiceExecutionCompleted
            return .finishRequestOutputAndTerminateCloudAppService(
                subRequestID: subRequestID,
                possibleError: possibleError
            )

        case .processLaunched,
            .cloudBoardRPCStarted,
            .warmupStarted,
            .warmupCompleted,
            .connectionContextReceived,
            .cloudAppServiceExecutionCompleted,
            .cloudAppRunCompleted:
            // NOTE: this signal is delivered by our code, after the request handler ends. Contrary to the requestOutputGenerated, we can assert it mustn't happen after execution completed
            return .disallowedTransition(reason: "requestHandlingCompleted(requestID:) in an unexpected state")

        case .shuttingDownEarlyDueCloudBoardRPCError, .shuttingDownEarlyDueTermination:
            // Don't attempt to deliver the data to CloudBoard. Especially that in some cases we're here because CB messages were corrupt, so it's a security concern
            return .doNothing
        }
    }

    package mutating func cloudAppRunCompleted(
        possibleError possibleCloudAppRunError: (any Error)?
    ) -> CloudAppStateMachineAction {
        self.lastHandlerFunction = #function
        switch self.state {
        case .warmupStarted,
            .warmupCompleted,
            .connectionContextReceived:
            self.state = .cloudAppRunCompleted
            return .exit(
                status: .exit(
                    possibleInvokeResponseError: possibleCloudAppRunError
                        ?? CloudAppStateMachineError.cloudAppRunCompletedPrematurely,
                    possibleAppRunError: possibleCloudAppRunError
                )
            )
        case .cloudAppServiceExecutionCompleted:
            // This is the normal path, don't generate a fake error here
            self.state = .cloudAppRunCompleted
            return .exit(
                status: .exit(
                    possibleInvokeResponseError: possibleCloudAppRunError,
                    possibleAppRunError: possibleCloudAppRunError
                )
            )
        case .shuttingDownEarlyDueCloudBoardRPCError(let rpcError):
            self.state = .cloudAppRunCompleted
            // possible CloudApp.run() error takes precedence over the fact we're terminating due to RPC errors
            return .exit(
                status: .exit(
                    possibleInvokeResponseError: possibleCloudAppRunError ?? rpcError,
                    possibleAppRunError: possibleCloudAppRunError
                )
            )
        case .shuttingDownEarlyDueTermination:
            self.state = .cloudAppRunCompleted
            // This is a clean early shutdown. Only report an error to CloudBoard if CloudApp.run() itself threw.
            return .exit(
                status: .exit(
                    possibleInvokeResponseError: possibleCloudAppRunError,
                    possibleAppRunError: possibleCloudAppRunError
                )
            )
        case .processLaunched,
            .cloudBoardRPCStarted,
            .cloudAppRunCompleted:
            return .disallowedTransition(reason: "cloudAppRunCompleted()  in an unexpected state")
        case .requestStarted:
            // This indicates that application isn't following structured concurrency rules.
            // CloudAppService.request() must be executing in some unstructured Task, not within the CloudApp.run() task
            // The good thing is that the Runner's Task devoted to CloudApp.run is gone therefore the exit won't end up being held up
            return .exit(
                status: .exit(
                    possibleInvokeResponseError: CloudAppStateMachineError.cloudAppRunCompletedPrematurely,
                    possibleAppRunError: possibleCloudAppRunError
                )
            )
        }
    }
}

package final class CloudAppStateMachine: Sendable {
    static let logger = Logger(label: "cloudapp.CloudAppStateMachine")

    let localID: String
    // The resourceID is set once the `WarmupContext` message arrives
    private let _nodeResourceID = Mutex<NodeResourceID?>(nil)
    var nodeResourceID: NodeResourceID {
        get {
            self._nodeResourceID.withLock {
                $0 ?? NodeResourceID(-1)
            }
        }
        set {
            self._nodeResourceID.withLock {
                $0 = newValue
            }
        }
    }

    fileprivate struct HistoryItem {
        let timestamp: NIODeadline
        let stateBefore: CloudAppStateMachineState
        let handlerFunction: StaticString
        let action: CloudAppStateMachineAction
        let stateAfter: CloudAppStateMachineState
    }

    struct DebugHistory: CustomDebugStringConvertible {
        private var historyTail: CircularBuffer<HistoryItem>
        private let maxDebugHistoryLength: Int

        fileprivate init(maxDebugHistoryLength: Int) {
            self.historyTail = CircularBuffer(initialCapacity: maxDebugHistoryLength)
            self.maxDebugHistoryLength = maxDebugHistoryLength
        }

        mutating fileprivate func append(_ historyItem: HistoryItem) {
            debugOnly {
                while self.historyTail.count >= self.maxDebugHistoryLength {
                    self.historyTail.removeFirst()
                }
                self.historyTail.append(historyItem)
            }
        }

        private var _debugDescription: String {
            guard let firstHistoryItem = self.historyTail.first else {
                return "Empty debug history"
            }
            return "First retained history item at: \(firstHistoryItem.timestamp)\n"
                + self.historyTail.map({ historyItem in
                    let fixedStateBefore = "\(historyItem.stateBefore)".padding(
                        toLength: 30,
                        withPad: " ",
                        startingAt: 0
                    )
                    let fixedStateAfter = "\(historyItem.stateAfter)".padding(toLength: 30, withPad: " ", startingAt: 0)
                    let fixedHandlerFunction = historyItem.handlerFunction.description.padding(
                        toLength: 30,
                        withPad: " ",
                        startingAt: 0
                    )
                    let fixedHandlerAction = "\(historyItem.action)".padding(toLength: 30, withPad: " ", startingAt: 0)

                    let timeDelta = historyItem.timestamp - firstHistoryItem.timestamp
                    let timeDeltaMs = timeDelta.nanoseconds / 1_000_000
                    return
                        "Δt \(String(format: "%8lldms", timeDeltaMs)), \(fixedStateBefore) >> \(fixedStateAfter), handler: \(fixedHandlerFunction), action: \(fixedHandlerAction)"
                }).joined(separator: "\n")
        }

        var debugDescription: String {
            debugOnly {
                self._debugDescription
            } nonDebugOnly: {
                "Debug history only available in debug builds"
            }
        }
    }

    struct StateMachineEngineWithDebugHistory {
        var engine: CloudAppStateMachineEngine
        var debugHistory: DebugHistory
    }
    private let engineWithDebugHistory: Mutex<StateMachineEngineWithDebugHistory>
    private let actionProducer: AsyncStream<CloudAppStateMachineAction>
    private let actionConsumer: AsyncStream<CloudAppStateMachineAction>.Continuation

    var debugHistory: DebugHistory {
        self.engineWithDebugHistory.withLock { $0.debugHistory }
    }

    package var requestID: String? {
        self.engineWithDebugHistory.withLock { $0.engine.requestID }
    }

    var actionSequence: any AsyncSequence<CloudAppStateMachineAction, Never> {
        self.actionProducer
    }

    package init(localID: String, maxDebugHistoryLength: Int = 16) {
        self.localID = localID
        self.engineWithDebugHistory = Mutex(
            StateMachineEngineWithDebugHistory(
                engine: CloudAppStateMachineEngine(),
                debugHistory: DebugHistory(maxDebugHistoryLength: maxDebugHistoryLength)
            )
        )
        let (producer, consumer) = AsyncStream.makeStream(of: CloudAppStateMachineAction.self)
        self.actionConsumer = consumer
        self.actionProducer = producer
    }

    private func recordAsynchronous(action: CloudAppStateMachineAction) {
        self.actionConsumer.yield(action)
        if case .exit = action {
            self.actionConsumer.finish()
        }
    }

    private func _advanceRecordingHistory<T: Sendable & ActionExtractable>(
        _ body: (inout CloudAppStateMachineEngine) -> T
    ) -> T {
        let (stateBefore, stateAfter, requestID, out) = self.engineWithDebugHistory.withLock { engineWithDebugHistory in
            // This has the drawback of leaking the locked context
            // However, it saves us having to duplicate all the signal functions again
            let stateBefore = engineWithDebugHistory.engine.state
            let out = body(&engineWithDebugHistory.engine)
            let stateAfter = engineWithDebugHistory.engine.state

            var debugHistoryForFatalError: String = ""
            debugOnly {
                engineWithDebugHistory.debugHistory.append(
                    HistoryItem(
                        timestamp: NIODeadline.now(),
                        stateBefore: stateBefore,
                        handlerFunction: engineWithDebugHistory.engine.lastHandlerFunction,
                        action: out.action,
                        stateAfter: stateAfter
                    )
                )
                if case .disallowedTransition = out.action {
                    debugHistoryForFatalError = "\n" + engineWithDebugHistory.debugHistory.debugDescription
                }
            }

            let requestID =
                if let requestID = engineWithDebugHistory.engine.requestID {
                    requestID
                } else {
                    "unavailable"
                }
            if case .disallowedTransition(let reason) = out.action {
                fatalError(
                    "State machine fatalError, in state: \(engineWithDebugHistory.engine.state), due to: \(reason)"
                        + debugHistoryForFatalError
                )
            }

            return (
                stateBefore.identifier,
                stateAfter.identifier,
                requestID,
                out
            )
        }

        if stateBefore != stateAfter {
            Self.logger.info(
                "CloudApp is transitioning between states",
                metadata: [
                    "stateBefore": "\(stateBefore.label)",
                    "stateAfter": "\(stateAfter.label)",
                    "localID": "\(self.localID)",
                    "resourceID": "\(self.nodeResourceID)",
                    "requestID": "\(requestID)",
                ]
            )
        }

        return out
    }

    package func advance(
        _ body: (inout CloudAppStateMachineEngine) -> CloudAppStateMachineAction
    ) {
        let action = self._advanceRecordingHistory(body)
        self.recordAsynchronous(action: action)
    }

    package enum ActionDecision {
        case consumeDirectly(CloudAppStateMachineAction)
        case consumeAsynchronously(CloudAppStateMachineAction)
    }

    package func advancePotentiallyConsumingTheActionDirectly(
        _ body: (inout CloudAppStateMachineEngine) -> ActionDecision
    ) -> CloudAppStateMachineAction? {
        let action = self._advanceRecordingHistory(body)
        switch action {
        case .consumeDirectly(let action):
            return action
        case .consumeAsynchronously(let action):
            self.recordAsynchronous(action: action)
            return nil
        }
    }
}

private protocol ActionExtractable {
    var action: CloudAppStateMachineAction { get }
}

extension CloudAppStateMachineAction: ActionExtractable {
    var action: CloudAppStateMachineAction {
        self
    }
}

extension CloudAppStateMachine.ActionDecision: ActionExtractable {
    var action: CloudAppStateMachineAction {
        switch self {
        case .consumeDirectly(let action), .consumeAsynchronously(let action):
            return action
        }
    }
}

extension CloudAppStateMachine: RequestIDVendor {}
