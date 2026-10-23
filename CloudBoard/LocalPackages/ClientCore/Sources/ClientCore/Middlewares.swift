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

//  Copyright © 2023 Apple Inc. All rights reserved.

import Foundation
import HTTPTypes
import OpenAPIRuntime
import OSLog

// Some of the middlewares below are based on https://github.com/apple/swift-openapi-generator/tree/main/Examples.

// MARK: - mTLS Auth Delegate

/// A delegate that handles mTLS and self-signed server certificates.
public actor AuthDelegate: NSObject, URLSessionDelegate {
    /// The logger used by the auth delegate.
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "AuthDelegate"
    )

    /// Whether to allow self-signed server certificates.
    private let allowSelfSignedCertificates: Bool

    /// The underlying credential provider, which is invoked on every client certificate challenge.
    private var credentialProvider: @Sendable () async -> URLCredential?

    /// Creates a new delegate.
    /// - Parameter allowSelfSignedCertificates: Whether to allow self-signed server certificates.
    public init(allowSelfSignedCertificates: Bool) {
        self.allowSelfSignedCertificates = allowSelfSignedCertificates
        self.credentialProvider = { nil }
    }

    /// Updates the current credential provider.
    /// - Parameter provider: The provider closure to be invoked to fetch the credential.
    public func updateCredentialProvider(_ provider: @escaping @Sendable () async -> URLCredential?) {
        self.credentialProvider = provider
    }

    public func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.logger.debug("AuthDelegate received challenge: \(challenge.protectionSpace.authenticationMethod)")

        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            if let credential = await credentialProvider() {
                Self.logger.debug("mTLS credential provided")
                return (.useCredential, credential)
            } else {
                Self.logger.warning("mTLS credential provider returned nil.")
                return (.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodServerTrust where self.allowSelfSignedCertificates:
            Self.logger
                .warning(
                    "Encountered a self-signed certificate and allowSelfSignedCertificates == true, allowing the connection to proceed."
                )
            guard let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            let credential = URLCredential(trust: trust)
            return (.useCredential, credential)
        default:
            Self.logger
                .debug(
                    "Unhandled authentication method: \(challenge.protectionSpace.authenticationMethod), using default handling"
                )
            return (.performDefaultHandling, nil)
        }
    }
}

// MARK: - Request ID

/// A middleware that creates a new unique request identifier, adds it as a request header, and sets a task local.
///
/// The header field name used is `x-request-id`.
///
/// The task local variable is `RequestIdMiddleware.currentRequestId`.
public struct RequestIdMiddleware {
    /// A task local value of the stored request identifier (can be nil).
    @TaskLocal static var requestId: String?

    /// The error thrown when the task local is not set.
    private struct TaskLocalNotSetError: Error {}

    /// A task local value of the current request identifier, throws an error if not set.
    public static var currentRequestId: String {
        get throws {
            guard let id = RequestIdMiddleware.requestId else {
                throw TaskLocalNotSetError()
            }
            return id
        }
    }

    /// Creates a new middleware.
    public init() {}

    /// The name of the header field.
    private static let requestIdName: HTTPField.Name = .init("x-request-id")!
}

extension RequestIdMiddleware: ClientMiddleware {
    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let id = UUID().uuidString
        var request = request
        request.headerFields[Self.requestIdName] = id
        return try await RequestIdMiddleware.$requestId.withValue(id) {
            try await next(request, body, baseURL)
        }
    }
}

// MARK: - Logging

/// A middleware that logs request and response information.
///
/// > Warning: Requires that RequestIdMiddleware is placed before this LoggingMiddleware in the middlewares array.
public actor LoggingMiddleware {
    /// The underlying logger.
    private let logger: Logger

    /// Creates a new logging middleware.
    /// - Parameter logger: The logger to use.
    public init(logger: Logger) {
        self.logger = logger
    }
}

extension LoggingMiddleware: ClientMiddleware {
    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let id = try RequestIdMiddleware.currentRequestId
        self.logger
            .debug(
                "Request [\(id, privacy: .public)]: \(request.method, privacy: .public) \(request.path ?? "<nil>", privacy: .public)"
            )
        do {
            let (response, responseBody) = try await next(request, body, baseURL)
            self.logger
                .debug(
                    "Response id=[\(id, privacy: .public)]: method=\(request.method, privacy: .public) path=\(request.path ?? "<nil>", privacy: .public) status=\(response.status, privacy: .public)"
                )
            return (response, responseBody)
        } catch {
            self.logger.warning("Request [\(id, privacy: .public)] failed. Error: \(error, privacy: .public)")
            throw error
        }
    }
}

// MARK: - Retrying

/// A middleware that retries the request under certain conditions.
///
/// > Warning: Requires that RequestIdMiddleware is placed before this RetryingMiddleware in the middlewares array.
public struct RetryingMiddleware {
    /// The logger used by this retrying middleware.
    private static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "RetryingMiddleware"
    )

    /// The failure signal that can lead to a retried request.
    public enum RetryableSignal: Sendable, Hashable {
        /// Retry if the response code matches this code.
        case code(Int)

        /// Retry if the response code falls into this range.
        case range(Range<Int>)

        /// Retry if an error is thrown by a downstream middleware or transport.
        case errorThrown
    }

    /// The policy to use when a retryable signal hints that a retry might be appropriate.
    public enum RetryingPolicy: Sendable, Hashable {
        /// Don't retry.
        case never

        /// Retry up to the provided number of attempts.
        case upToAttempts(count: Int)
    }

    /// The policy of delaying the retried request.
    public enum DelayPolicy: Sendable, Hashable {
        /// Don't delay, retry immediately.
        case none

        /// Constant delay.
        case constant(seconds: TimeInterval)
    }

    /// The signals that lead to the retry policy being evaluated.
    public var signals: Set<RetryableSignal>

    /// The policy used to evaluate whether to perform a retry.
    public var policy: RetryingPolicy

    /// The delay policy for retries.
    public var delay: DelayPolicy

    /// Creates a new retrying middleware.
    /// - Parameters:
    ///   - signals: The signals that lead to the retry policy being evaluated.
    ///   - policy: The policy used to evaluate whether to perform a retry.
    ///   - delay: The delay policy for retries.
    public init(
        signals: Set<RetryableSignal>,
        policy: RetryingPolicy,
        delay: DelayPolicy
    ) {
        self.signals = signals
        self.policy = policy
        self.delay = delay
    }
}

extension RetryingMiddleware: ClientMiddleware {
    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var stateMachine = RetryingMiddlewareStateMachine(
            signals: signals,
            policy: policy,
            delay: Duration(delay)
        )
        func logAndSleep(delay: Duration, finishedAttemptNumber: Int) async throws {
            Self.logger
                .warning(
                    "Request attempt \(finishedAttemptNumber, privacy: .public) failed, will retry in \(delay.components.seconds, privacy: .public) seconds."
                )
            try await Task.sleep(for: delay)
        }
        while true {
            do {
                let (response, responseBody) = try await next(request, body, baseURL)
                switch stateMachine.handleResponse(response, body: responseBody) {
                case .returnResponse(let response, let responseBody):
                    return (response, responseBody)
                case .retryAfterDelay(let delay, let finishedAttemptNumber):
                    try await logAndSleep(delay: delay, finishedAttemptNumber: finishedAttemptNumber)
                }
            } catch {
                switch stateMachine.handleError() {
                case .rethrowError:
                    throw error
                case .retryAfterDelay(let delay, let finishedAttemptNumber):
                    try await logAndSleep(delay: delay, finishedAttemptNumber: finishedAttemptNumber)
                }
            }
        }
    }
}

/// A state machine that controls the state transitions of `RetryingMiddleware`.
struct RetryingMiddlewareStateMachine {
    /// The signals that lead to the retry policy being evaluated.
    let signals: Set<RetryingMiddleware.RetryableSignal>

    /// The policy used to evaluate whether to perform a retry.
    let policy: RetryingMiddleware.RetryingPolicy

    /// The delay duration for retries.
    let delay: Duration

    /// Creates a new state machine.
    /// - Parameters:
    ///   - signals: The signals that lead to the retry policy being evaluated.
    ///   - policy: The policy used to evaluate whether to perform a retry.
    ///   - delay: The delay duration for retries.
    init(
        signals: Set<RetryingMiddleware.RetryableSignal>,
        policy: RetryingMiddleware.RetryingPolicy,
        delay: Duration
    ) {
        self.signals = signals
        self.policy = policy
        self.delay = delay
        self.attemptNumber = 1
    }

    /// The number of the currently running attempt.
    private(set) var attemptNumber: Int

    /// Evaluates whether the state machine allows another attempt.
    private func canRetry() -> Bool {
        guard
            case .upToAttempts(let maxAttempts) = policy,
            attemptNumber < maxAttempts
        else {
            return false
        }
        return true
    }

    /// Uses up one attempt.
    private mutating func consumeAttempt() {
        self.attemptNumber += 1
    }

    /// An action returned by the `handleResponse` method.
    enum HandleResponseAction: Hashable {
        /// Return the provided response.
        case returnResponse(HTTPResponse, HTTPBody?)

        /// Retry after the provided delay, and report that the attempt with the provided number failed.
        case retryAfterDelay(delay: Duration, finishedAttemptNumber: Int)
    }

    /// Call with the response returned by the `next` closure.
    mutating func handleResponse(_ response: HTTPResponse, body: HTTPBody?) -> HandleResponseAction {
        guard self.canRetry(), self.signals.contains(response.status.code) else {
            return .returnResponse(response, body)
        }
        let attemptNumber = attemptNumber
        self.consumeAttempt()
        return .retryAfterDelay(delay: self.delay, finishedAttemptNumber: attemptNumber)
    }

    /// An action returned by the `handleError` method.
    enum HandleErrorAction: Hashable {
        /// Rethrow the caught error.
        case rethrowError

        /// Retry after the provided delay, and report that the attempt with the provided number failed.
        case retryAfterDelay(delay: Duration, finishedAttemptNumber: Int)
    }

    /// Call when an error is thrown while invoking the `next` closure.
    mutating func handleError() -> HandleErrorAction {
        guard self.canRetry(), self.signals.contains(.errorThrown) else {
            return .rethrowError
        }
        let attemptNumber = attemptNumber
        self.consumeAttempt()
        return .retryAfterDelay(delay: self.delay, finishedAttemptNumber: attemptNumber)
    }
}

extension Set<RetryingMiddleware.RetryableSignal> {
    /// Checks whether the provided response code matches the retryable signals.
    /// - Parameter code: The provided code to check.
    /// - Returns: `true` if the code matches at least one of the signals, `false` otherwise.
    fileprivate func contains(_ code: Int) -> Bool {
        for signal in self {
            switch signal {
            case .code(let int): if code == int { return true }
            case .range(let range): if range.contains(code) { return true }
            case .errorThrown: break
            }
        }
        return false
    }
}

extension Duration {
    /// Creates a new duration from the provided delay policy.
    /// - Parameter delayPolicy: The delay policy to compute a duration for.
    public init(_ delayPolicy: RetryingMiddleware.DelayPolicy) {
        switch delayPolicy {
        case .none:
            self = .zero
        case .constant(let seconds):
            self = .seconds(seconds)
        }
    }
}

// MARK: - Task Local Headers

/// A middleware that injects caller-supplied HTTP headers via a task local.
///
/// Set `TaskLocalHeaderMiddleware.headers` as a task local before invoking the client to have
/// the key-value pairs injected into outgoing requests. When the task local is empty the request
/// is passed through unchanged.
///
/// Example:
/// ```swift
/// try await TaskLocalHeaderMiddleware.$headers.withValue(
///     ["x-apple-request-uuid": requestID]
/// ) {
///     try await client.someOperation()
/// }
/// ```
public struct TaskLocalHeaderMiddleware {
    /// A task local dictionary of header name → value pairs to inject (defaults to empty).
    @TaskLocal public static var headers: [String: String] = [:]

    /// Creates a new middleware.
    public init() {}
}

extension TaskLocalHeaderMiddleware: ClientMiddleware {
    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        for (name, value) in Self.headers {
            if let fieldName = HTTPField.Name(name) {
                request.headerFields[fieldName] = value
            }
        }
        return try await next(request, body, baseURL)
    }
}
