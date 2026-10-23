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
import CryptoKit
internal import CloudBoardDomain
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CloudBoardMetrics
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import InternalSwiftProtobuf
import Logging
import Network
import NIOCore
import NIOTransportServices
import os
import PersistentHelperInstance
import PersistentServiceBridgeRouterAPI
import Synchronization

typealias InstanceInfo = Com_Apple_Ase_Traffic_Servicediscovery_Api_V2_InstanceInfo
private typealias PersistentServiceRequest = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest
typealias PersistentServiceResponse = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceResponse

/// Manages the lifecycle of persistent gRPC connections to persistent services discovered via ServiceDiscovery.
///
/// When ServiceDiscovery reports nodes hosting persistent services (e.g. "trusted-filter"),
/// this manager:
/// 1. Opens a gRPC `InvokePersistentService` stream to each discovered node
/// 2. Receives attestation bundles from the server
/// 3. Spawns a `cb_pclienthelper` process and initializes it with the attestation bundle
/// 4. Exchanges the OHTTP encrypted key, sends Setup on gRPC, waits for SetupAck
/// 5. Bridges encrypted traffic between the helper and gRPC stream
final class PersistentClientHelperManager: Sendable {
    /// Updates a managed node inside `nodePools.nodes`, throwing
    /// `nodeNotFound` if the node was concurrently removed (or demoted to
    /// spares — by definition spares have no in-flight stream to update).
    private func updateActiveNode(
        address: String,
        connectionID: String,
        _ body: (inout ManagedNode) -> Void
    ) throws {
        try self.nodePools.withLock { pools in
            guard var node = pools.nodes[address], node.isActive else {
                Self.logger.error(
                    "Node already removed for \(connectionID, privacy: .public) at \(address, privacy: .public)"
                )
                throw ConnectionError.nodeNotFound(connectionID: connectionID)
            }
            body(&node)
            pools.nodes[address] = node
        }
    }

    static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentClientHelperManager"
    )

    /// Awaits the first element on `signal` or `timeout`, whichever comes first.
    /// Returns `true` if the signal arrived, `false` on timeout. The signal
    /// stream's first yielded element OR completion of the stream both count
    /// as "signalled" — a finished stream means the producer is gone (helper
    /// teardown, or a replacement that failed before reaching ready), so we
    /// stop waiting rather than sit out the timeout.
    /// Internal (not private) so unit tests can exercise the three outcomes.
    static func awaitSignalOrTimeout(
        signal: AsyncStream<Void>,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in signal {
                    return true
                }
                // Stream finished without yielding — treat as signal (helper
                // is being torn down for some other reason; we shouldn't wait
                // out the timeout).
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            // First task to return wins.
            let result = await group.next() ?? false
            group.cancelAll()
            // Drain any remaining tasks so the group exits cleanly, independent of the
            // number of racers.
            for await _ in group {}
            return result
        }
    }

    /// Outcome of waiting for a stream's in-flight queries to drain before retiring it.
    enum DrainWaitOutcome: Sendable, Equatable {
        /// Drain-complete arrived (or its signal stream ended): send a clean Terminate.
        case drained
        /// The bounded wait elapsed: force a Terminate to reclaim the slot.
        case timedOut
        /// Retirement was pre-empted (server-initiated critical drain): skip the Terminate.
        case aborted
    }

    /// Races drain-complete against an abort against a timeout. `aborted` wins if the abort
    /// signal fires/finishes (used to short-circuit an in-flight retirement on critical drain);
    /// `drained` if the drain-complete signal fires or its stream ends; `timedOut` otherwise.
    /// Internal (not private) so unit tests can exercise the three outcomes.
    static func awaitDrainOutcome(
        drainComplete: AsyncStream<Void>,
        abort: AsyncStream<Void>,
        timeout: Duration
    ) async -> DrainWaitOutcome {
        await withTaskGroup(of: DrainWaitOutcome.self) { group in
            group.addTask {
                for await _ in drainComplete {
                    return .drained
                }
                // Stream finished without yielding — the drain producer is gone; proceed.
                return .drained
            }
            group.addTask {
                for await _ in abort {
                    return .aborted
                }
                // Stream finished without yielding — treat as an abort request.
                return .aborted
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let outcome = await group.next() ?? .timedOut
            group.cancelAll()
            // Drain any remaining tasks so the group exits cleanly, independent of the
            // number of racers.
            for await _ in group {}
            return outcome
        }
    }

    /// Runs `operation` with a hard upper bound. On timeout cancels the
    /// operation task and throws
    /// `ConnectionError.establishmentTimeout(host:port:after:)`. Distinct
    /// from gRPC-Swift's own `connectionPool.maxWaitTime` because that
    /// knob has been observed not to bound real-world failures
    /// (closed-on-accept listeners, HTTP/2 mid-handshake RST). The
    /// thrown error is retryable; the retry filter then drives the swap-
    /// on-early-failure path if a spare is available in any covered unit.
    ///
    /// `closeOnLoss` is invoked when the timer wins the race **but** the
    /// operation task had already produced a value before cancellation
    /// propagated. Without it the salvaged value (typically a live
    /// `GRPCChannel` + bidi call) would be silently dropped — the
    /// channel is never closed, and we leak the connection pool plus
    /// any in-flight stream. The closer runs only on the lost-race
    /// branch; on the normal timeout path (operation cancelled before
    /// it produced a value) the drain returns `nil` and `closeOnLoss`
    /// does not fire.
    private static func withEstablishmentTimeout<T: Sendable>(
        _ timeout: Duration,
        host: String,
        port: Int,
        operation: @Sendable @escaping () async throws -> T,
        closeOnLoss: @Sendable @escaping (T) async -> Void
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ConnectionError.establishmentTimeout(
                    host: host, port: port, after: timeout
                )
            }
            // Capture the first child's outcome, then explicitly cancel
            // and drain the loser before returning. Without the drain
            // the throwing task group's implicit await on scope exit
            // would observe the cancelled timer's `CancellationError`
            // (`Task.sleep(for:)` throws on cancel) and could propagate
            // it — masking a successful operation result with a spurious
            // `CancellationError` at the caller.
            let outcome: Result<T, Error>
            do {
                guard let first = try await group.next() else {
                    throw ConnectionError.establishmentTimeout(
                        host: host, port: port, after: timeout
                    )
                }
                outcome = .success(first)
            } catch {
                outcome = .failure(error)
            }
            group.cancelAll()
            // Drain the loser. On the timer-wins branch the operation
            // may have completed past cancellation and produced a real
            // value; if so, close it so the channel/stream isn't leaked.
            // On the operation-wins branch the only loser is the timer
            // task, which throws on cancel and is swallowed by `try?`.
            if let salvaged = try? await group.next(),
               case .failure = outcome {
                await closeOnLoss(salvaged)
            }
            return try outcome.get()
        }
    }

    /// Owns the channel-construction config (TLS plumbing, event-loop
    /// group, HTTP/2 keepalive). Built once in `init` from the parameters
    /// supplied by the daemon; produces gRPC channels on demand from
    /// `runStream`.
    private let channelPoolBuilder: PersistentChannelPoolBuilder
    private let connectionBackoffStrategy: ExponentialBackoffStrategy
    private let keepaliveInterval: Duration
    private let idleTimeout: Duration
    /// Bound on how long the bridge waits for the router's drain-complete
    /// signal after a helper enters `.draining`. On expiry the bridge force-
    /// Terminates the gRPC stream and the retry loop reconnects with fresh
    /// keys. Without this bound a router-side drain-complete regression pins
    /// the stream slot indefinitely.
    private let drainCompleteWaitTimeout: Duration
    /// Bound on how long a rotating connection keeps its old stream `.ready` and
    /// serving while the replacement establishes and reaches `sendHelperReady`.
    /// On expiry the old stream is drained anyway to honour the server's recreate
    /// request. Separate from `drainCompleteWaitTimeout` (which bounds the
    /// subsequent in-flight drain) so the make-before-break overlap is tunable on
    /// its own and the two waits don't compound into a single conflated knob.
    private let replacementReadyWaitTimeout: Duration
    /// Grace period added to the server-supplied attestation `hardExpiry`
    /// before the bridge force-tears the stream down. Covers small clock skew
    /// between bridge and server while still bounding the slot recovery time.
    private let keyExpiryGracePeriod: Duration
    let metricsSystem: MetricsSystem
    private let helperInstanceProvider: any PersistentHelperInstanceProviderProtocol

    /// Control channel for pushing helper lifecycle events to the router.
    private let bridgeRouterClient: any PersistentServiceBridgeRouterClientProtocol

    /// The isolation domain this client belongs to. Only nodes publishing
    /// the same isolation domain are visible; all others are filtered out.
    let isolationDomain: String

    /// The cell ID this daemon belongs to. Only nodes in the same cell are visible.
    /// When nil, cell filtering is disabled.
    private let cellID: String?

    /// The IP address of the current node. Instances matching this IP are filtered out
    /// to prevent connecting to self. When nil, self-filtering is disabled.
    private let localNodeIP: String?

    /// Per-service snapshot of the discovered-instances-per-unit counts,
    /// produced by `planInstanceUpdate` (so it reflects exactly the admitted,
    /// address-deduped set the pool reconciled against) and re-emitted on a
    /// timer by `runEmitDiscoveredInstancesMetricsLoop`. Keyed by service name
    /// so each service's update replaces only its own slice.
    ///
    /// A slice is only ever overwritten by a later `handleInstancesChanged`
    /// for the same service; it is never pruned. That cannot strand a stale
    /// non-zero series, because the set of persistent-service names is fixed
    /// at launch and cannot change without restarting the daemon: every
    /// configured service keeps receiving SD updates for the process's whole
    /// lifetime, so a service emptying out arrives as an empty instance list
    /// and its units zero out via the vanished-key pass below — a service
    /// never silently disappears from this map while the process runs.
    let discoveredUnitCounts: Mutex<[String: [PersistentServiceUnitID: Int]]> = Mutex([:])

    /// The dimension keys emitted on the previous discovered-instances timer
    /// tick, so a unit that drops out of ServiceDiscovery is re-emitted as `0`
    /// instead of keeping its last non-zero value forever.
    let lastEmittedDiscoveredKeys: Mutex<Set<DiscoveredUnitKey>> = Mutex([])

    /// The unit and capability keys emitted on the previous `emitPerUnitGauges`
    /// pass, so a unit or capability that drops out of the pools is re-emitted
    /// as `0` rather than keeping its last non-zero value forever. Guarded by
    /// its own Mutex because `handleInstancesChanged` (and thus
    /// `emitPerUnitGauges`) can run concurrently for different services.
    private struct EmittedPerUnitKeys: Sendable {
        var units: Set<PersistentServiceUnitID> = []
        var capabilities: Set<String> = []
    }

    private let lastEmittedPerUnitKeys: Mutex<EmittedPerUnitKeys> = Mutex(EmittedPerUnitKeys())

    /// Active and spare pools partitioned by unit. Held in a single Mutex
    /// so cap checks, swaps, and multi-unit membership updates are atomic
    /// with no inter-lock ordering to maintain.
    private let nodePools: Mutex<NodePools> = Mutex(NodePools())

    /// Per-unit cap on the active pool, keyed by service name. The cap
    /// applies independently to each `PersistentServiceUnitID` derived
    /// from a service via `unitIDs(for:serviceName:)`. Missing entries
    /// (or a nil map) leave the corresponding units uncapped, matching
    /// the historical behaviour.
    ///
    /// The cap is **soft**: one connection counts toward every unit its node
    /// covers, so a unit's cap is intentionally exceeded when that is the only
    /// way to bring a colocated (overlapping) unit up to its own cap — see
    /// `promoteIfNeeded`, which promotes a spare whenever *any* covered unit is
    /// below cap and refuses only a promotion no unit needs. The active set is
    /// held at the caps by reconciliation as connections drain/fail and spares
    /// backfill, not by a synchronous hard limit.
    private let maxServersPerUnit: [String: Int]?

    /// Number of consecutive failures on a single node before the swap-
    /// on-exit path moves to a spare. Keyed by service name; missing
    /// entries fall back to `defaultSwapOnFailureThreshold` (2). The
    /// threshold only applies when the service has a `maxServersPerUnit`
    /// cap configured — uncapped services never swap.
    private let swapOnFailureThreshold: [String: Int]
    private static let defaultSwapOnFailureThreshold: Int = 2

    /// Capability IDs (as advertised in `meta["persistent-service"].capabilities`)
    /// that are discarded during SD capability parsing, so the router never
    /// establishes quorum for or routes to them.
    private let blockedCapabilities: Set<String>

    /// Hard upper bound on a single connection-establishment attempt.
    /// Wraps `establishConnection` with structured-concurrency
    /// cancellation since gRPC-Swift's own `connectionPool.maxWaitTime`
    /// has been observed not to bound real-world failures (closed-on-
    /// accept listeners, HTTP/2 mid-handshake RST). Does **not** bound
    /// time spent after `setupComplete` — long-lived keepalive/idle
    /// timers take over from there.
    private let connectionEstablishmentTimeout: Duration

    /// When true, the announcement parser refuses to admit any node
    /// whose `transportSecurity` declaration is not `mtls`. Mirrors
    /// `SecureConfig.shouldEnforceAppleInfrastructureSecurityConfig`:
    /// production policy fails closed; test/research/carry environments
    /// honour what the announcement says (plaintext or tls). Plumbed
    /// from `CloudBoardBridgeDaemon` at startup.
    let requireMTLS: Bool

    init(
        eventLoopGroup: NIOTSEventLoopGroup,
        identityCallback: GRPCTLSConfiguration.IdentityCallback?,
        tlsConfig: GRPCClientConfiguration.TLSConfiguration?,
        serverVerification: GRPCTLSConfiguration.ServerVerification?,
        isolationDomain: String,
        cellID: String?,
        localNodeIP: String?,
        connectionBackoffStrategy: ExponentialBackoffStrategy,
        keepaliveInterval: Duration,
        idleTimeout: Duration,
        // Queries should be sub second, vastly faster than this
        drainCompleteWaitTimeout: Duration = .seconds(60),
        // How long the old stream keeps serving while a replacement establishes.
        replacementReadyWaitTimeout: Duration = .seconds(60),
        // Generous window for clock skew
        keyExpiryGracePeriod: Duration = .seconds(60),
        // Hard cap on a single establishment attempt; default sits just
        // above gRPC's own 10 s `maxWaitTime` so the wrapper rarely fires
        // when the underlying knob actually bounds the failure.
        connectionEstablishmentTimeout: Duration = .seconds(15),
        // HTTP/2 keepalive (NIO PING/PONG). Defaults bound a black-holed
        // TCP within ~20 s. `timeout` must be strictly less than
        // `interval` per `ClientConnectionKeepalive`'s precondition.
        http2KeepalivePingInterval: Duration = .seconds(15),
        http2KeepalivePongTimeout: Duration = .seconds(5),
        metricsSystem: MetricsSystem,
        helperInstanceProvider: any PersistentHelperInstanceProviderProtocol,
        bridgeRouterClient: any PersistentServiceBridgeRouterClientProtocol,
        // No default: this is the policy gate that decides whether a
        // node announcing non-mTLS transport is admitted at all.
        // Defaulting to `false` would silently degrade security if a
        // future call site forgot to wire the SecureConfig flag.
        requireMTLS: Bool,
        maxServersPerUnit: [String: Int]? = nil,
        swapOnFailureThreshold: [String: Int] = [:],
        blockedCapabilities: Set<String> = [],
        // Injectable for deterministic spare selection in tests; production
        // uses system randomness.
        randomNumberGenerator: any RandomNumberGenerator & Sendable = SystemRandomNumberGenerator()
    ) {
        self.channelPoolBuilder = PersistentChannelPoolBuilder(
            eventLoopGroup: eventLoopGroup,
            identityCallback: identityCallback,
            tlsConfig: tlsConfig,
            serverVerification: serverVerification,
            http2KeepalivePingInterval: TimeAmount(http2KeepalivePingInterval),
            http2KeepalivePongTimeout: TimeAmount(http2KeepalivePongTimeout)
        )
        self.isolationDomain = isolationDomain
        self.cellID = cellID
        self.localNodeIP = localNodeIP
        self.connectionBackoffStrategy = connectionBackoffStrategy
        self.keepaliveInterval = keepaliveInterval
        self.idleTimeout = idleTimeout
        self.drainCompleteWaitTimeout = drainCompleteWaitTimeout
        self.replacementReadyWaitTimeout = replacementReadyWaitTimeout
        self.keyExpiryGracePeriod = keyExpiryGracePeriod
        self.connectionEstablishmentTimeout = connectionEstablishmentTimeout
        self.metricsSystem = metricsSystem
        self.helperInstanceProvider = helperInstanceProvider
        self.bridgeRouterClient = bridgeRouterClient
        self.requireMTLS = requireMTLS
        self.maxServersPerUnit = maxServersPerUnit
        self.swapOnFailureThreshold = swapOnFailureThreshold
        self.blockedCapabilities = blockedCapabilities
        self.nodePools.withLock { $0.rng = randomNumberGenerator }
        if !blockedCapabilities.isEmpty {
            Self.logger.info(
                "Persistent-service capability block-list active; discarding advertised capabilities: \(blockedCapabilities.sorted().joined(separator: ", "), privacy: .public)"
            )
        }
    }

    // MARK: - Instance update handling

    /// Called when ServiceDiscovery provides an updated instance list for a service.
    ///
    /// Filters instances to only those matching this client's isolation domain,
    /// then runs greedy per-unit reconciliation against the current pools.
    /// Caps and spare promotions are applied atomically inside the lock; the
    /// plan returned by `planInstanceUpdate` says which addresses need their
    /// helpers torn down (now invisible) and which addresses need a fresh
    /// connection task spawned (newly visible, or a spare that was just
    /// promoted to fill a deficit).
    func handleInstancesChanged(
        serviceName: String,
        instances: [InstanceInfo]
    ) async {
        Self.logger
            .debug("Received updated instances for \(serviceName, privacy: .public): \(instances, privacy: .public)")
        // Filter to instances in our isolation domain
        let afterIsolation = instances.filter { instance in
            Self.parseIsolationDomain(from: instance) == self.isolationDomain
        }
        // Filter by cell ID if configured
        let afterCell = afterIsolation.filter { instance in
            guard let requiredCellID = self.cellID else { return true }
            return Self.parseCellID(from: instance) == requiredCellID
        }
        // Filter out the current node to prevent connecting to self
        let visibleInstances = afterCell.filter { instance in
            guard let localIP = self.localNodeIP else { return true }
            if instance.address.ip == localIP {
                Self.logger.info(
                    "Filtering out self-node instance \(instance.address.ip, privacy: .public):\(instance.address.port, privacy: .public)"
                )
                return false
            }
            return true
        }

        // Surface filter outcomes so a single grep distinguishes "no instances published"
        // from "instances published but filtered out by isolationDomain/cellID/self-IP".
        // A drop to zero at any stage explains a node that "received SD updates but
        // launched no helpers".
        Self.logger.info(
            "handleInstancesChanged for \(serviceName, privacy: .public): received=\(instances.count, privacy: .public) afterIsolation=\(afterIsolation.count, privacy: .public) afterCell=\(afterCell.count, privacy: .public) afterSelf=\(visibleInstances.count, privacy: .public) (isolationDomain=\(self.isolationDomain, privacy: .public) cellID=\(self.cellID ?? "nil", privacy: .public))"
        )

        let plan = self.planInstanceUpdate(
            visibleInstances: visibleInstances,
            serviceName: serviceName
        )

        // The discovered-instances gauge counts the same admitted,
        // address-deduped set the pool reconciled against (computed under the
        // lock inside `planInstanceUpdate`), so the timer-driven gauge can
        // re-emit a cached snapshot without re-filtering and cannot diverge
        // from this reconciliation path. The serviceID/isolationDomain labels
        // are stamped on at emit time (serviceID is this slice's key,
        // isolationDomain is fixed for the manager), so they aren't stored.
        self.discoveredUnitCounts.withLock {
            $0[serviceName] = plan.discoveredCountsByUnit
        }

        // Tear down nodes that are no longer in the SD response. The
        // ManagedNode struct carrying their connectionTask + helperIDs has
        // already been removed from `nodePools.nodes` under the lock; this
        // path performs the off-lock helper teardown.
        for (address, removedNode) in plan.fullyRemoved {
            await self.tearDownRemovedNode(
                address: address,
                node: removedNode,
                serviceName: serviceName
            )
        }

        // Spawn connection tasks for nodes that became active in this
        // reconciliation pass — newly-visible or promoted from spares.
        for address in plan.toStartTask {
            self.startConnectionTaskForActive(address: address)
        }

        self.emitPerUnitGauges()
    }

    /// Result of planning an SD update against the current pool state.
    /// All field-level mutation of `nodePools` happens under the lock
    /// inside `planInstanceUpdate`; this struct just carries the work
    /// that has to happen *outside* the lock (helper teardown is async
    /// and connection-task spawning creates Tasks that capture self).
    private struct InstanceUpdatePlan {
        /// Addresses whose ManagedNode was fully removed from
        /// `nodePools.nodes`. Each entry carries the removed node so the
        /// caller can cancel its task and reap its helpers.
        var fullyRemoved: [(address: String, node: ManagedNode)] = []
        /// Addresses for whom `isActive` transitioned from false to true
        /// in this pass — newly-installed candidates promoted into the
        /// active pool, or existing spares promoted by the greedy fill.
        /// The caller spawns each one's connection task.
        var toStartTask: [String] = []
        /// Per-unit count of the admitted, address-deduped visible instances,
        /// for the discovered-instances gauge. Computed from the same
        /// `unitsForAddress` map the pool reconciles against, so the gauge
        /// reflects exactly what was admitted — no duplicate-address inflation
        /// and no policy-rejected (e.g. non-mTLS) nodes.
        var discoveredCountsByUnit: [PersistentServiceUnitID: Int] = [:]
    }

    /// Atomically reconciles the visible SD set against `nodePools`,
    /// per unit:
    ///
    /// 1. Compute the set of `(capability, shardID)` units this serviceName's
    ///    visible instances cover. Drop any units owned by `serviceName`
    ///    no longer covered by anyone.
    /// 2. For visible-but-known nodes, update their `units` membership in
    ///    place; rebuild the byUnit index entries that changed.
    /// 3. For visible-but-new addresses, install a ManagedNode in spare
    ///    state (`isActive = false`).
    /// 4. For nodes no longer visible, remove them from `nodePools.nodes`
    ///    and from every byUnit view; surface them in `fullyRemoved`.
    /// 5. Rebuild the per-capability configuration tracking
    ///    (`pools.byCapability`) for this service from the visible instances'
    ///    `allShardIDs`. Multiple distinct configurations per capability are
    ///    preserved so coverage remains decidable during a rolling
    ///    reconfiguration.
    /// 6. Greedy fill: for each unit with a configured cap and
    ///    `activeAddresses.count < cap`, promote a random spare that
    ///    covers that unit. Promotion sets `isActive = true` on the
    ///    canonical ManagedNode and moves the address from
    ///    `spareAddresses → activeAddresses` for **every** unit it
    ///    covers (the same connection counts toward each unit it serves).
    ///    Promoted addresses surface in `toStartTask`.
    private func planInstanceUpdate(
        visibleInstances: [InstanceInfo],
        serviceName: String
    ) -> InstanceUpdatePlan {
        self.nodePools.withLock { pools in
            var plan = InstanceUpdatePlan()
            let cap = self.maxServersPerUnit?[serviceName]

            // 1. Resolve units per visible instance.
            var instanceForAddress: [String: InstanceInfo] = [:]
            var unitsForAddress: [String: Set<PersistentServiceUnitID>] = [:]
            var visibleUnitsForService: Set<PersistentServiceUnitID> = []
            for instance in visibleInstances {
                let address = Self.nodeAddress(from: instance)
                // Apply the announcement-level policy gate up front:
                // if the publisher's declared transport security
                // violates the operator's enforced policy, treat the
                // instance as if it never appeared. Step 4 below will
                // then fully remove any pre-existing entry for this
                // address along with cancelling its connection task.
                let transport = Self.inferTransportSecurity(from: instance)
                guard Self.isTransportSecurityAllowed(
                    transport,
                    address: address,
                    requireMTLS: self.requireMTLS
                ) else {
                    continue
                }
                let units = Self.unitIDs(
                    for: instance,
                    serviceName: serviceName,
                    blockedCapabilities: self.blockedCapabilities
                )
                instanceForAddress[address] = instance
                unitsForAddress[address] = units
                visibleUnitsForService.formUnion(units)
            }

            // Per-unit count of the admitted, address-deduped visible
            // instances, for the discovered-instances gauge. Taken from the
            // same `unitsForAddress` map the pool reconciles against (one
            // entry per address, only mTLS-admitted nodes), so the gauge
            // cannot diverge from what was actually admitted.
            for units in unitsForAddress.values {
                for unitID in units {
                    plan.discoveredCountsByUnit[unitID, default: 0] += 1
                }
            }

            // 2. Drop units owned by this service that no longer have any
            //    covering instances. Any active address in the dropped
            //    unit loses that unit from its membership. If the address
            //    has no remaining units (all of its units are gone), it's
            //    fully unreachable and queued for removal in step 4.
            let staleUnitIDs: [PersistentServiceUnitID] = pools.byUnit
                .compactMap { unitID, view -> PersistentServiceUnitID? in
                    guard view.serviceName == serviceName,
                          !visibleUnitsForService.contains(unitID) else { return nil }
                    return unitID
                }
            for unitID in staleUnitIDs {
                guard let view = pools.byUnit.removeValue(forKey: unitID) else { continue }
                for address in view.activeAddresses.union(view.spareAddresses) {
                    pools.nodes[address]?.units.remove(unitID)
                }
            }

            // 3. Reconcile visible instances:
            //    - existing nodes: update units membership; rebuild byUnit indices.
            //    - new nodes: install in spare state.
            for (address, units) in unitsForAddress {
                // Step 1 above populates `instanceForAddress` and
                // `unitsForAddress` together, so this lookup always
                // succeeds today. Bind once with a guard so a future
                // refactor that filters one map without the other —
                // or any other invariant slip — surfaces as a skipped
                // node rather than a crash.
                guard let instance = instanceForAddress[address] else {
                    Self.logger.error(
                        "Reconcile saw address \(address, privacy: .public) without a matching SD instance; skipping"
                    )
                    continue
                }
                // Step 1's gate already filtered policy-rejected
                // instances out of `instanceForAddress`, so anything
                // we see here is admitted. Re-infer the transport
                // mode for storage on the node.
                let transportSecurity = Self.inferTransportSecurity(from: instance)
                let serviceDefinedMetadata = Self.extractServiceDefinedMetadata(
                    from: instance
                )
                if var node = pools.nodes[address] {
                    let oldUnits = node.units
                    let removedUnits = oldUnits.subtracting(units)
                    let addedUnits = units.subtracting(oldUnits)
                    for unitID in removedUnits {
                        pools.byUnit[unitID]?.activeAddresses.remove(address)
                        pools.byUnit[unitID]?.spareAddresses.remove(address)
                        if pools.byUnit[unitID]?.activeAddresses.isEmpty == true,
                           pools.byUnit[unitID]?.spareAddresses.isEmpty == true {
                            pools.byUnit.removeValue(forKey: unitID)
                        }
                    }
                    for unitID in addedUnits {
                        if pools.byUnit[unitID] == nil {
                            pools.byUnit[unitID] = PerUnitView(serviceName: serviceName)
                        }
                        if node.isActive {
                            pools.byUnit[unitID]?.activeAddresses.insert(address)
                        } else {
                            pools.byUnit[unitID]?.spareAddresses.insert(address)
                        }
                    }
                    node.units = units
                    // Refresh metadata fields from the latest SD record:
                    // capabilities may have changed and the publisher
                    // may have rolled its declared transport mode.
                    node.serviceDefinedMetadata = serviceDefinedMetadata
                    node.transportSecurity = transportSecurity
                    pools.nodes[address] = node
                } else {
                    let host = instance.address.ip
                    let port = Int(instance.address.port)
                    let node = ManagedNode(
                        nodeAddress: address,
                        host: host,
                        port: port,
                        serviceName: serviceName,
                        instance: instance,
                        units: units,
                        isActive: false,
                        connectionState: .connecting,
                        serviceDefinedMetadata: serviceDefinedMetadata,
                        transportSecurity: transportSecurity,
                        connectionTask: nil,
                        helperID: nil,
                        replacementHelperID: nil
                    )
                    pools.nodes[address] = node
                    for unitID in units {
                        if pools.byUnit[unitID] == nil {
                            pools.byUnit[unitID] = PerUnitView(serviceName: serviceName)
                        }
                        pools.byUnit[unitID]?.spareAddresses.insert(address)
                    }
                    if let metadata = serviceDefinedMetadata {
                        Self.logger.info(
                            "Adding node \(address, privacy: .public) for service '\(serviceName, privacy: .public)' (serviceDefinedMetadata SHA256: \(SHA256.hash(data: metadata).description, privacy: .public))"
                        )
                    } else {
                        Self.logger.info(
                            "Adding node \(address, privacy: .public) for service '\(serviceName, privacy: .public)'"
                        )
                    }
                }
            }

            // 4. Remove nodes (owned by this service) no longer visible at
            //    all, OR whose units became empty after step 2.
            let toFullyRemove: [String] = pools.nodes.compactMap { address, node in
                guard node.serviceName == serviceName else { return nil }
                if instanceForAddress[address] == nil { return address }
                if node.units.isEmpty { return address }
                return nil
            }
            for address in toFullyRemove {
                guard let node = pools.nodes.removeValue(forKey: address) else { continue }
                for unitID in node.units {
                    pools.byUnit[unitID]?.activeAddresses.remove(address)
                    pools.byUnit[unitID]?.spareAddresses.remove(address)
                    if pools.byUnit[unitID]?.activeAddresses.isEmpty == true,
                       pools.byUnit[unitID]?.spareAddresses.isEmpty == true {
                        pools.byUnit.removeValue(forKey: unitID)
                    }
                }
                // Even if node.units was empty (step 2 stripped them),
                // the byUnit views were already cleaned of this address.
                if node.isActive {
                    plan.fullyRemoved.append((address: address, node: node))
                }
            }

            // 5. Rebuild per-capability configuration tracking for this
            //    service. We replace this service's entries each pass: an
            //    capability that no instance currently advertises is dropped,
            //    and any new shard configuration is picked up. Distinct
            //    configurations across instances are preserved as separate
            //    Set elements so coverage stays decidable while a rolling
            //    reconfiguration is in flight.
            var nextConfigsByCapability: [String: Set<Set<PersistentServiceUnitID>>] = [:]
            for instance in visibleInstances {
                let configs = Self.capabilityConfigurations(
                    for: instance,
                    serviceName: serviceName,
                    blockedCapabilities: self.blockedCapabilities
                )
                for (capability, units) in configs {
                    nextConfigsByCapability[capability, default: []].insert(units)
                }
            }
            // Drop capabilities owned by this service that no instance now
            // advertises. Capabilities owned by *other* services in the same
            // pool are untouched.
            let capabilitiesToRemove: [String] = pools.byCapability.compactMap { capability, tracking in
                guard tracking.serviceName == serviceName else { return nil }
                return nextConfigsByCapability[capability] == nil ? capability : nil
            }
            for capability in capabilitiesToRemove {
                pools.byCapability.removeValue(forKey: capability)
            }
            // Install / update entries for capabilities advertised by this pass.
            for (capability, configs) in nextConfigsByCapability {
                pools.byCapability[capability] = CapabilityCoverageTracking(
                    serviceName: serviceName,
                    configurations: configs
                )
            }

            // 6. Greedy fill. Iterate units in deterministic key order so
            //    repeated test runs produce stable progress logs even
            //    though the choice of spare to promote within a unit is
            //    random.
            if let cap {
                let unitOrder: [PersistentServiceUnitID] = pools.byUnit.keys
                    .filter { pools.byUnit[$0]?.serviceName == serviceName }
                    .sorted { ($0.capability, $0.shardID) < ($1.capability, $1.shardID) }
                for unitID in unitOrder {
                    let promoted = Self.fillUnitToCap(unitID: unitID, cap: cap, pools: &pools)
                    plan.toStartTask.append(contentsOf: promoted)
                    if let view = pools.byUnit[unitID], view.activeAddresses.count < cap {
                        Self.logger.info(
                            "Unit '\(unitID, privacy: .public)' below cap=\(cap, privacy: .public): active=\(view.activeAddresses.count, privacy: .public), spares=\(view.spareAddresses.count, privacy: .public)"
                        )
                    }
                }
            } else {
                // Uncapped: promote every spare we have for this service.
                let candidates = pools.nodes.values
                    .filter { $0.serviceName == serviceName && !$0.isActive }
                    .map(\.nodeAddress)
                for address in candidates {
                    Self.promote(address: address, in: &pools)
                    plan.toStartTask.append(address)
                }
            }

            return plan
        }
    }

    /// Promotes a known node from spare state to active. Updates `isActive`
    /// on the canonical ManagedNode and moves the address from
    /// `spareAddresses` to `activeAddresses` in *every* unit the node
    /// covers (one connection counts toward every unit it serves). Caller
    /// spawns the connection task.
    private static func promote(
        address: String,
        in pools: inout NodePools
    ) {
        guard var node = pools.nodes[address], !node.isActive else { return }
        node.isActive = true
        node.connectionState = .connecting
        node.helperID = nil
        node.replacementHelperID = nil
        node.shouldSwapOnExit = false
        for unitID in node.units {
            pools.byUnit[unitID]?.spareAddresses.remove(address)
            pools.byUnit[unitID]?.activeAddresses.insert(address)
        }
        pools.nodes[address] = node
    }

    /// Demotes a known node from active to spare. The reverse of
    /// `promote` — moves its address back into `spareAddresses` of each
    /// unit and clears the in-flight connection bookkeeping. Caller is
    /// responsible for cancelling the in-flight task and tearing down
    /// any helpers, since both are off-lock async work.
    ///
    /// Sets `reconnectNotBefore = now + backoff(consecutiveFailureCount)`
    /// from the supplied strategy so a future re-promotion respects the
    /// node's accumulated streak. The instant is anchored at demote time,
    /// so a node sitting as a spare longer than the backoff window is
    /// automatically eligible by the time someone wants it.
    /// Returns the helper instances that were live on the node at demote time
    /// so the caller can forward them to `sendHelperRemoved` — its primary
    /// stream and, if a make-before-break handover was in flight, its
    /// replacement stream (a connection runs up to `maxStreamsPerConnection`
    /// at once). Empty when the node was gone/already-inactive, or was still
    /// connecting and had not yet established a helper. Without this hand-off a
    /// swap that fires while `cleanupHelper`'s `sendHelperRemoved` is preempted
    /// leaves an orphan helper entry in the router.
    private static func demote(
        address: String,
        backoffStrategy: ExponentialBackoffStrategy,
        in pools: inout NodePools
    ) -> [UUID] {
        guard var node = pools.nodes[address], node.isActive else { return [] }
        let releasedHelperIDs = [node.helperID, node.replacementHelperID].compactMap { $0 }
        node.isActive = false
        node.connectionTask = nil
        node.helperID = nil
        node.replacementHelperID = nil
        node.connectionState = .disconnected
        node.shouldSwapOnExit = false
        var strategy = backoffStrategy
        let backoff = strategy.backoff(retryCount: node.consecutiveFailureCount)
        node.reconnectNotBefore = .now.advanced(by: backoff)
        for unitID in node.units {
            pools.byUnit[unitID]?.activeAddresses.remove(address)
            pools.byUnit[unitID]?.spareAddresses.insert(address)
        }
        pools.nodes[address] = node
        return releasedHelperIDs
    }

    // MARK: - Node lifecycle

    /// Classifies an error thrown by a single connection attempt and
    /// returns the retry decision. Extracted from
    /// `startConnectionTaskForActive`'s retry strategy so tests can drive
    /// it directly with synthetic errors. Side-effects (counter bump,
    /// `shouldSwapOnExit` flag) live on the `ManagedNode` for `address`
    /// inside `nodePools`.
    ///
    /// `isTaskCancelled` is the caller's `Task.isCancelled`. Real
    /// external cancellation (SD removed the node, daemon shutting
    /// down, swap promoting a spare) sets it true; an internal
    /// `CancellationError` leaking from `runStream`'s task group when a
    /// child throws and a sibling observes the implicit group
    /// cancellation leaves it false. The latter is a transient inner
    /// failure — treating it as terminal would wedge the per-node retry
    /// loop until SD churns the node or the daemon restarts.
    internal func classifyConnectionRetryError(
        _ error: Error,
        address: String,
        isTaskCancelled: Bool
    ) -> RetryWithBackoff.RetryFilterResult {
        if error is CancellationError, isTaskCancelled {
            return .stop
        }
        if error is CancellationError {
            // Internal leak: a child of `runStream`'s discarding task
            // group threw, a sibling observed the implicit group
            // cancellation and itself threw `CancellationError`, and
            // that's what propagated. Treat as retryable — it's the
            // same shape as any other transient failure and must not
            // wedge the per-node retry loop.
            Self.logger.error(
                "Internal CancellationError leaked into retry filter for \(address, privacy: .public); treating as retryable transient failure"
            )
            // Fall through to the retryable-error path below.
        }
        // Permanent errors: retrying the same node won't help
        if let connectionError = error as? ConnectionError, !connectionError.isRetryable {
            Self.logger.error(
                "Node connection permanently failed for \(address, privacy: .public): \(String(unredacted: error), privacy: .public)"
            )
            return .stop
        }
        if let connectionError = error as? ConnectionError,
           case .reconnectRequested = connectionError {
            Self.logger.info(
                "Reconnect requested for \(address, privacy: .public). Retrying."
            )
        } else if let connectionError = error as? ConnectionError,
                  case .streamCoordinatorExited = connectionError {
            Self.logger.info(
                "Stream coordinator exited cleanly for \(address, privacy: .public). Retrying."
            )
        } else {
            Self.logger.error(
                "Node connection failed for \(address, privacy: .public): \(String(unredacted: error), privacy: .public). Retrying."
            )
        }
        // Either decide to stop for swap-on-N-failures or reset
        // state to retry — both happen under one lock acquisition so
        // the spare availability and counter can't be invalidated
        // between check and decision. The flag on the ManagedNode is
        // consumed by the terminal cleanup below.
        let stopForSwap = self.nodePools.withLock { pools -> Bool in
            guard var node = pools.nodes[address], node.isActive else {
                Self.logger.info(
                    "Node already removed during retry for \(address, privacy: .public)"
                )
                return false
            }
            // Count this attempt's failure first so the predicate
            // sees the up-to-date value. The count is reset on
            // setupComplete; a single healthy run wipes the streak.
            node.consecutiveFailureCount += 1
            let threshold = self.swapOnFailureThreshold[node.serviceName]
                ?? Self.defaultSwapOnFailureThreshold
            let hasSparesInSomeUnit = node.units.contains { unitID in
                !(pools.byUnit[unitID]?.spareAddresses.isEmpty ?? true)
            }
            if self.maxServersPerUnit?[node.serviceName] != nil,
               node.consecutiveFailureCount >= threshold,
               hasSparesInSomeUnit {
                Self.logger.info(
                    "Node \(address, privacy: .public) hit swap threshold \(threshold, privacy: .public) consecutive failures; will swap on exit"
                )
                node.shouldSwapOnExit = true
                pools.nodes[address] = node
                return true
            }
            node.connectionState = .connecting
            node.helperID = nil
            node.replacementHelperID = nil
            pools.nodes[address] = node
            return false
        }
        if stopForSwap {
            return .stop
        }
        // No retry-mid backstop send is needed here:
        // `runNodeConnection`'s per-iteration catch and happy-path
        // both `await cleanupHelper(...)` before returning/rethrowing,
        // and `cleanupHelper` awaits `sendHelperRemoved` to completion.
        // The router-side defences (XPC invalidation hook and expiry
        // reaper) cover any residual stale entry.
        return .continue
    }

    /// Spawns the per-node connection task for an address whose
    /// `isActive` was just set to `true`. The task itself is the
    /// long-lived backoff retry loop, swap-on-early-failure detection,
    /// and terminal cleanup. Stores the task handle on the canonical
    /// ManagedNode so SD-driven removal can cancel it.
    private func startConnectionTaskForActive(address: String) {
        let snapshot = self.nodePools.withLock { pools -> (host: String, port: Int, serviceName: String)? in
            guard let node = pools.nodes[address], node.isActive else { return nil }
            return (node.host, node.port, node.serviceName)
        }
        guard let snapshot else {
            Self.logger.info(
                "Address \(address, privacy: .public) no longer active before its task could start; skipping"
            )
            return
        }

        let host = snapshot.host
        let port = snapshot.port
        let serviceName = snapshot.serviceName

        let connectionTask = Task { [weak self] in
            guard let self else { return }

            // Respect any carry-over backoff this node has earned. The
            // `reconnectNotBefore` Instant is anchored at demote time
            // (`now + backoff(consecutiveFailureCount)`), so wall-clock
            // time spent sitting as a spare counts against the cooldown:
            // a node that's been a spare longer than its backoff window
            // has `.now >= node.reconnectNotBefore` and the sleep returns
            // immediately. `nil` = no constraint (fresh-from-SD or
            // healthy node) and we skip the sleep entirely.
            let reconnectNotBefore = self.nodePools.withLock { pools -> ContinuousClock.Instant? in
                pools.nodes[address]?.reconnectNotBefore
            }
            if let reconnectNotBefore {
                let remaining = ContinuousClock.now.duration(to: reconnectNotBefore)
                // Threshold the log + sleep on a meaningful wait.
                if remaining > .milliseconds(1) {
                    Self.logger.info(
                        "Promoted node \(address, privacy: .public) has carry-over reconnect cooldown of \(remaining, privacy: .public); sleeping before first attempt"
                    )
                    do {
                        try await Task.sleep(until: reconnectNotBefore, clock: ContinuousClock())
                    } catch {
                        // Cancellation during the carry-over sleep — node was
                        // removed before we got to attempt. Bail cleanly.
                        return
                    }
                }
            }

            // Shared across retries so a successful attestation fetch in one round
            // persists as the seed for the next. Survives a throw from
            // runNodeConnection because runStream writes to it directly.
            let attestationCache = SharedAttestationCache()

            let retryStrategy = RetryWithBackoff(
                backoffStrategy: self.connectionBackoffStrategy,
                deadline: .noDeadline,
                logger: Self.logger
            ) { [weak self] error in
                guard let self else { return .stop }
                return self.classifyConnectionRetryError(
                    error,
                    address: address,
                    isTaskCancelled: Task.isCancelled
                )
            }

            do {
                try await executeWithRetries(retryStrategy: retryStrategy) {
                    try await self.runNodeConnection(
                        address: address,
                        host: host,
                        port: port,
                        attestationCache: attestationCache
                    )
                }
            } catch is CancellationError {
                Self.logger.info("Node connection task cancelled for \(address, privacy: .public)")
            } catch {
                Self.logger.error(
                    "Node connection permanently failed for \(address, privacy: .public): \(String(unredacted: error), privacy: .public)"
                )
            }

            // Consume the swap-on-exit flag the retry filter may have set.
            // Atomic read+clear so an SD update that removes the node
            // between the filter and here can't accidentally cause a swap
            // on a stale entry.
            let shouldSwapNow = self.nodePools.withLock { pools -> Bool in
                guard var node = pools.nodes[address], node.isActive else { return false }
                let flag = node.shouldSwapOnExit
                node.shouldSwapOnExit = false
                pools.nodes[address] = node
                return flag
            }
            if shouldSwapNow {
                await self.swapToSpareIfPossible(failedAddress: address, serviceName: serviceName)
            }

            let leakedHelperIDs: (primary: UUID?, replacement: UUID?) = self.nodePools.withLock { pools in
                guard var node = pools.nodes[address], node.isActive else {
                    Self.logger.info(
                        "Node already removed during cleanup for \(address, privacy: .public)"
                    )
                    return (nil, nil)
                }
                let primary = node.helperID
                let replacement = node.replacementHelperID
                node.connectionState = .disconnected
                node.helperID = nil
                node.replacementHelperID = nil
                pools.nodes[address] = node
                return (primary, replacement)
            }
            // Backstop matching the retry-loop branch: send removals here so a
            // permanently-failed connection task doesn't leave router state
            // with an orphaned helper entry if cleanupHelper's await was
            // preempted.
            if let primary = leakedHelperIDs.primary {
                await self.bridgeRouterClient.sendHelperRemoved(helperID: primary)
            }
            if let replacement = leakedHelperIDs.replacement {
                await self.bridgeRouterClient.sendHelperRemoved(helperID: replacement)
            }
        }

        // Store the task handle. If the node was removed while we were
        // creating the task (concurrent SD update), cancel the orphaned
        // task. The active-state check is mandatory because demote() in
        // swapToSpareIfPossible could have flipped isActive while we were
        // outside the lock.
        self.nodePools.withLock { pools in
            if pools.isActive(address: address) {
                pools.nodes[address]?.connectionTask = connectionTask
            } else {
                Self.logger.info(
                    "Node no longer active before connectionTask could be stored for \(address, privacy: .public)"
                )
                connectionTask.cancel()
            }
        }
    }

    /// Outcome of a swap attempt. The two swapping cases both carry the
    /// helperIDs the demotion `released` (which the router must be told about);
    /// they differ in whether a replacement was promoted into the freed slot.
    private enum SwapOutcome {
        /// Failed node was gone or no covering spare was available — no change.
        case noSwap
        /// Failed node demoted and a spare promoted into the freed slot.
        case replaced(released: [UUID], promotedAddress: String)
        /// Failed node demoted but no replacement was needed — it was over-cap
        /// overflow, so the surplus connection is shed rather than replaced.
        case shed(released: [UUID])
    }

    /// Forwards the helperIDs a demotion released to the router so it drops its
    /// entries — releasing the pool slot alone does not.
    private func reapDemotedHelpers(_ releasedHelperIDs: [UUID]) async {
        for helperID in releasedHelperIDs {
            await self.bridgeRouterClient.sendHelperRemoved(helperID: helperID)
        }
    }

    /// Demotes `failedAddress` to spares and promotes one of its units'
    /// spares into the freed slot. No-op if the address is gone (SD
    /// removed it concurrently) or if no unit it covers has any spare
    /// available. Stays scoped to units the failed node covers so
    /// per-unit caps remain intact.
    private func swapToSpareIfPossible(failedAddress: String, serviceName: String) async {
        let backoffStrategy = self.connectionBackoffStrategy
        let outcome: SwapOutcome = self.nodePools.withLock { pools -> SwapOutcome in
            guard let node = pools.nodes[failedAddress], node.isActive else { return .noSwap }
            // Pick a spare to promote. Search units the failed node covers
            // — the per-unit cap contract requires the swap stays scoped
            // to those units. `pickFreshestSpare` prefers the candidate
            // whose `reconnectNotBefore` is soonest so a recently-failed
            // spare isn't immediately re-picked.
            var chosen: String?
            for unitID in node.units {
                if let candidate = Self.pickFreshestSpare(
                    in: unitID,
                    pools: &pools,
                    excluding: failedAddress
                ) {
                    chosen = candidate
                    break
                }
            }
            guard let chosen else { return .noSwap }
            // Demote the failed node, then promote the chosen spare. The
            // demoted node's task is already exiting (terminal cleanup is
            // what called us), so we don't cancel anything. `demote`
            // anchors the failed node's `reconnectNotBefore` at
            // `now + backoff(consecutiveFailureCount)` so a future
            // re-promotion respects its streak. The returned helperIDs
            // are the ones that were live on the node at demote time;
            // they're forwarded to `sendHelperRemoved` below so the
            // router can't be left with an orphan entry on the swap
            // path (the per-node loop's backstop is gated on
            // `isActive` and short-circuits once demote has flipped it).
            let released = Self.demote(address: failedAddress, backoffStrategy: backoffStrategy, in: &pools)
            // Promote the replacement only if a unit still needs it. Demote
            // above already restored the failed node's slots; if the failed
            // node was itself over-cap overflow, the units are still at cap
            // and we shed the surplus rather than replacing it.
            let didPromote = Self.promoteIfNeeded(
                address: chosen,
                in: &pools,
                maxServersPerUnit: self.maxServersPerUnit
            )
            return didPromote ? .replaced(released: released, promotedAddress: chosen) : .shed(released: released)
        }
        switch outcome {
        case .noSwap:
            return
        case .shed(let released):
            await self.reapDemotedHelpers(released)
        case .replaced(let released, let promotedAddress):
            await self.reapDemotedHelpers(released)
            Self.logger.info(
                "Swapping node \(failedAddress, privacy: .public) to spares; promoting \(promotedAddress, privacy: .public) for service '\(serviceName, privacy: .public)'"
            )
            self.startConnectionTaskForActive(address: promotedAddress)
        }
    }

    /// Promotes `address` from spare to active — but only if the node is
    /// still *needed*, i.e. at least one unit it covers is below cap. A single
    /// connection counts toward every unit the node covers, so promoting a
    /// node for a unit that needs it can push a sibling unit that is already
    /// at cap over its ceiling; that overflow is unavoidable and intended when
    /// units overlap (e.g. a sharded `bf2` node that also serves the unsharded
    /// `bf1` filter — covering every shard necessarily over-covers `bf1`).
    /// What must never happen is promoting a node that *no* unit needs: that
    /// is a redundant connection, and repeating it under churn is what ratchets
    /// the active pool up to the full cell size. The backfill and swap paths
    /// route through this gateway; the planning-time greedy fill
    /// (`fillUnitToCap`) enforces the same below-cap rule via its own loop
    /// guard. An uncapped unit always counts as needing the node. Returns
    /// whether it promoted, so the caller knows whether to spawn a task.
    private static func promoteIfNeeded(
        address: String,
        in pools: inout NodePools,
        maxServersPerUnit: [String: Int]?
    ) -> Bool {
        guard let node = pools.nodes[address], !node.isActive else { return false }
        let needed = node.units.contains { unitID in
            guard let view = pools.byUnit[unitID] else { return false }
            guard let cap = maxServersPerUnit?[view.serviceName] else { return true }
            return view.activeAddresses.count < cap
        }
        guard needed else { return false }
        Self.promote(address: address, in: &pools)
        return true
    }

    /// Promotes one random spare from the given unit (if any) into its
    /// active pool. Called after `tearDownRemovedNode` opens a slot in
    /// that unit. No-op for units without a cap (the planning step
    /// already promoted everything for uncapped services).
    private func promoteOneSpare(in unitID: PersistentServiceUnitID) {
        let promoted: String? = self.nodePools.withLock { pools -> String? in
            guard let chosen = Self.pickFreshestSpare(in: unitID, pools: &pools, excluding: nil) else {
                return nil
            }
            let didPromote = Self.promoteIfNeeded(
                address: chosen,
                in: &pools,
                maxServersPerUnit: self.maxServersPerUnit
            )
            return didPromote ? chosen : nil
        }
        guard let promoted else { return }
        Self.logger.info(
            "Promoting spare \(promoted, privacy: .public) into unit '\(unitID, privacy: .public)' after active slot opened"
        )
        self.startConnectionTaskForActive(address: promoted)
    }

    /// Picks a spare for promotion in the given unit.
    ///
    /// Two-stage priority:
    ///
    /// 1. Spares with `reconnectNotBefore == nil` — fresh-from-SD
    ///    nodes that have never failed under our retention — are
    ///    preferred outright. If any exist we pick one at random and
    ///    are done; an "earliest cooldown deadline" candidate never
    ///    competes with a fresh node, regardless of how long the
    ///    deadline has been in the past.
    /// 2. Otherwise every candidate has a `reconnectNotBefore`
    ///    Instant. Pick the earliest. The semantic of
    ///    `reconnectNotBefore` is "no attempts before this instant",
    ///    so the earliest Instant is the most ready — whether the
    ///    instant is in the past (eligible immediately) or the future
    ///    (least cooldown remaining). Ties are broken at random.
    ///
    /// We deliberately don't compare against `.now`: a spare with an
    /// already-elapsed deadline and a spare with a slightly-future
    /// deadline both want the same treatment ("pick the one with the
    /// earliest deadline"). Bucketing them as past/future would just
    /// rerandomize within an arbitrarily-defined "ready" set.
    private static func pickFreshestSpare(
        in unitID: PersistentServiceUnitID,
        pools: inout NodePools,
        excluding: String?
    ) -> String? {
        guard let view = pools.byUnit[unitID] else { return nil }
        let candidates = excluding.map { view.spareAddresses.subtracting([$0]) }
            ?? view.spareAddresses
        guard !candidates.isEmpty else { return nil }
        // Two-pass: first prefer "no constraint" candidates; if any
        // exist, pick at random among them. Otherwise pick the soonest
        // Instant.
        let unconstrained = candidates.filter { pools.nodes[$0]?.reconnectNotBefore == nil }
        if let chosen = unconstrained.randomElement(using: &pools.rng) { return chosen }
        let scored = candidates.compactMap { addr -> (ContinuousClock.Instant, String)? in
            guard let dl = pools.nodes[addr]?.reconnectNotBefore else { return nil }
            return (dl, addr)
        }
        guard let minInstant = scored.map(\.0).min() else { return nil }
        let soonestReady = scored.filter { $0.0 == minInstant }.map(\.1)
        return soonestReady.randomElement(using: &pools.rng)
    }

    /// Drives `unitID`'s active pool up to `cap` by promoting spares,
    /// preferring whichever candidate `pickFreshestSpare` says is most
    /// ready. Mutating contract: each successful promotion moves an
    /// address from `pools.byUnit[unitID].spareAddresses` to
    /// `activeAddresses` and flips the canonical `nodes[address]` to
    /// active. Returns the addresses promoted in iteration order so the
    /// caller can spawn their connection tasks.
    ///
    /// The loop is bounded statically by `min(deficit, spareCount)`
    /// captured at entry. In normal operation the early `return`
    /// inside the loop body fires first (no candidate or no deficit
    /// remaining); the bound exists as a defence against a buggy
    /// `promote` or `pickFreshestSpare` that fails to make progress —
    /// without it a regression there would silently spin forever
    /// holding the `nodePools` lock.
    private static func fillUnitToCap(
        unitID: PersistentServiceUnitID,
        cap: Int,
        pools: inout NodePools
    ) -> [String] {
        guard let view = pools.byUnit[unitID] else { return [] }
        let upperBound = min(
            max(0, cap - view.activeAddresses.count),
            view.spareAddresses.count
        )
        guard upperBound > 0 else { return [] }
        var promoted: [String] = []
        promoted.reserveCapacity(upperBound)
        for _ in 0 ..< upperBound {
            guard let active = pools.byUnit[unitID]?.activeAddresses.count, active < cap,
                  let chosen = pickFreshestSpare(in: unitID, pools: &pools, excluding: nil) else {
                return promoted
            }
            self.promote(address: chosen, in: &pools)
            promoted.append(chosen)
        }
        return promoted
    }

    /// Tears down an active node that was removed from `nodePools.nodes`
    /// during planning. Cancels its in-flight task, reaps any helpers
    /// the bridge spawned for it, then promotes one spare per unit the
    /// removed node had been holding a slot in (so caps are maintained
    /// without waiting for the next SD update).
    private func tearDownRemovedNode(
        address: String,
        node: ManagedNode,
        serviceName: String
    ) async {
        Self.logger.info(
            "Removing node \(address, privacy: .public) for service '\(serviceName, privacy: .public)'"
        )

        node.connectionTask?.cancel()

        if let helperID = node.helperID {
            Self.logger.info(
                "Tearing down helper \(helperID, privacy: .public) for removed node \(address, privacy: .public)"
            )
            await self.helperInstanceProvider.removeInstance(uuid: helperID)
            await self.bridgeRouterClient.sendHelperRemoved(helperID: helperID)
        }
        if let replacementHelperID = node.replacementHelperID {
            Self.logger.info(
                "Tearing down replacement helper \(replacementHelperID, privacy: .public) for removed node \(address, privacy: .public)"
            )
            await self.helperInstanceProvider.removeInstance(uuid: replacementHelperID)
            await self.bridgeRouterClient.sendHelperRemoved(helperID: replacementHelperID)
        }

        // For each unit the removed node was holding an active slot in,
        // try to promote a spare so the unit returns to its target cap.
        if self.maxServersPerUnit?[serviceName] != nil {
            for unitID in node.units {
                self.promoteOneSpare(in: unitID)
            }
        }
    }

    // MARK: - Per-node gRPC connection flow

    /// Maximum number of concurrent gRPC streams per node connection.
    /// One primary + one replacement = 2.
    private static let maxStreamsPerConnection = 2

    /// Manages the gRPC connection lifecycle for a single compute node.
    ///
    /// Coordinates up to two concurrent streams (primary + replacement) via `runStream`.
    /// Never returns normally. A clean exit of the stream coordinator just means
    /// *this stream* ended — for example, the server drained and closed it (see
    /// `.enteredDraining` / `.enteredDrainingCritical` in `runStream`), or the
    /// primary-replacement chain ran out. It does *not* mean the node is gone;
    /// node liveness is Service Discovery's call.
    ///
    /// So we throw a retryable `ConnectionError` and let `executeWithRetries`
    /// back off and open a new stream. This keeps retrying as long as the node
    /// is still in `nodePools.nodes`. The loop terminates when SD removes the node:
    /// `handleInstancesChanged` → `removeNode` cancels the connectionTask, which
    /// surfaces as `CancellationError` and the retry filter stops. A
    /// non-retryable `ConnectionError` would also stop, but none of the current
    /// cases are non-retryable.
    private func runNodeConnection(
        address: String,
        host: String,
        port: Int,
        attestationCache: SharedAttestationCache
    ) async throws {
        // Signal channel for stream creation. The initial attestation (possibly nil for
        // attestationPending) is seeded before the loop. When a running stream receives
        // connectionShouldBeRecreated, it yields a `StreamSpawn` here to trigger a
        // replacement stream (carrying a readiness continuation it then waits on).
        let (streamSignals, signalContinuation) = AsyncStream<StreamSpawn>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maxStreamsPerConnection)
        )

        // Seed the primary stream with whatever attestation the previous round cached.
        // No readiness continuation: nothing is waiting on the primary's readiness.
        signalContinuation.yield(StreamSpawn(attestation: attestationCache.load(), readyContinuation: nil))

        try await withThrowingTaskGroup(of: Void.self) { streamsTaskGroup in
            // Stream coordinator: spawns streams as signals arrive, up to the
            // concurrent limit. Each stream task decrements the counter on exit
            // so the count always reflects the true number of running streams.
            let activeStreams = ActiveStreamCounter()
            for await spawn in streamSignals {
                // If at capacity, wait for one stream to finish before spawning.
                while activeStreams.count >= Self.maxStreamsPerConnection {
                    try await streamsTaskGroup.next()
                }

                let isReplacement = activeStreams.count > 0
                activeStreams.increment()

                streamsTaskGroup.addTask {
                    defer { activeStreams.decrement() }
                    try await self.runStream(
                        address: address,
                        host: host,
                        port: port,
                        initialAttestation: spawn.attestation,
                        isReplacement: isReplacement,
                        replacementContinuation: signalContinuation,
                        readyContinuation: spawn.readyContinuation,
                        sharedCachedAttestation: attestationCache
                    )
                }
            }

            try await streamsTaskGroup.waitForAll()
        }

        // Stream coordinator exited cleanly. Throw a retryable error so the
        // retry loop opens a fresh stream; it'll stop looping once SD removes
        // the node and cancels us. Attestation accumulated during this round
        // is already in `attestationCache` via runStream's store() calls and
        // will seed the next round.
        Self.logger.info(
            "Stream coordinator exited cleanly for \(address, privacy: .public); reconnecting"
        )
        throw ConnectionError.streamCoordinatorExited(address: address)
    }

    /// Opens the bidirectional gRPC stream for a persistent-service node
    /// and sends `AnnounceConnection`. Wraps the establishment in
    /// `withEstablishmentTimeout` because gRPC-Swift's
    /// `connectionPool.maxWaitTime` has been observed not to bound real-
    /// world failures (closed-on-accept listeners, HTTP/2 mid-handshake
    /// RST); on hard timeout the wrapper throws
    /// `ConnectionError.establishmentTimeout` so the swap-on-early-
    /// failure path can promote a spare.
    ///
    /// On a `.establishmentTimeout` throw this method emits the
    /// `ConnectionEstablishmentTimeoutCounter` metric (sliced by the
    /// node's `serviceName` snapshot) and rethrows. Any other error —
    /// including non-`ConnectionError` transport errors from
    /// `requestStream.send` — propagates unchanged.
    ///
    /// On success the caller is responsible for the channel-close
    /// `defer`. On any throw there is no channel to close: either
    /// `establishConnection` never got that far, or
    /// `withEstablishmentTimeout`'s `closeOnLoss` already closed the
    /// salvaged channel from the lost-race path.
    private func openGRPCStream(
        host: String,
        port: Int,
        address: String,
        connectionID: String
    ) async throws -> (channel: any GRPCChannel, call: GRPCAsyncBidirectionalStreamingCall<
        PersistentServiceRequest,
        PersistentServiceResponse
    >) {
        let timeout = self.connectionEstablishmentTimeout
        let metricsSystem = self.metricsSystem
        // Connection-lifecycle counters slice by `serviceName`, not by
        // per-unit dimensions: the connection covers every unit the
        // node advertises, so per-unit fan-out would N-fold-count a
        // single event. `serviceName` lookup races a concurrent SD
        // removal — fall back to empty (low-cardinality sentinel,
        // matching `""` for unsharded `shardID` elsewhere) so a node
        // that just got pulled from SD doesn't poison the metric
        // backend with an IP:port-shaped serviceName.
        let serviceNameForMetric = self.nodePools.withLock { pools in
            pools.serviceName(of: address)
        }
        do {
            return try await Self.withEstablishmentTimeout(
                timeout,
                host: host,
                port: port,
                operation: {
                    try await self.channelPoolBuilder.establishConnection(
                        host: host,
                        port: port,
                        connectionID: connectionID,
                        resolveTransport: {
                            // Default to mtls if the node has somehow disappeared between
                            // SD ingest and now (lock window is small and the caller
                            // already validated the address). mtls is the safe choice
                            // for the production case.
                            self.nodePools.withLock { pools in
                                pools.nodes[address]?.transportSecurity ?? .mtls
                            }
                        }
                    )
                },
                closeOnLoss: { salvagedChannel, _ in
                    // Operation finished after the timer won the race. Close
                    // the channel it produced so we don't leak the connection
                    // pool; the bidi call rides the channel and is torn down
                    // with it.
                    do {
                        try await salvagedChannel.close().get()
                    } catch {
                        Self.logger.error(
                            "Failed to close salvaged gRPC channel after establishment timeout for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
                        )
                    }
                }
            )
        } catch let error as ConnectionError {
            if case .establishmentTimeout = error {
                Self.logger.error(
                    "Connection establishment to \(host, privacy: .public):\(port, privacy: .public) timed out for \(connectionID, privacy: .public); cancelling"
                )
                metricsSystem.emit(
                    Metrics.PersistentClientHelper.ConnectionEstablishmentTimeoutCounter(
                        dimensions: [.serviceName: serviceNameForMetric]
                    )
                )
            }
            throw error
        }
    }

    /// Adds an application-level keep-alive sender to `group` that emits
    /// a `KeepAlive` request every `keepaliveInterval`. Liveness detection
    /// for a black-holed TCP connection is handled at the HTTP/2 layer via
    /// NIO PINGs (see `applyChannelPoolConfiguration` on
    /// `PersistentChannelPoolBuilder`); this sender's job is to keep the
    /// server's own idle watchdog (PersistentServiceProvider) from
    /// tearing the stream down on quiet periods.
    private func addKeepaliveSender(
        to group: inout ThrowingDiscardingTaskGroup<Error>,
        requestStream: GRPCAsyncRequestStreamWriter<PersistentServiceRequest>
    ) {
        group.addTask {
            while !Task.isCancelled {
                try await Task.sleep(for: self.keepaliveInterval)
                var keepAlive = PersistentServiceRequest()
                keepAlive.type = .keepAlive(.init())
                try await requestStream.send(keepAlive)
            }
        }
    }

    /// Adds a belt-and-braces idle-timeout watchdog to `group` that
    /// throws `ConnectionError.idleTimeout` when no inbound activity is
    /// observed within `idleTimeout`. Complements the HTTP/2-layer
    /// keepalive PINGs configured on the channel: those bound a
    /// black-holed TCP connection within
    /// `pingInterval + pongTimeout`; this watchdog catches application-
    /// level stalls where TCP/H2 are healthy but the server has stopped
    /// producing.
    private func addIdleTimeoutWatchdog(
        to group: inout ThrowingDiscardingTaskGroup<Error>,
        lastActivity: LastActivity,
        connectionID: String
    ) {
        let idleTimeout = self.idleTimeout
        group.addTask {
            while !Task.isCancelled {
                try await Task.sleep(for: idleTimeout)
                let elapsed = lastActivity.elapsed
                if elapsed >= idleTimeout {
                    Self.logger.error(
                        "Connection idle timeout (\(idleTimeout, privacy: .public)) exceeded for \(connectionID, privacy: .public)"
                    )
                    throw ConnectionError.idleTimeout(connectionID: connectionID)
                }
            }
        }
    }

    /// Adds a hard-deadline watchdog to `group` that fires
    /// `keyExpiryGracePeriod` after the attestation's server-supplied
    /// `hardExpiry`. Past that point the helper is provably useless —
    /// any further query would fail at the server's AEAD step — so the
    /// watchdog throws `ConnectionError.helperKeyExpired` to force
    /// teardown and reclaim the stream slot. Belt-and-braces against a
    /// regressed drain-complete signal that escaped the bridge's
    /// `drainCompleteWaitTimeout`.
    ///
    /// Emits `HelperKeyExpiredForceTeardownCounter` (sliced by the
    /// node's `serviceName` snapshot) when the deadline fires.
    private func addKeyExpiryWatchdog(
        to group: inout ThrowingDiscardingTaskGroup<Error>,
        initialAttestation: AttestationInfo,
        address: String,
        connectionID: String
    ) {
        let hardExpiry = initialAttestation.hardExpiry
        let grace = self.keyExpiryGracePeriod
        let watchdogMetrics = self.metricsSystem
        let keyIDB64 = initialAttestation.keyID.base64EncodedString()
        let serviceNameAtExpiry = self.nodePools.withLock { pools in
            pools.serviceName(of: address)
        }
        group.addTask {
            let waitDuration: Duration = .seconds(hardExpiry.timeIntervalSinceNow) + grace
            if waitDuration > .zero {
                try await Task.sleep(for: waitDuration)
            }
            Self.logger.error(
                "Helper key hard-expired (keyID=\(keyIDB64, privacy: .public), connectionID=\(connectionID, privacy: .public), expired=\(hardExpiry, privacy: .public), grace=\(grace, privacy: .public)) — force tear-down to clear stream slot"
            )
            watchdogMetrics.emit(
                Metrics.PersistentClientHelper.HelperKeyExpiredForceTeardownCounter(
                    dimensions: [.serviceName: serviceNameAtExpiry]
                )
            )
            throw ConnectionError.helperKeyExpired(connectionID: connectionID)
        }
    }

    /// Returns an `AsyncThrowingStream` that mirrors the gRPC response
    /// stream and completes (with the underlying error or normally) as
    /// soon as a sibling task in `group` throws.
    ///
    /// The forwarding task is added to `group`. When another child task
    /// throws (e.g. idle timeout, key expiry), `withThrowingDiscardingTaskGroup`
    /// cancels every remaining child including the forwarder, which
    /// finishes the returned stream and lets the response-pump's
    /// `for try await` exit so the error can propagate to the retry
    /// handler. Iterating `call.responseStream` directly would not have
    /// this property — gRPC's stream doesn't observe sibling-task
    /// failures and would block the pump until the gRPC channel itself
    /// closed.
    private func cancellableResponseStream(
        from call: GRPCAsyncBidirectionalStreamingCall<
            PersistentServiceRequest,
            PersistentServiceResponse
        >,
        in group: inout ThrowingDiscardingTaskGroup<Error>
    ) -> AsyncThrowingStream<PersistentServiceResponse, Error> {
        let (stream, continuation) = AsyncThrowingStream<PersistentServiceResponse, Error>.makeStream()
        group.addTask {
            do {
                for try await response in call.responseStream {
                    continuation.yield(response)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    /// Drives the post-`SetupAck` wire-up: commits the helper as the
    /// node's primary, acknowledges setup to the delegate, and adds the
    /// two long-lived data-path tasks to `group` (the chunk forwarder
    /// from helper to gRPC, and the metadata-validation gate that
    /// signals `helperReady` to the router only after the helper's
    /// served metadata matches what we announced).
    ///
    /// Encrypted traffic is now flowing, so this is the moment we
    /// declare the run "healthy": the node's `consecutiveFailureCount`
    /// is reset to 0 and any carry-over `reconnectNotBefore` is cleared
    /// so the next failure starts a fresh backoff.
    ///
    /// Throws `ConnectionError.noActiveHelper` if `activeHelper` or
    /// `activeDelegate` is nil at this point — that's an invariant
    /// violation by the state machine (the SM only emits
    /// `.setupComplete` from the `.settingUp` state, which requires a
    /// helper has already been spawned).
    private func handleSetupComplete(
        in group: inout ThrowingDiscardingTaskGroup<Error>,
        activeHelper: PersistentHelperInstance?,
        activeDelegate: PersistentClientConnectionDelegate?,
        address: String,
        connectionID: String,
        requestStream: GRPCAsyncRequestStreamWriter<PersistentServiceRequest>,
        readyContinuation: AsyncStream<Void>.Continuation?
    ) throws {
        Self.logger.info(
            "SetupAck received for \(connectionID, privacy: .public)"
        )
        guard let helper = activeHelper, let delegate = activeDelegate else {
            let missing = switch (activeHelper, activeDelegate) {
            case (nil, nil): "helper and delegate"
            case (nil, _): "helper"
            case (_, nil): "delegate"
            default: "unknown"
            }
            Self.logger.error(
                "SetupAck received but \(missing, privacy: .public) missing for \(connectionID, privacy: .public) — invariant violation, forcing reconnect"
            )
            throw ConnectionError.noActiveHelper(connectionID: connectionID)
        }
        try self.updateActiveNode(address: address, connectionID: connectionID) {
            $0.helperID = helper.id
            $0.replacementHelperID = nil
            // Healthy run (encrypted traffic is now flowing) resets the consecutive-failure
            // counter and any carry-over backoff so the next failure starts fresh.
            $0.consecutiveFailureCount = 0
            $0.reconnectNotBefore = nil
        }
        delegate.setupAcknowledged()

        group.addTask {
            for await (data, isFinal) in delegate.forwardedChunks {
                var request = PersistentServiceRequest()
                var chunk = Proto_Ropes_Common_Chunk()
                chunk.encryptedPayload = data
                chunk.isFinal = isFinal
                request.type = .requestChunk(chunk)
                do {
                    try await requestStream.send(request)
                } catch {
                    Self.logger.error(
                        "Failed to forward helper chunk to gRPC for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
                    )
                    throw error
                }
            }
        }

        let bridgeRouterClient = self.bridgeRouterClient
        group.addTask {
            let validated: Bool
            do {
                validated = try await delegate.waitForMetadataValidation()
            } catch {
                Self.logger.error(
                    "Metadata validation failed for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
                )
                throw ConnectionError.metadataValidationFailed(connectionID: connectionID)
            }
            guard validated else {
                Self.logger.error(
                    "Metadata validation returned false for \(connectionID, privacy: .public), not signaling ready"
                )
                throw ConnectionError.metadataValidationFailed(connectionID: connectionID)
            }
            await bridgeRouterClient.sendHelperReady(helperID: helper.id)
            // The helper is now routable. If this stream is a replacement, release the
            // old stream's readiness wait so it can begin draining (make-before-break:
            // the old stream kept serving until exactly this point).
            readyContinuation?.yield(())
            readyContinuation?.finish()
        }
    }

    /// Adds a stream-retirement task to `group`. Shared by both retirement triggers:
    /// a server-initiated drain (`.enteredDraining`, `awaitReadiness == nil`, retire now)
    /// and a rotation (`.startReplacement`, `awaitReadiness != nil`, keep the old stream
    /// serving until the replacement is routable — or the readiness bound elapses — before
    /// retiring). The `latch`/`abortSignal` semantics are documented on `retireStreamOnce`.
    private func addStreamRetirementTask(
        to group: inout ThrowingDiscardingTaskGroup<Error>,
        latch: OneShotLatch,
        helperID: UUID,
        connectionID: String,
        requestStream: GRPCAsyncRequestStreamWriter<PersistentServiceRequest>,
        drainCompleteSignal: AsyncStream<Void>,
        abortSignal: AsyncStream<Void>,
        drainTimeout: Duration,
        serviceNameAtDrain: String,
        awaitReadiness: (signal: AsyncStream<Void>, timeout: Duration)?
    ) {
        group.addTask {
            if let awaitReadiness {
                let ready = await Self.awaitSignalOrTimeout(
                    signal: awaitReadiness.signal,
                    timeout: awaitReadiness.timeout
                )
                if !ready {
                    Self.logger.error(
                        "Replacement for \(connectionID, privacy: .public) did not become ready within \(awaitReadiness.timeout, privacy: .public); draining old stream anyway to honour the recreate request"
                    )
                    self.metricsSystem.emit(
                        Metrics.PersistentClientHelper.ReplacementReadyWaitTimeoutCounter(
                            dimensions: [.serviceName: serviceNameAtDrain]
                        )
                    )
                }
            }
            try await self.retireStreamOnce(
                latch: latch,
                helperID: helperID,
                connectionID: connectionID,
                requestStream: requestStream,
                drainCompleteSignal: drainCompleteSignal,
                abortSignal: abortSignal,
                drainTimeout: drainTimeout,
                serviceNameAtDrain: serviceNameAtDrain
            )
        }
    }

    /// Retires a stream that is being replaced or drained: tells the router the helper is
    /// draining (stop routing new queries), waits for in-flight queries to drain (bounded by
    /// `drainTimeout`), then sends `Terminate` so the server closes the stream. The `latch`
    /// makes this run at most once even though several triggers race (replacement-ready, the
    /// readiness backstop, a server-initiated `drainingStarted`).
    ///
    /// `abortSignal` pre-empts an *in-flight* retirement: on a server-initiated critical drain
    /// the server is force-closing the stream and has already been told the helper is removed,
    /// so we skip the (now stale, racing) `Terminate` and return. The `latch` only blocks
    /// retirements that have not started yet; the abort signal is what stops one already waiting.
    ///
    /// A failed `Terminate` send is rethrown, not swallowed: the send only fails when the gRPC
    /// stream is already broken, so we let it propagate (like the idle/key-expiry watchdogs) to
    /// tear the stream down and reclaim the slot via reconnect, rather than leaving a half-open
    /// stream that the idle watchdog can't reap while server keepalives keep arriving.
    private func retireStreamOnce(
        latch: OneShotLatch,
        helperID: UUID,
        connectionID: String,
        requestStream: GRPCAsyncRequestStreamWriter<PersistentServiceRequest>,
        drainCompleteSignal: AsyncStream<Void>,
        abortSignal: AsyncStream<Void>,
        drainTimeout: Duration,
        serviceNameAtDrain: String
    ) async throws {
        guard latch.claim() else { return }
        await self.bridgeRouterClient.sendHelperDraining(helperID: helperID)
        let outcome = await Self.awaitDrainOutcome(
            drainComplete: drainCompleteSignal,
            abort: abortSignal,
            timeout: drainTimeout
        )
        let reason: String
        switch outcome {
        case .aborted:
            // Server is force-closing the stream (critical drain) and the router already
            // saw `sendHelperRemoved`; sending our own Terminate now would just race that.
            Self.logger.info(
                "Retirement of \(connectionID, privacy: .public) pre-empted by critical drain; skipping Terminate"
            )
            return
        case .drained:
            Self.logger.info(
                "Drain complete for \(connectionID, privacy: .public), sending Terminate"
            )
            reason = "drain complete"
        case .timedOut:
            Self.logger.error(
                "Drain-complete signal never arrived for \(connectionID, privacy: .public) within \(drainTimeout, privacy: .public); forcing Terminate to recover the stream slot"
            )
            self.metricsSystem.emit(
                Metrics.PersistentClientHelper.DrainCompleteWaitTimeoutCounter(
                    dimensions: [.serviceName: serviceNameAtDrain]
                )
            )
            reason = "drain wait timeout"
        }
        var terminate = PersistentServiceRequest.Terminate()
        terminate.code = .clean
        terminate.reason = reason
        var request = PersistentServiceRequest()
        request.type = .terminate(terminate)
        // Don't call requestStream.finish() here. The server receives Terminate, triggers
        // helper teardown, and closes the response stream when its helper task exits; the
        // client's response pump then exits naturally and group.cancelAll() cleans up.
        // A send failure means the gRPC stream is already broken — rethrow so runStream
        // unwinds and the node reconnects (the standard slot-reclaim path), rather than
        // leaving a stream that keepalives keep "active" so the idle watchdog never reaps it.
        try await requestStream.send(request)
    }

    /// Emits a `.notice` log for incoming connection-lifecycle and
    /// server-lifecycle events so on-call can correlate them with
    /// state transitions and `.reconnect` decisions in the response
    /// pump. Chunks, keepalives, and setupAck are skipped — chunks and
    /// keepalives are too noisy, setupAck is already surfaced via the
    /// state transition log.
    private func traceLifecycleEvent(
        _ responseType: PersistentServiceResponse.OneOf_Type?,
        state: ConnectionStateMachine.State,
        connectionID: String
    ) {
        switch responseType {
        case .connectionLifecycle(let lc):
            // Log the suggested key so a `connectionShouldBeRecreated` can be
            // correlated to the target attestation key (and thus the server the
            // client is being asked to migrate to) when tracing a rotation.
            let suggestedKeyID = lc.hasSuggestedAttestation
                ? lc.suggestedAttestation.keyID.base64EncodedString()
                : "none"
            Self.logger.notice("""
            Connection lifecycle event for \(connectionID, privacy: .public): \
            eventType=\(String(describing: lc.eventType), privacy: .public), \
            hasAttestation=\(lc.hasSuggestedAttestation, privacy: .public), \
            suggestedKeyID=\(suggestedKeyID, privacy: .public), \
            state=\(state, privacy: .public)
            """)
        case .serverLifeCycle(let sc):
            Self.logger.notice("""
            Server lifecycle event for \(connectionID, privacy: .public): \
            eventType=\(String(describing: sc.eventType), privacy: .public), \
            state=\(state, privacy: .public)
            """)
        case .setupAck, .keepAlive, .responseChunk, .none:
            break
        }
    }

    /// Reads `serviceDefinedMetadata` for an active node under the
    /// `nodePools` lock. Throws `ConnectionError.nodeNotFound` if the
    /// node was concurrently removed (or demoted to spares — by
    /// definition spares have no in-flight stream), and
    /// `ConnectionError.missingServiceDefinedMetadata` if the field is
    /// nil at this point (an SD-publisher invariant violation rather
    /// than a transient).
    private func snapshotServiceDefinedMetadata(
        forAddress address: String,
        connectionID: String
    ) throws -> Data {
        try self.nodePools.withLock { pools -> Data in
            guard let node = pools.nodes[address], node.isActive else {
                throw ConnectionError.nodeNotFound(connectionID: connectionID)
            }
            guard let metadata = node.serviceDefinedMetadata else {
                throw ConnectionError.missingServiceDefinedMetadata(connectionID: connectionID)
            }
            return metadata
        }
    }

    /// Bootstraps a stream that is starting with an attestation seeded
    /// by a previous stream (either the initial primary that's been
    /// asked to rotate, or its replacement coming up). Initialises the
    /// state machine in `.settingUp`, syncs the node's
    /// `connectionState`, spawns the helper via `createHelper`, and
    /// records the helper's ID in either `helperID` (primary) or
    /// `replacementHelperID` (replacement).
    ///
    /// The state machine's `cachedAttestation` starts nil because the
    /// seeded attestation is consumed by `createHelper` /
    /// `setupHelper`. If the server sends a new attestation during
    /// this connection, the state machine's `cacheAttestation` path
    /// captures it for the next retry.
    ///
    /// Wraps any `createHelper` failure as
    /// `ConnectionError.helperSetupFailed`.
    private func bootstrapWithSeededAttestation(
        _ attestation: AttestationInfo,
        address: String,
        connectionID: String,
        isReplacement: Bool,
        serviceDefinedMetadata: Data
    ) async throws -> (
        stateMachine: ConnectionStateMachine,
        helper: PersistentHelperInstance,
        delegate: PersistentClientConnectionDelegate
    ) {
        Self.logger.info(
            "Using attestation for \(connectionID, privacy: .public), keyID=\(attestation.keyID.base64EncodedString(), privacy: .public)"
        )
        let stateMachine = ConnectionStateMachine(initialState: .settingUp, cachedAttestation: nil)
        try self.updateActiveNode(address: address, connectionID: connectionID) {
            $0.connectionState = .stream(.settingUp)
        }
        do {
            let (helper, delegate) = try await self.createHelper(
                attestation: attestation,
                connectionID: connectionID,
                address: address,
                serviceDefinedMetadata: serviceDefinedMetadata
            )
            do {
                try self.updateActiveNode(address: address, connectionID: connectionID) {
                    if isReplacement {
                        $0.replacementHelperID = helper.id
                    } else {
                        $0.helperID = helper.id
                    }
                }
            } catch {
                // createHelper succeeded but the node was concurrently
                // removed/demoted before we could record the helper ID. Tear
                // down the just-spawned helper before letting the error
                // propagate — without this the helper process leaks (we
                // never return it for runStream's outer cleanup path to
                // find).
                await self.cleanupHelper(helper, address: address, isReplacement: isReplacement)
                throw error
            }
            return (stateMachine, helper, delegate)
        } catch {
            Self.logger.error(
                "Helper setup failed for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
            )
            throw ConnectionError.helperSetupFailed(connectionID: connectionID, underlyingError: error)
        }
    }

    /// Bootstraps a stream that is starting *without* a seeded
    /// attestation: initialises the state machine in
    /// `.attestationPending`, syncs the node's `connectionState`, and
    /// sends the `AttestationQuery` request that prompts the server to
    /// reply with a `SuggestedAttestation`. The helper is spawned
    /// later by the response pump's `.activated` handler when that
    /// reply arrives.
    private func sendInitialAttestationQuery(
        address: String,
        connectionID: String,
        requestStream: GRPCAsyncRequestStreamWriter<PersistentServiceRequest>
    ) async throws -> ConnectionStateMachine {
        let stateMachine = ConnectionStateMachine(initialState: .attestationPending, cachedAttestation: nil)
        try self.updateActiveNode(address: address, connectionID: connectionID) {
            $0.connectionState = .stream(.attestationPending)
        }
        var attestationRequest = PersistentServiceRequest()
        attestationRequest.type = .attestationQuery(.init())
        try await requestStream.send(attestationRequest)
        Self.logger.info("Sent AttestationQuery for \(connectionID, privacy: .public)")
        return stateMachine
    }

    /// Runs a single gRPC stream: creates a channel, opens a bidirectional stream,
    /// optionally spawns a helper, and runs the response pump.
    ///
    /// Used by both the primary and replacement paths in `runNodeConnection`.
    ///
    /// - Parameters:
    ///   - initialAttestation: If non-nil, skips attestation query and goes directly to
    ///     helper setup (`settingUp`). If nil, sends an attestation query (`attestationPending`).
    ///   - isReplacement: True if this stream replaces an existing primary stream that
    ///     is in the process of draining (yielded via `.startReplacement`); false for
    ///     the first stream opened against a node. Determines which slot on
    ///     `ManagedNode` (`replacementHelperID` vs `helperID`) tracks this stream's
    ///     helper, and is recorded on the establishment log line.
    ///   - replacementContinuation: `.startReplacement` yields a `StreamSpawn` here for
    ///     the coordinator to pick up. The coordinator enforces the 2-stream limit by
    ///     spawning at most `maxStreamsPerConnection` streams.
    ///   - readyContinuation: For a replacement stream, the one-shot continuation the
    ///     spawning (old) stream is waiting on; this stream fires it once it reaches
    ///     `sendHelperReady` so the old stream can begin draining. `nil` for the primary
    ///     (nothing is waiting on the primary's readiness).
    ///   - sharedCachedAttestation: Shared cache for passing the latest attestation
    ///     between primary and replacement streams for the next retry.
    internal func runStream(
        address: String,
        host: String,
        port: Int,
        initialAttestation: AttestationInfo?,
        isReplacement: Bool,
        replacementContinuation: AsyncStream<StreamSpawn>.Continuation,
        readyContinuation: AsyncStream<Void>.Continuation?,
        sharedCachedAttestation: SharedAttestationCache
    ) async throws {
        let connectionID = UUID().uuidString

        Self.logger.notice(
            "Establishing gRPC connection to \(address, privacy: .public), connectionID=\(connectionID, privacy: .public), replacement=\(isReplacement, privacy: .public), hasInitialAttestation=\(initialAttestation != nil, privacy: .public)"
        )

        // If this is a replacement, the old stream is waiting on `readyContinuation`
        // before it begins draining. Finish it on every exit path so a replacement that
        // throws before reaching `sendHelperReady` (e.g. handshake/setup failure) releases
        // the old stream's readiness wait promptly instead of pinning it to the backstop.
        defer { readyContinuation?.finish() }

        // Track whether this stream spawned a replacement. Set to `true` by
        // the `.startReplacement` action in section 5; consumed by the defer
        // below to decide whether to finish the signal continuation.
        var spawnedReplacement = false

        // Guards this stream's retirement (sendHelperDraining → drain → Terminate) so it
        // runs at most once, whether triggered by the replacement becoming ready, the
        // readiness-wait backstop, or a server-initiated drain.
        let retirementLatch = OneShotLatch()

        // Fired by a server-initiated critical drain to pre-empt an in-flight retirement:
        // the latch only blocks a retirement that hasn't started, so this signal is what
        // stops one already waiting on drain-complete from sending a now-stale Terminate.
        let (criticalAbort, criticalAbortContinuation) = AsyncStream<Void>.makeStream()

        // Unblock `runNodeConnection`'s `for await streamSignals` coordinator
        // on every exit path from runStream, including throws from
        // establishConnection below. Only finish the continuation if this
        // stream did NOT spawn a replacement: if it did, the replacement
        // stream is now the active primary and needs the continuation alive
        // so future rotations can yield replacement signals.
        //
        // MUST be declared BEFORE establishConnection. If this defer registers
        // only after the establishment block, an early throw (e.g. retryable
        // `establishmentTimeout` when the OS reports `ENETDOWN` to the gRPC
        // pool) wedges the coordinator: `streamSignals` is never finished,
        // the for-await blocks indefinitely, and `executeWithRetries` never
        // observes the throw — so the per-node retry loop wedges until SD
        // removes the node or the daemon restarts.
        defer {
            if !spawnedReplacement {
                replacementContinuation.finish()
            }
        }

        // 1. Establish gRPC channel and send AnnounceConnection using
        //    the publisher-declared transport mode on the node.
        //    Wrapped in an outer cancellation timeout because gRPC's
        //    own `connectionPool.maxWaitTime` has been observed not to
        //    bound real-world failures (closed-on-accept listeners,
        //    HTTP/2 mid-handshake RST). On timeout the wrapper throws
        //    a retryable `establishmentTimeout` so the swap-on-early-
        //    failure path can promote a spare.
        let (channel, call) = try await self.openGRPCStream(
            host: host,
            port: port,
            address: address,
            connectionID: connectionID
        )

        defer {
            let ch = channel
            Task {
                do {
                    try await ch.close().get()
                } catch {
                    Self.logger.error(
                        "Failed to close gRPC channel for \(address, privacy: .public): \(String(unredacted: error), privacy: .public)"
                    )
                }
            }
        }

        Self.logger.info("Sent AnnounceConnection for \(connectionID, privacy: .public)")

        let serviceDefinedMetadata = try self.snapshotServiceDefinedMetadata(
            forAddress: address,
            connectionID: connectionID
        )

        var stateMachine: ConnectionStateMachine
        var activeHelper: PersistentHelperInstance?
        var activeDelegate: PersistentClientConnectionDelegate?

        if let initialAttestation {
            let bootstrap = try await self.bootstrapWithSeededAttestation(
                initialAttestation,
                address: address,
                connectionID: connectionID,
                isReplacement: isReplacement,
                serviceDefinedMetadata: serviceDefinedMetadata
            )
            stateMachine = bootstrap.stateMachine
            activeHelper = bootstrap.helper
            activeDelegate = bootstrap.delegate
        } else {
            stateMachine = try await self.sendInitialAttestationQuery(
                address: address,
                connectionID: connectionID,
                requestStream: call.requestStream
            )
        }

        // 5. Response pump and supporting tasks
        let lastMessageReceived = LastActivity()

        do {
            try await withThrowingDiscardingTaskGroup { group in
                self.addKeepaliveSender(to: &group, requestStream: call.requestStream)
                self.addIdleTimeoutWatchdog(
                    to: &group,
                    lastActivity: lastMessageReceived,
                    connectionID: connectionID
                )
                if let initialAttestation {
                    self.addKeyExpiryWatchdog(
                        to: &group,
                        initialAttestation: initialAttestation,
                        address: address,
                        connectionID: connectionID
                    )
                }

                // If we already have a helper (from initial attestation), start its tasks
                if let helper = activeHelper, let delegate = activeDelegate, let initialAttestation {
                    try self.startHelper(
                        helper: helper,
                        delegate: delegate,
                        attestation: initialAttestation,
                        connectionID: connectionID,
                        address: address,
                        serviceDefinedMetadata: serviceDefinedMetadata,
                        requestStream: call.requestStream,
                        group: &group
                    )
                }

                let responseStream = self.cancellableResponseStream(
                    from: call,
                    in: &group
                )

                // Response pump
                for try await response in responseStream {
                    lastMessageReceived.recordActivity()

                    self.traceLifecycleEvent(
                        response.type,
                        state: stateMachine.state,
                        connectionID: connectionID
                    )

                    let previousState = stateMachine.state
                    let action = stateMachine.handleResponse(response.type)

                    // Sync the state machine's state to the managed node only on transitions
                    if stateMachine.state != previousState {
                        Self.logger.notice("""
                        Stream state transitioned for \(connectionID, privacy: .public): \
                        \(previousState, privacy: .public) -> \(stateMachine.state, privacy: .public)
                        """)
                        try self.updateActiveNode(address: address, connectionID: connectionID) {
                            $0.connectionState = .stream(stateMachine.state)
                        }
                    }

                    switch action {
                    case .continue:
                        break

                    case .enteredDraining:
                        // Server-initiated graceful drain. Retire this stream now (the
                        // server decided; there's no replacement to wait for on this path).
                        // The in-flight drain is bounded by `drainCompleteWaitTimeout`; queries
                        // here are sub-second, so the bound only guards against a regressed
                        // drain-complete signal pinning the slot — not a real long drain.
                        if let helper = activeHelper, let delegate = activeDelegate {
                            self.addStreamRetirementTask(
                                to: &group,
                                latch: retirementLatch,
                                helperID: helper.id,
                                connectionID: connectionID,
                                requestStream: call.requestStream,
                                drainCompleteSignal: delegate.drainCompleteSignal,
                                abortSignal: criticalAbort,
                                drainTimeout: self.drainCompleteWaitTimeout,
                                serviceNameAtDrain: self.nodePools.withLock { $0.serviceName(of: address) },
                                awaitReadiness: nil
                            )
                        }

                    case .enteredDrainingCritical:
                        // Critical draining: the server is about to force-close the stream.
                        // Tell the router this helper is effectively removed so it doesn't
                        // wait for in-flight responses that may never arrive. Claim the
                        // retirement latch so a *future* retirement won't start, AND fire the
                        // abort signal so an *in-flight* retirement (already past the latch and
                        // waiting on drain-complete) short-circuits instead of sending a stale
                        // Terminate that races this removal.
                        _ = retirementLatch.claim()
                        criticalAbortContinuation.finish()
                        if let helper = activeHelper {
                            await self.bridgeRouterClient.sendHelperRemoved(helperID: helper.id)
                        }

                    case .activated(let attestation):
                        Self.logger.info(
                            "Attestation received for \(connectionID, privacy: .public), spawning helper"
                        )
                        do {
                            let serviceDefinedMetadata: Data = try self.nodePools.withLock { pools -> Data in
                                guard let node = pools.nodes[address], node.isActive else {
                                    throw ConnectionError.nodeNotFound(connectionID: connectionID)
                                }
                                guard let metadata = node.serviceDefinedMetadata else {
                                    throw ConnectionError.missingServiceDefinedMetadata(connectionID: connectionID)
                                }
                                return metadata
                            }
                            let (helper, delegate) = try await self.createHelper(
                                attestation: attestation,
                                connectionID: connectionID,
                                address: address,
                                serviceDefinedMetadata: serviceDefinedMetadata
                            )
                            activeHelper = helper
                            activeDelegate = delegate
                            try self.startHelper(
                                helper: helper,
                                delegate: delegate,
                                attestation: attestation,
                                connectionID: connectionID,
                                address: address,
                                serviceDefinedMetadata: serviceDefinedMetadata,
                                requestStream: call.requestStream,
                                group: &group
                            )
                        } catch {
                            Self.logger.error(
                                "Helper setup failed for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
                            )
                            throw ConnectionError.helperSetupFailed(
                                connectionID: connectionID,
                                underlyingError: error
                            )
                        }

                    case .setupComplete:
                        try self.handleSetupComplete(
                            in: &group,
                            activeHelper: activeHelper,
                            activeDelegate: activeDelegate,
                            address: address,
                            connectionID: connectionID,
                            requestStream: call.requestStream,
                            readyContinuation: readyContinuation
                        )

                    case .startReplacement(let attestation):
                        Self.logger.info(
                            "Replacement requested for \(connectionID, privacy: .public)"
                        )
                        spawnedReplacement = true
                        // Make-before-break: do NOT drain the old helper yet. Keep it `.ready`
                        // and serving while the replacement establishes; begin draining this
                        // stream only once the replacement signals `sendHelperReady` (fired via
                        // `readyContinuation` in `handleSetupComplete`) — or the readiness
                        // backstop fires. The proto licenses this: queries may keep flowing on
                        // the current connection while the new gRPC is being established.
                        // `readyContinuation` is non-nil only when we actually scheduled a
                        // retirement that's waiting on it; otherwise the replacement has nothing
                        // to signal.
                        var readyContinuationForReplacement: AsyncStream<Void>.Continuation?
                        if let delegate = activeDelegate, let helper = activeHelper {
                            let (readySignal, readyCont) = AsyncStream<Void>.makeStream()
                            readyContinuationForReplacement = readyCont
                            self.addStreamRetirementTask(
                                to: &group,
                                latch: retirementLatch,
                                helperID: helper.id,
                                connectionID: connectionID,
                                requestStream: call.requestStream,
                                drainCompleteSignal: delegate.drainCompleteSignal,
                                abortSignal: criticalAbort,
                                drainTimeout: self.drainCompleteWaitTimeout,
                                serviceNameAtDrain: self.nodePools.withLock { $0.serviceName(of: address) },
                                awaitReadiness: (signal: readySignal, timeout: self.replacementReadyWaitTimeout)
                            )
                        }
                        let spawnResult = replacementContinuation.yield(
                            StreamSpawn(
                                attestation: attestation,
                                readyContinuation: readyContinuationForReplacement
                            )
                        )
                        // If the coordinator didn't accept the spawn (buffer full, or it has
                        // finished because the node is unwinding), no replacement will come up
                        // to fire `readyContinuation`. Finish it now so the retirement task
                        // drains immediately instead of waiting out `replacementReadyWaitTimeout`.
                        if case .enqueued = spawnResult {} else {
                            Self.logger.error(
                                "Replacement spawn for \(connectionID, privacy: .public) was not accepted (\(String(describing: spawnResult), privacy: .public)); retiring old stream without waiting for a replacement"
                            )
                            readyContinuationForReplacement?.finish()
                        }

                    case .forwardResponseChunk(let data, let isFinal):
                        guard let helper = activeHelper else {
                            Self.logger.error(
                                "Received responseChunk but no active helper for \(connectionID, privacy: .public)"
                            )
                            throw ConnectionError.noActiveHelper(connectionID: connectionID)
                        }
                        do {
                            try await helper.sendEncryptedMessage(.encryptedChunk(data, isFinal: isFinal))
                        } catch {
                            Self.logger.error(
                                "Failed to forward responseChunk to helper for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
                            )
                            throw error
                        }

                    case .reconnect:
                        Self.logger.notice("""
                        Reconnect requested for \(connectionID, privacy: .public) from state \
                        \(previousState, privacy: .public); cancelling all stream tasks (helper, \
                        response pump, keepalive). Any in-flight queries on this stream will be lost.
                        """)
                        group.cancelAll()
                        throw ConnectionError.reconnectRequested(connectionID: connectionID)

                    case .protocolError:
                        Self.logger.error(
                            "Protocol error in state \(stateMachine.state, privacy: .public) for \(connectionID, privacy: .public). Closing connection."
                        )
                        throw ConnectionError.unknownResponseType(connectionID: connectionID)
                    }
                }

                // Stream ended (response stream EOF or peer-side close).
                if stateMachine.state == .attestationPending {
                    Self.logger.notice(
                        "Response stream ended for \(connectionID, privacy: .public) before attestation received; cancelling remaining tasks"
                    )
                    group.cancelAll()
                    throw ConnectionError.noAttestationReceived(connectionID: connectionID)
                }

                await self.drainHelperBeforeStreamEnd(activeHelper, connectionID: connectionID)

                Self.logger.notice(
                    "Response stream ended naturally for \(connectionID, privacy: .public) (state=\(stateMachine.state, privacy: .public)); cancelling remaining tasks"
                )
                group.cancelAll()
            }
        } catch {
            // Store cached attestation even on error so the next retry can skip attestation
            if let cached = stateMachine.cachedAttestation {
                sharedCachedAttestation.store(cached)
            }
            // Clean up this stream's helper before rethrowing
            await self.cleanupHelper(activeHelper, address: address, isReplacement: isReplacement)
            throw error
        }

        // Happy path cleanup
        if let cached = stateMachine.cachedAttestation {
            sharedCachedAttestation.store(cached)
        }
        await self.cleanupHelper(activeHelper, address: address, isReplacement: isReplacement)
    }

    // MARK: - Helper cleanup

    /// Triggers a graceful helper teardown after the gRPC response stream
    /// has ended naturally, and waits for the helper process to exit
    /// before the caller proceeds with `group.cancelAll()`.
    ///
    /// Server has closed the gRPC stream (the bridge sent Terminate, the
    /// server replied with EOF). The helper itself does not yet know:
    /// its bidi stream is gone, but cb_pclienthelper does not exit just
    /// because the gRPC stream closed — it waits for an XPC `teardown`
    /// from the bridge.
    ///
    /// If we go straight to `group.cancelAll()`, the launchd-monitor
    /// loop in `helper.run()` is cancelled mid-iteration. AsyncStream
    /// returns `nil` on cancellation rather than throwing, so the
    /// for-loop exits cleanly without ever delivering `.terminated` to
    /// the state machine. `monitoringCompleted` then runs with state
    /// `.connected` and emits the spurious "monitoring stopped before
    /// receiving termination notification" `.error` chain. The helper is
    /// in-flight at this exact moment too — killing it before drain-
    /// complete violates the rule that helpers only die on real
    /// gRPC-channel-loss or drain-signal timeout.
    ///
    /// Instead: signal teardown and wait for the helper to exit on its
    /// own. The existing `awaitTeardownTriggerAndComplete` task in the
    /// group picks up the trigger, runs `stateMachine.teardown()`,
    /// sends `client.teardown()` over XPC. cb_pclienthelper receives
    /// it, exits voluntarily. The XPC peer death fires the
    /// `handleConnectionInvalidated` handler on `PersistentHelperXPCClient`,
    /// which calls `disconnect()` — cancelling the XPC connection and
    /// clearing the delegate. launchd dispatches `.exited`,
    /// `helper.run()` observes `.terminated` and returns cleanly. Only
    /// then does the caller cancel the remaining infrastructure tasks
    /// (keepalive, idle/hard-expiry watchdogs, chunk forwarder).
    private func drainHelperBeforeStreamEnd(
        _ helper: PersistentHelperInstance?,
        connectionID: String
    ) async {
        guard let helper else { return }
        Self.logger.notice(
            "Triggering helper teardown after response stream ended for \(connectionID, privacy: .public)"
        )
        await helper.triggerTeardown()
        do {
            try await helper.waitForExit()
        } catch {
            Self.logger.warning(
                "Helper waitForExit threw during graceful drain for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
            )
        }
    }

    /// Removes a helper instance and notifies the bridge router.
    private func cleanupHelper(
        _ helper: PersistentHelperInstance?,
        address: String,
        isReplacement: Bool
    ) async {
        guard let helper else { return }
        Self.logger.info(
            "Cleaning up helper \(helper.id, privacy: .public) after stream ended for \(address, privacy: .public)"
        )
        await self.helperInstanceProvider.removeInstance(uuid: helper.id)
        self.nodePools.withLock { pools in
            guard pools.isActive(address: address) else {
                Self.logger.info(
                    "Node already removed during helper cleanup for \(address, privacy: .public)"
                )
                return
            }
            if isReplacement {
                if pools.nodes[address]?.replacementHelperID == helper.id {
                    pools.nodes[address]?.replacementHelperID = nil
                }
            } else {
                if pools.nodes[address]?.helperID == helper.id {
                    pools.nodes[address]?.helperID = nil
                }
            }
        }
        await self.bridgeRouterClient.sendHelperRemoved(helperID: helper.id)
    }

    // MARK: - Helper spawning and setup

    /// Creates a helper instance and delegate without blocking.
    private func createHelper(
        attestation: AttestationInfo,
        connectionID: String,
        address: String,
        serviceDefinedMetadata: Data
    ) async throws -> (PersistentHelperInstance, PersistentClientConnectionDelegate) {
        // 1. Create the delegate that bridges helper XPC responses → an AsyncStream
        //    for the chunk-forwarding task to drain.
        let delegate = PersistentClientConnectionDelegate(
            connectionID: connectionID,
            serviceDefinedMetadata: serviceDefinedMetadata
        )

        // 2. Spawn the helper process
        Self.logger.info(
            "Spawning helper for \(connectionID, privacy: .public), keyID=\(attestation.keyID.base64EncodedString(), privacy: .public)"
        )
        let helper = try await self.helperInstanceProvider.createInstance(
            keyID: attestation.keyID,
            delegate: delegate
        )

        // Check if the node was removed while we were spawning.
        // If teardown ran concurrently, the address is gone from
        // nodePools.nodes (or no longer active) and the connection task is
        // cancelled — but this helper is already spawned and untracked.
        // Tear it down immediately to avoid leaking the process.
        let nodeStillExists = self.nodePools.withLock { $0.isActive(address: address) }
        if !nodeStillExists {
            Self.logger.warning(
                "Node \(address, privacy: .public) removed during helper spawn for \(connectionID, privacy: .public). Tearing down orphaned helper \(helper.id, privacy: .public)"
            )
            await self.helperInstanceProvider.removeInstance(uuid: helper.id)
            throw CancellationError()
        }

        Self.logger.info(
            "Helper \(helper.id, privacy: .public) spawned for \(connectionID, privacy: .public)"
        )

        return (helper, delegate)
    }

    /// Waits for the helper's XPC connection, initializes it with the attestation bundle,
    /// exchanges the OHTTP encrypted key, and sends Setup on gRPC.
    private func setupHelper(
        helper: PersistentHelperInstance,
        delegate: PersistentClientConnectionDelegate,
        attestation: AttestationInfo,
        connectionID: String,
        address _: String,
        serviceDefinedMetadata: Data,
        requestStream: GRPCAsyncRequestStreamWriter<PersistentServiceRequest>
    ) async throws {
        // 1. Wait for XPC connection to be established (run() must already be running)
        do {
            try await helper.waitForConnectComplete()
        } catch {
            Self.logger.error(
                "Helper \(helper.id, privacy: .public) failed to connect for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
            )
            await self.helperInstanceProvider.removeInstance(uuid: helper.id)
            throw error
        }

        // 2. Initialize the helper with attestation bundle.
        //    The helper uses the attestation bundle's public key for OHTTP key encapsulation.
        //    It sends back a .responseChunk with the encrypted key BEFORE .initialized.
        do {
            var metadataQuery = Com_Apple_Cloudboard_Privatefilter_V1_MetadataQuery()
            metadataQuery.subscriberID = connectionID
            let subscriptionPayload: Data = try metadataQuery.serializedBytes()

            try await helper.initializeClient(PersistentClientHelperInitParams(
                keyID: attestation.keyID,
                attestationBundle: attestation.bundle,
                serviceDefinedMetadata: serviceDefinedMetadata,
                metadataSubscriptionPayload: subscriptionPayload
            ))
        } catch {
            Self.logger.error(
                "Helper \(helper.id, privacy: .public) initialization failed for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
            )
            await self.helperInstanceProvider.removeInstance(uuid: helper.id)
            throw error
        }

        // 3. Wait for the helper to signal initialization via the encrypted key.
        let encryptedKey: Data
        do {
            encryptedKey = try await delegate.waitForEncryptedKey()
        } catch {
            Self.logger.error(
                "Helper \(helper.id, privacy: .public) OHTTP setup failed for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
            )
            await self.helperInstanceProvider.removeInstance(uuid: helper.id)
            throw error
        }

        // 4. Send Setup on gRPC with the encrypted OHTTP key
        Self.logger.info(
            "Sending Setup for \(connectionID, privacy: .public), encryptedKey=\(encryptedKey.count, privacy: .public) bytes"
        )

        var setupMsg = PersistentServiceRequest.Setup()
        setupMsg.decryptionKey.keyID = attestation.keyID
        setupMsg.decryptionKey.encryptedPayload = encryptedKey
        var request = PersistentServiceRequest()
        request.type = .setup(setupMsg)
        do {
            try await requestStream.send(request)
        } catch {
            Self.logger.error(
                "Failed to send Setup on gRPC for \(connectionID, privacy: .public): \(String(unredacted: error), privacy: .public)"
            )
            await self.helperInstanceProvider.removeInstance(uuid: helper.id)
            throw error
        }

        Self.logger.info(
            "Setup sent for \(connectionID, privacy: .public), waiting for SetupAck"
        )
    }

    /// Adds helper lifecycle tasks to a task group: `run()`, teardown, and setup (XPC + OHTTP + gRPC).
    /// The chunk-forwarding task is NOT started here — it is added by the response pump
    /// after SetupAck is received, ensuring no chunks are sent before Setup.
    private func startHelper(
        helper: PersistentHelperInstance,
        delegate: PersistentClientConnectionDelegate,
        attestation: AttestationInfo,
        connectionID: String,
        address: String,
        serviceDefinedMetadata: Data,
        requestStream: GRPCAsyncRequestStreamWriter<PersistentServiceRequest>,
        group: inout ThrowingDiscardingTaskGroup<Error>
    ) throws {
        group.addTask {
            do {
                try await helper.run()
            } catch {
                await helper.triggerTeardown(error: error)
                throw error
            }
            await helper.triggerTeardown()
        }
        group.addTask {
            await helper.awaitTeardownTriggerAndComplete()
        }
        group.addTask {
            try await self.setupHelper(
                helper: helper,
                delegate: delegate,
                attestation: attestation,
                connectionID: connectionID,
                address: address,
                serviceDefinedMetadata: serviceDefinedMetadata,
                requestStream: requestStream
            )
            await self.bridgeRouterClient.sendHelperAttestationReceived(
                helperID: helper.id,
                keyID: attestation.keyID,
                attestationBundle: attestation.bundle,
                serviceDefinedMetadata: serviceDefinedMetadata,
                expiresAfter: attestation.hardExpiry
            )
        }
    }

    /// Runs a self-contained replacement stream in parallel with the primary stream.
    ///
    /// Opens a new gRPC channel and stream, spawns a new helper, performs OHTTP setup,
    /// and runs its own response pump. When the replacement stream's `SetupAck` is received,
    /// the new helper becomes the active one for this node. The primary stream continues
    /// draining (server closes it when ready).
    ///
    /// This method is called at most once per `runNodeConnection` invocation, enforcing
    /// the 2-stream limit via the `replacementPending` state.
    /// Tears down all managed nodes. Called during daemon shutdown.
    func teardownAllNodes() async {
        let activeNodes = self.nodePools.withLock { pools -> [ManagedNode] in
            let active = pools.nodes.values.filter { $0.isActive }
            pools.nodes.removeAll()
            pools.byUnit.removeAll()
            return Array(active)
        }

        for node in activeNodes {
            node.connectionTask?.cancel()
        }

        // Also tear down all helper instances
        await self.helperInstanceProvider.teardownAllInstances()
    }

    // MARK: - Metrics helpers

    /// Number of distinct ManagedNodes currently active (i.e. driving a
    /// connection task). Multi-unit nodes count once even though they
    /// hold a slot in many unit pools — matching the historical
    /// "connection count" semantics this property exposed before per-
    /// unit accounting existed.
    var activeNodeCount: Int {
        self.nodePools.withLock { pools in
            pools.nodes.values.reduce(0) { $0 + ($1.isActive ? 1 : 0) }
        }
    }

    /// Test seam: the active-pool addresses for one unit. Per-unit by
    /// design — cap enforcement and spare bookkeeping are per-unit, so
    /// tests should be too.
    internal func activeAddresses(in unitID: PersistentServiceUnitID) -> Set<String> {
        self.nodePools.withLock { pools in
            pools.byUnit[unitID]?.activeAddresses ?? []
        }
    }

    /// Test seam: the spare-pool addresses for one unit.
    internal func spareAddresses(in unitID: PersistentServiceUnitID) -> Set<String> {
        self.nodePools.withLock { pools in
            pools.byUnit[unitID]?.spareAddresses ?? []
        }
    }

    /// Test seam: the units a given address is a member of.
    internal func unitsForAddress(_ address: String) -> Set<PersistentServiceUnitID> {
        self.nodePools.withLock { pools in
            pools.nodes[address]?.units ?? []
        }
    }

    /// Test seam: read the publisher-declared transport security
    /// stored on a node, parsed at SD ingest time. Returns `nil` when
    /// no node tracks `address` (e.g. it was rejected by the policy
    /// gate or never announced).
    internal func transportSecurity(for address: String) -> PersistentServiceTransportSecurity? {
        self.nodePools.withLock { pools in
            pools.nodes[address]?.transportSecurity
        }
    }

    /// Test seam: simulates the per-node retry filter deciding that a
    /// swap should happen and the connection task subsequently exiting.
    /// Test seam: simulate a swap-eligible failure. Aligns the node's
    /// `consecutiveFailureCount` with the configured swap threshold so a
    /// single call exercises the same `swapToSpareIfPossible` path the
    /// real Nth failure would, then invokes it. Pre-conditions (per-unit
    /// cap configured for the service, spare available in some unit the
    /// node covers) still apply.
    internal func simulateEarlyFailure(address: String) async {
        let serviceName = self.nodePools.withLock { pools -> String? in
            guard var node = pools.nodes[address], node.isActive else { return nil }
            guard self.maxServersPerUnit?[node.serviceName] != nil else { return nil }
            let hasSparesInSomeUnit = node.units.contains { unitID in
                !(pools.byUnit[unitID]?.spareAddresses.isEmpty ?? true)
            }
            guard hasSparesInSomeUnit else { return nil }
            // Match the production predicate: count >= threshold. The
            // retry filter would have incremented just before signalling;
            // the seam bumps the counter to the threshold so the swap
            // fires on this single call.
            let threshold = self.swapOnFailureThreshold[node.serviceName]
                ?? Self.defaultSwapOnFailureThreshold
            node.consecutiveFailureCount = max(node.consecutiveFailureCount, threshold)
            pools.nodes[address] = node
            return node.serviceName
        }
        guard let serviceName else { return }
        await self.swapToSpareIfPossible(failedAddress: address, serviceName: serviceName)
    }

    /// Test seam: simulates the post-`setupComplete` reset that a
    /// real healthy run performs — clears `consecutiveFailureCount` and
    /// `reconnectNotBefore` without driving the gRPC state machine.
    internal func markHealthyForTesting(address: String) {
        self.nodePools.withLock { pools in
            pools.nodes[address]?.consecutiveFailureCount = 0
            pools.nodes[address]?.reconnectNotBefore = nil
        }
    }

    /// Test seam: pre-populates `helperID` and `replacementHelperID` on a
    /// node so swap-path tests can assert that a demote forwards them
    /// to `sendHelperRemoved`. Real production sets these via
    /// `runStream`'s `updateActiveNode`.
    internal func setHelperIDsForTesting(
        address: String,
        primary: UUID?,
        replacement: UUID?
    ) {
        self.nodePools.withLock { pools in
            pools.nodes[address]?.helperID = primary
            pools.nodes[address]?.replacementHelperID = replacement
        }
    }

    /// Test seam: directly set a node's `consecutiveFailureCount`. Used by
    /// tests that need to drive the swap predicate without burning real
    /// retry-loop iterations.
    internal func setConsecutiveFailureCount(address: String, to count: Int) {
        self.nodePools.withLock { pools in
            pools.nodes[address]?.consecutiveFailureCount = count
        }
    }

    /// Test seam: read the consecutive-failure counter for a node.
    internal func consecutiveFailureCount(for address: String) -> Int? {
        self.nodePools.withLock { pools in
            pools.nodes[address]?.consecutiveFailureCount
        }
    }

    /// Test seam: read the earliest absolute time at which a node may
    /// begin its next connection attempt. `nil` for fresh and healthy
    /// nodes (no constraint); a future instant for nodes recently
    /// demoted via the swap path.
    internal func reconnectNotBefore(for address: String) -> ContinuousClock.Instant? {
        self.nodePools.withLock { pools in
            pools.nodes[address]?.reconnectNotBefore ?? nil
        }
    }

    /// Test seam: directly set a node's `reconnectNotBefore`. Used by
    /// tests that need to set up a "still cooling off" or "ready" spare
    /// without driving the swap path.
    internal func setReconnectNotBefore(address: String, to instant: ContinuousClock.Instant?) {
        self.nodePools.withLock { pools in
            pools.nodes[address]?.reconnectNotBefore = instant
        }
    }

    /// Test seam: read a node's `shouldSwapOnExit` flag. The retry filter
    /// sets this when it decides the connection task should exit so a
    /// spare can be promoted; the terminal cleanup consumes it.
    internal func shouldSwapOnExit(for address: String) -> Bool? {
        self.nodePools.withLock { pools in
            pools.nodes[address]?.shouldSwapOnExit
        }
    }

    /// Test seam: the set of distinct shard configurations the manager
    /// has tracked for `capability`. Empty if the capability is unknown.
    internal func configurationsForCapability(_ capability: String) -> Set<Set<PersistentServiceUnitID>> {
        self.nodePools.withLock { pools in
            pools.byCapability[capability]?.configurations ?? []
        }
    }

    /// Test seam: whether the capability has at least one fully-covered
    /// configuration right now.
    internal func isCapabilityCovered(_ capability: String) -> Bool {
        self.nodePools.withLock { pools in
            pools.isCapabilityCovered(capability)
        }
    }

    /// Test seam: number of complete served replicas of `capability`.
    /// Mirrors the value emitted by `CapabilityCoverageGauge`.
    internal func capabilityReplicaDepth(_ capability: String) -> Int {
        self.nodePools.withLock { pools in
            pools.capabilityReplicaDepth(capability)
        }
    }

    /// Emit per-unit gauges for the current state of the pools. Called
    /// after each reconciliation pass so operators have continuous
    /// visibility into "is this unit at cap, below cap, has spares" and
    /// "how many complete replicas is this capability served by". Units and
    /// capabilities that dropped out of the pools since the previous pass are
    /// re-emitted as `0` so a vanished series doesn't keep its last non-zero
    /// value forever (reconciliation removes the stale entry from the pools
    /// and then calls this in the same pass, so the zero is emitted promptly).
    private func emitPerUnitGauges() {
        struct CapabilitySnapshot {
            let capability: String
            let replicaDepth: Int
            let configurationCount: Int
        }
        let (units, capabilities) = self.nodePools.withLock { pools -> (
            [(PersistentServiceUnitID, Int, Int)], [CapabilitySnapshot]
        ) in
            let unitTuples: [(PersistentServiceUnitID, Int, Int)] = pools.byUnit.map { id, view in
                (id, view.activeAddresses.count, view.spareAddresses.count)
            }
            let capabilitySnapshots: [CapabilitySnapshot] = pools.byCapability.map { capability, tracking in
                CapabilitySnapshot(
                    capability: capability,
                    replicaDepth: pools.capabilityReplicaDepth(capability),
                    configurationCount: tracking.configurations.count
                )
            }
            return (unitTuples, capabilitySnapshots)
        }
        for (unitID, active, spare) in units {
            let dimensions = Self.unitDimensions(for: unitID)
            self.metricsSystem.emit(
                Metrics.PersistentClientHelper.ActiveNodesPerUnitGauge(
                    dimensions: dimensions,
                    value: active
                )
            )
            self.metricsSystem.emit(
                Metrics.PersistentClientHelper.SpareNodesPerUnitGauge(
                    dimensions: dimensions,
                    value: spare
                )
            )
        }
        for snapshot in capabilities {
            let dimensions: MetricDimensions<Metrics.PersistentClientHelper.CapabilityDimensionKeys> = [
                .capability: snapshot.capability,
            ]
            self.metricsSystem.emit(
                Metrics.PersistentClientHelper.CapabilityCoverageGauge(
                    dimensions: dimensions,
                    value: snapshot.replicaDepth
                )
            )
            self.metricsSystem.emit(
                Metrics.PersistentClientHelper.CapabilityShardConfigurationsGauge(
                    dimensions: dimensions,
                    value: snapshot.configurationCount
                )
            )
        }

        // Zero out units/capabilities that were emitted last pass but are gone
        // now, so a removed series reads as 0 instead of staying stuck at its
        // last non-zero value. Computed atomically against the previous pass's
        // key set under the lock (concurrent passes for different services
        // never strand a non-zero value — whichever pass updates the set first
        // emits the zero, and at worst a redundant 0 is emitted).
        let currentUnits = Set(units.map { $0.0 })
        let currentCapabilities = Set(capabilities.map { $0.capability })
        let (vanishedUnits, vanishedCapabilities) = self.lastEmittedPerUnitKeys
            .withLock { previous -> (Set<PersistentServiceUnitID>, Set<String>) in
                let goneUnits = previous.units.subtracting(currentUnits)
                let goneCapabilities = previous.capabilities.subtracting(currentCapabilities)
                previous.units = currentUnits
                previous.capabilities = currentCapabilities
                return (goneUnits, goneCapabilities)
            }
        for unitID in vanishedUnits {
            let dimensions = Self.unitDimensions(for: unitID)
            self.metricsSystem.emit(
                Metrics.PersistentClientHelper.ActiveNodesPerUnitGauge(dimensions: dimensions, value: 0)
            )
            self.metricsSystem.emit(
                Metrics.PersistentClientHelper.SpareNodesPerUnitGauge(dimensions: dimensions, value: 0)
            )
        }
        for capability in vanishedCapabilities {
            let dimensions: MetricDimensions<Metrics.PersistentClientHelper.CapabilityDimensionKeys> = [
                .capability: capability,
            ]
            self.metricsSystem.emit(
                Metrics.PersistentClientHelper.CapabilityCoverageGauge(dimensions: dimensions, value: 0)
            )
            self.metricsSystem.emit(
                Metrics.PersistentClientHelper.CapabilityShardConfigurationsGauge(dimensions: dimensions, value: 0)
            )
        }
    }

    /// Decompose a unit into the `(capability, shardID)` metric dimensions
    /// for the per-unit gauges.
    static func unitDimensions(
        for unitID: PersistentServiceUnitID
    ) -> MetricDimensions<Metrics.PersistentClientHelper.UnitDimensionKeys> {
        [.capability: unitID.capability, .shardID: unitID.shardID]
    }
}

/// Payload yielded to `runNodeConnection`'s stream coordinator to spawn the
/// next stream. Carries the attestation to seed the stream with, and — for a
/// replacement spawned by a rotating old stream — a one-shot continuation the
/// replacement fires once it reaches `sendHelperReady`. The old stream awaits
/// the matching signal and keeps serving until the replacement is routable
/// before it begins draining (make-before-break at the routing layer).
struct StreamSpawn: Sendable {
    let attestation: PersistentClientHelperManager.AttestationInfo?
    let readyContinuation: AsyncStream<Void>.Continuation?
}

/// One-shot latch: the first `claim()` returns true; every later call returns
/// false. Ensures a rotating stream's retirement (sendHelperDraining → drain →
/// Terminate) is driven by exactly one trigger — replacement-ready, the
/// readiness-wait backstop, or a server-initiated drain — even when they race.
/// Internal (not private) so unit tests can exercise the exactly-once contract.
final class OneShotLatch: Sendable {
    private let claimed: Mutex<Bool>

    init() {
        self.claimed = Mutex(false)
    }

    /// Returns true to the first caller only.
    func claim() -> Bool {
        self.claimed.withLock { claimed in
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Thread-safe cache for passing a cached attestation between the primary and
/// replacement streams. Uses a class wrapper because `Mutex` is non-copyable
/// and cannot be captured directly by async closures.
internal final class SharedAttestationCache: Sendable {
    private let value: Mutex<PersistentClientHelperManager.AttestationInfo?>

    init() {
        self.value = Mutex(nil)
    }

    func store(_ attestation: PersistentClientHelperManager.AttestationInfo?) {
        self.value.withLock { $0 = attestation }
    }

    func load() -> PersistentClientHelperManager.AttestationInfo? {
        self.value.withLock { $0 }
    }
}

/// Thread-safe counter for tracking the number of active gRPC streams.
/// Each stream task decrements on exit so the coordinator always sees the
/// true count, even if `next()` hasn't been called yet.
private final class ActiveStreamCounter: Sendable {
    private let value: Mutex<Int>

    init() {
        self.value = Mutex(0)
    }

    var count: Int {
        self.value.withLock { $0 }
    }

    func increment() {
        self.value.withLock { $0 += 1 }
    }

    func decrement() {
        self.value.withLock { $0 -= 1 }
    }
}

/// Thread-safe tracker for the last time activity was observed on a connection.
/// Used by the idle timeout watchdog to detect stale connections.
private final class LastActivity: Sendable {
    private let timestamp: Mutex<ContinuousClock.Instant>

    init() {
        self.timestamp = Mutex(.now)
    }

    func recordActivity() {
        self.timestamp.withLock { $0 = .now }
    }

    var elapsed: Duration {
        ContinuousClock.now - self.timestamp.withLock { $0 }
    }
}
