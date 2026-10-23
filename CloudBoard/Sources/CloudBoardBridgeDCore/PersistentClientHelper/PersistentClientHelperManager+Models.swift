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

import CloudBoardCommon
import Foundation
import PersistentServiceBridgeRouterAPI
import Synchronization

extension PersistentClientHelperManager {
    /// Represents the connection state as tracked by the manager.
    /// Uses `ConnectionStateMachine.State` for active connections, plus
    /// `connecting` and `disconnected` for the manager's own lifecycle tracking.
    enum NodeConnectionState: Sendable, CustomStringConvertible {
        case connecting
        case stream(ConnectionStateMachine.State)
        case disconnected

        var description: String {
            switch self {
            case .connecting: "connecting"
            case .stream(let state): "\(state)"
            case .disconnected: "disconnected"
            }
        }
    }

    /// Attestation data received from a compute node.
    struct AttestationInfo: Sendable, Equatable {
        let keyID: Data
        let bundle: Data
        /// Hard expiry communicated by the server in `SuggestedAttestation
        /// .expires_after`. When the protobuf field is absent, the decode
        /// boundary substitutes `Date.now + 24h` and logs a warning, so this
        /// field is always populated and the key-expiry watchdog is always
        /// armed.
        let hardExpiry: Date
    }

    /// Tracks all state for a single managed persistent service node.
    ///
    /// A node may be a member of *many* `(capability, shardID)` units
    /// simultaneously — `units` records that membership. The node has at
    /// most one underlying gRPC connection regardless of how many units it
    /// covers; promotion / demotion to that connection is driven by per-
    /// unit cap accounting against the `byUnit` index in `NodePools`.
    struct ManagedNode: Sendable {
        let nodeAddress: String
        let host: String
        let port: Int
        let serviceName: String
        /// The SD-provided instance this node was added from. Retained so
        /// the swap-on-early-failure path can demote the node into the
        /// spare pool with its original metadata intact for future
        /// re-promotion.
        let instance: InstanceInfo
        /// All units this node currently covers, derived from
        /// `unitIDs(for:serviceName:)`. Updated on SD refreshes when the
        /// instance's `capabilities` map changes.
        var units: Set<PersistentServiceUnitID>
        /// `true` while a connection task is actively driving this node
        /// (i.e. the node lives in some unit's `activeAddresses` set).
        /// `false` while the node is a spare — known/visible but no
        /// connection task running.
        var isActive: Bool
        var connectionState: NodeConnectionState
        var serviceDefinedMetadata: Data?
        /// Transport mode declared by the publisher in the SD
        /// announcement (`mtls` / `tls` / `plaintext`). Bridge picks
        /// exactly this transport for every connection attempt — no
        /// fallback. Refreshed on SD update like
        /// `serviceDefinedMetadata`. Defaults to `.mtls` when the
        /// publisher hasn't set the field.
        var transportSecurity: PersistentServiceTransportSecurity
        var connectionTask: Task<Void, Never>?
        /// The helper instance ID associated with this node's active connection.
        var helperID: UUID?
        /// The helper instance ID of a replacement stream being set up in parallel.
        /// Non-nil only while a replacement is in progress (2-stream limit).
        var replacementHelperID: UUID?
        /// Set by the retry filter when it decides to stop retrying so the
        /// connection task's terminal cleanup can perform the swap. The
        /// state stays under the `nodePools` lock so the decision can't be
        /// lost to a race with concurrent SD updates.
        var shouldSwapOnExit: Bool = false
        /// Number of consecutive failed `runNodeConnection` iterations on
        /// this node since it was last healthy or freshly added. Drives
        /// the N-failure swap-on-exit predicate. Reset to 0 when the
        /// stream reaches `setupComplete` and on `promote` of a fresh
        /// candidate.
        var consecutiveFailureCount: Int = 0
        /// Earliest absolute time at which this node may begin its next
        /// connection attempt. Set on `demote(...)` to
        /// `now + backoff(retryCount: consecutiveFailureCount)` so a
        /// just-demoted node respects its accumulated backoff if
        /// re-promoted, while a node that's been a spare longer than
        /// that window is immediately eligible. `nil` = no constraint
        /// (fresh-from-SD or healthy node — always ready).
        ///
        /// Doubles as the spare-promotion sort key: `pickFreshestSpare`
        /// returns the candidate whose `reconnectNotBefore` is soonest
        /// (`nil` first), so a recently-failed spare is naturally
        /// deprioritised even across multi-step swap chains.
        var reconnectNotBefore: ContinuousClock.Instant? = nil
    }

    /// Identifier for a *persistent-service unit* — a `(capability, shardID)`
    /// pair. Equality and hashing are over the two components, so the
    /// canonical string form never has to be parsed back apart by consumers
    /// (cb_bridged caps and ROPES quorum). `shardID` is the empty string for
    /// an unsharded capability.
    ///
    /// `description` is the canonical human-readable string form, used for
    /// logs: just the capability when unsharded, or `"capability|shardID"`
    /// when sharded. The `|` separator is intentionally outside the character
    /// set of valid capability names and of the trusted-filter shard form
    /// (`shard=…,count=…,modulus=…`). The type only ever *composes* this
    /// string for display — equality, hashing, lookup, ordering and metrics
    /// all use the stored fields directly — so there is deliberately no
    /// parse-from-string initializer.
    struct PersistentServiceUnitID: Hashable, Sendable, CustomStringConvertible {
        let capability: String
        let shardID: String

        var description: String {
            self.shardID.isEmpty ? self.capability : "\(self.capability)|\(self.shardID)"
        }
    }

    /// Per-unit index view onto `NodePools.nodes`. Holds only addresses;
    /// the `ManagedNode` itself lives once in the canonical store. The
    /// invariant is that `activeAddresses ∪ spareAddresses` are exactly
    /// the addresses of nodes whose `units` set contains this unit.
    struct PerUnitView: Sendable {
        let serviceName: String
        var activeAddresses: Set<String> = []
        var spareAddresses: Set<String> = []
    }

    /// Per-capability tracking of advertised shard configurations.
    ///
    /// An capability (e.g. a filterID) may have multiple distinct
    /// configurations advertised by different instances at the same time
    /// — usually one in steady state, two during a rolling reconfiguration
    /// (e.g. some instances still advertising `count=4`, others already on
    /// `count=8`). Each configuration is the full expected set of unit IDs
    /// the capability is split into. Coverage is decided per configuration:
    /// the capability is "covered" when at least one configuration has ≥1
    /// active address per unit.
    struct CapabilityCoverageTracking: Sendable, Equatable {
        let serviceName: String
        /// Set of distinct configurations advertised across instances.
        /// Empty until at least one instance has been seen.
        var configurations: Set<Set<PersistentServiceUnitID>> = []
    }

    /// Container for all the unit pools managed by this manager.
    /// `nodes` is the single source of truth for every `ManagedNode`;
    /// `byUnit` is an index keyed by `PersistentServiceUnitID` whose
    /// values reference addresses, never copies of the node;
    /// `byCapability` accumulates per-capability advertised shard configurations
    /// for coverage tracking. Wrapping the whole struct in a single
    /// `Mutex` keeps every cross-pool operation atomic (cap checks, swap,
    /// promote, multi-unit membership updates, coverage evaluation) with
    /// no inter-lock ordering to maintain.
    struct NodePools: Sendable {
        var nodes: [String: ManagedNode] = [:]
        var byUnit: [PersistentServiceUnitID: PerUnitView] = [:]
        var byCapability: [String: CapabilityCoverageTracking] = [:]
        /// Source of randomness for spare selection (`pickFreshestSpare`).
        /// Lives in the pool so it's covered by the same lock as the state it
        /// perturbs; defaults to system randomness and is injectable (seeded)
        /// from tests for reproducible fills.
        var rng: any RandomNumberGenerator & Sendable = SystemRandomNumberGenerator()

        /// `true` if `address` is currently in the active set of any unit.
        /// Used by the connection-task code paths that have an address in
        /// hand and need to know whether it's still reachable.
        func isActive(address: String) -> Bool {
            self.nodes[address]?.isActive ?? false
        }

        /// Service name registered for `address`, or empty string if the
        /// address is unknown. The empty-string fallback matches the
        /// metric-dimension sentinel used at the call sites — it is *not*
        /// an indication that the node is healthy or present.
        func serviceName(of address: String) -> String {
            self.nodes[address]?.serviceName ?? ""
        }

        /// All units the address is a member of (active or spare). Empty
        /// set if the address is unknown.
        func units(for address: String) -> Set<PersistentServiceUnitID> {
            self.nodes[address]?.units ?? []
        }

        /// Number of complete, independent replicas of `capability` currently
        /// served, summed across all advertised shard configurations.
        ///
        /// Each configuration contributes the *minimum* active-node count over
        /// its units: a sharded configuration needs one node per shard to form
        /// one full copy, so its weakest shard bounds how many complete copies
        /// it provides, and a configuration with any uncovered unit contributes
        /// 0. Per-configuration depths are summed, so two independent
        /// configurations each one replica deep report 2, and an unsharded
        /// capability served by N nodes reports N. "Active" here means a node
        /// promoted with a connection task running (present in some unit's
        /// `activeAddresses`) — not a proven-healthy stream, so the depth can
        /// exceed the number of streams actually established at that instant.
        /// Steady state is the served redundancy level; 0 means the capability
        /// is not being served.
        func capabilityReplicaDepth(_ capability: String) -> Int {
            guard let tracking = self.byCapability[capability] else { return 0 }
            var total = 0
            for config in tracking.configurations {
                guard !config.isEmpty else { continue }
                var configDepth = Int.max
                for unitID in config {
                    configDepth = min(configDepth, self.byUnit[unitID]?.activeAddresses.count ?? 0)
                }
                total += configDepth
            }
            return total
        }

        /// `true` if `capability` has at least one complete served replica.
        /// Convenience over `capabilityReplicaDepth`; preserved as the
        /// permissive coverage decision used in tests and assertions.
        func isCapabilityCovered(_ capability: String) -> Bool {
            self.capabilityReplicaDepth(capability) > 0
        }
    }

    /// A persistent-service instance discovered via Service Discovery
    /// that isn't currently elected into the active set because its
    /// unit's cap is full. Spares are promoted into the active pool when
    /// an active slot opens (SD removes a node, or a node fails before
    /// ever becoming healthy and the swap path picks one up).
    struct SpareEntry: Sendable {
        let instance: InstanceInfo
        let serviceName: String
    }
}
