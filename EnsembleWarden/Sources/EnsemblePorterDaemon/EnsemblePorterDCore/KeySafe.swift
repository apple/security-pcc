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
//  KeySafe.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 2025-08-01.
//

package import CryptoKit
package import EnsemblePorterCommon
@_spi(OSMetric) private import os
private import OSLog
private import Synchronization

/// Thread-safe storage for cryptographic keys used by EnsemblePorter.
///
/// Keys are supplied in two phases:
/// 1. FT/ET key is set immediately when orchestration starts via `setFTETKey(_:)`
/// 2. Turn keys are supplied later via `supplyTurnKeys(_:)` (from CloudBoard or `[]` for FT/ET-only)
///
/// Consumers can wait for keys to be ready via `waitForTurnKeys()`.
package final class EnsemblePorterKeySafe: Sendable {

    /// Internal state machine for managing key lifecycle.
    private enum StateMachine: Sendable {
        /// Initial state - no keys yet.
        case idle

        /// FT/ET key set, waiting for turn keys. Optional waiter continuation.
        case awaitingTurnKeys(ftETKey: SymmetricKey, waiter: CheckedContinuation<Void, Error>?)

        /// All keys ready for use.
        case ready(turnKeys: [SymmetricKey], ftETKey: SymmetricKey)
    }

    private let stateMachine: Mutex<StateMachine>
    private let logger = Logger(subsystem: EnsemblePorterConstants.loggerSubsystem, category: "KeySafe")
    private let metrics: EnsemblePorterMetrics

    /// Creates a new key safe in the idle state.
    package init(metrics: EnsemblePorterMetrics) {
        self.stateMachine = .init(.idle)
        self.metrics = metrics
    }

    // MARK: - Two-Phase Key Supply API

    /// Sets the FT/ET key. Called at orchestration start.
    ///
    /// This transitions from `idle` to `awaitingTurnKeys` state.
    /// - Parameter key: The derived FT/ET key (256 bits).
    /// - Throws: `EnsemblePorterError.keysAlreadySupplied` if FT/ET key was already set.
    package func setFTETKey(_ key: SymmetricKey) throws {
        try self.stateMachine.withLock { state in
            switch state {
            case .idle:
                state = .awaitingTurnKeys(ftETKey: key, waiter: nil)
            case .awaitingTurnKeys, .ready:
                self.logger.warning("setFTETKey called when FT/ET key already set")
                throw EnsemblePorterError.keysAlreadySupplied
            }
        }
    }

    /// Supplies turn keys. Wakes any waiter.
    ///
    /// Pass `[]` for FT/ET-only requests (no turn keys from CloudBoard).
    /// - Parameter keys: The turn keys from CloudBoard, or empty array for FT/ET-only.
    /// - Throws: `EnsemblePorterError.keysNotYetSupplied` if FT/ET key not set,
    ///           `EnsemblePorterError.keysAlreadySupplied` if turn keys already supplied.
    package func supplyTurnKeys(_ keys: [SymmetricKey]) throws {
        try self.stateMachine.withLock { state in
            switch state {
            case .idle:
                self.metrics.incrementKeyProvision(success: false, error: .keysNotYetSupplied)
                throw EnsemblePorterError.keysNotYetSupplied
            case .awaitingTurnKeys(let ftETKey, let waiter):
                state = .ready(turnKeys: keys, ftETKey: ftETKey)
                self.metrics.turnKeysStored.set(Int64(keys.count))
                waiter?.resume(returning: ())
            case .ready:
                self.metrics.incrementKeyProvision(success: false, error: .keysAlreadySupplied)
                throw EnsemblePorterError.keysAlreadySupplied
            }
        }
    }

    /// Waits until turn keys are supplied.
    ///
    /// Returns immediately if keys are already ready.
    /// Throws `CancellationError` if the task is cancelled while waiting.
    /// - Precondition: `setFTETKey(_:)` must have been called first.
    package func waitForTurnKeys() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.stateMachine.withLock { state in
                    switch state {
                    case .idle:
                        // This shouldn't happen in correct usage
                        self.logger.error("waitForTurnKeys called before setFTETKey")
                        fatalError("waitForTurnKeys called before setFTETKey")
                    case .awaitingTurnKeys(let ftETKey, nil):
                        state = .awaitingTurnKeys(ftETKey: ftETKey, waiter: continuation)
                    case .awaitingTurnKeys(_, .some):
                        self.logger.error("Multiple waiters for turn keys")
                        fatalError("Multiple waiters for turn keys")
                    case .ready:
                        continuation.resume(returning: ())
                    }
                }
            }
        } onCancel: {
            self.stateMachine.withLock { state in
                if case .awaitingTurnKeys(let ftETKey, let waiter) = state {
                    state = .awaitingTurnKeys(ftETKey: ftETKey, waiter: nil)
                    waiter?.resume(throwing: CancellationError())
                }
            }
        }
    }

    /// Supplies both turn keys and FT/ET key in one call.
    ///
    /// - Parameters:
    ///   - turnKeys: The turn keys from CloudBoard.
    ///   - ftETKey: The derived FT/ET key.
    /// - Throws: `EnsemblePorterError.keysAlreadySupplied` if keys were already supplied.
    package func supply(turnKeys: [SymmetricKey], ftETKey: SymmetricKey) throws {
        try self.stateMachine.withLock { state in
            switch state {
            case .idle:
                state = .ready(turnKeys: turnKeys, ftETKey: ftETKey)
                self.metrics.turnKeysStored.set(Int64(turnKeys.count))
            case .awaitingTurnKeys(_, let waiter):
                state = .ready(turnKeys: turnKeys, ftETKey: ftETKey)
                self.metrics.turnKeysStored.set(Int64(turnKeys.count))
                waiter?.resume(returning: ())
            case .ready:
                self.metrics.incrementKeyProvision(success: false, error: .keysAlreadySupplied)
                throw EnsemblePorterError.keysAlreadySupplied
            }
        }
    }

    // MARK: - Key Retrieval

    package var ftETKey: SymmetricKey? {
        return self.stateMachine.withLock { state in
            switch state {
            case .idle:
                return nil
            case .awaitingTurnKeys(let ftETKey, _):
                return ftETKey
            case .ready(_, let ftETKey):
                return ftETKey
            }
        }
    }

    package func retrieveKey(turnNumber: Int) throws -> SymmetricKey {
        // Special case: Int.max is reserved for FT/ET key
        if turnNumber == Int.max {
            return try self.stateMachine.withLock { state in
                switch state {
                case .idle, .awaitingTurnKeys:
                    self.metrics.incrementKeyFetch(success: false, error: .keysNotYetSupplied)
                    throw EnsemblePorterError.keysNotYetSupplied
                case .ready(turnKeys: _, ftETKey: let ftETKey):
                    return ftETKey
                }
            }
        }

        guard turnNumber >= 0 else {
            self.metrics.incrementKeyFetch(success: false, error: .noKeyForTurn(turnNumber))
            throw EnsemblePorterError.noKeyForTurn(turnNumber)
        }
        return try self.stateMachine.withLock { state in
            switch state {
            case .idle, .awaitingTurnKeys:
                self.metrics.incrementKeyFetch(success: false, error: .keysNotYetSupplied)
                throw EnsemblePorterError.keysNotYetSupplied
            case .ready(turnKeys: let keys, ftETKey: _):
                // Ensure that we have the key before trying to return it.
                guard keys.count > turnNumber else {
                    self.metrics.incrementKeyFetch(success: false, error: .noKeyForTurn(turnNumber))
                    throw EnsemblePorterError.noKeyForTurn(turnNumber)
                }
                return keys[turnNumber]
            }
        }
    }

    package func getNumberOfTurnKeys() throws -> Int {
        return try self.stateMachine.withLock { state in
            switch state {
            case .idle, .awaitingTurnKeys:
                self.metrics.incrementKeyFetch(success: false, error: .keysNotYetSupplied)
                throw EnsemblePorterError.keysNotYetSupplied
            case .ready(turnKeys: let keys, ftETKey: _):
                return keys.count
            }
        }
    }
}
