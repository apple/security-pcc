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

public final class ProcessSnapshotGenerator: EHGenerator, AllEventsIterable {
    private let log = EHLog.withCategory(ProcessSnapshotGenerator.self)

    public static let allEvents: [any EHUEFEvent.Type] = [
        ProcessSnapshotEvent.self
    ]

    public enum ConfigKeys: String {
        case process_snapshot_generator_interval = "com.apple.eventhorizond.processSnapshot.interval"
    }

    public struct ProcessSnapshotEvent: EHUEFEvent {
        public init() {
        }

        public init(processes: [EventNormalizer.NormalizedProcess]) {
            self.processes = processes
        }
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .process
        public var event_type: String = "process_snapshot"

        public var processes: [EventNormalizer.NormalizedProcess]?
    }

    #if os(Linux)
    public var hostProcPath: String?
    #endif

    public var intervalOverride: Int?

    public init() {}

    public func configure(_ pipeline: EHPipeline) throws {
    }

    public func start(_ pipeline: EHPipeline) throws {
        let logger = log
        os_log(.info, log: logger, "Initializing ProcessSnapshotGenerator")

        #if os(Linux)
        let enumerator: ProcessEnumerator
        if let hostProc = hostProcPath {
            os_log(.info, log: logger, "Using host proc path: \(hostProc)")
            enumerator = ProcessEnumerator(procPath: hostProc)
        } else {
            enumerator = ProcessEnumerator.instance
        }
        #else
        let enumerator = ProcessEnumerator.instance
        #endif

        let defaultInterval = 60 * 60 * 6
        let interval: Int
        if let intervalOverride, intervalOverride > 0 {
            interval = intervalOverride
        } else {
            if let intervalOverride, intervalOverride <= 0 {
                os_log(.error, log: logger, "Invalid intervalOverride: %d. Must be positive, using default.", intervalOverride)
            }
            interval = EHConfigResolver(
                SecureConfigProvider(),
                EnvironmentConfigResolver(),
                DefaultConfigProvider(value: defaultInterval)
            ).resolve(key: ConfigKeys.process_snapshot_generator_interval.rawValue, domain: nil) ?? defaultInterval
        }
        os_log(.debug, log: logger, "Interval for process snapshot: \(interval)")
        Task {
            repeat {
                guard let processes = await enumerator.enumerateProcesses() else {
                    os_log(.error, log: logger, "Unable to enumerate processes")
                    return
                }
                let event = ProcessSnapshotEvent(
                    processes: processes
                )
                await pipeline.process(event)
                try? await Task.sleep(for: .seconds(interval))
            } while !Task.isCancelled
        }
    }

    public func stop() throws {
    }
}


extension ProcessSnapshotGenerator.ProcessSnapshotEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "processes": return processes
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
    static let processes: AST.RegoValue = .string("processes")
}

extension ProcessSnapshotGenerator.ProcessSnapshotEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        if let processes {
            obj[RK.processes] = .array(processes.map { $0.toRegoValue() })
        }
        return .object(obj)
    }
}
