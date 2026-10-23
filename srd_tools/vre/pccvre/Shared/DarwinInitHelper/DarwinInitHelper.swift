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
import os

// DarwinInitHelper provides a high-level interface to a darwin-init.json configuration file
// Selected "providers" available for common settings made for a VRE (such as cryptex spec and SSH)

struct DarwinInitHelper {
    var configJSON: String
    let sourcePath: String?
    let pccvreHelper: PCCVREHelper

    static let logger = os.Logger(subsystem: applicationName, category: "DarwinInitHelper")

    init(config: String, pccvreHelper: PCCVREHelper) throws {
        self.configJSON = config
        self.sourcePath = nil
        self.pccvreHelper = pccvreHelper
    }

    init(configFile: String, pccvreHelper: PCCVREHelper) throws {
        let url = URL(fileURLWithPath: configFile)
        let data = try Globals.computer.fileSystem.contentsOfFile(at: url)
        guard let str = String(data: data, encoding: .utf8) else {
            throw DarwinInitHelperError("darwin-init: invalid UTF-8 in \(configFile)")
        }
        self.configJSON = str
        self.sourcePath = configFile
        self.pccvreHelper = pccvreHelper
    }

    func read<T>(command: (PCCVREHelper.DarwinInit) throws -> T, v1Fallback: ((DarwinInitConfigV1) throws -> T)? = nil) throws -> T {
        do {
            return try command(pccvreHelper.darwinInit(configJSON))
        } catch {
            guard let v1Fallback, case PCCVREHelperError.notSupported(_) = error else {
                throw error
            }
            return try v1Fallback(DarwinInitConfigV1(jsonString: configJSON))
        }
    }

    mutating func modify(command: (PCCVREHelper.DarwinInit) throws -> String,
                         v1Fallback: ((inout DarwinInitConfigV1) throws -> Void)? = nil) throws {
        do {
            configJSON = try command(pccvreHelper.darwinInit(configJSON))
        } catch {
            guard let v1Fallback, case PCCVREHelperError.notSupported(_) = error else {
                throw error
            }
            var v1 = try DarwinInitConfigV1(jsonString: configJSON)
            try v1Fallback(&v1)
            configJSON = v1.json(pretty: true)
        }
    }

    // save writes darwin-init to named path in "pretty" form
    func save(toFile: String? = nil) throws {
        guard let toFile = toFile ?? sourcePath else {
            throw DarwinInitHelperError("darwin-init write: no destination provided")
        }

        do {
            try configJSON.write(toFile: toFile, atomically: true, encoding: .utf8)
        } catch {
            throw DarwinInitHelperError("darwin-init write to \(toFile): \(error)")
        }

        DarwinInitHelper.logger.debug("wrote darwin-init to: \(toFile, privacy: .public)")
        DarwinInitHelper.logger.debug("darwin-init: \(configJSON, privacy: .public)")
    }
}

extension DarwinInitHelper {
    func localHostname() throws -> String? {
        try read {
            let localHostname = try $0.localHostname()
            return localHostname == "" ? nil : localHostname
        } v1Fallback: {
            $0.localHostname
        }
    }

    mutating func setLocalHostname(_ localHostname: String) throws {
        try modify {
            try $0.setLocalHostname(localHostname)
        } v1Fallback: {
            $0.localHostname = localHostname
        }
    }
}

extension DarwinInitHelper {
    mutating func mergeConfig(overrideDarwinInit: String) throws {
        try modify {
            try $0.mergeConfig(overrideDarwinInit: overrideDarwinInit)
        }
    }
}

// DarwinInitHelperError provides general error encapsulation for errors encountered within DarwinInitHelper
struct DarwinInitHelperError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }

    init(_ message: String) {
        DarwinInitHelper.logger.error("\(message, privacy: .public)")
        self.message = message
    }
}
