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
//  Router8.swift
//  ensembleconfig
//
//  Created by Sumit Kamath on 11/17/23.
//

import Foundation

public final class Router8: Router {
	struct NodeState {
		/// Node rank
		let node: Int
		/// If the node is in the current node's chassis.
		let inChassis: Bool
		/// If this node is an outer node (in-chassis and partner-chassis)
		var outerNode: Bool
		/// TX established to this node (from current node)
		var txEstablished: Bool
		/// RX established from this node (to current node)
		var rxEstablished: Bool
	}

	var _configuration: RouterConfiguration
	var ensembleFailed: Bool
	var expectedTxConnections: Int
	var expectedRxConnections: Int
	var transferMap: [Int: CIOTransferState]
	var routeMap: [Int: String]
	var cioMap: [Int: Int]

	let partnerChassis: String
	var ensembleNodes: [NodeState]
	var outerPartnerNode: Int?
	var sentOuterNodeMessage: Bool
	var forwardedOuterPartnerNode: Bool
	var forwardedInnerNodes: Bool
	var forwardedPartnerChassisInnerNodes: Bool

	public var configuration: RouterConfiguration {
		self._configuration
	}

	public var nodeRank: Int {
		self.configuration.node.rank
	}

	var isOuterNode: Bool {
		get throws {
			let tmp = self.ensembleNodes.first(where: {
				$0.node == self._configuration.node.rank
			})
			guard let tmp = tmp else {
				throw "Could not find self in ensembleNodes"
			}

			return tmp.outerNode
		}
	}

	var allInnerChassisConnected: Bool {
		let innerFullyConnectedNodes = self.ensembleNodes.filter {
			$0.inChassis && $0.rxEstablished && $0.txEstablished
		}
		return innerFullyConnectedNodes.count == 4
	}

	var outerPartnerConnected: Bool {
		get throws {
			guard let outerPartner = outerPartnerNode else {
				return false
			}
			let tmp = self.ensembleNodes.first(where: {
				$0.node == outerPartner
			})

			guard let tmp = tmp else {
				throw "Could not find outer partner in ensembleNodes. Initialization failed?"
			}

			return tmp.txEstablished && tmp.rxEstablished
		}
	}

	public required init(configuration: RouterConfiguration) throws {
		self._configuration = configuration
		self.ensembleFailed = false
		self.expectedRxConnections = 7
		// For now, all nodes will transmit to 3 nodes only
		self.expectedTxConnections = 3
		self.transferMap = .init()
		self.routeMap = .init()
		self.cioMap = .init()

		self.ensembleNodes = .init()
		self.outerPartnerNode = nil
		self.sentOuterNodeMessage = false
		self.forwardedOuterPartnerNode = false
		self.forwardedInnerNodes = false
		self.forwardedPartnerChassisInnerNodes = false

		guard configuration.ensemble.nodeCount == 8 else {
			throw """
				Invalid number of nodes in ensemble configuration:
				\(configuration.ensemble.nodeCount). Expected 8."
				"""
		}

		let currentChassis = configuration.node.chassisID
		let alternateChassisNodes = configuration.ensemble.nodes.filter {
			$0.chassisID != currentChassis
		}

		guard let tmp = alternateChassisNodes.first,
		      alternateChassisNodes.count == 4
		else {
			throw """
				8 node ensembles require 4 nodes with an alternate chassis ID.
				Ensemble configuration has \(alternateChassisNodes.count)
				non-chassis nodes.
				"""
		}

		self.partnerChassis = tmp.chassisID

		// Verify there are 4 nodes in the other chassis
		let partnerChassisNodes = configuration.ensemble.nodes.filter {
			$0.chassisID == self.partnerChassis
		}
		guard partnerChassisNodes.count == 4 else {
			throw """
				8 node ensembles require 4 nodes with the same alternate chassis ID.
				Ensemble configuration has \(partnerChassisNodes.count) nodes with
				alternate chassis ID: \(self.partnerChassis).
				"""
		}

		// Verify there are 4 nodes in the current chassis
		let currentChassisNodes = configuration.ensemble.nodes.filter {
			$0.chassisID == currentChassis
		}
		guard currentChassisNodes.count == 4 else {
			throw """
				8 node ensembles require 4 nodes with the same chassis ID.
				Ensemble configuration has \(currentChassisNodes.count) nodes with
				alternate chassis ID: \(currentChassis).
				"""
		}

		self.transferMap[self.nodeRank] = .init(
			outputChannels: [],
			inputChannel: nil)
		for node in configuration.ensemble.nodes {
			self.ensembleNodes.append(.init(
				node: node.rank,
				inChassis: node.chassisID == currentChassis,
				outerNode: false,
				txEstablished: node.rank == self.nodeRank,
				rxEstablished: node.rank == self.nodeRank))
		}
	}

	public func isEnsembleReady() -> Bool {
		!self.ensembleFailed &&
			self.expectedRxConnections == 0 &&
			self.expectedTxConnections == 0
	}

	public func channelChange(
		channelIndex: Int,
		node: Int,
		chassis: String,
		connected: Bool) {
		if !connected {
			if let node = cioMap[channelIndex] {
				self.cioMap.removeValue(forKey: channelIndex)
				self.ensembleFailed = true
				self.configuration.delegate.ensembleFailed()
			}
			return
		}

		// Disable any CIO channels to non-ensemble nodes.
		let ensembleNode = self.configuration.ensemble.nodes.first(where: {
			$0.rank == node
		})

		if ensembleNode == nil {
			do {
				try disableChannel(channelIndex)
			} catch {
				print("Failed to disable channel: \(error)")
			}
			return
		}

		// Add the node to the transfer map
		self.transferMap[node] = .init(
			outputChannels: [],
			inputChannel: nil)
		// Add the node to the cio map
		self.cioMap[channelIndex] = node

		// If the channel is connected out of the chassis, we are an outer node.
		if chassis == self.partnerChassis {
			let selfIdx = self.ensembleNodes.firstIndex(where: {
				$0.node == self._configuration.node.rank
			})
			guard let selfIdx = selfIdx else {
				fatalError("""
					Could not find self in ensembleNodes. Initialization failed?
					""")
			}
			self.ensembleNodes[selfIdx].outerNode = true

			let partnerIdx = self.ensembleNodes.firstIndex(where: {
				$0.node == node
			})
			guard let partnerIdx = partnerIdx else {
				fatalError("""
					Could not find partner in ensembleNodes. Initialization failed?
					""")
			}
			// Do not mark the ensemble partner node as outer node because
			// we need to wait for the node to let us know it is safe to
			// forward data to it. This is done when it sends the outer node
			// message.

			self.outerPartnerNode = self.ensembleNodes[partnerIdx].node

			// Outer nodes have to transmit extra transfers:
			// +1 for self connection to partner-chassis
			// +2 for inner nodes to partner-chassis
			// +2 for lower inner-node in partner-chassis
			// +3 for partner-node to self-chassis
			self.expectedTxConnections += 8
		}

		// make a connection to in-ensemble nodes
		do {
			try self.configuration.backend.establishTXConnection(node: self.nodeRank, cioChannelIndex: channelIndex)
		} catch {
			print("Failed to establish connection to node: \(node)")
			self.ensembleFailed = true

			self.configuration.delegate.ensembleFailed()
		}
	}

	public func connectionChange(
		direction: BackendConnectionDirection,
		channelIndex: Int,
		node: Int,
		connected: Bool) {
		if !connected {
			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		if self.transferMap[node] == nil {
			self.transferMap[node] = .init(outputChannels: [], inputChannel: nil)
		}

		if direction == .rx {
			self.ensembleNodes[node].rxEstablished = true
			self.expectedRxConnections -= 1
			self.transferMap[node]?.inputChannel = channelIndex
		} else {
			self.expectedTxConnections -= 1
			self.transferMap[node]?.outputChannels.append(channelIndex)

			guard let receiver = cioMap[channelIndex] else {
				print("No CIO receiver for CIO\(channelIndex)")

				self.ensembleFailed = true
				self.configuration.delegate.ensembleFailed()
				return
			}

			if node != self.nodeRank {
				do {
					try sendForwardMessage(source: node, receiver: receiver)
				} catch {
					print("Failed to send forward message: \(error)")

					self.ensembleFailed = true
					self.configuration.delegate.ensembleFailed()
					return
				}
			} else {
				self.ensembleNodes[receiver].txEstablished = true
				self.routeMap[receiver] = "\(self.nodeRank)->\(receiver)"
			}
		}

		if self.isEnsembleReady() {
			// We Lock the ensemble here and now we're ready to party!
			do {
				try self.configuration.backend.lock()
			} catch {
				print("Could not lock the mesh configuration!")
				self.ensembleFailed = true
				self.configuration.delegate.ensembleFailed()
				return
			}

			self.configuration.delegate.ensembleReady()
			return
		}

		var outerNode = false
		do {
			outerNode = try self.isOuterNode
		} catch {
			print("Failed to determine if we are outer node, initialized failed?")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		// if we are not an outer node, we do nothing, we simply update our
		// transfer maps and expected counts, which is already done
		if self.ensembleFailed || !outerNode {
			return
		}

		// When we have all inner chassis connections and the outer-partner
		// connections, we can send the outer node message to all connected
		// nodes
		var allSelfConnectionsDone = false
		do {
			allSelfConnectionsDone = try self.allInnerChassisConnected && self.outerPartnerConnected
		} catch {
			print("Failed to determine if all self connections done: \(error)")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		if !allSelfConnectionsDone {
			return
		}

		do {
			try sendOuternodeMessage()
		} catch {
			print("Failed to send outernode message \(error)")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		// Attempt outernode forwards now
		setupOuternodeForwards()
	}

	public func networkConnectionChange(
		node: Int,
		connected: Bool) {
		print("Network Connection change is not supported on router8")
	}

	public func getCIOTransferMap() -> [Int: CIOTransferState] {
		self.transferMap
	}

	public func getRoutes() -> [Int: String] {
		self.routeMap
	}

	public func forwardMessage(_ forward: EnsembleControlMessage.Forward) {
		guard let routeToForwarder = routeMap[forward.forwarder] else {
			print("""
				Got a forwarding message: Forwarder:\(forward.forwarder)
				receiver:\(forward.receiver) before a route has been established
				to forwarder.
				""")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		self.routeMap[forward.receiver] = routeToForwarder + "->\(forward.receiver)"
		self.ensembleNodes[forward.receiver].txEstablished = true
	}
}

/// Internal functions specific for 8Node Ensembles
extension Router8 {
	func setupOuternodeForwards() {
		do {
			guard try self.isOuterNode else {
				fatalError("Only outernodes should attempt outernode forwards")
			}
		} catch {
			print("Failed to determine if outernode. Initialization failed: \(error)")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		// We need all our self connections done before starting to forward
		var allSelfConnectionsDone = false
		do {
			allSelfConnectionsDone = try self.allInnerChassisConnected && self.outerPartnerConnected
		} catch {
			print("Failed to determine if all self connections done: \(error)")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		if !allSelfConnectionsDone {
			return
		}

		// We need to know all 3 outer nodes (2 in chassis, 1 partner)
		let outerNodes = self.ensembleNodes.filter(\.outerNode)
		guard outerNodes.count == 3 else {
			return
		}

		// Make TX connections for outer-partner node to all in-chassis nodes
		// Rule #1
		do {
			try self.forwardOuterPartnerNodeInChassis()
		} catch {
			print("Failed to forward outer partner node in chassis")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		// Forward in-chassis inner node to outer partner.
		// Rule #2 setup
		do {
			try self.forwardInnerNodesToOuterPartner()
		} catch {
			print("Failed to forwad inner-nodes to outer-partner: \(error)")
			self.ensembleFailed = true

			self.configuration.delegate.ensembleFailed()
			return
		}

		// Attempt to forward partner chassis inner nodes if we have
		// all the connections and know outer node ranks.
		do {
			try self.forwardPartnerChassisInnerNodes()
		} catch {
			print("Failed to foward partner-chassis inner nodes: \(error)")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}
	}

	func sendOuternodeMessage() throws {
		guard !self.sentOuterNodeMessage else {
			return
		}

		self.sentOuterNodeMessage = true

		let outernodeMessage: EnsembleControlMessage =
			.OuterNodeMessage(.init(
				nodeID: nodeRank,
				chassisID: configuration.node.chassisID))

		let outernodeMessageData = try JSONEncoder().encode(outernodeMessage)

		for ensembleNode in self.ensembleNodes {
			if ensembleNode.node != self.nodeRank,
			   ensembleNode.txEstablished {
				try self.configuration.backend.sendControlMessage(
					node: ensembleNode.node,
					message: outernodeMessageData)
			}
		}
	}

	func forwardOuterPartnerNodeInChassis() throws {
		guard !self.forwardedOuterPartnerNode else {
			return
		}

		guard let outerPartnerNode = outerPartnerNode else {
			fatalError("""
				Attempting to make TX connections for outer-partner node to in-chassis
				nodes before the outer partner node has been set. This is a logic
				error.
				""")
		}

		self.forwardedOuterPartnerNode = true

		for ensembleNode in self.ensembleNodes {
			if ensembleNode.inChassis,
			   ensembleNode.node != self.nodeRank {
				// Figure out the input CIO channel for this in-chassis node,
				// we are going to send the outer-partner node on that cio channel
				let nodeCIOChannel = self.transferMap[ensembleNode.node]?.inputChannel
				guard let nodeCIOChannel = nodeCIOChannel else {
					fatalError("""
						Attempting to make TX connections for outer-partner node to
						in-chassis nodes, before a input channel has been established for
						node \(ensembleNode.node). This is a logic error.
						""")
				}

				do {
					try self.configuration.backend.establishTXConnection(
						node: outerPartnerNode, cioChannelIndex: nodeCIOChannel)
				} catch {
					print("""
						Failed to forward \(outerPartnerNode)'s data to
						\(ensembleNode.node) on CIO\(nodeCIOChannel)
						""")
					self.ensembleFailed = true

					self.configuration.delegate.ensembleFailed()
					throw error
				}
			}
		}
	}

	func forwardInnerNodesToOuterPartner() throws {
		guard !self.forwardedInnerNodes else {
			return
		}

		guard let outerPartnerNode = outerPartnerNode else {
			fatalError("""
				Attempting to make TX connections for inner in-chassis nodes to
				outer-partner node before the outer partner node has been set. This is
				a logic error.
				""")
		}

		let outerPartnerNodeCIO = self.transferMap[outerPartnerNode]?.inputChannel
		guard let outerPartnerNodeCIO = outerPartnerNodeCIO else {
			return
		}

		let innerChassisNodes = self.ensembleNodes.filter {
			$0.inChassis && !$0.outerNode
		}
		guard innerChassisNodes.count == 2 else {
			return
		}

		self.forwardedInnerNodes = true

		for innerChassisNode in innerChassisNodes {
			do {
				try self.configuration.backend.establishTXConnection(
					node: innerChassisNode.node, cioChannelIndex: outerPartnerNodeCIO)
			} catch {
				print("""
					Failed to forward \(innerChassisNode.node)'s data to
					\(outerPartnerNode) on CIO\(outerPartnerNodeCIO)
					""")
				self.ensembleFailed = true

				self.configuration.delegate.ensembleFailed()
				return
			}
		}
	}

	func forwardPartnerChassisInnerNodes() throws {
		guard !self.forwardedPartnerChassisInnerNodes else {
			return
		}

		let inChassisOuterNodes = self.ensembleNodes.filter {
			$0.inChassis && $0.outerNode
		}
		guard inChassisOuterNodes.count == 2 else {
			print("inChassisOuterNodes: \(inChassisOuterNodes.count)")
			return
		}

		let inChassisInnerNodes = self.ensembleNodes.filter {
			$0.inChassis && !$0.outerNode
		}
		guard inChassisInnerNodes.count == 2 else {
			print("inChassisInnerNodes: \(inChassisInnerNodes.count)")
			return
		}

		let otherOuterNode = inChassisOuterNodes.first(where: {
			$0.node != self.nodeRank
		})
		guard let otherOuterNode = otherOuterNode else {
			return
		}

		// Found all the outernodes in the chassis, this is enough to figure out
		// what forwarding needs to happen for partner chassis inner nodes.
		guard let outerPartnerNode = outerPartnerNode else {
			return
		}

		let outerPartnerNodeCIO = self.transferMap[outerPartnerNode]?.inputChannel
		guard let outerPartnerNodeCIO = outerPartnerNodeCIO else {
			/// Attempting to forward partner-chassis inner-nodes to in-chassis
			/// inner-nodes before a input channel has been established. Wait for
			/// it to be established
			print("outerPartnerNodeCIO not defined")
			return
		}

		// First let's get a list of all the nodes coming in on this CIO channel
		// That is not the outer partner node. There has to be 2 inner

		var partnerChassisInnerNodes: [Int] = .init()
		for (node, cioState) in self.transferMap {
			if cioState.inputChannel == outerPartnerNodeCIO,
			   node != outerPartnerNode {
				partnerChassisInnerNodes.append(node)
			}
		}
		guard partnerChassisInnerNodes.count == 2 else {
			return
		}

		self.forwardedPartnerChassisInnerNodes = true

		if otherOuterNode.node < self.nodeRank {
			// forward the higher of the 2 inner
			partnerChassisInnerNodes.sort(by: >)
		} else {
			// forward the lower of the 2 inner
			partnerChassisInnerNodes.sort()
		}

		for inInnerNode in inChassisInnerNodes {
			let innerNodeCIO = self.transferMap[inInnerNode.node]?.inputChannel
			guard let innerNodeCIO = innerNodeCIO else {
				fatalError("""
					Attempting to forward partner-chassis inner-nodes to in-chassis
					inner-nodes before a input channel has been established for inner
					node \(inInnerNode.node). This is a logic error.
					""")
			}

			do {
				try self.configuration.backend.establishTXConnection(
					node: partnerChassisInnerNodes[0], cioChannelIndex: innerNodeCIO)
			} catch {
				print("""
					Failed to forward \(partnerChassisInnerNodes[0])'s data to
					\(inInnerNode.node) on CIO\(innerNodeCIO)
					""")
				self.ensembleFailed = true

				self.configuration.delegate.ensembleFailed()
				return
			}
		}
	}

	public func outernodeMessage(_ outerNode: EnsembleControlMessage.OuterNode) {
		let nodeIdx = self.ensembleNodes.firstIndex(where: { $0.node == outerNode.nodeID })
		guard let nodeIdx = nodeIdx else {
			fatalError("""
				Got outer node message from node\(outerNode.nodeID) before
				initialization completed.
				""")
		}

		self.ensembleNodes[nodeIdx].outerNode = true

		do {
			let outerNode = try isOuterNode
			if !outerNode {
				return
			}
		} catch {
			print("Failed to determine if outernode. Initialization failed: \(error)")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		self.setupOuternodeForwards()
	}

	func sendForwardMessage(source: Int, receiver: Int) throws {
		let forwardMessage: EnsembleControlMessage =
			.ForwardMessage(.init(forwarder: nodeRank, receiver: receiver))

		let forwardMessageData = try JSONEncoder().encode(forwardMessage)

		try self.configuration.backend.sendControlMessage(node: source, message: forwardMessageData)
	}
}
