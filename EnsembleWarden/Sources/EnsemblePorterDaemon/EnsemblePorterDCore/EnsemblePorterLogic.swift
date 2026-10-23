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
//  EnsemblePorter+.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 2025-08-29.
//

package import CryptoKit
package import EnsemblePorterCommon
private import EnsemblePorterProtos
package import EnsembleWardenServer
package import Foundation
private import InternalSwiftProtobuf
@_spi(OSMetric) private import os
internal import OSLog
internal import Synchronization

/// Contains the core business logic common to XPCSession and XPCDistributed clients.
package final class EnsemblePorterLogic<IntraEnsembleTransponder: EnsembleTransponder>: Sendable {

    package let keySafe: EnsemblePorterKeySafe
    internal let intraEnsembleTransponder: IntraEnsembleTransponder
    internal let followerIntraEnsemblePrivateKey = Curve25519.KeyAgreement.PrivateKey()
    internal let followerInfo: [FollowerInfo]
    internal let followerTokensFetched: Mutex<Bool> = .init(false)
    internal let metrics: EnsemblePorterMetrics

    /// Stores the derived FT/ET key for use by ftETOnlyTurn().
    /// Set when orchestrateCryptoMaterialCoordination() starts.
    private let storedDerivedKey: Mutex<SymmetricKey?> = .init(nil)

    /// Tracks whether multi-turn mode is active (true) or FT/ET-only mode (false).
    /// Used by waitForMultiTurnMode() to unblock when mode is determined.
    private enum MultiTurnModeState: Sendable {
        case undetermined(CheckedContinuation<Bool, Never>?)
        case determined(Bool)
    }
    private let multiTurnModeState: Mutex<MultiTurnModeState> = .init(.undetermined(nil))

    internal let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "EnsemblePorterLogic")

    package init(keySafe: EnsemblePorterKeySafe,
                 intraEnsembleTransponder: IntraEnsembleTransponder,
                 followerInfo: [FollowerInfo],
                 metrics: EnsemblePorterMetrics) {
        self.keySafe = keySafe
        self.intraEnsembleTransponder = intraEnsembleTransponder
        self.followerInfo = followerInfo
        self.metrics = metrics
    }

    /// Returns the key for the specified turn number.
    /// - Parameters:
    ///   - turnNumber: The turn number.
    ///   - requestID: The request identifier.
    ///   - spanID: The span ID.
    package func fetch(turnNumber: Int) throws -> Data {
        let startTime = ContinuousClock.now
        defer {
            let duration = ContinuousClock.now - startTime
            self.metrics.fetchRequestDuration.set(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        }

        let key = try self.keySafe.retrieveKey(turnNumber: turnNumber)

        // Can't pass SymmetricKeys over XPC so need to convert to Data)
        let keyAsData = key.withUnsafeBytes { bytes in
            Data(bytes: bytes.baseAddress!, count: bytes.count)
        }
        self.metrics.incrementKeyFetch(success: true)
        return keyAsData
    }

    package func getNumberOfTurnKeys() throws -> Int {
        let count = try self.keySafe.getNumberOfTurnKeys()
        PrismTracing.logCheckpoint(name: "EnsemblePorterGotNumberOfTurnKeys", level: .debug)
        return count
    }

    // MARK: - FT/ET Only Turn Handling

    /// Signals that this turn only uses the FT/ET key (no multi-turn keys from CloudBoard).
    ///
    /// This method supplies empty turn keys to KeySafe and distributes to followers.
    /// For multi-turn requests, don't call this - the system will wait for CloudBoard keys.
    package func ftETOnlyTurn() async {
        self.logger.log("""
            ftETOnlyTurn called - supplying empty turn keys. \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID, privacy: .public)
            """)

        // Signal that multi-turn mode is false (FT/ET-only)
        self.multiTurnModeState.withLock { state in
            switch state {
            case .undetermined(let continuation):
                state = .determined(false)
                continuation?.resume(returning: false)
            case .determined:
                break
            }
        }

        // Get the FT/ET key from KeySafe
        guard let ftETKey = self.keySafe.ftETKey else {
            self.logger.error("""
                ftETOnlyTurn called but no derived key in KeySafe. \
                Orchestration may not have started yet. \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
            return
        }

        do {
            // Supply empty turn keys to KeySafe
            try self.keySafe.supplyTurnKeys([])

            // Distribute to followers
            let cryptoMaterial = Apple_Cloudos_Cloudllm_EnsemblePorterCryptoMaterial.with {
                $0.turnKeys = Apple_Cloudos_Cloudllm_TurnKeys()  // Empty
                $0.ftEtKey = ftETKey.withUnsafeBytes { Data($0) }
            }
            try await self.sendCryptoPayloadToFollowersIfRequired(try cryptoMaterial.serializedData())

            self.logger.log("""
                FT/ET-only turn complete. \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
        } catch {
            self.logger.error("""
                ftETOnlyTurn failed. \
                error=\(String(reportable: error), privacy: .public) \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
        }
    }

    /// Waits for and returns whether multi-turn mode is active.
    ///
    /// Returns true if crypto materials are provided (multi-turn mode).
    /// Returns false if ftETOnlyTurn() is called (FT/ET-only mode).
    package func waitForMultiTurnMode() async -> Bool {
        return await withCheckedContinuation { continuation in
            self.multiTurnModeState.withLock { state in
                switch state {
                case .undetermined(nil):
                    state = .undetermined(continuation)
                case .undetermined(.some):
                    fatalError("Multiple waiters for multi-turn mode state")
                case .determined(let isMultiTurn):
                    continuation.resume(returning: isMultiTurn)
                }
            }
        }
    }

    /// Supplies the FT/ET key and distributes it to followers.
    ///
    /// This is used for multi-turn mode initialization. On the leader, this will:
    /// 1. Set the FT/ET key in KeySafe
    /// 2. Distribute the key to all followers
    ///
    /// On followers, this is a no-op (they receive keys from the leader).
    ///
    /// - Parameter ftETKey: The FT/ET key to supply
    /// - Throws: `EnsemblePorterError.invalidKeysSupplied` if the key is invalid
    package func supply(ftETKey: SymmetricKey) async throws {
        // Validate key size
        guard ftETKey.bitCount == SymmetricKeySize.bits256.bitCount else {
            self.logger.error("""
                FT/ET key has invalid length. \
                expected=\(SymmetricKeySize.bits256.bitCount) \
                actual=\(ftETKey.bitCount) \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
            throw EnsemblePorterError.invalidKeysSupplied
        }

        // Check if this is a leader node
        let nodeInfo = try await self.intraEnsembleTransponder.nodeInfo()
        guard nodeInfo.leader else {
            // Followers don't supply keys - they receive them from the leader
            self.logger.log("""
                supply(ftETKey:) called on follower - no-op. \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID, privacy: .public)
                """)
            return
        }

        // Store the derived key for ftETOnlyTurn
        self.storedDerivedKey.withLock { $0 = ftETKey }

        // Set FT/ET key in KeySafe
        try self.keySafe.setFTETKey(ftETKey)

        // Create crypto material with just the FT/ET key (no turn keys yet)
        let cryptoMaterial = Apple_Cloudos_Cloudllm_EnsemblePorterCryptoMaterial.with {
            $0.turnKeys = Apple_Cloudos_Cloudllm_TurnKeys()  // Empty initially
            $0.ftEtKey = ftETKey.withUnsafeBytes { Data($0) }
        }

        // Distribute to followers
        try await self.sendCryptoPayloadToFollowersIfRequired(try cryptoMaterial.serializedData())

        self.logger.log("""
            FT/ET key supplied and distributed. \
            request_id=\(PrismTracing.requestID, privacy: .public) \
            span_id=\(PrismTracing.spanID, privacy: .public)
            """)
    }

    /// Coordinates crypto material distribution with multi-turn mode decision.
    ///
    /// This method:
    /// 1. Sets the FT/ET key in KeySafe immediately
    /// 2. Listens for crypto material from CloudBoard
    /// 3. Waits for turn keys to be supplied (either from CloudBoard or ftETOnlyTurn)
    /// 4. Cancels the listener when keys are ready
    ///
    /// - Parameters:
    ///   - derivedKey: The FT/ET key for crypto material distribution
    ///   - requestID: Request ID for tracing
    ///   - spanID: Span ID for tracing
    ///   - cryptoMaterials: Async stream of crypto material data
    package func orchestrateCryptoMaterialCoordination(
        derivedKey: SymmetricKey,
        requestID: UUID,
        spanID: UInt64,
        cryptoMaterials: AsyncStream<Data>
    ) async throws {
        // Store the derived key so ftETOnlyTurn() can access it
        self.storedDerivedKey.withLock { $0 = derivedKey }

        // Set FT/ET key immediately
        try self.keySafe.setFTETKey(derivedKey)

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Listen for crypto material from CloudBoard
            group.addTask {
                for await material in cryptoMaterials {
                    try Task.checkCancellation()
                    self.logger.log("""
                        Received crypto material. \
                        request_id=\(requestID, privacy: .public) \
                        span_id=\(spanID, privacy: .public)
                        """)

                    // Signal multi-turn mode on first material
                    self.multiTurnModeState.withLock { state in
                        switch state {
                        case .undetermined(let continuation):
                            state = .determined(true)
                            continuation?.resume(returning: true)
                        case .determined:
                            break
                        }
                    }

                    // Decode TurnKeys from CloudBoard/TIE
                    let turnKeys: Apple_Cloudos_Cloudllm_TurnKeys
                    do {
                        turnKeys = try .init(serializedBytes: material)
                    } catch {
                        self.logger.error("""
                            Error decoding turn keys protobuf from CloudBoard/TIE. \
                            error=\(String(reportable: error), privacy: .public) \
                            request_id=\(requestID, privacy: .public) \
                            span_id=\(spanID, privacy: .public)
                            """)
                        throw EnsemblePorterError.invalidKeysSupplied
                    }

                    // Combine TurnKeys + ftETKey into EnsemblePorterCryptoMaterial for distribution
                    let combinedMaterial = Apple_Cloudos_Cloudllm_EnsemblePorterCryptoMaterial.with {
                        $0.turnKeys = turnKeys
                        $0.ftEtKey = derivedKey.withUnsafeBytes { Data($0) }
                    }

                    try await self.provide(additionalCryptoPayload: try combinedMaterial.serializedData())
                }
            }

            // Wait for turn keys to be supplied (either from CloudBoard or being signalled that its an FT/ET only turn)
            try await self.keySafe.waitForTurnKeys()

            self.logger.log("""
                Turn keys ready - orchestration complete. \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID, privacy: .public)
                """)

            // Keys are ready - cancel listener if still running
            group.cancelAll()
        }
    }
}

extension Data {
    init(uuid: UUID) {
        var uuidCopy = uuid.uuid
        self = Swift.withUnsafeBytes(of: &uuidCopy) { Data($0) }
    }
}
