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

@preconcurrency package import OpenTelemetrySdk
internal import CloudMetricsConstants
internal import os

/// A MetricReader that does not drive its own collection loop.
///
/// Instead of sleeping on a timer, this adapter stores the MetricProducer the OTEL SDK hands it
/// and exposes a `collect()` method so the `AggregateReader` can pull metrics on demand.
/// One instance is created per (clientName, metricLabel) pair inside `AggregateStoreProvider`.
package final class AggregateMetricReaderAdapter: MetricReader, Sendable {
    private let metricProducer: OSAllocatedUnfairLock<MetricProducer?> = .init(initialState: nil)
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "AggregateMetricReaderAdapter")

    /// Pulls all accumulated delta metrics from the OTEL SDK and resets the delta accumulator.
    ///
    /// Thread-safety: `collectAllMetrics()` is intentionally called outside the lock.
    /// The lock only protects the reference swap in `register()`; once `producer` is captured here,
    /// ARC keeps the object alive for the full call even if `register()` were to race.
    /// In practice no race occurs: `register()` is called exactly once at `MeterProviderSdk.build()`
    /// time, before `AggregateReader.run()` starts its collection loop. `collect()` itself is only
    /// ever called from that single linear loop, so concurrent invocations are not possible.
    package func collect() -> [OpenTelemetrySdk.MetricData] {
        guard let producer = metricProducer.withLock({ $0 }) else { return [] }
        return producer.collectAllMetrics()
    }

    /// Returns delta temporality so each collect() call yields only events recorded since the last call.
    ///
    /// `.delta` is intentional for all instrument types: `AggregateStoreProvider` only records
    /// histograms (via `CloudMetricsService.histogramSet`), and the Laplace-noise publish path
    /// depends on delta semantics — the OTEL store accumulates between ticks and `collect()` drains
    /// exactly the window's worth of data. Cumulative semantics would prevent the hold-and-accumulate
    /// behaviour that the threshold check relies on.
    package func getAggregationTemporality(for _: InstrumentType) -> AggregationTemporality {
        .delta
    }

    /// Returns the SDK default aggregation for all instrument types.
    package func getDefaultAggregation(for _: InstrumentType) -> any Aggregation {
        Aggregations.defaultAggregation()
    }

    /// Clears the producer reference so collect() becomes a no-op and the producer can be deallocated.
    package func shutdown() -> ExportResult {
        metricProducer.withLock { $0 = nil }
        return .success
    }
    /// No-op: collection lifecycle is managed externally by AggregateReader.
    package func forceFlush() -> ExportResult { .success }

    /// Called by the OTEL SDK at MeterProvider build time; saves the MetricProducer used by collect().
    package func register(registration: CollectionRegistration) {
        if let producer = registration as? MetricProducer {
            metricProducer.withLock { $0 = producer }
        } else {
            logger.fault("Expected MetricProducer from OTEL SDK, got \(type(of: registration), privacy: .public) — collect() will return empty for this store")
            assertionFailure("Expected MetricProducer, got \(type(of: registration))")
        }
    }
}
