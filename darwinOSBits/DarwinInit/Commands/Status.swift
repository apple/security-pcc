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

import ArgumentParserInternal
import Darwin
import Foundation
import Foundation_Private.NSTask
import os

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
}

final class Status: AsyncParsableCommand {
    struct Failure: Error, CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }

    static let configuration = CommandConfiguration(
        abstract: "Read status of most recent application of system config"
    )

    @Option(name: [.short, .long], help: "Output format: text (default) or json")
    var format: OutputFormat = .text

    @Flag(
        name: .shortAndLong, help: "Watch log output if status is in-progress, exit when status changes"
    )
    var watch: Bool = false

    @Flag(
        name: .shortAndLong,
        help: "Display debug messages when watching (passes '--info' and '--debug' to log stream)"
    )
    var debug: Bool = false

    func run() async throws {
        let status = try DarwinInitApplyStatus.loadBootStatus()

        // If --watch is enabled and status is in-progress, stream logs
        if watch, case .progress = status {
            try await followLogs()
            return
        }

        try printStatusAndExit(status)
    }

    private func printStatusAndExit(_ status: DarwinInitApplyStatus, prefix: String = "") throws {
        switch format {
        case .text:
            print("\(prefix)Status: \(status)")
        case .json:
            let statusOutput = try status.toJSON()

            guard let jsonString = String(data: statusOutput, encoding: .utf8) else {
                throw Failure("Unable to convert status data to UTF-8 format")
            }
            print("\(prefix)\(jsonString)")
        }

        guard case .success = status else {
            Darwin.exit(2)
        }
    }

    private func followLogs() async throws {
        // Start log streaming subprocess
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")

        var arguments = [
            "stream",
            "--predicate", "subsystem == '\(Logger.subsystem)'",
        ]

        // Add debug flags if requested
        if debug {
            arguments.append(contentsOf: ["--info", "--debug"])
        }

        process.arguments = arguments

        // Inherit stdout/stderr so logs appear in real-time
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()

        // Set signals to SIG_IGN so dispatch sources can handle them
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

        intSource.setEventHandler {
            process.terminate()
            Darwin.exit(130)
        }
        termSource.setEventHandler {
            process.terminate()
            Darwin.exit(143)
        }

        intSource.resume()
        termSource.resume()

        // Watch status file for changes
        guard let statusURL = URL(filePath: kDInitStatusFilepath) else {
            throw Failure("Invalid status file path")
        }

        let fileDescriptor = open((statusURL as NSURL).fileSystemRepresentation, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            throw Failure("Failed to open status file for monitoring")
        }

        defer {
            close(fileDescriptor)
            intSource.cancel()
            termSource.cancel()
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }

        var finalStatus = DarwinInitApplyStatus.progress(tracker: nil)
        let statusFileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .attrib],
            queue: .main
        )

        statusFileSource.setEventHandler {
            do {
                // Read status file directly to avoid debug logging noise
                let data = try Data(contentsOf: statusURL)
                let currentStatus = try JSONDecoder().decode(DarwinInitApplyStatus.self, from: data)

                // Check if status has changed from in-progress
                if case .progress = currentStatus {
                    // Still in progress, continue watching
                    return
                } else {
                    // Status changed, capture it and terminate
                    finalStatus = currentStatus
                    statusFileSource.cancel()
                    process.terminate()
                }
            } catch {
                logger.error("Failed to read status: \(error)")
                statusFileSource.cancel()
                process.terminate()
            }
        }

        statusFileSource.resume()

        // Wait for process to exit
        process.waitUntilExit()

        try printStatusAndExit(finalStatus, prefix: "\n")
    }
}
