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

//
//  SCNetworkSettingsManager.swift
//  DarwinInit
//

import OSLog
import SystemConfiguration
import SystemConfiguration_Private
import SystemConfiguration_Private.SCNetworkSettingsManager

// MARK: - Initialization
extension SCNSManager {
    static let logger = Logger(category: "SCNSManager")
    static var interfaces: [SCNetworkInterface] = []
    
    static func create(_ context: String = #function) -> SCNSManager {
        return SCNSManagerCreate(context as CFString)
    }
}

// MARK: - General API
extension SCNSManager {
    /** 
     Copies a SCNetworkInterface given a BSD name
     
     - Parameter name: BSD name of a network interface, such as en0
     
     - Returns: an SCNetworkInterface that matches name or nil
    */
    func copyInterface(name: String) -> SCNetworkInterface? {
        // obtain a list of all network interfaces if you haven't already
        if Self.interfaces.isEmpty {
            Self.interfaces = SCNetworkInterfaceCopyAll() as! [SCNetworkInterface]
            // if still no interfaces found, report any error set by CopyAll
            if Self.interfaces.isEmpty {
                let error = SCError.current()
                Self.logger.error("No interfaces found: \(error)")
                return nil
            }
        }
        for idx in 0..<Self.interfaces.count {
            let netif: SCNetworkInterface = Self.interfaces[idx]
            if let bsdName = SCNetworkInterfaceGetBSDName(netif) {
                if (String(bsdName) == name) {
                    Self.logger.info("Found matching interface with name: \(name)")
                    return (netif)
                }
            }
        }
        let error = SCError.current()
        Self.logger.error("Found no matching interfaces with name \(name): \(error)")
        return nil
    }
    
    /** 
     Copy the default service for a given interface
     
     - Parameter interface: BSD name of the interface, such as en0
     
     - Parameter netif: SCNetworkInterface ref for interface with this name
     
     - Returns: a service ref or nil
    */
    func copyService(interface: String, netif: SCNetworkInterface) -> SCNSService? {
        // copy the default service (categories are not relevant here)
        guard let service = SCNSManagerCopyService(self, netif, nil, nil) else {
            let error = SCError.current()
            Self.logger.error("No service found for \(interface): \(error)")
            return nil
        }
        Self.logger.info("Found service for interface \(interface)")
        return service
    }
    
    /**
     Attempts to copy the config for the given interface and protocol
     
     - Parameter service: service for the interface to obtain config for
     
     - Parameter interface: name of network interface to obtain the config for
     
     - Parameter proto: One of "DNS", "IPv4," "IPv6," or "Proxies"
     
     - Returns: the config as a CFDictionary or nil if it doesn't exist/not yet created
    */
    func copyProtocolEntity(service: SCNSService, interface: String, proto: String) -> CFDictionary? {
        // attempt to copy the config for the specified service and protocol
        guard let entity = SCNSServiceCopyProtocolEntity(service, proto as CFString) else {
            let error = SCError.current()
            Self.logger.error("No existing config for \(interface) and \(proto): \(error)")
            return nil
        }
        Self.logger.info("Found config for \(interface) and \(proto)")
        return entity
    }
    
    /**
     Sets a new config for the given interface and protocol.
     
     It is assumed that the client has already checked that the config exists via copyProtocolEntity.
     
     Apply must be called to actually apply the changes
     
     - Parameter interface: name of network interface to set the config for
     
     - Parameter proto: One of "DNS", "IPv4," "IPv6," or "Proxies"
     
     - Parameter config: the new config value to apply
     
     - Returns: true or false indicating if the changes were set
    */
    func setProtocolEntity(service: SCNSService, interface: String, proto: String,                            config: CFDictionary?) -> Bool {
        guard SCNSServiceSetProtocolEntity(service, proto as CFString, config) else {
            let error = SCError.current()
            Self.logger.error("Unable to set config for \(interface) and proto \(proto): \(error)")
            return false
        }
        return true
    }
    
    func refresh() {
        SCNSManagerRefresh(self)
    }
    
    /// Applies changes made to network configuration by setProtocolEntity
    func apply() -> Bool {
        guard SCNSManagerApplyChanges(self) else {
            let error = SCError.current()
            Self.logger.error("Unable to apply network configuration: \(error)")
            return false
        }
        return true
    }
}
