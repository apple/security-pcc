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

import CFPreferenceCoder
import CloudBoardCommon
import CloudBoardLogging
import Foundation
import os

extension CFPreferences {
    static var cbJobHelperPreferencesDomain: String {
        "com.apple.cloudos.cb_jobhelper"
    }
}

public struct CBJobHelperConfiguration: Codable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case _cloudAppName = "CloudAppName"
        case _enforceTGTValidation = "EnforceTGTValidation"
        case _proxyConfiguration = "ProxyConfiguration"
        case _enablePIR = "EnablePIR"
        case _effortPrivacy = "EffortPrivacy"
        // deliberately *not* serialising _secureConfig
    }

    /// Name to search for in the `CloudBoardJobName` field in the `_AdditionalProperties` launchd plist to discover
    /// the cloud app process.
    var _cloudAppName: String?
    var cloudAppName: String {
        get { self._cloudAppName ?? "TIECloudApp" }
        set { self._cloudAppName = newValue }
    }

    var _enforceTGTValidation: Bool?
    /// If true, cb_jobhelper fails requests that fail Token Granting Token (TGT) validation. Otherwise, requests with
    /// invalid TGT are still processed.
    var enforceTGTValidation: Bool {
        get { self._enforceTGTValidation ?? false }
        set { self._enforceTGTValidation = newValue }
    }

    var _proxyConfiguration: ProxyConfiguration?

    var proxyConfiguration: ProxyConfiguration {
        get { self._proxyConfiguration ?? ProxyConfiguration() }
        set { self._proxyConfiguration = newValue }
    }

    var _enablePIR: Bool?
    var enablePIR: Bool {
        get { self._enablePIR ?? false }
        set { self._enablePIR = newValue }
    }

    var _effortPrivacy: EffortPrivacyConfiguration?
    var effortPrivacy: EffortPrivacyConfiguration {
        get { self._effortPrivacy ?? EffortPrivacyConfiguration() }
        set { self._effortPrivacy = newValue }
    }

    private var _secureConfig: SecureConfig? = nil
    /// The secure config is only available once it has been hooked up and validated
    /// This happens very early on in the setup so most consuming code can just assume this is set
    var secureConfig: SecureConfig {
        /// Attempting to do this in a real run means we didn't apply security checks, this should be instantly terminal
        precondition(self._secureConfig != nil, "Attempt to access secureconfig when it has not been hooked up")
        return self._secureConfig!
    }

    /// What sort of role this helper will be providing
    /// If not supplied this is assumed to be a worker
    /// we cannot determine if we are a nack processing instance from this
    /// so we just don't bother for now
    var isProxy: Bool {
        /// Attempting to do this in a real run means we didn't apply security checks, this should be instantly terminal
        precondition(self._secureConfig != nil, "Attempt to access secureconfig when it has not been hooked up")
        return self._secureConfig!.isProxy
    }

    /// This is not for direct use except in tests
    /// It *does not validate* `secureconfig`
    internal init(
        secureConfig: SecureConfig,
        cloudAppName: String? = nil,
        enforceTGTValidation: Bool? = nil
    ) {
        self._secureConfig = secureConfig
        self._cloudAppName = cloudAppName
        self._enforceTGTValidation = enforceTGTValidation
    }

    public static func fromPreferences(secureConfigLoader: SecureConfigLoader = .real) throws
    -> CBJobHelperConfiguration {
        CloudBoardJobHelper.logger
            .info(
                "Loading configuration from preferences \(CFPreferences.cbJobHelperPreferencesDomain, privacy: .public)"
            )
        let preferences = CFPreferences(domain: CFPreferences.cbJobHelperPreferencesDomain)
        do {
            return try .fromPreferences(preferences, secureConfigLoader: secureConfigLoader)
        } catch {
            CloudBoardJobHelper.logger
                .error(
                    "Error loading configuration from preferences: \(String(reportable: error), privacy: .public) (\(error))"
                )
            throw error
        }
    }

    private mutating func applySecureConfig(_ secureConfig: SecureConfig) throws {
        self._secureConfig = secureConfig
        // after setting up everything else validate
        if secureConfig.shouldEnforceAppleInfrastructureSecurityConfig {
            try self.enforceSecurityConfig()
        }
    }

    private mutating func enforceSecurityConfig() throws {
        CloudBoardJobHelper.logger.debug("Enforcing security config")
        // currently nothing requires enforcing
    }

    static func fromPreferences(
        _ preferences: CFPreferences,
        secureConfigLoader: SecureConfigLoader
    ) throws -> CBJobHelperConfiguration {
        let decoder = CFPreferenceDecoder()
        var configuration = try decoder.decode(CBJobHelperConfiguration.self, from: preferences)

        let secureConfig: SecureConfig
        do {
            CloudBoardJobHelper.logger.info("Loading secure config from SecureConfigDB")
            secureConfig = try secureConfigLoader.load()
        } catch {
            CloudBoardJobHelper.logger.error(
                "Error loading secure config: \(String(unredacted: error), privacy: .public)"
            )
            throw error
        }
        try configuration.applySecureConfig(secureConfig)
        return configuration
    }
}

/// Note: "EnableReleaseSetValidation" used to be enforced in the helper, so the config was here
/// It's now done in the AttestationDaemon, and config is done via SecureConfig with a fallback here
/// We retain the ProxyConfiguration object for a while in case some other proxy specific config comes up
extension CBJobHelperConfiguration {
    struct ProxyConfiguration: Codable, Hashable, Sendable {}

    /// Configuration for privacy-preserving effort degradation
    /// These values control how ideal effort calculations are converted into noisier,
    /// granular values before being sent to ROPES for routing decisions.
    public struct EffortPrivacyConfiguration: Codable, Hashable, Sendable {
        enum CodingKeys: String, CodingKey {
            case denominator = "Denominator"
            case probabilityOfOneWayMovement = "ProbabilityOfOneWayMovement"
        }

        /// Maximum granularity denominator for degraded effort values.
        /// Degraded effort is expressed as numerator/denominator where denominator
        /// must be of form 2^n - 1 (i.e., 1, 3, 7, 15, 31).
        /// Must be in range [1, 31]
        public var denominator: UInt8?

        /// Probability of moving up or down one granularity bucket to add noise.
        /// This creates symmetric noise that maintains mean(input) = mean(output)
        /// while making exact effort values unpredictable.
        /// Must be in the range [0.0, 1.0]
        public var probabilityOfOneWayMovement: Double?

        /// Non-throwing initializer when no values are provided (uses all defaults)
        public init() {
            self.denominator = nil
            self.probabilityOfOneWayMovement = nil
        }

        public init(
            denominator: UInt8? = nil,
            probabilityOfOneWayMovement: Double? = nil
        ) throws {
            if let denominator {
                try PolicyControlledEffortDegrader.validateDenominator(denominator)
            }
            if let probability = probabilityOfOneWayMovement {
                try PolicyControlledEffortDegrader.validateProbability(probability)
            }
            self.denominator = denominator
            self.probabilityOfOneWayMovement = probabilityOfOneWayMovement
        }
    }
}
