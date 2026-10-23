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
//  DaemonHandler.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 20/01/2025.
//

internal import CryptoKit
internal import EnsemblePorter
#if canImport(EnsembleTransport)
@preconcurrency @_weakLinked package import EnsembleTransport
#endif
#if canImport(AppleComputeEnsembler)
@_weakLinked private import AppleComputeEnsembler
#endif
private import EnsembleWardenCommon
package import EnsembleWardenServer
package import EnsembleWardenXPC
package import Foundation
package import IOSurface
package import os
private import Synchronization
@preconcurrency package import XPC


package protocol EnsembleTransportProviding: Sendable {
    func publish(_ identifier: String, data: IOSurface, timeout: Int) async throws
    func fetch(_ identifier: String, fromHost host: String) async throws -> EnsembleWardenFetchedData
    func delete(_ identifier: String) async throws
    func remoteDelete(_ identifier: String, onHost host: String) async throws
    func dropCache() async throws
}

/// In-memory transport used for testing. Stores IOSurfaces in a dictionary.
package struct NullTransport: EnsembleTransportProviding {
    package enum TransportError: Swift.Error {
        case noEntry
    }

    private final class Storage: Sendable {
        let mutex: Mutex<[String: IOSurface]> = .init([:])
    }

    private let storage: Storage = .init()

    package init() {}

    package func publish(_ identifier: String, data: IOSurface, timeout: Int) async throws {
        self.storage.mutex.withLock { $0[identifier] = data }
    }

    package func fetch(
        _ identifier: String, fromHost host: String
    ) async throws -> EnsembleWardenFetchedData {
        try self.storage.mutex.withLock { store in
            guard let surface = store[identifier] else {
                throw TransportError.noEntry
            }
            return EnsembleWardenFetchedData(
                ioSurface: surface,
                source: EnsembleWardenFetchedData.Source.localDRAM)
        }
    }

    package func delete(_ identifier: String) async throws {
        self.storage.mutex.withLock { _ = $0.removeValue(forKey: identifier) }
    }

    package func remoteDelete(_ identifier: String, onHost host: String) async throws {
        self.storage.mutex.withLock { _ = $0.removeValue(forKey: identifier) }
    }

    package func dropCache() async throws {
        self.storage.mutex.withLock { $0.removeAll() }
    }

    package func corruptCiphertext() {
        self.storage.mutex.withLock { store in
            for surface in store.values {
                let corruption: [UInt8] = [0x00, 0x11, 0x22]
                (surface.baseAddress + 30).copyMemory(from: corruption, byteCount: corruption.count)
            }
        }
    }
}

/// Production transport backend that wraps `EnsembleTransport` framework calls.
package struct EnsembleTransportBackend: EnsembleTransportProviding {
    private let logger = Logger(subsystem: "com.apple.cloudos.ensemblewardend", category: "EnsembleTransportBackend")
    private let signposter: OSSignposter

#if canImport(EnsembleTransport)
    private let client: EnsembleTransportClient?

    package init(client: EnsembleTransportClient?) {
        self.signposter = OSSignposter(logger: self.logger)
        self.client = client
    }
#else
    package init() {
        self.signposter = OSSignposter(logger: self.logger)
    }
#endif

#if canImport(EnsembleTransport)
    /// Translates `EnsembleTransportError` into ``EnsembleWardenError/ensembleTransportError(_:)``
    /// so the failure reason survives into logs and the `error_category` metric dimension.
    ///
    /// Without this the raw framework error escapes EnsembleWarden untyped: the metrics layer
    /// buckets it as `other` and `String(reportable:)` prints only the type name, because
    /// `EnsembleTransportError` is not a `ReportableError`. Any other error is rethrown
    /// unchanged.
    private func translatingTransportErrors<T>(_ fn: () async throws -> T) async throws -> T {
        do {
            return try await fn()
        } catch let error as EnsembleTransportError {
            let failure: EnsembleTransportFailure
            switch error {
            case .disconnected: failure = .disconnected
            case .publishFailed: failure = .publishFailed
            case .duplicateObject: failure = .duplicateObject
            case .invalidSurface: failure = .invalidSurface
            case .tooLarge: failure = .tooLarge
            case .deleteFailed: failure = .deleteFailed
            case .unexpectedResponse: failure = .unexpectedResponse
            case .unknown: failure = .unknown
            }
            self.logger.error("""
                EnsembleTransport call failed. \
                failure=\(failure.rawValue, privacy: .public) \
                description=\(error.description, privacy: .public)
                """)
            throw EnsembleWardenError.ensembleTransportError(failure)
        }
    }
#endif

    package func publish(_ identifier: String, data: IOSurface, timeout: Int) async throws {
#if canImport(EnsembleTransport)
        guard let client = self.client else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime
                """)
            throw EnsembleWardenError.ensembleTransportUnavailable
        }
        try await self.translatingTransportErrors {
            try await client.publish(
                identifier, data: data, timeout: timeout)
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time
            """)
        throw EnsembleWardenError.ensembleTransportUnavailable
#endif
    }

    package func fetch(
        _ identifier: String, fromHost host: String
    ) async throws -> EnsembleWardenFetchedData {
#if canImport(EnsembleTransport)
        guard let client = self.client else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime
                """)
            throw EnsembleWardenError.ensembleTransportUnavailable
        }
        self.logger.log("""
            \(#function, privacy: .public): \
            identifier=\(identifier, privacy: .public) \
            host=\(host, privacy: .public)
            """)
        return try await self.translatingTransportErrors {
            // fetchPrepareWithSurface gives us back an IOSurface that doesn't yet have the
            // relevant data written to it.
            let surfaceHint : IOSurface = try await client.fetchPrepareWithSurface(identifier, fromHost: host)
            return try await withThrowingTaskGroup(of: Optional<EnsembleWardenFetchedData>.self) { group in
                // We can begin prefaulting it in before it's ready to read from.
                // Background task to minimise impact on other threads.
                group.addTask(priority: .background) {
                    let prefaultInterval = self.signposter.beginInterval("EW.prefault_ciphertext.signpost")
                    defer {
                        self.signposter.endInterval("EW.prefault_ciphertext.signpost", prefaultInterval)
                    }
                    try surfaceHint.prefault()
                    return nil
                }
                group.addTask { @Sendable in
                    let fetchInterval = self.signposter.beginInterval("EW.fetch_ciphertext.signpost")
                    defer {
                        self.signposter.endInterval("EW.fetch_ciphertext.signpost", fetchInterval)
                    }
                    let (fetchedSurface, fetchedSurfaceSource) =
                        try await client.fetchBlobWithAnalytics(identifier)
                    if fetchedSurface.baseAddress != surfaceHint.baseAddress {
                        self.logger.warning("fetchPrepareWithSurface returned a different surface to fetch")
                    }
                    return EnsembleWardenFetchedData(
                        ioSurface: fetchedSurface, source: fetchedSurfaceSource)
                }
                for try await surface in group {
                    if let surface {
                        return surface
                    }
                }
                throw EnsembleWardenError.failedToGenerateIOSurface
            }
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time
            """)
        throw EnsembleWardenError.ensembleTransportUnavailable
#endif
    }

    package func delete(_ identifier: String) async throws {
#if canImport(EnsembleTransport)
        guard let client = self.client else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime
                """)
            throw EnsembleWardenError.ensembleTransportUnavailable
        }
        try await self.translatingTransportErrors {
            try await client.delete(identifier)
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time
            """)
        throw EnsembleWardenError.ensembleTransportUnavailable
#endif
    }

    package func remoteDelete(_ identifier: String, onHost host: String) async throws {
#if canImport(EnsembleTransport)
        guard let client = self.client else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime
                """)
            throw EnsembleWardenError.ensembleTransportUnavailable
        }
        try await self.translatingTransportErrors {
            try await client.remoteDelete(identifier, onHost: host)
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time
            """)
        throw EnsembleWardenError.ensembleTransportUnavailable
#endif
    }

    package func dropCache() async throws {
#if canImport(EnsembleTransport)
        guard let client = self.client else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime
                """)
            throw EnsembleWardenError.ensembleTransportUnavailable
        }
        try await self.translatingTransportErrors {
            try await client.dropCache()
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time
            """)
        throw EnsembleWardenError.ensembleTransportUnavailable
#endif
    }
}

/// DaemonHandler receives plaintext ioSurfaces, encrypts them and then publishes them over XPC.
///
/// DaemonHandler itself conforms to ``EnsembleWardenServerHandler``, our type for
/// defining a destination for fetching and publishing ioSurfaces. The ``DaemonHandler`` is
/// our own, internal type that we use to receive ioSurfaces, encrypt them, and then write them out
/// to whichever *other* ``EnsembleWardenServerHandler`` is configured to read them.
///
/// Overall flow will look like:
///
/// Application -> EnsembleWardenFramework -> DaemonHandler (EnsembleWardenDaemon) -> EnsembleWardenServer (DownstreamApplication)
package final class DaemonHandler<Transport: EnsembleTransportProviding, Factory: MetricsFactory>: Sendable {

    private enum State: Sendable {
        case cryptoHandlesNotYetReceived
        case cryptoHandlesReceived(CryptoHandlesState)
    }

    internal enum KeyType: Sendable {
        case ftET
        case latestTurnKey
        case specificTurnKey(Int)
    }

    /// Continuation that we yield to when we want the daemon to tear itself down
    private let shutdownInitiateContinuation: AsyncStream<Void>.Continuation
    internal let logger = Logger(subsystem: "com.apple.cloudos.ensemblewardend", category: "DaemonHandler")
    private let state: Mutex<State> = .init(.cryptoHandlesNotYetReceived)
    private let signposter: OSSignposter
    /// Storage for prefaulted IOSurfaces to maintain references and prevent unmapping
    private let prefaultedSurfaces: Mutex<[IOSurface]> = .init([])
    private let transportProvider: Transport
    internal let metrics: EnsembleWardenMetrics<Factory>

    package init(shutdownInitiateContinuation: AsyncStream<Void>.Continuation, transportProvider: Transport, metrics: EnsembleWardenMetrics<Factory>) {
        self.shutdownInitiateContinuation = shutdownInitiateContinuation
        self.signposter = OSSignposter(logger: self.logger)
        self.transportProvider = transportProvider
        self.metrics = metrics
    }

    internal func getKey(keyType: KeyType) async throws -> (key: SymmetricKey, turnNumber: Int?) {
        let cryptoState =  try self.state.withLock { state in
            switch state {
            case .cryptoHandlesNotYetReceived:
                logger.error("""
                         Tried to get key before receiving it. \
                         request_id=\(PrismTracing.requestID, privacy: .public) \
                         span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                         """)
                throw EnsembleWardenError.keyIDNotSupplied
            case .cryptoHandlesReceived(let cryptoHandles):
                return cryptoHandles
            }
        }

        switch keyType {
        case .ftET:
            // Fetch FT/ET key using dedicated API
            guard let ensemblePorterClient = cryptoState.ensemblePorterClient else {
                logger.error("""
                    No ensemblePorterClient for FT/ET key. \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                throw EnsembleWardenError.ensemblePorterHandleNotSupplied
            }

            do {
                let ftETKey = try await ensemblePorterClient.fetchFTETKey(
                    requestID: PrismTracing.requestID,
                    spanID: PrismTracing.spanID)
                return (ftETKey, nil)
            } catch {
                logger.error("""
                    Error getting FT/ET key from ensembleporter. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                throw error
            }
        case .latestTurnKey:
            guard let ensemblePorterClient = cryptoState.ensemblePorterClient else {
                logger.warning("""
                    No ensembleporter client for request. \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                throw EnsembleWardenError.ensemblePorterHandleNotSupplied
            }

            do {

                let lastTurnKeyIndex = try await ensemblePorterClient.getNumberOfTurnKeys(
                    requestID: PrismTracing.requestID, spanID: PrismTracing.spanID) - 1
                assert(lastTurnKeyIndex >= 0)
                let turnKey = try await ensemblePorterClient.fetchKey(
                    forTurnNumber: lastTurnKeyIndex,
                    requestID: PrismTracing.requestID,
                    spanID: PrismTracing.spanID)
                return (turnKey, lastTurnKeyIndex)
            } catch {
                logger.error("""
                    Error getting latest turn key from ensembleporter. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                throw error
            }
        case .specificTurnKey(let turnNumber):
            guard let ensemblePorterClient = cryptoState.ensemblePorterClient else {
                logger.error("""
                    No ensemblePorterClient supplied. \
                    turn_number=\(turnNumber) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                throw EnsembleWardenError.ensemblePorterHandleNotSupplied
            }
            do {
                let turnKey = try await ensemblePorterClient.fetchKey(
                    forTurnNumber: turnNumber,
                    requestID: PrismTracing.requestID,
                    spanID: PrismTracing.spanID)
                return (turnKey, turnNumber)
            } catch {
                logger.error("""
                    Error getting turn key from ensembleporter. \
                    error=\(String(reportable: error), privacy: .public) \
                    turn_number=\(turnNumber) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                throw error
            }
        }
    }
}

extension DaemonHandler: EnsembleWardenServerHandler {
    package func start(ensembleWardenCryptoHandles: EnsembleWardenCryptoHandles, requestID: UUID, spanID: UInt64) async throws -> FollowerTokens {
        let isLeader: Bool
        #if canImport(AppleComputeEnsembler)
        if #_hasSymbol(AppleComputeEnsembler.DerivedKeyType.self) {
            isLeader = try await EnsemblerSession().getNodeInfo().leader
        } else {
            self.logger.log("AppleComputeEnsembler not available at run time")
            isLeader = false
        }
        #else
        self.logger.log("AppleComputeEnsembler not available at build time")
        isLeader = true
        #endif

        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            PrismTracing.logCheckpoint(name: "EnsembleWardenStart")
            try self.state.withLock { state in
                let startInterval = self.signposter.beginInterval("EW.startInterval.signpost")
                defer {
                    self.signposter.endInterval("EW.startInterval.signpost", startInterval)
                }
                switch state {
                    case .cryptoHandlesNotYetReceived:
                        let cryptoHandles: CryptoHandlesState
                        if case .ensemblePorterEndpoint(let endpoint) = ensembleWardenCryptoHandles.ensemblePorterIdentifier {
                            self.logger.log("""
                                Using an XPC endpoint. \
                                request_id=\(PrismTracing.requestID, privacy: .public) \
                                span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                                """)
                            cryptoHandles = CryptoHandlesState(ensemblePorterEndpoint: endpoint,
                                                               isMultiTurn: ensembleWardenCryptoHandles.isMultiTurn,
                                                               requestID: PrismTracing.requestID, spanID: PrismTracing.spanID)
                        } else {
                            // TODO: porterConnection can become non-optional when TIE/CB land their corresponding changes.
                            let porterConnection: xpc_connection_t?
                            switch ensembleWardenCryptoHandles.ensemblePorterIdentifier {
                            case .ensemblePorterHandle(let existingConnection):
                                self.logger.log("""
                                    Using an existing XPC connection. \
                                    request_id=\(PrismTracing.requestID, privacy: .public) \
                                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                                    """)
                                porterConnection = existingConnection
                            case .followerToken(let followerToken):
                                self.logger.log("""
                                    Using a token to create a fresh XPC connection. \
                                    request_id=\(PrismTracing.requestID, privacy: .public) \
                                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                                    """)
                                let connection = XPCHelpers.fromFollowerToken(followerToken, leader: isLeader,
                                                                              requestID: PrismTracing.requestID, spanID: PrismTracing.spanID)
                                porterConnection = connection
                            case .ensemblePorterEndpoint:
                                fatalError("Handled above")
                            case .none:
                                self.logger.log("""
                                    No handle to a porter. \
                                    request_id=\(PrismTracing.requestID, privacy: .public) \
                                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                                    """)
                                porterConnection = nil
                            }

                            do {
                                cryptoHandles = try CryptoHandlesState(ensemblePorterXPCConnection: porterConnection,
                                                                       isMultiTurn: ensembleWardenCryptoHandles.isMultiTurn,
                                                                       requestID: PrismTracing.requestID, spanID: PrismTracing.spanID)
                            } catch {
                                if let porterConnection {
                                    // Libxpc will crash if you create a connection and then release its final
                                    // reference before activating it.
                                    // If ensembled doesn't have keys for us then we will throw above and
                                    // release our porterConnection without having activated it and thus crash.
                                    //
                                    // These two lines make us activate the connection before we throw it away,
                                    // avoiding the crash. When FT/ET keys become part of ensembleporter this
                                    // should go away.
                                    xpc_connection_set_event_handler(porterConnection) {_ in }
                                    xpc_connection_activate(porterConnection)
                                }
                                throw error
                            }
                        }

                        state = .cryptoHandlesReceived(cryptoHandles)
                    default:
                        // We don't expect to call start if we're in any other state.
                        logger.error("""
                                    start(keyID:,requestID:,spanID:) called but we already have a key. Each ensemblewardend should only have 1 key. \
                                    request_id=\(requestID, privacy: .public) \
                                    span_id=\(spanID.hexEncoded, privacy: .public)
                                    """)
                        throw EnsembleWardenError.keyIDSuppliedTwice
                    }
                }
        }

        // Only the leader fetches follower tokens - followers already received theirs
        guard isLeader else {
            self.logger.debug("""
                Follower node. Returning empty tokens. \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            return .init(nodeRanks: [])
        }

        // Generate per-process tokens using EnsemblePorter
        let ensemblePorterClient = try self.state.withLock { state in
           switch state {
           case .cryptoHandlesNotYetReceived:
               throw EnsembleWardenError.keyIDNotSupplied
           case .cryptoHandlesReceived(let cryptoHandles):
               return cryptoHandles.ensemblePorterClient
           }
        }
        guard let ensemblePorterClient else {
            // No tokens if we don't have a porter.
            self.logger.debug("""
                No connection to porter so returning empty tokens. \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            return .init(nodeRanks: [])
        }

        // For non-multi-turn requests, notify EnsemblePorter to signal non-multi-turn mode
        let isMultiTurn = try self.state.withLock { state -> Bool in
            switch state {
            case .cryptoHandlesReceived(let cryptoHandles):
                return cryptoHandles.isMultiTurn
            case .cryptoHandlesNotYetReceived:
                throw EnsembleWardenError.keyIDNotSupplied
            }
        }

        // If not multi-turn, call ftETOnlyTurn to signal EnsemblePorter
        if !isMultiTurn {
            logger.log("""
                Calling ftETOnlyTurn for non-multi-turn request. \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
            try await ensemblePorterClient.ftETOnlyTurn(requestID: requestID, spanID: spanID)
        } else {
            logger.log("""
                Multi-turn request - EnsemblePorter will wait for CloudBoard crypto material. \
                request_id=\(requestID, privacy: .public) \
                span_id=\(spanID.hexEncoded, privacy: .public)
                """)
        }

        logger.log("""
            Fetching follower tokens. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID.hexEncoded, privacy: .public)
            """)
        let followerTokens = try await ensemblePorterClient.fetchFollowerTokens(requestID: requestID, spanID: spanID)
        logger.debug("""
            Fetched follower tokens. \
            number_token=\(followerTokens.count) \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID.hexEncoded, privacy: .public)
            """)
        return followerTokens
    }

    package func onPrefault(ioSurfaces: [IOSurface], requestID: UUID, spanID: UInt64) async throws {
        await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            PrismTracing.logCheckpoint(name: "EnsembleWardenPrefaultDaemon")

            // Spawn low-priority background task to prefault surfaces
            Task(priority: .low) {
                let prefaultInterval = self.signposter.beginInterval("EW.prefault.signpost")
                defer {
                    self.signposter.endInterval("EW.prefault.signpost", prefaultInterval)
                }

                // Prefault each surface using madvise(MADV_WILLNEED)
                for ioSurface in ioSurfaces {
                    self.logger.log("""
                        Prefaulting IOSurface. \
                        surface_id=\(IOSurfaceGetID(ioSurface), privacy: .public) \
                        base_address=\(UInt(bitPattern: ioSurface.baseAddress), format: .hex, privacy: .public) \
                        request_id=\(PrismTracing.requestID, privacy: .public) \
                        span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                        """)
                    do {
                        try ioSurface.prefault()
                    } catch {
                        self.logger.error("Failed to prefault IOSurface: \(String(reportable: error), privacy: .public)")
                    }
                }

                // Store references to prevent the surfaces from being unmapped
                self.prefaultedSurfaces.withLock { surfaces in
                    surfaces.append(contentsOf: ioSurfaces)
                }
            }
        }
    }

    package func onFinish() async throws {
        self.shutdownSessionAndInitiateShutdown()
    }

    package func onCancellation() throws {
        self.shutdownSessionAndInitiateShutdown()
    }
}

extension DaemonHandler {
    private func shutdownSessionAndInitiateShutdown() {
        self.shutdownInitiateContinuation.yield()
    }
}

extension DaemonHandler {
    package func onPublish2(
        identifier: String,
        privateData: IOSurface,
        privateMetadata: IOSurface?,
        ttl: Duration,
        purpose: KVCacheTransferPurpose,
        requestID: UUID,
        spanID: UInt64
    ) async throws {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            PrismTracing.logCheckpoint(name: "Daemon onPublish2", level: .debug)
            let encryptedSurface = try await self.encrypt(
                decryptedSurfaces: [privateData],
                purpose: purpose).first!
            let encryptedSurfaceMetadata: IOSurface? =
            if privateMetadata != nil {
                try await self.encrypt(
                    decryptedSurfaces: [privateMetadata!],
                    purpose: purpose).first!
            } else {
                nil
            }
            PrismTracing.logCheckpoint(name: "EnsembleWardenEncryptionEnd", level: .debug)
            let publishInterval = self.signposter.beginInterval(
                "EW.publish_to_ensembletransport.signpost")
            defer {
                self.signposter.endInterval(
                    "EW.publish_to_ensembletransport.signpost",
                    publishInterval)
            }
            PrismTracing.logCheckpoint(name: "EnsembleWardenTransportPublishStart")
            try await self.ensembleTransportPublish(
                identifier: identifier,
                data: encryptedSurface,
                timeout: ttl)
            if let encryptedSurfaceMetadata {
                try await self.ensembleTransportPublish(
                    identifier: self.metadataIdentifier(identifier),
                    data: encryptedSurfaceMetadata,
                    timeout: ttl)
            }
            PrismTracing.logCheckpoint(name: "EnsembleWardenTransportPublishCompleted")
        }
    }

    package func onFetch2(
        identifier: String,
        range: ClosedRange<Int>?,
        host: String,
        requestID: UUID,
        spanID: UInt64
    ) async throws -> EnsembleWardenFetchedData {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            logger.log("""
                \(#function, privacy: .public): \
                identifier=\(identifier, privacy: .public) \
                host=\(host, privacy: .public)
                """)
            PrismTracing.logCheckpoint(name: "EnsembleWardenOnFetch2Daemon")
            let fetchInterval = self.signposter.beginInterval(
                "EW.fetch_from_ensembletransport.signpost")
            defer {
                self.signposter.endInterval(
                    "EW.fetch_from_ensembletransport.signpost", fetchInterval)
            }
            let fetched = try await self.ensembleTransportFetch(
                identifier: identifier, host: host)
            PrismTracing.logCheckpoint(name: "EnsembleWardenDecryptionStart")
            let plaintextSurfaces = try await self.decrypt(
                encryptedSurfaces: [fetched.ioSurface])
            PrismTracing.logCheckpoint(name: "EnsembleWardenDecryptionEnd")
            let fullSurface = plaintextSurfaces.first!
            // Need MetalLM change before we can return trimmed surface:
            // rdar://172750120
            #if false
            if let range {
                guard let subSurface = try IOSurface(from: fullSurface, at: range) else {
                    throw EnsembleWardenError.failedToCreateIOSurface
                }
                return EnsembleWardenFetchedData(
                    ioSurface: subSurface, source: fetched.source)

            }
            #endif
            return EnsembleWardenFetchedData(
                ioSurface: fullSurface, source: fetched.source)
        }
    }

    package func onFetchMetadata(
        identifier: String,
        host: String,
        requestID: UUID,
        spanID: UInt64
    ) async throws -> IOSurface? {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            logger.log("""
                \(#function, privacy: .public): \
                identifier=\(identifier, privacy: .public) \
                host=\(host, privacy: .public)
                """)
            PrismTracing.logCheckpoint(name: "EnsembleWardenOnFetchMetadataDaemon")
            let fetchInterval = self.signposter.beginInterval(
                "EW.fetchmetadata_from_ensembletransport.signpost")
            defer {
                self.signposter.endInterval(
                    "EW.fetchmetadata_from_ensembletransport.signpost", fetchInterval)
            }
            let fetched = try await self.ensembleTransportFetch(
                identifier: self.metadataIdentifier(identifier), host: host)
            PrismTracing.logCheckpoint(name: "EnsembleWardenDecryptionStart")
            let plaintextSurfaces = try await self.decrypt(
                encryptedSurfaces: [fetched.ioSurface])
            PrismTracing.logCheckpoint(name: "EnsembleWardenDecryptionEnd")
            return plaintextSurfaces.first!
        }
    }

    package func onDelete(
        identifier: String,
        host: String?,
        requestID: UUID,
        spanID: UInt64
    ) async throws {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            PrismTracing.logCheckpoint(name: "Daemon onDelete")
            let publishInterval = self.signposter.beginInterval(
                "EW.delete_with_ensembletransport.signpost")
            defer {
                self.signposter.endInterval(
                    "EW.delete_with_ensembletransport.signpost", publishInterval)
            }
            try await self.ensembleTransportDelete(
                identifier: identifier,
                host: host)
        }

    }

    package func onDropAll() async throws {
        let interval = self.signposter.beginInterval("EW.dropAll_ensembletransport.signpost")
        defer {
            self.signposter.endInterval("EW.dropAll_ensembletransport.signpost", interval)
        }

        logger.log("Dropping all cached data")
        try await self.ensembleTransportDropCache()
    }
}

extension DaemonHandler {
    private func ensembleTransportPublish(
        identifier: String,
        data: IOSurface,
        timeout: Duration
    ) async throws {
        try await self.transportProvider.publish(
            identifier, data: data, timeout: Int(timeout.components.seconds))
    }

    private func ensembleTransportFetch(
        identifier: String,
        host: String
    ) async throws -> EnsembleWardenFetchedData {
        try await self.transportProvider.fetch(identifier, fromHost: host)
    }

    private func ensembleTransportDelete(
        identifier: String,
        host: String?
    ) async throws {
        if let host {
            try await self.transportProvider.remoteDelete(identifier, onHost: host)
        } else {
            try await self.transportProvider.delete(identifier)
        }
    }

    private func ensembleTransportDropCache() async throws {
        try await self.transportProvider.dropCache()
    }

    private func metadataIdentifier(_ identifier: String) -> String {
        return "\(identifier)-metadata"
    }
}

#if canImport(EnsembleTransport)
extension EnsembleWardenFetchedData {
    internal init(ioSurface: IOSurface, source: EnsembleTransportDataSource) {
        self.init(ioSurface: ioSurface, source: Self.Source(source))
    }
}

extension EnsembleWardenFetchedData.Source {
    internal init(_ source: EnsembleTransportDataSource) {
        switch source {
        case .localDRAM:
            self = .localDRAM
        case .localNAND:
            self = .localNAND
        case .remoteDRAM:
            self = .remoteDRAM
        case .remoteNAND:
            self = .remoteNAND
        @unknown default:
            fatalError("Unknown transport source: \(source)")
        }
    }
}
#endif
