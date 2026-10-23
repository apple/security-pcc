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

import CloudBoardCommon
import CloudBoardDomain

package enum PolicyControlledEffortDegraderError: Error, Equatable {
    case noiseGreaterThanMaximum
    case noiseLessThanPolicyRequires
    case policyRequiresRemovalOfIdealValues
    case probabilityOutOfRange(Double)
    case denominatorOutOfRange(UInt8)
    case denominatorNotPowerOfTwoMinusOne(UInt8)
}

/// The only way to do proper privacy preserving effort degradation.
/// Not done as a protocol because there's only one acceptable implementation, with specific settings
/// bounded by policy as code.
internal struct PolicyControlledEffortDegrader: Sendable {
    /// Sense check: not a privacy control
    private static let minimumDenominator: UInt8 = 1
    /// Increasing this requires conversations with ROPES as well as Privacy
    private static let maximumDenominator: UInt8 = 31

    /// since most buckets allow movement either way this results in a probability of 1
    private static let maximumProbabilityOfOneWayMovement = 0.5
    /// Going below this is not acceptable in carry or prod
    /// The application in carry is deliberate, we should execise the code paths and seem the impacts, but
    /// can still see ideal values that allow analysis of the impact/debugging
    private static let minimumProbabilityOfOneWayMovementInCarryAndCustomer = 0.25

    /// Strip the ideal values from the degraded instance
    /// In customer this must happen, but outside that it's helpful to benchmark the
    /// impact of the degredation
    private let removeIdealValues: Bool
    /// If specified only keys which exactly match are allowed
    /// not currently required as a customer policy
    private let allowList: Set<String>?
    /// This might vary over the course of a request in future
    /// for now it's just a simple constant
    private let denominator: UInt8
    /// This allows tuning the amount of noise added
    /// The semantics are:
    /// 1. Never move more than one bucket away from the ideal bucket
    /// 2. Never go below 0 or `denominator`
    /// 3. The probability may not exceed 0.5 as it is symetric
    /// - At 50% in a "middle" bucket this would sum to a probability of 1.0 that a move happens
    /// - note: to avoid a bias if the sample is *precisely* ``maximumProbabilityOfOneWayMovement`` it
    /// will not move
    /// 4. To achieve mean(input) = mean(output) the input distribution:
    /// MUST
    /// - Be symetric and have mean(0.5)
    /// - The clamping at the ends requires
    /// SHOULD
    /// - Be uniform
    /// - This guarantees a uniform output.
    ///
    /// Adding noise at the ideal as a float level is theoretically nicer but results in complications
    /// when trying to enforce rule 1. This calculation should be simple.
    private let probabilityOfOneWayMovement: Double

    /// Validates that the denominator is within acceptable bounds and of the correct form.
    /// Denominator must be in range [1, 31] and of form 2^n - 1 (i.e., 1, 3, 7, 15, 31).
    package static func validateDenominator(_ denominator: UInt8) throws {
        guard denominator >= self.minimumDenominator, denominator <= self.maximumDenominator else {
            throw PolicyControlledEffortDegraderError.denominatorOutOfRange(denominator)
        }
        let isPowerOfTwoMinusOne = (denominator > 0) && (((denominator + 1) & denominator) == 0)
        guard isPowerOfTwoMinusOne else {
            throw PolicyControlledEffortDegraderError.denominatorNotPowerOfTwoMinusOne(denominator)
        }
    }

    package static func validateProbability(_ probability: Double) throws {
        guard probability >= 0.0, probability <= 1.0 else {
            throw PolicyControlledEffortDegraderError.probabilityOutOfRange(probability)
        }
    }

    /// This initialiser applies configuration values if provided, otherwise uses defaults that are
    /// guaranteed to be legal for the provided policy.
    package init(
        securityPolicy: SecureConfig.Parameters.SecurityPolicy,
        configuration: CBJobHelperConfiguration.EffortPrivacyConfiguration? = nil
    ) {
        do {
            try self.init(
                securityPolicy: securityPolicy,
                denominator: configuration?.denominator,
                probabilityOfOneWayMovement: configuration?.probabilityOfOneWayMovement
            )
        } catch {
            // The defaults are guaranteed to be valid.
            // This can only fail if configuration provides invalid values, which indicates a configuration error.
            fatalError(
                "PolicyControlledEffortDegrader initialization failed with error: \(error). This should only happen with invalid configuration values, not with defaults."
            )
        }
    }

    /// Allows control of settings (presumably from config/default) but this initialiser will enforce
    /// the various settings are reasonable and, respect `securityPolicy`
    /// If the constructor succceds all configuration is valid and calls to ``degrade()`` should never
    /// throw so long as they have ideal values in the range
    package init(
        securityPolicy: SecureConfig.Parameters.SecurityPolicy,
        removeIdealValues: Bool? = nil,
        denominator: UInt8? = nil,
        probabilityOfOneWayMovement: Double? = nil,
        allowList: Set<String>? = nil
    ) throws {
        let denominator = denominator ?? Self.maximumDenominator
        let probabilityOfOneWayMovement = probabilityOfOneWayMovement ?? Self
            .minimumProbabilityOfOneWayMovementInCarryAndCustomer

        // Validate basic constraints
        try Self.validateDenominator(denominator)
        try Self.validateProbability(probabilityOfOneWayMovement)

        // Probability must not exceed 0.5 for symmetric noise
        guard probabilityOfOneWayMovement <= Self.maximumProbabilityOfOneWayMovement else {
            throw PolicyControlledEffortDegraderError.noiseGreaterThanMaximum
        }

        self.removeIdealValues = removeIdealValues ?? (securityPolicy == .customer)

        // Policy-specific validation
        switch securityPolicy {
        case .none:
            () // nothing to enforce
        case .carry:
            // we want the noise to kick in, we just don't require stripping the ideal values
            guard probabilityOfOneWayMovement >= Self.minimumProbabilityOfOneWayMovementInCarryAndCustomer else {
                throw PolicyControlledEffortDegraderError.noiseLessThanPolicyRequires
            }
        case .customer:
            guard probabilityOfOneWayMovement >= Self.minimumProbabilityOfOneWayMovementInCarryAndCustomer else {
                throw PolicyControlledEffortDegraderError.noiseLessThanPolicyRequires
            }
            guard self.removeIdealValues else {
                throw PolicyControlledEffortDegraderError.policyRequiresRemovalOfIdealValues
            }
        }
        self.denominator = denominator
        self.probabilityOfOneWayMovement = probabilityOfOneWayMovement
        self.allowList = allowList
    }

    /// Returns a new `ExpectedEffort` that is degraded based on the policy
    package func degrade(_ effort: ExpectedEffort) throws -> ExpectedEffort {
        var rng = SystemRandomNumberGenerator()
        return try effort.degrade(removeIdealValues: self.removeIdealValues) { key, ideal in
            if let allowList = self.allowList, !allowList.contains(key) {
                return nil
            }
            let (idealBucket, wasSampled) = try ExpectedEffort.DegradedValue.closest(
                ideal: ideal, denominator: self.denominator, rng: &rng
            )
            // There's no need to degrade further a value that was sampled
            // it had a 50/50 chance of ending up either
            if self.probabilityOfOneWayMovement == 0 || wasSampled {
                return idealBucket
            } else {
                let sample = Double.random(in: 0.0 ... 1.0, using: &rng)
                if sample < self.probabilityOfOneWayMovement {
                    if idealBucket.numerator != 0 {
                        return try idealBucket.decremented()
                    }
                } else if sample > 1.0 - self.probabilityOfOneWayMovement {
                    if idealBucket.numerator != idealBucket.denominator {
                        return try idealBucket.incremented()
                    }
                } else {
                    // "in the middle so don't move"
                    // This explicity covers hitting the nasty floating point middle ground when
                    // using maximumProbabilityOfOneWayMovement so there's no bias as a result.
                    // It's not likely to be detectable in anyway but keep it consistent
                }
                return idealBucket
            }
        }
    }
}
