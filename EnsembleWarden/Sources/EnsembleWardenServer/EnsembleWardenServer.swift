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

//
//  EnsembleWardenServer.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 20/01/2025.
//

private import EnsembleWardenCommon
private import os
private import Synchronization
@preconcurrency private import XPC

/// Receives messages from EnsembleWarden
///
/// When EnsembleWarden runs it receives ioSurfaces which it encrypts and passes on.
/// It passes it onto an adopter who has provided an EnsembleWardenServer.
/// Adopters must provide a ``EnsembleWardenServerHandler`` defining the callbacks
/// to run.
public final class EnsembleWardenServer<Handler: EnsembleWardenServerHandler & Sendable>: Sendable {

    private let serverImplementation: EnsembleWardenServerImplementation<Handler, OSMetricsBridge>

        public init(handler: Handler, xpcServiceName: String) {
            self.serverImplementation = EnsembleWardenServerImplementation<Handler, OSMetricsBridge>.init(handler: handler, xpcServiceName: xpcServiceName, metricsFactory: OSMetricsBridge())
        }

        public func run() async throws {
            try await self.serverImplementation.run()
        }

        package func waitForRunning() async {
            await self.serverImplementation.waitForRunning()
        }

        public func shutdown() throws {
            try self.serverImplementation.shutdown()
        }
}

package final class EnsembleWardenServerImplementation<Handler: EnsembleWardenServerHandler & Sendable, Factory: MetricsFactory>: Sendable {
    private enum State {
        /// Continuations will be resumed when the server is running.
        case notStarted([CheckedContinuation<Void, Never>])
        /// Continuations will be resumed when the server is running.
        case starting([CheckedContinuation<Void, Never>])
        /// Continuations will be resumed when the server is stopped.
        case running(CheckedContinuation<Void, Never>)
        case stopped
    }

    private let handler: Handler
    private let ensembleWardenMetrics: EnsembleWardenMetrics<Factory>
    private let xpcServiceName: String
    private let entitlement: String

    private let state = Mutex<State>(.notStarted([]))
    private let logger = Logger(subsystem: "com.apple.cloudos.ensemblewardenserver", category: "Server")


    /// Creates an instance.
    /// - Parameters:
    ///   - handler: The callbacks to run when messages are received.
    ///   - xpcServiceName: The name of the XPC service to listen on.
    /// - SeeAlso: ``run()``, which needs to be called after initialisation.
    package init(handler: Handler, xpcServiceName: String, metricsFactory: Factory) {
        self.handler = handler
        self.xpcServiceName = xpcServiceName
        // Entitlement here is the entitlement that is required to talk ensemblewardend->tie-kvcache-transfer.
        // It is not overridable in the public initialiser.
        self.entitlement = kEnsembleWardenServerEntitlement
        self.ensembleWardenMetrics = EnsembleWardenMetrics(metricsFactory: metricsFactory)
    }

    // In our package-scoped init we allow specifying an entitlement to check.
    // Reason being that this initialiser is used from ensemblewardend. We want
    // that to check for a different entitlement to we check when we're running
    // in tie-kvcache-transfer. This is because we want tie-cloud-app to not
    // have entitlements to direct-talk to tie-kvcache-transfer.
    package init(handler: Handler, xpcServiceName: String, entitlement: String, metricsFactory: Factory) {
        self.handler = handler
        self.xpcServiceName = xpcServiceName
        self.entitlement = entitlement
        self.ensembleWardenMetrics = EnsembleWardenMetrics(metricsFactory: metricsFactory)
    }

    /// Waits for the server to be running (XPC listener ready to accept connections).
    ///
    /// Used in tests since we don't have the launchd magic there.
    package func waitForRunning() async {
        await withCheckedContinuation { continuation in
            self.state.withLock { state in
                switch state {
                case .notStarted(var continuations):
                    continuations.append(continuation)
                    state = .notStarted(continuations)
                case .starting(var continuations):
                    continuations.append(continuation)
                    state = .starting(continuations)
                case .running:
                    continuation.resume()
                case .stopped:
                    self.logger.warning("waitForRunning() called but the server already stopped")
                    continuation.resume()
                }
            }
        }
    }

    /// Performs the necessary steps to start listening for XPC requests.
    package func run() async throws {
        try self.state.withLock { state in
            switch state {
            case .notStarted(let continuations):
                state = .starting(continuations)
            default:
                throw EnsembleWardenError.invalidStateTransition
            }
        }
        defer {
            self.state.withLock { $0 = .stopped }
        }
        let listener = try XPCListener(
            service: xpcServiceName,
            targetQueue: .init(label: "com.apple.cloudos.ensemblewarden.xpcserver", qos: .userInitiated),
            requirement: .hasEntitlement(self.entitlement),
        ) { request in
            return request.accept { _ in
                XPCHandler(ensembleWardenHandler: self.handler,
                           ensembleWardenMetrics: self.ensembleWardenMetrics)
            }
        }
        await withThrowingTaskGroup(of: Void.self) { group in
            // Wait for shutdown
            group.addTask {
                await withTaskCancellationHandler(operation: {
                    await withCheckedContinuation { continuation in
                        let waitingContinuations = self.state.withLock { state -> [CheckedContinuation<Void, Never>] in
                            let waiting: [CheckedContinuation<Void, Never>]
                            switch state {
                            case .notStarted(let continuations):
                                assertionFailure("Should not be in not-started state")
                                waiting = continuations
                            case .starting(let continuations):
                                waiting = continuations
                            case .running:
                                waiting = []
                            case .stopped:
                                assertionFailure("Should not be in stopped state")
                                waiting = []
                            }
                            state = .running(continuation)
                            return waiting
                        }
                        // Resume all waiting continuations now that we're running
                        waitingContinuations.forEach { $0.resume() }
                        // Need to make sure to retain the listener so it doesn't get
                        // deallocated before it can accept connections.
                        withExtendedLifetime(listener) {}
                    }
                }, onCancel: {
                    try? self.shutdown()
                })
            }
        }
        listener.cancel()
    }

    /// Performs the necessary steps to shutdown the server.
    package func shutdown() throws {
        logger.log("Shutting down server")
        try self.state.withLock { state in
            switch state {
            case .running(let continuation):
                continuation.resume()
            default: throw EnsembleWardenError.invalidStateTransition
            }
        }
    }
}
