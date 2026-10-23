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


import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif
import Synchronization

public protocol HTTPPosterTransformEncoder: Sendable {
    static func encode(event: any EHUEFEvent) -> Data?
}

public final class HTTPPosterTransform: EHTransform {
    public let name = "HTTPPosterTransform"

    public static let posterName = "events"

    static let ServerDefaultURL = "https://dzv2.apple.com"
    public static let ServerConfigParameterKey = "com.apple.eventhorizond.httpPoster.serverURL"
    public static let SMLServerConfigParameterKey = "com.apple.securitymonitorlited.serverURL"
    public static let LSMLServerConfigParameterKey = "com.apple.lsecuritymonitorlited.serverURL"
    static let DisableTLSValidationConfigKey = "com.apple.eventhorizond.httpPoster.disableTLSValidation"

    private static let _configuredServerURL: Mutex<(value: String?, set: Bool)> = Mutex((nil, false))
    private static let _configuredDisableTLSValidation: Mutex<(value: Bool?, set: Bool)> = Mutex((nil, false))
    private static let _configuredToken: Mutex<String?> = .init(nil)
    private static let _configuredEncoderStyle: Mutex<ConfiguredEncoderStyle> = .init(.asep)
    private static let _configuredBuffering: Mutex<BufferingConfig> = .init(.default)

    public struct BufferingConfig: Sendable {
        public let bufferCount: Int
        public let bufferSize: Int
        public let timeoutSeconds: Double

        public init(bufferCount: Int, bufferSize: Int, timeoutSeconds: Double) {
            self.bufferCount = bufferCount
            self.bufferSize = bufferSize
            self.timeoutSeconds = timeoutSeconds
        }

        public static let `default` = BufferingConfig(
            bufferCount: 2,
            bufferSize: 655_360,
            timeoutSeconds: 30.0
        )
    }

    public static func setConfiguredBuffering(_ value: BufferingConfig) {
        _configuredBuffering.withLock { $0 = value }
    }

    public static func configuredBuffering() -> BufferingConfig {
        _configuredBuffering.withLock { $0 }
    }

    public enum ConfiguredEncoderStyle: Sendable {
        case asep
        case splunkHEC
    }

    public static func setConfiguredEncoderStyle(_ style: ConfiguredEncoderStyle) {
        _configuredEncoderStyle.withLock { $0 = style }
    }

    public static func configuredEncoderStyle() -> ConfiguredEncoderStyle {
        _configuredEncoderStyle.withLock { $0 }
    }

    public static func configuredEncoderType() -> any HTTPPosterTransformEncoder.Type {
        switch configuredEncoderStyle() {
        case .asep: return UEFToASEP.self
        case .splunkHEC: return UEFToSplunkHEC.self
        }
    }

    public static func setConfiguredServerURL(_ value: String) {
        _configuredServerURL.withLock { state in
            if state.set {
                os_log(.error, log: log, "configuredServerURL already set, ignoring subsequent call")
                return
            }
            state.value = value
            state.set = true
        }
    }

    public static func setConfiguredDisableTLSValidation(_ value: Bool) {
        _configuredDisableTLSValidation.withLock { state in
            if state.set {
                os_log(.error, log: log, "configuredDisableTLSValidation already set, ignoring subsequent call")
                return
            }
            state.value = value
            state.set = true
        }
    }

    public static func setConfiguredToken(_ value: String?) {
        _configuredToken.withLock { $0 = value }
    }

    let sender: HTTPSender
    let encoder: any HTTPPosterTransformEncoder.Type
    private static let log = EHLog.withCategory(HTTPPosterTransform.self)

    static func getURL(serverConfigKey: String = ServerConfigParameterKey) -> URL {
        let configuredDefault = _configuredServerURL.withLock { $0.value }
        let fallbackURL = configuredDefault ?? ServerDefaultURL
        let defaultUrl = URL(string: fallbackURL)!

        let resolvedURL: String? = EHConfigResolver(
            SecureConfigProvider(),
            EnvironmentConfigResolver()
        ).resolve(key: serverConfigKey, domain: nil)

        if let resolvedURL {
            guard let parsedUrl = URL(string: resolvedURL) else {
                os_log(.error, log: log, "Config provider passed invalid URL: \(resolvedURL, privacy: .public), using default: \(fallbackURL, privacy: .public)")
                return defaultUrl
            }
            os_log(.info, log: log, "Setting server URL from config provider: \(resolvedURL, privacy: .public)")
            return parsedUrl
        }

        os_log(.info, log: log, "Using server URL: \(fallbackURL, privacy: .public)")
        return defaultUrl
    }

    static func shouldDisableTLSValidation(override: Bool?) -> Bool {
        if let override {
            return override
        }
        let resolved: Bool? = EHConfigResolver(
            SecureConfigProvider(),
            EnvironmentConfigResolver()
        ).resolve(key: HTTPPosterTransform.DisableTLSValidationConfigKey, domain: "com.apple.eventhorizond")
        if let resolved {
            return resolved
        }
        return _configuredDisableTLSValidation.withLock { $0.value } ?? false
    }

    public init?(
        bufferCount: Int,
        bufferSize: Int,
        timeout: Double,
        encodingStrategy: any HTTPPosterTransformEncoder.Type,
        disableTLSValidation: Bool? = nil,
        serverConfigKey: String = ServerConfigParameterKey
    ) {
        let shouldDisable = Self.shouldDisableTLSValidation(override: disableTLSValidation)
        guard let sender = HTTPSender(
            endpoint: Self.getURL(serverConfigKey: serverConfigKey),
            token: Self._configuredToken.withLock { $0 },
            disableTLSValidation: shouldDisable,
            bufferCount: bufferCount,
            bufferSize: bufferSize,
            timeout: timeout,
            posterName: Self.posterName
        ) else {
            return nil
        }
        self.sender = sender
        self.encoder = encodingStrategy
    }

    public func process(_ event: any EHUEFEvent) async -> EHTransformReturn {
        if let adata = encoder.encode(event: event) {
            let isImmediate = event.tags.contains(SharedTags.high_priority.rawValue)
            self.sender.send(adata, immediate: isImmediate)
        }
        return (.proceed, nil, nil, nil)
    }

    public func configure() async throws {
        _ = getHostName()
    }
}
