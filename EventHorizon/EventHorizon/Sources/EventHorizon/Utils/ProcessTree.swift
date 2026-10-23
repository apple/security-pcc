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
#if canImport(LoggingSupport)
import LoggingSupport
#elseif canImport(os)
import os
#endif
import Synchronization


public struct ProcessTreeNode: Hashable, Sendable {
    public private(set) var childPids: Set<Int64> = []

    private let normalizedProcess: EventNormalizer.NormalizedProcess
    private var exitEvent: ESClient.ESClientProcExitEvent?
    private var syntheticExitTime: Double?

    init(normalizedProcess: EventNormalizer.NormalizedProcess) {
        self.normalizedProcess = normalizedProcess
    }

    public var pid: Int64 {
        normalizedProcess.pid
    }

    public var ppid: Int64 {
        normalizedProcess.ppid
    }

    public var gid: UInt32 {
        normalizedProcess.gid
    }

    public var uid: UInt32 {
        normalizedProcess.uid
    }

    public var cwd: String {
        normalizedProcess.cwd
    }

    public var name: String {
        normalizedProcess.exe
    }

    public var startTime: Double {
        normalizedProcess.start_time
    }

    public var exitTime: Double? {
        exitEvent?.timestamp ?? syntheticExitTime
    }

    public func isChild(childPid: Int64) -> Bool {
        childPids.contains(childPid)
    }

    public mutating func addChild(childPid: Int64) {
        childPids.insert(childPid)
    }

    public mutating func exit(exitEvent: ESClient.ESClientProcExitEvent) -> Bool {
        if self.exitEvent != nil {
            return false
        }
        self.exitEvent = exitEvent
        return true
    }

    mutating func markStaleExit(timestamp: Double) {
        if exitTime == nil {
            syntheticExitTime = timestamp
        }
    }


    public static func == (lhs: ProcessTreeNode, rhs: ProcessTreeNode) -> Bool {
        lhs.pid == rhs.pid && lhs.startTime == rhs.startTime
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(startTime)
    }
}


public final actor ProcessTree {
    static let maxTotalEntries = 32768
    static let maxPidEntries = 8

    public static let exitSweepIntervalSeconds: Double = 60
    public static let exitRetentionSeconds: Double = 60

    final class PidNodes {
        private var storage: [Double: ProcessTreeNode] = Dictionary(minimumCapacity: 2)

        subscript (startTime: Double) -> ProcessTreeNode? {
            get {
                storage[startTime]
            }
            set {
                if let newValue = newValue {
                    storage[startTime] = newValue
                    purgeIfFull()
                } else {
                    storage.removeValue(forKey: startTime)
                }
            }
        }

        var count: Int {
            storage.count
        }

        var nodes: [ProcessTreeNode] {
            return Array(storage.values)
        }

        var entries: [Double: ProcessTreeNode] {
            return storage
        }

        func latest(startBeforeTime: Double? = nil) -> ProcessTreeNode? {
            if let startBeforeTime = startBeforeTime {
                return storage.filter { $0.key <= startBeforeTime }.max(by: { $0.key < $1.key })?.value
            } else {
                return storage.max(by: { $0.key < $1.key })?.value
            }
        }

        func purgeIfFull() {
            if storage.count >= ProcessTree.maxPidEntries {
                let removeKeys = storage.keys.sorted().prefix(ProcessTree.maxPidEntries >> 1)
                removeKeys.forEach { storage.removeValue(forKey: $0) }
            }
        }

        @discardableResult
        func removeExitedOlderThan(threshold: Double) -> Int {
            let keysToRemove = storage.compactMap { startTime, node -> Double? in
                guard let exitTime = node.exitTime, exitTime < threshold else {
                    return nil
                }
                return startTime
            }
            for key in keysToRemove {
                storage.removeValue(forKey: key)
            }
            return storage.count
        }

        func markStaleProcesses(liveProcesses: [Int64: Double], timestamp: Double) {
            for (startTime, node) in storage where node.exitTime == nil {
                if let liveStartTime = liveProcesses[node.pid] {
                    if abs(liveStartTime - node.startTime) > 0.5 {
                        var staleNode = node
                        staleNode.markStaleExit(timestamp: timestamp)
                        storage[startTime] = staleNode
                    }
                } else {
                    var staleNode = node
                    staleNode.markStaleExit(timestamp: timestamp)
                    storage[startTime] = staleNode
                }
            }
        }
    }

    let log = EHLog.withCategory(type(of: ProcessTree.self))

    private let processCache = LRUCache<Int64, PidNodes>(totalCount: maxTotalEntries)

    public subscript(pid: Int64, startTime: Double? = nil) -> ProcessTreeNode? {
        guard let pidNodes = processCache[pid] else {
            return nil
        }
        guard let startTime = startTime else {
            return pidNodes.latest()
        }
        return pidNodes[startTime]
    }

    public var entries: Int {
        processCache.count
    }

    public func pidNodesCount(pid: Int64) -> Int {
        guard let pidNodes = processCache[pid] else {
            return 0
        }
        return pidNodes.count
    }

    public func clear() {
        processCache.removeAll()
    }

    private func findProcessNodeStartedBefore(pid: Int64, startBeforeTime: Double) -> ProcessTreeNode? {
        guard let pidNodes = processCache[pid] else {
            return nil
        }
        return pidNodes.latest(startBeforeTime: startBeforeTime)
    }

    public func parentOf(pid: Int64, startTime: Double? = nil) -> ProcessTreeNode? {
        guard let node = self[pid, startTime] else {
            return nil
        }
        return findProcessNodeStartedBefore(pid: node.ppid, startBeforeTime: node.startTime)
    }

    public func parentOf(node: ProcessTreeNode) -> ProcessTreeNode? {
        parentOf(pid: node.pid, startTime: node.startTime)
    }

    public func grandParentOf(pid: Int64, startTime: Double? = nil) -> ProcessTreeNode? {
        guard let node = parentOf(pid: pid, startTime: startTime) else {
            return nil
        }
        return findProcessNodeStartedBefore(pid: node.ppid, startBeforeTime: node.startTime)
    }

    public func grandParentOf(node: ProcessTreeNode) -> ProcessTreeNode? {
        grandParentOf(pid: node.pid, startTime: node.startTime)
    }

    public func isAncestor(
        ancestorPid: Int64,
        ancestorStartTime: Double? = nil,
        of descendantPid: Int64,
        descendantStartTime: Double,
        maxDepth: Int = 10
    ) -> Bool {
        var currentPid = descendantPid
        var currentStartTime = descendantStartTime

        for _ in 0..<maxDepth {
            guard let currentNode = self[currentPid, currentStartTime] else {
                return false
            }

            if currentNode.pid == ancestorPid {
                if let ancestorStartTime = ancestorStartTime {
                    let timeDiff = abs(currentNode.startTime - ancestorStartTime)
                    if timeDiff < 0.001 {
                        return true
                    } else {
                        return false
                    }
                }
                return true
            }

            guard let parentNode = self.parentOf(node: currentNode) else {
                return false
            }

            currentPid = parentNode.pid
            currentStartTime = parentNode.startTime
        }

        return false
    }

    public func findAncestor(
        of pid: Int64,
        startTime: Double,
        maxDepth: Int = 10,
        matching namePredicate: (String) -> Bool
    ) -> ProcessTreeNode? {
        var currentPid = pid
        var currentStartTime = startTime

        for _ in 0..<maxDepth {
            guard let currentNode = self[currentPid, currentStartTime] else {
                return nil
            }

            if namePredicate(currentNode.name) {
                return currentNode
            }

            guard let parentNode = self.parentOf(node: currentNode) else {
                return nil
            }

            currentPid = parentNode.pid
            currentStartTime = parentNode.startTime
        }

        return nil
    }

    public func sweepExitedProcesses(retentionSeconds: Double = exitRetentionSeconds, liveProcesses: [Int64: Double]? = nil) {
        let now = Date().timeIntervalSince1970

        if let liveProcesses {
            for (_, pidNodes) in processCache {
                pidNodes.markStaleProcesses(liveProcesses: liveProcesses, timestamp: now)
            }
        }

        let threshold = now - retentionSeconds
        var pidsToRemove: [Int64] = []

        for (pid, pidNodes) in processCache {
            let remaining = pidNodes.removeExitedOlderThan(threshold: threshold)
            if remaining == 0 {
                pidsToRemove.append(pid)
            }
        }

        for pid in pidsToRemove {
            processCache[pid] = nil
        }
    }

    public func debugStateDescription() -> String {
        let totalEntries = entries
        var pidDistribution: [Int64: Int] = [:]
        var totalProcessNodes = 0
        var totalActiveNodes = 0

        for (pid, pidNodes) in processCache {
            pidDistribution[pid] = pidNodes.count
            totalProcessNodes += pidNodes.count
            for node in pidNodes.nodes where node.exitTime == nil {
                totalActiveNodes += 1
            }
        }

        let avgNodesPerPID = totalEntries > 0 ? Double(totalProcessNodes) / Double(totalEntries) : 0.0
        let maxNodesForSinglePID = pidDistribution.values.max() ?? 0

        return """
            - Total PID entries: \(totalEntries)
            - Total process nodes: \(totalProcessNodes)
            - Avg nodes per PID: \(String(format: "%.2f", avgNodesPerPID))
            - Max nodes for single PID: \(maxNodesForSinglePID)
            - Cache capacity: \(ProcessTree.maxTotalEntries) total, \(ProcessTree.maxPidEntries) per PID
            """
    }

    public func logSnapshot() {
        guard EHLog.isDebugEnabled(log) else {
            return
        }
        let stateDescription = self.debugStateDescription()
        os_log(.debug, log: log, """
            ProcessTree: state:
            \(stateDescription, privacy: .public)
            """)
    }

    public func logProcessSummary() {
        os_log(.debug, log: log, "Process Tree Summary - Starting")

        var allProcesses: [ProcessTreeNode] = []

        for (_, pidNodes) in processCache {
            for node in pidNodes.nodes {
                allProcesses.append(node)
            }
        }

        allProcesses.sort { $0.pid < $1.pid }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM dd HH:mm:ss"

        var runningCount = 0

        for process in allProcesses {
            let executablePath = process.name
            let processName = {
                if executablePath.isEmpty {
                    return "Unknown"
                }
                let components = executablePath.split(separator: "/")
                return String(components.last ?? "Unknown")
            }()

            let ppid = process.ppid
            let startTime = process.startTime
            let startDate = Date(timeIntervalSince1970: startTime)
            let formattedStartTime = dateFormatter.string(from: startDate)

            let exitTime = process.exitTime
            let status = exitTime != nil ? "Exited" : "Running"
            if exitTime == nil {
                runningCount += 1
            }

            os_log(.debug, log: log, "PID: %d, Name: %{public}s, PPID: %d, Started: %{public}s, Status: %{public}s, Path: %{public}s",
                process.pid, processName, ppid, formattedStartTime, status, executablePath)
        }

        os_log(.debug, log: log, "Process Tree Summary - Total: %d, Running: %d, Exited: %d",
            allProcesses.count, runningCount, allProcesses.count - runningCount)
    }

    public func processProcessesSnapshot(_ processes: [EventNormalizer.NormalizedProcess]?) {
        guard let processes = processes else {
            os_log(.error, log: log, "Failed to enumerate existing processes during initialization")
            return
        }

        guard !processes.isEmpty else {
            os_log(.info, log: log, "No existing processes found during initialization")
            return
        }

        os_log(.info, log: log, "Initializing ProcessTree with %d existing processes", processes.count)

        self.clear()

        for process in processes {
            self.addNormalizedProcess(process: process)
        }

        os_log(.info, log: log, "ProcessTree initialization completed with %d entries", entries)

        logProcessSummary()
    }

    public func addNormalizedProcess(process: EventNormalizer.NormalizedProcess) {
        let pidNodes: PidNodes
        if let existing = processCache[process.pid] {
            pidNodes = existing
        } else {
            pidNodes = PidNodes()
            processCache[process.pid] = pidNodes
        }

        var existingStartTime: Double?
        for (startTime, node) in pidNodes.entries {
            let timeDiff = abs(startTime - process.start_time)

            if timeDiff <= 0.5 && node.ppid == process.ppid {
                existingStartTime = startTime
                break
            }
        }

        if let oldStartTime = existingStartTime {
            var updatedProcess = process
            updatedProcess.start_time = oldStartTime
            updatedProcess.non_normalizable = [:]

            pidNodes[oldStartTime] = nil
            pidNodes[oldStartTime] = ProcessTreeNode(normalizedProcess: updatedProcess)
        } else {
            var storedProcess = process
            storedProcess.non_normalizable = [:]
            pidNodes[process.start_time] = ProcessTreeNode(normalizedProcess: storedProcess)
        }

        if existingStartTime == nil {
            if let parent = findProcessNodeStartedBefore(pid: process.ppid, startBeforeTime: process.start_time),
               let parentPidNodes = processCache[parent.pid] {
                var updatedParent = parent
                updatedParent.addChild(childPid: process.pid)
                parentPidNodes[parent.startTime] = updatedParent
            }
        }
    }

    public func processEvent(event: any EHUEFEvent) -> (Bool, (any EHUEFEvent)?) {
        if let e = event as? ProcessSnapshotGenerator.ProcessSnapshotEvent {
            processProcessesSnapshot(e.processes)
            return (true, nil)
        } else if let e = event as? EventNormalizer.NormalizedProcess {
            addNormalizedProcess(process: e)

            if let parent = findProcessNodeStartedBefore(pid: e.ppid, startBeforeTime: e.start_time) {
                var m_e = e
                m_e.p_start_time = parent.startTime
                m_e.p_gid = parent.gid
                return (true, m_e)
            }

            return (true, nil)
        } else if var e = event as? (any EHProcessTreeEnrichable) {

            if let pidNode = self[e.pid] {
                e.pid_start_time = pidNode.startTime
                e.exe = pidNode.name
                e.uid = pidNode.uid
                if e.proc_name.isEmpty {
                    e.proc_name = exeBasename(pidNode.name)
                }

                if let parent = findProcessNodeStartedBefore(pid: pidNode.ppid, startBeforeTime: pidNode.startTime) {
                    e.p_pid = parent.pid
                    e.p_pid_start_time = parent.startTime
                    e.p_exe = parent.name
                }
                return (true, e)
            }

            return (true, nil)
        } else if let e = event as? ESClient.ESClientProcExitEvent {
            guard let node = self[Int64(e.pid)] else {
                return (true, nil)
            }

            var updatedNode = node
            if !updatedNode.exit(exitEvent: e) {
                return (false, nil)
            }

            if let pidNodes = processCache[node.pid] {
                pidNodes[node.startTime] = updatedNode
            }

            return (true, nil)
        }
        return (true, nil)
    }

    public func getPidNodesCount(_ pid: Int64) -> Int {
        return processCache[pid]?.count ?? 0
    }
}
