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

import CloudBoardCommon
internal import CloudBoardDomain
import CloudBoardLogging
import Foundation
import Instrumentation
import os
import ServiceContextModule
import Synchronization
import Tracing

// MARK: - ServiceContext keys (write-only; used for distributed tracing propagation)

private struct BridgeTraceIDKey: ServiceContextKey {
    typealias Value = UUID
    static var nameOverride: String { "bridgeTraceID" }
}

private struct BridgeRequestIDKey: ServiceContextKey {
    typealias Value = String
    static var nameOverride: String { "bridgeRequestID" }
}

private struct BridgeParentSpanIDKey: ServiceContextKey {
    typealias Value = UInt64
    static var nameOverride: String { "bridgeParentSpanID" }
}

// MARK: - Tracer

final class BridgeRequestSummaryTracer: Tracing.Tracer, Sendable {
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "CloudBoardBridgeServer"
    )

    func startSpan(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind _: SpanKind,
        at _: @autoclosure () -> some TracerInstant,
        function _: String,
        file _: String,
        line _: UInt
    ) -> Span {
        let context = context()
        if context[BridgeTraceIDKey.self] == nil || context[BridgeRequestIDKey.self] == nil ||
            context[BridgeParentSpanIDKey.self] == nil {
            Self.logger.fault(
                "BridgeRequestSummaryTracer.startSpan called without context keys; use withSpan(_:traceContext:_:) instead"
            )
        }
        return self.makeSpan(
            operationName: operationName,
            traceID: context[BridgeTraceIDKey.self] ?? UUID(),
            requestID: context[BridgeRequestIDKey.self] ?? "UNKNOWN",
            parentSpanID: context[BridgeParentSpanIDKey.self] ?? 0,
            context: context
        )
    }

    func forceFlush() {}

    func extract<Carrier, Extract>(
        _: Carrier,
        into _: inout ServiceContext,
        using _: Extract
    ) where Carrier == Extract.Carrier, Extract: Instrumentation.Extractor {}

    func inject<Carrier, Inject>(
        _: ServiceContext,
        into _: inout Carrier,
        using _: Inject
    ) where Carrier == Inject.Carrier, Inject: Instrumentation.Injector {}

    fileprivate func closeSpan(_ span: Span) {
        BridgeServerRequestSummary(from: span).log(to: Self.logger)
    }

    private func makeSpan(
        operationName: String,
        traceID: UUID,
        requestID: String,
        parentSpanID: UInt64,
        context: ServiceContext = .topLevel
    ) -> Span {
        Span(
            operationName: operationName,
            kind: .internal,
            startTimeNanos: DefaultTracerClock.now.nanosecondsSinceEpoch,
            spanID: TraceContextCache.singletonCache.generateNewSpanID(),
            parentSpanID: parentSpanID,
            traceID: traceID,
            requestID: requestID,
            context: context,
            tracer: self,
            logger: Self.logger
        )
    }
}

// MARK: - Convenience withSpan overloads

extension BridgeRequestSummaryTracer {
    func withSpan<T>(
        _ operationName: StaticString,
        traceContext: PCCToolInvocationTraceContext,
        _ body: (Span) async throws -> T
    ) async rethrows -> T {
        var ctx = ServiceContext.topLevel
        ctx[BridgeTraceIDKey.self] = traceContext.traceID
        ctx[BridgeRequestIDKey.self] = traceContext.serverRequestID
        ctx[BridgeParentSpanIDKey.self] = traceContext.spanID
        return try await self.withSpan(String(describing: operationName), context: ctx, body)
    }

    func withSpan<T>(
        _ operationName: StaticString,
        traceContext: AppleSigningServiceTraceContext,
        _ body: (Span) async throws -> T
    ) async rethrows -> T {
        var ctx = ServiceContext.topLevel
        ctx[BridgeTraceIDKey.self] = traceContext.traceID
        ctx[BridgeRequestIDKey.self] = traceContext.serverRequestID
        ctx[BridgeParentSpanIDKey.self] = traceContext.spanID
        return try await self.withSpan(String(describing: operationName), context: ctx, body)
    }

    func withSpan<T>(
        _ operationName: StaticString,
        traceContext: CIPCompanionServiceTraceContext,
        _ body: (Span) async throws -> T
    ) async rethrows -> T {
        var ctx = ServiceContext.topLevel
        ctx[BridgeTraceIDKey.self] = traceContext.traceID
        ctx[BridgeRequestIDKey.self] = traceContext.serverRequestID
        ctx[BridgeParentSpanIDKey.self] = traceContext.spanID
        return try await self.withSpan(String(describing: operationName), context: ctx, body)
    }
}

// MARK: - Span

extension BridgeRequestSummaryTracer {
    final class Span: Tracing.Span, Sendable {
        private struct Storage: Sendable {
            var recordingState: RecordingState
            var context: ServiceContext
            var events: [Tracing.SpanEvent]
            var status: Tracing.SpanStatus?
            var errors: [any Error]
            var attributes: Tracing.SpanAttributes
            var links: [Tracing.SpanLink]
            var operationName: String
            var outboundCallRequestID: String?
        }

        enum RecordingState {
            case open(BridgeRequestSummaryTracer)
            case closed(endTimeNanos: UInt64)
        }

        let startTimeNanos: UInt64
        let kind: Tracing.SpanKind
        let spanID: UInt64
        let parentSpanID: UInt64
        let traceID: UUID
        let requestID: String

        private let storage: Mutex<Storage>
        private let logger: Logger?

        init(
            operationName: String,
            kind: Tracing.SpanKind,
            startTimeNanos: UInt64,
            spanID: UInt64,
            parentSpanID: UInt64,
            traceID: UUID,
            requestID: String,
            context: ServiceContext,
            tracer: BridgeRequestSummaryTracer,
            logger: Logger?
        ) {
            self.startTimeNanos = startTimeNanos
            self.kind = kind
            self.spanID = spanID
            self.parentSpanID = parentSpanID
            self.traceID = traceID
            self.requestID = requestID
            self.storage = .init(Storage(
                recordingState: .open(tracer),
                context: context,
                events: [],
                status: nil,
                errors: [],
                attributes: .init(),
                links: [],
                operationName: operationName
            ))
            self.logger = logger
        }

        deinit {
            storage.withLock { storage in
                if case .open = storage.recordingState {
                    self.logger?.fault(
                        "[spanID: \(self.spanID.hexEncoded, privacy: .public)] Reference to unended bridge span dropped"
                    )
                }
            }
        }

        public var isRecording: Bool {
            self.storage.withLock {
                if case .open = $0.recordingState { true } else { false }
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

        var status: Tracing.SpanStatus? {
            self.storage.withLock { $0.status }
        }

        var errors: [any Error] {
            self.storage.withLock { $0.errors }
        }

        var events: [Tracing.SpanEvent] {
            self.storage.withLock { $0.events }
        }

        var endTimeNanos: UInt64 {
            self.storage.withLock { storage in
                guard case .closed(let endTime) = storage.recordingState else {
                    self.logger?.fault(
                        "[spanID: \(self.spanID.hexEncoded, privacy: .public)] endTimeNanos queried on open span"
                    )
                    return 0
                }
                return endTime
            }
        }

        var outboundCallRequestID: String? {
            get { self.storage.withLock { $0.outboundCallRequestID } }
            set { self.storage.withLock { $0.outboundCallRequestID = newValue } }
        }

        public func end(at instant: @autoclosure () -> some TracerInstant) {
            let endTimeNanos = instant().nanosecondsSinceEpoch
            let tracer = self.storage.withLock { storage -> BridgeRequestSummaryTracer? in
                switch storage.recordingState {
                case .open(let tracer):
                    storage.recordingState = .closed(endTimeNanos: endTimeNanos)
                    return tracer
                case .closed:
                    self.logger?.fault(
                        "[spanID: \(self.spanID.hexEncoded, privacy: .public)] Bridge span already closed"
                    )
                    return nil
                }
            }
            tracer?.closeSpan(self)
        }
    }
}

// MARK: - RequestSummary

struct BridgeServerRequestSummary: RequestSummary {
    let operationName: String
    let type = "RequestSummary"
    let serviceName = "cb_bridged"
    let namespace = "cloudboard"
    let requestID: String?
    let spanID: UInt64
    let parentSpanID: UInt64
    let traceID: UUID
    let outboundCallRequestID: String?
    var startTimeNanos: Int64?
    var endTimeNanos: Int64?
    var error: Error?
    var automatedDeviceGroup: String?

    init(from span: BridgeRequestSummaryTracer.Span) {
        self.operationName = span.operationName
        self.requestID = span.requestID
        self.spanID = span.spanID
        self.parentSpanID = span.parentSpanID
        self.traceID = span.traceID
        self.startTimeNanos = Int64(span.startTimeNanos)
        self.endTimeNanos = Int64(span.endTimeNanos)
        self.error = span.errors.first
        self.outboundCallRequestID = span.outboundCallRequestID
    }

    func log(to logger: Logger) {
        logger.log("""
        ttl=RequestSummary
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.trace_id=\(self.traceID.traceIDString, privacy: .public)
        tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
        tracing.parent_span_id=\(self.parentSpanID.hexEncoded, privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        request.duration_ms=\(self.durationMicros.map { String($0 / 1000) } ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(self.status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        outbound_call.request_id=\(self.outboundCallRequestID ?? "", privacy: .public)
        """)
    }
}
