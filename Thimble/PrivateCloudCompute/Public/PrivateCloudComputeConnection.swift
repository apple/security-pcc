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
//  PrivateCloudComputeConnection.swift
//  PrivateCloudCompute
//
//  Copyright © 2025 Apple Inc. All rights reserved.
//

internal import AsyncAlgorithmsInternal
private import AtomicsInternal
@_spi(NWConnection) import Network
import OSLog
import Synchronization

private let logger = Logger(for: .connection)

/// Describes a proxy used by `PrivateCloudComputeConnection.Request.Writer`
/// and `PrivateCloudComputeConnection.Request.Response`.
protocol PrivateCloudComputeConnectionSubrequestProxy: Sendable {
    func send(data: Data) async throws
    func finishSending() async throws
    func cancel()
    func next() async throws -> Data?
}

public final class PrivateCloudComputeConnection: Sendable {
    public struct Configuration: Sendable {
        /// The connections's ID. Note this should not be sent to the server. It is the local
        /// identity for the connection (i.e., the caller's notion).
        public var id: UUID = UUID()

        public var workloadType: String
        public var workloadParameters: [String: String]?

        /// Optional bundle identifier to override the one automatically determined. Can only be passed if you have an entitlement.
        public var bundleIdentifier: String?

        /// Optional bundle identifier that specifies which app contained the interaction that led to the inference request, which is potentially different from the bundleIdentifier.
        public var originatingBundleIdentifier: String?

        /// Optional process identifier to resolve for bundle identifier attribution. Can only be passed if you have an entitlement.
        public var onBehalfOfPID: Int32?

        /// Optional process identifier to resolve for the parent bundle identifier. Specifies which app contained the interaction that led to the inference request.
        public var parentOfOnBehalfOfPID: Int32?

        /// Optional audit token of the caller on whose behalf this request is being made.
        public var overrideAuditToken: audit_token_t?

        /// Optional feature identifier used for rate limiting and analytics.
        public var featureIdentifier: String?

        /// Optional session identifier used for rate limiting and analytics.
        public var sessionIdentifier: UUID?

        /// Quality of Service.
        /// If not set, the value is derived from the `Task.currentPriority`.
        public var qos: QoS?

        /// The network service class for the connection.
        /// If not set, the default service class (best effort) is used.
        public var serviceClass: NWParameters.ServiceClass?

        public init(
            workloadType: String,
            workloadParameters: [String: String],
            featureIdentifier: String,
        ) {
            self.workloadType = workloadType
            self.workloadParameters = workloadParameters
            self.featureIdentifier = featureIdentifier
        }
    }

    public struct Request: Sendable {
        /// A struct used for writing data for a subrequest.
        public struct Writer: Sendable {
            private let logPrefix: String
            private let proxy: any PrivateCloudComputeConnectionSubrequestProxy
            /// The chunk size to use. `nil` means chunking is disabled.
            private let chunkSize: Int?

            init(logPrefix: String, proxy: any PrivateCloudComputeConnectionSubrequestProxy, chunkSize: Int?) {
                self.logPrefix = logPrefix
                self.proxy = proxy
                self.chunkSize = chunkSize
            }

            /// Writes the contents of the sequence to the request.
            ///
            /// This method will suspend if no more data can be written due to back pressure. Once, more
            /// flow control has opened up the method will resume and allow more data to be written.
            ///
            /// - Parameter contentsOf: The sequence of data to write to the request.
            @concurrent public func write(contentsOf sequence: some Sequence<UInt8>) async throws {
                try await self.write(data: Data(sequence))
            }

            /// Writes the contents of the data to the request.
            ///
            /// This method will suspend if no more data can be written due to back pressure. Once, more
            /// flow control has opened up the method will resume and allow more data to be written.
            ///
            /// - Parameter data: The data to write to the request.
            @concurrent public func write(data: Data) async throws {
                try await logger.logLifetime("write", logPrefix: self.logPrefix) {
                    try await self.write(contentsOf: [data].async)
                }
            }

            /// Writes the contents of the asynchronous sequence to the request.
            ///
            /// This method will run until the passed asynchronous sequence has finished.
            ///
            /// - Parameter contentsOf: The asynchronous sequence of data to write to the request.
            @concurrent public func write<AS: AsyncSequence>(contentsOf sequence: AS) async throws where AS.Element == Data {
                try await logger.logLifetime("write(contentsOf:)", logPrefix: self.logPrefix) {
                    let pipeline = self.buildPipeline(sequence)

                    try await withTaskCancellationHandler {
                        for try await chunk in pipeline {
                            try await self.proxy.send(data: chunk)
                        }
                        try await self.proxy.finishSending()
                    } onCancel: {
                        logger.error("\(self.logPrefix) write(contentsOf:) cancelling proxy")
                        self.proxy.cancel()
                    }
                }
            }

            private func buildPipeline<S: AsyncSequence>(
                _ sequence: S
            ) -> any AsyncSequence<Data, any Error> where S.Element == Data {
                var pipeline: any AsyncSequence<Data, any Error> =
                    sequence
                    .mapError { [logPrefix = self.logPrefix, proxy = self.proxy] error in
                        logger.error("\(logPrefix) write(contentsOf:) cancelling proxy due to iterator throw")
                        proxy.cancel()
                        return error
                    }
                if let chunkSize = self.chunkSize {
                    pipeline = pipeline.chunked(chunkSize: chunkSize)
                }
                return pipeline
            }
        }

        /// A struct representing the returned data for a subrequest.
        public struct Response: AsyncSequence {
            private let logPrefix: String
            private let proxy: any PrivateCloudComputeConnectionSubrequestProxy
            /// The chunk size to use. `nil` means chunking is disabled.
            private let chunkSize: Int?
            private let madeAsyncIteratorAtomic = ManagedAtomic(false)

            init(logPrefix: String, proxy: any PrivateCloudComputeConnectionSubrequestProxy, chunkSize: Int?) {
                self.logPrefix = logPrefix
                self.proxy = proxy
                self.chunkSize = chunkSize
            }

            public func makeAsyncIterator() -> AsyncIterator {
                guard !self.madeAsyncIteratorAtomic.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).original else {
                    fatalError(
                        """
                        Bug in PrivateCloudCompute adopter code!

                        PrivateCloudComputeConnection.Request.Response can only create a single AsyncIterator.
                        Creating multiple AsyncIterators would lead to undefined behavior when iterating
                        the iterators in parallel and is therefore forbidden.
                        """
                    )
                }
                return AsyncIterator(logPrefix: self.logPrefix, proxy: self.proxy, chunking: self.chunkSize != nil)
            }

            public struct AsyncIterator: AsyncIteratorProtocol {
                private let logPrefix: String
                private let proxy: any PrivateCloudComputeConnectionSubrequestProxy
                private let concurrentNextCallsAtomic = ManagedAtomic(false)
                private var assemblerIterator: DataAssembler<AsyncThrowingStream<Data, any Error>>.AsyncIterator?

                fileprivate init(logPrefix: String, proxy: any PrivateCloudComputeConnectionSubrequestProxy, chunking: Bool) {
                    self.logPrefix = logPrefix
                    self.proxy = proxy

                    if chunking {
                        let proxyStream = AsyncThrowingStream { [proxy] in
                            try await proxy.next()
                        }
                        let assembler = proxyStream.assembledChunkedPayloadData()
                        self.assemblerIterator = assembler.makeAsyncIterator()
                    } else {
                        self.assemblerIterator = nil
                    }
                }

                @concurrent public mutating func next() async throws -> Data? {
                    guard !self.concurrentNextCallsAtomic.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).original else {
                        fatalError(
                            """
                            Bug in PrivateCloudCompute adopter code!

                            PrivateCloudComputeConnection.Response.AsyncIterator is not Sendable and therefore must not
                            be invoked concurrently.
                            """
                        )
                    }
                    return try await logger.logLifetime("next", logPrefix: self.logPrefix) {
                        defer {
                            let changed = self.concurrentNextCallsAtomic.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing)
                            precondition(changed.original)
                        }
                        return try await withTaskCancellationHandler {
                            if self.assemblerIterator != nil {
                                return try await self.assemblerIterator?.next(isolation: #isolation)
                            }
                            return try await self.proxy.next()
                        } onCancel: { [logPrefix, proxy] in
                            logger.error("\(logPrefix) next cancelling proxy")
                            proxy.cancel()
                        }
                    }
                }
            }
        }

        public enum Priority: Sendable, Codable, Equatable {
            case unspecified
            /// Means "may be dropped" to support "opportunistic".
            case discardable
        }

        public struct OpaqueCryptoMaterial: Sendable, Codable, Equatable {
            public var id: UUID
            public var material: Data

            public init(id: UUID, material: Data) {
                self.id = id
                self.material = material
            }
        }

        public var priority: Priority
        public var opaqueCryptoMaterial: [OpaqueCryptoMaterial]

        public init(
            priority: Priority = .unspecified,
            opaqueCryptoMaterial: [OpaqueCryptoMaterial] = []
        ) {
            self.priority = priority
            self.opaqueCryptoMaterial = opaqueCryptoMaterial
        }
    }

    public enum Progress: Sendable, Codable, TC2JSON {
        /// Encoded Progress value that could be decoded with `Progress(json:)`.
        package typealias Data = Foundation.Data

        case networkStateChange(NetworkStateChangeInfo)
        case networkConnectionProgress(NetworkConnectionProgressInfo)
    }

    struct ProgressReader: AsyncSequence {
        private let logPrefix: String
        private let xpcProxy: any XPCRequestProxyProtocol
        private let madeAsyncIteratorAtomic = ManagedAtomic(false)

        init(logPrefix: String, proxy: any XPCRequestProxyProtocol) {
            self.logPrefix = logPrefix
            self.xpcProxy = proxy
        }

        func makeAsyncIterator() -> AsyncIterator {
            guard !self.madeAsyncIteratorAtomic.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).original else {
                fatalError(
                    """
                    Bug in PrivateCloudCompute adopter code!

                    PrivateCloudComputeConnection.ProgressReader can only create a single AsyncIterator.
                    Creating multiple AsyncIterators would lead to undefined behavior when iterating
                    the iterators in parallel and is therefore forbidden.
                    """
                )
            }
            return AsyncIterator(logPrefix: self.logPrefix, xpcProxy: self.xpcProxy)
        }

        struct AsyncIterator: AsyncIteratorProtocol {
            private let logPrefix: String
            private let xpcProxy: any XPCRequestProxyProtocol
            private let concurrentNextCallsAtomic = ManagedAtomic(false)

            fileprivate init(logPrefix: String, xpcProxy: any XPCRequestProxyProtocol) {
                self.logPrefix = logPrefix
                self.xpcProxy = xpcProxy
            }

            @concurrent public mutating func next() async throws -> PrivateCloudComputeConnection.Progress? {
                guard !self.concurrentNextCallsAtomic.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).original else {
                    fatalError(
                        """
                        Bug in PrivateCloudCompute adopter code!

                        PrivateCloudComputeConnection.ProgressReader.AsyncIterator is not Sendable and therefore must not
                        be invoked concurrently.
                        """
                    )
                }
                return try await logger.logLifetime("connection progress next", logPrefix: self.logPrefix) {
                    defer {
                        let changed = self.concurrentNextCallsAtomic.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing)
                        precondition(changed.original)
                    }
                    return try await withTaskCancellationHandler {
                        return try await self.xpcProxy.nextProgress()
                    } onCancel: { [logPrefix] in
                        logger.error("\(logPrefix) cancellation detected while waiting for next progress")
                    }
                }
            }
        }
    }

    nonisolated(nonsending) static func run(
        configuration: Configuration,
        xpcProxy: any XPCRequestProxyProtocol,
        featureFlagChecker: any FeatureFlagCheckerProtocol,
        logPrefix: String,
        chunkSize: Int?,
        subrequestIdGenerator: @escaping @Sendable () -> UInt64 = randomSubrequestId,
        closure: (PrivateCloudComputeConnection) async throws -> Void
    ) async throws {
        let demultiplexer = ResponseDemultiplexer(
            logPrefix: logPrefix,
            producer: xpcProxy,
            featureFlagChecker: featureFlagChecker
        )
        let connection = PrivateCloudComputeConnection(
            logPrefix: logPrefix,
            configuration: configuration,
            xpcProxy: xpcProxy,
            featureFlagChecker: featureFlagChecker,
            responseDemultiplexer: demultiplexer,
            chunkSize: chunkSize,
            subrequestIdGenerator: subrequestIdGenerator
        )

        try await demultiplexer.run {
            var closureError: (any Error)?

            do {
                try await logger.logLifetime("withConnection body", logPrefix: logPrefix) {
                    try await closure(connection)
                }
            } catch {
                closureError = error
            }

            await connection.finalize()  // sends `.final`

            if let closureError {
                throw closureError
            }

            // Once this block finishes, the demultiplexer will "drain" the
            // response stream before `demultiplexer.run(...)` returns.
        }
    }

    private let configuration: Configuration
    private let xpcProxy: any XPCRequestProxyProtocol
    private let featureFlagChecker: any FeatureFlagCheckerProtocol
    private let responseDemultiplexer: ResponseDemultiplexer
    private let logPrefix: String
    private let chunkSize: Int?
    private let subrequestIdGenerator: @Sendable () -> UInt64

    private init(
        logPrefix: String,
        configuration: Configuration,
        xpcProxy: any XPCRequestProxyProtocol,
        featureFlagChecker: any FeatureFlagCheckerProtocol,
        responseDemultiplexer: ResponseDemultiplexer,
        chunkSize: Int?,
        subrequestIdGenerator: @escaping @Sendable () -> UInt64
    ) {
        self.configuration = configuration
        self.xpcProxy = xpcProxy
        self.featureFlagChecker = featureFlagChecker
        self.logPrefix = logPrefix
        self.responseDemultiplexer = responseDemultiplexer
        self.chunkSize = chunkSize
        self.subrequestIdGenerator = subrequestIdGenerator
    }

    private func finalize() async {
        // At the time we try to finalize the connection, the adopter has already
        // finished running `withConnection` closure, so they don't really care about
        // the finalization result.
        try? await logger.logLifetime("connection finalization", logPrefix: self.logPrefix) {
            // If the Task running the connection has been canceled, and the adopter
            // exited the closure we gave them cleanly, there is no point for us to
            // try to send "final", in fact, it will fail anyway since the request on
            // the daemon side is being teared down.
            try Task.checkCancellation()

            // At this point the adopter isn't going to send any new subrequests. But
            // we still have open root, data stream, node stream(s). We may still be
            // waiting for REL from selected node as well as NACK from other nodes.
            // We need to gracefully finish remaining streams before returning from `withConnection`.

            // 1. Send "final" on the data stream, so the server knows there will be
            //    no more subrequests. The server is expected to wrap up its
            //    communication on root and node streams.
            try await self.xpcProxy.send(message: .final)

            // 2. We should "drain" the "response" stream. The daemon completes it
            //    once the request is complete. In general we don't expect more responses
            //    at this point, and should just await and receive `nil`. But in theory it could
            //    be possible that, say, the last subrequest was cancelled by adopter,
            //    but its response has been already received, but not read by the adopter.
            //
            //    The draining happens in the demultiplexer.
        }
    }

    private let progressReader: Mutex<ProgressReader?> = Mutex(nil)

    public var progress: some AsyncSequence<Progress, any Error> {
        self.progressReader.withLock { progressReader in
            if let progressReader {
                return progressReader
            } else {
                let reader = ProgressReader(logPrefix: self.logPrefix, proxy: self.xpcProxy)
                progressReader = reader
                return reader
            }
        }
    }

    @concurrent public func withRequest<Return>(
        _ request: Request,
        _ body: @concurrent (_ writer: Request.Writer, _ response: Request.Response) async throws -> Return
    ) async throws -> Return {
        let requestId = subrequestIdGenerator()
        let subrequestLogPrefix = "\(self.logPrefix) <\(requestId)>"
        return try await logger.logLifetime("withRequest", logPrefix: subrequestLogPrefix) {
            let subrequestProxy = try await self.makeSubrequest(request: request, requestId: requestId, logPrefix: subrequestLogPrefix)
            defer { await subrequestProxy.close() }

            let writer = Request.Writer(logPrefix: subrequestLogPrefix, proxy: subrequestProxy, chunkSize: self.chunkSize)
            let response = Request.Response(logPrefix: subrequestLogPrefix, proxy: subrequestProxy, chunkSize: self.chunkSize)

            return try await logger.logLifetime("withRequest body", logPrefix: self.logPrefix) {
                try await body(writer, response)
            }
        }
    }

    private func makeSubrequest(request: Request, requestId: UInt64, logPrefix: String) async throws -> SubrequestProxy {
        try await self.xpcProxy.createSubrequest(.init(requestId: requestId, request: request))
        let subrequestProxy = SubrequestProxy(
            request: request,
            requestId: requestId,
            xpcProxy: self.xpcProxy,
            responseDemultiplexer: responseDemultiplexer,
            logPrefix: logPrefix
        )
        try await subrequestProxy.open()
        return subrequestProxy
    }
}

public struct NetworkStateChangeInfo: Sendable, Codable {
    public var state: NWConnection.State {
        codableState.unwrap()
    }

    package init?(state: NWConnection.State) {
        guard let codableState = ConnectionStateCodableValue(state) else {
            return nil
        }
        self.codableState = codableState
    }

    let codableState: ConnectionStateCodableValue
}

public struct NetworkConnectionProgressInfo: Sendable, Codable {
    public let progressReport: NWConnection.ConnectionProgressReport

    package init(progressReport: NWConnection.ConnectionProgressReport) {
        self.progressReport = progressReport
    }
}

func randomSubrequestId() -> UInt64 {
    UInt64.random(in: 1...UInt64(UInt32.max))
}
