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
import CloudBoardJob
import CloudBoardLogging
import Foundation
import InternalGRPC
import InternalSwiftProtobuf
import NIOCore
import NIOTransportServices
import os
import Synchronization
internal import CloudBoardDomain

// Warning: If someone is looking to implement a CloudApp and using this as a template *don't*
// This app is unusual in several respects:
// - It uses package level APIs in CloudBoard not shared in the SDK
// - It does operations that no real cloud app would be allowed to do - access the network
// This is a testing tool, and *not* safe and private as a CloudApp should be, it is blocked from running in customer
// and carry.
// it's not a template to base your real use case on.

@main
actor ShadowTunnelCloudApp: CloudBoardApp {
    /// This is passed to the NullAppRoles where required so that the logging in the null
    /// app is from a consistent source. this makes it easier to diagnose issues for users
    private static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardShadowTunnelApp"
    )

    private final class RemoteTunnel: Sendable {
        let warmupEnvironment: WarmupEnvironment
        let shadowedCloudAppConfig: SecureConfig.CloudAppConfig
        let grpcClient: Com_Apple_Cloudboard_Shadowtunnel_V1_CloudAppRemoteAsyncClient
        let grpcChannel: GRPCChannel
        let eventLoopGroup: NIOTSEventLoopGroup

        internal init(
            warmupEnvironment: WarmupEnvironment,
            shadowedCloudAppConfig: SecureConfig.CloudAppConfig,
            grpcClient: Com_Apple_Cloudboard_Shadowtunnel_V1_CloudAppRemoteAsyncClient,
            grpcChannel: GRPCChannel,
            eventLoopGroup: NIOTSEventLoopGroup
        ) {
            self.warmupEnvironment = warmupEnvironment
            self.shadowedCloudAppConfig = shadowedCloudAppConfig
            self.grpcClient = grpcClient
            self.grpcChannel = grpcChannel
            self.eventLoopGroup = eventLoopGroup
        }

        deinit {
            // best effort tidy up - the process is going away soon anyway
            try? self.grpcChannel.close().wait()
            try? self.eventLoopGroup.syncShutdownGracefully()
        }
    }

    private let tunnel = Mutex<RemoteTunnel?>(nil)

    init() {
        // nothing we can do till we know the cloud app we are shadowing
    }

    func warmup(environment: WarmupEnvironment) async throws {
        Self.log.log("ShadowTunnelCloudApp warmup invoked on behalf of \(environment.cloudAppName)")

        let tunnel = try self.tunnel.withLock { tunnel in
            precondition(tunnel == nil, "multiple warmups not allowed")
            let shadowedCloudAppConfig: SecureConfig.CloudAppConfig
            do {
                Self.log.debug("Loading secure config from SecureConfigDB")
                let secureConfig = try SecureConfigLoader.real.load()
                shadowedCloudAppConfig = try secureConfig.cloudAppConfig(cloudApp: environment.cloudAppName)
                precondition(
                    shadowedCloudAppConfig.shadow.enabled,
                    "ShadowTunnelCloudApp running for \(environment.cloudAppName) despite not being enabled"
                )
                precondition(
                    shadowedCloudAppConfig.shadow.remoteCloudApps,
                    "ShadowTunnelCloudApp running for \(environment.cloudAppName) despite the remoting of the cloud app itself not being enabled"
                )
            } catch {
                fatalError("Error loading secure config: \(String(unredacted: error))")
            }

            // Create gRPC channel to remote
            Self.log
                .log(
                    "Connecting to remote at \(shadowedCloudAppConfig.shadow.remoteHost):\(shadowedCloudAppConfig.shadow.remotePort)"
                )
            let eventLoopGroup = NIOTSEventLoopGroup()
            let channel = try GRPCChannelPool.with(
                target: .hostAndPort(
                    shadowedCloudAppConfig.shadow.remoteHost,
                    shadowedCloudAppConfig.shadow.remotePort
                ),
                transportSecurity: .plaintext,
                eventLoopGroup: eventLoopGroup
            )
            let grpcClient = Com_Apple_Cloudboard_Shadowtunnel_V1_CloudAppRemoteAsyncClient(channel: channel)
            tunnel = RemoteTunnel(
                warmupEnvironment: environment,
                shadowedCloudAppConfig: shadowedCloudAppConfig,
                grpcClient: grpcClient,
                grpcChannel: channel,
                eventLoopGroup: eventLoopGroup
            )
            return tunnel!
        }

        // Call remote warmup
        let warmupRequest = Com_Apple_Cloudboard_Shadowtunnel_V1_WarmupRequest.with {
            $0.cloudAppName = environment.cloudAppName
            $0.launchdJobInstanceUuid = environment.launchdJobInstanceUUID.uuidString
        }

        let warmupResponse = try await tunnel.grpcClient.warmup(warmupRequest)
        guard warmupResponse.success else {
            let errorMsg = warmupResponse.hasErrorMessage ? warmupResponse.errorMessage : "Unknown error"
            throw ShadowTunnelCloudAppError.remoteWarmupFailed(errorMsg)
        }

        Self.log.log("Remote warmup succeeded")
    }

    private static func translateToWorkloadParameterValues(
        _ parameters: [String: [String]]
    ) -> [String: Com_Apple_Cloudboard_Shadowtunnel_V1_WorkloadParameterValues] {
        var result: [String: Com_Apple_Cloudboard_Shadowtunnel_V1_WorkloadParameterValues] = [:]
        for parameter in parameters {
            var values = Com_Apple_Cloudboard_Shadowtunnel_V1_WorkloadParameterValues()
            values.values.append(contentsOf: parameter.value)
            result[parameter.key] = values
        }
        return result
    }

    func run(
        input: CloudBoardJobCore.InputData,
        responder: CloudBoardJobCore.ResponseWriter,
        environment: CloudBoardJobCore.CloudAppEnvironment
    ) async throws {
        let spanID: UInt64 = TraceContextCache.singletonCache.generateNewSpanID()
        let tunnel = self.tunnel.withLock { $0 }!
        try await ShadowTunnelAppRequestSummary(
            serviceName: tunnel.warmupEnvironment.cloudAppName,
            from: environment,
            spanID: spanID
        ).loggingRequestSummary(logger: Self.log) {
            try await self.proxyRequestToRemote(
                input: input,
                responder: responder,
                environment: environment,
                tunnel: tunnel
            )
        }
    }

    private func proxyRequestToRemote(
        input: CloudBoardJobCore.InputData,
        responder: CloudBoardJobCore.ResponseWriter,
        environment: CloudBoardJobCore.CloudAppEnvironment,
        tunnel: RemoteTunnel
    ) async throws {
        // Create bidirectional streaming call
        let runCall = tunnel.grpcClient.makeRunCall()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 1: Send environment metadata + input stream to remote
            group.addTask {
                // Send first message with environment metadata
                let metadata = Com_Apple_Cloudboard_Shadowtunnel_V1_CloudAppEnvironmentMetadata.with {
                    $0.plaintextMetadata = Com_Apple_Cloudboard_Shadowtunnel_V1_PlaintextMetadata.with {
                        $0.bundleID = environment.plaintextMetadata.bundleID
                        $0.bundleVersion = environment.plaintextMetadata.bundleVersion
                        $0.featureID = environment.plaintextMetadata.featureID
                        $0.clientInfo = environment.plaintextMetadata.clientInfo
                        $0.workloadType = environment.plaintextMetadata.workloadType
                        $0.workloadParameters = Self.translateToWorkloadParameterValues(
                            environment.plaintextMetadata.workloadParameters
                        )
                        $0.requestID = environment.plaintextMetadata.requestID
                        $0.automatedDeviceGroup = environment.plaintextMetadata.automatedDeviceGroup
                    }
                    $0.requestBypassed = environment.requestBypassed
                    $0.traceContext = Com_Apple_Cloudboard_Shadowtunnel_V1_TraceContext.with {
                        $0.traceID = environment.updatedTraceContext.traceID
                        $0.spanID = environment.updatedTraceContext.spanID
                    }
                    $0.ensembleInstanceID = Com_Apple_Cloudboard_Shadowtunnel_V1_EnsembleInstanceId.with {
                        $0.ensembleID = environment.ensembleInstanceID.ensembleId
                        $0.bootID = environment.ensembleInstanceID.bootId
                    }
                    $0.rackID = environment.rackID.rackId
                    $0.launchdJobInstanceUuid = environment.launchdJobInstanceUUID.uuidString
                    $0.supportApps = environment.supportApps
                }

                try await runCall.requestStream.send(.with { $0.environment = metadata })

                // Stream input data chunks
                for try await chunk in input {
                    try await runCall.requestStream.send(.with {
                        $0.inputChunk = Com_Apple_Cloudboard_Shadowtunnel_V1_InputDataChunk.with {
                            $0.data = chunk
                        }
                    })
                }

                // Signal end of input
                try await runCall.requestStream.send(.with {
                    $0.inputEnd = Com_Apple_Cloudboard_Shadowtunnel_V1_InputStreamEnd()
                })
                runCall.requestStream.finish()
            }

            // Task 2: Receive output stream from remote and write to responder
            group.addTask {
                for try await response in runCall.responseStream {
                    switch response.payload {
                    case .outputChunk(let chunk):
                        try await responder.write(chunk.data)
                    case .outputEnd:
                        try responder.finish()
                        return
                    case .error(let error):
                        throw ShadowTunnelCloudAppError.remoteError(error.errorMessage)
                    case .none:
                        throw ShadowTunnelCloudAppError.remoteError("Received response with no payload")
                    }
                }
            }

            // Wait for both tasks to complete
            try await group.waitForAll()
        }
    }

    func teardown() async throws {
        guard let tunnel = self.tunnel.withLock({ $0 }) else {
            // never got warmed up, fine to just exit
            Self.log.log("ShadowTunnelCloudApp teardown invoked without a successful warmup, exiting")
            exit(0)
        }

        Self.log.log("ShadowTunnelCloudApp teardown invoked, informing remote")

        // Call remote teardown
        let teardownRequest = Com_Apple_Cloudboard_Shadowtunnel_V1_TeardownRequest()
        let teardownResponse = try await tunnel.grpcClient.teardown(teardownRequest)

        guard teardownResponse.success else {
            let errorMsg = teardownResponse.hasErrorMessage ? teardownResponse.errorMessage : "Unknown error"
            throw ShadowTunnelCloudAppError.remoteTeardownFailed(errorMsg)
        }

        Self.log.log("Remote teardown succeeded")
        // release the tunnel and let deinit run
        self.tunnel.withLock { $0 = nil }
    }
}

enum ShadowTunnelCloudAppError: ReportableError {
    case notImplementedYet(String)
    case remoteWarmupFailed(String)
    case remoteError(String)
    case remoteTeardownFailed(String)

    var publicDescription: String {
        switch self {
        case .notImplementedYet(let description):
            return "notImplementedYet: \(description)"
        case .remoteWarmupFailed(let description):
            return "remoteWarmupFailed: \(description)"
        case .remoteError(let description):
            return "remoteError: \(description)"
        case .remoteTeardownFailed(let description):
            return "remoteTeardownFailed: \(description)"
        }
    }
}
