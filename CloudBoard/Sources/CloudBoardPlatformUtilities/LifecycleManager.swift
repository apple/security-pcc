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

import CloudBoardLogging
import InternalGRPC
import NIOCore
import os

private enum LifecycleManagerTaskLocals {
    @TaskLocal
    static var lifecycleManager: LifecycleManager?
}

/// Executes an operation with optional lifecycle management handlers.
///
/// This function registers drain and post-drain handlers with the current Task tree's lifecycle manager
/// (if available) and then executes the provided operation. The handlers will be called
/// during the lifecycle manager's drain process to enable graceful shutdown.
///
/// - Parameters:
///   - label: An optional label to identify this managed service in logs. Defaults to `nil`.
///   - operation: The async operation to execute under lifecycle management.
///   - drainHandler: An optional handler called during the drain phase to gracefully
///     shut down resources. This should perform cleanup operations like closing connections
///     or stopping background tasks. Defaults to `nil`.
///   - postDrainHandler: An optional handler called after the drain phase completes
///     for final cleanup tasks that should occur after all drain handlers have finished.
///     Defaults to `nil`.
///
/// - Returns: The result of the operation.
/// - Throws: Any error thrown by the operation.
///
/// - Note: If no lifecycle manager is found in the current task context, the operation
///   will proceed normally without lifecycle management, and a debug message will be logged.
public func withLifecycleManagementHandlers<T>(
    label: String? = nil,
    operation: () async throws -> T,
    onDrain drainHandler: (@Sendable () async -> Void)? = nil,
    onPostDrain postDrainHandler: (@Sendable () async -> Void)? = nil
) async rethrows -> T {
    guard let lifecycleManager = LifecycleManagerTaskLocals.lifecycleManager else {
        LifecycleManager.logger.debug("Managed task started but no Lifecycle Manager is found, proceeding anyway.")
        return try await operation()
    }

    // We have to keep track of our handler here to remove it once the operation is finished.
    await lifecycleManager.registerManagedService(.init(
        label: label,
        drainHandler: drainHandler,
        postDrainHandler: postDrainHandler
    ))

    return try await operation()
}

struct LifecycleManaged {
    let drainHandler: (@Sendable () async -> Void)?
    let postDrainHandler: (@Sendable () async -> Void)?
    let label: String?

    init(
        label: String?,
        drainHandler: (@Sendable () async -> Void)? = nil,
        postDrainHandler: (@Sendable () async -> Void)? = nil
    ) {
        self.label = label
        self.drainHandler = drainHandler
        self.postDrainHandler = postDrainHandler
    }
}

public final class LifecycleManager: Sendable {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LifecycleManager"
    )

    struct Handler {
        let id: Int
        let service: LifecycleManaged
    }

    private let config: Configuration
    private let storage = OSAllocatedUnfairLock(initialState: BackingStorage())

    public init(config: Configuration) {
        self.config = config
    }

    public func managed(
        operation: @Sendable @escaping () async throws -> Void,
        onDrain: (@Sendable () -> Void)? = nil,
        onDrainCompleted: (@Sendable () -> Void)? = nil
    ) async throws {
        try await withErrorLogging(operation: "Managed operation manager", sensitiveError: false) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTaskWithLogging(operation: "Managed operation", sensitiveError: false) {
                    try await withErrorLogging(operation: "get operation manager", sensitiveError: false) {
                        try await LifecycleManagerTaskLocals.$lifecycleManager.withValue(self) {
                            try await operation()
                        }
                    }

                    Self.logger.error("Managed operation returning")
                }

                group.addTaskWithLogging(operation: "Wait for and handle drain operation", sensitiveError: false) {
                    do {
                        try await self.waitForDrain()
                    } catch LifecycleManagerError.taskCancelled {
                        Self.logger.debug("Lifecycle Manager 'wait for drain signal' task cancelled.")
                        return
                    }
                    Self.logger.notice("Received drain signal. Handling drain...")
                    try await self.handleDrain(onDrain: onDrain, onDrainCompleted: onDrainCompleted)
                    Self.logger.notice("Drain completed")
                }

                // if either task ends, cancel the other
                try await group.next()
                group.cancelAll()
            }

            try self.storage.withLock { storage in
                switch storage.state {
                case .drained:
                    () // end the task, any restarting is handled at a higher level
                case .draining:
                    fatalError("Managed operation ended during drain")
                case .active, .activeWithDrainContinuation, .drainQueued:
                    Self.logger.error("Managed operation ended without drain")
                    if self.config.enforceAllStateChecks {
                        Self.logger.fault("Managed operation ended without drain")
                        throw LifecycleManagerError.exitedWithoutDrain
                    } else {
                        Self.logger.error("Managed operation ended without drain - ignoring")
                    }
                }
            }

            return
        }
    }

    func waitForDrain() async throws {
        try await withErrorLogging(operation: "waitForDrain", sensitiveError: false) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.storage.withLock { storage in
                        if Task.isCancelled {
                            continuation.resume(throwing: LifecycleManagerError.taskCancelled)
                            return
                        }

                        switch storage.state {
                        case .active:
                            storage.state = .activeWithDrainContinuation(continuation)
                        case .drainQueued:
                            storage.state = .draining
                            continuation.resume()
                        case .activeWithDrainContinuation:
                            continuation.resume(throwing: LifecycleManagerError.cannotDoubleWait)
                        case .draining, .drained:
                            let state = storage.state
                            Self.logger
                                .warning("Attempted to wait for drain in state: \(state, privacy: .public)")
                            continuation.resume(throwing: LifecycleManagerError.cannotDoubleDrain)
                        }
                    }
                }
            } onCancel: {
                self.storage.withLock { storage in
                    switch storage.state {
                    case .activeWithDrainContinuation(let continuation):
                        continuation.resume(throwing: LifecycleManagerError.taskCancelled)
                        storage.state = .active
                    case .active, .draining, .drainQueued, .drained:
                        break // no-op
                    }
                }
            }
        }
    }

    func registerManagedService(_ service: LifecycleManaged) async {
        let drainHandler: (@Sendable () async -> Void)? = self.storage.withLock { storage in
            switch storage.state {
            case .active, .activeWithDrainContinuation, .drainQueued:
                defer {
                    storage.handlerCounter += 1
                }
                storage.handlers.append(.init(id: storage.handlerCounter, service: service))
                return nil
            case .draining, .drained:
                return service.drainHandler
            }
        }
        if let drainHandler {
            await drainHandler()
        }
    }

    func removeManagedService(_ id: Int) {
        self.storage.withLock { storage in
            guard let index = storage.handlers.firstIndex(where: { $0.id == id }) else {
                // This can happen because drain ran while the operation was still in progress
                return
            }

            storage.handlers.remove(at: index)
        }
    }

    private func handleDrain(
        onDrain: (@Sendable () -> Void)?,
        onDrainCompleted: (@Sendable () -> Void)?
    ) async throws {
        try await withErrorLogging(operation: "handleDrain", sensitiveError: false) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTaskWithLogging(operation: "execute drain handlers", sensitiveError: false) {
                    onDrain?()
                    // grab a copy of the current drain handlers
                    let drainHandlers = self.storage.withLock { storage in
                        switch storage.state {
                        case .active, .activeWithDrainContinuation:
                            storage.state = .draining
                            return storage.handlers.map { (
                                $0.service.label,
                                $0.service.drainHandler,
                                $0.service.postDrainHandler
                            ) }
                        case .draining:
                            return [] // no-op
                        case .drainQueued, .drained:
                            let state = storage.state
                            assertionFailure("Drain started with the manager in state: \(state)")
                            Self.logger
                                .fault("Drain started with the manager in state: \(state, privacy: .public)")
                            return []
                        }
                    }

                    // execute drain
                    await withDiscardingTaskGroup { group in
                        for (label, drainHandler, _) in drainHandlers {
                            guard let drainHandler else {
                                Self.logger
                                    .info(
                                        "No drain handler for \(label ?? "Unlabeled Lifecycle Managed Component") - skipping"
                                    )
                                continue
                            }
                            group.addTaskWithLogging(
                                operation: "drainHandler" + (label.map { ": \($0)" } ?? ""),
                                sensitiveError: false
                            ) {
                                await drainHandler()
                            }
                        }
                    }

                    // mark drain complete
                    self.storage.withLock { storage in
                        switch storage.state {
                        case .draining:
                            storage.state = .drained
                        case .active, .activeWithDrainContinuation,
                             .drainQueued, .drained:
                            assertionFailure("Drain completed with the manager in state: \(storage.state) ")
                        }
                    }
                    onDrainCompleted?()

                    // execute post drain
                    await withDiscardingTaskGroup { group in
                        for (label, _, postDrainHandler) in drainHandlers {
                            guard let postDrainHandler else {
                                Self.logger
                                    .info(
                                        "No post drain handler for \(label ?? "Unlabeled Lifecycle Managed Component") - skipping"
                                    )
                                continue
                            }
                            group.addTaskWithLogging(
                                operation: "postDrainHandler" + (label.map { ": \($0)" } ?? ""),
                                sensitiveError: false
                            ) {
                                await postDrainHandler()
                            }
                        }
                    }
                }

                // Start a drain timer.
                // If this timer completes, CloudBoard will immediately exit regardless of the current number of
                // outstanding invocations still in flight.
                group.addTaskWithLogging(operation: "drain handler timeout", sensitiveError: false) {
                    try await Task.sleep(for: self.config.timeout)
                    Self.logger.critical("CloudBoard timed out during drain")
                    onDrainCompleted?()
                    os.exit(1)
                }

                // when either of the tasks complete the group
                try await group.next()
                group.cancelAll()
            }
        }
    }

    public func drain() {
        self.storage.withLock { storage in
            let outcome: DrainSignalOutcome
            let originalState = storage.state

            switch storage.state {
            case .active:
                storage.state = .drainQueued
                outcome = .drainQueued
            case .activeWithDrainContinuation(let continuation):
                continuation.resume()
                storage.state = .active
                outcome = .drainStarted
            case .drainQueued, .draining:
                outcome = .drainSignalIgnored // no-op
            case .drained:
                outcome = .drainSignalIgnored // ignore the signal
            }
            let newState = storage.state

            Self.logger
                .debug(
                    "Drain signal received whilst in state: \(originalState, privacy: .public). Outcome: \(outcome, privacy: .public), state: \(newState, privacy: .public)"
                )
        }
    }
}

extension LifecycleManager {
    public struct Configuration: Sendable {
        let timeout: ContinuousClock.Duration
        /// In unit tests often things are torn down in ways that would violate some checks
        /// Unsetting this skips those checks
        let enforceAllStateChecks: Bool

        public init(
            timeout: ContinuousClock.Duration,
            enforceAllStateChecks: Bool = true

        ) {
            self.timeout = timeout
            self.enforceAllStateChecks = enforceAllStateChecks
        }
    }
}

extension LifecycleManager {
    struct BackingStorage {
        var state: State
        var handlers: [Handler]
        /// A counter to assign a unique number to each handler.
        fileprivate var handlerCounter: Int = 0

        init() {
            self.state = .active
            self.handlers = []
        }
    }

    enum State: CustomStringConvertible {
        case active
        case drainQueued
        case activeWithDrainContinuation(CheckedContinuation<Void, Error>)
        case draining
        case drained

        var description: String {
            switch self {
            case .active:
                return "active"
            case .drainQueued:
                return "drainQueued"
            case .activeWithDrainContinuation:
                return "activeWithDrainContinuation"
            case .draining:
                return "draining"
            case .drained:
                return "drained"
            }
        }
    }
}

extension LifecycleManager {
    private enum DrainSignalOutcome: CustomStringConvertible {
        case drainSignalIgnored
        case drainQueued
        case drainStarted
        case drainTypeChanged

        var description: String {
            switch self {
            case .drainSignalIgnored:
                "drain signal ignored"
            case .drainQueued:
                "drain queued"
            case .drainStarted:
                "drain started"
            case .drainTypeChanged:
                "drain type changed"
            }
        }
    }
}

extension LifecycleManager {
    enum LifecycleManagerError: Error {
        case drainTimeout
        case taskCancelled
        case cannotDoubleWait
        case cannotDoubleDrain
        case exitedWithoutDrain
    }
}
