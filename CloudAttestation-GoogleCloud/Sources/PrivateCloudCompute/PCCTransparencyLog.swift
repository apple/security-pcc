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

//
//  AppleTransparencyLog.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Foundation
#if os(Linux)
import FoundationNetworking
#endif
import Logging
import Metrics

extension Counter {
    static let pccTransparencyLogInclusionFailOpen = Counter(
        label: "cloudattestation_transparency_inclusion_fail_open"
    )
}

public struct PCCTransparencyLog: Sendable, TransparencyProver {
    private static let logger = Logger(label: "com.apple.CloudAttestation.PCCTransparencyLog")

    package let environment: Environment

    public init(environment: Environment) {
        self.environment = environment
    }

    private var failOpen: Bool {
        self.environment <= .production
    }

    public func proveInclusion(
        of digests: [Data],
        at revision: TransparencyLogRevision?,
        coveringAll: ATLogDataType?,
        preferOldest: Bool,
        releaseType: ATReleaseType
    ) async throws -> [Data: ATLogProofs] {
        guard digests.count > 0 else {
            return [:]
        }

        Self.logger.info(
            "Fetching inclusion proofs",
            metadata: [
                "digests": .array(digests.map { .string($0.hexString) }),
                "environment": .stringConvertible(self.environment),
                "failOpen": .stringConvertible(self.failOpen),
            ]
        )

        do {
            let connection = Connection(environment: self.environment)
            var req = URLRequest(url: connection.atlInclusion)
            req.httpMethod = "POST"
            req.setValue("application/protobuf", forHTTPHeaderField: "Content-Type")
            let proofReq = PrivateCloudCompute_TransparencyLog_ATLogProofRequest.with { builder in
                builder.version = .v3
                builder.dataHashes = digests
                builder.application = self.application
                builder.releaseType = releaseType

                if let revision {
                    builder.treeID = revision.treeID
                    builder.revision = revision.revision
                }

                if let coveringAll {
                    builder.coveringAll = coveringAll
                }

                builder.preferOldest = preferOldest
            }
            req.httpBody = try proofReq.serializedData()

            let (data, response) = try await connection.urlSession.data(for: req)

            let httpResponse = response as! HTTPURLResponse
            if let serverHint = httpResponse.value(forHTTPHeaderField: "x-apple-server-hint") {
                Self.logger.info(
                    "Transparency server responded",
                    metadata: [
                        "server": .stringConvertible(connection.url),
                        "statusCode": .stringConvertible(httpResponse.statusCode),
                        "serverHint": .string(serverHint),
                    ]
                )
            }

            guard httpResponse.statusCode == 200 else {
                throw PCCTransparencyLogError.httpError(statusCode: httpResponse.statusCode)
            }

            let resp = try PrivateCloudCompute_TransparencyLog_ATLogProofBatchResponse(serializedBytes: data)
            switch resp.status {
            case .ok:
                guard resp.responses.count == digests.count else {
                    throw PCCTransparencyLogError.requestLimitExceeded(requested: digests.count)
                }
                let proofs = try resp.responses.proofs(for: digests)

                guard failOpen else {
                    return proofs
                }

                Counter.pccTransparencyLogInclusionFailOpen.increment()

                // Backfill empty proofs for digests that the server did not provide so that attestation
                // creation proceeds when failing open.
                return digests.reduce(into: proofs) { result, digest in
                    if result[digest] == nil {
                        result[digest] = ATLogProofs()
                    }
                }

            default:
                throw resp.status.pccTransparencyLogError ?? .internalError
            }
        } catch {
            guard failOpen else {
                throw error
            }

            Self.logger.info(
                "Fetching inclusion proofs failed, but failing open because the configured environment allows so",
                metadata: ["error": .string(String(describing: error))]
            )

            Counter.pccTransparencyLogInclusionFailOpen.increment()
            return Dictionary(digests.map { ($0, ATLogProofs()) }, uniquingKeysWith: { first, _ in first })
        }
    }

    public func proveConsistency(from start: TransparencyLogRevision, to end: TransparencyLogRevision) async throws -> TransparencyLogConsistency {
        Self.logger.info(
            "Fetching consistency proofs",
            metadata: [
                "start": .stringConvertible(start),
                "end": .stringConvertible(end),
                "environment": .stringConvertible(environment),
            ]
        )

        let connection = Connection(environment: environment)
        defer {
            connection.close()
        }

        var req = URLRequest(url: connection.atlConsistency)
        req.httpMethod = "POST"
        req.setValue("application/protobuf", forHTTPHeaderField: "Content-Type")
        let proofReq = PrivateCloudCompute_TransparencyLog_ATLogConsistencyProofRequest.with { builder in
            builder.version = .v3
            builder.treeID = start.treeID
            builder.requestUuid = UUID().uuidString
            builder.requests = [
                .with { request in
                    request.startRevision = start.revision
                    request.endRevision = end.revision
                }
            ]
        }
        req.httpBody = try proofReq.serializedData()

        let (data, response) = try await connection.urlSession.data(for: req)

        let httpResponse = response as! HTTPURLResponse
        if let serverHint = httpResponse.value(forHTTPHeaderField: "x-apple-server-hint") {
            Self.logger.info(
                "Transparency server responded",
                metadata: [
                    "server": .stringConvertible(connection.url),
                    "statusCode": .stringConvertible(httpResponse.statusCode),
                    "serverHint": .string(serverHint),
                ]
            )
        }

        guard httpResponse.statusCode == 200 else {
            throw PCCTransparencyLogError.httpError(statusCode: httpResponse.statusCode)
        }

        let resp = try PrivateCloudCompute_TransparencyLog_ATLogConsistencyProofResponse(serializedBytes: data)
        switch resp.status {
        case .ok:
            guard let logConsistencyResponse = resp.responses.first else {
                Self.logger.error("Transparency server did not return consistency proof")
                throw PCCTransparencyLogError.invalidRequest
            }

            return logConsistencyResponse

        default:
            throw resp.status.pccTransparencyLogError ?? PCCTransparencyLogError.internalError
        }
    }

    package var application: PrivateCloudCompute_TransparencyLog_Application {
        switch self.environment {
        case .staging, .production, .qa2Primary:
            .privateCloudCompute
        default:
            .privateCloudComputeInternal
        }
    }
}

extension PCCTransparencyLog {
    struct Connection {
        let url: URL
        let urlSession: URLSession
        init(environment: Environment) {
            self.url = PCCTransparencyLog.url(for: environment)
            self.urlSession = URLSession.shared
        }

        var atlInclusion: URL {
            self.url.appending(path: "/at/atl_inclusion")
        }

        var atlConsistency: URL {
            self.url.appending(path: "/at/atl_consistency")
        }

        func close() {
            self.urlSession.finishTasksAndInvalidate()
        }
    }

    package static func url(for environment: Environment) -> URL {
        return update(url: "https://kttcc-prod.ess.apple.com", environment: environment)
    }

    package static func authenticatingURL(for environment: Environment) -> URL {
        return update(url: "https://kttcc-internal-prod.ess.apple.com", environment: environment)
    }

    static private func update(url: String, environment: Environment) -> URL {
        switch environment {
        case .qa2Primary, .qa2Internal:
            URL(string: url.replacingOccurrences(of: "prod", with: "qa2"))!
        case .dev, .ephemeral, .perf, .quarantine, .qa, .staging:
            URL(string: url.replacingOccurrences(of: "prod", with: "qa1"))!
        case .carry, .liveon:
            URL(string: url.replacingOccurrences(of: "prod", with: "carry"))!
        case .production:
            URL(string: url)!
        default:
            URL(string: url.replacingOccurrences(of: "prod", with: "qa1"))!
        }
    }
}

extension PrivateCloudCompute_TransparencyLog_Status {
    var pccTransparencyLogError: PCCTransparencyLogError? {
        switch self {
        case .unknownStatus:
            return .unknownStatus
        case .ok:
            return nil
        case .mutationPending:
            return .mutationPending
        case .alreadyExists:
            return .internalError  // Not used for software transparency
        case .internalError:
            return .internalError
        case .invalidRequest:
            return .invalidRequest
        case .notFound:
            return .notFound
        case .UNRECOGNIZED(let int):
            return .unrecognized(status: int)
        }
    }
}

public enum PCCTransparencyLogError: RetryableError {
    case httpError(statusCode: Int)
    case internalError
    case mutationPending
    case invalidRequest
    case notFound
    case invalidProof
    case unknownStatus
    case unrecognized(status: Int)
    case unknown(error: any Error)
    case insertFailed
    case clientError(any Error)
    case expired
    case pendingExpiration(proofsExpiration: Date, expiration: Date)
    case requestLimitExceeded(requested: Int)

    /// Whether an identical request could plausibly succeed if retried after a backoff.
    ///
    /// Only transient failures are retryable: transport errors, gateway/server-side failures, and the
    /// throttling and not-yet-sequenced application statuses. Everything that is deterministic given the
    /// same request — malformed requests, bad proofs, expiration — is not.
    ///
    /// Both transparency endpoints are reads issued as `POST`s, so retrying them is side-effect free.
    public var retryable: Bool {
        switch self {
        case .httpError(let statusCode):
            // Statuses the VIP gateway (or an upstream KT server) returns while transiently unhealthy.
            switch statusCode {
            case 408, 429:
                // Request Timeout, Too Many Requests. A `Retry-After` may have accompanied these; it is not
                // carried on the error, so callers fall back to their own backoff.
                return true
            case 501, 505:
                // Not Implemented, HTTP Version Not Supported: the request itself is unsupported.
                return false
            case 500...599:
                return true
            default:
                return false
            }

        case .internalError:
            // Server-side failure with no further detail; assume transient and let the caller bound retries.
            return true

        case .mutationPending:
            // The digest is in the log but not yet sequenced, so a proof should become available shortly.
            return true

        case .requestLimitExceeded:
            // The server truncated the batch under its own limits; a retry after a backoff can be served.
            return true

        case .unknown(let error), .clientError(let error):
            return Self.isRetryable(error)

        case .insertFailed, .invalidRequest, .notFound, .invalidProof, .unknownStatus, .unrecognized, .expired, .pendingExpiration:
            // Deterministic given the same request: retrying returns the same answer. `notFound` in particular
            // means the digest was never published, which no amount of retrying changes.
            return false
        }
    }

    /// Classifies an error wrapped by ``PCCTransparencyLogError/unknown(error:)`` or
    /// ``PCCTransparencyLogError/clientError(_:)``, which is typically a `URLSession` transport error.
    private static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case let error as PCCTransparencyLogError:
            return error.retryable

        case is CancellationError:
            return false

        case let error as URLError:
            switch error.code {
            case .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .dnsLookupFailed,
                .networkConnectionLost,
                .notConnectedToInternet,
                .badServerResponse,
                .resourceUnavailable,
                .secureConnectionFailed:
                // Connection-level failures, including handshake failures that a proxy blip can cause.
                // Certificate trust failures are deliberately excluded: those are configuration, not transient.
                return true
            default:
                return false
            }

        default:
            return false
        }
    }
}

extension Sequence where Element == PrivateCloudCompute_TransparencyLog_ATLogProofResponse {
    private static var logger: Logger { Logger(label: "com.apple.CloudAttestation.PCCTransparencyLog") }

    /// Correlates a batch inclusion-proof response back to the requested digests.
    ///
    /// Since the batch response carries no ordering guarantee, each entry is matched to its requested
    /// digest via `ATLogProofResponse.dataHash`. The result contains only the digests we got
    /// a usable proof back for: entries with a `notFound`/`mutationPending` status are skipped,
    /// while other non-`ok` statuses and malformed proofs throw.
    func proofs(for digests: [Data]) throws -> [Data: ATLogProofs] {
        let responsesByDigest = Dictionary(self.map { ($0.dataHash, $0) }, uniquingKeysWith: { first, _ in first })

        let pairs = try digests.compactMap { digest -> (Data, ATLogProofs)? in
            guard let response = responsesByDigest[digest] else {
                Self.logger.warning(
                    "No inclusion proof returned for requested digest; skipping",
                    metadata: ["digest": .string(digest.hexString)]
                )
                return nil
            }

            switch response.status {
            case .ok:
                guard response.hasProofs, response.proofs != ATLogProofs() else {
                    throw PCCTransparencyLogError.invalidProof
                }
                return (digest, response.proofs)
            case .notFound, .mutationPending:
                // The digest either isn't in the log or hasn't sequenced yet. Treat this as
                // best-effort: skip it and return whatever proofs we did get.
                Self.logger.warning(
                    "Inclusion proof unavailable for requested digest; skipping",
                    metadata: [
                        "digest": .string(digest.hexString),
                        "status": .string(String(describing: response.status)),
                    ]
                )
                return nil
            default:
                throw response.status.pccTransparencyLogError ?? PCCTransparencyLogError.internalError
            }
        }

        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }
}
