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

//  Copyright © 2026 Apple, Inc. All rights reserved.
//

import ArgumentParserInternal
import Foundation

struct ServiceDiscoveryCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "service-discovery",
        abstract: "Invoke service discovery commands for service registration.",
        subcommands: [
            ServiceDiscoveryShowCommand.self,
            ServiceDiscoverySetupCommand.self,
            ServiceDiscoveryServerCommand.self,
        ],
    )

    @OptionGroup
    var options: InstanceCommand.Options
}

/// Reads back the ServiceDiscovery/GRPC preferences written by `ServiceDiscoveryConfigureOp`.
struct ServiceDiscoveryConfig {
    let serviceDiscovery: JSONDict
    let grpc: JSONDict

    init(instance: String) throws {
        let launcher = ProcessLauncher()
        let arguments = ["instance", "configure", "darwin-init", "dump", "--name", instance]
        let result = try launcher.exec(executablePath: CLI.pccvrePath, arguments: arguments)
        let config = try PCCDarwinInitConfig(json: result.stdout)

        guard let serviceDiscovery = Self.preferenceValue(in: config, key: "ServiceDiscovery"),
              let grpc = Self.preferenceValue(in: config, key: "GRPC") else {
            throw CLIError("Service discovery is not set up for '\(instance)'.")
        }

        self.serviceDiscovery = serviceDiscovery
        self.grpc = grpc
    }

    private static func preferenceValue(in config: PCCDarwinInitConfig, key: String) -> JSONDict? {
        let applicationID = ServiceDiscoveryConfigureOp.applicationID
        for entry in config.entries.reversed() {
            switch entry.version {
            case .v1:
                if let preferences = entry.dictionary["preferences"] as? [[String: Any]],
                   let match = preferences.first(where: { ($0["application_id"] as? String) == applicationID && ($0["key"] as? String) == key }),
                   let value = match["value"] as? JSONDict {
                    return value
                }
            case .v2:
                if let preferences = entry.dictionary["preferences"] as? [String: Any],
                   let anyUser = preferences["AnyUser"] as? [String: Any],
                   let app = anyUser[applicationID] as? [String: Any],
                   let value = app[key] as? JSONDict {
                    return value
                }
            }
        }
        return nil
    }
}

struct ServiceDiscoveryShowCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show service discovery configurations.",
    )

    @OptionGroup
    var options: InstanceCommand.Options

    func run() throws {
        let config = try ServiceDiscoveryConfig(instance: options.instanceName)
        let listeningIP = config.grpc["ListeningIP"] as? String ?? "?"
        let targetHost = config.serviceDiscovery["TargetHost"] as? String ?? "?"
        let targetPort = config.serviceDiscovery["TargetPort"] as? Int ?? 0
        print("Service discovery is set up for '\(options.instanceName)': listening on \(listeningIP), targeting \(targetHost):\(targetPort).")
    }
}

struct ServiceDiscoverySetupCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up the ServiceDiscovery and GRPC preferences for this instance.",
    )

    @OptionGroup
    var options: InstanceCommand.Options

    @Option(help: "Service discovery target port.")
    var port: Int = 8080

    /// A subset of `vrevm list --json`'s per-instance output, just enough to find the hostOnly network's IP.
    struct VREVMInstance: Decodable {
        struct Network: Decodable {
            let mode: String?
            let ipaddr: String?
        }

        let name: String
        let state: String?
        let networks: [Network]?
    }

    // Instances may have multiple network adapters (e.g. NAT + hostOnly); only the hostOnly
    // one is reachable from the host at ".1", so it must be looked up specifically.
    func hostOnlyIPAddress(launcher: ProcessLauncher) throws -> String {
        let arguments = ["list", "--json", "--name", options.instanceName]
        let result = try launcher.exec(executablePath: CLI.vrevmPath, arguments: arguments)

        let instances = try JSONDecoder().decode([VREVMInstance].self, from: Data(result.stdout.utf8))
        guard let instance = instances.first(where: { $0.name == options.instanceName }) else {
            throw CLIError("vrevm list --json --name \(options.instanceName) returned no matching instance.")
        }

        guard let network = instance.networks?.first(where: { $0.mode == "hostOnly" }) else {
            throw CLIError("Instance '\(options.instanceName)' has no hostOnly network.")
        }

        guard let ipaddr = network.ipaddr, !ipaddr.isEmpty else {
            throw CLIError("Instance '\(options.instanceName)' has no hostOnly IP assigned yet (state=\(instance.state ?? "unknown")). Please start the instance first and try again.")
        }

        return ipaddr
    }

    func run() throws {
        let launcher = ProcessLauncher()
        let listeningIP = try hostOnlyIPAddress(launcher: launcher)

        // The host should be listening at ".1" on the same hostOnly subnet.
        var targetHostParts = listeningIP.split(separator: ".")
        targetHostParts.removeLast()
        targetHostParts.append("1")
        let targetHost = targetHostParts.joined(separator: ".")

        var config = try PCCDarwinInitConfig(launcher: launcher, instance: options.instanceName)
        try config.configureServiceDiscovery(listeningIP: listeningIP, targetHost: targetHost, targetPort: port)
        try config.save(launcher: launcher, instance: options.instanceName)
        print("Setup done. Please restart the instance '\(options.instanceName)' to take effect.")
    }
}

struct ServiceDiscoveryServerCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Start the service discovery test server, with argument passthrough.",
    )

    @OptionGroup
    var options: InstanceCommand.Options

    @Argument(parsing: .captureForPassthrough)
    var passthroughArguments: [String] = []

    func run() throws {
        let queue = DispatchQueue(label: "\(CLI.applicationName).service-discovery-server")
        let launcher = ProcessLauncher()
        let executable = options.toolsDirectory.serviceDiscoveryTestServer
        let rc: Int32 = try launcher.exec(executablePath: executable, arguments: passthroughArguments, queue: queue)

        throw ExitCode(rc)
    }
}
