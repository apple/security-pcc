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
//  FileSystem.swift
//  darwinOSBits
//
//

import Foundation
import Darwin
import System


// MARK: Protocol

protocol FileSystem {

    func fileStat(at path: FilePath) throws -> FileStat?

    func chown(_ path: FilePath, owner: uid_t, group: gid_t) throws
    func chmod(_ path: FilePath, permissions: FilePermissions) throws

    func touch(_ path: FilePath, permissions: FilePermissions) throws

    func mkdir(_ path: FilePath, permissions: FilePermissions) throws

    func mkdirs(_ path: FilePath, permissions: FilePermissions) throws

    func open(_ path: FilePath,
              _ mode: FileDescriptor.AccessMode,
              options: FileDescriptor.OpenOptions,
              permissions: FilePermissions?,
              retryOnInterrupt: Bool) throws -> FileDescriptor
}

// MARK: Default implementations
extension FileSystem {
    func fileExists(at path: FilePath) throws -> Bool {
        guard let fs = try fileStat(at: path) else {
            return false
        }
        return fs.isRegularFile
    }

    /// Waits with a timeout for an item to exist at the provided path. This can be useful in a sumac bringup.
    ///
    /// - Parameter path: Path on filesystem to wait on.
    /// - Parameter timeout: Timeout in seconds.
    /// - Returns: `true` if the item was found and `false` otherwise.
    func exists(path: FilePath, withTimeout timeout: Int) -> Bool {
        path.exists(withTimeout: timeout)
    }

    func directoryExists(at path: FilePath) throws -> Bool {
        guard let fs = try fileStat(at: path) else {
            return false
        }
        return fs.isDirectory
    }

    func touch(_ path: FilePath, permissions: FilePermissions) throws {
        logger.debug("Creating file at \(path) with permissions \(permissions)")
        try open(path, .writeOnly,
                 options: [.create],
                 permissions: permissions,
                 retryOnInterrupt: true
        ).close()
    }

    func truncate(_ path: FilePath, at offset: UInt64 = 0, permissions: FilePermissions = .fileDefault) throws {
        logger.debug("Truncating file at \(path) at offset \(offset)")

        let fd = try open(path, .writeOnly,
                          options: [.create],
                          permissions: permissions,
                          retryOnInterrupt: true)


        try fd.closeAfter {
            try nothingOrErrno(retryOnInterrupt: true) {
                ftruncate(fd.rawValue, off_t(offset))
            }.get()
        }
    }

    func touch(_ path: FilePath) throws {
        try self.touch(path, permissions: .fileDefault)
    }

    func mkdir(_ path: FilePath) throws {
        try self.mkdir(path, permissions: .directoryDefault)
    }

    func mkdirs(_ path: FilePath) throws {
        try self.mkdirs(path, permissions: .directoryDefault)
    }

    func open(appending path: FilePath) throws -> FileDescriptor {
        try self.open(path, .writeOnly,
                      options: [.create, .append, .closeOnExec],
                      permissions: .fileDefault,
                      retryOnInterrupt: true)
    }

    func write(json: some Encodable, to path: FilePath, redacted: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        encoder.userInfo[CredentialString.redactionOverrideKey] = !redacted
        let data = try encoder.encode(json)
        let fd = try self.open(path, .writeOnly, options: [.truncate, .create],
                               permissions: .fileDefault, retryOnInterrupt: true)
        try fd.closeAfter {
            _ = try data.withUnsafeBytes { buffer in
                try fd.write(buffer)
            }
        }
    }

    func write(text: String, to path: FilePath) throws {
        let fd = try self.open(path, .writeOnly, options: [.truncate, .create],
                               permissions: .fileDefault, retryOnInterrupt: true)
        _ = try fd.closeAfter {
            try fd.writeAll(text.utf8)
        }
    }

    func append(text: String, to path: FilePath) throws {
        let fd = try self.open(appending: path)
        _ = try fd.closeAfter {
            try fd.writeAll(text.utf8)
        }
    }

    func readData(from path: FilePath) throws -> Data {

        let fd = try self.open(path, .readOnly,
                               options: [.closeOnExec],
                               permissions: .fileDefault,
                               retryOnInterrupt: true)

        return try fd.closeAfter {
            var statbuf = Darwin.stat()
            try nothingOrErrno(retryOnInterrupt: true) {
                fstat(fd.rawValue, &statbuf)
            }.get()
            var data = Data(count: Int(statbuf.st_size))
            _ = try data.withUnsafeMutableBytes { buf in
                try fd.read(into: buf)
            }
            return data
        }
    }

    func readJson<T>(_ type: T.Type, from path: FilePath) throws -> T where T: Decodable {
        let decoder = JSONDecoder()
        let data = try readData(from: path)
        return try decoder.decode(type, from: data)
    }

    func readText(from path: FilePath, encoding: String.Encoding = .utf8) throws -> String {
        let data = try self.readData(from: path)
        guard let str = String(data: data, encoding: encoding) else {
            throw Errno.invalidArgument
        }
        return str
    }
}

// MARK: Real File System
open class RealFileSystem: FileSystem {

    static let shared = RealFileSystem()

    func fileStat(at path: FilePath) throws -> FileStat? {
        var statbuf = Darwin.stat()
        do {
            try path.withPlatformString { platformString in
                try nothingOrErrno(retryOnInterrupt: true) {
                    stat(platformString, &statbuf)
                }.get()
            }
        } catch Errno.noSuchFileOrDirectory {
            return nil
        }

        return FileStat(rawValue: statbuf)
    }

    func pathExists(_ path: FilePath) throws -> Bool {
        return try path.exists()
    }

    func fileExists(at path: FilePath) throws -> Bool {
        return try path.fileExists()
    }

    func directoryExists(at path: FilePath) throws -> Bool {
        return try path.directoryExists()
    }

    func chown(_ path: FilePath, owner: uid_t, group: gid_t) throws {
        try path.chown(owner: owner, group: group)
    }

    func chmod(_ path: FilePath, permissions: FilePermissions) throws {
        try path.chmod(permissions: permissions)
    }

    func mkdir(_ path: FilePath, permissions: FilePermissions) throws {
        logger.debug("Creating directory at \(path) with permissions \(permissions)")
        try nothingOrErrno(retryOnInterrupt: true) {
            path.withPlatformString { buf in
                Darwin.mkdir(buf, permissions.rawValue)
            }
        }.get()
    }

    func mkdirs(_ path: FilePath, permissions: FilePermissions) throws {
        // TODO: move implemention here
        try path.createDirectory(permissions: permissions, intermediateDirectories: true)
    }

    func open(_ path: FilePath,
              _ mode: FileDescriptor.AccessMode,
              options: FileDescriptor.OpenOptions,
              permissions: FilePermissions?,
              retryOnInterrupt retry: Bool) throws -> FileDescriptor {
        logger.debug("Opening FileDescriptor at \(path), mode: \(mode)")
        return try FileDescriptor.open(path,
                                       mode,
                                       options: options,
                                       permissions: permissions,
                                       retryOnInterrupt: retry)
    }

    func fopen(_ path: FilePath, mode: String) throws -> UnsafeMutablePointer<FILE> {
        logger.debug("Opening FILE at \(path), mode: \(mode)")
        let res = path.withPlatformString { rawPath in
            mode.withCString { rawMode  in
                Darwin.fopen(rawPath, rawMode)
            }
        }
        guard let res else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? POSIXErrorCode.EIO)
        }
        return res
    }
}
