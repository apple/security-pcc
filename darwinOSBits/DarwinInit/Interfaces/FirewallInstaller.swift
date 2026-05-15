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

//
//  Firewall.swift
//  DarwinInit
//

import Foundation
import IOKit
import IOKit.network
import notify
import System

internal extension io_object_t {
    func name() -> String? {
        let buf = UnsafeMutablePointer<io_name_t>.allocate(capacity: 1)
        defer { buf.deallocate() }
        return buf.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<io_name_t>.size) {
            if IORegistryEntryGetName(self, $0) == KERN_SUCCESS {
                return String(cString: $0)
            }
            return nil
        }
    }

    func className() -> String? {
        let buf = UnsafeMutablePointer<io_name_t>.allocate(capacity: 1)
        defer { buf.deallocate() }
        return buf.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<io_name_t>.size) {
            if IOObjectGetClass(self, $0) == KERN_SUCCESS {
                return String(cString: $0)
            }
            return nil
        }
    }

    func parent() -> io_object_t? {
        var parent: io_object_t = 0
        let ret = IORegistryEntryGetParentEntry(self, kIOServicePlane, &parent)
        if ret != KERN_SUCCESS {
            return nil
        }
        return parent
    }
}

struct KernelReturnError: Error {
    internal let error: kern_return_t
}

internal class InterfaceFinder {
    internal func validate(_ error: kern_return_t) throws {
        if error != KERN_SUCCESS {
            throw KernelReturnError(error: error)
        }
    }

    // getEthernetInterfaceForParent finds an interface whose ioreg node has an exact
    // match for childClassName and is a subtype of parentClassName
    internal func getEthernetInterfaceForParent(childClassName: String, parentClassName: String) throws -> [String] {
        // Construct a matching dictionary that looks like this
        //    IOParentMatch = {
        //       IOProviderClass = parentName;
        //    };
        //    IOProviderClass = childName;
        let childMatch = IOServiceMatching(childClassName) as NSMutableDictionary
        let parentMatch = IOServiceMatching(parentClassName) as NSMutableDictionary
        childMatch.setValue(parentMatch, forKey: kIOParentMatchKey)
        
        var iterator: io_iterator_t = 0
        var ifaceNames: [String] = []

        logger.info("Looking for node with class \(childClassName) and parent class \(parentClassName)")
        try validate(IOServiceGetMatchingServices(kIOMainPortDefault, childMatch, &iterator))
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)

            guard child != 0 else {
                break
            }
            
            guard child.className() == childClassName else {
                let name = child.className() ?? "Unknown"
                logger.info("Skipping matched node with class: \(name)")
                continue
            }

            if let bsdName = getBSDName(forEntry: child) {
                ifaceNames.append(bsdName)
            }
        }

        return ifaceNames
    }

    internal func getBSDName(forEntry: io_registry_entry_t) -> String? {
        return stringProperty(forEntry, kIOBSDNameKey, recursive: true)
    }

    internal func stringProperty(_ entry: io_registry_entry_t, _ property: String, recursive: Bool = false) -> String? {
        IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            property as CFString,
            kCFAllocatorDefault,
            recursive ? IOOptionBits(kIORegistryIterateRecursively) : 0
        ).flatMap { $0 as? String }
    }
}

class FirewallInstaller {
    let firewallRulesInstalledEventName = "com.apple.darwininit.firewall.installed"
    let computer: Computer
    let interfaceFinder: InterfaceFinder

    /// Was there an error
    var lastError: Swift.Error? = nil

    enum Error: Swift.Error {
        case wrongNumberOfManagementInterfaces(count: Int)
    }

    init(computer: Computer = RealComputer.shared, interfaceFinder: InterfaceFinder = InterfaceFinder()) {
        self.interfaceFinder = interfaceFinder
        self.computer = computer
    }

    internal func findManagementNetworkInterfaceName() throws -> String {
        let ifaceNames = try interfaceFinder.getEthernetInterfaceForParent(
            childClassName: "IOEthernetInterface",
            parentClassName: "AppleUSBDeviceNCMData"
        )
        guard ifaceNames.count == 1 else {
            throw Error.wrongNumberOfManagementInterfaces(count: ifaceNames.count)
        }
        return ifaceNames[0]
    }

    internal func performInterfaceSubstitutions(_ rules: String) throws -> String {
        let variableName = "${MANAGEMENT_INTERFACE}"
        if rules.contains(variableName) {
            let numRetries = 60
            var lastError: Swift.Error = Error.wrongNumberOfManagementInterfaces(count: 0)
            for retry in 1 ... numRetries {
                do {
                    let managementInterfaceName = try findManagementNetworkInterfaceName()
                    logger.info("Found management network interface: \(managementInterfaceName)")
                    return rules.replacingOccurrences(of: variableName, with: managementInterfaceName)
                } catch {
                    lastError = error
                    logger.warning("Unable to find management network interface retry=\(retry): \(error)")
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            logger.error("Exhausted retries while looking for management interface: \(lastError)")
            throw lastError
        }
        return rules
    }

    internal func installRules(_ rules: [String]) throws {
        let combined = rules.joined(separator: "\n")
        try installRules(combined)
    }

    internal func installRules(_ rules: String) throws {
        do {
            let rules = try performInterfaceSubstitutions(rules)
            try computer.fileSystem.mkdirs(kDInitFirewallRulesPath.removingLastComponent())
            try computer.fileSystem.write(text: rules, to: kDInitFirewallRulesPath)
            let pfctl = URL(fileURLWithPath: "/sbin/pfctl")
            try computer.run(executable: pfctl, arguments: ["-F", "all"])
            try computer.run(executable: pfctl, arguments: ["-f", kDInitFirewallRulesPath.string])
            try computer.run(executable: pfctl, arguments: ["-e"])
        } catch {
            self.lastError = error
            throw error
        }
    }

    internal func sendFirewallRulesInstalledEvent() {
        notify_post(firewallRulesInstalledEventName)
    }
}
