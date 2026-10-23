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
import Logging

// MARK: - Retry configuration

/// Configuration for HTTP request retry behavior.
public struct RetryConfiguration: Sendable {
    /// Total number of attempts (including the initial one). Must be >= 1.
    public var maxAttempts: Int
    /// Base delay before the first retry. Subsequent retries double this.
    public var baseDelay: Duration
    /// Maximum delay between retries (caps the exponential growth).
    public var maxDelay: Duration
    /// Random jitter added as a fraction of the computed delay (0.0 to 1.0).
    public var jitterFactor: Double

    public init(
        maxAttempts: Int,
        baseDelay: Duration,
        maxDelay: Duration,
        jitterFactor: Double
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterFactor = jitterFactor
    }

    public static let `default` = RetryConfiguration(
        maxAttempts: 20,
        baseDelay: .milliseconds(250),
        maxDelay: .seconds(30),
        jitterFactor: 0.25
    )
}

// MARK: - Retry execution

/// Executes `body`, retrying on failure with exponential backoff and jitter.
///
/// - Parameters:
///   - configuration: Retry timing and attempt limits.
///   - logger: Logger for retry diagnostics.
///   - operation: The operation being performed (used for log messages and metrics).
///   - metrics: Pre-created metrics to record retries and errors, or `nil` to skip.
///   - body: The operation to attempt.
/// - Returns: The result of a successful `body` invocation.
/// - Throws: The error from the final attempt if all attempts are exhausted.
func withRetry<T: Sendable>(
    configuration: RetryConfiguration = .default,
    logger: Logger,
    operation: MetricsOperation,
    metrics: DownloadMetrics? = nil,
    _ body: @Sendable () async throws -> T
) async throws -> T {
    for attempt in 1..<configuration.maxAttempts {
        do {
            return try await body()
        } catch let cancellation as CancellationError {
            logger.debug(
                "Operation cancelled, not retrying",
                metadata: [
                    "operation": "\(operation.logDescription)",
                    "attempt": "\(attempt)/\(configuration.maxAttempts)",
                ]
            )
            throw cancellation
        } catch {
            let delay = computeDelay(
                attempt: attempt,
                baseDelay: configuration.baseDelay,
                maxDelay: configuration.maxDelay,
                jitterFactor: configuration.jitterFactor
            )
            logger.warning(
                "Retryable error, will retry",
                metadata: [
                    "operation": "\(operation.logDescription)",
                    "attempt": "\(attempt)/\(configuration.maxAttempts)",
                    "delay": "\(delay)",
                    "error": "\(String(reportable: error))",
                ]
            )
            metrics?.recordRetry(operation: operation)
            metrics?.recordError(error)
            try await Task.sleep(for: delay)
        }
    }
    // Final attempt — errors propagate directly, no retry.
    return try await body()
}

func computeDelay(
    attempt: Int,
    baseDelay: Duration,
    maxDelay: Duration,
    jitterFactor: Double
) -> Duration {
    let baseNanos = durationToNanoseconds(baseDelay)
    let maxNanos = durationToNanoseconds(maxDelay)

    // Exponential backoff: baseDelay * 2^(attempt-1), capped at maxDelay.
    let shift = min(attempt - 1, 62)
    let (exponentialNanos, expOverflow) = baseNanos.multipliedReportingOverflow(by: Int64(1) << shift)
    let cappedNanos = min(expOverflow ? Int64.max : exponentialNanos, maxNanos)

    // Add random jitter in [0, jitterFactor * cappedNanos].
    let jitterNanos = Int64(Double(cappedNanos) * Double.random(in: 0...jitterFactor))
    let (total, addOverflow) = cappedNanos.addingReportingOverflow(jitterNanos)
    return .nanoseconds(addOverflow ? Int64.max : total)
}

/// Converts a `Duration` to nanoseconds, clamping to `Int64.max` on overflow.
func durationToNanoseconds(_ duration: Duration) -> Int64 {
    let (secondsAsNanos, mulOverflow) = Int64(duration.components.seconds)
        .multipliedReportingOverflow(by: 1_000_000_000)
    let attosecondsAsNanos = duration.components.attoseconds / 1_000_000_000
    let (total, addOverflow) = secondsAsNanos.addingReportingOverflow(attosecondsAsNanos)
    return (mulOverflow || addOverflow) ? Int64.max : total
}
