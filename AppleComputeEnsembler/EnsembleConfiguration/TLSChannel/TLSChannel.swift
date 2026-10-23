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
//  TLSChannel.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 11/8/24.
//

// we need to weaklink since we wanted to run xctest on skywagon which might not contain the
// symbols.
@_weakLinked import CloudAttestation
import Foundation
import Network
import os
import OSLog
import AppleComputeEnsembler

private let logger = Logger(subsystem: kEnsemblerPrefix, category: "TLSChannel")

private let serverDefaultPort: UInt16 = 4250
// Default expirty in cloudattestation framework is 1 hr. we are setting it to 8 hrs.
// we will do the refresh attestation and reconnect clients to server to pick up
// the refreshed attestation.
// for server connections, just refreshing is enough, since, the new clients handshaking will ensure
// server is handshaking with the refreshed attestation.
private let kDefaultAttestationExpiryInSeconds: Int = 8 * 60 * 60

public protocol ServerConnectionDelegate {
	/// An incoming message from a node. Returns optional response data to send back.
    func incomingMessage(node: Int, message: Data, completion:@escaping (Data?) -> Void)

	func onServerStatusChange(state: NWListener.State)
}

public protocol ClientConnectionDelegate {
	/// callback regarding send status
	func sendCallback(node: Int, message: Data, error: Error?)

	/// callback indicating that connection to target server change
	/// in case of leader, it indicates the connection to all followers change
	/// in case of follower, it indicates the connection to leader change
	func onClientConnectionChange(node: Int, state: NWConnection.State)

	/// callback indicating that client connection could not be established
	/// after retrying maximum attempt.
	func onClientConnectionFailure(node: Int)
}

let tlsInboundQ = DispatchSerialQueue(label: "inboundQ", qos: .userInteractive)

public final class TLSChannel {
	// server listening for inbound messages
	var server: Server?
	// client to leader in case of followers, and clients to followers in case of leader
	var clients: [Int: Client] = [:]

    var clientQueues: [Int: DispatchQueue] = [:]
	// dedicated clients for data messaging (separate from control messaging)
	var dataClients: [Int: Client] = [:]
	var dataClientQueues: [Int: DispatchQueue] = [:]
	// Serialization dispatch groups - one per follower to ensure only one request at a time per follower
	private let dispatchGroups = OSAllocatedUnfairLock(initialState: [Int: DispatchGroup]())
    
	var configuration: EnsembleConfiguration
	let serverDelegate: ServerConnectionDelegate
	let clientDelegate: ClientConnectionDelegate
	let currentNode: NodeConfiguration
	let useNoAttestation: Bool
	var configurator: AttestedTLS.Configurator<EnsembleAttestor>?
	var tlsOptions: NWProtocolTLS.Options?
	init(
        nodeInfo: NodeConfiguration,
        ensembleConfig: EnsembleConfiguration,
		serverDelegate: ServerConnectionDelegate,
		clientDelegate: ClientConnectionDelegate,
		useNoAttestation: Bool = false
	) async throws {
		self.currentNode = nodeInfo
        self.configuration =  ensembleConfig
		self.serverDelegate = serverDelegate
		self.clientDelegate = clientDelegate
		self.useNoAttestation = useNoAttestation
		let port = nodeInfo.port ?? serverDefaultPort
		
		if useNoAttestation == true {
			self.server = try getServer(port: port, delegate: serverDelegate, node: nodeInfo.rank)
		} else {
            self.configurator = try await AttestedTLS.Configurator(
                with: EnsembleAttestor(),
                lifetime: .seconds(kDefaultAttestationExpiryInSeconds)
            )
            self.tlsOptions = try await self.getCloudAttestationTlsOptions(configuration: configuration)
			self.server = try self.getCloudAttestationBackedServer(
				configuration: configuration,
				port: port,
				delegate: serverDelegate,
				node: currentNode.rank
			)
		}
		self.server?.start()

		guard let clients = try self.getClients() else {
			throw EnsembleError.internalError(error: "Error getting client connections")
		}
		self.clients = clients
		
		// Set up dedicated data clients (separate connections for data messaging)
		guard let dataClients = try self.getDataClients() else {
			throw EnsembleError.internalError(error: "Error getting data client connections")
		}
		self.dataClients = dataClients
		
	}
	
	private func getDispatchGroupForNode(_ rank: Int) -> DispatchGroup? {
		dispatchGroups.withLock { groups in
			// Return existing dispatch group or create a new one if needed
			if let existingGroup = groups[rank] {
				return existingGroup
			}
			
			// Create new dispatch group if follower was added after initialization
			let newGroup = DispatchGroup()
			groups[rank] = newGroup
			logger.debug("TLSChannel: Created new serialization dispatch group for follower rank \(rank)")
			return newGroup
		}
	}

	func refreshAttestation() throws {
		let dispatchGroup = DispatchGroup()
		dispatchGroup.enter()
		Task {
			defer {
				dispatchGroup.leave()
			}
			logger.info(
				"TLSChannel.refreshAttestation() on rank \(self.currentNode.rank, privacy: .public): Refreshing attestation"
			)
			try await self.configurator?.refresh()
		}

		dispatchGroup.wait()

		logger.info(
			"TLSChannel.refreshAttestation() on rank \(self.currentNode.rank, privacy: .public): Refreshing attestation completed"
		)
	}

	func reConnectWithClients() throws {
		logger.info(
			"TLSChannel.reConnectWithClients() on rank \(self.currentNode.rank, privacy: .public): Reconnecting with clients"
		)

		for client in self.clients {
			client.value.stop()
		}
		
		for client in self.dataClients {
			client.value.stop()
		}

		try self.refreshAttestation()
		guard let clients = try self.getClients() else {
			throw EnsembleError.internalError(error: "Error getting client connections")
		}
		
		guard let dataClients = try self.getDataClients() else {
			throw EnsembleError.internalError(error: "Error getting data client connections")
		}

		self.clients.removeAll()
		self.clients = clients
		
		self.dataClients.removeAll()
		self.dataClients = dataClients
	}

	func getClients() throws -> [Int: Client]? {
		if self.currentNode.rank == 0 {
			return try self.getClientsForLeader()
		} else {
			return try self.getClientsForFollower()
		}
	}

	func getDataClients() throws -> [Int: Client]? {
		if self.currentNode.rank == 0 {
			return try self.getDataClientsForLeader()
		} else {
			return try self.getDataClientsForFollower()
		}
	}

	func getClientsForLeader() throws -> [Int: Client]? {
		var clients: [Int: Client] = [:]
		var targetPort: UInt16 = serverDefaultPort

		// for leader we need to send message to all clients
		// for follower, we just need to talk to leader
        for node in self.configuration.nodes {
			if node.value.port != nil {
				targetPort = node.value.port!
			}

			guard let hostName = node.value.hostName else {
				throw EnsembleError.internalError(error: "Error getting targets hostname")
			}

			if node.value.rank != 0 {
				// For server lets wait for announce message before we can start client connection to each
				// follower.
				if self.useNoAttestation == true {
					clients[node.value.rank] = try getClient(
						server: hostName,
						port: targetPort,
						node: node.value.rank,
						delegate: self.clientDelegate
					)
				} else {
					clients[node.value.rank] = try self.getCloudAttestationBackedClient(
						configuration: self.configuration,
						server: hostName,
						port: targetPort,
						node: node.value.rank,
						delegate: self.clientDelegate
					)
				}
                let label = "datamessage-queue-\(node.value.rank)"
                clientQueues[node.value.rank] = DispatchQueue(label:label, qos: .userInitiated )
			}
		}

		return clients
	}

	func getClientsForFollower() throws -> [Int: Client]? {
		var clients: [Int: Client] = [:]
		var targetPort: UInt16 = serverDefaultPort

		// for leader we need to send message to all clients
		// for follower, we just need to talk to leader
		for node in self.configuration.nodes {
			if node.value.port != nil {
				targetPort = node.value.port!
			}

			guard let hostName = node.value.hostName else {
				throw EnsembleError.internalError(error: "Error getting targets hostname")
			}

			if node.value.rank == 0 {
				if self.useNoAttestation == true {
					clients[node.value.rank] = try getClient(
						server: hostName,
						port: targetPort,
						node: node.value.rank,
						delegate: self.clientDelegate
					)
				} else {
					clients[node.value.rank] = try self.getCloudAttestationBackedClient(
						configuration: self.configuration,
						server: hostName,
						port: targetPort,
						node: node.value.rank,
						delegate: self.clientDelegate
					)
				}
                let label = "datamessagequeue-\(node.value.rank)"
                clientQueues[node.value.rank] = DispatchSerialQueue(label:label, qos: .userInitiated )
				// we will start the client to leader because followers need to checking first.
				clients[node.value.rank]?.start()
			}
		}

		return clients
	}

	func getDataClientsForLeader() throws -> [Int: Client]? {
		var dataClients: [Int: Client] = [:]
		var targetPort: UInt16 = serverDefaultPort

		// for leader we need to send data messages to all followers
		for node in self.configuration.nodes {
			if node.value.port != nil {
				targetPort = node.value.port!
			}

			guard let hostName = node.value.hostName else {
				throw EnsembleError.internalError(error: "Error getting targets hostname")
			}

			if node.value.rank != 0 {
				// Create dedicated data client connections for each follower
				if self.useNoAttestation == true {
					dataClients[node.value.rank] = try getClient(
						server: hostName,
						port: targetPort,
						node: node.value.rank,
						delegate: self.clientDelegate,
                        startReceiveLoopOnConnect: true
					)
				} else {
					dataClients[node.value.rank] = try self.getCloudAttestationBackedClient(
						configuration: self.configuration,
						server: hostName,
						port: targetPort,
						node: node.value.rank,
						delegate: self.clientDelegate,
                        startReceiveLoopOnConnect: true
					)
				}
                
                let label = "dataclients-queue-\(node.value.rank)"
                // Use concurrent queue to allow parallel message sending to same follower
                dataClientQueues[node.value.rank] = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
			}
		}

		return dataClients
	}

	func getDataClientsForFollower() throws -> [Int: Client]? {
		var dataClients: [Int: Client] = [:]
		var targetPort: UInt16 = serverDefaultPort

		// for follower we need a data client connection to the leader
		for node in self.configuration.nodes {
			if node.value.port != nil {
				targetPort = node.value.port!
			}

			guard let hostName = node.value.hostName else {
				throw EnsembleError.internalError(error: "Error getting targets hostname")
			}

			if node.value.rank == 0 {
				// Create dedicated data client connection to leader
				if self.useNoAttestation == true {
					dataClients[node.value.rank] = try getClient(
						server: hostName,
						port: targetPort,
						node: node.value.rank,
						delegate: self.clientDelegate,
                        startReceiveLoopOnConnect: true
					)
				} else {
					dataClients[node.value.rank] = try self.getCloudAttestationBackedClient(
						configuration: self.configuration,
						server: hostName,
						port: targetPort,
						node: node.value.rank,
						delegate: self.clientDelegate,
                        startReceiveLoopOnConnect: true
					)
				}
                
                let label = "dataclients-queue-\(node.value.rank)"
                // Use concurrent queue to allow parallel message sending
                dataClientQueues[node.value.rank] = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
				// Start the data client to leader for followers
				dataClients[node.value.rank]?.start()
			}
		}

		return dataClients
	}

	func startClientsToFollowers() {
        EnsemblerTLS.logger.info("Starting clients to all followers.")
        for client in self.clients {
            client.value.start()
        }
        
        EnsemblerTLS.logger.info("Starting data clients to all followers.")
        for client in self.dataClients {
            client.value.start()
        }
	}

	func startClientToLeader() {
		self.clients[0]?.start()
	}

	func startDataClientToLeader() {
		self.dataClients[0]?.start()
	}

	func sendControlMessage(node: Int, message: Data, expectAck: Bool = true) throws {
		DispatchQueue.global(qos: .userInteractive).async {
			let controlMsg: EnsembleControlMessage
			do {
				controlMsg = try EnsembleControlMessage.decode(from: message)
				guard let client = self.clients[node] else {
					throw EnsembleError.internalError(error: "Error getting client for node \(node)")
				}

				let controlData = EnsembleControlData(rank: self.currentNode.rank, data: message)

				if expectAck {
					client.sendAndWaitForAck(message: controlData)
				} else {
					client.send(message: controlData)
				}
			} catch {
				logger.error(
					"TLSChannel.sendControlMessage() on rank \(self.currentNode.rank, privacy: .public): Control message decoding failed: \(error, privacy: .public)"
				)
				return
			}

			logger.info(
				"""
				TLSChannel.sendControlMessage on rank \(self.currentNode.rank, privacy: .public): Sending message
				\(controlMsg.description, privacy: .public)  to rank \(node, privacy: .public)
				"""
			)
		}
	}

	func sendMessageTo(msg: EnsembleControlMessage, destination: Int) throws {
		// EnsembleControlMessage.description does not expose any private data.
		logger.info(
			"""
			TLSChannel.sendMessageTo() on rank \(self.currentNode.rank, privacy: .public): \(
				msg,
				privacy: .public
			), \
			destination: \(destination, privacy: .public)
			"""
		)

		let msgData: Data
		do {
			msgData = try JSONEncoder().encode(msg)
		} catch {
			EnsemblerTLS.logger.error(
				"""
				TLSChannel.sendMessageTo() on rank \(self.currentNode.rank, privacy: .public):
				Failed to encode message \(String(describing: msg), privacy: .public) \
				: \(String(reportableError: error), privacy: .public))
				"""
			)
			throw error
		}

		try self.sendControlMessage(node: destination, message: msgData)
	}

	deinit {
		// perform the deinitialization
		stopServer()
		closeClients()
	}

	public func stopServer() {
		// stop the server
		logger.info(
			"""
			TLSChannel.stopServer on rank \(
				self.currentNode.rank,
				privacy: .public
			): Stopping the server)
			"""
		)
		self.cancelClientRetries()
		self.server?.stop()
	}

	func closeClients() {
		logger.info(
            """
            TLSChannel.closeClients on rank \(
                self.currentNode.rank,
                privacy: .public
            ): Stopping all clients )
            """
		)
		for client in self.clients {
			client.value.stop()
		}

		logger.info(
			"""
			TLSChannel.closeClients on rank \(
				self.currentNode.rank,
				privacy: .public
			): Stopping all data clients )
			"""
		)
		for client in self.dataClients {
			client.value.stop()
		}
		
		// Clean up dispatch groups
		dispatchGroups.withLock { groups in
			groups.removeAll()
		}
	}

	// Soft-cancel all clients: marks isCancelled and clears state handlers so pending
	// asyncAfter retries exit early, without force-cancelling active NWConnections.
	// Use this from stopServer() teardown; use closeClients() only from deinit.
	func cancelClientRetries() {
		for client in self.clients {
			client.value.cancel()
		}
		for client in self.dataClients {
			client.value.cancel()
		}
	}

	func getEnsembleDeviceFilter(configuration: EnsembleConfiguration) -> EnsembleValidator
		.DeviceFilter {
		let deviceIdentifiersFilter: EnsembleValidator
			.DeviceFilter = { (deviceIdentifier: DeviceIdentifiers?) in
                logger.info("TLSChannel.DeviceIdentifiersFilter() on rank \(self.currentNode.rank, privacy: .public): start")
                
				guard let deviceID = deviceIdentifier else {
					logger.error(
                        """
                            TLSChannel.DeviceIdentifiersFilter on rank \(
                                self.currentNode.rank,
                                privacy: .public
                            ): DeviceID returned from EnsembleValidator is nil )
                        """
					)
					return false
				}

				if configuration.nodes.keys.contains(deviceID.udid) {
					logger.info(
                        """
                            TLSChannel.DeviceIdentifiersFilter() on rank \(
                                self.currentNode.rank,
                                privacy: .public
                            ): \(deviceID.udid, privacy: .public) allowed
                        """
					)
					return true
				} else {
					logger.error(
                        """
                        TLSChannel.DeviceIdentifiersFilter() on rank \(
                            self.currentNode.rank,
                            privacy: .public
                        ): \(deviceID.udid, privacy: .public) rejected
                        """
					)
					return false
				}
			}

		return deviceIdentifiersFilter
	}

	func getCloudAttestationTlsOptions(configuration: EnsembleConfiguration) async throws -> NWProtocolTLS
		.Options {
		let deviceFilter = self.getEnsembleDeviceFilter(configuration: configuration)
		let validator = try EnsembleValidator(deviceFilter)

        logger.info("Calling configurator.createTLSOptions()")
        guard let options = try await self.configurator?.createTLSOptions(with: validator) else {
            throw EnsembleError.internalError(error: "we did not get TLS Options from cloudattestation")
        }
            
        return options
	}

	func getCloudAttestationBackedClient(
		configuration _: EnsembleConfiguration,
		server: String,
		port: UInt16,
		node: Int,
		delegate: ClientConnectionDelegate,
        startReceiveLoopOnConnect: Bool = false
	) throws -> Client {
		guard let tlsOptions = self.tlsOptions else {
			throw EnsembleError.internalError(error: "TLSOptions is nil, not expected")
		}
		return ClientImpl(host: server, port: port, tlsOptions: tlsOptions, node: node, delegate: delegate, startReceiveLoopOnConnect: startReceiveLoopOnConnect)
	}

	func getCloudAttestationBackedServer(
		configuration: EnsembleConfiguration,
		port: UInt16,
		delegate: ServerConnectionDelegate,
		node: Int
	) throws -> Server {
		guard let tlsOptions = self.tlsOptions else {
			throw EnsembleError.internalError(error: "TLSOptions is nil, not expected")
		}
		return try Server(port: port, tlsOptions: tlsOptions, delegate: delegate, node: node, configuration: configuration)
	}
}

import Security
extension TLSChannel {

    public func sendDataToAllFollowers(appID: String,
                                       data: Data,
                                       timeout: TimeInterval = 2.0,
                                       completion: @escaping (Result<[NodeResponse], Error>) -> Void)
    {
        logger.debug("TLSChannel.sendDataToAllFollowers: sending data to all followers with appID \(appID, privacy: .public)")
        
        // Collect all follower ranks (all nodes except rank 0 which is the leader)
        let followerRanks = configuration.nodes.values
            .filter { $0.rank != 0 }  // Exclude leader (rank 0)
            .map { $0.rank }
            .sorted()
        
        guard !followerRanks.isEmpty else {
            logger.warning("TLSChannel.sendDataToAllFollowers: no followers found in ensemble")
            completion(.success([]))
            return
        }
        
        let dispatchGroup = DispatchGroup()
        let responsesLock = OSAllocatedUnfairLock(initialState: [NodeResponse]())
        
        // Send data to each follower in parallel
        for rank in followerRanks {
            dispatchGroup.enter()

            // Execute each request in parallel on a concurrent queue
            // But the actual sending will be serialized per follower by the client queue
            DispatchQueue.global(qos: .userInitiated).async {
                self.sendDataAndGetResponse(
                    appID: appID,
                    data: data,
                    rank: rank,
                    timeout: timeout
                ) { result in
                    defer { dispatchGroup.leave() }
                    
                    let nodeResponse: NodeResponse
                    let timestamp = Date()
                    
                    switch result {
                    case .success(let responseData):
                        nodeResponse = NodeResponse(
                            rank: rank,
                            data: responseData,
                            error: nil,
                            timestamp: timestamp
                        )
                        
                    case .failure(let error):
                        nodeResponse = NodeResponse(
                            rank: rank,
                            data: nil,
                            error: error,
                            timestamp: timestamp
                        )
                        logger.error("TLSChannel.sendDataToAllFollowers: error from rank \(rank, privacy: .public): \(error, privacy: .public)")
                    }
                    
                    responsesLock.withLock { responses in
                        responses.append(nodeResponse)
                    }
                }
            }
        }
        
        // Wait for all responses or timeout
        dispatchGroup.notify(queue: .global()) {
            let responses = responsesLock.withLock { $0 }
            
            // Check if any response contains an error
            let errorResponses = responses.filter { $0.error != nil }
            if !errorResponses.isEmpty {
                logger.error("TLSChannel.sendDataToAllFollowers: found \(errorResponses.count, privacy: .public) responses with errors")
                for errorResponse in errorResponses {
                    logger.error("TLSChannel.sendDataToAllFollowers: Error from rank \(errorResponse.rank, privacy: .public): \(String(reflecting: errorResponse.error), privacy: .public)")
                }
                // Return failure with the first error found, but include all responses
                if let firstError = errorResponses.first?.error {
                    completion(.failure(firstError))
                } else {
                    // Fallback in case error is somehow nil
                    let genericError = EnsembleError.internalError(error: "One or more follower responses contained errors")
                    completion(.failure(genericError))
                }
            } else {
                completion(.success(responses))
            }
        }
    }
    
    public func sendDataAndGetResponse(
        appID: String, 
        data: Data,
        rank: Int,
        timeout: TimeInterval = 2.0,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        
        logger.debug("TLSChannel.sendDataAndGetResponse: sending data to rank \(rank, privacy: .public) with appID \(appID, privacy: .public), data size: \(data.count) bytes")
        
        guard let clientQueue = dataClientQueues[rank], let client = self.dataClients[rank] else {
            logger.error(
                "TLSChannel.sendDataAndGetResponse() on rank \(rank, privacy: .public), no data client or data client queue exists"
            )
            
            let error = DataMessageError.internalError(appID: appID, reason: "No data client or data client queue exists for rank \(rank)")
            completion(.failure(error))
            return
        }
        
        // Check client state before attempting to send
        guard client.state == .ready else {
            logger.warning("TLSChannel.sendDataAndGetResponse: Client to rank \(rank, privacy: .public) is not ready")
            let error = DataMessageError.notReady(appID: appID, currentStatus: "Client connection to rank \(rank) is not ready (state: \(client.state))")
            completion(.failure(error))
            return
        }
        
        // Now execute the actual request on the follower's dedicated queue
        clientQueue.async {
            // Re-check state inside the queue: the connection may have dropped between
            // the check above and now (the outer check races with retryConnection).
            guard client.state == .ready else {
                logger.warning("TLSChannel.sendDataAndGetResponse: Client to rank \(rank, privacy: .public) dropped before send (inside queue)")
                let error = DataMessageError.notReady(appID: appID, currentStatus: "Client connection to rank \(rank) dropped before send (state: \(client.state))")
                completion(.failure(error))
                return
            }

            logger.debug("TLSChannel.sendDataAndGetResponse: starting request to rank \(rank, privacy: .public)")

            client.sendAndWaitForResponse(
                appID: appID,
                data: data,
                currentNode: self.currentNode.rank,
                timeout: timeout
            ) { result in
                if case .failure(let error) = result {
                    logger.error(
                        "TLSChannel.sendDataAndGetResponse: failure response from rank \(rank, privacy: .public) appID: \(appID, privacy: .public): \(error, privacy: .public)"
                    )
                } else {
                    logger.debug("TLSChannel.sendDataAndGetResponse: received response from \(rank, privacy: .public)")
                }
                completion(result)
            }
        }
    }

}
