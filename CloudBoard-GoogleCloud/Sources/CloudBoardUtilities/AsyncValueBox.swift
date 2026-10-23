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

import Atomics
import Foundation
import NIOConcurrencyHelpers

public struct AsyncValueBox<Boxed: Sendable>: Sendable {
    struct DoublePutError: Error {
    }

    enum Waiter {
        case cancelled
        case suspended(CheckedContinuation<Boxed, any Error>)
    }

    struct State {
        var value: Boxed?
        var waitingConsumers = [Int: Waiter]()
    }

    let state: NIOLockedValueBox<State>
    let waiterIDs: ManagedAtomic<Int>

    public init() {
        self.state = NIOLockedValueBox(State())
        self.waiterIDs = ManagedAtomic(0)
    }

    enum PutAction {
        case send(to: [CheckedContinuation<Boxed, any Error>])
        case doNothing
    }

    /// Sets the value in the box, waking up all suspended `get()` calls.
    ///
    /// The first call to `put()` succeeds and stores the value. Any subsequent calls to `put()` are ignored.
    /// This is a fire-once semantics: only the first value wins.
    ///
    /// When `put()` is called, all tasks waiting on `get()` are immediately woken up with the boxed value.
    /// If additional `get()` calls arrive after `put()`, they will receive the same value immediately
    /// without blocking.
    ///
    /// - Parameter value: The value to store in the box. Must be `Sendable`.
    ///   Important: Avoid storing values that require lifecycle management (e.g., resources that need cleanup),
    ///   since the value may be shared with multiple `get()` callers and there's no clear ownership semantics
    ///   for resource cleanup.
    /// - Returns: `true` if this was the first put and the value was stored; `false` if the box
    ///   already had a value and this call was ignored (fire-once semantics).
    @discardableResult
    public func put(_ value: Boxed) -> Bool {
        let action = self.state.withLockedValue { state in
            if state.value == nil {
                state.value = value
                var newWaiters = [Int: Waiter]()
                var suspendedWaiters = [CheckedContinuation<Boxed, any Error>]()
                for (waiterID, waiter) in state.waitingConsumers {
                    switch waiter {
                    case .cancelled:
                        // Cancelled waiters are only in the dictionary temporarily
                        // while the `withTaskCancellationHandler` resolves
                        // we need to preserve them in the newWaiters
                        newWaiters[waiterID] = .cancelled
                    case .suspended(let continuation):
                        suspendedWaiters.append(continuation)
                    }
                }
                state.waitingConsumers = newWaiters
                return PutAction.send(to: suspendedWaiters)
            } else {
                // Ignore secondary puts, but assert that there are no waiting consumers
                precondition(
                    {
                        let suspendedWaiters = state.waitingConsumers.filter { (_, waiter) in
                            switch waiter {
                            case .cancelled:
                                return false
                            case .suspended:
                                return true
                            }
                        }
                        return suspendedWaiters.isEmpty

                    }()
                )

                return PutAction.doNothing
            }
        }

        switch action {
        case .send(to: let consumers):
            for consumer in consumers {
                consumer.resume(returning: value)
            }
            return true
        case .doNothing:
            return false
        }
    }

    enum GetAction {
        case take(value: Boxed)
        case suspend
        case cancel(CheckedContinuation<Boxed, any Error>)
    }

    /// Retrieves the value from the box, waiting if necessary for it to be set.
    ///
    /// If a value has already been set via `put()`, `get()` returns immediately with that value.
    /// If no value has been set yet, `get()` suspends the current task and waits for `put()` to be called.
    ///
    /// Multiple calls to `get()` are allowed and encouraged. All callers—whether they arrive before or after
    /// `put()`—will receive the same value. This makes `AsyncValueBox` useful for one-time initialization
    /// scenarios where many tasks need to wait for a single value.
    ///
    /// - Returns: The value stored in the box via a `put()` call.
    ///
    /// - Important: Do not store values that require lifecycle management (e.g., database connections,
    ///   file handles, or other resources that need cleanup). Since the boxed value is shared among all
    ///   `get()` callers with no clear ownership semantics, there's no well-defined point for cleanup.
    ///   This is best used for immutable configuration values or simple data structures.
    public func `get`() async throws -> Boxed {
        // Get a unique id first
        let waiterID = self.waiterIDs.loadThenWrappingIncrement(ordering: .relaxed)
        defer {
            self.state.withLockedValue { state in
                guard let waiter = state.waitingConsumers[waiterID] else {
                    return
                }
                switch waiter {
                case .cancelled:
                    // Occasionally we end up leaking `.cancelled` in the
                    // `withTaskCancellationHandler` below. Clean this up here.
                    state.waitingConsumers[waiterID] = nil
                case .suspended:
                    fatalError("We've leaked continuation")
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action: GetAction = self.state.withLockedValue { state in
                    // Check if the `get` got cancelled first
                    if let cancelledWaiter = state.waitingConsumers[waiterID] {
                        switch cancelledWaiter {
                        case .cancelled:
                            state.waitingConsumers[waiterID] = nil
                            return .cancel(continuation)
                        case .suspended:
                            fatalError("Suspended waiter found for \(waiterID), before we put it there")
                        }
                    }

                    // Otherwise we need to either suspend or take the value if it's already present
                    guard let value = state.value else {
                        state.waitingConsumers[waiterID] = .suspended(continuation)
                        return .suspend
                    }

                    return .take(value: value)
                }
                switch action {
                case .take(let value):
                    continuation.resume(returning: value)
                case .suspend:
                    break
                case .cancel(let continuation):
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Boxed, any Error>?
            continuation = self.state.withLockedValue { state in
                // We're racing with the `withCheckedThrowingContinuation` section above
                // if we win, we need to put `.cancelled` marker in the state
                // if they win, we take the continuation out and resume it ourselves
                guard let waiter = state.waitingConsumers[waiterID] else {
                    state.waitingConsumers[waiterID] = .cancelled
                    return nil
                }

                switch waiter {
                case .cancelled:
                    // NOTE: it appears like `onCancel` can fire multiple
                    //       times for a single invocation of
                    //       `withTaskCancellationHandler`. We cannot therefore
                    //       assert that waiter isn't already .cancelled.
                    //       Also, we might end up "leaking" `.cancelled` here
                    //       we clean that up in the defer block above
                    return nil
                case .suspended(let continuation):
                    state.waitingConsumers[waiterID] = nil
                    return continuation
                }
            }
            if let continuation = continuation {
                continuation.resume(throwing: CancellationError())
            }
        }
    }
}

public struct AsyncThrowingValueBox<Boxed: Sendable>: Sendable {
    let resultBox: AsyncValueBox<Result<Boxed, any Error>>

    public init() {
        self.resultBox = AsyncValueBox()
    }

    public func put(_ value: Boxed) {
        self.resultBox.put(.success(value))
    }

    public func fail(_ error: any Error) {
        self.resultBox.put(.failure(error))
    }

    public func `get`() async throws -> Boxed {
        try await self.resultBox.get().get()
    }
}
