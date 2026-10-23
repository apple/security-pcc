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

import Foundation
import System

struct PCCVREHelper {
    static var configuredPath: String?

    enum Feature: String {
        case instanceV1
        case instanceInferenceRequestV1
        case darwinInit
        case requiredMemory
        case ensemble
    }

    let path: String
    let toolsDMGs: [CryptexHelper]

    static func pathInToolsDir(_ toolsDir: URL) -> String {
        return toolsDir.path(percentEncoded: false) + "/usr/bin/pccvre-helper"
    }

    static func configuredOrInToolsDMG(_ toolsDMGPath: String) throws -> Self {
        if let configuredPath {
            return Self(path: configuredPath, toolsDMGs: [])
        } else {
            return try Self.inToolsDMG(toolsDMGPath)
        }
    }

    private static func inToolsDMG(_ toolsDMGPath: String) throws -> Self {
        let toolsDMGs = try VRE.mountPCHostTools(dmgPath: toolsDMGPath)
        guard let toolsDir = toolsDMGs.first?.mountPoint else {
            throw CLIError("Unable to obtain Tools dmg mountpoint")
        }
        let path = pathInToolsDir(toolsDir)
        try HelperCodeSign.verify(path)
        return Self(path: path, toolsDMGs: toolsDMGs)
    }

    static func configuredOrInToolsDir(_ toolsDir: URL) -> Self {
        if let configuredPath {
            return Self(path: configuredPath, toolsDMGs: [])
        } else {
            return Self(path: pathInToolsDir(toolsDir), toolsDMGs: [])
        }
    }

    static func configuredOrFromRelease(_ release: String) throws -> Self {
        if let configuredPath {
            return Self(path: configuredPath, toolsDMGs: [])
        } else {
            let hostTools = try CLI.extractHostToolsAsset(release: release)
            return try Self.inToolsDMG(hostTools.string)
        }
    }

    private init(path: String, toolsDMGs: [CryptexHelper]) {
        self.path = path
        self.toolsDMGs = toolsDMGs
    }

    func supports(feature: Feature) -> Bool {
        return (try? _supports(feature: feature)) ?? false
    }

    func _supports(feature: Feature) throws -> Bool {
        guard Globals.computer.fileSystem.isExecutableFile(atPath: path) else {
            throw CLIError("helper not found")
        }

        let commandLine = [path, "features"]
        let (exitCode, stdOutput, stdError) = try ExecCommand(commandLine).run(
            outputMode: .capture,
            queue: DispatchQueue(label: "\(applicationName).ExecCommand")
        )

        guard exitCode == 0 else {
            throw CLIError("pccvre-helper features failed with exit code \(exitCode) - \(stdError)")
        }

        for line in stdOutput.split(separator: "\n") {
            if line == feature.rawValue {
                return true
            }
        }
        return false
    }
}

enum PCCVREHelperError: Error, CustomStringConvertible {
    case notSupported(_ feature: PCCVREHelper.Feature)
    case failed(exitCode: Int32, stderr: String)

    var description: String {
        switch self {
        case .notSupported(let feature): return "This PCC release does not support helper feature \(feature)"
        case .failed(exitCode: let exitCode, stderr: let stderr): return "pccvre-helper failed with exit code \(exitCode): \(stderr)"
        }
    }
}

extension PCCVREHelper {
    func darwinInit(_ config: String) -> DarwinInit {
        return DarwinInit(config: config, helper: self)
    }

    struct DarwinInit {
        let config: String
        let helper: PCCVREHelper

        func configFile() throws -> URL {
            let url = try FileManager.tempDirectory(subPath: applicationName).appendingPathComponent(UUID().uuidString)
            try config.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func command(_ command: String, requiring feature: Feature, arguments: [String]) throws -> String {
            guard helper.supports(feature: feature) else {
                throw PCCVREHelperError.notSupported(feature)
            }

            let command = [
                helper.path,
                "darwin-init",
                command,
                "--output",
                "-",
            ] + arguments + [
                try configFile().path(percentEncoded: false)
            ]
            let (exitCode, stdout, stderr) = try ExecCommand(command).run(
                outputMode: .capture,
                queue: DispatchQueue(label: "\(applicationName).ExecCommand")
            )
            guard exitCode == 0 else {
                throw PCCVREHelperError.failed(exitCode: exitCode, stderr: stderr)
            }

            return stdout
        }

        func listCryptexes() throws -> [Cryptex] {
            let stdout = try command("cryptex-list", requiring: .darwinInit, arguments: [])
            return try JSONDecoder().decode([Cryptex].self, from: stdout.data(using: .utf8)!)
        }

        func addCryptex(_ cryptex: Cryptex) throws -> String {
            return try command("cryptex-add", requiring: .darwinInit, arguments: [
                "--variant", cryptex.variant, "--url", cryptex.url
            ])
        }

        func removeCryptex(variant: String) throws -> String {
            return try command("cryptex-remove", requiring: .darwinInit, arguments: [
                "--variant", variant
            ])
        }

        func localHostname() throws -> String {
            return try command("local-hostname", requiring: .darwinInit, arguments: [])
        }

        func setLocalHostname(_ localHostname: String) throws -> String {
            return try command("local-hostname", requiring: .darwinInit, arguments: [
                "--new-value", localHostname
            ])
        }

        func enableSSH(sshPubKey: String) throws -> String {
            return try command("ssh-enable", requiring: .darwinInit, arguments: [
                "--public-key", sshPubKey
            ])
        }

        func disableSSH() throws -> String {
            return try command("ssh-disable", requiring: .darwinInit, arguments: [])
        }

        func addEnsembleConfig(name: String, nodes: [EnsembleNode]) throws -> String {
            var arguments = ["--ensemble-name", name]
            for node in nodes {
                arguments += ["--node", node.json]
            }
            return try command("ensemble-configure", requiring: .darwinInit, arguments: arguments)
        }


        /// Merge provided config overriding any matchig properties with the current one.
        ///
        /// Does not modify the current config, returns a new one as a string.
        ///
        /// - Parameter overrideDarwinInit: darwin-init containing the desired overrides
        /// - Returns: merged config
        func mergeConfig(overrideDarwinInit: String) throws -> String {
            let overrideDarwinInit = DarwinInit(config: overrideDarwinInit, helper: self.helper)
            let overrideFile = try overrideDarwinInit.configFile()
            let arguments = [overrideFile.path(percentEncoded: false)]
            return try command("merge", requiring: .darwinInit, arguments: arguments)
        }
    }
}

extension PCCVREHelper {
    func requiredMemory(application: String?) throws -> UInt {
        guard try _supports(feature: .requiredMemory) else {
            throw PCCVREHelperError.notSupported(.requiredMemory)
        }

        var command = [path, "required-memory"]
        if let application {
            command += ["--application", application]
        }
        let (exitCode, stdout, stderr) = try ExecCommand(command).run(
            outputMode: .capture,
            queue: DispatchQueue(label: "\(applicationName).ExecCommand")
        )
        guard exitCode == 0 else {
            throw PCCVREHelperError.failed(exitCode: exitCode, stderr: stderr)
        }

        guard let result = UInt(stdout) else {
            throw CLIError("Unable to parse required-memory as UInt: \(stdout)")
        }
        return result
    }
}
