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
//  FilePath+AppleArchive.swift
//  DarwinInit
//

import Foundation
import System
import AppleArchive
import CryptoKit

extension FilePath {
    fileprivate enum AppleArchiveError: Error {
        case streamOpenFailure
        case encryptionContextFailure
        case ioError
        case invalidInput
        case archiveIdentifierMismatch
    }
    
	func createAppleEncryptedArchive(at path: FilePath, using key: SymmetricKey, permissions: FilePermissions = .fileDefault, compression: Bool = true) throws {
		let isDirectory = (try? self.directoryExists()) == true
		let inputDescriptionStr = isDirectory ? "with the contents of directory" : "with"
		
		logger.debug("Creating Apple Encrypted Archive \(inputDescriptionStr) \(self, privacy: .public) at \(path, privacy: .public)")
		
		let encryptionContext = ArchiveEncryptionContext(
			profile: .hkdf_sha256_aesctr_hmac__symmetric__none,
			compressionAlgorithm: compression ? .lzfse : .none)
		try encryptionContext.setSymmetricKey(key)
		
		guard let outputFileStream = ArchiveByteStream.fileStream(
			path: path,
			mode: .writeOnly,
			options: [.create, .truncate],
			permissions: permissions) else {
			logger.error("Failed to open output file stream for \(path, privacy: .public)")
			throw AppleArchiveError.streamOpenFailure
		}
		
		defer {
			do {
				try outputFileStream.close()
			} catch {
				logger.debug("Failed to close output file stream for \(self, privacy: .public): \(error, privacy: .public)")
			}
		}
		
		guard let encryptionStream = ArchiveByteStream.encryptionStream(
			writingTo: outputFileStream,
			encryptionContext: encryptionContext) else {
			logger.error("Failed to open encryption stream for \(self, privacy: .public)")
			throw AppleArchiveError.streamOpenFailure
		}
		
		defer {
			do {
				try encryptionStream.close()
			} catch {
				logger.debug("Failed to close encryption stream for \(path, privacy: .public): \(error, privacy: .public)")
			}
		}

		do {
			try _encodeAppleArchive(toArchiveByteStream: encryptionStream, from: self)
		} catch {
			logger.error("Failed to create Apple Encrypted Archive \(inputDescriptionStr) \(self, privacy: .public) at \(path, privacy: .public): \(error, privacy: .public)")
			throw AppleArchiveError.ioError
		}
	}

	enum AppleEncryptedArchiveExtractionMode {
		// Decrypts the AEA container and extracts an embedded Apple Archive in one step.
		case extractEmbeddedAppleArchive

		// Commonly, the Apple Encrypted Archive container is expected to have an Apple Archive
		// inside that can contain multiple files as well as the attributes of those files.
		// This mode allows the extraction of the raw bytes contained within the container.
		// This is useful when what is contained in the AEA is not an Apple Archive.
		// If the container contains an Apple Archive, then an Apple Archive will be written
		// to disk.
		case extractRawBytes(outputFilePermissions: FilePermissions)
	}

    func extractAppleEncryptedArchive(to path: FilePath, using key: SymmetricKey, expectingArchiveIdentifier expectedArchiveIdentifier: Data? = nil, mode: AppleEncryptedArchiveExtractionMode = .extractEmbeddedAppleArchive) throws {
        logger.debug("Extracting Apple Encrypted Archive at \(self, privacy: .public) into \(path, privacy: .public)")

		switch mode {
		case .extractEmbeddedAppleArchive:
		   guard (try? path.directoryExists()) == true else {
				logger.error("Output path \(path, privacy: .public) is not a directory or is not accessible")
                throw AppleArchiveError.invalidInput
           }
		default:
			break
		}

        guard let archiveStream = ArchiveByteStream.fileStream(
            path: self,
            mode: .readOnly,
            options: [],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]) else {
            logger.error("Failed to open archive file stream for \(self, privacy: .public)")
            throw AppleArchiveError.streamOpenFailure
        }

		defer {
			do {
				try archiveStream.close()
			} catch {
				logger.debug("Failed to close archive file stream for \(self, privacy: .public): \(error, privacy: .public)")
			}
		}
        
        guard let encryptionContext = ArchiveEncryptionContext(from: archiveStream) else {
            logger.error("Failed to get encryption context for \(self, privacy: .public)")
            throw AppleArchiveError.encryptionContextFailure
        }
        do {
            try encryptionContext.setSymmetricKey(key)
        } catch {
            logger.error("Failed to set symmetric key for encryption context \(self, privacy: .public)")
            throw error
        }
        
        // decryption spawns additional threads, 12 is sufficient to saturate IO on production hardware
        // i.e. increasing the thread count beyond 12 does not increase decryption speed
        let decryptionThreadCount = 12
        logger.info("Decryption thread count: \(decryptionThreadCount) (\(self))")
        guard let decryptStream = ArchiveByteStream.decryptionStream(
            readingFrom: archiveStream,
			encryptionContext: encryptionContext,
            threadCount: decryptionThreadCount) else {
            logger.error("Failed to open decryption stream for \(self, privacy: .public)")
            throw AppleArchiveError.streamOpenFailure
        }

		defer {
			do {
				try decryptStream.close()
			} catch {
				logger.debug("Failed to close decryption stream for \(self, privacy: .public): \(error, privacy: .public)")
			}
		}

        logger.debug("AEA compression algorithm used for \(self, privacy: .public): \(encryptionContext.compressionAlgorithm)")

		if let expectedArchiveIdentifier = expectedArchiveIdentifier {
			guard let archiveIdentifier = encryptionContext.archiveIdentifier else {
				logger.error("Archive identifier is missing on archive")
				throw AppleArchiveError.archiveIdentifierMismatch
			}

			if archiveIdentifier != expectedArchiveIdentifier {
                logger.error("Archive identifier does not match expected")
				throw AppleArchiveError.archiveIdentifierMismatch
			}
		}

		switch mode {
		case .extractEmbeddedAppleArchive:
			do {
				try _extractAppleArchive(fromArchiveByteStream: decryptStream, to: path)
			} catch {
				logger.error("Failed to extract Apple Encrypted Archive at \(self, privacy: .public) to \(path, privacy: .public): \(error, privacy: .public)")
				throw AppleArchiveError.ioError
			}
		case .extractRawBytes(let permissions):
			guard let outputFileStream = ArchiveByteStream.fileStream(
				path: path,
				mode: .writeOnly,
				options: [.create, .truncate],
				permissions: permissions) else {
				logger.error("Failed to open output file stream for \(path, privacy: .public)")
				throw AppleArchiveError.streamOpenFailure
			}

			defer {
				do {
					try outputFileStream.close()
				} catch {
					logger.debug("Failed to close output file stream for \(self, privacy: .public): \(error, privacy: .public)")
				}
			}

			_ = try ArchiveByteStream.process(readingFrom: decryptStream, writingTo: outputFileStream)
		}
    }

	func createAppleArchive(at path: FilePath, permissions: FilePermissions = .fileDefault, compression: Bool) throws {
		let isDirectory = (try? self.directoryExists()) == true
		let inputDescriptionStr = isDirectory ? "with the contents of directory" : "with"

		logger.debug("Creating Apple Archive \(inputDescriptionStr) \(self, privacy: .public) at \(path, privacy: .public)")

		guard let outputFileStream = ArchiveByteStream.fileStream(
			path: path,
			mode: .writeOnly,
			options: [.create, .truncate],
			permissions: permissions) else {
			logger.error("Failed to open output file stream for \(path, privacy: .public)")
			throw AppleArchiveError.streamOpenFailure
		}

		defer {
			do {
				try outputFileStream.close()
			} catch {
				logger.debug("Failed to close output file stream for \(path, privacy: .public): \(error, privacy: .public)")
			}
		}

		let compressionStream: ArchiveByteStream?

		if (compression) {
			compressionStream = ArchiveByteStream.compressionStream(
				using: .lzfse,
				writingTo: outputFileStream)
			if compressionStream == nil {
				logger.error("Failed to open compression stream for \(path, privacy: .public)")
				throw AppleArchiveError.streamOpenFailure
			}
		} else {
			compressionStream = nil
		}

		defer {
			if let compressionStream = compressionStream {
				do {
					try compressionStream.close()
				} catch {
					logger.debug("Failed to close compression stream for \(path, privacy: .public): \(error, privacy: .public)")
				}
			}
		}

		do {
			try _encodeAppleArchive(
				toArchiveByteStream: compressionStream ?? outputFileStream,
				from: self)
		} catch {
			logger.error("Failed to create Apple Archive \(inputDescriptionStr) \(self, privacy: .public) at \(path, privacy: .public): \(error, privacy: .public)")
			throw AppleArchiveError.ioError
		}
	}

	// NOTE: ParallelCompression supports a few other archive formats, so it is possible that this function succeeds
	//       even if the archive was not actually an AppleArchive. The caller should check the magic of the file
	//       before calling this function to know if the file is actually an AppleArchive.
	func extractUncompressedAppleArchive(to path: FilePath) throws {
		logger.log("Extracting uncompressed Apple Archive at \(self, privacy: .public) into \(path, privacy: .public)")

		guard (try? path.directoryExists()) == true else {
			logger.error("Output path \(path, privacy: .public) is not a directory or is not accessible")
			throw AppleArchiveError.invalidInput
		}

		guard let archiveStream = ArchiveByteStream.fileStream(
			path: self,
			mode: .readOnly,
			options: [],
			permissions: [.ownerReadWrite, .groupRead, .otherRead]) else {
			logger.error("Failed to open archive file stream for \(self, privacy: .public)")
			throw AppleArchiveError.streamOpenFailure
		}

		defer {
			do {
				try archiveStream.close()
			} catch {
				logger.debug("Failed to close archive file stream for \(self, privacy: .public): \(error, privacy: .public)")
			}
		}

		do {
			try _extractAppleArchive(fromArchiveByteStream: archiveStream, to: path)
		} catch {
			logger.error("Failed to extract uncompressed Apple Archive at \(self, privacy: .public) to \(path, privacy: .public): \(error, privacy: .public)")
			throw AppleArchiveError.ioError
		}

		logger.log("Successfully extracted uncompressed Apple Archive at \(self, privacy: .public) into \(path, privacy: .public)")
	}

	// NOTE: An input Apple Archive must be uncompressed to work with the FilePath.extractAppleEncryptedArchive() function above.
	func wrapFileContentsInAppleEncryptedArchive(at path: FilePath, using key: SymmetricKey, permissions: FilePermissions = .fileDefault, compression: Bool = true) throws {
		logger.debug("Wrapping the contents of file at \(self) in Apple Encrypted Archive at \(path)")

		let encryptionContext = ArchiveEncryptionContext(
			profile: .hkdf_sha256_aesctr_hmac__symmetric__none,
			compressionAlgorithm: compression ? .lzfse : .none)
		try encryptionContext.setSymmetricKey(key)

		guard let inputFileStream = ArchiveByteStream.fileStream(
			path: self,
			mode: .readOnly,
			options: [],
			permissions: [.ownerReadWrite, .groupRead, .otherRead]) else {
			logger.error("Failed to open input file stream for \(self, privacy: .public)")
			throw AppleArchiveError.streamOpenFailure
		}

		defer {
			do {
				try inputFileStream.close()
			} catch {
				logger.debug("Failed to close input file stream for \(self, privacy: .public): \(error, privacy: .public)")
			}
		}

		guard let outputFileStream = ArchiveByteStream.fileStream(
			path: path,
			mode: .writeOnly,
			options: [.create, .truncate],
			permissions: permissions) else {
			logger.error("Failed to open output file stream to \(path, privacy: .public)")
			throw AppleArchiveError.streamOpenFailure
		}

		defer {
			do {
				try outputFileStream.close()
			} catch {
				logger.debug("Failed to close output file stream to \(self, privacy: .public): \(error, privacy: .public)")
			}
		}

		guard let encryptionStream = ArchiveByteStream.encryptionStream(
			writingTo: outputFileStream,
			encryptionContext: encryptionContext) else {
			logger.error("Failed to open encryption stream for \(path, privacy: .public)")
			throw AppleArchiveError.streamOpenFailure
		}

		defer {
			do {
				try encryptionStream.close()
			} catch {
				logger.debug("Failed to close encryption stream for \(path, privacy: .public): \(error, privacy: .public)")
			}
		}

		do {
            _ = try ArchiveByteStream.process(readingFrom: inputFileStream, writingTo: encryptionStream)
		} catch {
			logger.error("Failed to create Apple Encrypted Archive at \(path, privacy: .public) with contents of file at \(self, privacy: .public): \(error, privacy: .public)")
			throw AppleArchiveError.ioError
		}
	}

	enum ArchiveType {
		case AppleEncryptedArchive
		case UncompressedAppleArchive
	}

	func readArchiveMagic() throws -> ArchiveType? {
		guard let fileHandle = FileHandle(forReadingAtPath: self.description) else {
			throw Errno.noSuchFileOrDirectory
		}

		guard let magic = try fileHandle.read(upToCount: 4) else {
			throw Errno.ioError
		}

		if magic.elementsEqual([UInt8(ascii: "A"), UInt8(ascii: "E"), UInt8(ascii: "A"), UInt8(ascii: "1")]) {
			logger.debug("Apple Encrypted Archive detected at \(self)")
			return ArchiveType.AppleEncryptedArchive
		} else if magic.elementsEqual([UInt8(ascii: "A"), UInt8(ascii: "A"), UInt8(ascii: "0"), UInt8(ascii: "1")]) {
			logger.debug("Uncompressed Apple Archive detected at \(self)")
			return ArchiveType.UncompressedAppleArchive
		} else {
			logger.debug("No known archive magic in file at \(self)")
			return nil
		}
	}
    
    func readAppleEncryptedArchiveIdentifier() throws -> Data? {
        guard let archiveStream = ArchiveByteStream.fileStream(
            path: self,
            mode: .readOnly,
            options: [],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]) else {
            logger.error("Failed to open archive file stream for \(self, privacy: .public)")
            throw AppleArchiveError.streamOpenFailure
        }
        
        guard let encryptionContext = ArchiveEncryptionContext(from: archiveStream) else {
            logger.error("Failed to get encryption context for \(self, privacy: .public)")
            throw AppleArchiveError.encryptionContextFailure
        }
        
        return encryptionContext.archiveIdentifier
    }
}

fileprivate func _encodeAppleArchive(toArchiveByteStream stream: ArchiveByteStream, from path: FilePath) throws {
	let isDirectory = (try? path.directoryExists()) == true

	guard let encodeStream = ArchiveStream.encodeStream(writingTo: stream) else {
		logger.error("Failed to open encode stream for \(path, privacy: .public)")
		throw FilePath.AppleArchiveError.streamOpenFailure
	}

	defer {
		do {
			try encodeStream.close()
		} catch {
			logger.debug("Failed to close encode stream for \(path, privacy: .public): \(error, privacy: .public)")
		}
	}

	let entryFilter: ArchiveHeader.EntryFilter?

	if isDirectory {
		entryFilter = nil
	} else {
		entryFilter = { (entryMessage: ArchiveHeader.EntryMessage, entryPath: FilePath, entryFilterData: ArchiveHeader.EntryFilterData?) -> ArchiveHeader.EntryMessageStatus in
			switch entryMessage {
			case .searchExclude:
				return (path.lastComponent?.description == entryPath.description) ? .ok : .skip
			default:
				return .ok
			}
		}
	}

	try encodeStream.writeDirectoryContents(
		archiveFrom: isDirectory ? path : path.appending(".."),
		keySet: .defaultForArchive,
		selectUsing: entryFilter)
}

fileprivate func _extractAppleArchive(fromArchiveByteStream stream: ArchiveByteStream, to path: FilePath) throws {
    // decoding will not spawn additional threads, so use default 0 thread count
    guard let decoderStream = ArchiveStream.decodeStream(readingFrom: stream, threadCount: 0) else {
		logger.error("Failed to open decode stream for \(path, privacy: .public)")
		throw FilePath.AppleArchiveError.streamOpenFailure
	}

	defer {
		do {
			try decoderStream.close()
		} catch {
			logger.debug("Failed to close decoder stream for \(path, privacy: .public)")
		}
	}

    // extraction will spawn additional threads, 4 is sufficient to saturate IO on production hardware
    guard let extractorStream = ArchiveStream.extractStream(extractingTo: path, threadCount: 4) else {
		logger.error("Failed to open extractor stream for \(path, privacy: .public)")
		throw FilePath.AppleArchiveError.streamOpenFailure
	}

	defer {
		do {
			try extractorStream.close()
		} catch {
			logger.debug("Failed to close extract stream for \(path, privacy: .public)")
		}
	}

	_ = try ArchiveStream.process(readingFrom: decoderStream, writingTo: extractorStream)
}
