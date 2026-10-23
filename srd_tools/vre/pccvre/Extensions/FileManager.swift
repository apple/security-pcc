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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import Foundation

// Useful extensions to FileManager for identifying files / dirs / symlinks

extension FileManager {
    typealias Path = CustomStringConvertible

    static func fileURL<T: Path>(_ path: T) -> URL {
        guard let url = path as? URL, url.isFileURL else {
            return URL(fileURLWithPath: path.description)
        }
        return url
    }

    static func fullyQualified<T: Path>(
        _ path: T,
        relative: String? = nil,
        resolve: Bool = false
    ) throws -> URL {
        if FileManager.isExist(path) || relative == nil {
            // pathname exists, return fully-qualified form
            return resolve ? try resolveSymlinks(path) : fileURL(path)
        }

        // otherwise, attempt to prepend relative path
        let _path: String = if let _pathURL = path as? URL { _pathURL.relativePath } else { path.description }
        let pathURL = URL(string: _path, relativeTo: fileURL(relative!)) ?? fileURL(path)
        return resolve ? try resolveSymlinks(pathURL) : pathURL
    }

    // tempDirectory returns fileURL of private temporary directory based on NSTemporaryDirectory();
    //  optional subPath items may be provided to create underneath (e.g. Application name, uuid).
    // The directory is created as necessary is not an error if already exists
    static func tempDirectory(subPath: String...) throws -> URL {
        var tmpdir = Globals.computer.fileSystem.temporaryDirectory
        for sub in subPath {
            tmpdir.append(path: sub)
        }

        try Globals.computer.fileSystem.createDirectory(
            at: tmpdir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o0700]
        )

        return tmpdir
    }

    // spillToTempFile writes `data` to a UUID-named file under the application
    // temp directory and returns its URL. Callers are responsible for cleanup.
    // Consolidates the open-coded `tempDirectory(...).appendingPathComponent(UUID())`
    // + `data.write` pattern used by the helper subprocess wrappers.
    static func spillToTempFile(_ data: Data, prefix: String = "input") throws -> URL {
        let url = try tempDirectory(subPath: applicationName)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    // isExist returns true/false whether path exists on filesystem;
    //   if resolve set, follow symlink(s) (& possibly throw error)
    static func isExist<T: Path>(_ path: T, resolve: Bool = false) -> Bool {
        var pathURL = fileURL(path)
        do {
            if resolve {
                pathURL = try _resolveSymlinks(pathURL)
            }

            return Globals.computer.fileSystem.fileExists(atPath: pathURL.path)
        } catch {
            return false
        }
    }

    // isRegularFile returns true/false whether path exists and as a regular file;
    //  if resolve set, follow symlink(s) & throw error if destination doesn't ultimately exist
    static func isRegularFile<T: Path>(_ path: T, resolve: Bool = false) -> Bool {
        var pathURL = fileURL(path)
        do {
            if resolve {
                pathURL = try _resolveSymlinks(pathURL)
            }
            return Globals.computer.fileSystem.isRegularFile(at: pathURL)
        } catch {
            return false
        }
    }

    // isDirectory returns true/false whether path exists and as a directory;
    //  if resolve set, follow symlink(s) & throw error if destination doesn't ultimately exist
    static func isDirectory<T: Path>(_ path: T, resolve: Bool = false) -> Bool {
        var pathURL = fileURL(path)

        do {
            if resolve {
                pathURL = try _resolveSymlinks(pathURL)
            }
            return Globals.computer.fileSystem.isDirectory(at: pathURL)
        } catch {
            return false
        }
    }

    // isExecutable returns true if path appears to be executable
    static func isExecutable<T: Path>(_ path: T) -> Bool {
        let path = fileURL(path)
        return Globals.computer.fileSystem.isExecutableFile(atPath: path.path)
    }

    // isWritableDirectory returns true if path exists as directory and is writable by caller
    static func isWritableDirectory<T: Path>(_ path: T) -> Bool {
        let path = fileURL(path)
        if isDirectory(path.path) {
            return Globals.computer.fileSystem.isWritableFile(atPath: path.path)
        }

        return false
    }

    // isSymlink returns true/false whether path exists and as a symlink
    static func isSymlink<T: Path>(_ path: T) -> Bool {
        let pathURL = fileURL(path)
        return Globals.computer.fileSystem.isSymbolicLink(at: pathURL)
    }

    // copyFile copies src to dest
    // - if dest is directory, update with final src path component
    @discardableResult
    static func copyFile<T: Path>(_ src: T, _ dest: T) throws -> URL {
        let dest = fileURL(_destPath(src, dest))
        try Globals.computer.fileSystem.copyItem(at: resolveSymlinks(src), to: dest)
        return fileURL(dest)
    }

    // linkFile attempts to hardlink src to dest
    // - if dest is directory, update with final src path component
    // - if hard link fails (different f/s) then copy
    @discardableResult
    static func linkFile<T: Path>(_ src: T, _ dest: T) throws -> URL {
        let dest = fileURL(_destPath(src, dest))
        do {
            try Globals.computer.fileSystem.linkItem(at: resolveSymlinks(src), to: dest)
        } catch {
            try Globals.computer.fileSystem.copyItem(at: resolveSymlinks(src), to: dest)
        }

        return fileURL(dest)
    }

    // moveFile copies src to dest; returns destination path
    // - if dest is directory, update with final src path component
    // - if dest exists, attempt to remove it first
    @discardableResult
    static func moveFile<T: Path>(_ src: T, _ dest: T) throws -> URL {
        let dest = fileURL(_destPath(src, dest))

        try? Globals.computer.fileSystem.removeItem(at: dest) // remove dest; ignore errors

        try Globals.computer.fileSystem.moveItem(at: fileURL(src), to: dest)
        return fileURL(dest)
    }

    // resolveSymlinks returns final pathname after resolving any intervening symlinks;
    //  (base .resolvingSymlinksInPath() method otherwise stops at final link if it doesn't go anywhere)
    static func resolveSymlinks<T: Path>(_ path: T) throws -> URL {
        return try _resolveSymlinks(fileURL(path))
    }

    private static func _resolveSymlinks(_ path: URL) throws -> URL {
        var path = path
        let info: URLResourceValues?
        do {
            _ = try path.checkResourceIsReachable()
            info = try? path.resourceValues(forKeys: [.isSymbolicLinkKey])
        } catch {
            throw POSIXError(.ENOENT)
        }

        if let islink = info?.isSymbolicLink, islink {
            let dest = path.resolvingSymlinksInPath()
            guard dest != path else {
                // couldn't resolve symlink (just returns itself)
                throw POSIXError(.ENOENT)
            }
            path = dest
        }

        return path
    }

    // _destPath resolves (symlinks) and returns destination path; when dest is directory,
    //   append last component of src
    private static func _destPath<T: Path>(_ src: T, _ dest: T) -> URL {
        var dest = fileURL(dest)
        if isDirectory(dest.path, resolve: true) {
            dest = fileURL(dest.path).appending(path: fileURL(src).lastPathComponent)
        }

        return fileURL(dest)
    }
}
