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
import Foundation
import GRPCClientConfiguration
import InternalGRPC
import InternalSwiftProtobuf
import Logging
import NIOCore
import NIOTransportServices
import PersistentServiceBridgeRouterAPI

/// Owns the immutable channel-construction configuration for the
/// persistent-service gRPC channels and produces them on demand. Scoped
/// to a single value type so the manager doesn't carry the channel-
/// plumbing state itself.
struct PersistentChannelPoolBuilder: Sendable {
    let eventLoopGroup: NIOTSEventLoopGroup
    let identityCallback: GRPCTLSConfiguration.IdentityCallback?
    let tlsConfig: GRPCClientConfiguration.TLSConfiguration?
    let serverVerification: GRPCTLSConfiguration.ServerVerification?
    /// Interval between HTTP/2 PINGs sent on each gRPC channel. NIO
    /// uses these to detect a black-holed TCP connection independently
    /// of application-level traffic; if no PONG arrives within
    /// `http2KeepalivePongTimeout` the channel is closed and the
    /// in-flight stream errors out, triggering the retry loop. Stored
    /// as `TimeAmount` to match the gRPC-Swift / NIO surface.
    let http2KeepalivePingInterval: TimeAmount
    /// PONG-wait deadline paired with `http2KeepalivePingInterval`.
    /// Must be strictly less than the interval
    /// (`ClientConnectionKeepalive` preconditions on this).
    let http2KeepalivePongTimeout: TimeAmount

    private static let grpcBackgroundActivityLogger = Logging.Logger(
        osLogSubsystem: "com.apple.cloudos.cloudboard",
        osLogCategory: "PersistentClientHelperManager",
        domain: "BackgroundActivity"
    )

    private static let grpcClientLogger = Logging.Logger(
        osLogSubsystem: "com.apple.cloudos.cloudboard",
        osLogCategory: "PersistentClientHelperManager",
        domain: "GRPC"
    )

    /// Establishes a gRPC channel and sends AnnounceConnection using
    /// the transport mode the publisher declared in its SD
    /// announcement (parsed at SD ingest into `ManagedNode.transportSecurity`).
    ///
    /// Single attempt — no automatic fallback between transports. If
    /// the chosen transport fails, the per-node retry loop sees the
    /// error and backs off; mismatched transports show up as
    /// announcement misconfiguration, not as a runtime guess.
    ///
    /// `resolveTransport` is invoked synchronously to look up the
    /// publisher-declared transport for the target node. Caller defaults
    /// to `.mtls` when the node has disappeared concurrently.
    func establishConnection(
        host: String,
        port: Int,
        connectionID: String,
        resolveTransport: () -> PersistentServiceTransportSecurity
    ) async throws -> (channel: any GRPCChannel, call: GRPCAsyncBidirectionalStreamingCall<
        Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest,
        PersistentServiceResponse
    >) {
        let transport = resolveTransport()

        let transportSecurity: GRPCChannelPool.Configuration.TransportSecurity
        switch transport {
        case .mtls:
            let tlsConfiguration = ClientTLSConfiguration(
                self.tlsConfig,
                identityCallback: self.identityCallback,
                serverVerification: self.serverVerification
            )
            transportSecurity = .init(tlsConfiguration)
        case .tls:
            // Server-auth-only TLS: validate the server cert via
            // `serverVerification`, but do not present a client
            // certificate.
            let tlsConfiguration = ClientTLSConfiguration(
                self.tlsConfig,
                identityCallback: nil,
                serverVerification: self.serverVerification
            )
            transportSecurity = .init(tlsConfiguration)
        case .plaintext:
            transportSecurity = .plaintext
        }

        let channel = try GRPCChannelPool.with(
            target: .hostAndPort(host, port),
            transportSecurity: transportSecurity,
            eventLoopGroup: self.eventLoopGroup
        ) { config in
            self.applyChannelPoolConfiguration(&config)
        }

        let grpcClient = Com_Apple_Cloudboard_Api_V1_PersistentServiceAsyncClient(
            channel: channel,
            defaultCallOptions: CallOptions(logger: Self.grpcClientLogger)
        )
        let call = grpcClient.makeInvokePersistentServiceCall()

        var announceRequest = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest()
        var announce = Com_Apple_Cloudboard_Api_V1_InvokePersistentServiceRequest.AnnounceConnection()
        announce.connectionID = connectionID
        announceRequest.type = .announceConnection(announce)

        do {
            try await call.requestStream.send(announceRequest)
            return (channel, call)
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    /// Applies the configuration shared by every channel `establishConnection`
    /// creates.
    ///
    /// - `connectionPool.maxWaitTime`: bounds the wait for a connection
    ///   slot in the pool. The outer `withEstablishmentTimeout` is the
    ///   real cap; this is the cooperative knob inside gRPC.
    /// - `keepalive`: HTTP/2 PING-based liveness. Detects black-holed
    ///   TCP within `interval + timeout` regardless of application
    ///   traffic. `permitWithoutCalls = true` means PINGs run even
    ///   between in-flight messages (we always have a stream open, but
    ///   it can be quiet for long stretches).
    private func applyChannelPoolConfiguration(_ config: inout GRPCChannelPool.Configuration) {
        config.backgroundActivityLogger = Self.grpcBackgroundActivityLogger
        config.connectionPool.maxWaitTime = .seconds(10)
        config.keepalive = ClientConnectionKeepalive(
            interval: self.http2KeepalivePingInterval,
            timeout: self.http2KeepalivePongTimeout,
            permitWithoutCalls: true
        )
    }
}
