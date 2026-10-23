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

internal enum BufferingContinuationError: Error {
    case notUsingBypass
    case yieldAfterFinish
    case useAfterComplete
}

/// Allows abstracting away the AsyncStream Continuation so we can buffer/resend parts of it
protocol BypassContinuationProtocol<Element>: Sendable {
    associatedtype Element: Sendable

    /// Resume the task awaiting the next iteration point by having it return
    /// normally from its suspension point with a given element.
    ///
    /// - Parameter value: The value to yield from the continuation.
    /// - Returns: A `YieldResult` that indicates the success or failure of the
    ///   yield operation.
    ///
    /// If nothing is awaiting the next value, this method attempts to buffer the
    /// result's element.
    ///
    /// This can be called more than once and returns to the caller immediately
    /// without blocking for any awaiting consumption from the iteration.
    @discardableResult
    func yield(_ value: sending Element) -> AsyncStream<Element>.Continuation.YieldResult

    /// Resume the task awaiting the next iteration point by having it return
    /// nil, which signifies the end of the iteration.
    ///
    /// Calling this function more than once has no effect. After calling
    /// finish, the stream enters a terminal state and doesn't produce any
    /// additional elements.
    func finish()

    /// IFF this is a real bypass, and ``connect(AsyncStream<InvokeWorkloadRequest>.Continuation)``
    /// has not been called already it is legal and *mandatory* to call connect
    /// to flush the request (and possibly termination and finish) to the target.
    var hasPendingBypass: Bool { get }

    /// Should be called once and only once *only* if using bypass
    /// On calling this all buffered state is flushed to the `target`
    /// The caller is responsible for:
    /// First yielding the `.setup` and `.parameters` messages
    /// If the continuation this represents is not yet finished then the `target` is retained to delegate
    /// subsequent calls of ``yield(value:)`` and ``finish()`` to
    func connect(
        target: AsyncStream<InvokeWorkloadRequest>.Continuation
    ) throws
}

/// Wrap the normal target and send to it with no changes or capturing
struct NotBypassedContinuation<Element>: BypassContinuationProtocol {
    /// This is always false, using it implies we are not doing request bypass
    var hasPendingBypass: Bool { false }

    private let continuation: AsyncStream<Element>.Continuation

    init(_ continuation: AsyncStream<Element>.Continuation) {
        self.continuation = continuation
    }

    @discardableResult
    func yield(_ value: sending Element) -> AsyncStream<Element>.Continuation.YieldResult {
        return self.continuation.yield(value)
    }

    func finish() {
        return self.continuation.finish()
    }

    func connect(target _: AsyncStream<InvokeWorkloadRequest>.Continuation) throws {
        throw BufferingContinuationError.notUsingBypass
    }
}

/// This handles the state management of a request bypass:
///
/// It will
/// * Pass through anything no related to the actual encrypted request
/// * buffer incoming request events
/// * flush them once when a worker target is established
/// * keep streaming subsequent request messages to the target
/// * after the parameters are sent the pass thropugh stream is finished
/// * The real finish is buffered/passed along just like a message
///
/// Note: this is intended to match ROPES behaviour as closely as possible
/// but those semantics are not yet known so treat this as an indication of the desired semantics NOT
/// a guarantee of them!
///
/// Since this is mimicking ROPES this is assumed to be holding *encrypted* data
internal final class BufferingBypassContinuation: BypassContinuationProtocol {
    private enum State {
        /// if finished:
        /// holding the buffered data waiting for a connect
        /// if not finished:
        /// Currently buffering requests, passing through other messages
        case buffering(values: [InvokeWorkloadRequest], finished: Bool)
        /// connected to a `target` and all previously buffered data has been sent to it,
        /// Future requestChunk messages will be sent there too.
        /// The pass through still gets everything else.
        /// There has not yet been a finish
        case connected(target: AsyncStream<InvokeWorkloadRequest>.Continuation)
        /// finish has been called and all relevant buffered data passed on,
        /// or discarded if there was never a connect
        case complete
    }

    private var state: State = .buffering(values: [], finished: false)

    /// true until connected, even if nothing buffered yet
    var hasPendingBypass: Bool {
        switch self.state {
        case .buffering:
            return true
        case .connected:
            return false
        case .complete:
            return false
        }
    }

    /// Should be called once and only once
    /// On calling this all buffered state is flushed to the `target`
    /// If legal (not finished yet) then the `target` is retained to delegate subsequent calls
    /// of ``yield(value:)`` and ``finish()`` to
    func connect(
        target: AsyncStream<InvokeWorkloadRequest>.Continuation
    ) throws {
        switch self.state {
        case .buffering(let values, let finished):
            for value in values {
                target.yield(value)
            }
            if finished {
                target.finish()
                self.state = .complete
            } else {
                self.state = .connected(target: target)
            }
        case .connected, .complete:
            preconditionFailure("attempt to connect a request bypass stream multiple times")
        }
    }

    private var finished: Bool {
        return switch self.state {
        case .buffering(_, let finished):
            finished
        case .connected:
            false
        case .complete:
            true
        }
    }

    @discardableResult
    func yield(
        _ value: sending InvokeWorkloadRequest
    ) -> AsyncStream<InvokeWorkloadRequest>.Continuation.YieldResult {
        // When finished it's easy
        guard !self.finished else {
            return .terminated
        }
        switch value.type! {
        case .setup:
            // This is done elsewhere - ROPES would use setup requests to _find_ the target in the first place
            fatalError("setup requests should not be sent through the bypass stream")
        case .parameters:
            // The parameters must come from the proxy (rewrapping the DEK)
            fatalError("parameters requests should not be sent through the bypass stream")
        case .terminate, .requestChunk:
            switch self.state {
            case .buffering(var values, _):
                values.append(value)
                self.state = .buffering(values: values, finished: false)
                return .enqueued(remaining: Int.max)
            case .connected(let target):
                return target.yield(value)
            case .complete:
                return .terminated
            }
        }
    }

    func finish() {
        guard !self.finished else {
            return
        }
        switch self.state {
        case .buffering:
            // nothing to do till this is connected
            ()
        case .connected(let target):
            target.finish()
            self.state = .complete
        case .complete:
            // the finished guard should mean this never happens
            fatalError("finish when completed")
        }
    }
}

/// This type is not easy to make sendable - correct use of it is inherently subject to very precise rules on
/// ordering of the messages due to the encryption and authentication involved in the requestChunks.
/// Therefore we rely on the swift 6 concurrency checker to validate the consuming code is properly isolated
@available(*, unavailable)
extension BufferingBypassContinuation: Sendable {}
