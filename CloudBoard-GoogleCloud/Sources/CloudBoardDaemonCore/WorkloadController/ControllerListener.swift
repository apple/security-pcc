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

import CloudBoardControllerCore
import CloudBoardProtos
import CloudBoardUtilities
import Configuration
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Note:
// For now the sequence is simple enough not to require explicit state machines:
// 1. We create the controller listener, and run the `withControllerListener` handler ~immediately
// 2. We wait for controller to register, this is done with `waitForWorkloadRegistration`
// 3. Subsequently any changes to the controller (whether it's lower level rpc transport, or explicitly
//    communicated state), is done through a narrow set of functions exposing the current state. Note that we expect the controller to call us back with
//  `registerWorkload` fairly frequently (on each recycle?).
struct ControllerListener {
    private static let logger = Logger(label: "cloudboardd.ControllerListener")

    let workloadProperties: AsyncValueBox<(WorkloadProperties, ComputeWorkloadConfig)>
    let statusMonitor: ServiceStatusMonitor
    let skipExternal: Bool

    init(
        statusMonitor: ServiceStatusMonitor,
        skipExternal: Bool
    ) {
        self.workloadProperties = AsyncValueBox()
        self.statusMonitor = statusMonitor
        self.skipExternal = skipExternal
    }

    private enum TaskGroupResult<First: Sendable, Second: Sendable, Third: Sendable, Fourth: Sendable> {
        case first(First)
        case second(Second)
        case third(Third)
        case fourth(Fourth)
    }

    static func withControllerListener<R: Sendable>(
        configReader: ConfigReader,
        statusMonitor: ServiceStatusMonitor,
        skipExternal: Bool,
        _ handler: @Sendable @escaping (ControllerListener) async throws -> R
    ) async throws -> R {
        let listeningPort = configReader.int(forKey: "workload.controller.grpc.listeningport", default: 4443)
        let udsPath = configReader.string(
            forKey: "workload.controller.grpc.uds",
            default: "/var/run/tie-controllerd/tie-controllerd.sock"
        )
        // TODO: abstract this pattern into helper
        return try await withThrowingTaskGroup(of: TaskGroupResult<R, Void, Void, Void>.self) { group in
            let this = Self(
                statusMonitor: statusMonitor,
                skipExternal: skipExternal
            )

            let services = [
                ControllerGRPCService(
                    workloadProperties: this.workloadProperties,
                    statusMonitor: this.statusMonitor,
                    skipExternal: this.skipExternal
                )
            ]

            group.addTask {
                let result = try await handler(this)
                return .first(result)
            }
            group.addTask {
                try await this.runTCPServer(port: listeningPort, services: services)
                return .second(Void())
            }
            group.addTask {
                try await this.runUDSServer(path: udsPath, services: services)
                return .third(Void())
            }
            group.addTask {
                await this.runSubscriber(configReader: configReader)
                return .fourth(Void())
            }

            for try await result in group {
                switch result {
                case .first(let result):
                    group.cancelAll()
                    return result
                case .second, .third:
                    fatalError("Controller server finished before the workload. This is unexpected.")
                case .fourth:
                    break  // subscriber exited; continue waiting for handler
                }
            }
            fatalError("Task group exhausted without the handler task returning — this is a bug")
        }
    }

    func runTCPServer(port: Int, services: [any RegistrableRPCService]) async throws {
        let server = GRPCServer(
            transport: .http2NIOPosix(
                address: .ipv4(
                    host: "127.0.0.1",
                    port: port
                ),
                transportSecurity: .plaintext
            ),
            services: services
        )
        try await server.run()
    }

    func runUDSServer(path: String, services: [any RegistrableRPCService]) async throws {
        let server = GRPCServer(
            transport: .http2NIOPosix(
                address: .unixDomainSocket(path: path),
                transportSecurity: .plaintext
            ),
            services: services
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.run()
            }

            // Once the socket is bound, relax its permissions so the workload controller can connect() even when
            // running as a different user.
            group.addTask {
                do {
                    _ = try await server.transport.listeningAddress
                    try FileManager.default.setAttributes([.posixPermissions: 0o766], ofItemAtPath: path)
                    Self.logger.info("Relaxed controller socket permissions", metadata: ["path": "\(path)"])
                } catch is CancellationError {
                    // Graceful shutdown
                } catch {
                    Self.logger.error(
                        "Failed to relax controller socket permissions",
                        metadata: ["path": "\(path)", "error": "\(String(reportable: error))"]
                    )
                    throw error
                }
            }

            try await group.waitForAll()
        }
    }

    func waitForWorkloadRegistration() async throws -> (WorkloadProperties, ComputeWorkloadConfig) {
        Self.logger.info("Waiting for workload registration")
        let result = try await self.workloadProperties.get()
        Self.logger.info("Workload registration received", metadata: ["workloadName": "\(result.0.workloadName)"])
        return result
    }

    func runSubscriber(configReader: ConfigReader) async {
        let config = WorkloadStateSubscriberConfiguration(configReader: configReader)
        guard config.enabled else {
            Self.logger.info("WorkloadStateSubscriber is inactive (workload.state.enabled is false)")
            return
        }
        Self.logger.info("Connecting to workload state server", metadata: ["path": "\(config.udsPath)"])
        do {
            let subscriber = try WorkloadStateSubscriber(
                statusMonitor: self.statusMonitor,
                workloadProperties: self.workloadProperties,
                configuration: config
            )
            try await subscriber.run()
        } catch {
            Self.logger.error(
                "WorkloadStateSubscriber encountered an error",
                metadata: ["error": "\(String(reportable: error))"]
            )
            await self.statusMonitor.updateWorkloadState(
                .terminalError(message: "WorkloadStateSubscriber exited unexpectedly")
            )
        }
    }
}

struct ControllerGRPCService: Proto_Controller_Controller.SimpleServiceProtocol {
    private static let logger = Logger(label: "cloudboardd.ControllerGRPCService")

    let workloadProperties: AsyncValueBox<(WorkloadProperties, ComputeWorkloadConfig)>
    let statusMonitor: ServiceStatusMonitor
    let skipExternal: Bool

    init(
        workloadProperties: AsyncValueBox<(WorkloadProperties, ComputeWorkloadConfig)>,
        statusMonitor: ServiceStatusMonitor,
        skipExternal: Bool
    ) {
        self.workloadProperties = workloadProperties
        self.statusMonitor = statusMonitor
        self.skipExternal = skipExternal
    }

    func registerWorkload(
        request: Proto_Controller_RegisterWorkloadProperties,
        context: ServerContext
    ) async throws -> Proto_Controller_RegisterWorkloadResult {
        guard !self.skipExternal else {
            Self.logger.info(
                "Ignoring registerWorkload: workload controller is bypassed (WORKLOAD_CONTROLLER_SKIPEXTERNAL=true)"
            )
            return .with { _ in }
        }

        let workloadProperties = WorkloadProperties(from: request.workloadProperties)
        let computeWorkloadConfig = ComputeWorkloadConfig(from: request.computeWorkloadConfig)

        let stored = self.workloadProperties.put((workloadProperties, computeWorkloadConfig))
        if !stored {
            Self.logger.info(
                "Workload properties update ignored (already registered; fire-once box)",
                metadata: ["workloadName": "\(workloadProperties.workloadName)"]
            )
        }
        return .with { _ in
        }
    }

    func setState(
        request: Proto_Controller_WorkloadControllerState,
        context: ServerContext
    ) async throws -> Proto_Controller_SetStateResult {
        guard !self.skipExternal else {
            Self.logger.info(
                "Ignoring setState: workload controller is bypassed (WORKLOAD_CONTROLLER_SKIPEXTERNAL=true)"
            )
            return .with { _ in }
        }
        let workloadStatus: ServiceStatusMonitor.ComponentStatus
        switch request.kind.kind {
        case .initializing(let init_):
            workloadStatus = .initializing(phase: init_.phase)
        case nil:
            // nil means the proto was received without a oneof kind set — this is always
            // unexpected and indicates a protocol mismatch. Treat as a transient error so
            // the node self-recovers if the controller resends a valid state.
            Self.logger.error("Received workload state update with unrecognized state — treating as transient error")
            workloadStatus = .transientError(message: "Unknown workload controller state received")
        case .ready:
            workloadStatus = .ready
        case .busy(let busy):
            workloadStatus = .busy(reason: busy.reason)
        case .transientError(let error):
            workloadStatus = .transientError(message: error.message)
        case .terminalError(let error):
            workloadStatus = .terminalError(message: error.message)
        }
        Self.logger.info(
            "Dispatching workload state update",
            metadata: ["status": "\(workloadStatus)"]
        )
        await self.statusMonitor.updateWorkloadState(workloadStatus)
        Self.logger.info(
            "Workload state update dispatched",
            metadata: ["status": "\(workloadStatus)"]
        )
        return .with { _ in }
    }
}
