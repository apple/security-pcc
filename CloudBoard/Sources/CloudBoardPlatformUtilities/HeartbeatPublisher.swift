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

import AsyncAlgorithms
import Atomics
import CloudBoardCommon
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import HeartbeatClient
import os

protocol HeartbeatPublisherClientProtocol: Sendable {
    func sendHeartbeat(_ heartbeat: Heartbeat) async throws
    func updateCredentialProvider(_ provider: @escaping @Sendable () async -> URLCredential?) async
}

extension HeartbeatHTTPClient: HeartbeatPublisherClientProtocol {}

/// An actor that periodically publishes heartbeat to the control plane.
///
/// Publishes a heartbeat either when the health changes, and on a regular interval.
public actor HeartbeatPublisher {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "HeartbeatPublisher"
    )

    struct Configuration {
        /// The rough interval between ticks, in other words the time between subsequent
        /// calls to the upstream service.
        ///
        /// The actual interval is somewhat randomized to avoid a thundering herd of
        /// fetchers all trying to fetch at the same time.
        var tickInterval: Duration = .seconds(30)

        /// The maximum tolerance between ticks, expressed as a ratio of `tickInterval`.
        ///
        /// Valid range is between 0.0 and 1.0, both inclusive.
        ///
        /// The fetcher randomly adds a random amount of the tolerance to the tick interval
        /// to spread out fetches.
        ///
        /// Goes in both directions, so the added interval is `(-1*tolerance, tolerance)`.
        var maximumToleranceRatio: Double = 0.25
    }

    typealias StatusUpdates = AsyncSequence<DaemonStatus, Never> & Sendable

    private let configuration: Configuration
    private let identifier: String
    private let nodeInfo: NodeInfo?
    private let statusUpdates: any StatusUpdates
    private let client: any HeartbeatPublisherClientProtocol
    private let hotProperties: HotPropertiesController
    private let metrics: MetricsSystem
    private let additionalProperties: [String: String]?
    private let monitoringBridgeService: SecureConfig.BridgeServiceMonitoringConfig
    private var publishingMetrics: OperationMetrics {
        .init(
            metricsSystem: self.metrics,
            totalFactory: {
                Metrics.HeartbeatPublisher.PublishedCounter(
                    action: .increment,
                    isHealthy: self.isHealthy.load(ordering: .relaxed)
                )
            },
            cancellationFactory: nil,
            errorFactory: Metrics.HeartbeatPublisher.FailedToPublishCounter.Factory(),
            durationFactory: nil
        )
    }

    private var daemonStatus: DaemonStatus = .uninitialized
    private let isHealthy: ManagedAtomic<Bool> = .init(false)

    /// Closure awaited once at startup before the node may report healthy.
    ///
    /// When present, the first `isUp == true` is gated on this completing, ensuring the
    /// control plane isn't told the node is up until per-app initial assets are fetched.
    private let initialAssetsReady: (@Sendable () async throws -> Void)?

    /// One-way latch flipped to `true` once initial assets are fetched.
    ///
    /// Starts `false` only when `initialAssetsReady` is provided; otherwise starts `true`
    /// to preserve behavior for callers that don't gate. Never flips back to `false`, so
    /// later maintenance windows continue reporting UP (accepted stickiness).
    private let initialAssetsFetched: ManagedAtomic<Bool>

    public init(
        configuration: CloudBoardDConfiguration.Heartbeat,
        identifier: String,
        nodeInfo: NodeInfo?,
        statusMonitor: StatusMonitor,
        hotProperties: HotPropertiesController,
        metrics: MetricsSystem,
        monitoringBridgeService: SecureConfig.BridgeServiceMonitoringConfig = .disabled,
        initialAssetsReady: (@Sendable () async throws -> Void)? = nil
    ) throws {
        try self.init(
            configuration: .init(configuration),
            identifier: identifier,
            nodeInfo: nodeInfo,
            statusUpdates: statusMonitor.watch(),
            client: HeartbeatHTTPClient(configuration: .init(configuration)),
            hotProperties: hotProperties,
            metrics: metrics,
            additionalProperties: configuration.additionalProperties,
            monitoringBridgeService: monitoringBridgeService,
            initialAssetsReady: initialAssetsReady
        )
    }

    public init(
        configuration: CloudBoardDConfiguration.Heartbeat,
        identifier: String = ProcessInfo.processInfo.hostName,
        nodeInfo: NodeInfo?,
        hotProperties: HotPropertiesController,
        metrics: MetricsSystem,
        monitoringBridgeService: SecureConfig.BridgeServiceMonitoringConfig = .disabled
    ) throws {
        // Use this initializer for an always-healthy source.
        let (stream, continuation) = AsyncStream<DaemonStatus>.makeStream()
        continuation.yield(.serviceDiscoveryUpdateSuccess(1))
        try self.init(
            configuration: .init(configuration),
            identifier: identifier,
            nodeInfo: nodeInfo,
            statusUpdates: stream,
            client: HeartbeatHTTPClient(configuration: .init(configuration)),
            hotProperties: hotProperties,
            metrics: metrics,
            additionalProperties: configuration.additionalProperties,
            monitoringBridgeService: monitoringBridgeService
        )
    }

    /// Updates the current credentials provider.
    public func updateCredentialProvider(_ provider: @escaping @Sendable () async -> URLCredential?) async {
        await self.client.updateCredentialProvider(provider)
    }

    init(
        configuration: Configuration = .init(),
        identifier: String,
        nodeInfo: NodeInfo?,
        statusUpdates: any StatusUpdates,
        client: any HeartbeatPublisherClientProtocol,
        hotProperties: HotPropertiesController,
        metrics: MetricsSystem,
        additionalProperties: [String: String]?,
        monitoringBridgeService: SecureConfig.BridgeServiceMonitoringConfig = .disabled,
        initialAssetsReady: (@Sendable () async throws -> Void)? = nil
    ) {
        self.configuration = configuration
        self.identifier = identifier
        self.nodeInfo = nodeInfo
        self.statusUpdates = statusUpdates
        self.client = client
        self.hotProperties = hotProperties
        self.metrics = metrics
        self.additionalProperties = additionalProperties
        self.monitoringBridgeService = monitoringBridgeService
        self.initialAssetsReady = initialAssetsReady
        self.initialAssetsFetched = .init(initialAssetsReady == nil)
    }

    /// Identifies which task in `run()`'s group finished, letting the one-shot initial-assets gate be told apart
    /// from the long-lived publish tasks whose exit should tear the group down.
    private enum RunningTask: Sendable, Equatable {
        case initialAssetsGate
        case healthUpdates
        case timer
    }

    public func run() async throws {
        try await withLogging(operation: "run", sensitiveError: false, logger: Self.logger) {
            let hotProperties = self.hotProperties
            try await hotProperties.waitForFirstUpdate()
            Self.logger.debug("First hot property update already received, starting the task group.")

            try await waitForBridgeService(setting: self.monitoringBridgeService, logger: Self.logger)

            try await withThrowingTaskGroup(of: RunningTask.self) { group in
                if let initialAssetsReady = self.initialAssetsReady {
                    group.addTaskWithLogging(
                        operation: "initialAssetsGate",
                        sensitiveError: false,
                        logger: Self.logger
                    ) {
                        try await initialAssetsReady()
                        await self.markInitialAssetsFetched()
                        // Publish so the UP transition doesn't wait for the next tick.
                        try await self.publish()
                        return .initialAssetsGate
                    }
                }
                group.addTaskWithLogging(operation: "healthUpdates", sensitiveError: false, logger: Self.logger) {
                    for try await status in self.statusUpdates.removeDuplicatesGeneralized() {
                        await self.updateStatus(status)
                        try await self.publish()
                    }
                    return .healthUpdates
                }
                group.addTaskWithLogging(operation: "timer", sensitiveError: false, logger: Self.logger) {
                    let timerSequence = AsyncTimerSequence(
                        interval: self.configuration.tickInterval,
                        tolerance: self.configuration.tickInterval * self.configuration.maximumToleranceRatio,
                        clock: .continuous
                    )
                    for try await _ in timerSequence {
                        try await self.publish()
                    }
                    return .timer
                }
                // The gate is a one-shot; ignore its completion and tear down once a long-lived task exits.
                while let finished = try await group.next(), finished == .initialAssetsGate {}
                group.cancelAll()
            }
        }
    }

    private func updateStatus(_ daemonStatus: DaemonStatus) {
        self.daemonStatus = daemonStatus
        self.updateHealth()
    }

    /// Flips the one-way initial-assets latch and recomputes health.
    private func markInitialAssetsFetched() {
        self.initialAssetsFetched.store(true, ordering: .relaxed)
        self.updateHealth()
    }

    private func updateHealth() {
        let daemonHealthy = switch self.daemonStatus {
        case .serviceDiscoveryUpdateSuccess:
            true
        case .uninitialized, .initializing, .waitingForFirstAttestationFetch,
             .waitingForFirstHotPropertyUpdate, .waitingForWorkloadRegistration,
             .componentsFailedToRun, .serviceDiscoveryUpdateFailure,
             .serviceDiscoveryPublisherDraining, .daemonDrained,
             .daemonExitingOnError:
            false
        }
        let isHealthy = daemonHealthy && self.initialAssetsFetched.load(ordering: .relaxed)
        self.isHealthy.store(isHealthy, ordering: .relaxed)
    }

    private func publish() async throws {
        let hotPropsVersion = await self.hotProperties.version
        let identifier = self.identifier
        let status = Heartbeat.Status(from: self.daemonStatus)
        let nodeInfo = self.nodeInfo
        let isHealthy = self.isHealthy.load(ordering: .relaxed)
        Self.logger
            .log(
                "publishing heartbeat - identifier: \(identifier, privacy: .public), status: \(status, privacy: .public), isHealthy: \(isHealthy, privacy: .public), hot properties version: \(hotPropsVersion ?? "<nil>", privacy: .public), node info: \(nodeInfo?.description ?? "<nil>", privacy: .public), additional properties: \(self.additionalProperties.flatMap { $0.description } ?? "<nil>", privacy: .public)"
            )
        do {
            try await withErrorLogging(
                operation: "publish",
                sensitiveError: false,
                metrics: self.publishingMetrics,
                logger: Self.logger
            ) {
                try await self.client.sendHeartbeat(
                    .init(
                        identifier: identifier,
                        isUp: isHealthy,
                        status: status,
                        source: .cloudboardd,
                        senderType: .node,
                        timestamp: .now,
                        metadata: .init(
                            cloudOSReleaseType: nodeInfo?.cloudOSReleaseType,
                            cloudOSBuilderVersion: nodeInfo?.cloudOSBuildVersion,
                            serverOSReleaseType: nodeInfo?.serverOSReleaseType,
                            serverOSBuildVersion: nodeInfo?.serverOSBuildVersion,
                            configVersion: hotPropsVersion,
                            workloadEnabled: nodeInfo?.workloadEnabled,
                            additionalProperties: self.additionalProperties
                        )
                    )
                )
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            // Ignore any non-cancelation errors, continue running the loop.
        }
    }
}

extension HeartbeatPublisher.Configuration {
    init(_ configuration: CloudBoardDConfiguration.Heartbeat) {
        self.init(
            tickInterval: .seconds(configuration.tickInterval),
            maximumToleranceRatio: configuration.maximumToleranceRatio
        )
    }
}

extension HeartbeatClient.ServiceConfiguration {
    init(_ configuration: CloudBoardDConfiguration.Heartbeat) {
        self.init(
            serviceURL: configuration.serviceURL,
            allowInsecure: configuration.allowInsecure,
            disableMTLS: configuration.disableMTLS,
            attemptCount: configuration.attemptCount,
            retryDelay: configuration.retryDelay,
            httpRequestTimeout: configuration.httpRequestTimeout
        )
    }
}

extension Heartbeat.Status {
    init(from daemonStatus: DaemonStatus) {
        self = switch daemonStatus {
        case .uninitialized:
            .uninitialized
        case .initializing:
            .initializing
        case .waitingForFirstAttestationFetch:
            .waitingForFirstAttestationFetch
        case .waitingForFirstHotPropertyUpdate:
            .waitingForFirstHotPropertyUpdate
        case .waitingForWorkloadRegistration:
            .waitingForWorkloadRegistration
        case .componentsFailedToRun:
            .componentsFailedToRun
        case .serviceDiscoveryUpdateSuccess:
            .serviceDiscoveryUpdateSuccess
        case .serviceDiscoveryUpdateFailure:
            .serviceDiscoveryUpdateFailure
        case .serviceDiscoveryPublisherDraining:
            .serviceDiscoveryPublisherDraining
        case .daemonDrained:
            .daemonDrained
        case .daemonExitingOnError:
            .daemonExitingOnError
        }
    }
}

// This works round a flaw in the declaration of ``AsyncAlgorithms/AsyncSequence/removeDuplicates()``
// which makes it unusable with the generalization improvements to AsyncSequence in
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0421-generalize-async-sequence.md
// Without it we can't use use the extensions that don'tt specify the primary associated types
extension AsyncSequence where Element: Equatable {
    /// Creates an asynchronous sequence that omits repeated elements.
    fileprivate func removeDuplicatesGeneralized() -> some AsyncSequence<Element, Failure> {
        self.removeDuplicates()
    }
}
