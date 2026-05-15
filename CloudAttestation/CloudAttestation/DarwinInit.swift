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
//  DarwinInit.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import os.log

/// A struct that contains the parameters provided by `darwin-init`.
public struct DarwinInit: Sendable {
    static let logger = Logger(subsystem: "com.apple.CloudAttestation", category: "DarwinInit")

    /// The parameters provided by `darwin-init`.
    public let parameters: [String: any Sendable]

    /// The `SecureConfigSecurityPolicy` provided by `config-security-policy`.
    public let securityPolicy: SecureConfigSecurityPolicy

    /// The set of ensemble X.509 certificate fingerprints returned as a list of ``Data``. Is nil if not found or unparsable.
    public var ensembleCertificateFingerprints: [Data]? {
        guard let secureConfig = self.parameters["secure-config"] as? [String: Any] else {
            return nil
        }
        guard let b64Array = secureConfig["com.apple.CloudAttestation.ensembleMembers"] as? [String] else {
            return nil
        }

        let fingerprints = b64Array.compactMap { Data(base64Encoded: $0) }
        guard fingerprints.count == b64Array.count else {
            Self.logger.error("Invalid formatted data in com.apple.CloudAttestation.ensembleMembers")
            return nil
        }

        return fingerprints
    }

    /// The routing hint provided by `darwin-init` or cfPrefs
    public var routingHint: String? {
        secureConfigRoutingHint ?? cfPrefsRoutingHint
    }

    /// The routing hint provided by `config-security-policy`.
    public var secureConfigRoutingHint: String? {
        guard let secureConfig = self.parameters["secure-config"] as? [String: Any] else {
            return nil
        }
        return secureConfig["com.apple.CloudAttestation.routingHint"] as? String
    }

    public var cfPrefsRoutingHint: String? {
        guard let preferences = self.parameters["preferences"] as? [[String: Any]] else {
            return nil
        }
        let cellID = preferences.first { (pref: [String: Any]) in
            (pref["application_id"] as? String) == "com.apple.cloudos" && (pref["key"] as? String == "cellID")
        }
        guard let cellID else {
            return nil
        }

        return cellID["value"] as? String
    }

    /// Creates a new `DarwinInit` instance.
    /// - Parameter config: The `SecureConfig` instance.
    public init(from config: SecureConfig) throws {
        guard config.mimeType == "application/json" else {
            throw Error.wrongMimeType
        }

        guard config.name == "darwin-init" else {
            throw Error.wrongEntryName
        }

        let jsonObject = try JSONSerialization.jsonObject(with: config.entry)
        guard let parameters = jsonObject as? [String: any Sendable] else {
            throw Error.malformedSecureConfig
        }
        self.parameters = parameters

        let securityPolicyValue = parameters["config-security-policy"]

        switch securityPolicyValue {
        case .none:
            self.securityPolicy = .none

        case is NSNull:
            self.securityPolicy = .none

        case let stringValue as String:
            guard let securityPolicy = SecureConfigSecurityPolicy(rawValue: stringValue) else {
                fallthrough
            }
            self.securityPolicy = securityPolicy

        default:
            throw Error.invalidParameterValue(parameter: "config-security-policy")
        }
    }
}

// MARK: - Known keys
extension DarwinInit {
    /// Enumerates the known set of values `config-security-policy` can have in darwin-init.
    public enum SecureConfigSecurityPolicy: String, CaseIterable, Sendable, Codable {
        case none
        case carry
        case customer
        case customerProxy
    }
}

// MARK: - Error API

extension DarwinInit {
    enum Error: LocalizedError {
        case wrongEntryName
        case wrongMimeType
        case noSecureConfigDB
        case malformedSecureConfig
        case missingParameter(name: String)
        case invalidParameterValue(parameter: String)
        case missingDarwinInit
        case tooManyDarwinInit

        var errorDescription: String? {
            switch self {
            case .wrongEntryName:
                "SecureConfigDB entry has wrong \"name\""
            case .wrongMimeType:
                "SecureConfigDB entry has wrong \"mime_type\""

            case .noSecureConfigDB:
                "SecureConfigDB is not available on this system"

            case .malformedSecureConfig:
                "SecureConfigDB entry does not match expected JSON schema"

            case .invalidParameterValue(let parameter):
                "SecureConfigDB entry contains invalid value for parameter \"\(parameter)\""

            case .missingParameter(let name):
                "SecureConfigDB entry missing required field \"\(name)\""
            case .missingDarwinInit:
                "darwin-init missing from SecureConfigDB"

            case .tooManyDarwinInit:
                "SecureConfigDB contains more than one darwin-init entry"
            }
        }
    }
}
