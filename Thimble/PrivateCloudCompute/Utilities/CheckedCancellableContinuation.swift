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
//  CheckedCancellableContinuation.swift
//  PrivateCloudCompute
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import Synchronization
import os.log

private let logger = Logger(for: .client)

/// A continuation that adds a `cancel()` functionality.
///
/// In addition to the normal rules that a `CheckedContinuation` must be resumed exactly once,
/// a `CheckedCancellableContinuation` may  be `cancel()`ed any number of times.
///
/// If a `cancel()` is invoked before the underlying continuation is resumed, the underlying continuation
/// is resumed with a `CancellationError`.
///
/// If a `cancel()` is invoked after the underlying continuation has been resumed, it is a noop.
struct CheckedCancellableContinuation<T>: Sendable {
    private let canary: CheckedCancellableContinuationCanary<T>

    fileprivate init(_ continuation: CheckedContinuation<T, any Error>) {
        self.canary = CheckedCancellableContinuationCanary(continuation)
    }

    /// Resume the task that's awaiting the continuation by returning the given value.
    ///
    /// - Parameter value: The value to return from the continuation.
    ///
    /// A continuation must be resumed exactly once.
    /// If the continuation has already resumed, then calling this method results in undefined behavior.
    ///
    /// After calling this method, control immediately returns to the caller.
    /// The task continues executing when its executor schedules it.
    func resume(returning value: sending T) {
        self.canary.resume(returning: value)
    }

    /// Resume the task that's awaiting the continuation by throwing the given error.
    ///
    /// - Parameter error: The error to throw from the continuation.
    ///
    /// A continuation must be resumed exactly once.
    /// If the continuation has already resumed, then calling this method results in undefined behavior.
    ///
    /// After calling this method, control immediately returns to the caller.
    /// The task continues executing when its executor schedules it.
    func resume<E: Error>(throwing error: E) {
        self.canary.resume(throwing: error)
    }

    /// Resume the task that's awaiting the continuation by returning or throwing the given result value.
    ///
    /// - Parameter result: The result.
    ///   If it contains a `.success` value, the continuation returns that value; otherwise, it throws the `.error` value.
    ///
    /// A continuation must be resumed exactly once.
    /// If the continuation has already resumed, then calling this method results in undefined behavior.
    ///
    /// After calling this method, control immediately returns to the caller.
    /// The task continues executing when its executor schedules it.
    func resume<E: Error>(with result: sending Result<T, E>) {
        self.canary.resume(with: result)
    }

    /// Resume the task that's awaiting the continuation by returning a `Void()` instance.
    ///
    /// A continuation must be resumed exactly once.
    /// If the continuation has already resumed, then calling this method results in undefined behavior.
    ///
    /// After calling this method, control immediately returns to the caller.
    /// The task continues executing when its executor schedules it.
    func resume() where T == () {
        self.canary.resume()
    }

    /// Marks the continuation as cancelled.  The task that's awaiting the continuation will have a `CancellationError` thrown
    ///
    /// A continuation must be resumed exactly once.
    /// A continuation may be cancelled any number of times.
    /// Cancelling a continuation does not remove the requirement that it be resumed exactly once.
    /// If the continuation has already been resumed, then cancelling it has no effect.
    ///
    /// After calling this method, control immediately returns to the caller.
    /// The task continues executing when its executor schedules it.
    func cancel() {
        self.canary.cancel()
    }
}

nonisolated(nonsending) func withCheckedCancellableContinuation<T>(
    function: String = #function,
    _ body: (CheckedCancellableContinuation<T>) -> Void
) async throws -> sending T {
    return try await withCheckedThrowingContinuation(function: function) {
        body(CheckedCancellableContinuation($0))
    }
}

private final class CheckedCancellableContinuationCanary<T>: Sendable {
    private let continuation: CheckedContinuation<T, any Error>
    private enum State {
        /// Initial state
        case initialized

        /// The `CheckedCancellableContinuation` was cancelled, and has not yet had a `resume()` called .
        ///
        /// We will suppress the next `resume()` call on the wrapping `CheckedCancellableContinuation`
        case cancelledAndNeverResumed

        /// The `CheckedCancellableContinuation` has been resumed due to a `resume()` call.
        case resumed
    }
    private let stateMutex: Mutex<State>
    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
        self.stateMutex = Mutex(.initialized)
    }
}

extension CheckedCancellableContinuationCanary {
    /// Action a caller should take after calling ``noteResumption()``
    private enum ResumeAction {
        case invokeAdopter
    }

    /// - Returns: The action, if any, a caller should take.
    private func noteResumption() -> ResumeAction? {
        return self.stateMutex.withLock {
            switch $0 {
            case .initialized:
                $0 = .resumed  // .resumed <- .initialized
                return .invokeAdopter
            case .resumed:
                return .invokeAdopter
            case .cancelledAndNeverResumed:
                $0 = .resumed  // .resumed <- .cancelledAndNeverResumed
                // Not invoking resumeBlock, this is our one suppression of a `resume()`
                return nil
            }
        }
    }

    func resume(returning value: sending T) {
        let action = self.noteResumption()
        switch action {
        case .invokeAdopter:
            self.continuation.resume(returning: value)
        case .none:
            logger.debug("CheckedCancellableContinuation suppressing resume on cancelled continuation, would have returned \(String(describing: value))")
        }
    }

    func resume<E: Error>(throwing error: E) {
        let action = self.noteResumption()
        switch action {
        case .invokeAdopter:
            self.continuation.resume(throwing: error)
        case .none:
            logger.debug("CheckedCancellableContinuation suppressing resume on cancelled continuation, would have thrown \(error)")
        }
    }

    func resume<E: Error>(with result: sending Result<T, E>) {
        let action = self.noteResumption()
        switch action {
        case .invokeAdopter:
            self.continuation.resume(with: result)
        case .none:
            logger.debug("CheckedCancellableContinuation suppressing resume on cancelled continuation, would have resumed with \(String(describing: result))")
        }
    }

    func resume() where T == () {
        let action = self.noteResumption()
        switch action {
        case .invokeAdopter:
            self.continuation.resume()
        case .none:
            logger.debug("CheckedCancellableContinuation suppressing resume on cancelled continuation, would have resumed with Void()")
        }
    }

    func cancel() {
        let shouldResume = self.stateMutex.withLock {
            switch $0 {
            case .initialized:
                $0 = .cancelledAndNeverResumed  // .cancelledAndNeverResumed <- .initialized
                return true
            case .cancelledAndNeverResumed, .resumed:
                return false
            }
        }
        if shouldResume {
            continuation.resume(throwing: CancellationError())
        }
    }
}
