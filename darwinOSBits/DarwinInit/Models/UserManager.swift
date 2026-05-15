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
//  UserManager.swift
//  darwinOSBits
//
//

import Foundation
import System
import sys_types

struct UserManager {

    struct User {
        let name: String
        let uid: uid_t
        let gid: gid_t

        var password: String?
        var isAdmin: Bool = false
        var sshAuthorizedKeys: String?

        var passwordlessSudo: Bool = false
        var plaintextPassword: String?

        var esc: EngineeringSSHCA.Config?
        var memento: MementoSSH.Config?
    }

    let computer: any Computer

    /// Create the user with the supplied information
    func create(user: User) -> Bool {
#if os(macOS)

        let ok = OpenDirectory.create(user: user)
        if !ok {
            logger.error("darwin-init failed to create new user.")
        }
        return ok
#else
        return false
#endif
    }

    /// Checks if the user already exits
    func userExists(user: User) -> Bool {
        return getpwnam(user.name) != nil
    }

    /// Get a specific system user by name
    ///
    /// This function looks up a user by name and creates a User object
    /// containing their complete information including:
    ///     - username, uid, gid
    ///     - SSH authorized keys
    ///     - admin status (isAdmin).
    ///
    /// - Parameter name: The username to look up
    /// - Returns: A User object if the user exists, nil otherwise
    func getUser(withName name: String) -> User? {
        guard let pw = getpwnam(name) else {
            return nil
        }

        let uid = pw.pointee.pw_uid
        let gid = pw.pointee.pw_gid

        // Read SSH authorized keys if they exist
        let sshAuthorizedKeys = readSSHAuthorizedKeys(for: name)

        // Check if user is admin
        let isAdmin = checkIfUserIsAdmin(username: name)

        var user = User(
            name: name,
            uid: uid,
            gid: gid,
        )

        user.sshAuthorizedKeys = sshAuthorizedKeys
        user.isAdmin = isAdmin

        return user
    }

    /// Configures SSH keys for the specified user according to config set in DInitUserConfig
    ///
    /// - Precondition: The specified user already exists on the system and has a home directory.
    /// - Returns: `true` for success, `false` for failure.
    func setSSHAuthorizedKeys(for user: User) -> Bool {
        guard let sshAuthorizedKeys = user.sshAuthorizedKeys else {
            return true
        }
        // Create the .ssh directory, and set owner
        logger.log("Creating .ssh/authorized_keys")

        guard let homeDirectory = NSHomeDirectoryForUser(user.name).map({ FilePath($0) }) else {
            logger.fault("failed to set SSH keys for user \(user.name), home directory does not exist.")
            return false
        }

        let sshDirectory = homeDirectory.appending(".ssh")
        do {
            try sshDirectory.createDirectory(permissions: .ownerReadWriteExecute)
        } catch Errno.fileExists {
            logger.info("ssh directory already created")
        } catch {
            logger.fault("failed to make new ssh directory with error \(error.localizedDescription)")
            return false
        }

        do {
            try sshDirectory.chown(owner: user.uid, group: user.gid)
        } catch {
            logger.fault("failed to chown new ssh directory with error \(error.localizedDescription)")
            return false
        }

        // Create the file and set owner and permissions
        let sshAuthorizedKeysPath = sshDirectory.appending("authorized_keys")
        do {
            try sshAuthorizedKeysPath.save(sshAuthorizedKeys)
        } catch {
            logger.fault("write of authorized_key failed with error \(error.localizedDescription)")
            return false
        }

        do {
            try sshAuthorizedKeysPath.chown(owner: user.uid, group: user.gid)
        } catch {
            logger.fault("failed to chown new authorized_keys with error \(error.localizedDescription)")
            return false
        }

        do {
            try sshAuthorizedKeysPath.chmod(permissions: .ownerReadWrite)
        } catch {
            logger.fault("failed to chmod new ssh directory with error \(error.localizedDescription)")
            return false
        }
        return true
    }

    func setup(user: User) -> Bool {
        if computer.platform == .macOS {
            guard create(user: user) else {
                logger.error("darwin-init failed to create new user.")
                return false
            }
        } else {
            guard userExists(user: user) else {
                logger.error("darwin-init can only modify existing user accounts on this platform and user \(user.name) does not exist.")
                return false
            }
        }

        // From here on, we assume user exists and has a home directory
        guard setSSHAuthorizedKeys(for: user) else {
            logger.error("darwin-init failed to get setSSHAuthorizedKeys.")
            return false
        }

        if user.passwordlessSudo {
            guard computer.configurePasswordlessSudo() else {
                logger.error("darwin-init failed to configurePasswordlessSudo.")
                return false
            }
        }

        if computer.platform == .macOS {
            // print a banner on macOS for now, but apply the config anyway
            logger.info("SSH access to \(user.name) cannot be controlled using ESC and AppleConnect on macOS")
        }

        // Restrict account ESC SSH access.
        // Passing a nil appleConnectSSHConfig will disable access to the account using ESC
        // This is what we want to do as a default on BMC /ComputeNode but not in darwinOS in general
        if user.esc != nil || computer.isBMC || computer.isComputeNode {
            guard EngineeringSSHCA.restrictAccessTo(account: user.name, config: user.esc) else {
                logger.error("darwin-init failed to restrict ESC SSH access for \(user.name)")
                return false
            }
        }

        if let memento = user.memento {
            guard MementoSSH.setup(for: user.name,
                    users: memento.users,
                    groups: memento.groups,
                    ldapServer: memento.ldapServer) else {
                logger.error("failed to setup memento ssh")
                return false
            }
        }

        return true
    }

}

extension UserManager {
    /// Reads SSH authorized keys for a given user
    ///
    /// - Parameter username: The username to read SSH keys for
    /// - Returns: The contents of the authorized_keys file, or nil if it doesn't exist
    private func readSSHAuthorizedKeys(for username: String) -> String? {
        guard let homeDirectory = NSHomeDirectoryForUser(username).map({ FilePath($0) }) else {
            return nil
        }

        let sshAuthorizedKeysPath = homeDirectory.appending(".ssh").appending("authorized_keys")

        do {
            return try sshAuthorizedKeysPath.loadString()
        } catch {
            // File doesn't exist or can't be read
            return nil
        }
    }

    /// Checks if a user is a member of the admin group
    ///
    /// - Parameter username: The username to check
    /// - Returns: true if the user is an admin, false otherwise
    private func checkIfUserIsAdmin(username: String) -> Bool {
        // Get the admin group (GID 80 on macOS, but we'll look it up properly)
        guard let adminGroup = getgrnam("admin") else {
            return false
        }

        // Check if username is in the admin group's member list
        var memberPtr = adminGroup.pointee.gr_mem
        while let member = memberPtr?.pointee {
            let memberName = String(cString: member)
            if memberName == username {
                return true
            }
            memberPtr = memberPtr?.advanced(by: 1)
        }

        return false
    }
}
