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
//  PCCRegoValidator.swift
//  DarwinInit
//
//

import Foundation
import os
private import DarwinInitOPA
@_spi(Private) import SecureConfigDB

public enum ConfigSecurityPolicy: String, CaseIterable {
    /// Config must be validated to ensure secure and private handling of **customer** data.
    case customer
    /// Config must be validated to ensure secure and private handling of **customerProxy** data.
    case customerProxy
    /// Config must be validated to ensure secure and private handling of **internal carry / live-on** data.
    case carry
    /// Config should not be validated
    case none
}

// MARK: - Rego input
// Metadata in Rego input for indicating if validator is running on vm, other info in future
struct PCCRegoMetaInput: Codable, Equatable, Hashable {
    enum CodingKeys: String, CodingKey {
        case isVM = "is_vm"
    }
    let isVM : Bool
}

/* Structured Rego input including darwin-init config and metadata
 Example:
 {
   "darwin-init": [
     {
       "config_security_policy": {
         "policy": "customer"
       },
       ...
     },
     {
       "config_security_policy": {
         "policy": "customer"
       },
       ...
     },
     ...
   ]
 }
 */
struct PCCRegoInput: Codable, Equatable, Hashable {
    enum CodingKeys: String, CodingKey {
        case darwinInit = "darwin-init"
        case meta = "meta"
    }
    var darwinInit : [Config]
    var meta : PCCRegoMetaInput
}

extension PCCRegoInput {
    func jsonString(prettyPrinted: Bool = true, redacted: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted {
            encoder.outputFormatting.insert(.prettyPrinted)
        }
        if !redacted {
            encoder.userInfo[CredentialString.redactionOverrideKey] = true
        }
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Rego output
/* Rego policy evaluation result containing validity status, errors, and warnings
 Example:
 {
   "errors": {
     "0": {
       "ssh.enabled": "Enabling ssh daemon not permitted. ssh.enabled must be unset or false",
       "log.persist": "Logging to disk and snapshots must be disabled by setting log.persist to false"
     },
     "1": {
       "log.privacy_level": "log.privacy_level may only be set in config 0"
     }
   },
   "is_valid": false,
   "warnings": {},
   "net_secure_config": {
     "com.apple.logging.crashRedactionEnabled": true,
     "com.apple.logging.logFilteringEnforced": true
   }
 }
 */
public struct PCCRegoPolicyEvaluationResult: Codable, Equatable {
    enum CodingKeys: String, CodingKey {
        case errors
        case warnings
        case isValid = "is_valid"
        case netSecureConfig = "net_secure_config"
    }
    // Dictionary: config_index -> (key_path -> error_message)
    public let errors: [Int: [String: String]]
    public let warnings: [Int: [String: String]]
    public let isValid: Bool
    // Merged secure_config from all configs (only non-conflicting keys)
    public let netSecureConfig: JSON?
}

public struct PCCRegoPolicyEvaluationOutput: Codable, Equatable {
    public let result: PCCRegoPolicyEvaluationResult
}

struct PCCRegoValidatorError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

public class PCCRegoValidator {
    var configs: [Config]
    var logger: Logger
    var bundlePath: String

    // Merged secure_config from all configs (only non-conflicting keys)
    // Available after validate() is called
    private(set) public var mergedSecureConfig: JSON?

    init(configs: [Config], bundlePath: String = kDInitValidatorBundle) {
        self.logger = Logger.pccRegoValidator
        self.configs = configs
        self.bundlePath = bundlePath
        self.mergedSecureConfig = nil
    }

    func validate() async throws -> PCCRegoPolicyEvaluationResult {
        // init the Rego OPA engine using the IR bundle path
        let bundlePath = URL(fileURLWithPath: self.bundlePath, isDirectory: true)
        let bundle = OPA.Engine.BundlePath(name: "pcc-customer-bundle", url: bundlePath)
        var engine = OPA.Engine(bundlePaths: [bundle])

        // init Rego input including meta data indicating if this is a vm
        let input = PCCRegoInput(darwinInit: self.configs, meta: PCCRegoMetaInput(isVM: RealComputer.shared.isVM))

        let prettyInput = try input.jsonString()
        logger.info("Evaluating Rego input: \(prettyInput)")

        let encoder = JSONEncoder()
        let jsonInput = try encoder.encode(input)
        let regoInput = try RegoValue(jsonData: jsonInput)

        // evaluate the input
        let policyQuery = "data.policy.main.validate"
        let prepared = try await engine.prepareForEvaluation(query: policyQuery)
        let result = try await prepared.evaluate(input: regoInput, strictBuiltins: true)

        // encode RegoValue result as JSON, decode to PCCRegoPolicyEvaluationOutput
        let jsonResult = try encoder.encode(result.first)
        let evalOutput = try JSONDecoder().decode(PCCRegoPolicyEvaluationOutput.self, from: jsonResult)

        logger.debug("PCCRegoValidator evaluation result: \(evalOutput.result.isValid ? "valid" : "invalid")")

        logger.debug("PCCRegoValidator evaluation result warnings: \(evalOutput.result.warnings)")

        logger.debug("PCCRegoValidator evaluation result errors: \(evalOutput.result.errors)")

        // Store the merged secure_config for later use by Apply
        self.mergedSecureConfig = evalOutput.result.netSecureConfig

        return evalOutput.result
    }
}
