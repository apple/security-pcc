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
//  SystemLog.swift
//  darwinOSBits
//
//
import Foundation
import LoggingSupport

protocol SystemLog {
    func set(privacyLevel: DInitSystemLogPrivacyLevel) -> Bool
    func set(enabled: Bool) -> Bool
}

fileprivate let logd_admin_operation_block_writes: UInt64 = 7
fileprivate let logd_admin_operation_unblock_writes: UInt64 = 8
fileprivate let LOGD_ADMIN_OPERATION = "operation"
fileprivate let logdPrefsPath = URL(filePath: "/Library/Preferences/Logging/com.apple.logd.plist")
fileprivate let LOGD_STATUS = "st"

// Update a key in the logd config plist, keeping other keys if the plist already exists
fileprivate func updateBoolLogdConfigPlist(key: String, val: Bool) -> Bool {
    let properties = NSMutableDictionary(contentsOf: logdPrefsPath) ?? NSMutableDictionary()
    properties[key] = val

    do {
        try properties.write(to: logdPrefsPath)
        return true
    } catch {
        logger.error("Failed to write update key \(key, privacy: .public) to val \(val)")
        return false
    }
}

fileprivate func updateSnapshotEnablement(to newVal: Bool) -> Bool {
    return updateBoolLogdConfigPlist(key: "enableSnapshot", val: newVal)
}

// MARK: - RealSystemLog
class RealSystemLog: SystemLog {
    func set(privacyLevel: DInitSystemLogPrivacyLevel) -> Bool {
        let profile: [AnyHashable : Any] = ["System": ["Privacy-Set-Level": privacyLevel.rawValue]]
        let installError : ErrorPointer = nil

        guard OSLogInstallProfilePayload(profile, installError) else {
            logger.error("Failed to set system logging level to \(privacyLevel.rawValue) due to: \(installError?.pointee?.localizedDescription ?? "Unknown")")
            return false
        }
        logger.log("Set system logging level to \(privacyLevel.rawValue)")
        return true
    }

    func set(enabled isEnabled: Bool) -> Bool {
        // Create xpc connection with logd
        let connection = xpc_connection_create_mach_service("com.apple.logd.admin", nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        xpc_connection_set_event_handler(connection, { (_) in
            logger.log("Received message from logd")
        })
        xpc_connection_activate(connection)
        let xdict = xpc_dictionary_create(nil, nil, 0)

        // If logging is enabled, unblock writes, else block them
        let op = (isEnabled) ? logd_admin_operation_unblock_writes : logd_admin_operation_block_writes
        xpc_dictionary_set_uint64(xdict, LOGD_ADMIN_OPERATION, op)
        // Set up strings for log messages
        let writeAction = (isEnabled) ? "unblock" : "block"
        let snapshotAction = (isEnabled) ? "enable" : "disable"

        // Unfortunately have to enable/disable snapshots separately, as they're managed through a different flow
        guard updateSnapshotEnablement(to: isEnabled) else {
            logger.error("Failed to \(snapshotAction) snapshots")
            return false
        }

        let response = xpc_connection_send_message_with_reply_sync(connection, xdict)
        guard xpc_get_type(response) != XPC_TYPE_ERROR else {
            if let err:UnsafePointer<CChar> = xpc_dictionary_get_string(response, _xpc_error_key_description) {
                logger.error("Failed to \(writeAction) writes: \(String.init(cString: err))")
                return false
            }
            logger.error("Failed to \(writeAction) writes: unknown error.")
            return false
        }
        guard xpc_get_type(response) == XPC_TYPE_DICTIONARY else {
            logger.error("Failed to \(writeAction) writes: Got unexpected response from logd")
            return false
        }
        let status = xpc_dictionary_get_int64(response, LOGD_STATUS)
        guard status == 0 else {
            logger.error("Failed to \(writeAction) writes: Got status of \(status) from logd")
            return false
        }
        logger.log("Successfully \(writeAction)ed writes and \(snapshotAction)d snapshots.")
        return true
    }
}
