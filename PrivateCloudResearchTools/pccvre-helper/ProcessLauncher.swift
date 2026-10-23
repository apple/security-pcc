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

//  Copyright © 2025 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import Foundation

class ProcessLauncher {
    func exec(executablePath: String, arguments: [String], extraEnvvars: [String: String] = [:], queue: DispatchQueue? = nil) throws -> Int32 {
        logExec(executablePath: executablePath, arguments: arguments, extraEnvvars: extraEnvvars)

        let execCommand = ExecCommand([executablePath] + arguments, envvars: extraEnvvars)
        return try execCommand.run(outputMode: .terminal, queue: queue).exitCode
    }

    func exec(executablePath: String, arguments: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        logExec(executablePath: executablePath, arguments: arguments)

        let execCommand = ExecCommand([executablePath] + arguments)
        return try execCommand.run(outputMode: .capture)
    }

    func exec(executablePath: String, arguments: [String], queue: DispatchQueue, block: @escaping ExecCommand.CaptureBlock) throws -> Int32 {
        logExec(executablePath: executablePath, arguments: arguments)

        let execCommand = ExecCommand([executablePath] + arguments)
        return try execCommand.run(outputMode: .capture, queue: queue, block: block).exitCode
    }

    func logExec(executablePath: String, arguments: [String], extraEnvvars: [String: String] = [:]) {
        var command = ""
        for envvar in extraEnvvars {
            command += "\(envvar.key)=\(envvar.value) "
        }
        command += executablePath
        for arg in arguments {
            command += " \(arg)"
        }

        CLI.debugPrint(command)
    }
}

/// Exec an external command with different ways of capturing the output, and handle Ctrl+C / interruption.
struct ExecCommand {
    typealias SignalMap = [Int32: DispatchSourceSignal]
    typealias CaptureBlock = (NSMutableData) -> Void

    enum OutputMode {
        case none // no output captured (stdio set to nil)
        case terminal // output set to original stdio of caller
        case capture // stdout/err captured in return args; stdin set to nil
        case tee // capture + terminal
        case file // stdout/err to file; stdin set to nil
    }

    let process: Process
    private var sigMap: SignalMap = [:] // detached mode: signal handlers

    var isRunning: Bool { process.isRunning }

    /// `envvars` are merged with the caller's environment variables by default, set `clearenv` to replace them instead.
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
             queue: DispatchQueue? = nil,
             block: CaptureBlock? = nil) throws ->
        (exitCode: Int32,
         stdout: String,
         stderr: String)
    {
        let (stdoutData, stderrData) = try setOutputMode(outputMode,
                                                         outputFilePath: outputFilePath,
                                                         block: block)
        var sigMap: SignalMap = [:]
        try withExtendedLifetime(sigMap) {
            setSignalHandlers(queue: queue ?? DispatchQueue.global(), sigMap: &sigMap)

            try process.run()
            waitUntilExit()
        }

        return (exitCode: process.terminationStatus,
                stdout: String(decoding: stdoutData as Data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: String(decoding: stderrData as Data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func terminate() {
        process.terminate()
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    @discardableResult
    private func setOutputMode(_ outputMode: OutputMode,
                               outputFilePath: String? = nil,
                               block: CaptureBlock? = nil) throws ->
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
                block?(stdoutData)
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
                block?(stderrData)
                if outputMode == .tee {
                    fputs(String(decoding: data, as: UTF8.self), stderr)
                }
            }

        case .file:
            process.standardInput = nil
            if let outputFilePath {
                let outputFileURL = URL(filePath: outputFilePath)
                FileManager.default.createFile(atPath: outputFilePath, contents: nil)
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
