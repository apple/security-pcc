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

import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import CryptoKit
import Foundation
import HTTPClientStateMachine
import InternalSwiftProtobuf
import os

enum PCCWorkerSessionError: Error {
    case failedToDecodeResponse
    case invalidApplicationDataChunkSize
}

// Manages a session with a PCC node. This is initiated on behalf of a cloud app when requesting an outbound call to
// another PCC node and handles compute node attestation validation, encryption of request messages, decryption of
// response messages, and PrivateCloudCompute protocol message encoding and decoding.
//
// Request encryption is done here, rather than in CloudboardMessenger because it is worker specific,
// and there may be many of them. The messenger only concerns itself with the parent/client
final class PCCWorkerSession: Sendable {
    static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PCCWorkerSession"
    )

    typealias ProtoPrivateCloudComputeRequest = Proto_PrivateCloudCompute_PrivateCloudComputeRequest
    typealias ProtoPrivateCloudComputeResponse = Proto_PrivateCloudCompute_PrivateCloudComputeResponse

    private let workerID: UUID
    let negotiation: SelectionNegotiation.InitiatedNegotiation
    let query: FindWorkerQuery
    let responseBypassMode: ResponseBypassMode
    let findWorkerDurationMeasurement: OSAllocatedUnfairLock<ContinuousTimeMeasurement>
    let findWorkerStartTime: Date
    let cryptoMaterials: [InternalCryptoMaterial]

    let isFinal: Bool

    private let stateMachine: OSAllocatedUnfairLock<PCCWorkerSessionStateMachine>

    init(
        workerID: UUID,
        query: FindWorkerQuery,
        responseBypassMode: ResponseBypassMode,
        isFinal: Bool,
        findWorkerDurationMeasurement: OSAllocatedUnfairLock<ContinuousTimeMeasurement>,
        findWorkerStartTime: Date,
        cryptoMaterials: [InternalCryptoMaterial],
        negotiation: SelectionNegotiation.InitiatedNegotiation
    ) {
        self.workerID = workerID
        self.query = query
        self.negotiation = negotiation
        self.isFinal = isFinal
        self.responseBypassMode = responseBypassMode

        self.stateMachine = .init(uncheckedState: .init())
        self.findWorkerDurationMeasurement = findWorkerDurationMeasurement
        self.findWorkerStartTime = findWorkerStartTime
        self.cryptoMaterials = cryptoMaterials
    }

    /// Provides the Data Encryption Key to be (re-)wrapped to the worker node. This must be the same key that was sent
    /// by the client if request bypass is used.
    func receiveDataEncryptionKey(_ dataEncryptionKey: SymmetricKey) throws {
        try self.stateMachine.withLock {
            try $0.receiveDataEncryptionKey(dataEncryptionKey)
        }
    }

    func receiveValidatedAttestation(
        _ validatedWorker: ValidatedWorker
    ) throws -> (Data, ResponseBypassCapability?) {
        // Extract the encapsulated key and create bypass capability metadata required for decrypting the
        // response stream if requested
        let (encapsulatedKey, bypassCapability) = try self.stateMachine.withLock {
            try $0.receiveAttestation(
                workerPublicKey: validatedWorker.publicKey,
                responseBypassMode: self.responseBypassMode
            )
        }
        return (encapsulatedKey, bypassCapability)
    }

    func encapsulateProxyInvokeOpen(
        chunkingConfig: ApplicationDataChunkingConfiguration,
        workloadType: String,
        optedInToShareDiagnosticsAndUsageWithApple: Bool
    ) throws -> Data {
        let proxyInvokeOpenMessage = try ProtoPrivateCloudComputeRequest.serialized(
            with: .proxyInvokeOpen(.with {
                $0.optedInToShareDiagnosticsAndUsageWithApple = optedInToShareDiagnosticsAndUsageWithApple
                $0.opaqueCryptoMaterial = self.cryptoMaterials.map { cryptoMaterial in
                    .with {
                        $0.id = cryptoMaterial.id
                        $0.material = cryptoMaterial.material
                    }
                }

                switch chunkingConfig {
                case .disabled:
                    ()
                case .enabled(let chunkSize):
                    if let applicationDataChunkSize = UInt32(exactly: chunkSize) {
                        $0.capabilities = .with { capabilities in
                            capabilities.applicationDataChunking = .with { chunking in
                                chunking.size = applicationDataChunkSize
                            }
                        }
                    } else {
                        throw PCCWorkerSessionError.invalidApplicationDataChunkSize
                    }
                }
                $0.workloadType = workloadType
            })
        )
        return try self.stateMachine.withLock {
            try $0.encapsulateMessage(proxyInvokeOpenMessage, isFinal: false)
        }
    }

    func encapsulateMessage(_ payload: Data, isFinal: Bool) throws -> Data {
        let message = try ProtoPrivateCloudComputeRequest.serialized(with: .applicationPayload(payload))
        return try self.stateMachine.withLock { try $0.encapsulateMessage(message, isFinal: isFinal) }
    }

    func encapsulateFinalMessage() throws -> Data {
        let message = try ProtoPrivateCloudComputeRequest.serialized(with: .finalMessage(.init()))
        return try self.stateMachine.withLock { try $0.encapsulateMessage(message, isFinal: true) }
    }

    func decapsulateMessage(chunk: FinalizableChunk<Data>) throws -> ProtoPrivateCloudComputeResponse {
        var decapsulatedMessage = try self.stateMachine.withLock {
            try $0.decapsulateMessage(chunk.chunk, isFinal: chunk.isFinal)
        }

        guard let chunkData = decapsulatedMessage.readLengthPrefixedChunk() else {
            throw PCCWorkerSessionError.failedToDecodeResponse
        }
        return try ProtoPrivateCloudComputeResponse(serializedBytes: chunkData)
    }

    // Returns true if request stream was open, else false
    func finishRequestStreamAndCloseSession() -> Bool {
        return self.stateMachine.withLock { $0.finishRequestStreamAndMarkFinished() }
    }

    func workerFound() -> Bool {
        return self.stateMachine.withLock { $0.receivedAttestationOrFinished() }
    }

    func requestDataState() -> WorkerRequestDataStatus {
        return self.stateMachine.withLock { $0.requestDataState() }
    }

    func responseDataState() -> WorkerResponseDataStatus {
        if self.responseBypassMode == .matchRequestCiphersuiteSharedAeadState {
            return .bypassed
        }
        return self.stateMachine.withLock { $0.responseDataState() }
    }
}

struct PCCWorkerSessionStateMachine {
    private enum State {
        case awaitingDEK
        case awaitingAttestation
        case ready(requestStreamFinished: Bool, responseStreamFinished: Bool)
        case finished

        var publicDescription: String {
            let description = switch self {
            case .awaitingDEK: "awaitingDEK"
            case .awaitingAttestation: "awaitingAttestation"
            case .ready(
                let requestStreamFinished,
                let responseStreamFinished
            ): "ready (requestStreamFinished: \(String(requestStreamFinished)), responseStreamFinished: \(String(responseStreamFinished)))"
            case .finished: "finished"
            }
            return "\(description)"
        }
    }

    private var ohttpClientStateMachine: OHTTPClientStateMachine?
    private var oHTTPStreamingResponseDecapsulator: OHTTPStreamingResponseDecapsulatorProtocol?
    private var state: State = .awaitingDEK

    init() {}

    enum PCCWorkerSessionStateMachineError: ReportableError, Equatable {
        case illegalTransition(current: String, expected: [String])
        case requestStreamAlreadyClosed
        case responseStreamAlreadyClosed

        var publicDescription: String {
            switch self {
            case .illegalTransition(current: let current, expected: let expected):
                "illegalTransition(current: \(current), expected: \(expected))"
            case .requestStreamAlreadyClosed:
                "requestStreamAlreadyClosed"
            case .responseStreamAlreadyClosed:
                "responseStreamAlreadyClosed"
            }
        }
    }

    mutating func receiveDataEncryptionKey(_ dataEncryptionKey: SymmetricKey) throws {
        guard case .awaitingDEK = self.state else {
            throw PCCWorkerSessionStateMachineError.illegalTransition(
                current: self.state.publicDescription,
                expected: [State.awaitingDEK.publicDescription]
            )
        }

        self.ohttpClientStateMachine = OHTTPClientStateMachine(key: dataEncryptionKey)
        self.state = .awaitingAttestation
    }

    mutating func receiveAttestation(
        workerPublicKey: Curve25519.KeyAgreement.PublicKey,
        responseBypassMode: ResponseBypassMode
    ) throws -> (Data, ResponseBypassCapability?) {
        switch self.state {
        case .awaitingDEK, .ready, .finished:
            throw PCCWorkerSessionStateMachineError.illegalTransition(
                current: self.state.publicDescription,
                expected: [State.awaitingAttestation.publicDescription]
            )
        case .awaitingAttestation:
            let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_AES_GCM_128
            let encapsulatedKey: Data
            let bypassCapability: ResponseBypassCapability?
            let streamingResponseDecapsulator: OHTTPStreamingResponseDecapsulatorProtocol
            switch responseBypassMode {
            case .none:
                // Force-unwrap is safe as the state machine enforces that we have received the DEK and initialized
                // the OHTTP client state machine before reaching this code
                (encapsulatedKey, streamingResponseDecapsulator) = try self.ohttpClientStateMachine!.encapsulateKey(
                    publicKey: workerPublicKey,
                    ciphersuite: ciphersuite
                )
                bypassCapability = nil
            case .matchRequestCiphersuiteSharedAeadState:
                // force unwrap safe as above
                (encapsulatedKey, bypassCapability) = try self.ohttpClientStateMachine!.encapsulateKeyForResponseBypass(
                    workerPublicKey: workerPublicKey,
                    ciphersuite: ciphersuite
                )
                streamingResponseDecapsulator = OHTTPStreamingResponseIsFatal()
            }
            self.oHTTPStreamingResponseDecapsulator = streamingResponseDecapsulator
            self.state = .ready(requestStreamFinished: false, responseStreamFinished: false)
            return (encapsulatedKey, bypassCapability)
        }
    }

    mutating func encapsulateMessage(_ message: Data, isFinal: Bool) throws -> Data {
        switch self.state {
        case .awaitingDEK, .awaitingAttestation, .finished:
            throw PCCWorkerSessionStateMachineError.illegalTransition(
                current: self.state.publicDescription,
                expected: [
                    State.ready(requestStreamFinished: false, responseStreamFinished: false).publicDescription,
                    State.ready(requestStreamFinished: false, responseStreamFinished: true).publicDescription,
                ]
            )
        case .ready(let requestStreamFinished, let responseStreamFinished):
            if requestStreamFinished {
                throw PCCWorkerSessionStateMachineError.requestStreamAlreadyClosed
            }
            // Force-unwrap is safe as the state machine enforces that have received the DEK and initialized the OHTTP
            // client state machine before reaching this code
            let message = try self.ohttpClientStateMachine!.encapsulateMessage(
                message: message, isFinal: isFinal
            )
            if isFinal {
                self.state = if responseStreamFinished {
                    .finished
                } else {
                    .ready(requestStreamFinished: true, responseStreamFinished: false)
                }
            }
            return message
        }
    }

    mutating func decapsulateMessage(_ message: Data, isFinal: Bool) throws -> Data {
        switch self.state {
        case .ready(let requestStreamFinished, let responseStreamFinished):
            if responseStreamFinished {
                throw PCCWorkerSessionStateMachineError.responseStreamAlreadyClosed
            }
            guard self.oHTTPStreamingResponseDecapsulator != nil else {
                preconditionFailure("PCCWorkerSession marked ready without setting up response decapsulator")
            }
            let message = try self.oHTTPStreamingResponseDecapsulator!.decapsulateResponseMessage(
                message,
                isFinal: isFinal
            )

            if isFinal {
                self.state = if requestStreamFinished {
                    .finished
                } else {
                    .ready(requestStreamFinished: false, responseStreamFinished: true)
                }
            }
            return message
        case .awaitingDEK, .awaitingAttestation, .finished:
            throw PCCWorkerSessionStateMachineError.illegalTransition(
                current: self.state.publicDescription,
                expected: [
                    State.ready(requestStreamFinished: false, responseStreamFinished: false).publicDescription,
                    State.ready(requestStreamFinished: true, responseStreamFinished: false).publicDescription,
                ]
            )
        }
    }

    mutating func finishRequestStreamAndMarkFinished() -> Bool {
        if case .ready(let requestStreamFinished, _) = self.state {
            if !requestStreamFinished {
                self.state = .finished
                return true
            }
        }
        self.state = .finished
        return false
    }

    func receivedAttestationOrFinished() -> Bool {
        switch self.state {
        case .awaitingAttestation, .awaitingDEK:
            return false
        case .ready, .finished:
            return true
        }
    }

    func requestDataState() -> WorkerRequestDataStatus {
        switch self.state {
        case .awaitingAttestation, .awaitingDEK:
            return .notFinished
        case .ready(let requestStreamFinished, _):
            return requestStreamFinished ? .finished : .notFinished
        case .finished:
            return .finished
        }
    }

    func responseDataState() -> WorkerResponseDataStatus {
        switch self.state {
        case .awaitingAttestation, .awaitingDEK:
            return .notFinished
        case .ready(_, let responseStreamFinished):
            return responseStreamFinished ? .finished : .notFinished
        case .finished:
            return .finished
        }
    }
}

extension Proto_PrivateCloudCompute_PrivateCloudComputeRequest {
    typealias ProtoPrivateCloudComputeRequest = Proto_PrivateCloudCompute_PrivateCloudComputeRequest
    typealias ProtoPrivateCloudComputeRequestType = ProtoPrivateCloudComputeRequest.OneOf_Type

    static func serialized(with type: ProtoPrivateCloudComputeRequestType) throws -> Data {
        var request = try ProtoPrivateCloudComputeRequest.with {
            $0.type = type
        }.serializedData()
        request.prependLength()
        return request
    }
}

extension Proto_PrivateCloudCompute_PrivateCloudComputeResponse {
    typealias ProtoPrivateCloudComputeResponse = Proto_PrivateCloudCompute_PrivateCloudComputeResponse
    typealias ProtoPrivateCloudComputeResponseType = ProtoPrivateCloudComputeResponse.OneOf_Type

    static func serialized(with type: ProtoPrivateCloudComputeResponseType) throws -> Data {
        var request = try ProtoPrivateCloudComputeResponse.with {
            $0.type = type
        }.serializedData()
        request.prependLength()
        return request
    }
}
