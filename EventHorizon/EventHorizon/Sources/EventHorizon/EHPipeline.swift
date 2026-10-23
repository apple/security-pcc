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


#if canImport(os)
import os
#endif
import AST
import Dispatch
import Foundation
import Synchronization

extension Duration {
    var asSeconds: Double {
        Double(self.components.seconds) + Double(self.components.attoseconds) / 1e18
    }
}

public protocol EHGenerator {
    func configure(_ pipeline: EHPipeline) throws
    func start(_ pipeline: EHPipeline) throws
    func stop() throws
}

public enum EHTransformResult: String, CaseIterable {
    case proceed
    case proceed_mutated
    case drop
    case halt
    case halt_ok
    case error
}

public typealias EHTransformCounterMetrics = [(any EHMetrics.EHMetricDefinitionCounterProtocol, UInt64, [(String, String)]?)]
public typealias EHTransformGaugeMetrics = [(any EHMetrics.EHMetricDefinitionGaugeProtocol, Double, [(String, String)]?)]

public typealias EHTransformReturn = (EHTransformResult, [any EHUEFEvent]?, EHTransformCounterMetrics?, EHTransformGaugeMetrics?)

public enum EHUEFCategory: String, CaseIterable, Codable, Sendable {
    case process
    case network
    case file
    case resource
    case system
    case alert
    case informational
}

public enum EHValueType: Sendable, Codable, Equatable, Hashable {
    case int(Int), string(String), boolean(Bool), double(Double)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .boolean(boolValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw EHValueTypeError.unknownValue
        }
    }
    public enum EHValueTypeError: Error {
        case unknownValue
    }
    public var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        default:
            return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        default:
            return nil
        }
    }
    public var boolValue: Bool? {
        switch self {
        case .boolean(let value):
            return value
        default:
            return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        default:
            return nil
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        }
    }
}


public struct EHEventMetadata: Sendable, Codable, Hashable {
    private final class Storage: @unchecked Sendable {
        var fields: [String: EHValueType]
        var tags: Set<String>

        init(fields: [String: EHValueType] = [:], tags: Set<String> = []) {
            self.fields = fields
            self.tags = tags
        }

        func copy() -> Storage {
            Storage(fields: fields, tags: tags)
        }
    }

    private var storage: Storage

    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }
    }

    public var fields: [String: EHValueType] {
        get { storage.fields }
        set { ensureUnique(); storage.fields = newValue }
    }

    public var tags: Set<String> {
        get { storage.tags }
        set { ensureUnique(); storage.tags = newValue }
    }

    public mutating func mutateFields(_ body: (inout [String: EHValueType]) -> Void) {
        ensureUnique()
        body(&storage.fields)
    }

    public mutating func mutateTags(_ body: (inout Set<String>) -> Void) {
        ensureUnique()
        body(&storage.tags)
    }

    public init(fields: [String: EHValueType] = [:], tags: Set<String> = []) {
        self.storage = Storage(fields: fields, tags: tags)
    }

    public init(tags: Set<String>) {
        self.storage = Storage(fields: [:], tags: tags)
    }


    private enum CodingKeys: String, CodingKey {
        case fields, tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fields = try container.decodeIfPresent([String: EHValueType].self, forKey: .fields) ?? [:]
        let tags = try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? []
        self.storage = Storage(fields: fields, tags: tags)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storage.fields, forKey: .fields)
        try container.encode(storage.tags, forKey: .tags)
    }


    public static func == (lhs: EHEventMetadata, rhs: EHEventMetadata) -> Bool {
        lhs.storage.fields == rhs.storage.fields && lhs.storage.tags == rhs.storage.tags
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage.fields)
        hasher.combine(storage.tags)
    }
}

public protocol EHUEFEvent: Sendable, Codable, CustomDebugStringConvertible {
    var metadata: EHEventMetadata {get set}
    var event_category: EHUEFCategory {get}
    var event_type: String {get}
    init()
}

extension EHUEFEvent {
    public var fields: [String: EHValueType] {
        get { metadata.fields }
        set { metadata.fields = newValue }
    }

    public var tags: Set<String> {
        get { metadata.tags }
        set { metadata.tags = newValue }
    }
}

public protocol EHFieldExtractable {
    func fieldValue(for fieldName: String) -> Any?
}

public protocol EHRegoConvertible {
    func toRegoValue() -> AST.RegoValue
}


extension EHValueType {
    public var regoValue: AST.RegoValue {
        switch self {
        case .string(let s):
            return .string(s)
        case .int(let i):
            return .number(RegoNumber(int: Int64(i)))
        case .double(let d):
            return .number(RegoNumber(decimal: Decimal(d)))
        case .boolean(let b):
            return .boolean(b)
        }
    }
}

extension Set<String> {
    public func toRegoValue() -> AST.RegoValue {
        var regoSet = Set<AST.RegoValue>()
        for s in self {
            regoSet.insert(.string(s))
        }
        return .set(regoSet)
    }
}

extension Dictionary where Key == String, Value == EHValueType {
    public func toRegoValue() -> AST.RegoValue {
        var obj = [AST.RegoValue: AST.RegoValue](minimumCapacity: self.count)
        for (key, value) in self {
            obj[.string(key)] = value.regoValue
        }
        return .object(obj)
    }
}

enum EHJSONEncoding {
    static let sharedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static let sharedEncoderUnsorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
}

extension EHUEFEvent {
    public var jsonString: String {
        let errStr = "{\"encoding_error\": true}"
        return String(data: self.jsonData ?? Data(), encoding: .utf8) ?? errStr
    }
    public var jsonData: Data? {
        guard let encoded = try? EHJSONEncoding.sharedEncoderUnsorted.encode(self) else {
            return nil
        }
        return encoded
    }
}
extension EHUEFEvent {
    public var debugDescription: String {
        return jsonString
    }
}
public protocol EHTransform: Sendable {
    func process(_ event: any EHUEFEvent) async -> EHTransformReturn
    func configure() async throws
    var name: String { get }
}
public protocol EHFileSubscriber {
    var filePaths: [String]? { get }
}

public protocol EHFrontend {
    func getConfig() -> EHDaemonConfig
    func getPipeline() -> EHPipeline
    var name: String { get }
    init()
}

extension EHFrontend {
    public func getPipeline() -> EHPipeline {
        getConfig().Pipeline
    }
}

public struct EHDaemonConfig {
    public var Generators: [EHGenerator] = []
    public var Pipeline = EHPipeline(transforms: [], configOnlyTransforms: [])
    public init(Generators: [EHGenerator], Pipeline: EHPipeline) {
        self.Generators = Generators
        self.Pipeline = Pipeline
    }
}

public typealias EHEventMapping = [String: any EHUEFEvent.Type]

public final class EHDaemon {
    public var config: EHDaemonConfig
    private let log = EHLog.withCategory(EHDaemon.self)
    private let frontend: EHFrontend?

    public let allEventsIterable: [any AllEventsIterable.Type]
    public let eventMapping: EHEventMapping

    public nonisolated(unsafe) static let defaultAllEventsIterable: [any AllEventsIterable.Type] = [
        ESClient.self,
        NStatClient.self,
        OSLogStreamer.self,
        CryptexGenerator.self,
        HeartbeatGenerator.self,
        ProcessSnapshotGenerator.self,
        EventNormalizer.self,
        MDNSResponderQueries.self,
        RestrictedExecutionModeViolation.self,
        SandboxViolation.self,
        AuditLogGenerator.self,
        PCCFrontend.PrivacyApprovedEvents.self,
        RegoEngine.self,
        EhprobeGenerator.self
    ]

    public init(_ frontend: EHFrontend, allEventsIterable: [any AllEventsIterable.Type] = EHDaemon.defaultAllEventsIterable) {
        self.config = frontend.getConfig()
        self.frontend = frontend
        self.allEventsIterable = allEventsIterable
        self.eventMapping = Self.getEventMapping(allEventsIterable: allEventsIterable)
    }
    public init(_ config: EHDaemonConfig, allEventsIterable: [any AllEventsIterable.Type] = EHDaemon.defaultAllEventsIterable) {
        self.config = config
        self.frontend = nil
        self.allEventsIterable = allEventsIterable
        self.eventMapping = Self.getEventMapping(allEventsIterable: allEventsIterable)
    }

    private static func getEventMapping(allEventsIterable: [any AllEventsIterable.Type]) -> EHEventMapping {
        var eventMapping: EHEventMapping = [:]
        for events in allEventsIterable {
            for event in events.allEvents {
                eventMapping[event.init().event_type] = event
            }
        }
        return eventMapping
    }

    public func runDaemon() throws {
        if let fe = frontend {
            let fen = fe.name
            EHInfo.shared.currentFrontend = fen
        }
        os_log(.info, log: log, "Initializing")

        Task {
            await EHMetrics.shared.preRegisterMetrics(
                counters: EHMetrics.Labels.Counters.self,
                gauges: EHMetrics.Labels.Gauges.self
            )
        }

        nonisolated(unsafe) var configureError: Error?
        let pipeline = config.Pipeline
        let semaphore = DispatchSemaphore(value: 0)
        Task { @Sendable in
            do {
                try await pipeline.configure()
            } catch {
                configureError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let configureError {
            throw configureError
        }

        var activeGenerators: [EHGenerator] = []
        for generator in config.Generators {
            do {
                try generator.configure(config.Pipeline)
                try generator.start(config.Pipeline)
                activeGenerators.append(generator)
            } catch {
                os_log(
                    .error, log: log,
                    "Generator %{public}@ failed to initialize: %{public}@, skipping",
                    String(describing: type(of: generator)), "\(error)"
                )
                try? generator.stop()
            }
        }
        config.Generators = activeGenerators
        os_log(.info, log: log, "Daemon initialized and is listening for events")
    }

    public func runForever() throws {
        try self.runDaemon()
        dispatchMain()
    }

    public func stop() {
        for gen in config.Generators {
            try? gen.stop()
        }
    }
}

enum ExitCodes: Int32, CaseIterable {
    case success = 0
    case failure = 1
    case halt = 2
}

public final class EHPipeline: Sendable {
    private let log = EHLog.withCategory(EHPipeline.self)

    public let transforms: [EHTransform]
    public let configOnlyTransforms: [EHTransform]?
    public let maxDepth: Int

    public init (transforms: [EHTransform], configOnlyTransforms: [EHTransform]? = nil, maxDepth: Int = 10000) {
        self.transforms = transforms
        self.configOnlyTransforms = configOnlyTransforms
        self.maxDepth = maxDepth
    }

    let depth = Atomic<Int>(0)

    func configure() async throws {
        if let configOnlyTransforms = self.configOnlyTransforms {
            for transform in configOnlyTransforms {
                try await transform.configure()
            }
        }
        for transform in self.transforms {
            try await transform.configure()
        }
    }

    public func process(_ event: any EHUEFEvent, skipToTranformIndex: Int = 0) async {
        let metricsCache = PipelineMetricsCache.shared
        var curEvent: (any EHUEFEvent)? = event
        let dET: [(String, String)] = [(EHMetrics.Labels.Dimensions.event_type.rawValue, event.event_type)]
        let clock = ContinuousClock()
        let startTime = clock.now

        metricsCache.increment(EHMetrics.Labels.Counters.pipeline_event_ingest_count, dimensions: dET)

        let depth = self.depth.add(1, ordering: .acquiringAndReleasing)
        metricsCache.set(EHMetrics.Labels.Gauges.pipeline_queue_depth, value: Double(depth.newValue), dimensions: nil)
        defer { self.depth.subtract(1, ordering: .releasing) }

        if depth.newValue > maxDepth {
            metricsCache.increment(EHMetrics.Labels.Counters.pipeline_event_ingest_drop_count, dimensions: dET)
            metricsCache.set(EHMetrics.Labels.Gauges.pipeline_event_latency, value: (clock.now - startTime).asSeconds, dimensions: dET)
            return
        }

        for (transform_idx, transform) in self.transforms.enumerated() {
            if skipToTranformIndex > 0 && transform_idx < skipToTranformIndex {
                continue
            }
            let tStart = clock.now
            let (result, newEvents, transformMetricsCounters, transformMetricsGauges) = await transform.process(curEvent!)

            if let transformMetricsCounters {
                for (metric, value, dims) in transformMetricsCounters {
                    metricsCache.increment(metric, by: value, dimensions: dims)
                }
            }
            if let transformMetricsGauges {
                for (metric, value, dims) in transformMetricsGauges {
                    metricsCache.set(metric, value: value, dimensions: dims)
                }
            }

            let mDim: [(String, String)] = [
                (EHMetrics.Labels.Dimensions.event_type.rawValue, event.event_type),
                (EHMetrics.Labels.Dimensions.transform_id.rawValue, transform.name),
                (EHMetrics.Labels.Dimensions.transform_result.rawValue, result.rawValue)
            ]
            let tDuration = clock.now - tStart
            metricsCache.set(EHMetrics.Labels.Gauges.pipeline_transform_latency, value: tDuration.asSeconds, dimensions: mDim)
            metricsCache.increment(EHMetrics.Labels.Counters.pipeline_transform_count, dimensions: mDim)

            if let newEvents = newEvents {
                guard let firstEvent = newEvents.first else {
                    break
                }
                curEvent = firstEvent
                if newEvents.count > 1 {
                    metricsCache.increment(
                        EHMetrics.Labels.Counters.pipeline_transform_created_event_count,
                        by: UInt64(newEvents.count),
                        dimensions: mDim
                    )
                    if transform_idx < self.transforms.count - 1 {
                        Task {
                            let new_events = newEvents.dropFirst()
                            for ne in new_events {
                                await process(ne, skipToTranformIndex: transform_idx + 1)
                            }
                        }
                    }
                }
            }

            var outerBreak = false
            switch result {
            case .proceed, .proceed_mutated, .error:
                break
            case .halt:
                os_log(.error, log: log, "Pipeline halted due to transform \(String(describing: transform), privacy: .public)")
                exit(ExitCodes.halt.rawValue)
            case .halt_ok:
                os_log(.error, log: log, "Pipeline halted ok due to transform \(String(describing: transform), privacy: .public)")
                exit(ExitCodes.success.rawValue)
            case .drop:
                outerBreak = true
            }
            if outerBreak {
                break
            }
        }
        metricsCache.set(EHMetrics.Labels.Gauges.pipeline_event_latency, value: (clock.now - startTime).asSeconds, dimensions: dET)
    }
}

public protocol AllEventsIterable {
    static var allEvents: [any EHUEFEvent.Type] { get }
}
