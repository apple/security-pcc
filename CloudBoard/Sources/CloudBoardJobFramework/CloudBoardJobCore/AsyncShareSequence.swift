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

// Adapted from swift-async-algorithms 1.1.0 (Apache License v2.0)
// https://github.com/apple/swift-async-algorithms
//
// Copied here because the vendored swift-async-algorithms (1.0.4) predates
// AsyncShareSequence, and upgrading to 1.1.0 causes a dependency diamond
// with swift-collections (DequeModule) that the Xcode project can't resolve.
//
// Changes from the original:
//   - Replaced `import DequeModule` / `Deque<Element>` with `[Element]`
//   - Inlined `AsyncBufferSequencePolicy` (was in a separate file)
//   - Removed `@available(AsyncAlgorithms ...)` custom availability annotations
//   - Added `package` access where needed for cross-module use

#if compiler(>=6.2)

internal import Synchronization

// MARK: - AsyncBufferSequencePolicy (inlined from Buffer/AsyncBufferSequence.swift)

package struct AsyncBufferSequencePolicy: Sendable {
    enum _Policy {
        case bounded(Int)
        case unbounded
        case bufferingNewest(Int)
        case bufferingOldest(Int)
    }

    let policy: _Policy

    package static func bounded(_ limit: Int) -> Self {
        precondition(limit >= 0, "The limit should be positive or equal to 0.")
        return Self(policy: .bounded(limit))
    }

    package static var unbounded: Self {
        return Self(policy: .unbounded)
    }

    package static func bufferingLatest(_ limit: Int) -> Self {
        precondition(limit >= 0, "The limit should be positive or equal to 0.")
        return Self(policy: .bufferingNewest(limit))
    }

    package static func bufferingOldest(_ limit: Int) -> Self {
        precondition(limit >= 0, "The limit should be positive or equal to 0.")
        return Self(policy: .bufferingOldest(limit))
    }
}

// MARK: - .share() extension

extension AsyncSequence
where Element: Sendable, Self: SendableMetatype, AsyncIterator: SendableMetatype {
    package func share(
        bufferingPolicy: AsyncBufferSequencePolicy = .bounded(1)
    ) -> some AsyncSequence<Element, Failure> & Sendable {
        nonisolated(unsafe) let iterator = makeAsyncIterator()
        return AsyncShareSequence<Self>(
            {
                iterator
            },
            bufferingPolicy: bufferingPolicy
        )
    }
}

// MARK: - AsyncShareSequence

package struct AsyncShareSequence<Base: AsyncSequence>: Sendable
where Base.Element: Sendable, Base: SendableMetatype, Base.AsyncIterator: SendableMetatype {
    final class Side {
        struct State {
            var continuation: UnsafeContinuation<Result<Element?, Failure>, Never>?
            var position = 0

            func offset(_ adjustment: Int) -> State {
                State(continuation: self.continuation, position: self.position - adjustment)
            }
        }

        let iteration: Iteration
        let id: Int

        init(_ iteration: Iteration) {
            self.iteration = iteration
            self.id = iteration.registerSide()
        }

        deinit {
            iteration.unregisterSide(id)
        }

        func next(isolation actor: isolated (any Actor)?) async throws(Failure) -> Element? {
            try await self.iteration.next(isolation: actor, id: self.id)
        }
    }

    final class Iteration: Sendable {
        enum IteratingTask {
            case pending(@Sendable () -> sending Base.AsyncIterator)
            case starting
            case running(Task<Void, Never>)
            case cancelled

            var isStarting: Bool {
                switch self {
                case .starting: true
                case .pending, .running, .cancelled: false
                }
            }

            func cancel() {
                switch self {
                case .running(let task):
                    task.cancel()
                case .pending, .starting, .cancelled:
                    break
                }
            }
        }

        struct State: Sendable {
            enum StoragePolicy: Sendable {
                case unbounded
                case bufferingOldest(Int)
                case bufferingNewest(Int)
            }

            var generation = 0
            var sides = [Int: Side.State]()
            var iteratingTask: IteratingTask
            private(set) var buffer = [Element]()
            private(set) var finished = false
            private(set) var failure: Failure?
            var cancelled = false
            var limit: UnsafeContinuation<Bool, Never>?
            var demand: UnsafeContinuation<Void, Never>?

            let storagePolicy: StoragePolicy

            init(
                _ iteratorFactory: @escaping @Sendable () -> sending Base.AsyncIterator,
                bufferingPolicy: AsyncBufferSequencePolicy
            ) {
                self.iteratingTask = .pending(iteratorFactory)
                switch bufferingPolicy.policy {
                case .bounded: self.storagePolicy = .unbounded
                case .bufferingOldest(let bound): self.storagePolicy = .bufferingOldest(bound)
                case .bufferingNewest(let bound): self.storagePolicy = .bufferingNewest(bound)
                case .unbounded: self.storagePolicy = .unbounded
                }
            }

            mutating func trimBuffer() {
                if let minimumIndex = sides.values.map({ $0.position }).min(), minimumIndex > 0 {
                    self.buffer.removeFirst(minimumIndex)
                    self.sides = self.sides.mapValues {
                        $0.offset(minimumIndex)
                    }
                }
            }

            private mutating func _emit<T>(
                _ value: T,
                limit: Int
            ) -> (T, UnsafeContinuation<Bool, Never>?, UnsafeContinuation<Void, Never>?, Bool) {
                let belowLimit = self.buffer.count < limit || limit == 0
                defer {
                    if belowLimit {
                        self.limit = nil
                    }
                    demand = nil
                }
                guard case .cancelled = self.iteratingTask else {
                    return (value, belowLimit ? self.limit : nil, self.demand, false)
                }
                return (value, belowLimit ? self.limit : nil, self.demand, true)
            }

            mutating func emit<T>(
                _ value: T,
                limit: Int?
            ) -> (T, UnsafeContinuation<Bool, Never>?, UnsafeContinuation<Void, Never>?, Bool) {
                return self._emit(value, limit: limit ?? .max)
            }

            mutating func enqueue(_ element: Element) {
                let count = self.buffer.count

                switch self.storagePolicy {
                case .unbounded:
                    self.buffer.append(element)
                case .bufferingOldest(let limit):
                    if count < limit {
                        self.buffer.append(element)
                    }
                case .bufferingNewest(let limit):
                    if count < limit {
                        self.buffer.append(element)
                    } else if count > 0 {
                        self.buffer.removeFirst()
                        self.buffer.append(element)
                    }
                }
            }

            mutating func finish() {
                self.finished = true
            }

            mutating func fail(_ error: Failure) {
                self.finished = true
                self.failure = error
            }
        }

        let state: Mutex<State>
        let limit: Int?

        init(
            _ iteratorFactory: @escaping @Sendable () -> sending Base.AsyncIterator,
            bufferingPolicy: AsyncBufferSequencePolicy
        ) {
            self.state = Mutex(State(iteratorFactory, bufferingPolicy: bufferingPolicy))
            switch bufferingPolicy.policy {
            case .bounded(let limit):
                self.limit = limit
            default:
                self.limit = nil
            }
        }

        func cancel() {
            let (task, limitContinuation, demand, cancelled) = self.state.withLock {
                state -> (IteratingTask?, UnsafeContinuation<Bool, Never>?, UnsafeContinuation<Void, Never>?, Bool) in
                guard state.sides.count == 0 else {
                    state.cancelled = true
                    return state.emit(nil, limit: self.limit)
                }
                defer {
                    state.iteratingTask = .cancelled
                    state.cancelled = true
                }
                return state.emit(state.iteratingTask, limit: self.limit)
            }
            task?.cancel()
            limitContinuation?.resume(returning: cancelled)
            demand?.resume()
        }

        func registerSide() -> Int {
            self.state.withLock { state in
                defer { state.generation += 1 }
                state.sides[state.generation] = Side.State()
                return state.generation
            }
        }

        func unregisterSide(_ id: Int) {
            let (side, continuation, cancelled, iteratingTaskToCancel) = self.state.withLock {
                state -> (Side.State?, UnsafeContinuation<Bool, Never>?, Bool, IteratingTask?) in
                let side = state.sides.removeValue(forKey: id)
                state.trimBuffer()
                let cancelRequested = state.sides.count == 0 && state.cancelled
                guard let limit, state.buffer.count < limit else {
                    guard case .cancelled = state.iteratingTask else {
                        defer {
                            if cancelRequested {
                                state.iteratingTask = .cancelled
                            }
                        }
                        return (side, nil, false, cancelRequested ? state.iteratingTask : nil)
                    }
                    return (side, nil, true, nil)
                }
                defer { state.limit = nil }
                guard case .cancelled = state.iteratingTask else {
                    defer {
                        if cancelRequested {
                            state.iteratingTask = .cancelled
                        }
                    }
                    return (side, state.limit, false, cancelRequested ? state.iteratingTask : nil)
                }
                return (side, state.limit, true, nil)
            }
            if let continuation {
                continuation.resume(returning: cancelled)
            }
            if let side {
                side.continuation?.resume(returning: .success(nil))
            }
            if let iteratingTaskToCancel {
                iteratingTaskToCancel.cancel()
            }
        }

        func iterate() async -> Bool {
            if let limit {
                let cancelled = await withUnsafeContinuation { (continuation: UnsafeContinuation<Bool, Never>) in
                    let (resume, cancelled) = self.state.withLock { state -> (UnsafeContinuation<Bool, Never>?, Bool) in
                        guard state.buffer.count >= limit else {
                            assert(state.limit == nil)
                            guard case .cancelled = state.iteratingTask else {
                                return (continuation, false)
                            }
                            return (continuation, true)
                        }
                        state.limit = continuation
                        guard case .cancelled = state.iteratingTask else {
                            return (nil, false)
                        }
                        return (nil, true)
                    }
                    if let resume {
                        resume.resume(returning: cancelled)
                    }
                }
                if cancelled {
                    return false
                }
            }

            await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                let hasPendingDemand = self.state.withLock { state in
                    for (_, side) in state.sides {
                        if side.continuation != nil {
                            return true
                        }
                    }
                    state.demand = continuation
                    return false
                }
                if hasPendingDemand {
                    continuation.resume()
                }
            }
            return self.state.withLock { state in
                switch state.iteratingTask {
                case .cancelled:
                    return false
                default:
                    return true
                }
            }
        }

        func cancel(id: Int) {
            self.unregisterSide(id)
        }

        struct Resumption {
            let continuation: UnsafeContinuation<Result<Element?, Failure>, Never>
            let result: Result<Element?, Failure>

            func resume() {
                self.continuation.resume(returning: self.result)
            }
        }

        func emit(_ result: Result<Element?, Failure>) {
            let (resumptions, limitContinuation, demandContinuation, cancelled) = self.state.withLock {
                state -> ([Resumption], UnsafeContinuation<Bool, Never>?, UnsafeContinuation<Void, Never>?, Bool) in
                var resumptions = [Resumption]()
                switch result {
                case .success(let element):
                    if let element {
                        state.enqueue(element)
                    } else {
                        state.finish()
                    }
                case .failure(let failure):
                    state.fail(failure)
                }
                for (id, side) in state.sides {
                    if let continuation = side.continuation {
                        if side.position < state.buffer.count {
                            resumptions.append(
                                Resumption(
                                    continuation: continuation, result: .success(state.buffer[side.position])
                                )
                            )
                            state.sides[id]?.position += 1
                            state.sides[id]?.continuation = nil
                        } else if state.finished {
                            state.sides[id]?.continuation = nil
                            if let failure = state.failure {
                                resumptions.append(Resumption(continuation: continuation, result: .failure(failure)))
                            } else {
                                resumptions.append(Resumption(continuation: continuation, result: .success(nil)))
                            }
                        }
                    }
                }
                state.trimBuffer()
                return state.emit(resumptions, limit: self.limit)
            }

            if let limitContinuation {
                limitContinuation.resume(returning: cancelled)
            }
            if let demandContinuation {
                demandContinuation.resume()
            }
            for resumption in resumptions {
                resumption.resume()
            }
        }

        private func nextIteration(
            _ id: Int
        ) async -> Result<AsyncShareSequence<Base>.Element?, AsyncShareSequence<Base>.Failure> {
            return await withTaskCancellationHandler {
                await withUnsafeContinuation { continuation in
                    let (res, limitContinuation, demandContinuation, cancelled) = self.state.withLock {
                        state -> (
                            Result<Element?, Failure>?, UnsafeContinuation<Bool, Never>?,
                            UnsafeContinuation<Void, Never>?, Bool
                        ) in
                        guard let side = state.sides[id] else {
                            return state.emit(.success(nil), limit: self.limit)
                        }
                        if side.position < state.buffer.count {
                            let element = state.buffer[side.position]
                            state.sides[id]?.position += 1
                            state.trimBuffer()
                            return state.emit(.success(element), limit: self.limit)
                        } else {
                            if let failure = state.failure {
                                return state.emit(.failure(failure), limit: self.limit)
                            } else if state.finished {
                                return state.emit(.success(nil), limit: self.limit)
                            } else {
                                state.sides[id]?.continuation = continuation
                                return state.emit(nil, limit: self.limit)
                            }
                        }
                    }
                    if let limitContinuation {
                        limitContinuation.resume(returning: cancelled)
                    }
                    if let demandContinuation {
                        demandContinuation.resume()
                    }
                    if let res {
                        continuation.resume(returning: res)
                    }
                }
            } onCancel: {
                self.cancel(id: id)
            }
        }

        private func iterationLoop(factory: @Sendable () -> sending Base.AsyncIterator) async {
            var iterator = factory()
            do {
                while await self.iterate() {
                    if let element = try await iterator.next() {
                        self.emit(.success(element))
                    } else {
                        self.emit(.success(nil))
                    }
                }
            } catch {
                self.emit(.failure(error as! Failure))
            }
        }

        func next(isolation _: isolated (any Actor)?, id: Int) async throws(Failure) -> Element? {
            let (factory, cancelled) = self.state.withLock {
                state -> ((@Sendable () -> sending Base.AsyncIterator)?, Bool) in
                switch state.iteratingTask {
                case .pending(let factory):
                    state.iteratingTask = .starting
                    return (factory, false)
                case .cancelled:
                    return (nil, true)
                default:
                    return (nil, false)
                }
            }
            if cancelled { return nil }
            if let factory {
                let task: Task<Void, Never>
                #if swift(>=6.2)
                if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) {
                    task = Task(name: "Share Iteration") { [factory, self] in
                        await iterationLoop(factory: factory)
                    }
                } else {
                    task = Task.detached(name: "Share Iteration") { [factory, self] in
                        await self.iterationLoop(factory: factory)
                    }
                }
                #else
                task = Task.detached { [factory, self] in
                    await self.iterationLoop(factory: factory)
                }
                #endif
                self.state.withLock { state in
                    precondition(state.iteratingTask.isStarting)
                    state.iteratingTask = .running(task)
                }
            }

            return try await self.nextIteration(id).get()
        }
    }

    final class Extent: Sendable {
        let iteration: Iteration

        init(
            _ iteratorFactory: @escaping @Sendable () -> sending Base.AsyncIterator,
            bufferingPolicy: AsyncBufferSequencePolicy
        ) {
            self.iteration = Iteration(iteratorFactory, bufferingPolicy: bufferingPolicy)
        }

        deinit {
            iteration.cancel()
        }
    }

    let extent: Extent

    init(
        _ iteratorFactory: @escaping @Sendable () -> sending Base.AsyncIterator,
        bufferingPolicy: AsyncBufferSequencePolicy
    ) {
        self.extent = Extent(iteratorFactory, bufferingPolicy: bufferingPolicy)
    }
}

extension AsyncShareSequence: AsyncSequence {
    package typealias Element = Base.Element
    package typealias Failure = Base.Failure

    package struct Iterator: AsyncIteratorProtocol {
        let side: Side

        init(_ iteration: Iteration) {
            self.side = Side(iteration)
        }

        package mutating func next() async rethrows -> Element? {
            try await self.side.next(isolation: nil)
        }

        package mutating func next(isolation actor: isolated (any Actor)?) async throws(Failure) -> Element? {
            try await self.side.next(isolation: actor)
        }
    }

    package func makeAsyncIterator() -> Iterator {
        Iterator(self.extent.iteration)
    }
}

#endif
