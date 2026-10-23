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

import CloudBoardAsyncXPC
import CloudBoardAttestationDAPI
import CloudBoardBridgeDAPI
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobAPI
import CloudBoardJobAuthDAPI
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
#if RC_IS_CLOUDOS_ENABLED
import CloudConfigurationPreferences
#elseif canImport(CloudConfigurationPreferences)
@_weakLinked import CloudConfigurationPreferences
#else
#warning("CloudConfigurationPreferences not available at compile time")
#endif
import Foundation
import os
import Synchronization
import Tracing

enum CloudBoardJobHelperError: ReportableError {
    case unableToFindCloudAppToManage
    case restrictedChoiceModeInvalid(details: String)

    var publicDescription: String {
        let errorType = switch self {
        case .unableToFindCloudAppToManage: "unableToFindCloudAppToManage"
        case .restrictedChoiceModeInvalid(details: let details):
            // The details are only about the workload parameter itself, hence are already public
            "restrictedChoiceModeInvalid(\(details))"
        }
        return "jobHelper.\(errorType)"
    }
}

/// Auto-failure cause for the `WorkloadJobManager` promise — fired by
/// `Promise.deinit` if the manager-creating task is cancelled before it
/// fulfills the promise. Lets the attestation drain task observe a concrete
/// failure instead of waiting forever.
enum WorkloadJobManagerUnavailableError: Error {
    case cancelled
}

struct CloudBoardJobHelperHotProperties: Decodable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case _maxRequestMessageSize = "MaxRequestMessageSize"
    }

    private var _maxRequestMessageSize: Int?

    var maxRequestMessageSize: Int {
        self._maxRequestMessageSize ?? 1024 * 1024 * 4 // 4MB
    }
}

/// Per-request process implementing an end-to-end encrypted protocol with privatecloudcomputed on the client. It is
/// responsible for decrypting the request stream and encrypting the response stream to and from the cloud app.
public actor CloudBoardJobHelper {
    private let tracer: any Tracer

    let hostType: JobHelperHostType
    let server: CloudBoardJobHelperAPIServerProtocol
    let attestationClient: CloudBoardAttestationAPIClientProtocol
    let jobAuthClient: CloudBoardJobAuthAPIClientProtocol?
    let bridgeClient: CloudBoardBridgeAPIClientProtocol
    let launchdJobFinder: LaunchdJobFinderProtocol
    private let shadowConfigLookup: @Sendable (String) throws -> SecureConfig.ShadowCloudAppConfig
    let pirHelper: PIRHelperProtocol
    let effortDegrader: PolicyControlledEffortDegrader
    let metrics: any MetricsSystem
    let laContextProvider: LocalAuthContextProvider
    let workloadPromise: Promise<(ManagedCloudAppProtocol, [ManagedSupportAppProtocol], [AssetMetadata]), Error> =
        .init(
            autoFailureIfUnfulfilled: CloudBoardMessenger
                .CloudBoardMessengerError.warmupNeverCalled
        )
    var requestID: String
    var jobUUID: UUID
    var workloadProvider: CloudBoardJobHelperWorkloadProvider
    var hotPropertiesProvider: CloudBoardJobHelperHotPropertiesProvider
    let config: CBJobHelperConfiguration

    private var managedCloudApp: ManagedCloudAppProtocol {
        get async throws {
            try await Future(self.workloadPromise).valueWithCancellation.0
        }
    }

    private var managedSupportApps: [ManagedSupportAppProtocol] {
        get async throws {
            try await Future(self.workloadPromise).valueWithCancellation.1
        }
    }

    private var assetsMetadata: [AssetMetadata] {
        get async throws {
            try await Future(self.workloadPromise).valueWithCancellation.2
        }
    }

    private var cloudAppRemotePID: Int? {
        get async {
            do {
                return try await self.managedCloudApp.remotePID
            } catch {
                return nil
            }
        }
    }

    // Useful for tests - true once a real request/nack request is sent to the helper
    internal nonisolated let usedForRequest = OSAllocatedUnfairLock<Bool>(initialState: false)

    public static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "cb_jobhelper"
    )

    public static let tracingLogger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard.tracing",
        category: "cb_jobhelper"
    )

    public init(
        configuration: CBJobHelperConfiguration
    ) async {
        // for now there's no support for nacks directly
        self.hostType = configuration.isProxy ? .proxy : .worker
        self.server = CloudBoardJobHelperAPIXPCServer.localListener()
        self.attestationClient = await CloudBoardAttestationAPIXPCClient.localConnection()
        self.jobAuthClient = nil
        self.bridgeClient = await CloudBoardBridgeAPIXPCClient.localConnection(logger: Self.logger)
        self.metrics = CloudMetricsSystem(clientName: Metrics.ProcessInfo.prefix)
        self.tracer = RequestSummaryJobHelperTracer(metrics: self.metrics)
        self.requestID = ""
        self.launchdJobFinder = LaunchdJobFinder(metrics: self.metrics)

        if configuration.enablePIR {
            #if canImport(CipherMLSE)
            self.pirHelper = PIRHelper()
            #else
            Self.logger.warning("PIR is enabled but CipherMLSE is not available. Using NoOpPIRHelper.")
            self.pirHelper = NoOpPIRHelper()
            #endif
        } else {
            Self.logger.log("PIR is not enabled. Using NoOpPIRHelper.")
            self.pirHelper = NoOpPIRHelper()
        }

        self.effortDegrader = PolicyControlledEffortDegrader(
            securityPolicy: configuration.secureConfig.securityPolicy,
            configuration: configuration.effortPrivacy
        )
        let myUUID = self.launchdJobFinder.currentJobUUID(logger: Self.logger)
        if myUUID == nil {
            Self.logger.warning("Could not get own job UUID, creating new UUID for app")
        }
        self.jobUUID = myUUID ?? UUID()

        // Initialize providers
        let managedAppXPCClientFactory = ManagedAppXPCClientFactory()
        self.workloadProvider = LaunchdWorkloadProvider(
            launchdJobFinder: self.launchdJobFinder,
            cloudAppClientFactory: managedAppXPCClientFactory,
            supportAppClientFactory: managedAppXPCClientFactory,
            metrics: self.metrics
        )
        self.hotPropertiesProvider = PreferencesUpdatesProvider()
        self.config = configuration
        self.laContextProvider = DefaultLocalAuthContextProvider()
        let secureConfig = configuration.secureConfig
        self.shadowConfigLookup = { cloudAppName in
            // this performs the needed policy checks if shadow is enabled
            let config = try secureConfig.cloudAppConfig(cloudApp: cloudAppName)
            return config.shadow
        }
    }

    // For testing only
    internal init(
        hostType: JobHelperHostType,
        cloudAppName: String? = nil,
        secureConfig: SecureConfig,
        server: any CloudBoardJobHelperAPIServerProtocol,
        attestationClient: any CloudBoardAttestationAPIClientProtocol,
        jobAuthClient: CloudBoardJobAuthAPIClientProtocol,
        bridgeClient: CloudBoardBridgeAPIClientProtocol,
        workloadProvider: CloudBoardJobHelperWorkloadProvider,
        hotPropertiesProvider: CloudBoardJobHelperHotPropertiesProvider,
        launchdJobFinder: LaunchdJobFinderProtocol? = nil,
        pirHelper: PIRHelperProtocol,
        effortDegrader: PolicyControlledEffortDegrader? = nil,
        metrics: any MetricsSystem,
        laContextProvider: LocalAuthContextProvider
    ) {
        self.hostType = hostType
        self.server = server
        self.attestationClient = attestationClient
        self.jobAuthClient = jobAuthClient
        self.bridgeClient = bridgeClient
        self.metrics = metrics
        self.requestID = ""
        self.pirHelper = pirHelper
        self.effortDegrader = effortDegrader ?? PolicyControlledEffortDegrader(
            securityPolicy: secureConfig.securityPolicy
        )
        self.tracer = RequestSummaryJobHelperTracer(metrics: metrics)

        let launchdJobFinder = launchdJobFinder ?? LaunchdJobFinder(metrics: metrics)
        self.launchdJobFinder = launchdJobFinder
        if let currentUUID = launchdJobFinder.currentJobUUID(logger: Self.logger) {
            self.jobUUID = currentUUID
        } else {
            let jobUUID = UUID()
            self.jobUUID = jobUUID
            Self.logger.warning("""
            jobID=\(jobUUID.uuidString, privacy: .public)
            message=\("Could not get own job UUID, creating new UUID for app")
            """)
        }

        self.workloadProvider = workloadProvider
        self.hotPropertiesProvider = hotPropertiesProvider

        switch (secureConfig.isProxy, hostType) {
        case (true, .proxy), (true, .nack), (false, .worker):
            () // fine
        default:
            preconditionFailure(
                "Inconsistent parameters isProxy:\(secureConfig.isProxy) hostType:\(hostType)"
            )
        }
        var config = CBJobHelperConfiguration(secureConfig: secureConfig, cloudAppName: cloudAppName)
        self.config = config
        self.laContextProvider = laContextProvider
        // By disallowing shadow functionality via unit tests we keep the use of it in customer deployed code
        // gated behind the securityPolicy check in all cases.
        self.shadowConfigLookup = { _ in
            return .notShadowed
        }
    }

    /// Emit the launch metrics.
    private func emitLaunchMetrics() {
        self.metrics.emit(Metrics.Daemon.LaunchCounter(action: .increment))
    }

    /// Updates the metrics with the current values, called periodically.
    /// - Parameter startInstant: The instant at which the daemon started.
    private func updateMetrics(startInstant: ContinuousClock.Instant) {
        let uptime = Int(clamping: startInstant.duration(to: .now).components.seconds)
        self.metrics.emit(Metrics.Daemon.UptimeGauge(value: uptime))
    }

    private func setRequestID(_ requestID: String) {
        self.requestID = requestID
        self.usedForRequest.withLock { $0 = true }
    }

    public func start() async throws {
        return try await CloudBoardMetrics.Uptime.withStandardMetrics(
            processInfo: Metrics.ProcessInfo.self,
            metrics: self.metrics,
            self._start
        )
    }

    /// Use ``start()`` to get the standard metrics
    private func _start() async throws {
        let jobHelperSpanID: UInt64 = TraceContextCache.singletonCache.generateNewSpanID()
        CloudboardJobHelperCheckpoint(logMetadata: logMetadata(spanID: jobHelperSpanID), message: "Starting")
            .log(to: Self.tracingLogger, level: .default)
        // Records the error that terminated the job, if any, so the "Finished"
        // checkpoint below is logged exactly once per exit path with the right
        // level.
        var exitError: (any Error)?
        defer {
            self.metrics.emit(Metrics.Daemon.TotalExitCounter(action: .increment))
            self.metrics.invalidate()
            let level: OSLogType = exitError.map { isBenignTeardownError($0) ? .info : .error } ?? .default
            CloudboardJobHelperCheckpoint(
                logMetadata: logMetadata(spanID: jobHelperSpanID),
                message: "Finished",
                error: exitError
            ).log(to: Self.tracingLogger, level: level)
        }
        self.emitLaunchMetrics()

        let preferences = try await self.hotPropertiesProvider.getPreferences()
        let maxRequestMsgSize = preferences.maxRequestMessageSize

        // Create streams for communication between the different cb_jobhelper components
        let (wrappedRequestStream, wrappedRequestContinuation) = AsyncStream<PipelinePayload>.makeStream()
        let (wrappedResponseStream, wrappedResponseContinuation) = AsyncStream<WorkloadJobManager.OutboundMessage>
            .makeStream()
        let (cloudAppRequestStream, cloudAppRequestContinuation) = AsyncStream<PipelinePayload>.makeStream()

        let jobAuthClient: CloudBoardJobAuthAPIClientProtocol = if self.jobAuthClient != nil {
            self.jobAuthClient!
        } else {
            await CloudBoardJobAuthAPIXPCClient.localConnection()
        }
        await jobAuthClient.connect()

        let bridgeClient = self.bridgeClient
        await bridgeClient.connect()

        let requestSecrets = RequestSecrets()

        let proxyCapability: WorkloadJobManager.ProxyCapability? = self.config.isProxy ? .init() : nil
        let pirHelper = self.pirHelper
        let cloudBoardMessenger = CloudBoardMessenger(
            hostType: self.hostType,
            attestationClient: self.attestationClient,
            server: self.server,
            bridgeClient: self.bridgeClient,
            workloadProvider: self.workloadProvider,
            trampolineWorkloadProvider: self.config.isProxy ? TrampolineWorkloadProvider() : nil,
            workloadPromise: self.workloadPromise,
            pirHelper: pirHelper,
            requestSecrets: requestSecrets,
            encodedRequestContinuation: wrappedRequestContinuation,
            responseStream: wrappedResponseStream,
            metrics: self.metrics,
            jobUUID: self.jobUUID,
            jobHelperSpanID: jobHelperSpanID,
            laContextProvider: self.laContextProvider,
            shadowConfigLookup: self.shadowConfigLookup,
            proxyCapability: proxyCapability
        )

        pirHelper.setEncryptedRequestHandler { encryptedRequest, traceContext in
            return try await bridgeClient.makePIREncryptedRequest(encryptedRequest, traceContext: traceContext)
        }

        // We need to register for key rotation events as keys might rotate while cb_jobhelper runs but before we
        // receive a request, in particular with prewarming enabled.
        let attestationClientRouter = await AttestationClientRouter(
            attestationClient: self.attestationClient,
            messenger: cloudBoardMessenger,
            onSurpriseDisconnect: {
                await CloudboardJobHelperCheckpoint(
                    logMetadata: self.logMetadata(spanID: jobHelperSpanID),
                    message: "XPC connection to CloudBoard attestation daemon terminated unexpectedly. Attempting to reconnect."
                ).log(to: Self.tracingLogger, level: .error)
            }
        )

        // Fetch cost token signing key from cb_jobauthd
        let costTokenSigner: CostTokenSigner?
        do {
            CloudboardJobHelperCheckpoint(
                logMetadata: self.logMetadata(spanID: jobHelperSpanID),
                message: "Requesting cost token signing key from cb_jobauthd"
            ).log(to: Self.tracingLogger, level: .info)

            let costTokenSigningKey = try await jobAuthClient.requestCostTokenSigningKey()
            costTokenSigner = try CostTokenSigner(costTokenSigningKey: costTokenSigningKey)

            CloudboardJobHelperCheckpoint(
                logMetadata: self.logMetadata(spanID: jobHelperSpanID),
                message: "Successfully initialized CostTokenSigner with key from cb_jobauthd"
            ).log(to: Self.tracingLogger, level: .info)
        } catch {
            CloudboardJobHelperCheckpoint(
                logMetadata: self.logMetadata(spanID: jobHelperSpanID),
                message: "Failed to load cost token signing key from cb_jobauthd. Cost tokens will NOT be generated for this session.",
                error: error
            ).log(to: Self.tracingLogger, level: .error)
            costTokenSigner = nil
        }

        let jobAuthClientDelegate = JobAuthClientDelegate(costTokenSigner: costTokenSigner)
        await jobAuthClient.set(delegate: jobAuthClientDelegate)

        let isProxy = self.config.isProxy
        let secureConfig = self.config.secureConfig

        // Load reputation PAT signing key
        let reputationPATSigner: ReputationPATSigner?
        if let keyBase64 = secureConfig.reputationPATSigningKey {
            do {
                guard let keyData = Data(base64Encoded: keyBase64, options: .ignoreUnknownCharacters) else {
                    throw ReputationPATSignerError.invalidKeyFormat
                }
                reputationPATSigner = try ReputationPATSigner(derRepresentation: keyData)
                CloudboardJobHelperCheckpoint(
                    logMetadata: self.logMetadata(spanID: jobHelperSpanID),
                    message: "Successfully initialized ReputationPATSigner"
                ).log(to: Self.tracingLogger, level: .info)
            } catch {
                CloudboardJobHelperCheckpoint(
                    logMetadata: self.logMetadata(spanID: jobHelperSpanID),
                    message: "Failed to initialize ReputationPATSigner. Reputation PATs will not be issued for this session.",
                    error: error
                ).log(to: Self.tracingLogger, level: .error)
                reputationPATSigner = nil
            }
        } else {
            CloudboardJobHelperCheckpoint(
                logMetadata: self.logMetadata(spanID: jobHelperSpanID),
                message: "No reputation PAT signing key configured. Reputation PATs will not be issued for this session."
            ).log(to: Self.tracingLogger, level: .info)
            reputationPATSigner = nil
        }
        await self.server.set(delegate: cloudBoardMessenger)
        await self.server.connect()

        // Compute enabled persistent service routers ahead of time (no I/O needed)
        let persistentServiceEnabledRouters: [(serviceID: UInt64, machServiceName: String)]
        if isProxy, !secureConfig.persistentServiceClients.isEmpty {
            persistentServiceEnabledRouters = PersistentServiceRouter.enabledRouters(
                for: secureConfig.persistentServiceClients
            )
            if persistentServiceEnabledRouters.isEmpty {
                Self.logger.warning(
                    "persistentServiceClients configured but no known routes matched"
                )
            }
        } else {
            persistentServiceEnabledRouters = []
        }

        do {
            try await self.withMetricsUpdates(spanID: jobHelperSpanID) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    let cloudApp = try await self.managedCloudApp
                    let supportApps = try await self.managedSupportApps
                    let negotiationRules = try SelectionNegotiationSetup.cloudAppSelectionNegotiationRules(
                        cloudAppName: cloudApp.cloudAppName, secureConfig: secureConfig
                    )

                    // Create persistent service router now that cloudApp is available for response forwarding
                    let persistentServiceRouter: PersistentServiceRouter?
                    let persistentServiceTrustController: PersistentServiceTrustController?
                    // The attestation drain task and the WorkloadJobManager task are
                    // siblings in this task group and start in unspecified order. Use a
                    // Promise so the drain task awaits the manager rather than racing
                    // against a shared holder and silently dropping early reports.
                    // `autoFailureIfUnfulfilled` covers the path where the manager
                    // task is cancelled before it finishes constructing.
                    let workloadJobManagerPromise = Promise<WorkloadJobManager, WorkloadJobManagerUnavailableError>(
                        autoFailureIfUnfulfilled: .cancelled
                    )
                    if !persistentServiceEnabledRouters.isEmpty {
                        let router = await PersistentServiceRouter(
                            enabledRouters: persistentServiceEnabledRouters,
                            helperID: self.jobUUID,
                            attestationUsageReportsBufferLimit: secureConfig.attestationUsageReportsBufferLimit,
                            onResponse: { response in
                                do {
                                    try await cloudApp.sendPersistentServiceResponse(response)
                                } catch {
                                    Self.logger.log(
                                        "Failed to forward persistent service response: \(String(unredacted: error), privacy: .public)"
                                    )
                                }
                            }
                        )
                        persistentServiceRouter = router
                        persistentServiceTrustController = PersistentServiceTrustController(
                            maxTrustedEnsembleInstances: 100
                        )
                    } else {
                        persistentServiceRouter = nil
                        persistentServiceTrustController = nil
                    }

                    do {
                        // Guaranteed cleanup for the attestation drain task regardless
                        // of how this do-block exits (normal completion OR a sibling
                        // throw). Without this defer, a throw during `for try await _
                        // in group` would skip the in-loop shutdown and leave the
                        // drain task parked on the router's stream until task
                        // cancellation eventually unwound it.
                        defer { persistentServiceRouter?.shutdownAttestationUsageReports() }

                        group.addTaskWithLogging(
                            operation: "cloudBoardMessenger.run()",
                            metrics: .init(
                                metricsSystem: self.metrics,
                                errorFactory: Metrics.Messenger.OverallErrorCounter.Factory()
                            ),
                            logger: Self.tracingLogger,
                            level: .info
                        ) {
                            try await cloudBoardMessenger.run()
                        }

                        // Capture actor-isolated properties before entering the task closure
                        let effortDegrader = self.effortDegrader
                        let attestationClient = self.attestationClient
                        let helperMetrics = self.metrics
                        let jobUUID = await self.jobUUID
                        let helperTracer = self.tracer
                        let managedSupportAppsFuture = try await self.managedSupportApps
                        let assetsMetadataFuture = try await self.assetsMetadata

                        group.addTaskWithLogging(
                            operation: "workloadJobManager.run()",
                            metrics: .init(
                                metricsSystem: self.metrics,
                                errorFactory: Metrics.WorkloadManager.OverallErrorCounter.Factory()
                            ),
                            logger: Self.tracingLogger,
                            level: .info
                        ) {
                            let workloadJobManager = WorkloadJobManager(
                                effortDegrader: effortDegrader,
                                isProxy: isProxy,
                                securityPolicy: secureConfig.securityPolicy,
                                diagnosticsSharingOverride: self.config.diagnosticsSharingOverride,
                                requestStream: wrappedRequestStream,
                                maxRequestMessageSize: maxRequestMsgSize,
                                responseContinuation: wrappedResponseContinuation,
                                cloudAppRequestContinuation: cloudAppRequestContinuation,
                                managedCloudApp: cloudApp,
                                managedSupportApps: managedSupportAppsFuture,
                                assetsMetadata: assetsMetadataFuture,
                                attestationValidator: attestationClient,
                                negotiationRules: negotiationRules,
                                metrics: helperMetrics,
                                jobUUID: jobUUID,
                                tracer: helperTracer,
                                jobHelperSpanID: jobHelperSpanID,
                                costTokenSigner: costTokenSigner,
                                reputationPATSigner: reputationPATSigner,
                                skipMultiAppValidations: secureConfig.skipMultiAppValidations,
                                persistentServiceRouter: persistentServiceRouter,
                                persistentServiceTrustController: persistentServiceTrustController,
                                proxyCapability: proxyCapability
                            )
                            workloadJobManagerPromise.succeed(with: workloadJobManager)
                            await workloadJobManager.run()
                        }

                        // Drain attestation usage reports from the persistent service router
                        // and run the (async, crypto-heavy) validation here so the XPC event
                        // loop is never blocked. One structured task per job.
                        if let persistentServiceRouter {
                            group.addTaskWithLogging(
                                operation: "persistentServiceAttestationReports.drain",
                                metrics: .init(
                                    metricsSystem: self.metrics,
                                    errorFactory: Metrics.WorkloadManager.OverallErrorCounter.Factory()
                                ),
                                logger: Self.tracingLogger,
                                level: .info
                            ) {
                                // Wait for the WorkloadJobManager — reports yielded into
                                // `attestationUsageReports` before this resumes are buffered
                                // by the bounded AsyncStream and delivered in order once
                                // iteration begins.
                                let manager: WorkloadJobManager
                                do {
                                    manager = try await Future(workloadJobManagerPromise).valueWithCancellation
                                } catch {
                                    Self.logger.warning(
                                        "WorkloadJobManager unavailable; attestation drain task exiting without consuming reports: \(String(unredacted: error), privacy: .public)"
                                    )
                                    return
                                }
                                for await (report, serviceID) in persistentServiceRouter.attestationUsageReports {
                                    do {
                                        try await manager.handlePersistentServiceAttestationReport(
                                            report,
                                            serviceID: serviceID
                                        )
                                    } catch {
                                        Self.logger.error(
                                            "Persistent service client router violated protocol — attestation validation failed on use report. Subsystem: PersistentServiceClientRouter. Error: \(String(unredacted: error), privacy: .public)"
                                        )
                                    }
                                }
                            }
                        }

                        group.addTaskWithLogging(
                            operation: "managedCloudApp.run()",
                            metrics: .init(
                                metricsSystem: self.metrics,
                                errorFactory: Metrics.Workload.OverallErrorCounter.Factory()
                            ),
                            logger: Self.tracingLogger,
                            level: .info
                        ) {
                            func teardownSupportApps() async {
                                await CloudboardJobHelperCheckpoint(
                                    logMetadata: self.logMetadata(
                                        withRemotePID: cloudApp.remotePID,
                                        spanID: jobHelperSpanID
                                    ),
                                    message: "Cloud app has terminated, tearing down support apps...",
                                    operationName: "teardownSupportApps"
                                ).log(to: Self.logger, level: .info)
                                await withTaskGroup { group in
                                    for supportApp in supportApps {
                                        group.addTask {
                                            do {
                                                try await supportApp.teardown()
                                            } catch {
                                                await CloudboardJobHelperCheckpoint(
                                                    logMetadata: self.logMetadata(
                                                        withRemotePID: supportApp.remotePID,
                                                        spanID: jobHelperSpanID
                                                    ),
                                                    message: "Failed to teardown support app",
                                                    error: error
                                                ).log(to: Self.logger, level: .error)
                                            }
                                        }
                                    }
                                    await group.waitForAll()
                                }
                            }

                            do {
                                try await self.managedCloudApp.run()
                                // Once the cloud app has terminated, send a teardown signal to the support apps
                                await teardownSupportApps()
                            } catch {
                                // Once the cloud app has terminated, send a teardown signal to the support apps
                                await teardownSupportApps()
                                throw error
                            }
                        }

                        for supportApp in supportApps {
                            group.addTaskWithLogging(
                                operation: "managedSupportApp.run()",
                                metrics: .init(
                                    metricsSystem: self.metrics,
                                    errorFactory: Metrics.Workload.OverallErrorCounter.Factory()
                                ),
                                logger: Self.logger,
                                level: .info
                            ) {
                                try await supportApp.run()
                            }
                        }

                        group.addTaskWithLogging(
                            operation: "cloudAppRequestStream consumer",
                            metrics: .init(
                                metricsSystem: self.metrics,
                                errorFactory: Metrics.CloudAppRequestStream.OverallErrorCounter.Factory()
                            ),
                            logger: Self.tracingLogger,
                            level: .info
                        ) {
                            for try await request in cloudAppRequestStream {
                                switch request {
                                case .warmup(let info):
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Forwarding warmup message to workload",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    try await cloudApp.warmup(info: info)
                                case .nackAndExit:
                                    // Do nothing. Nacks are handled in WorkloadJobManager and aren't passed on
                                    // to the application.
                                    ()
                                case .parameters(var parametersData, patIssuer: _):
                                    // patIssuer is only used by WorkloadJobManager to generate the cost token, not by
                                    // CloudApp
                                    await self.setRequestID(parametersData.plaintextMetadata.requestID)
                                    parametersData.traceContext.spanID = jobHelperSpanID
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Forwarding parameters message to workload",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    let parametersData = parametersData
                                    try await withThrowingTaskGroup { group in
                                        for managedApp in [cloudApp] + supportApps {
                                            group.addTask {
                                                try await managedApp.parameters(parametersData)
                                            }
                                        }
                                        try await group.waitForAll()
                                    }
                                case .chunk(let chunk):
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Forwarding chunk to workload",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    try await cloudApp.provideInput(chunk.chunk)
                                    if chunk.isFinal {
                                        try await self.handleEndOfInput(cloudApp: cloudApp, supportApps: supportApps)
                                    }
                                case .openClientSubrequest(
                                    let clientSubrequestId,
                                    let cryptoMaterialHandles,
                                    let isDiscardable
                                ):
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Starting new sub request",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    try await cloudApp.openClientSubrequest(
                                        subrequestId: clientSubrequestId,
                                        cryptoMaterialHandles: cryptoMaterialHandles,
                                        isDiscardable: isDiscardable
                                    )
                                case .subrequestPayload(let clientSubrequestId, let chunk):
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Forwaring chunk to workload",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    try await cloudApp.subrequestPayloadChunk(
                                        subrequestId: clientSubrequestId,
                                        chunk: chunk
                                    )
                                case .closeSubrequest(let clientSubrequestId):
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Closing sub request",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    try await cloudApp.closeClientSubrequest(subrequestId: clientSubrequestId)
                                case .cancelSubrequest(let clientSubrequestId):
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Cancelling sub request",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    try await cloudApp.cancelClientSubrequest(subrequestId: clientSubrequestId)
                                case .endOfInput:
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Forwarding end of input signal to workload",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    try await self.handleEndOfInput(cloudApp: cloudApp, supportApps: supportApps)
                                case .abandon:
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Abandon requested, tearing down workload",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    try await withThrowingTaskGroup { group in
                                        for managedApp in [cloudApp] + supportApps {
                                            group.addTask {
                                                try await managedApp.abandon()
                                            }
                                        }
                                        try await group.waitForAll()
                                    }
                                case .teardown:
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Forwarding teardown message to workload",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .info)
                                    try await withThrowingTaskGroup { group in
                                        for managedApp in [cloudApp] + supportApps {
                                            group.addTask {
                                                try await managedApp.teardown()
                                            }
                                        }
                                        try await group.waitForAll()
                                    }
                                case .oneTimeToken:
                                    // We don't forward one-time tokens to the cloud app and receiving any in the
                                    // cloudAppRequestStream is unexpected
                                    await CloudboardJobHelperCheckpoint(
                                        logMetadata: self.logMetadata(
                                            withRemotePID: cloudApp.remotePID,
                                            spanID: jobHelperSpanID
                                        ),
                                        message: "Unexpectedly received one-time token to be forwarded to the cloud app. Ignoring.",
                                        operationName: "cloudAppRequestStream"
                                    ).log(to: Self.tracingLogger, level: .fault)
                                case .parametersMetaData:
                                    // Do nothing. attestations are handled in WorkloadJobManager and aren't passed on
                                    // to the application.
                                    ()
                                case .workerFound(let workerID, let info, let spanID):
                                    try await cloudApp.workerFound(
                                        workerID: workerID,
                                        info: info,
                                        spanID: spanID
                                    )
                                case .workerNegotiatePick:
                                    // Do nothing. negotiation is handled in WorkloadJobManager and isn't passed on
                                    // to the application.
                                    ()
                                case .selectedWorker:
                                    // Do nothing. attestations are handled in WorkloadJobManager and aren't passed on
                                    // to the application.
                                    ()
                                case .workerResponseChunk(let workerID, let chunk):
                                    try await cloudApp.workerResponseMessage(
                                        workerID: workerID,
                                        data: chunk.chunk,
                                        isFinal: chunk.isFinal
                                    )
                                case .workerResponseSummary(let workerID, let status):
                                    try await cloudApp.workerResponseSummary(workerID: workerID, status: status)
                                case .workerFailure(let workerID, let rawROPESCode, let ropesMessage):
                                    try await cloudApp.workerFailure(
                                        workerID: workerID,
                                        rawROPESCode: rawROPESCode,
                                        ropesMessage: ropesMessage
                                    )
                                case .workerResponseClose:
                                    // Do nothing. workerResponseClose messages are handled in WorkloadJobManager and
                                    // aren't passed on to the application.
                                    ()
                                case .workerResponseEOF(let workerID):
                                    try await cloudApp.workerResponseMessage(
                                        workerID: workerID,
                                        data: nil,
                                        isFinal: true
                                    )
                                case .applicationDataChunkingConfig(let config):
                                    try await cloudApp.configureApplicationDataChunking(config: config)
                                case .clientDiagnosticsSharingOptIn(let optedIn):
                                    // Already resolved by WorkloadJobManager (security policy / override applied
                                    // there, once, so proxied workers match this decision).
                                    try await cloudApp.clientDiagnosticsSharingOptIn(optedIn)
                                case .readyToSendAssetsMetadataRELEntry:
                                    // Do nothing. assetsMetadataRELEntry messages are handled in WorkloadJobManager and
                                    // aren't passed on to the application.
                                    ()
                                case .componentTimeMeasurement:
                                    // Do nothing. componentTimeMeasurement messages are handled in WorkloadJobManager
                                    // and aren't passed on to the application.
                                    ()
                                }
                            }
                            await CloudboardJobHelperCheckpoint(
                                logMetadata: self.logMetadata(
                                    withRemotePID: cloudApp.remotePID,
                                    spanID: jobHelperSpanID
                                ),
                                message: "Request stream finished",
                                operationName: "cloudAppRequestStream"
                            ).log(to: Self.tracingLogger, level: .default)
                            if await cloudApp.abandoned == false {
                                try await self.handleEndOfInput(cloudApp: cloudApp, supportApps: supportApps)
                            }
                        }

                        // The persistent-service attestation drain task (added above)
                        // has no natural termination — it only exits when the router's
                        // stream is finished. Express the shutdown sequence directly:
                        //   1. wait for the first non-drain task to return (its
                        //      completion signals the request is unwinding);
                        //   2. finish the router stream so the drain task exits;
                        //   3. wait for the rest (including the now-exiting drain).
                        // The defer at the top of this do-block covers the throw
                        // path; `shutdownAttestationUsageReports()` is idempotent
                        // so both drivers firing is safe.
                        _ = try await group.next()
                        persistentServiceRouter?.shutdownAttestationUsageReports()
                        try await group.waitForAll()
                        await CloudboardJobHelperCheckpoint(
                            logMetadata: self.logMetadata(
                                withRemotePID: self.cloudAppRemotePID,
                                spanID: jobHelperSpanID
                            ),
                            message: "Completed cloud app request and response handling",
                            operationName: "cloudAppRequestStream"
                        ).log(to: Self.tracingLogger, level: .default)
                    } catch {
                        let logLevel: OSLogType = isBenignTeardownError(error) ? .info : .error
                        await CloudboardJobHelperCheckpoint(
                            logMetadata: self.logMetadata(
                                withRemotePID: self.cloudAppRemotePID,
                                spanID: jobHelperSpanID
                            ),
                            message: "Error while managing cloud app. Attempting to tear down workload.",
                            error: error
                        ).log(to: Self.tracingLogger, level: logLevel)
                        // Attempt to cleanly tear down workload
                        // Teardown is idempotent, so it's fine to be called multiple times
                        await withTaskGroup { group in
                            for managedApp in [cloudApp] + supportApps {
                                group.addTask {
                                    do {
                                        try await managedApp.teardown()
                                    } catch {
                                        let logLevel: OSLogType = isBenignTeardownError(error) ? .info : .error
                                        await CloudboardJobHelperCheckpoint(
                                            logMetadata: self.logMetadata(
                                                withRemotePID: managedApp.remotePID,
                                                spanID: jobHelperSpanID
                                            ),
                                            message: "Failed to teardown managed app",
                                            error: error
                                        ).log(to: Self.logger, level: logLevel)
                                    }
                                }
                            }
                            await group.waitForAll()
                        }
                        // Rethrow error
                        throw error
                    }
                }
            }
        } catch {
            let isBenign = isBenignTeardownError(error)
            if !isBenign {
                self.metrics.emit(Metrics.Daemon.ErrorExitCounter(
                    action: .increment,
                    dimensions: [.errorDescription: String(reportable: error)]
                ))
            }
            exitError = error
            if !isBenign {
                throw error
            }
        }

        withExtendedLifetime(attestationClientRouter) {}
        withExtendedLifetime(jobAuthClientDelegate) {}
    }

    func handleEndOfInput(cloudApp: ManagedCloudAppProtocol, supportApps: [ManagedSupportAppProtocol]) async throws {
        try await cloudApp.endOfInput(error: nil)
        for supportApp in supportApps {
            try await supportApp.endOfInput()
        }
    }

    func withMetricsUpdates(spanID: UInt64, body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let startInstant = ContinuousClock.now

            group.addTask {
                try await body()
            }

            group.addTaskWithLogging(operation: "Update metrics task", logger: Self.logger) {
                do {
                    while !Task.isCancelled {
                        await self.updateMetrics(startInstant: startInstant)
                        // only throws if the task is cancelled
                        try await Task.sleep(for: .seconds(5))
                    }
                } catch {
                    await CloudboardJobHelperCheckpoint(
                        logMetadata: self.logMetadata(spanID: spanID),
                        message: "Update metric task cancelled",
                        error: error
                    ).log(to: Self.tracingLogger, level: .default)
                }
            }

            try await group.next()
            group.cancelAll()
        }
    }

    /// The attestation client ownership is complex
    /// It (may) be created externally (so that mocking is possible)
    /// It is owned by ``CloudBoardJobHelper`` but only in so far as it deals with the registration and
    /// lifecycle. The job helper delegates (almost) all that to this actor.
    /// The job helper is involved only for logging
    ///
    /// It is used by:
    /// ``WorkloadJobManager`` as a ``CloudBoardAttestationWorkerValidationProtocol``
    /// - client call/response
    /// - no delegate registration
    /// - no disconnect awareness
    ///
    /// ``CloudBoardMessenger`` as a ``CloudBoardAttestationAttestationLookupProtocol``
    /// - client call/response
    /// - requires notification of key rotations
    /// - requires notifications of disconnects
    ///
    /// This actor ensures that registration happens once, then connection
    /// and routes the relevant notifications to the right components
    /// The owner of the router is responsible for keeping it alive as long as is required,
    /// the attestationClient should only hold weak references to the delegate
    internal actor AttestationClientRouter: CloudBoardAttestationAPIClientDelegateProtocol {
        let attestationClient: any CloudBoardAttestationAPIClientProtocol
        let messenger: CloudBoardMessenger
        let onSurpriseDisconnect: @Sendable () async -> Void

        internal init(
            attestationClient: any CloudBoardAttestationAPIClientProtocol,
            messenger: CloudBoardMessenger,
            onSurpriseDisconnect: @escaping @Sendable () async -> Void,
        ) async {
            self.attestationClient = attestationClient
            self.messenger = messenger
            self.onSurpriseDisconnect = onSurpriseDisconnect
            await self.attestationClient.set(delegate: self)
            await self.attestationClient.connect()
        }

        func keyRotated(newKeySet: CloudBoardAttestationDAPI.AttestedKeySet) async throws {
            try await self.messenger.notifyKeyRotated(newKeySet: newKeySet)
        }

        func attestationRotated(newAttestationSet _: CloudBoardAttestationDAPI.AttestationSet) async throws {
            // Job helper cares only about the keys. It doesn't subscribe to attestation rotation notification.
            CloudBoardJobHelper.logger.error(
                "Unexpected to receive attestation rotation notification from attestation daemon"
            )
        }

        public func surpriseDisconnect() async {
            // let logging happen
            await self.onSurpriseDisconnect()
            // then reconnect
            await self.attestationClient.connect()
            // then tell the messenger about it
            await self.messenger.notifyAttestationClientReconnect()
        }
    }
}

// NOTE: The description of this type is publicly logged and/or included in metric dimensions and therefore MUST not
// contain sensitive data.
public struct CloudBoardJobHelperLogMetadata: CustomStringConvertible, Sendable {
    var jobID: UUID?
    var requestTrackingID: String?
    var remotePID: Int?
    var spanID: UInt64?

    public init(jobID: UUID? = nil, requestTrackingID: String? = nil, remotePID: Int? = nil, spanID: UInt64? = nil) {
        self.jobID = jobID
        self.requestTrackingID = requestTrackingID
        self.remotePID = remotePID
        self.spanID = spanID
    }

    // NOTE: This description is publicly logged and/or included in metric dimensions and therefore MUST not contain
    // sensitive data.
    public var description: String {
        var fields: [String] = []

        if let jobID = self.jobID {
            fields.append("jobId=\(jobID)")
        }
        if let requestTrackingID = self.requestTrackingID, requestTrackingID != "" {
            fields.append("request.uuid=\(requestTrackingID)")
        }
        if let remotePID = self.remotePID {
            fields.append("remotePid=\(remotePID)")
        }

        if !fields.isEmpty {
            return "[\(fields.joined(separator: " "))]"
        }
        return ""
    }
}

extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

extension SecKey {
    static func fromDEREncodedRSAPublicKey(_ derEncodedRSAPublicKey: Data) throws -> SecKey {
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(derEncodedRSAPublicKey as CFData, keyAttributes as CFDictionary, &error)

        guard let key else {
            // If this returns nil, error must be set.
            throw error!.takeRetainedValue() as Error
        }

        return key
    }
}

extension CloudBoardJobHelper {
    private func logMetadata(
        withRemotePID remotePID: Int? = nil,
        spanID: UInt64? = nil
    ) -> CloudBoardJobHelperLogMetadata {
        return CloudBoardJobHelperLogMetadata(
            jobID: self.jobUUID,
            requestTrackingID: self.requestID,
            remotePID: remotePID,
            spanID: spanID
        )
    }
}

// Delegate used to listen for cost token key updates from cb_jobauthd
private actor JobAuthClientDelegate: CloudBoardJobAuthAPIClientDelegateProtocol {
    private let costTokenSigner: CostTokenSigner?

    init(costTokenSigner: CostTokenSigner?) {
        self.costTokenSigner = costTokenSigner
    }

    func surpriseDisconnect() async {
        CloudBoardJobHelper.logger.error("Surprise disconnect from cb_jobauthd")
    }

    func costTokenKeyUpdated(newKey: CostTokenSigningKeyPair) async throws {
        CloudBoardJobHelper.logger.notice("""
        message=\("Received new cost token key from cb_jobauthd", privacy: .public)
        keyId=\(newKey.keyId.base64EncodedString(), privacy: .public)
        validStart=\(newKey.validStart, privacy: .public)
        validEnd=\(newKey.validEnd, privacy: .public)
        """)
        guard let costTokenSigner = self.costTokenSigner else {
            CloudBoardJobHelper.logger.warning("Received cost token key update but no cost token signer is configured")
            return
        }
        try costTokenSigner.setSigningKey(newKey)
    }
}

protocol CloudBoardJobHelperHotPropertiesProvider: Sendable {
    func getPreferences() async throws -> CloudBoardJobHelperHotProperties
}

struct PreferencesUpdatesProvider: CloudBoardJobHelperHotPropertiesProvider {
    #if canImport(CloudConfigurationPreferences)
    let preferencesUpdates: PreferencesUpdates<CloudBoardJobHelperHotProperties>

    init() {
        self.preferencesUpdates = PreferencesUpdates<CloudBoardJobHelperHotProperties>(
            preferencesDomain: "com.apple.cloudos.hotproperties.cb_jobhelper",
            maximumUpdateDuration: .seconds(1)
        )
    }
    #endif

    func getPreferences() async throws -> CloudBoardJobHelperHotProperties {
        #if canImport(CloudConfigurationPreferences)
        // force unwrap is safe as we will either get the preferences or throw an error
        return try await self.preferencesUpdates.first(where: { _ in true })!.applyingPreferences { $0 }
        #else
        CloudBoardJobHelperHotProperties()
        #endif
    }
}
