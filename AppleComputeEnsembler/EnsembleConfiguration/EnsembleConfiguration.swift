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
//  EnsembleConfiguration.swift
//  ensembleconfig
//
//  Created by Sumit Kamath on 11/17/23.
//

import Foundation

@_spi(Daemon) import AppleComputeEnsembler // Helper functions

let kEnsembleConfigurationPreferenceKey = "EnsembleConfiguration"

enum Rank: Int, Decodable {
	case Rank0 = 0
	case Rank1 = 1
	case Rank2 = 2
	case Rank3 = 3
	case Rank4 = 4
	case Rank5 = 5
	case Rank6 = 6
	case Rank7 = 7
	case Rank8 = 8
	case Rank9 = 9
	case Rank10 = 10
	case Rank11 = 11
	case Rank12 = 12
	case Rank13 = 13
	case Rank14 = 14
	case Rank15 = 15
	case Rank16 = 16
	case Rank17 = 17
	case Rank18 = 18
	case Rank19 = 19
	case Rank20 = 20
	case Rank21 = 21
	case Rank22 = 22
	case Rank23 = 23
	case Rank24 = 24
	case Rank25 = 25
	case Rank26 = 26
	case Rank27 = 27
	case Rank28 = 28
	case Rank29 = 29
	case Rank30 = 30
	case Rank31 = 31
}

struct NodeConfiguration: CustomStringConvertible, Decodable, ReportableString {
	let chassisID: String
	private let _rank: Rank
	let hostName: String?
	// port is needed for unit tests on desk, since we are running on same mac. Otherwise we will use
	// default port.
	let port: UInt16?

	var rank: Int {
		self._rank.rawValue
	}

	init(chassisID: String, rank: Rank, hostName: String?, port: UInt16? = nil) {
		self.chassisID = chassisID
		self._rank = rank
		self.hostName = hostName
		self.port = port
	}

	// This is OK to log publically because the private fields are obfuscated.
	var publicDescription: String {
		return """
		{\
		rank: \(self.rank), \
		chassisID: %s, \
		hostName: %s\
		}
		"""
	}

	var description: String {
		return """
		{\
		rank: \(self.rank), \
		chassisID: \(self.chassisID), \
		hostName: \(String(describing: self.hostName))\
		}
		"""
	}

	private enum CodingKeys: String, CodingKey {
		case chassisID
		case _rank = "rank"
		case hostName
		case port
	}
}

struct EnsembleConfiguration: CustomStringConvertible, Decodable, ReportableString {
	var backendType: BackendType?
	var hypercube: Bool?
	var ensembleID: String?
	var rackID: String?
	let nodes: [String: NodeConfiguration]

	// This is OK to log publically because the private fields are obfuscated.
	var publicDescription: String {
		var desc = """
		{
		    backendType: \(String(describing: self.backendType)),
		    hypercube: \(String(describing: self.hypercube)),
		    ensembleID: \(String(describing: self.ensembleID)),
		    rackID: \(String(describing: self.rackID)),
		    nodes: [
		"""
		for (_, value) in self.nodes {
			desc = """
			\(desc)\n\
			\t\t(key: "%s", value: \(value))
			"""
		}
		desc = "\(desc)\n\t]]"
		desc = "\(desc)\n}"
		return desc
	}

	var description: String {
		var desc = """
		{
		    backendType: \(String(describing: self.backendType)),
		    hypercube: \(String(describing: self.hypercube)),
		    ensembleID: \(String(describing: self.ensembleID)),
		    rackID: \(String(describing: self.rackID)),
		    nodes: [
		"""
		for (key, value) in self.nodes {
			desc = """
			\(desc)\n\
			\t\t(key: "\(key)", value: \(value))
			"""
		}
		desc = "\(desc)\n\t]]"
		desc = "\(desc)\n}"
		return desc
	}

	private enum CodingKeys: String, CodingKey {
		case backendType
		case hypercube
		case ensembleID = "ensemble_id"
		case rackID = "rack_id"
		case nodes
	}
}

func readEnsembleConfiguration(filePath: String) throws -> EnsembleConfiguration {
	guard FileManager.default.fileExists(atPath: filePath) else {
		preconditionFailure("\(filePath) does not exist")
	}

	let fileData = try Data(contentsOf: URL(filePath: filePath))
	return try JSONDecoder().decode(EnsembleConfiguration.self, from: fileData)
}

func readEnsemblerPreferences() throws -> EnsembleConfiguration {
	guard let ensembleConfigNS = CFPreferencesCopyValue(
		kEnsembleConfigurationPreferenceKey as CFString,
		kEnsemblerPrefix as CFString,
		kCFPreferencesAnyUser,
		kCFPreferencesAnyHost
	) as? NSDictionary else {
		throw "Failed to import configuration from preferences"
	}

	let data = try PropertyListSerialization.data(
		fromPropertyList: ensembleConfigNS,
		format: .binary,
		options: 0
	)

	let decoder = PropertyListDecoder()
	let ensembleConfig = try decoder.decode(EnsembleConfiguration.self, from: data as Data)

	return ensembleConfig
}

func getDefaultOneNodePreferences() throws -> EnsembleConfiguration {
	let cfPrefsKeyList = CFPreferencesCopyKeyList(
		kEnsemblerPrefix as CFString,
		kCFPreferencesAnyUser,
		kCFPreferencesAnyHost
	)
	if let cfPrefsKeyList = cfPrefsKeyList as? [AnyObject] {
		if cfPrefsKeyList.contains(where: { $0 as? String == "EnsembleConfiguration" }) {
			throw "Oops: Attempting to create default one-node config is not allowed!"
		}
	} else if cfPrefsKeyList != nil {
		throw "Oops: Failed to cast CFArray to Swift array!"
	}

	let udid = try getNodeUDID()
	let hostName = ProcessInfo.processInfo.hostName
	let chassisID = "Unknown"

	return EnsembleConfiguration(
		backendType: BackendType.StubBackend,
		hypercube: false,
		nodes: [
			udid: NodeConfiguration(
				chassisID: chassisID,
				rank: Rank.Rank0,
				hostName: hostName
			),
		]
	)
}
