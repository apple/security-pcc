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
//  Subprocess.swift
//  darwin-init
//

import Foundation
import os
import System
internal import DarwinInitBridging

/// `CStringArray` represents a C null-terminated array of pointers to C strings.
///
/// The lifetime of the C strings will correspond to the lifetime of the `CStringArray`
/// instance so be careful about copying the buffer as it may contain dangling pointers.
final class CStringArray {
    /// The null-terminated array of C string pointers.
    var cArray: [UnsafeMutablePointer<Int8>?]

    /// Creates an instance from an array of strings.
    init<S>(_ sequence: S) where S: Sequence, S.Element: StringProtocol {
        cArray = sequence.map({ $0.withCString({ strdup($0) }) }) + [nil]
    }

    deinit {
        for case let element? in cArray {
            free(element)
        }
    }
}

struct NonZeroExit: Error {
    let executable: URL
    let arguments: [String]
    let exitCode: CInt
    let error: String
    let output: String
}

extension NonZeroExit: LocalizedError {
    var errorDescription: String? {
        var components = [executable.lastPathComponent]
        components.append(contentsOf: arguments)
        return "subprocess '\(components.joined(separator: " "))' returned nonzero exit code \(exitCode), \(error)"
    }
}

enum Subprocess {
    private static func tempDir() -> FilePath {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(PATH_MAX))
        defer {
            buffer.deallocate()
        }
        
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, buffer, Int(PATH_MAX))
        guard size != 0 else {
            Logger.subprocess.error("confstr: \(Errno.current)")
            
            // if `confstr` fails, returns a default temporary folder that guaranteed to exist on all platforms
            return FilePath("/private/var/tmp")
        }
        return FilePath(String(cString: buffer, encoding: .utf8)!)
    }
    
    @discardableResult
    static func run(executable: URL, arguments: [CustomStringConvertible]) throws -> String {
        var components = [executable.lastPathComponent]
        components.append(contentsOf: arguments.map(\.description))
        Logger.subprocess.debug("running subprocess \(components.joined(separator: " "))")
        let process = Process()
        let errorPipe = Pipe()
        let outputPipe = Pipe()

        process.standardError = errorPipe
        process.standardOutput = outputPipe
        process.executableURL = executable
        process.arguments = arguments.map(\.description)

#if os(iOS)
        process.launch()
#else
        try process.run()
#endif

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

        let error = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        process.waitUntilExit()
        let status = process.terminationStatus
        guard status == 0 else {
            throw NonZeroExit(
                executable: executable,
                arguments: arguments.map(\.description),
                exitCode: status,
                error: error,
                output: output)
        }

        return output
    }

    /// Runs a command and logs the results.
    ///
    /// - Parameter shell: A `String` containing full path to the shell binary
    ///   if not provided the command will be executed directly.
    /// - Parameter command: If `shell` isn't specified, command is a `String`
    ///   containing the command and arguments separated by space. The command
    ///   must be fully qualified and the arguments must not contain any shell
    ///   expansion characters (such as tilde "~"). However, if `shell` is
    ///   specified, the command is fully interpreted by the shell, with all of
    ///   the usual semantics of the shell.
    /// - Parameter path: An optional path where the standard output should be saved.
    /// - Returns: `true` if the command was successful, `false` if it either
    ///   threw an exception or returned a non zero return code.
    ///
    /// Runs a command by breaking up the arguments, capturing both stdout and
    /// stderr and checking the result. Logs are created for the command that is
    /// run and the result. This only returns success or failure. No reasons are
    /// returned, but all cases are logged.
    ///
    /// The command is executed at a higher privilege than normal root
    /// tasks because of the `com.apple.private.security.storage-exempt.heritable`
    /// entitlement.
    static func run(shell: String?, command: String, savingStandardOutTo path: FilePath? = nil) -> Bool {
        // Break out the arguments
        let arguments: [String] = {
            // If shell is specified, don't parse the command/script manually
            if let shell = shell {
                return [shell, "-c", command]
            } else {
                return command
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .map {String($0)}
            }
        }()
        logger.log("Running: \(arguments)")
        
        // Clean off existing files (if any)
        let stdoutFile = path ?? tempDir().appending("darwin_init_stdout")
        let stderrFile = tempDir().appending("darwin_init_stderr")
        try? stdoutFile.remove()
        try? stderrFile.remove()

        // Convert the arguments to array of C strings
        let argv = CStringArray(arguments)

        // Set up the files for the process to write
        var fileActions: posix_spawn_file_actions_t?
        var returnCode = posix_spawn_file_actions_init(&fileActions)
        guard returnCode == 0 else {
            logger.error("posix_spawn_file_actions_init failed with error: \(returnCode)")
            return false
        }

        returnCode = posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, stdoutFile.description, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard returnCode == 0 else {
            logger.error("posix_spawn_file_actions_addopen \(STDOUT_FILENO) failed with error: \(returnCode)")
            return false
        }

        returnCode = posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, stderrFile.description, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard returnCode == 0 else {
            logger.error("posix_spawn_file_actions_addopen \(STDERR_FILENO) failed with error: \(returnCode)")
            return false
        }

        // Spawn the process and wait for completion
        var pid: pid_t = -1
        returnCode = posix_spawn(&pid, argv.cArray[0], &fileActions, nil, argv.cArray, environ)
        guard returnCode == 0 else {
            logger.error("posix_spawn failed with return code \(returnCode)")
            return false
        }
        
        var status: Int32 = 0
        let waitPidStatus = valueOrErrno(retryOnInterrupt: true) {
            waitpid(pid, &status, 0)
        }
        
        switch waitPidStatus {
        case .success(let outPid):
            if pid != outPid {
                return false
            }
        case .failure(let errnoValue):
            logger.error("waitpid failed with error: \(errnoValue)")
            return false
        }

        // get and log the stdout if the program is not looking at it.
        if path == nil {
            do {
                let stdoutStr = try stdoutFile.loadString()
                if !stdoutStr.isEmpty {
                    logger.log("\(arguments[0]) stdout:\n\(stdoutStr)")
                }
            } catch {
                logger.error("Read of stdout failed with error: \(error.localizedDescription)")
                return false
            }
        }

        // get and log stderr
        do {
            let stderrStr = try stderrFile.loadString()
            if !stderrStr.isEmpty {
                logger.log("\(arguments[0]) stderr:\n\(stderrStr)")
            }
        } catch {
            logger.error("Read of stderr failed with error: \(error.localizedDescription)")
            return false
        }

        // figure out what happened
        if shim_WIFSIGNALED(status) { // did the process signal?
            logger.error("Process signalled \(shim_WTERMSIG(status))")
            return false
        } else if shim_WIFEXITED(status) { // did the process exit?
            let returnCode = shim_WEXITSTATUS(status)
            if returnCode != 0 {
                logger.error("Process exited with return code \(returnCode)")
                return false
            }
        } else {
            logger.error("\(arguments[0]) internal error, do not know why the process stopped")
            return false
        }

        return true
    }
}
