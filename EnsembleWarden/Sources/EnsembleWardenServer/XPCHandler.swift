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
//  DaemonXPCHandler.swift
//  EnsembleWarden
//
//  Created by Oliver Chick (ORAC) on 13/12/2024.
//

private import CryptoKit
private import EnsembleWardenCommon
internal import EnsembleWardenXPCAPI
private import IOSurface
private import os
@_spiOnly import Security_Private.SecTaskPriv
@_spi(Private) @preconcurrency private import XPC
private import XPCPrivate

/// Handling of XPC message types
///
/// Takes XPC messages and calls the user's handlers with their nice Swift APIs.
package struct XPCHandler<UserHandler: EnsembleWardenServerHandler & Sendable, Factory: MetricsFactory>: XPCPeerHandler, Sendable {
    private let handler: UserHandler
    private let logger = Logger(subsystem: "com.apple.cloudos.ensemblewardend", category: "XPCHandler")
    private let ensembleWardenMetrics: EnsembleWardenMetrics<Factory>

    package init(ensembleWardenHandler: UserHandler, ensembleWardenMetrics: EnsembleWardenMetrics<Factory>) {
        self.handler = ensembleWardenHandler
        self.ensembleWardenMetrics = ensembleWardenMetrics
    }

    private func handle(startMessage: EnsembleWardenDaemonXPC.Start) async -> EnsembleWardenDaemonXPC.Start.Response {
        await PrismTracing.withResumed(requestID: startMessage.requestID) {
            await self.doHandle(startMessage: startMessage)
        }
    }

    private func doHandle(startMessage: EnsembleWardenDaemonXPC.Start) async -> EnsembleWardenDaemonXPC.Start.Response {
        let ensemblePorterConnection: xpc_connection_t?
        if let xpcObject = startMessage.ensemblePorterConnection {
            let dict = xpcObject.copyUnderlyingXPCObject()

            ensemblePorterConnection = xpc_dictionary_create_connection(
                dict,
                EnsembleWardenConstants.ensemblePorterConnectionNameInXPCDict)
            // Given the startMessage has a `ensemblePorterConnection` we better
            // not get a nil here.
            assert(ensemblePorterConnection != nil)
        } else {
            ensemblePorterConnection = nil
        }

        let ensembleWardenCryptoHandles: EnsembleWardenCryptoHandles
        if let ensemblePorterConnection {
            ensembleWardenCryptoHandles = .init(
                ensemblePorterIdentifier: .ensemblePorterHandle(
                    ensemblePorterConnection))
        } else if let followerToken = startMessage.followerToken {
            ensembleWardenCryptoHandles = .init(
                ensemblePorterIdentifier: .followerToken(followerToken))
        } else {
            return .failure(EnsembleWardenError.invalidStartMessage)
        }
        do {
            return try await self.ensembleWardenMetrics.reportingXPCMetrics(operationName: "start") {
                let tokens = try await handler.start(ensembleWardenCryptoHandles: ensembleWardenCryptoHandles,
                                                     requestID: PrismTracing.requestID,
                                                     spanID: PrismTracing.spanID)
                return .success(tokens.values)
            }
        } catch {
            return self.handleError(operation: "start", error: error) { .failure($0) }
        }
    }

    private func handle(publishMessage: EnsembleWardenDaemonXPC.Publish) async -> EnsembleWardenDaemonXPC.Publish.Response {
        do {
            return try await PrismTracing.withResumed(requestID: publishMessage.requestID,
                                                      spanID: publishMessage.spanID) {
                return try await self.ensembleWardenMetrics.reportingXPCMetrics(operationName: "publish") {
                    try await handler.onPublish(serializedXPCRequest: publishMessage.serializedXPCRequest,
                                                privateData: publishMessage.ioSurfaces,
                                                purpose: .init(xpcPurpose: publishMessage.purpose),
                                                requestID: PrismTracing.requestID,
                                                spanID: PrismTracing.spanID)
                    return .success(.init())
                }
            }
        } catch {
            return self.handleError(operation: "publish", error: error) { .failure($0) }
        }
    }


    private func handle(fetchMessage: EnsembleWardenDaemonXPC.Fetch) async -> EnsembleWardenDaemonXPC.Fetch.Response {
        do {
            return try await PrismTracing.withResumed(requestID: fetchMessage.requestID,
                                                      spanID: fetchMessage.spanID) {
                return try await self.ensembleWardenMetrics.reportingXPCMetrics(operationName: "fetch") {
                    let ioSurfaces = try await handler.onFetch(serializedXPCRequest: fetchMessage.serializedXPCRequest,
                                                               requestID: PrismTracing.requestID,
                                                               spanID: .init(uint: PrismTracing.spanID))

                    return .success(ioSurfaces)
                }
            }
        } catch {
            return self.handleError(operation: "fetch", error: error) { .failure($0) }
        }
    }

    private func handle(prefaultMessage: EnsembleWardenDaemonXPC.Prefault) async -> EnsembleWardenDaemonXPC.Prefault.Response {
        do {
            return try await PrismTracing.withResumed(requestID: prefaultMessage.requestID,
                                                      spanID: prefaultMessage.spanID) {
                return try await self.ensembleWardenMetrics.reportingXPCMetrics(operationName: "prefault") {
                    try await handler.onPrefault(ioSurfaces: prefaultMessage.ioSurfaces,
                                                 requestID: PrismTracing.requestID,
                                                 spanID: PrismTracing.spanID)
                    return .success(.init())
                }
            }
        } catch let error as EnsembleWardenError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedError)
        }
    }

    package func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        Task(priority: .userInitiated) {
            let decodedMessage = try message.decode(as: EnsembleWardenDaemonXPC.Request.self)
            let response: any Encodable = switch decodedMessage {
                case .empty: EnsembleWardenDaemonXPC.Empty.Response.init()
                case .start(let startMessage):
                    await handle(startMessage: startMessage)
                case .publish(let publishMessage):
                    await handle(publishMessage: publishMessage)
                case .fetch(let fetchMessage):
                    await handle(fetchMessage: fetchMessage)
                case .prefault(let prefaultMessage):
                    await handle(prefaultMessage: prefaultMessage)
                case .dropAll(let dropAllMessage):
                    await handle(dropAllMessage: dropAllMessage)
            }
            message.reply(response)
        }
        return nil
    }

    package func handleCancellation(error: XPCRichError) {
        logger.log("XPC cancellation. error=\(error, privacy: .public)")
        do {
            try handler.onCancellation()
        } catch {
            logger.error("""
                Error handling cancellation. \
                error=\(String(reportable: error), privacy: .public)
                """)
        }
    }
}

extension XPCHandler {
    private func handle(
        publish2Message: EnsembleWardenDaemonXPC.Publish2
    ) async -> EnsembleWardenDaemonXPC.Publish2.Response {
        do {
            return try await self.ensembleWardenMetrics.reportingXPCMetrics(
                operationName: "publish2") {
                try await handler.onPublish2(
                    identifier: publish2Message.identifier,
                    privateData: publish2Message.privateData,
                    privateMetadata: publish2Message.privateMetadata,
                    ttl: publish2Message.ttl,
                    purpose: .init(xpcPurpose: publish2Message.purpose),
                    requestID: publish2Message.requestID,
                    spanID: publish2Message.spanID)
                return .success(.init())
            }
        } catch {
            return self.handleError(operation: "publish2", error: error) { .failure($0) }
        }
    }

    private func handle(
        fetch2Message: EnsembleWardenDaemonXPC.Fetch2
    ) async -> EnsembleWardenDaemonXPC.Fetch2.Response {
        do {
            return try await  self.ensembleWardenMetrics.reportingXPCMetrics(
                operationName: "fetch2") {
                let ioSurface = try await handler.onFetch2(
                    identifier: fetch2Message.identifier,
                    range: fetch2Message.range,
                    host: fetch2Message.host,
                    requestID: fetch2Message.requestID,
                    spanID: fetch2Message.spanID)
                return .success(ioSurface)
            }
        } catch {
            return self.handleError(operation: "fetch2", error: error) { .failure($0) }
        }
    }

    private func handle(
        fetchMetadataMessage: EnsembleWardenDaemonXPC.FetchMetadata
    ) async -> EnsembleWardenDaemonXPC.FetchMetadata.Response {
        do {
            return try await  self.ensembleWardenMetrics.reportingXPCMetrics(
                operationName: "fetchMetadata") {
                let ioSurfaces = try await handler.onFetchMetadata(
                    identifier: fetchMetadataMessage.identifier,
                    host: fetchMetadataMessage.host,
                    requestID: fetchMetadataMessage.requestID,
                    spanID: fetchMetadataMessage.spanID)
                return .success(ioSurfaces)
            }
        } catch {
            return self.handleError(operation: "fetchMetadata", error: error) { .failure($0) }
        }
    }

    private func handle(
        deleteMessage: EnsembleWardenDaemonXPC.Delete
    ) async -> EnsembleWardenDaemonXPC.Delete.Response {
        do {
            return try await self.ensembleWardenMetrics.reportingXPCMetrics(
                operationName: "delete") {
                try await handler.onDelete(
                    identifier: deleteMessage.identifier,
                    host: deleteMessage.host,
                    requestID: deleteMessage.requestID,
                    spanID: deleteMessage.spanID)
                return .success(.init())
            }
        } catch {
            return self.handleError(operation: "delete", error: error) { .failure($0) }
        }
    }

    private func handle(
        dropAllMessage: EnsembleWardenDaemonXPC.DropAll
    ) async -> EnsembleWardenDaemonXPC.DropAll.Response {
        do {
            return try await self.ensembleWardenMetrics.reportingXPCMetrics(
                operationName: "dropAll") {
                try await handler.onDropAll()
                return .success(.init())
            }
        } catch {
            return self.handleError(operation: "dropAll", error: error) { .failure($0) }
        }
    }

    private func handleError<T>(
        operation: String,
        error: Error,
        failure: (EnsembleWardenError) -> T
    ) -> T {
        if let wardenError = error as? EnsembleWardenError {
            return failure(wardenError)
        }
        let errorType = String(describing: type(of: error))
        logger.error("""
            External error. \
            operation=\(operation, privacy: .public) \
            error=\(String(reportable: error), privacy: .public)
            """)
        return failure(.externalError(type: errorType))
    }
}

fileprivate extension KVCacheTransferPurpose {
    init(xpcPurpose: EnsembleWardenDaemonXPC.TransferPurpose) {
        switch xpcPurpose {
        case .ftET:
            self = .ftET
        }
    }
}
