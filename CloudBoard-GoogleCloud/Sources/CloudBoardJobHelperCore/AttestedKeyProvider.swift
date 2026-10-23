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

import Crypto

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Provides a key attestation with a corresponding key handle
package protocol AttestationProvider: Sendable {
    func currentAttestationSet() async throws -> AttestationSet
    func watchAttestationSets() -> AsyncStream<AttestationSet>
}

/// Provides an HPKE KEM key, the Request Encryption Key (REK), that is associated with they provided key ID and the
/// corresponding attestation.
package protocol AttestedKeyProvider: Sendable {
    func key(for keyID: Data) async throws -> any HPKEKEMPrivateKey
}

/// Attested key set containing the key and attestation bundle for the most recent key as well as keys and related
/// metatadata (IDs and expiries) for all unpublished but still active keys allowing cb_jobhelper to handle requests
/// wrapped to any unexpired key.
package struct AttestedKeySet: Codable, Sendable, Equatable {
    package var currentKey: AttestedKey
    package var unpublishedKeys: [AttestedKey]

    package init(currentKey: AttestedKey, unpublishedKeys: [AttestedKey]) {
        self.currentKey = currentKey
        self.unpublishedKeys = unpublishedKeys
    }
}

package enum AttestedKeyType: Codable, Sendable, Equatable {
    // Used for testing. Long-term we don't expect components that need to use the key to have direct access.
    case direct(privateKey: Data)
}

package struct AttestedKey: Codable, Sendable, Equatable {
    package var key: AttestedKeyType
    /// Attestation bundle containing the key attestation as well as metadata to velidate the it. This bundle also
    /// encodes the key expiry. Note that this expiry is not equivalent to ``expiry`` which includes an additional grace
    /// period.
    package var attestationBundle: Data
    /// Date after which CloudBoard will reject incoming requests wrapped to this key
    package var expiry: Date
    /// The sha-256 digest of the release section of the attestation bundle
    package var releaseDigest: String

    /// Application specific attestation data
    package var appData: [String: Data]

    package init(
        key: AttestedKeyType,
        attestationBundle: Data,
        expiry: Date,
        releaseDigest: String,
        appData: [String: Data],
    ) {
        self.key = key
        self.attestationBundle = attestationBundle
        self.expiry = expiry
        self.releaseDigest = releaseDigest
        self.appData = appData
    }
}

/// Attestation set containing the attestation bundle for the most recent key as well as key information (IDs
/// and expiries) for all unpublished but still active keys/attestations allowing ROPES to determine which key/node
/// identifiers to accept/reject without forwarding requests to CloudBoard.
package struct AttestationSet: Codable, Sendable, Equatable {
    package struct Attestation: Codable, Sendable, Equatable {
        /// Attestation bundle containing the key attestation as well as metadata to validate the it. This bundle also
        /// encodes the key expiry. Note that this expiry is not equivalent to ``expiry`` which includes an additional
        /// grace period.
        package var attestationBundle: Data
        /// Date after which CloudBoard will reject incoming requests wrapped to this key
        package var expiry: Date
        /// The sha-256 digest of the release section of the attestation bundle
        package var releaseDigest: String

        package var appData: [String: Data]

        /// Highest transparency log tree ID across the bundle's transparency proofs, if available.
        package var transparencyTreeID: UInt64?
        /// Highest transparency log revision within that tree, if available.
        package var transparencyRevision: UInt64?

        package init(
            attestationBundle: Data,
            expiry: Date,
            releaseDigest: String,
            appData: [String: Data] = [:],
            transparencyTreeID: UInt64? = nil,
            transparencyRevision: UInt64? = nil,
        ) {
            self.attestationBundle = attestationBundle
            self.expiry = expiry
            self.releaseDigest = releaseDigest
            self.appData = appData
            self.transparencyTreeID = transparencyTreeID
            self.transparencyRevision = transparencyRevision
        }

        /// Key ID, used by ROPES as "node identifier". This is the SHA256 sum of the key's attestation bundle allowing
        /// the
        /// client to verify that the "node identifier" has not been modified in-flight.
        package var keyID: Data {
            Data(SHA256.hash(data: self.attestationBundle))
        }
    }

    package var currentAttestation: Attestation
    package var unpublishedAttestations: [Attestation]
    package var allAttestations: [Attestation] {
        [self.currentAttestation] + self.unpublishedAttestations
    }

    package init(currentAttestation: Attestation, unpublishedAttestations: [Attestation]) {
        self.currentAttestation = currentAttestation
        self.unpublishedAttestations = unpublishedAttestations
    }
}

extension AttestationSet {
    package init(keySet: AttestedKeySet) {
        self = .init(
            currentAttestation: .init(key: keySet.currentKey),
            unpublishedAttestations: keySet.unpublishedKeys.map { .init(key: $0) },
        )
    }
}

extension AttestationSet.Attestation {
    package init(key: AttestedKey) {
        self = .init(
            attestationBundle: key.attestationBundle,
            expiry: key.expiry,
            releaseDigest: key.releaseDigest,
            appData: key.appData,
        )
    }
}
