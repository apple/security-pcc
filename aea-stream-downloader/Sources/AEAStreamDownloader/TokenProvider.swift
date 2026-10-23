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

import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import Synchronization

/// Manages an OAuth2 token, refreshing it in the background before it expires.
public final class TokenProvider: Sendable {
    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
    }

    private struct State {
        var token: String
        var refreshTask: Task<Void, Never>?
    }

    private let storage: Mutex<State>
    private let logger: Logger
    private let httpClient: HTTPClient
    private let metadataBaseURL: String

    /// Fetches an initial token and starts background refresh.
    public static func create(
        logger: Logger,
        httpClient: HTTPClient,
        metadataBaseURL: String = "http://metadata.google.internal",
        retryConfiguration: RetryConfiguration = .default
    ) async throws -> TokenProvider {
        let initial = try await withRetry(
            configuration: retryConfiguration,
            logger: logger,
            operation: .tokenFetch
        ) {
            try await fetchGCEToken(logger: logger, httpClient: httpClient, metadataBaseURL: metadataBaseURL)
        }
        return TokenProvider(
            initialToken: initial,
            logger: logger,
            httpClient: httpClient,
            metadataBaseURL: metadataBaseURL
        )
    }

    private init(initialToken: TokenResponse, logger: Logger, httpClient: HTTPClient, metadataBaseURL: String) {
        self.storage = Mutex(State(token: initialToken.access_token))
        self.logger = logger
        self.httpClient = httpClient
        self.metadataBaseURL = metadataBaseURL

        // Refresh the token before it expires. We refresh at 50% of the
        // lifetime to give plenty of margin.
        let initialSleep = max(initialToken.expires_in / 2, 1)

        let task = Task {
            var sleepSeconds = initialSleep
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(sleepSeconds))
                } catch {
                    // Task was cancelled during sleep
                    break
                }

                do {
                    let newToken = try await self.fetchGCEToken()
                    self.storage.withLock { $0.token = newToken.access_token }
                    sleepSeconds = max(newToken.expires_in / 2, 1)
                    consecutiveFailures = 0
                    self.logger.info("Refreshed OAuth2 token", metadata: ["expires_in": "\(newToken.expires_in)"])
                } catch {
                    consecutiveFailures += 1
                    let backoff = min(30, 1 << min(consecutiveFailures, 5))
                    let jitter = Int.random(in: 0...max(1, backoff / 4))
                    sleepSeconds = backoff + jitter
                    self.logger.error(
                        "Failed to refresh OAuth2 token, will retry",
                        metadata: [
                            "error": "\(String(reportable: error))",
                            "retryInSeconds": "\(sleepSeconds)",
                            "consecutiveFailures": "\(consecutiveFailures)",
                        ]
                    )
                }
            }
        }
        self.storage.withLock { $0.refreshTask = task }
    }

    /// Returns the current valid token.
    public var token: String {
        storage.withLock { $0.token }
    }

    /// Cancel the background refresh task. Call this when the provider is no longer needed.
    public func cancel() {
        storage.withLock { $0.refreshTask?.cancel() }
    }

    private func fetchGCEToken() async throws -> TokenResponse {
        try await Self.fetchGCEToken(logger: logger, httpClient: httpClient, metadataBaseURL: metadataBaseURL)
    }

    private static func fetchGCEToken(
        logger: Logger,
        httpClient: HTTPClient,
        metadataBaseURL: String
    ) async throws -> TokenResponse {
        logger.debug("Fetching OAuth2 token from GCE metadata service")

        var request = HTTPClientRequest(
            url: "\(metadataBaseURL)/computeMetadata/v1/instance/service-accounts/default/token"
        )
        request.headers.add(name: "Metadata-Flavor", value: "Google")

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard response.status == .ok else {
            logger.error(
                "GCE metadata token fetch failed",
                metadata: [
                    "httpStatus": "\(response.status.code)",
                    "url": "\(request.url)",
                ]
            )
            throw AEADownloaderError.metadataFetchFailed(status: Int(response.status.code))
        }

        var body = try await response.body.collect(upTo: 1024 * 1024)
        let data = Data(body.readBytes(length: body.readableBytes)!)
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        logger.debug("Successfully obtained OAuth2 token", metadata: ["expires_in": "\(tokenResponse.expires_in)"])
        return tokenResponse
    }
}
