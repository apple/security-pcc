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
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import ServiceLifecycle
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

private let logger = Logger(label: "cloudboardd.CPAgentDrainSubscriber")

/// Subscribes to drain signals from the on-node control plane agent via a long-lived
/// gRPC bidirectional streaming RPC over a Unix Domain Socket.
///
/// On startup, opens the `Subscribe` stream and sends `DrainSubscribeRequest`.
/// When the server sends a `DrainSignal`, the subscriber:
///   1. Transitions to `.draining` — new requests are rejected.
///   2. Waits for all in-flight requests to finish, up to the grace period.
///      - If all requests finish in time: transitions to `.drained`, sends `DrainComplete`.
///      - If the grace period expires first: stays in `.draining` and does not send
///        `DrainComplete`.
///   3. In both cases, the process stays alive and waits for CP to terminate it.
///
/// Reconnects with exponential backoff if the stream drops before a drain signal is received.
final class CPAgentDrainSubscriber<Transport: ClientTransport>: Service, Sendable {

    private let statusMonitor: ServiceStatusMonitor
    private let configuration: CPAgentDrainSubscriberConfiguration
    private let transport: Transport

    init(
        transport: Transport,
        statusMonitor: ServiceStatusMonitor,
        configuration: CPAgentDrainSubscriberConfiguration
    ) {
        self.transport = transport
        self.statusMonitor = statusMonitor
        self.configuration = configuration
    }

    func run() async throws {
        do {
            try await withGRPCRetryLoop(
                transport: transport,
                initialBackoff: configuration.retryBackoffInitial,
                maxBackoff: configuration.retryBackoffMax,
                logger: logger
            ) { grpcClient in
                let client = Proto_Drain_DrainService.Client(wrapping: grpcClient)
                try await self.subscribeToDrainSignals(using: client)
            }
            // subscribeToDrainSignals() returns only when drain is complete (or grace period
            // expired).
            logger.info("Drain handling complete, waiting for ControlPlane to terminate")
            let exitContinuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    exitContinuation.withLock { $0 = continuation }
                    // Guard against the race where the task was already cancelled before
                    // the continuation was stored — onCancel won't fire in that case.
                    if Task.isCancelled {
                        exitContinuation.withLock {
                            $0?.resume()
                            $0 = nil
                        }
                    }
                }
            } onCancel: {
                exitContinuation.withLock {
                    $0?.resume()
                    $0 = nil
                }
            }
        } catch is CancellationError {
            logger.info("Cancelled")
        }
    }

    /// Opens the Subscribe stream and drives it to completion.
    ///
    /// Returns normally after a `DrainSignal` is received and the drain race concludes
    /// (either all in-flight requests finished, or the grace period expired).
    /// Throws if the stream ends unexpectedly before a drain signal, triggering reconnect.
    private func subscribeToDrainSignals(
        using client: Proto_Drain_DrainService.Client<Transport>
    ) async throws {
        let statusMonitor = self.statusMonitor

        // Channel: response handler forwards DrainSignal -> request producer does drain work.
        let (drainSignals, drainSignalContinuation) = AsyncStream<Proto_Drain_DrainSignal>.makeStream()

        try await client.subscribe(
            requestProducer: { writer in
                // 1. Register as a drain subscriber.
                try await writer.write(
                    Proto_Drain_DrainClientMessage.with {
                        $0.subscribe = Proto_Drain_DrainSubscribeRequest.with {
                            $0.clientName = "cloudboard"
                        }
                    }
                )
                logger.info("Subscribed to drain signals")

                // 2. Wait for the response handler to forward a DrainSignal.
                var drainSignalIterator = drainSignals.makeAsyncIterator()
                if let drainSignal = await drainSignalIterator.next() {
                    let gracePeriod = Duration.seconds(drainSignal.gracePeriodSeconds)
                    logger.info(
                        "Received drain signal, starting drain",
                        metadata: ["gracePeriodSeconds": "\(drainSignal.gracePeriodSeconds)"]
                    )

                    // 3. Race: in-flight requests finish vs. grace period expires.
                    let drainingFinished = await withTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            await statusMonitor.beginDraining()
                            return true  // in-flight requests finished
                        }
                        group.addTask {
                            try? await Task.sleep(for: gracePeriod)
                            return false  // grace period expired
                        }
                        let result = await group.next() ?? false
                        group.cancelAll()
                        return result
                    }

                    if drainingFinished {
                        // 4. All requests finished — complete drain and notify ControlPlane.
                        logger.info("All in-flight requests finished, completing drain")
                        statusMonitor.completeDrain()

                        try await writer.write(
                            Proto_Drain_DrainClientMessage.with {
                                $0.drainComplete = Proto_Drain_DrainComplete.with {
                                    $0.timestamp = .init(
                                        roundingTimeIntervalSince1970: Date.now.timeIntervalSince1970
                                    )
                                }
                            }
                        )
                        logger.info("Sent DrainComplete")
                    } else {
                        // Grace period expired — stay in .draining, let ControlPlane force-terminate.
                        logger.warning(
                            "Grace period expired before all in-flight requests finished, waiting for ControlPlane to terminate"
                        )
                    }
                } else {
                    // Stream closed without a drain signal — throw to trigger reconnect.
                    throw RPCError(code: .unavailable, message: "Subscribe stream closed without drain signal")
                }
            },
            onResponse: { response in
                defer { drainSignalContinuation.finish() }
                do {
                    for try await message in response.messages {
                        guard case .signal(let signal) = message.payload else {
                            logger.warning("Ignoring unknown server message")
                            continue
                        }
                        drainSignalContinuation.yield(signal)
                        // Do not break — keep reading until the server closes the stream.
                        // The server closes only after processing our DrainComplete, ensuring
                        // requestProducer is not cancelled before it can send DrainComplete.
                    }
                } catch {
                    logger.warning(
                        "Response stream ended with error",
                        metadata: ["error": "\(String(reportable: error))"]
                    )
                    throw error
                }
            }
        )
    }
}

extension CPAgentDrainSubscriber where Transport == HTTP2ClientTransport.Posix {
    /// Production initializer — builds the UDS transport from configuration.
    convenience init(
        statusMonitor: ServiceStatusMonitor,
        configuration: CPAgentDrainSubscriberConfiguration
    ) throws {
        let transport = try HTTP2ClientTransport.Posix.http2NIOPosix(
            target: .unixDomainSocket(path: configuration.socketPath),
            transportSecurity: .plaintext
        )
        self.init(transport: transport, statusMonitor: statusMonitor, configuration: configuration)
    }
}
