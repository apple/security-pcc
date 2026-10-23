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

package import CloudBoardAsyncXPC
import CloudBoardController
import CloudBoardMetrics
import os

/// A server that manages workload controllers for CloudBoard applications.
///
/// `WorkloadControllerServer` acts as a centralized manager for multiple workload controllers,
/// handling XPC communication, service registration, and health monitoring. It can operate
/// in either leader or follower mode depending on the deployment configuration.
///
/// ## Key Responsibilities
/// - Manages XPC server connections for CloudBoard controller API
/// - Routes requests to appropriate workload controllers based on cloud app names
/// - Handles workload registration and health status updates
/// - Supports both leader and follower operational modes
package actor WorkloadControllerServer {
    /// The underlying XPC server for handling CloudBoard controller API requests.
    private var server: CloudBoardControllerAPIXPCServer?

    /// Metrics system for collecting and reporting performance data.
    private var metrics: MetricsSystem

    /// Indicates whether this instance operates as a leader node.
    private let isLeader: Bool

    /// Maps cloud application names to their corresponding workload controllers.
    private var workloadControllerMap: [String: WorkloadController] = [:]

    /// Maps XPC connection ID to their associated workload controllers for request routing.
    private var connectionToControllerMap: [Int: WorkloadController] = [:]

    /// Callback invoked when a persistent service registration arrives.
    /// The daemon provides this to wire up a `PersistentServiceManager`.
    private var persistentServiceRegistrationHandler: (
        @Sendable (PersistentServiceConfig, WorkloadProperties) async throws -> Void
    )?

    /// Callback invoked when a persistent service reports terminal failure.
    /// The daemon provides this to drive the owning `PersistentServiceManager`'s health monitor terminal.
    private var persistentServiceTerminalFailureHandler: (
        @Sendable (_ serviceId: String, _ reason: String) async -> Void
    )?

    package var numberOfConnections: Int {
        self.connectionToControllerMap.count
    }

    /// The standard app name used for follower instances.
    package static let kFollowerAppName: String = "FollowerApp"

    /// Shared logger for WorkloadControllerServer operations.
    public static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "WorkloadControllerServer"
    )

    /// Initializes a new WorkloadControllerServer.
    ///
    /// - Parameters:
    ///   - isLeader: Whether this instance should operate as a leader node. Defaults to `true`.
    ///   - metrics: The metrics system to use for collecting performance data.
    package init(
        isLeader: Bool = true,
        metrics: MetricsSystem
    ) {
        self.isLeader = isLeader
        self.metrics = metrics
    }

    /// Starts the WorkloadController server and begins listening for XPC connections.
    ///
    /// This method initializes the XPC server with a local listener and establishes
    /// the necessary delegate connections for handling incoming requests.
    package func start() async {
        Self.log.info("Starting WorkloadController server")
        self.server = CloudBoardControllerAPIXPCServer.localListener()
        await self.server?.connect(listenerDelegate: self, serverDelegate: self)
        Self.log.info("WorkloadController server started")
    }

    /// Registers a handler for persistent service registrations.
    ///
    /// When a controller calls `registerWorkload` with a `.persistentService` config,
    /// the registration is routed to this handler instead of to a `WorkloadController`.
    ///
    /// - Parameter handler: Async closure invoked with the persistent service config and workload properties.
    package func onPersistentServiceRegistration(
        handler: @escaping @Sendable (PersistentServiceConfig, WorkloadProperties) async throws -> Void
    ) {
        self.persistentServiceRegistrationHandler = handler
    }

    /// Registers a handler for persistent service terminal-failure reports.
    ///
    /// When a persistent-service controller calls `reportTerminalFailure`, the report is routed to this handler
    /// (keyed by `serviceId`) so the owning manager can drive its health monitor terminal.
    ///
    /// - Parameter handler: Async closure invoked with the failing service's ID and a human-readable reason.
    package func onPersistentServiceTerminalFailure(
        handler: @escaping @Sendable (_ serviceId: String, _ reason: String) async -> Void
    ) {
        self.persistentServiceTerminalFailureHandler = handler
    }

    /// Runs a specific workload controller with the provided configuration and handlers.
    ///
    /// This method registers the workload controller and executes it with the specified
    /// service discovery publisher, request count monitoring, and lifecycle handlers.
    ///
    /// - Parameters:
    ///   - workloadController: The workload controller to run.
    ///   - serviceDiscoveryPublisher: Optional publisher for service discovery announcements.
    ///   - concurrentRequestCountStream: Stream providing real-time concurrent request counts.
    ///   - providerPause: Handler for pausing provider operations, optionally with a reason.
    ///   - restartPrewarmedInstances: Optional handler for restarting prewarmed instances.
    ///
    /// - Throws: Any errors that occur during controller setup or execution.
    package func runController(
        workloadController: WorkloadController,
        serviceDiscoveryPublisher: ServiceDiscoveryPublisherProtocol?,
        concurrentRequestCountStream: AsyncStream<Int>,
        providerPause: @escaping @Sendable (String?) async throws -> Void,
        restartPrewarmedInstances: (@Sendable () async throws -> Void)?
    ) async throws {
        let cloudApp = workloadController.cloudAppName
        Self.log.info("Setting up controller for: \(cloudApp, privacy: .public)")
        self.workloadControllerMap[cloudApp] = workloadController

        Self.log.info("Running controller for: \(cloudApp, privacy: .public)")
        try await workloadController.run(
            serviceDiscoveryPublisher: serviceDiscoveryPublisher,
            concurrentRequestCountStream: concurrentRequestCountStream,
            providerPause: providerPause,
            restartPrewarmedInstances: restartPrewarmedInstances
        )
    }

    /// Runs the server in follower mode with health monitoring.
    ///
    /// This method starts the server and creates a follower controller for backup operations.
    /// It validates that the instance is not configured as a leader before proceeding.
    ///
    /// - Parameter healthPublisher: The service health monitor for tracking system health.
    ///
    /// - Throws:
    ///   - `WorkloadControllerServerError.ranAsFollowerOnLeader` if called on a leader instance.
    ///   - Any errors from server startup or controller execution.
    package func runAsFollower(healthPublisher: ServiceHealthMonitor) async throws {
        guard !self.isLeader else {
            throw WorkloadControllerServerError.ranAsFollowerOnLeader
        }
        let followerController = WorkloadController(
            cloudAppName: WorkloadControllerServer.kFollowerAppName,
            healthPublisher: healthPublisher,
            metrics: self.metrics
        )
        self.workloadControllerMap[WorkloadControllerServer.kFollowerAppName] = followerController
        try await followerController.runInFollowerMode()
    }

    /// Shuts down the WorkloadController server and closes all connections.
    ///
    /// This method gracefully terminates the XPC server and cleans up any active connections.
    ///
    /// - Throws: Any errors that occur during the shutdown process.
    package func shutdown() async throws {
        try await self.server?.shutdown()
    }
}

// MARK: - CloudBoardControllerAPIServerDelegateProtocol

extension WorkloadControllerServer: CloudBoardControllerAPIServerDelegateProtocol {
    /// Registers a new workload with the appropriate controller.
    ///
    /// This method routes the workload registration to the correct controller based on
    /// the server's mode (leader or follower) and the provided properties.
    ///
    /// - Parameters:
    ///   - connectionIdentifier: Unique identifier for the XPC connection.
    ///   - config: Configuration parameters for the workload.
    ///   - properties: Properties defining the workload characteristics.
    ///
    /// - Throws: `WorkloadControllerServerError.unknownCloudApp` if no controller exists for the target cloud app.
    package func registerWorkload(
        connectionIdentifier: Int,
        config: InternalWorkloadConfig,
        properties: WorkloadProperties
    ) async throws {
        // Persistent service registrations are routed to a dedicated handler
        // rather than to a WorkloadController.
        if case .persistentService(let persistentConfig) = config {
            guard let handler = self.persistentServiceRegistrationHandler else {
                Self.log.error(
                    "Received persistent service registration but no handler is configured"
                )
                throw WorkloadControllerServerError.unknownCloudApp(cloudApp: persistentConfig.serviceId)
            }
            Self.log.log(
                "Routing persistent service registration for serviceId=\(persistentConfig.serviceId, privacy: .public)"
            )
            try await handler(persistentConfig, properties)
            return
        }

        let cloudAppName = self.isLeader ? properties.cloudAppName : WorkloadControllerServer.kFollowerAppName
        guard let controller = self.workloadControllerMap[cloudAppName] else {
            throw WorkloadControllerServerError.unknownCloudApp(cloudApp: cloudAppName)
        }
        guard !controller.inMemoryMode else {
            Self.log.log(
                "cloudApp=\(cloudAppName, privacy: .public) using in memory controller. Ignoring registration message."
            )
            return
        }
        Self.log.log(
            "Received register workload for cloudApp=\(cloudAppName, privacy: .public), connectionIdentifier=\(connectionIdentifier, privacy: .public)"
        )
        self.connectionToControllerMap[connectionIdentifier] = controller
        try await controller.registerWorkload(config: config, properties: properties)
    }

    /// Updates the health status for a specific workload connection.
    ///
    /// - Parameters:
    ///   - connectionIdentifier: The connection identifier to update.
    ///   - status: The new health status to report.
    ///
    /// - Throws: `WorkloadControllerServerError.unknownConnection` if the connection is not found.
    package func updateHealthStatus(
        connectionIdentifier: Int,
        status: WorkloadControllerStatus
    ) async throws {
        let controller = self.isLeader ? self.connectionToControllerMap[connectionIdentifier] : self
            .workloadControllerMap[WorkloadControllerServer.kFollowerAppName]
        guard let controller else {
            // We ignore messages from connections which have not
            // called register first
            Self.log.log(
                "Received health update from unknown connection identifier: \(connectionIdentifier, privacy: .public)"
            )
            return
        }
        Self.log.log(
            "Received update health status for cloudApp=\(controller.cloudAppName, privacy: .public), connectionIdentifier=\(connectionIdentifier, privacy: .public)"
        )
        try await controller.updateHealthStatus(status: status)
    }

    /// Restarts prewarmed instances for a specific workload connection.
    ///
    /// - Parameter connectionIdentifier: The connection identifier for the workload.
    ///
    /// - Throws: `WorkloadControllerServerError.unknownConnection` if the connection is not found.
    package func restartPrewarmedInstances(
        connectionIdentifier: Int,
    ) async throws {
        let controller = self.isLeader ? self.connectionToControllerMap[connectionIdentifier] : self
            .workloadControllerMap[WorkloadControllerServer.kFollowerAppName]
        guard let controller else {
            // We ignore messages from connections which have not
            // called regiter first
            Self.log.log(
                "Received restartPrewarmedInstances from unknown connection identifier: \(connectionIdentifier, privacy: .public)"
            )
            return
        }
        Self.log.log("Received restartPrewarmedInstances for cloudApp=\(controller.cloudAppName, privacy: .public)")
        try await controller.restartPrewarmedInstances()
    }

    /// Routes a persistent service terminal-failure report to the registered handler.
    ///
    /// Routed by `serviceId` rather than connection identifier: a persistent service can fail terminally before it
    /// ever registers a workload, so there may be no connection→controller mapping to key off.
    package func reportPersistentServiceTerminalFailure(
        connectionIdentifier: Int,
        serviceId: String,
        reason: String
    ) async throws {
        Self.log.error(
            "Received persistent service terminal failure for serviceId=\(serviceId, privacy: .public), connectionIdentifier=\(connectionIdentifier, privacy: .public): \(reason, privacy: .public)"
        )
        guard let handler = self.persistentServiceTerminalFailureHandler else {
            Self.log.error(
                "No persistent service terminal failure handler configured; dropping report for serviceId=\(serviceId, privacy: .public)"
            )
            return
        }
        await handler(serviceId, reason)
    }
}

// MARK: - CloudBoardAsyncXPCListenerDelegate

extension WorkloadControllerServer: CloudBoardAsyncXPCListenerDelegate {
    /// Handles invalidated XPC connections by notifying the associated controller.
    ///
    /// This method is called when an XPC connection is terminated or becomes invalid,
    /// allowing the associated workload controller to perform cleanup operations.
    ///
    /// - Parameter connection: The XPC connection that was invalidated.
    package func invalidatedConnection(_ connection: CloudBoardAsyncXPCConnection) async {
        Self.log.log("""
        Received 'InvalidatedConnection' from CloudBoardController: \
        id=\(String(describing: connection.id), privacy: .public)
        """)

        guard let controller = self.connectionToControllerMap[connection.id.hashValue] else {
            return
        }
        await controller.disconnected()
    }
}

// MARK: - Error Types

/// Errors that can occur during WorkloadControllerServer operations.
package enum WorkloadControllerServerError: Error, Equatable, CustomStringConvertible {
    /// Thrown when attempting to access a cloud app that doesn't have a registered controller.
    case unknownCloudApp(cloudApp: String)

    /// Thrown when attempting to run as a follower on an instance configured as a leader.
    case ranAsFollowerOnLeader

    public var description: String {
        switch self {
        case .unknownCloudApp(let cloudApp):
            return "Unknown cloud app: \(cloudApp)"
        case .ranAsFollowerOnLeader:
            return "Ran as follower on leader"
        }
    }
}
