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
//  MetricsStoreProvider.swift
//  CloudMetrics
//
//  Created by Daniel Aguilar on 8/20/25.
//

internal import CloudMetricsConstants
internal import CloudMetricsXPC
@preconcurrency package import OpenTelemetrySdk
internal import os

/// Stores a mapping between ``MetricsClient``s and ``OpenTelemetryStore``s.
///
/// Each process that has an XPC connection to `cloudmetricsd` is identified by a ``MetricsClient``
/// and each has its own ``OpenTelemetryStore``, such that we can flush a store when its associated
/// process dies. This class maintains the mapping from ``MetricsClient`` to said ``OpenTelemetryStore``.
package final class MetricsStoreProvider: Sendable {
    private let configuration: Configuration
    /// Mapping from a process to a store
    ///
    /// Each process's metrics are stored and exported separately. This allows us to flush metrics for a single
    /// process when it dies.
    private let metricsStores: OSAllocatedUnfairLock<[String: OpenTelemetryStore]> = .init(initialState: [:])
    private let metricOverrides: MetricOverrides = .init()

    /// Continuation to which we yield in order to trigger data to be exported to the OTLP server.
    private let metricDataContinuation: AsyncStream<CollectedMetricsData>.Continuation

    /// Continuation with which we can send new readers for them to be run.
    private let newReaderContinuation: AsyncStream<OpenTelemetryPeriodicMetricReader>.Continuation

    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "OpenTelemetryPublisher")

    package init(
        configuration: Configuration,
        newReaderContinuation: consuming AsyncStream<OpenTelemetryPeriodicMetricReader>.Continuation,
        metricDataContinuation: AsyncStream<CollectedMetricsData>.Continuation
    ) {
        self.configuration = configuration
        self.newReaderContinuation = newReaderContinuation
        self.metricDataContinuation = metricDataContinuation
    }

    /// Gets the existing store for a client if it already exists. Otherwise will create a new one.
    internal func getMetricsStore(for client: MetricsClient) -> OpenTelemetryStore {
        return self.metricsStores.withLock { metricsStores in
            if let store = metricsStores[client.name] {
                return store
            }
            let destination = self.getDestination(for: client)
            self.logger.log("""
            Creating new store. \
            client=\(client.name, privacy: .public) \
            destination=\(destination, privacy: .private) \
            removable=\(client.removable)
            """)

            let metricOverrides = MetricOverrides()
            let cloudMetricsAggregation = CloudMetricsAggregation(
                histogramBuckets: configuration.defaultHistogramBuckets,
                metricOverrides: metricOverrides
            )
            
            let metricsView = View.builder().withAggregation(aggregation: cloudMetricsAggregation).build()
            let reader = OpenTelemetryPeriodicMetricReader(
                destination: destination,
                clientName: client.name,
                metricStoreProvider: self,
                metricContinuation: self.metricDataContinuation
            )
            let meterProvider = MeterProviderSdk.builder()
                .setResource(resource: EnvVarResource.get())
                .registerMetricReader(reader: reader)
                .registerView(
                    selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
                    view: metricsView
                )
                .build()
            let store = OpenTelemetryStore(
                meter: meterProvider.meterBuilder(name: client.name).build(),
                globalLabels: self.configuration.globalLabels,
                metricOverrides: metricOverrides,
                clientName: client.name,
                removable: client.removable
            )
            // We have a bit of a nasty circular dependency.
            // meterProvider needs a reader (swift-opentelemetry)
            // Reader needs a store to read from
            // store needs a meter provider in order to build new meters.
            // We should do some refactoring to fix this.
            reader.store.withLock { $0 = store }

            self.newReaderContinuation.yield(reader)
            metricsStores[client.name] = store
            return store
        }
    }

    internal func dropStore(_ store: OpenTelemetryStore) {
        self.metricsStores.withLock { metricStores in
            if let _ = metricStores.removeValue(forKey: store.clientName) {
                self.logger.log("Dropped OpenTelemetry store. client=\(store.clientName)")
            }
        }
    }

    private func getDestination(for client: MetricsClient) -> Configuration.Destination {
        self.configuration.destinations.first { $0.clients.contains(client.name) } ?? self.configuration
            .defaultDestination
    }
}

extension MetricsStoreProvider {
    subscript(client: MetricsClient) -> OpenTelemetryStore {
        self.getMetricsStore(for: client)
    }
}
