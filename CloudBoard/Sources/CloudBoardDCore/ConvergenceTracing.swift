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
import CloudBoardLogging
import Foundation
import os
import Tracing

private struct ConvergenceCheckPoint: RequestCheckpoint {
    var requestID: String?

    var operationName: StaticString

    var serviceName: StaticString = "cloudboardd"

    var namespace: StaticString = "cloudboard"

    var error: (any Error)?

    var spanID: UInt64?

    var traceID: String?

    func log(to logger: os.Logger, level _: os.OSLogType) {
        let time = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        logger.log("""
        ttl=\(self.type, privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.traceID ?? "", privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.time_unix_nano=\(time, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        """)
    }
}

private struct ConvergenceRequestSummary: RequestSummary {
    var operationName: String = OperationNames.cloudboardConvergence
    var type: String = "RequestSummary"
    var serviceName: String = "cloudboardd"
    var namespace: String = "cloudboard"
    var spanID: UInt64
    var linkSpanID: String
    var traceID: String
    var linkTraceID: String

    var requestID: String?
    var automatedDeviceGroup: String?
    var startTimeNanos: Int64?
    var endTimeNanos: Int64?
    var error: Error?

    public init(
        span: Span,
        spanID: UInt64,
        linkSpanID: String,
        traceID: String,
        linkTraceID: String
    ) {
        if let span = span as? RequestSummaryTracer.Span {
            self.startTimeNanos = Int64(span.startTimeNanos)
            self.endTimeNanos = Int64(span.endTimeNanos)
        }
        self.spanID = spanID
        self.linkSpanID = linkSpanID
        self.traceID = traceID
        self.linkTraceID = linkTraceID
    }

    public func log(to logger: Logger) {
        logger.log("""
        ttl=\(self.type, privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.traceID, privacy: .public)
        tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
        tracing.parent_span_id=
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        request.duration_ms=\(self.durationMicros.map { String($0 / 1000) } ?? "", privacy: .public)
        service.name=\(String(describing: self.serviceName), privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(self.status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        trace-origin=\(self.linkTraceID, privacy: .public)
        tracing.links=\("[{\"trace_id\":\"\(self.linkTraceID)\",\"span_id\":\"\(self.linkSpanID)\"}]", privacy: .public)
        """)
    }
}

public final class ConvergenceTracing: Sendable {
    fileprivate static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard", category: "ConvergenceTracing"
    )

    let linkSpanID: String
    let linkTraceID: String
    let traceID: String
    let spanID: UInt64
    let tracer: any Tracer

    let requestSummarySpan: OSAllocatedUnfairLock<Span?>

    public init(linkSpanID: String, linkTraceID: String, tracer: any Tracer) {
        self.linkSpanID = linkSpanID
        self.linkTraceID = linkTraceID
        self.spanID = TraceContextCache.singletonCache.generateNewSpanID()
        self.traceID = Self.generateNewTraceID()
        self.tracer = tracer
        self.requestSummarySpan = .init(initialState: nil)
    }

    private static func generateNewTraceID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: ""))
    }

    public func checkpoint(operationName: StaticString) {
        ConvergenceCheckPoint(
            operationName: operationName,
            spanID: self.spanID,
            traceID: self.traceID
        ).log(to: Self.log, level: .default)
    }

    public func startSummary() {
        self.requestSummarySpan.withLock { span in
            if span == nil {
                span = self.tracer.startSpan(OperationNames.cloudboardConvergence)
            } else {
                Self.log.error("Attempted to start convergence span more than once.")
            }
        }
    }

    public func stopSummary(error: (any Error)? = nil) {
        self.requestSummarySpan.withLock { span in
            if let span, span.isRecording {
                span.end()
                var summary = ConvergenceRequestSummary(
                    span: span,
                    spanID: self.spanID,
                    linkSpanID: self.linkSpanID,
                    traceID: self.traceID,
                    linkTraceID: self.linkTraceID
                )
                if let error {
                    summary.populate(error: error)
                }
                summary.log(to: Self.log)
            } else {
                Self.log.error("Attempted to stop convergence span when no span exists/is running.")
            }
        }
    }
}
