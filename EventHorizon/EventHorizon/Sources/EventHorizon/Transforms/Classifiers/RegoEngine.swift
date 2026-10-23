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
#if canImport(Compression)
import Compression
#elseif canImport(Czlib)
import Czlib
#endif
import AST
import Foundation
import Rego

public final class RegoEngine: EHTransform, EHFileSubscriber, AllEventsIterable, @unchecked Sendable {
    public static let allEvents: [any EHUEFEvent.Type] = [ AlertEvent.self ]
    public let name = "RegoEngine"
    public var filePaths: [String]? { configuredRequiredPaths ?? requiredPaths }

    private let log = EHLog.withCategory(RegoEngine.self)

    private let bundlePaths: [OPA.Engine.BundlePath]
    private let inMemoryBundles: [String: Data]
    private let compressedBundleData: [String: [UInt8]]
    private let compressedBundleDataJSON: [String: [UInt8]]
    private let query: String
    private let requiredPaths: [String]?
    private let enableAlertTags: Set<String>?
    private let eventTypeEntrypoints: [String: String]?
    private let metadataEntrypoint: String?

    private var preparedQuery: OPA.Engine.PreparedQuery?
    private var preparedQueries: [String: OPA.Engine.PreparedQuery]?
    private var configuredRequiredPaths: [String]?
    private var supportedEventTypes: Set<String>?

    public init(
        bundlePaths: [OPA.Engine.BundlePath] = [],
        inMemoryBundles: [String: Data] = [:],
        compressedBundleData: [String: [UInt8]] = [:],
        compressedBundleDataJSON: [String: [UInt8]] = [:],
        query: String = "data.eventhorizon.rules.output",
        requiredPaths: [String]? = nil,
        enableAlertTags: Set<String>? = nil,
        eventTypeEntrypoints: [String: String]? = nil,
        metadataEntrypoint: String? = nil
    ) {
        self.bundlePaths = bundlePaths
        self.inMemoryBundles = inMemoryBundles
        self.compressedBundleData = compressedBundleData
        self.compressedBundleDataJSON = compressedBundleDataJSON
        self.query = query
        self.requiredPaths = requiredPaths
        self.enableAlertTags = enableAlertTags
        self.eventTypeEntrypoints = eventTypeEntrypoints
        self.metadataEntrypoint = metadataEntrypoint
    }

    public func configure() async throws {
        if eventTypeEntrypoints != nil {
            try await prepareMultiPlanEngine()
        } else {
            try await prepareSinglePlanEngine()
        }
    }

    private func prepareSinglePlanEngine() async throws {
        try await prepareEngine()
        if let pq = self.preparedQuery {
            let rs = try await pq.evaluate(input: .object([:]))
            let output = Self.extractOutput(from: rs)
            if !output.requiredPaths.isEmpty {
                self.configuredRequiredPaths = Array(output.requiredPaths)
            }
            if !output.supportedEventTypes.isEmpty {
                self.supportedEventTypes = output.supportedEventTypes
            }
        }
    }

    private func prepareMultiPlanEngine() async throws {
        guard let entrypoints = eventTypeEntrypoints else {
            return
        }

        var bundles: [String: OPA.Bundle] = [:]
        for (bundleName, planData) in inMemoryBundles {
            let planFile = BundleFile(url: URL(fileURLWithPath: "plan.json"), data: planData)
            let bundle = try OPA.Bundle(planFiles: [planFile])
            bundles[bundleName] = bundle
        }

        for (bundleName, compressedData) in compressedBundleData {
            let decompressed = try Self.decompressGzip(Data(compressedData))
            let planFile = BundleFile(url: URL(fileURLWithPath: "plan.json"), data: decompressed)
            var bundleData: AST.RegoValue = .object([:])
            if let compressedJSON = compressedBundleDataJSON[bundleName], !compressedJSON.isEmpty {
                let decompressedJSON = try Self.decompressGzip(Data(compressedJSON))
                bundleData = try AST.RegoValue(jsonData: decompressedJSON)
            }
            bundles[bundleName] = try OPA.Bundle(planFiles: [planFile], data: bundleData)
        }

        var uniqueEntrypoints = Set(entrypoints.values)
        if let metaEP = metadataEntrypoint {
            uniqueEntrypoints.insert(metaEP)
        }

        var entrypointToPQ: [String: OPA.Engine.PreparedQuery] = [:]
        for ep in uniqueEntrypoints {
            var engine = OPA.Engine(
                bundles: bundles, customBuiltins: CustomRegoBuiltins.all,
                customSyncBuiltins: CustomRegoBuiltins.allSync
            )
            entrypointToPQ[ep] = try await engine.prepareForEvaluation(query: ep)
        }

        var pqMap: [String: OPA.Engine.PreparedQuery] = [:]
        for (eventType, ep) in entrypoints {
            pqMap[eventType] = entrypointToPQ[ep]
        }
        self.preparedQueries = pqMap

        if let metaEP = metadataEntrypoint, let metaPQ = entrypointToPQ[metaEP] {
            let rs = try await metaPQ.evaluate(input: .object([:]))
            let paths = Self.extractRequiredPaths(from: rs)
            if !paths.isEmpty {
                self.configuredRequiredPaths = Array(paths)
            }
        }
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        if let pqMap = preparedQueries {
            return await processMultiPlan(event, preparedQueries: pqMap)
        }

        guard let pq = preparedQuery else {
            return (.proceed, [event], nil, nil)
        }

        if let supported = supportedEventTypes, !supported.contains(event.event_type) {
            return (.proceed, [event], nil, nil)
        }

        return await evaluateAndApply(event, preparedQuery: pq)
    }

    private func processMultiPlan(
        _ event: any EHUEFEvent,
        preparedQueries: [String: OPA.Engine.PreparedQuery]
    ) async -> EHTransformReturn {
        guard let pq = preparedQueries[event.event_type] ?? preparedQueries["_default"] else {
            return (.proceed, [event], nil, nil)
        }
        return await evaluateAndApply(event, preparedQuery: pq)
    }

    private func evaluateAndApply(
        _ event: any EHUEFEvent,
        preparedQuery pq: OPA.Engine.PreparedQuery
    ) async -> EHTransformReturn {
        guard let convertible = event as? EHRegoConvertible else {
            os_log(
                .error, log: log,
                "RegoEngine: event type %{public}@ does not conform to EHRegoConvertible",
                event.event_type
            )
            return (.proceed, [event], nil, nil)
        }

        var input = convertible.toRegoValue()

        if let enableAlertTags {
            input = Self.injectRequirements(input: input, requirements: enableAlertTags)
        }

        let resultSet: ResultSet
        do {
            resultSet = try pq.evaluateSync(input: input)
        } catch {
            os_log(
                .error, log: log,
                "RegoEngine: query evaluation failed: %{public}@",
                String(describing: error)
            )
            return (.proceed, [event], nil, nil)
        }

        let output = Self.extractOutput(from: resultSet)

        if output.tags.isEmpty && output.alerts.isEmpty {
            return (.proceed, [event], nil, nil)
        }

        var tagAlerts: [RegoAlert] = []
        var realAlerts: [RegoAlert] = []
        for alert in output.alerts {
            if alert.type == "tag" {
                tagAlerts.append(alert)
            } else {
                realAlerts.append(alert)
            }
        }

        var mutatedEvent = event
        mutatedEvent.metadata.mutateTags { tags in
            tags.formUnion(output.tags)

            for alert in tagAlerts {
                tags.insert(alert.id)
            }

            for alert in realAlerts {
                tags.formUnion(alert.tags)
            }
        }

        if realAlerts.isEmpty {
            return (.proceed_mutated, [mutatedEvent], nil, nil)
        }

        var outputEvents: [any EHUEFEvent] = [mutatedEvent]
        let now = Date().timeIntervalSince1970
        for alert in realAlerts {
            var alertEvent = RegoEngine.AlertEvent()
            alertEvent.timestamp = now
            alertEvent.identifier = alert.id
            alertEvent.name = alert.id
            alertEvent.confidence = alert.confidence
            alertEvent.severity = alert.severity
            alertEvent.sourceEvent = mutatedEvent
            alertEvent.fields = mutatedEvent.fields
            alertEvent.tags = mutatedEvent.tags
            outputEvents.append(alertEvent)
        }

        return (.proceed_mutated, outputEvents, nil, nil)
    }


    struct RegoOutput {
        let tags: Set<String>
        let alerts: [RegoAlert]
        let requiredPaths: Set<String>
        let supportedEventTypes: Set<String>
    }

    struct RegoAlert {
        let id: String
        let confidence: Double
        let severity: Double
        let tags: Set<String>
        let type: String?
    }

    static func extractOutput(from resultSet: ResultSet) -> RegoOutput {
        for result in resultSet {
            let value: AST.RegoValue
            if case .object(let obj) = result,
               let inner = obj[.string("result")] {
                value = inner
            } else {
                value = result
            }

            if case .object(let outputObj) = value {
                let hasTags = outputObj[.string("tags")] != nil
                let hasAlerts = outputObj[.string("alerts")] != nil

                if hasTags || hasAlerts {
                    var tags = Set<String>()
                    if let tagsValue = outputObj[.string("tags")] {
                        collectStringTags(from: tagsValue, into: &tags)
                    }

                    var alerts: [RegoAlert] = []
                    if let alertsValue = outputObj[.string("alerts")] {
                        switch alertsValue {
                        case .set(let alertSet):
                            for alertValue in alertSet {
                                if let alert = parseAlert(from: alertValue) {
                                    alerts.append(alert)
                                }
                            }
                        case .array(let alertArray):
                            for alertValue in alertArray {
                                if let alert = parseAlert(from: alertValue) {
                                    alerts.append(alert)
                                }
                            }
                        default:
                            break
                        }
                    }

                    var requiredPaths = Set<String>()
                    if let pathsValue = outputObj[.string("required_paths")] {
                        collectStringTags(from: pathsValue, into: &requiredPaths)
                    }

                    var supportedEventTypes = Set<String>()
                    if let typesValue = outputObj[.string("supported_event_types")] {
                        collectStringTags(from: typesValue, into: &supportedEventTypes)
                    }

                    return RegoOutput(
                        tags: tags,
                        alerts: alerts,
                        requiredPaths: requiredPaths,
                        supportedEventTypes: supportedEventTypes
                    )
                }
            }
        }

        return RegoOutput(tags: [], alerts: [], requiredPaths: [], supportedEventTypes: [])
    }

    private static func parseAlert(from value: AST.RegoValue) -> RegoAlert? {
        guard case .object(let obj) = value else {
            return nil
        }

        guard let idValue = obj[.string("id")],
              case .string(let id) = idValue
        else {
            return nil
        }

        let confidence: Double
        if let confValue = obj[.string("confidence")] {
            switch confValue {
            case .number(let n):
                confidence = n.doubleValue
            default:
                confidence = 0
            }
        } else {
            confidence = 0
        }

        let severity: Double
        if let sevValue = obj[.string("severity")] {
            switch sevValue {
            case .number(let n):
                severity = n.doubleValue
            default:
                severity = 0
            }
        } else {
            severity = 0
        }

        var tags = Set<String>()
        if let tagsValue = obj[.string("tags")] {
            switch tagsValue {
            case .set(let tagSet):
                for tag in tagSet {
                    if case .string(let s) = tag {
                        tags.insert(s)
                    }
                }
            case .array(let tagArray):
                for tag in tagArray {
                    if case .string(let s) = tag {
                        tags.insert(s)
                    }
                }
            default:
                break
            }
        }

        var type: String?
        if let typeValue = obj[.string("type")],
           case .string(let t) = typeValue {
            type = t
        }

        return RegoAlert(id: id, confidence: confidence, severity: severity, tags: tags, type: type)
    }


    private static func extractRequiredPaths(from resultSet: ResultSet) -> Set<String> {
        for result in resultSet {
            let value: AST.RegoValue
            if case .object(let obj) = result,
               let inner = obj[.string("result")] {
                value = inner
            } else {
                value = result
            }

            if case .object(let outputObj) = value,
               let pathsValue = outputObj[.string("required_paths")] {
                var paths = Set<String>()
                collectStringTags(from: pathsValue, into: &paths)
                return paths
            }
        }
        return []
    }

    private static func collectStringTags(from value: AST.RegoValue, into tags: inout Set<String>) {
        switch value {
        case .set(let tagSet):
            for tag in tagSet {
                if case .string(let s) = tag {
                    tags.insert(s)
                }
            }
        case .array(let tagArray):
            for tag in tagArray {
                if case .string(let s) = tag {
                    tags.insert(s)
                }
            }
        case .string(let s):
            tags.insert(s)
        default:
            break
        }
    }

    private func prepareEngine() async throws {
        var bundles: [String: OPA.Bundle] = [:]
        for (bundleName, planData) in inMemoryBundles {
            let planFile = BundleFile(url: URL(fileURLWithPath: "plan.json"), data: planData)
            let bundle = try OPA.Bundle(planFiles: [planFile])
            bundles[bundleName] = bundle
        }

        for (bundleName, compressedData) in compressedBundleData {
            let decompressed = try Self.decompressGzip(Data(compressedData))
            let planFile = BundleFile(url: URL(fileURLWithPath: "plan.json"), data: decompressed)

            var bundleData: AST.RegoValue = .object([:])
            if let compressedJSON = compressedBundleDataJSON[bundleName], !compressedJSON.isEmpty {
                let decompressedJSON = try Self.decompressGzip(Data(compressedJSON))
                bundleData = try AST.RegoValue(jsonData: decompressedJSON)
            }

            bundles[bundleName] = try OPA.Bundle(planFiles: [planFile], data: bundleData)
        }

        if !bundlePaths.isEmpty {
            var engine = OPA.Engine(
                bundlePaths: bundlePaths, customBuiltins: CustomRegoBuiltins.all,
                customSyncBuiltins: CustomRegoBuiltins.allSync
            )
            preparedQuery = try await engine.prepareForEvaluation(query: query)
        } else {
            var engine = OPA.Engine(
                bundles: bundles, customBuiltins: CustomRegoBuiltins.all,
                customSyncBuiltins: CustomRegoBuiltins.allSync
            )
            preparedQuery = try await engine.prepareForEvaluation(query: query)
        }
    }


    enum DecompressionError: Error {
        case invalidGzipData
        case decompressionFailed(String)
    }

    #if canImport(Compression)
    static func decompressGzip(_ data: Data) throws -> Data {
        guard data.count >= 10,
              data[data.startIndex] == 0x1F,
              data[data.startIndex + 1] == 0x8B,
              data[data.startIndex + 2] == 0x08
        else {
            throw DecompressionError.invalidGzipData
        }

        let flags = data[data.startIndex + 3]
        var offset = 10

        if flags & 0x04 != 0 {
            guard offset + 2 <= data.count else {
                throw DecompressionError.invalidGzipData
            }
            let extraLen = Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
            offset += 2 + extraLen
        }
        if flags & 0x08 != 0 {
            while offset < data.count && data[data.startIndex + offset] != 0 {
                offset += 1
            }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < data.count && data[data.startIndex + offset] != 0 {
                offset += 1
            }
            offset += 1
        }
        if flags & 0x02 != 0 {
            offset += 2
        }

        guard data.startIndex + offset + 8 <= data.endIndex else {
            throw DecompressionError.invalidGzipData
        }

        let deflateData = data[data.startIndex + offset ..< data.endIndex - 8]

        let isizeOffset = data.endIndex - 4
        let isize = UInt32(data[isizeOffset])
            | (UInt32(data[isizeOffset + 1]) << 8)
            | (UInt32(data[isizeOffset + 2]) << 16)
            | (UInt32(data[isizeOffset + 3]) << 24)
        let sizeHint = isize > 0 ? Int(isize) : deflateData.count * 8

        var outputSize = sizeHint + 256
        for attempt in 0..<4 {
            var output = Data(count: outputSize)
            let decodedSize: Int = deflateData.withUnsafeBytes { srcPtr in
                output.withUnsafeMutableBytes { dstPtr in
                    compression_decode_buffer(
                        dstPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        outputSize,
                        srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        deflateData.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }

            guard decodedSize > 0 else {
                throw DecompressionError.decompressionFailed(
                    "compression_decode_buffer returned 0 on attempt \(attempt)"
                )
            }

            if decodedSize < outputSize {
                output.removeSubrange(decodedSize..<output.count)
                return output
            }

            outputSize = decodedSize * 4
        }

        throw DecompressionError.decompressionFailed(
            "Decompressed data exceeds buffer after retries"
        )
    }
    #elseif canImport(Czlib)
    static func decompressGzip(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw DecompressionError.invalidGzipData
        }
        let compressedBytes = [UInt8](data)
        var outBuf: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        var zlibErr: Int32 = 0
        let rc = compressedBytes.withUnsafeBufferPointer { srcBuf -> Int32 in
            eh_gzip_decompress(srcBuf.baseAddress, srcBuf.count, &outBuf, &outLen, &zlibErr)
        }
        defer {
            if let outBuf {
                free(outBuf)
            }
        }
        switch rc {
        case 0:
            guard let outBuf else {
                return Data()
            }
            return Data(bytes: outBuf, count: outLen)
        case -1:
            throw DecompressionError.invalidGzipData
        case -2:
            throw DecompressionError.decompressionFailed("inflateInit2 failed: \(zlibErr)")
        case -3:
            throw DecompressionError.decompressionFailed("inflate stalled: truncated gzip data")
        case -4:
            throw DecompressionError.decompressionFailed("inflate failed: \(zlibErr)")
        case -5:
            throw DecompressionError.decompressionFailed("output allocation failure")
        default:
            throw DecompressionError.decompressionFailed("unknown error: \(rc)")
        }
    }
    #endif

    private static func injectRequirements(
        input: AST.RegoValue,
        requirements: Set<String>
    ) -> AST.RegoValue {
        guard case .object(var obj) = input else {
            return input
        }
        let reqSet = Set(requirements.map { AST.RegoValue.string($0) })
        obj[.string("_requirements")] = .set(reqSet)
        return .object(obj)
    }

    public struct AlertEvent: EHUEFEvent {
        public init() {}
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .alert
        public var event_type: String = "alert"

        public var timestamp: TimeInterval = 0
        public var name: String = ""
        public var identifier: String = ""
        public var severity: Double = 0
        public var confidence: Double = 0

        @CodableIgnored public var sourceEvent: (any EHUEFEvent)?

        private enum CodingKeys: String, CodingKey {
            case metadata, event_category, event_type
            case timestamp, name, identifier, severity, confidence, payload
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(metadata, forKey: .metadata)
            try container.encode(event_category, forKey: .event_category)
            try container.encode(event_type, forKey: .event_type)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(name, forKey: .name)
            try container.encode(identifier, forKey: .identifier)
            try container.encode(severity, forKey: .severity)
            try container.encode(confidence, forKey: .confidence)
            if let sourceEvent {
                try sourceEvent.encode(to: container.superEncoder(forKey: .payload))
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.metadata = try container.decodeIfPresent(EHEventMetadata.self, forKey: .metadata) ?? EHEventMetadata()
            self.event_category = try container.decodeIfPresent(EHUEFCategory.self, forKey: .event_category) ?? .alert
            self.event_type = try container.decodeIfPresent(String.self, forKey: .event_type) ?? "alert"
            self.timestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .timestamp) ?? 0
            self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            self.identifier = try container.decodeIfPresent(String.self, forKey: .identifier) ?? ""
            self.severity = try container.decodeIfPresent(Double.self, forKey: .severity) ?? 0
            self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        }
    }
}
private enum RK {
    static let event_type: AST.RegoValue = .string("event_type")
    static let event_category: AST.RegoValue = .string("event_category")
    static let tags: AST.RegoValue = .string("tags")
    static let fields: AST.RegoValue = .string("fields")
    static let timestamp: AST.RegoValue = .string("timestamp")
    static let name: AST.RegoValue = .string("name")
    static let identifier: AST.RegoValue = .string("identifier")
    static let severity: AST.RegoValue = .string("severity")
    static let confidence: AST.RegoValue = .string("confidence")
}

extension RegoEngine.AlertEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.name] = .string(name)
        obj[RK.identifier] = .string(identifier)
        obj[RK.severity] = .number(RegoNumber(decimal: Decimal(severity)))
        obj[RK.confidence] = .number(RegoNumber(decimal: Decimal(confidence)))
        return .object(obj)
    }
}
