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
//  ConfigLoader.swift
//  darwinOSBits
//
//

import Foundation
import System
import RemoteServiceDiscovery

internal import DarwinInitBridging

/// Information about the origin of a configuration
struct ConfigOrigin: Equatable, Hashable, Codable {
    var loadingPath: [ConfigLoader.LoadingKey]
    var source: JSON
}

extension ConfigOrigin {
    /// Original source was a version 1 config
    var isV1: Bool {
        return loadingPath.version != .v2
    }

    /// Was not loaded from an array
    var isSimple: Bool {
        return loadingPath.first { $0.isIndex } == nil
    }
}

/// Marks a property as injected by the loader
///
/// Inject properties are excluded from comparisons, i.e.
/// they are always equal, indepedent of their values.
@propertyWrapper
struct LoaderInjected<Value: Hashable & Equatable & Codable>: Equatable, Hashable {
    var wrappedValue: Value?

    static func == (lhs: LoaderInjected<Value>, rhs: LoaderInjected<Value>) -> Bool {
        return true
    }
}

// MARK: - Config Loader
struct ConfigLoader {

    enum LoadingKey: Equatable, Hashable, Codable {
        case nvram(DInitNVRAMConfigSource)
        case source(DInitConfigSource)
        case index(Int)
        case version(VersionInfo)

        var isIndex: Bool {
            switch self {
            case .index(_): true
            default: false
            }
        }
    }

    enum DecodedData {
        case source(DInitConfigSource, [LoadingKey])
        case config(Config)
    }

    struct NetworkConfig {
        let retries: Int
        let backoff: BackOff
    }

    let jsonDecoder = JSONDecoder()

    let computer: any Computer
    let networkConfig: NetworkConfig

    init(computer: any Computer) {
        self.computer = computer
        self.networkConfig = .init(retries: 6, backoff: .fixed(.seconds(30)))
    }

    init(computer: any Computer, networkConfig: NetworkConfig) {
        self.computer = computer
        self.networkConfig = networkConfig
    }

    /// Loads a config from the provided source, if provided, or the system.
    func load(from source: DInitConfigSource?) async throws -> [Config] {
        do {
            if let source {
                return try await load(from: source)
            } else {
                return try await loadSystem()
            }

        } catch {
            throw Error.unableToLoad(source, error)
        }
    }

    /// Recursively load configurations from `source`.
    private func load(from source: DInitConfigSource,
                      at loadingPath: [LoadingKey] = []) async throws -> [Config] {
        logger.debug("Loading configuration from \(source)")

        let data = switch source {
        case .standardInput:
            try FileHandle.standardInput.readToEnd() ?? Data()
        case let .json(json):
            json.data(using: .utf8) ?? Data()
        case let .network(url):
            // Retry every thirty seconds for three minutes to ensure
            // slow network initialization doesn't become
            // a fatal error
            try await loadNetwork(from: url)
        case let .fileSystem(path):
            try path.loadData()
        case let .ec2imds(key):
            try await EC2MetadataService.fetchUserData(for: key)
        case let .remoteService(deviceTypeDesc, serviceName):
            try loadRemoteService(from: deviceTypeDesc, serviceName: serviceName)
        }

        let dt = try decode(data: data, at: loadingPath)

        logger.log("Successfully loaded configuration from \(source)")
        return try await resolve(data: dt)
    }

    /// Resolve any source references inside the array.
    ///
    /// Calls `load(from source:)` on any member of the array that is a source reference.
    ///
    /// - Returns: array of configuration objects, i.e. all members are `.config`.
    private func resolve(data: [DecodedData]) async throws -> [Config] {
        logger.debug("Resolving configuration Data from \(data)")
        var result: [Config] = []
        for item in data {
            switch item {
            case .source(let source, let path):
                let inner = try await load(from: source, at: path)
                result.append(contentsOf: inner)
            case .config(let cfg):
                result.append(cfg)
            }
        }
        return result
    }

    /// The default configuration
    ///
    /// If anything that need to be done automatically, either on internal, or
    /// for any specific hardware, it should land in the default config. The
    /// default config will be picked up when running
    /// `darwin-init apply --system` and will prepanded to the
    /// array of configurations.
    private func defaultConfig(mergeTo config: inout Config) {
        if computer.isComputeNode {
            logger.debug("Setting default compute name and local hostname for compute node")

            if let carrier = computer.oceanComputeCarrierID,
               let soc = computer.oceanComputeCarrierSlot {

                if config.identification == nil {
                    config.identification = Config.Identification()
                }

                if config.identification?.computerName == nil {
                    config.identification?.computerName = "soc-\(carrier)-\(soc)"
                }
                if config.identification?.localHostname == nil {
                    config.identification?.localHostname = "soc-\(carrier)-\(soc)"
                }
            } else {
                logger.error("Failed to copy carrier / soc information")
            }
        }
    }

    /// Loads the system configuration.
    private func loadSystem() async throws -> [Config] {
        var data: [DecodedData]?

        // On internal variants of darwin, first attempt to load the system
        // configuration from NVRAM.
        if computer.shouldLoadConfigFromNVRAM {
            logger.debug("Attempting to load configuration from NVRAM")
            data = try await loadNVRAM()
        }

        // If the device is a BMC and does not have a NVRAM configuration,
        // fall back to using the default data center config server.
        if data == nil && computer.isBMC {
            data = try await loadBMCConfig()
        }

        if data == nil && computer.isComputeNode {
            data = try await loadCNodeConfig()
        }

        guard let data else {
            throw Error.missingSystemConfiguration
        }

        var configs = try await resolve(data: data)

        guard var first = configs.first else {
            throw Error.missingSystemConfiguration
        }

        // TODO: don't merge the configs
        defaultConfig(mergeTo: &first)
        configs[0] = first

        return configs
    }
    
    // MARK: Remote Service Discovery
    /// Load configuration data from a remote service.
    private func loadRemoteService(from deviceTypeDesc: String, serviceName: String) throws -> Data {
        let queue = DispatchQueue(label: "remote_device_browse")
        let semaphore = DispatchSemaphore(value: 0)
        var configData: Data = Data()
        var _device: remote_device_t? = nil

        let deviceType = remote_device_type_parse(deviceTypeDesc)
        guard deviceType != REMOTE_DEVICE_TYPE_INVALID_OR_UNKNOWN else {
            throw RemoteDeviceTypeError.invalidDeviceTypeDesc(deviceTypeDesc)
        }

        var flag = atomic_flag()

        let browser = remote_device_start_browsing(deviceType, queue) { device, canceling in
            if canceling {
                return
            }

            remote_device_set_connected_callback(device!, queue) { device in
                if atomic_flag_test_and_set_explicit(&flag, memory_order_relaxed) {
                    // timed out, bail
                    return
                }
                _device = device
                semaphore.signal()
            }
        }
        defer {
            remote_device_browser_cancel(browser)
        }

        switch semaphore.wait(timeout: DispatchTime.now() + .seconds(120)) {
        case .success:
            let deviceName = String(cString: remote_device_get_name(_device!))
            logger.info("remote device found: \(deviceName)")
        case .timedOut:
            if atomic_flag_test_and_set_explicit(&flag, memory_order_relaxed) {
                // the callback has been fired but not signaled yet.
                // it's safe to wait for that forever here
                semaphore.wait()
            } else {
                logger.error("timeout waiting for remote device to show up")
                throw Error.loadTimeout(.remoteService(device: deviceTypeDesc, service: serviceName))
            }
        }

        configData = try DInitRemoteService.fetchConfig(from: _device!, service: serviceName)
        logger.debug("Raw data got from remote service: \(configData)")
        return configData
    }

    // MARK: Network
    /// Load the configuration data from an HTTP server.
    private func loadNetwork(from url: URL) async throws -> Data {
        let identity = DInitDeviceIdentity.shared
        logger.info("Requesting darwin-init configuration for \(identity) from \(url).")
        return try await Network.post(identity,
                                      to: url,
                                      attempts: self.networkConfig.retries,
                                      backoff: self.networkConfig.backoff)
    }
    
    // MARK: Factory
    /// Load configuration data from a factory remote service.
    private func loadFactoryConfig() async throws -> Data {
        logger.log("Loading configuration from factory remote service")
        
        let deviceTypeDesc = String(cString: remote_device_type_get_description(computer.isComputeNode ? REMOTE_DEVICE_TYPE_COMPUTE_CONTROLLER : REMOTE_DEVICE_TYPE_NCM_HOST))
        return try loadRemoteService(from: deviceTypeDesc, serviceName: kDInitFactoryRemoteServiceName)
    }

    // MARK: NVRAM
    /// Loads configuration data from NVRAM.
    ///
    /// Configurations in NVRAM can come from multiple variables in a variety of
    /// formats. `loadNVRAM()` unifies this loading process.
    /// `loadNVRAM()` reads data from both NVRAM variables in the following order:
    ///
    /// - `darwin-init-system`
    /// - `darwin-init`
    ///
    /// This ordering is determined by the natural order of `DInitNVRAMConfigSource.allCases`.
    ///
    /// If the data is in base64 it is decoded.
    /// At this point the data is expected to be valid UTF8 JSON.
    ///
    /// - seealso: ``DInitNVRAMConfigSource``
    private func loadNVRAM() async throws -> [DecodedData]? {
        logger.debug("Loading configuration from NVRAM")

        var allData: [DecodedData] = []

        for source in DInitNVRAMConfigSource.allCases {
            var data: Data
            do {
                let nvram = try computer.nvram
                data = try nvram.getData(forKey: source.variable)
            } catch NVRAM.Error.unableToGetDataForKey(_, shim_kIOReturnNoResources()) {
                logger.warning("No data contained in the \(source.variable.rawValue) NVRAM variable")
                continue
            }

            if let decodedData = Data(base64Encoded: data) {
                logger.debug("Data from \(source.variable.rawValue) NVRAM variable was recognized as base64")
                data = decodedData
            }

            do {
                let sourceData = try decode(data: data, at: [.nvram(source)])
                allData.append(contentsOf: sourceData)
                logger.log("Successfully loaded configuration from \(source.variable.rawValue) NVRAM variable")
            } catch {
                logger.warning("Data from \(source.variable.rawValue) NVRAM variable is not valid: \(error.localizedDescription)")
                continue
            }
        }

        return allData.isEmpty ? nil : allData
    }
    
    private func loadBMCConfig() async throws -> [DecodedData]? {
        logger.info("Loading configuration from Data Center Bootstrap service")
        
        let data: Data
        do {
            data = try await loadNetwork(from: kDInitDataCenterBootstrapServer)
        } catch {
            logger.error("Failed to load configuration from \(kDInitDataCenterBootstrapServer): \(error)")

            /// To avoid rev lock with dc-bss change, if the new endpoint doesn't work,
            /// fallback to the legacy endpoint automatically. This only works when darwin-init
            /// still understand the legacy config schema. When the support for that is removed,
            /// this logic needs to be removed as well.
            logger.log("Falling back to use the legacy Bootstrap endpoint")
            
            do {
                data = try await loadNetwork(from: kDInitDataCenterBootstrapServerFallback)
            } catch {
                logger.error("Failed to load configuration from \(kDInitDataCenterBootstrapServerFallback): \(error)")
                
                if computer.isFactorySignedRestore {
                    logger.log("Falling back to use factory endpoint")
                    data = try await loadFactoryConfig()
                } else {
                    throw error
                }
            }
        }
        
        do {
            return try decode(data: data, at: [])
        } catch {
            logger.warning("Data from Bootstrap service is not valid: \(error)")
            throw error
        }
    }

    private func loadCNodeConfig() async throws -> [DecodedData]? {
        logger.info("Loading configuration from remote service")

        let data: Data
        do {
            let deviceTypeDesc = String(cString: remote_device_type_get_description(REMOTE_DEVICE_TYPE_COMPUTE_CONTROLLER))
            data = try loadRemoteService(from: deviceTypeDesc, serviceName: kDInitRemoteServiceName)
        } catch {
            logger.error("Failed to load configuration from \(kDInitRemoteServiceName): \(error)")
            
            if computer.isFactorySignedRestore {
                logger.log("Falling back to use factory endpoint")
                data = try await loadFactoryConfig()
            } else {
                throw error
            }
        }
        
        do {
            return try decode(data: data, at: [])
        } catch {
            logger.warning("Data from remote service is not valid: \(error)")
            throw error
        }
    }
    
    // MARK: - Data decoding
    private func decode(data: Data, at loadingPath: [LoadingKey]) throws -> [DecodedData] {
        let json = try jsonDecoder.decode(JSON.self, from: data)
        return try decode(json: json, at: loadingPath)
    }

    /// Entry point for any JSON, can either be a config (json: dict), an array of
    /// configs (json: array) or a source reference (dict with `source` entry).
    private func decode(json: JSON, at loadingPath: [LoadingKey]) throws -> [DecodedData] {
        if case let .dictionary(dictionary) = json {
            return try decode(dict: dictionary, at: loadingPath)
        } else if case let .array(array) = json {
            return try decode(array: array, at: loadingPath)
        } else {
            // TODO: proper coding path
            throw DecodingError.dataCorrupted(
                .init(codingPath: [],
                      debugDescription: "Expected either an array or dictionary, got \(json)"))
        }
    }

    /// Decode a dictionary, which is a source reference, or a config
    private func decode(dict: [String: JSON], at loadingPath: [LoadingKey]) throws -> [DecodedData] {
        return if let source = dict["source"] {
            try decode(source: source, at: loadingPath)
        } else {
            [try decode(config: dict, at: loadingPath)]
        }
    }

    /// Decode an array, items must be dictionaries and can either be configs
    /// or source referencs, so they are passed to `decode(dict:)`.
    private func decode(array: [JSON], at loadingPath: [LoadingKey]) throws -> [DecodedData] {
        var result: [DecodedData] = []
        for (idx, item) in array.enumerated() {
            guard case let .dictionary(dict) = item else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [],
                          debugDescription: "Array elements must be dictionaries, got \(item)"))
            }
            let inner = try decode(dict: dict, at: loadingPath + [.index(idx)])
            result.append(contentsOf: inner)
        }
        return result
    }

    /// Decode a config form JSON.
    private func decode(config: [String: JSON], at loadingPath: [LoadingKey]) throws -> DecodedData {
        let version = Self.detectVersion(root: config)
        let json = JSON.dictionary(config)
        let origin: ConfigOrigin
        var config: Config

        logger.info("Detected config version: \(version)")
        logger.info("Decoding config: \(json, privacy: .private)")

        switch version {
        case .ambiguous, .v1:
            config = try JSONConverter.convert(from: json)
            let path = loadingPath + [.version(.v1)]
            origin = ConfigOrigin(loadingPath: path, source: json)

        case .v2:
            config = try JSEnumDecoder.decode(Config.self, from: json)
            let path = loadingPath + [.version(.v2)]
            origin = ConfigOrigin(loadingPath: path, source: json)
        }
        config.origin = origin
        return .config(config)
    }

    /// Decode a source reference: can either be an actual reference to a
    /// config somewhere else (network, rsd) or an embedded config or
    /// an array of configs.
    private func decode(source: JSON, at loadingPath: [LoadingKey]) throws -> [DecodedData] {
        if case let .string(str) = source {
            let source = DInitConfigSource(argument: str)
            return [.source(source, loadingPath)]
        } else {
            let path = loadingPath + [.source(.json("{}"))]
            return try decode(json: source, at: path)
        }
    }

    // MARK: - Version detection
    enum VersionInfo: Codable {
        case unknown
        case v1
        case v2
    }

    enum DetectedVersion: Codable, CustomStringConvertible {
        case ambiguous
        case v1(String)
        case v2(String)

        var description: String {
            switch self {
            case .ambiguous: "1 [ambiguous]"
            case let .v1(key): "1 [key: '\(key)']"
            case let .v2(key): "2 [key: '\(key)']"
            }
        }

    }

    /// Detect the version of the configuration by inspecting the JSON.
    ///
    /// The detection is done by checking for the presence of v1 or v2
    /// exclusive keys. If that fails we check for structural differences
    /// of common keys (i.e. values that are now dicts but were arrays).
    ///
    /// There are configs that are valid v1 or v2  and in those cases the
    /// return value is `VersionInfo.unknown`
    ///
    /// - Returns: the detected version or `.unknown`.
    static func detectVersion(root: [String: JSON]) -> DetectedVersion {
        let oldKeys = Set(DInitConfig.CodingKeys.allCases.map(\.stringValue))
        let newKeys = Set(Config.CodingKeys.allCases.map(\.stringValue))

        let commonKeys = oldKeys.intersection(newKeys)

        // Check if we have any v1 exclusive key, if so it is a v1
        for value in oldKeys.subtracting(commonKeys) where root[value] != nil {
            return .v1(value)
        }

        // Check if we have any v2 exclusive key, if so it is a v2
        for value in newKeys.subtracting(commonKeys) where root[value] != nil {
            return .v2(value)
        }

        // Must be one of the keys common to both
        // 1] was different type but is now dictionary:
        //   - preferences (was array, now dict)
        //   - network (was array, now dict)
        //   - ssh (was bool, now dict)
        //
        // - cryptex (was array or dict, now dict)
        //
        // - tailspin (structure changed)
        // - log (keys renamed '-', '_')
        //
        // Unchanged:
        //   - diavlo (stayed the same)
        //   - feature_flags (stayed the same)
        //   - volumes (stayed the same)

        let nowDict = [
            Config.CodingKeys.preferences,
            Config.CodingKeys.network,
            Config.CodingKeys.ssh
        ].map(\.stringValue)

        for key in nowDict {
            if let val = root[key] {
                return if case .dictionary = val {
                    .v2(key)
                } else {
                    .v1(key)
                }
            }
        }

        // The v1 parser actually allowed "cryptex" to be a dict and
        // would manually convert this to an array of dicts; in that
        // case there must be an "url" key.
        if let cryptex = root[Config.CodingKeys.cryptex] {
            if case .array = cryptex.value {
                return .v1(cryptex.key)
            } else if case .dictionary(let dict) = cryptex.value {
                if let url = dict[DInitCryptexConfig.CodingKeys.url] {
                    return .v1("\(cryptex.key).\(url.key)")
                } else {
                    return .v2("\(cryptex.key)")
                }
            }
        }

        if let log = root[Config.CodingKeys.log.stringValue] {
            // Look at the `log` section and if it has any of the new
            // v2 keys, it must be a v2
            if case .dictionary(let dict) = log {
                for key in Config.Log.CodingKeys.allCases.map(\.stringValue) {
                    if dict[key] != nil {
                        return .v2("log.\(key)")
                    }
                }
                // If it has any of the old v1 keys, it must be a v1
                for key in DInitLogConfig.CodingKeys.allCases.map (\.stringValue) {
                    if dict[key] != nil {
                        return .v1("log.\(key)")
                    }
                }
            }
        }

        // Check the tailspin config, for v1 the dictionary must
        // have `tailspin_enabled` key.
        if let tailspin = root[DInitConfig.CodingKeys.tailspinConfig] {
            if case .dictionary(let dict) = tailspin.value {
                if let enabled = dict[DInitTailSpinConfig.CodingKeys.tailspin_enabled] {
                    return .v1("\(tailspin.key).\(enabled.key)")
                }
            }
        }

        // Could be either
        return .ambiguous
    }
}

// MARK: Error
extension ConfigLoader {
    indirect enum Error: Swift.Error {
        case missingSystemConfiguration
        case unableToLoad(DInitConfigSource?, Swift.Error)
        case unableToDecodeData(DInitConfigSource?, DecodingError)
        case configRejected(String, Int32)
        case loadTimeout(DInitConfigSource)
    }
}

extension ConfigLoader.Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingSystemConfiguration:
            return "No system configuration found."
        case let .unableToLoad(source, error):
            return "Unable to load configuration data from \(source?.description ?? "system"): \(error.localizedDescription)"
        case let .unableToDecodeData(source, error):
            var description = "Unable to decode configuration data from \(source?.description ?? "system"): "
            switch error {
            case let .typeMismatch(_, context),
                let .valueNotFound(_, context),
                let .keyNotFound(_, context),
                let .dataCorrupted(context):
                description += context.debugDescription
            @unknown default:
                description += error.localizedDescription
            }
            return description
        case let .configRejected(source, errorCode):
            return "libsecureconfig rejected configuration data from \(source): \(errorCode)."
        case let .loadTimeout(source):
            return "Timeout loading configuration data from \(source)"
        }
    }
}

// MARK: Extensions
private extension Dictionary where Key == String, Value == JSON {
    subscript<K: CodingKey>(_ key: K) -> (key: String, value: JSON)? {
        let strKey = key.stringValue
        return if let value = self[strKey] {
            (strKey, value)
        } else {
            nil
        }
    }
}

extension Array where Element == ConfigLoader.LoadingKey {

    var containsIndex: Bool {
        self.first { $0.isIndex } != nil
    }

    var version: ConfigLoader.VersionInfo {
        for element in self.reversed() {
            if case let .version(info) = element {
                return info
            }
        }
        return .unknown
    }

}
