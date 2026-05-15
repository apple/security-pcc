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

internal enum TrackedPoolError: Error {
    case empty
    case keyNotFound(any Hashable & Sendable)
    case capacityExhausted(activeRequests: Int, maxConcurrentRequests: Int)
}

/// A pool of ``Element``s which can be "used"
/// Multiple uses of an element at the same time is possible (unless maxConcurrentRequests is set),
/// hence the elements must be Sendable
internal final class TrackedPool<Key: Hashable & Sendable, Element: Sendable>: Sendable {
    private let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "TrackedPool"
    )
    /// On deinit the tracking usage is "released"
    final class Token: Sendable {
        private let pool: TrackedPool<Key, Element>
        private let value: Element
        private let id: Int

        fileprivate init(
            _ pool: TrackedPool<Key, Element>,
            _ value: Element,
            _ id: Int
        ) {
            self.pool = pool
            self.value = value
            self.id = id
        }

        package func withValue<Result>(
            _ operation: (Element) throws -> Result
        ) rethrows -> Result {
            return try operation(self.value)
        }

        package func withValueAsync<Result>(
            _ operation: (Element) async throws -> Result
        ) async rethrows -> Result {
            return try await operation(self.value)
        }

        deinit {
            pool.finishedWith(self.id)
        }
    }

    private struct TrackingInfo: Comparable, Sendable {
        fileprivate let index: Int
        var activeRequests: Int = 0
        var totalRequests: Int = 0
        // Per-element max concurrent requests (nil means no limit for this element)
        let maxConcurrentRequests: Int?

        fileprivate init(_ index: Int, maxConcurrentRequests: Int?) {
            self.index = index
            self.maxConcurrentRequests = maxConcurrentRequests
        }

        mutating func onUse() throws {
            // Check capacity limit if configured for this element
            if let maxConcurrentRequests, self.activeRequests >= maxConcurrentRequests {
                throw TrackedPoolError.capacityExhausted(
                    activeRequests: self.activeRequests,
                    maxConcurrentRequests: maxConcurrentRequests
                )
            }
            self.activeRequests += 1
            self.totalRequests += 1
        }

        mutating func onFinished() {
            self.activeRequests -= 1
        }

        /// Provide an ordering that attempts to distribute work evenly
        /// with simplisitic assumptions that:
        /// 1. active work is always more important
        /// 2. historic "work" is equal
        static func < (
            lhs: TrackedPool<Key, Element>.TrackingInfo,
            rhs: TrackedPool<Key, Element>.TrackingInfo
        ) -> Bool {
            if lhs.activeRequests == rhs.activeRequests {
                return lhs.totalRequests < rhs.totalRequests
            }
            return lhs.activeRequests < rhs.activeRequests
        }
    }

    // very simple lock on all operations where we choose/release
    private let trackedState: Mutex<[TrackingInfo]>
    private let elements: [Element]
    private let indexByKey: [Key: Int]

    // Default max concurrent requests used when element doesn't specify its own limit
    private let defaultMaxConcurrentRequests: Int?

    // Queue manager for notifying waiting requests when nodes become available
    private let queueManager: ComputeNodeQueueManager?

    init(
        _ values: [Key: Element],
        defaultMaxConcurrentRequests: Int? = nil,
        elementMaxConcurrentRequests: [Key: Int?] = [:],
        queueManager: ComputeNodeQueueManager? = nil
    ) {
        var tracking: [TrackingInfo] = []
        var elements: [Element] = []
        var indexByKey: [Key: Int] = [:]
        for (index, (key, value)) in values.enumerated() {
            // Use element-specific limit if provided, otherwise fall back to default
            let maxConcurrentRequests = elementMaxConcurrentRequests[key] ?? defaultMaxConcurrentRequests
            tracking.append(.init(index, maxConcurrentRequests: maxConcurrentRequests))
            elements.append(value)
            indexByKey[key] = index
        }
        self.elements = elements
        self.indexByKey = indexByKey
        self.trackedState = .init(tracking)
        self.defaultMaxConcurrentRequests = defaultMaxConcurrentRequests
        self.queueManager = queueManager
    }

    /// Choose a value using the default selector rules
    func useLeastBusy() throws -> Token {
        guard !self.elements.isEmpty else {
            throw TrackedPoolError.empty
        }
        return try self.trackedState.withLock { tracking in
            var best = tracking[0]
            for info in tracking[1...] {
                if info < best {
                    best = info
                }
            }
            try tracking[best.index].onUse()
            return .init(self, self.elements[best.index], best.index)
        }
    }

    /// Choose the least busy value from a specific subset of keys
    func useLeastBusyFrom(_ keys: [Key]) throws -> Token {
        guard !keys.isEmpty else {
            throw TrackedPoolError.empty
        }

        return try self.trackedState.withLock { tracking in
            // Convert keys to indices
            var indices: [Int] = []
            for key in keys {
                guard let index = self.indexByKey[key] else {
                    throw TrackedPoolError.keyNotFound(key)
                }
                indices.append(index)
            }

            // Find the least busy among the specified indices
            var best = tracking[indices[0]]
            for index in indices[1...] {
                let info = tracking[index]
                if info < best {
                    best = info
                }
            }

            try tracking[best.index].onUse()
            return .init(self, self.elements[best.index], best.index)
        }
    }

    /// Use a specific known value.
    func useSpecific(_ key: Key) throws -> Token {
        return try self.trackedState.withLock { values in
            let index = self.indexByKey[key]
            guard let index else {
                throw TrackedPoolError.keyNotFound(key)
            }
            try values[index].onUse()
            return .init(self, self.elements[index], index)
        }
    }

    fileprivate func finishedWith(_ index: Int) {
        self.trackedState.withLock { tracking in
            tracking[index].onFinished()
        }

        let element = self.elements[index]

        // Notify queue manager that this endpoint is now available
        // This allows queued requests to be notified and attempt to acquire the node
        if let queueManager = self.queueManager {
            if let endpoint = element as? PCCHarness.ComputeCloudAppEndpoint {
                _ = queueManager.notifyAvailable(endpoint: endpoint)
            }
        }
    }

    var allValues: [Element] {
        return self.elements
    }

    /// Returns only the elements that have available capacity (not busy)
    /// Elements without configured limits are always considered available.
    /// Note: This is a point-in-time snapshot and used as such for test determinism.
    var availableValues: [Element] {
        return self.trackedState.withLock { tracking in
            var available: [Element] = []
            for (index, state) in tracking.enumerated() {
                // If element has no max concurrent requests limit, it's always available
                // Otherwise, check if it's below its limit
                if state.maxConcurrentRequests == nil || state.activeRequests < state.maxConcurrentRequests! {
                    available.append(self.elements[index])
                }
            }
            return available
        }
    }
}
