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


import Foundation
import Synchronization
#if canImport(os)
import os
#endif

public final class HeartbeatGenerator: EHGenerator, AllEventsIterable, Sendable {
    public static let allEvents: [any EHUEFEvent.Type] = [
        HeartbeatEvent.self
    ]

    private let log = EHLog.withCategory(HeartbeatGenerator.self)
    private let metricOnly: Bool
    public func stop() throws {
        self.serviceTask.withLock { $0?.cancel() }
    }

    public struct HeartbeatEvent: EHUEFEvent {
        public init() {}
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .system
        public var event_type: String = "heartbeat"

        public var timestamp: Double = 0
        public var resident_size: UInt64 = 0
        public var virtual_size: UInt64 = 0
    }

    struct MemoryUsageInfo {
        var resident_size: UInt64 = 0
        var virtual_size: UInt64 = 0
    }

    private func getMemoryUsage() -> MemoryUsageInfo? {
        #if os(Linux)
        guard let statusContents = URL(string: "/proc/self/status")?.readContentsAtPath() else {
            return nil
        }
        let lines = statusContents.split(separator: "\n")
        var stats = MemoryUsageInfo()
        var fields = 0
        for line in lines {
            if line.hasPrefix("VmSize:") {
                let components = line.components(separatedBy: .whitespaces).filter { $0.trimmingCharacters(in: .whitespaces).length > 0 }
                if components.count >= 2, let size = UInt64(components[1]) {
                    stats.virtual_size = size * 1024
                }
                fields += 1
            } else if line.hasPrefix("VmRSS:") {
                let components = line.components(separatedBy: .whitespaces).filter { $0.trimmingCharacters(in: .whitespaces).length > 0 }
                if components.count >= 2, let size = UInt64(components[1]) {
                    stats.resident_size = size * 1024
                }
                fields += 1
            }
            if fields >= 2 {
                break
            }
        }
        return stats
        #else
        var ti = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4
        let result: kern_return_t = withUnsafeMutablePointer(to: &ti) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            os_log(.error, log: log, "Unable to get process info, code: \(result)")
            return nil
        }
        return MemoryUsageInfo(resident_size: ti.resident_size, virtual_size: ti.virtual_size)
        #endif
    }

    public func configure(_ pipeline: EHPipeline) throws {
    }

    private let interval: TimeInterval

    private let intervalOverrideStorage: Mutex<Int?> = .init(nil)
    public var intervalOverride: Int? {
        get { intervalOverrideStorage.withLock { $0 } }
        set { intervalOverrideStorage.withLock { $0 = newValue } }
    }

    public init(interval: TimeInterval, metricOnly: Bool = false) {
        self.interval = interval
        self.metricOnly = metricOnly
    }

    private let serviceTask: Mutex<Task<(), Error>?> = .init(nil)

    public func start(_ pipeline: EHPipeline) throws {
        let logger = log
        let effectiveInterval: TimeInterval = {
            if let override = intervalOverride {
                if override > 0 {
                    return TimeInterval(override)
                }
                os_log(.error, log: logger,
                       "Invalid HeartbeatGenerator intervalOverride: %d. Must be positive, using init value %.1f.",
                       override, interval)
            }
            return interval
        }()
        serviceTask.withLock {
            $0 = Task {
                let initialOffset = effectiveInterval > 0 ? Double.random(in: 0..<effectiveInterval) : 0
                var firstIteration = true
                repeat {
                    var heartbeat = HeartbeatEvent()
                    heartbeat.timestamp = Date().timeIntervalSince1970
                    if let stats = getMemoryUsage() {
                        heartbeat.resident_size = stats.resident_size
                        heartbeat.virtual_size = stats.virtual_size
                        await withDiscardingTaskGroup { metrics in
                            metrics.addTask { await EHMetrics.Labels.Gauges.heartbeat_virtual_size.set(Double(stats.virtual_size)) }
                            metrics.addTask { await EHMetrics.Labels.Gauges.heartbeat_resident_size.set(Double(stats.resident_size)) }
                        }
                    }
                    if !metricOnly {
                        await pipeline.process(heartbeat)
                    }
                    if firstIteration {
                        firstIteration = false
                        try await Task.sleep(for: .seconds(initialOffset + effectiveInterval))
                    } else {
                        try await Task.sleep(for: .seconds(Int(effectiveInterval)))
                    }
                } while !Task.isCancelled
            }
        }
    }
}


extension HeartbeatGenerator.HeartbeatEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "timestamp": return timestamp
        case "resident_size": return resident_size
        case "virtual_size": return virtual_size
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
    static let timestamp: AST.RegoValue = .string("timestamp")
    static let resident_size: AST.RegoValue = .string("resident_size")
    static let virtual_size: AST.RegoValue = .string("virtual_size")
}

extension HeartbeatGenerator.HeartbeatEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.timestamp] = .number(RegoNumber(decimal: Decimal(timestamp)))
        obj[RK.resident_size] = .number(RegoNumber(value: resident_size))
        obj[RK.virtual_size] = .number(RegoNumber(value: virtual_size))
        return .object(obj)
    }
}
