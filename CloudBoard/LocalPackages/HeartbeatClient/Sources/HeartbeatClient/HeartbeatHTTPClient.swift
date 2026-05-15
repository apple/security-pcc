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

//  Copyright © 2023 Apple Inc. All rights reserved.

import ClientCore
import Foundation
import HealthClientV1
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import os

/// A concrete implementation of a service protocol that makes HTTP calls to an upstream service.
public struct HeartbeatHTTPClient: Sendable {
    /// The configuration for this service client.
    private let configuration: ServiceConfiguration

    /// Whether to allow sending of the client certificate.
    private let useMTLS: Bool

    /// The client used to make HTTP calls to the metadata service.
    private let healthClient: HealthClientV1.Client

    /// The authentication delegate that provides mTLS credentials.
    private let authDelegate: AuthDelegate

    /// The logger used by this service client.
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "HeartbeatHTTPClient"
    )

    /// The error thrown when a invalid configuration is provided.
    private enum ConfigurationError: Error, LocalizedError, CustomStringConvertible {
        /// An insecure URL was provided, but allowInsecure is false.
        case insecureURL

        var description: String {
            switch self {
            case .insecureURL:
                return "Provided a non-https serviceURL for the heartbeat service."
            }
        }

        var errorDescription: String? {
            self.description
        }
    }

    /// A delegate that handles mTLS and self-signed server certificates.
    private actor AuthDelegate: NSObject, URLSessionDelegate {
        /// Whether to allow self-signed server certificates.
        private let allowSelfSignedCertificates: Bool

        /// The underlying credential provider, which is invoked on every client certificate challenge.
        private var credentialProvider: @Sendable () async -> URLCredential?

        /// Creates a new delegate.
        /// - Parameter allowSelfSignedCertificates: Whether to allow self-signed server certificates.
        init(allowSelfSignedCertificates: Bool) {
            self.allowSelfSignedCertificates = allowSelfSignedCertificates
            self.credentialProvider = { nil }
        }

        /// Updates the current credential provider.
        /// - Parameter provider: The provider closure to be invoked to fetch the credential.
        func updateCredentialProvider(_ provider: @escaping @Sendable () async -> URLCredential?) {
            self.credentialProvider = provider
        }

        func urlSession(
            _: URLSession,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodClientCertificate:
                if let credential = await credentialProvider() {
                    HeartbeatHTTPClient.logger.debug("mTLS credential provided.")
                    return (.useCredential, credential)
                } else {
                    HeartbeatHTTPClient.logger.debug("mTLS credential not provided.")
                    return (.performDefaultHandling, nil)
                }
            case NSURLAuthenticationMethodServerTrust where self.allowSelfSignedCertificates:
                HeartbeatHTTPClient.logger
                    .warning(
                        "Encountered a self-signed certificate and allowSelfSignedCertificates == true, allowing the connection to proceed."
                    )
                guard let trust = challenge.protectionSpace.serverTrust else {
                    return (.performDefaultHandling, nil)
                }
                let credential = URLCredential(trust: trust)
                return (.useCredential, credential)
            default:
                return (.performDefaultHandling, nil)
            }
        }
    }

    /// Initializes a new service client with the given configuration.
    /// - Parameter configuration: The configuration for this service client.
    public init(configuration: ServiceConfiguration) throws {
        self.configuration = configuration
        let serviceURL = configuration.serviceURL
        let isHTTPS = serviceURL.scheme == "https"
        if !isHTTPS, !configuration.allowInsecure {
            Self.logger.error("Provided a non-HTTPS serviceURL and allowInsecure == false, throwing an error.")
            throw ConfigurationError.insecureURL
        }

        let generatedClientConfiguration = OpenAPIRuntime.Configuration(
            dateTranscoder: .iso8601WithFractionalSeconds
        )

        let useMTLS = isHTTPS && !configuration.disableMTLS
        HeartbeatHTTPClient.logger.debug("Will use mTLS: \(useMTLS).")
        self.useMTLS = useMTLS

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlSessionConfiguration.timeoutIntervalForRequest = configuration.httpRequestTimeout

        let authDelegate = AuthDelegate(allowSelfSignedCertificates: configuration.allowInsecure)
        self.authDelegate = authDelegate

        let urlSession = URLSession(
            configuration: urlSessionConfiguration,
            delegate: authDelegate,
            delegateQueue: nil
        )
        let transport = URLSessionTransport(configuration: .init(session: urlSession))
        let middlewares: [any ClientMiddleware] = [
            RequestIdMiddleware(),
            LoggingMiddleware(logger: Self.logger),
            RetryingMiddleware(
                signals: [.code(429), .range(500 ..< 600), .errorThrown],
                policy: .upToAttempts(count: configuration.attemptCount),
                delay: .constant(seconds: configuration.retryDelay)
            ),
        ]
        self.healthClient = .init(
            serverURL: serviceURL,
            configuration: generatedClientConfiguration,
            transport: transport,
            middlewares: middlewares
        )
    }
}

extension HeartbeatHTTPClient {
    /// An error thrown by the client.
    enum ClientError: Swift.Error, CustomStringConvertible, LocalizedError {
        /// The server is overloaded.
        case tooManyRequests

        /// The sent heartbeat was rejected.
        case heartbeatRejected(message: String)

        /// The server encountered an error.
        case serverError(message: String)

        /// Received an undocumented HTTP response status code.
        case undocumentedResponseHTTPCode(Int)

        var errorDescription: String? {
            self.description
        }

        var description: String {
            switch self {
            case .tooManyRequests:
                return "The server is overloaded, try again later."
            case .heartbeatRejected(let message):
                return "The sent heartbeat was rejected by the server with the error: \(message)."
            case .serverError(let message):
                return "The server encountered an error: \(message)."
            case .undocumentedResponseHTTPCode(let code):
                return "Received an undocumented HTTP response status code: \(code)."
            }
        }
    }
}

/// The application or daemon on the sender.
public enum HealthSource: Sendable {
    /// The CloudBoard daemon.
    case cloudboardd
}

/// The type of the sender node.
public enum HealthSenderType: Sendable {
    /// A worker node.
    case node
}

/// A snapshot of the current state of the sender.
public struct Heartbeat: Sendable {
    /// The identifier of the sender.
    public var identifier: String

    /// A Boolean value indicating whether the sender is healthy.
    public var isUp: Bool

    /// The granular status of the sender.
    public var status: Status

    /// The source application or daemon on the sender.
    public var source: HealthSource

    /// The type of the sender node.
    public var senderType: HealthSenderType

    /// The timestamp of the heartbeat.
    public var timestamp: Date

    /// The metadata values sent with the heartbeat.
    public struct Metadata: Sendable {
        /// The cloudOS release type.
        public var cloudOSReleaseType: String?

        /// The cloudOS build version.
        public var cloudOSBuilderVersion: String?

        /// The serverOS release type.
        public var serverOSReleaseType: String?

        /// The serverOS build version.
        public var serverOSBuildVersion: String?

        /// The hot properties version.
        public var configVersion: String?

        /// Whether a workload is enabled.
        public var workloadEnabled: Bool?

        // AdditionalProperties field in CF pref
        public var additionalProperties: [String: String]?

        /// Creates a new metadata value.
        /// - Parameters:
        ///   - cloudOSReleaseType: The cloudOS release type.
        ///   - cloudOSBuilderVersion: The cloudOS build version.
        ///   - serverOSReleaseType: The serverOS release type.
        ///   - serverOSBuildVersion: The serverOS build version.
        ///   - configVersion: The hot properties version.
        ///   - workloadEnabled: Whether a workload is enabled.
        ///   - additionalProperties: AdditionalProperties field in CF pref
        public init(
            cloudOSReleaseType: String? = nil,
            cloudOSBuilderVersion: String? = nil,
            serverOSReleaseType: String? = nil,
            serverOSBuildVersion: String? = nil,
            configVersion: String? = nil,
            workloadEnabled: Bool? = nil,
            additionalProperties: [String: String]? = nil
        ) {
            self.cloudOSReleaseType = cloudOSReleaseType
            self.cloudOSBuilderVersion = cloudOSBuilderVersion
            self.serverOSReleaseType = serverOSReleaseType
            self.serverOSBuildVersion = serverOSBuildVersion
            self.configVersion = configVersion
            self.workloadEnabled = workloadEnabled
            self.additionalProperties = additionalProperties
        }
    }

    /// The metadata values sent with the heartbeat.
    public var metadata: Metadata

    /// Creates a new heartbeat.
    /// - Parameters:
    ///   - identifier: The identifier of the sender.
    ///   - isUp: A Boolean value indicating whether the sender is healthy.
    ///   - status: The granular status of the sender.
    ///   - source: The source application or daemon on the sender.
    ///   - senderType: The type of the sender node.
    ///   - timestamp: The timestamp of the heartbeat.
    ///   - metadata: The metadata values sent with the heartbeat.
    public init(
        identifier: String,
        isUp: Bool,
        status: Status,
        source: HealthSource,
        senderType: HealthSenderType,
        timestamp: Date,
        metadata: Metadata
    ) {
        self.identifier = identifier
        self.isUp = isUp
        self.status = status
        self.source = source
        self.senderType = senderType
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

extension HeartbeatHTTPClient {
    /// Sends the provided heartbeat to the upstream service.
    /// - Parameter heartbeat: The information about the sender.
    public func sendHeartbeat(_ heartbeat: Heartbeat) async throws {
        let mappedSource: Components.Schemas.Source = switch heartbeat.source {
        case .cloudboardd:
            .CLOUDBOARDD
        }
        let mappedAssetType: Components.Schemas.AssetType = switch heartbeat.senderType {
        case .node:
            .NODE
        }
        let metadata = heartbeat.metadata
        let response = try await healthClient.heartbeat(
            path: .init(
                source: mappedSource,
                assetType: mappedAssetType,
                assetId: heartbeat.identifier
            ),
            body: .json(
                .init(
                    timestamp: heartbeat.timestamp,
                    state: heartbeat.isUp ? .UP : .DOWN,
                    operationalStatus: .init(from: heartbeat.status),
                    metadata: .init(
                        cloudOSReleaseType: metadata.cloudOSReleaseType,
                        cloudOSBuilderVersion: metadata.cloudOSBuilderVersion,
                        serverOSReleaseType: metadata.serverOSReleaseType,
                        serverOSBuildVersion: metadata.serverOSBuildVersion,
                        configVersion: metadata.configVersion,
                        workloadEnabled: metadata.workloadEnabled,
                        additionalProperties: metadata.additionalProperties
                            .flatMap {
                                Components.Schemas.PayloadMetadata.additionalPropertiesPayload
                                    .init(additionalProperties: $0)
                            }
                    )
                )
            )
        )
        switch response {
        case .accepted:
            return
        case .badRequest(let badRequest):
            let message = (try? badRequest.body.json.prettyDescription) ?? "<nil>"
            throw ClientError.heartbeatRejected(message: message)
        case .internalServerError(let internalServerError):
            let message = (try? internalServerError.body.json.prettyDescription) ?? "<nil>"
            throw ClientError.serverError(message: message)
        case .undocumented(let statusCode, _):
            throw ClientError.undocumentedResponseHTTPCode(statusCode)
        }
    }

    /// Provides the current credential provider for authentication.
    public func updateCredentialProvider(_ provider: @escaping @Sendable () async -> URLCredential?) async {
        guard self.useMTLS else {
            HeartbeatHTTPClient.logger.debug("mTLS is disabled, ignoring a credential provider update.")
            return
        }
        await self.authDelegate.updateCredentialProvider(provider)
        HeartbeatHTTPClient.logger.debug("Updated credential provider for mTLS.")
    }
}

extension Components.Schemas.ResponseError {
    var prettyDescription: String {
        "\(error): \(message)"
    }
}

extension Heartbeat {
    public enum Status: Equatable, Hashable, CustomStringConvertible, Sendable {
        case uninitialized
        case initializing
        case waitingForFirstAttestationFetch
        case waitingForFirstKeyFetch
        case waitingForFirstHotPropertyUpdate
        case waitingForWorkloadRegistration
        case componentsFailedToRun
        case serviceDiscoveryUpdateSuccess
        case serviceDiscoveryUpdateFailure
        case serviceDiscoveryPublisherDraining
        case daemonDrained
        case daemonExitingOnError

        public var description: String {
            switch self {
            case .uninitialized:
                "uninitialized"
            case .initializing:
                "initializing"
            case .waitingForFirstAttestationFetch:
                "waitingForFirstAttestationFetch"
            case .waitingForFirstKeyFetch:
                "waitingForFirstKeyFetch"
            case .waitingForFirstHotPropertyUpdate:
                "waitingForFirstHotPropertyUpdate"
            case .waitingForWorkloadRegistration:
                "waitingForWorkloadRegistration"
            case .componentsFailedToRun:
                "componentsFailedToRun"
            case .serviceDiscoveryUpdateSuccess:
                "serviceDiscoveryUpdateSuccess"
            case .serviceDiscoveryUpdateFailure:
                "serviceDiscoveryUpdateFailure"
            case .serviceDiscoveryPublisherDraining:
                "serviceDiscoveryPublisherDraining"
            case .daemonDrained:
                "daemonDrained"
            case .daemonExitingOnError:
                "daemonExitingOnError"
            }
        }
    }
}

extension Components.Schemas.NodeOperationalStatus {
    init(from heartbeatStatus: Heartbeat.Status) {
        self = switch heartbeatStatus {
        case .uninitialized:
            .UNINITIALIZED
        case .initializing:
            .INITIALIZING
        case .waitingForFirstAttestationFetch:
            .WAITING_FOR_FIRST_ATTESTATION_FETCH
        case .waitingForFirstKeyFetch:
            .WAITING_FOR_FIRST_KEY_FETCH
        case .waitingForFirstHotPropertyUpdate:
            .WAITING_FOR_FIRST_HOT_PROPERTY_UPDATE
        case .waitingForWorkloadRegistration:
            .WAITING_FOR_WORKLOAD_REGISTRATION
        case .componentsFailedToRun:
            .COMPONENTS_FAILED_TO_RUN
        case .serviceDiscoveryUpdateSuccess:
            .SERVICE_DISCOVERY_UPDATE_SUCCESS
        case .serviceDiscoveryUpdateFailure:
            .SERVICE_DISCOVERY_UPDATE_FAILURE
        case .serviceDiscoveryPublisherDraining:
            .SERVICE_DISCOVERY_PUBLISHER_DRAINING
        case .daemonDrained:
            .DAEMON_DRAINED
        case .daemonExitingOnError:
            .DAEMON_EXITING_ON_ERROR
        }
    }
}
