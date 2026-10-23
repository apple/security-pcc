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
//  Router8Hypercube.swift
//  ensembleconfig
//
//  Created by Sumit Kamath on 11/17/23.
//

import Foundation

public final class Router8Hypercube: Router {
	struct NodeState: Equatable {
		/// Node rank
		let node: Int
		/// If the node is in the current node's chassis.
		let inChassis: Bool
		/// TX established to this node (from current node)
		var txEstablished: Bool
		/// RX established from this node (to current node)
		var rxEstablished: Bool
		/// If the node is in the current node's partition.
		let inPartition: Bool
	}

	var _configuration: RouterConfiguration
	var ensembleFailed: Bool
	var expectedTxConnections: Int
	var expectedRxConnections: Int
	var expectedNetworkConnections: Int
	var transferMap: [Int: CIOTransferState]
	var routeMap: [Int: String]
	var cioMap: [Int: Int]

	var ensembleNodes: [Int: NodeState]
	var partnerNode: Int?
	var forwardedPartnerToChassis: Bool

	var myPartition: Int = 0
	var partitionPartners: [Int: NodeState] = .init()

	private func getParitionForNode(_ node: Int) -> Int {
		node / 8
	}

	private func isPartitionPartner(_ node: Int) -> Bool {
		(self.nodeRank % 8) == (node % 8)
	}

	public var configuration: RouterConfiguration {
		self._configuration
	}

	public var nodeRank: Int {
		self.configuration.node.rank
	}

	public var allInnerChassisDiscovered: Bool {
		let currentChassis = self._configuration.node.chassisID
		let inChassisDiscoveredNodes = self.ensembleNodes.values.filter {
			$0.inChassis && $0.rxEstablished && $0.txEstablished
		}

		return inChassisDiscoveredNodes.count == 4
	}

	public var partnerNodeDiscovered: Bool {
		guard let partnerNode = partnerNode else {
			return false
		}

		guard let partnerInfo = self.ensembleNodes[partnerNode] else {
			return false
		}

		return partnerInfo.rxEstablished && partnerInfo.txEstablished
	}

	public required init(configuration: RouterConfiguration) throws {
		self._configuration = configuration
		self.ensembleFailed = false
		self.expectedRxConnections = 7
		self.expectedTxConnections = 7
		self.transferMap = .init()
		self.routeMap = .init()
		self.cioMap = .init()
		self.ensembleNodes = .init()
		self.partnerNode = nil
		self.forwardedPartnerToChassis = false
		self.expectedNetworkConnections = configuration.ensemble.partitionCount - 1

		guard configuration.ensemble.nodeCount == 8 ||
			configuration.ensemble.nodeCount == 16 ||
			configuration.ensemble.nodeCount == 32 else {
			throw """
				Invalid number of nodes in ensemble configuration:
				\(configuration.ensemble.nodeCount). Expected to be a multiple of 8."
				"""
		}

		self.myPartition = self.nodeRank / 8

		self.transferMap[self.nodeRank] = .init(
			outputChannels: [],
			inputChannel: nil)

		for node in configuration.ensemble.nodes {
			if self.getParitionForNode(node.rank) == self.myPartition {
				self.ensembleNodes[node.rank] = .init(
					node: node.rank,
					inChassis: node.chassisID == configuration.node.chassisID,
					txEstablished: node.rank == self.nodeRank,
					rxEstablished: node.rank == self.nodeRank,
					inPartition: true)
			} else {
				if self.isPartitionPartner(node.rank) {
					self.partitionPartners[node.rank] = .init(
						node: node.rank,
						inChassis: false,
						txEstablished: false,
						rxEstablished: false,
						inPartition: false)

					guard let hostName = node.hostname else {
						print("No hostname for partner node: \(node.rank)")
						throw "Invalid configuration"
					}

					self.configuration.delegate.addPeerHostname(hostName: hostName, nodeRank: node.rank)
				}
			}
		}
	}

	public func networkConnectionChange(
		node: Int,
		connected: Bool) {
		guard self.partitionPartners.keys.contains(where: { $0 == node }) else {
			print("Network Connection to an unexpected node: \(node). I am node \(self.nodeRank).")
			return
		}

		self.partitionPartners[node]?.rxEstablished = connected
		self.partitionPartners[node]?.txEstablished = connected

		if connected {
			self.expectedNetworkConnections -= 1
		}

		if self.isEnsembleReady() {
			self.configuration.delegate.ensembleReady()
		}
	}

	public func channelChange(
		channelIndex: Int,
		node: Int,
		chassis _: String,
		connected: Bool) {
		if !connected {
			if let node = cioMap[channelIndex] {
				self.cioMap.removeValue(forKey: channelIndex)
				self.ensembleFailed = true
				self.configuration.delegate.ensembleFailed()
			}
			return
		}

		// All CIO channels are used in a hypercube
		// The node should be in the ensemble config, if it isn't, disable
		// the channel as a precaution and the ensemble has failed
		let ensembleNode = self.configuration.ensemble.nodes.first(where: {
			$0.rank == node
		})

		if ensembleNode == nil {
			do {
				try disableChannel(channelIndex)
			} catch {
				print("Failed to disable channel: \(error)")
			}
			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		if self.transferMap[node] != nil {
			return
		}

		// Add the node to the transfer map
		self.transferMap[node] = .init(
			outputChannels: [],
			inputChannel: nil)
		// And to the cio map
		self.cioMap[channelIndex] = node

		guard let nodeInfo = self.ensembleNodes[node] else {
			print("Channel change on unknown node: \(node)")
			self.configuration.delegate.ensembleFailed()
			return
		}

		// Found our partner node
		if !nodeInfo.inChassis {
			self.partnerNode = node
		}

		// make a connection to in-ensemble nodes
		do {
			try self.configuration.backend.establishTXConnection(
				node: self.nodeRank,
				cioChannelIndex: channelIndex)
		} catch {
			print("Failed to establish connection to node: \(node)")
			self.ensembleFailed = true

			self.configuration.delegate.ensembleFailed()
			return
		}
	}

	public func isEnsembleReady() -> Bool {
		!self.ensembleFailed &&
			self.expectedRxConnections == 0 &&
			self.expectedTxConnections == 0 &&
			self.expectedNetworkConnections == 0
	}

	public func isCIOEnsembleReady() -> Bool {
		!self.ensembleFailed &&
			self.expectedRxConnections == 0 &&
			self.expectedTxConnections == 0
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
			self.ensembleNodes[node]?.rxEstablished = true
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
				self.ensembleNodes[receiver]?.txEstablished = true
				self.routeMap[receiver] = "\(self.nodeRank)->\(receiver)"
			}
		}

		if self.isCIOEnsembleReady() {
			// We Lock the ensemble here and now we're ready to party!
			do {
				try self.configuration.backend.lock()
			} catch {
				print("Could not lock the mesh configuration!")
				self.ensembleFailed = true
				self.configuration.delegate.ensembleFailed()
				return
			}

			if self.isEnsembleReady() {
				self.configuration.delegate.ensembleReady()
			}
			return
		}

		// Did not discover all inner chassis nodes or the partner node fully
		if !self.allInnerChassisDiscovered || !self.partnerNodeDiscovered || self.forwardedPartnerToChassis {
			return
		}

		self.forwardedPartnerToChassis = true

		// Inner chassis and partner node discovered, forward the partner
		// node to all the inner chassis nodes
		let innerChassisNodes = self.ensembleNodes.values.filter { $0.inChassis && $0.node != self.nodeRank }
		guard let partnerNode = self.partnerNode else {
			fatalError("""
				Partner node not set when trying to make TX connections. This is a
				logic error
				""")
		}

		for innerChassisNode in innerChassisNodes {
			let nodeCIOChannel = self.transferMap[innerChassisNode.node]?.inputChannel
			guard let nodeCIOChannel = nodeCIOChannel else {
				fatalError("""
					Attempting to make TX connections for partner node to
					in-chassis nodes, before a input channel has been established for
					node \(innerChassisNode.node). This is a logic error.
					""")
			}

			do {
				try self.configuration.backend.establishTXConnection(node: partnerNode, cioChannelIndex: nodeCIOChannel)
			} catch {
				print("""
					Failed to forward \(partnerNode)'s data to
					\(innerChassisNode.node) on CIO\(nodeCIOChannel)
					""")
				self.ensembleFailed = true

				self.configuration.delegate.ensembleFailed()
				return
			}
		}
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
		self.ensembleNodes[forward.receiver]?.txEstablished = true
	}

	public func getCIOTransferMap() -> [Int: CIOTransferState] {
		self.transferMap
	}

	public func getRoutes() -> [Int: String] {
		self.routeMap
	}
}

extension Router8Hypercube {
	func sendForwardMessage(source: Int, receiver: Int) throws {
		let forwardMessage: EnsembleControlMessage =
			.ForwardMessage(.init(forwarder: nodeRank, receiver: receiver))

		let forwardMessageData = try JSONEncoder().encode(forwardMessage)

		try self.configuration.backend.sendControlMessage(node: source, message: forwardMessageData)
	}
}
