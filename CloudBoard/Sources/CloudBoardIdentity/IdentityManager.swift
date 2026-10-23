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

import CloudBoardCommon
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
@_weakLinked import libnarrativecert
import Network
import notify
import os
import Security
import Security_Private.SecCertificatePriv
import Synchronization

public struct NarrativeBackendConfig: Sendable {
    let domain: NarrativeDomain
    let identityType: NarrativeIdentityType
    let aprn: String?
    let sanDNS: String?
    let tag: String?

    public init(
        domain: NarrativeDomain = .acdc,
        identityType: NarrativeIdentityType = .actor,
        aprn: String? = nil,
        sanDNS: String? = nil,
        tag: String? = nil
    ) {
        self.domain = domain
        self.identityType = identityType
        self.aprn = aprn
        self.sanDNS = sanDNS
        self.tag = tag
    }
}

public enum IdentityBackendType: Sendable {
    case selfsigned
    case narrative(config: NarrativeBackendConfig? = nil)
    case custom(backend: any IdentityBackend)
}

public final class IdentityManager: Sendable {
    public static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboardIdentity",
        category: "IdentityManager"
    )

    private static let metricsRecordingInterval: Duration = .seconds(60)
    private let cached: Mutex<ResolvedIdentity?>
    private let updatedLoopStarted: Mutex<Bool>
    private let metricsSystem: any MetricsSystem
    private let metricProcess: String
    private let backend: any IdentityBackend

    public init(
        metricsSystem: any MetricsSystem,
        metricProcess: String,
        identityBackendType: IdentityBackendType,
    ) {
        let backend = switch identityBackendType {
        case .custom(let backend):
            backend
        case .narrative(let config):
            LibnarrativecertIdentityBackend(config: config)
        case .selfsigned:
            SelfSignedBackend()
        }

        let initialIdentity = try? Self._recordLoad(metricsSystem: metricsSystem, metricProcess: metricProcess) {
            try backend.fetchInitialIdentity()
        }

        self.metricsSystem = metricsSystem
        self.metricProcess = metricProcess
        self.backend = backend
        self.cached = Mutex(initialIdentity)
        self.updatedLoopStarted = Mutex(false)
    }

    public var identity: ResolvedIdentity? {
        self.cached.withLock { $0 }
    }

    public var identityCallback: @Sendable () throws -> ResolvedIdentity? {
        {
            guard self.updatedLoopStarted.withLock({ $0 }) else {
                throw IdentityManagerError.updateLoopNotStarted
            }
            return self.identity
        }
    }

    public func identityUpdateLoop() async {
        await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask { await self.runIdentityUpdateLoop() }
            taskGroup.addTask { await self.runMetricsRecordingLoop() }
        }
    }

    public func waitForInitialIdentity(
        backoffStrategy: ExponentialBackoffStrategy
    ) async throws {
        guard self.identity == nil else { return }
        Self.logger.log("Initial identity not loaded; attempting to load with exponential backoff")
        let retryStrategy = RetryWithBackoff(
            backoffStrategy: backoffStrategy,
            deadline: .noDeadline,
            logger: Self.logger
        ) { _ in .continue }
        let identity = try await executeWithRetries(retryStrategy: retryStrategy) {
            try Self._recordLoad(metricsSystem: self.metricsSystem, metricProcess: self.metricProcess) {
                try self.backend.fetchInitialIdentity()
            }
        }
        self.cached.withLock { $0 = identity }
        Self.logger.log("Successfully loaded identity")
    }

    private func runIdentityUpdateLoop() async {
        let initialIdentity = self.identity
        self.updatedLoopStarted.withLock { $0 = true }
        Self.logger.log("Identity update loop starting")
        for await _ in CertificateReloadNotifications(identity: initialIdentity) {
            Self.logger.debug("Attempting to reload identity")
            let identity: ResolvedIdentity
            do {
                // Force-unwrap here is safe: we can only reload if we know
                // the identity details.
                let domain = initialIdentity!.details!.domain
                let identityType = initialIdentity!.details!.type
                Self.logger.info("""
                Attempting to reload identity 
                \(domain.rawValue, privacy: .public) (\(identityType.rawValue, privacy: .public))
                """)
                identity = try Self._recordLoad(metricsSystem: self.metricsSystem, metricProcess: self.metricProcess) {
                    try self.backend.fetchSpecificIdentity(
                        domain: domain,
                        identityType: identityType
                    )
                }
            } catch {
                Self.logger.error(
                    "Error reloading identity: \(String(unredacted: error), privacy: .public). Retaining existing identity until next increment."
                )
                continue
            }
            self.cached.withLock { $0 = identity }
            Self.logger.log("Successfully reloaded identity")
        }
        Self.logger.log("Identity update loop complete")
    }

    private func runMetricsRecordingLoop() async {
        while true {
            do {
                try await Task.sleep(for: Self.metricsRecordingInterval)
            } catch {
                Self.logger.log("Metrics recording task cancelled")
                return
            }
            self.emitCertTimeToExpiryMetric()
        }
    }

    internal func emitCertTimeToExpiryMetric() {
        guard let identity = self.identity else {
            return
        }
        guard let fullCertChain = identity.credential.certificates as? [SecCertificate] else {
            Self.logger.error("Certificate chain is not of type [SecCertificate]")
            return
        }
        guard let leafCert = fullCertChain.first else {
            Self.logger.error("Certificate chain is empty")
            return
        }
        guard let expirationTime = leafCert.expirationTime else {
            Self.logger.error("Unable to obtain leaf certificate's expiration time")
            return
        }

        let certTimeToExpiryGauge = Metrics.IdentityManager.CertTimeToExpiryGauge(
            expirationTime: expirationTime,
            processName: self.metricProcess
        )
        self.metricsSystem.emit(certTimeToExpiryGauge)
    }

    private static func _recordLoad(
        metricsSystem: any MetricsSystem,
        metricProcess: String,
        _ block: () throws -> ResolvedIdentity
    ) rethrows -> ResolvedIdentity {
        do {
            // Emits a identity load metric whenever we attempt to obtain a new identity.
            metricsSystem.emit(
                Metrics.IdentityManager.LoadIdentityCounter(dimensions: [.process: metricProcess], action: .increment)
            )
            let identity = try block()
            return identity
        } catch {
            metricsSystem.emit(
                Metrics.IdentityManager.LoadIdentityErrorCounter.Factory(dimensions: [.process: metricProcess])
                    .make(error)
            )
            throw error
        }
    }

    public struct ResolvedIdentity: Sendable {
        public var base: SecIdentity
        public var chain: [SecCertificate]
        public var details: IdentityDetails?
        public var credential: URLCredential

        public struct IdentityDetails: Sendable {
            public var refreshedNotificationName: String
            public var domain: NarrativeDomain
            public var type: NarrativeIdentityType
        }

        public init(
            base: SecIdentity,
            chain: [SecCertificate],
            details: IdentityDetails? = nil,
            credential: URLCredential
        ) {
            self.base = base
            self.chain = chain
            self.details = details
            self.credential = credential
        }

        public init(base: SecIdentity) {
            self.init(
                base: base,
                chain: [],
                credential: .init(
                    identity: base,
                    certificates: nil,
                    persistence: .none
                )
            )
        }
    }
}

struct CertificateReloadNotifications: AsyncSequence {
    typealias Element = Void

    private static let queue = DispatchQueue(label: "CertificateReloadNotificationQueue")
    private let name: String

    init(identity: IdentityManager.ResolvedIdentity?) {
        if let name = identity?.details?.refreshedNotificationName {
            self.name = name
        } else {
            // This should only happen if we're using self-signed certs, but we want to
            // emit a warning log anyway. Then, we'll use a name we are confident no-one
            // else is using.
            IdentityManager.logger.warning("No cert refresh notification name available: cert will never reload.")
            self.name = "com.apple.cloudos.CloudBoardDCore.impossible-refresh-notification-name"
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        var token: CInt = 0
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        notify_register_dispatch(self.name, &token, Self.queue) { _ in
            continuation.yield()
        }
        continuation.onTermination = { [token] _ in
            notify_cancel(token)
        }

        return AsyncIterator(streamIterator: stream.makeAsyncIterator())
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        private var streamIterator: AsyncStream<Void>.AsyncIterator

        init(
            streamIterator: AsyncStream<Void>.AsyncIterator
        ) {
            self.streamIterator = streamIterator
        }

        mutating func next() async -> Void? {
            return await self.streamIterator.next()
        }
    }
}

public enum IdentityManagerError: Error, Equatable {
    case certificateNotAvailable(NarrativeDomain, NarrativeIdentityType)
    case unableToRunSecureService
    case unableToCreateIdentity(NarrativeDomain, NarrativeIdentityType)
    case unableToParseChainCert(NarrativeDomain, NarrativeIdentityType, String)
    case unimplementedFunctionality
    case updateLoopNotStarted
}

extension SecCertificate {
    var commonName: String {
        var string: CFString?
        let rc = SecCertificateCopyCommonName(self, &string)
        guard rc == errSecSuccess, let string else {
            return ""
        }
        return string as String
    }

    var expirationTime: CFAbsoluteTime? {
        let time = SecCertificateNotValidAfter(self)
        return time == 0 ? nil : time
    }
}

public protocol IdentityBackend: Sendable {
    func fetchInitialIdentity() throws -> IdentityManager.ResolvedIdentity

    func fetchSpecificIdentity(
        domain: NarrativeDomain,
        identityType: NarrativeIdentityType
    ) throws -> IdentityManager.ResolvedIdentity
}

struct LibnarrativecertIdentityBackend: IdentityBackend {
    let domain: NarrativeDomain
    let identityType: NarrativeIdentityType
    let aprn: String?
    let sanDNS: String?
    let tag: String?

    init(config: NarrativeBackendConfig?) {
        if let config {
            self.domain = config.domain
            self.identityType = config.identityType
            self.aprn = config.aprn
            self.sanDNS = config.sanDNS
            self.tag = config.tag
        } else {
            self.domain = .acdc
            self.identityType = .actor
            self.aprn = nil
            self.sanDNS = nil
            self.tag = nil
        }
    }

    func fetchInitialIdentity() throws -> IdentityManager.ResolvedIdentity {
        guard #_hasSymbol(NarrativeCert.self) else {
            IdentityManager.logger.warning("Narrative cert framework unavailable, proceeding without credentials")
            throw IdentityManagerError.unableToRunSecureService
        }

        try self.configureIdentity()

        do {
            let domain = self.domain.rawValue
            let identityType = self.identityType.rawValue
            IdentityManager.logger.log("""
            Attempting to load narrative identity: 
            attempting \(domain, privacy: .public) \(identityType, privacy: .public) identity"
            """)
            return try self.fetchSpecificIdentity(domain: self.domain, identityType: self.identityType)
        } catch {
            if self.domain == .aquaria {
                // Aquaria identity is independent of adb
                IdentityManager.logger.warning(
                    "Unable to load \(self.domain.rawValue, privacy: .public) actor identity: \(String(unredacted: error), privacy: .public)."
                )
                throw error
            } else {
                IdentityManager.logger.warning(
                    "Unable to load \(self.domain.rawValue, privacy: .public) actor identity: \(String(unredacted: error), privacy: .public). Falling back to ADB host identity."
                )
                // Fallthrough here is deliberate.
            }
        }

        do {
            IdentityManager.logger.info("Attempting to load narrative identity: attempting adb host identity")
            return try self.fetchSpecificIdentity(domain: .adb, identityType: .host)
        } catch {
            IdentityManager.logger.error(
                "Unable to load ADB platform identity: \(String(unredacted: error), privacy: .public). Proceeding without credentials."
            )
            throw error
        }
    }

    func fetchSpecificIdentity(
        domain: NarrativeDomain,
        identityType: NarrativeIdentityType
    ) throws -> IdentityManager.ResolvedIdentity {
        let cert = if let tag = self.tag {
            NarrativeCert(domain: domain, identityType: identityType, tag: tag)
        } else {
            NarrativeCert(domain: domain, identityType: identityType)
        }
        let refs = cert.fetchSecRefsFromKeychain()
        guard let certRef = refs?.certRef,
              let keyRef = refs?.keyRef else {
            throw IdentityManagerError.certificateNotAvailable(domain, identityType)
        }
        let parsedIdentity = SecIdentityCreate(nil, certRef, keyRef)
        guard let parsedIdentity else {
            throw IdentityManagerError.unableToCreateIdentity(domain, identityType)
        }
        IdentityManager.logger.log("Loaded identity \(certRef.commonName, privacy: .public)")

        // We drop last here because there is no point serving the root CA.
        // It only wastes CPU and network bandwidth. The remote peer can't use
        // it to validate, so let's just omit it.
        let chain = try cert.getCertChain().dropLast().map {
            IdentityManager.logger.log("Parsing chain cert: \($0, privacy: .public)")
            guard let der = Data(base64Encoded: $0),
                  let cert = SecCertificateCreateWithData(nil, der as CFData) else {
                IdentityManager.logger.error("Unable to parse chain cert: \($0, privacy: .public)")
                throw IdentityManagerError.unableToParseChainCert(domain, identityType, $0)
            }
            return cert
        }
        let identity = parsedIdentity.takeRetainedValue()

        let fullChain: [SecCertificate] = [certRef] + chain
        let credential = URLCredential(
            identity: identity,
            certificates: fullChain,
            persistence: .none
        )

        return .init(
            base: identity,
            chain: chain,
            details: .init(
                refreshedNotificationName: cert.refreshedNotificationName,
                domain: domain,
                type: identityType
            ),
            credential: credential
        )
    }

    private func configureIdentity() throws {
        guard let aprn = self.aprn, let sanDNS = self.sanDNS, let tag = self.tag else {
            return
        }
        let options = [
            NarrativeCertOptions.aprn: aprn,
            NarrativeCertOptions.sanDNS: sanDNS,
            NarrativeCertOptions.tag: tag,
        ]
        let client = NarrativeXPCClient()
        let domain = self.domain
        let identityType = self.identityType
        do {
            IdentityManager.logger.log("""
            Configure identity for 
            \(domain.rawValue, privacy: .public) with \(identityType.rawValue, privacy: .public).
            """)

            /// First time ConfigureIdentity is called it downloads the cert for the specified domain and identityType
            /// pair
            /// Any request after that returns immediately
            /// So, its safe to call ConfigureIdentity multiple times during a process lifecycle or across multiple
            /// processes as well.
            try client.ConfigureIdentity(
                narrativeDomain: domain,
                narrativeIdentityType: identityType,
                options: options
            )
        } catch {
            IdentityManager.logger.error("""
            Unable to configure identity for 
            \(domain.rawValue, privacy: .public): \(String(unredacted: error), privacy: .public)."
            """)
            throw error
        }
    }
}

struct SelfSignedBackend: IdentityBackend {
    func fetchInitialIdentity() throws -> IdentityManager.ResolvedIdentity {
        try SelfSignedIdentity().makeResolvedIdentity()
    }

    func fetchSpecificIdentity(
        domain _: NarrativeDomain,
        identityType _: NarrativeIdentityType
    ) throws -> IdentityManager.ResolvedIdentity {
        IdentityManager.logger.error("Should not have fetch specific identity called for SelfSignedBackend.")
        throw IdentityManagerError.unimplementedFunctionality
    }
}
