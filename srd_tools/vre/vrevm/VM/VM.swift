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

import ArgumentParserInternal
import Foundation
import os
import RemoteServiceDiscovery
import Virtualization

// VM is the in-core representation of a Virtual Machine
class VM {
    let name: String // name of VM
    var bundle: VMBundle // files making up VM
    var vmConfig: VM.Config? // VM configuration
    var vzVM: VZVirtualMachine? // instantiated VM
    var consoleOutput: Pipe? // console output stream

    var ecid: UInt64 { vmConfig?.ecid ?? 0 } // ecid for loaded VM
    var ecidStr: String { String(ecid, radix: 16, uppercase: false) } // ecid in string form
    var udidStr: String { String(format: "%08X-%016lX", self.vmConfig?.platformType.chipID ?? 0, self.ecid ) }
    var exists: Bool { FileManager.isRegularFile(bundle.configPath, resolve: true) } // true if config exists
    var isOpen: Bool { vzVM != nil } // true is VM config is loaded

    // dispatch queue for running vz VM
    let runQueue: DispatchQueue = .init(label: applicationName + "-VM")

    // logging handle for VM operations
    static var logger = os.Logger(subsystem: applicationName, category: "VM")

    enum PlatformType: Int, Codable {
        case notsupported = 0
        case vresearch101 = 3

        var chipID: UInt32 { // not exposed in VZ
            switch self {
            case .vresearch101: 0xfe01
            default: 0
            }
        }
    }

    enum PlatformFusing: String, CaseIterable, Codable, ExpressibleByArgument {
        case prod
        case dev
    }

    struct ROMImages: Codable {
        var avpbooter: String? = nil // iBoot
        var avpsepbooter: String? = nil // vSEP
    }

    enum NetworkMode: String, CaseIterable, Codable, ExpressibleByArgument {
        case none
        case nat
        case bridged
        case hostOnly

        static var allCases: [NetworkMode] {
            var _allCases: [NetworkMode] = [.none, .nat, .hostOnly]
            if CLI.internalBuild {
                _allCases += [.bridged]
            }

            return _allCases
        }
    }

    init(name: String, dataDir: String = cmdDefaults.dataDir) {
        self.name = name
        bundle = VMBundle(bundleName: name, libraryBaseDir: dataDir)
    }

    // awaitShutdown checks VM state as to whether it's stopped or paused (or error) or throws
    //  error if hasn't reached this state within timeout interval
    func awaitShutdown(timeout: TimeInterval) async throws {
        guard isOpen else {
            throw VMError("VM not open")
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while ![.error, .paused, .stopped].contains(vzVM!.state) {
            if Date() > deadline {
                throw VMError("timeout awaiting VM shutdown [\(vzVM!.state.rawValue)]")
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        VM.logger.debug("VM halted")
    }

    // rsdName returns the Remote Service Discovery name of the running VM; walks RSD devices
    //   of type "NCM" that are connected and matches VM's ECID against (suffix of)
    //   UniqueDeviceID
    func rsdName() throws -> String {
        guard isRunning() else {
            throw VMError("VM not running")
        }

        // chipID would also be in UniqueDeviceID (<chipid>-<ecid>), but no way to retrieve it
        let searchUDID = String(format: "-%016lX", ecid)

        var rsdDev: remote_device_t? = nil
        let browseCompleted = DispatchSemaphore(value: 0)

        remote_device_browse_present(REMOTE_DEVICE_TYPE_NCM_DEVICE, runQueue) { dev, done in
            if done {
                browseCompleted.signal()
                return
            }

            if let dev, remote_device_get_state(dev) == REMOTE_DEVICE_STATE_CONNECTED,
               let devudid_prop = remote_device_copy_property(dev, "UniqueDeviceID"),
               let devudid_str = xpc_string_get_string_ptr(devudid_prop),
               String(cString: devudid_str).hasSuffix(searchUDID)
            {
                rsdDev = dev
                browseCompleted.signal()
            }
        }

        browseCompleted.wait()
        if let rsdDev {
            return String(cString: remote_device_get_name(rsdDev))
        }

        throw VMError("RSD name not found")
    }
}

// VMError provides a general error wrapper for VirtualMachine operations
struct VMError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }

    init(_ message: String) {
        VM.logger.error("\(message, privacy: .public)")
        self.message = message
    }
}
