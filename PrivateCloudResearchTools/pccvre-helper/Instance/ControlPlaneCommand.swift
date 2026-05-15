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

//  Copyright © 2025 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import Foundation

struct ControlPlaneCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "control-plane",
        abstract: "Invoke control plane commands to manipulate services.",
        subcommands: [
            ControlPlaneShowCommand.self,
            ControlPlaneServerCommand.self,
            ControlPlaneRawServerCommand.self,
            ControlPlaneSetupCommand.self,
            ControlPlaneSendCommand.self,
        ],
    )

    @OptionGroup
    var options: InstanceCommand.Options
}

struct ControlPlaneShowCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show control plane agent configurations.",
    )

    @OptionGroup
    var options: InstanceCommand.Options

    func run() throws {
        let config = try ControlPlaneServerConfig(instance: options.instanceName)
        print("Control plane agent is set up for \(config.ServiceURL).")
    }
}

struct ControlPlaneSetupCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up the control plane agent.",
    )

    @OptionGroup
    var options: InstanceCommand.Options

    @Option(help: "Control plane agent port.")
    var port: Int

    @Option(help: "Control plane agent polling interval in seconds.")
    var interval: Int = 5

    func hostname(launcher: ProcessLauncher) throws -> String {
        let arguments = ["show", "ip-address", "--name", options.instanceName]
        let result = try launcher.exec(executablePath: CLI.vrevmPath, arguments: arguments)
        let address = result.stdout.split(separator: ".")

        guard address.count == 4 else {
            throw CLIError("Instance '\(options.instanceName)' has no IP address configured. Please try again after the instance is up.")
        }

        // The host should be listening at ".1"
        var parts = address.dropLast()
        parts.append("1")
        return parts.joined(separator: ".")
    }

    func run() throws {
        let launcher = ProcessLauncher()
        var config = try DarwinInitConfig(launcher: launcher, instance: options.instanceName)
        let controlPlaneConfig = try ControlPlaneServerConfig(
            hostname: try hostname(launcher: launcher),
            port: port,
            interval: interval).dictionary()

        var secureConfig = config.dictionary[ControlPlaneServerConfig.Keys.secureConfig] as? [String: Any] ?? [:]
        secureConfig[ControlPlaneServerConfig.Keys.controlPlane] = controlPlaneConfig

        config.dictionary[ControlPlaneServerConfig.Keys.secureConfig] = secureConfig
        try config.save(launcher: launcher, instance: options.instanceName)
        print("Setup done. Please restart the instance '\(options.instanceName)' to take effect.")
    }
}

struct ControlPlaneSendCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send commands to control plane agent.",

        subcommands: [
            ControlPlaneSendInitCommand.self,
            ControlPlaneSendDeactivateCommand.self,
            ControlPlaneSendApplyCommand.self,
            ControlPlaneSendActivateCommand.self,
            ControlPlaneSendModelSwitchCommand.self,
            ControlPlaneSendRawCommand.self,
        ],
    )

    struct ControlPlaneSendInitCommand: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "init",
            abstract: "The initialize command."
        )

        @OptionGroup
        var options: InstanceCommand.Options

        @Option(help: "Target service.")
        var service: String = ControlPlaneAgentCommand.DefaultService

        func run() throws {
            try ControlPlaneAgentCommand.send(
                type: .initialize,
                service: service,
                instance: options.instanceName)
        }
    }

    struct ControlPlaneSendDeactivateCommand: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "deactivate",
            abstract: "The deactivate command."
        )

        @OptionGroup
        var options: InstanceCommand.Options

        @Option(help: "Target service.")
        var service: String = ControlPlaneAgentCommand.DefaultService

        func run() throws {
            try ControlPlaneAgentCommand.send(
                type: .deactivate,
                service: service,
                instance: options.instanceName)
        }
    }

    struct ControlPlaneSendApplyCommand: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "apply",
            abstract: "The apply command."
        )

        @OptionGroup
        var options: InstanceCommand.Options

        @Option(help: "Property key.")
        var key: String

        @Option(help: "Property value.")
        var value: String

        @Option(help: "Target service.")
        var service: String = ControlPlaneAgentCommand.DefaultService

        func run() throws {
            try ControlPlaneAgentCommand.send(
                type: .applyProperty(key: key, value: value),
                service: service,
                instance: options.instanceName)
        }
    }

    struct ControlPlaneSendActivateCommand: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "activate",
            abstract: "The activate command."
        )

        @OptionGroup
        var options: InstanceCommand.Options

        @Option(help: "Target service.")
        var service: String = ControlPlaneAgentCommand.DefaultService

        func run() throws {
            try ControlPlaneAgentCommand.send(
                type: .activate,
                service: service,
                instance: options.instanceName)
        }
    }

    struct ControlPlaneSendModelSwitchCommand: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "model-switch",
            abstract: "The model switch command."
        )

        @OptionGroup
        var options: InstanceCommand.Options

        @Option(name: [.long, .short], help: "The model to switch to.")
        var model: [String] = ["com.apple.fm.language.research.adapter#cv10"]

        @Option(name: [.long, .short], help: "The model version.")
        var version: Int = 10

        func run() throws {
            let command = ControlPlaneAgentCommand.ModelSwitch(
                defaultBaseModelVersionMap: [:],
                inferenceIDsToActivate: model,
                distributionName: "pccvre-helper")

            try ControlPlaneAgentCommand.send(
                type: .applyProperty(
                    key: ControlPlaneAgentCommand.ModelSwitch.Key,
                    value: try command.json()),
                service: ControlPlaneAgentCommand.DefaultService,
                instance: options.instanceName)
        }
    }

    struct ControlPlaneSendRawCommand: ParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "raw",
            abstract: "A custom command using raw JSON."
        )

        @OptionGroup
        var options: InstanceCommand.Options

        @Option(help: "The raw command value.")
        var value: String

        func run() throws {
            try ControlPlaneAgentCommand.send(
                content: value,
                instance: options.instanceName)
        }
    }
}

struct ControlPlaneServerCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Start the control plane test server.",
    )

    @OptionGroup
    var options: InstanceCommand.Options

    @Flag(help: "Show verbose logs from the test server")
    var verbose: Bool = false

    @Flag(help: "Pass through raw messages from the test server")
    var raw: Bool = false

    func updateAndLogStatus(current raw: [String], last: ControlPlaneAgentStatus?) -> ControlPlaneAgentStatus? {
        let status = raw.joined(separator: "\n")
        guard let current = try? ControlPlaneAgentStatus(from: status) else {
            if verbose {
                print("Raw status: \(status)")
            }
            return nil
        }

        if current != last {
            var status = current
            if current.propertyStatusOnly == last?.propertyStatusOnly {
                status = current.stateOnly
            } else if current.stateOnly == last?.stateOnly {
                status = current.propertyStatusOnly
            }

            let description = status.description
            if !description.isEmpty {
                print(description)
            }
        }

        return current
    }

    func run() throws {
        let queue = DispatchQueue(label: "\(CLI.applicationName).control-plane-server")
        let launcher = ProcessLauncher()
        let executable = options.toolsDirectory.controlPlaneTestServer

        let config = try ControlPlaneServerConfig(instance: options.instanceName)
        guard let port = config.port else {
            throw CLIError("Failed to read port from configuration.")
        }
        let commandPath = try ControlPlaneAgentCommand.fileURL(instance: options.instanceName).path(percentEncoded: false)
        let arguments = ["--hostname", "0.0.0.0",
                         "--port", String(port),
                         "--data-source", commandPath]

        if raw {
            let rc: Int32 = try launcher.exec(executablePath: executable, arguments: arguments, queue: queue)
            throw ExitCode(rc)
        }

        // Streaming output
        // Unbuffer the subprocess console output via script(1)
        let unbufferedExec = "/usr/bin/script"
        let unbufferedArgs = ["-q", "/dev/null", executable] + arguments
        var rawStatus: [String]? = nil
        var lastStatus: ControlPlaneAgentStatus?
        let retCode = try launcher.exec(executablePath: unbufferedExec, arguments: unbufferedArgs, queue: queue) { data in
            // Parse line by line, 0xa = \n
            while let lineEnd = data.firstIndex(of: 0xa) {
                var stringEnd = lineEnd

                // Exclude \r if recorded
                if data[lineEnd - 1] == 0xd {
                    stringEnd = lineEnd - 1
                }
                let lineBytes = (data as Data).prefix(upTo: stringEnd)
                let line = String(data: lineBytes, encoding: .utf8)

                // Remove the parsed line with \n
                data.replaceBytes(in: NSRange(0...lineEnd), withBytes: nil, length: 0)
                guard let line = line else {
                    continue
                }

                // Start capturing response
                if line.hasPrefix("Request headers:") {
                    rawStatus = []
                }
                if rawStatus != nil {
                    if line == "}" {
                        // End of JSON capture
                        rawStatus?.append("}")
                        lastStatus = updateAndLogStatus(current: rawStatus!, last: lastStatus)
                        rawStatus = nil
                    } else if line.hasPrefix("Data Received =") {
                        // Start of JSON capture
                        rawStatus?.append("{")
                    } else if rawStatus!.count > 0 {
                        // Capture JSON body
                        rawStatus?.append(line)
                    }
                } else if !verbose && line.contains("info codes.vapor.application") {
                    // Hide verbose info by default
                    continue
                } else {
                    // Pass through other logs
                    print(line)
                }
            }
        }

        throw ExitCode(retCode)
    }
}

struct ControlPlaneRawServerCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "raw-server",
        abstract: "Start the test server with argument passthrough.",
    )

    @OptionGroup
    var options: InstanceCommand.Options

    @Argument(parsing: .captureForPassthrough)
    var passthroughArguments: [String] = []

    func run() throws {
        let queue = DispatchQueue(label: "\(CLI.applicationName).control-plane-server")
        let launcher = ProcessLauncher()
        let executable = options.toolsDirectory.controlPlaneTestServer
        let rc: Int32 = try launcher.exec(executablePath: executable, arguments: passthroughArguments, queue: queue)

        throw ExitCode(rc)
    }
}
