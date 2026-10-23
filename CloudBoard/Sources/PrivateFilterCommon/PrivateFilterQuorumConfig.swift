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

@_weakLinked import SecureConfigDB

package struct PrivateFilterQuorumConfig: Sendable, Hashable {
    package let requiredNodes: Int
    package let overshootAbsolute: Int
    package let overshootPercent: Double
    package let defaultQueryTimeout: Duration
    /// Interval between timeout-detection sweeps. Bounds worst-case overshoot
    /// on query expiry: a query may live up to one tick beyond its deadline.
    package let tickInterval: Duration
    /// Fraction of query timeout allocated to waiting for quorum before buffering expires.
    package let quorumWaitBudgetFraction: Double
    /// How long the router waits for a `.nodeApproval` after posting an
    /// attestation-usage report before the reaper in
    /// `JobHelperQuorumInstance.handleTick` re-posts it.
    package let attestationResendInterval: Duration
    /// Maximum number of times the reaper will re-post an attestation-usage
    /// report for the same `(helperID, keyID)` pair before declaring the
    /// keyID unresponsive for this instance session. See
    /// `HelperNodeApprovals.recordUnresponsive`.
    package let maxAttestationAttempts: Int

    /// Maximum number of times a query may be reissued onto a different connection (reconnect
    /// retry or proactive hedge). `0` disables reissue. Clamped under customer policy (see
    /// `fromSecureConfig`). The total attempts per query is `maxConnectionRetries + 1`.
    package let maxConnectionRetries: Int
    /// Minimum remaining time budget required before a reissue/hedge is attempted. Below this a
    /// backup would time out before it could answer, so the query fails on its original deadline
    /// instead of burning a retry.
    package let retryBudgetFloor: Duration
    /// Fraction of a query's timeout after which, if no response has arrived, a proactive hedge is
    /// fired onto a different quorate connection. Must be in `(0, 1)`.
    package let hedgeAfterFraction: Double

    /// Passive degraded-connection detection: number of consecutive queries a connection can be
    /// dispatched without producing a response (a hedge answered instead, or the query timed out)
    /// before the connection is torn down and re-established. `nil` or `0` disables detection.
    /// Combined with `degradedStaleTimeout` — both thresholds must trip — so a connection that
    /// recently answered (or was only just established) is never replaced.
    package let maxConsecutiveMisses: Int?
    /// Minimum time since a connection's last unambiguous response — or, if it has never answered,
    /// since it was established — before the miss-count threshold can trigger a replacement. Only
    /// consulted when detection is enabled.
    package let degradedStaleTimeout: Duration

    /// The effective degraded-detection miss threshold, or `nil` if detection is disabled
    /// (`maxConsecutiveMisses` unset or non-positive).
    package var degradedMissThreshold: Int? {
        guard let maxConsecutiveMisses, maxConsecutiveMisses > 0 else { return nil }
        return maxConsecutiveMisses
    }

    package init(
        requiredNodes: Int,
        overshootAbsolute: Int,
        overshootPercent: Double,
        defaultQueryTimeout: Duration = .seconds(1),
        tickInterval: Duration = .milliseconds(100),
        quorumWaitBudgetFraction: Double = 0.8,
        attestationResendInterval: Duration = .seconds(5),
        maxAttestationAttempts: Int = 3,
        maxConnectionRetries: Int = 2,
        retryBudgetFloor: Duration = .milliseconds(50),
        hedgeAfterFraction: Double = 0.5,
        maxConsecutiveMisses: Int? = nil,
        degradedStaleTimeout: Duration = .seconds(10)
    ) {
        self.requiredNodes = requiredNodes
        self.overshootAbsolute = overshootAbsolute
        self.overshootPercent = overshootPercent
        self.defaultQueryTimeout = defaultQueryTimeout
        self.tickInterval = tickInterval
        self.quorumWaitBudgetFraction = quorumWaitBudgetFraction
        self.attestationResendInterval = attestationResendInterval
        self.maxAttestationAttempts = maxAttestationAttempts
        self.maxConnectionRetries = maxConnectionRetries
        self.retryBudgetFloor = retryBudgetFloor
        self.hedgeAfterFraction = hedgeAfterFraction
        self.maxConsecutiveMisses = maxConsecutiveMisses
        self.degradedStaleTimeout = degradedStaleTimeout
    }
}

extension PrivateFilterQuorumConfig {
    private static let keyPrefix = "com.apple.privatefilter.clientrouter.quorum"

    /// Resolves the required-node quorum floor for a given policy.
    ///
    /// Under `customer`/`customerProxy` the floor is 15 and an operator override cannot go below it —
    /// except in research/VRE runs (`disableForResearch`), where the floor drops to 1 so a filter can
    /// become quorate with far fewer PFS nodes than a production fleet. The unconfigured default stays
    /// 15 regardless of the research flag; only an explicit override can reach the lower floor.
    package static func resolveRequiredNodes(
        securityPolicy: SecureConfigSecurityPolicy,
        configuredRequired: Int?,
        disableForResearch: Bool
    ) -> Int {
        switch securityPolicy {
        case .customer, .customerProxy:
            disableForResearch ? max(configuredRequired ?? 15, 1) : max(configuredRequired ?? 15, 15)
        case .carry:
            max(configuredRequired ?? 3, 1)
        case .none:
            configuredRequired ?? 1
        @unknown default:
            max(configuredRequired ?? 15, 15)
        }
    }

    /// Enforces security-policy minimum floors (e.g. customer/customerProxy ≥ 15 required nodes).
    package static func fromSecureConfig(
        parameters: SecureConfigParameters
    ) throws -> PrivateFilterQuorumConfig {
        let configuredRequired: Int? = try getUnvalidatedParameter(
            key: "\(keyPrefix).requiredNodes",
            from: parameters
        )
        let requiredNodes = self.resolveRequiredNodes(
            securityPolicy: parameters.securityPolicy,
            configuredRequired: configuredRequired,
            disableForResearch: parameters.research_disableAppleInfrastrucutureEnforcement == true
        )

        let overshootAbsolute: Int = try getUnvalidatedParameter(
            key: "\(keyPrefix).overshootAbsolute",
            from: parameters
        ) ?? 2
        guard overshootAbsolute >= 0 else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).overshootAbsolute must be non-negative, got \(overshootAbsolute)"
            )
        }
        let overshootPercent: Double = try getUnvalidatedParameter(
            key: "\(keyPrefix).overshootPercent",
            from: parameters
        ) ?? 0.0
        guard overshootPercent >= 0, overshootPercent.isFinite else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).overshootPercent must be non-negative and finite, got \(overshootPercent)"
            )
        }

        let defaultQueryTimeoutSeconds: Double = try getUnvalidatedParameter(
            key: "com.apple.privatefilter.clientrouter.defaultQueryTimeoutSeconds",
            from: parameters
        ) ?? 1.0
        guard defaultQueryTimeoutSeconds > 0, defaultQueryTimeoutSeconds.isFinite else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "defaultQueryTimeoutSeconds must be positive and finite, got \(defaultQueryTimeoutSeconds)"
            )
        }

        let tickIntervalSeconds: Double = try getUnvalidatedParameter(
            key: "\(keyPrefix).tickIntervalSeconds",
            from: parameters
        ) ?? 0.1
        guard tickIntervalSeconds > 0, tickIntervalSeconds.isFinite else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).tickIntervalSeconds must be positive and finite, got \(tickIntervalSeconds)"
            )
        }

        let quorumWaitBudgetFraction: Double = try getUnvalidatedParameter(
            key: "\(keyPrefix).quorumWaitBudgetFraction",
            from: parameters
        ) ?? 0.8
        guard quorumWaitBudgetFraction > 0, quorumWaitBudgetFraction <= 1.0, quorumWaitBudgetFraction.isFinite else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).quorumWaitBudgetFraction must be in (0, 1], got \(quorumWaitBudgetFraction)"
            )
        }

        let attestationResendIntervalSeconds: Double = try getUnvalidatedParameter(
            key: "\(keyPrefix).attestationResendIntervalSeconds",
            from: parameters
        ) ?? 5.0
        guard attestationResendIntervalSeconds > 0, attestationResendIntervalSeconds.isFinite else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).attestationResendIntervalSeconds must be positive and finite, got \(attestationResendIntervalSeconds)"
            )
        }

        let maxAttestationAttempts: Int = try getUnvalidatedParameter(
            key: "\(keyPrefix).maxAttestationAttempts",
            from: parameters
        ) ?? 3
        guard maxAttestationAttempts >= 1 else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).maxAttestationAttempts must be >= 1, got \(maxAttestationAttempts)"
            )
        }

        let configuredMaxConnectionRetries: Int? = try getUnvalidatedParameter(
            key: "\(keyPrefix).maxConnectionRetries",
            from: parameters
        )
        // Reissuing a query onto a replacement connection re-uses a new node; under customer
        // policy we allow at most two such backups per query.
        let maxConnectionRetries: Int = switch parameters.securityPolicy {
        case .customer, .customerProxy:
            min(configuredMaxConnectionRetries ?? 2, 2)
        case .carry:
            configuredMaxConnectionRetries ?? 2
        case .none:
            configuredMaxConnectionRetries ?? 2
        @unknown default:
            min(configuredMaxConnectionRetries ?? 2, 2)
        }
        guard maxConnectionRetries >= 0 else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).maxConnectionRetries must be non-negative, got \(maxConnectionRetries)"
            )
        }

        let retryBudgetFloorSeconds: Double = try getUnvalidatedParameter(
            key: "\(keyPrefix).retryBudgetFloorSeconds",
            from: parameters
        ) ?? 0.05
        guard retryBudgetFloorSeconds > 0, retryBudgetFloorSeconds.isFinite else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).retryBudgetFloorSeconds must be positive and finite, got \(retryBudgetFloorSeconds)"
            )
        }

        let hedgeAfterFraction: Double = try getUnvalidatedParameter(
            key: "\(keyPrefix).hedgeAfterFraction",
            from: parameters
        ) ?? 0.5
        guard hedgeAfterFraction > 0, hedgeAfterFraction < 1.0, hedgeAfterFraction.isFinite else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).hedgeAfterFraction must be in (0, 1), got \(hedgeAfterFraction)"
            )
        }

        // Passive degraded-connection detection is disabled by default (unset). Enabled per-fleet
        // once observed; nil or a non-positive value both mean disabled.
        let maxConsecutiveMisses: Int? = try getUnvalidatedParameter(
            key: "\(keyPrefix).maxConsecutiveMisses",
            from: parameters
        )
        if let maxConsecutiveMisses, maxConsecutiveMisses < 0 {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).maxConsecutiveMisses must be non-negative, got \(maxConsecutiveMisses)"
            )
        }

        let degradedStaleTimeoutSeconds: Double = try getUnvalidatedParameter(
            key: "\(keyPrefix).degradedStaleTimeoutSeconds",
            from: parameters
        ) ?? 10.0
        guard degradedStaleTimeoutSeconds > 0, degradedStaleTimeoutSeconds.isFinite else {
            throw PrivateFilterSecureConfigError.invalidParameter(
                "\(self.keyPrefix).degradedStaleTimeoutSeconds must be positive and finite, got \(degradedStaleTimeoutSeconds)"
            )
        }

        return .init(
            requiredNodes: requiredNodes,
            overshootAbsolute: overshootAbsolute,
            overshootPercent: overshootPercent,
            defaultQueryTimeout: .seconds(defaultQueryTimeoutSeconds),
            tickInterval: .seconds(tickIntervalSeconds),
            quorumWaitBudgetFraction: quorumWaitBudgetFraction,
            attestationResendInterval: .seconds(attestationResendIntervalSeconds),
            maxAttestationAttempts: maxAttestationAttempts,
            maxConnectionRetries: maxConnectionRetries,
            retryBudgetFloor: .seconds(retryBudgetFloorSeconds),
            hedgeAfterFraction: hedgeAfterFraction,
            maxConsecutiveMisses: maxConsecutiveMisses,
            degradedStaleTimeout: .seconds(degradedStaleTimeoutSeconds)
        )
    }
}
