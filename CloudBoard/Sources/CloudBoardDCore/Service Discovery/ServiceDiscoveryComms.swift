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

import CloudBoardCommon
import CloudBoardController
import CloudBoardLogging
import CloudBoardMetrics
import CloudBoardPlatformUtilities
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import InternalSwiftProtobuf
import Logging
import NIOCore
import NIOHTTP2
import NIOTransportServices
import os

/// Covers the boundary of talking to the remote ServiceDiscovery instance so it can be mocked out
protocol ServiceDiscoveryCommsProtocol: Sendable {
    func announceService(_ update: ServiceDiscovery.ServiceUpdate) -> ServiceDiscovery.Announcement
}

final class ServiceDiscoveryComms: ServiceDiscoveryCommsProtocol, Sendable {
    fileprivate static let logger: os.Logger = .init(
        subsystem: "com.apple.cloudos.cloudboard",
        category: "ServiceDiscovery.RemoteService"
    )

    private let client: ServiceDiscovery.Client
    private let metrics: any MetricsSystem

    init(
        group: NIOTSEventLoopGroup,
        targetHost: String,
        targetPort: Int,
        tlsConfiguration: ClientTLSConfiguration,
        keepalive: CloudBoardDConfiguration.Keepalive?,
        metrics: any MetricsSystem
    ) throws {
        Self.logger.log(
            "Preparing service discovery publisher to \(targetHost, privacy: .public):\(targetPort, privacy: .public), TLS \(tlsConfiguration, privacy: .public), Keepalive: \(String(describing: keepalive), privacy: .public)"
        )
        let channel = try GRPCChannelPool.with(
            target: .hostAndPort(targetHost, targetPort),
            transportSecurity: .init(tlsConfiguration),
            eventLoopGroup: group
        ) { config in
            config.backgroundActivityLogger = Logging.Logger(
                osLogSubsystem: "com.apple.cloudos.cloudboard",
                osLogCategory: "ServiceDiscovery.AsyncClient_BackgroundActivity",
                domain: "ServiceDiscovery.AsyncClient_BackgroundActivity"
            )
            config.keepalive = .init(keepalive)
            config.debugChannelInitializer = { channel in
                // We want to go immediately after the HTTP2 handler so we can see what the GRPC idle handler is doing.
                channel.pipeline.handler(type: NIOHTTP2Handler.self).map { http2Handler in
                    let pingDiagnosticHandler = GRPCPingDiagnosticHandler(logger: os.Logger(
                        subsystem: "com.apple.cloudos.cloudboard",
                        category: "ServiceDiscovery.GRPCPingDiagnosticHandler"
                    ))
                    do {
                        return try channel.pipeline.syncOperations.addHandler(
                            pingDiagnosticHandler,
                            position: .after(http2Handler)
                        )
                    } catch {
                        Self.logger.error(
                            "Failed to add GRPCPingDiagnosticHandler: \(String(unredacted: error), privacy: .public)"
                        )
                    }
                }
            }
            config.delegate = PoolDelegate(metrics: metrics)
        }

        let logger = Logging.Logger(
            osLogSubsystem: "com.apple.cloudos.cloudboard",
            osLogCategory: "ServiceDiscovery.AsyncClient",
            domain: "ServiceDiscovery.AsyncClient"
        )

        self.client = .init(channel: channel, defaultCallOptions: CallOptions(logger: logger))
        self.metrics = metrics
    }

    convenience init(
        group: NIOTSEventLoopGroup,
        configuration: CloudBoardDConfiguration.ServiceDiscovery,
        localIdentityCallback: GRPCTLSConfiguration.IdentityCallback?,
        metrics: any MetricsSystem,
    ) throws {
        try self.init(
            group: group,
            targetHost: configuration.targetHost,
            targetPort: configuration.targetPort,
            tlsConfiguration: .init(configuration.tlsConfig, identityCallback: localIdentityCallback),
            keepalive: configuration.keepalive,
            metrics: metrics
        )
    }

    func announceService(_: ServiceDiscovery.ServiceUpdate) -> ServiceDiscovery.Announcement {
        let grpc = self.client.makeAnnounceCall()
        return ServiceDiscovery.Announcement(
            responseStream: grpc.responseStream,
            // The use of typealiases means this needs a wrapping closure
            // that's worth it for simpler to read code given the length of the proto generated types
            send: { try await grpc.requestStream.send($0) },
            finish: grpc.requestStream.finish
        )
    }
}

extension GRPCChannelPool.Configuration.TransportSecurity {
    init(_ tlsMode: ClientTLSConfiguration) {
        switch tlsMode {
        case .plaintext:
            self = .plaintext
        case .simpleTLS(let config):
            self = .tls(
                .grpcTLSConfiguration(
                    hostnameOverride: config.sniOverride,
                    identityCallback: config.localIdentityCallback,
                    customRoot: config.customRoot
                )
            )
        }
    }
}

extension TimeAmount {
    init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components

        let nanosecondsFromSeconds = seconds * 1_000_000_000
        let nanosecondsFromAttoseconds = attoseconds / 1_000_000_000
        self = .nanoseconds(nanosecondsFromSeconds + nanosecondsFromAttoseconds)
    }
}
