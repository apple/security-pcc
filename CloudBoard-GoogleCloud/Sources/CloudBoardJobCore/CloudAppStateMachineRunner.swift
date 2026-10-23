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
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

private let runnerLogger = Logger(label: "cloudapp.CloudAppStateMachineRunner")

/// Synthesized error reported when `actionSequence` ends without ever yielding
/// `.exit` on a non-cancelled task. Distinct from `CancellationError` so ops
/// telemetry can tell the cancellation race apart from an engine regression.
package struct StateMachineExitError: Error, CustomStringConvertible {
    package var description: String { "actionSequence ended without .exit; synthesized exit" }
}

package enum CloudAppExitStatus: Sendable {
    /// This represents the case where CloudBoard RPC terminated (with an error) before `CloudApp.run(process:)` got invoked.
    case exitedBeforeCloudAppGotToRun(rpcError: (any Error))
    /// This is the common case, with `possibleInvokeResponseError` representing what gets returned to CloudBoard, and `possibleAppRunError` saves possible error thrown by `CloudApp.run(process:)`.
    case exit(
        possibleInvokeResponseError: (any Error)?,
        possibleAppRunError: (any Error)?
    )

    package var possibleInvokeResponseError: (any Error)? {
        switch self {
        case .exitedBeforeCloudAppGotToRun(let rpcError):
            return rpcError
        case .exit(let possibleInvokeResponseError, _):
            return possibleInvokeResponseError
        }
    }
}

private let logger = Logger(label: "cloudapp.CloudAppRunner")

extension CloudApp {
    package func run(stateMachine: CloudAppStateMachine) async -> CloudAppExitStatus {
        await withTaskGroup(of: Void.self) { group in
            let (executionNotificationProducer, executionNotificationConsumer) = AsyncStream<
                CloudAppProcess.ExecutionNotification
            >.makeStream()
            var requests = [CloudAppSubRequestID: CloudAppRequest]()
            var rpcChannel: CloudBoardRPCChannel? = nil
            for await action in stateMachine.actionSequence {
                let localID = stateMachine.localID
                let resourceID = stateMachine.nodeResourceID.description
                let requestID = stateMachine.requestID ?? "unavailable"
                switch action {
                case .doNothing:
                    break
                case .handleCloudBoardRPCStarting(let channel):
                    logger.info(
                        "Handling CloudBoard RPC start",
                        metadata: [
                            "localID": "\(localID)",
                            "resourceID": "\(resourceID)",
                            "requestID": "\(requestID)",
                        ]
                    )
                    rpcChannel = channel
                    // Run the key-derivation coordinator for the lifetime of the RPC. It is notified
                    // to exit — failing any pending derivations — via `channel.finish()` on `.exit`
                    // and `shutdown(error:)` on `.terminateCloudApp`.
                    group.addTask {
                        await channel.keyDerivationCoordinator.run()
                    }
                case .runCloudApp(let warmupContext):
                    logger.info(
                        "Running CloudApp",
                        metadata: [
                            "localID": "\(localID)",
                            "resourceID": "\(resourceID)",
                            "requestID": "\(requestID)",
                        ]
                    )
                    let cloudAppProcess = CloudAppProcess(
                        warmupContext: warmupContext,
                        stateMachine: stateMachine,
                        requestSequence: executionNotificationProducer
                    )
                    group.addTask {
                        do {
                            try await self.run(process: cloudAppProcess)
                            logger.info(
                                "CloudApp.run completed",
                                metadata: [
                                    "localID": "\(stateMachine.localID)",
                                    "resourceID": "\(stateMachine.nodeResourceID)",
                                    "requestID": "\(stateMachine.requestID ?? "unavailable")",
                                ]
                            )
                            stateMachine.advance {
                                $0.cloudAppRunCompleted(possibleError: nil)
                            }
                        } catch {
                            logger.error(
                                "CloudApp.run completed with error",
                                metadata: [
                                    "localID": "\(stateMachine.localID)",
                                    "resourceID": "\(stateMachine.nodeResourceID)",
                                    "requestID": "\(stateMachine.requestID ?? "unavailable")",
                                    "error": "\(String(reportable: error))",
                                ]
                            )
                            stateMachine.advance {
                                $0.cloudAppRunCompleted(possibleError: error)
                            }
                        }
                    }
                case .terminateCloudApp(let possibleError):
                    // This could be notified multiple times, but since `.finish()` will stop
                    // duplicate notifications, we handle this cleanly from the adopter's perspective
                    if let error = possibleError {
                        logger.error(
                            "Terminating CloudApp",
                            metadata: [
                                "localID": "\(localID)",
                                "resourceID": "\(resourceID)",
                                "requestID": "\(requestID)",
                                "error": "\(String(reportable: error))",
                            ]
                        )
                    } else {
                        logger.info(
                            "Terminating CloudApp",
                            metadata: [
                                "localID": "\(localID)",
                                "resourceID": "\(resourceID)",
                                "requestID": "\(requestID)",
                            ]
                        )
                    }
                    executionNotificationConsumer.yield(.shutdownEarly)
                    executionNotificationConsumer.finish()
                    // Fail in-flight derivations on early shutdown so a `request()` blocked in
                    // `deriveKey()` can finish even when the adopter's `earlyShutdown()` doesn't
                    // cancel the task; the response writer is finished later by `.exit`.
                    rpcChannel?.keyDerivationCoordinator.shutdown(error: possibleError)
                case .startRequest(let subRequestID, _, let connectionContext, let subRequestContext):
                    logger.info(
                        "Starting request",
                        metadata: [
                            "localID": "\(localID)",
                            "resourceID": "\(resourceID)",
                            "requestID": "\(requestID)",
                            "subRequestID": "\(subRequestID.id)",
                        ]
                    )
                    // `.handleCloudBoardRPCStarting` always precedes `.startRequest`, so the channel is set.
                    let coordinator = rpcChannel!.keyDerivationCoordinator
                    let request = CloudAppRequest(
                        id: subRequestID,
                        input: InputData(),
                        output: ResponseWriter(
                            subRequestID: subRequestID,
                            stateMachine: stateMachine
                        ),
                        context: RequestContext(
                            subRequestContext: subRequestContext,
                            connectionContext: connectionContext,
                            keyDeriver: coordinator
                        )
                    )
                    requests[subRequestID] = request
                    executionNotificationConsumer.yield(.request(request))
                case .yieldRequestInput(let subRequestID, let data):
                    let request = requests[subRequestID]!
                    request.input.yield(data)
                case .finishRequestInput(let subRequestID):
                    logger.info(
                        "Request input finished",
                        metadata: [
                            "localID": "\(localID)",
                            "resourceID": "\(resourceID)",
                            "requestID": "\(requestID)",
                            "subRequestID": "\(subRequestID.id)",
                        ]
                    )
                    let request = requests[subRequestID]!
                    request.input.finish(throwing: nil)

                case .notifyCloudBoardThatWarmupCompleted:
                    logger.info(
                        "Warmup completed, notifying CloudBoard",
                        metadata: [
                            "localID": "\(localID)",
                            "resourceID": "\(resourceID)",
                            "requestID": "\(requestID)",
                        ]
                    )
                    let warmupCompleted = Proto_CloudApp_InvokeWorkloadResponse.with {
                        $0.warmupComplete = .with { _ in
                        }
                    }
                    rpcChannel!.responseWriter.yield(warmupCompleted)
                case .yieldRequestOutput(let subRequestID, let data):
                    let requestOutput = Proto_CloudApp_InvokeWorkloadResponse.with {
                        $0.responseOutputData = .with {
                            $0.subRequestID = subRequestID.id
                            $0.message = data
                        }
                    }
                    rpcChannel!.responseWriter.yield(requestOutput)
                case .resolveKeyDerivation(let derivationID, let result):
                    // `.handleCloudBoardRPCStarting` always precedes any request, so the channel is set.
                    rpcChannel!.keyDerivationCoordinator.resolve(derivationID: derivationID, result: result)
                case .finishRequestOutputAndTerminateCloudAppService(let subRequestID, let possibleError):
                    if let error = possibleError {
                        logger.error(
                            "Request output finished with error",
                            metadata: [
                                "localID": "\(localID)",
                                "resourceID": "\(resourceID)",
                                "requestID": "\(requestID)",
                                "subRequestID": "\(subRequestID.id)",
                                "error": "\(String(reportable: error))",
                            ]
                        )
                    } else {
                        logger.info(
                            "Request output finished",
                            metadata: [
                                "localID": "\(localID)",
                                "resourceID": "\(resourceID)",
                                "requestID": "\(requestID)",
                                "subRequestID": "\(subRequestID.id)",
                            ]
                        )
                    }
                    let responseEndOfOutput = Proto_CloudApp_InvokeWorkloadResponse.with {
                        $0.responseEndOfOutput = .with {
                            $0.subRequestID = subRequestID.id
                            if let error = possibleError {
                                $0.type = .error(
                                    .with {
                                        $0.message = String(reportable: error)
                                    }
                                )
                            } else {
                                $0.type = .success(
                                    .with { _ in
                                    }
                                )
                            }
                        }
                    }
                    rpcChannel!.responseWriter.yield(responseEndOfOutput)
                    // This will trigger the service execution to finish
                    executionNotificationConsumer.finish()
                case .exit(let status):
                    logger.info(
                        "Exiting",
                        metadata: [
                            "localID": "\(localID)",
                            "resourceID": "\(resourceID)",
                            "requestID": "\(requestID)",
                        ]
                    )
                    let cloudAppComplete = Proto_CloudApp_InvokeWorkloadResponse.with {
                        $0.cloudAppComplete = .with {
                            if let error = status.possibleInvokeResponseError {
                                $0.type = .error(
                                    .with {
                                        $0.message = String(reportable: error)
                                    }
                                )
                            } else {
                                $0.type = .success(
                                    .with { _ in
                                    }
                                )
                            }
                        }
                    }
                    rpcChannel?.responseWriter.yield(cloudAppComplete)
                    rpcChannel?.finish(error: status.possibleInvokeResponseError)

                    return status
                case .rejectSecondaryCloudBoardRPC, .rejectCloudAppService, .disallowedTransition:
                    fatalError("Rejected RPCs/CloudAppServices/disallowed transition should be handled elsewhere")
                }
            }
            // Defensive fallback reached when `actionSequence` finishes without emitting `.exit`.
            // Primary teardown is via CloudAppRPCHandler's input-reader defer. This fallback
            // covers cases that bypass that path — e.g. warmup-phase aborts where CloudApp.run()
            // is cancelled before any RPC starts, or future engine-level regressions where a
            // state transition forgets to emit `.exit` on its terminal branch.
            // On a non-cancelled task, log at error level so the regression is visible in ops
            // telemetry; always return a well-formed `.exit` so the RPC completes.
            if !Task.isCancelled {
                runnerLogger.error("actionSequence ended without .exit; synthesizing exit")
                rpcChannel?.finish(error: StateMachineExitError())
                return .exit(
                    possibleInvokeResponseError: StateMachineExitError(),
                    possibleAppRunError: nil
                )
            }
            rpcChannel?.finish()
            return .exit(possibleInvokeResponseError: CancellationError(), possibleAppRunError: CancellationError())
        }
    }
}
