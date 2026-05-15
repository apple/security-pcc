// Copyright © 2025 Apple Inc. All Rights Reserved.

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

import Atomics
import CloudBoardCommon
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import NIOHPACK
import os
import ServiceContextModule
import Tracing

enum OperationNames {
    static let invokeWorkload = "workload.invocation"
    static let invokeWorkloadRequest = "workload.invocation.request"
    static let invokeWorkloadResponse = "workload.invocation.response"
    static let nackRequest = "nack.request"
}

/// Tracer to collect and emit "Request Summary" information.
/// When using this tracer every request has a `RequestSummary` entry in the logs.
public final class RequestSummaryJobHelperTracer: Tracing.Tracer, RequestIDInstrument, Sendable {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardJobHelperRequestSummary"
    )
    public static let tracingLogger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "CloudBoardJobHelperRequestSummary"
    )
    private let metrics: any MetricsSystem

    struct ActiveTrace {
        var invokeWorkloadSpan: Span?
        var invokeWorkloadRequestSpans: [Span] = []
        var invokeWorkloadResponseSpans: [Span] = []
        var customSpans: [Span] = []

        init() {}
    }

    private let spanIDGenerator = ManagedAtomic<UInt64>(0)
    private let requestSpans: OSAllocatedUnfairLock<[String: ActiveTrace]> = .init(initialState: [:])

    public init(metrics: any MetricsSystem) {
        self.metrics = metrics
    }

    public func startSpan(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> some TracerInstant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> Span {
        let context = context()
        let newSpanID: UInt64 = TraceContextCache.singletonCache.generateNewSpanID()
        let parentID = context.spanID
        let requestID = context.requestID ?? "requestID not passed through context"
        var nextContext = context
        nextContext.spanID = newSpanID

        if parentID == nil {
            // this is a new root span
            self.requestSpans.withLock {
                assert($0[requestID] == nil)
                $0[requestID] = .init()
            }
        }

        let span = Span(
            startTimeNanos: instant().nanosecondsSinceEpoch,
            operationName: operationName,
            kind: kind,
            requestID: requestID,
            parentID: parentID,
            spanID: newSpanID,
            context: nextContext,
            tracer: self,
            function: function,
            fileID: fileID,
            line: line,
            logger: Self.logger
        )

        return span
    }

    public func forceFlush() {
        // we can ignore this. we only flush to the logger
    }

    fileprivate func closeSpan(_ span: Span) {
        let requestId = span.requestID
        let isRoot = span.parentID == nil

        if isRoot {
            assert(OperationNames.invokeWorkload == span.operationName, "Unexpected span name: \(span.operationName)")
            let trace: ActiveTrace? = self.requestSpans.withLock { requestSpans in
                if var trace = requestSpans.removeValue(forKey: requestId) {
                    trace.invokeWorkloadSpan = span
                    return trace
                }
                return nil
            }

            guard let trace else {
                Self.logger.error("Could not find any trace for requestId: \(requestId, privacy: .public)")
                return
            }

            // Only log invokeWorkload operations for now
            if span.operationName == OperationNames.invokeWorkload {
                CloudBoardJobHelperRequestSummary(from: trace).log(to: Self.tracingLogger)
                CloudBoardJobHelperRequestSummary(from: trace).measure(to: self.metrics)
            }
        } else if span.operationName == OperationNames.invokeWorkloadRequest {
            self.requestSpans.withLock {
                $0[requestId]?.invokeWorkloadRequestSpans.append(span)
            }
        } else if span.operationName == OperationNames.invokeWorkloadResponse {
            self.requestSpans.withLock {
                $0[requestId]?.invokeWorkloadResponseSpans.append(span)
            }
        } else {
            self.requestSpans.withLock {
                assert($0[requestId] != nil)
                $0[requestId]?.customSpans.append(span)
            }
        }
    }
}

extension RequestSummaryJobHelperTracer {
    public final class Span: Tracing.Span, Sendable {
        private struct Storage: Sendable {
            var recordingState: RecordingState
            var context: ServiceContext
            var events: [Tracing.SpanEvent]
            var status: Tracing.SpanStatus?
            var errors: [any Error]
            var attributes: Tracing.SpanAttributes
            var links: [Tracing.SpanLink]
            var operationName: String
        }

        enum RecordingState {
            case open(RequestSummaryJobHelperTracer)
            case closed(endTimeNanos: UInt64)
        }

        let startTimeNanos: UInt64
        let kind: Tracing.SpanKind

        let requestID: String
        let spanID: UInt64
        let parentID: UInt64?

        let function: String
        let fileID: String
        let line: UInt

        var errors: [any Error] {
            self.storage.withLock { $0.errors }
        }

        var status: Tracing.SpanStatus? {
            self.storage.withLock { $0.status }
        }

        private let storage: OSAllocatedUnfairLock<Storage>

        private let logger: Logger?

        init(
            startTimeNanos: UInt64,
            operationName: String,
            kind: Tracing.SpanKind,
            requestID: String,
            parentID: UInt64?,
            spanID: UInt64,
            context: ServiceContext,
            tracer: RequestSummaryJobHelperTracer,
            function: String,
            fileID: String,
            line: UInt,
            logger: Logger?
        ) {
            self.startTimeNanos = startTimeNanos
            self.kind = kind

            self.requestID = requestID
            self.parentID = parentID
            self.spanID = spanID

            self.function = function
            self.fileID = fileID
            self.line = line
            self.storage = .init(
                initialState:
                .init(
                    recordingState: .open(tracer),
                    context: context,
                    events: [],
                    status: nil,
                    errors: [],
                    attributes: .init(),
                    links: [],
                    operationName: operationName
                )
            )
            self.logger = logger
        }

        deinit {
            self.storage.withLock { storage in
                switch storage.recordingState {
                case .closed:
                    break
                case .open:
                    let requestId = storage.context.requestID ?? ""
                    self.logger?
                        .fault(
                            "[requestID: \(requestId, privacy: .public), parentID: \(self.parentID?.hexEncoded ?? "", privacy: .public), spanID: \(self.spanID.hexEncoded, privacy: .public)] Reference to unended span dropped"
                        )
                }
            }
        }

        public var isRecording: Bool {
            self.storage.withLock { storage -> Bool in
                switch storage.recordingState {
                case .closed:
                    false
                case .open:
                    true
                }
            }
        }

        public var operationName: String {
            get { self.storage.withLock { $0.operationName } }
            set { self.storage.withLock { $0.operationName = newValue } }
        }

        public var context: ServiceContext {
            get { self.storage.withLock { $0.context } }
            set { self.storage.withLock { $0.context = newValue } }
        }

        public var attributes: Tracing.SpanAttributes {
            get { self.storage.withLock { $0.attributes } }
            set { self.storage.withLock { $0.attributes = newValue } }
        }

        public func setStatus(_ status: Tracing.SpanStatus) {
            self.storage.withLock { $0.status = status }
        }

        public func addEvent(_ event: Tracing.SpanEvent) {
            self.storage.withLock { $0.events.append(event) }
        }

        public func recordError(
            _ error: any Error,
            attributes _: Tracing.SpanAttributes,
            at _: @autoclosure () -> some Tracing.TracerInstant
        ) {
            self.storage.withLock { $0.errors.append(error) }
        }

        public func addLink(_ link: Tracing.SpanLink) {
            self.storage.withLock { $0.links.append(link) }
        }

        public func end(at instant: @autoclosure () -> some TracerInstant) {
            let endTimeNanos = instant().nanosecondsSinceEpoch
            let tracer = self.storage.withLock { storage -> RequestSummaryJobHelperTracer? in
                switch storage.recordingState {
                case .open(let tracer):
                    storage.recordingState = .closed(endTimeNanos: endTimeNanos)
                    return tracer
                case .closed:
                    let requestID = storage.context.requestID ?? ""
                    self.logger?
                        .fault(
                            "[requestID: \(requestID, privacy: .public), parentID: \(self.parentID?.hexEncoded ?? "", privacy: .public), spanID: \(self.spanID.hexEncoded, privacy: .public)] Span already closed"
                        )
                    return nil
                }
            }
            if let tracer {
                tracer.closeSpan(self)
            }
        }

        var endTimeNanos: UInt64 {
            self.storage.withLock { storage in
                guard case .closed(let stopTimeNanos) = storage.recordingState else {
                    let requestID = storage.context.requestID ?? ""
                    self.logger?
                        .fault(
                            "[requestID: \(requestID, privacy: .public), parentID: \(self.parentID?.hexEncoded ?? "", privacy: .public), spanID: \(self.spanID.hexEncoded, privacy: .public)] endTimeNanos queried for closed span"
                        )
                    return 0
                }
                return stopTimeNanos
            }
        }
    }
}

struct SpanIDKey: ServiceContextKey {
    typealias Value = UInt64
    static var nameOverride: String? { "spanID" }
}

struct ParentSpanIDKey: ServiceContextKey {
    typealias Value = UInt64
    static var nameOverride: String? { "parentSpanID" }
}

extension ServiceContext {
    public var spanID: UInt64? {
        get { self[SpanIDKey.self] }
        set { self[SpanIDKey.self] = newValue }
    }

    public var parentSpanID: UInt64? {
        get { self[ParentSpanIDKey.self] }
        set { self[ParentSpanIDKey.self] = newValue }
    }
}

extension CloudBoardJobHelperRequestSummary {
    public init(from trace: RequestSummaryJobHelperTracer.ActiveTrace) {
        var summary = CloudBoardJobHelperRequestSummary()
        // The order in which we populate the summary matters for NACK handling.
        summary.populate(invokeWorkloadRequestSpans: trace.invokeWorkloadRequestSpans)
        summary.populate(invokeWorkloadResponseSpans: trace.invokeWorkloadResponseSpans)
        summary.populate(invokeWorkloadSpan: trace.invokeWorkloadSpan)
        self = summary
    }
}
