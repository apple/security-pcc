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
import GRPCClientConfiguration
import NIOCore
import os

extension CFPreferences {
    static var cbJobAuthPreferencesDomain: String {
        "com.apple.cloudos.cb_jobauthd"
    }
}

enum CloudBoardJobAuthDConfigurationError: Swift.Error {
    case missingKeyRotationServiceConfiguration
}

struct CloudBoardJobAuthDConfiguration: Codable, Hashable {
    enum CodingKeys: String, CodingKey {
        case keyRotationService = "KeyRotationService"
        case _staticPublicSigningKeys = "StaticPublicSigningKeys"
    }

    /// Configuration of the key rotation service endpoint that provides public Token Granting Token (TGT) and One Time
    /// Token (OTT) signing keys used by cb_jobhelper for TGT validation.
    public var keyRotationService: CloudBoardJobAuthDConfiguration.KeyRotationService?
    private var _staticPublicSigningKeys: CloudBoardJobAuthDConfiguration.StaticPublicSigningKeys?
    /// Static public signing keys to use if no key rotation service configuration is provided
    public var staticPublicSigningKeys: CloudBoardJobAuthDConfiguration.StaticPublicSigningKeys {
        self._staticPublicSigningKeys ?? .init(tgtPublicSigningDERKeys: [], ottPublicSigningDERKeys: [])
    }

    init(
        keyRotationService: KeyRotationService?,
        staticPublicSigningKeys: StaticPublicSigningKeys?
    ) {
        self.keyRotationService = keyRotationService
        self._staticPublicSigningKeys = staticPublicSigningKeys
    }

    static func fromFile(
        path: String,
        secureConfigLoader: SecureConfigLoader
    ) throws -> CloudBoardJobAuthDConfiguration {
        var config: CloudBoardJobAuthDConfiguration
        do {
            CloudBoardJobAuthDaemon.logger.info("Loading configuration from file \(path, privacy: .public)")
            let fileContents = try Data(contentsOf: URL(filePath: path))
            let decoder = PropertyListDecoder()
            config = try decoder.decode(CloudBoardJobAuthDConfiguration.self, from: fileContents)
        } catch {
            CloudBoardJobAuthDaemon.logger
                .error("Unable to load config from file: \(String(unredacted: error), privacy: .public)")
            throw error
        }

        return try self.withSecureConfig(config: config, secureConfigLoader: secureConfigLoader)
    }

    static func fromPreferences(
        secureConfigLoader: SecureConfigLoader = .real
    ) throws -> CloudBoardJobAuthDConfiguration {
        CloudBoardJobAuthDaemon.logger.info(
            "Loading configuration from preferences \(CFPreferences.cbJobAuthPreferencesDomain, privacy: .public)"
        )
        let preferences = CFPreferences(domain: CFPreferences.cbJobAuthPreferencesDomain)
        do {
            return try .fromPreferences(preferences, secureConfigLoader: secureConfigLoader)
        } catch {
            CloudBoardJobAuthDaemon.logger
                .error("Error loading configuration from preferences: \(String(unredacted: error), privacy: .public)")
            throw error
        }
    }

    static func fromPreferences(
        _ preferences: CFPreferences,
        secureConfigLoader: SecureConfigLoader
    ) throws -> CloudBoardJobAuthDConfiguration {
        let decoder = CFPreferenceDecoder()
        let configuration = try decoder.decode(CloudBoardJobAuthDConfiguration.self, from: preferences)

        return try self.withSecureConfig(config: configuration, secureConfigLoader: secureConfigLoader)
    }

    private static func withSecureConfig(
        config: CloudBoardJobAuthDConfiguration,
        secureConfigLoader: SecureConfigLoader
    ) throws -> CloudBoardJobAuthDConfiguration {
        var config = config
        let secureConfig: SecureConfig
        do {
            CloudBoardJobAuthDaemon.logger.info("Loading secure config from SecureConfigDB")
            secureConfig = try secureConfigLoader.load()
        } catch {
            CloudBoardJobAuthDaemon.logger
                .error("Error loading secure config: \(String(unredacted: error), privacy: .public)")
            throw error
        }
        if secureConfig.shouldEnforceAppleInfrastructureSecurityConfig {
            try config.enforceAppleInfrastructureSecurityConfig()
        }
        return config
    }
}

extension CloudBoardJobAuthDConfiguration {
    struct KeyRotationService: Codable, Hashable {
        enum CodingKeys: String, CodingKey {
            case targetHost = "TargetHost"
            case targetPort = "TargetPort"
            case _tlsConfig = "TLS"
            // How often to poll the key rotation service for new keys
            case _pollPeriodSeconds = "PollPeriodSeconds"
            // Signing Keys Validity grace period in seconds
            case _signingKeysGracePeriodSeconds = "SigningKeyValidityGracePeriodSeconds"
            // Jitter in percent of the poll period
            case _jitter = "Jitter"
            case _backoffConfig = "BackoffConfig"
        }

        /// Key Rotation Service host address
        public var targetHost: String
        /// Key Rotation Service port
        public var targetPort: Int

        public var _tlsConfig: TLSConfiguration?
        /// TLS configuration for connections made to the Key Rotation Service
        public var tlsConfig: TLSConfiguration {
            self._tlsConfig ?? .init(enable: true, enablemTLS: true)
        }

        private var _signingKeysGracePeriodSeconds: Int64?
        private var _pollPeriodSeconds: Int64?
        private var _jitter: Double?
        private var _backoffConfig: ConnectionBackoff?

        /// Interval of requests to Key Rotation Service to update TGT and OTT signing key sets
        public var pollPeriod: Duration {
            self._pollPeriodSeconds.map { .seconds($0) } ?? .seconds(60 * 15)
        }

        /// TGT and OTT signing keys validity grace period
        public var signingKeysGracePeriodSeconds: TimeInterval {
            TimeInterval(integerLiteral: self._signingKeysGracePeriodSeconds ?? 0)
        }

        /// Jitter in percent to add to interval between Key Rotation Service requests
        public var jitter: Double {
            self._jitter ?? 20
        }

        /// Backoff configuration for the Key Rotation Service GRPC client
        public var backoffConfig: ConnectionBackoff {
            self._backoffConfig ?? .init(initial: 1.0, maximum: 120.0, factor: 1.6, jitterPercent: 0.2, coolDown: nil)
        }

        internal init(
            targetHost: String,
            targetPort: Int,
            pollPeriod: Duration?,
            signingKeysGracePeriodSeconds: Int64?,
            jitter: Double?,
            tlsConfig: GRPCClientConfiguration.TLSConfiguration? = nil,
            backoffConfig: ConnectionBackoff? = nil
        ) {
            self.targetHost = targetHost
            self.targetPort = targetPort
            self._tlsConfig = tlsConfig
            self._pollPeriodSeconds = pollPeriod?.components.seconds
            self._signingKeysGracePeriodSeconds = signingKeysGracePeriodSeconds
            self._jitter = jitter
            self._backoffConfig = backoffConfig
        }
    }

    /// Enforces security configuration if running on Apple infrastructure (as opposed to e.g. the VRE) with a
    /// 'customer' security policy
    mutating func enforceAppleInfrastructureSecurityConfig() throws {
        CloudBoardJobAuthDaemon.logger.log("Enforcing Apple infrastructure security config")

        guard self.keyRotationService != nil else {
            CloudBoardJobAuthDaemon.logger.error("Missing KeyRotationService configuration")
            throw CloudBoardJobAuthDConfigurationError.missingKeyRotationServiceConfiguration
        }
        self.keyRotationService!.enforceSecurityConfig()
    }
}

extension CloudBoardJobAuthDConfiguration.KeyRotationService {
    mutating func enforceSecurityConfig() {
        CloudBoardJobAuthDaemon.logger.log("Enforcing TLS security config")
        if !tlsConfig.enable {
            CloudBoardJobAuthDaemon.logger.error("Overriding TLS configuration with new value enable=true")
        }
        if !tlsConfig.enablemTLS {
            CloudBoardJobAuthDaemon.logger.error("Overriding TLS configuration with new value enablemTLS=true")
        }
        if var _tlsConfig {
            _tlsConfig._enable = true
            _tlsConfig._enablemTLS = true
        } else {
            _tlsConfig = .init(enable: true, enablemTLS: true)
        }
    }
}

extension CloudBoardJobAuthDConfiguration {
    struct StaticPublicSigningKeys: Codable, Hashable {
        enum CodingKeys: String, CodingKey {
            case tgtPublicSigningDERKeys = "TGTPublicSigningDERKeys"
            case ottPublicSigningDERKeys = "OTTPublicSigningDERKeys"
        }

        public var tgtPublicSigningDERKeys: [String]
        public var ottPublicSigningDERKeys: [String]
    }
}
