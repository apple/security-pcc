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

import CloudAttestation
import CloudBoardCommon
import CloudBoardIdentity
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import InternalSwiftProtobuf
import os

public protocol TransparencyLog: Sendable {
    func getReleaseSet() async throws -> [ReleaseDigestEntry]
}

enum TransparencyLogError: ReportableError {
    case httpError(statusCode: Int)
    case invalidLeafNodeType
    case notFound
    case invalidRequest
    case internalError

    var publicDescription: String {
        let errorType = switch self {
        case .httpError(let statusCode): "httpsError: statusCode=\(statusCode)"
        case .invalidLeafNodeType: "invalidLeafNodeType"
        case .notFound: "notFound"
        case .invalidRequest: "invalidRequest"
        case .internalError: "internalError"
        }
        return "\(errorType)"
    }
}

final class SWTransparencyLog: TransparencyLog {
    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "SWTransparencyLog"
    )

    let environment: CloudAttestation.Environment
    let identityManager: IdentityManager
    let metadataApplicationNames: [String]
    let retryConfig: CloudBoardAttestationDConfiguration.RetryConfiguration
    let metrics: MetricsSystem

    init(
        environment: CloudAttestation.Environment,
        identityManager: IdentityManager,
        metadataApplicationNames: [String],
        retryConfig: CloudBoardAttestationDConfiguration.RetryConfiguration,
        metrics: MetricsSystem,
    ) {
        self.environment = environment
        self.identityManager = identityManager
        self.metadataApplicationNames = metadataApplicationNames
        self.retryConfig = retryConfig
        self.metrics = metrics
    }

    func getReleaseSet() async throws -> [ReleaseDigestEntry] {
        return try await executeWithRetries(
            retryStrategy: self.createTransparencyLogRetryStrategy(retryConfig: self.retryConfig),
            perRetryTimeout: self.retryConfig.perRetryTimeout

        ) {
            return try await self.metrics.withStatusMetrics(
                total: Metrics.TransparencyLog.TransparencyLogCounter(action: .increment(by: 1)),
                error: Metrics.TransparencyLog.TransparencyLogErrorCounter.Factory()
            ) {
                return try await withErrorLogging(
                    operation: "get_active_release_set",
                    sensitiveError: false,
                    logger: Self.logger
                ) {
                    let url: URL
                    let urlSessionDelegate: URLSessionDelegate?

                    if let identity = try self.identityManager.identityCallback() {
                        final class Delegate: NSObject, URLSessionDelegate {
                            let credential: URLCredential

                            public init(credential: URLCredential) {
                                self.credential = credential
                            }

                            func urlSession(
                                _: URLSession,
                                didReceive _: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?)
                                    -> Void
                            ) {
                                completionHandler(.useCredential, self.credential)
                            }
                        }

                        url = self.environment.authenticatingTransparencyURL
                        urlSessionDelegate = Delegate(credential: identity.credential)
                        Self.logger.debug("Using authenticating transparency log url: \(url, privacy: .public)")
                    } else {
                        url = self.environment.transparencyURL
                        urlSessionDelegate = nil
                        Self.logger.debug("Using non-authenticating transparency log url: \(url, privacy: .public)")
                    }

                    var req = URLRequest(url: url.appending(path: "/at/atl_active_records"))
                    req.httpMethod = "POST"
                    req.setValue("application/protobuf", forHTTPHeaderField: "Content-Type")
                    let activeRecordsReq = PrivateCloudCompute_TransparencyLog_ATActiveRecordsRequest.with { builder in
                        builder.version = .v3
                        builder.application = self.environment
                            .transparencyPrimaryTree ? .privateCloudCompute : .privateCloudComputeInternal
                        builder.type = .release
                        builder.releaseType = [.production, .seed]
                    }
                    req.httpBody = try activeRecordsReq.serializedData()

                    let urlSession = if let urlSessionDelegate {
                        URLSession(configuration: .default, delegate: urlSessionDelegate, delegateQueue: nil)
                    } else {
                        URLSession.shared
                    }
                    defer {
                        urlSession.finishTasksAndInvalidate()
                    }

                    let (data, response) = try await urlSession.data(for: req)

                    let httpResponse = response as! HTTPURLResponse
                    let serverHint = httpResponse.value(forHTTPHeaderField: "x-apple-server-hint")

                    guard httpResponse.statusCode == 200 else {
                        let error = TransparencyLogError.httpError(statusCode: httpResponse.statusCode)
                        TransparencyLogRequestCheckPoint(
                            operationName: "fetch_atl_active_record",
                            httpErrorCode: httpResponse.statusCode,
                            serverHint: serverHint,
                            error: error
                        ).log(to: Self.logger, level: .error)
                        throw error
                    }
                    TransparencyLogRequestCheckPoint(
                        operationName: "fetch_atl_active_record",
                        httpErrorCode: httpResponse.statusCode,
                        serverHint: serverHint
                    ).log(to: Self.logger, level: .info)

                    var releaseSets: [ReleaseDigestEntry] = []
                    let resp = try PrivateCloudCompute_TransparencyLog_ATActiveRecordsResponse(serializedBytes: data)
                    switch resp.status {
                    case .ok:
                        for leaf in resp.leaves {
                            guard leaf.nodeType == .atlNode else {
                                throw TransparencyLogError.invalidLeafNodeType
                            }
                            let leafMetadata = try CloudAttestation
                                .PrivateCloudCompute_ReleaseMetadata(serializedBytes: leaf.metadata)
                            let releaseDigest = leafMetadata.releaseDigest.hexString
                            if !releaseDigest.isEmpty {
                                if !self.metadataApplicationNames.isEmpty,
                                   !self.metadataApplicationNames.contains(leafMetadata.application.name) {
                                    Self.logger.debug(
                                        "Ignoring leaf with application: \(leafMetadata.application.name, privacy: .public)"
                                    )
                                    continue
                                }
                                let expiryDate: Date = if leaf.expiryMs > 0 {
                                    .init(timeIntervalSince1970: TimeInterval(leaf.expiryMs / 1000))
                                } else {
                                    // If the expiryMs field is not set, set the expiry to distant future
                                    .distantFuture
                                }
                                Self.logger.log(
                                    "Adding release digest \(releaseDigest, privacy: .public) with expiration \(expiryDate, privacy: .public) to set."
                                )
                                releaseSets.append(.init(releaseDigestHexString: releaseDigest, expiry: expiryDate))
                            } else {
                                Self.logger.debug(
                                    "Ignoring leaf with empty release digest. \(leafMetadata.debugDescription, privacy: .public)"
                                )
                            }
                        }
                    case .notFound:
                        throw TransparencyLogError.notFound
                    case .invalidRequest:
                        throw TransparencyLogError.invalidRequest
                    default:
                        // Anything else treat as internal error
                        throw TransparencyLogError.internalError
                    }
                    if releaseSets.isEmpty {
                        Self.logger.warning("No proxy node release set returned. Going to set empty releaseSet.")
                    }
                    return releaseSets
                }
            }
        }
    }

    private func createTransparencyLogRetryStrategy(
        retryConfig: CloudBoardAttestationDConfiguration.RetryConfiguration
    ) -> RetryStrategy {
        return RetryWithBackoff(
            backoffStrategy: ExponentialBackoffStrategy(from: retryConfig),
            deadline: retryConfig.timeout.map { .instant(.now + $0) } ?? .noDeadline,
            retryFilter: { error in
                if let tlError = error as? TransparencyLogError {
                    switch tlError {
                    case .httpError, .internalError:
                        self.metrics
                            .emit(Metrics.TransparencyLog.TransparencyLogRetryCounter(action: .increment(by: 1)))
                        Self.logger.error(
                            "Failed to fetch transparency log active records with error: \(String(unredacted: tlError), privacy: .public). Retrying with backoff."
                        )
                        return .continue
                    case .invalidLeafNodeType, .invalidRequest, .notFound:
                        Self.logger.error(
                            "Failed to fetch transparency log active records with error: \(String(unredacted: tlError), privacy: .public). Not retrying."
                        )
                        return .stop
                    }
                } else {
                    self.metrics.emit(Metrics.TransparencyLog.TransparencyLogRetryCounter(action: .increment(by: 1)))
                    Self.logger.error(
                        "Failed to fetch transparency log active records with error: \(String(unredacted: error), privacy: .public). Retrying with backoff."
                    )
                    return .continue
                }
            }
        )
    }
}

extension Data {
    var hexString: String {
        self.compactMap { String(format: "%02x", $0) }.joined()
    }
}

struct TransparencyLogRequestCheckPoint: RequestCheckpoint {
    var requestID: String?

    var operationName: StaticString

    var serviceName: StaticString = "cb_attestationd"

    var namespace: StaticString = "cloudboard"

    var httpErrorCode: Int

    var serverHint: String?

    var error: (any Error)?

    func log(to logger: Logger, level: OSLogType) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        http.errorCode=\(self.httpErrorCode, privacy: .public)
        http.serverHint=\(self.serverHint ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        """)
    }
}
