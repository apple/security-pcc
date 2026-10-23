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

import DequeModule
import Synchronization

/// A `~Copyable` wrapper around `UnsafeContinuation` that guarantees exactly-once resumption.
///
/// - `consuming func resume()` resumes the continuation and discards `self` without running `deinit`.
/// - `consuming func resumeWithError(_:)` resumes with a thrown error and discards `self`.
/// - `deinit` traps if the continuation is dropped without being resumed.
/// - Because the type is `~Copyable`, double-resume is a compile-time error.
private struct OneshotThrowingContinuation: ~Copyable {
    private var continuation: UnsafeContinuation<Void, any Error>

    init(_ continuation: UnsafeContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    consuming func resume() {
        continuation.resume()
        discard self
    }

    consuming func resumeWithError(_ error: any Error) {
        continuation.resume(throwing: error)
        discard self
    }

    deinit {
        // Safety net: trap if dropped without resuming. The compiler may warn
        // that this is unreachable when all consuming paths use `discard self`,
        // but the deinit must exist for `discard self` to compile.
        let unreachable: Bool? = nil
        guard let _ = unreachable else {
            fatalError("OneshotThrowingContinuation dropped without being resumed")
        }
    }
}

/// Suspends the current task and provides a waiter ID and a pointer to an
/// initialized `OneshotThrowingContinuation` to the `body` closure.
///
/// The pointer is stack-allocated via `withUnsafeTemporaryAllocation`. The
/// closure **must** consume the pointee on every path — either by calling
/// `ptr.move().resume()` / `ptr.move().resumeWithError(_:)` or by moving
/// ownership elsewhere (e.g. into a deque). `OneshotThrowingContinuation`
/// enforces this: dropping it without calling resume triggers a fatal error,
/// and double-resume is a compile-time error (the type is `~Copyable`).
///
/// A pointer is used rather than passing the continuation directly because
/// `Mutex.withLock` takes a `@Sendable` (and therefore escaping) closure,
/// and `~Copyable` values cannot be captured by escaping closures.
private func withOneshotContinuation(
    id: UInt64,
    _ body: (UnsafeMutablePointer<OneshotThrowingContinuation>) -> Void
) async throws {
    try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
        withUnsafeTemporaryAllocation(of: OneshotThrowingContinuation.self, capacity: 1) { buf in
            let ptr = buf.baseAddress!
            ptr.initialize(to: OneshotThrowingContinuation(continuation))
            body(ptr)
        }
    }
}

/// An async-compatible counting semaphore with cancellation support.
///
/// Uses `Synchronization.Mutex` for thread-safe state management. Waiters are
/// resumed in FIFO order via a `UniqueDeque`.
///
/// - `acquire()` suspends if no permits are available. Throws
///   `CancellationError` if the calling task is cancelled while waiting.
/// - `release()` either resumes the next waiter or increments the permit count.
final class AsyncSemaphore: Sendable {
    /// A waiter in the queue: either a live continuation waiting to be resumed,
    /// or a tombstone indicating that cancellation arrived before the waiter was
    /// enqueued.
    private enum Waiter: ~Copyable {
        case live(OneshotThrowingContinuation)
        case tombstone
    }

    private struct State: ~Copyable {
        var permits: Int
        var waiters: UniqueDeque<WaiterEntry>

        init(permits: Int) {
            self.permits = permits
            self.waiters = UniqueDeque()
        }
    }

    /// An entry in the waiter deque, pairing an ID with a waiter.
    private struct WaiterEntry: ~Copyable {
        var id: UInt64
        var waiter: Waiter

        var isLive: Bool {
            switch waiter {
            case .live: true
            case .tombstone: false
            }
        }

        init(id: UInt64, waiter: consuming Waiter) {
            self.id = id
            self.waiter = waiter
        }
    }

    private let state: Mutex<State>
    private let nextID = Atomic<UInt64>(0)

    init(permits: Int) {
        precondition(permits >= 0, "AsyncSemaphore permits must be non-negative")
        self.state = Mutex(State(permits: permits))
    }

    func acquire() async throws {
        // Fast path: try to decrement without suspending.
        let needsSuspend = state.withLock { state -> Bool in
            if state.permits > 0 {
                state.permits -= 1
                return false
            }
            return true
        }

        if !needsSuspend {
            // Even on the fast path, respect cancellation.
            try Task.checkCancellation()
            return
        }

        let waiterID = nextID.wrappingAdd(1, ordering: .relaxed).oldValue

        try await withTaskCancellationHandler {
            try await withOneshotContinuation(id: waiterID) { ptr in
                let action = state.withLock { state -> WaiterAction in
                    // Double-check: a permit may have become available.
                    if state.permits > 0 {
                        state.permits -= 1
                        return .resumeImmediately
                    }

                    // Check if cancellation arrived before we got here
                    // by scanning for a tombstone with our ID.
                    for i in state.waiters.indices {
                        if state.waiters[i].id == waiterID {
                            // Found our tombstone — remove it and cancel.
                            _ = state.waiters.remove(at: i)
                            return .cancelImmediately
                        }
                    }

                    // Enqueue the waiter.
                    state.waiters.append(
                        WaiterEntry(id: waiterID, waiter: .live(ptr.move()))
                    )
                    return .enqueued
                }

                switch action {
                case .resumeImmediately:
                    ptr.move().resume()
                case .cancelImmediately:
                    ptr.move().resumeWithError(CancellationError())
                case .enqueued:
                    break  // Ownership transferred to the deque.
                }
            }
        } onCancel: {
            // Take the lock and try to find our waiter.
            let continuation: OneshotThrowingContinuation? = state.withLock { state in
                // Search for our entry in the deque.
                for i in state.waiters.indices {
                    if state.waiters[i].id == waiterID {
                        let entry = state.waiters.remove(at: i)
                        switch consume entry.waiter {
                        case .live(let cont):
                            return cont
                        case .tombstone:
                            // Already handled — shouldn't happen but be safe.
                            return nil
                        }
                    }
                }
                // Not yet enqueued — leave a tombstone so acquire sees it.
                state.waiters.append(
                    WaiterEntry(id: waiterID, waiter: .tombstone)
                )
                return nil
            }
            continuation?.resumeWithError(CancellationError())
        }
    }

    func release() {
        let waiter: OneshotThrowingContinuation? = state.withLock { state in
            // Walk the deque looking for the first live waiter,
            // leaving tombstones in place for acquire to find.
            for i in state.waiters.indices {
                if state.waiters[i].isLive {
                    let entry = state.waiters.remove(at: i)
                    switch consume entry.waiter {
                    case .live(let cont):
                        return cont
                    case .tombstone:
                        fatalError("Unreachable: isLive was true")
                    }
                }
            }
            state.permits += 1
            return nil
        }
        waiter?.resume()
    }
}

private enum WaiterAction {
    case resumeImmediately
    case cancelImmediately
    case enqueued
}
