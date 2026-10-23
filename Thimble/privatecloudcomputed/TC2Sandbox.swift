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
//  TC2Sandbox.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
import SandboxPrivate
private import TC2DaemonDependencies.DirHelperPrivate
import os.log

private let logger = Logger(for: .sandbox)

protocol TC2Sandbox {

}

extension TC2Sandbox {
    #if os(macOS)
    static var sandboxParameters: [String: String] {

        let homeDirectory: String
        if let home = NSHomeDirectory().realpath {
            homeDirectory = home
        } else {
            logger.error("User does not have a home directory! -- Faling back to /private/var/empty")
            homeDirectory = "/private/var/empty"
        }

        guard let tempDirectory = Self.confstr(_CS_DARWIN_USER_TEMP_DIR)?.realpath else {
            fatalError("Unable to read _CS_DARWIN_USER_TEMP_DIR")
        }

        guard let cacheDirectory = Self.confstr(_CS_DARWIN_USER_CACHE_DIR)?.realpath else {
            fatalError("Unable to read _CS_DARWIN_USER_CACHE_DIR")
        }

        return [
            "HOME": homeDirectory,
            "DARWIN_USER_TEMP_DIR": tempDirectory,
            "DARWIN_USER_CACHE_DIR": cacheDirectory,
        ]
    }

    static func flatten(_ dictionary: [String: String]) -> [String] {
        return dictionary.flatMap { [$0, $1] }
    }

    private static func _sandboxInit(profile: String, parameters: [String: String]) {

        var sbError: UnsafeMutablePointer<Int8>?
        let flatParameters = flatten(parameters)
        logger.log("Sandbox parameters: \(String(describing: parameters))")
        withArrayOfCStrings(flatParameters) { ptr -> Void in
            let result = sandbox_init_with_parameters(profile, UInt64(SANDBOX_NAMED), ptr, &sbError)
            guard result == 0 else {
                guard let sbError = sbError else {
                    fatalError("sandbox_init_with_parameters failed: (no error)")
                }
                fatalError("sandbox_init_with_parameters failed: [\(String(cString: sbError))]")
            }
        }

        _ = sbError
    }

    // For calling C functions with arguments like: `const char *const parameters[]`
    static func withArrayOfCStrings<R>(_ args: [String], _ body: ([UnsafePointer<CChar>?]) -> R) -> R {
        let mutableStrings = args.map { strdup($0) }
        var cStrings = mutableStrings.map { UnsafePointer($0) }
        defer {
            for mutableString in mutableStrings {
                free(mutableString)
            }
        }
        cStrings.append(nil)
        return body(cStrings)
    }

    #endif

    static func confstr(_ name: Int32) -> String? {
        var directory = Data(repeating: 0, count: Int(PATH_MAX))

        return directory.withUnsafeMutableBytes { body -> String? in
            let status = Darwin.confstr(name, body.bindMemory(to: Int8.self).baseAddress, Int(PATH_MAX))

            guard status > 0 else {
                return nil
            }

            guard let boundBuffer = body.bindMemory(to: Int8.self).baseAddress else {
                return nil
            }

            return String(cString: boundBuffer)
        }
    }

    static func enterSandbox(identifier: String, macOSProfile: String) {
        // Set user dir (tmp) suffix on both iOS and macOS
        guard _set_user_dir_suffix(identifier) else {
            fatalError("_set_user_dir_suffix() failed")
        }

        // call confstr to initialize the directory and env var on all platforms
        guard Self.confstr(_CS_DARWIN_USER_TEMP_DIR) != nil else {
            fatalError("Unable to read _CS_DARWIN_USER_TEMP_DIR")
        }

        // On macOS, we own the profile and initialize it ourselves.
        // On iOS, this is done automatically by the OS for us.
        #if os(macOS)
        _sandboxInit(profile: macOSProfile, parameters: sandboxParameters)
        #endif
    }
}

extension String {
    fileprivate var realpath: String? {
        let retValue: String?

        guard let real = Darwin.realpath(self, nil) else {
            return nil
        }

        retValue = String(cString: real)
        real.deallocate()

        return retValue
    }
}
