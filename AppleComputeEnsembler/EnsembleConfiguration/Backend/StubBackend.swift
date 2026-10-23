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
//  StubBackend.swift
//  EnsembleConfiguration
//
//  Created by Alex T Newman on 12/14/23.
//

import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: kEnsemblerPrefix, category: "StubBackend")

final class StubBackend: CIOBackendProtocol {
	let configuration: BackendConfiguration
	// Start Small
	var activated: Bool
	// Wow really advanced lock
	var locked: Bool

	var sharedKey: SymmetricKey? = nil

	init(configuration: BackendConfiguration) throws {
		self.configuration = configuration
		self.activated = false
		self.locked = false
	}

	func activate() {
		logger.log("Activating StubBackend")
		self.configuration.queue.sync {
			logger.info("StubBackend activation currently: \(self.activated, privacy: .public)")
			if self.activated {
				logger.warning("StubBackend already activated")
			}
			self.activated = true
			logger.log("StubBackend activated")
		}
	}

	func deactivate() {
		logger.log("Deactivating StubBackend")
		self.configuration.queue.sync {
			logger.info("StubBackend activation currently: \(self.activated, privacy: .public)")
			if !self.activated {
				logger.warning("StubBackend already deactivated")
			}
			self.activated = false
			logger.log("StubBackend deactivated")
		}
	}

	func setActivatedFlag() {
		self.activated = true
	}

	func disconnectCIO(channel: Int) {
		logger.log("Disconnecting CIO channel: \(channel, privacy: .public)")
	}

	func sendControlMessage(node: Int, message: Data) throws {
		logger
			.log(
				"Sending control message \(String(describing: message), privacy: .public) to node: \(node, privacy: .public)"
			)
	}

	func establishTXConnection(node: Int, cioChannelIndex: Int) {
		logger
			.log(
				"Establishing tx connection to node: \(node, privacy: .public) on channel: \(cioChannelIndex, privacy: .public)"
			)
	}

	func lock() throws {
		logger.log("Locking CIO")
		self.configuration.queue.sync {
			if self.locked {
				logger.warning("CIO was already locked")
			}
			self.locked = true
			logger.log("CIO locked")
		}
	}

	func isLocked() -> Bool {
		self.configuration.queue.sync {
			return self.locked
		}
	}

	public func getConnectedNodes() throws -> [[String: AnyObject]] {
		logger.log("getConnectedNodes not implemented for Stub backend")
		return []
	}

	public func getCIOCableState() throws -> [[String: AnyObject]] {
		logger.log("getCIOCableState not implemented for Stub backend")
		return []
	}

	func setCryptoKey(key: Data, flags _: UInt32) throws {
		logger.log("Setting crypto key ")
		self.sharedKey = SymmetricKey(data: key)

        logger
            .log(
			"setCryptoKey: Key is: \(key.map { String(format: "%02x", $0) }.joined())"
		)
	}

	/// get the crypto key
	func getCryptoKey() throws -> Data {
		logger.log("Getting crypto key ")

		guard let key = sharedKey else {
			throw EnsembleError.internalError(error: "Shared key was not initialized")
		}

		let keyData = key.withUnsafeBytes { Data(Array($0)) }
        logger
            .log(
			"getCryptoKey: Key is: \(keyData.map { String(format: "%02x", $0) }.joined())"
		)

		return key.withUnsafeBytes { Data(Array($0)) }
	}

	/// gets the number of buffers that can be allocated per Crypto Key.
	func getMaxBuffersPerKey() throws -> UInt64 {
		logger.log("getting the max buffers per key")
		return 1000
	}

	/// gets the number of seconds that can be used for a crypto key
	func getMaxSecondsPerKey() throws -> UInt64 {
		logger.log("getting the max seconds per key ")
		return 1000
	}

	public func addPeerHostname(hostname: String, node: Int) throws -> Bool {
		logger
			.log(
				"addHostname \(String(describing: hostname), privacy: .public) for node: \(node, privacy: .public)"
			)
		return true
	}
}
