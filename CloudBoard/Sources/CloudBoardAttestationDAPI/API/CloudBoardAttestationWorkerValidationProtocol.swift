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

import CloudBoardCommon
import CloudBoardDomain
import CryptoKit
import Foundation
internal import CloudBoardAsyncXPC
internal import CloudBoardLogging

/// API used by a job helper to validate a worker's attestation, thus only used on proxy nodes
/// Done as a separate protocol to simplify mocking
package protocol CloudBoardAttestationWorkerValidationProtocol: Sendable {
    /// Validate the attestation from a worker in the context of the attestation used to initiate the request
    ///
    /// This completely abstracts away parsing the attestation as internal caching may result in not
    /// performing any parsing at all.
    ///
    /// Parameters:
    ///   - proxyAttestationKeyID: the key of the attestation used to initiate the request
    ///   - rawWorkerAttestationBundle: completely unparsed attestation of the worker
    func validateWorkerAttestation(
        // The id of the relevant key the parent request is operating under
        // This defines which releases are valid implicitly
        proxyAttestationKeyID: Data,
        // The raw attestation bundle to validate and parse
        // The udid and rackID will be extracted from the validated attestation for rack validation
        rawWorkerAttestationBundle: Data
    ) async throws -> WorkerValidationResult

    /// Pre-warm the validation cache for a worker against the proxy's most recent active attestation keys.
    ///
    /// The caller supplies only the worker bundle; the daemon validates it against the proxy keys it
    /// currently holds (most recent first, bounded by config), populating the shared validation cache so a
    /// subsequent hot-path ``validateWorkerAttestation(proxyAttestationKeyID:rawWorkerAttestationBundle:)``
    /// — for whichever active key the next request arrives wrapped to — is a cache hit. This keeps the cache
    /// warm across the proxy's own attestation rolls.
    ///
    /// Best-effort: per-key validation failures are swallowed (the hot path still validates on use), and a
    /// proxy with no usable active key yet returns a summary with `keysAttempted == 0` rather than blocking.
    func warmWorkerValidation(rawWorkerAttestationBundle: Data) async throws -> WarmWorkerValidationSummary
}

/// A proxy supports only formats it specifically understands.
///
/// A format is not just the structure of the bytes that represent it, it also implies the trustworthiness of
/// the attestions that use it.
/// In this way different formats can be mixed and matched easily (including within the same request) and
/// only specific clear points need to enforce the security policy
package enum AttestationFormat: Int {
    case cloudAttestation
    case testJson

    /// This will throw if the attestation format is not considered acceptable
    /// validation of the attestion itself is still required
    func allowed(config: SecureConfig) throws(AttestationFormatError) {
        switch self {
        case .cloudAttestation:
            // These are strong in all cases, the parsing and validation within ``CloudAttestation`` checks
            // all detailed requirements in accordance with the security policy
            return
        case .testJson:
            // none is legal by default, carry is not
            // But in certain testing scenarios it may be configured otherwise and we respect that.
            // In customer the config will forbid it regarless of any attempt to configure it otherwise
            guard config.allowAttestationTestFormats else {
                throw AttestationFormatError.formatNotAllowedUnderSecurityPolicy(
                    format: self, policy: config.securityPolicy
                )
            }
        }
    }
}

package enum AttestationFormatError: ReportableError {
    /// An attempt to use an attestation format which the policy disallows
    case formatNotAllowedUnderSecurityPolicy(
        format: AttestationFormat,
        policy: SecureConfig.Parameters.SecurityPolicy
    )
    /// An attestation (of the specified format) did not contain a HardwareID
    case hardwareIDMissing(format: AttestationFormat)

    package var publicDescription: String {
        return switch self {
        case .formatNotAllowedUnderSecurityPolicy(format: let format, policy: let policy):
            "Attestation format \(format) is not allowed under security policy \(policy)"
        case .hardwareIDMissing(format: let format):
            "Attestation stating format \(format) does not contain a hardwareID"
        }
    }
}

/// A minimal abstraction over hardware identifiers which can be included in attestations, like UDID.
/// This provides a means of segmenting the identifiers, which should not be treated as reasonable to
/// compare outside of their family.
///
/// In effect each ``AttestationFormat`` has a specific case here if the values of one are not considered
/// equatable with others, letting them co-exist without the potential for one (for example
/// the test format) to collide with a stronger one.
package enum HardwareID: Hashable, Sendable, ByteBufferCodable, CustomStringConvertible, Codable {
    /// We do not have any indication of the hardware, Not reasonable in customer
    case unknown
    /// it's an arbitrary string, there's no semantics associated with it and it's unverifiable
    case test(arbitraryId: String)
    /// These always use the UDID, strongly linked to the SEP
    case cloudAttestation(udid: String)
    /// Hardware identity from CloudAttestationV2 validation
    case cloudAttestationV2(identifier: String)

    internal func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .unknown:
            buffer.writeHostInteger(0)
        case .test(let arbitraryId):
            buffer.writeHostInteger(1)
            try arbitraryId.encode(to: &buffer)
        case .cloudAttestation(let udid):
            buffer.writeHostInteger(2)
            try udid.encode(to: &buffer)
        case .cloudAttestationV2(let identifier):
            buffer.writeHostInteger(3)
            try identifier.encode(to: &buffer)
        }
    }

    internal init(from buffer: inout ByteBuffer) throws {
        let enumCase: Int = try buffer.readHostIntegerOrThrow()
        switch enumCase {
        case 0:
            self = .unknown
        case 1:
            self = try .test(arbitraryId: String(from: &buffer))
        case 2:
            self = try .cloudAttestation(udid: String(from: &buffer))
        case 3:
            self = try .cloudAttestationV2(identifier: String(from: &buffer))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad HardwareID enum case \(enumCase)"
            ))
        }
    }

    /// These identifiers must be safe to log freely, since they are embedded in the attestation
    package var description: String {
        switch self {
        case .unknown:
            "unidentified"
        case .test(arbitraryId: let id):
            "test arbitraryId: \(id)"
        case .cloudAttestation(udid: let id):
            "cloudAttestation udid: \(id)"
        case .cloudAttestationV2(identifier: let id):
            "cloudAttestationV2 identifier: \(id)"
        }
    }
}

/// Represents the results of validating an attestation for a worker successfully
/// Many useful pieces of information are available at this point and exposed here
///
/// This hides all the actual ``CloudAttestation`` API so that test use cases
/// (using InMemoryKeys) can function correctly without most code needing to know
/// about them.
package struct ValidatedWorker: ByteBufferCodable, Sendable, Equatable {
    package static func == (lhs: ValidatedWorker, rhs: ValidatedWorker) -> Bool {
        return lhs.expiration == rhs.expiration &&
            lhs.publicKey.rawRepresentation == rhs.publicKey.rawRepresentation &&
            lhs.releaseDigest == rhs.releaseDigest &&
            lhs.appData == rhs.appData &&
            lhs.hardwareID == rhs.hardwareID &&
            lhs.appIdentifiers == rhs.appIdentifiers
    }

    /// The key should not be used after this date
    package var expiration: Date

    /// The public key which can be used to establish a secure communication channel with
    package var publicKey: Curve25519.KeyAgreement.PublicKey

    /// The SHA256 digest of the release this attestation is for
    package var releaseDigest: String

    /// The application-specific data included in the attestation.
    /// Note that this may contain a rackId, but consuming code MUST reference
    /// the associated ``RackValidationResult``
    package var appData: [String: Data]

    /// An identifier for the hardware backing the attestation, such as the UDID of a SEP
    package var hardwareID: HardwareID

    /// The app identifiers from the worker's attestation bundle
    package var appIdentifiers: [String]?

    /// convenience for testing and other scenarios that assume udids
    internal init(
        expiration: Date,
        publicKey: Curve25519.KeyAgreement.PublicKey,
        releaseDigest: String,
        appData: [String: Data],
        udid: String,
        appIdentifiers: [String]? = nil
    ) {
        self.init(
            expiration: expiration,
            publicKey: publicKey,
            releaseDigest: releaseDigest,
            appData: appData,
            hardwareID: .cloudAttestation(udid: udid),
            appIdentifiers: appIdentifiers
        )
    }

    public init(
        expiration: Date,
        publicKey: Curve25519.KeyAgreement.PublicKey,
        releaseDigest: String,
        appData: [String: Data],
        hardwareID: HardwareID,
        appIdentifiers: [String]? = nil
    ) {
        self.expiration = expiration
        self.publicKey = publicKey
        self.releaseDigest = releaseDigest
        self.appData = appData
        self.hardwareID = hardwareID
        self.appIdentifiers = appIdentifiers
    }

    func encode(to buffer: inout ByteBuffer) throws {
        try self.expiration.encode(to: &buffer)
        try PublicKeyEnvelope(self.publicKey).encode(to: &buffer)
        try self.releaseDigest.encode(to: &buffer)
        try self.appData.encode(to: &buffer)
        try self.hardwareID.encode(to: &buffer)
        try self.appIdentifiers.encode(to: &buffer)
    }

    init(from buffer: inout ByteBuffer) throws {
        self.expiration = try .init(from: &buffer)
        self.publicKey = try PublicKeyEnvelope(from: &buffer).key
        self.releaseDigest = try .init(from: &buffer)
        self.appData = try .init(from: &buffer)
        self.hardwareID = try .init(from: &buffer)
        self.appIdentifiers = try .init(from: &buffer)
    }
}

/// Represents the result of rack validation
package enum RackValidationResult: Sendable, Equatable {
    /// The rack information is usable, but it may be irrelevant.
    /// If relevant it is reasonable to use for trust decisions or reuse, if not relevant this
    /// implies it may not be used for those purposes (what that results in is for the calling code to decide)
    case allowed(RackId)
    /// The rack may not be used for trust decisions or reuse
    case blocked(rackValidationError: WorkerRackValidationError)
}

extension RackValidationResult: ByteBufferCodable {
    func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .allowed(let rack):
            buffer.writeHostInteger(0)
            try rack.encode(to: &buffer)
        case .blocked(let rackValidationError):
            buffer.writeHostInteger(1)
            try rackValidationError.encode(to: &buffer)
        }
    }

    init(from buffer: inout ByteBuffer) throws {
        let enumCase: Int = try buffer.readHostIntegerOrThrow()
        switch enumCase {
        case 0:
            self = try .allowed(.init(from: &buffer))
        case 1:
            self = try .blocked(rackValidationError: .init(from: &buffer))
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}

package enum WorkerRackValidationError: Error, Codable, Sendable, ByteBufferCodable, Equatable {
    /// The rackId for the hardware changed, we block use of these for a period of time
    case rackIdChanged(reason: String, originalRackId: String, blockedUntil: Date, hardwareID: HardwareID)

    package var publicDescription: String {
        switch self {
        case .rackIdChanged(let reason, let originalRackId, let blockedUntil, let hardwareID):
            return "Worker \(hardwareID) blocked due to rack change: \(reason), original rack: \(originalRackId), blocked until: \(blockedUntil)"
        }
    }

    func encode(to buffer: inout ByteBuffer) throws {
        switch self {
        case .rackIdChanged(let reason, let originalRackId, let blockedUntil, let hardwareID):
            buffer.writeHostInteger(0)
            try reason.encode(to: &buffer)
            try originalRackId.encode(to: &buffer)
            try blockedUntil.encode(to: &buffer)
            try hardwareID.encode(to: &buffer)
        }
    }

    init(from buffer: inout ByteBuffer) throws {
        let enumCase: Int = try buffer.readHostIntegerOrThrow()
        switch enumCase {
        case 0:
            self = try .rackIdChanged(
                reason: .init(from: &buffer),
                originalRackId: .init(from: &buffer),
                blockedUntil: .init(from: &buffer),
                hardwareID: .init(from: &buffer)
            )
        case let value:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(value)"
            ))
        }
    }
}

/// Combined result of worker attestation validation and rack validation
package struct WorkerValidationResult: ByteBufferCodable, Sendable, CustomStringConvertible {
    public var validatedWorker: ValidatedWorker
    public var rackValidation: RackValidationResult

    public init(validatedWorker: ValidatedWorker, rackValidation: RackValidationResult) {
        self.validatedWorker = validatedWorker
        self.rackValidation = rackValidation
    }

    public var description: String {
        return "WorkerValidationResult(hardwareID: \(self.validatedWorker.hardwareID), releaseDigest: \(self.validatedWorker.releaseDigest), expiration: \(self.validatedWorker.expiration), rackValidation: \(self.rackValidation))"
    }

    func encode(to buffer: inout ByteBuffer) throws {
        try self.validatedWorker.encode(to: &buffer)
        try self.rackValidation.encode(to: &buffer)
    }

    init(from buffer: inout ByteBuffer) throws {
        self.validatedWorker = try .init(from: &buffer)
        self.rackValidation = try .init(from: &buffer)
    }
}

/// Outcome of a ``warmWorkerValidation(rawWorkerAttestationBundle:)`` request.
///
/// `keysAttempted` is the number of active proxy keys the worker was validated against (0 when the proxy has
/// no usable active key yet — a benign no-op). `keysSucceeded` is how many of those validations passed; a
/// value below `keysAttempted` indicates the worker failed validation against some keys (still recorded, the
/// hot path remains authoritative on use).
package struct WarmWorkerValidationSummary: ByteBufferCodable, Sendable, Equatable, CustomStringConvertible {
    public var keysAttempted: Int
    public var keysSucceeded: Int

    public init(keysAttempted: Int, keysSucceeded: Int) {
        self.keysAttempted = keysAttempted
        self.keysSucceeded = keysSucceeded
    }

    public var description: String {
        "WarmWorkerValidationSummary(keysAttempted: \(self.keysAttempted), keysSucceeded: \(self.keysSucceeded))"
    }

    func encode(to buffer: inout ByteBuffer) throws {
        buffer.writeHostInteger(self.keysAttempted)
        buffer.writeHostInteger(self.keysSucceeded)
    }

    init(from buffer: inout ByteBuffer) throws {
        self.keysAttempted = try buffer.readHostIntegerOrThrow()
        self.keysSucceeded = try buffer.readHostIntegerOrThrow()
    }
}
