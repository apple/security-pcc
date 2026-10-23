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
//  CryptexConfiguration.swift
//  darwinOSBits
//
//

import CryptoKit
import CryptexKit
import DarwinInitConfig
import Foundation
import System

/// Configuration for a single cryptex, including download, personalization, and installation parameters.
///
/// This wrapper combines a Config.Cryptex.Cryptex (auto-generated from JSON schema) with its identifier
/// and adds business logic for cache decisions and server URL resolution.
///
/// Access schema properties directly via `.config` (e.g., `cryptexConfig.config.url`).
struct CryptexConfig {
    let identifier: String
    let config: Config.Cryptex.Cryptex

    init(from config: Config.Cryptex.Cryptex, identifier: String) {
        self.identifier = identifier
        self.config = config
    }

    // MARK: - Business Logic

    var sha256Bytes: [UInt8]? {
        get throws {
            guard let sha256 = config.sha256 else { return nil }
            guard let parsed = sha256.string.hexadecimalASCIIBytes else {
                logger.error("[\(self.identifier)] Failed to parse SHA256 digest: \(sha256.description)")
                throw Errno.invalidArgument
            }

            return parsed
        }
    }

    var isCacheable: Bool {
        // explicit opt out
        guard config.cacheable != false else { return false }

        // If it is a knox URL we can cache
        if config.url.scheme == kKnoxURLScheme { return true }

        // If we have a sha256, we can cache
        if config.sha256 != nil { return true }

        // If we have decryption parameters, we can cache
        if config.aeaDecryptionParams != nil { return true }

        return false
    }

    /// Resolves the personalization server URL based on configuration and Diavlo server.
    ///
    /// - Parameter diavloServerURL: The Diavlo server URL to use if signing environment is .diavlo
    /// - Returns: The resolved server URL, or nil if no server should be used
    func serverPersonalizationURL(diavloServerURL: String?) -> String? {
        if let url = config.signingEnvironmentUrl?.absoluteString {
            return url
        } else if config.signingEnvironment == .diavlo {
            return diavloServerURL
        } else {
            return nil
        }
    }

    /// Resolves the personalization server based on configuration.
    ///
    /// This consolidates the logic for converting the signing environment configuration
    /// into a CryptexPersonalizationService. Used by both personalization and installation.
    ///
    /// - Parameter diavloServerURL: The Diavlo server URL to use if signing environment is .diavlo
    /// - Returns: The resolved personalization server, or nil if not personalized
    func personalizationServer(diavloServerURL: String?) -> CryptexPersonalizationService? {
        // Determine signing policy based on the configured signing environment.
        // Diavlo requires .signed policy; all others use .notSigned.
        let signingPolicy: CryptexPersonalizationService.SigningPolicy =
            config.signingEnvironment == .diavlo ? .signed : .notSigned

        // Custom server URL takes precedence
        let customURL = serverPersonalizationURL(diavloServerURL: diavloServerURL)
        if let customURL, let url = URL(string: customURL) {
            return CryptexPersonalizationService(url: url, signingPolicy: signingPolicy)
        }

        // Otherwise use the configured signing environment
        if let authService = config.signingEnvironment {
            switch authService {
            case .diavlo:
                return .diavlo
            case .tatsu:
                return .tatsu
            case .factory:
                return .tatsu
            case .none:
                return nil
            @unknown default:
                return .tatsu
            }
        }

        // Default to tatsu (matches CryptexKit's default behavior)
        return .tatsu
    }

    /// Resolves AEA decryption parameters for this cryptex.
    ///
    /// This method consolidates the logic for determining decryption parameters from:
    /// - Pre-determined params in the cryptex config
    /// - Knox-based parameter fetching
    ///
    /// - Parameters:
    ///   - downloadConfig: Download configuration for Knox access
    ///   - downloadAuth: Authentication for Knox access
    /// - Returns: The resolved AEA decryption parameters, or nil if not applicable
    func resolveAEADecryptionParameters(
        downloadConfig: DownloadConfiguration,
        downloadAuth: DownloadAuthentication
    ) async throws -> AEADecryptionParameters? {
        if self.config.aeaDecryptionParams != nil && self.config.url.scheme == kKnoxURLScheme {
            logger.warning("Pre-determined decryption components already provided for a knox:// url. Will use pre-determined components rather than fetching from Knox.")
        }

        if let params = self.config.aeaDecryptionParams {
            logger.info("Pre-determined decryption components provided")
            guard let key = params.getDecryptionKey() else {
                return nil
            }
            guard let archiveIdentifierData = params.getArchiveID() else {
                return nil
            }
            return AEADecryptionParameters(
                archiveID: archiveIdentifierData,
                decryptionKey: key)
        }

        if self.config.url.scheme == kKnoxURLScheme {
            logger.log("Attempting to fetch decryption key for cryptex from Knox.")

            return await KnoxClientWrapper.downloadAEADecryptionParameters(
                for: self.config.url,
                configuration: downloadConfig,
                authentication: downloadAuth,
                alternateCDNHost: downloadConfig.alternateCDNHost)
        } else {
            return nil
        }
    }
}

// MARK: - Config Extensions

extension Config.Authentication {
    var downloadAuthentication: DownloadAuthentication {
        if let token = self.dawToken {
            return .daw(token: token.string)
        } else if let oidc = self.oidcToken {
            return .oidc(token: oidc.string)
        } else if let wg = self.westgate {
            return .westgate(username: wg.username, token: wg.token.string)
        } else {
            return .none
        }
    }
}

extension Config.Cryptex.Cryptex.AeaDecryptionParams {

    func getDecryptionKey() -> SymmetricKey? {
        // convert input String key into an array of UInt8 bytes
        guard let hexDecoded = decryptionKey.string.hexadecimalASCIIBytes, !hexDecoded.isEmpty else {
            logger.error("Invalid hex decryption key, could not convert to array of UInt8")
            return nil
        }

        // convert array of bytes to SymmetricKey for use in a decryption context
        return SymmetricKey(data: hexDecoded)
    }

    func getArchiveID() -> Data? {
        guard let archiveIdentifierBytes = archiveId.string.hexadecimalASCIIBytes, !archiveIdentifierBytes.isEmpty else {
            logger.error("Failed to convert archive identifier from String to Data")
            return nil
        }
        return Data(archiveIdentifierBytes)
    }
}

