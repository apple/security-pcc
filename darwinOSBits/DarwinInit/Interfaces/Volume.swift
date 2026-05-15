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
//  Volume.swift
//  darwin-init
//

import CryptoKit
import LocalAuthentication
import StorageKit
import APFS
import CoreFoundation

extension UUID {
    init(md5: Insecure.MD5Digest) {
        let m = md5.compactMap { UInt8($0) }
        let bytes: uuid_t = (m[0],  m[1],  m[2],  m[3],
                             m[4],  m[5],  m[6],  m[7],
                             m[8],  m[9],  m[10], m[11],
                             m[12], m[13], m[14], m[15])
        self.init(uuid: bytes)
    }
}

extension SKAPFSDisk {
    var rawAPFSRole: UInt16 {
        var role: UInt16 = UInt16(APFS_VOL_ROLE_NONE)
        APFSVolumeRole(self.diskIdentifier, &role, nil)
        return role
    }
}

enum VolumeError : Error {
    case missingKeys
}

@available(macOS 16.0, iOS 19.0, *)
extension SKManager {
    func internalDisk() -> SKAPFSContainerDisk? {
        if let disk = self.disk(forPath: "/") {
            if disk.isKind(of: SKAPFSDisk.self) {
                let disk = disk as! SKAPFSDisk
                return disk.container()!
            } else {
                logger.error("Internal disk is not an APFS container")
            }
        } else {
            logger.error("Unable to find internal disk")
        }

        return nil
    }

    func allVolumes() -> [SKAPFSDisk] {
        let container = self.internalDisk()
        return container!.volumesExcludingSnapshots() as! [SKAPFSDisk]
    }

    func findVolume(withName name: String, uuid: UUID) -> SKAPFSDisk {
        for volume in self.allVolumes() {
            if volume.volumeUUID == Volume.uuidForName(name: name).uuidString {
                assert(volume.volumeName == name)
                assert(volume.rawAPFSRole == APFS_VOL_ROLE_CACHE)
                return volume
            }
        }
        fatalError("StorageKit was unable to find the volume \"\(name)\" that was just created.")
    }

    func withUnsafeContainerNodeCString <ReturnType> (
        body: (UnsafePointer<CChar>) throws -> ReturnType
    ) rethrows -> ReturnType {
        let container = self.internalDisk()!
        let bsdName = container.diskIdentifier! as NSString
        return try body(bsdName.fileSystemRepresentation)
    }
}

@available(macOS 16.0, iOS 19.0, *)
class Volume : CustomStringConvertible {
    var keys: CacheVolumeKeyManager?
    fileprivate var skVolume: SKAPFSDisk
    var name: String {
        return skVolume.volumeName!
    }
    var uuid:UUID {
        return Volume.uuidForName(name: self.name)
    }

    internal static func uuidForName(name: String) -> UUID {
        // This UUID posesses no security properties.
        // It is merely a deterministic APFS identifier.
        var digest = Insecure.MD5()
        digest.update(data: Data(name.utf8))
        return UUID(md5: digest.finalize())
    }

    init(createVolumeNamed name: String, secret: Data) throws {
        let _uuid = Volume.uuidForName(name: name)

        var sk = SKManager.syncShared()

        // Get keys ready
        let k = try CacheVolumeKeyManager(forNewVolumeWith: _uuid, secret: secret)
        try sk.withUnsafeContainerNodeCString { containerNode in
            try k.unlock(disk: containerNode)
        }
        keys = k
        
        // Create volume in container
        let uuidStr: CFString = _uuid.uuidString as CFString
        let uuidRef = CFUUIDCreateFromString(kCFAllocatorDefault, uuidStr)
        let options = [
            kAPFSVolumeCreateSynchronousKey : true,
            kAPFSVolumeNameKey : name as CFString,
            kAPFSVolumeRoleKey : APFS_VOL_ROLE_CACHE,
            kAPFSVolumeUUIDKey: uuidRef,
        ] as CFDictionary
        sk.withUnsafeContainerNodeCString { containerNode in
            let rc = APFSVolumeCreate(containerNode, CFDictionaryCreateMutableCopy(nil, 4, options))
            logger.debug("Received APFSVolumeCreate status code: \(rc) = \(String(format: "0x%08x", rc))")
            assert(rc == 0)
        }

        // Wait till IOServices are idle and then call syncShared so SKManager can find the volume created
        // We must do this since we don't use SKManager to create the volume
        var wait = mach_timespec(tv_sec: 5, tv_nsec: 0)
        let rc = IOKitWaitQuiet(kIOMainPortDefault, &wait)
        logger.debug("Recieved IOKitWaitQuite status code: \(rc) = \(String(format: "0x%08x", rc))")
        
        sk = SKManager.syncShared()
        skVolume = sk.findVolume(withName: name, uuid: _uuid)
    }

    init(existingVolume volume: SKAPFSDisk) {
        skVolume = volume
        assert(self.uuid.uuidString == volume.volumeUUID)
    }

    static func list() -> [String : Volume] {
        var results: [String : Volume] = [:]
        for volume in SKManager.shared().allVolumes() {
            if volume.rawAPFSRole == APFS_VOL_ROLE_CACHE {
                let volume = Volume(existingVolume: volume)
                results[volume.name] = volume
            }
        }

        return results
    }

    func unlock() throws {
        guard let keys = self.keys else {
            throw VolumeError.missingKeys
        }

        let sk = SKManager.syncShared()
        try sk.withUnsafeContainerNodeCString { containerNode in
            try keys.unlock(disk: containerNode)
        }
    }

    func mount() async throws {
        try unlock();

        guard let keys = self.keys else {
            throw VolumeError.missingKeys
        }
        try keys.loadVolumeKeys()

        let error = await withCheckedContinuation { continuation in
            skVolume.mount(completionBlock: { error in
                continuation.resume(returning: error)
            })
        }
        if error != nil {
            throw error!
        }
    }

    func destroy() async throws {
        await withCheckedContinuation { continuation in
            skVolume.removeVolume(progress: nil, completionBlock: { success, error in
                if !success {
                    logger.error("StorageKit failed to remove volume with error: \(error)")
                }
                continuation.resume()
            })
        }

        guard let keys = self.keys else {
            throw VolumeError.missingKeys
        }
        try keys.unloadVolumeKeys()
        try keys.deleteKeys()
    }

    var description: String {
        return "<Volume name:\(self.name) uuid:\(self.uuid)>"
    }
}
