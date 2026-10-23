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

import Logging
import Synchronization

/// Resettable idle watchdog for long-running streaming work.
///
/// Most callers should use `withIdleTimeout(_:body:)` rather than constructing
/// this directly — it manages a structured task group containing the watchdog
/// and the guarded work, and translates the timeout into a caller-supplied
/// error type.
///
/// `run()` suspends until either `timeout` elapses with no intervening
/// `registerActivity()` call (in which case it throws
/// `IdleTimeoutError.idleTimeoutExceeded`) or the task is cancelled (in which
/// case it returns normally so the enclosing task group does not see a
/// spurious `CancellationError`). Callers should invoke `registerActivity()`
/// on every signal of forward progress.
package final class IdleTimeout<C: Clock>: Sendable where C.Duration == Duration {
    private let timeout: Duration
    private let clock: C
    private let lastActivity: Mutex<C.Instant>
    private let logger: Logger

    package init(
        timeout: Duration,
        clock: C = ContinuousClock()
    ) {
        self.timeout = timeout
        self.clock = clock
        self.lastActivity = Mutex(clock.now)
        self.logger = Logger(label: "cloudboard.IdleTimeout")
    }

    /// Sleeps until the configured idle window elapses without activity, then
    /// throws `IdleTimeoutError.idleTimeoutExceeded`. Returns normally when the
    /// task is cancelled so the enclosing task group does not see a spurious
    /// `CancellationError` after a successful shutdown.
    package func run() async throws {
        // Anchor the idle window at run() entry so the timeout starts when
        // monitoring actually begins, not when this object was constructed.
        // Construction can happen well before the enclosing task group starts
        // executing this child task, e.g. on warmup-heavy paths.
        self.lastActivity.withLock { $0 = self.clock.now }

        self.logger.info(
            "Idle timer armed",
            metadata: ["timeout": "\(self.timeout)"]
        )

        var sleepInterval = self.timeout
        while true {
            do {
                try await Task.sleep(for: sleepInterval, clock: self.clock)
            } catch is CancellationError {
                self.logger.info("Idle timer cancelled")
                return
            }

            let remaining: Duration? = self.lastActivity.withLock { lastActivity in
                let elapsed = lastActivity.duration(to: self.clock.now)
                if elapsed >= self.timeout { return nil }
                return self.timeout - elapsed
            }
            guard let next = remaining else {
                self.logger.error(
                    "Idle timer exceeded",
                    metadata: ["timeout": "\(self.timeout)"]
                )
                throw IdleTimeoutError.idleTimeoutExceeded(self.timeout)
            }
            sleepInterval = next
        }
    }

    /// Resets the idle deadline. Safe to call from any isolation context.
    package func registerActivity() {
        self.lastActivity.withLock { $0 = self.clock.now }
    }
}

package enum IdleTimeoutError: Error, Equatable {
    case idleTimeoutExceeded(Duration)
}

extension IdleTimeoutError: ReportableError {
    package var publicDescription: String {
        switch self {
        case .idleTimeoutExceeded(let duration):
            "IdleTimeoutError.idleTimeoutExceeded(\(duration))"
        }
    }
}

private struct _IdleTimeoutBodyValue<T: Sendable>: Sendable {
    let value: T
}

/// Runs `body` while an idle watchdog observes activity in parallel. If the
/// watchdog elapses before `body` returns, `onTimeout(timeout)` is invoked and
/// expected to throw; the thrown error propagates out and `body` is cancelled.
/// When `body` returns or throws first, the watchdog is cancelled and exits
/// cleanly.
///
/// The watchdog instance is passed into `body` so the callee can call
/// `registerActivity()` whenever it observes forward progress (e.g. each
/// request/response chunk). This separates idleness observation from request
/// handling at the call site.
package func withIdleTimeout<T: Sendable>(
    _ timeout: Duration,
    onTimeout: @Sendable @escaping (Duration) throws -> Void = { throw IdleTimeoutError.idleTimeoutExceeded($0) },
    body: @Sendable @escaping (IdleTimeout<ContinuousClock>) async throws -> T
) async throws -> T {
    try await withIdleTimeout(
        timeout,
        clock: ContinuousClock(),
        onTimeout: onTimeout,
        body: body
    )
}

package func withIdleTimeout<T: Sendable, C: Clock>(
    _ timeout: Duration,
    clock: C,
    onTimeout: @Sendable @escaping (Duration) throws -> Void = { throw IdleTimeoutError.idleTimeoutExceeded($0) },
    body: @Sendable @escaping (IdleTimeout<C>) async throws -> T
) async throws -> T where C.Duration == Duration {
    let idleTimer = IdleTimeout(timeout: timeout, clock: clock)
    return try await withThrowingTaskGroup(of: _IdleTimeoutBodyValue<T>?.self) { group in
        group.addTask {
            do {
                try await idleTimer.run()
            } catch IdleTimeoutError.idleTimeoutExceeded(let duration) {
                try onTimeout(duration)
            }
            // Returned only after the watchdog task is cancelled (i.e. body
            // already completed). Signals "not the body's result".
            return nil
        }
        group.addTask {
            _IdleTimeoutBodyValue(value: try await body(idleTimer))
        }
        while let next = try await group.next() {
            if let result = next {
                group.cancelAll()
                return result.value
            }
        }
        // Unreachable: the body either returns a value (handled above) or
        // throws (propagates out of `group.next()`).
        throw CancellationError()
    }
}
