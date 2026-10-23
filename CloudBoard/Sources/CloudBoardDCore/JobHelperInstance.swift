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
import CloudBoardDomain
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import os
import Tracing
import XPC

enum JobHelperInstanceError: ReportableError {
    case managedJobNotFound
    case tooManyManagedJobs
    case tornDownBeforeRunning
    case unexpectedTerminationError(Error)
    case illegalStateAfterClientIsRunning(String)
    case illegalStateAfterClientIsConnected(String)
    case illegalStateAfterClientTerminationFailed(String)
    case jobHelperUnavailable(String)
    case monitoringCompletedEarly(Error?)
    case monitoringCompletedFromConnected(Error?)
    case monitoringCompletedMoreThanOnce
    case jobNeverRan
    case setDelegateCalledOnTerminatingInstance
    case assignedLAContextWhenNotConnected
    case assignedLAContextTwice
    case reclaimedLAContextWhenNotAssigned
    case reclaimedLAContextWhenNotConnected
    case reclaimedLAContextAfterInstanceUsed
    case usedLAContextWhenNotInUse
    case usedLAContextWhenAlreadyUsed
    case usedLAContextWhenNotAssigned
    case invokeWorkloadBeforeClientConnected
    case invokeWorkloadWhenNoLAContextAssigned

    var publicDescription: String {
        return switch self {
        case .managedJobNotFound: "managedJobNotFound"
        case .tooManyManagedJobs: "tooManyManagedJobs"
        case .tornDownBeforeRunning: "tornDownBeforeRunning"
        case .unexpectedTerminationError(let error): "unexpectedTerminationError(\(String(reportable: error)))"
        case .illegalStateAfterClientIsRunning(let state): "illegalStateAfterClientIsRunning(\(state))"
        case .illegalStateAfterClientIsConnected(let state): "illegalStateAfterClientIsConnected(\(state))"
        case .illegalStateAfterClientTerminationFailed(let state): "illegalStateAfterClientTerminationFailed(\(state))"
        case .jobHelperUnavailable(let state): "jobHelperUnavailable(\(state))"
        case .monitoringCompletedEarly(let error):
            "monitoringCompletedEarly\(error.map { "(\(String(reportable: $0)))" } ?? "")"
        case .monitoringCompletedFromConnected(let error):
            "monitoringCompletedFromConnected\(error.map { "(\(String(reportable: $0)))" } ?? "")"
        case .monitoringCompletedMoreThanOnce: "monitoringCompletedMoreThanOnce"
        case .jobNeverRan: "jobNeverRan"
        case .setDelegateCalledOnTerminatingInstance: "setDelegateCalledOnTerminatingInstance"
        case .assignedLAContextWhenNotConnected: "assignedLAContextWhenNotConnected"
        case .assignedLAContextTwice: "assignedLAContextTwice"
        case .reclaimedLAContextWhenNotAssigned: "reclaimedLAContextWhenNotAssigned"
        case .reclaimedLAContextWhenNotConnected: "reclaimedLAContextWhenNotConnected"
        case .reclaimedLAContextAfterInstanceUsed: "reclaimedLAContextAfterInstanceUsed"
        case .usedLAContextWhenNotInUse: "usedLAContextWhenNotInUse"
        case .usedLAContextWhenAlreadyUsed: "usedLAContextWhenAlreadyUsed"
        case .usedLAContextWhenNotAssigned: "usedLAContextWhenNotAssigned"
        case .invokeWorkloadBeforeClientConnected: "invokeWorkloadBeforeClientConnected"
        case .invokeWorkloadWhenNoLAContextAssigned: "invokeWorkloadWhenNoLAContextAssigned"
        }
    }
}

/// Mangages CloudBoardJobHelper instance and provides an API to it.
public actor JobHelperInstance: CloudBoardJobHelperInstanceProtocol, Equatable {
    public static func == (lhs: JobHelperInstance, rhs: JobHelperInstance) -> Bool {
        return lhs.job.uuid == rhs.job.uuid
    }

    fileprivate static let log: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard", category: "JobHelperInstance"
    )
    private var stateMachine: JobHelperInstanceStateMachine

    public var canBeReturnedToPool: Bool {
        get async {
            await !self.stateMachine.usedForClientRequest
        }
    }

    public var laContextAssigned: Bool {
        get async {
            await self.stateMachine.laContextAssigned
        }
    }

    private nonisolated let job: any LaunchdJobInstanceInitiatorProtocol
    public nonisolated let cloudAppName: String
    public nonisolated let supportAppNames: [String]
    private nonisolated let jobHelperXPCClientFactory: any CloudBoardJobHelperAPIClientFactoryProtocol

    public nonisolated var id: UUID {
        return self.job.uuid
    }

    private let metrics: MetricsSystem
    private let tracer: any Tracer

    private var warmupCompletePromise: Promise<Void, Error>
    /// A trigger to tear the instance down.
    ///
    /// Subscribed to by `JobHelperInstanceProvider` to tear the `JobHelperInstance` instance down
    private let teardownTrigger: Promise<Void, Error> = Promise()
    private var teardownTriggered: Bool = false

    init(
        _ jobHelperLaunchdJob: any LaunchdJobDefinitionProtocol,
        cloudAppName: String,
        supportAppNames: [String],
        isTrampolineProxy: Bool,
        withLAContext: Bool,
        assetsMetadata: [AssetConsumer: [AssetMetadata]],
        maxApplicationLayerMessageSize: Int,
        maxToolInvocationsPerRequest: Int,
        jobHelperXPCClientFactory: any CloudBoardJobHelperAPIClientFactoryProtocol,
        delegate: CloudBoardJobHelperAPIClientDelegateProtocol,
        metrics: MetricsSystem,
        tracer: any Tracer,
        teardownTimeout: Duration
    ) {
        self.job = jobHelperLaunchdJob.createInstance(uuid: UUID())
        self.cloudAppName = cloudAppName
        self.supportAppNames = supportAppNames
        self.jobHelperXPCClientFactory = jobHelperXPCClientFactory
        self.tracer = tracer
        self.stateMachine = JobHelperInstanceStateMachine(
            cloudAppName: self.cloudAppName,
            supportAppNames: self.supportAppNames,
            isTrampolineProxy: isTrampolineProxy,
            withLAContext: withLAContext,
            assetsMetadata: assetsMetadata,
            maxApplicationLayerMessageSize: maxApplicationLayerMessageSize,
            maxToolInvocationsPerRequest: maxToolInvocationsPerRequest,
            jobHelperJobInstance: self.job,
            jobHelperXPCClientFactory: self.jobHelperXPCClientFactory,
            delegate: delegate,
            metrics: metrics,
            tracer: self.tracer,
            teardownTimeout: teardownTimeout
        )
        self.metrics = metrics
        self.warmupCompletePromise = Promise()
    }

    public func run() async throws {
        do {
            Self.log.info("Running job \(self.job.uuid, privacy: .public)")
            for try await state in self.job.startAndWatch() {
                Self.log.info("""
                Job \(self.job.uuid, privacy: .public) state changed to \
                '\(state, privacy: .public)'
                """)
                switch state {
                case .initialized, .created, .starting:
                    // Nothing to do
                    break
                case .running(let pid):
                    do {
                        try await self.stateMachine.clientIsRunning(pid: pid)
                        self.markWarmupComplete()
                    } catch {
                        /// We swallow the error here, since we want to let the
                        /// threads waiting on the promise to perform the clean ups
                        /// and trigger the teardown on the instance.
                        /// We should not enter the monitor complete state here, otherwise
                        /// the we would fail sending the teardown to the cloud app.
                        self.markWarmupComplete(error: error)
                    }
                case .terminated(let terminationCondition):
                    terminationCondition.emitMetrics(
                        metricsSystem: self.metrics,
                        counterFactory: Metrics.CloudBoardDaemon
                            .CBJobHelperExitCounter.Factory()
                    )
                    await self.stateMachine.clientTerminated()
                case .neverRan:
                    await self.stateMachine.clientTerminated()
                @unknown default:
                    // Nothing to do
                    break
                }
            }
        }
        try await self.stateMachine.monitoringCompleted()
    }

    private func markWarmupComplete(error: Error? = nil) {
        if let error {
            self.warmupCompletePromise.fail(with: error)
        } else {
            self.warmupCompletePromise.succeed()
        }
    }

    package func set(
        delegate: CloudBoardJobHelperAPIClientDelegateProtocol
    ) async throws {
        try await self.stateMachine.set(delegate: delegate)
    }

    public func waitForExit(returnIfNotUsed: Bool) async throws {
        if await self.stateMachine.usedForClientRequest || !returnIfNotUsed {
            try await self.stateMachine.waitForTermination()
        }
    }

    public func waitForWarmupComplete() async throws {
        do {
            try await Future(
                self.warmupCompletePromise
            ).valueWithCancellation
        } catch let error as CancellationError {
            // current task got cancelled
            Self.log.error(
                "waitForWarmupComplete() warmupCompletePromise task cancelled"
            )
            throw error
        } catch {
            Self.log.error("""
            waitForWarmupComplete() warmupCompletePromise returned error: \
            \(String(unredacted: error), privacy: .public)
            """)
            throw error
        }
    }

    package func invokeWorkloadRequest(_ request: CloudBoardDaemonToJobHelperMessage) async throws {
        try await self.stateMachine.invokeWorkloadRequest(request)
    }

    public func triggerTeardown(error: Error? = nil) {
        guard !self.teardownTriggered else {
            Self.log.log("Teardown already triggered. Ignoring new trigger.")
            return
        }
        self.teardownTriggered = true
        if let error {
            self.teardownTrigger.fail(with: error)
        } else {
            self.teardownTrigger.succeed()
        }
    }

    public func assignLAContext() async throws {
        try await self.stateMachine.assignLAContext()
    }

    public func laContextUsed() async throws {
        try await self.stateMachine.laContextUsed()
    }

    /// Waits for the teardown trigger to fire, then performs teardown and waits for it to complete.
    ///
    /// This is the preferred way to manage instance lifecycle because it ensures the caller
    /// does not return until the helper process has been fully torn down (XPC teardown command
    /// sent and launchd job removed). Returning early — e.g. on cancellation — would leak the
    /// helper instance and its associated system resources.
    public func awaitTeardownTriggerAndComplete() async {
        // This promise should always be fulfilled, even if things are cancelled. If
        // we don't wait for this and instead return on cancellation, we leak a JobHelperInstance.
        do {
            try await Future(self.teardownTrigger).value
        } catch {
            Self.log.error("""
            \(self.logMetadata(), privacy: .public) \
            manageJobHelperInstance received error from associated \
            future: \(String(unredacted: error), privacy: .public)
            """)
        }

        do {
            try await self.stateMachine.teardown()
        } catch {
            Self.log.error("""
            \(self.logMetadata(), privacy: .public) \
            manageJobHelperInstance encountered error invoking \
            teardown: \
            \(String(unredacted: error), privacy: .public)
            """)
        }
    }
}

extension JobHelperInstance {
    nonisolated func logMetadata() -> CloudBoardDaemonLogMetadata {
        return CloudBoardDaemonLogMetadata(jobID: self.id, cloudApp: self.cloudAppName)
    }

    public func abandon() async throws {
        try await self.stateMachine.abandon()
    }

    package func queryProxyRequestStatus() async throws -> ProxyRequestStatus {
        try await self.stateMachine.queryProxyRequestStatus()
    }
}

internal actor JobHelperInstanceStateMachine {
    enum State: CustomStringConvertible {
        case awaitingJobHelperConnection
        case connecting(
            CloudBoardJobHelperAPIClientDelegateProtocol
        )
        case connected(any CloudBoardJobHelperAPIClientProtocol, usedForClientRequest: Bool)
        case abandoning(any CloudBoardJobHelperAPIClientProtocol)
        case terminating
        case terminated
        case monitoringCompleted

        var description: String {
            switch self {
            case .awaitingJobHelperConnection: "awaitingJobHelperConnection"
            case .connecting: "connecting"
            case .connected: "connected"
            case .terminating: "terminating"
            case .abandoning: "abandoning"
            case .terminated: "terminated"
            case .monitoringCompleted: "monitoringCompleted"
            }
        }
    }

    private let cloudAppName: String
    private let supportAppNames: [String]
    private let isTrampolineProxy: Bool
    private let assetsMetadata: [AssetConsumer: [AssetMetadata]]
    private let jobHelperJobInstance: any LaunchdJobInstanceInitiatorProtocol
    private let jobHelperXPCClientFactory: any CloudBoardJobHelperAPIClientFactoryProtocol
    internal var remotePID: Int?
    private var delegate: CloudBoardJobHelperAPIClientDelegateProtocol
    private var state: State {
        didSet(oldState) {
            JobHelperInstance.log.trace("""
            JobHelperInstanceStateMachine state changed: \
            \(oldState, privacy: .public) -> \(self.state, privacy: .public)
            """)
        }
    }

    var laContextAssigned: Bool
    private let maxApplicationLayerMessageSize: Int
    private let maxToolInvocationsPerRequest: Int

    var usedForClientRequest: Bool {
        switch self.state {
        case .awaitingJobHelperConnection, .connecting:
            return false
        case .connected(_, let usedForClientRequest):
            return usedForClientRequest
        case .abandoning, .terminating, .terminated, .monitoringCompleted:
            return true
        }
    }

    private let metrics: MetricsSystem
    private let tracer: any Tracer

    private let terminationPromise = Promise<Void, Error>()
    private var terminationRequested: Bool = false
    private let teardownTimeout: Duration

    init(
        cloudAppName: String,
        supportAppNames: [String],
        isTrampolineProxy: Bool,
        withLAContext: Bool,
        assetsMetadata: [AssetConsumer: [AssetMetadata]],
        maxApplicationLayerMessageSize: Int,
        maxToolInvocationsPerRequest: Int,
        jobHelperJobInstance: any LaunchdJobInstanceInitiatorProtocol,
        jobHelperXPCClientFactory: any CloudBoardJobHelperAPIClientFactoryProtocol,
        delegate: CloudBoardJobHelperAPIClientDelegateProtocol,
        metrics: any MetricsSystem,
        tracer: any Tracer,
        teardownTimeout: Duration
    ) {
        self.cloudAppName = cloudAppName
        self.supportAppNames = supportAppNames
        self.isTrampolineProxy = isTrampolineProxy
        self.assetsMetadata = assetsMetadata
        self.maxApplicationLayerMessageSize = maxApplicationLayerMessageSize
        self.maxToolInvocationsPerRequest = maxToolInvocationsPerRequest
        self.state = .awaitingJobHelperConnection
        self.laContextAssigned = withLAContext
        self.jobHelperJobInstance = jobHelperJobInstance
        self.jobHelperXPCClientFactory = jobHelperXPCClientFactory
        self.delegate = delegate
        self.tracer = tracer
        self.metrics = metrics
        self.teardownTimeout = teardownTimeout
    }

    func set(
        delegate: CloudBoardJobHelperAPIClientDelegateProtocol
    ) async throws {
        self.delegate = delegate
        switch self.state {
        case .awaitingJobHelperConnection, .connecting:
            ()
        case .connected(let client, _):
            await client.set(delegate: self.delegate)
        case .terminating, .abandoning, .terminated, .monitoringCompleted:
            JobHelperInstance.log.error("""
            \(self.logMetadata(), privacy: .public) \
            Received request to update delegate on terminating JobHelperInstance
            """)
            throw JobHelperInstanceError.setDelegateCalledOnTerminatingInstance
        }
    }

    deinit {
        switch state {
        case .awaitingJobHelperConnection, .connecting:
            terminationPromise.fail(
                with: JobHelperInstanceError.tornDownBeforeRunning
            )
        case .connected:
            // This cannot happen if `monitoringCompleted` is called as promised
            fatalError("JobHelperInstanceStateMachine dropped without cleaning up")
        case .terminated, .monitoringCompleted:
            () // terminationPromise should be completed
        case .terminating, .abandoning:
            // if we're hitting this case, neither `monitoringCompleted` has
            // been called (`JobHelperInstance.run()` invariant violated), nor
            // proper termination sequence has been allowed to complete.
            // In that case, terminationPromise will either leak, but if we
            // complete it here, it will race with ongoing termination.
            fatalError(
                "Must wait for JobHelperInstanceStateMachine to finish terminating"
            )
        }
    }

    func invokeWorkloadRequest(_ request: CloudBoardDaemonToJobHelperMessage) async throws {
        try await self.tracer.withSpan(
            OperationNames.clientInvokeWorkloadRequest
        ) { span in
            span.attributes.requestSummary.clientRequestAttributes.jobHelperPID
                = self.remotePID
            span.attributes.requestSummary.clientRequestAttributes.jobID
                = self.jobHelperJobInstance.uuid.uuidString

            switch self.state {
            case .awaitingJobHelperConnection, .connecting:
                JobHelperInstance.log.error("""
                \(self.logMetadata(), privacy: .public) \
                Cannot forward workload request chunks to cb_jobhelper \
                currently waiting for it to come up"
                """)
                throw JobHelperInstanceError.invokeWorkloadBeforeClientConnected
            case .connected(let client, let usedForClientRequest):
                if !usedForClientRequest {
                    guard self.laContextAssigned else {
                        throw JobHelperInstanceError.invokeWorkloadWhenNoLAContextAssigned
                    }
                    self.state = .connected(client, usedForClientRequest: true)
                }
                JobHelperInstance.log.debug("""
                \(self.logMetadata(), privacy: .public) \
                Sending workload request to cb_jobhelper
                """)
                try await client.invokeWorkloadRequest(request)
            case .terminating, .abandoning, .terminated, .monitoringCompleted:
                JobHelperInstance.log.error("""
                \(self.logMetadata(), privacy: .public) \
                Cannot forward workload request to cb_jobhelper \
                currently terminating
                """)
                throw JobHelperInstanceError.jobHelperUnavailable(
                    "\(self.state)"
                )
            }
        }
    }

    func queryProxyRequestStatus() async throws -> ProxyRequestStatus {
        switch self.state {
        case .connected(let client, _):
            return try await client.queryProxyRequestStatus()
        case .awaitingJobHelperConnection, .connecting,
             .terminating, .abandoning, .terminated, .monitoringCompleted:
            return ProxyRequestStatus(subrequestsStatus: .unavailable, workersStatus: .unavailable)
        }
    }

    func clientIsRunning(pid: Int?) async throws {
        self.remotePID = pid
        // Notice-/default-level log to ensure that we have the
        // cb_jobhelper associated with the current request is
        // visible in Splunk
        JobHelperInstance.log.notice("""
        \(self.logMetadata(), privacy: .public) \
        cb_jobhelper is running
        """)
        switch self.state {
        case .awaitingJobHelperConnection:
            let setDelegate = self.delegate
            self.state = .connecting(setDelegate)
            // Pass the stashed delegate as it may change across
            // await calls
            let client = await self.connect(delegate: setDelegate)
            try await self.clientIsConnected(client: client)
        case .connecting, .connected,
             .terminating, .abandoning, .terminated,
             .monitoringCompleted:
            JobHelperInstance.log.fault("""
            \(self.logMetadata(), privacy: .public) \
            State machine in unexpected state \
            \(self.state, privacy: .public) after cb_jobhelper state \
            reported to be \"running\"
            """)
            throw JobHelperInstanceError.illegalStateAfterClientIsRunning(
                "\(self.state)"
            )
        }
    }

    func connect(
        delegate: any CloudBoardJobHelperAPIClientDelegateProtocol
    ) async -> any CloudBoardJobHelperAPIClientProtocol {
        JobHelperInstance.log.debug("""
        \(self.logMetadata(), privacy: .public) \
        Connecting to cb_jobhelper
        """)
        let client = await self.jobHelperXPCClientFactory.localConnection(self.jobHelperJobInstance.uuid)
        await client.set(delegate: delegate)
        await client.connect()
        JobHelperInstance.log.debug("""
        \(self.logMetadata(), privacy: .public) \
        Connected to cb_jobhelper
        """)
        return client
    }

    private func clientIsConnected(
        client: any CloudBoardJobHelperAPIClientProtocol
    ) async throws {
        // Our locally stashed delegate could have changed while we were
        // connecting. Make sure the one we have set on the XPC client is up
        // to date before moving forward.
        while case .connecting(let setDelegate)
            = self.state, !(setDelegate === delegate) {
            self.state = .connecting(self.delegate)
            await client.set(delegate: self.delegate)
        }

        switch self.state {
        case .connecting:
            self.state = .connected(client, usedForClientRequest: false)
            if self.terminationRequested {
                // cb_jobhelper was requested to terminate
                await self.teardownConnectedClient(
                    client: client
                )
            } else {
                try await client.warmup(
                    .init(
                        cloudAppName: self.cloudAppName,
                        supportAppNames: self.supportAppNames,
                        assignLAContext: self.laContextAssigned,
                        assetsMetadata: self.assetsMetadata,
                        maxApplicationLayerMessageSize: self.maxApplicationLayerMessageSize,
                        maxToolInvocationsPerRequest: self.maxToolInvocationsPerRequest,
                        isTrampolineProxy: self.isTrampolineProxy
                    )
                )
            }
        case .terminated:
            // We have terminated in the meantime, nothing we can do
            ()
        case .awaitingJobHelperConnection,
             .connected,
             .terminating,
             .abandoning,
             .monitoringCompleted:
            JobHelperInstance.log.fault("""
            \(self.logMetadata(), privacy: .public) \
            State machine in unexpected state \
            \(self.state, privacy: .public) after connecting to cb_jobhelper
            """)
            throw JobHelperInstanceError.illegalStateAfterClientIsConnected(
                "\(self.state)"
            )
        }
    }

    func abandon() async throws {
        JobHelperInstance.log.log("""
        \(self.logMetadata(), privacy: .public) Received request to abandon job
        """)

        if case .connected(let client, _) = state {
            self.state = .abandoning(client)
        }

        try await self._teardown()
    }

    func teardown() async throws {
        JobHelperInstance.log.log("""
        \(self.logMetadata(), privacy: .public) Received request to teardown job
        """)

        try await self._teardown()
    }

    func _teardown() async throws {
        if self.terminationRequested {
            JobHelperInstance.log.info("""
            \(self.logMetadata(), privacy: .public) \
            Job termination already requested, waiting for termination
            """)
            try await self.waitForTermination()
            return
        }

        self.terminationRequested = true

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.teardownTask() }
                group.addTask { try await self.teardownTimeoutTask() }
                JobHelperInstance.log.info("""
                \(self.logMetadata(), privacy: .public) \
                Waiting for job termination to complete
                """)
                try await group.next()
                group.cancelAll()
                JobHelperInstance.log.info("""
                \(self.logMetadata(), privacy: .public) \
                Teardown complete
                """)
            }
            try? await self.removeJobs()
        } catch {
            try? await self.removeJobs()
        }
    }

    private func teardownTask() async throws {
        switch self.state {
        case .awaitingJobHelperConnection, .connecting:
            JobHelperInstance.log.info("""
            \(self.logMetadata(), privacy: .public) \
            Received request to teardown cb_jobhelper while not yet connected, \
            waiting for connection
            """)
            try await self.waitForTermination()
        case .connected(let client, _):
            await self.teardownConnectedClient(client: client)
            try await self.waitForTermination()
        case .abandoning(let client):
            await self.abandonConnectedClient(client: client)
            try await self.waitForTermination()
        case .terminating:
            try await self.waitForTermination()
        case .terminated, .monitoringCompleted:
            JobHelperInstance.log.debug("""
            \(self.logMetadata(), privacy: .public) \
            Ignoring request to teardown cb_jobhelper \
            in state \(self.state, privacy: .public)
            """)
        }
    }

    private func teardownTimeoutTask() async throws {
        JobHelperInstance.log.info("""
        \(self.logMetadata(), privacy: .public) \
        Teardown timeout task started
        """)
        do {
            try await Task.sleep(for: self.teardownTimeout)
        } catch is CancellationError {
            JobHelperInstance.log.info("Teardown timeout cancelled")
            throw CancellationError()
        }
        JobHelperInstance.log.error("""
        \(self.logMetadata(), privacy: .public) \
        Termination of job timed out
        """)
        try await self.removeJobs()
    }

    private func removeJobs() async throws {
        func handleTermination(_ jobHandle: any LaunchdJobInstanceHandleProtocol) throws {
            let metric: any Counter
            let name: String
            switch jobHandle.attributes.cloudBoardJobType {
            case .cloudBoardApp:
                metric = Metrics.JobHelperInstance.CloudAppTerminateFailureCounter(
                    action: .increment,
                    cloudApp: self.cloudAppName
                )
                name = jobHandle.attributes.cloudBoardJobName
            case .cloudBoardSupportApp:
                metric = Metrics.JobHelperInstance.SupportAppTerminateFailureCounter(
                    action: .increment,
                    cloudApp: self.cloudAppName,
                    supportApp: jobHandle.attributes.cloudBoardJobName
                )
                name = jobHandle.attributes.cloudBoardJobName
            case .cbJobHelper:
                metric = Metrics.JobHelperInstance.CBJobHelperTerminateFailureCounter(
                    action: .increment,
                    cloudApp: self.cloudAppName
                )
                name = "cb_jobhelper"
            case .cbPServerHelper:
                metric = Metrics.JobHelperInstance.CBPServerHelperTerminateFailureCounter(
                    action: .increment
                )
                name = "cb_pserverhelper"
            case .cbPClientHelper:
                metric = Metrics.JobHelperInstance.CBPClientHelperTerminateFailureCounter(
                    action: .increment
                )
                name = "cb_pclienthelper"
            }
            JobHelperInstance.log.error("""
            \(self.logMetadata(), privacy: .public) \
            \(name, privacy: .public) still running, removing
            """)
            self.metrics.emit(metric)
            try jobHandle.remove(logger: JobHelperInstance.log)
        }

        if let cloudAppHandle = self.jobHelperJobInstance.findRunningLinkedInstances(
            type: .cloudBoardApp,
            logger: JobHelperInstance.log
        ).first {
            try handleTermination(cloudAppHandle)
        }

        for supportAppHandle in self.jobHelperJobInstance.findRunningLinkedInstances(
            type: .cloudBoardSupportApp,
            logger: JobHelperInstance.log
        ) {
            try handleTermination(supportAppHandle)
        }

        if let jobHelperInstanceHandle = await jobHelperJobInstance.instanceHandleIfCreated {
            try handleTermination(jobHelperInstanceHandle)
        }
    }

    internal func waitForTermination() async throws {
        do {
            try await Future(self.terminationPromise).valueWithCancellation
        } catch let error as CancellationError {
            throw error
        } catch {
            JobHelperInstance.log.fault("""
            \(self.logMetadata(), privacy: .public) \
            Unexpected error while waiting for \
            terminationPromise to be fulfiled: \
            \(String(unredacted: error), privacy: .public)
            """)
            throw JobHelperInstanceError.unexpectedTerminationError(error)
        }
    }

    private func teardownConnectedClient(
        client: CloudBoardJobHelperAPIClientToServerProtocol
    ) async {
        self.state = .terminating
        JobHelperInstance.log.info("Sending teardown request to cb_jobhelper")
        do {
            try await client.teardown()
        } catch {
            JobHelperInstance.log.error("""
            \(self.logMetadata(), privacy: .public) \
            client.teardown() returned error: \
            \(String(unredacted: error), privacy: .public)
            """)
        }
    }

    private func abandonConnectedClient(
        client: CloudBoardJobHelperAPIClientToServerProtocol
    ) async {
        JobHelperInstance.log.info("Sending abandon request to cb_jobhelper")
        do {
            try await client.abandon()
        } catch {
            JobHelperInstance.log.error("""
            \(self.logMetadata(), privacy: .public) \
            client.abandon() returned error: \
            \(String(unredacted: error), privacy: .public)
            """)
        }
    }

    func clientTerminated() async {
        switch self.state {
        case .awaitingJobHelperConnection, .connecting, .connected, .terminating, .abandoning:
            self.terminationPromise.succeed()
        case .terminated:
            JobHelperInstance.log.warning("""
            \(self.logMetadata(), privacy: .public) \
            cb_jobhelper reported to have terminated twice
            """)
        case .monitoringCompleted:
            JobHelperInstance.log.warning("""
            \(self.logMetadata(), privacy: .public) \
            cb_jobhelper reported to have terminated after monitoring stopped
            """)
        }

        self.state = .terminated
    }

    // This routine is guaranteed to be invoked once we make it to the point
    // of calling JobHelperInstance.run(). That ensures that the terminationPromise
    // is completed.
    func monitoringCompleted(error: Error? = nil) async throws {
        defer {
            self.state = .monitoringCompleted
        }

        switch self.state {
        case .awaitingJobHelperConnection, .connecting,
             .terminating, .abandoning:
            if let error {
                JobHelperInstance.log.error("""
                \(self.logMetadata(), privacy: .public) \
                cb_jobhelper monitoring stopped before receiving \
                termination notification with error: \
                \(String(unredacted: error), privacy: .public)
                """)
            } else {
                JobHelperInstance.log.error("""
                \(self.logMetadata(), privacy: .public) \
                cb_jobhelper monitoring stopped before receiving termination \
                notification
                """)
            }
            self.terminationPromise.fail(
                with: JobHelperInstanceError.monitoringCompletedEarly(error)
            )
            throw JobHelperInstanceError.monitoringCompletedEarly(error)
        case .connected(let client, _):
            JobHelperInstance.log.error("""
            \(self.logMetadata(), privacy: .public) \
            cb_jobhelper monitoring stopped before receiving termination \
            notification (while connected). Will try to send a teardown to the
            client anyway oppotunitiscally.
            """)
            await self.teardownConnectedClient(client: client)
            self.terminationPromise.fail(
                with: JobHelperInstanceError.monitoringCompletedFromConnected(
                    error
                )
            )
            throw JobHelperInstanceError.monitoringCompletedFromConnected(error)
        case .terminated:
            // terminationPromise fulfilled in clientTerminated()
            ()
        case .monitoringCompleted:
            JobHelperInstance.log.error("""
            \(self.logMetadata(), privacy: .public) \
            cb_jobhelper monitoring reported to have completed twice
            """)
            throw JobHelperInstanceError.monitoringCompletedMoreThanOnce
        }
    }

    func assignLAContext() async throws {
        switch self.state {
        case .connected(let client, let usedForClientRequest):
            guard !self.laContextAssigned, !usedForClientRequest else {
                JobHelperInstance.log.error("""
                \(self.logMetadata(), privacy: .public) \
                Assigned LAContext twice.
                """)
                throw JobHelperInstanceError.assignedLAContextTwice
            }
            self.state = .connected(client, usedForClientRequest: false)
            try await client.assignLAContext()
            self.laContextAssigned = true
        case .abandoning, .awaitingJobHelperConnection, .connecting, .monitoringCompleted, .terminated, .terminating:
            JobHelperInstance.log.error("""
            \(self.logMetadata(), privacy: .public) \
            Assigned LAContext when not connected to cb_jobhelper.
            """)
            throw JobHelperInstanceError.assignedLAContextWhenNotConnected
        }
    }

    func laContextUsed() async throws {
        switch self.state {
        case .connected(let client, let usedForClientRequest):
            guard self.laContextAssigned else {
                throw JobHelperInstanceError.usedLAContextWhenNotAssigned
            }
            guard usedForClientRequest else {
                throw JobHelperInstanceError.usedLAContextWhenNotInUse
            }
            self.laContextAssigned = false
            self.state = .connected(client, usedForClientRequest: true)
        case .awaitingJobHelperConnection, .connecting, .monitoringCompleted, .terminated:
            throw JobHelperInstanceError.usedLAContextWhenNotInUse
        case .abandoning, .terminating:
            guard self.laContextAssigned else {
                throw JobHelperInstanceError.usedLAContextWhenNotAssigned
            }
            self.laContextAssigned = false
        }
    }
}

extension JobHelperInstanceStateMachine {
    private func logMetadata() -> CloudBoardDaemonLogMetadata {
        return CloudBoardDaemonLogMetadata(
            jobID: self.jobHelperJobInstance.uuid,
            rpcID: ServiceContext.current?.rpcID,
            requestTrackingID: ServiceContext.current?.requestID,
            remotePID: self.remotePID
        )
    }
}
