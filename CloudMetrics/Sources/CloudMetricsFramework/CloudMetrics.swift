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
//  CloudMetrics.swift
//  CloudMetricsFramework
//
//  Created by Andrea Guzzo on 8/30/23.
//

internal import CloudMetricsConstants
private import CloudMetricsUtils
internal import CloudMetricsXPC
import Foundation
import os

/// CloudMetrics allows cloudOS applications to report metrics to a centralised metrics collector.
///
/// It is heavily-based upon [SwiftMetrics](https://github.com/apple/swift-metrics).
/// Adopter applications should initialise CloudMetrics early on in their application's startup phase.
/// Usually it is run precisely once for the entire lifetime of the application.
///
/// Libraries should typically not directly run CloudMetrics.
///
/// ```
/// try CloudMetrics.bootstrapForAsync()
/// try await withThrowingTaskGroup(of: Void.self) { group in
///    group.addTask {
///        try await CloudMetrics.run()
///    }
///    group.addTask {
///        try await myApplication.run()
///    }
///    try await group.next()
///    try await CloudMetrics.shutdown() // Nb consider group.next() throwing in production code.
/// }
/// ```
public final class CloudMetrics: Sendable {
    /// Track the state of ``CloudMetrics``.
    ///
    /// We expect to only ever go `nonBootstrapped`->`bootstrapping`->`bootstrapped`->`shuttingDown`->`shutdown`
    fileprivate enum State {
        case nonBootstrapped
        case bootstrapped(CloudMetricsFactory, AsyncStream<CloudMetricsServiceMessages>)
        case running(CloudMetricsFactory)
        case shuttingDown(Promise<Void, Error>)
        case shutdown
    }

    private static let debugMetricPrefixes: OSAllocatedUnfairLock<[String]?> = .init(initialState: nil)
    private static let state: OSAllocatedUnfairLock<State> = .init(initialState: .nonBootstrapped)
    // If cloudmetricsd isn't correctly configured and listening we can buffer requests in an async stream.
    // We don't want this to grow unbounded and crash the process linking CloudMetricsFramework.
    private static let defaultMaxMetricUpdatesToBuffer = 10000
    private static let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "CloudMetricsFramework")

    @available(*, deprecated, renamed: "CloudMetrics.run()", message: "Prefer calling async method CloudMetrics.run()")
    public static func bootstrap(clientName _: String) {
        self.bootstrap()
    }

    /// Initialise ``CloudMetrics`` as a global metrics handler.
    ///
    /// This should be called by applications precisely once to register ``CloudMetrics`` as a global metrics handler.
    ///
    /// Applications that call ``bootstrap()`` are encouraged to call ``invalidate()`` as part of their
    /// shutdown to flush metrics to the backend. If applcations omit that call, metrics will be flushed when the
    /// application
    /// exits.
    public static func bootstrap() {
        self.bootstrap(xpcServiceName: kCloudMetricsXPCServiceName, bootstrapInternal: false)
        atexit {
            CloudMetrics.invalidate()
        }
    }

    /// Package-scoped function for testing.
    package static func bootstrap(xpcServiceName: String, bootstrapInternal: Bool) {
        self.logger.log("CloudMetrics beginning bootstrap")
        do {
            try self.bootstrapForAsync()
        } catch {
            self.logger.critical("Bootstrapping failed. Unable to start metrics")
            return
        }
        // Need an unstructured task here for backwards compatibility.
        // Existing clients are calling .bootstrap and we don't want to break them by forcing them to call .run()
        Task {
            // Run the service. This won't return until the service is shutdown
            try await Self.run(
                xpcServiceName: xpcServiceName,
                bootstrapInternal: bootstrapInternal
            )
        }
    }

    public static func bootstrapForAsync() throws {
        try self.bootstrapForAsync(bootstrapInternal: false)
    }

    package static func bootstrapForAsync(bootstrapInternal: Bool) throws {
        var validPreference: DarwinBoolean = true
        var maxUpdatesToBuffer: Int = CFPreferencesGetAppIntegerValue(
            "maxCloudMetricsUpdatesToBuffer" as CFString,
            kCFPreferencesCurrentApplication,
            &validPreference
        )
        if !validPreference.boolValue {
            maxUpdatesToBuffer = Self.defaultMaxMetricUpdatesToBuffer
        }

        // Setup the factory's dependencies.
        // We need an ``AsyncStream`` from which we will receive updates from the sync world
        // and an XPC client with which we will communicate with the daemon.
        self.logger.log("Beginning bootstrap of CloudMetrics")
        try self.state.withLock { state in
            switch (state, bootstrapInternal) {
            case (.nonBootstrapped, _), (_, true):
                let (metricUpdateStream, metricUpdateContinuation) = AsyncStream<CloudMetricsServiceMessages>
                    .makeStream(
                        bufferingPolicy: .bufferingOldest(maxUpdatesToBuffer)
                    )
                let factory = CloudMetricsFactory(metricUpdateContinuation: metricUpdateContinuation)
                if bootstrapInternal {
                    MetricsSystem.bootstrapInternal(factory)
                } else {
                    MetricsSystem.bootstrap(factory)
                }
                state = .bootstrapped(factory, metricUpdateStream)
            default:
                self.logger.error("Bootstrap called twice")
                throw CloudMetricsError.bootstrapCalledTwice
            }
        }
    }

    /// Run the global CloudMetrics provider.
    ///
    /// This function will initialise and run the global ``CloudMetrics`` system, sending metrics to `cloudmetricsd`.
    /// `cloudmetricsd` is then expected to forward the metrics to a metric aggregator.
    ///
    /// This function will usually be called during an application startup as a task in a `TaskGroup`.
    ///
    /// - Returns: When ``CloudMetrics`` has been shutdown.
    ///
    /// - SeeAlso: ``shutdown()`` for shutting down CloudMetrics.

    public static func run() async throws {
        do {
            try await self.run(xpcServiceName: kCloudMetricsXPCServiceName, bootstrapInternal: false)
        } catch {
            self.logger.error("Unexpected error running CloudMetricsFramework. error=\(error, privacy: .private)")
            throw error
        }
    }

    package static func run(
        xpcServiceName: String = kCloudMetricsXPCServiceName,
        bootstrapInternal _: Bool = false
    ) async throws {
        let metricUpdateStream = try self.state.withLock { state in
            switch state {
            case .nonBootstrapped: throw CloudMetricsError.bootstrapNotCalled
            case .bootstrapped(let factory, let metricUpdateStream):
                state = .running(factory)
                return metricUpdateStream
            default: throw CloudMetricsError.invalidLifecycle
            }
        }

        Self.logger.log("""
        Initialising CloudMetrics XPC client. \
        xpc_service_name=\(xpcServiceName, privacy: .public)
        """)
        let xpcClient = CloudMetricsXPCClient(xpcServiceName: xpcServiceName)

        // When the factory finishes, adjust our state to reflect we're now shutdown.
        defer {
            self.state.withLock { state in
                switch state {
                case .shuttingDown(let promise):
                    promise.succeed()
                default: break
                }
                state = .shutdown
            }
            Self.logger.log("CloudMetricsFramework shutdown")
        }
        Self.logger.log("CloudMetrics running")
        // asyncMetricDispatcher.run() returns when its asyncStream is finished
        let asyncMetricDispatcher = AsyncMetricDispatcher(xpcClient: xpcClient, metricUpdateStream: metricUpdateStream)
        try await asyncMetricDispatcher.run()

        // disconnect the xpc client so cloudmetricsd doesnt keep emitting last known value
        try await xpcClient.disconnect()
    }

    public static func invalidate() {
        // Backwards compatibility for sync-based API.
        Task {
            await Self.shutdown()
        }
    }

    /// Shutdown the global CloudMetrics backend
    ///
    /// Adopters should call ``shutdown()`` as part of their application's shutdown routine.
    ///
    /// When this is called any already-executed metric changes (e.g. counter increments) will be processed. But any
    /// future
    /// changes will not be executed.
    public static func shutdown() async {
        self.logger.log("Beginning shutdown of CloudMetrics")
        let shutdownFuture = Self.state.withLock { state in
            let future: Future<Void, Error>?
            switch state {
            case .nonBootstrapped:
                self.logger.error("CloudMetrics.shutdown called without having called CloudMetrics.run.")
                // Still shutdown the client.
                state = .shutdown
                future = nil
            case .bootstrapped:
                self.logger.warning("CloudMetrics shutdown without having been run")
                state = .shutdown
                future = nil
            case .running(let factory):
                // Finish the continuation to start the process of shutting down the client
                factory.metricUpdateContinuation.finish()
                let promise = Promise<Void, Error>()
                state = .shuttingDown(promise)
                future = .init(promise)
            case .shuttingDown(let promise):
                self.logger.log("CloudMetrics.shutdown called whilst already shutting down.")
                future = .init(promise)
            case .shutdown:
                // Might not be an error: some users call `invalidate()` themselves and others rely on the `atExit`
                // hook.
                self.logger.log("CloudMetrics.shutdown called when already shutdown.")
                future = nil
            }
            return future
        }
        do {
            self.logger.log("Waiting for CloudMetrics to finish shutdown")
            try await shutdownFuture?.valueWithCancellation
        } catch {
            self.logger.error("Error occurred during CloudMetrics shutdown")
        }
    }

    internal static var sharedFactory: CloudMetricsFactory? {
        state.withLock { state in
            switch state {
            case .bootstrapped(let factory, _):
                return factory
            case .running(let factory):
                return factory
            default:
                logger.log("CloudMetrics not in bootstrapped state")
                return nil
            }
        }
    }

    public static func debugMetricPrefixArray() -> [String] {
        self.debugMetricPrefixes.withLock { debugMetricPrefixes in
            if debugMetricPrefixes == nil {
                if let defaults = UserDefaults(suiteName: kCloudMetricsPreferenceDomain) {
                    let prefixes = defaults.stringArray(forKey: "DebugMetricPrefixes") ?? []
                    debugMetricPrefixes = prefixes
                    return prefixes
                }
            }
            return debugMetricPrefixes ?? []
        }
    }
}
