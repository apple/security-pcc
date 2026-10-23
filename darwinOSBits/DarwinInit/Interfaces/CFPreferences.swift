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
//  CFPreferences.swift
//  DarwinInit
//

import CoreFoundation
import CoreFoundation_Private.CFPreferences

enum CFPreferences {

    // CFPreferences.Domain FilePaths:
    // - Current User, Current Application, Current Host ~/Library/Preferences/ByHost/bundleID.hostID.plist
    // - Current User, Current Application, Any Host     ~/Library/Preferences/bundleID.plist
    // - Current User, Any Application, Current Host     ~/Library/Preferences/ByHost/.GlobalPreferences.hostID.plist
    // - Current User, Any Application, Any Host         ~/Library/Preferences/.GlobalPreferences.plist
    // - Any User, Current Application, Current Host     /Library/Preferences/bundleID.plist
    // - Any User, Current Application, Any Host         /Network/Library/Preferences/bundleID.plist (Unimplemented)
    // - Any User, Any Application, Current Host         /Library/Preferences/.GlobalPreferences.plist
    // - Any User, Any Application, Any Host             /Network/Library/Preferences/.GlobalPreferences.plist (Unimplemented)

    /// A Core Foundation "Preference Domain" to used specify the scope and location of a preference.
    ///
    /// A preference domain consists of three pieces of information, an application ID, a host name, and a user name.
    ///
    /// - note: Domains "(Any Application, Any User, Any Host)" and "(Current Application, Any User, Any Host)" are Unimplemented and "Any Host" is replaced with "Current Host"
    struct Domain: Hashable {
        /// The ID of the application whose preferences you wish to modify. Takes the form of a Java package name, e.g. `com.foosoft`.
        var applicationId: CFString
        /// `kCFPreferencesCurrentUser` to modify the current user’s preferences, otherwise `kCFPreferencesAnyUser` to modify the preferences of all users.
        var userName: CFString
        /// `kCFPreferencesCurrentHost` to search the current-host domain, otherwise `kCFPreferencesAnyHost` to search the any-host domain.
        var hostName: CFString

        /// Create a `CFPreferences.Domain` from an applicationID, userName, and hostName
        ///
        /// - parameter applicationID: application to restrict the preference to
        /// - parameter userName: user to restrict the preference to
        /// - parameter currentHost: host to restrict the preference to
        init(applicationId: CFString, userName: CFString, hostName: CFString) {
            self.applicationId = applicationId
            self.userName = userName
            self.hostName = hostName
        }
    }

    /// Internal set of domains accessed via the CFPreferences wrapper methods.
    /// Used for flushing caches.
    private static var accessedDomains = Set<Domain>()

    /// Returns a preference value for a given domain.
    ///
    /// `CFPreferences.getValue(for:in:)` searches only the exact domain specified.
    ///
    /// - parameter key: Preferences key for the value to obtain.
    /// - parameter domain: The domain to set the value into.
    static func getValue(for key: String, in domain: Domain) -> CFPropertyList? {
        accessedDomains.insert(domain)
        return CFPreferencesCopyValue(
            key as CFString,
            domain.applicationId,
            domain.userName,
            domain.hostName)
    }

    /// Adds, modifies, or removes a preference value for the specified domain.
    ///
    /// You must call the `CFPreferences.synchronize(domain:)` function in order for your changes to be saved to permanent storage.
    ///
    /// - parameter key: Preferences key for the value you wish to set.
    /// - parameter value: The value to set for key and application. Pass `nil` to remove key from the domain.
    /// - parameter domain: The domain to set the value into.
    static func `set`(value: CFPropertyList?, for key: String, in domain: Domain) {
        accessedDomains.insert(domain)
        CFPreferencesSetValue(
            key as CFString,
            value,
            domain.applicationId,
            domain.userName,
            domain.hostName)
    }

    /// For the specified domain, writes all pending changes to preference data to permanent storage, and reads latest preference data from permanent storage.
    ///
    /// This function is the primitive synchronize mechanism; it writes updated preferences to permanent storage, and reads the latest preferences from permanent storage. Only the exact domain specified is modified.
    ///
    /// - note: To modify "Any User" preferences requires root privileges (or Admin privileges prior to OS X v10.6)—see Authorization Services Programming Guide.
    ///
    /// - returns: `true` if synchronization was successful, `false` if an error occurred.
    static func synchronize(domain: Domain) -> Bool {
        accessedDomains.insert(domain)
        return CFPreferencesSynchronize(
            domain.applicationId,
            domain.userName,
            domain.hostName)
    }

    /// Flush a domain's cache from memory.
    ///
    /// - parameter domain: The domain whose cache should be flushed from memory to disk.
    private static func flushCache(domain: Domain) {
        // Use of this SPI was approved
        _CFPreferencesFlushCachesForIdentifier(domain.applicationId, domain.userName)
    }

    /// Flush all cached domains accessed via the CFPreferences wrapper.
    static func flushCaches() {
        for domain in accessedDomains {
            flushCache(domain: domain)
        }
        accessedDomains = Set<Domain>()
        // Use of this SPI was approved
        CFPreferencesFlushCaches()
    }
}

/// Errors related to modifying preferences.
enum CFPrefsError: Error {
    case synchronizeFailed
    case persistFailed
    case invalidValuePersisted(CFPropertyList)
}

extension CFPrefsError: CustomStringConvertible {
    var description: String {
        switch self {
        case .synchronizeFailed:
            "Failed to synchronize preferences"
        case .persistFailed:
            "Failed persist preferences"
        case .invalidValuePersisted(let value):
            "Invalid persisted value: \(value)"
        }
    }
}

extension CFPreferences {

    /// Adds, modifies, or removes a preference value for the specified domain, persists it and verifies it
    ///
    /// This is a combination of `CFPreferences.set`, `CFPreferences.synchronize`
    /// and `CFPreferences.flushCaches`. Afterwards the value will be read back and
    /// compared to what was being set to verify it. Throws a `CFPrefsError` on error.
    /// 
    /// - parameter key: Preferences key for the value you wish to set.
    /// - parameter value: The value to set for key and application. Pass `nil` to remove key from the domain.
    /// - parameter domain: The domain to set the value into.
    static func setVerified(value: CFPropertyList?, for key: String, in domain: Domain) throws {
        CFPreferences.set(value: value, for: key, in: domain)

        guard CFPreferences.synchronize(domain: domain) else {
            throw CFPrefsError.synchronizeFailed
        }

        CFPreferences.flushCaches()

        guard let actualValue = CFPreferences.getValue(for: key, in: domain) else {
            throw CFPrefsError.persistFailed
        }

        guard CFEqual(actualValue, value) else {
            throw CFPrefsError.invalidValuePersisted(actualValue)
        }
    }
}
