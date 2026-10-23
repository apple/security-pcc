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
//  AttestationStore.swift
//  PrivateCloudCompute
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import PrivateCloudCompute
@_spi(Private) import SwiftData
import os

private let logger = Logger(for: .attestationStore)
private let signposter = OSSignposter(logger: logger)

// MARK: - Protocol

/// Protocol for the attestation store with reusable pool model.
protocol AttestationStoreProtocol: Sendable {
    /// Saves a validated attestation to the staging area.
    ///
    /// All attestations are first saved to the staging area with a prefetch ID.
    /// Use `finalizePendingPrefetch` to commit them to the main store.
    ///
    /// If the validated attestation already exists, this will create an entry to track
    /// the prefetch against the existing attestation.
    ///
    /// - Parameters:
    ///   - validatedAttestation: The attestation to save.
    ///   - parameters: The workload parameters.
    func stageValidatedAttestation(
        _ validatedAttestation: ValidatedAttestation,
        pendingPrefetchID: UUID
    ) async throws

    /// Finalizes a pending prefetch.
    ///
    /// This atomically:
    /// 1. Deletes old attestations for the workload
    /// 2. Moves staged attestations to the committed store
    /// 3. Links them to the workload
    ///
    /// - Parameters:
    ///   - parameters: The workload parameters.
    ///   - pendingPrefetchID: The prefetch identifier. Must corresponding to the identifier used in `stageValidatedAttestation`
    ///   - isPrewarm: Whether these attestations were obtained via an on-demand prewarm (true) or a background/scheduled prefetch (false).
    func finalizePendingPrefetch(
        for parameters: Workload,
        pendingPrefetchID: UUID,
        isPrewarm: Bool
    ) async throws

    /// Discards a pending prefetch batch.
    ///
    /// Deletes all staging entries with the matching prefetch ID.
    /// The existing committed pool remains unchanged.
    func discardPendingPrefetch(id: UUID) async throws

    /// Gets attestations for a request.
    ///
    /// Selects random attestations from the committed pool.
    ///
    /// - Parameters:
    ///   - parameters: The workload parameters.
    ///   - serverRequestID: The server request ID for tracking.
    ///   - maxAttestations: Maximum number of attestations to return.
    /// - Returns: Set of ValidatedAttestation (nodeIDs are unique by nature of Set).
    /// - Throws: `storeEmpty`, `storeBelowMinimum`, or `storeExpired`.
    func getAttestationsForRequest(
        parameters: Workload,
        serverRequestID: UUID,
        maxAttestations: Int
    ) async throws -> Set<ValidatedAttestation>

    /// Retrieves validated attestation for given node id if it exists.
    /// Note: the bundle is not included in this to save runtime memory where it is not needed.
    ///
    /// - Parameters:
    ///   - nodeId: The node id
    func validatedAttestation(for nodeID: String) async throws -> ValidatedAttestation?

    /// Checks if sufficient attestations exist for a workload.
    ///
    /// - Parameters:
    ///   - forParameters: The workload parameters.
    ///   - clientCacheSize: The required number of attestations.
    ///   - fetchTime: Only considers attestations fetched at or after this time.
    func attestationsExist(
        forParameters: Workload,
        clientCacheSize: Int,
        fetchTime: Date
    ) async -> Bool

    /// Deletes a specific node by ROPES identifier (nodeID).
    func deleteEntryForNode(nodeID: String) async -> Bool

    /// Deletes all expired attestations.
    func deleteEntriesWithExpiredAttestationBundles(now: Date) async throws

    /// Deletes all attestation store entries (full reset).
    func deleteAllAttestationStoreEntries() async throws

    /// Deletes attestations used by a trusted request and
    /// - Returns: the number of attestations deleted
    func deleteAttestationsUsedByTrustedRequest(serverRequestID: UUID) async -> UInt

    /// Gets the attestation bundles used by a trusted request.
    /// - Returns: Dictionary mapping nodeID to attestation bundle data.
    func getAttestationBundlesUsedByTrustedRequest(serverRequestID: UUID) async -> [String: Data]

    /// Returns all available nodes and their attestations for debugging/testing purposes.
    /// Only returns nodes that are in the committed pool (linked to workloads).
    /// - Returns: Set of ValidatedAttestation.
    func getAllAvailableNodes() async -> Set<ValidatedAttestation>
}

// MARK: - Implementation

extension AttestationStore {
    typealias AvailableNode = AttestationStore.SchemaV3.AvailableNode
    typealias NodeMetadata = AttestationStore.SchemaV3.NodeMetadata
    typealias NodeBundle = AttestationStore.SchemaV3.NodeBundle
    typealias PrefetchStaging = AttestationStore.SchemaV3.PrefetchStaging
    typealias WorkloadEntry = AttestationStore.SchemaV3.WorkloadEntry
    typealias WorkloadRequests = AttestationStore.SchemaV3.WorkloadRequests
}

@ModelActor
final actor AttestationStore: AttestationStoreProtocol, Sendable {

    /// How long a PrefetchStaging or WorkloadRequests entry must exist before
    /// it no longer blocks deletion of expired metadata. Entries older than this
    /// threshold are considered "stale" and will not block metadata deletion.
    private static let staleEntryThreshold: TimeInterval = 24 * 60 * 60  // 1 day

    private static let dbFilename = "db.sqlite"

    init(dir: URL) {
        let storesDir = Self.storesDir(rootDir: dir)

        let storeFileURL = storesDir.appendingPathComponent(Self.dbFilename, isDirectory: false)
        logger.log("attestation store v3 path: \(storeFileURL)")
        let configuration = ModelConfiguration(url: storeFileURL)

        let schema = Schema(versionedSchema: AttestationStore.SchemaV3.self)
        do {
            let container = try ModelContainer(for: schema, configurations: configuration)
            self.init(modelContainer: container)
        } catch {
            fatalError("failed to init attestation store v3, error=\(error)")
        }
    }

    private static func storesDir(rootDir: URL) -> URL {
        return rootDir.appendingPathComponent("attestationstore_v3", isDirectory: true)
    }

    // MARK: - Transaction

    /// Opaque token proving the caller is executing within a modelContext transaction.
    /// Only constructible via `ModelContext.withAttestationStoreTransaction(_:)`.
    struct Transaction {
        fileprivate init() {}
    }

    // MARK: - Fetch Helpers

    /// Returns NodeMetaData for given `nodeId`
    private func fetchMetadata(nodeID: String) throws -> NodeMetadata? {
        let predicate = #Predicate<NodeMetadata> { $0.nodeID == nodeID }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    /// Returns NodeBundle for given `nodeId`
    private func fetchBundle(nodeID: String) throws -> NodeBundle? {
        let predicate = #Predicate<NodeBundle> { $0.nodeID == nodeID }
        return try modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    /// Returns true if an AvailableNode with `nodeId` exists
    private func nodeExists(nodeID: String) throws -> Bool {
        let predicate = #Predicate<AvailableNode> { $0.nodeID == nodeID }
        return try modelContext.fetchCount(FetchDescriptor(predicate: predicate)) > 0
    }

    // MARK: - Query Helpers

    /// Returns true if the node has any WorkloadEntry references.
    private func hasWorkloadEntriesForNode(nodeID: String) throws -> Bool {
        let predicate = #Predicate<WorkloadEntry> { $0.nodeID == nodeID }
        return try modelContext.fetchCount(FetchDescriptor(predicate: predicate)) > 0
    }

    /// Returns true if the node has any PrefetchStaging references.
    private func hasStagingEntriesForNode(nodeID: String) throws -> Bool {
        let predicate = #Predicate<PrefetchStaging> { $0.nodeID == nodeID }
        return try modelContext.fetchCount(FetchDescriptor(predicate: predicate)) > 0
    }

    /// Returns true if the node has any WorkloadRequests references.
    private func hasRequestEntriesForNode(nodeID: String) throws -> Bool {
        let predicate = #Predicate<WorkloadRequests> { $0.nodeID == nodeID }
        return try modelContext.fetchCount(FetchDescriptor(predicate: predicate)) > 0
    }

    // MARK: - Delete Helpers

    /// Deletes all WorkloadEntry records for a node.
    private func deleteWorkloadEntriesForNode(nodeID: String, _ transaction: Transaction) throws {
        let predicate = #Predicate<WorkloadEntry> { $0.nodeID == nodeID }
        try modelContext.delete(model: WorkloadEntry.self, where: predicate)
    }

    /// Deletes all PrefetchStaging records for a node.
    private func deleteStagingEntriesForNode(nodeID: String, _ transaction: Transaction) throws {
        let predicate = #Predicate<PrefetchStaging> { $0.nodeID == nodeID }
        try modelContext.delete(model: PrefetchStaging.self, where: predicate)
    }

    /// Deletes all WorkloadRequests records for a node.
    private func deleteRequestEntriesForNode(nodeID: String, _ transaction: Transaction) throws {
        let predicate = #Predicate<WorkloadRequests> { $0.nodeID == nodeID }
        try modelContext.delete(model: WorkloadRequests.self, where: predicate)
    }

    /// Deletes the AvailableNode record for a node.
    /// Invariant: AvailableNode should only exist when linked to at least one WorkloadEntry.
    private func deleteNodeRecord(nodeID: String, _ transaction: Transaction) throws {
        let predicate = #Predicate<AvailableNode> { $0.nodeID == nodeID }
        try modelContext.delete(model: AvailableNode.self, where: predicate)
    }

    /// Deletes NodeMetadata and its NodeBundle for a node.
    /// Warning: Only call this after verifying no references exist, or when doing complete cleanup.
    private func deleteMetadataRecord(nodeID: String, _ transaction: Transaction) throws {
        // Always delete bundles before metadata to avoid materializing them in memory (rdar://176278017)
        try modelContext.delete(model: NodeBundle.self, where: #Predicate { $0.nodeID == nodeID })
        try modelContext.delete(model: NodeMetadata.self, where: #Predicate { $0.nodeID == nodeID })
    }

    /// Deletes all references and then the node and metadata for a nodeID.
    /// - Warning: This will delete staging entries and request tracking entries,
    ///   which may break in-flight prefetches or request diagnostics. Only use this
    ///   for complete cleanup of a node from the store (e.g., operator-requested deletion).
    private func deleteNodeCompletely(nodeID: String, _ transaction: Transaction) throws {
        // Log if deleting node with active references
        let hasStaging = try hasStagingEntriesForNode(nodeID: nodeID)
        let hasRequests = try hasRequestEntriesForNode(nodeID: nodeID)
        if hasStaging || hasRequests {
            logger.warning("deleteNodeCompletely: node=\(nodeID) has active references (staging=\(hasStaging) requests=\(hasRequests))")
        }

        try deleteWorkloadEntriesForNode(nodeID: nodeID, transaction)
        try deleteRequestEntriesForNode(nodeID: nodeID, transaction)
        try deleteStagingEntriesForNode(nodeID: nodeID, transaction)
        try deleteNodeRecord(nodeID: nodeID, transaction)
        try deleteMetadataRecord(nodeID: nodeID, transaction)
    }

    /// Cleans up orphaned entities that are no longer referenced.
    private func cleanupOrphanedNodes(_ transaction: Transaction) throws {
        try signposter.withIntervalSignpost(.cleanupUnreferencedNodes, id: signposter.makeSignpostID()) {
            let workloadEntries = try modelContext.fetch(FetchDescriptor<WorkloadEntry>())
            let availableNodes = try modelContext.fetch(FetchDescriptor<AvailableNode>())
            let staging = try modelContext.fetch(FetchDescriptor<PrefetchStaging>())
            let requests = try modelContext.fetch(FetchDescriptor<WorkloadRequests>())
            let metadata = try modelContext.fetch(FetchDescriptor<NodeMetadata>())

            let workloadNodeIDs = Set(workloadEntries.map(\.nodeID))
            let availableNodeIDs = Set(availableNodes.map(\.nodeID))
            let stagingNodeIDs = Set(staging.map(\.nodeID))
            let requestNodeIDs = Set(requests.map(\.nodeID))
            let metadataNodeIDs = Set(metadata.map(\.nodeID))

            // AvailableNode must only exist while linked to a WorkloadEntry.
            let orphanedNodeIDs = availableNodeIDs.subtracting(workloadNodeIDs)

            // NodeMetadata (and its NodeBundle) is orphaned when nothing references its nodeID.
            let referencedNodeIDs = workloadNodeIDs.union(stagingNodeIDs).union(requestNodeIDs)
            let orphanedMetadataNodeIDs = metadataNodeIDs.subtracting(referencedNodeIDs)

            try modelContext.delete(model: AvailableNode.self, where: #Predicate { orphanedNodeIDs.contains($0.nodeID) })

            try modelContext.delete(model: NodeBundle.self, where: #Predicate { orphanedMetadataNodeIDs.contains($0.nodeID) })
            try modelContext.delete(model: NodeMetadata.self, where: #Predicate { orphanedMetadataNodeIDs.contains($0.nodeID) })
        }
    }

    // MARK: - Save

    func stageValidatedAttestation(
        _ validatedAttestation: ValidatedAttestation,
        pendingPrefetchID: UUID
    ) throws {
        let signpostID = signposter.makeSignpostID()
        try signposter.withIntervalSignpost(.stageValidatedAttestation, id: signpostID) {
            let udid = validatedAttestation.udid

            guard let validatedCellID = validatedAttestation.validatedCellID else {
                logger.error("missing validatedAttestation.validatedCellID")
                throw AttestationStoreError(code: .invalidAttestation)
            }

            let hasBundle = validatedAttestation.attestation.attestationBundle != nil
            let hasExistingMetadata = try fetchMetadata(nodeID: validatedAttestation.attestation.nodeID) != nil
            guard hasBundle || hasExistingMetadata else {
                logger.error("missing validatedAttestation.attestation.attestationBundle for new attestation")
                throw AttestationStoreError(code: .invalidAttestation)
            }

            let nodeID = validatedAttestation.attestation.nodeID

            logger.log("stageValidatedAttestation: nodeID=\(nodeID) pendingPrefetchID=\(pendingPrefetchID)")

            // Even though there is a unique constraint in our scheme, an error is not automatically thrown
            // SwiftData executes an UPSERT instead of throwing an error in this case

            // Check for duplicate nodeID within this prefetch
            // We do this first because duplicate nodeId implies duplicate udid but not the inverse
            let duplicateNodePredicate = #Predicate<PrefetchStaging> {
                $0.prefetchID == pendingPrefetchID && $0.nodeID == nodeID
            }
            let duplicateNodeCount = try modelContext.fetchCount(FetchDescriptor(predicate: duplicateNodePredicate))
            if duplicateNodeCount > 0 {
                throw AttestationStoreError(code: .duplicateNodeIdInPrefetch)
            }

            // Check for duplicate UDID within this prefetch
            let duplicatePredicate = #Predicate<PrefetchStaging> {
                $0.prefetchID == pendingPrefetchID && $0.udid == udid
            }
            let duplicateCount = try modelContext.fetchCount(FetchDescriptor(predicate: duplicatePredicate))
            if duplicateCount > 0 {
                throw AttestationStoreError(code: .duplicateUdidInPrefetch)
            }

            try modelContext.withAttestationStoreTransaction { _ in
                if try fetchMetadata(nodeID: nodeID) == nil, let bundle = validatedAttestation.attestation.attestationBundle {
                    signposter.emitEvent("InsertNewNodeBundle", id: signpostID)
                    // Create NodeMetadata and NodeBundle
                    let newMetadata = NodeMetadata(
                        nodeID: nodeID,
                        udid: udid,
                        attestationExpiry: validatedAttestation.attestationExpiry,
                        publicKey: validatedAttestation.publicKey,
                        cloudOSVersion: validatedAttestation.attestation.cloudOSVersion,
                        cloudOSReleaseType: validatedAttestation.attestation.cloudOSReleaseType,
                        cellID: validatedCellID,
                        ensembleID: validatedAttestation.attestation.ensembleID
                    )
                    modelContext.insert(newMetadata)

                    let nodeBundle = NodeBundle(nodeID: nodeID, attestationBundle: bundle)
                    nodeBundle.metadata = newMetadata
                    modelContext.insert(nodeBundle)
                }

                // Create staging entry
                let staging = PrefetchStaging(
                    nodeID: nodeID,
                    prefetchID: pendingPrefetchID,
                    udid: udid
                )
                modelContext.insert(staging)
            }
        }
    }

    // MARK: - Two-Phase Commit

    func finalizePendingPrefetch(
        for parameters: PrivateCloudCompute.Workload,
        pendingPrefetchID: UUID,
        isPrewarm: Bool
    ) throws {
        try signposter.withIntervalSignpost(.finalizeAttestations, id: signposter.makeSignpostID()) {
            let (workloadType, workloadID) = parameters.prefetchAttributes
            logger.log("finalizePendingPrefetch: workload=\(workloadType)/\(workloadID) id=\(pendingPrefetchID)")

            let stagingPredicate = #Predicate<PrefetchStaging> { $0.prefetchID == pendingPrefetchID }
            let stagingCount = try modelContext.fetchCount(FetchDescriptor(predicate: stagingPredicate))
            guard stagingCount > 0 else {
                logger.warning("finalizePendingPrefetch: no staging entries found for id=\(pendingPrefetchID)")
                throw AttestationStoreError(code: .noStagingEntriesForPrefetch)
            }

            try modelContext.withAttestationStoreTransaction { tx in
                // Batch delete old workload entries for this workload
                let oldWorkloadPredicate = #Predicate<WorkloadEntry> {
                    $0.type == workloadType && $0.workloadID == workloadID
                }
                try modelContext.delete(model: WorkloadEntry.self, where: oldWorkloadPredicate)

                // Create AvailableNode and WorkloadEntry for each staging entry
                // NodeMetadata/NodeBundle were already created during save
                let stagingEntries = try modelContext.fetch(FetchDescriptor(predicate: stagingPredicate))

                for staging in stagingEntries {
                    let nodeID = staging.nodeID

                    // Create AvailableNode if it doesn't exist (node may be reused across workloads)
                    if try !nodeExists(nodeID: nodeID) {
                        let newNode = AvailableNode(nodeID: nodeID)
                        modelContext.insert(newNode)
                    }

                    let workload = WorkloadEntry(
                        type: workloadType,
                        workloadID: workloadID,
                        nodeID: nodeID,
                        isPrewarm: isPrewarm,
                        fetchTime: staging.fetchTime
                    )
                    modelContext.insert(workload)
                }

                // Batch delete staging entries
                try modelContext.delete(model: PrefetchStaging.self, where: stagingPredicate)

                // Cleanup orphaned nodes (nodes with no workload entries)
                try cleanupOrphanedNodes(tx)
            }

            modelContext.reset()
        }
    }

    func discardPendingPrefetch(id: UUID) throws {
        try signposter.withIntervalSignpost(.discardPendingAttestations, id: signposter.makeSignpostID()) {
            logger.log("discardPendingPrefetch: id=\(id)")

            try modelContext.withAttestationStoreTransaction { tx in
                let stagingPredicate = #Predicate<PrefetchStaging> { $0.prefetchID == id }
                try modelContext.delete(model: PrefetchStaging.self, where: stagingPredicate)
                try cleanupOrphanedNodes(tx)
            }

            modelContext.reset()
        }
    }

    // MARK: - Get Attestations

    func getAttestationsForRequest(
        parameters: PrivateCloudCompute.Workload,
        serverRequestID: UUID,
        maxAttestations: Int
    ) throws -> Set<ValidatedAttestation> {
        let (workloadType, workloadID) = parameters.prefetchAttributes
        return try signposter.withIntervalSignpost(
            .retrieveCachedAttestations,
            id: signposter.makeSignpostID()
        ) {
            let now = Date()

            logger.log("getAttestationsForRequest: workload=\(workloadType)/\(workloadID) serverRequestID=\(serverRequestID) max=\(maxAttestations)")

            // Find workload entries for this workload
            let workloadPredicate = #Predicate<WorkloadEntry> {
                $0.type == workloadType && $0.workloadID == workloadID
            }
            let workloadEntries = try modelContext.fetch(FetchDescriptor(predicate: workloadPredicate))

            guard !workloadEntries.isEmpty else {
                throw AttestationStoreError(code: .storeEmpty, workloadType: workloadType, workloadID: workloadID)
            }

            // Get unique nodeIDs and filter for unexpired nodes FIRST
            let nodeIDs = Set(workloadEntries.map { $0.nodeID })
            var unexpiredNodeIDs: [String] = []

            for nodeID in nodeIDs {
                let metadataPredicate = #Predicate<NodeMetadata> {
                    $0.nodeID == nodeID && $0.attestationExpiry >= now
                }
                if try modelContext.fetchCount(FetchDescriptor(predicate: metadataPredicate)) > 0 {
                    unexpiredNodeIDs.append(nodeID)
                }
            }

            // Check count after filtering expired
            guard !unexpiredNodeIDs.isEmpty else {
                throw AttestationStoreError(code: .storeExpired, workloadType: workloadType, workloadID: workloadID)
            }

            if unexpiredNodeIDs.count > maxAttestations {
                logger.log("workload=\(workloadType)/\(workloadID) found more than \(maxAttestations) nodes; dropping \(unexpiredNodeIDs.count - maxAttestations)")
            } else if unexpiredNodeIDs.count < maxAttestations {
                logger.log("workload=\(workloadType)/\(workloadID) found less than \(maxAttestations) nodes)")
            }

            // Shuffle and take max
            unexpiredNodeIDs.shuffle()
            let selectedNodeIDs = unexpiredNodeIDs.prefix(maxAttestations)

            // Fetch metadata for selected nodes and record usage
            let requestIDString = serverRequestID.uuidString

            let result: Set<ValidatedAttestation> = try modelContext.withAttestationStoreTransaction { _ in
                var result: Set<ValidatedAttestation> = []
                for nodeID in selectedNodeIDs {
                    guard let metadata = try fetchMetadata(nodeID: nodeID) else {
                        continue
                    }
                    let bundle = try fetchBundle(nodeID: metadata.nodeID)
                    if let attestation = ValidatedAttestation(metadata: metadata, bundle: bundle?.attestationBundle) {
                        result.insert(attestation)

                        // Record this node as used by the request (uses nodeID as foreign key)
                        let record = WorkloadRequests(requestID: requestIDString, nodeID: nodeID)
                        modelContext.insert(record)
                    }
                }
                return result
            }

            logger.log("getAttestationsForRequest: returning \(result.count) attestations")
            return result
        }
    }

    // MARK: - Queries

    func validatedAttestation(for nodeID: String) throws -> ValidatedAttestation? {
        guard let metadata = try fetchMetadata(nodeID: nodeID) else {
            return nil
        }

        return ValidatedAttestation(metadata: metadata)
    }

    func attestationsExist(
        forParameters parameters: PrivateCloudCompute.Workload,
        clientCacheSize: Int,
        fetchTime: Date
    ) -> Bool {
        return signposter.withIntervalSignpost(.checkAttestationsExist, id: signposter.makeSignpostID()) {
            let (workloadType, workloadID) = parameters.prefetchAttributes
            let now = Date()

            logger.log("attestationsExist: workload=\(workloadType)/\(workloadID) clientCacheSize=\(clientCacheSize) fetchTime=\(fetchTime)")

            // Find workload entries fetched before the specified time
            let workloadPredicate = #Predicate<WorkloadEntry> {
                $0.type == workloadType && $0.workloadID == workloadID && $0.fetchTime >= fetchTime
            }

            do {
                let workloadEntries = try modelContext.fetch(FetchDescriptor(predicate: workloadPredicate))
                let nodeIDs = Set(workloadEntries.map { $0.nodeID })

                // Count unexpired nodes
                var unexpiredCount = 0
                for nodeID in nodeIDs {
                    let metadataPredicate = #Predicate<NodeMetadata> {
                        $0.nodeID == nodeID && $0.attestationExpiry >= now
                    }
                    if try modelContext.fetchCount(FetchDescriptor(predicate: metadataPredicate)) > 0 {
                        unexpiredCount += 1
                    }
                }

                return unexpiredCount >= clientCacheSize
            } catch {
                logger.error("attestationsExist failed: \(error)")
                return false
            }
        }
    }

    // MARK: - Deletion

    func deleteEntryForNode(nodeID: String) async -> Bool {
        return signposter.withIntervalSignpost(.deleteNode, id: signposter.makeSignpostID()) {
            logger.log("deleteEntryForNode: \(nodeID)")

            do {
                try modelContext.withAttestationStoreTransaction { tx in
                    try deleteNodeCompletely(nodeID: nodeID, tx)
                }
                modelContext.reset()
                return true
            } catch {
                logger.error("deleteEntryForNode failed: \(error)")
                return false
            }
        }
    }

    /// Deletes expired attestations while preserving metadata that is still actively referenced.
    ///
    /// This method implements nuanced deletion behavior:
    /// 1. Always deletes: stale WorkloadRequests tracking rows (older than the stale threshold).
    /// 2. Always deletes: AvailableNode and WorkloadEntry associations for expired metadata.
    /// 3. Conditionally deletes: NodeMetadata and its NodeBundle, but only for expired nodes with
    ///    no recent PrefetchStaging or WorkloadRequests reference.
    ///
    /// The rationale for preserving metadata with recent references:
    /// - PrefetchStaging: A prefetch operation is in progress. Stale prefetch means a prefetch was never
    ///   finalized.
    /// - WorkloadRequests: A request is in-flight or recently completed. The metadata may
    ///   be needed for diagnostics, retries, or attestation bundle retrieval. In this case, stale means
    ///   it was never explicitly removed (possible crash).
    func deleteEntriesWithExpiredAttestationBundles(now: Date = .now) throws {
        try signposter.withIntervalSignpost(.deleteExpiredAttestations, id: signposter.makeSignpostID()) {
            logger.log("deleteEntriesWithExpiredAttestationBundles")

            let staleCutoff = now.addingTimeInterval(-Self.staleEntryThreshold)

            // rdar://177748000: prune the WorkloadRequests table to avoid pulling too many into memory in the fetch below
            try deleteStaleWorkloadRequests(now: now)

            let expiredMetadata = try modelContext.fetch(FetchDescriptor<NodeMetadata>(predicate: #Predicate { $0.attestationExpiry < now }))
            guard !expiredMetadata.isEmpty else { return }
            let recentStaging = try modelContext.fetch(FetchDescriptor<PrefetchStaging>(predicate: #Predicate { $0.fetchTime > staleCutoff }))
            let recentRequests = try modelContext.fetch(FetchDescriptor<WorkloadRequests>(predicate: #Predicate { $0.usedAt > staleCutoff }))

            let expiredNodeIDs = Set(expiredMetadata.map(\.nodeID))
            let recentStagingNodeIDs = Set(recentStaging.map(\.nodeID))
            let recentRequestNodeIDs = Set(recentRequests.map(\.nodeID))

            // Keep metadata + bundle for any expired node still backing a recent
            // prefetch or request for telemetry; the rest are deletable.
            let recentlyReferencedNodeIDs = recentStagingNodeIDs.union(recentRequestNodeIDs)
            let deletableNodeIDs = expiredNodeIDs.subtracting(recentlyReferencedNodeIDs)

            try modelContext.delete(model: WorkloadEntry.self, where: #Predicate { expiredNodeIDs.contains($0.nodeID) })
            try modelContext.delete(model: AvailableNode.self, where: #Predicate { expiredNodeIDs.contains($0.nodeID) })
            try modelContext.delete(model: NodeBundle.self, where: #Predicate { deletableNodeIDs.contains($0.nodeID) })
            try modelContext.delete(model: NodeMetadata.self, where: #Predicate { deletableNodeIDs.contains($0.nodeID) })

            try modelContext.save()
            modelContext.reset()
        }
    }

    private func deleteStaleWorkloadRequests(now: Date) throws {
        let cutoff = now.addingTimeInterval(-Self.staleEntryThreshold)
        try modelContext.delete(model: WorkloadRequests.self, where: #Predicate { $0.usedAt < cutoff })
        try modelContext.save()
        modelContext.reset()
    }

    func deleteAllAttestationStoreEntries() throws {
        try signposter.withIntervalSignpost(.deleteAllAttestations, id: signposter.makeSignpostID()) {
            logger.log("deleteAllAttestationStoreEntries")

            try modelContext.delete(model: WorkloadEntry.self)
            try modelContext.delete(model: WorkloadRequests.self)
            try modelContext.delete(model: PrefetchStaging.self)
            try modelContext.delete(model: AvailableNode.self)
            try modelContext.delete(model: NodeBundle.self)
            try modelContext.delete(model: NodeMetadata.self)

            try modelContext.save()
            modelContext.reset()
        }
    }

    // MARK: - Request Tracking

    func deleteAttestationsUsedByTrustedRequest(serverRequestID: UUID) -> UInt {
        // Note: this is different than the legacy signpost "DeleteUsedAttestationBatch". This measures the time to
        // delete the attestations corresponding to a request for the purposes of no longer keeping them around
        // since we have already consume them in telemetry.
        return signposter.withIntervalSignpost(.deleteUsedAttestations, id: signposter.makeSignpostID()) {
            let requestIDString = serverRequestID.uuidString
            logger.log("deleteAttestationsUsedByTrustedRequest: \(requestIDString)")

            let queryPredicate = #Predicate<WorkloadRequests> { $0.requestID == requestIDString }

            do {
                // Get count before batch-delete
                let count = try modelContext.fetchCount(FetchDescriptor(predicate: queryPredicate))

                try modelContext.withAttestationStoreTransaction { _ in
                    // Batch-delete the request entries
                    try modelContext.delete(model: WorkloadRequests.self, where: queryPredicate)
                }

                // Orphan cleanup is best-effort - don't fail the whole operation if it fails
                do {
                    try modelContext.withAttestationStoreTransaction { tx in
                        try cleanupOrphanedNodes(tx)
                    }
                } catch {
                    logger.warning("deleteAttestationsUsedByTrustedRequest: orphan cleanup failed (will retry later): \(error)")
                }

                modelContext.reset()

                logger.log("deleteAttestationsUsedByTrustedRequest: deleted \(count) records")
                return UInt(count)
            } catch {
                logger.error("deleteAttestationsUsedByTrustedRequest failed: \(error)")
                return 0
            }
        }
    }

    func getAttestationBundlesUsedByTrustedRequest(serverRequestID: UUID) -> [String: Data] {
        return signposter.withIntervalSignpost(.getAttestationsUsedByTrustedRequest, id: signposter.makeSignpostID()) {
            let requestIDString = serverRequestID.uuidString
            logger.log("getAttestationBundlesUsedByTrustedRequest: \(requestIDString)")

            let queryPredicate = #Predicate<WorkloadRequests> { $0.requestID == requestIDString }

            do {
                let requests = try modelContext.fetch(FetchDescriptor(predicate: queryPredicate))

                // Collect all bundles for the nodes used by this request
                var bundles: [String: Data] = [:]
                for request in requests {
                    let requestNodeID = request.nodeID
                    if let bundle = try fetchBundle(nodeID: requestNodeID) {
                        bundles[requestNodeID] = bundle.attestationBundle
                    } else {
                        logger.warning("getAttestationBundlesUsedByTrustedRequest: missing bundle for tracked node=\(requestNodeID)")
                    }
                }

                return bundles
            } catch {
                logger.error("getAttestationBundlesUsedByTrustedRequest failed: \(error)")
                return [:]
            }
        }
    }

    func getAllAvailableNodes() -> Set<ValidatedAttestation> {
        logger.log("getAllAvailableNodes")

        do {
            let allNodes = try modelContext.fetch(FetchDescriptor<AvailableNode>())
            var result: Set<ValidatedAttestation> = []

            for node in allNodes {
                if let metadata = try fetchMetadata(nodeID: node.nodeID),
                    let attestation = ValidatedAttestation(metadata: metadata)
                {
                    result.insert(attestation)
                }
            }

            return result
        } catch {
            logger.error("getAllAvailableNodes failed: \(error)")
            return []
        }
    }
}

// MARK: - ModelContext Transaction Helper

extension ModelContext {
    /// Executes `body` inside a SwiftData transaction, supplying an `AttestationStore.Transaction`
    /// token that can be forwarded to helpers requiring transaction context.
    ///
    /// Any `AttestationStoreError` thrown by `body` is re-thrown as-is. All other errors are
    /// wrapped in `AttestationStoreError(code: .persistenceError)`.
    fileprivate func withAttestationStoreTransaction<T>(
        _ body: (AttestationStore.Transaction) throws -> T
    ) throws -> T {
        // ModelContext.transaction(_:) is Void-returning, so capture the result via a local.
        // If body throws, modelContext.transaction propagates the throw (triggering rollback)
        // and we rethrow from the catch blocks — the guard branch is unreachable.
        var capturedResult: T?
        do {
            try transaction {
                capturedResult = try body(AttestationStore.Transaction())
            }
        } catch let error as AttestationStoreError {
            throw error  // already wrapped, pass through
        } catch {
            throw AttestationStoreError(code: .persistenceError, underlyingError: error)
        }
        guard let result = capturedResult else {
            // Unreachable: transaction either ran the block (setting capturedResult)
            // or threw (caught and rethrown above).
            throw AttestationStoreError(code: .persistenceError)
        }
        return result
    }
}

// MARK: - Error Types

/// Errors that can occur during AttestationStore operations.
package struct AttestationStoreError: Error {

    package enum Code: Int, Sendable {
        /// The store has no attestations for the requested workload.
        case storeEmpty = 1000
        /// All attestations in the store have expired.
        case storeExpired = 1002
        /// A duplicate UDID was detected within a single prefetch.
        case duplicateUdidInPrefetch = 2000
        /// A duplicate nodeID was detected within a single prefetch.
        case duplicateNodeIdInPrefetch = 2003
        /// The attestation is missing required fields.
        case invalidAttestation = 2001
        /// No staging entries found for the given prefetch ID.
        case noStagingEntriesForPrefetch = 2002
        /// A persistence error occurred.
        case persistenceError = 3000
    }

    /// The specific error code
    package let code: Code

    /// The original error that caused this error, if any
    package let underlyingError: (any Error)?

    /// Workload type associated with this error, if applicable
    package let workloadType: String?

    /// Inference ID associated with this error, if applicable
    package let workloadID: String?

    init(
        code: Code,
        underlyingError: (any Error)? = nil,
        workloadType: String? = nil,
        workloadID: String? = nil
    ) {
        self.code = code
        self.underlyingError = underlyingError
        self.workloadType = workloadType
        self.workloadID = workloadID
    }

    package var localizedDescription: String { "\(code)" }
}

extension AttestationStoreError: CustomNSError {
    package static var errorDomain: String {
        return "AttestationStoreError"
    }

    package var errorCode: Int {
        return code.rawValue
    }

    package static let workloadTypeKey = "workloadType"
    package static let workloadIDKey = "workloadID"

    package var errorUserInfo: [String: Any] {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: localizedDescription]
        if let underlyingError {
            userInfo[NSUnderlyingErrorKey] = underlyingError
        }
        if let workloadType {
            userInfo[Self.workloadTypeKey] = workloadType
        }
        if let workloadID {
            userInfo[Self.workloadIDKey] = workloadID
        }
        return userInfo
    }
}

extension AttestationStoreError: LocalizedError {
    private static let component = "Private Cloud Compute | All"
    package var failureReason: String? {
        switch code {
        case .storeEmpty:
            "The attestation store has no attestations for the requested workload."
        case .storeExpired:
            "All attestations in the store have expired."
        case .duplicateUdidInPrefetch:
            "A duplicate UDID was detected within a single prefetch."
        case .duplicateNodeIdInPrefetch:
            "A duplicate nodeID was detected within a single prefetch."
        case .invalidAttestation:
            "The attestation is missing required fields."
        case .noStagingEntriesForPrefetch:
            "No staging entries were found for the prefetch."
        case .persistenceError:
            "A database persistence error occurred."
        }
    }
}
