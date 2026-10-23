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
//  OpenTelemetryPeriodicMetricReader.swift
//  CloudMetricsDaemon
//
//  Created by Andrea Guzzo on 11/28/23.
//

internal import CloudMetricsConstants
import Foundation
@preconcurrency package import OpenTelemetrySdk
internal import os

/// Periodically reads metrics for a destination and sends them to an AsyncStream.Continuation.
///
/// Usually the other end of this continuation is connected to an exporter, who is responsible for
/// sending all of the metrics (for all destinations) via gRPC.
package final class OpenTelemetryPeriodicMetricReader: Sendable {
    /// States the reader can be in
    private enum State {
        case stopped
        case running
        case shuttingDown
    }

    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "OTLPReader")
    private let metricProducer: OSAllocatedUnfairLock<MetricProducer?> = .init(initialState: nil)
    internal let store: OSAllocatedUnfairLock<OpenTelemetryStore?> = .init(initialState: nil)
    private let destination: Configuration.Destination

    /// The remote metrics client process name
    private let clientName: String

    /// Continuation on to which we push metric updates to
    private let metricContinuation: AsyncStream<CollectedMetricsData>
        .Continuation

    private let state: OSAllocatedUnfairLock<State> = .init(initialState: .stopped)
    private let metricStoreProvider: MetricsStoreProvider

    init(
        destination: Configuration.Destination,
        clientName: String,
        metricStoreProvider: MetricsStoreProvider,
        metricContinuation: AsyncStream<CollectedMetricsData>
            .Continuation
    ) {
        self.destination = destination
        self.clientName = clientName
        self.metricContinuation = metricContinuation
        self.metricStoreProvider = metricStoreProvider
    }

    internal func run() async throws {
        try self.state.withLock { state in
            if state != .stopped {
                throw CloudMetricsError.invalidStateTransition
            }
            state = .running
        }
        defer {
            self.state.withLock { state in
                state = .stopped
            }
        }

        guard let store = self.store.withLock({ $0 }) else {
            self.logger.fault("Reader does not have a store")
            return
        }

        self.logger.log("Starting OTEL periodic metric reader. client=\(store.clientName, privacy: .public)")
        while (self.state.withLock { $0 == .running }) {
            try Task.checkCancellation()

            self.readMetrics()

            self.logger
                .debug(
                    "Connected clients. client=\(store.clientName, privacy: .public), clients=\(store.connectedClients, privacy: .public)"
                )
            if !store.remoteEndIsAlive {
                self.metricStoreProvider.dropStore(store)
                self.logger
                    .log("Reader stopping as remote end disconnected. client=\(store.clientName, privacy: .public)")
                return
            }

            try await Task.sleep(for: self.destination.publishInterval)
        }
    }

    private func readMetrics() {
        guard let metricProducer = (self.metricProducer.withLock { $0 }) else {
            self.logger.error("No metric producer for destination. destination=\(self.destination, privacy: .public)")
            return
        }
        guard let store = self.store.withLock({ $0 }) else {
            self.logger.error("No metric store for reader. destination=\(self.destination, privacy: .public)")
            return
        }

        let metricData = store.collectAllMetrics(producer: metricProducer)

        guard !metricData.isEmpty else {
            // Only log where we're running with an exportInterval that resembles prod.
            // If exportInterval is low, we're probably running tests and don't want to
            // completely flood our logger.
            if self.destination.publishInterval > .seconds(10) {
                self.logger.log("Metric data are empty. client=\(self.clientName, privacy: .public) destination=\(self.destination, privacy: .public)")
            }
            return
        }
        self.logger.debug("Collected metrics. client=\(self.clientName, privacy: .public), metrics_count=\(metricData.count, privacy: .public)")
        let update = CollectedMetricsData(
            destination: self.destination,
            metrics: metricData,
            client: store.clientName
        )
        self.metricContinuation.yieldAndLogOnFailure(update)
    }
}

extension OpenTelemetryPeriodicMetricReader: MetricReader {
    package func getAggregationTemporality(for _: OpenTelemetrySdk.InstrumentType) -> OpenTelemetrySdk
    .AggregationTemporality {
        .delta
    }

    package func getDefaultAggregation(for _: OpenTelemetrySdk.InstrumentType) -> any OpenTelemetrySdk.Aggregation {
        Aggregations.defaultAggregation()
    }

    package func shutdown() -> OpenTelemetrySdk.ExportResult {
        do {
            try self.state.withLock { state in
                if state != .running {
                    throw CloudMetricsError.invalidStateTransition
                }
                state = .shuttingDown
            }
        } catch {
            // Can't throw here
            self.logger.error("invalid OpenTelemetryPeriodMetricReader state transition to begin shutdown")
        }
        return self.forceFlush()
    }

    package func forceFlush() -> ExportResult {
        self.readMetrics()
        return .success
    }

    package func register(registration: CollectionRegistration) {
        if let newProducer = registration as? MetricProducer {
            self.metricProducer.withLock { $0 = newProducer }
        } else {
            self.logger.error("Unrecognized CollectionRegistration")
        }
    }
}
