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

//  Copyright © 2024-2025 Apple, Inc. All rights reserved.
//

import Foundation
import IOKit
import MobileGestaltPrivate

struct PCCVREError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}

extension Main {
    private static func getSysctlByName(_ name: String) throws -> Int {
        try Globals.computer.sysctlValue(name)
    }

    private static func validateOSVersionRequirementForVRE() throws {
        let productVersion = MobileGestalt.current.productVersion
        guard let productVersion = productVersion else {
            throw PCCVREError("You should be running macOS >= 15.0.")
        }
        let firstComponent = productVersion.components(separatedBy: ".").first
        guard let firstComponent = firstComponent else {
            throw PCCVREError("macOS version \(productVersion) not supported. You should be running macOS >= 15.0.")
        }
        let productVersionNumber = Int(firstComponent)
        guard let productVersionNumber = productVersionNumber else {
            throw PCCVREError("macOS version \(productVersion) not supported. You should be running macOS >= 15.0.")
        }
        guard productVersionNumber >= 15 else {
            throw PCCVREError("macOS version \(productVersion) not supported. You should be running macOS >= 15.0.")
        }
    }

    public static let requiredMemoryGBHost = 2

    static func validateRequiredMemory(
        requiredMemoryGB: Int,
        consumedMemoryGB: Int
    ) throws {
        do {
            try _validateRequiredMemory(requiredMemoryGB: requiredMemoryGB,
                                        consumedMemoryGB: consumedMemoryGB)
        } catch {
            if os_variant_allows_internal_security_policies(applicationName) {
                fputs("Warning:\n\(error)\n", stderr)
            } else {
                throw error
            }
        }
    }

    private static func _validateRequiredMemory(
        requiredMemoryGB: Int,
        consumedMemoryGB: Int
    ) throws {
        let memoryGB: Int
        do {
            memoryGB = try Self.memoryGB()
        } catch {
            throw PCCVREError("Failed to validate hardware requirements - \(error)")
        }

        if memoryGB < (requiredMemoryGB + consumedMemoryGB) {
            let consumedMemoryMessage = if (consumedMemoryGB > 0) {
                "other running VRE instances use \(consumedMemoryGB)GB, "
            } else {
                ""
            }
            let error = """
            This command requires more Unified Memory than available.
            This command requires \(requiredMemoryGB)GB, \(consumedMemoryMessage)this device has \(memoryGB)GB.
            """

            throw PCCVREError(error)
        }
    }

    static func memoryGB() throws -> Int {
        try getSysctlByName("hw.memsize") / (1024 * 1024 * 1024)
    }

    // Checks whether we're on an internal build, or "allow-research-guests" is enabled via csrutil
    static func allowedToRunVRE() throws {
        try validateOSVersionRequirementForVRE()

        if os_variant_allows_internal_security_policies(applicationName) {
            return
        }

        var sipStatus: UInt64 = 0
        let result = bootpolicy_get_sip_flags(
            bootpolicy_default_policy_volume_path_value,
            bootpolicy_root_volume_uuid_value,
            &sipStatus
        )
        guard BOOTPOLICY_SUCCESS == result else {
            throw PCCVREError("Failed to get SIP flag from bootpolicy: \(result)")
        }

        let mask = UInt64(CSR_ALLOW_RESEARCH_GUESTS)
        guard mask == (sipStatus & mask) else {
            throw PCCVREError("allow-research-guests is currently disabled; Please go to recovery and run 'csrutil allow-research-guests enable'")
        }
    }
}
