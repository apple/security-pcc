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
//  CloudMetricsSummaryHandler.swift
//  CloudMetricsFramework
//
//  Created by Andrea Guzzo on 8/3/23.
//

internal import CloudMetricsConstants
internal import CloudMetricsXPC
import Foundation
import os

public class Summary {
    private let _handler: SummaryHandler
    private let label: String
    private let dimensions: [(String, String)]
    private let quantiles: [Double]
    private static let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "CloudMetricsHandler")

    /// Alternative way to create a new `Summary`, while providing an explicit `SummaryHandler`.
    ///
    /// - warning: This initializer provides an escape hatch for situations where one must use.
    ///            a custom factory instead of the global one.
    ///            We do not expect this API to be used in normal circumstances, so if you find
    ///            yourself using it make sure it's for a good reason.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `Summary` instances
    ///            using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `Summary`.
    ///     - dimensions: The dimensions for the `Summary`.
    ///     - handler: The custom backend.
    private init(label: String, dimensions: [(String, String)], quantiles: [Double], handler: SummaryHandler) {
        self.label = label
        self.dimensions = dimensions
        self.quantiles = quantiles
        self._handler = handler
    }

    /// Record a value.
    ///
    /// Recording a value is meant to have "set" semantics, rather than "add" semantics.
    /// This means that the value of this `Summary` will match the passed in value, rather
    /// than accumulate and sum the values up.
    ///
    /// - parameters:
    ///     - value: Value to record.
    public func record<DataType: BinaryInteger>(_ value: DataType) {
        self._handler.record(Int64(value))
    }

    /// Record a value.
    ///
    /// Recording a value is meant to have "set" semantics, rather than "add" semantics.
    /// This means that the value of this `Summary` will match the passed in value,
    /// rather than accumulate and sum the values up.
    ///
    /// - parameters:
    ///     - value: Value to record.
    public func record<DataType: BinaryFloatingPoint>(_ value: DataType) {
        self._handler.record(Double(value))
    }

    /// Record prepopulated buckets.
    ///
    /// Recording a value is meant to have "set" semantics, rather than "add" semantics.
    /// This means that the value of this `Summary` will match the passed in value,
    /// rather than accumulate and sum the values up.
    ///
    /// - parameters:
    ///     - value: Value to record.
    public func record(quantileValues: [Double], sum: Double, count: Int) {
        self._handler.record(quantileValues: quantileValues, sum: sum, count: count)
    }
}

extension Summary {
    public convenience init(label: String, dimensions: [(String, String)], quantiles: [Double]) throws {
        guard let factory = CloudMetrics.sharedFactory else {
            Self.logger.warning("Attempted to create a summary before the factory was initialised")
            throw CloudMetricsTypeError.apiMisuse("Factory not initiliazed")
        }
        let handler = factory.makeSummary(label: label, dimensions: dimensions, quantiles: quantiles)
        self.init(label: label, dimensions: dimensions, quantiles: quantiles, handler: handler)
    }

    /// Signal the underlying metrics library that this recorder will never be updated again.
    /// In response the library MAY decide to eagerly release any resources held by this `Summary`.
    public func destroy() {
        guard let factory = CloudMetrics.sharedFactory else {
            Self.logger.warning("Attempted to destroy a summary before the factory was initialised")
            return
        }
        factory.destroySummary(self._handler)
    }
}

public protocol SummaryHandler: AnyObject, RecorderHandler {
    func record(quantileValues: [Double], sum: Double, count: Int)
}

internal final class CloudMetricsSummaryHandler: SummaryHandler {
    private let summary: CloudMetricsSummary
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "CloudMetricsRecorderHandler")
    private let metricUpdateContinuation: AsyncStream<CloudMetricsServiceMessages>.Continuation

    internal init(metricUpdateContinuation: AsyncStream<CloudMetricsServiceMessages>.Continuation, summary: CloudMetricsSummary) {
        self.summary = summary
        self.metricUpdateContinuation = metricUpdateContinuation
    }

    internal func record(_ value: Int64) {
        let summary = self.summary
        let epoch = Date().timeIntervalSince1970
        metricUpdateContinuation.yieldAndLogOnFailure(.recordSummaryInteger(.init(summary, quantiles: summary.quantiles, value: value, epoch: epoch)))
    }

    internal func record(_ value: Double) {
        let summary = self.summary
        let epoch = Date().timeIntervalSince1970
        metricUpdateContinuation.yieldAndLogOnFailure(.recordSummaryDouble(.init(summary, quantiles: summary.quantiles, value: value, epoch: epoch)))
    }

    internal func record(quantileValues: [Double], sum: Double, count: Int) {
        let summary = self.summary
        let epoch = Date().timeIntervalSince1970
        metricUpdateContinuation.yieldAndLogOnFailure(.recordSummaryQuantiles(
            .init(summary, quantiles: summary.quantiles, values: quantileValues, sum: sum, count: count, epoch: epoch)))
    }
}
