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
//  FilePath+Archive.swift
//  DarwinInit
//

import System
internal import DarwinInitBridging

extension FilePath {
    private enum ArchiveError: Error {
        case endOfArchive
        case unknown(String?)
        case warning(String?)
        case failed(String?)
        case fatal(String?)
    }

    private func call(_ archive: OpaquePointer?, _ function: (OpaquePointer?) -> Int32) throws {
        func errorString(archive: OpaquePointer?) -> String? {
            guard let cSstr = archive_error_string(archive) else {
                logger.error("archive_errno(\(archive_errno(archive)))")
                return nil
            }
            logger.error("archive_errno(\(archive_errno(archive))) archive_error_string(\(String(cString: cSstr), privacy: .public))")
            return String(cString: cSstr)
        }

        while true {
            switch function(archive) {
            case ARCHIVE_EOF: throw ArchiveError.endOfArchive
            case ARCHIVE_OK: return
            case ARCHIVE_RETRY: continue
            case ARCHIVE_WARN: throw ArchiveError.warning(errorString(archive: archive))
            case ARCHIVE_FAILED: throw ArchiveError.failed(errorString(archive: archive))
            case ARCHIVE_FATAL: throw ArchiveError.fatal(errorString(archive: archive))
            default: throw ArchiveError.unknown(errorString(archive: archive))
            }
        }
    }

    private func copyData(from input: OpaquePointer?, to output: OpaquePointer?) throws {
        var buffer: UnsafeRawPointer?
        var size = 0
        var offset: Int64 = 0

        do {
            while true {
                try call(input) { archive_read_data_block($0, &buffer, &size, &offset) }
                try call(output) { Int32(archive_write_data_block($0, buffer, size, offset)) }
            }
        } catch ArchiveError.endOfArchive { }
    }

    func extractUsingLibarchive(to path: FilePath) throws {
        logger.debug("Extracting item at \(self) into \(path)")

        let archive = archive_read_new()
        defer { try? call(archive) { archive_read_free($0) } }
        try call(archive) { archive_read_support_filter_all($0) }
        try call(archive) { archive_read_support_format_all($0) }
        try call(archive) { archive_read_open_filename($0, self.description, 10_240) }

        let extract = archive_write_disk_new()
        defer { try? call(extract) { archive_write_free($0) } }
        let options =
        ARCHIVE_EXTRACT_TIME |
        ARCHIVE_EXTRACT_PERM |
        ARCHIVE_EXTRACT_ACL |
        ARCHIVE_EXTRACT_FFLAGS |
        ARCHIVE_EXTRACT_NO_OVERWRITE |
        ARCHIVE_EXTRACT_SECURE_NODOTDOT |
        ARCHIVE_EXTRACT_SECURE_SYMLINKS
        // * Don't use ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS as we set absolute
        //   paths using archive_entry_set_pathname() below.
        // * ARCHIVE_EXTRACT_SECURE_SYMLINKS requires output path to be inside
        //   realpath /private/var and not symlink /var .
        
        try call(extract) { archive_write_disk_set_options($0, options) }
        try call(extract) { archive_write_disk_set_standard_lookup($0) }

        do {
            while true {
                var entry: OpaquePointer?
                try call(archive) { archive_read_next_header($0, &entry) }
                defer { try? call(extract) { archive_write_finish_entry($0) } }

                if archive_entry_hardlink(entry) != nil {
                    logger.error("Extraction of archives with hardlinks is not permitted - rejecting")
                    throw ArchiveError.failed("Hardlink entries are not permitted")
                }

                // skip entry if it has no pathname
                guard let cStr = archive_entry_pathname(entry) else { continue }
                let str = String(cString: cStr)

                // update entry pathname relative to output directory
                let pathname = path.appending(str)
                archive_entry_set_pathname(entry, pathname.description)

                try call(extract) { archive_write_header($0, entry) }

                if archive_entry_size(entry) > 0 {
                    try copyData(from: archive, to: extract)
                }
            }
        } catch ArchiveError.endOfArchive { }
    }

    func extract(to path: FilePath, using aeaDecryptionParameters: AEADecryptionParameters?) throws {
        logger.log("Extracting \(self) to \(path)")
        
        let archiveMagic: FilePath.ArchiveType?
        
        do {
            archiveMagic = try self.readArchiveMagic()
        } catch {
            logger.error("Failed to read archive magic for \(self): \(error)")
            throw error
        }
        
        do {
            switch archiveMagic {
            case .UncompressedAppleArchive:
                try self.extractUncompressedAppleArchive(to: path)
            case .AppleEncryptedArchive:
                guard let aeaDecryptionParameters = aeaDecryptionParameters else {
                    logger.error("AEA decryption parameters unset for Apple Encrypted Archive. Unable to extract.")
                    throw Errno.invalidArgument
                }
                try self.extractAppleEncryptedArchive(
                    to: path,
                    using: aeaDecryptionParameters.decryptionKey,
                    expectingArchiveIdentifier: aeaDecryptionParameters.archiveID)
            default:
                try self.extractUsingLibarchive(to: path)
            }
        } catch {
            logger.log("Failed to extract: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        
        if (try? path.directoryExists()) != true {
            logger.warning("Nothing extracted to \(path, privacy: .public)")
        }
        
        logger.log("Successfully extracted to \(path)")
        
        do {
            let extractedContents = try path.performDeepEnumerationOfFiles()
            logger.info("Extracted \(self) with contents: \(extractedContents)")
        } catch {
            logger.error("Failed to enumerate the contents of \(path): \(error)")
        }
    }
}
