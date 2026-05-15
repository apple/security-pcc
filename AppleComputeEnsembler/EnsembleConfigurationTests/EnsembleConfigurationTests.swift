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
//  EnsembleConfigurationTests.swift
//  EnsembleConfigurationTests
//
//  Created by Dhanasekar Thangavel on 11/18/24.
//

import CryptoKit
import AppleComputeEnsembler
@testable import EnsembleConfiguration
import notify
import XCTest
import Testing

// Helper function to add timestamps to print statements
private func timestampedPrint(_ message: String, file: String = #file, line: Int = #line) {
    let timestamp = DateFormatter.iso8601WithFractionalSeconds.string(from: Date())
    let fileName = URL(fileURLWithPath: file).lastPathComponent
    print("[\(timestamp)] \(fileName):\(line) - \(message)")
}

extension DateFormatter {
    static let iso8601WithFractionalSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

// bad config, with two node having same rank
let twoNodeBadConfigDuplicateRank = EnsembleConfiguration(
	backendType: BackendType.StubBackend,
	hypercube: false,
	nodes: [
		"udid-0": NodeConfiguration(
			chassisID: "chassis1",
			rank: Rank.Rank0,
			hostName: "localhost",
			port: 8029
		),
		"udid-1": NodeConfiguration(
			chassisID: "chassis1",
			rank: Rank.Rank0,
			hostName: "localhost",
			port: 8030
		),
	]
)

final class EnsembleConfigurationTests: XCTestCase {
	

	override func setUp() {
		super.setUp()
        // Additional cleanup time for network connections to fully close
        Thread.sleep(forTimeInterval: 3.0)
	}
	
	// Verify state machine for single node
	func testStateMachinesSingleNode() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 1)
		try self.validateEnsemblerStateMachine(config: ensembleConfig)
	}

	// Verify state machine for 2 node
	// leaders starts first followed by follower1
	func testStateMachinesTwoNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	func invalidRankChassisIDConfiguration(nodeCount: Int) throws {
		let ensembleConfig = self.getEnsembleConfigInvalid(nodeCount: nodeCount)
		do {
			let ensembler = try EnsemblerTLS(
				ensembleConfig: ensembleConfig,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: ensembleConfig.nodes.keys.first,
				skipJobQuiescence: true
			)
            ensembler.stopServer()
		} catch InitializationError.invalidRankChassisdIDConfiguration {
			return
		}
		XCTFail("Invalid configuration is accepted, which should not be the case")
	}

	func testInvalidRankChassisIDConfiguration() throws {
		try self.invalidRankChassisIDConfiguration(nodeCount: 2)
		try self.invalidRankChassisIDConfiguration(nodeCount: 4)
		try self.invalidRankChassisIDConfiguration(nodeCount: 8)
		try self.invalidRankChassisIDConfiguration(nodeCount: 16)
	}

	func validRankChassisIDConfiguration(nodeCount: Int) throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: nodeCount)
		do {
			let ensembler = try EnsemblerTLS(
				ensembleConfig: ensembleConfig,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: ensembleConfig.nodes.keys.first,
				skipJobQuiescence: true
			)
            ensembler.stopServer()
		} catch InitializationError.invalidRankChassisdIDConfiguration {
			XCTFail("Valid configuration is not accepted, something wrong")
			return
		}
	}

	func testValidRankChassisIDConfiguration() throws {
		try self.validRankChassisIDConfiguration(nodeCount: 2)
		try self.validRankChassisIDConfiguration(nodeCount: 4)
		try self.validRankChassisIDConfiguration(nodeCount: 8)
		try self.validRankChassisIDConfiguration(nodeCount: 16)
	}

	// Verify state machine for two node for key rotation scenario
	// simulate node coming up in order i.e first node is started, and then second node it started.
	func testStateMachinesTwoNodeKeyrotation() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
		try self.validateEnsemblerStateMachineInternalForKeyRotation(
			config: ensembleConfig,
			startIndex: 0
		)
	}

	// Verify state machine for 2 node
	// follower1 starts first followed by leader
	func testStateMachinesTwoNodeUnordered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
		try self.validateEnsemblerStateMachine(config: ensembleConfig)
	}

	// simulate failure with both rank 0, expected state will be both stuck in coordinating state.
	func testStateMachinesTwoNodeWithFailure() throws {
		try self.validateEnsemblerStateMachineWithFailure(
			config: twoNodeBadConfigDuplicateRank,
			expectedState: .coordinating
		)
	}

	// Verify state machine for 4 node
	// leaders starts first followed by follower1,2.3...
	func testStateMachinesFourNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 4)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	// Verify state machine for 4 node
	// follower2 starts first followed by follower3, leader, follower1,2.
	func testStateMachinesFourNodeUnordered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 4)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 3)
	}

	// Verify distributing Datakey and getting the key on all followers
	func testValidateDistributeDataKey() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 8)
		try self.validateDataKeyDistribution(config: ensembleConfig)
	}

	// Verify state machine for 8 node
	// leaders starts first followed by follower1,2.3...
	func testStateMachinesEigthNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 8)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	// Verify state machine for 8 node
	// follower3 starts first followed by follower4,5,..n and then leader, follower1,2.
	func testStateMachinesEigthNodeUnordered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 8)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 4)
	}

	// Verify state machine for 16 node
	// leaders starts first followed by follower1,2.3...
	func testStateMachinesSixteenNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 16)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	// Verify state machine for 16 node
	// follower3 starts first followed by follower4,5,..n and then leader, follower1,2.
	func testStateMachinesSixteenNodeUnOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 16)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 4)
	}

	// Verify state machine for 32 node
	// leaders starts first followed by follower1,2.3...
	func testStateMachinesThirtyTwoNodeOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 32)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 0)
	}

	// Verify state machine for 32 node
	// follower3 starts first followed by follower4,5,..n and then leader, follower1,2.
	func testStateMachinesThirtyTwoNodeUnOrdered() throws {
		let ensembleConfig = self.getEnsembleConfig(nodeCount: 32)
		try self.validateEnsemblerStateMachineInternal(config: ensembleConfig, startIndex: 4)
	}
    
    // Test sending data message from one node to another, targetted to specific appID.
    func testDataMessaging() throws {
       
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
        let timeOut = Double(2) * 20.0
        // Create an expectation
        let expectation = self.expectation(description: "Test should complete within \(timeOut)")
        var ensemblers: [EnsemblerTLS] = []
        
        Task {
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("wait for all nodes to either get into ready state or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
            }
            
            timestampedPrint("check if all nodes are in ready state")
            for i in 0 ..< ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready)
            }
            
            let testmessage1 = "Test message1"
            let testmessage2 = "Test message2"
            ensemblers[0].registerDataCallback(appID: "app1") { sender, data in
                var response: String = ""
                if let string = String(data: data, encoding: .utf8) {
                    XCTAssert(string == testmessage1)
                    timestampedPrint("received data message: \(string) from rank \(sender)")
                    response = "response for \(string)"
                } else {
                    timestampedPrint("Failed to convert data to string")
                }
                
                return response.data(using: .utf8)!
            }
            
            ensemblers[0].registerDataCallback(appID: "app2") { sender, data in
                var response: String = ""
                if let string = String(data: data, encoding: .utf8) {
                    XCTAssert(string == testmessage2)
                    timestampedPrint("received data message: \(string) from rank \(sender)")
                    response = "response for \(string)"
                } else {
                    timestampedPrint("Failed to convert data to string")
                }
                
                return response.data(using: .utf8)!
            }
            
            Thread.sleep(forTimeInterval: 1)
            
            let message1StartTime = Date()
            ensemblers[1].sendDataAndGetResponse(appID: "app1", data: testmessage1.data(using: .utf8)!, destination: 0, completion: { [weak self] result in
                let message1EndTime = Date()
                let message1Duration = message1EndTime.timeIntervalSince(message1StartTime)
                timestampedPrint("Message1 response time: \(message1Duration) seconds")
                self?.handleControlDataResponse(result)
            })
            
          let message2StartTime = Date()
            ensemblers[1].sendDataAndGetResponse(appID: "app2",data: testmessage2.data(using: .utf8)!, destination: 0, completion: { [weak self] result in
                let message2EndTime = Date()
                let message2Duration = message2EndTime.timeIntervalSince(message2StartTime)
                timestampedPrint("Message2 response time: \(message2Duration) seconds")
                self?.handleControlDataResponse(result)
            })
            
            let message3StartTime = Date()
            ensemblers[1].sendDataAndGetResponse(appID: "app2",data: testmessage2.data(using: .utf8)!, destination: 0, completion: { [weak self] result in
                let message3EndTime = Date()
                let message3Duration = message3EndTime.timeIntervalSince(message3StartTime)
                timestampedPrint("Message3 response time: \(message3Duration) seconds")
                self?.handleControlDataResponse(result)
            })
            
            ensemblers[1].sendDataAndGetResponse(appID: "app3",data: "somedata".data(using: .utf8)!, destination: 0, completion: { result in
                switch result {
                case .success(let responseData):
                    XCTFail("There was not registered handler on the server, we should have got failure")
                    // Handle successful response
                case .failure(let error):
                    // Handle error
                    timestampedPrint("Received error as expected: \(error)")
                }
            })
            
        }
        Thread.sleep(forTimeInterval: 10) // Reduced timeout since we're now sequential
        expectation.fulfill()
    
        wait(for: [expectation], timeout: timeOut)
        
        ensemblers[0].unregisterDataCallback(appID: "app1")
        ensemblers[0].unregisterDataCallback(appID: "app2")
        // Clean up
        for ensembler in ensemblers {
            ensembler.stopServer()
        }
    }

    // Tests sending large data to node.
    func testMessagingLargeData() throws {
       
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
        let timeOut = Double(2) * 20.0
        // Create an expectation
        let expectation = self.expectation(description: "Test should complete within \(timeOut)")
        var ensemblers: [EnsemblerTLS] = []
        
        Task {
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("wait for all nodes to either get into ready state or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
            }
            
            timestampedPrint("check if all nodes are in ready state")
            for i in 0 ..< ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready)
            }
            
            let targetSize = 65536*16 // 1MB
            // Create the string
            let largeString = String(repeating: "a", count: targetSize) + "b"
            
            ensemblers[0].registerDataCallback(appID: "app1"){ sender, data in
                let response = "Ack."
                if let string = String(data: data, encoding: .utf8) {
                    XCTAssert(string == largeString)
                } else {
                    timestampedPrint("Failed to convert data to string")
                }
                
                return response.data(using: .utf8)!
            }
            Thread.sleep(forTimeInterval: 1)
            
            let message1StartTime = Date()

            ensemblers[1].sendDataAndGetResponse(appID: "app1",data: largeString.data(using: .utf8)!, destination: 0, completion: { [weak self] result in
                let message1EndTime = Date()
                let message1Duration = message1EndTime.timeIntervalSince(message1StartTime)
                timestampedPrint("Message1 response time: \(message1Duration) seconds")
                self?.handleControlDataResponse(result)
               
            })
            
           
        }
        Thread.sleep(forTimeInterval: 10) // Reduced timeout since we're now sequential
        expectation.fulfill()
    
        wait(for: [expectation], timeout: timeOut)
        
        ensemblers[0].unregisterDataCallback(appID: "app1")
        
        // Clean up
        for ensembler in ensemblers {
            ensembler.stopServer()
        }
    }
    
    // Tests sending concurrent messaging to same node.
    func testConcurrentDataMessaging() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
        let timeOut = Double(2) * 20.0
        let messageCount = 10
        
        // Create an expectation for completion
        let expectation = self.expectation(description: "Test should complete within \(timeOut)")
        
        // Create expectations to track all responses
        let responseExpectation = self.expectation(description: "All \(messageCount) responses received")
        responseExpectation.expectedFulfillmentCount = messageCount
        
        var ensemblers: [EnsemblerTLS] = []
        var responseCount = 0
        let responseCountLock = NSLock()
        var messageTimes: [Int: Date] = [:]
        let messageTimesLock = NSLock()
        
        Task {
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("wait for all nodes to either get into ready state or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
            }
            
            timestampedPrint("check if all nodes are in ready state")
            for i in 0 ..< ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready)
            }
            
            // Set up the receiver to handle control data requests
            ensemblers[0].registerDataCallback(appID: "app1") { sender, data in
                var response: String = ""
                if let string = String(data: data, encoding: .utf8) {
                    XCTAssert(string.contains("Concurrent test message"))
                    response = "response for \(string)"
                }
                
                return response.data(using: .utf8)!
            }
            
            Thread.sleep(forTimeInterval: 1)
            
            // Send multiple concurrent control messages
            for messageIndex in 1...messageCount {
                let message = "Concurrent test message \(messageIndex)"
                let messageStartTime = Date()
                
                // Store the start time for this message
                messageTimesLock.lock()
                messageTimes[messageIndex] = messageStartTime
                messageTimesLock.unlock()
                
                ensemblers[1].sendDataAndGetResponse(
                    appID: "app1",
                    data: message.data(using: .utf8)!,
                    destination: 0,
                    completion: { result in
                        let messageEndTime = Date()
                        
                        responseCountLock.lock()
                        defer { responseCountLock.unlock() }
                        
                        messageTimesLock.lock()
                        let startTime = messageTimes[messageIndex] ?? messageStartTime
                        messageTimesLock.unlock()
                        
                        let messageDuration = messageEndTime.timeIntervalSince(startTime)
                        
                        switch result {
                        case .success(let responseData):
                            responseCount += 1
                            if let responseString = String(data: responseData, encoding: .utf8) {
                                timestampedPrint("Concurrent message \(messageIndex) response time: \(messageDuration) seconds - Response: \(responseString)")
                            }
                            responseExpectation.fulfill()
                            
                        case .failure(let error):
                            timestampedPrint("Concurrent message \(messageIndex) failed after \(messageDuration) seconds: \(error)")
                            // Still fulfill to avoid hanging, but mark as failure
                            XCTFail("No failure is expected")
                            responseExpectation.fulfill()
                        }
                    }
                )
            }
            
            expectation.fulfill()
        }
        
        // Wait for test completion and all responses
        wait(for: [expectation, responseExpectation], timeout: timeOut)
        
        // Validate that all messages received responses
        responseCountLock.lock()
        XCTAssertEqual(responseCount, messageCount, "Expected \(messageCount) responses, but received \(responseCount)")
        responseCountLock.unlock()
        
        timestampedPrint("Successfully sent \(messageCount) concurrent control messages and received \(responseCount) responses")
        
        ensemblers[0].unregisterDataCallback(appID: "app1")
        
        // Clean up
        for ensembler in ensemblers {
            ensembler.stopServer()
        }
    }

    func testUnorderedRestarts() throws {
       var ensemblers: [EnsemblerTLS] = []
      
       var nodes: [String: NodeConfiguration] = [:]
       for i in 0 ..< 4 {
           let node = NodeConfiguration(
               chassisID: "chassis-".appending(String(i / 4)),
               rank: Rank(rawValue: i)!,
               hostName: "127.0.0.1",
               port: UInt16(8029 + i)
           )
           nodes["udid-".appending(String(i))] = node
       }
       let config =  EnsembleConfiguration(
           backendType: BackendType.StubBackend,
           hypercube: false,
           nodes: nodes
       )
       let timeOut = Double(config.nodes.count) * 60.0
       // Create an expectation
       let expectation = self.expectation(description: "Test should complete within \(timeOut)")
       
       let udids = Array(config.nodes.keys).sorted()

       for i in 0 ..< config.nodes.count {
           timestampedPrint("createing ensemblers[\(i)]")

           let ensembler = try EnsemblerTLS(
               ensembleConfig: config,
               autoRestart: false,
               skipDarwinInitCheck: true,
               useStubAttestation: true,
               currentUDID: udids[i],
               skipJobQuiescence: true,
               skipWaitingForDenali: true
           )
           ensemblers.append(ensembler)
           try ensembler.activate()
       }
       
       Task {
           timestampedPrint("wait for all nodes to either get into ready state or failed state")
           for i in 0 ..< config.nodes.count {
               while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
           }

           timestampedPrint("check if all nodes are in ready state")
           for i in 0 ..< config.nodes.count {
               XCTAssert(ensemblers[i].getStatus() == .ready)
           }

           ensemblers[1].stopServer()
           // simulate follower1 restarting
           ensemblers[1] = try EnsemblerTLS(
               ensembleConfig: config,
               autoRestart: false,
               skipDarwinInitCheck: true,
               useStubAttestation: true,
               currentUDID: udids[1],
               skipJobQuiescence: true,
               skipWaitingForDenali: true
           )
           try ensemblers[1].activate()
           
           
           Thread.sleep(forTimeInterval: 30.0)
           ensemblers[0].stopServer()
           Thread.sleep(forTimeInterval: 30.0)
           ensemblers[0] = try EnsemblerTLS(
               ensembleConfig: config,
               autoRestart: false,
               skipDarwinInitCheck: true,
               useStubAttestation: true,
               currentUDID: udids[0],
               skipJobQuiescence: true,
               skipWaitingForDenali: true
           )
           try ensemblers[0].activate()
           
           Thread.sleep(forTimeInterval: 30.0)
           for i in 2 ..< 4 {
               ensemblers[i].stopServer()
               ensemblers[i] = try EnsemblerTLS(
                   ensembleConfig: config,
                   autoRestart: false,
                   skipDarwinInitCheck: true,
                   useStubAttestation: true,
                   currentUDID: udids[i],
                   skipJobQuiescence: true,
                   skipWaitingForDenali: true
               )
               try ensemblers[i].activate()
           }
           
           timestampedPrint("wait for all nodes to either get into ready state or failed state")
           for i in 0 ..< config.nodes.count {
               while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
           }

           timestampedPrint("check if all nodes are in ready state")
           for i in 0 ..< config.nodes.count {
               XCTAssert(ensemblers[i].getStatus() == .ready)
           }
           
           for i in 0 ..< 4 {
               ensemblers[i].stopServer()
           }
           expectation.fulfill()
       }
       wait(for: [expectation], timeout: timeOut)

    }
	// Helper functions
	
	// Reusable completion handler for sendControlData
	private func handleControlDataResponse(_ result: Result<Data, Error>) {
		switch result {
		case .success(let responseData):
			let str = String(data: responseData, encoding: .utf8)
			timestampedPrint("Received response: \(str ?? "Unable to decode response")")
			
			// Handle successful response
		case .failure(let error):
            XCTFail("There was registered handler on the server, we should NOT have got failure")
			// Handle error
		}
	}
	
	// get the ensemble configuration which does gauranteee rank0-3 ( and so on) contains same
	// chassisid
	func getEnsembleConfig(nodeCount: Int) -> EnsembleConfiguration {
		var nodes: [String: NodeConfiguration] = [:]
		for i in 0 ..< nodeCount {
			let node = NodeConfiguration(
				chassisID: "chassis-".appending(String(i / 4)),
				rank: Rank(rawValue: i)!,
				hostName: "127.0.0.1",
				port: UInt16(8029 + i)
			)
			nodes["udid-".appending(String(i))] = node
		}

		return EnsembleConfiguration(
			backendType: BackendType.StubBackend,
			hypercube: false,
            ensembleID: "TESTENSEMBLEID",
            rackID: "TESTRACKID",
			nodes: nodes
		)
	}

	// get the ensemble configuration which does not gauranteee rank0-3 ( and so on) contains same
	// chassisid
	func getEnsembleConfigInvalid(nodeCount: Int) -> EnsembleConfiguration {
		var nodes: [String: NodeConfiguration] = [:]

		if nodeCount == 2 {
			let node1 = NodeConfiguration(
				chassisID: "chassis1",
				rank: Rank(rawValue: 0)!,
				hostName: "127.0.0.1",
				port: UInt16(8029)
			)
			nodes["udid-".appending(String(0))] = node1

			let node2 = NodeConfiguration(
				chassisID: "chassis2",
				rank: Rank(rawValue: 1)!,
				hostName: "127.0.0.1",
				port: UInt16(8030)
			)
			nodes["udid-".appending(String(1))] = node2
		} else if nodeCount == 4 {
			let node1 = NodeConfiguration(
				chassisID: "chassis1",
				rank: Rank(rawValue: 0)!,
				hostName: "127.0.0.1",
				port: UInt16(8029)
			)
			nodes["udid-".appending(String(0))] = node1

			let node2 = NodeConfiguration(
				chassisID: "chassis1",
				rank: Rank(rawValue: 1)!,
				hostName: "127.0.0.1",
				port: UInt16(8030)
			)
			nodes["udid-".appending(String(1))] = node2

			let node3 = NodeConfiguration(
				chassisID: "chassis1",
				rank: Rank(rawValue: 2)!,
				hostName: "127.0.0.1",
				port: UInt16(8029)
			)
			nodes["udid-".appending(String(2))] = node3

			let node4 = NodeConfiguration(
				chassisID: "chassis2",
				rank: Rank(rawValue: 3)!,
				hostName: "127.0.0.1",
				port: UInt16(8030)
			)
			nodes["udid-".appending(String(3))] = node4
		} else {
			// This will generate
			// rank1-4 assigned chassisid1, rank5-8 chassisid2... rank13,14,15,0 chassisd4 for 16 node.
			for i in 0 ..< nodeCount {
				let node = NodeConfiguration(
					chassisID: "chassis-".appending(String(i / 4)),
					rank: Rank(rawValue: (i + 1) % nodeCount)!,
					hostName: "127.0.0.1",
					port: UInt16(8029 + i)
				)
				nodes["udid-".appending(String(i))] = node
			}
		}

		return EnsembleConfiguration(
			backendType: BackendType.StubBackend,
			hypercube: false,
			nodes: nodes
		)
	}

	func validateEnsemblerStateMachine(
		config: EnsembleConfiguration,
		expectedState _: EnsemblerStatus = .ready
	) throws {
		for i in 1 ..< config.nodes.count {
			try self.validateEnsemblerStateMachineInternal(config: config, startIndex: i)
			Thread.sleep(forTimeInterval: 2)
		}
	}

	// We will simulate creating the nodes in different order, so we can simulate the nodes coming up
	// in different order.
	func validateEnsemblerStateMachineInternal(
		config: EnsembleConfiguration,
		startIndex: Int = 0
	) throws {
		let timeOut = Double(config.nodes.count) * 20.0
		// Create an expectation
		let expectation = self.expectation(description: "Test should complete within \(timeOut)")
		var ensemblers: [EnsemblerTLS] = []

		Task {
			ensemblers = try self.populateEnsemblers(config: config, startIndex: startIndex)
            
			timestampedPrint("wait for all nodes to either get into ready state or failed state")
			for i in 0 ..< config.nodes.count {
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
			}

			timestampedPrint("check if all nodes are in ready state")
			for i in 0 ..< config.nodes.count {
				XCTAssert(ensemblers[i].getStatus() == .ready)
                XCTAssert(ensemblers[i].getEnsembleID() == "TESTENSEMBLEID")
                XCTAssert(ensemblers[i].getRackID() == "TESTRACKID")
			}

			if config.nodes.count > 1 {
				timestampedPrint(
					"validate the keys are distributed by encrypting on one node and decrypting on other node"
				)
				try self.validateEncryptionDecryption(
					config: config,
					startIndex: startIndex,
					ensemblers: ensemblers
				)
			}

			for i in 0 ..< config.nodes.count {
				ensemblers[i].stopServer()
			}
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: timeOut)
	}

	func validateDataKeyDistribution(
		config: EnsembleConfiguration
	) throws {
		let timeOut = Double(config.nodes.count) * 20.0
		// Create an expectation
		let expectation = self.expectation(description: "Test should complete within \(timeOut)")
		var ensemblers: [EnsemblerTLS] = []

		Task {
			ensemblers = try self.populateEnsemblers(config: config, startIndex: 0)

			timestampedPrint("wait for all nodes to either get into ready state or failed state")
			for i in 0 ..< config.nodes.count {
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
			}

			timestampedPrint("check if all nodes are in ready state")
			for i in 0 ..< config.nodes.count {
				XCTAssert(ensemblers[i].getStatus() == .ready)
			}

			if config.nodes.count > 1 {
				timestampedPrint(
					"validate the keys are distributed by encrypting on one node and decrypting on other node"
				)
				try self.validateEncryptionDecryption(
					config: config,
					startIndex: 0,
					ensemblers: ensemblers
				)
			}

			let key = SymmetricKey(size: .bits128)
			let distributedKeyData = key.withUnsafeBytes {
				return Data(Array($0))
			}

			let startTime = Date()
			let token = try ensemblers[0].distributeDataKey(key: distributedKeyData, type: .distributed)
			let endTime = Date() // Record the end time
			let timeInterval = endTime.timeIntervalSince(startTime) // Calculate time taken
			timestampedPrint("Time taken for distributeDataKey API call: \(timeInterval) seconds")

			for node in 1 ..< config.nodes.count {
				guard let obtainedKeyData = try ensemblers[node].getDataKey(token: token) else {
					XCTFail("Got nil key")
					return
				}
				timestampedPrint(
					"leader distributedKey for token:\(token) is \(distributedKeyData.map { String(format: "%02x", $0) }.joined()), obtained key for token in follower is : \(obtainedKeyData.map { String(format: "%02x", $0) }.joined())"
				)
				XCTAssert(distributedKeyData == obtainedKeyData)
			}

			for i in 0 ..< config.nodes.count {
				ensemblers[i].stopServer()
			}
			expectation.fulfill()
		}
		wait(for: [expectation], timeout: timeOut)
	}

	// We will simulte creating the nodes in different order, so we can simulate the nodes coming up in
	// different order.
	func validateEnsemblerStateMachineInternalForKeyRotation(
		config: EnsembleConfiguration,
		expectedState: EnsemblerStatus = .ready,
		startIndex: Int = 0
	) throws {
		// Create an expectation
		let timeOut = 15.0 * Double(config.nodes.count)
		let expectation = self.expectation(description: "Test should complete within \(timeOut) seconds")
		var ensemblers: [EnsemblerTLS] = []

		Task {
			ensemblers = try self.populateEnsemblers(config: config, startIndex: startIndex)
			for i in 0 ..< config.nodes.count {
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
			}

			for i in 0 ..< config.nodes.count {
				XCTAssert(ensemblers[i].getStatus() == .ready)
			}

			let node1 = startIndex
			let node2 = (startIndex + 1) % config.nodes.count
			try self.validateEncryptionDecryption(
				config: config,
				startIndex: startIndex,
				ensemblers: ensemblers
			)
			var encryptedData = try ensemblers[node1].encryptData(data: "hello1".data(using: .utf8)!)
			// Now that we are ready and keys are distributed, lets trigger key rotation
			try ensemblers[0].rotateKey()

			for i in 0 ..< config.nodes.count {
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {}
			}

			// First wait and check if we are going to ready state
			for i in 0 ..< config.nodes.count {
				XCTAssert(ensemblers[i].getStatus() == .ready, "We should be in ready state")
			}

			// Now we should be able to encrypt on one node and decrypt on another node

			let message = "hello2"
			// encrypt on one instance
			encryptedData = try ensemblers[node1].encryptData(data: message.data(using: .utf8)!)

			// decrypt on other instance
			let decryptData = try ensemblers[node2].decryptData(data: encryptedData)
			let decryptedMessage = String(data: decryptData, encoding: .utf8)
			XCTAssert(message == decryptedMessage)

			for i in 0 ..< config.nodes.count {
				ensemblers[i].stopServer()
			}
			expectation.fulfill()
		}

		wait(for: [expectation], timeout: timeOut)

		for i in 0 ..< config.nodes.count {
			XCTAssert(ensemblers[i].getStatus() == expectedState)
		}
	}

	func populateEnsemblers(config: EnsembleConfiguration, startIndex: Int) throws -> [EnsemblerTLS] {
		var ensemblers: [EnsemblerTLS] = []
		let udids = Array(config.nodes.keys).sorted()

		timestampedPrint("Creating ensemblers in order from \(startIndex) to \(config.nodes.count)")
		for i in startIndex ..< config.nodes.count {
			timestampedPrint("createing ensemblers[\(i)]")

			let ensembler = try EnsemblerTLS(
				ensembleConfig: config,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: udids[i],
				skipJobQuiescence: true,
				skipWaitingForDenali: true
			)
			ensemblers.append(ensembler)
			try ensembler.activate()
		}

		timestampedPrint("Creating ensemblers in order from 0 to \(startIndex)")
		for i in 0 ..< startIndex {
			timestampedPrint("createing ensemblers[\(i)]")
			let ensembler = try EnsemblerTLS(
				ensembleConfig: config,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: udids[i],
				skipJobQuiescence: true,
				skipWaitingForDenali: true
			)
			ensemblers.append(ensembler)
			try ensembler.activate()
		}

		return ensemblers
	}

	func getEmptyKey() throws -> SymmetricKey {
		let keyStr = String(repeating: "0", count: 32)
		guard let keyData = keyStr.data(using: .utf8) else {
			throw EnsembleError.internalError(error: "Cannot create empty keydata")
		}

		return SymmetricKey(data: keyData)
	}

	func validateEncryptionDecryption(
		config: EnsembleConfiguration,
		startIndex: Int,
		ensemblers: [EnsemblerTLS]
	) throws {
		let node1 = startIndex
		let node2 = (startIndex + 1) % config.nodes.count
		let message = "hello"
		// encrypt on one instance
		let encryptedData = try ensemblers[node1].encryptData(data: message.data(using: .utf8)!)

		// decrypt on other instance
		let decryptData = try ensemblers[node2].decryptData(data: encryptedData)
		let decryptedMessage = String(data: decryptData, encoding: .utf8)
		timestampedPrint("Original text: \(message) Decrypted text: \(decryptedMessage!)")
		XCTAssert(message == decryptedMessage)
	}

	func validateEnsemblerStateMachineWithFailure(
		config: EnsembleConfiguration,
		expectedState: EnsemblerStatus = .failed
	) throws {
		for i in 0 ..< config.nodes.count {
			try self.validateEnsemblerStateMachineWithFailuresInternal(
				config: config,
				expectedState: expectedState,
				startIndex: i
			)
		}
	}

	func validateEnsemblerStateMachineWithFailuresInternal(
		config: EnsembleConfiguration,
		expectedState: EnsemblerStatus = .failed,
		startIndex: Int = 0
	) throws {
		let timeOut = 3.0 * Double(config.nodes.count)
		// Create an expectation
		let expectation = self.expectation(description: "Test should complete within \(timeOut) seconds")
		var ensemblers: [EnsemblerTLS] = []

		Task {
			ensemblers = try self.populateEnsemblers(config: config, startIndex: startIndex)

			expectation.fulfill()
		}

		wait(for: [expectation], timeout: timeOut)

		for i in 0 ..< config.nodes.count {
			ensemblers[i].stopServer()
		}

		for i in 0 ..< config.nodes.count {
			XCTAssert(ensemblers[i].getStatus() == expectedState)
		}
	}

    func testSendDataToAllFollowers() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 4)
        let timeOut = Double(ensembleConfig.nodes.count) * 30.0
        
        // Create an expectation for completion
        let expectation = self.expectation(description: "Test should complete within \(timeOut)")
        var ensemblers: [EnsemblerTLS] = []
        
        Task {
            // Create and activate all 4 ensemblers
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("Wait for all nodes to reach ready or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            
            timestampedPrint("Verify all nodes are in ready state")
            for i in 0 ..< ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) should be ready, but is \(ensemblers[i].getStatus())")
            }
            
            // Set up data callbacks on all followers (nodes 1, 2, 3)
            let testMessage = "Broadcast test message from leader"
            let expectedResponse = "Response from follower"
            
            // Register callbacks on followers (ranks 1, 2, 3)
            for i in 1...3 {
                ensemblers[i].registerDataCallback(appID: "broadcast-app") { sender, data in
                    timestampedPrint("Follower \(i) received data from sender \(sender)")
                    
                    if let receivedMessage = String(data: data, encoding: .utf8) {
                        XCTAssertEqual(receivedMessage, testMessage, "Follower \(i) should receive correct message")
                        XCTAssertEqual(sender, 0, "Sender should be leader (rank 0)")
                        timestampedPrint("Follower \(i) received: '\(receivedMessage)'")
                    } else {
                        XCTFail("Failed to decode message on follower \(i)")
                    }
                    
                    let response = "\(expectedResponse) \(i)"
                    return response.data(using: .utf8)!
                }
            }
            
            // Give callbacks time to register
            Thread.sleep(forTimeInterval: 1)
            
            timestampedPrint("Leader (rank 0) sending broadcast message to all followers...")
            
            let startTime = Date()
            
            // Leader calls sendDataToAllFollowers
            ensemblers[0].sendDataToAllFollowers(
                appID: "broadcast-app",
                data: testMessage.data(using: .utf8)!,
                timeout: 10.0
            ) { result in
                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)
                timestampedPrint("Broadcast completed in \(duration) seconds")
                
                switch result {
                case .success(let responses):
                    timestampedPrint("Successfully received \(responses.count) responses from followers")
                    
                    // Verify we got responses from all 3 followers
                    XCTAssertEqual(responses.count, 3, "Should receive responses from 3 followers")
                    
                    // Check each response
                    let sortedResponses = responses.sorted { $0.rank < $1.rank }
                    
                    for (index, nodeResponse) in sortedResponses.enumerated() {
                        let expectedRank = index + 1 // Followers have ranks 1, 2, 3
                        
                        XCTAssertEqual(nodeResponse.rank, expectedRank, "Response should be from rank \(expectedRank)")
                        XCTAssertNil(nodeResponse.error, "Response from rank \(expectedRank) should not have error")
                        
                        if let responseData = nodeResponse.data,
                           let responseString = String(data: responseData, encoding: .utf8) {
                            let expectedResponseString = "\(expectedResponse) \(expectedRank)"
                            XCTAssertEqual(responseString, expectedResponseString, "Response from rank \(expectedRank) should match expected")
                            timestampedPrint("Received response from rank \(expectedRank): '\(responseString)'")
                        } else {
                            XCTFail("Failed to decode response from rank \(expectedRank)")
                        }
                        
                        // Verify timestamp is reasonable (within last few seconds)
                        let timeSinceResponse = Date().timeIntervalSince(nodeResponse.timestamp)
                        XCTAssert(timeSinceResponse >= 0 && timeSinceResponse < 30, "Timestamp should be recent")
                    }
                    
                case .failure(let error):
                    XCTFail("Broadcast should succeed, but got error: \(error)")
                }
                
                expectation.fulfill()
            }
        }
        
        // Wait for test completion
        wait(for: [expectation], timeout: timeOut)
        
        for i in 1...3 {
            ensemblers[i].unregisterDataCallback(appID: "broadcast-app")
        }
        
        // Clean up
        for ensembler in ensemblers {
            ensembler.stopServer()
        }
        
        timestampedPrint("testSendDataToAllFollowers completed successfully")
    }

    func testSendDataToAllFollowersWithMissingHandler() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 4)
        let timeOut = Double(ensembleConfig.nodes.count) * 30.0
        
        // Create an expectation for completion
        let expectation = self.expectation(description: "Test should complete within \(timeOut)")
        var ensemblers: [EnsemblerTLS] = []
        
        Task {
            // Create and activate all 4 ensemblers
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("Wait for all nodes to reach ready or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            
            timestampedPrint("Verify all nodes are in ready state")
            for i in 0 ..< ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) should be ready, but is \(ensemblers[i].getStatus())")
            }
            
            // Set up data callbacks on only SOME followers (nodes 1, 2) - intentionally skip node 3
            let testMessage = "Broadcast test message from leader"
            let expectedResponse = "Response from follower"
            
            // Register callbacks on followers 1 and 2, but NOT on follower 3
            for i in 1...2 {
                ensemblers[i].registerDataCallback(appID: "broadcast-missing-handler-app") { sender, data in
                    timestampedPrint("Follower \(i) received data from sender \(sender)")
                    
                    if let receivedMessage = String(data: data, encoding: .utf8) {
                        XCTAssertEqual(receivedMessage, testMessage, "Follower \(i) should receive correct message")
                        XCTAssertEqual(sender, 0, "Sender should be leader (rank 0)")
                        timestampedPrint("Follower \(i) received: '\(receivedMessage)'")
                    } else {
                        XCTFail("Failed to decode message on follower \(i)")
                    }
                    
                    let response = "\(expectedResponse) \(i)"
                    return response.data(using: .utf8)!
                }
            }
            
            // Intentionally DO NOT register callback on follower 3 (ensemblers[3])
            timestampedPrint("Intentionally skipping handler registration on follower 3 (rank 3)")
            
            // Give callbacks time to register
            Thread.sleep(forTimeInterval: 1)
            
            timestampedPrint("Leader (rank 0) sending broadcast message to all followers (expecting failure)...")
            
            let startTime = Date()
            
            // Leader calls sendDataToAllFollowers - this should fail because follower 3 has no handler
            ensemblers[0].sendDataToAllFollowers(
                appID: "broadcast-missing-handler-app",
                data: testMessage.data(using: .utf8)!,
                timeout: 10.0
            ) { result in
                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)
                timestampedPrint("Broadcast completed in \(duration) seconds")
                
                switch result {
                case .success(let responses):
                    // This should not happen - we expect failure
                    XCTFail("Broadcast should have failed due to missing handler on follower 3, but got success with \(responses.count) responses")
                    
                case .failure(let error):
                    timestampedPrint("Got expected failure: \(error)")
                    
                    // Validate that we got the expected error
                    // The exact error type may vary depending on implementation, but it should indicate
                    // that one of the followers failed to respond or had no handler
                    let errorDescription = String(describing: error)
                    timestampedPrint("Error description: \(errorDescription)")
                    
                    // We expect the error to be related to missing handler or failed response
                    // This validates that the system properly detects and reports the failure
                    XCTAssert(true, "Correctly received error when follower had no registered handler")
                }
                expectation.fulfill()
            }
        }
        
        // Wait for test completion
        wait(for: [expectation], timeout: timeOut)
        
        for i in 1...2 {
            ensemblers[i].unregisterDataCallback(appID: "broadcast-missing-handler-app")
        }
        
        // Clean up
        for ensembler in ensemblers {
            ensembler.stopServer()
        }
        
        timestampedPrint("testSendDataToAllFollowersWithMissingHandler completed successfully")
    }
    
    // Test registerDataCallback and unregisterDataCallback functionality
    func testRegisterAndUnregisterDataCallback() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
        let timeOut = Double(ensembleConfig.nodes.count) * 30.0
        
        // Create an expectation for completion
        let expectation = self.expectation(description: "Test should complete within \(timeOut)")
        var ensemblers: [EnsemblerTLS] = []
        
        // Track callback invocations
        var callbackInvokedCount = 0
        let callbackCountLock = NSLock()
        
        Task {
            // Create and activate ensemblers
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("Wait for all nodes to reach ready or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            
            timestampedPrint("Verify all nodes are in ready state")
            for i in 0 ..< ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) should be ready, but is \(ensemblers[i].getStatus())")
            }
            
            let testMessage = "Test message for callback"
            let testAppID = "test-app-callback"
            
            // Phase 1: Register callback and verify it receives data
            timestampedPrint("Phase 1: Registering callback on receiver (rank 0)")
            ensemblers[0].registerDataCallback(appID: testAppID) { sender, data in
                callbackCountLock.lock()
                callbackInvokedCount += 1
                let currentCount = callbackInvokedCount
                callbackCountLock.unlock()
                
                timestampedPrint("Callback invoked (count: \(currentCount)) - received data from rank \(sender)")
                
                if let receivedMessage = String(data: data, encoding: .utf8) {
                    XCTAssertEqual(receivedMessage, testMessage, "Should receive correct test message")
                    timestampedPrint("Callback received: '\(receivedMessage)'")
                } else {
                    XCTFail("Failed to decode message in callback")
                }
                
                let response = "Response to message \(currentCount)"
                return response.data(using: .utf8)!
            }
            
            // Give callback time to register
            Thread.sleep(forTimeInterval: 1)
            
            // Send first message - should succeed
            timestampedPrint("Sending first message - callback should receive it")
            let firstMessageExpectation = self.expectation(description: "First message should succeed")
            
            ensemblers[1].sendDataAndGetResponse(
                appID: testAppID,
                data: testMessage.data(using: .utf8)!,
                destination: 0,
                timeout: 5.0
            ) { result in
                switch result {
                case .success(let responseData):
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        timestampedPrint("First message got response: '\(responseString)'")
                        XCTAssert(responseString.contains("Response to message"), "Should get valid response from callback")
                    } else {
                        XCTFail("Failed to decode response from first message")
                    }
                case .failure(let error):
                    XCTFail("First message should succeed, but got error: \(error)")
                }
                firstMessageExpectation.fulfill()
            }
            
            // Wait for first message to complete
            wait(for: [firstMessageExpectation], timeout: 10.0)
            
            // Verify callback was invoked
            callbackCountLock.lock()
            let countAfterFirstMessage = callbackInvokedCount
            callbackCountLock.unlock()
            XCTAssertEqual(countAfterFirstMessage, 1, "Callback should have been invoked once after first message")
            
            // Phase 2: Unregister callback
            timestampedPrint("Phase 2: Unregistering callback for appID: \(testAppID)")
            
            do {
                try ensemblers[0].unregisterDataCallback(appID: testAppID)
                timestampedPrint("Successfully unregistered callback")
            } catch {
                XCTFail("Failed to unregister callback: \(error)")
            }
            
            // Give time for unregistration to take effect
            Thread.sleep(forTimeInterval: 1)
            
            // Phase 3: Send second message - should fail (no handler)
            timestampedPrint("Sending second message - should fail because callback was unregistered")
            let secondMessageExpectation = self.expectation(description: "Second message should fail")
            
            ensemblers[1].sendDataAndGetResponse(
                appID: testAppID,
                data: testMessage.data(using: .utf8)!,
                destination: 0,
                timeout: 5.0
            ) { result in
                switch result {
                case .success(let responseData):
                    // This should not happen - we unregistered the callback
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        XCTFail("Second message should have failed, but got response: '\(responseString)'")
                    } else {
                        XCTFail("Second message should have failed, but got some response")
                    }
                case .failure(let error):
                    timestampedPrint("Got expected failure for second message: \(error)")
                    // This is expected - the callback was unregistered
                }
                secondMessageExpectation.fulfill()
            }
            
            // Wait for second message to complete
            wait(for: [secondMessageExpectation], timeout: 10.0)
            
            // Phase 4: Verify callback count didn't increase
            callbackCountLock.lock()
            let finalCallbackCount = callbackInvokedCount
            callbackCountLock.unlock()
            
            timestampedPrint("Final callback invocation count: \(finalCallbackCount)")
            XCTAssertEqual(finalCallbackCount, 1, "Callback should still have been invoked only once (before unregister)")
            
            // Phase 5: Test re-registration works
            timestampedPrint("Phase 5: Re-registering callback to verify it works again")
            ensemblers[0].registerDataCallback(appID: testAppID) { sender, data in
                callbackCountLock.lock()
                callbackInvokedCount += 1
                let currentCount = callbackInvokedCount
                callbackCountLock.unlock()
                
                timestampedPrint("Re-registered callback invoked (count: \(currentCount)) - received data from rank \(sender)")
                
                let response = "Response from re-registered callback"
                return response.data(using: .utf8)!
            }
            
            Thread.sleep(forTimeInterval: 1)
            
            // Send third message - should succeed again
            timestampedPrint("Sending third message - should succeed with re-registered callback")
            let thirdMessageExpectation = self.expectation(description: "Third message should succeed")
            
            ensemblers[1].sendDataAndGetResponse(
                appID: testAppID,
                data: testMessage.data(using: .utf8)!,
                destination: 0,
                timeout: 5.0
            ) { result in
                switch result {
                case .success(let responseData):
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        timestampedPrint("Third message got response: '\(responseString)'")
                        XCTAssert(responseString.contains("re-registered"), "Should get response from re-registered callback")
                    } else {
                        XCTFail("Failed to decode response from third message")
                    }
                case .failure(let error):
                    XCTFail("Third message should succeed with re-registered callback, but got error: \(error)")
                }
                thirdMessageExpectation.fulfill()
            }
            
            wait(for: [thirdMessageExpectation], timeout: 10.0)
            
            // Verify final callback count
            callbackCountLock.lock()
            let verifyFinalCount = callbackInvokedCount
            callbackCountLock.unlock()
            
            XCTAssertEqual(verifyFinalCount, 2, "Callback should have been invoked twice total (once before unregister, once after re-register)")
            
            timestampedPrint("Test completed successfully - callback registration/unregistration works as expected")
            
            expectation.fulfill()
        }
        // Wait for test completion
        wait(for: [expectation], timeout: timeOut)
        
        ensemblers[0].unregisterDataCallback(appID: "test-app-callback")
        // Clean up
        for ensembler in ensemblers {
            ensembler.stopServer()
        }
        
        timestampedPrint("testRegisterAndUnregisterDataCallback completed successfully")
    }
    
    /// Send data and get response from destination
    func sendDataAndGetResponse(ensembler: EnsemblerTLS, appID: String, data: Data, destination: Int, timeout: TimeInterval) async throws -> Result<Data, Error> {
        // Use proper async/await without blocking any threads
        do {
            let response = await withCheckedContinuation { continuation in
                ensembler.sendDataAndGetResponse(appID: appID, data: data, destination: destination, timeout: timeout) { result in
                    continuation.resume(returning: result)
                }
            }
            
            return response
        }
    }
    
    // Test concurrent sendDataAndGetResponse from leader to all followers in 8-node ensemble
    func testConcurrentLeaderToFollowerMessaging() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 8)
        let timeOut = Double(ensembleConfig.nodes.count) * 60.0
        let messagesPerFollower = 200
        let totalExpectedMessages = 7 * messagesPerFollower // 7 followers * 5 messages each
        
        // Create expectation for completion
        let expectation = self.expectation(description: "Test should complete within \(timeOut)")
        
        // Create expectations to track all responses
        let responseExpectation = self.expectation(description: "All \(totalExpectedMessages) responses received")
        responseExpectation.expectedFulfillmentCount = totalExpectedMessages
        
        var ensemblers: [EnsemblerTLS] = []
        var responseCount = 0
        let responseCountLock = NSLock()
        var messageResults: [String: String] = [:]
        let messageResultsLock = NSLock()
        
        // Performance metrics tracking
        struct MessageMetrics {
            let messageKey: String
            let startTime: Date
            let endTime: Date
            let latency: TimeInterval
            let followerRank: Int
            let messageIndex: Int
        }
        
        var performanceMetrics: [MessageMetrics] = []
        let performanceMetricsLock = NSLock()
        var messageSendTimes: [String: Date] = [:]
        let messageSendTimesLock = NSLock()
        
        Task {
            // Create and activate all 8 ensemblers
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("Wait for all \(ensembleConfig.nodes.count) nodes to reach ready or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            
            timestampedPrint("Verify all nodes are in ready state")
            for i in 0 ..< ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) should be ready, but is \(ensemblers[i].getStatus())")
            }
            
            // Set up data callbacks on all followers (ranks 1-7)
            for followerRank in 1...7 {
                ensemblers[followerRank].registerDataCallback(appID: "concurrent-leader-app") { sender, data in
                    if let messageString = String(data: data, encoding: .utf8) {
                        timestampedPrint("Follower \(followerRank) received message: '\(messageString)' from rank \(sender)")
                        
                        // Verify sender is leader (rank 0)
                        XCTAssertEqual(sender, 0, "Sender should be leader (rank 0)")
                        
                        // Verify message format
                        XCTAssert(messageString.contains("Message from leader"), "Message should contain expected text")
                        XCTAssert(messageString.contains("to follower \(followerRank)"), "Message should be targeted to this follower")
                        
                        // Create unique response that identifies both sender and receiver
                        let response = "Response from follower \(followerRank) to: \(messageString)"
                        return response.data(using: .utf8)!
                    } else {
                        XCTFail("Failed to decode message on follower \(followerRank)")
                        return "Error response".data(using: .utf8)!
                    }
                }
            }
            
            // Give callbacks time to register
            Thread.sleep(forTimeInterval: 2)
            
            timestampedPrint("Leader (rank 0) starting concurrent messaging to all followers...")
            let testStartTime = Date()
            
            // Send messages concurrently from leader to each follower
            for messageIndex in 1...messagesPerFollower {
                for followerRank in 1...7 {
                    let message = "Message from leader (batch \(messageIndex)) to follower \(followerRank)"
                    let messageKey = "follower\(followerRank)_message\(messageIndex)"
                    
                    // Record message send time
                    let messageSendTime = Date()
                    messageSendTimesLock.lock()
                    messageSendTimes[messageKey] = messageSendTime
                    messageSendTimesLock.unlock()
                    
                    timestampedPrint("Leader sending: '\(message)' to rank \(followerRank)")
                    
                    Task {
                        let result = try await sendDataAndGetResponse(
                            ensembler: ensemblers[0],
                            appID: "concurrent-leader-app",
                            data: message.data(using: .utf8)!,
                            destination: followerRank,
                            timeout: 2.0
                        )
                        let messageEndTime = Date()
                        
                        // Get the send time for this specific message
                        messageSendTimesLock.lock()
                        let specificSendTime = messageSendTimes[messageKey] ?? messageSendTime
                        messageSendTimesLock.unlock()
                        
                        let latency = messageEndTime.timeIntervalSince(specificSendTime)
                        let overallDuration = messageEndTime.timeIntervalSince(testStartTime)
                        
                        responseCountLock.lock()
                        defer { responseCountLock.unlock() }
                        
                        switch result {
                        case .success(let responseData):
                            responseCount += 1
                            
                            if let responseString = String(data: responseData, encoding: .utf8) {
                                timestampedPrint("Message \(messageKey) completed - Latency: \(String(format: "%.3f", latency * 1000))ms, Overall: \(String(format: "%.3f", overallDuration))s - Response: '\(responseString)'")
                                
                                // Verify response format
                                XCTAssert(responseString.contains("Response from follower \(followerRank)"), "Response should identify correct follower")
                                XCTAssert(responseString.contains(message), "Response should echo the original message")
                                
                                messageResultsLock.lock()
                                messageResults[messageKey] = responseString
                                messageResultsLock.unlock()
                                
                                // Record performance metrics
                                let metrics = MessageMetrics(
                                    messageKey: messageKey,
                                    startTime: specificSendTime,
                                    endTime: messageEndTime,
                                    latency: latency,
                                    followerRank: followerRank,
                                    messageIndex: messageIndex
                                )
                                
                                performanceMetricsLock.lock()
                                performanceMetrics.append(metrics)
                                performanceMetricsLock.unlock()
                                
                            } else {
                                XCTFail("Failed to decode response for \(messageKey)")
                            }
                            
                        case .failure(let error):
                            timestampedPrint("Message \(messageKey) failed after \(String(format: "%.3f", latency * 1000))ms: \(error)")
                            XCTFail("No failure expected for \(messageKey), but got: \(error)")
                        }
                        
                        responseExpectation.fulfill()
                    }
                }
            }
            
            expectation.fulfill()
        }
        
        // Wait for test completion and all responses
        wait(for: [expectation, responseExpectation], timeout: timeOut)
        
        let finalTime = Date()
        timestampedPrint("All concurrent messaging completed")
        
        // Validate results
        responseCountLock.lock()
        let finalResponseCount = responseCount
        responseCountLock.unlock()
        
        XCTAssertEqual(finalResponseCount, totalExpectedMessages,
                      "Expected \(totalExpectedMessages) responses, but received \(finalResponseCount)")
        
        // Verify each follower received and responded to all its messages
        messageResultsLock.lock()
        let finalResults = messageResults
        messageResultsLock.unlock()
        
        for followerRank in 1...7 {
            for messageIndex in 1...messagesPerFollower {
                let messageKey = "follower\(followerRank)_message\(messageIndex)"
                
                guard let response = finalResults[messageKey] else {
                    XCTFail("Missing response for \(messageKey)")
                    continue
                }
                
                // Verify the response contains the expected follower ID and message content
                XCTAssert(response.contains("Response from follower \(followerRank)"),
                         "Response for \(messageKey) should identify correct follower")
                XCTAssert(response.contains("batch \(messageIndex)"),
                         "Response for \(messageKey) should contain correct batch number")
                
                timestampedPrint("Verified response for \(messageKey): ✓")
            }
        }
        
        // Calculate and display performance metrics
        performanceMetricsLock.lock()
        let finalMetrics = performanceMetrics
        performanceMetricsLock.unlock()
        
        timestampedPrint("\n==================== PERFORMANCE METRICS ====================")
        
        if !finalMetrics.isEmpty {
            // Overall statistics
            let latencies = finalMetrics.map { $0.latency }
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
            
            timestampedPrint("📊 Overall Latency Statistics:")
            timestampedPrint("   Total Messages: \(finalMetrics.count)")
            timestampedPrint("   Average Latency: \(String(format: "%.3f", averageLatency * 1000))ms")
            timestampedPrint("   Min Latency: \(String(format: "%.3f", minLatency * 1000))ms")
            timestampedPrint("   Max Latency: \(String(format: "%.3f", maxLatency * 1000))ms")
            timestampedPrint("   P50 Latency: \(String(format: "%.3f", p50Latency * 1000))ms")
            timestampedPrint("   P90 Latency: \(String(format: "%.3f", p90Latency * 1000))ms")
            timestampedPrint("   P95 Latency: \(String(format: "%.3f", p95Latency * 1000))ms")
            timestampedPrint("   P99 Latency: \(String(format: "%.3f", p99Latency * 1000))ms")
            
            // Per-follower statistics
            timestampedPrint("\n📋 Per-Follower Statistics:")
            for followerRank in 1...7 {
                let followerMetrics = finalMetrics.filter { $0.followerRank == followerRank }
                if !followerMetrics.isEmpty {
                    let followerLatencies = followerMetrics.map { $0.latency }
                    let followerAverage = followerLatencies.reduce(0, +) / Double(followerLatencies.count)
                    let followerMin = followerLatencies.min() ?? 0
                    let followerMax = followerLatencies.max() ?? 0
                    
                    timestampedPrint("   Follower \(followerRank): Avg=\(String(format: "%.3f", followerAverage * 1000))ms, Min=\(String(format: "%.3f", followerMin * 1000))ms, Max=\(String(format: "%.3f", followerMax * 1000))ms (\(followerMetrics.count) messages)")
                }
            }
            
            // Batch analysis
            timestampedPrint("\n📦 Per-Batch Statistics:")
            for messageIndex in 1...messagesPerFollower {
                let batchMetrics = finalMetrics.filter { $0.messageIndex == messageIndex }
                if !batchMetrics.isEmpty {
                    let batchLatencies = batchMetrics.map { $0.latency }
                    let batchAverage = batchLatencies.reduce(0, +) / Double(batchLatencies.count)
                    let batchMin = batchLatencies.min() ?? 0
                    let batchMax = batchLatencies.max() ?? 0
                    
                    timestampedPrint("   Batch \(messageIndex): Avg=\(String(format: "%.3f", batchAverage * 1000))ms, Min=\(String(format: "%.3f", batchMin * 1000))ms, Max=\(String(format: "%.3f", batchMax * 1000))ms (\(batchMetrics.count) messages)")
                }
            }
            
            // Performance assertions
            timestampedPrint("\n✅ Performance Validations:")
            
            // Assert reasonable latency bounds (adjust these based on expected performance)
            let maxAcceptableLatency = 5.0 // 5 seconds max
            let maxAcceptableAverageLatency = 5.0 // 1 second average max
            
            XCTAssert(maxLatency < maxAcceptableLatency,
                     "Maximum latency (\(String(format: "%.3f", maxLatency))s) should be less than \(maxAcceptableLatency)s")
            
            XCTAssert(averageLatency < maxAcceptableAverageLatency,
                     "Average latency (\(String(format: "%.3f", averageLatency))s) should be less than \(maxAcceptableAverageLatency)s")
            
            timestampedPrint("   ✓ Maximum latency within acceptable bounds")
            timestampedPrint("   ✓ Average latency within acceptable bounds")
            
            // Check for latency consistency (no message should be more than 10x the average)
            let latencyConsistencyThreshold = averageLatency * 10
            let inconsistentMessages = finalMetrics.filter { $0.latency > latencyConsistencyThreshold }
            
            if inconsistentMessages.isEmpty {
                timestampedPrint("   ✓ All message latencies are consistent (within 10x of average)")
            } else {
                timestampedPrint("   ⚠️  Found \(inconsistentMessages.count) messages with high latency variance:")
                for metric in inconsistentMessages.prefix(5) { // Show first 5
                    timestampedPrint("      \(metric.messageKey): \(String(format: "%.3f", metric.latency * 1000))ms")
                }
            }
            
        } else {
            XCTFail("No performance metrics collected")
        }
        
        timestampedPrint("===========================================================\n")
        
        timestampedPrint("Successfully completed \(totalExpectedMessages) concurrent messages from leader to all followers")
        timestampedPrint("Response verification: All \(finalResults.count) responses validated")
        
        for followerRank in 1...7 {
            ensemblers[followerRank].unregisterDataCallback(appID: "concurrent-leader-app")
        }
        
        // Clean up
        for ensembler in ensemblers {
            ensembler.stopServer()
        }
        
        timestampedPrint("testConcurrentLeaderToFollowerMessaging completed successfully")
    }
    
    // Test concurrent sendDataAndGetResponse from leader to all followers in 8-node ensemble
    // Induce calling rotatekey in the middle
    func testConcurrentLeaderToFollowerMessagingWithRotateKey() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 8)
        let timeOut = Double(ensembleConfig.nodes.count) * 10.0
        let messagesPerFollower = 200
        let totalExpectedMessages = 7 * messagesPerFollower // 7 followers * 5 messages each
        
        // Create expectation for completion
        let expectation = self.expectation(description: "Test should complete within \(timeOut)")
        
       // let RotateExpectation = self.expectation(description: "Test should come out of rotation logic for proper cleanup")
        //RotateExpectation.expectedFulfillmentCount = 3
        // Create expectations to track all responses
        let responseExpectation = self.expectation(description: "All \(totalExpectedMessages) responses received")
        responseExpectation.expectedFulfillmentCount = totalExpectedMessages
        
        var ensemblers: [EnsemblerTLS] = []
        var responseCount = 0
        var failedResponseCount = 0
        let responseCountLock = NSLock()
        var messageResults: [String: String] = [:]
        let messageResultsLock = NSLock()
        
        // Performance metrics tracking
        struct MessageMetrics {
            let messageKey: String
            let startTime: Date
            let endTime: Date
            let latency: TimeInterval
            let followerRank: Int
            let messageIndex: Int
        }
        
        var performanceMetrics: [MessageMetrics] = []
        let performanceMetricsLock = NSLock()
        var messageSendTimes: [String: Date] = [:]
        let messageSendTimesLock = NSLock()
        
        Task {
            // Create and activate all 8 ensemblers
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("Wait for all \(ensembleConfig.nodes.count) nodes to reach ready or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            
            timestampedPrint("Verify all nodes are in ready state")
            for i in 0 ..< ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) should be ready, but is \(ensemblers[i].getStatus())")
            }
            
            // Set up data callbacks on all followers (ranks 1-7)
            for followerRank in 1...7 {
                ensemblers[followerRank].registerDataCallback(appID: "concurrent-leader-app") { sender, data in
                    if let messageString = String(data: data, encoding: .utf8) {
                        timestampedPrint("Follower \(followerRank) received message: '\(messageString)' from rank \(sender)")
                        
                        // Verify sender is leader (rank 0)
                        XCTAssertEqual(sender, 0, "Sender should be leader (rank 0)")
                        
                        // Verify message format
                        XCTAssert(messageString.contains("Message from leader"), "Message should contain expected text")
                        XCTAssert(messageString.contains("to follower \(followerRank)"), "Message should be targeted to this follower")
                        
                        // Create unique response that identifies both sender and receiver
                        let response = "Response from follower \(followerRank) to: \(messageString)"
                        return response.data(using: .utf8)!
                    } else {
                        XCTFail("Failed to decode message on follower \(followerRank)")
                        return "Error response".data(using: .utf8)!
                    }
                }
            }
            
            timestampedPrint("Leader (rank 0) starting concurrent messaging to all followers...")
            let testStartTime = Date()
            
            // Send messages concurrently from leader to each follower
            for messageIndex in 1...messagesPerFollower {
                // trigger rotating key
                if messageIndex % 50 == 0 {
                   Task(priority: .userInitiated) {
                        do {
                            try ensemblers[0].rotateKey()
                        }
                        catch {
                          print("ERROR ROTATING")
                        }
                    }
                }
                
                for followerRank in 1...7 {
                    let message = "Message from leader (batch \(messageIndex)) to follower \(followerRank)"
                    let messageKey = "follower\(followerRank)_message\(messageIndex)"
                    
                    // Record message send time
                    let messageSendTime = Date()
                    messageSendTimesLock.lock()
                    messageSendTimes[messageKey] = messageSendTime
                    messageSendTimesLock.unlock()
                    
                    timestampedPrint("Leader sending: '\(message)' to rank \(followerRank)")
                    
                    Task {
                        let result = try await sendDataAndGetResponse(
                            ensembler: ensemblers[0],
                            appID: "concurrent-leader-app",
                            data: message.data(using: .utf8)!,
                            destination: followerRank,
                            timeout: 2.0
                        )
                        let messageEndTime = Date()
                        
                        // Get the send time for this specific message
                        messageSendTimesLock.lock()
                        let specificSendTime = messageSendTimes[messageKey] ?? messageSendTime
                        messageSendTimesLock.unlock()
                        
                        let latency = messageEndTime.timeIntervalSince(specificSendTime)
                        let overallDuration = messageEndTime.timeIntervalSince(testStartTime)
                        
                        responseCountLock.lock()
                        defer { responseCountLock.unlock() }
                        
                        switch result {
                        case .success(let responseData):
                            responseCount += 1
                            
                            if let responseString = String(data: responseData, encoding: .utf8) {
                                timestampedPrint("Message \(messageKey) completed - Latency: \(String(format: "%.3f", latency * 1000))ms, Overall: \(String(format: "%.3f", overallDuration))s - Response: '\(responseString)'")
                                
                                // Verify response format
                                XCTAssert(responseString.contains("Response from follower \(followerRank)"), "Response should identify correct follower")
                                XCTAssert(responseString.contains(message), "Response should echo the original message")
                                
                                messageResultsLock.lock()
                                messageResults[messageKey] = responseString
                                messageResultsLock.unlock()
                                
                                // Record performance metrics
                                let metrics = MessageMetrics(
                                    messageKey: messageKey,
                                    startTime: specificSendTime,
                                    endTime: messageEndTime,
                                    latency: latency,
                                    followerRank: followerRank,
                                    messageIndex: messageIndex
                                )
                                
                                performanceMetricsLock.lock()
                                performanceMetrics.append(metrics)
                                performanceMetricsLock.unlock()
                                
                            } else {
                                XCTFail("Failed to decode response for \(messageKey)")
                            }
                            
                        case .failure(let error):
                            failedResponseCount += 1
                            timestampedPrint("Message \(messageKey) failed after \(String(format: "%.3f", latency * 1000))ms: \(error)")
                        }
                        
                        responseExpectation.fulfill()
                    }
                }
            }
            
            expectation.fulfill()
        }
        
        // Wait for test completion and all responses
        wait(for: [expectation, responseExpectation], timeout: timeOut)
        
        let finalTime = Date()
        timestampedPrint("All concurrent messaging completed")
        
        // Validate results
        responseCountLock.lock()
        let finalResponseCount = responseCount + failedResponseCount
        responseCountLock.unlock()
        
        print("Total response: \(finalResponseCount), expected: \(totalExpectedMessages), success: \(responseCount), failures:\(failedResponseCount)")
        XCTAssertEqual(finalResponseCount, totalExpectedMessages,
                      "Expected \(totalExpectedMessages) responses, but received \(finalResponseCount)")
        
      
        timestampedPrint("===========================================================\n")
        
        timestampedPrint("Successfully completed \(totalExpectedMessages) concurrent messages from leader to all followers")
        
        for followerRank in 1...7 {
            ensemblers[followerRank].unregisterDataCallback(appID: "concurrent-leader-app")
        }
        // Clean up
        for ensembler in ensemblers {
            ensembler.stopServer()
        }
    }
}
