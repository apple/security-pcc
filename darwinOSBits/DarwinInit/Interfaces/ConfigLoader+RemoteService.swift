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
//  ConfigLoader+RemoteService.swift
//  darwinOSBits
//
//

import Foundation
import RemoteServiceDiscovery

// MARK: - Remote Service Discovery
extension ConfigLoader {
    /// Load configuration data from a remote service.
    func loadRemoteService(from deviceTypeDesc: String, serviceName: String) throws -> Data {
        let queue = DispatchQueue(label: "remote_device_browse")
        let semaphore = DispatchSemaphore(value: 0)
        var configData: Data = Data()
        var _device: remote_device_t? = nil

        let deviceType = remote_device_type_parse(deviceTypeDesc)
        guard deviceType != REMOTE_DEVICE_TYPE_INVALID_OR_UNKNOWN else {
            throw RemoteDeviceTypeError.invalidDeviceTypeDesc(deviceTypeDesc)
        }

        var flag = atomic_flag()

        let browser = remote_device_start_browsing(deviceType, queue) { device, canceling in
            if canceling {
                return
            }

            remote_device_set_connected_callback(device!, queue) { device in
                if atomic_flag_test_and_set_explicit(&flag, memory_order_relaxed) {
                    // timed out, bail
                    return
                }
                _device = device
                semaphore.signal()
            }
        }
        defer {
            remote_device_browser_cancel(browser)
        }

        switch semaphore.wait(timeout: DispatchTime.now() + .seconds(120)) {
        case .success:
            let deviceName = String(cString: remote_device_get_name(_device!))
            logger.info("remote device found: \(deviceName)")
        case .timedOut:
            if atomic_flag_test_and_set_explicit(&flag, memory_order_relaxed) {
                // the callback has been fired but not signaled yet.
                // it's safe to wait for that forever here
                semaphore.wait()
            } else {
                logger.error("timeout waiting for remote device to show up")
                throw Error.loadTimeout(.remoteService(device: deviceTypeDesc, service: serviceName))
            }
        }

        configData = try DInitRemoteService.fetchConfig(from: _device!, service: serviceName)
        logger.debug("Raw data got from remote service: \(configData)")
        return configData
    }

    // MARK: Factory
    /// Load configuration data from a factory remote service.
    func loadFactoryConfig() async throws -> Data {
        logger.log("Loading configuration from factory remote service")

        let deviceTypeDesc = String(cString: remote_device_type_get_description(computer.isComputeNode ? REMOTE_DEVICE_TYPE_COMPUTE_CONTROLLER : REMOTE_DEVICE_TYPE_NCM_HOST))
        return try loadRemoteService(from: deviceTypeDesc, serviceName: kDInitFactoryRemoteServiceName)
    }

    // MARK: Compute Node
    func loadCNodeConfig() async throws -> [DecodedData]? {
        logger.info("Loading configuration from remote service")

        let data: Data
        do {
            let deviceTypeDesc = String(cString: remote_device_type_get_description(REMOTE_DEVICE_TYPE_COMPUTE_CONTROLLER))
            data = try loadRemoteService(from: deviceTypeDesc, serviceName: kDInitRemoteServiceName)
        } catch {
            logger.error("Failed to load configuration from \(kDInitRemoteServiceName): \(error)")

            if computer.isFactorySignedRestore {
                logger.log("Falling back to use factory endpoint")
                data = try await loadFactoryConfig()
            } else {
                throw error
            }
        }

        do {
            return try decode(data: data, at: [])
        } catch {
            logger.warning("Data from remote service is not valid: \(error)")
            throw error
        }
    }
}
