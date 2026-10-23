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
import os

// ExecCommand provides means to synchronously execution an external command with different means of capturing output;
//  additional environment variables for the sub-command can be provided through the envvars dictionary; set clearenv
//  to true to replace the environment with that passed in, otherwise they're merged with the parent's environment when
//  passing in
struct ExecCommand {
    typealias SignalMap = [Int32: DispatchSourceSignal]

    enum OutputMode {
        /// no output captured (stdio set to nil)
        case none
        /// stdin set to nil, stdout and stderr set to original stdio of caller
        case nostdin
        /// output set to original stdio of caller
        case terminal
        /// stdout/err captured in return args; stdin set to nil
        case capture
        /// capture + terminal
        case tee
        /// stdout/err to file; stdin set to nil
        case file
    }

    static let logger = os.Logger(subsystem: applicationName, category: "ExecCommand")

    let process: Process
    private var sigMap: SignalMap = [:] // detached mode: signal handlers

    var isRunning: Bool { process.isRunning }

    init(_ command: [String],
         envvars: [String: String]? = nil,
         clearenv: Bool = false)
    {
        var command = command
        self.process = Process()
        process.qualityOfService = .userInteractive
        process.executableURL = URL(filePath: command.removeFirst())
        process.arguments = command
        if let envvars {
            // if clearenv set, replace process environment - otherwise, merge with caller's
            process.environment = clearenv ? envvars :
                ProcessInfo().environment.merging(envvars, uniquingKeysWith: { $1 })
        }
    }

    @discardableResult
    func run(outputMode: OutputMode = .none,
             outputFilePath: String? = nil, // outputMode == .file
             queue: DispatchQueue? = nil) throws ->
        (exitCode: Int32,
         stdout: String,
         stderr: String)
    {
        Self.logger.debug("Running exec command \(String(describing: process.executableURL), privacy: .public) arguments: \(process.arguments ?? [], privacy: .public)")
        let (stdoutData, stderrData) = try setOutputMode(outputMode,
                                                         outputFilePath: outputFilePath)
        var sigMap: SignalMap = [:]
        do {
            try withExtendedLifetime(sigMap) {
                if let queue {
                    setSignalHandlers(queue: queue, sigMap: &sigMap)
                }

                try process.run()
                waitUntilExit()
            }
        } catch {
            Self.logger.error("Running exec command \(String(describing: process.executableURL), privacy: .public) failed: \(error, privacy: .public)")
            throw error
        }

        return (exitCode: process.terminationStatus,
                stdout: String(decoding: stdoutData as Data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: String(decoding: stderrData as Data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    mutating func runDetached(outputMode: OutputMode = .none,
                              outputFilePath: String? = nil, // outputMode == .file
                              queue: DispatchQueue? = nil) throws
    {
        try setOutputMode(outputMode, outputFilePath: outputFilePath)

        if let queue {
            sigMap = [:]
            setSignalHandlers(queue: queue, sigMap: &sigMap)
        }

        try process.run()
    }

    func terminate() {
        process.terminate()
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    @discardableResult
    private func setOutputMode(_ outputMode: OutputMode,
                               outputFilePath: String? = nil) throws ->
        (stdoutData: NSMutableData,
         stderrData: NSMutableData)
    {
        let stdoutData = NSMutableData()
        let stderrData = NSMutableData()

        switch outputMode {
        case .none:
            process.standardInput = nil
            process.standardOutput = nil
            process.standardError = nil
        case .nostdin:
            process.standardInput = nil
            // default stdout/stderr configuration
            break
        case .capture, .tee:
            process.standardInput = nil
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = {
                let data = $0.availableData

                guard !data.isEmpty else {
                    $0.readabilityHandler = nil
                    return
                }

                stdoutData.append(data)
                if outputMode == .tee {
                    fputs(String(decoding: data, as: UTF8.self), stdout)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = {
                let data = $0.availableData

                guard !data.isEmpty else {
                    $0.readabilityHandler = nil
                    return
                }

                stderrData.append(data)
                if outputMode == .tee {
                    fputs(String(decoding: data, as: UTF8.self), stderr)
                }
            }

        case .file:
            process.standardInput = nil
            if let outputFilePath {
                let outputFileURL = URL(filePath: outputFilePath)
                Globals.computer.fileSystem.createFile(atPath: outputFilePath, contents: nil)
                let outputFile = try FileHandle(forWritingTo: outputFileURL)
                process.standardOutput = outputFile
                process.standardError = outputFile
            } else {
                process.standardOutput = nil
                process.standardError = nil
            }

        case .terminal:
            // standard stdin/out/err configuration - leave them be
            break
        }

        return (stdoutData: stdoutData, stderrData: stderrData)
    }

    private func setSignalHandlers(queue: DispatchQueue,
                                   sigMap: inout SignalMap,
                                   signals: [Int32] = [SIGHUP, SIGINT, SIGQUIT, SIGTERM])
    {
        let process = self.process
        for sigVal in signals {
            signal(sigVal, SIG_IGN)
            sigMap[sigVal] = DispatchSource.makeSignalSource(signal: sigVal, queue: queue)
            sigMap[sigVal]!.setEventHandler { process.terminate() }
            sigMap[sigVal]!.resume()
        }
    }
}
