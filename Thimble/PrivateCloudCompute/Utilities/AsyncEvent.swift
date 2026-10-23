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
//  AsyncEvent.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import Synchronization

/// A type that accepts an `Event` from any source, and broadcasts it to any number of waiters.
///
/// A chief use of this type is to bridge between an unstructured event producer, and 0...N Structured Concurrency consumers.
///
/// Handles consumers awaiting a result before, during, or after the producer fires it.
///
/// Sample usage:
///
/// ```swift
/// let myFooEvent = AsyncEvent<Int>()
/// _ = Task {
///     ... do some stuff
///     myFooEvent.fire(1234)
/// }
/// let foo = try await myFooEvent() // returns 1234
/// ```
///
/// Note that awaiting an event is a `throw`-ing action.  If the producer throws, the error is propagated to all waiters:
///
/// ```swift
/// let myFooEvent = AsyncEvent<Int>()
/// _ = Task {
///     throw MyError()
/// }
/// let foo = try await myFooEvent() // throws MyError()
/// ```
///
/// Even if the producer is non-throwing, a task cancellation will cause all waiters to receive a `CancellationError()`
///
/// ```swift
/// let myFooEvent = AsyncEvent<Int>()
/// _ = Task {
///     ... do some stuff
///     myFooEvent.fire(1234)
/// }
/// withUnsafeCurrentTask { $0.cancel() }
/// let foo = try await myFooEvent() // throws CancellationError()
/// ```
package final class AsyncEvent<Success: Sendable>: Sendable {

    private typealias Continuation = CheckedCancellableContinuation<Success>

    /// Tracks the overall state of the `AsyncEvent`
    ///
    /// That overall state is either
    /// - continuations that are waiting on a result to be given, or
    /// - the result that has been given.
    /// Once we have a result we're done accumulating continuations.
    private enum EventState {
        /// The event is waiting for the producer to fire an event.
        ///
        /// Has an associated value of all the continuations waiting for that fire.
        case waiting([Continuation])

        /// The event has received a fired result from the producer
        ///
        /// Has an associated value of that fired result.
        case completed(Result<Success, any Error>)

        init() {
            self = .waiting([])
        }

        /// Action a caller should take after calling ``wait(with:)``
        enum WaitAction {
            case resume(Result<Success, any Error>)
        }

        /// Adds a new continuation to an `AsyncEvent`
        ///
        /// - Returns: The action, if any, a caller should take.
        mutating func wait(with continuation: Continuation) -> WaitAction? {
            switch self {
            case .waiting(var continuations):
                continuations.append(continuation)
                self = .waiting(continuations)  // .waiting <- .waiting
                return nil
            case .completed(let result):
                // In between
                // - `ReceiveState.runOrDefer` determining "we need to wait for the EventState", and
                // - `EventState.wait` being called,
                // the event state was completed.
                //
                // That's a reasonable race condition that should be accommodated
                return .resume(result)
            }
        }

        /// Action a caller should take after calling ``complete(_:)``
        enum CompleteAction {
            case resume(continuations: [Continuation], result: Result<Success, any Error>)
        }

        /// Transitions the ``EventState`` to ``completed``, resuming any existing continuations with the given `Result`.
        ///
        /// - Returns: The action, if any, a caller should take.
        ///
        /// This is legal to call at any time.
        mutating func complete(_ result: Result<Success, any Error>) -> CompleteAction? {
            switch self {
            case .waiting(let continuations):
                self = .completed(result)  // .completed <- .waiting
                return .resume(continuations: continuations, result: result)
            case .completed:
                return nil
            }
        }
    }

    private let eventState = Mutex<EventState>(.init())

    package init() {}

    /// Gives the `AsyncEvent` a successful result, which may be reported to any receivers.
    ///
    /// - Parameter value: The value to propagate to any receivers.
    /// - Returns: `true` if this is the first result fired on this event; `false` if the result is dropped.
    ///
    /// An `AsyncEvent` has a result buffer of 1.  Any additional calls to `fire(_:)` or ``fire(throwing:)`` are dropped.
    @discardableResult
    package func fire(_ value: Success) -> Bool {
        let action = self.eventState.withLock {
            $0.complete(.success(value))
        }
        switch action {
        case .resume(let continuations, let result):
            for continuation in continuations {
                continuation.resume(with: result)
            }
            return true
        case .none:
            return false
        }
    }

    /// Gives the `AsyncEvent` a failed result, which may be thrown to any receivers.
    ///
    /// - Parameter value: The error to throw when a receiver `await`s this event.
    /// - Returns: `true` if this is the first result fired on this event; `false` if the result is dropped.
    ///
    /// An `AsyncEvent` has a result buffer of 1.  Any additional calls to ``fire(_:)`` or `fire(throwing:)` are dropped.
    @discardableResult
    package func fire(throwing error: any Error) -> Bool {
        let action = self.eventState.withLock {
            $0.complete(.failure(error))
        }
        switch action {
        case .resume(let continuations, let result):
            for continuation in continuations {
                continuation.resume(with: result)
            }
            return true
        case .none:
            return false
        }
    }

    /// Tracks the state of a single call to `receive()`
    ///
    /// Coordinates between the event producing a value, and the receiving `Task` being cancelled.
    ///
    /// Each call to `receive()` is tracked by a separate `ReceiveState`
    private struct ReceiveState {
        /// Tracks the progress of a `ReceiveState` calling `resume` on its `Continuation`
        ///
        /// A `ReceiveState` wraps a `CheckedCancellableContinuation`, which must be resumed exactly once, and can be cancelled any number of times.
        /// A `ReceiveState.RunState` tracks the continuation along its resume path.
        ///
        /// All `ReceiveState.RunState`s are expected to proceed either `.initialized` -> `.completed`, or `.initialized` -> `.waiting` -> `.completed`.
        private enum RunState {
            /// The instance hasn't run.
            case initialized

            /// The instance is waiting for the event to produce a value.
            case waiting(Continuation)

            /// The instance has finished waiting for the event to produce a value.
            case completed
        }

        private var runState = RunState.initialized
        private var hasBeenCancelled = false

        /// Action a caller should take after calling ``runOrWait(eventState:continuation:)``
        enum RunOrWaitAction {
            case resume(Continuation, Result<Success, any Error>)
            case cancel(Continuation)
        }

        /// The main logic of a `ReceiveState`
        ///
        /// - Returns: The action, if any, a caller should take.
        mutating func runOrWait(eventState: inout EventState, continuation: Continuation) -> RunOrWaitAction? {
            guard case .initialized = runState else {
                preconditionFailure("An AsyncEvent.ReceiveState may only be runOrWait-ed once")
            }

            // Simple case: we have an event result ready-to-go:
            if case .completed(let result) = eventState {
                self.runState = .completed  // .completed <- .initialized

                return .resume(continuation, result)
            }

            // More complicated case: no event result ready-to-go, so we'll mark ourselves as waiting, and register ourselves with the event.
            self.runState = .waiting(continuation)  // .waiting <- .initialized

            let action = eventState.wait(with: continuation)

            // In between deciding we needed to wait for an event result, and successfully registering our continuation, it's possible the Event had a result fired on it.
            // In that scenario, this receive state should complete as asked.
            if case .resume(let result) = action {
                self.runState = .completed  // .completed <- .waiting

                return .resume(continuation, result)
            }

            // If we got here, then we're truly waiting for an event result.

            // If we were cancelled before getting to runOrWait, then we didn't cancel our continuation at cancel-time.
            // Check for that case, and propagate out a cancel action if necessary.
            if self.hasBeenCancelled {
                return .cancel(continuation)
            }

            // Nothing to do but sit around and wait for that event result.
            return nil
        }

        /// Action a caller should take after calling ``cancel(eventState:)``
        enum CancelAction {
            /// Cancel the associated `Continuation`
            case cancel(Continuation)
        }

        /// Marks the `ReceiveState` as having been cancelled.
        ///
        /// - Returns: The action, if any, a caller should take.
        ///
        /// If the `ReceiveState` was waiting on a continuation, the caller will be asked to cancel the continuation.
        mutating func cancel(eventState: EventState) -> CancelAction? {
            self.hasBeenCancelled = true
            if case .waiting(let continuation) = self.runState {
                // Note that we do not change `runState` here.
                // `runState` tracks our progress towards calling `resume` on the continuation, and that's orthogonal to calling `cancel` on it.
                return .cancel(continuation)
            }
            return nil
        }
    }

    private func receive() async throws -> Success {
        let receiveState = Mutex<ReceiveState>(.init())
        return try await withTaskCancellationHandler {
            return try await withCheckedCancellableContinuation { continuation in
                let action = self.eventState.withLock { eventState in
                    receiveState.withLock {
                        $0.runOrWait(eventState: &eventState, continuation: continuation)
                    }
                }
                switch action {
                case .resume(let actionContinuation, let actionResult):
                    actionContinuation.resume(with: actionResult)
                case .cancel(let actionContinuation):
                    actionContinuation.cancel()
                case .none:
                    break
                }
            }
        } onCancel: {
            let action = self.eventState.withLock { eventState in
                receiveState.withLock {
                    $0.cancel(eventState: eventState)
                }
            }
            switch action {
            case .cancel(let actionContinuation):
                actionContinuation.cancel()
            case .none:
                break
            }
        }
    }

    /// Awaits the result of this `AsyncEvent`
    ///
    /// If the `AsyncEvent` has already been `fire()`d, this returns the `fire()`d value, or throws the producer-fired `Error`.
    ///
    /// If the `AsyncEvent` has not yet been `fire()`d, this `await`s the event firing before returning.
    ///
    /// - Returns: the value `fire`d on the `AsyncEvent`
    /// - Throws:
    ///     - the error `fire`d on the `AsyncEvent`, or
    ///     - `CancellationError`: when the calling `Task` is cancelled
    package func callAsFunction() async throws -> Success {
        try await self.receive()
    }
}

extension AsyncEvent where Success == Void {
    /// Gives the `AsyncEvent` a successful `Void()` result, which may be reported to any receivers.
    ///
    /// - Returns: `true` if this is the first result fired on this event; `false` if the result is dropped.
    ///
    /// An `AsyncEvent` has a result buffer of 1.  Any additional calls to `fire()` or ``fire(throwing:)`` are dropped.
    @discardableResult
    package func fire() -> Bool {
        return self.fire(())
    }
}
