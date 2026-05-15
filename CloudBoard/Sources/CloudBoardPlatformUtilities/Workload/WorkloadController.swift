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

import CloudBoardCommon
import CloudBoardController
import CloudBoardMetrics
import os

package enum WorkloadControllerError: Error, Equatable, CustomStringConvertible {
    case controllerError(message: String)
    case controllerUnknownState
    case controllerDisconnected

    public var description: String {
        switch self {
        case .controllerError(let message):
            return "Controller reported error: \(message)"
        case .controllerUnknownState:
            return "Controller reported unknown state"
        case .controllerDisconnected:
            return "Controller disconnected"
        }
    }
}

/// A thread-safe actor that manages workload lifecycle and health status reporting for CloudBoard services.
///
/// `WorkloadController` serves as the primary interface between a workload and the CloudBoard infrastructure,
/// handling service registration, health monitoring, state transitions, and service discovery announcements.
/// It operates in two modes: leader mode (full functionality) and follower mode (minimal operation).
///
/// ## Key Responsibilities
///
/// - **State Management**: Tracks and manages workload states (initializing, ready, busy, error)
/// - **Service Discovery**: Announces services when ready and manages service visibility
/// - **Health Monitoring**: Reports health status to monitoring systems with debouncing
/// - **Concurrent Request Tracking**: Monitors and reports current request load
/// - **Prewarmed Instance Management**: Handles restarting of prewarmed instances
/// - **Leadership**: Operates differently in leader vs follower modes
///
/// ## State Transitions
///
/// The controller manages the following state flow:
/// ```
/// initializing -> ready <-> busy <-> busyTransitioning
///      |                              |
///      v                              v
///    error <------------------------error
/// ```
package actor WorkloadController {
    /// Duration to wait before publishing status updates to prevent rapid-fire announcements.
    /// Used when transitioning to states that benefit from debouncing (currently `.ready`).
    internal static let debounceDuration: Duration = .seconds(5)

    private var isLeader: Bool = true
    /// The name of the cloud application this controller manages.
    package let cloudAppName: String
    private var state: ControllerState
    private let healthPublisher: ServiceHealthMonitor
    private var providerPause: (@Sendable (String?) async throws -> Void)?
    private var restartPrewarmedInstances: (@Sendable () async throws -> Void)?
    private var restartingPrewarmedInstances: Bool = false
    private var concurrentRequestCount: Int
    private var announcedService: Bool = false
    private var serviceDiscoveryPublisher: ServiceDiscoveryPublisherProtocol?
    private var metrics: MetricsSystem

    private var workloadProperties: WorkloadProperties?
    private var workloadConfig: InternalWorkloadConfig?

    private var scheduledPublishing: Task<Void, Never>?
    private var lastDebouncedPublishingTime: ContinuousClock.Instant?

    /// Represents the current operational state of the workload controller.
    ///
    /// States control service visibility, health reporting, and allowed operations:
    /// - Only `.ready` state allows service discovery announcements
    /// - Transitions to `.busy` require provider pause capability
    /// - Error states halt normal operations and report unhealthy status
    package enum ControllerState: Sendable, Equatable, CustomStringConvertible {
        /// Initial state when the controller is starting up but not yet ready to serve requests.
        /// Service discovery announcements are suppressed in this state.
        case initializing

        /// Fully operational state where the service can accept new requests.
        /// Service discovery announcements are active and health status reports optimal capacity.
        case ready

        /// Intermediate state during transition to busy. Provider pause is called during this state.
        /// - Parameter reason: Optional description of why the transition is occurring
        case busyTransitioning(reason: String?)

        /// Service is operational but should not receive new requests.
        /// Existing requests continue to be processed, but capacity is reported as zero.
        /// - Parameter reason: Optional description of why the service is busy
        case busy(reason: String?)

        /// Error state indicating the service is not operational.
        /// Health status reports as unhealthy and service discovery announcements are suppressed.
        /// - Parameter error: The specific error that caused this state, if available
        case error(WorkloadControllerError?)

        public var description: String {
            switch self {
            case .initializing:
                return "Initializing"
            case .ready:
                return "Ready"
            case .busyTransitioning(let reason):
                return "Busy (Transitioning)\(reason.map { ": \($0)" } ?? "")"
            case .busy(let reason):
                return "Busy\(reason.map { ": \($0)" } ?? "")"
            case .error(let error):
                if let error {
                    return "Error: \(String(describing: error))"
                }
                return "Error"
            }
        }

        /// Indicates whether this state requires debounced publishing to prevent rapid status updates.
        /// Currently only `.ready` state uses debouncing to avoid announcement spam.
        var needDebouncing: Bool {
            self == .ready
        }
    }

    /// Shared logger instance for all WorkloadController operations.
    /// Uses the CloudBoard subsystem for consistent log categorization.
    public static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "WorkloadController"
    )

    /// Creates a new WorkloadController instance.
    ///
    /// - Parameters:
    ///   - cloudAppName: The name of the cloud application this controller manages
    ///   - healthPublisher: Service health monitor for reporting health status
    ///   - inMemoryControllerConfig: Optional in memory controller configuration tuple bypassing normal controller
    /// setup.
    ///                 When provided, immediately sets the controller to `.ready` state with the given config.
    ///   - metrics: Metrics system for emitting operational metrics
    ///
    /// ## In Memory Controller Mode
    ///
    /// When `inMemoryControllerConfig` is provided, the controller:
    /// - Skips the normal initialization flow
    /// - Immediately transitions to `.ready` state
    /// - Uses the provided configuration for service announcements
    package init(
        cloudAppName: String,
        healthPublisher: ServiceHealthMonitor,
        inMemoryControllerConfig: (WorkloadProperties, InternalWorkloadConfig)? = nil,
        metrics: MetricsSystem
    ) {
        self.cloudAppName = cloudAppName
        self.metrics = metrics
        self.state = .initializing
        self.healthPublisher = healthPublisher
        self.concurrentRequestCount = 0

        if let (workloadProperties, workloadConfig) = inMemoryControllerConfig {
            self.workloadProperties = workloadProperties
            self.workloadConfig = workloadConfig
            self.state = .ready
        }
        self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 1, healthStatus: self.state))
    }

    /// Runs the controller in leader mode with full functionality.
    ///
    /// This is the main execution method for primary instances that handle service discovery,
    /// health reporting, and workload management. The method runs indefinitely until cancelled
    /// or an error occurs.
    ///
    /// - Parameters:
    ///   - serviceDiscoveryPublisher: Publisher for announcing services to service discovery.
    ///                                Can be `nil` if service discovery is not needed.
    ///   - concurrentRequestCountStream: Async stream providing real-time concurrent request counts
    ///   - providerPause: Async closure called when transitioning to busy state.
    ///                    Should pause request acceptance. Receives optional reason string.
    ///   - restartPrewarmedInstances: Optional async closure for restarting prewarmed instances.
    ///                                If `nil`, restart functionality will be unavailable.
    ///
    /// ## Behavior
    ///
    /// - Sets the controller to leader mode
    /// - Monitors concurrent request count and updates health status accordingly
    /// - Handles service discovery announcements when in `.ready` state
    /// - Manages state transitions and provider pause coordination
    /// - Automatically cancels any scheduled publishing tasks on exit
    ///
    /// ## Throws
    ///
    /// Propagates errors from the concurrent request count stream monitoring.
    package func run(
        serviceDiscoveryPublisher: ServiceDiscoveryPublisherProtocol?,
        concurrentRequestCountStream: AsyncStream<Int>,
        providerPause: @escaping @Sendable (String?) async throws -> Void,
        restartPrewarmedInstances: (@Sendable () async throws -> Void)?
    ) async throws {
        defer {
            self.scheduledPublishing?.cancel()
        }
        self.isLeader = true
        self.serviceDiscoveryPublisher = serviceDiscoveryPublisher
        self.providerPause = providerPause
        self.restartPrewarmedInstances = restartPrewarmedInstances

        if case .ready = self.state,
           let properties = self.workloadProperties,
           self.workloadConfig != nil {
            Self.log.info("""
            Announcing inMemoryController based service \(properties.workloadName, privacy: .public)
            """)
            self.sendStatusUpdate()
        }

        try await self.concurrentRequestCountMonitor(
            concurrentRequestCountStream: concurrentRequestCountStream
        )
    }

    /// Runs the controller in follower mode with minimal functionality.
    ///
    /// Follower mode is designed for secondary instances that don't need to handle
    /// service discovery or full workload management. This method runs indefinitely
    /// with minimal resource usage.
    ///
    /// ## Behavior
    ///
    /// - Sets `isLeader` to `false`, disabling service discovery operations
    /// - Enters an infinite sleep loop with 1-hour intervals
    /// - Provides a lightweight presence for non-primary instances
    /// - Does not monitor concurrent requests or manage service announcements
    ///
    /// ## Usage
    ///
    /// Typically used in multi-instance deployments where only one instance
    /// needs to handle service discovery and coordination duties.
    // on follower nodes we dont need service discovery
    package func runInFollowerMode() async throws {
        self.isLeader = false

        while true {
            // Sleep for an hour. This is the longest reasonable interval to approximate
            // "wait forever" without producing unreasonably large numbers.
            try await Task.sleep(for: .seconds(60 * 60))
        }
    }

    /// Registers workload configuration and properties with the controller.
    ///
    /// This method is typically called by the CloudBoard infrastructure to provide
    /// the controller with necessary configuration for service announcements and
    /// health reporting.
    ///
    /// - Parameters:
    ///   - config: Workload configuration containing batch sizes, tags, and operational parameters
    ///   - properties: Workload properties including the service name and metadata
    ///
    /// ## Behavior
    ///
    /// - Validates that optimal batch size doesn't exceed max batch size (logs warning if it does)
    /// - Stores configuration for future health reporting and service discovery
    /// - Resets service announcement state to ensure fresh announcements
    /// - Triggers immediate status update to reflect new configuration
    ///
    /// ## Side Effects
    ///
    /// - May trigger service discovery announcements if controller is in `.ready` state
    /// - Updates health publisher with new capacity information
    /// - Logs the received configuration for debugging purposes
    public func registerWorkload(
        config: InternalWorkloadConfig,
        properties: WorkloadProperties
    ) async throws {
        Self.log.log("""
        Received 'RegisterWorkload' from CloudBoardController::\(self.cloudAppName, privacy: .public): \
        config=\(config.description, privacy: .public), \
        properties=\(properties.description, privacy: .public)
        """)

        if config.optimalBatchSize > config.maxBatchSize {
            Self.log.warning(
                "Optimal batch size is larger than max batch size"
            )
        }

        self.workloadConfig = config
        self.workloadProperties = properties
        self.announcedService = false

        self.sendStatusUpdate()
    }

    /// Updates the controller's health status based on external health checks.
    ///
    /// This method handles state transitions initiated by the CloudBoard infrastructure,
    /// managing the complex workflow of transitioning between operational states.
    ///
    /// - Parameter status: New health status containing the desired state and metadata
    ///
    /// ## State Transition Logic
    ///
    /// - **To Ready**: Requires no prewarmed restart in progress
    /// - **To Busy**: Cannot transition if already in `busyTransitioning`
    /// - **To BusyTransitioning**: Intermediate state that calls provider pause
    /// - **To Error**: Immediately transitions to error state
    ///
    /// ## Provider Pause Integration
    ///
    /// When transitioning to busy states in leader mode:
    /// 1. Validates provider pause handler is available
    /// 2. Transitions to `busyTransitioning`
    /// 3. Calls the provider pause handler
    /// 4. Finally transitions to `busy` state
    ///
    /// ## Error Handling
    ///
    /// Throws `CloudBoardControllerAPIError` for:
    /// - Attempting transitions during prewarmed restart
    /// - Missing provider pause handler when required
    /// - Already transitioning to busy state
    /// - Provider pause handler failures
    ///
    /// ## Metrics and Debouncing
    ///
    /// - Emits metrics for state changes
    /// - Uses debounced publishing for `.ready` state to prevent announcement spam
    /// - Immediate publishing for other states
    package func updateHealthStatus(
        status: WorkloadControllerStatus
    ) async throws {
        Self.log.log("""
        Received 'UpdateHealthStatus' from CloudBoardController::\(self.cloudAppName, privacy: .public): \
        status=\(status.description, privacy: .public)
        """)

        let oldWorkloadState = self.state
        switch status.state {
        case .initializing:
            self.state = .initializing
        case .ready:
            guard self.restartingPrewarmedInstances == false else {
                Self.log.error("""
                Cannot transition to \(status.state, privacy: .public) while restart of \
                prewarmed instances is in progress
                """)
                throw CloudBoardControllerAPIError.restartPrewarmedInProgress
            }
            self.state = .ready
        case .busy:
            if case .busyTransitioning = self.state {
                throw CloudBoardControllerAPIError.alreadyTransitioning(.busy)
            }
            self.state = .busyTransitioning(reason: nil)
        case .busyWithReason(let newReason):
            if case .busyTransitioning(let reason) = self.state {
                throw CloudBoardControllerAPIError.alreadyTransitioning(reason.map { .busyWithReason($0) } ?? .busy)
            }
            self.state = .busyTransitioning(reason: newReason)
        case .error:
            self.state = .error(nil)
        default:
            self.state = .error(.controllerUnknownState)
        }

        if self.isLeader, case .busyTransitioning = self.state {
            guard self.providerPause != nil else {
                Self.log.error("""
                Unable to transition to '\(status.state, privacy: .public)' because no \
                providerPause handler is configured
                """)
                self.state = oldWorkloadState
                throw CloudBoardControllerAPIError.unavailable
            }
        }

        if oldWorkloadState != self.state {
            self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 0, healthStatus: oldWorkloadState))
            self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 1, healthStatus: self.state))
        }

        self.sendOrDebounceStatusUpdate()

        if self.isLeader, case .busyTransitioning(let reason) = self.state {
            do {
                try await self.providerPause!(reason)
            } catch {
                throw CloudBoardControllerAPIError.alreadyTransitioning(.busy)
            }
        }
        if case .busyTransitioning(let reason) = self.state {
            self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 0, healthStatus: self.state))
            self.state = .busy(reason: reason)
            self.metrics.emit(Metrics.WorkloadStatus.HealthStatus(value: 1, healthStatus: self.state))
        }
    }

    /// Restarts prewarmed instances using the configured handler.
    ///
    /// This method provides a controlled way to restart prewarmed instances while
    /// ensuring proper state management and preventing concurrent restart operations.
    ///
    /// ## Preconditions
    ///
    /// - Must have a restart handler configured (set during `run()`)
    /// - Controller must be in `.busy` state
    /// - No other restart operation can be in progress
    ///
    /// ## Behavior
    ///
    /// - Sets restart-in-progress flag to prevent concurrent operations
    /// - Calls the configured restart handler
    /// - Automatically clears the in-progress flag on completion or error
    /// - Logs the operation start and any errors
    ///
    /// ## Error Handling
    ///
    /// Throws `CloudBoardControllerAPIError` for:
    /// - `.unavailable`: No restart handler configured
    /// - `.restartPrewarmedInProgress`: Another restart already in progress
    /// - `.restartPrewarmedInvalidState`: Controller not in `.busy` state
    /// - `.restartPrewarmedFailed`: Handler execution failed
    ///
    /// ## Thread Safety
    ///
    /// The restart-in-progress flag ensures only one restart operation can
    /// execute at a time, even with concurrent calls to this method.
    package func restartPrewarmedInstances() async throws {
        Self.log.log("""
        Received 'RestartPrewarmedInstances' from CloudBoardController::\(self.cloudAppName, privacy: .public)
        """)

        guard let handler = self.restartPrewarmedInstances else {
            Self.log.error("""
            No underlying handler configured for 'RestartPrewarmedInstances'
            """)
            throw CloudBoardControllerAPIError.unavailable
        }

        guard self.restartingPrewarmedInstances == false else {
            Self.log.error("Restart of prewarmed instances already in progress")
            throw CloudBoardControllerAPIError.restartPrewarmedInProgress
        }

        guard case .busy = self.state else {
            Self.log.error(
                "Cannot restart prewarmed instances in state \(self.state, privacy: .public)"
            )
            throw CloudBoardControllerAPIError.restartPrewarmedInvalidState(
                WorkloadControllerState(from: self.state)
            )
        }
        self.restartingPrewarmedInstances = true
        defer {
            self.restartingPrewarmedInstances = false
        }
        do {
            try await handler()
        } catch {
            Self.log.error(
                "Error while restarting prewarmed instances: \(error, privacy: .public)"
            )
            throw CloudBoardControllerAPIError.restartPrewarmedFailed
        }
    }

    /// Handles disconnection from the CloudBoard infrastructure.
    ///
    /// This method should be called when the connection to CloudBoard is lost,
    /// ensuring the controller transitions to an appropriate error state and
    /// updates all dependent systems.
    ///
    /// ## Behavior
    ///
    /// - Immediately transitions to `.error` state with disconnection reason
    /// - Updates service discovery to reflect unavailable status
    /// - Reports unhealthy status to health publisher
    /// - Does not throw errors - handles disconnection gracefully
    ///
    /// ## Usage
    ///
    /// Typically called by connection management code when detecting
    /// infrastructure connectivity issues.
    public func disconnected() {
        self.state = .error(
            WorkloadControllerError.controllerDisconnected
        )

        self.sendServiceDiscoveryUpdate()
        self.sendHealthPublisherUpdate()
    }

    /// Updates service discovery publisher with current service status.
    /// Only announces services when in `.ready` state and configuration is available.
    private func sendServiceDiscoveryUpdate() {
        guard let properties = self.workloadProperties,
              let config = self.workloadConfig else {
            return
        }

        switch self.state {
        case .ready:
            if self.announcedService == false {
                self.serviceDiscoveryPublisher?.announceService(
                    name: properties.workloadName,
                    workloadConfig: .init(from: config)
                )
                self.announcedService = true
            }
        case .initializing, .busy, .busyTransitioning, .error:
            return
        }
    }

    /// Updates health publisher with current status, routing to leader or follower logic.
    private func sendHealthPublisherUpdate() {
        if self.isLeader {
            self.sendHealthPublisherUpdateLeader()
        } else {
            self.sendHealthPublisherUpdateFollower()
        }
    }

    /// Handles health publisher updates for leader instances with full capacity reporting.
    private func sendHealthPublisherUpdateLeader() {
        if case .error = self.state {
            self.healthPublisher.updateStatus(.unhealthy)
            return
        }

        guard let properties = self.workloadProperties else {
            Self.log.warning("""
            Skipping health publisher update because workload properties \
            have not been received
            """)
            return
        }
        guard let config = self.workloadConfig else {
            Self.log.warning("""
            Skipping health publisher update because workload config \
            has not been received
            """)
            return
        }

        let maxBatchSize: Int
        let optimalBatchSize: Int
        if case .ready = self.state {
            maxBatchSize = config.maxBatchSize
            optimalBatchSize = config.optimalBatchSize
        } else {
            maxBatchSize = 0
            optimalBatchSize = 0
        }

        let tags = switch config {
        case .compute(let config): config.workloadTags
        case .proxy(let config): config.workloadTags
        }

        self.healthPublisher.updateStatus(.healthy(.init(
            workloadType: properties.workloadName,
            tags: tags,
            maxBatchSize: maxBatchSize,
            currentBatchSize: config.currentBatchSize,
            optimalBatchSize: optimalBatchSize
        )))
    }

    /// Handles health publisher updates for follower instances with minimal status reporting.
    private func sendHealthPublisherUpdateFollower() {
        switch self.state {
        case .initializing:
            return
        case .ready, .busy, .busyTransitioning:
            self.healthPublisher.updateStatus(.healthy(nil))
        case .error:
            self.healthPublisher.updateStatus(.unhealthy)
        }
    }

    /// Monitors concurrent request count stream and updates health status accordingly.
    /// Runs continuously until the stream ends or an error occurs.
    private func concurrentRequestCountMonitor(
        concurrentRequestCountStream: AsyncStream<Int>
    ) async throws {
        for try await concurrentRequestCount in concurrentRequestCountStream {
            self.concurrentRequestCount = concurrentRequestCount
            self.sendHealthPublisherUpdate()
        }
    }

    /// Immediately sends status updates to all publishers and resets debouncing state.
    private func sendStatusUpdate() {
        self.scheduledPublishing?.cancel()
        self.scheduledPublishing = nil
        self.sendServiceDiscoveryUpdate()
        self.sendHealthPublisherUpdate()
        if self.state.needDebouncing {
            self.lastDebouncedPublishingTime = .now
        }
    }

    /// Sends status updates with debouncing for states that benefit from it.
    /// Uses scheduled tasks to prevent rapid-fire announcements during frequent state changes.
    private func sendOrDebounceStatusUpdate() {
        if self.state.needDebouncing {
            if self.scheduledPublishing != nil {
                return
            }
            let delay = if let lastDebouncedPublishingTime = self.lastDebouncedPublishingTime {
                Self.debounceDuration - lastDebouncedPublishingTime.duration(to: .now)
            } else {
                Duration.zero
            }
            if delay <= Duration.zero {
                self.sendStatusUpdate()
                return
            }
            self.scheduledPublishing = Task {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    Self.log.debug("Scheduled status update publishing cancelled")
                    return
                }
                self.sendStatusUpdate()
            }
        } else {
            self.sendStatusUpdate()
        }
    }
}

/// Extension providing conversion from internal `ControllerState` to external `WorkloadControllerState`.
/// This allows the internal actor state to be safely exposed through the CloudBoard API.
extension WorkloadControllerState {
    /// Creates a `WorkloadControllerState` from the internal `ControllerState`.
    ///
    /// This conversion handles the mapping between internal state representation
    /// and the external API state format, including error message extraction.
    ///
    /// - Parameter controllerState: The internal controller state to convert
    package init(from controllerState: WorkloadController.ControllerState) {
        switch controllerState {
        case .initializing:
            self = .initializing
        case .ready:
            self = .ready
        case .busy(let reason), .busyTransitioning(let reason):
            if let reason {
                self = .busyWithReason(reason)
            } else {
                self = .busy
            }
        case .error(let error):
            if case .controllerError(let message) = error {
                self = .error(message: message)
            }
            self = .error(message: nil)
        }
    }
}
