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
//  TrustedCloudComputeClient.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import AppleIntelligenceReporting
import OSLog

private let logger = tc2Logger(forCategory: .client)

/// A client for executing trusted cloud compute requests.
public final class TrustedCloudComputeClient: Sendable {

    /// The underlying client.
    private let client: any TC2ClientProtocol
    /// The configuration.
    private let configuration: Configuration
    /// Feature flag checker to use
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

    /// Executes a trusted request.
    ///
    /// This method opens a trusted connection to the cloud compute environment and provides access to writing the request and consuming
    /// the response data in the `body` closure. Once the `body` closure returns the connection will be torn down and all resources
    /// associated with it will be freed.
    ///
    /// - Parameters:
    ///   - request: The request to execute.
    ///   - body: A closure during which request data can be written and the response data can be consumed.
    /// - Returns: The type that the body closure produced.
    @concurrent public func withTrustedRequest<Return>(
        _ request: TrustedRequest,
        _ body: @concurrent (_ writer: TrustedRequest.Writer, _ response: TrustedRequest.Response) async throws -> Return
    ) async throws -> Return {
        return try await withTaskCancellationHandler {
            var telemetryEventID: EventIdentifier?
            do {
                telemetryEventID = try EventReporter().emitAppleIntelligenceStartEvent(
                    eventInfo: trustedRequestEventInfo(with: request.id, step: .privateCloudComputeRequestInProcess)
                )
            } catch {
                logger.error("Failed to emit start reporting event; id=\(request.id), error=\(error)")
            }

            logger.log("\(request.id) withTrustedRequest started")
            defer {
                logger.log("\(request.id) withTrustedRequest finished")
            }

            let xpcRequestProxy = try await self.client.xpc.trustedRequest(
                withParameters: Workload(
                    type: request.workloadType,
                    parameters: request.workloadParameters ?? [:]
                ).json,
                requestID: request.id,
                multiTurn: false,
                bundleIdentifier: request.bundleIdentifier,
                originatingBundleIdentifier: request.originatingBundleIdentifier,
                featureIdentifier: request.featureIdentifier,
                sessionIdentifier: request.sessionIdentifier
            )
            defer {
                logger.log("\(request.id) withTrustedRequest xpc proxy closing")
                xpcRequestProxy.close()
            }

            let isChunkingEnabled = self.featureFlagChecker.isEnabled(.applicationDataChunking)
            let writer = TrustedRequest.Writer(id: request.id, xpcRequestProxy: xpcRequestProxy, telemetryEventID: telemetryEventID, isChunkingEnabled: isChunkingEnabled)
            let response = TrustedRequest.Response(id: request.id, xpcRequestProxy: xpcRequestProxy, telemetryEventID: telemetryEventID, isChunkingEnabled: isChunkingEnabled)
            return try await body(writer, response)
        } onCancel: {
            logger.error("\(request.id) withTrustedRequest cancelled")
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
            let xpcProxy = try await self.client.xpc.connection(
                withParameters: Workload(
                    type: configuration.workloadType,
                    parameters: configuration.workloadParameters ?? [:]
                ).json,
                connectionIdentifier: configuration.id,
                bundleIdentifier: configuration.bundleIdentifier,
                originatingBundleIdentifier: configuration.originatingBundleIdentifier,
                featureIdentifier: configuration.featureIdentifier,
                sessionIdentifier: configuration.sessionIdentifier
            )

            defer {
                logger.log("\(logPrefix) withConnection xpc proxy closing")
                xpcProxy.close()
            }

            try await withTaskCancellationHandler {
                try await PrivateCloudComputeConnection.run(
                    configuration: configuration,
                    xpcProxy: xpcProxy,
                    logPrefix: logPrefix,
                    featureFlagChecker: self.featureFlagChecker,
                    subrequestIdGenerator: self.subrequestIdGenerator,
                    closure: body
                )
            } onCancel: {
                logger.error("\(logPrefix) withConnection cancelling proxy")
                xpcProxy.cancel()
            }
        }
    }

    /// Runs a prefetch for attestations from the server, for the given workload specification.
    ///
    /// - Parameters:
    ///   - workloadType: The workloadType associated with requests to prefetch attestations for
    ///   - workloadParameters: The workloadParameters associated with requests to prefetch attestations for
    /// - Returns: Returns `true` when a successful prefetch occurs, or `false` otherwise.
    @available(*, deprecated, message: "Use `completePrewarm(workloadType:workloadParameters:bundleIdentifierOverride:featureIdentifier)` instead.")
    @concurrent public func prefetchRequest(workloadType: String, workloadParameters: [String: String]) async throws -> Bool {
        await client.prewarm(
            request: .init(
                workloadType: workloadType,
                workloadParameters: workloadParameters
            ),
            bundleIdentifier: nil,
            // This is temporary till the caller switches over to the new API
            featureIdentifier: "prewarm.prefetchRequest",
            runOnEventStream: true
        )
        return true
    }

    /// Kicks off a prefetch for attestations from the server, for the given workload specification.
    ///
    /// - Parameters:
    ///   - workloadType: The workloadType associated with requests to prefetch attestations for
    ///   - workloadParameters: The workloadParameters associated with requests to prefetch attestations for
    ///   - bundleIdentifierOverride: Optional bundle identifier to override the one automatically determined
    ///   - featureIdentifier: Non optional feature identifier used for rate limiting and analytics
    @available(*, deprecated, message: "Use `completePrewarm(workloadType:workloadParameters:bundleIdentifierOverride:featureIdentifier)` instead.")
    @concurrent public func prewarm(workloadType: String, workloadParameters: [String: String], bundleIdentifierOverride: String?, featureIdentifier: String) async {
        return await client.prewarm(
            request: .init(
                workloadType: workloadType,
                workloadParameters: workloadParameters
            ),
            bundleIdentifier: bundleIdentifierOverride,
            featureIdentifier: featureIdentifier,
            runOnEventStream: true
        )
    }

    /// Runs a prefetch for attestations from the server, for the given workload specification, as well
    /// as any other work that might be required to speed up request that is likely to occur. This method,
    /// `completePrewarm`, differs from `prewarm` in that it runs its work to completion before
    /// it asynchronously returns. This is in contrast to `prewarm`'s behavior being fire-and-forget.
    ///
    /// - Parameters:
    ///   - workloadType: The workloadType associated with requests to prefetch attestations for
    ///   - workloadParameters: The workloadParameters associated with requests to prefetch attestations for
    ///   - bundleIdentifierOverride: Optional bundle identifier to override the one automatically determined
    ///   - featureIdentifier: Non optional feature identifier used for rate limiting and analytics
    @concurrent public func completePrewarm(workloadType: String, workloadParameters: [String: String], bundleIdentifierOverride: String?, featureIdentifier: String) async {
        return await client.prewarm(
            request: .init(
                workloadType: workloadType,
                workloadParameters: workloadParameters
            ),
            bundleIdentifier: bundleIdentifierOverride,
            featureIdentifier: featureIdentifier,
            runOnEventStream: false
        )
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
    /// featureIdentifier. This is determined by consulting the server, which means that the data should be
    /// relatively fresh, and may reflect information like ongoing incidents or outages.
    ///
    /// Note that there is no guarantee that a new limitation doesn't arise after this method succeeds. Therefore
    /// the requests issued still need to handle rate limiting errors.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: Optional bundle identifier to override the one automatically determined. Can only be passed if you have an entitlement.
    ///   - featureIdentifier: Optional feature identifier. If `nil`, then return all configurations applicable to the bundleID regardless of what feature identifier they are scoped to.
    /// - Returns: Every rate limit known to the system that may apply to the bundle/feature in question.
    @concurrent public func knownRateLimits(bundleIdentifier: String? = nil, featureIdentifier: String? = nil) async -> [TrustedCloudComputeRateLimit] {
        return await self.client.knownRateLimits(bundleIdentifier: bundleIdentifier, featureIdentifier: featureIdentifier, skipFetch: false)
    }

    @concurrent public func knownRateLimits(bundleIdentifier: String? = nil, featureIdentifier: String? = nil, skipFetch: Bool = false) async -> [TrustedCloudComputeRateLimit] {
        return await self.client.knownRateLimits(bundleIdentifier: bundleIdentifier, featureIdentifier: featureIdentifier, skipFetch: skipFetch)
    }
}
