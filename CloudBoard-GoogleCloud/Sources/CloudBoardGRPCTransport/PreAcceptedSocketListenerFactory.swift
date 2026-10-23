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

import GRPCNIOTransportHTTP2
import NIOCore
import NIOPosix

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

final class AcceptHandler: ChannelInboundHandler {
    typealias InboundIn = NIOBSDSocket.Handle
    typealias InboundOut = Channel

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let fd = Self.unwrapInboundIn(data)

        let channel = ClientBootstrap(group: context.eventLoop).withConnectedSocket(fd)
        channel.assumeIsolated().whenSuccess { channel in
            context.fireChannelRead(Self.wrapInboundOut(channel))
        }
    }
}

final class ConfigureHandler: ChannelInboundHandler {
    typealias InboundIn = Channel
    typealias InboundOut = HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel

    let configurator: HTTP2ServerTransport.ConnectionConfigurator

    init(
        configurator: HTTP2ServerTransport.ConnectionConfigurator
    ) {
        self.configurator = configurator
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channel = Self.unwrapInboundIn(data)

        self.configurator.configure(
            channel: channel,
            tls: .none
        ).hop(to: context.eventLoop).assumeIsolated().whenComplete { result in
            switch result {
            case .success(let configured):
                context.fireChannelRead(Self.wrapInboundOut(configured))
            case .failure(let error):
                context.fireErrorCaught(error)
                context.close(promise: nil)
            }
        }
    }
}

/// A ``HTTP2ServerTransport/ListenerFactory`` for pre-accepted (already-connected) socket
/// file descriptors, such as those passed by systemd with `Accept=true`.
///
/// This factory registers the connected fd with NIO, configures the HTTP/2 + gRPC pipeline on it, and delivers it as a
/// single-element async channel to the gRPC transport.
///
/// ## Usage with systemd socket activation (`Accept=true`)
///
/// ```swift
/// let factory = try PreAcceptedSocketListenerFactory(source: .systemd)
/// let transport = HTTP2ServerTransport.Custom(listenerFactory: factory)
/// let server = GRPCServer(transport: transport, services: [myService])
/// try await server.serve()
/// ```
///
/// - Important: gRPC takes ownership of the file descriptor. You **must not** close it manually.
final package class PreAcceptedSocketListenerFactory: HTTP2ServerTransport.ListenerFactory {
    package let eventLoopGroup: any EventLoopGroup
    package let fileDescriptor: Int32

    /// Describes where the pre-accepted file descriptor comes from.
    package enum Source {
        /// Use fd 3 (`SD_LISTEN_FDS_START`) after validating that the process is
        /// running under systemd socket activation by checking `LISTEN_PID` and
        /// `LISTEN_FDS`.
        case systemd

        /// Use an explicit file descriptor.
        case fileDescriptor(Int32)
    }

    /// Creates a new factory.
    ///
    /// - Parameters:
    ///   - source: Where to obtain the pre-accepted file descriptor.
    ///   - eventLoopGroup: The event loop group to register the socket on.
    /// - Throws: If ``Source/systemd`` is used and the environment variables are missing,
    ///   `LISTEN_PID` doesn't match the current process, or no file descriptors were passed.
    package init(
        source: Source,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
    ) throws {
        switch source {
        case .systemd:
            let nfds = Self.sdListenFDs()
            guard nfds >= 1 else {
                throw SystemdSocketActivationError(
                    message: "No file descriptors received from systemd (LISTEN_FDS not set or LISTEN_PID mismatch)"
                )
            }
            guard nfds == 1 else {
                throw SystemdSocketActivationError(
                    message: "Unexpectedly received more than one file descriptor received from systemd"
                )
            }
            self.fileDescriptor = 3  // SD_LISTEN_FDS_START

        case .fileDescriptor(let fd):
            self.fileDescriptor = fd
        }
        self.eventLoopGroup = eventLoopGroup
    }

    package func makeListeningChannel(
        listenerConfigurator: HTTP2ServerTransport.ListenerConfigurator,
        connectionConfigurator: HTTP2ServerTransport.ConnectionConfigurator
    ) async throws -> NIOAsyncChannel<HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel, Never> {

        let eventLoop = self.eventLoopGroup.next()

        let channel = eventLoop.flatSubmit {
            // Create listener channel.
            let channel = SingleConnectionListenerChannel(eventLoop: eventLoop)

            // Configure the pipeline such that:
            // - Accept Handler
            // - <gRPC handlers>
            // - ConfigureHandler
            return listenerConfigurator.configure(channel: channel).flatMap {
                eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(AcceptHandler(), position: .first)
                    try sync.addHandler(ConfigureHandler(configurator: connectionConfigurator), position: .last)
                    // Wrap it up as an async channel.
                    return try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            inboundType: HTTP2ServerTransport.ConnectionConfigurator.ConnectionChannel.self,
                            outboundType: Never.self
                        )
                    )
                }
            }
        }

        let configured = try await channel.get()

        // Now that the listener is configured, fire in the fd.
        configured.channel.pipeline.fireChannelRead(self.fileDescriptor)
        configured.channel.pipeline.fireChannelReadComplete()

        return configured
    }

    /// Equivalent to `sd_listen_fds(1)` from libsystemd.
    private static func sdListenFDs() -> Int {
        let env = ProcessInfo.processInfo.environment
        guard let pidString = env["LISTEN_PID"],
            let fdsString = env["LISTEN_FDS"]
        else { return 0 }

        guard let pid = Int(pidString), pid == getpid() else { return 0 }
        guard let nfds = Int(fdsString), nfds >= 0 else { return 0 }

        unsetenv("LISTEN_PID")
        unsetenv("LISTEN_FDS")

        return nfds
    }
}

package struct SystemdSocketActivationError: Error, CustomStringConvertible {
    package let message: String
    package var description: String { self.message }
}

/// A minimal `Channel` implementation backed by a real `EventLoop` that serves as a
/// container for delivering a single pre-configured connection to a `NIOAsyncChannel`.
///
/// Most operations are no-ops since this channel doesn't perform real I/O. It only
/// exists to satisfy the `ListenerFactory` protocol's requirement of returning a
/// `NIOAsyncChannel<ConnectionChannel, Never>`.
private final class SingleConnectionListenerChannel: Channel, @unchecked Sendable {
    let allocator = ByteBufferAllocator()
    let parent: Channel? = nil
    let isWritable = true
    let _eventLoop: EventLoop
    private var _pipeline: ChannelPipeline!
    private let core: Core

    var pipeline: ChannelPipeline { self._pipeline }
    var eventLoop: EventLoop { self._eventLoop }
    var closeFuture: EventLoopFuture<Void> { self.core.closePromise.futureResult }
    var isActive: Bool { self.core.isActive }
    var localAddress: NIOCore.SocketAddress? { nil }
    var remoteAddress: NIOCore.SocketAddress? { nil }
    var _channelCore: ChannelCore { self.core }
    var syncOptions: NIOSynchronousChannelOptions? { nil }

    init(eventLoop: EventLoop) {
        self._eventLoop = eventLoop
        self._pipeline = nil
        self.core = Core(eventLoop: eventLoop)

        let pipeline = ChannelPipeline(channel: self)
        self._pipeline = pipeline
        self.core.pipeline = pipeline

        // Activate the channel so pipeline handlers see channelRegistered/channelActive.
        self.core.registerAlreadyConfigured0(promise: nil)
    }

    func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        self._eventLoop.makeSucceededVoidFuture()
    }

    func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        self._eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
    }

    private final class Core: ChannelCore, @unchecked Sendable {
        let eventLoop: EventLoop
        let closePromise: EventLoopPromise<Void>
        var pipeline: ChannelPipeline!
        private var _isActive = false

        var isActive: Bool { self._isActive }

        init(eventLoop: EventLoop) {
            self.eventLoop = eventLoop
            self.closePromise = eventLoop.makePromise()
        }

        func localAddress0() throws -> NIOCore.SocketAddress { throw ChannelError.operationUnsupported }
        func remoteAddress0() throws -> NIOCore.SocketAddress { throw ChannelError.operationUnsupported }

        func register0(promise: EventLoopPromise<Void>?) {
            promise?.succeed(())
            self.pipeline.syncOperations.fireChannelRegistered()
        }

        func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
            self._isActive = true
            self.register0(promise: promise)
            self.pipeline.syncOperations.fireChannelActive()
        }

        func bind0(to: NIOCore.SocketAddress, promise: EventLoopPromise<Void>?) {
            promise?.succeed(())
        }

        func connect0(to: NIOCore.SocketAddress, promise: EventLoopPromise<Void>?) {
            self._isActive = true
            promise?.succeed(())
            self.pipeline.syncOperations.fireChannelActive()
        }

        func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
            promise?.succeed(())
        }

        func flush0() {}
        func read0() {}

        func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            guard self._isActive else {
                promise?.fail(ChannelError.alreadyClosed)
                return
            }
            self._isActive = false
            promise?.succeed(())

            self.pipeline.syncOperations.fireChannelInactive()
            self.pipeline.syncOperations.fireChannelUnregistered()

            self.eventLoop.execute {
                self.removeHandlers(pipeline: self.pipeline)
                self.closePromise.succeed(())
            }
        }

        func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
            promise?.succeed(())
        }

        func channelRead0(_ data: NIOAny) {}
        func errorCaught0(error: Error) {}
    }
}
