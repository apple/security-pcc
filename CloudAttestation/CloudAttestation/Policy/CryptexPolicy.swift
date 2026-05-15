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

//
//  CryptexPolicy.swift
//  CloudAttestation
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Foundation
import CryptoKit
import os.log
import FeatureFlags

/// Defines an ``AttestationPolicy`` that evaluates the loaded sequence of Cryptexes on a device.
public struct CryptexPolicy: AttestationPolicy {
    /// The well-known Sealed Software Hash Slot UUID for SEP measured cryptexes.
    public static let slot: UUID = cryptexSlotUUID
    /// The well-known Sealed Software Hash Slot UUID for AP-only measured cryptexes.
    public static let apSlot: UUID = apCryptexSlotUUID

    static let logger: Logger = Logger(subsystem: "com.apple.CloudAttestation", category: "CryptexPolicy")

    let sealedHashesLoader: SealedHashesLoader
    let requireLocked: Bool

    @available(*, deprecated, message: "fallback no longer allowed")
    public init(_ sealedHashes: [UUID: SEP.SealedHash], locked: Bool, fallback: Bool) {
        self.sealedHashesLoader = .immediate(sealedHashes)
        self.requireLocked = locked
    }

    /// Creates a ``CryptexPolicy``.
    /// - Parameters:
    ///   - sealedHashes: The sealed hashes to use for verification.
    ///   - locked: The ``AttestationPolicy`` should require the device to be locked.
    public init(_ sealedHashes: [UUID: SEP.SealedHash], locked: Bool) {
        self.sealedHashesLoader = .immediate(sealedHashes)
        self.requireLocked = locked
    }

    @available(*, deprecated, message: "fallback no longer allowed")
    public init(locked: Bool, fallback: Bool) {
        self.sealedHashesLoader = .lazy
        self.requireLocked = locked
    }

    /// Creates a ``CryptexPolicy``.
    /// - Parameter locked: The ``AttestationPolicy`` should require the device to be locked.
    public init(locked: Bool) {
        self.sealedHashesLoader = .lazy
        self.requireLocked = locked
    }

    /// Evaluates the Cryptex information within the ``AttestationBundle``.
    ///
    /// A virtual Software Sealed Hash value will be calculated by ratcheting all of the provided cryptex load sequence information from the
    /// attestation bundle. This value is then compared against the expected digest value, which should come from a verified SEP Attestation Blob.
    ///
    /// - Parameters:
    ///     - bundle: the ``AttestationBundle`` to verify
    ///
    /// - Throws: ``CryptexPolicy/Error`` if the expected digest is missing, no cryptex load sequences are provided, or the digest values to not match.
    public func evaluate(bundle: AttestationBundle, context: inout AttestationPolicyContext) async throws {
        let sealedHashes: [UUID: SEP.SealedHash] =
            switch self.sealedHashesLoader {
            case .immediate(let shs):
                shs
            case .lazy:
                Self.cryptexSealedHashes(from: context.validatedAttestation) ?? [:]
            }

        let cryptexSealedHash = sealedHashes[Self.slot]
        let cryptexes = bundle.proto.cryptexes(slot: Self.slot)

        if cryptexes == nil {
            let sealedHashEmptylocked = cryptexSealedHash == Self.wellKnownEmptyLockedSEPSealedHash
            let sealedHashNilOrEmptyLocked = cryptexSealedHash == nil || sealedHashEmptylocked

            if !requireLocked && sealedHashNilOrEmptyLocked {
                Self.logger.warning("Device has no cryptexes installed")
                return
            }

            if requireLocked && sealedHashEmptylocked {
                Self.logger.warning("Device has no cryptexes installed, and is in cryptex lockdown")
                return
            }
        }

        guard let cryptexSealedHash else {
            Self.logger.error("Missing cryptex sealed hash slot from SEP Attestation")
            throw Error.missingCryptexSealedHash
        }

        guard let cryptexes = cryptexes else {
            Self.logger.error("Missing cryptex ledger from SecureConfigDB")
            throw Error.missingCryptexLedger(uuid: Self.slot, value: cryptexSealedHash.value)
        }

        let secureConfigLocked: Bool
        if case .locked = cryptexes {
            secureConfigLocked = true
        } else {
            secureConfigLocked = false
        }

        // This flag should always be present
        guard cryptexSealedHash.flags.contains(.cryptexMeasurement) else {
            Self.logger.error("SEP Cryptex Sealed Hash Slot is missing .cryptexMeasurement")
            throw Error.missingCryptexMeasurementFlag
        }

        let sealedHashLocked = cryptexSealedHash.flags.contains(.ratchetLocked)

        Self.logger.log("Observed Cryptex Lockdown State: \(sealedHashLocked)")

        if self.requireLocked {
            // we should make sure the reported lock state from SecureConfigDB (malleable) matches the SEP SSR lock state (trusted)
            guard secureConfigLocked == sealedHashLocked else {
                Self.logger.error("Cryptex Log and SEP Attestation's Sealed Hash have inconsistent lock states")
                throw Error.inconsistentLockState(secureConfigLocked: secureConfigLocked, sealedHashLocked: sealedHashLocked)
            }

            guard secureConfigLocked && sealedHashLocked else {
                Self.logger.error("Cryptex slot is unexpectedly unlocked")
                throw Error.unlocked(secureConfigLocked: secureConfigLocked, sealedHashLocked: sealedHashLocked)
            }
        }

        let cryptexHashFunc = bundle.proto.cryptexHashFunction ?? SHA384.self

        let replayedDigest: SEP.SealedHash.Value
        do {
            replayedDigest = try cryptexes.replaySealedHash(with: cryptexHashFunc)
        } catch {
            Self.logger.error("Unexpected error replaying the cryptex log: \(error, privacy: .public)")
            throw Error.replayFailure(error)
        }

        guard replayedDigest == cryptexSealedHash.value else {
            Self.logger.error("Cryptex log from SecureConfigDB did not replay against SEP Attestation's Sealed Hash")
            throw Error.replayMismatch(replayed: replayedDigest, expected: cryptexSealedHash.value)
        }

        Self.logger.log("AttestationBundle passed CryptexPolicy: reported cryptexes match SEP attestation")
    }
}

// MARK: - CryptexPolicy Error
extension CryptexPolicy {
    public enum Error: Swift.Error {
        case missingCryptexSealedHash
        case missingCryptexLedger(uuid: UUID, value: SEP.SealedHash.Value)
        case inconsistentLockState(secureConfigLocked: Bool, sealedHashLocked: Bool)
        case unlocked(secureConfigLocked: Bool, sealedHashLocked: Bool)
        case replayMismatch(replayed: SEP.SealedHash.Value, expected: SEP.SealedHash.Value)
        case replayFailure(Swift.Error)
        case missingCryptexMeasurementFlag
    }
}

// MARK: - SealedHash loader
extension CryptexPolicy {
    enum SealedHashesLoader: Sendable {
        case lazy
        case immediate([UUID: SEP.SealedHash])
    }
}

// MARK: - Helpers

extension CryptexPolicy {
    fileprivate static func cryptexSealedHashes(from attestation: SEP.Attestation?) -> [UUID: SEP.SealedHash]? {
        guard let attestation else {
            return nil
        }
        var out: [UUID: SEP.SealedHash] = [:]

        if let cryptexSlot = attestation.sealedHash(at: Self.slot) {
            out[Self.slot] = cryptexSlot
        }

        return out
    }

    private static let wellKnownEmptyLockedSEPSealedHash = try! SEP.SealedHash(digest: Data(repeating: 0, count: 48), flags: [.cryptexMeasurement, .ratchet, .ratchetLocked])
}
