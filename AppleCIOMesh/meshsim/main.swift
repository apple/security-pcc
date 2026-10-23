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

//
// main.swift
// meshsim
//
// Created by Sumit Kamath on 8/31/23.
// Copyright © 2023 Apple Inc. All rights reserved.
//

import Foundation

// MARK: - Compute Node

enum KVCacheState: Equatable {
	case empty
	case preparing(ComputeNode, Int)
	case preparingMLX(ComputeNode, Int)
	case cioReceived(ComputeNode, Int)
	case mlxReceived(ComputeNode, Int)
	case acquired(ComputeNode, Int)
}

extension KVCacheState: CustomStringConvertible {
	var description: String {
		switch self {
		case .empty:
			return "[____]"
		case .preparing(let node, _):
			if node.chassisID < 10 {
				return "[P \(node.chassisID)\(node.nodeID)]"
			}
			return "[P\(node.chassisID)\(node.nodeID)]"
		case .preparingMLX(let node, _):
			if node.chassisID < 10 {
				return "[Ṕ \(node.chassisID)\(node.nodeID)]"
			}
			return "[Ṕ\(node.chassisID)\(node.nodeID)]"
		case .cioReceived(let node, _):
			if node.chassisID < 10 {
				return "[C \(node.chassisID)\(node.nodeID)]"
			}
			return "[C\(node.chassisID)\(node.nodeID)]"
		case .mlxReceived(let node, _):
			if node.chassisID < 10 {
				return "[M \(node.chassisID)\(node.nodeID)]"
			}
			return "[M\(node.chassisID)\(node.nodeID)]"
		case .acquired(let node, _):
			if node.chassisID < 10 {
				return "[A \(node.chassisID)\(node.nodeID)]"
			}
			return "[A\(node.chassisID)\(node.nodeID)]"
		}
	}
}

extension KVCacheState: Comparable {
	static func < (lhs: KVCacheState, rhs: KVCacheState) -> Bool {
		var lhsTime = 0
		var rhsTime = 0

		switch lhs {
		case .empty:
			lhsTime = 0
		case .preparing(_, let time):
			lhsTime = time
		case .preparingMLX(_, let time):
			lhsTime = time
		case .cioReceived(_, let time):
			lhsTime = time
		case .mlxReceived(_, let time):
			lhsTime = time
		case .acquired(_, let time):
			lhsTime = time
		}

		switch rhs {
		case .empty:
			rhsTime = 0
		case .preparing(_, let time):
			rhsTime = time
		case .preparingMLX(_, let time):
			rhsTime = time
		case .cioReceived(_, let time):
			rhsTime = time
		case .mlxReceived(_, let time):
			rhsTime = time
		case .acquired(_, let time):
			rhsTime = time
		}

		return lhsTime < rhsTime
	}
}

class ComputeNode {
	var chassisID: Int
	var nodeID: Int
	var directConnections: [ComputeNode]
	var partnerNode: [ComputeNode]
	var kvCache: [KVCacheState]

	init(chassisID: Int, nodeID: Int) {
		self.chassisID = chassisID
		self.nodeID = nodeID
		self.directConnections = .init()
		self.kvCache = .init()
		self.partnerNode = .init()
	}

	init(nodeString: String) {
		let tmp = nodeString.components(separatedBy: ".")

		guard let chassis = Int(tmp[0]) else {
			preconditionFailure("Could not find chassis: \(tmp[0])")
		}

		guard let node = Int(tmp[1]) else {
			preconditionFailure("Could not find node: \(tmp[1])")
		}

		self.chassisID = chassis
		self.nodeID = node
		self.directConnections = .init()
		self.kvCache = .init()
		self.partnerNode = .init()
	}

	func addNodeConnection(link _: Int, node: ComputeNode) {
		self.directConnections.append(node)
	}

	func addPartnerNode(node: ComputeNode) {
		self.partnerNode.append(node)
	}

	func needsData() -> Bool {
		for kvCacheState in self.kvCache {
			if case .acquired = kvCacheState {
				continue
			}
			return true
		}
		return false
	}

	func missingData(from: ComputeNode) -> [Int] {
		var collection: [(node: Int, time: Int)] = .init()

		for (n, fromKvCacheState) in from.kvCache.enumerated() {
			if fromKvCacheState == .empty {
				continue
			}
			if case .acquired(_, let t) = fromKvCacheState {
				if self.kvCache[n] == .empty {
					collection.append((n, t))
					continue
				}
			}
			if case .cioReceived(_, let t) = fromKvCacheState {
				if self.kvCache[n] == .empty {
					collection.append((n, t))
					continue
				}
			}
			if case .mlxReceived(_, let t) = fromKvCacheState {
				if self.kvCache[n] == .empty {
					collection.append((n, t))
					continue
				}
			}
		}

		collection = collection.sorted {
			$0.time < $1.time
		}

		var retVal: [Int] = .init()

		for (node, _) in collection {
			retVal.append(node)
		}

		return retVal
	}

	func receiveDataCIO() {
		for (n, kvCacheState) in self.kvCache.enumerated() {
			if case .preparing(let receiving, _) = kvCacheState {
				self.kvCache[n] = .cioReceived(receiving, runningTime)
			}
		}
	}

	func receiveDataMLX() {
		for (n, kvCacheState) in self.kvCache.enumerated() {
			if case .preparingMLX(let receiving, _) = kvCacheState {
				self.kvCache[n] = .mlxReceived(receiving, runningTime)
			}
		}
	}

	func notifyUserspace() {
		for (n, kvCacheState) in self.kvCache.enumerated() {
			if case .cioReceived(let receiving, _) = kvCacheState {
				self.kvCache[n] = .acquired(receiving, runningTime)
			}
			if case .mlxReceived(let receiving, _) = kvCacheState {
				self.kvCache[n] = .acquired(receiving, runningTime)
			}
		}
	}
}

extension ComputeNode: CustomStringConvertible {
	var description: String {
		var tmp = ""
		for kvCache in self.kvCache {
			tmp += "\(kvCache)"
		}
		if self.chassisID < 10 {
			return " \(self.chassisID)/\(self.nodeID) :: \(tmp)"
		}
		return "\(self.chassisID)/\(self.nodeID) :: \(tmp)"
	}
}

extension ComputeNode: Equatable {
	static func == (lhs: ComputeNode, rhs: ComputeNode) -> Bool {
		lhs.chassisID == rhs.chassisID && lhs.nodeID == rhs.nodeID
	}
}

extension ComputeNode: Hashable {
	func hash(into hasher: inout Hasher) {
		hasher.combine(self.chassisID)
		hasher.combine(self.nodeID)
	}
}

extension ComputeNode: Comparable {
	static func < (lhs: ComputeNode, rhs: ComputeNode) -> Bool {
		if lhs.chassisID != rhs.chassisID {
			return lhs.chassisID < rhs.chassisID
		} else {
			return lhs.nodeID < rhs.nodeID
		}
	}
}

// MARK: - Main functions

func parseFile(lines: [String]) {
	// create all nodes
	var nodeCount = 0

	for line in lines {
		if line.isEmpty {
			continue
		}

		if line.hasPrefix("#") || line.isEmpty {
			continue
		}

		if line.contains("=") {
			let data = line.components(separatedBy: "=")
			let variable = data[0]
			let number = Int(data[1])!

			print("Setting \(variable) :: \(number)")

			if variable == "blockSizeBit" {
				blockSizeBit = number
			} else if variable == "CIOSpeedBitsPerSecond" {
				CIOSpeedBitsPerSecond = number
			} else if variable == "MLXSpeedBitsPerSecond" {
				MLXSpeedBitsPerSecond = number
			} else if variable == "initialBroadcastStartTimeNs" {
				initialBroadcastStartTimeNs = number
			} else if variable == "initialTbtSetupTimeNs" {
				initialTbtSetupTimeNs = number
			} else if variable == "initialMlxSetupTimeNs" {
				initialMlxSetupTimeNs = number
			} else if variable == "forwardTbtBroadcastStartTimeNs" {
				forwardTbtBroadcastStartTimeNs = number
			} else if variable == "forwardTbtSetupTimeNs" {
				forwardTbtSetupTimeNs = number
			} else if variable == "userSpaceNotifyTime" {
				userSpaceNotifyTime = number
			} else if variable == "hypercube" {
				hypercube = number
			}
			continue
		}

		let data = line.components(separatedBy: ",")

		guard let chassisID = Int(data[0]) else {
			preconditionFailure("Failed to read line \(line)")
		}

		// 4 new compute nodes
		for i in 0...3 {
			computeNodes.append(.init(chassisID: chassisID, nodeID: i))
			nodeCount += 1
		}
	}

	// connect all nodes
	for line in lines {
		if line.hasPrefix("#") || line.isEmpty || line.contains("=") {
			continue
		}

		let data = line.components(separatedBy: ",")

		guard let chassisID = Int(data[0]) else {
			preconditionFailure("Failed to read line \(line)")
		}

		// loop through each node in the chassis and add their connections
		for i in 0...3 {
			let tmp = ComputeNode(chassisID: chassisID, nodeID: i)
			let actualComputeNode = computeNodes.first(where: {
				$0 == tmp
			})

			guard let actualComputeNode = actualComputeNode else {
				preconditionFailure("Could not find computeNode: \(tmp)")
			}

			var connectionLine = data[i + 1]
			let removeCharacters: Set<Character> = ["{", "}"]
			connectionLine.removeAll(where: { removeCharacters.contains($0) })

			let connections = connectionLine.components(separatedBy: ";")

			for (link, connection) in connections.enumerated() {
				if connection == "X" {
					continue
				}

				if connection.isEmpty {
					continue
				}

				if connection.hasPrefix("P") {
					var tmp = connection
					tmp.removeFirst()

					let partnerNode = ComputeNode(nodeString: tmp)
					let actualPartnerNode = computeNodes.first(where: {
						$0 == partnerNode
					})
					if let actualPartnerNode = actualPartnerNode {
						actualComputeNode.addPartnerNode(node: actualPartnerNode)
					}
					continue
				}

				let connectionNode = ComputeNode(nodeString: connection)
				let actualConnectionNode = computeNodes.first(where: {
					$0 == connectionNode
				})

				if actualConnectionNode == nil {
					continue
				}

				guard let actualConnectionNode = actualConnectionNode else {
					preconditionFailure("Could not find connectionNode: \(connectionNode) while looking at node: \(actualComputeNode)")
				}

				actualComputeNode.addNodeConnection(link: link, node: actualConnectionNode)
			}
		}
	}

	for node in computeNodes {
		node.kvCache = .init(repeating: .empty, count: nodeCount)
	}
}

func openFile(filePath: String) throws {
	guard FileManager.default.fileExists(atPath: filePath) else {
		preconditionFailure("\(filePath) does not exist")
	}

	let fileData = try Data(contentsOf: URL(filePath: filePath))
	guard let fileString = String(data: fileData, encoding: .utf8) else {
		preconditionFailure("Failed to read chassissetup.csv")
	}

	let fileLines = fileString.components(separatedBy: "\n")

	parseFile(lines: fileLines)
}

func transferRequired() -> Bool {
	computeNodes.contains {
		$0.needsData()
	}
}

func nodesBroadcastCIO() -> Bool {
	var retval = false
	for node in computeNodes {
		for neighbor in node.directConnections {
			let transfers = neighbor.missingData(from: node)

			var ableToTransfer: Int? = nil

			// if chassis is different, check if my chassis doesnt have the data
			for potTransfer in transfers {
				if neighbor.chassisID != node.chassisID {
					var chassisHasIt = false

					for allnode in computeNodes {
						if allnode.chassisID == neighbor.chassisID {
							if allnode.kvCache[potTransfer] != .empty {
								chassisHasIt = true
								break
							}
						}
					}

					if chassisHasIt {
						continue
					}
				}
				ableToTransfer = potTransfer
				break
			}

			guard let ableToTransfer = ableToTransfer else {
				continue
			}

			neighbor.kvCache[ableToTransfer] = .preparing(node, runningTime)
			retval = true
		}
	}

	return retval
}

func getHyperCubePartnerChassis(chassis: Int) -> Int {
	if hypercube == 1 {
		if chassis % 2 == 0 {
			return chassis - 1
		} else {
			return chassis + 1
		}
	}
	return chassis
}

func nodesCheckPartnerTransfer() -> Bool {
	var retval = false
	for node in computeNodes {
		if !node.partnerNode.isEmpty {
			partnerLoop: for partnerNode in node.partnerNode {
				let possibleTransfers = partnerNode.missingData(from: node)
				guard !possibleTransfers.isEmpty else {
					// nothing to transfer for this partner node
					continue
				}

				let hyperCubePartner = getHyperCubePartnerChassis(chassis: partnerNode.chassisID)
				for possibleTransfer in possibleTransfers {
					var foundTransfer = true
					for loopNode in computeNodes {
						guard loopNode.chassisID == hyperCubePartner || loopNode.chassisID == partnerNode.chassisID else {
							continue
						}

						if loopNode.kvCache[possibleTransfer] != .empty {
							foundTransfer = false
							break
						}
					}

					if foundTransfer {
						partnerNode.kvCache[possibleTransfer] = .preparingMLX(node, runningTime)
						retval = true
						break partnerLoop
					}
				}
			}
		}
	}

	return retval
}

func nodesAcknowledgeBroadcastCIO() -> Bool {
	var retval = false
	for node in computeNodes {
		node.receiveDataCIO()
		retval = true
	}

	return retval
}

func nodesAcknowledgeMLX() -> Bool {
	var retval = false
	for node in computeNodes {
		node.receiveDataMLX()
		retval = true
	}

	return retval
}

func nodesCheckRebroadcastCIO() -> Bool {
	for node in computeNodes {
		for neighbor in node.directConnections {
			let neighborMissingDatas = neighbor.missingData(from: node)

			// for all the missing data, that is cioReceived, it will be a single
			// reforward cost
			for neighborMissingData in neighborMissingDatas {
				if case .cioReceived = node.kvCache[neighborMissingData] {
					return true
				}
			}
		}
	}

	return false
}

func nodesNotifyUserspace() {
	for node in computeNodes {
		node.notifyUserspace()
	}
}

enum Event {
	case requestReceived(Int)
	case setupTBT(Int)
	case notifyUserSpace(Int)
	case transferComplete(Int)
	case setupMLX(Int)
	case mlxTransferComplete(Int)
}

extension Event: Comparable {
	static func < (lhs: Event, rhs: Event) -> Bool {
		var lhsTime = 0
		var rhsTime = 0

		switch lhs {
		case .requestReceived(let time):
			lhsTime = time
		case .setupTBT(let time):
			lhsTime = time
		case .notifyUserSpace(let time):
			lhsTime = time
		case .transferComplete(let time):
			lhsTime = time
		case .setupMLX(let time):
			lhsTime = time
		case .mlxTransferComplete(let time):
			lhsTime = time
		}

		switch rhs {
		case .requestReceived(let time):
			rhsTime = time
		case .setupTBT(let time):
			rhsTime = time
		case .notifyUserSpace(let time):
			rhsTime = time
		case .transferComplete(let time):
			rhsTime = time
		case .setupMLX(let time):
			rhsTime = time
		case .mlxTransferComplete(let time):
			rhsTime = time
		}

		return lhsTime < rhsTime
	}
}

var runningTime = 0

func transferKVCache() {
	for (n, node) in computeNodes.enumerated() {
		node.kvCache[n] = .acquired(node, runningTime)
	}

	let transferTime = Int(Double(blockSizeBit) / Double(CIOSpeedBitsPerSecond) * 1_000_000_000)
	let mlxTransferTime = Int(Double(blockSizeBit) / Double(MLXSpeedBitsPerSecond) * 1_000_000_000)

	var events: [Event] = .init()
	print("[\(runningTime)ns] :: --> Start")
	events.append(.requestReceived(runningTime + initialBroadcastStartTimeNs))

	while !events.isEmpty || transferRequired() {
		events.sort()

		if events.isEmpty {
			print("[\(runningTime)ns] :: --> Transfer started")
			events.append(.setupTBT(runningTime + initialTbtSetupTimeNs))
			events.append(.setupMLX(runningTime + initialMlxSetupTimeNs))
		}

		let handleEvent = events.removeFirst()

		switch handleEvent {
		// Kick off transfer
		case .requestReceived(let time):
			runningTime = time

			// If data is still required, add setupTBT time
			if transferRequired() {
				print("[\(runningTime)ns] :: --> Transfer started")
				events.append(.setupTBT(runningTime + initialTbtSetupTimeNs))
				events.append(.setupMLX(runningTime + initialMlxSetupTimeNs))
			}

		// TBT has been setup
		case .setupTBT(let time):
			runningTime = time

			// Check if nodes can begin broadcasting on CIO
			if nodesBroadcastCIO() {
				print("[\(runningTime)ns] :: --> TBT Transmit commands submitted")
				events.append(.transferComplete(runningTime + transferTime))
			} else {
				print("TBTSetup at T:\(time) but no nodes prepared to broadcast.")
			}

		// Nodes have broadcast
		case .transferComplete(let time):
			runningTime = time
			if nodesAcknowledgeBroadcastCIO() {
				print("[\(runningTime)ns] :: --> TBT Receive commands triggered")
				events.append(.notifyUserSpace(runningTime + userSpaceNotifyTime))
			} else {
				print("TransferComplete at T:\(time) but no nodes acknowledged CIO broadcast.")
			}

			if nodesCheckRebroadcastCIO() {
				print("[\(runningTime)ns] :: --> TBT Determined can re-broadcast")
				events.append(.setupTBT(runningTime + forwardTbtBroadcastStartTimeNs))
			}

		case .notifyUserSpace(let time):
			runningTime = time
			print("[\(runningTime)ns] :: --> Notified user space")
			nodesNotifyUserspace()
			if transferRequired() {
				events.append(.setupTBT(runningTime + initialTbtSetupTimeNs))
				events.append(.setupMLX(runningTime + initialMlxSetupTimeNs))
			}

		case .setupMLX(let time):
			runningTime = time
			print("[\(runningTime)ns] :: --> Checking for MLX partner transfer")
			if nodesCheckPartnerTransfer() {
				print("[\(runningTime)ns] :: --> MLX Transmit Request submitted")
				events.append(.mlxTransferComplete(runningTime + mlxTransferTime))
			}

		case .mlxTransferComplete(let time):
			runningTime = time
			if nodesAcknowledgeMLX() {
				print("[\(runningTime)ns] :: --> MLX Transmit complete")
				events.append(.notifyUserSpace(runningTime + userSpaceNotifyTime))
			}
			print("[\(runningTime)ns] :: --> Checking for MLX partner transfer")
			if nodesCheckPartnerTransfer() {
				print("[\(runningTime)ns] :: --> MLX Transmit Request submitted")
				events.append(.mlxTransferComplete(runningTime + mlxTransferTime))
			}
		}

		var output = ""
		for computeNode in computeNodes {
			output += "\(computeNode)\n"
		}

		print("\(output)")
	}

	print("Total transfer time: \(runningTime)ns")
	print("\tBlock size: \(blockSizeBit)bits == \(blockSizeBit / 8 / 1_024)KB")
	print("\tTransfer Initiation Time: \(initialBroadcastStartTimeNs)ns")
	print("\tTBT Setup Time: \(initialTbtSetupTimeNs)ns")
	print("\tForward Start Time (Parallel): \(forwardTbtBroadcastStartTimeNs)ns")
	print("\tForward TBT Setup Time (Parallel): \(forwardTbtSetupTimeNs)ns")
	print("\tUserspace Notify Time (Parallel): \(userSpaceNotifyTime)ns")
	print("\tCIO Transfer Time: \(transferTime)ns")
	print("\tMLX Transfer Time: \(mlxTransferTime)ns")
}

var computeNodes: [ComputeNode] = .init()

var blockSizeBit = 512 * 1_024 * 8
var CIOSpeedBitsPerSecond = 35_600_000_000 * 2
var MLXSpeedBitsPerSecond = 35_600_000_000

var initialBroadcastStartTimeNs = 0_000
var initialTbtSetupTimeNs = 0_000
var initialMlxSetupTimeNs = 0_000

var forwardTbtBroadcastStartTimeNs = 0_000
var forwardTbtSetupTimeNs = 0_000

var userSpaceNotifyTime = 0_000

var hypercube = 1

func main() throws {
	let args = CommandLine.arguments

	if args.contains(where: { $0 == "--version" }) {
		print("version: 1.0.0-October23")
		exit(0)
	}

	if CommandLine.argc != 2 {
		print("Usage: meshsim <chassissetup.csv>")
		exit(0)
	}

	try openFile(filePath: args[1])
	transferKVCache()
}

try main()
