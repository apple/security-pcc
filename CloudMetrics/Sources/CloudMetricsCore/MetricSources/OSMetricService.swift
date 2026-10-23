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
internal import CloudMetricsXPC
import Foundation
internal import os
import LoggingSupport

private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "OSMetricsService")

internal enum OSMetricServiceError: Error, Sendable {
    case sourcePreparationError
}

#if canImport(LoggingSupport, _version: 1788)
internal final class OSMetricService: Sendable {
    private let source: OSAllocatedUnfairLock<OSLogEventLiveSource>
    private let stream: OSAllocatedUnfairLock<OSLogEventLiveStream>
    private let delegate: CloudMetricsService
    private let metricStream: AsyncStream<OSMetricEvent>
    private let metricContinuation: AsyncStream<OSMetricEvent>.Continuation

    internal init(
        delegate: CloudMetricsService,
        metricStream: AsyncStream<OSMetricEvent>,
        metricContinuation: AsyncStream<OSMetricEvent>.Continuation
    ) throws {
        self.delegate = delegate
        self.metricStream = metricStream
        self.metricContinuation = metricContinuation
        let store = OSLogEventLiveStore.liveLocal()

        var source: OSLogEventLiveSource?
        var prepartionError: Error?

        store.prepare {
            source = $0
            prepartionError = $1
        }

        if let error = prepartionError {
            throw error
        }

        guard let source = source else {
            throw OSMetricServiceError.sourcePreparationError
        }

        self.source = .init(initialState: source)
        self.stream = .init(initialState: OSLogEventLiveStream(liveSource: source))
        self.stream.withLock { stream in
            stream.flags = [.includeMetrics]
        }
    }

    internal func stream() async throws {
        let stream = stream.withLock { $0 }
        // start listening for metric events
        stream.setEventHandler { event in
            guard event.type == .metric else {
                return
            }

            let metric: OSMetricEvent
            do {
                metric = try OSMetricEvent(from: event)
            } catch {
                logger.error("Error decoding log event to metric error=\(String(describing: error), privacy: .public)")
                return
            }

            self.metricContinuation.yield(metric)
        }
        stream.activate()

        // Wait for any incoming metric events.
        // Since the osmetric stream handler does not support concurrency we use an AsyncStream to bridge the
        // concurrency gap.
        await withTaskCancellationHandler {
            logger.log("Started streaming os metrics")
            for await metric in self.metricStream {
                do {
                    switch metric.metaData.type {
                    case .counter:
                        try await self.process(counter: metric)
                    case .gauge:
                        try await self.process(gauge: metric)
                    case .histogram:
                        try await self.process(histogram: metric)
                    default:
                        logger.log("Received unsupported metric type=\(metric.metaData.type, privacy: .public)")
                    }

                } catch CloudMetricsServiceError.metricNotAllowed {
                    // A metric missing from the audit allow list is a configuration outcome, not a
                    // daemon failure, and it recurs for every sample the client emits. `MetricsFilter`
                    // already emits a throttled diagnostic naming the client.
                    logger.log("""
                    Dropped an os metric that is not allowed by the audit list \
                    client=\(metric.client, privacy: .public) \
                    type=\(metric.metaData.type, privacy: .public) \
                    label=\(metric.label, privacy: .private)
                    """)
                } catch {
                    logger.error("""
                    Error processing log event \
                    client=\(metric.client, privacy: .public) \
                    type=\(metric.metaData.type, privacy: .public) \
                    error=\(String(describing: error), privacy: .public) \
                    label=\(metric.label, privacy: .private)
                    """)
                }
            }
        } onCancel: {
            self.metricContinuation.finish()
        }
    }

    private func process(counter: OSMetricEvent) async throws {
        guard let delta = counter.data.delta as? NSNumber else {
            logger.error("""
                         Error processing counter, missing delta value.
                         label: \(counter.label, privacy: .public)
                         """)
            return
        }
        let doubleDelta = delta.doubleValue

        let incrementBy: Double
        incrementBy = doubleDelta
        let client = MetricsClient(name: counter.client, remoteProcess: counter.client, removable: false)

        let cloudMetricsCounter = CloudMetricsCounter(label: counter.label, dimensions: counter.dimensions)
        try self.delegate.incrementCounter(cloudMetricsCounter, by: incrementBy, epoch: counter.epoch, client: client)
    }

    private func process(gauge: OSMetricEvent) async throws {
        guard let value = gauge.data.value as? Double else {
            return
        }
        let client = MetricsClient(name: gauge.client, remoteProcess: gauge.client, removable: false)
        let cloudMetricsGauge = CloudMetricsRecorder(label: gauge.label, dimensions: gauge.dimensions, aggregate: false)
        try self.delegate.recordDouble(
            recorder: cloudMetricsGauge,
            value: value,
            epoch: gauge.epoch,
            client: client
        )
    }

    private func process(histogram: OSMetricEvent) async throws {
        guard let buckets = histogram.metaData.buckets else {
            return
        }
        guard let value = histogram.data.value as? Double else {
            return
        }
        let client = MetricsClient(name: histogram.client, remoteProcess: histogram.client, removable: false)
        let cloudMetricsHistogram = CloudMetricsHistogram(
            label: histogram.label,
            dimensions: histogram.dimensions,
            buckets: buckets
        )
        try self.delegate.recordDouble(
            histogram: cloudMetricsHistogram,
            buckets: buckets,
            value: value,
            epoch: histogram.epoch,
            client: client
        )
    }
}
#else
internal final class OSMetricService: Sendable {
    internal init(
        delegate _: CloudMetricsService,
        metricStream _: AsyncStream<OSMetricEvent>,
        metricContinuation _: AsyncStream<OSMetricEvent>.Continuation
    ) throws {}

    internal func stream() async throws {
        logger.log("Unable to stream OS metrics, not available at build time.")

        /// When os metrics are not available we still want to not return here, otherwise the main
        /// cloudmetrics daemon task group will cancel all running tasks.
        while true {
            try await Task.sleep(for: .seconds(60 * 60 * 6))
        }
    }
}
#endif
