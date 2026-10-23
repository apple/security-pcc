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

import CloudBoardDomain
import Foundation
import os
internal import Synchronization

/// Policy controlling what happens when a real response arrives after its query has already timed out.
package enum LateResponsePolicy: Sendable {
    /// Discard the late response — the caller already received a timeout error.
    case drop
    /// Forward the late response to the caller even though a timeout error was already emitted.
    case passThrough
}

/// Manages timeout deadlines for persistent service queries on a single service identity.
///
/// Queries are registered with a deadline computed from their timeout duration.
/// A single timer task sleeps until the earliest deadline and synthesizes error
/// responses for queries that exceed it.  The manager is generic over `Clock` so
/// that tests can supply a deterministic clock.
package final class QueryTimeoutManager<C: Clock>: Sendable where C.Duration == Duration {
    // MARK: - Logger

    private static var logger: Logger {
        Logger(
            subsystem: "com.apple.cloudos.cloudboard",
            category: "QueryTimeoutManager"
        )
    }

    // MARK: - Deadline heap entry

    struct DeadlineEntry: Comparable, Sendable {
        let deadline: C.Instant
        let correlationID: PersistentService.QueryCorrelationID
        let querySentAt: Date

        static func < (lhs: DeadlineEntry, rhs: DeadlineEntry) -> Bool {
            lhs.deadline < rhs.deadline
        }

        static func == (lhs: DeadlineEntry, rhs: DeadlineEntry) -> Bool {
            lhs.deadline == rhs.deadline && lhs.correlationID == rhs.correlationID
        }
    }

    // MARK: - Min-heap

    // Note: Importing HeapModule from swift-collections results in duplicate
    // symbol issues that break the linker, so we use a hand-rolled min-heap.

    struct MinHeap: Sendable {
        private var storage: [DeadlineEntry] = []

        var isEmpty: Bool { self.storage.isEmpty }
        var count: Int { self.storage.count }

        func peek() -> DeadlineEntry? { self.storage.first }

        mutating func push(_ element: DeadlineEntry) {
            self.storage.append(element)
            self.siftUp(from: self.storage.count - 1)
        }

        @discardableResult
        mutating func pop() -> DeadlineEntry? {
            guard !self.storage.isEmpty else { return nil }
            if self.storage.count == 1 { return self.storage.removeLast() }
            let top = self.storage[0]
            self.storage[0] = self.storage.removeLast()
            self.siftDown(from: 0)
            return top
        }

        private mutating func siftUp(from index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard self.storage[child] < self.storage[parent] else { break }
                self.storage.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from index: Int) {
            var parent = index
            let count = self.storage.count
            while true {
                let left = 2 * parent + 1
                let right = 2 * parent + 2
                var smallest = parent
                if left < count, self.storage[left] < self.storage[smallest] { smallest = left }
                if right < count, self.storage[right] < self.storage[smallest] { smallest = right }
                guard smallest != parent else { break }
                self.storage.swapAt(parent, smallest)
                parent = smallest
            }
        }
    }

    // MARK: - State

    private struct State: Sendable {
        var lateResponsePolicy: LateResponsePolicy
        var heap = MinHeap()
        var activeQueries = Set<PersistentService.QueryCorrelationID>()
        var timedOutQueries = Set<PersistentService.QueryCorrelationID>()
        var respondedQueries = Set<PersistentService.QueryCorrelationID>()
        var timerTask: Task<Void, Never>?
        /// Incremented each time a new timer task is created. Timer tasks check this
        /// to detect they've been superseded and exit, preventing orphaned tasks.
        var timerGeneration: UInt64 = 0
    }

    private let clock: C
    private let lock: Mutex<State>

    private let timeoutContinuation: AsyncStream<PersistentService.Response>.Continuation
    /// Stream of synthesized timeout responses.  Consumers should merge this with
    /// the real response stream from the inner client.
    package let timeoutResponses: AsyncStream<PersistentService.Response>

    // MARK: - Init

    package init(clock: C, lateResponsePolicy: LateResponsePolicy = .drop) {
        self.clock = clock
        let (stream, continuation) = AsyncStream<PersistentService.Response>.makeStream()
        self.timeoutResponses = stream
        self.timeoutContinuation = continuation
        self.lock = Mutex(State(lateResponsePolicy: lateResponsePolicy))
    }

    package func setLateResponsePolicy(_ policy: LateResponsePolicy) {
        self.lock.withLock { $0.lateResponsePolicy = policy }
    }

    deinit {
        let task = self.lock.withLock { state -> Task<Void, Never>? in
            let t = state.timerTask
            state.timerTask = nil
            return t
        }
        task?.cancel()
        timeoutContinuation.finish()
    }

    // MARK: - Registration

    /// Register a query with an optional timeout.  If `timeout` is `nil` the query
    /// is not tracked and will never time out.
    package func registerQuery(
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration?,
        querySentAt: Date
    ) {
        guard let timeout else { return }

        let deadline = self.clock.now.advanced(by: timeout)
        let entry = DeadlineEntry(
            deadline: deadline,
            correlationID: correlationID,
            querySentAt: querySentAt
        )
        self.lock.withLock { state in
            state.activeQueries.insert(correlationID)
            state.heap.push(entry)
        }

        // If this is earlier than the current timer target, restart.
        self.rescheduleTimerIfNeeded()
    }

    // MARK: - Response processing

    /// Process a real response from the persistent service.
    ///
    /// - Returns: The response to forward to the caller, or `nil` if it should be dropped.
    package func processRealResponse(
        _ response: PersistentService.Response
    ) -> PersistentService.Response? {
        self.lock.withLock { state in
            let id = response.correlationID

            if state.activeQueries.remove(id) != nil {
                // Arrived before timeout — mark as responded so the heap entry is skipped.
                state.respondedQueries.insert(id)
                return response
            }

            if state.timedOutQueries.remove(id) != nil {
                // Late arrival — policy decides.
                switch state.lateResponsePolicy {
                case .drop:
                    return nil
                case .passThrough:
                    return response
                }
            }

            // Unknown correlation ID — query had no timeout, pass through.
            return response
        }
    }

    // MARK: - Cancellation

    /// Cancel all pending timeouts.  No further timeout responses will be emitted.
    package func cancelAll() {
        let task = self.lock.withLock { state -> Task<Void, Never>? in
            state.activeQueries.removeAll()
            let t = state.timerTask
            state.timerTask = nil
            return t
        }
        // Cancel and finish outside the lock to avoid deadlock with consumers.
        task?.cancel()
        self.timeoutContinuation.finish()
    }

    // MARK: - Timer

    private func rescheduleTimerIfNeeded() {
        // Atomically: find the earliest deadline, cancel the old timer, and claim a
        // new generation. This prevents two concurrent registerQuery calls from both
        // creating timer tasks (the loser's task will see a stale generation and exit).
        let (earliest, generation): (DeadlineEntry?, UInt64) = self.lock.withLock { state in
            // Skip responded entries at the top.
            while let top = state.heap.peek(), state.respondedQueries.contains(top.correlationID) {
                _ = state.heap.pop()
                state.respondedQueries.remove(top.correlationID)
            }
            guard let earliest = state.heap.peek() else {
                return (nil, 0)
            }
            state.timerGeneration &+= 1
            state.timerTask?.cancel()
            state.timerTask = nil
            return (earliest, state.timerGeneration)
        }
        guard let earliest else { return }

        let newTask = Task { [weak self, clock] in
            var nextDeadline = earliest.deadline
            while !Task.isCancelled {
                do {
                    try await clock.sleep(until: nextDeadline, tolerance: .zero)
                } catch {
                    return // Cancelled
                }
                guard let self else { return }
                // Check if we've been superseded by a newer timer
                let isStale = self.lock.withLock { $0.timerGeneration != generation }
                if isStale { return }
                guard let next = self.fireExpiredEntries() else { return }
                nextDeadline = next
            }
        }

        self.lock.withLock { state in
            if state.timerGeneration == generation {
                state.timerTask = newTask
            } else {
                // Another call already superseded us — cancel our task
                newTask.cancel()
            }
        }
    }

    /// Pop and fire all expired entries.  Returns the next deadline to sleep to, or `nil` if the heap is empty.
    ///
    /// Collects responses under the lock, then yields them outside the lock to avoid
    /// deadlock with consumers that might call back into this manager.
    private func fireExpiredEntries() -> C.Instant? {
        var responsesToYield: [PersistentService.Response] = []

        let nextDeadline: C.Instant? = self.lock.withLock { state in
            let now = self.clock.now
            while let top = state.heap.peek() {
                // Lazy deletion of responded queries.
                if state.respondedQueries.contains(top.correlationID) {
                    _ = state.heap.pop()
                    state.respondedQueries.remove(top.correlationID)
                    continue
                }
                guard top.deadline <= now else { break }
                _ = state.heap.pop()

                // Only fire if still active.
                if state.activeQueries.remove(top.correlationID) != nil {
                    state.timedOutQueries.insert(top.correlationID)
                    responsesToYield.append(PersistentService.Response(
                        correlationID: top.correlationID,
                        payload: .error(.init(
                            code: PersistentServiceQueryErrorCode.timeout.rawValue,
                            message: "Persistent service query timed out"
                        )),
                        querySentAt: top.querySentAt
                    ))
                }
            }
            return state.heap.peek()?.deadline
        }

        // Yield and log outside the lock.
        for response in responsesToYield {
            Self.logger.warning(
                "Query \(response.correlationID, privacy: .public) timed out"
            )
            self.timeoutContinuation.yield(response)
        }

        return nextDeadline
    }
}
