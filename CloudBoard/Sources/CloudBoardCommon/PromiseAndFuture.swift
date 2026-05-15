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

import os

final class LockedValueBox<Value: Sendable>: @unchecked Sendable {
    private let _lock: OSAllocatedUnfairLock<Void> = .init()
    private var _value: Value

    var unsafeUnlockedValue: Value {
        get { self._value }
        set { self._value = newValue }
    }

    func lock() {
        self._lock.lock()
    }

    func unlock() {
        self._lock.unlock()
    }

    init(_ value: Value) {
        self._value = value
    }

    func withLockedValue<Result: Sendable>(
        _ body: @Sendable (inout Value) throws -> Result
    ) rethrows -> Result {
        try self._lock.withLock {
            try body(&self._value)
        }
    }
}

// MARK: - Promise

public final class Promise<Value: Sendable, Failure: Error>: Sendable {
    private enum State {
        struct Observer {
            enum State {
                /// observer was cancelled before continuation could be created
                case cancelled
                case waiting(CheckedContinuation<Result<Value, Failure>, Error>)
            }

            var id: Int
            var state: State
        }

        case unfulfilled(
            nextID: Int,
            observers: [Observer]
        )
        case fulfilled(Result<Value, Failure>)
    }

    private enum ResultAction {
        case fulfilled(Result<Value, Failure>)
        case unfulfilled
    }

    private let state = LockedValueBox(State.unfulfilled(nextID: 0, observers: []))

    private let file: String
    private let line: Int
    private let autoFailureIfUnfulfilled: Failure?

    public init(file: String = #fileID, line: Int = #line, autoFailureIfUnfulfilled: Failure? = nil) {
        self.file = file
        self.line = line
        self.autoFailureIfUnfulfilled = autoFailureIfUnfulfilled
    }

    private enum LockResult {
        case fulfilled(Result<Value, Failure>)
        case unfulfilled(continuationID: Int)
    }

    /// throws if calling task is cancelled
    fileprivate var resultWithCancellation: Result<Value, Failure> {
        get async throws {
            let result: LockResult = self.state.withLockedValue { state in
                switch state {
                case .fulfilled(let result):
                    return .fulfilled(result)

                case .unfulfilled(let continuationID, let observers):
                    state = .unfulfilled(nextID: continuationID + 1, observers: observers)
                    return .unfulfilled(continuationID: continuationID)
                }
            }

            switch result {
            case .fulfilled(let result):
                return result
            case .unfulfilled(let continuationID):
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (
                        continuation: CheckedContinuation<Result<Value, Failure>, Error>
                    ) in
                        let result = self.state.withLockedValue { state -> Result<Result<Value, Failure>, Error>? in
                            switch state {
                            case .fulfilled(let result):
                                return .success(result)
                            case .unfulfilled(let nextID, var observers):
                                defer {
                                    state = .unfulfilled(nextID: nextID, observers: observers)
                                }
                                if let index = observers.firstIndex(where: { $0.id == continuationID }) {
                                    let observer = observers[index]
                                    switch observer.state {
                                    case .cancelled:
                                        observers.remove(at: index)
                                        return .failure(CancellationError())
                                    case .waiting:
                                        preconditionFailure("trying to register an observer with the same id twice")
                                    }
                                } else {
                                    observers.append(.init(id: continuationID, state: .waiting(continuation)))
                                    return nil
                                }
                            }
                        }
                        if let result {
                            // we can't resume the continuation while holding the lock or we might otherwise
                            // deadlock
                            // see https://github.com/apple/swift-nio/pull/2558 for more details
                            continuation.resume(with: result)
                        }
                    }
                } onCancel: {
                    let continuationToCancel: CheckedContinuation<Result<Value, Failure>, Error>? = self.state
                        .withLockedValue { state in
                            switch state {
                            case .unfulfilled(let nextID, var observers):
                                defer {
                                    state = .unfulfilled(nextID: nextID, observers: observers)
                                }

                                guard let index = observers.firstIndex(where: { $0.id == continuationID }) else {
                                    observers.append(.init(id: continuationID, state: .cancelled))
                                    return nil
                                }
                                let observer = observers[index]
                                observers.remove(at: index)
                                state = .unfulfilled(nextID: nextID, observers: observers)

                                switch observer.state {
                                case .cancelled:
                                    preconditionFailure("task was cancelled twice")
                                case .waiting(let continuation):
                                    return continuation
                                }
                            case .fulfilled:
                                // already fulfilled, nothing to do
                                return nil
                            }
                        }
                    // we can't resume the continuation while holding the lock or we might otherwise
                    // deadlock
                    // see https://github.com/apple/swift-nio/pull/2558 for more details
                    continuationToCancel?.resume(throwing: CancellationError())
                }
            }
        }
    }

    fileprivate var result: Result<Value, Failure> {
        get async {
            self.state.lock()

            switch self.state.unsafeUnlockedValue {
            case .fulfilled(let result):
                defer { self.state.unlock() }
                return result

            case .unfulfilled(let continuationID, var observers):
                // force try safe because we never cancel the continuation
                return try! await withCheckedThrowingContinuation { (
                    continuation: CheckedContinuation<Result<Value, Failure>, Error>
                ) in
                    observers.append(.init(id: continuationID, state: .waiting(continuation)))
                    self.state.unsafeUnlockedValue = .unfulfilled(nextID: continuationID + 1, observers: observers)
                    self.state.unlock()
                }
            }
        }
    }

    public func fulfil(with result: Result<Value, Failure>) {
        let observers = self.state.withLockedValue { state in
            switch state {
            case .fulfilled(let oldResult):
                fatalError("tried to fulfil Promise that is already fulfilled to \(oldResult). New result: \(result)")
            case .unfulfilled(_, let observers):
                state = .fulfilled(result)
                // we can't resume the continuation while holding the lock or we might otherwise deadlock
                // see https://github.com/apple/swift-nio/pull/2558 for more details
                return observers
            }
        }
        for observer in observers {
            switch observer.state {
            case .waiting(let continuation):
                continuation.resume(returning: result)
            case .cancelled:
                break
            }
        }
    }

    deinit {
        // no race here, since this is in deinit
        let unfulfilled =
            self.state.withLockedValue {
                switch $0 {
                case .fulfilled:
                    return false
                case .unfulfilled:
                    return true
                }
            }
        if unfulfilled {
            if let autoFailureIfUnfulfilled {
                self.fail(with: autoFailureIfUnfulfilled)
            } else {
                fatalError("unfulfilled Promise leaked at \(file):\(line)")
            }
        }
    }
}

extension Promise {
    public func succeed(with value: Value) {
        self.fulfil(with: .success(value))
    }

    public func fail(with error: Failure) {
        self.fulfil(with: .failure(error))
    }
}

extension Promise where Value == Void {
    public func succeed() {
        self.fulfil(with: .success(()))
    }
}

extension Promise where Value == Void {
    public static func successful<Err>() -> Promise<Value, Err> {
        let promise = Promise<Void, Err>()
        promise.succeed()
        return promise
    }
}

// MARK: - Future

public struct Future<Value: Sendable, Failure: Error>: Sendable {
    private let promise: Promise<Value, Failure>

    public init(_ promise: Promise<Value, Failure>) {
        self.promise = promise
    }

    public var result: Result<Value, Failure> {
        get async {
            await self.promise.result
        }
    }

    public var resultWithCancellation: Result<Value, Failure> {
        get async throws {
            try await self.promise.resultWithCancellation
        }
    }
}

extension Future {
    public var value: Value {
        get async throws {
            try await self.result.get()
        }
    }

    public var valueWithCancellation: Value {
        get async throws {
            try await self.resultWithCancellation.get()
        }
    }
}

extension Future where Failure == Never {
    public var value: Value {
        get async {
            await self.result.get()
        }
    }
}

extension Result where Failure == Never {
    public func get() -> Success {
        switch self {
        case .success(let success):
            return success
        }
    }
}
