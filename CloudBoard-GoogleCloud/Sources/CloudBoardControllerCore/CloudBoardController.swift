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

import CloudBoardProtos
import Configuration
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import MirkwoodConfiguration

package enum WorkloadTagType: String, Hashable, Sendable {
    case string
    case stringList
}

package enum WorkloadTagValue: Hashable, Sendable {
    case string(String)
    case stringList([String])
}

public struct RoutingTagValue: Sendable {
    package let wrapped: WorkloadTagValue
    public static func from(string: String) -> Self {
        self.init(wrapped: .string(string))
    }

    public static func from(strings: [String]) -> Self {
        self.init(wrapped: .stringList(strings))
    }
}

public struct ComputeWorkloadConfig: Sendable {
    public var maxBatchSize: Int
    public var optimalBatchSize: Int
    public var workloadTags: [String: RoutingTagValue]

    public init(maxBatchSize: Int, optimalBatchSize: Int, workloadTags: [String: RoutingTagValue]) {
        self.maxBatchSize = maxBatchSize
        self.optimalBatchSize = optimalBatchSize
        self.workloadTags = workloadTags
    }
}

public struct WorkloadProperties: Sendable {
    public var workloadName: String

    public init(workloadName: String) {
        self.workloadName = workloadName
    }
}

public enum WorkloadControllerStateKind: Sendable {
    case initializing(phase: String)
    case ready
    case busy(reason: String)
    case transientError(message: String?)
    case terminalError(message: String?)
}

public struct WorkloadControllerState: Sendable {
    var kind: WorkloadControllerStateKind

    public static func initializing(phase: String) -> Self {
        Self(kind: .initializing(phase: phase))
    }

    public static func ready() -> Self {
        Self(kind: .ready)
    }

    public static func busy(reason: String) -> Self {
        Self(kind: .busy(reason: reason))
    }

    public static func transientError(message: String?) -> Self {
        Self(kind: .transientError(message: message))
    }

    public static func terminalError(message: String?) -> Self {
        Self(kind: .terminalError(message: message))
    }
}

public struct SetStateResult: Sendable {
    public init() {}
}

public protocol CloudBoardController: Sendable {
    func registerWorkload(properties: WorkloadProperties, config: ComputeWorkloadConfig) async throws
    func setState(_ state: WorkloadControllerState) async throws -> SetStateResult
}

struct LocalCloudBoardController<Transport: GRPCCore.ClientTransport>: CloudBoardController {
    private let client: Proto_Controller_Controller.Client<Transport>

    init(client: Proto_Controller_Controller.Client<Transport>) {
        self.client = client
    }

    func registerWorkload(properties: WorkloadProperties, config: ComputeWorkloadConfig) async throws {
        var registerRequest = Proto_Controller_RegisterWorkloadProperties()
        registerRequest.workloadProperties = Proto_Controller_WorkloadProperties(from: properties)
        registerRequest.computeWorkloadConfig = Proto_Controller_ComputeWorkloadConfig(from: config)

        _ = try await self.client.registerWorkload(registerRequest)
    }

    func setState(_ state: WorkloadControllerState) async throws -> SetStateResult {
        let stateRequest = Proto_Controller_WorkloadControllerState(from: state)
        let stateResponse = try await self.client.setState(stateRequest)
        return SetStateResult(from: stateResponse)
    }
}

struct PublishingCloudBoardController: CloudBoardController {
    let inner: any CloudBoardController
    let publisher: WorkloadStatePublisher

    func registerWorkload(properties: WorkloadProperties, config: ComputeWorkloadConfig) async throws {
        try await inner.registerWorkload(properties: properties, config: config)
        var protoState = Proto_Controller_WorkloadState()
        protoState.workloadProperties = Proto_Controller_WorkloadProperties(from: properties)
        protoState.computeWorkloadConfig = Proto_Controller_ComputeWorkloadConfig(from: config)
        publisher.updateState(.ready, properties: protoState)
    }

    func setState(_ state: WorkloadControllerState) async throws -> SetStateResult {
        let result = try await inner.setState(state)
        publisher.updateState(state.kind)
        return result
    }
}

public struct CloudBoardSupport {
}

struct ControllerConnectionError: Error {
    let message: String
}

extension CloudBoardSupport {
    public static func withController<R: Sendable>(
        _ handler: @escaping @Sendable (any CloudBoardController) async throws -> R
    ) async throws -> R {
        let configReader = try await ConfigReader(providers: [
            EnvironmentVariablesProvider(),
            UnmeasuredConfigurationProvider(scope: .local),
            UnmeasuredConfigurationProvider(scope: .global),
        ])
        return try await Self.withController(
            configReader: configReader,
            handler
        )
    }

    package static func withController<R: Sendable>(
        configReader: ConfigReader,
        maxAttempts: Int = 10,
        initialBackoff: UInt64 = 50,
        _ handler: @escaping @Sendable (any CloudBoardController) async throws -> R
    ) async throws -> R {
        let logger = Logger(label: "CloudBoardController.withController")
        let publisher = WorkloadStatePublisher()

        let watchStateSocketPath = configReader.string(
            forKey: "workload.state.grpc.uds",
            default: "/var/run/workload-status/workload-state.sock"
        )

        return try await withThrowingDiscardingTaskGroup { group in
            let server = GRPCServer(
                transport: .http2NIOPosix(
                    address: .unixDomainSocket(path: watchStateSocketPath),
                    transportSecurity: .plaintext
                ),
                services: [WorkloadStateService(publisher: publisher)]
            )
            group.addTask {
                do {
                    try await server.serve()
                } catch  where error is CancellationError || (error as? RuntimeError)?.cause is CancellationError {
                    logger.info("WatchState server stopped.", metadata: ["error": "\(String(reportable: error))"])
                } catch {
                    logger.error("WatchState server failed", metadata: ["error": "\(String(reportable: error))"])
                }
            }

            // Once the socket is bound, relax its permissions so cloudboardd can connect() even when running as a
            // different
            group.addTask {
                do {
                    _ = try await server.transport.listeningAddress
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o766],
                        ofItemAtPath: watchStateSocketPath
                    )
                    logger.info("Relaxed watch-state socket permissions", metadata: ["path": "\(watchStateSocketPath)"])
                } catch is CancellationError {
                    // Graceful shutdown
                } catch {
                    logger.error(
                        "Failed to relax watch-state socket permissions",
                        metadata: ["path": "\(watchStateSocketPath)", "error": "\(String(reportable: error))"]
                    )
                    throw error
                }
            }

            defer {
                // beginGracefulShutdown() signals connected clients so they can
                // reconnect cleanly, but it does not close active streaming connections —
                // serve() will keep running as long as any subscriber is connected.
                // group.cancelAll() force-cancels the server task, which is what actually
                // unblocks withThrowingDiscardingTaskGroup and allows this function to return.
                server.beginGracefulShutdown()
                group.cancelAll()
            }

            let udsPath = configReader.string(
                forKey: "workload.controller.grpc.uds",
                default: "/var/run/tie-controllerd/tie-controllerd.sock"
            )

            var lastError: Error?
            var backoffMs = initialBackoff

            for attempt in 1...maxAttempts {
                do {
                    logger.debug(
                        "Connection attempt",
                        metadata: [
                            "attempt": "\(attempt)",
                            "maxAttempts": "\(maxAttempts)",
                        ]
                    )

                    let transport: HTTP2ClientTransport.Posix
                    if udsPath != "" {
                        logger.info(
                            "Connecting to controller via UDS",
                            metadata: [
                                "path": "\(udsPath)",
                                "maxAttempts": "\(maxAttempts)",
                                "initialBackoff": "\(initialBackoff)",
                            ]
                        )
                        transport = try HTTP2ClientTransport.Posix.http2NIOPosix(
                            target: .unixDomainSocket(path: udsPath),
                            transportSecurity: .plaintext
                        )
                    } else {
                        let port = configReader.int(forKey: "workload.controller.grpc.listeningport", default: 4443)
                        logger.info(
                            "Connecting to controller via TCP",
                            metadata: [
                                "address": "127.0.0.1",
                                "port": "\(port)",
                                "maxAttempts": "\(maxAttempts)",
                                "initialBackoff": "\(initialBackoff)",
                            ]
                        )
                        let localhostAddress = SocketAddress.IPv4(host: "127.0.0.1", port: port)
                        transport = try HTTP2ClientTransport.Posix.http2NIOPosix(
                            target: ResolvableTargets.IPv4(addresses: [localhostAddress]),
                            transportSecurity: .plaintext
                        )
                    }

                    return try await withGRPCClient(
                        transport: transport
                    ) { grpcClient in
                        let client = Proto_Controller_Controller.Client(wrapping: grpcClient)
                        let controller = PublishingCloudBoardController(
                            inner: LocalCloudBoardController(client: client),
                            publisher: publisher
                        )
                        return try await handler(controller)
                    }
                } catch let error as RPCError where error.code == .unavailable {
                    // Transient error - server not ready yet, retry with backoff
                    lastError = error
                    logger.warning(
                        "Controller unavailable",
                        metadata: [
                            "attempt": "\(attempt)",
                            "maxAttempts": "\(maxAttempts)",
                            "error": "\(error.message)",
                        ]
                    )
                    if attempt < maxAttempts {
                        logger.debug(
                            "Backing off before retry",
                            metadata: [
                                "backoffMs": "\(backoffMs)"
                            ]
                        )
                        try await Task.sleep(for: .milliseconds(backoffMs))
                        backoffMs = min(backoffMs * 2, 5000)  // Cap at 5 seconds
                    }
                } catch {
                    // Terminal error - don't retry
                    logger.error(
                        "Terminal error",
                        metadata: [
                            "attempt": "\(attempt)",
                            "error": "\(String(reportable: error))",
                        ]
                    )
                    throw error
                }
            }

            logger.error(
                "Failed to connect to controller",
                metadata: [
                    "maxAttempts": "\(maxAttempts)"
                ]
            )
            if let error = lastError {
                throw error
            }
            throw ControllerConnectionError(message: "Failed to connect to controller after \(maxAttempts) attempts")
        }
    }
}
