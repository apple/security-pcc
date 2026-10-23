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

import CPAgentProtos
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import ServiceLifecycle
import SwiftProtobuf

// MARK: - Server

/// Hosts the dynamic config gRPC service over a Unix Domain Socket.
/// If the socket directory does not exist (shared volume not mounted), logs a warning and idles.
struct DynamicConfigGRPCServer: Service {
    let socketPath: String
    let dynamicConfigGRPCService: DynamicConfigGRPCService
    private let logger = Logger(label: "CPAgent.DynamicConfigGRPCServer")

    init(
        socketPath: String,
        dynamicConfigGRPCService: DynamicConfigGRPCService
    ) {
        self.socketPath = socketPath
        self.dynamicConfigGRPCService = dynamicConfigGRPCService
    }

    /// How long to wait before retrying after the socket directory or server setup fails, so that
    /// dynamic-config.sock keeps coming back rather than staying unavailable for the life of the process.
    private static let retryDelay: Duration = .seconds(30)

    func run() async throws {
        while !Task.isCancelled {
            await runOnce()
            if !Task.isCancelled {
                try? await Task.sleep(for: Self.retryDelay)
            }
        }
    }

    private func runOnce() async {
        let socketDirectory = (socketPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: socketDirectory) {
            do {
                try FileManager.default.createDirectory(
                    atPath: socketDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                logger.info(
                    "Created socket directory",
                    metadata: ["directory": "\(socketDirectory)"])
            } catch {
                logger.error(
                    "Failed to create socket directory, will retry",
                    metadata: [
                        "directory": "\(socketDirectory)", "error": "\(String(reportable: error))",
                    ])
                return
            }
        }

        // Remove a stale socket file (e.g. left behind by a previous crashed process) so bind/listen
        // doesn't fail repeatedly with "address already in use".
        try? FileManager.default.removeItem(atPath: socketPath)

        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        let server = GRPCServer(
            transport: transport,
            services: [dynamicConfigGRPCService]
        )

        logger.info(
            "Dynamic config gRPC server starting", metadata: ["socketPath": "\(self.socketPath)"])

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await server.serve()
                }
                group.addTask {
                    _ = try await server.transport.listeningAddress
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o666], ofItemAtPath: socketPath)
                }
                try await group.waitForAll()
            }
        } catch {
            logger.error(
                "Dynamic config gRPC server failed, will restart",
                metadata: [
                    "socketPath": "\(self.socketPath)", "error": "\(String(reportable: error))",
                ])
        }
    }
}

// MARK: - Service handler

/// gRPC service handler for the dynamic config stream.
/// Services subscribe via this stream. When a config update is received from the health service,
/// DynamicConfigService notifies this handler, which pushes ConfigUpdate messages to subscribed clients.
struct DynamicConfigGRPCService: Config_ConfigService.SimpleServiceProtocol, Sendable {
    let dynamicConfigService: DynamicConfigService
    private let logger = Logger(label: "CPAgent.DynamicConfigGRPCService")

    /// A config update queued for delivery, paired with a completion callback so the producer
    /// (DynamicConfigService) can await confirmation of whether the write actually succeeded,
    /// rather than treating a successful handoff into the queue as delivery.
    private struct QueuedConfigUpdate: Sendable {
        let configUpdate: DynamicConfigService.ConfigUpdate
        let completion: @Sendable (Result<Void, Error>) -> Void
    }

    private enum DeliveryError: Error, Sendable, ReportableError {
        case writeFailed

        var publicDescription: String {
            "DeliveryError.writeFailed"
        }
    }

    func subscribe(
        request: Config_SubscribeRequest,
        response: GRPCCore.RPCWriter<Config_ConfigUpdate>,
        context: GRPCCore.ServerContext
    ) async throws {
        let clientName = request.clientName
        logger.info("Client subscribed to config updates", metadata: ["client": "\(clientName)"])

        // Queue of updates to write to the client, one at a time, on this task so writes stay
        // serialized. Each queued item carries a completion so the pusher awaits confirmation
        // that the write actually succeeded before considering the update delivered.
        let (stream, continuation) = AsyncStream<QueuedConfigUpdate>.makeStream()

        do {
            try await dynamicConfigService.addConfigListener(serviceName: clientName) {
                configUpdate in
                try await withCheckedThrowingContinuation {
                    (delivered: CheckedContinuation<Void, Error>) in
                    continuation.yield(
                        QueuedConfigUpdate(configUpdate: configUpdate) { result in
                            delivered.resume(with: result)
                        })
                }
            }
        } catch {
            logger.warning(
                "Rejecting subscribe request",
                metadata: ["client": "\(clientName)", "error": "\(String(reportable: error))"])
            throw RPCError(code: .invalidArgument, message: String(reportable: error))
        }

        defer {
            Task {
                await dynamicConfigService.removeConfigListener(serviceName: clientName)
            }
        }

        // Forward config updates to the gRPC client, one at a time, until a write fails.
        for await queued in stream {
            do {
                // Convert business logic ConfigUpdate to protobuf ConfigUpdate
                var configData = Google_Protobuf_Struct()
                for (key, value) in queued.configUpdate.config {
                    configData.fields[key] = Google_Protobuf_Value(stringValue: value)
                }

                let protoUpdate = Config_ConfigUpdate.with {
                    $0.version = queued.configUpdate.version
                    $0.timestamp = Google_Protobuf_Timestamp(date: queued.configUpdate.timestamp)
                    $0.config = configData
                }

                try await response.write(protoUpdate)
                logger.debug(
                    "Sent config update to client",
                    metadata: [
                        "client": "\(clientName)",
                        "version": "\(queued.configUpdate.version)",
                    ])
                queued.completion(.success(()))
            } catch {
                logger.error(
                    "Failed to send config update to client",
                    metadata: ["client": "\(clientName)", "error": "\(String(reportable: error))"])
                queued.completion(.failure(DeliveryError.writeFailed))
                break
            }
        }

        // Stop accepting new updates and fail out anything already queued but not yet attempted,
        // so producers awaiting delivery confirmation aren't left hanging forever.
        continuation.finish()
        for await leftover in stream {
            leftover.completion(.failure(DeliveryError.writeFailed))
        }

        logger.info("Config subscription ended", metadata: ["client": "\(clientName)"])
    }
}
