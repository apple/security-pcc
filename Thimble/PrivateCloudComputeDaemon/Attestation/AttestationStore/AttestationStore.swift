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
//  AttestationStore.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
import SwiftData
import os.lock

protocol AttestationStoreProtocol: Sendable {
    func saveValidatedAttestation(
        _ validatedAttestation: ValidatedAttestation,
        for parameters: Workload,
        prefetched: Bool,
        batch: UInt,
        fetchTime: Date
    ) async -> Bool
    func getAttestationsForRequest(
        nodeKind: NodeKind,
        parameters: Workload,
        serverRequestID: UUID,
        maxAttestations: Int
    ) async -> [String: ValidatedAttestation]
    func deleteAllAttestationStoreEntries() async
    func deleteEntriesWithExpiredAttestationBundles() async
    func deleteEntryForNode(nodeIdentifier: String) async -> Bool
    func deleteEntries(
        withParameters parameters: Workload,
        batchId: UInt
    ) async
    func nodeExists(udid: String) async -> Bool
    func trackNodeForParameters(
        forParameters parameters: Workload,
        withUdid udid: String,
        prefetched: Bool,
        batchID: UInt,
        fetchTime: Date
    ) async -> Bool
    func attestationsExist(
        forParameters: Workload,
        clientCacheSize: Int,
        fetchTime: Date
    ) async -> Bool
    func deleteAttestationsUsedByTrustedRequest(
        serverRequestID: UUID
    ) async -> UInt
    func getAttestationBundlesUsedByTrustedRequest(
        serverRequestID: UUID
    ) async -> [String: Data]
}

private let logger = tc2Logger(forCategory: .attestationStore)

extension AttestationStore {
    typealias Workload = AttestationStore.SchemaV2.Workload
    typealias Node = AttestationStore.SchemaV2.Node
}

@ModelActor
final actor AttestationStore: AttestationStoreProtocol, Sendable {
    init?(environment: TC2Environment, dir: URL) {
        let storesDir = Self.storesDir(rootDir: dir, environment: environment)
        Self.removeOldStoreFiles(storesDir: storesDir)

        let storeFileURL = storesDir.appendingPathComponent("attestationstore_v2.sqlite", isDirectory: false)
        logger.log("attestation store path: \(storeFileURL)")
        let configuration = ModelConfiguration(url: storeFileURL)
        guard let currentVersionedSchema = SchemaMigrationPlan.schemas.last else {
            logger.error("failed to init attestation store, missing schema")
            return nil
        }
        let schema = Schema(versionedSchema: currentVersionedSchema)
        do {
            let container = try ModelContainer(for: schema, migrationPlan: SchemaMigrationPlan.self, configurations: configuration)
            self.init(modelContainer: container)
        } catch {
            logger.error("failed to init attestation store, error=\(error)")
            return nil
        }
    }

    private static func removeOldStoreFiles(storesDir: URL) {
        // In CrystalGlowE we updated the scheme discarding all previously
        // stored data by renaming underlying storage filename. Let's remove
        // the files used by old schema.
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storesDir.relativePath) else {
            // Very first launch and `Stores_production` directory hasn't been created yet.
            return
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: storesDir, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix("attestation_store_v0.2.sqlite") {
                removeDaemonStateFile(url: file)
            }
        } catch {
            logger.error("error obtaining contents of stores directory error=\(error)")
        }
    }

    static func migrate(from source: URL, to destination: URL) {
        // We're only going to migrate a production attestation store.
        // Unfortunately we do not yet know, at migration, which env we're in.
        let sourceFile = storesDir(rootDir: source, environment: .production)
        let destinationFile = storesDir(rootDir: destination, environment: .production)
        moveDaemonStateFile(from: sourceFile, to: destinationFile)
    }

    private static func storesDir(rootDir: URL, environment: TC2Environment) -> URL {
        // Next time we have an opportunity to discard previous version of attestation store, we should at least remove
        // addition of environment name into the directory name since in non-prod environments root dir will be already
        // specific to the environment. Additionally, it may make sense to rename the directory to `AttestationStore`
        // or even consider removing it.
        let dirName = "Stores_\(environment.name)"
        return rootDir.appendingPathComponent(dirName, isDirectory: true)
    }

    /// This will only be ever called for a brand new Attestation that doesn't have an entry in the TC2NodeStore
    func saveValidatedAttestation(
        _ validatedAttestation: ValidatedAttestation,
        for parameters: PrivateCloudCompute.Workload,
        prefetched: Bool,
        batch: UInt,
        fetchTime: Date
    ) -> Bool {
        logger.log("saveValidatedAttestation: \(validatedAttestation.attestation.nodeID) batch: \(batch) prefetched: \(prefetched) fetchTime: \(fetchTime) cloudOSVersion: \(validatedAttestation.attestation.cloudOSVersion)")

        guard let udid = validatedAttestation.udid else {
            logger.error("missing validatedAttestation.udid")
            return false
        }
        guard let validatedCellID = validatedAttestation.validatedCellID else {
            logger.error("missing validatedAttestation.validatedCellID")
            return false
        }
        guard let bundle = validatedAttestation.attestation.attestationBundle else {
            logger.error("missing validatedAttestation.attestation.attestationBundle")
            return false
        }

        // First create an entry in the TC2NodeStore for this attestation
        let newNodeEntry = AttestationStore.Node(
            udid: udid,
            kind: .init(validatedAttestation.nodeKind),
            ropesNodeIdentifier: validatedAttestation.attestation.nodeID,
            attestationBundle: bundle,
            attestationExpiry: validatedAttestation.attestationExpiry,
            publicKey: validatedAttestation.publicKey,
            cloudOSVersion: validatedAttestation.attestation.cloudOSVersion,
            cloudOSReleaseType: validatedAttestation.attestation.cloudOSReleaseType,
            cellID: validatedCellID,
            ensembleID: validatedAttestation.attestation.ensembleID
        )
        modelContext.insert(newNodeEntry)

        // Then link the parameters to use this Node
        if let params = fetchParamsEntry(parameters: parameters, batchId: batch) {
            if !params.nodeUdids.contains(udid) {
                params.nodeUdids.append(udid)
            }
        } else {
            // Create a new tracking entry for this set of parameters
            logger.log("Linking \(udid) to ...")
            createNewParamsEntry(
                parameters: parameters,
                withNode: udid,
                isPrefetched: prefetched,
                batchId: batch,
                time: fetchTime)
        }

        do {
            try modelContext.save()
            return true
        } catch {
            logger.error("failed to insert entry: \(error)")
            return false
        }
    }

    func getAllNodesAndAttestations() -> [String: ValidatedAttestation] {
        do {
            // A validated attestation is created for every parameter we have fetched so far
            var attestations: [String: ValidatedAttestation] = [:]
            let prefetchEntries = try modelContext.fetch(FetchDescriptor<AttestationStore.Workload>())
            for prefetchEntry in prefetchEntries {
                let nodeUdids = prefetchEntry.nodeUdids
                let queryNodePredicate = #Predicate<AttestationStore.Node> { entry in
                    nodeUdids.contains(entry.udid)
                }
                do {
                    let nodes = try modelContext.fetch(FetchDescriptor(predicate: queryNodePredicate))
                    for node in nodes {
                        attestations[node.ropesNodeIdentifier] = .init(
                            entry: node
                        )
                    }
                } catch {
                    // It is possible that the parameter set can be tracking nodes that no longer exist
                    logger.error("failed to query attestations error: \(error)")
                }
            }
            return attestations
        } catch {
            logger.error("failed to query attestations error: \(error)")
            return [:]
        }
    }

    func getAttestationsForRequest(
        nodeKind: NodeKind,
        parameters: PrivateCloudCompute.Workload,
        serverRequestID: UUID,
        maxAttestations: Int
    ) -> [String: ValidatedAttestation] {
        logger.log("getAttestationsForRequest id=\(serverRequestID) nodeKind=\(nodeKind)")

        let today = Date()
        let (workloadType, inferenceId) = parameters.prefetchAttributes

        let prefetchPredicate = #Predicate<AttestationStore.Workload> { entry in
            entry.type == workloadType && entry.inferenceId == inferenceId && entry.usedByTrustedRequestWithId == nil
        }

        do {
            // A validated attestation is created for every parameter we have fetched so far
            var attestations: [String: ValidatedAttestation] = [:]
            let sortByFetchTime = SortDescriptor(\AttestationStore.Workload.fetchTime, order: .forward)
            let prefetchDescriptor = FetchDescriptor(predicate: prefetchPredicate, sortBy: [sortByFetchTime])
            let prefetchEntries = try modelContext.fetch(prefetchDescriptor)

            let rawKind = AttestationStore.Node.Kind(nodeKind).rawValue

            outerLoop: for batchToUse in prefetchEntries {
                var count = 0
                let nodeUdids = batchToUse.nodeUdids
                let queryNodePredicate: Predicate<AttestationStore.Node>
                if nodeKind == .direct {
                    // treat rawKind not being set as `.direct` too
                    queryNodePredicate = #Predicate<AttestationStore.Node> { entry in
                        (entry.rawKind == nil || entry.rawKind == rawKind) && nodeUdids.contains(entry.udid) && entry.attestationExpiry >= today
                    }
                } else {
                    queryNodePredicate = #Predicate<AttestationStore.Node> { entry in
                        entry.rawKind == rawKind && nodeUdids.contains(entry.udid) && entry.attestationExpiry >= today
                    }

                }
                do {
                    let nodes = try modelContext.fetch(FetchDescriptor(predicate: queryNodePredicate)).shuffled()
                    innerLoop: for node in nodes {
                        attestations[node.ropesNodeIdentifier] = .init(
                            entry: node
                        )
                        count += 1
                        if count >= maxAttestations {
                            break innerLoop
                        }
                    }
                    if !attestations.isEmpty {
                        batchToUse.usedByTrustedRequestWithId = serverRequestID
                        logger.log("getAttestationsForRequest \(serverRequestID) returned batch: \(batchToUse.batchId) nodes count: \(attestations.count)")
                        if modelContext.hasChanges {
                            try modelContext.save()
                        }
                        break
                    }
                } catch {
                    logger.error("failed to query nodes, error: \(error)")
                }
            }

            return attestations
        } catch {
            logger.error("failed to query unexpired attestations: \(error)")
            return [:]
        }
    }

    func deleteEntriesWithExpiredAttestationBundles() {
        logger.log("deleteEntriesWithExpiredAttestationBundles")

        // This will just delete the node entries from the NodeStore
        // Parameter store may have stale entries, but that should be ok since there will be no underlying node
        let today = Date()

        let queryPredicate = #Predicate<AttestationStore.Node> { entry in
            today > entry.attestationExpiry
        }

        do {
            try modelContext.delete(model: AttestationStore.Node.self, where: queryPredicate)
        } catch {
            logger.error("failed to delete expired attestations: \(error)")
        }
    }

    func deleteEntries(
        withParameters parameters: PrivateCloudCompute.Workload,
        batchId: UInt
    ) {
        let (workloadType, inferenceId) = parameters.prefetchAttributes
        logger.log("deleteEntries workloadType=\(workloadType) inferenceId=\(inferenceId) batchId=\(batchId)")

        let queryPredicate = #Predicate<AttestationStore.Workload> { entry in
            entry.type == workloadType && entry.inferenceId == inferenceId && entry.batchId == batchId
        }

        do {
            try modelContext.delete(model: AttestationStore.Workload.self, where: queryPredicate)
        } catch {
            logger.error("failed to delete entries: \(error)")
        }
    }

    func deleteAllAttestationStoreEntries() {
        logger.log("deleteAllAttestationStoreEntries")

        do {
            try modelContext.delete(model: AttestationStore.Node.self)
            try modelContext.delete(model: AttestationStore.Workload.self)
        } catch {
            logger.error("failed to delete all entries: \(error)")
        }
    }

    /// Delete a node entry by looking up the ROPES provided identifier
    /// This is called in the invoke path where ROPES may tell the client that a few attestations sent by the client are unusable
    func deleteEntryForNode(nodeIdentifier: String) -> Bool {
        logger.log("deleteEntryForNode: \(nodeIdentifier)")

        let queryPredicate = #Predicate<AttestationStore.Node> { entry in
            entry.ropesNodeIdentifier == nodeIdentifier
        }

        do {
            try modelContext.delete(model: AttestationStore.Node.self, where: queryPredicate)
        } catch {
            logger.error("failed to delete entry for node with ropes identifier: \(nodeIdentifier) with error: \(error)")
            return false
        }

        return true
    }

    func nodeExists(udid: String) -> Bool {
        logger.log("nodeExists: checking if \(udid) node exists")

        // Return true if we have this node (unexpired) at all in our NodeStore to ensure we save on validation effort
        let today = Date()

        let queryPredicate = #Predicate<AttestationStore.Node> { entry in
            entry.udid == udid && entry.attestationExpiry >= today
        }

        do {
            return try modelContext.fetchCount(FetchDescriptor(predicate: queryPredicate)) > 0
        } catch {
            logger.error("failed to query nodes: \(error)")
        }

        return false
    }

    /// Checks to see if node with uniqueIdentifier is tracked in a given batch and for a parameters set, if not, it will add the tracking
    /// Returns true if parameters set already tracks this node in this batch
    /// This is to ensure that we calculate duplicates in a batch and not across batches
    func trackNodeForParameters(
        forParameters parameters: PrivateCloudCompute.Workload,
        withUdid udid: String,
        prefetched: Bool,
        batchID: UInt,
        fetchTime: Date
    ) -> Bool {
        logger.log("trackNodeForParameters: checking if \(udid) node tracks params")

        do {
            // let's ensure that the parameters cache is tracking this entry
            if nodeExistsInBatch(parameters: parameters, udid: udid, batchID: batchID) {
                return true
            } else {
                if let params = fetchParamsEntry(parameters: parameters, batchId: batchID) {
                    params.nodeUdids.append(udid)
                } else {
                    // Create a new tracking entry for this set of parameters and batch
                    logger.log("Linking \(udid) to ...")
                    createNewParamsEntry(
                        parameters: parameters,
                        withNode: udid,
                        isPrefetched: prefetched,
                        batchId: batchID,
                        time: fetchTime
                    )
                }
            }
            try modelContext.save()
        } catch {
            logger.error("failed to query nodes: \(error)")
        }

        return false
    }

    /// Fetches an entry for a particular parameter set - if it exists in the store
    private func fetchParamsEntry(parameters: PrivateCloudCompute.Workload, batchId: UInt) -> AttestationStore.Workload? {
        let (workloadType, inferenceId) = parameters.prefetchAttributes
        logger.log("fetchParamsEntry workloadType=\(workloadType) inferenceId=\(inferenceId)")

        let queryPredicate = #Predicate<AttestationStore.Workload> { entry in
            entry.type == workloadType && entry.inferenceId == inferenceId && entry.batchId == batchId
        }

        // Uniqueness attribute cannot be a combination of keys in SwiftData
        // Because of that, we will need to ensure that only one set of parameters are tracked per batch fetched

        // See WWDC Video - This is possible with #Unique
        do {
            let prefetchEntries = try modelContext.fetch(FetchDescriptor(predicate: queryPredicate))
            return prefetchEntries.first
        } catch {
            logger.error("failed to query entries: \(error)")
            return nil
        }
    }

    /// Create a new entry in the parameters table to track a set of previously unknown parameters
    private func createNewParamsEntry(parameters: PrivateCloudCompute.Workload, withNode nodeUdid: String, isPrefetched: Bool, batchId: UInt, time: Date) {
        // Create a new tracking entry for this set of parameters
        let (workloadType, inferenceId) = parameters.prefetchAttributes
        logger.log("createNewParamsEntry workloadType=\(workloadType) inferenceId=\(inferenceId)")

        let newPrefetchEntry = AttestationStore.Workload(
            type: workloadType,
            inferenceId: inferenceId,
            model: "",  // field could be removed in a future schema iteration
            adapter: "",  // field could be removed in a future schema iteration
            isPrefetched: isPrefetched,
            fetchTime: time,
            nodeUdid: nodeUdid,
            batchId: batchId
        )
        modelContext.insert(newPrefetchEntry)
    }

    private func nodeExistsInBatch(parameters: PrivateCloudCompute.Workload, udid: String, batchID: UInt) -> Bool {
        let (workloadType, inferenceId) = parameters.prefetchAttributes
        logger.log("nodeExistsInBatch workloadType=\(workloadType) inferenceId=\(inferenceId)")

        let queryPredicate = #Predicate<AttestationStore.Workload> { entry in
            entry.type == workloadType && entry.inferenceId == inferenceId && entry.batchId == batchID
        }

        do {
            let prefetchEntry = try modelContext.fetch(FetchDescriptor(predicate: queryPredicate))
            if let prefetchEntry = prefetchEntry.first {
                if prefetchEntry.nodeUdids.contains(udid) {
                    return true
                }
            }
        } catch {
            logger.error("failed to query entries: \(error)")
        }

        return false
    }

    func attestationsExist(forParameters workload: PrivateCloudCompute.Workload, clientCacheSize: Int, fetchTime: Date) -> Bool {
        let (workloadType, inferenceId) = workload.prefetchAttributes
        logger.log("attestationsExist workloadType=\(workloadType) inferenceId=\(inferenceId) clientCacheSize=\(clientCacheSize) fetchTime=\(fetchTime)")

        let queryPredicate = #Predicate<AttestationStore.Workload> { entry in
            entry.type == workloadType && entry.inferenceId == inferenceId && entry.fetchTime >= fetchTime && entry.usedByTrustedRequestWithId == nil
        }

        do {
            let entries = try modelContext.fetch(FetchDescriptor(predicate: queryPredicate))
            let nodes = entries.flatMap(\.nodeUdids)
            if nodes.count >= clientCacheSize {
                return true
            }
        } catch {
            logger.error("failed to fetch entries from prefetch store: \(error)")
        }

        return false
    }

    // Why is this doing a fetch only to do a batch delete after?
    // suggestion, just do the batch delete, if you need metrics, do a fetchCount
    func deleteAttestationsUsedByTrustedRequest(
        serverRequestID: UUID
    ) -> UInt {
        logger.log("deleteAttestationsUsedForTrustedRequest: \(serverRequestID)")

        let queryPredicate = #Predicate<AttestationStore.Workload> { entry in
            entry.usedByTrustedRequestWithId == serverRequestID
        }

        var deletedBatch: UInt = 0
        do {
            let prefetchEntries = try modelContext.fetch(FetchDescriptor(predicate: queryPredicate))
            if let prefetchEntry = prefetchEntries.first {
                deletedBatch = prefetchEntry.batchId
                logger.log("deleting batch: \(deletedBatch) used by request: \(serverRequestID)")
                try modelContext.delete(model: AttestationStore.Workload.self, where: queryPredicate)
            }
        } catch {
            logger.error("failed to delete entries: \(error)")
        }

        return deletedBatch
    }

    func getAttestationBundlesUsedByTrustedRequest(
        serverRequestID: UUID
    ) -> [String: Data] {
        logger.log("getAttestationBundlesUsedByTrustedRequest: \(serverRequestID)")
        let queryPredicate = #Predicate<AttestationStore.Workload> { entry in
            entry.usedByTrustedRequestWithId == serverRequestID
        }

        var bundles: [String: Data] = [:]
        let today = Date()
        do {
            let prefetchEntries = try modelContext.fetch(FetchDescriptor(predicate: queryPredicate))
            if let prefetchEntry = prefetchEntries.first {
                let nodeUdids = prefetchEntry.nodeUdids
                let queryNodePredicate = #Predicate<AttestationStore.Node> { entry in
                    nodeUdids.contains(entry.udid) && entry.attestationExpiry >= today
                }
                do {
                    let nodes = try modelContext.fetch(FetchDescriptor(predicate: queryNodePredicate))
                    for node in nodes {
                        bundles[node.ropesNodeIdentifier] = node.attestationBundle
                    }
                } catch {
                    logger.error("failed to query attestations error: \(error)")
                }
            }
        } catch {
            logger.error("failed to delete entries: \(error)")
        }

        return bundles
    }
}

extension AttestationStore.Node.Kind {
    init(_ nodeKind: NodeKind) {
        self =
            switch nodeKind {
            case .direct: .direct
            case .proxy: .proxy
            }
    }
}
