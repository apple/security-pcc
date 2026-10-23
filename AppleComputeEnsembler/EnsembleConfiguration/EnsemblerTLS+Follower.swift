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
//  EnsemblerTLS+Follower.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 12/27/24.
//

import Foundation
@_spi(Daemon) import AppleComputeEnsembler // Helper functions

// follower methods to send message to leader
extension EnsemblerTLS {
	// follower first checks-in with leader by sending .followerAnnounceNode message.
	// current state: .coordinating
	// message sent: .followerAnnounceNode
	// This is the first message that follower sends to leader
	internal func sendAnnounceToLeader() {
		var msg: Data
		do {
			let slot = self.slots[self.currentNodeConfig.rank]
			msg = try JSONEncoder().encode(EnsembleControlMessage.followerAnnounceNode(slot: slot))
		} catch {
			EnsemblerTLS.logger.error(
				"Failed to encode followerAnnounceNode, ensemble can not be assembled"
			)
            self.ensembleFailed(failMsg: "Failed to encode followerAnnounceNode, ensemble can not be assembled")
			return
		}

		self.sendMessageToLeader(message: msg)
	}

	internal func sendMessageToLeader(message: Data) {
		do {
			EnsemblerTLS.logger.info(
				"EnsemblerTLS.sendMessageToLeader(): sending \(message, privacy: .public) to leader"
			)

			try self.tlsChannel?.sendControlMessage(node: 0, message: message)
		} catch {
			EnsemblerTLS.logger.warning(
				"""
				EnsemblerTLS.sendMessageToLeader(): \
				Failed to send \(message, privacy: .public), will retry: \
				\(String(reportableError: error), privacy: .public) (\(error, privacy: .public))
				"""
			)
		}
	}

	// follower acknowledges to leader that it got the shared cio key by sending .followerKeyAccepted
	// This is in response to .ensembleAcceptAndshareCIOKey
	// current state: .keyaccepted
	// message sent: .followerKeyAccepted
	internal func sendKeyAcceptedToLeader() {
		var msg: Data
		do {
			msg = try JSONEncoder().encode(EnsembleControlMessage.followerKeyAccepted)
		} catch {
			EnsemblerTLS.logger.error(
				"Failed to encode followerKeyAccepted message, ensemble can not be assembled"
			)
            self.ensembleFailed(failMsg: "Failed to encode followerKeyAccepted message, ensemble can not be assembled")
			return
		}

		self.sendMessageToLeader(message: msg)
	}

	// follower acknowledges to leader that it got the data  key by sending .followerDataKeyObtained
	// This is in response to .ensembleShareDataKey
	// current state: .ready
	// message sent: .followerDataKeyObtained
	internal func sendDataKeyObtainedToLeader() {
		var msg: Data
		do {
			msg = try JSONEncoder().encode(EnsembleControlMessage.followerDataKeyObtained)
		} catch {
			EnsemblerTLS.logger.error(
				"Failed to encode followerDataKeyObtained message, ensemble can not be assembled"
			)
            self.ensembleFailed(failMsg: "Failed to encode followerDataKeyObtained message, ensemble can not be assembled")
			return
		}

		self.sendMessageToLeader(message: msg)
	}

	// follower acknowledges to leader that it activited its CIOMesh by sending
	// .followerActivationComplete.
	// This is in response to .activationComplete
	// current state: .activated
	// message sent: .followerActivationComplete
	internal func sendfollowerActivationCompleteToLeader() {
		var msg: Data
		do {
			msg = try JSONEncoder().encode(EnsembleControlMessage.followerActivationComplete)
		} catch {
			EnsemblerTLS.logger.error(
				"Failed to encode followerActivationComplete message, ensemble can not be assembled"
			)
            self.ensembleFailed(failMsg: "Failed to encode followerActivationComplete message, ensemble can not be assembled")
			return
		}

		self.sendMessageToLeader(message: msg)
	}

	// follower tells leader that it is ready
	// This is in response to .ensembleReady
	// current state: .ready
	// message sent: .followerNodeReady
	internal func sendNodeReadyToLeader() {
		var msg: Data
		do {
			msg = try JSONEncoder().encode(EnsembleControlMessage.followerNodeReady)
		} catch {
			EnsemblerTLS.logger.error(
				"Failed to encode followerNodeReady message, ensemble can not be assembled"
			)
			self.ensembleFailed(failMsg: "Failed to encode followerNodeReady message, ensemble can not be assembled")
			return
		}

		self.sendMessageToLeader(message: msg)
	}
}
