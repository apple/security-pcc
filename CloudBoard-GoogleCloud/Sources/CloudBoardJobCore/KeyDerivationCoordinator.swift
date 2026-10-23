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

import CloudBoardProtos
import CloudBoardUtilities
import Crypto
import Logging
import ServiceLifecycle
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Error surfaced when a pending key derivation is abandoned because the request is tearing down,
/// when `cb_jobhelper` reports a derivation failure, or when the reply never arrives.
struct KeyDerivationError: ReportableError {
    let publicDescription: String
}

/// Supplies the current request id for log correlation.
///
/// Implemented by `CloudAppStateMachine`, whose `requestID` only becomes available once the
/// connection context arrives — after the coordinator is created — so it is read lazily rather than
/// captured up front.
package protocol RequestIDVendor: Sendable {
    var requestID: String? { get }
}

/// Per-request registry that correlates `deriveKey` calls with `cb_jobhelper`'s replies.
///
/// Each `deriveKey` allocates a `derivationID`, parks an `AsyncThrowingValueBox` keyed by that id,
/// and emits a `KeyDerivationRequest`. The reply is routed back through `resolve`, which wakes the
/// matching box. The coordinator is a `Service`: `run()` is started once for the lifetime of the
/// RPC and, when notified to exit via `shutdown(error:)` (or on cancellation), fails any still-pending
/// derivations so no `deriveKey` hangs past request teardown.
package final class KeyDerivationCoordinator: Service {
    private static let logger = Logger(label: "cloudapp.KeyDerivationCoordinator")

    /// Upper bound on how long a `deriveKey` waits for `cb_jobhelper` to reply before failing. A
    /// coarse safety net against a helper that crashes or never answers a given derivation id; a
    /// legitimate HKDF round-trip is effectively instantaneous.
    static let replyTimeout: Duration = .seconds(30)

    private let nextID = Atomic<UInt64>(0)
    private let pending = Mutex<[UInt64: AsyncThrowingValueBox<Data>]>([:])
    /// Write end of the response stream that carries `KeyDerivationRequest`s out to `cb_jobhelper`.
    private let derivationRequestsToJobHelper: AsyncStream<Proto_CloudApp_InvokeWorkloadResponse>.Continuation
    private let requestIDVendor: (any RequestIDVendor)?
    /// Clock used for the reply timeout. Injectable so tests can drive the timeout with a fake clock.
    private let clock: any Clock<Duration>

    /// Signals `run()` to return. Finished by `shutdown(error:)`.
    private let shutdownSignal: AsyncStream<Void>
    private let shutdownSignalContinuation: AsyncStream<Void>.Continuation
    private let shutdownError = Mutex<(any Error)?>(nil)

    package init(
        derivationRequestsToJobHelper: AsyncStream<Proto_CloudApp_InvokeWorkloadResponse>.Continuation,
        requestIDVendor: (any RequestIDVendor)? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.derivationRequestsToJobHelper = derivationRequestsToJobHelper
        self.requestIDVendor = requestIDVendor
        self.clock = clock
        (self.shutdownSignal, self.shutdownSignalContinuation) = AsyncStream.makeStream()
    }

    private var requestID: String {
        self.requestIDVendor?.requestID ?? "unavailable"
    }

    // MARK: Service lifecycle

    /// Runs for the lifetime of the RPC. Returns once `shutdown(error:)` is called or the enclosing
    /// task is cancelled, then fails every still-pending derivation so no `deriveKey` hangs past
    /// request teardown.
    package func run() async {
        for await _ in self.shutdownSignal {}
        self.failPendingDerivations(error: self.shutdownError.withLock { $0 } ?? CancellationError())
    }

    /// Notifies `run()` to exit, failing pending derivations with `error` (defaults to
    /// `CancellationError`). Safe to call more than once; the first error wins.
    package func shutdown(error: (any Error)? = nil) {
        self.shutdownError.withLock { stored in
            if stored == nil {
                stored = error
            }
        }
        self.shutdownSignalContinuation.finish()
    }

    // MARK: Derivation

    /// Requests a derived key from `cb_jobhelper` and suspends until the reply arrives.
    ///
    /// - Parameters:
    ///   - info: Un-prefixed adopter purpose. The `"dek-derived-key"` domain-separation prefix is
    ///     applied on the `cb_jobhelper` side.
    ///   - outputByteCount: Length of the derived key in bytes.
    /// - Throws: `CancellationError` if the calling task is cancelled, or a `KeyDerivationError` if
    ///   the request cannot be sent, `cb_jobhelper` reports a failure, or the reply times out.
    func deriveKey(info: String, outputByteCount: UInt32) async throws -> SymmetricKey {
        let derivationID = self.nextID.wrappingAdd(1, ordering: .relaxed).oldValue
        let box = AsyncThrowingValueBox<Data>()
        self.pending.withLock { $0[derivationID] = box }
        defer {
            self.pending.withLock { _ = $0.removeValue(forKey: derivationID) }
        }
        Self.logger.info(
            "Requesting key derivation from cb_jobhelper",
            metadata: [
                "requestID": "\(self.requestID)",
                "derivationID": "\(derivationID)",
                "outputByteCount": "\(outputByteCount)",
            ]
        )
        let yieldResult = self.derivationRequestsToJobHelper.yield(
            .with {
                $0.keyDerivationRequest = .with {
                    $0.derivationID = derivationID
                    $0.info = info
                    $0.outputByteCount = outputByteCount
                }
            }
        )
        switch yieldResult {
        case .enqueued:
            break
        case .terminated:
            throw KeyDerivationError(
                publicDescription: "cloud app RPC ended before the key-derivation request could be sent"
            )
        case .dropped:
            throw KeyDerivationError(publicDescription: "key-derivation request was dropped")
        @unknown default:
            // Reaching here means AsyncStream gained a YieldResult case we do not model — entirely
            // unexpected. Trap in debug so the gap is caught; still fail the derivation in release.
            assertionFailure("Unexpected AsyncStream.Continuation.YieldResult: \(yieldResult)")
            throw KeyDerivationError(publicDescription: "key-derivation request was not enqueued")
        }
        let derivedKey = try await self.awaitReply(box: box, derivationID: derivationID)
        return SymmetricKey(data: derivedKey)
    }

    /// Awaits the reply for `derivationID`, failing with a timeout if `cb_jobhelper` never answers.
    private func awaitReply(box: AsyncThrowingValueBox<Data>, derivationID: UInt64) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await box.get() }
            group.addTask { [clock = self.clock] in
                try await clock.sleep(for: Self.replyTimeout)
                throw KeyDerivationError(
                    publicDescription:
                        "cb_jobhelper did not reply to key derivation \(derivationID) within \(Self.replyTimeout)"
                )
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Result routed back from `cb_jobhelper`'s `KeyDerivationResult` reply.
    package enum Result: Sendable {
        case derivedKey(Data)
        case failure(String)
    }

    /// Routes a reply to the matching pending derivation and removes its registry entry. Unknown ids
    /// are a no-op (e.g. a reply that arrives after the caller was cancelled or timed out).
    package func resolve(derivationID: UInt64, result: Result) {
        let box = self.pending.withLock { $0.removeValue(forKey: derivationID) }
        guard let box else {
            Self.logger.debug(
                "Ignoring key derivation reply for unknown or already-resolved id",
                metadata: ["requestID": "\(self.requestID)", "derivationID": "\(derivationID)"]
            )
            return
        }
        switch result {
        case .derivedKey(let data):
            Self.logger.info(
                "Received derived key from cb_jobhelper",
                metadata: ["requestID": "\(self.requestID)", "derivationID": "\(derivationID)"]
            )
            box.put(data)
        case .failure(let message):
            let error = KeyDerivationError(publicDescription: message)
            Self.logger.error(
                "cb_jobhelper reported a key derivation failure",
                metadata: [
                    "requestID": "\(self.requestID)",
                    "derivationID": "\(derivationID)",
                    "error": "\(String(reportable: error))",
                ]
            )
            box.fail(error)
        }
    }

    /// Fails every pending derivation. Invoked by `run()` at shutdown so no `deriveKey` hangs.
    private func failPendingDerivations(error: any Error) {
        let boxes = self.pending.withLock { Array($0.values) }
        guard !boxes.isEmpty else {
            return
        }
        Self.logger.info(
            "Cancelling pending key derivations",
            metadata: [
                "requestID": "\(self.requestID)",
                "count": "\(boxes.count)",
                "error": "\(String(reportable: error))",
            ]
        )
        for box in boxes {
            box.fail(error)
        }
    }
}

extension KeyDerivationCoordinator: KeyDeriving {
    /// Derives a subordinate key from the request DEK held by `cb_jobhelper`. Suspends until the
    /// reply arrives.
    package func deriveKey(purpose: StaticString, outputByteCount: Int) async throws -> SymmetricKey {
        guard outputByteCount > 0, outputByteCount <= Int(UInt32.max) else {
            throw KeyDerivationError(
                publicDescription: "requested outputByteCount \(outputByteCount) is out of range (1...\(UInt32.max))"
            )
        }
        return try await self.deriveKey(
            info: String(describing: purpose),
            outputByteCount: UInt32(outputByteCount)
        )
    }
}
