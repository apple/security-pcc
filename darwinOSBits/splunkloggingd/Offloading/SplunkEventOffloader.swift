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
//  SplunkEventOffloader.swift
//  splunkloggingd
//
//  Copyright © 2024 Apple, Inc.  All rights reserved.
//

import Foundation
import LoggingSupport
import os
import AtomicsInternal
import libnarrativecert
import notify

fileprivate let log = Logger(subsystem: sharedSubsystem, category: "SplunkEventOffloader")

fileprivate let kNotificationFailureName = CFNotificationName("com.apple.splunkloggingd.postFailure" as CFString)
fileprivate func postFailureNotification() {
    #if os(iOS)
    // Only one per process, always returns the same center
    guard let center = CFNotificationCenterGetDarwinNotifyCenter() else {
        return
    }
    CFNotificationCenterPostNotification(center,
                                         kNotificationFailureName,
                                         nil, // Sender. We can ignore this
                                         nil, // Ignored by darwin notification centers
                                         false // Ignored by darwin notification centers
    )
    #endif // os(iOS)
}

enum SplunkEventOffloaderError: Error {
    case invalidSplunkURL
}

typealias httpPostMethod_t = (_ request: URLRequest) async throws -> (Data, URLResponse)

fileprivate final class MTLSURLSessionDelegate: NSObject, URLSessionDelegate {
    public let cred: URLCredential?
    public let insecure: Bool
    public init(cred: URLCredential?, insecure: Bool) {
        self.cred = cred
        self.insecure = insecure
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let isClientCert = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate
        let isServerTrust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        
        if (isClientCert) {
            completionHandler(.useCredential, cred )
        } else if (isServerTrust && insecure ) {
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil);
                return
            }
            let urlCredential = URLCredential(trust: trust)
            completionHandler(.useCredential, urlCredential);
        } else {
            completionHandler(.performDefaultHandling, nil);
        }
    }
}

// MARK: SplunkBufferDelegate
actor SplunkEventOffloader {
    let jsonEndpoint: URL
    let token: UUID?

    var refreshEventRecieved: Bool = true
    var acdcActorURLSession: URLSession?

    // By making this a static var, we can mock it from our tests
    // This post method is used when token is provided.
    static var httpPostWithToken: httpPostMethod_t = URLSession.shared.data
    
    // This post method is used when token is not present, in which case the post will
    // be done using the URL credential created from acdc actor cert.
    private func httpPostWithAcdcActorCert(_ request: URLRequest) async throws -> (Data, URLResponse)
    {
        if (refreshEventRecieved) {
            log.log("Refreshing acdc actor cert.")
            let cert = NarrativeCert(domain: .acdc, identityType: .actor)
            let cred = cert.getCredential()
            let delegate = MTLSURLSessionDelegate(cred: cred, insecure: false)
            acdcActorURLSession?.finishTasksAndInvalidate()
            acdcActorURLSession = URLSession(configuration:URLSessionConfiguration.default, delegate: delegate, delegateQueue: nil)

            refreshEventRecieved = false
            var notifyToken: Int32 = 0;
            notify_register_dispatch(cert.refreshedNotificationName, &notifyToken, DispatchQueue.global(qos: .utility)) { _ in
                notify_cancel(notifyToken)
                log.log("Received acdc cert expiry notification.")
                self.refreshEventRecieved = true
            }
        }

        return try await acdcActorURLSession!.data(for: request)
    }

    // MARK: Offload Methods
    private func offload(event: SplunkEvent) async {
        let incoming = event.data()
        guard !incoming.isEmpty else {
            return
        }

        let sourcetype = String(describing: event)
        var requestEndpoint = jsonEndpoint
        let size = UInt64(incoming.count)
        let maxRetries = 5
        var attempts = 0

        Statistics.shared.totalBytes += size

        Statistics.shared.minimumBytes.withLock { minimumBytes in
            minimumBytes = min(size, minimumBytes)
        }
        Statistics.shared.maximumBytes.withLock { maximumBytes in
            maximumBytes = max(size, maximumBytes)
        }

        requestEndpoint.append(queryItems: [URLQueryItem(name: "sourcetype", value: sourcetype)])
        
        // set host to hostname of device
        let hostID = getHostName()
        requestEndpoint.append(queryItems: [URLQueryItem(name: "host", value: hostID)])
        
        var request = URLRequest(url: requestEndpoint)
        request.httpMethod = "POST"
        request.httpBody = incoming
        
        log.info("sending HTTP POST: \(request, privacy: .public)")
        log.debug("body: \(urlReqToString(request), privacy: .public)")
        
        while attempts < maxRetries {
            do { try await Task.sleep(for: .milliseconds(125 * attempts)) } catch { return }
            Statistics.shared.httpRequests += 1
            do {
                var data: Data
                var response: URLResponse
                if let token = token {
                    log.debug("Auth: using token")
                    request.allHTTPHeaderFields = ["Authorization": "Splunk \(token.uuidString)"]
                    (data,response) = try await SplunkEventOffloader.httpPostWithToken(request)
                } else {
                    log.debug("Auth: using acdc actor cert")
                    (data,response) = try await httpPostWithAcdcActorCert(request)
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "SplunkEventOffloader", code: 1, userInfo: [NSLocalizedFailureErrorKey:"Unexpected URL Response type"])
                }

                let status = httpResponse.statusCode
                if 200 == status {
                    return
                } else {
                    log.error("""
                        ERROR: Response: \(status)
                        ERROR: \(String(decoding: data, as: UTF8.self), privacy: .public)
                        ERROR: Request body:\n\(String(decoding: request.httpBody ?? Data(), as: UTF8.self), privacy: .private)
                        """)
                    // Retries won't help with Splunk errors, so force the loop to break
                    attempts = maxRetries
                    Statistics.shared.splunkErrors += 1

                    // Splunkloggingd can't emit metrics due to layering issues. For now, emit a darwin notification.
                    // A daemon in the support cryptex consumes and re-emits as a metric so we can monitor for failures
                    postFailureNotification()
                }
            } catch {
                log.error("Splunk HTTP POST failed:\n\(error.localizedDescription, privacy: .public)")
                Statistics.shared.httpErrors += 1
                attempts += 1

                // See above for why we need to emit this
                postFailureNotification()
            }
        }
    }

    // MARK: Initializers
    public init(splunkServer: URL, index: String, token: UUID? = nil) throws {
        self.token = token
        
        guard let splunkHECEndpoint = URLComponents(url: splunkServer, resolvingAgainstBaseURL: true) else {
            throw SplunkEventOffloaderError.invalidSplunkURL
        }
        let queryItems = [
            URLQueryItem(name: "index", value: index),
        ]
        
        var jsonEndpoint = splunkHECEndpoint
        jsonEndpoint.path = "/services/collector"
        jsonEndpoint.queryItems = queryItems
        guard let jsonURL = jsonEndpoint.url else {
            throw SplunkEventOffloaderError.invalidSplunkURL
        }
        self.jsonEndpoint = jsonURL
    }
}

extension SplunkEventOffloader: SplunkEventBufferDelegate {
    // Every time the timer fires, try to upload whatever data we've accumulated
    nonisolated func timerDidExpire(data: Data) {
        if data.isEmpty {
            return
        }

        Task {
            Statistics.shared.timerOffloads += 1
            await self.offload(event: .jsonEvent(data: data))
        }
    }

    nonisolated func bufferWouldOverflow(data: Data) {
        Task {
            await self.offload(event: .jsonEvent(data: data))
        }
    }

    nonisolated func handleDirectly(event: SplunkEvent) {
        Task {
            Statistics.shared.directOffloads += 1
            await self.offload(event: event)
        }
    }
}
