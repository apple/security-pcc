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

import Foundation
import os

/// Implements the ROPES selection logic for choosing compute nodes during negotiate/pick flows
package struct GatewayEnsembleSelectionStateMachine {
    private static let logger = Logger(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "GatewayEnsembleSelectionStateMachine"
    )

    // MARK: - State

    enum State: CustomStringConvertible {
        /// Initial state - no selection in progress
        case idle

        /// Candidates have been evaluated, ready to attempt reservations
        case ready(
            directCandidates: [EnsembleCandidate], // Can be reserved without pick
            pickCandidates: [EnsembleCandidate], // To offer to proxy for pick
            attemptedDirectCandidates: Set<String> // Legal ensemble IDs already attempted for reservation
        )

        /// Pick was sent to proxy, waiting for response or for one of the directCandiates to become available
        case awaitingPickOrQueueResolution(
            sentCandidates: [EnsembleCandidate],
            directCandidatesStillTrying: [EnsembleCandidate],
            attemptedEnsembles: Set<String>
        )

        /// Successfully reserved an ensemble and informed CloudBoard of the selection
        case succeeded(ReservationResult)

        /// All reservation attempts exhausted
        case failed(SelectionError)

        var description: String {
            switch self {
            case .idle: "idle"
            case .ready: "ready"
            case .awaitingPickOrQueueResolution: "awaitingProxySelection"
            case .succeeded: "succeeded"
            case .failed: "failed"
            }
        }
    }

    // MARK: - Types

    /// Ensemble candidate with metadata from service discovery
    package struct EnsembleCandidate: Sendable, Hashable {
        let ensembleId: String
        let bootId: String
        let rackId: String?
        let endpoint: PCCHarness.ComputeCloudAppEndpoint

        package init(
            ensembleId: String,
            bootId: String,
            rackId: String?,
            endpoint: PCCHarness.ComputeCloudAppEndpoint
        ) {
            self.ensembleId = ensembleId
            self.bootId = bootId
            self.rackId = rackId
            self.endpoint = endpoint
        }

        package func hash(into hasher: inout Hasher) {
            hasher.combine(self.ensembleId)
            hasher.combine(self.bootId)
        }

        package static func == (lhs: EnsembleCandidate, rhs: EnsembleCandidate) -> Bool {
            lhs.ensembleId == rhs.ensembleId && lhs.bootId == rhs.bootId
        }
    }

    /// Negotiate constraints from InvokeProxyInitiate message
    package struct NegotiateConstraints: Sendable {
        let trustedEnsembles: [(ensembleId: String, bootId: String)]
        let trustedRackIds: [String]
        let freeChoice: Bool
        let pick: PickParameters?

        package struct PickParameters: Sendable {
            let numProvidedChoices: UInt32
            let numSelectedChoices: UInt32
            /// The maximum factor the proxy will accept the ratio scaled by (announced in the
            /// InvokeProxyInitiate). Normalised to >= 1; an unset/zero wire value is treated as 1
            /// (no scaling).
            let ratioCanScaleTo: UInt32

            package init(
                numProvidedChoices: UInt32,
                numSelectedChoices: UInt32,
                ratioCanScaleTo: UInt32 = 1
            ) {
                self.numProvidedChoices = numProvidedChoices
                self.numSelectedChoices = numSelectedChoices
                self.ratioCanScaleTo = GatewayEnsembleSelectionStateMachine.normalisedScale(ratioCanScaleTo)
            }
        }

        package init(
            trustedEnsembles: [(ensembleId: String, bootId: String)] = [],
            trustedRackIds: [String] = [],
            freeChoice: Bool = false,
            pick: PickParameters? = nil
        ) {
            self.trustedEnsembles = trustedEnsembles
            self.trustedRackIds = trustedRackIds
            self.freeChoice = freeChoice
            self.pick = pick
        }

        /// Check if an ensemble can be used without pick protocol
        func isLegalToUseWithoutPick(ensembleId: String, bootId: String, rackId: String?) -> Bool {
            if self.freeChoice {
                return true
            }
            if self.trustedEnsembles.contains(where: { $0.ensembleId == ensembleId && $0.bootId == bootId }) {
                return true
            }
            if let rackId, trustedRackIds.contains(rackId) {
                return true
            }
            return false
        }
    }

    /// Result of a successful reservation
    package struct ReservationResult: Sendable {
        let candidate: EnsembleCandidate
        let token: PCCHarness.UsageTrackedAppEndpoint
        let workload: [String: [String]]
        let source: Source

        package enum Source: Sendable, CustomStringConvertible {
            case direct // Reserved directly without waiting for proxy
            case proxyPick // Proxy selected via pick protocol

            package var description: String {
                switch self {
                case .direct: return "direct"
                case .proxyPick: return "proxyPick"
                }
            }
        }

        internal init(
            candidate: EnsembleCandidate,
            token: PCCHarness.UsageTrackedAppEndpoint,
            workload: [String: [String]],
            source: Source
        ) {
            self.candidate = candidate
            self.token = token
            self.workload = workload
            self.source = source
        }
    }

    /// Selection failure reasons
    package enum SelectionError: Error, Sendable {
        case noCandidatesAvailable
        case allReservationsFailed
        case pickProtocolFailed
        case proxySelectedUnavailableEnsemble(String)
    }

    /// Actions the state machine wants the caller to perform
    package enum Action {
        /// Try to reserve the next direct candidate
        case tryDirectReservation(EnsembleCandidate, remaining: [EnsembleCandidate])

        /// Send pick options to proxy
        case sendPickToProxy([EnsembleCandidate])

        /// Selection completed successfully
        case succeeded(ReservationResult)

        /// Selection failed
        case failed(SelectionError)

        /// Continue waiting (when direct attempts exhausted but pick still pending)
        case waitForProxySelection
    }

    // MARK: - State Machine

    private var state: State = .idle

    /// A pick scale factor below 1 is meaningless; a zero/unset value means "no scaling" (1).
    /// Centralised so the announced-ratio and desired-scale normalisation stay in sync.
    fileprivate static func normalisedScale(_ raw: UInt32) -> UInt32 {
        max(1, raw)
    }

    /// The factor by which this simulated ROPES tries to scale the announced pick ratio. It is
    /// clamped to the proxy-announced `ratioCanScaleTo` and to the number of available candidates.
    /// Defaults to 1 (offer exactly `numProvidedChoices`), preserving historical behaviour.
    private let desiredPickScale: UInt32

    package init(desiredPickScale: UInt32 = 1) {
        self.desiredPickScale = Self.normalisedScale(desiredPickScale)
    }

    /// Begin selection process with constraints and available candidates
    package mutating func start(
        constraints: NegotiateConstraints,
        allCandidates: [EnsembleCandidate],
        workload _: [String: [String]]
    ) -> Action {
        guard case .idle = self.state else {
            let stateDesc = self.state.description
            Self.logger.error("start() called in non-idle state: \(stateDesc)")
            return .failed(.noCandidatesAvailable)
        }

        // Filter candidates that can be used directly (without pick)
        let directCandidates = allCandidates.filter { candidate in
            constraints.isLegalToUseWithoutPick(
                ensembleId: candidate.ensembleId,
                bootId: candidate.bootId,
                rackId: candidate.rackId
            )
        }

        // Select candidates to offer for pick, if that is deemed necessary.
        // For testing purposes with a limited node pool, we artificially
        // prefer non-direct candidates when possible. This ensures tests validate
        // the expected pick flow (offering different ensembles than those already
        // tried) rather than hitting the edge case where the same busy ensemble is offered again.
        // This is a testing optimization to ensure predictable test behavior.
        let pickCandidates: [EnsembleCandidate]
        if let pick = constraints.pick {
            let nonDirectCandidates = allCandidates.filter { candidate in
                !directCandidates.contains(where: { $0.ensembleId == candidate.ensembleId })
            }

            // ROPES may scale the announced ratio: offer numProvidedChoices * s ensembles, where s
            // is bounded by both the proxy-announced ratioCanScaleTo and this simulated ROPES'
            // configured desiredPickScale. The proxy then accepts numSelectedChoices * s of them.
            let scale = min(self.desiredPickScale, pick.ratioCanScaleTo)
            let numToOffer = Int(pick.numProvidedChoices) * Int(scale)
            if nonDirectCandidates.count >= numToOffer {
                // We have enough non-direct candidates, prefer those
                pickCandidates = Array(nonDirectCandidates.prefix(numToOffer))
            } else {
                // Not enough non-direct candidates, use any available candidates
                // (matches ROPES behavior when diversity is limited)
                let numAvailable = min(numToOffer, allCandidates.count)
                pickCandidates = Array(allCandidates.prefix(numAvailable))
            }
        } else {
            pickCandidates = []
        }

        Self.logger.info("""
        Selection started: \(directCandidates.count) direct candidates, \
        \(pickCandidates.count) pick candidates
        """)

        self.state = .ready(
            directCandidates: directCandidates,
            pickCandidates: pickCandidates,
            attemptedDirectCandidates: []
        )

        return self.nextAction()
    }

    /// Record the result of a direct reservation attempt
    internal mutating func recordDirectReservation(
        candidate: EnsembleCandidate,
        token: PCCHarness.UsageTrackedAppEndpoint?,
        workload: [String: [String]]
    ) -> Action {
        switch self.state {
        case .ready(let directCandidates, let pickCandidates, var attemptedDirect):
            if let token {
                // Success
                let result = ReservationResult(
                    candidate: candidate,
                    token: token,
                    workload: workload,
                    source: .direct
                )
                self.state = .succeeded(result)
                Self.logger.info("Direct reservation succeeded: \(candidate.ensembleId)")
                return .succeeded(result)
            } else {
                // Failed - mark as attempted and try next
                attemptedDirect.insert(candidate.ensembleId)
                self.state = .ready(
                    directCandidates: directCandidates,
                    pickCandidates: pickCandidates,
                    attemptedDirectCandidates: attemptedDirect
                )
                Self.logger.debug("Direct reservation failed: \(candidate.ensembleId)")
                return self.nextAction()
            }

        case .awaitingPickOrQueueResolution(
            let sentCandidates,
            let directCandidatesStillTrying,
            let attemptedEnsembles
        ):
            if let token {
                // Success while waiting for proxy
                let result = ReservationResult(
                    candidate: candidate,
                    token: token,
                    workload: workload,
                    source: .direct
                )
                self.state = .succeeded(result)
                Self.logger.info("Direct reservation succeeded while awaiting proxy: \(candidate.ensembleId)")
                return .succeeded(result)
            } else {
                // Failed - remove from still-trying list
                let remaining = directCandidatesStillTrying.filter { $0.ensembleId != candidate.ensembleId }
                // Add to attempted set
                var updatedAttempted = attemptedEnsembles
                updatedAttempted.insert(candidate.ensembleId)

                if remaining.isEmpty {
                    // No more direct candidates, just wait for proxy
                    self.state = .awaitingPickOrQueueResolution(
                        sentCandidates: sentCandidates,
                        directCandidatesStillTrying: [],
                        attemptedEnsembles: updatedAttempted
                    )
                    return .waitForProxySelection
                } else {
                    // Try next direct candidate
                    self.state = .awaitingPickOrQueueResolution(
                        sentCandidates: sentCandidates,
                        directCandidatesStillTrying: remaining,
                        attemptedEnsembles: updatedAttempted
                    )
                    return .tryDirectReservation(remaining[0], remaining: Array(remaining.dropFirst()))
                }
            }

        case .idle, .succeeded, .failed:
            let stateDesc = self.state.description
            Self.logger.error("recordDirectReservation() called in invalid state: \(stateDesc)")
            return .failed(.noCandidatesAvailable)
        }
    }

    /// Record that pick was sent to proxy (transition to awaiting state)
    package mutating func pickSentToProxy(
        candidates: [EnsembleCandidate],
        stillTryingDirect: [EnsembleCandidate],
        attemptedEnsembles: Set<String>
    ) {
        guard case .ready = self.state else {
            let stateDesc = self.state.description
            Self.logger.error("pickSentToProxy() called in non-ready state: \(stateDesc)")
            return
        }

        self.state = .awaitingPickOrQueueResolution(
            sentCandidates: candidates,
            directCandidatesStillTrying: stillTryingDirect,
            attemptedEnsembles: attemptedEnsembles
        )
        Self.logger.info("Pick sent to proxy, awaiting selection")
    }

    /// Record proxy's selection and attempt to reserve it
    internal mutating func recordProxySelection(
        selected: EnsembleCandidate,
        token: PCCHarness.UsageTrackedAppEndpoint?,
        workload: [String: [String]]
    ) -> Action {
        guard case .awaitingPickOrQueueResolution(_, _, let attemptedEnsembles) = self.state else {
            let stateDesc = self.state.description
            Self.logger.error("recordProxySelection() called in non-awaiting state: \(stateDesc)")
            return .failed(.noCandidatesAvailable)
        }

        if attemptedEnsembles.contains(selected.ensembleId) {
            Self.logger.info(
                "Proxy selected ensemble \(selected.ensembleId) that was already attempted - skipping re-attempt. Queueing already in progress."
            )
            self.state = .failed(.proxySelectedUnavailableEnsemble(selected.ensembleId))
            return .failed(.proxySelectedUnavailableEnsemble(selected.ensembleId))
        }

        if let token {
            // Successfully reserved proxy's selection
            let result = ReservationResult(
                candidate: selected,
                token: token,
                workload: workload,
                source: .proxyPick
            )
            self.state = .succeeded(result)
            Self.logger.info("Proxy selection reservation succeeded: \(selected.ensembleId)")
            return .succeeded(result)
        } else {
            // Proxy selected an ensemble we couldn't reserve
            // Queueing is already in progress during the race, so just fail
            self.state = .failed(.proxySelectedUnavailableEnsemble(selected.ensembleId))
            Self.logger
                .info("Proxy selected unavailable ensemble: \(selected.ensembleId). Queueing already in progress.")
            return .failed(.proxySelectedUnavailableEnsemble(selected.ensembleId))
        }
    }

    /// Record that pick protocol failed (proxy didn't respond, sent invalid data, or connection failed)
    package mutating func recordPickProtocolFailed() -> Action {
        guard case .awaitingPickOrQueueResolution = self.state else {
            let stateDesc = self.state.description
            Self.logger.error("recordPickProtocolFailed() called in non-awaiting state: \(stateDesc)")
            return .failed(.noCandidatesAvailable)
        }

        self.state = .failed(.pickProtocolFailed)
        Self.logger.error("Pick protocol failed")
        return .failed(.pickProtocolFailed)
    }

    // MARK: - Private Helpers

    /// Determine next action based on current state
    private func nextAction() -> Action {
        guard case .ready(let directCandidates, let pickCandidates, let attemptedDirect) = state else {
            Self.logger.error("nextAction() called in non-ready state")
            return .failed(.noCandidatesAvailable)
        }

        // Find next unattempted direct candidate
        let remainingDirect = directCandidates.filter { !attemptedDirect.contains($0.ensembleId) }

        let hasDirectToTry = !remainingDirect.isEmpty
        let hasPickToSend = !pickCandidates.isEmpty

        Self.logger.info("""
        nextAction: \(remainingDirect.count) direct remaining, \
        \(pickCandidates.count) pick available, \
        \(attemptedDirect.count) attempted
        """)

        if !hasDirectToTry, !hasPickToSend {
            // Nothing left to try
            Self.logger.info("nextAction: No candidates left")
            return .failed(.noCandidatesAvailable)
        }

        if hasDirectToTry {
            // Try next direct candidate
            let next = remainingDirect[0]
            let remaining = Array(remainingDirect.dropFirst())
            Self.logger.info("nextAction: Try direct \(next.ensembleId) (\(remaining.count) more)")
            return .tryDirectReservation(next, remaining: remaining)
        } else {
            // No direct candidates left, send pick to proxy
            Self.logger.info("nextAction: Send pick with \(pickCandidates.count) candidates")
            return .sendPickToProxy(pickCandidates)
        }
    }

    /// Query current state (for testing/debugging)
    package var currentState: String {
        self.state.description
    }

    /// Query current state details (for orchestrator to access state data during racing)
    internal var currentStateDetails: State {
        self.state
    }
}

// MARK: - Protocol Conversion

extension GatewayEnsembleSelectionStateMachine.NegotiateConstraints {
    /// Extract negotiate constraints from ProtoInvokeProxyInitiate message
    internal init?(proto: PCCHarness.ProtoInvokeProxyInitiate) {
        guard proto.hasNegotiate else {
            return nil
        }

        let negotiate = proto.negotiate

        let trustedEnsembles = negotiate.trustedEnsembles.map { ensemble in
            (ensembleId: ensemble.ensembleID, bootId: ensemble.bootID)
        }

        let trustedRackIds = Array(negotiate.trustedRackIds)
        let freeChoice = negotiate.freeChoice

        let pick: PickParameters? = if negotiate.hasPick {
            PickParameters(
                numProvidedChoices: negotiate.pick.numProvidedChoices,
                numSelectedChoices: negotiate.pick.numSelectedChoices,
                ratioCanScaleTo: negotiate.pick.ratioCanScaleTo
            )
        } else {
            nil
        }

        self.init(
            trustedEnsembles: trustedEnsembles,
            trustedRackIds: trustedRackIds,
            freeChoice: freeChoice,
            pick: pick
        )
    }
}

// MARK: - Service Discovery Helpers

extension GatewayEnsembleSelectionStateMachine {
    /// Gather ensemble candidates from service discovery
    package static func gatherCandidates(
        serviceDiscovery: ServiceDiscoveryAbstraction.ConsumerClientProtocol,
        availableEndpoints: [PCCHarness.ComputeCloudAppEndpoint]
    ) throws -> [EnsembleCandidate] {
        let snapshot = try serviceDiscovery.snapshot()
        Self.logger.info("Service discovery snapshot has \(snapshot.count) entries")

        let ensembles = PCCHarness.PCCNodeManager.gatherEnsemblesFromServiceDiscovery(
            snapshot: snapshot,
            computeEndpoints: availableEndpoints
        )

        // Map to candidates with rack IDs from service discovery
        return ensembles.map { ensemble in
            let matchingEntry = snapshot.first { endpoint, _ in
                endpoint.host == ensemble.endpoint.host && endpoint.port == ensemble.endpoint.port
            }
            let rackId = matchingEntry?.value.rackId

            return EnsembleCandidate(
                ensembleId: ensemble.ensembleId,
                bootId: ensemble.bootId,
                rackId: rackId,
                endpoint: ensemble.endpoint
            )
        }
    }
}
