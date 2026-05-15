// Copyright © 2025 Apple Inc. All Rights Reserved.

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
//  EnsembleTLS+Leader.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 12/27/24.
//

import Foundation

@_spi(Daemon) import AppleComputeEnsembler // Helper functions

// Leader handlers
extension EnsemblerTLS {
	internal func broadcastMessage(msg: EnsembleControlMessage) throws {
		// EnsembleControlMessage.description does not expose any private data.
		EnsemblerTLS.logger.info("EnsemblerTLS.broadcastMessage(): \(msg, privacy: .public)")
		let msgData: Data
		do {
			msgData = try JSONEncoder().encode(msg)
		} catch {
			EnsemblerTLS.logger.error(
				"""
				Failed to encode message \(String(describing: msg), privacy: .public) for \
				broadcast: \(error, privacy: .public)
				"""
			)
			throw error
		}

		DispatchQueue.global(qos: .userInteractive).async {
            
            // if called from follower, we should just send the message to leader.
            // follower node does not have connection to all other followers, so it will just fail and show up as noise
            if self.isLeader == false {
                do {
                    EnsemblerTLS.logger.info("EnsemblerTLS.broadcastMessage(): Sending \(msg, privacy: .public) message to leader")
                    try self.tlsChannel?.sendControlMessage(node: 0, message: msgData)
                } catch {
                    EnsemblerTLS.logger.warning(
                        """
                        Failed to send ensemble control message \
                        \(msg, privacy: .public) to leader
                        """
                    )
                }
            }
            else {
                EnsemblerTLS.logger.info("EnsemblerTLS.broadcastMessage(): Sending \(msg, privacy: .public) message to all followers")
                // No need to tell ourselves
                for node in self.ensembleConfig.nodes where node.key != self.UDID {
                    do {
                        EnsemblerTLS.logger.info("Sending \(msg) message to \(node.value.rank)")
                        try self.tlsChannel?.sendControlMessage(node: node.value.rank, message: msgData)
                    } catch {
                        EnsemblerTLS.logger.warning(
                              """
                              Failed to send ensemble control message \
                              \(msg, privacy: .public) to rank: \(node.value.rank) \
                              (UDID: \(node.key, privacy: .public))
                              """
                        )
                    }
                }
            }
		}
	}

	func checkAllNodeRanksNotFound() -> [Int] {
		var ranksNotFound: [Int] = []
		for node in self.nodeMap.values {
			if node.found != true {
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.checkAllNodesFoundStatus(): \
					node \(node.rank, privacy: .public) NOT yet found: \
					returning `false`
					"""
				)

				ranksNotFound.append(node.rank)
			}
		}
		return ranksNotFound
	}

	// check if all nodes have checked in their presence
	func checkAllNodesFoundStatus() -> Bool {
		for node in self.nodeMap.values {
			if node.found != true {
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.checkAllNodesFoundStatus(): \
					node \(node.rank, privacy: .public) NOT yet found: \
					returning `false`
					"""
				)
				return false
			}
		}
		EnsemblerTLS.logger.info(
			"EnsemblerTLS.checkAllNodesFoundStatus(): found all nodes: returning `true`"
		)
		return true
	}

	// reset status of key distribution status
	internal func resetEnsembleKeyDistributionStatus() {
		for node in self.nodeMap.values {
			self.nodeMap[node.UDID]?.keyShared = false
		}
		EnsemblerTLS.logger.info("Done resetting `keyShared` to `false` for all nodeMap entries.")
	}

	// reset status of data key distribution status
	internal func resetEnsembleDataKeyDistributionStatus() {
		for node in self.nodeMap.values {
			self.nodeMap[node.UDID]?.dataKeyShared = false
		}
		EnsemblerTLS.logger.info("Done resetting `dataKeyShared` to `false` for all nodeMap entries.")
	}

	// reset status of node found status
	internal func resetEnsembleNodeFoundStatus() {
		for node in self.nodeMap.values {
			self.nodeMap[node.UDID]?.found = false
		}
		EnsemblerTLS.logger.info("Done resetting `found` to `false` for all nodeMap entries.")
	}

	// reset status of node ready status
	internal func resetNodeReadyStatus() {
		for node in self.nodeMap.values {
			self.nodeMap[node.UDID]?.nodeReady = false
		}
		EnsemblerTLS.logger.info("Done resetting `nodeReady` to `false` for all nodeMap entries.")
	}

	// check nodes that did not acknowledge getting CIOkey
	func checkNodesNotDistributionCIOKey() -> [Int] {
		var nodesNotDistributedCIOKey: [Int] = []

		for node in self.nodeMap.values {
			// skip checking for leader, since leader has the sharedkey already.
			if node.rank == 0 {
				continue
			}
			if node.keyShared != true {
				nodesNotDistributedCIOKey.append(node.rank)
			}
		}

		return nodesNotDistributedCIOKey
	}

	// check if the CIO key is shared among all nodes.
	func checkEnsembleForKeyDistribution() -> Bool {
		for node in self.nodeMap.values {
			// skip checking for leader, since leader has the sharedkey already.
			if node.rank == 0 {
				continue
			}
			if node.keyShared != true {
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.checkEnsembleForKeyDistribution(): \
					node \(node.rank, privacy: .public): keyShared is `false`: \
					returning `false`
					"""
				)
				return false
			}
		}
		EnsemblerTLS.logger.info(
			"""
			EnsemblerTLS.checkEnsembleForKeyDistribution(): \
			keyShared is `true` for all nodes: returning `true`
			"""
		)
		return true
	}

	// check if the data key is shared among all nodes.
	func checkEnsembleForDataKeyDistribution() -> Bool {
		for node in self.nodeMap.values {
			// skip checking for leader, since leader has the sharedkey already.
			if node.rank == 0 {
				continue
			}
			if node.dataKeyShared != true {
				EnsemblerTLS.logger.debug(
					"""
					EnsemblerTLS.checkEnsembleForDataKeyDistribution(): \
					node \(node.rank, privacy: .public): dataKeyShared is `false`: \
					returning `false`
					"""
				)
				return false
			}
		}
		EnsemblerTLS.logger.info(
			"""
			EnsemblerTLS.checkEnsembleForDataKeyDistribution(): \
			            dataKeyShared is `true` for all nodes: returning `true`
			"""
		)
		return true
	}

	// check if all nodes are ready to go to ready state.
	func checkEnsembleForEnsembleReady() -> Bool {
		for node in self.nodeMap.values {
			// skip checking for leader, since leader has the sharedkey already.
			if node.rank == 0 {
				continue
			}
			if node.nodeReady != true {
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.checkEnsembleForEnsembleReady(): \
					node \(node.rank, privacy: .public): nodeReady is `false`: \
					returning `false`
					"""
				)
				return false
			}
		}
		EnsemblerTLS.logger.info(
			"""
			EnsemblerTLS.checkEnsembleForEnsembleReady(): \
			nodeReady is `true` for all nodes: returning `true`
			"""
		)
		return true
	}

	// check if all nodes have activiated their cio mesh
	func checkNodesNotActivated() -> [Int] {
		var nodesNotActivated: [Int] = []
		for node in self.nodeMap.values {
			if node.rank == 0 {
				continue
			}

			if node.activated != true {
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.checkEnsembleForActivationCompletion(): \
					node \(node.rank, privacy: .public): activated is `false`: \
					returning `false`
					"""
				)
				nodesNotActivated.append(node.rank)
			}
		}

		return nodesNotActivated
	}

	// check if all nodes have activiated their cio mesh
	func checkEnsembleForActivationCompletion() -> Bool {
		for node in self.nodeMap.values {
			if node.rank == 0 {
				continue
			}

			if node.activated != true {
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.checkEnsembleForActivationCompletion(): \
					node \(node.rank, privacy: .public): activated is `false`: \
					returning `false`
					"""
				)
				return false
			}
		}

		EnsemblerTLS.logger.info(
			"""
			EnsemblerTLS.checkEnsembleForActivationCompletion(): \
			activated is `true` for all nodes: returning `true`
			"""
		)

		return true
	}

	// handle the activation acknowledgement from followers
	// message handled: .activationComplete
	// description: follower node acknowledges that it activated its cio mesh, and ready for next action.
	internal func handleActivationComplete(udid: String) throws {
		EnsemblerTLS.logger.info("EnsemblerTLS.handleActivationComplete(udid: \(udid))")

		guard self.status != .ready, self.nodeMap[udid]?.activated != true else {
			EnsemblerTLS.logger.warning(
				"EnsemblerTLS.handleActivationComplete(): Handling extraneous message from \(udid)"
			)
			return
		}

		guard let destination = self.nodeMap[udid]?.rank else {
            EnsemblerTLS.logger.error("EnsemblerTLS.handleActivationComplete(): Cannot find rank for node \(udid, privacy: .public) ")
			ensembleFailed(failMsg: "EnsemblerTLS.handleActivationComplete(): Cannot find rank for node \(udid)")
			return
		}

		self.nodeMap[udid]?.activated = true

		if self.checkEnsembleForActivationCompletion() == true {
			self.setStatus(.activated)

			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.handleActivationComplete() on rank \(self.currentNodeConfig.rank): \
				All followers were acknowledged they activated their mesh.
				"""
			)

			do {
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.handleActivationComplete(): \
					Send .ensembleActivationComplete message to \
					rank \(destination, privacy: .public) (UDID: \(udid)).
					"""
				)
				// we dont need to broadcast repeatedly here, since the follower yammers at leader
				// with acknolwledgeActivation till they get ensembleActivationComplete from leader.
				try self.broadcastMessage(msg: EnsembleControlMessage.ensembleActivationComplete)
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.handleActivationComplete(): \
					Successfully sent .ensembleActivationComplete message to \
					rank \(destination, privacy: .public) (UDID: \(udid)).
					"""
				)
			} catch {
				EnsemblerTLS.logger.error(
					"""
					EnsemblerTLS.handleActivationComplete(): \
					Failed to broadcast ensembleActivationComplete status: \
					\(String(reportableError: error), privacy: .public) 
					"""
				)
				ensembleFailed(failMsg: "EnsemblerTLS.handleActivationComplete(): Failed to broadcast ensembleActivationComplete, error = \(error)")
			}
		}
	}

	// handle the data key acknowledgement from followers
	// message handled: .followerDataKeyObtained
	// description: follower node acknowledges that it got the shared data key
	internal func handleDataKeyObtained(udid: String) throws {
		EnsemblerTLS.logger.info("EnsemblerTLS.handleDataKeyObtained(udid: \(udid))")

		guard self.nodeMap[udid]?.dataKeyShared != true else {
			EnsemblerTLS.logger.warning(
				"Ensembler.handleDataKeyObtained(): Handling extraneous message from \(udid)"
			)
			return
		}

		guard let destination = self.nodeMap[udid]?.rank,
		      destination != 0 else {
			EnsemblerTLS.logger.error("Ensembler.handleDataKeyObtained(): Cannot find rank for node \(udid, privacy: .public), or rank is 0. ")
            ensembleFailed(failMsg: "Ensembler.handleDataKeyObtained(): Cannot find rank for node \(udid)")
			return
		}

		self.nodeMap[udid]?.dataKeyShared = true

		if self.checkEnsembleForDataKeyDistribution() == true {
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.handleDataKeyObtained() on rank \(self.currentNodeConfig.rank): \
				All followers were distributed the data key and followers acknowledged they got the key.
				"""
			)
			self.dataKeyDistributedDisapatchGroup.leave()
		}
	}

	// handle the key acknowledgement from followers
	// message handled: .keyAccepted
	// description: follower node acknowledges that it got the shared CIO key
	internal func handleKeyAccepted(udid: String) throws {
		EnsemblerTLS.logger.info("EnsemblerTLS.handleKeyAccepted(udid: \(udid))")

		guard self.status != .ready, self.nodeMap[udid]?.keyShared != true else {
			EnsemblerTLS.logger.warning(
				"Ensembler.handleKeyAccepted(): Handling extraneous message from \(udid)"
			)
			return
		}

		guard let destination = self.nodeMap[udid]?.rank,
		      destination != 0 else {
			EnsemblerTLS.logger.error("Ensembler.handleKeyAccepted(): Cannot find rank for node \(udid, privacy: .public), or rank is 0. ")
			ensembleFailed(failMsg: "Ensembler.handleKeyAccepted(): Cannot find rank for node \(udid)")
			return
		}

		self.nodeMap[udid]?.keyShared = true

		if self.checkEnsembleForKeyDistribution() == true {
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.handleKeyAccepted() on rank \(self.currentNodeConfig.rank): \
				All followers were distributed key and followers acknowledged they got the key.
				"""
			)

			self.setStatus(.distributedCIOKey)
			do {
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.handleKeyAccepted(): \
					broadcast .ensembleCIOKeyShared message to all nodes.
					"""
				)
				// we dont need to broadcast repeatedly here, since the follower yammers at leader
				// with acknolwedgeCIOKey till they get ensembleCIOKeyShared from leader.
				try self.broadcastMessage(msg: EnsembleControlMessage.ensembleCIOKeyShared)
				EnsemblerTLS.logger.info(
					"""
					EnsemblerTLS.handleKeyAccepted(): \
					Successfully broadcasted .ensembleCIOKeyShared message to all nodes
					"""
				)
			} catch {
				EnsemblerTLS.logger.error(
					"""
					EnsemblerTLS.handleKeyAccepted(): \
					Failed to broadcast ensembleCIOKeyShared status: \
					\(String(reportableError: error), privacy: .public)
					"""
				)
				ensembleFailed(failMsg: "EnsemblerTLS.handleKeyAccepted() Failed to broadcast ensembleCIOKeyShared, error = \(error)")
			}

			// Now that we know the key is present in all nodes, we can set it in CIOMesh/Backend
			EnsemblerTLS.logger.info("EnsemblerTLS.handleKeyAccepted(): Call setCryptoKey().")
			self.setCryptoKey()
			EnsemblerTLS.logger.info("EnsemblerTLS.handleKeyAccepted(): setCryptoKey() returned.")

			// if we just rotated the key, we know that we already activated the backend during initial
			// bootstrapping.
			// so we can move to ready state, since we already know the key was shared among all nodes.
			if self.checkEnsembleForActivationCompletion() == true {
				EnsemblerTLS.logger
					.info(
						"EnsemblerTLS.handleKeyAccepted(): In key rotation. Waiting to get nodeReady signal from followers"
					)

			} else if self.autoRestart {
				EnsemblerTLS.logger.error(
					"""
					The ensemble has already been activated. Attempting to auto-restart it. \
					This should never happen in production!
					"""
				)
				self.backend?.setActivatedFlag()
			} else {
				// Now activate the CIOMesh/Backend
				EnsemblerTLS.logger
					.info("EnsemblerTLS.handleKeyAccepted(): Initial bootstrapping. Call activate().")
				try self.activateMesh()
			}
		}
	}

	// handle the .nodeReady from followers
	// message handled: .acknolwledgeCIOKey
	// description: follower node tells the leader that it did all the steps to go into ready state, just waiting for message from leader to go to ready
	// state
	internal func handleNodeReady(udid: String) throws {
		guard self.status != .ready, self.nodeMap[udid]?.nodeReady != true else {
			EnsemblerTLS.logger.warning(
				"Ensembler.handleNodeReady(): Handling extraneous message from \(udid, privacy: .public)"
			)
			return
		}

		EnsemblerTLS.logger.info("EnsemblerTLS.handleNodeReady(udid: \(udid))")

		guard let destination = self.nodeMap[udid]?.rank,
		      destination != 0 else {
			EnsemblerTLS.logger.error("Ensembler.handleNodeReady: Cannot find rank for node \(udid, privacy: .public), or rank is 0. ")
			ensembleFailed(failMsg: "Ensembler.handleNodeReady: Cannot find rank for node \(udid)")
			return
		}

		self.nodeMap[udid]?.nodeReady = true

		if self.checkEnsembleForEnsembleReady() == true {
			EnsemblerTLS.logger.info(
				"""
				EnsemblerTLS.handleNodeReady() on rank \(self.currentNodeConfig.rank): \
				All followers ready and they acknowledged..
				"""
			)

			goToReady()
		}
	}

	func checkFollowerConnectionsNotReady() -> [Int] {
		var followerConnectionsNotReady: [Int] = []

		for follower in 1 ..< self.nodeMap.count {
			if self.clientConnections[follower] != .ready {
				followerConnectionsNotReady.append(follower)
			}
		}

		return followerConnectionsNotReady
	}

	func resetFollowerConnectionStatus() {
		for node in 1 ..< self.nodeMap.count {
			self.clientConnections[node] = .none
		}
	}

	func resetLeaderConnectionStatus() {
		self.clientConnections[0] = .none
	}

	func isAllFollowerConnectionsReady() -> Bool {
		EnsemblerTLS.logger.info(
			"EnsemblerTLS.isAllFollowerConnectionsReady(): Waiting for all follower connections to become ready."
		)

		for follower in 1 ..< self.nodeMap.count {
			if self.clientConnections[follower] != .ready {
				EnsemblerTLS.logger.info(
					"EnsemblerTLS.isAllFollowerConnectionsReady(): Node \(follower) connection state is \(self.clientConnections[follower].debugDescription) and is not .ready ."
				)
				return false
			}
		}

		return true
	}

	func waitForAllFollowerConnectionsReady() -> Bool {
		if self.isAllFollowerConnectionsReady() == true {
			EnsemblerTLS.logger
				.info(
					"All follower connections is ready. Leader dont need to wait, and can now start handshaking."
				)
			return true
		}

		let dispatchGroup = DispatchGroup()
		dispatchGroup.enter()

		DispatchQueue.global().async {
			repeat {
				// Simulate a small delay before rechecking
				Thread.sleep(forTimeInterval: 1)
			} while self.isAllFollowerConnectionsReady() == false

			dispatchGroup.leave()
		}

		let waitResult = dispatchGroup.wait(timeout: .now() + .seconds(kEnsemblerTimeout))

		if waitResult == .success {
			EnsemblerTLS.logger.info("All follower connections is ready. Leader can now start handshaking.")
			return true
		} else {
			EnsemblerTLS.logger
				.error(
					"Timeout of \(kEnsemblerTimeout) expired. Atleast one of the follower connection is not ready."
				)
			return false
		}
	}

	// Leader handles .followerAnnounceNode message from followers.
	internal func handleAnnounceNode(udid: String) {
		guard self.status != .ready, self.nodeMap[udid]?.found != true else {
			EnsemblerTLS.logger.warning(
				"Ensembler.handleNewNode(): Handling extraneous message from \(udid)"
			)
			return
		}
    
		guard let destination = self.nodeMap[udid]?.rank else {
			EnsemblerTLS.logger
				.error(
					"EnsemblerTLS.handleAnnounceNode() on rank \(self.currentNodeConfig.rank, privacy: .public): Cannot find rank for node \(udid)"
				)
			return
		}

		EnsemblerTLS.logger.info(
			"EnsemblerTLS.handleAnnounceNode() on rank \(self.currentNodeConfig.rank): from destination \(destination, privacy: .public) (UDID: \(udid))"
		)

		self.nodeMap[udid]?.found = true
		// If all followers have checked in, let's tell everyone, and initiate the
		// flow to distribute the shared key.
		// we have to make sure clientConnections to all servers i.e for leader all followers
		// for followers leader is reachable
		if self.checkAllNodesFoundStatus() == true {
			self.everyoneFound = true
			// we have not started client to followers earlier, because we dont know if we followers would
			// have started before
			// leader, so rather than continuosly poll connecting to each follower, we will wait for all
			// followers to check in with leader
			// Now that we know all followers have checked in, we can create client connection to all
			// followers, and start sending messages.
			self.tlsChannel?.startClientsToFollowers()

			EnsemblerTLS.logger.info(
				"EnsemblerTLS.handleAnnounceNode() on rank \(self.currentNodeConfig.rank): All nodes checked in, waiting for client connections to all followers to be become ready"
			)

			// wait for all follower connections to come to ready state, before we
			// start broadcasting messages.
			if self.waitForAllFollowerConnectionsReady() == false {
				EnsemblerTLS.logger.info(
					"EnsemblerTLS.handleAnnounceNode() on rank \(self.currentNodeConfig.rank): Could not create client connection to all followers"
				)
				ensembleFailed(failMsg: "EnsemblerTLS.handleAnnounceNode(): Leader could not create client connection to all followers after waiting for \(kEnsemblerTimeout).")
			}

			EnsemblerTLS.logger.info(
				"EnsemblerTLS.handleAnnounceNode() on rank \(self.currentNodeConfig.rank): All followers checked in and found reachable. Proceeding to distribute CIOMesh key"
			)

			self.dumpEnsembleDebugMap()

			if !self.setStatus(.distributingCIOKey) {
				return
			}

			self.distributeKey()
		}
	}

	// called only on leader node
	internal func distributeKey() {
		do {
			EnsemblerTLS.logger.info(
				"EnsemblerTLS.distributeKey(): broadcast .ensembleAcceptAndshareCIOKey message"
			)

			guard let keyData = sharedKey?.getKeyDataWrapper().data else {
				EnsemblerTLS.logger.error(
					"""
					Oops: distributeKey() error getting keydata.
					"""
				)
				throw InitializationError.unexpectedBehavior(
					"""
					Oops: distributeKey() error getting keydata.
					"""
				)
			}

			try self.broadcastMessage(
				msg: EnsembleControlMessage.ensembleAcceptAndshareCIOKey(sharedKey: keyData)
			)

			EnsemblerTLS.logger.info(
				"EnsemblerTLS.distributeKey(): successfully broadcasted .ensembleAcceptAndshareCIOKey message"
			)

		} catch {
			// This is technically harmless as only our status matters
			EnsemblerTLS.logger.warning(
				"""
				EnsemblerTLS.distributeKey(): Failed to broadcast ensembleAcceptAndshareCIOKey message: \
				\(String(reportableError: error), privacy: .public) 
				"""
			)
		}
	}

	internal func distributeDataKey(singleUseKeyToken: SingleUseKeyToken, key: Data) {
		do {
			EnsemblerTLS.logger.info(
				"EnsemblerTLS.distributeDataKey(): broadcast .ensembleShareDataKey message"
			)

			try self.broadcastMessage(
				msg: EnsembleControlMessage.ensembleShareDataKey(key: key, singleUseToken: singleUseKeyToken)
			)

			EnsemblerTLS.logger.info(
				"EnsemblerTLS.distributeDataKey(): successfully broadcasted .ensembleShareDataKey message"
			)

		} catch {
			// This is technically harmless as only our status matters
			EnsemblerTLS.logger.warning(
				"""
				EnsemblerTLS.distributeKey(): Failed to broadcast ensembleShareDataKey status: \
				\(String(reportableError: error), privacy: .public)
				"""
			)
		}
	}
}
