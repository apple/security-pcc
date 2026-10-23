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
import Virtualization
import Virtualization_Private

extension VMBundle {
    // VMBundle.Config is the on-disk representation of a Virtual Machine configuration
    struct Config: Codable {
        let platformType: VM.PlatformType // .vresearch101
        var platformFusing: VM.PlatformFusing? // .prod or .dev
        let machineIdentifier: Data // "opaque" representation of ECID
        let cpuCount: UInt
        let memorySize: UInt64
        let networkConfig: NetworkConfig // (legacy) == networkConfigs[0]
        var networkConfigs: [NetworkConfig]?
        let romImages: VM.ROMImages? // optional firmware files for iBoot and/or vSEP
        var virtMeshPlugin: String? // optional path to the VirtMesh plugin bundle
        var virtMeshRank: Int?

        // init instantiates a new VMBundle.Config from parameters (typically when creating a new VM)
        init(
            vmConfig: VZVirtualMachineConfiguration,
            platformType: VM.PlatformType,
            platformFusing: VM.PlatformFusing?,
            romImages: VM.ROMImages? = nil,
            virtMeshPlugin: String? = nil,
            virtMeshRank: Int? = nil
        ) {
            self.platformType = platformType
            self.platformFusing = platformFusing
            if let platformConfig = vmConfig.platform as? VZMacPlatformConfiguration {
                machineIdentifier = platformConfig.machineIdentifier.dataRepresentation
            } else {
                machineIdentifier = Data()
            }

            memorySize = vmConfig.memorySize
            cpuCount = UInt(vmConfig.cpuCount)

            if vmConfig.networkDevices.count > 0 {
                var networkConfigs: [NetworkConfig] = []
                for netDev in vmConfig.networkDevices {
                    networkConfigs.append(VMBundle.Config.NetworkConfig(netDev))
                }

                self.networkConfigs = networkConfigs
                networkConfig = networkConfigs.first!
            } else {
                networkConfig = VMBundle.Config.NetworkConfig(mode: .none)
                networkConfigs = [networkConfig]
            }

            self.romImages = romImages
            self.virtMeshPlugin = virtMeshPlugin
            self.virtMeshRank = virtMeshRank
        }

        // init instantiates VMBundle.Config from ondisk XML (config.) plist files (after creation)
        init(contentsOf url: URL) throws {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw VMBundleError("read config \(url.path): \(error)")
            }

            let decoder = PropertyListDecoder()
            do {
                self = try decoder.decode(Config.self, from: data)
                guard (virtMeshRank == nil) == (virtMeshPlugin == nil) else {
                    throw VMBundleError("VirtMesh has either rank or plugin path as nil")
                }
            } catch {
                throw VMBundleError("parse config \(url.path): \(error)")
            }

            if networkConfigs == nil {
                networkConfigs = [networkConfig]
            }

            let configJSON = asJSON()
            VMBundle.logger.debug("loaded config [\(url.path, privacy: .public)]: \(configJSON, privacy: .public)")
        }

        // write dumps self to XML (config.) plist at (to) path
        func write(to url: URL) throws {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml

            do {
                let data = try encoder.encode(self)
                try data.write(to: url)
            } catch {
                throw VMBundleError("write config \(url.path): \(error)")
            }

            VMBundle.logger.debug("wrote config [\(url.path, privacy: .public)]: \(asJSON(), privacy: .public)")
        }

        // asJSON returns JSON string form of self (VMBundle.Config), for logging/debugging
        func asJSON() -> String {
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = .withoutEscapingSlashes
            do {
                return try String(decoding: jsonEncoder.encode(self), as: UTF8.self)
            } catch {
                VMBundle.logger.error("encode config to JSON: \(error, privacy: .public)")
            }

            return "{ }"
        }

        // VMBundle.Config.NetworkConfig contains the network configuration stanza of the config.plist file
        struct NetworkConfig: Codable {
            static var defaultValue: NetworkConfig { self.init(mode: .none) }

            var mode: VM.NetworkMode
            var macAddr: String
            var options: [NetworkOptions]?

            init(mode: VM.NetworkMode, macAddr: VZMACAddress? = nil, options: [NetworkOptions]? = nil) {
                self.mode = mode
                if let macAddr {
                    self.macAddr = macAddr.string
                } else {
                    self.macAddr = ""
                }

                self.options = options
            }

            init(_ netdev: VZNetworkDeviceConfiguration) {
                switch netdev.attachment {
                case let attachment as VZBridgedNetworkDeviceAttachment:
                    mode = .bridged
                    options = [.bridgeIf(attachment.interface.identifier)]

                case is VZNATNetworkDeviceAttachment:
                    mode = .nat

                case is _VZHostOnlyNetworkDeviceAttachment:
                    mode = .hostOnly

                default:
                    mode = .none
                }

                macAddr = netdev.macAddress.string
            }
        }

        enum NetworkOptions: Codable {
            case bridgeIf(String) // phy interface for VM guest to "bridge" onto
            case isolateIf(Bool) // NAT mode (not implemented; support older config)
        }
    }
}
