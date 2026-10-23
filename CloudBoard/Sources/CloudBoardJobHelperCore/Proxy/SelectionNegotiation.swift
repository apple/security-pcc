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

import CloudBoardAttestationDAPI
import CloudBoardCommon
import CloudBoardDomain
import CloudBoardLogging
import Foundation
import os
import Synchronization

/// Rules and state on selecting a worker for a specific sub-request
/// This is closely aligned with the `NegotiateEnsembleChoice` proto
/// since that message is an expression of what is allowed
/// The usage model for this is slightly complex, but this reflects real world complexity
/// of concurrent InvokeProxyInitiate calls happening at once
///
/// This enum provides a namespace
internal enum SelectionNegotiation {
    internal static let logger: Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "SelectionNegotiation"
    )

    /// Reasons it can be valid to pick an ensemble
    /// this is entirely public as it is communicated externally already
    internal struct SelectionValidityReasons: CustomStringConvertible {
        var freeChoice: Bool
        var trustedEnsembles: [EnsembleInstanceId]
        var trustedRacks: [String]
        /// Pick was _advertised_
        var potentialPickNegotiation: PickOptions?
        /// Pick was performed to the point the proxy indicated at least one choice was legal
        var actualPickNegotiation: [EnsembleInstanceId]?

        public var description: String {
            """
            freeChoice: \(self.freeChoice), \
            trustedEnsembles: \(self.trustedEnsembles), \
            trustedRacks: \(self.trustedRacks), \
            potentialPickNegotiation: \(String(describing: self.potentialPickNegotiation)), \
            actualPickNegotiation: \(String(describing: self.actualPickNegotiation))
            """
        }
    }

    /// This represents the overall state that a request is in with respect to the worker sessions is is
    /// asking for and/or has asked for.
    /// We can have multiple "in flight" ``InitiatedNegotiation`` which represent InvokeProxyInitiate calls
    /// that have not yet completed.
    /// These are handled _conservatively_ for example if:
    /// * Only one more pick operation is allowed
    /// * Two worker sessions are requested at the same time
    /// The _first_ gets to indicate it can do pick, the second does not (even if the first doesn't end up
    /// needing the pick).
    /// After the first completes, if the policy enforcement would be fine with performing a pick regardless
    /// of the (legal) outcome of the (still pending) second request, the third would be allowed to do a pick.
    ///
    /// This conservatism is applied on stated behaviour, as well as overall. Using the original example,
    /// if the second request receives a pick negotiation after the first completes, *even if it now would be
    /// legal if the second operation were started now* we do *not* allow it.
    /// What was stated up front on each specific request applies, there are never race conditions to worry
    /// about.
    internal final class WorkerSessionsPrivacyController: Sendable {
        let rules: SelectionNegotiationSetup.Rules

        private struct State {
            var sessionCounter: Int = 0
            // For the avoidance of doubt, while a groupID of nil is considered identical to itself
            // this agrees with the assumptions made in ROPES for older requests without it set at all.
            // The only known use case for this is the use of split FT/ET for inference.
            // The FT phase is not targetable through side channels, and the ET phase starts concurrently
            // so the ET phase gets free choice too.
            var allowFreeChoiceOnSecondSessionForIdenticalGroupID: String? = nil

            var negotiationInProgress: [UUID: InitiatedNegotiation] = [:]

            // ROPES may choose any of these ensembles, reserve it, and hand it to the proxy
            // if it satisfies the primary workload constraints.
            // once trusted it remains trusted
            var trustedEnsembles: Set<EnsembleInstanceId> = []

            // Ensembles advertising this rack id can be consider trusted (ROPES may select and reserve
            // only one and return it to us)
            var trustedRackIds: Set<RackId> = []

            /// once set any attempt to use ``beginNewNegotiation`` will throw
            var terminalError: SelectionNegotiationError? = nil

            var toolCallInvoked: Bool = false
        }

        private let _state = Mutex<State>(State())

        internal init(rules: SelectionNegotiationSetup.Rules) {
            self.rules = rules
        }

        internal func setToolCallInvoked() {
            self._state.withLock {
                $0.toolCallInvoked = true
            }
        }

        // Some operating modes mean we can tolerate not knowing information about the compute nodes,
        // no privacy violation can happen without the data and it makes staggered deployments simpler
        // likely this will simply be removed later for simplicity because we can just assume we always
        // have the information regardless of the mode
        internal var requiresAttestationAppData: Bool {
            return self.rules.operatingMode != .alwaysFreeChoice
        }

        /// The result must be handed back via ``completeNegotiation`` once it is finished with
        /// (success or failure) unless the jobhelper itself is being torn down.
        /// Failure to do so will not result in a privacy violation, but it will significantly hinder
        /// the ability to efficiently request more worker sessions
        internal func beginNewNegotiation(
            groupID: String?,
            reuse: ReuseTargetConstraints?,
            treatAsRestrictedChoice: Bool,
            requestID: String
        ) throws(SelectionNegotiationError) -> InitiatedNegotiation {
            try self._state.withLock { state throws(SelectionNegotiationError) in
                if let error = state.terminalError {
                    fatalError("Attempt to use after terminal error: \(error.publicDescription)")
                }
                // if we hit this ROPES cannot be allowed to do anything that would violate the hard limit
                let potentialTransitiveTrustCountReachedLimit =
                    // trusted so far
                    state.trustedEnsembles.count +
                    // might result in a new trust
                    state.negotiationInProgress.count(where: { $0.value.allowedToAddToTransitiveTrustSet })
                    >= self.rules.maxTrustedEnsembleInstances

                let pick: PickOptions? = if potentialTransitiveTrustCountReachedLimit {
                    nil
                } else {
                    // if pickWhenRestricted is nil we use pick (which may also be nil)
                    // since the intent of pickWhenRestricted is always to make things "easier"
                    // If it's not set it does not imply "do not use pick" it means "use the normal pick"
                    if treatAsRestrictedChoice, self.rules.pickWhenRestricted != nil {
                        self.rules.pickWhenRestricted
                    } else {
                        self.rules.pick
                    }
                }
                let trustedRackIds = potentialTransitiveTrustCountReachedLimit ? nil : state.trustedRackIds
                let freeChoice: Bool
                if potentialTransitiveTrustCountReachedLimit {
                    // even the always freechoice operating mode doesn't stop this,
                    // if someone is testing and wants to avoid this they can force the maximum higher
                    freeChoice = false
                } else if state.toolCallInvoked {
                    /// If an outbound call is made, request is potentially targetable
                    SelectionNegotiation.logger.log(
                        "\(requestID, privacy: .public): Outbound tool-call made during the request, thereby making the request targetable"
                    )
                    freeChoice = false
                } else {
                    switch self.rules.operatingMode {
                    case .disallowed:
                        fatalError("Attempt to use selection negotiation when entirely disallowed")
                    case .alwaysFreeChoice:
                        freeChoice = true
                    case .firstGroupIsFreeChoiceIfNoReuse:
                        // If doing reuse it doesn't matter if this is the first request or not,
                        // this leaks enough information to make it potentially targetable
                        if reuse != nil {
                            freeChoice = false
                        } else if state.sessionCounter == 0 {
                            freeChoice = true
                            precondition(
                                state.allowFreeChoiceOnSecondSessionForIdenticalGroupID == nil,
                                "attempt to set allowFreeChoiceOnSecondSessionForIdenticalGroupID twice"
                            )
                            state.allowFreeChoiceOnSecondSessionForIdenticalGroupID = groupID
                        } else if state.sessionCounter == 1,
                                  groupID == state.allowFreeChoiceOnSecondSessionForIdenticalGroupID {
                            freeChoice = true
                        } else {
                            freeChoice = false
                        }
                    case .assumeTargetable:
                        freeChoice = false
                    }
                    state.sessionCounter += 1
                }
                let negotiation = try InitiatedNegotiation(
                    parent: self,
                    freeChoice: freeChoice,
                    // Once trusted they are always trusted unless they reboot
                    // rewrapping the DEK for an updated attestation is not considered to count
                    trustedEnsembles: state.trustedEnsembles,
                    trustedRackIds: trustedRackIds ?? [],
                    pick: pick
                )
                state.negotiationInProgress[negotiation.id] = negotiation
                return negotiation
            }
        }

        /// Update any state from this negotiation that aids future ones
        /// If the negotiation failed in a terminal way, where this means the system believes it
        /// should terminate the helper and the associated request right now this will throw.
        /// If no further negotiation is possible, but no violations have occurred it will not
        fileprivate func complete(
            negotiation: InitiatedNegotiation,
            action: InitiatedNegotiation.CompletionActions
        ) throws(SelectionNegotiationError) {
            try self._state.withLock { state throws(SelectionNegotiationError) in
                if let terminal = state.terminalError {
                    // nothing else to do really, just stay blocked and throw
                    // no need to throw the new error, any will do
                    throw terminal
                }
                guard state.negotiationInProgress.removeValue(forKey: negotiation.id) != nil else {
                    fatalError("attempt to return \(negotiation.id) when it is unknown to this controller")
                }
                switch action {
                case .noEnsembleSelected:
                    // The accounting for the speculative trust was done by removing it from inProgress
                    // nothing else to do
                    ()
                case .selectedEnsemble(let ensemble, let rack):
                    state.trustedEnsembles.insert(ensemble)
                    if let rack, !rack.isIrrelevant, self.rules.trustingEnsembleImpliesTrustingRack {
                        state.trustedRackIds.insert(rack)
                    }
                case .terminalError(let error):
                    // nothing else to do once we set this
                    state.terminalError = error
                    throw error
                }
            }
        }
    }

    /// This represents what we are about to/are sending to ropes in the context of a single InvokeProxyInitiate
    /// It mutates in response to inbound messages from ROPES.
    /// It is sendable to make it simpler to use, the state transitions are simple and should never actually
    /// race in practice. It is owned by an entity which is Sendable so it's easier this way
    /// This does *not* try to update any information in the parent RequestWorkerSessionPrivacyController
    /// as it mutates until it is completed (successfully or in a failure mode)
    /// At that point it will (without holding any lock) hand itself back to its parent once and only once
    internal final class InitiatedNegotiation: Sendable {
        private enum TerminalStatus {
            /// the negotiation cycle completed as a success
            case selectedSuccessfully(EnsembleInstanceId, RackId?)
            /// Covers anything _legal_ where we didn't get to `selectedSuccessfully`
            /// 1: ROPES couldn't find anything so we abandoned it, this is not a privacy or protocol failure
            /// it's reasonable to not find anything
            /// 2: we/ROPES decided to abandon the whole attempt, or just this makePCCRequest
            case endedWithoutTransitiveTrustChanges
            /// This implies *any* failure to follow the protocol at all, both seemingly malicious
            /// or just message ordering failures. This is not just terminal for this initiate, it's terminal
            /// for all future ones too (including any in flight not yet resolved)
            case protocolViolation(SelectionNegotiationError)
        }

        private enum State {
            // sent/sending the initial negotiation to ropes, it has not responded in anyway yet
            case sentToRopes
            /// ROPES sent a list of choices (which must have been greater than or equal to
            /// ``PickOptions/requireAtLeast(providedChoices:)``) and we specified the ones we would allow
            case negotiating(allowedByProxy: [EnsembleInstanceId])
            /// The negotiation cycle completed, this instance is no longer usable for anything
            /// Any attempt to use it after this is considered a protocol violation with the associated
            /// failure modes
            case completed(status: TerminalStatus)
            /// the result has been accounted for back to the parent controller
            case consumed
        }

        fileprivate enum CompletionActions {
            case noEnsembleSelected
            case selectedEnsemble(EnsembleInstanceId, RackId?)
            case terminalError(SelectionNegotiationError)
        }

        let id = UUID()
        private let parent: WorkerSessionsPrivacyController

        /// IFF true then ROPES can select *any* legal ensemble (that conforms to the constraints of the request)
        /// reserve it, and inform us of the choice.
        private let freeChoice: Bool

        // ROPES may choose any of these ensembles, reserve it, and hand it to the proxy
        // if it satisfies the primary workload constraints.
        private let trustedEnsembles: Set<EnsembleInstanceId>

        // Ensembles advertising these rack_id can be consider trusted (ROPES may select and reserve
        // only one and return it to us)
        // We ensure only relevant rackIds go in here
        private let trustedRackIds: Set<RackId>

        private let pick: PickOptions?

        private let _state: Mutex<State> = .init(.sentToRopes)

        var allowedToAddToTransitiveTrustSet: Bool {
            return self.freeChoice || !self.trustedRackIds.isEmpty || self.pick != nil
        }

        internal init(
            parent: WorkerSessionsPrivacyController,
            freeChoice: Bool,
            trustedEnsembles: Set<EnsembleInstanceId>,
            trustedRackIds: Set<RackId>,
            pick: PickOptions?
        ) throws(SelectionNegotiationError) {
            self.parent = parent
            self.freeChoice = freeChoice
            self.trustedEnsembles = trustedEnsembles
            self.trustedRackIds = trustedRackIds
            precondition(
                trustedRackIds.allSatisfy { !$0.isIrrelevant },
                "Attempt to consider an irrelevant RackId trusted"
            )
            self.pick = pick
            // We do a fail fast here rather than make it all the way to ROPES for it to say "I can't do that"
            guard freeChoice || trustedEnsembles.count > 0 || trustedRackIds.count > 0 || pick != nil else {
                throw SelectionNegotiationError.negotiationWouldDefinitelyFail
            }
        }

        internal var forROPES: Negotiate {
            return Negotiate(
                trustedEnsembles: EnsembleNegotiation(.init(self.trustedEnsembles)),
                trustedRackIds: self.trustedRackIds.map { $0.rackId },
                freeChoice: self.freeChoice,
                pick: self.pick
            )
        }

        /// Called on any definitively terminal state transition to ensure the parent is informed of it
        /// once and only once
        private func onTerminalState(error: SelectionNegotiationError? = nil) throws(SelectionNegotiationError) {
            let action: CompletionActions? = self._state.withLock { state in
                // not matter what we have consume the needed action
                // by the end of this lock
                defer {
                    state = .consumed
                }
                switch state {
                case .sentToRopes, .negotiating:
                    // Means we gave up in some way - nothing important happened
                    // Equivalent to transitioning to .completed(status: .endedWithoutTransitiveTrustChanges)
                    // then consuming it right away
                    return CompletionActions.noEnsembleSelected
                case .completed(status: let status):
                    switch status {
                    case .selectedSuccessfully(let ensemble, let rack):
                        return .selectedEnsemble(ensemble, rack)
                    case .endedWithoutTransitiveTrustChanges:
                        return .noEnsembleSelected
                    case .protocolViolation(let error):
                        return .terminalError(error)
                    }
                case .consumed:
                    return nil
                }
            }
            // now we've released our lock call into the parent (if needed)
            if let action {
                try self.parent.complete(negotiation: self, action: action)
            }
            // never swallow an error (it should have been rethrown by the machinery above, but we make sure)
            if let error {
                throw error
            }
        }

        /// Update the state of ``pick`` based on the provided negotiation cycle from ROPES
        /// If this would violate the allowed operation in some way it will throw (and prevent further use)
        /// Otherwise it returns a (non empty) list of allowed selections
        func pickUpdate(
            providedFromROPES: [EnsembleInstanceId]
        ) throws(SelectionNegotiationError) -> [EnsembleInstanceId] {
            do {
                return try self._state.withLock { state throws(SelectionNegotiationError) in
                    switch state {
                    case .negotiating:
                        let error = SelectionNegotiationError.choicesFromROPESSentMoreThanOnce
                        state = .completed(status: .protocolViolation(error))
                        throw error
                    case .completed:
                        // regardless of the prior completion state it's now a protocol violation
                        // overriding a prior violation is fine, none are recoverable
                        let error = SelectionNegotiationError.attemptToPerformPicksAfterNegotiationEnded
                        state = .completed(status: .protocolViolation(error))
                        throw error
                    case .sentToRopes:
                        guard let pick = self.pick else {
                            let error = SelectionNegotiationError.attemptToPerformPickWhenNotAllowed
                            state = .completed(status: .protocolViolation(error))
                            throw error
                        }
                        // ROPES could provide so many this causes us to crash at various points,
                        // that destroys all state for this request so is fine from a privacy POV.
                        guard providedFromROPES.count >= Int(pick.requiredEnsemblesFromROPES) else {
                            let error = SelectionNegotiationError.choicesFromROPESTooSmall(
                                requiredEnsembles: pick.requiredEnsemblesFromROPES,
                                providedEnsembles: providedFromROPES.count
                            )
                            state = .completed(status: .protocolViolation(error))
                            throw error
                        }
                        // CloudBoard treats EnsembleInstanceIds as case sensitive consistently
                        // throughout the system so there's no issue of sending many differing only by case.
                        let duplicatesByEnsembleId = Dictionary(
                            grouping: providedFromROPES,
                            by: { $0.ensembleId }
                        ).filter { _, ensembleInstances in
                            ensembleInstances.count > 1
                        }
                        guard duplicatesByEnsembleId.count == 0 else {
                            let example = duplicatesByEnsembleId.max(by: { a, b in a.value.count < b.value.count })!
                            let error = SelectionNegotiationError.choicesFromROPESContainDuplicateEnsembles(
                                // get the worst offender as the example
                                examples: example.value
                            )
                            state = .completed(status: .protocolViolation(error))
                            throw error
                        }
                        // passed validation - provide a securely random selection, without replacement
                        // we know this will work cleanly because we prevalidated the PickOptions
                        //
                        // ROPES may scale the announced ratio: if it returns requiredEnsemblesFromROPES * s
                        // ensembles we accept allowedEnsemblesFromProxy * s of them, preserving the ratio.
                        // The scale is bounded by ratioCanScaleTo, so an over-large return is simply capped
                        // (returning fewer is more conservative, never a protocol violation). The earlier
                        // count check guarantees scale >= 1.
                        let scale = min(
                            providedFromROPES.count / pick.requiredEnsemblesFromROPES,
                            pick.ratioCanScaleTo
                        )
                        let choice: [EnsembleInstanceId] = .init(
                            providedFromROPES.shuffled().prefix(
                                pick.allowedEnsemblesFromProxy * scale
                            )
                        )
                        state = .negotiating(allowedByProxy: choice)
                        return choice
                    case .consumed:
                        // no other action needed, it was already consumed
                        throw SelectionNegotiationError.attemptToPerformPicksAfterNegotiationEnded
                    }
                }
            } catch {
                // any error here is terminal - so inform and rethrow
                try self.onTerminalState(error: error)
                throw error
            }
        }

        /// If the selection was in some way illegal (at a PCC level, not from the CloudApp POV)
        /// This will throw. The caller is responsible for terminating the entire request
        /// in this case, but no further transitive trust decisions will be possible either way
        internal func selectionMade(
            ensemble: EnsembleInstanceId,
            validatedRack: RackId
        ) throws {
            let error: SelectionNegotiationError? = self._state.withLock { state in
                do throws(SelectionNegotiationError) {
                    switch state {
                    case .sentToRopes:
                        try validateSelection(ensemble, validatedRack)
                    case .negotiating(allowedByProxy: let allowedByProxy):
                        try validateSelection(ensemble, validatedRack, pickAllows: allowedByProxy)
                    case .completed(let status):
                        // upstream code should be validating no further selection messages are possible
                        // and will fail closer to the problem so just make sure this is terminal
                        fatalError("called selectionMade on a completed instance in state \(status)")
                    case .consumed:
                        fatalError("attempt to perform selectionMade on a consumed negotiation")
                    }
                    // if nothing threw it was a success
                    state = .completed(status: .selectedSuccessfully(ensemble, validatedRack))
                    return nil
                } catch {
                    state = .completed(status: .protocolViolation(error))
                    return error
                }
            }
            try self.onTerminalState(error: error)
        }

        /// Assuming it was legal to make a selection, is the worker legal.
        /// The ensemble (and rack if present) came from the attestation, not from external sources
        private func validateSelection(
            _ ensemble: EnsembleInstanceId,
            _ validatedRack: RackId,
            pickAllows: [EnsembleInstanceId] = []
        ) throws(SelectionNegotiationError) {
            // This function should very clearly and simply articulate every requirement and have 100% code
            // coverage, including all failure cases that are not fatal errors
            // Any state that would be illegal to reach due to prior sense checks should still result in
            // fatalErrors in case that sense check is broken/removed
            if self.freeChoice {
                return
            }
            if self.trustedEnsembles.contains(ensemble) {
                return
            }
            if !validatedRack.isIrrelevant, self.trustedRackIds.contains(validatedRack) {
                precondition(
                    self.allowedToAddToTransitiveTrustSet,
                    "trusted rackids non empty when not allowed to add to transitive trust"
                )
                return
            }
            if pickAllows.contains(ensemble) {
                precondition(
                    self.pick != nil,
                    "pick should be disabled, but somehow pick allowed more ensembles!"
                )
                precondition(
                    self.allowedToAddToTransitiveTrustSet,
                    "pickAllows was used when not allowed to add to transitive trust"
                )
                return
            }
            throw SelectionNegotiationError.selectedNodeWasNotTrusted(
                selected: ensemble,
                allowed: SelectionValidityReasons(
                    freeChoice: self.freeChoice,
                    trustedEnsembles: .init(self.trustedEnsembles),
                    trustedRacks: .init(self.trustedRackIds.map { $0.rackId }),
                    potentialPickNegotiation: self.pick,
                    actualPickNegotiation: pickAllows
                )
            )
        }
    }
}
