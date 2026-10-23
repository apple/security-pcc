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
//  Ensemble.swift
//  Ensemble
//
//  Created by Alex T Newman on 12/21/23.
//

import CryptoKit
import Foundation
import Network
import OSLog
import Security
import XPC
@_weakLinked private import CloudAttestation

@_implementationOnly import MobileGestaltPrivate // For fetching UDID

// MARK: - Ensemble Protocol -

// MARK: - Constants

/// Mach service name exposed by ensembled
@_spi(Daemon)
public let kEnsemblerServiceName = "com.apple.cloudos.AppleComputeEnsembler.service"

@available(macOS 15.0, iOS 18.0, *)
public let kDefaultRackID = "DEFAULT.RACK.ID"

@available(macOS 15.0, iOS 18.0, *)
public let kDefaultEnsembleID = "DEFAULT.ENSEMBLE.ID"

@available(macOS 15.0, iOS 18.0, *)
public let kEnsembleStatusReadyEventName =
	"com.apple.cloudos.AppleComputeEnsembler.Notification.ready"

@available(macOS 15.0, iOS 18.0, *)
public let kEnsembleStatusFailedEventName =
	"com.apple.cloudos.AppleComputeEnsembler.Notification.failed"

// MARK: - Errors

@available(macOS 15.0, iOS 18.0, *)
public enum EnsembleError: Error {
	/// XPC Client failed to connect
	case clientConnectionFailure
	/// Failed to construct/send/receive an XPC message
	case messagingFailure
	/// Command received but failed to complete/execute
	case commandFailure(error: String?)
	/// Internal error
	case internalError(error: String?)
	/// Can not fetch the EnsembleStatus (failure within the daemon)
	case statusNotFound
	/// Shared key is not set yet.
	case shareKeyNotFound
	/// Cannot determine own UDID
	case cannotDetermineUDID
	/// Cannot find node info
	case cannotFindNodesInfo
	/// Cannot find node info about ourselves
	case cannotFindSelfInfo
	/// Cannot find the node leader
	case cannotFindLeaderInfo
	/// Failed to retrieve the node's draining state
	case drainingNotFound
	/// No single use key token found
	case cannotFindSingleUseKeyToken
	/// cannot find the KVKey
	case cannotFindKVKey
    /// createAttestationFailed
    case createAttestationFailed
    /// refreshAttestationFailed
    case refreshAttestationFailed
    
    public var errorDescription: String? {
        switch self {
        case .clientConnectionFailure:
            return "XPC client failed to connect to ensembled service"
        case .messagingFailure:
            return "Failed to construct, send, or receive XPC message"
        case .commandFailure(let error):
            if let error = error {
                return "Command failed to execute: \(error)"
            } else {
                return "Command failed to execute"
            }
        case .internalError(let error):
            if let error = error {
                return "Internal ensemble error: \(error)"
            } else {
                return "Internal ensemble error occurred"
            }
        case .statusNotFound:
            return "Cannot fetch ensemble status from daemon"
        case .shareKeyNotFound:
            return "Shared key is not available"
        case .cannotDetermineUDID:
            return "Cannot determine device UDID"
        case .cannotFindNodesInfo:
            return "Cannot find node information in ensemble"
        case .cannotFindSelfInfo:
            return "Cannot find information about current node"
        case .cannotFindLeaderInfo:
            return "Cannot find ensemble leader information"
        case .drainingNotFound:
            return "Failed to retrieve node's draining state"
        case .cannotFindSingleUseKeyToken:
            return "No single-use key token found"
        case .cannotFindKVKey:
            return "Cannot find KV cache key"
        case .createAttestationFailed:
            return "Failed to create attestation"
        case .refreshAttestationFailed:
            return "Failed to refresh attestation"
        }
    }
}

// MARK: - Client Protocol (Public)

/// User-visible status of ensemble
@available(macOS 15.0, iOS 18.0, *)
public enum EnsemblerStatus: Codable, CaseIterable, CustomStringConvertible {
	/// Cannot determine ensemble state
	case unknown
	/// Ensemble failed to load or initialize configuration
	case uninitialized
	/// Configuration loaded and initialization in progress
	case initializing
	/// Checking that the darwin-init applied successfully
	case initializingDarwinInitCheckInProgress
	/// Activating the backend since all of the activation checks passed
	case initializingActivationChecksOK
	/// Ready to Ensemble, talking to our pals
	case coordinating
	/// The node has got the key and the key is validated by leader.
	case keyAccepted
	/// Ensemble in failed state; currently unrecoverable
	case failed
	/// An activation check failed before we even tried to activate the backend
	case failedActivationChecks
	/// Ensemble failed during a drain event. Almost certainly, a neighbor rebooted and we're about to
	/// reboot too!
	case failedWhileDraining
	/// All nodes got their shared key, and set the key in CIO Mesh
	case ready
	/// All nodes checked in, and now leader is distributing the CIOMesh key
	case distributingKey
	/// Leader got request for rotating key, and is resdistributing key.
	case redistributingKey
	/// The CIO key is now distributed in all nodes.
	case distributedCIOKey
	/// The ensembled is activating the backend (CIOMesh, Stub etc)
	case activating
	/// The ensembled has activated the backend and waiting to recieve acknolwedgement from followers
	/// that they also activated the backend successfully
	case activated

	// This `description` is logged. Do not expose private info!
	public var description: String {
		switch self {
		case .unknown:
			return "unknown"
		case .uninitialized:
			return "uninitialized"
		case .initializing:
			return "initializing"
		case .initializingDarwinInitCheckInProgress:
			return "initializingDarwinInitCheckInProgress"
		case .initializingActivationChecksOK:
			return "initializingActivationChecksOK"
		case .coordinating:
			return "coordinating"
		case .keyAccepted:
			return "keyAccepted"
		case .failed:
			return "failed"
		case .failedActivationChecks:
			return "failedActivationChecks"
		case .failedWhileDraining:
			return "failedWhileDraining"
		case .ready:
			return "ready"
		case .distributedCIOKey:
			return "distributedCIOKey"
		case .distributingKey:
			return "distributingKey"
		case .activating:
			return "activating"
		case .redistributingKey:
			return "redistributingKey"
		case .activated:
			return "activated"
		}
	}

	public func inFailedState() -> Bool {
		switch self {
		case .failed:
			fallthrough
		case .failedWhileDraining:
			fallthrough
		case .failedActivationChecks:
			return true
		default:
			return false
		}
	}
}

@available(macOS 15.0, iOS 18.0, *)
public struct EnsembleTracingContext {
    public let name: String?
    public let requestID: UUID
    public let spanID: UInt64
    public let parentSpanID:  UInt64?
    
    // Public initializer
    public init(name: String?, requestID: UUID, spanID: UInt64, parentSpanID: UInt64?) {
        self.name = name
        self.requestID = requestID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
    }
}

extension UInt64 {
    var hexEncoded: String {
        String(format:"%016llx", self)
    }
}

/// User visible information about nodes
@available(macOS 15.0, iOS 18.0, *)
public struct EnsembleNodeInfo: Codable {
	public let leader: Bool
	public let UDID: String
	public let rank: Int
	public let hostName: String?
	public let chassisID: String?

	public var found: Bool? // true indicates the node has checked in its presence to the leader
	public var keyShared: Bool? // true indicates that the node acknowledge it got the shared CIO key
	// from the leader
	public var dataKeyShared: Bool? // true indicates that the node acknoledged it got the shared data
	// key from the
	// the leader.
	public var nodeReady: Bool? // true indicates that the node is ready to go to ready state.
	public var activated: Bool? // true indicates that the node has activate its ciomesh.
    public var gpuCount: Int = 1
	public init(
		leader: Bool,
		UDID: String,
		rank: Int,
		hostName: String? = nil,
		chassisID: String? = nil,
        gpuCount: Int
	) {
		self.leader = leader
		self.UDID = UDID
		self.rank = rank
		self.hostName = hostName
		self.chassisID = chassisID
        self.gpuCount = gpuCount
	}
}

/// Access token to get a key
@available(macOS 15.0, iOS 18.0, *)
public typealias SingleUseKeyToken = UUID

/// Device filter to filter the devices during attestation
@available(macOS 15.0, iOS 18.0, *)
public typealias EnsembleDeviceFilter = (String) -> Bool

/// Key distribution strategy
@available(macOS 15.0, iOS 18.0, *)
public enum DistributionType: String, Sendable, Codable, CodingKeyRepresentable, Equatable {
	case local
	case distributed
}

/// refresh callback for refreshing attestation
@available(macOS 15.0, iOS 18.0, *)
public typealias refreshAttestation = @Sendable () async throws -> Void

/// Callback for handling incoming data messages and returning responses
@available(macOS 15.0, iOS 18.0, *)
public typealias EnsembleDataMessageReceived = (Int, Data) -> Data

/// Async callback for handling incoming data messages and returning responses.
/// Prefer this over EnsembleDataMessageReceived: each invocation runs as an
/// independent Swift Task, avoiding GCD thread exhaustion under burst load.
@available(macOS 15.0, iOS 18.0, *)
public typealias EnsembleDataMessageReceivedAsync = @Sendable (Int, Data) async throws -> Data

/// Copied verbatim from CMAC.
@available(macOS 15.0, iOS 18.0, *)
public enum HealthState: String, Sendable, Codable, CodingKeyRepresentable, Equatable {
	// responsive with known/confirmed bad
	case unhealthy
	// responsive with known/confirmed good
	case healthy
	// unresponsive - unknown good or unknown bad, but assume bad
	case unknown
	// responsive with unconfirmed good or bad (like during bootup)
	// this state specifically means that a caller should retry/checking again
	// the health state with some timeout before considering it unhealthy in
	// case the health domain application is stuck
	case initializing
}

/// Health status (derived from `EnsembleStatus`).
@available(macOS 15.0, iOS 18.0, *)
public struct EnsembleHealth: Sendable, Codable {
	public let healthState: HealthState
	public var metadata: [String: String]

	public init(
		healthState: HealthState,
		internalState: EnsemblerStatus,
		message1: String? = nil,
		message2: String? = nil
	) {
		self.healthState = healthState
		self.metadata = ["ensemblerStatus": "\(internalState)"]

		if message1 != nil {
			self.metadata["message1"] = message1
		}

		if message2 != nil {
			self.metadata["message2"] = message2
		}
	}
}

/// Health status (derived from `EnsembleStatus`).
@available(macOS 15.0, iOS 18.0, *)
public struct NodeResponse: Codable {
    public let rank: Int
    public let data: Data?
    public let errorMessage: String?
    public let timestamp: Date
    
    public var error: Error? {
        if let errorMessage = errorMessage {
            return EnsembleError.internalError(error: errorMessage)
        }
        return nil
    }
    
    public init(rank: Int, data: Data?, error: Error?, timestamp: Date) {
        self.rank = rank
        self.data = data
        self.errorMessage = error?.localizedDescription
        self.timestamp = timestamp
    }
    
}

// MARK: - XPC Protocol (Private)

/// Possible commands for ensembled
@_spi(Daemon)
public enum EnsemblerRequest: Codable {
	/// Return Ensemble Status
	case getStatus
	/// Return whether the ensembler is draining
	case getDraining
	/// Return the ensemble's health
	case getHealth
	/// Get cable diagnostics for a failed ensemble. Only works on 8-node ensembles.
	case getCableDiagnostics
	/// Activate ensembed if not auto-initialized
	case activate
	// Debug Functionality
	/// Shutdown ensemble (Unimplemented)
	case shutdown
	/// Re-Attempt Configuration; only valid on configuration failure
	case reloadConfiguration
	/// Send a test message within the ensemble
	case sendTestMessage(Int)
	/// Get information on nodes assigned to ensemble
	case getNodeMap
	// Currently unimplemented, copied from the test tool (needed?)
	/// Get ensemble routes (Unimplemented)
	case getRoutes
	/// Get ensemble CIOMap (Unimplemented)
	case getCIOMap
	/// Encrypts the plain text data
	case encryptData(Data)
	/// Decrypts the encrypted  data
	case decryptData(Data)
	/// Rotate shared key
	case rotateSharedKey
	/// Get max buffers per key, after which CIO mesh will fail allocation
	case getMaxBuffersPerKey
	/// Get max seconds per key, after which CIO mesh will fail allocation
	case getMaxSecsPerKey
	/// Get the ensemble ID
	case getEnsembleID
    /// Get the rack ID
    case getRackID
	/// Get authetnication code
	case getAuthCode(Data)
	/// Distribute a KVCache key
	case distributeDataKey(Data, DistributionType)
	/// get KVCache key
	case getDataKey(SingleUseKeyToken)
	/// Register callback for receiving data messages for an appID
	case registerDataCallback(String, String)
	/// Unregister callback for receiving data messages
	case unregisterDataCallback(String)
	/// Send data to a destination and get response
	case sendDataAndGetResponse(String, Data, Int, TimeInterval)
	/// Send data to all followers and get responses
	case sendDataToAllFollowers(String, Data, TimeInterval)
    /// Message to indicate received data
    case recievedData(Int, String, Data)
}

/// XPC response from ensembled to the framework
@_spi(Daemon)
public struct EnsemblerResponse: Codable {
	/// Result of operation requested
	public var result: Bool
	/// Current status
	public var status: EnsemblerStatus?
	/// Current draining state (`true` if draining, `false` otherwise)
	public var draining: Bool?
	/// Error (if relevant)
	public var error: String?
	/// Dictionary of UDID/NodeInfo
	public var nodesInfo: [String: EnsembleNodeInfo]?
	/// Current health
	public var health: EnsembleHealth?
	/// List of Strings encoding cable diagnostics for an 8-node ensemble that failed to activate.
	public var cableDiagnostics: [String]?
	/// encrypted text
	public var encrypted: Data?
	/// decrypted text
	public var decrypted: Data?
	/// max buffers per key
	public var maxBuffersPerKey: UInt64?
	/// max seconds per key
	public var maxSecsPerKey: UInt64?
	/// ensemble ID
	public var ensembleID: String?
    /// rack ID
    public var rackID: String?
	/// authentication code
	public var authCode: Data?
	/// SingleUseKeyToken
	public var singleUseKeyToken: SingleUseKeyToken?
	/// KVCache key
	public var kvKey: Data?
	/// Response data from sendDataAndGetResponse
	public var responseData: Data?
	/// Response data from sendDataToAllFollowers
	public var allFollowersResponseData: [NodeResponse]?
	/// JSON-encoded DataMessageError; present when result is false and a typed data-messaging
	/// error occurred so the Framework can rethrow it with full type fidelity.
	public var dataMessageError: Data?

	public init(
		result: Bool,
		status: EnsemblerStatus? = nil,
		draining: Bool? = nil,
		error: String? = nil,
		nodesInfo: [String: EnsembleNodeInfo]? = nil,
		encrypted: Data? = nil,
		decrypted: Data? = nil,
		health: EnsembleHealth? = nil,
		cableDiagnostics: [String]? = nil,
		maxSecsPerKey: UInt64? = nil,
		maxBuffersPerKey: UInt64? = nil,
		ensembleID: String? = nil,
        rackID: String? = nil,
		authCode: Data? = nil,
		singleUseKeyToken: SingleUseKeyToken? = nil,
		kvKey: Data? = nil,
		responseData: Data? = nil,
		allFollowersResponseData: [NodeResponse]? = nil,
		dataMessageError: Data? = nil
	) {
		self.result = result
		self.status = status
		self.draining = draining
		self.error = error
		self.nodesInfo = nodesInfo
		self.health = health
		self.cableDiagnostics = cableDiagnostics
		self.encrypted = encrypted
		self.decrypted = decrypted
		self.maxSecsPerKey = maxSecsPerKey
		self.maxBuffersPerKey = maxBuffersPerKey
		self.ensembleID = ensembleID
        self.rackID = rackID
		self.authCode = authCode
		self.singleUseKeyToken = singleUseKeyToken
		self.kvKey = kvKey
		self.responseData = responseData
		self.allFollowersResponseData = allFollowersResponseData
		self.dataMessageError = dataMessageError
	}
}

// MARK: - Helper Functions (Private)

/// Quick and dirty helper function for fetching the UDID
@_spi(Daemon)
public func getNodeUDID() throws -> String {
	guard let udid = MGGetStringAnswer("UniqueDeviceID" as CFString) as? String else {
		throw EnsembleError.cannotDetermineUDID
	}
	return udid
}

@_spi(Daemon)
public class KeyDataWrapper {
	public var data: Data
	private var keyDataPointer: UnsafeRawPointer?

	init(data: Data) {
		self.data = data
		self.keyDataPointer = data.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!) }
	}

	/// Securely zeroes the memory of the key data using memset_s
	func zeroKey() {
		guard let pointer = keyDataPointer else { return }
		let keySize = self.data.count
		memset_s(UnsafeMutableRawPointer(mutating: pointer), keySize, 0, keySize)
	}

	deinit {
		// Ensure key data is securely cleared when the object is deallocated
		zeroKey()
	}
}

@_spi(Daemon)
public enum DerivedKeyType: CustomStringConvertible {
	case MeshEncryption
	case TlsPsk
	case KeyConfirmation(String)
	case TestEncryptDecrypt

	public var description: String {
		switch self {
		case .MeshEncryption:
			return "ensembled-mesh-encryption"
		case .TlsPsk:
			return "ensembled-tls-psk"
		case .KeyConfirmation(let nodeUDID):
			return "ensembled-key-confirmation-\(nodeUDID)"
		case .TestEncryptDecrypt:
			return "ensembled-test-encrypt-decrypt"
		}
	}
}

@_spi(Daemon)
// No explicit copying or duplication is allowed.
public struct SecureSymmetricKey: ~Copyable {
	private var key: SymmetricKey
	// we need the rawpointer so we can zero in the memory using memset_s which is more secure.
	private var keyDataPointer: UnsafeRawPointer?
	private var keySize: Int

	// we need the class wrapper to data, since by default when data is returned it is by value
	// so in order to avoid copying around Data, we pass reference when needed.
	private var keyData: KeyDataWrapper

	public init(key: SymmetricKey) {
		// Generate a new symmetric key
		self.key = key
		self.keyData = KeyDataWrapper(data: key.withUnsafeBytes { Data(Array($0)) })
		self.keySize = key.withUnsafeBytes { $0.count }
		self.keyDataPointer = key.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!) }
	}

	public init() {
		// Generate a new symmetric key
		self.key = SymmetricKey(size: .bits128)
		self.keyData = KeyDataWrapper(data: self.key.withUnsafeBytes { Data(Array($0)) })
		self.keySize = self.key.withUnsafeBytes { $0.count }
		self.keyDataPointer = self.key.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!) }
	}

	public init(data: Data) {
		self.key = SymmetricKey(data: data)
		self.keyData = KeyDataWrapper(data: data)
		self.keySize = self.key.withUnsafeBytes { $0.count }
		self.keyDataPointer = self.key.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!) }
	}

	public func getKeyDataWrapper() -> KeyDataWrapper {
		return self.keyData
	}

	public func getAuthCode(data: Data) -> Data {
		let authenticationCode = HMAC<SHA256>.authenticationCode(for: data, using: self.key)
		let authenticationData = authenticationCode.withUnsafeBytes {
			return Data($0)
		}

		return authenticationData
	}

	public func encrypt(data: Data) throws -> Data {
		let box = try CryptoKit.AES.GCM.seal(data, using: self.key)
		guard let encryptedData = box.combined else {
			throw EnsembleError.internalError(error: "Error encrypting data")
		}

		return encryptedData
	}

	public func decrypt(data: Data) throws -> Data {
		let box = try CryptoKit.AES.GCM.SealedBox(combined: data)

		let decrypted = try CryptoKit.AES.GCM.open(box, using: self.key)
		return decrypted
	}

    public func getDerivedKey(type: DerivedKeyType, outputSize: Int = 32) throws -> SecureSymmetricKey {
		try self.deriveKey(salt: "\(type)-salt", info: "\(type)-info", outputSize: outputSize)
	}

	/// Method to derive a new key using HKDF<SHA384>
	public func deriveKey(salt: String, info: String, outputSize: Int = 32) throws -> SecureSymmetricKey {
		guard let salt = salt.data(using: .utf8) else {
			throw EnsembleError.internalError(error: "Error forming salt from \(salt).")
		}

		guard let info = info.data(using: .utf8) else {
			throw EnsembleError.internalError(error: "Error forming info from \(info).")
		}

		let derivedKey = HKDF<SHA384>.deriveKey(
			inputKeyMaterial: self.key,
			salt: salt,
			info: info,
			outputByteCount: outputSize
		)
		let derivedKeyData = derivedKey.withUnsafeBytes { Data($0) }

		return SecureSymmetricKey(data: derivedKeyData)
	}

	/// Expose a Data object that wraps the key data without copying
	func getKeyDataReference() -> Data {
		return Data(
			bytesNoCopy: UnsafeMutableRawPointer(mutating: self.keyDataPointer!),
			count: self.keySize,
			deallocator: .none
		)
	}

	/// Securely zeroes the memory of the key data using memset_s
	public func zeroKey() {
		guard let pointer = keyDataPointer else { return }
		let keySize = self.key.withUnsafeBytes { $0.count }
		memset_s(UnsafeMutableRawPointer(mutating: pointer), keySize, 0, keySize)
	}

	deinit {
		// Ensure key data is securely cleared when the object is deallocated
		zeroKey()
	}
}

// MARK: - Ensemble Session -


fileprivate var configurator: AttestedTLS.Configurator<EnsembleAttestor>?
/// A client representing an XPC connection to ensembled. Session lifecycle is tied to the client
@available(macOS 15.0, iOS 18.0, *)
public class EnsemblerSession {
    
	var session: XPCSession? = nil
	let targetQ: DispatchQueue?
	// Tracks in-flight sendCommandAsyncGuarded sends. deinit waits for this
	// group to empty before calling session.cancel(), so cancel only fires
	// after every queued reply handler has had its first delivery
	// (rdar://172856722).
	private let pendingSendsGroup = DispatchGroup()
	var UDID: String? = nil
	private struct CallbackState {
		var registry: [String: EnsembleDataMessageReceived] = [:]
		var asyncRegistry: [String: EnsembleDataMessageReceivedAsync] = [:]
		var appIDToCallbackIDs: [String: String] = [:]
	}
	private let callbackStateLock = OSAllocatedUnfairLock(initialState: CallbackState())

	static let logger = Logger(subsystem: "com.apple.cloudos.Ensemble", category: "EnsemblerClient")

    // Handler to receive and process request from ensembled.
    private func handleIncoming(_ request: EnsemblerRequest) -> EnsemblerResponse {
        EnsemblerSession.logger.debug("Received incoming message from ensembled.")
        switch request {
        case .recievedData(let sender, let callbackID, let data):
            EnsemblerSession.logger.debug("Received .recievedData with \(callbackID, privacy: .public)")
            guard let callback = callbackStateLock.withLock({ $0.registry[callbackID] }) else {
                EnsemblerSession.logger.error("No handler exists for \(callbackID, privacy: .public)")
                return EnsemblerResponse(result: false, error: "noRegisteredHandler")
            }
            EnsemblerSession.logger.debug("Handler exists for \(callbackID, privacy: .public), calling it now")
            let responseData = callback(sender, data)
            return EnsemblerResponse(result: true, responseData: responseData)
        default:
            EnsemblerSession.logger.warning("Received incoming message from ensembled, but not handled.")
            return EnsemblerResponse(result: true)
        }
    }
    
	/// Optionally accept a dispatch queue to be passed to XPCSession
	///  - NOTE: will fall back to default queue if `nil`
	public init(targetQ: DispatchQueue?) throws {
		self.targetQ = targetQ
		do {
			self.session = try XPCSession(
				machService: kEnsemblerServiceName,
				targetQueue: self.targetQ,
                options: [],
                incomingMessageHandler: { [weak self] (message: XPCReceivedMessage) in
                    return message.handoffReply(to: .global(qos: .userInitiated)) {
                        guard let self = self else {
                            EnsemblerSession.logger.error("EnsemblerSession xpc incomingMessageHandler, deallocated self")
                            return
                        }

                        do {
                            EnsemblerSession.logger.debug("Received data")
                            let request = try message.decode(as: EnsemblerRequest.self)
                            EnsemblerSession.logger.debug("Received data and converted to EnsemblerRequest")

                            // Async fast path: launch a Task so the callback runs cooperatively —
                            // no GCD thread held during await, enabling concurrent message handling.
                            if case .recievedData(let sender, let callbackID, let data) = request,
                               let asyncCb = self.callbackStateLock.withLock({ $0.asyncRegistry[callbackID] }) {
                                Task(priority: .userInitiated) {
                                    do {
                                        let responseData = try await asyncCb(sender, data)
                                        message.reply(EnsemblerResponse(result: true, responseData: responseData))
                                    } catch {
                                        EnsemblerSession.logger.error(
                                            "Async data callback failed for \(callbackID, privacy: .public): \(error, privacy: .public)"
                                        )
                                        message.reply(EnsemblerResponse(result: false, error: error.localizedDescription))
                                    }
                                }
                                return  // Task owns the reply; handoffReply block exits here
                            }

                            // Sync path: unchanged for existing callers
                            let response = self.handleIncoming(request)
                            EnsemblerSession.logger.debug("Returning reply")

                            // Reply to the message with the result
                            message.reply(response)
                        }
                        catch {
                            let response = EnsemblerResponse(result: false, responseData: nil)
                            EnsemblerSession.logger.error("Failed to decode received message")
                            message.reply(response)
                        }
                    }
                },
                cancellationHandler: { error in
                    EnsemblerSession.logger.warning("Session cancelled: \(error)")
                }
			)
            
			self.UDID = try getNodeUDID()
		} catch {
			EnsemblerSession.logger.error("Failed to establish XPC session with ensembled")
			throw EnsembleError.clientConnectionFailure
		}
	}

	deinit {
        guard let xpcSession = self.session else {
            EnsemblerSession.logger.error("XPC session with ensembled does not exists")
            return
        }
        // Defer cancel until every in-flight sendCommandAsyncGuarded send has
        // had its first reply handler fire (real reply or XPC error). This
        // ensures cancel only reaches sends that truly have no reply yet,
        // preventing double-resume of CheckedContinuations (rdar://172856722).
        pendingSendsGroup.notify(queue: .global()) {
            xpcSession.cancel(reason: "client destroyed")
        }
	}

	private func validateResponse(response: EnsemblerResponse) throws {
		guard response.result == true else {
			EnsemblerSession.logger
				.error(
					"Ensembler command failed, error: \(String(describing: response.error), privacy: .public)"
				)
			throw EnsembleError.commandFailure(error: response.error)
		}
	}

	/// Like validateResponse, but for the data-messaging API path.
	/// If the daemon encoded a typed DataMessageError it is rethrown directly so callers
	/// can distinguish notReady / timeoutOnPeerHandler / noRegisteredHandler / etc.
	/// Falls back to EnsembleError.commandFailure when no typed error is present.
	private func validateDataMessageResponse(response: EnsemblerResponse) throws {
		guard response.result == true else {
			if let encoded = response.dataMessageError,
			   let dataError = try? JSONDecoder().decode(DataMessageError.self, from: encoded) {
				EnsemblerSession.logger.error("Data message error: \(dataError, privacy: .public)")
				throw dataError
			}
			EnsemblerSession.logger
				.error(
					"Data message command failed, error: \(String(describing: response.error), privacy: .public)"
				)
			throw EnsembleError.commandFailure(error: response.error)
		}
	}

	private func grabStatus(response: EnsemblerResponse) throws -> EnsemblerStatus {
		guard let status = response.status else {
			EnsemblerSession.logger.error("No ensemble status found")
			throw EnsembleError.statusNotFound
		}
		EnsemblerSession.logger
			.debug("Received status: \(String(describing: status), privacy: .public)")
		return status
	}

	private func grabDraining(response: EnsemblerResponse) throws -> Bool {
		guard let draining = response.draining else {
			EnsemblerSession.logger.error("No draining state found")
			throw EnsembleError.drainingNotFound
		}
		EnsemblerSession.logger
			.debug("Received draining: \(draining, privacy: .public)")
		return draining
	}

	private func checkForReadiness(status: EnsemblerStatus?) -> Bool {
		guard status != nil else {
			EnsemblerSession.logger.error("Ensemble health status uninitialized")
			return false
		}

		switch status {
		case .ready:
			EnsemblerSession.logger.debug("Ensemble considered ready due to ready status")
			return true
		default:
			EnsemblerSession.logger
				.info(
					"Ensemble considered unready due to \(String(describing: status), privacy: .public) status"
				)
		}

		return false
	}

	private func validateNodesInfo(response: EnsemblerResponse) throws {
		try self.validateResponse(response: response)
		guard response.nodesInfo != nil else {
			EnsemblerSession.logger.error("No node info found in ensembler response")
			throw EnsembleError.cannotFindNodesInfo
		}
	}

	private func grabPeers(response: EnsemblerResponse) throws -> [EnsembleNodeInfo]? {
		try self.validateNodesInfo(response: response)
		guard let peers = response.nodesInfo?.filter({ $0.key != self.UDID }) else {
			EnsemblerSession.logger.error("No peers found in ensemble")
			return nil
		}

		return Array(peers.values)
	}

	private func grabSelf(response: EnsemblerResponse) throws -> EnsembleNodeInfo {
		try self.validateNodesInfo(response: response)
        guard let udid = self.UDID else {
            EnsemblerSession.logger.error("Could not find UDID")
            throw EnsembleError.cannotFindSelfInfo
        }
        
		guard let info = response.nodesInfo?[udid] else {
			EnsemblerSession.logger.error("Could not find self in node info")
			throw EnsembleError.cannotFindSelfInfo
		}

		return info
	}

	private func grabLeader(response: EnsemblerResponse) throws -> EnsembleNodeInfo {
		try self.validateNodesInfo(response: response)
		guard let leader = response.nodesInfo?.first(where: { $0.value.leader == true }) else {
			EnsemblerSession.logger.error("Cannot find lead nodes")
			throw EnsembleError.cannotFindLeaderInfo
		}

		return leader.value
	}

	private func grabSingleUseKeyToken(response: EnsemblerResponse) throws -> SingleUseKeyToken {
		guard let token = response.singleUseKeyToken else {
			EnsemblerSession.logger.error("Could not find single use key token")
			throw EnsembleError.cannotFindSingleUseKeyToken
		}

		return token
	}

	private func grabKVKey(response: EnsemblerResponse) throws -> Data {
		guard let key = response.kvKey else {
			EnsemblerSession.logger.error("Could not find KV key")
			throw EnsembleError.cannotFindKVKey
		}

		return key
	}

	// MARK: - Client Methods (Public)

	/// Create a new EnsembleSession using the default queue for the underlying XPC Session
	public convenience init() throws {
		// While this is fairly easy to achieve with optionals/defaults, we maintain a simple
		// initializer as a binding interface contract
		try self.init(targetQ: nil)
	}

	/// Blocking call to get current status of ensemble
	public func getStatus() throws -> EnsemblerStatus {
		EnsemblerSession.logger.debug("Requesting ensemble status")
		let response = try sendCommandSync(command: EnsemblerRequest.getStatus)
		try self.validateResponse(response: response)
		return try self.grabStatus(response: response)
	}

	/// Async-Friendly(TM) call to get current status of the ensemble
	public func getStatus() async throws -> EnsemblerStatus {
		EnsemblerSession.logger.debug("Requesting ensemble status asynchronously")
		let response = try await sendCommandAsync(command: EnsemblerRequest.getStatus)
		try self.validateResponse(response: response)
		return try self.grabStatus(response: response)
	}

	/// Simple blocking boolean determination of ensemble health
	///  - Returns: `true` if healthy and `false` if not healthy or indeterminate due to any issue
	/// including XPC issues
	public func isReady() -> Bool {
		EnsemblerSession.logger.debug("Triggering simple ensemble readiness check")
		do {
			let status = try getStatus()
			return self.checkForReadiness(status: status)
		} catch {
			EnsemblerSession.logger
				.error("Failed to perform simple health check so reporting false")
			return false
		}
	}

	/// Simple Async-Friendly(TM) boolean determination of ensemble health
	/// - Returns: `true` if healthy and `false` if not healthy or indeterminate due to any issue
	/// including XPC issues
	public func isReady() async -> Bool {
		EnsemblerSession.logger.debug("Triggering simple async ensemble readiness check")
		do {
			let status = try await getStatus()
			return self.checkForReadiness(status: status)
		} catch {
			EnsemblerSession.logger
				.error("Failed to perform simple health check so reporting false")
			return false
		}
	}

	/// Simple blocking boolean determination of ensemble draining
	///  - Returns: `true` if draining and `false` otherwise
	public func isDraining() throws -> Bool {
		EnsemblerSession.logger.debug("Requesting ensemble draining state")
		let response = try sendCommandSync(command: EnsemblerRequest.getDraining)
		try self.validateResponse(response: response)
		return try self.grabDraining(response: response)
	}

	/// Simple Async-Friendly(TM) determination of ensemble draining
	/// - Returns: `true` if draining and `false` otherwise
	public func isDraining() async throws -> Bool {
		EnsemblerSession.logger.debug("Requesting ensemble draining asynchronously")
		let response = try await sendCommandAsync(command: EnsemblerRequest.getDraining)
		try self.validateResponse(response: response)
		return try self.grabDraining(response: response)
	}

	/// Blocking call to receive node information for self
	/// - Returns: `EnsembleNodeInfo` including information for current node or throws an error if
	/// it cannot be provided
	public func getNodeInfo() throws -> EnsembleNodeInfo {
		EnsemblerSession.logger.debug("Requesting node information")
		let response = try sendCommandSync(command: .getNodeMap)
		return try self.grabSelf(response: response)
	}

	/// Async-Friendly(TM) call to receive node information for self
	/// - Returns: `EnsembleNodeInfo` including information for current node or throws an error if
	/// it cannot be provided
	public func getNodeInfo() async throws -> EnsembleNodeInfo {
		EnsemblerSession.logger.debug("Requesting node information asynchronously")
		let response = try await sendCommandAsync(command: .getNodeMap)
		return try self.grabSelf(response: response)
	}

	/// Assumption: distributeKey will be called only on leader.
	/// when distributeKey called with local, ensembled will generate the UUID, store the {UUID->key}
	/// in memory, and will NOT distribute to followers.
	/// when distributeKey called with distributed, ensembled will generate the UUID, store the
	/// {UUID->key} memory, and will distribute to followers.
	/// Blocking call to distribute a key
	/// - Returns: SingleUseKeyToken
	public func distributeDataKey(
		key: SymmetricKey,
		type: DistributionType
	) throws -> SingleUseKeyToken {
		EnsemblerSession.logger.debug("Trigger distributing a key")

		let secureKey = SecureSymmetricKey(key: key)
		let keyData = secureKey.getKeyDataWrapper().data

		let response = try sendCommandSync(command: .distributeDataKey(keyData, type))
		return try self.grabSingleUseKeyToken(response: response)
	}

	/// Async-Friendly(TM) call to distribute a key
	public func distributeDataKey(
		key: SymmetricKey,
		type: DistributionType
	) async throws -> SingleUseKeyToken {
		EnsemblerSession.logger.debug("Trigger distributing a key")

		let secureKey = SecureSymmetricKey(key: key)
		let keyData = secureKey.getKeyDataWrapper().data
		let response = try await sendCommandAsync(command: .distributeDataKey(keyData, type))
		return try self.grabSingleUseKeyToken(response: response)
	}
    
    /// Assumption: distributeKey will be called only on leader.
    /// when distributeKey called with local, ensembled will generate the UUID, store the {UUID->key}
    /// in memory, and will NOT distribute to followers.
    /// when distributeKey called with distributed, ensembled will generate the UUID, store the
    /// {UUID->key} memory, and will distribute to followers.
    /// Blocking call to distribute a key
    /// - Returns: SingleUseKeyToken
    public func distributeDataKey(
        key: AES.GCM.SealedBox,
        type: DistributionType,
        tracingContext: EnsembleTracingContext? = nil
    ) throws -> SingleUseKeyToken {
        EnsemblerSession.logger.debug("Trigger distributing a key")
        
        let spanID = generateSpanId()
        var summary = DistributeDataSummary(requestID: tracingContext?.requestID.uuidString, spanID: spanID, parentSpanID: tracingContext?.spanID.hexEncoded, operationName: "Distributing data key")
        
        return try summary.loggingRequestSummary(logger: EnsemblerSession.logger) {
            guard let keyData = key.combined else {
                EnsemblerSession.logger.error("Error getting keydata")
                throw EnsembleError.internalError(error: "Error getting keydata")
            }
            
            let response = try self.sendCommandSync(command: .distributeDataKey(keyData, type))
            return try self.grabSingleUseKeyToken(response: response)
        }
    }

    /// Async-Friendly(TM) call to distribute a key
    public func distributeDataKey(
        key: AES.GCM.SealedBox,
        type: DistributionType,
        tracingContext: EnsembleTracingContext? = nil
    ) async throws -> SingleUseKeyToken {
        EnsemblerSession.logger.debug("Trigger distributing a key")
        
        let spanID = generateSpanId()
        var summary = DistributeDataSummary(requestID: tracingContext?.requestID.uuidString, spanID: spanID, parentSpanID: tracingContext?.spanID.hexEncoded, operationName: "Distributing data key")
                
        return try await summary.loggingRequestSummary(logger: EnsemblerSession.logger) {
            guard let keyData = key.combined else {
                EnsemblerSession.logger.error("Error getting keydata")
                throw EnsembleError.internalError(error: "Error getting keydata")
            }
            
            let response = try await self.sendCommandAsync(command: .distributeDataKey(keyData, type))
            return try self.grabSingleUseKeyToken(response: response)
        }
    }
    
    // TODO: To remove it after TIE switches to using new interface
    /// Assumption: distributeKey will be called only on leader.
    /// when distributeKey called with local, ensembled will generate the UUID, store the {UUID->key}
    /// in memory, and will NOT distribute to followers.
    /// when distributeKey called with distributed, ensembled will generate the UUID, store the
    /// {UUID->key} memory, and will distribute to followers.
    /// Blocking call to distribute a key
    /// - Returns: SingleUseKeyToken
    @available(*, deprecated, message: "use distributeDataKey with Tracingcontext")
    public func distributeDataKey(
        key: AES.GCM.SealedBox,
        type: DistributionType
    ) throws -> SingleUseKeyToken {
        EnsemblerSession.logger.debug("Trigger distributing a key")
        guard let keyData = key.combined else {
            EnsemblerSession.logger.error("Error getting keydata")
            throw EnsembleError.internalError(error: "Error getting keydata")
        }

        let response = try sendCommandSync(command: .distributeDataKey(keyData, type))
        return try self.grabSingleUseKeyToken(response: response)
    }

    /// Async-Friendly(TM) call to distribute a key
    @available(*, deprecated, message: "use distributeDataKey with Tracingcontext")
    public func distributeDataKey(
        key: AES.GCM.SealedBox,
        type: DistributionType
    ) async throws -> SingleUseKeyToken {
        EnsemblerSession.logger.debug("Trigger distributing a key")
        guard let keyData = key.combined else {
            EnsemblerSession.logger.error("Error getting keydata")
            throw EnsembleError.internalError(error: "Error getting keydata")
        }
        
        let response = try await sendCommandAsync(command: .distributeDataKey(keyData, type))
        return try self.grabSingleUseKeyToken(response: response)
    }
    
    /// Assumption: getDataKey will be called  on leader as well followers
    /// when getDataKey  called ensembled will return the key in memory, and will delete the key in
    /// memory
    /// Blocking call to distribute a key
    /// - Returns: `Data
    public func getDataKey(token: SingleUseKeyToken, tracingContext: EnsembleTracingContext? = nil) throws -> AES.GCM.SealedBox {
        EnsemblerSession.logger.debug("Getting Data key")
        
        let spanID = generateSpanId()
        var summary = GetDatakeySummary(token: token.uuidString, requestID: tracingContext?.requestID.uuidString, spanID: spanID, parentSpanID: tracingContext?.spanID.hexEncoded)
                
        return try summary.loggingRequestSummary(logger: EnsemblerSession.logger)
        {
            
            let response = try self.sendCommandSync(command: .getDataKey(token))
            let keyData = try self.grabKVKey(response: response)
            
            EnsemblerSession.logger.debug("Reconstructing sealed box from keydata")
            let reconstructedBox = try AES.GCM.SealedBox(combined: keyData)
            EnsemblerSession.logger.debug("Successfully constructed the box from the keydata")
            return reconstructedBox
        }
    }

    /// Async-Friendly(TM) call to distribute a key
    public func getDataKey(token: SingleUseKeyToken, tracingContext: EnsembleTracingContext? = nil) async throws -> AES.GCM.SealedBox {
        EnsemblerSession.logger.debug("Getting Data key")
        
        let spanID = generateSpanId()
       var summary = GetDatakeySummary(token: token.uuidString, requestID: tracingContext?.requestID.uuidString, spanID: spanID, parentSpanID: tracingContext?.spanID.hexEncoded)
               
        return try await summary.loggingRequestSummary(logger: EnsemblerSession.logger) {
            let response = try await self.sendCommandAsync(command: .getDataKey(token))
            let keyData = try self.grabKVKey(response: response)
            
            EnsemblerSession.logger.debug("Reconstructing sealed box from keydata")
            let reconstructedBox = try AES.GCM.SealedBox(combined: keyData)
            EnsemblerSession.logger.debug("Successfully constructed the box from the keydata")
            return reconstructedBox
        }
    }
    
    // TODO: To remove it after TIE switched to using the other interface
    
    /// Assumption: getDataKey will be called  on leader as well followers
    /// when getDataKey  called ensembled will return the key in memory, and will delete the key in
    /// memory
    /// Blocking call to distribute a key
    /// - Returns: `Data
    @available(*, deprecated, message: "use getDataKey with Tracingcontext")
    public func getDataKey(token: SingleUseKeyToken) throws -> AES.GCM.SealedBox {
        EnsemblerSession.logger.debug("Getting Data key")

        let response = try sendCommandSync(command: .getDataKey(token))
        let keyData = try self.grabKVKey(response: response)
        
        EnsemblerSession.logger.debug("Reconstructing sealed box from keydata")
        let reconstructedBox = try AES.GCM.SealedBox(combined: keyData)
        EnsemblerSession.logger.debug("Successfully constructed the box from the keydata")
        return reconstructedBox
    }

    /// Async-Friendly(TM) call to distribute a key
    @available(*, deprecated, message: "use getDataKey with Tracingcontext")
    public func getDataKey(token: SingleUseKeyToken) async throws -> AES.GCM.SealedBox {
        EnsemblerSession.logger.debug("Getting Data key")
        let response = try await sendCommandAsync(command: .getDataKey(token))
        let keyData = try self.grabKVKey(response: response)
        
        EnsemblerSession.logger.debug("Reconstructing sealed box from keydata")
        let reconstructedBox = try AES.GCM.SealedBox(combined: keyData)
        EnsemblerSession.logger.debug("Successfully constructed the box from the keydata")
        return reconstructedBox
    }
    

	/// Assumption: getDataKey will be called  on leader as well followers
	/// when getDataKey  called ensembled will return the key in memory, and will delete the key in
	/// memory
	/// Blocking call to distribute a key
	/// - Returns: `Data
	public func getDataKey(token: SingleUseKeyToken) throws -> SymmetricKey {
		EnsemblerSession.logger.debug("Getting Data key")

		let response = try sendCommandSync(command: .getDataKey(token))
		let keyData = try self.grabKVKey(response: response)
        
		return SymmetricKey(data: keyData)
	}

	/// Async-Friendly(TM) call to distribute a key
	public func getDataKey(token: SingleUseKeyToken) async throws -> SymmetricKey {
		EnsemblerSession.logger.debug("Getting Data key")
		let response = try await sendCommandAsync(command: .getDataKey(token))
		let keyData = try self.grabKVKey(response: response)
		return SymmetricKey(data: keyData)
	}

	/// Blocking call to get NWProtocolTLS.Options
	/// - Returns: `NWProtocolTLS.Options`- An object that contains security options to use for TLS
	/// handshakes.
	public func getTlsOptions() throws -> NWProtocolTLS.Options {
		EnsemblerSession.logger.debug("Requesting sec options")
		// we need authStr string to get authcode back from ensembled ( using the shared key),
		// Because we rely on this on all the nodes, we need to have hardcoded string. ( unless, we come
		// up with other protocol to distributed this string).
		// The authcode we get will be eventually used to get the NWProtocolTLS.Options
		let authStr = "ensembled"
		guard let data = authStr.data(using: .utf8) else {
			throw EnsembleError.commandFailure(
				error: "Error converting to Data"
			)
		}
		let authCode = try getAuthCode(data: data)
		let options = try getTlsOptions(authStr: authStr, authCode: authCode)
		return options
	}

	/// Async-Friendly(TM) call to get NWProtocolTLS.Options
	/// - Returns: `NWProtocolTLS.Options`- An object that contains security options to use for TLS
	/// handshakes.
	public func getTlsOptions() async throws -> NWProtocolTLS.Options {
		EnsemblerSession.logger.debug("Requesting sec options")
		let authStr = "ensembled"
		guard let data = authStr.data(using: .utf8) else {
			throw EnsembleError.commandFailure(
				error: "Error converting to Data"
			)
		}
		let authCode = try await getAuthCode(data: data)
		let options = try getTlsOptions(authStr: authStr, authCode: authCode)
		return options
	}

	private func getCloudAttestationDeviceFilter(filter: @escaping EnsembleDeviceFilter)
		-> EnsembleValidator.DeviceFilter {
		let deviceFilter: EnsembleValidator
			.DeviceFilter = { (deviceIdentifier: DeviceIdentifiers?) in
				guard let deviceID = deviceIdentifier else {
					// error
					return false
				}
				if filter(deviceID.udid) {
					EnsemblerSession.logger
						.info("EnsembleDeviceFilter callback allowed the UDID: \(deviceID.udid, privacy: .public)")
					return true
				} else {
					// reject the request
					EnsemblerSession.logger
						.warning("EnsembleDeviceFilter callback rejected the UDID: \(deviceID.udid, privacy: .public)")
					return false
				}
			}
		return deviceFilter
	}

	private func getTlsOptionsBackedByCloudAttestationInternal(
		deviceFilter: @escaping EnsembleValidator
			.DeviceFilter
	) throws -> NWProtocolTLS.Options? {
		do {
			var options: NWProtocolTLS.Options?            
			let dispatchGroup = DispatchGroup()
			dispatchGroup.enter()
			Task {
				defer {
					dispatchGroup.leave()
				}
 
                options = try await getTlsOptionsBackedByCloudAttestationInternal(deviceFilter: deviceFilter)
			}
			let result = dispatchGroup.wait(timeout: .now() + 5)

			switch result {
			case .success:
				EnsemblerSession.logger.info("optionsFactory.createTLSOptions returned successufully.")
			case .timedOut:
				EnsemblerSession.logger.error("Timed out waiting for optionsFactory.createTLSOptions")
			}

			guard let options else {
				throw EnsembleError.commandFailure(
					error: "Error getting TLS options"
				)
			}
			return options
		} catch {
			EnsemblerSession.logger.error("Error in getting tlsoptions: \(error, privacy: .public)")
		}

		return nil
	}

	private func getTlsOptionsBackedByCloudAttestationInternal(
		deviceFilter: @escaping EnsembleValidator
			.DeviceFilter
	) async throws -> NWProtocolTLS.Options? {
		let validator = try EnsembleValidator(deviceFilter)

        // If the caller donot want to incur the latency involved with creating attestation
        // they should call createAttesattion first.
        if configurator == nil {
            try await createAttestation()
        }
        
        guard configurator != nil else {
            EnsemblerSession.logger.error("configurator is not initialized")
            throw EnsembleError.commandFailure(
                error: "configurator is not initialized"
            )
        }
        
        EnsemblerSession.logger.info("Calling configurator.createTLSOptions()")
        return try await configurator?.createTLSOptions(with: validator)
	}

	/// Blocking call to get NWProtocolTLS.Options backed by CloudAttestation
	/// - Returns: `NWProtocolTLS.Options`- An object that contains security options to use for TLS
	/// handshakes.
	public func getTlsOptionsBackedByCloudAttestation(filter: @escaping EnsembleDeviceFilter) throws
		-> NWProtocolTLS.Options {
		EnsemblerSession.logger.debug("Requesting tls options backed by cloudattestation")

		let deviceFilter = self.getCloudAttestationDeviceFilter(filter: filter)
		guard let options = try getTlsOptionsBackedByCloudAttestationInternal(deviceFilter: deviceFilter)
		else {
			throw EnsembleError.commandFailure(
				error: "Error getting TLS options backed by CloudAttestation"
			)
		}

		return options
	}

	/// Async-Friendly(TM) call to get NWProtocolTLS.Options backed by CloudAttestation
	/// - Returns: `NWProtocolTLS.Options`- An object that contains security options to use for TLS
	/// handshakes.
	public func getTlsOptionsBackedByCloudAttestation(
		filter: @escaping EnsembleDeviceFilter
	) async throws
		-> NWProtocolTLS.Options {
		EnsemblerSession.logger.debug("Requesting tls options backed by cloudattestation asynchronously")

		let deviceFilter = self.getCloudAttestationDeviceFilter(filter: filter)
		guard let options =
			try await getTlsOptionsBackedByCloudAttestationInternal(deviceFilter: deviceFilter) else {
			throw EnsembleError.commandFailure(
				error: "Error getting TLS options backed by CloudAttestation"
			)
		}

		return options
	}

	/// Blocking call to get NWProtocolTLS.Options backed by CloudAttestation and refresh method that
	/// can be called to refresh the attestation
	/// - Returns: `NWProtocolTLS.Options`- An object that contains security options to use for TLS
	/// handshake
	///           `refreshAttestation` - the closure method that can be called when attestation need to
	/// be refreshed.
    ///     Deprecated API, it will be removed when the callers stop calling it.
	public func getTlsOptionsBackedByCloudAttestationEx(filter: @escaping EnsembleDeviceFilter) throws
    -> (options: NWProtocolTLS.Options, refresh: refreshAttestation) {
		EnsemblerSession.logger.debug("Requesting tls options backed by cloudattestation")

		let deviceFilter = self.getCloudAttestationDeviceFilter(filter: filter)
		let refreshableOptions =
			try getTlsOptionsBackedByCloudAttestationInternal(deviceFilter: deviceFilter)
		guard let options = refreshableOptions else {
			throw EnsembleError.commandFailure(
				error: "Error getting TLS options backed by CloudAttestation"
			)
		}

		let refresh: refreshAttestation = {
            EnsemblerSession.logger.debug("Stub method for refreshing attestation")
		}
		return (options, refresh)
	}

	/// Async-Friendly(TM) call to get NWProtocolTLS.Options backed by CloudAttestation, and refresh
	/// method that can be called to refresh the attestation
	/// - Returns: `NWProtocolTLS.Options`- An object that contains security options to use for TLS
	/// handshake
	///           `refreshAttestation` - the closure method that can be called when attestation need to
	/// be refreshed.
	///
    /// Deprecated API, it will be removed when the callers stop calling it.
	public func getTlsOptionsBackedByCloudAttestationEx(
		filter: @escaping EnsembleDeviceFilter
	) async throws
		-> (options: NWProtocolTLS.Options, refresh: refreshAttestation) {
		EnsemblerSession.logger.debug("Requesting tls options backed by cloudattestation asynchronously")

		let deviceFilter = self.getCloudAttestationDeviceFilter(filter: filter)
		let refreshableOptions =
			try await getTlsOptionsBackedByCloudAttestationInternal(deviceFilter: deviceFilter)
		guard let options = refreshableOptions else {
			throw EnsembleError.commandFailure(
				error: "Error getting TLS options backed by CloudAttestation"
			)
		}

		let refresh: refreshAttestation = {
            EnsemblerSession.logger.debug("Stub method for refreshing attestation")
		}
		return (options, refresh)
	}

    /// Blocking call to create attesatation
    public func createAttestation(attestationExpiryInHrs: Int = 8) throws {
        // create the configurator
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        Task {
            defer {
                dispatchGroup.leave()
            }
            
            if configurator == nil {
                configurator = try await AttestedTLS.Configurator(
                    with: EnsembleAttestor(),
                    lifetime: .seconds(attestationExpiryInHrs * 60 * 60)
                )
            }
        }
        let result = dispatchGroup.wait(timeout: .now() + 5)

        switch result {
        case .success:
            EnsemblerSession.logger.info("AttestedTLS.Configurator created successfully.")
        case .timedOut:
            EnsemblerSession.logger.error("Timed out waiting for AttestedTLS.Configurator creation")
            throw EnsembleError.createAttestationFailed
        }
    }
    
    /// Async-Friendly  call to create attesation
    public func createAttestation(attestationExpiryInHrs: Int = 8) async throws {
        if configurator == nil {
            configurator = try await AttestedTLS.Configurator(
                with: EnsembleAttestor(),
                lifetime: .seconds(attestationExpiryInHrs * 60 * 60)
            )
        }
    }
    
    /// Blocking call to refresh attesatation
    public func refreshAttestation(attestationExpiryInHrs: Int = 8) throws {
        guard configurator != nil else {
            EnsemblerSession.logger.error("configurator is not initialized, make sure to call creatAttestation first")
            throw EnsembleError.commandFailure(
                error: "configurator is not initialized, make sure to call creatAttestation first"
            )
        }
        
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        Task {
            defer {
                dispatchGroup.leave()
            }
            
            try await configurator?.refresh()
        }
        let result = dispatchGroup.wait(timeout: .now() + 5)

        switch result {
        case .success:
            EnsemblerSession.logger.info("Attestation refreshed successfully.")
        case .timedOut:
            EnsemblerSession.logger.error("Timed out waiting for Attestation refresh")
            throw EnsembleError.refreshAttestationFailed
        }
    }
    
    /// Asynch friendly call to refresh attesatation
    public func refreshAttestation(attestationExpiryInHrs: Int = 8) async throws {
        guard configurator != nil else {
            EnsemblerSession.logger.error("configurator is not initialized, make sure to call creatAttestation first")
            throw EnsembleError.commandFailure(
                error: "configurator is not initialized, make sure to call creatAttestation first"
            )
        }
        
        try await configurator?.refresh()
    }
    
	/// Blocking call to receive a list of peers in the ensemble (not including self)
	/// - Returns: List of peers if any exist or `nil`
	/// - Note: We assume that no peers is a legal state so no error is thrown
	public func getPeerInfo() throws -> [EnsembleNodeInfo]? {
		EnsemblerSession.logger.debug("Request peer node info")
		let response = try sendCommandSync(command: .getNodeMap)
		return try self.grabPeers(response: response)
	}

	/// Async-Friendly(TM)  call to receive a list of peers in the ensemble (not including self)
	/// - Returns: List of peers if any exist or `nil`
	/// - Note: We assume that no peers is a legal state so no error is thrown
	public func getPeerInfo() async throws -> [EnsembleNodeInfo]? {
		EnsemblerSession.logger.debug("Request peer node info asynchronously")
		let response = try await sendCommandAsync(command: .getNodeMap)
		return try self.grabPeers(response: response)
	}

	/// Blocking call to receive node information for the ensemble leader
	/// - Returns: `EnsembleNodeInfo` including information for leader node or throws an error if it
	/// cannot be provided
	public func getLeaderInfo() throws -> EnsembleNodeInfo {
		EnsemblerSession.logger.debug("Requesting ensemble leader information")
		let response = try sendCommandSync(command: .getNodeMap)
		return try self.grabLeader(response: response)
	}

	/// Async-Friendly(TM) call to receive node information for the ensemble leader
	/// - Returns: `EnsembleNodeInfo` including information for leader node or throws an error if it
	/// cannot be provided
	public func getLeaderInfo() async throws -> EnsembleNodeInfo {
		EnsemblerSession.logger.debug("Requesting ensemble leader information asynchronously")
		let response = try await sendCommandAsync(command: .getNodeMap)
		return try self.grabLeader(response: response)
	}

	/// Blocking call to receive maxBuffersPerKey
	/// - Returns: `maxBuffersPerKey
	public func getMaxBuffersPerKey() throws -> UInt64 {
		EnsemblerSession.logger.debug("Getting max buffers per key")
		let response = try sendCommandSync(command: .getMaxBuffersPerKey)
		guard let maxBuffersPerKey = response.maxBuffersPerKey else {
			throw EnsembleError.commandFailure(
				error: "Error getting max buffers per key."
			)
		}
		return maxBuffersPerKey
	}

	/// Async-Friendly(TM) call to receive maxBuffersPerKey
	/// - Returns: maxBuffersPerKey
	public func getMaxBuffersPerKey() async throws -> UInt64 {
		EnsemblerSession.logger.debug("Getting max buffers per key asynchronously")
		let response = try await sendCommandAsync(command: .getMaxBuffersPerKey)
		guard let maxBuffersPerKey = response.maxBuffersPerKey else {
			throw EnsembleError.commandFailure(
				error: "Error getting max buffers per key."
			)
		}
		return maxBuffersPerKey
	}

	/// Blocking call to receive maxSecsPerKey
	/// - Returns: `maxSecsPerKey
	public func getMaxSecsPerKey() throws -> UInt64 {
		EnsemblerSession.logger.debug("Getting max seconds per key")
		let response = try sendCommandSync(command: .getMaxSecsPerKey)
		guard let maxSecsPerKey = response.maxSecsPerKey else {
			throw EnsembleError.commandFailure(
				error: "Error getting max seconds per key."
			)
		}
		return maxSecsPerKey
	}

	/// Async-Friendly(TM) call to receive maxSecsPerKey
	/// - Returns: maxSecsPerKey
	public func getMaxSecsPerKey() async throws -> UInt64 {
		EnsemblerSession.logger.debug("Getting max seconds per key asynchronously")
		let response = try await sendCommandAsync(command: .getMaxSecsPerKey)
		guard let maxSecsPerKey = response.maxSecsPerKey else {
			throw EnsembleError.commandFailure(
				error: "Error getting max seconds per key."
			)
		}
		return maxSecsPerKey
	}

	/// Blocking call boolean check if the current node is the ensemble leader
	/// - Returns: `true` if leader, throws `EnsembleError` if we cannot make the determination
	public func isLeader() throws -> Bool {
		EnsemblerSession.logger.debug("Checking if we're the leader")
		let response = try sendCommandSync(command: .getNodeMap)
		let node = try grabSelf(response: response)
		return node.leader
	}

	/// Async-Friendly(TM)  call boolean check if the current node is the ensemble leader
	/// - Returns: `true` if leader, throws `EnsembleError` if we cannot make the determination
	public func isLeader() async throws -> Bool {
		EnsemblerSession.logger.debug("Checking if we're the leader")
		let response = try await sendCommandAsync(command: .getNodeMap)
		let node = try grabSelf(response: response)
		return node.leader
	}

	/// Blocking call to get the ensemble's health state
	public func getHealth() throws -> EnsembleHealth {
		EnsemblerSession.logger.debug("Prompting ensembled to get health")
		let response = try sendCommandSync(command: EnsemblerRequest.getHealth)
		try self.validateResponse(response: response)
		guard let health = response.health else {
			return EnsembleHealth(
				healthState: HealthState.initializing,
				internalState: EnsemblerStatus.uninitialized
			)
		}
		return health
	}

	/// Async-Friendly(TM) call to get the ensemble's health state
	public func getHealth() async throws -> EnsembleHealth {
		EnsemblerSession.logger.debug("Prompting ensembled to get health asynchronously")
		let response = try await sendCommandAsync(command: EnsemblerRequest.getHealth)
		try self.validateResponse(response: response)
		guard let health = response.health else {
			return EnsembleHealth(
				healthState: HealthState.initializing,
				internalState: EnsemblerStatus.uninitialized
			)
		}
		return health
	}

	/// Blocking call to get cable diagnostics for a failed ensemble
	public func getCableDiagnostics() throws -> [String] {
		EnsemblerSession.logger.debug("Prompting ensembled to get cable diagnostics")
		let response = try sendCommandSync(command: EnsemblerRequest.getCableDiagnostics)
		try self.validateResponse(response: response)
		guard let diags = response.cableDiagnostics else {
			throw EnsembleError.commandFailure(
				error: "No cable diagnostics were returned. That's all I know."
			)
		}
		return diags
	}

	/// Async-Friendly(TM) call to get cable diagnostics for a failed ensemble
	public func getCableDiagnostics() async throws -> [String] {
		EnsemblerSession.logger.debug("Prompting ensembled to get cable diagnostics asynchronously")
		let response = try await sendCommandAsync(command: EnsemblerRequest.getCableDiagnostics)
		try self.validateResponse(response: response)
		guard let diags = response.cableDiagnostics else {
			throw EnsembleError.commandFailure(
				error: "No cable diagnostics were returned. That's all I know."
			)
		}
		return diags
	}

	/// Blocking call to get authentication code
	private func getAuthCode(data: Data) throws -> Data {
		EnsemblerSession.logger.debug("Getting authentication code")
		let response = try sendCommandSync(command: EnsemblerRequest.getAuthCode(data))
		try self.validateResponse(response: response)
		guard let authCode = response.authCode else {
			throw EnsembleError.commandFailure(
				error: "No authcode returned."
			)
		}
		return authCode
	}

	/// Async-Friendly(TM) call to get authentication code
	private func getAuthCode(data: Data) async throws -> Data {
		EnsemblerSession.logger.debug("Getting authentication code async")
		let response = try await sendCommandAsync(command: EnsemblerRequest.getAuthCode(data))
		try self.validateResponse(response: response)
		guard let authCode = response.authCode else {
			throw EnsembleError.commandFailure(
				error: "No authcode returned."
			)
		}
		return authCode
	}

	/// Blocking call to rotate shared key
	public func rotateSharedKey() throws -> Bool {
		EnsemblerSession.logger.debug("Rotating shared key ")
		let response = try sendCommandSync(command: EnsemblerRequest.rotateSharedKey)
		return response.result
	}

	/// Async-Friendly(TM) call to rotate shared key
	public func rotateSharedKey() async throws -> Bool {
		EnsemblerSession.logger.debug("Rotating shared key")
		let response = try await sendCommandAsync(command: EnsemblerRequest.rotateSharedKey)
		return response.result
	}

	/// Blocking call to get ensemble ID
	public func getEnsembleID() throws -> String? {
		EnsemblerSession.logger.debug("Requesting ensemble ID")
		let response = try sendCommandSync(command: EnsemblerRequest.getEnsembleID)
		try self.validateResponse(response: response)
		return response.ensembleID
	}

	/// Async-Friendly call to get ensemble ID
	public func getEnsembleID() async throws -> String? {
		EnsemblerSession.logger.debug("Requesting ensemble ID asynchronously")
		let response = try await sendCommandAsync(command: EnsemblerRequest.getEnsembleID)
		try self.validateResponse(response: response)
		return response.ensembleID
	}
    
    /// Blocking call to get rack  ID
    public func getRackID() throws -> String? {
        EnsemblerSession.logger.debug("Requesting rack ID")
        let response = try sendCommandSync(command: EnsemblerRequest.getRackID)
        try self.validateResponse(response: response)
        return response.rackID
    }

    /// Async-Friendly call to get rack ID
    public func getRackID() async throws -> String? {
        EnsemblerSession.logger.debug("Requesting rack ID asynchronously")
        let response = try await sendCommandAsync(command: EnsemblerRequest.getRackID)
        try self.validateResponse(response: response)
        return response.rackID
    }

	/// Register a callback to handle incoming data messages for a specific app ID
	/// - Parameters:
	///   - appID: The application identifier for routing messages
	///   - callback: The callback function to handle incoming data and return a response
	///   - Note: For a node to receive data from other node, lets say for follower-1 to receive data from app1 on leader or any other node
    ///    follower-1 will have to invoke this with app1, and callback which will be triggered when it receives data.
	/// Atomically validates no existing registration for appID, stores the callback in the
	/// local registry, and returns the generated callbackID for use in the XPC command.
	/// Throws if a callback is already registered for the given appID in this session.
	private func prepareCallbackRegistration(
		appID: String,
		callback: @escaping EnsembleDataMessageReceived
	) throws -> String {
		let callbackID = UUID().uuidString
		let alreadyRegistered = callbackStateLock.withLock { state -> Bool in
			guard state.appIDToCallbackIDs[appID] == nil else { return true }
			state.registry[callbackID] = callback
			state.appIDToCallbackIDs[appID] = callbackID
			return false
		}
		guard !alreadyRegistered else {
			EnsemblerSession.logger.error("Callback already registered for appID: \(appID, privacy: .public)")
			throw EnsembleError.commandFailure(error: "Callback already registered for appID: \(appID)")
		}
		return callbackID
	}

	public func registerDataCallback(appID: String, callback: @escaping EnsembleDataMessageReceived) throws {
        EnsemblerSession.logger.info("Registering data message handler for appID: \(appID, privacy: .public) synchronously")
		let callbackID = try prepareCallbackRegistration(appID: appID, callback: callback)
		let response = try sendCommandSync(command: EnsemblerRequest.registerDataCallback(appID, callbackID))
        EnsemblerSession.logger.debug("Registered the callback successfully for  appID: \(appID, privacy: .public), callbackID: \(callbackID,  privacy: .public)")
		try self.validateResponse(response: response)
	}

	/// Async version of registerDataCallback
	/// - Parameters:
	///   - appID: The application identifier for routing messages
	///   - callback: The callback function to handle incoming data and return a response
	public func registerDataCallback(appID: String, callback: @escaping EnsembleDataMessageReceived) async throws {
        EnsemblerSession.logger.info("Registering data message handler for appID: \(appID, privacy: .public) asynchronously")
		let callbackID = try prepareCallbackRegistration(appID: appID, callback: callback)
		let response = try await sendCommandAsync(command: EnsemblerRequest.registerDataCallback(appID, callbackID))
        EnsemblerSession.logger.debug("Registered the callback successfully for  appID: \(appID, privacy: .public), callbackID: \(callbackID,  privacy: .public)")
		try self.validateResponse(response: response)
	}

	/// Atomically validates no existing registration for appID, stores the async callback in the
	/// local async registry, and returns the generated callbackID for use in the XPC command.
	/// Throws if a callback is already registered for the given appID in this session.
	private func prepareAsyncCallbackRegistration(
		appID: String,
		callback: @escaping EnsembleDataMessageReceivedAsync
	) throws -> String {
		let callbackID = UUID().uuidString
		let alreadyRegistered = callbackStateLock.withLock { state -> Bool in
			guard state.appIDToCallbackIDs[appID] == nil else { return true }
			state.asyncRegistry[callbackID] = callback
			state.appIDToCallbackIDs[appID] = callbackID
			return false
		}
		guard !alreadyRegistered else {
			EnsemblerSession.logger.error("Callback already registered for appID: \(appID, privacy: .public)")
			throw EnsembleError.commandFailure(error: "Callback already registered for appID: \(appID)")
		}
		return callbackID
	}

	/// Registers an async data message callback. Each invocation runs as an independent
	/// Swift Task — use this instead of EnsembleDataMessageReceived to avoid GCD thread
	/// exhaustion under concurrent load.
	public func registerDataCallback(appID: String, callback: @escaping EnsembleDataMessageReceivedAsync) throws {
		EnsemblerSession.logger.info("Registering async data message handler for appID: \(appID, privacy: .public) synchronously")
		let callbackID = try prepareAsyncCallbackRegistration(appID: appID, callback: callback)
		let response = try sendCommandSync(command: EnsemblerRequest.registerDataCallback(appID, callbackID))
		EnsemblerSession.logger.debug("Registered async callback successfully for appID: \(appID, privacy: .public), callbackID: \(callbackID, privacy: .public)")
		try self.validateResponse(response: response)
	}

	/// Async version of registerDataCallback with async callback.
	public func registerDataCallback(appID: String, callback: @escaping EnsembleDataMessageReceivedAsync) async throws {
		EnsemblerSession.logger.info("Registering async data message handler for appID: \(appID, privacy: .public) asynchronously")
		let callbackID = try prepareAsyncCallbackRegistration(appID: appID, callback: callback)
		let response = try await sendCommandAsync(command: EnsemblerRequest.registerDataCallback(appID, callbackID))
		EnsemblerSession.logger.debug("Registered async callback successfully for appID: \(appID, privacy: .public), callbackID: \(callbackID, privacy: .public)")
		try self.validateResponse(response: response)
	}
    
	/// Atomically validates that a callback is registered for appID, removes it from the
	/// local registry, and returns its callbackID for use in the XPC command.
	/// Throws if no callback is registered for the given appID in this session.
	private func prepareCallbackUnregistration(appID: String) throws -> String {
		guard let callbackID = callbackStateLock.withLock({ state -> String? in
			guard let id = state.appIDToCallbackIDs[appID] else { return nil }
			state.registry.removeValue(forKey: id)
			state.asyncRegistry.removeValue(forKey: id)
			state.appIDToCallbackIDs.removeValue(forKey: appID)
			return id
		}) else {
			EnsemblerSession.logger.error("No callback registered for appID: \(appID, privacy: .public)")
			throw EnsembleError.commandFailure(error: "No callback registered for appID: \(appID)")
		}
		return callbackID
	}

    /// Unregister a data callback by its app ID
    /// - Parameter appID: The application identifier used when registering the callback
    public func unregisterDataCallback(appID: String) throws {
        EnsemblerSession.logger.info("Unregistering data message handler for appID: \(appID, privacy: .public) synchronously")
        let callbackID = try prepareCallbackUnregistration(appID: appID)
        EnsemblerSession.logger.debug("Calling EnsemblerRequest.unregisterDataCallback for \(callbackID)")
        let response = try sendCommandSync(command: EnsemblerRequest.unregisterDataCallback(callbackID))
        EnsemblerSession.logger.debug("Unregistered the callback successfully for \(appID) with \(callbackID)")
        try self.validateResponse(response: response)
    }

    /// Async version of unregisterDataCallback
    /// - Parameter appID: The application identifier used when registering the callback
    public func unregisterDataCallback(appID: String) async throws {
        EnsemblerSession.logger.info("Unregistering data message handler for appID: \(appID, privacy: .public) asynchronously")
        let callbackID = try prepareCallbackUnregistration(appID: appID)
        EnsemblerSession.logger.debug("Calling EnsemblerRequest.unregisterDataCallback for \(callbackID)")
        let response = try await sendCommandAsync(command: EnsemblerRequest.unregisterDataCallback(callbackID))
        EnsemblerSession.logger.debug("Unregistered the callback successfully for \(appID) with \(callbackID)")
		try self.validateResponse(response: response)
	}
    
	/// Send data to a specific destination and wait for a response
	/// - Parameters:
	///   - appID: The application identifier for routing the message
	///   - data: The data to send
	///   - destination: The rank of the destination node
	///   - timeout: Timeout for waiting for a response (default: 2.0 seconds)
	/// - Returns: The response data from the destination node
	public func sendDataAndGetResponse(appID: String, data: Data, destination: Int, timeout: TimeInterval = 2.0) throws -> Data {
        EnsemblerSession.logger.debug("Sending data to destination: \(destination, privacy: .public), appID: \(appID, privacy: .public)")
		let response = try sendCommandSync(command: EnsemblerRequest.sendDataAndGetResponse(appID, data, destination, timeout))
		try self.validateDataMessageResponse(response: response)
		
		guard let responseData = response.responseData else {
			EnsemblerSession.logger.error("No response data received")
			throw EnsembleError.commandFailure(error: "No response data received")
		}
        
		return responseData
	}

	/// Async version of sendDataAndGetResponse
	/// - Parameters:
	///   - appID: The application identifier for routing the message
	///   - data: The data to send
	///   - destination: The rank of the destination node
	///   - timeout: Timeout for waiting for a response (default: 2.0 seconds)
	/// - Returns: The response data from the destination node
	public func sendDataAndGetResponse(appID: String, data: Data, destination: Int, timeout: TimeInterval = 2.0) async throws -> Data {
        EnsemblerSession.logger.debug("Sending data to destination: \(destination, privacy: .public), appID: \(appID, privacy: .public) asynchronously")
		let response = try await sendCommandAsyncGuarded(command: EnsemblerRequest.sendDataAndGetResponse(appID, data, destination, timeout))
		try self.validateDataMessageResponse(response: response)

		guard let responseData = response.responseData else {
			EnsemblerSession.logger.error("No response data received")
			throw EnsembleError.commandFailure(error: "No response data received")
		}
		
		return responseData
	}
    
    /// Send data to a specific follower destination and wait for a response, with TracingContext
    /// - Parameters:
    ///   - appID: The application identifier for routing the message
    ///   - data: The data to send
    ///   - destination: The follower rank of the destination node
    ///   - timeout: Timeout for waiting for a response (default: 2.0 seconds)
    /// - Returns: The response data from the destination node
    public func sendDataToFollowerNode(appID: String, data: Data, destination: Int,
                                       timeout: TimeInterval = 2.0,
                                       tracingContext: EnsembleTracingContext? = nil) throws -> Data {
        guard let tracingContext else {
            return try sendDataAndGetResponse(appID: appID, data: data, destination: destination, timeout: timeout)
        }

        EnsemblerSession.logger.debug("Sending data to destination: \(destination, privacy: .public), appID: \(appID, privacy: .public)")

        let spanID = generateSpanId()
        let summary = DistributeDataSummary(requestID: tracingContext.requestID.uuidString, spanID: spanID, parentSpanID: tracingContext.spanID.hexEncoded, operationName: "Sending data to a node")

        return try summary.loggingRequestSummary(logger: EnsemblerSession.logger) {
            let response = try self.sendCommandSync(command: EnsemblerRequest.sendDataAndGetResponse(appID, data, destination, timeout))
            try self.validateDataMessageResponse(response: response)

            guard let responseData = response.responseData else {
                EnsemblerSession.logger.error("No response data received")
                throw EnsembleError.commandFailure(error: "No response data received")
            }

            return responseData
        }
    }

    /// Async version of sendDataToNode with TracingContext
    /// - Parameters:
    ///   - appID: The application identifier for routing the message
    ///   - data: The data to send
    ///   - destination: The rank of the destination node
    ///   - timeout: Timeout for waiting for a response (default: 2.0 seconds)
    /// - Returns: The response data from the destination node
    public func sendDataToFollowerNode(appID: String, data: Data, destination: Int,
                                       timeout: TimeInterval = 2.0,
                                       tracingContext: EnsembleTracingContext? = nil) async throws -> Data {
        guard let tracingContext else {
            return try await sendDataAndGetResponse(appID: appID, data: data, destination: destination, timeout: timeout)
        }

        EnsemblerSession.logger.debug("Sending data to destination: \(destination, privacy: .public), appID: \(appID, privacy: .public) asynchronously")

        let spanID = generateSpanId()
        let summary = DistributeDataSummary(requestID: tracingContext.requestID.uuidString, spanID: spanID, parentSpanID: tracingContext.spanID.hexEncoded, operationName: "Sending data to a node")

        return try await summary.loggingRequestSummary(logger: EnsemblerSession.logger) {
            let response = try await self.sendCommandAsyncGuarded(command: EnsemblerRequest.sendDataAndGetResponse(appID, data, destination, timeout))
            try self.validateDataMessageResponse(response: response)

            guard let responseData = response.responseData else {
                EnsemblerSession.logger.error("No response data received")
                throw EnsembleError.commandFailure(error: "No response data received")
            }

            return responseData
        }
    }

	/// Send data to all followers and wait for responses (leader only)
	/// - Parameters:
	///   - appID: The application identifier for routing the message
	///   - data: The data to send
	///   - timeout: Timeout for waiting for responses (default: 2.0 seconds)
	/// - Returns: Array of NodeResponse objects containing responses from all followers
	public func sendDataToAllFollowers(appID: String, data: Data, timeout: TimeInterval = 2.0) throws -> [NodeResponse] {
        EnsemblerSession.logger.debug("Broadcasting data to all followers, appID: \(appID, privacy: .public)")
		let response = try sendCommandSync(command: EnsemblerRequest.sendDataToAllFollowers(appID, data, timeout))
		try self.validateDataMessageResponse(response: response)
		
		guard let allFollowersResponseData = response.allFollowersResponseData else {
			EnsemblerSession.logger.error("No response data received from followers")
			throw EnsembleError.commandFailure(error: "No response data received from followers")
		}
		
		return allFollowersResponseData
	}
	
	/// Async version of sendDataToAllFollowers
	/// - Parameters:
	///   - appID: The application identifier for routing the message
	///   - data: The data to send
	///   - timeout: Timeout for waiting for responses (default: 2.0 seconds)
	/// - Returns: Array of NodeResponse objects containing responses from all followers
	public func sendDataToAllFollowers(appID: String, data: Data, timeout: TimeInterval = 2.0) async throws -> [NodeResponse] {
        EnsemblerSession.logger.debug("Broadcasting data to all followers asynchronously, appID: \(appID, privacy: .public)")
		let response = try await sendCommandAsyncGuarded(command: EnsemblerRequest.sendDataToAllFollowers(appID, data, timeout))
		try self.validateDataMessageResponse(response: response)
		
		guard let allFollowersResponseData = response.allFollowersResponseData else {
			EnsemblerSession.logger.error("No response data received from followers")
			throw EnsembleError.commandFailure(error: "No response data received from followers")
		}
		
		return allFollowersResponseData
	}
    
    /// Send data to all followers and wait for responses (leader only) with TracingContext
    /// - Parameters:
    ///   - appID: The application identifier for routing the message
    ///   - data: The data to send
    ///   - timeout: Timeout for waiting for responses (default: 2.0 seconds)
    /// - Returns: Array of NodeResponse objects containing responses from all followers
    public func sendDataToAllFollowers(appID: String, data: Data,
                                       timeout: TimeInterval = 2.0,
                                       tracingContext: EnsembleTracingContext? = nil) throws -> [NodeResponse] {
        EnsemblerSession.logger.debug("Broadcasting data to all followers, appID: \(appID, privacy: .public)")
        let spanID = generateSpanId()
        let summary = DistributeDataSummary(requestID: tracingContext?.requestID.uuidString, spanID: spanID, parentSpanID: tracingContext?.spanID.hexEncoded, operationName: "Distributing data to all followers")
        
        return try summary.loggingRequestSummary(logger: EnsemblerSession.logger) {
            let response = try self.sendCommandSync(command: EnsemblerRequest.sendDataToAllFollowers(appID, data, timeout))
            try self.validateDataMessageResponse(response: response)

            guard let allFollowersResponseData = response.allFollowersResponseData else {
                EnsemblerSession.logger.error("No response data received from followers")
                throw EnsembleError.commandFailure(error: "No response data received from followers")
            }

            return allFollowersResponseData
        }

    }

    /// Async version of sendDataToAllFollowers with TracingContext
    /// - Parameters:
    ///   - appID: The application identifier for routing the message
    ///   - data: The data to send
    ///   - timeout: Timeout for waiting for responses (default: 2.0 seconds)
    /// - Returns: Array of NodeResponse objects containing responses from all followers
    public func sendDataToAllFollowers(appID: String, data: Data,
                                       timeout: TimeInterval = 2.0,
                                       tracingContext: EnsembleTracingContext? = nil) async throws -> [NodeResponse] {
        
        EnsemblerSession.logger.debug("Broadcasting data to all followers asynchronously, appID: \(appID, privacy: .public)")
        let spanID = generateSpanId()
        let summary = DistributeDataSummary(requestID: tracingContext?.requestID.uuidString, spanID: spanID, parentSpanID: tracingContext?.spanID.hexEncoded, operationName: "Distributing data to all followers")
        
        return try await summary.loggingRequestSummary(logger: EnsemblerSession.logger) {
            let response = try await self.sendCommandAsyncGuarded(command: EnsemblerRequest.sendDataToAllFollowers(appID, data, timeout))
            try self.validateDataMessageResponse(response: response)

            guard let allFollowersResponseData = response.allFollowersResponseData else {
                EnsemblerSession.logger.error("No response data received from followers")
                throw EnsembleError.commandFailure(error: "No response data received from followers")
            }

            return allFollowersResponseData
        }
    }

	// MARK: - SPIs for the CLI

	/// Blocking call to activate ensemble and receive result on this node
	///  - NOTE: This is typically a NOOP
	@_spi(Debug)
	public func activate() throws -> Bool {
		EnsemblerSession.logger.debug("Activating ensemble")
		let response = try sendCommandSync(command: EnsemblerRequest.activate)
		return response.result
	}

	/// Async-Friendly(TM) call to activate ensemble on this node
	///  - NOTE: This is typically a NOOP
	@_spi(Debug)
	public func activate() async throws -> Bool {
		EnsemblerSession.logger.debug("Activating ensemble asynchronously")
		let response = try await sendCommandAsync(command: EnsemblerRequest.activate)
		return response.result
	}

	/// Blocking call to encrypt plain text data
	@_spi(Debug)
	public func encryptData(data: Data) throws -> Data? {
		EnsemblerSession.logger.debug("Encrypting plain text data ")
		let response = try sendCommandSync(command: EnsemblerRequest.encryptData(data))
		return response.encrypted
	}

	/// Async-Friendly(TM) call to encrypt plain text data
	@_spi(Debug)
	public func encryptData(data: Data) async throws -> Data? {
		EnsemblerSession.logger.debug("Encrypting plain text data ")
		let response = try await sendCommandAsync(command: EnsemblerRequest.encryptData(data))
		return response.encrypted
	}

	/// Blocking call to decrypt  text data
	@_spi(Debug)
	public func decryptData(data: Data) throws -> Data? {
		EnsemblerSession.logger.debug("Decrypting data ")
		let response = try sendCommandSync(command: EnsemblerRequest.decryptData(data))
		return response.decrypted
	}

	/// Async-Friendly(TM) call to decrypt  text data
	@_spi(Debug)
	public func decryptData(data: Data) async throws -> Data? {
		EnsemblerSession.logger.debug("Decrypting data ")
		let response = try await sendCommandAsync(command: EnsemblerRequest.decryptData(data))
		return response.decrypted
	}

	/// Blocking call to prompt ensembled to reload its configuration
	///  - NOTE: This should typically only be needed in debug scenarios
	@_spi(Debug)
	public func reloadConfiguration() throws -> Bool {
		EnsemblerSession.logger.debug("Prompting ensembled to reload ensemble configuration")
		let response = try sendCommandSync(command: EnsemblerRequest.reloadConfiguration)
		return response.result
	}

	/// Async-Friendly(TM) call to prompt ensembled to reload its configuration
	///  - NOTE: This should only be needed for debug scenarios
	@_spi(Debug)
	public func reloadConfiguration() async throws -> Bool {
		EnsemblerSession.logger
			.debug("Prompting ensembled to reload ensemble configuration asynchronously")
		let response = try await sendCommandAsync(command: EnsemblerRequest.reloadConfiguration)
		return response.result
	}

	/// Blocking call to prompt ensembled to send a test message to a given node
	///  - Parameter destination: The destination node by rank
	@_spi(Debug)
	public func sendTestMessage(destination: Int) throws -> Bool {
		EnsemblerSession.logger
			.debug("Prompting ensembled to send a test message to \(destination)")
		let response = try sendCommandSync(command: EnsemblerRequest.sendTestMessage(destination))
		return response.result
	}

	/// Async-Friendly(TM) call to prompt ensembled to send a test message to a given node
	///  - Parameter destination: The destination node by rank
	@_spi(Debug)
	public func sendTestMessage(destination: Int) async throws -> Bool {
		EnsemblerSession.logger
			.debug("Prompting ensembled to send a test message to \(destination) asynchronously")
		let response = try await sendCommandAsync(
			command: EnsemblerRequest
				.sendTestMessage(destination)
		)
		return response.result
	}
}

// MARK: - Private XPC Methods

extension EnsemblerSession {
	private func sendCommandSync(command: EnsemblerRequest) throws -> EnsemblerResponse {
        guard let session = self.session else {
            EnsemblerSession.logger.error("No xpc session exists")
            throw EnsembleError.internalError(error: "No xpc session exists")
        }
		let reply = try session.sendSync(command)
		return try reply.decode(as: EnsemblerResponse.self)
	}

	private func sendCommandAsync(command: EnsemblerRequest) async throws -> EnsemblerResponse {
        guard let session = self.session else {
            EnsemblerSession.logger.error("No xpc session exists")
            throw EnsembleError.internalError(error: "No xpc session exists")
        }

		let reply = try await withCheckedThrowingContinuation { continuation in
			do {
				try session.send(command, replyHandler: continuation.resume(with:))
			} catch {
				continuation.resume(throwing: error)
			}
		}

		return try reply.decode(as: EnsemblerResponse.self)
	}

	// rdar://172856722 — guarded variant of sendCommandAsync, used only by
	// sendDataToFollowerNode, sendDataAndGetResponse, and sendDataToAllFollowers. When N concurrent Tasks share one EnsemblerSession,
	// XPCSession.cancel() races with the real reply and can fire the replyHandler
	// twice on the same CheckedContinuation → _assertionFailure → SIGTRAP.
	// The gate ensures only the first delivery resumes the continuation; the second
	// is silently dropped. pendingSendsGroup tracks each send so deinit defers
	// session.cancel() until all in-flight reply handlers have fired.
	// sendCommandAsync is unchanged so all other callers are unaffected.
	private func sendCommandAsyncGuarded(command: EnsemblerRequest) async throws -> EnsemblerResponse {
		guard let session = self.session else {
			EnsemblerSession.logger.error("No xpc session exists")
			throw EnsembleError.internalError(error: "No xpc session exists")
		}

		let group = self.pendingSendsGroup
		group.enter()

		let reply = try await withCheckedThrowingContinuation { continuation in
			let gate = OSAllocatedUnfairLock(initialState: false)

			func resumeOnce(_ body: () -> Void) {
				let shouldFire = gate.withLock { fired -> Bool in
                    guard !fired else {
                        EnsemblerSession.logger.warning("sendCommandAsyncGuarded: Double resume gated.")
                        return false
                    }
					fired = true
					return true
				}
				if shouldFire {
					body()
					group.leave()
				}
			}

			do {
				try session.send(command, replyHandler: { result in
					resumeOnce { continuation.resume(with: result) }
				})
			} catch {
				resumeOnce { continuation.resume(throwing: error) }
			}
		}

		return try reply.decode(as: EnsemblerResponse.self)
	}

	// create a utility function to encode strings as preshared key data.
	private func stringToDispatchData(_ string: String) -> DispatchData? {
		guard let stringData = string.data(using: .utf8) else {
			return nil
		}
		let dispatchData = stringData.withUnsafeBytes {
			DispatchData(bytes: $0)
		}
		return dispatchData
	}

	private func getTlsOptions(authStr: String, authCode: Data) throws -> NWProtocolTLS.Options {
		let tlsOptions = NWProtocolTLS.Options()

		let authenticationData = authCode.withUnsafeBytes {
			DispatchData(bytes: $0)
		}

		guard let data = stringToDispatchData(authStr) else {
			throw EnsembleError.commandFailure(
				error: "Error converting to dispatch data."
			)
		}
		sec_protocol_options_add_pre_shared_key(
			tlsOptions.securityProtocolOptions,
			authenticationData as __DispatchData,
			data as __DispatchData
		)

		// Replace this with actual value from security framework when it is available
		// rdar://134442920
		let TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256: UInt16 = 0xCCAC

		EnsemblerSession.logger.log("Using TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 cipher suite")

		guard let tlsCipher = tls_ciphersuite_t(rawValue: TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256)
		else {
			throw EnsembleError.commandFailure(
				error: "Error creating tls ciphersuite."
			)
		}

		sec_protocol_options_append_tls_ciphersuite(
			tlsOptions.securityProtocolOptions,
			tlsCipher
		)
		return tlsOptions
	}
}
