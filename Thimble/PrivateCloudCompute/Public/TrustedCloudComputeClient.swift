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
//  TrustedCloudComputeClient.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import OSLog

private let logger = Logger(for: .client)

/// A client for executing trusted cloud compute requests.
public final class TrustedCloudComputeClient: Sendable {

    /// The underlying client.
    private let client: any TC2ClientProtocol
    /// The configuration.
    private let configuration: Configuration
    private let featureFlagChecker: any FeatureFlagCheckerProtocol
    /// Request ID generator for subrequests
    private let subrequestIdGenerator: @Sendable () -> UInt64

    /// Creates a new ``TrustedCloudComputeClient``.
    ///
    /// - Parameters:
    /// - configuration: The configuration to use for the client.
    public init(configuration: Configuration) throws {
        let wrapper = XPCWrapper(userID: configuration.userID)
        self.client = TC2Client(xpc: wrapper)
        self.configuration = configuration
        self.featureFlagChecker = FeatureFlagChecker()
        self.subrequestIdGenerator = randomSubrequestId
    }

    init(
        client: any TC2ClientProtocol,
        featureFlagChecker: any FeatureFlagCheckerProtocol,
        configuration: Configuration,
        subrequestIdGenerator: @escaping @Sendable () -> UInt64 = randomSubrequestId
    ) {
        self.client = client
        self.featureFlagChecker = featureFlagChecker
        self.configuration = configuration
        self.subrequestIdGenerator = subrequestIdGenerator
    }

    nonisolated(nonsending) public func withRequest<Return>(
        configuration: RequestConfiguration,
        _ body: @concurrent (_ writer: TrustedRequest.Writer, _ response: TrustedRequest.Response) async throws -> Return
    ) async throws -> Return {
        let logPrefix = "\(configuration.id):"
        return try await logger.logLifetime("withRequest", logPrefix: logPrefix) {
            let requestParameters = RequestParameters(configuration)
            let stepReporter = AppleIntelligenceStepReporter(forWorkload: requestParameters.workload)
            let step = stepReporter.beginStep(.privateCloudComputeRequestInProcess, requestID: configuration.id)
            let xpcRequestProxy = try await self.client.xpc.request(parametersData: requestParameters.json)
            defer {
                logger.log("\(logPrefix) withRequest xpc proxy closing")
                xpcRequestProxy.close()
            }

            let setup = try await xpcRequestProxy.prepare()
            let chunkSize = setup.chunkSize
            let writer = TrustedRequest.Writer(id: configuration.id, xpcRequestProxy: xpcRequestProxy, step: step, chunkSize: chunkSize)
            let response = TrustedRequest.Response(id: configuration.id, xpcRequestProxy: xpcRequestProxy, step: step, chunkSize: chunkSize)

            if self.featureFlagChecker.isEnabled(.requestCancellationV2) {
                // Before we return control to the adopter, we need to wrap up things, such as receive cost tokens
                // and final REL. And only then we can close XPC (defer defined earlier) and return to the adopter.
                defer {
                    try? await logger.logLifetime("withRequest waitForRequestCompletion", logPrefix: logPrefix) {
                        try await xpcRequestProxy.waitForRequestCompletion()
                    }
                }

                return try await withTaskCancellationHandler {
                    try await logger.logLifetime("withRequest body", logPrefix: logPrefix) {
                        try await body(writer, response)
                    }
                } onCancel: {
                    xpcRequestProxy.cancel()
                }
            } else {
                return try await body(writer, response)
            }
        }
    }

    /// Creates and manages a long-lived connection for executing multiple requests.
    ///
    /// This method establishes a long-lived connection with the Private Cloud Compute environment that can be used
    /// to execute multiple requests. The connection remains active for the duration of the `body` closure.
    ///
    /// When the `body` closure completes (either successfully or by throwing an error), the connections closes.
    ///
    /// - Parameters:
    ///   - configuration: The connection configuration.
    ///   - body: An async closure that receives the created connection and can use it to execute multiple requests.
    ///           The connection parameter provides access to `withRequest(_:_:)` for executing individual requests within the connection.
    @concurrent public func withConnection(
        configuration: PrivateCloudComputeConnection.Configuration,
        _ body: @concurrent (_ connection: PrivateCloudComputeConnection) async throws -> Void
    ) async throws {
        let logPrefix = "\(configuration.id):"
        try await logger.logLifetime("withConnection", logPrefix: logPrefix) {
            let requestParameters = RequestParameters(configuration)
            let xpcProxy = try await self.client.xpc.request(parametersData: requestParameters.json)

            defer {
                logger.log("\(logPrefix) withConnection xpc proxy closing")
                xpcProxy.close()
            }

            let setup = try await xpcProxy.prepare()

            // Before we return control to the adopter, we need to wrap up things, such as receive cost tokens
            // and final REL. And only then we can close XPC (defer defined earlier) and return to the adopter.
            defer {
                if self.featureFlagChecker.isEnabled(.requestCancellationV2) {
                    try? await logger.logLifetime(level: .info, "withConnection waitForRequestCompletion", logPrefix: logPrefix) {
                        try await xpcProxy.waitForRequestCompletion()
                    }
                }
            }

            try await withTaskCancellationHandler {
                try await PrivateCloudComputeConnection.run(
                    configuration: configuration,
                    xpcProxy: xpcProxy,
                    featureFlagChecker: self.featureFlagChecker,
                    logPrefix: logPrefix,
                    chunkSize: setup.chunkSize,
                    subrequestIdGenerator: self.subrequestIdGenerator,
                    closure: body
                )
            } onCancel: {
                logger.error("\(logPrefix) withConnection cancelling proxy")
                xpcProxy.cancel()
            }
        }
    }

    /// Runs a prefetch for attestations from the server, for the given workload specification, as well
    /// as any other work that might be required to speed up request that is likely to occur.
    nonisolated(nonsending) public func prewarm(configuration: PrewarmConfiguration) async throws {
        let logPrefix = "\(UUID().uuidString):"
        logger.log("\(logPrefix) prewarm, configuration=\(String(describing: configuration))")
        await logger.logLifetime("prewarm", logPrefix: logPrefix) {
            await client.prewarm(parameters: PrewarmParameters(configuration))
        }
    }

    package func prefetch(request: Prefetch) async throws -> [Prefetch.Response] {
        // This is called from only from thtool at the moment
        try await client.prefetch(request: request)
    }

    @_spi(Prefetch) public func prefetchParametersCache() async -> [String] {
        return await client.prefetchParametersCache()
    }

    @_spi(Prefetch) public func prefetchParametersCacheSavedState() async -> [String] {
        return await client.prefetchParametersCacheSavedState()
    }

    @_spi(Prefetch) public func prefetchCacheReset() async -> Bool {
        return await client.prefetchCacheReset()
    }

    @_spi(Prefetch) public func prefetchCache() async -> [String] {
        return await client.prefetchCache()
    }

    /// Discovers the rate limiting configurations for requests associated with the given bundleIdentifier and
    /// featureIdentifier.
    ///
    /// Note that there is no guarantee that a new limitation doesn't arise after this method succeeds. Therefore
    /// the requests issued still need to handle rate limiting errors.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Optional bundle identifier to override the one automatically determined. Can only be passed if you have an entitlement.
    ///   - featureIdentifier: Optional feature identifier. If `nil`, then return all configurations applicable to the bundleID regardless of what feature identifier they are scoped to.
    /// - Returns: Every rate limit known to the system that may apply to the bundle/feature in question.
    @concurrent public func knownRateLimits(
        bundleIdentifier: String? = nil,
        featureIdentifier: String? = nil
    ) async -> [TrustedCloudComputeRateLimit] {
        await self.knownRateLimits(
            bundleIdentifier: bundleIdentifier,
            featureIdentifier: featureIdentifier,
            skipFetch: false
        )
    }

    /// NOTE: the `skipFetch` flag is ignored and will not trigger fetching of the limits.
    @concurrent public func knownRateLimits(
        bundleIdentifier: String? = nil,
        featureIdentifier: String? = nil,
        skipFetch: Bool = false  // Unused. Will be deprecated and removed in future.
    ) async -> [TrustedCloudComputeRateLimit] {
        let logPrefix = "\(UUID().uuidString):"
        logger.log("\(logPrefix) knownRateLimits, bundleIdentifier=\(bundleIdentifier ?? "nil"), featureIdentifier=\(featureIdentifier ?? "nil")")
        return await logger.logLifetime("knownRateLimits", logPrefix: logPrefix) {
            await self.client.knownRateLimits(
                bundleIdentifier: bundleIdentifier,
                featureIdentifier: featureIdentifier,
            )
        }
    }
}
