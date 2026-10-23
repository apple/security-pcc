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
//  SCSlot.swift
//  SecureConfigDB
//

import Foundation
import os

/// SCSlot is the intermediate class that represents the collection of entries
/// that have been loaded at a particular slot.
@objc public class SCSlot: NSObject {
	public typealias EntriesType = [SCEntry]
	public var entries: EntriesType

	public let slotID: UUID
	public let algorithm: String
	public let recordType: String
	public let salt: String? // Should be deprecated in favor of the "Data?" version
	internal let saltData: Data?

	let slotURL: URL?

	static var logger: Logger {
		Logger(category: "\(Self.self)")
	}

	/// Creates a new SCSlot object.
	/// - Parameters:
	///   - slotURL: storage URL, may be nil for in-memory only
	///   - slotID: target UUID used during ratcheting
	///   - algorithm: algorithm used. Expected to be SHA256/SHA384
	///   - recordType: type of record. Expected to be Cryptex / Config
	///   - salt: salt used in SecureConfig hash (optional)
	init(slotURL: URL?, slotID: UUID, algorithm: String, recordType: String, salt: Data? = nil) {
		self.slotID = slotID
		self.algorithm = algorithm
		self.recordType = recordType
		self.slotURL = slotURL
		self.saltData = salt
		self.salt = salt?.base64EncodedString()
		self.entries = [SCEntry]()
	}

	public convenience init(createAtSlotURL slotURL: URL, slotID: UUID, algorithm: String, recordType: String,
		salt: Data? = nil) throws
	{
		self.init(slotURL: slotURL, slotID: slotID, algorithm: algorithm, recordType: recordType, salt: salt)
		try self.persist(slotURL: slotURL)
	}

	/// Convenience initializer used to create a store based on a location.
	/// This is used to restore state after a launch
	/// - Parameter slotURL: target location for the store
	public convenience init(slotURL: URL) throws {
		let logger = Logger(category: "SCSlot(loadFromURL:)")

		guard let slotID = UUID(uuidString: slotURL.lastPathComponent) else {
			logger.error("Invalid slot path \(slotURL.path)")
			throw SCUtilError.slotInvalidNameInPath
		}

		let infoURL = slotURL.appendingPathComponent(CONSTANTS.SLOT)
		guard let infoContent = infoURL.readDataAtPath() else {
			logger.error("No info file at \(infoURL.path)")
			throw SCUtilError.slotURLDataUnreadable
		}

		let slotInfo: [String: String]
		do {
			slotInfo = try JSONDecoder().decode([String: String].self, from: infoContent)
		} catch {
			logger.error("Failed to decode contents of \(infoURL.path) to [String: String]")
			throw SCUtilError.slotInfoDeserializationFailed
		}

		guard let algorithm = slotInfo[CONSTANTS.ALGO] else {
			logger.error("No \(CONSTANTS.ALGO) in file at \(infoURL.path)")
			throw SCUtilError.slotInfoNoAlgorithm
		}

		guard let recordtype = slotInfo[CONSTANTS.TYPE] else {
			logger.error("No \(CONSTANTS.TYPE) in file at \(infoURL.path)")
			throw SCUtilError.slotInfoNoType
		}

		let salt: Data?
		if let saltBase64Encoded = slotInfo[CONSTANTS.SALT] {
			salt = Data(base64Encoded: saltBase64Encoded)
			guard salt != nil else {
				logger.error("Failed to decode salt as base64-encoded string")
				throw SCUtilError.slotInfoDeserializationFailed
			}
		} else {
			salt = nil
			logger.debug("No \(CONSTANTS.SALT) in file at \(infoURL.path)")
		}

		self.init(slotURL: slotURL, slotID: slotID, algorithm: algorithm, recordType: recordtype, salt: salt)
		self.loadContents(slotURL: slotURL)
	}

	/// Persists the SCSlot to disk. Necessary metadata will be added at the
	/// target location that can be used to reload information.
	func persist(slotURL: URL) throws {
		let manager = FileManager.default
		let infoURL = slotURL.appendingPathComponent(CONSTANTS.SLOT)

		do {
			try manager.createDirectory(at: slotURL, withIntermediateDirectories: false)
		} catch {
			Self.logger.error("Failed to create slot directory at \(slotURL.path) with \(error)")
			throw SCUtilError.slotDirectoryCreationFailed
		}

		do {
			try self.serializeInfo().write(to: infoURL)
		} catch {
			Self.logger.error("Failed to write slot info at \(infoURL.path) with \(error)")
			throw SCUtilError.slotInfoSerializationFailed
		}
	}

	/// Determines the internal name of the new entry as the 3-digit index
	/// into its array. Writes the content of the entry and any metadata if
	/// available
	/// - Parameter entry: target SCEntry to write
	@objc public func append(_ entry: SCEntry) throws {
		let contentName = String(format: "%03lld", self.entries.count)

		if let slotURL = self.slotURL {
			let contentURL = slotURL.appendingPathComponent(contentName)

			do {
				try entry.write(entryURL: contentURL)
			} catch {
				Self.logger.error("Failed to write to \(contentURL.path) with \(error)")
				throw SCUtilError.slotEntryAddFailed
			}
		}

		self.entries.append(entry)
	}

	/// Parses the contents of slotURL and loads any available SCEntries
	func loadContents(slotURL: URL) {
		let manager = FileManager.default
		do {
			let files = try manager.contentsOfDirectory(atPath: slotURL.path)
			for filename in files.sorted() {
				// XXX: Make this a pattern match of the expected slot pattern instead of a deny-list
				if filename.hasSuffix(CONSTANTS.META) || filename == CONSTANTS.SLOT {
					continue
				}
				Self.logger.log("Parsing sorted slot \(filename)")
				let entryURL = slotURL.appendingPathComponent(filename)
				let entry = try SCEntry(entryURL: entryURL)
				self.entries.append(entry)
			}
		} catch {
			Self.logger.error("Failed to read files at \(slotURL.path) with error \(error)")
		}
	}

	/// Internal method to serialize the metadata of the SCStore
	/// - Returns: JSON representation of the slotInfo dictionary
	func serializeInfo() throws -> Data {
		let slotInfo: [String: String]
		if let saltData = saltData {
			slotInfo = [CONSTANTS.ALGO: algorithm, CONSTANTS.TYPE: recordType, CONSTANTS.SALT: saltData.base64EncodedString()]
		} else {
			slotInfo = [CONSTANTS.ALGO: algorithm, CONSTANTS.TYPE: recordType]
		}

		let encoder  = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		return try encoder.encode(slotInfo)
	}
}
