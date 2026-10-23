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

// Don't add any dependencies here to CloudBoard itself except static libraries
internal import CloudAttestation
internal import Crypto
@_spi(HPKEAlgID) import CryptoKit
internal import DequeModule
import Foundation
internal import HTTPClientStateMachine
internal import InternalGRPC
internal import InternalSwiftProtobuf
internal import LengthPrefixChunking
internal import NIOCore
internal import Synchronization
import os

public enum LocalCloudBoardGRPCClientError: Error {
    case invalidPrivateCloudComputeResponse
    case invalidUUIDInCloudComputeResponse
    case noChunkInStreamResponse
    case unknownKeyType(String)
    case failedToParseCloudAttestationBundle(Error)
    case proxyClientNotSet
    case proxyToComputeDEKInvalid
    case invalidComputeNodeMessage
    case invalidAeadType
    case failedToGetBypassDecapsulator
    case requestChunkFromProxyWhenRequestBypassConfigured
    case tooManyConcurrentOperations
    case expectedRequestToForwardBypassedRequestChunks
    case proxyInternalError
    case incompleteInfoForCreatingRequestExecutionLogEntry
    case invalidEndpointProvidedForFetchingAttestation
}

public enum ApplicationDataChunkingConfiguration: Sendable {
    case disabled
    case enabled(chunkSize: Int)
}

@available(*, deprecated, renamed: "LocalCloudBoardGRPCClientProxyWorkflowError")
public enum LocalCloudBoardGRPCClientFindWorkerError: Sendable {
    public static let unknownWorkload: UInt32 = 4000
}

/// The error codes below are the same as what ROPES sends back as RopesStatus to the client.
public enum LocalCloudBoardGRPCClientProxyWorkflowError: UInt32, Sendable {
    /// At the moment when failing to find worker we return unknown workload
    case unknownWorkload = 4000
    case nodesBusy = 4002
    case cloudBoardUnknownError = 5002
    case cloudBoardResourceExhausted = 5008
    case cloudBoardInternalError = 5013
    case internalServerError = 6000
}

extension LocalCloudBoardGRPCClientProxyWorkflowError {
    // Best effort to align with ROPES' mapping
    static func fromGRPCCode(_ code: GRPCStatus.Code) -> LocalCloudBoardGRPCClientProxyWorkflowError {
        switch code {
        case .ok:
            fatalError("GRPCStatus code for error should never be ok")
        case .internalError:
            return .cloudBoardInternalError
        case .resourceExhausted:
            return .cloudBoardResourceExhausted
        default:
            return .cloudBoardUnknownError
        }
    }
}

@available(*, deprecated, renamed: "PrivateCloudComputeResponse")
public enum PrivateCloudComputeResponseMessage {
    case responseID(UUID)
    case payload(Data)
    case summary(String)
    case requestExecutionLogEntry(RequestExecutionLogEntry)
    case attestationBundle(LocalCloudBoardAttestationBundle)
    case componentTimeMeasurement(ComponentTimeMeasurementEntry)
    case costToken
    case unknown
}

/// An enum that represents a response from CloudBoard.
public enum PrivateCloudComputeResponse: Sendable {
    /// Response ID generated and returned by CloudBoard for every request
    case responseID(UUID)
    /// UTF-8 encoded JSON representation of the attestation bundle. Should be ignored in favor of `.attestationBundle`
    case attestation(Data)
    /// Application payload chunk
    case payload(Data)
    /// being replaced by responseSummary
    case summary(String)
    /// Request summary with better fidelity
    /// you must set ``LocalCloudBoardGRPCAsyncClient/fullFidelityResponseSummary`` to receive these
    case responseSummary(summary: Translated.ResponseSummary)
    /// Request execution log entry including the compute node attestation a request has been made to
    case requestExecutionLogEntry(RequestExecutionLogEntry)
    /// Attestation bundle wrapper exposing both the raw attestation bundle and associated metadata such as the release
    /// digest
    case attestationBundle(LocalCloudBoardAttestationBundle)
    /// Time measurement for an operation from a component
    case componentTimeMeasurement(ComponentTimeMeasurementEntry)
    /// Cost token containing signed JWT with bucketized cost
    case costToken(Data)
    case unknown
}

public struct RequestExecutionLogEntry: Sendable {
    public var isNack: Bool
    public var isFinal: Bool
    public var endpoint: LocalCloudBoardGRPCAsyncClient.EndPoint
    public var trustedProxyAttestationBundle: LocalCloudBoardAttestationBundle
    public var computeNodeAttestationBundle: LocalCloudBoardAttestationBundle?
    public var assetsMetata: [LocalCloudBoardAssetMetadata]
    public var outboundCallContext: OutboundCallContext?
}

public struct LocalCloudBoardAssetMetadata: Sendable {
    public var assetID: String
    public var applicationID: String
    public var assetIdentityHash: String
    public var version: String
}

public struct ComponentTimeMeasurementEntry: Sendable, CustomStringConvertible {
    public var description: String {
        return """
        component: \(self.component),
        operation: \(self.operation),
        identifier: \(self.identifier ?? ""),
        subIdentifier: \(self.subIdentifier ?? ""),
        startTime: \(self.startTime),
        endTime: \(self.endTime)
        """
    }

    public var component: String
    public var operation: String
    public var identifier: String?
    public var subIdentifier: String?
    internal var _startTimeMs: Int64
    internal var _endTimeMs: Int64

    public var startTime: Date {
        Date(timeIntervalSince1970: Double(self._startTimeMs) / 1000.0)
    }

    public var endTime: Date {
        Date(timeIntervalSince1970: Double(self._endTimeMs) / 1000.0)
    }
}

// namespace for translated forms of the real protobuf types to avoid confusion
public enum Translated: Sendable {
    public enum ResponseStatus: Sendable, Equatable {
        case ok // = 0
        case unauthenticated // = 1
        case internalError // = 2
        case invalidRequest // = 3
        case proxyFindWorkerError // = 4
        case proxyWorkerValidationError // = 5
        case unrecognized(value: Int)
    }

    public struct ResponseSummary: Sendable {
        /// The old API exposed just this value - so we retain it in case it is needed
        public var protobufTextEncodedForm: String
        public var responseStatus: ResponseStatus

        internal init(_ responseSummary: Proto_PrivateCloudCompute_PrivateCloudComputeResponse.CloseResponsePayload) {
            self.protobufTextEncodedForm = responseSummary.textFormatString()
            self.responseStatus =
                switch responseSummary.responseStatus {
                case .ok: .ok
                case .unauthenticated: .unauthenticated
                case .internalError: .internalError
                case .invalidRequest: .invalidRequest
                case .proxyFindWorkerError: .proxyFindWorkerError
                case .proxyWorkerValidationError: .proxyWorkerValidationError
                case .UNRECOGNIZED(let value): .unrecognized(value: value)
                }
            // for now we are not bothering to expose postResponseActions
        }
    }
}

@available(*, deprecated, renamed: "LocalCloudBoardGRPCAsyncClient")
public class LocalCloudBoardGRPCClient {
    public static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LocalCloudBoardClient"
    )
    private var client: LocalCloudBoardGRPCAsyncClient

    public convenience init(host: String, port: Int) {
        self.init(host: host, port: port, attestationEnvironment: CloudAttestation.Environment.dev.rawValue)
    }

    public init(host: String, port: Int, attestationEnvironment: String) {
        self.client = LocalCloudBoardGRPCAsyncClient(
            host: host,
            port: port,
            attestationEnvironment: attestationEnvironment
        )
    }

    @available(*, deprecated, message: "Provide 'requestID' parameter explicitly")
    public func submitPrivateRequest(payload: Data) async throws
    -> AsyncThrowingStream<PrivateCloudComputeResponseMessage, Error> {
        return try await self.submitPrivateRequest(payload: payload, requestID: UUID().uuidString)
    }

    public func submitPrivateRequest(payload: Data, requestID: String) async throws
    -> AsyncThrowingStream<PrivateCloudComputeResponseMessage, Error> {
        let (outputStream, outputStreamContinuation) = AsyncThrowingStream<PrivateCloudComputeResponseMessage, Error>
            .makeStream()
        let (requestSender, responseStream) = try await client.streamPrivateRequest(requestID: requestID)
        requestSender.yield(payload)
        requestSender.finish()
        // unstructured task here is OK as on any cancellation responseStream will finish,
        // at which point we will end the output stream
        Task {
            do {
                for try await response in responseStream {
                    switch response {
                    case .attestation: ()
                    case .payload(let data): outputStreamContinuation.yield(.payload(data))
                    case .responseID(let id): outputStreamContinuation.yield(.responseID(id))
                    case .requestExecutionLogEntry(let requestExecutionLogEntry): outputStreamContinuation
                        .yield(.requestExecutionLogEntry(requestExecutionLogEntry))
                    case .summary(let summary): outputStreamContinuation.yield(.summary(summary))
                    case .responseSummary(let summary):
                        // the deprecated API can stick to the old forms
                        outputStreamContinuation.yield(.summary(summary.protobufTextEncodedForm))
                    case .attestationBundle(let attestationBundle): outputStreamContinuation
                        .yield(.attestationBundle(attestationBundle))
                    case .componentTimeMeasurement(let measurement): outputStreamContinuation
                        .yield(.componentTimeMeasurement(measurement))
                    case .costToken: outputStreamContinuation.yield(.costToken)
                    case .unknown: outputStreamContinuation.yield(.unknown)
                    }
                }
                outputStreamContinuation.finish()
            } catch {
                outputStreamContinuation.finish(throwing: error)
            }
        }

        return outputStream
    }
}

/// Information provided to allow more complex mimicry of ROPES behaviours when finding a worker.
/// Only fields that would be available and useful to ROPES to route are exposed
/// Currently unavailable: headers the client would have set, can be added if required
public struct ChooseWorkerContext: Sendable {
    public struct OriginalRequest: Sendable {
        public var requestID: String

        public var workloadType: String

        /// Workload parameters, sometimes called tags
        public var workloadParameters: [String: [String]]

        // not exposed yet - may never be needed
        // var decryptionKey: Proto_Ropes_Common_DecryptionKey
        // var tenantInfo: Proto_Ropes_Common_TenantInfo
        // var oneTimeToken: Data = Data()
        // var trustedProxyMetadata: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest.Parameters.TrustedProxyMetadata
        // var requestBypassed: Bool
        // var requestNack: Bool
        // var trustedProxyRequestPayload: Data

        public init(
            requestID: String = String(),
            workloadType: String = String(),
            workloadParameters: [String: [String]]
        ) {
            self.requestID = requestID
            self.workloadType = workloadType
            self.workloadParameters = workloadParameters
        }
    }

    /// Simplified subset of InvokeProxyInitiate.ReuseConstraints
    /// Note: This is package only this till it's more stable
    package struct ReuseConstraints: Sendable, CustomStringConvertible {
        // note: naming convention matches the protos! ID not Id
        package var ensembleID: String
        package var bootID: String
        package var rackID: String?
        package var workloadAdditions: [String: [String]]

        /// local cloudboard client concept allowing explicit control of whether the reuse
        /// is considered to be viable - remember this doesn't mean you have to *send the Initiate to
        /// that endpoint* just that the target is "present" (no restarted and registered with SD)
        package var forceReuseFailure: Bool

        // only the normal parts that were in the proto included
        package var description: String {
            "ensembleID: \(self.ensembleID) bootID: \(self.bootID) rackID: \(self.rackID ?? "nil") workloadAdditions: \(self.workloadAdditions)"
        }

        internal init(
            proto: Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate.ReuseConstraints,
            forceReuseFailure: Bool
        ) {
            self.ensembleID = proto.ensemble.ensembleID
            self.bootID = proto.ensemble.bootID
            self.rackID = proto.hasRackID ? proto.rackID : nil
            self.workloadAdditions = proto.workloadAdditions.param.asMap()
            self.forceReuseFailure = forceReuseFailure
        }
    }

    public struct InvokeProxyInitiate: Sendable {
        /// Unique id for this worker request - used to tie everything together
        public var taskId: String

        public var workloadType: String

        /// Workload parameters, sometimes called tags
        public var workloadParameters: [String: [String]]

        package var reuseConstraints: ReuseConstraints?

        package var groupID: String?

        // not exposed - likely never needed
        // var responseBypassMode: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode
        // var forwardBypassedRequestChunks: Bool = false

        // not exposed - not yet needed
        // var efforts: [Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate.Effort]
        // var negotiate: Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate.NegotiateEnsembleChoice

        public init(
            taskID: String,
            workloadType: String,
            workloadParameters: [String: [String]]
        ) {
            self.init(
                taskID: taskID,
                workloadType: workloadType,
                workloadParameters: workloadParameters,
                reuseConstraints: nil,
                groupID: nil
            )
        }

        package init(
            taskID: String,
            workloadType: String,
            workloadParameters: [String: [String]],
            reuseConstraints: ReuseConstraints?,
            groupID: String?
        ) {
            self.taskId = taskID
            self.workloadType = workloadType
            self.workloadParameters = workloadParameters
            self.reuseConstraints = reuseConstraints
            self.groupID = groupID
        }
    }

    /// The original requests parameters which ROPES would be able to link to the
    /// find worker request
    public var originalRequest: OriginalRequest
    /// The find worker message that was 'sent to ROPES'
    public var initiate: InvokeProxyInitiate

    public init(
        originalRequest: OriginalRequest,
        initiate: InvokeProxyInitiate
    ) {
        self.originalRequest = originalRequest
        self.initiate = initiate
    }

    internal init(
        originalRequestParameters: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest.Parameters,
        initiate: Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate,
        forceReuseFailure: Bool,
        groupID: String?
    ) {
        self.originalRequest = .init(
            requestID: originalRequestParameters.requestID,
            workloadType: originalRequestParameters.workload.type,
            workloadParameters: originalRequestParameters.workload.param.asMap()
        )
        self.initiate = .init(
            taskID: initiate.taskID,
            workloadType: initiate.workload.type,
            workloadParameters: initiate.workload.param.asMap(),
            reuseConstraints: .init(proto: initiate.reuseConstraints, forceReuseFailure: forceReuseFailure),
            groupID: groupID
        )
    }
}

public class LocalCloudBoardGRPCAsyncClient {
    typealias CloudBoardGrpcClient = Com_Apple_Cloudboard_Api_V1_CloudBoardAsyncClient
    typealias FetchAttestationRequest = Com_Apple_Cloudboard_Api_V1_FetchAttestationRequest
    typealias ProtoPrivateCloudComputeRequest = Proto_PrivateCloudCompute_PrivateCloudComputeRequest
    typealias ProtoPrivateCloudComputeResponse = Proto_PrivateCloudCompute_PrivateCloudComputeResponse
    typealias PrivateCloudComputeAttestationResponse = Com_Apple_Cloudboard_Api_V1_FetchAttestationResponse.Attestation
    typealias InvokeProxyDialBackResponse = Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackResponse
    /// Identifies a client
    /// There is *no* attempt to unify two instances whose ``host`` would refer to the
    /// same actual host.
    public struct EndPoint: Hashable, Sendable, CustomStringConvertible {
        var host: String
        var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        public var description: String {
            "\(self.host):\(self.port)"
        }
    }

    /// This provides full control of the "ROPES simulation" path as to whether the selection
    /// is considered to be a reuse or not.
    public struct SelectedComputeNode: Sendable {
        var endpoint: EndPoint
        var computeNodeWorkload: [String: [String]]

        public init(
            endpoint: LocalCloudBoardGRPCAsyncClient.EndPoint,
            computeNodeWorkload: [String: [String]]
        ) {
            self.endpoint = endpoint
            self.computeNodeWorkload = computeNodeWorkload
        }
    }

    public static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "LocalCloudBoardClient"
    )

    /// Wraps up the client, and remembers state for it like the attestation
    ///
    /// This is *not* currently a cache - there's no replacement policy so this is useful only for a limited
    /// time period, that's fine for current use cases but may not apply in future
    private final class StatefulClient: Sendable {
        let endPoint: EndPoint
        let isProxy: Bool
        let client: CloudBoardGrpcClient
        private let reusedAttestation: OSAllocatedUnfairLock<PrivateCloudComputeAttestationResponse?> =
            .init(initialState: nil)

        init(
            endPoint: EndPoint,
            client: CloudBoardGrpcClient,
            isProxy: Bool,
        ) {
            self.endPoint = endPoint
            self.client = client
            self.isProxy = isProxy
        }

        /// Get attestation for the connected node.
        ///
        /// Returns a previously requested attestation if one has already been fetched.
        /// Otherwise initiates a new fetch.
        ///
        /// - Returns: attestation from the GRPC call response
        func getAttestation() async throws -> PrivateCloudComputeAttestationResponse {
            if let attestation = reusedAttestation.withLock({ $0 }) {
                return attestation
            } else {
                let attestationResponse = try await client.fetchAttestation(
                    FetchAttestationRequest()
                )
                self.reusedAttestation.withLock { $0 = attestationResponse.attestation }
                return attestationResponse.attestation
            }
        }

        deinit {
            _ = self.client.channel.close()
        }
    }

    /// The proxy if defined that way, otherwise the sole target compute node
    private let initialClient: StatefulClient
    private let attestationEnvironment: CloudAttestation.Environment
    // Used only in very obscure testing scenarios (like doing KVCacheTransfer without a proxy)
    private var forcedDEK: SymmetricKey?
    /// These should be proxies, on each request they will be sent a Nack request
    private var nackTargets: [EndPoint: StatefulClient] = [:]

    private var clientByEndpoint: [EndPoint: StatefulClient] = [:]
    // The errors to be returned to the clients if Trusted Proxy sends ProxyWorkerErrors messages
    private let proxyWorkerErrors: Mutex<[String: Error]> = .init([:])

    private typealias UsageTrackedClient = TrackedPool<EndPoint, StatefulClient>.Token
    // pick the worker to use (if any) for an ProxyInvokeClient call
    private let proxyInvokeClientChoice: @Sendable (ChooseWorkerContext) -> InvokeProxyInitiateResult

    private let _forceReuseFailure = Mutex<Bool>(false)
    /// Setting this to true will make all future proxy Initiate requests which
    /// attempt to make use of the ReuseTargets be considered to *not* be able to
    /// achieve this regarless of any other code that would control this
    public var forceReuseFailure: Bool {
        get { self._forceReuseFailure.withLock { $0 } }
        set { self._forceReuseFailure.withLock { $0 = newValue } }
    }

    private static func determineEnvironment(_ env: String?) -> CloudAttestation.Environment {
        if let env {
            // This historically ignored parse failures
            // That behaviour is retained for now but might change in future
            return CloudAttestation.Environment(rawValue: env) ?? .dev
        } else {
            return .dev
        }
    }

    private static func makeGRPCClient(
        _ endPoint: EndPoint,
        isProxy: Bool
    ) -> StatefulClient {
        let group = PlatformSupport.makeEventLoopGroup(
            loopCount: 1,
            networkPreference: .userDefined(.networkFramework)
        )
        let queue = DispatchQueue(
            label: "com.apple.LocalCloudBoardClient.Verification.queue",
            qos: DispatchQoS.userInitiated
        )
        let channel = ClientConnection
            .usingTLSBackedByNetworkFramework(on: group)
            .withTLSHandshakeVerificationCallback(on: queue, verificationCallback: { _, _, verifyComplete in
                verifyComplete(true)
            })
            .withConnectionTimeout(minimum: .seconds(5))
            .withConnectionBackoff(retries: .none)
            .connect(host: endPoint.host, port: endPoint.port)
        return StatefulClient(
            endPoint: endPoint,
            client: CloudBoardGrpcClient(channel: channel),
            isProxy: isProxy
        )
    }

    /// For historic reasons, and user expectations (the proxy was added later) this constructor means
    /// "no proxy, a single compute worker"
    /// If you want a proxy with no worker nodes to test edge cases use
    /// ``init(proxyHost:proxyPort:computeHosts:attestationEnvironment:) for automatic failures, or
    /// ``init(proxyHost:proxyPort:computeHosts:attestationEnvironment:proxyInvokeClientChoice:)`` to
    /// explicitly opt into failing to find a node
    ///
    /// Note: not implemented as a convenience constructor to retain ABI compatibility
    public init(
        host: String,
        port: Int
    ) {
        self.attestationEnvironment = Self.determineEnvironment(nil)
        let endpoint = EndPoint(host: host, port: port)
        self.initialClient = Self.makeGRPCClient(
            endpoint,
            isProxy: false
        )
        self.clientByEndpoint[endpoint] = self.initialClient
        self.proxyInvokeClientChoice = { _ in .unavailable }
    }

    /// Kept for API and ABI compatibility, Creates a proxy targetted client with a single worker
    /// Note: not implemented as a convenience constructor to retain ABI compatibility
    public init(
        proxyHost: String,
        proxyPort: Int,
        computeHost: String,
        computePort: Int
    ) {
        self.attestationEnvironment = Self.determineEnvironment(nil)
        let endpoint = EndPoint(host: proxyHost, port: proxyPort)
        self.initialClient = Self.makeGRPCClient(
            endpoint,
            isProxy: true
        )
        self.clientByEndpoint[endpoint] = self.initialClient
        let computeEndpoint = EndPoint(host: computeHost, port: computePort)
        let compute = Self.makeGRPCClient(computeEndpoint, isProxy: false)
        self.clientByEndpoint[computeEndpoint] = compute
        let workers = TrackedPool([compute.endPoint: compute])
        self.proxyInvokeClientChoice = { context -> InvokeProxyInitiateResult in
            let choice = try! workers.useSpecific(compute.endPoint)
            let workload = try! Self.applyConventionalROPESWorkloadManipulation(
                context: context, serviceDiscovery: nil
            )
            return .directChoice(choice, workload: workload)
        }
    }

    /// For historic reasons, and user expectations (the proxy was added later) this constructor means
    /// "no proxy, a single compute worker"
    /// The naming of the arguemnts makes it unclear what it is intended for in the era of proxies.
    /// If you want a single direct to worker connection use ``init(computeHost:attestationEnvironment:)``
    ///
    /// If you want a proxy with no worker nodes to test edge cases use
    /// ``init(proxyHost:proxyPort:computeHosts:attestationEnvironment:) for automatic failures, or
    /// ``init(proxyHost:proxyPort:computeHosts:attestationEnvironment:proxyInvokeClientChoice:)`` to
    /// explicitly opt into failing to find a node
    @available(
        *,
        deprecated,
        renamed: "init(computeHost:attestationEnvironment:)",
        message: "This provides a single worker, but the naming is no longer clear"
    )
    public convenience init(
        host: String,
        port: Int,
        attestationEnvironment: String
    ) {
        self.init(
            computeHost: .init(host: host, port: port),
            attestationEnvironment: attestationEnvironment
        )
    }

    /// Make an instance with no proxy support that assumes it is operating in 'direct attest to k' mode
    /// But only supply the one instance to use
    public init(
        computeHost: EndPoint,
        attestationEnvironment: String? = nil
    ) {
        self.attestationEnvironment = Self.determineEnvironment(attestationEnvironment)
        self.proxyInvokeClientChoice = { _ in .unavailable }
        self.initialClient = Self.makeGRPCClient(
            computeHost,
            isProxy: false
        )
        self.clientByEndpoint[computeHost] = self.initialClient
    }

    /// Create for proxy use with a predefined selection of worker nodes (which can be empty)
    /// They are used in simplistic attempt to evenly distribute load and is inherently not
    /// deterministic. It will NOT respect the max concurrent request limits/health of the
    /// underlying nodes it talks to. If you need to control that use constructor that allows explicit
    /// choice
    public convenience init(
        proxy: EndPoint,
        computeHosts: [EndPoint],
        attestationEnvironment: String? = nil
    ) {
        self.init(
            proxy: proxy,
            computeHosts: computeHosts,
            proxyInvokeClientChoice: .automatic,
            attestationEnvironment: attestationEnvironment
        )
    }

    /// Create for proxy use with a predefined selection of worker nodes (which can be empty)
    /// and a callback selection function to pick the next request.
    /// This is an *advanced usage API* take care.
    ///
    /// The function provided is:
    /// * Required to either return one of the endpoints in `computeHosts` or `nil`
    ///    * `nil` implies no node is available (which is a legal response)
    /// * Is (always) executed whilst holding a lock, so is required to not use any locks itself
    @available(*, deprecated, message: "Use proxyChooseEndPoint taking ChooseWorkerContext instead")
    public convenience init(
        proxy: EndPoint,
        computeHosts: [EndPoint],
        proxyChooseEndPoint: @escaping () -> EndPoint?,
        attestationEnvironment: String? = nil
    ) {
        self.init(
            proxy: proxy,
            computeHosts: computeHosts,
            proxyChooseEndPoint: { _ in proxyChooseEndPoint() },
            attestationEnvironment: attestationEnvironment
        )
    }

    /// Create for proxy use with a predefined selection of worker nodes (which can be empty)
    /// and a callback selection function to pick the next request.
    /// This is an *advanced usage API* take care.
    ///
    /// The function provided is:
    /// * Required to either return one of the endpoints in `computeHosts` or `nil`
    ///    * `nil` implies no node is available (which is a legal response)
    /// * Is (always) executed whilst holding a lock, so is required to not use any locks itself
    public convenience init(
        proxy: EndPoint,
        computeHosts: [EndPoint],
        proxyChooseEndPoint: @escaping (ChooseWorkerContext) -> EndPoint?,
        attestationEnvironment: String? = nil
    ) {
        self.init(
            proxy: proxy,
            computeHosts: computeHosts,
            proxyInvokeClientChoice: .explicitSimple(proxyChooseEndPoint),
            attestationEnvironment: attestationEnvironment
        )
    }

    /// Create for proxy use with a predefined selection of worker nodes (which can be empty)
    /// and a callback selection function to pick the next request.
    /// This is an *advanced usage API* take care.
    ///
    /// The function provided is:
    /// * Required to either return one of the endpoints in `computeHosts` or `nil`
    ///    * `nil` implies no node is available (which is a legal response)
    /// * Is (always) executed whilst holding a lock, so is required to not use any locks itself
    package convenience init(
        proxy: EndPoint,
        computeHosts: [EndPoint],
        proxyChooseEndPoint: @escaping @Sendable (ChooseWorkerContext) -> EndPoint?,
        attestationEnvironment: String? = nil,
        serviceDiscovery: (any ServiceDiscoveryAbstraction.ConsumerClientProtocol)? = nil
    ) {
        self.init(
            proxy: proxy,
            computeHosts: computeHosts,
            proxyInvokeClientChoice: .explicitSimple(proxyChooseEndPoint),
            attestationEnvironment: attestationEnvironment,
            serviceDiscovery: serviceDiscovery
        )
    }

    /// Create for proxy use with a predefined selection of worker nodes (which can be empty)
    /// and a callback selection function to pick the next request which is capable of deliberately violating
    /// the normal ROPES mimicry to test 'illegal' validation code paths if desired.
    ///
    /// This is an *advanced usage API* take care.
    ///
    ///
    /// The function provided is:
    /// * Required to either return one of the endpoints in `computeHosts` or `nil`
    ///    * `nil` implies no node is available (which is a legal response)
    /// * Is (always) executed whilst holding a lock, so is required to not use any locks itself
    public convenience init(
        proxy: EndPoint,
        computeHosts: [EndPoint],
        proxyChooseEndPointFullControl: @escaping @Sendable (ChooseWorkerContext) -> SelectedComputeNode?,
        attestationEnvironment: String? = nil
    ) {
        self.init(
            proxy: proxy,
            computeHosts: computeHosts,
            proxyChooseEndPointFullControl: proxyChooseEndPointFullControl,
            attestationEnvironment: attestationEnvironment,
            serviceDiscovery: nil
        )
    }

    /// Create for proxy use with a predefined selection of worker nodes (which can be empty)
    /// and a callback selection function to pick the next request which is capable of deliberately violating
    /// the normal ROPES mimicry to test 'illegal' validation code paths if desired.
    ///
    /// This is an *advanced usage API* take care.
    ///
    ///
    /// The function provided is:
    /// * Required to either return one of the endpoints in `computeHosts` or `nil`
    ///    * `nil` implies no node is available (which is a legal response)
    /// * Is (always) executed whilst holding a lock, so is required to not use any locks itself
    package convenience init(
        proxy: EndPoint,
        computeHosts: [EndPoint],
        proxyChooseEndPointFullControl: @escaping @Sendable (ChooseWorkerContext) -> SelectedComputeNode?,
        attestationEnvironment: String? = nil,
        serviceDiscovery _: ServiceDiscoveryAbstraction.ConsumerClientProtocol? = nil
    ) {
        self.init(
            proxy: proxy,
            computeHosts: computeHosts,
            proxyInvokeClientChoice: .explicitFullControl(proxyChooseEndPointFullControl),
            attestationEnvironment: attestationEnvironment
        )
    }

    private enum InvokeProxyInitiateResult {
        // covers unknownWorkload and nodesBusy
        // if we want to control the error to indicate that update accordingly
        case unavailable
        /// pick is only supported in LocalCloudBoardClient V2
        case pick
        /// where to talk to, and the workload to use for it (may be edited from the original!)
        case directChoice(UsageTrackedClient, workload: [String: [String]])
    }

    private enum ProxyInvokeClientChoice {
        case none
        case automatic
        case explicitSimple(@Sendable (ChooseWorkerContext) -> EndPoint?)
        case explicitFullControl(@Sendable (ChooseWorkerContext) -> SelectedComputeNode?)
    }

    /// This replicates the logic in ROPES where workloads are transformed based on reuse requirements
    /// this logic is deliberately *not* application specific (for example injecting the run mode for
    /// split FT/ET or not) only generalised so one would expect it to always be applied
    package static func applyConventionalROPESWorkloadManipulation(
        context: ChooseWorkerContext,
        serviceDiscovery: ServiceDiscoveryAbstraction.ConsumerClientProtocol?
    ) throws -> [String: [String]] {
        var workloadParameters = context.initiate.workloadParameters
        if let reuseConstraints = context.initiate.reuseConstraints {
            var reuseConsideredViable = false
            if reuseConstraints.forceReuseFailure {
                Self.logger.log("reuse target \(reuseConstraints, privacy: .public) is forced to be unviable")
            } else if let sd = serviceDiscovery {
                let snapshot = try sd.snapshot()
                if let target = snapshot.values
                    .first(where: { $0.ensembleId == reuseConstraints.ensembleID }) {
                    if target.bootId == reuseConstraints.bootID {
                        Self.logger.log("reuse target \(reuseConstraints, privacy: .public) is present")
                    } else {
                        Self.logger
                            .log("reuse target \(reuseConstraints, privacy: .public) bootId does not match")
                    }
                } else {
                    Self.logger.log("reuse target \(reuseConstraints, privacy: .public) is not present")
                }
                // we don't care about the rack (yet) - nothing is currently enforcing the negotiate cycle
            } else {
                // We convert the choice decisions into the simple legal happy path
                // if consumers want to control this they can use the forceReuseFailure
                // property directly
                reuseConsideredViable = true
                Self.logger.log("reuse simply assumed to work")
            }
            if reuseConsideredViable {
                workloadParameters = workloadParameters.merging(reuseConstraints.workloadAdditions) { a, b in
                    // ROPES would cause a grpc error, we aren't interested in testing this
                    // as we should always prevent it happening
                    fatalError("attempt to override via reuse workload \(a) vs \(b)")
                }
            }
        }
        return workloadParameters
    }

    private init(
        proxy: EndPoint,
        computeHosts: [EndPoint],
        proxyInvokeClientChoice: ProxyInvokeClientChoice,
        attestationEnvironment: String? = nil,
        serviceDiscovery: ServiceDiscoveryAbstraction.ConsumerClientProtocol? = nil
    ) {
        self.attestationEnvironment = Self.determineEnvironment(attestationEnvironment)
        self.initialClient = Self.makeGRPCClient(
            proxy,
            isProxy: true
        )
        self.clientByEndpoint[proxy] = self.initialClient

        let clients = computeHosts.map { endPoint in
            let client = Self.makeGRPCClient(endPoint, isProxy: false)
            return (client.endPoint, client)
        }
        for (endPoint, client) in clients {
            self.clientByEndpoint[endPoint] = client
        }
        let workers = TrackedPool(.init(uniqueKeysWithValues: clients))
        self.proxyInvokeClientChoice =
            if computeHosts.isEmpty {
                { _ in .unavailable }
            } else {
                switch proxyInvokeClientChoice {
                case .none:
                    { _ in .unavailable }
                case .automatic:
                    // This is *not* enforcement, it's best effort distribution
                    // ROPES is inherently reactive for this (as another ROPES instance might grab the PCC node)
                    // it self heals, by trying another (or giving up and letting the client know)
                    // currently the local framework entirely ignores any of that - we keep it simple but do our best
                    // to distribute evenly as, in the realistic case (max one request per node) then doing this will
                    // behave reasonably if the consumer of the framework has configured the maximum concurrent requests
                    // to match the available workers
                    { context in
                        let choice = try! workers.useLeastBusy()
                        let workload = try! Self.applyConventionalROPESWorkloadManipulation(
                            context: context, serviceDiscovery: serviceDiscovery
                        )
                        return .directChoice(choice, workload: workload)
                    }
                case .explicitSimple(let choose):
                    { context -> InvokeProxyInitiateResult in
                        guard let endpoint = choose(context) else {
                            return .unavailable
                        }
                        let choice: UsageTrackedClient
                        do {
                            choice = try workers.useSpecific(endpoint)
                        } catch let error as TrackedPoolError {
                            switch error {
                            case .keyNotFound(let choice):
                                fatalError(
                                    "The worker choice function selected \(choice) but that is not a valid worker"
                                )
                            default:
                                fatalError("Unexpected error \(error)")
                            }
                        } catch {
                            fatalError("Unexpected error \(error)")
                        }
                        let workload = try! Self.applyConventionalROPESWorkloadManipulation(
                            context: context, serviceDiscovery: serviceDiscovery
                        )
                        return .directChoice(choice, workload: workload)
                    }
                case .explicitFullControl(let choose):
                    { context -> InvokeProxyInitiateResult in
                        guard let selection = choose(context) else {
                            return .unavailable
                        }
                        do {
                            let client = try workers.useSpecific(selection.endpoint)
                            return .directChoice(
                                client,
                                workload: selection.computeNodeWorkload
                            )
                        } catch let error as TrackedPoolError {
                            switch error {
                            case .keyNotFound(let choice):
                                fatalError(
                                    "The worker choice function selected \(choice) but that is not a valid worker"
                                )
                            default:
                                fatalError("Unexpected error \(error)")
                            }
                        } catch {
                            fatalError("Unexpected error \(error)")
                        }
                    }
                }
            }
    }

    /// This forces all subsequent requests to us an identical DEK
    /// It is considered a very unusual testing scenario so not worth adding to the (many) constructors
    /// This is *obviously* insecure, but rather than all clients having to know the precise semantics of
    /// the symetric key size required it just exposes a trivial seed whose entropy is (vastly) lower
    /// than the actual entropy involved in a real DEK but whose behaviour is stable.
    /// If for some reason the DEK needs to be full strength use the ``forceDEK(key:)`` instead
    public func forceDEK(seed: UInt8) {
        self.forceDEK(SymmetricKey(data: [UInt8](repeating: seed, count: SymmetricKeySize.bits128.bitCount / 8)))
    }

    /// This forces all subsequent requests to us an identical DEK
    /// It is considered a very unusual testing scenario so not worth adding to the (many) constructors
    public func forceDEK(_ key: SymmetricKey) {
        self.forcedDEK = key
    }

    public func registerNackTarget(_ endPoint: EndPoint) {
        // we must assume they are proxies
        let client = Self.makeGRPCClient(endPoint, isProxy: true)
        self.nackTargets[endPoint] = client
    }

    public func unregisterNackTarget(_ endPoint: EndPoint) {
        self.nackTargets.removeValue(forKey: endPoint)
    }

    private func makeClientStateMachine() -> OHTTPClientStateMachine {
        guard let dek = self.forcedDEK else {
            return OHTTPClientStateMachine()
        }
        return OHTTPClientStateMachine(key: dek)
    }

    @available(*, deprecated, renamed: "streamPrivateRequest")
    public func submitPrivateRequest(payload: Data) async throws
    -> LocalCloudboardClientResponse {
        return try await self.submitPrivateRequest(payload: payload, requestID: UUID().uuidString)
    }

    public func submitPrivateRequest(
        payload: Data, requestID: String
    ) async throws -> LocalCloudboardClientResponse {
        try await self.submitPrivateRequest(payload: payload, requestID: requestID, metaData: .init())
    }

    public func submitPrivateRequest(
        payload: Data, requestID: String, metaData: InvokeWorkloadRequestMetaData
    ) async throws -> LocalCloudboardClientResponse {
        let (requestSender, outputStream) = try await streamPrivateRequest(
            requestID: requestID, useRequestBypass: false, metaData: metaData
        )
        requestSender.yield(payload)
        requestSender.finish()
        return outputStream
    }

    public func streamPrivateRequest(
    ) async throws -> (AsyncStream<Data>.Continuation, LocalCloudboardClientResponse) {
        return try await self.streamPrivateRequest(requestID: UUID().uuidString)
    }

    /// create a stream for sending the request
    /// - Parameter requestID: client request ID for logging
    /// - Returns: a tuple with AsyncStream continuation to write request data chunks into and response stream
    public func streamPrivateRequest(
        requestID: String
    ) async throws -> (AsyncStream<Data>.Continuation, LocalCloudboardClientResponse) {
        try await self.streamPrivateRequest(requestID: requestID, useRequestBypass: false)
    }

    /// create a stream for sending the request
    /// - Parameter requestID: client request ID for logging
    /// - Parameter useRequestBypass: If the target is a proxy hold the request data for sending to the first worker
    /// - Returns: a tuple with AsyncStream continuation to write request data chunks into and response stream
    public func streamPrivateRequest(
        requestID: String,
        useRequestBypass: Bool
    ) async throws -> (AsyncStream<Data>.Continuation, LocalCloudboardClientResponse) {
        try await self.streamPrivateRequest(requestID: requestID, useRequestBypass: useRequestBypass, metaData: .init())
    }

    /// create a stream for sending the request
    /// - Parameter requestID: client request ID for logging
    /// - Parameter useRequestBypass: If the target is a proxy hold the request data for sending to the first worker
    /// - Parameter metaData: meta data to pass through to cloudboard and the cloud app on the initial request
    /// - Returns: a tuple with AsyncStream continuation to write request data chunks into and response stream
    public func streamPrivateRequest(
        requestID: String,
        useRequestBypass: Bool,
        metaData: InvokeWorkloadRequestMetaData
    ) async throws -> (AsyncStream<Data>.Continuation, LocalCloudboardClientResponse) {
        try await self.streamPrivateRequest(
            requestID: requestID,
            useRequestBypass: useRequestBypass,
            metaData: metaData,
            requestDumpFileURLs: [:]
        )
    }

    /// create a stream for sending the request
    /// - Parameter requestID: client request ID for logging
    /// - Parameter useRequestBypass: If the target is a proxy hold the request data for sending to the first worker
    /// - Parameter metaData: meta data to pass through to cloudboard and the cloud app on the initial request
    /// - Parameter requestDumpFileURLs: a dictionary mapping each endpoint to a file URL that is used for dumping
    /// the InvokeWorkloadRequest messages for that endpoint
    /// - Returns: a tuple with AsyncStream continuation to write request data chunks into and response stream
    public func streamPrivateRequest(
        requestID: String,
        useRequestBypass: Bool,
        metaData: InvokeWorkloadRequestMetaData,
        requestDumpFileURLs: [EndPoint: URL]
    ) async throws -> (AsyncStream<Data>.Continuation, LocalCloudboardClientResponse) {
        let parameters = InvokeWorkloadRequest.Parameters.with {
            $0.requestID = requestID
            $0.requestBypassed = useRequestBypass
            $0.workload = .init(type: metaData.workloadType, parameters: metaData.workloadParameters)
            $0.patIssuer = metaData.patIssuer
        }
        let session = try await self.streamPrivateRequestInternal(
            requestSender: .plainPayloadSender(parameters: parameters),
            requestDumpFileURLs: requestDumpFileURLs,
            cryptoMaterial: nil
        )
        guard case .forPlainPayloadSender(let requestContinuation, let responseStream, let nackContext) = session else {
            fatalError("Unexpected request session type")
        }
        return (
            requestContinuation,
            LocalCloudboardClientResponse(
                responseStream: responseStream,
                nackRequests: nackContext.nackRequests,
                nackResponseStreams: nackContext.nackResponseStreams
            )
        )
    }

    /// create a stream for sending the request
    /// - Parameter requestID: client request ID for logging
    /// - Parameter useRequestBypass: If the target is a proxy hold the request data for sending to the first worker
    /// - Parameter metaData: meta data to pass through to cloudboard and the cloud app on the initial request
    /// - Parameter requestDumpFileURLs: a dictionary mapping each endpoint to a file URL that is used for dumping
    /// the InvokeWorkloadRequest messages for that endpoint
    /// - Parameter applicationDataChunkingConfiguration: Enables data chunking support and defines the chunk size
    /// - Returns: a tuple with AsyncStream continuation to write request data chunks into and response stream
    public func streamPrivateRequest(
        requestID: String,
        useRequestBypass: Bool,
        metaData: InvokeWorkloadRequestMetaData,
        requestDumpFileURLs: [EndPoint: URL],
        applicationDataChunkingConfiguration: ApplicationDataChunkingConfiguration
    ) async throws -> (AsyncStream<Data>.Continuation, LocalCloudboardClientResponse) {
        let parameters = InvokeWorkloadRequest.Parameters.with {
            $0.requestID = requestID
            $0.requestBypassed = useRequestBypass
            $0.workload = .init(type: metaData.workloadType, parameters: metaData.workloadParameters)
            $0.patIssuer = metaData.patIssuer
        }
        let session = try await self.streamPrivateRequestInternal(
            requestSender: .plainPayloadSender(parameters: parameters),
            requestDumpFileURLs: requestDumpFileURLs,
            cryptoMaterial: nil,
            applicationDataChunkingConfiguration: applicationDataChunkingConfiguration
        )
        guard case .forPlainPayloadSender(let requestContinuation, let responseStream, let nackContext) = session else {
            fatalError("Unexpected request session type")
        }
        return (
            requestContinuation,
            LocalCloudboardClientResponse(
                responseStream: responseStream,
                nackRequests: nackContext.nackRequests,
                nackResponseStreams: nackContext.nackResponseStreams
            )
        )
    }

    public struct CryptoMaterial: Sendable {
        public let id: String
        public let material: Data

        public init(id: String, material: Data) {
            self.id = id
            self.material = material
        }
    }

    /// create a stream for sending the request
    /// - Parameter requestID: client request ID for logging
    /// - Parameter metaData: meta data to pass through to cloudboard and the cloud app on the initial request
    /// - Parameter cryptoMaterial: Crypto/key material to send to the PCC node alongside the application payload stream
    /// - Returns: a tuple with AsyncStream continuation to write request data chunks into and response stream
    public func streamPrivateComputeRequest(
        requestID: String,
        cryptoMaterial: [CryptoMaterial]?
    ) async throws -> (AsyncStream<Data>.Continuation, LocalCloudboardClientResponse) {
        return try await self.streamPrivateComputeRequest(
            requestID: requestID,
            metaData: .init(),
            cryptoMaterial: cryptoMaterial
        )
    }

    /// create a stream for sending the request
    /// - Parameter requestID: client request ID for logging
    /// - Parameter metaData: meta data to pass through to cloudboard and the cloud app on the initial request
    /// - Parameter cryptoMaterial: Crypto/key material to send to the PCC node alongside the application payload stream
    /// - Returns: a tuple with AsyncStream continuation to write request data chunks into and response stream
    public func streamPrivateComputeRequest(
        requestID: String,
        metaData: InvokeWorkloadRequestMetaData,
        cryptoMaterial: [CryptoMaterial]?
    ) async throws -> (AsyncStream<Data>.Continuation, LocalCloudboardClientResponse) {
        let parameters = InvokeWorkloadRequest.Parameters.with {
            $0.requestID = requestID
            $0.requestBypassed = false
            $0.workload = .init(type: metaData.workloadType, parameters: metaData.workloadParameters)
            $0.patIssuer = metaData.patIssuer
        }
        let session = try await self.streamPrivateRequestInternal(
            requestSender: .plainPayloadSender(parameters: parameters),
            requestDumpFileURLs: [:],
            cryptoMaterial: cryptoMaterial
        )
        guard case .forPlainPayloadSender(let requestContinuation, let responseStream, let nackContext) = session else {
            fatalError("Unexpected request session type")
        }
        return (
            requestContinuation,
            LocalCloudboardClientResponse(
                responseStream: responseStream,
                nackRequests: nackContext.nackRequests,
                nackResponseStreams: nackContext.nackResponseStreams
            )
        )
    }

    /// fetch attestation for the client with specified endpoint
    /// - Parameter endpoint: endpoint to fetch attestation from
    /// - Returns: Attestation bundle wrapper that exposes the raw attestation bundle, a JSON representation, the
    /// release digest, and trusted release set (for proxy nodes)
    public func fetchAttestation(endpoint: EndPoint) async throws -> LocalCloudBoardAttestationBundle {
        let client: StatefulClient

        if let nodeClient = self.clientByEndpoint[endpoint] {
            client = nodeClient
        } else if let nackClient = self.nackTargets[endpoint] {
            client = nackClient
        } else {
            throw LocalCloudBoardGRPCClientError.invalidEndpointProvidedForFetchingAttestation
        }

        let attestation = try await client.getAttestation()
        let (_, localCloudBoardAttestationBundle) = try await self
            .parseAndValidateAttestationBundle(attestation.attestationBundle)
        return localCloudBoardAttestationBundle
    }

    func streamPrivateRequestInternal(
        requestSender: RequestSender,
        requestDumpFileURLs: [EndPoint: URL] = [:],
        cryptoMaterial: [CryptoMaterial]?,
        applicationDataChunkingConfiguration: ApplicationDataChunkingConfiguration = .disabled
    ) async throws -> StreamPrivateRequestSession {
        let requestStreamContext = await PrivateRequestStreamContext.forSender(requestSender)
        let responseStreamContext = PrivateResponseStreamContext.forSender(requestSender)

        let requestID: String
        let useRequestBypass: Bool
        let metaData: InvokeWorkloadRequestMetaData
        switch requestStreamContext {
        case .plainPayload(_, _, let parameters), .invokeWorkloadRequest(_, let parameters):
            requestID = parameters.requestID
            useRequestBypass = parameters.requestBypassed
            metaData = parameters.invokeWorkloadRequestMetaData
        }

        let requestDumpFileHandle: FileHandle?
        if let requestDumpFileURL = requestDumpFileURLs[self.initialClient.endPoint] {
            Self.logger.info("""
            Will dump request for \(self.initialClient.endPoint, privacy: .public) \
            to \(requestDumpFileURL.path, privacy: .public)
            """)
            FileManager.default.createFile(atPath: requestDumpFileURL.path(), contents: nil)
            requestDumpFileHandle = try FileHandle(forWritingTo: requestDumpFileURL)
        } else {
            requestDumpFileHandle = nil
        }

        let initialClient = self.initialClient
        let attestation = try await initialClient.getAttestation()
        let cloudOSNodePublicKeyID = attestation.keyID
        let (
            publicKey,
            parsedAttestationBundle
        ) = try await parseAndValidateAttestationBundle(attestation.attestationBundle)
        guard let attestationData = try? parsedAttestationBundle.jsonString().data(using: .utf8) else {
            throw LocalCloudBoardGRPCClientError.invalidPrivateCloudComputeResponse
        }

        // create an ohttp request stream
        var oHTTPClientStateMachine = self.makeClientStateMachine()
        var (encapsulatedKey, oHTTPStreamingResponseDecapsulator) = try oHTTPClientStateMachine.encapsulateKey(
            publicKey: publicKey,
            ciphersuite: .Curve25519_SHA256_AES_GCM_128
        )

        let requestBypassed = useRequestBypass && initialClient.isProxy

        // The lack of usage tracking on the initial request is deliberate
        // If the user wishes to 'over use' it that's up to them
        let asyncWorkloadClient = WorkloadAsyncClientStream(client: initialClient.client)
        let (initialAuthenticatedRequestContinuation, grpcResponseStream) = asyncWorkloadClient.startSetup()

        let requestParameters: InvokeWorkloadRequest.Parameters = switch requestStreamContext {
        case .plainPayload:
            asyncWorkloadClient.makeParameters(
                decryptionKey: .helper(keyID: cloudOSNodePublicKeyID, key: encapsulatedKey),
                requestID: requestID,
                metaData: metaData,
                requestBypassed: requestBypassed
            )
        case .invokeWorkloadRequest(_, let parameters):
            parameters
        }
        let requestParametersGRPCMessage = asyncWorkloadClient.wrapParameters(requestParameters)
        if let requestDumpFileHandle {
            try requestDumpFileHandle.write(requestParametersGRPCMessage.serialized())
        }
        initialAuthenticatedRequestContinuation.yield(requestParametersGRPCMessage)

        var nackRequests: [EndPoint: Task<Void, Error>] = [:]
        var nackResponseStreams: [EndPoint: AsyncThrowingStream<PrivateCloudComputeResponse, Error>] = [:]
        for (endPoint, client) in self.nackTargets {
            // unstructured task for the nacks as they are entirely separate from the others
            let (nackResponseStream, nackResponseContinuation) = AsyncThrowingStream
                .makeStream(of: PrivateCloudComputeResponse.self)
            let asyncRequest = Task {
                try await self.processAndValidateNack(
                    requestID: requestID,
                    metaData: metaData,
                    client: client,
                    nackResponseContinuation: nackResponseContinuation,
                    requestDumpFileURL: requestDumpFileURLs[client.endPoint]
                )
            }
            nackRequests[endPoint] = asyncRequest
            nackResponseStreams[endPoint] = nackResponseStream
        }

        let authenticatedRequestContinuation: any BypassContinuationProtocol<InvokeWorkloadRequest> =
            if requestBypassed {
                BufferingBypassContinuation()
            } else {
                NotBypassedContinuation(
                    initialAuthenticatedRequestContinuation
                )
            }

        // Only now we have finalised the _authenticated_ output should we start sending encrypted things
        // the first of which is the auth token message
        let authTokenGRPCMessage: InvokeWorkloadRequest
        switch requestStreamContext {
        case .plainPayload:
            // Right now LocalCloudBoardClient only support providing crypto material to compute nodes
            if let cryptoMaterial {
                var proxyInvokeOpen = Proto_PrivateCloudCompute_ProxyInvokeOpen()
                proxyInvokeOpen.opaqueCryptoMaterial = cryptoMaterial.map { material in
                    .with {
                        $0.id = material.id
                        $0.material = material.material
                    }
                }
                if case .enabled(let chunkSize) = applicationDataChunkingConfiguration {
                    proxyInvokeOpen.capabilities = .with {
                        $0.applicationDataChunking = .with {
                            $0.size = UInt32(chunkSize)
                        }
                    }
                }
                proxyInvokeOpen.workloadType = metaData.workloadType
                let pccProxyInvokeOpen = try ProtoPrivateCloudComputeRequest.serialized(
                    with: .proxyInvokeOpen(proxyInvokeOpen)
                )
                let encapsulatedProxyInvokeOpen = try oHTTPClientStateMachine.encapsulateMessage(
                    message: pccProxyInvokeOpen, isFinal: false
                )
                authTokenGRPCMessage = asyncWorkloadClient.makeAuthToken(encapsulatedProxyInvokeOpen)
            } else {
                var authToken = Proto_PrivateCloudCompute_OpenRequestPayload()
                if case .enabled(let chunkSize) = applicationDataChunkingConfiguration {
                    authToken.capabilities = .with {
                        $0.applicationDataChunking = .with {
                            $0.size = UInt32(chunkSize)
                        }
                    }
                }
                authToken.workloadType = metaData.workloadType
                let pccAuthRequest = try ProtoPrivateCloudComputeRequest.serialized(with: .open(authToken))
                let encapsulatedOpen = try oHTTPClientStateMachine.encapsulateMessage(
                    message: pccAuthRequest, isFinal: false
                )
                authTokenGRPCMessage = asyncWorkloadClient.makeAuthToken(encapsulatedOpen)
            }
        case .invokeWorkloadRequest(let stream, _):
            var streamIterator = stream.makeAsyncIterator()
            let nextMessage = await streamIterator.next()
            guard let nextMessage, case .requestChunk = nextMessage.type else {
                fatalError("Expect request chunk message but get \(String(describing: nextMessage?.type))")
            }
            authTokenGRPCMessage = nextMessage
        }
        if let requestDumpFileHandle {
            try requestDumpFileHandle.write(authTokenGRPCMessage.serialized())
        }
        authenticatedRequestContinuation.yield(authTokenGRPCMessage)

        // When request bypass is enabled, ROPES duplicates the first request chunk containing the auth token when
        // instructed to do so by the client which pccd does for all proxy requests.
        if requestBypassed {
            initialAuthenticatedRequestContinuation.yield(authTokenGRPCMessage)
            // The semantics of request bypass, to the proxy, is that the request gets immediately closed after this.
            // after the parameters. This might change if new message types are added in future
            initialAuthenticatedRequestContinuation.finish()
        }

        // This is equivalent to what the GRPC Async Client does and is reasonable because the hop is expected
        // to be over the network, so we pull on the stream of inputs and yield them out into another continuation.
        // It's also OK to have the top level task because the `payloadChunkStream` is expected to be finished if the
        // caller gets cancelled, so not being the part of the same task tree should not cause problems here.
        Task {
            switch requestStreamContext {
            case .plainPayload(let stream, _, _):
                for try await chunk in stream {
                    let dataChunks: [Data]
                    switch applicationDataChunkingConfiguration {
                    case .disabled:
                        dataChunks = [chunk]
                    case .enabled(let chunkSize):
                        let chunker = try LengthPrefixChunker(chunkSize: chunkSize, mode: .dataOnly)
                        dataChunks = try chunker.chunkData(data: chunk)
                    }
                    for dataChunk in dataChunks {
                        let pccPayloadChunk = try ProtoPrivateCloudComputeRequest
                            .serialized(with: .applicationPayload(dataChunk))
                        let encapsulatedPayload = try oHTTPClientStateMachine.encapsulateMessage(
                            message: pccPayloadChunk, isFinal: false
                        )
                        let payloadChunkGRPCMessage = InvokeWorkloadRequest.with {
                            $0.requestChunk = Proto_Ropes_Common_Chunk.with {
                                $0.encryptedPayload = encapsulatedPayload
                                $0.isFinal = false
                            }
                        }
                        if let requestDumpFileHandle {
                            try requestDumpFileHandle.write(payloadChunkGRPCMessage.serialized())
                        }
                        authenticatedRequestContinuation.yield(payloadChunkGRPCMessage)
                    }
                }

                let pccFinalMessage = try ProtoPrivateCloudComputeRequest.serialized(with: .finalMessage(.init()))
                let encapuslatedFinalMessage = try oHTTPClientStateMachine.encapsulateMessage(
                    message: pccFinalMessage, isFinal: true
                )
                let finalChunkGRPCMessage = InvokeWorkloadRequest.with {
                    $0.requestChunk = Proto_Ropes_Common_Chunk.with {
                        $0.encryptedPayload = encapuslatedFinalMessage
                        $0.isFinal = true
                    }
                }
                if let requestDumpFileHandle {
                    try requestDumpFileHandle.write(finalChunkGRPCMessage.serialized())
                }
                authenticatedRequestContinuation.yield(finalChunkGRPCMessage)
            case .invokeWorkloadRequest(let stream, _):
                // Caller is responsible for providing the final message
                for try await payloadChunkGRPCMessage in stream {
                    if let requestDumpFileHandle {
                        try requestDumpFileHandle.write(payloadChunkGRPCMessage.serialized())
                    }
                    authenticatedRequestContinuation.yield(payloadChunkGRPCMessage)
                }
            }
            authenticatedRequestContinuation.finish()
        }

        // Receive messages from PCC Node
        // Even though this is a top level task, since the above Task completes when
        // the caller is cancelled, the grpcResponseStream will get closed.
        Task {
            if case .privateCloudComputeResponse(_, let pccResponseContinuation) = responseStreamContext {
                pccResponseContinuation.yield(PrivateCloudComputeResponse.attestation(attestationData))
                pccResponseContinuation.yield(PrivateCloudComputeResponse.attestationBundle(parsedAttestationBundle))
            }

            // encrypted response payload from the original node that the client directly attests to.
            let (
                originalResponseStream,
                originalResponseContinuation
            ) = AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.makeStream()
            // encrypted response payload from the worker node when response bypass is enabled.
            let (
                bypassResponseStream,
                bypassResponseContinuation
            ) = AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.makeStream()
            // context for decapsulating bypassed response payload
            let (
                bypassDecapStream,
                bypassDecapContinuation
            ) = AsyncStream<Proto_PrivateCloudCompute_ResponseContext>.makeStream()

            try await withThrowingDiscardingTaskGroup { group in
                group.addTask {
                    await self.handleInvokeWorkloadResponse(
                        originalResponseContinuation: originalResponseContinuation,
                        bypassResponseContinuation: bypassResponseContinuation,
                        grpcResponseStream: grpcResponseStream,
                        authenticatedRequestContinuation: authenticatedRequestContinuation,
                        requestParameters: requestParameters
                    )
                    bypassResponseContinuation.finish()
                }

                // decapsulate response payload from the original PCC node
                group.addTask {
                    var receivedFinalRequestExecutionLogEntry = false
                    var responseAssembler: LengthPrefixAssembler?
                    if case .enabled = applicationDataChunkingConfiguration {
                        responseAssembler = LengthPrefixAssembler()
                    }
                    do {
                        for try await chunk in originalResponseStream {
                            let pccResponseContinuation: AsyncThrowingStream<PrivateCloudComputeResponse, Error>
                                .Continuation
                            switch responseStreamContext {
                            case .encryptedPayload(_, let continuation):
                                continuation.yield(chunk.encryptedPayload)
                                if chunk.isFinal {
                                    continuation.finish()
                                }
                                continue
                            case .privateCloudComputeResponse(_, let continuation):
                                pccResponseContinuation = continuation
                            }
                            guard chunk.encryptedPayload.count > 0 else {
                                pccResponseContinuation.yield(PrivateCloudComputeResponse.payload(.init()))
                                continue
                            }
                            var data = try oHTTPStreamingResponseDecapsulator.decapsulateResponseMessage(
                                chunk.encryptedPayload,
                                isFinal: chunk.isFinal
                            )
                            if let chunkData = data.readLengthPrefixedChunk() {
                                let pccResponse = try LocalCloudBoardGRPCAsyncClient
                                    .ProtoPrivateCloudComputeResponse(serializedBytes: chunkData)
                                if case .requestExecutionLogEntry(let requestExecutionLogEntry) = pccResponse.type {
                                    if receivedFinalRequestExecutionLogEntry {
                                        LocalCloudBoardGRPCAsyncClient.logger.error(
                                            "Request execution log entry received after getting the final request execution log entry"
                                        )
                                    }
                                    if requestExecutionLogEntry.hasResponseContext {
                                        bypassDecapContinuation.yield(requestExecutionLogEntry.responseContext)
                                        bypassDecapContinuation.finish()
                                    }
                                    LocalCloudBoardGRPCAsyncClient.logger.log(
                                        "Received request execution log entry \(String(describing: requestExecutionLogEntry), privacy: .public)"
                                    )
                                    try pccResponseContinuation.yield(self.convertToClientResponse(
                                        pccResponse,
                                        attestationEnvironment: self.attestationEnvironment,
                                        trustedProxyAttestationBundle: parsedAttestationBundle,
                                        endpoint: self.initialClient.endPoint,
                                    ))
                                    if requestExecutionLogEntry.final {
                                        receivedFinalRequestExecutionLogEntry = true
                                        LocalCloudBoardGRPCAsyncClient.logger
                                            .log("Received final request execution log entry")
                                    }
                                } else {
                                    let clientResponse = try self.convertToClientResponse(
                                        pccResponse,
                                        attestationEnvironment: self.attestationEnvironment
                                    )
                                    if responseAssembler != nil,
                                       case .payload(let payloadData) = clientResponse, !payloadData.isEmpty {
                                        let reassembledMessages = try responseAssembler!.append(payloadData)
                                        for message in reassembledMessages {
                                            pccResponseContinuation
                                                .yield(PrivateCloudComputeResponse.payload(message))
                                        }
                                    } else {
                                        pccResponseContinuation.yield(clientResponse)
                                    }
                                }
                            } else {
                                pccResponseContinuation.yield(PrivateCloudComputeResponse.payload(.init()))
                            }
                        }
                        if let responseAssembler {
                            try responseAssembler.finish()
                        }
                        if !receivedFinalRequestExecutionLogEntry {
                            LocalCloudBoardGRPCAsyncClient.logger
                                .error("Final request execution log entry not received for the request")
                        }
                    } catch {
                        responseStreamContext.finishStream(throwing: error)
                    }
                }

                // optionally decapsulate response payload from the worker node
                group.addTask {
                    guard initialClient.isProxy else {
                        bypassResponseContinuation.finish()
                        return
                    }
                    var bypassDecapsulator: StreamingResponseBypassDecapsulator?
                    var bypassResponseAssembler: LengthPrefixAssembler?
                    if case .enabled = applicationDataChunkingConfiguration {
                        bypassResponseAssembler = LengthPrefixAssembler()
                    }
                    for try await chunk in bypassResponseStream {
                        let pccResponseContinuation: AsyncThrowingStream<PrivateCloudComputeResponse, Error>
                            .Continuation
                        switch responseStreamContext {
                        case .encryptedPayload(_, let continuation):
                            continuation.yield(chunk.encryptedPayload)
                            if chunk.isFinal {
                                continuation.finish()
                            }
                            continue
                        case .privateCloudComputeResponse(_, let continuation):
                            pccResponseContinuation = continuation
                        }

                        // Wait for Decapsulator to be available
                        if bypassDecapsulator == nil {
                            var decapIter = bypassDecapStream.makeAsyncIterator()
                            let bypassContext = await decapIter.next()
                            guard let bypassContext else {
                                throw LocalCloudBoardGRPCClientError.failedToGetBypassDecapsulator
                            }
                            let aeadType = if HPKE.AEAD.AES_GCM_128.value == bypassContext.aeadID {
                                HPKE.AEAD.AES_GCM_128
                            } else if HPKE.AEAD.AES_GCM_256.value == bypassContext.aeadID {
                                HPKE.AEAD.AES_GCM_256
                            } else {
                                throw LocalCloudBoardGRPCClientError.invalidAeadType
                            }
                            bypassDecapsulator = try StreamingResponseBypassDecapsulator(
                                aead: aeadType,
                                aeadKey: SymmetricKey(data: bypassContext.aeadKey),
                                aeadNonce: bypassContext.aeadNonce
                            )
                        }

                        guard chunk.encryptedPayload.count > 0 else {
                            pccResponseContinuation.yield(PrivateCloudComputeResponse.payload(.init()))
                            continue
                        }

                        precondition(bypassDecapsulator != nil)
                        var data = try bypassDecapsulator!.decapsulateResponseMessage(
                            chunk.encryptedPayload,
                            isFinal: chunk.isFinal
                        )
                        if let chunkData = data.readLengthPrefixedChunk() {
                            let pccResponse = try LocalCloudBoardGRPCAsyncClient
                                .ProtoPrivateCloudComputeResponse(serializedBytes: chunkData)
                            let clientResponse = try self.convertToClientResponse(
                                pccResponse,
                                attestationEnvironment: self.attestationEnvironment
                            )
                            if bypassResponseAssembler != nil,
                               case .payload(let payloadData) = clientResponse, !payloadData.isEmpty {
                                let reassembledMessages = try bypassResponseAssembler!.append(payloadData)
                                for message in reassembledMessages {
                                    pccResponseContinuation
                                        .yield(PrivateCloudComputeResponse.payload(message))
                                }
                            } else {
                                pccResponseContinuation.yield(clientResponse)
                            }
                        } else {
                            pccResponseContinuation.yield(PrivateCloudComputeResponse.payload(.init()))
                        }
                        LocalCloudBoardGRPCAsyncClient.logger
                            .log("Sent (bypassed) response chunk from compute to client")
                    }
                    if let bypassResponseAssembler {
                        try bypassResponseAssembler.finish()
                    }
                }
            }
            responseStreamContext.finishStream()
        }

        return .init(
            requestStreamContext: requestStreamContext,
            responseStreamContext: responseStreamContext,
            nackRequests: nackRequests,
            nackResponseStreams: nackResponseStreams
        )
    }

    private func handleInvokeWorkloadResponse(
        originalResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation,
        bypassResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation,
        grpcResponseStream: GRPCAsyncResponseStream<InvokeWorkloadResponse>,
        authenticatedRequestContinuation: any BypassContinuationProtocol<InvokeWorkloadRequest>,
        requestParameters: InvokeWorkloadRequest.Parameters
    ) async {
        var workloadResponseIterator = grpcResponseStream.makeAsyncIterator()
        do {
            try await withThrowingDiscardingTaskGroup { group in
                while let message = try await workloadResponseIterator.next() {
                    switch message.type {
                    case .invokeProxyInitiate(let proxyInitiate):
                        LocalCloudBoardGRPCAsyncClient.logger.log("Received proxy initiate")
                        if authenticatedRequestContinuation.hasPendingBypass {
                            if !proxyInitiate.forwardBypassedRequestChunks {
                                LocalCloudBoardGRPCAsyncClient.logger.error(
                                    "Pending bypassed request chunks but proxy did not request for them to be forwarded."
                                )
                                throw LocalCloudBoardGRPCClientError.expectedRequestToForwardBypassedRequestChunks
                            }
                            LocalCloudBoardGRPCAsyncClient.logger.log(
                                "Will forward the original request stream to worker"
                            )
                        }
                        group.addTask {
                            try await self.handleProxyWorkflow(
                                originalRequestParameters: requestParameters,
                                proxyInitiate: proxyInitiate,
                                potentialRequestByPass: authenticatedRequestContinuation,
                                bypassMode: proxyInitiate.responseBypassMode,
                                bypassResponseContinuation: bypassResponseContinuation
                            )
                        }
                    case .responseChunk(let chunk):
                        LocalCloudBoardGRPCAsyncClient.logger.log(
                            "Received response chunk of \(chunk.encryptedPayload.count) bytes"
                        )
                        originalResponseContinuation.yield(chunk)
                    case .setupAck:
                        LocalCloudBoardGRPCAsyncClient.logger.log("Received setup ack")
                    case .proxyWorkerError(let proxyError):
                        LocalCloudBoardGRPCAsyncClient.logger
                            .log("Received proxy worker error for workerId: \(proxyError.taskID, privacy: .public)")
                        let error: Error = self.proxyWorkerErrors.withLock {
                            $0[proxyError.taskID]
                        } ?? LocalCloudBoardGRPCClientError.proxyInternalError
                        originalResponseContinuation.finish(throwing: error)
                    case .requestExecutionError(let error):
                        LocalCloudBoardGRPCAsyncClient.logger.log(
                            """
                            Received requestExecutionError:
                            errorSource: \(error.source.rawValue, privacy: .public)
                            errorMessage: \(error.errorMessage, privacy: .public)
                            errorCode: \(error.errorCode, privacy: .public)
                            """
                        )
                    default:
                        LocalCloudBoardGRPCAsyncClient.logger.warning("Received something unknown")
                    }
                }
                originalResponseContinuation.finish()
            }
        } catch {
            originalResponseContinuation.finish(throwing: error)
        }
    }

    /// Replays a request. Request data for this call is retrieved from the specified file. The data should be
    /// presented as InvokeWorkload GRPC messages, with the first message being InvokeWorkload.Parameters.
    /// The response stream is expected to throw if the request is replayed against a node that has seen the DEK,
    /// because of anti-replay protection.
    /// - Parameter requestMessagesFileURL: URL of the file that contains all the request messages, including the
    /// parameters message
    /// - Parameter parametersOverrideFileURL: URL of the file that contains the parameters message. If not specified,
    /// will use the parameters message from the request messages file
    /// - Parameter requestIDOverride: Overrides the requestID in the parameters message
    /// - Parameter requestBypassOverride: Overrides the requestBypassed flag in the parameters message
    /// - Parameter metaDataOverride: Overrides the meta data in the parameters message
    /// - Returns: PCC encrypted response stream
    public func replayRequest(
        requestMessagesFileURL: URL,
        parametersOverrideFileURL: URL? = nil,
        requestIDOverride: String? = nil,
        requestBypassOverride: Bool? = nil,
        metaDataOverride: InvokeWorkloadRequestMetaData? = nil
    ) async throws -> (AsyncThrowingStream<Data, Error>) {
        var requestMessagesData = try Data(contentsOf: requestMessagesFileURL)

        let parametersOverride: InvokeWorkloadRequest.Parameters?
        if let parametersOverrideFileURL {
            var lengthPrefixedData = try Data(contentsOf: parametersOverrideFileURL)
            let messageData = lengthPrefixedData.readLengthPrefixedChunk()
            let message = try messageData.map { try InvokeWorkloadRequest(serializedBytes: $0) }
            if let message, case .parameters(let parameters) = message.type {
                parametersOverride = parameters
            } else {
                fatalError("ParametersOverrideFile does not have the parameters message")
            }
        } else {
            parametersOverride = nil
        }

        let (requestStream, requestContinuation) = AsyncStream<InvokeWorkloadRequest>.makeStream()
        while true {
            let messageData = requestMessagesData.readLengthPrefixedChunk()
            guard let messageData else {
                break
            }
            let message = try InvokeWorkloadRequest(serializedBytes: messageData)
            switch message.type {
            case .parameters(var parameters):
                if let parametersOverride {
                    parameters = parametersOverride
                }
                if let requestIDOverride {
                    parameters.requestID = requestIDOverride
                }
                if let requestBypassOverride {
                    parameters.requestBypassed = requestBypassOverride
                }
                if let metaDataOverride {
                    parameters.workload = .init(
                        type: metaDataOverride.workloadType,
                        parameters: metaDataOverride.workloadParameters
                    )
                }
                parameters.requestNack = false
                requestContinuation.yield(InvokeWorkloadRequest.with { $0.parameters = parameters })
                Self.logger.debug("Replay request - provided parameters message")
            default:
                requestContinuation.yield(message)
            }
        }
        requestContinuation.finish()
        Self.logger.debug("Replay request - provided all messages")

        let session = try await self.streamPrivateRequestInternal(
            requestSender: .invokeWorkloadRequestSender(requestStream: requestStream),
            cryptoMaterial: nil
        )
        guard case .forInvokeWorkloadRequestSender(let responseStream) = session else {
            fatalError("Unexpected request session type")
        }
        return responseStream
    }

    // The NACK is very strictly defined, within the limitations of our current ROPES interaction.
    private enum NackStateMachine {
        // 1: setupAck. The client device would not see this, but ROPES would
        // - In theory this could be optional but for now it is not
        case expectingSetupAck
        // 2: responseChunk containing responseUuid
        // - The client requires this, so we send it regardless
        case expectingResponseUuid
        // 3: responseChunk containing requestExecutionLogEntry
        // - This must be empty (no attestation, no context info) and final
        case expectingRequestExecutionLogEntry
        // 4: responseChunk containing responseSummary with status .ok
        case expectingResponseSummary
        // No further entries are allowed
        case complete

        var willAcceptResponseChunk: Bool {
            switch self {
            case .expectingSetupAck:
                false
            case .expectingResponseUuid, .expectingRequestExecutionLogEntry, .expectingResponseSummary:
                true
            case .complete:
                false
            }
        }

        func moveToNext() -> NackStateMachine {
            switch self {
            case .expectingSetupAck:
                .expectingResponseUuid
            case .expectingResponseUuid:
                .expectingRequestExecutionLogEntry
            case .expectingRequestExecutionLogEntry:
                .expectingResponseSummary
            case .expectingResponseSummary:
                .complete
            case .complete:
                fatalError("attempt to advance past complete!")
            }
        }
    }

    private func processAndValidateNack(
        requestID: String,
        metaData: InvokeWorkloadRequestMetaData,
        client: StatefulClient,
        nackResponseContinuation: AsyncThrowingStream<PrivateCloudComputeResponse, Error>.Continuation,
        requestDumpFileURL: URL? = nil
    ) async throws {
        // We let some errors just percolate up, but anything due to the response from the node should be
        // a nicely described NackError
        let attestation = try await client.getAttestation()
        let cloudOSNodePublicKeyID = attestation.keyID
        let (
            publicKey,
            parsedAttestationBundle
        ) = try await parseAndValidateAttestationBundle(attestation.attestationBundle)

        // create an ohttp request stream
        var oHTTPClientStateMachine = self.makeClientStateMachine()
        var (encapsulatedKey, oHTTPStreamingResponseDecapsulator) = try oHTTPClientStateMachine.encapsulateKey(
            publicKey: publicKey,
            ciphersuite: .Curve25519_SHA256_AES_GCM_128
        )

        let asyncWorkloadClient = WorkloadAsyncClientStream(client: client.client)
        let (initialAuthenticatedRequestContinuation, grpcResponseStream) = asyncWorkloadClient.startSetup()

        let requestParameters = asyncWorkloadClient.makeParameters(
            decryptionKey: .helper(keyID: cloudOSNodePublicKeyID, key: encapsulatedKey),
            requestID: requestID,
            metaData: metaData,
            requestBypassed: true,
            responseBypass: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode.none,
            requestNack: true
        )
        let requestParametersGRPCMessage = asyncWorkloadClient.wrapParameters(requestParameters)
        initialAuthenticatedRequestContinuation.yield(requestParametersGRPCMessage)
        // nothing else is sent down the request
        initialAuthenticatedRequestContinuation.finish()
        if let requestDumpFileURL {
            Self.logger.info("""
            Dumping parameters message for \(client.endPoint, privacy: .public) \
            to \(requestDumpFileURL.path, privacy: .public)
            """)
            try requestParametersGRPCMessage.serialized().write(to: requestDumpFileURL)
        }

        // Receive messages from PCC Node
        var workloadResponseIterator = grpcResponseStream.makeAsyncIterator()
        var state = NackStateMachine.expectingSetupAck
        do {
            var receivedFinalRequestExecutionLogEntry = false
            while let message = try await workloadResponseIterator.next() {
                switch message.type {
                case .setupAck:
                    LocalCloudBoardGRPCAsyncClient.logger.log(
                        "NACK request for \(client.endPoint, privacy: .public) received setup ack"
                    )
                    guard case .expectingSetupAck = state else {
                        throw NackError(client.endPoint, "\(state) but received a setup ack")
                    }
                    state = state.moveToNext()
                case .responseChunk(let chunk):
                    LocalCloudBoardGRPCAsyncClient.logger.log(
                        "NACK stream for \(client.endPoint, privacy: .public) received response chunk of \(chunk.encryptedPayload.count, privacy: .public) bytes"
                    )
                    guard state.willAcceptResponseChunk else {
                        throw NackError(client.endPoint, "\(state) but received a responseChunk")
                    }
                    var data = try oHTTPStreamingResponseDecapsulator.decapsulateResponseMessage(
                        chunk.encryptedPayload,
                        isFinal: chunk.isFinal
                    )
                    guard let chunkData = data.readLengthPrefixedChunk() else {
                        throw NackError(client.endPoint, "response did not contain a length prefixed chunk")
                    }
                    let pccResponse = try LocalCloudBoardGRPCAsyncClient
                        .ProtoPrivateCloudComputeResponse(serializedBytes: chunkData)
                    guard let type = pccResponse.type else {
                        throw NackError(client.endPoint, "response had no proto type")
                    }
                    switch type {
                    case .responseUuid:
                        guard case .expectingResponseUuid = state else {
                            throw NackError(client.endPoint, "\(state) but received a responseUuid")
                        }
                        LocalCloudBoardGRPCAsyncClient.logger
                            .log(
                                "Received responseUuid for NACK from \(client.endPoint, privacy: .public)"
                            )
                        try nackResponseContinuation.yield(self.convertToClientResponse(
                            pccResponse,
                            attestationEnvironment: self.attestationEnvironment
                        ))
                        state = state.moveToNext()
                    case .responsePayload:
                        throw NackError(client.endPoint, "responsePayload is never allowed")
                    case .responseSummary(let summary):
                        guard case .expectingResponseSummary = state else {
                            throw NackError(client.endPoint, "\(state) but received a responseSummary")
                        }
                        guard summary.responseStatus == .ok else {
                            throw NackError(client.endPoint, "responseSummary had status \(summary.responseStatus)")
                        }
                        try nackResponseContinuation.yield(self.convertToClientResponse(
                            pccResponse,
                            attestationEnvironment: self.attestationEnvironment
                        ))
                        state = state.moveToNext()
                    case .requestExecutionLogEntry(let requestExecutionLogEntry):
                        guard case .expectingRequestExecutionLogEntry = state else {
                            throw NackError(client.endPoint, "\(state) but received a requestExecutionLogEntry")
                        }
                        guard !requestExecutionLogEntry.hasAttestation else {
                            throw NackError(client.endPoint, "the request execution log entry had an attestation")
                        }
                        guard !requestExecutionLogEntry.hasResponseContext else {
                            throw NackError(client.endPoint, "the request execution log entry had a response context")
                        }
                        guard !requestExecutionLogEntry.hasAttestation else {
                            throw NackError(client.endPoint, "the request execution log entry had an attestation")
                        }
                        if receivedFinalRequestExecutionLogEntry {
                            LocalCloudBoardGRPCAsyncClient.logger
                                .warning(
                                    "request execution log entry received after getting the final request execution log entry"
                                )
                        }
                        if requestExecutionLogEntry.final {
                            receivedFinalRequestExecutionLogEntry = true
                        }
                        try nackResponseContinuation.yield(self.convertToClientResponse(
                            pccResponse,
                            attestationEnvironment: self.attestationEnvironment,
                            isNack: true,
                            trustedProxyAttestationBundle: parsedAttestationBundle,
                            endpoint: client.endPoint
                        ))
                        LocalCloudBoardGRPCAsyncClient.logger.log(
                            "Received empty request execution log entry NACK from \(client.endPoint, privacy: .public)"
                        )
                        state = state.moveToNext()
                    case .payloadChunk, .subClose, .subOpen, .componentTimeMeasurement, .costToken, .reputationToken,
                         .compressedExecutionLogEntry:
                        // Unsupported in V1 of LocalCloudBoardClient
                        ()
                    }
                default:
                    guard let type = message.type else {
                        throw NackError(client.endPoint, "sent message without a type")
                    }
                    throw NackError(client.endPoint, "sent \(type) instead of a .setupAck or .responseChunk")
                }
            }
            if !receivedFinalRequestExecutionLogEntry {
                LocalCloudBoardGRPCAsyncClient.logger
                    .warning("Final request execution log entry not received for the Nack request")
            }
            guard case .complete = state else {
                throw NackError(client.endPoint, "\(state) the response stream finished")
            }
            nackResponseContinuation.finish()
        } catch let error as NackError {
            nackResponseContinuation.finish(throwing: error)
            throw error
        } catch {
            let err = NackError(client.endPoint, "Unexpected error \(String(describing: error))")
            nackResponseContinuation.finish(throwing: err)
            throw err
        }
        LocalCloudBoardGRPCAsyncClient.logger.log(
            "NACK request for \(client.endPoint, privacy: .public) considered successful"
        )
    }

    private func parseComputeNodeAttestationBundle(_ attestationBundle: Data) throws
    -> LocalCloudBoardAttestationBundle {
        do {
            if let fakeBundle = try TestOnlyAttestationBundle(data: attestationBundle) {
                return LocalCloudBoardAttestationBundle(testOnlyAttestationBundle: fakeBundle)
            } else {
                let bundle = try AttestationBundle(data: attestationBundle)
                return try LocalCloudBoardAttestationBundle(unvalidated: bundle, validated: nil)
            }
        } catch {
            LocalCloudBoardGRPCAsyncClient.logger.log(
                "Failed to extract key from CloudAttestation attestation bundle: error (\(error, privacy: .public))"
            )
            throw LocalCloudBoardGRPCClientError.failedToParseCloudAttestationBundle(error)
        }
    }

    private func parseAndValidateAttestationBundle(_ attestationBundle: Data) async throws
    -> (Curve25519.KeyAgreement.PublicKey, LocalCloudBoardAttestationBundle) {
        if let fakeBundle = try TestOnlyAttestationBundle(data: attestationBundle) {
            LocalCloudBoardGRPCAsyncClient.logger.log(
                """
                Received \(attestationBundle.count, privacy: .public)-byte attestation bundle \
                that parsed as a fake bundle format: \(fakeBundle.version, privacy: .public)
                """
            )
            return (fakeBundle.publicKey, LocalCloudBoardAttestationBundle(testOnlyAttestationBundle: fakeBundle))
        } else {
            LocalCloudBoardGRPCAsyncClient.logger
                .log("Received CloudAttestation attestation bundle. Extracting public key.")
            do {
                let bundle = try AttestationBundle(data: attestationBundle)
                let validator = CloudAttestation.NodeValidator(environment: self.attestationEnvironment)
                let (key, validity, validatedAttestation) = try await validator.validate(bundle: bundle)
                LocalCloudBoardGRPCAsyncClient.logger.log(
                    "Verified attestation bundle with validity \(validity, privacy: .public) and expiration \(validatedAttestation.keyExpiration, privacy: .public), key: \(String(describing: key), privacy: .public)"
                )

                let rawKey: Data
                switch key {
                case .x963(let rawData):
                    rawKey = rawData
                case .curve25519(let rawData):
                    rawKey = rawData
                default:
                    LocalCloudBoardGRPCAsyncClient.logger.log("Unknown key type in attestation bundle")
                    throw LocalCloudBoardGRPCClientError.unknownKeyType(String(describing: key))
                }
                let publicKey = try Curve25519.KeyAgreement.PublicKey(rawKey, kem: .Curve25519_HKDF_SHA256)
                return try (
                    publicKey,
                    LocalCloudBoardAttestationBundle(unvalidated: bundle, validated: validatedAttestation)
                )
            } catch {
                LocalCloudBoardGRPCAsyncClient.logger.log(
                    "Failed to extract key from CloudAttestation attestation bundle: error (\(error, privacy: .public))"
                )
                throw LocalCloudBoardGRPCClientError.failedToParseCloudAttestationBundle(error)
            }
        }
    }

    private func selectWorkerNode(context: ChooseWorkerContext) -> InvokeProxyInitiateResult {
        // This is the probable point at which the pick negotiation would be (semi transparently) handled)
        return self.proxyInvokeClientChoice(context)
    }

    private func handleProxyWorkflow(
        originalRequestParameters: Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest.Parameters,
        proxyInitiate: Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate,
        // Request bypass
        potentialRequestByPass: any BypassContinuationProtocol<InvokeWorkloadRequest>,
        // Response bypass
        bypassMode: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode,
        bypassResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation
    ) async throws {
        guard self.initialClient.isProxy else {
            throw LocalCloudBoardGRPCClientError.proxyClientNotSet
        }
        let workerContext = ChooseWorkerContext(
            originalRequestParameters: originalRequestParameters,
            initiate: proxyInitiate,
            forceReuseFailure: self._forceReuseFailure.withLock { $0 },
            groupID: proxyInitiate.groupID
        )
        // pick the compute node
        let selectionResult = self.selectWorkerNode(context: workerContext)
        switch selectionResult {
        case .unavailable:
            return self.handleFailureToFindWorker(
                workerId: workerContext.initiate.taskId,
                errorCode: LocalCloudBoardGRPCClientProxyWorkflowError.unknownWorkload.rawValue
            )
        case .pick:
            fatalError("pick flow is not implemented! pick flow is only supported in LocalCloudBoardClient V2")
        case .directChoice(let chosenWorker, workload: let workload):
            return await chosenWorker.withValueAsync { statefulClient in
                return await self.handleProxyWorkflowWithChosenWorker(
                    workerContext: workerContext,
                    workload: workload,
                    potentialRequestByPass: potentialRequestByPass,
                    bypassMode: bypassMode,
                    bypassResponseContinuation: bypassResponseContinuation,
                    compute: statefulClient
                )
            }
        }
    }

    private func handleFailureToFindWorker(workerId: String, errorCode: UInt32) {
        ProxyDialBackStream(client: self.initialClient.client).workerNotFound(workerId: workerId, errorCode: errorCode)
    }

    private func handleProxyWorkflowWithChosenWorker(
        workerContext: ChooseWorkerContext,
        workload: [String: [String]],
        // Request bypass
        potentialRequestByPass: any BypassContinuationProtocol<InvokeWorkloadRequest>,
        // Response bypass
        bypassMode: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode,
        bypassResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation,
        compute: StatefulClient
    ) async {
        let workerId = workerContext.initiate.taskId
        let proxyDialBackStream = ProxyDialBackStream(client: initialClient.client)
        let (proxyDialBackContinuation, proxyDialBackResponseStream) =
            proxyDialBackStream.startDialBackStream(workerId: workerId)

        let computeAttestation: PrivateCloudComputeAttestationResponse
        do {
            // Create Grpc connection with the compute node
            computeAttestation = try await compute.getAttestation()
        } catch {
            self.closeProxyDialBackRequestOnError(
                workerId: workerId,
                proxyDialBackContinuation: proxyDialBackContinuation,
                error: error,
                ropesErrorCode: LocalCloudBoardGRPCClientProxyWorkflowError.nodesBusy.rawValue
            )
            return
        }
        // Make sure the workload passed to the worker matches that passed back to the proxy and are
        // consistent with ROPES semantics.
        // ROPES passes through all inputs, on an application specific basis it might inject additional ones
        // like RunMode for TIE - if someone wants to test that they can use the FullControl path
        let workloadPostRopes = workload
        let metaData = InvokeWorkloadRequestMetaData(
            workloadType: workerContext.initiate.workloadType,
            workloadParameters: workloadPostRopes,
        )
        let workloadProto = Proto_Ropes_Common_Workload.with {
            $0.type = workerContext.initiate.workloadType
            $0.param = .init(metaData.workloadParameters)
        }
        proxyDialBackContinuation.yield(ProxyDialBackStream.initiateProxyWorkerSelected(
            attestation: computeAttestation,
            workload: workloadProto,
            isResponseBypass: bypassMode == .matchRequestCiphersuiteSharedAeadState
        ))

        do {
            try await self.handleProxyWorkflowMessages(
                workerContext: workerContext,
                metaData: metaData,
                potentialRequestByPass: potentialRequestByPass,
                bypassMode: bypassMode,
                bypassResponseContinuation: bypassResponseContinuation,
                compute: compute,
                proxyDialBackResponseStream: proxyDialBackResponseStream,
                proxyDialBackContinuation: proxyDialBackContinuation
            )
        } catch {
            self.closeProxyDialBackRequestOnError(
                workerId: workerId,
                proxyDialBackContinuation: proxyDialBackContinuation,
                error: error
            )
        }
    }

    private func handleProxyWorkflowMessages(
        workerContext: ChooseWorkerContext,
        metaData: InvokeWorkloadRequestMetaData,
        potentialRequestByPass: any BypassContinuationProtocol<InvokeWorkloadRequest>,
        bypassMode: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode,
        bypassResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation,
        compute: StatefulClient,
        proxyDialBackResponseStream: GRPCAsyncResponseStream<InvokeProxyDialBackResponse>,
        proxyDialBackContinuation: AsyncStream<Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackRequest>.Continuation,
    ) async throws {
        // Assumption: proxy node will first return the DEK, before any chunks
        var proxyDialBackMessageIterator = proxyDialBackResponseStream.makeAsyncIterator()
        let dekMessageFromProxy = try await proxyDialBackMessageIterator.next()

        guard let dekMessage = dekMessageFromProxy else {
            throw LocalCloudBoardGRPCClientError.proxyToComputeDEKInvalid
        }

        guard dekMessage.proxyToComputeMessage.isInitialized,
              dekMessage.proxyToComputeMessage.decryptionKey.isInitialized else {
            throw LocalCloudBoardGRPCClientError.proxyToComputeDEKInvalid
        }
        let dekFromProxyToComputeNode = dekMessage.proxyToComputeMessage.decryptionKey

        let computeWorkloadStream = WorkloadAsyncClientStream(client: compute.client)
        let (computeRequestContinuation, computeResponseStream) = computeWorkloadStream
            .startWorkload(
                decryptionKey: .explicit(dek: dekFromProxyToComputeNode),
                // The requestId on worker requests is the same as the original
                // We consider this the trace (and until there is a specific TraceID this fulfills that need)
                requestID: workerContext.originalRequest.requestID,
                metaData: metaData,
                // the bypass is to indicate to the proxy it's not getting the message
                requestBypassed: false,
                responseByPass: bypassMode
            )
        // The computeRequestContinuation has now had the:
        // - warmup
        // - parameters (DEK)
        // sent to it
        // If there is a pending request bypass hook it up; otherwise the proxy needs to deal with
        // forwarding the open message (or making a new one if that is the agreed semantics)
        let allowPayloadMessagesFromProxy: Bool
        if potentialRequestByPass.hasPendingBypass {
            allowPayloadMessagesFromProxy = false
            // This will not only flush the buffer, it will also
            // wire up any subsequent messages to the worker as well
            try potentialRequestByPass.connect(target: computeRequestContinuation)
        } else {
            allowPayloadMessagesFromProxy = true
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Handle messages from Proxy App
            group.addTask {
                try await self.handleProxyWorkflowProxyMessages(
                    proxyDialBackMessageIterator: &proxyDialBackMessageIterator,
                    allowPayloadMessagesFromProxy: allowPayloadMessagesFromProxy,
                    computeRequestContinuation: computeRequestContinuation
                )
            }

            // Handle messages from compute node
            group.addTask {
                do {
                    try await self.handleProxyWorkflowWorkerMessages(
                        computeResponseStream: computeResponseStream,
                        isResponseBypassMode: bypassMode == .matchRequestCiphersuiteSharedAeadState,
                        bypassResponseContinuation: bypassResponseContinuation,
                        proxyDialBackContinuation: proxyDialBackContinuation
                    )
                } catch {
                    self.closeProxyDialBackRequestOnError(
                        workerId: workerContext.initiate.taskId,
                        proxyDialBackContinuation: proxyDialBackContinuation,
                        error: error
                    )
                }
            }

            try await group.waitForAll()
        }
    }

    private func handleProxyWorkflowProxyMessages(
        proxyDialBackMessageIterator: inout GRPCAsyncResponseStream<InvokeProxyDialBackResponse>.Iterator,
        allowPayloadMessagesFromProxy: Bool,
        computeRequestContinuation: AsyncStream<InvokeWorkloadRequest>.Continuation
    ) async throws {
        proxyMessages: while let dialBackMessage = try await proxyDialBackMessageIterator.next() {
            switch dialBackMessage.type {
            case .proxyToComputeMessage(let proxyToComputeMessage):
                switch proxyToComputeMessage.type {
                case .decryptionKey:
                    throw LocalCloudBoardGRPCClientError.proxyToComputeDEKInvalid
                case .requestChunk(let chunk):
                    // it's not actually clear what ROPES will do if we try to also send messages
                    // to the worker node, but since the result will be a mangled mess thanks to the
                    // sequence numbers we know we don't ever want to so lets make our testing
                    // environments fail immediately on breaking that contract
                    guard allowPayloadMessagesFromProxy else {
                        throw LocalCloudBoardGRPCClientError.requestChunkFromProxyWhenRequestBypassConfigured
                    }
                    computeRequestContinuation.yield(InvokeWorkloadRequest.with {
                        $0.requestChunk = chunk
                    })
                    LocalCloudBoardGRPCAsyncClient.logger.log("Sent workload chunk to compute node")
                default:
                    LocalCloudBoardGRPCAsyncClient.logger
                        .log("Received an non interesting message from compute node")
                }
            case .close:
                // this is tricksy - if there is bypass we may want to close both
                // if we suppose the proxy can 'take itself out of the loop' then the close just
                // gets ignored. For now that's not a mode of operation we support
                // so just convert the close into a close finish regardless of the bypass
                LocalCloudBoardGRPCAsyncClient.logger.log("Received proxy close notification")
                computeRequestContinuation.finish()
                break proxyMessages
            default:
                // ropes does not do blind forwarding of messages it doesn't understand so just
                // dropping this is fine conceptually, but worth noting we do in case it means we
                // missed something changing
                LocalCloudBoardGRPCAsyncClient.logger.log(
                    "Received an non interesting message from Proxy App \(dialBackMessage.type.debugDescription)"
                )
            }
        }
        LocalCloudBoardGRPCAsyncClient.logger.debug("Finished proxyDialBackResponseStream")
    }

    private func handleProxyWorkflowWorkerMessages(
        computeResponseStream: GRPCAsyncResponseStream<Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse>,
        isResponseBypassMode: Bool,
        bypassResponseContinuation: AsyncThrowingStream<Proto_Ropes_Common_Chunk, Error>.Continuation,
        proxyDialBackContinuation: AsyncStream<ProxyDialBackStream.InvokeProxyDialBackRequest>.Continuation
    ) async throws {
        var computeResponseStreamIterator = computeResponseStream.makeAsyncIterator()
        while let computeMessage = try await computeResponseStreamIterator.next() {
            switch computeMessage.type {
            case .responseChunk(let chunk):
                if isResponseBypassMode {
                    // Response bypass enabled, send the response directly to the client
                    bypassResponseContinuation.yield(chunk)
                } else {
                    // Response bypass not enabled, send back to proxy app
                    proxyDialBackContinuation.yield(ProxyDialBackStream.InvokeProxyDialBackRequest.with {
                        $0.computeToProxyMessage = .with {
                            $0.responseChunk = chunk
                        }
                    })
                    LocalCloudBoardGRPCAsyncClient.logger.log("Sent response chunk from compute to proxy")
                }
            case .setupAck:
                LocalCloudBoardGRPCAsyncClient.logger.log("Received setup ack from compute")
            case .requestExecutionError(let error):
                LocalCloudBoardGRPCAsyncClient.logger.log(
                    """
                    Received requestExecutionError from compute node:
                    errorSource: \(error.source.rawValue, privacy: .public)
                    errorMessage: \(error.errorMessage, privacy: .public)
                    errorCode: \(error.errorCode, privacy: .public)
                    """
                )
            default:
                LocalCloudBoardGRPCAsyncClient.logger.error(
                    "Received computeMessage of unknown type: \(String(describing: computeMessage.type))"
                )
                throw LocalCloudBoardGRPCClientError.invalidComputeNodeMessage
            }
        }
        proxyDialBackContinuation.yield(ProxyDialBackStream.InvokeProxyDialBackRequest.with {
            $0.close = .init()
        })
        proxyDialBackContinuation.finish()
    }

    internal static func validateComputeNodeAttestationInRequestExecutionLogEntry(
        bundle: AttestationBundle,
        attestationEnvironment: CloudAttestation.Environment
    ) {
        Task {
            do {
                let validator = CloudAttestation.NodeValidator(environment: attestationEnvironment)
                let (key, validity, validatedAttestation) = try await validator.validate(bundle: bundle)
                LocalCloudBoardGRPCAsyncClient.logger.log("""
                Verified attestation bundle for compute node in request execution log entry
                    validity: \(validity, privacy: .public),
                    expiration: \(validatedAttestation.keyExpiration, privacy: .public),
                    key: \(String(describing: key), privacy: .public)
                """)
            } catch {
                LocalCloudBoardGRPCAsyncClient.logger.error(
                    "Attestation validation failed for compute node attestation in request execution log entry: \(error)"
                )
            }
        }
    }

    public var fullFidelityResponseSummary: Bool = false

    internal func convertToClientResponse(
        _ pccResponse: ProtoPrivateCloudComputeResponse,
        attestationEnvironment: CloudAttestation.Environment,
        isNack: Bool = false,
        trustedProxyAttestationBundle: LocalCloudBoardAttestationBundle? = nil,
        endpoint: EndPoint? = nil
    ) throws -> PrivateCloudComputeResponse {
        let message: PrivateCloudComputeResponse
        switch pccResponse.type {
        case .responseUuid(let uuidData):
            if let uuid = UUID(from: uuidData) {
                message = PrivateCloudComputeResponse.responseID(uuid)
            } else {
                throw LocalCloudBoardGRPCClientError.invalidUUIDInCloudComputeResponse
            }
        case .responsePayload(let payloadData):
            message = PrivateCloudComputeResponse.payload(payloadData)
        case .responseSummary(let responseSummary):
            if self.fullFidelityResponseSummary {
                message = PrivateCloudComputeResponse.responseSummary(
                    summary: Translated.ResponseSummary(responseSummary)
                )
            } else {
                message = PrivateCloudComputeResponse.summary(responseSummary.textFormatString())
            }
        case .requestExecutionLogEntry(let requestExecutionLogEntry):
            var computeNodeAttestationBundle: LocalCloudBoardAttestationBundle?
            if requestExecutionLogEntry.hasAttestation {
                computeNodeAttestationBundle = try self
                    .parseComputeNodeAttestationBundle(requestExecutionLogEntry.attestation)
                if case .cloudAttestationBundle = computeNodeAttestationBundle!.attestationBundle {
                    try Self.validateComputeNodeAttestationInRequestExecutionLogEntry(
                        bundle: AttestationBundle(data: requestExecutionLogEntry.attestation),
                        attestationEnvironment: attestationEnvironment
                    )
                }
            }
            var outboundCallContext: OutboundCallContext?
            if requestExecutionLogEntry.hasOutboundCallContext {
                outboundCallContext = .init(
                    serviceName: requestExecutionLogEntry.outboundCallContext.serviceName,
                    metadata: requestExecutionLogEntry.outboundCallContext.metadata
                )
            }
            if let trustedProxyAttestationBundle, let endpoint {
                let requestExecutionLogEntryData = RequestExecutionLogEntry(
                    isNack: isNack,
                    isFinal: requestExecutionLogEntry.final,
                    endpoint: endpoint,
                    trustedProxyAttestationBundle: trustedProxyAttestationBundle,
                    computeNodeAttestationBundle: computeNodeAttestationBundle,
                    assetsMetata: requestExecutionLogEntry.assetMetadata.map {
                        .init(
                            assetID: $0.assetID,
                            applicationID: $0.applicationID,
                            assetIdentityHash: $0.hash,
                            version: $0.version
                        )
                    },
                    outboundCallContext: outboundCallContext
                )
                message = PrivateCloudComputeResponse.requestExecutionLogEntry(requestExecutionLogEntryData)
            } else {
                throw LocalCloudBoardGRPCClientError.incompleteInfoForCreatingRequestExecutionLogEntry
            }
        case .componentTimeMeasurement(let measurement):
            message = PrivateCloudComputeResponse.componentTimeMeasurement(.init(
                component: measurement.componentName,
                operation: measurement.operation,
                identifier: measurement.hasIdentifier ? measurement.identifier : nil,
                subIdentifier: measurement.hasSubIdentifier ? measurement.subIdentifier : nil,
                _startTimeMs: measurement.startTime,
                _endTimeMs: measurement.endTime
            ))
        case .costToken(let costToken):
            message = PrivateCloudComputeResponse.costToken(costToken.jwt)
        default:
            message = PrivateCloudComputeResponse.unknown
        }
        return message
    }

    private func closeProxyDialBackRequestOnError(
        workerId: String,
        proxyDialBackContinuation: AsyncStream<ProxyDialBackStream.InvokeProxyDialBackRequest>.Continuation,
        error: Error,
        ropesErrorCode: UInt32? = nil
    ) {
        var closeMessage: Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackRequest.Close = .init()
        closeMessage.ropesErrorDescription = String(describing: error)

        switch error {
        case let error as GRPCStatusTransformable:
            let grpcStatus = error.makeGRPCStatus()
            closeMessage.grpcStatus = Int32(grpcStatus.code.rawValue)
            if let grpcMessage = grpcStatus.message {
                closeMessage.grpcMessage = grpcMessage
            }
            closeMessage.ropesErrorCode = LocalCloudBoardGRPCClientProxyWorkflowError
                .fromGRPCCode(grpcStatus.code).rawValue
        default:
            // We use internalServerError for any error that's not from the compute node.
            // This doesn't fully align with how ROPES classify the errors, but for now we don't need to or intend to
            // align.
            closeMessage.ropesErrorCode = LocalCloudBoardGRPCClientProxyWorkflowError.internalServerError.rawValue
        }

        if let ropesErrorCode {
            closeMessage.ropesErrorCode = ropesErrorCode
        }

        proxyDialBackContinuation.yield(ProxyDialBackStream.InvokeProxyDialBackRequest.with {
            $0.close = closeMessage
        })
        proxyDialBackContinuation.finish()

        self.proxyWorkerErrors.withLock {
            $0[workerId] = error
        }
    }
}

@available(*, unavailable)
extension LocalCloudBoardGRPCAsyncClient: Sendable {}

public struct LocalCloudboardClientResponse: AsyncSequence {
    public typealias Element = PrivateCloudComputeResponse
    private var responseStream: AsyncThrowingStream<Element, Error>
    /// If any NACKS were requested they are provided here for consumers to wait for
    /// They are either a success (which implies an empty request execution log entry, or there is an Error describing
    /// the failure
    /// Timeouts on the tasks are the responsibility of the consumer of this instance
    public var nackRequests: [LocalCloudBoardGRPCAsyncClient.EndPoint: Task<Void, Error>]
    public var nackResponseStreams: [LocalCloudBoardGRPCAsyncClient.EndPoint: AsyncThrowingStream<Element, Error>]

    internal init(
        responseStream: AsyncThrowingStream<Element, Error>,
        nackRequests: [LocalCloudBoardGRPCAsyncClient.EndPoint: Task<Void, Error>],
        nackResponseStreams: [LocalCloudBoardGRPCAsyncClient.EndPoint: AsyncThrowingStream<Element, Error>]
    ) {
        self.responseStream = responseStream
        self.nackRequests = nackRequests
        self.nackResponseStreams = nackResponseStreams
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var responseStreamIterator: AsyncThrowingStream<Element, Error>.AsyncIterator

        public mutating func next() async throws -> Element? {
            return try await self.responseStreamIterator.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            responseStreamIterator: self.responseStream.makeAsyncIterator()
        )
    }
}

extension UUID {
    public init?(from data: Data) {
        guard data.count == MemoryLayout<uuid_t>.size else {
            return nil
        }

        let uuid: UUID? = data.withUnsafeBytes {
            guard let baseAddress = $0.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            return NSUUID(uuidBytes: baseAddress) as UUID
        }

        guard let uuid else {
            return nil
        }

        self = uuid
    }
}

extension HPKE.Ciphersuite {
    static var Curve25519_SHA256_AES_GCM_128: HPKE.Ciphersuite {
        .init(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_128)
    }
}

/// Possible failure cases for the NACK not being valid
/// Deliberately not public, this is for informational use only in logging
internal struct NackError: Error, CustomStringConvertible {
    var endPoint: LocalCloudBoardGRPCAsyncClient.EndPoint
    var text: String

    internal init(_ endPoint: LocalCloudBoardGRPCAsyncClient.EndPoint, _ text: String) {
        self.endPoint = endPoint
        self.text = text
    }

    var description: String {
        "failed nack for \(self.endPoint) due to \(self.text)"
    }
}

enum RequestSender {
    // the sender only provides plain application request payload
    case plainPayloadSender(parameters: InvokeWorkloadRequest.Parameters)
    // the sender is responsible for providing all needed InvokeWorkloadRequest messages
    case invokeWorkloadRequestSender(requestStream: AsyncStream<InvokeWorkloadRequest>)
}

enum PrivateRequestStreamContext {
    case plainPayload(
        stream: AsyncStream<Data>,
        continuation: AsyncStream<Data>.Continuation,
        parameters: InvokeWorkloadRequest.Parameters
    )
    case invokeWorkloadRequest(
        stream: AsyncStream<InvokeWorkloadRequest>,
        parameters: InvokeWorkloadRequest.Parameters
    )

    static func forSender(_ requestSender: RequestSender) async -> Self {
        switch requestSender {
        case .plainPayloadSender(let parameters):
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            return .plainPayload(stream: stream, continuation: continuation, parameters: parameters)
        case .invokeWorkloadRequestSender(let stream):
            var streamIterator = stream.makeAsyncIterator()
            let nextMessage = await streamIterator.next()
            guard let nextMessage, case .parameters = nextMessage.type else {
                fatalError("Expect parameters message first but get \(String(describing: nextMessage?.type))")
            }
            return .invokeWorkloadRequest(stream: stream, parameters: nextMessage.parameters)
        }
    }
}

enum PrivateResponseStreamContext {
    case privateCloudComputeResponse(
        stream: AsyncThrowingStream<PrivateCloudComputeResponse, Error>,
        continuation: AsyncThrowingStream<PrivateCloudComputeResponse, Error>.Continuation
    )
    case encryptedPayload(
        stream: AsyncThrowingStream<Data, Error>,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    )

    static func forSender(_ requestSender: RequestSender) -> Self {
        switch requestSender {
        case .plainPayloadSender:
            let (stream, continuation) = AsyncThrowingStream<PrivateCloudComputeResponse, Error>.makeStream()
            return .privateCloudComputeResponse(stream: stream, continuation: continuation)
        case .invokeWorkloadRequestSender:
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            return .encryptedPayload(stream: stream, continuation: continuation)
        }
    }

    func finishStream(throwing error: Error? = nil) {
        switch self {
        case .privateCloudComputeResponse(_, let continuation):
            continuation.finish(throwing: error)
        case .encryptedPayload(_, let continuation):
            continuation.finish(throwing: error)
        }
    }
}

enum StreamPrivateRequestSession {
    typealias EndPoint = LocalCloudBoardGRPCAsyncClient.EndPoint
    struct NACKContext {
        let nackRequests: [EndPoint: Task<Void, Error>]
        let nackResponseStreams: [EndPoint: AsyncThrowingStream<PrivateCloudComputeResponse, Error>]
    }

    case forPlainPayloadSender(
        requestContinuation: AsyncStream<Data>.Continuation,
        responseStream: AsyncThrowingStream<PrivateCloudComputeResponse, Error>,
        nackContext: NACKContext
    )
    case forInvokeWorkloadRequestSender(responseStream: AsyncThrowingStream<Data, Error>)

    init(
        requestStreamContext: PrivateRequestStreamContext,
        responseStreamContext: PrivateResponseStreamContext,
        nackRequests: [EndPoint: Task<Void, Error>],
        nackResponseStreams: [EndPoint: AsyncThrowingStream<PrivateCloudComputeResponse, Error>]
    ) {
        if case .plainPayload(_, let requestContinuation, _) = requestStreamContext,
           case .privateCloudComputeResponse(let responseStream, _) = responseStreamContext {
            self = .forPlainPayloadSender(
                requestContinuation: requestContinuation,
                responseStream: responseStream,
                nackContext: .init(nackRequests: nackRequests, nackResponseStreams: nackResponseStreams)
            )
        } else if case .invokeWorkloadRequest = requestStreamContext,
                  case .encryptedPayload(let responseStream, _) = responseStreamContext {
            self = .forInvokeWorkloadRequestSender(responseStream: responseStream)
        } else {
            fatalError("Invalid combination of request and response stream contexts")
        }
    }
}

extension InvokeWorkloadRequest.Parameters {
    var invokeWorkloadRequestMetaData: InvokeWorkloadRequestMetaData {
        .init(
            workloadType: self.workload.type,
            workloadParameters: self.workload.param.asMap(),
            patIssuer: self.patIssuer
        )
    }
}

extension Data {
    init(randomByteCount: Int) {
        let bytes: [UInt8] = (0 ..< randomByteCount).map { _ in
            UInt8.random(in: UInt8.min ... UInt8.max)
        }
        self = Data(bytes)
    }
}
