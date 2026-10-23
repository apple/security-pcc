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
import Logging
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Tracks cb_attestationd's readiness state and reports it to gRPC subscribers of
///  ``Proto_Attestation_AttestationProvider.watchStatus``.
///
/// The startup flow in ``CloudBoardAttestationServer`` and the rotation flow in ``KeyRotationService`` push
/// state changes here; the gRPC service implementation subscribes via ``watch()`` to stream them out to
/// cloudboardd.
final class AttestationDaemonStatusMonitor: Sendable {
    enum Status: Equatable, Sendable {
        case initializing(phase: String)
        case ready
        case degraded(reason: String)
        case transientError(message: String)
        case terminalError(message: String)
    }

    private struct State {
        var current: Status
        var watcherContinuations: [UUID: AsyncStream<Status>.Continuation]
    }

    private static let logger = Logger(label: "cb_attestationd.AttestationDaemonStatusMonitor")

    private let state: Mutex<State>

    init(initial: Status = .initializing(phase: "starting")) {
        self.state = Mutex(State(current: initial, watcherContinuations: [:]))
    }

    /// Replace the current status. Idempotent: no-ops if the new value equals the previous one.
    func update(_ status: Status) {
        let changed: Bool = self.state.withLock { state in
            guard state.current != status else { return false }
            state.current = status
            for continuation in state.watcherContinuations.values {
                continuation.yield(status)
            }
            return true
        }
        guard changed else { return }
        Self.logger.info("Daemon status updated", metadata: ["status": "\(status)"])
    }

    /// Returns an `AsyncStream` that yields the current status immediately, then yields
    /// every subsequent change until the subscriber drops the stream or the process exits.
    func watch() -> AsyncStream<Status> {
        let id = UUID()
        return AsyncStream { continuation in
            self.state.withLock { state in
                continuation.yield(state.current)
                state.watcherContinuations[id] = continuation
            }
            continuation.onTermination = { _ in
                self.state.withLock { _ = $0.watcherContinuations.removeValue(forKey: id) }
            }
        }
    }
}

extension AttestationDaemonStatusMonitor.Status {
    /// Encode as a `Proto_Attestation_AttestationDaemonStatus` for transmission over the
    /// ``Proto_Attestation_AttestationProvider.watchStatus`` stream.
    func toProto() -> Proto_Attestation_AttestationDaemonStatus {
        .with { status in
            switch self {
            case .initializing(let phase):
                status.initializing = .with { $0.phase = phase }
            case .ready:
                status.ready = .init()
            case .degraded(let reason):
                status.degraded = .with { $0.reason = reason }
            case .transientError(let message):
                status.transientError = .with { $0.message = message }
            case .terminalError(let message):
                status.terminalError = .with { $0.message = message }
            }
        }
    }

    /// Translates the outcome of an attempt to create an attested key from `generateWithRetry` into a status.
    ///
    /// Success -> `.ready`. Failure -> `.degraded` if a usable cached attestation remains,
    /// otherwise `.transientError`.
    init(forAttempt outcome: Result<Void, any Error>, hasUsableCachedKey: Bool) {
        switch outcome {
        case .success:
            self = .ready
        case .failure(let error):
            let reason = String(reportable: error)
            self =
                hasUsableCachedKey
                ? .degraded(reason: reason)
                : .transientError(message: reason)
        }
    }
}
