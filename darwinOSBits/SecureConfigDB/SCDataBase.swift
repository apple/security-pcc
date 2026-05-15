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
//  SecureConfigDB.swift
//  SecureConfigDB
//

import Foundation
import os

/// Top level object representing the SecureConfigDB. This object
/// is used to add stores for new ratcheting slots and to add new entries
/// to the existing store. It is the main tool to extract a summary of all
/// the ratcheted contents
@objc public class SCDataBase: NSObject {
	static public let defaultURL = URL(fileURLWithPath: "/var/db/secureconfig")
	let dbURL: URL

	public typealias SlotsType = [UUID: SCSlot]
	public var slots: SlotsType
	
	subscript(index: UUID) -> SCSlot? {
		return slots[index]
	}

	static var logger: Logger {
		Logger(category: "\(Self.self)")
	}

	/// Initializer for custom location. Can be used for testing
	/// - Parameter dbURL: Target location to set the database
	public init(dbURL: URL = SCDataBase.defaultURL) {
		let bootUUID: String
		do {
			bootUUID = try readBootSessionUUID()
		} catch {
			fatalError("Failed to read boot session uuid: \(error)")
		}

		self.dbURL = dbURL.appendingPathComponent(bootUUID)
		self.slots = SCDataBase.loadContents(dbURL: self.dbURL)
	}

	/// Standard initializer. Available in ObjC as init;
	@objc override public convenience init() {
		self.init(dbURL: SCDataBase.defaultURL)
	}

	/// Recursively searches the target location and loads the contents.
	/// - Parameter dbURL: Target url for the database
	/// - Returns: A dictionary of slot UUIDs -> SCSlot
	static func loadContents(dbURL: URL) -> [UUID: SCSlot] {
		let loadingLogger = Logger(category: "SCDB_load")
		var slots = [UUID: SCSlot]()
		let manager = FileManager.default
		var candidates: [String]

		loadingLogger.log("Loading SecureConfigDB at \(dbURL.path)")
		do {
			// Create if not exists
			try manager.createDirectory(at: dbURL, withIntermediateDirectories: true)
			if let candidateArray = try manager.contentsOfDirectory(atPath: dbURL.path) as [String]? {
				candidates = candidateArray
			} else {
				loadingLogger.error("Candidate array was nil at \(dbURL.path)")
				return slots
			}
		} catch {
			loadingLogger.error("Failed to read \(dbURL.path) with error \(error)")
			return slots
		}

		for candidate in candidates {
			if let slotID = UUID(uuidString: candidate) as UUID? {
				let slotURL = dbURL.appendingPathComponent(slotID.uuidString)
				do {
					let slot = try SCSlot(slotURL: slotURL)
					slots[slotID] = slot
				} catch {
					loadingLogger.error("Failed  to parse \(slotURL.path) with \(error)")
				}
			}
		}
		return slots
	}


	public func slot(slotID: UUID, algorithm: String, recordType: String, salt: String? = nil) throws -> SCSlot {
		let saltData: Data?
		if let salt = salt {
			saltData = Data(base64Encoded: salt)
			guard saltData != nil else {
				throw SCUtilError.slotDataMismatch
			}
		} else {
			saltData = nil
		}
		return try slot(slotID: slotID, algorithm: algorithm, recordType: recordType, salt: saltData)
	}

	public func slot(slotID: UUID, algorithm: String, recordType: String) throws -> SCSlot {
		let salt: Data? = nil
		return try slot(slotID: slotID, algorithm: algorithm, recordType: recordType, salt: salt)
	}

	@objc public func slot(slotID: UUID, algorithm: String, recordType: String, salt: Data? = nil) throws -> SCSlot {
		if let slot = slots[slotID] {
			if slot.algorithm != algorithm || slot.recordType != recordType || 
			   (salt != nil && slot.saltData != salt) {
				throw SCUtilError.slotDataMismatch
			}
			return slot
		}

		let slotURL = dbURL.appendingPathComponent(slotID.uuidString)
		let slot = try SCSlot(createAtSlotURL: slotURL, slotID: slotID,
				algorithm: algorithm, recordType: recordType,
				salt: salt)

		slots[slotID] = slot

		return slot
	}

}

// Make SCDatabase behave like a Sequence of SCSlot
extension SCDataBase : Sequence {
	public typealias Iterator = SlotsType.Iterator

	public func makeIterator() -> SlotsType.Iterator {
		return slots.makeIterator()
	}
}
