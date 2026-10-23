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

import CloudBoardJobCore
import CloudBoardProtos
import CloudBoardUtilities
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum WorkloadHandlerStateMachineState: Sendable {
    enum Identifier: Equatable & Hashable & Sendable {
        case started
        case warmupStarted
        case warmupCompleted
        case clientConnectionStarted
        case requestStarted
        case requestFinishedSuccessfully
        case abandoned
    }

    struct ClientConnection {
        let parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters
        let input: AsyncStream<Data>
        let output: AsyncThrowingStream<Data, any Error>.Continuation
        let opaqueCryptoMaterialProvider: @Sendable () async throws -> [OpaqueCryptoMaterial]
    }

    case started
    case warmupStarted
    case warmupCompleted
    case clientConnectionStarted(ClientConnection)
    case requestStarted(ClientConnection)
    case requestFinishedSuccessfully
    case abandoned

    var identifier: Identifier {
        switch self {
        case .started:
            return .started
        case .warmupStarted:
            return .warmupStarted
        case .warmupCompleted:
            return .warmupCompleted
        case .clientConnectionStarted:
            return .clientConnectionStarted
        case .requestStarted:
            return .requestStarted
        case .requestFinishedSuccessfully:
            return .requestFinishedSuccessfully
        case .abandoned:
            return .abandoned
        }
    }

    var continuation: (AsyncThrowingStream<Data, any Error>.Continuation)? {
        switch self {
        case .clientConnectionStarted(let clientConnection), .requestStarted(let clientConnection):
            return clientConnection.output
        case .started, .warmupStarted, .warmupCompleted, .requestFinishedSuccessfully, .abandoned:
            return nil
        }
    }
}
typealias ClientConnectionState = WorkloadHandlerStateMachineState.ClientConnection

enum WorkloadHandlerStateMachineAction {
    case doNothing
    case handleFailure(reason: StaticString)
    case finishOutputSuccessfully
    case finishOutputAbandoning(throwing: (any Error)? = nil)
    case disallowedTransition

    // For output signal wrappers (completeWarmup, finishRequestSuccessfully).
    // .finishOutput* cases are expected — advance() has already handled the continuation.
    func getOutputSignal() throws {
        switch self {
        case .doNothing, .finishOutputSuccessfully, .finishOutputAbandoning:
            break
        case .handleFailure(let reason):
            throw WorkloadHandlerStateMachineError(reason: reason)
        case .disallowedTransition:
            fatalError("Disallowed state machine transition")
        }
    }

    // For input signal wrappers (startWarmup, start(clientConnection:), startRequest).
    // .finishOutput* cases are structurally impossible — treat as failure if they ever appear.
    func getInputSignal() throws {
        switch self {
        case .doNothing:
            break
        case .handleFailure(let reason):
            throw WorkloadHandlerStateMachineError(reason: reason)
        case .disallowedTransition:
            fatalError("Disallowed state machine transition")
        case .finishOutputSuccessfully:
            throw WorkloadHandlerStateMachineError(reason: "finishOutputSuccessfully returned for input signal")
        case .finishOutputAbandoning:
            throw WorkloadHandlerStateMachineError(reason: "finishOutputAbandoning returned for input signal")
        }
    }
}

struct WorkloadHandlerStateMachineEngine: Sendable {
    fileprivate var state: WorkloadHandlerStateMachineState

    package init() {
        self.state = .started
    }

    var isAbandoned: Bool { state.identifier == .abandoned }
}

private protocol InputSignals {}
extension WorkloadHandlerStateMachineEngine: InputSignals {
    mutating func startWarmup() -> WorkloadHandlerStateMachineAction {
        switch self.state {
        case .started:
            self.state = .warmupStarted
            return .doNothing

        case .warmupStarted,
            .warmupCompleted,
            .clientConnectionStarted,
            .requestStarted,
            .requestFinishedSuccessfully:
            return .disallowedTransition

        case .abandoned:
            return .doNothing
        }
    }

    mutating func start(
        clientConnection: ClientConnectionState
    ) -> WorkloadHandlerStateMachineAction {
        switch self.state {
        case .warmupCompleted:
            self.state = .clientConnectionStarted(clientConnection)
            return .doNothing

        case .started,
            .warmupStarted,
            .clientConnectionStarted,
            .requestStarted,
            .requestFinishedSuccessfully:
            return .disallowedTransition

        case .abandoned:
            return .doNothing
        }
    }

    mutating func startRequest() -> WorkloadHandlerStateMachineAction {
        switch self.state {
        case .clientConnectionStarted(let clientConnection):
            self.state = .requestStarted(clientConnection)
            return .doNothing

        case .started,
            .warmupStarted,
            .warmupCompleted,
            .requestStarted,
            .requestFinishedSuccessfully:
            return .disallowedTransition

        case .abandoned:
            return .doNothing
        }
    }

}

private protocol OutputSignals {}
extension WorkloadHandlerStateMachineEngine: OutputSignals {
    mutating func completeWarmup() -> WorkloadHandlerStateMachineAction {
        switch self.state {
        case .warmupStarted:
            self.state = .warmupCompleted
            return .doNothing

        case .started,
            .warmupCompleted,
            .clientConnectionStarted,
            .requestStarted,
            .requestFinishedSuccessfully:
            let reason: StaticString = "warmupCompleted when not waiting for it"
            self.state = .abandoned
            return .handleFailure(reason: reason)

        case .abandoned:
            return .doNothing
        }
    }

    mutating func finishRequestSuccessfully() -> WorkloadHandlerStateMachineAction {
        switch self.state {
        case .requestStarted:
            self.state = .requestFinishedSuccessfully
            return .finishOutputSuccessfully

        case .clientConnectionStarted,
            .started,
            .warmupStarted,
            .warmupCompleted:
            let reason: StaticString = "finishRequestSuccessfully in an unexpected state"
            self.state = .abandoned
            return .handleFailure(reason: reason)

        case .requestFinishedSuccessfully,
            .abandoned:
            return .doNothing
        }
    }
}

private protocol AbandonSignals {}
extension WorkloadHandlerStateMachineEngine: AbandonSignals {
    mutating func abandon(throwing error: (any Error)? = nil) -> WorkloadHandlerStateMachineAction {
        switch self.state {
        case .started,
            .warmupStarted,
            .warmupCompleted:
            self.state = .abandoned
            return .doNothing

        case .clientConnectionStarted,
            .requestStarted:
            self.state = .abandoned
            return .finishOutputAbandoning(throwing: error)

        case .requestFinishedSuccessfully,
            .abandoned:
            return .doNothing
        }
    }
}

final class WorkloadHandlerStateMachine: Sendable {
    enum Continuation {
        case waiting(CheckedContinuation<WorkloadHandlerStateMachineState, any Error>)
        case alreadyCancelled
    }
    struct State {
        var engine: WorkloadHandlerStateMachineEngine
        var stateWaiters: [WorkloadHandlerStateMachineState.Identifier: [UUID: Continuation]]
    }

    let state: Mutex<State>

    init() {
        self.state = Mutex(
            State(
                engine: WorkloadHandlerStateMachineEngine(),
                stateWaiters: [:]
            )
        )
    }

    @discardableResult
    func waitUntil(
        state stateBeingWaitedFor: WorkloadHandlerStateMachineState.Identifier
    ) async throws -> WorkloadHandlerStateMachineState {
        let uuid = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let possibleImmediateContinuation:
                    (
                        CheckedContinuation<WorkloadHandlerStateMachineState, any Error>,
                        Result<WorkloadHandlerStateMachineState, any Error>
                    )?

                possibleImmediateContinuation = self.state.withLock { state in
                    guard stateBeingWaitedFor != state.engine.state.identifier else {
                        return (continuation, .success(state.engine.state))
                    }
                    var waiters = state.stateWaiters[stateBeingWaitedFor] ?? [:]
                    state.stateWaiters[stateBeingWaitedFor] = nil  // Prevent CoW
                    defer {
                        state.stateWaiters[stateBeingWaitedFor] = waiters
                    }
                    if let existingMarker = waiters.removeValue(forKey: uuid) {
                        switch existingMarker {
                        case .waiting:
                            fatalError("How did we get a `.waiting` continuation?")
                        case .alreadyCancelled:
                            return (continuation, .failure(CancellationError()))
                        }
                    } else {
                        waiters[uuid] = .waiting(continuation)
                    }
                    return nil
                }

                if let (immediateContinuation, action) = possibleImmediateContinuation {
                    switch action {
                    case .success(let currentState):
                        immediateContinuation.resume(returning: currentState)
                    case .failure(let error):
                        immediateContinuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            let possibleContinuation: CheckedContinuation<WorkloadHandlerStateMachineState, any Error>?
            possibleContinuation = self.state.withLock { state in
                let waiters = state.stateWaiters[stateBeingWaitedFor]
                state.stateWaiters[stateBeingWaitedFor] = nil  // Anti-CoW
                guard var waiters else {
                    // It's possible that cancellation races the `withCheckedThrowingContinuation` logic, to handle this, put in marker with the selected UUID, but nil continuation
                    state.stateWaiters[stateBeingWaitedFor] = [uuid: .alreadyCancelled]
                    return nil
                }

                defer {
                    // We've `nil`-ified the waiters above, for anti-CoW. Catch-all put it back
                    state.stateWaiters[stateBeingWaitedFor] = waiters
                }
                if let continuation = waiters.removeValue(forKey: uuid) {
                    switch continuation {
                    case .waiting(let rawContinuation):
                        return rawContinuation
                    case .alreadyCancelled:
                        fatalError("How did we get an `.alreadyCancelled` continuation?")
                    }
                } else {
                    // As above, we're racing `withCheckedThrowingContinuation`
                    waiters[uuid] = .alreadyCancelled
                    return nil
                }

            }
            if let continuation = possibleContinuation {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func _lockedExtractWaiters(
        state: inout State,
        engineStateBefore: WorkloadHandlerStateMachineState.Identifier,
        engineStateAfter: WorkloadHandlerStateMachineState.Identifier
    ) -> [CheckedContinuation<WorkloadHandlerStateMachineState, any Error>] {
        guard engineStateAfter != engineStateBefore else {
            // No state change, there should be noone to notify (`waitUntil(state:)` only adds a waiter if the current state is different to the one to be waited for
            assert(
                {
                    guard let waiters = state.stateWaiters[engineStateAfter] else {
                        // We're expecting no waiters, nil is fine
                        return true
                    }
                    // Ignore `.alreadyCancelled`
                    return waiters.first(where: {
                        switch $0.value {
                        case .waiting:
                            return true
                        case .alreadyCancelled:
                            return false
                        }
                    }) == nil
                }()
            )
            return []
        }

        // Extract all waiters waiting to be notified when engine exits a given state
        // However, leave `.alreadyCancelled` markers. These are used to resolve the short race window between `withTaskCancellationHandler` and `withCheckedThrowingContinuation` in `waitUntil(state:)`
        let waiters = state.stateWaiters.removeValue(forKey: engineStateAfter)
        guard let waiters else {
            return []
        }
        var actuallyWaiting = [CheckedContinuation<WorkloadHandlerStateMachineState, any Error>]()
        var alreadyCancelled = [UUID: Continuation]()
        for waiter in waiters {
            switch waiter.value {
            case .waiting(let rawContinuation):
                actuallyWaiting.append(rawContinuation)
            case .alreadyCancelled:
                alreadyCancelled[waiter.key] = waiter.value
            }
        }
        state.stateWaiters[engineStateAfter] = alreadyCancelled

        return actuallyWaiting
    }

    private func advance(
        _ body: (inout WorkloadHandlerStateMachineEngine) -> WorkloadHandlerStateMachineAction
    ) -> WorkloadHandlerStateMachineAction {

        struct Exit {
            let waiters: [CheckedContinuation<WorkloadHandlerStateMachineState, any Error>]
            let engineStateAfter: WorkloadHandlerStateMachineState
            let action: WorkloadHandlerStateMachineAction
            let previousContinuation: (AsyncThrowingStream<Data, any Error>.Continuation)?
        }
        let exit: Exit = self.state.withLock { state in
            let engineStateBefore = state.engine.state
            let previousContinuation = engineStateBefore.continuation
            let action = body(&state.engine)
            let engineStateAfter = state.engine.state

            let waiters = _lockedExtractWaiters(
                state: &state,
                engineStateBefore: engineStateBefore.identifier,
                engineStateAfter: engineStateAfter.identifier
            )

            return .init(
                waiters: waiters,
                engineStateAfter: engineStateAfter,
                action: action,
                previousContinuation: previousContinuation
            )
        }

        for waiter in exit.waiters {
            waiter.resume(returning: exit.engineStateAfter)
        }

        switch exit.action {
        case .finishOutputSuccessfully:
            exit.previousContinuation?.finish()
        case .finishOutputAbandoning(let error):
            if let error {
                exit.previousContinuation?.finish(throwing: error)
            } else {
                exit.previousContinuation?.finish()
            }
        case .handleFailure(let reason):
            exit.previousContinuation?.finish(throwing: WorkloadHandlerStateMachineError(reason: reason))
        case .doNothing, .disallowedTransition:
            break  // no continuation side effect; callers inspect the action (e.g. via action.get())
        }

        return exit.action
    }
}

extension WorkloadHandlerStateMachine {
    func startWarmup() throws {
        let out = self.advance { engine in engine.startWarmup() }
        try out.getInputSignal()
    }

    func completeWarmup() throws {
        let out = self.advance { engine in
            engine.completeWarmup()
        }
        try out.getOutputSignal()
    }

    func start(clientConnection: ClientConnectionState) throws {
        let out = self.advance { engine in engine.start(clientConnection: clientConnection) }
        try out.getInputSignal()
    }

    func startRequest() throws {
        let out = self.advance { engine in engine.startRequest() }
        try out.getInputSignal()
    }

    func finishRequestSuccessfully() throws {
        let out = self.advance { engine in
            engine.finishRequestSuccessfully()
        }
        try out.getOutputSignal()
    }

    func abandon(throwing error: (any Error)? = nil) {
        _ = self.advance { engine in
            engine.abandon(throwing: error)
        }
    }

    var isAbandoned: Bool {
        self.state.withLock { $0.engine.state.identifier == .abandoned }
    }

    var isRequestFinishedSuccessfully: Bool {
        self.state.withLock { $0.engine.state.identifier == .requestFinishedSuccessfully }
    }
}

struct WorkloadHandlerStateMachineError: Error, PCCResponseStatusTransformable {
    let reason: StaticString
    var pccResponseStatus: PCCResponseStatus { .internalError("\(self.reason)") }
}

extension WorkloadHandlerStateMachineError: ReportableError {
    var publicDescription: String {
        "WorkloadHandlerStateMachineError: \(self.reason)"
    }
}
