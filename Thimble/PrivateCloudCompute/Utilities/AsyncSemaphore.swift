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
//  AsyncSemaphore.swift
//  PrivateCloudCompute
//
//  Copyright © 2025 Apple Inc. All rights reserved.
//

import Synchronization

/// Like a regular semaphore, but async.
///
/// - Warning: Just like a regular semaphore, an `AsyncSemaphore` does not handle priority escalation, because it doesn't know what `Task` is going to ``signal()`` an adopter in ``wait()``. Consider if it's worth investing in a better design that allows for priority escalation in your use-case.
///
/// - SeeAlso: `DispatchSemaphore`
///
/// Sample usage:
///
/// ```swift
/// let sema = AsyncSemaphore(value: 2)
/// await sema() // Immediately completes - synonym for below
/// await sema.wait() // Immediately completes - synonym for above
/// _ = Task {
///     ... do some stuff
///     sema.signal()
/// }
/// await sema() // suspends the current task until the above unstructured task signals the semaphore.
/// ```
///
/// To get a timeout-respecting ``wait()`` behavior, compose alongside ``withCancellationTimeout(after:tolerance:name:executorPreference:priority:isolation:operation:)``:
///
/// ```swift
/// let sema = AsyncSemaphore(value: 0)
/// try await withCancellationTimeout(after: .secords(60)) {
///     await sema()
/// }
/// // After 60 seconds without a signal, this will throw a `CancellationError`
/// ```
package final class AsyncSemaphore: Sendable {
    private final class Waiter: Sendable, Equatable {
        let event: AsyncEvent<Void>
        let _priority: Atomic<UInt8>
        var priority: TaskPriority {
            get {
                let rawValue = self._priority.load(ordering: .acquiring)
                return TaskPriority(rawValue: rawValue)
            }
            set {
                let rawValue = newValue.rawValue
                self._priority.store(rawValue, ordering: .releasing)
            }
        }

        init(event: AsyncEvent<Void>, priority: TaskPriority) {
            self.event = event
            self._priority = .init(priority.rawValue)
        }

        static func == (lhs: Waiter, rhs: Waiter) -> Bool {
            return lhs === rhs
        }
    }

    private struct State: ~Copyable {
        var value: Int
        var waiters: [Waiter] = []
    }

    private let stateMutex: Mutex<State>
    /// Creates new async counting semaphore with an initial value.
    ///
    /// - Passing 0 for the value is useful for when two Tasks need to reconcile the completion of a particular event.
    /// - Passing a value greater than 0 is useful for managing a finite pool of resources, where the pool size is equal to the value.
    /// - Passing a value less than 0 is not allowed, and the implementation will `fatalError()`
    ///
    /// - Parameter value: The starting value for the semaphore.
    package init(value: Int = 0) {
        precondition(value >= 0)
        self.stateMutex = Mutex(State(value: value))
    }

    /// Syntactic Sugar for calling ``wait()``
    ///
    /// Sample usage:
    ///
    /// ```swift
    /// let sema = AsyncSemaphore(value: 2)
    /// await sema()
    /// ```
    nonisolated(nonsending) package func callAsFunction() async throws {
        try await self.wait()
    }

    /// Waits for, or decrements, an async semaphore.
    ///
    /// Decrement the async counting semaphore. If the resulting value is less than 0, this function awaits a signal before returning.
    ///
    /// To get a timeout-respecting ``wait()`` behavior, compose alongside ``withCancellationTimeout(after:tolerance:name:executorPreference:priority:isolation:operation:)``:
    ///
    /// ```swift
    /// let sema = AsyncSemaphore(value: 0)
    /// try await withCancellationTimeout(after: .secords(60)) {
    ///     await sema.wait()
    /// }
    /// // After 60 seconds without a signal, this will throw a `CancellationError`
    /// ```
    nonisolated(nonsending) package func wait() async throws {
        try Task.checkCancellation()

        let waiter: Waiter? = self.stateMutex.withLock { state in
            state.value -= 1

            if state.value >= 0 {
                return nil
            }

            let waiter = Waiter(
                event: AsyncEvent<Void>(),
                priority: Task.currentPriority
            )
            state.waiters.append(waiter)
            return waiter
        }

        guard let waiter else {
            if Task.isCancelled {
                // We were cancelled sometime between decrementing our value and now. Unwind that decrement and throw
                self.stateMutex.withLock { state in
                    state.value += 1
                }
                try Task.checkCancellation()
            }
            return
        }

        // Critical to not check for Task cancellation at this point in the function.
        // (Or at least, to not throw if the Task was cancelled).
        // We've added a waiter to our waiter list, and have decremented our value. We need to ensure there's a task cancellation handler in place that unwinds that decrement.
        try await withTaskCancellationHandler {
            try await withTaskPriorityEscalationHandler {
                try await waiter.event()
            } onPriorityEscalated: { [weak waiter] _, newPriority in
                // If waiter dealloced, it has necessarily been removed from self.waiters, and there's nothing to be done here.
                guard let waiter else { return }

                self.stateMutex.withLock { state in
                    let waiterIndex = state.waiters.firstIndex(of: waiter)
                    if let waiterIndex {
                        state.waiters[waiterIndex].priority = newPriority
                    }
                }
            }
        } onCancel: {
            self.stateMutex.withLock { [weak waiter] state in
                // If waiter dealloced, it has necessarily been removed from self.waiters, and there's nothing to be done here.
                guard let waiter else { return }

                let waiterIndex = state.waiters.firstIndex(of: waiter)
                if let waiterIndex {
                    state.waiters.remove(at: waiterIndex)
                    // Offset the decrement from wait()
                    // Don't wake up anyone else, since the fact that we were in the waiters list meant the semaphore was still negative, and removing ourselves wouldn't suddenly free up a slot for a different waiter.
                    state.value += 1
                }
            }
        }
    }

    /// Signals (increments) an async semaphore.
    ///
    /// - Returns: `true` if this signal resumed an awaiting `Task`, else `false`
    ///
    /// Increment the async counting semaphore. Wakes an awaiting `Task` if the resulting semaphore's value is `<= 0`.
    @discardableResult
    package func signal() -> Bool {
        let waiter: Waiter? = self.stateMutex.withLock { state in
            state.value += 1

            if state.value <= 0 {
                var highestPriorityInfo: (index: Int, priority: TaskPriority)?
                for (i, waiter) in state.waiters.enumerated() {
                    if let highestPriorityInfo {
                        guard waiter.priority > highestPriorityInfo.priority else {
                            continue
                        }
                    }
                    highestPriorityInfo = (i, waiter.priority)
                }
                if let highestPriorityInfo {
                    let waiter = state.waiters.remove(at: highestPriorityInfo.index)
                    return waiter
                } else {
                    precondition(state.waiters.isEmpty, "We have non-empty waiters, but couldn't determine the highest-priority one.")
                }
            }
            return nil
        }

        waiter?.event.fire()
        return waiter != nil
    }

    /// For testing.
    var value: Int {
        self.stateMutex.withLock { $0.value }
    }
}
