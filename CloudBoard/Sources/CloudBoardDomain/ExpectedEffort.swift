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

package import CloudBoardAsyncXPC

package enum ExpectedEffortError: Error {
    /// The ideal effort must be between [0.0, 1.0]
    case outsideExpectedEffortRange
    /// the ideal values have been dropped
    case noIdealValuesArePresent
    /// exceeded ``ExpectedEffort/DegradedValue/maxDenominator``
    case useOfDegradedDenominatorAboveMaximum
    /// ``ExpectedEffort/DegradedValue/denominator`` must be 2^n -1
    /// This means they will always cleanly nest
    case useOfDegradedDenominatorNotAPowerOfTwoMinusOne
    /// ``ExpectedEffort/DegradedValue/numerator`` must be less then or qual to
    /// ``ExpectedEffort/DegradedValue/denominator``
    case numeratorGreaterThanDenominator
}

/// A rigid means to express the effort involved in some aspect of ``PCCClient/makePCCRequest``.
/// This allows ROPES to make informed decisions about how to route those requests effectively.
/// It does not express conditions/requirements, those should be expressed clearly in other ways,
/// it allows *policy* to be defined in ROPES (where it is easy to change).
///
/// In doing so in a rigid way so that CloudBoard can ensure that the form of this that is presented to ROPES
/// has been transformed in a way that private information that could be used for fingerprinting is not
/// leaked.
///
/// The identifiers for the efforts are strings because they are all application specific and thus
/// undesirable to be codified without cloudBoard. Applications should define the strings used with
/// ROPES and CloudBoard will simply pass them through without change, much like workload parameters.
/// They are expected to be extremely stable, and  for each request to have very few of them.
/// Privacy constraints may result in defining allow lists for the names in future.
///
/// The efforts are defined as Doubles, but the rules for them are that they must be a value
/// between [0.0 and 1.0].
/// In the customer environments, they will have been adjusted such that
/// they have reduced precision and accuracy (but without bias) such that, over time
/// AVG(effort ROPES sees) ≅ AVG(ideal effort)
/// Note: that this requires the input effort have a symetric distribution around a mean of 0.5
/// The exact semantics of that transformation and representation and not something the cloud app should
/// have to concern themselves about.
public struct ExpectedEffort: Hashable, Sendable {
    /// The privacy transformed value is expressed as ``numerator`` / ``denominator``
    /// Numerator is a value between [0, denominator]
    /// Noise has been added such that *in the aggregate across a large number of requests*
    /// `AVG(Double(numerator)/Double(denominator)) = AVG(ideal)`
    ///
    /// ``denominator`` is guaranteed to be a number of form `(2^n)-1` in range `[1, maxGranularity]`
    /// so the granularities are always nested.
    /// ``maxGranularity`` is guaranteed not to increase without agreement with all parties
    ///  The current agreed value is 31.
    package struct DegradedValue: Hashable, Sendable, ByteBufferCodable {
        public static let maxDenominator: UInt8 = 31

        public let numerator: UInt8
        public let denominator: UInt8

        private static func checkDenominator(denominator: UInt8) throws {
            guard denominator <= DegradedValue.maxDenominator else {
                throw ExpectedEffortError.useOfDegradedDenominatorAboveMaximum
            }
            let isPowerOfTwoMinusOne = (denominator > 0) && (((denominator + 1) & denominator) == 0)
            guard isPowerOfTwoMinusOne else {
                throw ExpectedEffortError.useOfDegradedDenominatorNotAPowerOfTwoMinusOne
            }
        }

        package init(numerator: UInt8, denominator: UInt8) throws {
            try Self.checkDenominator(denominator: denominator)
            guard numerator <= denominator else {
                throw ExpectedEffortError.numeratorGreaterThanDenominator
            }
            self.numerator = numerator
            self.denominator = denominator
        }

        /// Create the closest value such that `ideal` as a percentage is uniformly distributed
        /// in the range 0-denominator
        /// Due to the need to keep the mean at 0.5 values that fall on an exact boundary cannot use
        /// round half even or similar, we need to distribute them randomly, and if we do so
        /// inform the caller so they don't add more randomness on top of that
        package static func closest(
            ideal: Double,
            denominator: UInt8,
            rng: inout SystemRandomNumberGenerator
        ) throws -> (DegradedValue, wasSampled: Bool) {
            // do this now, even though it will happen again, fail fast
            try self.checkDenominator(denominator: denominator)
            guard ideal >= 0, ideal <= 1 else {
                throw ExpectedEffortError.outsideExpectedEffortRange
            }
            let numeratorDouble = ideal * Double(denominator + 1)
            // keeping denominator 2^n -1 makes this valid exact equality checking
            for boundary in UInt8(1) ... denominator {
                if numeratorDouble == Double(exactly: boundary)! {
                    // 50/50 this one or one back
                    let numerator: UInt8 = if Bool.random(using: &rng) {
                        boundary
                    } else {
                        boundary - 1
                    }
                    return try (.init(numerator: numerator, denominator: denominator), wasSampled: true)
                }
            }
            // we are not on an exact boundary so we fall back towards zero
            guard let numeratorUnclamped = UInt8(exactly: numeratorDouble.rounded(.towardZero)) else {
                // given the prior guard on closestTo this should never happen
                fatalError("\(numeratorDouble) when we expected an exact UInt8")
            }
            let numerator: UInt8
                // deal with the edge case where 1.0 gets you exactly denominator + 1
                = if numeratorUnclamped > denominator {
                denominator
            } else {
                numeratorUnclamped
            }
            return try (.init(numerator: numerator, denominator: denominator), wasSampled: false)
        }

        /// Create the closest value ignoring attempts to distribute values precisely on boundaries
        /// This should only be used in unit tests
        package static func closestStableForTesting(
            ideal: Double,
            denominator: UInt8 = maxDenominator
        ) throws -> DegradedValue {
            // do this now, even though it will happen again, fail fast
            try self.checkDenominator(denominator: denominator)
            guard ideal >= 0, ideal <= 1 else {
                throw ExpectedEffortError.outsideExpectedEffortRange
            }
            let numeratorDouble = ideal * Double(denominator + 1)
            // keeping denominator 2^n -1 makes this valid exact equality checking
            for boundary in UInt8(1) ... denominator {
                if numeratorDouble == Double(exactly: boundary)! {
                    // always round up arbitrarily
                    let numerator: UInt8 = boundary
                    return try .init(numerator: numerator, denominator: denominator)
                }
            }
            // we are not on an exact boundary so we fall back towards zero
            guard let numeratorUnclamped = UInt8(exactly: numeratorDouble.rounded(.towardZero)) else {
                // given the prior guard on closestTo this should never happen
                fatalError("\(numeratorDouble) when we expected an exact UInt8")
            }
            let numerator: UInt8
                // deal with the edge case where 1.0 gets you exactly denominator + 1
                = if numeratorUnclamped > denominator {
                denominator
            } else {
                numeratorUnclamped
            }
            return try .init(numerator: numerator, denominator: denominator)
        }

        /// return a value whose ``numerator`` is one more than this one
        /// If this would violate the rule that `numerator <= denominator` this will throw
        package func incremented() throws -> Self {
            return try .init(numerator: self.numerator + 1, denominator: self.denominator)
        }

        /// return a value whose ``numerator`` is one less than this one
        /// If this would violate the rule that `numerator >= 0` this will throw
        package func decremented() throws -> Self {
            return try .init(numerator: self.numerator - 1, denominator: self.denominator)
        }

        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            buffer.writeInteger(self.numerator)
            buffer.writeInteger(self.denominator)
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            try self.numerator = buffer.readHostIntegerOrThrow(as: UInt8.self)
            try self.denominator = buffer.readHostIntegerOrThrow(as: UInt8.self)
        }
    }

    private enum ClassifiedEffort: Hashable, Sendable, ByteBufferCodable {
        case ideal(Double)
        /// output from cb_jobhelper in customer
        case degraded(DegradedValue)
        /// output from cb_jobhelper outside customer
        case complete(ideal: Double, degraded: DegradedValue)

        package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            switch self {
            case .ideal(let ideal):
                buffer.writeHostInteger(0)
                try ideal.encode(to: &buffer)
            case .degraded(let degraded):
                buffer.writeHostInteger(1)
                try degraded.encode(to: &buffer)
            case .complete(let ideal, let degraded):
                buffer.writeHostInteger(2)
                try ideal.encode(to: &buffer)
                try degraded.encode(to: &buffer)
            }
        }

        package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
            let rawValue = try buffer.readHostIntegerOrThrow(as: Int.self)
            switch rawValue {
            case 0:
                self = try .ideal(.init(from: &buffer))
            case 1:
                self = try .degraded(.init(from: &buffer))
            case 2:
                self = try .complete(
                    ideal: .init(from: &buffer),
                    degraded: .init(from: &buffer)
                )
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [ByteBufferCodingKey(Self.self)],
                    debugDescription: "bad result enum case \(rawValue)"
                ))
            }
        }
    }

    // invariant: all ClassifiedEfforts will be of the same type
    private let namedEfforts: [String: ClassifiedEffort]

    package var effortsAfterDegrading: [String: (ideal: Double?, degraded: DegradedValue)] {
        return self.namedEfforts.mapValues { effort in
            return switch effort {
            case .ideal:
                fatalError("used effortsAfterDegrading without first degrading!")
            case .degraded(let degraded):
                (nil, degraded)
            case .complete(ideal: let ideal, degraded: let degraded):
                (.some(ideal), degraded)
            }
        }
    }

    /// Useful for testing
    internal var assertIdealsAreAvailable: [String: Double] {
        return self.namedEfforts.mapValues { effort in
            return switch effort {
            case .ideal(let ideal):
                ideal
            case .degraded:
                fatalError("used assertIdealsAreAvailable after discarding ideals!")
            case .complete(ideal: let ideal, degraded: _):
                ideal
            }
        }
    }

    package init() {
        self.namedEfforts = [:]
    }

    public init(namedEfforts: [String: Double]) throws {
        self.namedEfforts = try namedEfforts.mapValues {
            guard $0 >= 0, $0 <= 1.0 else {
                throw ExpectedEffortError.outsideExpectedEffortRange
            }
            return ClassifiedEffort.ideal($0)
        }
    }

    // callers responsibility to ensure invariants are maintained
    private init(
        invariantChecked: [String: ClassifiedEffort]
    ) {
        self.namedEfforts = invariantChecked
    }

    /// Apply the `body` to each ideal value to calculate the degraded one.
    /// Return the result as a new instance with the new degraded values.
    /// If `body` retuns nil drop that effort
    ///
    /// If no ideal values are available on this instance this throws
    /// - parameters:
    ///     - removeIdealValues: if true the ideal values are not retained on the new instance
    /// - returns: An new instance with the altered values
    package func degrade(
        removeIdealValues: Bool = true,
        _ body: (String, Double) throws -> DegradedValue?
    ) throws -> ExpectedEffort {
        let revised = try namedEfforts.compactMap { key, value in
            let idealValue: Double
            switch value {
            case .ideal(let ideal):
                idealValue = ideal
            case .degraded:
                // this is just a coding error, we should be doning this once
                throw ExpectedEffortError.noIdealValuesArePresent
            case .complete(ideal: let ideal, degraded: _):
                // entirely ignore the old degraded values, we replace them all
                idealValue = ideal
            }
            if let degraded = try body(key, idealValue) {
                let newValue = removeIdealValues ?
                    ClassifiedEffort.degraded(degraded) :
                    ClassifiedEffort.complete(ideal: idealValue, degraded: degraded)
                return (key, newValue)
            } else {
                return nil
            }
        }
        return .init(invariantChecked: .init(uniqueKeysWithValues: revised))
    }

    // MARK: ByteBufferCodable without declaration

    package func encode(to buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        try self.namedEfforts.encode(to: &buffer)
    }

    package init(from buffer: inout CloudBoardAsyncXPC.ByteBuffer) throws {
        self.namedEfforts = try .init(from: &buffer)
    }
}
