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

package import CloudBoardAsyncXPC
import Foundation
internal import CloudBoardLogging

/// Parameters provided when initializing a persistent helper instance
package struct PersistentHelperInitParams: ByteBufferCodable, Sendable, Hashable, CustomStringConvertible {
    /// The identifier of the key this helper is bound to
    public var keyID: Data
    /// The OHTTP-wrapped HPKE key material
    public var encryptedKey: Data
    /// The XPC endpoint string for the target side (plaintext for server helper, encrypted for client helper)
    public var targetEndpoint: String

    public init(
        keyID: Data,
        encryptedKey: Data,
        targetEndpoint: String
    ) {
        self.keyID = keyID
        self.encryptedKey = encryptedKey
        self.targetEndpoint = targetEndpoint
    }

    public var description: String {
        """
        PersistentHelperInitParams(keyID: \(self.keyID.base64EncodedString()), \
        encryptedKey: \(self.encryptedKey.count) bytes, \
        targetEndpoint: \(self.targetEndpoint))
        """
    }

    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        try self.keyID.encode(to: &buffer)
        try self.encryptedKey.encode(to: &buffer)
        try self.targetEndpoint.encode(to: &buffer)
    }

    public init(from buffer: inout ByteBuffer) throws {
        self.keyID = try .init(from: &buffer)
        self.encryptedKey = try .init(from: &buffer)
        self.targetEndpoint = try .init(from: &buffer)
    }
}

/// Parameters for initializing a client-side persistent helper (cb_pclienthelper).
///
/// Unlike `PersistentHelperInitParams` (used by server helpers), this only carries the
/// key identity and the attestation bundle. The helper uses the bundle's public key to
/// perform OHTTP key encapsulation, then sends the resulting encrypted key back as a
/// pre-init `.responseChunk`.
///
/// There is no `encryptedKey` (that's the response, not an input) and no `targetEndpoint`
/// (the client helper communicates with cb_bridged via the XPC channel that spawned it).
package struct PersistentClientHelperInitParams: ByteBufferCodable, Sendable, Hashable, CustomStringConvertible {
    /// The identifier of the key this helper is bound to
    public var keyID: Data
    /// The attestation bundle from the compute node, containing the public key
    /// for OHTTP key encapsulation
    public var attestationBundle: Data
    /// Service-defined metadata from service discovery, used for cross-validation
    /// against the in-stream metadata sent by PrivateFilterController
    public var serviceDefinedMetadata: Data
    /// Serialized MetadataQuery protobuf. The helper prepends the metadata tag byte before encrypting.
    public var metadataSubscriptionPayload: Data

    public init(
        keyID: Data,
        attestationBundle: Data,
        serviceDefinedMetadata: Data,
        metadataSubscriptionPayload: Data
    ) {
        self.keyID = keyID
        self.attestationBundle = attestationBundle
        self.serviceDefinedMetadata = serviceDefinedMetadata
        self.metadataSubscriptionPayload = metadataSubscriptionPayload
    }

    public var description: String {
        """
        PersistentClientHelperInitParams(keyID: \(self.keyID.base64EncodedString()), \
        attestationBundle: \(self.attestationBundle.count) bytes, \
        serviceDefinedMetadata: \(self.serviceDefinedMetadata.count) bytes, \
        metadataSubscriptionPayload: \(self.metadataSubscriptionPayload.count) bytes)
        """
    }

    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        try self.keyID.encode(to: &buffer)
        try self.attestationBundle.encode(to: &buffer)
        try self.serviceDefinedMetadata.encode(to: &buffer)
        try self.metadataSubscriptionPayload.encode(to: &buffer)
    }

    public init(from buffer: inout ByteBuffer) throws {
        self.keyID = try .init(from: &buffer)
        self.attestationBundle = try .init(from: &buffer)
        self.serviceDefinedMetadata = try .init(from: &buffer)
        self.metadataSubscriptionPayload = try .init(from: &buffer)
    }
}

/// Messages sent from the creator (cloudboardd or cb_bridged) to the persistent helper
package enum PersistentHelperInboundMessage: ByteBufferCodable, Sendable, Hashable, CustomStringConvertible {
    /// Initialize the helper with key material and target endpoint
    case initialize(PersistentHelperInitParams)
    /// An encrypted query chunk from the encrypted side
    case encryptedChunk(Data, isFinal: Bool)
    /// Request graceful teardown
    case teardown

    public var description: String {
        switch self {
        case .initialize(let params):
            "initialize(\(params))"
        case .encryptedChunk(let data, isFinal: let isFinal):
            "encryptedChunk(\(data.count) bytes, isFinal: \(isFinal))"
        case .teardown:
            "teardown"
        }
    }

    @inlinable
    public func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .initialize(let params):
            buffer.writeInteger(0)
            try params.encode(to: &buffer)
        case .encryptedChunk(let data, isFinal: let isFinal):
            buffer.writeInteger(1)
            try data.encode(to: &buffer)
            try isFinal.encode(to: &buffer)
        case .teardown:
            buffer.writeInteger(2)
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
            self = try .initialize(.init(from: &buffer))
        case 1:
            self = try .encryptedChunk(.init(from: &buffer), isFinal: .init(from: &buffer))
        case 2:
            self = .teardown
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}

/// Messages sent from the persistent helper back to the creator (control channel)
package enum PersistentHelperOutboundMessage: CloudBoardAsyncXPCByteBufferMessage, Sendable, Equatable {
    public typealias Success = Never
    public typealias Failure = Never

    /// An encrypted response chunk to send back to the encrypted side
    case responseChunk(Data, isFinal: Bool)
    /// A failure has occurred
    case failureReport(PersistentHelperFailureReason)
    /// The helper has finished and will terminate
    case helperEOF
    /// The helper has successfully initialized and the HPKE link is established
    case initialized
    /// The router has confirmed all pending queries for this helper are complete.
    /// cb_bridged should send Terminate on this helper's gRPC stream.
    case drainComplete
    /// Raw decrypted metadata payload (without tag byte) forwarded from the encrypted
    /// stream for cb_bridged to parse and validate against service discovery metadata.
    case metadataUpdate(Data)

    public func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .responseChunk(let data, isFinal: let isFinal):
            buffer.writeInteger(0)
            try data.encode(to: &buffer)
            try isFinal.encode(to: &buffer)
        // Wire tag 1 was `.keyExpiring` — removed, slot intentionally skipped.
        case .failureReport(let reason):
            buffer.writeInteger(2)
            try reason.encode(to: &buffer)
        case .helperEOF:
            buffer.writeInteger(3)
        case .initialized:
            buffer.writeInteger(4)
        case .drainComplete:
            buffer.writeInteger(5)
        case .metadataUpdate(let payload):
            buffer.writeInteger(6)
            try payload.encode(to: &buffer)
        }
    }

    public init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        guard let enumCase: Int = buffer.readInteger() else {
            throw DecodingError.valueNotFound(
                Self.self,
                .init(codingPath: [], debugDescription: "no expected enum case")
            )
        }
        switch enumCase {
        case 0:
            self = try .responseChunk(.init(from: &buffer), isFinal: .init(from: &buffer))
        // Case 1 was `.keyExpiring` — removed because attestation rotation is now
        // detected by cloudboardd directly via AttestationProvider, not by the helper.
        // The slot is intentionally skipped to preserve wire-format compatibility.
        case 2:
            self = try .failureReport(.init(from: &buffer))
        case 3:
            self = .helperEOF
        case 4:
            self = .initialized
        case 5:
            self = .drainComplete
        case 6:
            self = try .metadataUpdate(.init(from: &buffer))
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}

/// Failure reasons specific to persistent helper operations
package enum PersistentHelperFailureReason: Int, ByteBufferCodable, Sendable, CustomStringConvertible, CaseIterable,
ReportableError {
    package var publicDescription: String {
        return self.description
    }

    case ohttpEncapsulationFailure
    case ohttpDecapsulationFailure
    case invalidAEAD
    case unknownKeyID
    case expiredKey
    case targetConnectionFailed

    public var description: String {
        return switch self {
        case .ohttpEncapsulationFailure: "ohttpEncapsulationFailure"
        case .ohttpDecapsulationFailure: "ohttpDecapsulationFailure"
        case .invalidAEAD: "invalidAEAD"
        case .unknownKeyID: "unknownKeyID"
        case .expiredKey: "expiredKey"
        case .targetConnectionFailed: "targetConnectionFailed"
        }
    }
}
