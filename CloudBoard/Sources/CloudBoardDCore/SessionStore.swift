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

import CloudBoardAttestationDAPI

import CloudBoardCommon
import CloudBoardLogging
import CloudBoardMetrics
import DequeModule
import Foundation
import NIOCore
import NIOFoundationCompat
import os
import Synchronization

enum SessionError: Error {
    case invalidKeyMaterial
    case sessionReplayed
    case unknownKeyID
    // Restore failed for the key, so any session for it must be rejected.
    // This should never happen, it's a simple sense check against the upstream
    // key revocation path failing in some way
    case keyIDBlocked
}

typealias NodeKeyID = Data

struct SessionEntry {
    let nodeKeyID: NodeKeyID
    let sessionKey: SessionKey
}

/// Session store to keep track of requests CloudBoard has seen to prevent replay attacks that might allow an adversary
/// to exfiltrate sensitive information by replaying a request.
///
/// CloudBoard prevents this by expecting the 32-byte key  material provided by the client that is used to
/// derive a session key would be unique and high entropy (further that selecting a smaller subset of those
/// bytes will retain those characteristics subject to birthday collision limits).
/// See ``SessionKey`` documentation for the details
///
/// This store will reject new sessions identified by this key that are already present when attempted to be
/// added.
///
/// To prevent unbounded growth, sessions expire once the corresponding SEP-backed node key expires since
/// `cb_jobhelper` will reject any request that contain key material wrapped to an expired node key anyway
/// which allows us to safely remove the session from the store.
///
/// If there is a failure (including a catastrophic crash such as a jetsam controlled death) on reading a
/// session store on restart then the store will not block startup, instead it will require the associated key
/// is dropped.
final class SessionStore: Sendable {
    fileprivate static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "SessionStore"
    )

    private let stateMachine: Mutex<SessionStoreStateMachine> = .init(.init())
    private let attestationProvider: AttestationProvider
    private let metrics: MetricsSystem
    private let sessionStorage: Mutex<(any SessionStorage)?>

    private let eventStream: AsyncStream<SessionStoreEvent>
    private let eventContinuation: AsyncStream<SessionStoreEvent>.Continuation

    init(
        attestationProvider: AttestationProvider,
        metrics: MetricsSystem,
        sessionStorage: sending any SessionStorage,
    ) {
        self.attestationProvider = attestationProvider
        self.metrics = metrics
        self.sessionStorage = Mutex<(any SessionStorage)?>(sessionStorage)
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream()
    }

    func run() async throws {
        let validKeyIDs: [NodeKeyID] = try await self.attestationProvider.currentAttestationSet().validKeyIDs()
        let restoredSessions = self.sessionStorage.withLock {
            $0!.restoreSessions(
                validNodeKeyIDs: validKeyIDs
            )
        }
        // If the restore failed to recover a session then we need to invalidate it
        // therefore we require explicit positive success/failure indication
        var revocationList: [NodeKeyID] = []
        for keyID in validKeyIDs {
            guard let restored = restoredSessions[keyID] else {
                fatalError("""
                    SessionStorage failed to provide the state for *all* keys input: \(validKeyIDs.count) \
                    output: \(restoredSessions.count) \
                    example: \(keyID.base64EncodedString())
                """)
            }
            switch restored {
            case .failed:
                revocationList.append(keyID)
            case .success:
                // nothing to do yet, we update the initial state in one go
                ()
            }
        }
        if !revocationList.isEmpty {
            Self.logger.info("Initiating revocation of \(revocationList.count) keys.")
            try await self.attestationProvider.forceRevocation(keyIDs: revocationList)
        }
        self.stateMachine.withLock {
            $0.onRestoredSessions(restoredSessions)
        }
        Self.logger.info("Sessions restored.")
        for await event in self.eventStream {
            switch event {
            case .newSession(let sessionEntry):
                self.sessionStorage.withLock {
                    $0!.storeSession(sessionEntry)
                }
            case .expiredNodeKey(let nodeKeyID):
                self.sessionStorage.withLock {
                    $0!.removeSessions(of: nodeKeyID)
                }
            }
        }
        // This is not necessary in normal processing, but some complex unit tests
        // 'kill' the daemon, but complex retain references exist that hold the store open
        // this releases any locks associated with the storage, and also makes the store unusable
        // which is actually desirable if somehow the run loop stopped
        self.sessionStorage.withLock {
            $0 = nil
        }
        Self.logger.info("Session store run loop completed")
    }

    /// Convert an encrypted payload from the parameters (so the header of an OHTTP request)
    /// into a SessionKey.
    /// Exposed to make testing easier
    internal static func reduceToSessionKey(encryptedPayload: Data) throws -> SessionKey {
        // (see https://datatracker.ietf.org/doc/rfc9458/ Section 4.1)
        //    Encapsulated Request {
        //        Key Identifier (8),
        //        HPKE KEM ID (16),
        //        HPKE KDF ID (16),
        //        HPKE AEAD ID (16),
        //        Encapsulated KEM Shared Secret (8 * Nenc),
        //        HPKE-Protected Request (..),
        //      }

        // It is possible for a malicious _client_ to use different OHTTP key identifiers
        // to repeat the same request up to 256 times
        // Helpfully those are stored in the first byte and, since clients always use 0
        // we can just reject other inputs
        // This deliberately duplicates OHTTPClientStateMachine.defaultKeyID as the real client code
        // cannot reference that value, or easily change
        // Note: The use of the reduction to SessionKey below means this no longer matters,
        // but it's also desirable to check we are doing the right thing as, for now, the KeyID is not used
        guard encryptedPayload.count > 0, encryptedPayload[encryptedPayload.startIndex] == 0x00 else {
            // the encrypted payload was user input - so even though it's a pain we do not output it
            self.logger.error("encrypted payload does not start with 0x00")
            throw SessionError.invalidKeyMaterial
        }
        // Nenc is currently 32 bytes it may grow in future which is fine as any part would be acceptable
        let otherHeaders = 1 + 2 + 2 + 2
        // now in the KEM, but we want to be aligned
        let alignmentOffset = otherHeaders + 1
        let requiredLength = alignmentOffset + SessionKey.byteLength
        guard encryptedPayload.count >= requiredLength else {
            // the length of the encrypted payload is visible externally already
            Self.logger.error(
                "encrypted payload was not long enough \(encryptedPayload.count, privacy: .public)"
            )
            throw SessionError.invalidKeyMaterial
        }
        // Now reduce to a smaller subset that is still high entropy
        // We just index into the Encapsulated KEM Shared Secret which has sufficient entropy
        var buffer = ByteBuffer(data: encryptedPayload.dropFirst(alignmentOffset).suffix(SessionKey.byteLength))
        return try SessionKey(exactlyTheRightSize: &buffer)
    }

    /// exposed directly for tests
    internal func waitForInitialization() async {
        if let pendingInitialization = self.stateMachine.withLock({ $0.ensureInitialized() }) {
            Self.logger.debug("Waiting for session store initialization")
            await pendingInitialization.value
        }
    }

    func addSession(encryptedPayload: Data, keyID: NodeKeyID) async throws {
        await self.waitForInitialization()

        self.metrics.emit(Metrics.SessionStore.SessionAddedCounter(action: .increment))

        let sessionKey = try Self.reduceToSessionKey(encryptedPayload: encryptedPayload)
        let validKeyIDs = try await attestationProvider.currentAttestationSetWithTimeout().validKeyIDs()

        try self.stateMachine.withLock { state in
            let expired = state.removeExpiredKeys(validKeyIDs: validKeyIDs)
            for id in expired {
                self.eventContinuation.yield(.expiredNodeKey(id))
            }
            if !expired.isEmpty {
                self.metrics.emit(Metrics.SessionStore.StoredSessions(value: state.sessionCount))
            }

            // Ensure the key ID is known
            guard validKeyIDs.contains(keyID) else {
                Self.logger
                    .error("Did not find any attestation for key ID \(keyID.base64EncodedString(), privacy: .public)")
                throw SessionError.unknownKeyID
            }

            switch state.attemptInsert(nodeKeyID: keyID, sessionKey: sessionKey) {
            case .success:
                self.eventContinuation.yield(.newSession(.init(nodeKeyID: keyID, sessionKey: sessionKey)))
                self.metrics.emit(Metrics.SessionStore.StoredSessions(value: state.sessionCount))
            case .alreadyPresent:
                // the encrypted payload is already public and might help in diagnosis
                Self.logger
                    .error("Attempt to replay session key \(encryptedPayload.base64EncodedString(), privacy: .public)")
                self.metrics.emit(Metrics.SessionStore.SessionReplayedCounter(action: .increment))
                throw SessionError.sessionReplayed
            case .blocked:
                // this actually indicates a pretty weird state so not bothering to include a metric
                Self.logger.error("Attempt to insert blocked key ID \(keyID.base64EncodedString(), privacy: .public)")
                throw SessionError.keyIDBlocked
            }
        }
    }

    deinit {
        self.stateMachine.withLock { $0.cancel() }
    }
}

private struct SessionStoreStateMachine {
    private enum State {
        case initializing(Promise<Void, Never>)
        case initialized
    }

    enum InsertResult {
        case success
        case alreadyPresent
        case blocked
    }

    private var state = State.initializing(Promise())
    private var storedSessions = [NodeKeyID: Set<SessionKey>]()
    private var blockedSessions = Set<NodeKeyID>()

    mutating func attemptInsert(nodeKeyID: NodeKeyID, sessionKey: SessionKey) -> InsertResult {
        // likely case is we have it already
        guard var sessionSet = self.storedSessions[nodeKeyID] else {
            // this would start a new one then, so lets check if it was blocked
            // in theory the revocation should have kicked in, but this protects us against that failing
            // or some asynchronous state change failure
            guard !self.blockedSessions.contains(nodeKeyID) else {
                return .blocked
            }
            self.storedSessions[nodeKeyID] = Set<SessionKey>([sessionKey])
            return .success
        }
        let (wasNew, _) = sessionSet.insert(sessionKey)
        self.storedSessions[nodeKeyID] = sessionSet
        return wasNew ? .success : .alreadyPresent
    }

    /// Checks for any nodeKeyIDs not present in `validKeyIDs`, any found are removed, and returned
    mutating func removeExpiredKeys(validKeyIDs: [NodeKeyID]) -> [NodeKeyID] {
        var expiredKeys: [NodeKeyID] = []
        for keyID in self.storedSessions.keys {
            if !validKeyIDs.contains(keyID) {
                self.storedSessions.removeValue(forKey: keyID)
                expiredKeys.append(keyID)
            }
        }
        return expiredKeys
    }

    /// A count of all valid sessions across all active NodeKeyIDs
    var sessionCount: Int {
        self.storedSessions.reduce(into: 0) { currentValue, sessionSetPair in
            currentValue += sessionSetPair.value.count
        }
    }

    mutating func onRestoredSessions(_ restoredSessions: [NodeKeyID: RecoveredSessionState]) {
        switch self.state {
        case .initializing(let promise):
            // since this will happen once and only once we can just set them
            for (keyID, state) in restoredSessions {
                switch state {
                case .success(let sessionKeys):
                    self.storedSessions[keyID] = sessionKeys
                case .failed:
                    self.blockedSessions.insert(keyID)
                }
            }
            self.state = .initialized
            promise.succeed()
        case .initialized:
            preconditionFailure("Unexpected state: restored sessions received after initialization. Will ignore")
        }
    }

    func ensureInitialized() -> Future<Void, Never>? {
        switch self.state {
        case .initializing(let promise):
            return Future(promise)
        case .initialized:
            return nil
        }
    }

    func cancel() {
        switch self.state {
        case .initializing(let promise):
            promise.succeed()
        case .initialized:
            // no-op
            ()
        }
    }
}

private enum SessionStoreEvent {
    case newSession(SessionEntry)
    case expiredNodeKey(NodeKeyID)
}

extension TimeAmount {
    public var timeInterval: TimeInterval {
        return Double(self.nanoseconds) / 1_000_000_000
    }
}

extension SessionError: ReportableError {
    var publicDescription: String {
        switch self {
        case .invalidKeyMaterial:
            "invalidKeyMaterial"
        case .sessionReplayed:
            "sessionReplayed"
        case .unknownKeyID:
            "unknownKeyID"
        case .keyIDBlocked:
            "keyIDBlocked"
        }
    }
}

extension AttestationSet {
    func validKeyIDs() -> [NodeKeyID] {
        self.allAttestations.filter { $0.expiry > .now }.map { $0.keyID }
    }
}
