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
//  Configuration+Environment.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

private import DarwinPrivate.os.variant
import Foundation
import PrivateCloudCompute
import os.log

private let logger = tc2Logger(forCategory: .configuration)

// Extends the Configuration protocol to add environment selection logic.
extension Configuration {
    package func environment(systemInfo: any SystemInfoProtocol) -> TC2Environment {
        let result: TC2Environment
        if os_variant_allows_internal_security_policies(privateCloudComputeOsVariantSubsystem) {
            result = self.internalEnvironment(systemInfo: systemInfo)
        } else {
            result = self.customerEnvironment
        }

        // rdar://128925304 (Every daemon that has a part to play in making a private cloud compute request should log the environment it thinks it's switched to)
        // The format of this string should not be changed without consulting with the various automation teams.
        // NOTE: Even if cached, we want to log this every time it is accessed.
        logger.log("current environment=\(result.name, privacy: .public)")
        return result
    }

    package var customerEnvironment: TC2Environment {
        let result = TC2Environment.production
        logger.debug("Configuration selected environment=\(result.name, privacy: .public)")
        return result
    }

    package func internalEnvironment(systemInfo: any SystemInfoProtocol) -> TC2Environment {
        precondition(os_variant_allows_internal_security_policies(privateCloudComputeOsVariantSubsystem))

        return self.configuredEnvironment ?? self.devicePreferredLiveOnEnvironment(systemInfo: systemInfo)
    }

    package var configuredEnvironment: TC2Environment? {
        precondition(os_variant_allows_internal_security_policies(privateCloudComputeOsVariantSubsystem))

        guard let environmentName = self[.environment] else {
            logger.debug("Configuration defaults absent, no environment configured")
            return nil
        }

        guard let environment = TC2Environment(name: environmentName) else {
            logger.debug("Configuration defaults=\(environmentName, privacy: .public) unrecognized, no environment configured")
            return nil
        }

        logger.info("Configuration selected configured environment=\(environmentName, privacy: .public) from defaults")
        return environment

    }

    private func devicePreferredLiveOnEnvironment(systemInfo: any SystemInfoProtocol) -> TC2Environment {
        precondition(os_variant_allows_internal_security_policies(privateCloudComputeOsVariantSubsystem))

        if !os_variant_has_internal_content(privateCloudComputeOsVariantSubsystem) {
            // On customer builds, the default environment should be
            // production, and we should not participate in the spillover
            // from the config bag.
            let result = TC2Environment.production
            logger.info("Configuration selected environment=\(result.name, privacy: .public)")
            return result
        }

        // At this point, we are on an internal build, so we need to figure out
        // the spillover value and default to carry.

        let bootSessionID = systemInfo.bootSessionID
        if let bootFixedEnv = self[.bootFixedLiveOnEnvironment] {
            let split = bootFixedEnv.split(separator: ",", maxSplits: 1)
            if split.count == 2 {
                let id = String(split[0])
                let environment = String(split[1])
                logger.debug("Configuration saw bootFixedLiveOnEnvironment with id=\(id), environment=\(environment, privacy: .public)")

                if id == bootSessionID {
                    // Here, we have a defaults with our boot id, we must always
                    // return it during this boot, so here we go
                    if let result = TC2Environment(name: environment) {
                        logger.info("Configuration agrees with current boot's selection, environment=\(environment, privacy: .public)")
                        return result
                    } else {
                        logger.error("Configuration saw bootFixedLiveOnEnvironment with invalid environment, ignoring")
                    }
                } else {
                    logger.debug("Configuration saw bootFixedLiveOnEnvironment from previous boot, ignoring")
                }
            } else {
                logger.error("Configuration saw invalid bootFixedLiveOnEnvironment=\(bootFixedEnv)")
            }
        } else {
            logger.debug("Configuration does not see bootFixedLiveOnEnvironment")
        }

        // At this point, something went wrong loading the default from
        // bootFixedLiveOnEnvironment, or it didn't exist, so we are free
        // to make a determination, and we must record it.

        if let proposal = self[.proposedLiveOnEnvironment] {
            if let result = TC2Environment(name: proposal) {
                logger.info("Configuration moving to proposed environment=\(proposal, privacy: .public)")
                self.writeBootFixedLiveOnEnvironment(bootSessionID: bootSessionID, environment: proposal)
                return result
            } else {
                logger.error("Configuration saw invalid proposed environment=\(proposal, privacy: .public), ignoring")
            }
        } else {
            logger.debug("Configuration does not see proposedEnvironment")
        }

        // Carry it is, then! The default for LiveOn

        let result = TC2Environment.carry
        logger.info("Configuration selected environment=\(result.name, privacy: .public)")
        self.writeBootFixedLiveOnEnvironment(bootSessionID: bootSessionID, environment: result.name)
        return result
    }

    private func writeBootFixedLiveOnEnvironment(bootSessionID: String, environment: String) {
        precondition(os_variant_allows_internal_security_policies(privateCloudComputeOsVariantSubsystem))

        let index = ConfigurationIndex<String?>.bootFixedLiveOnEnvironment
        let value = "\(bootSessionID),\(environment)"

        value.defaultsWrite(defaultsDomain: index.domain, name: index.name)
    }
}
