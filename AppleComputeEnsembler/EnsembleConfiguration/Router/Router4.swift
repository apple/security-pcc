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
//  Router4.swift
//  ensembleconfig
//
//  Created by Sumit Kamath on 11/17/23.
//

import OSLog

private let logger = Logger(subsystem: kEnsemblerPrefix, category: "Router4")

final class Router4: Router {
	internal var _configuration: RouterConfiguration
	internal var ensembleFailed: Bool
	internal var expectedTxConnections: Int
	internal var expectedRxConnections: Int
	internal var transferMap: [Int: CIOTransferState]
	internal var routeMap: [Int: String]
	internal var cioMap: [Int: Int]

	var configuration: RouterConfiguration {
		self._configuration
	}

	var nodeRank: Int {
		self.configuration.node.rank
	}

	required init(configuration: RouterConfiguration) throws {
		self._configuration = configuration
		self.ensembleFailed = false
		self.expectedRxConnections = 3
		self.expectedTxConnections = 3
		self.transferMap = .init()
		self.routeMap = .init()
		self.cioMap = .init()

		guard configuration.ensemble.nodes.count == 4 else {
			throw """
			Invalid number of nodes in ensemble configuration: \(
				configuration.ensemble.nodes
					.count
			). Expected 4."
			"""
		}

		self.transferMap[self.nodeRank] = .init(
			outputChannels: [],
			inputChannel: nil
		)
	}

	func channelChange(
		channelIndex: Int,
		node: Int,
		chassis: String,
		connected: Bool
	) {
		if !connected {
			if let _ = cioMap[channelIndex] {
				self.cioMap.removeValue(forKey: channelIndex)
				self.ensembleFailed = true
				self.configuration.delegate.ensembleFailed(failMsg: "channelChange: channelIndex=\(channelIndex), node=\(node), chassis=\(chassis) not connected")
			}
			return
		}

		// Disable any CIO channels to non-chassis nodes.
		if chassis != self.configuration.node.chassisID {
			logger
				.log(
					"disabling channel because '\(chassis)' != '\(self.configuration.node.chassisID)'"
				)
			do {
				try disableChannel(channelIndex)
			} catch {
				logger.error("Failed to disable channel: \(error, privacy: .public)")
			}
			return
		}

		// Add the node to the transfer map
		self.transferMap[node] = .init(
			outputChannels: [],
			inputChannel: nil
		)
		// And to the cio map
		self.cioMap[channelIndex] = node

		// make a connection to in-chassis nodes
		do {
			try self.configuration.backend.establishTXConnection(
				node: self.nodeRank,
				cioChannelIndex: channelIndex
			)
		} catch {
            logger.error("Failed to establish connection to node: \(node, privacy: .public)")
			self.ensembleFailed = true

			self.configuration.delegate.ensembleFailed(failMsg: "Failed to establish connection to node: \(node)")
		}
	}

	func isEnsembleReady() -> Bool {
		!self.ensembleFailed &&
			self.expectedRxConnections == 0 &&
			self.expectedTxConnections == 0
	}

	func connectionChange(
		direction: BackendConnectionDirection,
		channelIndex: Int,
		node: Int,
		connected: Bool
	) {
		if !connected {
			self.ensembleFailed = true
            self.configuration.delegate.ensembleFailed(failMsg: "connectionChange: channelIndex:\(channelIndex), node:\(node) disconnected")
			return
		}

		guard self.transferMap[node] != nil else {
			fatalError("""
			Connection change to a node before it has been added to the
			transfer map.
			""")
		}

		if direction == .rx {
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
			self.routeMap[receiver] = "\(self.nodeRank)->\(receiver)"
		}

		if self.isEnsembleReady() {
			self.configuration.delegate.ensembleReady()
			return
		}
	}

	public func networkConnectionChange(
		node _: Int,
		connected _: Bool
	) {
		logger.error("Network Connection change is not supported on router4")
	}

	func forwardMessage(_: EnsembleControlMessage.Forward) {
		logger.warning("Router4 should not be receiving any forwarding messages")
		self.ensembleFailed = true
		self.configuration.delegate.ensembleFailed(failMsg: "Router4 should not be receiving any forwarding messages")
	}

	func getCIOTransferMap() -> [Int: CIOTransferState] {
		self.transferMap
	}

	func getRoutes() -> [Int: String] {
		self.routeMap
	}
}
