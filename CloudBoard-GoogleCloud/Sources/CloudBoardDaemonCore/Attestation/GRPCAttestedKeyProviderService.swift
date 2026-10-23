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

import CloudBoardJobHelperCore
import CloudBoardProtos
import CloudBoardUtilities
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import Metrics
import ServiceLifecycle
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A ``Service`` that manages the gRPC client connection to cb_attestationd, populates a
/// ``GRPCAttestedKeyProvider`` with attestation updates, and drives the `attestation` subcomponent on
/// ``ServiceStatusMonitor`` from what it observes locally (connection state, cache freshness) and what
/// cb_attestationd reports about itself via ``Proto_Attestation_AttestationProvider/watchStatus``.
final class GRPCAttestedKeyProviderService: Service, Sendable {
    private static let logger = Logger(label: "cloudboardd.GRPCAttestedKeyProviderService")

    enum CacheState: Equatable, Sendable {
        case empty
        case fresh(currentExpiry: Date)
        case expired(currentExpiry: Date)
    }

    enum ConnectionState: Equatable, Sendable {
        case connecting
        case connected
        case reconnecting
    }

    /// Keeps track of all state that contributes to the attestation status that contributes to the overall system
    /// readiness/health.
    private struct StatusSignals {
        var cacheState: CacheState = .empty
        var connectionState: ConnectionState = .connecting
        var daemonReportedStatus: ServiceStatusMonitor.ComponentStatus?
        var lastPublishedStatus: ServiceStatusMonitor.ComponentStatus?
    }

    let provider: GRPCAttestedKeyProvider

    private let udsPath: String
    private let statusMonitor: ServiceStatusMonitor
    private let statusSignals: Mutex<StatusSignals>

    init(udsPath: String, provider: GRPCAttestedKeyProvider, statusMonitor: ServiceStatusMonitor) {
        self.udsPath = udsPath
        self.provider = provider
        self.statusMonitor = statusMonitor
        self.statusSignals = Mutex(StatusSignals())
    }

    func run() async throws {
        // Ensure the monitor reflects our initial view (connecting, empty cache, no daemon report yet)
        self.publishStatus()

        // Run the expiry watchdog separately from the reconnect loop. It's acceptable to be temporarily disconnected
        // from cb_attestationd as long as we have an active unexpired attestation.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.runExpiryWatchdog() }
            group.addTask { try await self.runReconnectLoop() }
            try await group.next()
            group.cancelAll()
        }
    }

    private func runReconnectLoop() async throws {
        var backoff = ExponentialBackoffStrategy(
            initialDelay: .milliseconds(100),
            multiplier: 2,
            maxDelay: .seconds(30),
            jitterPercent: 0
        )

        while true {
            do {
                try await withGRPCClient(
                    transport: .http2NIOPosix(
                        target: .unixDomainSocket(path: self.udsPath),
                        transportSecurity: .plaintext
                    )
                ) { client in
                    self.recordConnectionState(.connected)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await self.subscribeToAttestations(client: client) }
                        group.addTask { try await self.subscribeToStatus(client: client) }
                        // If either subscription completes (or throws), tear the other down so
                        // the reconnect loop can re-establish.
                        try await group.next()
                        group.cancelAll()
                    }
                    throw GRPCAttestedKeyProviderServiceError.attestationStreamEndedUnexpectedly
                }
            } catch is CancellationError {
                Self.logger.info("gRPC attestation provider service cancelled")
                return
            } catch {
                self.recordConnectionState(.reconnecting)
                // Drop any prior daemon-reported status — cb_attestationd may have restarted
                // and we should not gate readiness on what it told us before the gap.
                self.recordDaemonStatus(nil)
                Counter(
                    label: "cloudboard_attestation_stream_error_total",
                    dimensions: [("errorDescription", String(reportable: error))]
                ).increment()
                // Exponential backoff strategy does not make use of retryCount
                let delay = backoff.backoff(retryCount: 0)
                Self.logger.warning(
                    "Connection to cb_attestationd lost, will reconnect",
                    metadata: [
                        "uds": "\(self.udsPath)",
                        "backoff": "\(delay)",
                        "error": "\(String(reportable: error))",
                    ]
                )
                try await Task.sleep(for: delay)
                // Stay in `.reconnecting` between attempts
            }
        }
    }

    private func subscribeToAttestations<Transport: ClientTransport>(
        client: GRPCClient<Transport>
    ) async throws {
        let attestationClient = Proto_Attestation_AttestationProvider.Client(wrapping: client)

        Self.logger.info(
            "Subscribing to attestation updates from cb_attestationd",
            metadata: ["uds": "\(self.udsPath)"]
        )

        try await attestationClient.watchAttestations(.init()) { response in
            for try await message in response.messages {
                self.provider.updateFromProto(message)
                self.recordAttestation(currentExpiry: message.attestationSet.currentAttestation.expiry.date)
            }
        }
    }

    private func subscribeToStatus<Transport: ClientTransport>(
        client: GRPCClient<Transport>
    ) async throws {
        let attestationClient = Proto_Attestation_AttestationProvider.Client(wrapping: client)

        Self.logger.info(
            "Subscribing to daemon status updates from cb_attestationd",
            metadata: ["uds": "\(self.udsPath)"]
        )

        try await attestationClient.watchStatus(.init()) { response in
            for try await message in response.messages {
                let status = ServiceStatusMonitor.ComponentStatus(message.status)
                self.recordDaemonStatus(status)
            }
        }
    }

    /// Reclassifies `.fresh` -> `.expired` when the current attestation's effective expiry passes without a
    /// refresh arriving, so we transition into the error state as promptly as possible if a rotation never
    /// lands.
    private func runExpiryWatchdog() async throws {
        let idlePollInterval: Duration = .seconds(5)
        while !Task.isCancelled {
            let waitFor: Duration = self.statusSignals.withLock { signals in
                guard case .fresh(let expiry) = signals.cacheState else { return idlePollInterval }
                let interval = expiry.timeIntervalSinceNow
                return interval > 0 ? .seconds(interval) : .zero
            }
            // We never expect a newly added attestation to have an expiry earlier than the computed interval here.
            try await Task.sleep(for: waitFor)
            let transitioned: Bool = self.statusSignals.withLock { signals in
                guard case .fresh(let expiry) = signals.cacheState, expiry <= .now else {
                    return false
                }
                signals.cacheState = .expired(currentExpiry: expiry)
                return true
            }
            if transitioned {
                self.publishStatus()
            }
        }
    }

    func recordAttestation(currentExpiry: Date) {
        self.statusSignals.withLock { signals in
            signals.cacheState =
                currentExpiry > .now
                ? .fresh(currentExpiry: currentExpiry)
                : .expired(currentExpiry: currentExpiry)
        }
        self.publishStatus()
    }

    func recordDaemonStatus(_ status: ServiceStatusMonitor.ComponentStatus?) {
        self.statusSignals.withLock { signals in
            signals.daemonReportedStatus = status
        }
        self.publishStatus()
    }

    func recordConnectionState(_ newState: ConnectionState) {
        self.statusSignals.withLock { signals in
            signals.connectionState = newState
        }
        self.publishStatus()
    }

    private func publishStatus() {
        self.statusSignals.withLock { signals in
            let local = ServiceStatusMonitor.ComponentStatus(
                cacheState: signals.cacheState,
                connectionState: signals.connectionState
            )
            let merged = ServiceStatusMonitor.ComponentStatus(
                merging: local,
                with: signals.daemonReportedStatus
            )
            signals.lastPublishedStatus = merged
            self.statusMonitor.updateComponentState(
                name: ServiceStatusMonitor.ComponentName.attestation,
                status: merged
            )
        }
    }
}

extension ServiceStatusMonitor.ComponentStatus {
    /// Translates `Proto_Attestation_AttestationDaemonStatus` into the cloudboardd `ComponentStatus`
    /// taxonomy. Returns `nil` for an unset oneof (treated as "no daemon report yet" so it does not
    /// gate readiness).
    init?(_ proto: Proto_Attestation_AttestationDaemonStatus) {
        switch proto.kind {
        case .initializing(let phase):
            self = .initializing(phase: phase.phase)
        case .ready:
            self = .ready
        case .degraded(let degraded):
            self = .degraded(reason: degraded.reason)
        case .transientError(let error):
            self = .transientError(message: error.message)
        case .terminalError(let error):
            self = .terminalError(message: error.message)
        case nil:
            return nil
        }
    }

    /// Maps cloudboardd's local view (connection state + cache freshness) to the `ComponentStatus`
    /// the rest of the system consumes.
    init(
        cacheState: GRPCAttestedKeyProviderService.CacheState,
        connectionState: GRPCAttestedKeyProviderService.ConnectionState
    ) {
        switch (cacheState, connectionState) {
        case (.empty, .connecting):
            self = .initializing(phase: "awaiting cb_attestationd connection")
        case (.empty, .connected):
            self = .initializing(phase: "awaiting attestation set from cb_attestationd")
        case (.empty, .reconnecting):
            self = .transientError(message: "cb_attestationd unavailable; no attestation set received")
        case (.fresh, .connecting), (.fresh, .connected):
            self = .ready
        case (.fresh, .reconnecting):
            self = .degraded(reason: "reconnecting to cb_attestationd")
        case (.expired, .connecting), (.expired, .connected):
            self = .transientError(message: "current attestation expired; awaiting refresh")
        case (.expired, .reconnecting):
            self = .transientError(message: "current attestation expired; cb_attestationd unavailable")
        }
    }

    /// Fuses the cloudboardd-observed signal with cb_attestationd's self-reported status by picking
    /// the worst-severity outcome, using the same severity ordering that
    /// `ServiceStatusMonitor.aggregateState` applies across subcomponents.
    ///
    /// When cb_attestationd has not yet reported its own status (either because the gRPC
    /// connection has never delivered a `WatchStatus` message, or because we just reconnected
    /// after a drop and dropped the prior value as stale), we refuse to claim full readiness:
    /// otherwise an immediately-after-reconnect window would publish `.ready` before the daemon
    /// has confirmed it's actually serving. We downgrade to `.degraded` in that case so
    /// readiness only takes effect once both signals agree.
    ///
    /// When cb_attestationd reports `.initializing` (e.g. it has just restarted and is
    /// regenerating its initial key) but our local view shows a usable cached attestation
    /// (`.ready` or `.degraded` — both imply a `.fresh` cache), we keep serving from the cache
    /// rather than degrading further to `.initializing`.
    init(merging local: Self, with daemonReported: Self?) {
        guard let daemonReported else {
            if case .ready = local {
                self = .degraded(reason: "awaiting status from cb_attestationd")
            } else {
                self = local
            }
            return
        }
        if case .initializing = daemonReported, local.severity <= Self.degradedSeverity {
            self = .degraded(reason: "cb_attestationd reinitializing")
            return
        }
        self = daemonReported.severity > local.severity ? daemonReported : local
    }

    /// Severity of `.degraded`, named so the merge logic above can compare without spelling
    /// the magic number inline.
    private static var degradedSeverity: Int { Self.degraded(reason: "").severity }

    /// Mirrors `ServiceStatusMonitor.aggregateState`'s severity ordering:
    /// `terminalError > transientError > busy > initializing > degraded > ready`.
    var severity: Int {
        switch self {
        case .ready: return 0
        case .degraded: return 1
        case .initializing: return 2
        case .busy: return 3
        case .transientError: return 4
        case .terminalError: return 5
        }
    }
}

enum GRPCAttestedKeyProviderServiceError: Error, ReportableError {
    case attestationStreamEndedUnexpectedly

    var publicDescription: String {
        switch self {
        case .attestationStreamEndedUnexpectedly:
            "attestationStreamEndedUnexpectedly"
        }
    }
}
