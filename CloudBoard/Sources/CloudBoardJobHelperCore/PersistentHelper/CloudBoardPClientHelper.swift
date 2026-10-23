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
@_spi(HPKEAlgID) import CryptoKit
import Foundation
import HTTPClientStateMachine
import os
#if RC_IS_CLOUDOS_ENABLED && os(iOS)
@_spi(Private) internal import CloudAttestation
#elseif canImport(CloudAttestation)
@_spi(Private) internal import CloudAttestation
#else
#warning("CloudAttestation not available at compile time")
#endif

enum PersistentClientHelperError: Error, CustomStringConvertible {
    case unsupportedAttestationFormat
    case unknownKeyType(String)

    var description: String {
        switch self {
        case .unsupportedAttestationFormat:
            "Attestation bundle is not in a recognized format (test-only or CloudAttestation)"
        case .unknownKeyType(let keyType):
            "Unknown key type in attestation bundle: \(keyType)"
        }
    }
}

/// Per-connection process implementing OHTTP encapsulation for persistent client-side connections.
///
/// Unlike `CloudBoardJobHelper`, this is long-lived (tied to a key lifecycle, not a single request).
/// It receives plaintext queries from a daemon (PersistentServiceClientRouter),
/// encrypts them using OHTTP/HPKE via `OHTTPClientStateMachine`, and forwards the encrypted
/// data toward cb_bridged via an XPC endpoint.
public actor CloudBoardPersistentClientHelper {
    static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardPersistentClientHelper"
    )

    private enum InitState {
        case uninitialized
        case initializing
        case initialized
    }

    let server: PersistentHelperAPIServerProtocol
    let config: CloudBoardCommon.SecureConfig

    let lifecycle: PersistentHelperLifecycle
    private var ohttpClientStateMachine: OHTTPClientStateMachine?
    private var responseDecapsulator: (any OHTTPStreamingResponseDecapsulatorProtocol)?
    private var encryptedConnection: CloudBoardAsyncXPCConnection?
    private var keyID: Data?
    private var initState: InitState = .uninitialized
    private let routerServer: PersistentClientHelperRouterXPCServer
    private var filterQueryCount: UInt64 = 0

    private let metrics: any MetricsSystem

    /// Connection to cb_attestationd used to warm transitive-trust validation. Optional so tests can inject a
    /// double or omit it (warmup is best-effort); created lazily in `_start()` in production.
    private var attestationClient: (any CloudBoardAttestationAPIClientProtocol)?

    /// The remote worker's attestation bundle, retained from initialization so warmup can re-validate it
    /// against the proxy's active keys whenever they roll.
    private var workerAttestationBundle: Data?

    /// In-flight warmup. Latest-wins: a new trigger cancels the prior task since only the current active key
    /// set matters and the worker bundle is fixed for this helper's lifetime.
    private var warmupTask: Task<Void, Never>?

    /// Pre-built metadata subscription payload from cb_bridged (tag 0x02 + serialized MetadataQuery).
    private var metadataSubscriptionPayload: Data?

    // MARK: - Outbound send pump

    /// A single unit of OHTTP-encapsulated outbound traffic. The pump serializes
    /// the `encapsulate → sendResponse → commit` window so concurrent callers
    /// cannot reuse an AEAD nonce or reorder chunks on the wire.
    private struct SendJob {
        let taggedPayload: Data
        let continuation: CheckedContinuation<Void, Error>
    }

    private let sendQueue: AsyncStream<SendJob>
    private let sendContinuation: AsyncStream<SendJob>.Continuation
    private var sendPumpTask: Task<Void, Never>?

    /// Bounded queue depth for the send pump. Reasoning:
    ///   - Peers of this helper are the PrivateFilterClientRouter instances,
    ///     which have observed concurrency ceilings in low-double-digits per
    ///     helper.
    ///   - Each queued job carries one encrypted chunk (low hundreds of bytes),
    ///     so a saturated queue costs on the order of tens of KB.
    ///   - A bound well above expected peak concurrency avoids false drops in
    ///     bursty traffic while still bounding worst-case memory.
    ///   - On overflow the current caller's query fails with
    ///     `helperShuttingDown`; the helper itself keeps serving other
    ///     requests. Losing a single query is an acceptable back-pressure
    ///     response — the router times the caller out and will retry.
    /// See `enqueueOHTTPSend` / `runSendPump` for the producer/consumer.
    private static let sendQueueBufferLimit = 1024

    package init(
        server: PersistentHelperAPIServerProtocol,
        configuration: CloudBoardCommon.SecureConfig,
        routerServer: PersistentClientHelperRouterXPCServer? = nil,
        metrics: (any MetricsSystem)? = nil,
        attestationClient: (any CloudBoardAttestationAPIClientProtocol)? = nil
    ) {
        self.lifecycle = PersistentHelperLifecycle(logger: Self.logger)
        self.server = server
        self.config = configuration
        self.routerServer = routerServer ?? PersistentClientHelperRouterXPCServer.routerListener()
        self.metrics = metrics ?? CloudMetricsSystem(clientName: PClientHelperMetrics.ProcessInfo.prefix)
        self.attestationClient = attestationClient
        (self.sendQueue, self.sendContinuation) = AsyncStream<SendJob>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.sendQueueBufferLimit)
        )
    }

    public init(
        configuration: CloudBoardCommon.SecureConfig
    ) {
        self.lifecycle = PersistentHelperLifecycle(logger: Self.logger)
        self.server = PersistentHelperXPCServer.pclientHelperListener()
        self.config = configuration
        self.routerServer = PersistentClientHelperRouterXPCServer.routerListener()
        self.metrics = CloudMetricsSystem(clientName: PClientHelperMetrics.ProcessInfo.prefix)
        self.attestationClient = nil
        (self.sendQueue, self.sendContinuation) = AsyncStream<SendJob>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.sendQueueBufferLimit)
        )
    }

    public func start() async throws {
        try await CloudBoardMetrics.Uptime.withStandardMetrics(
            processInfo: PClientHelperMetrics.ProcessInfo.self,
            metrics: self.metrics
        ) {
            try await self._start()
        }
    }

    /// Sentinel thrown from the teardown-waiter child task to signal the surrounding
    /// `withThrowingTaskGroup` to cancel siblings (i.e. the send pump). Caught and
    /// discarded by `_start()` — it represents normal shutdown, not failure.
    private struct TeardownSignal: Error {}

    private func _start() async throws {
        Self.logger.info("Starting CloudBoardPersistentClientHelper")

        // Connect to cb_attestationd FIRST — before `server.connect()` makes this helper reachable — so the
        // attestation client is non-nil before any inbound `initializeClient` can run `triggerWarmup()`.
        // Otherwise actor reentrancy during a later `await` could process init while `attestationClient` is
        // still nil, the warmup guard would return, and the connection-time warmup would be silently skipped
        // until the next key roll. Best-effort: if cb_attestationd is unavailable the hot path still validates
        // on use. The lightweight keyRotated broadcast tells us when the proxy's own attestation rolls.
        if self.attestationClient == nil {
            self.attestationClient = await CloudBoardAttestationAPIXPCClient.localConnection()
        }
        if let attestationClient = self.attestationClient {
            await attestationClient.set(delegate: self)
            await attestationClient.connect()
        }

        await self.server.set(delegate: self)
        await self.server.connect()
        await self.server.setOnClientDisconnected { [weak self] in
            guard let self else { return }
            Self.logger.error("cb_bridged connection lost — triggering self-teardown")
            await self.handleTeardown()
        }
        // Start the router-facing XPC server so the PrivateFilterClientRouter
        // can send plaintext queries to this helper.
        await self.routerServer.set(delegate: self)
        await self.routerServer.setOnRouterDisconnected { [weak self] in
            guard let self else { return }
            Self.logger.error("Router connection lost — triggering self-teardown")
            await self.handleTeardown()
        }
        await self.routerServer.connect()
        Self.logger.info("CloudBoardPersistentClientHelper server connected, waiting for initialization")

        // Structured ownership of the send pump: kick it off here so it is
        // running before any inbound XPC traffic, and bound its lifetime to
        // this helper's `_start()` via a `withThrowingTaskGroup`. When the
        // teardown waiter throws `TeardownSignal`, the group cancels the pump
        // and awaits its exit before `_start()` returns. This replaces the
        // earlier unstructured `Task { ... }` that could outlive a stuck
        // `sendResponse`. (Tests that bypass `_start` rely on the lazy-start
        // path in `startSendPumpIfNeeded`; in production the pump is started
        // exactly once, structured under this group.)
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
        guard self.initState == .uninitialized else {
            Self.logger.error("Initialize called in state \(String(describing: self.initState), privacy: .public)")
            throw PersistentHelperAPIError.failedInitialization
        }
        self.initState = .initializing

        Self.logger.info("Initializing with keyID: \(params.keyID.base64EncodedString(), privacy: .public)")
        self.keyID = params.keyID

        // Create OHTTP client state machine for encrypting outbound queries
        Self.logger.info("Creating OHTTP client state machine")
        self.ohttpClientStateMachine = OHTTPClientStateMachine()

        // Establish connection to encrypted target (cb_bridged)
        Self.logger.info("Connecting to encrypted target: \(params.targetEndpoint, privacy: .public)")
        self.encryptedConnection = await CloudBoardAsyncXPCConnection.connect(to: params.targetEndpoint)
        Self.logger.info("Connected to encrypted target: \(params.targetEndpoint, privacy: .public)")

        self.initState = .initialized
        Self.logger.info("Client helper initialized")
    }

    private func handleInitializeClient(_ clientParams: PersistentClientHelperInitParams) async throws {
        guard self.initState == .uninitialized else {
            Self.logger
                .error("InitializeClient called in state \(String(describing: self.initState), privacy: .public)")
            throw PersistentHelperAPIError.failedInitialization
        }
        // Init is single-shot per actor: production callers (`PersistentClientHelperManager`)
        // discard and respawn the helper on any failure rather than retrying. Trigger
        // local teardown on any throw past this point so the actor's lifecycle ends
        // cleanly even before the parent kills the process.
        do {
            try await self.performInitializeClient(clientParams)
        } catch {
            await self.handleTeardown()
            throw error
        }
    }

    private func performInitializeClient(_ clientParams: PersistentClientHelperInitParams) async throws {
        self.initState = .initializing

        Self.logger.info(
            "Initializing client helper with keyID: \(clientParams.keyID.base64EncodedString(), privacy: .public), attestation bundle: \(clientParams.attestationBundle.count, privacy: .public) bytes"
        )
        self.keyID = clientParams.keyID
        self.metadataSubscriptionPayload = clientParams.metadataSubscriptionPayload

        // 1. Extract the public key from the attestation bundle
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            publicKey = try await Self.extractPublicKey(from: clientParams.attestationBundle)
        } catch {
            Self.logger.error(
                "Failed to extract public key from attestation bundle: \(String(reportable: error), privacy: .public)"
            )
            await self.reportFailure(.ohttpEncapsulationFailure)
            throw error
        }
        Self.logger.info("Extracted public key from attestation bundle")

        // Retain the worker bundle and kick off the initial transitive-trust warmup against the proxy's active
        // attestation keys. This is the connection-time trigger: it pre-validates here (the same point we
        // already parse the attestation to extract the key) so the per-request hot path is a cache hit. It is
        // best-effort — a timeout or failure does not block initialization, since the hot path still validates
        // each use and the existing router prevalidation continues to gate a genuinely untrustworthy node.
        self.workerAttestationBundle = clientParams.attestationBundle
        self.triggerWarmup()

        // 2. Create OHTTP client state machine and perform key encapsulation
        Self.logger.info("Creating OHTTP client state machine and encapsulating key")
        var ohttpStateMachine = OHTTPClientStateMachine()
        let encapsulatedKey: Data
        let responseDecapsulator: OHTTPStreamingResponseDecapsulator
        do {
            (encapsulatedKey, responseDecapsulator) = try ohttpStateMachine.encapsulateKey(
                publicKey: publicKey,
                ciphersuite: HPKE.Ciphersuite.Curve25519_SHA256_AES_GCM_128
            )
        } catch {
            Self.logger.error(
                "OHTTP key encapsulation failed: \(String(reportable: error), privacy: .public)"
            )
            await self.reportFailure(.ohttpEncapsulationFailure)
            throw error
        }
        self.ohttpClientStateMachine = ohttpStateMachine
        self.responseDecapsulator = responseDecapsulator
        Self.logger.info(
            "OHTTP key encapsulated: \(encapsulatedKey.count, privacy: .public) bytes"
        )

        // 3. Send the encrypted key back to cb_bridged as a pre-init responseChunk.
        //    The delegate in PersistentClientHelperManager captures this before .initialized.
        try await self.server.sendResponse(.responseChunk(encapsulatedKey, isFinal: false))

        // 4. Signal initialization complete.
        self.initState = .initialized
        try await self.server.sendResponse(.initialized)
        Self.logger.info("Client helper initialized and OHTTP link established")

        // 5. Subscribe to in-stream metadata updates from PrivateFilterController.
        if let subscriptionPayload = self.metadataSubscriptionPayload {
            do {
                try await self.sendMetadataSubscription(payload: subscriptionPayload)
            } catch {
                Self.logger.error(
                    "Failed to send metadata subscription: \(String(reportable: error), privacy: .public)"
                )
                throw error
            }
        }
    }

    /// Encrypts and sends the pre-built metadata subscription payload.
    private func sendMetadataSubscription(payload: Data) async throws {
        var taggedPayload = Data([PersistentServiceStreamTag.metadata])
        taggedPayload.append(payload)
        try await self.enqueueOHTTPSend(taggedPayload: taggedPayload)
        Self.logger.info("Metadata subscription sent")
    }

    // MARK: - Send pump

    /// Idempotently start the pump that serializes encapsulate→send for OHTTP chunks.
    /// In production this is invoked by `_start()` so the pump is structurally
    /// owned by the surrounding `withThrowingTaskGroup`. Tests that bypass
    /// `_start` rely on the lazy-start path here when `enqueueOHTTPSend` is
    /// first called.
    private func startSendPumpIfNeeded() {
        if self.sendPumpTask != nil { return }
        self.sendPumpTask = Task { [weak self] in
            await self?.runSendPump()
        }
    }

    /// Enqueue an OHTTP-encapsulated send and await its completion. Serialization
    /// and in-order wire delivery are guaranteed by the single-consumer pump.
    private func enqueueOHTTPSend(taggedPayload: Data) async throws {
        guard !self.lifecycle.isTornDown else {
            throw PersistentHelperAPIError.helperShuttingDown
        }
        self.startSendPumpIfNeeded()
        try await withCheckedThrowingContinuation { cont in
            let job = SendJob(taggedPayload: taggedPayload, continuation: cont)
            switch self.sendContinuation.yield(job) {
            case .enqueued:
                break
            case .terminated:
                // Teardown finished the stream between our torn-down check above
                // and this yield; the job is dropped. Resume the continuation
                // ourselves so the caller's `await` doesn't leak.
                cont.resume(throwing: PersistentHelperAPIError.helperShuttingDown)
            case .dropped:
                // Queue at capacity. Back-pressure: sacrifice this query — the
                // router observes the caller's thrown error and will time the
                // query out. The helper itself keeps serving; dropping a single
                // job neither advances nor corrupts OHTTP stream state, so
                // there is no reason to escalate by tearing down.
                let keyIDDesc = self.keyID?.base64EncodedString() ?? "<none>"
                Self.logger.error(
                    "SendJob dropped for keyID \(keyIDDesc, privacy: .public) — send queue at capacity (limit \(Self.sendQueueBufferLimit, privacy: .public))"
                )
                cont.resume(throwing: PersistentHelperAPIError.sendQueueOverflow)
            @unknown default:
                cont.resume(throwing: PersistentHelperAPIError.helperShuttingDown)
            }
        }
    }

    /// Consumer loop. Single-threaded by construction: at most one iteration is
    /// in flight at a time, so `self.ohttpClientStateMachine` is only ever read
    /// and committed within a non-suspending window inside the pump — no other
    /// actor caller can interleave and observe the pre-commit state.
    private func runSendPump() async {
        for await job in self.sendQueue {
            if self.lifecycle.isTornDown {
                job.continuation.resume(throwing: PersistentHelperAPIError.helperShuttingDown)
                continue
            }
            guard var stateMachine = self.ohttpClientStateMachine else {
                job.continuation.resume(throwing: PersistentHelperAPIError.failedInitialization)
                continue
            }
            let encryptedData: Data
            do {
                encryptedData = try stateMachine.encapsulateMessage(
                    message: job.taggedPayload, isFinal: false
                )
            } catch {
                Self.logger.error(
                    "OHTTP encryption failed; tearing down helper: \(String(reportable: error), privacy: .public)"
                )
                await self.reportFailure(.ohttpEncapsulationFailure)
                await self.handleTeardown()
                job.continuation.resume(throwing: error)
                continue
            }
            do {
                try await self.server.sendResponse(.responseChunk(encryptedData, isFinal: false))
            } catch {
                Self.logger.error(
                    "Failed to send encrypted chunk, NOT advancing OHTTP counter; tearing down helper to avoid AEAD desync: \(String(reportable: error), privacy: .public)"
                )
                await self.handleTeardown()
                job.continuation.resume(throwing: error)
                continue
            }
            // Commit the advanced counter only on successful send.
            self.ohttpClientStateMachine = stateMachine
            job.continuation.resume()
        }
    }

    /// Extracts the `Curve25519.KeyAgreement.PublicKey` from an attestation bundle.
    ///
    /// Tries the test-only format first (for development/testing environments where
    /// real SEP-backed attestations are unavailable), then falls back to parsing a real
    /// CloudAttestation bundle.
    ///
    /// Note: this performs structural validation (can the bundle be parsed and does it
    /// contain a valid key?) but does NOT perform trust validation (is this a genuine
    /// PCC node?). Trust validation happens separately via cb_jobhelper through the
    /// PrivateFilterClientRouter approval flow.
    private static func extractPublicKey(
        from attestationBundle: Data
    ) async throws -> Curve25519.KeyAgreement.PublicKey {
        // Test-only bundles encode the public key in a format defined by TestOnlyAttestationBundle
        if let testBundle = try TestOnlyAttestationBundle(data: attestationBundle) {
            self.logger.info("Parsed test-only attestation bundle: \(testBundle.version, privacy: .public)")
            return testBundle.publicKey
        }

        #if canImport(CloudAttestation)
        Self.logger.info("Parsing CloudAttestation attestation bundle")
        let bundle = try AttestationBundle(data: attestationBundle)
        /// We only need the validator to extract the public key here.
        /// The validation happens in cb_jobhelper at a later.
        /// Hence it is safe to not perform the TL checks at this point.
        var validator = CloudAttestation.NodeValidator()
        validator.transparencyVerifier = NopTransparencyLog()
        validator.transparencyProofValidation = false
        let (key, _, _) = try await validator.validate(bundle: bundle)
        let rawKey: Data
        switch key {
        case .x963(let rawData):
            rawKey = rawData
        case .curve25519(let rawData):
            rawKey = rawData
        default:
            throw PersistentClientHelperError.unknownKeyType(String(describing: key))
        }
        return try Curve25519.KeyAgreement.PublicKey(rawKey, kem: .Curve25519_HKDF_SHA256)
        #else
        throw PersistentClientHelperError.unsupportedAttestationFormat
        #endif
    }

    private func handleEncryptedChunk(_ data: Data, isFinal: Bool) async throws {
        guard !self.lifecycle.isTornDown else {
            Self.logger.info("Dropping message after teardown")
            return
        }
        guard self.initState == .initialized else {
            Self.logger.error("Received message before initialization")
            throw PersistentHelperAPIError.failedInitialization
        }

        // In the client helper, inbound messages on this protocol are actually encrypted
        // response chunks from the remote server via cb_bridged, which need decapsulation
        if var decapsulator = self.responseDecapsulator {
            let decrypted: Data
            do {
                decrypted = try decapsulator.decapsulateResponseMessage(data, isFinal: isFinal)
                self.responseDecapsulator = decapsulator
            } catch {
                Self.logger.error(
                    "Decapsulation failed: \(String(reportable: error), privacy: .public)"
                )
                // The Router's timeout mechanism will expire the pending query.
                return
            }

            Self.logger.debug(
                "Decapsulated response: \(decrypted.count, privacy: .public) bytes, isFinal: \(isFinal, privacy: .public)"
            )

            // Strip the tag byte prepended by the server-side PersistentServiceResponder
            // before encryption and dispatch based on channel type.
            guard let tag = decrypted.first else {
                Self.logger.error("Empty decrypted response")
                return
            }
            let strippedPayload = Data(decrypted.dropFirst())

            switch tag {
            case PersistentServiceStreamTag.serviceSpecific:
                // Service-specific response — forward to router
                await self.routerServer.sendPlaintextResponse(
                    payload: .success(strippedPayload)
                )

            case PersistentServiceStreamTag.metadata:
                if isFinal {
                    Self.logger.warning(
                        "Metadata frame marked isFinal — server is terminating the stream on a metadata chunk; in-flight service-specific queries will rely on router timeout"
                    )
                }
                // Metadata update — validate against SD announcement
                try await self.server.sendResponse(.metadataUpdate(strippedPayload))

            default:
                Self.logger.error(
                    "Unexpected response tag 0x\(String(tag, radix: 16), privacy: .public), dropping"
                )
            }
        }
    }

    private func handleTeardown() async {
        guard self.lifecycle.markTornDown() else {
            Self.logger.warning("Teardown called after already torn down")
            return
        }
        Self.logger.info("Teardown requested")
        // Stop any in-flight warmup. The attestation connection is released when this per-connection helper is
        // torn down and the process exits.
        self.warmupTask?.cancel()
        // Finish the send queue so the pump drains any buffered jobs with
        // helperShuttingDown and then exits. Safe to call multiple times.
        self.sendContinuation.finish()
        self.lifecycle.completeTeardown(with: .success(()))
        // Best-effort EOF to cb_bridged; the peer may already be gone.
        do {
            try await self.server.sendResponse(.helperEOF)
        } catch {
            Self.logger.info(
                "Could not send helperEOF during teardown (peer likely gone): \(String(reportable: error), privacy: .public)"
            )
        }
    }

    /// Best-effort diagnostic report to cb_bridged when we are about to throw
    /// an initialization / send error. If the report itself fails we log and
    /// move on — the caller will surface the real error.
    private func reportFailure(_ cause: PersistentHelperFailureReason) async {
        do {
            try await self.server.sendResponse(.failureReport(cause))
        } catch {
            Self.logger.error(
                "Failed to send failure report (\(String(describing: cause), privacy: .public)): \(String(reportable: error), privacy: .public)"
            )
        }
    }

    // MARK: - Transitive-trust warmup

    /// (Re)start warmup of the worker attestation against the proxy's active keys. Latest-wins: a new trigger
    /// cancels any in-flight warmup, since only the current active key set matters and the worker bundle is
    /// fixed for this helper's lifetime.
    private func triggerWarmup() {
        guard let bundle = self.workerAttestationBundle, let client = self.attestationClient else {
            return
        }
        self.warmupTask?.cancel()
        self.warmupTask = Task { [weak self] in
            await self?.runWarmup(bundle: bundle, client: client)
        }
    }

    private struct WarmupTimedOut: Error {}

    private func runWarmup(
        bundle: Data,
        client: any CloudBoardAttestationAPIClientProtocol
    ) async {
        self.metrics.emit(PClientHelperMetrics.Warmup.AttemptCounter(action: .increment))
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let summary = try await self.withTimeout(self.config.clientHelperAttestationWarmupTimeout) {
                try await client.warmWorkerValidation(rawWorkerAttestationBundle: bundle)
            }
            let elapsed = started.duration(to: clock.now)
            let outcome: PClientHelperMetrics.Warmup.Outcome = if summary.keysAttempted == 0 {
                .noActiveKey
            } else if summary.keysSucceeded == summary.keysAttempted {
                .success
            } else {
                .partial
            }
            Self.logger.info(
                "Transitive-trust warmup \(outcome.rawValue, privacy: .public): \(summary, privacy: .public) in \(elapsed, privacy: .public)"
            )
            self.metrics.emit(PClientHelperMetrics.Warmup.OutcomeCounter(outcome))
            self.metrics.emit(PClientHelperMetrics.Warmup.DurationHistogram(duration: elapsed))
        } catch is WarmupTimedOut {
            Self.logger.error(
                "Transitive-trust warmup timed out after \(self.config.clientHelperAttestationWarmupTimeout, privacy: .public) — proceeding on the unvalidated path"
            )
            self.metrics.emit(PClientHelperMetrics.Warmup.OutcomeCounter(.timeout))
        } catch is CancellationError {
            // Superseded by a newer warmup trigger (e.g. a key roll) or by teardown; nothing to record.
            Self.logger.debug("Transitive-trust warmup cancelled")
        } catch {
            Self.logger.error(
                "Transitive-trust warmup failed: \(String(reportable: error), privacy: .public) — proceeding on the unvalidated path"
            )
            self.metrics.emit(PClientHelperMetrics.Warmup.OutcomeCounter(error: error))
        }
    }

    /// Run `operation`, throwing ``WarmupTimedOut`` if it does not complete within `timeout`.
    ///
    /// Caveat: this bounds wall-clock only if `operation` is cancellation-responsive. On timeout the throwing
    /// task group cancels the children and then *awaits* them before returning, so if the underlying XPC call
    /// ignores cancellation (a hung/overloaded cb_attestationd) this won't return until that call completes —
    /// the `.timeout` metric and task exit are delayed. This is tolerated because warmup is fire-and-forget
    /// (`triggerWarmup` is not awaited by initialization, so a stuck warmup never blocks the helper) and the hot
    /// path validates each use regardless; the timeout's job is to free the task and record an outcome in the
    /// common case, not to hard-abort an unresponsive peer.
    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WarmupTimedOut()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw WarmupTimedOut()
            }
            return result
        }
    }

    /// Activate the internal encrypted connection so it can be cleanly released.
    /// Only needed in test environments where the target mach service does not exist.
    package func activateEncryptedConnectionForTest() async {
        await self.encryptedConnection?.activate()
    }

    /// Test seam: synchronously drive a single transitive-trust warmup with an injected worker bundle and
    /// await its completion, so tests can assert the emitted metrics deterministically.
    package func runWarmupForTesting(workerAttestationBundle: Data) async {
        self.workerAttestationBundle = workerAttestationBundle
        self.triggerWarmup()
        await self.warmupTask?.value
    }
}

extension CloudBoardPersistentClientHelper: PersistentHelperAPIClientToServerProtocol {
    package func initialize(_ params: PersistentHelperInitParams) async throws {
        try await self.handleInitialize(params)
    }

    package func initializeClient(_ params: PersistentClientHelperInitParams) async throws {
        try await self.handleInitializeClient(params)
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

extension CloudBoardPersistentClientHelper: PersistentClientHelperRouterServerDelegateProtocol {
    package func plaintextQueryReceived(
        payload: Data
    ) async throws {
        guard !self.lifecycle.isTornDown else {
            Self.logger.info("Dropping plaintext query after teardown")
            throw PersistentHelperAPIError.helperShuttingDown
        }
        guard self.initState == .initialized else {
            Self.logger.error("Received plaintext query before initialization")
            throw PersistentHelperAPIError.failedInitialization
        }

        Self.logger.debug(
            "Received plaintext query: \(payload.count, privacy: .public) bytes"
        )

        // Prepend the service-specific tag byte (0x01) so that the server-side
        // PersistentServiceMessage.parse() correctly identifies and strips it.
        var taggedPayload = Data([PersistentServiceStreamTag.serviceSpecific])
        taggedPayload.append(payload)

        // Hand off to the send pump. The pump serializes encapsulate→send so
        // concurrent queries cannot reuse an AEAD nonce or arrive out of
        // counter order on the wire.
        try await self.enqueueOHTTPSend(taggedPayload: taggedPayload)

        self.filterQueryCount += 1
        if self.filterQueryCount >= PersistentService.maxFilterQueryCount {
            Self.logger.error(
                "Filter query limit reached (\(PersistentService.maxFilterQueryCount, privacy: .public)) — triggering self-teardown"
            )
            await self.handleTeardown()
        }
    }

    package func drainCompleteReceived() async {
        Self.logger.info("Drain complete received from router, forwarding to cb_bridged")
        // `drainComplete` is a functional signal cb_bridged waits on to finish
        // tearing the stream down cleanly. If the send fails the peer will time
        // out the drain instead — caller has no recovery, but we surface the
        // failure so it's not silent.
        do {
            try await self.server.sendResponse(.drainComplete)
        } catch {
            Self.logger.error(
                "Failed to forward drainComplete to cb_bridged: \(String(reportable: error), privacy: .public)"
            )
        }
    }
}

extension CloudBoardPersistentClientHelper: CloudBoardAttestationAPIClientDelegateProtocol {
    /// Lightweight key-rotation broadcast: the proxy's own attestation rolled, so the per-proxy-key validation
    /// cache for the new key is cold. Re-warm against the active key set. We only use this as a trigger; the
    /// key set itself is selected daemon-side from the worker bundle we already hold.
    public func keyRotated(newKeySet _: AttestedKeySet) async throws {
        Self.logger.info("Proxy attestation key rotation observed — re-warming transitive trust")
        self.triggerWarmup()
    }

    /// cb_pclienthelper only needs the lightweight key-rotation signal as a re-warm trigger; it does not act on
    /// the heavier attestation-set broadcast.
    public func attestationRotated(newAttestationSet _: AttestationSet) async throws {}

    public func surpriseDisconnect() async {
        Self.logger.error("cb_attestationd connection lost — reconnecting and re-warming transitive trust")
        // Re-activate so broadcast handlers are re-registered on the reconnected connection, then re-warm.
        await self.attestationClient?.connect()
        self.triggerWarmup()
    }
}
