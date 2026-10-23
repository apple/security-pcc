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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

// CryptexHelper provides a high-level interface to handling cryptex and disk images

import CryptoKit
import Foundation
import os
import StorageKit
import System

private let aaCommand = "/usr/bin/aa" // for apple archive files
private let unzipCommand = "/usr/bin/unzip" // for ipsw

struct CryptexHelper {
    typealias FileType = AssetHelper.FileType

    enum Error: Swift.Error, CustomStringConvertible {
        case notMounted
        case fileError(String)
        case unsupportedType(FileType)
        case storageKit(String)
        case cmdFailed(String)

        var description: String {
            switch self {
            case .notMounted: "not mounted/unpacked"
            case .fileError(let msg): msg
            case .unsupportedType(let ftype): "unsupported type: \(ftype.rawValue)"
            case .storageKit(let msg): msg
            case .cmdFailed(let msg): msg
            }
        }
    }

    struct skMount { // for DMG mounts: must maintain both handles for managed
        var skImage: SKDiskImage
        var skDisk: SKDisk
    }

    let archivePath: URL // path to the image this instance represents
    let fileType: FileType // type of image (explicitly set or detected)
    private(set) var mountPoint: URL? // where image is mounted or unpacked

    private var buildManifest: BuildManifest?
    private var buildManifestPath: URL? // location of BuildManifest.plist

    // directory under which pathnames listed in the BuildManifest are relative to
    var contentDir: URL? { self.buildManifestPath?.deletingLastPathComponent() ?? self.mountPoint }

    private var dmgMount: skMount? // for DMG mounts

    private static let logger = os.Logger(subsystem: applicationName, category: "CryptexHelper")

    init(
        path: String,
        fileType: FileType = .unknown // .aar, .dmg, .ipsw
    ) throws {
        let pathURL = FileManager.fileURL(path)
        self.archivePath = pathURL

        guard FileManager.isRegularFile(pathURL, resolve: true) else {
            CryptexHelper.logger.error("\(path) doesn't exist/regular file")
            throw Error.fileError("\(path) doesn't exist (as a regular file)")
        }

        var fileType = fileType
        if fileType == .unknown {
            fileType = try AssetHelper.fileType(pathURL)
        }

        switch fileType {
        case .aar, .dmg, .ipsw:
            self.fileType = fileType
        default:
            CryptexHelper.logger.error("\(path): unsupported type: \(fileType.rawValue, privacy: .public)  ")
            throw Error.unsupportedType(fileType)
        }

        CryptexHelper.logger.log("instance [path:\(path, privacy: .public); type:\(fileType.rawValue, privacy: .public)]")
    }

    // mount either attaches (dmg) or unpacks (other types) into either existing folder onto, or if nil,
    //  a temporary folder -- of attachOnly is true (and subject is a .DMG), it is attached to a block device
    //  (referenced by self.mountPoint) but not actually mounted
    @discardableResult
    mutating func mount(
        onto: String? = nil,
        attachOnly: Bool = false
    ) throws -> URL {
        if let onto {
            guard FileManager.isExist(onto, resolve: true) else {
                CryptexHelper.logger.error("unpack into: \(onto, privacy: .public); destination does not exist")
                throw Error.fileError("does not exist")
            }

            guard FileManager.isDirectory(onto, resolve: true) else {
                CryptexHelper.logger.error("unpack into: \(onto, privacy: .public); destination not a directory")
                throw Error.fileError("not a directory")
            }

            self.mountPoint = FileManager.fileURL(onto)
        } else if !attachOnly || self.fileType != .dmg {
            guard let onto = try? FileManager.tempDirectory(
                subPath: applicationName, UUID().uuidString
            ) else {
                CryptexHelper.logger.error("couldn't create tempdir")
                throw Error.fileError("failed to create tempdir")
            }

            self.mountPoint = onto
        }

        switch self.fileType {
        case .dmg:
            try self.mountDMG()
        case .aar:
            try self.unpackAAR()
        case .ipsw:
            try self.unpackZIP()
        default:
            throw Error.unsupportedType(self.fileType)
        }

        return self.mountPoint!
    }

    // eject unmounts a dmg attachment or otherwise removes the mountDir folder containing unpacked archive
    mutating func eject() throws {
        guard let mountPoint else {
            return
        }

        if self.dmgMount != nil {
            try self.ejectDMG()
        }

        try? Globals.computer.fileSystem.removeItem(at: mountPoint)
        self.mountPoint = nil
    }

    // loadBuildManifest locates and loads BuildManifest.plist within mounted/unpacked cryptex
    mutating func loadBuildManifest() throws -> BuildManifest {
        if let buildManifest = self.buildManifest {
            // already loaded
            return buildManifest
        }

        let buildManifestName = "BuildManifest.plist"
        guard let mountPoint else {
            throw Error.notMounted
        }

        for plist in [buildManifestName, "Restore/\(buildManifestName)"] {
            let plistPath = mountPoint.appending(path: plist)
            guard FileManager.isRegularFile(plistPath) else {
                continue
            }

            self.buildManifestPath = plistPath
            return try BuildManifest(plistPath)
        }

        let archivePath = self.archivePath.path
        CryptexHelper.logger.error("\(archivePath, privacy: .public): no BuildManifest.plist found")
        throw Error.cmdFailed("\(self.archivePath.lastPathComponent): no BuildManifest.plist found")
    }

    // mountDMG handles mounting a DMG file using StorageKit
    private mutating func mountDMG() throws {
        let attachParams = SKDiskImageAttachParams()
        if let mountPoint = self.mountPoint {
            attachParams.mountParams.mountPoint = mountPoint
            CryptexHelper.logger.log("mount DMG onto \(mountPoint, privacy: .public)")
        } else {
            // if no target mountPoint set, only attach image as block device
            attachParams.policy = SKDiskImageMountPolicy.NOMOUNT
        }
        attachParams.isManagedAttach = true
        attachParams.mountParams.noBrowse = true
        attachParams.mountParams.readOnly = true

        let archivePath = self.archivePath
        let dmgImage: SKDiskImage
        do {
            dmgImage = try SKDiskImage(url: archivePath)
        } catch {
            CryptexHelper.logger.log("storageKit: disk \(archivePath.path, privacy: .public) failed: \(error, privacy: .public)")
            throw Error.storageKit("SKDiskImage(\(archivePath.path): \(error)")
        }

        let dmgDisk: SKDisk
        do {
            dmgDisk = try dmgImage.attach(with: attachParams)
        } catch {
            CryptexHelper.logger.log("storageKit: mount \(archivePath.path, privacy: .public) failed: \(error, privacy: .public)")
            throw Error.storageKit("failed to mount: \(error)")
        }

        self.dmgMount = skMount(skImage: dmgImage, skDisk: dmgDisk)
        if self.mountPoint == nil,
           let diskDev = dmgDisk.diskIdentifier
        {
            let attachPoint = FileManager.fileURL("/dev").appendingPathComponent(diskDev)
            self.mountPoint = attachPoint
            CryptexHelper.logger.log("attached DMG onto \(attachPoint.path, privacy: .public)")
        }
    }

    // ejectDMG handles unmounting a DMG image previously mounted using StorageKit
    private mutating func ejectDMG() throws {
        guard let dmgMount = self.dmgMount else {
            return
        }

        let mountPoint = self.mountPoint!.path

        self.dmgMount = nil // regardless of successful eject, we're done with it

        do {
            try dmgMount.skDisk.eject()
        } catch {
            CryptexHelper.logger.error("eject DMG \(mountPoint, privacy: .public); failed=\(error, privacy: .public)")
            throw Error.storageKit("failed to eject \(mountPoint): \(error)")
        }
        CryptexHelper.logger.log("eject DMG \(mountPoint, privacy: .public)")
    }

    // unpackAAR unpacks an Apple ARchive file using the "aa" command
    private func unpackAAR() throws {
        CryptexHelper.logger.log("unpackAAR into \(self.mountPoint!.path, privacy: .public)")
        try self.execUnpack(cmdline: [aaCommand,
                                      "extract",
                                      "-i",
                                      self.archivePath.path,
                                      "-d",
                                      self.mountPoint!.path])
    }

    // unpackZIP unpacks an IPSW file using the "unzip" command
    private func unpackZIP() throws {
        CryptexHelper.logger.log("unpackZIP into \(self.mountPoint!.path, privacy: .public)")
        try self.execUnpack(cmdline: [unzipCommand,
                                      "-o",
                                      "-d",
                                      self.mountPoint!.path,
                                      "-q",
                                      self.archivePath.path])
    }

    // execUnpack handles the process exec of the unarchive utility passed in
    private func execUnpack(cmdline: [String]) throws {
        let (exitCode, _, stdError) = try ExecCommand(cmdline).run(
            outputMode: .none,
            queue: DispatchQueue(label: applicationName + ".exec", qos: .userInitiated)
        )

        guard exitCode == 0 || exitCode == 15 else { // ec=15 == (sig) terminated
            var errMsg = "de-archiver failed with error"
            if !stdError.isEmpty {
                errMsg += "; error=\"\(stdError)\""
            }

            throw Error.cmdFailed(errMsg)
        }
    }
}

extension CryptexHelper {
    typealias ManifestTag = String

    // CryptexHelper.DigestEntry represents a (file) entry in a BuildManifest build identity manifest
    struct DigestEntry {
        let path: String // relative to self.contentdir
        let manifest: Data // digest blob in manifest
        let computed: (any CryptoKit.Digest)? // collected from the file itself
    }

    typealias ManifestDigests = [ManifestTag: DigestEntry]

    // measure collects digests on files listed in the manifest - those without a digest included in
    //  the manifest or otherwise unable to determine the algo used are not included
    func measure(
        manifest: BuildManifest.BuildIdentity.Manifest
    ) throws -> ManifestDigests {
        guard let contentDir else {
            throw Error.notMounted
        }

        let fileCache: [String: any CryptoKit.Digest] = [:]
        var res: ManifestDigests = [:]

        for tag in manifest.tags {
            guard let path = manifest.path(tag),
                  let expDigest = manifest.digest(tag),
                  let expDigestType = manifest.digestType(tag)
            else {
                continue
            }

            let fullPath = contentDir.appendingPathComponent(path)

            var computed: (any Digest)?
            // if file already measured, reuse the result
            if let fc = fileCache[path],
               type(of: fc) == type(of: type(of: expDigestType))
            {
                computed = fc
            } else {
                computed = try? computeDigest(at: fullPath, using: expDigestType)
            }

            // encrypted DMGs (.dmg.aea) may need to be attached and measured as a block device
            if computed != nil, computed!.bytes != expDigest,
               let ftype = try? AssetHelper.fileType(fullPath), ftype == .dmg
            {
                if var aeaImage = try? CryptexHelper(path: fullPath.path, fileType: .dmg) {
                    try aeaImage.mount(attachOnly: true)
                    defer { try? aeaImage.eject() }

                    computed = try computeDigest(at: aeaImage.mountPoint!, using: expDigestType)
                }
            }

            res[tag] = DigestEntry(
                path: path,
                manifest: expDigest,
                computed: computed
            )
        }

        return res
    }
}
