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

import CloudBoardAttestationDAPI
import CloudBoardLogging
import Foundation
import Security
import Security_Private.SecItemPriv

enum Keychain {
    enum Error: ReportableError {
        case failedToQueryForKeys(OSStatus, String? = nil)
        case failedToAddKeyToKeychain(OSStatus, String? = nil)
        case failedToDeleteKeyFromKeychain(OSStatus, String? = nil)
        case unexpectedSecClass
        case unexpectedResultType(CFTypeID)

        var publicDescription: String {
            let errorType = switch self {
            case .failedToQueryForKeys(let osStatus, _): "failedToQueryForKeys(osStatus: \(osStatus))"
            case .failedToAddKeyToKeychain(let osStatus, _): "failedToAddKeyToKeychain(osStatus: \(osStatus))"
            case .failedToDeleteKeyFromKeychain(let osStatus, _): "failedToDeleteKeyFromKeychain(osStatus: \(osStatus))"
            case .unexpectedSecClass: "unexpectedSecClass"
            case .unexpectedResultType: "unexpectedResultType"
            }
            return "keychain.\(errorType)"
        }
    }

    static var baseNodeKeyQuery: [String: Any] {
        return [
            kSecClass: kSecClassKey,
            kSecAttrKeyType: kSecAttrKeyTypeX25519!,
            kSecAttrKeySizeInBits: 256,
            kSecAttrEffectiveKeySize: 256,
            // We can't use kSecAttrTokenIDAppleKeyStore here instead of kSecAttrTokenIDSecureEnclave which would allow
            // for SecureEnclave emulation. CryptoKit's APIs for handling SecureEnclave keys are incompatible with such
            // keys.
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecAttrAccessGroup: CloudBoardAttestation.keychainAccessGroup,
        ] as [String: Any]
    }

    /// Returns Array of tuples of (SecKey, KeyId)
    static func findKeys(for attributes: [String: Any], keychain: SecKeychain? = nil) throws -> [(SecKey, Data)] {
        // Primary attributes for keys are:
        // kSecAttrKeyClass, kSecAttrKeyType, kSecAttrApplicationLabel, kSecAttrApplicationTag, kSecAttrKeySizeInBits,
        // and kSecAttrEffectiveKeySize.
        var query = attributes
        query[kSecReturnRef as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        if let secClass = query[kSecClass as String], secClass as! CFString != kSecClassKey {
            throw Error.unexpectedSecClass
        } else if query[kSecClass as String] == nil {
            query[kSecClass as String] = kSecClassKey
        }

        query.addKeychainAttributes(keychain: keychain, for: .lookup)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess else {
            let errMsg = SecCopyErrorMessageString(status, nil)
            throw Error.failedToQueryForKeys(status, errMsg as String?)
        }
        guard let resultDict = result as? [[String: Any]] else {
            throw Error.unexpectedResultType(CFGetTypeID(result))
        }

        return resultDict.map { result in
            let secKey = result[kSecValueRef as String] as! SecKey?
            let keyId = result[kSecAttrApplicationTag as String] as! Data?
            return (secKey!, keyId!)
        }
    }

    static func add(key secKey: SecKey, keyId: Data, keychain: SecKeychain? = nil) throws {
        var itemAddParams = [
            kSecClass: kSecClassKey,
            kSecValueRef: secKey,
            kSecAttrAccessGroup: CloudBoardAttestation.keychainAccessGroup,
            kSecAttrApplicationTag: keyId,
        ] as [String: Any]
        itemAddParams.addKeychainAttributes(keychain: keychain, for: .update)

        let status = SecItemAdd(itemAddParams as CFDictionary, nil)
        guard status == errSecSuccess else {
            let errorMessage = SecCopyErrorMessageString(status, nil)
            throw Error.failedToAddKeyToKeychain(status, errorMessage as String?)
        }
    }

    static func delete(key: SecKey, keychain: SecKeychain? = nil) throws {
        var query = [
            kSecClass: kSecClassKey,
            kSecValueRef: key,
        ] as [String: Any]
        query.addKeychainAttributes(keychain: keychain, for: .update)

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess else {
            let errorMessage = SecCopyErrorMessageString(status, nil)
            throw Error.failedToDeleteKeyFromKeychain(status, errorMessage as String?)
        }
    }

    static func delete(persistentKeyRef: Data, keychain: SecKeychain? = nil) throws {
        var query = [
            kSecClass: kSecClassKey,
            kSecValuePersistentRef: persistentKeyRef,
        ] as [String: Any]
        query.addKeychainAttributes(keychain: keychain, for: .update)

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess else {
            let errorMessage = SecCopyErrorMessageString(status, nil)
            throw Error.failedToDeleteKeyFromKeychain(status, errorMessage as String?)
        }
    }
}

extension [String: Any] {
    enum KeychainAction {
        case lookup
        case update
    }

    mutating func addKeychainAttributes(keychain: SecKeychain?, for action: KeychainAction) {
        #if os(macOS)
        if let keychain {
            // For legacy keychain used in testing

            switch action {
            case .lookup:
                // For lookups
                self[kSecMatchSearchList as String] = [keychain]
            case .update:
                // For adds/deletes
                self[kSecUseKeychain as String] = keychain
            }
        } else {
            self[kSecUseSystemKeychainAlways as String] = true
        }
        #else
        self[kSecUseDataProtectionKeychain as String] = true
        #endif
    }
}
