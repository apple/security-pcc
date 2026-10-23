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

//  Copyright © 2025 Apple Inc. All rights reserved.

internal import CloudMetricsConstants
@preconcurrency package import OpenTelemetrySdk
internal import os

/// Maintains one isolated OTEL MeterProvider per (clientName, metricLabel) pair for aggregate metrics.
///
/// Each entry contains a single-instrument store so that `collect()` on the adapter is effectively
/// a per-instrument collection — no other instruments in the same store are reset.
/// Entries are created lazily on the first record for that pair.
///
/// ## Concurrent access
/// This instance is shared between two consumers with strictly separated roles:
///   - **CloudMetricsService** calls `getStore()` on XPC request threads to record histogram values.
///   - **AggregateReader** calls `allEntries()` on its collection loop to drain and publish.
///
/// Thread-safety is guaranteed at two levels:
///   1. The `entries` dictionary is protected by `OSAllocatedUnfairLock`, so concurrent
///      `getStore()` writes and `allEntries()` reads never race.
///   2. Within each entry, concurrent histogram recording and `collect()` are safe because
///      `DoubleExplicitBucketHistogramAggregator` holds a per-instance lock during both
///      `record()` and `collect()`, and `MeterSharedState.collectAll()` additionally acquires
///      `collectionLock` before iterating storages.
package final class AggregateStoreProvider: Sendable {
    /// Uniquely identifies a (clientName, metricLabel) aggregate store entry.
    package struct Key: Hashable, Sendable {
        package let clientName: String
        package let metricLabel: String
    }

    /// Pairs the writable store (used by recording code) with its pull-only reader (used at publish time).
    /// `meterProvider` is retained here to keep the OTEL instrument state alive for the lifetime of the entry.
    internal struct Entry: Sendable {
        internal let store: OpenTelemetryStore
        internal let reader: AggregateMetricReaderAdapter
        internal let meterProvider: MeterProviderSdk
    }

    private let configuration: Configuration
    private let entries: OSAllocatedUnfairLock<[Key: Entry]> = .init(initialState: [:])
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "AggregateStoreProvider")

    package init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Returns the OpenTelemetryStore for the given pair, creating one lazily if none exists yet.
    internal func getStore(clientName: String, metricLabel: String) -> OpenTelemetryStore {
        let key = Key(clientName: clientName, metricLabel: metricLabel)
        if let entry = entries.withLock({ $0[key] }) { return entry.store }
        // makeEntry creates an OTEL MeterProvider — too heavy to do under the lock.
        // We may build it redundantly if two callers race on the same key, but that is safe
        // and far less harmful than holding the lock during initialization.
        let candidate = self.makeEntry(clientName: clientName, metricLabel: metricLabel)
        return entries.withLock { entries in
            if let existing = entries[key] { return existing.store }
            entries[key] = candidate
            self.logger.log("Created aggregate store. client=\(clientName, privacy: .public) label=\(metricLabel, privacy: .public)")
            return candidate.store
        }
    }

    /// Returns a snapshot of all current entries for iteration during a publish tick.
    internal func allEntries() -> [Key: Entry] {
        entries.withLock { $0 }
    }

    /// Creates an isolated OTEL MeterProvider, store, and reader for a single (clientName, metricLabel) pair.
    private func makeEntry(clientName: String, metricLabel: String) -> Entry {
        let reader = AggregateMetricReaderAdapter()
        let metricOverrides = MetricOverrides()
        let aggregation = CloudMetricsAggregation(
            histogramBuckets: configuration.defaultHistogramBuckets,
            metricOverrides: metricOverrides
        )
        let view = View.builder().withAggregation(aggregation: aggregation).build()
        let meterProvider = MeterProviderSdk.builder()
            .setResource(resource: EnvVarResource.get())
            .registerMetricReader(reader: reader)
            .registerView(
                selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
                view: view
            )
            .build()
        let store = OpenTelemetryStore(
            meter: meterProvider.meterBuilder(name: clientName).build(),
            globalLabels: configuration.globalLabels,
            metricOverrides: metricOverrides,
            clientName: clientName,
            removable: false
        )
        return Entry(store: store, reader: reader, meterProvider: meterProvider)
    }
}
