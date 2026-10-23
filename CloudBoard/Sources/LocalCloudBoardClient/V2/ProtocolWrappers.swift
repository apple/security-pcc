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

import Foundation
internal import InternalSwiftProtobuf

// This file contains typealiases for PrivateCloudCompute.proto and CloudBoard.proto messages as well as various wrapper
// types for request and response messages at the different protocol layers in order to avoid making the protobuf
// messages part of the public API.

// Namespaced to PCCHarness
extension PCCHarness {
    // MARK: - Proto typealiases

    // PrivateCloudCompute.proto
    typealias ProtoPrivateCloudComputeRequest = Proto_PrivateCloudCompute_PrivateCloudComputeRequest
    typealias ProtoPrivateCloudComputeResponse = Proto_PrivateCloudCompute_PrivateCloudComputeResponse
    // CloudBoard.proto
    typealias GRPCCloudBoardAsyncClient = Com_Apple_Cloudboard_Api_V1_CloudBoardAsyncClient
    typealias ProtoWatchAttestationRequest = Com_Apple_Cloudboard_Api_V1_WatchAttestationRequest
    typealias ProtoWatchAttestationResponse = Com_Apple_Cloudboard_Api_V1_WatchAttestationResponse
    typealias ProtoInvokeWorkloadRequest = Com_Apple_Cloudboard_Api_V1_InvokeWorkloadRequest
    typealias ProtoInvokeWorkloadResponse = Com_Apple_Cloudboard_Api_V1_InvokeWorkloadResponse
    typealias ProtoInvokeProxyInitiate = Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate
    typealias ProtoResponseBypassMode = Com_Apple_Cloudboard_Api_V1_ResponseBypassMode
    typealias ProtoInvokeProxyDialBackRequest = Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackRequest
    typealias ProtoInvokeProxyDialBackResponse = Com_Apple_Cloudboard_Api_V1_InvokeProxyDialBackResponse

    // MARK: - Subrequest/Subresponse Supporting Types

    /// Subrequest open message
    package struct SubrequestOpen: Sendable {
        package let subrequestID: UInt64
        package let metadata: SubrequestMetadata

        package init(subrequestID: UInt64, metadata: SubrequestMetadata) {
            self.subrequestID = subrequestID
            self.metadata = metadata
        }
    }

    /// Subrequest payload chunk
    package struct SubrequestPayload: Sendable {
        package let subrequestID: UInt64
        package let data: Data

        package init(subrequestID: UInt64, data: Data) {
            self.subrequestID = subrequestID
            self.data = data
        }
    }

    /// Subrequest close message
    package struct SubrequestClose: Sendable {
        package let subrequestID: UInt64

        package init(subrequestID: UInt64) {
            self.subrequestID = subrequestID
        }
    }

    /// Subrequest cancellation event
    package struct SubrequestCancellation: Sendable {
        package let subrequestID: UInt64

        package init(subrequestID: UInt64) {
            self.subrequestID = subrequestID
        }
    }

    /// Subresponse open message
    public struct SubresponseOpen: Sendable {
        public let subrequestID: UInt64

        package init(subrequestID: UInt64) {
            self.subrequestID = subrequestID
        }
    }

    /// Subresponse payload chunk
    public struct SubresponsePayload: Sendable {
        public let subrequestID: UInt64
        public let data: Data

        package init(subrequestID: UInt64, data: Data) {
            self.subrequestID = subrequestID
            self.data = data
        }
    }

    /// Subresponse close message
    public struct SubresponseClose: Sendable {
        /// Status of the subresponse
        public enum Status: Sendable, CustomStringConvertible {
            case ok
            case internalError
            case invalidRequest
            case discarded
            case unknown

            public var description: String {
                switch self {
                case .ok: "ok"
                case .internalError: "internalError"
                case .invalidRequest: "invalidRequest"
                case .discarded: "discarded"
                case .unknown: "unknown"
                }
            }
        }

        public let subrequestID: UInt64
        public let responseStatus: Status

        package init(subrequestID: UInt64, responseStatus: Status) {
            self.subrequestID = subrequestID
            self.responseStatus = responseStatus
        }
    }

    // MARK: - PCC Protocol Response/Request Types

    /// Response from PCC protocol layer - maps 1:1 to ProtoPrivateCloudComputeProtocolResponse messages.
    /// Attestation bundles are exposed separately via the session type.
    public enum PrivateCloudComputeProtocolResponse: Sendable {
        case responseID(UUID)
        case payload(Data)
        case responseSummary(ResponseSummary)
        case requestExecutionLogEntry(RequestExecutionLogEntry)
        case payloadChunk(SubresponsePayload)
        case subresponseOpen(SubresponseOpen)
        case subresponseClose(SubresponseClose)
        case componentTimeMeasurement(ComponentTimeMeasurement)
        case costToken(CostToken)
        case unknown
    }

    /// Request message for PCC protocol layer
    /// Maps 1:1 to ProtoPrivateCloudComputeRequest message types
    package enum PrivateCloudComputeProtocolRequest: Sendable {
        /// Open message with authentication token
        case open(version: UInt32 = 0)
        /// Application payload data
        case applicationPayload(Data)
        /// Final message indicating request completion
        case finalMessage
        /// Subrequest open (for persistent connections)
        case subrequestOpen(SubrequestOpen, oneTimeToken: Data)
        /// Subrequest payload chunk
        case subrequestPayload(SubrequestPayload)
        /// Subrequest close
        case subrequestClose(SubrequestClose)
        /// Subrequest cancellation
        case subrequestCancel(SubrequestCancellation)

        /// Convert to protobuf OneOf_Type for serialization
        internal func toProtoType() -> ProtoPrivateCloudComputeRequest.OneOf_Type {
            switch self {
            case .open(let version):
                return .open(.with {
                    $0.version = version
                })
            case .applicationPayload(let data):
                return .applicationPayload(data)
            case .finalMessage:
                return .finalMessage(.init())
            case .subrequestOpen(let open, let oneTimeToken):
                return .subOpen(.with {
                    $0.subrequestID = open.subrequestID
                    $0.oneTimeToken = oneTimeToken
                    switch open.metadata.priority {
                    case .unspecified:
                        $0.priority = .requestExecutionPriorityUnspecified
                    case .discardable:
                        $0.priority = .requestExecutionPriorityDiscardable
                    }
                })
            case .subrequestPayload(let payload):
                return .payloadChunk(.with {
                    $0.subrequestID = payload.subrequestID
                    $0.chunkData = payload.data
                })
            case .subrequestClose(let close):
                return .subClose(.with {
                    $0.subrequestID = close.subrequestID
                })
            case .subrequestCancel(let cancellation):
                return .subCancel(.with {
                    $0.subrequestID = cancellation.subrequestID
                })
            }
        }
    }

    /// Response summary from PCC layer
    public struct ResponseSummary: Sendable, CustomStringConvertible {
        public var responseStatus: ResponseStatus
        public var errorDescription: String?

        internal init(responseStatus: ResponseStatus, errorDescription: String? = nil) {
            self.responseStatus = responseStatus
            self.errorDescription = errorDescription
        }

        init(from proto: ProtoPrivateCloudComputeResponse.CloseResponsePayload) {
            self.responseStatus = .init(from: proto.responseStatus)
            self.errorDescription = proto.hasErrorDescription ? proto.errorDescription : nil
        }

        public var description: String {
            if let errorDescription {
                return "\(self.responseStatus) (\(errorDescription))"
            }
            return "\(self.responseStatus)"
        }
    }

    /// Cost token from PCC layer - contains signed JWT with bucketized cost
    public struct CostToken: Sendable, CustomStringConvertible {
        /// Signed JWT containing bucketized cost
        public var jwt: Data

        internal init(jwt: Data) {
            self.jwt = jwt
        }

        init(from proto: ProtoPrivateCloudComputeResponse.CostToken) {
            self.jwt = proto.jwt
        }

        public var description: String {
            "CostToken(jwt: \(self.jwt.count) bytes)"
        }
    }

    /// PCC protocol response summary status
    public enum ResponseStatus: Sendable, Equatable, CustomStringConvertible {
        case ok
        case unauthenticated
        case internalError
        case invalidRequest
        case proxyFindWorkerError
        case proxyWorkerValidationError
        case unrecognized(value: Int)

        init(from proto: ProtoPrivateCloudComputeResponse.ResponseStatus) {
            self = switch proto {
            case .ok: .ok
            case .unauthenticated: .unauthenticated
            case .internalError: .internalError
            case .invalidRequest: .invalidRequest
            case .proxyFindWorkerError: .proxyFindWorkerError
            case .proxyWorkerValidationError: .proxyWorkerValidationError
            case .UNRECOGNIZED(let value): .unrecognized(value: value)
            }
        }

        public var description: String {
            switch self {
            case .ok: "ok"
            case .unauthenticated: "unauthenticated"
            case .internalError: "internalError"
            case .invalidRequest: "invalidRequest"
            case .proxyFindWorkerError: "proxyFindWorkerError"
            case .proxyWorkerValidationError: "proxyWorkerValidationError"
            case .unrecognized(value: let value): "unrecognized(\(value))"
            }
        }
    }

    /// Request execution log entry
    public struct RequestExecutionLogEntry: Sendable {
        public var isNack: Bool
        public var isFinal: Bool
        public var endpoint: any CloudAppEndpoint
        // Note: Not exposing nodeID since we use endpoints directly
        public var trustedProxyAttestationBundle: LocalCloudBoardAttestationBundle
        public var computeNodeAttestationBundle: LocalCloudBoardAttestationBundle?
        public var outboundCallContext: OutboundCallContext?

        init(
            isNack: Bool,
            isFinal: Bool,
            endpoint: any CloudAppEndpoint,
            trustedProxyAttestationBundle: LocalCloudBoardAttestationBundle,
            computeNodeAttestationBundle: LocalCloudBoardAttestationBundle?
        ) {
            self.isNack = isNack
            self.isFinal = isFinal
            self.endpoint = endpoint
            self.trustedProxyAttestationBundle = trustedProxyAttestationBundle
            self.computeNodeAttestationBundle = computeNodeAttestationBundle
            self.outboundCallContext = nil
        }

        init(
            isNack: Bool,
            isFinal: Bool,
            endpoint: any CloudAppEndpoint,
            trustedProxyAttestationBundle: LocalCloudBoardAttestationBundle,
            computeNodeAttestationBundle: LocalCloudBoardAttestationBundle?,
            outboundCallContext: OutboundCallContext?
        ) {
            self.isNack = isNack
            self.isFinal = isFinal
            self.endpoint = endpoint
            self.trustedProxyAttestationBundle = trustedProxyAttestationBundle
            self.computeNodeAttestationBundle = computeNodeAttestationBundle
            self.outboundCallContext = outboundCallContext
        }
    }

    public struct ComponentTimeMeasurement: Sendable, CustomStringConvertible {
        public var component: String
        public var operation: String
        public var identifier: String?
        public var subIdentifier: String?
        public var startTimeMsSinceEpoch: Int64
        public var endTimeMsSinceEpoch: Int64

        /// Initialize with all parameters
        public init(
            component: String,
            operation: String,
            identifier: String? = nil,
            subIdentifier: String? = nil,
            startTimeMsSinceEpoch: Int64,
            endTimeMsSinceEpoch: Int64
        ) {
            self.component = component
            self.operation = operation
            self.identifier = identifier
            self.subIdentifier = subIdentifier
            self.startTimeMsSinceEpoch = startTimeMsSinceEpoch
            self.endTimeMsSinceEpoch = endTimeMsSinceEpoch
        }

        /// Initialize with Date objects (converted to milliseconds since epoch)
        public init(
            component: String,
            operation: String,
            identifier: String? = nil,
            subIdentifier: String? = nil,
            startTime: Date,
            endTime: Date
        ) {
            self.component = component
            self.operation = operation
            self.identifier = identifier
            self.subIdentifier = subIdentifier
            self.startTimeMsSinceEpoch = Int64(startTime.timeIntervalSince1970 * 1000)
            self.endTimeMsSinceEpoch = Int64(endTime.timeIntervalSince1970 * 1000)
        }

        init(from proto: Proto_PrivateCloudCompute_ComponentTimeMeasurement) {
            self.component = proto.componentName
            self.operation = proto.operation
            self.identifier = proto.identifier
            self.subIdentifier = proto.subIdentifier
            self.startTimeMsSinceEpoch = proto.startTime
            self.endTimeMsSinceEpoch = proto.endTime
        }

        public var description: String {
            var parts = ["\(component).\(operation)"]

            if let identifier {
                parts.append("id:\(identifier)")
            }

            if let subIdentifier {
                parts.append("subId:\(subIdentifier)")
            }

            parts.append("startTimeEpoch:\(self.startTimeMsSinceEpoch)")
            parts.append("endTimeEpoch:\(self.endTimeMsSinceEpoch)")

            return parts.joined(separator: " ")
        }
    }

    // MARK: - Attestation Types

    /// Wrapper for attestation metadata
    package struct AttestationMetadata: Sendable {
        package let keyID: Data

        package init(keyID: Data) {
            self.keyID = keyID
        }

        internal init(from proto: ProtoWatchAttestationResponse.AttestationMetadata) {
            self.keyID = proto.keyID
        }
    }

    /// Wrapper for active attestation
    package struct ActiveAttestation: Sendable {
        package let attestationMetadata: AttestationMetadata
        package let attestationBundle: Data

        package init(attestationMetadata: AttestationMetadata, attestationBundle: Data) {
            self.attestationMetadata = attestationMetadata
            self.attestationBundle = attestationBundle
        }

        internal init(from proto: ProtoWatchAttestationResponse.ActiveAttestation) {
            self.attestationMetadata = AttestationMetadata(from: proto.attestationMetadata)
            self.attestationBundle = proto.attestationBundle
        }

        /// Internal accessor for the proto representation (for GatewayPCCClient use)
        internal var proto: ProtoWatchAttestationResponse.ActiveAttestation {
            var activeAttestation = ProtoWatchAttestationResponse.ActiveAttestation()
            activeAttestation.attestationMetadata.keyID = self.attestationMetadata.keyID
            activeAttestation.attestationBundle = self.attestationBundle
            return activeAttestation
        }
    }

    /// Wrapper for attestation set
    package struct AttestationSet: Sendable {
        package let activeAttestation: ActiveAttestation

        package init(activeAttestation: ActiveAttestation) {
            self.activeAttestation = activeAttestation
        }

        internal init(from proto: ProtoWatchAttestationResponse.AttestationSet) {
            self.activeAttestation = ActiveAttestation(from: proto.activeAttestation)
        }
    }

    // MARK: - CloudBoard.proto request/response types (package-internal)

    /// Wrapper for CloudBoard response chunk (package-internal for testing)
    package struct ResponseChunk: Sendable {
        package let encryptedPayload: Data
        package let isFinal: Bool

        package init(encryptedPayload: Data, isFinal: Bool) {
            self.encryptedPayload = encryptedPayload
            self.isFinal = isFinal
        }

        internal init(from proto: Proto_Ropes_Common_Chunk) {
            self.encryptedPayload = proto.encryptedPayload
            self.isFinal = proto.isFinal
        }
    }

    /// Wrapper for proxy initiate message (package-internal for testing)
    package struct ProxyInitiate: Sendable {
        package let taskID: String
        package let workloadType: String
        package let workloadParameters: [String: [String]]

        package init(taskID: String, workloadType: String, workloadParameters: [String: [String]]) {
            self.taskID = taskID
            self.workloadType = workloadType
            self.workloadParameters = workloadParameters
        }

        internal init(from proto: Com_Apple_Cloudboard_Api_V1_InvokeProxyInitiate) {
            self.taskID = proto.taskID
            self.workloadType = proto.workload.type
            self.workloadParameters = proto.workload.param.asMap()
        }
    }

    /// Response from CloudBoard protocol layer (package-internal for testing)
    package enum InvokeWorkloadResponse: Sendable {
        case setupAck
        case responseChunk(ResponseChunk)
        case proxyInitiate(ProxyInitiate)
        case proxyWorkerError(ProxyWorkerError)
    }

    /// Proxy worker error
    package struct ProxyWorkerError: Sendable {
        package let taskID: String
        package let errorCode: UInt32

        package init(taskID: String, errorCode: UInt32) {
            self.taskID = taskID
            self.errorCode = errorCode
        }
    }

    /// Wrapper for CloudBoard InvokeWorkloadRequest (package-internal for testing)
    package struct InvokeWorkloadRequest: Sendable {
        let proto: ProtoInvokeWorkloadRequest

        package init(requestChunk: ResponseChunk) {
            var proto = ProtoInvokeWorkloadRequest()
            proto.requestChunk = Proto_Ropes_Common_Chunk.with {
                $0.encryptedPayload = requestChunk.encryptedPayload
                $0.isFinal = requestChunk.isFinal
            }
            self.proto = proto
        }

        internal init(from proto: ProtoInvokeWorkloadRequest) {
            self.proto = proto
        }
    }

    // MARK: - Response Bypass Mode

    /// Response bypass mode
    public enum ResponseBypassMode: Sendable {
        case none
        case matchRequestCiphersuiteSharedAeadState

        internal init(from proto: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode) {
            switch proto {
            case .none: self = .none
            case .matchRequestCiphersuiteSharedAeadState: self = .matchRequestCiphersuiteSharedAeadState
            case .UNRECOGNIZED: self = .none
            }
        }

        internal var toProto: Com_Apple_Cloudboard_Api_V1_ResponseBypassMode {
            switch self {
            case .none: return .none
            case .matchRequestCiphersuiteSharedAeadState: return .matchRequestCiphersuiteSharedAeadState
            }
        }
    }

    // MARK: - Observed Message Wrappers

    /// Lightweight wrapper for EnsembleInstanceId proto for testing as observer
    public struct EnsembleInstanceId: Sendable, Hashable {
        public let ensembleID: String
        public let bootID: String

        package init(ensembleID: String, bootID: String) {
            self.ensembleID = ensembleID
            self.bootID = bootID
        }

        internal init(from proto: Proto_Ropes_Common_EnsembleInstanceId) {
            self.ensembleID = proto.ensembleID
            self.bootID = proto.bootID
        }
    }

    /// Wrapper for observed InvokeWorkloadRequest proto messages
    package enum ObservedInvokeWorkloadRequest: Sendable {
        case setup
        case terminate(code: String, reason: String?)
        case requestChunk(data: Data, isFinal: Bool)
        case parameters(workloadType: String, workloadParameters: [String: [String]], requestID: String)
        case unknown

        internal init(_ proto: ProtoInvokeWorkloadRequest) {
            switch proto.type {
            case .setup:
                self = .setup
            case .terminate(let terminate):
                self = .terminate(code: String(describing: terminate.code), reason: terminate.reason)
            case .requestChunk(let chunk):
                self = .requestChunk(data: chunk.encryptedPayload, isFinal: chunk.isFinal)
            case .parameters(let parameters):
                self = .parameters(
                    workloadType: parameters.workload.type,
                    workloadParameters: parameters.workload.param.asMap(),
                    requestID: parameters.requestID
                )
            case .none:
                self = .unknown // Shouldn't happen
            }
        }
    }

    /// Wrapper for observed InvokeWorkloadResponse proto messages
    package enum ObservedInvokeWorkloadResponse: Sendable {
        case setupAck
        case responseChunk(data: Data, isFinal: Bool)
        case proxyInitiate(taskID: String, workloadType: String, workloadParameters: [String: [String]])
        case proxyWorkerError(taskID: String)
        case requestExecutionError
        case unknown

        internal init(_ proto: ProtoInvokeWorkloadResponse) {
            switch proto.type {
            case .setupAck:
                self = .setupAck
            case .responseChunk(let chunk):
                self = .responseChunk(data: chunk.encryptedPayload, isFinal: chunk.isFinal)
            case .invokeProxyInitiate(let initiate):
                self = .proxyInitiate(
                    taskID: initiate.taskID,
                    workloadType: initiate.workload.type,
                    workloadParameters: initiate.workload.param.asMap()
                )
            case .proxyWorkerError(let error):
                self = .proxyWorkerError(taskID: error.taskID)
            case .requestExecutionError:
                self = .requestExecutionError
            case .none:
                self = .unknown
            }
        }
    }

    /// Wrapper for observed InvokeProxyDialBackRequest proto messages
    package enum ObservedInvokeProxyDialBackRequest: Sendable {
        case initiate(taskID: String)
        case selectedEnsemble(nodeIdentifier: String, workloadType: String, workloadParameters: [String: [String]])
        case responseChunk(data: Data, isFinal: Bool)
        case negotiatePick(ensembles: [EnsembleInstanceId])
        case close(grpcStatus: Int32, grpcMessage: String?, ropesErrorCode: UInt32?)
        case unknown
        case unsupported(message: String, reason: String)

        internal init(_ proto: ProtoInvokeProxyDialBackRequest) {
            switch proto.type {
            case .taskID(let taskID):
                self = .initiate(taskID: taskID)
            case .initiate(let initiate):
                self = .initiate(taskID: initiate.taskID)
            case .computeToProxyMessage(let message):
                switch message.type {
                case .attestation:
                    // no real ROPES should do this fior V2 routing, so we don't bother either
                    self = .unsupported(
                        message: "attestation",
                        reason: "For V2 routing attestation is replaced by selectedEnsemble"
                    )
                case .responseChunk(let chunk):
                    self = .responseChunk(data: chunk.encryptedPayload, isFinal: chunk.isFinal)
                case .negotiatePick(let negotiation):
                    self = .negotiatePick(ensembles: negotiation.ensembles.map { EnsembleInstanceId(from: $0) })
                case .selectedEnsemble(let ensemble):
                    self = .selectedEnsemble(
                        nodeIdentifier: ensemble.attestation.nodeIdentifier,
                        workloadType: ensemble.computeEnsembleWorkload.type,
                        workloadParameters: ensemble.computeEnsembleWorkload.param.asMap()
                    )
                case .none:
                    self = .unknown
                }
            case .close(let close):
                self = .close(
                    grpcStatus: close.grpcStatus,
                    grpcMessage: close.grpcMessage,
                    ropesErrorCode: close.ropesErrorCode
                )
            case .none:
                self = .unknown
            }
        }
    }

    /// Wrapper for observed InvokeProxyDialBackResponse proto messages
    package enum ObservedInvokeProxyDialBackResponse: Sendable, CustomStringConvertible {
        case decryptionKey(keyID: Data, encryptedPayload: Data)
        case requestChunk(data: Data, isFinal: Bool)
        case selectableEnsembles(ensembles: [EnsembleInstanceId])
        case close
        case unknown

        internal init(_ proto: ProtoInvokeProxyDialBackResponse) {
            switch proto.type {
            case .proxyToComputeMessage(let message):
                switch message.type {
                case .decryptionKey(let key):
                    self = .decryptionKey(keyID: key.keyID, encryptedPayload: key.encryptedPayload)
                case .requestChunk(let chunk):
                    self = .requestChunk(data: chunk.encryptedPayload, isFinal: chunk.isFinal)
                case .selectableEnsembles(let negotiation):
                    self = .selectableEnsembles(ensembles: negotiation.ensembles.map { EnsembleInstanceId(from: $0) })
                case .none:
                    self = .unknown
                }
            case .close:
                self = .close
            case .none:
                self = .unknown
            }
        }

        package var description: String {
            switch self {
            case .decryptionKey(let keyID, _):
                return "decryptionKey(keyID: \(keyID.base64EncodedString()))"
            case .requestChunk(let data, let isFinal):
                return "requestChunk(data: \(data.count) bytes, isFinal: \(isFinal))"
            case .selectableEnsembles(let ensembles):
                return "selectableEnsembles(ensembles: \(ensembles.count) items)"
            case .close:
                return "close"
            case .unknown:
                return "unknown"
            }
        }
    }
}
