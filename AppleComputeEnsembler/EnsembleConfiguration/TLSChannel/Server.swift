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
//  Server.swift
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

private let logger = Logger(subsystem: kEnsemblerPrefix, category: "TLSChannelServer")

public enum ServerError: Error {
	case ServerError(mesage: String)
}

public struct EnsembleControlData: Codable {
	var rank: Int
	var data: Data
}

class ServerConnection {
	// The TCP maximum package size is 64K 65536
	let MTU = 65536
	private static var nextID: Int = 0
	let connection: NWConnection
	let id: Int
	let delegate: ServerConnectionDelegate
	var didStopCallback: ((Error?) -> Void)?
	let node: Int
	let receiveQueue = DispatchQueue(label: "com.apple.receiveQueue", qos: .userInteractive)

	init(nwConnection: NWConnection, delegate: ServerConnectionDelegate, node: Int) {
		self.connection = nwConnection
		self.id = ServerConnection.nextID
		ServerConnection.nextID += 1
		self.delegate = delegate
		self.node = node
	}

	func start() {
		logger
			.info("ServerConnection.start on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) will start")
		self.connection.stateUpdateHandler = self.stateDidChange(to:)
		self.setupReceiveLength()
		self.connection.start(queue: tlsInboundConnQ)
	}

	private func stateDidChange(to state: NWConnection.State) {
		switch state {
		case .waiting(let error):
			logger
				.warning(
					"ServerConnection.stateDidChange on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) waiting, error:\(error, privacy: .public)"
				)
		case .ready:
			logger
				.info(
					"ServerConnection.stateDidChange on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) ready"
				)
		case .failed(let error):
			logger
				.error(
					"ServerConnection.stateDidChange on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) failed with error \(error, privacy: .public)"
				)
			self.connectionDidFail(error: error)
		case .preparing:
			logger
				.info(
					"ServerConnection.stateDidChange on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) preparing"
				)
		case .cancelled:
			logger
				.info(
					"ServerConnection.stateDidChange on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) cancelled"
				)
		case .setup:
			logger
				.info(
					"ServerConnection.stateDidChange on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) setup"
				)
		default:
			logger
				.info(
					"ServerConnection.stateDidChange on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) unknown state"
				)
		}
	}

	private func setupReceiveLength() {
		self.receiveQueue.async {
			self.connection
				.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, _ in
					logger.info(
						"""
						ServerConnection.setupReceiveLength on rank \(
							self.node, privacy: .public
						): server Length Message received on \(self.node, privacy: .public)
						on connection id \(self.id, privacy: .public) size: \(data?.count.description)"
						"""
					)

					guard let data else { return }
					let lengthPrefix = data.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
					self.setupReceiveMessage(length: Int(lengthPrefix))
				}
		}
	}

	private func setupReceiveMessage(length: Int) {
		logger.info(
			"""
			ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): Received a message
			"""
		)

		self.receiveQueue.async {
			self.connection
				.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in

                    let dataSize = data?.count ?? 0
					logger.info(
                        """
                        ServerConnection.setupReceiveMessage on  rank \(self.node, privacy: .public): Received a message
                        on connection id \(self.id, privacy: .public) size: \(
                            dataSize,
                            privacy: .public
                        )"
                        """
					)

					if let data, !data.isEmpty {
						let jsonData = data

						let decoder = JSONDecoder()
						do {
							let decodedData = try decoder.decode(EnsembleControlData.self, from: jsonData)

							logger.info(
								"""
								ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): Received a messagefrom rank \(
									decodedData.rank,
									privacy: .public
								)
								calling delegate.incomingMessage to notify the registrar"
								"""
							)


							let responseData = self.delegate.incomingMessage(node: decodedData.rank, message: decodedData.data)

                            
							// Send response data if provided, otherwise send acknowledgment
							if let responseData = responseData {
                                logger.info(
                                    """
                                    ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): sending response to rank \(decodedData.rank, privacy: .public) of size \(responseData.count)
                                    """
                                )
                                self.sendResponse(data: responseData)
							} else {
								self.sendAck(messageData: decodedData.data)
                                logger.info(
                                    """
                                    ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): sending Ack to rank \(decodedData.rank, privacy: .public)
                                    """
                                )
							}
						} catch {
							logger.info(
								"""
								ServerConnection.setupReceiveMessage on rank \(
									self
										.node, privacy: .public
								): errored when recieving a messagefrom rank \(
									self.node,
									privacy: .public
								)
								"""
							)
						}
					}
					if isComplete {
						logger
							.info(
								"ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): server receive complete, ending connection"
							)
						self.connectionDidEnd()
					} else if let error {
						self.connectionDidFail(error: error)
					} else {
						self.setupReceiveLength()
					}
				}
		}
	}
    
	func sendAck(messageData _: Data) {
		let ackMessage: EnsembleControlMessage = .acknowledge
		let msgData: Data
		do {
			msgData = try JSONEncoder().encode(ackMessage)
            self.connection.send(content: msgData, completion: .contentProcessed { error in
                if let error {
                    self.connectionDidFail(error: error)
                    return
                }
                logger
                    .info(
                        "ServerConnection.sendAck on rank \(self.node, privacy: .public):  server connection \(self.id, privacy: .public) did send, data: \(msgData as NSData, privacy: .private)"
                    )
            })
		} catch {
			EnsemblerTLS.logger.error(
				"""
				Server.sendAck() on rank \(self.node, privacy: .public):
				Failed to encode message \(String(describing: ackMessage), privacy: .public) \
				: \(String(reportableError: error), privacy: .public)
				"""
			)
		}
	}

	func sendResponse(data: Data) {
		// Send with proper length prefix framing to match client expectations
		var lengthPrefix = UInt32(data.count).bigEndian
		let lengthData = Data(bytes: &lengthPrefix, count: 4)

		var messageData = Data()
		messageData.append(lengthData)
		messageData.append(data)
		
		logger.info(
			"ServerConnection.sendResponse on rank \(self.node, privacy: .public): sending \(data.count) bytes with 4-byte length prefix (total: \(messageData.count) bytes)"
		)
		
		self.connection.send(content: messageData, completion: .contentProcessed { error in
			if let error {
				self.connectionDidFail(error: error)
				return
			}
			logger
				.info(
					"ServerConnection.sendResponse on rank \(self.node, privacy: .public):  server connection \(self.id, privacy: .public) did send, data: \(data as NSData, privacy: .private)"
				)
		})
	}

	func stop() {
		logger.info("ServerConnection.stop on rank \(self.node, privacy: .public):  server connection \(self.id, privacy: .public) will stop")
		if self.connection.state != .cancelled {
			self.stop(error: nil)
		}
	}

	private func connectionDidFail(error: Error) {
		logger
			.info(
				"ServerConnection.connectionDidFail on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) did fail, error: \(error, privacy: .public)"
			)
		self.stop(error: error)
	}

	private func connectionDidEnd() {
		logger
			.info(
				"ServerConnection.connectionDidEnd on rank \(self.node, privacy: .public): server connection  server connection \(self.id, privacy: .public) did end"
			)
		self.stop(error: nil)
	}

	private func stop(error: Error?) {
		logger
			.info(
				"ServerConnection.stop on rank \(self.node, privacy: .public): server connection  server stopping connection \(self.id, privacy: .public)"
			)

		if self.connection.state != .cancelled {
			self.connection.forceCancel()
		}

		if let didStopCallback {
			self.didStopCallback = nil
			didStopCallback(error)
		}
	}
}

public class Server {
	let port: NWEndpoint.Port
	let listener: NWListener
	var delegate: ServerConnectionDelegate
	let node: Int
	private var connectionsByID: [Int: ServerConnection] = [:]

	init(
		port: UInt16,
		tlsOptions: NWProtocolTLS.Options,
		delegate: ServerConnectionDelegate,
		node: Int
	) throws {
		self.port = NWEndpoint.Port(rawValue: port)!

		let tcpOptions = NWProtocolTCP.Options()
		// enable TCP keep-alive feature
		tcpOptions.enableKeepalive = true
		// override default keepaliveidle seconds, so we can detect any network disruptions.
		tcpOptions.keepaliveIdle = 2


        //Dont wait to buffer, send message when ever it is available.
        tcpOptions.noDelay = true
		// create parameters with custom TLS and TCP options.
		let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
		parameters.allowLocalEndpointReuse = true

		self.listener = try NWListener(using: parameters, on: self.port)
		self.delegate = delegate
		self.node = node
	}

	func start() {
		logger.info("Server.start on rank \(self.node, privacy: .public): server starting...")
		self.listener.stateUpdateHandler = self.stateDidChange(to:)
		self.listener.newConnectionHandler = self.didAccept(nwConnection:)
		// Need a seperate queue to handle serializaion of incoming messages. Otherwise it will cause race
		// conditions
		// and cause issues.
		self.listener.start(queue: tlsInboundQ)
	}

	func stateDidChange(to newState: NWListener.State) {
		self.delegate.onServerStatusChange(state: newState)
		switch newState {
		case .ready:
			logger
				.info("Server.stateDidChange on rank \(self.node, privacy: .public): server ready on port \(self.port.rawValue, privacy: .public).")
		case .failed(let error):
			logger
				.error(
					"Server.stateDidChange on rank \(self.node, privacy: .public):server failure, error: \(error.localizedDescription, privacy: .public)"
				)
		default:
			logger
				.error(
					"Server.stateDidChange on rank \(self.node, privacy: .public): server statechange called with unknown (default) state"
				)
		}
	}

	private func didAccept(nwConnection: NWConnection) {
		let connection = ServerConnection(
			nwConnection: nwConnection,
			delegate: self.delegate,
			node: self.node
		)
		self.connectionsByID[connection.id] = connection
		connection.didStopCallback = { _ in
			self.connectionDidStop(connection)
		}
		connection.start()
		logger.info("Server.didAccept on rank \(self.node, privacy: .public): server did open connection: \(connection.id, privacy: .public)")
	}

	private func connectionDidStop(_ connection: ServerConnection) {
		self.connectionsByID.removeValue(forKey: connection.id)
		logger
			.info(
				"Server.connectionDidStop on rank \(self.node, privacy: .public): server did close connection \(connection.id, privacy: .public)"
			)
	}

	public func stop() {
		self.listener.stateUpdateHandler = nil
		self.listener.newConnectionHandler = nil
		if self.listener.state != .cancelled {
			self.listener.cancel()
		}
		for connection in self.connectionsByID.values {
			connection.didStopCallback = nil
			connection.stop()
		}
		self.connectionsByID.removeAll()
	}
}

public func getServer(
	port: UInt16,
	delegate: ServerConnectionDelegate,
	node: Int
) throws -> Server {
	let tlsOptions = getTlsOptions()
	let secIdentity = try getSecIdentity()
	sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
	return try Server(port: port, tlsOptions: tlsOptions, delegate: delegate, node: node)
}
