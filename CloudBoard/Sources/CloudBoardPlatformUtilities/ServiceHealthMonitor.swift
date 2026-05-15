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

import CloudBoardController
import os

public final class ServiceHealthMonitor: Sendable {
    private static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ServiceHealthMonitor"
    )

    package let cloudApp: String
    private let currentState: OSAllocatedUnfairLock<State>

    public init(cloudApp: String) {
        self.cloudApp = cloudApp
        self.currentState = OSAllocatedUnfairLock(initialState: State(
            nextID: 0,
            watchers: [],
            lastUpdate: .initializing,
            currentBatchSizeOverride: nil,
            maintenanceConditions: []
        ))
    }

    /// This permanently overrides the current request (batch) count. Used if CloudBoard is configured to keep track
    /// of the current count instead of reporting what the cloud app controller provides us with
    public func overrideCurrentRequestCount(count: Int) {
        self.currentState.withLock { state in
            state.currentBatchSizeOverride = count
        }
    }

    public func updateStatus(_ status: Status) {
        let (watchers, statusWithOverride): ([Watcher], Status) = self.currentState.withLock { state in
            let status = status.withCurrentBatchCountOverride(state.currentBatchSizeOverride)
            state.lastUpdate = status

            // do not notify watchers when under maintenance
            if state.isUnderMaintenance {
                return ([], status)
            }
            return (state.watchers, status)
        }

        for watcher in watchers {
            watcher.continuation.yield(statusWithOverride)
        }
    }

    public func drain() {
        self.enterMaintenance(.draining)
    }

    public func setAttestationInvalid() {
        self.enterMaintenance(.attestationInvalid)
    }

    public func setAttestationValid() {
        self.exitMaintenance(.attestationInvalid)
    }

    public func terminate() {
        Self.logger.debug("ServiceHealthMonitor::\(self.cloudApp, privacy: .public) terminate called")
        // We _must_ call `finish` from outside the lock, otherwise we'll
        // deadlock.
        let watchers = self.currentState.withLock { state in
            defer { state.watchers = [] }
            return state.watchers
        }

        for watcher in watchers {
            watcher.continuation.finish()
        }
    }

    public func watch() -> AsyncStream<Status> {
        let (stream, continuation) = AsyncStream<Status>.makeStream()

        self.currentState.withLock { state in
            let id = state.generateID()
            let watcher = Watcher(continuation: continuation, id: id)

            state.watchers.append(watcher)
            let count = state.watchers.count
            Self.logger
                .debug(
                    "ServiceHealthMonitor::\(self.cloudApp, privacy: .public) watch called \(count, privacy: .public)"
                )

            continuation.onTermination = { _ in
                self.watcherTerminated(id: id)
            }

            // Prime the pump with the last value to ensure that order of operations
            // isn't an issue.
            continuation.yield(state.lastUpdate)
        }

        return stream
    }

    public func enterMaintenance(_ maintenance: Maintenance) {
        let watchers: [Watcher] = self.currentState.withLock { state in
            // already in this maintenance condition
            if state.maintenanceConditions.contains(maintenance) {
                return []
            }
            state.maintenanceConditions.insert(maintenance)

            // already unhealthy due to last update or OTHER maintenance conditions
            if state.lastUpdate == .unhealthy || state.maintenanceConditions.count > 1 {
                return []
            }
            return state.watchers
        }

        for watcher in watchers {
            watcher.continuation.yield(.unhealthy)
        }
    }

    public func exitMaintenance(_ maintenance: Maintenance) {
        let (watchers, status): ([Watcher], Status) = self.currentState.withLock { state in
            // not under this maintenance condition - don't notify watchers
            if !state.maintenanceConditions.contains(maintenance) {
                return ([], state.lastUpdate)
            }

            state.maintenanceConditions.remove(maintenance)

            // still under other maintenance conditions - don't notify watchers
            if !state.maintenanceConditions.isEmpty {
                return ([], state.lastUpdate)
            }

            // not under any maintenance - notify watchers about last update
            return (state.watchers, state.lastUpdate)
        }

        for watcher in watchers {
            watcher.continuation.yield(status)
        }
    }

    private func watcherTerminated(id: Int) {
        self.currentState.withLock { state in
            if let index = state.watchers.firstIndex(where: { $0.id == id }) {
                state.watchers.remove(at: index)
            }
        }
    }
}

extension ServiceHealthMonitor {
    // Conditions where service is unhealthy due to CloudBoard internal reasons.
    public enum Maintenance: Sendable {
        case draining
        case attestationInvalid
        case restartingJobHelpers
    }

    private struct State {
        var nextID: Int

        var watchers: [Watcher]

        var lastUpdate: Status

        var currentBatchSizeOverride: Int?

        var maintenanceConditions: Set<Maintenance>

        var isUnderMaintenance: Bool {
            !self.maintenanceConditions.isEmpty
        }

        mutating func generateID() -> Int {
            defer { self.nextID &+= 1 }
            return self.nextID
        }
    }

    struct Watcher {
        var continuation: AsyncStream<Status>.Continuation
        var id: Int
    }

    public enum Status: Sendable, Hashable, CustomStringConvertible {
        case initializing
        case healthy(Healthy?)
        case unhealthy

        public var description: String {
            switch self {
            case .initializing:
                return "initializing"
            case .unhealthy:
                return "unhealthy"
            case .healthy(let healthy):
                return "healthy\(healthy.map { " (\($0))" } ?? "")"
            }
        }

        public func withCurrentBatchCountOverride(_ count: Int?) -> Status {
            if let count {
                switch self {
                case .initializing:
                    return .initializing
                case .healthy(let healthyState):
                    var newHealthyState: ServiceHealthMonitor.Status.Healthy?
                    if let healthyState {
                        newHealthyState = .init(
                            workloadType: healthyState.workloadType,
                            tags: healthyState.tags,
                            maxBatchSize: healthyState.maxBatchSize,
                            currentBatchSize: count,
                            optimalBatchSize: healthyState.optimalBatchSize
                        )
                    }
                    return .healthy(newHealthyState)
                case .unhealthy:
                    return .unhealthy
                }
            } else {
                return self
            }
        }
    }
}

extension ServiceHealthMonitor.Status {
    public struct Healthy: Sendable, Hashable {
        public var workloadType: String

        public var tags: [String: RoutingTagValue]

        public var maxBatchSize: Int

        public var currentBatchSize: Int

        public var optimalBatchSize: Int

        public init(
            workloadType: String,
            tags: [String: RoutingTagValue],
            maxBatchSize: Int,
            currentBatchSize: Int,
            optimalBatchSize: Int
        ) {
            self.workloadType = workloadType
            self.tags = tags
            self.maxBatchSize = maxBatchSize
            self.currentBatchSize = currentBatchSize
            self.optimalBatchSize = optimalBatchSize
        }
    }
}
