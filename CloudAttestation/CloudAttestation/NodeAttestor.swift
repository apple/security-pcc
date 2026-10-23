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

//
//  NodeAttestor.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import InternalSwiftProtobuf
import CryptoKit
@preconcurrency import Security
import Security_Private.SecKeyPriv
import os.log

/// Implements ``Attestor`` for Apple silicon nodes.
public struct NodeAttestor: Attestor {
    /// The environment for the attestation.
    public let environment: Environment

    /// The key lifetime duration for the attestation.
    public var defaultKeyDuration: Duration = .days(1)

    public internal(set) var assetProvider: any AttestationAssetProvider

    public internal(set) var sepProtocol: any SEP.AttestationProtocol = SEP.PhysicalDevice()

    @_spi(Private)
    public mutating func setAssetProvider(_ assetProvider: any AttestationAssetProvider) {
        self.assetProvider = assetProvider
    }

    @_spi(Private)
    public mutating func setSEPProtocol(_ sepProtocol: any SEP.AttestationProtocol) {
        self.sepProtocol = sepProtocol
    }

    @_spi(Private)
    public var transparencyProver: any TransparencyProver

    @_spi(Private)
    public var requireCertificateChain: Bool

    @_spi(Private)
    public var requireSealedHashes: Bool

    @_spi(Private)
    public var requireCryptex1: Bool

    @_spi(Private)
    public var populateSecureConfigMetadata: Bool = false

    @_spi(Private)
    public var preserveSecureConfigs: Bool = false

    @_spi(Private)
    public var certificateTransparency: Bool

    @_spi(Private)
    public var certificateTransparencyFetchFailClosed: Bool

    static let logger: Logger = Logger(subsystem: "com.apple.CloudAttestation", category: "NodeAttestor")

    static let dcik = SecKeyCopySystemKey(.DCIK, nil)?.takeRetainedValue()

    #if DEBUG
    var mockAttestingKey: SecKey? = nil
    public var attestingKey: SecKey {
        get throws {
            if let mockAttestingKey {
                return mockAttestingKey
            }
            guard let key = Self.dcik else {
                throw Error.dcikCreationFailure
            }
            guard let copy = SecKeyCreateDuplicate(key)?.takeRetainedValue() else {
                throw Error.dcikCreationFailure
            }
            return copy
        }
    }
    #else
    public var attestingKey: SecKey {
        get throws {
            guard let key = Self.dcik else {
                throw Error.dcikCreationFailure
            }
            guard let copy = SecKeyCreateDuplicate(key)?.takeRetainedValue() else {
                throw Error.dcikCreationFailure
            }
            return copy
        }
    }
    #endif

    /// Creates a new ``NodeAttestor``.
    public init() {
        self = .init(environment: Environment.current)
    }

    /// Creates a new ``NodeAttestor``.
    /// - Parameter environment: The environment for the attestation.
    public init(environment: Environment) {
        self = .init(
            transparencyProver: SWTransparencyLog(environment: environment),
            assetProvider: PCC.AssetProvider(),
            environment: environment
        )
    }

    /// Creates a new ``NodeAttestor``.
    /// - Parameter transparencyProver: The transparency prover.
    public init(
        transparencyProver: some TransparencyProver
    ) {
        self = .init(
            transparencyProver: transparencyProver,
            assetProvider: PCC.AssetProvider()
        )
    }

    @_spi(Private)
    public init(
        transparencyProver: some TransparencyProver,
        assetProvider: some AttestationAssetProvider
    ) {
        self = .init(transparencyProver: transparencyProver, assetProvider: assetProvider, environment: Environment.current)
    }

    @_spi(Private)
    public init(
        transparencyProver: some TransparencyProver,
        assetProvider: some AttestationAssetProvider,
        environment: Environment
    ) {
        self.assetProvider = assetProvider
        self.transparencyProver = transparencyProver
        self.environment = environment

        let configuration = Configuration(for: environment)
        self.requireCertificateChain = configuration.requireCertificateChain
        self.requireSealedHashes = configuration.requireSealedHashes
        self.requireCryptex1 = configuration.requireCryptex1
        self.certificateTransparency = configuration.certificateTransparency
        self.certificateTransparencyFetchFailClosed = configuration.certificateTransparencyFetchFailClosed
    }

    /// Creates an attestaton bundle for the given SEP key.
    /// - Parameters:
    ///   - key: The key to attest.
    ///   - expiration: The expiration date for the attestation.
    ///   - nonce: The nonce to use for the attestation.
    public func attest(key: SecKey, using attestationKey: SecKey, expiration: Date, nonce: Data?) async throws -> AttestationBundle {
        do {
            Self.logger.log("Attesting key in environment \(self.environment, privacy: .public)")

            if let nonce {
                SecKeySetParameter(attestationKey, kSecKeyParameterSETokenAttestationNonce, nonce as CFPropertyList, nil)
            }
            let parsedAttestation = try self.sepProtocol.attest(key: key, using: attestationKey)
            let attestation = parsedAttestation.data

            let provisioningCertificateChain = (try? await self.assetProvider.provisioningCertificateChain) ?? []
            let proto = try Proto_AttestationBundle.with { builder in
                builder.sepAttestation = attestation
                builder.keyExpiration = Google_Protobuf_Timestamp(date: expiration)

                do {
                    builder.apTicket = try self.assetProvider.apTicket
                } catch {
                    Self.logger.error("Unable to fetch ap ticket: \(error, privacy: .public)")
                    throw error
                }

                #if os(macOS)
                do {
                    builder.localPolicy = try .with { builder in
                        builder.implementation = .ec384Sha384
                        builder.policy = try self.assetProvider.localBootPolicy
                    }

                    builder.sfrManifest = try self.assetProvider.sfrManifest
                } catch {
                    Self.logger.error("Unable to fetch secure boot metadata: \(error, privacy: .public)")
                    if self.enforcementOptions.requireAllAssets {
                        throw error
                    }
                }
                #endif

                do {
                    // Only populate if not empty, so we don't have a wasteful empty proto field
                    if !provisioningCertificateChain.isEmpty {
                        builder.provisioningCertificateChain = provisioningCertificateChain
                    } else {
                        Self.logger.warning("Empty provisioning certificate chain")
                        if self.requireCertificateChain {
                            throw Error.emptyCertificateChain
                        }
                    }
                } catch {
                    Self.logger.error("Failed to obtain provisioning certificate chain from CFPrefs: \(error, privacy: .public)")
                    if self.requireCertificateChain {
                        throw error
                    }
                }

                do {
                    var sealedHashes = try self.assetProvider.sealedHashEntries
                    synchronizeLockStates(attestation: parsedAttestation, sealedHashes: &sealedHashes)

                    if let cryptexSlot = sealedHashes[cryptexSlotUUID] {
                        Self.logger.log("Reading cryptexes from \(cryptexSlotUUID, privacy: .public)")
                        populateCryptex(&builder, cryptexSlot, cryptexSlotUUID)
                    } else {
                        Self.logger.error("Failed to read cryptexes from \(cryptexSlotUUID, privacy: .public)")
                        if requireSealedHashes {
                            throw Error.missingCryptexes
                        }
                    }

                    if let secureConfigSlot = sealedHashes[secureConfigSlotUUID] {
                        Self.logger.log("Reading secure config from \(secureConfigSlot, privacy: .public)")
                        try populateSecureConfig(&builder, secureConfigSlot)
                    } else {
                        Self.logger.error("Failed to read secure config from \(secureConfigSlotUUID, privacy: .public)")
                        if requireSealedHashes {
                            throw Error.missingSecureConfig
                        }
                    }
                } catch {
                    Self.logger.error("Failed to read sealed hashes: \(error, privacy: .public)")
                    if requireSealedHashes {
                        throw error
                    }
                }
            }

            var bundle = AttestationBundle(proto: proto)
            let release: Release
            do {
                let evaluateTrust = self.requireCryptex1
                Self.logger.log("Computing release object: evaluateTrust=\(evaluateTrust, privacy: .public), requireCryptex1=\(requireCryptex1, privacy: .public))")
                release = try Release(bundle: bundle, evaluateTrust: evaluateTrust, requireCryptex1: requireCryptex1)
            } catch Image4Manifest.Error.trustEvaluationFailure(errno: 14) where requireCryptex1 {
                Self.logger.error("Failed to compute release object, likely because a PDI cryptex was supplied when cryptex1 is required")
                throw Error.unexpectedCryptexPDI
            } catch {
                Self.logger.error("Failed to compute release object")
                throw error
            }

            Self.logger.log("This device's \(release, privacy: .public):\n\(release.jsonString, privacy: .public)")
            let proofs = try await self.transparencyProver.proveInclusion(of: Data(release.digest()), at: nil, coveringAll: .release, preferOldest: true)
            Self.logger.debug("Fetched inclusion proofs for release")

            try proofs.verify(expiration: expiration)

            // only populate non-empty proofs
            if proofs.proofs != ATLogProofs() {
                bundle.proto.transparencyProofs = proofs.proto
            }

            // Populate Certificate Transparency proofs
            let certificateTransparencyPopulator = NodeCertificateTransparencyPopulator(
                certificateTransparency: self.certificateTransparency,
                certificateTransparencyFetchFailClosed: self.certificateTransparencyFetchFailClosed,
                transparencyProver: self.transparencyProver
            )
            try await certificateTransparencyPopulator.populateProofs(for: &bundle, expiration: expiration)

            // Can safely unwrap since a successful attestation of the key happened
            let publicKey = SecKeyCopyPublicKey(key)!
            let fingerprint = SecKeyCopyExternalRepresentation(publicKey, nil)!

            Self.logger.log("Successfully created attestation for key: \(SHA256.hash(data: fingerprint as Data), privacy: .public)")
            return bundle
        } catch {
            Self.logger.error("Attestation failed: \(error, privacy: .public)")
            throw error
        }
    }
}

extension NodeAttestor {
    struct NodeCertificateTransparencyPopulator: CertificateTransparencyPopulator {
        static let logger: Logger = Logger(subsystem: "com.apple.CloudAttestation", category: "NodeCertificateTransparencyPopulator")

        let certificateTransparency: Bool

        let certificateTransparencyFetchFailClosed: Bool

        let transparencyProver: any TransparencyProver

        func fetch(fingerprint: Data) async throws -> TransparencyLogProofs {
            try await self.transparencyProver.proveInclusion(of: fingerprint, at: nil, coveringAll: .serverNode, preferOldest: true)
        }
    }
}

// MARK: - Helpers
extension NodeAttestor {
    // mutate `sealedHashes` to end with a `.ratchetLocked` flag if the actual SEP register is locked
    func synchronizeLockStates(attestation: SEP.Attestation, sealedHashes: inout [UUID: [SEP.SealedHash.Entry]]) {
        for uuid in sealedHashes.keys {
            if let sh = attestation.sealedHash(at: uuid), sh.flags.contains(.ratchetLocked) {
                if let lastIndex = sealedHashes[uuid]?.indices.last, let last = sealedHashes[uuid]?.last {
                    sealedHashes[uuid]![lastIndex] = SEP.SealedHash.Entry(digest: last.digest, data: last.data, flags: last.flags.union(.ratchetLocked), algorithm: last.algorithm)
                }
            }
        }
    }

    fileprivate func populateCryptex(_ builder: inout Proto_AttestationBundle, _ entries: [SEP.SealedHash.Entry], _ slot: UUID) {
        guard !entries.isEmpty else {
            return
        }
        builder.sealedHashes.slots[slot.uuidString] = Proto_SealedHash.with { sh in
            let hashAlg = entries.first?.algorithm.protoHashAlg ?? .unknown
            sh.hashAlg = hashAlg
            sh.entries = entries.map { sepEntry in
                return Proto_SealedHash.Entry.with { entry in
                    entry.flags = Int32(sepEntry.flags.rawValue)
                    entry.digest = sepEntry.digest
                    if let metadata = sepEntry.metadata, populateSecureConfigMetadata {
                        entry.metadata = metadata
                    }

                    // sets .info = .cryptex(...)
                    if sepEntry.flags.contains(.ratchetLocked) && sepEntry.digest.elementsEqual(cryptexSignatureSealedHashSalt) {
                        entry.cryptexSalt = Proto_Cryptex.Salt()
                    } else {
                        entry.cryptex = Proto_Cryptex.with { cryptex in
                            if let data = sepEntry.data {
                                cryptex.image4Manifest = data
                            }
                        }
                    }
                }
            }
        }
    }

    fileprivate func populateSecureConfig(_ builder: inout Proto_AttestationBundle, _ entries: [SEP.SealedHash.Entry]) throws {
        guard !entries.isEmpty else {
            return
        }
        builder.sealedHashes.slots[secureConfigSlotUUID.uuidString] = try Proto_SealedHash.with { sh in
            let hashAlg = entries.first?.algorithm.protoHashAlg ?? .unknown
            sh.hashAlg = hashAlg
            sh.entries = try entries.map { sepEntry in
                try Proto_SealedHash.Entry.with { entry in
                    entry.flags = Int32(sepEntry.flags.rawValue)
                    entry.digest = sepEntry.digest
                    entry.secureConfig = try Proto_SecureConfig.with { sconf in
                        if let data = sepEntry.data {
                            guard let config = SecureConfig(from: data) else {
                                throw Error.malformedSecureConfig
                            }
                            if !preserveSecureConfigs {
                                // Deprecated field, remains in use for original PCC, use sconf.data instead
                                sconf.entry = config.entry
                                // Deprecated field, remains in use for original PCC, use sconf.data instead
                                sconf.metadata = config.metadata
                            } else {
                                sconf.data = config.serializedData
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - NodeAttestor Error API

extension NodeAttestor {
    public enum Error: Swift.Error, Equatable {
        case dcikCreationFailure
        case malformedSecureConfig
        case emptyCertificateChain
        case missingCryptexes
        case missingSecureConfig
        case unexpectedCryptexPDI
        @available(*, deprecated, message: "TransparencyLogError.pendingExpiration is thrown instead")
        case pendingTransparencyExpiry(proofsExpiration: Date, keyExpiration: Date)
        case nonceProvided
    }
}

// MARK: - helper extensions

extension SCSlotProtocol {
    fileprivate var protoHashAlg: Proto_HashAlg {
        switch self.algorithm {
        case "sha256":
            .sha256

        case "sha384":
            .sha384

        default:
            .unknown
        }
    }
}
