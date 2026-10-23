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

//
//  Daemon.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 02/12/2024.
//

#if canImport(cloudOSInfo)
@_weakLinked private import cloudOSInfo
#endif
#if canImport(EnsembleTransport)
@preconcurrency @_weakLinked private import EnsembleTransport
#endif
private import EnsembleWardenCommon
package import EnsembleWardenServer
private import EnsembleWardenXPC
private import Foundation
private import os
@preconcurrency package import XPC

/// Daemon that ensures sensitive assets, such as KV-caches, that are
/// transfered between ensembles are encrypted using application-level
/// cryptography.
///
/// This ensures that only legimitate stacks that have the required keys can
/// decrypt the sensitive data.
package final class EnsembleWardenDaemon<Factory: MetricsFactory, Transport: EnsembleTransportProviding>: Sendable {

    private enum State {
        case stopped
        case starting
        case running(CheckedContinuation<(), Never>)
        case shuttingDown
    }

    private let server: EnsembleWardenServerImplementation<DaemonHandler<Transport, Factory>, Factory>
    /// Stream that has requests for us to initiate a shutdown.
    private let shutdownRequestStream: AsyncStream<Void>

    private let logger = Logger(subsystem: "com.apple.cloudos.ensemblewardend", category: "Daemon")
    private let state: OSAllocatedUnfairLock<State> = .init(initialState: .stopped)
    private let ensembleWardenMetrics: EnsembleWardenMetrics<Factory>

    package init(ensembleWardenServerXPCServiceName: String = kEnsembleWardenAPIXPCLocalServiceName,
                 metricsFactory: Factory,
                 transportProvider: Transport) throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.shutdownRequestStream = stream
        self.ensembleWardenMetrics = EnsembleWardenMetrics(metricsFactory: metricsFactory)
        self.server = .init(
            handler: DaemonHandler(
                shutdownInitiateContinuation: continuation,
                transportProvider: transportProvider,
                metrics: self.ensembleWardenMetrics),
            xpcServiceName: ensembleWardenServerXPCServiceName,
            entitlement: kEnsembleWardenClientEntitlement,
            metricsFactory: metricsFactory)
    }
}

extension EnsembleWardenDaemon where Transport == EnsembleTransportBackend {
    package static func make() throws -> EnsembleWardenDaemon<OSMetricsBridge, EnsembleTransportBackend> {
#if canImport(EnsembleTransport)
        let transportClient: EnsembleTransportClient? =
            if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
                try EnsembleTransportClient()
            } else {
                nil
            }
        return try .init(metricsFactory: OSMetricsBridge(), transportProvider: EnsembleTransportBackend(client: transportClient))
#else
        return try .init(metricsFactory: OSMetricsBridge(), transportProvider: EnsembleTransportBackend())
#endif
    }
}

extension EnsembleWardenDaemon {
    /// Waits for the daemon's XPC server to be running (ready to accept connections).
    ///
    /// Used in tests since we don't have the launchd magic there.
    package func waitForRunning() async {
        await server.waitForRunning()
    }

    private var cloudOSBuildVersion: String {
#if canImport(cloudOSInfo)
        let cloudOSBuildVersion: String

        if #_hasSymbol(CloudOSInfoProvider.self) {
            cloudOSBuildVersion = (try? CloudOSInfoProvider().cloudOSBuildVersion()) ?? "<UNKNOWN>"
        } else {
            cloudOSBuildVersion = "<UNKNOWN>"
        }
        return cloudOSBuildVersion
#else
        return "<UNKNOWN>"
#endif
    }

    package func run(xpcServiceName: String = kEnsembleWardenAPIXPCLocalServiceName) async throws {
        try await self.startDaemon {
            try await self.server.run()
        }
    }

    /// Identical to ``run(xpcServiceName:)`` but uses an anonymous XPC listener.
    ///
    /// The resulting `XPCEndpoint` is vended via `endpointHandler` before blocking.
    /// Intended for use in tests where launchd registration is unavailable.
    package func runAnonymous(endpointHandler: @escaping @Sendable (XPCEndpoint) -> Void) async throws {
        try await self.startDaemon {
            try await self.server.runAnonymous(endpointHandler: endpointHandler)
        }
    }

    /// Shared daemon lifecycle: starts the server task, shutdown watcher, uptime recorder,
    /// and a continuation that blocks until shutdown is requested.
    private func startDaemon(serverTask: @escaping @Sendable () async throws -> Void) async throws {
        let start = Date()
        try self.state.withLock { state in
            switch state {
            case .stopped:
                state = .starting
            default:
                logger.error("Tried to run EnsembleWarden daemon when not stopped")
                throw EnsembleWardenError.invalidStateTransition
            }
            state = .starting
        }
        defer {
            self.state.withLock { $0 = .stopped }
            logger.log("Shutdown EnsembleWarden daemon")
        }

        self.logger.log("""
            Starting EnsembleWarden daemon. \
            cloudos_version=\(self.cloudOSBuildVersion, privacy: .public)
            """)

        self.ensembleWardenMetrics.daemonLaunchTotalCount.increment(by: 1)

        try await withThrowingTaskGroup(of: Void.self) { group in
            // XPC Server
            group.addTask {
                try await serverTask()
            }

            // Tasks that will trigger a shutdown if we request ourselves to go away
            group.addTask {
                self.logger.log("Starting shutdown request watcher")
                defer {
                    self.logger.log("Stopped shutdown request watcher")
                }
                for try await _ in self.shutdownRequestStream {
                    self.logger.log("Shutdown request")
                    defer {
                        self.logger.log("Completed shutdown request")
                    }
                    do {
                        try self.shutdown()
                    } catch {
                        self.logger.log("Error shutting down. error=\(String(reportable: error), privacy: .public)")
                    }
                }
            }

            // Tasks that will trigger for current uptime to be calculated
            group.addTask {
                while !Task.isCancelled {
                    let timeSince = Date().timeIntervalSince(start)
                    self.ensembleWardenMetrics.daemonUptime.record(timeSince*1000)
                    // Sleeping for 10 seconds between uptime recordings
                    try await Task.sleep(for: .seconds(10))
                }
            }


            // Await shutdown
            group.addTask(priority: .background) {
                await withTaskCancellationHandler(operation: {
                    await withCheckedContinuation { continuation in
                        self.state.withLock { $0 = .running(continuation) }
                    }
                }, onCancel: {
                    try? self.shutdown()
                })
            }

            defer {
                group.cancelAll()
            }
            try await group.next()
        }
    }

    package func shutdown() throws {
        logger.log("Shutting down")
        let continuation: CheckedContinuation? = try self.state.withLock { state in
            switch state {
            case .running(let continuation):
                state = .shuttingDown
                return continuation
            case .shuttingDown, .stopped:
                return nil
            default: throw EnsembleWardenError.invalidStateTransition
            }
        }
        continuation?.resume()
    }
}

