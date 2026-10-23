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
//  ensemblectl.swift
//  ensemblectl
//
//  Created by Alex T Newman on 1/5/24.
//

import ArgumentParserInternal
import CryptoKit
import Foundation
import Network
import os

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
            ReceiveDataMessageAsync.self,
            BroadcastDataMessage.self,
            ConcurrentMessagingTest.self,
            ConcurrentSendToSingleFollower.self,
            HeartbeatTest.self,
            HeartbeatReceive.self
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
                
            } catch let dataError as DataMessageError {
                timestampedPrint("❌ Failed to send message: \(dataError.localizedDescription)")
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
        @Option(name: .long, help: "Milliseconds to sleep inside the callback before sending response (default: 100ms). Use 0 to disable.")
        var responseDelay: Int = 100

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
            if responseDelay > 0 {
                timestampedPrint("⏱️  Response delay: \(responseDelay)ms per message")
            }
            timestampedPrint("Listening for incoming messages... (Press Ctrl+C to stop)")

            // Capture the values we need to avoid mutating self capture
            let responseMessage = self.response
            let shouldReturnStats = self.stats
            let delayMs = self.responseDelay

            // Thread-safe counters for follower-side summary
            let receivedCountLock = OSAllocatedUnfairLock(initialState: 0)
            let respondedCountLock = OSAllocatedUnfairLock(initialState: 0)

            // SIGINT handler: print summary before exit
            signal(SIGINT, SIG_IGN)
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                let received = receivedCountLock.withLock { $0 }
                let responded = respondedCountLock.withLock { $0 }
                let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                print("")
                print("[\(ts)] " + String(repeating: "=", count: 50))
                print("[\(ts)] 📊 FOLLOWER SUMMARY")
                print("[\(ts)] " + String(repeating: "=", count: 50))
                print("[\(ts)]    Messages received:  \(received)")
                print("[\(ts)]    Messages responded: \(responded)")
                if received > 0 {
                    print("[\(ts)]    Response rate:      \(String(format: "%.1f", Double(responded) / Double(received) * 100))%")
                }
                print("[\(ts)] " + String(repeating: "=", count: 50))
                Foundation.exit(0)
            }
            sigintSource.resume()

            // Register the message handler
            try ensembler.registerDataCallback(appID: appID) { sender, receivedData in
                receivedCountLock.withLock { $0 += 1 }
                // Convert received data to string for display
                let receivedString = String(data: receivedData, encoding: .utf8) ?? "<binary data>"
                let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                print("[\(timestamp)] 📨 Received from rank \(sender): \(receivedString.prefix(80))")

                if delayMs > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(delayMs) / 1000.0)
                }

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
                        respondedCountLock.withLock { $0 += 1 }
                        return statsData
                    } else {
                        responseText = "Stats calculation failed"
                    }
                } else {
                    // Default: echo the message
                    responseText = "Echo: \(receivedString)"
                }

                respondedCountLock.withLock { $0 += 1 }
                let responseTimestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                print("[\(responseTimestamp)] 📤 Responding: \(responseText.prefix(80))")
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

    struct ReceiveDataMessageAsync: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "receive-data-message-async",
            abstract: "Register an async callback to receive data messages for an appID and respond to them. (Requires Root)"
        )
        @Argument(help: "The application ID to listen for messages.")
        var appID: String
        @Option(name: .shortAndLong, help: "Response message to send back (default: echo)")
        var response: String?
        @Flag(name: .shortAndLong, help: "Calculate and return message statistics")
        var stats: Bool = false
        @Option(name: .long, help: "Milliseconds to delay inside the callback before sending response (default: 100ms). Use 0 to disable.")
        var responseDelay: Int = 100

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

            timestampedPrint("Registering async data message handler for appID: '\(appID)'")
            if responseDelay > 0 {
                timestampedPrint("⏱️  Response delay: \(responseDelay)ms per message (non-blocking)")
            }
            timestampedPrint("Listening for incoming messages... (Press Ctrl+C to stop)")

            // Capture the values we need to avoid mutating self capture
            let responseMessage = self.response
            let shouldReturnStats = self.stats
            let delayMs = self.responseDelay

            // Thread-safe counters for follower-side summary
            let receivedCountLock = OSAllocatedUnfairLock(initialState: 0)
            let respondedCountLock = OSAllocatedUnfairLock(initialState: 0)

            // SIGINT handler: print summary before exit
            signal(SIGINT, SIG_IGN)
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                let received = receivedCountLock.withLock { $0 }
                let responded = respondedCountLock.withLock { $0 }
                let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                print("")
                print("[\(ts)] " + String(repeating: "=", count: 50))
                print("[\(ts)] 📊 FOLLOWER SUMMARY")
                print("[\(ts)] " + String(repeating: "=", count: 50))
                print("[\(ts)]    Messages received:  \(received)")
                print("[\(ts)]    Messages responded: \(responded)")
                if received > 0 {
                    print("[\(ts)]    Response rate:      \(String(format: "%.1f", Double(responded) / Double(received) * 100))%")
                }
                print("[\(ts)] " + String(repeating: "=", count: 50))
                Foundation.exit(0)
            }
            sigintSource.resume()

            // ParsableCommand.run() is sync, so bridge into async with a Task.
            // RunLoop.current.run() below keeps the process alive while messages arrive.
            
            // Capture all needed values to avoid capturing mutating 'self'
            let capturedAppID = self.appID
            
            Task(priority: .userInitiated) {
                do {
                    // Each invocation of this callback runs as an independent Swift Task —
                    // no GCD thread is held during await, enabling concurrent message handling.
                    try await ensembler.registerDataCallback(appID: capturedAppID) { sender, receivedData in
                        receivedCountLock.withLock { $0 += 1 }
                        let receivedString = String(data: receivedData, encoding: .utf8) ?? "<binary data>"
                        let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                        print("[\(timestamp)] 📨 Received from rank \(sender): \(receivedString.prefix(80))")

                        if delayMs > 0 {
                            try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                        }

                        // Generate response based on options
                        let responseText: String
                        if let customResponse = responseMessage {
                            responseText = customResponse
                        } else if shouldReturnStats {
                            let stats: [String: Any] = [
                                "bytes": receivedData.count,
                                "timestamp": ISO8601DateFormatter().string(from: Date()),
                                "isUTF8": receivedString != "<binary data>"
                            ]
                            if let statsData = try? JSONSerialization.data(withJSONObject: stats) {
                                respondedCountLock.withLock { $0 += 1 }
                                return statsData
                            } else {
                                responseText = "Stats calculation failed"
                            }
                        } else {
                            // Default: echo the message
                            responseText = "Echo: \(receivedString)"
                        }

                        respondedCountLock.withLock { $0 += 1 }
                        let responseTimestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                        print("[\(responseTimestamp)] 📤 Responding: \(responseText.prefix(80))")
                        return responseText.data(using: .utf8) ?? Data()
                    }
                    let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                    print("[\(timestamp)] Handler registered successfully. Waiting for messages...")
                } catch {
                    let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                    print("[\(timestamp)] Failed to register async handler: \(error)")
                    Foundation.exit(1)
                }
            }

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
                
            } catch let dataError as DataMessageError {
                timestampedPrint("❌ Failed to broadcast message: \(dataError.localizedDescription)")
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

    
    struct ConcurrentSendToSingleFollower: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send N messages concurrently to one follower and measure concurrency ratio. (Requires Root)"
        )
        
        @Argument(help: "Rank of the destination follower.")
        var destination: Int
        
        @Option(name: .shortAndLong, help: "Number of messages to send concurrently (default: 10)")
        var messageCount: Int = 10
        
        @Option(name: .shortAndLong, help: "Timeout per message in seconds (default: 10.0)")
        var timeout: Double = 10.0
        
        @Option(name: .shortAndLong, help: "Application ID for message routing (default: concurrent-single-test)")
        var appID: String = "concurrent-single-test"
        
        @Flag(name: .shortAndLong, help: "Enable verbose logging")
        var verbose: Bool = false
        
        @Flag(name: .shortAndLong, help: "Validate that each response contains the 'Echo: ' prefix (receiver must be running in default echo mode)")
        var validateResponses: Bool = false

        @Option(name: .long, help: "Milliseconds to wait between each batch of concurrent messages (default: 0 = no delay)")
        var intervalMs: Int = 0

        @Option(name: .long, help: "Total duration to run in minutes; sends --message-count messages per batch repeatedly until time expires (default: 0 = use --batch-count)")
        var durationMinutes: Double = 0

        @Option(name: .long, help: "Number of batches to run (default: 100); each batch sends --message-count messages concurrently. Ignored when --duration-minutes is set.")
        var batchCount: Int = 100

        private struct MessageMetrics {
            let index: Int
            let startTime: Date
            let endTime: Date
            let latency: TimeInterval
        }

        mutating func validate() throws {
            guard geteuid() == 0 else {
                throw ValidationError("Sending concurrent messages requires Root privileges")
            }
            guard messageCount > 0 else {
                throw ValidationError("messageCount must be greater than 0")
            }
            guard timeout > 0 else {
                throw ValidationError("timeout must be greater than 0")
            }
            guard destination >= 0 else {
                throw ValidationError("destination rank must be non-negative")
            }
            guard intervalMs >= 0 else {
                throw ValidationError("interval-ms must be non-negative")
            }
            guard durationMinutes >= 0 else {
                throw ValidationError("duration-minutes must be non-negative")
            }
            guard batchCount > 0 else {
                throw ValidationError("batch-count must be greater than 0")
            }
        }
        
        private func timestampedPrint(_ message: String) {
            let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
            print("[\(timestamp)] \(message)")
        }
        
        mutating func run() throws {
            let ensembler = try EnsemblerSession()

            let status = try ensembler.getStatus()
            guard status == .ready else {
                timestampedPrint("❌ Ensemble is not ready. Status: \(status)")
                Foundation.exit(1)
            }

            guard durationMinutes <= 0 else {
                runDuration(ensembler: ensembler)
                return
            }

            runBatches(ensembler: ensembler)
        }

        private func runBatches(ensembler: EnsemblerSession) {
            let testStart = Date()
            var totalSucceeded = 0
            var totalFailed = 0
            var totalNotReady = 0
            var overallMin = Double.infinity
            var overallMax = 0.0
            var totalSumLat = 0.0
            var allLatencies = [Double]()
            var totalValidated = 0
            var totalValidationFailed = 0
            var totalFailureReasons = [String: Int]()
            var totalActiveBatchTime = 0.0       // sum of per-batch wall-clock times (excl. intervals)
            var totalConcurrencyRatioSum = 0.0   // for computing average concurrency ratio
            var batchesWithConcurrency = 0

            let capturedDest     = destination
            let capturedAppID    = appID
            let capturedTimeout  = timeout
            let capturedVerbose  = verbose
            let capturedCount    = messageCount
            let capturedInterval = intervalMs
            let capturedValidate = validateResponses
            let capturedBatches  = batchCount

            timestampedPrint("🚀 ConcurrentSendToSingleFollower: \(capturedCount) msgs/batch × \(capturedBatches) batches → rank \(capturedDest)")
            timestampedPrint("   App ID: \(capturedAppID) | Timeout: \(capturedTimeout)s | Interval: \(capturedInterval)ms")

            for batch in 1...capturedBatches {
                let group             = DispatchGroup()
                let metricsLock       = OSAllocatedUnfairLock(initialState: [MessageMetrics]())
                let batchFailureLock  = OSAllocatedUnfairLock(initialState: [String: Int]())
                let batchNotReadyLock = OSAllocatedUnfairLock(initialState: 0)
                let batchValLock      = OSAllocatedUnfairLock(initialState: (ok: 0, fail: 0))
                let pendingLock       = OSAllocatedUnfairLock(initialState: [Int: Date]())

                for index in 1...capturedCount {
                    let message = "Batch\(batch)-\(UUID().uuidString)-Msg[\(index)]"
                    group.enter()
                    Task(priority: .userInitiated) {
                        defer {
                            pendingLock.withLock { $0.removeValue(forKey: index) }
                            group.leave()
                        }
                        let sendTime = Date()
                        pendingLock.withLock { $0[index] = sendTime }
                        do {
                            let responseData = try await withDeadline(seconds: capturedTimeout + 3.0) {
                                try await ensembler.sendDataAndGetResponse(
                                    appID: capturedAppID,
                                    data: message.data(using: .utf8)!,
                                    destination: capturedDest,
                                    timeout: capturedTimeout
                                )
                            }
                            let lat = Date().timeIntervalSince(sendTime)
                            if capturedValidate {
                                let responseStr = String(data: responseData, encoding: .utf8) ?? ""
                                let expected = "Echo: \(message)"
                                if responseStr != expected {
                                    batchFailureLock.withLock { $0["validation mismatch", default: 0] += 1 }
                                    batchValLock.withLock { $0.fail += 1 }
                                    if capturedVerbose {
                                        let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                        print("[\(ts)] ❌ Batch \(batch) msg \(index) validation FAILED — expected '\(expected.prefix(60))', got: '\(responseStr.prefix(60))'")
                                    }
                                    return
                                } else {
                                    batchValLock.withLock { $0.ok += 1 }
                                }
                            }
                            metricsLock.withLock { $0.append(MessageMetrics(index: index, startTime: sendTime, endTime: Date(), latency: lat)) }
                            if capturedVerbose {
                                let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                let resp = String(data: responseData, encoding: .utf8) ?? "<binary>"
                                print("[\(ts)] ← Batch \(batch) msg \(index) in \(String(format: "%.3f", lat * 1000))ms: \(resp.prefix(60))")
                            }
                        } catch {
                            let reason = ConcurrentSendToSingleFollower.failureReason(error)
                            let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                            batchFailureLock.withLock { $0[reason, default: 0] += 1 }
                            if reason == "not ready" { batchNotReadyLock.withLock { $0 += 1 } }
                            print("[\(ts)] ❌ Batch \(batch) msg \(index) failed after \(String(format: "%.0f", Date().timeIntervalSince(sendTime) * 1000))ms: \(error)")
                        }
                    }
                }

                let batchWait = DispatchTime.now() + capturedTimeout + 5.0
                if group.wait(timeout: batchWait) == .timedOut {
                    let stuck = pendingLock.withLock { $0 }
                    let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                    print("[\(ts)] 🚨 Batch \(batch) HUNG — \(stuck.count) message(s) still pending after \(String(format: "%.0f", capturedTimeout + 5.0))s")
                }

                let batchMetrics  = metricsLock.withLock { $0 }
                let batchReasons  = batchFailureLock.withLock { $0 }
                let batchVal      = batchValLock.withLock { $0 }
                let batchFailed   = batchReasons.values.reduce(0, +)
                let batchElapsed  = Date().timeIntervalSince(testStart)

                for (reason, count) in batchReasons { totalFailureReasons[reason, default: 0] += count }
                totalSucceeded        += batchMetrics.count
                totalFailed           += batchFailed
                totalNotReady         += batchNotReadyLock.withLock { $0 }
                totalValidated        += batchVal.ok
                totalValidationFailed += batchVal.fail
                for m in batchMetrics {
                    allLatencies.append(m.latency)
                    totalSumLat += m.latency
                    if m.latency < overallMin { overallMin = m.latency }
                    if m.latency > overallMax { overallMax = m.latency }
                }

                // Per-batch concurrency ratio and throughput
                var batchAvgMs         = 0.0
                var batchThroughput    = 0.0
                var batchConcurrency   = 0.0
                if !batchMetrics.isEmpty,
                   let firstSend = batchMetrics.map({ $0.startTime }).min(),
                   let lastEnd   = batchMetrics.map({ $0.endTime }).max() {
                    let batchWall     = lastEnd.timeIntervalSince(firstSend)
                    let batchSumLat   = batchMetrics.map { $0.latency }.reduce(0, +)
                    batchAvgMs        = batchSumLat / Double(batchMetrics.count) * 1000
                    if batchWall > 0 {
                        batchThroughput  = Double(batchMetrics.count) / batchWall
                        batchConcurrency = batchSumLat / batchWall
                        totalActiveBatchTime     += batchWall
                        totalConcurrencyRatioSum += batchConcurrency
                        batchesWithConcurrency   += 1
                    }
                }

                let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                if batchFailed > 0 {
                    let reasons = batchReasons.sorted(by: { $0.value > $1.value }).map { "\($0.key):\($0.value)" }.joined(separator: ", ")
                    print("[\(ts)] ⚠️  Batch \(batch)/\(capturedBatches) — succeeded=\(batchMetrics.count) failed=\(batchFailed) avg-latency=\(String(format: "%.1f", batchAvgMs))ms throughput=\(String(format: "%.1f", batchThroughput))/s concurrency=\(String(format: "%.2f", batchConcurrency)) — \(reasons)")
                } else if batch % 10 == 0 || batch == capturedBatches {
                    print("[\(ts)] 📊 Batch \(batch)/\(capturedBatches) — succeeded=\(batchMetrics.count) avg-latency=\(String(format: "%.1f", batchAvgMs))ms throughput=\(String(format: "%.1f", batchThroughput))/s concurrency=\(String(format: "%.2f", batchConcurrency)) | cumulative: succeeded=\(totalSucceeded) failed=\(totalFailed) elapsed=\(String(format: "%.1f", batchElapsed))s")
                }

                if capturedInterval > 0 && batch < capturedBatches {
                    Thread.sleep(forTimeInterval: TimeInterval(capturedInterval) / 1000.0)
                }
            }

            // ── Leader-side final summary ────────────────────────────────────
            let elapsed   = Date().timeIntervalSince(testStart)
            let totalSent = totalSucceeded + totalFailed

            timestampedPrint("\n" + String(repeating: "=", count: 60))
            timestampedPrint("📊 CONCURRENT SEND TO SINGLE FOLLOWER — FINAL SUMMARY")
            timestampedPrint(String(repeating: "=", count: 60))
            timestampedPrint("   Batches:          \(capturedBatches)")
            timestampedPrint("   Msgs/batch:       \(capturedCount) concurrent")
            timestampedPrint("   Total sent:       \(totalSent)")
            timestampedPrint("   Succeeded:        \(totalSucceeded)")
            timestampedPrint("   Failed:           \(totalFailed)")
            if totalNotReady > 0 {
                timestampedPrint("   Not ready:        \(totalNotReady) (counted in failed; excluded from rate)")
            }
            timestampedPrint("   Elapsed:          \(formatDuration(elapsed))")

            if !totalFailureReasons.isEmpty {
                timestampedPrint("\n❌ Failure Breakdown:")
                for (reason, count) in totalFailureReasons.sorted(by: { $0.value > $1.value }) {
                    timestampedPrint("   \(reason): \(count)")
                }
            }

            let rateBase = totalSent - totalNotReady
            if rateBase > 0 {
                let note = totalNotReady > 0 ? " (excl. \(totalNotReady) not-ready)" : ""
                timestampedPrint("   Success rate:     \(String(format: "%.2f", Double(totalSucceeded) / Double(rateBase) * 100))%\(note)")
            }

            // Throughput and latency — excluding failures
            if totalSucceeded > 0 {
                let throughput = totalActiveBatchTime > 0 ? Double(totalSucceeded) / totalActiveBatchTime : Double(totalSucceeded) / elapsed
                let avgMs      = totalSumLat / Double(totalSucceeded) * 1000
                let minMs      = overallMin == .infinity ? 0.0 : overallMin * 1000
                let maxMs      = overallMax * 1000
                let sorted     = allLatencies.sorted()
                let p50Ms      = sorted[min(Int(Double(sorted.count) * 0.50), sorted.count - 1)] * 1000
                let p95Ms      = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)] * 1000
                let p99Ms      = sorted[min(Int(Double(sorted.count) * 0.99), sorted.count - 1)] * 1000

                timestampedPrint("\n⚡ Performance (successful messages only):")
                timestampedPrint("   Throughput:       \(String(format: "%.2f", throughput)) msgs/sec (active time)")
                timestampedPrint("   Latency avg:      \(String(format: "%.1f", avgMs))ms")
                timestampedPrint("   Latency min:      \(String(format: "%.1f", minMs))ms")
                timestampedPrint("   Latency max:      \(String(format: "%.1f", maxMs))ms")
                timestampedPrint("   Latency P50:      \(String(format: "%.1f", p50Ms))ms")
                timestampedPrint("   Latency P95:      \(String(format: "%.1f", p95Ms))ms")
                timestampedPrint("   Latency P99:      \(String(format: "%.1f", p99Ms))ms")

                if batchesWithConcurrency > 0 {
                    let avgConc    = totalConcurrencyRatioSum / Double(batchesWithConcurrency)
                    let idealConc  = Double(capturedCount)
                    let concPct    = min(avgConc / idealConc * 100.0, 100.0)
                    timestampedPrint("\n🔀 Concurrency (avg per batch):")
                    timestampedPrint("   Ratio:            \(String(format: "%.2f", avgConc)) / \(capturedCount) ideal (\(String(format: "%.1f", concPct))%)")
                    if avgConc < 1.5 {
                        timestampedPrint("   ⚠️  Sends appear serialized — receiver may be blocking between responses")
                    } else if concPct >= 80.0 {
                        timestampedPrint("   ✅ Good concurrency — receiver processes messages in parallel")
                    } else {
                        timestampedPrint("   ⚠️  Partial concurrency — some serialization detected")
                    }
                }
            }

            // Response validation summary
            if capturedValidate {
                let validTotal = totalValidated + totalValidationFailed
                timestampedPrint("\n✅ Response Validation (excluding send failures):")
                if validTotal > 0 {
                    timestampedPrint("   Validated OK:     \(totalValidated)/\(validTotal) (\(String(format: "%.1f", Double(totalValidated) / Double(validTotal) * 100))%)")
                }
                if totalValidationFailed > 0 {
                    timestampedPrint("   ❌ Validation failures: \(totalValidationFailed)")
                } else if totalSucceeded > 0 {
                    timestampedPrint("   ✅ All received responses validated correctly")
                }
            } else if totalSucceeded > 0 {
                timestampedPrint("\n   ℹ️  Response validation skipped (use --validate-responses to enable)")
            }

            timestampedPrint(String(repeating: "=", count: 60))

            if totalFailed > 0 || totalValidationFailed > 0 {
                timestampedPrint("❌ Test completed with issues.")
                Foundation.exit(1)
            }
            timestampedPrint("✅ All \(totalSent) messages succeeded across \(capturedBatches) batches.")
        }

        private func runDuration(ensembler: EnsemblerSession) {
            let deadline       = Date().addingTimeInterval(durationMinutes * 60)
            let testStart      = Date()
            var batchNum       = 0
            var totalSucceeded = 0
            var totalFailed    = 0
            var totalNotReady  = 0
            var overallMin     = Double.infinity
            var overallMax     = 0.0
            var totalSumLat    = 0.0
            var lastProgressAt = Date()
            var totalFailureReasons = [String: Int]()
            var totalActiveBatchTime    = 0.0
            var totalConcurrencyRatioSum = 0.0
            var batchesWithConcurrency  = 0

            let capturedDest     = destination
            let capturedAppID    = appID
            let capturedTimeout  = timeout
            let capturedCount    = messageCount
            let capturedInterval = intervalMs
            let capturedValidate = validateResponses

            timestampedPrint("🕐 Duration test: \(durationMinutes)min | \(capturedCount) msg/batch | interval \(capturedInterval)ms")
            timestampedPrint("   Destination rank \(capturedDest) | App ID: \(capturedAppID) | Timeout: \(capturedTimeout)s")

            while Date() < deadline {
                batchNum += 1
                let group         = DispatchGroup()
                let statsLock     = OSAllocatedUnfairLock(
                    initialState: (succeeded: 0, failed: 0, minLat: Double.infinity, maxLat: 0.0, sumLat: 0.0,
                                   firstSend: Date.distantFuture, lastEnd: Date.distantPast)
                )
                let batchReasonsLock = OSAllocatedUnfairLock(initialState: [String: Int]())
                let batchNotReadyLock = OSAllocatedUnfairLock(initialState: 0)
                let capturedBatch = batchNum
                let pendingLock = OSAllocatedUnfairLock(initialState: [Int: Date]())
                let batchStart = Date()

                for index in 1...capturedCount {
                    let message = "Batch\(capturedBatch)-\(UUID().uuidString)-Msg[\(index)]"
                    group.enter()
                    Task(priority: .userInitiated) {
                        defer {
                            pendingLock.withLock { $0.removeValue(forKey: index) }
                            group.leave()
                        }
                        let sendTime = Date()
                        pendingLock.withLock { $0[index] = sendTime }
                        do {
                            let responseData = try await withDeadline(seconds: capturedTimeout + 3.0) {
                                try await ensembler.sendDataAndGetResponse(
                                    appID: capturedAppID,
                                    data: message.data(using: .utf8)!,
                                    destination: capturedDest,
                                    timeout: capturedTimeout
                                )
                            }
                            let endTime = Date()
                            let lat = endTime.timeIntervalSince(sendTime)
                            if capturedValidate {
                                let responseStr = String(data: responseData, encoding: .utf8) ?? ""
                                let expected = "Echo: \(message)"
                                if responseStr != expected {
                                    let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                    print("[\(ts)] ❌ Batch \(capturedBatch) msg \(index) validation FAILED — expected '\(expected.prefix(80))', got: '\(responseStr.prefix(80))'")
                                    statsLock.withLock { $0.failed += 1 }
                                    batchReasonsLock.withLock { $0["validation mismatch", default: 0] += 1 }
                                    return
                                }
                            }
                            statsLock.withLock { s in
                                s.succeeded += 1
                                if lat < s.minLat { s.minLat = lat }
                                if lat > s.maxLat { s.maxLat = lat }
                                s.sumLat += lat
                                if sendTime < s.firstSend { s.firstSend = sendTime }
                                if endTime  > s.lastEnd   { s.lastEnd   = endTime  }
                            }
                        } catch {
                            let reason = ConcurrentSendToSingleFollower.failureReason(error)
                            statsLock.withLock { $0.failed += 1 }
                            batchReasonsLock.withLock { $0[reason, default: 0] += 1 }
                            if reason == "not ready" { batchNotReadyLock.withLock { $0 += 1 } }
                            let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                            print("[\(ts)] ❌ Batch \(capturedBatch) msg \(index) failed after \(String(format: "%.0f", Date().timeIntervalSince(sendTime) * 1000))ms: \(error)")
                            if case .timeoutOnPeerHandler = error as? DataMessageError {
                                print("[\(ts)]    ↳ Hint: verify 'receive-data-message' on rank \(capturedDest) for appID '\(capturedAppID)'")
                            }
                        }
                    }
                }
                let batchWaitTimeout = DispatchTime.now() + capturedTimeout + 5.0
                if group.wait(timeout: batchWaitTimeout) == .timedOut {
                    let stuck = pendingLock.withLock { $0 }
                    let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                    print("[\(ts)] 🚨 Batch \(batchNum) HUNG — \(stuck.count) message(s) stuck after \(String(format: "%.0f", capturedTimeout + 5.0))s:")
                    for (idx, t) in stuck.sorted(by: { $0.key < $1.key }) {
                        print("[\(ts)]    msg \(idx) waiting \(String(format: "%.1f", Date().timeIntervalSince(t)))s (appID: '\(capturedAppID)', dest: rank \(capturedDest))")
                    }
                }

                let s = statsLock.withLock { $0 }
                let batchReasons = batchReasonsLock.withLock { $0 }
                let batchElapsed = Date().timeIntervalSince(batchStart)

                // Per-batch concurrency ratio
                var batchConcurrency = 0.0
                var batchThroughput  = 0.0
                let batchWall = s.lastEnd.timeIntervalSince(s.firstSend)
                if batchWall > 0 && s.succeeded > 0 {
                    batchConcurrency = s.sumLat / batchWall
                    batchThroughput  = Double(s.succeeded) / batchWall
                    totalActiveBatchTime     += batchWall
                    totalConcurrencyRatioSum += batchConcurrency
                    batchesWithConcurrency   += 1
                }

                if s.failed > 0 {
                    let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                    let reasons = batchReasons.sorted(by: { $0.value > $1.value }).map { "\($0.key):\($0.value)" }.joined(separator: ", ")
                    let avgMs = s.succeeded > 0 ? s.sumLat / Double(s.succeeded) * 1000 : 0
                    print("[\(ts)] ⚠️  Batch \(batchNum) — succeeded=\(s.succeeded) failed=\(s.failed) in \(String(format: "%.0f", batchElapsed * 1000))ms avg-latency=\(String(format: "%.1f", avgMs))ms throughput=\(String(format: "%.1f", batchThroughput))/s concurrency=\(String(format: "%.2f", batchConcurrency)) — \(reasons)")
                }
                for (reason, count) in batchReasons {
                    totalFailureReasons[reason, default: 0] += count
                }
                totalSucceeded += s.succeeded
                totalFailed    += s.failed
                totalNotReady  += batchNotReadyLock.withLock { $0 }
                if s.minLat < overallMin { overallMin = s.minLat }
                if s.maxLat > overallMax { overallMax = s.maxLat }
                totalSumLat    += s.sumLat

                if Date().timeIntervalSince(lastProgressAt) >= 60 {
                    let elapsed   = Date().timeIntervalSince(testStart)
                    let remaining = max(0, deadline.timeIntervalSinceNow)
                    let sent      = totalSucceeded + totalFailed
                    let avgMs     = totalSucceeded > 0 ? totalSumLat / Double(totalSucceeded) * 1000 : 0
                    let tput      = totalActiveBatchTime > 0 ? Double(totalSucceeded) / totalActiveBatchTime : 0
                    let avgConc   = batchesWithConcurrency > 0 ? totalConcurrencyRatioSum / Double(batchesWithConcurrency) : 0
                    timestampedPrint(
                        "📊 batch=\(batchNum) elapsed=\(formatDuration(elapsed)) remaining=\(formatDuration(remaining))" +
                        " sent=\(sent) succeeded=\(totalSucceeded) failed=\(totalFailed)" +
                        " avg-latency=\(String(format: "%.1f", avgMs))ms throughput=\(String(format: "%.1f", tput))/s concurrency=\(String(format: "%.2f", avgConc))"
                    )
                    if !totalFailureReasons.isEmpty {
                        let reasonSummary = totalFailureReasons.sorted(by: { $0.value > $1.value })
                            .map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                        timestampedPrint("   Failures by reason: \(reasonSummary)")
                    }
                    lastProgressAt = Date()
                }

                if capturedInterval > 0 && Date() < deadline {
                    Thread.sleep(forTimeInterval: TimeInterval(capturedInterval) / 1000.0)
                }
            }

            let elapsed   = Date().timeIntervalSince(testStart)
            let sent      = totalSucceeded + totalFailed
            let avgMs     = totalSucceeded > 0 ? totalSumLat / Double(totalSucceeded) * 1000 : 0
            let minMs     = overallMin == .infinity ? 0 : overallMin * 1000
            let maxMs     = overallMax * 1000
            let tput      = totalActiveBatchTime > 0 ? Double(totalSucceeded) / totalActiveBatchTime : 0
            let avgConc   = batchesWithConcurrency > 0 ? totalConcurrencyRatioSum / Double(batchesWithConcurrency) : 0

            timestampedPrint("\n" + String(repeating: "=", count: 60))
            timestampedPrint("📊 DURATION TEST SUMMARY — SINGLE FOLLOWER")
            timestampedPrint(String(repeating: "=", count: 60))
            timestampedPrint("   Target duration:  \(durationMinutes)min")
            timestampedPrint("   Elapsed:          \(formatDuration(elapsed))")
            timestampedPrint("   Batches run:      \(batchNum)")
            timestampedPrint("   Messages/batch:   \(capturedCount)")
            timestampedPrint("   Interval:         \(capturedInterval)ms")
            timestampedPrint("   Total sent:       \(sent)")
            timestampedPrint("   Succeeded:        \(totalSucceeded)")
            timestampedPrint("   Failed:           \(totalFailed)")
            if totalNotReady > 0 {
                timestampedPrint("   Not ready:        \(totalNotReady) (counted in failed; excluded from rate)")
            }
            if !totalFailureReasons.isEmpty {
                timestampedPrint("\n❌ Failure Breakdown:")
                for (reason, count) in totalFailureReasons.sorted(by: { $0.value > $1.value }) {
                    timestampedPrint("   \(reason): \(count)")
                }
            }
            let rateBase2 = sent - totalNotReady
            if rateBase2 > 0 {
                let note = totalNotReady > 0 ? " (excl. \(totalNotReady) not-ready)" : ""
                timestampedPrint("   Success rate:     \(String(format: "%.2f", Double(totalSucceeded) / Double(rateBase2) * 100))%\(note)")
            }
            if totalSucceeded > 0 {
                timestampedPrint("\n⚡ Performance (successful messages only):")
                timestampedPrint("   Throughput:       \(String(format: "%.2f", tput)) msgs/sec (active time)")
                timestampedPrint("   Latency avg:      \(String(format: "%.1f", avgMs))ms")
                timestampedPrint("   Latency min:      \(String(format: "%.1f", minMs))ms")
                timestampedPrint("   Latency max:      \(String(format: "%.1f", maxMs))ms")
                if batchesWithConcurrency > 0 {
                    let idealConc = Double(capturedCount)
                    let concPct   = min(avgConc / idealConc * 100.0, 100.0)
                    timestampedPrint("\n🔀 Concurrency (avg per batch):")
                    timestampedPrint("   Ratio:            \(String(format: "%.2f", avgConc)) / \(capturedCount) ideal (\(String(format: "%.1f", concPct))%)")
                    if avgConc < 1.5 {
                        timestampedPrint("   ⚠️  Sends appear serialized — receiver may be blocking between responses")
                    } else if concPct >= 80.0 {
                        timestampedPrint("   ✅ Good concurrency")
                    } else {
                        timestampedPrint("   ⚠️  Partial concurrency — some serialization detected")
                    }
                }
            }
            timestampedPrint(String(repeating: "=", count: 60))

            if totalFailed > 0 {
                timestampedPrint("❌ Duration test completed with \(totalFailed) failure(s).")
                Foundation.exit(1)
            }
            timestampedPrint("✅ Duration test completed successfully.")
        }

        private func formatDuration(_ seconds: TimeInterval) -> String {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            let s = Int(seconds) % 60
            if h > 0 { return "\(h)h \(m)m \(s)s" }
            if m > 0 { return "\(m)m \(s)s" }
            return "\(s)s"
        }

        private static func failureReason(_ error: Error) -> String {
            if error is XPCDeadlineExceededError { return "XPC deadline exceeded (ensembled silent)" }
            if let dataErr = error as? DataMessageError {
                switch dataErr {
                case .notReady:             return "not ready"
                case .timeoutOnPeerHandler: return "timeout (peer handler)"
                case .noResponseReceived:   return "timeout (no response)"
                case .noRegisteredHandler:  return "no registered handler"
                case .internalError:        return "internal error"
                }
            }
            // Fallback: older daemon versions may surface errors as generic strings
            let desc = String(describing: error).lowercased()
            if desc.contains("timeoutonpeerhandler") || desc.contains("timeout on peer") { return "timeout (peer handler)" }
            if desc.contains("notready") || desc.contains("not ready") { return "not ready" }
            if desc.contains("timeout") { return "timeout (no response)" }
            if desc.contains("noregisteredhandler") || desc.contains("no registered handler") { return "no registered handler" }
            if desc.contains("internalerror") || desc.contains("internal error") { return "internal error" }
            return String(String(describing: error).prefix(60))
        }
    }

    struct ConcurrentMessagingTest: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Send concurrent messages from leader to all followers and collect performance metrics. (Requires Root)"
            )
            
            @Option(name: .shortAndLong, help: "Number of messages per follower per batch (default: 10)")
            var iterations: Int = 10
            
            @Option(name: .shortAndLong, help: "Timeout per message in seconds (default: 10.0)")
            var timeout: Double = 10.0
            
            @Option(name: .shortAndLong, help: "Application ID for message routing (default: concurrent-test)")
            var appID: String = "concurrent-test"
            
            @Flag(name: .shortAndLong, help: "Enable verbose logging")
            var verbose: Bool = false
            
            @Flag(name: .shortAndLong, help: "Validate message responses (check for Echo: prefix)")
            var validateResponses: Bool = false
            
            @Option(name: .long, help: "Delay in milliseconds before each concurrent send (default: 0). Applied inside each concurrent Task, so all sends are dispatched simultaneously.")
            var messageDelay: Int = 0

            @Option(name: .long, help: "Milliseconds to wait between each batch of concurrent messages (default: 0 = no delay)")
            var intervalMs: Int = 0

            @Option(name: .long, help: "Total duration to run in minutes; sends --iterations messages per follower per batch repeatedly until time expires (default: 0 = use --batch-count)")
            var durationMinutes: Double = 0

            @Option(name: .long, help: "Number of batches to run (default: 100); each batch sends --iterations × follower-count messages concurrently. Ignored when --duration-minutes is set.")
            var batchCount: Int = 100
            
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
                let peerInfo = try ensembler.getPeerInfo()
                let totalNodes = peerInfo!.count + 1
                let followerCount = totalNodes - 1 // Exclude leader

                guard followerCount > 0 else {
                    timestampedPrint("❌ Error: No followers found in ensemble")
                    Foundation.exit(1)
                }

                guard durationMinutes <= 0 else {
                    runDuration(ensembler: ensembler, followerCount: followerCount)
                    return
                }

                runBatches(ensembler: ensembler, followerCount: followerCount, totalNodes: totalNodes)
            }

            private func runBatches(ensembler: EnsemblerSession, followerCount: Int, totalNodes: Int) {
                let testStart       = Date()
                var totalSucceeded  = 0
                var totalFailed     = 0
                var totalNotReady   = 0
                var overallMin      = Double.infinity
                var overallMax      = 0.0
                var totalSumLat     = 0.0
                var allLatencies    = [Double]()
                var totalValidOK    = 0
                var totalValidFail  = 0
                var totalFailureReasons = [String: Int]()
                var allMetrics      = [MessageMetrics]()
                var totalActiveBatchTime    = 0.0
                var totalConcurrencyRatioSum = 0.0
                var batchesWithConcurrency  = 0

                let capturedAppID    = appID
                let capturedTimeout  = timeout
                let capturedVerbose  = verbose
                let capturedValidate = validateResponses
                let capturedMsgDelay = messageDelay
                let capturedInterval = intervalMs
                let capturedIter     = iterations
                let capturedBatches  = batchCount
                let msgsPerBatch     = capturedIter * followerCount

                timestampedPrint("🚀 ConcurrentMessagingTest: \(capturedIter) msgs/follower × \(followerCount) follower(s) = \(msgsPerBatch) msgs/batch × \(capturedBatches) batches")
                timestampedPrint("   Ensemble: \(totalNodes) nodes | App ID: \(capturedAppID) | Timeout: \(capturedTimeout)s | Interval: \(capturedInterval)ms")

                for batch in 1...capturedBatches {
                    let group            = DispatchGroup()
                    let metricsLock      = OSAllocatedUnfairLock(initialState: [MessageMetrics]())
                    let batchFailureLock = OSAllocatedUnfairLock(initialState: [String: Int]())
                    let batchNotReadyLock = OSAllocatedUnfairLock(initialState: 0)
                    let batchValLock     = OSAllocatedUnfairLock(initialState: (ok: 0, fail: 0))
                    let pendingLock      = OSAllocatedUnfairLock(initialState: [String: Date]())

                    for iteration in 1...capturedIter {
                        for followerRank in 1...followerCount {
                            let message    = "Batch\(batch)-\(UUID().uuidString)-Iter[\(iteration)]-Rank[\(followerRank)]"
                            let messageKey = "b\(batch)_f\(followerRank)_i\(iteration)"
                            group.enter()
                            Task(priority: .userInitiated) {
                                defer {
                                    pendingLock.withLock { $0.removeValue(forKey: messageKey) }
                                    group.leave()
                                }
                                if capturedMsgDelay > 0 {
                                    try? await Task.sleep(nanoseconds: UInt64(capturedMsgDelay) * 1_000_000)
                                }
                                let sendTime = Date()
                                pendingLock.withLock { $0[messageKey] = sendTime }
                                do {
                                    let responseData = try await withDeadline(seconds: capturedTimeout + 3.0) {
                                        try await ensembler.sendDataAndGetResponse(
                                            appID: capturedAppID,
                                            data: message.data(using: .utf8)!,
                                            destination: followerRank,
                                            timeout: capturedTimeout
                                        )
                                    }
                                    let lat = Date().timeIntervalSince(sendTime)
                                    guard let responseStr = String(data: responseData, encoding: .utf8) else {
                                        batchFailureLock.withLock { $0["non-UTF8 response", default: 0] += 1 }
                                        return
                                    }
                                    var validResponse = true
                                    if capturedValidate {
                                        let expected = "Echo: \(message)"
                                        if responseStr != expected {
                                            validResponse = false
                                            batchValLock.withLock { $0.fail += 1 }
                                            if capturedVerbose {
                                                let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                                print("[\(ts)] ❌ \(messageKey) validation FAILED — expected '\(expected.prefix(60))', got: '\(responseStr.prefix(60))'")
                                            }
                                        } else {
                                            batchValLock.withLock { $0.ok += 1 }
                                        }
                                    }
                                    metricsLock.withLock {
                                        $0.append(MessageMetrics(
                                            messageKey: messageKey, startTime: sendTime, endTime: Date(),
                                            latency: lat, followerRank: followerRank, iteration: iteration,
                                            originalMessage: message, receivedResponse: responseStr, validResponse: validResponse
                                        ))
                                    }
                                    if capturedVerbose {
                                        let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                        print("[\(ts)] ✅ \(messageKey): \(String(format: "%.3f", lat * 1000))ms")
                                    }
                                } catch {
                                    let reason = ConcurrentMessagingTest.failureReason(error)
                                    let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                    batchFailureLock.withLock { $0[reason, default: 0] += 1 }
                                    if reason == "not ready" { batchNotReadyLock.withLock { $0 += 1 } }
                                    print("[\(ts)] ❌ \(messageKey) failed after \(String(format: "%.0f", Date().timeIntervalSince(sendTime) * 1000))ms: \(error)")
                                }
                            }
                        }
                    }

                    let batchWait = DispatchTime.now() + capturedTimeout + 5.0
                    if group.wait(timeout: batchWait) == .timedOut {
                        let stuck = pendingLock.withLock { $0 }
                        let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                        print("[\(ts)] 🚨 Batch \(batch) HUNG — \(stuck.count) message(s) still pending")
                    }

                    let batchMetrics = metricsLock.withLock { $0 }
                    let batchReasons = batchFailureLock.withLock { $0 }
                    let batchVal     = batchValLock.withLock { $0 }
                    let batchFailed  = batchReasons.values.reduce(0, +)
                    let batchElapsed = Date().timeIntervalSince(testStart)

                    for (reason, count) in batchReasons { totalFailureReasons[reason, default: 0] += count }
                    totalSucceeded += batchMetrics.count
                    totalFailed    += batchFailed
                    totalNotReady  += batchNotReadyLock.withLock { $0 }
                    totalValidOK   += batchVal.ok
                    totalValidFail += batchVal.fail
                    for m in batchMetrics {
                        allLatencies.append(m.latency)
                        totalSumLat += m.latency
                        if m.latency < overallMin { overallMin = m.latency }
                        if m.latency > overallMax { overallMax = m.latency }
                    }
                    allMetrics.append(contentsOf: batchMetrics)

                    // Per-batch concurrency ratio and throughput
                    var batchAvgMs       = 0.0
                    var batchThroughput  = 0.0
                    var batchConcurrency = 0.0
                    if !batchMetrics.isEmpty,
                       let firstSend = batchMetrics.map({ $0.startTime }).min(),
                       let lastEnd   = batchMetrics.map({ $0.endTime }).max() {
                        let batchWall   = lastEnd.timeIntervalSince(firstSend)
                        let batchSumLat = batchMetrics.map { $0.latency }.reduce(0, +)
                        batchAvgMs      = batchSumLat / Double(batchMetrics.count) * 1000
                        if batchWall > 0 {
                            batchThroughput  = Double(batchMetrics.count) / batchWall
                            batchConcurrency = batchSumLat / batchWall
                            totalActiveBatchTime     += batchWall
                            totalConcurrencyRatioSum += batchConcurrency
                            batchesWithConcurrency   += 1
                        }
                    }

                    let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                    if batchFailed > 0 {
                        let reasons = batchReasons.sorted(by: { $0.value > $1.value }).map { "\($0.key):\($0.value)" }.joined(separator: ", ")
                        print("[\(ts)] ⚠️  Batch \(batch)/\(capturedBatches) — succeeded=\(batchMetrics.count) failed=\(batchFailed) avg-latency=\(String(format: "%.1f", batchAvgMs))ms throughput=\(String(format: "%.1f", batchThroughput))/s concurrency=\(String(format: "%.2f", batchConcurrency)) — \(reasons)")
                    } else if batch % 10 == 0 || batch == capturedBatches {
                        print("[\(ts)] 📊 Batch \(batch)/\(capturedBatches) — succeeded=\(batchMetrics.count) avg-latency=\(String(format: "%.1f", batchAvgMs))ms throughput=\(String(format: "%.1f", batchThroughput))/s concurrency=\(String(format: "%.2f", batchConcurrency)) | cumulative: succeeded=\(totalSucceeded) failed=\(totalFailed) elapsed=\(String(format: "%.1f", batchElapsed))s")
                    }

                    if capturedInterval > 0 && batch < capturedBatches {
                        Thread.sleep(forTimeInterval: TimeInterval(capturedInterval) / 1000.0)
                    }
                }

                // ── Leader-side final summary ────────────────────────────────
                let elapsed   = Date().timeIntervalSince(testStart)
                let totalSent = totalSucceeded + totalFailed

                timestampedPrint("\n" + String(repeating: "=", count: 60))
                timestampedPrint("📊 CONCURRENT MESSAGING TEST — FINAL SUMMARY")
                timestampedPrint(String(repeating: "=", count: 60))
                timestampedPrint("   Batches:          \(capturedBatches)")
                timestampedPrint("   Msgs/batch:       \(msgsPerBatch) (\(capturedIter)/follower × \(followerCount) followers)")
                timestampedPrint("   Total sent:       \(totalSent)")
                timestampedPrint("   Succeeded:        \(totalSucceeded)")
                timestampedPrint("   Failed:           \(totalFailed)")
                if totalNotReady > 0 {
                    timestampedPrint("   Not ready:        \(totalNotReady) (counted in failed; excluded from rate)")
                }
                timestampedPrint("   Elapsed:          \(formatDuration(elapsed))")

                if !totalFailureReasons.isEmpty {
                    timestampedPrint("\n❌ Failure Breakdown:")
                    for (reason, count) in totalFailureReasons.sorted(by: { $0.value > $1.value }) {
                        timestampedPrint("   \(reason): \(count)")
                    }
                }

                let rateBase3 = totalSent - totalNotReady
                if rateBase3 > 0 {
                    let note = totalNotReady > 0 ? " (excl. \(totalNotReady) not-ready)" : ""
                    timestampedPrint("   Success rate:     \(String(format: "%.2f", Double(totalSucceeded) / Double(rateBase3) * 100))%\(note)")
                }

                // Throughput and latency — excluding failures
                if totalSucceeded > 0 {
                    let throughput = totalActiveBatchTime > 0 ? Double(totalSucceeded) / totalActiveBatchTime : Double(totalSucceeded) / elapsed
                    let avgMs      = totalSumLat / Double(totalSucceeded) * 1000
                    let minMs      = overallMin == .infinity ? 0.0 : overallMin * 1000
                    let maxMs      = overallMax * 1000
                    let sorted     = allLatencies.sorted()
                    let p50Ms      = sorted[min(Int(Double(sorted.count) * 0.50), sorted.count - 1)] * 1000
                    let p95Ms      = sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)] * 1000
                    let p99Ms      = sorted[min(Int(Double(sorted.count) * 0.99), sorted.count - 1)] * 1000

                    timestampedPrint("\n⚡ Performance (successful messages only):")
                    timestampedPrint("   Throughput:       \(String(format: "%.2f", throughput)) msgs/sec (active time)")
                    timestampedPrint("   Latency avg:      \(String(format: "%.1f", avgMs))ms")
                    timestampedPrint("   Latency min:      \(String(format: "%.1f", minMs))ms")
                    timestampedPrint("   Latency max:      \(String(format: "%.1f", maxMs))ms")
                    timestampedPrint("   Latency P50:      \(String(format: "%.1f", p50Ms))ms")
                    timestampedPrint("   Latency P95:      \(String(format: "%.1f", p95Ms))ms")
                    timestampedPrint("   Latency P99:      \(String(format: "%.1f", p99Ms))ms")

                    if batchesWithConcurrency > 0 {
                        let avgConc   = totalConcurrencyRatioSum / Double(batchesWithConcurrency)
                        let idealConc = Double(msgsPerBatch)
                        let concPct   = min(avgConc / idealConc * 100.0, 100.0)
                        timestampedPrint("\n🔀 Concurrency (avg per batch):")
                        timestampedPrint("   Ratio:            \(String(format: "%.2f", avgConc)) / \(msgsPerBatch) ideal (\(String(format: "%.1f", concPct))%)")
                        if avgConc < 1.5 {
                            timestampedPrint("   ⚠️  Sends appear serialized — receiver may be blocking between responses")
                        } else if concPct >= 80.0 {
                            timestampedPrint("   ✅ Good concurrency — receivers process messages in parallel")
                        } else {
                            timestampedPrint("   ⚠️  Partial concurrency — some serialization detected")
                        }
                    }

                    // Per-follower breakdown
                    timestampedPrint("\n👥 Per-Follower (successful messages only):")
                    let followerRanks = Set(allMetrics.map { $0.followerRank }).sorted()
                    for rank in followerRanks {
                        let fm = allMetrics.filter { $0.followerRank == rank }
                        if !fm.isEmpty {
                            let lats = fm.map { $0.latency }
                            let avg  = lats.reduce(0, +) / Double(lats.count) * 1000
                            let mn   = (lats.min() ?? 0) * 1000
                            let mx   = (lats.max() ?? 0) * 1000
                            timestampedPrint("   Rank \(rank): avg=\(String(format: "%.1f", avg))ms min=\(String(format: "%.1f", mn))ms max=\(String(format: "%.1f", mx))ms (\(fm.count) msgs)")
                        }
                    }
                }

                // Response validation summary
                if capturedValidate {
                    let validTotal = totalValidOK + totalValidFail
                    timestampedPrint("\n✅ Response Validation (excluding send failures):")
                    if validTotal > 0 {
                        timestampedPrint("   Validated OK:     \(totalValidOK)/\(validTotal) (\(String(format: "%.1f", Double(totalValidOK) / Double(validTotal) * 100))%)")
                    }
                    if totalValidFail > 0 {
                        timestampedPrint("   ❌ Validation failures: \(totalValidFail)")
                    } else if totalSucceeded > 0 {
                        timestampedPrint("   ✅ All received responses validated correctly")
                    }
                } else if totalSucceeded > 0 {
                    timestampedPrint("\n   ℹ️  Response validation skipped (use --validate-responses to enable)")
                }

                timestampedPrint(String(repeating: "=", count: 60))

                if exportMetrics {
                    exportMetricsToJSON(metrics: allMetrics)
                }

                if totalFailed > 0 || totalValidFail > 0 {
                    timestampedPrint("❌ Test completed with issues.")
                    Foundation.exit(1)
                }
                timestampedPrint("✅ All \(totalSent) messages succeeded across \(capturedBatches) batches.")
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

            private func runDuration(ensembler: EnsemblerSession, followerCount: Int) {
                let deadline       = Date().addingTimeInterval(durationMinutes * 60)
                let testStart      = Date()
                var batchNum       = 0
                var totalSucceeded = 0
                var totalFailed    = 0
                var totalNotReady  = 0
                var overallMin     = Double.infinity
                var overallMax     = 0.0
                var totalSumLat    = 0.0
                var lastProgressAt = Date()
                var totalFailureReasons = [String: Int]()
                var totalActiveBatchTime    = 0.0
                var totalConcurrencyRatioSum = 0.0
                var batchesWithConcurrency  = 0

                let capturedAppID    = appID
                let capturedTimeout  = timeout
                let capturedIter     = iterations
                let capturedInterval = intervalMs
                let capturedValidate = validateResponses
                let msgsPerBatch     = iterations * followerCount

                timestampedPrint("🕐 Duration test: \(durationMinutes)min | \(capturedIter) msg/follower × \(followerCount) follower(s) = \(msgsPerBatch) msg/batch | interval \(capturedInterval)ms")
                timestampedPrint("   App ID: \(capturedAppID) | Timeout: \(capturedTimeout)s")

                while Date() < deadline {
                    batchNum += 1
                    let group            = DispatchGroup()
                    let statsLock        = OSAllocatedUnfairLock(
                        initialState: (succeeded: 0, failed: 0, minLat: Double.infinity, maxLat: 0.0, sumLat: 0.0,
                                       firstSend: Date.distantFuture, lastEnd: Date.distantPast)
                    )
                    let batchReasonsLock = OSAllocatedUnfairLock(initialState: [String: Int]())
                    let batchNotReadyLock = OSAllocatedUnfairLock(initialState: 0)
                    let capturedBatch    = batchNum
                    let pendingLock = OSAllocatedUnfairLock(initialState: [String: Date]())
                    let batchStart = Date()

                    for iteration in 1...capturedIter {
                        for followerRank in 1...followerCount {
                            let message = "Batch\(capturedBatch)-\(UUID().uuidString)-Iter[\(iteration)]-Rank[\(followerRank)]"
                            let pendingKey = "iter\(iteration)-rank\(followerRank)"
                            group.enter()
                            Task(priority: .userInitiated) {
                                defer {
                                    pendingLock.withLock { $0.removeValue(forKey: pendingKey) }
                                    group.leave()
                                }
                                let sendTime = Date()
                                pendingLock.withLock { $0[pendingKey] = sendTime }
                                do {
                                    let responseData = try await withDeadline(seconds: capturedTimeout + 3.0) {
                                        try await ensembler.sendDataAndGetResponse(
                                            appID: capturedAppID,
                                            data: message.data(using: .utf8)!,
                                            destination: followerRank,
                                            timeout: capturedTimeout
                                        )
                                    }
                                    let endTime = Date()
                                    let lat = endTime.timeIntervalSince(sendTime)
                                    if capturedValidate {
                                        let responseStr = String(data: responseData, encoding: .utf8) ?? ""
                                        let expected = "Echo: \(message)"
                                        if responseStr != expected {
                                            let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                            print("[\(ts)] ❌ Batch \(capturedBatch) iter \(iteration) rank \(followerRank) validation FAILED — expected '\(expected.prefix(80))', got: '\(responseStr.prefix(80))'")
                                            statsLock.withLock { $0.failed += 1 }
                                            batchReasonsLock.withLock { $0["validation mismatch", default: 0] += 1 }
                                            return
                                        }
                                    }
                                    statsLock.withLock { s in
                                        s.succeeded += 1
                                        if lat < s.minLat { s.minLat = lat }
                                        if lat > s.maxLat { s.maxLat = lat }
                                        s.sumLat += lat
                                        if sendTime < s.firstSend { s.firstSend = sendTime }
                                        if endTime  > s.lastEnd   { s.lastEnd   = endTime  }
                                    }
                                } catch {
                                    let reason = ConcurrentMessagingTest.failureReason(error)
                                    statsLock.withLock { $0.failed += 1 }
                                    batchReasonsLock.withLock { $0[reason, default: 0] += 1 }
                                    if reason == "not ready" { batchNotReadyLock.withLock { $0 += 1 } }
                                    let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                                    print("[\(ts)] ❌ Batch \(capturedBatch) iter \(iteration) rank \(followerRank) failed after \(String(format: "%.0f", Date().timeIntervalSince(sendTime) * 1000))ms: \(error)")
                                    if case .timeoutOnPeerHandler = error as? DataMessageError {
                                        print("[\(ts)]    ↳ Hint: verify 'receive-data-message' on rank \(followerRank) for appID '\(capturedAppID)'")
                                    }
                                }
                            }
                        }
                    }
                    let batchWaitTimeout = DispatchTime.now() + capturedTimeout + 5.0
                    if group.wait(timeout: batchWaitTimeout) == .timedOut {
                        let stuck = pendingLock.withLock { $0 }
                        let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                        print("[\(ts)] 🚨 Batch \(batchNum) HUNG — \(stuck.count) message(s) stuck after \(String(format: "%.0f", capturedTimeout + 5.0))s:")
                        for (key, t) in stuck.sorted(by: { $0.key < $1.key }) {
                            print("[\(ts)]    \(key) waiting \(String(format: "%.1f", Date().timeIntervalSince(t)))s (appID: '\(capturedAppID)')")
                        }
                    }

                    let s = statsLock.withLock { $0 }
                    let batchReasons = batchReasonsLock.withLock { $0 }
                    let batchElapsed = Date().timeIntervalSince(batchStart)

                    // Per-batch concurrency ratio
                    var batchConcurrency = 0.0
                    var batchThroughput  = 0.0
                    let batchWall = s.lastEnd.timeIntervalSince(s.firstSend)
                    if batchWall > 0 && s.succeeded > 0 {
                        batchConcurrency = s.sumLat / batchWall
                        batchThroughput  = Double(s.succeeded) / batchWall
                        totalActiveBatchTime     += batchWall
                        totalConcurrencyRatioSum += batchConcurrency
                        batchesWithConcurrency   += 1
                    }

                    if s.failed > 0 {
                        let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                        let reasons = batchReasons.sorted(by: { $0.value > $1.value }).map { "\($0.key):\($0.value)" }.joined(separator: ", ")
                        let avgMs = s.succeeded > 0 ? s.sumLat / Double(s.succeeded) * 1000 : 0
                        print("[\(ts)] ⚠️  Batch \(batchNum) — succeeded=\(s.succeeded) failed=\(s.failed) in \(String(format: "%.0f", batchElapsed * 1000))ms avg-latency=\(String(format: "%.1f", avgMs))ms throughput=\(String(format: "%.1f", batchThroughput))/s concurrency=\(String(format: "%.2f", batchConcurrency)) — \(reasons)")
                    }
                    for (reason, count) in batchReasons {
                        totalFailureReasons[reason, default: 0] += count
                    }
                    totalSucceeded += s.succeeded
                    totalFailed    += s.failed
                    totalNotReady  += batchNotReadyLock.withLock { $0 }
                    if s.minLat < overallMin { overallMin = s.minLat }
                    if s.maxLat > overallMax { overallMax = s.maxLat }
                    totalSumLat    += s.sumLat

                    if Date().timeIntervalSince(lastProgressAt) >= 60 {
                        let elapsed   = Date().timeIntervalSince(testStart)
                        let remaining = max(0, deadline.timeIntervalSinceNow)
                        let sent      = totalSucceeded + totalFailed
                        let avgMs     = totalSucceeded > 0 ? totalSumLat / Double(totalSucceeded) * 1000 : 0
                        let tput      = totalActiveBatchTime > 0 ? Double(totalSucceeded) / totalActiveBatchTime : 0
                        let avgConc   = batchesWithConcurrency > 0 ? totalConcurrencyRatioSum / Double(batchesWithConcurrency) : 0
                        timestampedPrint(
                            "📊 batch=\(batchNum) elapsed=\(formatDuration(elapsed)) remaining=\(formatDuration(remaining))" +
                            " sent=\(sent) succeeded=\(totalSucceeded) failed=\(totalFailed)" +
                            " avg-latency=\(String(format: "%.1f", avgMs))ms throughput=\(String(format: "%.1f", tput))/s concurrency=\(String(format: "%.2f", avgConc))"
                        )
                        if !totalFailureReasons.isEmpty {
                            let reasonSummary = totalFailureReasons.sorted(by: { $0.value > $1.value })
                                .map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                            timestampedPrint("   Failures by reason: \(reasonSummary)")
                        }
                        lastProgressAt = Date()
                    }

                    if capturedInterval > 0 && Date() < deadline {
                        Thread.sleep(forTimeInterval: TimeInterval(capturedInterval) / 1000.0)
                    }
                }

                let elapsed   = Date().timeIntervalSince(testStart)
                let sent      = totalSucceeded + totalFailed
                let avgMs     = totalSucceeded > 0 ? totalSumLat / Double(totalSucceeded) * 1000 : 0
                let minMs     = overallMin == .infinity ? 0 : overallMin * 1000
                let maxMs     = overallMax * 1000
                let tput      = totalActiveBatchTime > 0 ? Double(totalSucceeded) / totalActiveBatchTime : 0
                let avgConc   = batchesWithConcurrency > 0 ? totalConcurrencyRatioSum / Double(batchesWithConcurrency) : 0

                timestampedPrint("\n" + String(repeating: "=", count: 60))
                timestampedPrint("📊 DURATION TEST SUMMARY — CONCURRENT MESSAGING")
                timestampedPrint(String(repeating: "=", count: 60))
                timestampedPrint("   Target duration:  \(durationMinutes)min")
                timestampedPrint("   Elapsed:          \(formatDuration(elapsed))")
                timestampedPrint("   Batches run:      \(batchNum)")
                timestampedPrint("   Followers:        \(followerCount)")
                timestampedPrint("   Iterations/batch: \(capturedIter) per follower (\(msgsPerBatch) total)")
                timestampedPrint("   Interval:         \(capturedInterval)ms")
                timestampedPrint("   Total sent:       \(sent)")
                timestampedPrint("   Succeeded:        \(totalSucceeded)")
                timestampedPrint("   Failed:           \(totalFailed)")
                if totalNotReady > 0 {
                    timestampedPrint("   Not ready:        \(totalNotReady) (counted in failed; excluded from rate)")
                }
                if !totalFailureReasons.isEmpty {
                    timestampedPrint("\n❌ Failure Breakdown:")
                    for (reason, count) in totalFailureReasons.sorted(by: { $0.value > $1.value }) {
                        timestampedPrint("   \(reason): \(count)")
                    }
                }
                let rateBase4 = sent - totalNotReady
                if rateBase4 > 0 {
                    let note = totalNotReady > 0 ? " (excl. \(totalNotReady) not-ready)" : ""
                    timestampedPrint("   Success rate:     \(String(format: "%.2f", Double(totalSucceeded) / Double(rateBase4) * 100))%\(note)")
                }
                if totalSucceeded > 0 {
                    timestampedPrint("\n⚡ Performance (successful messages only):")
                    timestampedPrint("   Throughput:       \(String(format: "%.2f", tput)) msgs/sec (active time)")
                    timestampedPrint("   Latency avg:      \(String(format: "%.1f", avgMs))ms")
                    timestampedPrint("   Latency min:      \(String(format: "%.1f", minMs))ms")
                    timestampedPrint("   Latency max:      \(String(format: "%.1f", maxMs))ms")
                    if batchesWithConcurrency > 0 {
                        let idealConc = Double(msgsPerBatch)
                        let concPct   = min(avgConc / idealConc * 100.0, 100.0)
                        timestampedPrint("\n🔀 Concurrency (avg per batch):")
                        timestampedPrint("   Ratio:            \(String(format: "%.2f", avgConc)) / \(msgsPerBatch) ideal (\(String(format: "%.1f", concPct))%)")
                        if avgConc < 1.5 {
                            timestampedPrint("   ⚠️  Sends appear serialized — receiver may be blocking between responses")
                        } else if concPct >= 80.0 {
                            timestampedPrint("   ✅ Good concurrency")
                        } else {
                            timestampedPrint("   ⚠️  Partial concurrency — some serialization detected")
                        }
                    }
                }
                timestampedPrint(String(repeating: "=", count: 60))

                if totalFailed > 0 {
                    timestampedPrint("❌ Duration test completed with \(totalFailed) failure(s).")
                    Foundation.exit(1)
                }
                timestampedPrint("✅ Duration test completed successfully.")
            }

            private func formatDuration(_ seconds: TimeInterval) -> String {
                let h = Int(seconds) / 3600
                let m = (Int(seconds) % 3600) / 60
                let s = Int(seconds) % 60
                if h > 0 { return "\(h)h \(m)m \(s)s" }
                if m > 0 { return "\(m)m \(s)s" }
                return "\(s)s"
            }

            private static func failureReason(_ error: Error) -> String {
                if error is XPCDeadlineExceededError { return "XPC deadline exceeded (ensembled silent)" }
                if let dataErr = error as? DataMessageError {
                    switch dataErr {
                    case .notReady:             return "not ready"
                    case .timeoutOnPeerHandler: return "timeout (peer handler)"
                    case .noResponseReceived:   return "timeout (no response)"
                    case .noRegisteredHandler:  return "no registered handler"
                    case .internalError:        return "internal error"
                    }
                }
                // Fallback: older daemon versions may surface errors as generic strings
                let desc = String(describing: error).lowercased()
                if desc.contains("timeoutonpeerhandler") || desc.contains("timeout on peer") { return "timeout (peer handler)" }
                if desc.contains("notready") || desc.contains("not ready") { return "not ready" }
                if desc.contains("timeout") { return "timeout (no response)" }
                if desc.contains("noregisteredhandler") || desc.contains("no registered handler") { return "no registered handler" }
                if desc.contains("internalerror") || desc.contains("internal error") { return "internal error" }
                return String(String(describing: error).prefix(60))
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
                guard intervalMs >= 0 else {
                    throw ValidationError("interval-ms must be non-negative")
                }
                guard durationMinutes >= 0 else {
                    throw ValidationError("duration-minutes must be non-negative")
                }
                guard batchCount > 0 else {
                    throw ValidationError("batch-count must be greater than 0")
                }
            }
        }
    }

// MARK: - HeartbeatTest

extension EnsembleCtl {
    struct HeartbeatTest: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "heartbeat-test",
            abstract: "Send periodic heartbeats from leader to all followers and detect failures. (Requires Root)"
        )

        @Option(name: .long, help: "Milliseconds between heartbeat rounds (default: 2000)")
        var intervalMs: Int = 2000

        @Option(name: .shortAndLong, help: "Timeout per heartbeat message in seconds (default: 5.0)")
        var timeout: Double = 5.0

        @Option(name: .shortAndLong, help: "Application ID for heartbeat routing (default: heartbeat-test)")
        var appID: String = "heartbeat-test"

        @Option(name: .long, help: "Consecutive failures per follower before test aborts (default: 3)")
        var consecutiveFailureLimit: Int = 3

        @Option(name: .long, help: "Number of rounds to run (default: 100). Ignored when --duration-minutes is set.")
        var batchCount: Int = 100

        @Option(name: .long, help: "Run for N minutes instead of a fixed round count (default: 0 = use --batch-count)")
        var durationMinutes: Double = 0

        @Flag(name: .shortAndLong, help: "Enable verbose per-round per-follower output")
        var verbose: Bool = false

        private struct FollowerState {
            var consecutiveFailures:   Int     = 0
            var consecutiveFailureHWM: Int     = 0
            var succeeded:             Int     = 0
            var failed:                Int     = 0
            var latencies:             [Double] = []
            var lastFailureReason:     String  = ""
        }

        private func timestampedPrint(_ message: String) {
            let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
            print("[\(ts)] \(message)")
        }

        private func verbosePrint(_ message: String) {
            if verbose { timestampedPrint("DEBUG: \(message)") }
        }

        private func formatDuration(_ seconds: TimeInterval) -> String {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            let s = Int(seconds) % 60
            if h > 0 { return "\(h)h \(m)m \(s)s" }
            if m > 0 { return "\(m)m \(s)s" }
            return "\(s)s"
        }

        private static func failureReason(_ error: Error) -> String {
            if error is XPCDeadlineExceededError { return "XPC deadline exceeded (ensembled silent)" }
            if let dataErr = error as? DataMessageError {
                switch dataErr {
                case .notReady:             return "not ready"
                case .timeoutOnPeerHandler: return "timeout (peer handler)"
                case .noResponseReceived:   return "timeout (no response)"
                case .noRegisteredHandler:  return "no registered handler"
                case .internalError:        return "internal error"
                }
            }
            // Fallback: older daemon versions may surface errors as generic strings
            let desc = String(describing: error).lowercased()
            if desc.contains("timeoutonpeerhandler") || desc.contains("timeout on peer") { return "timeout (peer handler)" }
            if desc.contains("notready") || desc.contains("not ready") { return "not ready" }
            if desc.contains("timeout") { return "timeout (no response)" }
            if desc.contains("noregisteredhandler") || desc.contains("no registered handler") { return "no registered handler" }
            if desc.contains("internalerror") || desc.contains("internal error") { return "internal error" }
            return String(String(describing: error).prefix(60))
        }

        mutating func validate() throws {
            guard geteuid() == 0 else {
                throw ValidationError("Heartbeat test requires Root privileges")
            }
            guard intervalMs > 0 else { throw ValidationError("interval-ms must be > 0") }
            guard timeout > 0 else { throw ValidationError("timeout must be > 0") }
            guard consecutiveFailureLimit > 0 else { throw ValidationError("consecutive-failure-limit must be > 0") }
            guard batchCount > 0 else { throw ValidationError("batch-count must be > 0") }
            guard durationMinutes >= 0 else { throw ValidationError("duration-minutes must be >= 0") }
        }

        mutating func run() throws {
            let ensembler = try EnsemblerSession()

            let status = try ensembler.getStatus()
            guard status == .ready else {
                timestampedPrint("❌ Ensemble is not ready. Status: \(status)")
                Foundation.exit(1)
            }

            let isLeader = try ensembler.isLeader()
            guard isLeader else {
                timestampedPrint("❌ heartbeat-test can only run on the leader node")
                Foundation.exit(1)
            }

            let peerInfo = try ensembler.getPeerInfo()
            let followerCount = peerInfo!.count

            guard followerCount > 0 else {
                timestampedPrint("❌ No followers found in ensemble")
                Foundation.exit(1)
            }

            timestampedPrint("💓 HeartbeatTest: \(followerCount) follower(s) | interval=\(intervalMs)ms | timeout=\(timeout)s | consecutiveFailureLimit=\(consecutiveFailureLimit)")

            if durationMinutes > 0 {
                runDuration(ensembler: ensembler, followerCount: followerCount)
            } else {
                runRounds(ensembler: ensembler, followerCount: followerCount)
            }
        }

        // MARK: executeRound

        private func executeRound(
            round: Int,
            ensembler: EnsemblerSession,
            followerCount: Int,
            capturedAppID: String,
            capturedTimeout: Double,
            capturedVerbose: Bool
        ) -> (succeeded: [Int: Double], failed: [Int: String]) {
            let group       = DispatchGroup()
            let resultLock  = OSAllocatedUnfairLock(
                initialState: (succeeded: [Int: Double](), failed: [Int: String]())
            )
            let pendingLock = OSAllocatedUnfairLock(initialState: [Int: Date]())

            for rank in 1...followerCount {
                let payload = "HB-\(round)-\(UUID().uuidString)"
                group.enter()
                Task(priority: .userInitiated) {
                    defer {
                        pendingLock.withLock { $0.removeValue(forKey: rank) }
                        group.leave()
                    }
                    let sendTime = Date()
                    pendingLock.withLock { $0[rank] = sendTime }
                    do {
                        _ = try await withDeadline(seconds: capturedTimeout + 3.0) {
                            try await ensembler.sendDataAndGetResponse(
                                appID: capturedAppID,
                                data: payload.data(using: .utf8)!,
                                destination: rank,
                                timeout: capturedTimeout
                            )
                        }
                        let lat = Date().timeIntervalSince(sendTime)
                        resultLock.withLock { $0.succeeded[rank] = lat }
                        if capturedVerbose {
                            let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                            print("[\(ts)] ✅ round=\(round) rank=\(rank) \(String(format: "%.1f", lat * 1000))ms")
                        }
                    } catch {
                        let reason = HeartbeatTest.failureReason(error)
                        resultLock.withLock { $0.failed[rank] = reason }
                        let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                        print("[\(ts)] ❌ round=\(round) rank=\(rank) failed: \(reason)")
                    }
                }
            }

            let batchWait = DispatchTime.now() + capturedTimeout + 5.0
            if group.wait(timeout: batchWait) == .timedOut {
                let stuck = pendingLock.withLock { $0 }
                let ts    = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                print("[\(ts)] 🚨 Round \(round) HUNG — \(stuck.count) follower(s) still pending")
                resultLock.withLock { s in
                    for rank in stuck.keys where s.succeeded[rank] == nil && s.failed[rank] == nil {
                        s.failed[rank] = "XPC deadline exceeded (ensembled silent)"
                    }
                }
            }

            return resultLock.withLock { $0 }
        }

        // MARK: runRounds

        private func runRounds(ensembler: EnsemblerSession, followerCount: Int) {
            let testStart        = Date()
            let capturedAppID    = appID
            let capturedTimeout  = timeout
            let capturedVerbose  = verbose
            let capturedLimit    = consecutiveFailureLimit
            let capturedBatches  = batchCount
            let capturedInterval = intervalMs

            var states = Dictionary(uniqueKeysWithValues: (1...followerCount).map { ($0, FollowerState()) })
            var aborted     = false
            var abortRound  = 0
            var abortReason: String? = nil

            timestampedPrint("🚀 Starting \(capturedBatches) rounds of heartbeats")

            for round in 1...capturedBatches {
                let result = executeRound(
                    round: round, ensembler: ensembler, followerCount: followerCount,
                    capturedAppID: capturedAppID, capturedTimeout: capturedTimeout,
                    capturedVerbose: capturedVerbose
                )

                for rank in 1...followerCount {
                    if let lat = result.succeeded[rank] {
                        states[rank]!.consecutiveFailures = 0
                        states[rank]!.succeeded += 1
                        states[rank]!.latencies.append(lat)
                    } else if let reason = result.failed[rank] {
                        states[rank]!.consecutiveFailures += 1
                        states[rank]!.failed += 1
                        states[rank]!.lastFailureReason = reason
                        states[rank]!.consecutiveFailureHWM = max(
                            states[rank]!.consecutiveFailureHWM,
                            states[rank]!.consecutiveFailures
                        )
                        if states[rank]!.consecutiveFailures >= capturedLimit {
                            timestampedPrint("💔 HEARTBEAT FAILURE: Rank \(rank) hit \(capturedLimit) consecutive failures (\(reason))")
                            timestampedPrint("Stopping test after round \(round).")
                            aborted     = true
                            abortRound  = round
                            abortReason = "Rank \(rank): \(capturedLimit) consecutive failures — \(reason)"
                            break
                        }
                    }
                }
                if aborted { break }

                let ts         = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                let roundFailed = !result.failed.isEmpty
                if roundFailed || round % 10 == 0 || round == capturedBatches {
                    let succCount = result.succeeded.count
                    let failCount = result.failed.count
                    let lats      = result.succeeded.values.map { $0 * 1000 }
                    let avgMs     = lats.isEmpty ? "n/a" : String(format: "%.1f", lats.reduce(0, +) / Double(lats.count))
                    if roundFailed {
                        let reasons = result.failed.map { "rank\($0.key):\($0.value)" }.joined(separator: ", ")
                        print("[\(ts)] ⚠️  Round \(round)/\(capturedBatches) — ok=\(succCount) fail=\(failCount) avg=\(avgMs)ms — \(reasons)")
                    } else {
                        print("[\(ts)] 💓 Round \(round)/\(capturedBatches) — ok=\(succCount) avg=\(avgMs)ms")
                    }
                }

                if !aborted && round < capturedBatches && capturedInterval > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(capturedInterval) / 1000.0)
                }
            }

            let elapsed = Date().timeIntervalSince(testStart)
            printFinalSummary(
                states: states, totalRounds: aborted ? abortRound : capturedBatches,
                plannedRounds: capturedBatches, elapsed: elapsed,
                aborted: aborted, abortReason: abortReason
            )
            if aborted {
                timestampedPrint("❌ Heartbeat failure detected. Exiting.")
                Foundation.exit(1)
            }
        }

        // MARK: runDuration

        private func runDuration(ensembler: EnsemblerSession, followerCount: Int) {
            let deadline         = Date().addingTimeInterval(durationMinutes * 60)
            let testStart        = Date()
            let capturedAppID    = appID
            let capturedTimeout  = timeout
            let capturedVerbose  = verbose
            let capturedLimit    = consecutiveFailureLimit
            let capturedInterval = intervalMs

            var states = Dictionary(uniqueKeysWithValues: (1...followerCount).map { ($0, FollowerState()) })
            var round        = 0
            var aborted      = false
            var abortReason: String? = nil
            var lastProgressAt = Date()

            timestampedPrint("🕐 Duration heartbeat test: \(durationMinutes)min | interval=\(capturedInterval)ms | timeout=\(capturedTimeout)s")

            while Date() < deadline {
                round += 1
                let result = executeRound(
                    round: round, ensembler: ensembler, followerCount: followerCount,
                    capturedAppID: capturedAppID, capturedTimeout: capturedTimeout,
                    capturedVerbose: capturedVerbose
                )

                for rank in 1...followerCount {
                    if let lat = result.succeeded[rank] {
                        states[rank]!.consecutiveFailures = 0
                        states[rank]!.succeeded += 1
                        states[rank]!.latencies.append(lat)
                    } else if let reason = result.failed[rank] {
                        states[rank]!.consecutiveFailures += 1
                        states[rank]!.failed += 1
                        states[rank]!.lastFailureReason = reason
                        states[rank]!.consecutiveFailureHWM = max(
                            states[rank]!.consecutiveFailureHWM,
                            states[rank]!.consecutiveFailures
                        )
                        if states[rank]!.consecutiveFailures >= capturedLimit {
                            timestampedPrint("💔 HEARTBEAT FAILURE: Rank \(rank) hit \(capturedLimit) consecutive failures (\(reason))")
                            timestampedPrint("Stopping test after round \(round).")
                            aborted     = true
                            abortReason = "Rank \(rank): \(capturedLimit) consecutive failures — \(reason)"
                            break
                        }
                    }
                }
                if aborted { break }

                if Date().timeIntervalSince(lastProgressAt) >= 60 {
                    let elapsed   = Date().timeIntervalSince(testStart)
                    let remaining = max(0, deadline.timeIntervalSinceNow)
                    timestampedPrint("📊 round=\(round) elapsed=\(formatDuration(elapsed)) remaining=\(formatDuration(remaining))")
                    lastProgressAt = Date()
                }

                if Date() < deadline && capturedInterval > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(capturedInterval) / 1000.0)
                }
            }

            let elapsed = Date().timeIntervalSince(testStart)
            printFinalSummary(
                states: states, totalRounds: round,
                plannedRounds: round, elapsed: elapsed,
                aborted: aborted, abortReason: abortReason
            )
            if aborted {
                timestampedPrint("❌ Heartbeat failure detected. Exiting.")
                Foundation.exit(1)
            }
        }

        // MARK: printFinalSummary

        private func printFinalSummary(
            states: [Int: FollowerState],
            totalRounds: Int,
            plannedRounds: Int,
            elapsed: TimeInterval,
            aborted: Bool,
            abortReason: String?
        ) {
            let followerCount   = states.count
            let totalHeartbeats = totalRounds * followerCount
            let totalSucceeded  = states.values.map { $0.succeeded }.reduce(0, +)
            let totalFailed     = states.values.map { $0.failed }.reduce(0, +)

            let allLats = states.values.flatMap { $0.latencies }.sorted()
            let avgMs   = allLats.isEmpty ? 0.0 : allLats.reduce(0, +) / Double(allLats.count) * 1000
            let minMs   = (allLats.first ?? 0) * 1000
            let maxMs   = (allLats.last  ?? 0) * 1000
            let p50Ms   = allLats.isEmpty ? 0.0 : allLats[min(Int(Double(allLats.count) * 0.50), allLats.count - 1)] * 1000
            let p95Ms   = allLats.isEmpty ? 0.0 : allLats[min(Int(Double(allLats.count) * 0.95), allLats.count - 1)] * 1000
            let p99Ms   = allLats.isEmpty ? 0.0 : allLats[min(Int(Double(allLats.count) * 0.99), allLats.count - 1)] * 1000

            let heartbeatRatePerSec = elapsed > 0 ? Double(totalRounds) / elapsed : 0

            var failureReasons = [String: Int]()
            for state in states.values where !state.lastFailureReason.isEmpty {
                failureReasons[state.lastFailureReason, default: 0] += state.failed
            }

            timestampedPrint("\n" + String(repeating: "=", count: 60))
            if aborted {
                timestampedPrint("📊 HEARTBEAT TEST — FINAL SUMMARY (ABORTED)")
            } else {
                timestampedPrint("📊 HEARTBEAT TEST — FINAL SUMMARY")
            }
            timestampedPrint(String(repeating: "=", count: 60))
            if aborted {
                timestampedPrint("   Stopped at round:    \(totalRounds) / \(plannedRounds)")
                timestampedPrint("   Reason:              \(abortReason ?? "unknown")")
            } else {
                timestampedPrint("   Rounds:              \(totalRounds)")
            }
            timestampedPrint("   Followers:           \(followerCount)")
            timestampedPrint("   Interval:            \(intervalMs)ms")
            timestampedPrint("   Total heartbeats:    \(totalHeartbeats) (\(totalRounds) rounds × \(followerCount) followers)")
            timestampedPrint("   Elapsed:             \(formatDuration(elapsed))")
            timestampedPrint("   Heartbeat rate:      \(String(format: "%.2f", heartbeatRatePerSec)) rounds/sec")

            if !failureReasons.isEmpty {
                timestampedPrint("\n❌ Failure Breakdown:")
                for (reason, count) in failureReasons.sorted(by: { $0.value > $1.value }) {
                    timestampedPrint("   \(reason): \(count)")
                }
            }

            if !allLats.isEmpty {
                timestampedPrint("\n⚡ Performance (successful heartbeats only):")
                timestampedPrint("   Latency avg:         \(String(format: "%.1f", avgMs))ms  min: \(String(format: "%.1f", minMs))ms  max: \(String(format: "%.1f", maxMs))ms")
                timestampedPrint("   Latency P50:         \(String(format: "%.1f", p50Ms))ms  P95: \(String(format: "%.1f", p95Ms))ms  P99: \(String(format: "%.1f", p99Ms))ms")
            }

            timestampedPrint("\n👥 Per-Follower:")
            for rank in states.keys.sorted() {
                let s     = states[rank]!
                let total = s.succeeded + s.failed
                let pct   = total > 0 ? Double(s.succeeded) / Double(total) * 100 : 0
                let avgF  = s.latencies.isEmpty ? 0.0 : s.latencies.reduce(0, +) / Double(s.latencies.count) * 1000
                let maxF  = (s.latencies.max() ?? 0) * 1000
                timestampedPrint("   Rank \(rank): success=\(s.succeeded)/\(total) (\(String(format: "%.1f", pct))%)  avg=\(String(format: "%.1f", avgF))ms  max=\(String(format: "%.1f", maxF))ms  consec-fail-hwm=\(s.consecutiveFailureHWM)")
            }
            timestampedPrint(String(repeating: "=", count: 60))

            if !aborted {
                let succPct = totalHeartbeats > 0 ? Double(totalSucceeded) / Double(totalHeartbeats) * 100 : 0
                if totalFailed > 0 {
                    timestampedPrint("⚠️  Test completed with failures. \(totalSucceeded)/\(totalHeartbeats) heartbeats succeeded (\(String(format: "%.1f", succPct))%).")
                } else {
                    timestampedPrint("✅ Test completed. \(totalSucceeded)/\(totalHeartbeats) heartbeats succeeded (\(String(format: "%.1f", succPct))%).")
                }
            }
        }
    }
}

// MARK: - HeartbeatReceive

extension EnsembleCtl {
    struct HeartbeatReceive: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "heartbeat-receive",
            abstract: "Listen for heartbeat messages from the leader, ACK them, and detect staleness. (Requires Root)"
        )

        @Option(name: .shortAndLong, help: "Application ID to listen on (default: heartbeat-test)")
        var appID: String = "heartbeat-test"

        @Option(name: .long, help: "Seconds without a heartbeat before logging a stale warning (default: 6.0)")
        var staleSeconds: Double = 6.0

        @Option(name: .long, help: "Auto-stop after N minutes (default: 0 = run until Ctrl+C)")
        var durationMinutes: Double = 0

        @Flag(name: .shortAndLong, help: "Enable verbose per-heartbeat logging")
        var verbose: Bool = false

        private func timestampedPrint(_ message: String) {
            let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
            print("[\(ts)] \(message)")
        }

        private func formatDuration(_ seconds: TimeInterval) -> String {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            let s = Int(seconds) % 60
            if h > 0 { return "\(h)h \(m)m \(s)s" }
            if m > 0 { return "\(m)m \(s)s" }
            return "\(s)s"
        }

        mutating func validate() throws {
            guard geteuid() == 0 else {
                throw ValidationError("Heartbeat receive requires Root privileges")
            }
            guard staleSeconds > 0 else { throw ValidationError("stale-seconds must be > 0") }
            guard durationMinutes >= 0 else { throw ValidationError("duration-minutes must be >= 0") }
        }

        mutating func run() throws {
            let ensembler = try EnsemblerSession()

            let status = try ensembler.getStatus()
            guard status == .ready else {
                timestampedPrint("❌ Ensemble is not ready. Status: \(status)")
                Foundation.exit(1)
            }

            let capturedAppID    = appID
            let capturedStale    = staleSeconds
            let capturedVerbose  = verbose
            let capturedDuration = durationMinutes
            let testStart        = Date()

            let lastHeartbeatLock = OSAllocatedUnfairLock(initialState: Date())
            let receivedCountLock = OSAllocatedUnfairLock(initialState: 0)
            let staleCountLock    = OSAllocatedUnfairLock(initialState: 0)
            let interArrivalLock  = OSAllocatedUnfairLock(initialState: [Double]())
            let lastArrivalLock   = OSAllocatedUnfairLock(initialState: Optional<Date>.none)

            timestampedPrint("💓 HeartbeatReceive listening on appID '\(capturedAppID)' | stale=\(capturedStale)s")
            if capturedDuration > 0 {
                timestampedPrint("   Auto-stop after \(capturedDuration)min")
            } else {
                timestampedPrint("   Running until Ctrl+C")
            }

            // Stale monitor: 1-second DispatchSource timer
            let monitorQueue = DispatchQueue(label: "heartbeat.receive.monitor", qos: .utility)
            let monitorTimer = DispatchSource.makeTimerSource(queue: monitorQueue)
            monitorTimer.schedule(deadline: .now() + 1.0, repeating: 1.0)
            monitorTimer.setEventHandler {
                let received = receivedCountLock.withLock { $0 }
                guard received > 0 else { return }
                let last  = lastHeartbeatLock.withLock { $0 }
                let since = Date().timeIntervalSince(last)
                if since > capturedStale {
                    let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                    print("[\(ts)] ⚠️  STALE: No heartbeat for \(String(format: "%.1f", since))s (threshold: \(capturedStale)s)")
                    staleCountLock.withLock { $0 += 1 }
                }
            }
            monitorTimer.resume()

            // SIGINT handler
            signal(SIGINT, SIG_IGN)
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                monitorTimer.cancel()
                HeartbeatReceive.printReceiveSummary(
                    testStart: testStart,
                    receivedCountLock: receivedCountLock,
                    staleCountLock: staleCountLock,
                    interArrivalLock: interArrivalLock
                )
                Foundation.exit(0)
            }
            sigintSource.resume()

            // Duration auto-stop
            if capturedDuration > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + capturedDuration * 60) {
                    monitorTimer.cancel()
                    HeartbeatReceive.printReceiveSummary(
                        testStart: testStart,
                        receivedCountLock: receivedCountLock,
                        staleCountLock: staleCountLock,
                        interArrivalLock: interArrivalLock
                    )
                    Foundation.exit(0)
                }
            }

            // Register heartbeat callback using the async variant so each invocation
            // runs as an independent Swift Task — no GCD thread held during the response.
            Task(priority: .userInitiated) {
                do {
                    try await ensembler.registerDataCallback(appID: capturedAppID) { sender, data in
                        let now = Date()

                        let prev = lastArrivalLock.withLock { $0 }
                        if let prev = prev {
                            interArrivalLock.withLock { $0.append(now.timeIntervalSince(prev)) }
                        }
                        lastArrivalLock.withLock { $0 = now }

                        receivedCountLock.withLock { $0 += 1 }
                        lastHeartbeatLock.withLock { $0 = now }

                        let count   = receivedCountLock.withLock { $0 }
                        let payload = String(data: data, encoding: .utf8) ?? "<binary>"

                        if capturedVerbose {
                            let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                            print("[\(ts)] 💓 HB #\(count) from rank \(sender): \(payload.prefix(60))")
                        }

                        return data  // ACK: echo payload back
                    }
                } catch {
                    let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
                    print("[\(ts)] ❌ Failed to register heartbeat callback: \(error)")
                    Foundation.exit(1)
                }
            }

            timestampedPrint("Handler registered. Waiting for heartbeats...")
            RunLoop.current.run()
        }

        private static func printReceiveSummary(
            testStart: Date,
            receivedCountLock: OSAllocatedUnfairLock<Int>,
            staleCountLock: OSAllocatedUnfairLock<Int>,
            interArrivalLock: OSAllocatedUnfairLock<[Double]>
        ) {
            let received      = receivedCountLock.withLock { $0 }
            let staleEvents   = staleCountLock.withLock { $0 }
            let interArrivals = interArrivalLock.withLock { $0 }
            let elapsed       = Date().timeIntervalSince(testStart)

            let avgIAms = interArrivals.isEmpty ? 0.0 : interArrivals.reduce(0, +) / Double(interArrivals.count) * 1000
            let minIAms = (interArrivals.min() ?? 0) * 1000
            let maxIAms = (interArrivals.max() ?? 0) * 1000

            let ts = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
            print("")
            print("[\(ts)] " + String(repeating: "=", count: 60))
            print("[\(ts)] 📊 HEARTBEAT RECEIVE — FINAL SUMMARY")
            print("[\(ts)] " + String(repeating: "=", count: 60))
            print("[\(ts)]    Heartbeats received:  \(received)")
            print("[\(ts)]    Stale events:          \(staleEvents)")
            print("[\(ts)]    Elapsed:               \(HeartbeatReceive.formatDurationStatic(elapsed))")

            if !interArrivals.isEmpty {
                print("[\(ts)] ")
                print("[\(ts)] ⏱ Inter-arrival times (between consecutive heartbeats):")
                print("[\(ts)]    avg: \(String(format: "%.0f", avgIAms))ms  min: \(String(format: "%.0f", minIAms))ms  max: \(String(format: "%.0f", maxIAms))ms")
            }

            print("[\(ts)] " + String(repeating: "=", count: 60))
            if staleEvents == 0 {
                print("[\(ts)] ✅ Heartbeat receiver stopped. No stale events detected.")
            } else {
                print("[\(ts)] ⚠️  Heartbeat receiver stopped. \(staleEvents) stale event(s) detected.")
            }
        }

        private static func formatDurationStatic(_ seconds: TimeInterval) -> String {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            let s = Int(seconds) % 60
            if h > 0 { return "\(h)h \(m)m \(s)s" }
            if m > 0 { return "\(m)m \(s)s" }
            return "\(s)s"
        }
    }
}

/// Thrown by `withDeadline` when the operation does not complete in time.
/// Distinct from framework-level timeout errors so we can identify XPC-layer hangs.
struct XPCDeadlineExceededError: Error {
    let seconds: TimeInterval
    var localizedDescription: String {
        "XPC deadline exceeded: ensembled did not reply within \(String(format: "%.1f", seconds))s — possible XPC session stall in this process"
    }
}

/// Run `operation` with a hard wall-clock deadline.  If `operation` does not complete
/// within `seconds`, it is cancelled and `XPCDeadlineExceededError` is thrown.
/// This prevents zombie Swift Tasks when `withCheckedThrowingContinuation` inside
/// `sendCommandAsync` is silently abandoned (i.e. the XPC reply never arrives).
func withDeadline<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw XPCDeadlineExceededError(seconds: seconds)
        }
        // First result (success or error from either child) wins.
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

    @main
public enum EnsembleCtlMain {
    public static func main() throws {
        EnsembleCtl.main()
    }
}
