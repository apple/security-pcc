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

import os
import Synchronization

/// Tracks the affinity keys carried by in-progress inference requests and broadcasts changes to watchers.
///
/// Each request `register`s its affinity keys under its `requestID` and `remove`s them with that same `requestID` when
/// it finishes. A `requestID` is expected to register exactly once; a repeat registration is a programming error that
/// is logged and ignored. `keysInProgress` exposes the deduplicated union of all currently-registered keys, which
/// CloudBoard echoes back to ROPES via `LoadResponse.affinityKeysInProgress`.
final class InProgressAffinityKeyStore: Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "InProgressAffinityKeyStore"
    )

    private let state: Mutex<State>

    init() {
        self.state = Mutex(State())
    }

    /// The deduplicated union of all currently-registered affinity keys, in first-appearance order.
    var keysInProgress: [Com_Apple_Cloudboard_Api_V1_AffinityKey] {
        self.state.withLock { $0.union }
    }

    /// Stores `keys` under `requestID` and notifies watchers if the deduplicated union changed.
    ///
    /// A `requestID` must register exactly once; a repeat call is logged and ignored, leaving the existing entry
    /// intact.
    func register(requestID: String, keys: [Com_Apple_Cloudboard_Api_V1_AffinityKey]) {
        let watchers: [AsyncStream<Void>.Continuation]? = self.state.withLock { state in
            guard state.keysByRequest[requestID] == nil else {
                return nil
            }

            var newKeys: [Com_Apple_Cloudboard_Api_V1_AffinityKey] = []
            for key in keys where !newKeys.contains(key) {
                newKeys.append(key)
            }
            state.keysByRequest[requestID] = newKeys

            var changed = false
            for key in newKeys {
                changed = state.retain(key) || changed
            }
            return changed ? Array(state.watchers.values) : []
        }

        guard let watchers else {
            Self.logger.error(
                "register called more than once for the same request; ignoring. requestID=\(requestID, privacy: .public)"
            )
            return
        }

        for watcher in watchers {
            watcher.yield(())
        }
    }

    /// Drops the keys registered under `requestID` and notifies watchers if the deduplicated union changed.
    func remove(requestID: String) {
        let watchers: [AsyncStream<Void>.Continuation] = self.state.withLock { state in
            guard let oldKeys = state.keysByRequest.removeValue(forKey: requestID) else { return [] }
            var changed = false
            for key in oldKeys {
                changed = state.release(key) || changed
            }
            return changed ? Array(state.watchers.values) : []
        }

        for watcher in watchers {
            watcher.yield(())
        }
    }

    /// A stream that emits whenever `keysInProgress` changes. No value is primed on subscription — the load-level
    /// health stream's own initial emission already covers the first send.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()

        let id = self.state.withLock { state in
            let id = state.nextWatcherID
            state.nextWatcherID &+= 1
            state.watchers[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.watchers[id] = nil }
        }

        return stream
    }

    /// Finishes all watcher streams. Used to bound consumers during teardown.
    func finishAllWatchers() {
        let watchers: [AsyncStream<Void>.Continuation] = self.state.withLock { state in
            defer { state.watchers = [:] }
            return Array(state.watchers.values)
        }

        for watcher in watchers {
            watcher.finish()
        }
    }

    /// `AffinityKey` is `Equatable` but not `Hashable`, so distinct keys are reference-counted under this hashable
    /// proxy derived from the fields that define their identity (`category` + `data`).
    private struct KeyID: Hashable {
        var categoryRawValue: Int
        var data: UInt64

        init(_ key: Com_Apple_Cloudboard_Api_V1_AffinityKey) {
            self.categoryRawValue = key.category.rawValue
            self.data = key.data
        }
    }

    private struct State {
        var keysByRequest: [String: [Com_Apple_Cloudboard_Api_V1_AffinityKey]] = [:]
        var refCounts: [KeyID: Int] = [:]
        var union: [Com_Apple_Cloudboard_Api_V1_AffinityKey] = []
        var watchers: [Int: AsyncStream<Void>.Continuation] = [:]
        var nextWatcherID = 0

        /// Increments `key`'s reference count, returning `true` if it was newly added to the union.
        mutating func retain(_ key: Com_Apple_Cloudboard_Api_V1_AffinityKey) -> Bool {
            let id = KeyID(key)
            let count = self.refCounts[id, default: 0]
            self.refCounts[id] = count + 1
            if count == 0 {
                self.union.append(key)
                return true
            }
            return false
        }

        /// Decrements `key`'s reference count, returning `true` if it was removed from the union.
        mutating func release(_ key: Com_Apple_Cloudboard_Api_V1_AffinityKey) -> Bool {
            let id = KeyID(key)
            guard let count = self.refCounts[id] else { return false }
            if count <= 1 {
                self.refCounts[id] = nil
                if let index = self.union.firstIndex(where: { KeyID($0) == id }) {
                    self.union.remove(at: index)
                }
                return true
            }
            self.refCounts[id] = count - 1
            return false
        }
    }
}
