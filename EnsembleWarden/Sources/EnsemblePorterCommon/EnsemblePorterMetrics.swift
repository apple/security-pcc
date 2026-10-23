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
//  EnsemblePorterMetrics.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 2025-10-14.
//

@_spi(OSMetric) package import os
private import Synchronization

fileprivate let group = OSMetricGroup(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "Metrics")

/// Metric labels for EnsemblePorter.
///
/// ### Phase 1: Prewarm Phase
/// **Initiated by**: CloudBoard calls `prewarm()` on leader
/// **Purpose**: Start EnsemblePorter on all the followers (process startup is slow) and establishes
/// a key pair with each.
///
/// ```
/// CloudBoard → Leader → Controller → Followers
///     ↓         ↓         ↓          ↓
///  prewarm()   start    spawn    generate
///              followers processes keypairs
/// ```
///
/// **Flow**:
/// 1. CloudBoard calls `prewarm()` on leader
/// 2. Leader contacts each follower's EnsemblePorterController via ensembled transport
/// 3. Controller spawns new follower porter processes via launchd
/// 4. Each follower generates a keypair and returns public key to leader
/// 5. Leader stores follower info (rank, instanceUUID, publicKey) for request phase
///
/// ### Phase 2: Request Phase
/// **Initiated by**: CloudBoard calls `provide()` with cryptographic material
/// **Purpose**: Securely distribute keys to all ensemble members
///
/// ```
/// CloudBoard → Leader → [Encrypt with each follower's pubkey] → Followers
///     ↓         ↓              ↓                                    ↓
///  provide()   receive      parallel distribution              decrypt &
///           turn keys     via ensembled transport             store keys
/// ```
///
/// **Flow**:
/// 1. CloudBoard provides unencrypted turn keys to leader
/// 2. Leader validates the raw cryptographic material
/// 3. Leader encrypts keys individually for each follower using their public key
/// 4. Leader sends encrypted keys in parallel to all followers via ensembled
/// 5. Each follower decrypts using their private key and stores locally
/// 6. All nodes can now serve `fetch()` requests for individual turn keys
///
package enum EnsemblePorterMetricLabel: String, CaseIterable, Sendable {

    // MARK: - PREWARM PHASE METRICS

    /// Tracks number of ensembleporter processes started. Remember that there is per-request
    /// recycling of proccesses.
    ///
    /// **Phase**: Prewarm
    /// **When Incremented**: Every time we start a ensembleporter process
    case processStartCount = "ensembleporter_process_start_count"

    /// Tracks different message types processed by the EnsemblePorterController daemon.
    ///
    /// **Phase**: Prewarm (startNewProcess) & Request (perProcessMessage, shutdown)
    /// **Operation**: Controller processing inter-process coordination messages from leader
    /// **When Incremented**: Each message received and processed by controller, by type
    /// **Dimensions**: `type` ("start_new_process", "per_process_message", "shutdown")
    case controllerMessageCount = "ensembleporter_controller_message_count"

    /// Measures latency for prewarm operations. This involves starting ensembleporter on every follower and
    /// performing a key exchange with them all.
    ///
    /// **Phase**: Prewarm
    /// **Operation**: Complete prewarm from CloudBoard call to all followers ready
    /// **When Recorded**: From start of `prewarmFollowers()` call to completion
    case prewarmRequestDurationSeconds = "ensembleporter_prewarm_request_duration_seconds"

    // MARK: - REQUEST PHASE METRICS

    /// Measures latency for the distribution phase of cryptographic material to all followers.
    ///
    /// **Phase**: Request
    /// **Operation**: Leader distributing encrypted keys to all follower nodes via ensembled transport
    /// **When Recorded**: From start of distribution phase to completion (all followers processed)
    case distributionRequestDurationSeconds = "ensembleporter_distribution_request_duration_seconds"

    /// Number of times we've been provisioned with keys.
    ///
    /// **Phase**: Request
    /// **Operation**: Storing cryptographic material in the KeySafe after validation
    /// **When Incremented**: Each key provision attempt in `KeySafe.supply()` method
    /// **Dimensions**: `result` ("success"/"failure"), `error` (detailed error type from EnsemblePorterError)
    case keyProvisionCount = "ensembleporter_key_provision_count"

    /// Tracks cryptographic material distribution from leader to all follower ensemble members.
    ///
    /// **Phase**: Request
    /// **Operation**: Leader distributing encrypted keys to all follower nodes via ensembled
    /// **When Incremented**: After each complete distribution cycle (all followers or failure)
    /// **Dimensions**: `result` ("success"/"failure")
    case distributionAttemptsCount = "ensembleporter_distribution_attempts_count"

    /// Measures latency for key retrieval operations.
    ///
    /// **Phase**: Request (post-distribution)
    /// **Operation**: Complete fetch request from client call to key return
    /// **When Recorded**: From start of `fetch()` call to successful key retrieval
    /// **System Context**: Should be consistently low (sub-millisecond) as it's a local KeySafe
    /// lookup after distribution is complete. High latencies indicate KeySafe contention or issues.
    case fetchRequestDurationSeconds = "ensembleporter_fetch_request_duration_seconds"

    /// Tracks individual key retrieval operations.
    ///
    /// **Phase**: Request (post-distribution)
    /// **Operation**: Retrieving specific keys by turn number from local KeySafe storage
    /// **When Incremented**: Each key retrieval attempt in `KeySafe.retrieveKey()` method
    /// **Dimensions**: `result` ("success"/"failure"), `error` (detailed error type from EnsemblePorterError)
    /// **System Context**: Storage layer metric, more granular than `fetchAttemptsCount`.
    /// Tracks KeySafe state validation and turn number bounds checking.
    case keyFetchCount = "ensembleporter_key_fetch_count"

    /// Current count of cryptographic keys stored and available for retrieval.
    ///
    /// **Phase**: Request (state tracking)
    /// **Operation**: KeySafe state monitoring showing current ensemble capacity (gauge metric)
    /// **When Updated**: After successful key provisioning in `KeySafe.supply()` method
    case turnKeysStoredCount = "ensembleporter_turn_keys_stored_count"

    // MARK: - CROSS-PHASE METRICS

    /// Number of XPC calls
    ///
    /// **Phase**: Both (client communication throughout)
    /// **Operation**: XPC message handling, connection management, and serialization operations
    /// **When Incremented**: Each XPC-related error in transport layer operations
    /// **Dimensions**: `result` (always "failure"), `error` (detailed error type from EnsemblePorterError)
    /// **System Context**: Client communication issues including entitlement failures, connection
    /// drops, serialization errors. Affects both prewarm coordination and request operations.
    case xpcCount = "ensembleporter_xpc_count"

    /// Tracks malformed or unexpected messages received by the controller.
    ///
    /// **Phase**: Both (message validation throughout)
    /// **Operation**: Controller rejecting invalid message content, format, or protocol violations
    /// **When Incremented**: Each message that fails protobuf parsing, validation, or routing
    /// **System Context**: Should be extremely rare. High counts indicate protocol bugs,
    /// network corruption, or version mismatches between ensemble components.
    case controllerInvalidMessagesCount = "ensembleporter_controller_invalid_messages_count"

    // MARK: - HEARTBEAT METRICS

    /// Measures round-trip latency for heartbeat sends from leader to follower.
    ///
    /// **Phase**: Both (continuous during request lifetime)
    /// **When Recorded**: After each heartbeat send attempt, measuring time from send to response/failure
    /// **Dimensions**: `result` ("success"/"failure"), `rank` (destination follower rank as a string),
    ///                 `consecutive_failures` ("0" on success; "1".."4", "5+" on failure — the streak
    ///                 length *including* the current attempt). Lets dashboards distinguish a single
    ///                 transient blip from a sustained streak approaching the `EX_UNAVAILABLE` cutoff.
    case heartbeatRoundTripDurationSeconds = "ensembleporter_heartbeat_round_trip_duration_seconds"

    /// Per-follower send latency: how long each individual key send to a follower takes.
    ///
    /// **Phase**: Request
    /// **When Recorded**: Around `intraEnsembleTransponder.sendData` per follower
    /// **Dimensions**: `rank` (destination follower rank), `result` ("success"/"failure")
    case followerSendDurationSeconds = "ensembleporter_follower_send_duration_seconds"

    /// Tracks instance removals on the controller, with a reason dimension.
    ///
    /// **Phase**: Both
    /// **When Incremented**: Each time an instance is removed from the controller
    /// **Dimensions**: `reason` ("shutdown" for leader-initiated, "heartbeat_timeout" for heartbeat expiry,
    ///                          "process_crash" for process no longer running at heartbeat time,
    ///                          "orphan" for a launchd-running instance the controller had no record of)
    case instanceRemovedCount = "ensembleporter_instance_removed_count"

    /// Per-step latency for the leader↔follower ECDH key exchange during prewarm.
    ///
    /// **Phase**: Prewarm
    /// **When Recorded**: Around each individually-instrumented step of `negotiateFollowerPorter()`
    /// **Dimensions**: `rank` (destination follower rank), `step` ("send_start"|"key_agreement"|"hkdf"),
    ///                 `result` ("success"/"failure")
    case ecdhExchangeDurationSeconds = "ensembleporter_ecdh_exchange_seconds"

    /// Tracks entitlement validation outcomes on the porter XPC server.
    ///
    /// **Phase**: Both
    /// **When Incremented**: Once per `validate(entitlement:)` call (success or thrown failure)
    /// **Dimensions**: `entitlement` (the entitlement string), `result` ("success"/"failure"),
    ///                 `failure_type` ("none"|"sec_task"|"sec_task_copy_error"|"missing_or_wrong_value")
    case entitlementValidationCount = "ensembleporter_entitlement_validation_count"

    /// Latency for porter XPC server-side request handling, with operation + result dims.
    ///
    /// **Phase**: Both
    /// **When Recorded**: From handler entry to response, per operation
    /// **Dimensions**: `operation` (RPC name), `result` ("success"/"failure"),
    ///                 `error_category` (low-cardinality classification or `none`)
    case xpcRequestDurationSeconds = "ensembleporter_xpc_request_duration_seconds"

    /// Latency for porter framework client-side calls, with operation + result dims.
    ///
    /// **Phase**: Both
    /// **When Recorded**: Around each client framework method, end-to-end including XPC
    /// **Dimensions**: `operation`, `result`, `error_category`
    case clientCallDurationSeconds = "ensembleporter_client_call_duration_seconds"

    /// Tracks `fatalError` invocations in `KeySafe`.
    ///
    /// **Phase**: Both
    /// **When Incremented**: Immediately before the fatalError so the crash is explainable
    /// **Dimensions**: `reason`
    case keysafeFatalErrorCount = "ensembleporter_keysafe_fatal_error_count"

    /// Tracks heartbeat-driven adoption of launchd-running instances the controller had
    /// no record of (recovery path after a controller restart mid-request).
    ///
    /// **Phase**: Both
    /// **When Incremented**: Each time the heartbeat handler adopts an unknown UUID
    case instanceAdoptedCount = "ensembleporter_instance_adopted_count"

    /// Tracks failures to query the launchd-running instance set during heartbeat-timeout reaping.
    ///
    /// **Phase**: Both
    /// **When Incremented**: Each time `removeTimedOutInstances` fails to enumerate running instances
    case runningInstancesQueryFailureCount = "ensembleporter_running_instances_query_failure_count"

    /// Tracks `exit(EX_UNAVAILABLE)` invocations from the porter heartbeat loop.
    ///
    /// **Phase**: Both (continuous during request lifetime)
    /// **When Incremented**: Immediately before `exit(EX_UNAVAILABLE)` so the termination
    ///                       is explainable in the metrics pipeline even when stderr/logs
    ///                       are lost.
    /// **Dimensions**: `reason` ("instance_not_found", "max_consecutive_failures").
    ///                 The platform adds host/rank dimensions automatically.
    /// **System Context**: ALARM. Every increment ends the per-request porter process and
    /// hands control back to CloudBoard. Persistently non-zero rates indicate a failing
    /// follower or controller, not a transient hiccup.
    case heartbeatExitCount = "ensembleporter_heartbeat_exit_count"

    // MARK: - CONTROLLER GAUGE METRICS

    /// Current number of active porter jobs managed by the controller.
    ///
    /// **Phase**: Both (continuous monitoring)
    /// **Operation**: Controller polling launchd for running porter instances
    /// **When Updated**: Every second by the controller's polling loop
    /// **System Context**: Helps detect porter leaks and capacity issues.
    case controllerActiveJobsCount = "ensembleporter_controller_active_jobs_count"

    /// Tracks how often the controller's max-porter cap was hit, forcing eviction of the oldest
    /// porter instance.
    ///
    /// **Phase**: Both
    /// **When Incremented**: Each time `cleanupStaleInstances` finds running.count ≥ maxInstances
    /// **System Context**: ALARM. Hitting the cap evicts a live porter and can crash a concurrent
    /// leader's request. Should be 0 in healthy operation. Any non-zero rate indicates either a
    /// porter leak on the follower or excessive concurrency from leaders.
    case controllerMaxPortersReachedCount = "ensembleporter_controller_max_porters_reached_count"

    /// Tracks the round-trip duration of shutdown sends made to follower porters as part of
    /// heartbeat-failure handling (when one follower stops responding, we proactively shut down
    /// the other followers' porters so their controllerds free the slots immediately rather
    /// than waiting on the heartbeat-timeout watchdog).
    ///
    /// **Phase**: Both (during heartbeat)
    /// **When Recorded**: After each best-effort shutdown send completes (success or failure)
    /// after the leader detected heartbeat failure on a different follower.
    /// **Dimensions**: `result` ("success"/"failure")
    case heartbeatFailureShutdownDurationSeconds = "ensembleporter_heartbeat_failure_shutdown_duration_seconds"

    /// Counts each leader-side aggregate shutdown-followers operation, broken out by why
    /// it ran. Pairs with `shutdownFollowersDurationSeconds`.
    ///
    /// **Phase**: Both
    /// **When Incremented**: Once per `teardownFollowers()` call that actually issues
    /// shutdowns to followers, and once per `shutdownOtherFollowers(...)` call.
    /// **Dimensions**: `phase` ("request_complete" — teardown after a real request,
    ///                          "pre_request" — teardown of an unused prewarm-pool member or
    ///                                          an iOS-cancellation-before-Parameters,
    ///                          "heartbeat_failure" — best-effort sibling shutdown when our
    ///                                                heartbeat to one follower failed),
    ///                 `result` ("success"/"failure"),
    ///                 `error_category` (`String(reportable:)` of the failing error —
    ///                                   `publicDescription` for `ReportableError` types,
    ///                                   the error type name otherwise. Omitted on success.)
    /// **System Context**: `phase=pre_request` rate is the canary for client-cancellation-
    /// driven cascades; sustained spikes correlate with downstream cap-firing storms.
    case shutdownFollowersCount = "ensembleporter_shutdown_followers_count"

    /// Wall-clock duration of an aggregate shutdown-followers operation, end-to-end.
    /// Pairs with `shutdownFollowersCount`.
    ///
    /// **Phase**: Both
    /// **When Recorded**: After `shutdownAllFollowers()` (or `shutdownOtherFollowers`) returns,
    /// success or failure.
    /// **Dimensions**: `phase` (same values as `shutdownFollowersCount`),
    ///                 `result` ("success"/"failure")
    case shutdownFollowersDurationSeconds = "ensembleporter_shutdown_followers_duration_seconds"
}

/// Gauge that tracks a current value and maintains an internal copy for testing.
package final class EnsemblePorterGauge: Sendable {
    private let gauge: OSMetricGauge<Int64>
    private let internalValue: Mutex<Int64> = .init(0)

    package init(label: String, extraDimensions: OSMetricDimensions = [:]) {
        self.gauge = OSMetricGauge(
            type: Int64.self, group: group, label: label, extraDimensions: extraDimensions)
    }

    package func set(_ value: Int64) {
        self.gauge.set(value)
        self.internalValue.withLock { $0 = value }
    }

    package var value: Int64 {
        self.internalValue.withLock { $0 }
    }
}

/// Counter that tracks metrics and maintains an internal count for testing.
package final class EnsemblePorterCounter: Sendable {
    private let counter: OSMetricCounter<Int64>
    private let internalValue: Mutex<Int64> = .init(0)

    package init(label: String, extraDimensions: OSMetricDimensions = [:]) {
        self.counter = OSMetricCounter(type: Int64.self, group: group, label: label, extraDimensions: extraDimensions)
    }

    package func increment() {
        self.counter.increment()
        self.internalValue.withLock { $0 += 1 }
    }

    package var value: Int64 {
        self.internalValue.withLock { $0 }
    }
}

/// Histogram wrapper that emits to OSMetricHistogram and tracks sample count + last value
/// for tests. The underlying OSMetricHistogram has no read API, so we shadow the state in
/// a `Mutex` here; this is the same pattern used by `EnsemblePorterCounter` / `EnsemblePorterGauge`.
package final class EnsemblePorterHistogram: Sendable {
    private struct State {
        var sampleCount: Int = 0
        var lastValue: Double? = nil
    }
    private let histogram: OSMetricHistogram<Double>
    private let internalState: Mutex<State> = .init(State())

    package init(label: String,
                 extraDimensions: OSMetricDimensions = [:]) {
        self.histogram = OSMetricHistogram(
            type: Double.self,
            group: group,
            label: label,
            extraDimensions: extraDimensions,
            bins: .interval(count: 25, interval: 2))
    }

    package func setUnit(to unit: OSMetricUnit) {
        self.histogram.setUnit(to: unit)
    }

    package func setScale(to scale: OSMetricScale) {
        self.histogram.setScale(to: scale)
    }

    package func set(_ value: Double) {
        self.histogram.set(value)
        self.internalState.withLock {
            $0.sampleCount += 1
            $0.lastValue = value
        }
    }

    /// Number of `set(_:)` calls observed. Useful in tests.
    package var sampleCount: Int {
        self.internalState.withLock { $0.sampleCount }
    }

    /// Most recently recorded value, or nil if `set(_:)` has not been called.
    package var lastValue: Double? {
        self.internalState.withLock { $0.lastValue }
    }
}

/// All the metrics for ensemble porter.
package final class EnsemblePorterMetrics: Sendable {

    /// Tracks process initialization events.
    package let processStarts = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.processStartCount.rawValue)

    /// Records the outcome of a controller-driven instance creation. Emits to
    /// `ensembleporter_process_start_count` with `result=success|failure` dimension.
    package func recordInstanceCreation(success: Bool) {
        getCounter(metric: .processStartCount, result: success ? "success" : "failure").increment()
    }

    /// Current count of turn keys stored in the KeySafe after supply.
    package let turnKeysStored = OSMetricGauge(type: Int64.self,
                                               group: group,
                                               label: EnsemblePorterMetricLabel.turnKeysStoredCount.rawValue)

    /// Latency distribution for prewarm operations from start to completion.
    package let prewarmRequestDuration = OSMetricHistogram(type: Double.self,
                                                           group: group,
                                                           label: EnsemblePorterMetricLabel.prewarmRequestDurationSeconds.rawValue,
                                                           bins: .interval(count: 25, interval: 2))

    /// Latency distribution for fetch operations from start to completion.
    package let fetchRequestDuration = OSMetricHistogram(type: Double.self,
                                                         group: group,
                                                         label: EnsemblePorterMetricLabel.fetchRequestDurationSeconds.rawValue,
                                                         bins: .interval(count: 25, interval: 2))

    /// Latency distribution for distribution operations from start to completion.
    package let distributionRequestDuration = OSMetricHistogram(type: Double.self,
                                                                group: group,
                                                                label: EnsemblePorterMetricLabel.distributionRequestDurationSeconds.rawValue,
                                                                bins: .interval(count: 25, interval: 2))


    // MARK: Distribution metrics
    /// Records the outcome of a complete distribution cycle. Emits to
    /// `ensembleporter_distribution_attempts_count` with `result=success|failure`.
    package func recordDistributionAttempt(success: Bool) {
        getCounter(metric: .distributionAttemptsCount, result: success ? "success" : "failure").increment()
    }

    // MARK: Controller message type metrics
    /// Count of startNewProcess message requests received by controller.
    package let startNewProcessRequests = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.controllerMessageCount.rawValue,
                                                                extraDimensions: ["type": "start_new_process"])

    /// Count of perProcessMessage requests received by controller.
    package let perProcessMessageRequests = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.controllerMessageCount.rawValue,
                                                                  extraDimensions: ["type": "per_process_message"])

    /// Count of shutdown message requests received by controller.
    package let shutdownRequests = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.controllerMessageCount.rawValue,
                                                         extraDimensions: ["type": "shutdown"])

    /// Count of heartbeat message requests received by controller.
    package let heartbeatMessageRequests = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.controllerMessageCount.rawValue,
                                                                  extraDimensions: ["type": "heartbeat"])

    /// Count of invalid messages received by controller.
    package let invalidMessagesReceived = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.controllerInvalidMessagesCount.rawValue)

    // MARK: Heartbeat metrics

    /// Low-cardinality bucket for the `consecutive_failures` dimension on the heartbeat
    /// round-trip histogram. `zero` is used on success; the other cases capture the
    /// running streak length at the time of a failed attempt, clamped at `fivePlus` so
    /// the dimension stays bounded regardless of `maxConsecutiveHeartbeatFailures`.
    package enum HeartbeatConsecutiveFailuresBucket: String, Sendable, CaseIterable {
        case zero = "0"
        case one = "1"
        case two = "2"
        case three = "3"
        case four = "4"
        case fivePlus = "5+"

        /// Maps a raw consecutive-failure count to its bucket. `count` should be `0`
        /// on success and `1...` on failure (i.e. the failure-streak length *including*
        /// the current attempt).
        package static func bucket(forCount count: Int) -> Self {
            switch count {
            case ...0: return .zero
            case 1: return .one
            case 2: return .two
            case 3: return .three
            case 4: return .four
            default: return .fivePlus
            }
        }
    }

    /// Per-`(rank, result, consecutive_failures)` cache of heartbeat round-trip latency
    /// histograms. `rank` is the destination follower rank; `result` is "success" or
    /// "failure"; `consecutive_failures` is the bucketed streak length (see
    /// `HeartbeatConsecutiveFailuresBucket`). Cardinality is bounded by
    /// `ensemble size × 2 × 6`, so caching per-key is safe.
    private let heartbeatHistograms: Mutex<[String: EnsemblePorterHistogram]> = .init([:])

    private func heartbeatHistogram(
        rank: Int,
        result: String,
        consecutiveFailures: HeartbeatConsecutiveFailuresBucket
    ) -> EnsemblePorterHistogram {
        let key = "\(rank)_\(result)_\(consecutiveFailures.rawValue)"
        return self.heartbeatHistograms.withLock { dict in
            if let existing = dict[key] {
                return existing
            }
            let histogram = EnsemblePorterHistogram(
                label: EnsemblePorterMetricLabel.heartbeatRoundTripDurationSeconds.rawValue,
                extraDimensions: [
                    "result": result,
                    "rank": String(rank),
                    "consecutive_failures": consecutiveFailures.rawValue,
                ])
            histogram.setUnit(to: .seconds); histogram.setScale(to: .milli)
            dict[key] = histogram
            return histogram
        }
    }

    /// Records the round-trip latency of a heartbeat send to a specific follower.
    ///
    /// Emits to `ensembleporter_heartbeat_round_trip_duration_seconds` with dimensions
    /// `result=success|failure`, `rank=<follower rank>`, and `consecutive_failures`
    /// (bucketed: "0" on success, "1".."4", "5+" on failure). Per-rank slicing lets us
    /// identify a single flaky follower without grepping logs; the `consecutive_failures`
    /// bucket lets dashboards distinguish a single transient blip from a sustained
    /// streak that's about to trigger an `EX_UNAVAILABLE` exit.
    ///
    /// - Parameter consecutiveFailures: Streak length *including* the current attempt
    ///   when it failed; pass `0` on success.
    package func recordHeartbeatRoundTrip(
        rank: Int,
        success: Bool,
        consecutiveFailures: Int,
        durationSeconds: Double
    ) {
        let result = success ? "success" : "failure"
        let bucket = HeartbeatConsecutiveFailuresBucket.bucket(forCount: consecutiveFailures)
        self.heartbeatHistogram(rank: rank, result: result, consecutiveFailures: bucket).set(durationSeconds)
    }

    /// Test-only: number of heartbeat histogram samples observed for a
    /// `(rank, result, consecutive_failures)` tuple.
    package func getHeartbeatRoundTripSampleCount(
        rank: Int,
        success: Bool,
        consecutiveFailures: HeartbeatConsecutiveFailuresBucket
    ) -> Int {
        let result = success ? "success" : "failure"
        let key = "\(rank)_\(result)_\(consecutiveFailures.rawValue)"
        return self.heartbeatHistograms.withLock { $0[key]?.sampleCount ?? 0 }
    }

    // MARK: ECDH exchange (per-rank, per-step) histograms

    /// Steps in the leader↔follower ECDH key exchange that we time independently.
    package enum ECDHStep: String, Sendable {
        /// Sending the start request to ensembled / awaiting the follower's reply.
        case sendStart = "send_start"
        /// `sharedSecretFromKeyAgreement(with:)` after parsing the follower's public key.
        case keyAgreement = "key_agreement"
        /// `hkdfDerivedSymmetricKey(...)` from the shared secret.
        case hkdf
    }

    private let ecdhHistograms: Mutex<[String: EnsemblePorterHistogram]> = .init([:])

    private func ecdhHistogram(rank: Int, step: ECDHStep, result: String) -> EnsemblePorterHistogram {
        let key = "\(rank)_\(step.rawValue)_\(result)"
        return self.ecdhHistograms.withLock { dict in
            if let existing = dict[key] {
                return existing
            }
            let histogram = EnsemblePorterHistogram(
                label: EnsemblePorterMetricLabel.ecdhExchangeDurationSeconds.rawValue,
                extraDimensions: ["result": result, "rank": String(rank), "step": step.rawValue])
            histogram.setUnit(to: .seconds); histogram.setScale(to: .milli)
            dict[key] = histogram
            return histogram
        }
    }

    /// Records latency of one step of the ECDH exchange against a specific follower.
    package func recordECDHExchange(rank: Int, step: ECDHStep, success: Bool, durationSeconds: Double) {
        let result = success ? "success" : "failure"
        self.ecdhHistogram(rank: rank, step: step, result: result).set(durationSeconds)
    }

    /// Test-only: number of ECDH histogram samples observed for a `(rank, step, result)`.
    package func getECDHExchangeSampleCount(rank: Int, step: ECDHStep, success: Bool) -> Int {
        let result = success ? "success" : "failure"
        let key = "\(rank)_\(step.rawValue)_\(result)"
        return self.ecdhHistograms.withLock { $0[key]?.sampleCount ?? 0 }
    }

    // MARK: Per-follower send latency

    private let followerSendHistograms: Mutex<[String: EnsemblePorterHistogram]> = .init([:])

    private func followerSendHistogram(rank: Int, result: String) -> EnsemblePorterHistogram {
        let key = "\(rank)_\(result)"
        return self.followerSendHistograms.withLock { dict in
            if let existing = dict[key] {
                return existing
            }
            let histogram = EnsemblePorterHistogram(
                label: EnsemblePorterMetricLabel.followerSendDurationSeconds.rawValue,
                extraDimensions: ["result": result, "rank": String(rank)])
            histogram.setUnit(to: .seconds); histogram.setScale(to: .milli)
            dict[key] = histogram
            return histogram
        }
    }

    /// Records the duration of a single key send from leader to a specific follower.
    package func recordFollowerSend(rank: Int, success: Bool, durationSeconds: Double) {
        let result = success ? "success" : "failure"
        self.followerSendHistogram(rank: rank, result: result).set(durationSeconds)
    }

    /// Test-only: number of follower-send histogram samples observed for a `(rank, result)`.
    package func getFollowerSendSampleCount(rank: Int, success: Bool) -> Int {
        let result = success ? "success" : "failure"
        let key = "\(rank)_\(result)"
        return self.followerSendHistograms.withLock { $0[key]?.sampleCount ?? 0 }
    }

    // MARK: Entitlement validation

    /// Failure types for entitlement validation. Stable, low-cardinality.
    package enum EntitlementFailureType: String, Sendable {
        case none
        /// `SecTaskCreateWithAuditToken` returned nil.
        case secTask = "sec_task"
        /// `SecTaskCopyValueForEntitlement` reported an error.
        case secTaskCopyError = "sec_task_copy_error"
        /// Entitlement value missing or not exactly `kCFBooleanTrue`.
        case missingOrWrongValue = "missing_or_wrong_value"
    }

    private let entitlementCounters: Mutex<[String: EnsemblePorterCounter]> = .init([:])

    /// Records an entitlement validation outcome.
    ///
    /// Emits to `ensembleporter_entitlement_validation_count` with
    /// `entitlement`, `result=success|failure`, `failure_type` dimensions.
    package func incrementEntitlementValidation(entitlement: String, success: Bool, failureType: EntitlementFailureType) {
        let result = success ? "success" : "failure"
        let key = "\(entitlement)_\(result)_\(failureType.rawValue)"
        let counter = self.entitlementCounters.withLock { dict -> EnsemblePorterCounter in
            if let existing = dict[key] {
                return existing
            }
            let c = EnsemblePorterCounter(
                label: EnsemblePorterMetricLabel.entitlementValidationCount.rawValue,
                extraDimensions: [
                    "entitlement": entitlement,
                    "result": result,
                    "failure_type": failureType.rawValue,
                ])
            dict[key] = c
            return c
        }
        counter.increment()
    }

    // MARK: Generic per-operation timing wrappers

    /// Operations exposed by the porter XPC server. Matches the `EnsemblePorterXPCAPI.Request` shape.
    package enum XPCOperation: String, Sendable {
        case provide
        case fetch
        case getNumberOfTurnKeys
        case fetchFollowerTokens
        case fetchFTETKey
        case getIntraEnsemblePublicKey
        case provideEncryptedCryptoMaterial
        case ftETOnlyTurn
    }

    /// Operations exposed by the porter framework client.
    package enum ClientOperation: String, Sendable {
        case provide
        case getIntraEnsemblePublicKey
        case provideEncryptedCryptoMaterial
    }

    private let xpcRequestHistograms: Mutex<[String: EnsemblePorterHistogram]> = .init([:])
    private let clientCallHistograms: Mutex<[String: EnsemblePorterHistogram]> = .init([:])

    private func operationHistogram(
        cache: borrowing Mutex<[String: EnsemblePorterHistogram]>,
        label: String,
        operation: String,
        result: String,
        errorCategory: String?
    ) -> EnsemblePorterHistogram {
        let categoryKey = errorCategory ?? ""
        let key = "\(operation)_\(result)_\(categoryKey)"
        return cache.withLock { dict in
            if let existing = dict[key] {
                return existing
            }
            let dims: OSMetricDimensions
            if let errorCategory {
                dims = [
                    "operation": operation,
                    "result": result,
                    "error_category": errorCategory,
                ]
            } else {
                dims = [
                    "operation": operation,
                    "result": result,
                ]
            }
            let histogram = EnsemblePorterHistogram(label: label, extraDimensions: dims)
            histogram.setUnit(to: .seconds); histogram.setScale(to: .milli)
            dict[key] = histogram
            return histogram
        }
    }

    /// Wraps a porter XPC server-side handler closure and records its duration into
    /// `ensembleporter_xpc_request_duration_seconds` with `operation`, `result`, and (on failure)
    /// `error_category` dims. The `error_category` dim is omitted on success.
    package func reportingPorterXPC<T>(operation: XPCOperation, fn: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        var result = "success"
        var errorCategory: String? = nil
        defer {
            let elapsed = ContinuousClock.now - start
            let durationSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            self.operationHistogram(
                cache: self.xpcRequestHistograms,
                label: EnsemblePorterMetricLabel.xpcRequestDurationSeconds.rawValue,
                operation: operation.rawValue,
                result: result,
                errorCategory: errorCategory
            ).set(durationSeconds)
        }
        do {
            return try await fn()
        } catch let error as EnsemblePorterError {
            result = "failure"
            errorCategory = error.metricsLabel
            throw error
        } catch {
            result = "failure"
            errorCategory = "other"
            throw error
        }
    }

    /// Records a single porter XPC server-side request outcome with explicit result/error info.
    /// The `error_category` dim is omitted on success.
    package func recordXPCRequest(operation: XPCOperation, success: Bool, errorCategory: String?, durationSeconds: Double) {
        self.operationHistogram(
            cache: self.xpcRequestHistograms,
            label: EnsemblePorterMetricLabel.xpcRequestDurationSeconds.rawValue,
            operation: operation.rawValue,
            result: success ? "success" : "failure",
            errorCategory: success ? nil : (errorCategory ?? "other")
        ).set(durationSeconds)
    }

    /// Wraps a porter framework client-side call and records its duration into
    /// `ensembleporter_client_call_duration_seconds` with `operation`, `result`, and (on failure)
    /// `error_category` dims. The `error_category` dim is omitted on success.
    package func reportingPorterClient<T>(operation: ClientOperation, fn: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        var result = "success"
        var errorCategory: String? = nil
        defer {
            let elapsed = ContinuousClock.now - start
            let durationSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            self.operationHistogram(
                cache: self.clientCallHistograms,
                label: EnsemblePorterMetricLabel.clientCallDurationSeconds.rawValue,
                operation: operation.rawValue,
                result: result,
                errorCategory: errorCategory
            ).set(durationSeconds)
        }
        do {
            return try await fn()
        } catch let error as EnsemblePorterError {
            result = "failure"
            errorCategory = error.metricsLabel
            throw error
        } catch {
            result = "failure"
            errorCategory = "other"
            throw error
        }
    }

    // MARK: KeySafe fatal-error counter

    /// Reasons a `KeySafe` operation triggers `fatalError`. Stable, low-cardinality.
    package enum KeySafeFatalErrorReason: String, Sendable {
        /// `waitForTurnKeys()` invoked before `setFTETKey(_:)`.
        case waitBeforeSetFTET = "wait_before_set_ftet"
        /// More than one waiter for turn keys at the same time.
        case multipleWaiters = "multiple_waiters"
    }

    private let keysafeFatalErrorCounters: Mutex<[KeySafeFatalErrorReason: EnsemblePorterCounter]> = .init([:])

    /// Counts `fatalError` invocations in `KeySafe`. Increment immediately before the call so
    /// crashes can be attributed to a specific reason in the metrics pipeline.
    package func incrementKeysafeFatalError(reason: KeySafeFatalErrorReason) {
        let counter = self.keysafeFatalErrorCounters.withLock { dict -> EnsemblePorterCounter in
            if let existing = dict[reason] {
                return existing
            }
            let c = EnsemblePorterCounter(
                label: EnsemblePorterMetricLabel.keysafeFatalErrorCount.rawValue,
                extraDimensions: ["reason": reason.rawValue])
            dict[reason] = c
            return c
        }
        counter.increment()
    }

    // MARK: Heartbeat-driven exit counter

    /// Reasons the heartbeat loop calls `exit(EX_UNAVAILABLE)`. Stable, low-cardinality.
    package enum HeartbeatExitReason: String, Sendable {
        /// Controller rejected the heartbeat with `success=false` — the follower porter
        /// instance is gone.
        case instanceNotFound = "instance_not_found"
        /// `maxConsecutiveHeartbeatFailures` heartbeats in a row failed.
        case maxConsecutiveFailures = "max_consecutive_failures"
    }

    private let heartbeatExitCounters: Mutex<[HeartbeatExitReason: EnsemblePorterCounter]> = .init([:])

    /// Counts `exit(EX_UNAVAILABLE)` invocations from the heartbeat loop. Increment
    /// immediately before the call so terminations can be attributed to a specific
    /// reason even if the surrounding logs are lost. Host/rank dimensions are added
    /// by the metrics platform.
    package func incrementHeartbeatExit(reason: HeartbeatExitReason) {
        let counter = self.heartbeatExitCounters.withLock { dict -> EnsemblePorterCounter in
            if let existing = dict[reason] {
                return existing
            }
            let c = EnsemblePorterCounter(
                label: EnsemblePorterMetricLabel.heartbeatExitCount.rawValue,
                extraDimensions: ["reason": reason.rawValue])
            dict[reason] = c
            return c
        }
        counter.increment()
    }

    // MARK: Instance removal metrics
    /// Instance removed due to leader-initiated shutdown.
    package let instanceRemovedByShutdown = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.instanceRemovedCount.rawValue,
                                                                   extraDimensions: ["reason": "shutdown"])

    /// Instance removed due to heartbeat timeout.
    package let instanceRemovedByHeartbeatTimeout = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.instanceRemovedCount.rawValue,
                                                                          extraDimensions: ["reason": "heartbeat_timeout"])

    /// Instance removed because its process was no longer running when a heartbeat was received.
    package let instanceRemovedByProcessCrash = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.instanceRemovedCount.rawValue,
                                                                      extraDimensions: ["reason": "process_crash"])

    /// Instance reaped because launchd was running it but the controller had no record of it.
    ///
    /// This typically indicates the controller restarted while a request was in flight,
    /// or that a previous controller life leaked launchd job instances. A non-zero rate is
    /// expected after every controller restart; a sustained rate indicates a leak.
    package let instanceRemovedByOrphan = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.instanceRemovedCount.rawValue,
                                                                extraDimensions: ["reason": "orphan"])

    /// Heartbeat arrived for a launchd-running instance the controller had no record of,
    /// so the controller adopted it.
    ///
    /// This is the recovery path for a controller restart that occurs during a live
    /// request: the leader keeps heartbeating and we resume tracking. A non-zero rate is
    /// expected after every controller restart and means the recovery worked.
    package let instanceAdopted = EnsemblePorterCounter(
        label: EnsemblePorterMetricLabel.instanceAdoptedCount.rawValue)

    /// Failures to query the launchd-running instance set during heartbeat-timeout reaping.
    package let runningInstancesQueryFailures = EnsemblePorterCounter(
        label: EnsemblePorterMetricLabel.runningInstancesQueryFailureCount.rawValue)

    /// Current number of active porter jobs managed by the controller.
    package let controllerActiveJobs = EnsemblePorterGauge(
        label: EnsemblePorterMetricLabel.controllerActiveJobsCount.rawValue)

    /// ALARM. Incremented every time the controller's max-porter cap is reached, forcing
    /// eviction of the oldest in-use porter. See `controllerMaxPortersReachedCount`.
    package let maxPortersReached = EnsemblePorterCounter(
        label: EnsemblePorterMetricLabel.controllerMaxPortersReachedCount.rawValue)

    // MARK: Heartbeat-failure shutdown metrics (best-effort cleanup of sibling followers)
    /// Round-trip duration for successful sibling-follower shutdown after heartbeat failure.
    package let heartbeatFailureShutdownDurationSuccess = OSMetricHistogram(
        type: Double.self,
        group: group,
        label: EnsemblePorterMetricLabel.heartbeatFailureShutdownDurationSeconds.rawValue,
        extraDimensions: ["result": "success"],
        bins: .logarithmic(count: 100))

    /// Round-trip duration for failed sibling-follower shutdown after heartbeat failure.
    package let heartbeatFailureShutdownDurationFailure = OSMetricHistogram(
        type: Double.self,
        group: group,
        label: EnsemblePorterMetricLabel.heartbeatFailureShutdownDurationSeconds.rawValue,
        extraDimensions: ["result": "failure"],
        bins: .logarithmic(count: 100))

    // MARK: Aggregate shutdown-followers metrics

    /// Why a leader-side aggregate shutdown of followers ran. Stable, low-cardinality.
    package enum ShutdownFollowersPhase: String, Sendable {
        /// `teardownFollowers()` from `.running` — request completed normally.
        case requestComplete = "request_complete"
        /// `teardownFollowers()` from `.prewarmed` / `.notStarted` / `.starting` — torn down
        /// before Parameters arrived (CloudBoard pool recycle or client cancellation).
        case preRequest = "pre_request"
        /// `shutdownOtherFollowers(...)` — best-effort sibling cleanup after a heartbeat to
        /// some other follower failed.
        case heartbeatFailure = "heartbeat_failure"
    }

    private let shutdownFollowersCounters: Mutex<[String: EnsemblePorterCounter]> = .init([:])
    private let shutdownFollowersHistograms: Mutex<[String: EnsemblePorterHistogram]> = .init([:])

    private func shutdownFollowersCounter(
        phase: ShutdownFollowersPhase,
        result: String,
        errorCategory: String?
    ) -> EnsemblePorterCounter {
        let categoryKey = errorCategory ?? ""
        let key = "\(phase.rawValue)_\(result)_\(categoryKey)"
        return self.shutdownFollowersCounters.withLock { dict in
            if let existing = dict[key] {
                return existing
            }
            let dims: OSMetricDimensions
            if let errorCategory {
                dims = ["phase": phase.rawValue, "result": result, "error_category": errorCategory]
            } else {
                dims = ["phase": phase.rawValue, "result": result]
            }
            let counter = EnsemblePorterCounter(
                label: EnsemblePorterMetricLabel.shutdownFollowersCount.rawValue,
                extraDimensions: dims)
            dict[key] = counter
            return counter
        }
    }

    private func shutdownFollowersHistogram(
        phase: ShutdownFollowersPhase,
        result: String
    ) -> EnsemblePorterHistogram {
        let key = "\(phase.rawValue)_\(result)"
        return self.shutdownFollowersHistograms.withLock { dict in
            if let existing = dict[key] {
                return existing
            }
            let histogram = EnsemblePorterHistogram(
                label: EnsemblePorterMetricLabel.shutdownFollowersDurationSeconds.rawValue,
                extraDimensions: ["phase": phase.rawValue, "result": result])
            histogram.setUnit(to: .seconds)
            histogram.setScale(to: .milli)
            dict[key] = histogram
            return histogram
        }
    }

    /// Records one aggregate shutdown-followers invocation: increments the counter (with
    /// `error_category` only on failure, derived via `String(reportable:)`) and records
    /// the wall-clock duration.
    package func recordShutdownFollowers(
        phase: ShutdownFollowersPhase,
        success: Bool,
        error: Error? = nil,
        durationSeconds: Double
    ) {
        let result = success ? "success" : "failure"
        let category: String? = success ? nil : (error.map { String(reportable: $0) } ?? "other")
        self.shutdownFollowersCounter(phase: phase, result: result, errorCategory: category)
            .increment()
        self.shutdownFollowersHistogram(phase: phase, result: result)
            .set(durationSeconds)
    }

    /// Test-only: number of `shutdown_followers_count` increments observed for a series.
    package func getShutdownFollowersCount(
        phase: ShutdownFollowersPhase,
        success: Bool,
        error: Error? = nil
    ) -> Int64 {
        let result = success ? "success" : "failure"
        let category: String? = success ? nil : (error.map { String(reportable: $0) } ?? "other")
        return self.shutdownFollowersCounter(phase: phase, result: result, errorCategory: category).value
    }

    /// Test-only: number of `shutdown_followers_duration_seconds` samples observed for a series.
    package func getShutdownFollowersDurationSampleCount(
        phase: ShutdownFollowersPhase,
        success: Bool
    ) -> Int {
        let result = success ? "success" : "failure"
        return self.shutdownFollowersHistogram(phase: phase, result: result).sampleCount
    }

    // MARK: Dynamic counter functionality for consolidated metrics

    /// Dynamic counter cache for consolidated metrics
    private let counters: Mutex<[String: EnsemblePorterCounter]> = .init([:])

    private func getCounter(metric: EnsemblePorterMetricLabel, result: String, error: EnsemblePorterError? = nil) -> EnsemblePorterCounter {
        let errorKey = error?.metricsLabel ?? "success"
        let key = "\(metric.rawValue)_\(result)_\(errorKey)"
        return counters.withLock { dict in
            if let existing = dict[key] {
                return existing
            }
            let counter: EnsemblePorterCounter
            if let error = error {
                counter = EnsemblePorterCounter(label: metric.rawValue, extraDimensions: ["result": result, "error": error.metricsLabel])
            } else {
                counter = EnsemblePorterCounter(label: metric.rawValue, extraDimensions: ["result": result])
            }
            dict[key] = counter
            return counter
        }
    }

    // Operation-specific increment methods
    package func incrementKeyProvision(success: Bool, error: EnsemblePorterError? = nil) {
        let result = success ? "success" : "failure"
        getCounter(metric: .keyProvisionCount, result: result, error: error).increment()
    }

    package func incrementKeyFetch(success: Bool, error: EnsemblePorterError? = nil) {
        let result = success ? "success" : "failure"
        getCounter(metric: .keyFetchCount, result: result, error: error).increment()
    }

    package func incrementXPC(error: EnsemblePorterError = .transportFailed) {
        getCounter(metric: .xpcCount, result: "failure", error: error).increment()
    }

    // Test helper methods
    package func getKeyProvisionValue(success: Bool, error: EnsemblePorterError? = nil) -> Int64 {
        let result = success ? "success" : "failure"
        return getCounter(metric: .keyProvisionCount, result: result, error: error).value
    }

    package func getKeyFetchValue(success: Bool, error: EnsemblePorterError? = nil) -> Int64 {
        let result = success ? "success" : "failure"
        return getCounter(metric: .keyFetchCount, result: result, error: error).value
    }

    package func getXPCValue(error: EnsemblePorterError = .transportFailed) -> Int64 {
        return getCounter(metric: .xpcCount, result: "failure", error: error).value
    }

    /// Test-only: returns the current value of the `process_start_count` counter for the given outcome.
    package func getInstanceCreationValue(success: Bool) -> Int64 {
        getCounter(metric: .processStartCount, result: success ? "success" : "failure").value
    }

    /// Test-only: returns the current value of the `distribution_attempts_count` counter for the given outcome.
    package func getDistributionAttemptValue(success: Bool) -> Int64 {
        getCounter(metric: .distributionAttemptsCount, result: success ? "success" : "failure").value
    }

    /// Test-only: returns the current value of the `entitlement_validation_count` counter
    /// for the given (entitlement, success, failureType) tuple.
    package func getEntitlementValidationValue(entitlement: String, success: Bool, failureType: EntitlementFailureType) -> Int64 {
        let result = success ? "success" : "failure"
        let key = "\(entitlement)_\(result)_\(failureType.rawValue)"
        return self.entitlementCounters.withLock { dict in
            dict[key]?.value ?? 0
        }
    }

    /// Test-only: returns the current value of the `keysafe_fatal_error_count` counter for the given reason.
    /// Note: production call sites invoke `fatalError` immediately after incrementing, so this is only
    /// useful for asserting the helper itself works.
    package func getKeysafeFatalErrorValue(reason: KeySafeFatalErrorReason) -> Int64 {
        self.keysafeFatalErrorCounters.withLock { dict in
            dict[reason]?.value ?? 0
        }
    }

    /// Test-only: number of `xpc_request_duration_seconds` samples observed for an
    /// `(operation, success, errorCategory)` series. Pass `nil` for `errorCategory` on success.
    package func getXPCRequestSampleCount(operation: XPCOperation, success: Bool, errorCategory: String? = nil) -> Int {
        let categoryKey = errorCategory ?? ""
        let key = "\(operation.rawValue)_\(success ? "success" : "failure")_\(categoryKey)"
        return self.xpcRequestHistograms.withLock { $0[key]?.sampleCount ?? 0 }
    }

    /// Test-only: number of `client_call_duration_seconds` samples observed for an
    /// `(operation, success, errorCategory)` series. Pass `nil` for `errorCategory` on success.
    package func getClientCallSampleCount(operation: ClientOperation, success: Bool, errorCategory: String? = nil) -> Int {
        let categoryKey = errorCategory ?? ""
        let key = "\(operation.rawValue)_\(success ? "success" : "failure")_\(categoryKey)"
        return self.clientCallHistograms.withLock { $0[key]?.sampleCount ?? 0 }
    }

    package init() {
        self.prewarmRequestDuration.setUnit(to: .seconds)
        self.prewarmRequestDuration.setScale(to: .milli)
        self.fetchRequestDuration.setUnit(to: .seconds)
        self.fetchRequestDuration.setScale(to: .milli)
        self.distributionRequestDuration.setUnit(to: .seconds)
        self.distributionRequestDuration.setScale(to: .milli)
        // Heartbeat histograms are configured per-`(rank, result)` on first use; see
        // `heartbeatHistogram(rank:result:)`.
        self.heartbeatFailureShutdownDurationSuccess.setUnit(to: .seconds)
        self.heartbeatFailureShutdownDurationSuccess.setScale(to: .milli)
        self.heartbeatFailureShutdownDurationFailure.setUnit(to: .seconds)
        self.heartbeatFailureShutdownDurationFailure.setScale(to: .milli)
    }
}
