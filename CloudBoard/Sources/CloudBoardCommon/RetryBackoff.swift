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

import os

/// Calculates exponential backoffs with jitter
///
/// Calculates exponential backoffs with jitter and optionally resets the backoff delay value when not called for a
/// specified cool-down period. Makes use of generics to allow a mockable clock to be supplied.
public struct RetryBackoff<AContinuousClock: ContinuousClockProtocol>: Sendable {
    public let config: Configuration
    let clock: AContinuousClock

    private var nextBackoff: Duration
    private var backoffCalculated: ContinuousClock.Instant

    private let defaultConfig: Configuration = .init(
        initial: .seconds(1),
        maximum: .seconds(120),
        factor: 1.6,
        jitterPercent: 20,
        // No cooldown by default. Only useful where RetryBackoff is reused across multiple successful requests.
        coolDown: nil
    )

    public struct Configuration: Sendable {
        var initial: Duration
        var maximum: Duration
        var factor: Double
        var jitterPercent: Double
        var coolDown: Duration?
    }

    public init(
        initial: Duration? = nil,
        maximum: Duration? = nil,
        factor: Double? = nil,
        jitterPercent: Double? = nil,
        coolDown: Duration? = nil,
        clock: AContinuousClock = ContinuousClock()
    ) {
        let config: Configuration = .init(
            initial: initial ?? self.defaultConfig.initial,
            maximum: maximum ?? self.defaultConfig.maximum,
            // factors probably want to be >=1 so that they grow
            factor: Swift.max(1, factor ?? self.defaultConfig.factor),
            // jitter probably wants to be +ve and less than the backoff
            jitterPercent: jitterPercent?.clamped(0, 100) ?? self.defaultConfig.jitterPercent,
            coolDown: coolDown ?? self.defaultConfig.coolDown
        )
        self.config = config

        self.nextBackoff = self.config.initial
        self.clock = clock
        self.backoffCalculated = self.clock.now
    }

    public mutating func backoff() -> Duration {
        self.applyCoolDown()

        let backoff = self.nextBackoff
        self.nextBackoff = self.calculateNextBackoff()
        return backoff
    }

    private func calculateNextBackoff() -> Duration {
        let jitter = Double.random(in: (0 - self.config.jitterPercent) ... self.config.jitterPercent) / 100
        let nextBackoff = self.nextBackoff * self.config.factor * (1.0 + jitter)

        return Swift.min(nextBackoff, self.config.maximum)
    }

    private mutating func applyCoolDown() {
        guard let coolDown = self.config.coolDown else {
            return
        }
        let now = self.clock.now
        let backoffCalculated = self.backoffCalculated
        self.backoffCalculated = now

        if backoffCalculated.duration(to: now) > coolDown {
            self.reset()
        }
    }

    private mutating func reset() {
        self.nextBackoff = self.config.initial
    }
}

extension RetryBackoff: Sequence {
    public typealias Element = Duration

    public func makeIterator() -> Iterator {
        Iterator(retryBackoff: self)
    }

    public struct Iterator: IteratorProtocol {
        public typealias Element = Duration

        private var retryBackoff: RetryBackoff

        public init(retryBackoff: RetryBackoff) {
            self.retryBackoff = retryBackoff
        }

        public mutating func next() -> Duration? {
            self.retryBackoff.backoff()
        }
    }
}

extension RetryBackoff.Configuration: CustomStringConvertible {
    public var description: String {
        "RetryBackoff.Configuration(" +
            "initial: \"\(initial)\", " +
            "maximum: \"\(maximum)\", " +
            "factor: \"\(factor)\", " +
            "jitterPercent: \"\(jitterPercent)\", " +
            "coolDown: \"\(coolDown.map { "\($0)) " } ?? "nil")\"" +
            ")"
    }
}

extension Double {
    func clamped(_ min: Double, _ max: Double) -> Double {
        return Swift.min(Swift.max(self, min), max)
    }
}

public protocol ContinuousClockProtocol: Sendable {
    var now: ContinuousClock.Instant { get }
}

extension ContinuousClock: ContinuousClockProtocol {}
