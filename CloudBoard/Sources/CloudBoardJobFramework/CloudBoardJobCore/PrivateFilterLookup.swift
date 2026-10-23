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

import CloudBoardDomain
internal import CloudBoardLogging
import CryptoKit
import Foundation
import InternalSwiftProtobuf

/// Temporary strongly typed wrapper around ``PersistentServiceClientProtocol`` for PrivateFilter lookups.
///
/// This enum serves as a namespace for all PrivateFilter-related types and the ``Client``
/// that wraps the generic persistent-service transport layer. It encapsulates proto
/// serialization/deserialization so callers work with Swift value types instead of opaque
/// `Data` payloads.
///
/// Usage:
/// ```swift
/// let client = PrivateFilterLookup.Client(wrapping: persistentServiceClient)
/// let pendingQueries = Mutex<[PersistentService.QueryCorrelationID: MyRequestContext]>([:])
///
/// try await withThrowingTaskGroup(of: Void.self) { group in
///     group.addTask { try await client.run() }
///
///     // Send a query, tracking the correlation ID for later.
///     // filterID and hashingID are SHA256-last-8 values precomputed from their
///     // respective ID strings (e.g. FilterID.uniqueName, HashingID.uniqueName).
///     let correlationID = PersistentService.QueryCorrelationID()
///     let query = try PrivateFilterTemp.LookupQuery(
///         filterID: myFilterID,
///         hashingID: myHashingID,
///         key: twelveByteLookupKey
///     )
///     pendingQueries.withLock { $0[correlationID] = context }
///     try await client.sendQuery(query, correlationID: correlationID)
///
///     // Consume results, matching each back to its original request.
///     for await response in client.results {
///         let context = pendingQueries.withLock { $0.removeValue(forKey: response.correlationID) }
///         guard let context else {
///             // log.warning("Duplicate response for \(response.correlationID)")
///             continue
///         }
///         switch response.result {
///         case .success(let filterResponse):
///             switch filterResponse.result {
///             case .hit:
///                 handleHit(filterResponse, context: context)
///             case .miss:
///                 handleMiss(filterResponse, context: context)
///             }
///         case .serviceFailure(let code):
///             // log.error("Lookup failed with code \(code)")
///             break
///         case .infrastructureFailure(let errorInfo):
///             // log.error("Infrastructure failure: \(errorInfo)")
///             break
///         }
///     }
/// }
/// ```
public enum PrivateFilterLookup: Sendable {}

// MARK: - Types

extension PrivateFilterLookup {
    /// A single lookup query to send to the PrivateFilter service.
    ///
    /// - ``filterID``: SHA256-last-8 of the filter's string identifier.
    /// - ``hashingID``: SHA256-last-8 of the hashing configuration's string identifier.
    /// - ``key``: Exactly 12 bytes in big-endian order. Byte 0 is the most-significant byte
    ///   of the high 64-bit portion; byte 8 is the most-significant byte of the low 32-bit
    ///   portion. This matches the `BinaryKey` layout used by `pcc-disk-filter`.
    public struct LookupQuery: Sendable {
        public var filterID: UInt64
        public var hashingID: UInt64
        public var key: Data

        /// Creates a lookup query.
        ///
        /// - Throws: ``QueryError/invalidKeyLength(_:)`` if `key` is not exactly 12 bytes.
        public init(filterID: UInt64, hashingID: UInt64, key: Data) throws {
            guard key.count == 12 else {
                throw QueryError.invalidKeyLength(key.count)
            }
            self.filterID = filterID
            self.hashingID = hashingID
            self.key = key
        }
    }

    /// A single element from the result stream, carrying the correlation ID so callers
    /// can match it back to the original query.
    public struct QueryResponse: Sendable {
        public var correlationID: PersistentService.QueryCorrelationID
        public var result: LookupResult

        public init(correlationID: PersistentService.QueryCorrelationID, result: LookupResult) {
            self.correlationID = correlationID
            self.result = result
        }
    }

    /// A decoded filter response with the echoed filter ID and key.
    ///
    /// - ``filterID``: Echoed from the original query — identifies which filter was queried.
    /// - ``key``: Echoed 12-byte key in big-endian order, reconstructed from the proto response.
    /// - ``result``: Whether it was a hit or miss.
    public struct FilterResponse: Sendable {
        public var filterID: UInt64
        public var key: Data
        public var result: FilterResult

        public init(filterID: UInt64, key: Data, result: FilterResult) {
            self.filterID = filterID
            self.key = key
            self.result = result
        }
    }

    /// The outcome of a successfully decoded lookup — either the key was found or it wasn't.
    ///
    /// Service-level failures (failedToQuery, unspecified) are represented as
    /// ``LookupResult/serviceFailure(_:)`` instead.
    public enum FilterResult: Sendable {
        case hit
        case miss
    }

    /// The result of a single PrivateFilter lookup.
    ///
    /// - ``success(_:)``: A successfully decoded ``FilterResponse``.
    /// - ``serviceFailure(_:)``: The filter service returned an error code
    ///   (failedToQuery → the service's failure code; unspecified/UNRECOGNIZED → 0).
    /// - ``infrastructureFailure(_:)``: A transport or deserialization error from the
    ///   persistent-service layer.
    public enum LookupResult: Sendable {
        case success(FilterResponse)
        case serviceFailure(Int32)
        case infrastructureFailure(PersistentService.ErrorInfo)
    }

    /// Errors that can occur when sending a query.
    ///
    /// - ``invalidKeyLength(_:)``: The key data was not exactly 12 bytes.
    /// - ``serializationFailed(_:)``: Proto serialization failed (should not happen with
    ///   fixed-layout protos).
    package enum QueryError: ReportableError {
        public var publicDescription: String {
            switch self {
            // do not expose the length, it's a side channel
            case .invalidKeyLength: return "Invalid key length: not 12 bytes"
            case .serializationFailed: return "Failed to serialize query"
            }
        }

        /// The 12-byte key data was not exactly 12 bytes.
        case invalidKeyLength(Int)
        /// Proto serialization failed (should not happen with fixed-layout protos).
        case serializationFailed(Error)
    }
}

// MARK: - Shared serialization

extension PrivateFilterLookup {
    /// Serialize a ``LookupQuery`` and correlation ID into an opaque `Data` payload
    /// suitable for ``PersistentServiceClientProtocol/sendQuery(to:payload:correlationID:timeout:)``.
    ///
    /// The correlation ID is embedded in the protobuf `responseID` field so that the
    /// persistent service can echo it back in the response. This is a legacy coupling —
    /// the correlation ID must be passed both here (in-band) and as a separate parameter
    /// to the send call (out-of-band). A future update will decouple these.
    static func serializeQuery(
        _ query: LookupQuery,
        correlationID: PersistentService.QueryCorrelationID
    ) throws -> Data {
        let responseIDData = withUnsafeBytes(of: correlationID.rawValue.uuid) { Data($0) }

        let keyHigh = query.key.withUnsafeBytes {
            UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))
        }
        let keyLow = query.key.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        }

        var protoQuery = Com_Apple_Cloudboard_Privatefilter_V1_LookupQuery()
        protoQuery.responseID = responseIDData
        protoQuery.filterID = query.filterID
        protoQuery.hashingID = query.hashingID
        protoQuery.keyHigh = keyHigh
        protoQuery.keyLow = keyLow

        do {
            return try protoQuery.serializedBytes()
        } catch {
            throw QueryError.serializationFailed(error)
        }
    }

    /// Decode a ``PersistentService.ResponsePayload`` into a ``LookupResult``.
    static func deserializeResponse(
        _ payload: PersistentService.ResponsePayload
    ) -> LookupResult {
        switch payload {
        case .success(let data):
            do {
                let lookup = try Com_Apple_Cloudboard_Privatefilter_V1_LookupResponse(
                    serializedBytes: data
                )

                switch lookup.result {
                case .hit, .miss:
                    var keyData = Data(count: 12)
                    keyData.withUnsafeMutableBytes { buf in
                        buf.storeBytes(of: lookup.keyHigh.bigEndian, as: UInt64.self)
                        buf.storeBytes(of: lookup.keyLow.bigEndian, toByteOffset: 8, as: UInt32.self)
                    }
                    let filterResult: FilterResult = lookup.result == .hit ? .hit : .miss
                    return .success(FilterResponse(
                        filterID: lookup.filterID,
                        key: keyData,
                        result: filterResult
                    ))
                case .failedToQuery:
                    return .serviceFailure(lookup.failureCode)
                case .unspecified, .UNRECOGNIZED:
                    return .serviceFailure(0)
                }
            } catch {
                return .infrastructureFailure(PersistentService.ErrorInfo(
                    code: -1,
                    message: "Failed to deserialize PrivateFilter response: \(error)"
                ))
            }
        case .error(let errorInfo):
            return .infrastructureFailure(errorInfo)
        }
    }
}

// MARK: - Client

extension PrivateFilterLookup {
    /// A client that wraps ``PersistentServiceClientProtocol`` for PrivateFilter lookups.
    ///
    /// Lifecycle:
    /// 1. Create via ``init(wrapping:filterIDLabels:)`` (or the legacy ``init(wrapping:)``).
    /// 2. Start ``run()`` in a task group — it subscribes to the underlying response stream
    ///    and pumps decoded results into ``results``.
    /// 3. Send queries via ``sendQuery(_:correlationID:timeout:)``.
    /// 4. Consume decoded results from ``results``.
    public final class Client: Sendable {
        private let inner: any PersistentServiceClientProtocol
        private let serviceIdentity: PersistentService.Identity
        private let _stream: AsyncStream<QueryResponse>
        private let continuation: AsyncStream<QueryResponse>.Continuation
        private let filterIDLabels: FilterIDLabelRegistry

        /// SHA256-last-8 of `"trusted-filter"`, matching the convention in `PrivateFilterTestApp`.
        private static let trustedFilterServiceID: UInt64 = PersistentService.sha256Last8("trusted-filter")

        public convenience init(wrapping client: any PersistentServiceClientProtocol) {
            self.init(wrapping: client, filterIDLabels: FilterIDLabelRegistry())
        }

        /// - Parameter filterIDLabels: registry consulted at metric-emit time to derive the
        ///   human-readable `capability` dimension from each query's `filterID`. Pass an
        ///   already-populated registry if the caller knows the original filter names; an
        ///   empty registry leaves the metric falling back to the 16-char hex form.
        public init(
            wrapping client: any PersistentServiceClientProtocol,
            filterIDLabels: FilterIDLabelRegistry
        ) {
            self.inner = client
            self.serviceIdentity = PersistentService.Identity(
                serviceID: Self.trustedFilterServiceID
            )
            let (stream, continuation) = AsyncStream<QueryResponse>.makeStream()
            self._stream = stream
            self.continuation = continuation
            self.filterIDLabels = filterIDLabels
        }

        public var results: AsyncStream<QueryResponse> {
            self._stream
        }

        /// Serializes and sends a lookup query to the PrivateFilter service. The metric
        /// `capability` dimension is synthesized from `query.filterID` via the
        /// ``FilterIDLabelRegistry`` supplied at init — falling back to the 16-char hex of
        /// the hash when the name hasn't been registered.
        ///
        /// - Throws: ``QueryError/serializationFailed(_:)`` if proto serialization fails.
        public func sendQuery(
            _ query: LookupQuery,
            correlationID: PersistentService.QueryCorrelationID = .init(),
            timeout: Duration? = nil
        ) async throws {
            let payload = try PrivateFilterLookup.serializeQuery(query, correlationID: correlationID)
            let capability = self.filterIDLabels.label(for: query.filterID)

            await self.inner.sendQuery(
                to: self.serviceIdentity,
                payload: payload,
                correlationID: correlationID,
                timeout: timeout,
                capability: capability
            )
        }

        public func informBlocked(
            on correlationIDs: [PersistentService.QueryCorrelationID]
        ) async {
            await self.inner.informBlocked(on: correlationIDs)
        }

        /// Subscribes to the underlying response stream and pumps decoded results
        /// into ``results``. Runs until the underlying stream ends or the task is
        /// cancelled. Propagates any error thrown by the stream iteration.
        public func run() async throws {
            let realStream = await self.inner.subscribeToResults(for: self.serviceIdentity)
            for await response in realStream {
                let result = PrivateFilterLookup.deserializeResponse(response.payload)
                self.continuation.yield(QueryResponse(
                    correlationID: response.correlationID,
                    result: result
                ))
            }
            self.continuation.finish()
        }
    }
}

// MARK: - Simple (request/response) client

extension PrivateFilterLookup {
    /// A simple request/response client for PrivateFilter lookups.
    ///
    /// Unlike ``Client`` which uses a streaming pattern requiring a pump task and manual
    /// correlation, this client provides a single async ``lookup(_:timeout:)`` method that
    /// sends a query and awaits its response. Multiple lookups can safely run concurrently
    /// from a task group.
    ///
    /// Backed by ``PersistentServiceQuerySession`` — the caller must run the session's pump
    /// via ``PersistentServiceQuerySession/run()`` in a task group.
    ///
    /// **Example:**
    /// ```swift
    /// let session = try await persistentServiceClient.makeQuerySession(for: identity)
    /// let filterClient = PrivateFilterLookup.SimpleClient(session: session)
    /// try await withThrowingTaskGroup(of: Void.self) { group in
    ///     group.addTask { await session.run() }
    ///     let result = try await filterClient.lookup(
    ///         PrivateFilterLookup.LookupQuery(filterID: id, hashingID: hid, key: key),
    ///         timeout: .seconds(5)
    ///     )
    ///     session.cancel()
    /// }
    /// ```
    public final class SimpleClient: Sendable {
        /// The service identity for the PrivateFilter ("trusted-filter") service.
        public static let serviceIdentity = PersistentService.Identity(
            serviceID: PersistentService.sha256Last8("trusted-filter")
        )

        private let session: PersistentServiceQuerySession
        private let filterIDLabels: FilterIDLabelRegistry

        public convenience init(session: PersistentServiceQuerySession) {
            self.init(session: session, filterIDLabels: FilterIDLabelRegistry())
        }

        /// - Parameter filterIDLabels: registry consulted at metric-emit time to derive the
        ///   human-readable `capability` dimension from each query's `filterID`. Pass an
        ///   already-populated registry if the caller knows the original filter names; an
        ///   empty registry leaves the metric falling back to the 16-char hex form.
        public init(
            session: PersistentServiceQuerySession,
            filterIDLabels: FilterIDLabelRegistry
        ) {
            self.session = session
            self.filterIDLabels = filterIDLabels
        }

        /// Send a lookup query and await the decoded result. The metric `capability`
        /// dimension is synthesized from `query.filterID` via the ``FilterIDLabelRegistry``
        /// supplied at init — falling back to the 16-char hex of the hash when the name
        /// hasn't been registered.
        ///
        /// - Parameters:
        ///   - query: The lookup query to send.
        ///   - timeout: Optional per-query timeout.
        /// - Returns: The decoded ``LookupResult``.
        /// - Throws: ``QueryError`` if serialization fails, or `CancellationError`
        ///   if the task or session is cancelled before a response arrives.
        public func lookup(
            _ query: LookupQuery,
            timeout: Duration? = nil
        ) async throws -> LookupResult {
            let correlationID = PersistentService.QueryCorrelationID()
            let payload = try PrivateFilterLookup.serializeQuery(query, correlationID: correlationID)
            let capability = self.filterIDLabels.label(for: query.filterID)
            let responsePayload = try await self.session.query(
                payload: payload,
                correlationID: correlationID,
                timeout: timeout,
                capability: capability
            )
            return PrivateFilterLookup.deserializeResponse(responsePayload)
        }
    }
}

// MARK: - Scoped lookup API

extension PrivateFilterLookup {
    /// Execute a block with a managed PrivateFilter lookup client.
    ///
    /// This is the simplest way to perform PrivateFilter lookups. The session pump
    /// is started automatically and cancelled when `body` returns. Multiple lookups
    /// can run concurrently within `body` using `async let` or task groups.
    ///
    /// **Example:**
    /// ```swift
    /// let result = try await PrivateFilterLookup.withLookups(using: client) { lookups in
    ///     try await lookups.lookup(
    ///         LookupQuery(filterID: myFilterID, hashingID: myHashingID, key: key),
    ///         timeout: .seconds(5)
    ///     )
    /// }
    /// ```
    public static func withLookups<Result: Sendable>(
        using persistentServiceClient: PersistentServiceClient,
        body: @escaping @Sendable (SimpleClient) async throws -> Result
    ) async throws -> Result {
        try await self.withLookups(
            using: persistentServiceClient,
            filterIDLabels: FilterIDLabelRegistry(),
            body: body
        )
    }

    /// Variant of ``withLookups(using:body:)`` that accepts a ``FilterIDLabelRegistry``.
    /// The registry is consulted by ``SimpleClient/lookup(_:timeout:)`` to derive the
    /// human-readable `capability` metric dimension from each query's `filterID`. Pass an
    /// already-populated registry if the caller knows the original filter names.
    public static func withLookups<Result: Sendable>(
        using persistentServiceClient: PersistentServiceClient,
        filterIDLabels: FilterIDLabelRegistry,
        body: @escaping @Sendable (SimpleClient) async throws -> Result
    ) async throws -> Result {
        try await persistentServiceClient.withQuerySession(for: SimpleClient.serviceIdentity) { session in
            try await body(SimpleClient(session: session, filterIDLabels: filterIDLabels))
        }
    }
}
