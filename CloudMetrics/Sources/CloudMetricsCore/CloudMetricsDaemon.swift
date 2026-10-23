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

//
//  CloudMetricsDaemon.swift
//  CloudMetricsCore
//
//  Created by Andrea Guzzo on 8/25/22
//

internal import CloudMetricsConstants
package import CloudMetricsHealthFramework
private import CloudMetricsUtils
internal import CloudMetricsXPC
internal import NIO
internal import os
private import OpenTelemetrySdk

/// Setup the server along with all metric collection services.
public final class CloudMetricsDaemon: Sendable {
    private enum State {
        case stopped
        case running(Promise<Void, Error>)
        case shuttingDown
    }

    private let cloudMetricsServer: CloudMetricsXPCServer
    /// Provides the XPC interface and passes data to the publisher
    private let cloudMetricsService: CloudMetricsService
    private let coreAnalyticsActivity: CoreAnalyticsActivity
    private let certExpiryHandler: NICCertExpiryHandler
    private let otlpMetricExporter: OTLPGRPCClient
    private let configuration: Configuration
    private let healthContinuation: AsyncStream<CloudMetricsHealthState>.Continuation
    /// Stream that provides us with new readers that we need to run.
    ///
    /// We have a separate store/reader per process. So this will yield whenever a new process starts.
    /// When it yields we need to create and run a new reader.
    private let newReaderStream: AsyncStream<OpenTelemetryPeriodicMetricReader>
    /// Non-nil only when the allow list contains at least one `aggregateOnNode = true` entry.
    private let aggregateReader: AggregateReader?

    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "Daemon")
    private let osMetricService: OSMetricService

    private let state = OSAllocatedUnfairLock<State>(initialState: .stopped)

    /// Initialises the daemon from in-memory objects
    ///
    /// This method is preferable for testing.
    package init(
        configuration: Configuration,
        healthContinuation: AsyncStream<CloudMetricsHealthState>.Continuation,
        osMetricStream: AsyncStream<OSMetricEvent>,
        osMetricContinuation: AsyncStream<OSMetricEvent>.Continuation,
        xpcServiceName: String = kCloudMetricsXPCServiceName
    ) throws {
        self.configuration = configuration
        self.healthContinuation = healthContinuation
        self.coreAnalyticsActivity = CoreAnalyticsActivity()
        let metricsFilter = MetricsFilter(configuration: configuration)

        self.certExpiryHandler = NICCertExpiryHandler()

        let (metricDataStream, metricDataContinuation) = AsyncStream<CollectedMetricsData>
            .makeStream()

        self.otlpMetricExporter = OTLPGRPCClient(
            metricDataStream: metricDataStream,
            tlsConfigStream: self.certExpiryHandler,
            configuration: configuration,
            healthContinuation: healthContinuation,
            metricsFilter: metricsFilter
        )

        let (newReaderStream, newReaderContinuation) = AsyncStream<OpenTelemetryPeriodicMetricReader>.makeStream()
        self.newReaderStream = newReaderStream

        let metricStoreProvider = MetricsStoreProvider(
            configuration: configuration,
            newReaderContinuation: newReaderContinuation,
            metricDataContinuation: metricDataContinuation
        )

        let hasAggregateMetrics = configuration.auditLists?.allowedMetrics.contains { $0.aggregateOnNode } ?? false
        let aggregateStoreProvider: AggregateStoreProvider? = hasAggregateMetrics
            ? AggregateStoreProvider(configuration: configuration)
            : nil
        // metricDataContinuation is intentionally shared between MetricsStoreProvider (per-process
        // periodic readers) and AggregateReader (node-aggregate readers). This is safe because
        // OTLPGRPCClient consumes each CollectedMetricsData independently — it sends one gRPC
        // export request per update with no batching or ordering assumptions across updates,
        // so interleaving from two concurrent producers causes no semantic issues.
        self.aggregateReader = aggregateStoreProvider.map { storeProvider in
            AggregateReader(
                storeProvider: storeProvider,
                metricsFilter: metricsFilter,
                metricDataContinuation: metricDataContinuation,
                destination: configuration.defaultDestination
            )
        }

        self.cloudMetricsService = CloudMetricsService(
            metricsStoreProvider: metricStoreProvider,
            metricsFilter: metricsFilter,
            aggregateStoreProvider: aggregateStoreProvider
        )
        self.cloudMetricsServer = CloudMetricsXPCServer.localListener(
            delegate: self.cloudMetricsService,
            xpcServiceName: xpcServiceName
        )
        self.osMetricService = try OSMetricService(
            delegate: self.cloudMetricsService,
            metricStream: osMetricStream,
            metricContinuation: osMetricContinuation
        )
    }

    /// Calling main will setup all metrics and servers. This will block until
    /// an error or shutdown occurs.
    package func run() async throws {
        self.logger.log("Running CloudMetricsDaemon")
        let shutdownPromise = try self.state.withLock { state in
            switch state {
            case .stopped:
                let shutdownPromise = Promise<Void, Error>()
                state = .running(shutdownPromise)
                return shutdownPromise
            default:
                self.logger.fault("Invalid state to run cloudmetricsdaemon")
                throw CloudMetricsInternalError.invalidStateTransition
            }
        }

        self.logger.log("Registering CoreAnalyticsActivity")
        self.coreAnalyticsActivity.registerActivity()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                self.logger.log("OS Metric streaming starting")
                defer {
                    self.logger.log("OS Metric streaming stopped")
                }
                try await self.osMetricService.stream()
            }
            group.addTask {
                self.logger.log("Metric exporter starting")
                defer {
                    self.logger.log("Metric exporter stopped")
                }
                try await self.otlpMetricExporter.run()
            }
            group.addTask {
                self.logger.log("Cloud metrics server starting")
                defer {
                    self.logger.log("Cloud metrics server stopped")
                }
                try await self.cloudMetricsServer.run()
            }
            if self.configuration.keySource == .keychain {
                // Only run the cert expiry handler if we're going to load cers from keychain.
                group.addTask {
                    self.logger.log("Cert expiry handler starting")
                    try await self.certExpiryHandler.run()
                    self.logger.log("Cert expiry handler stopped")
                }
            }

            group.addTask {
                self.logger.log("Processing of new stores starting")
                defer {
                    self.logger.log("Processing of new stores stopped")
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for try await reader in self.newReaderStream {
                        group.addTask {
                            try await reader.run()
                        }
                    }
                    try await group.waitForAll()
                }
            }

            if let aggregateReader = self.aggregateReader {
                group.addTask {
                    self.logger.log("Aggregate reader starting")
                    defer { self.logger.log("Aggregate reader stopped") }
                    try await aggregateReader.run()
                }
            }

            group.addTask {
                self.logger.log("Waiting for shutdown promise")
                defer {
                    self.logger.log("Shutdown promise returned")
                }
                try await withTaskCancellationHandler(operation: {
                    try await Future(shutdownPromise).valueWithCancellation
                }, onCancel: {
                    shutdownPromise.fail(with: CancellationError())
                })
            }

            defer {
                logger.log("Cancelling daemon children")
                group.cancelAll()
            }
            try await group.next()
            try Task.checkCancellation()
        }
    }

    package func shutdown() async throws {
        self.coreAnalyticsActivity.flush()
        try self.state.withLock { state in
            switch state {
            case .running(let promise):
                self.logger.log("Initiating shutdown")
                promise.succeed(with: ())
            default:
                self.logger.fault("Invalid state to begin shutdown")
                throw CloudMetricsInternalError.invalidStateTransition
            }
        }
    }
}
