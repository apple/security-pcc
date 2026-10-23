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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import CloudAttestation
import Foundation
import os

// allow ArgumentParser to map it to command-line arg
extension CloudAttestation.Environment: @retroactive ExpressibleByArgument {}

// TransparencyLog provides methods to retrieve log entries from KT Auditor log
struct TransparencyLog: Sendable {
    typealias Environment = CloudAttestation.Environment

    
    var ktInitURL: URL? {
        switch self.environment {
            case .production: return URL.normalized(string: "init-kt-prod.ess.apple.com")
            case .carry: return URL.normalized(string: "init-kt-carry.ess.apple.com")
            case .qa, .staging: return URL.normalized(string: "init-kt-qa1.ess.apple.com")
            case .qa2Primary, .qa2Internal: return URL.normalized(string: "init-kt-qa2.ess.apple.com")
            default: return nil
        }
    }

    var application: TxPB_Application {
        self.environment.transparencyPrimaryTree ? .privateCloudCompute : .privateCloudComputeInternal
    }

    // supported protocol version of Transparency Log requests
    static let protocolVersion = TxPB_ProtocolVersion.v3

    static let atLogType: TxPB_LogType = .atLog
    static let requestUUIDHeader = "X-Apple-Request-UUID"
    static let serverHintHeader = "x-apple-server-hint"

    static let logger = os.Logger(subsystem: applicationName, category: "TransparencyLog")
    static var traceLog: Bool = false // include (excessive) debugging messages of Transparency Log calls

    let environment: Environment
    let instanceUUID: UUID // passed into upstream API (for logging)
    var ktInitBag: KTInitBag? // KT Init Bag (links to Transparency endpoints for selected env/application)
    var useIdentity: Bool { self.environment != .production } // for mTLS

    init(
        environment: Environment,
        altKtInitEndpoint: URL? = nil,
        loadKtInitBag: Bool = true,
        traceLog: Bool = false
    ) async throws {
        self.environment = environment
        self.instanceUUID = UUID()

        TransparencyLog.traceLog = traceLog
        let uuidString = self.instanceUUID.uuidString
        TransparencyLog.logger.debug("Session UUID: \(uuidString, privacy: .public)")

        // load KTInitBag for the other endpoints
        if loadKtInitBag {
            guard let endpoint = altKtInitEndpoint ?? self.ktInitURL else {
                throw TransparencyLogError("must provide KT Init Bag endpoint")
            }

            TransparencyLog.logger.debug("Using KT Init endpoint: \(endpoint.absoluteString, privacy: .public)")

            do {
                self.ktInitBag = try await KTInitBag(
                    endpoint: endpoint,
                    useIdentity: self.useIdentity
                )
            } catch {
                throw TransparencyLogError("Fetch KT Init Bag: \(error)")
            }

            if traceLog {
                self.ktInitBag?.debugDump()
            }
        }
    }

    // urlGet performs a simple GET request against url and returns payload; throws an error
    //  if request fails, doesn't obtain a 2xx response, or doesn't match provided mimeType
    static func urlGet(
        url: URL,
        useIdentity: Bool = false,
        timeout: TimeInterval = 15,
        headers: [String: String]? = nil,
        mimeType: String? = nil
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        TransparencyLog.addRequestHeaders(&request, headers: headers)

        return try await TransparencyLog.urlRequest(
            request: request,
            useIdentity: useIdentity,
            contentType: mimeType
        )
    }

    // urlPostProtbuf performs a POST request against url with requestBody containing a serialized protobuf
    //  and returns (serialized protobuf) payload; throws an error if request fails, doesn't obtain a
    //  2xx response, or response content type != "application/protobuf"
    static func urlPostProtbuf(
        url: URL,
        useIdentity: Bool = false,
        requestBody: Data,
        timeout: TimeInterval = 15,
        headers: [String: String]? = nil
    ) async throws -> (Data, URLResponse) {
        let pbContentType = "application/protobuf"

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(pbContentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody
        TransparencyLog.addRequestHeaders(&request, headers: headers)

        return try await TransparencyLog.urlRequest(
            request: request,
            useIdentity: useIdentity,
            contentType: pbContentType
        )
    }

    // addRequestHeaders sets headers in the URL request
    static func addRequestHeaders(_ request: inout URLRequest, headers: [String: String]? = nil) {
        if let headers {
            for (h, v) in headers {
                request.addValue(v, forHTTPHeaderField: h)
            }
        }
    }

    // urlRequest issues populated request to endpoint and returns payload and response if status code 2xx is
    //  received and (if contantType is set) confirms mimeType in payload matches expected.
    static func urlRequest(
        request: URLRequest,
        useIdentity: Bool = false,
        contentType: String? = nil,
        rateLimitStart: Duration = .milliseconds(100),
        rateLimitMax: Duration = .milliseconds(1000)
    ) async throws -> (Data, URLResponse) {
        // Always install a delegate to handle TLS authentication challenges. Even when we are not
        // performing mTLS, we must explicitly decline client-certificate requests; otherwise the
        // default handling causes the system to auto-select a matching identity from the keychain,
        // which production KT servers reject.
        let session = URLSession(configuration: .default,
                                 delegate: TransparencyLog.MutualTLSDelegate(
                                     identityProvider: useIdentity ? AnyIdentityProvider() : nil),
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var retryWait = rateLimitStart // x2 upto rateLimitMax
        var retryLogDeadline = Date(timeIntervalSinceNow: 0) // emit log when expire
        let retryLogEverySec: Double = 10 // .. and every # sec

        while true {
            let (respData, response) = try await session.data(for: request)
            TransparencyLog.dumpURLResponse(response: response)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse, userInfo: ["reason": "failed to get response"])
            }

            if let hint = httpResponse.value(forHTTPHeaderField: TransparencyLog.serverHintHeader) {
                let reqURL = request.url?.absoluteString ?? "[url unknown]"
                TransparencyLog.logger.log("\(reqURL, privacy: .public) responded with HTTP \(httpResponse.statusCode): server hint: \(hint, privacy: .public)")
            }

            // server reported rate limit exceeded
            if httpResponse.statusCode == 429 {
                if Date() > retryLogDeadline {
                    let reqHost = request.url?.host() ?? "[host unknown]"
                    TransparencyLog.logger.log("\(reqHost, privacy: .public): throttling requests due to rate limit")
                    retryLogDeadline = Date(timeIntervalSinceNow: retryLogEverySec)
                }

                try? await Task.sleep(for: retryWait)
                retryWait = max(retryWait * 2, rateLimitMax)
                continue
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse,
                               userInfo: ["reason": "request failed (error: \(httpResponse.statusCode))"])
            }

            if let contentType {
                guard httpResponse.mimeType == contentType else {
                    throw URLError(.cannotParseResponse,
                                   userInfo: ["reason": "request returned contentType=\(httpResponse.mimeType ?? "unset")"])
                }
            }

            return (respData, response)
        }
    }

    // dumpURLResponse outputs contents of response from a URLSession call to debug log channel (trace level)
    private static func dumpURLResponse(response: URLResponse) {
        guard TransparencyLog.traceLog else {
            return
        }

        func _dlog(_ msg: String) {
            TransparencyLog.logger.debug("\(msg, privacy: .public)")
        }

        _dlog("URL Response:")
        _dlog("  URL: \(response.url?.absoluteString ?? "unset")")
        _dlog("  mimeType: \(response.mimeType ?? "unset")")
        _dlog("  expectedContentLength: \(response.expectedContentLength)")
        if let suggestedFilename = response.suggestedFilename {
            _dlog("  suggestedFilename: \(suggestedFilename)")
        }
        if let textEncodingName = response.textEncodingName {
            _dlog("  textEncodingName: \(textEncodingName)")
        }

        if let httpResponse = response as? HTTPURLResponse {
            _dlog("  Status: \(httpResponse.statusCode)")
            _dlog("  Headers:")
            for (h, v) in httpResponse.allHeaderFields {
                _dlog("    \(h as? String): \(v as? String)")
            }
        }
    }

    // MutualTLSDelegate is a URLSessionDelegate to provide mutual TLS backed by Apple Narrative identity certs.
    // When identityProvider is nil (or yields no identity), client-certificate challenges are explicitly
    // declined so the system does not auto-select an unrelated identity from the keychain.
    private class MutualTLSDelegate: NSObject, URLSessionDelegate {
        let identityProvider: IdentityProvider?

        init(identityProvider: IdentityProvider?) {
            self.identityProvider = identityProvider
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            if let identity = identityProvider?.identity {
                TransparencyLog.logger.debug("using identity certificate for mTLS request")
                completionHandler(.useCredential,
                                  URLCredential(identity: identity,
                                                certificates: identity.intermediateCertificateAuthorities,
                                                persistence: .forSession))
            } else {
                if identityProvider != nil {
                    TransparencyLog.logger.error("mTLS requested but no identity available")
                }
                // Send no client certificate. Using .useCredential with a nil credential continues the
                // handshake without offering a cert and, crucially, prevents the system from picking one
                // out of the keychain (which .performDefaultHandling would do).
                completionHandler(.useCredential, nil)
            }
        }
    }
}

// functions to collect layers to get us to enumerating log leaves for this instance
extension TransparencyLog {
    // fetchPubkeys retrieves public keys used to verify signature of Top Level trees
    @discardableResult
    func fetchPubkeys(altEndpoint: URL? = nil) async throws -> PublicKeys {
        guard let endpoint = altEndpoint ?? ktInitBag?.url(.atResearcherPublicKeys) else {
            throw TransparencyLogError("must provide Public Keys endpoint")
        }

        let dbgEndpoint = "\(endpoint.absoluteString)\(self.useIdentity ? " [useIdentity=true]" : "")"
        TransparencyLog.logger.debug("Using KT Public Keys endpoint: \(dbgEndpoint, privacy: .public)")
        do {
            let pubKeys = try await PublicKeys(
                endpoint: endpoint,
                useIdentity: self.useIdentity,
                requestUUID: self.instanceUUID
            )

            return pubKeys
        } catch {
            throw TransparencyLogError("Fetch Public Keys: \(error)")
        }
    }

    // fetchLogTree retrieves top-level trees and selects active one for Private Cloude Compute application
    @discardableResult
    func fetchLogTree(
        logType: TxPB_LogType = Self.atLogType,
        application: TxPB_Application? = nil,
        altEndpoint: URL? = nil
    ) async throws -> Tree {
        guard let endpoint = altEndpoint ?? ktInitBag?.url(.atResearcherListTrees) else {
            throw TransparencyLogError("must provide List Keys endpoint")
        }

        let dbgEndpoint = "\(endpoint.absoluteString)\(self.useIdentity ? " [useIdentity=true]" : "")"
        TransparencyLog.logger.debug("Using KT List Trees endpoint: \(dbgEndpoint, privacy: .public)")

        var logTrees: TransparencyLog.Trees
        do {
            logTrees = try await Trees(
                endpoint: endpoint,
                useIdentity: self.useIdentity,
                requestUUID: self.instanceUUID
            )
        } catch {
            throw TransparencyLogError("Fetch Log Trees: \(error)")
        }

        if TransparencyLog.traceLog {
            logTrees.debugDump()
        }

        guard let relTree = logTrees.select(
            logType: logType,
            application: application ?? self.application
        ) else {
            throw TransparencyLogError("PCC Log Tree not found [\(application ?? self.application)]")
        }

        TransparencyLog.logger.debug("Using Private Cloud Tree ID [\(relTree.treeID, privacy: .public)]")
        return relTree
    }

    // fetchLogHead retrieves the log head of the application ("releases") tree
    @discardableResult
    func fetchLogHead(
        logTree: Tree,
        useCache: Bool = false,
        altEndpoint: URL? = nil
    ) async throws -> Head {
        guard let endpoint = altEndpoint ?? ktInitBag?.url(.atResearcherLogHead) else {
            throw TransparencyLogError("must provide Log Head endpoint")
        }

        let dbgEndpoint = "\(endpoint.absoluteString)\(self.useIdentity ? " [useIdentity=true]" : "")"
        TransparencyLog.logger.debug("Using Log Head endpoint: \(dbgEndpoint, privacy: .public)")

        do {
            let relLogHead = try await Head(
                endpoint: endpoint,
                useIdentity: self.useIdentity,
                logTree: logTree,
                appCerts: nil, 
                requestUUID: self.instanceUUID
            )
            if TransparencyLog.traceLog {
                TransparencyLog.logger.debug("LogHead: log size: \(relLogHead.size, privacy: .public); revision: \(relLogHead.revision, privacy: .public)")
            }
            return relLogHead
        } catch {
            throw TransparencyLogError("Fetch Log Head for PCC: \(error)")
        }
    }

    // MARK: - Generic leaf retrieval

    func fetchLogLeaves<L: Leaf>(type: L.Type,
                                 tree: Tree,
                                 start: UInt64? = nil,
                                 end: UInt64? = nil,
                                 dataType: TxPB_ATLogDataType? = nil) async throws -> [L]
    {
        try await self.fetchLogLeaves(type: type,
                                      tree: tree,
                                      head: self.fetchLogHead(logTree: tree),
                                      start: start,
                                      end: end,
                                      dataType: dataType)
    }

    func fetchLogLeaves<L: Leaf>(type: L.Type,
                                 tree: Tree,
                                 head: Head,
                                 start: UInt64? = nil,
                                 end: UInt64? = nil,
                                 batchSize: UInt64 = 3000,
                                 dataType: TxPB_ATLogDataType? = nil,
                                 altEndpoint: URL? = nil) async throws -> [L]
    {
        guard let endpoint = altEndpoint ?? ktInitBag?.url(.atResearcherLogLeaves) else {
            throw TransparencyLogError("must provide Log Leaves endpoint")
        }

        let dbgEndpoint = "\(endpoint.absoluteString)\(self.useIdentity ? " [useIdentity=true]" : "")"
        TransparencyLog.logger.debug("Using Log Leaves endpoint: \(dbgEndpoint, privacy: .public)")

        let maxIndex = head.size
        let endIndex = UInt64(min(maxIndex, end ?? maxIndex))
        let startIndex: UInt64 = start ?? 0

        guard startIndex < endIndex else {
            return []
        }

        let logLeaves = TransparencyLog.Leaves(
            endpoint: endpoint,
            useIdentity: self.useIdentity,
            logTree: tree
        )

        var outLeaves: [L] = []
        var currentStart = startIndex
        var currentEnd = min(startIndex + batchSize, endIndex)
        repeat {
            do {
                let leaves = try await logLeaves.fetch(startIndex: currentStart,
                                                       endIndex: currentEnd,
                                                       dataType: dataType,
                                                       requestUUID: self.instanceUUID,
                                                       nodeDecoder: {
                                                           guard let leaf = L($0) else {
                                                               return nil as L?
                                                           }
                                                           return leaf as L?
                                                       })
                outLeaves.append(contentsOf: leaves)
                currentStart += batchSize
                currentEnd = min(currentEnd + batchSize, endIndex)
            } catch {
                throw TransparencyLogError("fetch log entries [\(startIndex)..<\(endIndex) (current_end: \(currentEnd))] for PCC: \(error)")
            }
        } while currentStart < currentEnd

        return outLeaves
    }
}

// TransparencyLogError provides general error encapsulation for errors encountered when interacting
//  with the TransparencyLog
struct TransparencyLogError: Error, CustomStringConvertible {
    var message: String
    var description: String { self.message }

    init(_ message: String) {
        TransparencyLog.logger.error("\(message, privacy: .public)")
        self.message = message
    }
}
