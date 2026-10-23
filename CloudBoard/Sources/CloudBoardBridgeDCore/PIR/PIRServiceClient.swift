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

#if RC_IS_CLOUDOS_ENABLED && os(iOS)
import CipherMLSE
#elseif canImport(CipherMLSE)
import CipherMLSE
#else
#warning("CipherMLSE not available at compile time")
#endif
import CloudBoardCommon
internal import CloudBoardDomain
import CloudBoardIdentity
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import GRPCCoreInternal
import GRPCURLSessionTransportInternal
import InternalSwiftProtobuf
import os
import Synchronization

protocol PIRServiceClientProtocol: Sendable {
    func makeEncryptedRequest(
        _ encryptedRequest: PIREncryptedRequest,
        traceContext: PIREncryptedRequestTraceContext
    ) async throws -> PIREncryptedResponse
}

protocol RunnablePIRServiceClientProtocol: PIRServiceClientProtocol {
    func run() async throws
}

final class SharedMutex<T: Sendable>: Sendable {
    let lock: Mutex<T>

    init(_ initialValue: T) {
        self.lock = .init(initialValue)
    }

    @inline(__always)
    func withLock<R: ~Copyable>(body: (inout T) throws -> R) rethrows -> R {
        try self.lock.withLock { obj in
            try body(&obj)
        }
    }
}

#if canImport(CipherMLSE)

// Due to legacy reasons, the PIR protobuf RPC and message names are tied to visual search, even
// though they serve more general PIR purpose.

extension Apple_Parsec_Encryptedvisualsearch_V1_EncryptedVisualSearchRequest {
    init(from request: PIREncryptedRequest) throws {
        try self.init(serializedBytes: request.encryptedData)
    }
}

extension PIREncryptedResponse {
    init(from response: Apple_Parsec_Encryptedvisualsearch_V1_EncryptedVisualSearchResponse) throws {
        try self.init(encryptedData: response.serializedData())
    }
}

final class PIRServiceGRPCClient: RunnablePIRServiceClientProtocol {
    private static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: PIRServiceGRPCClient.self)
    )
    private static let tracingLogger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: String(describing: PIRServiceGRPCClient.self)
    )

    private let keepaliveInterval: Duration?
    private let lastActivityTime: SharedMutex<ContinuousClock.Instant>
    private let grpcClient: GRPCClient<URLSessionTransport>
    private let client: Apple_Parsec_Encryptedvisualsearch_V1_EncryptedVisualSearch.ClientProtocol
    private let attemptCount: Int
    private let retryDelay: Duration
    private let requestTimeout: Duration
    private let metricsSystem: MetricsSystem

    init(
        serverURL: URL,
        kfedService: String?,
        identityManager: IdentityManager?,
        keepaliveInterval: Duration?,
        attemptCount: Int = 1,
        retryDelay: Duration = .milliseconds(100),
        requestTimeout: Duration = .seconds(10),
        metricsSystem: MetricsSystem
    ) {
        let methodConfig = MethodConfig(
            // applies to all methods
            names: [.init(service: "", method: "")],
            maxRequestMessageBytes: .max,
            maxResponseMessageBytes: .max
        )
        let serviceConfig = ServiceConfig(
            methodConfig: [methodConfig],
            loadBalancingConfig: [.roundRobin]
        )

        let urlSession: URLSession
        if let identityManager {
            Self.logger.log("Using URLSession with mTLS")
            let urlSessionConfiguration = URLSessionConfiguration.ephemeral
            urlSession = URLSession(
                configuration: urlSessionConfiguration,
                delegate: IdentityURLSessionDelegate(identityManager: identityManager),
                delegateQueue: nil
            )
        } else {
            Self.logger.log("Using URLSession without mTLS")
            urlSession = URLSession(configuration: .ephemeral)
        }

        let oneMiB = 1024 * 1024
        let transport = URLSessionTransport.urlSession(
            baseURL: serverURL,
            serviceConfig: serviceConfig,
            session: urlSession,
            config: .defaults(configure: { config in
                config.requestBackpressureLowWatermark = 4 * oneMiB
                config.requestBackpressureHighWatermark = 8 * oneMiB
                config.responseBackpressureLowWatermark = 4 * oneMiB
                config.responseBackpressureHighWatermark = 8 * oneMiB
            })
        )

        self.keepaliveInterval = keepaliveInterval
        self.attemptCount = max(1, attemptCount)
        self.retryDelay = retryDelay
        self.requestTimeout = requestTimeout
        self.metricsSystem = metricsSystem
        self.lastActivityTime = .init(.now)
        let interceptors: [ClientInterceptor] = [
            MetadataInjector(kfedService: kfedService),
            ActivityTracker(lastActivityTime: self.lastActivityTime),
        ]
        self.grpcClient = GRPCClient(transport: transport, interceptors: interceptors)
        self.client = Apple_Parsec_Encryptedvisualsearch_V1_EncryptedVisualSearch.Client(wrapping: self.grpcClient)
    }

    func run() async throws {
        Self.logger.log("Running PIRServiceGRPCClient")
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Add the main gRPC client connection task
            group.addTask {
                do {
                    try await self.grpcClient.runConnections()
                } catch {
                    Self.logger
                        .error("GRPC client runConnections failed: \(String(unredacted: error), privacy: .public)")
                    throw error
                }
                // this shouldn't happen since we don't shut down the client.
                Self.logger.error("GRPC client runConnections stopped.")
            }

            // Add keepalive task if configured
            if let keepaliveInterval = self.keepaliveInterval {
                group.addTask {
                    await self.runKeepalive(interval: keepaliveInterval)
                }
            }

            // Wait for first task to complete (or throw)
            // When one task completes/fails, the group will be cancelled
            try await group.next()

            // Cancel all remaining tasks
            group.cancelAll()
        }
    }

    private func runKeepalive(interval: Duration) async {
        Self.logger.info("Starting keepalive with interval: \(interval, privacy: .public)")

        while !Task.isCancelled {
            do {
                // Calculate when the next keep-alive is due
                let nextKeepAliveTime = self.lastActivityTime.withLock { $0 + interval }

                if ContinuousClock.now >= nextKeepAliveTime {
                    // Time to send a keep-alive
                    try await self.sendKeepalive()
                } else {
                    // Not time yet, sleep until it is
                    try await Task.sleep(until: nextKeepAliveTime, clock: .continuous)
                }
            } catch is CancellationError {
                break
            } catch {
                Self.logger.warning("Failed to send keepalive: \(String(unredacted: error), privacy: .public)")
                // manually mark the last activity as now, to avoid frequent keepalivesin a loop
                self.lastActivityTime.withLock { $0 = .now }
            }
        }
    }

    /// Send a keep-alive request.
    ///
    /// This uses a gRPC call to make sure that we are using the same connection as other gRPC calls to ensure that the
    /// connection is kept-alive.
    /// In theory one might be able to use a plain ``URLRequest`` from the same ``URLSession``, but it was not reliable
    /// and connection was not reused.
    private func sendKeepalive() async throws {
        Self.logger.info("Sending keepalive request")
        // Activity time will be automatically updated by the ActivityTracker interceptor
        _ = try await self.client.encryptedVisualSearchConfig(.init())
    }

    func makeEncryptedRequest(
        _ encryptedRequest: PIREncryptedRequest,
        traceContext: PIREncryptedRequestTraceContext
    ) async throws -> PIREncryptedResponse {
        let gRPCRequest = try Apple_Parsec_Encryptedvisualsearch_V1_EncryptedVisualSearchRequest(
            from: encryptedRequest
        )
        let maxRetries = self.attemptCount - 1
        var retryStrategy = MaxAttemptsRetryStrategy(
            maxRetries: maxRetries,
            delay: self.retryDelay
        )
        let start = ContinuousClock.now
        do {
            let response = try await executeWithRetries(retryStrategy: retryStrategy) {
                PIRServiceClientCheckpoint(
                    message: "Sending PIR gRPC request to the server",
                    traceContext: traceContext
                ).log(to: Self.tracingLogger, level: .default, attemptCount: self.attemptCount)
                var options = CallOptions.defaults
                options.timeout = self.requestTimeout
                do {
                    let gRPCResponse = try await self.client.encryptedVisualSearch(gRPCRequest, options: options)
                    PIRServiceClientCheckpoint(
                        message: "Received PIR gRPC response from the server",
                        traceContext: traceContext
                    ).log(to: Self.tracingLogger, level: .default, pirServiceTraceID: gRPCResponse.traceID)
                    return try PIREncryptedResponse(from: gRPCResponse)
                } catch {
                    PIRServiceClientCheckpoint(
                        message: "Failed to get PIR gRPC response",
                        error: error,
                        traceContext: traceContext
                    ).log(to: Self.tracingLogger, level: .error)
                    throw error
                }
            }
            self.emitMetrics(duration: ContinuousClock.now - start, result: .success)
            return response
        } catch {
            self.emitMetrics(duration: ContinuousClock.now - start, result: .failure)
            throw error
        }
    }

    private func emitMetrics(
        duration: Duration,
        result: Metrics.PIRService.ResultValue
    ) {
        self.metricsSystem.emit(Metrics.PIRService.RequestTotalCounter(
            action: .increment(by: 1),
            result: result
        ))
        self.metricsSystem.emit(Metrics.PIRService.RequestDurationHistogram(
            duration: duration,
            result: result
        ))
    }
}

private struct MaxAttemptsRetryStrategy: RetryStrategy {
    let maxRetries: Int
    let delay: Duration

    func shouldRetry(error: Error, retryCount: Int) -> RetryConfiguration {
        if error is CancellationError { return .stop(error: error) }
        if retryCount >= self.maxRetries { return .stop(error: error) }
        return .continue(retryDelay: self.delay)
    }
}

struct MetadataInjector: ClientInterceptor {
    let kfedService: String?

    func intercept<Input, Output>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> where Input: Sendable, Output: Sendable {
        var request = request
        if let kfedService = self.kfedService {
            request.metadata.addString("kfed-service=\(kfedService)", forKey: "X-Apple-Debug")
        }
        request.metadata.addString("encryptedvisualsearch/encryptedvisualsearch", forKey: "apple-featureid")
        return try await next(request, context)
    }
}

struct ActivityTracker: ClientInterceptor {
    let lastActivityTime: SharedMutex<ContinuousClock.Instant>

    func intercept<Input, Output>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> where Input: Sendable, Output: Sendable {
        @Sendable func recordActivity() {
            self.lastActivityTime.withLock { $0 = .now }
        }

        // for each streaming request call `recordActivity`
        let wrappedRequest = StreamingClientRequest<Input>(
            metadata: request.metadata, producer: { writer in
                recordActivity()
                try await request.producer(writer)
            }
        )

        let response = try await next(wrappedRequest, context)

        // for each streaming response call `recordActivity`
        let wrappedBodyParts = response.bodyParts.map { bodyPart in
            recordActivity()
            return bodyPart
        }

        return StreamingClientResponse<Output>(
            metadata: response.metadata,
            bodyParts: RPCAsyncSequence(wrapping: wrappedBodyParts)
        )
    }
}

#endif

final class IdentityURLSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    private static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: String(describing: IdentityURLSessionDelegate.self)
    )

    let identityManager: IdentityManager

    init(identityManager: IdentityManager) {
        self.identityManager = identityManager
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            if let credential = self.identityManager.identity?.credential {
                return (.useCredential, credential)
            } else {
                Self.logger.error("No client certificate credential available. Fall back to default handling.")
                return (.performDefaultHandling, nil)
            }
        default:
            return (.performDefaultHandling, nil)
        }
    }
}

struct PIRServiceClientCheckpoint: RequestCheckpoint {
    var requestID: String?
    var pirRequestID: String
    var pirEncryptedRequestID: String
    var traceID: UUID
    var spanID: UInt64
    var operationName: StaticString
    var serviceName: StaticString = "cb_bridged"
    var namespace: StaticString = "cloudboard"
    var error: Error?
    var message: StaticString

    init(
        requestID: String,
        operationName: StaticString = #function,
        message: StaticString,
        error: Error? = nil,
        traceID: UUID,
        spanID: UInt64,
        pirRequestID: String,
        pirEncryptedRequestID: String
    ) {
        self.requestID = requestID
        self.operationName = operationName
        self.message = message
        self.traceID = traceID
        self.spanID = spanID
        self.error = error
        self.pirRequestID = pirRequestID
        self.pirEncryptedRequestID = pirEncryptedRequestID
    }

    init(
        operationName _: StaticString = #function,
        message: StaticString,
        error: Error? = nil,
        traceContext: PIREncryptedRequestTraceContext
    ) {
        self.init(
            requestID: traceContext.pccServerRequestID,
            message: message,
            error: error,
            traceID: traceContext.traceID,
            spanID: traceContext.spanID,
            pirRequestID: traceContext.pirRequestID,
            pirEncryptedRequestID: traceContext.pirEncryptedRequestID
        )
    }

    func log(to logger: Logger, level: OSLogType) {
        self.log(to: logger, level: level, pirServiceTraceID: "")
    }

    func log(to logger: Logger, level: OSLogType = .default, pirServiceTraceID: String) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
        tracing.trace_id=\(self.traceID.traceIDString, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        pir.request.uuid=\(self.pirRequestID, privacy: .public)
        pir.encryptedRequest.uuid=\(self.pirEncryptedRequestID, privacy: .public)
        pir.encryptedRequest.serverTraceID=\(pirServiceTraceID, privacy: .public)
        """)
    }

    func log(to logger: Logger, level: OSLogType = .default, attemptCount: Int) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID.hexEncoded, privacy: .public)
        tracing.trace_id=\(self.traceID.traceIDString, privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        pir.request.uuid=\(self.pirRequestID, privacy: .public)
        pir.encryptedRequest.uuid=\(self.pirEncryptedRequestID, privacy: .public)
        attemptCount=\(attemptCount, privacy: .public)
        """)
    }
}
