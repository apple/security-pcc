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
import CloudBoardJobHelperAPI
import CloudBoardLogging
import CryptoKit
import Foundation
import InternalSwiftProtobuf
import os
import PersistentHelperInstance
import Synchronization

/// Bridges XPC responses from a persistent client helper to the connection manager.
///
/// Uses a phase state machine where each phase holds the Promise that will be fulfilled
/// during the transition out of that phase. This guarantees single-fulfillment structurally.
///
/// Phases:
/// 1. `awaitingInit` — captures OHTTP key; `.initialized` fulfills keyPromise
/// 2. `awaitingSetupAck` — buffers chunks; `setupAcknowledged()` flushes and transitions
/// 3. `awaitingMetadataValidation` — forwards chunks; `.metadataUpdate` fulfills validationPromise
/// 4. `forwarding` — steady state, chunks flow to `forwardedChunks`
final class PersistentClientConnectionDelegate: PersistentHelperAPIClientDelegateProtocol, Sendable {
    private static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "PersistentClientConnectionDelegate"
    )

    private enum Phase {
        case awaitingInit(
            encryptedKey: Data?,
            keyPromise: Promise<Data, Error>,
            validationPromise: Promise<Bool, Error>
        )
        case awaitingSetupAck(buffered: [(Data, Bool)], validationPromise: Promise<Bool, Error>)
        case awaitingMetadataValidation(validationPromise: Promise<Bool, Error>)
        case forwarding
        case failed
    }

    private let connectionID: String
    private let expectedServiceDefinedMetadata: Data
    private let phase: Mutex<Phase>

    private let keyFuture: Future<Data, Error>
    private let validationFuture: Future<Bool, Error>

    /// Cap on the pre-SetupAck buffered chunks and on the forwardedChunks stream.
    /// Keeps an upper bound on per-connection memory if setup stalls or the helper is fast.
    private static let chunkBufferCap = 4096

    /// Captures a promise fulfillment to execute *after* releasing `phase.withLock`.
    /// Promise fulfillment can synchronously resume awaiters or invoke observers; running
    /// those under the lock risks reentrant acquisition and deadlock.
    private enum PromiseFulfillment {
        case succeedKey(Promise<Data, Error>, Data)
        case failKey(Promise<Data, Error>, Error)
        case succeedValidation(Promise<Bool, Error>, Bool)
        case failValidation(Promise<Bool, Error>, Error)

        func apply() {
            switch self {
            case .succeedKey(let p, let v): p.succeed(with: v)
            case .failKey(let p, let e): p.fail(with: e)
            case .succeedValidation(let p, let v): p.succeed(with: v)
            case .failValidation(let p, let e): p.fail(with: e)
            }
        }
    }

    /// Stream of response chunks available after setup is acknowledged.
    let forwardedChunks: AsyncStream<(Data, Bool)>
    private let forwardContinuation: AsyncStream<(Data, Bool)>.Continuation

    /// Signal that all pending queries for this draining helper have completed.
    let drainCompleteSignal: AsyncStream<Void>
    private let drainCompleteContinuation: AsyncStream<Void>.Continuation

    init(connectionID: String, serviceDefinedMetadata: Data) {
        self.connectionID = connectionID
        self.expectedServiceDefinedMetadata = serviceDefinedMetadata

        let keyPromise = Promise<Data, Error>(autoFailureIfUnfulfilled: CancellationError())
        self.keyFuture = Future(keyPromise)
        let validationPromise = Promise<Bool, Error>(autoFailureIfUnfulfilled: CancellationError())
        self.validationFuture = Future(validationPromise)
        self.phase = Mutex(.awaitingInit(
            encryptedKey: nil,
            keyPromise: keyPromise,
            validationPromise: validationPromise
        ))

        let (chunkStream, chunkCont) = AsyncStream<(Data, Bool)>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.chunkBufferCap)
        )
        self.forwardedChunks = chunkStream
        self.forwardContinuation = chunkCont

        let (drainStream, drainCont) = AsyncStream<Void>.makeStream()
        self.drainCompleteSignal = drainStream
        self.drainCompleteContinuation = drainCont
    }

    /// Awaits the OHTTP encrypted key, available once `.initialized` is received.
    func waitForEncryptedKey() async throws -> Data {
        try await self.keyFuture.valueWithCancellation
    }

    /// Called by the manager after SetupAck is received from the gRPC response pump.
    /// Flushes buffered chunks and transitions to metadata validation phase.
    func setupAcknowledged() {
        let buffered: [(Data, Bool)] = self.phase.withLock { phase in
            guard case .awaitingSetupAck(let buf, let validationPromise) = phase else {
                Self.logger.warning(
                    "connectionID: \(self.connectionID, privacy: .public) setupAcknowledged called in unexpected phase"
                )
                return []
            }
            phase = .awaitingMetadataValidation(validationPromise: validationPromise)
            return buf
        }
        for (data, isFinal) in buffered {
            self.forwardContinuation.yield((data, isFinal))
        }
    }

    /// Awaits metadata validation result after setup is acknowledged.
    func waitForMetadataValidation() async throws -> Bool {
        try await self.validationFuture.valueWithCancellation
    }

    // MARK: - XPC message handling

    func handleResponse(_ response: PersistentHelperOutboundMessage) {
        switch response {
        case .initialized:
            self.handleInitialized()
        case .responseChunk(let data, isFinal: let isFinal):
            self.handleResponseChunk(data, isFinal: isFinal)
        case .failureReport(let reason):
            self.handleFailure(reason: reason)
        case .helperEOF:
            Self.logger.info(
                "connectionID: \(self.connectionID, privacy: .public) helper EOF"
            )
            self.forwardContinuation.finish()
        case .drainComplete:
            Self.logger.info(
                "connectionID: \(self.connectionID, privacy: .public) drain complete received from helper"
            )
            self.drainCompleteContinuation.yield(())
            self.drainCompleteContinuation.finish()
        case .metadataUpdate(let payload):
            self.handleMetadataUpdate(payload: payload)
        }
    }

    private func handleInitialized() {
        Self.logger.info(
            "connectionID: \(self.connectionID, privacy: .public) helper initialized"
        )
        let fulfillments: [PromiseFulfillment] = self.phase.withLock { phase in
            guard case .awaitingInit(let encryptedKey, let keyPromise, let validationPromise) = phase else {
                Self.logger.warning(
                    "connectionID: \(self.connectionID, privacy: .public) .initialized received in unexpected phase"
                )
                return []
            }
            guard let key = encryptedKey else {
                Self.logger.error(
                    "connectionID: \(self.connectionID, privacy: .public) .initialized received without prior encrypted key"
                )
                let err = PersistentHelperInstanceError.helperUnavailable(
                    "helper sent .initialized without prior encrypted key"
                )
                phase = .failed
                return [.failKey(keyPromise, err), .failValidation(validationPromise, err)]
            }
            phase = .awaitingSetupAck(buffered: [], validationPromise: validationPromise)
            return [.succeedKey(keyPromise, key)]
        }
        for fulfillment in fulfillments {
            fulfillment.apply()
        }
    }

    private func handleResponseChunk(_ data: Data, isFinal: Bool) {
        enum Action {
            case storeKey
            case buffer
            case forward
            case drop
        }

        let (action, fulfillments): (Action, [PromiseFulfillment]) = self.phase.withLock { phase in
            switch phase {
            case .awaitingInit(let existingKey, let keyPromise, let validationPromise):
                if existingKey != nil {
                    Self.logger.error(
                        "connectionID: \(self.connectionID, privacy: .public) received duplicate pre-init responseChunk — protocol violation"
                    )
                    let err = PersistentHelperInstanceError.helperUnavailable(
                        "helper sent multiple responseChunks before .initialized"
                    )
                    phase = .failed
                    return (.drop, [.failKey(keyPromise, err), .failValidation(validationPromise, err)])
                }
                phase = .awaitingInit(
                    encryptedKey: data,
                    keyPromise: keyPromise,
                    validationPromise: validationPromise
                )
                return (.storeKey, [])
            case .awaitingSetupAck(var buffered, let validationPromise):
                if buffered.count >= Self.chunkBufferCap {
                    Self.logger.error(
                        "connectionID: \(self.connectionID, privacy: .public) pre-SetupAck buffer cap (\(Self.chunkBufferCap, privacy: .public)) exceeded — failing setup"
                    )
                    let err = PersistentHelperInstanceError.helperUnavailable(
                        "helper sent too many chunks before SetupAck"
                    )
                    phase = .failed
                    return (.drop, [.failValidation(validationPromise, err)])
                }
                buffered.append((data, isFinal))
                phase = .awaitingSetupAck(buffered: buffered, validationPromise: validationPromise)
                return (.buffer, [])
            case .awaitingMetadataValidation, .forwarding:
                return (.forward, [])
            case .failed:
                return (.drop, [])
            }
        }

        for fulfillment in fulfillments {
            fulfillment.apply()
        }

        switch action {
        case .storeKey:
            Self.logger.info(
                "connectionID: \(self.connectionID, privacy: .public) captured encrypted key (\(data.count, privacy: .public) bytes)"
            )
        case .buffer:
            Self.logger.debug(
                "connectionID: \(self.connectionID, privacy: .public) buffering responseChunk (\(data.count, privacy: .public) bytes) pending SetupAck"
            )
        case .forward:
            Self.logger.debug(
                "connectionID: \(self.connectionID, privacy: .public) forwarding responseChunk (\(data.count, privacy: .public) bytes, isFinal: \(isFinal, privacy: .public))"
            )
            self.forwardContinuation.yield((data, isFinal))
        case .drop:
            break
        }
    }

    private func handleMetadataUpdate(payload: Data) {
        let validated = self.validateMetadata(payload: payload)
        let fulfillments: [PromiseFulfillment] = self.phase.withLock { phase in
            switch phase {
            case .awaitingMetadataValidation(let validationPromise):
                phase = .forwarding
                return [.succeedValidation(validationPromise, validated)]
            case .forwarding:
                // `PrivateFilterController` server-side re-registers every hour and
                // broadcasts `.metadataUpdate` to every subscriber on each re-register.
                // This state machine validates metadata exactly once during setup and
                // drops all subsequent refreshes — that is the designed behaviour.
                Self.logger.debug(
                    "connectionID: \(self.connectionID, privacy: .public) ignoring metadata refresh (already in forwarding phase)"
                )
                return []
            case .awaitingInit, .awaitingSetupAck, .failed:
                // A metadataUpdate in any of these phases is a genuine protocol anomaly:
                // the server should not be sending it before SetupAck or after we have
                // marked the connection failed. Log loudly with the actual phase so the
                // anomaly is diagnosable, but don't change state.
                let phaseName = switch phase {
                case .awaitingInit: "awaitingInit"
                case .awaitingSetupAck: "awaitingSetupAck"
                case .awaitingMetadataValidation: "awaitingMetadataValidation"
                case .forwarding: "forwarding"
                case .failed: "failed"
                }
                Self.logger.warning(
                    "connectionID: \(self.connectionID, privacy: .public) received metadataUpdate in unexpected phase \(phaseName, privacy: .public) — ignoring; this is a protocol anomaly"
                )
                return []
            }
        }
        for fulfillment in fulfillments {
            fulfillment.apply()
        }
    }

    private func handleFailure(reason: PersistentHelperFailureReason) {
        Self.logger.error(
            "connectionID: \(self.connectionID, privacy: .public) helper failure: \(reason, privacy: .public)"
        )
        let fulfillments: [PromiseFulfillment] = self.phase.withLock { phase in
            let err = PersistentHelperInstanceError.helperUnavailable("\(reason)")
            let result: [PromiseFulfillment] = switch phase {
            case .awaitingInit(_, let keyPromise, let validationPromise):
                [.failKey(keyPromise, err), .failValidation(validationPromise, err)]
            case .awaitingSetupAck(_, let validationPromise):
                [.failValidation(validationPromise, err)]
            case .awaitingMetadataValidation(let validationPromise):
                [.failValidation(validationPromise, err)]
            case .forwarding, .failed:
                []
            }
            phase = .failed
            return result
        }
        for fulfillment in fulfillments {
            fulfillment.apply()
        }
        self.forwardContinuation.finish()
        self.drainCompleteContinuation.finish()
    }

    func persistentHelperSurpriseDisconnect() {
        Self.logger.error(
            "connectionID: \(self.connectionID, privacy: .public) helper surprise disconnected"
        )
        let fulfillments: [PromiseFulfillment] = self.phase.withLock { phase in
            let err = PersistentHelperInstanceError.helperUnavailable("surprise disconnect")
            let result: [PromiseFulfillment] = switch phase {
            case .awaitingInit(_, let keyPromise, let validationPromise):
                [.failKey(keyPromise, err), .failValidation(validationPromise, err)]
            case .awaitingSetupAck(_, let validationPromise):
                [.failValidation(validationPromise, err)]
            case .awaitingMetadataValidation(let validationPromise):
                [.failValidation(validationPromise, err)]
            case .forwarding, .failed:
                []
            }
            phase = .failed
            return result
        }
        for fulfillment in fulfillments {
            fulfillment.apply()
        }
        self.forwardContinuation.finish()
        self.drainCompleteContinuation.finish()
    }

    // MARK: - Metadata validation

    private func validateMetadata(payload: Data) -> Bool {
        let update: Com_Apple_Cloudboard_Privatefilter_V1_ServiceDefinedMetadataUpdate
        do {
            update = try .init(serializedBytes: payload)
        } catch {
            Self.logger.error(
                "connectionID: \(self.connectionID, privacy: .public) failed to parse metadata update: \(error, privacy: .public)"
            )
            return false
        }

        let streamMetadata = Data(update.metadataJson.utf8)
        let expected = self.expectedServiceDefinedMetadata

        let expectedObj: Any
        let streamObj: Any
        do {
            expectedObj = try JSONSerialization.jsonObject(with: expected)
            streamObj = try JSONSerialization.jsonObject(with: streamMetadata)
        } catch {
            Self.logger.error(
                "connectionID: \(self.connectionID, privacy: .public) failed to parse metadata as JSON: \(error, privacy: .public)"
            )
            return false
        }

        switch Self.jsonEqual(expectedObj, streamObj) {
        case .equal:
            Self.logger.info(
                "connectionID: \(self.connectionID, privacy: .public) metadata validated successfully"
            )
            return true
        case .mismatch(let path, let detail):
            let expectedHash = SHA256.hash(data: expected).description
            let streamHash = SHA256.hash(data: streamMetadata).description
            Self.logger.error(
                "connectionID: \(self.connectionID, privacy: .public) metadata mismatch at \(path, privacy: .public): \(detail, privacy: .public) — SD SHA256: \(expectedHash, privacy: .public), stream SHA256: \(streamHash, privacy: .public)"
            )
            return false
        }
    }

    private enum JSONComparisonResult {
        case equal
        case mismatch(path: String, detail: String)
    }

    private static func jsonEqual(_ lhs: Any, _ rhs: Any, path: String = "$", depth: Int = 0) -> JSONComparisonResult {
        guard depth < 64 else {
            return .mismatch(path: path, detail: "recursion depth limit exceeded")
        }
        switch (lhs, rhs) {
        case (let l as [String: Any], let r as [String: Any]):
            let allKeys = Set(l.keys).union(r.keys)
            for key in allKeys.sorted() {
                guard let lVal = l[key] else {
                    return .mismatch(path: "\(path).\(key)", detail: "key missing in expected")
                }
                guard let rVal = r[key] else {
                    return .mismatch(path: "\(path).\(key)", detail: "key missing in stream")
                }
                let result = self.jsonEqual(lVal, rVal, path: "\(path).\(key)", depth: depth + 1)
                if case .mismatch = result { return result }
            }
            return .equal
        case (let l as [Any], let r as [Any]):
            if l.count != r.count {
                return .mismatch(path: path, detail: "array length \(l.count) vs \(r.count)")
            }
            for (i, (lElem, rElem)) in zip(l, r).enumerated() {
                let result = self.jsonEqual(lElem, rElem, path: "\(path)[\(i)]", depth: depth + 1)
                if case .mismatch = result { return result }
            }
            return .equal
        case (let l as NSNumber, let r as NSNumber):
            let lIsBool = CFGetTypeID(l) == CFBooleanGetTypeID()
            let rIsBool = CFGetTypeID(r) == CFBooleanGetTypeID()
            if lIsBool != rIsBool {
                return .mismatch(
                    path: path,
                    detail: "type mismatch: \(lIsBool ? "bool" : "number") vs \(rIsBool ? "bool" : "number")"
                )
            }
            if l == r { return .equal }
            return .mismatch(path: path, detail: "\(lIsBool ? "bool" : "number") \(l) vs \(r)")
        case (let l as String, let r as String):
            if l == r { return .equal }
            let prefix = String(l.prefix(40))
            let rPrefix = String(r.prefix(40))
            return .mismatch(path: path, detail: "string '\(prefix)...' vs '\(rPrefix)...'")
        case (is NSNull, is NSNull):
            return .equal
        default:
            return .mismatch(path: path, detail: "type mismatch: \(type(of: lhs)) vs \(type(of: rhs))")
        }
    }
}
