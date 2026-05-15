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
//  ensemblectl.swift
//  ensemblectl
//
//  Created by Alex T Newman on 1/5/24.
//

import ArgumentParserInternal
import CryptoKit
import Foundation
import Network

// Import debug functions like activate and reconfigure
@_spi(Debug) import AppleComputeEnsembler

extension DateFormatter {
    static let iso8601WithFractionalSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

struct EnsembleCtl: ParsableCommand {
	static var configuration = CommandConfiguration(
		abstract: "CLI front-end to ensembled",
		subcommands: [
			GetStatus.self,
			GetDraining.self,
			GetNodeInfo.self,
			Activate.self,
			ReloadConfiguration.self,
			SendMessage.self,
			GetHealth.self,
			GetCableDiags.self,
			Encrypt.self,
			Decrypt.self,
			RotateSharedKey.self,
			GetMaxBuffersPerKey.self,
			GetMaxSecsKey.self,
			GetEnsembleID.self,
            GetRackID.self,
			RunServer.self,
			RunClient.self,
			DistributeDataKey.self,
			GetDataKey.self,
            DistributeDataKeyV2.self,
            GetDataKeyV2.self,
            DistributeDataKeyV3.self,
            GetDataKeyV3.self,
            SendDataMessage.self,
            ReceiveDataMessage.self,
            BroadcastDataMessage.self,
            ConcurrentMessagingTest.self
		]
	)
}

extension EnsembleCtl {
	struct GetStatus: ParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Prints status of ensemble.")
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let status = try ensembler.getStatus()
			print("Received status: \(String(describing: status))")
		}
	}

	struct GetDraining: ParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Prints node's draining state.")
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let draining = try ensembler.isDraining()
			print("Received node's draining state: \(draining)")
		}
	}

	struct GetMaxBuffersPerKey: ParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Gets the max buffers per key.")
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let maxBuffersPerKey = try ensembler.getMaxBuffersPerKey()
			print("Received Max buffers per key: \(maxBuffersPerKey)")
		}
	}

	struct GetMaxSecsKey: ParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Gets the max seconds per key.")
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let maxSecsPerKey = try ensembler.getMaxSecsPerKey()
			print("Received Max seconds per key: \(maxSecsPerKey)")
		}
	}

    struct DistributeDataKey: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Distributes the data key.")
            mutating func run() throws {
                let ensembler = try EnsemblerSession()
                let key = SymmetricKey(size: .bits128)
                let keyData = key.withUnsafeBytes { Data(Array($0)) }

                let token = try ensembler.distributeDataKey(key: key, type: .distributed)
                print(
                    "Distributed the data key.: \(keyData.map { String(format: "%02x", $0) }.joined()), token = \(token)"
                )
            }
        }

    struct GetDataKey: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Gets the data key.")

        @Argument(help: "The single use key token for the key to retrieve.")
        var token: String

        mutating func run() throws {
            let ensembler = try EnsemblerSession()
            let key: SymmetricKey = try ensembler.getDataKey(token: UUID(uuidString: self.token)!)
            let keyData = key.withUnsafeBytes { Data(Array($0)) }
            print(
                " Key obtained for token \(self.token) is: \(keyData.map { String(format: "%02x", $0) }.joined())"
            )
        }
    }

    
	struct DistributeDataKeyV2: ParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Distributes the data key.")
        
        @Argument(help: "The paraphrase to generate key encryption key.")
        var paraPhrase: String
        
        func generateSymmetricKey(from string: String) -> SymmetricKey {
            // Convert string to Data
            let keyData = Data(string.utf8)

            // Hash the data to ensure a fixed size (use SHA256 for a 256-bit key)
            let hashedKey = SHA256.hash(data: keyData)

            // Create the SymmetricKey
            return SymmetricKey(data: Data(hashedKey))
        }
        
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let key = SymmetricKey(size: .bits128)
            
			let keyData = key.withUnsafeBytes { Data(Array($0)) }
            let kek = generateSymmetricKey(from: paraPhrase)
            let box = try CryptoKit.AES.GCM.seal(keyData, using: kek)
            
			let token = try ensembler.distributeDataKey(key: box, type: .distributed)
			print(
				"Distributed the data key.: \(keyData.map { String(format: "%02x", $0) }.joined()), token = \(token)"
			)
		}
	}
    
    struct DistributeDataKeyV3: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Distributes the data key.")
        
        @Argument(help: "The paraphrase to generate key encryption key.")
        var paraPhrase: String
        
        func generateSymmetricKey(from string: String) -> SymmetricKey {
            // Convert string to Data
            let keyData = Data(string.utf8)

            // Hash the data to ensure a fixed size (use SHA256 for a 256-bit key)
            let hashedKey = SHA256.hash(data: keyData)

            // Create the SymmetricKey
            return SymmetricKey(data: Data(hashedKey))
        }
        
        mutating func run() throws {
            let ensembler = try EnsemblerSession()
            let key = SymmetricKey(size: .bits128)
            
            let keyData = key.withUnsafeBytes { Data(Array($0)) }
            let kek = generateSymmetricKey(from: paraPhrase)
            let box = try CryptoKit.AES.GCM.seal(keyData, using: kek)
            
            let uuid = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")
            let spanID = UInt64("1234567")
            
            let tracingContext = EnsembleTracingContext(name: nil, requestID: uuid!, spanID: spanID! , parentSpanID: nil)
            
            let token = try ensembler.distributeDataKey(key: box, type: .distributed, tracingContext: tracingContext)
            print(
                "Distributed the data key.: \(keyData.map { String(format: "%02x", $0) }.joined()), token = \(token)"
            )
        }
    }

	struct GetDataKeyV2: ParsableCommand {
		static let configuration = CommandConfiguration(abstract: "Gets the data key.")

		@Argument(help: "The single use key token for the key to retrieve.")
		var token: String
        
        @Argument(help: "The paraphrase to generate key encryption key.")
        var paraPhrase: String

        func generateSymmetricKey(from string: String) -> SymmetricKey {
            // Convert string to Data
            let keyData = Data(string.utf8)

            // Hash the data to ensure a fixed size (use SHA256 for a 256-bit key)
            let hashedKey = SHA256.hash(data: keyData)

            // Create the SymmetricKey
            return SymmetricKey(data: Data(hashedKey))
        }
        
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
            let sealedBox: AES.GCM.SealedBox = try ensembler.getDataKey(token: UUID(uuidString: self.token)!)
            
            let kek = generateSymmetricKey(from: paraPhrase)
            let keyData = try CryptoKit.AES.GCM.open(sealedBox, using: kek)
			print(
				" Key obtained for token \(self.token) is: \(keyData.map { String(format: "%02x", $0) }.joined())"
			)
		}
	}
    
    struct GetDataKeyV3: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Gets the data key.")

        @Argument(help: "The single use key token for the key to retrieve.")
        var token: String
        
        @Argument(help: "The paraphrase to generate key encryption key.")
        var paraPhrase: String

        func generateSymmetricKey(from string: String) -> SymmetricKey {
            // Convert string to Data
            let keyData = Data(string.utf8)

            // Hash the data to ensure a fixed size (use SHA256 for a 256-bit key)
            let hashedKey = SHA256.hash(data: keyData)

            // Create the SymmetricKey
            return SymmetricKey(data: Data(hashedKey))
        }
        
        mutating func run() throws {
            let uuid = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")
            let spanID = UInt64("1234567")
            
            let tracingContext = EnsembleTracingContext(name: nil, requestID: uuid!, spanID: spanID! , parentSpanID: nil)
            
            let ensembler = try EnsemblerSession()
            let sealedBox: AES.GCM.SealedBox = try ensembler.getDataKey(token: UUID(uuidString: self.token)!, tracingContext: tracingContext)
            
            let kek = generateSymmetricKey(from: paraPhrase)
            let keyData = try CryptoKit.AES.GCM.open(sealedBox, using: kek)
            print(
                " Key obtained for token \(self.token) is: \(keyData.map { String(format: "%02x", $0) }.joined())"
            )
        }
    }

	struct GetNodeInfo: ParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Prints info about the nodes in the ensemble."
		)
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let nodeInfo = try ensembler.getNodeInfo()
			let leaderInfo = try ensembler.getLeaderInfo()
			let peerInfo = try ensembler.getPeerInfo()
			let leader = try ensembler.isLeader()

			print(
				"""
				Current Node Info:
				isLeader: \(leader)
				Node: \(nodeInfo)

				Leader Info:
				Node: \(leaderInfo)

				Peer Info:
				Peers: \(String(describing: peerInfo))
				"""
			)
		}
	}

	struct Activate: ParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Activate the ensemble manually. (Requires Root)"
		)
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let result = try ensembler.activate()
			if result == true {
				print("Activation succeeded.")
			} else {
				print("Activation failed.")
			}
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError("Activating the ensemble requires Root privileges")
			}
		}
	}

	struct RotateSharedKey: ParsableCommand {
		static let configuration =
			CommandConfiguration(abstract: "Rotate the shared key manually. (Requires Root)")
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let result = try ensembler.rotateSharedKey()
			if result == true {
				print("Rotate key succeeded.")
			} else {
				print("Rotate key failed.")
			}
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError("Rotating the key requires Root privileges")
			}
		}
	}

	struct Encrypt: ParsableCommand {
		static let configuration =
			CommandConfiguration(abstract: "Encrypt the message with sharedKey. (Requires Root)")
		@Argument(help: "The text to encrypt.")
		var text: String
		mutating func run() throws {
			let ensembler = try EnsemblerSession()

			guard let data = text.data(using: .utf8) else {
				print("Error converting text")
				return
			}
			guard let result = try ensembler.encryptData(data: data) else {
				print("Could not encrypt the data")
				return
			}

			print("Encrypted data (base64encoded) is \(result.base64EncodedString())")
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError(
					"Encrypting the message using shared key requires Root privileges"
				)
			}
		}
	}

	struct RunServer: ParsableCommand {
		static let configuration =
			CommandConfiguration(
				abstract: "Gets the TLS options, and runs a server using the TLSOptions. (Requires Root)"
			)

		@Argument(help: "The port to stand the server.")
		var port: UInt16

		@Argument(help: "Whether to use cloudattestation or not.")
		var useAttestation: Bool = false

		@Option(name: .shortAndLong, help: "List of UDIDs that should be allowed to mTLS")
		var udidList: [String]

		mutating func run() throws {
			let ensembler = try EnsemblerSession()
            
            var options: NWProtocolTLS.Options
            
            if useAttestation {
                let allowedList = udidList
                try ensembler.createAttestation()
                options = try ensembler.getTlsOptionsBackedByCloudAttestation(filter: { udid in
                    print("CloudAttestation callback called")
                    if allowedList.contains(udid) {
                        print("UDID found in the allowedList, allowing the UDID \(udid)")
                        return true
                    }
                    else {
                        print("UDID not found in the allowedList, rejecting the UDID \(udid)")
                        return false
                    }
                })
                
                print("calling refreshattestation")
                try ensembler.refreshAttestation()

            }
            else {
                options = try ensembler.getTlsOptions()
            }

			print("Obtained TLS options \(options.securityProtocolOptions.hash)")

			runServer(port: self.port, tlsOptions: options)
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError(
					"Encrypting the message using shared key requires Root privileges"
				)
			}
		}
	}

	struct RunClient: ParsableCommand {
		static let configuration =
			CommandConfiguration(
				abstract: "Gets the TLS options, and runs a server using the TLSOptions. (Requires Root)"
			)

		@Argument(help: "The port on which the server listens.")
		var port: UInt16

		@Argument(help: "The server to connect to.")
		var server: String

		@Argument(help: "Whether to use cloudattestation or not.")
		var useAttestation: Bool

		@Option(name: .shortAndLong, help: "List of UDIDs that should be allowed to mTLS")
		var udidList: [String]

		mutating func run() throws {
			let ensembler = try EnsemblerSession()
            
            var options: NWProtocolTLS.Options
            
            if useAttestation {
                let allowedList = udidList
                
                try ensembler.createAttestation()
                options = try ensembler.getTlsOptionsBackedByCloudAttestation(filter: { udid in
                    print("CloudAttestation callback called")
                    if allowedList.contains(udid) {
                        print("UDID found in the allowedList, allowing the UDID \(udid)")
                        return true
                    }
                    else {
                        print("UDID not found in the allowedList, rejecting the UDID \(udid)")
                        return false
                    }
                })
                
                print("calling refreshattestation")
                try ensembler.refreshAttestation()
            }
            else {
                options = try ensembler.getTlsOptions()
            }

			print("Obtained TLS options \(options.securityProtocolOptions.hash)")

			runClient(server: self.server, port: self.port, tlsOptions: options)
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError(
					"Encrypting the message using shared key requires Root privileges"
				)
			}
		}
	}

	struct Decrypt: ParsableCommand {
		static let configuration =
			CommandConfiguration(
				abstract: "Decrypt the encrypted message with sharedKey. (Requires Root)"
			)
		@Argument(help: "The base64encoded text to decrypt.")
		var text: String
		mutating func run() throws {
			let ensembler = try EnsemblerSession()

			guard let data = Data(base64Encoded: text) else {
				print("Error converting text")
				return
			}

			guard let result = try ensembler.decryptData(data: data) else {
				print("Could not decrypt the data")
				return
			}

			print("Decrypted text: \(String(data: result, encoding: .utf8)!)")
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError(
					"Decrypting the message using shared key requires Root privileges"
				)
			}
		}
	}

	struct ReloadConfiguration: ParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Force ensembled to re-read and reload configuration. (Requires Root)"
		)
		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let result = try ensembler.reloadConfiguration()
			if result == true {
				print("Configuration reloaded")
			} else {
				print("Configuration reload failed")
			}
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError(
					"Reloading the ensemble configuration requires Root privileges"
				)
			}
		}
	}

	struct SendMessage: ParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Send a test message to given node. (Requires Root)"
		)

		@Argument(help: "the Node to message (by rank)")
		var destination: Int

		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let result = try ensembler.sendTestMessage(destination: self.destination)
			if result == true {
				print("Message sent")
			} else {
				print("Message failed to send.")
			}
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError(
					"Reloading the ensemble configuration requires Root privileges"
				)
			}
		}
	}

	struct GetHealth: ParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Get ensemble health. (Requires Root)"
		)

		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let health = try ensembler.getHealth()
			print("Got health state: \(health.healthState)")
			print("Got health metadata: \(health.metadata)")
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError(
					"Getting ensemble health requires Root privileges"
				)
			}
		}
	}

	struct GetCableDiags: ParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Run cable mesh diagnostics. 8 node ensembles only. (Requires Root)"
		)

		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let diags = try ensembler.getCableDiagnostics()
			print("Got \(diags.count) cable diagnostics")
			for diag in diags {
				print("  - \(diag)")
			}
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError(
					"Getting cable diagnostics requires Root privileges"
				)
			}
		}
	}

	struct GetEnsembleID: ParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Get ensemble ID. (Requires Root)"
		)

		mutating func run() throws {
			let ensembler = try EnsemblerSession()
			let ensembleID = try ensembler.getEnsembleID()
			print("Got \(String(describing: ensembleID))")
		}

		mutating func validate() throws {
			guard geteuid() == 0 else {
				throw ValidationError(
					"Getting cable diagnostics requires Root privileges"
				)
			}
		}
	}
    
    struct GetRackID: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Get rack ID. (Requires Root)"
        )

        mutating func run() throws {
            let ensembler = try EnsemblerSession()
            let rackID = try ensembler.getRackID()
            print("Got \(String(describing: rackID))")
        }

        mutating func validate() throws {
            guard geteuid() == 0 else {
                throw ValidationError(
                    "Getting cable diagnostics requires Root privileges"
                )
            }
        }
    }

    struct SendDataMessage: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send data message to a destination node and get response. (Requires Root)"
        )
        @Argument(help: "The application ID for message routing.")
        var appID: String
        @Argument(help: "The destination node rank.")
        var destination: Int
        @Argument(help: "The message text to send.")
        var message: String
        @Option(name: .shortAndLong, help: "Timeout in seconds (default: 5.0)")
        var timeout: Double = 5.0
        @Option(name: .shortAndLong, help: "use tracing context, default is true")
        var useTracingContext: Bool = true
        
        private func timestampedPrint(_ message: String) {
            let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
            print("[\(timestamp)] \(message)")
        }
        
        mutating func run() throws {
            let ensembler = try EnsemblerSession()
            
            // Check ensemble status first
            let status = try ensembler.getStatus()
            guard status == .ready else {
                timestampedPrint("Ensemble is not ready. Status: \(status)")
                return
            }
            
            // Convert message to data
            guard let messageData = message.data(using: .utf8) else {
                timestampedPrint("Error: Could not convert message to data")
                return
            }
            
            timestampedPrint("Sending message to node \(destination) with appID '\(appID)'...")
            timestampedPrint("Message: \(message)")
            
            do {
                var responseData: Data?
                if useTracingContext {
                    let uuid = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")
                    let spanID = UInt64("1234567")
                    
                    let tracingContext = EnsembleTracingContext(name: nil, requestID: uuid!, spanID: spanID! , parentSpanID: nil)
                    
                    responseData = try ensembler.sendDataToFollowerNode(
                        appID: appID,
                        data: messageData,
                        destination: destination,
                        timeout: timeout,
                        tracingContext: tracingContext
                    )
                }
                else {
                    responseData = try ensembler.sendDataAndGetResponse(
                        appID: appID,
                        data: messageData,
                        destination: destination,
                        timeout: timeout
                    )
                }
                
                guard let responseData = responseData else {
                    timestampedPrint("Response data is nil")
                    return
                }
                // Try to convert response to string
                if let responseString = String(data: responseData, encoding: .utf8) {
                    timestampedPrint("Received response: \(responseString)")
                } else {
                    timestampedPrint("Received binary response (\(responseData.count) bytes): \(responseData.base64EncodedString())")
                }
                
            } catch {
                timestampedPrint("Failed to send message: \(error)")
            }
        }
        
        mutating func validate() throws {
            guard geteuid() == 0 else {
                throw ValidationError(
                    "Sending data messages requires Root privileges"
                )
            }
        }
    }

    struct ReceiveDataMessage: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Register to receive data messages for an appID and respond to them. (Requires Root)"
        )
        @Argument(help: "The application ID to listen for messages.")
        var appID: String
        @Option(name: .shortAndLong, help: "Response message to send back (default: echo)")
        var response: String?
        @Flag(name: .shortAndLong, help: "Calculate and return message statistics")
        var stats: Bool = false
        
        private func timestampedPrint(_ message: String) {
            let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
            print("[\(timestamp)] \(message)")
        }
        
        mutating func run() throws {
            let ensembler = try EnsemblerSession()
            
            // Check ensemble status first
            let status = try ensembler.getStatus()
            guard status == .ready else {
                timestampedPrint("Ensemble is not ready. Status: \(status)")
                return
            }
            
            timestampedPrint("Registering data message handler for appID: '\(appID)'")
            timestampedPrint("Listening for incoming messages... (Press Ctrl+C to stop)")
            
            // Capture the values we need to avoid mutating self capture
            let responseMessage = self.response
            let shouldReturnStats = self.stats
            
            // Register the message handler
            try ensembler.registerDataCallback(appID: appID) { sender, receivedData in
                // Convert received data to string for display
                let receivedString = String(data: receivedData, encoding: .utf8) ?? "<binary data>"
                let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                print("[\(timestamp)] 📨 Received message: \(receivedString) from rank \(sender)")
                
                // Generate response based on options
                let responseText: String
                if let customResponse = responseMessage {
                    responseText = customResponse
                } else if shouldReturnStats {
                    // Return message statistics
                    let stats: [String: Any] = [
                        "bytes": receivedData.count,
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                        "isUTF8": receivedString != "<binary data>"
                    ]
                    if let statsData = try? JSONSerialization.data(withJSONObject: stats) {
                        return statsData
                    } else {
                        responseText = "Stats calculation failed"
                    }
                } else {
                    // Default: echo the message
                    responseText = "Echo: \(receivedString)"
                }
                
                let responseTimestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                print("[\(responseTimestamp)] 📤 Sending response: \(responseText)")
                return responseText.data(using: .utf8) ?? Data()
            }
            
            // Keep the program running to receive messages
            timestampedPrint("Handler registered successfully. Waiting for messages...")
            RunLoop.current.run()
        }
        
        mutating func validate() throws {
            guard geteuid() == 0 else {
                throw ValidationError(
                    "Receiving data messages requires Root privileges"
                )
            }
        }
    }

    struct BroadcastDataMessage: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Broadcast data message to all followers and get responses. (Requires Root)"
        )
        @Argument(help: "The application ID for message routing.")
        var appID: String
        @Argument(help: "The message text to broadcast.")
        var message: String
        @Option(name: .shortAndLong, help: "Timeout in seconds (default: 5.0)")
        var timeout: Double = 5.0
        @Option(name: .shortAndLong, help: "Use tracing context, default = true")
        var useTracingContext: Bool = true
        
        private func timestampedPrint(_ message: String) {
            let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
            print("[\(timestamp)] \(message)")
        }
        
        mutating func run() throws {
            let ensembler = try EnsemblerSession()
            
            // Check ensemble status first
            let status = try ensembler.getStatus()
            guard status == .ready else {
                timestampedPrint("Ensemble is not ready. Status: \(status)")
                return
            }
            
            // Check if this node is the leader
            let isLeader = try ensembler.isLeader()
            guard isLeader else {
                timestampedPrint("Error: Broadcast can only be initiated from the leader node")
                return
            }
            
            // Convert message to data
            guard let messageData = message.data(using: .utf8) else {
                timestampedPrint("Error: Could not convert message to data")
                return
            }
            
            timestampedPrint("Broadcasting message to all followers with appID '\(appID)'...")
            timestampedPrint("Message: \(message)")
            
            do {
                
                var responseData: [NodeResponse]?
                if useTracingContext {
                    let uuid = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")
                    let spanID = UInt64("1234567")
                    
                    let tracingContext = EnsembleTracingContext(name: nil, requestID: uuid!, spanID: spanID! , parentSpanID: nil)
                    
                    responseData = try ensembler.sendDataToAllFollowers(
                        appID: appID,
                        data: messageData,
                        timeout: timeout,
                        tracingContext: tracingContext
                    )
                }
                else {
                    responseData = try ensembler.sendDataToAllFollowers(
                        appID: appID,
                        data: messageData,
                        timeout: timeout
                    )
                }
                
                guard let responseData = responseData else {
                    timestampedPrint("Received nil data.")
                    return
                }
                
                timestampedPrint("Successfully received \(responseData.count) responses from followers:")
                
                // Sort responses by rank for consistent output
                let sortedResponses = responseData.sorted { $0.rank < $1.rank }
                
                for nodeResponse in sortedResponses {
                    let responsePrefix = "Rank \(nodeResponse.rank):"
                    
                    if let error = nodeResponse.error {
                        timestampedPrint("\(responsePrefix) ERROR - \(error.localizedDescription)")
                    } else if let data = nodeResponse.data {
                        if let responseString = String(data: data, encoding: .utf8) {
                            if responseString.isEmpty {
                                timestampedPrint("\(responsePrefix) Response: <empty string>")
                            } else {
                                timestampedPrint("\(responsePrefix) Response: \(responseString)")
                            }
                        } else {
                            timestampedPrint("\(responsePrefix) Binary response (\(data.count) bytes): \(data.base64EncodedString())")
                        }
                    } else {
                        timestampedPrint("\(responsePrefix) No response data")
                    }
                    
                    // Show response time
                    let responseTime = Date().timeIntervalSince(nodeResponse.timestamp)
                    timestampedPrint("\(responsePrefix) Response received \(String(format: "%.3f", abs(responseTime))) seconds ago")
                }
                
            } catch {
                timestampedPrint("Failed to broadcast message: \(error)")
            }
        }
        
        mutating func validate() throws {
            guard geteuid() == 0 else {
                throw ValidationError(
                    "Broadcasting data messages requires Root privileges"
                )
            }
        }
    }

    struct ConcurrentMessagingTest: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send concurrent messages from leader to all followers and collect performance metrics. (Requires Root)"
        )
        
        @Option(name: .shortAndLong, help: "Number of message iterations per follower (default: 5)")
        var iterations: Int = 5
        
        @Option(name: .shortAndLong, help: "Timeout per message in seconds (default: 10.0)")
        var timeout: Double = 10.0
        
        @Option(name: .shortAndLong, help: "Application ID for message routing (default: concurrent-test)")
        var appID: String = "concurrent-test"
        
        @Flag(name: .shortAndLong, help: "Enable verbose logging")
        var verbose: Bool = false
        
        @Flag(name: .shortAndLong, help: "Validate message responses (check for Echo: prefix)")
        var validateResponses: Bool = false
        
        @Option(name: .shortAndLong, help: "Message delay in milliseconds between sends (default: 0)")
        var messageDelay: Int = 0
        
        @Flag(name: .shortAndLong, help: "Export metrics to JSON file")
        var exportMetrics: Bool = false
        
        // Performance metrics structure
        struct MessageMetrics: Codable {
            let messageKey: String
            let startTime: Date
            let endTime: Date
            let latency: TimeInterval
            let followerRank: Int
            let iteration: Int
            let originalMessage: String
            let receivedResponse: String
            let validResponse: Bool
        }
        
        private func timestampedPrint(_ message: String) {
            let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
            print("[\(timestamp)] \(message)")
        }
        
        private func verbosePrint(_ message: String) {
            if verbose {
                timestampedPrint("DEBUG: \(message)")
            }
        }
        
        mutating func run() throws {
            let ensembler = try EnsemblerSession()
            
            // Check ensemble status first
            let status = try ensembler.getStatus()
            guard status == .ready else {
                timestampedPrint("❌ Ensemble is not ready. Status: \(status)")
                Foundation.exit(1)
            }
            
            // Check if this node is the leader
            let isLeader = try ensembler.isLeader()
            guard isLeader else {
                timestampedPrint("❌ Error: Concurrent messaging test can only be run from the leader node")
                Foundation.exit(1)
            }
            
            // Get node information to determine follower count
            let nodeInfo = try ensembler.getNodeInfo()
            let peerInfo = try ensembler.getPeerInfo()
            let totalNodes = peerInfo!.count + 1
            let followerCount = totalNodes - 1 // Exclude leader
            
            guard followerCount > 0 else {
                timestampedPrint("❌ Error: No followers found in ensemble")
                Foundation.exit(1)
            }
            
            timestampedPrint("🚀 Starting concurrent messaging performance test")
            timestampedPrint("📊 Configuration:")
            timestampedPrint("   - Ensemble size: \(totalNodes) nodes")
            timestampedPrint("   - Followers: \(followerCount)")
            timestampedPrint("   - Iterations per follower: \(iterations)")
            timestampedPrint("   - Message timeout: \(timeout)s")
            timestampedPrint("   - App ID: \(appID)")
            timestampedPrint("   - Validate responses: \(validateResponses)")
            timestampedPrint("   - Message delay: \(messageDelay)ms")
            
            let totalMessages = followerCount * iterations
            timestampedPrint("   - Total messages: \(totalMessages)")
            
            // Performance tracking
            var performanceMetrics: [MessageMetrics] = []
            var responseCount = 0
            let performanceMetricsLock = NSLock()
            let responseCountLock = NSLock()
            
            // Create dispatch group to wait for all messages
            let group = DispatchGroup()
            
            timestampedPrint("⏱️  Test starting in 3 seconds...")
            Thread.sleep(forTimeInterval: 3.0)
            
            let testStartTime = Date()
            timestampedPrint("📤 Sending \(totalMessages) concurrent messages...")
            
            // Capture values needed in the async closure to avoid mutating self capture
            let capturedAppID = self.appID
            let capturedTimeout = self.timeout
            let capturedVerbose = self.verbose
            let capturedValidateResponses = self.validateResponses
            
            // Send messages concurrently to all followers
            for iteration in 1...iterations {
                for followerRank in 1...followerCount {
                    let message = "ConcurrentTest-\(UUID().uuidString)-Iteration[\(iteration)]-ToFollower[\(followerRank)]"
                    let messageKey = "follower\(followerRank)_iteration\(iteration)"
                    
                    verbosePrint("Preparing message: \(messageKey)")
                    
                    group.enter()
                    
                    // Add delay if specified
                    if messageDelay > 0 {
                        Thread.sleep(forTimeInterval: Double(messageDelay) / 1000.0)
                    }
                    
                    // Record send time
                    let sendTime = Date()
                    
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            if capturedVerbose {
                                let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                print("[\(timestamp)] DEBUG: Sending \(messageKey): \(message)")
                            }
                            
                            let responseData = try ensembler.sendDataAndGetResponse(
                                appID: capturedAppID,
                                data: message.data(using: .utf8)!,
                                destination: followerRank,
                                timeout: capturedTimeout
                            )
                            
                            let responseTime = Date()
                            let latency = responseTime.timeIntervalSince(sendTime)
                            
                            responseCountLock.lock()
                            responseCount += 1
                            let currentCount = responseCount
                            responseCountLock.unlock()
                        
                            guard let responseString = String(data: responseData, encoding: .utf8) else {
                                let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                print("[\(timestamp)] ⚠️  \(messageKey): Could not decode response as UTF-8")
                                group.leave()
                                return
                            }
                            
                            // Validate response if requested
                            var validResponse = true
                            if capturedValidateResponses {
                                let expectedPrefix = "Echo: "
                                validResponse = responseString.hasPrefix(expectedPrefix) && 
                                               responseString.dropFirst(expectedPrefix.count).contains(message)
                                
                                if !validResponse {
                                    let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                    print("[\(timestamp)] ❌ \(messageKey): Invalid response - Expected echo, got: \(responseString)")
                                }
                            }
                            
                            // Record metrics
                            let metrics = MessageMetrics(
                                messageKey: messageKey,
                                startTime: sendTime,
                                endTime: responseTime,
                                latency: latency,
                                followerRank: followerRank,
                                iteration: iteration,
                                originalMessage: message,
                                receivedResponse: responseString,
                                validResponse: validResponse
                            )
                            
                            performanceMetricsLock.lock()
                            performanceMetrics.append(metrics)
                            performanceMetricsLock.unlock()
                            
                            if capturedVerbose {
                                let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                print("[\(timestamp)] ✅ \(messageKey): \(String(format: "%.3f", latency * 1000))ms - Response: \(responseString.prefix(50))\(responseString.count > 50 ? "..." : "")")
                            } else if currentCount % 10 == 0 {
                                let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                print("[\(timestamp)] 📊 Progress: \(currentCount)/\(totalMessages) messages completed")
                            }
                            
                        } catch {
                            let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                            print("[\(timestamp)] ❌ \(messageKey): Failed - \(error)")
                        }
                        
                        group.leave()
                    }
                }
            }
            
            timestampedPrint("⏳ Waiting for all messages to complete...")
            group.wait()
            
            let testEndTime = Date()
            let totalDuration = testEndTime.timeIntervalSince(testStartTime)
            
            timestampedPrint("✅ All messages completed!")
            
            // Generate performance report
            performanceMetricsLock.lock()
            let finalMetrics = performanceMetrics
            performanceMetricsLock.unlock()
            
            generatePerformanceReport(metrics: finalMetrics, totalDuration: totalDuration, expectedMessages: totalMessages)
            
            if exportMetrics {
                exportMetricsToJSON(metrics: finalMetrics)
            }
        }
        
        private func generatePerformanceReport(metrics: [MessageMetrics], totalDuration: TimeInterval, expectedMessages: Int) {
            timestampedPrint("\n" + String(repeating: "=", count: 60))
            timestampedPrint("📊 CONCURRENT MESSAGING PERFORMANCE REPORT")
            timestampedPrint(String(repeating: "=", count: 60))
            
            // Basic statistics
            timestampedPrint("\n🔢 Basic Statistics:")
            timestampedPrint("   Total Duration: \(String(format: "%.3f", totalDuration))s")
            timestampedPrint("   Expected Messages: \(expectedMessages)")
            timestampedPrint("   Completed Messages: \(metrics.count)")
            timestampedPrint("   Success Rate: \(String(format: "%.1f", Double(metrics.count) / Double(expectedMessages) * 100))%")
            
            if metrics.isEmpty {
                timestampedPrint("❌ No metrics to analyze")
                return
            }
            
            // Response validation
            if validateResponses {
                let validResponses = metrics.filter { $0.validResponse }
                let validationRate = Double(validResponses.count) / Double(metrics.count) * 100
                timestampedPrint("   Response Validation Rate: \(String(format: "%.1f", validationRate))%")
                
                if validationRate < 100 {
                    let invalidResponses = metrics.filter { !$0.validResponse }
                    timestampedPrint("   ⚠️  Invalid responses: \(invalidResponses.count)")
                    if verbose {
                        for invalid in invalidResponses.prefix(5) {
                            timestampedPrint("      \(invalid.messageKey): \(invalid.receivedResponse)")
                        }
                    }
                }
            }
            
            // Latency statistics
            let latencies = metrics.map { $0.latency }
            let totalLatency = latencies.reduce(0, +)
            let averageLatency = totalLatency / Double(latencies.count)
            let minLatency = latencies.min() ?? 0
            let maxLatency = latencies.max() ?? 0
            
            // Calculate percentiles
            let sortedLatencies = latencies.sorted()
            let p50Index = Int(Double(sortedLatencies.count) * 0.5)
            let p90Index = Int(Double(sortedLatencies.count) * 0.9)
            let p95Index = Int(Double(sortedLatencies.count) * 0.95)
            let p99Index = Int(Double(sortedLatencies.count) * 0.99)
            
            let p50Latency = sortedLatencies[min(p50Index, sortedLatencies.count - 1)]
            let p90Latency = sortedLatencies[min(p90Index, sortedLatencies.count - 1)]
            let p95Latency = sortedLatencies[min(p95Index, sortedLatencies.count - 1)]
            let p99Latency = sortedLatencies[min(p99Index, sortedLatencies.count - 1)]
            
            timestampedPrint("\n⚡ Latency Analysis:")
            timestampedPrint("   Average: \(String(format: "%.3f", averageLatency * 1000))ms")
            timestampedPrint("   Min: \(String(format: "%.3f", minLatency * 1000))ms")
            timestampedPrint("   Max: \(String(format: "%.3f", maxLatency * 1000))ms")
            timestampedPrint("   P50: \(String(format: "%.3f", p50Latency * 1000))ms")
            timestampedPrint("   P90: \(String(format: "%.3f", p90Latency * 1000))ms")
            timestampedPrint("   P95: \(String(format: "%.3f", p95Latency * 1000))ms")
            timestampedPrint("   P99: \(String(format: "%.3f", p99Latency * 1000))ms")
            
            // Throughput
            let messagesPerSecond = Double(metrics.count) / totalDuration
            timestampedPrint("\n📈 Throughput:")
            timestampedPrint("   Messages/Second: \(String(format: "%.2f", messagesPerSecond))")
            
            // Per-follower analysis
            timestampedPrint("\n👥 Per-Follower Performance:")
            let followerRanks = Set(metrics.map { $0.followerRank }).sorted()
            for rank in followerRanks {
                let followerMetrics = metrics.filter { $0.followerRank == rank }
                if !followerMetrics.isEmpty {
                    let followerLatencies = followerMetrics.map { $0.latency }
                    let followerAvg = followerLatencies.reduce(0, +) / Double(followerLatencies.count)
                    let followerMin = followerLatencies.min() ?? 0
                    let followerMax = followerLatencies.max() ?? 0
                    
                    timestampedPrint("   Rank \(rank): Avg=\(String(format: "%.3f", followerAvg * 1000))ms, Min=\(String(format: "%.3f", followerMin * 1000))ms, Max=\(String(format: "%.3f", followerMax * 1000))ms (\(followerMetrics.count) msgs)")
                }
            }
            
            // Per-iteration analysis
            timestampedPrint("\n🔄 Per-Iteration Performance:")
            let iterationNumbers = Set(metrics.map { $0.iteration }).sorted()
            for iteration in iterationNumbers {
                let iterationMetrics = metrics.filter { $0.iteration == iteration }
                if !iterationMetrics.isEmpty {
                    let iterationLatencies = iterationMetrics.map { $0.latency }
                    let iterationAvg = iterationLatencies.reduce(0, +) / Double(iterationLatencies.count)
                    let iterationMin = iterationLatencies.min() ?? 0
                    let iterationMax = iterationLatencies.max() ?? 0
                    
                    timestampedPrint("   Iteration \(iteration): Avg=\(String(format: "%.3f", iterationAvg * 1000))ms, Min=\(String(format: "%.3f", iterationMin * 1000))ms, Max=\(String(format: "%.3f", iterationMax * 1000))ms (\(iterationMetrics.count) msgs)")
                }
            }
            
            // Performance warnings
            timestampedPrint("\n🚨 Performance Analysis:")
            let highLatencyThreshold = averageLatency * 3
            let highLatencyMessages = metrics.filter { $0.latency > highLatencyThreshold }
            
            if highLatencyMessages.isEmpty {
                timestampedPrint("   ✅ All message latencies are within acceptable range")
            } else {
                timestampedPrint("   ⚠️  \(highLatencyMessages.count) messages had high latency (>3x avg):")
                for msg in highLatencyMessages.prefix(5) {
                    timestampedPrint("      \(msg.messageKey): \(String(format: "%.3f", msg.latency * 1000))ms")
                }
            }
            
            // System recommendations
            timestampedPrint("\n💡 Performance Recommendations:")
            if averageLatency > 1.0 {
                timestampedPrint("   ⚠️  High average latency detected - consider system optimization")
            }
            if Double(metrics.count) / Double(expectedMessages) < 0.95 {
                timestampedPrint("   ⚠️  Low success rate - check network and system stability")
            }
            if maxLatency > averageLatency * 10 {
                timestampedPrint("   ⚠️  High latency variance detected - investigate system bottlenecks")
            }
            if messagesPerSecond < 100 {
                timestampedPrint("   ⚠️  Low throughput - consider increasing concurrency or optimizing message handling")
            }
            
            if averageLatency <= 0.1 && Double(metrics.count) / Double(expectedMessages) >= 0.99 && maxLatency <= averageLatency * 5 {
                timestampedPrint("   ✅ Excellent performance! System is operating optimally")
            }
            
            timestampedPrint(String(repeating: "=", count: 60))
        }
        
        private func exportMetricsToJSON(metrics: [MessageMetrics]) {
            let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
            let filename = "concurrent_messaging_metrics_\(timestamp.replacingOccurrences(of: ":", with: "-")).json"
            
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                
                let jsonData = try encoder.encode(metrics)
                try jsonData.write(to: URL(fileURLWithPath: filename))
                timestampedPrint("📁 Metrics exported to: \(filename)")
                
            } catch {
                timestampedPrint("❌ Failed to export metrics: \(error)")
            }
        }
        
        mutating func validate() throws {
            guard geteuid() == 0 else {
                throw ValidationError(
                    "Running concurrent messaging test requires Root privileges"
                )
            }
            
            guard iterations > 0 else {
                throw ValidationError("Iterations must be greater than 0")
            }
            
            guard timeout > 0 else {
                throw ValidationError("Timeout must be greater than 0")
            }
            
            guard messageDelay >= 0 else {
                throw ValidationError("Message delay must be non-negative")
            }
        }
    }
}

@main
public enum EnsembleCtlMain {
	public static func main() throws {
		EnsembleCtl.main()
	}
}
