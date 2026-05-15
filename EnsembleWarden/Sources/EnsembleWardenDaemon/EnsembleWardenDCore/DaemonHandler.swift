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
//  DaemonHandler.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 20/01/2025.
//

internal import CryptoKit
internal import EnsemblePorter
#if canImport(EnsembleTransport)
@preconcurrency @_weakLinked private import EnsembleTransport
#endif
#if canImport(AppleComputeEnsembler)
@_weakLinked private import AppleComputeEnsembler
#endif
private import EnsembleWardenCommon
package import EnsembleWardenServer
private import EnsembleWardenXPCAPI
package import Foundation
package import IOSurface
internal import os
private import Synchronization
@preconcurrency private import XPC


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
package final class DaemonHandler: Sendable {

    private enum State: Sendable {
        case cryptoHandlesNotYetReceived
        case cryptoHandlesReceived(CryptoHandlesState)
        case connectedToDownstream(CryptoHandlesState, XPCSession)
    }

    internal enum KeyType: Sendable {
        case ftET
    }

    private let downstreamXPCService: String
    /// Continuation that we yield to when we want the daemon to tear itself down
    private let shutdownInitiateContinuation: AsyncStream<Void>.Continuation
    internal let logger = Logger(subsystem: "com.apple.cloudos.ensemblewardend", category: "DaemonHandler")
    private let state: Mutex<State> = .init(.cryptoHandlesNotYetReceived)
    private let signposter: OSSignposter
    /// Storage for prefaulted IOSurfaces to maintain references and prevent unmapping
    private let prefaultedSurfaces: Mutex<[IOSurface]> = .init([])

    package init(downstreamXPCService: String, shutdownInitiateContinuation: AsyncStream<Void>.Continuation) {
        self.downstreamXPCService = downstreamXPCService
        self.shutdownInitiateContinuation = shutdownInitiateContinuation
        self.signposter = OSSignposter(logger: self.logger)
    }

    private func sendToKVCacheTransfer(downstreamRequest:EnsembleWardenDaemonXPC.Request, requestID: UUID, spanID: UInt64) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let downstreamSession = try self.getDownstreamXPCSession()
                try downstreamSession.send(downstreamRequest) { response in
                    do {
                        _ = try response.get()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume()
                }
            } catch {
                logger.error("""
                    Error sending encrypted surface to tie-kvcache-transfer. \
                    error=\(String(reportable: error), privacy: .public) \
                    request_id=\(PrismTracing.requestID, privacy: .public) \
                    span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                    """)
                continuation.resume(throwing: EnsembleWardenError.kvCacheTransferFetchFailed)
            }
        }
    }

    private func getDownstreamXPCSession() throws -> XPCSession {
        try self.state.withLock { state in
            switch state {
            case .cryptoHandlesNotYetReceived:
                logger.error("""
                            Tried to connect to downstream before receiving a key. \
                            request_id=\(PrismTracing.requestID, privacy: .public) \
                            span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                            """)
                throw EnsembleWardenError.keyIDNotSupplied
            case .cryptoHandlesReceived(let cryptoHandles):
                let session = try XPCSession(machService: downstreamXPCService)
                state = .connectedToDownstream(cryptoHandles, session)
                return session
            case .connectedToDownstream(_, let session):
                return session
            }
        }
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
            case .connectedToDownstream(let cryptoHandles, _):
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
                        case .none:
                            self.logger.log("""
                                No handle to a porter. \
                                request_id=\(PrismTracing.requestID, privacy: .public) \
                                span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                                """)
                            porterConnection = nil
                        }

                        let cryptoHandles: CryptoHandlesState
                        do {
                            cryptoHandles = try CryptoHandlesState(ensemblePorterXPCConnection: porterConnection,
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
           case .connectedToDownstream(let cryptoHandles, _):
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

        logger.log("""
            Calling ftETOnlyTurn. \
            request_id=\(requestID, privacy: .public) \
            span_id=\(spanID.hexEncoded, privacy: .public)
            """)
        try await ensemblePorterClient.ftETOnlyTurn(requestID: requestID, spanID: spanID)

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

    /// Encrypts ioSurfaces using a key from ensembled and publishes the resulting ciphertext.
    /// - Parameters:
    ///   - serializedXPCRequest: The serialized XPC request that contains the ioSurface
    ///   - privateData: The data to encrypt and then publish.
    ///   - purpose: The purpose of the KV$ transfer that we're about to initiate. Eg is it for FT/ET?
    package func onPublish(serializedXPCRequest: Data, privateData decryptedSurfaces: [IOSurface], purpose: KVCacheTransferPurpose,
                           requestID: UUID, spanID: UInt64) async throws {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            PrismTracing.logCheckpoint(name: "EnsembleWardenPublishDaemon")
            try await self.doPublish(serializedXPCRequest: serializedXPCRequest,
                                    decryptedSurfaces: decryptedSurfaces,
                                    purpose: purpose)
        }
    }

    private func doPublish(serializedXPCRequest: Data, decryptedSurfaces: [IOSurface], purpose: KVCacheTransferPurpose) async throws {
        PrismTracing.logCheckpoint(name: "EnsembleWardenEncryptionStart")
        let encryptedSurfaces = try await self.encrypt(decryptedSurfaces: decryptedSurfaces, purpose: purpose)
        PrismTracing.logCheckpoint(name: "EnsembleWardenEncryptionEnd")
        let transferPurpose: EnsembleWardenDaemonXPC.TransferPurpose
        switch purpose {
        case .ftET:
            transferPurpose = .ftET
        }

        let downstreamRequest = EnsembleWardenDaemonXPC.Request.publish(.init(
            serializedXPCRequest: serializedXPCRequest,
            ioSurfaces: encryptedSurfaces,
            purpose: transferPurpose,
            requestID: PrismTracing.requestID,
            spanID: PrismTracing.spanID))
        let publishInterval = self.signposter.beginInterval("EW.publish_to_kvcache_transfer.signpost")
        defer {
            self.signposter.endInterval("EW.publish_to_kvcache_transfer.signpost", publishInterval)
        }
        try await sendToKVCacheTransfer(downstreamRequest: downstreamRequest, requestID: PrismTracing.requestID, spanID: PrismTracing.spanID)
    }

    /// Fetches ioSurfaces from the downstream EnsembleWardenServer, decrypts them, and then returns the plaintext.
    /// - Parameter serializedXPCRequest: The serialized XPC request that contains the ioSurface...
    package func onFetch(serializedXPCRequest: Data, requestID: UUID, spanID: UUID) async throws -> [IOSurface] {
        try await PrismTracing.withResumed(requestID: requestID, spanID: UInt64(uuid: spanID)) {
            return try await self.doFetch(serializedXPCRequest: serializedXPCRequest)
        }
    }

    private func doFetch(serializedXPCRequest: Data) async throws -> [IOSurface] {
        let fetchInterval = self.signposter.beginInterval("EW.fetch_from_kvcache.signpost")
        defer {
            self.signposter.endInterval("EW.fetch_from_kvcache.signpost", fetchInterval)
        }
        let encryptedSurfaces = try await fetchEncryptedSurfaces(serializedXPCRequest: serializedXPCRequest)
        let final = try await self.decrypt(encryptedSurfaces: encryptedSurfaces)
        return final
    }


    private func fetchEncryptedSurfaces(serializedXPCRequest: Data) async throws -> [IOSurface] {
        do {
            let downstreamRequest = EnsembleWardenDaemonXPC.Fetch(
                serializedXPCRequest: serializedXPCRequest,
                requestID: PrismTracing.requestID,
                spanID: PrismTracing.spanID
            )
            let downstreamSession = try self.getDownstreamXPCSession()
            let response = try await downstreamSession.sendXPC(request: downstreamRequest)
            switch response {
            case .success(let ioSurfaces): return ioSurfaces
            case .failure(let error): throw error
            }
        } catch {
            logger.error("""
                Failed to fetch from tie-kv$-transfer. \
                error=\(String(reportable: error), privacy: .public) \
                request_id=\(PrismTracing.requestID, privacy: .public) \
                span_id=\(PrismTracing.spanID.hexEncoded, privacy: .public)
                """)
            throw EnsembleWardenError.kvCacheTransferFetchFailed
        }
    }

    internal func getEnsemblePorterClient() throws -> EnsemblePorterKeyFetcher {
        let cryptoState = try self.state.withLock { state in
            switch state {
            case .cryptoHandlesNotYetReceived:
                throw EnsembleWardenError.keyIDNotSupplied
            case .cryptoHandlesReceived(let cryptoHandles):
                return cryptoHandles
            case .connectedToDownstream(let cryptoHandles, _):
                return cryptoHandles
            }
        }
        guard let ensemblePorterClient = cryptoState.ensemblePorterClient else {
            throw EnsembleWardenError.keyIDNotSupplied
        }
        return ensemblePorterClient
    }

    private func shutdownSessionAndInitiateShutdown() {
        self.state.withLock { state in
            switch state {
            case .connectedToDownstream(_, let session): session.cancel(reason: "Finished")
            default: break
            }
        }
        self.shutdownInitiateContinuation.yield()
    }

    package func onFinish() async throws {
        self.shutdownSessionAndInitiateShutdown()
    }

    package func onCancellation() throws {
        self.shutdownSessionAndInitiateShutdown()
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
            PrismTracing.logCheckpoint(name: "Daemon onPublish2")
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
            PrismTracing.logCheckpoint(name: "EnsembleWardenEncryptionEnd")
            let publishInterval = self.signposter.beginInterval(
                "EW.publish_to_ensembletransport.signpost")
            defer {
                self.signposter.endInterval(
                    "EW.publish_to_ensembletransport.signpost",
                    publishInterval)
            }
            PrismTracing.logCheckpoint(name: "EnsembleWardenTransportPublishStart")
#if canImport(EnsembleTransport)
            if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
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
            } else {
                self.logger.log("EnsembleTransport not available at runtime, skipping publish")
            }
#else
            self.logger.log("EnsembleTransport not available at build time, skipping publish")
#endif
            PrismTracing.logCheckpoint(name: "EnsembleWardenTransportPublishCompleted")
        }
    }

    package func onFetch2(
        identifier: String,
        range: ClosedRange<Int>?,
        host: String,
        requestID: UUID,
        spanID: UInt64
    ) async throws -> IOSurface {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            PrismTracing.logCheckpoint(name: "EnsembleWardenOnFetch2Daemon")
            let fetchInterval = self.signposter.beginInterval(
                "EW.fetch_from_ensembletransport.signpost")
            defer {
                self.signposter.endInterval(
                    "EW.fetch_from_ensembletransport.signpost", fetchInterval)
            }
#if canImport(EnsembleTransport)
            if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
                let encryptedSurface = try await self.ensembleTransportFetch(
                    identifier: identifier, host: host)
                PrismTracing.logCheckpoint(name: "EnsembleWardenDecryptionStart")
                let plaintextSurfaces = try await self.decrypt(
                    encryptedSurfaces: [encryptedSurface])
                PrismTracing.logCheckpoint(name: "EnsembleWardenDecryptionEnd")
                return plaintextSurfaces.first!
            } else {
                self.logger.log("EnsembleTransport not available at runtime, returning empty IOSurface")
                return IOSurface()
            }
#else
            self.logger.log("EnsembleTransport not available at build time, returning empty IOSurface")
            return IOSurface()
#endif
        }
    }

    package func onFetchMetadata(
        identifier: String,
        host: String,
        requestID: UUID,
        spanID: UInt64
    ) async throws -> IOSurface? {
        try await PrismTracing.withResumed(requestID: requestID, spanID: spanID) {
            PrismTracing.logCheckpoint(name: "EnsembleWardenOnFetchMetadataDaemon")
            let fetchInterval = self.signposter.beginInterval(
                "EW.fetchmetadata_from_ensembletransport.signpost")
            defer {
                self.signposter.endInterval(
                    "EW.fetchmetadata_from_ensembletransport.signpost", fetchInterval)
            }
#if canImport(EnsembleTransport)
            if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
                let encryptedSurface = try await self.ensembleTransportFetch(
                    identifier: self.metadataIdentifier(identifier), host: host)
                PrismTracing.logCheckpoint(name: "EnsembleWardenDecryptionStart")
                let plaintextSurfaces = try await self.decrypt(
                    encryptedSurfaces: [encryptedSurface])
                PrismTracing.logCheckpoint(name: "EnsembleWardenDecryptionEnd")
                return plaintextSurfaces.first!
            } else {
                self.logger.log("EnsembleTransport not available at runtime, returning nil for metadata")
                return nil
            }
#else
            self.logger.log("EnsembleTransport not available at build time, returning nil for metadata")
            return nil
#endif
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
#if canImport(EnsembleTransport)
            if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
                try await self.ensembleTransportDelete(
                    identifier: identifier,
                    host: host)
            } else {
                self.logger.log("""
                    EnsembleTransportClient not available at runtime, \
                    ignoring delete
                    """)
            }
#else
            self.logger.log("""
                EnsembleTransportClient not available at build time, \
                ignoring delete
                """)
#endif
        }

    }

    package func onDropAll() async throws {
        let interval = self.signposter.beginInterval("EW.dropAll_ensembletransport.signpost")
        defer {
            self.signposter.endInterval("EW.dropAll_ensembletransport.signpost", interval)
        }

        logger.log("Dropping all cached data")

#if canImport(EnsembleTransport)
        if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
            try await self.ensembleTransportDropCache()
        } else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime, \
                ignoring dropAll
                """)
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time, \
            ignoring dropAll
            """)
#endif
    }
}

extension DaemonHandler {
    private func ensembleTransportPublish(
        identifier: String,
        data: IOSurface,
        timeout: Duration
    ) async throws {
#if canImport(EnsembleTransport)
        if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
            let client = try EnsembleTransportClient()
            try await client.publish(
                identifier, data: data, timeout: Int(timeout.components.seconds))
        } else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime, \
                ignoring publish
                """)
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time, \
            ignoring publish
            """)
#endif
    }

    private func ensembleTransportFetch(
        identifier: String,
        host: String
    ) async throws -> IOSurface {
#if canImport(EnsembleTransport)
        if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
            let client = try EnsembleTransportClient()
            // fetchPreparwWithSurface gives us back an IOSurface that doesn't yet have the
            // relevant data written to it.
            let surfaceHint = try await client.fetchPrepareWithSurface(identifier, fromHost: host)
            return try await withThrowingTaskGroup(of: Optional<IOSurface>.self) { group in
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
                    let fetchedSurface = try await client.fetch(identifier)
                    if fetchedSurface.baseAddress != surfaceHint.baseAddress {
                        self.logger.warning("fetchPrepareWithSurface returned a different surface to fetch")
                    }
                    return fetchedSurface
                }
                for try await surface in group {
                    if let surface {
                        return surface
                    }
                }
                throw EnsembleWardenError.failedToGenerateIOSurface
            }

        } else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime, \
                ignoring fetch and returning empty IOSurface
                """)
            return IOSurface()
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time, \
            ignoring fetch and returning empty IOSurface
            """)
        return IOSurface()
#endif
    }

    private func ensembleTransportDelete(
        identifier: String,
        host: String?
    ) async throws {
#if canImport(EnsembleTransport)
        if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
            let client = try EnsembleTransportClient()
            if let host {
                try await client.remoteDelete(identifier, onHost: host)
            } else {
                try await client.delete(identifier)
            }
        } else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime, \
                ignoring delete
                """)
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time, \
            ignoring delete
            """)
#endif
    }

    private func ensembleTransportDropCache() async throws {
#if canImport(EnsembleTransport)
        if #_hasSymbol(EnsembleTransport.EnsembleTransportClient.self) {
            let client = try EnsembleTransportClient()
            try await client.dropCache()
        } else {
            self.logger.log("""
                EnsembleTransportClient not available at runtime, \
                ignoring dropCache
                """)
        }
#else
        self.logger.log("""
            EnsembleTransportClient not available at build time, \
            ignoring dropCache
            """)
#endif
    }

    private func metadataIdentifier(_ identifier: String) -> String {
        return "\(identifier)-metadata"
    }
}

