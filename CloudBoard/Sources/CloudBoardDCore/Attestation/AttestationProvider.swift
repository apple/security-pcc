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
import CloudBoardPlatformUtilities
import Foundation
import os

private typealias AttestationTimeToExpiryGauge = Metrics.AttestationProvider.AttestationTimeToExpiryGauge

public enum AttestationError: Error {
    case attestationExpired
    case unavailableWithinTimeout
    case unknownOrExpiredKeyID(_ keyID: Data)
}

/// Obtains and manages attestations provided by cb_attestationd
final actor AttestationProvider: CloudBoardAttestationAPIClientDelegateProtocol {
    private static let metricsRecordingInterval: Duration = .seconds(60)

    // This is shared with the state machine so can't be made private
    fileprivate static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "AttestationProvider"
    )

    private let attestationClient: CloudBoardAttestationAPIClientProtocol
    private let metricsSystem: MetricsSystem
    private var connectionStateMachine: ConnectionStateMachine
    private var attestationStateMachine: AttestationStateMachine
    // maintained as an efficient lookup for the proxy
    // Only required by the proxy, but harmless to maintain anyway
    private var keyIDToTransitivelyTrustedReleases: [Data: [String]] = .init()

    private var attestationInvalidFlag: Bool = false
    private var healthMonitors: [ServiceHealthMonitor]
    private let isProxy: Bool

    init(
        attestationClient: CloudBoardAttestationAPIClientProtocol,
        metricsSystem: MetricsSystem,
        healthMonitors: [ServiceHealthMonitor],
        isProxy: Bool = false
    ) {
        self.attestationClient = attestationClient
        self.metricsSystem = metricsSystem
        self.connectionStateMachine = ConnectionStateMachine()
        self.attestationStateMachine = AttestationStateMachine()
        self.healthMonitors = healthMonitors
        self.isProxy = isProxy
    }

    func run() async throws {
        try await self.runLoop()
    }

    /// exposed for testing only
    internal func runLoop(once: Bool = false) async throws {
        await self.attestationClient.set(delegate: self)
        // Request attestation bundle to make it available as soon as possible
        _ = try await self.currentAttestationSet()

        if once {
            await self.validateAttestations()
        } else {
            while true {
                await self.validateAttestations()
                try await Task.sleep(for: Self.metricsRecordingInterval)
            }
        }
    }

    internal func validateAttestations() async {
        do {
            let attestationSet = try await self.currentAttestationSet()

            let bootIDValid = self.isBootIDValid(attestationSet)
            let expiryValid = attestationSet.currentAttestation.expiry.timeIntervalSince(Date.now) > 0

            self.metricsSystem.emit(
                AttestationTimeToExpiryGauge(expireAt: attestationSet.currentAttestation.expiry)
            )

            if bootIDValid, expiryValid {
                self.sendHealthMonitorStateUpdate(state: .valid)
            } else {
                self.sendHealthMonitorStateUpdate(state: .invalid)
            }
        } catch {
            // If we can't get attestation, mark unhealthy
            self.sendHealthMonitorStateUpdate(state: .error)
            Self.logger.log("Attestation set not available yet. Skip validation")
        }
    }

    private func isBootIDValid(_ attestationSet: AttestationSet) -> Bool {
        // BootID validation is required to route requests to valid workers. We don't care about bootID for proxy
        // attestations.
        guard !self.isProxy else {
            return true
        }

        let bootID = attestationSet.currentAttestation.appData[ComputeNodeAppDataKeys.bootID]?.utf8String ?? ""
        if bootID.isEmpty {
            Self.logger
                .error(
                    "Boot ID is missing from attestation - this is an unrecoverable configuration or implementation error. Worker routing will not function correctly."
                )
            return false
        }
        return true
    }

    private func onNewAttestation(_ attestationSet: AttestationSet) {
        // If any old key is not longer supported by attestationd it's useless anyway, and this avoids
        // trying to manage expiry to avoid a slow memory leak
        self.keyIDToTransitivelyTrustedReleases.removeAll()
        for attestation in attestationSet.allAttestations {
            self.keyIDToTransitivelyTrustedReleases[attestation.keyID] = attestation.proxiedReleaseDigests
        }
    }

    func attestationRotated(newAttestationSet: CloudBoardAttestationDAPI.AttestationSet) async throws {
        Self.logger
            .notice("Received new attestation set from attestation daemon: \(newAttestationSet, privacy: .public)")
        self.onNewAttestation(newAttestationSet)
        self.attestationStateMachine.attestationRotated(attestationSet: newAttestationSet)
    }

    func keyRotated(newKeySet _: CloudBoardAttestationDAPI.AttestedKeySet) async throws {
        // attestationRotated covers us
    }

    /// Used to force an attestation to be dropped entirely - this may trigger a new attestation
    func forceRevocation(keyIDs: [NodeKeyID]) async throws {
        try await self.attestationClient.forceRevocation(keyIDs: keyIDs)
    }

    func surpriseDisconnect() async {
        Self.logger
            .error("XPC connection to CloudBoard attestation daemon terminated unexpectedly. Attempting to reconnect")
        self.connectionStateMachine.resetConnectionStateOnSurpriseDisconnect()
        self.attestationStateMachine.resetAttestationStateOnSurpriseDisconnect()
        // Until we get a reconnect we cannot trust any already seen attestations.
        // The reasonable assumption is that the attestationd has crashed, and is (hopefully) restarting.
        // Even if we cached them here then requests that passed the session store based on that may
        // just end up in jobhelper which does not know about the attestation and fails anyway.
        // it is simpler and safer to just become unhealthy and block new requests to us until
        // this is resolved, which hopefully is quickly (but possibly in a way the invalidates all previously
        // published attestations)
        // After this the next successful attestation message will trigger
        // validateAttestationExpiryAndEmitTimeToExpiry and set us healthy
        self.sendHealthMonitorStateUpdate(state: .error)
        do {
            try await self.ensureConnectionToAttestationDaemon()
        } catch {
            Self.logger.error("Unable to connect to CloudBoard attestation daemon after surprise disconnect.")
        }

        // Request a new attestation set to handle a possible race between reconnecting and a broadcast by
        // cb_attestationd
        do {
            _ = try await self.currentAttestationSet()
        } catch {
            Self.logger.error("Failed to refetch attestation set after surprise disconnect: \(error)")
        }
    }

    /// Find the transitively trusted release set associated to the attestation with key `keyID`
    /// If no such attestation is known (wherether through loss, or expiry) this throws
    func findProxiedReleaseDigests(keyID: Data) async throws -> [String] {
        // this really only covers unit tests where the system is assumed to always
        // have had one successful call (because cloudboard daemon does this)
        if !self.attestationStateMachine.hasCompletedSuccessfullyAtLeastOnce {
            // this is called on the hotpath, so don't block forever if this
            // assumption was wrong
            _ = try await self.currentAttestationSetWithTimeout()
        }
        guard let releases = self.keyIDToTransitivelyTrustedReleases[keyID] else {
            throw AttestationError.unknownOrExpiredKeyID(keyID)
        }
        return releases
    }

    func currentAttestationSet() async throws -> AttestationSet {
        try await self.ensureConnectionToAttestationDaemon()
        switch try self.attestationStateMachine.obtainAttestation() {
        case .requestAttestation:
            do {
                Self.logger.info("requesting attestation set from cb_attestationd")
                let attestationSet = try await self.attestationClient.requestAttestationSet()
                Self.logger.log("successfully obtained current attested set: \(attestationSet, privacy: .public)")
                self.onNewAttestation(attestationSet)
                return self.attestationStateMachine.attestationReceived(attestationSet: attestationSet)
            } catch {
                // We do not invalidate keyIDToTransitivelyTrustedReleases.
                // There might be an issue generating new attestations, attestation daemon might have crashed
                // but there's a reasonable chance aan inflight request will still work
                Self.logger
                    .error("failed to request attestation bundle: \(String(unredacted: error), privacy: .public)")
                return try self.attestationStateMachine.attestationRequestFailed(error: error)
            }
        case .waitForAttestation(let future):
            return try await future.valueWithCancellation
        case .continueWithAttestation(let attestationSet):
            return attestationSet
        }
    }

    /// Performs the same operation as ``currentAttestationSet()`` but with a timeout
    /// so that a failure to get the attestation on a request hot path can be timely.
    /// If there is a problem generating a new attestation, or the attestation daemon is not recovering
    /// it's better to fail this fast.
    func currentAttestationSetWithTimeout(
        // This is used on the hot path for a request.
        // We have worst case heuristics putting a full recycle of the attestationd as < 100ms
        // therefore that's how long we are willing to wait by default.
        timeout: Duration = .milliseconds(100)
    ) async throws -> AttestationSet {
        return try await withThrowingTaskGroup(of: AttestationSet.self) { group in
            group.addTask {
                return try await self.currentAttestationSet()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AttestationError.unavailableWithinTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func ensureConnectionToAttestationDaemon() async throws {
        switch self.connectionStateMachine.checkConnection() {
        case .connect:
            AttestationProvider.logger.info("connecting to cb_attestationd")
            await self.attestationClient.connect()
            self.connectionStateMachine.connectionEstablished()
        case .waitForConnection(let future):
            try await future.valueWithCancellation
        case .continue:
            // Nothing to do
            ()
        }
    }

    func registerForUpdates() -> AsyncStream<AttestationSet> {
        let (stream, continuation) = AsyncStream<AttestationSet>.makeStream()
        self.attestationStateMachine.registerWatcher(continuation)
        return stream
    }
}

extension AttestationProvider {
    enum AttestationState {
        case valid
        case error
        case invalid
    }

    internal func sendHealthMonitorStateUpdate(state: AttestationState) {
        switch state {
        case .valid:
            if self.attestationInvalidFlag {
                self.healthMonitors.forEach { $0.setAttestationValid() }
                self.attestationInvalidFlag = false
                Self.logger.info("CloudBoard attestation active")
            }
        case .error, .invalid:
            if !self.attestationInvalidFlag {
                self.healthMonitors.forEach { $0.setAttestationInvalid() }
                self.attestationInvalidFlag = true
                Self.logger.error("CloudBoard attestation invalid")
            }
        }
    }
}

private struct ConnectionStateMachine {
    internal enum ConnectionState: CustomStringConvertible {
        case initialized
        case connecting(Promise<Void, Error>)
        case connected

        var description: String {
            switch self {
            case .initialized:
                return "initialized"
            case .connecting:
                return "connecting"
            case .connected:
                return "connected"
            }
        }
    }

    private var state: ConnectionState

    init() {
        self.state = .initialized
    }

    enum ConnectAction {
        case connect
        case waitForConnection(Future<Void, Error>)
        case `continue`
    }

    mutating func resetConnectionStateOnSurpriseDisconnect() {
        let connectionState = self.state
        if case .connecting(let promise) = connectionState {
            // fulfill any outstanding promises with failure
            promise.fulfil(with: .failure(CloudBoardAsyncXPCError.connectionInterrupted))
        }

        self.state = .initialized
    }

    mutating func checkConnection() -> ConnectAction {
        switch self.state {
        case .initialized:
            self.state = .connecting(Promise<Void, Error>())
            return .connect
        case .connecting(let promise):
            return .waitForConnection(Future(promise))
        case .connected:
            // Nothing to do, already connected
            return .continue
        }
    }

    mutating func connectionEstablished() {
        let state = self.state
        guard case .connecting(let promise) = state else {
            AttestationProvider.logger
                .error("unexpected connection state \(state, privacy: .public) after connecting to cb_attestationd")
            preconditionFailure(
                "unexpected connection state \(state) after connecting to cb_attestationd"
            )
        }
        promise.succeed()
        self.state = .connected
    }
}

private struct AttestationStateMachine {
    private struct State {
        public var hasCompletedSuccessfullyAtLeastOnce: Bool = false
        public var attestationState: AttestationState
        public var watchers: [AsyncStream<AttestationSet>.Continuation]
    }

    internal enum AttestationState: CustomStringConvertible {
        case initialized
        case awaitingAttestation(Promise<AttestationSet, Error>)
        case attestationAvailable(AttestationSet)
        case attestationUnavailable(Error)

        var description: String {
            switch self {
            case .initialized:
                return "initialized"
            case .awaitingAttestation:
                return "awaitingAttestation"
            case .attestationAvailable(let attestationSet):
                return "attestationAvailable(keyExpiry: \(attestationSet.currentAttestation.expiry))"
            case .attestationUnavailable(let error):
                return "attestationUnavailable(error: \(error)"
            }
        }
    }

    private var state: OSAllocatedUnfairLock<State>

    init() {
        self.state = .init(initialState: .init(attestationState: .initialized, watchers: []))
    }

    var hasCompletedSuccessfullyAtLeastOnce: Bool {
        return self.state.withLock(\.hasCompletedSuccessfullyAtLeastOnce)
    }

    enum AttestationAction {
        case requestAttestation
        case waitForAttestation(Future<AttestationSet, Error>)
        case continueWithAttestation(AttestationSet)
    }

    mutating func resetAttestationStateOnSurpriseDisconnect() {
        self.state.withLock { state in
            if case .awaitingAttestation(let promise) = state.attestationState {
                // fulfill any outstanding promises with failure
                promise.fulfil(with: .failure(CloudBoardAsyncXPCError.connectionInterrupted))
            }
            state.attestationState = .initialized
            state.hasCompletedSuccessfullyAtLeastOnce = false
        }
    }

    mutating func obtainAttestation() throws -> AttestationAction {
        try self.state.withLock { state in
            switch state.attestationState {
            case .initialized:
                state.attestationState = .awaitingAttestation(Promise<AttestationSet, Error>())
                return .requestAttestation
            case .awaitingAttestation(let promise):
                return .waitForAttestation(Future(promise))
            case .attestationAvailable(let attestationSet):
                return .continueWithAttestation(attestationSet)
            case .attestationUnavailable(let error):
                throw error
            }
        }
    }

    mutating func attestationReceived(attestationSet: AttestationSet) -> AttestationSet {
        // We might have gotten additional requests or the key might have rotated and has been updated in the meantime
        self.state.withLock { state in
            switch state.attestationState {
            case .awaitingAttestation(let promise):
                promise.succeed(with: attestationSet)
                state.hasCompletedSuccessfullyAtLeastOnce = true
                state.attestationState = .attestationAvailable(attestationSet)
                for watcher in state.watchers {
                    watcher.yield(attestationSet)
                }
                return attestationSet
            case .attestationAvailable(let attestationSet):
                // Key set has rotated in the meantime. Use the rotated set.
                return attestationSet
            case .initialized, .attestationUnavailable:
                // We should never get into any other state
                let currentState = state.attestationState
                AttestationProvider.logger
                    .error("unexpected state: \(currentState, privacy: .public) after requesting attestation set")
                preconditionFailure("unexpected state: \(currentState) after requesting attestation set")
            }
        }
    }

    mutating func attestationRequestFailed(error: Error) throws -> AttestationSet {
        try self.state.withLock { state in
            switch state.attestationState {
            case .awaitingAttestation(let promise):
                promise.fail(with: error)
                state.attestationState = .attestationUnavailable(error)
            case .attestationAvailable(let attestationSet):
                // Key has successfully rotated in the meantime. Use the rotated key and ignore error.
                AttestationProvider.logger.notice(
                    "failed to request attestation set but attestation set has successfully rotated in the meantime. Continuing with rotated attestation set."
                )
                return attestationSet
            case .initialized, .attestationUnavailable:
                // We should never get into any other state
                let currentState = state.attestationState
                AttestationProvider.logger
                    .error(
                        "unexpected state: \(currentState, privacy: .public) when handling attestation request error"
                    )
                preconditionFailure("unexpected state: \(currentState) when handling attestation request error")
            }
            // Rethrow if we couldn't recover from the error
            throw error
        }
    }

    mutating func attestationRotated(attestationSet: AttestationSet) {
        self.state.withLock { state in
            switch state.attestationState {
            case .awaitingAttestation(let promise):
                promise.succeed(with: attestationSet)
            case .initialized, .attestationAvailable, .attestationUnavailable:
                // Nothing to do
                ()
            }
            state.attestationState = .attestationAvailable(attestationSet)
            for watcher in state.watchers {
                watcher.yield(attestationSet)
            }
        }
    }

    mutating func registerWatcher(_ continuation: AsyncStream<AttestationSet>.Continuation) {
        self.state.withLock { state in
            state.watchers.append(continuation)
            switch state.attestationState {
            case .attestationAvailable(let attestationSet):
                continuation.yield(attestationSet)
            default: ()
            }
        }
    }
}

extension AttestationError: ReportableError {
    public var publicDescription: String {
        return switch self {
        case .attestationExpired: "attestationExpired"
        case .unavailableWithinTimeout: "unavailableWithinTimeout"
        // the keyID is visible in the request parameters
        case .unknownOrExpiredKeyID(let keyID): "unknownOrExpiredKeyID \(keyID.base64EncodedString())"
        }
    }
}
