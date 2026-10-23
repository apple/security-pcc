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

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Metrics API open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Metrics API project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Metrics API project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// MARK: - User API

// MARK: - Counter

/// A counter is a cumulative metric that represents a single monotonically increasing counter whose value can only increase or be reset to zero.
/// For example, you can use a counter to represent the number of requests served, tasks completed, or errors.
///
/// This is the user-facing Counter API.
///
/// Its behavior depends on the `CounterHandler` implementation.
package final class Counter {
    /// `_handler` and `_factory` are only public to allow access from `MetricsTestKit`.
    /// Do not consider them part of the public API.
    package let _handler: CounterHandler
    @usableFromInline
    package let _factory: MetricsFactory
    package let label: String
    package let dimensions: [(String, String)]

    /// Alternative way to create a new `Counter`, while providing an explicit `CounterHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `Counter` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `Counter`.
    ///     - dimensions: The dimensions for the `Counter`.
    ///     - handler: The custom backend.
    ///     - factory: The custom factory.
    package init(label: String, dimensions: [(String, String)], handler: CounterHandler, factory: MetricsFactory) {
        self.label = label
        self.dimensions = dimensions
        self._handler = handler
        self._factory = factory
    }

    /// Alternative way to create a new `Counter`, while providing an explicit `CounterHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `Counter` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `Counter`.
    ///     - dimensions: The dimensions for the `Counter`.
    ///     - handler: The custom backend, created by the global metrics factory.
    package convenience init(label: String, dimensions: [(String, String)], handler: CounterHandler) {
        self.init(
            label: label,
            dimensions: dimensions,
            handler: handler,
            factory: MetricsSystem.factory
        )
    }

    /// Increment the counter.
    ///
    /// - parameters:
    ///     - amount: Amount to increment by.
    @inlinable
    package func increment<DataType: BinaryInteger>(by amount: DataType) {
        self._handler.increment(by: Int64(amount))
    }

    /// Increment the counter by one.
    @inlinable
    package func increment() {
        self.increment(by: 1)
    }

    /// Reset the counter back to zero.
    @inlinable
    package func reset() {
        self._handler.reset()
    }
}

extension Counter {
    /// Create a new `Counter`.
    ///
    /// - parameters:
    ///     - label: The label for the `Counter`.
    ///     - dimensions: The dimensions for the `Counter`.
    package convenience init(label: String, dimensions: [(String, String)] = []) {
        self.init(label: label, dimensions: dimensions, factory: MetricsSystem.factory)
    }

    /// Create a new `Counter`.
    ///
    /// - parameters:
    ///     - label: The label for the `Counter`.
    ///     - dimensions: The dimensions for the `Counter`.
    ///     - factory: The custom factory.
    package convenience init(label: String, dimensions: [(String, String)] = [], factory: MetricsFactory) {
        let handler = factory.makeCounter(label: label, dimensions: dimensions)
        self.init(label: label, dimensions: dimensions, handler: handler, factory: factory)
    }

    /// Signal the underlying metrics library that this counter will never be updated again.
    /// In response the library MAY decide to eagerly release any resources held by this `Counter`.
    @inlinable
    package func destroy() {
        self._factory.destroyCounter(self._handler)
    }
}

extension Counter: CustomStringConvertible {
    package var description: String {
        "Counter(\(self.label), dimensions: \(self.dimensions))"
    }
}

// MARK: - FloatingPointCounter

/// A FloatingPointCounter is a cumulative metric that represents a single monotonically increasing FloatingPointCounter whose value can only increase or be reset to zero.
/// For example, you can use a FloatingPointCounter to represent the number of requests served, tasks completed, or errors.
/// FloatingPointCounter is not supported by all metrics backends, however a default implementation is provided which accumulates floating point values and records increments to a standard Counter after crossing integer boundaries.
///
/// This is the user-facing FloatingPointCounter API.
///
/// Its behavior depends on the `FloatingCounterHandler` implementation.
package final class FloatingPointCounter {
    /// `_handler` and `_factory` are only public to allow access from `MetricsTestKit`.
    /// Do not consider them part of the public API.
    package let _handler: FloatingPointCounterHandler
    @usableFromInline
    package let _factory: MetricsFactory
    package let label: String
    package let dimensions: [(String, String)]

    /// Alternative way to create a new `FloatingPointCounter`, while providing an explicit `FloatingPointCounterHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `FloatingPointCounter` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `FloatingPointCounter`.
    ///     - dimensions: The dimensions for the `FloatingPointCounter`.
    ///     - handler: The custom backend.
    ///     - factory: The custom factory.
    package init(
        label: String,
        dimensions: [(String, String)],
        handler: FloatingPointCounterHandler,
        factory: MetricsFactory
    ) {
        self.label = label
        self.dimensions = dimensions
        self._handler = handler
        self._factory = factory
    }

    /// Alternative way to create a new `FloatingPointCounter`, while providing an explicit `FloatingPointCounterHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `FloatingPointCounter` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `FloatingPointCounter`.
    ///     - dimensions: The dimensions for the `FloatingPointCounter`.
    ///     - handler: The custom backend.
    package convenience init(label: String, dimensions: [(String, String)], handler: FloatingPointCounterHandler) {
        self.init(
            label: label,
            dimensions: dimensions,
            handler: handler,
            factory: MetricsSystem.factory
        )
    }

    /// Increment the FloatingPointCounter.
    ///
    /// - parameters:
    ///     - amount: Amount to increment by.
    @inlinable
    package func increment<DataType: BinaryFloatingPoint>(by amount: DataType) {
        self._handler.increment(by: Double(amount))
    }

    /// Increment the FloatingPointCounter by one.
    @inlinable
    package func increment() {
        self.increment(by: 1.0)
    }

    /// Reset the FloatingPointCounter back to zero.
    @inlinable
    package func reset() {
        self._handler.reset()
    }
}

extension FloatingPointCounter {
    /// Create a new `FloatingPointCounter`.
    ///
    /// - parameters:
    ///     - label: The label for the `FloatingPointCounter`.
    ///     - dimensions: The dimensions for the `FloatingPointCounter`.
    package convenience init(label: String, dimensions: [(String, String)] = []) {
        self.init(label: label, dimensions: dimensions, factory: MetricsSystem.factory)
    }

    /// Create a new `FloatingPointCounter`.
    ///
    /// - parameters:
    ///     - label: The label for the `FloatingPointCounter`.
    ///     - dimensions: The dimensions for the `FloatingPointCounter`.
    ///     - factory: The custom factory.
    package convenience init(label: String, dimensions: [(String, String)] = [], factory: MetricsFactory) {
        let handler = factory.makeFloatingPointCounter(label: label, dimensions: dimensions)
        self.init(label: label, dimensions: dimensions, handler: handler, factory: factory)
    }

    /// Signal the underlying metrics library that this FloatingPointCounter will never be updated again.
    /// In response the library MAY decide to eagerly release any resources held by this `FloatingPointCounter`.
    @inlinable
    package func destroy() {
        self._factory.destroyFloatingPointCounter(self._handler)
    }
}

extension FloatingPointCounter: CustomStringConvertible {
    package var description: String {
        "FloatingPointCounter(\(self.label), dimensions: \(self.dimensions))"
    }
}

// MARK: - Gauge

/// A gauge is a metric that represents a single numerical value that can arbitrarily go up and down.
/// Gauges are typically used for measured values like temperatures or current memory usage, but also "counts" that can go up and down, like the number of active threads.
/// Gauges are modeled as `Recorder` with a sample size of 1 and that does not perform any aggregation.
package final class Gauge: Recorder, @unchecked Sendable {
    /// Create a new `Gauge`.
    ///
    /// - parameters:
    ///     - label: The label for the `Gauge`.
    ///     - dimensions: The dimensions for the `Gauge`.
    package convenience init(label: String, dimensions: [(String, String)] = []) {
        self.init(label: label, dimensions: dimensions, aggregate: false)
    }

    /// Create a new `Gauge`.
    ///
    /// - parameters:
    ///     - label: The label for the `Gauge`.
    ///     - dimensions: The dimensions for the `Gauge`.
    ///     - factory: The custom factory.
    package convenience init(label: String, dimensions: [(String, String)] = [], factory: MetricsFactory) {
        self.init(label: label, dimensions: dimensions, aggregate: false, factory: factory)
    }
}

// MARK: - Meter

/// A meter is similar to a gauge, it is a metric that represents a single numerical value that can arbitrarily go up and down.
/// Meters are typically used for measured values like temperatures or current memory usage, but also "counts" that can go up and down, like the number of active threads.
package final class Meter {
    /// `_handler` and `_factory` are only public to allow access from `MetricsTestKit`.
    /// Do not consider them part of the public API.
    package let _handler: MeterHandler
    @usableFromInline
    package let _factory: MetricsFactory
    package let label: String
    package let dimensions: [(String, String)]

    /// Alternative way to create a new `Meter`, while providing an explicit `MeterHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `Meter` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `Recorder`.
    ///     - dimensions: The dimensions for the `Recorder`.
    ///     - handler: The custom backend.
    ///     - factory: The custom factory.
    package init(label: String, dimensions: [(String, String)], handler: MeterHandler, factory: MetricsFactory) {
        self.label = label
        self.dimensions = dimensions
        self._handler = handler
        self._factory = factory
    }

    /// Alternative way to create a new `Meter`, while providing an explicit `MeterHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `Meter` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `Recorder`.
    ///     - dimensions: The dimensions for the `Recorder`.
    ///     - handler: The custom backend.
    package convenience init(label: String, dimensions: [(String, String)], handler: MeterHandler) {
        self.init(label: label, dimensions: dimensions, handler: handler, factory: MetricsSystem.factory)
    }

    /// Set a value.
    ///
    /// - parameters:
    ///     - value: Value to set.
    @inlinable
    package func set<DataType: BinaryInteger>(_ value: DataType) {
        self._handler.set(Int64(value))
    }

    /// Set a value.
    ///
    /// - parameters:
    ///     - value: Value to est.
    @inlinable
    package func set<DataType: BinaryFloatingPoint>(_ value: DataType) {
        self._handler.set(Double(value))
    }

    /// Increment the Meter.
    ///
    /// - parameters:
    ///     - amount: Amount to increment by.
    @inlinable
    package func increment<DataType: BinaryFloatingPoint>(by amount: DataType) {
        self._handler.increment(by: Double(amount))
    }

    /// Increment the Meter by one.
    @inlinable
    package func increment() {
        self.increment(by: 1.0)
    }

    /// Decrement the Meter.
    ///
    /// - parameters:
    ///     - amount: Amount to decrement by.
    @inlinable
    package func decrement<DataType: BinaryFloatingPoint>(by amount: DataType) {
        self._handler.decrement(by: Double(amount))
    }

    /// Decrement the Meter by one.
    @inlinable
    package func decrement() {
        self.decrement(by: 1.0)
    }
}

extension Meter {
    /// Create a new `Meter`.
    ///
    /// - parameters:
    ///     - label: The label for the `Meter`.
    ///     - dimensions: The dimensions for the `Meter`.
    ///     - factory: The custom factory.
    package convenience init(label: String, dimensions: [(String, String)] = [], factory: MetricsFactory) {
        let handler = factory.makeMeter(label: label, dimensions: dimensions)
        self.init(label: label, dimensions: dimensions, handler: handler, factory: factory)
    }

    /// Create a new `Meter`.
    ///
    /// - parameters:
    ///     - label: The label for the `Meter`.
    ///     - dimensions: The dimensions for the `Meter`.
    package convenience init(label: String, dimensions: [(String, String)] = []) {
        self.init(label: label, dimensions: dimensions, factory: MetricsSystem.factory)
    }

    /// Signal the underlying metrics library that this recorder will never be updated again.
    /// In response the library MAY decide to eagerly release any resources held by this `Recorder`.
    @inlinable
    package func destroy() {
        self._factory.destroyMeter(self._handler)
    }
}

extension Meter: CustomStringConvertible {
    package var description: String {
        "\(type(of: self))(\(self.label), dimensions: \(self.dimensions))"
    }
}

// MARK: - Recorder

/// A recorder collects observations within a time window (usually things like response sizes) and *can* provide aggregated information about the data sample, for example, count, sum, min, max and various quantiles.
///
/// This is the user-facing Recorder API.
///
/// Its behavior depends on the `RecorderHandler` implementation.
package class Recorder {
    /// `_handler` and `_factory` are only public to allow access from `MetricsTestKit`.
    /// Do not consider them part of the public API.
    package let _handler: RecorderHandler
    @usableFromInline
    package let _factory: MetricsFactory
    package let label: String
    package let dimensions: [(String, String)]
    package let aggregate: Bool

    /// Alternative way to create a new `Recorder`, while providing an explicit `RecorderHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `Recorder` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `Recorder`.
    ///     - dimensions: The dimensions for the `Recorder`.
    ///     - aggregate: aggregate recorded values to produce statistics across a sample size
    ///     - handler: The custom backend.
    ///     - factory: The custom factory.
    package init(
        label: String,
        dimensions: [(String, String)],
        aggregate: Bool,
        handler: RecorderHandler,
        factory: MetricsFactory
    ) {
        self.label = label
        self.dimensions = dimensions
        self.aggregate = aggregate
        self._handler = handler
        self._factory = factory
    }

    /// Alternative way to create a new `Recorder`, while providing an explicit `RecorderHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `Recorder` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `Recorder`.
    ///     - dimensions: The dimensions for the `Recorder`.
    ///     - aggregate: aggregate recorded values to produce statistics across a sample size
    ///     - handler: The custom backend.
    package convenience init(label: String, dimensions: [(String, String)], aggregate: Bool, handler: RecorderHandler) {
        self.init(
            label: label,
            dimensions: dimensions,
            aggregate: aggregate,
            handler: handler,
            factory: MetricsSystem.factory
        )
    }

    /// Record a value.
    ///
    /// Recording a value is meant to have "set" semantics, rather than "add" semantics.
    /// This means that the value of this `Recorder` will match the passed in value, rather than accumulate and sum the values up.
    ///
    /// - parameters:
    ///     - value: Value to record.
    @inlinable
    package func record<DataType: BinaryInteger>(_ value: DataType) {
        self._handler.record(Int64(value))
    }

    /// Record a value.
    ///
    /// Recording a value is meant to have "set" semantics, rather than "add" semantics.
    /// This means that the value of this `Recorder` will match the passed in value, rather than accumulate and sum the values up.
    ///
    /// - parameters:
    ///     - value: Value to record.
    @inlinable
    package func record<DataType: BinaryFloatingPoint>(_ value: DataType) {
        self._handler.record(Double(value))
    }
}

extension Recorder {
    /// Create a new `Recorder`.
    ///
    /// - parameters:
    ///     - label: The label for the `Recorder`.
    ///     - dimensions: The dimensions for the `Recorder`.
    ///     - aggregate: aggregate recorded values to produce statistics across a sample size
    package convenience init(label: String, dimensions: [(String, String)] = [], aggregate: Bool = true) {
        self.init(label: label, dimensions: dimensions, aggregate: aggregate, factory: MetricsSystem.factory)
    }

    /// Create a new `Recorder`.
    ///
    /// - parameters:
    ///     - label: The label for the `Recorder`.
    ///     - dimensions: The dimensions for the `Recorder`.
    ///     - aggregate: aggregate recorded values to produce statistics across a sample size.
    ///     - factory: The custom factory.
    package convenience init(
        label: String,
        dimensions: [(String, String)] = [],
        aggregate: Bool = true,
        factory: MetricsFactory
    ) {
        let handler = factory.makeRecorder(label: label, dimensions: dimensions, aggregate: aggregate)
        self.init(label: label, dimensions: dimensions, aggregate: aggregate, handler: handler, factory: factory)
    }

    /// Signal the underlying metrics library that this recorder will never be updated again.
    /// In response the library MAY decide to eagerly release any resources held by this `Recorder`.
    @inlinable
    package func destroy() {
        self._factory.destroyRecorder(self._handler)
    }
}

extension Recorder: CustomStringConvertible {
    package var description: String {
        "\(type(of: self))(\(self.label), dimensions: \(self.dimensions), aggregate: \(self.aggregate))"
    }
}

// MARK: - Timer

package struct TimeUnit: Equatable, Sendable {
    private enum Code: Equatable, Sendable {
        case nanoseconds
        case microseconds
        case milliseconds
        case seconds
        case minutes
        case hours
        case days
    }

    private let code: Code
    package let scaleFromNanoseconds: UInt64

    private init(code: Code, scaleFromNanoseconds: UInt64) {
        assert(scaleFromNanoseconds > 0, "invalid scale from nanoseconds")

        self.code = code
        self.scaleFromNanoseconds = scaleFromNanoseconds
    }

    package static let nanoseconds = TimeUnit(code: .nanoseconds, scaleFromNanoseconds: 1)
    package static let microseconds = TimeUnit(code: .microseconds, scaleFromNanoseconds: 1000)
    package static let milliseconds = TimeUnit(
        code: .milliseconds,
        scaleFromNanoseconds: 1000 * TimeUnit.microseconds.scaleFromNanoseconds
    )
    package static let seconds = TimeUnit(
        code: .seconds,
        scaleFromNanoseconds: 1000 * TimeUnit.milliseconds.scaleFromNanoseconds
    )
    package static let minutes = TimeUnit(
        code: .minutes,
        scaleFromNanoseconds: 60 * TimeUnit.seconds.scaleFromNanoseconds
    )
    package static let hours = TimeUnit(code: .hours, scaleFromNanoseconds: 60 * TimeUnit.minutes.scaleFromNanoseconds)
    package static let days = TimeUnit(code: .days, scaleFromNanoseconds: 24 * TimeUnit.hours.scaleFromNanoseconds)
}

/// A timer collects observations within a time window (usually things like request durations) and provides aggregated information about the data sample,
/// for example, min, max and various quantiles. It is similar to a `Recorder` but specialized for values that represent durations.
///
/// This is the user-facing Timer API.
///
/// Its behavior depends on the `TimerHandler` implementation.
package final class CoreMetricsTimer {
    /// `_handler` and `_factory` are only public to allow access from `MetricsTestKit`.
    /// Do not consider them part of the public API.
    package let _handler: TimerHandler
    @usableFromInline
    package let _factory: MetricsFactory
    package let label: String
    package let dimensions: [(String, String)]

    /// Alternative way to create a new `Timer`, while providing an explicit `TimerHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `Recorder` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `Timer`.
    ///     - dimensions: The dimensions for the `Timer`.
    ///     - handler: The custom backend.
    ///     - factory: The custom factory.
    package init(label: String, dimensions: [(String, String)], handler: TimerHandler, factory: MetricsFactory) {
        self.label = label
        self.dimensions = dimensions
        self._handler = handler
        self._factory = factory
    }

    /// Alternative way to create a new `Timer`, while providing an explicit `TimerHandler`.
    ///
    /// - SeeAlso: Use `init(label:dimensions:)` to create `Recorder` instances using the configured metrics backend.
    ///
    /// - parameters:
    ///     - label: The label for the `Timer`.
    ///     - dimensions: The dimensions for the `Timer`.
    ///     - handler: The custom backend.
    package convenience init(label: String, dimensions: [(String, String)], handler: TimerHandler) {
        self.init(label: label, dimensions: dimensions, handler: handler, factory: MetricsSystem.factory)
    }

    /// Record a duration in nanoseconds.
    ///
    /// - parameters:
    ///     - duration: Duration to record.
    @inlinable
    package func recordNanoseconds(_ duration: Int64) {
        self._handler.recordNanoseconds(duration)
    }

    /// Record a duration in nanoseconds.
    ///
    /// - parameters:
    ///     - duration: Duration to record.
    @inlinable
    package func recordNanoseconds<DataType: BinaryInteger>(_ duration: DataType) {
        self.recordNanoseconds(duration >= Int64.max ? Int64.max : Int64(duration))
    }

    /// Record a duration in microseconds.
    ///
    /// - parameters:
    ///     - duration: Duration to record.
    @inlinable
    package func recordMicroseconds<DataType: BinaryInteger>(_ duration: DataType) {
        guard duration <= Int64.max else { return self.recordNanoseconds(Int64.max) }

        let result = Int64(duration).multipliedReportingOverflow(by: 1000)
        if result.overflow {
            self.recordNanoseconds(Int64.max)
        } else {
            self.recordNanoseconds(result.partialValue)
        }
    }

    /// Record a duration in microseconds.
    ///
    /// - parameters:
    ///     - duration: Duration to record.
    @inlinable
    package func recordMicroseconds<DataType: BinaryFloatingPoint>(_ duration: DataType) {
        self.recordNanoseconds(Double(duration * 1000) < Double(Int64.max) ? Int64(duration * 1000) : Int64.max)
    }

    /// Record a duration in milliseconds.
    ///
    /// - parameters:
    ///     - duration: Duration to record.
    @inlinable
    package func recordMilliseconds<DataType: BinaryInteger>(_ duration: DataType) {
        guard duration <= Int64.max else { return self.recordNanoseconds(Int64.max) }

        let result = Int64(duration).multipliedReportingOverflow(by: 1_000_000)
        if result.overflow {
            self.recordNanoseconds(Int64.max)
        } else {
            self.recordNanoseconds(result.partialValue)
        }
    }

    /// Record a duration in milliseconds.
    ///
    /// - parameters:
    ///     - duration: Duration to record.
    @inlinable
    package func recordMilliseconds<DataType: BinaryFloatingPoint>(_ duration: DataType) {
        self.recordNanoseconds(
            Double(duration * 1_000_000) < Double(Int64.max) ? Int64(duration * 1_000_000) : Int64.max
        )
    }

    /// Record a duration in seconds.
    ///
    /// - parameters:
    ///     - duration: Duration to record.
    @inlinable
    package func recordSeconds<DataType: BinaryInteger>(_ duration: DataType) {
        guard duration <= Int64.max else { return self.recordNanoseconds(Int64.max) }

        let result = Int64(duration).multipliedReportingOverflow(by: 1_000_000_000)
        if result.overflow {
            self.recordNanoseconds(Int64.max)
        } else {
            self.recordNanoseconds(result.partialValue)
        }
    }

    /// Record a duration in seconds.
    ///
    /// - parameters:
    ///     - duration: Duration to record.
    @inlinable
    package func recordSeconds<DataType: BinaryFloatingPoint>(_ duration: DataType) {
        self.recordNanoseconds(
            Double(duration * 1_000_000_000) < Double(Int64.max) ? Int64(duration * 1_000_000_000) : Int64.max
        )
    }
}

extension CoreMetricsTimer {
    /// Create a new `Timer`.
    ///
    /// - parameters:
    ///     - label: The label for the `Timer`.
    ///     - dimensions: The dimensions for the `Timer`.
    ///     - factory: The custom factory.
    package convenience init(label: String, dimensions: [(String, String)] = [], factory: MetricsFactory) {
        let handler = factory.makeTimer(label: label, dimensions: dimensions)
        self.init(label: label, dimensions: dimensions, handler: handler, factory: factory)
    }

    /// Create a new `Timer`.
    ///
    /// - parameters:
    ///     - label: The label for the `Timer`.
    ///     - dimensions: The dimensions for the `Timer`.
    package convenience init(label: String, dimensions: [(String, String)] = []) {
        self.init(label: label, dimensions: dimensions, factory: MetricsSystem.factory)
    }

    /// Create a new `Timer`.
    ///
    /// - parameters:
    ///     - label: The label for the `Timer`.
    ///     - dimensions: The dimensions for the `Timer`.
    ///     - displayUnit: A hint to the backend responsible for presenting the data of the preferred display unit. This is not guaranteed to be supported by all backends.
    ///     - factory: The custom factory.
    package convenience init(
        label: String,
        dimensions: [(String, String)] = [],
        preferredDisplayUnit displayUnit: TimeUnit,
        factory: MetricsFactory
    ) {
        let handler = factory.makeTimer(label: label, dimensions: dimensions)
        handler.preferDisplayUnit(displayUnit)
        self.init(label: label, dimensions: dimensions, handler: handler, factory: factory)
    }

    /// Create a new `Timer`.
    ///
    /// - parameters:
    ///     - label: The label for the `Timer`.
    ///     - dimensions: The dimensions for the `Timer`.
    ///     - displayUnit: A hint to the backend responsible for presenting the data of the preferred display unit. This is not guaranteed to be supported by all backends.
    package convenience init(
        label: String,
        dimensions: [(String, String)] = [],
        preferredDisplayUnit displayUnit: TimeUnit
    ) {
        self.init(
            label: label,
            dimensions: dimensions,
            preferredDisplayUnit: displayUnit,
            factory: MetricsSystem.factory
        )
    }

    /// Signal the underlying metrics library that this timer will never be updated again.
    /// In response the library MAY decide to eagerly release any resources held by this `Timer`.
    @inlinable
    package func destroy() {
        self._factory.destroyTimer(self._handler)
    }
}

extension CoreMetricsTimer: CustomStringConvertible {
    package var description: String {
        "Timer(\(self.label), dimensions: \(self.dimensions))"
    }
}

// MARK: - MetricsSystem

/// The `MetricsSystem` is a global facility where the default metrics backend implementation (`MetricsFactory`) can be
/// configured. `MetricsSystem` is set up just once in a given program to set up the desired metrics backend
/// implementation.
package enum MetricsSystem {
    private static let _factory = FactoryBox(NOOPMetricsHandler.instance)

    /// `bootstrap` is an one-time configuration function which globally selects the desired metrics backend
    /// implementation. `bootstrap` can be called at maximum once in any given program, calling it more than once will
    /// lead to undefined behavior, most likely a crash.
    ///
    /// - parameters:
    ///     - factory: A factory that given an identifier produces instances of metrics handlers such as `CounterHandler`, `RecorderHandler` and `TimerHandler`.
    package static func bootstrap(_ factory: MetricsFactory) {
        self._factory.replaceFactory(factory, validate: true)
    }

    // for our testing we want to allow multiple bootstrapping
    internal static func bootstrapInternal(_ factory: MetricsFactory) {
        self._factory.replaceFactory(factory, validate: false)
    }

    /// Returns a reference to the configured factory.
    package static var factory: MetricsFactory {
        self._factory.underlying
    }

    /// Acquire a writer lock for the duration of the given block.
    ///
    /// - Parameter body: The block to execute while holding the lock.
    /// - Returns: The value returned by the block.
    package static func withWriterLock<T>(_ body: () throws -> T) rethrows -> T {
        try self._factory.withWriterLock(body)
    }

    // This can be `@unchecked Sendable` because we're manually gating access to mutable state with a lock.
    private final class FactoryBox: @unchecked Sendable {
        private let lock = ReadWriteLock()
        fileprivate var _underlying: MetricsFactory
        private var initialized = false

        init(_ underlying: MetricsFactory) {
            self._underlying = underlying
        }

        func replaceFactory(_ factory: MetricsFactory, validate: Bool) {
            self.lock.withWriterLock {
                precondition(
                    !validate || !self.initialized,
                    "metrics system can only be initialized once per process. currently used factory: \(self._underlying)"
                )
                self._underlying = factory
                self.initialized = true
            }
        }

        var underlying: MetricsFactory {
            self.lock.withReaderLock {
                self._underlying
            }
        }

        func withWriterLock<T>(_ body: () throws -> T) rethrows -> T {
            try self.lock.withWriterLock(body)
        }
    }
}

// MARK: - Library SPI, intended to be implemented by backend libraries

// MARK: - MetricsFactory

/// The `MetricsFactory` is the bridge between the `MetricsSystem` and the metrics backend implementation.
/// `MetricsFactory`'s role is to initialize concrete implementations of the various metric types:
/// * `Counter` -> `CounterHandler`
/// * `FloatingPointCounter` -> `FloatingPointCounterHandler`
/// * `Recorder` -> `RecorderHandler`
/// * `Timer` -> `TimerHandler`
///
/// To use the SwiftMetrics API, please refer to the documentation of `MetricsSystem`.
///
/// # Destroying metrics
///
/// Since _some_ metrics implementations may need to allocate (potentially "heavy") resources for metrics, destroying
/// metrics offers a signal to libraries when a metric is "known to never be updated again."
///
/// While many metrics are bound to the entire lifetime of an application and thus never need to be destroyed eagerly,
/// some metrics have well defined unique life-cycles, and it may be beneficial to release any resources held by them
/// more eagerly than awaiting the application's termination. In such cases, a library or application should invoke
/// a metric's appropriate `destroy()` method, which in turn results in the corresponding handler that it is backed by
/// to be passed to `destroyCounter(handler:)`, `destroyRecorder(handler:)` or `destroyTimer(handler:)` where the factory
/// can decide to free any corresponding resources.
///
/// While some libraries may not need to implement this destroying as they may be stateless or similar,
/// libraries using the metrics API should always assume a library WILL make use of this signal, and shall not
/// neglect calling these methods when appropriate.
package protocol MetricsFactory: _SwiftMetricsSendableProtocol {
    /// Create a backing `CounterHandler`.
    ///
    /// - parameters:
    ///     - label: The label for the `CounterHandler`.
    ///     - dimensions: The dimensions for the `CounterHandler`.
    func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler

    /// Create a backing `FloatingPointCounterHandler`.
    ///
    /// - parameters:
    ///     - label: The label for the `FloatingPointCounterHandler`.
    ///     - dimensions: The dimensions for the `FloatingPointCounterHandler`.
    func makeFloatingPointCounter(label: String, dimensions: [(String, String)]) -> FloatingPointCounterHandler

    /// Create a backing `MeterHandler`.
    ///
    /// - parameters:
    ///     - label: The label for the `MeterHandler`.
    ///     - dimensions: The dimensions for the `MeterHandler`.
    func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler

    /// Create a backing `RecorderHandler`.
    ///
    /// - parameters:
    ///     - label: The label for the `RecorderHandler`.
    ///     - dimensions: The dimensions for the `RecorderHandler`.
    ///     - aggregate: Is data aggregation expected.
    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler

    /// Create a backing `TimerHandler`.
    ///
    /// - parameters:
    ///     - label: The label for the `TimerHandler`.
    ///     - dimensions: The dimensions for the `TimerHandler`.
    func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler

    /// Invoked when the corresponding `Counter`'s `destroy()` function is invoked.
    /// Upon receiving this signal the factory may eagerly release any resources related to this counter.
    ///
    /// - parameters:
    ///     - handler: The handler to be destroyed.
    func destroyCounter(_ handler: CounterHandler)

    /// Invoked when the corresponding `Meter`'s `destroy()` function is invoked.
    /// Upon receiving this signal the factory may eagerly release any resources related to this recorder.
    ///
    /// - parameters:
    ///     - handler: The handler to be destroyed.
    func destroyMeter(_ handler: MeterHandler)

    /// Invoked when the corresponding `FloatingPointCounter`'s `destroy()` function is invoked.
    /// Upon receiving this signal the factory may eagerly release any resources related to this counter.
    ///
    /// - parameters:
    ///     - handler: The handler to be destroyed.
    func destroyFloatingPointCounter(_ handler: FloatingPointCounterHandler)

    /// Invoked when the corresponding `Recorder`'s `destroy()` function is invoked.
    /// Upon receiving this signal the factory may eagerly release any resources related to this recorder.
    ///
    /// - parameters:
    ///     - handler: The handler to be destroyed.
    func destroyRecorder(_ handler: RecorderHandler)

    /// Invoked when the corresponding `Timer`'s `destroy()` function is invoked.
    /// Upon receiving this signal the factory may eagerly release any resources related to this timer.
    ///
    /// - parameters:
    ///     - handler: The handler to be destroyed.
    func destroyTimer(_ handler: TimerHandler)
}

/// Wraps a CounterHandler, adding support for incrementing by floating point values by storing an accumulated floating point value and recording increments to the underlying CounterHandler after crossing integer boundaries.
internal final class AccumulatingRoundingFloatingPointCounter: FloatingPointCounterHandler {
    private let lock = Lock()
    private let counterHandler: CounterHandler
    private let factory: MetricsFactory
    internal var fraction: Double = 0

    init(label: String, dimensions: [(String, String)], factory: MetricsFactory) {
        self.counterHandler = factory.makeCounter(label: label, dimensions: dimensions)
        self.factory = factory
    }

    func increment(by amount: Double) {
        // Drop illegal values
        // - cannot increment by NaN
        guard !amount.isNaN else { return }
        // - cannot increment by infinite quantities
        guard !amount.isInfinite else { return }
        // - cannot increment by negative values
        guard amount.sign == .plus else { return }
        // - cannot increment by zero
        guard !amount.isZero else { return }

        if amount.exponent >= 63 {
            // If amount is in Int64.max..<+Inf, ceil to Int64.max
            self.lock.withLockVoid {
                self.counterHandler.increment(by: .max)
            }
        } else {
            // Split amount into integer and fraction components
            var (increment, fraction) = self.integerAndFractionComponents(of: amount)
            self.lock.withLockVoid {
                // Add the fractional component to the accumulated fraction.
                self.fraction += fraction
                // self.fraction may have cross an integer boundary, Split it
                // and add any integer component.
                let (integer, fraction) = integerAndFractionComponents(of: self.fraction)
                increment += integer
                self.fraction = fraction
                // Increment the handler by the total integer component.
                if increment > 0 {
                    self.counterHandler.increment(by: increment)
                }
            }
        }
    }

    @inline(__always)
    private func integerAndFractionComponents(of value: Double) -> (Int64, Double) {
        let integer = Int64(value)
        let fraction = value - value.rounded(.towardZero)
        return (integer, fraction)
    }

    func reset() {
        self.lock.withLockVoid {
            self.fraction = 0
            self.counterHandler.reset()
        }
    }

    func destroy() {
        self.factory.destroyCounter(self.counterHandler)
    }
}

/// Wraps a RecorderHandler, adding support for incrementing values by storing an accumulated  value and recording increments to the underlying CounterHandler after crossing integer boundaries.
/// - Note: we can annotate this class as `@unchecked Sendable` because we are manually gating access to mutable state (i.e., the `value` property) via a Lock.
internal final class AccumulatingMeter: MeterHandler, @unchecked Sendable {
    private let recorderHandler: RecorderHandler
    // FIXME: use swift-atomics when floating point support is available
    private var value: Double = 0
    private let lock = Lock()
    private let factory: MetricsFactory

    init(label: String, dimensions: [(String, String)], factory: MetricsFactory) {
        self.recorderHandler = factory.makeRecorder(label: label, dimensions: dimensions, aggregate: true)
        self.factory = factory
    }

    func set(_ value: Int64) {
        self._set(Double(value))
    }

    func set(_ value: Double) {
        self._set(value)
    }

    func increment(by amount: Double) {
        // Drop illegal values
        // - cannot increment by NaN
        guard !amount.isNaN else {
            return
        }
        // - cannot increment by infinite quantities
        guard !amount.isInfinite else {
            return
        }
        // - cannot increment by negative values
        guard amount.sign == .plus else {
            return
        }
        // - cannot increment by zero
        guard !amount.isZero else {
            return
        }

        let newValue: Double = self.lock.withLock {
            self.value += amount
            return self.value
        }
        self.recorderHandler.record(newValue)
    }

    func decrement(by amount: Double) {
        // Drop illegal values
        // - cannot decrement by NaN
        guard !amount.isNaN else {
            return
        }
        // - cannot decrement by infinite quantities
        guard !amount.isInfinite else {
            return
        }
        // - cannot decrement by negative values
        guard amount.sign == .plus else {
            return
        }
        // - cannot decrement by zero
        guard !amount.isZero else {
            return
        }

        let newValue: Double = self.lock.withLock {
            self.value -= amount
            return self.value
        }
        self.recorderHandler.record(newValue)
    }

    private func _set(_ value: Double) {
        self.lock.withLockVoid {
            self.value = value
        }
        self.recorderHandler.record(value)
    }

    func destroy() {
        self.factory.destroyRecorder(self.recorderHandler)
    }
}

extension MetricsFactory {
    /// Create a default backing `FloatingPointCounterHandler` for backends which do not naively support floating point counters.
    ///
    /// The created FloatingPointCounterHandler is a wrapper around a backend's CounterHandler which accumulates floating point values and records increments to an underlying CounterHandler after crossing integer boundaries.
    ///
    /// - parameters:
    ///     - label: The label for the `FloatingPointCounterHandler`.
    ///     - dimensions: The dimensions for the `FloatingPointCounterHandler`.
    package func makeFloatingPointCounter(label: String, dimensions: [(String, String)]) -> FloatingPointCounterHandler {
        AccumulatingRoundingFloatingPointCounter(label: label, dimensions: dimensions, factory: self)
    }

    /// Invoked when the corresponding `FloatingPointCounter`'s `destroy()` function is invoked.
    /// Upon receiving this signal the factory may eagerly release any resources related to this counter.
    ///
    /// `destroyFloatingPointCounter` must be implemented if `makeFloatingPointCounter` is implemented.
    ///
    /// - parameters:
    ///     - handler: The handler to be destroyed.
    package func destroyFloatingPointCounter(_ handler: FloatingPointCounterHandler) {
        (handler as? AccumulatingRoundingFloatingPointCounter)?.destroy()
    }
}

extension MetricsFactory {
    /// Create a default backing `MeterHandler` for backends which do not naively support meters.
    ///
    /// The created MeterHandler is a wrapper around a backend's RecorderHandler which records current values.
    ///
    /// - parameters:
    ///     - label: The label for the `MeterHandler`.
    ///     - dimensions: The dimensions for the `MeterHandler`.
    package func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        AccumulatingMeter(label: label, dimensions: dimensions, factory: self)
    }

    /// Invoked when the corresponding `Meter`'s `destroy()` function is invoked.
    /// Upon receiving this signal the factory may eagerly release any resources related to this counter.
    ///
    /// `destroyMeter` must be implemented if `makeMeter` is implemented.
    ///
    /// - parameters:
    ///     - handler: The handler to be destroyed.
    package func destroyMeter(_ handler: MeterHandler) {
        (handler as? AccumulatingMeter)?.destroy()
    }
}

// MARK: - Backend Handlers

/// A `CounterHandler` represents a backend implementation of a `Counter`.
///
/// This type is an implementation detail and should not be used directly, unless implementing your own metrics backend.
/// To use the SwiftMetrics API, please refer to the documentation of `Counter`.
///
/// # Implementation requirements
///
/// To implement your own `CounterHandler` you should respect a few requirements that are necessary so applications work
/// as expected regardless of the selected `CounterHandler` implementation.
///
/// - The `CounterHandler` must be a `class`.
package protocol CounterHandler: AnyObject, _SwiftMetricsSendableProtocol {
    /// Increment the counter.
    ///
    /// - parameters:
    ///     - by: Amount to increment by.
    func increment(by: Int64)

    /// Reset the counter back to zero.
    func reset()
}

/// A `FloatingPointCounterHandler` represents a backend implementation of a `FloatingPointCounter`.
///
/// This type is an implementation detail and should not be used directly, unless implementing your own metrics backend.
/// To use the SwiftMetrics API, please refer to the documentation of `FloatingPointCounter`.
///
/// # Implementation requirements
///
/// To implement your own `FloatingPointCounterHandler` you should respect a few requirements that are necessary so applications work
/// as expected regardless of the selected `FloatingPointCounterHandler` implementation.
///
/// - The `FloatingPointCounterHandler` must be a `class`.
package protocol FloatingPointCounterHandler: AnyObject, _SwiftMetricsSendableProtocol {
    /// Increment the counter.
    ///
    /// - parameters:
    ///     - by: Amount to increment by.
    func increment(by: Double)

    /// Reset the counter back to zero.
    func reset()
}

/// A `RecorderHandler` represents a backend implementation of a `Recorder`.
///
/// This type is an implementation detail and should not be used directly, unless implementing your own metrics backend.
/// To use the SwiftMetrics API, please refer to the documentation of `Recorder`.
///
/// # Implementation requirements
///
/// To implement your own `RecorderHandler` you should respect a few requirements that are necessary so applications work
/// as expected regardless of the selected `RecorderHandler` implementation.
///
/// - The `RecorderHandler` must be a `class`.
package protocol RecorderHandler: AnyObject, _SwiftMetricsSendableProtocol {
    /// Record a value.
    ///
    /// - parameters:
    ///     - value: Value to record.
    func record(_ value: Int64)
    /// Record a value.
    ///
    /// - parameters:
    ///     - value: Value to record.
    func record(_ value: Double)
}

/// A `MeterHandler` represents a backend implementation of a `Meter`.
///
/// This type is an implementation detail and should not be used directly, unless implementing your own metrics backend.
/// To use the SwiftMetrics API, please refer to the documentation of `Meter`.
///
/// # Implementation requirements
///
/// To implement your own `MeterHandler` you should respect a few requirements that are necessary so applications work
/// as expected regardless of the selected `MeterHandler` implementation.
///
/// - The `RecorderHandler` must be a `class`.
package protocol MeterHandler: AnyObject, _SwiftMetricsSendableProtocol {
    /// Set a value.
    ///
    /// - parameters:
    ///     - value: Value to set.
    func set(_ value: Int64)
    /// Set a value.
    ///
    /// - parameters:
    ///     - value: Value to set.
    func set(_ value: Double)

    /// Increment the value.
    ///
    /// - parameters:
    ///     - by: Amount to increment by.
    func increment(by: Double)

    /// Decrement the value.
    ///
    /// - parameters:
    ///     - by: Amount to increment by.
    func decrement(by: Double)
}

/// A `TimerHandler` represents a backend implementation of a `Timer`.
///
/// This type is an implementation detail and should not be used directly, unless implementing your own metrics backend.
/// To use the SwiftMetrics API, please refer to the documentation of `Timer`.
///
/// # Implementation requirements
///
/// To implement your own `TimerHandler` you should respect a few requirements that are necessary so applications work
/// as expected regardless of the selected `TimerHandler` implementation.
///
/// - The `TimerHandler` must be a `class`.
package protocol TimerHandler: AnyObject, _SwiftMetricsSendableProtocol {
    /// Record a duration in nanoseconds.
    ///
    /// - parameters:
    ///     - duration: Duration to record.
    func recordNanoseconds(_ duration: Int64)

    /// Set the preferred display unit for this TimerHandler.
    ///
    /// - parameters:
    ///     - unit: A hint to the backend responsible for presenting the data of the preferred display unit. This is not guaranteed to be supported by all backends.
    func preferDisplayUnit(_ unit: TimeUnit)
}

extension TimerHandler {
    package func preferDisplayUnit(_: TimeUnit) {
        // NOOP
    }
}

// MARK: - Predefined Metrics Handlers

/// A pseudo-metrics handler that can be used to send messages to multiple other metrics handlers.
package final class MultiplexMetricsHandler: MetricsFactory {
    private let factories: [MetricsFactory]
    package init(factories: [MetricsFactory]) {
        self.factories = factories
    }

    package func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        MuxCounter(factories: self.factories, label: label, dimensions: dimensions)
    }

    package func makeFloatingPointCounter(label: String, dimensions: [(String, String)]) -> FloatingPointCounterHandler {
        MuxFloatingPointCounter(factories: self.factories, label: label, dimensions: dimensions)
    }

    package func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        MuxMeter(factories: self.factories, label: label, dimensions: dimensions)
    }

    package func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        MuxRecorder(factories: self.factories, label: label, dimensions: dimensions, aggregate: aggregate)
    }

    package func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        MuxTimer(factories: self.factories, label: label, dimensions: dimensions)
    }

    package func destroyCounter(_ handler: CounterHandler) {
        for factory in self.factories {
            factory.destroyCounter(handler)
        }
    }

    package func destroyFloatingPointCounter(_ handler: FloatingPointCounterHandler) {
        for factory in self.factories {
            factory.destroyFloatingPointCounter(handler)
        }
    }

    package func destroyMeter(_ handler: MeterHandler) {
        for factory in self.factories {
            factory.destroyMeter(handler)
        }
    }

    package func destroyRecorder(_ handler: RecorderHandler) {
        for factory in self.factories {
            factory.destroyRecorder(handler)
        }
    }

    package func destroyTimer(_ handler: TimerHandler) {
        for factory in self.factories {
            factory.destroyTimer(handler)
        }
    }

    private final class MuxCounter: CounterHandler {
        let counters: [CounterHandler]
        package init(factories: [MetricsFactory], label: String, dimensions: [(String, String)]) {
            self.counters = factories.map { $0.makeCounter(label: label, dimensions: dimensions) }
        }

        func increment(by amount: Int64) {
            for counter in self.counters { counter.increment(by: amount) }
        }

        func reset() {
            for counter in self.counters { counter.reset() }
        }
    }

    private final class MuxFloatingPointCounter: FloatingPointCounterHandler {
        let counters: [FloatingPointCounterHandler]
        package init(factories: [MetricsFactory], label: String, dimensions: [(String, String)]) {
            self.counters = factories.map { $0.makeFloatingPointCounter(label: label, dimensions: dimensions) }
        }

        func increment(by amount: Double) {
            for counter in self.counters { counter.increment(by: amount) }
        }

        func reset() {
            for counter in self.counters { counter.reset() }
        }
    }

    private final class MuxMeter: MeterHandler {
        let meters: [MeterHandler]
        package init(factories: [MetricsFactory], label: String, dimensions: [(String, String)]) {
            self.meters = factories.map { $0.makeMeter(label: label, dimensions: dimensions) }
        }

        func set(_ value: Int64) {
            for meter in self.meters { meter.set(value) }
        }

        func set(_ value: Double) {
            for meter in self.meters { meter.set(value) }
        }

        func increment(by amount: Double) {
            for meter in self.meters { meter.increment(by: amount) }
        }

        func decrement(by amount: Double) {
            for meter in self.meters { meter.decrement(by: amount) }
        }
    }

    private final class MuxRecorder: RecorderHandler {
        let recorders: [RecorderHandler]
        package init(factories: [MetricsFactory], label: String, dimensions: [(String, String)], aggregate: Bool) {
            self.recorders = factories.map {
                $0.makeRecorder(label: label, dimensions: dimensions, aggregate: aggregate)
            }
        }

        func record(_ value: Int64) {
            for recorder in self.recorders { recorder.record(value) }
        }

        func record(_ value: Double) {
            for recorder in self.recorders { recorder.record(value) }
        }
    }

    private final class MuxTimer: TimerHandler {
        let timers: [TimerHandler]
        package init(factories: [MetricsFactory], label: String, dimensions: [(String, String)]) {
            self.timers = factories.map { $0.makeTimer(label: label, dimensions: dimensions) }
        }

        func recordNanoseconds(_ duration: Int64) {
            for timer in self.timers { timer.recordNanoseconds(duration) }
        }

        func preferDisplayUnit(_ unit: TimeUnit) {
            for timer in self.timers { timer.preferDisplayUnit(unit) }
        }
    }
}

/// Ships with the metrics module, used for initial bootstrapping.
package final class NOOPMetricsHandler: MetricsFactory, CounterHandler, FloatingPointCounterHandler, MeterHandler,
    RecorderHandler, TimerHandler
{
    package static let instance = NOOPMetricsHandler()

    private init() {}

    package func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        self
    }

    package func makeFloatingPointCounter(label: String, dimensions: [(String, String)]) -> FloatingPointCounterHandler {
        self
    }

    package func makeMeter(label: String, dimensions: [(String, String)]) -> MeterHandler {
        self
    }

    package func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        self
    }

    package func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        self
    }

    package func destroyCounter(_: CounterHandler) {}
    package func destroyFloatingPointCounter(_: FloatingPointCounterHandler) {}
    package func destroyMeter(_: MeterHandler) {}
    package func destroyRecorder(_: RecorderHandler) {}
    package func destroyTimer(_: TimerHandler) {}

    package func increment(by: Int64) {}
    package func increment(by: Double) {}
    package func decrement(by: Double) {}
    package func reset() {}
    package func record(_: Int64) {}
    package func record(_: Double) {}
    package func recordNanoseconds(_: Int64) {}
    package func set(_: Int64) {}
    package func set(_: Double) {}
}

// MARK: - Sendable support helpers

extension MetricsSystem: Sendable {}
extension Counter: Sendable {}
extension FloatingPointCounter: Sendable {}
// must be @unchecked since Gauge inherits Recorder :(
extension Recorder: @unchecked Sendable {}
extension CoreMetricsTimer: Sendable {}
extension Meter: Sendable {}
// ideally we would not be using @unchecked here, but concurrency-safety checks do not recognize locks
extension AccumulatingRoundingFloatingPointCounter: @unchecked Sendable {}

@preconcurrency package protocol _SwiftMetricsSendableProtocol: Sendable {}
