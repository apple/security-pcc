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


#if canImport(SecureConfigDB)
@_weakLinked import SecureConfigDB
#endif
#if canImport(os)
import os
#endif
import Foundation

public protocol ConfigProvider {
    func get<T>(key: String, domain: String?) -> T?
    var name: String {get}
}

public class SecureConfigProvider: ConfigProvider {
    public let name = "SecureConfigProvider"
    let log: EHLog.EHLoggerType
    #if canImport(SecureConfigDB)
    private let configParams: SecureConfigParameters?
    #endif

    public init(allowedInCustomerMode: Bool = true) {
        let llog = EHLog.withCategory("SecureConfigProvider")
        log = llog
    #if canImport(SecureConfigDB)
        configParams = {
            if #_hasSymbol(SecureConfigParameters.self) {
                do {
                    let values = try SecureConfigParameters.loadContents()
                    if !allowedInCustomerMode && values.securityPolicy == .customer {
                        os_log(.info, log: llog, "SecureConfigParameters is set to customer mode, but this feature is not allowed.")
                    } else {
                        return values
                    }
                } catch {
                    os_log(.info, log: llog, "Failed to load SecureConfigParameters, Error: \(error, privacy: .public)")
                }
            } else {
                os_log(.info, log: llog, "Failed to load SecureConfigParameters, Symbol doesn't exist")
            }
            return nil
        }()
    #endif
    }

    public func get<T>(key: String, domain: String?) -> T? {
        #if canImport(SecureConfigDB)
        if #_hasSymbol(SecureConfigParameters.self) {
            if let configParams {
                do {
                    let value: T? = try configParams.unvalidatedParameter(key)
                    return value
                } catch {
                    os_log(.info, log: log, "Failed to load SecureConfigParameters, key: \(key), Error: \(error, privacy: .public)")
                    return nil
                }
            }
        }
        #endif
        return nil
    }
}

public class CFPrefsProvider: ConfigProvider {
    public let name = "CFPrefsProvider"
    let log = EHLog.withCategory(CFPrefsProvider.self)
    #if !os(Linux)
    public func preferencesValue(_ key: String, domain: String) throws -> CFPropertyList? {
        guard let value = CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost) else {
            os_log(.error, log: log, "Unable to get CFPreferences key \(key) from domain \(domain)")
            return nil
        }
        return value
    }
    public func preferencesDictionaryValue<T>(_ key: String, domain: String) -> [String: T]? {
        guard let value = try? preferencesValue(key, domain: domain) else {
            os_log(.error, log: log, "Unable to get CFPreferences key \(key) from domain \(domain)")
            return nil
        }
        let type = CFGetTypeID(value)
        guard type == CFDictionaryGetTypeID() else {
            os_log(.error, log: log, "Unable to cast value to CFDictionary type")
            return nil
        }
        return value as? [String: T]
    }
    public func preferencesValueAs<T>(_ key: String, domain: String) -> T? {
        guard let value = try? preferencesValue(key, domain: domain) else {
            os_log(.error, log: log, "Unable to get CFPreferences key \(key) from domain \(domain)")
            return nil
        }
        return value as? T
    }
    #endif
    public init() {}
    public func get<T>(key: String, domain: String?) -> T? {
        #if !os(Linux)
        return self.preferencesValueAs(key, domain: domain ?? "")
        #else
        return nil
        #endif
    }
}

class EnvironmentConfigResolver: ConfigProvider {
    public let name = "EnvironmentConfigResolver"
    init() {}

    static func envVarName(for key: String) -> String {
        var k = key
        if k.hasPrefix("com.apple.eventhorizond.") {
            k = String(k.dropFirst("com.apple.eventhorizond.".count))
        } else if k.hasPrefix("com.apple.securitymonitorlited.") {
            k = String(k.dropFirst("com.apple.securitymonitorlited.".count))
        } else if k.hasPrefix("com.apple.lsecuritymonitorlited.") {
            k = String(k.dropFirst("com.apple.lsecuritymonitorlited.".count))
        }
        k = k.replacingOccurrences(of: ".", with: "_")
        let chars = Array(k)
        var result = ""
        for i in chars.indices {
            let char = chars[i]
            if char.isUppercase && i > 0 && chars[i - 1] != "_" {
                let prevIsLower = chars[i - 1].isLowercase
                let nextIsLower = (i + 1 < chars.count) && chars[i + 1].isLowercase
                if prevIsLower || (chars[i - 1].isUppercase && nextIsLower) {
                    result += "_"
                }
            }
            result += String(char)
        }
        return "EH_" + result.uppercased()
    }

    func get<E>(key: String, domain: String?) -> E? {
        let envKey = Self.envVarName(for: key)
        if let v = ProcessInfo.processInfo.environment[envKey] {
            if E.self == Int?.self, let intValue = Int(v) {
                return intValue as? E
            } else if E.self == Bool?.self {
                let boolValue = v.lowercased() == "true" || v == "1"
                return boolValue as? E
            } else if E.self == Double?.self, let doubleValue = Double(v) {
                return doubleValue as? E
            } else {
                return v as? E
            }
        }
        return nil
    }
}

class DefaultConfigProvider<T>: ConfigProvider {
    public let name = "DefaultConfigProvider"
    let storage: T
    init(value: T) {
        storage = value
    }
    func get<E>(key: String, domain: String?) -> E? {
        return storage as? E
    }
}

public class EHConfigResolver {
    let providers: [any ConfigProvider]
    public init(_ providers: ConfigProvider...) {
        self.providers = providers
    }
    public func resolve<T>(key: String, domain: String?) -> T? {
        for provider in providers {
            if let value: T? = provider.get(key: key, domain: domain), value != nil {
                return value
            }
        }
        return nil
    }
}
