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
import Logging
import NIOCore

// MARK: - Data model

struct NUMATopology: Sendable, Equatable {
    struct LogicalCPU: Sendable, Equatable, ExpressibleByIntegerLiteral,
        CustomStringConvertible
    {
        let id: Int
        let smtPairID: Int?

        var description: String {
            if let smtPairID {
                "\(id)(smt:\(smtPairID))"
            } else {
                "\(id)"
            }
        }

        init(id: Int, smtPairID: Int? = nil) {
            self.id = id
            self.smtPairID = smtPairID
        }

        init(integerLiteral value: Int) {
            self.id = value
            self.smtPairID = nil
        }
    }

    struct Node: Sendable, Equatable {
        let id: Int
        let cpus: [LogicalCPU]
        let devices: [NIONetworkDevice]
    }

    let nodes: [Node]
    let unassignedDevices: [NIONetworkDevice]
    let smtEnabled: Bool
}

// MARK: - UTF-8 parsing helpers

private let _asciiZero = UInt8(ascii: "0")
private let _asciiNine = UInt8(ascii: "9")
private let _asciiComma = UInt8(ascii: ",")
private let _asciiDash = UInt8(ascii: "-")

extension UInt8 {
    /// Whether this byte is ASCII whitespace: space, tab, newline, or carriage return.
    var isASCIIWhitespace: Bool {
        self == UInt8(ascii: " ") || self == UInt8(ascii: "\t")
            || self == UInt8(ascii: "\n") || self == UInt8(ascii: "\r")
    }
}

extension Substring.UTF8View {
    /// Returns a sub-slice with leading and trailing ASCII whitespace removed.
    func trimmingASCIIWhitespace() -> Substring.UTF8View {
        var start = startIndex
        var end = endIndex
        while start < end && self[start].isASCIIWhitespace {
            formIndex(after: &start)
        }
        while start < end {
            let prev = index(before: end)
            if !self[prev].isASCIIWhitespace { break }
            end = prev
        }
        return self[start..<end]
    }
}

/// Parses a non-negative integer from a UTF-8 view. Returns `nil` if the view
/// is empty, contains any non-digit bytes, or the value overflows `Int`.
private func _parseUInt(_ utf8: Substring.UTF8View) -> Int? {
    guard !utf8.isEmpty else { return nil }
    var value = 0
    var overflow = false
    for byte in utf8 {
        guard byte >= _asciiZero && byte <= _asciiNine else { return nil }
        let (mul, mulOverflow) = value.multipliedReportingOverflow(by: 10)
        let (add, addOverflow) = mul.addingReportingOverflow(Int(byte &- _asciiZero))
        value = add
        overflow = overflow || mulOverflow || addOverflow
    }
    return overflow ? nil : value
}

/// Parses a possibly-negative integer from a UTF-8 view.
private func _parseInt(_ utf8: Substring.UTF8View) -> Int? {
    guard let first = utf8.first else { return nil }
    if first == _asciiDash {
        guard let magnitude = _parseUInt(utf8[utf8.index(after: utf8.startIndex)...]) else {
            return nil
        }
        return -magnitude
    }
    return _parseUInt(utf8)
}

// MARK: - Helpers

/// Parses a Linux CPU list string like `"0-3,8-11,15"` into a sorted array of
/// individual CPU indices. Returns `nil` on malformed input.
func parseCPUList(_ string: String) -> [Int]? {
    let trimmed = Substring(string).utf8.trimmingASCIIWhitespace()
    guard !trimmed.isEmpty else { return nil }

    var result: [Int] = []

    // Split on ',' by walking the UTF-8 view.
    var partStart = trimmed.startIndex
    for i in trimmed.indices {
        guard trimmed[i] == _asciiComma else { continue }
        guard _parseCPUListPart(trimmed[partStart..<i], into: &result) else { return nil }
        partStart = trimmed.index(after: i)
    }
    // Handle the final segment after the last comma (or the only segment).
    guard _parseCPUListPart(trimmed[partStart..<trimmed.endIndex], into: &result) else {
        return nil
    }

    return result.sorted()
}

/// Parses a single segment of a CPU list (either `"N"` or `"N-M"`) and appends
/// the CPU indices to `result`. Returns `false` on malformed input.
private func _parseCPUListPart(
    _ part: Substring.UTF8View,
    into result: inout [Int]
) -> Bool {
    // Find the first dash to split "lo-hi".
    if let dashIndex = part.firstIndex(of: _asciiDash) {
        guard let lo = _parseUInt(part[part.startIndex..<dashIndex]),
            let hi = _parseUInt(part[part.index(after: dashIndex)..<part.endIndex]),
            lo <= hi
        else {
            return false
        }
        result.append(contentsOf: lo...hi)
    } else {
        guard let value = _parseUInt(part) else { return false }
        result.append(value)
    }
    return true
}

// MARK: - sysfs discovery

#if os(Linux)

private let _nodePrefix = "node".utf8

/// Lists NUMA node IDs by scanning `{sysfsRoot}/devices/system/node/` for
/// directories matching `node\d+`. Returns a sorted array.
func discoverNUMANodeIDs(
    sysfsRoot: String = "/sys",
    logger: Logger
) -> [Int] {
    let nodePath = "\(sysfsRoot)/devices/system/node"
    let fm = FileManager.default

    guard let entries = try? fm.contentsOfDirectory(atPath: nodePath) else {
        logger.debug("Could not list NUMA node directory", metadata: ["path": "\(nodePath)"])
        return []
    }

    var ids: [Int] = []
    for entry in entries {
        let utf8 = Substring(entry).utf8
        guard utf8.starts(with: _nodePrefix) else { continue }
        if let id = _parseUInt(utf8.dropFirst(4)) {
            ids.append(id)
        }
    }
    return ids.sorted()
}

/// Reads and parses the CPU list for a given NUMA node.
func readNodeCPUList(
    nodeID: Int,
    sysfsRoot: String = "/sys",
    logger: Logger
) -> [Int] {
    let path = "\(sysfsRoot)/devices/system/node/node\(nodeID)/cpulist"
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        logger.debug("Could not read cpulist", metadata: ["path": "\(path)"])
        return []
    }
    guard let cpus = parseCPUList(contents) else {
        logger.warning("Malformed cpulist", metadata: ["path": "\(path)", "contents": "\(contents)"])
        return []
    }
    return cpus
}

/// Reads the SMT sibling for a given CPU ID from sysfs.
///
/// Parses `thread_siblings_list` (same format as `cpulist`) and returns the
/// single sibling CPU ID, or `nil` when: the file is missing, the data is
/// malformed, there is no sibling (single-threaded core), or the core has
/// more than 2 hardware threads.
func readSMTPairID(
    cpuID: Int,
    sysfsRoot: String = "/sys",
    logger: Logger
) -> Int? {
    let path =
        "\(sysfsRoot)/devices/system/cpu/cpu\(cpuID)/topology/thread_siblings_list"
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        return nil
    }
    guard let siblings = parseCPUList(contents) else {
        logger.warning(
            "Malformed thread_siblings_list",
            metadata: ["path": "\(path)", "contents": "\(contents)"]
        )
        return nil
    }
    let others = siblings.filter { $0 != cpuID }
    guard others.count == 1 else {
        return nil
    }
    return others[0]
}

/// Enumerates network interfaces and reads their NUMA node affinity.
/// Returns a dictionary mapping node ID to sorted NIC names.
func discoverNICNUMAMapping(
    sysfsRoot: String = "/sys",
    logger: Logger
) -> [Int: [String]] {
    let netPath = "\(sysfsRoot)/class/net"
    let fm = FileManager.default

    guard let interfaces = try? fm.contentsOfDirectory(atPath: netPath) else {
        logger.debug("Could not list network interfaces", metadata: ["path": "\(netPath)"])
        return [:]
    }

    var mapping: [Int: [String]] = [:]
    for iface in interfaces {
        let numaNodePath = "\(netPath)/\(iface)/device/numa_node"
        guard let contents = try? String(contentsOfFile: numaNodePath, encoding: .utf8) else {
            continue
        }
        let trimmed = Substring(contents).utf8.trimmingASCIIWhitespace()
        guard let nodeID = _parseInt(trimmed), nodeID >= 0 else {
            continue
        }
        mapping[nodeID, default: []].append(iface)
    }

    // Sort NIC names within each node.
    for key in mapping.keys {
        mapping[key]?.sort()
    }

    return mapping
}

/// Reads `/sys/devices/system/cpu/smt/active` and returns `true` when SMT is enabled.
/// Returns `false` for missing, unreadable, or malformed files.
func detectSMTEnabled(
    sysfsRoot: String = "/sys",
    logger: Logger
) -> Bool {
    let path = "\(sysfsRoot)/devices/system/cpu/smt/active"
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        logger.debug("Could not read SMT active file", metadata: ["path": "\(path)"])
        return false
    }
    let trimmed = Substring(contents).utf8.trimmingASCIIWhitespace()
    guard let value = _parseUInt(trimmed) else {
        logger.warning("Malformed SMT active file", metadata: ["path": "\(path)", "contents": "\(contents)"])
        return false
    }
    return value == 1
}

#else

/// Returns an empty array on non-Linux platforms (no sysfs).
func discoverNUMANodeIDs(
    sysfsRoot: String = "/sys",
    logger: Logger
) -> [Int] {
    []
}

/// Returns an empty dictionary on non-Linux platforms (no sysfs).
func discoverNICNUMAMapping(
    sysfsRoot: String = "/sys",
    logger: Logger
) -> [Int: [String]] {
    [:]
}

/// Returns an empty array on non-Linux platforms (no sysfs).
func readNodeCPUList(
    nodeID: Int,
    sysfsRoot: String = "/sys",
    logger: Logger
) -> [Int] {
    []
}

/// Returns `false` on non-Linux platforms (no sysfs).
func detectSMTEnabled(
    sysfsRoot: String = "/sys",
    logger: Logger
) -> Bool {
    false
}

/// Returns `nil` on non-Linux platforms (no sysfs).
func readSMTPairID(
    cpuID: Int,
    sysfsRoot: String = "/sys",
    logger: Logger
) -> Int? {
    nil
}

#endif

// MARK: - Topology discovery

/// Discovers the full NUMA topology by combining node, CPU, and NIC information.
///
/// On Linux, reads from sysfs to discover NUMA nodes, CPU lists, and NIC-to-node
/// mappings, then matches enumerated `NIONetworkDevice` objects to their respective
/// nodes. Devices that don't belong to any NUMA node (e.g. loopback) are placed in
/// `unassignedDevices`.
///
/// When no NUMA nodes are found (always the case on macOS, and possible on Linux in
/// highly containerised environments), a single synthetic node with id 0 containing
/// all available CPUs is returned, with every device in `unassignedDevices`.
///
/// - Parameters:
///   - sysfsRoot: Root path for sysfs (Linux only, default "/sys").
///   - enumerateDevices: Closure that returns network devices. Defaults to
///     `NIOCore.System.enumerateDevices()`. Pass a custom closure for testing.
///   - logger: Logger for debug/info output.
func discoverNUMATopology(
    sysfsRoot: String = "/sys",
    enumerateDevices: () throws -> [NIONetworkDevice] = { try NIOCore.System.enumerateDevices() },
    logger: Logger
) -> NUMATopology {
    let allDevices = (try? enumerateDevices()) ?? []
    let smtEnabled = detectSMTEnabled(sysfsRoot: sysfsRoot, logger: logger)

    let nodeIDs = discoverNUMANodeIDs(sysfsRoot: sysfsRoot, logger: logger)
    if nodeIDs.isEmpty {
        logger.info("No NUMA nodes found; synthesizing single-node topology")
        let node = NUMATopology.Node(
            id: 0,
            cpus: (0..<NIOCore.System.coreCount).map { NUMATopology.LogicalCPU(id: $0) },
            devices: []
        )
        return NUMATopology(nodes: [node], unassignedDevices: allDevices, smtEnabled: smtEnabled)
    }

    let nicMapping = discoverNICNUMAMapping(sysfsRoot: sysfsRoot, logger: logger)
    let devicesByName = Dictionary(grouping: allDevices, by: \.name)

    var assignedNames: Set<String> = []

    let nodes = nodeIDs.map { id in
        let nicNames = nicMapping[id] ?? []
        let nodeDevices = nicNames.flatMap { name -> [NIONetworkDevice] in
            assignedNames.insert(name)
            return devicesByName[name] ?? []
        }
        let rawCPUs = readNodeCPUList(nodeID: id, sysfsRoot: sysfsRoot, logger: logger)
        let logicalCPUs = rawCPUs.map { cpuID in
            NUMATopology.LogicalCPU(
                id: cpuID,
                smtPairID: readSMTPairID(cpuID: cpuID, sysfsRoot: sysfsRoot, logger: logger)
            )
        }
        return NUMATopology.Node(
            id: id,
            cpus: logicalCPUs,
            devices: nodeDevices
        )
    }

    let unassigned = allDevices.filter { !assignedNames.contains($0.name) }
    return NUMATopology(nodes: nodes, unassignedDevices: unassigned, smtEnabled: smtEnabled)
}

/// Logs details of the discovered NUMA topology.
func logNUMATopology(_ topology: NUMATopology, logger: Logger) {
    for node in topology.nodes {
        let uniqueDeviceNames = Array(Set(node.devices.map(\.name))).sorted()
        let smtPairCount = node.cpus.count(where: { $0.smtPairID != nil })
        logger.info(
            "NUMA node discovered",
            metadata: [
                "nodeID": "\(node.id)",
                "cpus": "\(node.cpus)",
                "cpuCount": "\(node.cpus.count)",
                "smtPairCount": "\(smtPairCount)",
                "devices": "\(uniqueDeviceNames)",
            ]
        )
    }

    if !topology.unassignedDevices.isEmpty {
        let uniqueUnassignedNames = Array(Set(topology.unassignedDevices.map(\.name))).sorted()
        logger.info(
            "Unassigned network devices",
            metadata: [
                "devices": "\(uniqueUnassignedNames)",
                "count": "\(uniqueUnassignedNames.count)",
            ]
        )
    }

    let totalCPUs = topology.nodes.reduce(0) { $0 + $1.cpus.count }
    let totalSMTPairs = topology.nodes.reduce(0) { $0 + $1.cpus.count(where: { $0.smtPairID != nil }) }
    let unassignedCount = Set(topology.unassignedDevices.map(\.name)).count
    logger.info(
        "NUMA topology summary",
        metadata: [
            "nodeCount": "\(topology.nodes.count)",
            "totalCPUs": "\(totalCPUs)",
            "totalSMTPairCount": "\(totalSMTPairs)",
            "unassignedDeviceCount": "\(unassignedCount)",
            "smtEnabled": "\(topology.smtEnabled)",
        ]
    )
}
