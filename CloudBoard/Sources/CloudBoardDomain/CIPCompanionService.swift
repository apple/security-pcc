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

import Foundation
package import CloudBoardAsyncXPC

/// Error received from CIP Companion service HTTP request
public enum CIPCompanionServiceError: Error, Equatable {
    /// BridgeCIPCompanionService Client not running
    case clientUnavailable
    /// unexpected error encountered during CIPCompanionService request execution
    case unexpectedError
    /// stores http error code string(eg: INVALID_PARAMETER) and error message
    /// receieved when imageVerify request fails
    /// details in CIPCompanionClient openapi.yaml
    case verificationFailed(code: String, message: String)
    /// stores undocumented HTTP response status code and error message
    /// details in CIPCompanionClient openapi.yaml
    case undocumentedResponseHTTPCode(code: Int, message: String)

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .clientUnavailable:
            buffer.writeHostInteger(0)
        case .unexpectedError:
            buffer.writeHostInteger(1)
        case .verificationFailed(let code, let message):
            buffer.writeHostInteger(2)
            try code.encode(to: &buffer)
            try message.encode(to: &buffer)
        case .undocumentedResponseHTTPCode(let code, let message):
            buffer.writeHostInteger(3)
            buffer.writeHostInteger(code)
            try message.encode(to: &buffer)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch rawValue {
        case 0:
            self = .clientUnavailable
        case 1:
            self = .unexpectedError
        case 2:
            self = try .verificationFailed(
                code: .init(from: &buffer),
                message: .init(from: &buffer)
            )
        case 3:
            let code = try buffer.readHostIntegerOrThrow(as: Int.self)
            self = try .undocumentedResponseHTTPCode(
                code: code,
                message: .init(from: &buffer)
            )
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
    }
}

/// The status of an image verification attempt received from CIP Companion service
public enum CIPCompanionServiceImageVerificationStatus: Sendable, Equatable, Codable {
    case accepted
    case rejected

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .accepted:
            buffer.writeHostInteger(0)
        case .rejected:
            buffer.writeHostInteger(1)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch rawValue {
        case 0:
            self = .accepted
        case 1:
            self = .rejected
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
    }
}

/// The reason for an image verification result received from CIP Companion service
public enum CIPCompanionServiceImageVerificationReason: Sendable, Equatable, Codable {
    case imageAllowlisted
    case sensorBanned
    case fraudScoreTriggeredDetection
    case imageAlreadyValid
    case imageAlreadyRevoked
    case allChecksPassed

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        switch self {
        case .imageAllowlisted:
            buffer.writeHostInteger(0)
        case .sensorBanned:
            buffer.writeHostInteger(1)
        case .fraudScoreTriggeredDetection:
            buffer.writeHostInteger(2)
        case .imageAlreadyValid:
            buffer.writeHostInteger(3)
        case .imageAlreadyRevoked:
            buffer.writeHostInteger(4)
        case .allChecksPassed:
            buffer.writeHostInteger(5)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch rawValue {
        case 0:
            self = .imageAllowlisted
        case 1:
            self = .sensorBanned
        case 2:
            self = .fraudScoreTriggeredDetection
        case 3:
            self = .imageAlreadyValid
        case 4:
            self = .imageAlreadyRevoked
        case 5:
            self = .allChecksPassed
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad result enum case \(rawValue)"
            ))
        }
    }
}

/// CIPCompanionService verifyImage http request result
public struct CIPCompanionServiceImageVerificationResult: Sendable, Equatable, Codable {
    /// The overall verification status of the image.
    public let status: CIPCompanionServiceImageVerificationStatus
    /// The reason for the verification result.
    public let reason: CIPCompanionServiceImageVerificationReason

    package init(
        status: CIPCompanionServiceImageVerificationStatus,
        reason: CIPCompanionServiceImageVerificationReason
    ) {
        self.status = status
        self.reason = reason
    }

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.status.encode(to: &buffer)
        try self.reason.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.status = try .init(from: &buffer)
        self.reason = try .init(from: &buffer)
    }
}

/// V1 image metadata for CIPCompanionService requests
public struct CIPCompanionServiceImageMetadataV1: Sendable, Equatable {
    static let maxArrayCount = 3

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

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.uniqueCameraModel.encode(to: &buffer)
        try self.pccAppVersion.encode(to: &buffer)
        try self.fraudModelVersion.encode(to: &buffer)
        buffer.writeHostInteger(self.isoSpeedRatings)
        try self.exposureTime.bitPattern.encode(to: &buffer)
        buffer.writeHostInteger(self.asShotNeutral.count)
        for val in self.asShotNeutral {
            try val.bitPattern.encode(to: &buffer)
        }
        try self.captureTimestamp.encode(to: &buffer)
        buffer.writeHostInteger(self.perChannelAvgIntensityMap.count)
        for outer in self.perChannelAvgIntensityMap {
            buffer.writeHostInteger(outer.count)
            for middle in outer {
                buffer.writeHostInteger(middle.count)
                for val in middle {
                    try val.bitPattern.encode(to: &buffer)
                }
            }
        }
        buffer.writeHostInteger(self.fraudScore)
        buffer.writeHostInteger(self.confidenceScore)
        buffer.writeHostInteger(self.tracer1FraudScore)
        buffer.writeHostInteger(self.tracer1ConfidenceScore)
        buffer.writeHostInteger(self.tracer2FraudScore)
        buffer.writeHostInteger(self.tracer2ConfidenceScore)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.uniqueCameraModel = try .init(from: &buffer)
        self.pccAppVersion = try .init(from: &buffer)
        self.fraudModelVersion = try .init(from: &buffer)
        self.isoSpeedRatings = try buffer.readHostIntegerOrThrow(as: Int.self)
        self.exposureTime = try Float(bitPattern: .init(from: &buffer))
        let asShotCount = try buffer.readHostIntegerOrThrow(as: Int.self)
        guard asShotCount <= Self.maxArrayCount else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "asShotNeutral count \(asShotCount) exceeds maximum of \(Self.maxArrayCount)"
            ))
        }
        var asShotNeutral: [Float] = []
        asShotNeutral.reserveCapacity(asShotCount)
        for _ in 0 ..< asShotCount {
            try asShotNeutral.append(Float(bitPattern: .init(from: &buffer)))
        }
        self.asShotNeutral = asShotNeutral
        self.captureTimestamp = try .init(from: &buffer)
        let outerCount = try buffer.readHostIntegerOrThrow(as: Int.self)
        guard outerCount <= Self.maxArrayCount else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "perChannelAvgIntensityMap outer count \(outerCount) exceeds maximum of \(Self.maxArrayCount)"
            ))
        }
        var perChannelMap: [[[Float]]] = []
        perChannelMap.reserveCapacity(outerCount)
        for _ in 0 ..< outerCount {
            let middleCount = try buffer.readHostIntegerOrThrow(as: Int.self)
            guard middleCount <= Self.maxArrayCount else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "perChannelAvgIntensityMap middle count \(middleCount) exceeds maximum of \(Self.maxArrayCount)"
                ))
            }
            var middle: [[Float]] = []
            middle.reserveCapacity(middleCount)
            for _ in 0 ..< middleCount {
                let innerCount = try buffer.readHostIntegerOrThrow(as: Int.self)
                guard innerCount <= Self.maxArrayCount else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: [ByteBufferCodingKey(Self.self)],
                        debugDescription: "perChannelAvgIntensityMap inner count \(innerCount) exceeds maximum of \(Self.maxArrayCount)"
                    ))
                }
                var inner: [Float] = []
                inner.reserveCapacity(innerCount)
                for _ in 0 ..< innerCount {
                    try inner.append(Float(bitPattern: .init(from: &buffer)))
                }
                middle.append(inner)
            }
            perChannelMap.append(middle)
        }
        self.perChannelAvgIntensityMap = perChannelMap
        self.fraudScore = try buffer.readHostIntegerOrThrow(as: Int.self)
        self.confidenceScore = try buffer.readHostIntegerOrThrow(as: Int.self)
        self.tracer1FraudScore = try buffer.readHostIntegerOrThrow(as: Int.self)
        self.tracer1ConfidenceScore = try buffer.readHostIntegerOrThrow(as: Int.self)
        self.tracer2FraudScore = try buffer.readHostIntegerOrThrow(as: Int.self)
        self.tracer2ConfidenceScore = try buffer.readHostIntegerOrThrow(as: Int.self)
    }
}

/// Versioned metadata container for CIPCompanionService requests
public struct CIPCompanionServiceImageMetadata: Sendable, Equatable {
    public let imageMetadataV1: CIPCompanionServiceImageMetadataV1?

    public init(imageMetadataV1: CIPCompanionServiceImageMetadataV1? = nil) {
        self.imageMetadataV1 = imageMetadataV1
    }

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        if let v1 = self.imageMetadataV1 {
            buffer.writeHostInteger(1)
            try v1.encode(to: &buffer)
        } else {
            buffer.writeHostInteger(0)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        let hasV1 = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch hasV1 {
        case 1:
            self.imageMetadataV1 = try .init(from: &buffer)
        case 0:
            self.imageMetadataV1 = nil
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad presence flag \(hasV1) for imageMetadataV1"
            ))
        }
    }
}

/// CIPCompanionService verifyImage request params
/// details in CIPCompanionClient openapi.yaml
public struct CIPCompanionServiceVerifyImageRequest: Sendable, Equatable {
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
    public let imageMetadata: CIPCompanionServiceImageMetadata
    /// A score representing the confidence of the fraud score.
    public let confidenceScore: Int?

    public init(
        imageID: Data,
        sensorID: Data,
        imageHash: Data,
        developmentTime: Date,
        imageFraudScore: Int,
        imageMetadata: CIPCompanionServiceImageMetadata,
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

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.imageID.encode(to: &buffer)
        try self.sensorID.encode(to: &buffer)
        try self.imageHash.encode(to: &buffer)
        try self.developmentTime.encode(to: &buffer)
        buffer.writeHostInteger(self.imageFraudScore)
        try self.imageMetadata.encode(to: &buffer)
        if let confidenceScore = self.confidenceScore {
            buffer.writeHostInteger(1)
            buffer.writeHostInteger(confidenceScore)
        } else {
            buffer.writeHostInteger(0)
        }
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.imageID = try .init(from: &buffer)
        self.sensorID = try .init(from: &buffer)
        self.imageHash = try .init(from: &buffer)
        self.developmentTime = try .init(from: &buffer)
        self.imageFraudScore = try buffer.readHostIntegerOrThrow(as: Int.self)
        self.imageMetadata = try .init(from: &buffer)
        let hasConfidenceScore = try buffer.readHostIntegerOrThrow(as: Int.self)
        switch hasConfidenceScore {
        case 1:
            self.confidenceScore = try buffer.readHostIntegerOrThrow(as: Int.self)
        case 0:
            self.confidenceScore = nil
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: [ByteBufferCodingKey(Self.self)],
                debugDescription: "bad presence flag \(hasConfidenceScore) for confidenceScore"
            ))
        }
    }
}

/// Trace context associated with CIPCompanionService requests
package struct CIPCompanionServiceTraceContext: ByteBufferCodable, Sendable, Equatable {
    package let companionServiceRequestID: String
    package let serverRequestID: String
    package let traceID: UUID
    package let spanID: UInt64

    package init(
        companionServiceRequestID: String,
        serverRequestID: String,
        traceID: UUID,
        spanID: UInt64
    ) {
        self.companionServiceRequestID = companionServiceRequestID
        self.serverRequestID = serverRequestID
        self.traceID = traceID
        self.spanID = spanID
    }

    package func encode(to buffer: inout ByteBuffer) throws {
        try self.companionServiceRequestID.encode(to: &buffer)
        try self.serverRequestID.encode(to: &buffer)
        try self.traceID.encode(to: &buffer)
        try self.spanID.encode(to: &buffer)
    }

    package init(from buffer: inout ByteBuffer) throws {
        self.companionServiceRequestID = try .init(from: &buffer)
        self.serverRequestID = try .init(from: &buffer)
        self.traceID = try .init(from: &buffer)
        self.spanID = try .init(from: &buffer)
    }
}

/// wrapper to share CIPCompanionServiceError within cloudboard processes
package struct InternalCIPCompanionServiceErrorResponse: Error, Sendable, Equatable, ByteBufferCodable {
    package let error: CIPCompanionServiceError

    package init(error: CIPCompanionServiceError) {
        self.error = error
    }

    package func encode(to buffer: inout ByteBuffer) throws {
        try self.error.encode(to: &buffer)
    }

    package init(from buffer: inout ByteBuffer) throws {
        self.error = try .init(from: &buffer)
    }
}

/// wrapper to share CIPCompanionService verifyImage request result within cloudboard processes
package struct InternalCIPCompanionServiceImageVerificationResponse: Sendable, Equatable, ByteBufferCodable {
    /// verifyImage http request result
    package let result: CIPCompanionServiceImageVerificationResult

    package init(result: CIPCompanionServiceImageVerificationResult) {
        self.result = result
    }

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.result.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.result = try .init(from: &buffer)
    }
}

/// XPC message for CIPCompanionService verifyImage request.
package struct InternalCIPCompanionServiceVerifyImageMessage: CloudBoardAsyncXPCByteBufferMessage {
    package typealias Success = InternalCIPCompanionServiceImageVerificationResponse
    package typealias Failure = InternalCIPCompanionServiceErrorResponse

    package let request: CIPCompanionServiceVerifyImageRequest
    package let traceContext: CIPCompanionServiceTraceContext

    package init(
        request: CIPCompanionServiceVerifyImageRequest,
        traceContext: CIPCompanionServiceTraceContext
    ) {
        self.request = request
        self.traceContext = traceContext
    }

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.request.encode(to: &buffer)
        try self.traceContext.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.request = try .init(from: &buffer)
        self.traceContext = try .init(from: &buffer)
    }
}
