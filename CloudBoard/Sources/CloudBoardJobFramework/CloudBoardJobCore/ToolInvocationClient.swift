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
internal import Synchronization

import CloudBoardDomain
import Foundation
import os

/// Supported argument types for tool invocation
public enum ToolInvocationArgumentValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ToolInvocationArgumentValue])
    case map([String: ToolInvocationArgumentValue])
}

/// Content within a tool response
public enum ToolInvocationResponseContent: Sendable, Equatable, Hashable, Encodable {
    /// Text content
    case text(String)
    /// Image content
    case image(data: Data, mimeType: String, metadata: [String: String]?)
    /// Audio content
    case audio(data: Data, mimeType: String)
    /// Embedded resource content
    case resource(uri: String, mimeType: String, text: String?)
}

/// Tool invocation response
public struct ToolInvocationResponse: Sendable, Equatable, Hashable, Encodable {
    public var contents: [ToolInvocationResponseContent]
    public var structuredContent: [String: ToolInvocationResponseValue]?

    package init(
        contents: [ToolInvocationResponseContent],
        structuredContent: [String: ToolInvocationResponseValue]? = nil
    ) {
        self.contents = contents
        self.structuredContent = structuredContent
    }
}

public struct ToolInvocationRequest: Sendable, Equatable, Hashable {
    // MCP server id
    public var serverID: String
    // Name of the invoked tool
    public var tool: String
    public var arguments: [String: ToolInvocationArgumentValue]

    public init(
        serverID: String,
        tool: String,
        arguments: [String: ToolInvocationArgumentValue]
    ) {
        self.serverID = serverID
        self.tool = tool
        self.arguments = arguments
    }
}

public struct ToolInvocationRequestConfiguration: Sendable, Equatable, Hashable {
    public var spanID: UInt64?

    public init(spanID: UInt64?) {
        self.spanID = spanID
    }
}

public enum ToolInvocationError: RequestExecutionErrorProtocol, Equatable {
    case rateLimitExceeded
    case protocolError(Int, String)
    case requestFailure(String)

    package var errorSource: RequestExecutionErrorSource {
        return RequestExecutionErrorSource.cloudAppFramework
    }

    public var description: String {
        switch self {
        case .rateLimitExceeded: "rateLimitExceeded"
        case .protocolError(let code, let message): "errorReceivedFromMCPServer code:\(code) message:\(message)"
        case .requestFailure(let message): "requestFailure: \(message)"
        }
    }

    public var staticStringRepresentation: StaticString {
        switch self {
        case .rateLimitExceeded: "rateLimitExceeded"
        case .protocolError: "protocolError"
        case .requestFailure: "requestFailure"
        }
    }

    public var errorCode: UInt32 {
        switch self {
        case .rateLimitExceeded: CloudAppFrameworkErrorCodes.rateLimitExceeded.rawValue
        case .protocolError: CloudAppFrameworkErrorCodes.protocolError.rawValue
        case .requestFailure: CloudAppFrameworkErrorCodes.requestFailure.rawValue
        }
    }
}

public final class ToolInvocationClient: Sendable {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ToolInvocationClient"
    )

    private static let tracingLogger = Logger(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "ToolInvocationClient"
    )

    private let jobHelperMessenger: JobHelperMessengerProtocol
    private let clientRequestMetadata: ParametersData.PlaintextMetadata
    private let _requestCounter = Mutex<Int>(0)
    private let traceID: UUID
    private let defaultParentSpanID: UInt64
    private let maxToolInvocationsPerRequest: Int

    internal init(
        clientRequestMetadata: ParametersData.PlaintextMetadata,
        jobHelperMessenger: JobHelperMessengerProtocol,
        traceID: UUID,
        defaultParentSpanID: UInt64,
        maxToolInvocationsPerRequest: Int
    ) {
        self.clientRequestMetadata = clientRequestMetadata
        self.jobHelperMessenger = jobHelperMessenger
        self.traceID = traceID
        self.defaultParentSpanID = defaultParentSpanID
        self.maxToolInvocationsPerRequest = maxToolInvocationsPerRequest
    }

    private func incrementRequestCounter() -> Int {
        self._requestCounter.withLock {
            $0 += 1
            return $0
        }
    }

    /// Makes a Tool Gateway(eg: Pegasus) request.
    ///
    /// - Parameters:
    ///   - request: Tool invocation request params.
    ///   - configuration: Tool invocation request configuration.
    /// - Returns: Tool invocation response.
    public func makeToolGatewayRequest(
        request: ToolInvocationRequest,
        configuration: ToolInvocationRequestConfiguration
    ) async throws -> ToolInvocationResponse {
        let requestCount = self.incrementRequestCounter()
        if requestCount > self.maxToolInvocationsPerRequest {
            throw ToolInvocationError.rateLimitExceeded
        }
        let toolInvocationRequestId = UUID().uuidString
        let spanID = TraceContextCache.singletonCache.generateNewSpanID()
        let requestSummary = ToolInvocationRequestSummaryProvisioner(
            toolInvocationRequestId: toolInvocationRequestId,
            requestID: self.clientRequestMetadata.requestID,
            traceID: self.traceID,
            spanID: spanID,
            parentSpanID: configuration.spanID ?? self.defaultParentSpanID
        )

        ToolInvocationCheckpoint(
            toolInvocationRequestId: toolInvocationRequestId,
            requestID: self.clientRequestMetadata.requestID,
            traceID: self.traceID,
            spanID: spanID,
            operationName: "tool_gateway_request_started",
            message: "Making tool gateway request",
            request: request
        ).log(to: Self.tracingLogger, level: .default)

        do {
            let toolGatewayResponse = try await self.jobHelperMessenger.makeToolInvocationRequest(
                PCCToolInvocationRequest(
                    serverID: request.serverID,
                    tool: request.tool,
                    arguments: request.arguments.mapValues { .init(from: $0) },
                    traceContext: .init(
                        toolInvocationID: toolInvocationRequestId,
                        serverRequestID: self.clientRequestMetadata.requestID,
                        traceID: self.traceID,
                        spanID: spanID
                    ),
                    clientRequestMetadata: .init(
                        bundleID: self.clientRequestMetadata.bundleID,
                        featureID: self.clientRequestMetadata.featureID,
                        clientInfo: self.clientRequestMetadata.clientInfo,
                        automatedDeviceGroup: self.clientRequestMetadata.automatedDeviceGroup
                    )
                )
            )
            switch toolGatewayResponse {
            case .success(let response):
                var responseContents: [ToolInvocationResponseContent] = []
                for content in response.contents {
                    responseContents.append(ToolInvocationResponseContent(from: content))
                }
                ToolInvocationCheckpoint(
                    toolInvocationRequestId: toolInvocationRequestId,
                    requestID: self.clientRequestMetadata.requestID,
                    traceID: self.traceID,
                    spanID: spanID,
                    operationName: "tool_gateway_request_succeeded",
                    message: "Tool gateway request succeeded",
                    request: request
                ).log(to: Self.tracingLogger, level: .default)
                await requestSummary.log(to: Self.tracingLogger)
                return ToolInvocationResponse(
                    contents: responseContents,
                    structuredContent: response.structuredContent
                )
            case .protocolError(let err):
                let err = ToolInvocationError.protocolError(err.code, err.message)
                ToolInvocationCheckpoint(
                    toolInvocationRequestId: toolInvocationRequestId,
                    requestID: self.clientRequestMetadata.requestID,
                    traceID: self.traceID,
                    spanID: spanID,
                    operationName: "tool_gateway_request_protocol_error",
                    message: "Received protocolError",
                    error: err,
                    request: request
                ).log(to: Self.tracingLogger, level: .error)
                throw err
            case .failure(let message):
                let err = ToolInvocationError.requestFailure(message)
                ToolInvocationCheckpoint(
                    toolInvocationRequestId: toolInvocationRequestId,
                    requestID: self.clientRequestMetadata.requestID,
                    traceID: self.traceID,
                    spanID: spanID,
                    operationName: "tool_gateway_request_failure",
                    message: "Request failure",
                    error: err,
                    request: request
                ).log(to: Self.tracingLogger, level: .error)
                throw err
            }
        } catch {
            await requestSummary.populate(error: error)
            await requestSummary.log(to: Self.tracingLogger)
            throw error
        }
    }
}

struct ToolInvocationCheckpoint: RequestCheckpoint {
    let toolInvocationRequestId: String
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
    let request: ToolInvocationRequest

    init(
        toolInvocationRequestId: String,
        requestID: String?,
        traceID: UUID,
        spanID: UInt64?,
        operationName: StaticString,
        message: StaticString,
        error: Error? = nil,
        request: ToolInvocationRequest,
    ) {
        self.toolInvocationRequestId = toolInvocationRequestId
        self.requestID = requestID
        self.traceID = traceID
        self.spanID = spanID
        self.operationName = operationName
        self.message = message
        self.error = error
        self.request = request
    }

    func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID!, privacy: .public)
        toolInvocationRequestId.uuid=\(self.toolInvocationRequestId, privacy: .public)
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
        request.serverID=\(self.request.serverID, privacy: .public)
        request.tool=\(self.request.tool, privacy: .public)
        """)
    }
}

struct ToolInvocationRequestSummary: RequestSummary {
    var serviceName: String {
        DebugContext.appName ?? ProcessInfo.processInfo.processName
    }

    let operationName = "ToolInvocation"
    let type = "RequestSummary"
    let namespace = "cloudboard"

    let toolInvocationRequestId: String
    let requestID: String?
    let traceID: UUID
    let spanID: UInt64?
    let parentSpanID: UInt64?

    var startTimeNanos: Int64?
    var endTimeNanos: Int64?

    var error: Error?
    var automatedDeviceGroup: String?

    init(
        toolInvocationRequestId: String,
        requestID: String,
        traceID: UUID,
        spanID: UInt64? = nil,
        parentSpanID: UInt64? = nil
    ) {
        self.toolInvocationRequestId = toolInvocationRequestId
        self.requestID = requestID
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }

    func log(to logger: Logger) {
        logger.log("""
        ttl=RequestSummary
        request.uuid=\(self.requestID ?? "UNKNOWN", privacy: .public)
        toolInvocationRequestId.uuid=\(self.toolInvocationRequestId, privacy: .public)
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
        """)
    }
}

actor ToolInvocationRequestSummaryProvisioner {
    var requestSummary: ToolInvocationRequestSummary

    init(
        toolInvocationRequestId: String,
        requestID: String,
        traceID: UUID,
        spanID: UInt64? = nil,
        parentSpanID: UInt64? = nil
    ) {
        self.requestSummary = .init(
            toolInvocationRequestId: toolInvocationRequestId,
            requestID: requestID,
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

extension CloudBoardDomain.PCCToolInvocationArgumentValue {
    init(from: ToolInvocationArgumentValue) {
        self = switch from {
        case .null:
            .null
        case .bool(let value):
            .bool(value)
        case .int(let value):
            .int(value)
        case .double(let value):
            .double(value)
        case .string(let value):
            .string(value)
        case .array(let value):
            .array(value.map { CloudBoardDomain.PCCToolInvocationArgumentValue(from: $0) })
        case .map(let value):
            .map(value.mapValues { CloudBoardDomain.PCCToolInvocationArgumentValue(from: $0) })
        }
    }
}

extension ToolInvocationResponseContent {
    init(from: CloudBoardDomain.PCCToolInvocationResponseContent) {
        self = switch from {
        case .text(let text):
            .text(text)
        case .image(let data, let mimeType, let metadata):
            .image(data: data, mimeType: mimeType, metadata: metadata)
        case .audio(let data, let mimeType):
            .audio(data: data, mimeType: mimeType)
        case .resource(let uri, let mimeType, let text):
            .resource(uri: uri, mimeType: mimeType, text: text)
        }
    }
}
