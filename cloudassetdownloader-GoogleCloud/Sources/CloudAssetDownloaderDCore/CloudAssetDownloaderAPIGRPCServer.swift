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

import CloudAssetDownloaderAPI
import CloudAssetDownloaderProto
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import Synchronization

#if canImport(System)
import System
#else
import SystemPackage
#endif

final class CloudAssetDownloaderAPIGRPCServer: CloudAssetDownloaderAPIServer {
    private static let logger = Logger.forType(CloudAssetDownloaderAPIGRPCServer.self)

    private let socketPath: String
    private let delegate: Mutex<(any CloudAssetDownloaderAPIServerDelegate)?>
    private let stateMachine: Mutex<CloudAssetDownloaderAPIServerStateMachine>

    init(socketPath: String = "/var/run/cloudassetdownloader/cloudassetdownloader.sock") {
        self.socketPath = socketPath
        self.delegate = .init(nil)
        self.stateMachine = .init(.init())
    }

    func run() async throws {
        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: self.socketPath),
            transportSecurity: .plaintext
        )
        let server = GRPCServer(transport: transport, services: [self])
        Self.logger.info("gRPC server listening", metadata: ["socketPath": "\(self.socketPath)"])

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.serve()
            }
            // rdar://183134000
            group.addTask { [socketPath = self.socketPath] in
                do {
                    _ = try await transport.listeningAddress
                    try Self.relaxSocketPermissions(at: socketPath)
                } catch is CancellationError {
                    // Graceful shutdown before the socket was bound; nothing to do.
                } catch {
                    Self.logger.error(
                        "Failed to relax gRPC socket permissions",
                        metadata: [
                            "socketPath": "\(socketPath)",
                            "error": "\(String(describing: error))",
                        ]
                    )
                    throw error
                }
            }

            try await group.waitForAll()
        }
    }

    private static func relaxSocketPermissions(at path: String) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o766],
            ofItemAtPath: path
        )
        Self.logger.info(
            "Relaxed socket permissions",
            metadata: ["socketPath": "\(path)", "mode": "0o766"]
        )
    }

    func setDelegate(_ delegate: any CloudAssetDownloaderAPIServerDelegate) {
        self.delegate.withLock { $0 = delegate }
    }

    func onAssetBundleUpdate(consumerID: String, assets: Set<AssetMetadata>) async {
        self.stateMachine.withLock {
            $0.onAssetBundleUpdate(consumerID: consumerID, assetBundle: assets)
        }
    }
}

extension CloudAssetDownloaderAPIGRPCServer: Proto_CAD_CloudAssetDownloaderService.SimpleServiceProtocol {
    func watchAssetBundle(
        request: Proto_CAD_WatchAssetBundleRequest,
        response: RPCWriter<Proto_CAD_AssetBundleUpdate>,
        context _: ServerContext
    ) async throws {
        let consumerID = request.consumerID
        let stream: AsyncStream<Set<AssetMetadata>>
        do {
            stream = try self.stateMachine.withLock {
                try $0.onConsumerConnect(consumerID: consumerID)
            }
        } catch let error as CloudAssetDownloaderAPIServerStateMachine.StateError {
            throw RPCError(code: .invalidArgument, message: error.description)
        } catch {
            throw RPCError(code: .internalError, message: String(describing: error))
        }

        let unregisteredConsumer = Mutex(false)
        let unregisterConsumer: @Sendable () -> Void = {
            let shouldUnregister = unregisteredConsumer.withLock {
                guard !$0 else {
                    return false
                }
                $0 = true
                return $0
            }
            if shouldUnregister {
                self.stateMachine.withLock {
                    $0.onConsumerDisconnect(consumerID: consumerID)
                }
            }
        }

        try await withRPCCancellationHandler {
            defer {
                unregisterConsumer()
            }
            try await self.streamAssetBundleUpdates(
                consumerID: consumerID,
                stream: stream,
                responseWriter: response
            )
        } onCancelRPC: {
            Self.logger.info("Asset bundle streaming RPC cancelled")
            unregisterConsumer()
        }
    }

    private func streamAssetBundleUpdates(
        consumerID: ConsumerID,
        stream: AsyncStream<Set<AssetMetadata>>,
        responseWriter: RPCWriter<Proto_CAD_AssetBundleUpdate>
    ) async throws {
        for await assetBundle in stream {
            Self.logger.info(
                "Sending asset bundle update to consumer",
                metadata: [
                    "consumerID": "\(consumerID)",
                    "assetBundle": "\(assetBundle)",
                ]
            )
            let responseMessage = Proto_CAD_AssetBundleUpdate.with { message in
                message.consumerID = consumerID
                message.assets = assetBundle.map { asset in
                    Proto_CAD_AssetMetadata.with {
                        $0.assetID = asset.id
                        $0.assetVersion = asset.version
                        $0.assetLocation = asset.location.string
                    }
                }
            }
            try await responseWriter.write(responseMessage)
        }
    }

    func reportAssetBundleConsumption(
        request: Proto_CAD_ReportConsumptionRequest,
        context _: ServerContext
    ) async throws -> Proto_CAD_ReportConsumptionResponse {
        let consumerID = request.consumerID
        let assetUIDs = Set(
            request.assets.map {
                AssetUID(consumerID: consumerID, assetID: $0.assetID, version: $0.assetVersion)
            }
        )

        let result: Result<Void, any Error>
        switch request.result {
        case .success:
            result = .success(())
        case let .failure(failure):
            result = .failure(AssetConsumptionError(reason: failure.reason))
        case nil:
            throw RPCError(code: .invalidArgument, message: "missing result")
        }

        try self.delegate.withLock {
            guard let delegate = $0 else {
                throw RPCError(code: .internalError, message: "no delegate set")
            }
            delegate.onAssetBundleConsumptionResult(result, consumerID: consumerID, assetUIDs: assetUIDs)
        }
        return .init()
    }
}

private struct AssetConsumptionError: Error {
    let reason: String
}
