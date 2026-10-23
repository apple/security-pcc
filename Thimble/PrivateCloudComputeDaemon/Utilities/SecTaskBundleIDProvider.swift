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
//  SecTaskBundleIDProvider.swift
//  PrivateCloudCompute
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import PrivateCloudCompute
import Security_Private
import os

private let logger = Logger(for: .daemon)

/// Resolves bundle identifiers using the SecTask framework to obtain the code-signing
/// identity and determine whether the calling process is an Apple-signed binary.
///
/// Unlike ``LegacyBundleIDProvider``, which returns pre-redacted identifiers without
/// provenance information, this provider classifies each identifier by its signing
/// provenance (platform binary, Apple-signed, or third-party).
struct SecTaskBundleIDProvider: BundleIDProviderProtocol {
    /// Derives the bundle identifier from an audit token using the SecTask framework
    /// to determine the signing identity and whether the binary is Apple-signed.
    func bundleIdentifier(for auditToken: audit_token_t) throws -> BundleIdentifier {
        let secTask = auditToken.secTask
        let signingIdentifier = try secTask.signingIdentifier
        let codeSignStatus = secTask.codeSignStatus

        let isSigned = codeSignStatus.contains(.valid) && codeSignStatus.contains(.signed)

        let provenance: BundleIdentifier.Provenance
        if isSigned && codeSignStatus.contains(.platformBinary) {
            provenance = .platformBinary
        } else if isSigned && signingIdentifier.starts(with: "com.apple.") {
            provenance = .appleIdentifier
        } else {
            provenance = .thirdParty
        }

        return BundleIdentifier(rawValue: signingIdentifier, provenance: provenance)
    }

    /// Derives the bundle identifier from a process ID using the SecTask framework
    /// to determine the signing identity and whether the binary is Apple-signed.
    ///
    /// Requires the `com.apple.system-task-ports.name.safe` entitlement.
    func bundleIdentifier(for pid: pid_t) -> BundleIdentifier {
        do {
            let taskName = try pid.taskName
            defer { mach_port_deallocate(mach_task_self_, taskName) }
            let auditToken = try taskName.auditToken
            return try bundleIdentifier(for: auditToken)
        } catch {
            logger.error("Failed to resolve bundle id from pid \(pid): \(error)")
            return BundleIdentifier(rawValue: "sectask_failure", provenance: .unknown)
        }
    }
}

// MARK: - SecTask Helpers

extension audit_token_t {
    /// Create SecTask via `SecTaskCreateWithAuditToken`
    fileprivate var secTask: SecTask {
        guard let task = SecTaskCreateWithAuditToken(kCFAllocatorDefault, self) else {
            /// Per the documentation, this only fails if malloc fails, so
            /// we treat a nil return as a fatal error (same approach as CloudCore).
            fatalError("SecTaskCreateWithAuditToken returned nil (malloc failure)")
        }
        return task
    }
}

extension SecTask {
    /// Get signing ID via `SecTaskCopySigningIdentifier`
    fileprivate var signingIdentifier: String {
        get throws {
            guard let identifier = SecTaskCopySigningIdentifier(self, nil) else {
                throw PrivateCloudComputeError(message: "could not get signing identifier for SecTask")
            }
            return String(identifier)
        }
    }

    fileprivate struct CodeSignStatus: OptionSet {
        let rawValue: UInt32

        // Equivalents to constants in cs_blobs.h
        static let valid = CodeSignStatus(rawValue: 0x0000_0001)  // CS_VALID: dynamically valid
        static let signed = CodeSignStatus(rawValue: 0x2000_0000)  // CS_SIGNED: process has a signature (may have gone invalid)
        static let platformBinary = CodeSignStatus(rawValue: 0x0400_0000)  // CS_PLATFORM_BINARY: this is a platform binary
    }
    fileprivate var codeSignStatus: CodeSignStatus {
        return CodeSignStatus(rawValue: SecTaskGetCodeSignStatus(self))
    }

}

extension pid_t {
    /// Get mach_port_t from PID via `task_name_for_pid`.
    /// This will throw if there is no process with this pid.
    ///
    /// Requires the `com.apple.system-task-ports.name.safe` entitlement on the calling process.
    fileprivate var taskName: mach_port_t {
        get throws(MachError) {
            var taskName: mach_port_t = 0
            let kr = task_name_for_pid(mach_task_self_, self, &taskName)
            guard kr == KERN_SUCCESS else {
                throw MachError(uncheckedCode: kr)
            }
            return taskName
        }
    }
}

extension mach_port_t {
    /// Get audit_token_t via `task_info`
    fileprivate var auditToken: audit_token_t {
        get throws(MachError) {
            var auditToken = audit_token_t()
            var size = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &auditToken) { tokenPtr in
                tokenPtr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                    task_info(self, task_flavor_t(TASK_AUDIT_TOKEN), intPtr, &size)
                }
            }
            guard kr == KERN_SUCCESS else {
                throw MachError(uncheckedCode: kr)
            }
            return auditToken
        }
    }
}

// Copied from FoundationAdditions
extension MachError {
    /// Initialize an instance of `MachError` with the specified raw error code
    /// even if it does not equate to any enumerated case of `MachError.Code`.
    ///
    /// - Parameters:
    ///     - code: The underlying Mach error code to use. Do not pass
    ///         `KERN_SUCCESS`.
    ///     - userInfo: A user info dictionary to set on the new error.
    ///
    /// This initializer is necessary because `MachError.Code` is not
    /// exhaustive and cannot represent all known or valid Mach error codes.
    /// This is a known issue in Foundation.
    fileprivate init(uncheckedCode code: mach_error_t, userInfo: [String: Any] = [:]) {
        precondition(code != KERN_SUCCESS)

        // Check if a simple conversion is possible.
        if let machErrorCode = MachError.Code(rawValue: code) {
            self = MachError(machErrorCode, userInfo: userInfo)
        } else {
            // MachErrorCode is incorrectly specified as an enum in the
            // stdlib instead of as a struct, which is unfortunate because
            // mach error codes use the high bits of kern_return_t to store
            // additional information and extracting the raw code cannot be
            // done correctly in Swift because it requires the use of complex
            // C macros from mach/error.h. Sigh.
            self = NSError(domain: NSMachErrorDomain, code: Int(code), userInfo: userInfo) as! MachError
        }
    }
}
