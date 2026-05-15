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

import CloudBoardAsyncXPC
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobHelperAPI
import CloudBoardJobSupportAPI
import CloudBoardLogging
import CloudBoardMetrics
import CryptoKit
import Foundation
import InternalSwiftProtobuf
import os

/// Models CloudBoardJobHelper side of the API with a support app.
///
/// Manages the state of the support app process, including launching, warming it up and tearing it down,
/// monitors the state of the process, and provides an interface to allow the support app to access request-related
/// data.
package protocol ManagedSupportAppProtocol: ManagedAppProtocol, Actor {
    func run() async throws
    func endOfInput() async throws
    func receiveCryptoMaterial(_ materials: [InternalCryptoMaterial]) async throws
}

actor ManagedSupportApp: ManagedSupportAppProtocol, ManagedAppResponseHandlerProtocol {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ManagedSupportApp"
    )

    private static let tracingLogger = Logger(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "ManagedSupportApp"
    )

    private enum CryptoMaterialRegistrationState: Sendable {
        case unregistered
        case registering(queuedUpdates: [InternalCryptoMaterial])
        case registered
    }

    private let jobUUID: UUID
    private var requestID: String?
    private var spanID: UInt64?
    private let metrics: MetricsSystem

    /// Provides access to request secrets such as the DEK need to derive new secrets from client-provided key material
    private let requestSecrets: RequestSecrets

    /// If set, crypto material access XPC calls require the calling process to have a corresponding entitlement
    private let enforceSupportAppEntitlements: Bool
    private var cryptoMaterialRegistrationState = CryptoMaterialRegistrationState.unregistered
    private var cryptoMaterial: [UUID: InternalCryptoMaterial] = [:]

    private let managedApp: ManagedApp
    private let terminationHandler: (_ cleanTermination: Bool) async -> Void

    var remotePID: Int? {
        get async {
            return await self.managedApp.remotePID
        }
    }

    var abandoned: Bool {
        get async {
            return await self.managedApp.abandoned
        }
    }

    init(
        definition: any LaunchdJobDefinitionProtocol,
        xpcClientFactory: any ManagedAppXPCClientFactoryProtocol,
        requestSecrets: RequestSecrets,
        // this would only be false in unit tests
        enforceSupportAppEntitlements: Bool = true,
        metrics: any MetricsSystem,
        jobUUID: UUID,
        terminationHandler: @escaping (_ cleanTermination: Bool) async -> Void,
        spanID: UInt64?
    ) throws {
        self.jobUUID = jobUUID
        self.requestSecrets = requestSecrets
        self.enforceSupportAppEntitlements = enforceSupportAppEntitlements
        self.metrics = metrics
        self.spanID = spanID
        self.managedApp = ManagedApp(
            definition: definition,
            xpcClientFactory: xpcClientFactory,
            tracingLogger: Self.tracingLogger,
            logger: Self.logger,
            metrics: metrics,
            jobUUID: jobUUID,
            spanID: spanID
        )
        self.terminationHandler = terminationHandler
    }

    func run() async throws {
        try await self.managedApp.run(responseHandler: self)
    }

    func onTermination(statusCode: Int?) async {
        var cleanTermination: Bool
        if let statusCode, statusCode != 0 {
            // For now we don't treat an unclean exit as terminal and let the cloud app deal with a support app
            // potentially
            // becoming unavailable.
            await ManagedSupportAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: self.spanID,
                message: "Support app terminated with non-zero exit code",
            ).logAppTermination(statusCode: statusCode, to: Self.tracingLogger, level: .error)
            cleanTermination = false
        } else {
            await ManagedSupportAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: self.spanID,
                message: "Support app terminated",
            ).logAppTermination(statusCode: statusCode, to: Self.tracingLogger, level: .default)
            cleanTermination = true
        }
        await self.terminationHandler(cleanTermination)
    }

    func onDisconnect(error: (any Error)?) async {
        await ManagedSupportAppCheckpoint(
            jobID: self.jobUUID,
            requestID: self.requestID,
            remotePID: self.managedApp.remotePID,
            spanID: self.spanID,
            message: "Support app disconnected",
            error: error
        ).log(to: Self.tracingLogger, level: .default)
    }

    func onInternalError() async throws {
        // For now we don't treat an internal error as terminal and let the cloud app deal with a support app
        // potentially becoming unavailable.
        await ManagedSupportAppCheckpoint(
            jobID: self.jobUUID,
            requestID: self.requestID,
            remotePID: self.managedApp.remotePID,
            spanID: self.spanID,
            message: "Support app experienced unexpected internal error",
        ).log(to: Self.tracingLogger, level: .error)
    }

    func onJobFinished() async throws {
        // Nothing to do. We already log on app termination
        ()
    }

    // MARK: Jobhelper to Cloud App messages/events

    func warmup(info: ManagedWarmupInfo) async throws {
        try await self.managedApp.warmup(info: info)
    }

    func parameters(_ parametersData: ParametersData) async throws {
        self.requestID = parametersData.plaintextMetadata.requestID
        try await self.managedApp.parameters(parametersData)
    }

    func abandon() async throws {
        try await self.managedApp.abandon()
    }

    func teardown() async throws {
        try await self.managedApp.teardown()
    }

    // MARK: Support app to jobhelper messages/events

    nonisolated func configureMessageHandlers(store: inout CloudBoardAsyncXPCConnection.MessageHandlerStore) {
        store.register(CryptoMaterialRequest.self, handler: self.handleCryptoMaterialRequest)
        store.register(RegistrationForCryptoMaterialUpdates.self, handler: self.handleCryptoMaterialUpdateRegistration)
        store.register(KeyDerivationRequest.self, handler: self.deriveKeyFromDEK)
    }

    func handleCryptoMaterialRequest(request: CryptoMaterialRequest) async throws -> InternalCryptoMaterial {
        try await self.enforceEntitlement(kCloudBoardJobSupportAPICryptoMaterialAccessEntitlement)
        guard let requestedCryptoMaterial = self.cryptoMaterial[request.uuid] else {
            throw CryptoMaterialRequestError.unknownHandle
        }
        return requestedCryptoMaterial
    }

    func handleCryptoMaterialUpdateRegistration(
        registrationMessage _: RegistrationForCryptoMaterialUpdates
    ) async throws -> ExplicitSuccess {
        try await self.enforceEntitlement(kCloudBoardJobSupportAPICryptoMaterialAccessEntitlement)

        switch self.cryptoMaterialRegistrationState {
        case .registered, .registering:
            // This function is idempotent. If the support app has previously registered, we just do nothing and return.
            return ExplicitSuccess()
        case .unregistered:
            self.cryptoMaterialRegistrationState = .registering(queuedUpdates: self.cryptoMaterial.values.map { $0 })
        }

        while case .registering(queuedUpdates: var queuedUpdates) = self.cryptoMaterialRegistrationState,
              !queuedUpdates.isEmpty {
            let nextUpdate = queuedUpdates.removeFirst()
            self.cryptoMaterialRegistrationState = .registering(queuedUpdates: queuedUpdates)
            let message = CloudBoardSupportAppAPIXPCClientToServerMessage.CryptoMaterialMessage(nextUpdate)
            _ = try await self.managedApp.send(message)
        }

        self.cryptoMaterialRegistrationState = .registered
        return ExplicitSuccess()
    }

    func deriveKeyFromDEK(_ keyDerivationRequest: KeyDerivationRequest) async throws -> InternalDerivedKey {
        try await self.enforceEntitlement(kCloudBoardJobSupportAPIKeyDerivationEntitlement)
        do {
            let key = try await self.requestSecrets.deriveKey(
                info: Data(("dek-derived-key" + keyDerivationRequest.info).utf8),
                outputByteCount: keyDerivationRequest.outputByteCount
            )
            return .init(keyBytes: key.withUnsafeBytes { Data($0) })
        } catch is CancellationError {
            throw KeyDerivationError.cancelled
        } catch {
            await ManagedCloudAppCheckpoint(
                jobID: self.jobUUID,
                requestID: self.requestID,
                remotePID: self.managedApp.remotePID,
                spanID: self.spanID,
                message: "Failed to derive key",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            throw KeyDerivationError.failedKeyDerivation
        }
    }

    private func enforceEntitlement(_ entitlement: String) async throws {
        guard let xpcConnection = CloudBoardAsyncXPCContext.context?.peerConnection else {
            // This is a programming error, there is no condition where we would get a message but not have
            // a `peerConnection` available.
            Self.logger.error("XPC connection not available")
            fatalError("XPC connection not available")
        }
        let hasEntitlement = await xpcConnection.hasEntitlement(entitlement)
        if self.enforceSupportAppEntitlements, !hasEntitlement {
            Self.logger.error("Support app not entitled to access crypto material but this check is disabled")
        } else {
            guard hasEntitlement else {
                Self.logger.error("Support app not entitled to access crypto material")
                throw CloudBoardXPCAPIError.missingEntitlement(entitlement)
            }
        }
    }

    func receiveCryptoMaterial(_ materials: [InternalCryptoMaterial]) async throws {
        for material in materials {
            self.cryptoMaterial[material.handle.uuid] = material
        }
        switch self.cryptoMaterialRegistrationState {
        case .unregistered:
            // Nothing to do
            ()
        case .registering(let queuedUpdates):
            // Currently registering, queue the crypto material to be forwarded
            self.cryptoMaterialRegistrationState = .registering(queuedUpdates: queuedUpdates + materials)
        case .registered:
            // Registered for updates, forward the crypto material to the cloud app
            for material in materials {
                let message = CloudBoardSupportAppAPIXPCClientToServerMessage.CryptoMaterialMessage(material)
                _ = try await self.managedApp.send(message)
            }
        }
    }

    func endOfInput() async throws {
        _ = try await self.managedApp.send(CloudBoardSupportAppAPIXPCClientToServerMessage.EndOfInput())
    }
}

extension ManagedSupportApp {
    /// Testing only: handle of the underlying launchd job
    var _testJobInitiator: any LaunchdJobInstanceInitiatorProtocol {
        get async {
            await self.managedApp._testJobInitiator
        }
    }
}

struct ManagedSupportAppCheckpoint: RequestCheckpoint {
    private(set) var jobID: UUID
    private(set) var requestID: String?
    private(set) var remotePID: Int?
    var operationName: StaticString
    var serviceName: StaticString = "cb_jobhelper"
    var namespace: StaticString = "cloudboard"
    var error: Error?
    var message: StaticString
    var spanID: UInt64?

    public init(
        jobID: UUID,
        requestID: String?,
        remotePID: Int?,
        spanID: UInt64?,
        operationName: StaticString = #function,
        message: StaticString,
        error: Error? = nil
    ) {
        self.jobID = jobID
        self.requestID = requestID
        self.remotePID = remotePID
        self.spanID = spanID
        self.operationName = operationName
        self.message = message
        if let error {
            self.error = error
        }
    }

    func log(to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.jobID.uuidString, privacy: .public)
        remotePid=\(self.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        error.type=\(self.error.map { String(describing: Swift.type(of: $0)) } ?? "", privacy: .public)
        error.description=\(self.error.map { String(reportable: $0) } ?? "", privacy: .public)
        error.detailed=\(self.error.map { String(describing: $0) } ?? "", privacy: .private)
        message=\(self.message, privacy: .public)
        """)
    }

    func logAppTermination(statusCode: Int?, to logger: Logger, level: OSLogType = .default) {
        logger.log(level: level, """
        ttl=\(self.type, privacy: .public)
        jobID=\(self.jobID.uuidString, privacy: .public)
        remotePid=\(self.remotePID.map { String(describing: $0) } ?? "", privacy: .public)
        request.uuid=\(self.requestID ?? "", privacy: .public)
        tracing.name=\(self.operationName, privacy: .public)
        tracing.span_id=\(self.spanID?.hexEncoded ?? "", privacy: .public)
        tracing.type=\(self.type, privacy: .public)
        service.name=\(self.serviceName, privacy: .public)
        service.namespace=\(self.namespace, privacy: .public)
        status=\(status?.rawValue ?? "", privacy: .public)
        application_exit_code=\(statusCode.map { "\($0)" } ?? "", privacy: .public)
        message=\(self.message, privacy: .public)
        """)
    }
}
