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
//  RopesResponseMetadata.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation

// We use this to package up the response data that the daemon collects into one
// piece that we can reason about here while we are forming errors.
package struct RopesResponseMetadata: Sendable, Codable {
    /// HTTP response status code (200 OK, 404 NOT FOUND, etc)
    package var code: Code?

    /// gRPC-style response status code (0 OK, 8 RESOURCE\_EXHAUSED, etc)
    package var status: StatusCode?

    /// ROPES-defined error code (1001 INVALID\_WORKLOAD, 4000 UNKNOWN\_WORKLOAD, etc)
    package var receivedErrorCode: OptionalCode<ErrorCode>?

    /// A description of the error
    package var errorDescription: String?

    /// A description of the cause of the error
    package var cause: String?

    /// For retryable errors, a TimeInterval (`retry-after` metadata)
    package var retryAfter: TimeInterval?

    /// For Tap-to-radar (TTR) indications from server, some TTR metadata
    package var ttrTitle: String?
    package var ttrDescription: String?
    package var ttrComponentID: String?
    package var ttrComponentName: String?
    package var ttrComponentVersion: String?

    /// Component time measurements from ROPES (can have multiple values)
    package var componentTimeMeasurements: [String] = []

    // This is for computing retryAfterDate--we need to know when we got the
    // error, it is like creationDate.
    private var now: Date

    package init(now: Date = Date.now, code: Int) {
        self.code = Code(rawValue: code)
        self.now = now
    }

    package var loggingDescription: String {
        """
        <RopesResponseMetadata
            code: \(nilStringIfNil(code))
            status: \(nilStringIfNil(status))
            receivedErrorCode: \(nilStringIfNil(receivedErrorCode))
            cause: \(nilStringIfNil(cause))
            retryAfter: \(nilStringIfNil(retryAfter))
            ttrTitle: \(nilStringIfNil(ttrTitle))
            ttrDescription: \(nilStringIfNil(ttrDescription))
            ttrComponentID: \(nilStringIfNil(ttrComponentID))
            ttrComponentName: \(nilStringIfNil(ttrComponentName))
            ttrComponentVersion: \(nilStringIfNil(ttrComponentVersion))
            componentTimeMeasurements: \(componentTimeMeasurements)
            now: \(now)
        >
        """
    }

    package mutating func set(value: String, for key: String) {
        switch key {
        case "status":
            self.status = Int(value).flatMap(StatusCode.init(rawValue:))
        case "error-code":
            self.receivedErrorCode = Int(value).flatMap(OptionalCode<ErrorCode>.init(rawValue:))
        case "description":
            self.errorDescription = value
        case "cause":
            self.cause = value
        case "retry-after":
            self.retryAfter = TimeInterval(value)
        case "ttr-title":
            self.ttrTitle = value
        case "ttr-description":
            self.ttrDescription = value
        case "ttr-component-id":
            self.ttrComponentID = value
        case "ttr-component-name":
            self.ttrComponentName = value
        case "ttr-component-version":
            self.ttrComponentVersion = value
        case "apple-component-time-measurement":
            self.componentTimeMeasurements.append(value)
        default:
            break
        }
    }

    package var isError: Bool {
        return self.code != .ok || self.status != .ok || self.receivedErrorCode != .code(.success)
    }

    // We use this to know whether to set a rate limit. Because many errors allow
    // retry but without applying a new RateLimitConfig across the board.
    package var isAvailabilityConcern: Bool {
        if case .code(let errorCode) = self.receivedErrorCode {
            switch errorCode {
            case .rateLimitReached,
                .unknownWorkload,
                .nodesNotAvailable,
                .nodesBusy:
                return true
            default:
                break
            }
        }

        if let status = self.status {
            switch status {
            case .resourceExhausted, .unavailable:
                return true
            default:
                break
            }
        }

        switch self.code {
        case .serviceUnavailable, .tooManyRequests:
            return true
        default:
            return false
        }
    }

    // A request is always retryable if a retry-after header is present
    // In the absence of retry-after header, the list of errors that are retryable are:
    //     DEADLINE_EXCEEDED (4), SETUP_REQUEST_TIMEOUT (2000)
    //     DEADLINE_EXCEEDED (4), DECRYPTION_KEY_TIMEOUT (2001)
    //     DEADLINE_EXCEEDED (4), CLOUDBOARD_DEADLINE_EXCEEDED (5004)
    //     PERMISSION_DENIED (7), NODE_ATTESTATION_CHANGED (7000)
    //     PERMISSION_DENIED (7), MISSING_ONE_TIME_TOKEN (7001)
    //     PERMISSION_DENIED (7), CLOUDBOARD_OTT_PERMISSION_DENIED (7002)
    //     PERMISSION_DENIED (7), INVALID_ONE_TIME_TOKEN (7003)
    //     RESOURCE_EXHAUSTED (8), CLOUDBOARD_RESOURCE_EXHAUSTED (5008)
    //     UNAVAILABLE (14), UNKNOWNWORKLOAD (4000)
    //     UNAVAILABLE (14), NODES_NOT_AVAILABLE (4001)
    //     UNAVAILABLE (14), NODES_BUSY (4002)

    package var retryAfterDate: Date {
        if let retryAfter = self.retryAfter {
            return self.now + retryAfter
        } else {
            return self.now
        }
    }

    package var retryable: Bool {
        if self.retryAfter != nil {
            return true
        }

        if case .code(let errorCode) = self.receivedErrorCode {
            switch errorCode {
            case .setupRequestTimeout,
                .decryptionKeyTimeout,
                .rateLimitReached,
                .unknownWorkload,
                .nodesNotAvailable,
                .nodesBusy,
                .cloudboardDeadlineExceeded,
                .cloudboardResourceExhausted,
                .nodeAttestationChanged,
                .missingOneTimeToken,
                .cloudboardOttPermissionDenied,
                .invalidOneTimeToken:
                return true
            default:
                break
            }
        }

        if let status = self.status {
            switch status {
            case .deadlineExceeded,
                .resourceExhausted,
                .unavailable:
                return true
            default:
                break
            }
        }

        switch self.code {
        case .requestTimeout,
            .tooManyRequests,
            .serviceUnavailable:
            return true
        default:
            break
        }

        return false
    }

    package enum StatusCode: Int, Sendable, Codable {
        case ok = 0
        case cancelled = 1
        case unknown = 2
        case invalidArgument = 3
        case deadlineExceeded = 4
        case notFound = 5
        case alreadyExists = 6
        case permissionDenied = 7
        case resourceExhausted = 8
        case failedPrecondition = 9
        case aborted = 10
        case outOfRange = 11
        case unimplemented = 12
        case `internal` = 13
        case unavailable = 14
        case dataLoss = 15
        case unauthenticated = 16
    }

    package enum ErrorCode: Int, Sendable, Codable {
        case success = 0

        // Errors 1XXX: missing/invalid/unexpected request parameter
        case unexpectedContentType = 1000
        case invalidWorkload = 1001
        case missingWorkload = 1002
        case missingBundleId = 1003
        case missingFeatureId = 1004
        case missingClientInfo = 1005
        case setupRequestDuplicate = 1006
        case setupRequestInvalidContext = 1007
        case setupRequestConflictingContext = 1008
        case invalidProtobuf = 1009
        case requestChunkBufferOverflow = 1010
        case invalidTestOptions = 1011
        case unknownChunkContext = 1012
        case rateLimitsInvalidRequestType = 1013
        case invalidClientInfo = 1014
        case unauthorizedTestOptions = 1015
        case invalidClientOverrideBuildVersion = 1016
        case invalidRoutingGroupAlias = 1017
        case invalidTrustedProxyRoutingGroupAlias = 1018
        case missingGroupId = 1019

        // Errors 2XXX: timeout
        case setupRequestTimeout = 2000
        case decryptionKeyTimeout = 2001
        case maxRequestLifetimeReached = 2002
        case requestChunkTimeout = 2003
        case trustedProxyPickTimeout = 2004

        // Errors 3XXX: throttling
        case rateLimitReached = 3000
        case tenantBlocked = 3001
        case softwareBlocked = 3002
        case workloadBlocked = 3003
        case featureIdBlocked = 3004

        // Errors 4XXX: load balancing errors
        case unknownWorkload = 4000
        case nodesNotAvailable = 4001
        case nodesBusy = 4002
        case nodesOverUtilized = 4003
        case workloadNotFound = 4004
        case attestationsUnavailable = 4005
        case trustedProxyNotFound = 4006
        case trustedProxyIncompatibleTrains = 4007
        case resourceExhaustedDiscardable = 4008
        case notEnoughNodes = 4009

        // Errors 5XXX: CloudBoard errors
        case cloudboardUnknownError = 5002
        case cloudboardInvalidArgument = 5003
        case cloudboardDeadlineExceeded = 5004
        case cloudboardResourceExhausted = 5008
        case cloudboardInternalError = 5013

        // Errors 6XXX: other
        case internalServerError = 6000
        case cancelled = 6001
        case clientTerminated = 6002

        // Errors 7XXX: Unauthorized
        case nodeAttestationChanged = 7000
        case missingOneTimeToken = 7001
        case cloudboardOttPermissionDenied = 7002
        case invalidOneTimeToken = 7003
        case duplicatedOneTimeToken = 7004

        // Errors 8XXX: Trusted Proxy
        case proxyInternalError = 8000
    }

    package enum Code: Int, Sendable, Codable {
        // Informational
        case `continue` = 100
        case switchingProtocols = 101
        case processing = 102
        case earlyHints = 103

        // Successful
        case ok = 200
        case created = 201
        case accepted = 202
        case nonAuthoritativeInformation = 203
        case noContent = 204
        case resetContent = 205
        case partialContent = 206

        // Redirection
        case multipleChoices = 300
        case movedPermanently = 301
        case found = 302
        case seeOther = 303
        case notModified = 304
        case temporaryRedirect = 307
        case permanentRedirect = 308

        // Client Error
        case badRequest = 400
        case unauthorized = 401
        case forbidden = 403
        case notFound = 404
        case methodNotAllowed = 405
        case notAcceptable = 406
        case proxyAuthenticationRequired = 407
        case requestTimeout = 408
        case conflict = 409
        case gone = 410
        case lengthRequired = 411
        case preconditionFailed = 412
        case contentTooLarge = 413
        case uriTooLong = 414
        case unsupportedMediaType = 415
        case rangeNotSatisfiable = 416
        case expectationFailed = 417
        case misdirectedRequest = 421
        case unprocessableContent = 422
        case upgradeRequired = 426
        case preconditionRequred = 428
        case tooManyRequests = 429
        case requestHeaderFieldsTooLarge = 431

        // Server Error
        case internalServerError = 500
        case notImplemented = 501
        case badGateway = 502
        case serviceUnavailable = 503
        case gatewayTimeout = 504
        case httpVersionNotSupported = 505
    }
}

package func nilStringIfNil<T>(_ x: T?) -> String {
    x.map(String.init(describing:)) ?? "nil"
}
