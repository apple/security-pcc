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
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import InternalSwiftProtobuf
import Logging
import NIOCore
import NIOTransportServices
import os
import Synchronization

final class ServiceDiscoverySubscriber: ServiceDiscoverySubscriberProtocol {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ServiceDiscoverySubscriber"
    )

    private static let grpcBackgroundActivityLogger = Logging.Logger(
        osLogSubsystem: "com.apple.cloudos.cloudboard",
        osLogCategory: "ServiceDiscoverySubscriber",
        domain: "BackgroundActivity"
    )

    private static let grpcClientLogger = Logging.Logger(
        osLogSubsystem: "com.apple.cloudos.cloudboard",
        osLogCategory: "ServiceDiscoverySubscriber",
        domain: "GRPC"
    )

    /// Configuration for the SD subscriber, derived from the shared platform config.
    struct Config: Sendable {
        let targetHost: String
        let targetPort: Int
        let scope: String
        let namespace: String
        let region: String
        let zone: String?
        let environment: String?
        let tlsConfig: GRPCClientConfiguration.TLSConfiguration?
        let backoffConfig: GRPCClientConfiguration.ConnectionBackoff?
        let keepalive: CloudBoardDConfiguration.Keepalive?

        init(from sdConfig: CloudBoardDConfiguration.ServiceDiscovery, scope: String = "global") {
            self.targetHost = sdConfig.targetHost
            self.targetPort = sdConfig.targetPort
            self.scope = scope
            self.namespace = sdConfig.namespace
            self.region = sdConfig.serviceRegion
            self.zone = sdConfig.serviceZone
            self.environment = sdConfig.lbConfig["environment"]
            self.tlsConfig = sdConfig.tlsConfig
            self.backoffConfig = sdConfig.backoffConfig
            self.keepalive = sdConfig.keepalive
        }

        /// Test-only initializer with explicit values.
        init(
            targetHost: String,
            targetPort: Int,
            scope: String = "global",
            namespace: String = "private-cloud-compute",
            region: String,
            zone: String? = nil,
            environment: String? = nil,
            tlsConfig: GRPCClientConfiguration.TLSConfiguration? = nil,
            backoffConfig: GRPCClientConfiguration.ConnectionBackoff? = nil,
            keepalive: CloudBoardDConfiguration.Keepalive? = nil
        ) {
            self.targetHost = targetHost
            self.targetPort = targetPort
            self.scope = scope
            self.namespace = namespace
            self.region = region
            self.zone = zone
            self.environment = environment
            self.tlsConfig = tlsConfig
            self.backoffConfig = backoffConfig
            self.keepalive = keepalive
        }
    }

    private let grpcClient: Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_ServiceDiscoveryAsyncClientProtocol
    private let config: Config
    private let serviceNames: [String]
    private let backoffStrategy: ExponentialBackoffStrategy
    private let instancesByService: Mutex<[String: [Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_InstanceInfo]]>
    private let healthByService: Mutex<[String: Bool]>
    private let metricsSystem: MetricsSystem
    private let onInstancesChanged: (
        @Sendable (String, [Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_InstanceInfo]) async
            -> Void
    )?

    private enum SubscriptionError: Error {
        case streamEnded
    }

    init(
        eventLoopGroup: NIOTSEventLoopGroup,
        config: Config,
        serviceNames: [String],
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        metricsSystem: MetricsSystem,
        onInstancesChanged: (
            @Sendable (String, [Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_InstanceInfo]) async -> Void
        )? =
            nil
    ) throws {
        self.config = config
        self.serviceNames = serviceNames
        self.backoffStrategy = Self.makeBackoffStrategy(from: config.backoffConfig)
        self.instancesByService = Mutex([:])
        self.healthByService = Mutex([:])
        self.metricsSystem = metricsSystem
        self.onInstancesChanged = onInstancesChanged

        Self.logger.log("""
        message=Preparing ServiceDiscovery subscriber
        target=\(config.targetHost + ":" + String(config.targetPort), privacy: .public)
        scope=\(config.scope, privacy: .public)
        namespace=\(config.namespace, privacy: .public)
        serviceNames=\(serviceNames.joined(separator: ", "), privacy: .public)
        """)

        let tlsConfiguration = ClientTLSConfiguration(config.tlsConfig, identityCallback: identityCallback)

        let channel = try GRPCChannelPool.with(
            target: .hostAndPort(config.targetHost, config.targetPort),
            transportSecurity: .init(tlsConfiguration),
            eventLoopGroup: eventLoopGroup
        ) { gRPCConfig in
            gRPCConfig.backgroundActivityLogger = Self.grpcBackgroundActivityLogger
            if let backoff = config.backoffConfig {
                gRPCConfig.connectionBackoff = .init(from: backoff)
            }
            gRPCConfig.keepalive = .init(config.keepalive)
        }

        self.grpcClient = Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_ServiceDiscoveryAsyncClient(
            channel: channel,
            defaultCallOptions: CallOptions(logger: Self.grpcClientLogger)
        )
    }

    // Test-only initializer
    init(
        grpcClient: Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_ServiceDiscoveryAsyncClientProtocol,
        config: Config,
        serviceNames: [String],
        metricsSystem: MetricsSystem,
        onInstancesChanged: (
            @Sendable (String, [Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_InstanceInfo]) async -> Void
        )? =
            nil
    ) {
        self.grpcClient = grpcClient
        self.config = config
        self.serviceNames = serviceNames
        self.backoffStrategy = Self.makeBackoffStrategy(from: config.backoffConfig)
        self.instancesByService = Mutex([:])
        self.healthByService = Mutex([:])
        self.metricsSystem = metricsSystem
        self.onInstancesChanged = onInstancesChanged
    }

    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for serviceName in self.serviceNames {
                group.addTask {
                    try await self.runSubscription(for: serviceName)
                }
            }
            try await group.waitForAll()
        }
    }

    func isHealthy() -> Bool {
        self.healthByService.withLock { healthMap in
            guard !self.serviceNames.isEmpty else {
                return true
            }
            return self.serviceNames.allSatisfy { healthMap[$0] == true }
        }
    }

    private func runSubscription(for serviceName: String) async throws {
        let retryStrategy = RetryWithBackoff(
            backoffStrategy: self.backoffStrategy,
            deadline: .noDeadline,
            logger: Self.logger
        ) { error in
            if error is CancellationError {
                return .stop
            }
            self.healthByService.withLock { $0[serviceName] = false }
            // Only emit error metric for real failures, not normal stream EOF
            if !(error is SubscriptionError) {
                self.metricsSystem.emit(
                    Metrics.ServiceDiscoverySubscriber.UpdateErrorCounter(serviceName: serviceName)
                )
                Self.logger.error(
                    "ServiceDiscovery query for '\(serviceName, privacy: .public)' failed: \(String(unredacted: error), privacy: .public)"
                )
            }
            return .continue
        }

        try await executeWithRetries(retryStrategy: retryStrategy) {
            try await self.subscribe(serviceName: serviceName)
            Self.logger.log(
                "ServiceDiscovery query stream for '\(serviceName, privacy: .public)' ended. Reconnecting."
            )
            throw SubscriptionError.streamEnded
        }
    }

    private func subscribe(serviceName: String) async throws {
        let request = Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_DiscoveryRequest.with {
            $0.requestID = UUID().uuidString
            $0.scope = self.config.scope
            $0.namespace = self.config.namespace
            $0.serviceName = serviceName
            $0.locality = .with {
                $0.region = self.config.region
                if let zone = self.config.zone {
                    $0.zone = zone
                }
            }
            if let environment = self.config.environment {
                $0.environment = environment
            }
        }

        Self.logger.log(
            "Starting ServiceDiscovery query for '\(serviceName, privacy: .public)' (requestID=\(request.requestID, privacy: .public))"
        )

        let responseStream = self.grpcClient.query(request)

        for try await response in responseStream {
            switch response.message {
            case .state(let state):
                self.instancesByService.withLock { $0[serviceName] = state.instances }
                Self.logger.log(
                    "[\(serviceName, privacy: .public)] Received full state: \(state.instances.count, privacy: .public) instance(s)"
                )
            case .update(let update):
                self.instancesByService.withLock { instances in
                    var current = instances[serviceName, default: []]
                    for removed in update.removedInstances {
                        current.removeAll { $0 == removed }
                    }
                    current.append(contentsOf: update.addedInstances)
                    instances[serviceName] = current
                }
                let totalCount = self.instancesByService.withLock { $0[serviceName]?.count ?? 0 }
                Self.logger.log(
                    "[\(serviceName, privacy: .public)] Received update: +\(update.addedInstances.count, privacy: .public) -\(update.removedInstances.count, privacy: .public) instance(s). Total: \(totalCount, privacy: .public)"
                )
            case .none:
                Self.logger.warning("[\(serviceName, privacy: .public)] Received empty discovery response")
            }
            self.healthByService.withLock { $0[serviceName] = true }
            self.metricsSystem.emit(
                Metrics.ServiceDiscoverySubscriber.UpdateSuccessCounter(serviceName: serviceName)
            )

            // Notify observers of the current instance list for this service
            if let onInstancesChanged = self.onInstancesChanged {
                let currentInstances = self.instancesByService.withLock { $0[serviceName] ?? [] }
                await onInstancesChanged(serviceName, currentInstances)
            }
        }
    }

    private static func makeBackoffStrategy(
        from backoffConfig: GRPCClientConfiguration.ConnectionBackoff?
    ) -> ExponentialBackoffStrategy {
        ExponentialBackoffStrategy(
            initialDelay: .milliseconds(Int(((backoffConfig?.initial ?? 1.0) * 1000).rounded())),
            multiplier: backoffConfig?.factor ?? 1.6,
            maxDelay: .milliseconds(Int(((backoffConfig?.maximum ?? 120.0) * 1000).rounded())),
            jitterPercent: backoffConfig?.jitterPercent ?? 0.2
        )
    }
}
