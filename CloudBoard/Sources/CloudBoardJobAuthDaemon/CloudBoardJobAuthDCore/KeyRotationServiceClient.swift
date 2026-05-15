// Copyright © 2025 Apple Inc. All Rights Reserved.

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
import CloudBoardJobAuthDAPI
import CloudBoardLogging
import CloudBoardMetrics
import CryptoKit
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import InternalSwiftProtobuf
import Logging
import NIOCore
import NIOHTTP2
import NIOTransportServices
import os
import SwiftASN1

enum KeyRotationServiceClientError: ReportableError {
    enum AssetType: String, RawRepresentable {
        case keyPair
        case transparencyEntry
        case transparencyProof
    }

    case grpc(GRPCStatus)
    case unexpectedAssetType(AssetType)
    case applicationError(Error)
    case unexpectedResponse
    case spkiParsingFailedBadFormat
    case spkiExpiredKey

    public var publicDescription: String {
        let errorType = switch self {
        case .grpc(let status): "grpc(status: \(status.code))"
        case .unexpectedAssetType(let assetType): "unexpectedAssetType(\(assetType))"
        case .applicationError(let error): "applicationError(code: \(error.errorCode))"
        case .unexpectedResponse: "unexpectedResponse"
        case .spkiParsingFailedBadFormat: "spkiParsingFailedBadFormat"
        case .spkiExpiredKey: "spkiExpiredKey"
        }
        return "keyRotationService.\(errorType)"
    }
}

extension SigningKey {
    public init(derEncodedSPKI: Data, validStart: Date, validEnd: Date) throws {
        let derPublicKey: ASN1Node
        do {
            derPublicKey = try DER.parse([UInt8](derEncodedSPKI))
        } catch {
            KeyRotationServiceClient.logger.error("Failed to parse DER of the provided key: \(error, privacy: .public)")
            throw error
        }
        let spki: SubjectPublicKeyInfo
        do {
            spki = try SubjectPublicKeyInfo(derEncoded: derPublicKey)
            guard spki.algorithmIdentifier.algorithm == ASN1ObjectIdentifier.AlgorithmIdentifier.rsassaPSS else {
                throw KeyRotationServiceClientError.spkiParsingFailedBadFormat
            }
        } catch {
            KeyRotationServiceClient.logger
                .error("Failed to parse SPKI of the provided key: \(error, privacy: .public)")
            throw error
        }
        // validates that we can construct SecKey from this representation
        let rsaPublicKeyData = Data(spki.key.bytes)
        do {
            _ = try SecKey.fromDEREncodedRSAPublicKey(rsaPublicKeyData)
        } catch {
            KeyRotationServiceClient.logger
                .error("Cannot create SecKey from decoded RSA public key: \(error, privacy: .public)")
            throw error
        }
        self.init(
            keyId: Data(SHA256.hash(data: derEncodedSPKI)),
            rsaPublicKey: rsaPublicKeyData,
            validStart: validStart,
            validEnd: validEnd
        )
    }
}

extension SecKey {
    fileprivate static func fromDEREncodedRSAPublicKey(_ derEncodedRSAPublicKey: Data) throws -> SecKey {
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(derEncodedRSAPublicKey as CFData, keyAttributes as CFDictionary, &error)

        guard let key else {
            // If this returns nil, error must be set.
            throw error!.takeRetainedValue()
        }

        return key
    }
}

final class KeyRotationServiceClient: AuthTokenSigningKeyProvider {
    public static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cb_jobauthd",
        category: "KeyRotationServiceClient"
    )

    private static let metricsRecordingInterval: Duration = .seconds(60)

    enum SigningKeyUseCase: String, RawRepresentable {
        case ott = "thimble_ott"
        case tgt = "thimble_tgt"

        var metricValue: String {
            switch self {
            case .ott: "ott"
            case .tgt: "tgt"
            }
        }
    }

    private let client: AssetDeliveryAsyncClientProtocol
    private let config: CloudBoardJobAuthDConfiguration.KeyRotationService
    private let metrics: any MetricsSystem
    private let watchers: OSAllocatedUnfairLock<[AuthTokenSigningKeyUpdateWatcher]> = .init(initialState: [])
    private let stateMachine: OSAllocatedUnfairLock<KeyRotationServiceStateMachine> = .init(initialState: .init())

    init(
        eventLoopGroup: NIOTSEventLoopGroup,
        config: CloudBoardJobAuthDConfiguration.KeyRotationService,
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        metrics: any MetricsSystem
    ) throws {
        Self.logger.log("""
        message=\("Preparing key rotation service client", privacy: .public)
        target=\(config.targetHost + ":" + String(config.targetPort), privacy: .public)
        TLS=\(String(describing: config.tlsConfig), privacy: .public)
        """)
        self.config = config
        let backoffConfig = config.backoffConfig
        let channel = try GRPCChannelPool.with(
            target: .hostAndPort(config.targetHost, config.targetPort),
            transportSecurity: .init(.init(config.tlsConfig, identityCallback: identityCallback)),
            eventLoopGroup: eventLoopGroup
        ) { config in
            // set a short idle timeout as requested by KRS team,
            // essentially to avoid tying up connections in between requests
            config.idleTimeout = .seconds(5)
            config.backgroundActivityLogger = Logging.Logger(
                osLogSubsystem: "com.apple.cloudos.cb_jobauthd",
                osLogCategory: "KeyRotationServiceClient",
                domain: "KeyRotationServiceClient_BackgroundActivity"
            )
            config.connectionBackoff = .init(from: backoffConfig)
        }
        let logger = Logging.Logger(
            osLogSubsystem: "com.apple.cloudos.cb_jobauthd",
            osLogCategory: "KeyRotationServiceClient",
            domain: "GRPC"
        )
        self.client = AssetDeliveryAsyncClient(channel: channel, defaultCallOptions: CallOptions(logger: logger))
        self.metrics = metrics
    }

    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask { try await self.runSigningKeysRefreshLoop() }
            taskGroup.addTask { await self.runMetricsRecordingLoop() }
            try await taskGroup.next()
        }
    }

    private func runSigningKeysRefreshLoop() async throws {
        while true {
            do {
                try await self.fetchAllSigningKeys()
                Self.logger.log("""
                message=\("Signing keys updated", privacy: .public)
                """)
            } catch {
                Self.logger.error("""
                message=\("Fetching signing keys failed", privacy: .public)
                error=\(error, privacy: .public))
                """)
            }

            let jitter = Double.random(in: (0 - self.config.jitter) ... self.config.jitter) / 100
            let sleepTime = self.config.pollPeriod * (1.0 + jitter)
            Self.logger.log("""
            message=\("Sleeping for key refresh interval", privacy: .public)
            interval=\(sleepTime.components.seconds, privacy: .public)
            """)
            try await Task.sleep(for: self.config.pollPeriod)
        }
    }

    private func runMetricsRecordingLoop() async {
        while true {
            do {
                try await Task.sleep(for: Self.metricsRecordingInterval)
            } catch {
                Self.logger.log("Metrics recording task cancelled")
                return
            }
            let signingKeys: AuthTokenKeySet
            do {
                signingKeys = try await self.obtainSigningKeys()
            } catch {
                Self.logger.error("""
                message=\("Obtaining signing keys failed", privacy: .public)
                error=\(error, privacy: .public))
                """)
                continue
            }
            self.emitSigningKeysTimeToExpiry(signingKeys: signingKeys)
            Self.logger.debug("Emitted signing keys time to expiry metrics")
        }
    }

    deinit {
        self.stateMachine.withLock { stateMachine in
            stateMachine.cancel()
        }
    }

    func fetchAllSigningKeys() async throws {
        Self.logger.log("Fetching OTT signing keys")
        let ottSigningKeys = try await fetchSigningKeys(.ott)
        if ottSigningKeys.isEmpty {
            Self.logger.error("No OTT signing keys fetched")
        }
        Self.logger.log("Fetching TGT signing keys")
        let tgtSigningKeys = try await fetchSigningKeys(.tgt)
        if tgtSigningKeys.isEmpty {
            Self.logger.error("No TGT signing keys fetched")
        }

        let newSigningKeySet = AuthTokenKeySet(
            ottPublicSigningKeys: ottSigningKeys,
            tgtPublicSigningKeys: tgtSigningKeys
        )
        let updateAction = self.stateMachine.withLock { stateMachine in
            stateMachine.updateSigningKeys(keySet: newSigningKeySet)
        }
        switch updateAction {
        case .noAction:
            Self.logger.log("Signing keys unchanged, not broadcasting update")
        case .updateWatchers:
            Self.logger.log("Broadcasting changed set of signing keys")
            let watchers = self.watchers.withLock { $0 }
            for watcher in watchers {
                do {
                    try await watcher.authTokenKeysUpdated(newKeySet: newSigningKeySet)
                } catch {
                    Self.logger
                        .error("Failed to update signing key watcher: \(String(reportable: error), privacy: .public)")
                }
            }
        }
    }

    internal func fetchSigningKeys(_ useCase: SigningKeyUseCase) async throws -> [SigningKey] {
        return try await self.metrics.withStatusMetrics(
            total: Metrics.KeyRotationService.KeyRotationServiceFetchCounter(
                action: .increment(by: 1),
                dimensions: [.keyType: useCase.metricValue]
            ),
            error: Metrics.KeyRotationService.KeyRotationServiceFetchErrorCounter.Factory(
                dimensions: [.keyType: useCase.metricValue]
            ),
            timer: Metrics.KeyRotationService.KeyRotationServiceFetchDurationHistogram.Factory(
                dimensions: [.keyType: useCase.metricValue]
            )
        ) {
            let request: AssetRequest = .with {
                $0.assetType = .publicKey
                $0.useCase = useCase.rawValue
            }
            var callOptions = CallOptions()
            callOptions.requestIDHeader = "X-Apple-Request-UUID"
            let requestId = UUID().uuidString
            callOptions.requestIDProvider = .userDefined(requestId)

            let fetchDeliveryCall = self.client.makeFetchDeliveryCall(request, callOptions: callOptions)
            let status = await fetchDeliveryCall.status
            do {
                guard status.isOk else {
                    throw KeyRotationServiceClientError.grpc(status)
                }
                let response = try await fetchDeliveryCall.response
                switch response.result {
                case .error(let error):
                    throw KeyRotationServiceClientError.applicationError(error)
                case .assets(let assets):
                    return try self.parseSigningKeys(useCase: useCase, assets: assets, requestId: requestId)
                case .none:
                    throw KeyRotationServiceClientError.unexpectedResponse
                }
            } catch {
                Self.logger.error("""
                message=\("Failed to fetch public keys from KRS", privacy: .public)
                request_id=\(requestId, privacy: .public)
                useCase=\(useCase.metricValue, privacy: .public)
                error=\(error, privacy: .public)
                """)
                throw error
            }
        }
    }

    private func parseSigningKeys(
        useCase: SigningKeyUseCase,
        assets: Assets,
        requestId: String
    ) throws -> [SigningKey] {
        var keys = [SigningKey]()
        for assetBundle in assets.assetBundle {
            do {
                if let asset = assetBundle.asset {
                    let spkiData: Data = switch asset {
                    case .keyPair(let keypair): keypair.publicKey
                    case .publicKey(let publicKey): publicKey.publicKey
                    }
                    // validate the asset bundle is not expired (cb_jobhelper instances can be prewarmed, so it is too
                    // soon to check for future valid start dates here)
                    guard Date.now < assetBundle.assetValidEndTimestamp.date + self.config
                        .signingKeysGracePeriodSeconds else {
                        throw KeyRotationServiceClientError.spkiExpiredKey
                    }
                    let signingKey = try SigningKey(
                        derEncodedSPKI: spkiData,
                        validStart: assetBundle.assetValidStartTimestamp.date,
                        validEnd: assetBundle.assetValidEndTimestamp
                            .date + self.config.signingKeysGracePeriodSeconds
                    )
                    keys.append(signingKey)
                    Self.logger.log("""
                    message=\("Successfully fetched public key from KRS", privacy: .public)
                    request_id=\(requestId, privacy: .public)
                    useCase=\(useCase.metricValue, privacy: .public)
                    keyId=\(signingKey.keyId.base64EncodedString(), privacy: .public)
                    truncatedKeyId=\(Int8(bitPattern: signingKey.keyId.last!), privacy: .public)
                    publicKey=\(signingKey.rsaPublicKey.base64EncodedString(), privacy: .public)
                    validStart=\(signingKey.validStart, privacy: .public)
                    validEnd=\(signingKey.validEnd, privacy: .public)
                    """)
                } else {
                    Self.logger.error("""
                    message=\("Could not decode asset bundle asset", privacy: .public)
                    request_id=\(requestId, privacy: .public)
                    useCase=\(useCase.metricValue, privacy: .public)
                    assetbundle=\(assetBundle.debugDescription, privacy: .public)
                    """)
                }
            } catch KeyRotationServiceClientError.spkiExpiredKey {
                Self.logger.error("""
                message=\("Expired asset key, skipping", privacy: .public)
                request_id=\(requestId, privacy: .public)
                useCase=\(useCase.metricValue, privacy: .public)
                assetbundle=\(assetBundle.debugDescription, privacy: .public)
                assetValidStart=\(assetBundle.assetValidStartTimestamp.date, privacy: .public)
                assetValidEnd=\(assetBundle.assetValidEndTimestamp.date, privacy: .public)
                """)
            } catch {
                Self.logger.error("""
                message=\("Failed to parse asset key, skipping", privacy: .public)
                request_id=\(requestId, privacy: .public)
                useCase=\(useCase.metricValue, privacy: .public)
                assetbundle=\(assetBundle.debugDescription, privacy: .public)
                error=\(error, privacy: .public)
                """)
            }
        }
        return keys
    }

    /// Public API, invvoked by CloudBoardJobAuthServer
    public func requestTGTSigningKeys() async throws -> [SigningKey] {
        try await self.obtainSigningKeys().tgtPublicSigningKeys
    }

    /// Public API, invvoked by CloudBoardJobAuthServer
    public func requestOTTSigningKeys() async throws -> [SigningKey] {
        try await self.obtainSigningKeys().ottPublicSigningKeys
    }

    func registerForUpdates(watcher: AuthTokenSigningKeyUpdateWatcher) {
        self.watchers.withLock {
            $0.append(watcher)
        }
    }

    private func obtainSigningKeys() async throws -> AuthTokenKeySet {
        let action = try self.stateMachine.withLock { try $0.obtainSigningKeys() }
        switch action {
        case .continueWithSigningKeys(let keySet): return keySet
        case .waitForSigningKeys(let future):
            return try await future.valueWithCancellation
        }
    }

    private func emitSigningKeysTimeToExpiry(signingKeys: AuthTokenKeySet) {
        self.emitLatestSigningKeyTimeToExpiry(signingKeys: signingKeys.ottPublicSigningKeys, useCase: .ott)
        self.emitLatestSigningKeyTimeToExpiry(signingKeys: signingKeys.tgtPublicSigningKeys, useCase: .tgt)
    }

    private func emitLatestSigningKeyTimeToExpiry(signingKeys: [SigningKey], useCase: SigningKeyUseCase) {
        guard let latestSigningKey = signingKeys.max(by: { $0.validEnd < $1.validEnd }) else {
            return
        }
        let timeToExpiryGauge = Metrics.KeyRotationService.SigningKeyTimeToExpiryGauge(
            keyType: useCase,
            expireAt: latestSigningKey.validEnd
        )
        self.metrics.emit(timeToExpiryGauge)
    }
}

private struct KeyRotationServiceStateMachine {
    enum State: CustomStringConvertible {
        case initialized
        case awaitingSigningKeys(Promise<AuthTokenKeySet, Swift.Error>)
        case signingKeysAvailable(keySet: AuthTokenKeySet)

        var description: String {
            switch self {
            case .initialized:
                return "initialized"
            case .awaitingSigningKeys:
                return "awaitingSigningKeys"
            case .signingKeysAvailable:
                return "signingKeysAvailable"
            }
        }
    }

    private var state: State

    init() {
        self.state = .initialized
    }

    enum ObtainSigningKeyAction {
        case waitForSigningKeys(Future<AuthTokenKeySet, Swift.Error>)
        case continueWithSigningKeys(AuthTokenKeySet)
    }

    mutating func obtainSigningKeys() throws -> ObtainSigningKeyAction {
        switch self.state {
        case .initialized:
            let promise = Promise<AuthTokenKeySet, Swift.Error>()
            self.state = .awaitingSigningKeys(promise)
            return .waitForSigningKeys(Future(promise))
        case .awaitingSigningKeys(let promise):
            return .waitForSigningKeys(Future(promise))
        case .signingKeysAvailable(let keySet):
            return .continueWithSigningKeys(keySet)
        }
    }

    enum UpdateSigningKeysAction {
        case noAction
        case updateWatchers
    }

    mutating func updateSigningKeys(keySet: AuthTokenKeySet) -> UpdateSigningKeysAction {
        switch self.state {
        case .awaitingSigningKeys(let promise):
            promise.succeed(with: keySet)
            self.state = .signingKeysAvailable(keySet: keySet)
            return .noAction
        case .initialized:
            self.state = .signingKeysAvailable(keySet: keySet)
            return .updateWatchers
        case .signingKeysAvailable(let oldKeySet):
            self.state = .signingKeysAvailable(keySet: keySet)
            if keySet == oldKeySet {
                return .noAction
            } else {
                return .updateWatchers
            }
        }
    }

    mutating func cancel() {
        switch self.state {
        case .awaitingSigningKeys(let promise):
            promise.fail(with: CancellationError())
            self.state = .initialized
        case .initialized, .signingKeysAvailable:
            self.state = .initialized
        }
    }
}

extension KeyRotationServiceClient {
    enum TLSConfiguration: CustomStringConvertible {
        case plaintext
        case simpleTLS(SimpleTLS)

        init(
            _ tlsConfig: GRPCClientConfiguration.TLSConfiguration?,
            identityCallback: GRPCTLSConfiguration.IdentityCallback?
        ) {
            if let tlsConfig, tlsConfig.enable {
                self = .simpleTLS(.init(sniOverride: tlsConfig.sniOverride, localIdentityCallback: identityCallback))
            } else {
                self = .plaintext
            }
        }

        var description: String {
            switch self {
            case .plaintext:
                return "TLSConfiguration.plaintext"
            case .simpleTLS:
                return "TLSConfiguration.simpleTLS"
            }
        }
    }
}

extension KeyRotationServiceClient.TLSConfiguration {
    public struct SimpleTLS: CustomStringConvertible {
        var sniOverride: String?
        var localIdentityCallback: GRPCTLSConfiguration.IdentityCallback?

        // Override for setting a custom root cert, used only in testing.
        var customRoot: SecCertificate?

        var description: String {
            "SimpleTLSConfig(sniOverride: \(String(describing: self.sniOverride)))"
        }
    }
}

extension GRPCChannelPool.Configuration.TransportSecurity {
    init(_ tlsMode: KeyRotationServiceClient.TLSConfiguration) {
        switch tlsMode {
        case .plaintext:
            self = .plaintext
        case .simpleTLS(let config):
            self = .tls(
                .grpcTLSConfiguration(
                    hostnameOverride: config.sniOverride,
                    identityCallback: config.localIdentityCallback,
                    customRoot: config.customRoot
                )
            )
        }
    }
}
