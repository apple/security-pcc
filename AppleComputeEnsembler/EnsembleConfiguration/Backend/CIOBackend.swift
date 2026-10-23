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
//  CIOBackend.swift
//  ensembleconfig
//
//  Created by Sumit Kamath on 11/17/23.
//

#if canImport(AppleCIOMeshConfigSupport)
@_weakLinked import AppleCIOMeshConfigSupport
import Foundation
import OSLog

fileprivate let logger = Logger(subsystem: kEnsemblerPrefix, category: "CIOBackend")

final class CIOBackend: CIOBackendProtocol {
	let configuration: BackendConfiguration
	let meshService: AppleCIOMeshConfigServiceRef
	let _activatedLockQueue = DispatchQueue(label: "activated.lock.queue")
	var _activated = false

	var activated: Bool {
		get {
			self._activatedLockQueue.sync {
				return self._activated
			}
		}
		set {
			self._activatedLockQueue.sync {
				self._activated = newValue
			}
		}
	}

	init(configuration: BackendConfiguration) throws {
		self.configuration = configuration

		if #_hasSymbol(AppleCIOMeshConfigServiceRef.self) {
			let meshServices = AppleCIOMeshConfigServiceRef.all()
			guard let meshServices,
			      let meshService = meshServices.first
			else {
				throw "Unable to find mesh config service"
			}

			self.meshService = meshService
			meshService.setDispatchQueue(configuration.queue)

			var ok = false
			if #available(iOS 18.4, macOS 15.4, *) {
				ok = meshService.setExtendedNodeId(UInt32(configuration.node.rank))
			} else {
				ok = meshService.setNodeId(UInt32(configuration.node.rank))
			}

			if !ok {
				throw EnsembleError.internalError(
					error:
					"""
					Oops: meshService.setNodeId(rank: \(UInt32(configuration.node.rank)) failed.
					"""
				)
			}
			ok = meshService.setChassisId(configuration.node.chassisID)
			if !ok {
				throw EnsembleError.internalError(
					error:
					"""
					Oops: meshService.setChassisId(rank: \(configuration.node.chassisID) failed.
					"""
				)
			}

			meshService.onMeshChannelChange { channel, node, chassis, connected in
				guard let chassis else {
					logger.warning("No chassis ID. Closing connection")
					meshService.disconnectCIOChannel(channel)
					return
				}
				self.configuration.delegate?.channelChange(
					node: Int(node),
					chassis: chassis,
					channelIndex: Int(channel),
					connected: connected
				)
			}

			meshService.onNodeConnectionChange { direction, channel, node, connected in
				let backendDirection: BackendConnectionDirection = direction == TX ? .tx : .rx
				self.configuration.delegate?.connectionChange(
					direction: backendDirection,
					node: Int(node),
					channelIndex: Int(channel),
					connected: connected
				)
			}

			meshService.onNodeNetworkConnectionChange { node, connected in
				self.configuration.delegate?.networkConnectionChange(node: Int(node), connected: connected)
			}

			meshService.onNodeMessage { node, message in
				guard let message else {
					logger.warning("Received a nil message from node\(node, privacy: .public)")
					return
				}
				self.configuration.delegate?.incomingMessage(node: Int(node), message: message)
			}
		} else {
			throw "AppleCIOMeshConfigSupport not available"
		}
	}

	func activate() throws {
		logger.info("CIOBackend.activate(): Call into CIO backend to activate the node.")
		guard self.meshService.activateCIO() else {
			logger.error(
				"""
				CIOBackend.activate(): Oops: meshService.activateCIO() failed. That's all we know.
				"""
			)
			throw "Unable to activate mesh"
		}
		self.activated = true
		logger.info("CIOBackend.activate(): meshService.activateCIO() returned OK")
	}

	func deactivate() throws {
		self.activated = false
		logger.info("CIOBackend.deactivate(): Call into CIO backend to deactivate the node.")
		guard self.meshService.deactivateCIO() else {
			logger.error(
				"""
				CIOBackend.activate(): Oops: meshService.deactivateCIO() failed. That's all we know.
				"""
			)
			throw "Unable to deactivate mesh"
		}
		logger.info("CIOBackend.deactivate(): meshService.deactivateCIO() returned OK")
	}

	func setActivatedFlag() {
		self.activated = true
	}

	func disconnectCIO(channel: Int) throws {
		logger.info("CIOBackend.disconnectCIO(): Call into CIO backend to disconnect CIO.")
		guard self.meshService.disconnectCIOChannel(UInt32(channel)) else {
			logger.error(
				"""
				CIOBackend.disconnectCIO(): Oops: meshService.disconnectCIOChannel() failed. \
				That's all we know.
				"""
			)
			throw "Unable to disconnect CIO"
		}
		logger.info("CIOBackend.disconnectCIO(): meshService.disconnectCIOChannel() returned OK")
	}

	func sendControlMessage(node: Int, message: Data) throws {
		if !self.activated {
			logger.warning(
				"""
				Mesh not activated: \
				Ignoring request to send a control message to node \(node, privacy: .public): \(message)
				"""
			)
			return
		}
		logger.info(
			"""
			CIOBackend.sendControlMessage(node: \(node, privacy: .public), message: %s): \
			Call into the CIO backend's sendControlMessage() function.
			"""
		)
		guard self.meshService.sendControlMessage(message, toNode: UInt32(node)) else {
			logger.error(
				"""
				CIOBackend.sendControlMessage(): Oops: mesService.sendControlMessage() failed. \
				That's all we know.
				"""
			)
			throw "Unable to send message to node\(node)"
		}
		logger.info("CIOBackend.sendControlMessage(): meshService.sendControlMessage() returned OK.")
	}

	func establishTXConnection(node: Int, cioChannelIndex: Int) throws {
		logger.info(
			"""
			CIOBackend.establishTXConnection(): \
			Call into CIO backend to establish a TX connection to: \
			node: \(node, privacy: .public) \
			cioChannelIndex: \(cioChannelIndex, privacy: .public)
			"""
		)
		guard self.meshService.establishTXConnection(
			UInt32(node),
			onChannel: UInt32(cioChannelIndex)
		) else {
			logger.error(
				"""
				CIOBackend.establishTXConnection(): Oops: mesService.establishTXConnection() \
				failed. That's all we know.
				"""
			)
			throw "Unable to make a TX connection"
		}
		logger.info(
			"CIOBackend.establishTXConnection(): meshService.establishTXConnection() returned OK."
		)
	}

	func lock() throws {
		logger.info("CIOBackend.lock(): Call into CIO backend to lock the mesh.")
		guard self.meshService.lockCIO() else {
			logger.error(
				"CIOBackend.lock(): Oops: mesService.lockCIO() failed. That's all we know."
			)
			throw "Unable to lock CIO mesh"
		}
		logger.info("CIOBackend.lock(): meshService.lockCIO() returned OK.")
	}

	/// Check if CIO is locked
	func isLocked() -> Bool {
		return self.meshService.isCIOLocked()
	}

	public func getConnectedNodes() throws -> [[String: AnyObject]] {
		let nodes = self.meshService.getConnectedNodes()

		guard let nodes else {
			throw "Unable to get connected nodes"
		}

		var newNodes: [[String: AnyObject]] = .init()
		for node in nodes {
			guard let node = node as? [String: AnyObject] else {
				throw "Connected node invalid"
			}
			newNodes.append(node)
		}
		return newNodes
	}

	public func getCIOCableState() throws -> [[String: AnyObject]] {
		let cables = self.meshService.getCIOCableState()

		guard let cables else {
			throw "Unable to get CIO cable state"
		}

		var cioCables: [[String: AnyObject]] = .init()
		for cable in cables {
			guard let cable = cable as? [String: AnyObject] else {
				throw "CIO state invalid"
			}
			cioCables.append(cable)
		}
		return cioCables
	}

	/// set the crypto key
	func setCryptoKey(key: Data, flags: UInt32) throws {
		if self.meshService.setCryptoKey(key, andFlags: flags) == false {
			throw "Error setting crypto key in CIO Mesh"
		}
	}

	/// get the crypto key
	/// This API should not be called in real code path, and can be only used on test path
	func getCryptoKey() throws -> Data {
		var flags: UInt32 = 0
		guard let keyData = self.meshService.getCryptoKey(forSize: 128, andFlags: &flags) else {
			throw "Could not get crypto key from CIO Mesh"
		}

		return keyData
	}

	/// gets the number of buffers that can be allocated per Crypto Key.
	func getMaxBuffersPerKey() throws -> UInt64 {
		return self.meshService.getMaxBuffersPerCryptoKey()
	}

	/// gets the number of seconds that can be used for a crypto key
	func getMaxSecondsPerKey() throws -> UInt64 {
		return self.meshService.getMaxSecondsPerCryptoKey()
	}

	public func addPeerHostname(hostname: String, node: Int) throws -> Bool {
		logger.info(
			"""
			CIOBackend.addPeerHostname(hostname: \(hostname, privacy: .public), node: \(node): \
			Call into the CIO backend's addPeerHostname() function. 
			"""
		)

		return self.meshService.addPeerHostname(hostname, peerNodeId: UInt32(node))
	}
}
#endif
