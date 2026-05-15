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
//  LibSecureConfig.swift
//  DarwinInit
//

import Foundation
internal import DarwinInitBridging

enum LibSecureConfigError: Error {
	case configCommitFailed(code: Int32)
}

extension LibSecureConfigError: CustomStringConvertible {
	var description: String {
		switch self {
		case .configCommitFailed(let code):
			return "LibSecureConfig failed to commit with code \(code)"
		}
	}
}
	
enum LibSecureConfig {

    static func commit(config: Config, to computer: Computer) throws {

        if let origin = config.origin, origin.loadingPath.version == .v1 {
            // TODO: manually construct a V1 from a V2 and commit it
            let v1 = try JSEnumDecoder.decode(DInitConfig.self, from: origin.source)
            try commitConfig(v1, to: computer)
            return
        }

        let attested = attested(config: config)
        let json = try attested.jsonString(prettyPrinted: false,
                                           redacted: false)
        let data = json.data(using: .utf8)
        let error = computer.registerSecureconfig(config: data)

        guard error == 0 else {
            logger.error("Failed to register config data: \(error)")
            throw LibSecureConfigError.configCommitFailed(code: error)
        }
    }

    static func commitConfig(_ config: DInitConfig, to computer: any Computer) throws {
		let attestedConfig = attestedConfig(config)
        let attestedConfigJson = try attestedConfig.jsonString(prettyPrinted: false, redactCredentialStrings: false)
		let attestedConfigData = attestedConfigJson.data(using: .utf8)
        let secureConfigError = computer.registerSecureconfig(config: attestedConfigData)
		guard secureConfigError == 0 else {
			logger.error("Failed to register config data: \(secureConfigError)")
			throw LibSecureConfigError.configCommitFailed(code: secureConfigError)
		}
	}

    static func commitSecureConfigParameters(parameters: [String: JSON],
											 securityPolicy: String?,
                                             to computer: any Computer) throws {
		let data = try JSONEncoder().encode(parameters)
        let error = computer.registerSecureconfig(parameters: data, securityPolicy: securityPolicy)
		guard error == 0 else {
			logger.error("Failed to register secure config parameters: \(error)")
			throw LibSecureConfigError.configCommitFailed(code: error)
		}
	}

    static func attested(config: Config) -> Config {
#if os(macOS)
        return config
#else
        var result = Config()
        var security = Config.SecurityPolicy()

        security.policy = config.configSecurityPolicy?.policy
        security.version = config.configSecurityPolicy?.version
        result.configSecurityPolicy = security

        if let parameters = config.secureConfig {
            let attestedParameters = parameters.filter {
                switch $0.key {
                    // all com.apple.CloudAttestation.* keys are incldued to allow CloudAttestation
                    // to provide a generic API to query attested configuration values.
                case let key where key.hasPrefix("com.apple.CloudAttestation."):
                    return true
                case "com.apple.libcryptex.appIdentifiers":
                    return true
                default:
                    return false
                }
            }
            result.secureConfig = attestedParameters
        }

        return result
        #endif
    }

    static func attestedConfig(_ config: DInitConfig) -> DInitConfig {
#if os(macOS)
        return config
#else
        var result = DInitConfig()
        result.configSecurityPolicy = config.configSecurityPolicy
        result.configSecurityPolicyVersion = config.configSecurityPolicyVersion
        if case .dictionary(let parameters) = config.secureConfigParameters {
            let attestedParameters = parameters.filter {
                switch $0.key {
                // all com.apple.CloudAttestation.* keys are incldued to allow CloudAttestation
                // to provide a generic API to query attested configuration values.
                case let key as String where key.hasPrefix("com.apple.CloudAttestation."):
                    return true
                case "com.apple.libcryptex.appIdentifiers":
                    return true
                default:
                    return false
                }
            }
            result.secureConfigParameters = .dictionary(attestedParameters)
        }
        return result
#endif
    }


}
