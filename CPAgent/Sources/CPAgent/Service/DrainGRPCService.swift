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

/// Hosts the drain gRPC service over a Unix Domain Socket for CloudBoard drain signaling.
/// If the socket directory does not exist (shared volume not mounted), logs a warning and idles.
struct DrainGRPCServer: Service {
    let socketPath: String
    let drainGRPCService: DrainGRPCService
    private let logger = Logger(label: "CPAgent.DrainGRPCServer")

    init(socketPath: String = "/var/run/cloudboard/drain.sock", drainGRPCService: DrainGRPCService)
    {
        self.socketPath = socketPath
        self.drainGRPCService = drainGRPCService
    }

    func run() async throws {
        let socketDirectory = (socketPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: socketDirectory) else {
            logger.warning(
                "Socket directory does not exist, drain gRPC server will not start",
                metadata: ["directory": "\(socketDirectory)"])
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
            }
            return
        }

        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        let server = GRPCServer(
            transport: transport,
            services: [drainGRPCService]
        )

        logger.info("Drain gRPC server starting", metadata: ["socketPath": "\(self.socketPath)"])

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
                "Drain gRPC server failed, will not restart",
                metadata: [
                    "socketPath": "\(self.socketPath)", "error": "\(String(reportable: error))",
                ])
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }
}

// MARK: - Service handler

/// gRPC service handler for the drain bidi stream.
/// Cloudboard subscribes via this stream. When a drain is initiated (via HTTP POST /drain),
/// DrainService notifies this handler, which pushes a DrainSignal to the client.
/// When the client sends back a DrainComplete, we mark the drain as complete early.
struct DrainGRPCService: Drain_DrainService.SimpleServiceProtocol, Sendable {
    let drainService: DrainService
    private let logger = Logger(label: "CPAgent.DrainGRPCService")

    func subscribe(
        request: GRPCCore.RPCAsyncSequence<Drain_DrainClientMessage, any Swift.Error>,
        response: GRPCCore.RPCWriter<Drain_DrainServerMessage>,
        context: GRPCCore.ServerContext
    ) async throws {
        // RPCAsyncSequence is single-consumer; use one iterator for the stream's lifetime.
        var requestIterator = request.makeAsyncIterator()
        let clientName = await readClientName(from: &requestIterator)
        logger.info("Client subscribed to drain stream", metadata: ["client": "\(clientName)"])
        await drainService.subscriberConnected()

        let (signalStream, signalContinuation) = AsyncStream<Int>.makeStream()
        let listenerId = await drainService.addDrainListener { gracePeriodSeconds in
            signalContinuation.yield(gracePeriodSeconds)
        }
        defer {
            signalContinuation.finish()
            Task {
                await drainService.removeDrainListener(listenerId)
                await drainService.subscriberDisconnected()
            }
        }

        // If drain is already in progress when client connects, send signal immediately
        let currentStatus = await drainService.getStatus()
        if currentStatus == .draining {
            logger.info(
                "Drain already in progress, sending signal immediately",
                metadata: ["client": "\(clientName)"])
            try await response.write(makeDrainServerMessage(gracePeriodSeconds: 0))
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.forwardDrainSignals(
                    signalStream: signalStream, response: response, clientName: clientName)
            }

            // Continue reading from the same iterator for drain complete messages
            do {
                while let message = try await requestIterator.next() {
                    if case .drainComplete = message.message {
                        logger.info(
                            "Received drain complete from client",
                            metadata: ["client": "\(clientName)"])
                        await drainService.receivedDrainComplete()
                    }
                }
            } catch {
                logger.debug("Client request stream ended", metadata: ["client": "\(clientName)"])
            }

            group.cancelAll()
        }
    }

    private func forwardDrainSignals(
        signalStream: AsyncStream<Int>,
        response: GRPCCore.RPCWriter<Drain_DrainServerMessage>,
        clientName: String
    ) async {
        do {
            for await gracePeriodSeconds in signalStream {
                try await response.write(
                    makeDrainServerMessage(gracePeriodSeconds: gracePeriodSeconds))
                logger.info(
                    "Sent drain signal to client",
                    metadata: [
                        "client": "\(clientName)", "gracePeriodSeconds": "\(gracePeriodSeconds)",
                    ])
            }
        } catch {
            logger.debug("Drain signal stream ended", metadata: ["client": "\(clientName)"])
        }
    }

    private func readClientName(
        from iterator:
            inout GRPCCore.RPCAsyncSequence<Drain_DrainClientMessage, any Swift.Error>.AsyncIterator
    ) async -> String {
        do {
            while let message = try await iterator.next() {
                if case .subscribe(let sub) = message.message {
                    return sub.clientName
                }
            }
        } catch {
            // Stream ended before subscribe message received
        }
        return "unknown"
    }

    private func makeDrainServerMessage(gracePeriodSeconds: Int) -> Drain_DrainServerMessage {
        var signal = Drain_DrainSignal()
        signal.gracePeriodSeconds = Int32(clamping: gracePeriodSeconds)
        signal.timestamp = Google_Protobuf_Timestamp(date: Date())

        var serverMessage = Drain_DrainServerMessage()
        serverMessage.signal = signal
        return serverMessage
    }
}
