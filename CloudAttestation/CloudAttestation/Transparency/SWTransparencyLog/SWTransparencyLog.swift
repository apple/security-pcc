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
//  SWTransparencyLog.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//
import os.log
import CryptoKit
#if canImport(libnarrativecert)
@_weakLinked internal import libnarrativecert
#endif
import Security
import InternalSwiftProtobuf

typealias ATLogProofs = PrivateCloudCompute_TransparencyLog_ATLogProofs
typealias ATLogProofRequest = PrivateCloudCompute_TransparencyLog_ATLogProofRequest
typealias ATLogProofBatchResponse = PrivateCloudCompute_TransparencyLog_ATLogProofBatchResponse
typealias LogConsistency = PrivateCloudCompute_TransparencyLog_LogConsistency

public struct SWTransparencyLog: TransparencyLog {
    static let logger = Logger(subsystem: "com.apple.CloudAttestation", category: "SWTransparencyLog")

    public let environment: Environment
    let verifier: SWTransparencyVerifier

    public init(environment: Environment) {
        self.environment = environment
        self.verifier = SWTransparencyVerifier()
    }

    public func proveInclusion(of digests: [Data]) async throws -> [TransparencyLogProofs] {
        guard digests.count > 0 else {
            return []
        }

        Self.logger.log("Fetching inclusion proofs for digests \(digests.map { $0.hexString }, privacy: .public)")

        let url: URL
        let urlSessionDelegate: URLSessionDelegate?

        if let credential = try? self.loadNarrativeCredential() {
            final class Delegate: NSObject, URLSessionDelegate {
                let credential: URLCredential

                public init(credential: URLCredential) {
                    self.credential = credential
                }

                func urlSession(
                    _ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
                ) {
                    completionHandler(.useCredential, credential)
                }
            }

            url = environment.authenticatingTransparencyURL
            urlSessionDelegate = Delegate(credential: credential)
            Self.logger.log("Using authenticating transparency log url: \(url, privacy: .public)")
        } else {
            url = environment.transparencyURL
            urlSessionDelegate = nil
            Self.logger.log("Using non-authenticating transparency log url: \(url, privacy: .public)")
        }

        var req = URLRequest(url: url.appending(path: "/at/atl_inclusion"))
        req.httpMethod = "POST"
        req.setValue("application/protobuf", forHTTPHeaderField: "Content-Type")
        let proofReq = ATLogProofRequest.with { builder in
            builder.version = .v3
            builder.dataHashes = digests
            builder.application = self.environment.transparencyPrimaryTree ? .privateCloudCompute : .privateCloudComputeInternal
        }
        req.httpBody = try proofReq.serializedData()

        let urlSession: URLSession
        if let urlSessionDelegate {
            urlSession = URLSession(configuration: .default, delegate: urlSessionDelegate, delegateQueue: nil)
        } else {
            urlSession = URLSession.shared
        }
        defer {
            if urlSessionDelegate != nil {
                urlSession.finishTasksAndInvalidate()
            }
        }

        let (data, response) = try await urlSession.data(for: req)

        let httpResponse = response as! HTTPURLResponse
        if let serverHint = httpResponse.value(forHTTPHeaderField: "x-apple-server-hint") {
            Self.logger.log(
                "Transparency server \(url, privacy: .public) responded with status \(httpResponse.statusCode, privacy: .public), server hint \(serverHint, privacy: .public)"
            )
        }

        guard httpResponse.statusCode == 200 else {
            throw TransparencyLogError.httpError(statusCode: httpResponse.statusCode)
        }

        let resp = try ATLogProofBatchResponse(serializedBytes: data)
        switch resp.status {
        case .ok:
            guard resp.responses.count == digests.count else {
                throw TransparencyLogError.requestLimitExceeded(requested: digests.count)
            }

            return try resp.responses.map {
                guard $0.status == .ok else {
                    throw $0.status.transparencyLogError ?? .internalError
                }

                guard $0.hasProofs, $0.proofs != ATLogProofs() else {
                    throw TransparencyLogError.invalidProof
                }

                return TransparencyLogProofs(proofs: $0.proofs, expiry: Int64($0.expiryMs), digest: $0.dataHash)
            }

        default:
            throw resp.status.transparencyLogError ?? .internalError
        }
    }

    public func verifyExpiringInclusion(of digest: Data, proofs: TransparencyLogProofs) async throws -> Date {
        return try await self.verifier.verifyExpiringInclusion(of: digest, proofs: proofs)
    }

    func loadNarrativeCredential() throws -> URLCredential {
        #if canImport(libnarrativecert)
        guard #_hasSymbol(NarrativeCert.self) else {
            Self.logger.error("Narrative is not available on this OS")
            throw TransparencyLogError.clientError(Error.narrativeUnsupported)
        }

        // first try and get the acdc domain identity
        let acdc = NarrativeCert(domain: .acdc, identityType: .actor)
        if let credential = acdc.getCredential() {
            return credential
        }

        // fallback to adb
        let adb = NarrativeCert(domain: .adb, identityType: .actor)
        if let credential = adb.getCredential() {
            return credential
        }

        Self.logger.error("Unable to load acdc or adb narrative identity")
        throw TransparencyLogError.clientError(Error.noAvailableNarrativeIdentities)
        #else
        Self.logger.error("Narrative is not available on SDK")
        throw TransparencyLogError.clientError(Error.narrativeUnsupported)
        #endif
    }
}

extension Status {
    var transparencyLogError: TransparencyLogError? {
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
