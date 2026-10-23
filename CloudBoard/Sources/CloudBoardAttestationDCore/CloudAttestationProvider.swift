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

@_spi(Private) import CloudAttestation
import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardLogging
import CloudBoardMetrics
@_spi(SEP_Curve25519) import CryptoKit
@_spi(SEP_Curve25519) import CryptoKitPrivate
import Foundation
import InternalSwiftProtobuf
import NIOCore
import os
import Security_Private.SecItemPriv
import Security_Private.SecKeyPriv

enum CloudAttestationProviderError: ReportableError {
    case sepUnavailable
    case failedToAccessControlFlags(Error)
    case failedToDeleteExistingKey(Error)
    case failedToCreateKey(Error)
    case failedToObtainPersistentKeyReference(OSStatus)
    case failedToParseTransparencyURL(String)
    case earlyExit
    case cloudAttestationUnavailable
    case releaseDigestsExpirationCheckFailed
    case failedToStoreBootID
    case failedToReadBootID

    var publicDescription: String {
        let errorType = switch self {
        case .sepUnavailable: "sepUnavailable"
        case .failedToAccessControlFlags(let error): "failedToAccessControlFlags(\(String(reportable: error)))"
        case .failedToDeleteExistingKey(let error): "failedToDeleteExistingKey(\(String(reportable: error)))"
        case .failedToCreateKey(let error): "failedToCreateKey(\(String(reportable: error)))"
        case .failedToObtainPersistentKeyReference(let osStatus):
            "failedToObtainPersistentKeyReference(osStatus: \(osStatus))"
        case .failedToParseTransparencyURL: "failedToParseTransparencyURL"
        case .earlyExit: "earlyExit"
        case .cloudAttestationUnavailable: "cloudAttestationUnavailable"
        case .releaseDigestsExpirationCheckFailed: "releaseDigestsExpirationCheckFailed"
        case .failedToStoreBootID: "failedToStoreBootID"
        case .failedToReadBootID: "failedToReadBootID"
        }
        return "cloudAttestation.\(errorType)"
    }
}

/// Provides attested key with an attestation provided by CloudAttestation.framework
struct CloudAttestationProvider: AttestationProviderProtocol {
    fileprivate static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudAttestationProvider"
    )

    private var configuration: CloudBoardAttestationDConfiguration
    private var keychain: SecKeychain?
    private var metrics: MetricsSystem
    private var releaseDigestExpiryGracePeriod: TimeAmount?
    private var nodeInfo: NodeInfo
    private var bootID: String?

    init(
        configuration: CloudBoardAttestationDConfiguration,
        keychain: SecKeychain? = nil,
        metrics: MetricsSystem,
        releaseDigestExpiryGracePeriod: TimeAmount? = nil,
        nodeInfo: NodeInfo,
        bootID: String?
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.metrics = metrics
        self.releaseDigestExpiryGracePeriod = releaseDigestExpiryGracePeriod
        self.nodeInfo = nodeInfo
        self.bootID = bootID
    }

    func createAttestedKey(
        clock: any DateAwareClock,
        attestationLifetime: Duration,
        keyExpiryGracePeriod: TimeInterval,
        proxiedReleaseDigests: [ReleaseDigestEntry] = []
    ) async throws -> InternalAttestedKey {
        Self.logger.info("Creating attested SEP-backed X25519 key")

        guard SecureEnclave.isAvailable else {
            Self.logger.fault("SEP is unavailable. Cannot create an attested SEP-backed key.")
            fatalError("SEP is unavailable. Cannot create an attested SEP-backed key.")
        }

        let retryConfig = self.configuration.cloudAttestation.attestationRetryConfiguration
        let retryStrategy = self.createCloudAttestationRetryStrategy(retryConfig: retryConfig)

        return try await self.metrics.withStatusMetrics(
            total: CloudBoardAttestationMetrics.CloudAttestation.AttestationCounter(action: .increment(by: 1)),
            error: CloudBoardAttestationMetrics.CloudAttestation.AttestationErrorCounter.Factory()
        ) {
            return try await executeWithRetries(
                retryStrategy: retryStrategy,
                perRetryTimeout: retryConfig.perRetryTimeout
            ) {
                let attestationBundleExpiry = clock.dateNow + attestationLifetime.seconds
                let releaseEntryExpirationWithGracePeriod = attestationBundleExpiry
                    .advanced(by: self.releaseDigestExpiryGracePeriod?.timeInterval ?? 0)
                let filteredReleaseDigests = proxiedReleaseDigests.filter { releaseEntry in
                    releaseEntry.expiry > releaseEntryExpirationWithGracePeriod
                }.map { $0.releaseDigestHexString }

                // we should only fail on empty filteredReleaseDigests if proxiedReleaseDigests was non empty
                // since proxiedReleaseDigests could be passed empty in test env like ephemeral
                if !proxiedReleaseDigests.isEmpty, filteredReleaseDigests.isEmpty {
                    throw CloudAttestationProviderError.releaseDigestsExpirationCheckFailed
                } else {
                    Self.logger.log(
                        "Filtered release digests: \(filteredReleaseDigests, privacy: .public). Provided release digests: \(proxiedReleaseDigests, privacy: .public)"
                    )
                }

                let privateKey = try createSecureEnclaveKey()
                let publicKey = try SecureEnclave.Curve25519.KeyAgreement.PrivateKey(from: privateKey).publicKey
                let (
                    attestationBundle,
                    releaseDigest,
                    appData,
                    transparencyTreeID,
                    transparencyRevision
                ) = try await createAttestationBundleAndReleaseDigest(
                    for: privateKey,
                    expiry: attestationBundleExpiry,
                    releaseDigests: filteredReleaseDigests
                )

                Self.logger.notice(
                    "Created attested SEP-backed key with public key \(publicKey.rawRepresentation.base64EncodedString(), privacy: .public)"
                )

                return InternalAttestedKey(
                    key: .sepKey(secKey: privateKey),
                    attestationBundle: attestationBundle,
                    releaseDigest: releaseDigest,
                    proxiedReleaseDigests: filteredReleaseDigests,
                    expiry: attestationBundleExpiry + keyExpiryGracePeriod,
                    appData: appData,
                    transparencyTreeID: transparencyTreeID,
                    transparencyRevision: transparencyRevision
                )
            }
        }
    }

    private func createSecureEnclaveKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let aclOpts = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAlwaysThisDeviceOnlyPrivate,
            .privateKeyUsage,
            &error
        ) else {
            // If this returns nil, error must be set
            throw CloudAttestationProviderError.failedToAccessControlFlags(error!.takeRetainedValue() as Error)
        }

        // Create key
        var attributes = Keychain.baseNodeKeyQuery
        attributes[kSecAttrIsPermanent as String] = false
        attributes.addKeychainAttributes(keychain: self.keychain, for: .update)
        attributes[kSecPrivateKeyAttrs as String] = [
            kSecAttrAccessControl: aclOpts,
            kSecAttrLabel: "CloudBoard X25519 Key",
            kSecKeyOSBound: true,
            kSecKeySealedHashesBound: true,
        ] as [String: Any]
        guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            // If this returns nil, error must be set
            throw CloudAttestationProviderError.failedToCreateKey(error!.takeRetainedValue() as Error)
        }

        return secKey
    }

    private func createCloudAttestationRetryStrategy(
        retryConfig: CloudBoardAttestationDConfiguration
            .RetryConfiguration
    ) -> RetryStrategy {
        return RetryWithBackoff(
            backoffStrategy: ExponentialBackoffStrategy(from: retryConfig),
            deadline: retryConfig.timeout.map { .instant(.now + $0) } ?? .noDeadline,
            retryFilter: { error in
                // We defensively retry on all errors as we don't have an exhaustive set of known retryable errors and
                // the set might change over time.
                self.metrics
                    .emit(
                        CloudBoardAttestationMetrics.CloudAttestation
                            .AttestationRetryCounter(action: .increment(by: 1))
                    )
                self.metrics
                    .emit(CloudBoardAttestationMetrics.CloudAttestation.AttestationErrorCounter.Factory().make(error))
                Self.logger.error(
                    "Failed to generate attestation with error: \(String(unredacted: error), privacy: .public). Retrying with backoff."
                )
                return .continue
            }
        )
    }

    private func createAttestationBundleAndReleaseDigest(
        for privateKey: SecKey,
        expiry: Date,
        releaseDigests: [String]
    ) async throws
        -> (
            attestationBundle: Data,
            ourReleaseDigest: String,
            appData: [String: Data],
            transparencyTreeID: UInt64?,
            transparencyRevision: UInt64?
        ) {
        let appData: [String: Data] = if self.configuration.isProxy {
            // proxies have no 'slot' to store this, it is already taken up by the release digests
            [:]
        } else {
            [
                ComputeNodeAppDataKeys.rackID: self.nodeInfo.rackID?.data ?? Data(),
                ComputeNodeAppDataKeys.ensembleID: self.nodeInfo.ensembleID?.data ?? Data(),
                ComputeNodeAppDataKeys.bootID: self.bootID?.data ?? Data(),
            ]
        }

        guard self.configuration.cloudAttestation.enabled else {
            Self.logger.warning("Attestation via CloudAttestation.framework disabled. Using fake attestation bundle.")
            let publicKey = try SecureEnclave.Curve25519.KeyAgreement.PrivateKey(from: privateKey).publicKey
            let ourReleaseDigest = CloudBoardAttestation.neverKnownReleaseDigest

            return try (InMemoryKeyAttestationProvider.createBundleForKey(
                publicKey,
                expiration: expiry,
                releaseDigest: ourReleaseDigest,
                proxiedReleaseDigests: self.configuration.isProxy ? releaseDigests : nil,
                computeNodeAppData: appData,
                hardwareID: self.nodeInfo.testOnlyHardwareID
            ), ourReleaseDigest, appData, nil, nil)
        }

        let transparencyProofsEnabled = self.configuration.cloudAttestation.includeTransparencyLogInclusionProof
        if transparencyProofsEnabled {
            Self.logger.log("CloudAttestation transparency proof inclusion enabled")
        } else {
            Self.logger.warning("CloudAttestation transparency proof inclusion disabled")
        }

        let attestationBundle: AttestationBundle
        let attestor: Attestor
        if self.configuration.isProxy {
            let enableTransitiveProofVerification = self.configuration.secureConfig.enableTransitiveProofVerification
            if enableTransitiveProofVerification {
                Self.logger.log("Generating proxy attestation with transitive proof verification")
                if transparencyProofsEnabled {
                    attestor = PCC.ProxyNodeAttestor()
                } else {
                    attestor = PCC.ProxyNodeAttestor(transparencyProver: NopTransparencyLog())
                }
            } else {
                Self.logger.log(
                    "Generating proxy attestation with proxied release digests: \(releaseDigests, privacy: .public)"
                )
                if transparencyProofsEnabled {
                    attestor = PCC.ProxyNodeAttestor(
                        proxiedReleases: releaseDigests.compactMap { Data(hexString: $0) }
                    )
                } else {
                    attestor = PCC.ProxyNodeAttestor(
                        proxiedReleases: releaseDigests.compactMap { Data(hexString: $0) },
                        transparencyProver: NopTransparencyLog()
                    )
                }
            }
            attestationBundle = try await attestor.attest(key: privateKey, expiration: expiry)
        } else {
            Self.logger.log("Using regular node attestor")
            if transparencyProofsEnabled {
                attestor = NodeAttestor()
            } else {
                attestor = NodeAttestor(transparencyProver: NopTransparencyLog())
            }

            // We use the empty appData slot on the compute node to stick node metadata. The appData slot on the proxy
            // node contains the proxied release digests which is entirely controlled by the CloudAttestation code.
            let appDataProto = try Proto_AppData.with {
                $0.domain = "com.apple.PrivateCloudCompute"
                $0.name = "Compute Node"
                $0.version = 1
                $0.metadata = try .init(
                    message: AttestationAppData.with {
                        $0.rackID = appData[ComputeNodeAppDataKeys.rackID] ?? Data()
                        $0.ensembleID = appData[ComputeNodeAppDataKeys.ensembleID] ?? Data()
                        $0.bootID = appData[ComputeNodeAppDataKeys.bootID] ?? Data()
                    }
                )
            }

            attestationBundle = try await attestor.attest(key: privateKey, expiration: expiry, appData: appDataProto)
        }

        let releaseDigest = try Release(bundle: attestationBundle, evaluateTrust: false).sha256
        let attestationBundleJson = try attestationBundle.jsonString()
        Self.logger.debug("Generated key attestation bundle: \(attestationBundleJson, privacy: .public)")

        var transparencyTreeID: UInt64?
        var transparencyRevision: UInt64?
        do {
            if let logRevision = try attestationBundle.transparencyLogRevision {
                transparencyTreeID = logRevision.treeID
                transparencyRevision = logRevision.revision
                Self.logger.log("Attestation bundle transparency log revision: \(logRevision, privacy: .public)")
            }
        } catch {
            Self.logger.warning("Failed to extract transparency log revision: \(error, privacy: .public)")
        }

        return try (
            attestationBundle.serializedData(),
            releaseDigest,
            appData,
            transparencyTreeID,
            transparencyRevision
        )
    }

    /// Parses out the proxied release digests from the bundle
    /// If not present this returns an empty array
    internal static func parseProxiedReleaseDigests(
        attestationBundle: Data
    ) throws -> [String] {
        var proxiedReleaseDigests: [String] = []
        do {
            let protoBundle = try Proto_AttestationBundle(serializedBytes: attestationBundle)
            let protoAppData = try Proto_AppData(serializedBytes: protoBundle.appData)
            guard protoAppData.hasMetadata, protoAppData.name == "Proxy Node" else {
                return []
            }
            proxiedReleaseDigests = try PrivateCloudCompute_ProxyNodeMetadata(unpackingAny: protoAppData.metadata)
                .proxiedRelease.map { $0.digest.hexString }
        } catch {
            Self.logger.error("Failed to parse attestation proxied release digests: \(error, privacy: .public)")
        }
        return proxiedReleaseDigests
    }

    func restoreKeysFromDisk(
        attestationCache: AttestationBundleCache,
        keyExpiryGracePeriod: TimeInterval
    ) async -> [InternalAttestedKey] {
        var keyIdToBundleMap: [Data: Data] = [:]
        let _ = await attestationCache.read().entries.map { entry in
            Self.logger.info("Got entry from cache. KeyId: \(entry.key.base64EncodedString(), privacy: .public)")
            keyIdToBundleMap[entry.key] = entry.value
        }
        var attestedKeys: [InternalAttestedKey] = []
        do {
            let keys = try Keychain.findKeys(for: Keychain.baseNodeKeyQuery, keychain: self.keychain)
            Self.logger.log("Found \(keys.count, privacy: .public) existing key(s)")

            for key in keys {
                let (secKey, keyID) = key
                // if keyID exists in the cache, and the cached bundle is not corrupted
                if let cachedAttestationBundle = keyIdToBundleMap[keyID],
                   Data(SHA256.hash(data: cachedAttestationBundle)) == keyID {
                    do {
                        let protoBundle = try Proto_AttestationBundle(serializedBytes: cachedAttestationBundle)
                        let keyExpiry = protoBundle.keyExpiration.date
                        if keyExpiry > .now {
                            let protoAppData = try Proto_AppData(serializedBytes: protoBundle.appData)
                            let proxiedReleaseDigests: [String] = if self.configuration.isProxy,
                                                                     protoAppData.hasMetadata {
                                try PrivateCloudCompute_ProxyNodeMetadata(unpackingAny: protoAppData.metadata)
                                    .proxiedRelease.map { $0.digest.hexString }
                            } else { [] }
                            var appData: [String: Data] = [:]
                            if !self.configuration.isProxy {
                                let metadata = try AttestationAppData(unpackingAny: protoAppData.metadata)
                                appData[ComputeNodeAppDataKeys.rackID] = metadata.rackID
                                appData[ComputeNodeAppDataKeys.bootID] = metadata.bootID
                                appData[ComputeNodeAppDataKeys.ensembleID] = metadata.ensembleID
                            }

                            let cloudAttestationBundle = try AttestationBundle(data: cachedAttestationBundle)

                            var transparencyTreeID: UInt64?
                            var transparencyRevision: UInt64?
                            do {
                                if let logRevision = try cloudAttestationBundle.transparencyLogRevision {
                                    transparencyTreeID = logRevision.treeID
                                    transparencyRevision = logRevision.revision
                                }
                            } catch {
                                Self.logger.warning(
                                    "Failed to extract transparency log revision from restored bundle: \(String(unredacted: error), privacy: .public)"
                                )
                            }

                            try attestedKeys.append(.init(
                                key: .sepKey(secKey: secKey),
                                attestationBundle: cachedAttestationBundle,
                                releaseDigest: Release(
                                    bundle: cloudAttestationBundle,
                                    evaluateTrust: false
                                )
                                .sha256,
                                proxiedReleaseDigests: proxiedReleaseDigests,
                                expiry: keyExpiry + keyExpiryGracePeriod,
                                appData: appData,
                                availableOnNodeOnly: false,
                                transparencyTreeID: transparencyTreeID,
                                transparencyRevision: transparencyRevision
                            ))
                        } else {
                            Self.logger.log("Removing expired key from cache. keyID: \(keyID, privacy: .public)")
                            await self.removeKey(attestationCache: attestationCache, keyID: keyID, secKey: secKey)
                        }
                    } catch {
                        Self.logger.error(
                            "Could not parse cached attestation bundle, keyId: \(keyID, privacy: .public). Removing from cache."
                        )
                        await attestationCache.remove(keyId: keyID)
                    }

                } else {
                    await self.removeKey(attestationCache: attestationCache, keyID: keyID, secKey: secKey)
                }
            }
            attestedKeys.sort { $0.expiry < $1.expiry }
        } catch {
            Self.logger.error(
                "Failed to query for existing keys: \(String(unredacted: error), privacy: .public)"
            )
        }
        return attestedKeys
    }

    private func removeKey(attestationCache: AttestationBundleCache, keyID: Data, secKey: SecKey) async {
        let keyAttributes = SecKeyCopyAttributes(secKey)
        do {
            try Keychain.delete(key: secKey, keychain: self.keychain)
            Self.logger.log("Successfully deleted key: \(keyAttributes, privacy: .public)")
        } catch {
            Self.logger.error(
                "Failed to delete key with attributes \(keyAttributes, privacy: .public): \(String(unredacted: error), privacy: .public)"
            )
        }
        await attestationCache.remove(keyId: keyID)
    }
}

extension Data {
    fileprivate init?(hexString: String) {
        var prefixLength = 0
        if hexString.hasPrefix("0x") {
            prefixLength = 2
        }
        let len = (hexString.count - prefixLength) / 2
        var data = Data(capacity: len)
        var i = hexString.index(hexString.startIndex, offsetBy: prefixLength)
        for _ in 0 ..< len {
            let j = hexString.index(i, offsetBy: 2)
            let bytes = hexString[i ..< j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}

extension CloudAttestation.CloudAttestationError: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .unexpected: "unexpected"
        case .attestError(let error): "attestError(\(String(reportable: error)))"
        case .validateError(let error): "validateError(\(String(reportable: error)))"
        case .invalidNonce: "invalidNonce"
        case .expired(expiration: let expiration): "expired(\(expiration))"
        case .emptyCertificateChain: "emptyCertificateChain"
        case .malformedSecureConfig: "malformedSecureConfig"
        case .missingAttestingKey: "missingAttestingKey"
        case .missingSealedHash(slot: let slot): "missingSealedHash(\(slot))"
        case .untrustedAppData: "untrustedAppData"
        @unknown default: "unknown"
        }
        return "cloudAttestation.\(errorType)"
    }
}

extension CloudAttestation.NodeAttestor.Error: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .dcikCreationFailure: "dcikCreationFailure"
        case .malformedSecureConfig: "malformedSecureConfig"
        case .emptyCertificateChain: "emptyCertificateChain"
        case .missingCryptexes: "missingCryptexes"
        case .missingSecureConfig: "missingSecureConfig"
        case .unexpectedCryptexPDI: "unexpectedCryptexPDI"
        case .pendingTransparencyExpiry(
            proofsExpiration: let proofsExpiration, keyExpiration: let keyExpiration
        ): "pendingTransparencyExpiry(proofsExpiration: \(proofsExpiration), keyExpiration: \(keyExpiration))"
        case .nonceProvided: "nonceProvided"
        @unknown default: "unknown"
        }
        return "nodeAttestor.\(errorType)"
    }
}

extension CloudAttestation.TransparencyLogError: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .httpError(statusCode: let statusCode): "httpError(statusCode: \(statusCode))"
        case .internalError: "internalError"
        case .mutationPending: "mutationPending"
        case .invalidRequest: "invalidRequest"
        case .notFound: "notFound"
        case .invalidProof: "invalidProof"
        case .insertFailed: "insertFailed"
        case .unknownStatus: "unknownStatus"
        case .unrecognized(status: let status): "unrecognized(status: \(status))"
        case .unknown(error: let error): "unknown(\(String(reportable: error)))"
        case .clientError(error: let error): "clientError(\(String(reportable: error)))"
        case .expired: "expired"
        case .pendingExpiration: "pendingExpiration"
        case .requestLimitExceeded: "requestLimitExceeded"
        @unknown default: "unknown"
        }
        return "cloudAttestation.transparencyLog.\(errorType)"
    }
}

extension CloudAttestation.X509Policy.Error: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .untrusted(cause: let cause): "untrusted(cause: \(cause))"
        case .emptyCertificateChain: "emptyCertificateChain"
        case .malformedCertificateChain: "malformedCertificateChain"
        case .unsupportedPublicKey: "unsupportedPublicKey"
        case .internalSecError(status: let status): "internalSecError(status: \(status))"
        case .invalidRevocationPolicy: "invalidRevocationPolicy"
        case .policyCreationFailure: "policyCreationFailure"
        @unknown default: "X509Policy unknown error"
        }
        return "cloudAttestation.\(errorType)"
    }
}

extension CloudAttestation.KeyOptionsPolicy.Error: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .missingKeyOptions: "missingKeyOptions"
        // Due to there being two untrusted cases we cannot distinguish them, so they are included here.
        @unknown default: "KeyOptionsPolicy unknown error"
        }
        return "cloudAttestation.\(errorType)"
    }
}

extension CloudAttestation.APTicketPolicy.Error: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .missingDigest: "missingDigest"
        case .missingAttestation: "missingAttestation"
        case .untrusted: "untrusted"
        @unknown default: "APTicketPolicy unknown error"
        }
        return "cloudAttestation.\(errorType)"
    }
}

extension CloudAttestation.TransparencyPolicy.Error: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .malformedRelease(error: let error): "malformedRelease(error: \(String(reportable: error)))"
        case .missingProofs: "missingProofs"
        case .notIncluded: "notIncluded"
        case .expired: "expired"
        case .unknown(error: let error): "unknown(error: \(String(reportable: error)))"
        @unknown default: "TransparencyPolicy unknown error"
        }
        return "cloudAttestation.\(errorType)"
    }
}

extension CloudAttestation.RoutingHintPolicy.Error: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .missingDarwinInit: "missingDarwinInit"
        case .missingRoutingHint: "missingRoutingHint"
        @unknown default: "RoutingHintPolicy unknown error"
        }
        return "cloudAttestation.\(errorType)"
    }
}

extension CloudAttestation.CryptexPolicy.Error: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .missingCryptexSealedHash: "missingCryptexSealedHash"
        case .missingCryptexLedger(
            uuid: let uuid,
            value: let value
        ): "missingCryptexLedger(uuid: \(uuid), value: \(value))"
        case .inconsistentLockState(
            secureConfigLocked: let secureConfigLocked,
            sealedHashLocked: let sealedHashLocked
        ): "inconsistentLockState(secureConfigLocked: \(secureConfigLocked), sealedHashLocked: \(sealedHashLocked))"
        case .unlocked(
            secureConfigLocked: let secureConfigLocked,
            sealedHashLocked: let sealedHashLocked
        ): "unlocked(secureConfigLocked: \(secureConfigLocked), sealedHashLocked: \(sealedHashLocked))"
        case .replayMismatch(
            replayed: let replayed,
            expected: let expected
        ): "replayMismatch(replayed: \(replayed), expected: \(expected))"
        case .replayFailure(let error): "replayFailure(error: \(String(reportable: error)))"
        case .missingCryptexMeasurementFlag: "missingCryptexMeasurementFlag"
        @unknown default: "CryptexPolicy unknown error"
        }
        return "cloudAttestation.\(errorType)"
    }
}

extension CloudAttestation.SecureConfigPolicy.Error: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .missingSecureConfig: "missingSecureConfig"
        case .missingSealedHash: "missingSealedHash"
        case .untrusted(
            replayed: let replayed,
            expeced: let expeced
        ): "untrusted(replayed: \(replayed), expeced: \(expeced))"
        case .replayMismatch(
            replayed: let replayed,
            expected: let expected
        ): "replayMismatch(replayed: \(replayed), expected: \(expected))"
        case .replayFailure(let error): "replayFailure(error: \(String(reportable: error)))"
        @unknown default: "SecureConfigPolicy unknown error"
        }
        return "cloudAttestation.\(errorType)"
    }
}

extension CloudAttestation.SEPAttestationPolicy.Error: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        let errorType = switch self {
        case .missingSigningKey: "missingSigningKey"
        case .untrusted: "untrusted"
        case .unknown(underlying: let underlyingError): "unknown(\(String(reportable: underlyingError)))"
        case .invalidIdentity: "invalidIdentity"
        @unknown default: "SEPAttestationPolicy unknown error"
        }
        return "cloudAttestation.\(errorType)"
    }
}

// CloudAttestation in some cases wraps NSErrors
//
// We should wrap these errors and throw more meaningful errors when we can but this serves as a fallback to provide at
// least some additional context.
extension NSError: CloudBoardLogging.ReportableError {
    public var publicDescription: String {
        return "nsError.domain: \(self.domain), code: \(self.code)"
    }
}
