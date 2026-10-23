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
//  Client.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 11/8/24.
//

import Foundation
import Network
import OSLog
import Security_Private
import Security_Private.SecCertificateRequest
import Security_Private.SecIdentityPriv
@_spi(Daemon) import AppleComputeEnsembler

private let logger = Logger(subsystem: kEnsemblerPrefix, category: "TLSChannelClient")

public enum ClientError: Error {
	case ClientError(message: String)
}

extension ClientError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .ClientError(let message):
			return message
		}
	}
}

// MARK: - Client Protocol

/// Protocol defining the public interface for TLS client connections
public protocol Client: AnyObject {
	/// Current connection state
	var state: NWConnection.State { get }
	
	/// The target node rank this client connects to
	var target: Int { get }

	/// Start the client connection
	func start()
	
	/// Stop the client connection
	func stop()

	/// Permanently cancel the client connection, preventing any further retry attempts
	func cancel()
	
	/// Send a message without waiting for acknowledgment (fire and forget)
	/// - Parameter message: The control data to send
	func send(message: EnsembleControlData)
	
	/// Send a message and wait for acknowledgment
	/// - Parameters:
	///   - message: The control data to send
	///   - maxRetries: Maximum number of retry attempts
	func sendAndWaitForAck(message: EnsembleControlData, maxRetries: Int)
	
	/// Send a message and wait for a response
	/// - Parameters:
	///   - appID: Application identifier for routing
	///   - data: The data to send
	///   - currentNode: The rank of the current node
	///   - timeout: Timeout interval (default: 2.0 seconds)
	///   - completion: Completion handler with Result containing response data or error
	func sendAndWaitForResponse(
		appID: String,
		data: Data,
		currentNode: Int,
		timeout: TimeInterval,
		completion: @escaping (Result<Data, Error>) -> Void
	)
}

// MARK: - Client Protocol Extension

extension Client {
	/// Convenience method for sendAndWaitForAck with default retry count of 1000
	/// - Parameters:
	///   - message: The control data to send
	func sendAndWaitForAck(message: EnsembleControlData) {
		self.sendAndWaitForAck(message: message, maxRetries: 1000)
	}
}

// MARK: - ClientImpl

// Leader and follower node can boot up at different time
// For example leader can come up first and the followed by followers
// leader can come up after followers. when a followers boot first, and then connect
// to leader, we need to retry when the connection fails.
// we will try up to 20 minutes, and if we can not connect, there is something else
// going on. At 30 minute time interval, fleet management will find the ensemble
// is in failure state and reboot the nodes.

public class ClientImpl: Client {
	internal var connection: NWConnection?
	private var retryAttempts = 0
	private let readySemaphore = DispatchSemaphore(value: 0)

	private let isCancelledLock = OSAllocatedUnfairLock(initialState: false)
	private var isCancelled: Bool {
		get { isCancelledLock.withLock { $0 } }
		set(value) { isCancelledLock.withLock { $0 = value } }
	}
	// we will try to reconnect every 2 seconds for up to 20 minutes
	private let maxRetryAttempts = kEnsemblerTimeout /
		kDefaultRetryInterval // we will retry up for 600*2 = 1200 seconds = 20 minutes
	let host: NWEndpoint.Host
	let port: NWEndpoint.Port
	public var state: NWConnection.State
	let tlsOptions: NWProtocolTLS.Options
	public let target: Int
	let delegate: ClientConnectionDelegate

    // Per-client queue for NWConnection callbacks. Replaces the global tlsOutboundQ so
    // concurrent responses from different followers are delivered in parallel rather than
    // serialising through one shared serial queue.
    private let connectionQueue: DispatchQueue
    
    let startReceiveLoopOnConnect: Bool
    
    // Variables to parse incoming responses and call appropriate completion callback.
    var pendingCompletion: [String: (Result<Data, Error>) -> Void] = [:]
    var pendingTimeouts: [String: DispatchWorkItem] = [:]
    // Tracks the appID for each in-flight request so timeout errors can name the app.
    var pendingAppIDs: [String: String] = [:]
    let pendingCompletionLock = DispatchQueue(label: "com.apple.cloudos.applecomputensembler.recievemsg.lock")
    let parsingQueue = DispatchQueue(label: "com.apple.cloudos.applecomputensembler.parser")
    var recieveBuffer = Data()

	init(
		host: String,
		port: UInt16,
		tlsOptions: NWProtocolTLS.Options,
		node: Int,
		delegate: ClientConnectionDelegate,
        startReceiveLoopOnConnect: Bool,
	) {
		self.host = NWEndpoint.Host(host)
		self.port = NWEndpoint.Port(rawValue: port)!
		self.tlsOptions = tlsOptions
        self.state = .setup
		self.target = node
		self.delegate = delegate
        self.connectionQueue = DispatchQueue(
            label: "\(kEnsemblerPrefix).conn.queue.\(node)",
            qos: .userInteractive
        )
        self.startReceiveLoopOnConnect = startReceiveLoopOnConnect
	}

	private func stateDidChange(to newState: NWConnection.State) {
		self.state = newState
		switch newState {
		case .ready:
			self.retryAttempts = 0 // Reset retry count on successful connection
			self.readySemaphore.signal()
			logger
				.info(
					"client connection to rank: \(self.target, privacy: .public) hostname:\(self.host.debugDescription, privacy: .public):\(self.port.rawValue, privacy: .public)  ready"
				)
			self.delegate.onClientConnectionChange(node: self.target, state: self.state)
			if startReceiveLoopOnConnect {
				logger.info("ClientImpl: restarting receive loop after connect to rank \(self.target, privacy: .public)")
				self.startReceiveLoop()
			}
		case .waiting(let error):
			logger
				.warning(
					"client connection to rank:\(self.target, privacy: .public) hostname:\(self.host.debugDescription, privacy: .public):\(self.port.rawValue) waiting, error: \(error, privacy: .public)"
				)
			// recommendation from network team is that we should treat .waiting as such, the network stack
			// is waiting for
			// the condition to change to establish connection, so we should not consider it as failure
			// however i observed when denali is active, once it goes to waiting state it does not go into
			// ready or failure state
			// as well but when denalis not active, as condition changes, it eventually goes to ready state.
			self.retryConnection()
		case .failed(let error):
			logger
				.error(
					"client connection to rank:\(self.target, privacy: .public) hostname:\(self.host.debugDescription, privacy: .public):\(self.port.rawValue, privacy: .public) failed with error: \(error, privacy: .public)"
				)
			self.delegate.onClientConnectionChange(node: self.target, state: self.state)
			self.retryConnection()
		default:
            logger
                .info(
                    "client connection to rank:\(self.target, privacy: .public) hostname:\(self.host.debugDescription, privacy: .public):\(self.port.rawValue, privacy: .public), state: \(String(describing: self.state), privacy: .public)  "
                )
			break
		}
	}

	private func attemptConnection() {
		guard !isCancelled else { return }
		let tcpOptions = NWProtocolTCP.Options()
		// enable TCP keep-alive feature
		tcpOptions.enableKeepalive = true
		// override default keepaliveidle seconds, so we can detect any network disruptions.
		tcpOptions.keepaliveIdle = 2
		tcpOptions.noDelay = true

		// Create parameters with custom TLS and TCP options.
		let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
		parameters.allowFastOpen = true

		self.connection = NWConnection(host: self.host, port: self.port, using: parameters)

		logger
			.info(
				"client connection to rank:\(self.target, privacy: .public) Attempt: \(self.retryAttempts, privacy: .public) client connection to  rank:\(self.target, privacy: .public) \(self.host.debugDescription, privacy: .public):\(self.port.rawValue, privacy: .public)"
			)
		self.connection?.stateUpdateHandler = self.stateDidChange
		self.connection?.start(queue: connectionQueue)
	}

	func retryConnection(retryAfter: TimeInterval = TimeInterval(kDefaultRetryInterval)) {
		guard !isCancelled else { return }
		self.stop()
		guard self.retryAttempts < self.maxRetryAttempts else {
			logger.warning("Max retry attempts reached. Giving up.")
			logger
				.error(
					"client connection to rank:\(self.target, privacy: .public) \(self.host.debugDescription, privacy: .public):\(self.port.rawValue, privacy: .public) could not be started"
				)
			self.delegate.onClientConnectionFailure(node: self.target)
			return
		}

		self.retryAttempts += 1

		logger
			.info(
				"client connection to rank:\(self.target, privacy: .public) retrying in \(retryAfter) seconds - (attempt \(self.retryAttempts, privacy: .public) of \(self.maxRetryAttempts, privacy: .public))"
			)
		DispatchQueue.global(qos: .userInitiated)
			.asyncAfter(deadline: .now() + retryAfter) { [weak self] in
				guard let self = self else {
					logger.error("Client deallocated during retry delay - connection attempt abandoned")
					return
				}
				self.attemptConnection()
			}
	}

	public func start() {
		logger
			.info(
				"client connection to rank:\(self.target, privacy: .public) hostname:\(self.host.debugDescription, privacy: .public):\(self.port.rawValue, privacy: .public)starting the connection."
			)
		self.attemptConnection()
	}

	public func stop() {
		logger
			.info(
				"client connection to rank:\(self.target, privacy: .public) hostname:\(self.host.debugDescription, privacy: .public):\(self.port.rawValue, privacy: .public) stopping the connection."
			)
		self.connection?.stateUpdateHandler = nil
		self.connection?.forceCancel()
		self.connection = nil
	}

	public func cancel() {
		isCancelled = true
		self.connection?.stateUpdateHandler = nil
		self.connection?.forceCancel()
		self.connection = nil
		readySemaphore.signal()
	}

	// send without waiting for any ack ( send and foreget )
	public func send(message: EnsembleControlData) {
		do {
			let encoder = JSONEncoder()
			let data = try encoder.encode(message)
			var lengthPrefix = UInt32(data.count).bigEndian
			let lengthData = Data(bytes: &lengthPrefix, count: 4)

			var messageData = Data()
			messageData.append(lengthData)
			messageData.append(data)

			self.connection?.send(content: messageData, completion: .contentProcessed { error in
				if let error {
					logger.error("client connection to rank:\(self.target, privacy: .public) failed to send data: \(error, privacy: .public)")
					self.delegate.sendCallback(node: self.target, message: message.data, error: error)
				} else {
					self.delegate.sendCallback(node: self.target, message: message.data, error: nil)
				}
			})
		} catch {
			logger.error("client connection to rank:\(self.target, privacy: .public) failed to send data: \(error, privacy: .public)")
		}
	}

	private func waitForConnectionReady() -> Bool {
		if self.state == .ready {
			logger.debug("State is ready. Dont need to wait")
			return true
		}

		let overallDeadline = DispatchTime.now() + .seconds(kEnsemblerTimeout)
		while true {
			_ = readySemaphore.wait(timeout: .now() + .seconds(1))
			if self.state == .ready {
				logger.debug("State is ready. Proceeding with action.")
				return true
			}
			if isCancelled {
				logger.info("waitForConnectionReady: client cancelled, returning false immediately")
				return false
			}
			if DispatchTime.now() >= overallDeadline {
				logger.error("Timeout of \(kEnsemblerTimeout, privacy: .public) expired. State is not ready.")
				return false
			}
			// Either stale signal or 1s wait expired — loop and wait again
		}
	}
    
	private func attemptSend(messageData: Data, controlData: Data, attempts: Int, maxRetries: Int) {
		logger.debug("Client.attemptSend: Attempt \(attempts, privacy: .public) to send message")

		// wait for connection to be ready before attempting to send.
		// In good case scenario, connection will be established in the start,
		// and unless network connection is lost or crash on the other node happens
		// connection will be in ready state.
		// In order to increase resiliency, its good to expect network connection loss
		// or the other node crashing.
		guard self.waitForConnectionReady() else {
			let error = ClientError
				.ClientError(
					message: "Cannot send data, since connection to \(self.target) is not in ready state."
				)
			self.delegate.sendCallback(node: self.target, message: controlData, error: error)
			return
		}

		if attempts >= maxRetries {
			logger.error("Client.attemptSend: Reached max retry \(maxRetries, privacy: .public) attempts")
			let error = ClientError
				.ClientError(message: "Attempted maximum \(maxRetries) attempts to send message and failed.")
			self.delegate.sendCallback(node: self.target, message: controlData, error: error)
			return
		}

		self.connection?.send(content: messageData, completion: .contentProcessed { error in
			// we got some error sending message.
			if let error {
				logger.warning("Client.attemptSend: error sending message: \(error, privacy: .public)")
				logger.debug("Client.attemptSend Retrying: \(attempts + 1, privacy: .public)...")
				// we need to retry in matter of milliseconds, because we are involved in
				// hot path when TIE calls for distributing data key,
				// so for any failure in sending message,we need to retry in milliseconds.
				let timeDelay: DispatchTimeInterval = .milliseconds(10)
				EnsemblerTLS.fromBackendQ.asyncAfter(deadline: .now() + timeDelay) { [weak self] in
					guard let self = self else {
						logger.warning("Client deallocated during send retry delay - message send abandoned")
						return
					}
					self.attemptSend(
						messageData: messageData,
						controlData: controlData,
						attempts: attempts + 1,
						maxRetries: maxRetries
					)
				}

				return
			} else {
				self.receiveAcknowledgment { success in
					if success {
						self.delegate.sendCallback(node: self.target, message: controlData, error: nil)
						return
					} else {
						logger.warning("Client.attemptSend: Did not receive proper acknowledgment")
						// Retry logic
						logger.debug("Client.attemptSend Retrying: \(attempts + 1, privacy: .public)...")
						let timeDelay: DispatchTimeInterval = .milliseconds(10)
						EnsemblerTLS.fromBackendQ.asyncAfter(deadline: .now() + timeDelay) { [weak self] in
							guard let self = self else {
								logger.warning("Client deallocated during acknowledgment retry delay - message send abandoned")
								return
							}
							self.attemptSend(
								messageData: messageData,
								controlData: controlData,
								attempts: attempts + 1,
								maxRetries: maxRetries
							)
						}
					}
				}
			}
		})
	}
    
    private func receiveAcknowledgment(completion: @escaping (Bool) -> Void) {
        
        // Now read the actual message data
        self.connection?.receive(minimumIncompleteLength: 0, maximumLength: 4096) { messageData, _, _, messageError in
            DispatchQueue.global(qos: .userInitiated).async {
                
                if let messageError {
                    logger.error("Client.receiveAcknowledgment: Error receiving message data: \(messageError, privacy: .public)")
                    completion(false)
                    return
                }
                
                guard let messageData = messageData else {
                    logger.error("Client.receiveFramedResponse: Received incomplete message data")
                    completion(false)
                    return
                }
                
                // Now decode the actual control message
                do {
                    let controlMsg = try EnsembleControlMessage.decode(from: messageData)
                    switch controlMsg {
                    case .acknowledge:
                        completion(true)
                        return
                    default:
                        logger.warning("Client.receiveAcknowledgment: Got a different message other than acknowledge: \(controlMsg)")
                        completion(false)
                    }
                } catch {
                    logger.warning("Client.receiveAcknowledgment: Control message decoding failed: \(error, privacy: .public)")
                    completion(false)
                }
            }
        }
    }
    
    // send message and wait for acknowledge message from the server
    public func sendAndWaitForAck(message: EnsembleControlData, maxRetries: Int = 1000) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(message)
            var lengthPrefix = UInt32(data.count).bigEndian
            let lengthData = Data(bytes: &lengthPrefix, count: 4)

            var messageData = Data()
            messageData.append(lengthData)
            messageData.append(data)

            self.attemptSend(
                messageData: messageData,
                controlData: message.data,
                attempts: 0,
                maxRetries: maxRetries
            )
        } catch {
            logger.error("sendAndWaitForAck: error sending message \(error, privacy: .public)")
        }
    }
    
}

public func getClient(
	server: String,
	port: UInt16,
	node: Int,
	delegate: ClientConnectionDelegate,
    startReceiveLoopOnConnect: Bool = false
) throws -> Client {
	// get the tls options with appropriate options set.
	let tlsOptions = getTlsOptions()

	// set the self signed cert
	let secIdentity = try getSecIdentity()
	sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)

	let client = ClientImpl(
		host: server,
		port: port,
		tlsOptions: tlsOptions,
		node: node,
		delegate: delegate,
        startReceiveLoopOnConnect: startReceiveLoopOnConnect
	)

	return client
}
