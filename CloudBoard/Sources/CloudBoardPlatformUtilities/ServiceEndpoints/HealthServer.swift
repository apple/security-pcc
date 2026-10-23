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
import CloudBoardCommon
import CloudBoardHealth
import CloudBoardLogging
import os

/// Local health server used by other on-node components to query CloudBoard health over XPC. This is called via the
/// CloudBoardHealth.framework. This interface is used to monitor CloudBoard health during convergence
public actor HealthServer {
    private var healthState: CloudBoardHealthState = .initializing
    private var publisherStates: [String: ServiceHealthMonitor.Status] = [:]
    private let healthReporter: (any HealthReporter)?
    private let monitoringBridgeService: SecureConfig.BridgeServiceMonitoringConfig

    private static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "HealthServer"
    )

    private let apiServer: CloudBoardHealthAPIServerProtocol

    package init(
        apiServer: CloudBoardHealthAPIServerProtocol = CloudBoardHealthAPIXPCServer.localListener(),
        healthReporter: (any HealthReporter)?,
        monitoringBridgeService: SecureConfig.BridgeServiceMonitoringConfig = .disabled
    ) {
        self.apiServer = apiServer
        self.healthReporter = healthReporter
        self.monitoringBridgeService = monitoringBridgeService
    }

    public func run(healthPublishers: [ServiceHealthMonitor]) async throws {
        Self.log.info("Starting HealthServer")
        await self.apiServer.connect(listenerDelegate: self, serverDelegate: self)
        Self.log.info("HealthServer started")

        try await waitForBridgeService(setting: self.monitoringBridgeService, logger: Self.log)

        guard !healthPublishers.isEmpty else {
            fatalError("No health publishers provided, Exiting!!!")
        }

        // Initialize publisher states
        self.publisherStates = healthPublishers.reduce(into: [:]) { result, publisher in
            result[publisher.cloudApp] = .initializing
        }

        await withTaskGroup(of: Void.self) { group in
            // Start monitoring each health publisher directly
            for publisher in healthPublishers {
                group.addTask {
                    await self.monitorPublisher(publisher)
                }
            }
        }

        // This point is reached when all tasks complete (which shouldn't happen in normal operation)
        Self.log.info("HealthServer monitoring completed")
    }

    private func monitorPublisher(_ publisher: ServiceHealthMonitor) async {
        let healthStream = publisher.watch()
        for await status in healthStream {
            Self.log.log(
                "Received new status from healthServer::\(publisher.cloudApp, privacy: .public): \(status, privacy: .public)"
            )

            await self.updateHealthState(for: publisher.cloudApp, status: status)
        }
        Self.log.log("Health stream ended for \(publisher.cloudApp, privacy: .public)")
    }

    private func updateHealthState(for cloudApp: String, status: ServiceHealthMonitor.Status) async {
        // Store the new status
        self.publisherStates[cloudApp] = status

        // Calculate the aggregated health state
        let newState = self.aggregateHealthStates(self.publisherStates)

        let oldState = self.healthState
        if oldState != newState {
            self.healthState = newState
            do {
                Self.log
                    .log(
                        "Changing health state to \(newState, privacy: .public) from \(oldState, privacy: .public)"
                    )
                if let healthReporter = self.healthReporter {
                    await healthReporter.report(state: newState)
                }

                try await self.apiServer.healthStateChanged(to: newState)
            } catch {
                Self.log.error("""
                HealthServer failed to update client of state change: \
                \(String(unredacted: error), privacy: .public)
                """)
            }
        }
    }

    /// Aggregates multiple service health states into a single CloudBoard health state.
    ///
    /// This method implements a conservative aggregation strategy that prioritizes system reliability:
    /// - If any service is terminally unhealthy, the overall state is unhealthy — even if other services are
    ///   still initializing. A terminal failure (e.g. a persistent service that could not download its assets)
    ///   cannot recover without external re-convergence, so there is no point waiting on the others.
    /// - If any service is still initializing, the overall state is considered initializing
    /// - If all services are unhealthy, the overall state is unhealthy
    /// - Otherwise (at least one service is healthy and none are initializing), the overall state is healthy
    ///
    /// - Parameter states: A dictionary mapping service names to their current health status
    /// - Returns: The aggregated `CloudBoardHealthState` representing the overall system health
    ///
    /// - Note: This aggregation strategy ensures that CloudBoard doesn't report as healthy until all
    ///   services have completed initialization, and only reports as unhealthy when all services have failed
    ///   or any one service has failed terminally.
    private func aggregateHealthStates(_ states: [String: ServiceHealthMonitor.Status]) -> CloudBoardHealthState {
        // A terminal failure of any single service makes the whole node unhealthy, overriding any service that is
        // still initializing. This lets convergence fail fast rather than waiting out the convergence timeout.
        if states.values.contains(where: {
            if case .terminal = $0 { return true }
            return false
        }) {
            return .unhealthy
        }

        // If any is initializing, return initializing
        if states.values.contains(where: {
            if case .initializing = $0 { return true }
            return false
        }) {
            return .initializing
        }

        // If all are unhealthy, return unhealthy
        let allUnhealthy = states.values.allSatisfy {
            if case .unhealthy = $0 { return true }
            return false
        }
        if allUnhealthy {
            return .unhealthy
        }

        // Otherwise, return healthy
        return .healthy
    }
}

extension HealthServer: CloudBoardHealthAPIServerDelegateProtocol {
    public func getHealthState() async throws -> CloudBoardHealthState {
        return self.healthState
    }
}

extension HealthServer: CloudBoardAsyncXPCListenerDelegate {
    package func invalidatedConnection(
        _ connection: CloudBoardAsyncXPCConnection
    ) async {
        Self.log.log("""
        Received 'InvalidatedConnection' from CloudBoardHealth: \
        id=\(String(describing: connection.id), privacy: .public)
        """)
    }
}

extension CloudBoardHealthState {
    public init(from serviceHealthMonitorStatus: ServiceHealthMonitor.Status) {
        switch serviceHealthMonitorStatus {
        case .initializing:
            self = .initializing
        case .unhealthy, .terminal:
            self = .unhealthy
        case .healthy:
            self = .healthy
        }
    }
}
