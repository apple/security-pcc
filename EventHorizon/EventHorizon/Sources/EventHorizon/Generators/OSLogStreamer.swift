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


#if canImport(LoggingSupport)
import LoggingSupport
#endif
import Foundation
import Synchronization

public class OSLogStreamer: EHGenerator, AllEventsIterable {
    private static let log = EHLog.withCategory(OSLogStreamer.self)
    public static let allEvents: [any EHUEFEvent.Type] = [ OSLogEvent.self ]
    public init(predicates: [any OSLogStreamer.PredicatePlugin.Type]) {
        self.predicates = predicates
    }

    protocol EventParser {
        init()
        func parse(_ fromOSLogEvent: OSLogStreamer.OSLogEvent) -> (any EHUEFEvent)?
    }

    public protocol PredicatePlugin: Sendable, AllEventsIterable {
        func getPredicate() -> String
        func parse(_ fromOSLogEvent: OSLogStreamer.OSLogEvent) -> (any EHUEFEvent)?
        func logMessageMatch(_ event: OSLogStreamer.OSLogEvent) -> Bool
        init()
    }

    private let predicates: [any OSLogStreamer.PredicatePlugin.Type]

    public func configure(_ pipeline: EHPipeline) throws {}

    enum EventTypes: String, CaseIterable {
        case log_entry
    }
    public struct OSLogEvent: EHUEFEvent {
        public init(
            tags: Set<String> = Set<String>(),
            fields: [String: EHValueType] = [:],
            label: String = "",
            uid: uid_t = 0,
            process: String = "",
            processID: pid_t = 0,
            category: String = "",
            subsystem: String = "",
            sender: String = "",
            composedMessage: String = "",
            timestamp: Date = Date()) {
            self.metadata = EHEventMetadata(fields: fields, tags: tags)
            self.label = label
            self.uid = uid
            self.process = process
            self.processID = processID
            self.category = category
            self.subsystem = subsystem
            self.sender = sender
            self.composedMessage = composedMessage
            self.timestamp = timestamp
        }

        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .system
        public var event_type: String = OSLogStreamer.EventTypes.log_entry.rawValue

        public var label: String = ""
        public var uid: uid_t = 0
        public var process: String = ""
        public var processID: pid_t = 0
        public var category: String = ""
        public var subsystem: String = ""
        public var sender: String = ""
        public var composedMessage: String = ""
        public var timestamp = Date()
        public var formatString: String?
        public init() {}
        #if canImport(LoggingSupport)
        public init(from: OSLogEventProxy) {
            self.uid = from.userIdentifier
            self.process = from.process ?? ""
            self.processID = from.processIdentifier
            self.category = from.category ?? ""
            self.subsystem = from.subsystem ?? ""
            self.sender = from.sender ?? ""
            self.composedMessage = from.composedMessage ?? ""
            self.timestamp = from.date
            self.formatString = from.formatString
        }
        #endif
    }

    public func stop() throws {
        #if canImport(LoggingSupport)
        serviceTask?.cancel()
        serviceTask = nil
        #endif
    }

    deinit {
        try? self.stop()
    }
    #if canImport(LoggingSupport)
    @discardableResult
    static func pollStore(
        from beginDate: Date,
        eventHandler: ((OSLogEvent, OSLogEventStream) -> Void)? = nil,
        predicate: NSPredicate? = nil,
        invalidationHandler: ((OSLogEventStreamInvalidation, OSLogEventStreamPosition) -> Void)? = nil
    ) async throws -> [OSLogEvent] {
        let store = OSLogEventStore.local()
        store.setUpgradeConfirmationHandler {
            return false
        }
        let eventSource = try await store.prepare()
        return try await withCheckedThrowingContinuation { continuation in
            lazy var capturedEvents: [OSLogEvent] = []
            let stream = OSLogEventStream(source: eventSource)
            let flags: OSLogEventStreamFlags = [
                .includePrivate,
                .includeInfo,
                .includeSignposts,
                .doNotTrackActivities
            ]
            stream.flags = flags
            stream.filterPredicate = predicate
            stream.setEventHandler { proxy in
                let event = OSLogEvent(from: proxy)
                capturedEvents.append(event)
                eventHandler?(event, stream)
            }
            stream.invalidationHandler = { reason, position in
                invalidationHandler?(reason, position)
                continuation.resume(returning: capturedEvents)
            }
            stream.activate(from: beginDate)
        }
    }

    static func streamStore(
        from beginDate: Date,
        eventHandler: (@Sendable (OSLogEvent) -> Void)? = nil,
        predicate: NSPredicate? = nil,
        invalidationHandler: (@Sendable (OSLogEventStreamInvalidation, OSLogEventStreamPosition) -> Void)? = nil,
        droppedEventHandler: (() -> Void?)? = nil
    ) async throws {
        let liveStore = OSLogEventLiveStore.liveLocal()
        let eventSource = try await liveStore.prepare()
        nonisolated(unsafe) let stream = OSLogEventLiveStream(liveSource: eventSource)
        let flags: OSLogEventStreamFlags = [
            .includePrivate,
            .includeInfo,
            .includeSignposts,
            .doNotTrackActivities
        ]
        stream.flags = flags
        stream.filterPredicate = predicate
        let droppedCount = Atomic<Int>(0)
        await withCheckedContinuation { continuation in
            stream.setDroppedEventHandler { _ in
                droppedEventHandler?()
                droppedCount.add(1, ordering: .relaxed)
            }
            stream.setEventHandler { proxy in
                if Task.isCancelled {
                    stream.invalidate()
                } else {
                    eventHandler?(OSLogEvent(from: proxy))
                }
            }
            stream.invalidationHandler = { reason, position in
                os_log(.info, log: log, "Log live stream has ended")
                if reason != .endOfStream, reason != .byRequest {
                    os_log(.info, log: log, "Stream did not end due to being at the end or requested, reason: \(reason.rawValue, privacy: .public)")
                }
                invalidationHandler?(reason, position)
                os_log(.debug, log: log, "Stream dropped \(droppedCount.load(ordering: .relaxed)) events")
                continuation.resume()
            }
            os_log(.error, log: log, "Starting live log stream")
            stream.activate()
        }
    }
    #endif
    private var serviceTask: Task<(), Error>?
    enum OSLogStreamerError: Error {
        case unsupportedPlatform
    }

    public func start(_ pipeline: EHPipeline) throws {
        #if !canImport(LoggingSupport)
        throw OSLogStreamerError.unsupportedPlatform
        #else
        guard serviceTask == nil else {
           return
        }
        serviceTask = Task { [predicates = predicates] in
            repeat {
                let start = Date()
                let instantiatedPredicates = predicates.map { $0.init() }
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for predicateFilter in instantiatedPredicates {
                            group.addTask {
                                let nsPredicate = NSPredicate(format: predicateFilter.getPredicate())
                                let filterLabel = String(describing: predicateFilter)
                                let (eventStream, eventContinuation) = AsyncStream<any EHUEFEvent>.makeStream()
                                async let consuming: Void = {
                                    for await event in eventStream {
                                        await pipeline.process(event)
                                    }
                                }()
                                try await OSLogStreamer.streamStore(
                                    from: start,
                                    eventHandler: { (event: OSLogEvent) in
                                        guard predicateFilter.logMessageMatch(event) else {
                                            return
                                        }
                                        if let parsed = predicateFilter.parse(event) {
                                            eventContinuation.yield(parsed)
                                        } else {
                                            var labeledEvent = event
                                            labeledEvent.label = filterLabel
                                            eventContinuation.yield(labeledEvent)
                                        }
                                    },
                                    predicate: nsPredicate
                                )
                                eventContinuation.finish()
                                await consuming
                            }
                        }
                        try await group.waitForAll()
                    }
                } catch {
                    os_log(.error, log: OSLogStreamer.log, "OSLogStreamer: Error while streaming logs: \(error, privacy: .public)")
                }
            } while !Task.isCancelled
        }
        #endif
    }
}


extension OSLogStreamer.OSLogEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "label": return label
        case "uid": return uid
        case "process": return process
        case "processID": return processID
        case "category": return category
        case "subsystem": return subsystem
        case "sender": return sender
        case "composedMessage": return composedMessage
        case "timestamp": return timestamp
        case "formatString": return formatString
        default: return nil
        }
    }
}


import AST

private enum RK {
    static let event_type: AST.RegoValue = .string("event_type")
    static let event_category: AST.RegoValue = .string("event_category")
    static let tags: AST.RegoValue = .string("tags")
    static let fields: AST.RegoValue = .string("fields")
    static let label: AST.RegoValue = .string("label")
    static let uid: AST.RegoValue = .string("uid")
    static let process: AST.RegoValue = .string("process")
    static let processID: AST.RegoValue = .string("processID")
    static let category: AST.RegoValue = .string("category")
    static let subsystem: AST.RegoValue = .string("subsystem")
    static let sender: AST.RegoValue = .string("sender")
    static let composedMessage: AST.RegoValue = .string("composedMessage")
    static let timestamp: AST.RegoValue = .string("timestamp")
    static let formatString: AST.RegoValue = .string("formatString")
}

extension OSLogStreamer.OSLogEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.label] = .string(label)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.process] = .string(process)
        obj[RK.processID] = .number(RegoNumber(int: Int64(processID)))
        obj[RK.category] = .string(category)
        obj[RK.subsystem] = .string(subsystem)
        obj[RK.sender] = .string(sender)
        obj[RK.composedMessage] = .string(composedMessage)
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp.timeIntervalSince1970)))
        if let formatString {
            obj[RK.formatString] = .string(formatString)
        }
        return .object(obj)
    }
}
