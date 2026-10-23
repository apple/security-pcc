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

internal import CloudBoardAsyncXPC
import CryptoKit
import Foundation
import Security

package protocol CloudBoardAttestationAPIClientProtocol: CloudBoardAttestationAPIClientToServerProtocol {
    func set(delegate: CloudBoardAttestationAPIClientDelegateProtocol) async
    func connect() async
}

/// Attested key set containing the key and attestation bundle for the most recent key as well as keys and related
/// metatadata (IDs and expiries) for all unpublished but still active keys allowing cb_jobhelper to handle requests
/// wrapped to any unexpired key.
public struct AttestedKeySet: Codable, Sendable, Equatable {
    public var currentKey: AttestedKey
    public var unpublishedKeys: [AttestedKey]

    public init(currentKey: AttestedKey, unpublishedKeys: [AttestedKey]) {
        self.currentKey = currentKey
        self.unpublishedKeys = unpublishedKeys
    }
}

public enum AttestedKeyType: Codable, Sendable, Equatable {
    // using the SEP and keychain properly
    case keychain(persistentKeyReference: Data)
    // for testing when the SEP isn't viable
    case direct(privateKey: Data)
}

public struct AttestedKey: Codable, Sendable, Equatable {
    public var key: AttestedKeyType
    /// Key ID, used by ROPES as "node identifier". This is the SHA256 sum of the key's attestation bundle allowing the
    /// client to verify that the "node identifier" has not been modified in-flight. Also used by cb_jobhelper to
    /// determine which key to use for unwrapping the client's session key material.
    public var keyID: Data

    /// Date after which CloudBoard will reject incoming requests wrapped to this key
    public var expiry: Date

    /// Application specific attestation data
    public var appData: [String: Data]

    public init(
        key: AttestedKeyType,
        keyID: Data,
        expiry: Date,
        appData: [String: Data] = [:]
    ) {
        self.key = key
        self.keyID = keyID
        self.expiry = expiry
        self.appData = appData
    }
}

/// Attestation set containing the attestation bundle for the most recent key as well as key information (IDs
/// and expiries) for all unpublished but still active keys/attestations allowing ROPES to determine which key/node
/// identifiers to accept/reject without forwarding requests to CloudBoard.
public struct AttestationSet: Codable, Sendable, Equatable {
    public struct Attestation: Codable, Sendable, Equatable {
        /// Attestation bundle containing the key attestation as well as metadata to validate the it. This bundle also
        /// encodes the key expiry. Note that this expiry is not equivalent to ``expiry`` which includes an additional
        /// grace period.
        public var attestationBundle: Data
        /// Date after which CloudBoard will reject incoming requests wrapped to this key
        public var expiry: Date
        /// The sha-256 digest of the release section of the attestation bundle
        public var releaseDigest: String
        /// If true, the attestation key id should not be sent to ROPES
        /// The key id is still valid to be used till it's expiry
        public var availableOnNodeOnly: Bool
        /// The sha-256 digest of the releases of nodes which the node with this key can proxy requests to
        public var proxiedReleaseDigests: [String]

        public var appData: [String: Data]

        /// Transparency log tree ID from the attestation bundle's transparency proofs
        public var transparencyTreeID: UInt64?
        /// Transparency log revision number from the attestation bundle's transparency proofs
        public var transparencyRevision: UInt64?

        public init(
            attestationBundle: Data,
            expiry: Date,
            releaseDigest: String,
            availableOnNodeOnly: Bool,
            proxiedReleaseDigests: [String] = [],
            appData: [String: Data] = [:],
            transparencyTreeID: UInt64? = nil,
            transparencyRevision: UInt64? = nil
        ) {
            self.attestationBundle = attestationBundle
            self.expiry = expiry
            self.releaseDigest = releaseDigest
            self.availableOnNodeOnly = availableOnNodeOnly
            self.proxiedReleaseDigests = proxiedReleaseDigests
            self.appData = appData
            self.transparencyTreeID = transparencyTreeID
            self.transparencyRevision = transparencyRevision
        }
    }

    public var currentAttestation: Attestation
    public var unpublishedAttestations: [Attestation]
    public var allAttestations: [Attestation] {
        return [self.currentAttestation] + self.unpublishedAttestations
    }

    public init(currentAttestation: Attestation, unpublishedAttestations: [Attestation]) {
        self.currentAttestation = currentAttestation
        self.unpublishedAttestations = unpublishedAttestations
    }
}

package protocol CloudBoardAttestationAttestationLookupProtocol: Actor {
    func requestAttestedKeySet() async throws -> AttestedKeySet
    func requestAttestationSet() async throws -> AttestationSet
}

package protocol CloudBoardAttestationAttestationRevocationProtocol: Actor {
    func forceRevocation(keyIDs: [Data]) async throws
}

package protocol CloudBoardAttestationAPIClientToServerProtocol:
    CloudBoardAttestationAttestationLookupProtocol,
    CloudBoardAttestationWorkerValidationProtocol,
    CloudBoardAttestationAttestationRevocationProtocol {}

public protocol CloudBoardAttestationAPIClientDelegateProtocol: AnyObject, Sendable,
CloudBoardAttestationAPIServerToClientProtocol {
    func surpriseDisconnect() async
}

extension AttestedKey: CustomStringConvertible {
    public var description: String {
        """
        key ID \(self.keyID.base64EncodedString()), \
        expiry \(self.expiry)
        """
    }
}

extension AttestedKeySet: CustomStringConvertible {
    public var description: String {
        """
        current key (\(self.currentKey)), \
        unpublished keys (\(self.unpublishedKeys))
        """
    }
}

extension AttestationSet.Attestation {
    /// Key ID, used by ROPES as "node identifier". This is the SHA256 sum of the key's attestation bundle allowing the
    /// client to verify that the "node identifier" has not been modified in-flight.
    public var keyID: Data {
        Data(SHA256.hash(data: self.attestationBundle))
    }
}

extension AttestationSet.Attestation: CustomStringConvertible {
    public var description: String {
        """
        key ID \(self.keyID.base64EncodedString()), \
        expiry \(self.expiry)
        """
    }
}

extension AttestationSet: CustomStringConvertible {
    public var description: String {
        """
        current attestation (\(self.currentAttestation)), \
        unpublished attestations (\(self.unpublishedAttestations))
        """
    }
}
