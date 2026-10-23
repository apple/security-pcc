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
//  CloudMetericsXPCClient.swift
//  
//
//  Created by Andrea Guzzo on 8/24/22.
//

internal import CloudMetricsConstants
private import CloudMetricsUtils
private import CloudMetricsAsyncXPC
import Foundation
import os

package enum CloudMetricsXPCClientError: Error {
    case internalError(String)
    case xpcError(String)
    case apiMisuse(String)
}

extension CloudMetricsXPCClientError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .internalError(let message):
            return "Internal Error: \(message)."
        case .xpcError(let message):
            return "XPC Error: \(message)."
        case .apiMisuse(let message):
            return "API misuse \(message)."
        }
    }
}

package actor CloudMetricsXPCClient: Sendable {

    /// We need to track connection state since our connection to the daemon has application-layer state.
    ///
    /// In particular consider the case of the XPC connection being interrupted. When this happens you are supposed
    /// to reuse the connection later on (and the magic of launchd will create a new daemon) but when you do connect
    /// again you need to send a configuration message again. We therefore need to know where we are in the lifecycle
    /// of the XPC connection and thus need this state enum.
    fileprivate enum ConnectionState: Sendable {
        case disconnected
        /// Contains a promise that we will fire when we are connected.
        case connecting(Promise<CloudMetricsAsyncXPCConnection, CloudMetricsXPCError>)
        case connected(CloudMetricsAsyncXPCConnection)
        /// If daemon crashes or gets jetsammed our connection will be interrupted. 
        ///
        /// When this happen we need to resend the ``CloudMetricsServiceMessages.SetConiguration`` message
        /// as the previous state will be lost
        case interrupted(CloudMetricsAsyncXPCConnection)
        /// After being interrupted we need to reconfigure the backend by sending a configuration.
        case reconfiguring(CloudMetricsAsyncXPCConnection, Promise<CloudMetricsAsyncXPCConnection, CloudMetricsXPCError>)
        case disconnecting

        fileprivate var isDisconnected: Bool {
            switch self {
            case .disconnected: true
            default: false
            }
        }
    }

    private var connectionState: ConnectionState = .disconnected
    private var configurationMessage: CloudMetricsServiceMessages.SetConfiguration?
    private var unallowedMetricLogTracker: [String: ContinuousClock.Instant] = [:]
    private let logThrottleIntervalSeconds: Int
    private let xpcServiceName: String
    private static let debugMetricPrefixes: OSAllocatedUnfairLock<[String]?> = .init(initialState: nil)
    private let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "XPCClient")

    
    /// Create a ``CloudMetricsXPCClient``.
    /// - Parameter xpcServiceName: Used for testing. Allows overriding of service name to let us test the framework->XPC layer
    /// - Seealso  https://developer.apple.com/documentation/technotes/tn3113-testing-xpc-code-with-an-anonymous-listener
    package init(xpcServiceName: String) {
        self.xpcServiceName = xpcServiceName
        if let defaults = UserDefaults(suiteName: kCloudMetricsPreferenceDomain) {
            let interval = defaults.integer(forKey: "AuditLogThrottleIntervalSeconds")
            logThrottleIntervalSeconds = interval > 0 ? interval : kCloudMetricsAuditLogThrottleIntervalDefault
        } else {
            logThrottleIntervalSeconds = kCloudMetricsAuditLogThrottleIntervalDefault
        }
    }

    private func set(connectionState: ConnectionState) {
        self.connectionState = connectionState
    }

    /// Forms an XPC connection to `cloudmetricsd` and executes a closure with the connection.
    ///
    /// This handles ensuring that `cloudmetricsd` has a configuration and that this configuration is passed again if `cloudmetricsd` crashes.
    private func withConnection<T>(_ fn: (CloudMetricsAsyncXPCConnection) async throws -> T) async throws -> T {
        // Adjust state (and take a copy) to reflect that we're trying to connect
        let doConnect: Bool
        let doReconfigure: Bool
        switch connectionState {
            case .disconnected:
                let promise = Promise<CloudMetricsAsyncXPCConnection, CloudMetricsXPCError>()
                connectionState = .connecting(promise)
                doConnect = true
                doReconfigure = false
            case .connecting:
                doConnect = false
                doReconfigure = false
            case .connected:
                doConnect = false
                doReconfigure = false
            case .interrupted(let connection):
                doConnect = false
                doReconfigure = true
                let reconfiguredPromise = Promise<CloudMetricsAsyncXPCConnection, CloudMetricsXPCError>()
                connectionState = .reconfiguring(connection, reconfiguredPromise)
            case .reconfiguring:
                doConnect = false
                doReconfigure = false
            case .disconnecting:
                doConnect = false
                doReconfigure = false
        }

        let connection: CloudMetricsAsyncXPCConnection
        switch (connectionState, doConnect, doReconfigure) {
        case (.disconnected, _, _):
            logger.critical("Unexpected codepath in CloudMetricsXPCClient: newState==disconnected")
            throw CloudMetricsXPCError.invalidStateTransition
        case (.connecting(let connectionPromise), true, _):
            logger.log("CloudMetricsFramework connecting to daemon")
            connection = await CloudMetricsAsyncXPCConnection.connect(to: xpcServiceName)
            await connection.handleConnectionInvalidated { _ in
                await self.set(connectionState: .disconnected)
                self.logger.warning("CloudMetricsFramework connection invalidated")
            }
            await connection.handleConnectionInterrupted { connection in
                // When the XPC connection is interrupted best practice it's likely that the
                // daemon has been jetsammed or has crashed. The existing session is lost so
                // we need to send a `configurationMessage` again to setup the state.
                //
                // No need to create a new connection. Launchd will launch the daemon if it isn't
                // already running.
                self.logger.log("XPC connection interrupted")
                await self.set(connectionState: .interrupted(connection))
            }

            await connection.activate()
            if let configurationMessage {
                logger.log("Sending existing configuration message to new XPC connection")
                do {
                    try await connection.send(configurationMessage)
                } catch {
                    connectionPromise.fail(with: CloudMetricsXPCError.cannotConfigureDaemon)
                    throw error
                }
            }
            self.connectionState = .connected(connection)
            connectionPromise.succeed(with: connection)
        case (.connecting(let connectionPromise), false, _):
            connection = try await Future(connectionPromise).valueWithCancellation
        case( .connected(let existingConnection), _, _):
            connection = existingConnection
        case (.interrupted, _, _):
            logger.critical("Unexpected codepath where newState==interrupted")
            throw CloudMetricsXPCError.invalidStateTransition
        case (.reconfiguring(let existingConnection, let promise), _, true):
            if let configurationMessage {
                logger.log("Resending configuration message post-interruption")
                do {
                    try await existingConnection.send(configurationMessage)
                    promise.succeed(with: existingConnection)
                } catch {
                    self.logger.error("Unable to send configuration message on interruption: \(error, privacy: .public)")
                    // Set state back to interrupted so we try again.
                    self.connectionState = .interrupted(existingConnection)
                    promise.fail(with: CloudMetricsXPCError.cannotConfigureDaemon)
                    throw CloudMetricsXPCError.cannotConfigureDaemon
                }
            } else {
                promise.succeed(with: existingConnection)
            }
            connection = existingConnection
        case (.reconfiguring(_, let promise), _, false):
            connection = try await Future(promise).valueWithCancellation
        case (.disconnecting, _, _):
            throw CloudMetricsXPCError.clientShuttingDown
        }
        return try await fn(connection)
    }

    package func disconnect() async throws {
        let connectionPromise: Promise<CloudMetricsAsyncXPCConnection, CloudMetricsXPCError>?
        switch connectionState {
            case .disconnected:
                logger.error("disconnect called but already disconnected")
                // Nothing to do
                connectionPromise = nil
            case .connecting(let promise):
                connectionPromise = promise
            case .connected(let connection):
                connectionState = .disconnecting
                let promise = Promise<CloudMetricsAsyncXPCConnection, CloudMetricsXPCError>()
                promise.succeed(with: connection)
                connectionPromise = promise
            case .interrupted(let connection):
                connectionState = .disconnecting
                let promise = Promise<CloudMetricsAsyncXPCConnection, CloudMetricsXPCError>()
                promise.succeed(with: connection)
                connectionPromise = promise
            case .reconfiguring(_, let reconfiguredPromise):
                connectionPromise = reconfiguredPromise
            case .disconnecting:
                logger.error("disconnect called but already disconnecting")
                connectionPromise = nil
        }

        if let connectionPromise {
            let connection = try await Future(connectionPromise).valueWithCancellation
            await connection.handleConnectionInvalidated(handler: nil)
            await connection.cancel()
            self.connectionState = .disconnected
        }
    }
}

extension CloudMetricsXPCClient {

    package func setConfiguration(message configurationMessage: CloudMetricsServiceMessages.SetConfiguration) async throws {
        if self.configurationMessage != nil {
            // Another configuration messsage was already sent.
            throw CloudMetricsXPCClientError.apiMisuse("Configuration message already sent")
        }
        let result = try await self.withConnection { connection in
            try await connection.send(configurationMessage)
        }
        if result == .notAllowed {
            logger.error("Setting configuration not allowed")
        }
        self.configurationMessage = configurationMessage
    }

    private func logUnallowedMetric(_ metric: CloudMetric) {
        var shouldLog = true
        if let when = unallowedMetricLogTracker[metric.label] {
            let duration: Duration = .seconds(logThrottleIntervalSeconds)
            if when.duration(to: .now) < duration {
                shouldLog = false
            }
        }
        if shouldLog {
            // A metric outside the audit allow list is a configuration outcome rather than a
            // failure of this process, so it is logged below the error level.
            logger.log("Metric not allowed type=\(metric.type, privacy: .public) label=\(metric.label)")
            unallowedMetricLogTracker[metric.label] = .now
        }
    }

    private static func debugMetricPrefixArray() -> [String] {
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

    private func debugMetric(metric: CloudMetric, message: String, value: String) {
        let logger = Logger(subsystem: kCloudMetricsLoggingSubsystem, category: "XPCClient")

        for debuggingPrefix in Self.debugMetricPrefixArray() where metric.label.hasPrefix(debuggingPrefix) {
            // swiftlint:disable:next line_length
            logger.info("\(message, privacy: .public) [label: \(metric.label, privacy: .public), dimensions: \(metric.dimensions, privacy: .public), value: \(value, privacy: .public)]")
        }
    }

    package func incrementCounter(message: CloudMetricsServiceMessages.IncrementCounter) async throws {
        debugMetric(metric: message.counter, message: "incrementCounter", value: "\(message.amount)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.counter)
        }
    }

    package func incrementCounter(message: CloudMetricsServiceMessages.IncrementFloatingPointCounter) async throws {
        debugMetric(metric: message.counter, message: "incrementCounter", value: "\(message.amount)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.counter)
        }
    }

    package func recordInteger(message: CloudMetricsServiceMessages.RecordInteger) async throws {
        debugMetric(metric: message.recorder, message: "recordInteger", value: "\(message.value)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.recorder)
        }
    }

    package func recordDouble(message: CloudMetricsServiceMessages.RecordDouble) async throws {
        debugMetric(metric: message.recorder, message: "recordDouble", value: "\(message.value)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.recorder)
        }
    }

    package func recordNanoseconds(message: CloudMetricsServiceMessages.RecordNanoseconds) async throws {
        debugMetric(metric: message.timer, message: "recordNanoseconds", value: "\(message.duration)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.timer)
        }
    }

    package func resetCounter(message: CloudMetricsServiceMessages.ResetCounter) async throws {
        debugMetric(metric: message.counter, message: "resetCounter", value: "")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.counter)
        }
    }

    package func resetCounter(message: CloudMetricsServiceMessages.ResetCounterWithIntValue) async throws {
        debugMetric(metric: message.counter, message: "resetCounter", value: "\(message.value)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.counter)
        }
    }

    package func resetCounter(message: CloudMetricsServiceMessages.ResetCounterWithDoubleValue) async throws {
        debugMetric(metric: message.counter, message: "resetCounter", value: "\(message.value)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.counter)
        }
    }

    package func recordInteger(message: CloudMetricsServiceMessages.RecordHistogramInteger) async throws {
        debugMetric(metric: message.histogram, message: "recordInteger", value: "\(message.value)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.histogram)
        }
    }

    package func recordDouble(message: CloudMetricsServiceMessages.RecordHistogramDouble) async throws {
        debugMetric(metric: message.histogram, message: "recordDouble", value: "\(message.value)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.histogram)
        }
    }

    package func recordBuckets(message: CloudMetricsServiceMessages.RecordHistogramBuckets) async throws {
        debugMetric(metric: message.histogram, message: "recordBuckets", value: "\(message.buckets)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.histogram)
        }
    }

    package func recordInteger(message: CloudMetricsServiceMessages.RecordSummaryInteger) async throws {
        debugMetric(metric: message.summary, message: "recordInteger", value: "\(message.value)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.summary)
        }
    }

    package func recordDouble(message: CloudMetricsServiceMessages.RecordSummaryDouble) async throws {
        debugMetric(metric: message.summary, message: "recordDouble", value: "\(message.value)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.summary)
        }
    }

    package func recordQuantiles(message: CloudMetricsServiceMessages.RecordSummaryQuantiles) async throws {
        debugMetric(metric: message.summary, message: "recordQuantiles", value: "\(message.quantiles)")
        let result = try await self.withConnection { connection in
            try await connection.send(message)
        }
        if result == .notAllowed {
            logUnallowedMetric(message.summary)
        }
    }
}
