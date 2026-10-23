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

import ClientCore
import CryptoClientV1
import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import os

public protocol AppleSigningServiceHTTPClientProtocol: Sendable {
    func sign(
        accountId: String,
        keyId: String,
        request: SignRequest
    ) async throws -> SignResponse

    func getKeyVersions(
        accountId: String,
        keyId: String
    ) async throws -> GetKeyVersionsResponse

    func updateCredentialProvider(
        _ provider: @escaping @Sendable () async -> URLCredential?
    ) async
}

/// A concrete implementation of a AppleSigningService crypto service client that makes HTTP calls to an upstream
/// service.
public struct AppleSigningServiceHTTPClient: AppleSigningServiceHTTPClientProtocol {
    /// The configuration for this service client.
    private let configuration: ServiceConfiguration

    /// Whether to allow sending of the client certificate.
    private let useMTLS: Bool

    /// The client used to make HTTP calls to the crypto service.
    private let cryptoClient: Client

    /// The authentication delegate that provides mTLS credentials.
    private let authDelegate: AuthDelegate

    /// The logger used by this service client.
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "AppleSigningServiceHTTPClient"
    )

    /// The error thrown when a invalid configuration is provided.
    private enum ConfigurationError: Error, LocalizedError, CustomStringConvertible {
        /// An insecure URL was provided, but allowInsecure is false.
        case insecureURL

        var description: String {
            switch self {
            case .insecureURL:
                return "Provided a non-https serviceURL for the crypto service."
            }
        }

        var errorDescription: String? {
            self.description
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
        AppleSigningServiceHTTPClient.logger.debug("Will use mTLS: \(useMTLS).")
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
        self.cryptoClient = .init(
            serverURL: serviceURL,
            configuration: generatedClientConfiguration,
            transport: transport,
            middlewares: middlewares
        )
    }

    /// Initializes a new service client with a custom transport (for testing).
    /// - Parameters:
    ///   - serverURL: The URL of the AppleSigningService service.
    ///   - transport: The transport to use for HTTP requests.
    init(serverURL: URL, transport: any ClientTransport) {
        self.configuration = ServiceConfiguration(
            serviceURL: serverURL,
            allowInsecure: true,
            disableMTLS: true
        )
        self.useMTLS = false
        let generatedClientConfiguration = OpenAPIRuntime.Configuration(
            dateTranscoder: .iso8601WithFractionalSeconds
        )
        self.authDelegate = AuthDelegate(allowSelfSignedCertificates: true)
        self.cryptoClient = .init(
            serverURL: serverURL,
            configuration: generatedClientConfiguration,
            transport: transport
        )
    }
}

extension AppleSigningServiceHTTPClient {
    /// An error thrown by the client.
    public enum ClientError: Swift.Error, CustomStringConvertible, LocalizedError {
        /// Received an undocumented HTTP response status code.
        case undocumentedResponseHTTPCode(Int, String)

        /// Sign operation failed.
        case signFailed(code: Int, title: String, detail: String?, instance: String?)

        /// Get key versions operation failed.
        case getKeyVersionsFailed(code: Int, title: String, detail: String?, instance: String?)

        public var errorDescription: String? {
            self.description
        }

        public var description: String {
            switch self {
            case .undocumentedResponseHTTPCode(let code, let body):
                return "Received an undocumented HTTP response status code: \(code). Body: \(body)."
            case .signFailed(let code, let title, let detail, let instance):
                return "Sign operation failed: \(code): \(title): \(detail ?? "nil"). Instance: \(instance ?? "nil")"
            case .getKeyVersionsFailed(let code, let title, let detail, let instance):
                return "Get key versions operation failed: \(code): \(title): \(detail ?? "nil"). Instance: \(instance ?? "nil")"
            }
        }
    }
}

/// A request to sign data.
public struct SignRequest: Sendable {
    /// The payload to sign (will be Base64-encoded).
    public let payload: Data

    /// The type of payload being signed.
    public let payloadType: PayloadType

    /// The signature algorithm to use.
    public let algorithm: SignatureAlgorithm

    /// Optional key version (required only if key mode is manual).
    public let version: String?

    /// Optional operation context for audit logging.
    public let operationContext: [String: String]?

    /// Creates a new sign request.
    /// - Parameters:
    ///   - payload: The payload to sign (digest).
    ///   - payloadType: The type of payload being signed.
    ///   - algorithm: The signature algorithm to use.
    ///   - version: Optional key version.
    ///   - operationContext: Optional context for audit logging.
    public init(
        payload: Data,
        payloadType: PayloadType,
        algorithm: SignatureAlgorithm,
        version: String? = nil,
        operationContext: [String: String]? = nil
    ) {
        self.payload = payload
        self.payloadType = payloadType
        self.algorithm = algorithm
        self.version = version
        self.operationContext = operationContext
    }
}

/// A response from a sign operation.
public struct SignResponse: Sendable {
    /// The signature.
    public let signature: Data

    /// The certificate chain (Base64-encoded DER format).
    public let certChain: [Data]

    /// Creates a new sign response.
    /// - Parameters:
    ///   - signature: The signature.
    ///   - certChain: The certificate chain.
    public init(signature: Data, certChain: [Data]) {
        self.signature = signature
        self.certChain = certChain
    }
}

/// A response from getting key versions.
public struct GetKeyVersionsResponse: Sendable {
    /// The list of key versions.
    public let versions: [KeyVersion]

    /// Creates a new get key versions response.
    /// - Parameter versions: The list of key versions.
    public init(versions: [KeyVersion]) {
        self.versions = versions
    }
}

/// A key version with its associated certificate chain.
public struct KeyVersion: Sendable {
    /// The version identifier.
    public let version: String

    /// The certificate chain (Base64-encoded DER format).
    public let certChain: [Data]

    /// Creates a new key version.
    /// - Parameters:
    ///   - version: The version identifier.
    ///   - certChain: The certificate chain.
    public init(version: String, certChain: [Data]) {
        self.version = version
        self.certChain = certChain
    }
}

/// The type of payload being signed.
public enum PayloadType: String, Sendable {
    /// Pre-computed digest (only supported type).
    case digest = "DIGEST"
}

/// Signature algorithm.
public enum SignatureAlgorithm: String, Sendable {
    case mldsa87Rsa3072PssSha512Dr13 = "MLDSA87_RSA3072_PSS_SHA512_DR13"
}

// MARK: - Type Conversions

extension CryptoClientV1.Components.Schemas.PayloadType {
    init(from: PayloadType) {
        switch from {
        case .digest:
            self = .DIGEST
        }
    }
}

extension CryptoClientV1.Components.Schemas.SignatureAlgorithm {
    init(from: SignatureAlgorithm) {
        switch from {
        case .mldsa87Rsa3072PssSha512Dr13:
            self = .MLDSA87_RSA3072_PSS_SHA512_DR13
        }
    }
}

extension AppleSigningServiceHTTPClient {
    /// Signs the provided data with the specified key.
    /// - Parameters:
    ///   - accountId: The account identifier.
    ///   - keyId: The key identifier (can be keyId or "name:keyName").
    ///   - request: The sign request containing payload, payload type, and algorithm.
    /// - Returns: The sign response containing signature and certificate chain.
    public func sign(
        accountId: String,
        keyId: String,
        request: SignRequest
    ) async throws -> SignResponse {
        let response = try await cryptoClient.sign(
            path: .init(
                accountId: accountId,
                keyId: keyId
            ),
            body: .json(
                .init(
                    version: request.version,
                    payload: .init(request.payload),
                    payloadType: .init(from: request.payloadType),
                    algorithm: .init(from: request.algorithm),
                    operationContext: request.operationContext.map { .init(additionalProperties: $0) }
                )
            )
        )

        switch response {
        case .ok(let okResponse):
            let signResponse = try okResponse.body.json
            let certChain = signResponse.certChain.map { Data($0.data) }
            return SignResponse(
                signature: Data(signResponse.signature.data),
                certChain: certChain
            )
        case .forbidden(let errorResponse):
            let problem = try errorResponse.body.application_problem_plus_json
            throw ClientError.signFailed(
                code: HTTPStatusCode.forbidden.rawValue,
                title: problem.title,
                detail: problem.detail,
                instance: problem.instance
            )
        case .notFound(let errorResponse):
            let problem = try errorResponse.body.application_problem_plus_json
            throw ClientError.signFailed(
                code: HTTPStatusCode.notFound.rawValue,
                title: problem.title,
                detail: problem.detail,
                instance: problem.instance
            )
        case .conflict(let errorResponse):
            let problem = try errorResponse.body.application_problem_plus_json
            throw ClientError.signFailed(
                code: HTTPStatusCode.conflict.rawValue,
                title: problem.title,
                detail: problem.detail,
                instance: problem.instance
            )
        case .gone(let errorResponse):
            let problem = try errorResponse.body.application_problem_plus_json
            throw ClientError.signFailed(
                code: HTTPStatusCode.gone.rawValue,
                title: problem.title,
                detail: problem.detail,
                instance: problem.instance
            )
        case .unprocessableContent(let errorResponse):
            let problem = try errorResponse.body.application_problem_plus_json
            throw ClientError.signFailed(
                code: HTTPStatusCode.unprocessableContent.rawValue,
                title: problem.title,
                detail: problem.detail,
                instance: problem.instance
            )
        case .undocumented(let statusCode, let response):
            let bodyString: String = if let body = response.body {
                try await String(collecting: body, upTo: 10000)
            } else {
                "<empty body>"
            }
            throw await ClientError.undocumentedResponseHTTPCode(statusCode, bodyString)
        }
    }

    /// Gets the underlying key versions for a specified signing key.
    /// - Parameters:
    ///   - accountId: The account identifier.
    ///   - keyId: The key identifier (can be keyId or "name:keyName").
    /// - Returns: The response containing a list of key versions.
    public func getKeyVersions(
        accountId: String,
        keyId: String
    ) async throws -> GetKeyVersionsResponse {
        let response = try await cryptoClient.getKeyVersions(
            path: .init(
                accountId: accountId,
                keyId: keyId
            )
        )

        switch response {
        case .ok(let okResponse):
            let versionsResponse = try okResponse.body.json
            let versions = versionsResponse.versions.map { keyVersion in
                KeyVersion(
                    version: keyVersion.version,
                    certChain: keyVersion.certChain.map { Data($0.data) }
                )
            }
            return GetKeyVersionsResponse(versions: versions)
        case .forbidden(let errorResponse):
            let problem = try errorResponse.body.application_problem_plus_json
            throw ClientError.getKeyVersionsFailed(
                code: HTTPStatusCode.forbidden.rawValue,
                title: problem.title,
                detail: problem.detail,
                instance: problem.instance
            )
        case .notFound(let errorResponse):
            let problem = try errorResponse.body.application_problem_plus_json
            throw ClientError.getKeyVersionsFailed(
                code: HTTPStatusCode.notFound.rawValue,
                title: problem.title,
                detail: problem.detail,
                instance: problem.instance
            )
        case .conflict(let errorResponse):
            let problem = try errorResponse.body.application_problem_plus_json
            throw ClientError.getKeyVersionsFailed(
                code: HTTPStatusCode.conflict.rawValue,
                title: problem.title,
                detail: problem.detail,
                instance: problem.instance
            )
        case .gone(let errorResponse):
            let problem = try errorResponse.body.application_problem_plus_json
            throw ClientError.getKeyVersionsFailed(
                code: HTTPStatusCode.gone.rawValue,
                title: problem.title,
                detail: problem.detail,
                instance: problem.instance
            )
        case .undocumented(let statusCode, let response):
            let bodyString: String = if let body = response.body {
                try await String(collecting: body, upTo: 10000)
            } else {
                "<empty body>"
            }
            throw await ClientError.undocumentedResponseHTTPCode(statusCode, bodyString)
        }
    }

    /// Provides the current credential provider for authentication.
    public func updateCredentialProvider(_ provider: @escaping @Sendable () async -> URLCredential?) async {
        guard self.useMTLS else {
            AppleSigningServiceHTTPClient.logger.debug("mTLS is disabled, ignoring a credential provider update.")
            return
        }
        await self.authDelegate.updateCredentialProvider(provider)
        AppleSigningServiceHTTPClient.logger.debug("Updated credential provider for mTLS.")
    }
}

enum HTTPStatusCode: Int {
    case ok = 200
    case created = 201
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case conflict = 409
    case gone = 410
    case unprocessableContent = 422
    case serverError = 500
}
