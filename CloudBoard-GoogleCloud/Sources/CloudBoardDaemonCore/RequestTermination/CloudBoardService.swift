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

import CloudBoardJobCore
import CloudBoardJobHelperCore
import CloudBoardProtos
import CloudBoardUtilities
import Configuration
import GRPCCore
import GRPCNIOTransportCore
import GRPCNIOTransportHTTP2
import Logging
import Metrics
import ServiceLifecycle
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private let cloudBoardServiceLogger = Logger(label: "cloudboardd.CloudBoardService")

final class CloudBoardService<IdleClock: Clock>: Service, Sendable where IdleClock.Duration == Duration {
    private static var logger: Logger { cloudBoardServiceLogger }

    private let configReader: ConfigReader
    private let statusMonitor: ServiceStatusMonitor
    private let attestationProvider: any AttestationProvider
    private let attestedKeyProvider: any AttestedKeyProvider
    private let sessionStore: SessionStore
    private let requestEncryptionKeyResolver: any RequestEncryptionKeyResolver
    private let cloudAppWarmupPool: CloudAppWarmupPool
    private let metricsFactory: any MetricsFactory
    private let idleClock: IdleClock

    init(
        configReader: ConfigReader,
        statusMonitor: ServiceStatusMonitor,
        attestationProvider: any AttestationProvider,
        attestedKeyProvider: any AttestedKeyProvider,
        sessionStore: SessionStore,
        requestEncryptionKeyResolver: any RequestEncryptionKeyResolver,
        cloudAppWarmupPool: CloudAppWarmupPool,
        metricsFactory: any MetricsFactory = MetricsSystem.factory,
        idleClock: IdleClock = ContinuousClock()
    ) {
        self.configReader = configReader
        self.statusMonitor = statusMonitor
        self.attestationProvider = attestationProvider
        self.attestedKeyProvider = attestedKeyProvider
        self.sessionStore = sessionStore
        self.requestEncryptionKeyResolver = requestEncryptionKeyResolver
        self.cloudAppWarmupPool = cloudAppWarmupPool
        self.metricsFactory = metricsFactory
        self.idleClock = idleClock
    }

    func run() async throws {
        while !Task.isShuttingDownGracefully {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Reads `invokeWorkload.idleTimeoutMilliseconds` and clamps non-positive
    /// values to the default. A misconfigured `0` or negative value would
    /// otherwise cause `IdleTimeout.run()` to fire immediately and abort every
    /// request.
    private func resolveIdleTimeout() -> Duration {
        let rawMs = self.configReader.int(
            forKey: "invokeWorkload.idleTimeoutMilliseconds",
            default: 60_000
        )
        if rawMs > 0 {
            return .milliseconds(rawMs)
        }
        Self.logger.warning(
            "invokeWorkload.idleTimeoutMilliseconds <= 0; falling back to 60000",
            metadata: ["raw": "\(rawMs)"]
        )
        return .milliseconds(60_000)
    }
}

extension CloudBoardService: Proto_CloudBoard_CloudBoard.StreamingServiceProtocol {
    func watchAttestation(
        request _: GRPCCore.StreamingServerRequest<Proto_CloudBoard_WatchAttestationRequest>,
        context: GRPCCore.ServerContext,
    ) async throws -> GRPCCore.StreamingServerResponse<Proto_CloudBoard_WatchAttestationResponse> {
        .init { writer in
            try await withErrorLogging(operation: "watchAttestation", to: Self.logger) {
                try await context.withTaskCancellationOnRPCCancellation {
                    for await attestationSet in self.attestationProvider.watchAttestationSets() {
                        Self.logger.info(
                            "Sending attestation set",
                            metadata: [
                                "currentKeyID":
                                    "\(attestationSet.currentAttestation.keyID.base64EncodedString())",
                                "unpublishedKeyIDs":
                                    "\(attestationSet.unpublishedAttestations.map { $0.keyID.base64EncodedString() })",
                                "unpublishedKeyCount": "\(attestationSet.unpublishedAttestations.count)",
                            ]
                        )
                        try await writer.write(Proto_CloudBoard_WatchAttestationResponse(attestationSet))
                    }
                }

                return Metadata()
            }
        }
    }

    func watchLoadLevel(
        request _: GRPCCore.StreamingServerRequest<Proto_CloudBoard_LoadRequest>,
        context: GRPCCore.ServerContext,
    ) async throws -> GRPCCore.StreamingServerResponse<Proto_CloudBoard_LoadResponse> {
        .init { writer in
            try await withErrorLogging(operation: "watchLoadLevel", to: Self.logger) {
                try await context.withTaskCancellationOnRPCCancellation {
                    var lastReportedState: ServiceStatusMonitor.InvokeWorkloadLoadState?
                    for try await stateUpdate in self.statusMonitor.watch() {
                        // The load state carries the in-progress affinity keys; non-serving states
                        // collapse to `.unavailable`, which reports empty affinity automatically.
                        let loadState =
                            switch stateUpdate.aggregateState {
                            case .ready(let state):
                                state
                            case .degraded(_, let state):
                                state
                            case .initializing, .transientError, .busy, .terminalError, .draining, .drained:
                                ServiceStatusMonitor.InvokeWorkloadLoadState.unavailable
                            }

                        if lastReportedState != loadState {
                            Self.logger.info(
                                "Reporting load status",
                                metadata: [
                                    "concurrentRequestCount": "\(loadState.concurrentRequestCount)",
                                    "maxConcurrentRequests": "\(loadState.maxConcurrentRequests)",
                                    "optimalConcurrentRequests":
                                        "\(loadState.optimalConcurrentRequests.map { String($0) } ?? "nil")",
                                    "affinityKeyCount": "\(loadState.affinityKeysInProgress.count)",
                                    "affinityKeysInProgress":
                                        "\(loadState.affinityKeysInProgress.map { "\($0.category):\($0.data)" }.joined(separator: ","))",
                                ]
                            )
                            try await writer.write(
                                .with {
                                    $0.currentBatchSize = UInt32(loadState.concurrentRequestCount)
                                    $0.maxBatchSize = UInt32(loadState.maxConcurrentRequests)
                                    if let optimalBatchSize = loadState.optimalConcurrentRequests {
                                        $0.optimalBatchSize = UInt32(optimalBatchSize)
                                    }
                                    $0.affinityKeysInProgress = loadState.affinityKeysInProgress.map(\.proto)
                                }
                            )
                            lastReportedState = loadState
                        } else {
                            Self.logger.debug(
                                "Not reporting deduplicated load status",
                                metadata: [
                                    "concurrentRequestCount": "\(loadState.concurrentRequestCount)",
                                    "maxConcurrentRequests": "\(loadState.maxConcurrentRequests)",
                                    "optimalConcurrentRequests":
                                        "\(loadState.optimalConcurrentRequests.map { String($0) } ?? "nil")",
                                ]
                            )
                        }
                    }
                }

                return Metadata()
            }
        }
    }

    func invokeWorkload(
        request: GRPCCore.StreamingServerRequest<Proto_CloudBoard_InvokeWorkloadRequest>,
        context _: GRPCCore.ServerContext,
    ) async throws -> GRPCCore.StreamingServerResponse<Proto_CloudBoard_InvokeWorkloadResponse> {
        .init { writer in
            try await self.withInvokeWorkloadRequestSummaryAndMetrics(metricsFactory: self.metricsFactory) {
                requestStats in
                if let rpcID = request.metadata.extractRPCID() {
                    requestStats.rpcIdReceived(rpcID)
                }
                return try await self.statusMonitor.monitoringLoad { preRequestLoadState, affinityRegistration in
                    // Affinity keys arrive mid-stream in `Parameters`, after the request is
                    // admitted. `monitoringLoad` owns the registration's teardown, removing any
                    // activated keys atomically with the load-count drop; the executor only
                    // activates it once `Parameters` arrives.
                    try await InvokeWorkloadViaJobHelperExecutor(
                        configReader: self.configReader,
                        requestEncryptionKeyResolver: self.requestEncryptionKeyResolver,
                        preRequestLoadState: preRequestLoadState,
                        cloudAppWarmupPool: self.cloudAppWarmupPool,
                        sessionStore: self.sessionStore,
                        metricsFactory: self.metricsFactory,
                        idleTimeout: self.resolveIdleTimeout(),
                        idleClock: self.idleClock,
                        affinityRegistration: affinityRegistration
                    ).process(request, writer: writer, requestStats: requestStats)

                    return Metadata()
                }
            }
        }
    }

    /// Logs request summary and emits duration and status metrics for the request once the provided closure completes
    func withInvokeWorkloadRequestSummaryAndMetrics<T>(
        metricsFactory: any MetricsFactory,
        _ body: (InvokeWorkloadRequestStatistics) async throws -> T
    ) async rethrows -> T {
        let requestStats = InvokeWorkloadRequestStatistics(grpcCallStart: ContinuousClock.now)
        Counter(label: "cloudboard_requests_total", factory: metricsFactory).increment()
        do {
            let result = try await body(requestStats)
            recordInvokeWorkloadRequestSummaryAndMetrics(requestStats: requestStats, metricsFactory: metricsFactory)
            return result
        } catch {
            if isRequestCancellation(error), !requestStats.hasSentSetupAck {
                Counter(
                    label: "cloudboard_requests_cancelled_before_setup_ack_total",
                    factory: metricsFactory
                ).increment()
            }
            Counter(
                label: "cloudboard_requests_errors_total",
                dimensions: [("errorDescription", String(reportable: error))],
                factory: metricsFactory
            ).increment()
            recordInvokeWorkloadRequestSummaryAndMetrics(
                requestStats: requestStats,
                metricsFactory: metricsFactory,
                error: error
            )
            throw error
        }
    }

    /// Whether an error represents a caller-initiated cancellation (task cancellation or a gRPC `.cancelled` status)
    private func isRequestCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let rpcError = error as? RPCError, rpcError.code == .cancelled {
            return true
        }
        return false
    }

    private func recordInvokeWorkloadRequestSummaryAndMetrics(
        requestStats: InvokeWorkloadRequestStatistics,
        metricsFactory: any MetricsFactory,
        error: Error? = nil
    ) {
        let durations = requestStats.durations()
        recordDurationMetrics(
            durations: durations,
            factory: metricsFactory,
            dimensions: [
                ("automatedDeviceGroup", requestStats.parameters?.tenantInfo.automatedDeviceGroup ?? "unknown"),
                ("featureId", requestStats.parameters?.tenantInfo.featureID ?? "unknown"),
                ("bundleId", requestStats.parameters?.tenantInfo.bundleID ?? "unknown"),
            ]
        )
        let parameters = requestStats.parameters
        let rpcID = requestStats.rpcID ?? ""
        let traceID = parameters.flatMap { $0.hasTraceContext ? $0.traceContext.traceID.hexEncoded : nil } ?? ""

        let logger = Logger(label: "cloudboardd.CloudBoardService")
        logger.log(
            level: error == nil ? .info : .error,
            "InvokeWorkload request summary",
            metadata: [
                "requestID": "\(parameters?.requestID ?? "")",
                "rpcID": "\(rpcID)",
                "error": "\(error.map { String(reportable: $0) } ?? "")",
                "bundleID": "\(parameters?.tenantInfo.bundleID ?? "")",
                "bundleVersion": "\(parameters?.tenantInfo.bundleVersion ?? "")",
                "featureID": "\(parameters?.tenantInfo.featureID ?? "")",
                "clientInfo": "\(parameters?.tenantInfo.clientInfo ?? "")",
                "automatedDeviceGroup": "\(parameters?.tenantInfo.automatedDeviceGroup ?? "")",
                "workloadType": "\(parameters?.workload.type ?? "")",
                "traceID": "\(traceID)",
                "terminationCode": "\(requestStats.terminationCode.map { "\($0)" } ?? "")",
                "terminationReason": "\(requestStats.terminationReason ?? "")",
                "requestChunksReceived": "\(requestStats.requestChunksReceived)",
                "finalRequestChunkReceived": "\(requestStats.finalRequestChunkReceived)",
                "encryptedRequestBytesReceived": "\(requestStats.encryptedRequestBytesReceived)",
                "responseChunksSent": "\(requestStats.responseChunksSent)",
                "finalResponseChunkSent": "\(requestStats.finalResponseChunkSent)",
                "encryptedResponseBytesSent": "\(requestStats.encryptedResponseBytesSent)",
                "totalMs": "\(durations.total.map { "\($0.inMilliseconds)" } ?? "")",
                "grpcCallStartToSetupMs": "\(durations.grpcCallStartToSetup.map { "\($0.inMilliseconds)" } ?? "")",
                "setupToSetupAckMs": "\(durations.setupToSetupAck.map { "\($0.inMilliseconds)" } ?? "")",
                "setupAckToParametersMs": "\(durations.setupAckToParameters.map { "\($0.inMilliseconds)" } ?? "")",
                "setupToParametersMs": "\(durations.setupToParameters.map { "\($0.inMilliseconds)" } ?? "")",
                "setupToFirstRequestChunkMs":
                    "\(durations.setupToFirstRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
                "parametersToFirstRequestChunkMs":
                    "\(durations.parametersToFirstRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
                "firstRequestChunkToFirstResponseChunkMs":
                    "\(durations.firstRequestChunkToFirstResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                "firstRequestChunkToFinalRequestChunkMs":
                    "\(durations.firstRequestChunkToFinalRequestChunk.map { "\($0.inMilliseconds)" } ?? "")",
                "firstRequestChunkToFinalResponseChunkMs":
                    "\(durations.firstRequestChunkToFinalResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                "finalRequestChunkToFirstResponseChunkMs":
                    "\(durations.finalRequestChunkToFirstResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                "finalRequestChunkToFinalResponseChunkMs":
                    "\(durations.finalRequestChunkToFinalResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                "firstResponseChunkToFinalResponseChunkMs":
                    "\(durations.firstResponseChunkToFinalResponseChunk.map { "\($0.inMilliseconds)" } ?? "")",
                "finalResponseChunkToCallEndMs":
                    "\(durations.finalResponseChunkToCallEnd.map { "\($0.inMilliseconds)" } ?? "")",
                "terminationReceivedToCallEndMs":
                    "\(durations.terminationReceivedToCallEnd.map { "\($0.inMilliseconds)" } ?? "")",
            ]
        )
    }
}

extension Proto_CloudBoard_WatchAttestationResponse {
    init(_ attestationSet: CloudBoardJobHelperCore.AttestationSet) {
        self = .with {
            $0.attestationSet = .with {
                $0.activeAttestation = .with {
                    $0.attestationBundle = attestationSet.currentAttestation.attestationBundle
                    $0.attestationMetadata = .init(attestationSet.currentAttestation)
                }
                $0.unpublishedAttestations = attestationSet.unpublishedAttestations.map { attestation in
                    .init(attestation)
                }
            }
        }
    }
}

extension Proto_CloudBoard_WatchAttestationResponse.AttestationMetadata {
    init(_ attestation: CloudBoardJobHelperCore.AttestationSet.Attestation) {
        self = .with {
            $0.keyID = attestation.keyID
            $0.expiresAfter = .init(date: attestation.expiry)
            if let treeID = attestation.transparencyTreeID {
                $0.transparencyTreeID = treeID
            }
            if let revision = attestation.transparencyRevision {
                $0.transparencyRevision = revision
            }
        }
    }
}
