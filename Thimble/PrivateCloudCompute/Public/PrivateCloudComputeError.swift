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

//
//  PrivateCloudComputeError.swift
//  PrivateCloudCompute
//
//  Copyright © 2025 Apple Inc. All rights reserved.
//

import AppleIntelligenceReporting
import Foundation

private let privateCloudComputeErrorDomain = "PrivateCloudComputeError"

package let privateCloudComputeErrorCategoryKey = "PrivateCloudComputeErrorCategory"
package let privateCloudComputeErrorRetryAfterDateKey = "PrivateCloudComputeErrorRetryAfterDate"
package let privateCloudComputeErrorTelemetryStringKey = "PrivateCloudComputeErrorTelemetryString"
package let privateCloudComputeErrorDebugMessageKey = "PrivateCloudComputeErrorDebugMessage"

public struct PrivateCloudComputeError: Error {
    /// The error code for this PrivateCloudComputeError
    public var code: Code

    /// If present, then the error is regarded as retryable, with the
    /// `Date` giving the earliest allowable time for the retry to
    /// be run.
    public var retryAfterDate: Date?

    /// A concise `String` suitable for use in telemetry, containing
    /// no data unique to the circumstances of this error.
    package var telemetryString: String {
        if let telemetrySuffix = self.telemetrySuffix {
            return "\(privateCloudComputeErrorDomain)_\(self.code)_\(telemetrySuffix)"
        } else {
            return "\(privateCloudComputeErrorDomain)_\(self.code)"
        }
    }
    private var telemetrySuffix: String?

    /// A `String` that contains error details for debug logging
    package var debugMessage: String?

    /// The `Error`s that caused this error. They are stored with
    /// conformance to `Codable` for easy use, so they are not
    /// full fidelity.
    public var underlying: [any Error] {
        get { return self.underlyingCodable.map { $0.unwrap() } }
        set { self.underlyingCodable = newValue.map(ErrorCodableValue.init(error:)) }
    }
    private var underlyingCodable: [ErrorCodableValue]

    public init(code: Code, retryAfterDate: Date? = nil, underlying: [any Error] = []) {
        self.init(code: code, retryAfterDate: retryAfterDate, telemetrySuffix: nil, debugMessage: nil, underlying: underlying)
    }

    package init(code: Code, retryAfterDate: Date? = nil, telemetrySuffix: String? = nil, debugMessage: String? = nil, underlying: [any Error] = []) {
        self.code = code
        self.retryAfterDate = retryAfterDate
        self.telemetrySuffix = telemetrySuffix
        self.debugMessage = debugMessage
        self.underlyingCodable = underlying.map(ErrorCodableValue.init(error:))
    }
}

extension PrivateCloudComputeError {
    public enum Code: Int, Sendable, Codable {
        case deniedDueToRateLimit = 32_001
        case availabilityError = 32_002  // (unknown reason)
        case unknownWorkload = 32_003
        case noNodesAvailable = 32_004
        case nodesBusy = 32_005
        case nodeAttestationChanged = 32_006
        case nodesOverUtilized = 32_007
        case workloadNotFound = 32_008
        case attestationsUnavailable = 32_009
        case timeoutError = 32_010  // (unknown reason)
        case setupRequestTimeout = 32_011
        case decryptionKeyTimeout = 32_012
        case maxRequestLifetimeReached = 32_013
        case requestChunkTimeout = 32_014
        case invalidRequestError = 32_015  // (unknown reason)
        case invalidWorkload = 32_016
        case unauthorizedError = 32_017  // (unknown reason)
        case tenantBlocked = 32_018
        case softwareBlocked = 32_019
        case workloadBlocked = 32_020
        case featureIdBlocked = 32_021
        case internalError = 32_022  // (unknown reason)
        case xpcConnectionInterrupted = 32_023
        case failedToLoadKeyData = 32_024
        case privacyProxyPermissionDenied = 32_025
        case privacyProxyIpcFailed = 32_026
        case privacyProxyInvalidUserTier = 32_027
        case privacyProxyInvalidParam = 32_028
        case privacyProxyInvalidConfigData = 32_029
        case privacyProxyInvalidConfigDataSign = 32_030
        case privacyProxyServerFailure = 32_031
        case privacyProxyFeatureDisabled = 32_032
        case privacyProxyRateLimited = 32_033
        case privacyProxyInvalidAuthentication = 32_034
        case privacyProxyInvalidRequest = 32_035
        case privacyProxyNetworkFailure = 32_036
        case privacyProxyTransparencyFailure = 32_037
        case privacyProxyInvalidConfigDates = 32_038
        case privacyProxyTDMFailure = 32_039
        case privacyProxyInvalidResponse = 32_040
        case privacyProxyFailed = 32_041
        case failedToValidateAllAttestations = 32_043
        case responseSummaryIndicatesFailure = 32_044
        case responseSummaryIndicatesUnauthenticated = 32_045
        case responseSummaryIndicatesInternalError = 32_046
        case responseSummaryIndicatesInvalidRequest = 32_047
        case responseSummaryIndicatesProxyFindWorkerError = 32_048
        case responseSummaryIndicatesProxyWorkerValidationError = 32_049
        case missingAttestationBundle = 32_050
        case invalidAttestationBundle = 32_051
        case routingHintMismatch = 32_052
        case missingResponseBypassContext = 32_053
        case expectedResponseOnBypass = 32_054
        case unexpectedAttestationKind = 32_055
        case attestationKindMismatch = 32_056
        case networkFailure = 32_057
        case serverError = 32_058  // (unknown reason)
        case unexpectedlyReceivedResponseBypassContext = 32_059
        case invalidClientOverrideBuildVersion = 32_060
        case subrequestResponseIndicatesInternalError = 32_061
        case subrequestResponseIndicatesInvalidRequest = 32_062
        case subrequestResponseIndicatesDiscarded = 32_063
        /// Unrecognized subresponse status.
        case subrequestResponseIndicatesFailure = 32_064
        case networkTimedOutSendingRopesRequest = 32_065
        case unableToAssembleDataChunkTooLarge = 32_066
        case unableToAssembleDataSizeMismatch = 32_067
        case unableToAssembleDataExpectedAdditionalChunks = 32_068
        case unableToChunkDataSizeTooLarge = 32_069
        /// Applicable to long-lived connections. Thrown to suspended readers of subrequest
        /// responses if the adopter exits `withConnection` closure before they finish.
        case connectionNoLongerRunning = 32_070

        /// Thrown for new discardable subrequests if an earlier discardable subrequest
        /// on this connection reached the server and was discarded.
        case subrequestDiscardedDueToEarlierDiscard = 32_071

        /// Not enough nodes to satisfy demand
        case notEnoughNodes = 32_072
    }
}

extension PrivateCloudComputeError {
    public enum Category: Sendable {
        case availability
        case clientError
        case forbidden
        case internalError
        case network
        case rateLimited
        case serverError
        case timeout
    }

    public var errorCategory: Category {
        switch self.code {
        case .attestationsUnavailable: .availability
        case .availabilityError: .availability
        case .nodeAttestationChanged: .availability
        case .nodesBusy: .availability
        case .nodesOverUtilized: .availability
        case .noNodesAvailable: .availability
        case .notEnoughNodes: .availability
        case .unknownWorkload: .clientError
        case .workloadNotFound: .clientError

        case .invalidClientOverrideBuildVersion: .clientError
        case .invalidRequestError: .clientError
        case .invalidWorkload: .clientError

        case .featureIdBlocked: .forbidden
        case .softwareBlocked: .forbidden
        case .tenantBlocked: .forbidden
        case .unauthorizedError: .forbidden
        case .workloadBlocked: .forbidden

        case .attestationKindMismatch: .internalError
        case .expectedResponseOnBypass: .internalError
        case .failedToLoadKeyData: .internalError
        case .failedToValidateAllAttestations: .internalError
        case .internalError: .internalError
        case .invalidAttestationBundle: .internalError
        case .missingAttestationBundle: .internalError
        case .missingResponseBypassContext: .internalError
        case .privacyProxyFailed: .internalError
        case .privacyProxyFeatureDisabled: .internalError
        case .privacyProxyInvalidAuthentication: .internalError
        case .privacyProxyInvalidConfigData: .internalError
        case .privacyProxyInvalidConfigDataSign: .internalError
        case .privacyProxyInvalidConfigDates: .internalError
        case .privacyProxyInvalidParam: .internalError
        case .privacyProxyInvalidRequest: .internalError
        case .privacyProxyInvalidResponse: .internalError
        case .privacyProxyInvalidUserTier: .internalError
        case .privacyProxyIpcFailed: .internalError
        case .privacyProxyNetworkFailure: .network
        case .privacyProxyPermissionDenied: .internalError
        case .privacyProxyRateLimited: .rateLimited
        case .privacyProxyServerFailure: .internalError
        case .privacyProxyTDMFailure: .internalError
        case .privacyProxyTransparencyFailure: .internalError
        case .responseSummaryIndicatesFailure: .internalError
        case .responseSummaryIndicatesInternalError: .internalError
        case .responseSummaryIndicatesInvalidRequest: .internalError
        case .responseSummaryIndicatesProxyFindWorkerError: .internalError
        case .responseSummaryIndicatesProxyWorkerValidationError: .internalError
        case .responseSummaryIndicatesUnauthenticated: .internalError
        case .routingHintMismatch: .internalError
        case .unexpectedAttestationKind: .internalError
        case .unexpectedlyReceivedResponseBypassContext: .internalError
        case .xpcConnectionInterrupted: .internalError

        case .networkFailure: .network

        case .deniedDueToRateLimit: .rateLimited

        case .serverError: .serverError

        case .decryptionKeyTimeout: .timeout
        case .maxRequestLifetimeReached: .timeout
        case .requestChunkTimeout: .timeout
        case .setupRequestTimeout: .timeout
        case .timeoutError: .timeout
        case .networkTimedOutSendingRopesRequest: .timeout

        case .subrequestResponseIndicatesDiscarded: .availability
        case .subrequestResponseIndicatesFailure: .internalError
        case .subrequestResponseIndicatesInternalError: .internalError
        case .subrequestResponseIndicatesInvalidRequest: .internalError

        case .unableToAssembleDataChunkTooLarge: .serverError
        case .unableToAssembleDataSizeMismatch: .serverError
        case .unableToAssembleDataExpectedAdditionalChunks: .serverError
        case .unableToChunkDataSizeTooLarge: .clientError

        case .connectionNoLongerRunning: .clientError
        case .subrequestDiscardedDueToEarlierDiscard: .availability
        }
    }
}

extension PrivateCloudComputeError: Codable, TC2JSON {
}

extension PrivateCloudComputeError: CustomNSError {
    public static var errorDomain: String { privateCloudComputeErrorDomain }
    public var errorCode: Int { self.code.rawValue }
    public var errorUserInfo: [String: Any] {
        var result: [String: Any] = [:]
        if let retryAfterDate = self.retryAfterDate {
            result[AppleIntelligenceErrorRetryAfterDateKey] = "\(retryAfterDate.ISO8601Format())"
            result[privateCloudComputeErrorRetryAfterDateKey] = "\(retryAfterDate.ISO8601Format())"
        }
        result[privateCloudComputeErrorTelemetryStringKey] = self.telemetryString
        if let debugMessage = self.debugMessage {
            result[privateCloudComputeErrorDebugMessageKey] = debugMessage
        }
        result[AppleIntelligenceErrorCategoryKey] = "\(self.category)"
        result[privateCloudComputeErrorCategoryKey] = "\(self.category)"
        if self.underlying.count == 1, let error = self.underlying.first {
            result[NSUnderlyingErrorKey] = error
        } else if self.underlying.count > 1 {
            result[NSMultipleUnderlyingErrorsKey] = self.underlying
        }
        return result
    }
}

extension PrivateCloudComputeError: CustomStringConvertible {
    // This mimics the `AppleIntelligenceError` `description` except
    // that it has more access to type information for the underlying
    // errors. If we don't implement this, AppleIntelligenceError will.
    public var description: String {
        if let next = underlying.first {
            return "\(descriptionWithoutUnderlying)::\(next)"
        } else {
            return "\(descriptionWithoutUnderlying)"
        }
    }
}

// AppleIntelligenceError makes certain demands, which we meet here.

extension PrivateCloudComputeError: AppleIntelligenceError {
    public var rawCode: Int {
        return self.code.rawValue
    }

    public var descriptionWithoutUnderlying: String {
        if let debugMessage {
            return "\(Self.errorDomain): \(self.code) (\(debugMessage))"
        } else if let telemetrySuffix {
            return "\(Self.errorDomain): \(self.code) (\(telemetrySuffix))"
        } else {
            return "\(Self.errorDomain): \(self.code)"
        }
    }

    public var underlyingErrors: [any AppleIntelligenceError] {
        return self.underlying.map {
            $0 as? any AppleIntelligenceError ?? convertToAppleIntelligenceError(error: $0 as NSError)
        }
    }

    public var additionalUserInfo: [String: String] {
        var result: [String: String] = [:]
        if let retryAfterDate = self.retryAfterDate {
            result[privateCloudComputeErrorRetryAfterDateKey] = "\(retryAfterDate.ISO8601Format())"
        }
        result[privateCloudComputeErrorTelemetryStringKey] = self.telemetryString
        if let debugMessage = self.debugMessage {
            result[privateCloudComputeErrorDebugMessageKey] = debugMessage
        }
        result[privateCloudComputeErrorCategoryKey] = "\(self.category)"
        return result
    }

    public var category: AppleIntelligenceErrorCategory {
        switch self.errorCategory {
        case .availability: return .availability
        case .clientError: return .clientError
        case .forbidden: return .forbidden
        case .internalError: return .internalError
        case .network: return .network
        case .rateLimited: return .rateLimited
        case .serverError: return .serverError
        case .timeout: return .timeout
        }
    }
}

extension PrivateCloudComputeError {
    /// An easy-to-use internal `PrivateCloudComputeError` that comes with debug information.
    package init(file: StaticString = #file, line: Int = #line, message: String = "internal error") {
        self.init(code: .internalError, debugMessage: "\(message) file=\(file), line=\(line)")
    }
}

extension PrivateCloudComputeError {
    // This is how we build errors on the basis of error results from ROPES,
    // giving a good mapping for the debug and telemetry strings.
    package init(responseMetadata: RopesResponseMetadata) {
        assert(responseMetadata.isError)

        // Build the telemetrySuffix
        let telemetrySuffix: String?
        if let receivedErrorCode = responseMetadata.receivedErrorCode {
            switch receivedErrorCode {
            case .code(let errorCode): telemetrySuffix = "\(errorCode)"
            case .unrecognized(let rawValue): telemetrySuffix = "\(rawValue)"
            }
        } else if let statusCode = responseMetadata.status {
            telemetrySuffix = "grpc_\(statusCode)"
        } else if let httpCode = responseMetadata.code {
            telemetrySuffix = "http_\(httpCode)"
        } else {
            telemetrySuffix = nil
        }

        // Build the debugMessage
        var debugMessageComponents: [String] = []
        if let code = responseMetadata.code {
            debugMessageComponents.append("response-code=\(code)")
        }
        if let status = responseMetadata.status {
            debugMessageComponents.append("status=\(status)")
        }
        if case .code(let errorCode) = responseMetadata.receivedErrorCode {
            debugMessageComponents.append("error-code=\(errorCode)")
        }
        if case .unrecognized(let rawValue) = responseMetadata.receivedErrorCode {
            debugMessageComponents.append("error-code=\(rawValue)")
        }
        if let errorDescription = responseMetadata.errorDescription {
            debugMessageComponents.append("description=\(errorDescription)")
        }
        if let cause = responseMetadata.cause {
            debugMessageComponents.append("cause=\(cause)")
        }
        if responseMetadata.retryable {
            debugMessageComponents.append("retryable=yes")
            let dateFormatted = responseMetadata.retryAfterDate.ISO8601Format(.init(timeZone: TimeZone.current))
            debugMessageComponents.append("retryAfterDate=\(dateFormatted)")
        } else {
            debugMessageComponents.append("retryable=no")
        }
        let debugMessage = debugMessageComponents.joined(separator: " ")

        if case .code(let errorCode) = responseMetadata.receivedErrorCode {
            switch errorCode {
            case .attestationsUnavailable:
                self.init(code: .attestationsUnavailable, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .cloudboardDeadlineExceeded:
                self.init(code: .timeoutError, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .cloudboardResourceExhausted:
                self.init(code: .availabilityError, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .decryptionKeyTimeout:
                self.init(code: .decryptionKeyTimeout, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .featureIdBlocked:
                self.init(code: .featureIdBlocked, debugMessage: debugMessage)
            case .invalidClientOverrideBuildVersion:
                self.init(code: .invalidClientOverrideBuildVersion, debugMessage: debugMessage)
            case .invalidWorkload:
                self.init(code: .invalidWorkload, debugMessage: debugMessage)
            case .maxRequestLifetimeReached:
                self.init(code: .maxRequestLifetimeReached, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .nodeAttestationChanged:
                self.init(code: .nodeAttestationChanged, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .nodesBusy:
                self.init(code: .nodesBusy, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .nodesNotAvailable:
                self.init(code: .noNodesAvailable, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .nodesOverUtilized:
                self.init(code: .nodesOverUtilized, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .notEnoughNodes:
                self.init(code: .notEnoughNodes, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .rateLimitReached:
                self.init(code: .deniedDueToRateLimit, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .requestChunkTimeout:
                self.init(code: .requestChunkTimeout, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .setupRequestTimeout:
                self.init(code: .setupRequestTimeout, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .softwareBlocked:
                self.init(code: .softwareBlocked, debugMessage: debugMessage)
            case .tenantBlocked:
                self.init(code: .tenantBlocked, debugMessage: debugMessage)
            case .unknownWorkload:
                self.init(code: .unknownWorkload, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            case .workloadBlocked:
                self.init(code: .workloadBlocked, debugMessage: debugMessage)
            case .workloadNotFound:
                self.init(code: .workloadNotFound, retryAfterDate: responseMetadata.retryAfterDate, debugMessage: debugMessage)
            default:
                self.init(code: .serverError, telemetrySuffix: telemetrySuffix, debugMessage: debugMessage)
            }
        } else {
            self.init(code: .serverError, telemetrySuffix: telemetrySuffix, debugMessage: debugMessage)
        }
    }
}
