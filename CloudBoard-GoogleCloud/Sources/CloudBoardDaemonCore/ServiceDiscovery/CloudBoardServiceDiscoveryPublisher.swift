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
import CloudBoardUtilities
import Configuration
// Foundation required for JSONSerialization (not provided by FoundationEssentials)
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import Metrics
import NIOCertificateReloading
import ServiceDiscoveryPublisher
import ServiceLifecycle
import Synchronization

struct CloudBoardServiceDiscoveryPublisher {
    private static let logger = Logger(label: "cloudboardd.CloudBoardServiceDiscoveryPublisher")

    private let config: ServiceDiscoveryConfiguration
    private let identityManager: CloudBoardIdentityManager
    let bootID: String

    init(config: ServiceDiscoveryConfiguration, identityManager: CloudBoardIdentityManager) async throws {
        self.config = config
        self.identityManager = identityManager
        do {
            self.bootID = try readSystemBootIdentifier()
        } catch {
            Self.logger.error(
                "Failed to read system boot identifier. Using fallback.",
                metadata: ["error": "\(String(unredacted: error))"]
            )
            self.bootID = fallbackSystemBootIdentifier
        }
    }

    /// Creates a GRPC client for service discovery and keeps it alive for the duration of `body`.
    /// The client is reused across retries of the publisher stream.
    func withGRPCClient<R>(
        _ body: @escaping @Sendable (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> R
    ) async throws -> R where R: Sendable {
        let identitySource = try await self.identityManager.identitySource
        let transportSecurity: HTTP2ClientTransport.Posix.TransportSecurity
        if self.config.enableTLS, self.config.useMTLS {
            switch identitySource {
            case .resolved(let identity):
                transportSecurity = try .mTLS(
                    certificateChain: .init(identity.chain),
                    privateKey: .bytes(identity.privateKey)
                )
            case .reloader(let reloader):
                transportSecurity = try .mTLS(certificateReloader: reloader)
            }
        } else if self.config.enableTLS {
            transportSecurity = .tls
        } else {
            transportSecurity = .plaintext
        }

        var clientConfig = HTTP2ClientTransport.Posix.Config.defaults
        clientConfig.http2.authority = self.config.sniOverride

        // Configure keepalive to detect connection failures
        clientConfig.connection.keepalive = .init(
            time: .seconds(10),
            timeout: .seconds(5),
            allowWithoutCalls: true
        )

        clientConfig.channelDebuggingCallbacks = .init(
            onCreateTCPConnection: { channel in
                Self.logger.debug("Creating TCP connection", metadata: ["channel": "\(channel)"])
                return channel.eventLoop.makeSucceededVoidFuture()
            },
            onCreateHTTP2Stream: { channel in
                Self.logger.debug("Creating HTTP2 stream", metadata: ["channel": "\(channel)"])
                return channel.eventLoop.makeSucceededVoidFuture()
            }
        )

        let grpcTransport = try HTTP2ClientTransport.Posix.http2NIOPosix(
            target: .dns(host: self.config.host, port: self.config.port),
            transportSecurity: transportSecurity,
            config: clientConfig
        )

        return try await GRPCCore.withGRPCClient(transport: grpcTransport) { grpcClient in
            try await body(grpcClient)
        }
    }

    /// Runs the service discovery publisher stream on an existing GRPC client.
    /// Only the stream is established — the client itself is not recreated.
    func withServiceDiscoveryPublisher<R>(
        grpcClient: GRPCClient<HTTP2ClientTransport.Posix>,
        serviceAddress: ServiceDiscovery.NetworkEndpoint,
        _ body: @escaping @Sendable (ServiceDiscoveryPublisher<HTTP2ClientTransport.Posix>) async throws -> R
    ) async throws -> R where R: Sendable {
        try await ServiceDiscoveryPublisher.withServiceDiscoveryPublisher(
            grpcClient: grpcClient,
            serviceAddress: serviceAddress,
            locality: .init(region: self.config.region, zone: nil),
            lbConfig: .init(cluster: self.config.cluster),
            scope: "global",
            namespace: "private-cloud-compute",
            environment: self.config.environment,
            retryConfiguration: .init { config in
                // Retries are owned by withServiceDiscoveryRetry; disable internal retries here.
                config.maxRetries = 0
            },
            logger: Self.logger,
            body
        )
    }
}

extension CloudBoardServiceDiscoveryPublisher {
    /// Runs `connect` in a loop, retrying indefinitely on failure.
    ///
    /// - When `connect` returns normally (graceful shutdown path), exits cleanly.
    /// - When `connect` throws `CancellationError`, stops retrying and rethrows.
    /// - When `connect` throws any other error, sets the SD component state to
    ///   `.degraded` initially, then escalates to `.transientError` after
    ///   `degradedGracePeriod` elapses without a successful reconnection.
    ///
    /// The grace period accounts for the fact that Service Discovery entries have a TTL
    /// (typically 5 minutes), so the node remains known and available to ROPES while
    /// CloudBoard's SD connection is down.
    ///
    /// - Parameters:
    ///   - statusMonitor: Used to update the SD component state on connect, disconnect, and escalation.
    ///   - initialBackoff: How long to wait before the first retry. Defaults to 1 second.
    ///   - maxBackoff: Maximum backoff between retries. Defaults to 60 seconds.
    ///   - degradedGracePeriod: How long to remain in `.degraded` before escalating to
    ///     `.transientError`. Defaults to 5 minutes to match the SD entry TTL.
    ///   - connect: Establishes and holds the SD connection. Must set the SD component
    ///     status to `.ready` on the `statusMonitor` once connected — this is used to
    ///     detect successful reconnections and reset the grace period timer.
    static func withServiceDiscoveryRetry(
        statusMonitor: ServiceStatusMonitor,
        initialBackoff: Duration = .seconds(1),
        maxBackoff: Duration = .seconds(60),
        degradedGracePeriod: Duration = .seconds(300),
        connect: @escaping @Sendable () async throws -> Void
    ) async throws {
        let sdComponent = ServiceStatusMonitor.ComponentName.serviceDiscovery

        let strategy = RetryWithBackoff(
            backoffStrategy: ExponentialBackoffStrategy(
                initialDelay: initialBackoff,
                multiplier: 2,
                maxDelay: maxBackoff,
                jitterPercent: 0
            )
        ) { error in
            if error is CancellationError {
                return .stop
            }
            Self.logger.warning(
                "Service discovery connection lost, will retry",
                metadata: ["error": "\(String(reportable: error))"]
            )
            Counter(
                label: "cloudboard_service_discovery_re_connect_total",
                dimensions: [("errorDescription", String(reportable: error))]
            ).increment()

            let componentState = statusMonitor.componentState(sdComponent)
            let elapsed = componentState.map { ContinuousClock.now - $0.updatedAt } ?? .zero

            switch componentState?.status {
            case .degraded where elapsed >= degradedGracePeriod:
                statusMonitor.updateComponentState(
                    name: sdComponent,
                    status: .transientError(message: "Service discovery connection lost, grace period exceeded")
                )
            case .transientError:
                break
            default:
                statusMonitor.updateComponentState(
                    name: sdComponent,
                    status: .degraded(reason: "Service discovery connection lost, retrying")
                )
            }
            return .continue
        }
        try await executeWithRetries(retryStrategy: strategy) {
            try await connect()
        }
    }
}

extension CloudBoardServiceDiscoveryPublisher {
    /// Wraps a service-discovery connect attempt and emits 1P-expected metrics:
    ///
    /// - `cloudboard_service_discovery_connect_succeeded_total` and its duration timer on success
    /// - `cloudboard_service_discovery_connect_failed_total` and its duration timer on failure
    ///   (excluding `CancellationError`, which represents graceful shutdown)
    /// - `cloudboard_service_discovery_registered_services` gauge toggled to 1 once the body signals
    ///   a successful registration via `onConnected()`, and back to 0 when the body exits for any reason.
    ///
    /// `body` must call `onConnected()` once the service is announced. The success counter and
    /// success-duration timer are emitted as part of `onConnected()`, so the duration reflects the
    /// time from connect-start to announce, not the full lifetime of the connection.
    static func withConnectMetrics(
        factory: any MetricsFactory = MetricsSystem.factory,
        _ body: (_ onConnected: @escaping @Sendable () -> Void) async throws -> Void
    ) async throws {
        let connectStart = ContinuousClock.now
        let connected = Mutex(false)
        do {
            try await body {
                connected.withLock { $0 = true }
                Counter(
                    label: "cloudboard_service_discovery_connect_succeeded_total",
                    factory: factory
                ).increment()
                Timer(
                    label: "cloudboard_service_discovery_connect_succeeded_duration_in_seconds",
                    preferredDisplayUnit: .seconds,
                    factory: factory
                ).record(duration: ContinuousClock.now - connectStart)
                Gauge(
                    label: "cloudboard_service_discovery_registered_services",
                    factory: factory
                ).record(1)
            }
            Gauge(
                label: "cloudboard_service_discovery_registered_services",
                factory: factory
            ).record(0)
        } catch {
            Gauge(
                label: "cloudboard_service_discovery_registered_services",
                factory: factory
            ).record(0)
            let didConnect = connected.withLock { $0 }
            if !didConnect, !(error is CancellationError) {
                Counter(
                    label: "cloudboard_service_discovery_connect_failed_total",
                    dimensions: [("errorDescription", String(reportable: error))],
                    factory: factory
                ).increment()
                Timer(
                    label: "cloudboard_service_discovery_connect_failed_duration_in_seconds",
                    dimensions: [("errorDescription", String(reportable: error))],
                    preferredDisplayUnit: .seconds,
                    factory: factory
                ).record(duration: ContinuousClock.now - connectStart)
            }
            throw error
        }
    }
}

extension ServiceDiscoveryPublisher {
    func announceCloudBoardService(config: ServiceDiscoveryConfiguration, bootID: String) throws {
        let ensembleID = config.ensembleID ?? fallbackEnsembleID
        var description: [String: ServiceDiscovery.MetadataValue] = [
            "hardwareType": .string(config.hardwareType),
            "releaseType": .string(config.releaseType),
            "buildVersion": .string(config.buildVersion),
            "machineName": .string("\(ProcessInfo.processInfo.hostName)"),
            "ensembleID": .string(ensembleID),
            "rackID": .string("rack_not_relevant"),
            "bootId": .string(bootID),
            "cellId": .string(config.cellID),
        ]

        if let routingGroupAliases = config.routingGroupAliases {
            description["routingGroupAliases"] = .list(routingGroupAliases.map { .string($0) })
        }

        var globalLabels: [String: ServiceDiscovery.MetadataValue] = [:]
        if let workloadName = config.workloadName {
            globalLabels["workload_name"] = .string(workloadName)
        }
        if let workloadPurpose = config.workloadPurpose {
            globalLabels["workload_purpose"] = .string(workloadPurpose)
        }
        if let workloadApp = config.workloadApp {
            globalLabels["workload_app"] = .string(workloadApp)
        }
        if let workloadServesCustomers = config.workloadServesCustomers {
            globalLabels["workload_serves_customers"] = .string(workloadServesCustomers)
        }

        var metadata: [String: [String: ServiceDiscovery.MetadataValue]] = [
            "description": description,
            "workload": .init(config.workloadTags),
        ]
        if !globalLabels.isEmpty {
            metadata["globalLabels"] = globalLabels
        }

        let logger = Logger(label: "cloudboardd.CloudBoardServiceDiscoveryPublisher")
        logger.info(
            "Announcing service",
            metadata: [
                "serviceName": "\(config.serviceName)",
                "description": "\(description)",
                "workload": "\(config.workloadTags)",
                "globalLabels": "\(globalLabels)",
            ]
        )
        self.announceService(
            name: config.serviceName,
            metadata: metadata
        )
    }
}

extension [String: ServiceDiscovery.MetadataValue] {
    init(_ tags: [String: WorkloadTagValue]) {
        self = tags.mapValues {
            switch $0 {
            case .string(let value): .string(value)
            case .stringList(let listValue): .list(listValue.map { .string($0) })
            }
        }
    }
}
