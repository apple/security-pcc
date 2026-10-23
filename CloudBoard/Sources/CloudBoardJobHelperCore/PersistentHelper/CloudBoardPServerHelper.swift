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
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
@_spi(SEP_Curve25519) import CryptoKit
@_spi(SEP_Curve25519) import CryptoKitPrivate
import Foundation
import LocalAuthentication
internal import ObliviousX
import os
import Synchronization

private enum PServerHelperMetrics {
    struct ProcessInfo: CloudBoardMetrics.Uptime.ProcessInfo {
        static let prefix: String = "cb_pserverhelper"
        static let type = CloudBoardMetrics.Uptime.ProcessType.process
    }
}

/// Per-connection process implementing OHTTP termination for persistent server-side connections.
///
/// Unlike `CloudBoardJobHelper`, this is long-lived (tied to a key lifecycle, not a single request).
/// It receives encrypted queries from cloudboardd (via PersistentServiceManager),
/// decrypts them using OHTTP/HPKE, and forwards the plaintext to a target daemon
/// (e.g., PrivateFilterController) via an XPC endpoint.
public actor CloudBoardPersistentServerHelper {
    static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardPersistentServerHelper"
    )

    let server: PersistentHelperAPIServerProtocol
    let config: SecureConfig
    let attestationClient: CloudBoardAttestationAttestationLookupProtocol
    let laContextProvider: LocalAuthContextProvider
    let plaintextConnectionFactory: @Sendable (String) async -> CloudBoardAsyncXPCConnection

    let lifecycle: PersistentHelperLifecycle
    private var ohttpStateMachine = OHTTPServerStateMachine()
    private var responseEncapsulator: StreamingResponseProtocol?
    private var plaintextConnection: CloudBoardAsyncXPCConnection?
    private var keyID: Data?
    private var initialized = false
    private var filterQueryCount: UInt64 = 0

    // MARK: - Outbound send pump

    /// One OHTTP-encapsulated response chunk to be sent back to cloudboardd.
    /// The pump serializes encapsulate→send so concurrent plaintext responses
    /// from the target daemon cannot reuse an AEAD nonce or reorder on the wire.
    private struct SendJob {
        let data: Data
        let isFinal: Bool
    }

    private let sendQueue: AsyncStream<SendJob>
    private let sendContinuation: AsyncStream<SendJob>.Continuation
    private var sendPumpTask: Task<Void, Never>?

    /// Bounded queue depth for the send pump. Reasoning:
    ///   - The producer is the XPC handler delivering plaintext response
    ///     chunks from the target daemon, which can burst ahead of wire
    ///     sends during backpressure on the cloudboardd peer.
    ///   - Each queued job carries one encrypted response chunk (low
    ///     hundreds of bytes), so a saturated queue costs on the order of
    ///     tens of KB.
    ///   - A bound well above expected peak concurrency avoids false drops
    ///     in bursty traffic while still bounding worst-case memory.
    ///   - On overflow the incoming chunk is dropped and logged. The remote
    ///     client will time the query out and fail it — same observable
    ///     outcome as a slow path with no new escalation. Tearing the helper
    ///     down would turn one lost query into many.
    /// See `enqueueResponseChunk` / `runSendPump` for the producer/consumer.
    private static let sendQueueBufferLimit = 1024

    internal init(
        server: PersistentHelperAPIServerProtocol,
        configuration: SecureConfig,
        attestationClient: CloudBoardAttestationAttestationLookupProtocol,
        laContextProvider: LocalAuthContextProvider,
        plaintextConnectionFactory: @escaping @Sendable (String) async -> CloudBoardAsyncXPCConnection = { endpoint in
            await CloudBoardAsyncXPCConnection.connect(to: endpoint)
        }
    ) {
        self.lifecycle = PersistentHelperLifecycle(logger: Self.logger)
        self.server = server
        self.config = configuration
        self.attestationClient = attestationClient
        self.laContextProvider = laContextProvider
        self.plaintextConnectionFactory = plaintextConnectionFactory
        (self.sendQueue, self.sendContinuation) = AsyncStream<SendJob>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.sendQueueBufferLimit)
        )
    }

    public init(
        configuration: SecureConfig
    ) async {
        self.lifecycle = PersistentHelperLifecycle(logger: Self.logger)
        self.server = PersistentHelperXPCServer.pserverHelperListener()
        self.config = configuration
        let attestationClient = await CloudBoardAttestationAPIXPCClient.localConnection()
        await attestationClient.connect()
        self.attestationClient = attestationClient
        self.laContextProvider = ImmediateLocalAuthContextProvider()
        self.plaintextConnectionFactory = { endpoint in
            await CloudBoardAsyncXPCConnection.connect(to: endpoint)
        }
        (self.sendQueue, self.sendContinuation) = AsyncStream<SendJob>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.sendQueueBufferLimit)
        )
    }

    public func start() async throws {
        try await CloudBoardMetrics.Uptime.withStandardMetrics(
            processInfo: PServerHelperMetrics.ProcessInfo.self,
            metrics: CloudMetricsSystem(clientName: PServerHelperMetrics.ProcessInfo.prefix)
        ) {
            try await self._start()
        }
    }

    /// Sentinel thrown from the teardown-waiter child task to signal the surrounding
    /// `withThrowingTaskGroup` to cancel siblings (i.e. the send pump). Caught and
    /// discarded by `_start()` — it represents normal shutdown, not failure.
    private struct TeardownSignal: Error {}

    private func _start() async throws {
        Self.logger.info("Starting CloudBoardPersistentServerHelper")
        await self.server.set(delegate: self)
        await self.server.connect()
        await self.server.setOnClientDisconnected { [weak self] in
            guard let self else { return }
            Self.logger.error("cloudboardd connection lost — triggering self-teardown")
            await self.handleTeardown()
        }
        Self.logger.info("CloudBoardPersistentServerHelper server connected, waiting for initialization")

        // Structured ownership of the send pump — see CloudBoardPClientHelper._start
        // for the rationale. The pump is launched here and its lifetime is bounded
        // by the surrounding `withThrowingTaskGroup`; teardown cancels the pump and
        // `_start()` does not return until it has exited. Tests that bypass
        // `_start` rely on the lazy-start path in `startSendPumpIfNeeded`.
        self.startSendPumpIfNeeded()
        let pumpTask = self.sendPumpTask
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = await pumpTask?.value
                }
                group.addTask {
                    try await self.lifecycle.awaitTeardown()
                    throw TeardownSignal()
                }
                try await group.next()
                pumpTask?.cancel()
                group.cancelAll()
                try await group.waitForAll()
            }
        } catch is TeardownSignal {
            // Normal shutdown — pump cancelled and awaited above.
        }
    }

    private func handleInitialize(_ params: PersistentHelperInitParams) async throws {
        guard !self.initialized else {
            Self.logger.error("Initialize called twice")
            throw PersistentHelperAPIError.failedInitialization
        }
        // Init is single-shot per actor: production callers (`PersistentServiceProvider`)
        // discard and respawn the helper on any failure rather than retrying. Trigger
        // local teardown on any throw past this point so the actor's lifecycle ends
        // cleanly even before the parent kills the process — closing the window
        // where the actor could be observed in a half-initialized state. The
        // duplicate-completion warning logged by `lifecycle.completeTeardown` when an
        // inline branch already fulfilled the future with `.failure` is benign and
        // rare; the failure result still surfaces to `start()`'s caller.
        do {
            try await self.performInitialization(params)
        } catch {
            await self.handleTeardown()
            throw error
        }
    }

    private func performInitialization(_ params: PersistentHelperInitParams) async throws {
        Self.logger.info("Initializing with keyID: \(params.keyID.base64EncodedString(), privacy: .public)")
        self.keyID = params.keyID

        // Fetch attested keys from cb_attestationd
        Self.logger.info("Requesting attested key set from cb_attestationd")
        let keySet: AttestedKeySet
        do {
            keySet = try await self.attestationClient.requestAttestedKeySet()
        } catch {
            Self.logger.error("Failed to request attested key set: \(String(reportable: error), privacy: .public)")
            await self.reportFailure(.ohttpDecapsulationFailure)
            self.lifecycle.completeTeardown(with: .failure(error))
            throw error
        }
        Self.logger
            .info(
                "Received attested key set (1 current + \(keySet.unpublishedKeys.count, privacy: .public) unpublished key(s))"
            )

        // Cache keys with the LAContext for SEP access
        Self.logger.info("Obtaining LAContext for SEP key access")
        let laContext: LAContext
        do {
            laContext = try self.laContextProvider.getContext()
        } catch {
            Self.logger.error("Failed to get LAContext: \(String(reportable: error), privacy: .public)")
            await self.reportFailure(.ohttpDecapsulationFailure)
            self.lifecycle.completeTeardown(with: .failure(error))
            throw error
        }

        Self.logger.info("Caching attested keys with LAContext")
        let cachedKeys: [CachedAttestedKey]
        do {
            cachedKeys = try [CachedAttestedKey](keySet: keySet, laContext: laContext)
        } catch {
            Self.logger.error("Failed to cache attested keys: \(String(reportable: error), privacy: .public)")
            await self.reportFailure(.ohttpDecapsulationFailure)
            self.lifecycle.completeTeardown(with: .failure(error))
            throw error
        }
        Self.logger.info("Cached \(cachedKeys.count, privacy: .public) attested key(s)")

        // Find the matching key by keyID
        let keyIDEncoded = params.keyID.base64EncodedString()
        guard let matchedKey = cachedKeys.first(where: { $0.keyID == params.keyID }) else {
            Self.logger.error("No attested key found for keyID: \(keyIDEncoded, privacy: .public)")
            await self.reportFailure(.unknownKeyID)
            let error = NodeKeyError.unknownKeyID(keyIDEncoded)
            self.lifecycle.completeTeardown(with: .failure(error))
            throw error
        }

        Self.logger
            .info(
                "Found attested key for keyID: \(keyIDEncoded, privacy: .public), expiry: \(matchedKey.expiry, privacy: .public)"
            )

        // Verify key is not expired
        guard matchedKey.expiry >= .now else {
            Self.logger.error("Key expired for keyID: \(keyIDEncoded, privacy: .public)")
            await self.reportFailure(.expiredKey)
            let error = NodeKeyError.expiredKey(keyIDEncoded)
            self.lifecycle.completeTeardown(with: .failure(error))
            throw error
        }

        // Perform the HPKE handshake
        Self.logger.info("Performing OHTTP/HPKE handshake")
        let completedHandshake: OHTTPServerStateMachine.HandshakeCompleteInfo
        do {
            completedHandshake = try self.ohttpStateMachine.receiveKey(
                params.encryptedKey,
                privateKey: matchedKey.cachedKey,
                responseBypassMode: .none
            )
        } catch {
            Self.logger.error("OHTTP handshake failed: \(String(reportable: error), privacy: .public)")
            await self.reportFailure(.ohttpDecapsulationFailure)
            self.lifecycle.completeTeardown(with: .failure(error))
            throw error
        }

        // Store the response encapsulator for encrypting responses back
        self.responseEncapsulator = completedHandshake.outboundStream

        // Establish connection to plaintext target (after handshake succeeds to avoid
        // leaving a suspended XPC connection on error paths)
        Self.logger.info("Connecting to plaintext target: \(params.targetEndpoint, privacy: .public)")
        // The target is a named mach service, so a controller restart delivers
        // XPC_ERROR_CONNECTION_INTERRUPTED (peer died, will relaunch) — not invalidation. All three
        // lifecycle events (interruption, invalidation, imminent termination) mean the same thing for
        // us: our link to the filter-serving controller is gone. Tear the helper down so cloudboardd
        // sees the client-facing connection drop and a fresh helper is spawned against the restarted
        // controller; leaving the process up would silently drop every decrypted query.
        //
        // This is a *clean* teardown, not a crash: we detected the dropped controller link and exited
        // in a controlled way (finish the send queue, cancel the connection, EOF to cloudboardd), so
        // `handleTeardown` completes the lifecycle successfully and the process exits 0. A non-zero
        // exit would misrepresent this expected, self-healing event as a failure.
        let onControllerLinkLost: @Sendable (CloudBoardAsyncXPCConnection) async -> Void = { [weak self] _ in
            guard let self else { return }
            if self.lifecycle.isTornDown {
                Self.logger.info("Plaintext target connection lost during teardown (expected)")
            } else {
                Self.logger.error("Plaintext target connection to controller lost — tearing down helper")
                await self.reportFailure(.targetConnectionFailed)
            }
            await self.handleTeardown()
        }
        self.plaintextConnection = await self.plaintextConnectionFactory(params.targetEndpoint)
            .handleConnectionInvalidated(handler: onControllerLinkLost)
            .handleConnectionInterrupted(handler: onControllerLinkLost)
            .handleConnectionTerminationImminent(handler: onControllerLinkLost)
        Self.logger.info("Connected to plaintext target: targetEndpoint=\(params.targetEndpoint, privacy: .public)")

        // Activate the plaintext connection with a handler for response chunks from the target
        await self.plaintextConnection?.activate(buildMessageHandlerStore: self.configurePlaintextHandlers)

        // Forward any pending inbound data that was buffered while awaiting the key
        let pendingCount = completedHandshake.pendingInboundData.count
        if pendingCount > 0 {
            Self.logger.info("Forwarding \(pendingCount, privacy: .public) pending inbound chunk(s)")
        }
        for chunk in completedHandshake.pendingInboundData {
            Self.logger.debug(
                "Forwarding pending chunk: \(chunk.chunk.count, privacy: .public) bytes, isFinal: \(chunk.isFinal, privacy: .public)"
            )
            try await self.forwardToPlaintextTarget(chunk.chunk, isFinal: chunk.isFinal)
        }

        self.initialized = true

        // Notify cloudboardd that the HPKE link is established.
        try await self.server.sendResponse(.initialized)
        Self.logger.info("HPKE handshake complete, helper initialized")
    }

    /// hot path - do not log except in error conditions.
    private func handleEncryptedChunk(_ data: Data, isFinal: Bool) async throws {
        guard !self.lifecycle.isTornDown else {
            Self.logger.info("Dropping encrypted chunk after teardown")
            return
        }
        guard self.initialized else {
            Self.logger.error("Received encrypted chunk before initialization")
            throw PersistentHelperAPIError.failedInitialization
        }

        if let decrypted = try self.ohttpStateMachine.receiveChunk(data, isFinal: isFinal) {
            try await self.forwardToPlaintextTarget(decrypted, isFinal: isFinal)
            self.filterQueryCount += 1
            if self.filterQueryCount >= PersistentService.maxFilterQueryCount {
                Self.logger.error(
                    "Filter query limit reached (\(PersistentService.maxFilterQueryCount, privacy: .public)) — triggering self-teardown"
                )
                await self.handleTeardown()
            }
        }
    }

    /// Forwards decrypted plaintext data to the target daemon via XPC.
    /// Hot path, do no logging except in error conditions.
    private func forwardToPlaintextTarget(_ data: Data, isFinal: Bool) async throws {
        guard !self.lifecycle.isTornDown else {
            Self.logger.info("Dropping plaintext forward after teardown")
            return
        }
        guard let connection = self.plaintextConnection else {
            Self.logger.error("No plaintext connection available for forwarding")
            await self.reportFailure(.targetConnectionFailed)
            throw PersistentHelperAPIError.failedInitialization
        }

        // Fire-and-forget: `PersistentPlaintextDataChunk` is a posted message, so this does
        // not wait for the target to run the lookup — that is what lets the (serial, in-order)
        // decrypt loop keep feeding chunks instead of stalling one-query-at-a-time. The lookup
        // result returns out-of-band as a `PersistentPlaintextResponseChunk`. `post` throws only
        // on encode failure, never on delivery; a lost forward just means the client times out
        // that one query, and connection-level failures still surface via
        // `handleConnectionInvalidated`.
        do {
            try await connection.post(PersistentPlaintextDataChunk(data: data, isFinal: isFinal))
        } catch {
            Self.logger.error(
                "Failed to post plaintext forward to target: \(String(reportable: error), privacy: .public)"
            )
        }
    }

    /// Configures message handlers for the plaintext XPC connection to the target daemon.
    ///
    /// The underlying XPC posted-message handler is synchronous (`Success == Never`),
    /// so we still spawn a short Task to hop into actor isolation. The Task body
    /// only yields into the send-pump queue — it does NOT touch
    /// `responseEncapsulator`, so there is no actor-reentrancy window on the OHTTP
    /// state machine under concurrency > 1. The pump drains jobs serially and
    /// owns all encapsulate→send→commit work.
    private nonisolated func configurePlaintextHandlers(
        _ handlers: inout CloudBoardAsyncXPCConnection
            .MessageHandlerStore
    ) {
        handlers.register(PersistentPlaintextResponseChunk.self) { [weak self] message in
            guard let self else { return }
            Task {
                await self.enqueueResponseChunk(data: message.data, isFinal: message.isFinal)
            }
        }
    }

    /// Appends a response chunk to the send pump's queue. Safe to call concurrently
    /// from multiple inbound XPC dispatchers — jobs are processed in yield order.
    /// In production the pump is started by `_start()` under structured scope; the
    /// lazy-start here is a fallback for tests that bypass `_start`.
    private func enqueueResponseChunk(data: Data, isFinal: Bool) {
        guard !self.lifecycle.isTornDown else {
            Self.logger.info("Dropping plaintext response after teardown")
            return
        }
        self.startSendPumpIfNeeded()
        switch self.sendContinuation.yield(SendJob(data: data, isFinal: isFinal)) {
        case .enqueued:
            break
        case .terminated:
            // Teardown finished the stream between the torn-down check and this
            // yield; the chunk is discarded, which is the intended behaviour
            // during shutdown.
            Self.logger.info("Dropping plaintext response after teardown (stream terminated)")
        case .dropped:
            // Queue at capacity. Back-pressure: sacrifice this response chunk.
            // The remote client times the query out and surfaces the failure
            // there. Escalating to helper teardown would turn one slow query
            // into many dropped ones, so we intentionally do not do that.
            let keyIDDesc = self.keyID?.base64EncodedString() ?? "<none>"
            Self.logger.error(
                "Response chunk dropped for keyID \(keyIDDesc, privacy: .public) — send queue at capacity (limit \(Self.sendQueueBufferLimit, privacy: .public)); remote client will time out this query"
            )
        @unknown default:
            let keyIDDesc = self.keyID?.base64EncodedString() ?? "<none>"
            Self.logger.error(
                "Unknown yield result for response chunk (keyID \(keyIDDesc, privacy: .public)); treating as dropped"
            )
        }
    }

    /// Idempotently start the single-consumer send pump. In production this is
    /// invoked by `_start()` so the pump is structurally owned by the surrounding
    /// `withThrowingTaskGroup`. The lazy-start path here is a fallback for tests
    /// that bypass `_start`.
    private func startSendPumpIfNeeded() {
        if self.sendPumpTask != nil { return }
        self.sendPumpTask = Task { [weak self] in
            await self?.runSendPump()
        }
    }

    /// Single-threaded consumer. Reading `self.responseEncapsulator`, encapsulating,
    /// awaiting the send, and committing all happen inside one pump iteration — no
    /// other task on this actor can interleave between encapsulate and commit, so
    /// counter/nonce advancement is monotonic and wire order matches counter order.
    private func runSendPump() async {
        for await job in self.sendQueue {
            if self.lifecycle.isTornDown {
                Self.logger.info("Send pump dropping job after teardown")
                continue
            }
            guard var encapsulator = self.responseEncapsulator else {
                Self.logger.error("Received plaintext response but no response encapsulator is set")
                continue
            }
            let encrypted: Data
            do {
                encrypted = try encapsulator.encapsulate(job.data, final: job.isFinal)
            } catch {
                Self.logger.error(
                    "Failed to encapsulate response; tearing down helper: error=\(String(reportable: error), privacy: .public)"
                )
                await self.reportFailure(.ohttpEncapsulationFailure)
                await self.handleTeardown()
                continue
            }
            do {
                try await self.server.sendResponse(.responseChunk(encrypted, isFinal: job.isFinal))
            } catch {
                Self.logger.error(
                    "Failed to send encrypted response chunk, NOT advancing encapsulator; tearing down: \(String(reportable: error), privacy: .public)"
                )
                await self.handleTeardown()
                continue
            }
            self.responseEncapsulator = encapsulator
        }
    }

    private func handleTeardown() async {
        guard self.lifecycle.markTornDown() else {
            Self.logger.warning("Teardown called after already torn down")
            return
        }
        Self.logger.info("Teardown requested")
        // Finish the send queue so the pump drops any buffered jobs and exits.
        self.sendContinuation.finish()
        self.lifecycle.completeTeardown(with: .success(()))
        await self.plaintextConnection?.cancel()
        self.plaintextConnection = nil
        self.responseEncapsulator = nil
        // Best-effort EOF to cloudboardd; peer may already be gone.
        do {
            try await self.server.sendResponse(.helperEOF)
        } catch {
            Self.logger.info(
                "Could not send helperEOF during teardown (peer likely gone): \(String(reportable: error), privacy: .public)"
            )
        }
    }

    /// Best-effort diagnostic report to cloudboardd when we are about to throw
    /// an initialization / forwarding error. If the report itself fails we log
    /// and move on — the caller will surface the real error.
    private func reportFailure(_ cause: PersistentHelperFailureReason) async {
        do {
            try await self.server.sendResponse(.failureReport(cause))
        } catch {
            Self.logger.error(
                "Failed to send failure report (\(String(describing: cause), privacy: .public)): \(String(reportable: error), privacy: .public)"
            )
        }
    }
}

extension CloudBoardPersistentServerHelper: PersistentHelperAPIClientToServerProtocol {
    package func initialize(_ params: PersistentHelperInitParams) async throws {
        try await self.handleInitialize(params)
    }

    package func initializeClient(_: PersistentClientHelperInitParams) async throws {
        Self.logger.error("Received client-specific init on server helper — rejecting")
        throw PersistentHelperAPIError.failedInitialization
    }

    package func sendEncryptedMessage(_ message: PersistentHelperInboundMessage) async throws {
        switch message {
        case .initialize(let params):
            try await self.handleInitialize(params)
        case .encryptedChunk(let data, isFinal: let isFinal):
            try await self.handleEncryptedChunk(data, isFinal: isFinal)
        case .teardown:
            await self.handleTeardown()
        }
    }

    package func teardown() async throws {
        await self.handleTeardown()
    }
}
