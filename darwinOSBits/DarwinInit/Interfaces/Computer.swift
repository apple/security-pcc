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
//  Computer.swift
//  darwin-init
//

import Darwin
import os
import RemoteServiceDiscovery
import System
import SystemConfiguration
import MobileGestaltPrivate
import reboot2
internal import DarwinInitBridging


// MARK: - Platform

enum ComputerPlatform: Codable {
    case macOS
    case tvOS
    case iOS
    case watchOS
    case other
}

// MARK: - Protocol
protocol Computer {

    typealias Platform = ComputerPlatform

    var platform: ComputerPlatform { get }

    /// Sets the computerName using SystemConfiguration.
    ///
    /// The computer name is used for user displays and is used by bonjour.
    func set(computerName name: String) async throws

    /// Sets the host name using SystemConfiguration.
    ///
    /// The host name can be queried via SystemConfiguration and bsd APIs.
    func set(hostName name: String) async throws

    /// Sets the local host name using SystemConfiguration.
    ///
    /// The local host name is used by bonjour.
    func set(localHostName name: String) async throws

    /// Set CFPreferences
    ///
    /// The levels are [User: App: Key: Values]]]
    /// AnyUser will be translated to `kCFPreferencesAnyUser`
    /// AnyApplication will be translated to `kCFPreferencesAnyApplication`
    func set(preferences: [String: [String: [String: JSON]]]) -> [String: [String: [String: JSON]]]?

    /// Configures password-less sudo for the admin group.
    ///
    /// - Returns: `true` for success, `false` for failure.
    func configurePasswordlessSudo() -> Bool

    /// Set the current locale for all users. Default locale is `en_US_POSIX`
    ///
    /// - Returns: true if successful (result can be ignored).
    func setLocale(_ locale: String) -> Bool

    func getAutomatedDeviceGroup() -> String?

    func setAutomatedDeviceGroup(to group: String) -> Bool

    var uniqueChipID: Int? { get }

    var serialNumber: String? { get }

    var securityDomain: Int? { get }

    var boardID: Int? { get }

    var chipID: Int? { get }

    var oceanComputeCarrierID: Int? { get }

    var oceanComputeCarrierSlot: Int? { get }

    var isComputeNode: Bool { get }

    var isBMC: Bool { get }

    var isHostAttached: Bool { get }

    var isVM: Bool { get }

    var isDarwinCloud: Bool { get }
    
    var isFactorySignedRestore: Bool { get }

    var buildVersion: String? { get }

    var releaseType: String { get }

    var shouldLoadConfigFromNVRAM: Bool { get }

    var allowsInternalSecurityPolicies: Bool { get }

    func lockCryptexes() throws

    var defaultUSRAction: DInitUSR? { get  }

    func userspaceReboot(_ USR: DInitUSR) throws

    func reboot() throws

    func shutdown() throws

    var console: UnsafeMutablePointer<FILE>? { get }

    var osVariantHasInternalContent: Bool { get }

    /// Location of the rego bundle, abstracted for testing
    var regoBundle: String { get }

    // MARK: Run commands
    @discardableResult
    func run(executable: URL, arguments: [CustomStringConvertible]) throws -> String
    func run(shell: String?, command: String, savingStandardOutTo path: FilePath?) -> Bool


    // MARK: Secure Config
    func registerSecureconfig(parameters: Data?, securityPolicy: String?) -> Int32
    func registerSecureconfig(config: Data?) -> Int32

    // MARK: subsystems
    var nvram: any NVRAM { get throws }
    var fileSystem: any FileSystem { get }
    var systemLog: any SystemLog { get }
}

extension Computer {

    func run(shell: String?, command: String) -> Bool {
        return self.run(shell: shell, command: command, savingStandardOutTo: nil)
    }

}

// MARK: - RealComputer
class RealComputer: Computer {

    var platform: Platform {
#if os(macOS)
        return .macOS
#elseif os(iOS)
        return .iOS
#elseif os(watchOS)
        return .watchOS
#else
        return .other
#endif
    }

    /// Globallay shared RealComputer Instance
    static var shared: RealComputer = RealComputer()

    var _nvram: RealNVRAM?
    var nvram: NVRAM {
        get throws {
            guard let _nvram else {
                let nvram = try RealNVRAM()
                _nvram = nvram
                return nvram
            }
            return _nvram
        }
    }

    let fileSystem: any FileSystem = RealFileSystem.shared
    let systemLog: any SystemLog = RealSystemLog()

    /// Sets the computerName using SystemConfiguration.
    ///
    /// The computer name is used for user displays and is used by bonjour.
    func set(computerName name: String) async throws {
        logger.log("Setting computerName to \(name)")
        let preferences = try SCPreferences.create()
        try await preferences.withLock(lockRetryLimit: 5) { preferences in
            try preferences.computerName(name)
            try preferences.commit()
            try preferences.apply()
        }
    }

    /// Sets the host name using SystemConfiguration.
    ///
    /// The host name can be queried via SystemConfiguration and bsd APIs.
    func set(hostName name: String) async throws {
        logger.log("Setting hostName to \(name)")
        let preferences = try SCPreferences.create()
        try await preferences.withLock(lockRetryLimit: 5) { preferences in
            try preferences.hostName(name)
            try preferences.commit()
            try preferences.apply()
        }
    }

    /// Sets the local host name using SystemConfiguration.
    ///
    /// The local host name is used by bonjour.
     func set(localHostName name: String) async throws {
        logger.log("Setting localHostName to \(name)")
        let preferences = try SCPreferences.create()
        try await preferences.withLock(lockRetryLimit: 5) { preferences in
            try preferences.localHostname(name)
            try preferences.commit()
            try preferences.apply()
        }
    }

    /// Sets the preferences
    func set(preferences: [String: [String: [String: JSON]]]) -> [String: [String: [String: JSON]]]? {
        var result: [String: [String: [String: JSON]]] = [:]

        for (user, userPrefs) in preferences {
            var appVerified: [String: [String: JSON]] = [:]

            for (app, appPrefs) in userPrefs {

                let cfUser = if user == "AnyUser" {
                    kCFPreferencesAnyUser
                } else {
                    user as CFString
                }

                let cfApp = if app == "AnyApplication" {
                    kCFPreferencesAnyApplication
                } else {
                    app as CFString
                }

                let domain = CFPreferences.Domain(
                    applicationId: cfApp,
                    userName: cfUser,
                    hostName: kCFPreferencesCurrentHost
                )

                for (key, value) in appPrefs {
                    CFPreferences.set(value: value.propertyListValue, for: key, in: domain)
                }

                let ok = CFPreferences.synchronize(domain: domain)
                if !ok {
                    logger.warning("Failed to synchronize \(cfUser).\(cfApp)")
                }

                var verified: [String: JSON] = [:]
                for (key, value) in appPrefs {
                    let want = value.propertyListValue
                    let have = CFPreferences.getValue(for: key, in: domain)

                    if CFEqual(want ?? kCFNull, have ?? kCFNull) {
                        verified[key] = value
                    }
                }

                if !verified.isEmpty {
                    appVerified[app] = verified
                }
            }

            if !appVerified.isEmpty {
                result[user] = appVerified
            }
        }

        return result.isEmpty ? nil : result
    }

    /// Configures password-less sudo for the admin group.
    ///
    /// - Returns: `true` for success, `false` for failure.
    func configurePasswordlessSudo() -> Bool {
#if os(macOS)
        logger.log("Configuring password-less sudo for admin group")
        do {
            try kDInitPasswordlessSuodersFile.path.save(
                kDInitPasswordlessSuodersFile.contents
            )
        } catch {
            logger.fault("failed to create sudoers file with error \(error.localizedDescription)")
            return false
        }
        return true
#else
        logger.fault("Password-less sudo has no effect because it is not available on this platform")
        return false
#endif
    }

    /// Set the current locale for all users. Default locale is `en_US_POSIX`
    ///
    /// - Returns: true if successful (result can be ignored).
    func setLocale(_ locale: String) -> Bool {
        let key = "AppleLocale"
        let value = locale as CFString

        let domain = CFPreferences.Domain(
            applicationId: kCFPreferencesAnyApplication,
            userName: kCFPreferencesCurrentUser,
            hostName: kCFPreferencesAnyHost)
        CFPreferences.set(value: value, for: key, in: domain)

        guard CFPreferences.synchronize(domain: domain) else {
            logger.error("Failed to set AppleLocale to \(locale, privacy: .public): Failed to synchronize preferences.")
            return false
        }
        CFPreferences.flushCaches()

        guard let actualValue = CFPreferences.getValue(for: key, in: domain) else {
            logger.error("Failed to set AppleLocale to \(locale, privacy: .public): Failed persist preferences.")
            return false
        }

        guard CFEqual(actualValue, value) else {
            logger.error("Failed to set AppleLocale to \(locale, privacy: .public): Invalid persisted value.")
            return false
        }

        logger.log("Set AppleLocale to \(locale, privacy: .public).")
        return true
    }

    func getAutomatedDeviceGroup() -> String? {
        guard let group = shim_automatedDeviceGroup() else {
            logger.log("Failed to find an AutomatedDeviceGroup for this device")
            return nil
        }
        logger.log("Found AutomatedDeviceGroup: \(group, privacy: .public)")
        return group
    }

    func setAutomatedDeviceGroup(to group: String) -> Bool {
        shim_setAutomatedDeviceGroup(group)
        let actual = getAutomatedDeviceGroup()
        guard actual == group else {
            logger.error("Failed to set AutomatedDeviceGroup to \(group, privacy: .public)")
            return false
        }
        logger.log("Successfully set AutomatedDeviceGroup to \(group, privacy: .public)")
        return true
    }

    var uniqueChipID: Int? {
        let id = Int(shim_MGQUniqueChipID())
        return id != -1 ? id : nil
    }

    var serialNumber: String? {
        shim_MGQSerialNumber() as String?
    }

    var securityDomain: Int? {
        let id =  Int(shim_MGQSecurityDomain())
        return id != -1 ? id : nil
    }

    var boardID: Int? {
        let id =  Int(shim_MGQBoardID())
        return id != -1 ? id : nil
    }

    var chipID: Int? {
        let id =  Int(shim_MGQChipID())
        return id != -1 ? id : nil
    }

    var oceanComputeCarrierID: Int? {
        shim_MGQOceanComputeCarrierID() as? Int
    }

    var oceanComputeCarrierSlot: Int? {
        shim_MGQOceanComputeCarrierSlot() as? Int
    }

    var isComputeNode: Bool {
        MobileGestalt.current.isComputeNode
    }

    var isBMC: Bool {
        MobileGestalt.current.isComputeController
    }

    var isHostAttached: Bool {
        return remote_device_copy_unique_of_type(REMOTE_DEVICE_TYPE_NCM_HOST) != nil
    }

    var isVM: Bool {
        MobileGestalt.current.isVirtualDevice
    }

    var nvramConfigAllowedOnCustomerOS: Bool {
        MobileGestalt.current.deviceSupportsDarwinInitConfigFromNVRAM
    }

    var isDarwinCloud: Bool {
        self.releaseType.contains("Darwin Cloud")
    }

    var isFactorySignedRestore: Bool {
            MobileGestalt.current.isFactorySignedRestore
    }
    
    var buildVersion: String? {
        MobileGestalt.current.buildVersion
    }

    var releaseType: String {
        MobileGestalt.current.releaseType
    }

    var shouldLoadConfigFromNVRAM: Bool {
        if self.allowsInternalSecurityPolicies || self.isVM || self.nvramConfigAllowedOnCustomerOS {
            return true
        }

        /*
         * Hardware that operates in Ephemeral Data Mode by default
         * should only trust the BMC on customer builds, and not use NVRAM.
         * However, hardware that does not normally run in EphDM
         * could use EphDM, but lacks a BMC from which to fetch its config.
         *
         * The EphDM Tatsu entitlement requires explicit action and permission
         * from Tatsu to enable, making it a safe indicator for trusting
         * NVRAM on customer builds, without affecting existing hardware.
         *
         * This allows us to configure shelf-stable EphDM devices that can
         * reliably boot a given darwin-init config, even without a network
         * connection.
         *
         * NOTE: This could also be used to enable trusting NVRAM on customer
         * builds on prod fused EphDM hardware, if the hardware is authorized
         * to request this entitlement.
         */
        let override: NSNumber? = MobileGestalt.current.ephemeralDataModeOverride
        if let value = override {
            return value == 1
        }
        return false
    }

    private static func hasServiceNamed(_ name: String) -> Bool {
        var result = false
        let matchingDict = IOServiceNameMatching(name)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)

        if service != IO_OBJECT_NULL {
            result = true
            IOObjectRelease(service)
        }

        return result
    }

    var allowsInternalSecurityPolicies: Bool {
        shim_allows_internal_security_policies()
    }

    var osVariantHasInternalContent: Bool {
        os_variant_has_internal_content(Logger.subsystem)
    }

    func lockCryptexes() throws {
        let e = shim_cryptex_lockdown()
        if e != 0 {
            throw Errno(rawValue: e)
        }
    }

    var defaultUSRAction: DInitUSR? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, kIODeviceTreePlane + ":/chosen")
        guard entry > 0 else {
            return nil
        }

        let key = "darwinos-security-environment" as CFString
        guard let property = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0)  else {
            return nil
        }

        let data = property.takeRetainedValue() as! Data
        let value = data.withUnsafeBytes { raw in
            raw.load(as: UInt32.self)
        }
        logger.log("\(key) is \(value)")

        switch value {
        case 6: // BOOT_ENVIRONMENT_EMBEDDED_DARWINOS
            return .rem
        default:
            return nil
        }
    }

    fileprivate static func userspaceReboot(USRType: UInt64, USRPurpose: rb3_userreboot_purpose_t_t?) throws {
        var timeout:mach_timespec_t = mach_timespec(tv_sec: 60, tv_nsec: 0)
        let kr = IOKitWaitQuiet(kIOMainPortDefault, &timeout)
        logger.log("IOKitWaitQuiet returned \(kr)")

        var rc: Int32 = -1
        if let USRPurpose {
            rc = shim_reboot3_with_purpose(USRType, USRPurpose)
        } else {
            rc = shim_reboot3(USRType)
        }

        if rc != 0  {
            throw DInitError.userspaceRebootFailed(Errno(rawValue: rc))
        }
    }

    func userspaceReboot(_ USR: DInitUSR) throws {
        logger.info("Getting ready to reboot with type \(USR.rawValue)")
        if USR != .none && USR != .empty {
            try Self.userspaceReboot(USRType: USR.rebootType, USRPurpose: USR.rebootPurpose)
        } else {
            throw DInitError.userspaceRebootInvalidInput
        }
    }

    func reboot() throws {
        guard 0 == shim_reboot3(RB2_FULLREBOOT) else {
            throw DInitError.rebootFailed(Errno.current)
        }
    }

    func shutdown() throws {
#if os(macOS)
        if !Subprocess.run(shell: nil, command: "shutdown -h now") {
            throw DInitError.shutdownFailed
        }
#else
        logger.error("Shutdown only available on macOS")
        throw DInitError.shutdownFailed
#endif
    }

    var console: UnsafeMutablePointer<FILE>? {
        return fopen("/dev/console", "a")
    }

    var regoBundle: String {
        kDInitValidatorBundle
    }

    // MARK: Run commands
    @discardableResult
    func run(executable: URL, arguments: [CustomStringConvertible]) throws -> String {
        try Subprocess.run(executable: executable, arguments: arguments)
    }

    func run(shell: String?, command: String, savingStandardOutTo path: FilePath?) -> Bool {
        Subprocess.run(shell: shell, command: command, savingStandardOutTo: path)
    }

    // MARK: Secure Config
    func registerSecureconfig(parameters: Data?, securityPolicy: String?) -> Int32 {
        shim_register_secureconfig_parameters(parameters, securityPolicy)
    }

    func registerSecureconfig(config: Data?) -> Int32 {
        shim_register_config(config)
    }
}
