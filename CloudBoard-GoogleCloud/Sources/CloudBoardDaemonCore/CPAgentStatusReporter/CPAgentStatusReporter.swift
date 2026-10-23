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

import AsyncAlgorithms
import CloudBoardProtos
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import Metrics
import ServiceLifecycle

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private let logger = Logger(label: "cloudboardd.CPAgentStatusReporter")
private let heartbeatPublishCounter = Counter(label: "cloudboard_heartbeat_publish_total")

/// Reports cloudboardd component status to the on-node control plane agent via a long-lived
/// gRPC client-streaming RPC over a Unix Domain Socket.
///
/// Sends a full component tree snapshot whenever any component's state changes, and
/// re-sends the current snapshot at a fixed heartbeat interval so the agent can detect
/// a silent cloudboardd (distinct from one whose state simply hasn't changed).
///
/// Reconnects with exponential backoff if the RPC drops.
final class CPAgentStatusReporter<Transport: ClientTransport>: Service, Sendable {

    private let statusMonitor: ServiceStatusMonitor
    private let configuration: CPAgentStatusReporterConfiguration
    private let transport: Transport
    /// The time at which this reporter started, stable across reconnects.
    /// Changes on restart, allowing cp-agent to detect state resets.
    private let startTime: Date

    init(
        transport: Transport,
        statusMonitor: ServiceStatusMonitor,
        configuration: CPAgentStatusReporterConfiguration
    ) {
        self.transport = transport
        self.statusMonitor = statusMonitor
        self.configuration = configuration
        self.startTime = Date()
    }

    func run() async throws {
        do {
            try await withGRPCRetryLoop(
                transport: transport,
                initialBackoff: configuration.retryBackoffInitial,
                maxBackoff: configuration.retryBackoffMax,
                logger: logger
            ) { grpcClient in
                let client = Proto_CPAgentStatus_StatusReporter.Client(wrapping: grpcClient)
                try await self.streamStatusUpdates(using: client)
            }
            // streamStatusUpdates() returns only when the statusMonitor is terminated.
            logger.info("CPAgentStatusReporter: status monitor terminated, exiting")
        } catch is CancellationError {
            logger.info("CPAgentStatusReporter cancelled")
        }
    }

    private func streamStatusUpdates(
        using client: Proto_CPAgentStatus_StatusReporter.Client<Transport>
    ) async throws {
        let statusMonitor = self.statusMonitor
        let config = self.configuration
        let startTime = self.startTime

        _ = try await client.reportStatus { writer in
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Merge status changes and heartbeat ticks into a single stream.
                // nil = heartbeat tick, .some = status changed.
                let (events, continuation) = AsyncStream<ServiceStatusMonitor.Status?>.makeStream()

                // Forward status changes from the monitor.
                group.addTask {
                    for await status in statusMonitor.watch() {
                        continuation.yield(status)
                    }
                    // Monitor terminated — end the event stream.
                    continuation.finish()
                }

                // Emit a heartbeat tick on a fixed interval.
                // This task runs indefinitely; it exits only when cancelled by group.cancelAll()
                // after the event stream ends.
                group.addTask {
                    let timer = AsyncTimerSequence(
                        interval: config.heartbeatInterval,
                        clock: .continuous
                    )
                    for await _ in timer {
                        continuation.yield(nil)
                    }
                }

                var lastStatus: ServiceStatusMonitor.Status? = nil
                for await event in events {
                    if let newStatus = event {
                        lastStatus = newStatus
                    }
                    guard let status = lastStatus else {
                        // Heartbeat fired before we got the first status — skip.
                        continue
                    }
                    logger.debug(
                        "Sending status snapshot",
                        metadata: [
                            "trigger": event == nil ? "heartbeat" : "stateChange",
                            "state": "\(status.aggregateState)",
                        ]
                    )
                    if event == nil {
                        heartbeatPublishCounter.increment()
                    }
                    do {
                        try await writer.write(
                            Proto_CPAgentStatus_StatusReport(
                                from: status,
                                reporterIdentifier: "cloudboard",
                                reporterStartTime: startTime
                            )
                        )
                    } catch {
                        if event == nil {
                            Counter(
                                label: "cloudboard_heartbeat_publish_failed_total",
                                dimensions: [("errorDescription", String(reportable: error))]
                            ).increment()
                        }
                        throw error
                    }
                }

                // Event stream ended — cancel the heartbeat task.
                group.cancelAll()
            }
        }
    }
}

extension CPAgentStatusReporter where Transport == HTTP2ClientTransport.Posix {
    /// Production initializer — builds the UDS transport from configuration.
    convenience init(
        statusMonitor: ServiceStatusMonitor,
        configuration: CPAgentStatusReporterConfiguration
    ) throws {
        let transport = try HTTP2ClientTransport.Posix.http2NIOPosix(
            target: .unixDomainSocket(path: configuration.socketPath),
            transportSecurity: .plaintext
        )
        self.init(transport: transport, statusMonitor: statusMonitor, configuration: configuration)
    }
}

// MARK: - Proto mapping

extension Proto_CPAgentStatus_StatusReport {
    init(
        from status: ServiceStatusMonitor.Status,
        reporterIdentifier: String,
        reporterStartTime: Date,
        timestamp: Date = .now
    ) {
        self.init()
        self.timestamp = .init(roundingTimeIntervalSince1970: timestamp.timeIntervalSince1970)
        self.reporterIdentifier = reporterIdentifier
        self.reporterStartTime = .init(roundingTimeIntervalSince1970: reporterStartTime.timeIntervalSince1970)

        self.components =
            [.init(path: ["cloudboardd"], state: status.aggregateState)]
            + status.components.map { name, componentStatus in
                .init(path: ["cloudboardd", name], state: componentStatus)
            }
    }
}

extension Proto_CPAgentStatus_ComponentStatus {
    init(path: [String], state: ServiceStatusMonitor.State) {
        self.init()
        self.componentPath = path
        self.state = .init(state)
    }

    init(path: [String], state: ServiceStatusMonitor.ComponentStatus) {
        self.init()
        self.componentPath = path
        self.state = .init(state)
    }
}

extension Proto_CPAgentStatus_ComponentStatus.OneOf_State {
    init(_ state: ServiceStatusMonitor.State) {
        switch state {
        case .initializing(let phase):
            self = .initializing(.with { $0.phase = phase })
        case .ready:
            self = .ready(Proto_CPAgentStatus_Ready())
        case .degraded(let reason, _):
            self = .degraded(.with { $0.reason = reason })
        case .busy(let reason):
            self = .busy(.with { $0.reason = reason })
        case .transientError(let message):
            self = .transientError(.with { $0.message = message })
        case .terminalError(let message):
            self = .terminalError(.with { $0.message = message })
        case .draining:
            self = .draining(Proto_CPAgentStatus_Draining())
        case .drained:
            self = .drained(Proto_CPAgentStatus_Drained())
        }
    }

    init(_ status: ServiceStatusMonitor.ComponentStatus) {
        switch status {
        case .initializing(let phase):
            self = .initializing(.with { $0.phase = phase })
        case .ready:
            self = .ready(Proto_CPAgentStatus_Ready())
        case .degraded(let reason):
            self = .degraded(.with { $0.reason = reason })
        case .busy(let reason):
            self = .busy(.with { $0.reason = reason })
        case .transientError(let message):
            self = .transientError(.with { $0.message = message })
        case .terminalError(let message):
            self = .terminalError(.with { $0.message = message })
        }
    }
}
