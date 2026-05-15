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

import Foundation
internal import Synchronization
import os
internal import DequeModule

/// Manages FIFO queues of requests waiting for compute nodes to become available
///
/// - Each endpoint maintains an independent FIFO queue
/// - When an endpoint becomes available, the oldest waiter in that endpoint's queue is notified
/// - A request can enqueue on multiple endpoints concurrently to implement "first-available-wins" logic
/// - The caller is responsible for canceling other queue positions when one succeeds
package final class ComputeNodeQueueManager: Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ComputeNodeQueueManager"
    )

    /// Optional callback for testing - notified when a waiter is enqueued
    /// nonisolated(unsafe): Only used in tests, set before concurrent access begins
    internal nonisolated(unsafe) var onWaiterEnqueued: (@Sendable (PCCHarness.HostAndPort) -> Void)?

    /// Represents a waiter in the queue
    private struct Waiter: Sendable {
        let id: UUID // For cancellation lookup
        let continuation: UnsafeContinuation<PCCHarness.ComputeCloudAppEndpoint, Error>

        init(
            id: UUID,
            continuation: UnsafeContinuation<PCCHarness.ComputeCloudAppEndpoint, Error>
        ) {
            self.id = id
            self.continuation = continuation
        }
    }

    /// FIFO queue per endpoint - oldest waiter at front
    private let queues: Mutex<[PCCHarness.HostAndPort: Deque<Waiter>]>

    package init() {
        self.queues = Mutex([:])
    }

    /// Enqueue a request to wait for an endpoint to become available
    /// Returns a QueueToken that can be used to cancel the wait
    package func enqueue(
        endpoint: PCCHarness.ComputeCloudAppEndpoint,
        continuation: UnsafeContinuation<PCCHarness.ComputeCloudAppEndpoint, Error>
    ) -> QueueToken {
        let waiterID = UUID()
        let waiter = Waiter(id: waiterID, continuation: continuation)
        let hostAndPort = endpoint.hostAndPort

        let queueSize = self.queues.withLock { queues in
            queues[hostAndPort, default: Deque()].append(waiter)
            return queues[hostAndPort]!.count
        }
        Self.logger.info(
            "Enqueued waiter \(waiterID) on endpoint \(hostAndPort), queue size: \(queueSize)"
        )

        // Notify test observer that a waiter has been enqueued
        self.onWaiterEnqueued?(hostAndPort)

        return QueueToken(
            waiterID: waiterID,
            endpoint: endpoint,
            manager: self
        )
    }

    /// Remove a waiter from the queue (used when request is cancelled or succeeded via another path)
    /// The waiter's continuation is resumed with CancellationError
    package func cancelIfWaiting(waiterID: UUID, endpoint: PCCHarness.ComputeCloudAppEndpoint) {
        let hostAndPort = endpoint.hostAndPort

        let removedWaiter = self.queues.withLock { queues -> Waiter? in
            guard var queue = queues[hostAndPort] else {
                return nil
            }

            // Find and remove the waiter by ID
            var removed: Waiter?
            queue.removeAll { waiter in
                if waiter.id == waiterID {
                    removed = waiter
                    return true
                }
                return false
            }

            if queue.isEmpty {
                queues.removeValue(forKey: hostAndPort)
            } else {
                queues[hostAndPort] = queue
            }

            return removed
        }

        // Resume the continuation with cancellation error outside the lock
        // This ensures continuations don't wait forever when the waiter is removed
        if let waiter = removedWaiter {
            Self.logger.debug(
                "Resuming cancelled waiter \(waiterID) for endpoint \(hostAndPort) with CancellationError"
            )
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    /// Notify that an endpoint is now available
    /// Fulfills the oldest waiter in FIFO order
    /// Returns true if a waiter was notified, false if queue was empty
    package func notifyAvailable(endpoint: PCCHarness.ComputeCloudAppEndpoint) -> Bool {
        let hostAndPort = endpoint.hostAndPort
        let waiter = self.queues.withLock { queues -> Waiter? in
            guard var queue = queues[hostAndPort], !queue.isEmpty else {
                return nil
            }

            let waiter = queue.removeFirst()
            if queue.isEmpty {
                queues.removeValue(forKey: hostAndPort)
            } else {
                queues[hostAndPort] = queue
            }

            Self.logger.info(
                "Notifying oldest waiter \(waiter.id) for available endpoint \(hostAndPort), remaining in queue: \(queue.count)"
            )

            return waiter
        }

        // Resume continuation outside the lock
        if let waiter {
            waiter.continuation.resume(returning: endpoint)
            return true
        }

        return false
    }

    /// Token that represents a position in the queue
    /// Can be used to manually cancel the wait via cancel()
    package final class QueueToken: Sendable {
        private let waiterID: UUID
        private let endpoint: PCCHarness.ComputeCloudAppEndpoint
        private let manager: ComputeNodeQueueManager

        fileprivate init(
            waiterID: UUID,
            endpoint: PCCHarness.ComputeCloudAppEndpoint,
            manager: ComputeNodeQueueManager
        ) {
            self.waiterID = waiterID
            self.endpoint = endpoint
            self.manager = manager
        }

        /// Manually remove from queue and resume continuation with CancellationError
        package func cancel() {
            self.manager.cancelIfWaiting(waiterID: self.waiterID, endpoint: self.endpoint)
        }
    }
}
