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
//  ControlMessage.swift
//  ensembleconfig
//
//  Created by Sumit Kamath on 11/17/23.
//

// we need to weaklink since we wanted to run xctest on skywagon which might not contain the
// symbols.
@_weakLinked import CloudAttestation
import CryptoKit
import Foundation
import AppleComputeEnsembler

enum EnsembleControlMessage: Codable, CustomStringConvertible {
	case ensembleFailed /// Something went wrong. Tell everyone
	case ensembleDraining /// Node is draining. Tell everyone
	case testMessage /// Just say hi to a node

	case ForwardMessage(Forward)
	case rotateKey /// Leader sends message to followers to initiate pairing process to get the
	/// shared key

	// Control messages applicable to transport over mTLS only
	case followerAnnounceNode(slot: Slot) /// Check in with the leader
	case ensembleAcceptAndshareCIOKey(sharedKey: Data) // leader shares the shared key to all followers
	// via mtls
	case followerKeyAccepted // follower acknowledges it got the shared key
	case ensembleCIOKeyShared /// All nodes now have the shared key and the key set in CIOMesh, so
	/// data can be encrypted and decrypted.
	case followerActivationComplete // follower acknowledges it activated the backend successfully
	case ensembleActivationComplete // leader knows that all followers got the key, and activated
	// successfully. Followers will receive this message and go to ready
	case followerNodeReady // follower node is ready, and now waiting for leader to signal followers
	// about
	// ensemble ready state
	case ensembleReady // leader knows all followers are ready
	case acknowledge // message to acknowledge that a server got the message
	case ensembleShareDataKey(key: Data, singleUseToken: UUID)
	case followerDataKeyObtained
    /// Leader → Follower: carries the request payload and an advisory timeout for the follower's app callback.
    case dataMessageRequest(appID: String, data: Data, requestID: UUID, callbackTimeout: TimeInterval)
    /// Follower → Leader: carries the app callback's response payload.
    case dataMessageResponse(appID: String, data: Data, requestID: UUID)
    /// Follower → Leader: signals a typed error (no registered handler, app callback timeout, etc.).
    case dataMessageError(error: DataMessageError, requestID: UUID)

	// EnsembleControlMessage.description does not expose any private data.
	var description: String {
		switch self {
		case .ForwardMessage(let forward): return ".ForwardMessage(\(forward))"
		case .ensembleFailed: return ".ensembleFailed"
		case .ensembleDraining: return ".ensembleDraining"
		case .testMessage: return ".testMessage"
		case .rotateKey: return ".rotateKey"
		case .ensembleAcceptAndshareCIOKey: return ".ensembleAcceptAndshareCIOKey"
		case .followerKeyAccepted: return ".followerKeyAccepted"
		case .followerActivationComplete: return ".followerActivationComplete"
		case .ensembleActivationComplete: return ".ensembleActivationComplete"
		case .followerNodeReady: return ".followerNodeReady"
		case .ensembleReady: return ".ensembleReady"
		case .followerAnnounceNode: return ".followerAnnounceNode"
		case .ensembleCIOKeyShared: return ".ensembleCIOKeyShared"
		case .acknowledge: return ".acknowledge"
		case .ensembleShareDataKey: return "ensembleShareDataKey"
		case .followerDataKeyObtained: return "followerDataKeyObtained"
        case .dataMessageRequest: return "dataMessageRequest"
        case .dataMessageResponse: return "dataMessageResponse"
        case .dataMessageError: return "dataMessageError"
		}
	}

    // Darwin Foundation's JSONDecoder throws an ObjC NSException (not a Swift Error) when the
    // root JSON value is not a dictionary (e.g. a bare string or number). Swift `catch` blocks
    // don't intercept ObjC exceptions, so we pre-validate the root type via JSONSerialization —
    // which returns a typed Swift Error for non-dict roots — before handing off to JSONDecoder.
    static func decode(from data: Data) throws -> EnsembleControlMessage {
        guard !data.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Empty data")
            )
        }
        let root = try JSONSerialization.jsonObject(with: data)
        guard root is [String: Any] else {
            let hexPrefix = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Root JSON value is not a dictionary — cannot decode as EnsembleControlMessage. First \(min(32, data.count)) bytes: [\(hexPrefix)]"
                )
            )
        }
        return try JSONDecoder().decode(EnsembleControlMessage.self, from: data)
    }

	// EnsembleControlMessage.OuterNode.description does not expose any private data.
	struct OuterNode: Codable, CustomStringConvertible {
		internal let nodeID: Int
		internal let chassisID: String

		var description: String {
			return "OuterNode(nodeID: \(self.nodeID), chassisID: \(self.chassisID))"
		}
	}

	// EnsembleControlMessage.Forward.description does not expose any private data.
	struct Forward: Codable, CustomStringConvertible {
		internal let forwarder: Int
		internal let receiver: Int

		var description: String {
			return "Forward(forwarder: \(self.forwarder), receiver: \(self.receiver))"
		}
	}
}
