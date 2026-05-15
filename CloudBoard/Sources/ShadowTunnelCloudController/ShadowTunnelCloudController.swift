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
import CloudBoardLogging
import Foundation
import InternalGRPC
import InternalSwiftProtobuf
import NIOCore
import NIOTransportServices
import os

/// One of these is instantiated and run for each cloud app
/// This *only* executes if the policy allowed it and it was configured to do so
actor ShadowTunnelCloudController {
    typealias ProtoStartupInfo = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_StartupInfo
    typealias ProtoStateTransition = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_StateTransition
    typealias ProtoControllerEvent = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_ControllerEvent
    typealias ProtoRegisterWorkload = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_RegisterWorkload
    typealias ProtoRoutingTagValue = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_RoutingTagValue
    typealias ProtoUpdateHealthStatus = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_UpdateHealthStatus
    typealias ProtoWorkloadControllerState = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_WorkloadControllerState
    typealias ProtoReady = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_Ready

    /// abstract away being truly connected to the remote, or just providing automatic events
    private protocol Remote: Sendable {
        func startup(_ info: ProtoStartupInfo) async throws
        func establishTunnel(
            send: AsyncStream<ProtoStateTransition>,
            receive: AsyncStream<ProtoControllerEvent>.Continuation
        ) async throws
    }

    private let log: Logger
    private let cloudApp: String
    private let config: SecureConfig.CloudAppConfig
    private let secureConfig: SecureConfig
    private let controller: CloudBoardWorkloadController
    private let uuid = UUID()
    private let remote: any Remote

    private var connectionID = 0

    init(
        cloudApp: String,
        config: SecureConfig.CloudAppConfig,
        secureConfig: SecureConfig
    ) async throws {
        // One final check here even though it was previously checked
        precondition(config.shadow.enabled, "\(cloudApp) not configured to be tunneled at all")

        self.log = Logger(
            subsystem: "com.apple.cloudos.cloudboard",
            // we embed it here, but also include it in a few messages for ease of use
            category: "ShadowTunnelCloudController_\(cloudApp)"
        )
        // Make onShutdown closure Sendable
        let log = self.log

        self.cloudApp = cloudApp
        self.config = config
        self.secureConfig = secureConfig

        self.controller = try await CloudBoardWorkloadController()
        switch config.shadow.cloudController {
        case .original:
            fatalError(
                "\(cloudApp) remoted, but the controller is original - this type should not have been instantiated"
            )
        case .fixed:
            self.remote = try Fixed(shadowedCloudAppConfig: config)
        case .remote:
            self.remote = try RemoteTunnel(
                log: self.log,
                shadowedCloudAppConfig: config
            )
        }

        await self.controller.onShutdown {
            log.log("Handling shutdown from cloudboardd")
        }
        await self.controller.onDisconnect { @Sendable in
            self.log.warning("Handling disconnect from cloudboardd")
            await self.incrementConnectionID()
        }
    }

    private final class RemoteTunnel: Remote {
        let grpcClient: Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_ControllerRemoteAsyncClient
        let grpcChannel: GRPCChannel
        let eventLoopGroup: NIOTSEventLoopGroup

        init(
            log: Logger,
            shadowedCloudAppConfig: SecureConfig.CloudAppConfig
        ) throws {
            log.log(
                "Connecting to remote at \(shadowedCloudAppConfig.shadow.remoteHost):\(shadowedCloudAppConfig.shadow.remotePort)"
            )
            self.eventLoopGroup = NIOTSEventLoopGroup()
            self.grpcChannel = try GRPCChannelPool.with(
                target: .hostAndPort(
                    shadowedCloudAppConfig.shadow.remoteHost,
                    shadowedCloudAppConfig.shadow.remotePort
                ),
                transportSecurity: .plaintext,
                eventLoopGroup: self.eventLoopGroup
            )

            self.grpcClient = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_ControllerRemoteAsyncClient(
                channel: self.grpcChannel
            )
        }

        func startup(_ info: ProtoStartupInfo) async throws {
            // no content in the response, not failing is sufficent
            _ = try await self.grpcClient.startup(info)
        }

        func establishTunnel(
            send: AsyncStream<ProtoStateTransition>,
            receive: AsyncStream<ProtoControllerEvent>.Continuation
        ) async throws {
            // Create bidirectional streaming call
            let runCall = self.grpcClient.makeRunCall()

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Task 1: Send environment metadata + input stream to remote
                group.addTask {
                    // Stream input data chunks
                    for try await transition in send {
                        try await runCall.requestStream.send(transition)
                    }
                    runCall.requestStream.finish()
                }

                // Task 2: Receive output stream from remote and write to responder
                group.addTask {
                    for try await event in runCall.responseStream {
                        receive.yield(event)
                    }
                }
                // Wait for both tasks to complete
                try await group.waitForAll()
            }
        }

        deinit {
            // this happens on process shutdown anyway, so just do best effort
            try? self.grpcChannel.close().wait()
            try? self.eventLoopGroup.syncShutdownGracefully()
        }
    }

    /// not actually remote - just responds as needed
    private struct Fixed: Remote {
        let maxBatchSize: Int32
        let optimalBatchSize: Int32
        let workloadName: String
        let workloadTags: [String: ProtoRoutingTagValue]

        init(
            shadowedCloudAppConfig: SecureConfig.CloudAppConfig
        ) throws {
            self.maxBatchSize = Int32(shadowedCloudAppConfig.shadow.fixedMaxBatchSize)
            self.optimalBatchSize = Int32(shadowedCloudAppConfig.shadow.fixedOptimalBatchSize)
            self.workloadName = shadowedCloudAppConfig.shadow.workloadName
            // none required - RGA will be added elsewhere if needed
            self.workloadTags = [:]
        }

        func startup(_: ProtoStartupInfo) async throws {
            // nothing to do
        }

        func establishTunnel(
            send: AsyncStream<ProtoStateTransition>,
            receive: AsyncStream<ProtoControllerEvent>.Continuation
        ) async throws {
            for try await transition in send {
                if let payload = transition.payload {
                    switch payload {
                    case .connected:
                        // first register
                        let register = ProtoRegisterWorkload.with {
                            $0.maxBatchSize = self.maxBatchSize
                            $0.optimalBatchSize = self.optimalBatchSize
                            $0.workloadName = self.workloadName
                            $0.workloadTags = self.workloadTags
                        }
                        receive.yield(ProtoControllerEvent.with { $0.workload = register })
                        // then say we are healthy
                        let healthy = ProtoUpdateHealthStatus.with {
                            $0.state = ProtoWorkloadControllerState.with {
                                $0.ready = ProtoReady()
                            }
                        }
                        receive.yield(ProtoControllerEvent.with { $0.updateHealthStatus = healthy })
                    case .disconnected:
                        () // nothing to do till reconnect
                    }
                }
            }
        }
    }

    func run() async throws {
        self.log.log("Hello from ShadowTunnelCloudController for \(self.cloudApp, privacy: .public)")

        // we don't do anything till we are connected to our remote
        try await self.remote.startup(ProtoStartupInfo.with {
            $0.cloudAppName = self.cloudApp
            $0.instanceUuid = self.uuid.uuidString
        })

        let (sendStream, sendContinuation) = AsyncStream<ProtoStateTransition>.makeStream()
        let (receiveStream, receiveContinuation) = AsyncStream<ProtoControllerEvent>.makeStream()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 1: Send environment metadata + input stream to remote
            group.addTask {
                // establish connection
                try await self.remote.establishTunnel(
                    send: sendStream,
                    receive: receiveContinuation
                )
            }
            // Taks 2: Poll controller for connection status
            group.addTask {
                while true {
                    let connectionID = await self.connectionID
                    await self.controller.connect()
                    // Tell the remote we are (re)connected
                    // we expect it to then send us:
                    // 1: registerWorkload
                    // 2: updateHealthStatus
                    sendContinuation.yield(ProtoStateTransition.with {
                        $0.connected = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_Connected()
                    })

                    while await self.connectionID == connectionID {
                        try await Task.sleep(for: .seconds(5))
                    }

                    self.log.warning("Detected cloudboardd disconnect, re-registering")
                    sendContinuation.yield(ProtoStateTransition.with {
                        $0.disconnected = Com_Apple_Cloudboard_Shadowtunnel_Controller_V1_Disconnected()
                    })
                }
            }

            // Task 3: Receive stream from remote and notify controller
            group.addTask {
                for try await response in receiveStream {
                    guard let payload = response.payload else {
                        self.log.warning("ControllerEvent with empty payload from remote - ignoring")
                        continue
                    }
                    // Deliberate decision not to expose restarting the prewarmed instances for now
                    // if needed allow it.
                    switch payload {
                    case .workload(let workload):
                        try await self.registerWorkLoad(workload)
                    case .updateHealthStatus(let status):
                        guard let state = status.state.payload else {
                            self.log.warning("updateHealthStatus with empty state from remote - ignoring")
                            continue
                        }
                        try await self.updateHealthStatus(state)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    private func registerWorkLoad(
        _ workload: ProtoRegisterWorkload
    ) async throws {
        var tags: [String: RoutingTagValue] = [:]
        // we do *not* let the remote mess with the RGA, mis-configuring this could result in significant
        // complications for other users in ephemeral, whatever the config indicates is used
        let rgaTagKey = "routingGroupAliases"
        if let rga = secureConfig.routingGroupAliases {
            tags[rgaTagKey] = RoutingTagValue.stringList(rga)
        }
        for tag in workload.workloadTags {
            switch tag.key {
            case rgaTagKey:
                self.log
                    .warning("ignoring \(tag.key, privacy: .public) from remote - this is not allowed to be changed")
            default:
                switch tag.value.payload {
                case .none:
                    self.log.error("ignoring \(tag.key, privacy: .public) with empty payload from remote")
                case .some(ProtoRoutingTagValue.OneOf_Payload.list(let list)):
                    tags[tag.key] = RoutingTagValue.stringList(list.values)
                case .some(ProtoRoutingTagValue.OneOf_Payload.single(let single)):
                    tags[tag.key] = RoutingTagValue.string(single.value)
                }
            }
        }
        self.log.log("Sending RegisterWorkload...")
        // Currently we only support shadow apps for compute workloads
        try await self.controller.registerComputeWorkload(
            config: .init(
                maxBatchSize: Int(workload.maxBatchSize),
                optimalBatchSize: Int(workload.optimalBatchSize),
                // this is defunct - no point plumbing it from remote
                currentBatchSize: 0,
                workloadTags: tags,
            ),
            properties: WorkloadProperties(
                workloadName: workload.workloadName.isEmpty ? self.config.shadow.workloadName : workload.workloadName,
                cloudAppName: self.cloudApp
            )
        )
    }

    private func updateHealthStatus(
        _ state: ProtoWorkloadControllerState.OneOf_Payload
    ) async throws {
        let controllerState: WorkloadControllerState = switch state {
        case .initializing:
            .initializing
        case .ready:
            .ready
        case .busy(let busy):
            if busy.hasReason {
                .busyWithReason(busy.reason)
            } else {
                .busy
            }
        case .error(let error):
            .error(message: error.hasMessage ? error.message : nil)
        }
        self.log.log("Sending status \(controllerState)")
        try await self.controller.updateHealthStatus(
            status: WorkloadControllerStatus(state: controllerState)
        )
    }

    private func incrementConnectionID() {
        self.connectionID += 1
    }
}
