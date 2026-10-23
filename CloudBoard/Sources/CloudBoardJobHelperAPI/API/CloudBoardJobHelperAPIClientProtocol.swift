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

import CryptoKit
import Foundation
package import CloudBoardAsyncXPC
package import CloudBoardDomain

/// An abstraction for making CloudBoardJobHelperAPIClientProtocol instances
package protocol CloudBoardJobHelperAPIClientFactoryProtocol: Sendable {
    /// make a connection to a specific instance on this node identified by `uuid`
    func localConnection(
        _ uuid: UUID
    ) async -> any CloudBoardJobHelperAPIClientProtocol
}

/// Those parts of the JobHelper API relevant for the client to talk to the server
package protocol CloudBoardJobHelperAPIClientToServerProtocol: Actor {
    func invokeWorkloadRequest(_ request: CloudBoardDaemonToJobHelperMessage) async throws
    func teardown() async throws
    func abandon() async throws
    func warmup(_ info: WarmupInfo) async throws
    func assignLAContext() async throws
    func queryProxyRequestStatus() async throws -> ProxyRequestStatus
}

/// call back notifications available to ``CloudBoardJobHelperAPIClientProtocol``
package protocol CloudBoardJobHelperAPIClientDelegateProtocol: AnyObject, Sendable,
CloudBoardJobHelperAPIServerToClientHandlerProtocol {
    func cloudBoardJobHelperAPIClientSurpriseDisconnect()
}

/// Code only relevant for the 'owner' of the client that implements all the protocols
/// applicable to the client.
/// These are the setup ones which will be called once, the only non test implementation should be
/// ``CloudBoardJobHelperAPIXPCClient``
package protocol CloudBoardJobHelperAPIClientProtocol: CloudBoardJobHelperAPIClientToServerProtocol {
    func set(delegate: CloudBoardJobHelperAPIClientDelegateProtocol) async
    func connect() async
}

package struct WorkerAttestationInfo: ByteBufferCodable, Sendable, Hashable, CustomStringConvertible {
    /// The id we used when requesting the worker, rather than something identifying the node itself
    package var workerID: UUID
    /// The id identifying the key within the ``attestationBundle`` on the worker
    package var keyID: Data
    /// The serialized bundle, so we can validate it, and pass it along in the REL
    package var attestationBundle: Data
    /// Present if response bypass was requested, this is then the OHTTP contextId
    /// the bypass will be presented to the client on
    package var bypassContextID: UInt32?
    package var spanID: UInt64?
    package var workerBuildVersion: String
    package var workerReleaseType: String

    package init(
        workerID: UUID,
        keyID: Data,
        attestationBundle: Data,
        bypassContextID: UInt32?,
        spanID: UInt64?,
        workerBuildVersion: String,
        workerReleaseType: String
    ) {
        self.workerID = workerID
        self.keyID = keyID
        self.attestationBundle = attestationBundle
        self.bypassContextID = bypassContextID
        self.spanID = spanID
        self.workerBuildVersion = workerBuildVersion
        self.workerReleaseType = workerReleaseType
    }

    package var description: String {
        """
        worker: \(self.workerID), 
        key ID: \(self.keyID), 
        \(self.attestationBundle.count) bytes, 
        bypassContextID: \((self.bypassContextID?.description ?? "nil")),
        workerBuildVersion: \(self.workerBuildVersion),
        workerReleaseType: \(self.workerReleaseType)
        """
    }

    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        try self.workerID.encode(to: &buffer)
        try self.keyID.encode(to: &buffer)
        try self.attestationBundle.encode(to: &buffer)
        try self.bypassContextID.encode(to: &buffer)
        try self.spanID.encode(to: &buffer)
        try self.workerBuildVersion.encode(to: &buffer)
        try self.workerReleaseType.encode(to: &buffer)
    }

    public init(from buffer: inout ByteBuffer) throws {
        self.workerID = try .init(from: &buffer)
        self.keyID = try .init(from: &buffer)
        self.attestationBundle = try .init(from: &buffer)
        self.bypassContextID = try .init(from: &buffer)
        self.spanID = try .init(from: &buffer)
        self.workerBuildVersion = try .init(from: &buffer)
        self.workerReleaseType = try .init(from: &buffer)
    }
}

package struct WorkerNegotiatePickInfo: ByteBufferCodable, Sendable, Hashable, CustomStringConvertible {
    public var workerID: UUID
    public var spanID: UInt64?
    public var proposed: EnsembleNegotiation

    package init(workerID: UUID, spanID: UInt64? = nil, proposed: EnsembleNegotiation) {
        self.workerID = workerID
        self.spanID = spanID
        self.proposed = proposed
    }

    package var description: String {
        "worker: \(self.workerID), proposed: \(self.proposed)"
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.workerID.encode(to: &buffer)
        try self.spanID.encode(to: &buffer)
        try self.proposed.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.workerID = .init(from: &buffer)
        try self.spanID = .init(from: &buffer)
        try self.proposed = .init(from: &buffer)
    }
}

package enum CloudBoardDaemonToJobHelperMessage: ByteBufferCodable, Sendable, Hashable, CustomStringConvertible {
    public typealias KeyID = Data

    case parameters(Parameters)
    case requestChunk(Data, isFinal: Bool)
    /// ROPES wishes to negotiate a new ensemble to trust
    case workerNegotiatePick(providedByRopes: WorkerNegotiatePickInfo)
    /// Once a compute node worker has been selected by ROPES we are provided the attestation and
    /// the workload that applied to the sub request (which may have values injected by ROPES,
    /// including dealing with reuse or not)
    case workerAttestation(attestation: WorkerAttestationInfo, workloadParameters: [String: [String]])
    case workerResponseChunk(UUID, Data, isFinal: Bool)
    case workerResponseClose(
        UUID,
        grpcStatus: Int,
        grpcMessage: String?,
        ropesErrorCode: UInt32?,
        ropesErrorMessage: String?
    )
    case workerResponseEOF(UUID)

    public var description: String {
        switch self {
        case .parameters(let parameters):
            "parameters(\(parameters))"
        case .requestChunk(let data, isFinal: let isFinal):
            "requestChunk(\(data.count) bytes, isFinal: \(isFinal))"
        case .workerNegotiatePick(providedByRopes: let providedByRopes):
            "workerNegotiatePick(\(providedByRopes))"
        case .workerAttestation(let info, let workloadParameters):
            "workerAttestation(\(info), \(workloadParameters))"
        case .workerResponseChunk(let workerID, let data, isFinal: let isFinal):
            "workerResponseChunk(worker: \(workerID), \(data.count) bytes, isFinal: \(isFinal))"
        case .workerResponseClose(
            let workerID,
            let grpcStatus,
            let grpcMessage,
            let ropesErrorCode,
            let ropesErrorMessage
        ):
            "workerResponseClose(worker: \(workerID), gRPC status: \(grpcStatus), gRPC message: \(grpcMessage ?? "nil"), ROPES error code: \(ropesErrorCode ?? 0), ROPES message: \(ropesErrorMessage ?? " nil")"
        case .workerResponseEOF(let workerID):
            "workerResponseEOF(worker: \(workerID))"
        }
    }

    public func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .parameters(let parameters):
            buffer.writeInteger(1)
            try parameters.encode(to: &buffer)
        case .requestChunk(let data, isFinal: let isFinal):
            buffer.writeInteger(2)
            try data.encode(to: &buffer)
            try isFinal.encode(to: &buffer)
        case .workerAttestation(let attestationInfo, let workloadParameter):
            buffer.writeInteger(3)
            try attestationInfo.encode(to: &buffer)
            try workloadParameter.encode(to: &buffer)
        case .workerResponseChunk(let uuid, let data, let isFinal):
            buffer.writeInteger(4)
            try uuid.encode(to: &buffer)
            try data.encode(to: &buffer)
            try isFinal.encode(to: &buffer)
        case .workerResponseClose(let uuid, let grpcStatus, let grpcMessage, let ropesErrorCode, let ropesMessage):
            buffer.writeInteger(5)
            try uuid.encode(to: &buffer)
            buffer.writeInteger(grpcStatus)
            try grpcMessage.encode(to: &buffer)
            try ropesErrorCode.encode(to: &buffer)
            try ropesMessage.encode(to: &buffer)
        case .workerResponseEOF(let uuid):
            buffer.writeInteger(6)
            try uuid.encode(to: &buffer)
        case .workerNegotiatePick(providedByRopes: let providedByRopes):
            buffer.writeInteger(7)
            try providedByRopes.encode(to: &buffer)
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let enumCase: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        switch enumCase {
        case 1:
            self = try .parameters(.init(from: &buffer))
        case 2:
            self = try .requestChunk(Data(from: &buffer), isFinal: .init(from: &buffer))
        case 3:
            self = try .workerAttestation(
                attestation: .init(from: &buffer),
                workloadParameters: .init(from: &buffer)
            )
        case 4:
            self = try .workerResponseChunk(
                .init(from: &buffer),
                .init(from: &buffer),
                isFinal: .init(from: &buffer)
            )
        case 5:
            let uuid = try UUID(from: &buffer)
            guard let grpcStatus: Int = buffer.readInteger() else {
                throw DecodingError.valueNotFound(
                    Self.self,
                    .init(
                        codingPath: [ByteBufferCodingKey(stringValue: "grpcStatus")],
                        debugDescription: "no expected integer"
                    )
                )
            }
            let grpcMessage: Optional<String> = try .init(from: &buffer)
            let ropesErrorCode: Optional<UInt32> = try .init(from: &buffer)
            let ropesMessage: Optional<String> = try .init(from: &buffer)
            self = .workerResponseClose(
                uuid,
                grpcStatus: grpcStatus,
                grpcMessage: grpcMessage,
                ropesErrorCode: ropesErrorCode,
                ropesErrorMessage: ropesMessage
            )
        case 6:
            self = try .workerResponseEOF(.init(from: &buffer))
        case 7:
            self = try .workerNegotiatePick(
                providedByRopes: .init(from: &buffer)
            )
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}

/// What we expect from reponse bypass, we simplify the proto down to this
package enum ResponseBypassMode: Sendable, ByteBufferCodable, CaseIterable {
    /// no bypass is requested
    case none
    /// The worker compute node will construct an OHTTP response stream using:
    /// Ciphersuite: The same ciphersuite used to unwrap the DEK
    /// ikm: same ikm used to unwrap the DEK
    /// responseNonce: a fixed single use value
    case matchRequestCiphersuiteSharedAeadState

    public var description: String {
        return switch self {
        case .none: "none"
        case .matchRequestCiphersuiteSharedAeadState: "matchRequestCiphersuiteSharedAeadState"
        }
    }

    /// We require multiple processes to agree on what "I want response bypass to happen"
    /// to actually mean.
    /// This is centralised here.
    public init(requested: Bool) {
        self = requested ? .matchRequestCiphersuiteSharedAeadState : .none
    }

    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .none: buffer.writeInteger(0)
        case .matchRequestCiphersuiteSharedAeadState:
            buffer.writeInteger(1)
        }
    }

    public init(from buffer: inout ByteBuffer) throws {
        guard let enumCase: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        switch enumCase {
        case 0:
            self = .none
        case 1:
            self = .matchRequestCiphersuiteSharedAeadState
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}

/// Parameters message sent from cloudboardd to cb_jobhelper
package struct Parameters: ByteBufferCodable, Sendable, Hashable, CustomStringConvertible {
    public var requestID: String
    public var oneTimeToken: Data
    public var encryptedKey: SealedKey
    public var parametersReceived: Date
    public var plaintextMetadata: PlaintextMetadata
    public var traceContext: TraceContext

    /// If set to something other than ``ResponseBypassMode.none`` this means response bypass is requested for this
    /// specific sub request
    public var responseBypassMode: ResponseBypassMode

    /// If true the actual request payload will not be passed to this instance,
    /// The use case is for the proxy, which does not need to see the request
    public var requestBypassed: Bool = false

    /// Should only ever be set for a proxy node, to request a NACK (An immediate empty REL and exit)
    public var requestedNack: Bool = false

    /// PAT issuer, which acts as an indirect resource pool identifier for cost token generation
    public var patIssuer: String?

    public init(
        requestID: String,
        oneTimeToken: Data,
        encryptedKey: SealedKey,
        parametersReceived: Date,
        plaintextMetadata: PlaintextMetadata,
        responseBypassMode: ResponseBypassMode,
        requestBypassed: Bool,
        requestedNack: Bool,
        traceContext: TraceContext,
        patIssuer: String? = nil
    ) {
        self.requestID = requestID
        self.oneTimeToken = oneTimeToken
        self.encryptedKey = encryptedKey
        self.parametersReceived = parametersReceived
        self.plaintextMetadata = plaintextMetadata
        self.responseBypassMode = responseBypassMode
        self.requestBypassed = requestBypassed
        self.requestedNack = requestedNack
        self.traceContext = traceContext
        self.patIssuer = patIssuer
    }

    public var description: String {
        """
        Parameters(requestID: \(self.requestID),
        oneTimeToken: \(self.oneTimeToken.base64EncodedString()),
        encryptedKey: \(self.encryptedKey.keyID.base64EncodedString()), \(self.encryptedKey.key.count) bytes,
        responseBypassMode: \(self.responseBypassMode.description))"),
        requestBypassed: \(self.requestBypassed)"),
        parametersReceived: \(self.parametersReceived),
        plaintextMetadata: \(self.plaintextMetadata),
        requestedNack: \(self.requestedNack),
        traceContext: \(self.traceContext),
        patIssuer: \(self.patIssuer ?? "nil")
        """
    }

    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        try self.requestID.encode(to: &buffer)
        try self.oneTimeToken.encode(to: &buffer)
        try self.encryptedKey.encode(to: &buffer)
        try self.parametersReceived.encode(to: &buffer)
        try self.plaintextMetadata.encode(to: &buffer)
        try self.responseBypassMode.encode(to: &buffer)
        try self.requestBypassed.encode(to: &buffer)
        try self.requestedNack.encode(to: &buffer)
        try self.traceContext.encode(to: &buffer)
        try self.patIssuer.encode(to: &buffer)
    }

    public init(from buffer: inout ByteBuffer) throws {
        self.requestID = try .init(from: &buffer)
        self.oneTimeToken = try .init(from: &buffer)
        self.encryptedKey = try .init(from: &buffer)
        self.parametersReceived = try .init(from: &buffer)
        self.plaintextMetadata = try .init(from: &buffer)
        self.responseBypassMode = try .init(from: &buffer)
        self.requestBypassed = try .init(from: &buffer)
        self.requestedNack = try .init(from: &buffer)
        self.traceContext = try .init(from: &buffer)
        self.patIssuer = try .init(from: &buffer)
    }
}

extension Parameters {
    package struct SealedKey: ByteBufferCodable, Sendable, Hashable {
        public var keyID: Data
        public var key: Data

        public init(keyID: Data, key: Data) {
            self.keyID = keyID
            self.key = key
        }

        @inlinable
        package func encode(to buffer: inout ByteBuffer) throws {
            try self.keyID.encode(to: &buffer)
            try self.key.encode(to: &buffer)
        }

        package init(from buffer: inout ByteBuffer) throws {
            self.keyID = try .init(from: &buffer)
            self.key = try .init(from: &buffer)
        }
    }
}

extension Parameters {
    package struct PlaintextMetadata: ByteBufferCodable, Sendable, Hashable {
        public var bundleID: String
        public var bundleVersion: String
        public var featureID: String
        public var clientInfo: String
        public var workloadType: String
        public var workloadParameters: [String: [String]]
        public var automatedDeviceGroup: String

        public init(
            bundleID: String,
            bundleVersion: String,
            featureID: String,
            clientInfo: String,
            workloadType: String,
            workloadParameters: [String: [String]],
            automatedDeviceGroup: String
        ) {
            self.bundleID = bundleID
            self.bundleVersion = bundleVersion
            self.featureID = featureID
            self.clientInfo = clientInfo
            self.workloadType = workloadType
            self.workloadParameters = workloadParameters
            self.automatedDeviceGroup = automatedDeviceGroup
        }

        @inlinable
        public func encode(to buffer: inout ByteBuffer) throws {
            try self.automatedDeviceGroup.encode(to: &buffer)
            try self.bundleID.encode(to: &buffer)
            try self.bundleVersion.encode(to: &buffer)
            try self.clientInfo.encode(to: &buffer)
            try self.featureID.encode(to: &buffer)
            try self.workloadType.encode(to: &buffer)
            try self.workloadParameters.encode(to: &buffer)
        }

        public init(from buffer: inout ByteBuffer) throws {
            self.automatedDeviceGroup = try String(from: &buffer)
            self.bundleID = try String(from: &buffer)
            self.bundleVersion = try String(from: &buffer)
            self.clientInfo = try String(from: &buffer)
            self.featureID = try String(from: &buffer)
            self.workloadType = try String(from: &buffer)
            self.workloadParameters = try [String: [String]](from: &buffer)
        }
    }

    package struct TraceContext: ByteBufferCodable, Sendable, Hashable {
        public var traceID: String
        public var spanID: UInt64

        public init(
            traceID: String,
            spanID: UInt64
        ) {
            self.traceID = traceID
            self.spanID = spanID
        }

        @inlinable
        public func encode(to buffer: inout ByteBuffer) throws {
            try self.traceID.encode(to: &buffer)
            try self.spanID.encode(to: &buffer)
        }

        public init(from buffer: inout ByteBuffer) throws {
            self.traceID = try String(from: &buffer)
            self.spanID = try .init(from: &buffer)
        }
    }
}
