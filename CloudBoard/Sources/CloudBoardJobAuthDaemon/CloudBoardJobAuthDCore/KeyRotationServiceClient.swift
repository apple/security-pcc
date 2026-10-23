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
import Synchronization

enum KeyRotationServiceClientError: ReportableError {
    enum AssetType: String, RawRepresentable {
        case keyPair
        case transparencyEntry
        case transparencyProof
    }

    case grpc(GRPCStatus)
    case unexpectedAssetType(AssetType)
    case applicationError(AssetError)
    case unexpectedResponse
    case spkiParsingFailedBadFormat
    case spkiExpiredKey
    case noValidKeysFound

    public var publicDescription: String {
        let errorType = switch self {
        case .grpc(let status): "grpc(status: \(status.code))"
        case .unexpectedAssetType(let assetType): "unexpectedAssetType(\(assetType))"
        case .applicationError(let error): "applicationError(code: \(error.errorCode))"
        case .unexpectedResponse: "unexpectedResponse"
        case .spkiParsingFailedBadFormat: "spkiParsingFailedBadFormat"
        case .spkiExpiredKey: "spkiExpiredKey"
        case .noValidKeysFound: "noValidKeysFound"
        }
        return "keyRotationService.\(errorType)"
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

final class KeyRotationServiceClient: SigningKeyProvider {
    public static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cb_jobauthd",
        category: "KeyRotationServiceClient"
    )

    enum SigningKeyUseCase: String, RawRepresentable {
        case costToken = "pcc_cost_token"

        var metricValue: String {
            switch self {
            case .costToken: "cost_token"
            }
        }
    }

    private let client: AssetDeliveryAsyncClientProtocol
    private let config: CloudBoardJobAuthDConfiguration.KeyRotationService
    private let metrics: any MetricsSystem
    private let costTokenKeyWatchers: Mutex<[CostTokenSigningKeyUpdateWatcher]> = .init([])
    private let costTokenKeyStateMachine: Mutex<KeyRotationServiceStateMachine<CostTokenSigningKeyPair>> =
        .init(.init())

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
        try await self.runSigningKeysRefreshLoop()
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

    deinit {
        self.costTokenKeyStateMachine.withLock { stateMachine in
            stateMachine.cancel()
        }
    }

    func fetchAllSigningKeys() async throws {
        Self.logger.log("Fetching cost token signing key")
        try await self.fetchCostTokenSigningKey()
    }

    /// Public API, invoked by CloudBoardJobAuthServer
    public func requestCostTokenSigningKey() async throws -> CostTokenSigningKeyPair {
        try await self.obtainCostTokenSigningKey()
    }

    func registerForCostTokenKeyUpdates(watcher: CostTokenSigningKeyUpdateWatcher) {
        self.costTokenKeyWatchers.withLock {
            $0.append(watcher)
        }
    }

    private func obtainCostTokenSigningKey() async throws -> CostTokenSigningKeyPair {
        let action = try self.costTokenKeyStateMachine.withLock { try $0.obtainSigningKeys() }
        switch action {
        case .continueWithSigningKeys(let key): return key
        case .waitForSigningKeys(let future):
            return try await future.valueWithCancellation
        }
    }

    internal func fetchCostTokenSigningKey() async throws {
        return try await self.metrics.withStatusMetrics(
            total: Metrics.KeyRotationService.KeyRotationServiceFetchCounter(
                action: .increment(by: 1),
                dimensions: [.keyType: SigningKeyUseCase.costToken.metricValue]
            ),
            error: Metrics.KeyRotationService.KeyRotationServiceFetchErrorCounter.Factory(
                dimensions: [.keyType: SigningKeyUseCase.costToken.metricValue]
            ),
            timer: Metrics.KeyRotationService.KeyRotationServiceFetchDurationHistogram.Factory(
                dimensions: [.keyType: SigningKeyUseCase.costToken.metricValue]
            )
        ) {
            let request: AssetRequest = .with {
                $0.assetType = .keyPair
                $0.useCase = SigningKeyUseCase.costToken.rawValue
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
                    let costTokenKey = try self.parseCostTokenSigningKey(assets: assets, requestId: requestId)
                    let updateAction = self.costTokenKeyStateMachine.withLock { stateMachine in
                        stateMachine.updateSigningKeys(keySet: costTokenKey)
                    }
                    switch updateAction {
                    case .noAction:
                        Self.logger.log("Cost token signing key unchanged, not broadcasting update")
                    case .updateWatchers:
                        Self.logger.log("Broadcasting changed cost token signing key")
                        let watchers = self.costTokenKeyWatchers.withLock { $0 }
                        for watcher in watchers {
                            do {
                                try await watcher.costTokenKeyUpdated(newKey: costTokenKey)
                            } catch {
                                Self.logger
                                    .error(
                                        "Failed to update cost token key watcher: \(String(reportable: error), privacy: .public)"
                                    )
                            }
                        }
                    }
                case .none:
                    throw KeyRotationServiceClientError.unexpectedResponse
                }
            } catch {
                Self.logger.error("""
                message=\("Failed to fetch cost token private key from KRS", privacy: .public)
                request_id=\(requestId, privacy: .public)
                useCase=\(SigningKeyUseCase.costToken.metricValue, privacy: .public)
                error=\(error, privacy: .public)
                """)
                throw error
            }
        }
    }

    private func parseCostTokenSigningKey(
        assets: Assets,
        requestId: String
    ) throws -> CostTokenSigningKeyPair {
        // KRS returns multiple keys including future keys (based on hoursInAdvance config)
        // Select the key with the most recent validStart that is currently active (validStart <= now <= validEnd)
        let selectedKey = assets.assetBundle
            .compactMap { bundle -> (bundle: AssetBundle, keyPair: KeyPairAsset, validStart: Date, validEnd: Date)? in
                guard let asset = bundle.asset,
                      case .keyPair(let keyPair) = asset else {
                    return nil
                }
                return (
                    bundle,
                    keyPair,
                    bundle.assetValidStartTimestamp.date,
                    bundle.assetValidEndTimestamp.date
                )
            }
            .filter { $0.validStart <= Date.now && Date.now <= $0.validEnd } // Active and not expired
            .max(by: { $0.validStart < $1.validStart }) // Select most recent

        guard let selectedKey else {
            Self.logger.error("""
            message=\("No valid cost token keys found in KRS response", privacy: .public)
            request_id=\(requestId, privacy: .public)
            totalKeysInResponse=\(assets.assetBundle.count, privacy: .public)
            """)
            throw KeyRotationServiceClientError.noValidKeysFound
        }

        let costTokenKey = CostTokenSigningKeyPair(
            keyId: Data(SHA256.hash(data: selectedKey.keyPair.publicKey)),
            privateKey: selectedKey.keyPair.privateKey,
            publicKey: selectedKey.keyPair.publicKey,
            validStart: selectedKey.validStart,
            validEnd: selectedKey.validEnd
        )

        Self.logger.notice("""
        message=\("Successfully fetched and selected cost token signing key", privacy: .public)
        request_id=\(requestId, privacy: .public)
        useCase=\(SigningKeyUseCase.costToken.metricValue, privacy: .public)
        selectedKeyValidStart=\(selectedKey.validStart, privacy: .public)
        selectedKeyValidEnd=\(selectedKey.validEnd, privacy: .public)
        totalKeysInResponse=\(assets.assetBundle.count, privacy: .public)
        keyId=\(costTokenKey.keyId.base64EncodedString(), privacy: .public)
        truncatedKeyId=\(Int8(bitPattern: costTokenKey.keyId.last!), privacy: .public)
        """)

        return costTokenKey
    }
}

private struct KeyRotationServiceStateMachine<T: Equatable & Sendable> {
    enum State: CustomStringConvertible {
        case initialized
        case awaitingSigningKeys(Promise<T, Error>)
        case signingKeysAvailable(keySet: T)

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

    enum ObtainSigningKeysAction {
        case waitForSigningKeys(Future<T, Error>)
        case continueWithSigningKeys(T)
    }

    mutating func obtainSigningKeys() throws -> ObtainSigningKeysAction {
        switch self.state {
        case .initialized:
            let promise = Promise<T, Error>()
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

    mutating func updateSigningKeys(keySet: T) -> UpdateSigningKeysAction {
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
