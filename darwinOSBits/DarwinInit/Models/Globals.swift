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
//  Globals.swift
//  darwinOSBits
//
//

import DarwinInitConfig
import os

/// Contains the config values that is common to the application of all configurations.
struct Globals {
    var rebootAfterSetup = false
    var retainCachedCryptexes = false
    var lockCryptexes = false
    var USRAfterSetup: DInitUSR?
    var cryptexCacheInvalidationId: String?
    var configSecurityPolicy: String?
    var secureConfigParameters: [String: JSON] = [:]
    var builtinCryptexOverride: [String: Config.Cryptex.Cryptex] = [:]
}

extension Globals {
    var bootingIntoREM: Bool {
        if let usr = USRAfterSetup {
            usr.willRebootIntoRem
        } else {
            false
        }
    }

    var willLockCryptexes: Bool {
        return bootingIntoREM || lockCryptexes
    }

    var willUserspaceReboot: Bool {
        if let usr = USRAfterSetup {
            usr.willReboot
        } else {
            false
        }
    }
}

extension Globals: CustomStringConvertible {
    var description: String {
        var res: String = "{"

        res += "\n  rebootAfterSetup: \(rebootAfterSetup)"
        res += "\n  retainCachedCryptexes: \(retainCachedCryptexes)"
        res += "\n  lockCryptexes: \(lockCryptexes)"
        if let USRAfterSetup {
            res += "\n  USRAfterSetup: \(USRAfterSetup)"
        }
        res += "\n  cryptexCacheInvalidationId: \(cryptexCacheInvalidationId ?? "Not Set")"
        res += "\n  configSecurityPolicy: \(String(describing: configSecurityPolicy))"
        res += "\n  builtinCryptexOverride: [\(builtinCryptexOverride.keys.joined(separator: ", "))]"

        res += "\n}"

        return res
    }
}

// MARK: - GlobalsBuilder

/// Build `Globals` from one or many `Config` structures with dynamic policies.
struct GlobalsBuilder {

    /// A `Value` coming from config at `index` in the array of configs.
    struct ValueRef<Value: Equatable>: Equatable {
        let value: Value
        let index: Int
        let path: JSONPointer

        init(value: Value, index: Int, path: JSONPointer = JSONPointer(components: [])) {
            self.value = value
            self.index = index
            self.path = path
        }
    }

    /// The policy to apply when combining values from multiple configurations.
    protocol Policy<Value> {
        associatedtype Value: Equatable
        var value: Value? { get }
        mutating func check(_ newValue: ValueRef<Value>) throws
    }

    struct GlobalsError: Swift.Error {
        /// The index in the array of configurations.
        let config: Int

        /// The location within one configuration.
        let location: JSONPointer

        /// The policy violation that caused this error.
        let reason: any Error
    }

    protocol GlobalValue {
        mutating func update(from: Config, at index: Int) throws
        func write(to: inout Globals)
    }

    ///Read values from Config with a unified interface
    ///Note: Value will actually be `String?` or `DInitUSR?`
    struct PathCodedExtractor<Value: Codable & Equatable> {
        let extractor: (Config) -> (Value, JSONPointer)?

        func value(for config: Config) -> (Value, JSONPointer)? {
            self.extractor(config)
        }

        init(_ path: KeyPath<Config, PathCoded<Value>?>) {
            self.extractor = { cfg in
                if let pc = cfg[keyPath: path] {
                    (pc.wrappedValue, pc.jsonPointer)
                } else {
                    nil
                }
            }
        }

        init(_ path: KeyPath<Config, PathCoded<Value>>) {
            self.extractor = { cfg in
                let pc = cfg[keyPath: path]
                return (pc.wrappedValue, pc.jsonPointer)
            }
        }
    }

    /// Write values in a unified way
    /// Note: Value here will be `String` or `DInitUSR`
    struct PathWriter<Value: Codable & Equatable> {
        let writer: (Value, inout Globals) -> (Void)

        func write(_ value: Value?, to vars: inout Globals) {
            guard let value else { return }
            self.writer(value, &vars)
        }

        init(_ destination: WritableKeyPath<Globals, Value> & Sendable) {
            self.writer = { (val, vars) in
                vars[keyPath: destination] = val
            }
        }

        init(_ destination: WritableKeyPath<Globals, Value?> & Sendable) {
            self.writer = { (val, vars) in
                vars[keyPath: destination] = val
            }
        }
    }

    ///Bridge from Config values to Globals
    ///Note: Value here will be `String` or `DInitUSR`.
    struct Entry<Value: Codable & Equatable>: GlobalValue {
        let source: PathCodedExtractor<Value?>
        let destination: PathWriter<Value>
        var policy: any Policy<Value>

        init(
            from source: PathCodedExtractor<Value?>,
            to dest: PathWriter<Value>,
            policy: any Policy<Value>
        ) {
            self.source = source
            self.destination = dest
            self.policy = policy
        }

        mutating func update(from config: Config, at index: Int) throws {
            guard let (val, loc) = self.source.value(for: config) else { return }
            guard let val else { return }
            do {
                try policy.check(.init(value: val, index: index, path: loc))
            } catch {
                throw GlobalsError(config: index, location: loc, reason: error)
            }
        }

        func write(to vars: inout Globals) {
            destination.write(policy.value, to: &vars)
        }
    }

    // MARK: - Public Interface
    var entries: [any GlobalValue] = []

    /// Register a global value to be read from `source` into `destination` while
    /// observing the provided `policy`.
    mutating func register<Value: Codable & Equatable>(
        source: PathCodedExtractor<Value?>,
        dest: WritableKeyPath<Globals, Value> & Sendable,
        policy: any Policy<Value> = GlobalsBuilder.SameValuePolicy()
    ) {
        let writer = PathWriter(dest)
        let entry = Entry(from: source, to: writer, policy: policy)
        entries.append(entry)
    }

    /// Register a global value to be read from `source` into `destination` while
    /// observing the provided `policy`.
    mutating func register<Value: Codable & Equatable>(
        source: PathCodedExtractor<Value?>,
        dest: WritableKeyPath<Globals, Value?> & Sendable,
        policy: any Policy<Value> = GlobalsBuilder.SameValuePolicy()
    ) {
        let writer = PathWriter(dest)
        let entry = Entry(from: source, to: writer, policy: policy)
        entries.append(entry)
    }

    /// Update all registered globals from `config` at `index`.
    mutating func update(from config: Config, at index: Int) throws {
        for i in entries.indices {
            try entries[i].update(from: config, at: index)
        }
    }

    /// Create a new `Globals` with the combined values from all configs.
    func realize() -> Globals {
        var vars = Globals()
        for entry in entries {
            entry.write(to: &vars)
        }
        return vars
    }

}

// MARK: - Policies
extension GlobalsBuilder {

    /// First occurrence will set the value, subsequent ones will be ignored.
    ///
    /// When constructed with `init(forced:)`, the value is pre-determined and
    /// all config values are ignored.
    struct FirstValuePolicy<Value: Equatable>: Policy {
        var value: Value?

        init() { self.value = nil }
        init(forced: Value) { self.value = forced }

        mutating func check(_ newValue: ValueRef<Value>) throws {
            guard value == nil else {
                logger.info("Ignoring \(newValue.path, privacy: .public): value already determined")
                return
            }
            self.value = newValue.value
        }
    }

    /// First occurrence will set the value, any subsequent one that differs
    /// will lead to an error
    struct SameValuePolicy<Value: Equatable>: Policy {
        struct Conflict: Swift.Error {
            let reference: GlobalsBuilder.ValueRef<Value>
            let conflicts: [GlobalsBuilder.ValueRef<Value>]
            init(
                ref: GlobalsBuilder.ValueRef<Value>,
                _ conflicts: [GlobalsBuilder.ValueRef<Value>]
            ) {
                self.reference = ref
                self.conflicts = conflicts
            }
        }

        var reference: ValueRef<Value>?

        var value: Value? {
            return reference?.value
        }

        mutating func check(_ newValue: ValueRef<Value>) throws {
            guard let reference else {
                reference = newValue
                return
            }

            if reference.value == newValue.value {
                return
            }

            throw Conflict(ref: reference, [newValue])
        }
    }

    /// Merges JSON dictionaries as long as all keys are unique
    ///
    /// Combines keys at the top-level, throwing an error when
    /// the key already exists and the value is different.
    struct JSDictCombinePolicy: Policy {
        var dict: [String: JSON] = [:]
        var keys: [String: [Int]] = [:]

        var value: [String: JSON]? {
            return dict
        }

        struct Conflict: Swift.Error {
            let conflicts: [String: [Int]]
            init(on conflicts: [String: [Int]]) {
                self.conflicts = conflicts
            }
        }

        mutating func check(_ newValue: ValueRef<[String: JSON]>) throws {
            for (key, val) in newValue.value {
                var known = keys[key, default: []]
                known.append(newValue.index)
                keys[key] = known
                if let existing = dict[key] {
                    if existing != val {
                        throw Conflict(on: [key: known])
                    }
                } else {
                    dict[key] = val
                }
            }
        }
    }

    struct BuiltinCryptexPolicy: Policy {
        var dict: [String: Config.Cryptex.Cryptex] = [:]
        var value: [String: Config.Cryptex.Cryptex]? {
            dict
        }

        mutating func check(_ newValue: ValueRef<[String: Config.Cryptex.Cryptex]>) throws {
            for (key, val) in newValue.value {
                if kBuiltinCryptexIdentifiers.contains(key) {
                    dict[key] = val
                }
            }
        }
    }

}

// MARK: - Globals : GlobalBuilder integration
extension Globals {

    static func setup(
        builder: inout GlobalsBuilder,
        computer: any Computer
    ) {

        builder.register(
            source: .init(\Config.finish?.$reboot),
            dest: \Globals.rebootAfterSetup
        )

        // Retaining cached cryptexes is unsafe and only allowed on internal devices.
        let retainPolicy: any GlobalsBuilder.Policy<Bool> = if !computer.allowsInternalSecurityPolicies {
            GlobalsBuilder.FirstValuePolicy(forced: false)
        } else {
            GlobalsBuilder.SameValuePolicy()
        }

        builder.register(
            source: .init(\Config.cryptex?.cache?.$retainPreviouslyCachedCryptexesUnsafely),
            dest: \Globals.retainCachedCryptexes,
            policy: retainPolicy
        )

        builder.register(
            source: .init(\Config.cryptex?.$lock),
            dest: \Globals.lockCryptexes
        )

        builder.register(
            source: .init(\Config.finish?.$userspaceReboot),
            dest: \Globals.USRAfterSetup,
        )

        builder.register(
            source: .init(\Config.cryptex?.cache?.$invalidationId),
            dest: \Globals.cryptexCacheInvalidationId
        )

        builder.register(
            source: .init(\Config.configSecurityPolicy?.$policy),
            dest: \Globals.configSecurityPolicy
        )

        builder.register(
            source: .init(\Config.$secureConfig),
            dest: \Globals.secureConfigParameters,
            policy: GlobalsBuilder.JSDictCombinePolicy()
        )

        builder.register(
            source: .init(\Config.cryptex?.$cryptexes),
            dest: \Globals.builtinCryptexOverride,
            policy: GlobalsBuilder.BuiltinCryptexPolicy()
        )
    }

}
