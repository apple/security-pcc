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


import Dispatch
import Foundation
#if canImport(NetworkStatistics)
import NetworkStatistics
#endif
#if canImport(os)
import os
#endif
public class NStatClient: EHGenerator, AllEventsIterable {
    private let log = EHLog.withCategory(NStatClient.self)
    public static let allEvents: [any EHUEFEvent.Type] = [
        NStatClientNWEvent.self
    ]

    enum EventSubTypes: String, CaseIterable {
        case nw_open
        case nw_close
    }

    public struct NStatClientNWEvent: EHUEFEvent {
        public var metadata = EHEventMetadata()
        public var event_category: EHUEFCategory = .network
        public var event_type: String = "nw_open"

        public var startTime: Double = 0

        public var remoteAddr: String = ""

        public var remotePort: UInt16 = 0

        public var localPort: UInt16 = 0

        public var epid: pid_t = 0

        public var procName: String = ""

        public var uid: uid_t = 0

        public var direction: String = ""

        public init() {}

        public init(
            startTime: Double,
            remoteAddr: String,
            remotePort: UInt16,
            localPort: UInt16,
            epid: pid_t,
            procName: String,
            uid: uid_t,
            direction: String
        ) {
            self.startTime = startTime
            self.remoteAddr = remoteAddr
            self.remotePort = remotePort
            self.localPort = localPort
            self.epid = epid
            self.procName = procName
            self.uid = uid
            self.direction = direction
        }
    }

    public func start(_ pipeline: EHPipeline) throws {
    #if !canImport(NetworkStatistics)
        throw NStatClientError.unsupportedPlatform
        #else
        self.delegate.pipeline = pipeline

        let confResult = self.configureNstats()
        guard confResult == 0 else {
            os_log(.error, log: log, "Error configuring NStatClient: \(confResult)")
            throw NStatClientError.unableToConfigure(code: Int(confResult))
        }
        #endif
    }
    public func stop() throws {
        #if canImport(NetworkStatistics)
        self.nwStatsManager.invalidate()
        #endif
    }

    deinit {
        try? self.stop()
    }

    enum NStatClientError: Error {
        case unableToSubsribe(code: Int)
        case unableToConfigure(code: Int)
        case unsupportedPlatform
    }

    #if canImport(NetworkStatistics)
    let nstatQueue: DispatchQueue
    let nstatConfigParams: [String: Any] = [
        kNWStatsSelectAllFlows: true,
        kNWStatsSelectInterfaceWired: true,
        kNWStatsSelectFlowEvents: NWStatsEventType.enterOutboundState.rawValue,
        kNWStatsParameterReportOpen: true,
        kNWStatsSelectKnownInbound: true,
        kNWStatsSelectKnownOutbound: true,
        kNWStatsSelectKnownListener: true,
        kNWStatsParameterCheckNESessionManagerVPNs: false
    ]
    var nwStatsManager: NWStatsManager
    let delegate: StatsDelegate
    #endif

    init?() {
        #if !canImport(NetworkStatistics)
        return
        #else
        self.nstatQueue = DispatchQueue(label: "com.apple.securitymonitorlited.nstatclient")
        guard let statsManager = NWStatsManager(queue: self.nstatQueue) else {
            os_log(.error, log: log, "Error creating NWStatsManager")
            return nil
        }
        self.nwStatsManager = statsManager
        self.delegate = StatsDelegate()
        self.nwStatsManager.delegate = self.delegate
        #endif
    }

    public func configure(_ pipeline: EHPipeline) throws {}

#if canImport(NetworkStatistics)

    func configureNstats() -> Int32 {
        self.nstatQueue.sync {
            return self.nwStatsManager.configure(nstatConfigParams)
        }
    }
    class StatsDelegate: NSObject, NWStatsManagerDelegate {
        var pipeline: EHPipeline?
        func statsManager(_ manager: NWStatsManager, didReceiveNWSnapshot snapshot: NWStatsSnapshot) {
            guard let protoSnap = snapshot as? NWStatsProtocolSnapshot else {
                return
            }
            guard let pipeline = pipeline else {
                return
            }
            guard protoSnap.firstOccurrence == true else {
                return
            }
            var remoteAddr = protoSnap.remoteAddressString ?? EventHorizonKit.eventInfoUnknown
            if let portIndex = remoteAddr.lastIndex(of: ":") {
                remoteAddr = String(remoteAddr.prefix(upTo: portIndex))
            }
            let event: any EHUEFEvent = NStatClientNWEvent(
                startTime: protoSnap.flowStartTimeIntervalSince1970,
                remoteAddr: remoteAddr,
                remotePort: protoSnap.remotePort,
                localPort: protoSnap.localPort,
                epid: protoSnap.processID,
                procName: "",
                uid: protoSnap.uid,
                direction: protoSnap.snapshotReasonString ?? EventHorizonKit.eventInfoUnknown)
            Task {
                await pipeline.process(event)
            }
        }
    }
#endif
}


extension NStatClient.NStatClientNWEvent: EventNormalizer.NetworkNormalizable {
    public var n_pid: Int64 {
        Int64(self.epid)
    }

    public var n_proc_name: String {
        self.procName
    }

    public var n_remote_addr: String {
        self.remoteAddr
    }

    public var n_remote_port: UInt16 {
        self.remotePort
    }

    public var n_local_port: UInt16 {
        self.localPort
    }

    public var n_direction: String {
        self.direction
    }

    public var n_protocol: String {
        "tcp"
    }

    public var n_uid: UInt32 {
        self.uid
    }

    public var n_start_time: Double {
        self.startTime
    }

    public var n_non_normalizable: [String: EHValueType] {
        [:]
    }
}

extension NStatClient.NStatClientNWEvent: EHEventSimilarityValue {
    public var similarityHash: Int {
        var hasher = Hasher()
        hasher.combine(epid)
        hasher.combine(procName)
        hasher.combine(remoteAddr)
        hasher.combine(remotePort)
        return hasher.finalize()
    }
}

extension NStatClient.NStatClientNWEvent: EHFieldExtractable {
    public func fieldValue(for field: String) -> Any? {
        switch field {
        case "tags": return tags
        case "fields": return fields
        case "event_category": return event_category
        case "event_type": return event_type
        case "startTime": return startTime
        case "remoteAddr": return remoteAddr
        case "remotePort": return remotePort
        case "localPort": return localPort
        case "epid": return epid
        case "procName": return procName
        case "uid": return uid
        case "direction": return direction
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
    static let startTime: AST.RegoValue = .string("startTime")
    static let remoteAddr: AST.RegoValue = .string("remoteAddr")
    static let remotePort: AST.RegoValue = .string("remotePort")
    static let localPort: AST.RegoValue = .string("localPort")
    static let epid: AST.RegoValue = .string("epid")
    static let procName: AST.RegoValue = .string("procName")
    static let uid: AST.RegoValue = .string("uid")
    static let direction: AST.RegoValue = .string("direction")
}

extension NStatClient.NStatClientNWEvent: EHRegoConvertible {
    public func toRegoValue() -> AST.RegoValue {
        var obj: [AST.RegoValue: AST.RegoValue] = [:]
        obj[RK.event_type] = .string(event_type)
        obj[RK.event_category] = .string(event_category.rawValue)
        obj[RK.tags] = tags.toRegoValue()
        obj[RK.fields] = fields.toRegoValue()
        obj[RK.startTime] = .number(RegoNumber(decimal: Decimal(startTime)))
        obj[RK.remoteAddr] = .string(remoteAddr)
        obj[RK.remotePort] = .number(RegoNumber(int: Int64(remotePort)))
        obj[RK.localPort] = .number(RegoNumber(int: Int64(localPort)))
        obj[RK.epid] = .number(RegoNumber(int: Int64(epid)))
        obj[RK.procName] = .string(procName)
        obj[RK.uid] = .number(RegoNumber(int: Int64(uid)))
        obj[RK.direction] = .string(direction)
        return .object(obj)
    }
}
