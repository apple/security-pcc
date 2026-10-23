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
//  main.swift
//  ensembleconfig
//
//  Created by Sumit Kamath on 11/17/23.
//
#if canImport(AppleCIOMeshConfigSupport)
@_weakLinked import AppleCIOMeshConfigSupport
#endif

import Foundation
import IOKit
import RemoteServiceDiscovery

extension xpc_object_t {
	public func asString(objName: String) throws -> String? {
		let propObjType = xpc_get_type(self)
		guard propObjType == XPC_TYPE_STRING else {
			throw "Unexpected type \(objName) is not string \(String(cString: xpc_type_get_name(propObjType)))"
		}

		guard let str = xpc_string_get_string_ptr(self) else {
			return nil
		}

		return String(cString: str)
	}
}

func getNodeConfiguration(
	configuration: EnsembleConfiguration,
	node: Int) -> NodeConfiguration? {
	configuration.nodes.first(where: { $0.rank == node })
}

class IOKitManagedHandle {
	var handle: io_object_t
	init(handle: io_object_t = 0) {
		self.handle = handle
	}

	func clone() -> IOKitManagedHandle {
		IOObjectRetain(self.handle)
		return IOKitManagedHandle(handle: self.handle)
	}

	deinit {
		IOObjectRelease(handle)
	}
}

class Agent {
	var backend: Backend?
	var router: Router?
	var debugMode = false
	var hypercubeMode = true
	var autoActivate = false
	var printInfo = false
	var deactivateMesh = false
	var cioCableTestMode = false
	var singleChassisCIOCableTestMode = false

	func main() throws {
		let args = CommandLine.arguments
		let ensembleConfigArg: String?
		let nodeRankArg: String?
		var nodeRank = -1
		var checkBuffersUsed = false

		let timeoutSecondsArg: String?
		var timeoutSeconds = 30

		if args.contains(where: { $0 == "--version" }) {
			print("version: 1.1.0-Nov22")
			exit(0)
		}

		if args.contains(where: { $0 == "--debug" }) {
			self.debugMode = true
		}

		if args.contains(where: { $0 == "--hypercube" }) {
			self.hypercubeMode = true
		}

		if args.contains(where: { $0 == "--auto" }) {
			self.autoActivate = true
		}

		if args.contains(where: { $0 == "--cablecheck" }) {
			self.cioCableTestMode = true
		}

		if args.contains(where: { $0 == "--chassiscablecheck" }) {
			self.singleChassisCIOCableTestMode = true
		}

		if args.contains(where: { $0 == "--info" }) {
			self.printInfo = true
		}

		if args.contains(where: { $0 == "--buffercount" }) {
			checkBuffersUsed = true
		}

		if args.contains(where: { $0 == "--deactivate" }) {
			let meshService: AppleCIOMeshConfigServiceRef
			let meshServices = AppleCIOMeshConfigServiceRef.all()

			guard let meshServices = meshServices,
			      let meshService = meshServices.first
			else {
				throw "Unable to find mesh config service"
			}

			print("Deactivating the mesh!")
			meshService.deactivateCIO()
			return
		}

		if self.printInfo {
			let meshService: AppleCIOMeshConfigServiceRef
			let meshServices = AppleCIOMeshConfigServiceRef.all()

			guard let meshServices = meshServices,
			      let meshService = meshServices.first
			else {
				throw "Unable to find mesh config service"
			}

			let nodes = meshService.getConnectedNodes()

			guard let nodes = nodes else {
				throw "Unable to get connected nodes"
			}

			for n in nodes {
				guard let n = n as? [String: AnyObject] else {
					throw "Bad node object"
				}
				let obj = n["inputChannel"]
				guard let inputChannel = obj as? Int else {
					throw "InputChannel is not an Int"
				}
				if inputChannel == -1 {
					let obj = n["rank"]
					guard let myId = obj as? Int else {
						throw "Rank is not an Int"
					}
					print("My rank is \(myId) and there are \(nodes.count) nodes in the mesh.")
					return
				}
			}
			print("Could not determine our rank but there are \(nodes.count) nodes in the mesh.")
			return
		}

		// Default ways to get ensemble based on cable test args
		if self.cioCableTestMode {
			ensembleConfigArg = "ensemble=/System/Library/PrivateFrameworks/AppleCIOMeshConfigSupport.framework/Versions/A/Resources/ensemblesetup-hypercube.json"
			self.hypercubeMode = true

			// Get a timeout if its set
			timeoutSecondsArg = args.first(where: { $0.hasPrefix("timeout=") })
			if let timeoutSecondsArg = timeoutSecondsArg {
				timeoutSeconds = Int(String(timeoutSecondsArg.dropFirst("timeout=".count)))!
			}
		} else if self.singleChassisCIOCableTestMode {
			ensembleConfigArg = "ensemble=/System/Library/PrivateFrameworks/AppleCIOMeshConfigSupport.framework/Versions/A/Resources/ensemblesetup-4nodes.json"

			// For single chassis we will default to the slot number
			guard let matchingDict = IOServiceMatching("AppleOceanComputeMCU") else {
				throw "Could not make AppleOceanComputeMCU matching dictionary"
			}

			let iterator = IOKitManagedHandle()
			let handler = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator.handle)
			guard handler == kIOReturnSuccess else {
				throw "Could not find AppleOceanComputeMCU"
			}

			let service = IOKitManagedHandle(handle: IOIteratorNext(iterator.handle))
			guard service.handle != 0 else {
				throw "Could not find AppleOceanComputeMCU"
			}

			guard let data = IORegistryEntryCreateCFProperty(service.handle, "Carrier Slot" as CFString, kCFAllocatorDefault, 0) else {
				throw "Could not find AppleOceanComputeMCU::Carrier Slot"
			}

			let slot = data.takeRetainedValue() as! NSNumber
			nodeRank = slot.intValue

			// Get a timeout if it's set
			timeoutSecondsArg = args.first(where: { $0.hasPrefix("timeout=") })
			if let timeoutSecondsArg = timeoutSecondsArg {
				timeoutSeconds = Int(String(timeoutSecondsArg.dropFirst("timeout=".count)))!
			}
		} else {
			ensembleConfigArg = args.first(where: { $0.hasPrefix("ensemble=") })
		}

		if nodeRank == -1 {
			nodeRankArg = args.first(where: { $0.hasPrefix("rank=") })
			guard let nodeRankArg = nodeRankArg else {
				print("Usage: ensembleconfig [--debug] [--hypercube] <ensemble=ensemble_config> <rank=noderank>")
				return
			}

			nodeRank = Int(String(nodeRankArg.dropFirst("rank=".count)))!
		}

		guard let ensembleConfigArg = ensembleConfigArg else {
			print("Usage: ensembleconfig [--debug] [--hypercube] <ensemble=ensemble_config> <rank=noderank>")
			return
		}

		var ensembleConfig = try readEnsembleConfiguration(filePath: String(ensembleConfigArg.dropFirst("ensemble=".count)))

		// go through the ensembleconfig and put in the bmc as the chassis for single chassis test
		if self.singleChassisCIOCableTestMode {
			let bmc = remote_device_copy_unique_of_type(REMOTE_DEVICE_TYPE_COMPUTE_CONTROLLER)
			guard let bmc = bmc else {
				throw "Could not find bmc"
			}

			guard let serialNumberObj = remote_device_copy_property(bmc, "SerialNumber") else {
				throw "Could not get BMC serial number"
			}

			guard let serialNumber = try serialNumberObj.asString(objName: "SerialNumber") else {
				throw "Could not get BMC Serial number from xpc object"
			}

			for var node in ensembleConfig.nodes {
				node.chassisID = serialNumber
			}

			print("using BMC serial: \(serialNumber)")
		}

		print("Ensemble Configuration Read")
		print("=== NodeRank: \(nodeRank)")

		// verify the current node is in the ensemble configuration
		let currentNodeConfig = getNodeConfiguration(configuration: ensembleConfig, node: nodeRank)
		guard let currentNodeConfig = currentNodeConfig else {
			throw "Could not find \(nodeRank) in ensemble configuration"
		}

		let queue = DispatchSerialQueue(label: "cio_queue")
		if self.debugMode {
			backend = try SocketBackend(
				configuration: .init(
					queue: queue,
					node: currentNodeConfig,
					ensemble: ensembleConfig,
					delegate: self))
		} else {
			backend = try CIOBackend(
				configuration: .init(
					queue: queue,
					node: currentNodeConfig,
					ensemble: ensembleConfig,
					delegate: self))
		}

		guard let backend = backend else {
			throw "CIO backend not specified"
		}

		if checkBuffersUsed {
			do {
				let buffersUsed = try backend.getBuffersUsed()
				print("Buffers Used: \(buffersUsed)")
				exit(0)
			} catch {
				print("Failed to read buffers used")
				exit(1)
			}
		}

		let routerConfig = RouterConfiguration(backend: backend, node: currentNodeConfig, ensemble: ensembleConfig, delegate: self)
		var nodeCount = 8

		switch ensembleConfig.nodeCount {
		case 1:
			throw "Router1 not implemented"

		case 2:
			self.router = try Router2(configuration: routerConfig)
			nodeCount = 2

		case 4:
			self.router = try Router4(configuration: routerConfig)
			nodeCount = 4

		case 8:
			fallthrough

		case 16:
			fallthrough

		case 32:
			if self.hypercubeMode {
				self.router = try Router8Hypercube(configuration: routerConfig)
			} else {
				self.router = try Router8(configuration: routerConfig)
			}
			nodeCount = 8

		default:
			throw "Unsupported ensemble size: \(ensembleConfig.nodeCount)"
		}

		let canActivateMesh = try backend.canActivate(nodeCount: nodeCount)

		if canActivateMesh {
			print("Safe to activate mesh")
		} else {
			print("Cannot activate mesh")
			exit(1)
		}

		if self.autoActivate {
			if self.debugMode {
				let socketBackend = backend as! SocketBackend
				socketBackend.setBooted(booted: true)
			}
			try backend.activate()
			while true {
				usleep(1 * 1_000_000)
			}
		}

		if self.cioCableTestMode || self.singleChassisCIOCableTestMode {
			var previouslyActivated = false

			do {
				if self.cioCableTestMode {
					previouslyActivated = try backend.getConnectedNodes().count == 8
				} else if self.singleChassisCIOCableTestMode {
					previouslyActivated = try backend.getConnectedNodes().count == 4
				}
			} catch {
				// do nothing
			}

			var myRank = -1

			if !previouslyActivated {
				print("Activating \(self.cioCableTestMode ? "8" : "4") node CIO mesh")
				try backend.activate()

				var counter = 0
				while counter < timeoutSeconds {
					usleep(1 * 1_000_000)

					// Check if we connected to all nodes
					let nodes = try backend.getConnectedNodes()
					if self.cioCableTestMode, nodes.count == 8 {
						break
					}
					if self.singleChassisCIOCableTestMode, nodes.count == 4 {
						break
					}

					// We didn't, increment counter
					counter = counter + 1
				}

				print("Finished waiting \(counter) seconds. CIO should have activated")
				myRank = nodeRank
			} else {
				print("Ensemble already activated, assuming \(self.cioCableTestMode ? "8" : "4") node CIO mesh")

				// Verify all the input channels are set
				let nodes = try backend.getConnectedNodes()
				for n in nodes {
					let obj = n["inputChannel"]
					guard let inputChannel = obj as? Int else {
						throw "InputChannel is not an Int"
					}

					if inputChannel == -1 {
						let obj = n["rank"]
						guard let myId = obj as? Int else {
							throw "Rank is not an Int"
						}

						myRank = myId
						break
					}
				}
			}

			let cio = try backend.getCIOCableState()

			var cableStatus: [Bool] = .init(repeating: false, count: 8)
			var expectedPartners: [Int] = .init(repeating: -1, count: 8)
			var actualPartners: [Int] = .init(repeating: -1, count: 8)

			for (i, c) in cio.enumerated() {
				let cableConnectedObj = c["cableConnected"]
				guard let cableConnected = cableConnectedObj as? Int else {
					throw "cableConnected is not an Int"
				}

				let expectedPartnerObj = c["expectedPartnerHardwareNode"]
				guard let expectedPartner = expectedPartnerObj as? Int else {
					throw "expectedPartner is not an Int"
				}

				let actualPartnerObj = c["actualPartnerHardwareNode"]
				guard let actualPartner = actualPartnerObj as? Int else {
					throw "actualPartner is not an Int"
				}

				cableStatus[i] = cableConnected == 1
				expectedPartners[i] = expectedPartner
				actualPartners[i] = actualPartner
			}

			guard let matchingDict = IOServiceMatching("AppleOceanComputeMCU") else {
				throw "Could not make AppleOceanComputeMCU matching dictionary"
			}

			let iterator = IOKitManagedHandle()
			let handler = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator.handle)
			guard handler == kIOReturnSuccess else {
				throw "Could not find AppleOceanComputeMCU"
			}

			let service = IOKitManagedHandle(handle: IOIteratorNext(iterator.handle))
			guard service.handle != 0 else {
				throw "Could not find AppleOceanComputeMCU"
			}

			guard let data = IORegistryEntryCreateCFProperty(service.handle, "Carrier Slot" as CFString, kCFAllocatorDefault, 0) else {
				throw "Could not find AppleOceanComputeMCU::Carrier Slot"
			}

			let slot = data.takeRetainedValue() as! NSNumber

			print("-------------------------------------")
			print("Node:\(slot.intValue) Rank:\(myRank)")
			var error = false

			if !cableStatus[0] || !cableStatus[2] {
				print("PortB Cable not functioning")
				error = true
			}
			if self.cioCableTestMode {
				if !cableStatus[1] || !cableStatus[3] {
					print("PortA Cable not functioning")
					error = true
				}
			}
			if !cableStatus[4] || !cableStatus[5] || !cableStatus[6] || !cableStatus[7] {
				print("Internal Cable not functioning")
				error = true
			}

			print("-------------------------------------")
			if expectedPartners[0] != actualPartners[0] ||
				expectedPartners[2] != actualPartners[2] {
				print("PortB Cable not plugged correctly")
				error = true
			}
			if expectedPartners[1] != actualPartners[1] ||
				expectedPartners[3] != actualPartners[3] {
				print("PortA Cable not plugged correctly")
				error = true
			}
			if expectedPartners[4] != actualPartners[4] ||
				expectedPartners[5] != actualPartners[5] ||
				expectedPartners[6] != actualPartners[6] ||
				expectedPartners[7] != actualPartners[7] {
				print("Internal Cable not plugged correctly")
				error = true
			}

			if !error {
				print("No errors.")
			}

			exit(error ? EXIT_FAILURE : EXIT_SUCCESS)
		}

		while true {
			print("enter option (routes, ciomap, activate, deactivate, writeout:<file>, message:<node>:<data>, nodes, ciocable, setPeerHostnames, getPeerHostnames) : ")

			let line = readLine()

			guard let line = line else {
				print("goodbye")
				break
			}

			// Turn on All CIO Outgoing ports
			if line == "activate" {
				if self.debugMode {
					let socketBackend = backend as! SocketBackend
					socketBackend.setBooted(booted: true)
				}
				try backend.activate()
			} else if line == "routes" {
				let routes = self.router?.getRoutes()
				guard let routes = routes?.values else {
					continue
				}
				for route in routes {
					print(route)
				}
			} else if line == "ciomap" {
				let cioMap = self.router?.getCIOTransferMap()
				guard let cioMap = cioMap else {
					print("Error: CIOMap not available")
					continue
				}

				for (node, cioTransfer) in cioMap {
					var nodeString = ""
					if let input = cioTransfer.inputChannel {
						nodeString += "CIO\(input) --> "
					}
					nodeString += "\(node)"

					if !cioTransfer.outputChannels.isEmpty {
						nodeString += " --> "
					}

					for output in cioTransfer.outputChannels {
						nodeString += "CIO\(output), "
					}
					print("\(nodeString)")
				}
			} else if line == "deactivate" {
				try backend.deactivate()
				if self.debugMode {
					let socketBackend = backend as! SocketBackend
					socketBackend.setBooted(booted: false)
				}
			} else if line == "nodes" {
				let nodes = try backend.getConnectedNodes()
				for (i, node) in nodes.enumerated() {
					print("Node \(i)")
					print(node)
					print("=========")
				}
			} else if line == "ciocable" {
				let cio = try backend.getCIOCableState()
				for (i, cio) in cio.enumerated() {
					print("CIO \(i)")
					print(cio)
					print("=========")
				}
			} else if line.hasPrefix("setPeerHostnames:") {
				let components = line.components(separatedBy: ":")
				let ranksComponent = components[1].components(separatedBy: ",")
				try self.addHostnames(ranks: ranksComponent, config: ensembleConfig)

			} else {
				if line.hasPrefix("message:") {
					let components = line.components(separatedBy: ":")
					let destination = Int(components[1])!
					let messageString = components[2]

					try backend.sendControlMessage(node: destination, message: messageString.data(using: .utf8)!)
				} else if line.hasPrefix("writeout:") {
					let cioMap = self.router?.getCIOTransferMap()
					guard let cioMap = cioMap else {
						print("Error: CIOMap not available")
						continue
					}

					var outputFileData: String = .init()

					for (node, cioTransfer) in cioMap.sorted(by: { $0.0 < $1.0 }) {
						let outputArrayString = cioTransfer.outputChannels.map { String($0) }
						var inputString = ""
						if let input = cioTransfer.inputChannel {
							inputString = String(input)
						}

						outputFileData.append("\(node);\(inputString);\(outputArrayString.joined(separator: ","))\n")
					}

					let components = line.components(separatedBy: ":")
					let outputFile = components[1]

					try outputFileData.write(to: URL(fileURLWithPath: outputFile), atomically: true, encoding: String.Encoding.utf8)
				}
			}
		}
	}

	func addHostnames(ranks: [String], config: EnsembleConfiguration) throws {
		guard let backend = backend else {
			throw "CIO backend not specified"
		}

		for r in ranks {
			guard let nodeId = Int(r) else {
				throw "Error: not a valid node rank."
			}
			let nodeConfig = getNodeConfiguration(configuration: config, node: nodeId)
			guard let hostname = nodeConfig?.hostname else {
				throw "Unable to get hostname from configuration."
			}
			let result = try backend.addHostname(hostname: hostname, node: nodeId)
			if result == false {
				print("Attempt to add hostname failed. Check the logs for more details.")
				break
			}
			print("Added node \(nodeId) with hostname \(hostname).")
		}
	}
}

extension Agent: BackendDelegate {
	func channelChange(node: Int, chassis: String, channelIndex: Int, connected: Bool) {
		self.router?.channelChange(channelIndex: channelIndex, node: node, chassis: chassis, connected: connected)
	}

	func connectionChange(direction: BackendConnectionDirection, node: Int, channelIndex: Int, connected: Bool) {
		self.router?.connectionChange(direction: direction, channelIndex: channelIndex, node: node, connected: connected)
	}

	func networkConnectionChange(node: Int, connected: Bool) {
		self.router?.networkConnectionChange(node: node, connected: connected)
	}

	func incomingMessage(node: Int, message: Data) {
		do {
			let ensembleControlMessage = try JSONDecoder().decode(EnsembleControlMessage.self, from: message)

			switch ensembleControlMessage {
			case .OuterNodeMessage(let outerNode):
				let router8 = self.router as! Router8
				router8.outernodeMessage(outerNode)
			case .ForwardMessage(let forward):
				self.router?.forwardMessage(forward)
			}

			return
		} catch {
			// Did not get a ensemble control message, handle it differently
			// or error out
		}

		print("Received message from \(node) : \(String(data: message, encoding: .utf8)!)")
	}
}

extension Agent: RouterDelegate {
	func ensembleReady() {
		print("--> \(String(describing: self.router)) Ensemble Ready")

		let cioMap = self.router?.getCIOTransferMap()
		guard let cioMap = cioMap else {
			print("Error: CIOMap not available")
			return
		}
		var outputFileData: String = .init()

		for (node, cioTransfer) in cioMap.sorted(by: { $0.0 < $1.0 }) {
			let outputArrayString = cioTransfer.outputChannels.map { String($0) }
			var inputString = ""
			if let input = cioTransfer.inputChannel {
				inputString = String(input)
			}

			outputFileData.append("\(node);\(inputString);\(outputArrayString.joined(separator: ","))\n")
		}

		let outputFile = "ensemble.dat"

		do {
			try outputFileData.write(to: URL(fileURLWithPath: outputFile), atomically: true, encoding: String.Encoding.utf8)
		} catch {
			print("failed to write ensemble.dat")
			return
		}

		print("wrote ensemble.dat")

		if self.autoActivate {
			exit(EXIT_SUCCESS)
		}
	}

	func ensembleFailed() {
		print("--> \(String(describing: self.router)) Ensemble Failed")
	}

	func addPeerHostname(hostName: String, nodeRank: Int) {
		do {
			try self.backend?.addHostname(hostname: hostName, node: nodeRank)
		} catch {
			print("Failed to add peer hostname")
			return
		}
	}
}

var ensembleAgent: Agent = .init()
try ensembleAgent.main()
