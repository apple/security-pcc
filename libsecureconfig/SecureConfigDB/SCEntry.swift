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
//  SCEntry.swift
//  SecureConfigDB
//

import Foundation
import os

/// The SCEntry class represents a single item that has been recorded in a
/// SCSlot. This class wraps the reading/writing of entries to a particular
/// location and metadata interactions
@objc public class SCEntry: NSObject {
	/// Exactly what was ratcheted
	public let data: Data

	/// Readable additional info
	public var metadata: [String: Data]

	static var logger: Logger {
		Logger(category: "\(Self.self)")
	}

	/// Simple initializer for an SCEntry. This is called by SCSlot factory
	/// method and passes in the target slotID.
	/// - Parameters:
	///   - data: data represented in the entry (read-only)
	///   - metadata: optional information to preload - (read-write)
	@objc public init(data: Data, metadata: [String: Data]?) {
		self.data = data
		self.metadata = metadata ?? [:]
	}

	/// Loads an entry from a file location. The metadata is expected to be
	/// located at "FILENAME".meta. This is called by SCSlot when loading from
	/// a directory
	/// - Parameters:
	///   - entryURL: URL for the file to load
	convenience init(entryURL: URL) throws {
		let logger = Logger(category: "SCEntry(entryURL:)")

		if !entryURL.exists() {
			logger.error("Entry URL doesn't exist")
			throw SCUtilError.recordLocationNotFound
		}

		guard let data = entryURL.readDataAtPath() as Data? else {
			logger.error("Failed to read contents of \(entryURL.path)")
			throw SCUtilError.recordReadFailed
		}

		var info: [String: Data]?
		let metadataURL = entryURL.appendingPathExtension(CONSTANTS.META)

		if metadataURL.exists() {
			if let metadataContents = metadataURL.readDataAtPath() as Data? {
				info = try SCEntry.deserialize(metadata: metadataContents)
			}
		}

		self.init(data: data, metadata: info)
	}

	/// Method to add metadata content to a particular entry.
	/// - Parameters:
	///   - key: name to access the data at a later time
	///   - data: data blob associated with the key
	@objc public func setMetadata(key: String, data: Data) {
		self.metadata[key] = data
	}

	/// Serializes the contents of the SCEntry. Since Data is not supported in
	/// JSONSerialization, it is necessary to convert the Data values in the
	/// metadata dictionary to base64 encoded strings. The resulting
	/// [String: String] dictionary is then serialized for writing
	/// - Returns: Tuple of (contents, optional metadata)
	static func serialize(metadata: [String : Data]) throws -> Data {
		var encodedMetadata: Data
		do {
			let base64Values = metadata.mapValues { $0.base64EncodedString() }
			encodedMetadata = try JSONSerialization.data(withJSONObject: base64Values)
		} catch {
			self.logger.error("Could not serialize metadata")
			throw SCUtilError.recordSerializeFailed
		}
		return encodedMetadata
	}

	/// This method reverses the serialization used above. Extracts a
	/// [String: String dictionary from the Data and then creates
	/// Data objects for the Base64 encoded strings
	/// - Parameter metadata: Contents from a FILE.meta
	/// - Returns: Returns the metadata object if successful
	static func deserialize(metadata: Data) throws -> [String: Data] {
		guard let typedDict = try? JSONSerialization.jsonObject(with: metadata, options: []) as? [String: String] else {
			self.logger.error("Could not deserialize metadata")
			throw SCUtilError.recordDeserializeFailed
		}
		return typedDict.mapValues { Data(base64Encoded: $0) ?? Data() }
	}

	/// Writes the contents of the SCEntry to a location.
	/// - Parameter entryURL: location to write entry
	public func write(entryURL: URL) throws {
		try data.write(to: entryURL)

		if !metadata.isEmpty {
			let infoURL = entryURL.appendingPathExtension(CONSTANTS.META)
			try SCEntry.serialize(metadata: metadata).write(to: infoURL)
		}
	}
}
