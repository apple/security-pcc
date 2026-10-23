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

import struct AppleCertificates.PolicyAPRN
import CloudBoardCommon
import CloudBoardController
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import Logging
import NIOCore
import NIOTransportServices
import os
import PersistentHelperInstance
import Synchronization

/// Lightweight manager for a single persistent service.
///
/// Unlike `WorkloadManager` (which orchestrates job helpers, prewarming, health monitoring, and ROPES-mediated
/// request handling for a CloudApp), `PersistentServiceManager` manages a single long-lived gRPC endpoint served
/// on its own dedicated port. It owns:
/// - A `PersistentServiceProvider` (the gRPC handler for bidirectional streams)
/// - Its own gRPC server on a dedicated port
/// - Draining support for graceful shutdown
package final class PersistentServiceManager: Sendable {
    static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentServiceManager"
    )

    /// Identifier for this persistent service (e.g. "trusted-filter").
    let serviceId: String

    /// Health monitor for this persistent service, published to HealthServer.
    let healthMonitor: ServiceHealthMonitor

    /// The gRPC handler for InvokePersistentService RPCs.
    let persistentServiceProvider: PersistentServiceProvider

    /// The helper instance provider, retained for bulk teardown on server exit.
    private let helperInstanceProvider: PersistentHelperInstanceProvider

    init(
        serviceId: String,
        helperInstanceProvider: PersistentHelperInstanceProvider,
        attestationProvider: AttestationProvider,
        healthMonitor: ServiceHealthMonitor? = nil,
        drainJitterConfig: DrainJitterConfig
    ) {
        self.serviceId = serviceId
        self.helperInstanceProvider = helperInstanceProvider
        self.healthMonitor = healthMonitor ?? ServiceHealthMonitor(cloudApp: serviceId)
        self.persistentServiceProvider = PersistentServiceProvider(
            helperInstanceProvider: helperInstanceProvider,
            attestationProvider: attestationProvider,
            serviceId: serviceId,
            drainJitterConfig: drainJitterConfig
        )
    }

    /// Runs the persistent service gRPC server.
    ///
    /// The gRPC server starts immediately. The `machServiceName` needed by the provider
    /// is supplied to it on the first controller registration; until then the provider
    /// rejects incoming connections as not-ready. The first controller registration also
    /// triggers the initial service discovery announcement; subsequent re-registrations
    /// update service discovery metadata.
    ///
    /// - Parameters:
    ///   - identityCallback: TLS identity callback for secure connections, or nil for insecure.
    ///   - serviceAddress: The socket address to bind the dedicated gRPC port on.
    ///   - serviceDiscovery: Optional service discovery publisher for announcing this service.
    func run(
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        serviceAddress: SocketAddress,
        expectedPeerAPRNs: [APRN]?,
        serviceDiscovery: ServiceDiscoveryPublisherProtocol?,
        workloadControllerServer: WorkloadControllerServer?,
        portPromise: Promise<Int, Error>? = nil
    ) async throws {
        Self.logger.log(
            "Starting PersistentServiceManager for service '\(self.serviceId, privacy: .public)' at \(serviceAddress, privacy: .public)"
        )

        // All registrations (including the first) flow through this stream for service
        // discovery announcements. The first also fulfills the machServiceName promise.
        let (registrationStream, registrationContinuation) = AsyncStream<PersistentServiceConfig>.makeStream()
        let receivedFirst = Mutex(false)

        // Set up handler for persistent service registrations before starting the server.
        // When the right controller (e.g. PrivateFilterController) registers we link up.
        // This _MUST_ happen before starting the server so mocks have a stable means to wait for this to
        // be hooked up.
        // In real environments the XPC messages themselves would be buffered as needed.
        await workloadControllerServer?.onPersistentServiceRegistration {
            [weak self] config, _ in
            guard let self else { return }
            guard self.serviceId == config.serviceId else {
                return
            }
            Self.logger.log(
                "Persistent service registration received: serviceId=\(config.serviceId, privacy: .public) machServiceName=\(config.machServiceName, privacy: .public)"
            )
            let isFirst = receivedFirst.withLock { first in
                if !first {
                    first = true
                    return true
                }
                return false
            }
            if isFirst {
                self.persistentServiceProvider.markControllerRegistered(machServiceName: config.machServiceName)
                self.healthMonitor.updateStatus(.healthy(.persistentService))
            }
            registrationContinuation.yield(config)
        }

        // A terminal failure for this service (e.g. the controller exhausted its asset download retries during
        // initialization) drives the health monitor terminal so the node reports unhealthy and convergence fails
        // fast, rather than sitting in `.initializing` until the convergence timeout. This can arrive before any
        // registration, so it is keyed purely by serviceId.
        await workloadControllerServer?.onPersistentServiceTerminalFailure { [weak self] serviceId, reason in
            guard let self else { return }
            guard self.serviceId == serviceId else {
                return
            }
            Self.logger.error(
                "Persistent service '\(self.serviceId, privacy: .public)' reported terminal failure: \(reason, privacy: .public)"
            )
            self.healthMonitor.updateStatus(.terminal)
        }

        do {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.runGRPCServer(
                        identityCallback: identityCallback,
                        serviceAddress: serviceAddress,
                        expectedPeerAPRNs: expectedPeerAPRNs,
                        portPromise: portPromise
                    )
                    return "\(self.serviceId)::grpcServer"
                }

                if let serviceDiscovery {
                    group.addTask {
                        try await serviceDiscovery.run()
                        return "\(self.serviceId)::serviceDiscovery"
                    }
                }

                // Forward registrations to service discovery. This handles both the initial
                // announcement and subsequent re-registrations (e.g. metadata updates).
                group.addTask { [serviceId = self.serviceId] in
                    for await config in registrationStream {
                        Self.logger.log(
                            "Persistent service '\(serviceId, privacy: .public)' announcing to service discovery"
                        )
                        serviceDiscovery?.announceService(
                            name: serviceId,
                            workloadConfig: ServiceDiscoveryWorkloadConfig(
                                workloadType: .persistentService(config.metadata),
                                workloadTags: config.workloadTags,
                                appRoutingKeys: Self.filterIDs(from: config.metadata)
                            )
                        )
                    }
                    return "\(serviceId)::registrationUpdates"
                }

                let name = try await group.next()
                Self.logger.log(
                    "PersistentServiceManager '\(self.serviceId, privacy: .public)': \(name ?? "nil", privacy: .public) exited - cancelling"
                )
                registrationContinuation.finish()
                group.cancelAll()
            }
        } catch {
            // When the gRPC server exits with an error, ensure all helper processes are terminated.
            self.healthMonitor.updateStatus(.unhealthy)
            await self.helperInstanceProvider.teardownAllInstances()
            throw error
        }

        // When the gRPC server exits cleanly, ensure all helper processes are terminated.
        await self.helperInstanceProvider.teardownAllInstances()
    }

    /// Drains the persistent service, blocking until all active connections finish.
    func drain() async {
        Self.logger.log("Draining PersistentServiceManager for service '\(self.serviceId, privacy: .public)'")
        self.healthMonitor.drain()
        await self.persistentServiceProvider.drain()
    }

    /// Extracts unique filter IDs from the service-defined metadata JSON.
    ///
    /// The metadata is expected to contain a `"shards"` array where each element
    /// has a `"filterID"` string. Returns an empty array if the metadata is absent
    /// or does not match the expected schema.
    static func filterIDs(from metadata: PersistentServiceConfig.ServiceMetadata) -> [String] {
        guard
            let jsonString = metadata.serviceDefinedMetadata,
            let data = jsonString.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let shards = root["shards"] as? [[String: Any]]
        else {
            return []
        }
        var seen = Set<String>()
        return shards.compactMap { shard in
            guard let filterID = shard["filterID"] as? String else { return nil }
            return seen.insert(filterID).inserted ? filterID : nil
        }
    }

    private func runGRPCServer(
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        serviceAddress: SocketAddress,
        expectedPeerAPRNs: [APRN]?,
        portPromise: Promise<Int, Error>?
    ) async throws {
        let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 1)
        do {
            try await self._runGRPCServer(
                eventLoopGroup: eventLoopGroup,
                identityCallback: identityCallback,
                serviceAddress: serviceAddress,
                expectedPeerAPRNs: expectedPeerAPRNs,
                portPromise: portPromise
            )
            try? await eventLoopGroup.shutdownGracefully()
        } catch {
            portPromise?.fail(with: error)
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }

    private func _runGRPCServer(
        eventLoopGroup: NIOTSEventLoopGroup,
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        serviceAddress: SocketAddress,
        expectedPeerAPRNs _: [APRN]?,
        portPromise: Promise<Int, Error>?
    ) async throws {
        let providers: [CallHandlerProvider] = [self.persistentServiceProvider]

        let loggingLogger = Logging.Logger(
            osLogSubsystem: "com.apple.cloudos.cloudboard",
            osLogCategory: "PersistentServiceManager",
            domain: "GRPCServer"
        )

        let server: Server
        if let identityCallback {
            let policyAPRNs: [PolicyAPRN] = [
                GRPCTLSConfiguration.persistentServicePeerPolicyAPRN,
            ]
            Self.logger.info(
                "PersistentService configuring mTLS with PolicyAPRNs: \(policyAPRNs.map(\.description), privacy: .public)"
            )
            let config = try GRPCTLSConfiguration.cloudboardProviderConfiguration(
                identityCallback: identityCallback,
                expectedPeerPolicyAPRNs: policyAPRNs,
                metricsSystem: CloudMetricsSystem(clientName: "persistentService")
            )
            server = try await Server.usingTLS(with: config, on: eventLoopGroup)
                .withServiceProviders(providers)
                .withLogger(loggingLogger)
                .bind(host: serviceAddress.ipAddress!, port: serviceAddress.port!).get()
        } else {
            server = try await Server.insecure(group: eventLoopGroup)
                .withServiceProviders(providers)
                .withLogger(loggingLogger)
                .bind(host: serviceAddress.ipAddress!, port: serviceAddress.port!).get()
        }

        Self.logger.info(
            "PersistentService '\(self.serviceId, privacy: .public)' bound at \(String(describing: server.channel.localAddress), privacy: .public)"
        )

        portPromise?.succeed(with: server.channel.localAddress!.port!)

        try await withLifecycleManagementHandlers(label: "PersistentService(\(self.serviceId))") {
            try await withTaskCancellationHandler {
                try await server.onClose.get()
            } onCancel: {
                server.close(promise: nil)
            }
        } onDrain: {
            await self.persistentServiceProvider.drain()
        }
    }
}
