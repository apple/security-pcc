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

internal import CloudBoardCommon
internal import CloudBoardLogging

import CloudBoardDomain
import Foundation
import os

public struct PrivateInformationRetrievalRequest: Sendable {
    /// Serialized request message
    public let payload: Data

    public init(payload: Data) {
        self.payload = payload
    }
}

public struct PrivateInformationRetrievalResponse: Sendable {
    /// Serialized response message
    public let payload: Data
}

public final class PrivateInformationRetrievalClient: Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PrivateInformationRetrievalClient"
    )

    private static let tracingLogger = Logger(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "PrivateInformationRetrievalClient"
    )

    private let jobHelperMessenger: JobHelperMessengerProtocol
    private let pccServerRequestID: String
    private let traceID: UUID
    private let defaultParentSpanID: UInt64

    internal init(
        jobHelperMessenger: JobHelperMessengerProtocol,
        pccServerRequestID: String,
        traceID: UUID,
        defaultParentSpanID: UInt64
    ) {
        self.jobHelperMessenger = jobHelperMessenger
        self.pccServerRequestID = pccServerRequestID
        self.traceID = traceID
        self.defaultParentSpanID = defaultParentSpanID
    }

    /// Makes a Private Information Retrieval (PIR) request.
    ///
    /// - Parameters:
    ///   - request: The Private Information Retrieval (PIR) request.
    ///   - purpose: The purpose of this PIR request.
    ///   - parentSpanID: ID of the span to be considered as the parent of the PIR span.
    /// - Returns: The Private Information Retrieval (PIR) response.
    public func makeRequest(
        _ request: PrivateInformationRetrievalRequest,
        purpose: String,
        parentSpanID: UInt64? = nil
    ) async throws -> PrivateInformationRetrievalResponse {
        let pirSpanID = TraceContextCache.singletonCache.generateNewSpanID()
        let pirRequestID = UUID().uuidString
        let requestSummary = PrivateInformationRetrievalRequestSummaryProvisioner(
            pccServerRequestID: self.pccServerRequestID,
            pirRequestID: pirRequestID,
            traceID: self.traceID,
            spanID: pirSpanID,
            parentSpanID: parentSpanID ?? self.defaultParentSpanID
        )

        PrivateInformationRetrievalClientCheckpoint(
            pccServerRequestID: self.pccServerRequestID,
            traceID: self.traceID,
            spanID: pirSpanID,
            message: "Starting PIR request",
            pirRequestID: pirRequestID
        ).log(to: Self.tracingLogger, level: .default)

        let response: PrivateInformationRetrievalResponse
        do {
            response = try await self.jobHelperMessenger.makePIRRequest(
                request,
                purpose: purpose,
                traceContext: .init(
                    pccServerRequestID: self.pccServerRequestID,
                    pirRequestID: pirRequestID,
                    traceID: self.traceID,
                    spanID: pirSpanID
                )
            )
        } catch {
            await requestSummary.populate(error: error)
            await requestSummary.log(to: Self.tracingLogger)
            throw error
        }
        await requestSummary.log(to: Self.tracingLogger)
        return response
    }
}

struct PrivateInformationRetrievalClientCheckpoint: RequestCheckpoint {
    let requestID: String?
    let traceID: UUID
    let spanID: UInt64?
    let operationName: StaticString
    // RequestCheckpoint requires serviceName to be a static string but we can only
    // determine the cloud app's process name dynamically
    let serviceName: StaticString = "unused"
    var cloudAppServiceName: String {
        DebugContext.appName ??
            ProcessInfo.processInfo.processName
    }

    let namespace: StaticString = "cloudboard"
    var error: Error?
    let message: StaticString

    let pirRequestID: String

    init(
        pccServerRequestID: String,
        traceID: UUID,
        spanID: UInt64?,
        operationName: StaticString = #function,
        message: StaticString,
        error: Error? = nil,
        pirRequestID: String,
    ) {
        self.requestID = pccServerRequestID
        self.traceID = traceID
        self.spanID = spanID
        self.operationName = operationName
        self.message = message
        self.error = error
        self.pirRequestID = pirRequestID
    }

    func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID!, privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.trace_id=\(self.traceID.traceIDString, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.cloudAppServiceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        pir.request.uuid=\(self.pirRequestID, privacy: .public)
        """)
    }
}

struct PrivateInformationRetrievalRequestSummary: RequestSummary {
    var serviceName: String {
        DebugContext.appName ?? ProcessInfo.processInfo.processName
    }

    let requestID: String?
    let traceID: UUID
    let spanID: UInt64?
    let parentSpanID: UInt64?
    let automatedDeviceGroup: String? = nil // No automated device group for PIR calls

    var startTimeNanos: Int64?
    var endTimeNanos: Int64?

    let operationName = "PrivateInformationRetrieval"
    let type = "RequestSummary"
    let namespace = "cloudboard"

    var error: Error?

    let pirRequestID: String

    init(
        pccServerRequestID: String,
        pirRequestID: String,
        traceID: UUID,
        spanID: UInt64? = nil,
        parentSpanID: UInt64? = nil
    ) {
        self.requestID = pccServerRequestID
        self.pirRequestID = pirRequestID
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }

    func log(to logger: Logger) {
        logger.log("""
        ttl=RequestSummary
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.trace_id=\(self.traceID.traceIDString, privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.parent_span_id=\(self.parentSpanID?.hexEncoded ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        request.duration_ms=\(self.durationMicros.map { String($0 / 1000) } ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { "\(String(reportable: $0))" } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        pir.request.uuid=\(self.pirRequestID, privacy: .public)
        """)
    }
}

actor PrivateInformationRetrievalRequestSummaryProvisioner {
    var requestSummary: PrivateInformationRetrievalRequestSummary

    init(
        pccServerRequestID: String,
        pirRequestID: String,
        traceID: UUID,
        spanID: UInt64? = nil,
        parentSpanID: UInt64? = nil
    ) {
        self.requestSummary = .init(
            pccServerRequestID: pccServerRequestID,
            pirRequestID: pirRequestID,
            traceID: traceID,
            spanID: spanID,
            parentSpanID: parentSpanID
        )
        self.requestSummary.startTimeNanos = RequestSummaryClock.now
    }

    func populate(error: Error) {
        self.requestSummary.populate(error: error)
    }

    func log(to logger: Logger) {
        self.requestSummary.endTimeNanos = RequestSummaryClock.now
        self.requestSummary.log(to: logger)
    }
}
