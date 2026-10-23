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
import CloudBoardMetrics

// just for the fake attestation support
internal import HTTPClientStateMachine
@_spi(SEP_Curve25519) import CryptoKit
@_spi(SEP_Curve25519) import CryptoKitPrivate
import Foundation
import os

/// Provides in-memory (non-SEP backed) key with a fake attestation bundle (an OHTTP key configuration containing the
/// node's public key)
struct InMemoryKeyAttestationProvider: AttestationProviderProtocol {
    /// In _theory_ this could change (as it's calculated for each attestation produced) but in
    /// reality it should be tied to the OS version, config and installed cryptexes, which should not change
    /// after startup so just make it fixed
    let releaseDigest: String
    /// This may not actually be tied to the real hardware, but it will be treated as such
    let hardwareID: String
    let ensembleID: String
    let bootID: String
    let rackID: RackId

    let attestationBundleCache: AttestationBundleCache = NoopAttestationBundleCache()

    /// Make a provider that knows the releaseSet of itself, and optionaly
    /// will create attestations which indicate it transitively trusts itself
    init(
        releaseDigest: String,
        ensembleID: String,
        bootID: String,
        rackID: RackId,
        hardwareID: String = UUID().uuidString
    ) {
        self.releaseDigest = releaseDigest
        self.ensembleID = ensembleID
        self.bootID = bootID
        self.rackID = rackID
        self.hardwareID = hardwareID
    }

    func restoreKeysFromDisk(
        attestationCache _: AttestationBundleCache,
        keyExpiryGracePeriod _: TimeInterval
    ) async -> [InternalAttestedKey] {
        /// Already lost the in memory private key, nothing to return
        return []
    }

    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "InMemoryAttestationProvider"
    )

    /// There are testing cases where we use a real SEP backed key, but not the attestation system
    /// this lets us use whatever key we like, but be consistent with the formatting
    static func createBundleForKey(
        _ publicKey: Curve25519.KeyAgreement.PublicKey,
        expiration: Date,
        releaseDigest: String,
        proxiedReleaseDigests: [String]?,
        computeNodeAppData: [String: Data],
        hardwareID: String
    ) throws -> RawAttestationBundle {
        // For development it's simpler to just define this by fiat
        let kem = HPKE.KEM.Curve25519_HKDF_SHA256
        let appData: TestOnlyAttestationInfo.AppData = if let proxiedReleaseDigests, proxiedReleaseDigests.count > 0 {
            .proxy(.init(transitivelyTrustedReleaseDigests: proxiedReleaseDigests))
        } else {
            .compute(.init(metadata: computeNodeAppData))
        }
        return try TestOnlyAttestationBundle.encodeAsVersion1(
            for: publicKey,
            kem: kem,
            info: TestOnlyAttestationInfo(
                expiration: expiration,
                releaseDigest: releaseDigest,
                appData: appData,
                computeNodeMetadata: computeNodeAppData,
                hardwareID: hardwareID
            )
        )
    }

    func createAttestedKey(
        clock: any DateAwareClock,
        attestationLifetime: Duration,
        keyExpiryGracePeriod: TimeInterval,
        proxiedReleaseDigests: [ReleaseDigestEntry]
    ) async throws -> InternalAttestedKey {
        Self.logger.warning("Using insecure in-memory key. No SEP attestation will be available.")

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        Self.logger.notice(
            "Created attested in-memory key with public key \(privateKey.publicKey.rawRepresentation.base64EncodedString(), privacy: .public)"
        )

        var appData: [String: Data] = [:]
        appData[ComputeNodeAppDataKeys.rackID] = self.rackID.rackId.data
        appData[ComputeNodeAppDataKeys.ensembleID] = self.ensembleID.data
        appData[ComputeNodeAppDataKeys.bootID] = self.bootID.data

        let attestationExpiry = clock.dateNow.advanced(by: attestationLifetime.seconds)
        // We cannot create real attestation bundles for non-SEP keys.
        // we therefore use the fake format.
        let attestationBundle = try Self.createBundleForKey(
            privateKey.publicKey,
            expiration: attestationExpiry,
            releaseDigest: self.releaseDigest,
            proxiedReleaseDigests: proxiedReleaseDigests.map { $0.releaseDigestHexString },
            computeNodeAppData: appData,
            hardwareID: self.hardwareID
        )
        return InternalAttestedKey(
            key: .direct(privateKey: privateKey.rawRepresentation),
            attestationBundle: attestationBundle,
            releaseDigest: self.releaseDigest,
            proxiedReleaseDigests: proxiedReleaseDigests.map { $0.releaseDigestHexString },
            expiry: attestationExpiry + keyExpiryGracePeriod,
            appData: appData
        )
    }
}

final class InMemoryReleasesProvider: ReleasesProviderProtocol {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "InMemoryReleasesProvider"
    )

    let releases: [ReleaseDigestEntry]

    init(releases: [String]) {
        self.releases = releases.map {
            .init(releaseDigestHexString: $0, expiry: .distantFuture)
        }
    }

    func run() async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .hours(24))
        }
    }

    func getCurrentReleaseSet() async throws -> [ReleaseDigestEntry] {
        return self.releases
    }

    func trustedReleaseSetUpdates() async throws -> ReleasesUpdatesSubscription {
        let (stream, cont) = AsyncStream<[ReleaseDigestEntry]>.makeStream()
        cont.yield(self.releases)
        return .init(id: 0, updates: stream)
    }

    func deregister(_: Int) {
        // no op
    }
}
