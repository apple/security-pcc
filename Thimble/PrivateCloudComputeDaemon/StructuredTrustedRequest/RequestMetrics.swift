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

//
//  RequestMetrics.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import CloudAttestation
import CloudTelemetry
import Foundation
import GenerativeFunctionsInstrumentation
@_spi(Restricted) import IntelligencePlatformLibrary
@_spi(HTTP) @_spi(NWActivity) import Network
import OSLog
import PrivateCloudCompute
import Synchronization
import os

private let logger = tc2Logger(forCategory: .trustedRequest)

final class RequestMetrics<
    Clock: _Concurrency.Clock,
    AttestationStore: AttestationStoreProtocol,
    SystemInfo: SystemInfoProtocol,
    BiomeReporter: BiomeReporterProtocol
>: TrustedRequestXPCEventsObserver, Sendable where Clock.Duration == Duration {
    struct State: Sendable {
        let environment: String
        let logPrefix: String

        enum RopesRequestState: Sendable, CustomStringConvertible {
            case initialized
            case waitingForConnection(attestationsActivity: NWActivity)
            case requestSent(attestationsActivity: NWActivity)
            case responseHeadReceived(attestationsActivity: NWActivity)
            case attestationsReceived
            case finished(Duration)
            case failed(PrivateCloudComputeError, Duration)

            var description: String {
                switch self {
                case .initialized:
                    return "Initialized"
                case .requestSent:
                    return "Request sent"
                case .responseHeadReceived:
                    return "Response head received"
                case .attestationsReceived:
                    return "Attestations received"
                case .finished:
                    return "Finished"
                case .failed(let error, _):
                    return "Failed (error: \(error))"
                case .waitingForConnection:
                    return "Waiting for ROPES OHTTP Connection"
                }
            }
        }

        enum DataStreamState: Sendable, CustomStringConvertible {
            case initialized
            case authTokenSent
            case awaitingForReadyForMoreChunks(bytesSent: Int)
            case readyForMoreChunks(bytesSent: Int)
            case finished(bytesSent: Int)
            case failed(any Error)

            var description: String {
                switch self {
                case .initialized:
                    return "Initialized"
                case .authTokenSent:
                    return "AuthTokenSent"
                case .awaitingForReadyForMoreChunks(let bytesSent):
                    return "Connected (remaining budget: \(TrustedRequestConstants.maxDataToSendBeforeReadyForMoreChunksReceived - bytesSent))"
                case .readyForMoreChunks:
                    return "Node selected"
                case .finished:
                    return "Finished"
                case .failed(let error):
                    return "Failed (error: \(error))"
                }
            }
        }

        /// Note: response payload could be coming on node stream or response bypass stream.
        /// Expected normal flow:
        /// - initialized > waitingToSendFirstKey > waitingForNode > receiving > finished
        /// - any > failed
        enum ResponseState: Sendable, CustomStringConvertible {
            case initialized
            /// Can't expect to receive response if haven't sent data key. User's request data can't be decoded on the server without our key.
            case waitingToSendFirstKey(firstTokenActivity: NWActivity)
            /// Means data key has been already sent to at least one node. After this we could expect to start receiving a response.
            /// If that node gets selected and received the user's data, then it could decode that data, and generate a response.
            /// Perhaps a better name would be: `waitingForResponse`.
            case waitingForNode(firstTokenActivity: NWActivity, interval: OSSignpostIntervalState)
            /// Means we are receiving actual payload that is a response to user's request. If response bypass is on, it comes on the response
            /// bypass stream, otherwise it comes on proxy node's stream.
            case receiving(bytesReceived: Int, interval: OSSignpostIntervalState)
            /// If response bypass is on, this should indicate it finished.
            /// If it's off and we expect response payload on one of node streams, this would indicate node streams finished.
            case finished(bytesReceived: Int)
            /// If response bypass is on, this should indicate a failure on response bypass stream.
            /// If it's off and we expect response payload on one of node streams, this would indicate an error there. Note
            /// that errors from non-selected proxy nodes don't affect overall result.
            case failed(any Error)

            var description: String {
                switch self {
                case .initialized:
                    return "Initialized"
                case .waitingToSendFirstKey:
                    return "Waiting to send first key"
                case .waitingForNode:
                    return "Waiting for Node"
                case .receiving:
                    return "Receiving"
                case .finished:
                    return "Finished"
                case .failed(let error):
                    return "Failed (error: \(error))"
                }
            }
        }

        enum AuthTokenFetchState: Sendable {
            case notStarted
            case succeeded(Duration)
            case failed(any Error, Duration)
        }

        enum AuthTokenSendState: Sendable {
            case notStarted
            case succeeded(Duration)
            case failed(any Error, Duration)
        }

        enum AttestationsReceivedState: Sendable {
            case noAttestationReceived
            case receivedAttestations(count: Int, durationSinceStart: Duration)
        }

        enum RopesRequestSentState: Sendable {
            case notSend
            case succeeded(Duration)
            case failed(any Error, Duration)
        }

        /// Auth token fetch state for subrequests (times relative to subrequest timebase)
        enum SubrequestAuthTokenFetchState: Sendable {
            case notStarted
            case succeeded(startTime: Duration, finishTime: Duration)
            case failed(startTime: Duration, finishTime: Duration, error: any Error)
        }

        enum KDataSendState: Sendable {
            case notSend
            /// duration here means the time interval from beginning of the request to the time when we send the first key
            case sent(duration: Duration, count: Int)
        }

        enum FirstChunkSentState: Sendable {
            case notSend
            case succeeded(Duration, withinBudget: Bool)
        }

        enum OHTTPConnectionEstablishmentState {
            case notEstablished
            case established(Duration, (any ConnectionEstablishmentReport)?)
            case failed(Duration, any Error)
        }

        enum AttestationBundleRef: Equatable {
            case lookupInDatabase
            case data(Data)
        }

        struct NodeMetadata: Sendable {
            enum State: Sendable, CustomStringConvertible {
                case unverified
                case verifying
                case verified
                case verifiedFailed(any Error)
                case sentKey
                case receiving(summaryReceived: Bool, bytesReceived: Int)
                case finished(summaryReceived: Bool, bytesReceived: Int)

                var description: String {
                    switch self {
                    case .unverified:
                        "unverified"
                    case .verifying:
                        "verifying"
                    case .verifiedFailed:
                        "verifiedFailed"
                    case .verified:
                        "verified"
                    case .sentKey:
                        "sentKey"
                    case .receiving:
                        "receiving"
                    case .finished:
                        "finished"
                    }
                }

                var hasReceivedSummary: Bool {
                    switch self {
                    case .unverified, .verifying, .verified, .verifiedFailed, .sentKey:
                        return false
                    case .receiving(let summaryReceived, _),
                        .finished(let summaryReceived, _):
                        return summaryReceived
                    }
                }

                var bytesReceived: UInt64 {
                    switch self {
                    case .unverified, .verifying, .verified, .verifiedFailed, .sentKey:
                        return 0
                    case .receiving(_, let bytesReceived),
                        .finished(_, let bytesReceived):
                        return UInt64(bytesReceived)
                    }
                }
            }

            var state: State
            var nodeID: String
            var attestationBundleRef: AttestationBundleRef
            var ohttpContext: UInt64
            var cloudOSVersion: String?
            var cloudOSReleaseType: String?
            var maybeValidatedCellID: String?
            var ensembleID: String?
            var requestExecutionLogFinalized: Bool = false
            var isFromCache: Bool {
                switch self.attestationBundleRef {
                case .lookupInDatabase:
                    true
                case .data(_):
                    false
                }
            }
        }

        struct ProxiedNodeMetadata: Sendable {
            var nodeID: String
            var attestationBundle: Data
            var proxiedBy: String
        }

        /// Metadata about a subrequest within this TrustedRequest
        struct SubrequestState: Sendable {
            init(
                subrequestIdForEventReporting: SpanID,
                durationFromStartUntilTimebase: Duration,
                priority: PrivateCloudComputeConnection.Request.Priority? = nil
            ) {
                self.subrequestIdForEventReporting = subrequestIdForEventReporting
                self.durationFromStartUntilTimebase = durationFromStartUntilTimebase
                self.priority = priority
            }

            let subrequestIdForEventReporting: SpanID
            let durationFromStartUntilTimebase: Duration

            var priority: PrivateCloudComputeConnection.Request.Priority?
            var authTokenFetchState: SubrequestAuthTokenFetchState = .notStarted

            // Outgoing message timings (relative to timebase)
            var durationFromTimebaseUntilOpenEnqueued: Duration?
            var durationFromTimebaseUntilOpenWritten: Duration?
            var durationFromTimebaseUntilFirstDataEnqueued: Duration?
            var durationFromTimebaseUntilFirstDataWritten: Duration?
            var durationFromTimebaseUntilLastDataWritten: Duration?
            var durationFromTimebaseUntilCloseWritten: Duration?

            // Server response timings (relative to timebase)
            var durationFromTimebaseUntilOpenResponseReceived: Duration?
            var durationFromTimebaseUntilFirstResponseDataReceived: Duration?
            var durationFromTimebaseUntilLastResponseDataReceived: Duration?

            private(set) var writeExceededInitialBudget: Bool?

            /// Once set to `true`, it stays `true`.
            mutating func setWriteExceededInitialBudget(_ exceeded: Bool) {
                if exceeded {
                    writeExceededInitialBudget = true
                } else if writeExceededInitialBudget == nil {
                    writeExceededInitialBudget = false
                }
            }

            private(set) var durationFromTimebaseUntilCloseResponseReceived: Duration?
            private(set) var remoteResponseStatus: XPCResponseMessage.SubresponseStatus?
            private(set) var subrequestError: (any Error)?

            private var durationFromTimebaseUntilEnd: Duration?

            private var isInflight: Bool {
                durationFromTimebaseUntilEnd == nil
            }

            /// Called when we receive closeSubresponse from the server. Only affects inflight subrequests.
            mutating func endWithServerClose(
                durationFromConnectionStartUntilNow: Duration,
                responseStatus: XPCResponseMessage.SubresponseStatus
            ) {
                guard isInflight else { return }

                let relativeToTimebase = durationFromConnectionStartUntilNow - durationFromStartUntilTimebase
                durationFromTimebaseUntilEnd = relativeToTimebase
                durationFromTimebaseUntilCloseResponseReceived = relativeToTimebase
                remoteResponseStatus = responseStatus
            }

            /// Called when the parent connection ends. Only affects inflight subrequests.
            mutating func endWithConnectionClose(
                durationFromConnectionStartUntilNow: Duration,
                error: PrivateCloudComputeError?
            ) {
                guard isInflight else { return }

                durationFromTimebaseUntilEnd = durationFromConnectionStartUntilNow - durationFromStartUntilTimebase
                if subrequestError == nil {
                    subrequestError = error
                }
            }

            func eventTime(connectionStartTime: Date) -> Date? {
                guard let durationFromTimebaseUntilEnd else { return nil }
                let endDuration = durationFromStartUntilTimebase + durationFromTimebaseUntilEnd
                return connectionStartTime.addingTimeInterval(endDuration / .seconds(1))
            }
        }

        mutating func getOrCreateSubrequestState(
            subrequestId: SpanID,
            durationFromStartUntilTimebase: Duration
        ) -> SubrequestState {
            if let existing = self.subrequests[subrequestId] {
                return existing
            }

            // Privacy: Use anonymized ID for telemetry in production to avoid linking server/client logs
            let subrequestIdForEventReporting: SpanID
            if self.environment == TC2Environment.production.name {
                subrequestIdForEventReporting = SpanID()
                let logPrefix = self.logPrefix
                logger.log("\(logPrefix) New subrequest \(subrequestId) logged for metrics with reporting subrequestId \(subrequestIdForEventReporting)")
            } else {
                subrequestIdForEventReporting = subrequestId
            }

            let newState = SubrequestState(
                subrequestIdForEventReporting: subrequestIdForEventReporting,
                durationFromStartUntilTimebase: durationFromStartUntilTimebase
            )
            self.subrequests[subrequestId] = newState
            return newState
        }

        var connectionEstablishState: OHTTPConnectionEstablishmentState = .notEstablished
        var dataTransferReport: DataTransferReport?
        var ropesRequestState: RopesRequestState = .initialized
        var ropesRequestSentState: RopesRequestSentState = .notSend
        var ropesRequestHeaders: HTTPFields? = nil
        var dataStreamState: DataStreamState = .initialized
        var responseState: ResponseState = .initialized
        var authTokenFetchState: AuthTokenFetchState = .notStarted
        var authTokenSendState: AuthTokenSendState = .notStarted
        var firstChunkSentState: FirstChunkSentState = .notSend
        var attestationsReceivedState: AttestationsReceivedState = .noAttestationReceived
        var kDataSendState: KDataSendState = .notSend

        var durationFromStartUntilReadyForMoreChunks: Duration? = nil
        var durationFromStartUntilLastPayloadChunkSent: Duration? = nil
        var durationFromStartUntilFirstToken: Duration? = nil
        var durationFromStartUntilLastResponseChunk: Duration? = nil
        var durationFromStartUntilNodeStreamsFinished: Duration? = nil
        var durationFromStartUntilResponseBypassFinished: Duration? = nil
        var durationFromStartUntilGatewayStreamFinished: Duration? = nil

        var responseCode: Int?
        var ropesVersion: String?

        var nodes: [String: NodeMetadata] = [:]
        var proxiedNodes: [ProxiedNodeMetadata] = []
        var executionAssets: [AssetMetadata] = []
        /// Accumulates information about all subrequests in this TrustedRequest; queued until requestFinished
        var subrequests: [SpanID: SubrequestState] = [:]
        var cancellationReason: TrustedRequestCancellationReason?
        var selectedNodeOHTTPContext: Int? = nil
    }

    private let state: Mutex<State>
    private let clock: Clock

    private let clientRequestID: UUID
    private let serverRequestID: UUID
    private let startDate: Date
    private let startInstant: Clock.Instant
    private let bundleID: String
    private let originatingBundleID: String?
    private let featureID: String?
    private let sessionID: UUID?
    private let environment: String
    private let qos: ServerQoS
    private let parameters: Workload

    private let systemInfo: SystemInfo
    private let locale: Locale

    private let logPrefix: String
    private let eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation

    private let signposter: OSSignposter
    private let signpostID: OSSignpostID
    private let fullRequestInterval: OSSignpostIntervalState

    /// this is the requestID that will be used for Cloud Telemetry reporting
    /// In PROD, it needs to be different than requestID for privacy concerns
    let requestIDForEventReporting: UUID
    private let attestationStore: AttestationStore?
    private let biomeReporter: BiomeReporter
    private let encoder = tc2JSONEncoder()

    init(
        clientRequestID: UUID,
        serverRequestID: UUID,
        bundleID: String,
        originatingBundleID: String?,
        featureID: String?,
        sessionID: UUID?,
        environment: String,
        qos: ServerQoS,
        parameters: Workload,
        eventStreamContinuation: AsyncStream<ThimbledEvent>.Continuation,
        clock: Clock,
        startDate: Date = .now,
        store: AttestationStore?,
        systemInfo: SystemInfo,
        biomeReporter: BiomeReporter
    ) {
        self.clientRequestID = clientRequestID
        self.serverRequestID = serverRequestID
        self.clock = clock
        self.startDate = startDate
        self.startInstant = clock.now

        self.bundleID = bundleID
        self.originatingBundleID = originatingBundleID
        self.featureID = featureID
        self.sessionID = sessionID
        self.environment = environment
        self.qos = qos
        self.parameters = parameters

        self.systemInfo = systemInfo
        self.locale = Locale.current

        self.logPrefix = "\(serverRequestID):"
        self.eventStreamContinuation = eventStreamContinuation
        self.signposter = OSSignposter(logger: logger)
        self.signpostID = self.signposter.makeSignpostID()
        self.fullRequestInterval = self.signposter.beginInterval("FullTrustedRequest", id: self.signpostID)

        if self.environment == TC2Environment.production.name {
            self.requestIDForEventReporting = UUID()
            logger.log("\(self.logPrefix) RequestIDForEventReporting: \(self.requestIDForEventReporting)")
        } else {
            self.requestIDForEventReporting = self.serverRequestID
        }

        self.attestationStore = store
        self.biomeReporter = biomeReporter

        self.state = Mutex(State(environment: environment, logPrefix: self.logPrefix))
    }

    // MARK: - Export

    func makeLogEntry() -> TrustedRequestLogEntry {
        let state = self.state.withLock { $0 }
        var endpoints = state.nodes.map { (_, info) in
            let servedRequest: Bool
            if let selectedContext = state.selectedNodeOHTTPContext, selectedContext == info.ohttpContext {
                servedRequest = true
            } else {
                servedRequest = false
            }

            return TrustedRequestEndpointMetadata(
                nodeState: "\(info.state)",
                nodeIdentifier: info.nodeID,
                ohttpContext: info.ohttpContext,
                hasReceivedSummary: info.state.hasReceivedSummary,
                dataReceived: info.state.bytesReceived,
                cloudOSVersion: info.cloudOSVersion,
                cloudOSReleaseType: info.cloudOSReleaseType,
                maybeValidatedCellID: info.maybeValidatedCellID,
                ensembleID: info.ensembleID,
                isFromCache: info.isFromCache,
                servedRequest: servedRequest,
                proxiedBy: nil,  // not applicable
                requestExecutionLogFinalized: info.requestExecutionLogFinalized,
            )
        }

        endpoints += state.proxiedNodes.map { info in
            TrustedRequestEndpointMetadata(
                nodeState: nil,  // we don't verify proxied attestations
                nodeIdentifier: info.nodeID,
                ohttpContext: 0,  // not applicable for proxied attestations
                hasReceivedSummary: false,  // not applicable
                dataReceived: 0,  // not applicable
                cloudOSVersion: nil,  // not easily available
                cloudOSReleaseType: nil,  // not easily available
                maybeValidatedCellID: nil,  // not easily available
                ensembleID: nil,  // not easily available
                isFromCache: false,  // not applicable
                servedRequest: false,  // not applicable
                proxiedBy: info.proxiedBy,
                requestExecutionLogFinalized: nil,  // not applicable
            )
        }

        return TrustedRequestLogEntry(
            type: .trustedRequest,
            clientRequestID: self.clientRequestID,
            serverRequestID: self.serverRequestID,
            environment: self.environment,
            creationDate: self.startDate,
            bundleIdentifier: self.bundleID,
            featureIdentifier: self.featureID,
            sessionIdentifier: self.sessionID,
            qos: self.qos.rawValue,
            workloadName: self.parameters.type,
            workloadParameters: self.parameters.parameters,
            state: "\(state.ropesRequestState)",
            payloadTransportState: "\(state.dataStreamState)",
            requestHeaders: state.ropesRequestHeaders?.dictionaryForLogging ?? [:],
            responseState: "\(state.responseState)",
            responseCode: state.responseCode,
            ropesVersion: state.ropesVersion,
            endpoints: endpoints
        )
    }

    private func makeFullRequestMetrics() -> TrustedRequestMetric {
        let stateCopy = self.state.withLock { $0 }

        return TrustedRequestMetric(
            eventTime: .now,
            bundleID: self.bundleID,
            environment: self.environment,
            systemInfo: self.systemInfo,
            featureID: self.featureID,
            originatingBundleID: self.originatingBundleID,
            locale: self.locale,
            clientRequestId: self.requestIDForEventReporting,
            requestMetricsState: stateCopy
        )
    }

    // MARK: - Connection metrics

    func reportConnectionReady() {
        let duration = self.startInstant.duration(to: self.clock.now)

        self.state.withLock { state in
            switch state.connectionEstablishState {
            case .notEstablished, .failed:
                state.connectionEstablishState = .established(duration, nil)

            case .established:
                break
            }
        }
    }

    func reportConnectionEstablishReport(_ report: any ConnectionEstablishmentReport) {
        let duration = self.startInstant.duration(to: self.clock.now)

        self.state.withLock { state in
            switch state.connectionEstablishState {
            case .notEstablished, .failed:
                // this should never happen, but we don't want to crash here!
                state.connectionEstablishState = .established(duration, report)

            case .established(_, .some):
                // this should never happen, but we don't want to crash here!
                break

            case .established(let duration, .none):
                state.connectionEstablishState = .established(duration, report)
            }
        }
    }

    func reportConnectionError(_ error: any Error) {
        let duration = self.startInstant.duration(to: self.clock.now)

        self.state.withLock { state in
            switch state.connectionEstablishState {
            case .notEstablished:
                state.connectionEstablishState = .failed(duration, error)

            case .established, .failed:
                // let's not overwrite the initial state!
                break
            }
        }
    }

    func reportDataTransferReport(_ report: DataTransferReport) {
        self.state.withLock { state in
            guard state.dataTransferReport == nil else {
                // Don't overwrite first report
                return
            }
            state.dataTransferReport = report
        }
    }

    // MARK: - Ropes Connection

    func attachNetworkActivities(_ activityStarter: some NWActivityTracker) {
        let attestationActivity = NWActivity(domain: .cloudCompute, label: .attestationFetch)
        let firstTokenActivity = NWActivity(domain: .cloudCompute, label: .computeRequest)

        activityStarter.startActivity(attestationActivity)
        activityStarter.startActivity(firstTokenActivity)

        self.state.withLock { state in
            switch state.responseState {
            case .initialized:
                state.responseState = .waitingToSendFirstKey(firstTokenActivity: firstTokenActivity)
            case .waitingToSendFirstKey, .waitingForNode, .receiving, .finished, .failed:
                // TODO: fail the activity right away
                break
            }

            switch state.ropesRequestState {
            case .initialized:
                state.ropesRequestState = .waitingForConnection(attestationsActivity: attestationActivity)

            case .waitingForConnection,
                .requestSent,
                .responseHeadReceived,
                .attestationsReceived,
                .finished,
                .failed:
                // TODO: fail the activity right away
                break
            }
        }
    }

    func observeSendingRopesRequest<Success: Sendable>(headers: HTTPFields, _ closure: () async throws -> Success) async throws -> Success {
        let result = await Result(asyncCatching: closure)
        let duration = self.startInstant.duration(to: self.clock.now)

        self.state.withLock {
            $0.ropesRequestHeaders = headers

            switch result {
            case .success:
                $0.ropesRequestSentState = .succeeded(duration)
                guard case .waitingForConnection(let activity) = $0.ropesRequestState else {
                    break
                }
                $0.ropesRequestState = .requestSent(attestationsActivity: activity)
            case .failure(let error):
                $0.ropesRequestSentState = .failed(error, duration)
            // NOTE: ropesRequestState failure will be set through surrounding metrics calls
            }
        }
        if result.isSuccess {
            self.signposter.emitEvent("RopesInvokeRequestSent", id: self.signpostID)
        }
        logger.log("\(self.logPrefix) Ropes invoke request sent")
        return try result.get()
    }

    func ropesConnectionResponseReceived(response: HTTPResponse, error: (any Error)?) {
        let isResponseHead = self.state.withLock {
            guard case .requestSent(let attestationsActivity) = $0.ropesRequestState else {
                return false
            }

            $0.ropesRequestState = .responseHeadReceived(attestationsActivity: attestationsActivity)
            $0.responseCode = response.status.code
            $0.ropesVersion = response.headerFields[.appleServerBuildVersion]
            return true
        }

        guard isResponseHead else { return }

        logger.log("\(self.logPrefix) Ropes invoke response head received")
        self.signposter.emitEvent("RopesResponseHeadReceived", id: self.signpostID)

        let invokeResponseMetric = InvokeResponseMetric(
            eventTime: .now,
            bundleID: self.bundleID,
            clientRequestId: self.requestIDForEventReporting,
            environment: self.environment,
            systemInfo: self.systemInfo,
            featureID: featureID,
            locale: self.locale,
            error: error
        )

        self.eventStreamContinuation.yield(.exportMetric(invokeResponseMetric))
    }

    func requestFinished(error: PrivateCloudComputeError?) async {
        let durationFromStartUntilNow = self.startInstant.duration(to: self.clock.now)

        self.state.withLock { state in
            if let error {
                state.ropesRequestState = .failed(error, durationFromStartUntilNow)
            } else {
                state.ropesRequestState = .finished(durationFromStartUntilNow)
            }

            // Close out metrics for any inflight subrequests
            for (spanId, var subrequest) in state.subrequests {
                subrequest.endWithConnectionClose(
                    durationFromConnectionStartUntilNow: durationFromStartUntilNow,
                    error: error
                )
                state.subrequests[spanId] = subrequest
            }
        }

        self.signposter.endInterval("FullTrustedRequest", self.fullRequestInterval)

        // Emit all SubrequestMetrics
        let subrequestMetrics = self.state.withLock { state in
            state.subrequests.values.map { subrequestState in
                return SubrequestMetric(
                    eventTime: subrequestState.eventTime(connectionStartTime: self.startDate) ?? self.startDate,
                    bundleID: self.bundleID,
                    environment: self.environment,
                    systemInfo: self.systemInfo,
                    featureID: self.featureID,
                    originatingBundleID: self.originatingBundleID,
                    locale: self.locale,
                    clientRequestId: self.requestIDForEventReporting,
                    subrequestState: subrequestState
                )
            }
        }
        for subrequestMetric in subrequestMetrics {
            self.eventStreamContinuation.yield(.exportMetric(subrequestMetric))
        }

        // Then emit the TrustedRequestMetric
        let requestEvent = self.makeFullRequestMetrics()
        self.eventStreamContinuation.yield(.exportMetric(requestEvent))

        await self.logOSLogAndBiomeStreamRequestLog()
    }

    func observeAuthTokenFetch<Success: Sendable>(_ closure: () async throws -> Success) async throws -> Success {
        let result = await self.signposter.withIntervalSignpost("FetchOTT", id: self.signpostID) {
            await Result(asyncCatching: closure)
        }

        let duration = self.startInstant.duration(to: self.clock.now)
        // need to get a copy here, as we don't want to enforce that Success is Sendable.
        // `withLock` enforces a Sendable closure for whatever reason.
        self.state.withLock {
            switch result {
            case .success:
                $0.authTokenFetchState = .succeeded(duration)
            case .failure(let error):
                // If there is a failure to fetch the tokens, we want to know why for
                // this telemetry. The outer error will show in the trusted request failure.
                if let trustedRequestError = error as? TrustedRequestError {
                    $0.authTokenFetchState = .failed(trustedRequestError.selfOrFirstUnderlying, duration)
                } else {
                    $0.authTokenFetchState = .failed(error, duration)
                }
            }
        }
        return try result.get()
    }

    /// Observes an auth token fetch for a subrequest.
    func observeSubrequestAuthTokenFetch<Success: Sendable>(
        subrequestId: UInt64,
        _ closure: () async throws -> Success
    ) async throws -> Success {
        guard let spanId = SpanID(rawValue: UInt64(subrequestId)) else {
            logger.warning("\(self.logPrefix) Invalid subrequestId \(subrequestId), cannot create SpanID")
            return try await closure()
        }

        let startDuration = self.startInstant.duration(to: self.clock.now)
        let result = await self.signposter.withIntervalSignpost("FetchOTT", id: self.signpostID) {
            await Result(asyncCatching: closure)
        }
        let finishDuration = self.startInstant.duration(to: self.clock.now)

        self.state.withLock { state in
            var subrequest = state.getOrCreateSubrequestState(
                subrequestId: spanId,
                durationFromStartUntilTimebase: startDuration
            )

            let startTime = startDuration - subrequest.durationFromStartUntilTimebase
            let finishTime = finishDuration - subrequest.durationFromStartUntilTimebase
            switch result {
            case .success:
                subrequest.authTokenFetchState = .succeeded(startTime: startTime, finishTime: finishTime)
            case .failure(let error):
                subrequest.authTokenFetchState = .failed(startTime: startTime, finishTime: finishTime, error: error)
            }
            state.subrequests[spanId] = subrequest
        }

        return try result.get()
    }

    func nodeSelected(ohttpContext: Int) {
        self.state.withLock {
            $0.selectedNodeOHTTPContext = ohttpContext
        }
    }

    // MARK: - Data streams calls

    func observeAuthTokenSend<Success: Sendable>(_ closure: () async throws -> Success) async throws -> Success {
        let result = await Result(asyncCatching: closure)
        let durationSinceStartTillTokenGrantingTokenSent = self.startInstant.duration(to: self.clock.now)
        self.state.withLock {
            switch result {
            case .success:
                $0.authTokenSendState = .succeeded(durationSinceStartTillTokenGrantingTokenSent)
                $0.dataStreamState = .authTokenSent
            case .failure(let error):
                $0.authTokenSendState = .failed(error, durationSinceStartTillTokenGrantingTokenSent)
                $0.dataStreamState = .failed(error)
            }
        }

        if result.isSuccess {
            self.signposter.emitEvent("OTTSent", id: self.signpostID)
            logger.log("\(self.logPrefix) Sent auth message on data stream")
        }

        return try result.get()
    }

    func readyForMoreChunks() {
        let duration = self.startInstant.duration(to: self.clock.now)
        self.state.withLock {
            switch $0.dataStreamState {
            case .initialized, .authTokenSent:
                $0.dataStreamState = .readyForMoreChunks(bytesSent: 0)
                $0.durationFromStartUntilReadyForMoreChunks = duration
            case .awaitingForReadyForMoreChunks(let bytesSent):
                $0.dataStreamState = .readyForMoreChunks(bytesSent: bytesSent)
                $0.durationFromStartUntilReadyForMoreChunks = duration
            case .finished:
                // it can happen that we get a readyForMoreChunks _after_ the data stream has finished.
                // this happens in scenarios where we are able to send the complete payload within
                // the initial budget
                $0.durationFromStartUntilReadyForMoreChunks = duration

            case .readyForMoreChunks, .failed:
                break
            }
        }
        self.signposter.emitEvent("ReadyForMoreChunks", id: self.signpostID)
        logger.log("\(self.logPrefix) readyForMoreChunks received")
    }

    /// Records the receipt of outgoing user data from the adopter over XPC.
    func receivedOutgoingUserData(outgoingUserData: OutgoingUserData) {
        let durationSinceStartTillNow = self.startInstant.duration(to: self.clock.now)

        self.signposter.emitEvent("ReceivedOutgoingUserDataChunk", id: self.signpostID)

        switch outgoingUserData {
        case .openSubrequest(let subrequestId, let priority, _):
            guard let spanId = SpanID(rawValue: UInt64(subrequestId)) else {
                logger.warning("\(self.logPrefix) Invalid subrequestId \(subrequestId), cannot create SpanID")
                return
            }

            self.state.withLock { state in
                var subrequest = state.getOrCreateSubrequestState(
                    subrequestId: spanId,
                    durationFromStartUntilTimebase: durationSinceStartTillNow
                )

                subrequest.priority = priority
                subrequest.durationFromTimebaseUntilOpenEnqueued = durationSinceStartTillNow - subrequest.durationFromStartUntilTimebase
                state.subrequests[spanId] = subrequest
            }
            logger.debug("\(self.logPrefix) openSubrequest enqueued subrequestId=\(subrequestId)")

        case .subrequestData(let subrequestId, _):
            guard let spanId = SpanID(rawValue: UInt64(subrequestId)) else {
                logger.warning("\(self.logPrefix) Invalid subrequestId \(subrequestId), cannot create SpanID")
                return
            }

            self.state.withLock { state in
                var subrequest = state.getOrCreateSubrequestState(
                    subrequestId: spanId,
                    durationFromStartUntilTimebase: durationSinceStartTillNow
                )

                if subrequest.durationFromTimebaseUntilFirstDataEnqueued == nil {
                    let relativeToTimebase = durationSinceStartTillNow - subrequest.durationFromStartUntilTimebase
                    subrequest.durationFromTimebaseUntilFirstDataEnqueued = relativeToTimebase
                }
                state.subrequests[spanId] = subrequest
            }
        case .data, .closeSubrequest, .cancelSubrequest, .final:
            break
        }
    }

    /// Records the completion of writing outgoing user data to the network.
    func wroteOutgoingUserData(outgoingUserData: OutgoingUserData, inBudget: Bool) {
        let durationSinceStartTillNow = self.startInstant.duration(to: self.clock.now)

        self.state.withLock { state in
            switch outgoingUserData {
            case .openSubrequest(let subrequestId, _, _):
                guard let spanId = SpanID(rawValue: UInt64(subrequestId)) else {
                    logger.warning("\(self.logPrefix) Invalid subrequestId \(subrequestId), cannot create SpanID")
                    return
                }
                var subrequest = state.getOrCreateSubrequestState(
                    subrequestId: spanId,
                    durationFromStartUntilTimebase: durationSinceStartTillNow
                )

                let relativeToTimebase = durationSinceStartTillNow - subrequest.durationFromStartUntilTimebase
                subrequest.durationFromTimebaseUntilOpenWritten = relativeToTimebase
                subrequest.setWriteExceededInitialBudget(!inBudget)
                state.subrequests[spanId] = subrequest

            case .subrequestData(let subrequestId, _):
                guard let spanId = SpanID(rawValue: UInt64(subrequestId)) else {
                    logger.warning("\(self.logPrefix) Invalid subrequestId \(subrequestId), cannot create SpanID")
                    return
                }
                var subrequest = state.getOrCreateSubrequestState(
                    subrequestId: spanId,
                    durationFromStartUntilTimebase: durationSinceStartTillNow
                )

                let relativeToTimebase = durationSinceStartTillNow - subrequest.durationFromStartUntilTimebase
                if subrequest.durationFromTimebaseUntilFirstDataWritten == nil {
                    subrequest.durationFromTimebaseUntilFirstDataWritten = relativeToTimebase
                }
                subrequest.durationFromTimebaseUntilLastDataWritten = relativeToTimebase
                subrequest.setWriteExceededInitialBudget(!inBudget)
                state.subrequests[spanId] = subrequest

            case .closeSubrequest(let subrequestId):
                guard let spanId = SpanID(rawValue: UInt64(subrequestId)) else {
                    logger.warning("\(self.logPrefix) Invalid subrequestId \(subrequestId), cannot create SpanID")
                    return
                }
                var subrequest = state.getOrCreateSubrequestState(
                    subrequestId: spanId,
                    durationFromStartUntilTimebase: durationSinceStartTillNow
                )

                let relativeToTimebase = durationSinceStartTillNow - subrequest.durationFromStartUntilTimebase
                subrequest.durationFromTimebaseUntilCloseWritten = relativeToTimebase
                subrequest.setWriteExceededInitialBudget(!inBudget)
                state.subrequests[spanId] = subrequest

            case .data, .cancelSubrequest, .final:
                break
            }
        }
    }

    /// Records the receipt of incoming user data from the server.
    func receivedIncomingUserData(incomingUserData: IncomingUserData) {
        let durationSinceStartTillNow = self.startInstant.duration(to: self.clock.now)

        self.state.withLock { state in
            switch incomingUserData {
            case .openSubresponse(let subrequestId):
                guard let spanId = SpanID(rawValue: UInt64(subrequestId)) else {
                    logger.warning("\(self.logPrefix) Invalid subrequestId \(subrequestId), cannot create SpanID")
                    return
                }
                var subrequest = state.getOrCreateSubrequestState(
                    subrequestId: spanId,
                    durationFromStartUntilTimebase: durationSinceStartTillNow
                )

                let relativeToTimebase = durationSinceStartTillNow - subrequest.durationFromStartUntilTimebase
                subrequest.durationFromTimebaseUntilOpenResponseReceived = relativeToTimebase
                state.subrequests[spanId] = subrequest

            case .subresponseData(let subrequestId, _):
                guard let spanId = SpanID(rawValue: UInt64(subrequestId)) else {
                    logger.warning("\(self.logPrefix) Invalid subrequestId \(subrequestId), cannot create SpanID")
                    return
                }
                var subrequest = state.getOrCreateSubrequestState(
                    subrequestId: spanId,
                    durationFromStartUntilTimebase: durationSinceStartTillNow
                )

                let relativeToTimebase = durationSinceStartTillNow - subrequest.durationFromStartUntilTimebase
                if subrequest.durationFromTimebaseUntilFirstResponseDataReceived == nil {
                    subrequest.durationFromTimebaseUntilFirstResponseDataReceived = relativeToTimebase
                }
                subrequest.durationFromTimebaseUntilLastResponseDataReceived = relativeToTimebase

                state.subrequests[spanId] = subrequest

            case .closeSubresponse(let subrequestId, let status):
                guard let spanId = SpanID(rawValue: UInt64(subrequestId)) else {
                    logger.warning("\(self.logPrefix) Invalid subrequestId \(subrequestId), cannot create SpanID")
                    return
                }
                var subrequest = state.getOrCreateSubrequestState(
                    subrequestId: spanId,
                    durationFromStartUntilTimebase: durationSinceStartTillNow
                )

                subrequest.endWithServerClose(
                    durationFromConnectionStartUntilNow: durationSinceStartTillNow,
                    responseStatus: status
                )
                state.subrequests[spanId] = subrequest

            case .data:
                break
            }
        }
    }

    func observeDataWrite<Success: Sendable>(
        bytesToSend: Int,
        inBudget: Bool = true,
        _ closure: () async throws -> Success
    ) async throws -> Success {
        let result = await Result(asyncCatching: closure)
        let durationSinceStartTillNow = self.startInstant.duration(to: self.clock.now)
        self.state.withLock {
            var isFirstWrite: Bool = false
            switch result {
            case .success:
                switch $0.dataStreamState {
                case .initialized:
                    fatalError("Invalid state: \($0.dataStreamState). Auth token must be sent first!")
                case .authTokenSent:
                    $0.dataStreamState = .awaitingForReadyForMoreChunks(bytesSent: bytesToSend)
                    isFirstWrite = true

                case .awaitingForReadyForMoreChunks(let bytesSent):
                    $0.dataStreamState = .awaitingForReadyForMoreChunks(bytesSent: bytesSent + bytesToSend)

                case .readyForMoreChunks(let bytesSent):
                    $0.dataStreamState = .readyForMoreChunks(bytesSent: bytesSent + bytesToSend)
                    isFirstWrite = bytesSent == 0

                case .finished, .failed:
                    break  // invalid call, but we don't want to crash here!
                }

                if isFirstWrite {
                    $0.firstChunkSentState = .succeeded(durationSinceStartTillNow, withinBudget: inBudget)
                }

            case .failure(let failure):
                switch $0.dataStreamState {
                case .initialized, .authTokenSent, .awaitingForReadyForMoreChunks, .readyForMoreChunks:
                    $0.dataStreamState = .failed(failure)
                case .finished, .failed:
                    break
                }
            }
        }

        return try result.get()
    }

    func dataStreamFinished() {
        let durationSinceStartTillNow = self.startInstant.duration(to: self.clock.now)
        self.state.withLock {
            switch $0.dataStreamState {
            case .initialized:
                fatalError("Invalid state: \($0.dataStreamState). Auth token must be sent first!")
            case .authTokenSent:
                $0.dataStreamState = .finished(bytesSent: 0)
                $0.durationFromStartUntilLastPayloadChunkSent = durationSinceStartTillNow

            case .awaitingForReadyForMoreChunks(let bytesSent):
                // it can happen that we finish the data stream _before_ we got a readyForMoreChunks.
                // this happens in scenarios where we are able to send the complete payload within
                // the initial budget
                $0.dataStreamState = .finished(bytesSent: bytesSent)
                $0.durationFromStartUntilLastPayloadChunkSent = durationSinceStartTillNow

            case .readyForMoreChunks(let bytesSent):
                $0.dataStreamState = .finished(bytesSent: bytesSent)
                $0.durationFromStartUntilLastPayloadChunkSent = durationSinceStartTillNow

            case .finished, .failed:
                break  // invalid call, but we don't want to crash here!
            }
        }
    }

    // MARK: - Node stream calls

    func observeLoadAttestationsFromCache(closure: () async -> [ValidatedAttestationOrAttestation]) async -> [ValidatedAttestationOrAttestation] {
        let result = await self.signposter.withIntervalSignpost("LoadAttestationsFromCache", id: self.signpostID) {
            await Result(asyncCatching: closure)
        }

        self.state.withLock { state in
            switch result {
            case .success(let attestations):
                for attestation in attestations {
                    switch attestation {
                    case .inlineAttestation(let attestation, let ohttpContext):
                        if let bundle = attestation.attestationBundle {
                            state.nodes[attestation.nodeID] = .init(
                                state: .unverified,
                                nodeID: attestation.nodeID,
                                attestationBundleRef: .data(bundle),
                                ohttpContext: UInt64(ohttpContext),
                                cloudOSVersion: attestation.cloudOSVersion,
                                cloudOSReleaseType: attestation.cloudOSReleaseType,
                                maybeValidatedCellID: attestation.unvalidatedCellID,
                                ensembleID: attestation.ensembleID
                            )
                        } else {
                            logger.error("bundle missing for attestation: \(attestation.nodeID)")
                        }
                    case .cachedValidatedAttestation(let validatedAttestation, let ohttpContext):
                        state.nodes[validatedAttestation.attestation.nodeID] = .init(
                            state: .verified,
                            nodeID: validatedAttestation.attestation.nodeID,
                            attestationBundleRef: .lookupInDatabase,
                            ohttpContext: UInt64(ohttpContext),
                            cloudOSVersion: validatedAttestation.attestation.cloudOSVersion,
                            cloudOSReleaseType: validatedAttestation.attestation.cloudOSReleaseType,
                            maybeValidatedCellID: validatedAttestation.validatedCellID,
                            ensembleID: validatedAttestation.attestation.ensembleID
                        )
                    }
                }
            }
        }

        return result.get()
    }

    func attestationsReceived(_ attestations: some (Collection<ValidatedAttestationOrAttestation> & Sendable)) {
        let duration = self.startInstant.duration(to: self.clock.now)
        let count = attestations.count
        let maybeAttestationActivity = self.state.withLock { state -> NWActivity? in
            var result: NWActivity? = nil
            switch state.attestationsReceivedState {
            case .noAttestationReceived:
                state.attestationsReceivedState = .receivedAttestations(count: count, durationSinceStart: duration)
            case .receivedAttestations(let existing, let durationSinceStart):
                state.attestationsReceivedState = .receivedAttestations(count: existing + count, durationSinceStart: durationSinceStart)
            }

            switch state.ropesRequestState {
            case .responseHeadReceived(let attestationsActivity):
                // expected case
                state.ropesRequestState = .attestationsReceived
                result = attestationsActivity

            case .attestationsReceived:
                // expected case. nothing to do. got a second attestation message
                break

            case .waitingForConnection(let attestationsActivity), .requestSent(let attestationsActivity):
                // unexpected case. but we should not crash here!
                state.ropesRequestState = .attestationsReceived
                result = attestationsActivity

            case .initialized, .finished, .failed:
                // unexpected case. nothing to do
                break
            }

            for attestation in attestations {
                switch attestation {
                case .cachedValidatedAttestation:
                    // We will never receive validated attestations
                    logger.error("Received unexpected validated attestation nodeID: \(attestation.identifier)")
                    break

                case .inlineAttestation(let attestation, let ohttpContext):
                    guard state.nodes[attestation.nodeID] == nil else { continue }
                    if let bundle = attestation.attestationBundle {
                        state.nodes[attestation.nodeID] = .init(
                            state: .unverified,
                            nodeID: attestation.nodeID,
                            attestationBundleRef: .data(bundle),
                            ohttpContext: UInt64(ohttpContext),
                            cloudOSVersion: attestation.cloudOSVersion,
                            cloudOSReleaseType: attestation.cloudOSReleaseType,
                            maybeValidatedCellID: attestation.unvalidatedCellID,
                            ensembleID: attestation.ensembleID
                        )
                    } else {
                        logger.error("bundle missing for attestation: \(attestation.nodeID)")
                    }
                }
            }
            return result
        }
        self.signposter.emitEvent("AttestationsReceivedFromRopes", id: self.signpostID)
        maybeAttestationActivity?.complete(reason: .success)
    }

    func proxiedAttestationReceived(proxiedAttestation: ProxiedAttestation, proxiedBy: String) {
        self.state.withLock { state in
            state.proxiedNodes.append(
                .init(
                    nodeID: proxiedAttestation.nodeID,
                    attestationBundle: proxiedAttestation.attestationBundle,
                    proxiedBy: proxiedBy
                )
            )
        }
    }

    func executionAssetReceived(_ assetMetadata: AssetMetadata) {
        self.state.withLock { state in
            state.executionAssets.append(assetMetadata)
        }
    }

    func inlineAttestationsValidated(_ udids: [String]) {
        self.eventStreamContinuation.yield(.nodesReceived(udids: udids, fromSource: .request))
    }

    func noFurtherAttestations() {
        let maybeAttestationActivity = self.state.withLock { state -> NWActivity? in
            switch state.ropesRequestState {
            case .responseHeadReceived(let attestationsActivity):
                // expected case. got no attestations from ROPES. Cache was sufficient.
                state.ropesRequestState = .attestationsReceived
                return attestationsActivity

            case .attestationsReceived:
                // expected case. got attestations before. Cache was insufficient.
                return nil

            case .waitingForConnection(let attestationsActivity), .requestSent(let attestationsActivity):
                // unexpected case. but we should not crash here!
                state.ropesRequestState = .attestationsReceived
                return attestationsActivity

            case .initialized, .finished, .failed:
                // unexpected case. nothing to do
                return nil
            }
        }
        maybeAttestationActivity?.complete(reason: .success)
    }

    func observeAttestationVerify(nodeID: String, closure: () async throws -> ValidatedAttestation) async throws -> ValidatedAttestation {
        self.state.withLock { state in
            guard var value = state.nodes[nodeID] else { return }
            value.state = .verifying
            state.nodes[nodeID] = value
        }

        // We are verifying attestations in parallel, so we need to create one signpostID for each verification.
        let attestationSignpostID = self.signposter.makeSignpostID()
        let startTime = self.clock.now
        let result = await self.signposter.withIntervalSignpost("VerifyAttestation", id: attestationSignpostID) {
            await Result(asyncCatching: closure)
        }
        let duration = startTime.duration(to: self.clock.now)

        self.state.withLock { state in
            guard var value = state.nodes[nodeID] else { return }
            guard case .verifying = value.state else { return }

            switch result {
            case .success:
                value.state = .verified
            case .failure(let error):
                value.state = .verifiedFailed(error)
            }

            state.nodes[nodeID] = value
        }

        if case .failure(let error) = result {
            // report a separate event for the error
            let errorMetric = AttestationVerificationErrorMetric(
                eventTime: .now,
                clientRequestId: self.requestIDForEventReporting,
                bundleID: self.bundleID,
                environment: self.environment,
                systemInfo: self.systemInfo,
                locale: self.locale,
                // this is false because we are on request flow here
                isPrefetchedAttestation: false,
                nodeID: nodeID,
                error: error,
                attestationVerificationTime: duration,
                featureID: featureID
            )

            self.eventStreamContinuation.yield(.exportMetric(errorMetric))
        }

        let verificationMetric = AttestationVerificationMetric(
            eventTime: .now,
            bundleID: self.bundleID,
            clientRequestId: self.requestIDForEventReporting,
            environment: self.environment,
            systemInfo: self.systemInfo,
            featureID: self.featureID,
            locale: self.locale,
            attestationVerificationTime: duration,
            verificationResult: result,
            nodeID: nodeID
        )
        self.eventStreamContinuation.yield(.exportMetric(verificationMetric))

        return try result.get()
    }

    func observeSendingKeyToNode(nodeID: String, _ closure: () async throws -> Void) async throws {
        let result = await Result(asyncCatching: closure)

        let kDataSendMetrics = KDataSendMetric(
            eventTime: .now,
            clientRequestId: self.requestIDForEventReporting,
            environment: self.environment,
            systemInfo: self.systemInfo,
            bundleID: self.bundleID,
            featureID: self.featureID,
            locale: self.locale,
            result: result,
            nodeID: nodeID
        )

        self.eventStreamContinuation.yield(.exportMetric(kDataSendMetrics))

        guard result.isSuccess else { return }
        let duration = self.startInstant.duration(to: self.clock.now)
        let firstKeySent = self.state.withLock { state -> Bool in
            guard var value = state.nodes[nodeID] else { return false }
            guard case .verified = value.state else { return false }
            value.state = .sentKey
            state.nodes[nodeID] = value

            // update kDataSendState to record how many keys are we sending to and when did we send the first key
            var newKDataSendState = state.kDataSendState
            switch state.kDataSendState {
            case .notSend:
                newKDataSendState = .sent(duration: duration, count: 1)
            case .sent(let firstSentDuration, let count):
                // just increase the counter
                newKDataSendState = .sent(duration: firstSentDuration, count: count + 1)
            }
            state.kDataSendState = newKDataSendState

            switch state.responseState {
            case .initialized:
                // invalid state. don't crash though
                return false

            case .waitingToSendFirstKey(let firstTokenActivity):
                let interval = self.signposter.beginInterval("SentKey", id: self.signpostID)
                state.responseState = .waitingForNode(firstTokenActivity: firstTokenActivity, interval: interval)
                return true

            case .waitingForNode, .receiving, .finished, .failed:
                // we sent the key to another node first
                return false
            }
        }

        self.signposter.emitEvent("SentKeyToNode", id: self.signpostID)
        if firstKeySent {
            logger.log("\(self.logPrefix) First key sent to node.")
        }
    }

    func nodeFirstResponseReceived(nodeID: String) {
        self.state.withLock { state in
            guard var value = state.nodes[nodeID] else { return }
            guard case .sentKey = value.state else { return }
            value.state = .receiving(summaryReceived: false, bytesReceived: 0)
            state.nodes[nodeID] = value
        }
    }

    func nodeSummaryReceived(nodeID: String, error: (any Error)?) {
        reportNodeResponseMetric(nodeID: nodeID, error: error)
        guard error == nil else { return }

        self.state.withLock { state in
            guard var value = state.nodes[nodeID] else { return }
            guard case .receiving(false, let bytesReceived) = value.state else { return }
            value.state = .receiving(summaryReceived: true, bytesReceived: bytesReceived)
            state.nodes[nodeID] = value
        }
    }

    private func reportNodeResponseMetric(nodeID: String, error: (any Error)?) {
        let endpointResponseMetric = TrustedEndpointResponseMetric(
            eventTime: .now,
            bundleID: self.bundleID,
            clientRequestId: self.requestIDForEventReporting,
            environment: self.environment,
            systemInfo: self.systemInfo,
            featureID: self.featureID,
            locale: self.locale,
            nodeID: nodeID,
            error: error
        )

        self.eventStreamContinuation.yield(.exportMetric(endpointResponseMetric))
    }

    private enum ResponsePayloadReceivedAction {
        case endActivityAndEndInterval(NWActivity, OSSignpostIntervalState, intervalName: StaticString)
    }

    /// Pass in `nodeID` if response is coming on the node's stream. If the response is coming on response bypass
    /// stream, then `nodeID` should be `nil`.
    func responsePayloadReceived(bytes: Int, nodeID: String? = nil) {
        let followUpAction = self.state.withLock { state -> ResponsePayloadReceivedAction? in
            if let nodeID {
                guard var value = state.nodes[nodeID] else { return nil }
                guard case .receiving(let summaryReceived, let bytesReceived) = value.state else { return nil }
                value.state = .receiving(summaryReceived: summaryReceived, bytesReceived: bytesReceived + bytes)
                state.nodes[nodeID] = value
            }

            let duration = self.startInstant.duration(to: self.clock.now)

            if state.durationFromStartUntilFirstToken == nil {
                // we have now received our first token
                state.durationFromStartUntilFirstToken = duration
            }

            state.durationFromStartUntilLastResponseChunk = duration

            switch state.responseState {
            case .waitingForNode(let firstTokenActivity, let interval):
                let receivingInterval = self.signposter.beginInterval("Response", id: signpostID)
                state.responseState = .receiving(bytesReceived: bytes, interval: receivingInterval)
                return .endActivityAndEndInterval(firstTokenActivity, interval, intervalName: "SentKey")

            case .waitingToSendFirstKey:
                // unexpected! but we don't want to crash here!
                return nil

            case .receiving(let bytesReceived, let interval):
                state.responseState = .receiving(bytesReceived: bytesReceived + bytes, interval: interval)
                return nil

            case .initialized, .finished, .failed:
                return nil
            }
        }

        switch followUpAction {
        case .none:
            break
        case .endActivityAndEndInterval(let activity, let interval, let intervalName):
            activity.complete(reason: .success)
            self.signposter.endInterval(intervalName, interval)
        }
    }

    func nodeRequestExecutionLogFinalized(nodeID: String) {
        self.state.withLock { state in
            guard var value = state.nodes[nodeID] else { return }
            value.requestExecutionLogFinalized = true
            state.nodes[nodeID] = value
        }
    }

    func nodeResponseFinished(nodeID: String) {
        self.state.withLock { state in
            guard var value = state.nodes[nodeID] else { return }
            guard case .receiving(let summaryReceived, let bytesReceived) = value.state else { return }
            value.state = .finished(summaryReceived: summaryReceived, bytesReceived: bytesReceived)
            state.nodes[nodeID] = value
        }
    }

    func responsePayloadReceiveFinished() {
        let receiveInterval = self.state.withLock { state -> OSSignpostIntervalState? in
            switch state.responseState {
            case .initialized, .waitingToSendFirstKey, .waitingForNode, .finished, .failed:
                // invalid states! Don't crash though!
                return nil

            case .receiving(let bytesReceived, let interval):
                state.responseState = .finished(bytesReceived: bytesReceived)
                return interval
            }
        }

        if let receiveInterval {
            self.signposter.endInterval("Response", receiveInterval)
        }
    }

    func nodeStreamsFinished() {
        let duration = self.startInstant.duration(to: self.clock.now)
        self.state.withLock { state in
            state.durationFromStartUntilNodeStreamsFinished = duration
        }
    }

    func responseBypassStreamFinished() {
        let duration = self.startInstant.duration(to: self.clock.now)
        self.state.withLock { state in
            state.durationFromStartUntilResponseBypassFinished = duration
        }
    }

    func gatewayStreamFinished() {
        let duration = self.startInstant.duration(to: self.clock.now)
        self.state.withLock { state in
            state.durationFromStartUntilGatewayStreamFinished = duration
        }
    }

    private enum ResponseReceiveFailedAction: Sendable {
        case failActivity(NWActivity)
        case failActivityAndEndInterval(NWActivity, OSSignpostIntervalState, intervalName: StaticString)
        case endInterval(OSSignpostIntervalState, intervalName: StaticString)
    }

    func responseReceivingFailed(error: any Error) {
        let action = self.state.withLock { state -> ResponseReceiveFailedAction? in
            // If there is a TrustedRequestError in attestation validation, we want to know
            // what happened in this telemetry. In that case, the outer error will show
            // the trusted request failure.
            let trustedRequestError = error as? TrustedRequestError
            let error = trustedRequestError?.selfOrFirstUnderlying ?? error

            switch state.responseState {
            case .initialized:
                state.responseState = .failed(error)
                return nil
            case .waitingToSendFirstKey(let firstTokenActivity):
                state.responseState = .failed(error)
                return .failActivity(firstTokenActivity)
            case .waitingForNode(let firstTokenActivity, let interval):
                state.responseState = .failed(error)
                return .failActivityAndEndInterval(firstTokenActivity, interval, intervalName: "SentKey")
            case .receiving(_, let interval):
                state.responseState = .failed(error)
                return .endInterval(interval, intervalName: "ReceivingResponse")
            case .finished, .failed:
                return nil
            }
        }

        switch action {
        case .none:
            break
        case .endInterval(let interval, let intervalName):
            self.signposter.endInterval(intervalName, interval)
        case .failActivity(let activity):
            activity.complete(reason: .failure)
        case .failActivityAndEndInterval(let activity, let interval, let intervalName):
            activity.complete(reason: .failure)
            self.signposter.endInterval(intervalName, interval)
        }
    }

    // MARK: - TrustedRequestXPCEventsObserver

    func willCancel(reason: TrustedRequestCancellationReason) {
        self.state.withLock {
            $0.cancellationReason = reason
        }
    }

    func createSubrequestFailed(subrequest: XPCSubrequest, error: PrivateCloudComputeError) {
        // TODO: rdar://166639044 (Report telemetry on subrequests discarded by pccd)
    }

    // MARK: - Private Method -

    private func logOSLogAndBiomeStreamRequestLog() async {
        // log the metadata associated with this request for researcher logs:
        // 1. all the request parameters {model, arguments}
        // 2. a deserialization of all attestations, including failed nodes
        //    this is provided by CloudAttestation

        if !TransparencyReport().enabled {
            logger.log("\(self.logPrefix) Request Log: TransparencyReport is not enabled")
            return
        }

        logger.log("\(self.logPrefix) Request Log: workload type: \(self.parameters.type)")
        logger.log("\(self.logPrefix) Request Log: workload parameters: \(self.parameters.parameters)")

        let nodes = self.state.withLock(\.nodes)

        // Load bundles from store
        var bundles: [String: Data] = [:]
        if let store = self.attestationStore {
            bundles = await store.getAttestationBundlesUsedByTrustedRequest(serverRequestID: self.serverRequestID)
        }

        var biomeAttestations: [PrivateCloudComputeRequestLog.Attestation] = []
        biomeAttestations.reserveCapacity(nodes.count)
        for (key, node) in nodes {
            var attestationString: String = ""
            switch node.attestationBundleRef {
            case .lookupInDatabase:
                if let bundle = bundles[node.nodeID] {
                    attestationString = bundle.base64EncodedString()
                }
            case .data(let bundle):
                attestationString = bundle.base64EncodedString()
            }

            let validatedString =
                switch node.state {
                case .unverified, .verifying, .verifiedFailed:
                    "Unvalidated"
                case .verified,
                    .sentKey,
                    .receiving,
                    .finished:
                    "Validated"
                }
            logger.log("\(self.logPrefix) Request Log: Attestation: \(key) \(node.state) <\(validatedString) \(node.nodeID): \(attestationString)>")

            var biomeAttestation: PrivateCloudComputeRequestLog.Attestation = .init()
            biomeAttestation.node = node.nodeID
            biomeAttestation.nodeState = validatedString
            biomeAttestation.attestationBundle = attestationString
            biomeAttestation.requestExecutionLogFinalized = node.requestExecutionLogFinalized
            biomeAttestations.append(biomeAttestation)
        }

        let proxiedNodes = self.state.withLock(\.proxiedNodes)
        for node in proxiedNodes {
            let attestationString = node.attestationBundle.base64EncodedString()
            logger.log("\(self.logPrefix) Request Log: Proxied Attestation: <\(node.nodeID): \(attestationString)>")

            var biomeAttestation: PrivateCloudComputeRequestLog.Attestation = .init()
            biomeAttestation.node = node.nodeID
            biomeAttestation.attestationBundle = attestationString
            biomeAttestation.proxiedBy = node.proxiedBy
            biomeAttestations.append(biomeAttestation)
        }

        let assetMetadata = self.state.withLock(\.executionAssets)

        var biomeAssets: [PrivateCloudComputeRequestLog.AssetMetadata] = []
        biomeAssets.reserveCapacity(assetMetadata.count)
        for asset in assetMetadata {
            logger.log("\(self.logPrefix) Request Log: Asset Metadata: <\(asset.applicationId) \(asset.assetId) \(asset.version) \(asset.hash)>")
            var biomeAsset: PrivateCloudComputeRequestLog.AssetMetadata = .init()
            biomeAsset.applicationId = asset.applicationId
            biomeAsset.assetId = asset.assetId
            biomeAsset.assetVersion = asset.version
            biomeAsset.assetHash = asset.hash
            biomeAssets.append(biomeAsset)
        }

        // Log the request parameters to Biome stream
        do {
            let workloadParametersAsJSON = try self.encoder.encode(self.parameters.parameters)
            let workloadParametersAsString = String(data: workloadParametersAsJSON, encoding: .utf8) ?? ""
            let event = PrivateCloudComputeRequestLog.with {
                // The Biome stream gets the clientRequestID.
                $0.requestId = self.clientRequestID.uuidString
                $0.timestamp = Date()
                $0.pipelineKind = self.parameters.type
                $0.pipelineParameters = workloadParametersAsString
                $0.nodes = biomeAttestations
                $0.assets = biomeAssets
            }

            try self.biomeReporter.send(requestLog: event)
        } catch {
            logger.error("Biome event logging failed, error=\(error)")
        }
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        switch self {
        case .success: true
        case .failure: false
        }
    }

    fileprivate var maybeError: Failure? {
        switch self {
        case .success: nil
        case .failure(let failure): failure
        }
    }
}

extension OSSignposter {
    func withIntervalSignpost<T>(
        _ name: StaticString,
        id: OSSignpostID = .exclusive,
        around task: () async throws -> T
    ) async rethrows -> T {
        let interval = self.beginInterval(name, id: id)
        defer { self.endInterval(name, interval) }
        return try await task()
    }
}

extension TrustedRequestCancellationReason {
    var telemetryString: EventValue {
        EventValue.string("\(self)")
    }
}
