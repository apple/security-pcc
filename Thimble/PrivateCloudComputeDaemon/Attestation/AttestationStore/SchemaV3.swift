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
//  SchemaV3.swift
//  PrivateCloudCompute
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
import SwiftData

extension AttestationStore {
    /// Schema V3: Reusable attestation pool with two-phase commit support.
    ///
    /// Tables:
    /// - `AvailableNode`: Lightweight reference to a committed attestation (just nodeID).
    /// - `NodeMetadata`: Attestation metadata including udid, keyed by nodeID.
    /// - `PrefetchStaging`: Tracking table for a single prefetch (nodeID, prefetchID, udid).
    /// - `WorkloadEntry`: Links nodes to workload pools (one row per node-workload pair).
    /// - `WorkloadRequests`: Tracks which nodes were used by each completed request.
    /// - `NodeBundle`: Contains the raw attestation bundle data (cascade deleted with NodeMetadata).
    ///
    enum SchemaV3: VersionedSchema {
        static var models: [any PersistentModel.Type] {
            [AvailableNode.self, NodeMetadata.self, PrefetchStaging.self, WorkloadEntry.self, WorkloadRequests.self, NodeBundle.self]
        }

        static var versionIdentifier: Schema.Version {
            Schema.Version(3, 0, 0)
        }

        // MARK: - AvailableNode

        /// A committed attestation node that is available for use.
        ///
        /// This is a lightweight table containing only the node identifier.
        /// Attestation data is stored separately in `NodeMetadata` (including udid)
        /// and the bundle is stored in `NodeBundle`.
        ///
        /// Key invariant: AvailableNode only exists when linked to at least one WorkloadEntry.
        ///
        /// All relationships are managed via `nodeID` foreign keys rather than SwiftData relationships
        /// to enable batch operations and avoid relationship staleness issues.
        @Model
        final class AvailableNode: Hashable, Identifiable {
            /// Unique identifier for this node, computed as a hash of the attestation data.
            @Attribute(.unique) var nodeID: String

            init(nodeID: String) {
                self.nodeID = nodeID
            }
        }

        // MARK: - NodeMetadata

        /// Attestation metadata for a node.
        ///
        /// Contains metadata needed to select and validate an attestation: expiry date,
        /// public key, udid, and server metadata. The attestation bundle itself is stored
        /// in `NodeBundle` which is cascade-deleted when this metadata is deleted.
        ///
        /// All lookups use `nodeID` as the foreign key. No SwiftData relationships are used
        /// except for the cascade delete to NodeBundle.
        @Model
        final class NodeMetadata: Hashable, Identifiable {
            #Index<NodeMetadata>([\.attestationExpiry])

            /// References `AvailableNode.nodeID`. Also serves as the primary key.
            @Attribute(.unique) var nodeID: String

            /// Hardware identifier for the node. Stable across attestation refreshes.
            var udid: String

            /// When this attestation expires and can no longer be used.
            var attestationExpiry: Date

            /// Public key for encrypted communication with the node.
            var publicKey: Data

            /// CloudOS version running on the node.
            var cloudOSVersion: String

            /// CloudOS release type (e.g., "Customer", "Internal").
            var cloudOSReleaseType: String

            /// Cell identifier for the node's datacenter location.
            var cellID: String

            /// Optional ensemble identifier for grouped nodes.
            var ensembleID: String?

            /// The attestation bundle. Cascade-deleted when this metadata is deleted.
            @Relationship(deleteRule: .cascade, inverse: \NodeBundle.metadata)
            var bundle: NodeBundle?

            init(
                nodeID: String,
                udid: String,
                attestationExpiry: Date,
                publicKey: Data,
                cloudOSVersion: String,
                cloudOSReleaseType: String,
                cellID: String,
                ensembleID: String?
            ) {
                self.nodeID = nodeID
                self.udid = udid
                self.attestationExpiry = attestationExpiry
                self.publicKey = publicKey
                self.cloudOSVersion = cloudOSVersion
                self.cloudOSReleaseType = cloudOSReleaseType
                self.cellID = cellID
                self.ensembleID = ensembleID
            }
        }

        // MARK: - PrefetchStaging

        /// Staging table for prefetch requests.
        ///
        /// Enables two-phase commit for atomic pool replacement:
        /// 1. During save: NodeMetadata/NodeBundle are created, PrefetchStaging tracks nodeID.
        /// 2. On success (finalize): Create AvailableNode and WorkloadEntry, delete staging entries.
        /// 3. On failure (discard): Delete staging entries and cleanup orphaned metadata.
        ///
        /// Key invariant: AvailableNode only exists when linked to at least one WorkloadEntry.
        /// This ensures the existing pool remains usable until the new pool is fully validated.
        ///
        /// UDID deduplication: The unique constraint on (prefetchID, udid) ensures that
        /// the same hardware cannot appear twice in a single prefetch response.
        ///
        /// Node deduplication: The unique constraint on (prefetchID, nodeID) ensures that
        /// the same node cannot appear twice in a single prefetch response.
        ///
        /// Uses `nodeID` as a foreign key to NodeMetadata rather than a SwiftData relationship.
        @Model
        final class PrefetchStaging: Hashable, Identifiable {
            #Unique<PrefetchStaging>([\.prefetchID, \.udid], [\.prefetchID, \.nodeID])
            #Index<PrefetchStaging>([\.prefetchID])

            /// References `NodeMetadata.nodeID`.
            var nodeID: String

            /// Identifies which prefetch this entry belongs to.
            /// Attestations from a single prefetch are grouped via this field.
            /// All entries with the same `prefetchID` are committed or discarded together.
            var prefetchID: UUID

            /// Hardware identifier for the node. Used for UDID deduplication within a prefetch.
            var udid: String

            /// When this attestation was fetched from the server. In case a prefetch is not completed in its
            /// entirety, this time can be used to discard stale nodes from this table.
            var fetchTime: Date

            init(
                nodeID: String,
                prefetchID: UUID,
                udid: String,
                fetchTime: Date = Date()
            ) {
                self.nodeID = nodeID
                self.prefetchID = prefetchID
                self.udid = udid
                self.fetchTime = fetchTime
            }
        }

        // MARK: - WorkloadEntry

        /// Links a node to a workload pool.
        ///
        /// Each row represents one node's membership in a specific workload pool,
        /// identified by (type, workloadID). A node can belong to multiple workloads.
        ///
        /// Uses `nodeID` as a foreign key to `AvailableNode` rather than a SwiftData
        /// relationship to enable batch operations.
        @Model
        final class WorkloadEntry: Hashable, Identifiable {
            #Unique<WorkloadEntry>([\.type, \.workloadID, \.nodeID])
            #Index<WorkloadEntry>([\.type, \.workloadID])

            /// Workload type identifier.
            var type: String

            /// Inference model identifier for this workload.
            var workloadID: String

            /// Foreign key referencing `AvailableNode.nodeID`.
            var nodeID: String

            /// True if obtained via background prefetch, false if via on-demand prewarm.
            var isPrewarm: Bool

            /// When this attestation was fetched from the server.
            var fetchTime: Date

            init(
                type: String,
                workloadID: String,
                nodeID: String,
                isPrewarm: Bool,
                fetchTime: Date
            ) {
                self.type = type
                self.workloadID = workloadID
                self.nodeID = nodeID
                self.isPrewarm = isPrewarm
                self.fetchTime = fetchTime
            }
        }

        // MARK: - WorkloadRequests

        /// Tracks which nodes were used by each completed request.
        ///
        /// Used for metrics: after a request completes, this table
        /// records which attestations were actually used, enabling auditing
        /// and diagnostics without keeping the data in memory.
        ///
        /// A single request can use multiple nodes, so we track each (requestID, nodeID) pair.
        ///
        /// Uses `nodeID` as a foreign key to NodeMetadata rather than a SwiftData relationship.
        @Model
        final class WorkloadRequests: Hashable, Identifiable {
            #Unique<WorkloadRequests>([\.requestID, \.nodeID])
            #Index<WorkloadRequests>([\.requestID])

            /// Identifier for the request that used this node.
            var requestID: String

            /// References `NodeMetadata.nodeID` for the node that was used.
            var nodeID: String

            /// When this request used the node. Used to determine if an expired metadata
            /// should be preserved because a recent request is still in progress.
            var usedAt: Date

            init(requestID: String, nodeID: String, usedAt: Date = Date()) {
                self.requestID = requestID
                self.nodeID = nodeID
                self.usedAt = usedAt
            }
        }

        // MARK: - NodeBundle

        /// Stores the attestation bundle separately from other metadata.
        /// Cascade-deleted when the associated NodeMetadata is deleted.
        @Model
        final class NodeBundle: Hashable, Identifiable {
            /// References `AvailableNode.nodeID`. Also serves as the primary key.
            @Attribute(.unique) var nodeID: String

            /// The raw attestation bundle from the server.
            var attestationBundle: Data

            /// Inverse relationship to NodeMetadata. This bundle is cascade-deleted with metadata.
            var metadata: NodeMetadata?

            init(nodeID: String, attestationBundle: Data) {
                self.nodeID = nodeID
                self.attestationBundle = attestationBundle
            }
        }
    }
}
