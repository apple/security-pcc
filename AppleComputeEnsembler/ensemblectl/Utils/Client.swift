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
//  Created by Dhanasekar Thangavel on 5/1/24.
//

//
// The ensembledframework getTlsOptions() API expose the NWProtocolTLS.Options.
// There is no way to test this easily, and one way to rely on TIE team to test this for us.
// Now with the client server, we get the tlsOptions from ensembled and use Network Framework APIs
// to establish mtls communication between server and client.
// To use it, run esenmblectl run-server <port> on a node, and on other node/nodes, run ensemblectl
// run-client <port> <server>
import Foundation
import Network

class Client {
	let connection: ClientConnection
	let host: NWEndpoint.Host
	let port: NWEndpoint.Port

	init(host: String, port: UInt16, tlsOptions: NWProtocolTLS.Options) {
		self.host = NWEndpoint.Host(host)
		self.port = NWEndpoint.Port(rawValue: port)!

		let tcpOptions = NWProtocolTCP.Options()
		tcpOptions.enableKeepalive = true
		tcpOptions.keepaliveIdle = 2

		// Create parameters with custom TLS and TCP options.
		let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)

		let nwConnection = NWConnection(host: self.host, port: self.port, using: parameters)
		self.connection = ClientConnection(nwConnection: nwConnection)
	}

	func start() {
		print("Client started \(self.host) \(self.port)")
		self.connection.didStopCallback = self.didStopCallback(error:)
		self.connection.start()
	}

	func stop() {
		self.connection.stop()
	}

	func send(data: Data) {
		self.connection.send(data: data)
	}

	func didStopCallback(error: Error?) {
		if error == nil {
			exit(EXIT_SUCCESS)
		} else {
			exit(EXIT_FAILURE)
		}
	}
}

class ClientConnection {
	let nwConnection: NWConnection
	let queue = DispatchQueue(label: "Client connection Q")

	init(nwConnection: NWConnection) {
		self.nwConnection = nwConnection
	}

	var didStopCallback: ((Error?) -> Void)?

	func start() {
		print("connection will start")
		self.nwConnection.stateUpdateHandler = self.stateDidChange(to:)
		self.setupReceive()
		self.nwConnection.start(queue: self.queue)
	}

	private func stateDidChange(to state: NWConnection.State) {
		switch state {
		case .waiting(let error):
			self.connectionDidFail(error: error)
		case .ready:
			print("Client connection ready")
		case .failed(let error):
			self.connectionDidFail(error: error)
		default:
			break
		}
	}

	private func setupReceive() {
		self.nwConnection
			.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
				if let data, !data.isEmpty {
					let message = String(data: data, encoding: .utf8)
					print("connection did receive, data: \(data as NSData) string: \(message ?? "-")")
				}
				if isComplete {
					self.connectionDidEnd()
				} else if let error {
					self.connectionDidFail(error: error)
				} else {
					self.setupReceive()
				}
			}
	}

	func send(data: Data) {
		self.nwConnection.send(content: data, completion: .contentProcessed { error in
			if let error {
				self.connectionDidFail(error: error)
				return
			}
			print("connection did send, data: \(data as NSData)")
		})
	}

	func stop() {
		print("connection will stop")
		self.stop(error: nil)
	}

	private func connectionDidFail(error: Error) {
		print("connection did fail, error: \(error)")
		self.stop(error: error)
	}

	private func connectionDidEnd() {
		print("connection did end")
		self.stop(error: nil)
	}

	private func stop(error: Error?) {
		self.nwConnection.stateUpdateHandler = nil
		self.nwConnection.cancel()
		if let didStopCallback = self.didStopCallback {
			self.didStopCallback = nil
			didStopCallback(error)
		}
	}
}

func initClient(server: String, port: UInt16, tlsOptions: NWProtocolTLS.Options) {
	let client = Client(host: server, port: port, tlsOptions: tlsOptions)
	client.start()
	while true {
		var command = readLine(strippingNewline: true)
		switch command {
		case "CRLF":
			command = "\r\n"
		case "RETURN":
			command = "\n"
		case "exit":
			client.stop()
		default:
			break
		}
		client.connection.send(data: (command?.data(using: .utf8))!)
	}
}

func runClient(server: String, port: UInt16, tlsOptions: NWProtocolTLS.Options) {
	initClient(server: server, port: port, tlsOptions: tlsOptions)
	RunLoop.current.run()
}
