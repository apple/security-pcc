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

import CloudBoardCommon
import CloudBoardIdentity
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import Foundation
import os
#if RC_IS_CLOUDOS_ENABLED && os(iOS)
import SystemServiceMonitor
#elseif canImport(SystemServiceMonitor)
@_weakLinked import SystemServiceMonitor
#else
#warning("SystemServiceMonitor not available at compile time")
#endif

/// Long-lived daemon only running on follower nodes in distributed inferencing ensembles, responsible for reporting
/// health of the node back to the the Control Plane Health Service
public actor CloudBoardFollowerDaemon {
    public static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "cloudboardd_follower"
    )

    private let config: CloudBoardDFollowerConfiguration
    private let healthMonitor: ServiceHealthMonitor
    private let healthServer: HealthServer?
    private let lifecycleManager: LifecycleManager
    private let workloadControllerServer: WorkloadControllerServer
    private let metricsSystem: any MetricsSystem
    private let hotProperties: HotPropertiesController
    private let heartbeatPublisher: HeartbeatPublisher?
    static let metricsClientName = "cloudboardd_follower"
    private static let watchdogProcessName = "cloudboardd_follower"
    private let watchdogService: CloudBoardWatchdogService
    private let healthReporter: (any RunnableHealthReporter)?

    public init() throws {
        let config = try CloudBoardDFollowerConfiguration.fromPreferences()
        let nodeInfo = NodeInfo.load(secureConfig: config.secureConfig)
        if let isLeader = nodeInfo.isLeader {
            if isLeader {
                CloudBoardFollowerDaemon.logger.log("Node is a leader, exiting...")
                Foundation.exit(0)
            }
        } else {
            CloudBoardFollowerDaemon.logger.error("Unable to check if node is a follower")
            Foundation.exit(0)
        }

        let leaderConfig = try CloudBoardDConfiguration.fromPreferences()
        let hotProperties = HotPropertiesController()
        let metricsSystem = CloudMetricsSystem(clientName: CloudBoardFollowerDaemon.metricsClientName)
        try self.init(
            config: config,
            leaderConfig: leaderConfig,
            nodeInfo: nodeInfo,
            hotProperties: hotProperties,
            metricsSystem: metricsSystem
        )
    }

    init(
        config: CloudBoardDFollowerConfiguration,
        leaderConfig: CloudBoardDConfiguration,
        nodeInfo: NodeInfo?,
        hotProperties: HotPropertiesController,
        metricsSystem: any MetricsSystem
    ) throws {
        self.config = config

        self.healthMonitor = ServiceHealthMonitor(cloudApp: WorkloadControllerServer.kFollowerAppName)
        self.healthReporter = Self.initializeHealthReporter(config: leaderConfig)
        self.healthServer = HealthServer(healthReporter: self.healthReporter, monitoringBridgeService: .disabled)

        if let heartbeat = leaderConfig.heartbeat {
            CloudBoardFollowerDaemon.logger.info("Heartbeat publisher was successfully configured")
            self.heartbeatPublisher = try HeartbeatPublisher(
                configuration: heartbeat,
                nodeInfo: nodeInfo,
                hotProperties: hotProperties,
                metrics: metricsSystem,
                monitoringBridgeService: .disabled
            )
        } else {
            CloudBoardFollowerDaemon.logger.error("Heartbeat publisher not configured")
            self.heartbeatPublisher = nil
        }
        self.hotProperties = hotProperties
        self.metricsSystem = metricsSystem
        self.watchdogService = CloudBoardWatchdogService(processName: Self.watchdogProcessName, logger: Self.logger)
        let lifecycleManagerConfig = leaderConfig.lifecycleManager ?? CloudBoardDConfiguration.LifecycleManager()
        self.lifecycleManager = LifecycleManager(
            config: .init(timeout: lifecycleManagerConfig.drainTimeout)
        )

        self.workloadControllerServer = WorkloadControllerServer(
            isLeader: false,
            metrics: metricsSystem
        )
    }

    nonisolated static func initializeHealthReporter(config: CloudBoardDConfiguration) -> RunnableHealthReporter? {
        #if canImport(SystemServiceMonitor)
        if #available(iOS 26.0, macOS 15.6, *), #_hasSymbol(ReportClient.self) {
            let enableSSMStatusReportingFlag = config.systemServiceMonitor?
                .enableSSMStatusReporting ?? CloudBoardDConfiguration.SystemServiceMonitorConfiguration()
                .enableSSMStatusReporting
            guard enableSSMStatusReportingFlag else {
                CloudBoardFollowerDaemon.logger.info("SystemServiceMonitor disabled")
                return nil
            }

            return SystemServiceMonitorHealthReporter()
        }
        #endif

        CloudBoardFollowerDaemon.logger.debug("SystemServiceMonitor is not available")
        return nil
    }

    public func run() async throws {
        // register watchdog monitoring
        await self.watchdogService.activate()
        CloudBoardFollowerDaemon.logger.log("Hello from cloudboard follower!")

        let jobQuiescenceMonitor = JobQuiescenceMonitor(lifecycleManager: self.lifecycleManager)
        try jobQuiescenceMonitor.startQuiescenceMonitor()

        try await self.lifecycleManager.managed {
            let identityManager = IdentityManager(
                metricsSystem: self.metricsSystem,
                metricProcess: "cloudboardd_follower",
                identityBackendType: .narrative()
            )
            if identityManager.identity != nil {
                Self.logger.log("Loaded a TLS identity, will send heartbeats with mTLS.")
            } else {
                Self.logger.error("Failed to load a TLS identity, will send heartbeats without mTLS.")
            }

            let heartbeatPublisher = self.heartbeatPublisher
            await heartbeatPublisher?.updateCredentialProvider {
                identityManager.identity?.credential
            }
            let healthServer = self.healthServer

            try await withErrorLogging(operation: "cloudboardFollowerDaemon task group") {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTaskWithLogging(operation: "hotProperties", sensitiveError: false, logger: Self.logger) {
                        try await self.hotProperties.run(metrics: self.metricsSystem)
                    }

                    if let heartbeatPublisher {
                        group.addTaskWithLogging(
                            operation: "heartbeatPublisher",
                            sensitiveError: false,
                            logger: Self.logger
                        ) {
                            try await heartbeatPublisher.run()
                        }
                    }

                    group.addTaskWithLogging(operation: "certificate refresh", sensitiveError: false) {
                        await identityManager.identityUpdateLoop()
                    }

                    if let healthServer {
                        if let healthReporter = self.healthReporter {
                            await healthReporter.run()
                        }
                        group.addTaskWithLogging(
                            operation: "healthServer", sensitiveError: false
                        ) {
                            try await healthServer.run(healthPublishers: [self.healthMonitor])
                        }
                    }

                    group.addTaskWithLogging(operation: "workloadController", sensitiveError: false) {
                        try await withLifecycleManagementHandlers(label: "workloadController") {
                            try await self.workloadControllerServer.runAsFollower(healthPublisher: self.healthMonitor)
                        } onDrain: {
                            do {
                                try await self.workloadControllerServer.shutdown()
                            } catch {
                                CloudBoardFollowerDaemon.logger
                                    .error(
                                        "workload controller failed to notify listeners of shutdown: \(String(reportable: error), privacy: .public)"
                                    )
                            }
                        }
                    }

                    // When any of these tasks exit, they all do.
                    await self.workloadControllerServer.start()
                    _ = try await group.next()
                    group.cancelAll()
                }
            }
        }
    }
}
