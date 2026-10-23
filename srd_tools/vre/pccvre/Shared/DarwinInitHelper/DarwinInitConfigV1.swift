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

//  Copyright © 2025 Apple, Inc. All rights reserved.
//

import Foundation

struct DarwinInitConfigV1 {
    typealias JSONDict = [String: Any]

    enum Section: String {
        case cryptex
        case localHostname = "local-host-name"
        case preferences
        case secureConfig = "secure-config"
        case ssh
        case sshPWAuth = "ssh_pwauth"
        case user
    }

    var loaded: JSONDict

    // security policy keys that must be suppressed when enabling certain researcher features (such as ssh)
    private static let securityPolicyKeys = ["config-security-policy", "config-security-policy-version"]

    // retrieve and set the local hostname config
    var localHostname: String? {
        get { getSection(Section.localHostname) as? String }
        set(newValue) {
            if let newValue {
                setSection(Section.localHostname, value: newValue)
            } else {
                removeSection(Section.localHostname)
            }
        }
    }

    // retrieve and store various settings related to [the] ssh user
    var sshConfig: DarwinInitConfigV1.SSH {
        get {
            var sshUser: DarwinInitConfigV1.SSH.User
            if let user = getSection(Section.user) as? JSONDict {
                sshUser = DarwinInitConfigV1.SSH.User(
                    uid: UInt(user["uid"] as? String ?? "0") ?? 0,
                    gid: UInt(user["gid"] as? String ?? "0") ?? 0,
                    name: user["root"] as? String ?? "root",
                    sshPubKey: DarwinInitHelper.validateSSHPubKey(user["ssh_authorized_key"] as? String ?? "") ?? ""
                )
            } else {
                sshUser = DarwinInitConfigV1.SSH.User()
            }

            return DarwinInitConfigV1.SSH(
                enabled: getSection(Section.ssh) as? Bool ?? false,
                pwAuthEnabled: getSection(Section.sshPWAuth) as? Bool ?? false,
                user: sshUser
            )
        }

        set(newValue) {
            setSection(Section.ssh, value: newValue.enabled)

            if newValue.sshPWAuth {
                setSection(Section.sshPWAuth, value: newValue.sshPWAuth)
            } else {
                removeSection(Section.sshPWAuth) // remove if false
            }

            if let userDef = newValue.userDef {
                setSection(Section.user, value: [
                    "uid": userDef.uid,
                    "gid": userDef.gid,
                    "name": userDef.name,
                    "ssh_authorized_key": userDef.sshPubKey,
                ])
            } else {
                removeSection(Section.user)
            }
        }
    }

    var buildVersion: String? {
        getPreference(applicationId: "com.apple.cloudos.cloudOSInfo", key: "cloudOSBuildVersion") as? String
    }

    init(fromFile: String) throws {
        do {
            let src = try NSData(contentsOfFile: fromFile) as Data
            self.loaded = try JSONSerialization.jsonObject(with: src, options: []) as! JSONDict
        } catch {
            throw DarwinInitHelperError("darwin-init load from \(fromFile): \(error)")
        }
    }

    init(data: Data) throws {
        do {
            self.loaded = try JSONSerialization.jsonObject(with: data, options: []) as! JSONDict
        } catch {
            throw DarwinInitHelperError("darwin-init create from provided data: \(error)")
        }
    }

    init(jsonString: String?) throws {
        do {
            try self.init(data: (jsonString ?? "{}").data(using: .utf8)!)
        } catch {
            CLI.logger.error("Failed to load darwin-init from \(jsonString ?? "{}")")
            throw error
        }
    }

    // encode returns json representation as base64 blob
    func encode() -> String {
        return json(pretty: false).data(using: .utf8)!.base64EncodedString()
    }

    // json returns string representing darwin-init in json form; pretty sets whether to
    // include newlines and indentation for readability or compact form
    func json(pretty: Bool = false) -> String {
        var jsonOpts: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty {
            jsonOpts = [.fragmentsAllowed, .prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: loaded as NSDictionary, options: jsonOpts)
            let jsonString = String(decoding: jsonData, as: UTF8.self)
            return jsonString
        } catch {
            return "{}"
        }
    }

    // setPreferencesKey adds an entry to in-core darwin-init "preferences" list for applicationId/key
    //  set to the provided value (existing applicationId/key entry is removed)
    mutating func setPreferencesKey(
        applicationId: String,
        key: String,
        value: Any?
    ) {
        removePreferencesKeys(applicationId: applicationId, key: key)
        guard let value else {
            return
        }

        var preferences: [JSONDict] = getSection(Section.preferences) as? [JSONDict] ?? [JSONDict]()
        let newPref: JSONDict = [
            "application_id": applicationId,
            "key": key,
            "value": value,
        ]
        preferences.append(newPref)
        setSection(Section.preferences, value: preferences)
    }

    // removePreferencesKey deletes entry(s) from in-core darwin-init "preferences" list by applicationId,
    //  and optionally specific keys
    mutating func removePreferencesKeys(applicationId: String, key: String? = nil) {
        guard let preferences = getSection(Section.preferences) as? [JSONDict] else {
            return
        }

        setSection(Section.preferences, value: preferences.filter {
            guard let pAppId = $0["application_id"] as? String,
                  pAppId == applicationId
            else {
                return true
            }

            guard let key else {
                return false
            }

            guard let pKey = $0["key"] as? String, pKey == key else {
                return true
            }

            return false
        })
    }

    func getPreference(applicationId: String, key: String) -> Any? {
        guard let preferences = getSection(Section.preferences) as? [JSONDict] else {
            return nil
        }
        let preference = preferences.first {
            $0["application_id"] as? String == applicationId &&
            $0["key"] as? String == key
        }
        guard let preference else {
            return nil
        }
        return preference["value"]
    }

    // getSecureConfigKey returns an entry from in-core darwin-init "secure-config" dictionary by key
    func getSecureConfigKey(key: String) -> Any? {
        guard let secConfig = getSection(Section.secureConfig) as? JSONDict else {
            return nil
        }

        return secConfig[key]
    }

    // setSecureConfigKey adds an entry to in-core darwin-init "secure-config" dictionary, with key
    //  set to the provided value (replacing previous one)
    mutating func setSecureConfigKey(key: String, value: Any?) {
        var secConfig = getSection(Section.secureConfig) as? JSONDict ?? JSONDict()
        secConfig[key] = value
        setSection(Section.secureConfig, value: secConfig)
    }

    // removeSecureConfigKey removes an entry from in-core darwin-init "secure-config" dictionary by key
    mutating func removeSecureConfigKey(key: String) {
        setSecureConfigKey(key: key, value: nil)
    }

    // disableKey renames a key within in-core darwin-init using a prefix (effectively disabling it)
    //  such that it allows it to be easily "re-enabled". Returns true if update applied, false if
    //  original key isn't found.
    @discardableResult
    mutating func disableKey(_ key: String, prefix: String = "DISABLED-") -> Bool {
        if let val = getKey(key) {
            removeKey(key)
            setKey(prefix+key, value: val)
            return true
        }

        return false
    }

    // enableKey renames a key within in-core darwin-init using a prepended prefix (such as by
    //  disableKey) back to the (original) key to enable it again - existing key (if present) is
    //  overwritten. Returns true if update applied, false if original key isn't found.
    @discardableResult
    mutating func enableKey(_ key: String, prefix: String = "DISABLED-") -> Bool {
        if let val = getKey(prefix+key) {
            removeKey(prefix+key)
            setKey(key, value: val)
            return true
        }

        return false
    }

    // disableSecurityPolicy disables config-security-policy keys in provided darwin-init.
    //  Returns true of update applied, false otherwise (key wasn't found).
    @discardableResult
    mutating func disableSecurityPolicy(prefix: String = "DISABLED-") -> Bool {
        var updated = false
        for spkey in Self.securityPolicyKeys where disableKey(spkey, prefix: prefix) {
            updated = true
        }

        return updated
    }

    // reenableSecurityPolicy re-enables config-security-policy keys in provided darwin-init
    //   previously moved aside with prefix. Returns true of update applied, false otherwise
    //   (key wasn't found).
    @discardableResult
    mutating func reenableSecurityPolicy(prefix: String = "DISABLED-") -> Bool {
        var updated = false
        for spkey in Self.securityPolicyKeys where enableKey(spkey, prefix: prefix) {
            updated = true
        }

        return updated
    }

    // getSection returns section/value from in-core darwin-init or nil if not found; value type may
    //  otherwise be String, Integer, Double, Bool, or another dictionary - for bare tokens/assertions,
    //  an empty String ("") is returned
    func getSection(_ section: Section) -> Any? {
        return getKey(section.rawValue)
    }

    // getKey returns value from in-core darwin-init or nil if not found; value type may otherwise be
    //  String, Integer, Double, Bool, or another dictionary - for bare tokens/assertions, an empty
    //  String ("") is returned
    func getKey(_ key: String) -> Any? {
        return loaded[key]
    }

    // removeSection deletes section/key from in-core darwin-init
    mutating func removeSection(_ section: Section) {
        removeKey(section.rawValue)
    }

    // removeKey deletes item from in-core darwin-init
    mutating func removeKey(_ key: String) {
        loaded[key] = nil
    }

    // setSection adds/replaces section/key of in-core darwin-init
    mutating func setSection(_ section: Section, value: Any) {
        setKey(section.rawValue, value: value)
    }

    // setKey adds/replaces key to in-core darwin-init
    mutating func setKey(_ key: String, value: Any) {
        loaded.updateValue(value, forKey: key)
    }

}
