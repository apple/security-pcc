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

import CryptoKit
import Foundation

struct Auditor {
    var log: TransparencyLog
    var storageURL: URL
    var applicationTree: MerkleTree<SHA256>
    var perApplicationTree: MerkleTree<SHA256>
    var topLevelTree: MerkleTree<SHA256>
    var delegate: Delegate?

    private let appTreeFile = "applicationTree.json"
    private let perAppTreeFile = "perApplicationTree.json"
    private let tltTreeFile = "topLevelTree.json"

    init(for log: TransparencyLog, storageURL: URL) throws {
        self.log = log
        self.storageURL = storageURL
        let decoder = JSONDecoder()

        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        if let applicationTreeData = try? Data(contentsOf: storageURL.appending(path: appTreeFile)) {
            self.applicationTree = try decoder.decode(MerkleTree<SHA256>.self, from: applicationTreeData)
        } else {
            self.applicationTree = .init()
        }

        if let perApplicationTreeData = try? Data(contentsOf: storageURL.appending(path: perAppTreeFile)) {
            self.perApplicationTree = try decoder.decode(MerkleTree<SHA256>.self, from: perApplicationTreeData)
        } else {
            self.perApplicationTree = .init()
        }

        if let topLevelTreeFileData = try? Data(contentsOf: storageURL.appending(path: tltTreeFile)) {
            self.topLevelTree = try decoder.decode(MerkleTree<SHA256>.self, from: topLevelTreeFileData)
        } else {
            self.topLevelTree = .init()
        }
    }

    enum UpdateMode {
        /// Download and verify all three trees (AT, PAT, TLT), including the cross-tree bindings.
        case full
        /// Download and verify only the Application Tree (AT); skips PAT and TLT.
        ///
        /// Note: this only proves the AT log is internally consistent (its leaves reconstruct
        /// to the root advertised by the AT log head). It does *not* prove that the AT is
        /// anchored into the Per-Application and Top Level trees.
        case applicationTreeOnly
    }

    mutating func update(mode: UpdateMode = .full) async throws {
        switch mode {
        case .full:
            try await updateTopLevelTree()
        case .applicationTreeOnly:
            _ = try await updateObjectTree()
        }
    }

    func save(mode: UpdateMode = .full) throws {
        let encoder = JSONEncoder()

        // The Application Tree is the only tree touched in every mode, so write it first.
        let atURL = storageURL.appending(path: appTreeFile)
        let tempATURL = try FileManager.default.url(for: .itemReplacementDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: atURL,
                                                    create: true).appending(path: appTreeFile)
        try encoder.encode(applicationTree).write(to: tempATURL)

        // In AT-only mode PAT/TLT were never fetched, so leave their checkpoints untouched.
        if case .applicationTreeOnly = mode {
            _ = try FileManager.default.replaceItemAt(atURL,
                                                      withItemAt: tempATURL,
                                                      backupItemName: "\(appTreeFile).bak")
            return
        }

        let patURL = storageURL.appending(path: perAppTreeFile)
        let tempPATURL = try FileManager.default.url(for: .itemReplacementDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: patURL,
                                                     create: true).appending(path: perAppTreeFile)

        let topLevelURL = storageURL.appending(path: tltTreeFile)
        let tempTopLevelURL = try FileManager.default.url(for: .itemReplacementDirectory,
                                                          in: .userDomainMask,
                                                          appropriateFor: topLevelURL,
                                                          create: true).appending(path: tltTreeFile)

        try encoder.encode(perApplicationTree).write(to: tempPATURL)
        try encoder.encode(topLevelTree).write(to: tempTopLevelURL)

        _ = try FileManager.default.replaceItemAt(atURL,
                                                  withItemAt: tempATURL,
                                                  backupItemName: "\(appTreeFile).bak")
        _ = try FileManager.default.replaceItemAt(patURL,
                                                  withItemAt: tempPATURL,
                                                  backupItemName: "\(perAppTreeFile).bak")
        _ = try FileManager.default.replaceItemAt(topLevelURL,
                                                  withItemAt: tempTopLevelURL,
                                                  backupItemName: "\(tltTreeFile).bak")
    }

    private mutating func updateObjectTree() async throws -> UInt64 {
        let myTreeSize = UInt64(applicationTree.count)
        let tree = try await log.fetchLogTree(logType: .atLog)
        let head = try await log.fetchLogHead(logTree: tree)

        await delegate?.handleAuditEvent(.fetchedLogHead(tree: .application,
                                                         position: myTreeSize,
                                                         count: head.size))
        let newLeaves = try await log.fetchLogLeaves(type: TransparencyLog.ATLeaf.self,
                                                     tree: tree,
                                                     head: head,
                                                     start: myTreeSize)

        for leaf in newLeaves {
            applicationTree.append(leaf.nodeBytes)
            await delegate?.handleAuditEvent(.fetchedLeaf(tree: .application,
                                                          position: UInt64(applicationTree.count),
                                                          digest: Data(SHA256.leaf(data: leaf.nodeBytes))))
        }

        let updatedCount = applicationTree.count
        guard head.size == updatedCount else {
            await delegate?.handleAuditEvent(.constructionCompleted(tree: .application,
                                                                    status: .invalid))
            throw TransparencyLogError("Object tree size \(updatedCount) != log head tree size \(head.size)")
        }

        let merkleTreeDigest = applicationTree.rootDigest

        guard merkleTreeDigest == head.hash else {
            await delegate?.handleAuditEvent(.constructionCompleted(tree: .application,
                                                                    status: .invalid))
            throw TransparencyLogError("Object tree root hash \(merkleTreeDigest.hexString) does not match log head digest \(head.hash.hexString)")
        }
        await delegate?.handleAuditEvent(.constructionCompleted(tree: .application,
                                                                status: .valid(rootDigest: merkleTreeDigest)))
        return head.treeID
    }

    private mutating func updateRevisionTree() async throws -> UInt64 {
        let myTreeSize = UInt64(perApplicationTree.count)
        let tree = try await log.fetchLogTree(logType: .perApplicationTree)
        let head = try await log.fetchLogHead(logTree: tree)

        await delegate?.handleAuditEvent(.fetchedLogHead(tree: .perApplication,
                                                         position: myTreeSize,
                                                         count: head.size))
        let newLeaves = try await log.fetchLogLeaves(type: TransparencyLog.PATLeaf.self,
                                                     tree: tree,
                                                     head: head,
                                                     start: myTreeSize)

        guard head.size == (myTreeSize + UInt64(newLeaves.count)) else {
            throw TransparencyLogError("fetchLogLeaves returned short number of items")
        }

        let objectTreeID = try await updateObjectTree()

        for leaf in newLeaves {
            perApplicationTree.append(leaf.nodeBytes)
            await delegate?.handleAuditEvent(.fetchedLeaf(tree: .perApplication,
                                                          position: UInt64(perApplicationTree.count),
                                                          digest: Data(SHA256.leaf(data: leaf.nodeBytes))))

            switch leaf.node {
            case .config:
                break
            case .head(let head):
                guard head.treeID == objectTreeID else {
                    continue
                }
                let size = Int(head.size)
                let subDigest = applicationTree.digest(range: ..<size)
                guard subDigest == head.hash else {
                    await delegate?.handleAuditEvent(.constructionCompleted(tree: .perApplication,
                                                                            status: .invalid))
                    throw TransparencyLogError("Revision tree digest mismatch for revision \(head.revision), size \(head.size): \(subDigest.hexString) != \(head.hash.hexString)")
                }
            }
        }

        let updatedCount = perApplicationTree.count
        guard head.size == updatedCount else {
            await delegate?.handleAuditEvent(.constructionCompleted(tree: .perApplication,
                                                                    status: .invalid))
            throw TransparencyLogError("Revision tree size \(updatedCount) != log head tree size \(head.size)")
        }

        let merkleTreeDigest = perApplicationTree.rootDigest

        guard merkleTreeDigest == head.hash else {
            await delegate?.handleAuditEvent(.constructionCompleted(tree: .perApplication,
                                                                    status: .invalid))
            throw TransparencyLogError("Revision tree root hash \(merkleTreeDigest.hexString) does not match log head digest \(head.hash.hexString)")
        }
        await delegate?.handleAuditEvent(.constructionCompleted(tree: .perApplication,
                                                                status: .valid(rootDigest: merkleTreeDigest)))
        return head.treeID
    }

    private mutating func updateTopLevelTree() async throws {
        let myTreeSize = UInt64(topLevelTree.count)
        let tree = try await log.fetchLogTree(logType: .topLevelTree, application: .unknownApplication)
        let head = try await log.fetchLogHead(logTree: tree)

        await delegate?.handleAuditEvent(.fetchedLogHead(tree: .topLevel,
                                                         position: myTreeSize,
                                                         count: head.size))
        let newLeaves = try await log.fetchLogLeaves(type: TransparencyLog.TLTLeaf.self,
                                                     tree: tree,
                                                     head: head,
                                                     start: myTreeSize)

        // update revision tree
        let revisionTreeID = try await updateRevisionTree()

        for leaf in newLeaves {
            topLevelTree.append(leaf.nodeBytes)
            await delegate?.handleAuditEvent(.fetchedLeaf(tree: .topLevel,
                                                          position: UInt64(topLevelTree.count),
                                                          digest: Data(SHA256.leaf(data: leaf.nodeBytes))))
            
            switch leaf.node {
            case .config:
                continue

            case .head(let head):
                guard head.application == log.application, head.treeID == revisionTreeID else {
                    continue
                }
                let size = Int(head.size)
                let subDigest = perApplicationTree.digest(range: ..<size)
                guard subDigest == head.hash else {
                    await delegate?.handleAuditEvent(.constructionCompleted(tree: .topLevel,
                                                                            status: .invalid))
                    throw TransparencyLogError("Top Level Tree digest mismatch for revision \(head.revision), size \(head.size): \(subDigest.hexString) != \(head.hash.hexString)")
                }
            }
        }

        let updatedCount = topLevelTree.count
        guard head.size == updatedCount else {
            await delegate?.handleAuditEvent(.constructionCompleted(tree: .topLevel, status: .invalid))
            throw TransparencyLogError("Top level tree size \(updatedCount) != log head tree size \(head.size)")
        }

        let merkleTreeDigest = topLevelTree.rootDigest

        guard merkleTreeDigest == head.hash else {
            
            await delegate?.handleAuditEvent(.constructionCompleted(tree: .topLevel, status: .invalid))
            throw TransparencyLogError("Top level tree root hash \(merkleTreeDigest.hexString) does not match log head digest \(head.hash.hexString)")
        }
        await delegate?.handleAuditEvent(.constructionCompleted(tree: .topLevel,
                                                                status: .valid(rootDigest: merkleTreeDigest)))
    }
}
