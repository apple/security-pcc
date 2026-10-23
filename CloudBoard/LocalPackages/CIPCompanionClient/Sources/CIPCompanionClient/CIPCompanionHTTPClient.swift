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

import CIPCompanionClientV1
import ClientCore
import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import os

public protocol CIPCompanionHTTPClientProtocol: Sendable {
    func verifyImage(
        requestID: String,
        request: VerifyImageRequest
    ) async throws -> VerificationResult

    func updateCredentialProvider(
        _ provider: @escaping @Sendable () async -> URLCredential?
    ) async
}

/// A concrete implementation of a CIPCompanion service client that makes HTTP calls to an upstream service.
public struct CIPCompanionHTTPClient: CIPCompanionHTTPClientProtocol {
    /// The configuration for this service client.
    private let configuration: ServiceConfiguration

    /// Whether to allow sending of the client certificate.
    private let useMTLS: Bool

    /// The client used to make HTTP calls to the CIPCompanion service.
    private let client: Client

    /// The authentication delegate that provides mTLS credentials.
    private let authDelegate: AuthDelegate

    /// The logger used by this service client.
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CIPCompanionHTTPClient"
    )

    /// The error thrown when an invalid configuration is provided.
    private enum ConfigurationError: Error, LocalizedError, CustomStringConvertible {
        /// An insecure URL was provided, but allowInsecure is false.
        case insecureURL

        var description: String {
            switch self {
            case .insecureURL:
                return "Provided a non-https serviceURL for the CIPCompanion service."
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
        Self.logger.debug("Will use mTLS: \(useMTLS).")
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
            TaskLocalHeaderMiddleware(),
            RequestIdMiddleware(),
            LoggingMiddleware(logger: Self.logger),
            RetryingMiddleware(
                signals: [.code(429), .range(500 ..< 600), .errorThrown],
                policy: .upToAttempts(count: configuration.attemptCount),
                delay: .constant(seconds: configuration.retryDelay)
            ),
        ]
        self.client = .init(
            serverURL: serviceURL,
            configuration: generatedClientConfiguration,
            transport: transport,
            middlewares: middlewares
        )
    }

    /// Initializes a new service client with a custom transport (for testing).
    /// - Parameters:
    ///   - serverURL: The URL of the CIPCompanion service.
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
        self.client = .init(
            serverURL: serverURL,
            configuration: generatedClientConfiguration,
            transport: transport
        )
    }
}

extension CIPCompanionHTTPClient {
    /// An error thrown by the client.
    public enum ClientError: Swift.Error, CustomStringConvertible, LocalizedError {
        /// Received an undocumented HTTP response status code.
        case undocumentedResponseHTTPCode(Int, String)

        /// Image verification failed.
        case verificationFailed(code: String, message: String)

        public var errorDescription: String? {
            self.description
        }

        public var description: String {
            switch self {
            case .undocumentedResponseHTTPCode(let code, let body):
                return "Received an undocumented HTTP response status code: \(code). Body: \(body)."
            case .verificationFailed(let code, let message):
                return "Image verification failed: [\(code)] \(message)"
            }
        }
    }
}

/// Versioned metadata container for a verify image request.
public struct ImageMetadata: Sendable, Equatable {
    public let imageMetadataV1: ImageMetadataV1?

    public init(imageMetadataV1: ImageMetadataV1? = nil) {
        self.imageMetadataV1 = imageMetadataV1
    }
}

/// V1 structured image metadata.
public struct ImageMetadataV1: Sendable, Equatable {
    public let uniqueCameraModel: String
    public let pccAppVersion: String
    public let fraudModelVersion: String
    public let isoSpeedRatings: Int
    public let exposureTime: Float
    public let asShotNeutral: [Float]
    public let captureTimestamp: String
    public let perChannelAvgIntensityMap: [[[Float]]]
    public let fraudScore: Int
    public let confidenceScore: Int
    public let tracer1FraudScore: Int
    public let tracer1ConfidenceScore: Int
    public let tracer2FraudScore: Int
    public let tracer2ConfidenceScore: Int

    public init(
        uniqueCameraModel: String,
        pccAppVersion: String,
        fraudModelVersion: String,
        isoSpeedRatings: Int,
        exposureTime: Float,
        asShotNeutral: [Float],
        captureTimestamp: String,
        perChannelAvgIntensityMap: [[[Float]]],
        fraudScore: Int,
        confidenceScore: Int,
        tracer1FraudScore: Int,
        tracer1ConfidenceScore: Int,
        tracer2FraudScore: Int,
        tracer2ConfidenceScore: Int
    ) {
        self.uniqueCameraModel = uniqueCameraModel
        self.pccAppVersion = pccAppVersion
        self.fraudModelVersion = fraudModelVersion
        self.isoSpeedRatings = isoSpeedRatings
        self.exposureTime = exposureTime
        self.asShotNeutral = asShotNeutral
        self.captureTimestamp = captureTimestamp
        self.perChannelAvgIntensityMap = perChannelAvgIntensityMap
        self.fraudScore = fraudScore
        self.confidenceScore = confidenceScore
        self.tracer1FraudScore = tracer1FraudScore
        self.tracer1ConfidenceScore = tracer1ConfidenceScore
        self.tracer2FraudScore = tracer2FraudScore
        self.tracer2ConfidenceScore = tracer2ConfidenceScore
    }
}

/// A request to verify an image.
public struct VerifyImageRequest: Sendable {
    /// The unique identifier for the image.
    public let imageID: Data

    /// The identifier of the sensor that captured the image.
    public let sensorID: Data

    /// The hash of the image data.
    public let imageHash: Data

    /// The timestamp when the image was developed.
    public let developmentTime: Date

    /// A score indicating the likelihood of fraud associated with the image.
    public let imageFraudScore: Int

    /// Additional metadata associated with the image.
    public let imageMetadata: ImageMetadata

    /// A score representing the confidence of the fraud score.
    public let confidenceScore: Int?

    /// Creates a new verify image request.
    /// - Parameters:
    ///   - imageID: The unique identifier for the image.
    ///   - sensorID: The identifier of the sensor that captured the image.
    ///   - imageHash: The hash of the image data.
    ///   - developmentTime: The timestamp when the image was developed.
    ///   - imageFraudScore: A score indicating the likelihood of fraud.
    ///   - imageMetadata: Additional arbitrary metadata.
    ///   - confidenceScore: A score representing the confidence of the fraud score.
    public init(
        imageID: Data,
        sensorID: Data,
        imageHash: Data,
        developmentTime: Date,
        imageFraudScore: Int,
        imageMetadata: ImageMetadata,
        confidenceScore: Int? = nil
    ) {
        self.imageID = imageID
        self.sensorID = sensorID
        self.imageHash = imageHash
        self.developmentTime = developmentTime
        self.imageFraudScore = imageFraudScore
        self.imageMetadata = imageMetadata
        self.confidenceScore = confidenceScore
    }
}

/// The verification status of an image.
public enum VerificationStatus: String, Sendable {
    case accepted
    case rejected
}

/// The reason for the verification result.
public enum VerificationReason: Sendable {
    case imageAllowlisted
    case sensorBanned
    case fraudScoreTriggeredDetection
    case imageAlreadyValid
    case imageAlreadyRevoked
    case allChecksPassed
}

/// A response from an image verification operation.
public struct VerificationResult: Sendable {
    /// The overall verification status of the image.
    public let status: VerificationStatus
    /// The reason for the verification result.
    public let reason: VerificationReason

    /// Creates a new verification result.
    /// - Parameters:
    ///   - status: The verification status.
    ///   - reason: The reason for the result.
    public init(status: VerificationStatus, reason: VerificationReason) {
        self.status = status
        self.reason = reason
    }
}

// MARK: - Type Conversions

extension VerificationStatus {
    init(from packageType: CIPCompanionClientV1.Components.Schemas.VerificationResult.statusPayload) {
        switch packageType {
        case .ACCEPTED:
            self = .accepted
        case .REJECTED:
            self = .rejected
        }
    }
}

extension VerificationReason {
    init(from packageType: CIPCompanionClientV1.Components.Schemas.VerificationResult.reasonPayload) {
        switch packageType {
        case .IMAGE_ALLOWLISTED:
            self = .imageAllowlisted
        case .SENSOR_BANNED:
            self = .sensorBanned
        case .FRAUD_SCORE_TRIGGERED_DETECTION:
            self = .fraudScoreTriggeredDetection
        case .IMAGE_ALREADY_VALID:
            self = .imageAlreadyValid
        case .IMAGE_ALREADY_REVOKED:
            self = .imageAlreadyRevoked
        case .ALL_CHECKS_PASSED:
            self = .allChecksPassed
        }
    }
}

extension CIPCompanionHTTPClient {
    /// Verifies an image's fraud score, sensor status, and temporal score.
    /// - Parameters:
    ///   - requestID: The companion service request UUID to forward as the `x-apple-request-uuid` header.
    ///   - request: The verification request containing image and sensor information.
    /// - Returns: The verification result indicating whether the image is accepted or rejected.
    public func verifyImage(
        requestID: String,
        request: VerifyImageRequest
    ) async throws -> VerificationResult {
        let response = try await TaskLocalHeaderMiddleware.$headers.withValue(
            ["x-apple-request-uuid": requestID]
        ) {
            try await self.client.verifyImage(
                body: .json(
                    .init(
                        imageID: request.imageID.base64URLEncodedString(),
                        sensorID: request.sensorID.base64URLEncodedString(),
                        imageHash: request.imageHash.base64URLEncodedString(),
                        developmentTime: request.developmentTime,
                        imageFraudScore: request.imageFraudScore,
                        imageMetadata: .init(from: request.imageMetadata),
                        confidenceScore: request.confidenceScore
                    )
                )
            )
        }

        switch response {
        case .ok(let okResponse):
            let verificationResult = try okResponse.body.json
            return VerificationResult(
                status: VerificationStatus(from: verificationResult.status),
                reason: VerificationReason(from: verificationResult.reason)
            )
        case .badRequest(let errorResponse):
            let error = try errorResponse.body.json
            throw ClientError.verificationFailed(code: error.code, message: error.message)
        case .internalServerError(let errorResponse):
            let error = try errorResponse.body.json
            throw ClientError.verificationFailed(code: error.code, message: error.message)
        case .undocumented(let statusCode, let response):
            let bodyString: String = if let body = response.body {
                try await String(collecting: body, upTo: 10000)
            } else {
                "<empty body>"
            }
            Self.logger.error("Undocumented response (\(statusCode)): \(bodyString)")
            throw await ClientError.undocumentedResponseHTTPCode(statusCode, bodyString)
        }
    }

    /// Provides the current credential provider for authentication.
    public func updateCredentialProvider(_ provider: @escaping @Sendable () async -> URLCredential?) async {
        guard self.useMTLS else {
            Self.logger.debug("mTLS is disabled, ignoring a credential provider update.")
            return
        }
        await self.authDelegate.updateCredentialProvider(provider)
        Self.logger.debug("Updated credential provider for mTLS.")
    }
}

extension CIPCompanionClientV1.Components.Schemas.ImageMetadata {
    init(from metadata: ImageMetadata) {
        self = .init(imageMetadataV1: metadata.imageMetadataV1.map { .init(from: $0) })
    }
}

extension CIPCompanionClientV1.Components.Schemas.ImageMetadataV1 {
    init(from v1: ImageMetadataV1) {
        self = .init(
            unique_camera_model: v1.uniqueCameraModel,
            pcc_app_version: v1.pccAppVersion,
            fraud_model_version: v1.fraudModelVersion,
            iso_speed_ratings: v1.isoSpeedRatings,
            exposure_time: v1.exposureTime,
            as_shot_neutral: v1.asShotNeutral,
            capture_timestamp: v1.captureTimestamp,
            per_channel_avg_intensity_map: v1.perChannelAvgIntensityMap,
            fraud_score: v1.fraudScore,
            confidence_score: v1.confidenceScore,
            tracer1_fraud_score: v1.tracer1FraudScore,
            tracer1_confidence_score: v1.tracer1ConfidenceScore,
            tracer2_fraud_score: v1.tracer2FraudScore,
            tracer2_confidence_score: v1.tracer2ConfidenceScore
        )
    }
}

extension Data {
    /// Returns a URL-safe base64 encoded string (RFC 4648 §5) without padding characters.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
