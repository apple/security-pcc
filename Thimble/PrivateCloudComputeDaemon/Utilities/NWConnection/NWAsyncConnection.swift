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
//  NWAsyncConnection.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
@_spi(NWActivity) @_spi(OHTTP) @_spi(NWConnection) import Network
import OSLog
import PrivateCloudCompute
import os

private let logger = Logger(for: .network)

/// A protocol for a type that can write to an underlying `NWConnection`.
///
/// This protocol is primarily used to make code testable.
protocol AsyncConnectionWriterProtocol: Sendable {
    /// Send data on a connection. This may be called before the connection is ready,
    /// in which case the send will be enqueued until the connection is ready to send.
    ///
    /// - Important: If the task calling this method gets cancelled then the underlying `NWConnection` will get force-closed.
    ///
    /// - Parameter content: The data to send on the connection. May be nil if this send marks its context as complete, such
    ///   as by sending .finalMessage as the context and marking isComplete to send a write-close.
    /// - Parameter contentContext: The context associated with the content, which represents a logical message
    ///   to be sent on the connection. All content sent within a single context will
    ///   be sent as an in-order unit, up until the point that the context is marked
    ///   complete (see isComplete). Once a context is marked complete, it may be re-used
    ///   as a new logical message. Protocols like TCP that cannot send multiple
    ///   independent messages at once (serial streams) will only start processing a new
    ///   context once the prior context has been marked complete. Defaults to .defaultMessage.
    /// - Parameter isComplete: A flag indicating if the caller's sending context (logical message) is now complete.
    ///   Until a context is marked complete, content sent for other contexts may not
    ///   be sent immediately (if the protocol requires sending bytes serially, like TCP).
    ///   For datagram protocols, like UDP, isComplete indicates that the content represents
    ///   a complete datagram.
    ///   When sending using streaming protocols like TCP, isComplete can be used to mark the end
    ///   of a single message on the stream, of which there may be many. However, it can also
    ///   indicate that the connection should send a "write close" (a TCP FIN) if the sending
    ///   context is the final context on the connection. Specifically, to send a "write close",
    ///   pass .finalMessage or .defaultStream for the context (or create a custom context and
    ///   set .isFinal), and pass true for isComplete.
    func write(
        content: Data?,
        contentContext: NWConnection.ContentContext,
        isComplete: Bool
    ) async throws
}

protocol OHTTPStreamFactoryProtocol: Sendable {
    associatedtype Inbound: AsyncSequence<NWConnectionReceived, any Error>
    associatedtype Outbound: AsyncConnectionWriterProtocol

    /// Creates an OHTTP substream on an existing connection
    ///
    /// - Parameters:
    ///   - ohttpContext: The OHTTPContext for the request
    ///   - gatewayKeyConfig: Some Data used as the gateway key config
    ///   - mediaType: A media type
    ///   - logComment: A string to be included in logs associated with this connection.
    ///   - body: A body that gets access to incoming stream and the outgoing writer.
    func withOHTTPSubStream<Result>(
        ohttpContext: UInt64,
        gatewayKeyConfig: Data,
        mediaType: String,
        logComment: String,
        _ body: (Inbound, Outbound) async throws -> Result
    ) async throws -> Result

    /// Creates an OHTTP substream on an existing connection
    ///
    /// - Parameters:
    ///   - ohttpContext: The OHTTPContext for the request
    ///   - standaloneAEADKey: The AEAD key
    ///   - logComment: A string to be included in logs associated with this connection.
    ///   - body: A body that gets access to incoming stream and the outgoing writer.
    func withOHTTPSubStream<Result>(
        ohttpContext: UInt64,
        standaloneAEADKey: some ContiguousBytes,
        logComment: String,
        _ body: (Inbound, Outbound) async throws -> Result
    ) async throws -> Result

    /// Creates a receive-only OHTTP substream on an existing connection
    ///
    /// - Parameters:
    ///   - ohttpContext: The OHTTPContext for the request
    ///   - logComment: A string to be included in logs associated with this connection.
    ///   - aeadDelivery: A block that "delivers" AEAD data and key after the connection is being created.
    ///   - body: A body that gets access to incoming stream.
    func withOHTTPSubStream<Result: Sendable>(
        ohttpContext: UInt64,
        logComment: String,
        aeadDelivery: () async throws -> (aeadKey: Data, aeadNonce: Data),
        body: (Inbound) async throws -> Result
    ) async throws -> Result
}

protocol NWActivityTracker {
    func startActivity(_ activity: NWActivity)
}

/// A pending data transfer report represents a report that was started with
/// `startDataTransferReport()`, and may be collected to generate a completed `DataTransferReport`.
protocol PendingDataTransferReportProtocol: Sendable {
    /// Collects the data transfer report, effectively ending the outstanding report
    /// begun with `startDataTransferReport()`.
    func collect() async -> DataTransferReport
}

protocol NWConnectionEstablishmentReportProvider: Sendable {
    /// An option to wait until the connection has become ready
    var connectionReady: Void { get async throws }

    /// Provides a connection establishment report once the connection has become ready.
    /// **throws** if a connection has been cancelled before ever becoming ready.
    var connectionEstablishReport: NWConnection.EstablishmentReport? { get async throws }
}

protocol NWConnectionDataTransferReportProvider: Sendable {
    associatedtype PendingReport: PendingDataTransferReportProtocol

    /// Starts a new pending data transfer report on a connection. Multiple reports may be
    /// created for a single connection. The report begins capturing data when the connection
    /// moves to the ready state, or when the report is created (whichever occurs last).
    func startDataTransferReport() -> PendingReport
}

/// A protocol abstracting an `NWConnection`.
///
/// This protocol is primarily used to make code testable.
protocol NWAsyncConnectionFactoryProtocol: Sendable {
    associatedtype Inbound: AsyncSequence<NWConnectionReceived, any Error> & Sendable
    associatedtype Outbound: AsyncConnectionWriterProtocol
    associatedtype OHTTPSubStreamFactory: OHTTPStreamFactoryProtocol & NWActivityTracker
    associatedtype MetricsReporter: NWConnectionEstablishmentReportProvider & NWConnectionDataTransferReportProvider

    /// Creates a new `NWConnection` and connects to an endpoint
    ///
    /// - Parameters:
    ///   - parameters: The parameters for the connection.
    ///   - endpoint: The endpoint to connect to.
    ///   - activity: An optional activity that will be tracked around the connection's lifetime. The activity will be succeed if the `body` returns normally.
    ///   If the `body` throws an error the activity will be failed.
    ///   - queue: The queue on which to start the connection on.
    ///   - body: A body that gets access to the asynchronous wrappers.
    ///   - progressContinuation: A continuation to receive connection updates on. **Note:** the connection factory will not finish the provided continuation.
    ///   The caller is responsible to finish it.
    /// - Returns: The body's result.
    func connect<Result>(
        parameters: NWParameters,
        endpoint: NWEndpoint,
        activity: NWActivity?,
        on queue: DispatchQueue,
        requestID: UUID,
        logComment: String,
        maximumReadLength: Int,
        progressContinuation: AsyncStream<ConnectionUpdate>.Continuation?,
        _ body: (Inbound, Outbound, OHTTPSubStreamFactory, MetricsReporter) async throws -> Result
    ) async throws -> Result
}

extension NWAsyncConnectionFactoryProtocol {
    /// Creates a new `NWConnection` and connects to an endpoint
    ///
    /// - Parameters:
    ///   - parameters: The parameters for the connection.
    ///   - endpoint: The endpoint to connect to.
    ///   - activity: An optional activity that will be tracked around the connection's lifetime. The activity will be succeed if the `body` returns normally.
    ///   If the `body` throws an error the activity will be failed.
    ///   - queue: The queue on which to start the connection on.
    ///   - body: A body that gets access to the asynchronous wrappers.
    /// - Returns: The body's result.
    func connect<Result>(
        parameters: NWParameters,
        endpoint: NWEndpoint,
        activity: NWActivity?,
        on queue: DispatchQueue,
        requestID: UUID,
        logComment: String,
        maximumReadLength: Int = .max,
        _ body: (Inbound, Outbound, OHTTPSubStreamFactory, MetricsReporter) async throws -> Result
    ) async throws -> Result {
        try await self.connect(
            parameters: parameters,
            endpoint: endpoint,
            activity: activity,
            on: queue,
            requestID: requestID,
            logComment: logComment,
            maximumReadLength: maximumReadLength,
            progressContinuation: nil,
            body
        )
    }
}

/// A struct representing all the data returned from a single `NWConnection.receive` call.
struct NWConnectionReceived {
    /// The received data.
    var data: Data?
    /// The received context.
    var contentContext: NWConnection.ContentContext?
    /// A boolean indicating if the context has been completed.
    var isComplete: Bool

    init(
        data: Data? = nil,
        contentContext: NWConnection.ContentContext? = nil,
        isComplete: Bool
    ) {
        self.data = data
        self.contentContext = contentContext
        self.isComplete = isComplete
    }
}

/// A struct wrapping an `NWConnection` providing asynchronous interfaces.
struct NWAsyncConnection: NWAsyncConnectionFactoryProtocol {
    /// Wraps an existing connection and provides scoped access to asynchronous interfaces.
    /// Used for the root connection of the TrustedRequest.
    ///
    /// - Parameters:
    ///   - connection: The connection that gets wrapped. This connection **must not** be started.
    ///   - queue: The queue on which to start the connection on.
    ///   - body: A body that gets access to the asynchronous wrappers.
    static func wrapping<Result>(
        connection: NWConnection,
        on queue: DispatchQueue,
        requestID: UUID,
        logComment: String,
        maximumReadLength: Int = .max,
        progressContinuation: AsyncStream<ConnectionUpdate>.Continuation? = nil,
        _ body: (Inbound, Outbound, OHTTPStreamFactory, ConnectionMetricsReporter) async throws -> Result
    ) async throws -> Result {
        let readyEvent = AsyncEvent<Void>()
        let ohttpFactory = OHTTPStreamFactory(
            rootConnection: connection,
            rootConnectionReadyEvent: readyEvent,
            queue: queue,
            requestID: requestID,
            maximumReadLength: maximumReadLength
        )
        let metricsReporter = ConnectionMetricsReporter(
            rootConnection: connection,
            rootConnectionReadyEvent: readyEvent,
            queue: queue
        )
        return try await self._wrapping(
            connection: connection,
            on: queue,
            requestID: requestID,
            logComment: logComment,
            readyEvent: readyEvent,
            maximumReadLength: maximumReadLength,
            progressContinuation: progressContinuation,
            inputs: ohttpFactory, metricsReporter,
            body: body
        )
    }

    // Parameter Pack trick explained:
    // We use the parameter pack here to allow passing n additional values to the users closure.
    // This allows us to reuse the same code for the case where we pass an additional parameter
    // in the NWAsyncConnection case and no additional parameter in the OHTTPStreamFactory case.
    private static func _wrapping<each Input, Result>(
        connection: NWConnection,
        on queue: DispatchQueue,
        requestID: UUID,
        logComment: String,
        readyEvent: AsyncEvent<Void>?,
        maximumReadLength: Int,
        progressContinuation: AsyncStream<ConnectionUpdate>.Continuation? = nil,
        inputs: repeat each Input,
        body: (Inbound, Outbound, repeat each Input) async throws -> Result
    ) async throws -> Result {
        let connectionWrapper = NWConnectionWrapper(
            underlying: connection,
            readyEvent: readyEvent,
            logger: logger,
            requestID: requestID,
            logComment: logComment,
            maximumReadLength: maximumReadLength,
            progressContinuation: progressContinuation
        )

        connectionWrapper.start(queue: queue)
        defer {
            connectionWrapper.cancel()
        }

        let outbound = Outbound(connection: connectionWrapper)
        let inbound = Inbound(connection: connectionWrapper)
        return try await body(inbound, outbound, repeat each inputs)
    }

    /// Creates a new `NWConnection` and connects to an endpoint
    ///
    /// - Parameters:
    ///   - parameters: The parameters for the connection.
    ///   - endpoint: The endpoint to connect to.
    ///   - activity: An optional activity that will be tracked around the connection's lifetime. The activity will be succeed if the `body` returns normally.
    ///   If the `body` throws an error the activity will be failed.
    ///   - queue: The queue on which to start the connection on.
    ///   - body: A body that gets access to the asynchronous wrappers.
    /// - Returns: The body's result.
    func connect<Result>(
        parameters: NWParameters,
        endpoint: NWEndpoint,
        activity: NWActivity?,
        on queue: DispatchQueue,
        requestID: UUID,
        logComment: String,
        maximumReadLength: Int,
        progressContinuation: AsyncStream<ConnectionUpdate>.Continuation?,
        _ body: (Inbound, Outbound, OHTTPStreamFactory, ConnectionMetricsReporter) async throws -> Result
    ) async throws -> Result {
        let connection = NWConnection(
            to: endpoint,
            using: parameters
        )

        guard let activity else {
            return try await Self.wrapping(
                connection: connection,
                on: queue,
                requestID: requestID,
                logComment: logComment,
                maximumReadLength: maximumReadLength,
                progressContinuation: progressContinuation,
                body
            )
        }

        return try await connection.withActivity(activity: activity) {
            try await Self.wrapping(
                connection: connection,
                on: queue,
                requestID: requestID,
                logComment: logComment,
                maximumReadLength: maximumReadLength,
                progressContinuation: progressContinuation,
                body
            )
        }
    }
}

// MARK: Writer

extension NWAsyncConnection {
    /// An outbound writer for an `NWConnection`.
    ///
    /// It is safe to write from multiple tasks at once. The writes will be written to the underlying
    /// connection in the order that ``NWConnectionWriter/write(content:contentContext:isComplete:)`` was called in.
    struct Outbound: Sendable, AsyncConnectionWriterProtocol {
        private let connection: NWConnectionWrapper

        fileprivate init(connection: NWConnectionWrapper) {
            self.connection = connection
        }
        /// Send data on a connection. This may be called before the connection is ready,
        /// in which case the send will be enqueued until the connection is ready to send.
        ///
        /// - Important: If the task calling this method gets cancelled then the underlying `NWConnection` will get force-closed.
        ///
        /// - Parameter content: The data to send on the connection. May be nil if this send marks its context as complete, such
        ///   as by sending .finalMessage as the context and marking isComplete to send a write-close.
        /// - Parameter contentContext: The context associated with the content, which represents a logical message
        ///   to be sent on the connection. All content sent within a single context will
        ///   be sent as an in-order unit, up until the point that the context is marked
        ///   complete (see isComplete). Once a context is marked complete, it may be re-used
        ///   as a new logical message. Protocols like TCP that cannot send multiple
        ///   independent messages at once (serial streams) will only start processing a new
        ///   context once the prior context has been marked complete. Defaults to .defaultMessage.
        /// - Parameter isComplete: A flag indicating if the caller's sending context (logical message) is now complete.
        ///   Until a context is marked complete, content sent for other contexts may not
        ///   be sent immediately (if the protocol requires sending bytes serially, like TCP).
        ///   For datagram protocols, like UDP, isComplete indicates that the content represents
        ///   a complete datagram.
        ///   When sending using streaming protocols like TCP, isComplete can be used to mark the end
        ///   of a single message on the stream, of which there may be many. However, it can also
        ///   indicate that the connection should send a "write close" (a TCP FIN) if the sending
        ///   context is the final context on the connection. Specifically, to send a "write close",
        ///   pass .finalMessage or .defaultStream for the context (or create a custom context and
        ///   set .isFinal), and pass true for isComplete.
        func write(
            content: Data?,
            contentContext: NWConnection.ContentContext = .defaultMessage,
            isComplete: Bool = true
        ) async throws {
            try await self.connection.write(content: content, contentContext: contentContext, isComplete: isComplete)
        }
    }
}

// MARK: Inbound

extension NWAsyncConnection {
    /// A struct wrapping the receiving side of `NWConnection` into an asynchronous sequence.
    ///
    /// - Important: If the task calling this method gets cancelled then the underlying `NWConnection` will get force-closed.
    struct Inbound: AsyncSequence, Sendable {
        typealias Element = NWConnectionReceived

        private let connection: NWConnectionWrapper
        private let hasCreatedIterator = OSAllocatedUnfairLock(initialState: false)

        fileprivate init(connection: NWConnectionWrapper) {
            self.connection = connection
        }

        func makeAsyncIterator() -> AsyncIterator {
            self.hasCreatedIterator.withLock { hasCreatedIterator in
                if hasCreatedIterator {
                    fatalError("Tried to create more than one iterator")
                } else {
                    hasCreatedIterator = true
                }
            }

            return AsyncIterator(connection: self.connection)
        }

        struct AsyncIterator: AsyncIteratorProtocol {
            private let connection: NWConnectionWrapper
            private var error: (any Error)? = nil
            private var isComplete: Bool = false

            fileprivate init(connection: NWConnectionWrapper) {
                self.connection = connection
            }

            mutating func next() async throws -> Element? {
                if self.isComplete {
                    return nil
                }
                let result = try await self.connection.next()
                if result.isComplete {
                    self.isComplete = true
                }
                return result
            }
        }
    }
}

// MARK: OHTTPStreamFactory

extension NWAsyncConnection {
    /// A pending data transfer report represents a report that was started with
    /// `startDataTransferReport()`, and may be collected to generate a completed `DataTransferReport`.
    struct PendingDataTransferReport: PendingDataTransferReportProtocol {
        private let pendingReport: NWConnection.PendingDataTransferReport
        private let dispatchQueue: DispatchQueue

        fileprivate init(pendingReport: NWConnection.PendingDataTransferReport, dispatchQueue: DispatchQueue) {
            self.pendingReport = pendingReport
            self.dispatchQueue = dispatchQueue
        }

        /// Collects the data transfer report, effectively ending the outstanding report
        /// begun with `startDataTransferReport()`.
        func collect() async -> DataTransferReport {
            await withCheckedContinuation { (continuation: CheckedContinuation<DataTransferReport, Never>) in
                self.pendingReport.collect(queue: self.dispatchQueue) { report in
                    continuation.resume(returning: DataTransferReport(report))
                }
            }
        }
    }

    struct ConnectionMetricsReporter: NWConnectionEstablishmentReportProvider, NWConnectionDataTransferReportProvider {
        private let dispatchQueue: DispatchQueue
        private let rootConnection: NWConnection
        private let rootConnectionReadyEvent: AsyncEvent<Void>

        fileprivate init(rootConnection: NWConnection, rootConnectionReadyEvent: AsyncEvent<Void>, queue: DispatchQueue) {
            self.rootConnection = rootConnection
            self.rootConnectionReadyEvent = rootConnectionReadyEvent
            self.dispatchQueue = queue
        }

        var connectionReady: Void {
            get async throws {
                try await self.rootConnectionReadyEvent()
            }
        }

        var connectionEstablishReport: NWConnection.EstablishmentReport? {
            get async throws {
                try await self.rootConnectionReadyEvent()
                return await withCheckedContinuation {
                    (continuation: CheckedContinuation<NWConnection.EstablishmentReport?, Never>) in
                    self.rootConnection.requestEstablishmentReport(queue: self.dispatchQueue) { report in
                        // We query the report once the connection is ready, so the report should be there.
                        continuation.resume(returning: report)
                    }
                }
            }
        }

        /// Starts a new pending data transfer report on a connection. Multiple reports may be
        /// created for a single connection. The report begins capturing data when the connection
        /// moves to the ready state, or when the report is created (whichever occurs last).
        func startDataTransferReport() -> PendingDataTransferReport {
            let pendingReport = rootConnection.startDataTransferReport()
            return PendingDataTransferReport(pendingReport: pendingReport, dispatchQueue: self.dispatchQueue)
        }
    }

    struct OHTTPStreamFactory: OHTTPStreamFactoryProtocol, NWActivityTracker {
        typealias Inbound = NWAsyncConnection.Inbound
        typealias Outbound = NWAsyncConnection.Outbound

        enum Error: Swift.Error {
            case couldNotCreateConnection
            case couldNotUpdateObliviousHTTPConnection
        }

        private let dispatchQueue: DispatchQueue
        private let rootConnection: NWConnection
        private let rootConnectionReadyEvent: AsyncEvent<Void>
        private let requestID: UUID
        private let maximumReadLength: Int

        fileprivate init(rootConnection: NWConnection, rootConnectionReadyEvent: AsyncEvent<Void>, queue: DispatchQueue, requestID: UUID, maximumReadLength: Int) {
            self.rootConnection = rootConnection
            self.rootConnectionReadyEvent = rootConnectionReadyEvent
            self.dispatchQueue = queue
            self.requestID = requestID
            self.maximumReadLength = maximumReadLength
        }

        /// Used for node streams.
        func withOHTTPSubStream<Result>(
            ohttpContext: UInt64,
            gatewayKeyConfig: Data,
            mediaType: String,
            logComment: String,
            _ body: (Inbound, Outbound) async throws -> Result
        ) async throws -> Result {
            // we must wait until the root connection is ready, before we can create ohttp
            // substreams on it
            try await self.rootConnectionReadyEvent()

            guard let connection = NWConnection(obliviousHTTPConnection: self.rootConnection, gatewayKeyConfig: gatewayKeyConfig, contextID: ohttpContext, mediaType: mediaType) else {
                throw Error.couldNotCreateConnection
            }

            return try await NWAsyncConnection._wrapping(connection: connection, on: .main, requestID: requestID, logComment: logComment, readyEvent: nil, maximumReadLength: self.maximumReadLength, body: body)
        }

        /// Used for data stream.
        func withOHTTPSubStream<Result>(
            ohttpContext: UInt64,
            standaloneAEADKey: some ContiguousBytes,
            logComment: String,
            _ body: (NWAsyncConnection.Inbound, NWAsyncConnection.Outbound) async throws -> Result
        ) async throws -> Result {
            // we must wait until the root connection is ready, before we can create ohttp
            // substreams on it
            try await self.rootConnectionReadyEvent()

            guard let connection = NWConnection(obliviousHTTPConnection: self.rootConnection, standaloneAEADKey: standaloneAEADKey, contextID: ohttpContext) else {
                throw Error.couldNotCreateConnection
            }

            return try await NWAsyncConnection._wrapping(connection: connection, on: .main, requestID: requestID, logComment: logComment, readyEvent: nil, maximumReadLength: self.maximumReadLength, body: body)
        }

        /// Used for response bypass stream.
        func withOHTTPSubStream<Result: Sendable>(
            ohttpContext: UInt64,
            logComment: String,
            aeadDelivery: () async throws -> (aeadKey: Data, aeadNonce: Data),
            body: (Inbound) async throws -> Result
        ) async throws -> Result {
            // we must wait until the root connection is ready, before we can create ohttp
            // substreams on it
            try await self.rootConnectionReadyEvent()

            guard let connection = NWConnection(obliviousHTTPConnection: self.rootConnection, contextIDForReceiveAEAD: ohttpContext) else {
                throw Error.couldNotCreateConnection
            }

            let connectionReadyEvent = AsyncEvent<Void>()

            return try await NWAsyncConnection._wrapping(
                connection: connection,
                on: .main,
                requestID: requestID,
                logComment: logComment,
                readyEvent: connectionReadyEvent,
                maximumReadLength: self.maximumReadLength,
            ) { inbound, _ in
                let logPrefix = "\(requestID): [C\(connection.identifier)] (\(logComment))"
                // We need to wait for this connection to be ready before calling `updateObliviousHTTPConnection()`
                try await connectionReadyEvent()

                let result = try await aeadDelivery()
                logger.debug("\(logPrefix) updating obliviousHTTPConnection aeadNonce.count=\(result.aeadNonce.count), aeadKey.count=\(result.aeadKey.count)")
                guard
                    connection.updateObliviousHTTPConnection(
                        receiveAEADNonce: result.aeadNonce,
                        receiveAEADKey: result.aeadKey
                    )
                else {
                    throw Error.couldNotUpdateObliviousHTTPConnection
                }
                logger.debug("\(logPrefix) did update obliviousHTTPConnection")

                return try await body(inbound)
            }
        }

        func startActivity(_ activity: NWActivity) {
            self.rootConnection.startActivity(activity)
        }
    }
}

enum ConnectionUpdate: Sendable {
    case stateChanged(NWConnection.State)
    case connectionProgress(NWConnection.ConnectionProgressReport)
}
