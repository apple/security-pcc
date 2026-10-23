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
//  TC2DaemonHost.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import AppSupport
import Darwin
import Foundation
import Foundation_Private.NSXPCConnection
import Network
import PrivateCloudCompute
import Synchronization
import os.lock

private let logger = Logger(for: .daemon)

protocol TC2DaemonHostDelegate: Sendable {
    func prefetchRequest(workloadType: String, workloadParameters: [String: String]) async -> Data?
    func prewarmRequest(workloadType: String, workloadParameters: [String: String], bundleIdentifier: BundleIdentifier, featureIdentifier: String, serviceClass: NWParameters.ServiceClass?) async -> Data?
    func warmAttestationStore() async
    func structuredRequestFactory(
        forSetup: TC2ResolvedSetup,
        requestParameters: RequestParameters
    ) -> ThimbledTrustedRequestFactory
    func prefetchCache() async -> [String]
    func prefetchParametersCache() -> [String]
    func prefetchParametersCacheSavedState() -> [String]
    func prefetchCacheReset() async -> Bool
    func listRateLimits(bundleIdentifier: BundleIdentifier?, featureIdentifier: String?, fetch: Bool) async -> Data?
    func addRateLimit(
        source: RateLimitSource,
        bundleIdentifier: String?,
        featureIdentifier: String?,
        workloadType: String?,
        count: UInt,
        duration: Double,
        ttl: Double,
        jitter: Double
    ) async
    func resetRateLimits() async
    func fetchServerDrivenConfiguration() async -> Data
    func listServerDrivenConfiguration() async -> Data
    func setServerDrivenConfiguration(json: Data) async -> Data
}

/// This object implements the protocol which we have defined. It provides the actual behavior for the service. It is 'exported' by the service to make it available to the process hosting the service over an NSXPCConnection.
final class TC2DaemonHost<
    SystemInfo: SystemInfoProtocol,
    DeviceState: DeviceStateProtocol
>: NSObject, TC2DaemonProtocol, @unchecked Sendable {
    let delegate: any TC2DaemonHostDelegate
    let connection: NSXPCConnection
    let config: any Configuration
    let systemInfo: SystemInfo
    let bundleIDProvider: any BundleIDProviderProtocol
    let bundleIDResolver: BundleIDResolver
    let requestProxies: Mutex<[TrustedRequestXPCProxy]> = .init([])
    let deviceState: DeviceState

    init(
        config: any Configuration,
        systemInfo: SystemInfo,
        bundleIDProvider: any BundleIDProviderProtocol,
        delegate: any TC2DaemonHostDelegate,
        connection: NSXPCConnection,
        deviceState: DeviceState
    ) {
        self.delegate = delegate
        self.connection = connection
        self.config = config
        self.systemInfo = systemInfo
        self.bundleIDProvider = bundleIDProvider
        self.bundleIDResolver = BundleIDResolver(provider: bundleIDProvider)
        self.deviceState = deviceState
    }

    func invalidationHandler() {
        logger.log("XPC connection invalidated")
        self.requestProxies.withLock {
            for proxy in $0 {
                proxy.cancelRequestTask(reason: .xpcInvalidation)
            }
            $0 = []
        }
    }

    func interruptionHandler() {
        logger.log("XPC connection interrupted")
    }

    func currentEnvironment(completion: (String) -> Void) {
        guard hasEntitlement(.admin) || hasEntitlement(.serverEnvironment) else {
            return completion("")
        }

        completion(self.config.environment(systemInfo: self.systemInfo).name)
    }

    func echo(text: String, completion: (String) -> Void) {
        let response = "thimbled Echo: \(text)"
        logger.log("echo: \(text)")
        completion(response)
    }

    func request(
        parametersData: RequestParameters.Data,
        completion: @escaping ((any TC2XPCTrustedRequestProtocol)?, Data?) -> Void
    ) {
        // The requestID that is passed in here is the clientRequestID, i.e., the ID
        // that the caller provides. We track it for logging but we do not pass it to the server.
        do {
            let xpcRequest = try self._request(parametersData: parametersData)
            completion(xpcRequest, nil)
        } catch {
            completion(nil, error.json)
        }
    }

    private func _request(
        parametersData: RequestParameters.Data
    ) throws(PrivateCloudComputeError) -> any TC2XPCTrustedRequestProtocol {
        guard hasEntitlement(.requests) else {
            throw PrivateCloudComputeError(message: "missing entitlements")
        }

        guard let clientBundleIdentifier = try? self.bundleIDProvider.bundleIdentifier(for: connection.auditToken) else {
            throw PrivateCloudComputeError(message: "missing client bundle identifier")
        }
        let allowBundleIdentifierOverride = hasEntitlement(.bundleIdentifierOverride)
        let effectiveUserIdentifier = effectiveUserIdentifier(auditToken: connection.auditToken)

        guard let parameters = RequestParameters(json: parametersData) else {
            throw PrivateCloudComputeError(message: "failure decoding request parameters")
        }

        let bundleIdentifier: BundleIdentifier
        do {
            bundleIdentifier = try bundleIDResolver.resolve(
                forAuditToken: connection.auditToken,
                stringOverride: parameters.bundleIdentifier,
                pidOverride: parameters.onBehalfOfPID,
                allowOverride: allowBundleIdentifierOverride
            )
        } catch {
            throw PrivateCloudComputeError(message: "failed to resolve bundle identifier")
        }

        let originatingBundleIdentifier: BundleIdentifier?
        do {
            originatingBundleIdentifier = try bundleIDResolver.resolveOriginating(
                stringOverride: parameters.originatingBundleIdentifier,
                pidOverride: parameters.parentOfOnBehalfOfPID,
                allowOverride: allowBundleIdentifierOverride
            )
        } catch {
            throw PrivateCloudComputeError(message: "failed to resolve originating bundle identifier")
        }

        let factory = delegate.structuredRequestFactory(
            forSetup: .init(
                clientBundleIdentifier: clientBundleIdentifier.rawValue,
                allowBundleIdentifierOverride: allowBundleIdentifierOverride
            ),
            requestParameters: parameters
        )

        let xpcRequest: TrustedRequestXPCProxy
        do {
            xpcRequest = try factory.startTrustedRequest(
                requestParameters: parameters,
                bundleIdentifier: bundleIdentifier,
                originatingBundleIdentifier: originatingBundleIdentifier,
                effectiveUserIdentifier: effectiveUserIdentifier
            )
        } catch {
            throw PrivateCloudComputeError.wrapAny(error: error)
        }

        self.requestProxies.withLock {
            $0.append(xpcRequest)
        }

        return xpcRequest
    }

    func prefetchRequest(workloadType: String, workloadParameters: [String: String], completion: @escaping @Sendable (Data?) -> Void) {
        guard hasEntitlement(.prefetchRequest) else {
            completion(nil)
            return
        }
        guard deviceState.isUnlockedSinceBoot else {
            logger.error("ignoring prefetch request: unavailable before first unlock")
            completion(nil)
            return
        }

        Task {
            let data = await delegate.prefetchRequest(workloadType: workloadType, workloadParameters: workloadParameters)
            completion(data)
        }
    }

    func prewarmRequest(
        parametersData: PrewarmParameters.Data,
        completion: @escaping @Sendable () -> Void
    ) {
        // Entitlement is still the same, since the underlying call is going to be a prefetch
        guard hasEntitlement(.prefetchRequest) else {
            return completion()
        }
        guard deviceState.isUnlockedSinceBoot else {
            logger.error("ignoring prewarm request: unavailable before first unlock")
            return completion()
        }

        guard let parameters = PrewarmParameters(json: parametersData) else {
            logger.log("failure decoding prewarm parameters")
            return completion()
        }

        let bundleIdentifierForPrewarm: BundleIdentifier
        do {
            bundleIdentifierForPrewarm = try bundleIDResolver.resolve(
                forAuditToken: connection.auditToken,
                stringOverride: parameters.bundleIdentifier,
                pidOverride: parameters.onBehalfOfPID,
                allowOverride: hasEntitlement(.bundleIdentifierOverride)
            )
        } catch {
            logger.log("attempt to set bundleIdentifierOverride failed: \(error)")
            return completion()
        }

        // Touch the attestation store at our current (pre-.medium) priority so its
        // lazy init isn't left starting at .medium.
        Task {
            await self.delegate.warmAttestationStore()
        }

        Task(priority: .medium) {
            _ = await self.delegate.prewarmRequest(
                workloadType: parameters.workload.type,
                workloadParameters: parameters.workload.parameters,
                bundleIdentifier: bundleIdentifierForPrewarm,
                featureIdentifier: parameters.featureIdentifier,
                serviceClass: parameters.serviceClass?.unwrap()
            )
            completion()
        }
    }

    func prefetchCache(completion: @escaping @Sendable ([String]) -> Void) {
        guard hasEntitlement(.admin) else {
            return completion([])
        }

        Task {
            let result = await delegate.prefetchCache()
            completion(result)
        }
    }

    func prefetchParametersCache(completion: @escaping @Sendable ([String]) -> Void) {
        guard hasEntitlement(.admin) else {
            return completion([])
        }

        completion(delegate.prefetchParametersCache())
    }

    func prefetchParametersCacheSavedState(completion: @escaping @Sendable ([String]) -> Void) {
        guard hasEntitlement(.admin) else {
            return completion([])
        }

        return completion(delegate.prefetchParametersCacheSavedState())
    }

    func prefetchCacheReset(completion: @escaping @Sendable (Bool) -> Void) {
        guard hasEntitlement(.admin) else {
            return completion(false)
        }

        Task {
            let result = await delegate.prefetchCacheReset()
            completion(result)
        }
    }

    // The difference between knownRateLimits and listRateLimits is that knownRateLimits is ultimately
    // exposed in API, and it (a) will not issue a fetch request to the
    // server, and (b) will default to the caller's bundleID but allow them to override with the
    // correct entitlement, and therefore (c) uses its own entitlement separate from the admin one.
    func knownRateLimits(bundleIdentifier: String?, featureIdentifier: String?, completion: @escaping @Sendable (Data?) -> Void) {
        guard hasEntitlement(.knownRateLimits) else {
            return completion(nil)
        }
        guard deviceState.isUnlockedSinceBoot else {
            logger.error("ignoring knownRateLimits: unavailable before first unlock")
            return completion(nil)
        }

        let resolvedBundleIdentifier: BundleIdentifier
        do {
            resolvedBundleIdentifier = try bundleIDResolver.resolve(
                forAuditToken: connection.auditToken,
                stringOverride: bundleIdentifier,
                pidOverride: nil,
                allowOverride: hasEntitlement(.bundleIdentifierOverride)
            )
        } catch {
            logger.log("attempt to set bundleIdentifierOverride failed: \(error)")
            return completion(nil)
        }

        Task {
            let result = await delegate.listRateLimits(bundleIdentifier: resolvedBundleIdentifier, featureIdentifier: featureIdentifier, fetch: false)
            completion(result)
        }
    }

    func listRateLimits(bundleIdentifier: String?, featureIdentifier: String?, fetch: Bool, completion: @escaping @Sendable (Data?) -> Void) {
        guard hasEntitlement(.admin) else {
            return completion(nil)
        }
        guard deviceState.isUnlockedSinceBoot else {
            logger.error("ignoring listRateLimits: unavailable before first unlock")
            return completion(nil)
        }

        Task {
            let bundleID = bundleIdentifier.map { BundleIdentifier(rawValue: $0, provenance: .unknown) }
            let result = await delegate.listRateLimits(bundleIdentifier: bundleID, featureIdentifier: featureIdentifier, fetch: fetch)
            completion(result)
        }
    }

    func addRateLimit(
        source: RateLimitSource.RawValue,
        bundleIdentifier: String?,
        featureIdentifier: String?,
        workloadType: String?,
        count: UInt,
        duration: Double,
        ttl: Double,
        jitter: Double,
        completion: @escaping @Sendable () -> Void
    ) {
        guard hasEntitlement(.admin) else {
            return completion()
        }
        guard deviceState.isUnlockedSinceBoot else {
            logger.error("ignoring addRateLimit: unavailable before first unlock")
            return completion()
        }

        guard let source = RateLimitSource(rawValue: source) else {
            logger.error("can not create RateLimitSource from rawValue, ignoring. source=\(source)")
            return completion()
        }

        Task {
            await delegate.addRateLimit(
                source: source,
                bundleIdentifier: bundleIdentifier,
                featureIdentifier: featureIdentifier,
                workloadType: workloadType,
                count: count,
                duration: duration,
                ttl: ttl,
                jitter: jitter
            )
            completion()
        }
    }

    func resetRateLimits(completion: @escaping @Sendable (Data?) -> Void) {
        guard hasEntitlement(.admin) else {
            return completion(PrivateCloudComputeError(code: .unauthorizedError).json)
        }
        guard deviceState.isUnlockedSinceBoot else {
            logger.error("ignoring resetRateLimits: unavailable before first unlock")
            return completion(PrivateCloudComputeError(code: .unavailableBeforeFirstUnlock).json)
        }

        Task {
            await delegate.resetRateLimits()
            completion(nil)
        }
    }

    func fetchServerDrivenConfiguration(completion: @escaping @Sendable (Data) -> Void) {
        guard hasEntitlement(.admin) else {
            return completion(Data())
        }

        Task {
            let result = await delegate.fetchServerDrivenConfiguration()
            completion(result)
        }
    }

    func listServerDrivenConfiguration(completion: @escaping @Sendable (Data) -> Void) {
        guard hasEntitlement(.admin) else {
            return completion(Data())
        }

        Task {
            let result = await delegate.listServerDrivenConfiguration()
            completion(result)
        }
    }

    func setServerDrivenConfiguration(json: Data, completion: @escaping @Sendable (Data) -> Void) {
        guard hasEntitlement(.admin) else {
            return completion(Data())
        }

        Task {
            let result = await delegate.setServerDrivenConfiguration(json: json)
            completion(result)
        }
    }

    private func hasEntitlement(_ entitlement: PrivateCloudComputeEntitlement) -> Bool {
        guard let value = self.connection.value(forEntitlement: entitlement.rawValue) else {
            logger.log("entitlement not present: \(entitlement.rawValue)")
            return false
        }
        switch value {
        case let b as Bool:
            logger.log("entitlement observed: \(entitlement.rawValue) = \(b)")
            return b
        case let x:
            logger.log("entitlement is wrong type: \(entitlement.rawValue) = \(type(of: x))")
            return false
        }
    }

    private func effectiveUserIdentifier(auditToken: audit_token_t) -> uid_t? {
        #if os(macOS)
        let euid = audit_token_to_euid(auditToken)
        logger.debug("audit_token_to_euid=\(Int(euid))")
        return euid
        #else
        return nil
        #endif
    }
}
