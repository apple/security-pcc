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

extension VM {
    // modify alters configuration of a VM (existing configuration will attempt to be loaded,
    //  otherwise assume a new/empty config) -- parameters not specified are copied from existing config,
    //  platform default, or assumes equivalent "none" value
    func modify(
        cpuCount: UInt? = nil,
        memorySize: UInt64? = nil,
        networkConfigs: [NetworkConfig]? = nil,
        nvramArgs: VM.NVRAMmap? = nil,
        romImages: ROMImages? = nil,
        platformFusing: VM.PlatformFusing? = nil,
        virtMeshPlugin: String? = nil,
        virtMeshRank: Int? = nil
    ) throws {
        VM.logger.log("modify VM: \(self.name, privacy: .public)")
        var curConfig: Config?

        // when creating, bundle/curConfig will be empty
        if exists {
            do {
                curConfig = try Config(fromBundle: bundle)
            } catch {
                throw VMError("could not load existing config")
            }
        }

        var bundleROMs = curConfig?.romImages ?? VM.ROMImages()
        if let copiedROMs = try copyROMs(romImages) {
            if let img = copiedROMs.avpbooter {
                bundleROMs.avpbooter = img
            }

            if let img = copiedROMs.avpsepbooter {
                bundleROMs.avpsepbooter = img
            }
        }

        if virtMeshPlugin != nil, virtMeshRank == nil {
            throw VMError("VirtMesh rank has to be set when plugin is preset, redo the modify with the rank set")
        }

        // new config parameters are those passed in or from previous config (or some other default)
        let vmConfig = Config(
            bundle: bundle,
            platformFusing: platformFusing ?? curConfig?.platformFusing,
            machineIDBlob: curConfig?.machineIDBlob,
            cpuCount: cpuCount ?? curConfig?.cpuCount ?? 1,
            memorySize: memorySize ?? curConfig?.memorySize ?? (4 * 1024 * 1024 * 1024),
            networkConfigs: networkConfigs ?? curConfig?.networkConfigs ?? [NetworkConfig(mode: .none)],
            nvramArgs: nvramArgs ?? curConfig?.nvramArgs,
            romImages: bundleROMs,
            virtMeshPlugin: virtMeshPlugin ?? curConfig?.virtMeshPlugin,
            virtMeshRank: virtMeshRank ?? curConfig?.virtMeshRank
        )

        // validate resulting configuration
        do {
            _ = try vmConfig.vzConfig()
        } catch {
            throw VMError("VM configuration: \(error)")
        }

        // and save config in VM bundle
        do {
            try vmConfig.writeBundleConfig()
        } catch {
            throw VMError("save VM configuration: \(error)")
        }

        VM.logger.log("modify completed")
    }

    // copyROMs copies in iBoot (avpbooter) and/or vSEP (avpsepbooter) (or neither) and updates their
    //  pathname relative to the VM bundle folder
    func copyROMs(_ roms: ROMImages?) throws -> ROMImages? {
        guard var roms else {
            return nil // no optional images to copy in
        }

        if let img = roms.avpbooter {
            do {
                VM.logger.debug("copyROM (iBoot): \(img, privacy: .public)")
                roms.avpbooter = try bundle.copyInFile(FileManager.fileURL(img)).lastPathComponent
            } catch {
                throw VMError("\(img): copy into VM bundle: \(error)")
            }
        }

        if let img = roms.avpsepbooter {
            do {
                VM.logger.debug("copyROM (vSEP): \(img, privacy: .public)")
                roms.avpsepbooter = try bundle.copyInFile(FileManager.fileURL(img)).lastPathComponent
            } catch {
                throw VMError("\(img): copy into VM bundle: \(error)")
            }
        }

        return roms
    }
}
