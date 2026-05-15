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
//  NetworkConfig.swift
//  DarwinInit
//

import OSLog
import SystemConfiguration
import SystemConfiguration_Private
import SystemConfiguration_Private.SCNetworkSettingsManager

enum NetworkConfig {
    static func getProtocols(config: CFDictionary?) -> [String] {
        var protocols: [String] = []
        for (proto, _) in config as! [String : Any] {
            protocols.append(proto)
        }
        return protocols
    }
    /** 
     Gets a configuration for the specified network interface
     
     - Parameter interface: name of network interface to obtain the config for
     
     - Returns: the configuration as a CFDictionary or nil
     */
    static func getConfig(interface: String, config: CFDictionary?) -> CFDictionary? {
        let manager = SCNSManager.create()
        guard let netif = manager.copyInterface(name: interface) else {
            return nil
        }
        guard let service = manager.copyService(interface: interface, netif: netif) else {
            return nil
        }
        var copiedConfig: [String: Any] = [:]
        let protocols = getProtocols(config: config)
        for proto in protocols {
            copiedConfig[proto] = manager.copyProtocolEntity(service: service, interface: interface, proto: proto)
        }
        guard !copiedConfig.isEmpty else {
            logger.error("No config found for \(interface) and its protocols")
            return nil
        }
        return copiedConfig as CFDictionary
    }
    
    /** 
    Set a new network configuration for the specified interface and protocol
     
    - Parameter retryLimit: retry limit on checking if configd has laid down a config for the interface
     
    - Parameter config: the new configuration to apply
     
    - Parameter interface: name of the network interface to set the config for
     
    - Returns true or false indicating if the config was successfully applied
     */
    static func setConfig(retryLimit: Int, config: NSDictionary?, interface: String) -> Bool {
        let manager = SCNSManager.create()
        guard let netif = manager.copyInterface(name: interface) else {
            return false
        }

        // Poll until service has been laid down by configd or limit reached
        var retryCount = 0
        var service = manager.copyService(interface: interface, netif: netif)
        while service == nil {
            // Give up if we reach the retry limit
            guard retryLimit >= retryCount else {
                logger.error("Reached retry limit when trying to find service for interface \(interface)")
                return false
            }
            logger.error("Did not reach retry limit. Refreshing manager and trying to find service for interface again")
            retryCount += 1
            let waitSec = UInt32(retryCount)
            sleep(waitSec)
            manager.refresh()
            service = manager.copyService(interface: interface, netif: netif)
        }

        // Set the nested config for each protocol specified in client's network config
        var changed = false
        let protocols = getProtocols(config: config)
        for proto in protocols {
            let entity = manager.copyProtocolEntity(service: service!, interface: interface, proto: proto)
            // If the config isn't going to change, don't bother setting and applying
            let subconfig = config!.object(forKey: proto) as! CFDictionary
            guard !CFEqual(entity ?? kCFNull, subconfig) else {
                logger.info("Network config value for \(interface) and \(proto) is the same as current settings. Will not re-apply.")
                continue
            }
            guard manager.setProtocolEntity(service: service!, interface: interface, proto: proto, config: subconfig) else {
                return false
            }
            // Indicate we changed settings and should call apply
            changed = true
        }
        /* Configs for all protocols have been set or nothing changed
        if we make it here, so now apply */
        if changed {
            guard manager.apply() else {
                return false
            }
        }
        // Configs for all protocols have been applied properly if we make it here
        return true
    }
}
