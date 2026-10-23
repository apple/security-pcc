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
//  Backend.swift
//  ensembleconfig
//
//  Created by Sumit Kamath on 11/17/23.
//

import Foundation

/// Known record of all backends
public enum BackendType: String, CustomStringConvertible, Decodable {
	case None
	case CIOBackend
	case CIOFusionBackend
	case StubBackend

	public var description: String {
		switch self {
		case .None:
			return "None"
		case .CIOBackend:
			return "CIOBackend"
		case .CIOFusionBackend:
			return "CIOFusionBackend"
		case .StubBackend:
			return "StubBackend"
		}
	}
}

enum BackendConnectionDirection: CustomStringConvertible {
	case tx
	case rx

	public var description: String {
		switch self {
		case .tx: return ".tx"
		case .rx: return ".rx"
		}
	}
}

protocol BackendDelegate {
	/// A channel is available/unavailable from the backend.
	func channelChange(node: Int, chassis: String, channelIndex: Int, connected: Bool)

	/// A connection has been established/disconnected to a node over the channel.
	func connectionChange(
		direction: BackendConnectionDirection,
		node: Int,
		channelIndex: Int,
		connected: Bool
	)

	/// An incoming message from a node.
	func incomingMessage(node: Int, message: Data)

	/// A network connection has been established/discnonected to a node.
	func networkConnectionChange(node: Int, connected: Bool)
}

struct BackendConfiguration {
	/// The dispatch queue to send backend callbacks on.
	let queue: DispatchQueue

	/// The current node.
	let node: NodeConfiguration

	/// The ensemble configuration for the backend. This is only needed in
	/// the CIO Socket simulation backend.
	let ensemble: EnsembleConfiguration

	/// The delegate all backend callbacks will be sent to.
	let delegate: BackendDelegate?

	init(
		queue: DispatchQueue,
		node: NodeConfiguration,
		ensemble: EnsembleConfiguration,
		delegate: BackendDelegate?
	) {
		self.queue = queue
		self.node = node
		self.ensemble = ensemble
		self.delegate = delegate
	}
}

/// Common interface implemented by every backend.
protocol Backend {
	/// Protocol initializer
	init(configuration: BackendConfiguration) throws

	/// Activates the backend.
	func activate() throws

	/// Deactivates the backend.
	func deactivate() throws

	/// Set a flag within the backend to indicate that the backend has been activated (e.g., after
	/// restarting the mesh).
	func setActivatedFlag()

	/// Is the ensemble locked?
	func isLocked() -> Bool

	/// Locks the backend if applicable. Backends that lock implicitly on activation implement this
	/// as a no-op.
	func lock() throws

	/// Set the crypto key.
	func setCryptoKey(key: Data, flags: UInt32) throws
}

/// Extended interface for the CIO Fusion backend.
/// Conformed to by CIOFusionBackend.
protocol CIOFusionBackendProtocol: Backend {
	// CIOFusion-specific operations — to be defined as the backend matures.
}

/// Extended interface for backends that use the CIO physical mesh.
/// Conformed to by CIOBackend and StubBackend.
protocol CIOBackendProtocol: Backend {
	/// Disconnects a single CIO channel.
	func disconnectCIO(channel: Int) throws

	/// Sends a control message to a node in the mesh.
	func sendControlMessage(node: Int, message: Data) throws

	/// Makes a TX connection to a node.
	func establishTXConnection(node: Int, cioChannelIndex: Int) throws

	/// Returns a list of all connected nodes by rank.
	func getConnectedNodes() throws -> [[String: AnyObject]]

	/// Returns a dictionary of the ACIO connectivity state.
	func getCIOCableState() throws -> [[String: AnyObject]]

	/// Get the crypto key. Only for use on the test path.
	func getCryptoKey() throws -> Data

	/// Gets the number of buffers that can be allocated per crypto key.
	func getMaxBuffersPerKey() throws -> UInt64

	/// Gets the number of seconds that can be used for a crypto key.
	func getMaxSecondsPerKey() throws -> UInt64

	/// Add peer hostnames.
	func addPeerHostname(hostname: String, node: Int) throws -> Bool
}
