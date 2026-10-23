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
//  Metrics.swift
//  AppleComputeEnsembler
//
//  Created by Dhanasekar Thangavel on 11/13/24.
//
#if canImport(CloudMetricsFramework)
import CloudMetricsFramework
#endif
@_spi(Daemon) import AppleComputeEnsembler // Helper functions

// TODO: rdar://141310224 (Create and use StubFrameworks for DarwinInitChecker, JaobQuiscence, and CloudMetrics)
public func initCloudMetricsFrameworkBackend() {
	#if canImport(CloudMetricsFramework)
	CloudMetrics.bootstrap(clientName: "ensembled")
	#endif
}

public func handleStateTransition(
	to currentState: EnsemblerStatus,
	isLeader: Bool,
	rank: Int,
	chassisID: String,
	nodeCnt: Int
) {
	EnsemblerTLS.logger.info("Exporting metrics")
	#if canImport(CloudMetricsFramework)
	// increment counter for the number of transitions
	let counter = Counter(
		label: "ensembled_statetransitions_total",
		dimensions: [
			("to_state", "\(currentState)"),
			("is_leader", "\(isLeader)"),
			("rank", "\(rank)"),
			("chassisID", chassisID),
			("nodeCount", "\(nodeCnt)"),
		]
	)
	counter.increment()

	// update the guage metrics as well.
	updateCurrentStateCountGaugeMetrics(
		newState: currentState,
		isLeader: isLeader,
		rank: rank,
		chassisID: chassisID,
		nodeCnt: nodeCnt
	)
	#endif
	EnsemblerTLS.logger.info("Done exporting metrics.")
}

#if canImport(CloudMetricsFramework)
/// Updates a gauge counter which represents a set of different states numerically as 0 or 1, where
/// the gauge with a given dimension set to one of the states set to 0 means that something is not
/// in that state
/// but a gauge with a given dimension set to a different state set to 1 means that something IS IN
/// that state.
/// For the case of EnsemblerStatus, if the node is in initialized state, the guage with the
/// dimension
/// "tostate": "initialized" is set to 1 and guage with dimension "tostate": all other states is set
/// to 0.
///  This allows both easily aggreagating the count of nodes in a given state across the fleet
/// at a point in time as well as viewing the history of the state for a given node as it
/// transitions from one state
/// to another.
/// - Parameters:
///   - currentState: the state that is active for the gauge
///   - mkGauge: a function to create the gauge object, this should set the label and dimensions on
/// the gauge
public func updateGenericStateGaugeCounter<T: CustomStringConvertible & CaseIterable & Equatable>(
	currentState: T,
	mkGauge: (_ state: T) -> Gauge
) {
	// Set all guages for all other states to 0 before setting the current
	// state to 1 to avoid sampling races.
	for state in T.allCases {
		guard state != currentState else { continue }

		let gauge = mkGauge(state)
		gauge.record(0)
	}

	let gauge = mkGauge(currentState)
	gauge.record(1)
}
#endif

/// Record a sendDataAndGetResponse call as a latency histogram in milliseconds.
/// Pass `error: nil` on success; pass the actual error on failure so the failure_reason
/// dimension is resolved inside the CloudMetricsFramework guard and never evaluated otherwise.
/// Pass `durationMs: 0` for pre-flight failures (not-ready, nil channel) that never hit
/// the network.
public func trackSendDataAndGetResponse(
	success: Bool,
	error: Error?,
	durationMs: Double,
	isLeader: Bool,
	rank: Int,
	chassisID: String
) {
	#if canImport(CloudMetricsFramework)
	let failureReason: String
	if success {
		failureReason = "none"
	} else if let dataErr = error as? DataMessageError {
		switch dataErr {
		case .noRegisteredHandler:  failureReason = "noRegisteredHandler"
		case .timeoutOnPeerHandler: failureReason = "timeoutOnPeerHandler"
		case .noResponseReceived:   failureReason = "noResponseReceived"
		case .internalError:        failureReason = "internalError"
		case .notReady:             failureReason = "notReady"
		}
	} else {
		failureReason = "other"
	}
	if let histogram = try? Histogram(
		label: "ensembled_senddataandgetresponse_latency_ms",
		dimensions: [
			("result", success ? "success" : "failure"),
			("failure_reason", failureReason),
			("ensemble_role", isLeader ? "leader" : "follower"),
			("rank", "\(rank)"),
			("chassisID", chassisID),
		],
		buckets: Array(stride(from: 0.0, through: 200.0, by: 5.0))
	) {
		histogram.record(durationMs)
	}
	#endif
}

/// Record the time from `.initializing` to first `.ready` as a histogram in seconds.
/// Buckets: 2-minute intervals from 0 to 30 minutes, then 30+ minutes.
public func trackEnsembleFormationDuration(durationSeconds: Double, isLeader: Bool, rank: Int, chassisID: String) {
	#if canImport(CloudMetricsFramework)
	if let histogram = try? Histogram(
		label: "ensembled_formation_duration_seconds",
		dimensions: [
			("ensemble_role", isLeader ? "leader" : "follower"),
			("rank", "\(rank)"),
			("chassisID", chassisID),
		],
		buckets: Array(stride(from: 0.0, through: 1800.0, by: 120.0))
	) {
		histogram.record(durationSeconds)
	}
	#endif
}

/// Record the time from `.redistributingKey` back to `.ready` as a histogram in seconds.
/// Buckets: 1-second intervals from 0 to 10 seconds, then 10+ seconds.
public func trackKeyRotationDuration(durationSeconds: Double, isLeader: Bool, rank: Int, chassisID: String) {
	#if canImport(CloudMetricsFramework)
	if let histogram = try? Histogram(
		label: "ensembled_keyrotation_duration_seconds",
		dimensions: [
			("ensemble_role", isLeader ? "leader" : "follower"),
			("rank", "\(rank)"),
			("chassisID", chassisID),
		],
		buckets: Array(stride(from: 0.0, through: 10.0, by: 1.0))
	) {
		histogram.record(durationSeconds)
	}
	#endif
}

/// Update the current state metrics gauges for this compute node with
/// either the specified new state
/// - Parameter newState: the new state
/// - Parameter isLeader: whether the node sending metrics is leader or not. Leader if true,
/// Follower if false.
///                       However in case of  .uninitialized state, this should be ignored.
/// - Parameter rank: rank of the node, In case of .uninitialized state, this should be ignored.
/// - Parameter chassisID: chassisID of the node. In case of .uninitialized state, this should be
/// ignored.
///
public func updateCurrentStateCountGaugeMetrics(
	newState: EnsemblerStatus,
	isLeader: Bool,
	rank: Int,
	chassisID: String,
	nodeCnt: Int
) {
	#if canImport(CloudMetricsFramework)
	updateGenericStateGaugeCounter(currentState: newState) { state in
		Gauge(
			label: "ensembled_state_total",
			dimensions: [
				("to_state", "\(state)"),
				("is_leader", "\(isLeader)"),
				("rank", "\(rank)"),
				("chassisID", chassisID),
				("nodeCount", "\(nodeCnt)"),
			]
		)
	}
	#endif
}
