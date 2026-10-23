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
import InternalSwiftProtobuf
import os

extension PersistentClientHelperManager {
    /// State machine for a single persistent gRPC stream.
    ///
    /// Each `runStream` invocation (primary or replacement) has its own instance.
    /// Processes response messages and returns actions for the caller to execute.
    /// All state transitions are encapsulated here, making the response pump a simple
    /// dispatch loop with no conditional state logic.
    ///
    /// ## States
    ///
    /// - `attestationPending`: Waiting for the server to respond to our attestation query.
    /// - `settingUp`: Attestation received (or cached). Helper is being spawned, OHTTP key
    ///   exchange in progress, waiting for SetupAck from server.
    /// - `active`: SetupAck received. Encrypted traffic is flowing. The connection is fully
    ///   operational.
    /// - `replacementPending`: A `connectionShouldBeRecreated` signal was received while
    ///   active. A replacement stream is being set up in parallel. This stream continues
    ///   serving traffic until the server drains it.
    /// - `draining`: The server sent `drainingStarted` or `drainingCritical`. No new work
    ///   will arrive, but in-flight responses continue until the server closes the stream.
    ///
    /// ## State Diagram
    ///
    /// ```
    ///                          ┌──────────────────────┐
    ///                          │  attestationPending  │
    ///                          └──────────┬───────────┘
    ///                                     │ responseToQuery (with attestation)
    ///                                     │ → .activated
    ///                                     ▼
    ///                          ┌──────────────────────┐
    ///                          │     settingUp        │
    ///                          └──────────┬───────────┘
    ///                                     │ setupAck
    ///                                     │ → .setupComplete
    ///                                     ▼
    ///                          ┌─────────────────────┐
    ///                          │       active        │
    ///                          └───┬─────────────┬───┘
    ///                              │             │
    ///     connectionShouldBeRecreated           drainingStarted/Critical
    ///     (with attestation)       │             │
    ///     → .startReplacement      │             │ → .continue
    ///                              ▼             ▼
    ///              ┌──────────────────┐   ┌──────────┐
    ///              │replacementPending│   │ draining │
    ///              └────────┬─────────┘   └──────────┘
    ///                       │
    ///                       │ drainingStarted/Critical
    ///                       │ → .continue
    ///                       ▼
    ///                 ┌──────────┐
    ///                 │ draining │
    ///                 └──────────┘
    /// ```
    ///
    /// **From any state:**
    /// - `connectionMustBeRecreated` / `connectionRecreationForced` → `.reconnect`
    /// - `keepAlive` → `.continue`
    /// - `nil` response type → `.protocolError`
    /// - `undefined` / `UNRECOGNIZED` lifecycle events → `.protocolError`
    ///
    /// **`connectionShouldBeRecreated` without attestation from `active`:**
    /// Falls back to `.reconnect` (can't start replacement without an attestation).
    ///
    /// **`responseChunk` in `active` / `replacementPending` / `draining`:**
    /// → `.forwardResponseChunk` (forwarded to the stream's helper)
    ///
    /// **`responseToQuery` in any state except `attestationPending`:**
    /// Caches the attestation for the next connection, returns `.continue`.
    struct ConnectionStateMachine {
        enum State: Sendable, Equatable, CustomStringConvertible {
            case attestationPending
            /// Helper is being spawned, OHTTP key exchange in progress, waiting for SetupAck.
            case settingUp
            case active
            /// A reconnection has been requested but the node is still usable for queries.
            case replacementPending
            case draining

            var description: String {
                switch self {
                case .attestationPending: "attestationPending"
                case .settingUp: "settingUp"
                case .active: "active"
                case .replacementPending: "replacementPending"
                case .draining: "draining"
                }
            }
        }

        /// Actions the response pump should take after processing a message.
        enum Action: Equatable {
            case `continue`
            /// Attestation received — start helper setup (transitions to settingUp).
            case activated(AttestationInfo)
            /// SetupAck received — helper is fully bridged, enter active state.
            case setupComplete
            /// Forward an encrypted response chunk to the helper.
            case forwardResponseChunk(Data, isFinal: Bool)
            /// Start a replacement stream in parallel with the cached attestation.
            /// Only returned once per connection (2-stream limit enforced by replacementPending).
            case startReplacement(AttestationInfo)
            /// Server signalled graceful draining — stop routing new queries,
            /// but in-flight responses will still arrive.
            case enteredDraining
            /// Server signalled critical draining — the stream is about to be
            /// force-closed. The helper should be treated as effectively removed.
            case enteredDrainingCritical
            case reconnect
            case protocolError
        }

        private(set) var state: State
        private(set) var cachedAttestation: AttestationInfo?

        init(initialState: State, cachedAttestation: AttestationInfo?) {
            self.state = initialState
            self.cachedAttestation = cachedAttestation
        }

        mutating func handleResponse(
            _ responseType: PersistentServiceResponse.OneOf_Type?
        ) -> Action {
            guard let responseType else {
                return .protocolError
            }

            switch responseType {
            case .connectionLifecycle(let lifecycle):
                return self.handleConnectionLifecycle(lifecycle)
            case .serverLifeCycle(let serverLifecycle):
                return self.handleServerLifecycle(serverLifecycle)
            case .keepAlive:
                return .continue
            case .setupAck:
                return self.handleSetupAck()
            case .responseChunk(let chunk):
                return self.handleResponseChunk(chunk)
            }
        }

        // MARK: SetupAck handling

        private mutating func handleSetupAck() -> Action {
            switch self.state {
            case .settingUp:
                self.state = .active
                return .setupComplete
            case .attestationPending, .active, .replacementPending, .draining:
                return .protocolError
            }
        }

        // MARK: Response chunk handling

        private func handleResponseChunk(
            _ chunk: Proto_Ropes_Common_Chunk
        ) -> Action {
            switch self.state {
            case .active, .replacementPending, .draining:
                return .forwardResponseChunk(chunk.encryptedPayload, isFinal: chunk.isFinal)
            case .attestationPending, .settingUp:
                return .protocolError
            }
        }

        // MARK: Connection lifecycle

        private mutating func handleConnectionLifecycle(
            _ lifecycle: PersistentServiceResponse.ConnectionLifecycleMessage
        ) -> Action {
            switch lifecycle.eventType {
            case .responseToQuery:
                return self.handleAttestationResponse(lifecycle)

            case .connectionShouldBeRecreated:
                self.cacheAttestation(from: lifecycle)
                switch self.state {
                case .attestationPending, .settingUp:
                    return .reconnect
                case .replacementPending, .draining:
                    // Already replacing or draining — 2-stream limit. Just update the cached
                    // attestation for the next connection if the replacement also needs replacing.
                    return .continue
                case .active:
                    guard let cached = self.cachedAttestation else {
                        // No attestation to use for replacement — reconnect instead
                        return .reconnect
                    }
                    self.state = .replacementPending
                    return .startReplacement(cached)
                }

            case .connectionMustBeRecreated, .connectionRecreationForced:
                self.cacheAttestation(from: lifecycle)
                return .reconnect

            case .undefined, .UNRECOGNIZED:
                return .protocolError

            @unknown default:
                return .protocolError
            }
        }

        private mutating func handleAttestationResponse(
            _ lifecycle: PersistentServiceResponse.ConnectionLifecycleMessage
        ) -> Action {
            guard lifecycle.hasSuggestedAttestation else { return .continue }
            let info = PersistentClientHelperManager.attestationInfo(from: lifecycle.suggestedAttestation)

            switch self.state {
            case .attestationPending:
                self.state = .settingUp
                self.cachedAttestation = nil
                return .activated(info)
            case .settingUp, .active, .replacementPending, .draining:
                self.cachedAttestation = info
                return .continue
            }
        }

        // MARK: Server lifecycle

        private mutating func handleServerLifecycle(
            _ serverLifecycle: PersistentServiceResponse.ServerLifecycleMessage
        ) -> Action {
            switch serverLifecycle.eventType {
            case .drainingStarted:
                if self.state == .draining {
                    return .continue
                }
                self.state = .draining
                return .enteredDraining
            case .drainingCritical:
                self.state = .draining
                return .enteredDrainingCritical
            case .undefined, .UNRECOGNIZED:
                return .protocolError
            @unknown default:
                return .protocolError
            }
        }

        // MARK: Helpers

        /// Caches the attestation from a lifecycle message for use on reconnection.
        /// When the message contains no attestation, the cache is cleared — the next
        /// reconnection will perform a full attestation round-trip.
        private mutating func cacheAttestation(
            from lifecycle: PersistentServiceResponse.ConnectionLifecycleMessage
        ) {
            if lifecycle.hasSuggestedAttestation {
                self.cachedAttestation = PersistentClientHelperManager.attestationInfo(
                    from: lifecycle.suggestedAttestation
                )
            } else {
                self.cachedAttestation = nil
            }
        }
    }

    /// Default lifetime applied when the server omits `expires_after` on a
    /// `SuggestedAttestation`. Producing a concrete date at the protobuf
    /// decode boundary lets every downstream consumer (cb_bridged's
    /// key-expiry watchdog, the wire payload to the router, the router's
    /// expiry-based reaper) treat the field as non-optional.
    private static let defaultAttestationLifetime: TimeInterval = 86400

    /// Build an `AttestationInfo` from a server-provided `SuggestedAttestation`,
    /// substituting the default lifetime and logging a warning when the
    /// server omits the `expires_after` field. Single source of truth for the
    /// substitution so both `.activated` and `.cacheAttestation` paths agree.
    fileprivate static func attestationInfo(
        from suggested: Com_Apple_Cloudboard_Api_V1_SuggestedAttestation
    ) -> AttestationInfo {
        let hardExpiry: Date
        if suggested.hasExpiresAfter {
            hardExpiry = suggested.expiresAfter.date
        } else {
            Self.logger.warning(
                "Suggested attestation omitted expires_after; defaulting to now + 24h"
            )
            hardExpiry = Date.now.addingTimeInterval(Self.defaultAttestationLifetime)
        }
        return AttestationInfo(
            keyID: suggested.keyID,
            bundle: suggested.attestationBundle,
            hardExpiry: hardExpiry
        )
    }
}
