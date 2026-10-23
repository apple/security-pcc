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
#endif
import Foundation

public final class CIOBackend: Backend {

	let configuration: BackendConfiguration
	let meshService: AppleCIOMeshConfigServiceRef

	public init(configuration: BackendConfiguration) throws {
		self.configuration = configuration

		if #_hasSymbol(AppleCIOMeshConfigServiceRef.self) {

			let meshServices = AppleCIOMeshConfigServiceRef.all()
			guard let meshServices = meshServices,
			      let meshService = meshServices.first
			else {
				throw "Unable to find mesh config service"
			}

			self.meshService = meshService
			meshService.setDispatchQueue(configuration.queue)

			meshService.setExtendedNodeId(UInt32(configuration.node.rank))
			meshService.setChassisId(configuration.node.chassisID)
			print("setting ensemble size to \(configuration.ensemble.nodeCount)")
			meshService.setEnsembleSize(UInt32(configuration.ensemble.nodeCount))

			meshService.onMeshChannelChange { channel, node, chassis, connected in
				guard let chassis = chassis else {
					print("No chassis ID. Closing connection")
					meshService.disconnectCIOChannel(channel)
					return
				}
				self.configuration.delegate.channelChange(
					node: Int(node),
					chassis: chassis,
					channelIndex: Int(channel),
					connected: connected)
			}

			meshService.onNodeConnectionChange { direction, channel, node, connected in
				let backendDirection: BackendConnectionDirection = direction == TX ? .tx : .rx
				self.configuration.delegate.connectionChange(
					direction: backendDirection,
					node: Int(node),
					channelIndex: Int(channel),
					connected: connected)
			}

			meshService.onNodeNetworkConnectionChange { node, connected in
				self.configuration.delegate.networkConnectionChange(node: Int(node), connected: connected)
			}

			meshService.onNodeMessage { node, message in
				guard let message = message else {
					print("Received a nil message from node\(node)")
					return
				}
				self.configuration.delegate.incomingMessage(node: Int(node), message: message)
			}
		} else {
			throw "AppleCIOMeshConfigSupport not available"
		}
	}

	public func activate() throws {
		guard self.meshService.activateCIO() else {
			throw "Unable to activate mesh"
		}
	}

	public func deactivate() throws {
		guard self.meshService.deactivateCIO() else {
			throw "Unable to deactivate mesh"
		}
	}

	public func disconnectCIO(channel: Int) throws {
		guard self.meshService.disconnectCIOChannel(UInt32(channel)) else {
			throw "Unable to disconnect CIO"
		}
	}

	public func sendControlMessage(node: Int, message: Data) throws {
		guard self.meshService.sendControlMessage(message, toNode: UInt32(node)) else {
			throw "Unable to send message to node\(node)"
		}
	}

	public func establishTXConnection(node: Int, cioChannelIndex: Int) throws {
		guard self.meshService.establishTXConnection(UInt32(node), onChannel: UInt32(cioChannelIndex)) else {
			throw "Unable to make a TX connection"
		}
	}

	public func lock() throws {
		guard self.meshService.lockCIO() else {
			throw "Unable to lock CIO mesh"
		}
	}

	public func getConnectedNodes() throws -> [[String: AnyObject]] {
		let nodes = self.meshService.getConnectedNodes()

		guard let nodes = nodes else {
			throw "Unable to get connected nodes"
		}

		var newNodes: [[String: AnyObject]] = .init()
		for n in nodes {
			guard let n = n as? [String: AnyObject] else {
				throw "Connected node invalid"
			}
			newNodes.append(n)
		}
		return newNodes
	}

	public func getCIOCableState() throws -> [[String: AnyObject]] {
		let cables = self.meshService.getCIOCableState()

		guard let cables = cables else {
			throw "Unable to get CIO cable state"
		}

		var cioCables: [[String: AnyObject]] = .init()
		for c in cables {
			guard let c = c as? [String: AnyObject] else {
				throw "CIO state invalid"
			}
			cioCables.append(c)
		}
		return cioCables
	}

	public func getBuffersUsed() throws -> Int {
		Int(self.meshService.getBuffersUsedForCryptoKey())
	}

	public func canActivate(nodeCount: Int) throws -> Bool {
		Bool(self.meshService.canActivate(UInt32(nodeCount)))
	}

	public func addHostname(hostname: String, node: Int) throws -> Bool {
		self.meshService.addPeerHostname(hostname, peerNodeId: UInt32(node))
	}

	public func getEnsembleSize() throws -> UInt32 {
		var EnsembleSize: UInt32 = 0
		guard self.meshService.getEnsembleSize(&EnsembleSize) else {
			throw "Failed to get Ensemble size"
		}

		return EnsembleSize
	}
}
