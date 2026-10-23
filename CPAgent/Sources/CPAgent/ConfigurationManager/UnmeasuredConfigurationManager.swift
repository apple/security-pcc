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

import FleetManagerClient
import Foundation
import Logging

class UnmeasuredConfigurationManager {
    private let cpagentConfiguration: CPAgentMeasuredConfiguration
    private let logger = Logger(label: "CPAgent.UnmeasuredConfigurationManager")

    init(
        cpagentConfiguration: CPAgentMeasuredConfiguration
    ) {
        self.cpagentConfiguration = cpagentConfiguration
    }

    public struct Configuration {
        public let preferencesByAppId: [ApplicationID: [String: Any]]
    }

    private func parseConfigurationResponse(config: Components.Schemas.NodeConfiguration) throws
        -> Configuration
    {
        logger.info(
            "Parsing configuration response",
            metadata: [
                "configuration": "\(config)"
            ])

        guard let preferencesValue = config.values?.preferences else {
            logger.info(
                "No preferences key found in configuration values, returning empty preferences")
            return Configuration(preferencesByAppId: [:])
        }

        if preferencesValue.isEmpty {
            logger.info("Preferences array is empty, returning empty preferences")
            return Configuration(preferencesByAppId: [:])
        }

        var preferencesByAppId: [ApplicationID: [String: Any]] = [:]

        for item in preferencesValue {
            guard let appId = ApplicationID(item.applicationId)
            else {
                continue
            }

            preferencesByAppId[appId, default: [:]].updateValue(item.value.value, forKey: item.key)
        }

        return Configuration(preferencesByAppId: preferencesByAppId)
    }

    public func fetchAndSaveUnmeasuredConfiguration(
        config: Components.Schemas.NodeConfiguration,
        fleetNodeId: String?
    ) async throws {
        defer {
            do {
                // Save fleet node ID to global unmeasured config
                let globalDir = "\(cpagentConfiguration.renderedConfigDirectory)/global"
                try FileManager.default.createDirectory(
                    atPath: globalDir, withIntermediateDirectories: true, attributes: nil)

                let unmeasuredConfigPath = "\(globalDir)/unmeasured-config.json"

                // Read existing file or create new dictionary
                var configDict: [String: Any] = [:]
                if FileManager.default.fileExists(atPath: unmeasuredConfigPath) {
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: unmeasuredConfigPath)),
                        let json = try? JSONSerialization.jsonObject(with: data, options: [])
                            as? [String: Any]
                    {
                        configDict = json
                    }
                }

                // Add or update FLEET_NODE_ID (use empty string if nil or empty)
                configDict["FLEET_NODE_ID"] = fleetNodeId ?? ""

                // Write back to file with proper JSON formatting
                let jsonData = try JSONSerialization.data(
                    withJSONObject: configDict, options: .prettyPrinted)
                try jsonData.write(to: URL(fileURLWithPath: unmeasuredConfigPath))

                logger.info(
                    "Saved fleet node ID to unmeasured config",
                    metadata: ["path": "\(unmeasuredConfigPath)"])
            } catch {
                logger.error(
                    "Unable to write fleet-node-id to global unmeasured json file.",
                    metadata: ["error": "\(String(reportable: error))"])
            }
        }
        var configuration: Configuration = Configuration(preferencesByAppId: [:])
        do {
            configuration = try parseConfigurationResponse(config: config)
        } catch {
            logger.error(
                "Failed to parse configuration response",
                metadata: [
                    "error": "\(String(reportable: error))"
                ]
            )
        }

        // Check if preferencesByAppId is empty and return early
        if configuration.preferencesByAppId.isEmpty {
            logger.info("No preferences to save, preferencesByAppId is empty")
            return
        }

        for (appId, preferences) in configuration.preferencesByAppId {
            logger.info(
                "Mounting configurations for application.", metadata: ["appId": "\(appId)"])

            let directoryPath =
                "\(cpagentConfiguration.renderedConfigDirectory)/\(appId.directorySuffix)/"

            let fileManager = FileManager.default

            do {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: directoryPath, isDirectory: &isDirectory),
                    isDirectory.boolValue
                {
                    logger.info(
                        "Directory already exists, skipping creation.",
                        metadata: ["directoryPath": "\(directoryPath)"])
                } else {
                    try fileManager.createDirectory(
                        atPath: directoryPath,
                        withIntermediateDirectories: true,
                        attributes: [
                            .posixPermissions: 0o755
                        ]
                    )
                    logger.info(
                        "Created directory.", metadata: ["directoryPath": "\(directoryPath)"])
                }
                // Create unmeasured-config.json file for each application ID
                let filePath = directoryPath + "unmeasured-config.json"
                fileManager.createFile(
                    atPath: filePath,
                    contents: Data(),  // Empty file
                    attributes: [.posixPermissions: 0o644]  // rw-r--r--
                )
                logger.info(
                    "Finished trying to create file.", metadata: ["filePath": "\(filePath)"]
                )

                let jsonData = try JSONSerialization.data(
                    withJSONObject: preferences,
                    options: [.withoutEscapingSlashes, .prettyPrinted]
                )

                try jsonData.write(to: URL(fileURLWithPath: filePath))
                try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: filePath)

            } catch {
                let nsError = error as NSError
                logger.error(
                    "Failed to write unmeasured config file.",
                    metadata: [
                        "directoryPath": "\(directoryPath)",
                        "error": "\(String(reportable: error))",
                        "errorDomain": "\(String(reportable: nsError.domain))",
                        "errorCode": "\(String(reportable: nsError.code))",
                        "errorDescription": "\(String(reportable: nsError.localizedDescription))",
                    ]
                )
            }

        }
    }
}
