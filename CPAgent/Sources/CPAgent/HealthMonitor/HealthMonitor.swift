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

import AsyncHTTPClient
import CPAgentProtos
import FleetManagerClient
import Foundation
import GPUHealthDaemonClient
import HealthServiceClient
import Logging
import OpenAPIRuntime
import ServiceLifecycle
import GRPCCore

actor HealthMonitor: Service {
    private let logger = Logger(label: "CPAgent.HealthMonitor")

    private let healthCheckInterval = Duration.seconds(300)

    private let healthServiceClient: HealthServiceClient?
    private let fleetManagerClient: FleetManagerClient?
    private let nodeStatusStore: NodeStatusStore?
    private let gpuHealthProvider: GPUHealthProvider?
    private let fluentBitCheckService: FluentBitCheckService

    private let convergenceCheckGpu: Bool
    private let convergenceCheckCloudboard: Bool
    private let convergenceCheckFluentBit: Bool
    private let enableHealthServiceReporting: Bool

    private let gpuChecks = GPUChecks()
    private var currentStatus = FleetManagerClient.Schemas.HealthStatus()
    private var currentReport: Proto_CPAgentStatus_StatusReport?

    public init(
        healthServiceClient: HealthServiceClient?,
        fleetManagerClient: FleetManagerClient?,
        nodeStatusStore: NodeStatusStore? = nil,
        convergenceCheckGpu: Bool = false,
        convergenceCheckCloudboard: Bool = true,
        convergenceCheckFluentBit: Bool = false,
        enableHealthServiceReporting: Bool = false,
        gpuHealthProvider: GPUHealthProvider? = nil,
        fluentBitCheckService: FluentBitCheckService
    ) {
        self.healthServiceClient = healthServiceClient
        self.fleetManagerClient = fleetManagerClient
        self.nodeStatusStore = nodeStatusStore
        self.convergenceCheckGpu = convergenceCheckGpu
        self.convergenceCheckCloudboard = convergenceCheckCloudboard
        self.convergenceCheckFluentBit = convergenceCheckFluentBit
        self.enableHealthServiceReporting = enableHealthServiceReporting
        self.gpuHealthProvider = gpuHealthProvider
        self.fluentBitCheckService = fluentBitCheckService
    }

    func run() async throws {
        logger.info("Starting...")
        try await withGracefulShutdownHandler {
            try await self.monitor()
        } onGracefulShutdown: {
            Task {
                self.logger.info("Shutting down health monitor")
            }
        }
        logger.info("finished")
    }

    func monitor() async throws {
        logger.info(
            "Starting health monitoring",
            metadata: ["healthCheckInterval": "\(healthCheckInterval.components.seconds)s"])

        while !Task.isCancelled {
            await runHealthCheck()

            logger.info("Health check completed", metadata: ["health": "\(currentStatus)"])

            async let report1 = reportToHealthService()
            async let report2 = reportToFleetManager()
            await report1
            await report2

            try await Task.sleep(for: healthCheckInterval)
        }
    }

    public func GPUCheckOutputAsGPUCheckResult(_ output: GPUChecksOutput) -> FleetManagerClient.Schemas.GPUCheckResult {
        .init(
            timestamp: Date(),
            success: output.success,
            output: output.output,
            issues: output.Issues?.map { issue in
                FleetManagerClient.Schemas.GpuIssue(issueCode: issue.issueCode, gpuUuid: issue.gpuUuid)
            })
    }

    public nonisolated func scheduleComprehensiveGpuCheck() {
        Task {
            await runComprehensiveCheck()
            await reportToHealthService()
        }
    }

    private func runComprehensiveCheck() async {
        logger.info("Performing comprehensive GPU health check")

        do {
            let output = try await gpuChecks.runComprehensive()
            currentStatus.comprehensiveGpuCheck = GPUCheckOutputAsGPUCheckResult(output)
        } catch {
            currentStatus.comprehensiveGpuCheck = .init(
                timestamp: Date(), success: false, output: error.localizedDescription, issues: nil)
        }
    }

    private func runHealthCheck() async {
        logger.info("Performing health check")

        if let store = nodeStatusStore {
            currentReport = await store.getLatestReport()
        }

        let (basicGpuCheck, gpuHealthDaemonStatus) = await fetchGpuHealthDaemonStatus()

        currentStatus.basicGpuCheck = basicGpuCheck

        // Build component status including Fluent Bit (from service)
        let fluentBitStatus = await fluentBitCheckService.componentStatus
        var componentStatuses =
            HealthMonitor.reportToComponentStatus(currentReport) + gpuHealthDaemonStatus
        componentStatuses.append(fluentBitStatus)
        currentStatus.componentStatus = componentStatuses
        currentStatus.componentStatusTimestamp = Date()

        currentStatus.converged = await computeConvergence()
    }

    private static func reportToComponentStatus(_ report: Proto_CPAgentStatus_StatusReport?)
        -> [FleetManagerClient.Schemas.ComponentStatus]
    {
        if let report = report {
            return report.components.map(convertProtoComponent(_:))
        } else {
            return []
        }
    }

    private static func convertProtoComponent(_ proto: Proto_CPAgentStatus_ComponentStatus)
        -> FleetManagerClient.Schemas.ComponentStatus
    {
        let state: FleetManagerClient.Schemas.ComponentStatus.statePayload?
        let message: String?

        switch proto.state {
        case .initializing(let v):
            state = .INITIALIZING
            message = v.phase
        case .ready:
            state = .READY
            message = nil
        case .degraded(let v):
            state = .DEGRADED
            message = v.reason
        case .busy(let v):
            state = .BUSY
            message = v.reason
        case .transientError(let v):
            state = .TRANSIENT_ERROR
            message = v.message
        case .terminalError(let v):
            state = .TERMINAL_ERROR
            message = v.message
        case .draining(let v):
            state = .DRAINING
            message = v.reason
        case .drained(let v):
            state = .DRAINED
            message = v.reason
        case .none:
            state = nil
            message = nil
        }

        return .init(
            componentPath: proto.componentPath,
            state: state,
            message: message
        )
    }

    private func reportToHealthService() async {
        if enableHealthServiceReporting {
            await reportToHealthServiceV2()
        } else {
            await reportToHealthServiceLegacy()
        }
    }

    private func reportToHealthServiceLegacy() async {
        guard let client = healthServiceClient else {
            logger.warning("Health client not initialized, skipping report")
            return
        }

        let cpAgentHealthy = (currentStatus.cpAgentStatus ?? .HEALTHY) == .HEALTHY
        let basicGPUOk = currentStatus.basicGpuCheck?.success ?? true
        let comprehensiveGPUOk = currentStatus.comprehensiveGpuCheck?.success ?? true

        do {
            try await client.heartbeat(healthy: cpAgentHealthy && basicGPUOk && comprehensiveGPUOk)
        } catch {
            logger.error(
                "Failed to send heartbeat", metadata: ["error": "\(String(reportable: error))"])
        }
    }

    private func reportToHealthServiceV2() async {
        guard let client = healthServiceClient else {
            logger.warning("Health client not initialized, skipping report")
            return
        }

        let state: HealthServiceClient.State = (currentStatus.converged ?? false) ? .UP : .DOWN

        let operationalStatus: HealthServiceClient.NodeOperationalStatus
        if let report = currentReport {
            let rootComponents = report.components.filter { $0.componentPath.count == 1 }
            if rootComponents.isEmpty {
                operationalStatus = .UNINITIALIZED
            } else if rootComponents.allSatisfy({ $0.state?.isServing ?? false }) {
                operationalStatus = .FUNCTIONAL
            } else if rootComponents.contains(where: {
                if case .terminalError = $0.state { return true }
                return false
            }) {
                operationalStatus = .COMPONENTS_FAILED_TO_RUN
            } else if rootComponents.contains(where: {
                if case .draining = $0.state { return true }
                return false
            }) {
                operationalStatus = .SERVICE_DISCOVERY_PUBLISHER_DRAINING
            } else if rootComponents.contains(where: {
                if case .drained = $0.state { return true }
                return false
            }) {
                operationalStatus = .DAEMON_DRAINED
            } else {
                operationalStatus = .INITIALIZING
            }
        } else {
            operationalStatus = .UNINITIALIZED
        }

        let componentStatus = HealthMonitor.componentStatusAsStringMap(
            currentStatus.componentStatus ?? [])

        do {
            try await client.heartbeat(
                state: state,
                operationalStatus: operationalStatus,
                componentStatus: componentStatus)
        } catch {
            logger.error(
                "Failed to send heartbeat", metadata: ["error": "\(String(reportable: error))"])
        }
    }

    private static func componentStatusAsStringMap(_ components: [FleetManagerClient.Schemas.ComponentStatus]) -> [String:
        String]?
    {
        var result: [String: String] = [:]
        for component in components {
            guard let path = component.componentPath?.joined(separator: "/") else { continue }
            guard let state = component.state else { continue }
            switch component.state {
            case .READY: result[path] = "READY"
            default: result[path] = "\(state.rawValue): \(component.message ?? "nil")"
            }
        }
        return result
    }

    private func reportToFleetManager() async {
        guard let client = fleetManagerClient else {
            logger.warning("Fleet manager client not initialized, skipping report")
            return
        }

        do {
            try await client.reportHealth(currentStatus)
        } catch {
            logger.error(
                "Failed to report health to fleet manager",
                metadata: ["error": "\(String(reportable: error))"])
        }

        await fetchAndReportGpuTelemetry()
    }

    private func fetchAndReportGpuTelemetry() async {
        guard let provider = gpuHealthProvider else { return }
        guard let client = fleetManagerClient else { return }

        do {
            let response = try await provider.getTelemetry()
            let telemetry = TypeMapper.convertTelemetryResponse(response)
            try await client.reportGpuDaemonTelemetry(telemetry)
        } catch {
            logger.error(
                "Failed to report GPU telemetry to fleet manager",
                metadata: ["error": "\(String(reportable: error))"])
        }
    }

    fileprivate func fetchGpuHealthDaemonStatus() async -> (FleetManagerClient.Schemas.GPUCheckResult, [FleetManagerClient.Schemas.ComponentStatus]) {
        var gpuCheckResult = FleetManagerClient.Schemas.GPUCheckResult()
        gpuCheckResult.timestamp = Date()
        gpuCheckResult.success = false

        var statusArray: [FleetManagerClient.Schemas.ComponentStatus] = []
        if let gpuHealthProvider = gpuHealthProvider {
            var gpuDaemonHealth = FleetManagerClient.Schemas.ComponentStatus()
            gpuDaemonHealth.componentPath = ["gpu-health-daemon"]

            do {
                let gpuHealth = try await gpuHealthProvider.getHealth()
                var gpuComponent = FleetManagerClient.Schemas.ComponentStatus()
                gpuComponent.componentPath = ["gpu-health-daemon", "gpu"]
                gpuComponent.state = HealthMonitor.gpuStatusToComponentStatus(gpuHealth.status)
                if gpuHealth.status != .healthy {
                    let activeFaults = try await gpuHealthProvider.getActiveFaults().faults
                    gpuComponent.message = activeFaults.compactMap { fault -> String? in
                        switch fault.detail {
                        case .xidFault(let xid):
                            return "Critical XID \(xid.xid) on device \(fault.index)/\(fault.uuid)"
                        case .gpuLoss(let loss):
                            return "GPU loss: \(loss.index)/\(loss.uuid)"
                        case .signal(let signal):
                            return
                                "Health signal on device \(fault.index)/\(fault.uuid): \(signal.type)"
                        case .system(let fault):
                            return "GPU system fault: \(fault.message)"
                        case .none:
                            return nil
                        }
                    }.joined(separator: ", ")

                    gpuCheckResult.output = gpuComponent.message

                } else {
                    gpuCheckResult.success = true
                }

                statusArray.append(gpuComponent)

                gpuDaemonHealth.state = .READY
            } catch {
                gpuDaemonHealth.state = .DEGRADED
                gpuDaemonHealth.message =
                    "Failed to get health from gpu-health-daemon: \(error.localizedDescription)"
            }
            statusArray.append(gpuDaemonHealth)
        }
        return (gpuCheckResult, statusArray)
    }

    private func computeConvergence() async -> Bool {
        let basicGpuOk = currentStatus.basicGpuCheck?.success ?? true
        let comprehensiveGpuOk = currentStatus.comprehensiveGpuCheck?.success ?? true

        var cloudboardConverged: Bool?
        if convergenceCheckCloudboard, let store = nodeStatusStore {
            cloudboardConverged = await store.isConverged()
        }

        var fluentBitState: FleetManagerClient.Schemas.ComponentStatus.statePayload?
        if convergenceCheckFluentBit {
            fluentBitState = await fluentBitCheckService.componentStatus.state
        }

        let gpuBlocks = convergenceCheckGpu && (!basicGpuOk || !comprehensiveGpuOk)
        let cloudboardBlocks = convergenceCheckCloudboard && (cloudboardConverged == false)
        let fluentBitBlocks = convergenceCheckFluentBit && (fluentBitState != .READY)
        let converged = !gpuBlocks && !cloudboardBlocks && !fluentBitBlocks

        let componentStatusMetadata: Logger.MetadataValue = .array(
            (currentStatus.componentStatus ?? []).map { component in
                var entry: Logger.Metadata = [:]
                if let path = component.componentPath {
                    entry["componentPath"] = .string("\(path)")
                }
                if let state = component.state {
                    entry["state"] = .string(state.rawValue)
                }
                if let message = component.message {
                    entry["message"] = .string(message)
                }
                return .dictionary(entry)
            })

        logger.info(
            "Computed convergence decision",
            metadata: [
                "converged": "\(converged)",
                "basicGpuOk": "\(basicGpuOk)",
                "comprehensiveGpuOk": "\(comprehensiveGpuOk)",
                "gpuChecksRequired": "\(convergenceCheckGpu)",
                "cloudboardConverged": cloudboardConverged.map { "\($0)" } ?? "n/a",
                "cloudboardRequired": "\(convergenceCheckCloudboard)",
                "fluentBitState": fluentBitState.map { "\($0.rawValue)" } ?? "n/a",
                "fluentBitRequired": "\(convergenceCheckFluentBit)",
                "componentStatus": componentStatusMetadata,
            ])

        return converged
    }

    private static func gpuStatusToComponentStatus(_ status: GpuHealth_V1_InstanceStatus)
        -> FleetManagerClient.Schemas.ComponentStatus.statePayload?
    {
        switch status {
        case .healthy:
            return .READY
        case .unhealthy:
            return .DEGRADED
        case .terminal:
            return .TERMINAL_ERROR
        default:
            return .DEGRADED
        }
    }
}

extension GRPCCore.RPCError: ReportableError {
    public var publicDescription: String {
        return description
    }
}

extension ClientError: ReportableError {
    public var publicDescription: String {
        return localizedDescription
    }
}

#if DEBUG
    extension HealthMonitor {
        func testReportToFleetManager() async {
            await runHealthCheck()
            await reportToFleetManager()
        }

        static func testGpuStatusToComponentStatus(_ status: GpuHealth_V1_InstanceStatus)
            -> FleetManagerClient.Schemas.ComponentStatus.statePayload?
        {
            return HealthMonitor.gpuStatusToComponentStatus(status)
        }
    }
#endif
