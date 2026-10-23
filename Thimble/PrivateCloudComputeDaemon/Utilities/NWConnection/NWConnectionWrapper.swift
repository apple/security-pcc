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

//
//  NWConnectionWrapper.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

@_spi(NWActivity) @_spi(OHTTP) @_spi(NWConnection) import Network
import OSLog
import PrivateCloudCompute
import Synchronization

final class NWConnectionWrapper: Sendable {
    private let underlying: NWConnection
    private let logger: Logger
    private let logPrefix: String
    private let readyEvent: AsyncEvent<Void>?
    private let maximumReadLength: Int

    private enum State {
        case connecting
        case waiting(error: NWError)
        case connected
    }

    private let stateLock = Mutex<State>(.connecting)

    init(
        underlying: NWConnection,
        readyEvent: AsyncEvent<Void>?,
        logger: Logger,
        requestID: UUID,
        logComment: String,
        maximumReadLength: Int = .max,
        progressContinuation: AsyncStream<ConnectionUpdate>.Continuation?
    ) {
        self.underlying = underlying
        self.logger = logger
        self.logPrefix = "\(requestID): [C\(underlying.identifier)] (\(logComment))"
        self.readyEvent = readyEvent
        self.maximumReadLength = maximumReadLength
        // We deliberately set up a reference cycle between the self and the underlying connection.
        // We are aware that weak exists. But we prefer to break the reference cycle instead.
        // Performance is much better without weak references.
        self.underlying.stateUpdateHandler = { [self] newState in
            progressContinuation?.yield(.stateChanged(newState))
            self.connectionStateUpdated(newState)
        }

        if let progressContinuation {
            self.underlying.connectionProgressUpdateHandler = { progressReport in
                progressContinuation.yield(.connectionProgress(progressReport))
            }
        }
    }

    func start(queue: DispatchQueue) {
        self.logger.debug("\(self.logPrefix) start")
        self.underlying.start(queue: queue)
    }

    func cancel() {
        self.logger.log("\(self.logPrefix) cancel")
        self.underlying.cancel()
    }

    func write(
        content: Data?,
        contentContext: NWConnection.ContentContext,
        isComplete: Bool
    ) async throws {
        try await withTaskCancellationHandler {
            self.logger.debug("\(self.logPrefix) send content.count=\(content?.count ?? -1) context=\(contentContext.identifier) isComplete=\(isComplete)")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.underlying.send(
                    content: content,
                    contentContext: contentContext,
                    isComplete: isComplete,
                    completion: .contentProcessed { error in
                        if let error {
                            self.logger.error("\(self.logPrefix) send failed error=\(error)")
                            let errorToThrow = self.stateLock.withLock { state -> NWError in
                                switch state {
                                case .connecting, .connected:
                                    return error
                                case .waiting(let connectionCreationError):
                                    return connectionCreationError
                                }
                            }
                            continuation.resume(throwing: errorToThrow)
                        } else {
                            continuation.resume(returning: ())
                        }
                    }
                )
            }
            self.logger.debug("\(self.logPrefix) send finished")
        } onCancel: {
            self.logger.log("\(self.logPrefix) send cancelled")
            self.underlying.forceCancel()
        }
    }

    func next() async throws -> NWConnectionReceived {
        try await withTaskCancellationHandler {
            self.logger.debug("\(self.logPrefix) receive")
            let (data, contentContext, isComplete, error) = await withCheckedContinuation { continuation in
                self.underlying.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: self.maximumReadLength
                ) { data, contentContext, isComplete, error in
                    continuation.resume(returning: (data, contentContext, isComplete, error))
                }
            }
            self.logger.debug("\(self.logPrefix) receive finished data.count=\(data?.count ?? -1) isComplete=\(isComplete) error=\(error)")

            if let error {
                // we need to check if we have seen a waiting before and NOT a ready! If we got a
                // waiting before, we should use the error that we got when we were waiting.
                let errorToThrow = self.stateLock.withLock { state -> NWError in
                    switch state {
                    case .connecting, .connected:
                        return error
                    case .waiting(let connectionCreationError):
                        return connectionCreationError
                    }
                }
                throw errorToThrow
            } else {
                return .init(data: data, contentContext: contentContext, isComplete: isComplete)
            }
        } onCancel: {
            // We are force cancelling here since Swift cancellation should be as immediate
            // as possible.
            self.logger.log("\(self.logPrefix) receive cancelled")
            self.underlying.forceCancel()
        }
    }

    private func connectionStateUpdated(_ newState: NWConnection.State) {
        switch newState {
        case .setup:
            self.logger.debug("\(self.logPrefix) state changed to setup")
        case .preparing:
            self.logger.debug("\(self.logPrefix) state changed to preparing")
            break

        case .waiting(let error):
            self.logger.error("\(self.logPrefix) state changed to waiting error=\(error)")
            // this is the callback we get, if a connection can not be established right away
            let cancelIfNetworkUnavailable = self.stateLock.withLock { state -> Bool in
                switch state {
                case .connecting:
                    state = .waiting(error: error)
                    return true

                case .waiting:
                    // This state is not expected and should never be reached. But we do not
                    // want to crash here. Therefore ignore.
                    return true

                case .connected:
                    // This state is not expected and should never be reached. But we do not
                    // want to crash here. Therefore ignore.
                    return false
                }
            }

            if cancelIfNetworkUnavailable && self.underlying.currentPath?.status == .unsatisfied {
                // there is no viable network. therefore we want to cancel right away.
                self.cancel()
                // this will nullify self.underlying.stateUpdateHandler and effectively break the reference cycle with self
                self.underlying.stateUpdateHandler = nil
            }

        case .ready:
            self.logger.debug("\(self.logPrefix) state changed to ready")
            self.stateLock.withLock { state in
                switch state {
                case .connecting, .waiting:
                    state = .connected

                case .connected:
                    // connected again? Should never be reached. Anyway, don't want to crash here.
                    break
                }
            }
            self.readyEvent?.fire()

        case .failed(let error):
            self.logger.error("\(self.logPrefix) state changed to failed error=\(error)")

        case .cancelled:
            self.logger.debug("\(self.logPrefix) state changed to cancelled")
            let error = self.stateLock.withLock { state -> (any Error)? in
                switch state {
                case .connecting:
                    return CancellationError()
                case .waiting(let error):
                    return error
                case .connected:
                    return nil
                }
            }

            if let error {
                self.readyEvent?.fire(throwing: error)
            } else {
                self.readyEvent?.fire()
            }

        @unknown default:
            self.logger.error("\(self.logPrefix) state change to unexpected state=\(String(describing: newState), privacy: .public)")
            break
        }
    }
}
