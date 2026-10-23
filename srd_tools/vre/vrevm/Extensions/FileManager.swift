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

import Darwin
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

    // isExist returns true/false whether path exists on filesystem; if resolve set, follow symlink(s) (& possibly throw error)
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
        try? Globals.computer.fileSystem.removeItem(at: dest) // remove dest; ignore errors
        try Globals.computer.fileSystem.copyItem(at: fileURL(src), to: dest)
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

    // tryEXLock attempts to open the named file with a R/W exclusive lock and immediately close (releasing it)
    // to determine whether something else has it locked. Returns true (successfully opened with lock; nobody else
    // has it locked), false (failed to open due to existing lock), or throws an error (not accessible/exist/regfile)
    static func tryEXLock<T: Path>(_ path: T) throws -> Bool {
        let pathURL = fileURL(path)
        let fd = Darwin.open(pathURL.path, O_RDWR | O_EXLOCK | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            }

            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }

        Darwin.close(fd)
        return true
    }

    // resolveSymlinks returns final pathname after resolving any intervening symlinks;
    // (base .resolvingSymlinksInPath() method otherwise stops at final link if it doesn't go anywhere)
    // Note: requires full-disk entitlement to work outside designated user areas ?
    static func resolveSymlinks<T: Path>(_ path: T) throws -> String {
        return try _resolveSymlinks(fileURL(path)).path()
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

    // _destPath resolves (symlinks) and returns destination path; when dest is directory, append last component of src
    private static func _destPath<T: Path>(_ src: T, _ dest: T) -> URL {
        var dest = fileURL(dest)
        if isDirectory(dest.path, resolve: true) {
            let src = fileURL(src)
            dest = fileURL("\(dest.path)/\(src.lastPathComponent)")
        }

        return fileURL(dest)
    }
}
