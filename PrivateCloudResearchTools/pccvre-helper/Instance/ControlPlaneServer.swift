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

import Foundation

struct ControlPlaneServerConfig: Codable {
    struct Keys {
        static let secureConfig = "secure-config"
        static let controlPlane = "com.apple.cloudos.controlplane.agent.ControlPlaneClient"
    }

    let AllowInsecure: Bool
    let DisableMTLS: Bool
    let CommandPollIntervalSeconds: Int
    let StatusPushIntervalSeconds: Int
    let ServiceURL: String

    init(hostname: String, port: Int, interval: Int) {
        self.AllowInsecure = true
        self.DisableMTLS = true
        self.CommandPollIntervalSeconds = interval
        self.StatusPushIntervalSeconds = interval
        self.ServiceURL = "http://\(hostname):\(port)/api/v1"
    }

    var port: Int? {
        if let url = URL(string: ServiceURL) {
            return url.port
        }
        return nil
    }

    init(from dictionary: [String: Any]) throws {
        let jsonData = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        self = try JSONDecoder().decode(ControlPlaneServerConfig.self, from: jsonData)
    }

    func dictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        return jsonObject as! [String: Any]
    }

    init(instance: String) throws {
        let launcher = ProcessLauncher()
        let arguments = ["instance", "configure", "darwin-init", "dump", "--name", instance]

        let result = try launcher.exec(executablePath: CLI.pccvrePath, arguments: arguments)
        let config = try DarwinInitConfig(json: result.stdout)

        let secureConfig = config.dictionary[ControlPlaneServerConfig.Keys.secureConfig] as? [String: Any]
        let dict = secureConfig?[ControlPlaneServerConfig.Keys.controlPlane] as? [String: Any]
        if let dict, let config = try? ControlPlaneServerConfig(from: dict) {
            self = config
            return
        }

        throw CLIError("Control plane agent is not set up for \(instance).")
    }
}

struct ControlPlaneAgentCommand {
    let service: String
    let type: Command

    static let DefaultService = "com.apple.tie-controllerd.from.control-plane-agent"

    enum Command {
        case initialize
        case deactivate
        case applyProperty(key: String, value: String)
        case activate
    }

    // See the definition of `TieModelSwitchingConfig`
    struct ModelSwitch: Codable {
        let defaultBaseModelVersionMap: [String: Int32]
        let inferenceIDsToActivate: [String]
        let distributionName: String

        static let Key = "ModelSwitchingProperty"

        func json() throws -> String {
            let data = try JSONEncoder().encode(self)
            return String(decoding: data, as: UTF8.self)
        }
    }

    var dictionary: [String: Any] {
        var config: [String: Any] = [
            "name": self.service
        ]

        let type = switch self.type {
        case .initialize:
            "INIT"
        case .deactivate:
            "DEACTIVATE"
        case .applyProperty:
            "APPLY_PROPERTY"
        case .activate:
            "ACTIVATE"
        }

        if case .applyProperty(let key, let value) = self.type {
            let dict = [
                "key": key,
                "value": value
            ]
            config["serviceProperty"] = dict
        }

        let command: [String : Any] = [
            "type": type,
            "serviceConfig": config,
        ]

        return [
            "commands": [command]
        ]
    }

    static func fileURL(instance: String) throws -> URL {
        try FileManager.tempDirectory(
            subPath: CLI.applicationName, instance).appending(path: "control-plane-commands.json")
    }

    static func send(type: Command, service: String, instance: String) throws {
        let command = ControlPlaneAgentCommand(service: service, type: type)
        let jsonData = try JSONSerialization.data(withJSONObject: command.dictionary, options: [])
        let content = String(decoding: jsonData, as: UTF8.self)
        try Self.send(content: content, instance: instance)
    }

    static func send(content: String, instance: String) throws {
        let url = try ControlPlaneAgentCommand.fileURL(instance: instance)
        CLI.debugPrint("Control plane commands saving to \(url.path(percentEncoded: false))")

        var toPrint = content
        if let data = content.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            toPrint = prettyString
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        print("Command sent: \(toPrint)")
    }
}

struct ControlPlaneAgentStatus: Codable, Equatable, CustomStringConvertible {
    let serviceStatuses: [Status]

    struct Status: Codable, Equatable {
        let state: State
        let propertyStatuses: [PropertyStatus]
        let name: String

        init(state: State, propertyStatuses: [PropertyStatus], name: String) {
            self.state = state
            self.propertyStatuses = propertyStatuses
            self.name = name
        }
    }

    struct State: Codable, Equatable {
        let observedAt: String
        let value: String

        init(observedAt: String, value: String) {
            self.observedAt = observedAt
            self.value = value
        }

        var isEmpty: Bool {
            value.isEmpty && observedAt.isEmpty
        }
    }

    struct PropertyStatus: Codable, Equatable {
        let key: String
        let state: State
        let value: String
    }

    init(from json: String) throws {
        let data = json.data(using: .utf8)!
        self = try JSONDecoder().decode(ControlPlaneAgentStatus.self, from: data)
    }

    init(status: [Status]) {
        self.serviceStatuses = status
    }

    var propertyStatusOnly: ControlPlaneAgentStatus {
        ControlPlaneAgentStatus(status: self.serviceStatuses.map {
            Status(state: State(observedAt: "", value: ""),
                   propertyStatuses: $0.propertyStatuses,
                   name: $0.name)
        })
    }

    var stateOnly: ControlPlaneAgentStatus {
        ControlPlaneAgentStatus(status: self.serviceStatuses.map {
            Status(state: $0.state,
                   propertyStatuses: [],
                   name: $0.name)
        })
    }

    var description: String {
        var result: [String] = []
        for status in serviceStatuses {
            if !status.state.isEmpty {
                result.append("\(status.state.observedAt) [\(status.name)] \(status.state.value)")
            }
            for propertyStatus in status.propertyStatuses {
                result.append("\(propertyStatus.state.observedAt) [\(status.name)] PROPERTY \(propertyStatus.state.value)")
                result.append("=> \(propertyStatus.key) -> \(propertyStatus.value)")
            }
        }
        return result.joined(separator: "\n")
    }
}
