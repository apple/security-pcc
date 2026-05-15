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
//  ResponseDemultiplexer.swift
//  PrivateCloudCompute
//
//  Copyright © 2025 Apple Inc. All rights reserved.
//

import OSLog
import Synchronization

/// Applicable for long-lived connections where there is a single "response channel" from the
/// daemon returning responses tagged for different subrequests, and possibly multiple
/// consumers each interested in responses for a particular subrequest.
/// One producer, multiple consumers.
/// * "producer" is basically our daemon
/// * "consumer" is our adopter calling `next()` on the Response that we give them in the
///   `bodyClosure` of `PrivateCloudComputeConnection.withRequest(...)`.
/// **NOTE:** When there are some consumers, but no consumer for the message that producer
/// produced, all consumers will remain suspended until there is
final class ResponseDemultiplexer: Sendable {
    typealias RequestId = UInt64

    struct State {
        var canceledRequestIds: Set<RequestId> = [] {
            didSet {
                incrementRevisionAndResumeRunloopIfSuspended()
            }
        }
        var consumers: [RequestId: AsyncEvent<XPCResponseMessage>] = [:] {
            didSet {
                incrementRevisionAndResumeRunloopIfSuspended()
            }
        }
        var pendingMessage: XPCResponseMessage? {
            didSet {
                incrementRevisionAndResumeRunloopIfSuspended()
            }
        }
        var shouldDrainProducer = false {
            didSet {
                incrementRevisionAndResumeRunloopIfSuspended()
            }
        }

        /// Will be set once the runloop ends.
        private(set) var runloopResult: Result<Void, any Error>?

        /// Updated whenever fields that runloop cares about have been changed. The runloop reads the value
        /// at the beginning of the iteration, and then at the end of the iteration passes it to
        /// `suspendRunloopIfNeeded()` to determine if it should suspend or not.
        private(set) var revision: Int = 0

        /// Set when the runloop is suspended and is waiting for a signal on this event to resume.
        private var resumeRunloopSignal: AsyncEvent<Void>?

        private mutating func incrementRevisionAndResumeRunloopIfSuspended() {
            revision += 1

            if let event = self.resumeRunloopSignal {
                self.resumeRunloopSignal = nil
                event.fire(())
            }
        }

        /// Called at the end of the iteration of the runloop to determine whether it should do another iteration or if it
        /// should suspend and wait for the returned event to be fired.
        /// - Parameter revisionAtIterationStart: the revision that runloop knew about when it started its iteration.
        /// - Returns: an event that the runloop should wait for. If nil, the runloop should continue with another iteration right away.
        mutating func createEventForRunloopToWaitForIfNeeded(revisionAtIterationStart: Int) -> AsyncEvent<Void>? {
            if revisionAtIterationStart == self.revision {
                if let existing = self.resumeRunloopSignal {
                    // Shouldn't be happening, dev error. But let's be safe just in case.
                    existing.fire(throwing: PrivateCloudComputeError(code: .internalError))
                }
                // The runloop just ran and the state didn't change.
                // It can be suspended now until a new change.
                self.resumeRunloopSignal = AsyncEvent()
            }
            return self.resumeRunloopSignal
        }

        mutating func finishConsumers(error: any Error) {
            for consumer in consumers.values {
                consumer.fire(throwing: error)
            }
            consumers = [:]
        }

        mutating func runloopFinished(logPrefix: String, logger: Logger, error: (any Error)? = nil) {
            if let error {
                self.runloopResult = .failure(error)
                self.finishConsumers(error: error)
            } else {
                self.runloopResult = .success(())
                // We shouldn't have any consumers at this point. But in case
                // we do, fail them so they don't hang forever.
                let pendingRequestIds = consumers.keys
                if !pendingRequestIds.isEmpty {
                    logger.warning("\(logPrefix) unexpected, still have \(pendingRequestIds.count) outstanding requests, requestIds=\(pendingRequestIds)")
                    self.finishConsumers(error: PrivateCloudComputeError(code: .internalError))
                }
            }
        }
    }

    private let state = Mutex(State())
    private let logPrefix: String
    private let logger: Logger
    private let producer: any XPCRequestProxyProtocol

    init(logPrefix: String, logger: Logger, producer: any XPCRequestProxyProtocol) {
        self.logPrefix = "\(logPrefix) response demultiplexer"
        self.logger = logger
        self.producer = producer
    }

    func run(closure: () async throws -> Void) async throws {
        logger.log("\(self.logPrefix) run")
        defer {
            logger.log("\(self.logPrefix) run end")
        }
        try await withThrowingTaskGroup { taskGroup in
            taskGroup.addTask {
                // Don't re-throw runloop's errors to the adopter. Runloop finishes
                // after the adopter finished running the closure, they shouldn't care
                // what happens during response "draining".
                do {
                    try await self.logger.logLifetime("runTheRunloop", logPrefix: self.logPrefix) {
                        try await self.runTheRunloop()
                        self.state.withLock {
                            $0.runloopFinished(logPrefix: self.logPrefix, logger: self.logger)
                        }
                    }
                } catch {
                    self.state.withLock {
                        $0.runloopFinished(logPrefix: self.logPrefix, logger: self.logger, error: error)
                    }
                }
            }

            var closureError: (any Error)?
            do {
                try await closure()
            } catch {
                closureError = error
            }

            // The closure may have thrown, but we want to gracefully finish the connection.

            // We need to drain the producer before returning. Calling `finish` will put
            // the runloop into a state to drain the response stream from the daemon. As
            // a result, this should end `runTheRunloop()` subtask started above.
            self.finish()

            // Wait for the runloop to finish. Note: the subtask won't throw as it catches
            // and handles the runloop errors.
            try await taskGroup.waitForAll()

            // Re-throw whatever the adopter threw from the closure.
            if let closureError {
                throw closureError
            }
        }
    }

    /// Finishes suspended consumers, if any, with an error, and sets a flag indicating to the runloop that it needs to drain the producer.
    private func finish() {
        logger.log("\(self.logPrefix) finish")

        state.withLock { state in
            state.pendingMessage = nil
            state.shouldDrainProducer = true
            state.finishConsumers(error: PrivateCloudComputeError(code: .connectionNoLongerRunning))
        }
    }

    /// The runloop runs `while true` cycle. At the beginning of each iteration, it gets
    /// the "revision" number of the State. At the end of each cycle, we check if the State
    /// has the same revision.
    /// * If yes, that means nothing changed since iteration start, and
    /// we suspend the runloop until something changes.
    /// * If revision changed, we let the runloop run another iteration.
    /// Whenever a field in State that the runloop "cares about" changed, and if the runloop
    /// is suspended, we resume it.
    /// Once the runloop encounters an error, e.g. producer throws or a cancellation is detected,
    /// it stops.
    private func runTheRunloop() async throws {
        while true {
            try Task.checkCancellation()

            // Check if we should read from producer
            let (shouldReadFromProducer, revision) = state.withLock { state in
                if state.shouldDrainProducer {
                    return (true, state.revision)
                }

                return (!state.consumers.isEmpty && state.pendingMessage == nil, state.revision)
            }
            logger.log("\(self.logPrefix) runloop iteration, shouldReadFromProducer=\(shouldReadFromProducer), revision=\(revision)")

            if shouldReadFromProducer {
                let message: XPCResponseMessage? = try await self.logger.logLifetime("producer next", logPrefix: self.logPrefix) {
                    try await self.producer.next()
                }

                guard let message else {
                    logger.log("\(self.logPrefix) producer finished")
                    break
                }

                guard let requestId = message.subrequestId else {
                    logger.error("\(self.logPrefix) response missing subrequestId, ignoring message=\(String(describing: message))")
                    continue
                }

                logger.log("\(self.logPrefix) producer returned a message, requestId=\(requestId)")

                try Task.checkCancellation()

                // We have a message, do we have a consumer waiting for it? If not - save it as pending message.
                let consumerToResume = state.withLock { state in
                    let isRequestCanceled = state.canceledRequestIds.contains(requestId)

                    let consumerToResume = state.consumers.removeValue(forKey: requestId)

                    if consumerToResume == nil && !isRequestCanceled && !state.shouldDrainProducer {
                        logger.log("\(self.logPrefix) saving pending message, requestId=\(requestId)")
                        // We don't have a consumer for this message and this request hasn't been canceled.
                        // We should keep the message as pending until we get a consumer.
                        // Or until the request gets canceled, in which case the pendingMessage will get
                        // set to nil in `cancel(requestId:)`.
                        assert(state.pendingMessage == nil)
                        state.pendingMessage = message
                    }

                    return consumerToResume
                }

                if let consumerToResume {
                    logger.log("\(self.logPrefix) consumer resume, requestId=\(requestId)")
                    consumerToResume.fire(message)
                }
            } else {
                // No consumers or we have a pending message.

                // Since we started the iteration, it's possible that something in the
                // state may have changed, e.g. new consumer or a canceled subrequest.
                // If that's the case, then we need to run another iteration.
                // If nothing has changed, then we can suspend the runloop until something
                // changes and resumes the runloop.
                let event: AsyncEvent<Void>? = self.state.withLock {
                    $0.createEventForRunloopToWaitForIfNeeded(revisionAtIterationStart: revision)
                }
                if let event {
                    logger.log("\(self.logPrefix) will suspend runloop, revision=\(revision)")
                    try await event()
                    logger.log("\(self.logPrefix) did resume runloop, revision=\(revision)")
                } else {
                    // This means something in the state has changed since this iteration
                    // started and we should run another iteration now before possibly suspending.
                    logger.log("\(self.logPrefix) will do another iteration without suspension, revision=\(revision)")
                }
            }
        }
    }

    func cancel(requestId: RequestId) {
        logger.log("\(self.logPrefix) cancel, requestId=\(requestId)")
        let consumerToCancel = self.state.withLock { state in
            _ = state.canceledRequestIds.insert(requestId)
            if state.pendingMessage?.subrequestId == requestId {
                state.pendingMessage = nil
            }
            return state.consumers.removeValue(forKey: requestId)
        }
        if let consumerToCancel {
            consumerToCancel.fire(throwing: CancellationError())
        }
    }

    /// Caller will remain suspended until producer produces a messages for the given request id. If
    /// producer produce a message, but there is no consumer for the given requestId, all consumers
    /// will remain suspended until there is a consumer reading it.
    func next(requestId: RequestId) async throws -> XPCResponseMessage {
        logger.log("\(self.logPrefix) next, requestId=\(requestId)")
        defer {
            logger.log("\(self.logPrefix) next returned, requestId=\(requestId)")
        }

        let asyncEvent = AsyncEvent<XPCResponseMessage>()

        state.withLock { state in
            if state.canceledRequestIds.contains(requestId) {
                asyncEvent.fire(throwing: CancellationError())
            } else if let result = state.runloopResult {
                self.logger.warning("\(self.logPrefix) received new consumer after runloop ended, result=\(String(describing: result))")
                switch result {
                case .success:
                    asyncEvent.fire(throwing: PrivateCloudComputeError(code: .connectionNoLongerRunning))
                case .failure(let error):
                    asyncEvent.fire(throwing: error)
                }
            } else if let pendingMessage = state.pendingMessage, pendingMessage.subrequestId == requestId {
                asyncEvent.fire(pendingMessage)
                state.pendingMessage = nil
            } else {
                if state.consumers[requestId] != nil {
                    asyncEvent.fire(throwing: PrivateCloudComputeError(code: .internalError))
                } else {
                    state.consumers[requestId] = asyncEvent
                }
            }
        }

        return try await asyncEvent()
    }
}
