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
//  MementoKeys.swift
//  DarwinInit
//

import Foundation
import ArgumentParserInternal
import os
import System
import CryptoKit

struct MementoKeys: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fetch the memento keys for given user or group",
        discussion: """
Fetch the memento SSH public keys for specified users or all members of a specified \
group from LDAP server, then output all the keys to stdout.
""")

    @Option(name: [.customLong("user"), .short], help: "UserID to fetch memento key for")
    var users: [String] = []
    
    @Option(name: [.customLong("group"), .short], help: "GroupID whose members to fetch memento key for")
    var groups: [String] = []

	@Option(name: [.customLong("server"), .customShort("s")], help: "LDAP server to fetch memento key from. Defaults to nod.apple.com")
    var ldapServer: String = "nod.apple.com"
    
    internal func getCacheFile() -> FilePath {
        // Use the program arguments hash to be the identifier of the cache
        let data = Data(String(CommandLine.arguments.joined()).utf8)
        let digest = SHA256.hash(data: data)
        return kDInitPersistStorage.appending(digest.compactMap { String(format: "%02x", $0) }.joined())
    }
    
    internal func readCache(from cacheFile: FilePath) throws -> String {
        do {
            let fileStat = try FileStat(cacheFile)
            if fileStat.lastModificationTime.distance(to: Date.now) < kDInitSSHPublicKeysCacheExpirationTime {
                return try cacheFile.loadString()
            } else {
                logger.log("Memento cache expired")
                throw MementoKeysError.cacheExpired
            }
        } catch Errno.noSuchFileOrDirectory {
            logger.info("Memento cache \(cacheFile) doesn't exist")
            throw MementoKeysError.cacheNotExist
        }
    }
    
    internal func writeCache(_ content: String, to cacheFile: FilePath) throws {
        if try !kDInitPersistStorage.directoryExists() {
            try kDInitPersistStorage.createDirectory()
        }
        return try cacheFile.save(content)
    }
    
    internal func queryLDAP() async throws -> String {
        var finalUsers = Set(users)
        var sshPublicKeys: [String] = []

        for group in groups {
            do {
                // if the ldap server has a different schema than nod.apple.com this query would fail.
                // we'll need to have the schema info passed in if we need to support that in the future
                let result = try await LDAP.query(from: ldapServer, recordDN: "cn=\(group),cn=groups,dc=apple,dc=com", attributes: ["memberUid"])
                if let uids = result["memberUid"] as? [String] {
                    finalUsers.formUnion(uids)
                }
            } catch {
                logger.error("Failed to query memberUid from group \(group): \(error)")
            }
        }

        for user in finalUsers {
            do {
                // if the ldap server has a different schema than nod.apple.com this query would fail.
                // we'll need to have the schema info passed in if we need to support that in the future
                let result = try await LDAP.query(from: ldapServer, recordDN: "uid=\(user),cn=users,dc=apple,dc=com", attributes: ["sshPublicKey"])
                if let keys = result["sshPublicKey"] as? [String] {
                    sshPublicKeys.append(contentsOf: keys)
                    logger.log("Added public key for user \(user):\n\(keys)")
                }
            } catch {
                logger.error("Failed to query sshPublicKey from user \(user): \(error)")
            }
        }
        
        return sshPublicKeys.joined(separator: "\n")
    }

    func run() async throws {
        var sshPublicKeys: String
        
        let cacheFile = getCacheFile()

        do {
            sshPublicKeys = try self.readCache(from: cacheFile)
        } catch {
            logger.log("Memento cache is not available, fetching live records")

            try await sshPublicKeys = queryLDAP()
            
            do {
                try self.writeCache(sshPublicKeys, to: cacheFile)
                logger.log("Memento cache saved")
            } catch {
                logger.error("Fail to save memento cache: \(error)")
            }
        }

        print("\(sshPublicKeys)")
    }
}

enum MementoKeysError: Error {
    case cacheNotExist
    case cacheExpired
}
