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
//  Server.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 11/8/24.
//

@_weakLinked import CloudAttestation
import Foundation
import Network
import os
import OSLog
import Security
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

// The TCP maximum package size is 64K 65536
public let MTU = 65536

class ServerConnection {
	// Validates a length prefix parsed from the wire before it is fed to
	// NWConnection.receive(minimumIncompleteLength:maximumLength:). A length
	// that is non-positive or exceeds the agreed-upon MTU indicates either a
	// corrupt stream or a hostile peer trying to coerce the server into
	// allocating buffers far larger than the protocol permits.
	static func isValidLengthPrefix(_ length: Int) -> Bool {
		return length > 0 && length <= MTU
	}

	private static var nextID: Int = 0
	let connection: NWConnection
	let id: Int
	let delegate: ServerConnectionDelegate
	var didStopCallback: ((Error?) -> Void)?
	let node: Int
	let configuration: EnsembleConfiguration?
	// Written once on tlsInboundConnQ (stateDidChange .ready), read on receiveQueue.
	// Lock ensures cross-queue visibility.
	private let verifiedPeerRankLock = OSAllocatedUnfairLock<Int?>(initialState: nil)
	private var verifiedPeerRank: Int? {
		get { verifiedPeerRankLock.withLock { $0 } }
		set { verifiedPeerRankLock.withLock { $0 = newValue } }
	}
	let receiveQueue = DispatchQueue(label: "com.apple.receiveQueue", qos: .userInteractive)
	// Per-connection queue so TLS handshakes (including EnsembleValidator.DeviceFilter) on
	// concurrent follower reconnections run in parallel rather than serialising through the
	// former shared tlsInboundConnQ. Mirrors the per-client queue pattern in ClientImpl.
	private let connectionQueue: DispatchQueue

	init(nwConnection: NWConnection, delegate: ServerConnectionDelegate, node: Int, configuration: EnsembleConfiguration? = nil) {
		self.connection = nwConnection
		self.id = ServerConnection.nextID
		ServerConnection.nextID += 1
		self.delegate = delegate
		self.node = node
		self.configuration = configuration
		self.connectionQueue = DispatchQueue(
			label: "\(kEnsemblerPrefix).serverconn.queue.\(node).\(self.id)",
			qos: .userInteractive
		)
	}

	func start() {
		logger
			.info("ServerConnection.start on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) will start")
		self.connection.stateUpdateHandler = self.stateDidChange(to:)
		self.setupReceiveLength()
		self.connection.start(queue: self.connectionQueue)
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
			self.verifiedPeerRank = self.resolveVerifiedPeerRank()
			// Rank verification is mandatory when attestation config is present.
			// A nil result means the peer certificate carried no recognisable UDID —
			// falling back to the body-supplied rank would trust an unverified value,
			// so close the connection instead (fail closed).
			if self.configuration != nil, self.verifiedPeerRank == nil {
				logger.error(
					"ServerConnection.stateDidChange on rank \(self.node, privacy: .public): cannot verify peer rank from TLS certificate on connection \(self.id, privacy: .public) — closing connection"
				)
				self.connectionDidFail(error: ServerError.ServerError(mesage: "peer rank not verifiable from TLS certificate"))
			}
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
				.warning(
					"ServerConnection.stateDidChange on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) unknown state"
				)
		}
	}

	// Derive the peer's rank from the TLS peer certificate by reading the CloudAttestation
	// attestation bundle extension (OID 1.2.840.113635.100.6.93). The TLS leaf cert is a
	// self-signed CloudAttestation cert whose extnValue is a DER OctetString wrapping the
	// raw protobuf bytes of an AttestationBundle. We unwrap the OctetString, parse the
	// bundle, and extract the UDID via withUnvalidatedAttestationBundle { $0.udid }.
	// The UDID format matches config.nodes keys (SEP.Identity.udid: "%08X-%016llX").
	// Returns nil in two cases:
	//   • configuration is absent  → no-attestation/test path; caller skips verification.
	//   • UDID not in config nodes → caller treats this as fatal and closes the connection.
	private func resolveVerifiedPeerRank() -> Int? {
		guard let config = self.configuration else { return nil }
		guard let tlsMeta = connection.metadata(definition: NWProtocolTLS.definition)
				as? NWProtocolTLS.Metadata else {
			logger.error(
				"ServerConnection.resolveVerifiedPeerRank on connection \(self.id, privacy: .public): NWProtocolTLS.Metadata unavailable"
			)
			return nil
		}

		var result: Int? = nil
		sec_protocol_metadata_access_peer_certificate_chain(
			tlsMeta.securityProtocolMetadata
		) { secCert in
			guard result == nil else { return }  // leaf cert only

			let cert = sec_certificate_copy_ref(secCert).takeRetainedValue()

			// The extension value returned by SecCertificateCopyExtensionValue is the
			// DER-encoded extnValue field: an OctetString wrapping the raw protobuf bytes.
			let attestationOID = "1.2.840.113635.100.6.93" as CFString
			guard let extData = SecCertificateCopyExtensionValue(cert, attestationOID, nil) as? Data else {
				logger.error(
					"ServerConnection.resolveVerifiedPeerRank on connection \(self.id, privacy: .public): attestation extension (OID 1.2.840.113635.100.6.93) absent from peer certificate"
				)
				return
			}

			guard let protoData = ServerConnection.derOctetStringBytes(from: extData),
				  let bundle = try? AttestationBundle(data: protoData) else {
				logger.error(
					"ServerConnection.resolveVerifiedPeerRank on connection \(self.id, privacy: .public): failed to parse AttestationBundle from peer certificate extension"
				)
				return
			}

			let udid = bundle.withUnvalidatedAttestationBundle { $0.udid }
			guard let udid else {
				logger.error(
					"ServerConnection.resolveVerifiedPeerRank on connection \(self.id, privacy: .public): UDID absent from peer attestation bundle"
				)
				return
			}

			logger.debug(
				"ServerConnection.resolveVerifiedPeerRank on connection \(self.id, privacy: .public): derived UDID \(udid, privacy: .public)"
			)

			guard let nodeConfig = config.nodes[udid] else {
				logger.error(
					"ServerConnection.resolveVerifiedPeerRank on connection \(self.id, privacy: .public): UDID \(udid, privacy: .public) not found in config nodes"
				)
				return
			}

			logger.info(
				"ServerConnection.resolveVerifiedPeerRank on connection \(self.id, privacy: .public): UDID \(udid, privacy: .public) → rank \(nodeConfig.rank, privacy: .public)"
			)
			result = nodeConfig.rank
		}
		return result
	}

	// Unwrap a DER-encoded OctetString (tag 0x04) and return its content bytes.
	// SecCertificateCopyExtensionValue returns the raw DER bytes of the extnValue field,
	// which is an OctetString; this strips the tag+length header to expose the payload.
	private static func derOctetStringBytes(from data: Data) -> Data? {
		var idx = data.startIndex
		guard idx < data.endIndex, data[idx] == 0x04 else { return nil }
		data.formIndex(after: &idx)
		guard idx < data.endIndex else { return nil }
		let firstLengthByte = data[idx]
		data.formIndex(after: &idx)
		let length: Int
		if firstLengthByte & 0x80 == 0 {
			length = Int(firstLengthByte)
		} else {
			let numBytes = Int(firstLengthByte & 0x7F)
			guard data.distance(from: idx, to: data.endIndex) >= numBytes else { return nil }
			var len = 0
			for _ in 0..<numBytes {
				len = (len << 8) | Int(data[idx])
				data.formIndex(after: &idx)
			}
			length = len
		}
		guard data.distance(from: idx, to: data.endIndex) >= length else { return nil }
		return data[idx..<data.index(idx, offsetBy: length)]
	}

	private func setupReceiveLength() {
		self.receiveQueue.async {
			self.connection
				.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, isComplete, error in
					logger.debug(
						"""
						ServerConnection.setupReceiveLength on rank \(
							self.node, privacy: .public
						): server Length Message received on \(self.node, privacy: .public)
						on connection id \(self.id, privacy: .public) size: \(data?.count.description)"
						"""
					)

					if let error {
						logger.error("ServerConnection.setupReceiveLength on rank \(self.node, privacy: .public): receive error on connection \(self.id, privacy: .public): \(error, privacy: .public)")
						self.connectionDidFail(error: error)
						return
					}
					guard let data else {
						if isComplete {
							self.connectionDidEnd()
						} else {
							logger.error("ServerConnection.setupReceiveLength on rank \(self.node, privacy: .public): received nil data with no error on connection \(self.id, privacy: .public)")
						}
						return
					}
					let lengthPrefix = data.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
					let length = Int(lengthPrefix)
					guard ServerConnection.isValidLengthPrefix(length) else {
						logger.error(
							"""
							ServerConnection.setupReceiveLength on rank \(self.node, privacy: .public): \
							length prefix \(length, privacy: .public) on connection \(self.id, privacy: .public) \
							is out of bounds (MTU=\(MTU, privacy: .public)); closing connection
							"""
						)
						self.connectionDidFail(error: ServerError.ServerError(
							mesage: "length prefix \(length) exceeds MTU \(MTU)"
						))
						return
					}
					self.setupReceiveMessage(length: length)
				}
		}
	}

	private func setupReceiveMessage(length: Int) {
		logger.debug(
			"""
			ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): Received a message
			"""
		)

		// Defence in depth: callers are expected to validate, but a misbehaving
		// caller (or a future code path) must never be allowed to ask the
		// transport for a frame larger than the protocol's MTU.
		guard ServerConnection.isValidLengthPrefix(length) else {
			logger.error(
				"""
				ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): \
				refusing to receive message of length \(length, privacy: .public) on connection \
				\(self.id, privacy: .public) (MTU=\(MTU, privacy: .public)); closing connection
				"""
			)
			self.connectionDidFail(error: ServerError.ServerError(
				mesage: "message length \(length) exceeds MTU \(MTU)"
			))
			return
		}

		self.receiveQueue.async {
			self.connection
				.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in

                    let dataSize = data?.count ?? 0
					logger.debug(
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

							logger.debug(
								"""
								ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): Received a messagefrom rank \(
									decodedData.rank,
									privacy: .public
								)
								calling delegate.incomingMessage to notify the registrar"
								"""
							)

							// If TLS peer rank was resolved from the remote host, require it to
							// match the body-supplied rank. A mismatch means a peer is claiming
							// a rank it was not verified for; close the connection immediately.
							if let verifiedRank = self.verifiedPeerRank, decodedData.rank != verifiedRank {
								logger.error(
									"""
									ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): \
									rank mismatch on connection \(self.id, privacy: .public): \
									body rank \(decodedData.rank, privacy: .public) \
									!= TLS-verified rank \(verifiedRank, privacy: .public). Closing connection.
									"""
								)
								self.connectionDidFail(error: ServerError.ServerError(mesage: "rank mismatch"))
								return
							}
							let effectiveRank = self.verifiedPeerRank ?? decodedData.rank

                            self.delegate.incomingMessage(node: effectiveRank, message: decodedData.data) { [weak self] responseData in
                                guard let self else {
                                    logger.error(
                                        "ServerConnection: connection torn down before response could be sent for message from rank \(decodedData.rank, privacy: .public)"
                                    )
                                    return
                                }
                                // Send response data if provided, otherwise send acknowledgment
                                if let responseData = responseData {
                                    // data message always sends back response, either response data or error
                                    logger.debug(
                                    """
                                    ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): sending response to rank \(decodedData.rank, privacy: .public) of size \(responseData.count)
                                    """
                                    )
                                    self.sendResponse(data: responseData)
                                } else {
                                    // control message sends ack — for data messages this indicates a bug
                                    logger.warning(
                                        "ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): responseData was nil for message from rank \(decodedData.rank, privacy: .public) — sending ack (expected for control msgs, unexpected for data msgs)"
                                    )
                                    self.sendAck(messageData: decodedData.data)
                                }
                            }
						} catch {
							logger.error(
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
							.debug(
								"ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public): server receive complete, ending connection"
							)
						self.connectionDidEnd()
					} else if let error {
						self.connectionDidFail(error: error)
					} else {
                        logger.debug(
                            """
                            ServerConnection.setupReceiveMessage on rank \(self.node, privacy: .public):  setting up other receive"
                            """
                        )
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
                    .debug(
                        "ServerConnection.sendAck on rank \(self.node, privacy: .public):  server connection \(self.id, privacy: .public) did send, \(msgData.count, privacy: .public) bytes"
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
		
		logger.debug(
			"ServerConnection.sendResponse on rank \(self.node, privacy: .public): sending \(data.count) bytes with 4-byte length prefix (total: \(messageData.count) bytes)"
		)
		
		self.connection.send(content: messageData, completion: .contentProcessed { error in
			if let error {
				self.connectionDidFail(error: error)
				return
			}
			logger
				.debug(
					"ServerConnection.sendResponse on rank \(self.node, privacy: .public):  server connection \(self.id, privacy: .public) did send, \(data.count, privacy: .public) bytes"
				)
		})
	}

	func stop() {
		logger.debug("ServerConnection.stop on rank \(self.node, privacy: .public):  server connection \(self.id, privacy: .public) will stop")
		if self.connection.state != .cancelled {
			self.stop(error: nil)
		}
	}

	private func connectionDidFail(error: Error) {
		logger
			.error(
				"ServerConnection.connectionDidFail on rank \(self.node, privacy: .public): server connection \(self.id, privacy: .public) did fail, error: \(error, privacy: .public)"
			)
		self.stop(error: error)
	}

	private func connectionDidEnd() {
		logger
			.debug(
				"ServerConnection.connectionDidEnd on rank \(self.node, privacy: .public): server connection  server connection \(self.id, privacy: .public) did end"
			)
		self.stop(error: nil)
	}

	private func stop(error: Error?) {
		logger
			.debug(
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
	let configuration: EnsembleConfiguration?
	// connectionsByID is accessed from both tlsInboundQ (didAccept adds) and each
	// connection's own connectionQueue (connectionDidStop removes), so it needs a lock.
	private let connectionsByID = OSAllocatedUnfairLock(initialState: [Int: ServerConnection]())

	init(
		port: UInt16,
		tlsOptions: NWProtocolTLS.Options,
		delegate: ServerConnectionDelegate,
		node: Int,
		configuration: EnsembleConfiguration? = nil
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
		self.configuration = configuration
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
			node: self.node,
			configuration: self.configuration
		)
		connectionsByID.withLock { $0[connection.id] = connection }
		connection.didStopCallback = { _ in
			self.connectionDidStop(connection)
		}
		connection.start()
		logger.info("Server.didAccept on rank \(self.node, privacy: .public): server did open connection: \(connection.id, privacy: .public)")
	}

	private func connectionDidStop(_ connection: ServerConnection) {
		connectionsByID.withLock { _ = $0.removeValue(forKey: connection.id) }
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
		connectionsByID.withLock { connections in
			for connection in connections.values {
				connection.didStopCallback = nil
				connection.stop()
			}
			connections.removeAll()
		}
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
