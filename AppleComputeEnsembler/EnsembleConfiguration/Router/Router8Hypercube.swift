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
import OSLog

private let logger = Logger(subsystem: kEnsemblerPrefix, category: "Router8Hypercube")

final class Router8Hypercube: Router {
	internal struct NodeState: Equatable {
		/// Node rank
		internal let node: Int
		/// If the node is in the current node's chassis.
		internal let inChassis: Bool
		/// TX established to this node (from current node)
		internal var txEstablished: Bool
		/// RX established from this node (to current node)
		internal var rxEstablished: Bool
		/// If the node is in the current node's partition.
		internal let inPartition: Bool
	}

	internal var _configuration: RouterConfiguration
	internal var ensembleFailed: Bool
	internal var expectedTxConnections: Int
	internal var expectedRxConnections: Int
	internal var expectedNetworkConnections: Int
	internal var transferMap: [Int: CIOTransferState]
	#if false
	internal var routeMap: [Int: String]
	#endif
	internal var cioMap: [Int: Int]

	internal var ensembleNodes: [Int: NodeState]
	internal var partnerNode: Int?
	internal var forwardedPartnerToChassis: Bool

	internal var myPartition: Int = 0
	internal var partitionPartners: [Int: NodeState] = .init()

	private func getParitionForNode(_ node: Int) -> Int {
		node / 8
	}

	private func isPartitionPartner(_ node: Int) -> Bool {
		return (self.nodeRank % 8) == (node % 8)
	}

	var configuration: RouterConfiguration {
		self._configuration
	}

	var nodeRank: Int {
		self.configuration.node.rank
	}

	var allInnerChassisDiscovered: Bool {
		let inChassisDiscoveredNodes = self.ensembleNodes.values.filter {
			$0.inChassis && $0.rxEstablished && $0.txEstablished
		}

		return inChassisDiscoveredNodes.count == 4
	}

	var partnerNodeDiscovered: Bool {
		guard let partnerNode else {
			return false
		}

		guard let partnerInfo = self.ensembleNodes[partnerNode] else {
			return false
		}

		return partnerInfo.rxEstablished && partnerInfo.txEstablished
	}

	let nodePerPartition = 8

	required init(configuration: RouterConfiguration) throws {
		self._configuration = configuration
		self.ensembleFailed = false
		self.expectedRxConnections = 7
		self.expectedTxConnections = 7
		self.transferMap = .init()
		#if false
		self.routeMap = .init()
		#endif
		self.cioMap = .init()
		self.ensembleNodes = .init()
		self.partnerNode = nil
		self.forwardedPartnerToChassis = false
		let partitionCount = configuration.ensemble.nodes.count / self.nodePerPartition
		self.expectedNetworkConnections = partitionCount - 1

		// we use this router config for ensemble size 8,16,32
		guard configuration.ensemble.nodes.count == 8 ||
			configuration.ensemble.nodes.count == 16 ||
			configuration.ensemble.nodes.count == 32
		else {
			throw """
			Invalid number of nodes in ensemble configuration: \(
				configuration.ensemble.nodes
					.count
			). Expected node count in multiple of 8."
			"""
		}
		self.myPartition = self.nodeRank / 8

		logger.info("""
		    Router8Hypercube: totalParitions:\(partitionCount, privacy: .public), 
		    myPartition:\(self.myPartition, privacy: .public),
		    expectedRxConnections:\(self.expectedRxConnections, privacy: .public),
		    expectedTxConnections:\(self.expectedTxConnections, privacy: .public),
		    expectedNetworkConnections:\(self.expectedNetworkConnections, privacy: .public)
		""")

		self.transferMap[self.nodeRank] = .init(
			outputChannels: [],
			inputChannel: nil
		)

		for node in configuration.ensemble.nodes.values {
			if self.getParitionForNode(node.rank) == self.myPartition {
				self.ensembleNodes[node.rank] = .init(
					node: node.rank,
					inChassis: node.chassisID == configuration.node.chassisID,
					txEstablished: node.rank == self.nodeRank,
					rxEstablished: node.rank == self.nodeRank,
					inPartition: true
				)
			} else {
				if self.isPartitionPartner(node.rank) {
					self.partitionPartners[node.rank] = .init(
						node: node.rank,
						inChassis: false,
						txEstablished: false,
						rxEstablished: false,
						inPartition: false
					)

					guard let hostName = node.hostName else {
						logger.error("No hostname for partner node: \(node.rank, privacy: .public)")
						self.configuration.delegate.ensembleFailed(failMsg: "No hostname for partner node: \(node.rank)")
						return
					}

					self.configuration.delegate.addPeer(hostName: hostName, nodeRank: node.rank)
				}
			}
		}
	}

	func channelChange(
		channelIndex: Int,
		node: Int,
		chassis: String,
		connected: Bool
	) {
		logger
			.info(
				"channelChange(channelIndex: \(channelIndex, privacy: .public), node: \(node, privacy: .public), chassis: \(chassis, privacy: .public), connected: \(connected, privacy: .public))"
			)
		if !connected {
			if let _ = cioMap[channelIndex] {
				self.cioMap.removeValue(forKey: channelIndex)
				self.ensembleFailed = true
				self.configuration.delegate.ensembleFailed(failMsg: "channelChange: channelIndex=\(channelIndex), node=\(node), chassis=\(chassis) dis-connected")
			}
			return
		}

		// All CIO channels are used in a hypercube
		// The node should be in the ensemble config, if it isn't, disable
		// the channel as a precaution and the ensemble has failed
		let ensembleNode = self.configuration.ensemble.nodes.values.first(where: {
			$0.rank == node
		})

		if ensembleNode == nil {
			do {
				try disableChannel(channelIndex)
			} catch {
				logger.error("Failed to disable channel: \(error, privacy: .public)")
			}
			self.ensembleFailed = true
            self.configuration.delegate.ensembleFailed(failMsg: "Failed to disable channel")
			return
		}

		// And to the cio map
		self.cioMap[channelIndex] = node

		guard let nodeInfo = self.ensembleNodes[node] else {
			logger.error("Channel change on unknown node: \(node, privacy: .public)")
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
				cioChannelIndex: channelIndex
			)
		} catch {
			logger.error("Failed to establish connection to node: \(node, privacy: .public)")
			self.ensembleFailed = true

			self.configuration.delegate.ensembleFailed(failMsg: "Failed to establish connection to node: \(node)")
			return
		}
	}

	public func isPartitionEnsembleReady() -> Bool {
		!self.ensembleFailed &&
			self.expectedRxConnections == 0 &&
			self.expectedTxConnections == 0
	}

	func isEnsembleReady() -> Bool {
		!self.ensembleFailed &&
			self.expectedRxConnections == 0 &&
			self.expectedTxConnections == 0 &&
			self.expectedNetworkConnections == 0
	}

	func connectionChange(
		direction: BackendConnectionDirection,
		channelIndex: Int,
		node: Int,
		connected: Bool
	) {
		logger
			.info(
				"connectionChange(direction: \(direction, privacy: .public), channelIndex: \(channelIndex, privacy: .public), node: \(node, privacy: .public), connected: \(connected, privacy: .public))"
			)
		if !connected {
			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed(failMsg: "connectionChange: channelIndex:\(channelIndex), node:\(node) disconnected")
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
				logger.error("No CIO receiver for CIO\(channelIndex, privacy: .public)")

				self.ensembleFailed = true
				self.configuration.delegate.ensembleFailed(failMsg: "No CIO receiver for CIO\(channelIndex)")
				return
			}

			if node != self.nodeRank {
				do {
					try sendForwardMessage(source: node, receiver: receiver)
				} catch {
					logger.error("Failed to send forward message: \(error, privacy: .public)")

					self.ensembleFailed = true
                    self.configuration.delegate.ensembleFailed(failMsg: "Failed to send forward message: \(error)")
					return
				}
			} else {
				self.ensembleNodes[receiver]?.txEstablished = true
				#if false
				self.routeMap[receiver] = "\(self.nodeRank)->\(receiver)"
				#endif
			}
		}

		logger.info("""
		    connectionChange:
		    expectedRxConnections:\(self.expectedRxConnections),
		    expectedTxConnections:\(self.expectedTxConnections),
		    expectedNetworkConnections:\(self.expectedNetworkConnections)
		""")

		if self.isEnsembleReady() {
			logger.info("We have the ensemble activated!.")
			self.configuration.delegate.ensembleReady()
			return
		}

		if self.isPartitionEnsembleReady() {
			logger
				.info(
					"We have the partition ensemble activated, waiting for peer network connection to happen before marking the ensemble activated."
				)
			return
		}

		// Did not discover all inner chassis nodes or the partner node fully
		if !self.allInnerChassisDiscovered || !self.partnerNodeDiscovered || self
			.forwardedPartnerToChassis {
			return
		}

		self.forwardedPartnerToChassis = true

		// Inner chassis and partner node discovered, forward the partner
		// node to all the inner chassis nodes
		let innerChassisNodes = self.ensembleNodes.values
			.filter { $0.inChassis && $0.node != self.nodeRank }
		guard let partnerNode = self.partnerNode else {
			fatalError("""
			Partner node not set when trying to make TX connections. This is a
			logic error
			""")
		}

		for innerChassisNode in innerChassisNodes {
			let nodeCIOChannel = self.transferMap[innerChassisNode.node]?.inputChannel
			guard let nodeCIOChannel else {
				fatalError("""
				Attempting to make TX connections for partner node to
				in-chassis nodes, before a input channel has been established for
				node \(innerChassisNode.node). This is a logic error.
				""")
			}

			do {
				try self.configuration.backend.establishTXConnection(
					node: partnerNode,
					cioChannelIndex: nodeCIOChannel
				)
			} catch {
				logger.warning("""
				Failed to forward \(partnerNode)'s data to
				\(innerChassisNode.node, privacy: .public) on CIO\(nodeCIOChannel, privacy: .public)
				""")
				self.ensembleFailed = true

				self.configuration.delegate.ensembleFailed(failMsg: "Failed to forward \(partnerNode)'s data to \(innerChassisNode.node) on CIO\(nodeCIOChannel)")
				return
			}
		}
	}

	func forwardMessage(_ forward: EnsembleControlMessage.Forward) {
		#if false
		guard let routeToForwarder = routeMap[forward.forwarder] else {
			logger.warning("""
			Got a forwarding message: Forwarder:\(forward.forwarder)
			receiver:\(forward.receiver) before a route has been established
			to forwarder.
			""")

			self.ensembleFailed = true
			self.configuration.delegate.ensembleFailed()
			return
		}

		self.routeMap[forward.receiver] = routeToForwarder + "->\(forward.receiver)"
		#endif
		self.ensembleNodes[forward.receiver]?.txEstablished = true
	}

	func networkConnectionChange(
		node: Int,
		connected: Bool
	) {
		logger.info("networkConnectionChange: from node \(node, privacy: .public), connected status is \(connected, privacy: .public)")
		guard self.partitionPartners.keys.contains(where: { $0 == node }) else {
			logger.error("Network Connection to an unexpected node: \(node, privacy: .public). I am node \(self.nodeRank, privacy: .public).")
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

	func getCIOTransferMap() -> [Int: CIOTransferState] {
		self.transferMap
	}

	func getRoutes() -> [Int: String] {
		#if false
		self.routeMap
		#else
		return [:]
		#endif
	}
}

extension Router8Hypercube {
	internal func sendForwardMessage(source: Int, receiver: Int) throws {
		let forwardMessage: EnsembleControlMessage =
			.ForwardMessage(.init(forwarder: nodeRank, receiver: receiver))

		let forwardMessageData = try JSONEncoder().encode(forwardMessage)

		try self.configuration.backend.sendControlMessage(node: source, message: forwardMessageData)
	}
}
