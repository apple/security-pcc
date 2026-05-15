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

import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import os
import Tracing

struct CloudBoardJobHelperRequestSummary: RequestSummary {
    var operationName: String = "cb_jobhelper response summary"
    var type: String = "RequestSummary"
    var serviceName: String = "cb_jobhelper"
    var namespace: String = "cloudboard"
    var requestPlaintextMetadata: ParametersData.PlaintextMetadata?
    var jobUUID: String?
    var remotePID: Int?
    var requestMessageCount: Int = 0
    var responseMessageCount: Int = 0
    var requestFinalChunkSeen: Bool = false
    var responseFinalChunkSeen: Bool = false
    var error: Error?
    var startTimeNanos: Int64?
    var endTimeNanos: Int64?
    var automatedDeviceGroup: String?
    var requestWorkload: String?
    var requestBundleID: String?
    var requestFeatureID: String?
    var receivedSetup: Bool = false
    var receivedParameters: Bool = false
    var requestID: String?
    var spanID: UInt64?
    var parentSpanID: UInt64?
    var isNack: Bool = false
    var requestExecutionError: [RequestExecutionSpanError] = []

    init() {}

    mutating func populateRequestMetadata(_ requestMetadata: ParametersData.PlaintextMetadata) {
        self.requestPlaintextMetadata = requestMetadata
    }

    /// NOTE: This value will be logged as public and therefore must not contain public information
    public func log(to logger: Logger) {
        logger.log("""
        ttl=\(self.type, privacy: .public)
        jobID=\(self.jobUUID ?? "UNKNOWN", privacy: .public)
        remotePid=\(self.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        client.feature_id=\(self.requestFeatureID ?? "", privacy: .public)
        client.bundle_id=\(self.requestBundleID ?? "", privacy: .public)
        client.automated_device_group=\(self.automatedDeviceGroup ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.parent_span_id=\(self.parentSpanID?.hexEncoded ?? "", privacy: .public)
        tracing.start_time_unix_nano=\(self.startTimeNanos ?? 0, privacy: .public)
        tracing.end_time_unix_nano=\(self.endTimeNanos ?? 0, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        durationMicros=\(self.durationMicros ?? 0, privacy: .public)
        tracing.status=\(self.status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        requestMessageCount=\(self.requestMessageCount, privacy: .public)
        responseMessageCount=\(self.responseMessageCount, privacy: .public)
        requestExecutionError=\(self.requestExecutionError, privacy: .public)
        """)
    }

    mutating func populate(invokeWorkloadSpan: RequestSummaryJobHelperTracer.Span?) {
        if let span = invokeWorkloadSpan {
            if self.isNack {
                self.operationName = OperationNames.nackRequest
            } else {
                self.operationName = span.operationName
            }
            self.spanID = span.attributes.requestSummary.pipelinePayloadRequestAttributes.spanID
            self.parentSpanID = span.attributes.requestSummary.pipelinePayloadRequestAttributes.parentSpanID
            self.jobUUID = span.attributes.requestSummary.pipelinePayloadRequestAttributes.jobUUID
            self.remotePID = span.attributes.requestSummary.pipelinePayloadRequestAttributes.remotePID

            self.startTimeNanos = Int64(span.startTimeNanos)
            self.endTimeNanos = Int64(span.endTimeNanos)

            if let error = span.errors.first {
                self.populate(error: error)
            }
        }
    }

    mutating func populate(invokeWorkloadRequestSpans: [RequestSummaryJobHelperTracer.Span]) {
        var invokeWorkloadRequestFinalChunkSeen = false
        var receivedSetup = false
        var receivedParameters = false

        for span in invokeWorkloadRequestSpans {
            self.isNack = span.attributes.requestSummary.pipelinePayloadRequestAttributes.isNack ?? false
            if span.attributes.requestSummary.pipelinePayloadRequestAttributes.isFinal ?? false {
                invokeWorkloadRequestFinalChunkSeen = true
            }
            if span.attributes.requestSummary.pipelinePayloadRequestAttributes.receivedSetup ?? false {
                receivedSetup = true
            }
            if span.attributes.requestSummary.pipelinePayloadRequestAttributes.receivedParameters ?? false {
                receivedParameters = true
            }
            if let workload = span.attributes.requestSummary.pipelinePayloadRequestAttributes.workload {
                self.requestWorkload = workload
            }
            if let featureID = span.attributes.requestSummary.pipelinePayloadRequestAttributes.featureID {
                self.requestFeatureID = featureID
            }
            if let bundleID = span.attributes.requestSummary.pipelinePayloadRequestAttributes.bundleID {
                self.requestBundleID = bundleID
            }
            if let requestID = span.attributes.requestSummary.pipelinePayloadRequestAttributes.requestID {
                self.requestID = requestID
            }
            if let remotePID = span.attributes.requestSummary.pipelinePayloadRequestAttributes.remotePID {
                self.remotePID = remotePID
            }
            if let automatedDeviceGroup = span.attributes.requestSummary.pipelinePayloadRequestAttributes
                .automatedDeviceGroup {
                self.automatedDeviceGroup = automatedDeviceGroup
            }
            if let requestMessageCount = span.attributes.requestSummary.pipelinePayloadRequestAttributes
                .requestMessageCount {
                self.requestMessageCount = requestMessageCount
            }
            if let error = span.errors.first {
                self.populate(error: error)
            }
        }

        self.requestFinalChunkSeen = invokeWorkloadRequestFinalChunkSeen
        self.receivedSetup = receivedSetup
        self.receivedParameters = receivedParameters
    }

    mutating func populate(invokeWorkloadResponseSpans: [RequestSummaryJobHelperTracer.Span]) {
        // There should be only one
        let span = invokeWorkloadResponseSpans.first
        self.responseMessageCount = span?.attributes.requestSummary.responseChunkAttributes
            .responseMessagesCount ?? 0
        self.responseFinalChunkSeen = span?.attributes.requestSummary.responseChunkAttributes.isFinal ?? false
        self.requestExecutionError = span?.attributes.requestSummary.requestExecutionErrorAttributes.errors ?? []
        if let error = span?.errors.first {
            self.populate(error: error)
        }
    }

    func measure(to metrics: any MetricsSystem) {
        let automatedDeviceGroupDimension = !(
            self.requestPlaintextMetadata?.automatedDeviceGroup
                .isEmpty ?? true
        )
        let featureID = self.requestPlaintextMetadata?.featureID
        let bundleID = self.requestPlaintextMetadata?.bundleID
        let inferenceID = self.requestPlaintextMetadata?.workloadParameters[workloadParameterInferenceIDKey]?.first
        if self.requestMessageCount > 0 {
            if self.responseMessageCount > 0 {
                metrics.emit(Metrics.WorkloadManager.TotalResponsesSentCounter(
                    action: .increment,
                    automatedDeviceGroup: automatedDeviceGroupDimension,
                    featureId: featureID,
                    bundleId: bundleID,
                    inferenceId: inferenceID
                ))
                if let error = self.error {
                    metrics.emit(Metrics.WorkloadManager.FailureResponsesSentCounter(
                        action: .increment,
                        automatedDeviceGroup: automatedDeviceGroupDimension,
                        error: error,
                        featureId: featureID,
                        bundleId: bundleID,
                        inferenceId: inferenceID
                    ))

                    if let durationMicros = self.durationMicros {
                        metrics.emit(
                            Metrics.WorkloadManager.WorkloadDurationFromFirstRequestMessage(
                                duration: .microseconds(durationMicros),
                                error: error,
                                automatedDeviceGroup: automatedDeviceGroupDimension
                            )
                        )
                    } else {
                        RequestSummaryJobHelperTracer.logger.fault("""
                        WorkloadManagerRequestSummary duration could not be determined. Top-level span likely not closed correctly.
                        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
                        requestId=\(self.requestID ?? "", privacy: .public)
                        """)
                    }
                } else {
                    metrics.emit(Metrics.WorkloadManager.SuccessResponsesSentCounter(
                        action: .increment,
                        automatedDeviceGroup: automatedDeviceGroupDimension,
                        featureId: featureID,
                        bundleId: bundleID,
                        inferenceId: inferenceID
                    ))
                    if let durationMicros = self.durationMicros {
                        metrics.emit(
                            Metrics.WorkloadManager.WorkloadDurationFromFirstRequestMessage(
                                duration: .microseconds(durationMicros),
                                error: nil,
                                automatedDeviceGroup: automatedDeviceGroupDimension
                            )
                        )
                    } else {
                        RequestSummaryJobHelperTracer.logger.fault("""
                        WorkloadManagerRequestSummary duration could not be determined. Top-level span likely not closed correctly.
                        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
                        requestId=\(self.requestID ?? "", privacy: .public)
                        """)
                    }
                }
            } else { // no response sent, but an error recorded
                if let error = self.error {
                    metrics.emit(Metrics.WorkloadManager.OverallErrorCounter.Factory().make(error))
                } else {
                    let error = WorkloadJobManagerNoResponseSentError()
                    metrics.emit(Metrics.WorkloadManager.OverallErrorCounter.Factory().make(error))
                }
            }
        } else {
            metrics.emit(Metrics.WorkloadManager.UnusedTerminationCounter(action: .increment))
        }
    }
}

struct WorkloadJobManagerCheckpoint: RequestCheckpoint {
    var requestID: String? {
        self.logMetadata.requestTrackingID
    }

    var spanID: UInt64? {
        self.logMetadata.spanID
    }

    let operationName: StaticString
    let serviceName: StaticString = "cb_jobhelper"
    let namespace: StaticString = "cloudboard"

    var logMetadata: CloudBoardJobHelperLogMetadata
    var requestMessageCount: Int
    var responseMessageCount: Int
    var message: StaticString
    var error: Error?

    init(
        logMetadata: CloudBoardJobHelperLogMetadata,
        requestMessageCount: Int = 0,
        responseMessageCount: Int = 0,
        message: StaticString,
        operationName: StaticString = #function,
        error: Error? = nil
    ) {
        self.logMetadata = logMetadata
        self.requestMessageCount = requestMessageCount
        self.responseMessageCount = responseMessageCount
        self.message = message
        self.operationName = operationName
        if let error {
            self.error = error
        }
    }

    func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        requestMessageCount=\(self.requestMessageCount, privacy: .public)
        responseMessageCount=\(self.responseMessageCount, privacy: .public)
        """)
    }

    func log(to logger: Logger, keyID: Data?, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        requestMessageCount=\(self.requestMessageCount, privacy: .public)
        responseMessageCount=\(self.responseMessageCount, privacy: .public)
        keyID=\(keyID?.base64EncodedString() ?? "", privacy: .public)
        """)
    }

    func log(workerID: UUID, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        requestMessageCount=\(self.requestMessageCount, privacy: .public)
        responseMessageCount=\(self.responseMessageCount, privacy: .public)
        worker.uuid=\(workerID, privacy: .public)
        """)
    }

    func log(workerID: UUID, pccResponseStatus: Int, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        requestMessageCount=\(self.requestMessageCount, privacy: .public)
        responseMessageCount=\(self.responseMessageCount, privacy: .public)
        worker.uuid=\(workerID, privacy: .public)
        worker.pccResponseStatus=\(pccResponseStatus, privacy: .public)
        """)
    }

    func log(
        workerID: UUID,
        grpcStatus: Int,
        grpcMessage: String?,
        ropesErrorCode: UInt32?,
        ropesMessage: String?,
        to logger: Logger,
        level: OSLogType = .default
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        requestMessageCount=\(self.requestMessageCount, privacy: .public)
        responseMessageCount=\(self.responseMessageCount, privacy: .public)
        worker.uuid=\(workerID, privacy: .public)
        worker.grpcStatus=\(grpcStatus, privacy: .public)
        worker.grpcMessage=\(grpcMessage ?? "", privacy: .public)
        worker.ropesErrorCode=\(ropesErrorCode ?? 0, privacy: .public)
        worker.ropesMessage=\(ropesMessage ?? "", privacy: .public)
        """)
    }

    func log(
        workerID: UUID,
        serviceName: String,
        routingParameters: [String: [String]],
        groupID: String?,
        to logger: Logger,
        level: OSLogType = .default
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        requestMessageCount=\(self.requestMessageCount, privacy: .public)
        responseMessageCount=\(self.responseMessageCount, privacy: .public)
        worker.uuid=\(workerID, privacy: .public)
        worker.serviceName=\(serviceName, privacy: .public)
        worker.routingParameters=\(routingParameters, privacy: .public)
        worker.groupID=\(groupID ?? "", privacy: .public)
        """)
    }

    func log(
        requestExecutionError: RequestExecutionError?,
        to logger: Logger,
        level: OSLogType = .default
    ) {
        if let requestExecutionError {
            logger.log(level: level, """
            ttl=\(self.type, privacy: .public)
            jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
            remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
            request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
            tracing.name=\(self.operationName, privacy: .public)
            tracing.type=\(self.type, privacy: .public)
            tracing.trace_id=\(
                self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "",
                privacy: .public
            )
            tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
            service.name=\(self.serviceName, privacy: .public)
            service.namespace=\(self.namespace, privacy: .public)
            tracing.status=\(status?.rawValue ?? "", privacy: .public)
            error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
            error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
            message=\(self.message, privacy: .public)
            requestMessageCount=\(self.requestMessageCount, privacy: .public)
            responseMessageCount=\(self.responseMessageCount, privacy: .public)
            requestExecutionError.errorSource=\(requestExecutionError.errorSource, privacy: .public)
            requestExecutionError.errorMessage=\(requestExecutionError.errorMessage, privacy: .public)
            requestExecutionError.errorCode=\(requestExecutionError.errorCode, privacy: .public)
            """)
        } else {
            self.log(to: logger, level: level)
        }
    }

    func log(
        subrequestID: UInt32,
        subresponseStatus: InternalSubresponseStatus,
        duration: Duration,
        to logger: Logger,
        level: OSLogType = .default
    ) {
        switch subresponseStatus {
        case .error(let requestExecutionError):
            logger.log(level: level, """
            ttl=\(self.type, privacy: .public)
            jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
            remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
            request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
            tracing.name=\(self.operationName, privacy: .public)
            tracing.type=\(self.type, privacy: .public)
            tracing.trace_id=\(
                self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "",
                privacy: .public
            )
            tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
            service.name=\(self.serviceName, privacy: .public)
            service.namespace=\(self.namespace, privacy: .public)
            tracing.status=\(status?.rawValue ?? "", privacy: .public)
            error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
            error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
            message=\(self.message, privacy: .public)
            requestMessageCount=\(self.requestMessageCount, privacy: .public)
            responseMessageCount=\(self.responseMessageCount, privacy: .public)
            subrequest.id=\(subrequestID, privacy: .public)
            subrequest.duration_ms=\(Int(duration.milliseconds), privacy: .public)
            subrequest.status=\("error", privacy: .public)
            subrequest.requestExecutionError.errorSource=\(requestExecutionError.errorSource, privacy: .public)
            subrequest.requestExecutionError.errorMessage=\(requestExecutionError.errorMessage, privacy: .public)
            subrequest.requestExecutionError.errorCode=\(requestExecutionError.errorCode, privacy: .public)
            """)
        case .ok, .discarded:
            logger.log(level: level, """
            ttl=\(self.type, privacy: .public)
            jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
            remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
            request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
            tracing.name=\(self.operationName, privacy: .public)
            tracing.type=\(self.type, privacy: .public)
            tracing.trace_id=\(
                self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "",
                privacy: .public
            )
            tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
            service.name=\(self.serviceName, privacy: .public)
            service.namespace=\(self.namespace, privacy: .public)
            tracing.status=\(status?.rawValue ?? "", privacy: .public)
            error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
            error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
            message=\(self.message, privacy: .public)
            requestMessageCount=\(self.requestMessageCount, privacy: .public)
            responseMessageCount=\(self.responseMessageCount, privacy: .public)
            subrequest.id=\(subrequestID, privacy: .public)
            subrequest.duration_ms=\(Int(duration.milliseconds), privacy: .public)
            subrequest.status=\(subresponseStatus.description, privacy: .public)
            """)
        }
    }

    func log(to logger: Logger, subrequestID: UInt32, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        subrequest.id=\(subrequestID, privacy: .public)
        """)
    }

    func log(to logger: Logger, subrequestID: UInt32, cryptoMaterialCount: Int, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        subrequest.id=\(subrequestID, privacy: .public)
        cryptoMaterialCount=\(cryptoMaterialCount, privacy: .public)
        """)
    }

    func log(to logger: Logger, supportAppPID: Int?, cryptoMaterialHandle: UUID, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        supportapp.pid=\(supportAppPID.map { "\($0)" } ?? "", privacy: .public)
        cryptoMaterialHandle=\(cryptoMaterialHandle.uuidString, privacy: .public)
        """)
    }
}

extension WorkloadJobManagerCheckpoint {
    public func logAppTermination(
        terminationMetadata: TerminationMetadata,
        to logger: Logger,
        level: OSLogType
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        requestMessageCount=\(self.requestMessageCount, privacy: .public)
        responseMessageCount=\(self.responseMessageCount, privacy: .public)
        terminationStatusCode=\(terminationMetadata.statusCode.map { String(describing: $0) } ?? "", privacy: .public)
        """)
    }
}

extension PipelinePayload {
    /// This is a public description of the payload to be included in logs and metrics and must not include any
    /// sensitive data
    public var publicDescription: String {
        switch self {
        case .chunk(let finalizable) where finalizable.isFinal: return "chunk:final"
        case .chunk: return "chunk"
        case .endOfInput: return "endOfInput"
        case .oneTimeToken: return "oneTimeToken"
        case .parameters: return "parameters"
        case .abandon: return "abandon"
        case .teardown: return "teardown"
        case .warmup: return "warmup"
        case .nackAndExit: return "nackAndExit"
        case .parametersMetaData: return "parametersMetaData"
        case .workerNegotiatePick(providedByRopes: let providedByRopes):
            // it's all from ROPES or metadata keys, so fine to print in full
            return "workerNegotiatePick \(providedByRopes)"
        case .workerFound: return "workerFound"
        case .selectedWorker: return "workerAttestationAndDEK"
        case .workerResponseChunk: return "workerResponseChunk"
        case .workerResponseSummary: return "workerResponseSummary"
        case .workerResponseClose: return "workerResponseClose"
        case .workerResponseEOF: return "workerResponseEOF"
        case .openClientSubrequest: return "openClientSubrequest"
        case .subrequestPayload: return "subrequestPayload"
        case .closeSubrequest: return "closeSubrequest"
        case .cancelSubrequest: return "cancelSubrequest"
        case .applicationDataChunkingConfig: return "applicationDataChunkingConfig"
        case .readyToSendAssetsMetadataRELEntry: return "readyToSendAssetsMetadataRELEntry"
        }
    }
}

extension PipelinePayload: CustomStringConvertible {
    /// This is a non-public description and must not be logged publicly
    internal var description: String {
        switch self {
        case .chunk(let encodedRequestChunk): return "chunk bytes \(encodedRequestChunk.chunk.count)"
        case .endOfInput: return "endOfInput"
        case .oneTimeToken: return "oneTimeToken"
        case .parameters(let parameters): return "parameters \(parameters.plaintextMetadata)"
        case .abandon: return "abandon"
        case .teardown: return "teardown"
        case .warmup(let warmup): return "warmup \(warmup)"
        case .nackAndExit: return "nackAndExit"
        case .parametersMetaData(let keyID, _): return "parametersMetaData \(keyID)"
        case .workerFound(let workerID, let releaseDigest, _):
            return "workerFound (worker: \(workerID), releaseDigest: \(releaseDigest))"
        case .selectedWorker(let info, _, let workloadParameters):
            return "workerAttestation (worker: \(info.workerID), keyID: \(info.keyID), workloadParameters: \(workloadParameters.description)"
        case .workerResponseChunk(let workerID, _): return "workerResponsePayload (worker: \(workerID))"
        case .workerResponseSummary(let workerID, _): return "workerResponseSummary (worker: \(workerID))"
        case .workerResponseClose(let workerID, let grpcCode, _, let ropesErrorCode, _):
            return "workerResponseClose (worker: \(workerID), grpcCode: \(grpcCode), ropesErrorCode: \(ropesErrorCode.map { "\($0)" } ?? "nil"))"
        case .workerResponseEOF(let workerID): return "workerResponseEOF (worker: \(workerID))"
        case .openClientSubrequest(
            let subrequestID,
            let cryptoMaterialsHandle,
            let isDiscardable
        ): return "openClientSubrequest (subrequestID: \(subrequestID), cryptoMaterialsHandle: \(cryptoMaterialsHandle), isDiscardable: \(isDiscardable))"
        case .subrequestPayload(
            let clientSubrequestId,
            let chunk
        ): return "subrequestPayload (clientSubrequestId: \(clientSubrequestId), chunk: \(chunk.count))"
        case .closeSubrequest(let clientSubrequestId): return "closeSubrequest (clientSubrequestId: \(clientSubrequestId))"
        case .cancelSubrequest(let clientSubrequestId): return "cancelSubrequest (clientSubrequestId: \(clientSubrequestId))"
        case .workerNegotiatePick(providedByRopes: let providedByRopes):
            return "workerNegotiatePick \(providedByRopes)"
        case .applicationDataChunkingConfig(let config): return "applicationDataChunkingConfig (config: \(config))"
        case .readyToSendAssetsMetadataRELEntry: return "readyToSendAssetsMetadataRELEntry"
        }
    }
}

extension WorkloadJobManagerCheckpoint {
    /// Log sanitised information about messages coming down the receive request pipeline
    public func logReceiveRequestPipelineMessage(
        pipelineMessage: PipelinePayload,
        to logger: Logger,
        level: OSLogType
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        remotePid=\(self.logMetadata.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        requestMessageCount=\(self.requestMessageCount, privacy: .public)
        responseMessageCount=\(self.responseMessageCount, privacy: .public)
        pipelineMessage=\(pipelineMessage.publicDescription, privacy: .public)
        pipelineMessageDetailed=\(pipelineMessage)
        """)
    }
}

struct WorkloadJobStateMachineCheckpoint: RequestCheckpoint {
    var requestID: String? {
        self.logMetadata.requestTrackingID
    }

    var operationName: StaticString
    let serviceName: StaticString = "cb_jobhelper"
    let namespace: StaticString = "cloudboard"

    var error: Error?

    var logMetadata: CloudBoardJobHelperLogMetadata
    var state: WorkloadJobStateMachine.State
    var newState: WorkloadJobStateMachine.State?

    public init(
        logMetadata: CloudBoardJobHelperLogMetadata,
        state: WorkloadJobStateMachine.State,
        operation: StaticString
    ) {
        self.logMetadata = logMetadata
        self.state = state
        self.operationName = operation
    }

    public func loggingStateChange<Result>(
        to logger: Logger,
        level: OSLogType,
        _ body: () throws -> (Result, WorkloadJobStateMachine.State)
    ) rethrows -> Result {
        do {
            let (result, newState) = try body()
            var checkpoint = self
            checkpoint.newState = newState
            checkpoint.log(to: logger, level: level)
            return result
        } catch {
            var checkpoint = self
            checkpoint.error = error
            checkpoint.log(to: logger, level: level)
            throw error
        }
    }

    func log(to logger: Logger, level: OSLogType) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        state=\(self.state.publicDescription, privacy: .public)
        newState=\(self.newState?.publicDescription ?? "", privacy: .public)
        """)
    }
}

extension WorkloadJobStateMachine.State {
    public var publicDescription: StaticString {
        switch self {
        case .awaitingOneTimeToken: "awaitingOneTimeToken"
        case .awaitingTokenGrantingToken: "awaitingTokenGrantingToken"
        case .validatedTokenGrantingToken: "validatedTokenGrantingToken"
        case .abandoning: "abandoning"
        case .terminated: "terminated"
        }
    }
}

struct CloudboardJobHelperCheckpoint: RequestCheckpoint {
    var requestID: String? {
        self.logMetadata.requestTrackingID
    }

    let operationName: StaticString
    let serviceName: StaticString = "cb_jobhelper"
    let namespace: StaticString = "cloudboard"

    var logMetadata: CloudBoardJobHelperLogMetadata
    var message: StaticString
    var error: Error?

    var durationMicros: Int64?

    public init(
        logMetadata: CloudBoardJobHelperLogMetadata,
        message: StaticString,
        operationName: StaticString = #function,
        error: Error? = nil
    ) {
        self.logMetadata = logMetadata
        self.message = message
        self.operationName = operationName
        if let error {
            self.error = error
        }
    }

    public func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        """)
    }

    public func log(forCloudApp cloudApp: String, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        cloudApp=\(cloudApp, privacy: .public)
        message=\(self.message, privacy: .public)
        """)
    }

    public func log(
        forCloudApp cloudApp: String,
        forSupportApp supportApp: String,
        to logger: Logger,
        level: OSLogType = .default
    ) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.logMetadata.jobID?.uuidString ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        tracing.span_id=\(self.logMetadata.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.trace_id=\(self.requestID?.replacingOccurrences(of: "-", with: "").lowercased() ?? "", privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        tracing.status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        cloudApp=\(cloudApp, privacy: .public)
        supportApp=\(supportApp, privacy: .public)
        message=\(self.message, privacy: .public)
        """)
    }
}
