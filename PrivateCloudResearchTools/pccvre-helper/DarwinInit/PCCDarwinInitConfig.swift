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
import darwininitschema

typealias JSONDict = [String: Any]

struct PCCDarwinInitConfig {

    struct Cryptex: Encodable, Equatable {
        let variant: String
        let url: String
    }

    enum ConfigVersion {
        case v1
        case v2

        static func detect(from config: JSONDict) -> Self {
            let defaultVersion = Self.v2

            let json = try? DarwinInitConfig.from(jsonDict: config)
            guard let json else {
                return defaultVersion
            }

            let detected = DarwinInitConfig.detectVersion(root: json)

            return switch detected {
            case .v1: .v1
            case .v2: .v2
            case .ambiguous: defaultVersion
            }
        }
    }

    class Entry {
        var dictionary: JSONDict
        let version: ConfigVersion

        init(dictionary: JSONDict, version: ConfigVersion? = nil) {
            self.dictionary = dictionary
            self.version = version ?? ConfigVersion.detect(from: dictionary)
        }

        func mergeOverlay(_ overlay: JSONDict) throws {
            let underlay = try DarwinInitConfig.from(jsonDict: dictionary)
            let overlayDarwinInit = try DarwinInitConfig.from(jsonDict: overlay)

            let merged = switch version {
            case .v1:
                try DarwinInitConfig.merge(underlay: underlay, overlay: overlayDarwinInit)
            case .v2:
                try DarwinInitConfig.mergeV2(underlay: underlay, overlay: overlayDarwinInit)
            }

            let data = try JSONEncoder().encode(merged)
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            guard let mergedDict = object as? [String: Any] else {
                throw ParsingError("Merged JSON is not a dictionary")
            }
            self.dictionary = mergedDict
        }
    }

    var entries: [Entry]
    var firstEntry: Entry { entries[0] }
    var lastEntry: Entry { entries[entries.count - 1] }

    init(dictionary: JSONDict, version: ConfigVersion? = nil) {
        self.entries = [Entry(dictionary: dictionary, version: version)]
    }

    init(dictionaries: [JSONDict]) {
        assert(!dictionaries.isEmpty, "Config dictionaries should never be empty")
        self.entries = dictionaries.map { Entry(dictionary: $0) }
    }

    init(json: String) throws {
        let data = (json == "" ? "{}" : json).data(using: .utf8)!
        let object = try JSONSerialization.jsonObject(with: data, options: [])

        // Support both single dictionary and array of dictionaries
        if let dictionary = object as? [String: Any] {
            // Single dictionary - create single entry
            self.entries = [Entry(dictionary: dictionary)]
        } else if let array = object as? [[String: Any]] {
            // Array of dictionaries - create multiple entries
            guard !array.isEmpty else {
                throw ParsingError("JSON array must not be empty")
            }
            self.entries = array.map { dict in
                Entry(dictionary: dict)
            }
        } else {
            throw ParsingError("JSON must be a dictionary or an array of dictionaries")
        }
    }

    func json(pretty: Bool = false) throws -> String {
        let options: JSONSerialization.WritingOptions = pretty ?
        [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys, .prettyPrinted] :
        [.fragmentsAllowed, .withoutEscapingSlashes]

        let jsonObject: Any
        if entries.count == 1 {
            // Backward compatibility: single entry outputs as dictionary
            jsonObject = entries[0].dictionary
        } else {
            // Multiple entries output as array
            jsonObject = entries.map { $0.dictionary }
        }

        let jsonData = try JSONSerialization.data(withJSONObject: jsonObject, options: options)
        return String(decoding: jsonData, as: UTF8.self)
    }

    mutating func appendOrReplaceCryptex(_ cryptex: Cryptex) throws {
        try CryptexAppendOrReplaceOp(variant: cryptex.variant, url: cryptex.url).run(&self)
    }

    mutating func removeCryptex(variant: String) throws {
        try CryptexRemoveOp(variant: variant).run(&self)
    }

    func listCryptexes() throws -> [Cryptex] {
        try ListCryptexesOp().run(self)
    }

    var localHostname: String? {
        get throws { try GetLocalHostnameOp().run(self) }
    }

    mutating func setLocalHostname(_ hostname: String) throws {
        try LocalHostnameUpdateOp(hostname: hostname).run(&self)
    }

    mutating func enableSSH(publicKey: String) throws {
        try SSHEnableOp(publicKey: publicKey).run(&self)
    }

    mutating func disableSSH() throws {
        try SSHDisableOp().run(&self)
    }

    func hasCryptex(variant: String) throws -> Bool {
        try listCryptexes().contains { $0.variant == variant }
    }

    func entriesWithCryptex(variant: String) throws -> [Entry] {
        var result: [Entry] = []
        for entry in entries {
            let tempConfig = PCCDarwinInitConfig(dictionary: entry.dictionary, version: entry.version)
            let cryptexes = try ListCryptexesOp().run(tempConfig)
            if cryptexes.contains(where: { $0.variant == variant }) {
                result.append(entry)
            }
        }
        return result
    }
}

extension PCCDarwinInitConfig {
    init(launcher: ProcessLauncher, instance: String) throws {
        let arguments = ["instance", "configure", "darwin-init", "dump", "--name", instance]
        let result = try launcher.exec(executablePath: CLI.pccvrePath, arguments: arguments)
        try self.init(json: result.stdout)
    }

    func save(launcher: ProcessLauncher, instance: String) throws {
        let tempFileURL = try FileManager.tempDirectory(
            subPath: CLI.applicationName, instance).appending(path: "darwin-init.json")

        CLI.debugPrint("Modified darwin-init: \(tempFileURL)")
        try self.json(pretty: true).write(to: tempFileURL, atomically: true, encoding: .utf8)

        let arguments = ["instance", "configure", "darwin-init", "set",
                         "--name", instance,
                         "--input", tempFileURL.path(percentEncoded: false)]
        let result = try launcher.exec(executablePath: CLI.pccvrePath, arguments: arguments)

        guard result.exitCode == 0 else {
            throw CLIError("Failed to save darwin-init configuration: \(result.stdout)")
        }
    }
}

extension PCCDarwinInitConfig {
    struct EnsembleNode: Decodable {
        let udid: String
        let rank: UInt8
        let hostName: String
    }

    mutating func configureEnsemble(name: String, nodes: [EnsembleNode]) throws {
        try EnsembleConfigureOp(name: name, nodes: nodes).run(&self)
    }
}

extension PCCDarwinInitConfig {
    mutating func configureServiceDiscovery(listeningIP: String, targetHost: String, targetPort: Int) throws {
        try ServiceDiscoveryConfigureOp(listeningIP: listeningIP, targetHost: targetHost, targetPort: targetPort).run(&self)
    }
}

extension DarwinInitConfig {
    static func from(jsonDict: JSONDict) throws -> Self {
        let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return try JSONDecoder().decode(Self.self, from: jsonData)
    }
}

extension PCCDarwinInitConfig {
    /// Merges provided overlay config onto current config
    /// - If overlay has a single entry, applies it to the last entry of this config
    /// - If overlay has multiple entries, applies each overlay entry to the corresponding config entry (counts must match)
    /// The latter case is needed for MERGE_STRAT=REMOVE overlays - the merger adds those entries if there is no match.
    mutating func overridingMerge(with overlay: PCCDarwinInitConfig) throws {
        if overlay.entries.count == 1 {
            // Single overlay entry: apply to last entry only
            try lastEntry.mergeOverlay(overlay.firstEntry.dictionary)
        } else {
            // Multiple overlay entries: must match config entry count
            guard overlay.entries.count == entries.count else {
                throw ParsingError("Overlay entry count (\(overlay.entries.count)) must match config entry count (\(entries.count))")
            }
            // Apply each overlay to corresponding entry
            for (index, overlayEntry) in overlay.entries.enumerated() {
                try entries[index].mergeOverlay(overlayEntry.dictionary)
            }
        }
    }
}

protocol DarwinInitConfigUpdateOperation {
    func run(_ config: inout PCCDarwinInitConfig) throws
}

enum ArrayHandlingStrategy {
    case first  // Apply operation to first entry only
    case last   // Apply operation to last entry only
    case all    // Apply operation to all entries
}

protocol DarwinInitConfigOverlayOperation: DarwinInitConfigUpdateOperation {
    func overlay(version: PCCDarwinInitConfig.ConfigVersion) -> JSONDict
    func arrayStrategy() -> ArrayHandlingStrategy
}

extension DarwinInitConfigOverlayOperation {
    func run(_ config: inout PCCDarwinInitConfig) throws {
        let strategy = arrayStrategy()

        switch strategy {
        case .first:
            // Apply to first entry only
            let entry = config.firstEntry
            let overlay = overlay(version: entry.version)
            try entry.mergeOverlay(overlay)

        case .last:
            // Apply to last entry only
            let entry = config.lastEntry
            let overlay = overlay(version: entry.version)
            try entry.mergeOverlay(overlay)

        case .all:
            // Apply to all entries
            for entry in config.entries {
                let overlay = overlay(version: entry.version)
                try entry.mergeOverlay(overlay)
            }
        }
    }
}

protocol DarwinInitConfigReadOperation<Result> {
    associatedtype Result
    func run(_ config: PCCDarwinInitConfig) throws -> Result
}

protocol DarwinInitConfigCryptexUpdateOperation: DarwinInitConfigUpdateOperation {
    var variant: String { get }
}

extension DarwinInitConfigCryptexUpdateOperation {
    /// Returns the key and properties of the cryptex matching `variant` in the given entry,
    /// or nil if the entry does not contain this cryptex. For v2, the dictionary key is the
    /// cryptex's identifier, which is not guaranteed to equal its variant, so entries are
    /// matched by their "variant" field rather than by key.
    func existingCryptex(in entry: PCCDarwinInitConfig.Entry) -> (key: String, properties: [String: Any])? {
        switch entry.version {
        case .v1:
            guard let cryptexes = entry.dictionary["cryptex"] as? [[String: Any]],
                  let cryptex = cryptexes.first(where: { ($0["variant"] as? String) == variant }) else {
                return nil
            }
            return (key: variant, properties: cryptex)
        case .v2:
            guard let cryptexContainer = entry.dictionary["cryptex"] as? [String: Any],
                  let cryptexesDict = cryptexContainer["cryptexes"] as? [String: JSONDict],
                  let match = cryptexesDict.first(where: { $1["variant"] as? String == variant }) else {
                return nil
            }
            return (key: match.key, properties: match.value)
        }
    }
}

struct CryptexAppendOrReplaceOp: DarwinInitConfigCryptexUpdateOperation {
    let variant: String
    let url: String

    func run(_ config: inout PCCDarwinInitConfig) throws {
        // Find entries containing this cryptex by checking each entry directly,
        // avoiding the heavier entriesWithCryptex/ListCryptexesOp path.
        // Update ALL matching entries to stay consistent with CryptexRemoveOp semantics.
        var found = false
        for entry in config.entries {
            guard let existing = existingCryptex(in: entry) else { continue }
            try entry.mergeOverlay(overlay(version: entry.version, key: existing.key, existingProperties: existing.properties))
            found = true
        }

        if !found {
            // No entry contained this cryptex, append to the last entry
            let entry = config.lastEntry
            try entry.mergeOverlay(overlay(version: entry.version, key: variant))
        }
    }

    func overlay(version: PCCDarwinInitConfig.ConfigVersion, key: String, existingProperties: [String: Any]? = nil) -> JSONDict {
        // Start with existing properties, then override variant and url
        var cryptexDict: [String: Any] = existingProperties ?? [:]
        cryptexDict["variant"] = variant
        cryptexDict["url"] = url
        // Don't carry over any merge strategy from the existing entry
        cryptexDict.removeValue(forKey: "MERGE_STRAT")

        switch version {
        case .v1:
            return [
                "cryptex": [cryptexDict]
            ]
        case .v2:
            return [
                "cryptex": [
                    "cryptexes": [
                        key: cryptexDict
                    ]
                ]
            ]
        }
    }
}

struct CryptexRemoveOp: DarwinInitConfigCryptexUpdateOperation {
    let variant: String

    func run(_ config: inout PCCDarwinInitConfig) throws {
        // Find entries containing this cryptex by checking each entry directly, mirroring
        // CryptexAppendOrReplaceOp. We cannot apply the overlay to all entries because the
        // merger somewhat surprisingly adds MERGE_STRAT=REMOVE entries if there is no match.
        for entry in config.entries {
            guard let existing = existingCryptex(in: entry) else { continue }
            try entry.mergeOverlay(overlay(version: entry.version, key: existing.key, existingProperties: existing.properties))
        }
    }

    func overlay(version: PCCDarwinInitConfig.ConfigVersion, key: String, existingProperties: [String: Any] = [:]) -> JSONDict {
        // The overlay must match the existing cryptex's full properties (e.g. "identifier"),
        // not just variant/url - the merger matches by full dictionary equality, so a bare
        // overlay won't match entries with extra properties and gets appended instead of
        // removing them.
        var cryptexDict = existingProperties
        cryptexDict["variant"] = variant
        cryptexDict["url"] = ""
        cryptexDict["MERGE_STRAT"] = "REMOVE"

        switch version {
        case .v1:
            return [
                "cryptex": [cryptexDict]
            ]
        case .v2:
            return [
                "cryptex": [
                    "cryptexes": [
                        key: cryptexDict
                    ]
                ]
            ]
        }
    }
}

struct SSHEnableOp: DarwinInitConfigUpdateOperation {
    let publicKey: String

    static let sshDisabledPrefix = "SSH_DISABLED-"

    func run(_ config: inout PCCDarwinInitConfig) throws {
        // SSH operations apply to first entry only
        let entry = config.firstEntry
        switch entry.version {
        case .v1:
            entry.dictionary["ssh"] = true
            entry.dictionary["user"] = [
                "gid": 0,
                "name": "root",
                "ssh_authorized_key": publicKey,
                "uid": 0
            ]
            disable(key: "config-security-policy", in: &entry.dictionary)
            disable(key: "config-security-policy-version", in: &entry.dictionary)
        case .v2:
            entry.dictionary["ssh"] = [
                "enabled": true
            ]
            entry.dictionary["users"] = [
                "root": [
                    "gid": 0,
                    "uid": 0,
                    "authentication": [
                        "ssh_authorized_key": publicKey
                    ]
                ]
            ]
            disable(key: "config_security_policy", in: &entry.dictionary)
        }
    }

    func disable(key: String, in dictionary: inout JSONDict) {
        if let value = dictionary[key] {
            dictionary[Self.sshDisabledPrefix + key] = value
            dictionary[key] = nil
        }
    }
}

struct SSHDisableOp: DarwinInitConfigUpdateOperation {
    func run(_ config: inout PCCDarwinInitConfig) throws {
        // SSH operations apply to first entry only
        let entry = config.firstEntry
        switch entry.version {
        case .v1:
            entry.dictionary["ssh"] = false
            entry.dictionary["user"] = nil
            reenable(key: "config-security-policy", in: &entry.dictionary)
            reenable(key: "config-security-policy-version", in: &entry.dictionary)
        case .v2:
            entry.dictionary["ssh"] = [
                "enabled": false
            ]
            entry.dictionary["users"] = nil
            reenable(key: "config_security_policy", in: &entry.dictionary)
        }
    }

    func reenable(key: String, in dictionary: inout JSONDict) {
        if let disabled = dictionary[SSHEnableOp.sshDisabledPrefix + key] {
            dictionary[key] = disabled
            dictionary[SSHEnableOp.sshDisabledPrefix + key] = nil
        }
    }
}

struct LocalHostnameUpdateOp: DarwinInitConfigOverlayOperation {
    let hostname: String

    func arrayStrategy() -> ArrayHandlingStrategy {
        .last
    }

    func overlay(version: PCCDarwinInitConfig.ConfigVersion) -> JSONDict {
        switch version {
        case .v1:
            return [
                "local-host-name": hostname
            ]
        case .v2:
            return [
                "identification": [
                    "local_hostname": hostname
                ]
            ]
        }
    }
}

struct EnsembleConfigureOp: DarwinInitConfigOverlayOperation {
    let name: String
    let nodes: [PCCDarwinInitConfig.EnsembleNode]

    func arrayStrategy() -> ArrayHandlingStrategy {
        return .last
    }

    func overlay(version: PCCDarwinInitConfig.ConfigVersion) -> JSONDict {
        var ensembleNodes: JSONDict = [:]
        for node in nodes {
            ensembleNodes[node.udid] = [
                "chassisID": "vre",
                "rank": node.rank,
                "hostName": node.hostName
            ]
        }

        let ensembleConfig: JSONDict = [
            "ensemble_id": name,
            "nodes": ensembleNodes
        ]

        switch version {
        case .v1:
            // V1: preferences is an array of objects with application_id, key, value
            return [
                "preferences": [
                    [
                        "application_id": "com.apple.cloudos.AppleComputeEnsembler",
                        "key": "EnsembleConfiguration",
                        "value": ensembleConfig
                    ]
                ]
            ]
        case .v2:
            // V2: preferences -> username -> applicationId -> key: value
            // Using AnyUser to apply to any user
            return [
                "preferences": [
                    "AnyUser": [
                        "com.apple.cloudos.AppleComputeEnsembler": [
                            "EnsembleConfiguration": ensembleConfig
                        ]
                    ]
                ]
            ]
        }
    }
}

struct ServiceDiscoveryConfigureOp: DarwinInitConfigOverlayOperation {
    let listeningIP: String
    let targetHost: String
    let targetPort: Int

    static let applicationID = "com.apple.cloudos.cloudboardd"
    static let serviceRegion = "test-region"
    static let cellID = "cell-id-test"

    func arrayStrategy() -> ArrayHandlingStrategy {
        return .last
    }

    func overlay(version: PCCDarwinInitConfig.ConfigVersion) -> JSONDict {
        let serviceDiscoveryValue: JSONDict = [
            "TargetPort": targetPort,
            "ServiceRegion": Self.serviceRegion,
            "CellID": Self.cellID,
            "TargetHost": targetHost,
            // TLS is not supported by the local test service discovery server.
            "TLS": ["EnableMTLS": false, "Enable": false],
            "LBConfig": ["environment": "ephemeral", "cluster": "PV"]
        ]
        let grpcValue: JSONDict = [
            "ListeningIP": listeningIP,
            "UseSelfSignedCertificate": true
        ]

        switch version {
        case .v1:
            // V1: preferences is an array of objects with application_id, key, value
            return [
                "preferences": [
                    ["application_id": Self.applicationID, "key": "ServiceDiscovery", "value": serviceDiscoveryValue],
                    ["application_id": Self.applicationID, "key": "GRPC", "value": grpcValue]
                ]
            ]
        case .v2:
            // V2: preferences -> username -> applicationId -> key: value
            // Using AnyUser to apply to any user
            return [
                "preferences": [
                    "AnyUser": [
                        Self.applicationID: [
                            "ServiceDiscovery": serviceDiscoveryValue,
                            "GRPC": grpcValue
                        ]
                    ]
                ]
            ]
        }
    }
}

struct ListCryptexesOp: DarwinInitConfigReadOperation {
    func run(_ config: PCCDarwinInitConfig) throws -> [PCCDarwinInitConfig.Cryptex] {
        // Collect cryptexes from all entries
        var cryptexesByVariant: [String: PCCDarwinInitConfig.Cryptex] = [:]

        for entry in config.entries {
            let entryCryptexes: [PCCDarwinInitConfig.Cryptex]
            switch entry.version {
            case .v1:
                entryCryptexes = try listV1Cryptexes(entry.dictionary)
            case .v2:
                entryCryptexes = try listV2Cryptexes(entry.dictionary)
            }

            // Last occurrence wins for duplicates
            for cryptex in entryCryptexes {
                cryptexesByVariant[cryptex.variant] = cryptex
            }
        }

        // Return sorted for stable ordering
        return cryptexesByVariant.values.sorted { $0.variant < $1.variant }
    }

    private func listV1Cryptexes(_ dictionary: JSONDict) throws -> [PCCDarwinInitConfig.Cryptex] {
        guard let cryptexes = dictionary["cryptex"] as? [Any] else {
            return []
        }

        return try cryptexes.map { cryptex in
            guard let cryptexDictionary = cryptex as? [String: Any] else {
                throw ParsingError("cryptex entry is not a dictionary")
            }
            guard let variant = cryptexDictionary["variant"] as? String else {
                throw ParsingError("cryptex 'variant' is not a string")
            }
            guard let url = cryptexDictionary["url"] as? String else {
                throw ParsingError("cryptex 'url' is not a string")
            }
            return PCCDarwinInitConfig.Cryptex(variant: variant, url: url)
        }
    }

    private func listV2Cryptexes(_ dictionary: JSONDict) throws -> [PCCDarwinInitConfig.Cryptex] {
        guard let cryptexContainer = dictionary["cryptex"] as? [String: Any],
              let cryptexesDict = cryptexContainer["cryptexes"] as? [String: Any] else {
            return []
        }

        // sort for stable ordering
        return try cryptexesDict.sorted(by: { $0.key < $1.key }).compactMap { (_, value) in
            guard let cryptexDictionary = value as? [String: Any] else {
                throw ParsingError("cryptex entry is not a dictionary")
            }
            guard let variant = cryptexDictionary["variant"] as? String else {
                throw ParsingError("cryptex 'variant' is not a string")
            }
            guard let url = cryptexDictionary["url"] as? String else {
                throw ParsingError("cryptex 'url' is not a string")
            }
            return PCCDarwinInitConfig.Cryptex(variant: variant, url: url)
        }
    }
}

struct GetLocalHostnameOp: DarwinInitConfigReadOperation {
    func run(_ config: PCCDarwinInitConfig) throws -> String? {
        // Iterate entries in reverse to get the last hostname
        for entry in config.entries.reversed() {
            let hostname: String?
            switch entry.version {
            case .v1:
                hostname = entry.dictionary["local-host-name"] as? String
            case .v2:
                if let identification = entry.dictionary["identification"] as? [String: Any] {
                    hostname = identification["local_hostname"] as? String
                } else {
                    hostname = nil
                }
            }

            if hostname != nil {
                return hostname
            }
        }

        return nil
    }
}

struct ParsingError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}
