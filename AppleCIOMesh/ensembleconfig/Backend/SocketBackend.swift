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
//  SocketBackend.swift
//  ensembleconfig
//
//  Created by Sumit Kamath on 11/17/23.
//

import Foundation

public class CIOSocketConnection {
	let channel: Int
	let node: NodeConfiguration

	var incoming: Server?
	var outgoing: Client?

	var outgoingConnected = false
	var processedConnected = false
	var holdingConnected: String?
	var holdingConnection: String?

	let provider: SocketBackend

	var delegate: BackendDelegate {
		self.provider.configuration.delegate
	}

	var queue: DispatchQueue {
		self.provider.configuration.queue
	}

	init(
		provider: SocketBackend,
		queue: DispatchQueue,
		node: NodeConfiguration,
		channel: Int,
		partnerNode: NodeConfiguration) throws {
		self.channel = channel
		self.node = node
		self.provider = provider

		guard let debugSocketConnectivity = node.debugSocketConnectivity else {
			throw "Debug socket connectivity not specified"
		}

		var incomingPort = 0
		switch channel {
		case 0:
			incomingPort = debugSocketConnectivity.cio0Port
		case 1:
			incomingPort = debugSocketConnectivity.cio1Port
		case 2:
			incomingPort = debugSocketConnectivity.cio2Port
		case 3:
			incomingPort = debugSocketConnectivity.cio3Port
		default:
			throw "Invalid CIO channel when setting up CIO Socket: \(channel)"
		}

		let outgoingPort = try partnerNode.getDebugPortForPartner(partnerRank: node.rank)

		self.incoming = .init(
			queue: queue,
			port: UInt16(incomingPort),
			dataIn: self.dataIn)
		self.outgoing = .init(
			queue: queue,
			host: partnerNode.debugSocketConnectivity?.ip ?? "localhost",
			port: outgoingPort,
			connectionIn: self.outgoingConnectionEstablished)

		try self.incoming?.start()
	}

	func close() {
		self.incoming?.stop()
		self.outgoing?.stop()
	}

	func outgoingPlugConnected() {
		self.outgoingConnected = true
	}

	func waitForOtherNode(deadline: TimeInterval) throws {
		guard let outgoing = self.outgoing else {
			throw "Oops, self.outgoing is nil. Has .init() been called?"
		}
		let serverReady = outgoing.waitForServer(deadline: deadline)
		if !serverReady {
			throw "Unable to establish connection to \(outgoing.host):\(outgoing.port)"
		}
	}

	func inititePlugToOtherNode() {
		self.outgoing?.start()
	}

	func sendOutgoing(data: Data) {
		self.outgoing?.send(data: data)
	}

	func makeDataConnection(node: Int) {
		self.sendOutgoing(data: "connection#\(node)#\(true)#\(node == self.node.rank ? "Direct" : "Forward")\t".data(using: .utf8)!)
	}

	func processConnectionMessage() {
		if let holdingConnection = holdingConnection,
		   processedConnected {
			if !self.provider.booted {
				fatalError("""
					A connection on CIOSocket\(self.channel) cannot be made
					when we aren't booted. \(holdingConnection)
					""")
			}

			let tmp = holdingConnection.components(separatedBy: "#")
			// connection#node#<status>#<DirectOrForward>
			let connected: Bool = .init(tmp[2])!
			let connectedNode = Int(tmp[1])!
			let isForwardConnection = tmp[3] == "Forward"

			if connected {
				self.provider.addConnection(node: connectedNode, cioChannelIndex: self.channel)
			} else {
				self.provider.removeConnection(node: connectedNode, cioChannelIndex: self.channel)
			}

			if !isForwardConnection {
				self.delegate.connectionChange(
					direction: .tx,
					node: self.node.rank,
					channelIndex: self.channel,
					connected: connected)
			}
			self.delegate.connectionChange(
				direction: .rx,
				node: connectedNode,
				channelIndex: self.channel,
				connected: connected)

			self.holdingConnection = nil
		}
	}

	func outgoingConnectionEstablished() {
		self.outgoingPlugConnected()
		self.sendOutgoing(data: "connected#\(self.node.rank)#\(self.node.chassisID)\t".data(using: .utf8)!)

		if let holdingConnected = holdingConnected {
			self.queue.schedule {
				let tmp = holdingConnected.components(separatedBy: "#")
				self.delegate.channelChange(
					node: Int(tmp[1])!,
					chassis: tmp[2],
					channelIndex: self.channel,
					connected: true)
				self.holdingConnected = nil
				self.processedConnected = true
				self.processConnectionMessage()
			}
		}
	}

	func dataIn(data: Data) {
		if !self.outgoingConnected, self.provider.booted {
			self.inititePlugToOtherNode()
		}

		let dataString = String(data: data, encoding: .utf8)!
		let datas = dataString.components(separatedBy: "\t")

		for data in datas {
			if data.isEmpty {
				continue
			}
			//			print("\t\t\t\t\t\t-> dataIn: CIOSocket\(self.channel): \(data)")
			if data.hasPrefix("connected#") {
				// data format: connected#nodeID#chassisID

				// we need to hold connected if we are not booted
				if !self.provider.booted {
					self.holdingConnected = data
					return
				}

				if !self.outgoingConnected {
					self.holdingConnected = data
					return
				}

				let tmp = data.components(separatedBy: "#")
				self.delegate.channelChange(
					node: Int(tmp[1])!,
					chassis: tmp[2],
					channelIndex: self.channel,
					connected: true)
				self.processedConnected = true
				self.processConnectionMessage()
			} else if data.hasPrefix("connection#") {
				if self.holdingConnected != nil {
					self.holdingConnection = data
					return
				}

				if !self.processedConnected {
					self.holdingConnection = data
					return
				}

				self.holdingConnection = data
				self.processConnectionMessage()
			} else if data.hasPrefix("message#") {
				// data format: message#sourceNode#destinationNode#data
				if !self.provider.booted {
					fatalError("""
						A message on CIOSocket\(self.channel) cannot come
						when we aren't booted. \(data)
						""")
				}

				let tmp = data.components(separatedBy: "#")
				let messageDest = Int(tmp[2])!
				let messageSrc = Int(tmp[1])!

				if messageDest == self.node.rank {
					self.delegate.incomingMessage(node: messageSrc, message: tmp[3].data(using: .utf8)!)
				} else {
					try! self.provider.forwardControlMessage(
						node: messageDest,
						source: messageSrc,
						message: tmp[3].data(using: .utf8)!)
				}
			}
		}
	}
}

public final class SocketBackend: Backend {
	public func addHostname(hostname: String, node: Int) throws -> Bool {
		true
	}

	var cio: [CIOSocketConnection?]
	let configuration: BackendConfiguration
	var booted: Bool = false
	var activated: Bool = false

	var nodeConnections: [Int: Int]

	func addConnection(node: Int, cioChannelIndex: Int) {
		self.nodeConnections[node] = cioChannelIndex
	}

	func removeConnection(node: Int, cioChannelIndex _: Int) {
		self.nodeConnections.removeValue(forKey: node)
	}

	func setBooted(booted: Bool) {
		self.booted = booted
	}

	public init(configuration: BackendConfiguration) throws {
		self.cio = .init(repeating: nil, count: 4)
		self.configuration = configuration
		self.nodeConnections = .init()

		guard let nodeConnectivity = configuration.node.debugNodeConnectivity else {
			throw "Node connectivity not specified"
		}

		for i in 0...3 {
			var partnerNode: NodeConfiguration?
			switch i {
			case 0:
				partnerNode = configuration.ensemble.nodes.first(where: {
					$0.rank == nodeConnectivity.cio0Connection
				})
			case 1:
				partnerNode = configuration.ensemble.nodes.first(where: {
					$0.rank == nodeConnectivity.cio1Connection
				})
			case 2:
				partnerNode = configuration.ensemble.nodes.first(where: {
					$0.rank == nodeConnectivity.cio2Connection
				})
			case 3:
				partnerNode = configuration.ensemble.nodes.first(where: {
					$0.rank == nodeConnectivity.cio3Connection
				})
			default:
				throw "Invalid cio number when setting up socket backend: \(i)"
			}

			guard let partnerNode = partnerNode else {
				continue
			}

			self.cio[i] = try .init(
				provider: self,
				queue: configuration.queue,
				node: configuration.node,
				channel: i,
				partnerNode: partnerNode)
		}
	}

	public func waitForNeighbors(deadline: TimeInterval) throws {
		for cio in self.cio {
			guard let cio = cio else {
				continue
			}
			try cio.waitForOtherNode(deadline: deadline)
		}
	}

	public func activate() throws {
		if !self.activated {
			self.activated = true
			for cio in self.cio {
				guard let cio = cio else {
					continue
				}
				cio.inititePlugToOtherNode()
			}
		}
	}

	public func deactivate() throws {
		if self.activated {
			self.activated = false
			for cio in self.cio {
				guard let cio = cio else {
					continue
				}
				cio.close()
			}
		}
	}

	public func disconnectCIO(channel: Int) throws {
		guard let cio = cio[channel] else {
			throw "Disconnect CIO[\(channel)] when no partner is on this channel"
		}
		cio.close()
	}

	public func sendControlMessage(node: Int, message: Data) throws {
		let cioChannel = self.nodeConnections[node]
		guard let cioChannel = cioChannel else {
			throw "Connection not established to \(node)"
		}

		let msg = String(data: message, encoding: .utf8)!
		let tmp = "message#\(configuration.node.rank)#\(node)#\(msg)\t"

		self.cio[cioChannel]?.sendOutgoing(data: tmp.data(using: .utf8)!)
	}

	public func establishTXConnection(node: Int, cioChannelIndex: Int) throws {
		let cioChannel = self.cio[cioChannelIndex]
		guard let cioChannel = cioChannel else {
			throw "CIO[\(cioChannelIndex)] not available"
		}

		// We only need to send the connection message on the correct CIO socket
		// Rely on the router knowing who the receiver on the cio channel is.
		cioChannel.makeDataConnection(node: node)

		// For forwards, we need to send back a fake TX connection change, so we
		// can let the caller know a TX connection has been made. On Real CIO,
		// this will be doen by the driver
		if node != self.configuration.node.rank {
			self.configuration.delegate.connectionChange(
				direction: .tx,
				node: node,
				channelIndex: cioChannelIndex,
				connected: true)
		}
	}

	public func lock() throws {
		print("Lock not implemented for Socket backend")
	}

	func forwardControlMessage(node: Int, source: Int, message: Data) throws {
		let cioChannel = self.nodeConnections[node]
		guard let cioChannel = cioChannel else {
			throw "Connection not established to \(node)"
		}

		let msg = String(data: message, encoding: .utf8)!
		let tmp = "message#\(source)#\(node)#\(msg)\t"

		self.cio[cioChannel]?.sendOutgoing(data: tmp.data(using: .utf8)!)
	}

	public func getConnectedNodes() throws -> [[String: AnyObject]] {
		print("getConnectedNodes not implemented for Socket backend")
		return []
	}

	public func getCIOCableState() throws -> [[String: AnyObject]] {
		print("getCIOCableState not implemented for Socket backend")
		return []
	}

	public func getBuffersUsed() throws -> Int {
		throw "Not implemented on Socket"
	}

	public func canActivate(nodeCount: Int) throws -> Bool {
		throw "Not implemented on Socket"
	}

	public func getEnsembleSize() throws -> UInt32 {
		throw "Not implemented on Socket"
	}
}
