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

import NIOCore

/// Buffers inbound bytes until the first flush.
///
/// When a `ClientBootstrap`-connected channel is handed to `HTTP2ClientTransport.WrappedChannel`,
/// the channel is already active and may receive the server's initial HTTP/2 SETTINGS frame
/// before the gRPC pipeline is configured. If that frame arrives before
/// `configureGRPCClientPipeline` has installed the `ClientConnectionHandler`, the connection
/// wedges — `.ready` is never emitted and RPCs fail with a generic `unknown` error.
///
/// This handler is installed in the channel pipeline before the channel is handed to
/// `WrappedChannel`. It buffers inbound bytes until the first outbound flush (the HTTP/2
/// connection preface emitted by `NIOHTTP2Handler.handlerAdded`), then defers delivery by
/// one event loop tick so the rest of the pipeline finishes configuring before the buffered
/// bytes are replayed.

/// Buffers inbound bytes until the first flush.
///
/// Some tests using the 'WrappedChannel' client transport create a NIO channel with an
/// empty pipeline and pass it to the transport to configure it. However, the server may send its
/// initial SETTINGS frame before the pipeline is configured which would result in the frame
/// being dropped. This results in unnecessary connection errors.
///
/// This handler works around the issue by buffering inbound bytes until the first flush
/// happens (which would be the HTTP/2 connection preface). It should be added to the channel
/// pipeline before being passed to the 'WrappedChannel'.
///
/// Vendored from grpc-swift-nio-transport
/// (`Tests/GRPCNIOTransportHTTP2Tests/Test Utilities/BufferInboundUntilFlush.swift`).
package final class BufferInboundUntilFlush: ChannelDuplexHandler {
    package typealias InboundIn = ByteBuffer
    package typealias InboundOut = ByteBuffer
    package typealias OutboundIn = ByteBuffer
    package typealias OutboundOut = ByteBuffer

    private var accumulated: ByteBuffer?
    private var isBuffering: Bool

    package init() {
        self.accumulated = nil
        self.isBuffering = true
    }

    private func unbuffer(context: ChannelHandlerContext) {
        self.isBuffering = false
        if let buffered = self.accumulated.take() {
            let wrapped = self.wrapInboundOut(buffered)
            context.fireChannelRead(wrapped)
            context.fireChannelReadComplete()
        }
    }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if self.isBuffering {
            let buffer = self.unwrapInboundIn(data)
            self.accumulated.setOrWriteImmutableBuffer(buffer)
        } else {
            context.fireChannelRead(data)
        }
    }

    package func channelReadComplete(context: ChannelHandlerContext) {
        if !self.isBuffering {
            context.fireChannelReadComplete()
        }
    }

    package func flush(context: ChannelHandlerContext) {
        if self.isBuffering {
            // Defer unbuffering to the next event loop tick.
            //
            // This flush originates from the NIOHTTP2Handler writing its connection preface
            // in 'handlerAdded'. At this point 'configureGRPCClientPipeline' has not finished so the
            // 'ClientConnectionHandler' has not been added to the pipeline yet.
            //
            // If the handler delivered the buffered bytes synchronously the 'NIOHTTP2Handler'
            // would decode the server's SETTINGS frame and the multiplexer would forward
            // it inbound as an 'HTTP2Frame'. The 'ClientConnectionHandler' would never see the
            // initial SETTINGS frame (it hasn't been added to the pipeline yet) and would never
            // emit '.ready', and the connection would be wedged.
            //
            // Deferring by one tick allows the current tick to finish configuring the
            // pipeline. On the next tick the buffered bytes are delivered through the
            // fully configured pipeline.
            context.eventLoop.assumeIsolated().execute {
                self.unbuffer(context: context)
            }
        }

        context.flush()
    }
}
