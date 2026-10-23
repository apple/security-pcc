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

import Foundation

extension VRE {
    typealias NVRAMArgs = [String: String]
    typealias VMConfig = VRE.VM.Config
    typealias VMStatus = VRE.VM.Status

    // applicationDir contains the full path of the "~/Library/Application Support/" dir for this utility
    static var applicationDir: URL { CLIDefaults.applicationDir }

    // instancesDir contains the full path of the VRE instances catalog
    static var instancesDir: URL { VRE.applicationDir.appending(path: "instances") }

    // instanceDir contains the full path of the named instance bundle
    static func instanceDir(_ name: String) -> URL { VRE.instancesDir.appending(path: name) }

    // ensemblesDir contains the full path of the VRE ensembles catalog
    static var ensemblesDir: URL { VRE.applicationDir.appending(path: "ensembles") }

    // ensembleDir contains the full path of the named ensemble bundle
    static func ensembleDir(_ name: String) -> URL { VRE.ensemblesDir.appending(path: name) }

    init(vrevmPath: String? = nil) {
        if let vrevmPath, Globals.computer.fileSystem.isExecutableFile(atPath: vrevmPath) {
            VRE.VM.vrevmCmd = vrevmPath
        }
    }

    // instanceList returns a set of available VRE instances
    static func instanceList() -> [VRE.Instance]? {
        guard let instanceNames = try? Globals.computer.fileSystem.contentsOfDirectory(
            atPath: VRE.instancesDir.path)
            .filter({ FileManager.isDirectory(VRE.instanceDir($0)) })
        else {
            return nil
        }

        VRE.logger.debug("list of VRE instance: \(instanceNames, privacy: .public)")

        var vres: [VRE.Instance] = []
        for iname in instanceNames {
            do {
                try vres.append(VRE.Instance(name: iname))
            } catch {
                VRE.logger.error("could not load VRE instance: \(iname, privacy: .public)")
                continue
            }
        }

        return vres.count > 0 ? vres : nil
    }

    // ensembleList returns a set of available VRE ensembles
    static func ensembleList() -> [VRE.Ensemble]? {
        guard let ensembleNames = try? Globals.computer.fileSystem.contentsOfDirectory(
            atPath: VRE.ensemblesDir.path)
            .filter({ FileManager.isDirectory(VRE.ensembleDir($0)) })
        else {
            return nil
        }

        VRE.logger.debug("list of VRE ensembles: \(ensembleNames, privacy: .public)")

        var ensembles: [VRE.Ensemble] = []
        for ename in ensembleNames {
            do {
                try ensembles.append(VRE.Ensemble(name: ename))
            } catch {
                VRE.logger.error("could not load VRE ensemble: \(ename, privacy: .public)")
                continue
            }
        }

        return ensembles.count > 0 ? ensembles : nil
    }

    // mountPCHostTools mounts dmgPath and checks if expected directories (checkToolsDirs)
    //  are available. Publishing needs may require an inner DMG (containing the actual tools),
    //  therefore, check for .dmg file in the root folder and mount it (only taken 1 level)
    //  and check for expected dirs.
    // Returns 1 or 2 DMGHandles (with first handle referencing the one containing the tools);
    //  these should be ejected in order -- they are otherwise ejected automatically when
    //  out of scope
    // Error is thrown if expected pathnames containing the tools are not found in any image
    //   (among other reasons)
    static func mountPCHostTools(
        dmgPath: String,
        checkToolsDirs: [String] = ["usr/local/bin", "System/Library"]
    ) throws -> [CryptexHelper] {
        VRE.logger.log("mountPCHostTools: \(dmgPath, privacy: .public)")
        var dmgHandles: [CryptexHelper] = [] // must hold these while mounted

        func _doMount(_ dp: String) throws -> URL {
            do {
                var dmg = try CryptexHelper(path: dp)
                try dmg.mount()
                dmgHandles.append(dmg)

                guard let mnt = dmg.mountPoint else {
                    throw VREError("unable to obtain mountpoint")
                }

                return mnt
            } catch {
                throw VREError("\(dmgPath): \(error)")
            }
        }

        var toolsMountPoint: URL
        do {
            toolsMountPoint = try _doMount(dmgPath)
        } catch {
            throw VREError("mount private cloud host tools: \(error)")
        }

        // check if first DMG contains another DMG in root dir
        var innerDMGPath: String?
        do {
            let dirls = try Globals.computer.fileSystem.contentsOfDirectory(atPath: toolsMountPoint.path)
            innerDMGPath = dirls.filter { $0.hasSuffix(".dmg") }.first
        } catch {
            throw VREError("unable to get contents of \(dmgPath)")
        }

        if var innerDMGPath {
            innerDMGPath = toolsMountPoint.appending(path: innerDMGPath).path
            VRE.logger.log("mountPCHostTools: mount inner DMG: \(innerDMGPath, privacy: .public)")
            do {
                toolsMountPoint = try _doMount(innerDMGPath)
            } catch {
                throw VREError("mount private cloud host tools: \(error)")
            }
        }

        // check if expected pathnames are available
        for sub in checkToolsDirs {
            let searchPath = toolsMountPoint.appending(path: sub)
            if !FileManager.isDirectory(searchPath) {
                VRE.logger.error("mountPCHostTools: \(searchPath, privacy: .public)/ not found")
                throw VREError("host tools not found")
            }

            VRE.logger.debug("mountPCHostTools: found \(sub, privacy: .public)/")
        }

        return dmgHandles.reversed() // innermost disk image handle first
    }
}
