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

internal import CloudBoardDomain
import CloudBoardJob
import CloudBoardJobCore
import CloudBoardLogging
import CloudBoardMetrics
import CryptoKit
import Foundation
import os

/// A proxy-only NullApp role that generates PrivateFilter lookup traffic for testing.
///
/// Sends lookup queries to configured (or default) test filters via the
/// persistent service client. Generates a burst of ~250 lookups with hardcoded known hit/miss
/// keys plus random traffic, then reports results as JSON on the response stream.
struct PrivateFilterTestApp: NullAppRole {
    static var serviceName: NullAppServiceName { .privateFilterTestApp }

    private let log: Logger
    private let metrics: any MetricsSystem
    private let filterIDLabels: FilterIDLabelRegistry
    private let persistentServiceClient: any PersistentServiceClientProtocol
    private let client: PrivateFilterLookup.Client

    // Note: we use the "ignore the hashingID" special value of "*" throughout this role
    // unless the input specifically selects it, trying to keep this up to date with externally defined
    // config simply isn't tenable.

    /// Default filters used when the request body does not specify `filters`.
    private static let defaultFilters: [FilterConfig] = [
        FilterConfig(
            name: "com.apple.fm.language.instruct_server_v2.base_pro.bf2",
            filterID: sha256Last8("com.apple.fm.language.instruct_server_v2.base_pro.bf2"),
            hashingID: sha256Last8("*"),
            skippable: true,
            knownHitKeys: [],
            knownMissKeys: [],
            queryTimeout: .milliseconds(Self.defaultQueryTimeoutMs)
        ),
        // base_zap.bf2 not deployed everywhere yet so disabled
        // needs proper know keys
        // FilterConfig(
        //     name: "com.apple.fm.language.instruct_server_v2.base_zap.bf2",
        //     filterID: sha256Last8("com.apple.fm.language.instruct_server_v2.base_zap.bf2"),
        //     hashingID: sha256Last8("*"),
        //     skippable: true,
        //     knownHitKeys: [],
        //     knownMissKeys: [],
        //     queryTimeout: .milliseconds(Self.defaultQueryTimeoutMs)
        // ),
        FilterConfig(
            name: "com.apple.fm.language.instruct_server_v2.base_pro.bf1",
            filterID: sha256Last8("com.apple.fm.language.instruct_server_v2.base_pro.bf1"),
            hashingID: sha256Last8("*"),
            skippable: false,
            knownHitKeys: [],
            knownMissKeys: [],
            queryTimeout: .milliseconds(Self.defaultQueryTimeoutMs)
        ),
    ]

    init(
        log: Logger,
        metrics: any MetricsSystem,
        persistentServiceClient: any PersistentServiceClientProtocol
    ) {
        self.log = log
        self.metrics = metrics
        self.persistentServiceClient = persistentServiceClient
        let labels = FilterIDLabelRegistry()
        self.filterIDLabels = labels
        self.client = PrivateFilterLookup.Client(
            wrapping: persistentServiceClient,
            filterIDLabels: labels
        )
    }

    // note - these are *not* actually real keys, we need the real filters to know them
    // This is fine and can be fixed later.

    /// Default key expected to produce a HIT response when no per-filter override is supplied.
    private static let defaultKnownHitKey: Data = makeLookupKeyData(high: 0xDEAD_BEEF_CAFE_F00D, low: 0x1234_5678)

    /// Default key expected to produce a MISS response when no per-filter override is supplied.
    private static let defaultKnownMissKey: Data = makeLookupKeyData(high: 0x0000_0000_0000_0001, low: 0x0000_0001)

    // MARK: - Configuration Defaults

    // These are broadly speaking what a very fast inference would produce
    // the informBlockedDelayMs is quite speculative though
    private static let defaultInitialWaitMs: Int = 100
    private static let defaultLookupIntervalMs: Int = 5
    private static let defaultBaseLookupCount: Int = 250
    private static let defaultLookupCountJitter: Int = 50
    private static let lastNSkipBigFilter: Int = 10
    private static let informBlockedDelayMs: Int = 5
    private static let defaultQueryTimeoutMs: Int = 500
    private static let defaultHistogramCoarsenFactor: Int = 10
    private static let defaultReservoirSize: Int = 32

    // MARK: - Helpers

    /// Build a 12-byte big-endian lookup key from high (UInt64) and low (UInt32) parts.
    private static func makeLookupKeyData(high: UInt64, low: UInt32) -> Data {
        var data = Data(count: 12)
        data.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: high.bigEndian, as: UInt64.self)
            buf.storeBytes(of: low.bigEndian, toByteOffset: 8, as: UInt32.self)
        }
        return data
    }

    /// Generate a random 12-byte lookup key.
    fileprivate static func randomLookupKey() -> Data {
        self.makeLookupKeyData(
            high: UInt64.random(in: UInt64.min ... UInt64.max),
            low: UInt32.random(in: UInt32.min ... UInt32.max)
        )
    }

    // MARK: - Run

    func run(
        input: InputData,
        responder: ResponseWriter,
        environment: CloudAppEnvironment,
        spanID _: UInt64
    ) async throws {
        let requestID = environment.plaintextMetadata.requestID
        let clock = ContinuousClock()

        // Read only the first input chunk to check for client-provided configuration.
        var inputIterator = input.makeAsyncIterator()
        let firstChunk = try await inputIterator.next()

        let requestConfig: PrivateFilterTestRequestConfig?
        let configurationSource: TestResults.ConfigurationSource
        if let firstChunk {
            do {
                requestConfig = try JSONDecoder().decode(
                    PrivateFilterTestRequestConfig.self,
                    from: firstChunk
                )
                configurationSource = .clientProvided
            } catch {
                requestConfig = nil
                configurationSource = .defaultParseFailure
                self.log.warning("""
                request.uuid=\(requestID, privacy: .public)
                message=PrivateFilterTestApp ignoring malformed request configuration; using defaults
                chunkBytes=\(firstChunk.count, privacy: .public)
                error=\(String(reportable: error), privacy: .public)
                """)
            }
        } else {
            requestConfig = nil
            configurationSource = .defaultNoInput
        }

        // Resolve effective configuration: request body > hardcoded defaults.
        let effectiveFilters: [FilterConfig]
        let effectiveInitialWaitMs: Int
        let effectiveLookupIntervalMs: Int
        let effectiveBaseLookupCount: Int
        let effectiveLookupCountJitter: Int
        let effectiveHistogramCoarsenFactor: Int
        let effectiveReservoirSize: Int

        if let requestConfig {
            let hashingID = sha256Last8(requestConfig.hashingID ?? "*")

            if let configuredFilters = requestConfig.filters, !configuredFilters.isEmpty {
                effectiveFilters = try configuredFilters.map { entry in
                    let hits = try (entry.knownHitKeys?.map { try Self.decodeKeyBase64($0) })
                        ?? [Self.defaultKnownHitKey]
                    let misses = try (entry.knownMissKeys?.map { try Self.decodeKeyBase64($0) })
                        ?? [Self.defaultKnownMissKey]
                    let timeoutMs = entry.queryTimeoutMs ?? Self.defaultQueryTimeoutMs
                    return FilterConfig(
                        name: entry.name,
                        filterID: sha256Last8(entry.name),
                        hashingID: hashingID,
                        skippable: entry.skippable ?? false,
                        knownHitKeys: hits,
                        knownMissKeys: misses,
                        queryTimeout: .milliseconds(timeoutMs)
                    )
                }
            } else {
                effectiveFilters = Self.defaultFilters
            }

            effectiveInitialWaitMs = requestConfig.initialWaitMs ?? Self.defaultInitialWaitMs
            effectiveLookupIntervalMs = requestConfig.lookupIntervalMs ?? Self.defaultLookupIntervalMs
            effectiveBaseLookupCount = requestConfig.baseLookupCount ?? Self.defaultBaseLookupCount
            effectiveLookupCountJitter = requestConfig.lookupCountJitter ?? Self.defaultLookupCountJitter
            effectiveHistogramCoarsenFactor = Swift.max(
                1,
                requestConfig.histogramCoarsenFactor ?? Self.defaultHistogramCoarsenFactor
            )
            effectiveReservoirSize = Swift.max(
                0,
                requestConfig.reservoirSize ?? Self.defaultReservoirSize
            )

            self.log.log("""
            request.uuid=\(requestID, privacy: .public)
            message=PrivateFilterTestApp using client-provided configuration
            filters=\(effectiveFilters.map(\.name), privacy: .public)
            hashingID=\(requestConfig.hashingID ?? "*", privacy: .public)
            initialWaitMs=\(effectiveInitialWaitMs, privacy: .public)
            lookupIntervalMs=\(effectiveLookupIntervalMs, privacy: .public)
            baseLookupCount=\(effectiveBaseLookupCount, privacy: .public)
            lookupCountJitter=\(effectiveLookupCountJitter, privacy: .public)
            histogramCoarsenFactor=\(effectiveHistogramCoarsenFactor, privacy: .public)
            reservoirSize=\(effectiveReservoirSize, privacy: .public)
            """)
        } else {
            effectiveFilters = Self.defaultFilters
            effectiveInitialWaitMs = Self.defaultInitialWaitMs
            effectiveLookupIntervalMs = Self.defaultLookupIntervalMs
            effectiveBaseLookupCount = Self.defaultBaseLookupCount
            effectiveLookupCountJitter = Self.defaultLookupCountJitter
            effectiveHistogramCoarsenFactor = Self.defaultHistogramCoarsenFactor
            effectiveReservoirSize = Self.defaultReservoirSize

            self.log.log("""
            request.uuid=\(requestID, privacy: .public)
            message=PrivateFilterTestApp using default configuration
            filters=\(effectiveFilters.map(\.name), privacy: .public)
            """)
        }

        // Populate the registry so the framework's `capability` metric dimension carries
        // human-readable filter names instead of hex hashes. Must happen before any
        // `sendQuery` call, since the capability is captured at query-record time.
        for filter in effectiveFilters {
            self.filterIDLabels.register(filter.name, for: filter.filterID)
        }

        // Activate framework metrics under NullCloudApp's existing `MetricsSystem` so the
        // persistent-service metrics emit alongside NullCloudApp's own. Uses the package-level
        // overload that accepts a pre-built `MetricsSystem` rather than re-bootstrapping by
        // client name.
        if let concreteClient = self.persistentServiceClient as? PersistentServiceClient {
            concreteClient.activateMetrics(self.metrics)
        } else {
            self.log.warning("""
            request.uuid=\(requestID, privacy: .public)
            message=PrivateFilterTestApp could not activate framework metrics; \
            persistentServiceClient is not the concrete PersistentServiceClient
            """)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Drain remaining input in the background (must consume the stream).
            // The stream's shared buffer continues from where we read the first chunk.
            group.addTask { for try await _ in input {} }

            // Start the client's response pump
            group.addTask { try await self.client.run() }

            let baseLookupCount = effectiveBaseLookupCount
                + Int.random(in: -effectiveLookupCountJitter ... effectiveLookupCountJitter)

            // Ensure every configured probe runs at least once even if baseLookupCount is
            // small, AND falls strictly before the tail skip window so skippable filters
            // still receive every known-hit/miss probe. The tail window is the last
            // `lastNSkipBigFilter` iterations, so we need at least `maxProbeCount +
            // lastNSkipBigFilter` iterations total to push all probe indices out of it.
            let maxProbeCount = effectiveFilters
                .map { $0.knownHitKeys.count + $0.knownMissKeys.count }
                .max() ?? 0
            let lookupCount = max(baseLookupCount, maxProbeCount + Self.lastNSkipBigFilter)

            self.log.log("""
            request.uuid=\(requestID, privacy: .public)
            message=PrivateFilterTestApp starting
            lookupCount=\(lookupCount, privacy: .public)
            initialWaitMs=\(effectiveInitialWaitMs, privacy: .public)
            lookupIntervalMs=\(effectiveLookupIntervalMs, privacy: .public)
            filters=\(effectiveFilters.map(\.name), privacy: .public)
            """)

            // Tracking state
            let tracker = LookupTracker()

            // Consume responses from the client
            group.addTask {
                for await response in self.client.results {
                    await tracker.recordResponse(response, log: self.log)
                }
            }

            let overallStart = clock.now

            // Initial wait
            try await clock.sleep(for: .milliseconds(effectiveInitialWaitMs), tolerance: .zero)

            // Burst phase
            for i in 0 ..< lookupCount {
                let skipBigFilter = i >= (lookupCount - Self.lastNSkipBigFilter)

                // Send to each filter
                for filter in effectiveFilters {
                    if skipBigFilter, filter.skippable {
                        continue
                    }

                    let probe = filter.probe(at: i)

                    let correlationID = PersistentService.QueryCorrelationID()
                    let sentAt = clock.now

                    await tracker.registerLookup(
                        correlationID: correlationID,
                        filterName: filter.name,
                        key: probe.key,
                        knownHitIndex: probe.knownHitIndex,
                        knownMissIndex: probe.knownMissIndex,
                        sentAt: sentAt
                    )

                    let query = try PrivateFilterLookup.LookupQuery(
                        filterID: filter.filterID,
                        hashingID: filter.hashingID,
                        key: probe.key
                    )

                    try await self.client.sendQuery(
                        query,
                        correlationID: correlationID,
                        timeout: filter.queryTimeout
                    )
                }

                if i % 50 == 0, i > 0 {
                    let outstanding = await tracker.outstandingCount
                    self.log.log("""
                    request.uuid=\(requestID, privacy: .public)
                    message=PrivateFilterTestApp progress
                    lookupsSent=\(i, privacy: .public)
                    outstanding=\(outstanding, privacy: .public)
                    """)
                }

                if i < lookupCount - 1 {
                    try await clock.sleep(for: .milliseconds(effectiveLookupIntervalMs), tolerance: .zero)
                }
            }

            // Wait 5ms after last lookup, then call informBlocked
            try await clock.sleep(for: .milliseconds(Self.informBlockedDelayMs), tolerance: .zero)

            let outstandingIDs = await tracker.outstandingCorrelationIDs
            self.log.log("""
            request.uuid=\(requestID, privacy: .public)
            message=PrivateFilterTestApp calling informBlocked
            outstandingCount=\(outstandingIDs.count, privacy: .public)
            """)

            let informBlockedTime = clock.now
            // it is fine to call this when the outstanding is empty - we get good metrics from that
            await self.client.informBlocked(on: outstandingIDs)

            // Intentionally no timeout — the process-level request timeout will
            // terminate this task if persistent service responses are lost. This is
            // acceptable in a test harness where we *want* to observe that failure mode
            // and measure how long it takes to hit the request timeout. Do NOT copy this
            // pattern in production code paths — real services should enforce their own
            // per-query deadlines.
            await tracker.waitForAllResponses()

            let informBlockedDuration = clock.now - informBlockedTime
            let informBlockedMs = durationToMilliseconds(informBlockedDuration)

            let totalDuration = clock.now - overallStart
            let totalMs = durationToMilliseconds(totalDuration)

            // Build results
            let results = await tracker.buildResults(
                configurationSource: configurationSource,
                histogramCoarsenFactor: effectiveHistogramCoarsenFactor,
                reservoirSize: effectiveReservoirSize,
                informBlockedMs: informBlockedMs,
                totalMs: totalMs
            )

            self.log.log("""
            request.uuid=\(requestID, privacy: .public)
            message=PrivateFilterTestApp completed
            totalLookups=\(results.totalLookups, privacy: .public)
            informBlockedToAllResponsesMs=\(informBlockedMs, privacy: .public)
            totalDurationMs=\(totalMs, privacy: .public)
            """)

            // Log per-filter results
            for (filterName, info) in results.filters {
                let latencySummary = info.latency.map {
                    "mean=\($0.meanMs)ms p50=\($0.p50Ms)ms p95=\($0.p95Ms)ms p99=\($0.p99Ms)ms"
                } ?? "N/A"
                self.log.log("""
                request.uuid=\(requestID, privacy: .public)
                message=PrivateFilterTestApp filter results
                filter=\(filterName, privacy: .public)
                lookups=\(info.lookups, privacy: .public)
                hits=\(info.hits, privacy: .public)
                misses=\(info.misses, privacy: .public)
                failures=\(info.failures, privacy: .public)
                knownHitResults=\(info.knownHitResults, privacy: .public)
                knownMissResults=\(info.knownMissResults, privacy: .public)
                knownHitMismatchCount=\(info.knownHitMismatches.count, privacy: .public)
                knownMissMismatchCount=\(info.knownMissMismatches.count, privacy: .public)
                latency=\(latencySummary, privacy: .public)
                """)
            }

            // Send JSON results on the response stream
            let jsonData = try JSONEncoder().encode(results)
            try await responder.write(jsonData)
            try responder.finish()

            // Cancel drain and response tasks
            group.cancelAll()
        }
    }
}

// MARK: - Supporting Types

private struct FilterConfig {
    let name: String
    let filterID: UInt64
    let hashingID: UInt64
    let skippable: Bool
    let knownHitKeys: [Data]
    let knownMissKeys: [Data]
    let queryTimeout: Duration

    struct Probe {
        let key: Data
        let knownHitIndex: Int?
        let knownMissIndex: Int?
    }

    /// Decide what to send for the i-th burst iteration on this filter:
    /// known-hit keys first (in order), then known-miss keys, then random keys.
    func probe(at i: Int) -> Probe {
        if i < self.knownHitKeys.count {
            return Probe(key: self.knownHitKeys[i], knownHitIndex: i, knownMissIndex: nil)
        }
        let missIdx = i - self.knownHitKeys.count
        if missIdx < self.knownMissKeys.count {
            return Probe(key: self.knownMissKeys[missIdx], knownHitIndex: nil, knownMissIndex: missIdx)
        }
        return Probe(key: PrivateFilterTestApp.randomLookupKey(), knownHitIndex: nil, knownMissIndex: nil)
    }
}

// MARK: - Client-Provided Request Configuration

/// JSON configuration that the client can send in the first input chunk to override
/// the hardcoded defaults. All fields are optional; omitted fields fall back to
/// the existing default. An empty request body (no input data) preserves
/// full backward compatibility.
private struct PrivateFilterTestRequestConfig: Codable {
    struct FilterEntry: Codable {
        var name: String
        var skippable: Bool?
        /// Base64-encoded 12-byte keys expected to produce HIT responses.
        var knownHitKeys: [String]?
        /// Base64-encoded 12-byte keys expected to produce MISS responses.
        var knownMissKeys: [String]?
        /// Per-query timeout in milliseconds for this filter. Defaults to
        /// `PrivateFilterTestApp.defaultQueryTimeoutMs`.
        var queryTimeoutMs: Int?
    }

    var filters: [FilterEntry]?
    /// String hashed via SHA256-last-8 to produce the hashingID for all filters.
    /// Defaults to "*" (wildcard — skip validation).
    var hashingID: String?

    // Timing overrides
    var initialWaitMs: Int?
    var lookupIntervalMs: Int?
    var baseLookupCount: Int?
    var lookupCountJitter: Int?

    /// Number of dense histogram buckets coalesced into one output bucket.
    /// Storage and percentile math are unaffected; only response payload
    /// granularity changes. Clamped to >= 1. Defaults to
    /// `PrivateFilterTestApp.defaultHistogramCoarsenFactor`.
    var histogramCoarsenFactor: Int?

    /// Capacity of the reservoir-sampled latency buffer (per filter).
    /// Clamped to >= 0. Defaults to `PrivateFilterTestApp.defaultReservoirSize`.
    var reservoirSize: Int?
}

extension PrivateFilterTestApp {
    enum ConfigError: Error, CustomStringConvertible {
        case invalidBase64Key(String)
        case wrongKeyLength(actual: Int)

        var description: String {
            switch self {
            case .invalidBase64Key(let s): "invalid base64 in known key: \(s)"
            case .wrongKeyLength(let n): "lookup key must be 12 bytes, got \(n)"
            }
        }
    }

    static func decodeKeyBase64(_ s: String) throws -> Data {
        guard let data = Data(base64Encoded: s) else {
            throw ConfigError.invalidBase64Key(s)
        }
        guard data.count == 12 else {
            throw ConfigError.wrongKeyLength(actual: data.count)
        }
        return data
    }
}

// MARK: - Lookup Tracking

private actor LookupTracker {
    struct Entry {
        let filterName: String
        let key: Data
        let knownHitIndex: Int?
        let knownMissIndex: Int?
        let sentAt: ContinuousClock.Instant
        var result: LookupResult?
        var errorMessage: String?
        var latencyNs: UInt64?
    }

    enum LookupResult: String, Encodable {
        case hit = "HIT"
        case miss = "MISS"
        case failedToQuery = "FAILED_TO_QUERY"
        case unknown = "UNKNOWN"
    }

    private var entries: [PersistentService.QueryCorrelationID: Entry] = [:]
    private var completionContinuation: CheckedContinuation<Void, Never>?

    func registerLookup(
        correlationID: PersistentService.QueryCorrelationID,
        filterName: String,
        key: Data,
        knownHitIndex: Int?,
        knownMissIndex: Int?,
        sentAt: ContinuousClock.Instant
    ) {
        self.entries[correlationID] = Entry(
            filterName: filterName,
            key: key,
            knownHitIndex: knownHitIndex,
            knownMissIndex: knownMissIndex,
            sentAt: sentAt
        )
    }

    func recordResponse(_ response: PrivateFilterLookup.QueryResponse, log: Logger) {
        guard var entry = self.entries[response.correlationID] else {
            log.warning("""
            message=PrivateFilterTestApp received response for unknown correlationID
            correlationID=\(response.correlationID, privacy: .public)
            """)
            return
        }

        entry.latencyNs = durationToNanoseconds(ContinuousClock().now - entry.sentAt)

        switch response.result {
        case .success(let filterResponse):
            switch filterResponse.result {
            case .hit:
                entry.result = .hit
            case .miss:
                entry.result = .miss
            }
        case .serviceFailure:
            entry.result = .failedToQuery
            entry.errorMessage = "serviceFailure"
        case .infrastructureFailure(let errorInfo):
            // privacy: .public is justified here because the test app ignores user input
            // entirely — error messages are purely the result of the test harness's own
            // actions (hardcoded lookup keys and filter IDs), not user-supplied data.
            log.warning("""
            message=PrivateFilterTestApp received error response
            correlationID=\(response.correlationID, privacy: .public)
            errorCode=\(errorInfo.code, privacy: .public)
            errorMessage=\(errorInfo.message, privacy: .public)
            """)
            entry.result = .failedToQuery
            entry.errorMessage = errorInfo.message
        }

        self.entries[response.correlationID] = entry

        if self.outstandingCount == 0, let continuation = self.completionContinuation {
            self.completionContinuation = nil
            continuation.resume()
        }
    }

    var outstandingCount: Int {
        self.entries.values.filter { $0.result == nil }.count
    }

    var outstandingCorrelationIDs: [PersistentService.QueryCorrelationID] {
        self.entries.filter { $0.value.result == nil }.map(\.key)
    }

    /// Wait indefinitely until every registered lookup has a response.
    ///
    /// This has no internal timeout — the process-level request timeout will kill
    /// the task if responses are lost. Acceptable in a test harness; do NOT copy
    /// this pattern in real code paths.
    func waitForAllResponses() async {
        guard self.outstandingCount > 0 else { return }
        await withCheckedContinuation { continuation in
            self.completionContinuation = continuation
        }
    }

    func buildResults(
        configurationSource: TestResults.ConfigurationSource,
        histogramCoarsenFactor: Int,
        reservoirSize: Int,
        informBlockedMs: Double,
        totalMs: Double
    ) -> TestResults {
        struct FilterAccumulator {
            var info = TestResults.FilterInfo()
            var histogram: LatencyHistogram
            var reservoir: ReservoirBuffer
            var hitProbes: [Int: TestResults.LookupResult] = [:]
            var missProbes: [Int: TestResults.LookupResult] = [:]
            var hitMismatches: [TestResults.ProbeMismatch] = []
            var missMismatches: [TestResults.ProbeMismatch] = []

            init(histogramCoarsenFactor: Int, reservoirSize: Int) {
                self.histogram = LatencyHistogram(outputCoarsenFactor: histogramCoarsenFactor)
                self.reservoir = ReservoirBuffer.empty(capacity: reservoirSize)
            }
        }

        var perFilter: [String: FilterAccumulator] = [:]

        for entry in self.entries.values {
            var acc = perFilter[entry.filterName] ?? FilterAccumulator(
                histogramCoarsenFactor: histogramCoarsenFactor,
                reservoirSize: reservoirSize
            )
            acc.info.lookups += 1

            switch entry.result {
            case .hit:
                acc.info.hits += 1
            case .miss:
                acc.info.misses += 1
            case .failedToQuery, .unknown, nil:
                acc.info.failures += 1
                if let msg = entry.errorMessage {
                    acc.info.errorCounts[msg, default: 0] += 1
                }
            }

            if let latencyNs = entry.latencyNs {
                acc.histogram.record(latencyNs)
                acc.reservoir.record(latencyNs)
            }

            let resultValue: TestResults.LookupResult = .init(entry.result)
            let keyB64 = entry.key.base64EncodedString()

            if let idx = entry.knownHitIndex {
                acc.hitProbes[idx] = resultValue
                if entry.result != .hit {
                    acc.hitMismatches.append(TestResults.ProbeMismatch(
                        probeIndex: idx,
                        keyBase64: keyB64,
                        actualResult: resultValue.rawValue
                    ))
                }
            }
            if let idx = entry.knownMissIndex {
                acc.missProbes[idx] = resultValue
                if entry.result != .miss {
                    acc.missMismatches.append(TestResults.ProbeMismatch(
                        probeIndex: idx,
                        keyBase64: keyB64,
                        actualResult: resultValue.rawValue
                    ))
                }
            }

            perFilter[entry.filterName] = acc
        }

        var filterStats: [String: TestResults.FilterInfo] = [:]
        for (name, var acc) in perFilter {
            acc.info.knownHitResults = acc.hitProbes.sorted { $0.key < $1.key }.map { $0.value.rawValue }
            acc.info.knownMissResults = acc.missProbes.sorted { $0.key < $1.key }.map { $0.value.rawValue }
            acc.info.knownHitMismatches = acc.hitMismatches.sorted { $0.probeIndex < $1.probeIndex }
            acc.info.knownMissMismatches = acc.missMismatches.sorted { $0.probeIndex < $1.probeIndex }
            acc.info.latency = TestResults.LatencyStats(
                histogram: acc.histogram,
                reservoir: acc.reservoir
            )
            filterStats[name] = acc.info
        }

        let totalFailures = filterStats.values.reduce(0) { $0 + $1.failures }

        return TestResults(
            configurationSource: configurationSource,
            totalLookups: self.entries.count,
            totalFailures: totalFailures,
            filters: filterStats,
            informBlockedToAllResponsesMs: informBlockedMs,
            totalDurationMs: totalMs
        )
    }
}

// MARK: - JSON Results

private struct TestResults: Encodable {
    typealias LookupResult = LookupTracker.LookupResult

    enum ConfigurationSource: String, Encodable {
        case clientProvided
        case defaultNoInput
        case defaultParseFailure
    }

    struct ProbeMismatch: Encodable {
        var probeIndex: Int
        var keyBase64: String
        var actualResult: String
    }

    struct HistogramBucket: Encodable {
        var bucketUpperBoundMs: Double
        var count: UInt32
    }

    struct LatencyStats: Encodable {
        var count: UInt64
        var meanMs: Double
        var p50Ms: Double
        var p95Ms: Double
        var p99Ms: Double
        var minMs: Double
        var maxMs: Double
        var histogram: [HistogramBucket]
        var sampledMs: [Double]

        init?(histogram: LatencyHistogram, reservoir: ReservoirBuffer) {
            guard histogram.count > 0 else { return nil }
            self.count = histogram.count
            self.meanMs = nsToMs(histogram.mean)
            self.p50Ms = nsToMs(Double(histogram.percentile(50)))
            self.p95Ms = nsToMs(Double(histogram.percentile(95)))
            self.p99Ms = nsToMs(Double(histogram.percentile(99)))
            self.minMs = nsToMs(Double(histogram.min))
            self.maxMs = nsToMs(Double(histogram.max))
            self.histogram = histogram.sparseBuckets().map {
                HistogramBucket(bucketUpperBoundMs: nsToMs(Double($0.upperBoundNs)), count: $0.count)
            }
            self.sampledMs = reservoir.samples.map { nsToMs(Double($0)) }
        }
    }

    struct FilterInfo: Encodable {
        var lookups: Int = 0
        var hits: Int = 0
        var misses: Int = 0
        var failures: Int = 0
        var errorCounts: [String: Int] = [:]
        var knownHitResults: [String] = []
        var knownMissResults: [String] = []
        var knownHitMismatches: [ProbeMismatch] = []
        var knownMissMismatches: [ProbeMismatch] = []
        var latency: LatencyStats?
    }

    let configurationSource: ConfigurationSource
    let totalLookups: Int
    let totalFailures: Int
    let filters: [String: FilterInfo]
    let informBlockedToAllResponsesMs: Double
    let totalDurationMs: Double
}

extension TestResults.LookupResult {
    fileprivate init(_ raw: LookupTracker.LookupResult?) {
        self = raw ?? .unknown
    }
}

// MARK: - Latency Histogram (inlined from cloudboard-vre-cli/FilterTraffic.swift)

/// A log-linear histogram for recording nanosecond latencies with bounded memory.
/// 32 major buckets × 128 sub-buckets = 4096 counters, ≤0.78% relative error, 16 KB.
private struct LatencyHistogram: Sendable {
    static let majorBuckets = 32
    static let subBuckets = 128
    static let totalBuckets = majorBuckets * subBuckets

    /// Factor by which dense buckets are coalesced when emitted via
    /// `sparseBuckets()`. Storage and percentile math operate at full
    /// resolution; only the JSON output is coarsened to keep response
    /// payloads readable.
    let outputCoarsenFactor: Int

    private var buckets: [UInt32]
    private var _count: UInt64
    private var _min: UInt64
    private var _max: UInt64
    private var _sum: UInt64

    init(outputCoarsenFactor: Int) {
        self.outputCoarsenFactor = outputCoarsenFactor
        self.buckets = [UInt32](repeating: 0, count: Self.totalBuckets)
        self._count = 0
        self._min = UInt64.max
        self._max = 0
        self._sum = 0
    }

    mutating func record(_ valueNs: UInt64) {
        let index = Self.bucketIndex(for: valueNs)
        self.buckets[index] &+= 1
        self._count &+= 1
        self._sum &+= valueNs
        if valueNs < self._min { self._min = valueNs }
        if valueNs > self._max { self._max = valueNs }
    }

    var count: UInt64 { self._count }
    var min: UInt64 { self._count > 0 ? self._min : 0 }
    var max: UInt64 { self._count > 0 ? self._max : 0 }
    var mean: Double {
        guard self._count > 0 else { return 0 }
        return Double(self._sum) / Double(self._count)
    }

    func percentile(_ p: Double) -> UInt64 {
        guard self._count > 0 else { return 0 }
        let target = UInt64(Double(self._count) * p / 100.0)
        var cumulative: UInt64 = 0
        for i in 0 ..< Self.totalBuckets {
            cumulative += UInt64(self.buckets[i])
            if cumulative > target {
                return Self.bucketUpperBound(index: i)
            }
        }
        return self._max
    }

    struct Bucket {
        let upperBoundNs: UInt64
        let count: UInt32
    }

    func sparseBuckets() -> [Bucket] {
        var out: [Bucket] = []
        var i = 0
        while i < Self.totalBuckets {
            let chunkEnd = Swift.min(i + self.outputCoarsenFactor, Self.totalBuckets)
            var sum: UInt32 = 0
            for j in i ..< chunkEnd {
                sum &+= self.buckets[j]
            }
            if sum > 0 {
                out.append(Bucket(
                    upperBoundNs: Self.bucketUpperBound(index: chunkEnd - 1),
                    count: sum
                ))
            }
            i = chunkEnd
        }
        return out
    }

    @inline(__always)
    static func bucketIndex(for value: UInt64) -> Int {
        guard value >= UInt64(self.subBuckets) else {
            return Int(value)
        }
        let significantBits = 63 - value.leadingZeroBitCount
        let major = significantBits - 6
        let shift = significantBits - 7
        let sub = Int((value >> shift) & 0x7F)
        let idx = major * self.subBuckets + sub
        return Swift.min(idx, self.totalBuckets - 1)
    }

    static func bucketUpperBound(index: Int) -> UInt64 {
        guard index >= self.subBuckets else {
            return UInt64(index)
        }
        let major = index / self.subBuckets
        let sub = index % self.subBuckets
        let significantBits = major + 6
        let shift = significantBits - 7
        let base = UInt64(0x80 | sub) << shift
        return base + (1 << shift) - 1
    }
}

// MARK: - Reservoir Sampling (Algorithm R, inlined from PrivateFilterCommon)

/// Fixed-capacity reservoir buffer using Algorithm R for uniform random sampling
/// of a stream of nanosecond latency values.
private struct ReservoirBuffer {
    let capacity: Int

    var samples: [UInt64]
    var count: Int = 0

    static func empty(capacity: Int) -> Self {
        var buf = Self(capacity: capacity, samples: [])
        buf.samples.reserveCapacity(capacity)
        return buf
    }

    mutating func record(_ valueNs: UInt64) {
        self.count += 1
        if self.count <= self.capacity {
            self.samples.append(valueNs)
        } else {
            let j = Int.random(in: 0 ..< self.count)
            if j < self.capacity {
                self.samples[j] = valueNs
            }
        }
    }
}

// MARK: - Duration Conversion

/// Convert a `Duration` to fractional milliseconds.
///
/// `Duration.components` splits the value into whole seconds and a sub-second
/// attosecond remainder:
///   - 1 second  = 1e18 attoseconds
///   - 1 millisecond = 1e15 attoseconds
///
/// So: `ms = seconds * 1000 + attoseconds / 1e15`
private func durationToMilliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000.0
        + Double(duration.components.attoseconds) / 1e15
}

private func durationToNanoseconds(_ duration: Duration) -> UInt64 {
    let secNs = UInt64(Swift.max(0, duration.components.seconds)) &* 1_000_000_000
    let attoNs = UInt64(Swift.max(0, duration.components.attoseconds) / 1_000_000_000)
    return secNs &+ attoNs
}

private func nsToMs(_ ns: Double) -> Double {
    ns / 1_000_000.0
}

// MARK: - SHA256 Hashing

/// Compute last 64 bits of SHA256 as big-endian UInt64, matching PrivateFilter's convention
/// for filter_id and hashing_id.
private func sha256Last8(_ name: String) -> UInt64 {
    PersistentService.sha256Last8(name)
}
