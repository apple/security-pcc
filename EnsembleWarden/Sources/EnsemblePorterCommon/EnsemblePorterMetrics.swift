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

    /// Tracks encrypted data transmission from leader to individual follower instances.
    ///
    /// **Phase**: Request
    /// **Operation**: Leader sending encrypted keys to specific follower processes
    /// **When Incremented**: Each individual send operation to a follower during distribution
    /// **Dimensions**: `result` ("success"/"failure"), `error` (detailed error type from EnsemblePorterError)
    case followerSendCount = "ensembleporter_follower_send_count"

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

/// All the metrics for ensemble porter.
package final class EnsemblePorterMetrics: Sendable {

    /// Tracks process initialization events.
    package let processStarts = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.processStartCount.rawValue)
    /// Tracks successful instance creation by the controller.
    package let instanceCreationSuccess = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.processStartCount.rawValue,
                                                                extraDimensions: ["result": "success"])
    /// Tracks failed instance creation by the controller.
    package let instanceCreationFailure = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.processStartCount.rawValue,
                                                                extraDimensions: ["result": "failure"])

    /// Current count of turn keys stored in the KeySafe after supply.
    package let turnKeysStored = OSMetricGauge(type: Int64.self,
                                               group: group,
                                               label: EnsemblePorterMetricLabel.turnKeysStoredCount.rawValue)

    /// Latency distribution for prewarm operations from start to completion.
    package let prewarmRequestDuration = OSMetricHistogram(type: Double.self,
                                                           group: group,
                                                           label: EnsemblePorterMetricLabel.prewarmRequestDurationSeconds.rawValue,
                                                           bins: .logarithmic(count: 100))

    /// Latency distribution for fetch operations from start to completion.
    package let fetchRequestDuration = OSMetricHistogram(type: Double.self,
                                                         group: group,
                                                         label: EnsemblePorterMetricLabel.fetchRequestDurationSeconds.rawValue,
                                                         bins: .logarithmic(count: 100))

    /// Latency distribution for distribution operations from start to completion.
    package let distributionRequestDuration = OSMetricHistogram(type: Double.self,
                                                                group: group,
                                                                label: EnsemblePorterMetricLabel.distributionRequestDurationSeconds.rawValue,
                                                                bins: .logarithmic(count: 100))


    // MARK: Distribution metrics
    /// Successful distribution of crypto material to all follower nodes.
    package let distributionAttemptsSuccess = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.distributionAttemptsCount.rawValue,
                                                                    extraDimensions: ["result": "success"])

    /// Failed distribution of crypto material to follower nodes.
    package let distributionAttemptsFailure = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.distributionAttemptsCount.rawValue,
                                                                    extraDimensions: ["result": "failure"])

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

    /// Count of invalid messages received by controller.
    package let invalidMessagesReceived = EnsemblePorterCounter(label: EnsemblePorterMetricLabel.controllerInvalidMessagesCount.rawValue)

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

    package func incrementFollowerSend(success: Bool, error: EnsemblePorterError? = nil) {
        let result = success ? "success" : "failure"
        getCounter(metric: .followerSendCount, result: result, error: error).increment()
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

    package func getFollowerSendValue(success: Bool, error: EnsemblePorterError? = nil) -> Int64 {
        let result = success ? "success" : "failure"
        return getCounter(metric: .followerSendCount, result: result, error: error).value
    }

    package func getXPCValue(error: EnsemblePorterError = .transportFailed) -> Int64 {
        return getCounter(metric: .xpcCount, result: "failure", error: error).value
    }

    package init() {
        self.prewarmRequestDuration.setUnit(to: .seconds)
        self.prewarmRequestDuration.setScale(to: .micro)
        self.fetchRequestDuration.setUnit(to: .seconds)
        self.fetchRequestDuration.setScale(to: .micro)
        self.distributionRequestDuration.setUnit(to: .seconds)
        self.distributionRequestDuration.setScale(to: .micro)
    }
}
