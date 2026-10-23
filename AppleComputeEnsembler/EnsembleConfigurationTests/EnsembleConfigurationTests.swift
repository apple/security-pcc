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
//  EnsembleConfigurationTests.swift
//  EnsembleConfigurationTests
//
//  Created by Dhanasekar Thangavel on 11/18/24.
//

import CryptoKit
import AppleComputeEnsembler
@testable import EnsembleConfiguration
import notify
import os
import Synchronization
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

extension Task<Never, Never> {
    static func sleepSeconds(_ seconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }
    
    static func sleepMilliseconds(_ milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

final class EnsembleConfigurationTestHelpers {
    // get the ensemble configuration which does not gauranteee rank0-3 ( and so on) contains same
    // chassisid
    static func getEnsembleConfigInvalid(nodeCount: Int) -> EnsembleConfiguration {
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
    
    // get the ensemble configuration which does gauranteee rank0-3 ( and so on) contains same
    // chassisid
    static func getEnsembleConfig(nodeCount: Int) -> EnsembleConfiguration {
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
}

// MARK: - Swift Testing Test Suite

@Suite("Ensemble Configuration Validation Tests", .serialized)
struct EnsembleConfigurationSwiftTests {
	
	@Test("Invalid rank-chassis ID configuration", arguments: [2, 4, 8, 16])
	func invalidRankChassisIDConfiguration(nodeCount: Int) throws {
		let ensembleConfig = EnsembleConfigurationTestHelpers.getEnsembleConfigInvalid(nodeCount: nodeCount)
		
		#expect(throws: InitializationError.invalidRankChassisdIDConfiguration) {
			let ensembler = try EnsemblerTLSCIO(
				ensembleConfig: ensembleConfig,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: ensembleConfig.nodes.keys.first,
				skipJobQuiescence: true
			)
			ensembler.stopServer()
		}
	}
	
	@Test("Unordered restarts")
	func unorderedRestarts() async throws {
		func makeEnsembler(config: EnsembleConfiguration, udid: String) throws -> EnsemblerTLSCIO {
			let ensembler = try EnsemblerTLSCIO(
				ensembleConfig: config,
				autoRestart: false,
				skipDarwinInitCheck: true,
				useStubAttestation: true,
				currentUDID: udid,
				skipJobQuiescence: true,
				skipWaitingForDenali: true
			)
			
			return ensembler
		}
		
		let nodeCount: Int = 4
		var ensemblers: [EnsemblerTLSCIO] = []
		
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
		let config = EnsembleConfiguration(
			backendType: BackendType.StubBackend,
			hypercube: false,
			nodes: nodes
		)
		
		let udids = Array(config.nodes.keys).sorted()
		
		for i in 0 ..< config.nodes.count {
			timestampedPrint("creating ensemblers[\(i)]")
			
			let ensembler = try makeEnsembler(config: config, udid: udids[i])
			ensemblers.append(ensembler)
			try ensembler.activate()
		}
		
        // Wait for all nodes to reach ready state initially
        timestampedPrint("wait for all nodes to either get into ready state or failed state")
		for i in 0 ..< config.nodes.count {
			while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
				try await Task.sleepMilliseconds(100)
			}
		}
		
		timestampedPrint("check if all nodes are in ready state")
		for i in 0 ..< config.nodes.count {
			#expect(ensemblers[i].getStatus() == .ready)
		}

        // Simulate follower1 restarting
		ensemblers[1].stopServer()
        ensemblers.remove(at: 1)
        ensemblers.insert(try makeEnsembler(config: config, udid: udids[1]), at: 1)
		try ensemblers[1].activate()
		
		try await Task.sleepSeconds(5)
		
		// Simulate leader restarting
		ensemblers[0].stopServer()
        ensemblers.remove(at: 0)
		try await Task.sleepSeconds(5)
        ensemblers.insert(try makeEnsembler(config: config, udid: udids[0]), at: 0)

		try ensemblers[0].activate()
		
		try await Task.sleepSeconds(5)
		
		// Simulate remaining followers restarting
		for i in 2 ..< nodeCount {
			ensemblers[i].stopServer()
		}
        
        
        for i in 2 ..< nodeCount {
            ensemblers.removeLast()
        }
        
        // Simulate remaining followers restarting
        for i in 2 ..< nodeCount {
            ensemblers.insert(try makeEnsembler(config: config, udid: udids[i]), at: i)
            try ensemblers[i].activate()
        }
		
		// Wait for all nodes to reach ready state after restarts
		timestampedPrint("wait for all nodes to either get into ready state or failed state")
		for i in 0 ..< config.nodes.count {
			while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
				try await Task.sleepMilliseconds(100)
			}
		}
		
		timestampedPrint("check if all nodes are in ready state")
		for i in 0 ..< config.nodes.count {
			#expect(ensemblers[i].getStatus() == .ready)
		}

		// Clean up
		for i in 0 ..< nodeCount {
			ensemblers[i].stopServer()
		}
	}
}

// MARK: - XCTest Test Suite

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
                while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
                }
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
            
            try await Task.sleepSeconds(1)
            
            let message1StartTime = Date()
            ensemblers[1].sendDataAndGetResponse(appID: "app1", data: testmessage1.data(using: .utf8)!, destination: 0, completion: { result in
                let message1EndTime = Date()
                let message1Duration = message1EndTime.timeIntervalSince(message1StartTime)
                timestampedPrint("Message1 response time: \(message1Duration) seconds")
                switch result {
                case .success(let responseData):
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        XCTAssertEqual(responseString, "response for \(testmessage1)", "app1 message1 response should match expected")
                    } else {
                        XCTFail("Failed to decode response for app1 message1")
                    }
                case .failure(let error):
                    XCTFail("There was a registered handler on the server, we should NOT have got failure: \(error)")
                }
            })
            
          let message2StartTime = Date()
            ensemblers[1].sendDataAndGetResponse(appID: "app2",data: testmessage2.data(using: .utf8)!, destination: 0, completion: { result in
                let message2EndTime = Date()
                let message2Duration = message2EndTime.timeIntervalSince(message2StartTime)
                timestampedPrint("Message2 response time: \(message2Duration) seconds")
                switch result {
                case .success(let responseData):
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        XCTAssertEqual(responseString, "response for \(testmessage2)", "app2 message2 response should match expected")
                    } else {
                        XCTFail("Failed to decode response for app2 message2")
                    }
                case .failure(let error):
                    XCTFail("There was a registered handler on the server, we should NOT have got failure: \(error)")
                }
            })
            
            let message3StartTime = Date()
            ensemblers[1].sendDataAndGetResponse(appID: "app2",data: testmessage2.data(using: .utf8)!, destination: 0, completion: { result in
                let message3EndTime = Date()
                let message3Duration = message3EndTime.timeIntervalSince(message3StartTime)
                timestampedPrint("Message3 response time: \(message3Duration) seconds")
                switch result {
                case .success(let responseData):
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        XCTAssertEqual(responseString, "response for \(testmessage2)", "app2 message3 response should match expected")
                    } else {
                        XCTFail("Failed to decode response for app2 message3")
                    }
                case .failure(let error):
                    XCTFail("There was a registered handler on the server, we should NOT have got failure: \(error)")
                }
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
            
            // Wait for messages to complete
            try await Task.sleepSeconds(10)
            expectation.fulfill()
        }
    
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

                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
                }
            }
            
            timestampedPrint("check if all nodes are in ready state")
            for i in 0 ..< ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready)
            }
            
            let targetSize = 32*1024 // 32KB
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

            try await Task.sleepSeconds(1)

            let message1StartTime = Date()

            ensemblers[1].sendDataAndGetResponse(appID: "app1",data: largeString.data(using: .utf8)!, destination: 0, completion: { result in
                let message1EndTime = Date()
                let message1Duration = message1EndTime.timeIntervalSince(message1StartTime)
                timestampedPrint("Message1 response time: \(message1Duration) seconds")
                switch result {
                case .success(let responseData):
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        XCTAssertEqual(responseString, "Ack.", "Large data response should match expected")
                    } else {
                        XCTFail("Failed to decode response for large data message")
                    }
                case .failure(let error):
                    XCTFail("There was a registered handler on the server, we should NOT have got failure: \(error)")
                }

            })
            
            // Wait for message to complete
            try await Task.sleepSeconds(10)
            expectation.fulfill()
        }
    
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
        let responseCount = Atomic<Int>(0)
        let messageTimes = OSAllocatedUnfairLock<[Int: Date]>(initialState: [:])
        
        Task {
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("wait for all nodes to either get into ready state or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
                }
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
            
            try await Task.sleepSeconds(1)
            
            // Send multiple concurrent control messages
            for messageIndex in 1...messageCount {
                let message = "Concurrent test message \(messageIndex)"
                let messageStartTime = Date()
                
                // Store the start time for this message
                messageTimes.withLock { dict in
                    dict[messageIndex] = messageStartTime
                }
                
                ensemblers[1].sendDataAndGetResponse(
                    appID: "app1",
                    data: message.data(using: .utf8)!,
                    destination: 0,
                    completion: { result in
                        let messageEndTime = Date()
                        
                        let startTime = messageTimes.withLock { dict in
                            dict[messageIndex] ?? messageStartTime
                        }
                        
                        let messageDuration = messageEndTime.timeIntervalSince(startTime)
                        
                        switch result {
                        case .success(let responseData):
                            responseCount.wrappingAdd(1, ordering: .relaxed)
                            if let responseString = String(data: responseData, encoding: .utf8) {
                                timestampedPrint("Concurrent message \(messageIndex) response time: \(messageDuration) seconds - Response: \(responseString)")
                                XCTAssertEqual(responseString, "response for \(message)", "Concurrent message \(messageIndex) response should match expected")
                            } else {
                                XCTFail("Failed to decode response for concurrent message \(messageIndex)")
                            }
                            responseExpectation.fulfill()
                            
                        case .failure(let error):
                            timestampedPrint("Concurrent message \(messageIndex) failed after \(messageDuration) seconds: \(error)")
                            let errorDesc = String(describing: error)
                            let hint = errorDesc.lowercased().contains("timeout")
                                ? " — verify that 'registerDataCallback' is set up on the receiver node for appID 'app1'"
                                : ""
                            XCTFail("Message \(messageIndex) failed: \(error)\(hint)")
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
        let finalResponseCount = responseCount.load(ordering: .relaxed)
        XCTAssertEqual(finalResponseCount, messageCount, "Expected \(messageCount) responses, but received \(finalResponseCount)")
        
        timestampedPrint("Successfully sent \(messageCount) concurrent control messages and received \(finalResponseCount) responses")
        
        ensemblers[0].unregisterDataCallback(appID: "app1")
        
        // Clean up
        for ensembler in ensemblers {
            ensembler.stopServer()
        }
    }

	// Helper functions
	// get the ensemble configuration which does gauranteee rank0-3 ( and so on) contains same
	// chassisid
	func getEnsembleConfig(nodeCount: Int) -> EnsembleConfiguration {
        return EnsembleConfigurationTestHelpers.getEnsembleConfig(nodeCount: nodeCount)
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
		var ensemblers: [EnsemblerTLSCIO] = []

		Task {
			ensemblers = try self.populateEnsemblers(config: config, startIndex: startIndex)
            
			timestampedPrint("wait for all nodes to either get into ready state or failed state")
			for i in 0 ..< config.nodes.count {
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {
					try await Task.sleepMilliseconds(100)
				}
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
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {
					try await Task.sleepMilliseconds(100)
				}
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
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {
					try await Task.sleepMilliseconds(100)
				}
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
				while ensemblers[i].getStatus() != .ready, ensemblers[i].getStatus() != .failed {
					try await Task.sleepMilliseconds(100)
				}
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

	func populateEnsemblers(config: EnsembleConfiguration, startIndex: Int) throws -> [EnsemblerTLSCIO] {
		var ensemblers: [EnsemblerTLSCIO] = []
		let udids = Array(config.nodes.keys).sorted()

		timestampedPrint("Creating ensemblers in order from \(startIndex) to \(config.nodes.count)")
		for i in startIndex ..< config.nodes.count {
			timestampedPrint("createing ensemblers[\(i)]")

			let ensembler = try EnsemblerTLSCIO(
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
			print("createing ensemblers[\(i)]")
			let ensembler = try EnsemblerTLSCIO(
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
                    try await Task.sleepMilliseconds(100)
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
            try await Task.sleepSeconds(1)
            
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
                    try await Task.sleepMilliseconds(100)
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
            try await Task.sleepSeconds(1)
            
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
        let callbackInvokedCount = Atomic<Int>(0)
        
        Task {
            // Create and activate ensemblers
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("Wait for all nodes to reach ready or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
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
                let currentCount = callbackInvokedCount.wrappingAdd(1, ordering: .relaxed)
                
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
            try await Task.sleepSeconds(1)
            
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
            let countAfterFirstMessage = callbackInvokedCount.load(ordering: .relaxed)
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
            try await Task.sleepSeconds(1)
            
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
            let finalCallbackCount = callbackInvokedCount.load(ordering: .relaxed)
            
            timestampedPrint("Final callback invocation count: \(finalCallbackCount)")
            XCTAssertEqual(finalCallbackCount, 1, "Callback should still have been invoked only once (before unregister)")
            
            // Phase 5: Test re-registration works
            timestampedPrint("Phase 5: Re-registering callback to verify it works again")
            ensemblers[0].registerDataCallback(appID: testAppID) { sender, data in
                let currentCount = callbackInvokedCount.wrappingAdd(1, ordering: .relaxed)
                
                timestampedPrint("Re-registered callback invoked (count: \(currentCount)) - received data from rank \(sender)")
                
                let response = "Response from re-registered callback"
                return response.data(using: .utf8)!
            }
            
            try await Task.sleepSeconds(1)
            
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
            let verifyFinalCount = callbackInvokedCount.load(ordering: .relaxed)
            
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
        let responseCount = Atomic<Int>(0)
        let messageResults = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        
        // Performance metrics tracking
        struct MessageMetrics {
            let messageKey: String
            let startTime: Date
            let endTime: Date
            let latency: TimeInterval
            let followerRank: Int
            let messageIndex: Int
        }
        
        let performanceMetrics = OSAllocatedUnfairLock<[MessageMetrics]>(initialState: [])
        let messageSendTimes = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
        
        Task {
            // Create and activate all 8 ensemblers
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("Wait for all \(ensembleConfig.nodes.count) nodes to reach ready or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
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
            try await Task.sleepSeconds(2)
            
            timestampedPrint("Leader (rank 0) starting concurrent messaging to all followers...")
            let testStartTime = Date()
            
            // Send messages concurrently from leader to each follower
            for messageIndex in 1...messagesPerFollower {
                for followerRank in 1...7 {
                    let message = "Message from leader (batch \(messageIndex)) to follower \(followerRank)"
                    let messageKey = "follower\(followerRank)_message\(messageIndex)"
                    
                    // Record message send time
                    let messageSendTime = Date()
                    messageSendTimes.withLock { $0[messageKey] = messageSendTime }
                    
                    timestampedPrint("Leader sending: '\(message)' to rank \(followerRank)")
                    
                    Task {
                        let result = try await sendDataAndGetResponse(
                            ensembler: ensemblers[0],
                            appID: "concurrent-leader-app",
                            data: message.data(using: .utf8)!,
                            destination: followerRank,
                            timeout: 4.0
                        )
                        let messageEndTime = Date()
                        
                        // Get the send time for this specific message
                        let specificSendTime = messageSendTimes.withLock { $0[messageKey] ?? messageSendTime }
                        
                        let latency = messageEndTime.timeIntervalSince(specificSendTime)
                        let overallDuration = messageEndTime.timeIntervalSince(testStartTime)
                        
                        switch result {
                        case .success(let responseData):
                            responseCount.wrappingAdd(1, ordering: .relaxed)
                            
                            if let responseString = String(data: responseData, encoding: .utf8) {
                                timestampedPrint("Message \(messageKey) completed - Latency: \(String(format: "%.3f", latency * 1000))ms, Overall: \(String(format: "%.3f", overallDuration))s - Response: '\(responseString)'")
                                
                                // Verify response format
                                XCTAssert(responseString.contains("Response from follower \(followerRank)"), "Response should identify correct follower")
                                XCTAssert(responseString.contains(message), "Response should echo the original message")
                                
                                messageResults.withLock { dict in
                                    dict[messageKey] = responseString
                                }
                                
                                // Record performance metrics
                                let metrics = MessageMetrics(
                                    messageKey: messageKey,
                                    startTime: specificSendTime,
                                    endTime: messageEndTime,
                                    latency: latency,
                                    followerRank: followerRank,
                                    messageIndex: messageIndex
                                )
                                
                                performanceMetrics.withLock { $0.append(metrics) }
                                
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
        let finalResponseCount = responseCount.load(ordering: .relaxed)
        
        XCTAssertEqual(finalResponseCount, totalExpectedMessages,
                      "Expected \(totalExpectedMessages) responses, but received \(finalResponseCount)")
        
        // Verify each follower received and responded to all its messages
        let finalResults = messageResults.withLock { $0 }
        
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
        let finalMetrics = performanceMetrics.withLock { $0 }
        
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
        
        struct ResponseCounts {
            public var successful: Int = 0
            public var failed: Int = 0
        }
        
        var ensemblers: [EnsemblerTLS] = []
        let responseCount = OSAllocatedUnfairLock<ResponseCounts>(initialState: ResponseCounts())
        let messageResults = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        
        // Performance metrics tracking
        struct MessageMetrics {
            let messageKey: String
            let startTime: Date
            let endTime: Date
            let latency: TimeInterval
            let followerRank: Int
            let messageIndex: Int
        }
        
        let performanceMetrics = OSAllocatedUnfairLock<[MessageMetrics]>(initialState: [])
        let messageSendTimes = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
        
        Task {
            // Create and activate all 8 ensemblers
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)
            
            timestampedPrint("Wait for all \(ensembleConfig.nodes.count) nodes to reach ready or failed state")
            for i in 0 ..< ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
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
                    messageSendTimes.withLock { $0[messageKey] = messageSendTime }
                    
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
                        let specificSendTime = messageSendTimes.withLock { $0[messageKey] ?? messageSendTime }
                        
                        let latency = messageEndTime.timeIntervalSince(specificSendTime)
                        let overallDuration = messageEndTime.timeIntervalSince(testStartTime)
                        
                        responseCount.withLock { rc in
                            switch result {
                            case .success(let responseData):
                                rc.successful += 1
                                
                                if let responseString = String(data: responseData, encoding: .utf8) {
                                    timestampedPrint("Message \(messageKey) completed - Latency: \(String(format: "%.3f", latency * 1000))ms, Overall: \(String(format: "%.3f", overallDuration))s - Response: '\(responseString)'")
                                    
                                    // Verify response format
                                    XCTAssert(responseString.contains("Response from follower \(followerRank)"), "Response should identify correct follower")
                                    XCTAssert(responseString.contains(message), "Response should echo the original message")
                                    
                                    messageResults.withLock { $0[messageKey] = responseString }
                                    
                                    // Record performance metrics
                                    let metrics = MessageMetrics(
                                        messageKey: messageKey,
                                        startTime: specificSendTime,
                                        endTime: messageEndTime,
                                        latency: latency,
                                        followerRank: followerRank,
                                        messageIndex: messageIndex
                                    )
                                    
                                    performanceMetrics.withLock { $0.append(metrics) }
                                } else {
                                    XCTFail("Failed to decode response for \(messageKey)")
                                }
                                
                            case .failure(let error):
                                rc.failed += 1
                                let errorDesc = String(describing: error)
                                timestampedPrint("Message \(messageKey) failed after \(String(format: "%.3f", latency * 1000))ms: \(error)")
                                let hint = errorDesc.lowercased().contains("timeout")
                                    ? " — verify that 'registerDataCallback' is set up on follower \(followerRank) for appID 'concurrent-leader-app'"
                                    : ""
                                XCTFail("Message \(messageKey) failed: \(error)\(hint)")
                            }
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
        let finalResponses = responseCount.withLock { $0 }
        let successCount = finalResponses.successful
        let failureCount = finalResponses.failed
        let finalResponseCount = successCount + failureCount
        
        print("Total response: \(finalResponseCount), expected: \(totalExpectedMessages), success: \(successCount), failures:\(failureCount)")
        XCTAssertEqual(finalResponseCount, totalExpectedMessages,
                      "Expected \(totalExpectedMessages) responses, but received \(finalResponseCount)")
        XCTAssertEqual(failureCount, 0,
                      "\(failureCount) message(s) failed — if errors are timeouts, verify that 'registerDataCallback' is set up on all followers")
        
      
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

    // MARK: - Test 1: Response correlation
    // Leader sends N concurrent messages to a single follower. Each message embeds a
    // unique ID; the follower echoes the payload back verbatim. The leader asserts that
    // every response matches exactly the payload it sent — not a response from another
    // in-flight request.
    func testConcurrentResponseCorrelation() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
        let messageCount = 20
        let timeOut = Double(2) * 30.0

        let expectation = self.expectation(description: "Setup completes")
        let responseExpectation = self.expectation(description: "All \(messageCount) responses received")
        responseExpectation.expectedFulfillmentCount = messageCount

        var ensemblers: [EnsemblerTLS] = []
        // Records (sentPayload, receivedResponse) keyed by message index
        let resultMap = OSAllocatedUnfairLock<[Int: (sent: String, received: String)]>(initialState: [:])
        let failureCount = Atomic<Int>(0)

        Task {
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)

            for i in 0..<ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
                }
            }
            for i in 0..<ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) not ready")
            }

            // Follower echoes payload back verbatim so the leader can verify correlation.
            ensemblers[0].registerDataCallback(appID: "correlation-app") { _, data in
                return data
            }

            try await Task.sleepSeconds(1)

            for index in 1...messageCount {
                // Unique UUID in each payload ensures we can detect cross-wiring.
                let uniqueID = UUID().uuidString
                let payload = "MSG-\(index)-\(uniqueID)"

                Task {
                    let result = try await self.sendDataAndGetResponse(
                        ensembler: ensemblers[1],
                        appID: "correlation-app",
                        data: payload.data(using: .utf8)!,
                        destination: 0,
                        timeout: 5.0
                    )
                    switch result {
                    case .success(let responseData):
                        let response = String(data: responseData, encoding: .utf8) ?? ""
                        XCTAssertEqual(response, payload,
                            "Message \(index): response '\(response)' does not match sent payload '\(payload)'")
                        resultMap.withLock { $0[index] = (sent: payload, received: response) }
                    case .failure(let error):
                        failureCount.wrappingAdd(1, ordering: .relaxed)
                        XCTFail("Message \(index) unexpectedly failed: \(error)")
                    }
                    responseExpectation.fulfill()
                }
            }

            expectation.fulfill()
        }

        wait(for: [expectation, responseExpectation], timeout: timeOut)

        let results = resultMap.withLock { $0 }
        XCTAssertEqual(results.count, messageCount,
            "Expected \(messageCount) correlated responses, got \(results.count)")
        for (index, pair) in results {
            XCTAssertEqual(pair.sent, pair.received,
                "Message \(index): response must match its own payload")
        }
        XCTAssertEqual(failureCount.load(ordering: .relaxed), 0, "No messages should fail")

        ensemblers[0].unregisterDataCallback(appID: "correlation-app")
        for ensembler in ensemblers { ensembler.stopServer() }
        timestampedPrint("testConcurrentResponseCorrelation completed")
    }

    // MARK: - Test 2: Mixed registered / unregistered appIDs
    // Leader sends concurrent messages to two appIDs simultaneously. One appID has a
    // registered handler on the follower; the other does not. Verifies that messages to
    // the registered appID succeed and messages to the unregistered appID fail immediately
    // with DataMessageError.noRegisteredHandler — not with a generic timeout.
    func testConcurrentMixedAppIDsRegisteredAndUnregistered() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
        let messagesPerApp = 10
        let totalMessages = messagesPerApp * 2
        let timeOut = Double(2) * 30.0

        let expectation = self.expectation(description: "Setup completes")
        let responseExpectation = self.expectation(description: "All \(totalMessages) responses received")
        responseExpectation.expectedFulfillmentCount = totalMessages

        var ensemblers: [EnsemblerTLS] = []
        let registeredSuccessCount = Atomic<Int>(0)
        let noHandlerErrorCount    = Atomic<Int>(0)
        let unexpectedErrors       = OSAllocatedUnfairLock<[String]>(initialState: [])

        Task {
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)

            for i in 0..<ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
                }
            }
            for i in 0..<ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) not ready")
            }

            // Only "app-registered" has a handler; "app-unregistered" deliberately has none.
            ensemblers[0].registerDataCallback(appID: "app-registered") { _, data in
                let msg = String(data: data, encoding: .utf8) ?? ""
                return "ack:\(msg)".data(using: .utf8)!
            }

            try await Task.sleepSeconds(1)

            // Messages to the registered app — all must succeed.
            for i in 1...messagesPerApp {
                Task {
                    let result = try await self.sendDataAndGetResponse(
                        ensembler: ensemblers[1],
                        appID: "app-registered",
                        data: "msg-\(i)".data(using: .utf8)!,
                        destination: 0,
                        timeout: 5.0
                    )
                    switch result {
                    case .success(let responseData):
                        if let responseString = String(data: responseData, encoding: .utf8) {
                            XCTAssertEqual(responseString, "ack:msg-\(i)", "app-registered message \(i) response should match expected")
                        } else {
                            XCTFail("Failed to decode response for app-registered message \(i)")
                        }
                        registeredSuccessCount.wrappingAdd(1, ordering: .relaxed)
                    case .failure(let error):
                        unexpectedErrors.withLock { $0.append("app-registered[\(i)]: \(error)") }
                        XCTFail("app-registered message \(i) should succeed, got: \(error)")
                    }
                    responseExpectation.fulfill()
                }
            }

            // Messages to the unregistered app — all must fail with noRegisteredHandler.
            for i in 1...messagesPerApp {
                Task {
                    let result = try await self.sendDataAndGetResponse(
                        ensembler: ensemblers[1],
                        appID: "app-unregistered",
                        data: "msg-\(i)".data(using: .utf8)!,
                        destination: 0,
                        timeout: 5.0
                    )
                    switch result {
                    case .success(let data):
                        let str = String(data: data, encoding: .utf8) ?? ""
                        XCTFail("app-unregistered message \(i) should fail, but succeeded: '\(str)'")
                    case .failure(let error):
                        if case DataMessageError.noRegisteredHandler = error {
                            noHandlerErrorCount.wrappingAdd(1, ordering: .relaxed)
                            timestampedPrint("app-unregistered[\(i)] correctly got noRegisteredHandler")
                        } else {
                            unexpectedErrors.withLock { $0.append("app-unregistered[\(i)]: unexpected \(error)") }
                            XCTFail("app-unregistered message \(i) expected noRegisteredHandler, got: \(error)")
                        }
                    }
                    responseExpectation.fulfill()
                }
            }

            expectation.fulfill()
        }

        wait(for: [expectation, responseExpectation], timeout: timeOut)

        XCTAssertEqual(registeredSuccessCount.load(ordering: .relaxed), messagesPerApp,
            "Expected \(messagesPerApp) successes for app-registered")
        XCTAssertEqual(noHandlerErrorCount.load(ordering: .relaxed), messagesPerApp,
            "Expected \(messagesPerApp) noRegisteredHandler errors for app-unregistered")

        let errors = unexpectedErrors.withLock { $0 }
        XCTAssertTrue(errors.isEmpty, "Unexpected errors: \(errors)")

        ensemblers[0].unregisterDataCallback(appID: "app-registered")
        for ensembler in ensemblers { ensembler.stopServer() }
        timestampedPrint("testConcurrentMixedAppIDsRegisteredAndUnregistered completed")
    }

    // MARK: - Test 3: Slow handler does not block fast handler
    // Leader sends messages concurrently to two appIDs: one whose handler sleeps 2 s
    // (beyond the 1 s callbackTimeout) and one whose handler responds immediately.
    // Asserts that slow-app messages get DataMessageError.timeoutOnPeerHandler while
    // fast-app messages succeed and are NOT serialised behind the slow ones.
    func testConcurrentSlowHandlerDoesNotBlockFastHandler() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
        let messagesPerApp = 5
        let totalMessages  = messagesPerApp * 2
        let timeOut        = Double(2) * 30.0

        // message timeout = 1.25 s → callbackTimeout on follower = 1.0 s
        // handler sleep   = 2.0 s  → callbackTimeout fires first → leader gets timeoutOnPeerHandler
        let msgTimeout: TimeInterval = 1.25

        let expectation = self.expectation(description: "Setup completes")
        let responseExpectation = self.expectation(description: "All \(totalMessages) responses received")
        responseExpectation.expectedFulfillmentCount = totalMessages

        var ensemblers: [EnsemblerTLS] = []
        let timeoutOnPeerCount = Atomic<Int>(0)
        let fastSuccessCount   = Atomic<Int>(0)
        let fastLatencies      = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])

        Task {
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)

            for i in 0..<ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
                }
            }
            for i in 0..<ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) not ready")
            }

            // Slow handler: sleeps 2 s — exceeds the 1.0 s callbackTimeout.
            // Use Task.sleep (cooperative suspension) instead of Thread.sleep (blocking) to
            // avoid starving the Swift cooperative thread pool under concurrent load, which
            // caused memory corruption / ObjC tagged-pointer crashes in stress tests.
            ensemblers[0].registerDataCallback(appID: "app-slow") { _, data in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return "slow-response".data(using: .utf8)!
            }

            // Fast handler: responds immediately.
            ensemblers[0].registerDataCallback(appID: "app-fast") { _, data in
                return "fast-response".data(using: .utf8)!
            }

            try await Task.sleepSeconds(1)

            let testStart = Date()

            // Fire slow and fast messages concurrently in the same loop so they truly
            // overlap and we can detect any serialisation.
            for i in 1...messagesPerApp {
                Task {
                    let result = try await self.sendDataAndGetResponse(
                        ensembler: ensemblers[1],
                        appID: "app-slow",
                        data: "slow-msg-\(i)".data(using: .utf8)!,
                        destination: 0,
                        timeout: msgTimeout
                    )
                    switch result {
                    case .failure(let error):
                        if case DataMessageError.timeoutOnPeerHandler = error {
                            timeoutOnPeerCount.wrappingAdd(1, ordering: .relaxed)
                            timestampedPrint("slow-msg-\(i) correctly got timeoutOnPeerHandler")
                        } else {
                            XCTFail("slow-msg-\(i) expected timeoutOnPeerHandler, got: \(error)")
                        }
                    case .success:
                        XCTFail("slow-msg-\(i) should have timed out on peer handler but succeeded")
                    }
                    responseExpectation.fulfill()
                }

                Task {
                    let sendTime = Date()
                    let result = try await self.sendDataAndGetResponse(
                        ensembler: ensemblers[1],
                        appID: "app-fast",
                        data: "fast-msg-\(i)".data(using: .utf8)!,
                        destination: 0,
                        timeout: 5.0
                    )
                    let latency = Date().timeIntervalSince(sendTime)
                    switch result {
                    case .success(let responseData):
                        if let responseString = String(data: responseData, encoding: .utf8) {
                            XCTAssertEqual(responseString, "fast-response", "fast-msg-\(i) response should match expected")
                        } else {
                            XCTFail("Failed to decode response for fast-msg-\(i)")
                        }
                        fastSuccessCount.wrappingAdd(1, ordering: .relaxed)
                        fastLatencies.withLock { $0.append(latency) }
                        timestampedPrint("fast-msg-\(i) succeeded in \(String(format: "%.3f", latency))s (test elapsed: \(String(format: "%.3f", Date().timeIntervalSince(testStart)))s)")
                    case .failure(let error):
                        XCTFail("fast-msg-\(i) should succeed but got: \(error)")
                    }
                    responseExpectation.fulfill()
                }
            }

            expectation.fulfill()
        }

        wait(for: [expectation, responseExpectation], timeout: timeOut)

        XCTAssertEqual(timeoutOnPeerCount.load(ordering: .relaxed), messagesPerApp,
            "All \(messagesPerApp) slow messages should get timeoutOnPeerHandler")
        XCTAssertEqual(fastSuccessCount.load(ordering: .relaxed), messagesPerApp,
            "All \(messagesPerApp) fast messages should succeed despite concurrent slow handlers")

        // Fast messages must not have been serialised behind the 2 s slow handlers.
        // Each fast message should complete well under 2 s.
        let latencies = fastLatencies.withLock { $0 }
        for (idx, lat) in latencies.enumerated() {
            XCTAssertLessThan(lat, 2.0,
                "fast-msg-\(idx + 1) took \(String(format: "%.3f", lat))s — suggests it was blocked by slow handler")
        }

        ensemblers[0].unregisterDataCallback(appID: "app-slow")
        ensemblers[0].unregisterDataCallback(appID: "app-fast")
        for ensembler in ensemblers { ensembler.stopServer() }
        timestampedPrint("testConcurrentSlowHandlerDoesNotBlockFastHandler completed")
    }

    // MARK: - Test 4: Some messages get no response; others are unaffected
    // Leader sends a batch of interleaved messages where half target an appID with no
    // registered handler (immediate noRegisteredHandler fast-fail) and half target an
    // appID with a working handler. Verifies that the fast-fail errors do not delay or
    // corrupt the successful responses in the same concurrent batch.
    func testConcurrentSomeMessagesFailWhileOthersSucceed() throws {
        let ensembleConfig  = self.getEnsembleConfig(nodeCount: 2)
        let batchSize       = 20   // 10 to "app-ok", 10 to "app-missing"
        let timeOut         = Double(2) * 30.0

        let expectation = self.expectation(description: "Setup completes")
        let responseExpectation = self.expectation(description: "All \(batchSize) responses received")
        responseExpectation.expectedFulfillmentCount = batchSize

        var ensemblers: [EnsemblerTLS] = []
        let okSuccessCount   = Atomic<Int>(0)
        let missingErrCount  = Atomic<Int>(0)
        // Track latency of "app-ok" messages to confirm they aren't delayed.
        let okLatencies      = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
        let unexpectedErrors = OSAllocatedUnfairLock<[String]>(initialState: [])

        Task {
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)

            for i in 0..<ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
                }
            }
            for i in 0..<ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) not ready")
            }

            // Only "app-ok" is registered; "app-missing" has no handler — fast-fail.
            ensemblers[0].registerDataCallback(appID: "app-ok") { _, data in
                let msg = String(data: data, encoding: .utf8) ?? ""
                return "ok:\(msg)".data(using: .utf8)!
            }

            try await Task.sleepSeconds(1)

            // Send all batchSize messages at once, alternating appID.
            for i in 1...(batchSize / 2) {
                // Message to working handler
                Task {
                    let sendTime = Date()
                    let result = try await self.sendDataAndGetResponse(
                        ensembler: ensemblers[1],
                        appID: "app-ok",
                        data: "ok-msg-\(i)".data(using: .utf8)!,
                        destination: 0,
                        timeout: 5.0
                    )
                    let latency = Date().timeIntervalSince(sendTime)
                    switch result {
                    case .success(let responseData):
                        if let responseString = String(data: responseData, encoding: .utf8) {
                            XCTAssertEqual(responseString, "ok:ok-msg-\(i)", "ok-msg-\(i) response should match expected")
                        } else {
                            XCTFail("Failed to decode response for ok-msg-\(i)")
                        }
                        okSuccessCount.wrappingAdd(1, ordering: .relaxed)
                        okLatencies.withLock { $0.append(latency) }
                        timestampedPrint("ok-msg-\(i) succeeded in \(String(format: "%.3f", latency))s")
                    case .failure(let error):
                        unexpectedErrors.withLock { $0.append("ok-msg-\(i): \(error)") }
                        XCTFail("ok-msg-\(i) should succeed, got: \(error)")
                    }
                    responseExpectation.fulfill()
                }

                // Message to unregistered handler — expect immediate noRegisteredHandler.
                Task {
                    let sendTime = Date()
                    let result = try await self.sendDataAndGetResponse(
                        ensembler: ensemblers[1],
                        appID: "app-missing",
                        data: "missing-msg-\(i)".data(using: .utf8)!,
                        destination: 0,
                        timeout: 5.0
                    )
                    let latency = Date().timeIntervalSince(sendTime)
                    switch result {
                    case .success(let data):
                        let str = String(data: data, encoding: .utf8) ?? ""
                        XCTFail("missing-msg-\(i) should fail with noRegisteredHandler, got success: '\(str)'")
                    case .failure(let error):
                        if case DataMessageError.noRegisteredHandler = error {
                            missingErrCount.wrappingAdd(1, ordering: .relaxed)
                            timestampedPrint("missing-msg-\(i) correctly got noRegisteredHandler in \(String(format: "%.3f", latency))s")
                        } else {
                            unexpectedErrors.withLock { $0.append("missing-msg-\(i): unexpected \(error)") }
                            XCTFail("missing-msg-\(i) expected noRegisteredHandler, got: \(error)")
                        }
                    }
                    responseExpectation.fulfill()
                }
            }

            expectation.fulfill()
        }

        wait(for: [expectation, responseExpectation], timeout: timeOut)

        let half = batchSize / 2
        XCTAssertEqual(okSuccessCount.load(ordering: .relaxed), half,
            "Expected \(half) successes for app-ok")
        XCTAssertEqual(missingErrCount.load(ordering: .relaxed), half,
            "Expected \(half) noRegisteredHandler errors for app-missing")

        let errors = unexpectedErrors.withLock { $0 }
        XCTAssertTrue(errors.isEmpty, "Unexpected errors: \(errors)")

        // "app-ok" messages must not have been delayed by the concurrent fast-fail errors.
        let latencies = okLatencies.withLock { $0 }
        for (idx, lat) in latencies.enumerated() {
            XCTAssertLessThan(lat, 5.0,
                "ok-msg-\(idx + 1) took \(String(format: "%.3f", lat))s — may have been blocked")
        }

        ensemblers[0].unregisterDataCallback(appID: "app-ok")
        for ensembler in ensemblers { ensembler.stopServer() }
        timestampedPrint("testConcurrentSomeMessagesFailWhileOthersSucceed completed")
    }

    // MARK: - Test 5: Messaging during key rotation (recycle)
    // Leader sends 50 concurrent messages to a follower. After the first 20 have been
    // dispatched, rotateKey() is triggered from a separate task. Verifies that:
    //   - rotateKey() completes without error (recycle is not stuck)
    //   - The ensemble returns to .ready after rotation
    //   - All messages eventually get a response (success or graceful error during recycle)
    func testMessagingDuringRotateKey() throws {
        let ensembleConfig = self.getEnsembleConfig(nodeCount: 2)
        let totalMessages  = 50
        let timeOut        = Double(2) * 60.0

        let expectation = self.expectation(description: "Setup and sends complete")
        let responseExpectation = self.expectation(description: "All \(totalMessages) responses received")
        responseExpectation.expectedFulfillmentCount = totalMessages

        var ensemblers: [EnsemblerTLS] = []

        struct SendResult {
            var succeeded: Int = 0
            var failed:    Int = 0
        }
        let counts         = OSAllocatedUnfairLock<SendResult>(initialState: SendResult())
        let rotateKeyError = OSAllocatedUnfairLock<Error?>(initialState: nil)

        Task {
            ensemblers = try self.populateEnsemblers(config: ensembleConfig, startIndex: 0)

            for i in 0..<ensembleConfig.nodes.count {
                while ensemblers[i].getStatus() != .ready && ensemblers[i].getStatus() != .failed {
                    try await Task.sleepMilliseconds(100)
                }
            }
            for i in 0..<ensembleConfig.nodes.count {
                XCTAssert(ensemblers[i].getStatus() == .ready, "Node \(i) not ready before rotation test")
            }

            ensemblers[0].registerDataCallback(appID: "recycle-app") { _, data in
                let msg = String(data: data, encoding: .utf8) ?? ""
                return "ack:\(msg)".data(using: .utf8)!
            }

            try await Task.sleepSeconds(1)

            timestampedPrint("Dispatching \(totalMessages) concurrent messages")

            for msgIndex in 1...totalMessages {
                let message = "recycle-msg-\(msgIndex)"

                // After the 20th message is dispatched, trigger key rotation concurrently.
                if msgIndex == 20 {
                    Task(priority: .userInitiated) {
                        timestampedPrint("Triggering rotateKey() mid-flight")
                        do {
                            try ensemblers[0].rotateKey()
                            timestampedPrint("rotateKey() completed successfully")
                        } catch {
                            rotateKeyError.withLock { $0 = error }
                            timestampedPrint("rotateKey() failed: \(error)")
                        }
                    }
                }

                Task {
                    let result = try await self.sendDataAndGetResponse(
                        ensembler: ensemblers[0],
                        appID: "recycle-app",
                        data: message.data(using: .utf8)!,
                        destination: 1,
                        timeout: 10.0
                    )
                    counts.withLock { c in
                        switch result {
                        case .success(let responseData):
                            if let responseString = String(data: responseData, encoding: .utf8) {
                                XCTAssertEqual(responseString, "ack:\(message)", "Response should match expected ack for \(message)")
                            } else {
                                XCTFail("Failed to decode response for \(message)")
                            }
                            c.succeeded += 1
                        case .failure(let error):
                            // Messages in flight during key rotation may fail; that is
                            // acceptable. What must NOT happen is a hang or a crash.
                            c.failed += 1
                            timestampedPrint("msg-\(msgIndex) failed (may be expected during recycle): \(error)")
                        }
                    }
                    responseExpectation.fulfill()
                }
            }
            
            expectation.fulfill()
        }

        wait(for: [expectation, responseExpectation], timeout: timeOut)

        // rotateKey() must not throw.
        let keyRotationError = rotateKeyError.withLock { $0 }
        XCTAssertNil(keyRotationError, "rotateKey() should succeed, got: \(String(describing: keyRotationError))")

        // Ensemble must return to .ready after rotation completes.
        
        while ensemblers[0].getStatus() != .ready && ensemblers[0].getStatus() != .failed {
            Thread.sleep(forTimeInterval: 1)
        }
        
        let leaderStatus = ensemblers[0].getStatus()
        XCTAssertEqual(leaderStatus, .ready, "Leader should be .ready after key rotation, got: \(leaderStatus)")

        // All messages must have received some response (no hangs).
        let final = counts.withLock { $0 }
        let totalResponses = final.succeeded + final.failed
        XCTAssertEqual(totalResponses, totalMessages,
            "Expected \(totalMessages) total responses (success+failure), got \(totalResponses)")

        timestampedPrint("testMessagingDuringRotateKey: succeeded=\(final.succeeded) failed=\(final.failed)")

        ensemblers[0].unregisterDataCallback(appID: "recycle-app")
        for ensembler in ensemblers { ensembler.stopServer() }
        timestampedPrint("testMessagingDuringRotateKey completed")
    }
}

// MARK: - Length-Prefix MTU Enforcement (rdar://168633620)
//
// setupReceiveLength reads a 4-byte length prefix from the wire and then asks
// NWConnection to deliver that many bytes. Prior to rdar://168633620 the value
// was passed through verbatim — a peer could send a length prefix of, say, 4GB
// and force the server into an absurdly long receive. setupReceiveMessage(length:)
// had the same flaw. ServerConnection.isValidLengthPrefix gates both paths;
// the tests below assert its boundary behaviour and the values that motivated
// the fix.
final class ServerLengthPrefixMTUTests: XCTestCase {

	func testAcceptsLengthOfOne() {
		XCTAssertTrue(ServerConnection.isValidLengthPrefix(1),
			"a single-byte payload is within MTU and must be accepted")
	}

	func testAcceptsLengthAtMTU() {
		XCTAssertTrue(ServerConnection.isValidLengthPrefix(MTU),
			"a payload exactly equal to MTU must be accepted")
	}

	func testRejectsZeroLength() {
		XCTAssertFalse(ServerConnection.isValidLengthPrefix(0),
			"a zero-length frame is meaningless and must be ignored")
	}

	func testRejectsNegativeLength() {
		// A UInt32 wire value with the high bit set becomes negative once cast
		// to Int — exactly the kind of bogus value setupReceiveLength used to
		// pass through unchecked.
		XCTAssertFalse(ServerConnection.isValidLengthPrefix(-1),
			"a negative length is nonsense and must be ignored")
	}

	func testRejectsLengthJustAboveMTU() {
		XCTAssertFalse(ServerConnection.isValidLengthPrefix(MTU + 1),
			"a frame one byte over MTU must be ignored")
	}

	func testRejectsLengthFarAboveMTU() {
		// A peer sending UInt32.max as the length prefix is the canonical
		// abuse pattern called out by rdar://168633620.
		XCTAssertFalse(ServerConnection.isValidLengthPrefix(Int(UInt32.max)),
			"a 4GB length prefix must be ignored")
	}

	// Walks a representative spread of oversized prefixes to show that the
	// validator's rejection isn't dependent on a single magic value.
	func testRejectsAssortedOversizedPrefixes() {
		let oversized: [Int] = [
			MTU + 1,
			MTU * 2,
			MTU * 16,
			1 << 20,            // 1 MiB
			1 << 24,            // 16 MiB
			Int(UInt32.max),    // 4 GiB - 1
		]
		for length in oversized {
			XCTAssertFalse(ServerConnection.isValidLengthPrefix(length),
				"length \(length) exceeds MTU \(MTU) and must be ignored")
		}
	}
}
