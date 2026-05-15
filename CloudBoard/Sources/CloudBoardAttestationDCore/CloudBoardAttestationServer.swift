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

internal import CloudBoardAsyncXPC
import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardLogging
import CloudBoardMetrics
import CryptoKit
import Foundation
import NIOCore
import os
import Synchronization

/// Serves requests from other components (cloudboardd and cb_jobhelper) for attestations/attested keys
actor CloudBoardAttestationServer<ClockType: DateAwareClock>: CloudBoardAttestationAPIServerDelegateProtocol {
    public let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "CloudBoardAttestationServer"
    )

    fileprivate typealias RevocationRequest = [Data]

    private let apiServer: CloudBoardAttestationAPIServerProtocol
    private let attestationProvider: any AttestationProviderProtocol
    private let releasesProvider: ReleasesProviderProtocol?
    private let keyLifetime: TimeAmount
    private let keyExpiryGracePeriod: TimeAmount
    private let keychain: SecKeychain?
    private let attestationCache: AttestationBundleCache
    private let metrics: MetricsSystem
    private let workerValidationCache: WorkerValidationCache<ClockType>
    private let isProxy: Bool
    private let clock: ClockType
    private let existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition: Bool
    private let revocationRequests = CancellableAsyncNotification<RevocationRequest>()
    private var waitingTillRunning: [CheckedContinuation<Void, any Error>]? = []

    private var stateMachine: AttestationStateMachine
    private var _unpublishedKeys: [InternalAttestedKey] = []
    // This is only ever mutated safely on the actor
    // it may be read outside of it though in tests
    private let _proxiedReleases = Mutex<[ReleaseDigestEntry]>([])

    private var activeUnpublishedKeys: [InternalAttestedKey] {
        return self._unpublishedKeys.filter { $0.expiry > .now }
    }

    // Exposed solely for unit tests
    private(set) var proxiedReleases: [ReleaseDigestEntry] {
        get {
            return self._proxiedReleases.withLock { $0 }
        }
        set {
            self._proxiedReleases.withLock { $0 = newValue }
        }
    }

    init(
        apiServer: CloudBoardAttestationAPIServerProtocol,
        attestationProvider: any AttestationProviderProtocol,
        attestationValidatorFactory: any AttestationValidatorFactoryProtocol,
        releasesProvider: ReleasesProviderProtocol? = nil,
        enableReleaseSetValidation: Bool,
        keyLifetime: TimeAmount,
        keyExpiryGracePeriod: TimeAmount,
        keychain: SecKeychain? = nil,
        metrics: MetricsSystem,
        attestationCache: AttestationBundleCache,
        existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition: Bool,
        maximumValidatedEntryCacheSize: Int,
        isProxy: Bool,
        // abstracted to allow unit testing
        clock: ClockType,
        workerRackIDCacheTTL: Int
    ) {
        self.apiServer = apiServer
        self.attestationProvider = attestationProvider
        self.releasesProvider = releasesProvider
        self.keyLifetime = keyLifetime
        self.keyExpiryGracePeriod = keyExpiryGracePeriod
        self.keychain = keychain
        self.attestationCache = attestationCache
        self.stateMachine = AttestationStateMachine(logger: self.logger)
        self.isProxy = isProxy
        self.workerValidationCache = WorkerValidationCache<ClockType>(
            factory: attestationValidatorFactory,
            enableReleaseSetValidation: enableReleaseSetValidation,
            maximumValidatedEntrySize: maximumValidatedEntryCacheSize,
            metrics: metrics,
            clock: clock,
            workerRackIDCacheTTLMinutes: workerRackIDCacheTTL
        )
        self.metrics = metrics
        self.clock = clock
        self
            .existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition =
            existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition
    }

    deinit {
        self.stateMachine.reset()
        if let waitingTillRunning {
            for continuation in waitingTillRunning {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func requestAttestedKeySet() async throws -> AttestedKeySet {
        self.logger.info("Received request for attested key set")
        do {
            let activeKey = try await self.obtainAttestedKey()
            let keySet = try AttestedKeySet(
                currentKey: activeKey
                    .exportable(
                        logger: self.logger
                    ),
                unpublishedKeys: self.activeUnpublishedKeys.map { try $0.exportable(
                    logger: self.logger
                ) }
            )
            self.logger.log("Returning key set: \(keySet, privacy: .public)")
            return keySet
        } catch {
            self.logger.error("Failed to obtain attested key: \(String(unredacted: error), privacy: .public)")
            throw error
        }
    }

    func requestAttestationSet() async throws -> AttestationSet {
        self.logger.info("Received request for attestation set")
        do {
            let activeKey = try await self.obtainAttestedKey()
            let attestationSet = AttestationSet(
                currentAttestation: .init(key: activeKey),
                unpublishedAttestations: self.activeUnpublishedKeys.map { .init(key: $0) }
            )
            self.logger.log("Returning attestation set: \(attestationSet, privacy: .public)")
            return attestationSet
        } catch {
            self.logger.error("Failed to obtain attested key: \(String(unredacted: error), privacy: .public)")
            throw error
        }
    }

    /// Causes a revocation check in the near future
    func forceRevocation(keyIDs: [Data]) async throws {
        self.logger.info("Received forceRevocation for \(keyIDs.count, privacy: .public) keys")
        await self.revocationRequests.yield(keyIDs)
    }

    func validateWorkerAttestation(
        proxyAttestationKeyID: Data,
        rawWorkerAttestationBundle: Data
    ) async throws -> CloudBoardAttestationDAPI.WorkerValidationResult {
        guard self.isProxy else {
            self.logger.error("requested validation of a worker attestation when not a proxy!")
            throw CloudBoardAttestationAPIError.internalError
        }
        return try await self.workerValidationCache.validateWorkerAttestation(
            proxyAttestationKeyID: proxyAttestationKeyID,
            rawWorkerAttestationBundle: rawWorkerAttestationBundle
        )
    }

    private func obtainAttestedKey() async throws -> InternalAttestedKey {
        switch try self.stateMachine.obtainAttestedKey() {
        case .waitForInitialization(let future):
            self.logger.info("Waiting for initialization to complete")
            if let attestedKey = try await future.valueWithCancellation {
                self.logger.info("Continuing with cached key \(attestedKey, privacy: .public)")
                return attestedKey
            } else {
                return try await self.obtainAttestedKey()
            }
        case .createAttestedKey:
            do {
                self.logger.info("Requested to create new attested key")
                let attestedKey = try await createNewAttestedKey()
                return self.stateMachine.attestedKeyReceived(key: attestedKey)
            } catch {
                self.logger.error("Failed to create attested key: \(String(unredacted: error), privacy: .public)")
                return try self.stateMachine.keyRequestFailed(error: error)
            }
        case .waitForAttestedKey(let future):
            self.logger.info("Waiting for attested key to become available")
            return try await future.valueWithCancellation
        case .continueWithAttestedKey(let key):
            self.logger.info("Requested to continue with key \(key, privacy: .public)")
            return key
        }
    }

    private func createNewAttestedKey() async throws -> InternalAttestedKey {
        // Actual key expiry is slightly longer (by self.keyExpiryGracePeriod) than the advertised key expiry to avoid
        // TOCTOU issues and to allow for latency between client-side validation and CloudBoard receiving requests
        let advertisedKeyLifetime = Duration.seconds(self.keyLifetime.timeInterval)

        let internalAttestedKey = try await self.attestationProvider
            .createAttestedKey(
                clock: self.clock,
                attestationLifetime: advertisedKeyLifetime,
                keyExpiryGracePeriod: self.keyExpiryGracePeriod.timeInterval,
                proxiedReleaseDigests: self.proxiedReleases
            )

        /// For  a SEP backed key store in the keychain
        if case .sepKey(let secKey) = internalAttestedKey.key {
            do {
                try Keychain.add(
                    key: secKey,
                    keyId: Data(SHA256.hash(data: internalAttestedKey.attestationBundle)),
                    keychain: self.keychain
                )
            } catch {
                self.logger.error(
                    "Failed to add key to keychain: \(error, privacy: .public)"
                )
                throw error
            }
        }

        self.logger.log(level: .default, """
        New attested key created with
        KeyID=\(internalAttestedKey.keyID.base64EncodedString(), privacy: .public)
        Expiry=\(internalAttestedKey.expiry, privacy: .public)
        ProxiedReleaseDigests=\(internalAttestedKey.proxiedReleaseDigests, privacy: .public)
        ReleaseDigest=\(internalAttestedKey.releaseDigest, privacy: .public)
        AppData=\(internalAttestedKey.appData.forLogging(), privacy: .public)
        """)

        if self.isProxy {
            try await self.workerValidationCache.notifyOfNewKey(proxyKey: internalAttestedKey)
        }
        do {
            try await self.attestationCache.write(.init(
                keyId: internalAttestedKey.keyID,
                attestationBundle: internalAttestedKey.attestationBundle
            ))
            self.logger
                .notice(
                    "Cached attested key with keyID: \(internalAttestedKey.keyID.base64EncodedString(), privacy: .public)"
                )
        } catch {
            self.logger.error("Failed to cache attestation bundle: \(error, privacy: .public)")
        }
        return internalAttestedKey
    }

    private func initializeFromCache() async throws {
        let attestedKeys = await self.attestationProvider
            .restoreKeysFromDisk(
                attestationCache: self.attestationCache,
                keyExpiryGracePeriod: self.keyExpiryGracePeriod.timeInterval
            )
            .filter { self.filterKeyForCurrentReleases($0) }
        if self.isProxy {
            for key in attestedKeys {
                try await self.workerValidationCache.notifyOfNewKey(proxyKey: key)
            }
        }

        if !attestedKeys.isEmpty {
            self._unpublishedKeys = attestedKeys

            if self.existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition,
               !Set(self.proxiedReleases.map { $0.releaseDigestHexString })
                   .isSubset(of: self._unpublishedKeys.last!.proxiedReleaseDigests) {
                self._unpublishedKeys.indices.forEach { self._unpublishedKeys[$0].availableOnNodeOnly = true }
                self.stateMachine.initialize()
            } else {
                self.stateMachine.initialize(cachedKey: self._unpublishedKeys.removeLast())
            }
        } else {
            self.stateMachine.initialize()
        }
    }

    /// tests benefit from waiting till the initialisation is done
    internal func waitTillRunning() async throws {
        if self.waitingTillRunning == nil {
            return // no need to wait
        }
        try await withCheckedThrowingContinuation { continuation in
            // need to check again
            if self.waitingTillRunning == nil {
                continuation.resume()
            } else {
                self.waitingTillRunning?.append(continuation)
            }
        }
    }

    private enum RunLoopEvent {
        case rotationRequired
        case releaseSetChange([ReleaseDigestEntry])
        case keyRevocation(RevocationRequest)
        case cancelled
    }

    func run() async throws {
        await self.apiServer.set(delegate: self)
        await self.apiServer.connect()

        self.proxiedReleases = try await self.releasesProvider?.getCurrentReleaseSet() ?? []
        try await self.initializeFromCache()

        // Create initial attested key
        self.logger.info("Creating initial attested key")
        var currentKey = try await self.obtainAttestedKey()

        // considered running from here, not legal to call run twice
        for continuation in self.waitingTillRunning! {
            continuation.resume()
        }
        self.waitingTillRunning = nil

        if self.releasesProvider == nil {
            self.logger.warning("No releases provider configured, will not poll for release set updates.")
        }

        while true {
            try Task.checkCancellation()
            // We substract the grace period as we want to rotate the key once the previous key has reached half of the
            // time of the advertised expiry, having ~2 overlapping keys active at a time by default
            let currentKeyLife = currentKey.expiry.timeIntervalSinceNow(self.clock)
            let currentKeyHalfLife = (currentKeyLife - self.keyExpiryGracePeriod.timeInterval) / 2.0
            var performRotation = false
            try await withThrowingTaskGroup(of: RunLoopEvent.self) { group in
                // We wait for either:
                // 1) the time to rotate the key
                // 2) till there's an update in the releases set
                // 3) a key revocation notification arrives
                if currentKeyHalfLife >= 0 {
                    group.addTask {
                        self.logger.notice(
                            "Sleeping for \(currentKeyHalfLife, privacy: .public) seconds before rotating the attested key"
                        )
                        do {
                            try await Task.sleep(
                                for: .seconds(currentKeyHalfLife),
                                tolerance: .zero,
                                clock: self.clock
                            )
                        } catch is CancellationError {
                            return RunLoopEvent.cancelled
                        }
                        return RunLoopEvent.rotationRequired
                    }
                } else {
                    self.logger.critical("Current attested key expired before successfully rotating!")
                }

                if let releasesProvider {
                    // This task is vulnerable to cancellation while in progress due to the timeout in the
                    // expiry check. In reality the expiry is long enough that would be very unlikely, but
                    // it can happen in testing a lot
                    // The task therefore should only update trivial state, and loss of that update
                    // should be idempotent if restarted and the update did not take effect
                    group.addTask {
                        self.logger.notice("Listening for release digest updates...")
                        let updateSubscription = try await releasesProvider.trustedReleaseSetUpdates()
                        let releases = await withTaskCancellationHandler {
                            await updateSubscription.updates.first { await $0 != self.proxiedReleases }
                        } onCancel: {
                            releasesProvider.deregister(updateSubscription.id)
                        }
                        guard let releases else {
                            return RunLoopEvent.cancelled
                        }
                        return RunLoopEvent.releaseSetChange(releases)
                    }
                }

                // if this triggers we must act on the result, even if other events are happening,
                // so once the notification is recieved do no further awaits
                group.addTask {
                    if let revocations = try await self.revocationRequests.waitForNotification() {
                        return RunLoopEvent.keyRevocation(revocations)
                    }
                    return RunLoopEvent.cancelled
                }

                // Consume all events before moving on if because not all events are 'self renewing'
                // if multiple occur in the same loop and are not handled first (such as key revocations)
                while let runLoopEvent = try await group.next() {
                    switch runLoopEvent {
                    case .rotationRequired:
                        self.logger.log("key rotation timer expired, performing rotation")
                        performRotation = true
                    case .releaseSetChange(let releaseDigests):
                        if self.existingAttestationsAvailableOnlyOnNodeAfterReleaseEntryAddition,
                           !Set(releaseDigests).isSubset(of: self.proxiedReleases) {
                            self.logger.log(
                                "Marking all keys as available only on the node after release entry addition. They will no longer be sent to ROPES"
                            )
                            currentKey.availableOnNodeOnly = true
                            self._unpublishedKeys.indices
                                .forEach { self._unpublishedKeys[$0].availableOnNodeOnly = true }
                        }
                        self.logger.log(
                            "Updated the proxied releases to: \(releaseDigests.map(\.releaseDigestHexString).joined(separator: ", "), privacy: .public)"
                        )
                        self.proxiedReleases = releaseDigests
                        performRotation = true
                    case .keyRevocation(let keyIDs):
                        let toRevoke = Set(keyIDs)
                        var revoked = Set<Data>()
                        // Any active request already passed anti replay checks, so don't destroy the key
                        // SessionStore retains a block on those keys so the antiReplay properties are
                        // retained (cloudboard will reject future attempts to replay anything).
                        // However from a usability perspective we additionaly need to:
                        // * stop advertising it to ROPES so no new requests come in
                        // * if it's the current attestation - make a new one right now
                        // This is all controlled by the attestation daemon so we send it a message and let
                        // it work out how to resolve things
                        if toRevoke.contains(currentKey.keyID) {
                            currentKey.availableOnNodeOnly = true
                            revoked.insert(currentKey.keyID)
                            self.logger.warning("the current key was revoked - performing an early rotation")
                            performRotation = true
                        }
                        for index in self._unpublishedKeys.indices {
                            if toRevoke.contains(self._unpublishedKeys[index].keyID) {
                                self._unpublishedKeys[index].availableOnNodeOnly = true
                                revoked.insert(self._unpublishedKeys[index].keyID)
                            }
                        }
                        for keyID in toRevoke.subtracting(revoked) {
                            self.logger
                                .error(
                                    "revocation for key \(keyID.base64EncodedString(), privacy: .public) failed - no such key found"
                                )
                        }
                    case .cancelled:
                        self.logger.debug("cancel notification received")
                        ()
                    }
                    if !group.isCancelled {
                        self.logger.debug("cancelling group")
                        group.cancelAll()
                    }
                }
            }
            if performRotation {
                do {
                    let newKey = try await createNewAttestedKey()
                    self.stateMachine.keyRotated(key: newKey)
                    self._unpublishedKeys += [currentKey]
                    currentKey = newKey
                } catch {
                    if let attestationProviderError = error as? CloudAttestationProviderError,
                       case .releaseDigestsExpirationCheckFailed = attestationProviderError {
                        self.logger.error(
                            "No release digest entry found which expires after key generation expiry. The current key will expire in \(currentKeyLife, privacy: .public) seconds!"
                        )
                        continue
                    } else {
                        throw error
                    }
                }
            }

            // Remove expired keys from keychain
            // lots of side effects so not appropriate for a filter
            var keepUnpublishedKeys: [InternalAttestedKey] = []
            for key in self._unpublishedKeys {
                if key.expiry < self.clock.dateNow {
                    self.logger.notice(
                        "Removing expired key with key ID \(key.keyID.base64EncodedString(), privacy: .public) and expiry \(key.expiry, privacy: .public)"
                    )
                    // Remove from keychain if persisted
                    do {
                        switch key.key {
                        case .direct:
                            // Nothing to do
                            ()
                        case .sepKey(let secKey):
                            try Keychain.delete(persistentKeyRef: secKey.persistentRef(), keychain: self.keychain)
                        }
                    } catch {
                        self.logger.error(
                            "Failed to delete key with key ID \(key.keyID.base64EncodedString(), privacy: .public): \(String(unredacted: error), privacy: .public)"
                        )
                    }
                    await self.attestationCache.remove(keyId: key.keyID)
                    // The key is destroyed, so clear any cache it's now wrong and useless
                    if self.isProxy {
                        await self.workerValidationCache.notifyOfKeyRemoval(proxyKey: key)
                    }
                } else {
                    if self.filterKeyForCurrentReleases(key) {
                        keepUnpublishedKeys.append(key)
                    }
                }
            }
            self._unpublishedKeys = keepUnpublishedKeys
            // It's possible that we didn't actually rotate the key, but this occurs only on revocations
            // and so we just treat this as having happened, it's not a problem to repeat ourselves
            let keySet = try AttestedKeySet(
                currentKey: currentKey
                    .exportable(
                        logger: self.logger
                    ),
                unpublishedKeys: self.activeUnpublishedKeys.map { try $0.exportable(
                    logger: self.logger
                ) }
            )
            self.metrics.emit(Metrics.CloudBoardAttestationServer.KeyRotationCounter(action: .increment(by: 1)))
            self.logger.notice("Broadcasting new attested key set: \(keySet, privacy: .public)")
            try await self.apiServer.keyRotated(newKeySet: keySet)
            try await self.apiServer.attestationRotated(newAttestationSet: .init(
                currentAttestationKey: currentKey,
                unpublishedAttestationKeys: self.activeUnpublishedKeys
            ))
        }
    }

    private func filterKeyForCurrentReleases(_ key: InternalAttestedKey) -> Bool {
        if self.releasesProvider != nil {
            for release in key.proxiedReleaseDigests {
                if self.proxiedReleases
                    .contains(where: { releaseEntry in release == releaseEntry.releaseDigestHexString }) {
                    return true
                }
            }
            self.logger.notice(
                "Not publishing key with key ID \(key.keyID.base64EncodedString(), privacy: .public) anymore as none of associated release digests active anymore"
            )
            return false
        }
        return true
    }
}

private struct AttestationStateMachine {
    private let logger: Logger

    enum AttestationStateMachineError: ReportableError {
        case keyFetchCancelled

        var publicDescription: String {
            let errorType = switch self {
            case .keyFetchCancelled: "keyFetchCancelled"
            }
            return "\(errorType)"
        }
    }

    internal enum AttestationState: CustomStringConvertible {
        case initializing(Promise<InternalAttestedKey?, Error>)
        case initialized
        case awaitingAttestedKey(Promise<InternalAttestedKey, Error>)
        case attestedKeyAvailable(key: InternalAttestedKey)
        case attestedKeyUnavailable(Error)

        var description: String {
            switch self {
            case .initializing:
                return "initializing"
            case .initialized:
                return "initialized"
            case .awaitingAttestedKey:
                return "awaitingAttestedKey"
            case .attestedKeyAvailable(let key):
                return "attestationAvailable(expiry: \(key.expiry))"
            case .attestedKeyUnavailable(let error):
                return "attestationUnavailable(error: \(error)"
            }
        }
    }

    private var state: AttestationState

    init(logger: Logger) {
        self.logger = logger
        self.state = .initializing(Promise<InternalAttestedKey?, Error>())
    }

    enum AttestedKeyAction {
        case waitForInitialization(Future<InternalAttestedKey?, Error>)
        case createAttestedKey
        case waitForAttestedKey(Future<InternalAttestedKey, Error>)
        case continueWithAttestedKey(InternalAttestedKey)
    }

    mutating func initialize(cachedKey: InternalAttestedKey? = nil) {
        switch self.state {
        case .initializing(let promise):
            promise.succeed(with: cachedKey)
            if let cachedKey {
                self.state = .attestedKeyAvailable(key: cachedKey)
            } else {
                self.state = .initialized
            }
        default:
            // do nothing
            ()
        }
    }

    mutating func obtainAttestedKey() throws -> AttestedKeyAction {
        switch self.state {
        case .initializing(let promise):
            return .waitForInitialization(Future(promise))
        case .initialized:
            self.state = .awaitingAttestedKey(Promise<InternalAttestedKey, Error>())
            return .createAttestedKey
        case .awaitingAttestedKey(let promise):
            return .waitForAttestedKey(Future(promise))
        case .attestedKeyAvailable(let key):
            return .continueWithAttestedKey(key)
        case .attestedKeyUnavailable(let error):
            throw error
        }
    }

    mutating func attestedKeyReceived(key: InternalAttestedKey) -> InternalAttestedKey {
        // We might have gotten additional requests or the key might have rotated and has been updated in the meantime
        switch self.state {
        case .awaitingAttestedKey(let promise):
            promise.succeed(with: key)
            self.state = .attestedKeyAvailable(key: key)
            return key
        case .attestedKeyAvailable(let key):
            // Key has rotated in the meantime. Use the rotated key.
            return key
        case .initializing, .initialized, .attestedKeyUnavailable:
            // We should never get into any other state
            let state = self.state
            self.logger
                .error("unexpected state: \(state, privacy: .public) after requesting attested key")
            preconditionFailure("unexpected state: \(state) after requesting attested key")
        }
    }

    mutating func keyRotated(key: InternalAttestedKey) {
        switch self.state {
        case .awaitingAttestedKey(let promise):
            promise.succeed(with: key)
        case .initializing, .initialized, .attestedKeyAvailable, .attestedKeyUnavailable:
            // do nothing
            ()
        }
        self.state = .attestedKeyAvailable(key: key)
    }

    mutating func keyRequestFailed(error: Error) throws -> InternalAttestedKey {
        switch self.state {
        case .awaitingAttestedKey(let promise):
            promise.fail(with: error)
            self.state = .attestedKeyUnavailable(error)
            // Rethrow since we couldn't recover from the error
            throw error
        case .attestedKeyAvailable(let key):
            // Key has successfully rotated in the meantime. Use the rotated key and ignore error.
            self.logger.warning(
                "failed to request attestaton but attestation has successfully rotated in the meantime. Continuing with rotated attestation."
            )
            return key
        case .initializing, .initialized, .attestedKeyUnavailable:
            // We should never get into any other state
            let state = self.state
            self.logger
                .error("unexpected state: \(state, privacy: .public) when handling attestation request error")
            preconditionFailure("unexpected state: \(state) when handling attestation request error")
        }
    }

    mutating func reset() {
        switch self.state {
        case .initializing(let promise):
            promise.succeed(with: nil)
        case .awaitingAttestedKey(let promise):
            promise.fail(with: AttestationStateMachineError.keyFetchCancelled)
        case .initialized, .attestedKeyAvailable, .attestedKeyUnavailable:
            ()
        }
        self.state = .attestedKeyUnavailable(AttestationStateMachineError.keyFetchCancelled)
    }
}

extension InternalAttestedKey {
    /// Creates AttestedKey from the InternalAttestedKey. For a SEP-backed key this
    /// will obtain a persistent reference that can be shared across process boundaries.
    func exportable(
        logger: Logger,
    ) throws -> AttestedKey {
        let key: AttestedKeyType
        switch self.key {
        case .direct(let data):
            key = .direct(privateKey: data)
        case .sepKey(let secKey):
            do {
                key = try .keychain(persistentKeyReference: secKey.persistentRef())
            } catch {
                logger.error(
                    "Failed to obtain persistent reference for node key: \(error, privacy: .public)"
                )
                throw error
            }
        }
        return AttestedKey(
            key: key,
            keyID: self.keyID,
            expiry: self.expiry,
            appData: self.appData
        )
    }
}

extension AttestationSet.Attestation {
    init(key: InternalAttestedKey) {
        self = .init(
            attestationBundle: key.attestationBundle,
            expiry: key.expiry,
            releaseDigest: key.releaseDigest,
            availableOnNodeOnly: key.availableOnNodeOnly,
            proxiedReleaseDigests: key.proxiedReleaseDigests,
            appData: key.appData
        )
    }
}

extension AttestationSet {
    init(currentAttestationKey: InternalAttestedKey, unpublishedAttestationKeys: [InternalAttestedKey]) {
        self = .init(
            currentAttestation: .init(key: currentAttestationKey),
            unpublishedAttestations: unpublishedAttestationKeys.map { .init(key: $0) }
        )
    }
}

extension Duration {
    public init(_ timeAmount: TimeAmount) {
        self = .nanoseconds(timeAmount.nanoseconds)
    }
}

extension TimeAmount {
    public var timeInterval: TimeInterval {
        return Double(self.nanoseconds) / 1_000_000_000
    }
}

/// For logging AppData - in almost all cases it will be a UTF8 string
extension [String: Data] {
    func forLogging() -> [String: String] {
        self.mapValues { data in
            if let string = data.utf8String {
                return string
            }
            return "base64: \(data.base64EncodedString())"
        }
    }
}
