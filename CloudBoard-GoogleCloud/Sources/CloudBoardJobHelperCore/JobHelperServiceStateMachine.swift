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

import CloudBoardUtilities
import Synchronization

enum JobHelperServiceStateMachineState: Equatable {
    case idle
    case warmupReceived
    case warmupCompleteSent
    case connectionReceived
    case streaming
    case terminating
    case finished
    case failed(reason: StaticString)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
            (.warmupReceived, .warmupReceived),
            (.warmupCompleteSent, .warmupCompleteSent),
            (.connectionReceived, .connectionReceived),
            (.streaming, .streaming),
            (.terminating, .terminating),
            (.finished, .finished):
            return true
        case (.failed(let lReason), .failed(let rReason)):
            return "\(lReason)" == "\(rReason)"
        default:
            return false
        }
    }
}

enum JobHelperServiceStateMachineAction {
    case doNothing
    case handleFailure(reason: StaticString)
    case disallowedTransition(reason: StaticString)

    func get() throws {
        switch self {
        case .doNothing:
            break
        case .handleFailure(let reason):
            throw JobHelperServiceStateMachineError(reason: reason)
        case .disallowedTransition(let reason):
            fatalError("Disallowed JobHelperService state machine transition: \(reason)")
        }
    }
}

/// Pure state transition logic for ``JobHelperGRPCService``, enforcing the expected message sequence
/// from cloudboardd.
///
/// Expected flow:
/// 1. Receive `warmupContext`
/// 2. Send `warmupComplete`
/// 3. Receive `connectionContext`
/// 4. Receive `requestChunk`* / send `responseChunk`* concurrently
struct JobHelperServiceStateMachineEngine {
    private(set) var state: JobHelperServiceStateMachineState = .idle
}

private protocol InputSignals {}
extension JobHelperServiceStateMachineEngine: InputSignals {
    mutating func receiveWarmupContext() -> JobHelperServiceStateMachineAction {
        switch self.state {
        case .idle:
            self.state = .warmupReceived
            return .doNothing
        case .terminating, .finished, .failed:
            return .doNothing
        case .warmupReceived, .warmupCompleteSent, .connectionReceived, .streaming:
            let reason: StaticString = "warmupContext received in unexpected state"
            self.state = .failed(reason: reason)
            return .handleFailure(reason: reason)
        }
    }

    mutating func receiveConnectionContext() -> JobHelperServiceStateMachineAction {
        switch self.state {
        case .warmupCompleteSent:
            self.state = .connectionReceived
            return .doNothing
        case .idle, .warmupReceived, .connectionReceived, .streaming, .terminating, .finished:
            let reason: StaticString = "connectionContext received in unexpected state"
            self.state = .failed(reason: reason)
            return .handleFailure(reason: reason)
        case .failed:
            return .doNothing
        }
    }

    mutating func receiveRequestChunk() -> JobHelperServiceStateMachineAction {
        switch self.state {
        case .connectionReceived, .streaming:
            self.state = .streaming
            return .doNothing
        case .idle, .warmupReceived, .warmupCompleteSent, .terminating, .finished:
            let reason: StaticString = "requestChunk received before connectionContext"
            self.state = .failed(reason: reason)
            return .handleFailure(reason: reason)
        case .failed:
            return .doNothing
        }
    }

    mutating func receiveTerminate() -> JobHelperServiceStateMachineAction {
        switch self.state {
        case .idle, .warmupReceived, .warmupCompleteSent, .connectionReceived, .streaming:
            self.state = .terminating
            return .doNothing
        case .terminating, .finished, .failed:
            return .doNothing
        }
    }
}

private protocol OutputSignals {}
extension JobHelperServiceStateMachineEngine: OutputSignals {
    mutating func sendWarmupComplete() -> JobHelperServiceStateMachineAction {
        switch self.state {
        case .warmupReceived:
            self.state = .warmupCompleteSent
            return .doNothing
        case .terminating, .finished, .failed:
            return .doNothing
        case .idle, .warmupCompleteSent, .connectionReceived, .streaming:
            return .disallowedTransition(reason: "sendWarmupComplete in unexpected state")
        }
    }

    mutating func sendResponseChunk() -> JobHelperServiceStateMachineAction {
        switch self.state {
        case .streaming, .terminating:
            return .doNothing
        case .failed:
            return .doNothing
        case .idle, .warmupReceived, .warmupCompleteSent, .connectionReceived, .finished:
            return .disallowedTransition(reason: "sendResponseChunk before streaming")
        }
    }

    mutating func sendError() -> JobHelperServiceStateMachineAction {
        switch self.state {
        case .idle, .warmupReceived, .warmupCompleteSent, .connectionReceived, .streaming, .terminating:
            self.state = .failed(reason: "error sent")
            return .doNothing
        case .finished, .failed:
            return .doNothing
        }
    }

    mutating func sendCompleted() -> JobHelperServiceStateMachineAction {
        switch self.state {
        case .streaming, .terminating, .finished, .warmupCompleteSent, .connectionReceived:
            self.state = .finished
            return .doNothing
        case .idle, .warmupReceived:
            // The RPC can be cancelled before any message is processed (`.idle`) or while
            // the cloud app is still warming up (`.warmupReceived`). The writer body still
            // attempts to emit a trailing Completed and tear down cleanly, so funnel
            // through the same transition rather than crashing.
            self.state = .finished
            return .doNothing
        case .failed:
            return .doNothing
        }
    }
}

/// Thread-safe wrapper around ``JobHelperServiceStateMachineEngine``.
package final class JobHelperServiceStateMachine: Sendable {
    private let state: Mutex<JobHelperServiceStateMachineEngine>

    package init() {
        self.state = Mutex(JobHelperServiceStateMachineEngine())
    }

    package var isTerminating: Bool {
        self.state.withLock { engine in
            if case .terminating = engine.state { return true }
            return false
        }
    }

    private func advance(
        _ body: (inout JobHelperServiceStateMachineEngine) -> JobHelperServiceStateMachineAction
    ) throws {
        let action = self.state.withLock { engine in body(&engine) }
        try action.get()
    }

    package func receiveWarmupContext() throws {
        try self.advance { $0.receiveWarmupContext() }
    }

    package func receiveConnectionContext() throws {
        try self.advance { $0.receiveConnectionContext() }
    }

    package func receiveRequestChunk() throws {
        try self.advance { $0.receiveRequestChunk() }
    }

    package func receiveTerminate() throws {
        try self.advance { $0.receiveTerminate() }
    }

    package func sendWarmupComplete() throws {
        try self.advance { $0.sendWarmupComplete() }
    }

    package func sendResponseChunk() throws {
        try self.advance { $0.sendResponseChunk() }
    }

    package func sendError() throws {
        try self.advance { $0.sendError() }
    }

    package func sendCompleted() throws {
        try self.advance { $0.sendCompleted() }
    }
}

package struct JobHelperServiceStateMachineError: Error, ReportableError {
    package let reason: StaticString

    package var publicDescription: String {
        "JobHelperServiceStateMachineError: \(self.reason)"
    }
}
