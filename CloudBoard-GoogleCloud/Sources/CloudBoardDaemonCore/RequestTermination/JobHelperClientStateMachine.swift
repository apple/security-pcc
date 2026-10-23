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

import CloudBoardJobHelperCore
import CloudBoardProtos
import CloudBoardUtilities
import Synchronization

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum JobHelperClientStateMachineState: Sendable {
    enum Identifier: Equatable, Hashable, Sendable {
        case idle
        case warmupSent
        case warmupComplete
        case requestStarted
        case streaming
        case terminating
        case finished
        case failed
    }

    struct RequestContext: Sendable {
        let parameters: Proto_CloudBoard_InvokeWorkloadRequest.Parameters
        let keyHandle: String
        let requestInput: AsyncStream<FinalizableChunk<Data>>
        let responseOutput: AsyncThrowingStream<FinalizableChunk<Data>, any Error>.Continuation
    }

    case idle
    case warmupSent
    case warmupComplete
    case requestStarted(RequestContext)
    case streaming(RequestContext)
    /// Carries the in-flight `RequestContext` (if a request had started) so the response side can still be completed
    /// after an early terminate, e.g. `onResponse` resolving `responseOutput` to deliver cb_jobhelper's `.completed`.
    /// `nil` when terminating before a request started.
    case terminating(RequestContext?)
    case finished
    case failed(reason: StaticString)

    var identifier: Identifier {
        switch self {
        case .idle: .idle
        case .warmupSent: .warmupSent
        case .warmupComplete: .warmupComplete
        case .requestStarted: .requestStarted
        case .streaming: .streaming
        case .terminating: .terminating
        case .finished: .finished
        case .failed: .failed
        }
    }
}

enum JobHelperClientStateMachineAction {
    case doNothing
    case handleFailure(reason: StaticString)
    case disallowedTransition(reason: StaticString)

    func get() throws {
        switch self {
        case .doNothing:
            break
        case .handleFailure(let reason):
            throw JobHelperClientStateMachineError(reason: reason)
        case .disallowedTransition(let reason):
            fatalError("Disallowed JobHelperClient state machine transition: \(reason)")
        }
    }
}

/// Pure state transition logic for the ``JobHelperClient``, enforcing the
/// expected message sequence between cloudboardd and cb_jobhelper.
struct JobHelperClientStateMachineEngine {
    private(set) var state: JobHelperClientStateMachineState = .idle
}

private protocol InputSignals {}
extension JobHelperClientStateMachineEngine: InputSignals {
    mutating func sendWarmupContext() -> JobHelperClientStateMachineAction {
        switch self.state {
        case .idle:
            self.state = .warmupSent
            return .doNothing
        case .terminating, .finished, .failed:
            return .doNothing
        case .warmupSent, .warmupComplete, .requestStarted, .streaming:
            return .disallowedTransition(reason: "sendWarmupContext in unexpected state")
        }
    }

    mutating func startRequest(
        _ context: JobHelperClientStateMachineState.RequestContext
    ) -> JobHelperClientStateMachineAction {
        switch self.state {
        case .warmupComplete:
            self.state = .requestStarted(context)
            return .doNothing
        case .terminating, .finished, .failed:
            return .doNothing
        case .idle, .warmupSent, .requestStarted, .streaming:
            return .disallowedTransition(reason: "startRequest before warmupComplete")
        }
    }

    mutating func sendConnectionContext() -> JobHelperClientStateMachineAction {
        switch self.state {
        case .requestStarted:
            return .doNothing
        case .terminating, .finished, .failed:
            return .doNothing
        case .idle, .warmupSent, .warmupComplete, .streaming:
            return .disallowedTransition(reason: "sendConnectionContext before requestStarted")
        }
    }

    mutating func sendRequestChunk() -> JobHelperClientStateMachineAction {
        switch self.state {
        case .requestStarted(let context):
            self.state = .streaming(context)
            return .doNothing
        case .streaming:
            return .doNothing
        case .terminating, .finished, .failed:
            return .doNothing
        case .idle, .warmupSent, .warmupComplete:
            return .disallowedTransition(reason: "sendRequestChunk in unexpected state")
        }
    }

    mutating func sendTerminate() -> JobHelperClientStateMachineAction {
        switch self.state {
        case .requestStarted(let context), .streaming(let context):
            // Preserve the request context so the response side can still complete after terminate.
            self.state = .terminating(context)
            return .doNothing
        case .idle, .warmupSent, .warmupComplete:
            self.state = .terminating(nil)
            return .doNothing
        case .terminating, .finished, .failed:
            return .doNothing
        }
    }
}

private protocol OutputSignals {}
extension JobHelperClientStateMachineEngine: OutputSignals {
    mutating func receiveWarmupComplete() -> JobHelperClientStateMachineAction {
        switch self.state {
        case .warmupSent:
            self.state = .warmupComplete
            return .doNothing
        case .failed:
            return .doNothing
        case .idle, .warmupComplete, .requestStarted, .streaming, .terminating, .finished:
            let reason: StaticString = "warmupComplete received in unexpected state"
            self.state = .failed(reason: reason)
            return .handleFailure(reason: reason)
        }
    }

    mutating func receiveResponseChunk() -> JobHelperClientStateMachineAction {
        switch self.state {
        case .streaming:
            return .doNothing
        case .failed:
            return .doNothing
        case .idle, .warmupSent, .warmupComplete, .requestStarted, .terminating, .finished:
            let reason: StaticString = "responseChunk received before streaming"
            self.state = .failed(reason: reason)
            return .handleFailure(reason: reason)
        }
    }

    mutating func receiveError() -> JobHelperClientStateMachineAction {
        switch self.state {
        case .idle, .finished:
            let reason: StaticString = "error received in unexpected state"
            self.state = .failed(reason: reason)
            return .handleFailure(reason: reason)
        case .warmupSent, .warmupComplete, .requestStarted, .streaming, .terminating:
            let reason: StaticString = "cb_jobhelper reported error"
            self.state = .failed(reason: reason)
            return .handleFailure(reason: reason)
        case .failed:
            return .doNothing
        }
    }

    mutating func receiveResponseStreamEnd() -> JobHelperClientStateMachineAction {
        switch self.state {
        case .finished, .failed:
            return .doNothing
        case .idle, .warmupSent, .warmupComplete, .requestStarted, .streaming, .terminating:
            let reason: StaticString = "response stream ended without Completed message"
            self.state = .failed(reason: reason)
            return .handleFailure(reason: reason)
        }
    }

    mutating func receiveCompleted() -> JobHelperClientStateMachineAction {
        switch self.state {
        case .streaming, .terminating:
            self.state = .finished
            return .doNothing
        case .failed:
            return .doNothing
        case .idle, .warmupSent, .warmupComplete, .requestStarted, .finished:
            let reason: StaticString = "completed received in unexpected state"
            self.state = .failed(reason: reason)
            return .handleFailure(reason: reason)
        }
    }
}

typealias JobHelperClientRequestContext = JobHelperClientStateMachineState.RequestContext

/// Thread-safe wrapper around ``JobHelperClientStateMachineEngine`` with
/// support for async waiters, following the ``WorkloadHandlerStateMachine`` pattern.
final class JobHelperClientStateMachine: Sendable {
    private enum WaiterContinuation {
        case waiting(CheckedContinuation<JobHelperClientStateMachineState, any Error>)
        case alreadyCancelled
    }

    private struct WrapperState {
        var engine: JobHelperClientStateMachineEngine
        var stateWaiters: [JobHelperClientStateMachineState.Identifier: [UUID: WaiterContinuation]]
    }

    private let state: Mutex<WrapperState>

    init() {
        self.state = Mutex(WrapperState(engine: .init(), stateWaiters: [:]))
    }

    @discardableResult
    func waitUntil(
        state target: JobHelperClientStateMachineState.Identifier
    ) async throws -> JobHelperClientStateMachineState {
        let uuid = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = self.state.withLock {
                    wrapperState
                        -> (
                            CheckedContinuation<JobHelperClientStateMachineState, any Error>,
                            Result<JobHelperClientStateMachineState, any Error>
                        )? in

                    guard target != wrapperState.engine.state.identifier else {
                        return (continuation, .success(wrapperState.engine.state))
                    }
                    var waiters = wrapperState.stateWaiters[target] ?? [:]
                    wrapperState.stateWaiters[target] = nil
                    defer { wrapperState.stateWaiters[target] = waiters }
                    if let existing = waiters.removeValue(forKey: uuid) {
                        switch existing {
                        case .waiting: fatalError("Unexpected .waiting continuation")
                        case .alreadyCancelled: return (continuation, .failure(CancellationError()))
                        }
                    } else {
                        waiters[uuid] = .waiting(continuation)
                    }
                    return nil
                }
                if let (immediateContinuation, result) = immediate {
                    switch result {
                    case .success(let currentState):
                        immediateContinuation.resume(returning: currentState)
                    case .failure(let error):
                        immediateContinuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            let toCancel: CheckedContinuation<JobHelperClientStateMachineState, any Error>? =
                self.state.withLock { wrapperState in
                    let waiters = wrapperState.stateWaiters[target]
                    wrapperState.stateWaiters[target] = nil
                    guard var waiters else {
                        wrapperState.stateWaiters[target] = [uuid: .alreadyCancelled]
                        return nil
                    }
                    defer { wrapperState.stateWaiters[target] = waiters }
                    if let existing = waiters.removeValue(forKey: uuid) {
                        switch existing {
                        case .waiting(let rawContinuation): return rawContinuation
                        case .alreadyCancelled: fatalError("Unexpected .alreadyCancelled")
                        }
                    } else {
                        waiters[uuid] = .alreadyCancelled
                        return nil
                    }
                }
            toCancel?.resume(throwing: CancellationError())
        }
    }

    func throwAfterFailure() throws -> Never {
        try self.state.withLock { wrapperState in
            guard case .failed(let reason) = wrapperState.engine.state else {
                fatalError("getFailure called when not in failed state")
            }
            throw JobHelperClientStateMachineError(reason: reason)
        }
    }

    private func advance(
        _ body: (inout JobHelperClientStateMachineEngine) -> JobHelperClientStateMachineAction
    ) throws {
        struct Exit {
            let waiters: [CheckedContinuation<JobHelperClientStateMachineState, any Error>]
            let stateAfter: JobHelperClientStateMachineState
            let action: JobHelperClientStateMachineAction
        }
        let exit: Exit = self.state.withLock { wrapperState in
            let before = wrapperState.engine.state.identifier
            let action = body(&wrapperState.engine)
            let after = wrapperState.engine.state

            let waiters = Self.extractWaiters(state: &wrapperState, before: before, after: after.identifier)
            return Exit(waiters: waiters, stateAfter: after, action: action)
        }
        for waiter in exit.waiters {
            waiter.resume(returning: exit.stateAfter)
        }
        try exit.action.get()
    }

    private static func extractWaiters(
        state: inout WrapperState,
        before: JobHelperClientStateMachineState.Identifier,
        after: JobHelperClientStateMachineState.Identifier
    ) -> [CheckedContinuation<JobHelperClientStateMachineState, any Error>] {
        guard after != before else { return [] }
        guard let waiters = state.stateWaiters.removeValue(forKey: after) else { return [] }
        var ready = [CheckedContinuation<JobHelperClientStateMachineState, any Error>]()
        var cancelled = [UUID: WaiterContinuation]()
        for (id, waiter) in waiters {
            switch waiter {
            case .waiting(let continuation): ready.append(continuation)
            case .alreadyCancelled: cancelled[id] = waiter
            }
        }
        if !cancelled.isEmpty { state.stateWaiters[after] = cancelled }
        return ready
    }

    func sendWarmupContext() throws {
        try self.advance { $0.sendWarmupContext() }
    }

    func startRequest(_ context: JobHelperClientRequestContext) throws {
        try self.advance { $0.startRequest(context) }
    }

    func sendConnectionContext() throws {
        try self.advance { $0.sendConnectionContext() }
    }

    func sendRequestChunk() throws {
        try self.advance { $0.sendRequestChunk() }
    }

    func receiveWarmupComplete() throws {
        try self.advance { $0.receiveWarmupComplete() }
    }

    func receiveResponseChunk() throws {
        try self.advance { $0.receiveResponseChunk() }
    }

    func receiveError() throws {
        try self.advance { $0.receiveError() }
    }

    func receiveResponseStreamEnd() throws {
        try self.advance { $0.receiveResponseStreamEnd() }
    }

    func receiveCompleted() throws {
        try self.advance { $0.receiveCompleted() }
    }

    func sendTerminate() throws {
        try self.advance { $0.sendTerminate() }
    }
}

struct JobHelperClientStateMachineError: Error, ReportableError {
    let reason: StaticString

    var publicDescription: String {
        "JobHelperClientStateMachineError: \(self.reason)"
    }
}
